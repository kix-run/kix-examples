# kix-examples

Runnable examples used by the Kix tutorials and how-to guides. Numbered
clusters under `tutorials/` form a learning sequence. Scenarios under
`how-to/` are independent fixtures shared by related task guides.

## Audience

**Engineers familiar with Kubernetes, with zero Nix knowledge.** Nix
is the single biggest barrier to Kix adoption, so the examples must
be approachable to someone who has never seen Nix syntax before.

That doesn't mean every example is a Nix tutorial — but:
- The root README must carry a glossary covering every Nix construct
  the examples use.
- The first example (`02-hello-world`) must carry a "New to Nix?"
  pointer to that glossary.
- The first occurrence of a tricky Nix construct (multi-line strings,
  pipe operator, `let ... in`, function-with-rest-args, etc.) should
  get a one-line inline note explaining it. Don't repeat the note on
  subsequent occurrences.

## Authoring rules

- **Tutorial concepts must be supported by prior tutorials.** Don't
  reference `deps`, `ref`, `aliases`, etc. before an earlier example has
  introduced them. A reader walking the examples in order should never hit a
  term they haven't seen before.

- **Every tutorial must declare its prerequisites in both the code and
  the README.** Engineers often skip READMEs, so the code header
  comment must include a `Recommended reading:` line naming the
  specific examples that introduced the concepts in use. The README
  mirrors it as a `> Recommended reading: [...](../NN-name/)` callout
  under the title.

- **Every tutorial must declare what's new.** Code header includes a
  `What's new:` line explaining the brick this example adds on top of
  prior examples. Keeps the per-example focus tight.

- **Explicit is better than implicit.** When something can be written
  out (e.g. `({ ref, ... }: { ... })` even when `ref` is unused, or
  `deps.backend = ref.ns.inst` even when name-matching would auto-wire),
  prefer the explicit form. The implicit shortcut can be shown as a
  comment or "Things to try" note.

- **Explain code in the code, not in the surrounding prose.** When a
  README includes a code snippet, the reader's eyes snap to the code.
  Put the per-line explanation in inline `#` comments on the snippet
  itself. The surrounding prose should frame *why this code matters*,
  not narrate what each line does. A reader should be able to
  understand a snippet without bouncing back and forth between code
  and paragraphs.

- **Keep the voice human, but make the concept do the work.** A little
  informal engineer-to-engineer tone is welcome, but avoid clever
  phrasing when a direct explanation would be clearer. Prefer concrete
  consequences ("nginx rejects larger request bodies") over abstract
  claims ("runtime 5xx", "scar tissue", "guardrail") unless the latter
  genuinely helps the reader.

- **Files that are unchanged from a prior example should say so**
  at the top — point the reader back rather than restating the
  walkthrough. Saves cognitive load and keeps each example focused
  on its actual new brick.

## How-to scenarios

How-to scenarios provide executable source and command output for several
related documentation pages.

- Put scenarios under `how-to/<scenario>/` and register their clusters in the
  root flake. Use stable descriptive cluster names such as
  `how-to-application`.
- Design a scenario around one coherent concern. Reuse it across guides, but
  split out package stacks or platform components that would make the ordinary
  scenario slow or difficult to run.
- Give every cluster a unique namespace so live documentation captures can
  share one kind cluster.
- Keep the checked-in scenario valid and deployable. Broken values, simulated
  drift, and failing probes belong in the documentation capture manifest as
  temporary mutations.
- Wrap substantial reusable fragments in named `# region:NAME` and
  `# endregion:NAME` markers. Names describe the concept, not a docs page.
  Regions in `.nix`, `.sh`, and `.py` files are extracted by the docs build.
- Keep source regions short enough to explain in one place. Prefer several
  focused regions over one region containing a complete large cluster.
- Verify every affected cluster against the current Kix source before updating
  the docs input lock. At minimum, build the cluster manifests. Run live
  captures when the documented behavior depends on Kubernetes.
- Coordinate changes with `kixpkgs/docs/how-to-coverage.json`. A documentation
  change may use a local input override while both repositories are under
  development, but the final docs lock must point to a published revision that
  contains the scenario.
