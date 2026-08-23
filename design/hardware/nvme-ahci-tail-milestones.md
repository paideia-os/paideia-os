# R51 tail milestones — M6 (AHCI I/O + hot-plug), M7 (unified block wire), M8 (integration)

**Status.**  Draft v0.1 (osarch, 2026-08-22).  Landed as the tail
half of the R51 planning wave (M1..M4 planned, M5 planning in
parallel, M6..M8 planned here).
**Anchor.**  `design/hardware/nvme-and-disk-substrate.md` §7.M6..§7.M8
+ §4 (unified `KIND_BLKDEV`) + §5 (DMA/IOMMU) — this document
expands the sketched three-line breakdowns into commit-scale plans.
**Companion (parallel).**  `design/filesystem/volume-fs-substrate.md`
(softarch) — R52 depends on this document's M7 handshake surface.
**Companion (peer).**  R51.M5 planning (AHCI probe + port mint) —
tracked in the same round; M6 opens once M5 has landed
`KIND_AHCI_PORT` + per-port bring-up (design-doc §3.4 steps 4–7).
**Sibling issues.**  18 total, all in the `R51` milestone:
- M6 (AHCI I/O + hot-plug): #1663, #1664, #1665, #1666, #1667, #1668
- M7 (unified block wire + FS rename): #1669, #1670, #1671, #1672, #1673, #1674
- M8 (mount → soak → hot-remove → HW witness): #1675, #1676, #1677, #1678, #1679, #1680

---

## 0. Reading order

- §1 — What each of M6/M7/M8 accomplishes as a phase (three paragraphs).
- §2 — Per-issue design (18 subsections; one per open issue).
- §3 — R52 handshake at M7: exactly what softarch consumes.
- §4 — Integration story at M8: end-to-end wire from PCI probe through
  BDEV mint to a PdxFS mount, with which test/witness is load-bearing.
- §5 — File layout: which R51/R42 files extend versus which new files
  each milestone adds.
- §6 — paideia-as encoder caveats (arity ≤ 6, prologue alignment,
  `mov_b` syntax, reserved-label prefixing) that every M6-M8 commit
  must respect.
- §7 — Failure-code bands, disjoint from M1-M5's assignments.
- §8 — Per-issue implementation order + dependency graph across M6-M8.

---

## 1. Milestone summaries

### M6 — AHCI I/O commands + hot-plug (6 issues)

M6 completes the AHCI driver's wire-through. M5's output is a
per-port `KIND_AHCI_PORT` that has run `IDENTIFY DEVICE` and knows
its geometry; nothing above it can yet issue user data. M6 lands
the four `BDEV_OP_*` primitives R42 PdxFS v1 needs (READ_LBA,
WRITE_LBA, FLUSH, TRIM-if-DRAT) as native SATA opcodes wrapped in
H2D Register FISes and PRDT-driven scatter-gather, plus the
port-level hot-plug staging that mints and revokes
`KIND_AHCI_PORT` (and its dual-kind `KIND_BLKDEV`) as devices
appear and vanish on their SATA phy. When M6 closes, AHCI is
functionally the peer of NVMe at the BDEV wire; the two families
still speak separate op dispatchers, which is what M7 unifies.

### M7 — Unified `KIND_BLKDEV` + R42 FS rename (6 issues)

M7 removes the last place PdxFS names NVMe. The existing R24
`KIND_BLKDEV = 0x42` descriptor tail grows from 32 B to 64 B to
carry `family / features / max_transfer_blocks / dma_domain_slot /
parent_slot / attest_key` (§4.3 of the substrate doc), preserving
R24-legacy readers via `_blkdev_legacy_view`. The mint entry
splits per-family (`blkdev_cap_mint_from_nvme` /
`blkdev_cap_mint_from_ahci`) and the R24 three-arg form stays as a
compat shim minting with `family = LEGACY_NVME`. Rights add
`R_BLK_FLUSH` (0x08) and `R_BLK_TRIM` (0x10); R24 holders keep
their prior authority unchanged. `cap_handler_blkdev` extends to
dispatch all seven ops (QUERY_GEOM / QUERY_FAMILY / QUERY_FEATURES
/ READ_LBA / WRITE_LBA / FLUSH / TRIM) per §4.2's rights matrix
and routes the tail's `family` byte to either the NVMe or AHCI
back-end. R42's `pdxfs/nvme_write.pdx` becomes
`pdxfs/bdev_write.pdx` and forgets NVMe exists. The milestone
closes on a cross-family witness: the same PdxFS mount code drives
QEMU `nvme` and QEMU `ahci` back-ends and asserts identical
FS-level fingerprints.

### M8 — Integration: mount → journal write → unmount → replay → soak → hot-remove → real HW (6 issues)

M8 is the round's close-out and the point at which R51 and R52
converge for real. The wire-shape from userspace `mount` through
KIND_BLKDEV cap request through FS-layer transaction open to a
BDEV_OP_QUERY_GEOM confirmation goes end-to-end (M8-001). PdxFS
v1 issues journaled writes through BDEV_OP_WRITE_LBA +
BDEV_OP_FLUSH and the durability-barrier order is asserted
(M8-002). Unmount + remount + WAL replay + snapshot-digest equality
prove the round-trip (M8-003). A 1000-iteration soak on both
families exercises the DMA/IOMMU discipline at rate (M8-004).
Hot-remove-under-write on both families proves the revoke cascade
is orderly and the FS surfaces EIO to the mount owner (M8-005).
Finally, the real T14 G4 NVMe boot fingerprints the whole path in
`tests/hw/r51-nvme-t14g4.golden` — the first time PaideiaOS
touches an unaltered internal disk with a mounted filesystem
(M8-006).

---

## 2. Per-issue design

Each subsection lists: **anchor** (substrate-doc section this issue
implements), **new/changed files**, **wire encoding or algorithm**,
**failure-code slot(s) claimed**, **witness/test target**, and
**upstream/downstream deps within M6-M8**.

### 2.M6 — AHCI I/O + hot-plug

#### #1663 — R51.M6-001: Per-port command list + Command Table + PRDT alloc

- **Anchor.** substrate §3.5 (command header + Command Table + PRDT
  layout), §7.M6-001.
- **New file.** `src/kernel/core/drivers/ahci/cmd_alloc.pdx`.
- **Extends.** `src/kernel/core/drivers/ahci/port.pdx` (M5 output) —
  add `ahci_port_cmd_regions_bind(port_row_id, cl_phys, ct_phys)`
  that programs CLB/CLBU (via M5's already-mapped ABAR MMIO cap).
- **Layout.** Per port: one 1 KiB Command List page (32 headers ×
  32 B; 256 B aligned), one 128 B Command Table (H2D Register FIS
  slot + ATAPI slot + reserved; 128 B aligned), and a
  variable-length PRDT allocated per-op (each 16 B, up to 65535
  entries per op). Physical allocation goes through the driver
  process's `KIND_DMA_DOMAIN` (R29.M5); the returned IOVAs are what
  CLB/CLBU and CTBA/CTBAU program.
- **Slot layout.** Each of the 32 command slots owns a 32 B
  command-header row indexed by slot id; the header's `CTBA/CTBAU`
  point at that port's single Command Table. R51.M6 uses one
  Command Table per port (not per slot) — the H2D FIS is re-written
  per submission, and the PRDT that follows is treated as
  overwrite-per-op. This trades one alloc-per-op for the simpler
  reservation model; 32-way in-flight remains reachable because CI
  is per-slot but Command Tables can be per-slot when a future
  round wants to expand queue depth (a `cmd_alloc_v2.pdx` swap-in
  point is documented in `ahci/cmd_alloc.pdx`'s header).
- **Failure codes.** `AHCIIO_CMD_ALLOC_NOMEM = 0xFFFFECA0`;
  `AHCIIO_CMD_BIND_BAD_ROW = 0xFFFFECA1`.
- **Witness.** Fixture: probe QEMU `-device ahci -device ide-hd`, assert
  the port row's `cl_iova` and `ct_iova` are non-zero and
  256/128-byte aligned respectively.
- **Deps.** Upstream: R51.M5 `KIND_AHCI_PORT` mint gate. Downstream:
  every remaining M6 issue (they all submit through this region).

#### #1664 — R51.M6-002: BDEV_OP_READ_LBA via READ_DMA_EXT (0x25)

- **Anchor.** substrate §3.6 (LBA48 R/W + FLUSH), §7.M6-002.
- **New file.** `src/kernel/core/drivers/ahci/io_submit.pdx`.
- **Extends.** `src/kernel/core/cap/cap_handler_blkdev.pdx` —
  the READ_LBA branch's `hblk_do_rw` block routes on
  `family == BDEV_FAMILY_AHCI` (from M7's tail extension; at M6
  the branch temporarily lives behind an `if family == AHCI` guard
  that M7-004 will fold into the unified dispatch).
- **Wire.** H2D Register FIS layout (FIS type `0x27`, C=1):
  - byte 0: `0x27`.
  - byte 1: `C=1`, PMP=0 → `0x80`.
  - byte 2: command byte = `0x25` (READ_DMA_EXT).
  - byte 3: features (low), 0.
  - byte 4: LBA low `[7:0]`.
  - byte 5: LBA mid `[15:8]`.
  - byte 6: LBA high `[23:16]`.
  - byte 7: device = `0x40` (LBA mode set).
  - byte 8: LBA exp low `[31:24]`.
  - byte 9: LBA exp mid `[39:32]`.
  - byte 10: LBA exp high `[47:40]`.
  - byte 11: features (high), 0.
  - byte 12: NSECTOR low.
  - byte 13: NSECTOR high (LBA48 count is 16-bit; 0 → 65536).
  - bytes 14–19: 0.
- **PRDT.** One entry per DMA page. `DBA/DBAU` from
  `dma_domain_map`; `DBC[21:0]` = byte_count − 1, with `I` (interrupt
  on completion) set on the last entry only.
- **Submit path.** Fill H2D FIS in the port's Command Table; set the
  command header's `CFL = 5` (dword count of a 20 B H2D FIS), clear
  `W` (READ), `PRDTL = <n>`; write `CI |= (1 << slot)`; sfence.
- **Completion.** Wait on `CI` bit clear (IRQ-driven via M5's
  shared vector; the IRQ handler drains all ports via IS + PxIS).
  On completion, `PRDBC` in the header reports bytes actually
  transferred; TFD `[BSY|DRQ|ERR]` is checked for error.
- **Failure codes.** `AHCIIO_SUBMIT_NO_SLOT = 0xFFFFECA2`;
  `AHCIIO_SUBMIT_TIMEOUT = 0xFFFFECA3`;
  `AHCIIO_SUBMIT_TFD_ERR = 0xFFFFECA4`;
  `AHCIIO_SUBMIT_PRDT_OVERFLOW = 0xFFFFECA5`.
- **Witness.** `tests/r51/ahci-read.golden` — QEMU AHCI + a 1 MiB
  pre-populated disk image; read LBA 0 for 8 blocks, assert
  content byte-fingerprint matches.
- **Deps.** Upstream: #1663 (needs a bound Command Table + PRDT
  region); parallel with #1665 (they share `io_submit.pdx`).

#### #1665 — R51.M6-003: BDEV_OP_WRITE_LBA via WRITE_DMA_EXT (0x35)

- **Anchor.** substrate §3.6, §7.M6-003.
- **Extends.** `ahci/io_submit.pdx` — a second entry point
  `ahci_io_submit_write` sharing the READ code path via a boolean
  `is_write` argument that gates the header `W` bit + FIS command
  byte.
- **Wire deltas from READ.** command byte = `0x35`; H2D FIS byte 2
  encodes `0x35`; command header dw0 `W` = 1. Everything else is
  identical.
- **PRDT direction.** DMA-domain map programs the pages as
  device-readable (the device pulls bytes from host memory); the
  IOMMU entry's read/write direction bits are set accordingly.
- **Failure codes.** Reuses AHCIIO_SUBMIT_* from #1664 (the
  submit-timeout / TFD-err / PRDT-overflow slots).
