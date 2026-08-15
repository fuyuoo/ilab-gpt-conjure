export type GenerationErrorPresentation = {
  key: string;
  values: Record<string, string | number>;
};

const SAFE_SIZE = /^[1-9][0-9]{0,5}x[1-9][0-9]{0,5}$/;
const SAFE_IDENTIFIER = /^[A-Za-z0-9._:-]{1,100}$/;
const SAFE_TASK_ID = /^[A-Za-z0-9._:-]{1,160}$/;

function safeText(value: unknown, pattern: RegExp): string {
  const text = String(value || "").trim();
  return pattern.test(text) ? text : "-";
}

export function generationErrorPresentation(task: any): GenerationErrorPresentation | null {
  const error = task?.generation_error;
  const details = error?.details;
  if (error?.code !== "edit_mask_canvas_snapshot_mismatch" || !details || typeof details !== "object") {
    return null;
  }
  const queuedSize = safeText(details.queued_size, SAFE_SIZE);
  const executionSize = safeText(details.execution_size, SAFE_SIZE);
  const maxEdge = Number(details.provider_max_edge);
  if (queuedSize === "-" || executionSize === "-" || !Number.isInteger(maxEdge) || maxEdge <= 0 || maxEdge > 100_000) {
    return null;
  }
  return {
    key: "generationError.editMaskCanvasSnapshotMismatch",
    values: {
      taskId: safeText(task?.task_id, SAFE_TASK_ID),
      providerId: safeText(error.provider_id, SAFE_IDENTIFIER),
      modelId: safeText(error.canonical_model_id, SAFE_IDENTIFIER),
      queuedSize,
      executionSize,
      maxEdge,
    },
  };
}
