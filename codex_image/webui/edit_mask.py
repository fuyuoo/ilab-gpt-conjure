from __future__ import annotations

import base64
import binascii
import math
import re
from io import BytesIO

from PIL import Image, UnidentifiedImageError


RESPONSES_EDIT_MASK_MAX_EDGE = 2048
EDIT_MASK_MAX_FILE_BYTES = 50 * 1024 * 1024
GPT_IMAGE_2_MAX_EDGE = 3840
GPT_IMAGE_2_MIN_PIXELS = 655_360
GPT_IMAGE_2_MAX_PIXELS = 8_294_400
GPT_IMAGE_2_MAX_ASPECT_RATIO = 3.0
LEGACY_EDIT_SIZES = ((1024, 1024), (1024, 1536), (1536, 1024))


class EditMaskContractError(RuntimeError):
    def __init__(self, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.retryable = retryable

    @property
    def detail(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message}


def decode_image_data_url(data_url: str) -> bytes:
    return _decode_image_data_url(
        data_url,
        code="edit_primary_image_invalid",
        message="The Primary Edit Image is invalid.",
    )


def validate_edit_mask(mask_bytes: bytes, primary_image_bytes: bytes) -> None:
    if not mask_bytes:
        raise EditMaskContractError("edit_mask_empty", "The Edit Mask file cannot be empty.")
    if len(mask_bytes) >= EDIT_MASK_MAX_FILE_BYTES:
        raise EditMaskContractError("edit_mask_too_large", "The Edit Mask must be smaller than 50 MB.")
    if len(primary_image_bytes) >= EDIT_MASK_MAX_FILE_BYTES:
        raise EditMaskContractError("edit_primary_image_too_large", "The Primary Edit Image must be smaller than 50 MB.")

    try:
        with Image.open(BytesIO(primary_image_bytes)) as primary:
            primary.load()
            primary_size = primary.size
        with Image.open(BytesIO(mask_bytes)) as mask:
            mask.load()
            mask_format = str(mask.format or "").upper()
            mask_size = mask.size
            has_alpha = "A" in mask.getbands() or "transparency" in mask.info
            alpha = mask.convert("RGBA").getchannel("A") if has_alpha else None
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise EditMaskContractError("edit_mask_invalid", "The Edit Mask must be a valid PNG image.") from exc

    if mask_format != "PNG" or alpha is None:
        raise EditMaskContractError("edit_mask_invalid", "The Edit Mask must be a valid PNG image with an alpha channel.")
    if mask_size != primary_size:
        raise EditMaskContractError(
            "edit_mask_dimensions_mismatch",
            "The Edit Mask dimensions must exactly match the Primary Edit Image.",
        )
    if alpha.getextrema() == (255, 255):
        raise EditMaskContractError("edit_mask_empty_region", "The Edit Mask must contain a non-empty editable region.")


def validate_edit_mask_data_urls(mask_data_url: str, primary_image_data_url: str) -> None:
    mask_bytes = _decode_mask_data_url(mask_data_url)
    primary_bytes = decode_image_data_url(primary_image_data_url)
    validate_edit_mask(mask_bytes, primary_bytes)


def aligned_edit_mask_canvas_size(
    primary_image_data_url: str,
    *,
    requested_size: str | None,
    model: str | None,
    max_edge: int | None = None,
) -> tuple[int, int]:
    primary_bytes = decode_image_data_url(primary_image_data_url)
    try:
        with Image.open(BytesIO(primary_bytes)) as primary:
            primary.load()
            primary_size = primary.size
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise EditMaskContractError("edit_primary_image_invalid", "The Primary Edit Image is invalid.") from exc

    width, height = primary_size
    long_short_ratio = max(width, height) / min(width, height)
    if long_short_ratio > GPT_IMAGE_2_MAX_ASPECT_RATIO:
        raise EditMaskContractError(
            "edit_primary_aspect_ratio_unsupported",
            "The Primary Edit Image aspect ratio must be between 1:3 and 3:1 for a locked Edit Mask canvas.",
        )

    normalized_model = str(model or "").strip().lower()
    if not normalized_model.startswith("gpt-image-2"):
        source_ratio = width / height
        return min(
            LEGACY_EDIT_SIZES,
            key=lambda size: abs(math.log((size[0] / size[1]) / source_ratio)),
        )

    requested = _parse_size(requested_size)
    desired_pixels = requested[0] * requested[1] if requested is not None else width * height
    desired_pixels = min(max(desired_pixels, GPT_IMAGE_2_MIN_PIXELS), GPT_IMAGE_2_MAX_PIXELS)
    effective_max_edge = min(max_edge or GPT_IMAGE_2_MAX_EDGE, GPT_IMAGE_2_MAX_EDGE)
    source_ratio = width / height
    candidates: list[tuple[float, tuple[int, int]]] = []
    for candidate_width in range(16, effective_max_edge + 1, 16):
        ideal_height = candidate_width / source_ratio
        height_steps = {max(1, math.floor(ideal_height / 16)), max(1, math.ceil(ideal_height / 16))}
        for height_step in height_steps:
            candidate_height = height_step * 16
            if candidate_height > effective_max_edge:
                continue
            pixels = candidate_width * candidate_height
            if not GPT_IMAGE_2_MIN_PIXELS <= pixels <= GPT_IMAGE_2_MAX_PIXELS:
                continue
            candidate_ratio = candidate_width / candidate_height
            if max(candidate_ratio, 1 / candidate_ratio) > GPT_IMAGE_2_MAX_ASPECT_RATIO:
                continue
            ratio_error = abs(math.log(candidate_ratio / source_ratio))
            area_error = abs(math.log(pixels / desired_pixels))
            candidates.append((ratio_error * 100 + area_error, (candidate_width, candidate_height)))

    if not candidates:
        raise EditMaskContractError(
            "edit_mask_canvas_unsupported",
            "The Primary Edit Image cannot be aligned to a supported Edit Mask canvas.",
        )
    return min(candidates, key=lambda candidate: candidate[0])[1]


def normalize_edit_mask_data_urls(
    primary_image_data_url: str,
    mask_data_url: str,
    *,
    target_size: tuple[int, int],
) -> tuple[str, str]:
    if len(target_size) != 2 or any(dimension <= 0 for dimension in target_size):
        raise ValueError("target_size must contain two positive dimensions")

    primary_bytes = decode_image_data_url(primary_image_data_url)
    mask_bytes = _decode_mask_data_url(mask_data_url)
    validate_edit_mask(mask_bytes, primary_bytes)

    try:
        with Image.open(BytesIO(primary_bytes)) as primary_source:
            primary_source.load()
            primary = primary_source.convert("RGBA")
        with Image.open(BytesIO(mask_bytes)) as mask_source:
            mask_source.load()
            mask = mask_source.convert("RGBA")
    except (UnidentifiedImageError, OSError, ValueError) as exc:
        raise EditMaskContractError("edit_mask_invalid", "The Edit Mask must be a valid PNG image.") from exc

    if primary.size != target_size:
        primary = primary.resize(target_size, Image.Resampling.LANCZOS)
        mask = mask.resize(target_size, Image.Resampling.NEAREST)

    primary_buffer = BytesIO()
    primary.save(primary_buffer, format="PNG")
    mask_buffer = BytesIO()
    mask.save(mask_buffer, format="PNG")
    normalized_primary = _png_data_url(primary_buffer.getvalue())
    normalized_mask = _png_data_url(mask_buffer.getvalue())
    validate_edit_mask_data_urls(normalized_mask, normalized_primary)
    return normalized_primary, normalized_mask


def _decode_mask_data_url(data_url: str) -> bytes:
    return _decode_image_data_url(
        data_url,
        code="edit_mask_invalid",
        message="The Edit Mask must be a valid PNG image.",
    )


def _decode_image_data_url(data_url: str, *, code: str, message: str) -> bytes:
    match = re.fullmatch(r"data:image/[^;,]+;base64,(.*)", str(data_url or ""), flags=re.DOTALL)
    if match is None:
        raise EditMaskContractError(code, message)
    try:
        return base64.b64decode(match.group(1), validate=True)
    except (ValueError, binascii.Error) as exc:
        raise EditMaskContractError(code, message) from exc


def _png_data_url(image_bytes: bytes) -> str:
    return f"data:image/png;base64,{base64.b64encode(image_bytes).decode('ascii')}"


def _parse_size(value: str | None) -> tuple[int, int] | None:
    match = re.fullmatch(r"([1-9]\d*)x([1-9]\d*)", str(value or "").strip().lower())
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


def is_explicit_edit_mask_rejection(exc: BaseException) -> bool:
    status = getattr(exc, "status", None) or getattr(exc, "status_code", None)
    message = str(exc).lower()
    return "mask" in message and (
        status in {400, 415, 422}
        or any(
            marker in message
            for marker in ("does not support", "not supported", "unsupported", "reject", "invalid")
        )
    )