- **Witness.** `tests/r51/ahci-write.golden` — write 8 blocks with
  a known pattern, read back via #1664, assert equality.
- **Deps.** Upstream: #1663, #1664 (shares module).

#### #1666 — R51.M6-004: BDEV_OP_FLUSH via FLUSH_CACHE_EXT (0xEA)

- **Anchor.** substrate §3.6 (FLUSH_CACHE_EXT), §4.2 (rights),
  §7.M6-004.
- **New file.** `src/kernel/core/drivers/ahci/reliability.pdx` (peer
  of the NVMe-side `nvme_reliability.pdx` M4 landed).
- **Extends.** `cap_handler_blkdev.pdx` FLUSH branch to dispatch
  through `ahci_flush(port_row_id)` when `family == AHCI`;
  `_ahci_port_table` row gains a `write_cache_present : u8` byte
  (from IDENTIFY word-82 bit-5 at M5-005; if IDENTIFY missed it,
  default 1 — SATA disks universally cache).
- **Wire.** H2D FIS: command = `0xEA`; NSECTOR = 0; LBA = 0; device
  = `0x40`. No PRDT (`PRDTL = 0`).
- **QUERY_FEATURES surface.** `cap_handler_blkdev`'s
  QUERY_FEATURES branch reads the port row's `write_cache_present`
  and sets `BDEV_FEATURE_WRITE_CACHE_PRESENT` (bit 3) accordingly;
  `BDEV_FEATURE_FLUSH_SUPPORTED` (bit 0) is unconditional on AHCI
  (FLUSH_CACHE_EXT is spec-mandatory).
- **Failure codes.** `AHCIREL_FLUSH_TIMEOUT = 0xFFFFECB0`;
  `AHCIREL_FLUSH_TFD_ERR = 0xFFFFECB1`.
- **Witness.** `tests/r51/ahci-flush.golden` — write → flush →
  read after a `qemu-system-x86_64 -drive cache=writeback` restart;
  assert the write persists.
- **Deps.** Upstream: #1663, #1665 (write path exists to be
  flushed). Peers: M7-004 will fold the family-dispatch guard into
  the unified handler.

#### #1667 — R51.M6-005: BDEV_OP_TRIM via DATA_SET_MANAGEMENT (0x06) gated on DRAT

- **Anchor.** substrate §3.6 (TRIM via DSM + DRAT gate), §7.M6-005.
- **Extends.** `ahci/reliability.pdx` (from #1666).
- **DRAT gating.** M5-005 stashes IDENTIFY word-169 in the port row
  (`ahci_port_row_word169 : u16`); `_ahci_port_table.drat` bit is
  `word169 & 1`. If clear, `ahci_trim` returns
  `BDEV_ERR_UNSUPPORTED` before wire touch.
- **Wire.** H2D FIS: command = `0x06` (DATA SET MANAGEMENT);
  features = `0x01` (TRIM bit); device = `0x40`; PRDT points at
  the range descriptor page.
- **Range descriptor.** SATA DSM range: 8 B per range — LBA `[47:0]`
  in bytes 0..5, count `[15:0]` in bytes 6..7; up to 64 ranges per
  512 B sector, up to 65535 sectors per op. R51.M6 caps at one
  512 B page = 64 ranges per op; multi-range TRIM is split by the
  driver, invisible to the FS.
- **Failure codes.** `AHCIREL_TRIM_UNSUP = 0xFFFFECB2`
  (DRAT clear); `AHCIREL_TRIM_BAD_RANGES = 0xFFFFECB3` (count
  0 or >64); `AHCIREL_TRIM_TIMEOUT = 0xFFFFECB4`.
- **Witness.** `tests/r51/ahci-trim.golden` — QEMU
  `-drive discard=on`, TRIM one 64 KiB range, assert the
  underlying image sparsifies (fingerprint the `qemu-img info`
  output size).
- **Deps.** Upstream: #1666 (shares reliability module).

#### #1668 — R51.M6-006: Port hot-plug staging (PxIS.PCS + SSTS.DET debounce)

- **Anchor.** substrate §3.7 (hot-plug), §7.M6-006.
- **New file.** `src/kernel/core/drivers/ahci/hotplug.pdx`.
- **Extends.** `ahci/irq.pdx` (M5 landed) — on IS bit set, if the
  port's PxIS has `PCS` or `PRCS` set, hand off to
  `ahci_hotplug_service(port_row_id)`.
- **State machine.**
  1. Read PxIS: capture `PCS` (present change) + `PRCS` (phy-ready
     change). Clear both by writing 1s back (write-1-to-clear).
  2. Read SSTS.DET:
     - `0x3` (device present, phy established) → schedule
       `ahci_port_present_transition`.
     - `0x0` (no device) → schedule
       `ahci_port_absent_transition`.
     - `0x1` (present, phy not established) → debounce: arm a
       50 ms one-shot timer via `KIND_TIMER`, re-poll on expiry.
     - other → SERR bits are logged, port marked degraded, no
       revoke fires until DET settles.
  3. **SERR debounce.** After DET has settled (any terminal
     transition), write `~0` to PxSERR to clear all error bits;
     otherwise the port stays in an interrupt-storm loop.
- **Present transition.** Re-run M5's port bring-up steps (§3.4
  steps 4–7 — SIG read → IDENTIFY DEVICE → parse geometry) → mint
  a fresh `KIND_AHCI_PORT` row for the new device → dual-mint a
  `KIND_BLKDEV` on the same row_id.
- **Absent transition.** Revoke the port's current
  `KIND_AHCI_PORT` slot; the `cap_revoke` cascade (already wired
  in M5 for KIND_AHCI_PORT parenthood) tears down every
  descendant `KIND_BLKDEV` and every open op. FS mounts holding
  those caps observe `INVOKE_STALE_HANDLE` on their next op.
- **Failure codes.** `AHCIHP_DEBOUNCE_TIMEOUT = 0xFFFFECB5`
  (DET stuck at `0x1` after 500 ms); `AHCIHP_MINT_FAILED =
  0xFFFFECB6` (present transition could not mint — usually
  `AHCI_PORT_TABLE_FULL`); `AHCIHP_REVOKE_ALREADY =
  0xFFFFECB7`.
- **Witness.** `tests/r51/ahci-hotplug.golden` — QEMU
  `device_add ide-hd` + `device_del ide-hd`; assert two mint/revoke
  pairs and no leaked port row.
