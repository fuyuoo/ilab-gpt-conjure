# Windows Portable Package

This package is intended for Windows x64 users who want to unzip and run the
WebUI without installing Python separately.

## How to use

1. Extract the zip package into a normal user directory, for example
   `D:\Apps\ilab-gpt-conjure`.
2. Double-click `Start WebUI Portable.bat`.
3. Open `http://127.0.0.1:8787/` if the browser does not open automatically.
4. Choose `Codex` if this machine has a local Codex / ChatGPT OAuth session, or
   configure an OpenAI-compatible API provider in the WebUI for the recommended
   stable integration path.

The startup launcher only starts the local WebUI server and opens the browser.
It does not contact GitHub or update files automatically. To check for and apply
updates, run `Update WebUI Portable.bat` manually.

## Directory layout

- `Start WebUI Portable.bat`: one-click WebUI launcher.
- `Update WebUI Portable.bat`: one-click updater for the latest GitHub Release.
- `app/`: iLab GPT Conjure source code, prebuilt static WebUI assets, and
  frontend package metadata/build config for source rebuilds.
- `python/`: embedded CPython runtime and installed WebUI dependencies.
- `data/`: local settings, gallery files, inputs, outputs, queue database, and
  logs created while using the app.

The portable startup launcher does not run `npm install` or rebuild frontend
assets. Node.js is only needed if you intentionally edit TypeScript or CSS and
rebuild `app/codex_image/webui/static/app.js` from source.

## Security notes

Do not put API keys, OAuth tokens, private prompts, input images, outputs, task
databases, or logs into GitHub issues or public repositories.

OpenAI-compatible API mode is the recommended stable integration path. The
optional Codex / ChatGPT OAuth mode defaults to the Codex Image channel for
personal local workflows only; it can be switched to the Responses compatibility
channel in API settings, but it is not an officially recommended OpenAI API
integration path.

## Upgrading

Close the WebUI server window, then double-click `Update WebUI Portable.bat`.
The updater prints the current version, latest version, selected release asset,
SHA256 file, and download URL before making changes. It downloads the latest
Windows x64 portable package from GitHub Releases, verifies its SHA256 file,
replaces only the package-managed app and bundled Python files inside this
portable folder, and preserves the existing `data/` directory. A backup of
replaced files is saved under `.backup/`.

If your local PowerShell policy blocks the updater, run it from a trusted local
PowerShell session according to your organization or device policy.

Do not move `data/` out of the package unless you are intentionally migrating
settings, gallery assets, history, outputs, and local task databases. For a
manual upgrade, extract the new package next to the old one and copy the old
`data/` directory into the new package.
