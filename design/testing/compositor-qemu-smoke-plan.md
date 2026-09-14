# Compositor QEMU boot-smoke plan (Wave SSS)

**Status:** DESIGN + PREREQUISITE SCOPING ONLY. Nothing under
`tools/boot/compositor-smokes/` is runnable today. Each `.sh` in that
directory is a stub that documents intent and exits 77 (skip). Do not
wire any of these into `tools/run-smoke.sh`'s `MODE` dispatcher until
the prerequisite gaps in §3 close for that fixture.

**Scope:** five candidate boot-smoke fixtures (COMP-QM-01..05) that
would exercise the compositor stack end-to-end once it exists. This
doc records what exists, what's missing, and the order in which the
gaps should close.

---

## 1. Current state

### 1.1 Two compositor lineages exist in this tree, not one

The task naming this wave conflates two separate, only partly
reconciled design efforts. Before any fixture above COMP-QM-01 can be
wired for real, pick one:

* **R102 (CPU-side framebuffer track)** —
  `design/graphics/r102-user-plan.md`. Specs `svc-compositor` and
  `svc-wm` as **new satellite repos** (`paideia-os/svc-compositor`,
  `paideia-os/svc-wm`), neither created. This doc is where the names
  `svc-compositor`, `svc-wm`, and a `KIND_FB_SCANOUT` **stub** cap
  first appear (R102.M1-002: "`caps.decl` (KIND_FB_SCANOUT stub,
  ...)"). It already specs its own fingerprints — `SVC-COMPOSITOR
  WIRE-PROTOCOL FROZEN OK`, `SVC-WM REGISTER OK`, etc. — none emitted
  anywhere because no source exists for either service.
* **R113 (GPU-native track)** — `design/graphics/r113-gpu-native-gui.md`
  + `design/graphics/r113-m1-substrate.md`. Kernel-side substrate only:
  `KIND_SURFACE` (0x1B8) is real and substantial —
  `src/kernel/core/cap/kind_surface.pdx` (1040 lines: row pool,
  `surface_mint`/`surface_destroy`, 5 fingerprint tags) and
  `src/kernel/core/cap/handlers/cap_handler_surface.pdx` (356-line
  6-op dispatcher), wired into the main cap-invoke table at
  `src/kernel/core/cap/invoke.pdx:1260` (`call_kind_surface`). This is
  **not** a "WEAK stub" — M1 is code-complete per
  `r113-gpu-native-gui.md`'s own status line ("the compositor kernel
  and its first client are code-complete and QEMU-verified"). There is
  no `KIND_FB_SCANOUT` kind in this track; the nearest analog is
  `KIND_SCANOUT_LEASE` (0x188, `src/kernel/core/cap/kind_scanout_lease.pdx`,
  G2.M1 — direct-scanout plane leases, a different authority than a
  compositor-mediated framebuffer). R113.M2 (window manager) through M5
  (session/seat) — the layer that would actually make `svc-wm`-shaped
  behavior real — are still open, gated on M1.

**This doc's fixtures name things from both lineages** (task brief:
`svc-compositor`, `svc-wm`, `postui-desktop`, `KIND_FB_SCANOUT`,
`KIND_SURFACE`). Treat the fixture names below as placeholders for
"whichever daemon eventually owns this responsibility" — see G1.

### 1.2 What actually exists today

| Component | State |
|---|---|
| `src/user/compositor/*.pdx` (30 files) | Library/data-model modules (surface_commit, layer_tree, tiling_bsp, damage_kind, etc. — PWP vocabulary, `design/compositor/pwp-spec-*.md`). **No entry point.** `grep -l "fn main"` over the directory returns nothing — these are not a linked or spawnable daemon. |
| `svc-compositor` daemon | Does not exist. No source anywhere in this monorepo; R102 specs it as an uncreated satellite repo. |
| `svc-wm` daemon | Does not exist. Same as above — spec-only, uncreated repo. |
| `src/user/postui-desktop/entry.pdx` | Exists, 115 lines, explicitly marked "LIFECYCLE-SKELETON SCOPE... not yet a linked, spawned process" — `tools/build-user.sh` has an active exclusion branch for `postui-desktop/*`. Compiles/type-checks; init does not fork+execve it. |
| `KIND_SURFACE` kernel substrate | Real, code-complete (R113.M1). Mint/destroy/dispatch wired. No userspace-reachable mint syscall confirmed for a ring-3 daemon to use on client connect (G7). |
| `KIND_SCANOUT_LEASE` | Real (G2.M1, 1233 lines), a different authority (direct-scanout plane lease) than the R102 `KIND_FB_SCANOUT` stub the brief's name evokes. |
| `tools/run-qemu.sh` | No compositor bring-up path at all — no `COMPOSITOR_INIT_ENABLE`, no userspace-daemon spawn sequencing knob. Confirmed by `grep -i compositor tools/run-qemu.sh` (zero hits). |
| Fingerprints named in this wave (`COMP INIT OK`, `SVC-COMP READY host_id=<n>`, `SVC-WM REGISTER OK`, `PU-DT UP status_bar=OK terminal=OK`, `COMPOSITOR E2E OK client=1 surface=1 frames>=60`) | None exist in source today. `SVC-WM REGISTER OK` collides in spirit (not string-identical) with R102's already-specced `SVC-WM REGISTER OK` fingerprint in `r102-user-plan.md` — reconcile against that doc rather than mint a second, divergent contract (see G6). |

**Net:** everything above kernel-substrate level (R113.M1) is
unimplemented. COMP-QM-01 is the only fixture with a plausible near-term
path; COMP-QM-02..05 each require a daemon, a spawn wire, or both that
do not exist.

---

## 2. Fingerprint-contract note (applies to every fixture below)

`tools/verify-fingerprint-coverage.sh` requires every asserted marker
to contain `OK` as a whole word (`design/testing/fingerprint-coverage.md`
§2), and `run-smoke.sh --fingerprint` does **literal ordered-substring**
matching — no wildcards. Two of the brief's proposed fingerprints need
revision before they can be wired as real goldens:

* `SVC-COMP READY host_id=<n>` — no `OK` token (coverage-gate reject)
  and `<n>` is a placeholder, not a literal (matcher reject). Proposed
  fix: `SVC-COMP READY OK host_id=0` for a single-host QEMU boot,
  generalize the placeholder only if/when the matcher gains pattern
  support.
* `COMPOSITOR E2E OK client=1 surface=1 frames>=60` — the `frames>=60`
  clause cannot be expressed as a literal substring against a
  variable frame count. Proposed fix: emit a fixed sentinel once a
  frame-count threshold is crossed internally (e.g. the client emits
  `COMPOSITOR E2E OK client=1 surface=1 frames=60` exactly once, at
  the 60th frame) rather than encoding an inequality in the golden.

The stub fixtures in `tools/boot/compositor-smokes/` carry both the
brief's original string (in comments, for traceability) and the
coverage-gate-compliant revision (in the `.txt` golden) where they
differ.

---

## 3. Prerequisite gaps

| # | Gap | Blocks |
|---|---|---|
| G1 | R102 vs R113 compositor lineage unreconciled — no decision on which daemon shape (`svc-compositor` satellite repo vs. an in-monorepo R113.M2+ window-manager module) owns `KIND_SURFACE`/scanout mediation. | All of COMP-QM-02..05 |
| G2 | `svc-compositor` daemon has zero source. Needs: repo-or-module scaffold, `main`/entry, `svc_broker` registration, an init-handoff spawn wire. | COMP-QM-02..05 |
| G3 | `svc-wm` daemon has zero source and zero design beyond the R102 issue list (no freeze doc comparable to `r113-m1-substrate.md`). | COMP-QM-03..05 |
| G4 | `postui-desktop` has a skeleton entry point but no process-spawn wire — init never forks/execves it, and `tools/build-user.sh` explicitly excludes it from the link step. | COMP-QM-04, 05 |
| G5 | `tools/run-qemu.sh` / `kernel_main.pdx` init sequencing has no compositor-bringup gate (`COMPOSITOR_INIT_ENABLE` or equivalent) to conditionally run compositor module init before/instead of the plain shell handoff. | COMP-QM-01..05 |
| G6 | Fingerprint contracts named in this wave are either unminted (§2) or collide informally with R102's pre-existing `r102-user-plan.md` fingerprint table — needs one authoritative fingerprint appendix, not two. | COMP-QM-02..05 |
| G7 | No confirmed userspace-reachable (ring-3) syscall path to mint a `KIND_SURFACE` capability on client connect — current mint wiring is exercised kernel-internally (witness chain), not proven from a ring-3 caller via `sys_cap_mint`. | COMP-QM-02..05 |
| G8 | No reference demo client exists that would speak whatever wire protocol wins G1 (needed for COMP-QM-05's "one demo client" leg). | COMP-QM-05 |

---

## 4. Sequenced rollout

1. **SSS-01 (`boot_r113_compositor`, COMP-QM-01) — kernel-only.**
   Closest to feasible: only needs G5 (an init-time gate that runs
   `src/user/compositor/*.pdx` module self-checks or a kernel-side
   init probe and emits one fingerprint) plus picking/emitting the
   `COMP INIT OK` marker somewhere real. No daemon dependency.
2. **SSS-02 (`boot_svc_compositor`, COMP-QM-02) — first userspace daemon.**
   Needs G1 (pick the lineage) → G2 (build the daemon) → G7 (prove a
   ring-3 mint path) before the fixture can boot past SSS-01's bar.
3. **SSS-03 (`boot_svc_wm`, COMP-QM-03) — second userspace daemon.**
   Needs everything SSS-02 needs, plus G3 (svc-wm design + source) and
   a registration handshake against the now-running svc-compositor.
4. **SSS-04 (`boot_postui_desktop`, COMP-QM-04) — full desktop shell.**
   Needs SSS-03's stack live, plus G4 (postui-desktop spawn wire and
   re-inclusion in `tools/build-user.sh`'s link step).
5. **SSS-05 (`boot_compositor_full`, COMP-QM-05) — E2E with a demo client.**
   Needs SSS-04's stack live, plus G8 (a reference client) and the
   revised frame-count fingerprint from §2.

Each stage is a strict superset of the previous stage's gaps; do not
attempt to parallelize SSS-02..05 ahead of their listed dependencies.

---

## 5. Fixture inventory

| ID | Fixture | Fingerprint (coverage-gate-compliant) | Runnable? |
|---|---|---|---|
| COMP-QM-01 | `tools/boot/compositor-smokes/boot_r113_compositor.sh` | `COMP INIT OK` | No — blocked on G5 |
| COMP-QM-02 | `tools/boot/compositor-smokes/boot_svc_compositor.sh` | `SVC-COMP READY OK host_id=0` | No — blocked on G1, G2, G7 |
| COMP-QM-03 | `tools/boot/compositor-smokes/boot_svc_wm.sh` | `SVC-WM REGISTER OK` | No — blocked on G1, G2, G3, G7 |
| COMP-QM-04 | `tools/boot/compositor-smokes/boot_postui_desktop.sh` | `PU-DT UP status_bar=OK terminal=OK` | No — blocked on G1-G4, G7 |
| COMP-QM-05 | `tools/boot/compositor-smokes/boot_compositor_full.sh` | `COMPOSITOR E2E OK client=1 surface=1 frames=60` | No — blocked on G1-G8 |

Each fixture's expected fingerprint lives alongside it as
`expected-<name>.txt`, matching the `tests/r8/expected-*.txt`
convention used by `tools/run-smoke.sh --fingerprint`.

---

## 6. Non-goals of this wave

* No kernel, userspace, or `tools/run-qemu.sh`/`run-smoke.sh` code
  changes. This wave is design + stub scripts only.
* No attempt to run QEMU. Every stub script below exits 77
  (skip) unconditionally.
* No resolution of G1 (lineage choice) — that is an
  osarch/softarch decision for a future wave, flagged here so it
  isn't rediscovered from scratch.