- **Deps.** Upstream: #1663..#1667 (all of them need to survive
  a mid-transfer revoke).

### 2.M7 — Unified `KIND_BLKDEV` + FS-layer rename

#### #1669 — R51.M7-001: KIND_BLKDEV tail extension 32 → 64 bytes

- **Anchor.** substrate §4.3 (extended tail), §7.M7-001.
- **Extends.** `src/kernel/core/cap/blkdev_cap.pdx` (adds tail
  fields); `src/kernel/core/cap/kind_blkdev.pdx` (row layout,
  accessors).
- **New accessors** (row-indirection via `_blkdev_row_table`):
  - `blkdev_row_family(row_id) -> u8`.
  - `blkdev_row_features(row_id) -> u8`.
  - `blkdev_row_max_transfer_blocks(row_id) -> u16`.
  - `blkdev_row_dma_domain_slot(row_id) -> u32`.
  - `blkdev_row_parent_slot(row_id) -> u32`.
  - `blkdev_row_attest_key(row_id) -> u32`.
- **Legacy view.** `_blkdev_legacy_view(row_id)` returns the R24
  32-byte prefix as a `LegacyBlkdevRow` struct with the exact R24
  offsets (controller_idx/nsid/lba_size/block_count/rights)
  preserved bit-for-bit; the R24-era readers in
  `pdxfs_lite/mount_op.pdx` continue to compile against it.
- **Zero-extension of legacy rows.** R24 rows already stamped
  through the compat shim have `family = 0 (LEGACY_NVME)`, all
  other new fields zero. `blkdev_row_family` returns 0 for those,
  which QUERY_FAMILY maps to `BDEV_FAMILY_LEGACY_NVME` (the
  softarch-visible enum value, distinct from `NVME` and `AHCI`).
- **Failure codes.** `BDEVU_TAIL_ENOSPC = 0xFFFFECC0`;
  `BDEVU_TAIL_BAD_ARG = 0xFFFFECC1`.
- **Witness.** `tests/r51/blkdev-tail64.golden` — mint through the
  compat shim + through `blkdev_cap_mint_from_nvme`; assert
  both readable via `_blkdev_legacy_view`, only the second via
  the new accessors.
- **Deps.** Upstream: none within M7 (this lands first). Downstream:
  every remaining M7 issue.

#### #1670 — R51.M7-002: Rights extension R_BLK_FLUSH + R_BLK_TRIM

- **Anchor.** substrate §6.1 (rights extension), §7.M7-002.
- **Extends.** `blkdev_cap.pdx` — add the constants and audit every
  mint site.
- **Constants.**
  - `R_BLK_READ  = 0x01` (R24, unchanged).
  - `R_BLK_WRITE = 0x02` (R24, unchanged).
  - `R_BLK_ADMIN = 0x04` (R24, unchanged).
  - `R_BLK_ALL   = 0x07` (R24, unchanged).
  - `R_BLK_FLUSH = 0x08` (new).
  - `R_BLK_TRIM  = 0x10` (new).
  - `R_BLK_ALL_R51 = 0x1F` (new).
- **Compat invariant.** R24 holders of `R_BLK_ALL = 0x07` still
  READ/WRITE/ADMIN. They CANNOT FLUSH or TRIM — the mint gate
  refuses to hand out those rights unless the parent cap carries
  them. R42 `nvme_write.pdx`, when M7-005 renames it, is re-minted
  with `R_BLK_ALL_R51`.
- **Mint-gate check** (added to both new per-family mint paths).
  `requested_rights & ~parent_rights == 0` must hold; else
  `BLK_CAP_MINT_BAD_RIGHTS`.
- **Failure codes.** No new slots; reuses the R24 mint-gate
  refusal code.
- **Witness.** `tests/r51/blkdev-rights.golden` — mint with
  `R_BLK_ALL`, attempt FLUSH → BLK_CAP_MINT_BAD_RIGHTS; mint with
  `R_BLK_ALL_R51`, FLUSH succeeds.
- **Deps.** Upstream: #1669 (rights live in the tail's
  R24-preserved `rights` field, but the check reads
  `blkdev_row_family` to compute the max-legal-rights envelope).

#### #1671 — R51.M7-003: blkdev_cap_mint split into per-family entry points

- **Anchor.** substrate §4.1 (reconciliation), §7.M7-003.
- **Extends.** `blkdev_cap.pdx` — two new entry points:
  - `blkdev_cap_mint_from_nvme(parent_ns_slot, dma_domain_slot,
    attest_key, requested_rights) -> slot | ERR` — reads
    `_nvme_namespace_table[parent]` for geometry, features, MDTS
    (→ `max_transfer_blocks = min(MDTS_pages × page_size / lba_size,
    0xFFFF)`), family = NVME.
  - `blkdev_cap_mint_from_ahci(parent_port_slot, dma_domain_slot,
    attest_key, requested_rights) -> slot | ERR` — reads
    `_ahci_port_table[parent]` for geometry, DRAT (→ features
    bit 1), write-cache-present (→ features bit 3), family = AHCI.
    `max_transfer_blocks` derived from PRDTL_max × page_size /
    lba_size, capped at 0xFFFF.
- **Compat shim** — the R24 three-arg mint stays exported as
  `blkdev_cap_mint(controller_idx, nsid, lba_size, block_count,
  rights) -> slot | ERR` and internally packs into the new tail
  with `family = LEGACY_NVME`, `dma_domain_slot = 0` (invalid;
  the compat path pre-dates R29.M5 and cannot use DMA), and
  `attest_key = 0`. Ops that require a live DMA domain
  (READ_LBA/WRITE_LBA/FLUSH/TRIM) reject a caller whose row has
  `dma_domain_slot == 0` with `BDEV_ERR_UNSUPPORTED` (matches R24
  posture: R24-minted caps were never wired end-to-end anyway).
- **Failure codes.** `BDEVU_MINT_BAD_PARENT = 0xFFFFECC2`;
  `BDEVU_MINT_BAD_FAMILY = 0xFFFFECC3`;
  `BDEVU_MINT_NO_ATTEST = 0xFFFFECC4` (attest_key does not match
  a live `KIND_DMA_ATTESTATION` row for the driver's domain);
  `BDEVU_MINT_BAD_DOMAIN = 0xFFFFECC5`.
- **Witness.** `tests/r51/blkdev-mint-split.golden` — mint one
  from each per-family entry, mint one via the compat shim, assert
  family byte = 1/2/0 respectively.
- **Deps.** Upstream: #1669 (tail fields), #1670 (rights
  envelope check).

#### #1672 — R51.M7-004: cap_handler_blkdev unified op dispatch

- **Anchor.** substrate §4.2 (op set + rights matrix), §7.M7-004.
- **Extends.** `cap_handler_blkdev.pdx` — the M3 handler already
  routes NVMe path (checks target_ptr for a namespace row); M7
  adds the family branch: if `blkdev_row_family(row_id) == AHCI`,
  route READ_LBA/WRITE_LBA to `ahci_io_submit_{read,write}`,
  FLUSH to `ahci_flush`, TRIM to `ahci_trim`.
- **Dispatch table** (per op × family):
  | Op | NVMe backend | AHCI backend | LEGACY_NVME |
  |:---|:-------------|:-------------|:------------|
  | QUERY_GEOM | `nvme_ns_row_geom` | `ahci_port_row_geom` | legacy row |
  | QUERY_FAMILY | rax = 1 | rax = 2 | rax = 0 |
  | QUERY_FEATURES | `nvme_ctrl_row_oncs` map | `ahci_port_row_features` map | 0 |
  | READ_LBA | `nvme_io_submit_rw(read)` | `ahci_io_submit_read` | UNSUPPORTED |
  | WRITE_LBA | `nvme_io_submit_rw(write)` | `ahci_io_submit_write` | UNSUPPORTED |
  | FLUSH | `nvme_io_submit_flush` | `ahci_flush` | UNSUPPORTED |
  | TRIM | `nvme_io_submit_trim` | `ahci_trim` | UNSUPPORTED |
- **Rights matrix** (unchanged from M3, extended for FLUSH/TRIM):
  READ_LBA needs `R_BLK_READ`; WRITE_LBA needs `R_BLK_WRITE`;
  FLUSH needs `R_BLK_FLUSH`; TRIM needs `R_BLK_TRIM`; query ops
  need any non-zero rights; QUERY_GEOM needs
  `R_BLK_READ | R_BLK_ADMIN` (both bits, per the M3 comment
  matching design §3.5 verbatim).
- **Fold-in.** M6's per-op `if family == AHCI` guards are removed;
  the M3 handler's `hblk_do_rw` block now decodes family once at
  the top of the branch and dispatches via a two-arm switch.
- **Failure codes.** Reuses `BDEV_ERR_*` from M3
  (0xFFFFEC60..0xFFFFEC6F); one new slot `BDEV_ERR_BAD_FAMILY =
  0xFFFFEC63` (family byte outside {0,1,2}).
- **Witness.** `tests/r51/blkdev-dispatch.golden` — same handler
  under gdb, step through NVMe row + AHCI row + LEGACY row,
  assert each backend was reached exactly once.
- **Deps.** Upstream: #1669, #1670, #1671, and M6-002..M6-005
  (the AHCI backends must exist to be dispatched to).

