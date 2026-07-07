// Pure graph logic for the Apodexis VS Code extension: normalizes both JSON
// formats (the app's saved format and the simpler import format), validates
// referential integrity, and lays out positionless graphs. No dependencies, so
// it runs in the extension host, the webview, and plain node tests.

'use strict';

const NODE_KINDS = [
  'theorem', 'conjecture', 'definition', 'assumption', 'lemma', 'claim',
  'proposal', 'strategy', 'conclusion', 'goal', 'reduction', 'caseSplit',
  'inductionStep', 'construction', 'counterexample', 'failedAttempt', 'formalCode'
];

const EDGE_KINDS = [
  'uses', 'implies', 'reducesTo', 'equivalentTo', 'caseOf', 'generalizes',
  'contradicts', 'dependsOnAssumption', 'forksFrom', 'refines', 'supports',
  'requires', 'motivates', 'blocks', 'diagnoses', 'witnesses', 'constrains',
  'summarizes'
];

const PROOF_STATUS = ['open', 'inProgress', 'blocked', 'needsReview', 'proven', 'failed', 'abandoned'];

function slug(value) {
  return String(value).toLowerCase().replace(/[^a-z0-9]/g, '');
}

/// Enum resolution mirroring the app: exact match first, then normalized.
function resolveEnum(value, allowed, fallback) {
  if (value == null) return fallback;
  if (allowed.includes(value)) return value;
  const target = slug(value);
  const match = allowed.find((candidate) => slug(candidate) === target);
  return match || fallback;
}

function isFiniteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

/// Normalizes either JSON format into one model the renderer understands.
function normalize(doc) {
  if (!doc || typeof doc !== 'object') {
    return { title: 'Invalid graph', branches: [], nodes: [], edges: [] };
  }

  let branches = (Array.isArray(doc.branches) ? doc.branches : [])
    .filter((branch) => branch && typeof branch === 'object' && branch.id != null)
    .map((branch) => ({
      id: String(branch.id),
      name: typeof branch.name === 'string' ? branch.name : 'Branch',
      color: branch.colorName || branch.color || 'blue'
    }));
  if (branches.length === 0) {
    branches = [{ id: 'main', name: 'Main proof', color: 'blue' }];
  }
  const branchIDs = new Set(branches.map((branch) => branch.id));

  const nodes = (Array.isArray(doc.nodes) ? doc.nodes : [])
    .filter((node) => node && typeof node === 'object' && node.id != null)
    .map((node) => {
      const rawBranch = node.branchID != null ? node.branchID : node.branch;
      const branchID = rawBranch != null && branchIDs.has(String(rawBranch))
        ? String(rawBranch)
        : branches[0].id;
      const position = node.position
        && isFiniteNumber(node.position.x) && isFiniteNumber(node.position.y)
        ? { x: node.position.x, y: node.position.y }
        : null;
      const subgoals = Array.isArray(node.subgoals) ? node.subgoals : [];
      return {
        id: String(node.id),
        title: typeof node.title === 'string' ? node.title : String(node.id),
        kind: resolveEnum(node.kind != null ? node.kind : node.type, NODE_KINDS, 'claim'),
        status: resolveEnum(node.status, PROOF_STATUS, 'open'),
        branchID,
        position,
        statement: typeof node.statement === 'string' ? node.statement : '',
        sourceFile: typeof node.sourceFile === 'string' ? node.sourceFile : null,
        sourceLine: isFiniteNumber(node.sourceLine) ? node.sourceLine : null,
        openSubgoals: subgoals.filter((s) => s && s.status !== 'proven').length
      };
    });
  const nodeIDs = new Set(nodes.map((node) => node.id));

  const edges = (Array.isArray(doc.edges) ? doc.edges : [])
    .filter((edge) => edge && typeof edge === 'object')
    .map((edge) => ({
      source: String(edge.sourceID != null ? edge.sourceID : edge.from),
      target: String(edge.targetID != null ? edge.targetID : edge.to),
      kind: resolveEnum(edge.kind != null ? edge.kind : edge.type, EDGE_KINDS, 'uses'),
      label: typeof edge.label === 'string' ? edge.label : ''
    }))
    .filter((edge) => nodeIDs.has(edge.source) && nodeIDs.has(edge.target) && edge.source !== edge.target);

  return {
    title: typeof doc.title === 'string' ? doc.title : 'Proof graph',
    branches,
    nodes,
    edges
  };
}

