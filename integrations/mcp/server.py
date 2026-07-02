#!/usr/bin/env python3
"""Apodexis MCP server.

Exposes tools that let an AI agent (Claude Desktop, Claude Code, etc.) build and
edit an Apodexis proof-graph project on disk. Each tool operates on a project
*folder*; the graph lives in ``<folder>/apodexis.json`` in the import format, and
the user opens that folder in Apodexis with "Open Folder".

Run:
    pip install "mcp[cli]"
    python3 server.py

See README.md for Claude Desktop / Claude Code configuration.
"""

from __future__ import annotations

import json

from mcp.server.fastmcp import FastMCP

import apodexis_graph as ag

mcp = FastMCP("apodexis")


@mcp.tool()
def apodexis_vocabulary() -> dict:
    """List every valid node type, edge type, and status value for Apodexis graphs.

    Call this first so you pick valid `type`/`status` values. Values are forgiving
    ("reduces to" resolves to "reducesTo"), but these are the canonical forms.
    """
    return ag.vocabulary()


@mcp.tool()
def read_apodexis_graph(folder: str) -> str:
    """Read the current proof graph in a project folder.

    Returns the apodexis.json contents (or a note if the folder has no graph yet),
    plus a one-line summary. Use this before editing so you reference existing
    node ids correctly.
    """
    doc = ag.load_graph(folder)
    if doc is None:
        return f"No apodexis.json in '{folder}' yet. Use write_apodexis_graph to create one."
    return ag.summarize(doc) + "\n\n" + json.dumps(doc, indent=2, ensure_ascii=False)


@mcp.tool()
def write_apodexis_graph(
    folder: str,
    title: str,
    nodes: list[dict],
    edges: list[dict] | None = None,
    branches: list[dict] | None = None,
) -> str:
    """Create or overwrite a project's proof graph.

    Writes `<folder>/apodexis.json`, creating the folder if needed. The graph is
    validated first; on any error nothing is written and the errors are returned.

    Node shape (only `id` and `title` are required):
      {"id": "thm", "type": "theorem", "title": "...", "statement": "$...$",
       "status": "proven", "subgoals": [{"title": "...", "status": "open"}],
       "sourceFile": "Main.lean", "sourceLine": 12}
    Edge shape: {"from": "<node id>", "to": "<node id>", "type": "implies", "label": "..."}
    Omit node `position` — Apodexis auto-arranges the graph on open.
    """
    doc = {
        "title": title,
        "branches": branches or [{"id": "main", "name": "Main proof", "status": "active", "color": "blue"}],
        "nodes": nodes,
        "edges": edges or [],
    }
    try:
        summary = ag.save_graph(folder, doc)
    except ag.GraphError as exc:
        return f"NOT WRITTEN — {exc}"
    return f"Wrote {ag.graph_path(folder)}\n{summary}\nOpen this folder in Apodexis with 'Open Folder'."


@mcp.tool()
def add_to_apodexis_graph(
    folder: str,
    nodes: list[dict] | None = None,
    edges: list[dict] | None = None,
    branches: list[dict] | None = None,
    title: str | None = None,
) -> str:
    """Incrementally add nodes/edges/branches to an existing (or new) graph.

    Upserts by id: an item whose id already exists is replaced, otherwise appended.
    Creates the graph if the folder has none. Validates before writing.
    """
    doc = ag.load_graph(folder) or ag.new_graph(title or "Untitled proof")
    if title:
        doc["title"] = title
    doc = ag.merge(doc, nodes=nodes, edges=edges, branches=branches)
    try:
        summary = ag.save_graph(folder, doc)
    except ag.GraphError as exc:
        return f"NOT WRITTEN — {exc}"
    return f"Updated {ag.graph_path(folder)}\n{summary}"


@mcp.tool()
def validate_apodexis_graph(folder: str) -> str:
    """Check whether a folder's apodexis.json will import into Apodexis cleanly."""
    doc = ag.load_graph(folder)
    if doc is None:
        return f"No apodexis.json in '{folder}'."
    errors = ag.validate_doc(doc)
    if errors:
        return "INVALID:\n- " + "\n- ".join(errors)
    return "VALID — " + ag.summarize(doc)


if __name__ == "__main__":
    mcp.run()
