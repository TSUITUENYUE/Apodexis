# Apodexis MCP server

A [Model Context Protocol](https://modelcontextprotocol.io) server that lets an AI
agent build and edit Apodexis proof graphs directly. The agent works on a project
**folder**; you then open that folder in Apodexis with **Open Folder**.

## Tools

| Tool | What it does |
|------|--------------|
| `apodexis_vocabulary` | Lists every valid node/edge/status value. |
| `read_apodexis_graph(folder)` | Returns the folder's current `apodexis.json` + a summary. |
| `write_apodexis_graph(folder, title, nodes, edges?, branches?)` | Creates/overwrites the graph (validated before writing). |
| `add_to_apodexis_graph(folder, nodes?, edges?, branches?, title?)` | Upserts nodes/edges by id into an existing (or new) graph. |
| `validate_apodexis_graph(folder)` | Checks the graph will import cleanly. |

Every write is validated against the same contract the app decodes
([format spec](../../skills/apodexis-proof-graph/reference/format-spec.md)); on any
error nothing is written and the errors are returned to the agent to fix.

## Install

```sh
cd integrations/mcp
pip install "mcp[cli]"
```

Requires Python 3.10+.

## Configure

**Claude Desktop** — add to `claude_desktop_config.json`
(Settings → Developer → Edit Config):

```json
{
  "mcpServers": {
    "apodexis": {
      "command": "python3",
      "args": ["/absolute/path/to/New project/integrations/mcp/server.py"]
    }
  }
}
```

**Claude Code** — from the repo root:

```sh
claude mcp add apodexis -- python3 "$(pwd)/integrations/mcp/server.py"
```

Restart the client so it picks up the server.

## Use

Ask your agent something like:

> Read `paper.tex`, then build an Apodexis graph of the proof in
> `~/Proofs/MyPaper` — one node per lemma/step, edges for the dependencies, and
> mark anything unproven as an open subgoal.

The agent calls `apodexis_vocabulary`, then `write_apodexis_graph` /
`add_to_apodexis_graph`. When it's done, open `~/Proofs/MyPaper` in Apodexis with
**Open Folder** — the graph appears, auto-arranged.

## Notes

- The server never runs the app; it only reads/writes `apodexis.json` files. Keep
  source files (`.tex`, `.lean`) in the same folder and reference them from nodes
  via `sourceFile` / `sourceLine` so Apodexis can jump to them.
- `apodexis_graph.py` holds the pure logic and has no third-party dependencies, so
  it can be imported and tested without the MCP runtime.