#### #1673 — R51.M7-005: Rename pdxfs/nvme_write.pdx → pdxfs/bdev_write.pdx

- **Anchor.** substrate §2.7 (what R42 sees), §7.M7-005.
- **File move.** `src/kernel/core/fs/pdxfs/nvme_write.pdx` →
  `src/kernel/core/fs/pdxfs/bdev_write.pdx`.
- **API rename** (three functions):
  - `nvme_write_sync(nsid, lba, len, buf)` →
    `bdev_write_sync(bdev_slot, lba, nblocks, dma_iova)`.
  - `nvme_read_sync(nsid, lba, len, buf)` →
    `bdev_read_sync(bdev_slot, lba, nblocks, dma_iova)`.
  - (new) `bdev_flush(bdev_slot)` — was implicit in R42's NVMe
    path; explicit now because `durability.pdx` should reach it
    through this module rather than by walking NVMe internals.
- **Internal rewrite.** The three functions used to call NVMe SQ
  submission directly; they now `cap_invoke(bdev_slot,
  BDEV_OP_{READ,WRITE,FLUSH}_LBA, arg_page)` and consume the
  descriptor-page status field. The FS layer never touches NVMe
  or AHCI code again.
- **Import audit.** `durability.pdx`, `journal_fence.pdx`,
  `cow_read.pdx`, `cow_write.pdx`, `wal.pdx` all currently
  `import Pdxfs.NvmeWrite`; every one is renamed to
  `import Pdxfs.BdevWrite`. `nvme_write.pdx` stays for one
  commit as a thin re-export shim, then is deleted at end of M7.
- **arity note.** `bdev_write_sync` takes 4 args (bdev_slot, lba,
  nblocks, dma_iova) — fits in rdi/rsi/rdx/rcx; well under the
  6-arg SysV limit. See §6.
- **Failure codes.** `BDEVFS_INVOKE_FAILED = 0xFFFFECD0`;
  `BDEVFS_BAD_STATUS = 0xFFFFECD1`.
- **Witness.** the M7-006 cross-family witness covers this.
- **Deps.** Upstream: #1672 (needs the unified handler wired first
  so FS invocations reach both backends). Blocking for: every M8
  issue.

#### #1674 — R51.M7-006: Cross-family witness: PdxFS mount on NVMe and AHCI

- **Anchor.** substrate §4.5 (softarch invariants), §7.M7-006.
- **Test file.** `tests/r51/pdxfs-cross-family.golden` (new).
- **Two QEMU configurations.**
  - `nvme.qcow2` mounted through `-drive
    if=none,file=nvme.qcow2,id=nd0 -device nvme,drive=nd0,serial=SN0`.
  - `ahci.qcow2` mounted through `-drive
    if=none,file=ahci.qcow2,id=ad0 -device ahci,id=ahci
    -device ide-hd,drive=ad0,bus=ahci.0`.
- **Test sequence** (identical PdxFS driver code for both):
  1. Probe → mint → pdxfs_lite mount.
  2. Write 4 KiB of a fixed pattern to inode 1.
  3. `bdev_flush`.
  4. Read back.
  5. Fingerprint the FS-level state (superblock digest +
     inode-table digest + data-region digest).
- **Assertion.** The three digests are byte-identical between the
  two runs — proves the FS layer sees no family-specific
  behaviour.
- **Failure codes.** Witness-only, no new slots.
- **Deps.** Upstream: every prior M7 issue.

### 2.M8 — Integration: mount → journal → soak → hot-remove → HW witness

#### #1675 — R51.M8-001: Mount syscall wire through KIND_BLKDEV

- **Anchor.** substrate §7.M8-001; softarch companion §3.1
  (probe every KIND_BLOCK_DEVICE at mount-init).
- **Handshake with softarch's R52.M2/M5.** R52 owns the userspace
  `mount` tool (R52.M2-003 `mkfs.pdxfs`; R52.M5-005 extends
  `mount.pdx` with `MOUNT_BACKEND_PDXFS_BLOCK = 5`; R52.M5-004
  lands `volume_registry.pdx` + `probe.pdx`). R51.M8-001's
  responsibility is only the KIND_BLKDEV side of the wire:
  1. Userspace mount tool holds a `KIND_BLKDEV` slot (obtained via
     `blkdev_cap_request` — the userspace-facing syscall that
     the R51 supervisor answers by minting or delegating).
  2. FS layer opens a transaction (R42 `PXT_OP_OPEN`).
  3. FS layer invokes `BDEV_OP_QUERY_GEOM` on the slot; the
     `(lba_size, block_count)` in rax feeds the R52 probe's
     block-0 read.
- **New file.** `src/kernel/core/cap/blkdev_cap_request.pdx` — a
  supervisor-facing entry point the userspace mount tool reaches
  through the standard cap-request wire. Argument: a `bdev_id`
  (UUID-like — R52 owns the shape) which the R51 supervisor
  looks up in its `_blkdev_index_table` (a small 16-slot table
  populated at mint time from the parent controller's
  identify-serial). Returns a fresh `KIND_BLKDEV` slot in the
  caller's cspace with `R_BLK_ALL_R51` rights (contingent on the
  caller's attestation posture — see §5.4 of the substrate doc).
- **Failure codes.** `MOUNTW_BAD_BDEV_ID = 0xFFFFECE0`;
  `MOUNTW_ATTEST_MISSING = 0xFFFFECE1`;
  `MOUNTW_ELEVATE_REFUSED = 0xFFFFECE2` (mount attempt from a
  non-founder against an un-attested device).
- **Witness.** `tests/r51/mount-wire.golden` — the mount tool
  syscall traces show `blkdev_cap_request → mint slot → QUERY_GEOM
  → (lba_size=4096, block_count=<matches -drive size>)`.
- **Deps.** Upstream: every M7 issue.

#### #1676 — R51.M8-002: Journaled write + FLUSH barrier order

- **Anchor.** substrate §5.4 (softarch companion) — the WAL
  durability rules PdxFS v1 already carries at R42, wired now
  through the unified BDEV wire.
- **Barrier order asserted.**
  1. `BDEV_OP_WRITE_LBA` of the journal-block payload.
  2. `BDEV_OP_FLUSH`.
  3. `BDEV_OP_WRITE_LBA` of the journal-block CSUM word.
  4. `BDEV_OP_FLUSH`.
  5. `BDEV_OP_WRITE_LBA` of the data-region blocks the journal
     record commits.
  6. `BDEV_OP_FLUSH` (only if `JOP_COMMIT` — a `JOP_ABORT` frees
     without flushing).
- **Assertion mechanism.** A per-cap event-ring in
  `bdev_write.pdx` records every op's (op_code, lba, ts) at
  submission; the test harness reads the ring and asserts the
  ordering above via a state-machine walk.
- **Failure codes.** `MOUNTW_BARRIER_VIOLATION = 0xFFFFECE3`
  (the ordering-check finds a WRITE without a preceding FLUSH
  where one was required).
- **Witness.** `tests/r51/journal-barrier.golden` — write 8
  journaled records, assert the event ring matches the
  six-step pattern per record.
- **Deps.** Upstream: #1675.

#### #1677 — R51.M8-003: Unmount + remount + WAL replay + snapshot digest

- **Anchor.** substrate §7.M8-003; softarch companion §4.3 (WAL
  replay walks on-disk JBNL blocks).
- **Sequence.**
  1. Mount volume V.
  2. Take snapshot digest `D_pre` (superblock + itable + WAL head
     + data-region hash).
  3. Write 32 records + `JOP_COMMIT`.
  4. Unmount cleanly (R52.M8-004 owns the clean-unmount flag; on
     the R51 side, the last op before unmount is a
     `BDEV_OP_FLUSH`).
  5. Remount.
  6. R52's `journal_replay.pdx` (M5-003) walks on-disk JBNL
     blocks and replays.
  7. Take snapshot digest `D_post`.
  8. Assert `D_pre == D_post` (nothing lost, nothing added — the
     32 written records are already replayed by step 6, and the
     digest is defined post-replay).
- **Failure codes.** `MOUNTW_REMOUNT_DIGEST_MISMATCH =
  0xFFFFECE4`.
- **Witness.** `tests/r51/remount-replay.golden` on both NVMe
  and AHCI.
- **Deps.** Upstream: #1676; softarch R52.M5-003.

#### #1678 — R51.M8-004: Cross-family 1000-iteration soak

- **Anchor.** substrate §7.M8-004; §5 (DMA/IOMMU discipline is
  exercised at rate for the first time).
- **Loop body.** mount → write 4 KiB → flush → unmount → remount →
  read back → assert equality → unmount → sleep 1 ms.
- **Iteration count.** 1000. On each iteration the DMA domain
  cycles map/unmap, exercising the VT-d IOTLB invalidation queue
  and the domain-reach invariant.
- **Cross-family.** Two runs of the loop: one against QEMU
  `nvme`, one against QEMU `ahci`, using the same test binary.
  Optional (skipped in CI, run in HW smoke): T14 G4 internal NVMe
  + T14 G4 SATA dock.
- **Success criterion.** 1000/1000 iterations pass, no IOTLB
  descriptor drops (`vtd_ctx.pdx` counter unchanged from
  start), no orphan bounce-pool pages.
