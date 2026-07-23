from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile

from codex_image.client import DEFAULT_MAIN_MODEL, image_model_supports_input_fidelity
from codex_image.webui.context import WebUIContext
from codex_image.webui.edit_mask import (
    RESPONSES_EDIT_MASK_MAX_EDGE,
    EditMaskContractError,
    aligned_edit_mask_canvas_size,
    decode_image_data_url,
    validate_edit_mask,
)
from codex_image.webui.executor import (
    _file_to_data_url,
    _instructions_for_transport,
    _normalize_compression,
    _normalize_prompt_fidelity,
    _prompt_for_transport,
    _resolve_gallery_refs,
    _resolve_reference_assets,
)
from codex_image.webui.prompt_ratio import append_ratio_prompt_instruction
from codex_image.webui.reference_file_capabilities import (
    effective_reference_file_main_model,
    reference_file_capability_key_for_backend,
)
from codex_image.webui.reference_files import (
    ReferenceFileStorage,
    dedupe_reference_file_records,
    read_reference_file_uploads,
    reference_file_task_record,
    resolve_reference_file_ids,
    validate_reference_file_total,
)
from codex_image.webui.storage import utc_now
from codex_image.webui.task_metadata import _dedupe_preserve_order, _params, _with_file_urls, _write_queued_metadata

DEFAULT_PROMPT_FIDELITY = "strict"

REFERENCE_FILE_ERROR_MESSAGES = {
    "reference_file_empty": "Reference files cannot be empty.",
    "reference_file_type_unsupported": "This reference file type is not supported.",
    "reference_file_type_mismatch": "The reference file type does not match its filename.",
    "reference_file_invalid": "The reference file is invalid.",
    "reference_file_too_large": "The reference file is too large.",
    "reference_files_total_too_large": "The combined reference files are too large.",
}
REFERENCE_FILE_MISSING_DETAIL = {
    "code": "reference_file_missing",
    "message": "A referenced file is no longer available.",
}
PROVIDER_REFERENCE_FILES_UNSUPPORTED_DETAIL = {
    "code": "provider_reference_files_unsupported",
    "message": "This provider does not support reference files for the selected Responses model.",
}


def _reject_cached_unsupported_reference_files(
    ctx: WebUIContext,
    *,
    has_reference_files: bool,
    requested_backend: str,
    provider_id: str | None,
    main_model: str,
) -> None:
    if not has_reference_files:
        return
    key = reference_file_capability_key_for_backend(
        requested_backend=requested_backend,
        provider_id=str(provider_id or ""),
        main_model=main_model,
        api_settings=ctx.api_settings,
    )
    if key in ctx.responses_file_unsupported_keys:
        raise HTTPException(status_code=400, detail=PROVIDER_REFERENCE_FILES_UNSUPPORTED_DETAIL)


async def _prepare_reference_files(
    storage: ReferenceFileStorage,
    uploads: list[UploadFile],
    asset_ids: list[str],
) -> list[dict[str, Any]]:
    try:
        validated_uploads = await read_reference_file_uploads(uploads)
    except ValueError as exc:
        code = str(exc)
        raise HTTPException(
            status_code=400,
            detail={"code": code, "message": REFERENCE_FILE_ERROR_MESSAGES.get(code, "The reference file is invalid.")},
        ) from exc
    try:
        selected_records = resolve_reference_file_ids(storage, asset_ids, touch=False)
    except (FileNotFoundError, OSError, ValueError) as exc:
        raise HTTPException(status_code=404, detail=REFERENCE_FILE_MISSING_DETAIL) from exc

    predicted_records = dedupe_reference_file_records(
        [reference_file_task_record(upload) for upload in validated_uploads] + selected_records
    )
    try:
        validate_reference_file_total(predicted_records)
    except ValueError as exc:
        code = str(exc)
        raise HTTPException(
            status_code=400,
            detail={"code": code, "message": REFERENCE_FILE_ERROR_MESSAGES.get(code, "The reference file is invalid.")},
        ) from exc

    try:
        return storage.commit_batch(validated_uploads, asset_ids)
    except ValueError as exc:
        code = str(exc)
        if code == "reference_file_missing":
            raise HTTPException(status_code=404, detail=REFERENCE_FILE_MISSING_DETAIL) from exc
        stable_code = code if code in REFERENCE_FILE_ERROR_MESSAGES else "reference_file_invalid"
        raise HTTPException(
            status_code=400,
            detail={
                "code": stable_code,
                "message": REFERENCE_FILE_ERROR_MESSAGES[stable_code],
            },
        ) from exc


