#!/usr/bin/env python3
"""Validate an Apodexis import file (apodexis.json).

Mirrors the decoder in Apodexis/Store/ProofStore.swift (ApodexisImportDocument)
so an AI agent can check its work *before* handing the file to a human. Exits 0
when the file will import cleanly, 1 when it would fail or import incorrectly.

Usage:
    python3 validate.py path/to/apodexis.json
    python3 validate.py --quiet path/to/apodexis.json     # only print on failure
"""

from __future__ import annotations

import argparse
import json
import re
import sys

# --- Enum vocabularies (raw values, exactly as in ProofModels.swift) ----------

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
BRANCH_COLORS = ["blue", "pink", "green", "orange", "purple", "red"]


def _norm(value: str) -> str:
    """Same normalization the app uses: lowercase, keep only letters/digits."""
    return re.sub(r"[^a-z0-9]", "", value.lower())


def _resolve_enum(value, allowed):
    """Return the canonical raw value, or None if it does not resolve.

    The app accepts an exact raw-value match first, then a normalized match
    ("reduces to", "Reduces_To", "REDUCESTO" all map to "reducesTo").
    """
    if not isinstance(value, str):
        return None
    if value in allowed:
        return value
    target = _norm(value)
    for candidate in allowed:
        if _norm(candidate) == target:
            return candidate
    return None


class Report:
    def __init__(self):
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, msg: str):
        self.errors.append(msg)

    def warn(self, msg: str):
        self.warnings.append(msg)


def _require_str(obj, key, where, report, *, required=True):
    val = obj.get(key)
    if val is None:
        if required:
            report.error(f"{where}: missing required field '{key}'.")
        return None
    if not isinstance(val, str):
        report.error(f"{where}: field '{key}' must be a string, got {type(val).__name__}.")
        return None
    return val