- **Failure codes.** `MOUNTW_SOAK_ITER_FAILED = 0xFFFFECF0`
  (with iteration index in the descriptor page's status field);
  `MOUNTW_SOAK_IOTLB_DROP = 0xFFFFECF1`;
  `MOUNTW_SOAK_BOUNCE_LEAK = 0xFFFFECF2`.
- **Witness.** `tests/r51/soak.golden` (only the summary line —
  iteration index and elapsed µs are stripped before
  fingerprinting).
- **Deps.** Upstream: #1677 (soak reuses the mount/unmount pair).

#### #1679 — R51.M8-005: Hot-remove-under-write surfaces EIO

- **Anchor.** substrate §7.M8-005.
- **Test shape.** Background writer thread issues
  `bdev_write_sync` in a loop; a controller thread triggers
  device removal at iteration 100:
  - NVMe: QEMU monitor `device_del nvme0`.
  - AHCI: port SUD toggle (write `CMD.SUD = 0` then `= 1` on the
    port row's ABAR).
- **Expected observable cascade.**
  1. R29 PCIe hot-plug (NVMe) or `ahci_hotplug_service` (AHCI)
     observes the transition.
  2. `KIND_NVME_NAMESPACE` (or `KIND_AHCI_PORT`) revoke fires.
  3. Cascade takes down the dual-kind `KIND_BLKDEV` row.
  4. The writer's next `cap_invoke(bdev_slot, WRITE_LBA)` returns
     `INVOKE_STALE_HANDLE`.
  5. `bdev_write.pdx` translates `INVOKE_STALE_HANDLE` to
     `BDEVFS_EIO = 0xFFFFECD2` (new slot in the BDEVFS band).
  6. R42 `cow_write.pdx` propagates that to `PXT_OP_ABORT` →
     the mount owner sees the abort.
- **Assertion.** Every in-flight op after the removal returns EIO;
  no op returns success against a revoked cap; no bounce-pool
  page leaks (the per-driver bounce accounting is at zero
  outstanding at end-of-test).
- **Failure codes.** `MOUNTW_HR_SILENT_SUCCESS = 0xFFFFECE5`
  (write succeeded against a cap that should have been revoked);
  `MOUNTW_HR_LEAKED_BOUNCE = 0xFFFFECE6`.
- **Witness.** `tests/r51/hot-remove.golden` on both families.
- **Deps.** Upstream: #1676 (writer needs the journaled-write
  path); #1668 (AHCI hot-plug must be wired).

#### #1680 — R51.M8-006: T14 G4 first-real-hardware witness

- **Anchor.** substrate §7.M8-006; `design/hardware/t14-g4-first-boot.md`
  §6 (extends the existing HW fingerprint set).
- **Test target.** `tests/hw/r51-nvme-t14g4.golden`.
- **Procedure.** Follows the t14-g4-first-boot recipe steps 0–5
  (cold power → USB stick → serial cable → first-light kernel
  message → `kernel_main` reaches userspace). New in R51:
  step 6 is the mount+write+flush+unmount+remount+read sequence
  from #1677 against the T14 G4's internal NVMe device.
- **Fingerprint fields.** Superblock digest (post-mkfs), itable
  digest (post-write), WAL-head LBA, `mount_gen` counter, and
  the `blkdev_row_family` byte (must be 1 = NVME).
- **Redaction.** Serial numbers, wall-clock timestamps, and MSI-X
  vector indices (whose exact values depend on APIC init order,
  not reproducible) are stripped before fingerprinting; the
  `tools/hw-smoke-normalize.sh` script from R28.M2 handles this.
- **Failure codes.** `MOUNTW_HW_FINGERPRINT_MISMATCH =
  0xFFFFECF3` (fingerprint diff against the golden);
  `MOUNTW_HW_BOOT_TIMEOUT = 0xFFFFECF4` (kernel_main did not
  reach userspace within 30 s).
- **Witness.** the golden file itself. First landing is a
  no-diff baseline; regressions are diffs against it.
- **Deps.** Upstream: #1677, #1678 (the sequences the HW witness
  drives). Optional: #1679 (hot-remove is not driven on real
  HW at R51; deferred to a manual QA pass).

---

## 3. R52 handshake at M7

The R52 planning wave (`design/filesystem/volume-fs-substrate.md`)
consumes R51.M7's output as follows. Every one of these surfaces is
frozen at M7-close and any change downstream requires cross-repo
notice.

### 3.1 Surface consumed by R52

- **The KIND itself.** `KIND_BLKDEV = 0x42` (osarch-owned; R52
  never allocates a block-device ordinal). Softarch's doc names
  it `KIND_BLOCK_DEVICE` for readability but the codebase spells
  it `KIND_BLKDEV` — see substrate §4.1. Cross-references from
  R52 modules to R51 modules use the codebase spelling.
- **The op set.** `BDEV_OP_QUERY_GEOM`, `BDEV_OP_QUERY_FAMILY`,
  `BDEV_OP_QUERY_FEATURES`, `BDEV_OP_READ_LBA`,
  `BDEV_OP_WRITE_LBA`, `BDEV_OP_FLUSH`, `BDEV_OP_TRIM`.
- **Op-name aliasing.** The R52 draft uses `BD_OP_*` prefixes
  throughout (§4.2, §5.3, §7.M6/M7 of `volume-fs-substrate.md`).
  R51 code exports the `BDEV_OP_*` symbols. **M7-004 lands an
  alias module** `src/kernel/core/cap/bdev_op_aliases.pdx` that
  re-exports `BDEV_OP_*` under `BD_OP_*` for one round to let
  R52 code compile without renaming; R53 removes the aliases.
  Documented in the alias module's header as a scheduled retire.
- **Op-arg encoding.** Per M3's `cap_handler_blkdev.pdx` header:
  `rdi = rights`, `rsi = target_ptr`, `rdx = op_arg`, where
  `op_arg[7:0] = op_code` and `op_arg[63:12] = descriptor page
  IOVA` (page-aligned). READ/WRITE/FLUSH consume a 32 B
  descriptor page laid out as
  `+0 lba:u64 / +8 nblocks:u64 / +16 dma_iova:u64 /
  +24 status_out:u64`. R52 allocates this page per op through its
  block cache's DMA-mapped scratch pool.
- **QUERY_GEOM return.** rax packs `(lba_size:u32, block_count:u64)`
  — low 32 bits are lba_size, high 32 bits are the low 32 bits of
  block_count. R52 needs the full 64-bit block_count; a
  supplementary `BDEV_OP_QUERY_GEOM_EXT` returning rax = row_id
  and writing `(lba_size:u32, block_count:u64)` to the
  descriptor page's `+0/+8` slot is provided for R52 use (added
  in M7-004; R24 callers keep using the packed form).
- **QUERY_FEATURES bitmap.** Bit 0 FLUSH, bit 1 TRIM, bit 2
  WRITE_ZEROES, bit 3 WRITE_CACHE_PRESENT, bit 4 SMART_AVAILABLE
  (from M3 + M4). R52's allocator conditions its TRIM path on
  bit 1 (§9 of the substrate doc: `BDEV_OP_TRIM` may fail with
  `BDEV_ERR_UNSUPPORTED`).
- **max_transfer_blocks.** From the extended tail
  (`blkdev_row_max_transfer_blocks`). R52 sizes its writeback
  chunks to this; it MUST NOT depend on a particular value
  (§9 constraint).
- **FLUSH is a hard fence.** When `BDEV_OP_FLUSH` returns 0,
  every prior `WRITE_LBA` on that cap is persistent. R52's WAL
  barrier + snapshot commit paths get to depend on this without
  further per-family reasoning.
- **Discovery timing.** Softarch's probe (companion §3.1) runs
  after every `KIND_BLKDEV` mint. R51's driver reset semantic
  (M4-005 queue reset; M4-006 controller reset; M6-006 port
  hot-plug) ensures the device is quiesced before the mint fires
  — QUERY_GEOM/QUERY_FAMILY/QUERY_FEATURES all answer correctly
  the first time. R52's `probe.pdx` (R52.M5-004) may re-probe on
  every driver bounce without observing torn state.

### 3.2 Surface R52 does NOT consume (deliberately opaque)

- **Family byte** (from QUERY_FAMILY) is diagnostic only. R52's
  allocator, journal, and FS tree never branch on it.
- **NVMe-specific ordinals** (`KIND_NVME_CONTROLLER`,
  `KIND_NVME_NAMESPACE`) stay confined to the R51 supervisor
  process; R52 never asks for them.
- **AHCI-specific ordinals** (`KIND_AHCI_CONTROLLER`,
  `KIND_AHCI_PORT`) — same.
- **IOMMU / DMA domain caps** — R52 never holds a
  `KIND_DMA_DOMAIN`; it hands the driver `KIND_PAGE` handles
  and the driver's op path programs the IOMMU (substrate §5.2).
- **Bounce buffer choice** — invisible to R52 (substrate §5.3).

### 3.3 R52 issues that specifically wire against R51.M7 surface

Searched via the R52 milestone (`gh issue list --milestone R52`);
issues that name `BD_OP_*` or `KIND_BLOCK_DEVICE`:

