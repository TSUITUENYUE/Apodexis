// Apodexis for VS Code: renders apodexis.json proof graphs in a webview panel,
// validates them, and jumps from nodes to their sourceFile:sourceLine.

'use strict';

const vscode = require('vscode');
const path = require('path');
const { normalize, validate, layout } = require('./lib/graphModel');

let panel = null;
let currentGraphUri = null;

function activate(context) {
  const diagnostics = vscode.languages.createDiagnosticCollection('apodexis');
  context.subscriptions.push(diagnostics);

  context.subscriptions.push(
    vscode.commands.registerCommand('apodexis.showGraph', () => showGraph(context)),
    vscode.commands.registerCommand('apodexis.validate', () => runValidation(diagnostics)),
    vscode.workspace.onDidSaveTextDocument((document) => {
      if (currentGraphUri && document.uri.toString() === currentGraphUri.toString()) {
        refreshPanel(document);
      }
      if (isGraphFileName(document.uri) && diagnostics.has(document.uri)) {
        applyDiagnostics(diagnostics, document);
      }
    })
  );
}

function isGraphFileName(uri) {
  const name = path.basename(uri.fsPath).toLowerCase();
  return name === 'apodexis.json' || name === 'proof-chain.json';
}

/// The active editor's graph if it is one, otherwise the workspace's apodexis.json.
async function findGraphDocument() {
  const active = vscode.window.activeTextEditor;
  if (active && active.document.languageId === 'json') {
    try {
      const parsed = JSON.parse(active.document.getText());
      if (Array.isArray(parsed.nodes)) return active.document;
    } catch (error) { /* fall through to workspace search */ }
  }
  const found = await vscode.workspace.findFiles('**/apodexis.json', '**/node_modules/**', 1);
  if (found.length > 0) return vscode.workspace.openTextDocument(found[0]);
  return null;
}

async function showGraph(context) {
  const document = await findGraphDocument();
  if (!document) {
    vscode.window.showInformationMessage('Apodexis: no apodexis.json found — open one or add it to the workspace.');
    return;
  }
  currentGraphUri = document.uri;

  if (!panel) {
    panel = vscode.window.createWebviewPanel(
      'apodexisGraph',
      'Apodexis Graph',
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [vscode.Uri.file(path.join(context.extensionPath, 'media'))]
      }
    );
    panel.onDidDispose(() => { panel = null; currentGraphUri = null; });
    panel.webview.onDidReceiveMessage((message) => {
      if (message && message.type === 'openSource') openSource(message.file, message.line);
    });
  } else {
    panel.reveal(undefined, true);
  }

  panel.webview.html = buildWebviewHtml(context, panel.webview, parseModel(document));
}

function parseModel(document) {
  try {
    return layout(normalize(JSON.parse(document.getText())));
  } catch (error) {
    return { title: `Parse error: ${error.message}`, branches: [], nodes: [], edges: [] };
  }
}

function refreshPanel(document) {
  if (!panel) return;
  panel.webview.postMessage({ type: 'update', model: parseModel(document) });
}

async function openSource(file, line) {
  if (!file || !currentGraphUri) return;
  const base = path.dirname(currentGraphUri.fsPath);
  const target = path.isAbsolute(file) ? file : path.join(base, file);
  try {
    const document = await vscode.workspace.openTextDocument(target);
    const editor = await vscode.window.showTextDocument(document, vscode.ViewColumn.One);
    const at = new vscode.Position(Math.max(0, (line || 1) - 1), 0);
    editor.selection = new vscode.Selection(at, at);
    editor.revealRange(new vscode.Range(at, at), vscode.TextEditorRevealType.InCenter);
  } catch (error) {
    vscode.window.showWarningMessage(`Apodexis: couldn't open ${file}.`);
  }
}

