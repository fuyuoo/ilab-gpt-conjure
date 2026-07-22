from __future__ import annotations

import base64
import binascii
import re
from io import BytesIO

from PIL import Image, UnidentifiedImageError


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
