# Apodexis import format — full contract

This is the authoritative field-by-field reference for the `apodexis.json` import
format, mirroring the decoder in `Apodexis/Store/ProofStore.swift`
(`ApodexisImportDocument`). The validator (`scripts/validate.py`) enforces
everything here.

## How Apodexis reads a file

Both **Import JSON** and **Open Folder** call the same loader. It first tries to
decode the file as Apodexis's *internal* saved format; if that fails, it decodes
this *import* format. So you only ever author the import format described here.

- **Import JSON** → creates a new managed project (copied into app storage).
  `sourceFile` paths will **not** resolve, because the original folder is not the
  project directory.
- **Open Folder** → opens the folder in place. Apodexis looks for `apodexis.json`
  (then `proof-chain.json`, `project.json`, `workspace.json`, then any `.json`).
  `sourceFile`/`sourceLine` resolve relative to the folder. Use this for
  source-linked workspaces.

When **every** node omits `position`, Apodexis runs Auto Layout on open. If any
node has a `position`, all positions are respected as given.

## Top-level object

| Field      | Type              | Required | Notes                                             |
|------------|-------------------|----------|---------------------------------------------------|
| `title`    | string            | ✅       | Project title.                                    |
| `nodes`    | array of Node     | ✅       | Must be non-empty.                                |
| `branches` | array of Branch   | optional | If omitted/empty, one branch `id:"main"` is made. |
| `edges`    | array of Edge     | optional | Defaults to none.                                 |

## Branch

| Field        | Type   | Required | Default    | Notes                                             |
|--------------|--------|----------|------------|---------------------------------------------------|
| `id`         | string | ✅       | —          | Unique; referenced by nodes/branches.             |
| `name`       | string | ✅       | —          | Display name.                                     |
| `summary`    | string | optional | `""`       |                                                   |
| `status`     | enum   | optional | `active`   | BranchStatus (see below).                         |
| `color`      | string | optional | `blue`     | One of blue, pink, green, orange, purple, red.    |
| `parent`     | string | optional | none       | Another branch `id` (unknown ⇒ ignored).          |
| `forkedFrom` | string | optional | none       | A node `id` this branch forks from (unknown ⇒ ignored). |

## Node

| Field           | Type              | Required | Default      | Notes                                       |
|-----------------|-------------------|----------|--------------|---------------------------------------------|
| `id`            | string            | ✅       | —            | Unique; referenced by edges/branches.       |
| `title`         | string            | ✅       | —            | Short label (LaTeX allowed).                |
| `branch`        | string            | optional | first branch | Must be a real branch `id` (unknown ⇒ error). |
| `type`          | enum              | optional | `claim`      | NodeKind (see below).                        |
| `statement`     | string            | optional | `""`         | The precise claim (LaTeX).                   |
| `context`       | string            | optional | `""`         | Setup / surrounding assumptions.            |
| `proofSketch`   | string            | optional | `""`         | The argument in prose.                       |
| `formalCode`    | string            | optional | `""`         | Lean/Coq/etc. source; holes auto-detected.  |
| `formalDialect` | enum              | optional | `latex`      | FormalDialect (see below).                   |
| `status`        | enum              | optional | `open`       | ProofStatus (see below).                     |
| `verification`  | enum              | optional | `unchecked`  | VerificationStatus (see below).             |
| `position`      | `{x,y}` numbers   | optional | auto         | Omit to let Apodexis lay out the graph.     |
| `assumptions`   | array of string   | optional | `[]`         |                                             |
| `subgoals`      | array of Subgoal  | optional | `[]`         | Feeds the Open Goals tracker.               |
| `symbols`       | array of Symbol   | optional | `[]`         |                                             |
| `tags`          | array of string   | optional | `[]`         |                                             |
| `sourceFile`    | string            | optional | none         | Path relative to the opened folder.         |
| `sourceLine`    | integer           | optional | none         |                                             |

**Subgoal:** `{ "title": string (required), "detail": string?, "status": ProofStatus? = open }`

**Symbol:** `{ "symbol": string (required), "meaning": string (required), "scope": string? }`

## Edge

| Field   | Type   | Required | Notes                                        |
|---------|--------|----------|----------------------------------------------|
| `from`  | string | ✅       | Source node `id` (unknown ⇒ error).          |
| `to`    | string | ✅       | Target node `id` (unknown ⇒ error).          |
| `type`  | enum   | ✅       | EdgeKind (see below).                         |
| `label` | string | optional | Short annotation shown on the edge.          |

## Enum vocabularies

Values resolve by exact match first, then by normalization (lowercase, strip
everything but letters/digits). So `caseSplit`, `"case split"`, `"Case_Split"`
all map to `caseSplit`.

- **NodeKind:** `theorem, conjecture, definition, assumption, lemma, claim, proposal, strategy, conclusion, goal, reduction, caseSplit, inductionStep, construction, counterexample, failedAttempt, formalCode`
- **EdgeKind:** `uses, implies, reducesTo, equivalentTo, caseOf, generalizes, contradicts, dependsOnAssumption, forksFrom, refines, supports, requires, motivates, blocks, diagnoses, witnesses, constrains, summarizes`
- **ProofStatus** (node & subgoal): `open, inProgress, blocked, needsReview, proven, failed, abandoned`
- **BranchStatus:** `active, blocked, stuck, abandoned, merged`
- **FormalDialect:** `latex, lean, coq, isabelle, pseudocode, swift, python`
- **VerificationStatus:** `unchecked, checked, partial, checking, verified, failed`

## Hard errors vs. tolerated issues

The import **fails** (nothing loads) on: missing `title`/`nodes`; a node whose
`branch` names a nonexistent branch; an edge whose `from`/`to` names a nonexistent
node; any unresolvable enum value. Duplicate node/branch ids silently collide and
corrupt the graph — the validator treats them as errors. A node `parent`/
`forkedFrom` that references something missing is tolerated (ignored) but the
validator warns.
