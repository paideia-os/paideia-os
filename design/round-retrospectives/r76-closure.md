# R76 Retrospective (PARTIAL): USB mass-storage + full HID live

**Date:** 2026-08-25
**Milestone:** R76.M1 (single-milestone round)
**Issues:** 5 landed-as-scaffold/PROVISIONAL (#1875, #1876, #1879,
#1881, #1890); 2 deferred (#1887, #1892); this doc closes #1893.
**HEAD at audit:** paideia-os bbb3d35 (fresh worktree, no code changes
made by this audit).
**Release tag:** `r76-closed` recommended as a partial-close, per the
R58/R59/R74/R78 precedent — real remaining work exists (#1887) that is
not hardware-gated.

## Round intent

Per `design/roadmap/post-r60-daily-use-roadmap.md:385-388`: "BOT/UAS
mass-storage + touchpad/TrackPoint/fingerprint — drivers written under
R34 but never live-exercised." Corpus: `src/kernel/core/drivers/usb/`
(17 files) + `src/kernel/core/drivers/i2c_hid/` (5 files), 9,808 lines
total across both.

## Per-issue disposition

### #1875 — BOT mass-storage real-hw exercise — LANDED (PROVISIONAL)
`src/kernel/core/drivers/usb/msc/bot.pdx` (496 lines) implements the
full Bulk-Only Transport protocol (CBW/CSW framing, SCSI command
wrapping, stall/reset recovery). Code-complete; never run against a
real USB drive. QEMU's `usb-storage` device offers a partial generic-
protocol test path, but the issue's fingerprint (enumerate a real
drive, mount FAT/exFAT, read a file) needs real hardware.

### #1876 — UAS mass-storage real-hw exercise — LANDED (PROVISIONAL)
`src/kernel/core/drivers/usb/msc/uas.pdx` (622 lines): UAS command/
status/data pipe framing over bulk-stream IDs. Same disposition as
#1875.

### #1879 — Synaptics touchpad live HID exercise — LANDED (PROVISIONAL)
Mechanism: the generic HID-over-I²C stack in `src/kernel/core/drivers/
i2c_hid/` — `transport.pdx` (432L), `descriptor.pdx` (325L), `isr.pdx`
(262L), `reset_wake.pdx` (257L), `quirks.pdx` (296L) — plus the
Synaptics quirk-table row (vendor `0x06CB` → `DELAYED_RESET`, per
`tests/kernel/drivers/i2c_hid/quirks_synth.pdx:11-12`). There is no
Synaptics-touchpad-*specific* driver file; the touchpad is just an
I²C-HID device the generic stack (landed R32.M1, #1119) already
handles. **Caveat:** the roadmap text
(`post-r60-daily-use-roadmap.md:395-396`) claims "two-finger scroll
observed on `boot_r32_m5_004` on T14 G4" — no such witness file exists
anywhere in `tests/` or `tools/`; this reads as the roadmap's stated
*target* for this issue, not a completed observation. Flagging so it
is not mistaken for prior evidence.

### #1881 — ELAN touchpad live exercise — LANDED (PROVISIONAL)
Same generic I²C-HID mechanism as #1879, with the ELAN quirk-table row
(vendor `0x04F3` → `RESET_BEFORE_DESC | DROP_FIRST_REPORT`). No
ELAN-specific driver file exists or is needed — the quirk table is the
only per-vendor differentiation this stack requires.

### #1887 — TrackPoint HID live exercise — DEFERRED
No TrackPoint-specific code exists anywhere. `grep -rli 'trackpoint\|
track_point'` across `src/kernel/core/drivers/` returns nothing.
`design/roadmap/next-wave-osarch.md:170,179` documents the intended
design (TrackPoint is PS/2-protocol tunneled through the same I²C-HID
transport, demuxed by report ID — "R33.M5 — TrackPoint via I²C-HID
tunnel") but no report-ID demux code or PS/2-in-HID unwrap logic was
ever written. This contradicts the roadmap's blanket claim that all of
R76's drivers were "written under R34" — TrackPoint specifically was
not. Real, unstarted work, not hardware-gated.

### #1890 — Goodix fingerprint reader live exercise — LANDED (PROVISIONAL)
`src/kernel/core/drivers/usb/fp/goodix.pdx` (436 lines) +
`fp_class.pdx` (495 lines): command framing scaffold, explicit in its
own header ("IT DOES NOT ISSUE ANY URB... synaptics_arbitrated()
returns 0 until a later round binds it") — the same seam-gated
discipline used project-wide (identical to the R84 Thunderbolt
scaffolds), not a special-case gap. LANDED (PROVISIONAL).

### #1892 — Boot smoke `boot_r76_usb_devices` composite — DEFERRED
Does not exist. Blocked on real hardware for the BOT/UAS/Synaptics/
ELAN/Goodix legs, and additionally blocked on #1887's genuine code gap
for the TrackPoint leg. DEFERRED.

### #1893 — Round closure — this document
STATUS + retrospective + `r76-closed` tag, partial-close discipline.

## Cross-repo escalations

None. No paideia-as defect found while auditing.

## Observable proof

Driver corpus builds under the existing R34 landing witnesses; no new
observable was produced by this audit (no code changes made). Live
exercise for #1875/#1876/#1879/#1881/#1890 deferred to real T14 G4
hardware; #1887 deferred to a future implementation pass.

## Debt inventory (carried forward)

1. **TrackPoint PS/2-in-HID demux** (#1887) — new file, template from
   the existing generic-HID report-ID split pattern in
   `usb/hid/composite_hid.pdx`; not hardware-gated, can land without a
   real T14 G4 session.
2. **`boot_r76_usb_devices` composite smoke** (#1892) — write once (1)
   lands and real hardware is available for the rest.
3. **Roadmap accuracy** — the "boot_r32_m5_004 two-finger scroll
   observed" claim in `post-r60-daily-use-roadmap.md:396` should be
   corrected to describe intent, not an observed result, to avoid a
   future audit treating it as evidence.

**Next round:** R77 (Iris Xe display/modeset) or R81 (HDA audio) per
the post-R60 roadmap sequencing; TrackPoint work (#1887) can be picked
up independently of hardware availability.
