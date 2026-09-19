# Compositor E2E boot plan (Wave β β-05)

**Status:** DESIGN. Sequences the full stack -- kernel init through a
launched desktop shell -- across work that is landed today, work this
wave (β) adds, and work that remains scoped to future repos/waves.
Authority for the fixture inventory and gap numbering (G1-G8) is
`design/testing/compositor-qemu-smoke-plan.md` (Wave SSS); this doc
does not re-litigate that gap analysis, it sequences the rollout
*through* it and pins the fingerprint chain a real E2E boot is expected
to emit at each stage.

---

## 1. Why this doc exists separately from the Wave SSS smoke plan

`compositor-qemu-smoke-plan.md` enumerates five candidate boot-smoke
*fixtures* (COMP-QM-01..05) and the prerequisite gaps blocking each.
It is fixture-shaped: one row per `.sh` script. This doc is
*sequence*-shaped: one boot, start to finish, with every process that
comes up along the way and the fingerprint each one is expected to
emit, so a future implementer can tell "did the chain get further than
last time" from a raw serial log without cross-referencing five
separate fixture files.

The two docs describe the same underlying system from different axes
and must stay reconciled: a stage lands here exactly when its
corresponding fixture in the smoke plan's gap table flips from
"blocked" to a real assertion.

---

## 2. Stack layers, bottom to top

```
 kernel (ring 0)
   └─ init (PID 1, ring 3)
        ├─ compositor_selftest  (Wave β β-01 -- kernel-module self-check, SHORT-LIVED)
        └─ svc-compositor       (Wave β β-04 spawn wire -- LONG-LIVED daemon, source TBD)
                └─ svc-wm       (G3 -- LONG-LIVED daemon, zero source today)
                        └─ postui-desktop (G4 -- LONG-LIVED shell process)
                                ├─ status bar widget
                                └─ terminal widget
```

Each arrow is a process boundary the parent spawns (fork+execve) or a
protocol connection the child establishes against an already-running
parent (svc-wm registers with svc-compositor; postui-desktop connects
to svc-wm). Only the first two rows exist as real, buildable source in
this monorepo as of this landing.

---

## 3. Sequenced rollout

### Stage 0 -- kernel + init boot (LANDED, pre-Wave-β)

Standard boot chain, unchanged by this wave. Relevant fingerprints, in
order, on a `tools/run-qemu.sh` boot with no flags:

```
INIT ENTERED RING3
init home envp ok [legacy: INIT HOME ENVP OK]
rootfs seed ok [legacy: ROOTFS SEED OK] files=<N>
INIT OK
```

### Stage 1 -- compositor module self-check (Wave β β-01/β-02, LANDED this wave)

Init's compositor-selftest fork+exec+wait4 cycle
(`src/user/init.pdx`) runs before the pre-existing `/bin/child_hello`
cycle. `compositor_selftest.elf` (`src/user/compositor/selftest.pdx`)
calls one real compositor-library function
(`buffer_age_rights_valid`) to prove genuine linkage into the
`src/user/compositor/*` tree, then exits.

```
INIT FORK COMPOSITOR OK
COMP INIT OK
```

Asserted by `tools/boot/compositor-smokes/boot_r113_compositor.sh`
(COMP-QM-01 in the smoke plan -- now runnable, no longer a design-stage
stub). `COMPOSITOR_INIT=1` is accepted by `tools/run-qemu.sh` as a
forward-compatible fw_cfg passthrough (see that flag's own composition
comment for why the fingerprint does not yet depend on it) rather than
a functional gate -- Stage 1 fires on every boot today because it has
no daemon dependency (SSS-01's own design rationale).

A parallel Wave π effort (`tools/build.sh --compositor-tests`,
`tests/kernel/compositor/test_harness/`) builds a second, INDEPENDENT
verification path -- a standalone kernel-linked test-runner ELF
(`build/tests/compositor-runner.elf`) that link-tests a wider slice of
`src/user/compositor/*.pdx` outside any boot at all. That effort and
this one deliberately partition the same source directory (its build
step excludes `compositor/selftest.pdx` by name) so neither's link
unit contends with the other's `_start`. The two are complementary,
not sequential: Wave π verifies the library at build time; Wave β
proves one real call into it survives an actual boot.

### Stage 2 -- svc-compositor daemon spawn wire (Wave β β-04, LANDED this wave; daemon itself NOT landed)

Immediately after tty0 setup (before rootfs_seed_run), init forks and
attempts `execve("/system/services/svc-compositor", ...)`
(`src/user/init/svc_compositor_spawn.pdx`). No wait4 -- a compositor
daemon is long-lived, mirroring the existing
`/bin/elevate_broker_daemon` spawn cycle.

```
SVC-COMP SPAWNED pid=<N>
```

fires unconditionally once `fork` returns in the parent -- it asserts
"init attempted the spawn", exactly the same distinction the existing
`INIT FORK SH OK` / `INIT FORK ELEVATE OK` markers already draw for
their own children. **Today the child's execve fails** (G2: no rootfs
seed populates `/system/services/svc-compositor` because no
svc-compositor source exists anywhere in this monorepo or its
satellite repos), and the child emits:

```
SVC-COMP SPAWN EXEC FAIL
```

then exits. This failure is the honest, expected state of the world
until G1 (lineage decision, R102-satellite-repo vs. R113.M2+
in-monorepo window manager) and G2 (the daemon actually gets written)
close. **Closing this gap is out of scope for Wave β** -- it requires
a real daemon binary, which is a multi-milestone undertaking of its
own (see `design/graphics/r102-user-plan.md` and
`design/graphics/r113-gpu-native-gui.md` for the two competing shapes),
not a Wave β line item.

