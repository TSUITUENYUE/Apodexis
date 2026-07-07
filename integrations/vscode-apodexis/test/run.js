#!/usr/bin/env node
// Sanity tests for the extension's pure logic: normalization of both JSON
// formats, validation, layout, and SVG rendering. Also writes an HTML preview
// (same CSS variables as the webview) for visual inspection.
//
//   node test/run.js [path-to-app-saved-apodexis.json] [preview-output-dir]

'use strict';

const fs = require('fs');
const path = require('path');
const { normalize, validate, layout } = require('../lib/graphModel');
const { buildGraphSVG, plainMath } = require('../media/renderer');

let failures = 0;
function check(name, condition) {
  console.log(`${condition ? '✓' : '✗'} ${name}`);
  if (!condition) failures += 1;
}

// --- Import format (the bundled sqrt2 skill example: no positions) ------------
const importPath = path.join(__dirname, '..', '..', '..', 'skills', 'apodexis-proof-graph', 'examples', 'sqrt2-irrational', 'apodexis.json');
const importDoc = JSON.parse(fs.readFileSync(importPath, 'utf8'));
const importModel = layout(normalize(importDoc));

check('import: all nodes normalized', importModel.nodes.length === importDoc.nodes.length);
check('import: all edges resolved', importModel.edges.length === importDoc.edges.length);
check('import: layout assigned positions', importModel.nodes.every((n) => n.position !== null));
check('import: kinds resolved', importModel.nodes.every((n) => n.kind && n.kind !== 'undefined'));
check('import: validator passes clean file', validate(importDoc).length === 0);

const badDoc = { nodes: [{ id: 'a', title: 'A', type: 'lemmma' }, { id: 'a', title: 'dup' }], edges: [{ from: 'a', to: 'ghost', type: 'impies' }] };
const badProblems = validate(badDoc);
check('validator: catches bad enum, dup id, dangling edge', badProblems.length >= 3);

const rendered = buildGraphSVG(importModel, null);
check('render: svg produced', rendered.svg.startsWith('<svg') && rendered.width > 400);
check('render: contains a node title', rendered.svg.includes('irrational'));
check('render: contains edge labels', rendered.svg.includes('implies'));
check('plainMath: sqrt + superscript', plainMath('$\\sqrt{2}$ and $q^2$') === '√2 and q²');

// --- App-saved internal format -------------------------------------------------
const internalPath = process.argv[2];
if (internalPath && fs.existsSync(internalPath)) {
  const internalDoc = JSON.parse(fs.readFileSync(internalPath, 'utf8'));
  const internalModel = layout(normalize(internalDoc));
  check('internal: nodes normalized', internalModel.nodes.length === internalDoc.nodes.length);
  check('internal: positions preserved', internalModel.nodes.every((n) => n.position !== null));
  check('internal: edges resolved (sourceID/targetID)', internalModel.edges.length > 0);
  check('internal: branches carried over', internalModel.branches.length === internalDoc.branches.length);
  const internalRender = buildGraphSVG(internalModel, internalModel.branches[0].id);
  check('internal: branch render works', internalRender.svg.includes('<svg'));
} else {
  console.log('· internal-format fixture not provided — skipped');
}

// --- Visual preview -------------------------------------------------------------
const outDir = process.argv[3];
if (outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Apodexis webview preview</title>
<style>
  :root { --chip-bg: #ffffff; --chip-border: rgba(60,60,67,0.25); --chip-text: #1d1d1f; }
  body { margin: 0; font-family: -apple-system, system-ui, sans-serif; background: #f5f5f7; }
  .bar { padding: 10px 16px; font-size: 13px; font-weight: 600; border-bottom: 1px solid #ddd; background: #fff; }
  .wrap { padding: 16px; overflow: auto; }
  .dark { background: #1e1e1e; --chip-bg: #2a2a2e; --chip-border: rgba(255,255,255,0.22); --chip-text: #f2f2f2; }
</style></head><body>
<div class="bar">Apodexis VS Code webview preview — light</div>
<div class="wrap">${rendered.svg}</div>
<div class="bar dark" style="color:#fff">dark</div>
<div class="wrap dark">${rendered.svg}</div>
</body></html>`;
  fs.writeFileSync(path.join(outDir, 'index.html'), html);
  console.log(`· preview written to ${path.join(outDir, 'index.html')}`);
}

console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
