# R26 Retrospective: USB xHCI substrate + HID Boot Keyboard bring-up

**Date:** 2026-08-11
**Milestone:** R26.M1–R26.M6 (all closed; M6 = closure milestone this
doc + #965/#966/#967/#968/#969/#970)
**Issues:** 30 landed across 6 milestones (24 implementation + 6
closure). Zero fully-deferred R26-scoped issues. All 3 ambient
`paideia-as-blocked` labels on R26 issues resolved as paper tigers
on inspection.
**HEAD at closure:** (bumped by the R26.M6 commit that lands this doc)
**paideia-as pinned at:** `2cf169d` — unchanged across R26 (**sixth
consecutive round** with zero cross-repo escalations, since R21 close).

---

## Round Intent

R26 was scoped as the USB xHCI + HID keyboard round per
`design/roadmap/r18-plus-bare-metal.md` §R26 — the first user-input
plane on top of the R22 PCIe substrate. The six milestones threaded
the controller substrate first (probe + regmap + BIOS handoff +
reset), then the command/event/MSI-X plumbing, then port reset and
slot lifecycle, then the DCBAAP + Configure Endpoint + Transfer Ring,
then Control Transfers + HID class match + Boot Protocol, then round
closure (HID keymap + report parser + TTY bridge + hotplug handler +
T14 smoke + retro):

- **M1:** Controller substrate — `probe.pdx` (class 0C/03/30 match),
  `regs.pdx` (Cap + Op window u32/u64 accessors), `bios_handoff.pdx`
  (USBLEGSUP RW1S ownership transfer), a `sysreg` gate over the SMI
  Enable mask, `reset.pdx` (Halt -> HCRST -> CNR clear -> CONFIG.
  MaxSlotsEn program).
- **M2:** Ring plumbing — `cmd_ring.pdx` (256 × 16 B Command Ring
  with Link TRB), `event_ring.pdx` (Event Ring Segment Table +
  segment 0 + `event_ring_ctx`), `msix.pdx` (MSI-X table map +
  vector 0 arm), `doorbell.pdx` (DB[0] + per-EP DB writer with
  fence discipline).
- **M3:** Ports + slots — `ports.pdx` (PORTSC accessors +
  RW1C-preserving write + port-reset settle-poll),
  `slot.pdx` (Enable Slot + Address Device commands with
  Command Completion Event polling), `context.pdx` (Input Context
  + Slot + EP0 Context populate with speed-derived MPS).
- **M4:** DCBAAP + slot lifecycle + Configure Endpoint + Transfer
  Ring — `dcbaap.pdx` (DCBAA anchor + Device Context pool +
  DCBAAP MMIO program), `slot_lifecycle.pdx` (slot state shadow +
  Disable Slot command), `configure_ep.pdx` (Configure Endpoint
  command for EP1 IN Interrupt with hardcoded HID boot defaults),
  `transfer_ring.pdx` (per-endpoint 256-TRB ring + enqueue helper).
- **M5:** Control Transfers + HID class + Boot Protocol —
  `control_xfer.pdx` (3-TRB Control Transfer with Setup / Data /
  Status; `xhci_get_descriptor(Device)`; Configuration descriptor
  TLV parser; `xhci_set_configuration`), `hid.pdx` (HID class
  match hook + `xhci_hid_set_boot_protocol(0)`).
- **M6:** Round closure — HID Usage Page 0x07 -> ASCII keymap
  (#965), report-diff press/release logic (#966), HID -> TTY bridge
  (#967), hotplug attach/detach handler (#968), T14 keyboard smoke
  harness + operator recipe (#969), R26 closure retro + STATUS.md
  block + quirks-db pass + tag `r26-closed` (#970, this document).

Pillar 4 target (`design/00-feature-inventory.md`): give the kernel
exactly the substrate a USB HID keyboard needs to see, address,
configure, and — under Boot Protocol — receive input from — with the
IRQ-driven event walker + full driver-attach ceremony deferred to
R27+ where it consumes the same #1015 userspace-server substrate
gate as #820 (acpi_supervisor) / #860 (pci_enumerator) / #906
(userspace half of `nvme_read_blocking`) / #1015 (userspace HID
driver / #963 partial-close sibling).

---

## What Shipped

### R26.M1 — Controller substrate (5 issues: #941–#945)

- **#941 xHCI probe** — `src/kernel/core/drivers/xhci/probe.pdx`.
  Class-code triple 0x0C / 0x03 / 0x30 filter over `_pci_devices`;
  publishes `_xhci_devices` (32 B stride) + `_xhci_device_count`;
  emits `XHCI PROBE N=<count>` fingerprint. Under `-kernel` boot
  `_pci_device_count == 0` -> count stays 0.
- **#942 Capability + Operational register accessors** —
  `regs.pdx`. `xhci_cap_u8/u16/u32` for the capability window,
  `xhci_op_u32` and `xhci_op_write_u32/u64` for the operational
  window (op_base = bar0 + CAPLENGTH). All with mfence discipline.
- **#943 BIOS -> OS handoff** — `bios_handoff.pdx`. Extended
  Capabilities walk over the xECP chain looking for USBLEGSUP
  (cap ID 1); RW1S write to HC_OS_OWNED_SEM (bit 24); poll for
  HC_BIOS_OWNED_SEM (bit 16) clear with bounded budget.
- **#944 SMI Enable mask** — same file. USBLEGCTLSTS register
  write clears every SMI-generating condition so the platform can
  never re-enter SMM on an xHCI event. Behind the `sysreg` effect
  gate.
- **#945 Controller reset** — `reset.pdx`. Halt via USBCMD.RS
  clear + poll USBSTS.HCH set; USBCMD.HCRST assert + poll HCRST
  clear + poll USBSTS.CNR clear; program CONFIG.MaxSlotsEn =
  min(HCSPARAMS1.MaxSlots, 64).

**Closure commit:** `a73042d`.

### R26.M2 — Ring plumbing (5 issues: #946–#950)

- **#946 Command Ring** — `cmd_ring.pdx`. 256 × 16 B ring with a
  Link TRB at slot 255 (TC=1, Toggle Cycle); `xhci_cmd_enqueue`
  produces one TRB with cycle-last discipline (Parameter + Status
  written first, then Control with C bit set); wraparound
  re-publishes the Link TRB and toggles the SW cycle bit.
- **#947 Doorbell writer** — `doorbell.pdx`. DBOFF read from the
  Capability window; DB[0] writer (command doorbell); per-EP DB
  writer (DB target = DCI). Both with mfence-before to publish TRB
  stores globally before the doorbell write.
- **#948 Event Ring + ERST** — `event_ring.pdx`. Single 256-TRB
  segment; ERST allocated with room for 4 entries (headroom for R27
  multi-segment); ERSTSZ / ERSTBA / ERDP program; `event_ring_ctx`
  for SW-side dequeue index + expected cycle.
- **#949 MSI-X table map + arm** — `msix.pdx`. `_xhci_msix_table_
  info` (BAR + offset + N cached), `xhci_msix_map_arm_vec0` writes
  the LAPIC MSI Message Address + Data + Vector Control mask
  clear.
- **#950 Doorbell + MSI-X integration lint** — same files; ensures
  DBOFF and MSI-X capability offsets came out of the M1 register
  map exactly as documented.

**Closure commit:** `812fcfb`.

### R26.M3 — Ports + slots + input context (5 issues: #951–#955)

- **#951 PORTSC accessors** — `ports.pdx`. `xhci_port_read` /
  `xhci_port_write` with RW1C-preserving mask (bits 17..23 masked
  off in the value being written); port_1based -> portsc_off
  arithmetic.
- **#952 Port reset + settle poll** — same file. `xhci_port_reset`
  sets PR while preserving RW1C latches, polls PORTSC.PRC with
  budgeted spin, extracts PortSpeed from bits 10..13,
  acknowledges PRC via RW1C write.
- **#953 Enable Slot** — `slot.pdx`. Enqueue Enable Slot TRB (Type
  9) with SlotType=0; ring DB[0]; poll event ring for CCE (TRB
  Type 33); extract Slot ID from Control bits 24..31.
- **#954 Input Context init** — `context.pdx`. Per-slot 4 KiB
  Input Context page (`_xhci_input_contexts[slot_id]` at 4 KiB
  stride); zero via `rep_stosb`; populate Input Control Context
  add_flags = A0|A1, Slot Context DW0 (speed + context_entries=1),
  Slot Context DW1 (root_hub_port), EP0 Context DW1 (CErr=3 +
  EP Type=Control + speed-derived MPS), EP0 Context DW4
  (Average TRB Length = 8).
- **#955 Address Device** — `slot.pdx`. Enqueue Address Device
  TRB (Type 11) with BSR bit + Slot ID; ring DB[0]; poll for CCE;
  same completion discipline as Enable Slot.

**Closure commit:** `d5c6047`.

### R26.M4 — DCBAAP + slot lifecycle + Configure EP + Transfer Ring (4 issues: #956–#959)

- **#956 DCBAAP** — `dcbaap.pdx`. `_xhci_dcbaa` (128 × 8 B = 1024 B
  device-context array); `_xhci_device_contexts` (64 × 4096 B pool);
  zero both via `rep_stosb`; populate DCBAA[1..63] with per-slot
  device context PA; program DCBAAP MMIO with the DCBAA base.
- **#957 Slot Disable + slot-state shadow** — `slot_lifecycle.pdx`.
  `_xhci_slot_states` (128 × u8 = 128 B shadow); `xhci_slot_state_
  set/get`; `xhci_slot_disable` (TRB Type 10 + CCE poll + set slot
  state to DISABLED on success).
- **#958 Configure Endpoint (HID variant)** — `configure_ep.pdx`.
  `xhci_configure_ep_hid` for EP1 IN Interrupt (DCI=3) with
  hardcoded boot-HID defaults (MPS=8, interval=3, Average TRB Length
  =8); RMW of Slot Context DW0 to bump context_entries to 3; issue
  Configure Endpoint TRB (Type 12); poll for CCE; set slot state to
  CONFIGURED on success.
- **#959 Transfer Ring** — `transfer_ring.pdx`. Per-endpoint 256 × 16
  B ring with Link TRB wraparound; `xhci_transfer_enqueue_raw`
  produces one TRB (Parameter + Status + Control) with cycle-last
  discipline; sibling `_xhci_transfer_ring_ep1_in_ctx` for the SW-
  side enqueue index + cycle.

**Closure commit:** `8e5df01`.

### R26.M5 — Control Transfers + HID class + Boot Protocol (5 issues: #960–#964)

- **#960 Control Transfer core** — `control_xfer.pdx`.
  `xhci_transfer_enqueue_raw` (already at M4); precomputed control
  words (Setup IN / Setup NoData / Data IN / Data OUT / Status IN
  IOC / Status OUT IOC); `xhci_get_descriptor` composes the 3-TRB
  Control Transfer for GET_DESCRIPTOR(Device or Configuration).
- **#961 Configuration descriptor TLV parser** — same file.
  `xhci_parse_config_desc` walks a Configuration descriptor byte
  stream; records the first Interface (class/subclass/protocol) and
  first Endpoint (address / max packet size / interval) into a
  caller-supplied 8-byte output structure.
- **#962 Poll Transfer Event** — same file.
  `xhci_poll_transfer_event` walks the event ring waiting for a
  Transfer Event (TRB Type 32) with matching endpoint; returns the
  completion code.
- **#963 HID class match (kernel stub)** — `hid.pdx`.
  `hid_probe_from_config` returns 1 iff the parsed interface's
  class == 0x03 (USB HID); userspace HID class driver lives out-of-
  tree behind #1015 substrate.
- **#964 SET_PROTOCOL(0) Boot Protocol** — same file.
  `xhci_hid_set_boot_protocol` issues the class-specific 2-TRB
  Control Transfer (bmRequestType=0x21, bRequest=0x0B, wValue=0);
  same shape as `xhci_set_configuration` with a different
  bmRequestType.

**Closure commit:** `2cd1b0a`.

### R26.M6 — Round closure (6 issues: #965–#970)

- **#965 HID Usage -> ASCII keymap** —
  `src/kernel/core/drivers/xhci/hid_keymap.pdx`. Two 256-byte tables
  (`_hid_us_keymap` + `_hid_us_keymap_shifted`) populated for the
  0x00..0x38 range (letters, digits, punctuation, Enter/Esc/BS/Tab/
  Space) with 0-fill for the R27 tail (CapsLock, F-keys, keypad,
  nav). `hid_translate(usage, modifiers)` masks modifiers &
  HID_MOD_SHIFT_MASK (0x22) to select base vs shifted table.
- **#966 Report press/release + rollover** —
  `hid_report.pdx`. `_hid_prev_report` .bss anchor;
  `hid_process_report` diffs the new 8-byte report against prev,
  emits `HID KEY <ascii>\n` fingerprint on each new press,
  ignores rollover-marker reports (bytes [2..3] both 0x01),
  copies the new report into prev after processing.
- **#967 HID -> TTY bridge** — same file. `hid_bridge_to_tty`
  zero-guards on ASCII == 0 (unmapped code, must not enter TTY
  layer) then tail-calls `tty_process_input` (R16.M5 cooked-mode
  router).
- **#968 Hotplug handler** —
  `src/kernel/core/drivers/xhci/hotplug.pdx`.
  `xhci_hotplug_handler_event(bar0, event_trb_pa)` extracts Port ID
  from PSCE TRB Parameter[31:24], reads PORTSC, classifies as
  attach / detach / spurious via CCS + CSC, emits fingerprint,
  calls `xhci_port_reset` on attach (returns speed), clears CSC
  by RW1C write through `xhci_port_write`. Full attach/detach
  chain (slot enable + input ctx + address + configure_ep_hid /
  slot_disable + transfer-ring teardown) deferred to R27
  driver-attach — needs a per-port slot ledger.
- **#969 T14 keyboard smoke harness** —
  `tests/kernel/drivers/xhci/keyboard_witness.pdx` (structural
  witness — SKIP under `-kernel`, TRANSLATE + REPORT check on live
  HW) + `tools/xhci-keyboard-smoke.md` (operator recipe: UEFI boot
  -> shell prompt -> type `echo hello\n` -> verify `HID KEY *`
  fingerprints on serial). `gated:hardware`.
- **#970 R26 closure retro + STATUS.md + quirks + tag** — this
  document + STATUS.md R26 CLOSED block + quirks-db pass (§2.4 USB
  row anchored + new "T14 G4 USB keyboard Boot Protocol works
  after xHCI enable" row) + mouse-deferred note + tag
  `r26-closed`.

**Closure commit:** (this M6 commit).

---

## Cross-Repo Escalations to paideia-as (R26)

**None.** `paideia-as` submodule remained pinned at `2cf169d` for all
six R26 milestones — unchanged since R21 close. This is the **sixth
consecutive round** with zero cross-repo escalations
(`feedback_cross_repo_escalation.md` never fired in R26 planning or
implementation).

Three ambient `paideia-as-blocked` labels queued into the R26
planning sheet were reviewed and downgraded on inspection as
**paper tigers**:

- **Multi-arg SysV shim for `xhci_configure_ep_hid` (M4 #958).**
  The R25 preflight cited "6-arg SysV load with a synthesised
  stack pad" as an ease-of-implementation item. On inspection every
  6-arg call in R26 fit the SysV integer register file cleanly (rdi,
  rsi, rdx, rcx, r8, r9); the "synthesised stack pad" was never
  needed. Hardcoded HID boot defaults (MPS=8, interval=3) collapsed
  the 8-arg surface the naive port would have needed.
- **Register-width sanction for `mov [r14+0x88], rax` (M4 #958).**
  The 64-bit store spanning DW2+DW3 (TR Dequeue Pointer) landed
  as natural REX.W width — the encoder already emits this via the
  standard `mov reg64, mem` encoding. No paideia-as change needed.
- **Byte-array literal density for `_hid_us_keymap` (M6 #965).**
  The 256-byte keymap tables landed using the numeric `[u8; 256] =
  [0x00u8, 0x00u8, ...]` initializer form (same shape as
  `_msg_kernel_uefi` in `kernel_main_uefi.pdx:91`) with 16-per-line
  chunking. No paideia-as change needed.

Zero paideia-as submodule bumps required across R26. Zero PA-R26-*
escalation entries filed.

---

## Deferrals

R26 landed with several substrate deferrals — all in the
**driver-attach + IRQ-driven event walker** arc, chained on the
same external-blocker family the last four rounds have inherited.
Documented in-round (each M6 module header calls out the R27
dependency) rather than as after-the-fact debt discovery:

### D1. Full attach/detach chain in xhci_hotplug_handler_event — R27

**Scope:** `xhci_hotplug_handler_event` at M6 fires the port_reset
step on attach + emits fingerprint, but does not chain
`xhci_enable_slot -> xhci_input_context_init -> xhci_address_device
-> xhci_configure_ep_hid`. The detach path likewise does not chain
`xhci_slot_disable + transfer-ring teardown`.

**What blocks:** A per-port slot ledger (port_id -> slot_id map)
that survives across hotplug events. That ledger is a driver-attach
concern — where the ceremony lives in kernel_main_uefi, how it
gates on `Features.XHCI_ATTACH_ENABLED`, how it composes with the
R23 fb console + R17 shell bootstrap. Same shape as the R25 D2
mount-ceremony deferral (`design/round-retrospectives/r25-closure.
md §D2`).

**Rerouting:** R27 driver-attach round.

### D2. IRQ walker over event ring — R27

**Scope:** MSI-X vector 0 is armed in M2 (`msix.pdx`) but no IRQ
handler picks up the event ring at boot. Every event-ring polling
path in R26.M3–M6 (Enable Slot, Address Device, Configure Endpoint,
Control Transfer status) is *synchronous* — the calling function
spins on the event ring until it sees the expected completion.

**What blocks:** A per-CPU IRQ dispatch that dequeues events,
filters by TRB Type, and routes:
- Type 32 (Transfer Event) -> `hid_process_report(report_pa)` for
  EP1 IN reports (or per-endpoint dispatch table).
- Type 33 (Command Completion Event) -> per-command wake.
- Type 34 (Port Status Change Event) -> `xhci_hotplug_handler_
  event(bar0, event_trb_pa)`.

**Rerouting:** R27 driver-attach round.

### D3. #963 userspace HID class driver — R28+ (blocked on #1015)

**Scope:** `hid.pdx:hid_probe_from_config` is the kernel-side match
hook (class == 0x03). The full HID class driver lives in userspace
per PaideiaOS's out-of-kernel-except-substrate posture. Landed as a
partial-close in M5 with the R26.M6 header calling out that the
kernel stays out of report parsing.

**What blocks:** #1015 (userspace-server substrate — same gate that
blocks #820 acpi_supervisor / #860 pci_enumerator / #906 userspace-
half of `nvme_read_blocking`). Once #1015 lands, the userspace HID
server subscribes to the notification channel published on each
Transfer Event and produces the report-parse output for downstream
consumers (Wayland compositor at R30+ etc.).

**Rerouting:** R28+ per the R25 preflight's userspace-substrate
sequencing.

### D4. Boot-time driver attach in kernel_main_uefi — R27

**Scope:** Every R26 primitive is a `pub` symbol; `kernel_main_uefi`
does not invoke `xhci_reset -> xhci_bios_handoff -> ...` at boot.
Under QEMU-TCG `-kernel` this is moot (no MCFG -> no PCI enumeration
-> no xHCI controllers surface); on real hardware the driver-attach
ceremony is R26 debt that did not land.

**Rerouting:** R27 same as D1/D2.

### D5. Mouse support — R27+

**Scope:** R26.M6 supports **HID Boot Protocol keyboard only**. HID
mouse (usage page 0x02, boot protocol subclass 1 protocol 2) is out
of scope. The R26 substrate is *composable* with a boot-mouse
driver — the same Control Transfer + SET_PROTOCOL(Boot) sequence
applies, and a sibling `hid_process_mouse_report` would land next
to `hid_process_report` — but M6 does not ship it.

**What blocks:** No blocker beyond scope; the mouse driver has been
deferred to R27+ per the R26 planning sheet's "keyboard first, mouse
second" sequencing. Wayland compositor at R30+ needs mouse; that's
the natural pull.

**Rerouting:** R27+ HID input round (probably as a mini-sub-round
alongside the driver-attach ceremony).

### D6. Live capture on T14 G4

**Scope:** `xhci_keyboard_smoke_witness` is a `pub` symbol under
`-kernel` it always emits SKIP. On real HW via GDB it fires OK if
D1..D4 land. None have landed.

**Rerouting:** R27+ same as D1/D2.

---

## The Parallel-Race Lesson (R26.M5 -> #1016)

During R26.M5 landing, the parent agent reported issue #1016 (shell
echo drops trailing args due to r10 clobber across syscall) *while*
the softarch was mid-authoring the M5 files. The softarch's
uncommitted work was inadvertently removed by the parent-agent
context switch and had to be re-authored from the earlier commit
b8df859 baseline.

**Root cause:** Parallel work with shared uncommitted state. The
softarch had files staged but not yet committed to git; the parent
agent's #1016 investigation touched files in the same directory
tree, and a git checkout / clean during that debugging pass wiped
the softarch's WIP.

**Lesson codified for R26.M6 onwards:** COMMIT FILES QUICKLY once
they build. Do not accumulate more than one file's worth of
uncommitted work before running `bash tools/build.sh` + `git add`.
The build-and-stage cadence (`build; add; build; add`) preserves
work against parent-agent context-switch races.

This is a discipline pattern rather than a policy — the safest
alternative (running softarch under `EnterWorktree` isolation) would
force every softarch pass to be a merge afterward, which the softarch
loop doesn't currently amortise well. In-tree commits with quick
cadence stay the norm.

R26.M6 implementation followed this: `hid_keymap.pdx` was staged
immediately after its build passed, before `hid_report.pdx` began.
No parallel-race incidents at M6.

---

## Observable Proof

- Kernel builds clean under `tools/build.sh` — **15/15 verify gates
  pass** (no-AML lint + opcode-canary + kernel dispatch + sched
  guards + tty_read wrapper + link).
- All 15 default pre-push smoke modes pass (`boot_r8_only` through
  `boot_smp`, incl. `boot_r14b_*` and `boot_r17_shell_*`). No new
  fingerprint under `-kernel` — no R26 primitive fires
  (`_xhci_device_count == 0` under -kernel; `xhci_reset` never
  called; hotplug handler dormant).
- R22 opt-in smokes pass unchanged.
- R21 opt-in smokes pass unchanged.
- R24/R25 opt-in smokes pass unchanged.
- `nm build/kernel.elf` shows every R26 substrate symbol linked:
  M1: `xhci_probe`, `_xhci_devices` (128 B), `_xhci_device_count`,
  `xhci_cap_u8/u16/u32`, `xhci_op_u32`, `xhci_op_write_u32/u64`,
  `xhci_bios_handoff`, `xhci_reset`.
  M2: `xhci_cmd_enqueue`, `_xhci_cmd_ring` (8 KiB) + `_xhci_cmd_
  ring_ctx` (32 B), `xhci_event_ring_init`, `_xhci_event_ring` (8
  KiB) + `_xhci_erst` (64 B) + `_xhci_event_ring_ctx` (32 B),
  `xhci_msix_map_arm_vec0`, `_xhci_msix_table_info` (24 B),
  `xhci_ring_cmd_doorbell`, `xhci_ring_ep_doorbell`.
  M3: `xhci_port_read/write/reset`, `xhci_enable_slot`,
  `xhci_address_device`, `xhci_input_context_ptr`,
  `xhci_input_context_init`, `_xhci_input_contexts` (256 KiB).
  M4: `_xhci_dcbaa` (1024 B), `_xhci_device_contexts` (256 KiB),
  `xhci_dcbaap_init`, `_xhci_slot_states` (128 B),
  `xhci_slot_state_set/get`, `xhci_slot_disable`,
  `xhci_configure_ep_hid`, `_xhci_transfer_ring_ep1_in` (8 KiB) +
  `_xhci_transfer_ring_ep1_in_ctx` (32 B), `xhci_transfer_enqueue_
  raw`.
  M5: `xhci_get_descriptor`, `xhci_parse_config_desc`,
  `xhci_poll_transfer_event`, `xhci_set_configuration`,
  `hid_probe_from_config`, `xhci_hid_set_boot_protocol`.
  M6: `_hid_us_keymap` (256 B) + `_hid_us_keymap_shifted` (256 B),
  `hid_translate`, `_hid_prev_report` (8 B), `_hid_kp_prefix_msg`
  (9 B), `hid_bridge_to_tty`, `hid_process_report`,
  `xhci_hotplug_handler_event`, `_xhci_hp_*_msg`,
  `xhci_keyboard_smoke_witness`, `_xhci_kbd_smoke_report` (8 B).

---

## What Worked (Round Discipline)

1. **softarch -> debugger loop shape held throughout.** Six
   milestones closed as architect+implement passes followed by
   debugger passes. Zero workerbee invocations
   (per `feedback_paideia_os_loop_shape.md`).

2. **Continuous tempo across six milestones.** Per
   `feedback_paideia_os_tempo.md`, R26 ran continuous with no
   between-milestone review pause. Six milestones closed within
   two loop days.

3. **In-round documentation of deferrals.** Every M6 module header
   calls out the R27 dependency inline — the R26 closure debt
   inventory (§Deferrals D1..D6) is a consolidation of those
   headers, not a discovery. Same discipline codified in R24 M5
   partial-close note; R25 first applied prospectively from M1;
   R26 extended into every M3..M6 module.

4. **Paper-tiger downgrades saved cross-repo churn thrice.**
   Multi-arg SysV shim / register-width sanction / byte-array
   literal density all tacked cleanly onto pre-existing encoder
   features. Zero submodule bumps across R26. Sixth consecutive
   round with zero paideia-as escalations.

5. **Placeholder-witness idiom continues as standard practice.**
   R22.M6 (`msix_ir_round_robin_witness`), R24.M6
   (`concurrent_io_witness` + `nvme_hw_smoke_witness`), R25.M5
   (`pdxfs_lite_corrupt_sb_witness`), R25.M7 (`pdxfs_lite_e2e_
   witness`), R26.M6 (`xhci_keyboard_smoke_witness`) all share the
   pattern: `.bss`-backed scratch + guard-on-substrate-availability
   + SKIP emit under `-kernel` + OK emit on live HW via GDB.

6. **Quick-commit cadence codified.** R26.M5's parallel-race with
   the #1016 debugger pass produced the "commit each file as it
   builds" rule for R26.M6 onwards. This tightens the softarch's
   context window and preserves work against parent-agent
   context-switch races. Documented in this retro §"The Parallel-
   Race Lesson".

---

## What Didn't Work

1. **Zero primitives fired at boot in R26.** Every M1..M6 symbol is
   dormant under `-kernel` and would only fire under UEFI/OVMF +
   real HW + R27 driver-attach ceremony. This is the same posture
   R24/R25 shipped with (substrate first, wire-up later) but at R26
   the surface is larger — the R27 driver-attach round is now
   carrying three rounds' worth of substrate to wire.

2. **T14 G4 first-USB-touch never happened.** Every R26 milestone
   ran under QEMU-TCG `-kernel`. The T14 first-keyboard-input
   moment stays queued for R27+ hardware bring-up alongside the
   R23 first-visual-output moment and the R24 first-NVMe-touch
   moment (none of which have fired). Zero rows promoted in
   `design/hardware/quirks.md` at this pass; §2.4 USB row is
   anchored + one new row seeded as PROVISIONAL.

3. **The parallel-race with #1016 cost roughly 30 minutes.** The
   softarch had to re-author M5 files from the baseline. Not a
   process failure — a discipline gap that got codified into a
   rule ("commit each file as it builds") for M6 onwards. Full
   post-mortem in §"The Parallel-Race Lesson" above.

4. **No opt-in `boot_r26_xhci_kbd` structural smoke landed.** R26
   planning identified this as a potential M6-close witness
   (kernel_main_uefi conditional call to
   `xhci_keyboard_smoke_witness`) but wiring in the caller behind
   `Features.XHCI_KEYBOARD_SMOKE_AT_BOOT = 1` was ruled out of
   scope — same posture as the R24 `boot_r24_concurrent_io` and
   R25 `boot_r25_pdxfs_e2e` smokes that landed as SKIP-echo
   pending future wire-up. R27 driver-attach adds the wire.

5. **HID mouse not shipped.** D5 above. The R26 planning sheet
   sequenced "keyboard first, mouse second" and mouse was
   deferred out of the round. Wayland compositor at R30+ pulls
   the mouse driver in.

---

## Preflight for R27

**R27 (Networking + xHCI driver-attach)** — opens after R26 close
per `design/roadmap/r18-plus-bare-metal.md §R27`. Draft preflight to
land as `design/round-retrospectives/r27-preflight.md` at R27.M1
kickoff.

### R27 direct scope (roadmap)

- Intel i219-LM (e1000e-family) driver.
- ARP + IP + UDP + TCP substrate.
- BPF-lite packet filter (deferred to later).

### R27 opportunistic scope — R26 debt discharge

The R27 opening also has room to discharge the R26 hotplug + IRQ +
driver-attach debt as an M0/M1 prelude:

1. **R27.M0 (optional prelude):** land the xHCI IRQ walker over the
   event ring. ~1 file, ~150 lines. Dispatches TRB Types 32 / 33 /
   34 to their respective handlers.
2. **R27.M0.5 (optional prelude):** wire the port_id -> slot_id
   ledger + extend `xhci_hotplug_handler_event` attach path to full
   `enable_slot + input_ctx + address_device + configure_ep_hid`
   chain.
3. **R27.M0.9 (optional prelude):** wire driver-attach ceremony into
   `kernel_main_uefi` behind `Features.XHCI_ATTACH_ENABLED = 1`
   (default 0 to keep `-kernel` boots side-effect-free).
4. **R27.M0.95 (optional prelude):** wire `xhci_keyboard_smoke_
   witness` into `kernel_main_uefi` behind
   `Features.XHCI_KEYBOARD_SMOKE_AT_BOOT = 1`.

If R27 scope tolerates the M0 prelude, the R26 driver-attach
first-fire lands at R27 open — probably 4-6 issues total. If R27
scope is too tight (networking is a serious substrate; R27 could
easily run 30+ issues on its direct scope), the M0 prelude moves to
R27.5 / R28 as a targeted "flush the R26 debt" sub-round.

### R26 debt items not covered by R27 M0 prelude

- **HID mouse** (D5) — R27+ HID-input round.
- **Userspace HID class driver** (#963 / D3) — R28+ per #1015 gate.
- **Live T14 keyboard capture** (D6) — pulls with (1)+(2)+(3)+(4).

Decision to defer to R27.M1 kickoff — see kickoff doc for the call.
