# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root.
- **`docs/decisions.md`**: this repo's decision log. Read the sections
  that touch the area you are about to work in.
- **`docs/spec-v1.md`**: what the keyboard must do. Behaviour questions
  are answered there before they are answered by reading code.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## Where decisions are recorded

This repo keeps its architecture decisions in a single numbered file,
[docs/decisions.md](../decisions.md), rather than one file per decision
under `docs/adr/`. Each entry names the difficulty first and cites the
commits that prove it. New decisions append there; `docs/adr/` is unused.

When a skill says "read the ADRs", read `docs/decisions.md`.

## File structure

Single-context repo:

```
/
├── CONTEXT.md
├── docs/
│   ├── decisions.md      ← the decision log (ADRs)
│   ├── spec-v1.md        ← behaviour spec
│   ├── orientation.md    ← what we are building, current state
│   └── vm-handoff.md     ← test lab operating manual
└── daemon/, tools/, *.qml
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag decision conflicts

If your output contradicts an entry in `docs/decisions.md`, surface it explicitly rather than silently overriding:

> _Contradicts decisions §3 (the helper compiles its own keymap), but worth reopening because…_

Treat the "Dead ends — do not retry" list at the bottom of that file as
binding. Every item on it was shipped and withdrawn once already.
