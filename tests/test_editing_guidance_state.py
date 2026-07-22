from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class EditingGuidanceStateTests(unittest.TestCase):
    def _run_module_probe(self, script: str) -> dict[str, object]:
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
                    "codex_image/webui/frontend/src/editing-guidance-state.ts",
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


if __name__ == "__main__":
    unittest.main()
