# Preserve editing guidance modes independently

The image editor retains Instruction Marks and the Edit Region as separate drafts over the same edited base image. Switching guidance modes never destroys either draft; only the active mode is materialized and submitted, preventing destructive mode switches while ensuring a request never mixes instruction marks with an Edit Mask. Both drafts and the active-mode choice persist with task history so reusing a task restores the complete editing state, while the inactive draft is never sent to the image provider.
