// SVG renderer for Apodexis proof graphs. Pure string-building so it runs both
// inside the webview and under plain node for tests. Mirrors the app's visual
// language: chip cards, curved edges, dash patterns per relation family.

'use strict';

const KIND_COLORS = {
  theorem: '#5856D6', conjecture: '#D4A800', definition: '#30B0C7',
  assumption: '#FF9500', lemma: '#007AFF', claim: '#32ADE6', proposal: '#FF9500',
  strategy: '#AF52DE', conclusion: '#34C759', goal: '#FF2D55', reduction: '#00C7BE',
  caseSplit: '#AF52DE', inductionStep: '#34C759', construction: '#A2845E',
  counterexample: '#FF3B30', failedAttempt: '#8E8E93', formalCode: '#6E6E73'
};

const EDGE_COLORS = {
  uses: '#007AFF', implies: '#34C759', reducesTo: '#00C7BE', equivalentTo: '#30B0C7',
  caseOf: '#AF52DE', generalizes: '#5856D6', contradicts: '#FF3B30',
  dependsOnAssumption: '#FF9500', forksFrom: '#FF2D55', refines: '#32ADE6',
  supports: '#34C759', requires: '#FF9500', motivates: '#AF52DE', blocks: '#FF3B30',
  diagnoses: '#FF3B30', witnesses: '#30B0C7', constrains: '#5856D6', summarizes: '#8E8E93'
};

const STATUS_COLORS = {
  open: '#FF9500', inProgress: '#007AFF', blocked: '#FF3B30', needsReview: '#AF52DE',
  proven: '#34C759', failed: '#8E8E93', abandoned: '#8E8E93'
};

const EDGE_DASH = {
  forksFrom: '7 5', contradicts: '7 5', blocks: '7 5', diagnoses: '7 5',
  supports: '2 5', motivates: '2 5', summarizes: '2 5'
};

const BIDIRECTIONAL = { equivalentTo: true };

const EDGE_TITLES = {
  uses: 'uses', implies: 'implies', reducesTo: 'reduces to', equivalentTo: 'equivalent to',
  caseOf: 'case of', generalizes: 'generalizes', contradicts: 'contradicts',
  dependsOnAssumption: 'depends on assumption', forksFrom: 'forks from', refines: 'refines',
  supports: 'supports', requires: 'requires', motivates: 'motivates', blocks: 'blocks',
  diagnoses: 'diagnoses', witnesses: 'witnesses', constrains: 'constrains', summarizes: 'summarizes'
};

const KIND_TITLES = {
  theorem: 'Theorem', conjecture: 'Conjecture', definition: 'Definition',
  assumption: 'Assumption', lemma: 'Lemma', claim: 'Claim', proposal: 'Proposal',
  strategy: 'Strategy', conclusion: 'Conclusion', goal: 'Goal', reduction: 'Reduction',
  caseSplit: 'Case split', inductionStep: 'Induction step', construction: 'Construction',
  counterexample: 'Counterexample', failedAttempt: 'Failed attempt', formalCode: 'Formal code'
};

const CARD = { w: 214, h: 74 };
const MARGIN = 90;

const MATH_SYMBOLS = {
  sqrt: '√', infty: '∞', pi: 'π', alpha: 'α', beta: 'β', gamma: 'γ', Gamma: 'Γ',
  delta: 'δ', Delta: 'Δ', epsilon: 'ε', lambda: 'λ', Lambda: 'Λ', mu: 'μ', sigma: 'σ',
  Sigma: 'Σ', phi: 'φ', Phi: 'Φ', psi: 'ψ', omega: 'ω', Omega: 'Ω', theta: 'θ', tau: 'τ',
  leq: '≤', le: '≤', geq: '≥', ge: '≥', neq: '≠', ne: '≠', in: '∈', notin: '∉',
  subseteq: '⊆', subset: '⊂', cup: '∪', cap: '∩', emptyset: '∅', forall: '∀',
  exists: '∃', implies: '⇒', iff: '⇔', to: '→', rightarrow: '→', mapsto: '↦',
  times: '×', cdot: '·', pm: '±', equiv: '≡', approx: '≈', sim: '∼', partial: '∂',
  sum: '∑', prod: '∏', int: '∫', mathbb: '', mathrm: '', text: '', gcd: 'gcd'
};

