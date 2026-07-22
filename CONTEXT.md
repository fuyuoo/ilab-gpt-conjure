# Image Editing

This context defines the image-editing artifacts users create when preparing reference images for AI-assisted generation and editing.

## Language

**Instruction Mark**:
A visible brush stroke, arrow, or filled region added to an input image to communicate an editing instruction to the model.
_Avoid_: Mask, selection

**Editing Guidance**:
The active guidance type for a Primary Edit Image: Instruction Marks or an Edit Region. Both types retain independent drafts, but only the active type is materialized and submitted for an edit request.
_Avoid_: Mixed submission

**Edit Mask**:
A system-generated, same-sized alpha image mechanically derived from the Edit Region on the final Primary Edit Image without semantic object recognition. It identifies the region the model may edit while leaving the source image unchanged; an edit task has at most one, and users never manage its file or alpha representation directly, but it is not a secret from the user who owns the task.
_Avoid_: Instruction mark, annotation

**Primary Edit Image**:
The first input image in an edit task and the only image to which an Edit Mask may belong; additional input images are references.
_Avoid_: Reference image, masked images

**Mask Tool**:
The image-editor tool used to paint and revise an Edit Region independently from Instruction Marks; the system converts that region into an Edit Mask when the edit is saved.
_Avoid_: Brush, annotation tool

**Edit Region**:
The non-empty, user-adjustable guidance area painted with the Mask Tool where the user wants the model to make changes. It may be rough and is the input from which the system derives the Edit Mask; mask-based editing is invalid until an Edit Region exists.
_Avoid_: Protected region, transparent area