def register_generation_routes(app: FastAPI, ctx: WebUIContext) -> None:
    h = ctx.route_helpers

    @app.post("/api/generate")
    async def generate(
        prompt: str = Form(...),
        main_model: str = Form(DEFAULT_MAIN_MODEL),
        model: str = Form("gpt-image-2"),
        size: str = Form("auto"),
        resolution: str | None = Form(None),
        ratio: str | None = Form(None),
        orientation: str | None = Form(None),
        quality: str = Form("low"),
        background: str | None = Form(None),
        output_format: str = Form("png"),
        moderation: str | None = Form(None),
        output_compression: str | None = Form(None),
        n: int = Form(1, ge=1, le=4),
        web_search: bool = Form(False),
        codex_mode: str | None = Form(None),
        api_mode: str | None = Form(None),
        api_provider_id: str | None = Form(None),
        prompt_for_model: str | None = Form(None),
        prompt_fidelity: str = Form(DEFAULT_PROMPT_FIDELITY),
        gallery_image_ids: list[str] | None = Form(None),
        reference_asset_ids: list[str] | None = Form(None),
        reference_file_ids: list[str] | None = Form(None),
        reference_images: list[UploadFile] | None = File(None),
        editing_guidance: str | None = Form(None),
        editing_shared_base: UploadFile | None = File(None),
        editing_instruction_marks: UploadFile | None = File(None),
        editing_edit_region: UploadFile | None = File(None),
        editing_edit_mask: UploadFile | None = File(None),
        reference_files: list[UploadFile] | None = File(None),
    ) -> dict[str, Any]:
        if not ctx.auth_checker():
            raise HTTPException(status_code=401, detail="Codex auth is not available")
        main_model = effective_reference_file_main_model(main_model)

        auth_source = ctx.auth_settings.read_source() if not h["client_factory_overridden"] else "codex"
        effective_api_provider_id = h["request_api_provider_id"](auth_source, api_provider_id)
        effective_api_provider_name = h["request_api_provider_name"](auth_source, effective_api_provider_id)
        effective_api_mode = h["request_api_mode"](auth_source, api_mode, effective_api_provider_id)
        effective_codex_mode = h["request_codex_mode"](auth_source, codex_mode)
        effective_api_images_concurrency = h["request_api_images_concurrency"](auth_source, effective_api_provider_id)
        requested_backend = h["backend_for_submit"](auth_source, effective_api_mode, effective_codex_mode)
        if (reference_files or reference_file_ids) and not requested_backend.endswith("_responses"):
            raise HTTPException(
                status_code=400,
                detail={
                    "code": "reference_files_require_responses",
                    "message": "Reference files require a Responses backend.",
                },
            )
        _reject_cached_unsupported_reference_files(
            ctx,
            has_reference_files=bool(reference_files or reference_file_ids),
            requested_backend=requested_backend,
            provider_id=effective_api_provider_id,
            main_model=main_model,
        )

        gallery_refs, gallery_data_urls = _resolve_gallery_refs(ctx.gallery_storage, gallery_image_ids or [])
        uploaded_assets = await h["save_reference_assets"](reference_images or [])
        selected_assets, _ = _resolve_reference_assets(ctx.reference_asset_storage, reference_asset_ids or [])
        reference_assets = h["dedupe_reference_assets"](uploaded_assets + selected_assets)
        file_references = await _prepare_reference_files(
            ctx.reference_file_storage,
            reference_files or [],
            reference_file_ids or [],
        )
        guidance_state: dict[str, Any] | None = None
        if editing_guidance is not None:
            try:
                candidate = json.loads(editing_guidance)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail="Invalid Editing Guidance state") from exc
            if (
                not isinstance(candidate, dict)
                or candidate.get("version") != 1
                or candidate.get("activeGuidance") not in {"instruction-marks", "edit-region"}
                or editing_shared_base is None
            ):
                raise HTTPException(status_code=400, detail="Invalid Editing Guidance state")
            guidance_state = {"version": 1, "activeGuidance": candidate["activeGuidance"]}
        task = ctx.storage.create_task("generate")
        created_at = utc_now()
        input_files: list[Path] = []
        guidance_uploads = [
            upload
            for upload in (editing_shared_base, editing_instruction_marks, editing_edit_region, editing_edit_mask)
            if upload is not None
        ]
        guidance_files = await h["save_uploads"](task.task_id, guidance_uploads, kind="guidance")
        if guidance_state is not None:
            guidance_file_iter = iter(guidance_files)
            guidance_state["sharedBaseFile"] = next(guidance_file_iter).name
            if editing_instruction_marks is not None:
                guidance_state["instructionMarksFile"] = next(guidance_file_iter).name
            if editing_edit_region is not None:
                guidance_state["editRegionFile"] = next(guidance_file_iter).name
            if editing_edit_mask is not None:
                guidance_state["editMaskFile"] = next(guidance_file_iter).name
        reference_data_urls = [
            _file_to_data_url(ctx.reference_asset_storage.image_path(str(item["id"])), mime_type=str(item.get("mime_type") or ""))
            for item in reference_assets
        ]
        all_reference_data_urls = reference_data_urls + gallery_data_urls
        compression = _normalize_compression(output_format, output_compression)
        fidelity = _normalize_prompt_fidelity(prompt_fidelity)
        model_prompt = append_ratio_prompt_instruction(h["model_prompt_for_fidelity"](prompt, prompt_for_model, fidelity), ratio)
        prompt_constraints, guard_instructions = h["prompt_guard_context"](prompt, fidelity)
        transport_mode = effective_api_mode or effective_codex_mode
        web_search_enabled = bool(web_search) and requested_backend.endswith("_responses")
        request_model_prompt = _prompt_for_transport(
            model_prompt,
            auth_source=auth_source,
            api_mode=transport_mode,
            prompt_fidelity=fidelity,
            instructions=guard_instructions,
        )
        request_instructions = _instructions_for_transport(
            auth_source=auth_source,
            api_mode=transport_mode,
            instructions=guard_instructions,
        )

        request_kwargs: dict[str, Any] = dict(
            auth_source=auth_source,
            api_mode=effective_api_mode,
            codex_mode=effective_codex_mode,
            prompt=request_model_prompt,
            main_model=main_model,
            model=model,
            input_images=all_reference_data_urls,
            size=size,
            quality=quality,
            background=background,
            output_format=output_format,
            moderation=moderation,
            output_compression=compression,
        )
        if request_instructions:
            request_kwargs["instructions"] = request_instructions
        if web_search_enabled:
            request_kwargs["web_search"] = True
        request_payload = h["build_image_request_payload"](**request_kwargs)
        stored_request_payload = h["slim_request_payload"](
            request_payload,
            input_files=[path.name for path in input_files],
            gallery_refs=gallery_refs,
            reference_assets=reference_assets,
            reference_files=file_references,
        )
        stored_request_payload["webui_requested_backend"] = requested_backend
        if effective_api_provider_id is not None:
            stored_request_payload["webui_api_provider_id"] = effective_api_provider_id
        if effective_api_provider_name:
            stored_request_payload["webui_api_provider_name"] = effective_api_provider_name
        if auth_source == "api":
            stored_request_payload["webui_api_images_concurrency"] = effective_api_images_concurrency
        ctx.storage.write_request(task.task_id, stored_request_payload)
        params = _params(main_model, model, size, quality, background, output_format, moderation, compression, n)
        if resolution:
            params["resolution"] = resolution
        if ratio:
            params["ratio"] = ratio
        if orientation:
            params["orientation"] = orientation
        params["prompt_fidelity"] = fidelity
        if web_search_enabled:
            params["web_search"] = True
        if effective_codex_mode is not None:
            params["codex_mode"] = effective_codex_mode
        if effective_api_mode is not None:
            params["api_mode"] = effective_api_mode
        if effective_api_provider_id is not None:
            params["api_provider_id"] = effective_api_provider_id
        if effective_api_provider_name:
            params["api_provider_name"] = effective_api_provider_name
        if auth_source == "api":
            params["api_images_concurrency"] = effective_api_images_concurrency
        metadata = _write_queued_metadata(
            ctx.storage,
            task.task_id,
            created_at=created_at,
            mode="generate",
            prompt=prompt,
            prompt_for_model=model_prompt,
            params=params,
            input_files=[path.name for path in input_files],
            mask_file=None,
            gallery_refs=gallery_refs,
            reference_assets=reference_assets,
            reference_files=file_references,
            prompt_constraints=prompt_constraints,
            requested_backend=requested_backend,
            max_attempts=ctx.queue_manager.max_attempts if ctx.queue_manager is not None else 1,
            editing_guidance=guidance_state,
        )
        ctx.queue_storage.enqueue(task.task_id)
        h["ensure_queue_worker_running"]()
        return {
            "task": _with_file_urls(
                metadata,
                ctx.active_task_ids,
                ctx.gallery_storage,
                ctx.reference_asset_storage,
                ctx.reference_file_storage,
            ),
            "request": stored_request_payload,
        }

    @app.post("/api/edit")
    async def edit(
        prompt: str = Form(...),
        main_model: str = Form(DEFAULT_MAIN_MODEL),
        model: str = Form("gpt-image-2"),
        size: str = Form("auto"),
        resolution: str | None = Form(None),
        ratio: str | None = Form(None),
        orientation: str | None = Form(None),
        quality: str = Form("low"),
        background: str | None = Form(None),
        output_format: str = Form("png"),
        input_fidelity: str | None = Form(None),
        moderation: str | None = Form(None),
        output_compression: str | None = Form(None),
        n: int = Form(1, ge=1, le=4),
        web_search: bool = Form(False),
        codex_mode: str | None = Form(None),
        api_mode: str | None = Form(None),
        api_provider_id: str | None = Form(None),
        prompt_for_model: str | None = Form(None),
        prompt_fidelity: str = Form(DEFAULT_PROMPT_FIDELITY),
        gallery_image_ids: list[str] | None = Form(None),
        reference_asset_ids: list[str] | None = Form(None),
        reference_file_ids: list[str] | None = Form(None),
        images: list[UploadFile] | None = File(None),
        mask: UploadFile | None = File(None),
        editing_guidance: str | None = Form(None),
        editing_shared_base: UploadFile | None = File(None),
        editing_instruction_marks: UploadFile | None = File(None),
        editing_edit_region: UploadFile | None = File(None),
        reference_files: list[UploadFile] | None = File(None),
    ) -> dict[str, Any]:
        if not ctx.auth_checker():
            raise HTTPException(status_code=401, detail="Codex auth is not available")
        main_model = effective_reference_file_main_model(main_model)

        auth_source = ctx.auth_settings.read_source() if not h["client_factory_overridden"] else "codex"
        effective_api_provider_id = h["request_api_provider_id"](auth_source, api_provider_id)
        effective_api_provider_name = h["request_api_provider_name"](auth_source, effective_api_provider_id)
        effective_api_mode = h["request_api_mode"](auth_source, api_mode, effective_api_provider_id)
        effective_codex_mode = h["request_codex_mode"](auth_source, codex_mode)
        effective_api_images_concurrency = h["request_api_images_concurrency"](auth_source, effective_api_provider_id)
        requested_backend = h["backend_for_submit"](auth_source, effective_api_mode, effective_codex_mode)
        if (reference_files or reference_file_ids) and not requested_backend.endswith("_responses"):
            raise HTTPException(
                status_code=400,
                detail={
                    "code": "reference_files_require_responses",
                    "message": "Reference files require a Responses backend.",
                },
            )
        _reject_cached_unsupported_reference_files(
            ctx,
            has_reference_files=bool(reference_files or reference_file_ids),
            requested_backend=requested_backend,
            provider_id=effective_api_provider_id,
            main_model=main_model,
        )

        gallery_refs, gallery_data_urls = _resolve_gallery_refs(ctx.gallery_storage, gallery_image_ids or [])
        uploaded_assets = await h["save_reference_assets"](images or [])
        selected_assets, _ = _resolve_reference_assets(ctx.reference_asset_storage, reference_asset_ids or [])
        reference_assets = h["dedupe_reference_assets"](uploaded_assets + selected_assets)
        if not reference_assets and not gallery_data_urls:
            raise HTTPException(status_code=400, detail="At least one image is required")
        file_references = await _prepare_reference_files(
            ctx.reference_file_storage,
            reference_files or [],
            reference_file_ids or [],
        )
        image_data_urls = [
            _file_to_data_url(ctx.reference_asset_storage.image_path(str(item["id"])), mime_type=str(item.get("mime_type") or ""))
            for item in reference_assets
        ]
        all_image_data_urls = image_data_urls + gallery_data_urls
        mask_canvas_size: tuple[int, int] | None = None
        if mask is not None:
            mask_bytes = await mask.read()
            await mask.seek(0)
            try:
                validate_edit_mask(mask_bytes, decode_image_data_url(all_image_data_urls[0]))
                mask_canvas_size = aligned_edit_mask_canvas_size(
                    all_image_data_urls[0],
                    requested_size=size,
                    model=model,
                    max_edge=RESPONSES_EDIT_MASK_MAX_EDGE if requested_backend.endswith("_responses") else None,
                )
            except EditMaskContractError as exc:
                raise HTTPException(status_code=400, detail=exc.detail) from exc

        if mask_canvas_size is not None:
            size = f"{mask_canvas_size[0]}x{mask_canvas_size[1]}"
            resolution = None
            ratio = None
            orientation = "square" if mask_canvas_size[0] == mask_canvas_size[1] else (
                "landscape" if mask_canvas_size[0] > mask_canvas_size[1] else "portrait"
            )

        guidance_state: dict[str, Any] | None = None
        if editing_guidance is not None:
            try:
                candidate = json.loads(editing_guidance)
            except json.JSONDecodeError as exc:
                raise HTTPException(status_code=400, detail="Invalid Editing Guidance state") from exc
            if (
                not isinstance(candidate, dict)
                or candidate.get("version") != 1
                or candidate.get("activeGuidance") not in {"instruction-marks", "edit-region"}
                or editing_shared_base is None
            ):
                raise HTTPException(status_code=400, detail="Invalid Editing Guidance state")
            if candidate["activeGuidance"] == "edit-region" and (editing_edit_region is None or mask is None):
                raise HTTPException(status_code=400, detail="Edit Region guidance requires an Edit Region and Edit Mask")
            guidance_state = {
                "version": 1,
                "activeGuidance": candidate["activeGuidance"],
            }

        task = ctx.storage.create_task("edit")
        created_at = utc_now()
        input_files: list[Path] = []
        mask_files = await h["save_uploads"](task.task_id, [mask] if mask is not None else [], kind="mask")
        guidance_uploads = [
            upload
            for upload in (editing_shared_base, editing_instruction_marks, editing_edit_region)
            if upload is not None
        ]
        guidance_files = await h["save_uploads"](task.task_id, guidance_uploads, kind="guidance")
        if guidance_state is not None:
            guidance_file_iter = iter(guidance_files)
            guidance_state["sharedBaseFile"] = next(guidance_file_iter).name
            if editing_instruction_marks is not None:
                guidance_state["instructionMarksFile"] = next(guidance_file_iter).name
            if editing_edit_region is not None:
                guidance_state["editRegionFile"] = next(guidance_file_iter).name
        mask_data_url = _file_to_data_url(mask_files[0]) if mask_files else None
        compression = _normalize_compression(output_format, output_compression)
        fidelity = _normalize_prompt_fidelity(prompt_fidelity)
        model_prompt = append_ratio_prompt_instruction(h["model_prompt_for_fidelity"](prompt, prompt_for_model, fidelity), ratio)
        prompt_constraints, guard_instructions = h["prompt_guard_context"](prompt, fidelity)
        effective_input_fidelity = input_fidelity if image_model_supports_input_fidelity(model) else None
        transport_mode = effective_api_mode or effective_codex_mode
        web_search_enabled = bool(web_search) and requested_backend.endswith("_responses")
        request_model_prompt = _prompt_for_transport(
            model_prompt,
            auth_source=auth_source,
            api_mode=transport_mode,
            prompt_fidelity=fidelity,
            instructions=guard_instructions,
        )
        request_instructions = _instructions_for_transport(
            auth_source=auth_source,
            api_mode=transport_mode,
            instructions=guard_instructions,
        )

        request_kwargs = dict(
            auth_source=auth_source,
            api_mode=effective_api_mode,
            codex_mode=effective_codex_mode,
            prompt=request_model_prompt,
            action="edit",
            main_model=main_model,
            model=model,
            input_images=all_image_data_urls,
            mask_image=mask_data_url,
            size=size,
            quality=quality,
            background=background,
            output_format=output_format,
            input_fidelity=effective_input_fidelity,
            moderation=moderation,
            output_compression=compression,
        )
        if request_instructions:
            request_kwargs["instructions"] = request_instructions
        if web_search_enabled:
            request_kwargs["web_search"] = True
        request_payload = h["build_image_request_payload"](**request_kwargs)
        image_input_names = [path.name for path in input_files]
        mask_file = mask_files[0].name if mask_files else None
        if guidance_state is not None and mask_file:
            guidance_state["editMaskFile"] = mask_file
        stored_request_payload = h["slim_request_payload"](
            request_payload,
            input_files=image_input_names,
            gallery_refs=gallery_refs,
            reference_assets=reference_assets,
            reference_files=file_references,
            mask_file=mask_file,
        )
        stored_request_payload["webui_requested_backend"] = requested_backend
        if effective_api_provider_id is not None:
            stored_request_payload["webui_api_provider_id"] = effective_api_provider_id
        if effective_api_provider_name:
            stored_request_payload["webui_api_provider_name"] = effective_api_provider_name
        if auth_source == "api":
            stored_request_payload["webui_api_images_concurrency"] = effective_api_images_concurrency
        ctx.storage.write_request(task.task_id, stored_request_payload)
        params = _params(main_model, model, size, quality, background, output_format, moderation, compression, n)
        if mask_canvas_size is not None:
            params["edit_mask_canvas_locked"] = True
        if resolution:
            params["resolution"] = resolution
        if ratio:
            params["ratio"] = ratio
        if orientation:
            params["orientation"] = orientation
        params["prompt_fidelity"] = fidelity
        if effective_input_fidelity:
            params["input_fidelity"] = effective_input_fidelity
        if web_search_enabled:
            params["web_search"] = True
        if effective_codex_mode is not None:
            params["codex_mode"] = effective_codex_mode
        if effective_api_mode is not None:
            params["api_mode"] = effective_api_mode
        if effective_api_provider_id is not None:
            params["api_provider_id"] = effective_api_provider_id
        if effective_api_provider_name:
            params["api_provider_name"] = effective_api_provider_name
        if auth_source == "api":
            params["api_images_concurrency"] = effective_api_images_concurrency
        metadata = _write_queued_metadata(
            ctx.storage,
            task.task_id,
            created_at=created_at,
            mode="edit",
            prompt=prompt,
            prompt_for_model=model_prompt,
            params=params,
            input_files=image_input_names,
            mask_file=mask_file,
            gallery_refs=gallery_refs,
            reference_assets=reference_assets,
            reference_files=file_references,
            prompt_constraints=prompt_constraints,
            requested_backend=requested_backend,
            max_attempts=ctx.queue_manager.max_attempts if ctx.queue_manager is not None else 1,
            editing_guidance=guidance_state,
        )
        ctx.queue_storage.enqueue(task.task_id)
        h["ensure_queue_worker_running"]()
        return {
            "task": _with_file_urls(
                metadata,
                ctx.active_task_ids,
                ctx.gallery_storage,
                ctx.reference_asset_storage,
                ctx.reference_file_storage,
            ),
            "request": stored_request_payload,
        }
