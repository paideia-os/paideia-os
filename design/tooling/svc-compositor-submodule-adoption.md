# svc-compositor submodule adoption — sequencing plan (not yet executed)

**Status:** Design (wave α-05). Docs-only. **Do not adopt yet** — this
document is sequencing, not an instruction to run the adoption.
**Date:** 2026-09-14.
**Precedent:** `tools/user/shell` adoption (commit `73183ba`, "Wave 20:
adopt tools/user/shell as submodule (fix #2438)"), itself Phase A of
`design/user/in-tree-vs-satellite-transition.md`.

## 1. How the shell precedent actually worked (and why svc-compositor differs)

The shell adoption was a **conversion**, not a fresh add: `tools/user/
shell/` already existed as a live, untracked local clone at HEAD
`c355368` with 20+ real commits (shell_main/REPL/line-reader/history/
tokenizer). The adoption commit's whole job was: add a `.gitmodules`
entry pointing at `github.com/paideia-os/shell`, pin it at the commit
already checked out, and verify the build stayed green. No new code
was fetched; a directory that was already there just became tracked.

**`tools/user/svc-compositor` does not exist in this tree at all** —
confirmed: no `tools/user/svc-compositor` directory, no untracked
clone, nothing in `.gitmodules`. This adoption would be a **fresh
add** (`git submodule add https://github.com/paideia-os/svc-compositor
tools/user/svc-compositor`, pinned at whatever commit backs the v1.4.0
tag), not a conversion. The shell precedent's "verify nothing new is
being pulled in" step doesn't apply the same way — a fresh add pulls
in real, previously-unreviewed code (window table, damage/commit
decode, 60 Hz render loop, input pump per `ECOSYSTEM_STATUS.md`) for
the first time inside this monorepo's tree.

## 2. Why not now — the sequencing dependency

Per `design/graphics/compositor-split-decision.md` (α-01) Phase 3,
submodule adoption is the *last* step, gated on Phase 2 (vocab
adoption, α-03) landing and being verified. Adopting the submodule
before that would freeze `svc-compositor`'s current R102-v0 wire
shapes — the ones that don't consume `KIND_SURFACE`/`KIND_FRAMEBUFFER`/
`KIND_SEAT` — into a pinned SHA inside this monorepo, creating exactly
the kind of "adopted but stale" drift `ECOSYSTEM_STATUS.md` already
flags for the coreutils submodules ("this monorepo's pinned submodule
SHAs for cat/cp/mv/rm/doc/shell/libpdx-argv still point at commits near
their old v1.0.0/v1.1.0 tags — the upstream recovery exists but has not
yet been pulled"). Adopting early just relocates that same staleness
hazard onto a repo that doesn't have it yet.

## 3. Proposed sequencing (three steps, none executed by this document)

### Step 1 — precondition: vocab adoption lands upstream (blocks on α-03)

`svc-compositor` adopts the `KIND_SURFACE`/`KIND_FRAMEBUFFER`/
`KIND_SEAT` wire mapping from `design/graphics/compositor-vocab-
adoption.md`, tagged as a real release (matching the shell precedent's
"pin at a real, inspectable HEAD" bar — not a WIP branch).

### Step 2 — fresh submodule add, pinned at the post-vocab-adoption tag

```
git submodule add https://github.com/paideia-os/svc-compositor \
    tools/user/svc-compositor
git -C tools/user/svc-compositor checkout <post-vocab-adoption-tag>
```

Add the `.gitmodules` stanza in the same alphabetized block as the
other 15 `tools/user/*` entries. Verify the submodule carries the
shape the transition doc's precedent expects before committing:
`caps.decl`, `manifest.pdxproj`, `CHANGELOG.md`, `link.ld`, `src/`,
`tests/` — the same file set `tools/user/shell` carries today. If
`svc-compositor` is missing any of these (its current README/LICENSE-
only-scaffold history per `design/round-retrospectives/r102-closure.md`
suggests the repo's scaffolding maturity should be checked, not
assumed), that is a blocking gap to fix upstream first, not something
to patch around in the monorepo.

### Step 3 — build wiring, deliberately NOT `bin_seeds`

Unlike coreutils (which target `/bin/<name>` via
`tools/bin_seeds.manifest`, per the transition doc's Phase B),
`svc-compositor` is not a boot-early `/bin` entry — it is a long-running
service `init` would need to spawn post-boot. Step 3 is scoped
narrowly to **making the submodule buildable** (`tools/build.sh`
drives `paideia-as compile` inside it, same as every other
`tools/user/*` submodule) — it explicitly does **not** include wiring
`init.pdx`'s spawn cascade to fork/exec it. That wiring is a separate,
later decision that should cite whichever of `svc-compositor` or
`postui-desktop` wins the "first real client" race named in
`design/graphics/compositor-lineage.md` §4 point 4 — adopting the
submodule must not be read as pre-committing to that race's outcome.

## 4. Explicit non-goals of this document

- Does not run `git submodule add`.
- Does not modify `.gitmodules`.
- Does not modify `tools/build.sh` or `tools/build-user.sh`.
- Does not decide whether `svc-compositor` or `postui-desktop` becomes
  the boot-spawned compositor client — that is `compositor-lineage.md`'s
  open question, not this document's.

When Step 1 lands, re-open this document (or its successor) to convert
§3 into an executed adoption commit, following the shell precedent's
verification bar: build green post-adoption, commit message citing
this plan and the fixed issue number.
