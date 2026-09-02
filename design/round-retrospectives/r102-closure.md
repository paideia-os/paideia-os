# R102 Closure Retrospective — Monorepo integration wave (userland graphical-display stack)

**Status:** Closed with deferrals
**Date:** 2026-09-02
**Design authority:** `design/graphics/r102-user-plan.md` §4.10
**Companion (kernel):** `design/round-retrospectives/r101-closure.md`
**Wave scope:** paideia-os monorepo `R102` milestone — 10 MON- integration issues (#2208..#2217).

---

## 1. What the R102 MON- wave was supposed to land

Per `design/graphics/r102-user-plan.md` §4.10, R102's monorepo-side
integration wave stitches nine freshly-created satellite repos
(`libpdx-font`, `libpdx-gfx`, `libpdx-event`, `svc-compositor`,
`svc-wm`, `pdxterm`, `pdxclock`, `pdxwatch`, `pdxpaint`) into the
paideia-os boot image so that a boot smoke can observe a graphical
compositor drawing its first pixel, spawning a window, and routing
input events end-to-end. Ten issues:

| Issue | Scope |
|---|---|
| MON-001 | 9 submodule adds under `tools/user/` |
| MON-002 | `tools/build.sh` r102-tools stage (SAT_LIBS + SAT_APPS pipeline) |
| MON-003 | `tools/userbin_embed.S` .incbin + `bin_seeds.pdx` seed rows for six apps |
| MON-004 | `boot_r102_first_pixel` smoke wiring |
| MON-005 | `boot_r102_window_present` smoke wiring |
| MON-006 | `boot_r102_input_route` smoke wiring |
| MON-007 | `boot_r102_pdxterm_hello` smoke wiring |
| MON-008 | `boot_r102_screenshot` smoke wiring |
| MON-009 | `init.pdx` compositor + WM spawn cascade |
| MON-010 | This retrospective |

Fingerprint targets (per the plan):

- `r102 build stage ok` (MON-002)
- `r102 bin seeds ok` (MON-003)
- `first pixel ok` / `window present ok` / `input route ok` / `pdxterm hello ok` / `screenshot ok` (MON-004..008)
- `r102 init sequence ok` (MON-009)

---

## 2. What actually landed — skeletons, not real bodies

Every one of the nine R102 satellite repos exists on
`github.com/paideia-os` as a **LICENSE + README.md-only scaffold** as
of this closure. No `src/`, no `caps.decl`, no `find-paideia-as.sh`,
no `tools/build.sh` in any of the nine. The R102 M1-scaffold issues
inside each satellite repo are open but unfilled — the R102 M1..M5
wave has not started per-repo yet.

Verified 2026-09-02 via `gh api repos/paideia-os/<name>/contents/`:

    libpdx-font       -> LICENSE, README.md
    libpdx-gfx        -> LICENSE, README.md
    libpdx-event      -> LICENSE, README.md
    svc-compositor    -> LICENSE, README.md
    svc-wm            -> LICENSE, README.md
    pdxterm           -> LICENSE, README.md
    pdxclock          -> LICENSE, README.md
    pdxwatch          -> LICENSE, README.md
    pdxpaint          -> LICENSE, README.md

Landing an OK-fingerprint version of any of MON-002..MON-009 today
would require every satellite to be buildable. It is not. The R102
MON- wave therefore lands as **skeletons** — every issue emits a
lowercase skip fingerprint naming why it degraded, structured so the
`ok` path can slot in with no reshuffling of the surrounding wiring
when the M1..M5 waves fill in real code.

### 2.1 Disposition table

| Issue | Landed | Disposition |
|---|---|---|
| **MON-001** | **DEFERRED** — no submodules added | Empty repos are not `git submodule add`-safe here (no `tools/build.sh` to invoke, no `find-paideia-as.sh` to pin). `.gitmodules` unchanged. Intended structure documented in this retrospective (§4). Slot into the tree via a follow-up per-satellite issue at the point that satellite lands its M1-001 scaffold. |
| **MON-002** | **SKELETON** in `tools/build.sh` | `SAT_LIBS_R102` / `SAT_APPS_R102` arrays declared with the nine names; walks each satellite's `tools/build.sh` if present, prints one lowercase skip line otherwise. Flips to full parallel invocation shape (mirroring `r64v2-tools`) when at least one satellite has real code. **Fingerprint (skip):** `r102 build stage skip reason=no-satellite-code`. |
| **MON-003** | **SKELETON** in `src/kernel/boot/witness/r102_bin_seeds.pdx` (new) + reservation block in `tools/userbin_embed.S` | Six reserved userbin symbol names + six `/bin/<name>` path constants documented as commented-out `.incbin` and `[u8; N]` templates. Real seed stanzas will move into `bin_seeds.pdx` (structurally mirroring `bs_ls_seed`) once the six ELFs are built. **Fingerprint (skip):** `boot r102 bin seeds skip reason=no-elf`. |
| **MON-004** | **SKELETON** in `src/kernel/boot/witness/r102_first_pixel.pdx` (new) + `tools/run-smoke.sh` case arm + `tests/expected-r102-first-pixel.golden` | Skip fingerprint pinned by golden; witness fires on every boot. **Fingerprint (skip):** `boot r102 first pixel skip reason=no-userland`. |
| **MON-005** | **SKELETON** — same shape as MON-004 | **Fingerprint (skip):** `boot r102 window present skip reason=no-userland`. |
| **MON-006** | **SKELETON** — same shape as MON-004 | Two-precondition deferral (svc-compositor.M4-003 + svc-wm.M4 + pdxpaint.M4-001 AND R101 HID-injection fixture per §7.2.5). **Fingerprint (skip):** `boot r102 input route skip reason=no-userland`. |
| **MON-007** | **SKELETON** — same shape as MON-004 | **Fingerprint (skip):** `boot r102 pdxterm hello skip reason=no-userland`. |
| **MON-008** | **SKELETON** — same shape as MON-004 | **Fingerprint (skip):** `boot r102 screenshot skip reason=no-userland`. |
| **MON-009** | **SKELETON** in `src/kernel/boot/witness/r102_init_spawn.pdx` (new) | Kernel-side skip witness in the boot cascade rather than a real spawn in `src/user/init.pdx` — the underlying `/bin/svc-compositor` and `/bin/svc-wm` paths do not resolve (blocked on MON-003 which is blocked on the satellite scaffolds). Migrates into `init.pdx` when the paths seed. **Fingerprint (skip):** `boot r102 init spawn skip reason=no-elf`. |
| **MON-010** | **LANDED** — this document | Honest disposition + follow-up roadmap. |

### 2.2 Fingerprints emitted this wave

All seven fingerprints are ONE lowercase line, printed under
`SUBSYS_BOOT` at `LEVEL_INFO`:

    boot r102 bin seeds skip reason=no-elf
    boot r102 init spawn skip reason=no-elf
    boot r102 first pixel skip reason=no-userland
    boot r102 window present skip reason=no-userland
    boot r102 input route skip reason=no-userland
    boot r102 pdxterm hello skip reason=no-userland
    boot r102 screenshot skip reason=no-userland

Plus one build-log-only stage line:

    [r102-tools] r102 build stage skip reason=no-satellite-code

---

## 3. Why skeletons instead of just deferring the whole wave

Two considerations pushed toward skeleton-land-and-pin rather than
close-as-blocked:

1. **Positive skip lines vs missing markers.** Every previous
   round-close discipline in this tree (r92-closed, r101-closed) treats
   the *absence* of a fingerprint line as ambiguous — did the witness
   run and skip, or was the witness never wired up? Landing a witness
   that always fires and always emits ONE skip line converts that
   ambiguity into an explicit boot-transcript record. `grep 'r102' log`
   returns a line count the reader can reason about.

2. **Golden-pinned skip lines catch premature re-enable.** The five
   `boot_r102_*` smoke modes now exist as first-class run-smoke.sh
   dispatch arms with goldens that pin the skip line verbatim. The
   moment somebody flips a witness body from `skip` to `ok` without
   updating the golden, that smoke mode fails. This is exactly the
   discipline `boot_r105_flip_client_virtio` uses today (it pins a
   skip line waiting for R103's virtio-gpu backend to arrive — see
   `tests/expected-r105-flip-client-virtio-skip.golden`).

The alternative — closing the wave as `blocked upstream` with no
monorepo-side changes — would have deferred every wiring decision
(what does the smoke mode look like, what argument names does the
witness carry, what does the golden pin) to a future round-under-time-
pressure and cost one more full context load per issue when M4 wiring
eventually lands. The skeleton wave pays that context tax once now.

---

## 4. Intended satellite layout (deferred MON-001 documentation)

When the R102-M1 wave lands per-satellite scaffolds and the nine
repos become `git submodule add`-safe, `.gitmodules` gains these
entries under the existing `tools/user/` root:

    [submodule "tools/user/libpdx-font"]
      path = tools/user/libpdx-font
      url  = https://github.com/paideia-os/libpdx-font.git
    [submodule "tools/user/libpdx-gfx"]
      path = tools/user/libpdx-gfx
      url  = https://github.com/paideia-os/libpdx-gfx.git
    [submodule "tools/user/libpdx-event"]
      path = tools/user/libpdx-event
      url  = https://github.com/paideia-os/libpdx-event.git
    [submodule "tools/user/svc-compositor"]
      path = tools/user/svc-compositor
      url  = https://github.com/paideia-os/svc-compositor.git
    [submodule "tools/user/svc-wm"]
      path = tools/user/svc-wm
      url  = https://github.com/paideia-os/svc-wm.git
    [submodule "tools/user/pdxterm"]
      path = tools/user/pdxterm
      url  = https://github.com/paideia-os/pdxterm.git
    [submodule "tools/user/pdxclock"]
      path = tools/user/pdxclock
      url  = https://github.com/paideia-os/pdxclock.git
    [submodule "tools/user/pdxwatch"]
      path = tools/user/pdxwatch
      url  = https://github.com/paideia-os/pdxwatch.git
    [submodule "tools/user/pdxpaint"]
      path = tools/user/pdxpaint
      url  = https://github.com/paideia-os/pdxpaint.git

Each pinned at that satellite's `r102-closed` tag once the satellite's
own M5-001 landing cuts it. The existing three-lib + three-tool R64v2
submodule set (`libpdx-audit`, `libpdx-elevate`, `libpdx-volume`,
`mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs`) is the shape template —
`tools/build.sh`'s `SAT_LIBS_R102` + `SAT_APPS_R102` arrays already
name the nine slots.

---

## 5. Files changed this wave

New files:

- `src/kernel/boot/witness/r102_bin_seeds.pdx` (MON-003 skeleton witness)
- `src/kernel/boot/witness/r102_init_spawn.pdx` (MON-009 skeleton witness)
- `src/kernel/boot/witness/r102_first_pixel.pdx` (MON-004 skeleton witness)
- `src/kernel/boot/witness/r102_window_present.pdx` (MON-005 skeleton witness)
- `src/kernel/boot/witness/r102_input_route.pdx` (MON-006 skeleton witness)
- `src/kernel/boot/witness/r102_pdxterm_hello.pdx` (MON-007 skeleton witness)
- `src/kernel/boot/witness/r102_screenshot.pdx` (MON-008 skeleton witness)
- `tests/expected-r102-first-pixel.golden`
- `tests/expected-r102-window-present.golden`
- `tests/expected-r102-input-route.golden`
- `tests/expected-r102-pdxterm-hello.golden`
- `tests/expected-r102-screenshot.golden`
- `design/round-retrospectives/r102-closure.md` (this file)

Modified files:

- `src/kernel/boot/kernel_main.pdx` — seven `call witness_r102_*`
  lines added after `witness_r101_stdvga_checkerboard` inside
  `boot_continue_after_ring3` (all seven witnesses fire on every
  boot; skip fingerprints observable in the transcript).
- `tools/build.sh` — R102.MON-002 skeleton `r102-tools` stage after
  the existing `r64v2-tools` block. `SAT_LIBS_R102` /
  `SAT_APPS_R102` arrays defined; per-satellite `tools/build.sh`
  invocation gated on file existence; skip line emitted when no
  satellite has code.
- `tools/userbin_embed.S` — appended a reservation block naming the
  six future `_<app>_bin_start` / `_end` symbol pairs, matching
  `/bin/<name>` path constants, and the exact `.incbin` incantation to
  uncomment when the ELFs land. Bytes emitted to `userbin_embed.o`:
  unchanged (all comments).
- `tools/run-smoke.sh` — five new case arms (`boot_r102_first_pixel`,
  `boot_r102_window_present`, `boot_r102_input_route`,
  `boot_r102_pdxterm_hello`, `boot_r102_screenshot`) each pinning
  its matching golden.

**Unchanged**: `.gitmodules` (MON-001 deferred), `src/user/init.pdx`
(MON-009 kernel-side today, migrates when paths seed),
`src/kernel/boot/witness/bin_seeds.pdx` (MON-003 kernel-side today,
migrates when ELFs embed).

---

## 6. Deferred work — follow-up per-satellite

The R102 round is not closed *outside* the monorepo. Nine satellite
repos each need their own M1..M5 waves per `design/graphics/r102-user-
plan.md` §3 and §4.1..§4.9. When those waves land, each satellite
files a hoist issue against this repo of the shape:

- **Precondition:** satellite `<name>` at `r102-closed` tag; ELF built
  and reproducible via that repo's `tools/build.sh`.
- **This-repo landing:**
  1. `git submodule add https://github.com/paideia-os/<name>.git tools/user/<name>` (retires part of MON-001).
  2. Uncomment the corresponding `.incbin` block in `tools/userbin_embed.S` (retires part of MON-003).
  3. Add the matching `bs_<name>_seed` stanza to `src/kernel/boot/witness/bin_seeds.pdx` mirroring `bs_ls_seed` (retires part of MON-003).
  4. For the six APPS specifically: add the matching `bin_<name>_path` constant to `src/user/init.pdx` (retires part of MON-009 for compositor and WM specifically).
- **This-repo re-close:** flip the corresponding `witness_r102_*`
  body from `skip` to the real cascade, update the corresponding
  `tests/expected-r102-*.golden` from the skip line to the `ok` line.

The wave that flips MON-004..MON-008 witnesses to their `ok` forms is
also the wave that retires this retrospective's §2.1 "SKELETON" rows
to "LANDED — REAL". At that point `r102-closure.md` gets a §7
appendix updating the disposition table.

---

## 7. Open questions for the R102-M1 follow-up wave

Two structural decisions the M1 wave will hit that this MON- skeleton
does not pre-empt:

1. **Whether `svc-compositor` and `svc-wm` boot as user-space
   services or kernel-space bubbles at first.** The R102 plan §4.4/§4.5
   commits to user-space processes, but the R30-family precedents
   (acpi_supervisor, audio_supervisor, elevate_broker_daemon) show
   svc-* bubbles landing user-space via init's fork+execve chain.
   MON-009's future migration into `init.pdx` assumes user-space; the
   witness at `r102_init_spawn.pdx` is agnostic and either target
   works.

2. **Whether the six graphical smokes fold into a `boot_r102_smoke`
   composite meta-mode.** `boot_net_smoke` (R98.M1-001) is the
   precedent: one composite that runs `boot_r91_nic +
   boot_r93_udp_dns + boot_r94_tcp_offbox`, rolls up one green/red.
   R102 should very likely gain `boot_r102_smoke` running the five
   `boot_r102_*` modes as one lane, with an env gate
   (`PAIDEIA_GUI_SMOKE=1`?) mirroring `PAIDEIA_NET_SMOKE`. Deferred
   to whichever MON-004..008 hoist issue is landing last.

Neither question blocks this wave's closure.