When G1+G2 close, the fixture path is: extend
`src/kernel/boot/witness/bin_seeds.pdx` with a
`svc_compositor_seed`-shaped function (mirrors this file's own
`bin_compositor_selftest_seed`, rooted at `/system/services/` instead
of `/bin/`) that seeds the real daemon ELF, at which point the child's
execve starts succeeding and the daemon's own startup fingerprint
(`SVC-COMP READY OK host_id=0` per the smoke plan's §2 coverage-gate
revision) becomes reachable. No change to `svc_compositor_spawn.pdx`
itself is anticipated -- the spawn wire is daemon-shape-agnostic.

### Stage 3 -- svc-wm registration (G1, G2, G3, G7 -- NOT landed, NOT scoped to Wave β)

Once svc-compositor is real and live, svc-wm registers against it.
Expected fingerprint (per `r102-user-plan.md`, reconciled -- see smoke
plan §"Fingerprint-contract note", gap G6):

```
SVC-WM REGISTER OK
```

Blocked on everything Stage 2's daemon needs, plus G3 (svc-wm has zero
source AND zero freeze-doc design, unlike svc-compositor which at
least has `r113-m1-substrate.md` for its kernel substrate) and G7 (no
proven ring-3 `sys_cap_mint` path for `KIND_SURFACE`, needed for
whichever client svc-wm mediates first). Filing the design freeze doc
for svc-wm is the concrete next step here, not code.

### Stage 4 -- postui-desktop launch (G1-G4 -- NOT landed, NOT scoped to Wave β)

`src/user/postui-desktop/entry.pdx` exists today as an explicitly
unlinked "lifecycle-skeleton" (excluded from `tools/build-user.sh`'s
link step). Once Stage 3's svc-wm is live, postui-desktop connects,
brings up its status bar and terminal widgets:

```
PU-DT UP status_bar=OK terminal=OK
```

Requires: init spawn wire for postui-desktop (mirrors Stage 2's
pattern once a real target exists), re-inclusion in
`tools/build-user.sh`'s link step (currently excluded on purpose, see
that script's `compositor/*` classification comment), and a live
svc-wm connection to attach to.

### Stage 5 -- E2E steady state (G1-G8 -- NOT landed, NOT scoped to Wave β)

One demo client renders 60 frames through the full stack. Fingerprint
(smoke-plan §2 revised form, since `run-smoke.sh --fingerprint` cannot
express an inequality):

```
COMPOSITOR E2E OK client=1 surface=1 frames=60
```

Needs G8 (a reference demo client speaking whatever wire protocol
Stage 3's lineage decision (G1) settles on) in addition to every prior
stage's gaps.

---

## 4. What Wave β actually closes vs. defers

| Stage | Wave β status | Gaps closed | Gaps remaining |
|---|---|---|---|
| 0 kernel/init boot | pre-existing | -- | -- |
| 1 compositor selftest | **LANDED** (β-01/β-02) | G5 (init-time compositor bring-up gate) | -- |
| 2 svc-compositor spawn wire | **LANDED** (β-04, wire only) | none of G1/G2/G7 -- the WIRE is not the DAEMON | G1, G2, G7 |
| 3 svc-wm registration | not started | -- | G1, G2, G3, G7 |
| 4 postui-desktop launch | not started | -- | G1-G4, G7 |
| 5 E2E steady state | not started | -- | G1-G8 |

Wave β's honest contribution is Stage 1 (fully closed, real fingerprint
on real hardware and QEMU alike modulo the UEFI-only Stage 0.5 LFB
population below) and the Stage 2 spawn wire (mechanism landed, daemon
itself explicitly out of scope). Stages 3-5 require design + source
that does not exist yet and are correctly left as future-wave line
items, not silently declared done.

### Stage 0.5 -- LFB capability population (Wave β β-03, LANDED this wave, UEFI-real-hardware path only)

Orthogonal to the process-spawn chain above: on the real UEFI boot
path only (`_boot_env_pa != 0` -- never true under the `qemu -kernel`
PVH path every stage above actually boots through), `kernel_main.pdx`
now calls `lfb_populate_run` (`src/kernel/boot/lfb_populate.pdx`)
immediately after `kind_framebuffer_init`, projecting the EFI-GOP
descriptor the R23-M2 framebuffer-console bring-up already captured
into `KIND_FRAMEBUFFER` row 0:

```
r101 lfb populate ok
```

This gives a future `KIND_SURFACE`-mediated compositor (Stage 2+'s
eventual daemon) a real, capability-addressable boot framebuffer to
scan out to on T14 G4 hardware, without waiting on any of Stages 2-5.
It has no observable effect on any QEMU smoke in this tree today (PVH
boots never populate `_boot_env_pa`), so it does not appear in the
Stage 1-5 fingerprint sequences above.

---

## 5. Cross-references

- `design/testing/compositor-qemu-smoke-plan.md` -- fixture-shaped gap
  analysis (G1-G8) this doc sequences through.
- `design/graphics/r102-user-plan.md` -- R102 (CPU-side framebuffer,
  satellite-repo) lineage candidate for Stages 2-3.
- `design/graphics/r113-gpu-native-gui.md`,
  `design/graphics/r113-m1-substrate.md` -- R113 (GPU-native,
  in-monorepo) lineage candidate for Stages 2-3; the only one with a
  code-complete kernel substrate (`KIND_SURFACE`) today.
- `src/user/compositor/selftest.pdx`, `src/user/init/
  svc_compositor_spawn.pdx`, `src/kernel/boot/lfb_populate.pdx` --
  Wave β source landed alongside this doc.
- `tests/kernel/compositor/test_harness/` (Wave π) -- the independent
  build-time link-test harness for the wider `src/user/compositor/*`
  library, distinct from Stage 1's boot-time self-check.
