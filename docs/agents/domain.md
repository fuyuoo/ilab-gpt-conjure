# Domain Docs

This is a single-context repository.

## Before exploring

- Read `CONTEXT.md` at the repository root.
- Read relevant decisions under `docs/adr/`.
- If either is absent, proceed silently; domain-modeling workflows create them lazily.

## Layout

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
└── codex_image/
```

## Vocabulary

Use the canonical terms defined in `CONTEXT.md` in issue titles, specifications, tests, code review, and implementation notes.

Avoid synonyms explicitly listed under `_Avoid_`. If a required concept is missing, note it for `/domain-modeling` instead of silently inventing competing terminology.

## Architectural decisions

If proposed work conflicts with an existing ADR, identify the conflict explicitly before changing the decision.