def validate(doc, report: Report):
    if not isinstance(doc, dict):
        report.error("Top level must be a JSON object.")
        return

    _require_str(doc, "title", "document", report)

    nodes = doc.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        report.error("document: 'nodes' must be a non-empty array.")
        nodes = nodes if isinstance(nodes, list) else []

    branches = doc.get("branches")
    if branches is not None and not isinstance(branches, list):
        report.error("document: 'branches' must be an array when present.")
        branches = []
    branches = branches or []

    edges = doc.get("edges")
    if edges is not None and not isinstance(edges, list):
        report.error("document: 'edges' must be an array when present.")
        edges = []
    edges = edges or []

    # --- Branches -------------------------------------------------------------
    branch_ids: set[str] = set()
    for i, branch in enumerate(branches):
        where = f"branches[{i}]"
        if not isinstance(branch, dict):
            report.error(f"{where}: must be an object.")
            continue
        bid = _require_str(branch, "id", where, report)
        _require_str(branch, "name", where, report)
        if bid is not None:
            if bid in branch_ids:
                report.error(f"{where}: duplicate branch id '{bid}'.")
            branch_ids.add(bid)
        status = branch.get("status")
        if status is not None and _resolve_enum(status, BRANCH_STATUS) is None:
            report.error(f"{where}: invalid branch status '{status}'. Allowed: {', '.join(BRANCH_STATUS)}.")
        color = branch.get("color")
        if color is not None and _resolve_enum(color, BRANCH_COLORS) is None:
            report.warn(f"{where}: unknown color '{color}' will fall back to blue. Known: {', '.join(BRANCH_COLORS)}.")

    # When no branches are given the app synthesizes a default "main" branch.
    effective_branch_ids = branch_ids if branch_ids else {"main"}

    # --- Nodes ----------------------------------------------------------------
    node_ids: set[str] = set()
    for i, node in enumerate(nodes):
        where = f"nodes[{i}]"
        if not isinstance(node, dict):
            report.error(f"{where}: must be an object.")
            continue
        nid = _require_str(node, "id", where, report)
        title = _require_str(node, "title", where, report)
        label = f"nodes[{i}] ('{nid or title or '?'}')"
        if nid is not None:
            if nid in node_ids:
                report.error(f"{label}: duplicate node id '{nid}'.")
            node_ids.add(nid)

        branch_ref = node.get("branch")
        if branch_ref is not None and branch_ref not in effective_branch_ids:
            report.error(f"{label}: 'branch' references unknown branch id '{branch_ref}'.")

        _check_enum(node, "type", NODE_KINDS, label, report, default="claim")
        _check_enum(node, "status", PROOF_STATUS, label, report, default="open")
        _check_enum(node, "verification", VERIFICATION, label, report, default="unchecked")
        _check_enum(node, "formalDialect", FORMAL_DIALECT, label, report, default="latex")

        pos = node.get("position")
        if pos is not None:
            if not isinstance(pos, dict) or not _is_number(pos.get("x")) or not _is_number(pos.get("y")):
                report.error(f"{label}: 'position' must be an object with numeric 'x' and 'y'.")

        for j, sub in enumerate(node.get("subgoals") or []):
            sw = f"{label} subgoals[{j}]"
            if not isinstance(sub, dict):
                report.error(f"{sw}: must be an object.")
                continue
            _require_str(sub, "title", sw, report)
            _check_enum(sub, "status", PROOF_STATUS, sw, report, default="open")

        for j, sym in enumerate(node.get("symbols") or []):
            sw = f"{label} symbols[{j}]"
            if not isinstance(sym, dict):
                report.error(f"{sw}: must be an object.")
                continue
            _require_str(sym, "symbol", sw, report)
            _require_str(sym, "meaning", sw, report)

        _check_str_list(node, "assumptions", label, report)
        _check_str_list(node, "tags", label, report)
        if node.get("sourceLine") is not None and not isinstance(node.get("sourceLine"), int):
            report.error(f"{label}: 'sourceLine' must be an integer.")

    # --- forkedFrom (needs node ids resolved) ---------------------------------
    for i, branch in enumerate(branches):
        if not isinstance(branch, dict):
            continue
        forked = branch.get("forkedFrom")
        if forked is not None and forked not in node_ids:
            report.warn(f"branches[{i}]: 'forkedFrom' references unknown node id '{forked}' (will be ignored).")
        parent = branch.get("parent")
        if parent is not None and parent not in branch_ids:
            report.warn(f"branches[{i}]: 'parent' references unknown branch id '{parent}' (will be ignored).")

    # --- Edges ----------------------------------------------------------------
    for i, edge in enumerate(edges):
        where = f"edges[{i}]"
        if not isinstance(edge, dict):
            report.error(f"{where}: must be an object.")
            continue
        frm = _require_str(edge, "from", where, report)
        to = _require_str(edge, "to", where, report)
        if frm is not None and frm not in node_ids:
            report.error(f"{where}: 'from' references unknown node id '{frm}'.")
        if to is not None and to not in node_ids:
            report.error(f"{where}: 'to' references unknown node id '{to}'.")
        if frm is not None and frm == to:
            report.warn(f"{where}: self-edge '{frm}' -> '{to}' (a node connected to itself).")
        etype = edge.get("type")
        if etype is None:
            report.error(f"{where}: missing required field 'type'.")
        elif _resolve_enum(etype, EDGE_KINDS) is None:
            report.error(f"{where}: invalid edge type '{etype}'. Allowed: {', '.join(EDGE_KINDS)}.")


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _check_enum(obj, key, allowed, where, report, *, default):
    val = obj.get(key)
    if val is None:
        return  # decoder falls back to `default`
    if _resolve_enum(val, allowed) is None:
        report.error(f"{where}: invalid '{key}' value '{val}'. Allowed: {', '.join(allowed)}.")


def _check_str_list(obj, key, where, report):
    val = obj.get(key)
    if val is None:
        return
    if not isinstance(val, list) or any(not isinstance(x, str) for x in val):
        report.error(f"{where}: '{key}' must be an array of strings.")


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
    title = doc.get("title") if isinstance(doc, dict) else "?"
    return (
        f"'{title}': {len(branches) or 1} branch(es), {len(nodes)} node(s), "
        f"{len(edges)} edge(s), {open_subgoals} open subgoal(s)."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an Apodexis import file.")
    parser.add_argument("path", help="Path to apodexis.json (or any import JSON).")
    parser.add_argument("--quiet", action="store_true", help="Only print output on failure.")
    args = parser.parse_args()

    try:
        with open(args.path, "r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except FileNotFoundError:
        print(f"✗ File not found: {args.path}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as exc:
        print(f"✗ Not valid JSON: {exc}", file=sys.stderr)
        return 1

    report = Report()
    validate(doc, report)

    for warning in report.warnings:
        print(f"⚠ {warning}")

    if report.errors:
        for err in report.errors:
            print(f"✗ {err}")
        print(f"\nFAILED with {len(report.errors)} error(s). This file will not import correctly.")
        return 1

    if not args.quiet:
        print(f"✓ Valid Apodexis import. {summarize(doc)}")
        if report.warnings:
            print(f"  ({len(report.warnings)} warning(s) above — import will still succeed.)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
