# R77 Retrospective (PARTIAL): Iris Xe display/modeset

**Date:** 2026-08-25
**Milestone:** R77.M1 (single-milestone round)
**Issues:** 0 landed / 3 partial (#1895, #1898, #1902) / 4 deferred
(#1897, #1900, #1901, #1903); this doc closes #1904.
**HEAD at audit:** paideia-os bbb3d35 (fresh worktree, no code changes
made by this audit).
**Release tag:** none cut — real, non-hardware-gated implementation
gaps remain (missing pipe/transcoder/link-training files); recommend
leaving the milestone open for an implementation pass before any
closure tag.

## A correction made during this audit

An earlier draft of this file (briefly present on disk during this
audit pass) asserted "no CDCLK-specific init/lock-verify code was
found under any name" and attributed #1895's only adjacent code to
`dpclk_config.pdx`'s DP-link PLL scaffold. **That is incorrect and is
fixed in this version.** `src/kernel/core/drivers/dpy/pwr_wells.pdx`
(R36.M1-002, #1236) is explicitly and unambiguously a CDCLK driver:
its own header reads "Intel Iris Xe display engine power-wells +
**CDCLK setpoint driver** scaffold... CDCLK setpoints per gen," it
declares `PWR_REG_CDCLK_CTL : u64 = 0x46000` and a `_pwr_cdclk_khz`
state cell, and implements three real functions —
`pwr_cdclk_setpoint_valid(gen, khz)` (the per-generation legal-
setpoint table: Xe1/Xe2/Xe3 each have five valid kHz values, an
out-of-set value is refused rather than clamped), `pwr_cdclk_set(gen,
khz)` (the sole writer of `_pwr_cdclk_khz`, refuses if PG1 is not up),
and `pwr_cdclk_get()`. `dpclk_config.pdx` (R36.M1-003, #1237) is a
genuinely separate clock domain — the per-DDI DisplayPort *link-rate*
PLL (RBR/HBR/HBR2/HBR3), not the core display clock — so the earlier
draft's distinction between the two PLLs was sound, but its conclusion
that CDCLK itself has no code was wrong.

## Round intent

Per `design/roadmap/post-r60-daily-use-roadmap.md:404-407`: "CDCLK/
pipes/planes/DDI atomic modeset. **Only cap/IPC stubs exist today.**
Prerequisite for any compositor." The roadmap's own framing already
signals this round is less mature than R76/R81/R83/R84 — confirmed by
the audit. Corpus: `src/kernel/core/drivers/dpy/`, 14 files, 7,172
lines.

## Per-issue disposition

### #1895 — CDCLK programming — PARTIAL
`pwr_wells.pdx` `pwr_cdclk_setpoint_valid`/`pwr_cdclk_set`/
`pwr_cdclk_get` (~L409-564, R36.M1-002 #1236) implement the real
per-generation setpoint table and the sole state-writer, gated on PG1
being up. Its own header states: "IT DOES NOT TOUCH REAL MMIO.
PG_STATUS and CDCLK_CTL are read/written through a seam whose default
backing is caller-supplied register snapshots... `pwr_wells_
arbitrated()` returns 0 until a later round binds this against a live
MMIO window." PARTIAL: the setpoint logic this issue asks for is
real and landed; the real `CDCLK_CTL` (0x46000) MMIO write is not.

### #1897 — Pipe programming (PIPE_MISC, PIPE_CONF, plane attach) — DEFERRED
No file implements pipe-register programming. `grep -ln 'PIPE_MISC\|
PIPE_CONF'` across `src/kernel/core/drivers/dpy/` returns nothing.
Genuinely unstarted.

### #1898 — Plane programming (primary bind BO, format, scaler) — PARTIAL
`plane_primary.pdx` (484L), `plane_overlay.pdx` (591L),
`plane_cursor.pdx` (510L) exist and declare register-offset scaffolds
under the same "does not touch real MMIO, seam-only" discipline as
#1895. No pipe (#1897) or transcoder (#1900) counterpart exists to
actually drive these planes end-to-end, so even the scaffold cannot
be exercised in isolation. PARTIAL.

### #1900 — Transcoder programming (TRANS_HTOTAL/VTOTAL/HSYNC/VSYNC/
HBLANK/VBLANK from EDID DTD) — DEFERRED
No file implements transcoder timing registers. `grep -ln
'TRANS_HTOTAL\|TRANS_VTOTAL'` across the whole tree returns nothing.
`edid.pdx` (737L) parses the EDID DTD the transcoder would consume,
but nothing consumes it into transcoder timing registers. Genuinely
unstarted.

### #1901 — DDI/eDP link training (TP1/TP2/TP3, channel equalization) — DEFERRED
No file implements the DP link-training state machine.
`topology.pdx` (578L) maps DDI-to-wire-type and provides a DP-AUX
transaction seam (`dtopo_aux_request`) but explicitly defers actual
training: no TP1/TP2/TP3 sequencing or channel-equalization logic
exists anywhere. `dpclk_config.pdx`'s DP-link-rate PLL select/lock
(see the correction above) is a real prerequisite building block for
this issue, but link training itself — the TP1/TP2/TP3 handshake — is
unstarted. Genuinely unstarted; this and #1897/#1900 are the three
files this round's roadmap intent describes but never produced.

### #1902 — Modeset composition over GOP handoff LFB — PARTIAL
`scanout.pdx` (839L) implements a grant/revoke lease policy for
direct-scanout ("(1) grant a direct-scanout lease... (2) present a
buffer... (3) revoke the lease") and `atomic_commit.pdx` (471L)
implements write-then-arm double-buffering discipline for register
writes — both real logic, both explicitly "does not touch real MMIO."
Note `scanout.pdx` traces to **G2** (#1445-#1456, the direct-scanout
GPU-native-GUI track), and `atomic_commit.pdx` to **R36**.M3-003
(#1246) — both pre-existing, neither authored for R77. Neither
performs an actual GOP-framebuffer-to-native-scanout transition, and
neither has a pipe/transcoder backing to commit against. PARTIAL.

### #1903 — Boot smoke boot_r77_modeset_native — DEFERRED
Does not exist. Blocked on #1897/#1900/#1901's missing implementations
independent of hardware, and additionally real-T14-G4-hardware-only
once those land — QEMU/OVMF's stdvga/virtio-gpu path has no Intel Xe
MMIO model at all. DEFERRED on both grounds.

### #1904 — Round closure — this document
STATUS + retrospective, this round's own audit.

## Cross-repo escalations

None found.

## Observable proof

None — no code changes made by this audit, and the round has no
end-to-end observable to exercise (pipe/transcoder/link-training are
absent, so even a synthetic register-snapshot test could not produce a
displayed frame).

## Debt inventory (carried forward)

1. **Real `CDCLK_CTL` (0x46000) MMIO bind** — the setpoint table and
   state machine (#1895) already exist in `pwr_wells.pdx`; only the
   live register write is missing.
2. **Pipe programming** (#1897) — `PIPE_MISC`/`PIPE_CONF` registers,
   plane-attach wiring. New file, not hardware-gated.
3. **Transcoder programming** (#1900) — `TRANS_HTOTAL`/`VTOTAL`/`HSYNC`/
   `VSYNC`/`HBLANK`/`VBLANK`, driven from `edid.pdx`'s already-parsed
   DTD. New file, not hardware-gated.
4. **DDI/eDP link training** (#1901) — TP1/TP2/TP3 sequencing and
   channel-equalization, building on `topology.pdx`'s existing DP-AUX
   seam and `dpclk_config.pdx`'s existing link-rate PLL select. New
   file, not hardware-gated.
5. **Live MMIO seam binding** — every scaffold in `dpy/` (`pwr_wells`,
   `dpclk_config`, `plane_*`, `atomic_commit`, `scanout`) is gated
   behind an `*_arbitrated()` function returning 0 until bound to a
   real MMIO window; that binding plus (1)-(4) above are the
   prerequisites for #1902/#1903 to mean anything.

**Next round:** this round needs a genuine implementation pass (items
1-4 above are not hardware-gated and can land without a T14 G4
session) before a meaningful hardware-exercise retro is possible.
Recommend scoping a follow-up R77-redux issue set from this debt
inventory directly, or resuming the roadmap at R81/R83/R84 (which are
purely hardware-blocked) in the meantime.
