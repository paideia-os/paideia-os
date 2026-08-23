# AHCI Controller + Port + Dual-Kind BLKDEV Parity (R51.M5)

**Status.**  Draft v0.1 (R51.M5 planning, 2026-08-22).
**Parent.**  `design/hardware/nvme-and-disk-substrate.md`
- §3 (AHCI / SATA driver) — the master narrative for this substrate.
- §3.2 (Probe + ABAR) — HBA register bring-up sequence.
- §3.3 (MSI-X) — one shared vector per controller (contrast: NVMe = per-CPU).
- §3.4 (Port bring-up + FIS discipline) — CLB/FB, IDENTIFY DEVICE.
- §3.5 (Command list + PRDT) — descriptor shapes.
- §4.3, §4.4 (Descriptor tail, derivation graph) — dual-kind property.
- §6 (KIND ordinal allocations) — `KIND_AHCI_CONTROLLER = 0x19A`,
  `KIND_AHCI_PORT = 0x19B`; §6.2 rights bit layouts.
- §7 R51.M5 issue titles (lines 855-860) — the six R51.M5-00N tickets.

**Sibling.**  `design/hardware/nvme-io-queues.md` (R51.M3, landed) and
`design/hardware/nvme-oncs-reliability.md` (R51.M4, landed).  This M5
doc inherits their file-split rationale, per-issue ordering, and the
paideia-as encoder-caveats block; only the AHCI-specific delta is spelled
out below.

**Depends on** (all landed):

- R51.M1 — `KIND_NVME_CONTROLLER = 0x198` at
  `src/kernel/core/cap/kind_nvme_controller.pdx` (1681 lines).  The
  full analogue of the M5 controller-cap shape (mint gate, table,
  parent gate, revoke cascade).  Every §1 pattern below points at a
  named function in that file.
- R51.M2 — `KIND_NVME_NAMESPACE = 0x199` + `nvme_ns_dual_kind_mint`
  at `src/kernel/core/cap/kind_nvme_namespace.pdx` (1674 lines).  The
  full analogue of the M5 port + dual-kind mint shape.  §4 replicates
  its 6-arg `params_ptr` packing verbatim (commit `cb6291e`).
- R51.M3 — `nvme_io_queues.pdx` (`nvme_io_submit_rw`) and
  `cap_handler_blkdev.pdx` (298 lines).  §5 extends the dispatcher's
  `hblk_do_rw` block with a family byte demux; the NVMe branch is
  unchanged.
- R24 driver split at `src/kernel/core/drivers/nvme/` — the per-concern
  file shape (`regs.pdx`, `probe.pdx`, `identify_*`, `dispatch.pdx`,
  `io_queue.pdx`, `prp.pdx`, `errors.pdx`) the M5 AHCI substrate
  mirrors under `src/kernel/core/drivers/ahci/`.
- R29.M1 — `KIND_HW_INTERRUPT`, `KIND_HW_MSIX_VECTOR` + cascade revoke.
  M5 wires ONE `KIND_HW_MSIX_VECTOR` per controller (§2.3), not per
  CPU.
- R29.M5 — `KIND_DMA_DOMAIN`.  Per-port CLB + FIS receive + Command
  Table + PRDT pages are mapped through the driver's domain (§2.4).
- R35.M4 — `KIND_DMA_ATTESTATION`.  M5 mint gate for `KIND_AHCI_PORT`
  requires the same attestation-covers-this-domain check M2 already
  enforces on `KIND_NVME_NAMESPACE` (parent §5.4).
- `design/policy/output-provenance-strip.md` — runtime output MUST NOT
  carry `R51.M5-*` / `#166*` tags; the M5 witness fingerprint is
  component-named (§9).

**Scope of this doc.**  Everything R51.M5 substantiates:

- §1 NVMe-parallel structure — the pattern re-use manifest.
- §2 AHCI-specific facts — HBA + port register layout, FIS discipline,
  IDENTIFY DEVICE, PRDT, MSI-X, hot-plug posture (deferred to M6).
- §3 File layout — the split-off decision (two cap files + a
  `drivers/ahci/` split mirroring `drivers/nvme/`).
- §4 Dual-kind BLKDEV parity — the ≤6-arg mint signature and the
  `params_ptr` stack-block workaround, up-front.
- §5 BLKDEV op wire-up — family-byte demux in `cap_handler_blkdev.pdx`
  + `ahci_io_submit_rw` on the AHCI side.
- §6 Failure taxonomy — the disjoint M5 band `0xFFFFEC80..0xFFFFEC8F`.
- §7 Per-issue implementation order + dependency edges.
- §8 paideia-as encoder caveats — delta from M3/M4.
- §9 Witness plan — `KIND_AHCI OK` fingerprint.

**Out of scope for R51.M5** (deferred to M6+):
- READ_DMA_EXT / WRITE_DMA_EXT / FLUSH_CACHE_EXT wire — M6.
- Port hot-plug (PxIS.PCS + SSTS.DET debounce) — M6.
- TRIM (DATA_SET_MANAGEMENT with TRIM feature bit) — M6.
- Cross-family witness (same PdxFS mount code against NVMe + AHCI) — M7.

---

## 1. NVMe-parallel structure — the pattern re-use manifest

Every M5 shape has a landed R51.M1..M3 analogue.  The table below is
the load-bearing contract of this design: reviewers who understand
the NVMe half already understand the AHCI half up to the register
substitutions in §2.