async function runValidation(diagnostics) {
  const document = await findGraphDocument();
  if (!document) {
    vscode.window.showInformationMessage('Apodexis: no apodexis.json found to validate.');
    return;
  }
  const count = applyDiagnostics(diagnostics, document);
  if (count === 0) {
    vscode.window.showInformationMessage('Apodexis: graph is valid — it will import cleanly.');
  } else {
    vscode.window.showWarningMessage(`Apodexis: ${count} problem${count === 1 ? '' : 's'} found — see the Problems panel.`);
    vscode.commands.executeCommand('workbench.actions.view.problems');
  }
}

function applyDiagnostics(diagnostics, document) {
  let problems;
  try {
    problems = validate(JSON.parse(document.getText()));
  } catch (error) {
    problems = [{ message: `Not valid JSON: ${error.message}`, anchor: null }];
  }
  const text = document.getText();
  const items = problems.map((problem) => {
    let range = new vscode.Range(0, 0, 0, 1);
    if (problem.anchor) {
      const index = text.indexOf(`"${problem.anchor}"`);
      if (index >= 0) {
        range = new vscode.Range(
          document.positionAt(index + 1),
          document.positionAt(index + 1 + problem.anchor.length)
        );
      }
    }
    return new vscode.Diagnostic(range, problem.message, vscode.DiagnosticSeverity.Error);
  });
  diagnostics.set(document.uri, items);
  return items.length;
}

