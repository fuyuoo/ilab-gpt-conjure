import { formatTranslation, LOCALE_CHANGE_EVENT } from "./i18n";
import { getLegacyBridge } from "./state";

const SMALL_EDIT_AREA_FRACTION = 0.005;
const LARGE_EDIT_AREA_FRACTION = 0.9;
const RESPONSES_EDIT_MASK_MAX_EDGE = 2048;
const GPT_IMAGE_2_MIN_PIXELS = 655_360;
const GPT_IMAGE_2_MAX_PIXELS = 8_294_400;
const GPT_IMAGE_2_MAX_ASPECT_RATIO = 3;

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
  mask_inactive: "editPreflight.maskInactive",
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

function formattedPercentage(editablePixels: number, totalPixels: number): string {
  const percentage = totalPixels > 0 ? (editablePixels / totalPixels) * 100 : 0;
  return percentage.toFixed(percentage < 10 ? 2 : 1);
}

function parsedSize(value: string): [number, number] | null {
  const match = /^([1-9][0-9]*)x([1-9][0-9]*)$/.exec(String(value || "").trim());
  if (!match) return null;
  return [Number(match[1]), Number(match[2])];
}

export function alignedResponsesEditMaskCanvasSize(
  width: number,
  height: number,
  requestedSize: string,
): [number, number] | null {
  const sourceWidth = positiveInteger(width);
  const sourceHeight = positiveInteger(height);
  if (!sourceWidth || !sourceHeight) return null;
  const sourceRatio = sourceWidth / sourceHeight;
  if (Math.max(sourceRatio, 1 / sourceRatio) > GPT_IMAGE_2_MAX_ASPECT_RATIO) return null;
  const requested = parsedSize(requestedSize);
  const requestedPixels = requested
    ? requested[0] * requested[1]
    : sourceWidth * sourceHeight;
  const desiredPixels = Math.min(
    Math.max(requestedPixels, GPT_IMAGE_2_MIN_PIXELS),
    GPT_IMAGE_2_MAX_PIXELS,
  );
  let best: { score: number; width: number; height: number } | null = null;
  for (let candidateWidth = 16; candidateWidth <= RESPONSES_EDIT_MASK_MAX_EDGE; candidateWidth += 16) {
    const idealHeight = candidateWidth / sourceRatio;
    const heightSteps = new Set([
      Math.max(1, Math.floor(idealHeight / 16)),
      Math.max(1, Math.ceil(idealHeight / 16)),
    ]);
    for (const heightStep of heightSteps) {
      const candidateHeight = heightStep * 16;
      if (candidateHeight > RESPONSES_EDIT_MASK_MAX_EDGE) continue;
      const pixels = candidateWidth * candidateHeight;
      if (pixels < GPT_IMAGE_2_MIN_PIXELS || pixels > GPT_IMAGE_2_MAX_PIXELS) continue;
      const candidateRatio = candidateWidth / candidateHeight;
      if (Math.max(candidateRatio, 1 / candidateRatio) > GPT_IMAGE_2_MAX_ASPECT_RATIO) continue;
      const ratioError = Math.abs(Math.log(candidateRatio / sourceRatio));
      const areaError = Math.abs(Math.log(pixels / desiredPixels));
      const score = ratioError * 100 + areaError;
      if (!best || score < best.score) {
        best = { score, width: candidateWidth, height: candidateHeight };
      }
    }
  }
  return best ? [best.width, best.height] : null;
}

export function evaluateEditRequestPreflight(input: EditRequestPreflightInput): EditRequestPreflightResult {
  if (input.mode !== "edit") return { issues: [] };
  if (!input.hasMask) return { issues: [{ code: "mask_inactive", level: "info" }] };
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
    const target = alignedResponsesEditMaskCanvasSize(width, height, input.outputSize);
    if (target) {
      issues.push({
        code: "responses_resize",
        level: "warning",
        values: {
          width,
          height,
          targetWidth: target[0],
          targetHeight: target[1],
        },
      });
    }
  }

  const editableFraction = editablePixels / totalPixels;
  issues.push({ code: "edit_area", level: "info", values: { percent: formattedPercentage(editablePixels, totalPixels) } });
  if (editableFraction > 0 && editableFraction <= SMALL_EDIT_AREA_FRACTION) {
    issues.push({ code: "edit_area_small", level: "warning" });
  } else if (editableFraction >= LARGE_EDIT_AREA_FRACTION) {
    issues.push({ code: "edit_area_large", level: "warning" });
  }

  return { issues };
}

