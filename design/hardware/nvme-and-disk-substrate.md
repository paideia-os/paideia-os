# NVMe + Legacy-Disk (SATA/AHCI) Hardware Substrate

**Status.**  Draft v0.1 (osarch half of the R51 planning wave, 2026-08-21).
**Companion (parallel).**  softarch's FS / volume-manager plan (same
round, extends this document at §5 and inserts §9+ per its own scope).
**Depends on.**
- R24 NVMe scaffolding at `src/kernel/core/drivers/nvme/`
  (regs / queue / doorbell / prp / identify / dispatch / io_queue / irq
  / mdts / errors) — landed at #887..#908.
- R24.M5-003 `KIND_BLKDEV = 0x42` mint gate at
  `src/kernel/core/cap/blkdev_cap.pdx` (#905).
- R29.M1 `KIND_HW_INTERRUPT = 0x140` + `KIND_HW_MSIX_VECTOR = 0x141`
  (#1019, #1022) — the MSI-X allocation substrate this round wires.
- R29.M5-001 `KIND_DMA_DOMAIN = 0x142` (#1036) — the per-driver-process
  IOMMU-context cap this round's read/write paths transact against.
- R35.M4 `KIND_DMA_ATTESTATION = 0x16E` (#1210) — the consent record
  the mint gate for a bus-mastering namespace/port cap consults.
- R42 PdxFS v1 kernel path at `src/kernel/core/fs/pdxfs/`, in
  particular `nvme_write.pdx` (#1396) + `durability.pdx` (#1397) —
  the FS layer this substrate ships blocks under.
- `design/drivers/blkdev-cap.md` (R24.M5) — the existing rights model
  this round preserves and extends.
- `design/hardware/t14-g4-first-boot.md` — the T14 G4 posture the
  smoke matrix inherits.
**Scope of this doc.**  §1–§8 as scoped in the round brief.  softarch
adds §5.softarch (per-tool/service milestone breakdown) and §9+ (VFS
integration, mount semantics, allocator, journal shape).  Everything
below the block-device wire (BDEV_OP_*) is HW; everything above is FS
— the two halves meet at §4.

---

## 0. Reading order

- §1 substrate scope + relationship to R35 (IOMMU), R36 (display),
  R38 (deferred), R42 (PdxFS v1), R48 (user mgmt), R49/R50 (tooling).
- §2 NVMe driver — the promotion of the R24 scaffolding to a full
  driver: probe, admin queue, IDENTIFY, per-CPU I/O queues, MSI-X
  wire, READ/WRITE/FLUSH/TRIM, timeouts, hot-plug, queue reset.
- §3 AHCI / SATA driver — new-from-scratch, ABAR + port enumeration
  + FIS discipline + PRDT + LBA48 R/W + hot-plug.
- §4 Unified `KIND_BLOCK_DEVICE` — reconciled with the existing
  `KIND_BLKDEV = 0x42`; ops, tail, family-family derivation graph.
- §5 DMA + IOMMU discipline — how each device family transacts
  through `KIND_DMA_DOMAIN`, when a bounce buffer materialises,
  scatter-gather contract, alignment invariants.
- §6 KIND ordinal allocations — five new tags in the 0x198..0x19B
  band, one reused (`KIND_BLKDEV = 0x42`), softarch's reserved
  window 0x19C..0x1A7.
- §7 R51 milestone breakdown — M1..M8, one commit-scale chunk each,
  with 4–6 issue titles per milestone.
- §8 paideia-as cross-repo dependency map — the encoder gaps this
  substrate exposes.

---

## 1. Scope + relationship to adjacent rounds

R51 is the round that turns the R24 NVMe scaffolding — mint-gated but
never wired end-to-end into a namespace-serving driver — and the (as
yet non-existent) AHCI driver into a **unified block-device
substrate**: the abstraction that R42 PdxFS v1 mounts against on real
hardware and that R49/R50 coreutils (`ls`, `cp`, …) can therefore
touch.

The relationship to nearby rounds is:

| Round | Deliverable | R51 relies on it for | R51 supplies to it |
|:------|:------------|:--------------------|:--------------------|
| R24 (closed) | NVMe register/queue scaffold + `KIND_BLKDEV` mint gate | The whole PCIe/MMIO/PRP layer this round finishes wiring. | Nothing (R24 is upstream). |
| R29.M1 (closed) | `KIND_HW_INTERRUPT` + `KIND_HW_MSIX_VECTOR` | Per-queue MSI-X allocation for NVMe I/O queues + one shared vector for AHCI. | Real callers for the MSI-X allocator (previously exercised only by synthetic witnesses). |
| R29.M5 (closed) | `KIND_DMA_DOMAIN` per-driver-process IOMMU context | The bus-mastering PRDT/PRP transfers this round issues MUST cite a live domain cap. | The first non-network DMA consumer at scale — R51.M8 exercises the domain-reach invariant on a mount+write+flush workload. |
| R35.M4 (closed) | `KIND_DMA_ATTESTATION` — user-consent record | The mint gate for `KIND_NVME_NAMESPACE` and `KIND_AHCI_PORT` consults an attestation row whose `iommu_domain_id` matches the driver's domain (bus-mastering peripheral → user must consent). | The first attestation cascade that reaches an *internal* peripheral rather than a hot-plugged dock (R35's original scope was Thunderbolt); the invariant generalises unchanged. |
| R36 (display, closed) | Not a direct dep. | Nothing. | Nothing (parallel HW substrate; the two share no dispatch code beyond `cap/invoke.pdx`). |
| R38 (deferred) | n/a | n/a — R38 was scoped elsewhere per the priority table. | n/a. |
| R42 (closed) | PdxFS v1 (CoW + WAL + snapshot + `nvme_write.pdx`) | The FS layer that mounts against this substrate; `nvme_write.pdx` is the *user* of the R51 unified block-device wire. | An `_ns_read_lba / _ns_write_lba / _ns_flush` contract R42 can call without knowing whether the underlying medium is NVMe or AHCI. |
| R48 (closed) | `KIND_USER = 0x190`, elevate protocol | The identity under which a mount is attempted; a mount cap-request goes through elevate if it crosses out of the invoker's subtree. | Nothing beyond the mount-request being audited. |
| R49/R50 (open) | Coreutils on top of PdxFS v1 | Not a direct dep on this substrate; consumes it transitively through the FS layer. | Nothing. |
| R51 (this round) | NVMe + AHCI + unified block device | — | The block-device abstraction PdxFS v1 already writes against (`nvme_write.pdx`) generalises to AHCI. |

**Where NVMe sits in the driver stack.**  A PCIe class-01/subclass-08
function (NVM Express controller).  PCI enumeration (already landed;
`src/kernel/core/pci/`) mints a `KIND_PCI_DEV` for it; the NVMe
supervisor derives `KIND_NVME_CONTROLLER` (§6) which authorises BAR0
MMIO + admin-queue + I/O-queue setup + MSI-X allocation.  Each namespace
the controller identifies mints a `KIND_NVME_NAMESPACE` (which is
simultaneously a `KIND_BLOCK_DEVICE` — see §4) that is what the FS
layer holds.

**Where AHCI sits.**  A PCIe class-01/subclass-06/prog-if-01 function
(AHCI 1.0+).  Same PCI enumeration path mints `KIND_PCI_DEV`; the AHCI
supervisor derives `KIND_AHCI_CONTROLLER` which authorises ABAR
(BAR5) MMIO + Ports Implemented enumeration + one shared MSI-X vector
per controller.  Each populated port mints `KIND_AHCI_PORT`, which is
also a `KIND_BLOCK_DEVICE`.

**Sharing at the FS interface.**  Both families expose the same
BDEV_OP_* op set (§4).  A KIND_BLOCK_DEVICE consumer NEVER knows
which family produced it — that is opaque behind the descriptor tail's
`family` byte, queryable only through `BDEV_OP_QUERY_FAMILY` for
diagnostic tooling.  This is the load-bearing property: PdxFS v1's
`nvme_write.pdx` becomes `block_write.pdx` and forgets it ever knew
about NVMe.

**Userspace surface.**  Ring-3 tooling (`mount`, `df`, `blkid`,
future `smart`) receives `KIND_BLOCK_DEVICE` caps.  The controller /
port / namespace caps stay confined to the supervisor process that
enumerated them.  This is the R29.M5 discipline generalised: the
authority to *reach* a bus-mastering window (controller cap) is not
the authority to *use* it (block cap); the split lets a userspace
mounter operate on a subset of the machine without holding the reset
authority for the controller as a whole.

---

## 2. NVMe driver

### 2.1 What R24 shipped, what R51 finishes

R24.M1–M6 landed:

- `regs.pdx` — CAP/VS/INTMS/INTMC/CC/CSTS/NSSR/AQA/ASQ/ACQ MMIO
  accessors per NVMe Base Spec 2.0 §3.1.
- `queue.pdx` — Admin SQ/CQ ring allocation, tail/head accounting.
- `doorbell.pdx` — MMIO doorbell writes (SQyTDBL / CQyHDBL) with the
  DSTRD-derived offset math.
- `prp.pdx` — Physical Region Pointer 1/2 encoding + PRP-list page
  layout for MDTS-sized transfers.
- `identify_ns.pdx` — CNS=0x00 (namespace) IDENTIFY submission +
  response parse; NSZE / NCAP / NUSE / LBAF[0] extraction.
- `dispatch.pdx` — Admin+I/O command submission with opcode/nsid/PRP
  packing.
- `io_queue.pdx` — I/O SQ/CQ ring allocation (fixture only).
- `irq.pdx` — IRQ handler stub; MSI-X wire-up NOT wired.
- `mdts.pdx` — MDTS-derived max transfer chunk bound.
- `errors.pdx` — Status-field decode → typed error names.
- `KIND_BLKDEV = 0x42` mint gate (`cap/blkdev_cap.pdx`).

What is **not** landed and is R51's substance:

1. **Controller-cap mint gate.**  There is no `KIND_NVME_CONTROLLER`
   today — R24 minted `KIND_BLKDEV` directly from the enumerator.  §6
   introduces the controller cap so the controller's reset-authority
   is a separable capability from any namespace's I/O authority.
2. **Full probe path.**  R24's probe is `probe.pdx` up to
   `nvme_ns_list`; the wiring from `pci_enumerator` through cap-mint
   through admin-queue-enable to a driver-process-visible controller
   cap is R51.M1.
3. **Per-CPU I/O queues + MSI-X wiring.**  R24 allocates one I/O
   queue as a fixture; R51.M3 allocates one SQ/CQ pair per CPU and
   binds each CQ to a distinct `KIND_HW_MSIX_VECTOR` (R29.M1-004).
4. **FLUSH + TRIM (DATASET_MANAGEMENT).**  R24 has no cache-flush or
   TRIM op; R51.M4 lands both (FLUSH opcode 0x00, DSM opcode 0x09
   with `deallocate` bit).
5. **ASYNC_EVENT_REQUEST + GET_LOG_PAGE.**  For controller-fatal /
   namespace-attach-notice / SMART-log delivery.  R51.M4.
6. **Error recovery + queue reset.**  Command-timeout handling
   (CC.EN toggle → CSTS.RDY re-observation → queue-tail replay),
   Controller Fatal Status detection with subsystem-reset (NSSR)
   escalation.  R51.M4.
7. **Namespace-attach / detach hot events.**  A namespace being
   removed live must revoke every downstream `KIND_NVME_NAMESPACE`
   (and hence `KIND_BLOCK_DEVICE`) sharing that `(controller_idx,
   nsid)` — the R25+ hot-plug work `design/drivers/blkdev-cap.md`
   §3 flagged as TBD.  R51.M4 wires this cascade.

### 2.2 Admin queue

- **Allocation.**  4 KiB SQ (64 entries × 64 B), 4 KiB CQ (64 entries
  × 16 B), both page-aligned + physically contiguous + DMA-coherent
  (allocated through the driver process's `KIND_DMA_DOMAIN` so the
  IOMMU sees them; §5).
- **Programming.**  AQA ← (63 | 63<<16); ASQ ← phys(sq); ACQ ← phys(cq);
  CC.MPS ← host-page-size log2 − 12; CC.IOSQES/IOCQES ← 6/4; CC.CSS ←
  0 (NVM command set); CC.EN ← 1; poll CSTS.RDY until 1 or timeout
  (CAP.TO × 500 ms).  All of this lives in the driver process — the
  kernel exposes only the MMIO write cap and the DMA domain cap.
- **Commands issued at bring-up.**
  - `IDENTIFY` (0x06) CNS=0x01 (controller) — reads MDTS, ONCS
    (FLUSH/DSM support bits), NN (number of namespaces), CQES/SQES
    entry sizes.  Row cached at `_nvme_controller_table[idx]`.
  - `IDENTIFY` (0x06) CNS=0x02 (active namespace list) — enumerates
    up to `NN` NSIDs.
  - `SET_FEATURES` (0x09) FID=0x07 (Number of Queues) — negotiate
    `#CPU` submission + completion queues.
  - `CREATE_IO_CQ` (0x05) once per CPU — pass MSI-X vector index in
    CDW11[31:16], PC (physically contiguous) bit set.
  - `CREATE_IO_SQ` (0x01) once per CPU — pass CQ id, priority,
    physical address.
  - `ASYNC_EVENT_REQUEST` (0x0C) — up to 4 in-flight, refilled on
    completion.  Completions surface into a driver-side `evt_ring`
    and are dispatched to a `KIND_IPC_ENDPOINT` the supervisor
    subscribed on.

### 2.3 I/O commands (NVM command set)

The three that matter for R42 PdxFS v1 first-hardware boot:

- `READ` (opcode 0x02).  `NSID` names the namespace; `SLBA` (starting
  logical block) in CDW10/CDW11; `NLB` (number of logical blocks, 0-
  based) in CDW12[15:0]; PRP1/PRP2 point at the DMA buffer(s).
- `WRITE` (opcode 0x01).  Same layout; direction reversed.
- `FLUSH` (opcode 0x00).  No PRP; forces persistent-media commit of
  every prior write on the specified namespace.  R42.M5-002
  `durability.pdx` calls this from the FS-layer barrier primitive.

The two that matter for space reclamation:

- `DATASET_MANAGEMENT` (opcode 0x09) with the `deallocate` (AD) bit
  in CDW11[2].  Sends up to 256 LBA ranges per invocation via a PRP-
  pointed 16 B/range descriptor list.  Landed at R51.M4.
- `WRITE_ZEROES` (opcode 0x08) — optional, only wired if ONCS[3]
  reports support; a fast-path for zero-fill that most drives can
  serve without media traffic.  Landed at R51.M4 gated on ONCS.

### 2.4 Namespaces + KIND_NVME_NAMESPACE

Each active NSID enumerated by `IDENTIFY(CNS=0x02)` triggers a
namespace IDENTIFY (`CNS=0x00`) whose response gives NSZE (total
blocks), NCAP (allocated blocks), LBAF[FLBAS & 0xF] (LBA format —
`ds` field is log2 of block size, typically 9 or 12).  The driver
process then mints:

- One `KIND_NVME_NAMESPACE` (§6, tag 0x199) per namespace, bound to
  `(controller_idx, nsid, lba_size, block_count)`.
- Simultaneously — via the derivation graph of §4 — one
  `KIND_BLOCK_DEVICE` (`KIND_BLKDEV = 0x42` retained; §6) whose tail
  records `family = BDEV_FAMILY_NVME` and `(controller_idx, nsid)`.

The mint-gate cascade is:

```
KIND_PCI_DEV (from pci_enumerator)
   -> KIND_NVME_CONTROLLER (driver acquires reset authority for the function)
        -> KIND_NVME_NAMESPACE (one per active NSID, derived over KIND_BLKDEV)
```

`KIND_NVME_NAMESPACE` is BOTH a namespace-authority cap AND a
block-device cap by structural derivation — the tail is a superset of
`KIND_BLOCK_DEVICE`'s tail, so `cap_invoke_dispatch` can route it
through either handler on the same descriptor.  This is the same
pattern `KIND_OP_REGION` uses for its two-base derivation (kind.pdx
§KIND_OP_REGION).

### 2.5 MSI-X vector allocation

Per-CPU I/O queue → distinct MSI-X vector.  Allocation flow:

1. Driver process holds `KIND_HW_INTERRUPT` for the NVMe function
   (minted from the PCI enumerator's affinity + edge/level fields).
2. Driver mints N `KIND_HW_MSIX_VECTOR` children — one per I/O queue
   — via `msix_cap_mint(parent, table_offset, data, address)`.  The
   R29.M1-004 mint gate refuses if the same `(table_offset, data)`
   pair is already live (`MSIX_MINT_IN_USE`).
3. `CREATE_IO_CQ` command carries the vector index in CDW11[31:16];
   NVMe wire.
4. Driver's userspace IRQ thread sits on
   `endpoint_recv(msix_notification_endpoint)` and drains the CQ
   until head == tail on each wake.

The revoke cascade already implemented at R29.M1-004 (`hw_int_cap_revoke`
calls `msix_cascade_revoke_by_parent`) means tearing down the
interrupt cap tears down every MSI-X vector, which the driver
observes as `endpoint_recv → EPERM` and initiates its own queue
teardown — no dangling completion path.

### 2.6 Timeouts + error recovery + queue reset

- **Per-command timeout.**  Every submission stamps a wall-clock
  deadline (default: 30 s for I/O, 5 s for admin, both overridable via
  `SET_FEATURES(FID=0x0E)` "Host Behavior Support").  A dedicated
  watchdog thread scans the in-flight SQ tail table; on breach, the
  command's status is synthesised as `CMD_TIMEOUT` and the completion
  ring is fed a fake CQE with `SCT=0x3 SC=0x83` (Media and Data
  Integrity — Timeout).
- **Controller Fatal Status.**  CSTS.CFS observed → all in-flight
  commands synthesised as `CMD_ABORT` → driver executes a reset:
  CC.EN ← 0; poll CSTS.RDY == 0 (with CAP.TO deadline); if RDY did
  not clear, escalate to NSSR (write 0x4E564D65 to `NSSR`) — writes
  the whole subsystem, all namespaces revoked; `KIND_NVME_NAMESPACE`
  cascade fires.
- **Queue reset (per-queue, non-fatal).**  A single command timing
  out does NOT necessarily reset the controller.  The R51.M4 policy
  is: after 3 consecutive timeouts on ONE queue, delete-and-recreate
  that SQ/CQ pair (opcodes 0x00 DELETE_IO_SQ / 0x04 DELETE_IO_CQ,
  then 0x05 CREATE_IO_CQ / 0x01 CREATE_IO_SQ), rebinding the same
  MSI-X vector; only if the recreate itself fails do we escalate to
  controller reset.  This matches the Linux nvme driver's reset
  hierarchy.

### 2.7 What the R42 FS layer sees

`nvme_write.pdx` (R42.M5-001, #1396) is R51-legacy.  R51.M7 renames it
to `bdev_write.pdx` and re-routes it through the `KIND_BLOCK_DEVICE`
op set — the FS layer stops naming NVMe.  The wire equivalence is:

| R42 name | R51 name | Op |
|:---------|:---------|:---|
| `nvme_write_sync(nsid, lba, len, buf)` | `bdev_write_sync(bdev, lba, len, buf)` | `BDEV_OP_WRITE_LBA` |
| `nvme_read_sync(nsid, lba, len, buf)` | `bdev_read_sync(bdev, lba, len, buf)` | `BDEV_OP_READ_LBA` |
| (implicit — R42 assumes NVMe FLUSH) | `bdev_flush(bdev)` | `BDEV_OP_FLUSH` |

softarch's Round-2 §5 owns the FS-side rename plan.  This document's
obligation is only to guarantee the wire below the FS layer honours
those three ops through both families.

---

## 3. AHCI / SATA driver

### 3.1 Why AHCI at all

A T14 G4 exposes no rotational disk on its M.2 slot — the primary
volume is NVMe.  AHCI matters because:

- Development targets (QEMU + `-drive if=none,file=disk.img,id=d0
  -device ahci,id=ahci -device ide-hd,drive=d0,bus=ahci.0`) expose
  AHCI first-class; smoke matrix acceleration depends on it.
- The **portable installer image** (`design/hardware/t14-g4-first-boot.md`
  §1 output) is written to a USB stick — a UAS device that presents
  as SCSI, not AHCI, so this section is not about that path.  But a
  bootable optical drive, an eSATA dock, or an internal SATA SSD on
  older hardware all remain in scope, and the ecosystem cost of the
  driver is small once the block-device abstraction is in place.
- Deferring AHCI would make PdxFS v1's cross-family invariants
  (§4) unexercised — the abstraction is only load-bearing when
  there are two producers.

### 3.2 Probe + ABAR

PCI class-01, subclass-06, prog-if 01 → AHCI 1.0+.  The AHCI
supervisor's mint of `KIND_AHCI_CONTROLLER` (§6) authorises BAR5
(the "ABAR" — AHCI Base Address Register).  MMIO layout per Intel
AHCI 1.3.1 §3.1:

- 0x00 CAP — HBA capabilities (NP, NCS, PSC, SSC, S64A, SNCQ, PMD,
  FBSS, SPM, SAM, ISS, SCLO, SXS).
- 0x04 GHC — Global HBA Control (AE, IE, HR, MRSM).
- 0x08 IS  — Interrupt status (bit N = port N raised).
- 0x0C PI  — Ports Implemented (bitmask of live port indices).
- 0x10 VS  — Version.
- 0x14 CCC_CTL — Command Completion Coalescing (unused at R51).
- 0x100 + 0x80×N — per-port register block (see §3.4).

Bring-up:

1. GHC.AE ← 1 (enable AHCI mode; legacy IDE emulation off).
2. GHC.HR ← 1 → poll until 0 (HBA reset).
3. GHC.AE ← 1 again (HR cleared it).
4. Read PI, iterate over set bits.

### 3.3 MSI-X

AHCI 1.3 §5.6 gives a controller ONE (or MSI-X pinned) interrupt
vector shared across all ports.  R51 wires one `KIND_HW_MSIX_VECTOR`
per controller (contrast: NVMe has one per queue = one per CPU).
The IRQ handler reads AHCI IS, iterates over set bits, dispatches
per-port completion drain.

### 3.4 Port bring-up + FIS discipline

Per active port (PI bit set):

- 0x00 CLB / 0x04 CLBU — Command List Base (256 B aligned, 1 KiB
  region: 32 command headers × 32 B).
- 0x08 FB  / 0x0C FBU  — Received-FIS Base (256 B, per FIS type
  slots).
- 0x10 IS  — Port interrupt status.
- 0x14 IE  — Port interrupt enable.
- 0x18 CMD — Port command (ST, SUD, POD, CLO, FR, FRE, CCS, ICC,
  MPSS, PMA, ATAPI, DLAE, ALPE, ASP, ESP).
- 0x20 TFD — Task File Data.
- 0x24 SIG — Device signature (0x00000101=ATA, 0xEB140101=ATAPI,
  0xC33C0101=SEMB, 0x96690101=PM).
- 0x28 SSTS — SATA status (DET, SPD, IPM).
- 0x30 SERR — SATA error.
- 0x38 CI  — Command Issue.

Order:

1. Clear ST, wait CR==0, clear FRE, wait FR==0 (idle port).
2. Allocate 1 KiB command list + 256 B FIS receive; write CLB/FB.
3. Set FRE, then ST.
4. Read SIG — if 0x00000101 the device is ATA (SATA disk).
5. Issue `IDENTIFY DEVICE` (opcode 0xEC) via a command slot: build
   an H2D Register FIS (FIS type 0x27, C=1, command=0xEC), point the
   PRDT at a 512-byte response buffer, set CI bit for the slot.
6. Wait for CI bit to clear + Task File D bit to clear.
7. Parse IDENTIFY response: word 60/61 = LBA28 addressable count;
   word 83/86 = LBA48 support bit; word 100..103 = LBA48 count;
   word 106 = logical/physical sector layout.

FIS types the R51.M6 driver actually emits:

- 0x27 (Register — Host to Device) — every command.
- 0x34 (Register — Device to Host) — every completion.
- 0x41 (DMA Setup) — DMA activation; the driver only reads it.
- 0x39 (Set Device Bits) — status/error/interrupt on completion.
- 0x5F (PIO Setup) — never issued (PIO transfers only used for
  IDENTIFY responses at bring-up; even those use DMA on most modern
  ports).

### 3.5 Command list + PRDT

Command header (32 B):

- +0 dw0: `CFL[4:0]` (Command FIS Length in dwords), `A` (ATAPI),
  `W` (write), `P` (prefetchable), `R` (reset), `B` (BIST), `C`
  (clear on OK), `PMP[15:12]` (port multiplier port).  Upper 16 bits:
  `PRDTL` (PRDT length in entries).
- +4 dw1: PRDBC (PRD byte count actually transferred; device writes).
- +8/+12: CTBA/CTBAU — Command Table Base Address (128 B aligned).
- +16..+31: reserved.

Command Table:

- +0..+63:   Command FIS (host-to-device H2D Register FIS, ≤ 64 B).
- +64..+79:  ATAPI command (unused for SATA disk).
- +80..+127: reserved.
- +128..:    PRDT — up to 65535 entries × 16 B.

PRD entry (16 B):

- +0/+4: DBA / DBAU — data base address (2 B aligned).
- +8:    reserved.
- +12:   `I` (interrupt on completion), `DBC[21:0]` (byte count − 1,
  max 4 MiB per entry, must be even).

### 3.6 LBA48 R/W + FLUSH

Post-IDENTIFY, if word-83 bit-10 = 1, LBA48 is supported.  The three
commands R51.M6 uses:

- `READ_DMA_EXT` (0x25).  H2D FIS: command=0x25, device=0x40 (LBA
  mode); LBA[47:0] split across LBA(low/mid/high) + LBA(exp low/mid/
  high); count=NSECTOR (0 → 65536, 0xFFFF → 65535).  Data via PRDT.
- `WRITE_DMA_EXT` (0x35).  Same layout; header W bit = 1.
- `FLUSH_CACHE_EXT` (0xEA).  No PRDT.  Forces device write cache to
  persistent media — the AHCI equivalent of NVMe FLUSH; R42
  `durability.pdx` reaches it through `BDEV_OP_FLUSH`.

TRIM on AHCI: `DATA_SET_MANAGEMENT` (0x06) with the TRIM feature bit
in the LBA range descriptor.  Optional per IDENTIFY word-169 bit-0
(DRAT).  R51 gates the op on that bit; when absent, `BDEV_OP_TRIM`
returns `BDEV_ERR_UNSUPPORTED` and softarch's allocator must not
depend on it.

### 3.7 Hot-plug

AHCI SUpports port-level hot-plug via CMD.PMA + PxIS.PCS/PRCS bits
(present change / phy-ready change).  R51.M6 handles the staging
lifecycle:

1. PxIS.PCS = 1 → SSTS.DET is re-read.
2. If DET = 3 (device present, phy established) → new device →
   re-run bring-up (§3.4 steps 4–7) → mint new `KIND_AHCI_PORT` +
   downstream `KIND_BLOCK_DEVICE`.
3. If DET = 0 (no device) → revoke the port's `KIND_AHCI_PORT`
   cascade → clear PxIS.PCS.
4. PxSERR error bits require the standard debounce (`SERR ← ~0` after
   the transition sinks in) or the port stays interrupt-storming.

Hot-plug on NVMe is a PCIe surprise-remove — handled by the R29
PCIe hot-plug substrate already, and the revoke of the parent
`KIND_PCI_DEV` cascades to `KIND_NVME_CONTROLLER` → `KIND_NVME_NAMESPACE`
→ `KIND_BLOCK_DEVICE` through the existing revoke tree.  No new AHCI-
specific code is needed for that path.

---

## 4. Unified `KIND_BLOCK_DEVICE` abstraction

### 4.1 Reconciliation with the existing `KIND_BLKDEV = 0x42`

The R24 substrate landed `KIND_BLKDEV = 0x42` (`cap/blkdev_cap.pdx`,
`design/drivers/blkdev-cap.md`).  It was minted only from NVMe, was
per-namespace, and never wired end-to-end.

**R51 keeps the tag `0x42` unchanged** — the same feedback that
governs `KIND_MEMORY == KIND_PAGE` (`kind.pdx` §KIND_MEMORY: "This is
an alias, NOT a new base kind: the closed 16-kind enum is unchanged")
applies here at the derived-kind layer.  `KIND_BLKDEV` becomes THE
`KIND_BLOCK_DEVICE`.  The doc name `KIND_BLOCK_DEVICE` is a
design-time synonym for readability; the codebase spells it
`KIND_BLKDEV` and no rename is required.

Forking would break:

- `src/kernel/core/cap/blkdev_cap.pdx` (mint gate).
- `src/kernel/core/fs/pdxfs_lite/mount.pdx` + `mount_op.pdx` (they
  already reference `KIND_BLKDEV`).
- The R42 `nvme_write.pdx` path (implicitly built on it).

What CHANGES about `KIND_BLKDEV` at R51:

1. The tail grows a `family : u8` byte (§4.3) so the same descriptor
   can name a namespace or a port.
2. Mint gate accepts a `parent_kind` argument and refuses if it is
   not one of `KIND_NVME_NAMESPACE` or `KIND_AHCI_PORT` — no
   direct-from-controller minting (a controller cap is NOT a block
   cap; NVMe multi-namespace and AHCI multi-port make the
   distinction load-bearing).
3. Rights add `R_BLK_FLUSH` (bit 3) and `R_BLK_TRIM` (bit 4).  Old
   holders of `R_BLK_ALL = 0x07` continue to work — they lose no
   authority — but new mints intended for FS use request
   `R_BLK_ALL_R51 = 0x1F`.
4. `blkdev_cap_mint` is superseded by two mint entry points, one per
   family; the R24-era three-arg mint stays as a compat shim that
   packs into the new tail with `family = BDEV_FAMILY_LEGACY_NVME`.

### 4.2 Op set (`BDEV_OP_*`)

`cap_handler_blkdev` in `blkdev_cap.pdx` dispatches on
`op_arg[7:0]`:

| Op code | Name | rdi/rsi/rdx | Rights required | Result |
|:---------|:-----|:------------|:----------------|:-------|
| 0 | `BDEV_OP_QUERY_GEOM` | (none) | any non-zero | packs `{lba_size, block_count}` into rax |
| 1 | `BDEV_OP_QUERY_FAMILY` | (none) | any non-zero | rax = `family:u8` (NVME=1, AHCI=2, LEGACY_NVME=0) |
| 2 | `BDEV_OP_QUERY_FEATURES` | (none) | any non-zero | rax = feature bitmap (bit 0: FLUSH; 1: TRIM; 2: WRITE_ZEROES; 3: WRITE_CACHE_PRESENT) |
| 3 | `BDEV_OP_READ_LBA`  | rdi=lba, rsi=nblocks, rdx=dma_addr | `R_BLK_READ`  | rax = bytes read, or `BDEV_ERR_*` |
| 4 | `BDEV_OP_WRITE_LBA` | rdi=lba, rsi=nblocks, rdx=dma_addr | `R_BLK_WRITE` | rax = bytes written |
| 5 | `BDEV_OP_FLUSH`     | (none) | `R_BLK_FLUSH` | rax = 0 on OK |
| 6 | `BDEV_OP_TRIM`      | rdi=dsm_descriptor_dma, rsi=range_count | `R_BLK_TRIM` | rax = 0 on OK, `BDEV_ERR_UNSUPPORTED` if the device does not advertise it |

`rdx=dma_addr` is a **physical address in the driver-process
`KIND_DMA_DOMAIN`** — i.e. an IOVA the IOMMU maps to the caller's
scatter-gather region.  The handler does not walk it; the driver
proces already wrote the mapping (via `KIND_DMA_DOMAIN` invoke ops,
R29.M5) before issuing the block op.  §5 covers the discipline.

### 4.3 Descriptor tail (extended from R24's 32 B)

Preserved fields (offsets 0..31 unchanged for R24 compat):

| Offset | Size | Field | Notes |
|:-------|:-----|:------|:------|
| 0  | 1 | controller_idx | R24 spec — driver-family-specific table index |
| 1  | 1 | _pad0 | R24 |
| 2  | 2 | _pad1 | R24 |
| 4  | 4 | nsid_or_port | R24 spec was `nsid`; R51 overloads: NVMe → nsid, AHCI → port_index |
| 8  | 4 | lba_size | R24 |
| 12 | 4 | _pad2 | R24 |
| 16 | 8 | block_count | R24 |
| 24 | 4 | rights | R24; low 5 bits used |
| 28 | 4 | _pad3 | R24 |

Extended R51 fields (offsets 32..63; row indirection via
`_blkdev_row_table`):

| Offset | Size | Field | Notes |
|:-------|:-----|:------|:------|
| 32 | 1 | family | 0=LEGACY_NVME (R24 mint), 1=NVME, 2=AHCI |
| 33 | 1 | features | bit 0 FLUSH, 1 TRIM, 2 WRITE_ZEROES, 3 WRITE_CACHE_PRESENT |
| 34 | 2 | max_transfer_blocks | derived from MDTS (NVMe) or PRDT×512 (AHCI) |
| 36 | 4 | dma_domain_slot | the driver-process KIND_DMA_DOMAIN cap slot (0..255) this cap is scoped to |
| 40 | 4 | parent_slot | KIND_NVME_NAMESPACE or KIND_AHCI_PORT slot the cap was derived from |
| 44 | 4 | attest_key | KIND_DMA_ATTESTATION.attest_key that consented to this device's DMA reach (§5.4) |
| 48 | 16 | reserved | zero |

Total tail: 64 B.  Row indirection: `target_ptr[15:0]` = row id in
`_blkdev_row_table`; the ≤32 B R24 form remains readable via the
alias `_blkdev_legacy_view(row)`.

### 4.4 Derivation graph

```
KIND_PCI_DEV (0x30, R24)
   |
   +--> KIND_NVME_CONTROLLER (0x198, R51.M1)
   |       |
   |       +--> KIND_NVME_NAMESPACE (0x199, R51.M2)
   |               |
   |               +==> KIND_BLKDEV (0x42, R24; family=NVME) [DUAL-KIND: same descriptor]
   |
   +--> KIND_AHCI_CONTROLLER (0x19A, R51.M5)
           |
           +--> KIND_AHCI_PORT (0x19B, R51.M5)
                   |
                   +==> KIND_BLKDEV (0x42, R24; family=AHCI) [DUAL-KIND: same descriptor]
```

The `==>` edges are the same one `KIND_OP_REGION` uses at
`kind.pdx §KIND_OP_REGION`: one row in `_blkdev_row_table` is
reachable through two derived-kind tags.  `cap_invoke_dispatch`
compares the full u64 kind field, so the same descriptor slot can
be invoked via `KIND_NVME_NAMESPACE` (yields namespace-admin ops like
`NS_OP_ATTACH_LOG`) or via `KIND_BLKDEV` (yields BDEV_OP_*) without
another mint.

### 4.5 What softarch sees

softarch's parallel design owns everything *above* the BDEV wire.
The invariants this substrate guarantees to that layer:

- **A `KIND_BLKDEV` cap is opaque about medium.**  The `family` byte
  is queryable but shall not appear in any allocator, journal, or
  FS-tree decision.  Family-specific tuning lives in a driver-side
  policy table, not FS-side.
- **`(lba_size, block_count)` is invariant across the cap's
  lifetime.**  A live namespace/port never re-negotiates its geometry
  without a revoke-and-remint.  A `WRITE_LBA` that would go past
  `block_count` is refused before touching the wire.
- **`BDEV_OP_FLUSH` is a hard fence.**  When it returns 0, every
  prior `WRITE_LBA` on that cap is persistent.  softarch's WAL
  barrier + snapshot commit paths get to depend on this without
  further per-family reasoning.
- **`BDEV_OP_TRIM` may fail with `BDEV_ERR_UNSUPPORTED`.**  softarch's
  allocator MUST tolerate this; a device that does not advertise
  DRAT / DSM is fine, the FS just loses space-hint efficiency, not
  correctness.
- **`max_transfer_blocks` bounds a single op.**  A larger request
  is split by the driver, not the FS.  softarch's chunking logic
  operates on FS-level semantics (block group / extent / WAL frame),
  not on the wire limit.
- **DMA is the driver's problem.**  softarch never allocates a
  bounce buffer, never programs an IOMMU entry, never sees an IOVA.
  It hands the driver a scatter-gather list of caller-space physical
  pages (as `KIND_PAGE` handles carrying `RIGHT_READ | RIGHT_WRITE`)
  and the driver maps them into its own `KIND_DMA_DOMAIN` for the
  duration of the op.  See §5.

---

## 5. DMA + IOMMU discipline

### 5.1 The domain the driver holds

Per R29.M5 (`kind.pdx §KIND_DMA_DOMAIN`), each driver process owns
ONE `KIND_DMA_DOMAIN` capability — a per-driver-process IOMMU context
that names the set of physical pages the bus-mastering device is
authorised to reach.  R51 does not change this.  It DOES exercise
it end-to-end for the first time at scale: R29.M5 landed the
capability + mint gate + revoke cascade; R35.M4 landed the
attestation record; R51 is the first driver family to REGULARLY
program IOMMU entries at I/O rate rather than at driver-load time.

### 5.2 The map-per-op lifecycle

Per block op, the driver process:

1. Receives a scatter-gather list of `KIND_PAGE` handles from the
   FS layer (via IPC).  Each handle authorises the driver to read
   or write that page.
2. Calls `dma_domain_map(domain_slot, page_slot, iova_hint) → iova`
   on `KIND_DMA_DOMAIN` for each page.  The IOMMU context now has
   an entry.  IOVA is chosen from the domain's private allocator
   (per-process, disjoint from other drivers').
3. Encodes the resulting IOVAs into the wire structure — PRP1/PRP2
   + PRP-list page for NVMe, PRDT entries for AHCI.
4. Issues the command.
5. On completion: `dma_domain_unmap(domain_slot, iova)` for each
   page.  The IOMMU entry is invalidated (VT-d IOTLB flush required
   before the mapping is reused — R35 substrate).

The FS layer NEVER sees an IOVA.  The kernel NEVER sees a device
address on the syscall boundary.  This is the R29 IOMMU invariant
made routine.

### 5.3 When a bounce buffer materialises

A bounce buffer is needed only when:

- The FS-supplied page's physical address exceeds the device's
  addressability bound (NVMe: reported in `IDENTIFY` word range; AHCI:
  reported in HBA CAP.S64A bit — if clear, the device is 32-bit-only
  and any page above 4 GiB requires bouncing).
- Alignment is wrong: NVMe requires PRP entries to be at least
  `MPSMIN`-aligned; AHCI PRDT requires 2-byte alignment on any entry
  and 4-byte total transfer count.  A user-space page that is not
  page-aligned but the op requires page-aligned DMA implies a bounce.

Bounce buffers live in a per-driver-process page pool allocated from
`KIND_MEMORY` at driver load, mapped into the domain at load time,
and never surfaced past the driver.  Userspace never sees them.  The
FS layer sees only the completion, never the physical detour.

### 5.4 The consent gate for a bus-mastering peripheral

R35.M4 designed `KIND_DMA_ATTESTATION` (0x16E) as the record of user
consent for a bus-mastering Thunderbolt dock.  R51 generalises the
requirement to *every* bus-mastering peripheral — an internal NVMe
drive is technically the same threat model as a hot-plugged dock; the
only reason internal storage has historically been un-attested is a
policy choice, not a security one.

R51's discipline: `KIND_NVME_NAMESPACE` and `KIND_AHCI_PORT` mints
require an inherited `KIND_DMA_ATTESTATION` cap whose:

- `iommu_domain_id` matches the driver process's `KIND_DMA_DOMAIN`
  id — the same domain the driver's PRP/PRDT walks will program.
- `consent_state == GRANTED` at mint time.
- `dock_id` (semantically overloaded: at R51 it names the enumerator
  key that PCI probe registered for this function) matches the
  parent `KIND_NVME_CONTROLLER` / `KIND_AHCI_CONTROLLER`.

For internal NVMe on a fresh install, the attestation is granted at
first boot by the founder-user's initial-mount dialog (a policy the
R48 user-management substrate already carries via
`elevate_policy.pdx`).  The dialog is a one-time cost per install,
not per boot — the attestation record is persisted to
`/system/audit/user-events/` and re-verified on mount.

Consequence: a mount attempt from a NON-founder user against an
un-attested device fails at the mint gate with
`BLK_CAP_MINT_NO_ATTEST`, and the elevate broker surfaces the
attestation request to the founder.  This closes the class of attack
where a delegated user can attach an untested USB-SATA bridge and
DMA-scan host memory through the AHCI driver.

### 5.5 Alignment + scatter-gather contract

- **Read/write LBA counts** are always exact multiples of the
  device's `lba_size` — the FS layer sees `lba_size` from
  `BDEV_OP_QUERY_GEOM` and never issues an op smaller than one
  block.
- **DMA buffer alignment** is guaranteed page-aligned (`4 KiB` on
  x86_64) by the FS layer's page-cache; a sub-page tail scatter
  entry is handled by the driver's bounce path.
- **Scatter-gather list length** is bounded — for NVMe, MDTS (in
  units of `2^(12+MPSMIN)` bytes) divided by page size caps the
  entry count per op; for AHCI, PRDTL ≤ 65535 caps it independently.
  The driver splits when the FS's SG list exceeds the wire limit;
  softarch never observes the split.

---

## 6. KIND ordinal allocations

Last-allocated ordinal (per `src/kernel/core/cap/kind.pdx` §tail as
of 2026-08-21): `KIND_TTY = 0x197` (R30-PREP #1631).  Gaps at
`0x192..0x194` are reserved for R49/R50 (KIND_PACKAGE, KIND_SHELL,
KIND_TERMINAL_SESSION per §5 of `design/tooling/r49-r50-plan.md`).

R51 allocates FOUR new derived-kind tags in the `0x198..0x19B` band
and REUSES the existing `KIND_BLKDEV = 0x42` as the doc-level
`KIND_BLOCK_DEVICE` (see §4.1 for why).

| Kind | Value | Base kind | Round | Purpose | Cap seedable? |
|:-----|:------|:----------|:------|:--------|:--------------|
| `KIND_BLKDEV` (`KIND_BLOCK_DEVICE`) | **0x42** *(existing, R24)* | 4 (KIND_MEMORY) | R24 (R51 extends tail + rights) | Unified per-block-device authority; produced by NVMe and AHCI drivers. | No |
| `KIND_NVME_CONTROLLER` | **0x198** | 10 (KIND_DEVICE) | R51.M1 | Per-NVMe-function controller authority: BAR0 access, admin queue, reset. | No |
| `KIND_NVME_NAMESPACE` | **0x199** | 4 (KIND_MEMORY) *(dual-kind with KIND_BLKDEV)* | R51.M2 | Per-namespace authority; derives KIND_BLKDEV via same descriptor row. | No |
| `KIND_AHCI_CONTROLLER` | **0x19A** | 10 (KIND_DEVICE) | R51.M5 | Per-AHCI-function controller authority: ABAR access, GHC reset, PI enumeration. | No |
| `KIND_AHCI_PORT` | **0x19B** | 4 (KIND_MEMORY) *(dual-kind with KIND_BLKDEV)* | R51.M5 | Per-populated-port authority; derives KIND_BLKDEV via same descriptor row. | No |

**Reserved for softarch coordination:** `0x19C..0x1A7` (12 slots).
softarch's parallel design owns everything above the block-device
wire.  Suggested reservations for FS-layer KINDs softarch may need:

- `KIND_PDXFS_MOUNT` (proposed at `design/user/pdxfs-kinds.md` §3.3)
- `KIND_PDXFS_DIR` (§3.1 there)
- `KIND_PDXFS_SYMLINK` (§3.2 there)
- `KIND_PDXFS_SNAPSHOT` (§3.4 there)
- `KIND_VOLUME` (softarch may introduce for the volume manager layer)
- `KIND_VOLUME_MEMBER` (RAID/pool member sub-cap, if applicable)
- `KIND_FS_TXN_XDEV` (cross-device transaction, if the volume manager
  supports write-across-two-BDEVs atomicity)

That leaves `0x1A8+` free for later rounds.

### 6.1 Rights extension for `KIND_BLKDEV`

The R24 rights (`R_BLK_READ = 0x01`, `R_BLK_WRITE = 0x02`,
`R_BLK_ADMIN = 0x04`, `R_BLK_ALL = 0x07`) remain valid.  R51 adds:

- `R_BLK_FLUSH = 0x08` — authorises `BDEV_OP_FLUSH`.
- `R_BLK_TRIM  = 0x10` — authorises `BDEV_OP_TRIM`.
- `R_BLK_ALL_R51 = 0x1F`.

A holder minted under R24 (`R_BLK_ALL = 0x07`) can still `READ` /
`WRITE` / `ADMIN`.  It cannot `FLUSH` or `TRIM` — the mint gate
refuses to hand these rights to a caller whose parent cap does not
carry them.  R42 `nvme_write.pdx` MUST be re-minted with the new
rights when it is rewired to the unified wire (R51.M7).

### 6.2 Rights model for the four new kinds

- `KIND_NVME_CONTROLLER`: `R_NVMEC_MMIO | R_NVMEC_RESET | R_NVMEC_ADMIN | R_NVMEC_MINT_NS | R_NVMEC_OBSERVE = 0x1F`.
- `KIND_NVME_NAMESPACE`: `R_NVMEN_MINT_BLK | R_NVMEN_QUERY | R_NVMEN_ATTACH | R_NVMEN_DETACH = 0x0F`.
- `KIND_AHCI_CONTROLLER`: `R_AHCIC_MMIO | R_AHCIC_RESET | R_AHCIC_ENUM_PORTS | R_AHCIC_MINT_PORT = 0x0F`.
- `KIND_AHCI_PORT`: `R_AHCIP_MINT_BLK | R_AHCIP_QUERY | R_AHCIP_HOTPLUG_OBSERVE = 0x07`.

The MINT_BLK / MINT_NS / MINT_PORT rights are what enforce the
"controller cap is not a block cap" invariant: a driver process
holding `KIND_NVME_CONTROLLER` without `R_NVMEC_MINT_NS` cannot
mint namespace caps, and one holding a namespace cap without
`R_NVMEN_MINT_BLK` cannot mint block caps.  The R51 boot-time policy
grants `MINT_NS` and `MINT_BLK` to the NVMe supervisor; a downstream
FS mounter receives the block cap only.

### 6.3 Loader-seedable posture

**None** of the five kinds is loader-seedable.  Reasons match every
other bus-mastering kind in the tree:

- KIND_NVME_CONTROLLER: target_ptr is a row into `_nvme_controller_table`;
  a sidecar-seeded entry would claim a controller no PCI probe
  sanctioned.
- KIND_NVME_NAMESPACE / KIND_AHCI_PORT / KIND_BLKDEV: block_count is
  in the row; seeding would let a boot image claim any addressable
  range of any device.
- KIND_AHCI_CONTROLLER: same pattern; the ABAR handle would let a
  seeded entry name any MMIO window.

Every mint requires a live parent cap the enumerator produced.

---

## 7. R51 milestone breakdown

Eight commit-scale milestones.  M1..M4 own NVMe, M5..M6 own AHCI,
M7 unifies, M8 integrates with softarch's parallel FS work for the
first cross-family smoke.  Milestones M1..M4 and M5..M6 can run in
parallel once M1 opens.

### M1 — NVMe controller-cap mint + PCI probe wire-up

- R51.M1-001 KIND_NVME_CONTROLLER: mint gate + descriptor row + `_nvme_controller_table` (8 slots, matches BLK_CAP_CTRL_MAX)
- R51.M1-002 PCI probe hook: on class 01/subclass 08 match, mint KIND_NVME_CONTROLLER from parent KIND_PCI_DEV
- R51.M1-003 Admin SQ/CQ page allocation via KIND_DMA_DOMAIN; AQA/ASQ/ACQ programming; CC.EN → poll CSTS.RDY
- R51.M1-004 IDENTIFY(controller) CNS=0x01; cache MDTS/ONCS/NN into controller row
- R51.M1-005 SET_FEATURES(FID=0x07) queue-count negotiation; results cached
- R51.M1-006 Controller-cap revoke cascade: revoking KIND_NVME_CONTROLLER tears down every namespace row + every downstream KIND_BLKDEV

### M2 — NVMe namespace enumeration + KIND_NVME_NAMESPACE

- R51.M2-001 KIND_NVME_NAMESPACE: mint gate + descriptor row + `_nvme_namespace_table` (32 slots per controller)
- R51.M2-002 IDENTIFY(active namespace list) CNS=0x02; iterate NSIDs
- R51.M2-003 Per-NSID IDENTIFY(namespace) CNS=0x00; parse NSZE/NCAP/LBAF/FLBAS; validate DMA-attestation covers this domain
- R51.M2-004 Dual-kind mint: same row_id reachable via KIND_NVME_NAMESPACE (0x199) and KIND_BLKDEV (0x42); tail records family=NVME
- R51.M2-005 Namespace-revoke: revoke KIND_NVME_NAMESPACE → cascade-revoke matching KIND_BLKDEV rows
- R51.M2-006 Witness: probe a QEMU nvme controller with two namespaces, assert two KIND_BLKDEV rows produced with distinct geometry

### M3 — NVMe I/O queues + MSI-X + READ/WRITE bring-up

- R51.M3-001 MSI-X vector allocation loop: one KIND_HW_MSIX_VECTOR per CPU, bound to distinct table_offset/data
- R51.M3-002 CREATE_IO_CQ per CPU with MSI-X vector index in CDW11[31:16]; CREATE_IO_SQ per CPU pointing at its CQ
- R51.M3-003 BDEV_OP_READ_LBA: PRP1/PRP2/PRP-list encoding via `prp.pdx`, dispatch through per-CPU SQ, IRQ-driven completion drain
- R51.M3-004 BDEV_OP_WRITE_LBA: same shape as READ
- R51.M3-005 Per-CPU SQ round-robin submission when caller CPU has no bound queue (fallback + witness)
- R51.M3-006 Witness: 4 KiB single-block round-trip through KIND_BLKDEV against QEMU nvme; fingerprint on `tests/r51/nvme-io.golden`

### M4 — NVMe FLUSH + TRIM + error recovery + AER

- R51.M4-001 BDEV_OP_FLUSH: opcode 0x00 through admin queue path, gated on ONCS[0]; return `BDEV_ERR_UNSUPPORTED` when clear
- R51.M4-002 BDEV_OP_TRIM: DATASET_MANAGEMENT opcode 0x09 with AD bit; PRP-list range descriptor packing; gated on ONCS[2]
- R51.M4-003 ASYNC_EVENT_REQUEST refill loop: 4 in-flight, completions posted to a KIND_IPC_ENDPOINT the supervisor holds
- R51.M4-004 GET_LOG_PAGE opcode 0x02 for SMART/health (LID=0x02) and error-info (LID=0x01)
- R51.M4-005 Command timeout watchdog: per-op deadline, synth CQE on breach; 3-strike per-queue reset (delete+recreate SQ/CQ)
- R51.M4-006 Controller Fatal Status recovery: CC.EN toggle; NSSR escalation; namespace revoke cascade on subsystem reset

### M5 — AHCI controller-cap mint + port enumeration + KIND_AHCI_PORT

- R51.M5-001 KIND_AHCI_CONTROLLER: mint gate + descriptor row + `_ahci_controller_table` (4 slots)
- R51.M5-002 PCI probe hook: class 01/subclass 06/prog-if 01 → mint KIND_AHCI_CONTROLLER from KIND_PCI_DEV
- R51.M5-003 AHCI HBA reset (GHC.AE=1 → GHC.HR=1 → wait; re-set GHC.AE); PI enumeration
- R51.M5-004 KIND_AHCI_PORT: mint gate + descriptor row + `_ahci_port_table` (32 slots per controller)
- R51.M5-005 Per-port bring-up (CLB/FB alloc via KIND_DMA_DOMAIN, FRE/ST sequence, SIG read); IDENTIFY DEVICE H2D FIS + PIO response
- R51.M5-006 Dual-kind mint: same row_id reachable via KIND_AHCI_PORT (0x19B) and KIND_BLKDEV (0x42); tail records family=AHCI

### M6 — AHCI READ/WRITE/FLUSH via PRDT + hot-plug

- R51.M6-001 Command header + Command Table + PRDT allocation per-port (1 KiB + 128 B + variable PRDT)
- R51.M6-002 BDEV_OP_READ_LBA: READ_DMA_EXT (opcode 0x25) H2D FIS + PRDT scatter-gather encoding
- R51.M6-003 BDEV_OP_WRITE_LBA: WRITE_DMA_EXT (opcode 0x35)
- R51.M6-004 BDEV_OP_FLUSH: FLUSH_CACHE_EXT (opcode 0xEA); write cache present bit surfaced through BDEV_OP_QUERY_FEATURES
- R51.M6-005 BDEV_OP_TRIM: DATA_SET_MANAGEMENT (opcode 0x06) with TRIM feature bit, gated on IDENTIFY word-169 bit-0 (DRAT)
- R51.M6-006 Port hot-plug: PxIS.PCS + SSTS.DET debounce; mint/revoke KIND_AHCI_PORT + downstream KIND_BLKDEV on transition

### M7 — Unified KIND_BLOCK_DEVICE + FS-layer rename

- R51.M7-001 KIND_BLKDEV tail extension: 32 B → 64 B; family/features/max_transfer_blocks/dma_domain_slot/parent_slot/attest_key fields
- R51.M7-002 Rights extension: R_BLK_FLUSH (0x08) + R_BLK_TRIM (0x10); R_BLK_ALL_R51 (0x1F)
- R51.M7-003 blkdev_cap_mint → blkdev_cap_mint_from_nvme + blkdev_cap_mint_from_ahci; R24 mint retained as compat shim (family=LEGACY_NVME)
- R51.M7-004 cap_handler_blkdev: BDEV_OP_QUERY_GEOM / QUERY_FAMILY / QUERY_FEATURES / READ_LBA / WRITE_LBA / FLUSH / TRIM dispatch
- R51.M7-005 R42 pdxfs/nvme_write.pdx → pdxfs/bdev_write.pdx: rewire to BDEV_OP_WRITE_LBA + BDEV_OP_FLUSH; delete direct NVMe dependency
- R51.M7-006 Cross-family witness: same PdxFS mount code exercised against QEMU nvme AND QEMU ahci; assert identical FS-level fingerprint

### M8 — Full round-trip smoke: FS mount → write → flush → unmount → remount → read

*This milestone is the integration point with softarch's parallel §5.
The BDEV wire is R51's, the mount/unmount + WAL replay are softarch's.
Both halves cite this milestone as their close-out.*

- R51.M8-001 Mount syscall wire: userspace mount tool → KIND_BLKDEV cap request → FS layer opens transaction → BDEV_OP_QUERY_GEOM
- R51.M8-002 Write path: PdxFS v1 issues journaled writes through BDEV_OP_WRITE_LBA + BDEV_OP_FLUSH; assert durability barrier order
- R51.M8-003 Unmount + remount: WAL replay reads back through BDEV_OP_READ_LBA; verify FS consistency by comparing snapshot digests pre-unmount and post-remount
- R51.M8-004 Cross-family soak: 1000-iteration mount/write/flush/unmount/remount/read loop on both NVMe (QEMU + T14 G4 internal) and AHCI (QEMU + optional T14 G4 dock)
- R51.M8-005 Hot-remove-under-write: pull the device (QEMU `device_del` for NVMe, port SUD toggle for AHCI) during a write burst; assert cap revoke cascades cleanly and FS layer surfaces EIO to the mount owner
- R51.M8-006 T14 G4 first-real-hardware witness: fingerprint on `tests/hw/r51-nvme-t14g4.golden` (extends `design/hardware/t14-g4-first-boot.md` §6)

**Post-M8 open threads** (deliberately NOT in this round):

- SMART / health-log surface to a userspace `smartctl`-equivalent — R52+.
- Namespace-attach / -detach management (opcodes 0x15/0x16) — R52+.
- NVMe over Fabrics — R60+ (needs network substrate).
- AHCI port multipliers — deferred (uncommon in the target hardware
  landscape; T14 G4 has no PM).

---

## 8. Cross-repo dependencies (paideia-as encoder gaps)

The R51 substrate exercises three paideia-as encoder patterns that
have thin or unaudited coverage.  Each is a candidate cross-repo
issue to file BEFORE R51 opens.

### 8.1 MSI-X vector allocation programming

**Requirement.**  R51.M3 writes MSI-X table entries at physical
addresses read from the PCI MSI-X capability structure.  The write
is a 128-bit atomic (address_lo:u32, address_hi:u32, data:u32,
vector_control:u32) issued through `mov qword ptr [rdi + N], rax`
sequences.

**paideia-as gap to verify.**  Whether the encoder emits proper
64-bit atomic writes to MMIO regions (as opposed to two 32-bit
writes which some CPUs will tear).  MSI-X spec requires atomicity
w.r.t. the vector_control field's mask bit.

**Suggested issue on paideia-as.**  "MSI-X 64-bit atomic MMIO write:
verify encoder emits a single 8-byte store for a `mov qword ptr
[<mmio>], <reg>` and does not tear into two 4-byte stores under any
optimization posture."

### 8.2 DMA descriptor packing (PRP-list + PRDT)

**Requirement.**  NVMe PRP-list pages are arrays of u64 physical
addresses, 4 KiB aligned, exactly 512 entries per page.  AHCI PRDT
entries are 16 B structs (DBA:u64, reserved:u32, dbc_i:u32) with
strict alignment (2-byte data alignment, 4-byte byte-count).

**paideia-as gap to verify.**  Struct-of-integers packing at
compile time — no padding drift; the round-plan for R51 assumes the
encoder produces exactly the byte layout Intel/NVMe specify.  Some
paideia-as struct forms have historically been padded to alignment
boundaries greater than the spec.

**Suggested issue on paideia-as.**  "Verify unsafe-block struct
literal packing for PRP-list and PRDT layouts.  Test: emit a
16-byte-per-entry PRDT array of N entries; assert byte-accurate
match against a fixture."

### 8.3 MMIO barriers (mfence/sfence/lfence around device MMIO)

**Requirement.**  Doorbell writes (NVMe SQyTDBL / AHCI CI) must
appear to the device AFTER all prior submission-queue entry writes
land.  On x86_64 with WC memory this needs an `sfence` at minimum;
UC memory is naturally ordered but the standard is defense-in-depth
+ portability.

**paideia-as gap to verify.**  Whether the encoder recognises
`sfence` / `mfence` / `lfence` as fence primitives and does not
reorder them with prior stores in the unsafe block, AND whether an
explicit `; sfence` in the block emits the intended 3-byte
`0F AE F8` sequence.

**Suggested issue on paideia-as.**  "Emit and lock down fence
primitives (sfence/mfence/lfence) in unsafe blocks; add a witness
that decoding the emitted bytes yields the correct opcode."

### 8.4 IOMMU invalidation (VT-d QI queue)

**Requirement.**  Between `dma_domain_unmap` and re-mapping the
same IOVA, the VT-d IOTLB must be invalidated (queued-invalidation
descriptor).  The QI queue is an MMIO-programmed ring;
implementation lives at R35 (`iommu/vtd_ctx.pdx`) already but R51 is
the first regular caller.

**paideia-as gap to verify.**  Nothing NEW — R29/R35 already
exercised this path.  R51 amplifies the exposure; if any
encoder-side latent issue exists, it will surface here first.

**Suggested action.**  Add a paideia-as smoke that runs the
QI-invalidate wire at 10 kHz for 1 s and asserts no descriptor
drops.  File as a *preventive* issue, not a blocker.

---

## 9. Notes for softarch integration

softarch's parallel design owns:

- Volume manager (pool from multiple `KIND_BLKDEV`s, RAID levels,
  cross-device journaling if any).
- Mount table + mount namespaces.
- FS-level allocator (extent trees, B-tree, whatever softarch
  chooses within the R42 PdxFS v1 shape).
- Cache eviction + writeback strategy.
- Space reclamation policy (when to TRIM, batching heuristics).
- Cross-device transactions (if the volume manager surfaces atomic
  writes across two BDEVs, the coordination protocol).

softarch and osarch share exactly these coordination points that
require main to reconcile:

- **KIND ordinals 0x19C..0x1A7** are reserved for softarch's FS-
  layer additions (see §6).  If softarch's design proposes more, it
  should extend the range explicitly and update `kind.pdx` in the
  same commit.
- **`BDEV_OP_TRIM` semantics.**  Softarch's allocator must tolerate
  `BDEV_ERR_UNSUPPORTED`.  If softarch's design assumes TRIM is
  mandatory, the assumption belongs in `KIND_VOLUME`'s minter, not
  in this substrate.
- **`BDEV_OP_FLUSH` is a hard fence.**  If softarch's WAL design
  wants a *softer* barrier (a write-order dependency without full
  persistence), that is a new op — call it `BDEV_OP_BARRIER` — and
  softarch owns proposing it; the R51 design does not include it
  because neither NVMe nor AHCI has a wire equivalent (both flush
  the whole cache on the fence op).
- **DMA memory ownership**: softarch's FS layer allocates pages
  from `KIND_MEMORY` and hands them to the driver as `KIND_PAGE`
  handles.  Softarch never sees an IOVA; osarch never sees an FS
  extent.  The wire is at BDEV_OP_READ_LBA/BDEV_OP_WRITE_LBA.
- **`max_transfer_blocks` in the tail** is queried by softarch via
  `BDEV_OP_QUERY_GEOM` — softarch may size its writeback chunks to
  it, but MUST NOT depend on any particular value (it varies wildly
  between NVMe MDTS-256 and AHCI PRDTL-16-page-max).

---

## 10. Open questions for main

1. **KIND_BLOCK_DEVICE naming.**  This design keeps the codebase
   spelling `KIND_BLKDEV` and treats `KIND_BLOCK_DEVICE` as a
   doc-only synonym (§4.1).  If main prefers a full rename with a
   compat alias, the discipline steps in `design/user/pdxfs-kinds.md`
   §4 cover it — but at real cost to the R24 code and R42 FS wiring
   that already references `KIND_BLKDEV`.  Default recommendation:
   keep the R24 spelling; document the synonym.

2. **Attestation for internal storage.**  §5.4 generalises R35's
   attestation gate to internal NVMe.  This is more restrictive than
   Linux (which does not attest internal devices at all).  Pillar 6
   (security by construction) argues for it; user-experience cost is
   a one-time founder dialog at first boot.  Confirm this is the
   posture main wants before R51.M2-003 lands.

3. **Bounce-buffer pool sizing.**  §5.3 puts bounce buffers in a
   per-driver-process pool.  A 64 MiB default per driver process is
   the R51.M3 proposal; a 128 MiB alternative doubles the pool at
   the cost of pinned memory even when idle.  softarch's cache
   design may prefer the larger pool.  Coordinate at §5 of the
   unified plan.

4. **AHCI slot count.**  §6 caps at 4 AHCI controllers ×  32 ports
   = 128 ports max.  QEMU CI runs 1×1; T14 G4 has 0 AHCI controllers
   (all storage is NVMe).  If a future workstation target exceeds
   these bounds, bump `AHCI_CTRL_MAX` and `AHCI_PORT_MAX` per the
   R48b-style substrate-prep discipline (`design/user/pdxfs-kinds.md`
   §4 checklist).
