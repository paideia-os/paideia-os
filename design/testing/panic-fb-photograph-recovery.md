# Panic framebuffer log ring — photograph-recoverability verification

**Owner issue:** paideia-os #1005 (R28.M3-001 — Framebuffer log-ring
in panic path — verify photograph-recoverability).
**Substrate landed at:** R23.M3-002 (#884) — `k_panic_fb_banner` +
`klog_ring_dump_panic` fb-mirror hook. This document is
verification-only; no kernel change lands under #1005.
**Status:** Landable pre-first-light — verification recipe. Promotion
of the T14 G4 §2.5 quirks row from `PROVISIONAL` to `WORKED-AROUND`
happens when a physical operator completes §4 on the T14 G4.

---

## 0. Scope

The T14 G4 chassis has no debug UART. Per `design/hardware/quirks.md
§2.5`, the fallback recording surface is the eDP framebuffer: a
photograph of the frozen screen after a kernel panic must be legible
enough to transcribe the last few log lines without any attached
serial capture. This document codifies the acceptance criteria and
the operator recipe that certifies the R23.M3 substrate meets them.

**Non-goals.** Panic-time state recovery via memory dump (deferred to
R33+ crashdump substrate). ANSI colour reproduction fidelity (the
bold-red `*** PANIC ***` banner is expected to render, but the test
does not measure chromatic accuracy — only legibility of the ring
bytes). Live serial-cross-check on T14 G4 (no chassis UART; QEMU-OVMF
covers this per the regression matrix).

---

## 1. Substrate under test

The R23.M3-002 (#884) wire, unchanged since R23 close:

1. **`klog_panic` step 3.7** — after NMI freeze of secondary cores
   and the `klog_walk_rbp` stack-frame emission (#716), the panic
   handler tests `[_fb_console_active] != 0` and, when true, calls
   `fb_console_puts(&k_panic_fb_banner, 26)` — the 26-byte bold-red
   `\x1b[1;31m*** PANIC ***\x1b[0m\r\n` sequence.
2. **`klog_ring_dump_panic` step 4** — the ring-drain body carries a
   per-byte hook that mirrors each byte written to COM1 through
   `fb_console_putchar`, so the eDP frame and the UART wire see the
   same bytes in the same order.
3. **`klog_panic` step 6** — post-drain, `cli; hlt` spin freezes the
   BSP with the display state intact.

The intended visual result on the eDP panel after a synthetic panic:

- Upper portion of the screen: pre-panic klog history (boot
  fingerprints + any pre-panic activity), the topmost rows scrolled
  off if the boot log is long.
- One horizontal-rule-like `*** PANIC ***` banner in bold-red.
- The ring dump BEGIN marker (`>>> KLOG RING DUMP BEGIN <<<` or
  equivalent), then oldest-to-newest ring bytes, then the END marker.
- Bottom portion: possibly empty rows if the ring did not fill the
  remaining screen.
- No further activity — the cursor does not blink; the frame does not
  scroll.

---

## 2. Legibility budget

The photograph-recoverability property is quantitative, not
subjective. The T14 G4 native eDP panel is 1920x1080 with a 3:2 to
16:9 aspect; the R23 fb-console uses the 8x16 embedded VGA font
(`_fb_font`, R23.M1 #877).

| Metric | Value | Derivation |
|--------|-------|------------|
| Panel resolution | 1920 x 1080 px | T14 G4 Intel Iris Xe eDP native. |
| Glyph size | 8 x 16 px | R23.M1 embedded font. |
| Console grid | 240 cols x 67 rows | 1920 / 8 = 240 cols; 1080 / 16 = 67 rows. |
| Chars per line (guaranteed) | 100+ | Wide enough for a full klog line: subsystem tag (~8 B) + TSC (~16 B) + key (~24 B) + value (~30 B) with headroom. |
| Rows for post-banner ring dump | ~30 minimum | ~35 rows above banner reserved for pre-panic history; ~30 below is the acceptance floor. |
| Ring bytes visible on-screen | ~3000 B minimum | 30 rows x ~100 B/row. |
| Last 20 klog entries visible | Yes (acceptance) | Assuming average 60-80 B/entry (subsystem + key + value + TSC), 20 entries = 1200-1600 B, fits inside the 3000-B budget with headroom for line-wrapping. |

**Acceptance floor:** a phone-camera photograph taken from
15-30 cm away, with the panel at typical office brightness, must
allow a human reader to transcribe the last 20 klog entries — every
subsystem tag, key, and value — without ambiguity. Wrap-around from
long values is allowed; unreadable glyphs (blur, glare, sub-pixel
smear) are not.

---

## 3. Verification procedure — QEMU-OVMF (CI-like proxy)

Real HW verification (§4) is the primary acceptance. QEMU-OVMF with a
GOP-backed display provides a CI-like proxy that exercises the same
code path (UEFI GOP handoff → `_boot_env` populated → `fb_console_init`
→ `k_panic_fb_banner` emit).

### 3.1 Build

```
bash tools/build.sh                     # 15 gates
bash tools/build-uefi-stub.sh           # uefi_stub.efi
bash tools/build-image.sh               # build/mvp/paideia-mvp.img
```

### 3.2 Boot under QEMU-OVMF with an fb display

```
bash tools/run-uefi-ovmf.sh --display gtk
```

The window should light up with the boot log rendered via
`fb_console_init` + `fb_console_puts`.

### 3.3 Inject a synthetic panic

Wire a `k_panic_fb_photo_witness` (R28.M3+ test kind, not required
for #1005 close) that calls `klog_panic(SUBSYS_TEST, tag)` after the
shell reaches its prompt. Until the witness lands, the manual proxy is
to trigger a #GP by writing to a canonical-non-canonical VA from the
shell (out of scope for #1005; sufficient for #1005 is the fingerprint
that `k_panic_fb_banner` + `klog_ring_dump_panic` symbols are linked
and the R23-M3 close-time smoke asserted their invocation ordering).

### 3.4 Capture the QEMU window

Screenshot the QEMU GTK window (host-side, e.g. `gnome-screenshot -w`
or the QEMU `screendump` monitor command). Verify:

- Bold-red `*** PANIC ***` banner is present and visually distinct
  from the surrounding white-on-black rows.
- Ring dump BEGIN marker is above the ring bytes; END marker below.
- Last 20 klog entries before the panic are readable end-to-end.
- Cursor state is frozen — no further activity in a second screenshot
  taken 5 s later.

### 3.5 Acceptance under QEMU-OVMF

Pass if §3.4 succeeds. The QEMU screenshot is a structural check —
it proves the emit path fires and the bytes land — but does not
prove eDP-panel-photograph legibility. That is §4's job.

---

## 4. Verification procedure — T14 G4 first-panel-panic (physical)

The definitive acceptance. Cross-references
`design/round-retrospectives/r23-closure.md` §
"Real-Hardware Verification Procedure" step 5.

### 4.1 Preflight

- T14 G4 physical unit (Raptor Lake, MVP target).
- USB stick with `build/mvp/paideia-mvp.img` (`bash
  tools/build-image.sh`).
- Any modern phone camera (2020+ mid-range suffices; the acceptance
  is 100+ chars/line legibility, well within a 12 MP camera's
  resolving power at 20 cm).
- BIOS setup per `design/hardware/quirks.md §2.4` VMD row: Secure Boot
  off, Intel VMD Controller off, CSM off, UEFI Only.
- Optional: USB-C dock DB-9 for serial cross-check per
  `design/kernel/serial-console-fallback.md`. Not required — the
  point of this test is to prove the panic is recoverable WITHOUT
  serial.

### 4.2 Boot

Boot the T14 G4 from the USB stick. Wait for the R23 fingerprint
(`FB CONSOLE INIT OK`) to appear on the eDP panel, followed by the
R28 MVP fingerprints (`SHELL PROMPT`, etc.) per
`design/hardware/t14-g4-first-boot.md` §7.

### 4.3 Inject a panic

From the shell prompt, trigger a #GP via the R28.M3+ panic-test
builtin (deferred to #1005 M3-close+ witness; alternatively write a
one-shot user binary that dereferences a non-canonical pointer and
`exec`s it from `/bin/sh`).

Expected: the eDP panel freezes with the panic layout per §1.

### 4.4 Photograph

Take a phone photograph of the frozen eDP panel. Guidelines:

- Distance: 15-30 cm from the panel; the goal is 100+ chars fitting
  legibly across the frame.
- Angle: perpendicular to the panel to minimize keystoning.
- Lighting: normal office lighting; avoid direct-light glare on the
  panel.
- Focus: manual-focus the phone camera on the glyph grid; auto-focus
  sometimes hunts across the uniform text field.
- Frame: capture the full screen; the banner should be near the
  vertical middle with pre-panic log above and ring dump below.

Take 2-3 photos to cover focus/glare variance.

### 4.5 Transcribe

Without any other capture source (no serial log to cross-check), read
the photograph and transcribe:

1. The `*** PANIC ***` banner (present, colour visible as reddish
   even without perfect colour reproduction).
2. The ring dump BEGIN marker.
3. The last 20 klog entries — each entry's subsystem tag, key, and
   value.
4. The ring dump END marker.

**Acceptance:** transcription must be unambiguous — every character
identifiable, no `[unreadable]` gaps in the last-20 entries. Line-
wrap from long values is allowed; the row above/below the wrap must
match on the next-glyph continuation.

### 4.6 Promote

On successful transcription:

- Promote `design/hardware/quirks.md §2.5` UART row from
  `PROVISIONAL` to `WORKED-AROUND`, citing:
  - The T14 G4 physical unit serial number.
  - The commit that lands this recipe's execution log (a
    `design/round-retrospectives/rNN-t14-g4-first-panel-panic.md` in
    the round that first executed the procedure — likely R28.M3
    close-plus-first-light or R29).
  - The photograph filename in
    `design/hardware/photos/t14-g4-first-panic-YYYY-MM-DD.jpg` (add
    a `design/hardware/photos/README.md` if absent — provenance +
    licensing note).

---

## 5. Failure modes and remediation

| Failure | Diagnosis | Remediation |
|---------|-----------|-------------|
| Panel is black post-panic. | `_fb_console_active` was zero at panic time — either the PVH `-kernel` boot path (never inits fb) or a `fb_console_init` failure. | Confirm boot path is UEFI GOP (not PVH). Cross-check the R23 fingerprint (`FB CONSOLE INIT OK`) appears before the panic. |
| Banner appears, ring dump missing. | `klog_ring_dump_panic` fb-mirror hook regressed or was compiled out. | Verify `k_panic_fb_banner` and `klog_ring_dump_panic` are both linked (`nm build/kernel.elf | grep -E 'k_panic_fb_banner\|klog_ring_dump_panic'`). Re-audit `src/kernel/core/klog/panic.pdx` step 3.7 through step 4 for regression. |
| Photograph is blurry / illegible. | Camera focus, hand shake, or glare. | Retake at higher shutter speed with the phone on a stable surface; use manual focus. Rotate the panel or reduce ambient light to eliminate glare bands. |
| Banner colour is grey instead of red. | ANSI SGR parser regressed or the panel colour profile flattens hue. | Cross-check that non-panic SGR sequences render correctly (from a shell test using `printf '\x1b[31mR\x1b[0m'`). If they do, the panel colour is the issue — accept the test if the banner is glyph-visible (bold, distinct from surrounding text) even if colour is muted. |
| Ring dump text is present but garbled. | Font glyph corruption, wrong LFB pitch, or the WC-mapped LFB was not fully flushed before HLT. | `fb_console_flush` (if exposed) or add an `mfence` prior to `cli; hlt`. Diagnose via QEMU-OVMF §3 first — if QEMU is clean and T14 G4 is not, escalate to a GOP-pitch-mismatch quirk in `design/hardware/quirks.md §2.4`. |

---

## 6. Related documents

- `design/hardware/quirks.md §2.5` — UART / no-chassis-header row; the
  fallback this test proves.
- `design/round-retrospectives/r23-closure.md` § "Real-Hardware
  Verification Procedure" step 5 — the R23-close-time draft of this
  recipe.
- `src/kernel/core/klog/panic.pdx` — `klog_panic` step 3.7 fb-banner
  emit.
- `src/kernel/core/klog/keys.pdx` — `k_panic_fb_banner` byte slice.
- `src/kernel/core/klog/ring.pdx` — `klog_ring_dump_panic` fb-mirror
  hook.
- `src/kernel/core/drivers/fb_glyph.pdx` — glyph rasterizer (8x16
  font).
- `src/kernel/core/drivers/fb_console.pdx` — ANSI SGR parser.
- `tools/panic-fb-recovery-smoke.md` — operator quick-reference.
- `design/testing/hw-regression-matrix.md` — where the
  `panic-fb readable` column lives per target.

---

*Landed 2026-08-11 at R28.M3 close (#1005).*
