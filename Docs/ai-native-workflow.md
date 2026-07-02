# AI-native workflow

Most people don't have time to hand-build a large proof graph. Apodexis is
designed so an AI agent can build it for you from work you already have.

## The idea

An Apodexis project is a folder containing an `apodexis.json` graph. The import
format (documented in
[the format spec](../skills/apodexis-proof-graph/reference/format-spec.md)) is a
stable, forgiving JSON contract with string ids. That makes it a clean target for
any agent that can write files — no live API or running app required.

```
  You ──▶  "Turn my paper.tex into an Apodexis graph"
   │
   ▼
  AI agent (with the apodexis-proof-graph skill)
   │   reads the proof, decomposes it into typed nodes + semantic edges,
   │   writes a folder, and validates it
   ▼
  MyProof/
    apodexis.json     ← the graph (no positions — Apodexis lays it out)
    paper.tex         ← your source, linked from nodes via sourceFile/sourceLine
   │
   ▼
  You ──▶  Apodexis › Open Folder › MyProof   (graph appears, auto-arranged)
```

## For agents

Use the bundled skill:
[`skills/apodexis-proof-graph/SKILL.md`](../skills/apodexis-proof-graph/SKILL.md).
It covers which node/edge types to choose, how to record open obligations as
subgoals, how to link nodes back to source files, and a required validation step:

```sh
python3 skills/apodexis-proof-graph/scripts/validate.py path/to/apodexis.json
```

The validator mirrors the app's decoder, so a `✓` means the file will import
cleanly.

## For users

1. Ask your agent to convert a proof, pointing it at this skill.
2. Open the result in Apodexis:
   - **Open Folder** for a source-linked folder (so `sourceFile` links resolve), or
   - **Import JSON** for a standalone graph file.
3. Apodexis auto-arranges positionless graphs. Refine from there — every node and
   edge is editable, and drag-to-connect / undo work as usual.

## Try it now

Open [`skills/apodexis-proof-graph/examples/sqrt2-irrational/`](../skills/apodexis-proof-graph/examples/sqrt2-irrational/)
with **Open Folder**. It's a validated graph of the classic proof that √2 is
irrational, including a Lean formalization node with a `sorry` hole that shows up
in the Open Goals tracker.
