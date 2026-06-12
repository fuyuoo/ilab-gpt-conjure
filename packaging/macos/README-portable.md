# macOS Portable Package

This package is intended for macOS users who want to unzip and run the WebUI
without installing Python separately.

## How to use

1. Download the zip that matches your Mac:
   - `macos_portable_arm64` for Apple Silicon Macs.
   - `macos_portable_x64` for Intel Macs.
2. Extract the zip package into a normal user directory, for example
   `~/Applications/ilab-gpt-conjure`.
3. Double-click `Start WebUI Portable.command`.
4. Open `http://127.0.0.1:8787/` if the browser does not open automatically.
5. Configure an OpenAI-compatible API provider in the WebUI before generating
   images, unless you intentionally use the advanced local OAuth mode.

This is an unsigned portable zip. It is not a signed `.app`, not notarized, and
does not require an Apple Developer account to build. The launcher tries to
remove quarantine attributes from its own extracted folder before starting the
bundled Python framework. If macOS still blocks the package after download, use
one of these local actions:

- Right-click or Control-click `Start WebUI Portable.command`, choose Open, then
  confirm Open again in the macOS security prompt.
- Or remove quarantine from the extracted folder:

```bash
xattr -dr com.apple.quarantine /path/to/ilab-gpt-conjure_macos_portable_arm64
# or:
xattr -dr com.apple.quarantine /path/to/ilab-gpt-conjure_macos_portable_x64
```

## Directory layout

- `Start WebUI Portable.command`: one-click WebUI launcher.
- `Update WebUI Portable.command`: one-click updater for the latest GitHub
  Release matching this Mac architecture.
- `app/`: iLab GPT Conjure source code, static WebUI assets, and installed
  WebUI Python dependencies under `app/.deps`.
- `python/`: bundled Python.org Python framework.
- `data/`: local settings, gallery files, inputs, outputs, queue database, and
  logs created while using the app.

## Security notes

Do not put API keys, OAuth tokens, private prompts, input images, outputs, task
databases, or logs into GitHub issues or public repositories.

OpenAI-compatible API mode is the recommended stable integration path. The
optional Codex / ChatGPT OAuth mode is for personal local workflows only and is
not an officially recommended OpenAI API integration path.

## Upgrading

Close the WebUI server window, then double-click `Update WebUI Portable.command`.
The updater downloads the latest portable package for your Mac architecture from
GitHub Releases, verifies its SHA256 file, replaces the app and bundled Python
files, preserves the existing `data/` directory, and clears quarantine
attributes on the updated folder. A backup of replaced files is saved under
`.backup/`.

Do not move `data/` out of the package unless you are intentionally migrating
settings, gallery assets, history, outputs, and local task databases. For a
manual upgrade, extract the new package next to the old one and copy the old
`data/` directory into the new package.
