# Apodexis for VS Code

View, validate, and navigate [Apodexis](https://github.com/TSUITUENYUE/Apodexis)
proof graphs without leaving your editor. Works in VS Code and VS Code forks
(Cursor, VSCodium). Zero dependencies — plain JavaScript.

## Features

- **Show Proof Graph** — renders `apodexis.json` as the familiar Apodexis canvas
  (chip nodes, curved typed edges, dash patterns per relation family) in a
  webview. Pan by dragging, zoom with the scroll wheel, filter by branch, and
  the view refreshes on save. Click a node for its statement and status; if it
  has a `sourceFile`, one click jumps to that file and line.
- **Validate Proof Graph** — deep integrity checks (duplicate ids, dangling
  edges, invalid enum values) reported in the Problems panel.
- **Schema-backed editing** — red squiggles and autocompletion for every field
  and enum while editing `apodexis.json` by hand, in both supported formats.

Both Apodexis JSON formats are understood: the simple import format
(`from`/`to`, string ids, positions optional — laid out automatically) and the
format the macOS app saves (`sourceID`/`targetID`, UUIDs, saved positions).

## Install

Not on the marketplace; install by copying the folder:

```sh
# VS Code
cp -R integrations/vscode-apodexis ~/.vscode/extensions/apodexis.vscode-apodexis-0.1.0
# Cursor
cp -R integrations/vscode-apodexis ~/.cursor/extensions/apodexis.vscode-apodexis-0.1.0
```

Restart the editor. Open a folder containing an `apodexis.json`, then run
**Apodexis: Show Proof Graph** from the command palette (or click the graph
icon in the editor title bar when an `apodexis.json` is open).

## Development

Pure-logic tests (no VS Code needed):

```sh
node test/run.js                       # against the bundled sqrt2 example
node test/run.js path/to/apodexis.json # plus an app-saved file
```

`lib/graphModel.js` (normalize/validate/layout) and `media/renderer.js` (SVG)
are dependency-free modules shared by the extension host, the webview, and the
tests.
