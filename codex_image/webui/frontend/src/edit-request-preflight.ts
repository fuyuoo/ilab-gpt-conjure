import { formatTranslation, LOCALE_CHANGE_EVENT } from "./i18n";
import { getLegacyBridge } from "./state";

const RESPONSES_EDIT_MASK_MAX_EDGE = 2048;
const ASPECT_RATIO_WARNING_FACTOR = 1.25;
const SMALL_EDIT_AREA_FRACTION = 0.005;
const LARGE_EDIT_AREA_FRACTION = 0.9;

export type EditRequestPreflightLevel = "info" | "warning" | "error";

export type EditRequestPreflightIssue = {
  code: string;
  level: EditRequestPreflightLevel;
  values?: Record<string, string | number>;
};

export type EditRequestPreflightResult = {
  issues: EditRequestPreflightIssue[];
};

export type EditRequestPreflightInput = {
  mode: string;
  hasMask: boolean;
  usesResponses: boolean;
  primaryName: string;
  primaryWidth: number;
  primaryHeight: number;
  maskWidth?: number;
  maskHeight?: number;
  outputSize: string;
  editablePixels: number;
  totalPixels: number;
};

type ImageDimensions = { width: number; height: number };
type MaskMetrics = ImageDimensions & { editablePixels: number; totalPixels: number };

const imageDimensionsCache = new WeakMap<File, Promise<ImageDimensions>>();
const maskMetricsCache = new WeakMap<File, Promise<MaskMetrics>>();
let renderGeneration = 0;
let lastRenderedResult: EditRequestPreflightResult = { issues: [] };

const ISSUE_TRANSLATION_KEYS: Record<string, string> = {
  mask_dimensions_mismatch: "editPreflight.maskDimensionsMismatch",
  empty_edit_area: "editPreflight.emptyEditArea",
  primary: "editPreflight.primary",
  responses_resize: "editPreflight.responsesResize",
  edit_area: "editPreflight.editArea",
  edit_area_small: "editPreflight.editAreaSmall",
  edit_area_large: "editPreflight.editAreaLarge",
  aspect_mismatch: "editPreflight.aspectMismatch",
  inspection_failed: "editPreflight.inspectionFailed",
};

function positiveInteger(value: unknown): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? Math.round(parsed) : 0;
}

function greatestCommonDivisor(left: number, right: number): number {
  let a = Math.abs(Math.round(left));
  let b = Math.abs(Math.round(right));
  while (b) [a, b] = [b, a % b];
  return a || 1;
}

function ratioLabel(width: number, height: number): string {
  const divisor = greatestCommonDivisor(width, height);
  return `${Math.round(width / divisor)}:${Math.round(height / divisor)}`;
}

function parsedOutputSize(value: string): ImageDimensions | null {
  const match = /^(\d+)x(\d+)$/i.exec(String(value || "").trim());
  if (!match) return null;
  const width = positiveInteger(match[1]);
  const height = positiveInteger(match[2]);
  return width && height ? { width, height } : null;
}

