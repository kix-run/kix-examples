# .hidden/

**Spoiler warning.** This directory contains finished versions of
clusters that the
[Kix docs tutorial sequence](https://kixops.dev/docs/tutorials/) asks
you to build yourself. They live here so the docs build pipeline can
generate accurate command output (`kix check`, `kix build`,
`kix graph`, …) against a real flake without putting the answers in
front of you the moment you `ls`.

The dot-prefix keeps these out of `kix list clusters` and casual
directory listings. Look only when you want the reference answer —
otherwise stop reading and finish the tutorial.

## Layout

```
flake.nix              # separate flake exposing only the hidden clusters
04-from-scratch/       # finished version of the tutorial-04 cluster
```

## Why a separate flake?

Putting these in the main `flake.nix` would make them appear in
`kix list clusters` for anyone running the public examples, which
defeats the spoiler protection. The docs pipeline points its
`--flake` at `.hidden/` when it needs to capture output from a
"finished tutorial" cluster.
