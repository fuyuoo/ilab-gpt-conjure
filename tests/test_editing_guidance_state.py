from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class EditingGuidanceStateTests(unittest.TestCase):
    def _run_module_probe(
        self,
        script: str,
        module: str = "codex_image/webui/frontend/src/editing-guidance-state.ts",
    ) -> dict[str, object]:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is required for Editing Guidance state tests")

        esbuild = shutil.which("esbuild", path=str(Path("node_modules/.bin").resolve()))
        if esbuild is None:
            self.skipTest("npm install is required for Editing Guidance state tests")

        with tempfile.TemporaryDirectory() as temp_dir:
            bundle = Path(temp_dir) / "editing-guidance-state.cjs"
            build = subprocess.run(
                [
                    esbuild,
                    module,
                    "--bundle",
                    "--platform=node",
                    "--format=cjs",
                    f"--outfile={bundle}",
                    "--log-level=warning",
                ],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            probe = subprocess.run(
                [node, "-e", script, str(bundle)],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(probe.returncode, 0, probe.stderr)
            return json.loads(probe.stdout)

    def test_instruction_marks_submission_keeps_edit_region_only_in_recovery_state(self) -> None:
        result = self._run_module_probe(
            """
            const { createEditingGuidanceState, saveEditingGuidance } = require(process.argv[1]);
            const state = createEditingGuidanceState({
              baseImage: { sourceId: "primary-1" },
              instructionMarks: { data: { strokes: ["arrow"] } },
              editRegion: { data: { pixels: [1, 2, 3] }, nonEmpty: true },
              activeGuidance: "instruction-marks",
            });
            process.stdout.write(JSON.stringify(saveEditingGuidance(state)));
            """
        )

        self.assertEqual(
            result["submission"],
            {
                "baseImage": {"sourceId": "primary-1"},
                "guidance": {
                    "type": "instruction-marks",
                    "draft": {"strokes": ["arrow"]},
                },
            },
        )
        self.assertEqual(
            result["recovery"]["editRegion"],
            {"data": {"pixels": [1, 2, 3]}, "nonEmpty": True},
        )
        self.assertEqual(result["recovery"]["version"], 1)

    def test_edit_region_submission_round_trips_versioned_recovery_state(self) -> None:
        result = self._run_module_probe(
            """
            const {
              createEditingGuidanceState,
              restoreEditingGuidanceState,
              saveEditingGuidance,
            } = require(process.argv[1]);
            const initial = createEditingGuidanceState({
              baseImage: { sourceId: "primary-2" },
              instructionMarks: { data: { strokes: ["circle"] } },
              editRegion: { data: { pixels: [7, 8] }, nonEmpty: true },
              activeGuidance: "edit-region",
            });
            const serialized = JSON.stringify(saveEditingGuidance(initial).recovery);
            const restored = restoreEditingGuidanceState(JSON.parse(serialized));
            process.stdout.write(JSON.stringify(saveEditingGuidance(restored)));
            """
        )

        self.assertEqual(
            result["submission"],
            {
                "baseImage": {"sourceId": "primary-2"},
                "guidance": {
                    "type": "edit-region",
                    "draft": {"pixels": [7, 8]},
                },
            },
        )
        self.assertEqual(
            result["recovery"]["instructionMarks"],
            {"data": {"strokes": ["circle"]}},
        )

    def test_edit_region_submission_rejects_a_missing_active_draft(self) -> None:
        result = self._run_module_probe(
            """
            const { createEditingGuidanceState, saveEditingGuidance } = require(process.argv[1]);
            const state = createEditingGuidanceState({
              baseImage: { sourceId: "primary-3" },
              instructionMarks: { data: { strokes: ["arrow"] } },
              editRegion: null,
              activeGuidance: "edit-region",
            });
            let error = null;
            try {
              saveEditingGuidance(state);
            } catch (cause) {
              error = cause.message;
            }
            process.stdout.write(JSON.stringify({ error }));
            """
        )

        self.assertEqual(
            result,
            {"error": "An active Edit Region must be non-empty before saving."},
        )

    def test_edit_region_pixels_materialize_as_provider_alpha_mask(self) -> None:
        result = self._run_module_probe(
            """
            const { legacyEditMaskPixelsToEditRegion, materializeEditMaskPixels } = require(process.argv[1]);
            const mask = materializeEditMaskPixels(2, 2, new Uint8ClampedArray([
              0, 0, 0, 0,
              255, 0, 0, 1,
              255, 0, 0, 128,
              255, 0, 0, 255,
            ]));
            const restored = legacyEditMaskPixelsToEditRegion(new Uint8ClampedArray([
              0, 0, 0, 255,
              0, 0, 0, 0,
            ]));
            process.stdout.write(JSON.stringify({ pixels: Array.from(mask), restored: Array.from(restored) }));
            """,
            "codex_image/webui/frontend/src/edit-region-materialization.ts",
        )

        self.assertEqual(
            result["pixels"],
            [
                0, 0, 0, 255,
                0, 0, 0, 0,
                0, 0, 0, 0,
                0, 0, 0, 0,
            ],
        )
        self.assertEqual(result["restored"], [255, 59, 48, 0, 255, 59, 48, 255])

    def test_mask_submission_is_edit_only_primary_only_and_active_only(self) -> None:
        result = self._run_module_probe(
            """
            const { editMaskForSubmission } = require(process.argv[1]);
            const primaryMask = { name: "primary-mask.png" };
            const referenceMask = { name: "reference-mask.png" };
            const sources = [
              { activeGuidance: "edit-region", editMaskFile: primaryMask },
              { activeGuidance: "edit-region", editMaskFile: referenceMask },
            ];
            process.stdout.write(JSON.stringify({
              edit: editMaskForSubmission("edit", sources)?.name || null,
              generate: editMaskForSubmission("generate", sources)?.name || null,
              instructionMarks: editMaskForSubmission("edit", [
                { activeGuidance: "instruction-marks", editMaskFile: primaryMask },
              ])?.name || null,
              referenceOnly: editMaskForSubmission("edit", [
                { activeGuidance: "instruction-marks" },
                { activeGuidance: "edit-region", editMaskFile: referenceMask },
              ])?.name || null,
            }));
            """,
            "codex_image/webui/frontend/src/edit-region-materialization.ts",
        )

        self.assertEqual(
            result,
            {
                "edit": "primary-mask.png",
                "generate": None,
                "instructionMarks": None,
                "referenceOnly": None,
            },
        )

    def test_active_edit_region_submission_requires_mask_and_uses_clean_images(self) -> None:
        result = self._run_module_probe(
            """
            const { editMaskForSubmission, imageFilesForSubmission } = require(process.argv[1]);
            const markedPrimary = { name: "marked-primary.png" };
            const instructionMarksDraft = { name: "instruction-marks-draft.png" };
            const cleanPrimary = { name: "clean-primary.png" };
            const markedReference = { name: "marked-reference.png" };
            const cleanReference = { name: "clean-reference.png" };
            const mask = { name: "edit-mask.png" };
            const sources = [
              {
                activeGuidance: "edit-region",
                file: markedPrimary,
                baseFile: cleanPrimary,
                instructionMarksFile: instructionMarksDraft,
                editMaskFile: mask,
              },
              {
                activeGuidance: "instruction-marks",
                file: markedReference,
                originalFile: cleanReference,
              },
            ];
            let missingMaskError = null;
            try {
              editMaskForSubmission("edit", [{ activeGuidance: "edit-region" }]);
            } catch (cause) {
              missingMaskError = cause.message;
            }
            process.stdout.write(JSON.stringify({
              missingMaskError,
              editFiles: imageFilesForSubmission("edit", sources).map((file) => file.name),
              generateFiles: imageFilesForSubmission("generate", sources).map((file) => file.name),
              instructionMarksFiles: imageFilesForSubmission("edit", [
                { activeGuidance: "instruction-marks", file: markedPrimary, baseFile: cleanPrimary },
              ]).map((file) => file.name),
            }));
            """,
            "codex_image/webui/frontend/src/edit-region-materialization.ts",
        )

        self.assertEqual(
            result,
            {
                "missingMaskError": "An active Edit Region requires a materialized Edit Mask.",
                "editFiles": ["clean-primary.png", "clean-reference.png"],
                "generateFiles": ["instruction-marks-draft.png", "marked-reference.png"],
                "instructionMarksFiles": ["marked-primary.png"],
            },
        )

    def test_task_mode_switch_submits_marks_only_in_generate_and_restores_edit_region(self) -> None:
        result = self._run_module_probe(
            """
            const {
              editMaskForSubmission,
              imageFilesForSubmission,
              instructionMarksAreSubmitted,
            } = require(process.argv[1]);
            const cleanPrimary = { name: "clean-primary.png" };
            const instructionMarks = { name: "instruction-marks.png" };
            const editMask = { name: "edit-mask.png" };
            const sources = [{
              activeGuidance: "edit-region",
              file: cleanPrimary,
              baseFile: cleanPrimary,
              instructionMarksFile: instructionMarks,
              editMaskFile: editMask,
            }];
            const generate = {
              files: imageFilesForSubmission("generate", sources).map((file) => file.name),
              mask: editMaskForSubmission("generate", sources)?.name || null,
              instructionMarksSubmitted: instructionMarksAreSubmitted("generate", sources),
            };
            const edit = {
              files: imageFilesForSubmission("edit", sources).map((file) => file.name),
              mask: editMaskForSubmission("edit", sources)?.name || null,
              instructionMarksSubmitted: instructionMarksAreSubmitted("edit", sources),
              activeGuidance: sources[0].activeGuidance,
            };
            process.stdout.write(JSON.stringify({ generate, edit }));
            """,
            "codex_image/webui/frontend/src/edit-region-materialization.ts",
        )

        self.assertEqual(
            result,
            {
                "generate": {
                    "files": ["instruction-marks.png"],
                    "mask": None,
                    "instructionMarksSubmitted": True,
                },
                "edit": {
                    "files": ["clean-primary.png"],
                    "mask": "edit-mask.png",
                    "instructionMarksSubmitted": False,
                    "activeGuidance": "edit-region",
                },
            },
        )

    def test_task_mode_switch_updates_prompt_hint_for_actual_submission(self) -> None:
        result = self._run_module_probe(
            """
            const { promptForEditingGuidanceSubmission } = require(process.argv[1]);
            const source = {
              activeGuidance: "edit-region",
              file: { name: "clean.png" },
              baseFile: { name: "clean.png" },
              instructionMarksFile: { name: "marks.png" },
              editMaskFile: { name: "mask.png" },
            };
            const currentHint = "Marks are instructions only.";
            const legacyHint = "Legacy marks hint.";
            const generate = promptForEditingGuidanceSubmission(
              `Change the shirt.\nEnglish marks hint.`,
              currentHint,
              [currentHint, legacyHint, "English marks hint."],
              "generate",
              [source],
            );
            const edit = promptForEditingGuidanceSubmission(
              generate,
              currentHint,
              [currentHint, legacyHint, "English marks hint."],
              "edit",
              [source],
            );
            const cleanGenerate = promptForEditingGuidanceSubmission(
              "Change the shirt.",
              currentHint,
              [currentHint, legacyHint, "English marks hint."],
              "generate",
              [{ activeGuidance: "edit-region", file: source.file, baseFile: source.baseFile }],
            );
            const markedEdit = promptForEditingGuidanceSubmission(
              "Change the shirt.",
              currentHint,
              [currentHint, legacyHint, "English marks hint."],
              "edit",
              [{ ...source, activeGuidance: "instruction-marks" }],
            );
            process.stdout.write(JSON.stringify({ generate, edit, cleanGenerate, markedEdit }));
            """,
            "codex_image/webui/frontend/src/edit-region-materialization.ts",
        )

        self.assertEqual(
            result,
            {
                "generate": "Change the shirt.\nMarks are instructions only.",
                "edit": "Change the shirt.",
                "cleanGenerate": "Change the shirt.",
                "markedEdit": "Change the shirt.\nMarks are instructions only.",
            },
        )

    def test_real_mode_control_preserves_both_drafts_across_round_trip(self) -> None:
        form_controls_path = json.dumps(str(Path("codex_image/webui/frontend/src/form-controls.ts").resolve()))
        script = """
            const fs = require("fs");
            const ts = require("typescript");
            const vm = require("vm");
            const guidance = require(process.argv[1]);
            const sourceCode = fs.readFileSync(__FORM_CONTROLS_PATH__, "utf8");
            const code = ts.transpileModule(sourceCode, {
              compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
            }).outputText;
            const source = {
              activeGuidance: "edit-region",
              file: { name: "clean-primary.png" },
              baseFile: { name: "clean-primary.png" },
              instructionMarksFile: { name: "instruction-marks.png" },
              editRegionFile: { name: "edit-region.png" },
              editMaskFile: { name: "edit-mask.png" },
            };
            const initialSource = JSON.stringify(source);
            const state = { mode: "edit", images: [source], runTimerId: null };
            const modeButtons = [
              { dataset: { mode: "generate" }, classList: { toggle() {} } },
              { dataset: { mode: "edit" }, classList: { toggle() {} } },
            ];
            let previewUpdates = 0;
            const bridge = { state, els: {}, methods: {} };
            const noop = () => {};
            const module = { exports: {} };
            vm.runInNewContext(code, {
              module,
              exports: module.exports,
              console,
              document: { querySelectorAll: () => modeButtons },
              require(name) {
                if (name === "./state") return { getLegacyBridge: () => bridge };
                if (name === "./output-controls") return {
                  syncRadioButtons: noop,
                  updateRequestPreview: () => { previewUpdates += 1; },
                };
                if (name === "./i18n") return {
                  LOCALE_CHANGE_EVENT: "locale-change",
                  translate: (key) => key,
                };
                return new Proxy({}, { get: () => noop });
              },
            });
            module.exports.setMode("generate");
            const generate = {
              mode: state.mode,
              files: guidance.imageFilesForSubmission(state.mode, state.images).map((file) => file.name),
              mask: guidance.editMaskForSubmission(state.mode, state.images)?.name || null,
            };
            module.exports.setMode("edit");
            const edit = {
              mode: state.mode,
              files: guidance.imageFilesForSubmission(state.mode, state.images).map((file) => file.name),
              mask: guidance.editMaskForSubmission(state.mode, state.images)?.name || null,
            };
            process.stdout.write(JSON.stringify({
              generate,
              edit,
              sourceUnchanged: JSON.stringify(source) === initialSource,
              previewUpdates,
            }));
        """.replace("__FORM_CONTROLS_PATH__", form_controls_path)
        result = self._run_module_probe(
            script,
            "codex_image/webui/frontend/src/edit-region-materialization.ts",
        )

        self.assertEqual(
            result,
            {
                "generate": {
                    "mode": "generate",
                    "files": ["instruction-marks.png"],
                    "mask": None,
                },
                "edit": {
                    "mode": "edit",
                    "files": ["clean-primary.png"],
                    "mask": "edit-mask.png",
                },
                "sourceUnchanged": True,
                "previewUpdates": 2,
            },
        )

    def test_task_persistence_maps_both_drafts_without_browser_urls_or_history(self) -> None:
        result = self._run_module_probe(
            """
            const {
              editingGuidanceForSubmission,
              loadEditingGuidanceFiles,
            } = require(process.argv[1]);
            const source = {
              baseFile: { name: "base.png" },
              instructionMarksFile: { name: "marks.png" },
              editRegionFile: { name: "region.png" },
              editMaskFile: { name: "mask.png" },
              activeGuidance: "edit-region",
              undoStack: ["must-not-persist"],
            };
            const submission = editingGuidanceForSubmission(source);
            const loaded = [];
            loadEditingGuidanceFiles({
              version: 1,
              activeGuidance: "edit-region",
              sharedBaseUrl: "/inputs/base",
              instructionMarksUrl: "/inputs/marks",
              editRegionUrl: "/inputs/region",
              editMaskUrl: "/inputs/mask",
            }, async (url, name) => {
              loaded.push(url);
              return { name };
            }).then((restored) => {
              process.stdout.write(JSON.stringify({ submission, restored, loaded }));
            });
            """,
            module="codex_image/webui/frontend/src/editing-guidance-persistence.ts",
        )

        self.assertEqual(result["submission"]["state"], {"version": 1, "activeGuidance": "edit-region"})
        self.assertEqual(
            list(result["submission"]["files"]),
            ["editing_shared_base", "editing_instruction_marks", "editing_edit_region", "editing_edit_mask"],
        )
        self.assertNotIn("undoStack", json.dumps(result["submission"]))
        self.assertEqual(result["loaded"], ["/inputs/base", "/inputs/marks", "/inputs/region", "/inputs/mask"])
        self.assertEqual(result["restored"]["activeGuidance"], "edit-region")
        self.assertEqual(result["restored"]["baseFile"]["name"], "shared-base.png")
        self.assertEqual(result["restored"]["instructionMarksFile"]["name"], "instruction-marks.png")
        self.assertEqual(result["restored"]["editRegionFile"]["name"], "edit-region.png")
        self.assertEqual(result["restored"]["editMaskFile"]["name"], "edit-mask.png")

    def test_missing_legacy_edit_mask_preserves_edit_region_guidance_with_stable_error(self) -> None:
        result = self._run_module_probe(
            """
            const { loadEditingGuidanceFiles } = require(process.argv[1]);
            loadEditingGuidanceFiles({
              version: 1,
              activeGuidance: "edit-region",
              legacyAlphaMask: true,
              sharedBaseUrl: "/inputs/base",
              editMaskUrl: "/inputs/missing-mask",
            }, async (url, name) => {
              if (url.includes("missing-mask")) throw new Error("404");
              return { name };
            }).then((restored) => {
              process.stdout.write(JSON.stringify(restored));
            });
            """,
            module="codex_image/webui/frontend/src/editing-guidance-persistence.ts",
        )

        self.assertEqual(result["activeGuidance"], "edit-region")
        self.assertEqual(result["baseFile"]["name"], "shared-base.png")
        self.assertIsNone(result["editMaskFile"])
        self.assertEqual(result["restoreError"], "legacy_edit_mask_unavailable")

    def test_fractional_crop_uses_one_bounded_integer_rectangle(self) -> None:
        result = self._run_module_probe(
            """
            const { finalCropRect } = require(process.argv[1]);
            process.stdout.write(JSON.stringify({
              fractional: finalCropRect(
                { left: 1.2, top: 2.7, width: 4.4, height: 3.2 },
                10,
                10,
              ),
              bounded: finalCropRect(
                { left: -2.1, top: 8.2, width: 20, height: 5 },
                10,
                10,
              ),
            }));
            """,
            "codex_image/webui/frontend/src/edit-region-materialization.ts",
        )

        self.assertEqual(
            result,
            {
                "fractional": {"left": 1, "top": 2, "width": 5, "height": 4},
                "bounded": {"left": 0, "top": 8, "width": 10, "height": 2},
            },
        )


if __name__ == "__main__":
    unittest.main()
