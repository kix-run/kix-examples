# kix-examples

A series of numbered example clusters teaching Kix patterns. Each
example builds on the previous one.

## Authoring rules

- **Concepts in examples must be supported by prior examples.** Don't
  reference `deps`, `ref`, `aliases`, etc. in `02-` if `01-` hasn't
  introduced them. A reader walking the examples in order should never
  hit a term they haven't seen before.

- **Explicit is better than implicit.** When something can be written
  out (e.g. `({ ref, ... }: { ... })` even when `ref` is unused, or
  `deps.backend = ref.ns.inst` even when name-matching would auto-wire),
  prefer the explicit form. The implicit shortcut can be shown as a
  comment or "Things to try" note.
