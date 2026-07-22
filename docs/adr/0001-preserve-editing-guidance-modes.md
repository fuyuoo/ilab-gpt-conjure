# Preserve editing guidance modes independently

The image editor retains Instruction Marks and the Edit Region as separate drafts over the same edited base image. Switching guidance modes never destroys either draft; for Edit requests, only the active mode is materialized and submitted, preventing destructive mode switches while ensuring a request never mixes instruction marks with an Edit Mask. Both drafts and the active-mode choice persist with task history so reusing a task restores the complete editing state, while the inactive draft is never sent as Editing Guidance.

Generate requests do not submit Editing Guidance or an Edit Mask. When an Instruction Marks draft exists, Generate may use its materialized image as an ordinary reference image; otherwise it uses the clean shared base. Returning to Edit restores both drafts and the previously active Editing Guidance.
