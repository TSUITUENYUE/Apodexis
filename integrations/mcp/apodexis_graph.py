"""Read / write / validate Apodexis project folders.

Pure logic used by the MCP server (server.py). Operates on a project *folder*
containing an ``apodexis.json`` in the import format — the same contract the app
reads. No third-party dependencies, so it is unit-testable on its own.
"""

from __future__ import annotations

import json
import os
import re

# --- Vocabulary (kept in sync with Apodexis/Models/ProofModels.swift) ---------

NODE_KINDS = [
    "theorem", "conjecture", "definition", "assumption", "lemma", "claim",
    "proposal", "strategy", "conclusion", "goal", "reduction", "caseSplit",
    "inductionStep", "construction", "counterexample", "failedAttempt",
    "formalCode",
]
EDGE_KINDS = [
    "uses", "implies", "reducesTo", "equivalentTo", "caseOf", "generalizes",
    "contradicts", "dependsOnAssumption", "forksFrom", "refines", "supports",
    "requires", "motivates", "blocks", "diagnoses", "witnesses", "constrains",
    "summarizes",
]
PROOF_STATUS = ["open", "inProgress", "blocked", "needsReview", "proven", "failed", "abandoned"]
BRANCH_STATUS = ["active", "blocked", "stuck", "abandoned", "merged"]
FORMAL_DIALECT = ["latex", "lean", "coq", "isabelle", "pseudocode", "swift", "python"]
VERIFICATION = ["unchecked", "checked", "partial", "checking", "verified", "failed"]

GRAPH_FILENAME = "apodexis.json"


class GraphError(Exception):
    """Raised when a graph is invalid or a folder is unusable."""


def vocabulary() -> dict:
    """The full set of enum values, so an agent can pick valid types."""
    return {
        "nodeTypes": NODE_KINDS,
        "edgeTypes": EDGE_KINDS,
        "nodeStatus": PROOF_STATUS,
        "branchStatus": BRANCH_STATUS,
        "formalDialects": FORMAL_DIALECT,
        "verification": VERIFICATION,
    }