| Concern | NVMe (landed, R51.M1..M3) | AHCI (this round, R51.M5) |
|:--------|:--------------------------|:--------------------------|
| Controller cap tag | `KIND_NVME_CONTROLLER = 0x198` over `KIND_DEVICE` (10) | `KIND_AHCI_CONTROLLER = 0x19A` over `KIND_DEVICE` (10) |
| Controller cap file | `cap/kind_nvme_controller.pdx` | `cap/kind_ahci_controller.pdx` |
| Controller row table | `_nvme_controller_table[64] u64` (8 rows × 64 B) | `_ahci_controller_table[32] u64` (4 rows × 64 B — see §2.2 for the smaller ceiling) |
| Controller mint gate | `nvme_ctrl_cap_mint_inner(parent_slot, rights, ctrl_idx, bar0_pa)` | `ahci_ctrl_cap_mint_inner(parent_slot, rights, ctrl_idx, abar_pa)` |
| Parent-derivation check | `nvme_ctrl_check_parent_pci_dev(parent_slot)` — kind == `KIND_PCI_DEV (0x30)` + `RIGHT_MINT` | `ahci_ctrl_check_parent_pci_dev(parent_slot)` — same shape, identical constants |
| PCI probe hook | `nvme_ctrl_probe_and_mint(parent_slot, rights)` iterates `_nvme_devices[..]` | `ahci_ctrl_probe_and_mint(parent_slot, rights)` iterates `_ahci_devices[..]` populated by `ahci_probe` |
| Controller state machine | MINTED → ENABLED → IDENTIFIED → NEGOTIATED | MINTED → RESET_DONE → PI_ENUMERATED (three states; §2.2) |
| Revoke cascade | `nvme_ctrl_cap_revoke` → `nvme_ns_cascade_revoke_by_ctrl` → per-NS revoke → dual-kind KIND_BLKDEV rows | `ahci_ctrl_cap_revoke` → `ahci_port_cascade_revoke_by_ctrl` → per-port revoke → dual-kind KIND_BLKDEV rows |
| Port / namespace cap tag | `KIND_NVME_NAMESPACE = 0x199` over `KIND_MEMORY` (4) | `KIND_AHCI_PORT = 0x19B` over `KIND_MEMORY` (4) |
| Port / namespace cap file | `cap/kind_nvme_namespace.pdx` | `cap/kind_ahci_port.pdx` |
| Port row table | `_nvme_namespace_table[256] u64` (32 rows × 64 B) | `_ahci_port_table[256] u64` (32 rows × 64 B — 32 ports per controller matches AHCI 1.3 §3.1 CAP.NP field width) |
| Dual-kind mint | `nvme_ns_dual_kind_mint(ns_slot, blk_slot, parent_slot, ns_rights, blk_rights, params_ptr)` — 6 args, `params_ptr` packs `{nsid, lba_size, block_count, parent_ctrl_row}` | `ahci_port_dual_kind_mint(port_slot, blk_slot, parent_slot, port_rights, blk_rights, params_ptr)` — same shape, `params_ptr` packs `{port_index, sector_size, block_count, parent_ctrl_row}`; §4 details |
| Family byte in row | `NVMEN_FAMILY_NVME = 1` stamped in row `[+32]` bits [23:16] | `AHCIP_FAMILY_AHCI = 2` stamped in row `[+32]` bits [23:16] |
| BDEV op dispatcher | `cap_handler_blkdev` reads `nvme_ns_row_*` accessors, calls `nvme_io_submit_rw` | Same handler extended to demux on family byte from KIND_BLKDEV descriptor's `target_ptr` bits [23:16] (§5); AHCI branch calls `ahci_port_row_*` + `ahci_io_submit_rw` |
| Bring-up (per-row) | `nvme_ctrl_bring_up(row_id)` runs `nvme_admin_queue_init` + `nvme_reset` | `ahci_port_bring_up(row_id)` runs `ahci_port_idle` (clear ST/FRE) + CLB/FB alloc + FRE/ST + SIG read + IDENTIFY DEVICE |
| IDENTIFY (post-bring-up) | `nvme_identify_ctrl` (opcode 0x06 CNS=0x01) at controller row; `nvme_identify_ns` (CNS=0x00) at each NSID | `ahci_identify_device` (ATA opcode 0xEC via H2D Register FIS) at each port — populates sector_size / LBA48 / block_count into `_ahci_identify_scratch` fields the port mint reads |
| Failure taxonomy band | `KIND_NVME_CONTROLLER = 0xFFFFEC40..0xFFFFEC4F`; `KIND_NVME_NAMESPACE = 0xFFFFEC50..0xFFFFEC5F` | `KIND_AHCI = 0xFFFFEC80..0xFFFFEC8F` (§6) — one band covers both controller and port because M5 does not need >16 codes |
| MSI-X wiring | Per-CPU `KIND_HW_MSIX_VECTOR` (R51.M3) | ONE shared `KIND_HW_MSIX_VECTOR` per controller (parent §3.3); M5 lands the allocation, M6 wires the IRQ drain |
| Witness | `NVME_CTRL OK` + `NVME_NS OK` fingerprints, no `R` prefix | `KIND_AHCI OK` fingerprint (§9), no `R` prefix |

Reviewers looking for a specific NVMe pattern's AHCI counterpart:
grep `nvme_ctrl_` and substitute `ahci_ctrl_`; grep `nvme_ns_` and
substitute `ahci_port_`; grep `_nvme_controller_table` and substitute
`_ahci_controller_table`; grep `_nvme_namespace_table` and substitute
`_ahci_port_table`.  The eight patterns above cover every mechanical
substitution.  The genuinely different pieces — HBA register layout,
FIS discipline, IDENTIFY DEVICE parsing, PRDT — are §2's subject.

---

## 2. AHCI-specific facts

Everything below is spec-mechanical: Intel AHCI 1.3.1 + SATA-IO 3.5.
Section numbers refer to Intel AHCI 1.3.1 unless noted.

### 2.1 HBA register layout (BAR5 = ABAR)

The AHCI PCI function's BAR5 (32-bit) or BAR5/BAR6 pair (64-bit MEM
BAR) names the HBA MMIO window.  `ahci_probe` (§3) captures it as
`abar_pa` in `_ahci_devices[i]`.

Generic Host Control (offsets from `abar_pa`):