| R52 issue | R51 surface consumed |
|:----------|:---------------------|
| #1683 R52.M1-003 (lands `volume-fs-substrate.md`) | Cites `KIND_BLOCK_DEVICE` and the full op set as its foundation |
| #1706 R52.M5-004 (probe.pdx + volume_registry) | Iterates live `KIND_BLKDEV` caps; issues `BDEV_OP_QUERY_GEOM` per cap |
| #1707 R52.M5-005 (mount.pdx backend 5) | Backend takes a `KIND_BLKDEV` slot as arg |
| #1705 R52.M5-003 (journal_replay walks on-disk JBNL) | Uses `BDEV_OP_READ_LBA` for the walk |
| #1712 R52.M6-004 (PXT_OP_COMMIT emits JOP_COMMIT + BD_OP_FLUSH) | `BDEV_OP_FLUSH` as fence op |
| #1717 R52.M7-003 (cache wired into cow_read/cow_write) | Retires `nvme_write.pdx` scaffold; only calls `BDEV_OP_*` |
| #1718 R52.M7-004 (writeback tick + BD_OP_FLUSH cadence) | `BDEV_OP_FLUSH` on the writeback path |
| #1719 R52.M7-005 (single-block prefetch on BD_OP_READ_LBA) | `BDEV_OP_READ_LBA` is the low-priority hit |
| #1721 R52.M8-001 (run-smoke.sh + QEMU-attached blank NVMe) | Full stack — driver probe → BDEV mint → mkfs.pdxfs |

R52 issues that only touch above-BDEV surface (mkfs, allocator, WAL
on-disk shape, inode table, block cache, etc.) — not listed; they
consume the wire but not any specific op-level detail.

### 3.4 What breaks if the handshake slips

- If M7-001's tail extension is not readable by R52's probe (byte
  offsets differ from §4.3), the volume registry cannot compute
  `max_transfer_blocks` for its cache-size heuristic → chooses a
  default that either wastes memory (too large) or introduces
  driver-side splitting (too small).
- If M7-004's alias module is not landed, every R52 module that
  uses `BD_OP_*` symbols fails to link at R52 open → R52.M1
  cannot land.
- If the `BDEV_OP_QUERY_GEOM_EXT` variant is not added, R52
  volumes greater than 4 TiB (block_count > 2^32) truncate at
  probe → the volume registry misreports capacity.
- If `BDEV_OP_FLUSH` is not a hard fence, R52's WAL barrier
  semantic (companion §4.2) is silently wrong on real hardware.
  This is the single most load-bearing invariant R51 owes R52.

---

## 4. Integration story at M8

The end-to-end wire the M8 sequence exercises, in order, so a
reader can trace what each test/witness is actually proving.

### 4.1 Cold boot → first PdxFS mount

```
firmware POST
  -> UEFI stub -> kernel_main_uefi
    -> R23 framebuffer / R30 tty online
    -> R28 userspace init
      -> PCIe enumerator (R24)
        for each function:
          class 01/sub 08 -> mint KIND_NVME_CONTROLLER (R51.M1)
            -> admin queue bring-up (R51.M1-003)
            -> IDENTIFY controller (R51.M1-004)
            -> IDENTIFY active-nsid list (R51.M2-002)
              for each NSID:
                mint KIND_NVME_NAMESPACE + dual-mint KIND_BLKDEV
                                                    (R51.M2-004)
          class 01/sub 06/prog-if 01 -> mint KIND_AHCI_CONTROLLER (R51.M5)
            -> AHCI HBA reset + PI enum (R51.M5-003)
              for each populated port:
                per-port bring-up + IDENTIFY DEVICE (R51.M5-005)
                mint KIND_AHCI_PORT + dual-mint KIND_BLKDEV
                                                    (R51.M5-006)
      -> userspace mount tool
        -> blkdev_cap_request(bdev_id)               (R51.M8-001)
          -> supervisor mints KIND_BLKDEV in caller cspace
        -> R52 mount syscall MOUNT_BACKEND_PDXFS_BLOCK (R52.M5-005)
          -> R52 probe.pdx opens block-0 via BDEV_OP_READ_LBA (R52.M5-004)
          -> R52 volume_registry indexes by UUID
          -> R52 vfs opens root inode
```

### 4.2 First journaled write

```
userspace write(fd, buf, 4096)
  -> vfs_write.pdx
    -> R42 cow_write.pdx (via BdevWrite import)
      -> journal alloc slot (R42 wal.pdx)
      -> bdev_write_sync(bdev_slot, journal_lba, 1, journal_iova)
        -> cap_invoke(bdev_slot, BDEV_OP_WRITE_LBA, arg_page)
          -> cap_handler_blkdev routes on family byte
            -> nvme_io_submit_rw OR ahci_io_submit_write     (R51.M6-003)
              -> per-CPU SQ tail bump (NVMe) or CI bit set (AHCI)
              -> IRQ-driven CQE/CI-clear on completion
      -> bdev_flush(bdev_slot)                                (R51.M8-002)
        -> BDEV_OP_FLUSH -> nvme_io_submit_flush OR ahci_flush (R51.M6-004)
      -> journal CSUM write (same shape)
      -> bdev_flush
      -> data-region write (same shape)
      -> bdev_flush (only on JOP_COMMIT)
```

### 4.3 Unmount → remount → replay

```
umount /mnt/data
  -> R52 fs_close -> BDEV_OP_FLUSH -> checkpoint advance
  -> mark clean-unmount flag in superblock (R52.M8-004)
  -> BDEV_OP_FLUSH
  -> vfs frees the mount slot
  -> KIND_BLKDEV slot released (not revoked; the supervisor may re-hand)

mount /dev/nvme0n1 /mnt/data
  -> blkdev_cap_request again
  -> R52 probe finds the same UUID
  -> R52 journal_replay.pdx walks JBNL back to checkpoint (R52.M5-003)
    -> BDEV_OP_READ_LBA over the journal region
  -> forward-walk CSUM-verify -> replay JOP_COMMIT records
  -> checkpoint advances
  -> root inode readable
```

### 4.4 The load-bearing witnesses

Each test in `tests/r51/` proves one narrowly-scoped invariant of
this wire. The M8 sequence is designed so a single test failure
localises to a single BDEV_OP_ or a single sequencing rule.

| Witness | Proves |
|:--------|:-------|
| `tests/r51/ahci-read.golden` (M6-002) | AHCI READ path pumps bytes |
| `tests/r51/ahci-write.golden` (M6-003) | AHCI WRITE path pumps bytes |
| `tests/r51/ahci-flush.golden` (M6-004) | FLUSH persists across a QEMU cache-flush restart |
| `tests/r51/ahci-trim.golden` (M6-005) | TRIM sparsifies the image (or gracefully declines) |
| `tests/r51/ahci-hotplug.golden` (M6-006) | Present/absent transitions produce mint/revoke pairs |
| `tests/r51/blkdev-tail64.golden` (M7-001) | Tail extension is backward-view-compatible |
| `tests/r51/blkdev-rights.golden` (M7-002) | R24 rights untouched; R51 rights gated |
| `tests/r51/blkdev-mint-split.golden` (M7-003) | Per-family + compat mints stamp the right family byte |
| `tests/r51/blkdev-dispatch.golden` (M7-004) | Unified handler reaches every backend exactly once |
| `tests/r51/pdxfs-cross-family.golden` (M7-006) | Same PdxFS state on NVMe vs AHCI |
| `tests/r51/mount-wire.golden` (M8-001) | mount → cap_request → mint → QUERY_GEOM |
| `tests/r51/journal-barrier.golden` (M8-002) | The 6-step barrier order per record |
| `tests/r51/remount-replay.golden` (M8-003) | Snapshot digest unchanged after unmount+remount |
| `tests/r51/soak.golden` (M8-004) | 1000-iteration cycle exercises DMA discipline cleanly |
| `tests/r51/hot-remove.golden` (M8-005) | Revoke cascade + EIO propagation |
| `tests/hw/r51-nvme-t14g4.golden` (M8-006) | The whole stack on real hardware |

---

## 5. File layout

### 5.1 Extending existing files (from R24/R29/R42/R51 prior milestones)

| File | Milestone | What extends |
|:-----|:----------|:-------------|
| `src/kernel/core/cap/blkdev_cap.pdx` (R24) | M7-001, M7-002, M7-003 | Tail 32→64 B, R_BLK_FLUSH/TRIM constants, per-family mint entry points, compat shim |
| `src/kernel/core/cap/kind_blkdev.pdx` (R24) | M7-001 | New row accessors + `_blkdev_legacy_view` |
| `src/kernel/core/cap/cap_handler_blkdev.pdx` (R51.M3) | M7-004 | Family byte dispatch, `BDEV_OP_QUERY_GEOM_EXT`, `BDEV_ERR_BAD_FAMILY` |
| `src/kernel/core/drivers/ahci/port.pdx` (R51.M5) | M6-001 | `ahci_port_cmd_regions_bind` |
| `src/kernel/core/drivers/ahci/irq.pdx` (R51.M5) | M6-006 | Dispatch on PxIS.PCS/PRCS → hotplug service |
| `src/kernel/core/fs/pdxfs/durability.pdx` (R42) | M7-005 | Import rename `NvmeWrite` → `BdevWrite` |
| `src/kernel/core/fs/pdxfs/journal_fence.pdx` (R42) | M7-005 | Same import rename |
| `src/kernel/core/fs/pdxfs/cow_read.pdx`, `cow_write.pdx`, `wal.pdx` (R42) | M7-005 | Same import rename |
| `design/hardware/nvme-and-disk-substrate.md` (this round) | every M6-M8 issue closes with a cross-ref | Living doc; §7.M6/M7/M8 stay authoritative |
| `design/hardware/t14-g4-first-boot.md` (R28) | M8-006 | Extends §6 with the mount+flush+remount HW procedure |

