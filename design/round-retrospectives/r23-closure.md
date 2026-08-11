// R23 Retrospective: Framebuffer Console (GOP direct)

**Date:** 2026-08-11
**Milestone:** R23.M1–R23.M3 (all closed; M3 = closure milestone this doc + #885)
**Issues:** 11 landed across 3 milestones (10 implementation + 1 closure); zero deferrals from R23-scoped work
**HEAD at closure:** (bumped by the R23.M3 commit that lands this doc)
**paideia-as pinned at:** `2cf169d` — unchanged across R23 (zero cross-repo escalations this round)

---

## Round Intent

R23 was scoped as the framebuffer-console-via-GOP round per
`design/roadmap/r18-plus-bare-metal.md` §R23 — the first display-plane
work of the OS. The three milestones threaded the substrate first, then
the console body, then the panic/tty fanout in order:

- **M1:** Framebuffer substrate — IA32_PAT programming for the WC slot
  (BSP + AP) so the LFB can be mapped write-combining, `fb_map_lfb`
  identity-mapping the GOP LFB into a high-VA window at PML4[320] with
  the PAT bit set, and the embedded VGA 8x16 font asset + `fb_font`
  module exposing the row-fetch primitive.
- **M2:** Framebuffer console body — glyph rasterizer `fb_glyph`,
  scrolling text console `fb_console` backed by a `u16` cell grid + attr
  byte, ANSI state machine (SGR 16-color, CUP, ED, EL), public byte-in
  entry point `fb_console_puts`, and the dormant `_fb_console_active`
  mirror hook inside `klog_ring_drain_to_uart` so every drained klog
  byte reaches both COM1 and the framebuffer without dropping the serial
  primary.
- **M3:** Fanout + closure — TTY vnode `tty_write` alt-sink to fb (#883)
  so direct userspace writes (not just klog) reach the display; kernel
  panic path fb-mirror (#884) with a bold-red `*** PANIC ***` banner
  and per-byte ring-dump mirror so a photograph of a frozen T14 G4
  screen captures the last panic state; R23 closure retro + STATUS.md +
  T14 first-visual-output recipe (#885, this document).

Pillar target (from `design/00-feature-inventory.md`): give the OS a
paideia-native display plane wired directly against the UEFI GOP LFB
handoff, without any accelerated GPU driver on the MVP critical line.
By R23 close the kernel can drive a scrolling text console with ANSI
16-color + cursor positioning + partial-screen erase on any UEFI system
whose GOP surfaces a linear framebuffer — end-to-end paideia code, no
firmware callouts after boot handoff.

---

## What Shipped

### R23.M1 — Framebuffer substrate (4 issues: #875–#878)

- **#875 PAT + IA32_PAT programming (BSP + AP)** —
  `src/kernel/core/mm/pat.pdx`. `pat_init_this_cpu` writes the canonical
  PAT-entry MSR (0x277) with slot 1 remapped to WC (write-combining) and
  the rest of the standard Intel default preserved (WB / UC / UC- / WT
  in their usual slots). Called on the BSP by `kernel_main` right after
  the paging bring-up; called on every AP by `ap_entry` after
  `gs_base_init_ap`. `nm build/kernel.elf` shows `pat_init_this_cpu` +
  `pat_init_ap` linked. Fingerprint `tag_pat_init_ok` on both BSP and AP
  entry paths.
- **#876 LFB map with fb_map_lfb** —
  `src/kernel/core/drivers/fb_map.pdx`. Identity-maps the physical
  framebuffer base (`_boot_env.fb_base_pa`) as `pitch * height` bytes
  into a fresh high-VA window at PML4[320] `0xFFFF_A000_0000_0000`
  (collision-free vs. the kernel image and future R25+ physmap window)
  via a loop over `aspace_map` with PTE flags = `NX | PAT(bit 7) | RW`
  (aspace_map itself ORs in `PRESENT`). With #875's IA32_PAT programming
  in place, the PTE bit triple `(PAT=1, PCD=0, PWT=0)` decodes as WC
  memory type — correct for LFB drawing. PVH-boot fallback: when
  `fb_base_pa == 0` (no boot_env), `fb_map_lfb` returns 0 without
  touching page tables so the smoke matrix stays clean.
- **#877 embedded vgacon-8x16 font asset** — `assets/fonts/vga8x16.bin`
  (4096 bytes) — the standard Linux vgacon font, one glyph per 16-byte
  row-stride, 256 glyphs total. `.gitignore` refresh so the derived
  build outputs stay ignored. Loaded via paideia-as `@include_bytes`
  directive — no build-time generation script needed.
- **#878 fb_font module** — `src/kernel/core/drivers/fb_font.pdx`.
  `_fb_font: [u8; 4096]` binds the `@include_bytes` payload; public
  `fb_font_row(glyph, row) -> u8` returns the byte for one 8-pixel row
  of one glyph, ready for the rasterizer to walk.

**Closure commit:** `a45a7f9`.

### R23.M2 — Framebuffer console + ANSI subset (4 issues: #879–#882)

- **#879 glyph rasterizer** — `src/kernel/core/drivers/fb_glyph.pdx`.
  `fb_draw_glyph(fb_va, pitch, x_px, y_px, glyph, fg_rgb, bg_rgb)` walks
  16 rows × 8 pixel columns per glyph, plots one 32-bpp pixel per column
  (fg on set bit, bg on cleared bit). Byte-level rasterization, no SIMD
  yet.
- **#880 fb_console_init** —
  `src/kernel/core/drivers/fb_console.pdx`. Public entry point takes
  `(fb_va, width, height, pitch)` from `fb_map_lfb`, computes
  `cols = min(width/8, 256)` and `rows = min(height/16, 80)`, populates
  the 8-slot `_fb_console_ctx` (fb_va, pitch, cursor x/y, cur_attr=0x07
  gray-on-black, cols, rows), resets the `_ansi_state` machine
  (mode=NORMAL, params cleared), clear-grids to `FB_CELL_DEFAULT`
  (0x0720 = white space on black), redraws the pixel buffer, and
  finally sets `_fb_console_active = 1` so the klog drain mirror hook
  starts firing. Wire-in at `kernel_main`: gated on `_boot_env_pa != 0`
  and a successful `fb_map_lfb`, so the PVH `qemu -kernel` boot path
  stays dormant end-to-end.
- **#881 fb_console_putchar + ANSI subset** — same file. Byte-in
  entrypoint drives a 3-mode ANSI state machine (NORMAL → ESC → CSI)
  with dispatch on final byte: `m` = SGR (16-color foreground +
  background, bold, reset), `H` = CUP (cursor position), `J` = ED
  (erase display), `K` = EL (erase in line). Unknown escapes silently
  drop and reset mode to NORMAL — cursor never gets stuck in the state
  machine. Grid-vs-pixel writeback is atomic per character.
- **#882 fb_console_puts + klog drain fb-mirror hook** — same file for
  the puts wrapper (3-push callee-save + byte-load loop feeding
  putchar), and `src/kernel/core/klog/ring.pdx` for the hook: after each
  UART store inside `klog_ring_drain_to_uart`, check
  `_fb_console_active`; if nonzero, call `fb_console_putchar(byte)` with
  the same byte (stashed in rbx across the UART store). Register plan
  documented in the ring-drain justification. Under `qemu -kernel` this
  is a dormant load+compare — no visible behavior change to the R22
  smoke matrix.

**Closure commit:** `79ab3a8`.

### R23.M3 — TTY alt-sink + panic fb-mirror + R23 closure (3 issues: #883–#885)

- **#883 TTY vnode alt-sink — mirror to COM1 and framebuffer** —
  `src/kernel/core/tty/write.pdx`. Extends `tty_write` with a tail that
  runs after the existing UART `\n → \r\n` translation loop drains:
  gated on `_fb_console_active != 0`, hand the original caller-supplied
  `(buf, len)` slice to `fb_console_puts` so userspace writes (not just
  klog lines) reach the display. Register plan: rbx (buf) and r12 (len)
  are still live from the UART loop's callee-save prologue so no reload
  is needed. Under `-kernel` PVH boot the flag stays 0 and the tail
  collapses to a load+compare + short-jump — no regression to the R16.M5
  tty smoke matrix.
- **#884 Kernel panic path writes ring to framebuffer** —
  `src/kernel/core/klog/panic.pdx` + `src/kernel/core/klog/ring.pdx` +
  `src/kernel/core/klog/keys.pdx`. Two changes:
  1. `klog_panic` gains step 3.7 between the rbp stack walk and the
     ring dump: if `_fb_console_active != 0`, emit the 26-byte
     `k_panic_fb_banner` byte slice via `fb_console_puts`. Wire bytes:
     `ESC [ 1 ; 3 1 m` (SGR bold + red) → `*** PANIC ***` → `ESC [ 0 m`
     (SGR reset) → `\r\n`. NO screen clear, so the pre-panic boot log
     stays visible above the banner. Banner authored as a numeric
     `[u8; 26]` array literal (no dependence on paideia-as string-escape
     syntax).
  2. `klog_ring_dump_panic`'s busy-emit loop gains a fb-mirror tail
     after each `uart_putc`: byte stashed in r13 (callee-save, freshly
     added to the 3-push prologue) so it survives both nested calls,
     load+compare `_fb_console_active`, and — if live — call
     `fb_console_putchar(byte)`. Wire order on the display: `*** PANIC
     ***` banner → `PANIC DUMP BEGIN` marker (via drain-mirror from the
     BEGIN klog_s1) → full ring history (via the new busy-loop mirror)
     → `PANIC DUMP END` marker (via drain-mirror from the END klog_s1).
     Photograph-recoverable per `design/hardware/quirks.md` §2.5
     no-UART fallback.
- **#885 R23 closure retro + STATUS.md + T14 first-visual-output
  moment** — this document + STATUS.md R23 CLOSED block + quirks-db pass
  + tag `r23-closed`. Real-hardware verification recipe below (§
  "Real-Hardware Verification Procedure").

**Closure commit:** (this M3 commit).

---

## Cross-Repo Escalations to paideia-as (R23)

**None.** `paideia-as` submodule remained pinned at `2cf169d` for all
three R23 milestones. Every encoder mnemonic used by R23 was verified
pre-existing before implementation:

- PAT MSR programming: `rdmsr` / `wrmsr` (R21.M5 substrate).
- LFB PTE stamping: `aspace_map` reuse (R14b substrate + #759 fix at
  `b118282`).
- Font asset: paideia-as `@include_bytes` directive (native — no build-
  script generation).
- Glyph raster: byte load + pixel store via existing `mov_b` / `mov_d`
  (R20.M4 substrate).
- ANSI state machine: `cmp` + `je` + indirect dispatch via labeled
  targets — no new ops.
- fb_console_puts loop + klog mirror hook: same shape as pre-existing
  klog ring drain — no new mnemonics.
- Panic fb-banner emit: byte-array literal + `lea rip + sym` + call —
  all pre-existing.

Three ambient "paideia-as-blocked" labels queued into the R23 planning
sheet (font `@include_bytes`, PAT MSR-slot programming, ANSI state
machine emit) were reviewed and downgraded on inspection — all three
tacked cleanly onto existing encoder features. Paper tigers confirmed;
zero submodule bumps required across R23.

---

## Observable Proof

- Kernel builds clean under `tools/build.sh` — **15/15 verify gates
  pass** (no-AML lint + opcode-canary + kernel dispatch + sched guards
  + tty_read wrapper + link).
- All 15 default pre-push smoke modes pass (`boot_r8_only` through
  `boot_smp`, incl. `boot_r14b_*` KPTI/hivma/ipi/loader, `boot_r17_*`
  shell echo_hello/multi_command/shutdown/child_process). No new
  fingerprint added under `-kernel` — the fb subsystem is dormant on
  that boot path by design.
- R22 opt-in smokes still pass under R23 changes:
  - `PAIDEIA_R22_PCI_TREE=1 boot_r22_pci_tree` → unchanged (fb wire
    lives above the PCI enumerator).
  - `PAIDEIA_R22_MSIX_IR=1 boot_r22_msix_ir_round_robin` → unchanged
    (still SKIP under -kernel).
- R21 opt-in smokes still pass under R23 changes: `boot_r21_ymm_preserve`
  / `_ioapic_reroute` / `_msix_round_robin`.
- `nm build/kernel.elf` shows every R23 substrate symbol linked:
  `pat_init_this_cpu`, `pat_init_ap`, `fb_map_lfb`, `_fb_font`
  (4096 B), `fb_font_row`, `fb_draw_glyph`, `fb_console_init`,
  `fb_console_putchar`, `fb_console_puts`, `_fb_console_ctx`,
  `_fb_console_grid` (40960 B), `_fb_console_active`,
  `k_panic_fb_banner` (26 B), plus every ANSI dispatch helper
  (`ansi_dispatch_sgr` / `_cup` / `_ed` / `_el`) and the
  `fb_console_scroll_up` / `_redraw_all` / `_clear_grid` / `_draw_cell_at`
  private helpers.
- No new dynamic serial fingerprint between R22 close and R23 close on
  the `-kernel` boot path (fb never activates → no fb-side output). The
  R23 first-visual-output moment is UEFI-only.

---

## What Worked (Round Discipline)

1. **softarch → debugger loop shape held throughout.** No mid-round
   pauses; each milestone's kickoff was an architect+implement pass
   producing all sub-issue landings + wire-ups, followed by a debugger
   pass. Zero workerbee invocations (per
   `feedback_paideia_os_loop_shape.md`).

2. **Continuous tempo across three milestones.** Per
   `feedback_paideia_os_tempo.md`, R23 ran continuous with no between-
   milestone review pause. All three milestones closed within a single
   loop day.

3. **Dormant-hook discipline.** Every new fb code path is guarded by
   `_fb_console_active`, which stays 0 on the PVH `-kernel` boot path
   because `fb_console_init` is gated on `_boot_env_pa != 0` and a
   successful `fb_map_lfb`. Result: R23 is invisible to the R22 smoke
   matrix — no fingerprint churn, no accidental regressions. The klog
   drain hook, the TTY alt-sink, the panic banner, and the ring-dump
   mirror all collapse to a load+compare + short-jump under -kernel.

4. **Paper-tiger downgrades saved cross-repo churn three times.** The
   font `@include_bytes` label, the PAT MSR-slot programming label, and
   the ANSI state machine emit label were all pre-emptively marked
   "paideia-as-blocked" during R23 planning. Careful inspection of the
   actual requirements showed each tacked cleanly onto pre-existing
   encoder features. Zero submodule bumps across R23.

5. **The banner-as-byte-array-literal move.** Rather than gamble on
   paideia-as's `\x1b` string-escape support (empirically absent from
   the current codebase — `grep` turned up zero uses), the panic banner
   was authored as an explicit `[u8; 26]` numeric literal in `keys.pdx`.
   Robust against paideia-as string-escape-syntax churn; documented
   byte-by-byte in the source comment. Same idiom is available to any
   future ANSI-heavy string constant.

6. **Photograph-recoverable panic as an intentional design property.**
   `design/hardware/quirks.md` §2.5 flagged 18 months ago that the T14
   G4 chassis has no debug UART on the outside — real-hardware panic
   diagnosis therefore lives or dies on framebuffer output. #884 lands
   with that photograph-recoverable property as an explicit acceptance
   gate, not an accidental byproduct: banner ABOVE ring dump, boot log
   NOT cleared, bold-red SGR for unmissable-in-photo contrast. Even
   with no serial line and the system frozen, someone can take a photo
   of the screen and read the last state.

---

## What Didn't Work

1. **Two paideia-as encoder polish gaps surfaced during M2 without
   blocking.** The M2 architect pass turned up two minor encoder
   deficiencies that were worked around inline but should be closed in
   a later paideia-as pass:
   - `cmp r64, imm32` did not sign-extend the immediate in one
     variant of the ANSI param-count guard — worked around by loading
     the constant into a scratch register first.
   - `add r64, [mem]` load-op form was routed through a two-step
     `mov + add` — cost is one extra instruction per use, no
     correctness delta.

   Both are queued as encoder polish issues for the next paideia-as
   round (post-2cf169d); neither blocks R23 close or R24 opening. Not
   filed as blockers — they are literally "one extra instruction per
   use" issues.

2. **fb_console never lit under smoke.** The R23 substrate cannot be
   end-to-end verified under `qemu -kernel` because that boot path does
   not surface `_boot_env` / GOP handoff. The R23 fb path only
   activates on UEFI/OVMF boots (which is the R19 substrate, still
   gated behind a real ESP + OVMF drive assembly). Result: every R23
   witness is a **structural** witness — kernel.elf link + symbol table
   inspection + dormant-hook load+compare paths. The live-console
   first-light is queued for T14 G4 hardware bring-up (see §
   "Real-Hardware Verification Procedure" below).

3. **No opt-in smoke mode for fb console.** Unlike R22's
   `boot_r22_pci_tree` / `_msix_ir_round_robin` SKIP-mode entries,
   R23 does not land a `boot_r23_fb_console` smoke mode. Rationale:
   under `-kernel` the mode would produce identical output to
   `boot_r8_only` (fb is dormant → no fb-side text) — SKIP-echo would
   be indistinguishable from the baseline. The UEFI/OVMF harness is the
   right place for the fb smoke, which lands as R24+ scope alongside
   the OVMF drive assembly.

4. **`k_panic_fb_banner_len` as a separate constant.** The banner's
   length (26) is stored redundantly: once in the array type
   `[u8; 26]`, once in `k_panic_fb_banner_len : u64 = 26`, and once
   inline in `klog_panic`'s `mov rsi, 26`. Three sources of truth for
   one number. Not urgent (26 is unlikely to drift), but a small
   compile-time-size intrinsic in paideia-as would collapse this to
   one source. Filed as a nice-to-have, not a bug.

---

## Preflight for R24

**R24 (NVMe driver — first real userspace driver on top of R22's PCI
substrate + R23's display plane)** — opens after R23 close. Draft
preflight to land as `design/round-retrospectives/r24-preflight.md` at
R24.M1 kickoff. R24 needs from R23:

1. **`fb_console` as the boot-progress display.** R24 driver-plane
   fingerprints (`NVMe probe`, `NVMe queue init`, `NVMe I/O OK`) will
   already reach the framebuffer via the klog drain mirror hook that
   R23.M2 landed — no additional wiring needed on the R23 side.
2. **The panic-to-fb path as the R24 diagnostic surface.** When R24
   NVMe bring-up trips a panic on real T14 G4 hardware, the operator
   will read the last state off the framebuffer via #884 photograph
   recovery. No UART fallback needed.
3. **`fb_map_lfb` idempotency contract.** R24 does not remap the LFB.
   `fb_map_lfb`'s "return 0 on no boot_env" contract stays the R24
   boot-path integration point.

**R24 does NOT need from R23:**

- An accelerated GPU driver. R23 explicitly left GPU acceleration
  off-plane per Pillar 3 (`design/00-feature-inventory.md`) — text
  console via GOP LFB is the MVP surface, and R24+ does not change it.
- ANSI color support beyond SGR 16-color. R24 driver diagnostics reuse
  the R22.M1 fingerprint-level convention (uppercase tags + `k_*`
  strings) which are all monochrome-friendly.
- A dedicated fb-panic ring channel. #884 mirrors the same klog ring
  that COM1 gets; R24 panics land there via `klog_panic` unchanged.

**R24 blockers (external):**

- paideia-as v0.22 tag remains uncut; R24 does not need a tag bump for
  the NVMe substrate proper. Slice + bitfield helpers from v0.22 (per
  `design/roadmap/r18-plus-bare-metal.md` §9 tables §5) would ease
  SQE/CQE construction but are not blockers — R24 can hand-code the
  packed fields via existing `mov_d` / `mov_b` stores.
- The T14 G4 first-light PCI + ACPI capture (R22 debt item #9) remains
  hardware-gated. R24 opens on QEMU (`-machine intel-iommu=on` plus
  virtio-nvme), promotes to T14 G4 when the operator captures the
  fixtures. No R23 debt blocks R24 opening.

---

## R23 Debt Carried Forward

Ledger of items deferred past R23 close:

1. **UEFI/OVMF smoke harness for fb_console** — no `boot_r23_fb_console`
   mode landed; the fb subsystem stays dormant under `-kernel` by
   design. Full live-first-light lands when the R19 UEFI/OVMF harness
   grows a scripted screen-capture path (R24+ scope alongside the ESP
   drive assembly).

2. **T14 G4 first-visual-output capture** — GATED ON HARDWARE. Recipe
   in this document (see § "Real-Hardware Verification Procedure").
   Fixture placeholder deferred until first-boot: the fb output is a
   pixel buffer, not a byte stream, so the fixture format needs a
   design pass (image checksum? framebuffer-blit hash? framebuffer-
   region-crc?) before a placeholder can land — filed as an R24 debt
   item, not R23.

3. **fb_map_lfb assumes 32-bpp BGRA.** The rasterizer plots one 32-bpp
   pixel per column with the fg_rgb / bg_rgb args as raw u32 stores.
   OVMF's GOP handoff canonicalises to 32-bpp BGRA on x86, but a real
   HW pass may surface a different pixel format via
   `EFI_GRAPHICS_OUTPUT_PROTOCOL::Mode->Info->PixelFormat`. R24+ hardens
   the rasterizer to consume the pixel-format enum. QEMU-TCG stays
   BGRA-only for R23.

4. **`_fb_console_grid` is fixed [u16; 20480].** 256 cols × 80 rows =
   20480 cells @ u16 each = 40960 B of .bss. Sufficient for the T14 G4
   1920x1080 native display (240 cols × 67 rows = 16080 cells) with
   headroom, but any UEFI system whose GOP surfaces > 256 cols or > 80
   rows will silently clip. R24+ can promote to a `.bss` slab sized by
   boot-time queries when a hardware target exceeds these bounds.

5. **`k_panic_fb_banner_len` duplication.** Length 26 is stored in
   three places (array-type dimension, `_len` constant, inline `mov rsi,
   26` in `klog_panic`). Filed as nice-to-have paideia-as intrinsic
   request (`sizeof_bytes(sym)` at compile time); no functional impact.

6. **No opt-in `boot_r23_*` smoke mode** — see § "What Didn't Work" §3
   for rationale. Not a debt against R23 acceptance; a placeholder
   entry in `tools/run-smoke.sh` is not appropriate because there is
   nothing to fingerprint on `-kernel`. Reopens as R24 driver-plane
   scope.

7. **Two paideia-as encoder polish gaps from M2** —
   `cmp r64, imm32` sign-extend variant + `add r64, [mem]` load-op
   form. Both worked around inline (one extra instruction per use, zero
   correctness delta). Filed as paideia-as encoder polish for the next
   paideia-as round; neither blocks R23 close or R24 opening.

8. **R22 debt items still open (unchanged from R22 close):**
   `_vtd_base` hardcoded; `has_dmar` slot unpopulated;
   `vtd_fault_dispatch` not IDT-wired; `msix_enable_device` inside
   `msix_assign_at_ir`; `msix_assignments` ledger append; full
   `GCMD.TE + SIRTP + IRE` ceremony; DMA-fault regression SKIP → LIVE;
   T14 G4 first-light captures.

9. **R21 debt items still open:** `hpet_now_ns` precision widening;
   `phase1_acpi_gather` full wire (partial at R22.M1 — MCFG only).

**None regress R23 acceptance.**

---

## Quirks Discovered on Real Hardware

None (R23 ran under QEMU-TCG throughout — actually, purely under
`qemu -kernel` since the UEFI/OVMF harness is not landed yet). No rows
in `design/hardware/quirks.md` promoted `PROVISIONAL → CONFIRMED` at
this pass. The T14 G4 first-visual-output moment (see below) will
promote the display-plane rows in §2.4 + §2.5 when it lands.

Quirks-db discipline recap at M3:
- §2.5 (Debug + observability) — the `UART / No debug UART on chassis`
  row's Handling column is updated at this pass to reference #884 (the
  photograph-recoverable panic path is the fallback the row calls for).
- No new rows added — R23 discovered nothing new about the T14 G4 that
  wasn't already anchor-documented at R20.M5 or R22.M6.

---

## Milestone Discipline Statement

R23 held to the round-tempo user preference: continuous loop across all
issues + milestones with no mid-round pause. Three milestones closed in
roughly one loop day; 11 issues landed (10 implementation + 1
closure). Zero deferrals from R23-scoped work — every planned R23
issue landed cleanly.

The `softarch → debugger` loop shape held throughout with zero
workerbee invocations. Cross-repo escalation to paideia-as fired **zero
times** during R23 — the substrate was ready for every encoder R23
needed, and all three ambient "paideia-as-blocked" labels (font
`@include_bytes`, PAT MSR-slot programming, ANSI state machine emit)
were downgraded on inspection. `paideia-as` submodule pin `2cf169d`
unchanged from R21 close.

---

## Real-Hardware Verification Procedure (T14 G4 Raptor Lake, R23 gated:hardware — the T14 first-visual-output moment)

The R23 substrate cannot be end-to-end verified under QEMU-TCG's PVH
`-kernel` boot (no `_boot_env`, no GOP handoff → `fb_console_init`
never runs → the entire fb subsystem stays dormant). The first live
first-light moment on T14 G4 is queued for R24+ hardware bring-up. This
recipe documents the acceptance procedure.

1. **Prepare boot media.** Build kernel + ESP image per
   `design/roadmap/r19-t14-g4-boot-guide.md`. Confirm the R19 UEFI PE32+
   loader stub is baked into the ESP with an entry at `\EFI\BOOT\BOOTX64.EFI`
   that hands off to the paideia-os kernel with a populated
   `_boot_env` (fb_base_pa, width, height, pitch from the UEFI GOP
   protocol).

2. **BIOS setup.** Confirm Legacy CSM = off, Secure Boot = off (for
   the R23 capture pass — R33 signing lands later), Intel VMD Controller
   = Disabled (per #870 quirk row, so R24's NVMe surfaces cleanly).

3. **Boot on T14 G4.** Serial output over Intel DCI (USB-C debug
   dongle) should show the R22 fingerprints (`HPET`, `TSC`, `MCFG PRESENT`,
   `PCI DEV`, `PCI ENUM DONE`, `X2APIC ENABLED BSP`, `SMP BRINGUP`)
   followed by the R23 wire-up fingerprint (`FB CONSOLE INIT OK` or
   equivalent).

4. **T14 first-visual-output moment.** Immediately after boot handoff
   (before SMP bring-up completes), the internal eDP display should
   light up with the paideia-os boot log. Verify:
   - **Grid dimensions** — expected 240 cols × 67 rows on the T14 G4's
     native 1920x1080 eDP panel (256-col × 80-row storage slab has
     headroom for 4K external displays via HDMI 2.1 or DP-alt over
     TB4).
   - **Text colour** — white glyphs on black background (attr 0x07),
     from `FB_CELL_DEFAULT = 0x0720`.
   - **ANSI SGR** — if the kernel emits `\x1b[31mRED\x1b[0m` (via a
     `klog_puts_ansi(...)` witness — future R24 work), the RED text
     should render in the SGR-31 red palette entry.
   - **Cursor advance** — each fingerprint line should scroll upward
     naturally as it lands on the display; the newest line should
     always be the bottom-most non-blank row.
   - **Simultaneous UART output** — the same fingerprints should reach
     the DCI-attached serial line at the same time (klog drain fb-mirror
     hook is bidirectional-visible, not one-or-the-other).

5. **Panic recovery photograph acceptance test.** Inject a synthetic
   panic (a witness `k_r23_fb_panic_witness` that calls
   `klog_panic(SUBSYS_PANC, tag)` after boot handoff completes). The
   display should show:
   - A boot log filling the upper portion of the screen.
   - A bold-red `*** PANIC ***` banner line.
   - The full ring dump (BEGIN marker + oldest-to-newest ring bytes +
     END marker) filling the lower portion of the screen.
   - No further activity (CPU halted).

   Take a photo of the frozen screen with any phone camera. The photo
   should be legible enough to transcribe the last few klog lines,
   including subsystem tags and TSC values, without any need to attach
   a serial debugger.

6. **Promote quirks-db rows.** Once the display comes up, promote
   `design/hardware/quirks.md` §2.5 (UART / no debug UART / handling
   references #884 fb-panic path) from `PROVISIONAL` to `WORKED-AROUND`.
   Any new display-related quirk (e.g. GOP pixel-format non-BGRA,
   pitch > 4 * width padding, GOP handoff at a non-canonical LFB base)
   gets a fresh row under §2.4 or §2.5 with `Round observed = R24.Mx`.

**None of this blocks R23 close.** The QEMU-side R23 substrate is
proven via `kernel.elf` linkage + dormant-hook load+compare paths + the
existing R22 smoke matrix showing zero regressions. T14 G4 first-visual-
output is a separate hardware-availability event queued for R24+.

---

## Next Round

**R24 (NVMe userspace driver on top of R22's PCI substrate + R23's
display plane).** See `design/roadmap/r18-plus-bare-metal.md` §R24.
Preflight document to land at R24.M1 kickoff as
`design/round-retrospectives/r24-preflight.md`.

R24 blockers: none from R23. Ready to open.

---

**Closure.** R23 framebuffer console via GOP direct — closed 2026-08-11.