const SUPERSCRIPTS = { 0: '⁰', 1: '¹', 2: '²', 3: '³', 4: '⁴', 5: '⁵', 6: '⁶', 7: '⁷', 8: '⁸', 9: '⁹', n: 'ⁿ', i: 'ⁱ', '+': '⁺', '-': '⁻' };
const SUBSCRIPTS = { 0: '₀', 1: '₁', 2: '₂', 3: '₃', 4: '₄', 5: '₅', 6: '₆', 7: '₇', 8: '₈', 9: '₉', i: 'ᵢ', n: 'ₙ', '+': '₊', '-': '₋' };

/// Tiny LaTeX-to-Unicode pass so titles like "$\sqrt{2}$ is irrational" read well.
function plainMath(text) {
  let out = String(text);
  out = out.replace(/\\([a-zA-Z]+)\s*\{([^{}]*)\}/g, (match, command, body) => {
    if (command === 'sqrt') return '√' + body;
    if (command in MATH_SYMBOLS) return MATH_SYMBOLS[command] + body;
    return body;
  });
  out = out.replace(/\\([a-zA-Z]+)/g, (match, command) => (command in MATH_SYMBOLS ? MATH_SYMBOLS[command] : command));
  out = out.replace(/\^\{?([0-9ni+-])\}?/g, (match, ch) => SUPERSCRIPTS[ch] || '^' + ch);
  out = out.replace(/_\{?([0-9ni+-])\}?/g, (match, ch) => SUBSCRIPTS[ch] || '_' + ch);
  out = out.replace(/[${}]/g, '');
  return out;
}