### 5.2 New files this tail lands

| New file | Milestone | Purpose |
|:---------|:----------|:--------|
| `src/kernel/core/drivers/ahci/cmd_alloc.pdx` | M6-001 | Command list + Command Table + PRDT alloc per port |
| `src/kernel/core/drivers/ahci/io_submit.pdx` | M6-002, M6-003 | READ_DMA_EXT + WRITE_DMA_EXT wire |
| `src/kernel/core/drivers/ahci/reliability.pdx` | M6-004, M6-005 | FLUSH_CACHE_EXT + DSM/TRIM wire |
| `src/kernel/core/drivers/ahci/hotplug.pdx` | M6-006 | PxIS + SSTS.DET debounce + mint/revoke |
| `src/kernel/core/cap/bdev_op_aliases.pdx` | M7-004 | `BD_OP_*` → `BDEV_OP_*` alias for R52 (retires at R53) |
| `src/kernel/core/cap/blkdev_cap_request.pdx` | M8-001 | Supervisor-facing mount cap-request entry point |
| `src/kernel/core/fs/pdxfs/bdev_write.pdx` | M7-005 | Renamed from `nvme_write.pdx`; adds `bdev_flush` |
| `tests/r51/ahci-read.golden` .. `hot-remove.golden` | M6/M7/M8 | 15 witnesses (one per issue that lands a witness) |
| `tests/hw/r51-nvme-t14g4.golden` | M8-006 | Real HW fingerprint |

### 5.3 Files retired

- `src/kernel/core/fs/pdxfs/nvme_write.pdx` — retired at end of
  M7 (after M7-005 lands `bdev_write.pdx` as a re-export shim for
  one commit and then flips every importer).
- `src/kernel/core/cap/bdev_op_aliases.pdx` — retired at R53 open
  (the alias module documents its own scheduled removal date in
  its header comment).

### 5.4 Directory-level shape after M8 close

```
src/kernel/core/drivers/
  nvme/                     (R24; unchanged from M4)
  ahci/                     (R51.M5 + M6)
    controller.pdx          (M5-001)
    port.pdx                (M5-004,M5-005, extended M6-001)
    irq.pdx                 (M5, extended M6-006)
    cmd_alloc.pdx           (M6-001)
    io_submit.pdx           (M6-002, M6-003)
    reliability.pdx         (M6-004, M6-005)
    hotplug.pdx             (M6-006)
src/kernel/core/cap/
  blkdev_cap.pdx            (R24, extended M7-001/002/003)
  kind_blkdev.pdx           (R24, extended M7-001)
  cap_handler_blkdev.pdx    (M3, extended M7-004)
  bdev_op_aliases.pdx       (M7-004, retires R53)
  blkdev_cap_request.pdx    (M8-001)
  kind_nvme_controller.pdx  (M1)
  kind_nvme_namespace.pdx   (M2)
  kind_ahci_controller.pdx  (M5)
  kind_ahci_port.pdx        (M5)
src/kernel/core/fs/pdxfs/
  bdev_write.pdx            (M7-005; was nvme_write.pdx)
  (durability|journal_fence|cow_read|cow_write|wal).pdx   (imports flipped M7-005)
```

---

## 6. paideia-as encoder caveats

Every M6-M8 commit lives under the same encoder-gap posture the
R51.M3 handler already carries (`cap_handler_blkdev.pdx` §
"paideia-as encoder-gap posture (v0.22.x)"). The four caveats
that recur across this tail:

### 6.1 Arity ≤ 6 (SysV register ABI)

`ahci_io_submit_read/write` takes 5 args (port_row_id, lba,
nblocks, dma_iova, is_write) — fits rdi/rsi/rdx/rcx/r8. If a
future extension needs a 7th arg (e.g. `barrier_flags`), fold it
into the descriptor page. `bdev_write_sync` at 4 args stays
comfortably under the limit. Every M6-M8 function ships ≤ 6 args
by design; any variant that would exceed spills to the caller's
descriptor page like M3 did with `arg_page`.

### 6.2 Prologue alignment (SysV requires 16-byte-aligned rsp at call)

Every M6-M8 unsafe-block function that pushes callee-save
registers documents its push count in the function's
`justification:` field so a reviewer can verify `rsp % 16 == 0`
at the first internal `call`. Precedent from M3:
`cap_handler_blkdev` pushes 5 (rbx/r12/r13/r14/rbp) → 5×8 = 40
on entry to a function called at `rsp % 16 == 8` (post-`call`
return-address push) → `8 + 40 = 48`, `48 % 16 == 0`, no
alignment pad needed. M6-M8 functions with 4 callee-save
pushes need one `sub rsp, 8` pad; the justification records
this explicitly.

### 6.3 `mov_b` for sub-8-byte fields

The AHCI port row's `family : u8`, `features : u8`,
`write_cache_present : u8`, `drat : u8`, and the blkdev tail's
`family : u8` bytes are all read/written with `mov_b` /
`movzx` idioms, never `mov reg64, [addr]` truncated. Every
byte access ships an accompanying `xor <reg>, <reg>` pre-zero so
the upper 56 bits are known clean. M3's header calls this out as
G1; the pattern is unchanged here.

### 6.4 Full-register comparisons via `mov r10, <imm64>; cmp`

Every failure-code sentinel this document defines
(0xFFFFECA0..0xFFFFECF4) has bit 63 clear but bit 31 set — an
imm32 operand to `cmp` sign-extends to `0xFFFFFFFFFFFFECxx`
rather than `0x00000000FFFFECxx`. Direct `cmp rax, 0xFFFFECA0`
compares against the wrong value. Every sentinel comparison is
staged through `mov r10, <imm64>; cmp reg, r10`. M3's header
documents this as G4; every M6-M8 handler that maps a raw
backend return code inherits the same discipline.

### 6.5 Reserved-label discipline

`loop`, `if`, `else`, `while`, `for`, `match`, `let`, `fn`,
`return`, `break`, `continue` are keywords in the paideia-as
grammar; a label spelled `loop:` or `if:` fails to parse. Every
label in M6-M8 unsafe blocks is prefixed with the function name:

- `ahci_io_submit_read` labels: `aior_*`.
- `ahci_io_submit_write` labels: `aiow_*`.
- `ahci_flush` labels: `aflush_*`.
- `ahci_trim` labels: `atrim_*`.
- `ahci_hotplug_service` labels: `ahp_*`.
- `blkdev_cap_mint_from_nvme` labels: `bmfn_*`.
- `blkdev_cap_mint_from_ahci` labels: `bmfa_*`.
- `bdev_write_sync` labels: `bws_*`.
- `blkdev_cap_request` labels: `bcreq_*`.

The prefix is checked into `.plans/reserved-labels.tsv` as each
file lands so a grep confirms no collision.

### 6.6 Encoder-gap issues to file on paideia-as (M6-M8 amplified)

The substrate doc §8 already flagged four encoder gaps R51
amplifies. M6-M8 sharpens two of them:

- **§8.2 struct-of-integers packing.** The AHCI PRDT is 16 B
  entries of `(u64 DBA, u32 reserved, u32 dbc_i)`. M6-002 is the
  first regular emitter of this layout at rate; if paideia-as
  pads the third `u32` to align the following entry, the PRDT
  breaks silently on every op past entry 0. Suggested paideia-as
  issue: "Verify PRDT 16-byte-per-entry byte-accurate packing;
  test: emit an N=8 entry array, dump bytes, assert 128 B
  total".
- **§8.3 MMIO fence.** M6-002/003's `CI |= (1 << slot); sfence`
  pattern is a doorbell equivalent. If sfence is silently
  dropped, the device sees the CI-bit set before its command
  table has settled → data corruption. Suggested paideia-as
  issue: "Golden-fingerprint an sfence emission at
  `unsafe { block: { sfence; } }`; assert bytes = `0F AE F8`".

---

## 7. Failure-code bands (disjoint from M1-M5)

R51 uses the `0xFFFFECxx` band the R30 and R48 rounds pioneered
(one 16-slot subband per KIND / per module). Assignments so far:

