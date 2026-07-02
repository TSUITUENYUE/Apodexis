---
name: apodexis-proof-graph
description: >-
  Convert a mathematical or scientific proof — from LaTeX, a paper, plain notes,
  or a photo of handwritten work — into an Apodexis proof-graph project
  (apodexis.json). Use whenever the user wants to turn a written proof or draft
  into an Apodexis graph, visualize a proof's dependency structure, or build,
  extend, or fix an apodexis.json file.
---

# Building Apodexis proof graphs

Apodexis is a macOS app that shows a proof as a **typed dependency graph**:
each idea is a node with a type (theorem, lemma, assumption, …) and nodes are
joined by **semantic edges** (`implies`, `uses`, `reducesTo`, `contradicts`, …).
Your job is to read a proof the user already has and emit an `apodexis.json` file
that captures its structure. The human then opens it in Apodexis — no manual
graph-building required.

## Workflow

1. **Read the source.** Accept LaTeX, a PDF/paper, plain-text notes, or an image
   of handwritten work. Identify the goal, the assumptions, the intermediate
   results, and how they depend on each other.
2. **Decompose** into nodes and edges (see below). One mathematical *move* = one
   node. One *dependency* = one edge.
3. **Write `apodexis.json`** in the import format (see the cheat-sheet below and
   `reference/format-spec.md` for the full contract). **Omit `position`** on every
   node — Apodexis auto-arranges positionless graphs on open.
4. **Validate** — always run the validator before handing off:
   ```sh
   python3 scripts/validate.py path/to/apodexis.json
   ```
   Fix every `✗` error until it prints `✓ Valid Apodexis import`.
5. **Hand off** (see "Delivering to the user").

## Decomposition: how to turn a proof into a graph

Aim for one node per *claim or move*, not one node per sentence. A short proof is
5–12 nodes; a paper section is 15–40. Prefer clarity over completeness.

**Pick the node `type` by role:**

| The text is…                                   | Use type          |
|------------------------------------------------|-------------------|
| The main result being proved                   | `theorem`         |
| A supporting result used by the theorem        | `lemma`           |
| A small proven step inside the argument        | `claim`           |
| A statement believed but not yet proved        | `conjecture`      |
| A definition of a term/object                  | `definition`      |
| A hypothesis / "suppose that…"                 | `assumption`      |
| The overall plan ("proof by contradiction")    | `strategy`        |
| "It suffices to show…" / reframing the goal    | `reduction`       |
| A split into cases                             | `caseSplit`       |
| The inductive step                             | `inductionStep`   |
| An explicit object being constructed           | `construction`    |
| A concrete example that refutes something      | `counterexample`  |
| An approach that was tried and failed          | `failedAttempt`   |
| The closing statement / QED                    | `conclusion`      |
| A goal/open problem you're tracking            | `goal`            |
| A block of Lean/Coq/Isabelle/LaTeX code        | `formalCode`      |

**Pick the edge `type` by relationship (edges point from cause → effect):**

| Meaning                                          | Use type              |
|--------------------------------------------------|-----------------------|
| A logically forces B                             | `implies`             |
| B invokes/relies on A                            | `uses`                |
| Proving A is reduced to proving B                | `reducesTo`           |
| A and B are equivalent                           | `equivalentTo`        |
| B is one case of A                               | `caseOf`              |
| A generalizes B                                  | `generalizes`         |
| A contradicts B (contradiction reached)          | `contradicts`         |
| B depends on assumption A                        | `dependsOnAssumption` |
| B is an alternative branch off A                 | `forksFrom`           |
| B refines/sharpens A                             | `refines`             |
| A provides evidence for B                        | `supports`            |
| B requires A as a prerequisite                   | `requires`            |
| A motivates B                                    | `motivates`           |
| A blocks/obstructs B                             | `blocks`              |
| A diagnoses why B fails                          | `diagnoses`           |
| A is a formal witness for B                      | `witnesses`           |
| A constrains B                                   | `constrains`         |
| A summarizes B                                   | `summarizes`          |

**Fill the fields that carry the math:**
- `statement` — the precise claim, in LaTeX (Apodexis renders common LaTeX).
- `context` / `proofSketch` — surrounding setup and the argument in prose.
- `assumptions` — array of hypotheses this node relies on.
- `symbols` — `{symbol, meaning, scope}` for notation you introduce.
- `subgoals` — remaining obligations as `{title, detail, status}`; these feed the
  app's **Open Goals** tracker. Mark `status: "open"` for anything not yet done.

**Status conventions** (be honest — this is what makes the graph useful):
- Node `status`: `proven` for finished steps, `open`/`inProgress` for unfinished,
  `needsReview` when you inferred something the source left implicit,
  `failed`/`abandoned` for dead ends worth recording.
- If the source has real gaps, create `open` subgoals so the user sees the work
  that remains rather than a falsely "complete" graph.

**Formal code & holes:** put Lean/Coq/etc. in `formalCode` with the matching
`formalDialect`. Apodexis flags holes (`sorry`, `admit`, `Admitted`, `oops`,
`TODO`) automatically, so leave them in — they become tracked obligations.

## Source-linked workspaces (recommended for real projects)

If the user has actual source files (a `.tex` paper, a Lean project), produce a
**folder**, not a lone JSON:

```
MyProof/
  apodexis.json      ← the graph
  paper.tex          ← their source
  Main.lean
```

Give nodes a `sourceFile` (relative to the folder) and `sourceLine`. In Apodexis
each such node gets an "open source" action that jumps to the file. The user opens
this with **Open Folder**. (A lone JSON opened with **Import JSON** can't resolve
`sourceFile` paths, so use a folder whenever source links matter.)

## Output cheat-sheet

```jsonc
{
  "title": "Project title",                 // required
  "branches": [                             // optional; a "main" branch is created if omitted
    { "id": "main", "name": "Main proof", "status": "active", "color": "blue" }
  ],
  "nodes": [                                // required, non-empty
    {
      "id": "thm",                          // required, unique string id you choose
      "type": "theorem",                    // default "claim"
      "title": "…",                         // required
      "branch": "main",                     // default: first branch
      "statement": "$…$", "context": "…", "proofSketch": "…",
      "status": "proven",                   // default "open"
      "verification": "unchecked",          // default "unchecked"
      "assumptions": ["…"],
      "subgoals": [{ "title": "…", "detail": "…", "status": "open" }],
      "symbols":  [{ "symbol": "p", "meaning": "…", "scope": "…" }],
      "formalDialect": "lean", "formalCode": "…",
      "sourceFile": "Main.lean", "sourceLine": 12,
      "tags": ["…"]
      // NO "position" — let Apodexis lay it out
    }
  ],
  "edges": [                                // optional
    { "from": "thm", "to": "lemma1", "type": "uses", "label": "optional" }
  ]
}
```

Enum values are forgiving: `"reduces to"`, `"reducesTo"`, and `"REDUCES_TO"` all
resolve. The full list of every type/status value is in `reference/format-spec.md`.
A complete, validated example is in `examples/sqrt2-irrational/`.

## Delivering to the user

After validating, tell the user exactly how to open it:
- **Folder** (with source files): *"In Apodexis, click **Open Folder** and choose
  the `MyProof` folder."*
- **Lone JSON**: *"In Apodexis, click **Import JSON** and choose `apodexis.json`."*

Either way Apodexis arranges the graph automatically. Mention the node/edge counts
and call out anything you marked `open` or `needsReview` so they know what to check.