function escapeXml(text) {
  return String(text)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

/// Two-line word wrap with ellipsis, tuned for the chip width.
function wrapTitle(text, maxChars) {
  const words = String(text).split(/\s+/).filter(Boolean);
  const lines = [];
  let current = '';
  for (const word of words) {
    const candidate = current === '' ? word : current + ' ' + word;
    if (candidate.length <= maxChars || current === '') {
      current = candidate;
    } else {
      lines.push(current);
      current = word;
      if (lines.length === 2) break;
    }
  }
  if (lines.length < 2 && current !== '') lines.push(current);
  if (lines.length === 2 && current !== lines[1]) {
    lines[1] = lines[1].length > maxChars - 1 ? lines[1].slice(0, maxChars - 1) + '…' : lines[1] + '…';
  } else if (lines[1] && lines[1].length > maxChars) {
    lines[1] = lines[1].slice(0, maxChars - 1) + '…';
  }
  return lines;
}

function connectionPoint(center, toward) {
  const dx = toward.x - center.x;
  const dy = toward.y - center.y;
  if (dx === 0 && dy === 0) return { x: center.x, y: center.y };
  const xScale = dx === 0 ? Infinity : (CARD.w / 2) / Math.abs(dx);
  const yScale = dy === 0 ? Infinity : (CARD.h / 2) / Math.abs(dy);
  const scale = Math.min(xScale, yScale);
  return { x: center.x + dx * scale, y: center.y + dy * scale };
}

function arrowHead(tip, from, color) {
  const angle = Math.atan2(tip.y - from.y, tip.x - from.x);
  const size = 11;
  const spread = Math.PI / 7;
  const a = { x: tip.x - size * Math.cos(angle - spread), y: tip.y - size * Math.sin(angle - spread) };
  const b = { x: tip.x - size * Math.cos(angle + spread), y: tip.y - size * Math.sin(angle + spread) };
  return `<path d="M ${tip.x} ${tip.y} L ${a.x} ${a.y} L ${b.x} ${b.y} Z" fill="${color}" fill-opacity="0.9"/>`;
}

/// Builds the full SVG for one branch (or all branches when branchID is null).
function buildGraphSVG(model, branchID) {
  const nodes = model.nodes.filter((node) => !branchID || node.branchID === branchID)
    .filter((node) => node.position !== null);
  const ids = new Set(nodes.map((node) => node.id));
  const edges = model.edges.filter((edge) => ids.has(edge.source) && ids.has(edge.target));

  if (nodes.length === 0) {
    return { svg: '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="120"><text x="20" y="60" fill="#8E8E93">No nodes in this branch.</text></svg>', width: 400, height: 120 };
  }

  const xs = nodes.map((node) => node.position.x);
  const ys = nodes.map((node) => node.position.y);
  const minX = Math.min(...xs) - CARD.w / 2;
  const minY = Math.min(...ys) - CARD.h / 2;
  const width = Math.max(...xs) - Math.min(...xs) + CARD.w + 2 * MARGIN;
  const height = Math.max(...ys) - Math.min(...ys) + CARD.h + 2 * MARGIN;
  const at = (node) => ({ x: node.position.x - minX + MARGIN, y: node.position.y - minY + MARGIN });
  const centers = new Map(nodes.map((node) => [node.id, at(node)]));

  const parts = [];

  for (const edge of edges) {
    const source = centers.get(edge.source);
    const target = centers.get(edge.target);
    const start = connectionPoint(source, target);
    const end = connectionPoint(target, source);
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const offset = Math.max(70, Math.min(260, Math.abs(dx) * 0.38));
    const dir = dx >= 0 ? 1 : -1;
    let c1;
    let c2;
    // Long, nearly horizontal edges bow upward so they clear any chips sitting
    // between their endpoints instead of striping through the chain.
    const bow = Math.abs(dx) > CARD.w * 1.6 && Math.abs(dy) < CARD.h ? 90 + Math.abs(dx) * 0.05 : 0;
    if (Math.abs(dx) < 50) {
      c1 = { x: start.x, y: start.y + dy * 0.36 };
      c2 = { x: end.x, y: end.y - dy * 0.36 };
    } else {
      c1 = { x: start.x + offset * dir, y: start.y - bow };
      c2 = { x: end.x - offset * dir, y: end.y - bow };
    }
    const color = EDGE_COLORS[edge.kind] || '#8E8E93';
    const dash = EDGE_DASH[edge.kind] ? ` stroke-dasharray="${EDGE_DASH[edge.kind]}"` : '';
    parts.push(`<path d="M ${start.x} ${start.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${end.x} ${end.y}" fill="none" stroke="${color}" stroke-opacity="0.8" stroke-width="2.4" stroke-linecap="round"${dash}/>`);
    parts.push(arrowHead(end, c2, color));
    if (BIDIRECTIONAL[edge.kind]) parts.push(arrowHead(start, c1, color));

    const labelText = edge.label ? `${EDGE_TITLES[edge.kind]} · ${plainMath(edge.label)}` : EDGE_TITLES[edge.kind];
    const lx = (source.x + target.x) / 2;
    const ly = (source.y + target.y) / 2 - 16 - bow * 0.75;
    const lw = labelText.length * 5.6 + 16;
    parts.push(`<g class="edge-label"><rect x="${lx - lw / 2}" y="${ly - 9}" width="${lw}" height="18" rx="9" fill="var(--chip-bg)" stroke="${color}" stroke-opacity="0.4"/><text x="${lx}" y="${ly + 3.5}" text-anchor="middle" font-size="9.5" font-weight="600" fill="${color}">${escapeXml(labelText)}</text></g>`);
  }

  for (const node of nodes) {
    const center = centers.get(node.id);
    const x = center.x - CARD.w / 2;
    const y = center.y - CARD.h / 2;
    const kindColor = KIND_COLORS[node.kind] || '#8E8E93';
    const statusColor = STATUS_COLORS[node.status] || '#8E8E93';
    const lines = wrapTitle(plainMath(node.title), 24);
    const titleY = lines.length > 1 ? 40 : 46;
    const attrs = `class="node" data-id="${escapeXml(node.id)}"${node.sourceFile ? ` data-file="${escapeXml(node.sourceFile)}" data-line="${node.sourceLine || 1}"` : ''}`;
    parts.push([
      `<g ${attrs} transform="translate(${x}, ${y})" cursor="pointer">`,
      `<rect class="chip" width="${CARD.w}" height="${CARD.h}" rx="12" fill="var(--chip-bg)" stroke="var(--chip-border)" stroke-width="1"/>`,
      `<rect x="6" y="12" width="4" height="${CARD.h - 24}" rx="2" fill="${kindColor}"/>`,
      `<text x="20" y="24" font-size="8.5" font-weight="700" letter-spacing="0.5" fill="${kindColor}">${escapeXml((KIND_TITLES[node.kind] || node.kind).toUpperCase())}</text>`,
      lines.map((line, index) => `<text x="20" y="${titleY + index * 15}" font-size="12" font-weight="600" fill="var(--chip-text)">${escapeXml(line)}</text>`).join(''),
      `<circle cx="${CARD.w - 16}" cy="20" r="4.5" fill="${statusColor}"/>`,
      node.openSubgoals > 0 ? `<text x="${CARD.w - 16}" y="40" text-anchor="middle" font-size="9" font-weight="700" fill="#FF9500">${node.openSubgoals}</text>` : '',
      '</g>'
    ].join(''));
  }

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" font-family="-apple-system, system-ui, sans-serif">${parts.join('\n')}</svg>`;
  return { svg, width, height };
}

const api = { buildGraphSVG, plainMath, KIND_COLORS, EDGE_COLORS, STATUS_COLORS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof window !== 'undefined') window.ApodexisRenderer = api;