| Range | Owner | Round | File |
|:------|:------|:------|:-----|
| 0xFFFFEC00..0xFFFFEC0F | ELVC (kind_elevate_channel) | R48 | `cap/kind_elevate_channel.pdx` |
| 0xFFFFEC10..0xFFFFEC1F | PXT (kind_pdxfs_txn) | R48b | `cap/kind_pdxfs_txn.pdx` |
| 0xFFFFEC20..0xFFFFEC2F | PFF (kind_pdxfs_file) | R48b | `cap/kind_pdxfs_file.pdx` |
| 0xFFFFEC30..0xFFFFEC3F | TTY (kind_tty) | R30-PREP | `cap/kind_tty.pdx` |
| 0xFFFFEC40..0xFFFFEC4F | NVMEC (KIND_NVME_CONTROLLER) | R51.M1 | `cap/kind_nvme_controller.pdx` |
| 0xFFFFEC50..0xFFFFEC5F | NVMEIO + NVMEN (I/O submit + namespace) | R51.M2, M3 | `drivers/nvme/nvme_io_queues.pdx`, `cap/kind_nvme_namespace.pdx` |
| 0xFFFFEC60..0xFFFFEC6F | BDEV_ERR (op-set errors) | R51.M3, extended M7-004 | `cap/cap_handler_blkdev.pdx` |
| 0xFFFFEC70..0xFFFFEC7F | NVMEREL (FLUSH/TRIM/AER/log/watchdog/CFS) | R51.M4 | `cap/nvme_reliability.pdx` |

**Reserved for R51.M5 (planning in parallel; expected):**

| 0xFFFFEC80..0xFFFFEC8F | AHCIC (KIND_AHCI_CONTROLLER) | R51.M5 |
| 0xFFFFEC90..0xFFFFEC9F | AHCIP (KIND_AHCI_PORT) | R51.M5 |

**Claimed by this tail (M6-M8):**

| Range | Owner | Milestone | Anchor |
|:------|:------|:----------|:-------|
| 0xFFFFECA0..0xFFFFECAF | AHCIIO (cmd alloc + I/O submit) | M6-001, M6-002, M6-003 | `drivers/ahci/cmd_alloc.pdx`, `drivers/ahci/io_submit.pdx` |
| 0xFFFFECB0..0xFFFFECBF | AHCIREL + AHCIHP (flush/trim + hotplug) | M6-004..M6-006 | `drivers/ahci/reliability.pdx`, `drivers/ahci/hotplug.pdx` |
| 0xFFFFECC0..0xFFFFECCF | BDEVU (unified tail + mint split + dispatch) | M7-001..M7-004 | `cap/blkdev_cap.pdx`, `cap/cap_handler_blkdev.pdx` |
| 0xFFFFECD0..0xFFFFECDF | BDEVFS (FS-side bdev_write) | M7-005 | `fs/pdxfs/bdev_write.pdx` |
| 0xFFFFECE0..0xFFFFECEF | MOUNTW (mount/journal/remount/hot-remove witnesses) | M8-001..M8-003, M8-005 | `cap/blkdev_cap_request.pdx` + witnesses |
| 0xFFFFECF0..0xFFFFECFF | MOUNTW extended (soak + HW witness) | M8-004, M8-006 | witness-side codes |

**Left free for R52 (softarch):** `0xFFFFED00..0xFFFFEDFF` (16
subbands, ample for R52's KIND_VOLUME, KIND_BLOCK_CACHE,
KIND_INODE_HANDLE, KIND_SIG_KEY, plus mkfs/allocator/replay/
cache subsystems).

Every failure-code constant defined in an M6-M8 commit cites its
band in the file header (`Failure taxonomy. 0xFFFFECA0..0xFFFFECAF,
disjoint band.` — matching the PFF precedent at line 103 of
`kind_pdxfs_file.pdx`).

---

## 8. Per-issue implementation order + dependencies

### 8.1 Topological order across M6-M8

The 18 issues admit a partial order; the columns below give one
correct linearisation. Where two issues are order-independent, the
issue with the lower number is listed first for tidiness.

| Rank | Issue | Milestone | Blocking upstream (within M6-M8) |
|:-----|:------|:----------|:-------------------------------|
| 1 | #1663 M6-001 | M6 | (R51.M5 close is external) |
| 2 | #1664 M6-002 | M6 | #1663 |
| 3 | #1665 M6-003 | M6 | #1663, #1664 |
| 4 | #1666 M6-004 | M6 | #1663, #1665 |
| 5 | #1667 M6-005 | M6 | #1666 |
| 6 | #1668 M6-006 | M6 | #1663..#1667 |
| 7 | #1669 M7-001 | M7 | (none within tail; needs R51.M1..M5 rows to exist) |
| 8 | #1670 M7-002 | M7 | #1669 |
| 9 | #1671 M7-003 | M7 | #1669, #1670 |
| 10 | #1672 M7-004 | M7 | #1669..#1671, #1664..#1667 |
| 11 | #1673 M7-005 | M7 | #1672 |
| 12 | #1674 M7-006 | M7 | #1671, #1672, #1673, #1668 |
| 13 | #1675 M8-001 | M8 | every M7 issue |
| 14 | #1676 M8-002 | M8 | #1675 |
| 15 | #1677 M8-003 | M8 | #1676 (and softarch R52.M5-003 for the on-disk WAL walker) |
| 16 | #1678 M8-004 | M8 | #1677 |
| 17 | #1679 M8-005 | M8 | #1676, #1668 |
| 18 | #1680 M8-006 | M8 | #1677, #1678 |

### 8.2 Cross-milestone dependencies

- **M6 → M7-004.** M7-004 collapses the per-op `if family == AHCI`
  guards M6 sprinkled through the handler. It cannot land before
  M6-002..M6-005 have carved out the AHCI backends.
- **M7-001 → M7-002 → M7-003 → M7-004.** Strict serial: rights
  live in the extended tail; mint checks rights against the tail;
  the handler reads the tail's family byte to dispatch.
- **M7-005 → M8-*.** Every M8 issue drives PdxFS through the
  renamed `bdev_write.pdx`; if the rename slips, M8 tests still
  compile against `nvme_write.pdx` and cannot exercise AHCI.
- **M7-006 → nothing.** The cross-family witness is self-contained
  once every prior M7 issue is landed; nothing in M8 waits on its
  fingerprint to be stamped.
- **M6-006 → M8-005.** Hot-remove-under-write for AHCI requires
  the port-hot-plug wire to exist. NVMe hot-remove goes through
  R29 PCIe surprise-remove (already landed).
- **R52 gates in M8-001 and M8-003.**
  - M8-001 wires the userspace mount tool through `KIND_BLKDEV`.
    The tool itself is R52.M2-003 (`mkfs.pdxfs`) + R52.M5-005
    (mount backend). If R52.M5-005 has not landed, M8-001 lands
    against a synthetic caller (a smoke harness); the fingerprint
    is re-stamped when R52.M5-005 arrives.
  - M8-003 depends on R52.M5-003 (`journal_replay.pdx` on-disk
    walker). If R52.M5-003 slips, M8-003 stays open pending its
    close; the M8 fingerprint set is incomplete until then.
  - M8-005 (hot-remove) does NOT depend on R52 — its assertion is
    about the R51-side revoke cascade and the `bdev_write.pdx`
    EIO translation, both of which are R51-native.

### 8.3 Recommended parallel lanes

Given the graph, the round can execute in three concurrent lanes
once M6-001 lands:

- **Lane A (M6 core writer, ~5 issues).** #1663 → #1664 → #1665 →
  #1666 → #1667 (single reviewer; each issue takes 1-2 commits).
- **Lane B (M6 hot-plug, 1 issue).** #1668 waits on #1667 but
  needs no other lane; a second reviewer can open on it as soon
  as #1667 merges.
- **Lane C (M7 unified, 6 issues; opens as soon as M6 is done).**
  #1669..#1674 strictly serial per §8.1.

M8 opens after M7-005 lands; #1675..#1680 execute serially since
each builds on the prior sequence's fingerprint.

---

## 9. Open questions for main

1. **`BD_OP_*` alias longevity.** M7-004 lands an alias module to
   let R52 code compile without renaming. §5.3 puts its retirement
   at R53 open. If main wants R52 to rename to `BDEV_OP_*` in-
   round instead, drop the alias and file R52-facing rename
   issues; the round-open cost is ~10 file touches in R52 code.

2. **`BDEV_OP_QUERY_GEOM_EXT` naming.** §3.1 introduces a wide
   variant returning the descriptor-page pack. If main prefers a
   flag bit (`op_arg[16]` = extended) rather than a new opcode,
   the M7-004 wiring can carry either. Current preference: new
   opcode (7 → 8) for clarity; the op-arg flag-bit alternative
   fits the M3 header's op-arg encoding but hides the extension
   from grep.

3. **Hot-remove-during-write on real HW at M8-006.** M8-006 lands
   the mount+flush+remount fingerprint but NOT the hot-remove
   scenario. Pulling an internal NVMe device on a real T14 G4 is a
   destructive test (there is no PCIe hot-swap slot; the risk is
   an unclean shutdown of the developer's laptop). Recommendation:
   defer to a manual QA pass, not a golden.

4. **AHCI Command Table per-slot vs per-port.** §2.1 (M6-001)
   documents one Command Table per port. A future expansion to
   32-way in-flight would need one Command Table per slot (32×128 B
   = 4 KiB per port). The `cmd_alloc_v2.pdx` swap-in point is
   documented; the round-open cost of doing it at R51 is small
   but wastes memory for the T14 G4 scenario (0 AHCI ports).
   Recommendation: land the per-port form now; revisit if a real
   workload exceeds one in-flight command per port.