/// Deep integrity checks the JSON schema cannot express. Each problem carries an
/// `anchor` substring the extension uses to place the diagnostic in the text.
function validate(doc) {
  const problems = [];
  const report = (message, anchor) => problems.push({ message, anchor: anchor || null });

  if (!doc || typeof doc !== 'object') {
    report('Top level must be a JSON object.');
    return problems;
  }
  if (!Array.isArray(doc.nodes) || doc.nodes.length === 0) {
    report("'nodes' must be a non-empty array.");
  }

  const branchIDs = new Set();
  for (const branch of Array.isArray(doc.branches) ? doc.branches : []) {
    if (!branch || branch.id == null) continue;
    const id = String(branch.id);
    if (branchIDs.has(id)) report(`Duplicate branch id '${id}'.`, id);
    branchIDs.add(id);
  }

  const nodeIDs = new Set();
  for (const node of Array.isArray(doc.nodes) ? doc.nodes : []) {
    if (!node || typeof node !== 'object') continue;
    if (node.id == null) {
      report("A node is missing its 'id'.");
      continue;
    }
    const id = String(node.id);
    if (nodeIDs.has(id)) report(`Duplicate node id '${id}'.`, id);
    nodeIDs.add(id);
    if (typeof node.title !== 'string' || node.title.trim() === '') {
      report(`Node '${id}' is missing a 'title'.`, id);
    }
    const kind = node.kind != null ? node.kind : node.type;
    if (kind != null && resolveEnum(kind, NODE_KINDS, null) === null) {
      report(`Node '${id}' has invalid type '${kind}'. Allowed: ${NODE_KINDS.join(', ')}.`, String(kind));
    }
    const branchRef = node.branchID != null ? node.branchID : node.branch;
    if (branchRef != null && branchIDs.size > 0 && !branchIDs.has(String(branchRef))) {
      report(`Node '${id}' references unknown branch '${branchRef}'.`, String(branchRef));
    }
  }

  for (const edge of Array.isArray(doc.edges) ? doc.edges : []) {
    if (!edge || typeof edge !== 'object') continue;
    const source = edge.sourceID != null ? edge.sourceID : edge.from;
    const target = edge.targetID != null ? edge.targetID : edge.to;
    if (source == null || target == null) {
      report("An edge is missing 'from'/'to' (or 'sourceID'/'targetID').");
      continue;
    }
    if (!nodeIDs.has(String(source))) report(`Edge references unknown node '${source}'.`, String(source));
    if (!nodeIDs.has(String(target))) report(`Edge references unknown node '${target}'.`, String(target));
    if (String(source) === String(target)) report(`Edge connects node '${source}' to itself.`, String(source));
    const kind = edge.kind != null ? edge.kind : edge.type;
    if (kind == null) {
      report('An edge is missing its relation type.');
    } else if (resolveEnum(kind, EDGE_KINDS, null) === null) {
      report(`Invalid edge type '${kind}'. Allowed: ${EDGE_KINDS.join(', ')}.`, String(kind));
    }
  }

  return problems;
}

/// Assigns positions to branches whose nodes lack them (AI/hand-authored files),
/// using the same longest-path layering idea as the app. Positioned branches
/// (everything the app saves) are left untouched.
function layout(model) {
  for (const branch of model.branches) {
    const branchNodes = model.nodes.filter((node) => node.branchID === branch.id);
    if (branchNodes.length === 0 || branchNodes.every((node) => node.position !== null)) continue;

    const ids = new Set(branchNodes.map((node) => node.id));
    const edges = model.edges.filter((edge) => ids.has(edge.source) && ids.has(edge.target));

    const layer = new Map(branchNodes.map((node) => [node.id, 0]));
    for (let pass = 0; pass < branchNodes.length; pass += 1) {
      let changed = false;
      for (const edge of edges) {
        const next = layer.get(edge.source) + 1;
        if (next > layer.get(edge.target)) {
          layer.set(edge.target, next);
          changed = true;
        }
      }
      if (!changed) break;
    }

    const byLayer = new Map();
    for (const node of branchNodes) {
      const key = layer.get(node.id);
      if (!byLayer.has(key)) byLayer.set(key, []);
      byLayer.get(key).push(node);
    }
    for (const [key, group] of [...byLayer.entries()].sort((a, b) => a[0] - b[0])) {
      group.forEach((node, index) => {
        node.position = { x: 170 + key * 320, y: 120 + index * 130 };
      });
    }
  }
  return model;
}

module.exports = { NODE_KINDS, EDGE_KINDS, PROOF_STATUS, normalize, validate, layout, resolveEnum };