function buildWebviewHtml(context, webview, model) {
  const rendererUri = webview.asWebviewUri(
    vscode.Uri.file(path.join(context.extensionPath, 'media', 'renderer.js'))
  );
  const nonce = Math.random().toString(36).slice(2);
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
  :root { --chip-bg: var(--vscode-editorWidget-background); --chip-border: var(--vscode-widget-border, rgba(128,128,128,0.35)); --chip-text: var(--vscode-foreground); }
  body { margin: 0; padding: 0; font-family: var(--vscode-font-family); color: var(--vscode-foreground); overflow: hidden; }
  #toolbar { display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-bottom: 1px solid var(--chip-border); }
  #toolbar h1 { font-size: 13px; margin: 0; font-weight: 600; flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  #toolbar .meta { font-size: 11px; opacity: 0.7; white-space: nowrap; }
  select { background: var(--vscode-dropdown-background); color: var(--vscode-dropdown-foreground); border: 1px solid var(--chip-border); border-radius: 4px; padding: 2px 6px; font-size: 12px; }
  #viewport { position: absolute; top: 37px; bottom: 0; left: 0; right: 0; overflow: hidden; cursor: grab; }
  #viewport.panning { cursor: grabbing; }
  #stage { transform-origin: 0 0; }
  #detail { position: absolute; left: 12px; right: 12px; bottom: 12px; background: var(--chip-bg); border: 1px solid var(--chip-border); border-radius: 8px; padding: 10px 14px; font-size: 12px; display: none; max-height: 30%; overflow: auto; }
  #detail.visible { display: block; }
  #detail .title { font-weight: 700; margin-bottom: 4px; }
  #detail .statement { opacity: 0.85; white-space: pre-wrap; }
  #detail a { color: var(--vscode-textLink-foreground); cursor: pointer; }
  g.node.selected rect.chip { stroke: var(--vscode-focusBorder); stroke-width: 2.5; }
</style>
</head>
<body>
<div id="toolbar">
  <h1 id="title"></h1>
  <span class="meta" id="meta"></span>
  <select id="branch"></select>
</div>
<div id="viewport"><div id="stage"></div></div>
<div id="detail"></div>
<script nonce="${nonce}" src="${rendererUri}"></script>
<script nonce="${nonce}">
(function () {
  const vscodeApi = acquireVsCodeApi();
  let model = ${JSON.stringify(model)};
  let branchID = model.branches.length > 1 ? model.branches[0].id : null;
  let scale = 1, panX = 20, panY = 20;

  const stage = document.getElementById('stage');
  const viewport = document.getElementById('viewport');
  const branchSelect = document.getElementById('branch');
  const detail = document.getElementById('detail');

  function applyTransform() {
    stage.style.transform = 'translate(' + panX + 'px,' + panY + 'px) scale(' + scale + ')';
  }

  function render() {
    document.getElementById('title').textContent = model.title;
    const shown = model.nodes.filter(function (n) { return !branchID || n.branchID === branchID; });
    document.getElementById('meta').textContent = shown.length + ' nodes · ' + model.edges.length + ' relations';
    stage.innerHTML = window.ApodexisRenderer.buildGraphSVG(model, branchID).svg;
    applyTransform();
  }

  function renderBranchSelect() {
    branchSelect.innerHTML = '';
    const all = document.createElement('option');
    all.value = ''; all.textContent = 'All branches';
    branchSelect.appendChild(all);
    model.branches.forEach(function (branch) {
      const option = document.createElement('option');
      option.value = branch.id; option.textContent = branch.name;
      branchSelect.appendChild(option);
    });
    branchSelect.value = branchID || '';
    branchSelect.style.display = model.branches.length > 1 ? '' : 'none';
  }

  branchSelect.addEventListener('change', function () {
    branchID = branchSelect.value || null;
    detail.classList.remove('visible');
    render();
  });

  viewport.addEventListener('wheel', function (event) {
    event.preventDefault();
    const factor = event.deltaY < 0 ? 1.1 : 0.9;
    const next = Math.min(3, Math.max(0.2, scale * factor));
    const rect = viewport.getBoundingClientRect();
    const mx = event.clientX - rect.left, my = event.clientY - rect.top;
    panX = mx - (mx - panX) * (next / scale);
    panY = my - (my - panY) * (next / scale);
    scale = next;
    applyTransform();
  }, { passive: false });

  let dragging = null;
  viewport.addEventListener('mousedown', function (event) {
    dragging = { x: event.clientX - panX, y: event.clientY - panY };
    viewport.classList.add('panning');
  });
  window.addEventListener('mousemove', function (event) {
    if (!dragging) return;
    panX = event.clientX - dragging.x;
    panY = event.clientY - dragging.y;
    applyTransform();
  });
  window.addEventListener('mouseup', function () { dragging = null; viewport.classList.remove('panning'); });

  viewport.addEventListener('click', function (event) {
    const group = event.target.closest('g.node');
    document.querySelectorAll('g.node.selected').forEach(function (n) { n.classList.remove('selected'); });
    if (!group) { detail.classList.remove('visible'); return; }
    group.classList.add('selected');
    const node = model.nodes.find(function (n) { return n.id === group.dataset.id; });
    if (!node) return;
    let html = '<div class="title">' + esc(window.ApodexisRenderer.plainMath(node.title)) + '</div>';
    if (node.statement) html += '<div class="statement">' + esc(window.ApodexisRenderer.plainMath(node.statement)) + '</div>';
    html += '<div style="margin-top:6px; opacity:0.7">' + esc(node.kind) + ' · ' + esc(node.status) +
      (node.openSubgoals ? ' · ' + node.openSubgoals + ' open subgoal(s)' : '') + '</div>';
    if (node.sourceFile) {
      html += '<div style="margin-top:4px"><a id="open-source">Open ' + esc(node.sourceFile) +
        (node.sourceLine ? ':' + node.sourceLine : '') + '</a></div>';
    }
    detail.innerHTML = html;
    detail.classList.add('visible');
    const link = document.getElementById('open-source');
    if (link) link.addEventListener('click', function () {
      vscodeApi.postMessage({ type: 'openSource', file: node.sourceFile, line: node.sourceLine || 1 });
    });
  });

  function esc(text) {
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  window.addEventListener('message', function (event) {
    if (event.data && event.data.type === 'update') {
      model = event.data.model;
      if (branchID && !model.branches.some(function (b) { return b.id === branchID; })) branchID = null;
      renderBranchSelect();
      render();
    }
  });

  renderBranchSelect();
  render();
})();
</script>
</body>
</html>`;
}

function deactivate() {}

module.exports = { activate, deactivate };
