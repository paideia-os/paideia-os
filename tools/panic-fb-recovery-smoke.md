# Panic FB recovery — operator quick-reference

**Owner issue:** paideia-os #1005 (R28.M3-001).
**Full recipe:** `design/testing/panic-fb-photograph-recovery.md`.
**Status:** Operator quick-reference; live run gated on first-boot on
the T14 G4 with the R28.M3+ panic-test witness.

---

## 0. Purpose

Terse copy-paste sheet for an operator who already knows the R28
image lifecycle and just needs the panic-fb-photograph verification
steps in one place. For the reasoning, acceptance floor, promotion
rules, and failure-mode table, see the full recipe.

---

## 1. Prereqs (one-line each)

- T14 G4 or QEMU-OVMF host.
- `build/mvp/paideia-mvp.img` from `bash tools/build-image.sh`.
- Any modern phone camera (physical run only).
- Optional serial capture per
  `design/kernel/serial-console-fallback.md` for cross-check.

---

## 2. QEMU-OVMF (CI-like proxy)

```
bash tools/build.sh
bash tools/build-uefi-stub.sh
bash tools/build-image.sh
bash tools/run-uefi-ovmf.sh --display gtk
```

At shell prompt, trigger a panic (deferred witness — until it lands,
manual proxy is a `#GP`-inducing user binary).

Screenshot QEMU GTK window. Verify:
- Bold-red `*** PANIC ***` banner.
- Ring dump BEGIN/END markers present.
- Last 20 klog entries transcribable end-to-end.

---

## 3. T14 G4 (physical, definitive)

BIOS setup: Secure Boot off, Intel VMD Controller off, CSM off,
UEFI Only.

```
dd if=build/mvp/paideia-mvp.img of=/dev/sdX bs=4M conv=fsync
```

Boot from USB (F12 boot menu). Wait for `FB CONSOLE INIT OK` +
`SHELL PROMPT` fingerprints on the eDP panel.

At shell prompt, trigger panic. Photograph the frozen panel:

- 15-30 cm distance, perpendicular, manual focus, minimize glare.
- 2-3 shots for focus/glare variance.

Transcribe from photo (no serial cross-check). Every character in
the last 20 klog entries must be identifiable.

---

## 4. On pass

Add photo file:

```
mkdir -p design/hardware/photos
cp <photo>.jpg design/hardware/photos/t14-g4-first-panic-YYYY-MM-DD.jpg
```

Promote `design/hardware/quirks.md §2.5` UART row:
- `PROVISIONAL` -> `WORKED-AROUND`.
- Add T14 G4 serial number + commit reference + photo filename in
  the "Source" column.

Land the promotion in a `design/round-retrospectives/rNN-t14-g4-
first-panel-panic.md` execution log.

---

## 5. On fail

See `design/testing/panic-fb-photograph-recovery.md §5` failure-mode
table. Common paths:

- Blank panel -> boot path was PVH not UEFI GOP.
- Banner but no dump -> `klog_ring_dump_panic` fb-mirror hook
  regression; audit `src/kernel/core/klog/panic.pdx` + `ring.pdx`.
- Garbled glyphs -> WC LFB flush missing before `cli; hlt`; add
  `mfence`.
- Grey banner -> ANSI SGR parser regression OR panel colour profile;
  accept if bold + distinct even without hue.

---

*Landed 2026-08-11 at R28.M3 close (#1005).*
