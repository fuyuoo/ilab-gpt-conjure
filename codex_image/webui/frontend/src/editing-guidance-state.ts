export const EDITING_GUIDANCE_STATE_VERSION = 1 as const;

export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };
export type EditingGuidanceType = "instruction-marks" | "edit-region";

export interface InstructionMarksDraft {
  data: JsonValue;
}

export interface EditRegionDraft {
  data: JsonValue;
  nonEmpty: true;
}

export interface EditingGuidanceState {
  version: typeof EDITING_GUIDANCE_STATE_VERSION;
  baseImage: JsonValue;
  instructionMarks: InstructionMarksDraft | null;
  editRegion: EditRegionDraft | null;
  activeGuidance: EditingGuidanceType;
}

export interface EditingGuidanceStateInput {
  baseImage: JsonValue;
  instructionMarks?: InstructionMarksDraft | null;
  editRegion?: EditRegionDraft | null;
  activeGuidance: EditingGuidanceType;
}

export interface MaterializedEditingGuidance {
  type: EditingGuidanceType;
  draft: JsonValue;
}

export interface SavedEditingGuidance {
  submission: {
    baseImage: JsonValue;
    guidance: MaterializedEditingGuidance | null;
  };
  recovery: EditingGuidanceState;
}

function cloneJson<T extends JsonValue>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function isJsonValue(value: unknown): value is JsonValue {
  if (value === null || typeof value === "string" || typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (Array.isArray(value)) return value.every(isJsonValue);
  if (typeof value !== "object") return false;
  return Object.values(value).every(isJsonValue);
}

function cloneInstructionMarksDraft(draft: InstructionMarksDraft): InstructionMarksDraft {
  return { data: cloneJson(draft.data) };
}

function cloneEditRegionDraft(draft: EditRegionDraft): EditRegionDraft {
  return { data: cloneJson(draft.data), nonEmpty: true };
}

export function createEditingGuidanceState(input: EditingGuidanceStateInput): EditingGuidanceState {
  return {
    version: EDITING_GUIDANCE_STATE_VERSION,
    baseImage: cloneJson(input.baseImage),
    instructionMarks: input.instructionMarks == null ? null : cloneInstructionMarksDraft(input.instructionMarks),
    editRegion: input.editRegion == null ? null : cloneEditRegionDraft(input.editRegion),
    activeGuidance: input.activeGuidance,
  };
}

export function restoreEditingGuidanceState(value: unknown): EditingGuidanceState {
  if (!value || typeof value !== "object") {
    throw new Error("Editing Guidance state must be an object.");
  }
  const candidate = value as Record<string, unknown>;
  if (candidate.version !== EDITING_GUIDANCE_STATE_VERSION) {
    throw new Error(`Unsupported Editing Guidance state version: ${String(candidate.version)}`);
  }
  if (!isJsonValue(candidate.baseImage)) {
    throw new Error("Editing Guidance base image must be JSON-serializable.");
  }
  const instructionMarks = candidate.instructionMarks as Record<string, unknown> | null;
  if (
    instructionMarks !== null
    && (
      !instructionMarks
      || typeof instructionMarks !== "object"
      || !isJsonValue(instructionMarks.data)
    )
  ) {
    throw new Error("Instruction Marks draft must contain JSON-serializable data or be null.");
  }
  const editRegion = candidate.editRegion as Record<string, unknown> | null;
  if (
    editRegion !== null
    && (
      !editRegion
      || typeof editRegion !== "object"
      || editRegion.nonEmpty !== true
      || !isJsonValue(editRegion.data)
    )
  ) {
    throw new Error("Edit Region draft must be explicitly non-empty and contain JSON-serializable data.");
  }
  if (candidate.activeGuidance !== "instruction-marks" && candidate.activeGuidance !== "edit-region") {
    throw new Error("Editing Guidance type is invalid.");
  }

  return createEditingGuidanceState({
    baseImage: candidate.baseImage,
    instructionMarks: instructionMarks as InstructionMarksDraft | null,
    editRegion: editRegion as EditRegionDraft | null,
    activeGuidance: candidate.activeGuidance,
  });
}

export function saveEditingGuidance(state: EditingGuidanceState): SavedEditingGuidance {
  if (state.activeGuidance === "edit-region" && state.editRegion == null) {
    throw new Error("An active Edit Region must be non-empty before saving.");
  }
  const activeDraft = state.activeGuidance === "instruction-marks"
    ? state.instructionMarks
    : state.editRegion;
  const recovery = createEditingGuidanceState(state);

  return {
    submission: {
      baseImage: cloneJson(state.baseImage),
      guidance: activeDraft == null
        ? null
        : {
          type: state.activeGuidance,
          draft: cloneJson(activeDraft.data),
        },
    },
    recovery,
  };
}