| Offset | Name | Width | Purpose (M5 read set) |
|:-------|:-----|:------|:----------------------|
| 0x00 | CAP     | u32 | HBA capabilities: NP (bits [4:0], # ports), NCS (bits [12:8], # command slots), S64A (bit 31, 64-bit addressing), SNCQ (bit 30, NCQ support) |
| 0x04 | GHC     | u32 | Global HBA Control: AE (bit 31, AHCI enable), IE (bit 1, global IRQ enable), MRSM (bit 2, MSI revert), HR (bit 0, HBA reset) |
| 0x08 | IS      | u32 | Interrupt Status — bit N set = port N raised (M6 IRQ path) |
| 0x0C | PI      | u32 | Ports Implemented — bitmask of live port indices |
| 0x10 | VS      | u32 | Version (informational) |
| 0x14 | CCC_CTL | u32 | Command Completion Coalescing (unused at R51) |
| 0x18 | CCC_PORTS | u32 | (unused at R51) |
| 0x1C | EM_LOC  | u32 | Enclosure Management (unused at R51) |
| 0x20 | EM_CTL  | u32 | (unused at R51) |
| 0x24 | CAP2    | u32 | (unused at R51) |
| 0x28 | BOHC    | u32 | BIOS/OS Handoff (M5-003 reads to check ownership, but does not race a BIOS handoff — M5 targets OVMF / no-BIOS boot) |

Per-port register block starts at `abar_pa + 0x100 + 0x80 * port_index`:

| Offset (from port base) | Name | Width | M5 use |
|:------------------------|:-----|:------|:-------|
| 0x00 | CLB / CLBU | u64 (or u32/u32) | Command List Base (256 B aligned, 1 KiB region: 32 command headers × 32 B) — M5-005 writes |
| 0x08 | FB  / FBU  | u64 | Received-FIS Base (256 B, per-FIS slots) — M5-005 writes |
| 0x10 | IS   | u32 | Port interrupt status — M6 IRQ drain reads |
| 0x14 | IE   | u32 | Port interrupt enable — M5-005 sets DHRE (D2H Register FIS receipt), M6 enables SDBE + PSE |
| 0x18 | CMD  | u32 | ST (start), FRE (FIS receive enable), FR/CR (status), POD/SUD (power/spin-up) — M5-005 sequences |
| 0x20 | TFD  | u32 | Task File Data — BSY (bit 7) + DRQ (bit 3) must both be clear before commanding |
| 0x24 | SIG  | u32 | Device signature (0x00000101 = SATA disk; §2.2) |
| 0x28 | SSTS | u32 | SATA status — DET (bits [3:0]) — DET=3 means "device present, phy established" |
| 0x2C | SCTL | u32 | SATA control (M6 hot-plug debounce) |
| 0x30 | SERR | u32 | SATA error — write-1-to-clear |
| 0x38 | CI   | u32 | Command Issue — bit N = command slot N pending |

The M5 read/write shape uses `abar_reg_u32(abar_pa, off) -> u32` and
`abar_reg_u32_set(abar_pa, off, val)` accessors (mirror
`drivers/nvme/regs.pdx`'s `nvme_reg_u32`).  For 64-bit fields
(CLB+CLBU, FB+FBU) the two 32-bit stores are ordered `lo` then `hi`
per AHCI 1.3 §3.3.2 to avoid a mid-write transient pointing to the
wrong page.

### 2.2 Controller bring-up + state machine

Per parent §3.2:

1. Read `CAP` — extract NP (bits [4:0], number of ports supported).
   The `_ahci_controller_table` row's `port_map` slot stashes `PI` and
   NP for the M5-003 enumeration walk.
2. Ensure ownership: read `BOHC`; if `OOS` bit set (BIOS still owns)
   set `OOC` and poll `BOS` to clear.  Under OVMF this is a no-op.
   (BIOS-handoff race is deferred to a future ROM support round; the
   M5 posture is "OVMF or no legacy ROM".)
3. `GHC.AE = 1` — enable AHCI mode (legacy IDE emulation off).
4. `GHC.HR = 1` — HBA reset.  Poll `GHC.HR == 0` with a bounded TSC
   deadline (parent §3.2 gives no timeout; adopt 1 s conservatively).
5. Re-set `GHC.AE = 1` (HR cleared it).
6. Read `PI` — iterate over set bits; each set bit is a port index in
   [0, NP).

The controller state machine has three states (not four like NVMe):

- `AHCIC_STATE_MINTED = 1` — row alive, HBA not touched.
- `AHCIC_STATE_RESET_DONE = 2` — steps 1-5 complete; `GHC.AE=1`,
  `GHC.HR` cleared.
- `AHCIC_STATE_PI_ENUMERATED = 3` — step 6 complete; `port_map`
  stashed.

Monotonic advancement enforced by `ahci_ctrl_row_state_set(row_id,
new_state)`, same shape as `nvme_ctrl_row_state_set`.

**Slot ceiling.**  `AHCIC_MAX = 4` matches parent §6 (§4.1 caveat).  A
fifth AHCI HBA on one machine exceeds every consumer + workstation to
date; a workstation target that hits it bumps `AHCIC_MAX` under the
R48b substrate-prep discipline (parent §10 open question 4).

### 2.3 MSI-X allocation posture

AHCI 1.3 §5.6.4 gives an HBA ONE MSI-X vector shared across all
ports (contrast: NVMe = one per queue = one per CPU).  M5 lands the
allocation:

- The controller mint gate accepts a `parent_msix_vec_slot` argument
  (the parent `KIND_HW_MSIX_VECTOR` already minted via
  `msix_cap_mint` from `KIND_HW_INTERRUPT`), stores its slot in the
  controller row `[+48]`, and refuses if the parent kind is wrong.
- M6 (deferred) wires the IRQ handler: on wake, read `IS`; iterate set
  bits; per port with `PxIS` non-zero, drain completed slots via
  `CI ^ ~PxCI_last_seen`.

The M5 slot in the controller row is populated but not yet consumed;
the same "dormant at BIOS boot" posture as `nvme_ctrl_bring_up` (M1
close) — no IRQ traffic until M6.

### 2.4 Per-port DMA memory layout

Every populated port needs four DMA-coherent allocations, all mapped
into the driver's `KIND_DMA_DOMAIN` (parent §5.2):

| Region | Size | Alignment | Contents |
|:-------|:-----|:----------|:---------|
| Command List | 1024 B | 256 B | 32 command headers × 32 B (AHCI 1.3 §4.2.2) |
| FIS Receive Area | 256 B | 256 B | D2H Register FIS (0x40), PIO Setup FIS (0x20), DMA Setup FIS (0x1C), etc. — device-written |
| Command Table (one per used slot; M5 needs 1) | 128 B + PRDT | 128 B | Command FIS (≤64 B) + ATAPI (16 B, unused) + PRDT (variable) |
| PRDT (embedded in Command Table) | 16 B × entries | 4 B (within CT) | Per parent §3.5: DBA/DBAU (data base, 2 B aligned), reserved, DBC[21:0] + I bit |

M5 uses ONE Command Table per port (slot 0), sized for the largest
M5-time transfer — IDENTIFY DEVICE returns 512 B, single PRD entry.
M6 grows the table array to 32 entries per port + on-demand PRDT
expansion for real R/W traffic.

Allocation strategy at M5: per-port `_ahci_port_dma_ctx[port_row]`
holds four contiguous pages carved from a driver-process page pool
mapped into `KIND_DMA_DOMAIN` at driver-init (same posture as
`_nvme_admin_ctx`).  The pool is bounded by `AHCIC_MAX * 32` (max
possible port count) — 128 slots × 4 pages = 512 pages = 2 MiB worst
case, well within the driver-process budget.

### 2.5 FIS discipline

The four FIS types M5 sees (parent §3.4):

- `0x27` H2D Register FIS — the *command carrier*.  M5 emits it for
  IDENTIFY DEVICE (opcode 0xEC).  Layout (20 B):
  ```
  +0  u8  fis_type = 0x27
  +1  u8  pmport[3:0] | C[7]=1 (C=command bit)
  +2  u8  command       (0xEC for IDENTIFY DEVICE)
  +3  u8  features_lo   (0)
  +4  u8  lba0          (0)
  +5  u8  lba1          (0)
  +6  u8  lba2          (0)
  +7  u8  device        (0 for IDENTIFY DEVICE)
  +8  u8  lba3          (0)
  +9  u8  lba4          (0)
  +10 u8  lba5          (0)
  +11 u8  features_hi   (0)
  +12 u16 count         (0)
  +14 u8  icc           (0)
  +15 u8  control       (0)
  +16 u32 reserved      (0)
  ```
- `0x34` D2H Register FIS — the *completion carrier*.  Device writes
  into the port's FIS receive area at offset `0x40`.  M5 reads
  `status` (byte at receive-area + 0x42) to confirm success (bit 0
  ERR clear, bit 7 BSY clear).
- `0x5F` PIO Setup FIS — precedes an IDENTIFY DEVICE data phase.
  Device writes into receive area at `0x20`.  M5 ignores its contents
  (the data buffer address is what M5 supplied via PRDT).
- `0x39` Set Device Bits — status/error surface on completion.  M6
  hot-plug path reads.

M5 emits `0x27` only.  M6 will need a `0x27` builder for
READ_DMA_EXT / WRITE_DMA_EXT / FLUSH_CACHE_EXT; the M5 builder is
factored to accept `(command_opcode, lba48, count, device_byte)`
tuples so M6 reuses the same builder.

### 2.6 IDENTIFY DEVICE parsing

The 512-byte IDENTIFY DEVICE response yields (SATA-IO 3.5 §7.16):

- Word 60/61: LBA28 total sectors (u32; deprecated for M5's LBA48
  targets but read as a floor).
- Word 83: bit 10 = LBA48 supported.  M5 asserts this bit is set
  (target hardware / QEMU AHCI defaults enable LBA48); refuses the
  mint with `AHCIP_MINT_NO_LBA48` otherwise.
- Word 100..103: LBA48 total sectors (u64).
- Word 106: bit 12 = "logical sector larger than 512 B" flag; if
  clear, sector size is 512 B.  If set, word 117..118 gives sector
  size in u16 words (multiply by 2 for bytes).
- Word 169: bit 0 = DRAT (Deterministic Read After TRIM).  M5 stashes
  but does not act on it; M6 gates TRIM on this bit.

The parsed `(sector_size, block_count)` pair goes into `params_ptr`
for `ahci_port_dual_kind_mint` (§4).

---

## 3. File layout

Two new cap files + a small `drivers/ahci/` split-off, mirroring the
R24 `drivers/nvme/` shape.  No in-place growth on any existing file
beyond the surgical additions to `cap_handler_blkdev.pdx` (§5).

| New file | Ownership | Approx size |
|:---------|:----------|:------------|
| `src/kernel/core/cap/kind_ahci_controller.pdx` | Controller cap: `KIND_AHCI_CONTROLLER = 0x19A`, `_ahci_controller_table`, mint gate + probe hook + revoke cascade + row accessors + state machine.  Analogue: `kind_nvme_controller.pdx` (1681 lines). | ~1400 lines |
| `src/kernel/core/cap/kind_ahci_port.pdx` | Port cap: `KIND_AHCI_PORT = 0x19B`, `_ahci_port_table`, mint gate + dual-kind mint + row accessors.  Analogue: `kind_nvme_namespace.pdx` (1674 lines). | ~1500 lines |
| `src/kernel/core/drivers/ahci/regs.pdx` | ABAR accessors + per-port register offset math + CAP/GHC/PI/IS/CMD/TFD/SIG/SSTS/CI helpers.  Analogue: `drivers/nvme/regs.pdx` (~200 lines). | ~200 lines |
| `src/kernel/core/drivers/ahci/probe.pdx` | PCI walk (class 01 / subclass 06 / prog-if 01), populates `_ahci_devices[4]` records `{seg, bus, dev, fn, abar_pa, cap_msix_off, port_count_hint}`.  Analogue: `drivers/nvme/probe.pdx` (~200 lines). | ~200 lines |
| `src/kernel/core/drivers/ahci/reset.pdx` | HBA reset sequence (BOHC observe, GHC.AE, GHC.HR, PI read).  M5-003 body. | ~150 lines |
| `src/kernel/core/drivers/ahci/port.pdx` | Per-port CLB/FB allocation via `KIND_DMA_DOMAIN`, FRE/ST idle-then-start sequence, SIG read.  M5-005 body (partial). | ~250 lines |
| `src/kernel/core/drivers/ahci/fis.pdx` | H2D Register FIS builder (`ahci_fis_h2d_build(buf, cmd_op, lba48, count, device)`); D2H completion reader.  M5-005 uses; M6 grows for R/W. | ~150 lines |
| `src/kernel/core/drivers/ahci/identify.pdx` | Submit IDENTIFY DEVICE (opcode 0xEC) through slot 0; parse response into scratch `{sector_size, block_count, lba48_ok, drat}`.  M5-005 body (remainder). | ~250 lines |
| `src/kernel/core/drivers/ahci/errors.pdx` | Status-byte decode + typed error names.  Small; keeps the driver file clean. | ~80 lines |

`drivers/ahci/submit.pdx` (the M6 analogue of `nvme_io_queues.pdx`'s
`nvme_io_submit_rw`) is **not** landed at M5.  M6 opens it and adds
`ahci_io_submit_rw` on top of the M5 CLB + PRDT scaffolding.

**Inline vs split rationale.**  Same as parent §3.1 for the NVMe half
and `design/hardware/nvme-io-queues.md` §1: keeping each concern near
150-250 lines lets the god-file-refactor directive (user memory,
2026-08-11) apply without follow-up work.  The two cap files stay
large because the NVMe analogues set the shape and matching their
per-file scope prevents accidental drift between the two families.

**Files touched at R51.M5 close:**

| File | Change | Reason |
|:-----|:-------|:-------|
| `src/kernel/core/cap/kind_ahci_controller.pdx` | NEW | M5-001, M5-002, M5-003. |
| `src/kernel/core/cap/kind_ahci_port.pdx` | NEW | M5-004, M5-005, M5-006. |
| `src/kernel/core/drivers/ahci/*.pdx` | NEW (7 files) | HBA + port bring-up + FIS + IDENTIFY. |
| `src/kernel/core/cap/cap_handler_blkdev.pdx` | +~80 lines | Family-byte demux at the top of `hblk_do_rw` (§5); NVMe branch untouched. |
| `src/kernel/core/cap/blkdev_cap.pdx` | 0 (defer to M6/M7) | Rights extension + family-widening are M4-era decisions; M5 stays inside R24 rights envelope. |
| `src/kernel/core/klog/file_ids.pdx` | +9 rows | FILE_ID assignments for the nine new files. |
| `src/kernel/boot/witness/*.pdx` | +1 witness call | `KIND_AHCI OK` fingerprint (§9). |

---

## 4. Dual-kind BLKDEV parity — the ≤6-arg mint

**Critical constraint.**  paideia-as caps lambda arity at 6 SysV-
register args (issue P0276, applied in commit `cb6291e` to fix
`nvme_ns_dual_kind_mint`'s original 9-arg signature).  The AHCI
dual-kind mint MUST NOT exceed 6 args; §4 designs it to fit exactly
without needing a further reduction pass.

### 4.1 Signature

```
ahci_port_dual_kind_mint : (u64, u64, u64, u64, u64, u64) -> u64 !{mem, sysreg} @{cap}
  fn (port_slot: u64)     -- KIND_AHCI_PORT descriptor slot to write
     (blk_slot:  u64)     -- KIND_BLKDEV descriptor slot to write (same row)
     (parent_slot: u64)   -- KIND_AHCI_CONTROLLER descriptor slot (with R_AHCIC_MINT_PORT)
     (port_rights: u64)   -- rights for the KIND_AHCI_PORT descriptor
     (blk_rights:  u64)   -- rights for the KIND_BLKDEV descriptor
     (params_ptr:  u64)   -- pointer to caller-owned 32 B / 4 u64 block
```

**Exactly 6 args**, matching `nvme_ns_dual_kind_mint`'s post-P0276
signature word-for-word up to naming.

### 4.2 `params_ptr` layout

Caller-owned 32-byte stack block, four u64 words:

| Offset | Field | Notes |
|:-------|:------|:------|
| 0  | `port_index`      | AHCI port index (0..31) from PI enumeration |
| 8  | `sector_size`     | Bytes per logical sector, from IDENTIFY DEVICE (typ. 512) |
| 16 | `block_count`     | LBA48 total sectors, from IDENTIFY DEVICE words 100..103 |
| 24 | `parent_ctrl_row` | `_ahci_controller_table` row_id (0..AHCIC_MAX-1) |

Callers build it on their own stack (identical pattern to the NVMe
caller):

```
    sub rsp, 32
    mov [rsp + 0],  <port_index>
    mov [rsp + 8],  <sector_size>
    mov [rsp + 16], <block_count>
    mov [rsp + 24], <parent_ctrl_row>
    mov r9, rsp              ; params_ptr
    call ahci_port_dual_kind_mint
    add rsp, 32
```

The callee reads `[rbx + 0/8/16/24]` and never retains the pointer
past the call.  This exactly mirrors `nvme_ns_dual_kind_mint`'s
`params_ptr` handling — same stack shape, same register plan (`rbx =
params_ptr` in the 6-push callee-save prologue).

### 4.3 Why the pack is 4 words, not more

Every AHCI-port row field the mint must set is either in `params_ptr`
or derivable from the parent chain:

- `port_index`, `sector_size`, `block_count`, `parent_ctrl_row`:
  packed in `params_ptr` (4 words).
- `family` (= `AHCIP_FAMILY_AHCI = 2`): compile-time constant,
  stamped without a caller arg.
- `features` (bit 0 FLUSH, bit 1 TRIM, bit 2 WRITE_ZEROES, bit 3
  WCP): all zero at M5 (M6 sets FLUSH; TRIM gated on DRAT which M6
  reads from `_ahci_identify_scratch`).
- `attest_key`: read from the `parent_slot`'s inherited attestation
  through the descriptor chain, same shape as NVMe.  No extra arg.
- `ns_slot` header equivalent (`port_slot` byte): assigned = row_id
  at mint, same as `nvme_ns_dual_kind_mint`.

If M6 adds a field that ISN'T derivable, extend the `params_ptr`
block to 5 words (40 B) — a stack-block extension is source-local and
does not touch the signature.  The signature stays at 6 args
indefinitely.

### 4.4 Register plan + prologue alignment

Six callee-save pushes + `sub rsp, 8` = 56 B; entry `rsp%16 == 8` →
post-prologue `rsp%16 == 0` for every nested call.  Identical to
`nvme_ns_dual_kind_mint`.

```
port_slot        -> r12
blk_slot         -> r13
parent_slot      -> r14
port_rights      -> r15
blk_rights       -> rbp
params_ptr       -> rbx
```

### 4.5 KIND_BLKDEV descriptor extension for family demux

M5-006 stamps the KIND_BLKDEV descriptor's `target_ptr` with the
family byte encoded in the *upper* bits, so `cap_handler_blkdev` can
demux without a separate table:

```
target_ptr bits [15:0]  = row_id (unchanged from R51.M2/M3)
target_ptr bits [23:16] = family byte (0 = LEGACY_NVME, 1 = NVME,
                                       2 = AHCI)
target_ptr bits [63:24] = reserved (must be zero)
```

**Backward compatibility.**  The M2 dual-kind mint stamps
`target_ptr` with `row_id` and upper bits zero — this reads as
`family = 0 = LEGACY_NVME` under the new demux.  §5 treats family 0
AND family 1 both as the NVMe branch, so M2/M3 callers work unchanged
with no M2 code edit.  M5-006 is the FIRST mint that ever stamps a
non-zero family byte (= 2 AHCI); the demux is exercised for the first
time on that path.

An alternative — patching `nvme_ns_dual_kind_mint` to stamp
family=1 into the descriptor bits — is source-clean but adds an edit
to a landed R51.M2 file for zero behavioral benefit.  Skip; treat 0
and 1 as equivalent in the handler.

---

## 5. BLKDEV op wire-up — family-byte demux in cap_handler_blkdev

### 5.1 What changes in `cap_handler_blkdev.pdx`

Today `cap_handler_blkdev`'s `hblk_do_rw` block hard-codes the NVMe
path: `nvme_ns_row_parent` → `nvme_io_submit_rw`.  M5 inserts a
family-byte demux at the *top* of the handler (before any per-op
work), stashes the family in a callee-save register, and branches on
it inside `hblk_do_rw` (and inside the QUERY_FAMILY / QUERY_FEATURES
/ QUERY_GEOM ops that read row fields).

### 5.2 Demux design

At handler entry the SysV convention is `rdi=rights, rsi=target_ptr,
rdx=op_arg`.  The current handler pulls `target_ptr & 0xFFFF` into
`rbp` (row_id) and forgets the upper bits.  M5 pulls the same
row_id AND the family byte:

```
mov rbp, rsi                  ; target_ptr full
mov r10, rbp
and r10, 0xFFFF               ; r10 = row_id
mov r11, rbp
shr r11, 16
and r11, 0xFF                 ; r11 = family byte

; Reserved-bits gate: family in {0, 1, 2}; anything else refuses.
cmp r11, 2
ja  hblk_bad_family
; Upper bits [63:24] must be zero.
mov rax, rbp
shr rax, 24
cmp rax, 0
jne hblk_bad_family

; Stash family in a callee-save (rbx already carries rights; reuse
; the existing 5-push shape and repurpose one slot for family, or
; add a 6th push).  See §5.3 register plan.
```

Family maps to a *branch label* per op-body, chosen with one compare:

```
cmp r11, 2                    ; AHCI?
je  hblk_ns_row_is_ahci
; else NVMe (0 = LEGACY_NVME or 1 = NVME)
```

`hblk_op_family` (BDEV_OP_QUERY_FAMILY) returns `r11` directly (no
row access needed) — a one-line simplification over the current
`nvme_ns_row_family(rbp)` call.

`hblk_op_geom` splits:
- family in {0, 1}: `nvme_ns_row_lba_size(rbp)` + `nvme_ns_row_block_count(rbp)`
- family == 2:      `ahci_port_row_sector_size(rbp)` + `ahci_port_row_block_count(rbp)`

`hblk_do_rw` splits at the `nvme_ns_row_parent`/`nvme_io_submit_rw`
tail:
- family in {0, 1}: current path (NVMe), unchanged.
- family == 2:
  ```
  mov rdi, rbp
  call ahci_port_row_parent        ; -> ctrl_row_id
  ; ... same lba/nblocks/dma_iova unpack ...
  call ahci_io_submit_rw           ; symmetric to nvme_io_submit_rw
  ```
  `ahci_io_submit_rw(ctrl_row, port_row, opcode, lba, nblocks,
  dma_iova)` is the M6 primitive; at M5 close it is a `ret 0xEEEE`
  stub so the family-demux compiles and the NVMe path stays live.

### 5.3 Register plan for the extended handler

Existing 5-push (rbx, r12, r13, r14, rbp) → extended to 6-push
(add r15 to carry `family` across nested calls).  Prologue: 48 B →
alignment recomputation matches the same 5-push pad shape (entry
%16==8 → 48+8 == 56 → sub rsp,8 → 64 → %16==0).  Same discipline as
every landed cap-dispatch handler.

### 5.4 Failure paths

New error code:

- `BDEV_ERR_BAD_FAMILY = 0xFFFFEC63` (extends the existing
  `BDEV_ERR_*` band `0xFFFFEC60..0xFFFFEC6F`; positions
  `0xFFFFEC60`/`61`/`62` are already `BAD_ARG` / `UNSUPPORTED` /
  `BAD_ROW`).  Returned when the target_ptr family byte is out of
  range OR reserved bits are set.

Every other error path from the NVMe branch is unchanged; the AHCI
branch synthesises the same shape (AHCI_IO_STATE_BAD /
AHCI_IO_SUBMIT_TIMEOUT / AHCI_IO_SUBMIT_TFERR — all in the M6 band).
At M5 close, `ahci_io_submit_rw` returns `0xEEEE` unconditionally;
the handler forwards it as a `BDEV_ERR_*` alias per the same sentinel
pattern the NVMe branch uses today.

### 5.5 Why not a per-family handler table

Alternative: one `cap_handler_blkdev_nvme` + one `cap_handler_blkdev_ahci`,
selected by `cap_invoke_dispatch` via a family-tag mint slot.  This
requires changing `cap_invoke_dispatch` to look up handler by
(kind, family) instead of (kind), and to teach the mint gate to
stamp a family-scoped variant kind.  Larger surgery; two dispatcher
paths whose only difference is a one-branch demux.  Skip.

The chosen design keeps ONE handler for `KIND_BLKDEV`, matching the
"opaque about medium" invariant parent §4.5 promises the FS layer.

---

## 6. Failure taxonomy — the M5 band

Sixteen codes at `0xFFFFEC80..0xFFFFEC8F`, disjoint from every
landed band (`0xFFFFEC00..0xFFFFEC7F` fully allocated by R48b →
R51.M4).  M6 will claim `0xFFFFEC90..0xFFFFEC9F` (I/O submit +
TFERR + hot-plug); M7 leaves the next open band to softarch.

Proposed allocation (both `KIND_AHCI_CONTROLLER` and
`KIND_AHCI_PORT` share this band; 16 codes are enough for both
because M5 is smaller than M2 in error-path surface):

```
AHCIC_TAIL_ENOSPC       0xFFFFEC8F
AHCIC_TAIL_BAD_ARG      0xFFFFEC8E
AHCIC_MINT_BAD_PARENT   0xFFFFEC8D
AHCIC_MINT_BAD_RIGHTS   0xFFFFEC8C
AHCIC_MINT_BAD_IDX      0xFFFFEC8B
AHCIC_MINT_BAD_ABAR     0xFFFFEC8A
AHCIC_BAD_SLOT          0xFFFFEC89
AHCIC_WRONG_KIND        0xFFFFEC88
AHCIC_REVOKE_ALREADY    0xFFFFEC87
AHCIC_RESET_TIMEOUT     0xFFFFEC86     -- GHC.HR did not clear
AHCIC_BAD_TRANSITION    0xFFFFEC85

AHCIP_MINT_BAD_PARENT   0xFFFFEC84
AHCIP_MINT_BAD_PORT     0xFFFFEC83     -- port_index >= 32 or !PI-set
AHCIP_MINT_NO_LBA48     0xFFFFEC82     -- IDENTIFY word 83 bit 10 clear
AHCIP_MINT_BAD_SIG      0xFFFFEC81     -- SIG != 0x00000101 (not ATA)
AHCIP_DUAL_BAD_SLOTS    0xFFFFEC80
```

**Overflow to a second band.**  If M5 discovers it needs more than
16 codes (unlikely — the M1 controller cap used 14 of its 16
allocation), spill to `0xFFFFEC90..EC9F` and defer M6 to
`0xFFFFECA0..ECAF`.  Track in the file header.

Add one code to the existing `BDEV_ERR_*` band (§5.4):

```
BDEV_ERR_BAD_FAMILY     0xFFFFEC63     -- descriptor family byte OOR
```

---

## 7. Per-issue implementation order

The recommended order is `#1657 → #1658 → #1659 → #1660 → #1661 →
#1662`.  Dependency edges are strict but shallow: each issue extends
the previous one's row / mint / bring-up shape.  Parallelism inside
the milestone is minimal — the substrate is small enough that
serialising the six issues keeps blast-radius per commit tight and
lets each commit's build be the incremental verifier for the next.

### #1657 R51.M5-001 — KIND_AHCI_CONTROLLER mint gate + table

Needs: nothing new — R51.M1 shape + parent §6.  Blocks: every M5
issue.

Lands: `src/kernel/core/cap/kind_ahci_controller.pdx` with the
mint gate (`ahci_ctrl_cap_mint_inner`), row table
(`_ahci_controller_table[32]` — 4 rows × 64 B), state machine (three
states), row accessors, revoke primitive (cascade stub — M5-004
widens), stats, header + failure-taxonomy band claim, ops
(QUERY_ABAR / QUERY_STATE / QUERY_PORT_MAP / QUERY_CTRL_IDX +
DEBUG_PRINT).  Rights: `R_AHCIC_MMIO | R_AHCIC_RESET |
R_AHCIC_ENUM_PORTS | R_AHCIC_MINT_PORT = 0x0F` (per parent §6.2)
extended with `R_AHCIC_INVOKE = 0x008`, `R_AHCIC_REVOKE = 0x010`,
`R_AHCIC_OBSERVE = 0x400`, `R_AHCIC_ALL = 0x41F`.

Debugger hint on failure: (a) verify `AHCIC_MAX = 4` matches the
row-table sizing (32 u64 = 4 rows × 8 words); (b) verify no
overlap in the failure-taxonomy band with landed codes; (c) verify
the parent-derivation gate reads `KIND_PCI_DEV (0x30)` and
`RIGHT_MINT (0x200)` — same constants as
`nvme_ctrl_check_parent_pci_dev`.

### #1658 R51.M5-002 — PCI probe hook

Needs: #1657 (mint) + a new `drivers/ahci/probe.pdx` producing
`_ahci_devices[4]`.

Lands: `drivers/ahci/probe.pdx` (class 01/subclass 06/prog-if 01
walk, populates `_ahci_devices[i]` records with `{seg, bus, dev,
fn, abar_pa, cap_msix_off}` — mirror `nvme/probe.pdx` layout with
BAR5 read instead of BAR0), and adds `ahci_ctrl_probe_and_mint` to
`kind_ahci_controller.pdx` — iterates `_ahci_devices[0.._ahci_device_count)`,
calls `ahci_ctrl_cap_mint_inner(parent_slot, rights, i, abar_pa)`
per record.

Under BIOS/`-kernel` boot no controller exists (`_ahci_device_count
== 0`), same dormant posture as R24 NVMe probe.

Debugger hint: (a) PCI class/subclass/prog-if constants match Intel
AHCI 1.3.1 §2.2; (b) BAR5 offset in PCI config space is 0x24 (five
BARs of 4 B each starting at 0x10); (c) `_ahci_device_count` is
staged into r14 as a cached u64 read once at loop head, same shape
as `_nvme_device_count` in `nvme_ctrl_probe_and_mint`.

### #1659 R51.M5-003 — AHCI HBA reset + PI enumeration

Needs: #1658 (row minted with `abar_pa`).

Lands: `drivers/ahci/regs.pdx` + `drivers/ahci/reset.pdx`.
`ahci_hba_reset(abar_pa) -> u64` implements §2.2 steps 1-5 with a
1 s TSC-bounded HR-clear poll; `ahci_pi_enumerate(abar_pa) ->
port_map:u32` reads PI.  `ahci_ctrl_bring_up(row_id)` calls both,
stashes `port_map` into row `[+40]`, advances state
MINTED → RESET_DONE → PI_ENUMERATED.

Debugger hint: (a) GHC bit numbers per §2.1 — AE=31, IE=1, HR=0;
(b) BOHC bit numbers — OOS=bit 0, BOS=bit 4, SOOE=bit 3; (c) the HR
timeout is 1 s (bounded by TSC per R21 discipline); (d) advertised
NP in CAP is 0-based (NP+1 = actual port count) — the M5-003 walker
must add 1.

### #1660 R51.M5-004 — KIND_AHCI_PORT mint gate + table

Needs: #1657 (controller cap parent-check target).

Lands: `src/kernel/core/cap/kind_ahci_port.pdx` with mint gate
(`ahci_port_cap_mint_inner`), row table (`_ahci_port_table[256]` —
32 rows × 64 B; matches parent §7 M5-004 sizing), state machine
(two states MINTED / IDENTIFIED — same shape as
`kind_nvme_namespace`), row accessors (`ahci_port_row_port_index /
_sector_size / _block_count / _parent_ctrl_row / _family / _state`),
revoke primitive with cascade stub (M5-006 stamps the cascade), meta
packer (mirror `nvme_ns_tail_pack_meta` with family=AHCI baked in),
rights (`R_AHCIP_MINT_BLK / _ATTACH / _DETACH / _INVOKE / _REVOKE /
_OBSERVE / _ALL = 0x41F`), ops (QUERY_PORT_INDEX / _SECTOR_SIZE /
_BLOCK_COUNT / _PARENT / _FAMILY / _STATE / _PORT_SLOT + DEBUG_PRINT).

Parent-derivation gate: `KIND_AHCI_CONTROLLER (0x19A)` + rights &
`R_AHCIC_MINT_PORT (0x008)` — NOT `RIGHT_MINT (0x200)` — because
the port-mint authority is a first-class right on the controller cap
(same shape as `R_NVMEC_MINT_NS` for M2).

Debugger hint: (a) failure taxonomy — `AHCIP_MINT_BAD_PARENT =
0xFFFFEC84`; (b) meta word layout matches
`nvme_ns_tail_pack_meta` (parent_ctrl_row[15:0] |
family[23:16] | features[31:24]) — different offsets from
`kind_nvme_controller`'s state-in-[15:8] header shape; (c) family
byte is `AHCIP_FAMILY_AHCI = 2` (matches `NVMEN_FAMILY_AHCI = 2`
already defined in `kind_nvme_namespace.pdx`).

### #1661 R51.M5-005 — Per-port bring-up + IDENTIFY DEVICE

Needs: #1659 (`ahci_ctrl_bring_up` produces `port_map` for iteration)
and #1660 (row table for later mint).

Lands: `drivers/ahci/port.pdx` + `drivers/ahci/fis.pdx` +
`drivers/ahci/identify.pdx`.

- `ahci_port_idle(abar_pa, port_index)`: clear `CMD.ST`, wait
  `CMD.CR == 0`; clear `CMD.FRE`, wait `CMD.FR == 0`.  Bounded
  polls (100 ms each).
- `ahci_port_alloc_dma(row_id) -> u64` (via `KIND_DMA_DOMAIN`):
  allocate CLB (1 KiB), FIS receive (256 B), Command Table (128 B +
  PRDT), each as separately-mapped IOVAs; stash in a per-port DMA
  context row `_ahci_port_dma_ctx[row_id]` (4 words: `clb_iova`,
  `fb_iova`, `cmd_table_iova`, `identify_buf_iova`).
- `ahci_port_program(abar_pa, port_index, clb_iova, fb_iova)`:
  write CLB/CLBU, FB/FBU, set `CMD.FRE`, wait `CMD.FR == 1`, set
  `CMD.ST`, wait `CMD.CR == 1`.
- `ahci_port_read_sig(abar_pa, port_index) -> u32`: read SIG;
  refuse mint with `AHCIP_MINT_BAD_SIG` if != 0x00000101.
- `ahci_fis_h2d_build(buf_va, cmd_op, lba48, count, device)`:
  populate 20-byte FIS in host memory (buffer address is inside the
  Command Table's Command FIS slot); C bit = 1.
- `ahci_identify_device_submit(row_id) -> AHCIP_OK | error`:
  populate slot 0 Command Header (PRDTL=1, CFL=5 dwords, W=0),
  slot 0 Command Table (Command FIS from `ahci_fis_h2d_build(..,
  0xEC, 0, 0, 0)`, PRDT[0] pointing at 512 B identify buffer),
  write `CI=1` for slot 0, poll `CI & 1 == 0` OR `IS.TFES` set
  (task file error).  Read D2H FIS status byte at `fb_va + 0x42`.
- `ahci_identify_parse(identify_buf_va) -> (sector_size, block_count,
  lba48_ok, drat)`: read words 60/61/83/100..103/106/117..118/169
  per §2.6.

The two-step (bring-up + identify) is orchestrated by
`ahci_port_bring_up_and_identify(row_id) -> u64` living in
`kind_ahci_port.pdx` — analogue of `nvme_ctrl_bring_up`.  It stops
short of minting a KIND_BLKDEV; M5-006 owns the mint.

Debugger hint: (a) CLB alignment 256 B, FB alignment 256 B, Command
Table alignment 128 B — all guaranteed by page-carve allocation
(each region on its own page); (b) `CMD.FRE` MUST be set before
`CMD.ST` (§10.1.2); (c) IDENTIFY DEVICE Command FIS: cmd=0xEC,
device=0 (LBA mode not applicable), features=0, count=0; (d) PRDT
DBC field is (byte_count - 1), max 0x3FFFFF (4 MiB - 1); the M5
identify buffer is 512 B, so DBC = 511.

### #1662 R51.M5-006 — Dual-kind AHCI port/BLKDEV mint

Needs: #1660 (row table) + #1661 (per-port bring-up produces
`(sector_size, block_count)`).

Lands: `ahci_port_dual_kind_mint` in `kind_ahci_port.pdx` — the
6-arg mint (§4) that stamps both a `KIND_AHCI_PORT` descriptor at
`port_slot` and a `KIND_BLKDEV` descriptor at `blk_slot`, both
pointing at the same `_ahci_port_table` row_id; the KIND_BLKDEV
descriptor's `target_ptr` bits [23:16] carries family = 2 (AHCI)
per §4.5.

Also lands the family-byte demux in `cap_handler_blkdev.pdx` (§5):
- Family byte extraction + validation + `BDEV_ERR_BAD_FAMILY`.
- `hblk_op_family` short-circuit (return family from descriptor,
  skip row lookup).
- `hblk_op_geom` split (NVMe vs. AHCI row accessors).
- `hblk_do_rw` split (NVMe `nvme_io_submit_rw` vs. AHCI stub
  `ahci_io_submit_rw` — the latter returns `0xEEEE` at M5, fully
  implemented at M6).

Also lands the port cascade revoke: `ahci_port_cascade_revoke_by_ctrl
(ctrl_row_id)` walks `_ahci_port_table`, revokes every row whose
`parent_ctrl_row == ctrl_row_id`.  Wired into `ahci_ctrl_cap_revoke`.
Every port revoke itself scrubs the dual-kind KIND_BLKDEV descriptor
that shares the row — same defensive posture as
`nvme_ns_cascade_revoke_by_ctrl`.

Debugger hint: (a) exact 6-arg SysV signature — if the build says
"too many args" you exceeded 6 and must move to a wider
`params_ptr`; (b) `params_ptr` layout is 4 u64 at 0/8/16/24; (c)
demux family byte MUST validate reserved bits [63:24] == 0
(otherwise a bit-set attacker could route a legit KIND_BLKDEV
through an unintended handler); (d) `BDEV_ERR_BAD_FAMILY =
0xFFFFEC63` extends the BDEV band, not the AHCI band; (e)
`ahci_io_submit_rw` returns `0xEEEE` at M5 which the handler maps to
a `BDEV_ERR_*` alias — that is expected behavior, not a failure to
land.

---

## 8. paideia-as encoder caveats

Delta from `design/hardware/nvme-io-queues.md` §7 and
`design/hardware/nvme-oncs-reliability.md` §8; every point that
applies unchanged is repeated so a reviewer landing M5 does not have
to cross-open a prior doc.

### 8.1 Arity 6-cap (P0276) — IN SCOPE for this milestone

The only mint whose natural arity exceeds 6 is
`ahci_port_dual_kind_mint`.  §4 pre-designs the 6-arg signature with
`params_ptr`.  Every other function in this milestone stays ≤ 6 args.

If a signature grows during implementation (e.g. M6 wants
`ahci_io_submit_rw(ctrl_row, port_row, opcode, lba, nblocks,
dma_iova, deadline_ticks)` — 7 args), the fix is the same
`params_ptr` pattern applied to the trailing overflow args.  Do NOT
try to squeeze via bit-packing — the row_id + lba pair already
consume 40 bits each.

### 8.2 Reserved-label discipline

Labels prefixed per module: `ahcic_` (kind_ahci_controller.pdx),
`ahcip_` (kind_ahci_port.pdx), `ahci_pr_` (drivers/ahci/probe.pdx),
`ahci_rs_` (drivers/ahci/reset.pdx), `ahci_pt_`
(drivers/ahci/port.pdx), `ahci_fs_` (drivers/ahci/fis.pdx),
`ahci_id_` (drivers/ahci/identify.pdx), `ahci_er_`
(drivers/ahci/errors.pdx), `hblk_` (cap_handler_blkdev.pdx —
unchanged; new labels within the same prefix).

`loop`, `if`, `port`, `reset`, `enum` are reserved keywords in
paideia-as and must never appear bare in a label; use the module
prefix.

### 8.3 Sized stores (G1)

Per-port register writes hit u32 registers via
`abar_reg_u32_set(abar_pa, off, val)` — no direct sub-word MMIO
needed at M5.  Row header packing (`in_use[63:56]`, `state[15:8]`,
`ctrl_idx[7:0]`) uses full u64 OR-and-store — no `mov_b` / `mov_w`
in the cap-file layer.

The 20-byte H2D FIS builder (`ahci_fis_h2d_build`) writes byte
fields; use `mov_b [rdi + N], al` with an intermediate zero-extended
byte source.  Same shape as `hda_stream_program`'s H-format setup.

### 8.4 Full-register compares (G4)

The `family` byte demux (§5) does a `cmp r11, 2` after
`and r11, 0xFF` — the mask clears the upper bits so the u8 compare
is safe under G4.  Same pattern the NVMe handler uses on the state
byte.

### 8.5 r11 imm size

All controller / port failure-taxonomy constants sit at
`0xFFFFEC80..EC8F` — greater than `0x7FFFFFFF`, so they DO NOT fit
imm32 and MUST be staged into `r10` (or `r11` between calls) before
`cmp`.  Follow the R51.M2 discipline: `mov r10, 0xFFFFEC8F; cmp
rax, r10` — never `cmp rax, 0xFFFFEC8F` directly.

The `0x00000101` SATA-disk signature fits imm32 and can be compared
directly.  The `0x00000EC1`/`0xEB140101`/`0xC33C0101` device
signatures similarly fit.  The 20-byte FIS field constants (`0x27`,
`0xEC`, `0x40`) all fit imm8 / imm32.

### 8.6 SysV alignment discipline

Every `call` site must observe `rsp%16 == 0`.  The prologue tables:

- `ahci_ctrl_cap_mint_inner`: 5 pushes + `sub rsp, 8` = 48 B; entry
  8 → 56 → %16==0.  Same as `nvme_ctrl_cap_mint_inner`.
- `ahci_ctrl_probe_and_mint`: 6 pushes + `sub rsp, 8` = 56 B; entry
  8 → 64 → %16==0.  Same as `nvme_ctrl_probe_and_mint`.
- `ahci_port_dual_kind_mint`: 6 pushes + `sub rsp, 8` = 56 B; entry
  8 → 64 → %16==0.  Same as `nvme_ns_dual_kind_mint`.
- `cap_handler_blkdev` (extended): grows from 5 to 6 pushes; entry
  8 → 56 → sub rsp, 8 → 64 → %16==0.

---

## 9. Witness plan

Fingerprint: `KIND_AHCI OK` (component-named, no `R` / `M5` /
`#166*` — per `design/policy/output-provenance-strip.md`).

Witness call site: `src/kernel/boot/witness/rpc_servers.pdx` (which
already has the R51 witness scaffolding pattern the file itself
references at line 806 — record[3] AHCI at 0,1F,2 in the QEMU
`-M q35` topology).  Wire one call after the existing NVMe witness:

```
; ...NVMe witness fires 'NVME CTRL OK' + 'NVME NS OK'...
call ahci_witness_probe_and_mint    ; NEW at M5 close
```

`ahci_witness_probe_and_mint` (living in this M5 witness file, not
in the driver):
1. Under BIOS/`-kernel` boot `_ahci_device_count == 0`; drain
   immediately and emit `KIND_AHCI OK` with count=0 (dormant
   posture, matches every prior R51 milestone's under-BIOS shape).
2. Under OVMF with `-device ahci`, `_ahci_devices[0]` is populated;
   mint one `KIND_AHCI_CONTROLLER` at a fixed cap slot, run the
   bring-up (M5-003), enumerate PI, per port run the bring-up +
   IDENTIFY (M5-005), mint dual-kind KIND_AHCI_PORT + KIND_BLKDEV
   (M5-006), then invoke `BDEV_OP_QUERY_GEOM` on the KIND_BLKDEV to
   confirm the geometry matches the identify parse.  Emit
   `KIND_AHCI OK` with count=1 and the parsed
   `(sector_size, block_count)`.
3. On any failure, emit `KIND_AHCI FAIL <code>` with the taxonomy
   code that fired.  The witness never wedges — it always emits
   exactly one fingerprint line per boot.

The `KIND_AHCI OK` fingerprint format (whitespace and casing match
`NVME CTRL OK` / `NVME NS OK`):

```
KIND_AHCI OK
```

with a same-line follow-on when count > 0:

```
KIND_AHCI OK ports=1 sect=512 blocks=<block_count>
```

Golden fixture: `tests/r51/ahci-mint.golden` (mirror
`tests/r51/nvme-mint.golden`).

**Cross-family witness** — invoking the *same* PdxFS mount code
against both NVMe and AHCI — is R51.M7's responsibility (parent §7
M7-006); M5 stops at "AHCI-side substrate synthesises the
KIND_BLKDEV cap that M7 will exercise".

---

## Appendix A — File-size projection

| File | At M5 close | Analogue file | Analogue size |
|:-----|:------------|:--------------|:--------------|
| `cap/kind_ahci_controller.pdx` | ~1400 lines | `cap/kind_nvme_controller.pdx` | 1681 lines |
| `cap/kind_ahci_port.pdx` | ~1500 lines | `cap/kind_nvme_namespace.pdx` | 1674 lines |
| `cap/cap_handler_blkdev.pdx` (extended) | ~380 lines (+~80) | (self, unchanged elsewhere) | 298 lines |
| `drivers/ahci/regs.pdx` | ~200 lines | `drivers/nvme/regs.pdx` | ~200 lines |
| `drivers/ahci/probe.pdx` | ~200 lines | `drivers/nvme/probe.pdx` | ~200 lines |
| `drivers/ahci/reset.pdx` | ~150 lines | (new; no NVMe analogue) | — |
| `drivers/ahci/port.pdx` | ~250 lines | (partial `drivers/nvme/enable.pdx`) | ~120 lines |
| `drivers/ahci/fis.pdx` | ~150 lines | (partial `drivers/nvme/dispatch.pdx`) | — |
| `drivers/ahci/identify.pdx` | ~250 lines | `drivers/nvme/identify.pdx` + `identify_ns.pdx` | ~250 combined |
| `drivers/ahci/errors.pdx` | ~80 lines | `drivers/nvme/errors.pdx` | ~80 lines |

All files stay under the 1800-line god-file threshold the R51
refactor round adopted.  M6 grows `drivers/ahci/submit.pdx` (new,
~500 lines, analogue of `nvme_io_queues.pdx`'s submit path) and
adds ~100 lines to `cap_handler_blkdev.pdx` for the completion
sentinel forwarding.  No M5 file becomes a god-file at M6 close.

---

## Appendix B — Cross-reference to parent design

- Parent §3.2 → §2.1, §2.2 here.
- Parent §3.3 → §2.3 here.
- Parent §3.4 → §2.2 (bring-up), §2.5 (FIS) here.
- Parent §3.5 → §2.4 (PRDT within Command Table) here.
- Parent §3.7 (hot-plug) → OUT OF SCOPE (M6).
- Parent §4.3 (descriptor tail family byte) → §4.5 (family in
  descriptor `target_ptr`) here — the descriptor-level encoding
  supersedes the tail-level `family:u8` field the parent doc
  described for the R24 pre-extended shape.  Both are equivalent for
  dispatch; the descriptor encoding is cheaper because it saves the
  row lookup.
- Parent §4.4 (derivation graph) → §1 mapping table here.
- Parent §5.4 (attestation cascade) → §4.3 note "attestation
  inherited through parent chain" here.
- Parent §6.2 (rights) → §7 M5-001, M5-004 here (with per-cap
  extension noted).
- Parent §7 M5 (issue titles) → §7 here (per-issue design +
  debugger hints).
