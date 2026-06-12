# Windows Portable Package

This package is intended for Windows x64 users who want to unzip and run the
WebUI without installing Python separately.

## How to use

1. Extract the zip package into a normal user directory, for example
   `D:\Apps\ilab-gpt-conjure`.
2. Double-click `Start WebUI Portable.bat`.
3. Open `http://127.0.0.1:8787/` if the browser does not open automatically.
4. Configure an OpenAI-compatible API provider in the WebUI before generating
   images, unless you intentionally use the advanced local OAuth mode.

## Directory layout

- `Start WebUI Portable.bat`: one-click WebUI launcher.
- `Update WebUI Portable.bat`: one-click updater for the latest GitHub Release.
- `app/`: iLab GPT Conjure source code and static WebUI assets.
- `python/`: embedded CPython runtime and installed WebUI dependencies.
- `data/`: local settings, gallery files, inputs, outputs, queue database, and
  logs created while using the app.

## Security notes

Do not put API keys, OAuth tokens, private prompts, input images, outputs, task
databases, or logs into GitHub issues or public repositories.

OpenAI-compatible API mode is the recommended stable integration path. The
optional Codex / ChatGPT OAuth mode is for personal local workflows only and is
not an officially recommended OpenAI API integration path.

## Upgrading

Close the WebUI server window, then double-click `Update WebUI Portable.bat`.
The updater downloads the latest Windows x64 portable package from GitHub
Releases, verifies its SHA256 file, replaces the app and bundled Python files,
and preserves the existing `data/` directory. A backup of replaced files is
saved under `.backup/`.

Do not move `data/` out of the package unless you are intentionally migrating
settings, gallery assets, history, outputs, and local task databases. For a
manual upgrade, extract the new package next to the old one and copy the old
`data/` directory into the new package.
