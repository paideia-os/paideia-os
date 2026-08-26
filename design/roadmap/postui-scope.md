# postui — scope pointer

**Date:** 2026-08-25
**Authors:** osarch + softarch combined pass

This is a **stub**. The authoritative design document for `postui` (the
paideia-os TUI widget library, Ratatui-inspired, cap-based,
semantically-queryable) lives in its own repo, not here:

**[`paideia-os/postui` — `docs/design.md`](https://github.com/paideia-os/postui/blob/main/docs/design.md)**

That document covers: the feasibility assessment against `paideia-as`
v0.22.0 (what ports cleanly, what needs a `.pdx`-native workaround, and
the one real non-blocking compiler gap it surfaces); the `KIND_TUI_CANVAS`
cap architecture (ordinal `0x1A6`, derived over `KIND_MEMORY`); the
rendering pipeline and semantic-pipe integration; the integer-only layout
engine; the full widget catalog; the three reference apps (`postui-top`,
`postui-hex`, `postui-dmesg`); the cross-repo dependency chain; and the
milestone/issue plan.

## What lives in this monorepo

- **`R89 — KIND_TUI_CANVAS substrate`** (milestone, this repo): the
  kernel-side cap kind, dispatch, cell-diff/ANSI-emit path, damage
  bookkeeping, and boot witness `postui` needs before it can render
  against a real canvas. See `docs/design.md` §2.1 and §5.5 in `postui`.
- `src/kernel/core/cap/kind_tui_canvas.pdx` (landing under R89.M1-001).

## What lives elsewhere

- `paideia-os/postui` — the library itself (M1–M5).
- `paideia-os/postui-top` / `-hex` / `-dmesg` — the three reference apps.
- `paideia-os/paideia-as` — milestone `R89-XREPO — postui-required
  encoder gaps` (exactly one real, non-blocking gap: scalar `f32`/`f64`
  arithmetic codegen; postui v1 ships on an all-integer Q32.32
  fixed-point module instead — see `docs/design.md` §1.4/§5.6).

Do not duplicate content here — update the `postui` repo's `docs/design.md`
and let this stub's links stay stable.