export function responsesResizeConfirmationIssue(
  result: EditRequestPreflightResult,
): EditRequestPreflightIssue | null {
  return result.issues.find((issue) => issue.code === "responses_resize" && issue.level === "warning") || null;
}

export function responsesResizeConfirmationKey(
  issue: EditRequestPreflightIssue | null,
): string {
  if (!issue || issue.code !== "responses_resize") return "";
  const width = Number(issue.values?.width);
  const height = Number(issue.values?.height);
  const targetWidth = Number(issue.values?.targetWidth);
  const targetHeight = Number(issue.values?.targetHeight);
  if (![width, height, targetWidth, targetHeight].every((value) => Number.isInteger(value) && value > 0)) {
    return "";
  }
  return `${width}x${height}->${targetWidth}x${targetHeight}`;
}

export function pendingResponsesResizeConfirmation(
  result: EditRequestPreflightResult,
  approvedKey = "",
): { issue: EditRequestPreflightIssue; key: string } | null {
  const issue = responsesResizeConfirmationIssue(result);
  if (!issue) return null;
  const key = responsesResizeConfirmationKey(issue);
  return approvedKey === key ? null : { issue, key };
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
  if (state.mode !== "edit" || !primary) {
    return { issues: [] };
  }
  if (!(maskFile instanceof File)) {
    return evaluateEditRequestPreflight({
      mode: state.mode,
      hasMask: false,
      usesResponses: requestUsesResponses(request),
      primaryName: primary.name || primaryFile?.name || "",
      primaryWidth: 0,
      primaryHeight: 0,
      outputSize: String(request?.parameters?.["canvas.size"] || request?.size || ""),
      editablePixels: 0,
      totalPixels: 0,
    });
  }
  if (!(primaryFile instanceof File)) {
    return { issues: [{ code: "inspection_failed", level: "warning" }] };
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
      outputSize: String(request?.parameters?.["canvas.size"] || request?.size || ""),
      editablePixels: editMaskMetrics.editablePixels,
      totalPixels: editMaskMetrics.totalPixels,
    });
  } catch {
    return { issues: [{ code: "inspection_failed", level: "warning" }] };
  }
}

function setEditRequestPreflightOpen(open: boolean): void {
  const { els } = getLegacyBridge();
  els.editPreflightList?.classList.toggle("hidden", !open);
  els.editPreflightToggle?.setAttribute("aria-expanded", String(open));
  els.editPreflight?.closest(".prompt-panel")?.classList.toggle("edit-preflight-open", open);
}

function renderEditRequestPreflight(result: EditRequestPreflightResult): void {
  const { els } = getLegacyBridge();
  const panel = els.editPreflight;
  const summary = els.editPreflightSummary;
  const list = els.editPreflightList;
  lastRenderedResult = result;
  if (!panel || !list) return;
  list.replaceChildren();
  panel.classList.toggle("hidden", result.issues.length === 0);
  if (!result.issues.length) {
    setEditRequestPreflightOpen(false);
    panel.removeAttribute("data-level");
    if (summary) summary.textContent = "0";
    return;
  }
  const level = result.issues.some((issue) => issue.level === "error")
    ? "error"
    : result.issues.some((issue) => issue.level === "warning") ? "warning" : "info";
  panel.dataset.level = level;
  if (summary) summary.textContent = String(result.issues.length);
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
  const { els, methods } = getLegacyBridge();
  Object.assign(methods, { updateEditRequestPreflight });
  els.editPreflightToggle?.addEventListener("click", () => {
    const open = els.editPreflightToggle?.getAttribute("aria-expanded") !== "true";
    setEditRequestPreflightOpen(open);
  });
  document.addEventListener("click", (event) => {
    if (!els.editPreflight?.contains(event.target as Node)) setEditRequestPreflightOpen(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") setEditRequestPreflightOpen(false);
  });
  document.addEventListener(LOCALE_CHANGE_EVENT, () => renderEditRequestPreflight(lastRenderedResult));
}