def _norm(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def _resolve_enum(value, allowed):
    if not isinstance(value, str):
        return None
    if value in allowed:
        return value
    target = _norm(value)
    for candidate in allowed:
        if _norm(candidate) == target:
            return candidate
    return None


def validate_doc(doc) -> list[str]:
    """Return a list of hard errors ([] means the graph will import cleanly)."""
    errors: list[str] = []
    if not isinstance(doc, dict):
        return ["Top level must be a JSON object."]

    if not isinstance(doc.get("title"), str) or not doc["title"].strip():
        errors.append("Missing required 'title'.")

    nodes = doc.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        errors.append("'nodes' must be a non-empty array.")
        nodes = nodes if isinstance(nodes, list) else []

    branches = doc.get("branches") or []
    edges = doc.get("edges") or []

    branch_ids: set[str] = set()
    for i, b in enumerate(branches):
        if not isinstance(b, dict):
            errors.append(f"branches[{i}] must be an object.")
            continue
        bid = b.get("id")
        if not isinstance(bid, str):
            errors.append(f"branches[{i}] missing string 'id'.")
        else:
            if bid in branch_ids:
                errors.append(f"branches[{i}] duplicate id '{bid}'.")
            branch_ids.add(bid)
        if not isinstance(b.get("name"), str):
            errors.append(f"branches[{i}] missing string 'name'.")
        if b.get("status") is not None and _resolve_enum(b["status"], BRANCH_STATUS) is None:
            errors.append(f"branches[{i}] invalid status '{b['status']}'.")
    effective_branches = branch_ids or {"main"}

    node_ids: set[str] = set()
    for i, n in enumerate(nodes):
        if not isinstance(n, dict):
            errors.append(f"nodes[{i}] must be an object.")
            continue
        nid = n.get("id")
        if not isinstance(nid, str):
            errors.append(f"nodes[{i}] missing string 'id'.")
        else:
            if nid in node_ids:
                errors.append(f"nodes[{i}] duplicate id '{nid}'.")
            node_ids.add(nid)
        if not isinstance(n.get("title"), str):
            errors.append(f"nodes[{i}] ('{nid}') missing string 'title'.")
        if n.get("branch") is not None and n["branch"] not in effective_branches:
            errors.append(f"nodes[{i}] ('{nid}') unknown branch '{n['branch']}'.")
        for field, allowed in (("type", NODE_KINDS), ("status", PROOF_STATUS),
                               ("verification", VERIFICATION), ("formalDialect", FORMAL_DIALECT)):
            if n.get(field) is not None and _resolve_enum(n[field], allowed) is None:
                errors.append(f"nodes[{i}] ('{nid}') invalid {field} '{n[field]}'.")

    for i, e in enumerate(edges):
        if not isinstance(e, dict):
            errors.append(f"edges[{i}] must be an object.")
            continue
        for end in ("from", "to"):
            ref = e.get(end)
            if not isinstance(ref, str):
                errors.append(f"edges[{i}] missing string '{end}'.")
            elif ref not in node_ids:
                errors.append(f"edges[{i}] '{end}' references unknown node '{ref}'.")
        if _resolve_enum(e.get("type"), EDGE_KINDS) is None:
            errors.append(f"edges[{i}] invalid or missing type '{e.get('type')}'.")

    return errors


def summarize(doc) -> str:
    nodes = doc.get("nodes") or []
    edges = doc.get("edges") or []
    branches = doc.get("branches") or []
    open_subgoals = sum(
        1
        for n in nodes if isinstance(n, dict)
        for s in (n.get("subgoals") or [])
        if isinstance(s, dict) and _resolve_enum(s.get("status") or "open", PROOF_STATUS) != "proven"
    )
    return (f"'{doc.get('title')}': {len(branches) or 1} branch(es), {len(nodes)} node(s), "
            f"{len(edges)} edge(s), {open_subgoals} open subgoal(s).")


# --- Folder I/O ---------------------------------------------------------------

def graph_path(folder: str) -> str:
    return os.path.join(os.path.expanduser(folder), GRAPH_FILENAME)


def new_graph(title: str) -> dict:
    return {
        "title": title,
        "branches": [{"id": "main", "name": "Main proof", "status": "active", "color": "blue"}],
        "nodes": [],
        "edges": [],
    }


def load_graph(folder: str) -> dict | None:
    path = graph_path(folder)
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def save_graph(folder: str, doc: dict) -> str:
    """Validate, then atomically write apodexis.json. Returns a summary string."""
    errors = validate_doc(doc)
    if errors:
        raise GraphError("Graph is invalid:\n- " + "\n- ".join(errors))
    resolved = os.path.expanduser(folder)
    os.makedirs(resolved, exist_ok=True)
    path = graph_path(folder)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2, ensure_ascii=False)
    os.replace(tmp, path)
    return summarize(doc)


def merge(doc: dict, nodes=None, edges=None, branches=None) -> dict:
    """Upsert nodes/edges/branches into ``doc`` by id (new ids are appended)."""
    doc = dict(doc)
    doc.setdefault("nodes", [])
    doc.setdefault("edges", [])
    doc.setdefault("branches", [])

    if branches:
        by_id = {b.get("id"): idx for idx, b in enumerate(doc["branches"]) if isinstance(b, dict)}
        for b in branches:
            if b.get("id") in by_id:
                doc["branches"][by_id[b["id"]]] = b
            else:
                doc["branches"].append(b)

    if nodes:
        by_id = {n.get("id"): idx for idx, n in enumerate(doc["nodes"]) if isinstance(n, dict)}
        for n in nodes:
            if n.get("id") in by_id:
                doc["nodes"][by_id[n["id"]]] = n
            else:
                doc["nodes"].append(n)

    if edges:
        # Edges have no id; treat (from, to, type) as the identity to avoid dupes.
        seen = {(e.get("from"), e.get("to"), e.get("type")) for e in doc["edges"] if isinstance(e, dict)}
        for e in edges:
            key = (e.get("from"), e.get("to"), e.get("type"))
            if key not in seen:
                doc["edges"].append(e)
                seen.add(key)

    return doc