function resizedDimensions(width: number, height: number): ImageDimensions {
  const scale = RESPONSES_EDIT_MASK_MAX_EDGE / Math.max(width, height);
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

function formattedPercentage(editablePixels: number, totalPixels: number): string {
  const percentage = totalPixels > 0 ? (editablePixels / totalPixels) * 100 : 0;
  return percentage.toFixed(percentage < 10 ? 2 : 1);
}

export function evaluateEditRequestPreflight(input: EditRequestPreflightInput): EditRequestPreflightResult {
  if (input.mode !== "edit" || !input.hasMask) return { issues: [] };
  const width = positiveInteger(input.primaryWidth);
  const height = positiveInteger(input.primaryHeight);
  const totalPixels = positiveInteger(input.totalPixels);
  const editablePixels = Math.min(totalPixels, Math.max(0, Math.round(Number(input.editablePixels) || 0)));
  if (!width || !height || !totalPixels) return { issues: [] };

  const issues: EditRequestPreflightIssue[] = [];
  const maskWidth = positiveInteger(input.maskWidth);
  const maskHeight = positiveInteger(input.maskHeight);
  if (maskWidth && maskHeight && (maskWidth !== width || maskHeight !== height)) {
    issues.push({
      code: "mask_dimensions_mismatch",
      level: "error",
      values: { width, height, maskWidth, maskHeight },
    });
  }
  if (editablePixels === 0) issues.push({ code: "empty_edit_area", level: "error" });
  issues.push({ code: "primary", level: "info", values: { name: input.primaryName || "-" } });
  if (input.usesResponses && Math.max(width, height) > RESPONSES_EDIT_MASK_MAX_EDGE) {
    const target = resizedDimensions(width, height);
    issues.push({
      code: "responses_resize",
      level: "info",
      values: { width, height, targetWidth: target.width, targetHeight: target.height },
    });
  }

  const editableFraction = editablePixels / totalPixels;
  issues.push({ code: "edit_area", level: "info", values: { percent: formattedPercentage(editablePixels, totalPixels) } });
  if (editableFraction > 0 && editableFraction <= SMALL_EDIT_AREA_FRACTION) {
    issues.push({ code: "edit_area_small", level: "warning" });
  } else if (editableFraction >= LARGE_EDIT_AREA_FRACTION) {
    issues.push({ code: "edit_area_large", level: "warning" });
  }

  const output = parsedOutputSize(input.outputSize);
  if (output) {
    const sourceAspect = width / height;
    const outputAspect = output.width / output.height;
    const difference = Math.max(sourceAspect / outputAspect, outputAspect / sourceAspect);
    if (difference >= ASPECT_RATIO_WARNING_FACTOR) {
      issues.push({
        code: "aspect_mismatch",
        level: "warning",
        values: { sourceRatio: ratioLabel(width, height), outputRatio: ratioLabel(output.width, output.height) },
      });
    }
  }
  return { issues };
}

async function imageDimensions(file: File): Promise<ImageDimensions> {
  const cached = imageDimensionsCache.get(file);
  if (cached) return cached;
  const pending = createImageBitmap(file).then((bitmap) => {
    const dimensions = { width: bitmap.width, height: bitmap.height };
    bitmap.close?.();
    return dimensions;
  });
  imageDimensionsCache.set(file, pending);
  return pending;
}

async function maskMetrics(file: File): Promise<MaskMetrics> {
  const cached = maskMetricsCache.get(file);
  if (cached) return cached;
  const pending = createImageBitmap(file).then((bitmap) => {
    const canvas = document.createElement("canvas");
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) throw new Error("Mask canvas is unavailable");
    context.drawImage(bitmap, 0, 0);
    bitmap.close?.();
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
    let editablePixels = 0;
    for (let offset = 3; offset < pixels.length; offset += 4) {
      if ((pixels[offset] ?? 255) < 128) editablePixels += 1;
    }
    return { width: canvas.width, height: canvas.height, editablePixels, totalPixels: canvas.width * canvas.height };
  });
  maskMetricsCache.set(file, pending);
  return pending;
}

function requestUsesResponses(request: any): boolean {
  return String(request?.requested_backend || "").endsWith("_responses")
    || request?.endpoint === "/responses"
    || request?.api_mode === "responses"
    || request?.codex_mode === "responses";
}

async function inspectCurrentEditRequest(request: any): Promise<EditRequestPreflightResult> {
  const state = getLegacyBridge().state;
  const primary: any = state.images[0];
  const maskFile = primary?.activeGuidance === "edit-region" ? primary.editMaskFile : null;
  const primaryFile = primary?.baseFile || primary?.originalFile || primary?.file;
  if (state.mode !== "edit" || !(maskFile instanceof File) || !(primaryFile instanceof File)) {
    return { issues: [] };
  }
  try {
    const [primaryMetrics, editMaskMetrics] = await Promise.all([
      imageDimensions(primaryFile),
      maskMetrics(maskFile),
    ]);
    return evaluateEditRequestPreflight({
      mode: state.mode,
      hasMask: true,
      usesResponses: requestUsesResponses(request),
      primaryName: primary.name || primaryFile.name,
      primaryWidth: primaryMetrics.width,
      primaryHeight: primaryMetrics.height,
      maskWidth: editMaskMetrics.width,
      maskHeight: editMaskMetrics.height,
      outputSize: String(request?.size || ""),
      editablePixels: editMaskMetrics.editablePixels,
      totalPixels: editMaskMetrics.totalPixels,
    });
  } catch {
    return { issues: [{ code: "inspection_failed", level: "warning" }] };
  }
}

function renderEditRequestPreflight(result: EditRequestPreflightResult): void {
  const { els } = getLegacyBridge();
  const panel = els.editPreflight;
  const list = els.editPreflightList;
  lastRenderedResult = result;
  if (!panel || !list) return;
  list.replaceChildren();
  panel.classList.toggle("hidden", result.issues.length === 0);
  result.issues.forEach((issue) => {
    const item = document.createElement("div");
    item.className = `edit-preflight-item ${issue.level}`;
    const icon = document.createElement("span");
    icon.className = "edit-preflight-icon";
    icon.textContent = issue.level === "warning" ? "!" : issue.level === "error" ? "×" : "i";
    const message = document.createElement("span");
    message.textContent = formatTranslation(ISSUE_TRANSLATION_KEYS[issue.code] || issue.code, issue.values);
    item.append(icon, message);
    list.append(item);
  });
}

export async function updateEditRequestPreflight(request: any): Promise<EditRequestPreflightResult> {
  const generation = ++renderGeneration;
  const result = await inspectCurrentEditRequest(request);
  if (generation === renderGeneration) renderEditRequestPreflight(result);
  return result;
}

export function initEditRequestPreflightFeature(): void {
  Object.assign(getLegacyBridge().methods, { updateEditRequestPreflight });
  document.addEventListener(LOCALE_CHANGE_EVENT, () => renderEditRequestPreflight(lastRenderedResult));
}
