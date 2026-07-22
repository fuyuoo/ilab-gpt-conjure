import type { EditingGuidanceType } from "./editing-guidance-state";

export const EDITING_GUIDANCE_PERSISTENCE_VERSION = 1 as const;

export type EditingGuidanceRestoreError =
  | "legacy_edit_mask_unavailable"
  | "legacy_edit_mask_invalid";

export interface PersistedEditingGuidance {
  version: typeof EDITING_GUIDANCE_PERSISTENCE_VERSION;
  activeGuidance: EditingGuidanceType;
  legacyAlphaMask?: boolean;
  sharedBaseUrl?: string;
  instructionMarksUrl?: string;
  editRegionUrl?: string;
  editMaskUrl?: string;
}

type EditingGuidanceSource = {
  baseFile?: File | null;
  originalFile?: File | null;
  instructionMarksFile?: File | null;
  editRegionFile?: File | null;
  editMaskFile?: File | null;
  activeGuidance?: EditingGuidanceType;
};

export function editingGuidanceForSubmission(source: EditingGuidanceSource | null | undefined) {
  const activeGuidance = source?.activeGuidance;
  const sharedBase = source?.baseFile || source?.originalFile;
  if (!sharedBase || !["instruction-marks", "edit-region"].includes(String(activeGuidance))) return null;

  const files: Record<string, File> = { editing_shared_base: sharedBase };
  if (source?.instructionMarksFile) files.editing_instruction_marks = source.instructionMarksFile;
  if (source?.editRegionFile) files.editing_edit_region = source.editRegionFile;
  if (source?.editMaskFile) files.editing_edit_mask = source.editMaskFile;
  return {
    state: { version: EDITING_GUIDANCE_PERSISTENCE_VERSION, activeGuidance },
    files,
  };
}

type GuidanceFileLoader = (url: string, filename: string) => Promise<File>;

interface LoadedEditingGuidanceFiles {
  activeGuidance: EditingGuidanceType;
  baseFile: File;
  originalFile: File;
  instructionMarksFile: File | null;
  editRegionFile: File | null;
  editMaskFile: File | null;
  restoreError?: EditingGuidanceRestoreError;
}

export async function loadEditingGuidanceFiles(
  guidance: PersistedEditingGuidance | null | undefined,
  loadFile: GuidanceFileLoader,
): Promise<LoadedEditingGuidanceFiles | null> {
  if (
    guidance?.version !== EDITING_GUIDANCE_PERSISTENCE_VERSION
    || !["instruction-marks", "edit-region"].includes(String(guidance.activeGuidance))
    || !guidance.sharedBaseUrl
  ) return null;

  let legacyEditMaskUnavailable = false;
  const loadEditMask = () => guidance.editMaskUrl
    ? loadFile(guidance.editMaskUrl, "edit-mask.png").catch((error) => {
      if (!guidance.legacyAlphaMask) throw error;
      legacyEditMaskUnavailable = true;
      return null;
    })
    : Promise.resolve(null);
  const [baseFile, instructionMarksFile, editRegionFile, editMaskFile] = await Promise.all([
    loadFile(guidance.sharedBaseUrl, "shared-base.png"),
    guidance.instructionMarksUrl ? loadFile(guidance.instructionMarksUrl, "instruction-marks.png") : null,
    guidance.editRegionUrl ? loadFile(guidance.editRegionUrl, "edit-region.png") : null,
    loadEditMask(),
  ]);
  return {
    activeGuidance: guidance.activeGuidance,
    baseFile,
    originalFile: baseFile,
    instructionMarksFile,
    editRegionFile,
    editMaskFile,
    ...(legacyEditMaskUnavailable ? { restoreError: "legacy_edit_mask_unavailable" as const } : {}),
  };
}
