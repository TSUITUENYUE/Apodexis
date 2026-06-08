# Apodexis

Apodexis is a SwiftUI app for organizing long mathematical and scientific proof chains as typed dependency graphs rather than generic mind maps.

## Targets

- `ApodexisMac`: native macOS app
- `ApodexisIOS`: native iOS/iPadOS app

Both targets share the same SwiftUI views, models, graph logic, local persistence, and export code.

## Implemented MVP

- Typed proof nodes: theorem, definition, assumption, lemma, claim, goal, reduction, case split, induction step, construction, counterexample, failed attempt, formal code.
- Semantic edges: uses, implies, reduces to, equivalent to, case of, generalizes, contradicts, depends on assumption, forks from, refines.
- Branch/fork workflow for alternative proof strategies.
- Structured node inspector with statement, context, assumptions, proof sketch, formal code, subgoals, symbols, and relations.
- Lean/Coq/Isabelle/LaTeX-oriented formal hole detection for tokens such as `sorry`, `admit`, `Admitted`, `oops`, and `TODO`.
- Open goal tracker.
- Draggable graph canvas.
- Local JSON persistence in Application Support.
- Markdown export and clipboard copy.
- Human-editable JSON import via the `Import JSON` toolbar button.

## Import Template

Use [Templates/apodexis-import-template.json](Templates/apodexis-import-template.json) as the starting point.

The import format is intentionally simpler than the internal stored JSON. You can use string IDs such as `main-theorem`; the app converts them to internal UUIDs during import.

Important enum values:

- `type`: `theorem`, `definition`, `assumption`, `lemma`, `claim`, `goal`, `reduction`, `caseSplit`, `inductionStep`, `construction`, `counterexample`, `failedAttempt`, `formalCode`
- edge `type`: `uses`, `implies`, `reducesTo`, `equivalentTo`, `caseOf`, `generalizes`, `contradicts`, `dependsOnAssumption`, `forksFrom`, `refines`
- node `status`: `open`, `inProgress`, `blocked`, `needsReview`, `proven`, `failed`
- branch `status`: `active`, `stuck`, `abandoned`, `merged`
- `formalDialect`: `latex`, `lean`, `coq`, `isabelle`, `pseudocode`, `swift`, `python`
- `verification`: `unchecked`, `partial`, `checking`, `verified`, `failed`

## Build

```sh
xcodebuild -project Apodexis.xcodeproj -scheme ApodexisMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apodexis.xcodeproj -target ApodexisIOS -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

The current machine has the iOS simulator SDK but no installed simulator runtime, so the iOS target has been compile-checked with the simulator SDK rather than launched in a simulator.
