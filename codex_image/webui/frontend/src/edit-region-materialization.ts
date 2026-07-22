import type { EditingGuidanceType } from "./editing-guidance-state";

export type EditingGuidanceSubmissionSource = {
  activeGuidance?: EditingGuidanceType;
  file?: File | null;
  baseFile?: File | null;
  originalFile?: File | null;
  editMaskFile?: File | null;
};

export type FinalCropRect = {
  left: number;
  top: number;
  width: number;
  height: number;
};

export function finalCropRect(
  crop: FinalCropRect,
  canvasWidth: number,
  canvasHeight: number,
): FinalCropRect {
  const left = Math.max(0, Math.floor(crop.left));
  const top = Math.max(0, Math.floor(crop.top));
  const right = Math.min(canvasWidth, Math.ceil(crop.left + crop.width));
  const bottom = Math.min(canvasHeight, Math.ceil(crop.top + crop.height));
  return {
    left,
    top,
    width: Math.max(1, right - left),
    height: Math.max(1, bottom - top),
  };
}

export function materializeEditMaskPixels(
  width: number,
  height: number,
  editRegionPixels: Uint8ClampedArray,
): Uint8ClampedArray {
  const pixelCount = width * height;
  if (width < 1 || height < 1 || editRegionPixels.length !== pixelCount * 4) {
    throw new Error("Edit Region dimensions must match the final Primary Edit Image.");
  }
  const mask = new Uint8ClampedArray(pixelCount * 4);
  for (let pixel = 0; pixel < pixelCount; pixel += 1) {
    const offset = pixel * 4;
    mask[offset] = 0;
    mask[offset + 1] = 0;
    mask[offset + 2] = 0;
    mask[offset + 3] = (editRegionPixels[offset + 3] ?? 0) > 0 ? 0 : 255;
  }
  return mask;
}

export function editRegionHasPixels(editRegionPixels: Uint8ClampedArray): boolean {
  for (let offset = 3; offset < editRegionPixels.length; offset += 4) {
    if ((editRegionPixels[offset] ?? 0) > 0) return true;
  }
  return false;
}

export function editMaskForSubmission(
  mode: string,
  sources: EditingGuidanceSubmissionSource[],
): File | null {
  if (mode !== "edit") return null;
  const primary = sources[0];
  if (primary?.activeGuidance !== "edit-region") return null;
  if (!primary.editMaskFile) {
    throw new Error("An active Edit Region requires a materialized Edit Mask.");
  }
  return primary.editMaskFile;
}

export function imageFilesForSubmission(
  mode: string,
  sources: EditingGuidanceSubmissionSource[],
): File[] {
  const useCleanImages = Boolean(editMaskForSubmission(mode, sources));
  return sources.flatMap((source) => {
    const file = useCleanImages
      ? source.baseFile || source.originalFile || source.file
      : source.file;
    return file ? [file] : [];
  });
}
