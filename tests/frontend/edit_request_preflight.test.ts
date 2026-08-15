import assert from "node:assert/strict";
import test from "node:test";

import {
  evaluateEditRequestPreflight,
  pendingResponsesResizeConfirmation,
  responsesResizeConfirmationKey,
  responsesResizeConfirmationIssue,
} from "../../codex_image/webui/frontend/src/edit-request-preflight";
import { generationErrorPresentation } from "../../codex_image/webui/frontend/src/generation-error-presentation";

function input(overrides: Record<string, unknown> = {}) {
  return {
    mode: "edit",
    hasMask: true,
    usesResponses: true,
    primaryName: "input.png",
    primaryWidth: 3081,
    primaryHeight: 1359,
    maskWidth: 3081,
    maskHeight: 1359,
    outputSize: "3072x1360",
    editablePixels: 100,
    totalPixels: 3081 * 1359,
    ...overrides,
  };
}

test("responses mask preflight reports the deterministic temporary resize", () => {
  const result = evaluateEditRequestPreflight(input());
  assert.deepEqual(
    result.issues.find((issue) => issue.code === "responses_resize"),
    {
      code: "responses_resize",
      level: "warning",
      values: {
        width: 3081,
        height: 1359,
        targetWidth: 2032,
        targetHeight: 896,
      },
    },
  );
});

test("responses mask preflight does not warn when the input is already within the limit", () => {
  const result = evaluateEditRequestPreflight(input({
    primaryWidth: 1536,
    primaryHeight: 1024,
    maskWidth: 1536,
    maskHeight: 1024,
    outputSize: "1536x1024",
    totalPixels: 1536 * 1024,
  }));
  assert.equal(result.issues.some((issue) => issue.code === "responses_resize"), false);
});

test("only a responses resize warning requires explicit resize confirmation", () => {
  const resizeResult = evaluateEditRequestPreflight(input());
  const resizeIssue = responsesResizeConfirmationIssue(resizeResult);
  assert.equal(resizeIssue?.code, "responses_resize");
  assert.equal(responsesResizeConfirmationKey(resizeIssue), "3081x1359->2032x896");
  assert.notEqual(
    responsesResizeConfirmationKey(
      responsesResizeConfirmationIssue(
        evaluateEditRequestPreflight(input({ outputSize: "1024x1024" })),
      ),
    ),
    responsesResizeConfirmationKey(resizeIssue),
  );
  assert.equal(
    responsesResizeConfirmationIssue({
      issues: [{ code: "edit_area_small", level: "warning" }],
    }),
    null,
  );
});

test("resize approval is valid only for the exact current resize fingerprint", () => {
  const initial = evaluateEditRequestPreflight(input());
  const firstDecision = pendingResponsesResizeConfirmation(initial);
  if (!firstDecision) throw new Error("expected initial resize confirmation");
  assert.equal(pendingResponsesResizeConfirmation(initial, firstDecision.key), null);

  const changed = evaluateEditRequestPreflight(input({ outputSize: "1536x1024" }));
  const changedDecision = pendingResponsesResizeConfirmation(changed, firstDecision.key);
  if (!changedDecision) throw new Error("expected stale confirmation to require approval");
  assert.notEqual(changedDecision.key, firstDecision.key);
});

test("mask snapshot mismatch exposes only actionable safe fields", () => {
  assert.deepEqual(
    generationErrorPresentation({
      task_id: "task-mask-mismatch",
      generation_error: {
        code: "edit_mask_canvas_snapshot_mismatch",
        message: "generic",
        provider_id: "codex",
        canonical_model_id: "gpt-image-2",
        protocol_profile: "codex_responses",
        details: {
          queued_size: "3072x1360",
          execution_size: "2032x896",
          provider_max_edge: 2048,
          recommended_action: "reuse_task",
          prompt: "must-not-leak",
          api_key: "must-not-leak",
        },
      },
    }),
    {
      key: "generationError.editMaskCanvasSnapshotMismatch",
      values: {
        taskId: "task-mask-mismatch",
        providerId: "codex",
        modelId: "gpt-image-2",
        queuedSize: "3072x1360",
        executionSize: "2032x896",
        maxEdge: 2048,
      },
    },
  );
});
