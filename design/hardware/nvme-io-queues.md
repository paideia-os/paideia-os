# NVMe I/O Queues + First LBA Round-Trip

**Status.**  Draft v0.1 (R51.M3 planning, 2026-08-22).
**Parent.**  `design/hardware/nvme-and-disk-substrate.md` §2.5 (MSI-X),
§2.3 (I/O commands), §4.2 (`BDEV_OP_*` op set), §7 (R51 milestone table).
This doc expands the parent's §7 R51.M3 block (issue titles at parent §7,
lines 836-843) into a per-file / per-function implementation plan.
**Depends on.**
- R51.M1 (landed) — `KIND_NVME_CONTROLLER = 0x198` at
  `src/kernel/core/cap/kind_nvme_controller.pdx` (1635 lines).  Provides
  the controller row (`_nvme_controller_table`), `admin_ctx_pa`,
  `bar0_pa`, `mdts`, `nn`, `num_io_queues`, and the state machine
  `MINTED → ENABLED → IDENTIFIED → NEGOTIATED`.
- R51.M2 (landed) — `KIND_NVME_NAMESPACE = 0x199` at
  `src/kernel/core/cap/kind_nvme_namespace.pdx` (1674 lines).  Provides
  the namespace row (`_nvme_namespace_table`), `nsid`, `lba_size`,
  `block_count`, `parent_ctrl_row`, and the dual-kind mint with
  `KIND_BLKDEV = 0x42` — the same row_id is reachable through either
  handler.
- R24 scaffolding at `src/kernel/core/drivers/nvme/`:
  - `io_queue.pdx` (771 lines) — `nvme_create_io_cq`, `nvme_create_io_sq`,
    `nvme_create_all_io_cqs`, `nvme_create_all_io_sqs`, per-CPU
    `_nvme_io_queues[32]` descriptor table + `_nvme_io_cq_buffers` /
    `_nvme_io_sq_buffers` .bss.
  - `sync.pdx` (289 lines) — `nvme_read_blocking(nsid, lba, count,
    buf_pa)` scaffold; no matching `nvme_write_blocking` yet.
  - `prp.pdx`, `dispatch.pdx`, `doorbell.pdx`, `irq.pdx` — the wire.
- R29.M1 (landed) — `KIND_HW_INTERRUPT = 0x140` and
  `KIND_HW_MSIX_VECTOR = 0x141` at
  `src/kernel/core/cap/kind_hw_msix_vector.pdx`.  Provides
  `msix_cap_mint(slot, parent_slot, rights, msix_table_offset,
  msix_data) -> u64` and the cascade revoke path.
- R29.M5 (landed) — `KIND_DMA_DOMAIN = 0x142`.  R51.M3's PRP encodes
  IOVAs the caller already programmed into the driver's DMA domain;
  this milestone does not touch the domain map/unmap paths.
- `design/policy/output-provenance-strip.md` — runtime output must not
  carry `R51.M3-*` or `#164*` tags; fingerprint text is component-named.

**Scope of this doc.**  Everything R51.M3 substantiates:

- §1 File layout — the split-off decision.
- §2 Data structures — the per-controller / per-CPU I/O pair table.
- §3 API surface — the ≤5 module-lets this round introduces, with SysV
  signatures, callee-save discipline, and the `BDEV_OP_*` route.
- §4 MSI-X integration — how #1645 wires into R29.M1's `msix_cap_mint`
  path; the parent-cap chain from `KIND_HW_INTERRUPT`.
- §5 Per-issue implementation order — the six R51.M3-00N tickets, their
  dependency edges, and what each debugger will need if the build fails.
- §6 Witness (#1650) — the QEMU nvme round-trip witness, mirroring the
  M1/M2 synth witness shape, with a provenance-stripped fingerprint.
- §7 paideia-as encoder caveats — reserved labels, arity caps, sized
  stores, SysV alignment.

**Out of scope for R51.M3** (deferred to R51.M4 and later):
- `BDEV_OP_FLUSH` (opcode 0x00) — R51.M4-001.
- `BDEV_OP_TRIM` (`DATASET_MANAGEMENT` opcode 0x09) — R51.M4-002.
- `ASYNC_EVENT_REQUEST` refill, timeout watchdog, CFS recovery —
  R51.M4-003..006.
- The AHCI family — R51.M5..M6.
- Real IRQ-driven completion drain wiring end-to-end.  R51.M3 lands the
  poll-until-Phase-Tag-flips fallback that R24 `sync.pdx` already uses
  and defers wire-up of the userspace IRQ endpoint to the AER round
  (R51.M4-003 sits on the same endpoint).

---

## 1. File layout — split off, or extend controller cap?

`kind_nvme_controller.pdx` is already 57 KB / 1635 lines.  It owns the
mint gate, four state transitions, IDENTIFY(controller), SET_FEATURES,
row accessors, six-op dispatch handler, and a documentation-heavy header.
Adding I/O queue substrate + PRP submit path + completion drain + BDEV
op routing would push it toward ~2500 lines; R51.M4 (flush, TRIM, AER,
timeout, CFS) would then push it past 3500.

`kind_nvme_namespace.pdx` (1674 lines) faces the same pressure: the
`BDEV_OP_*` handler for the dual-kind route naturally lives there
(because `KIND_BLKDEV` invocations dispatch into a handler that reads
the namespace row via `nvme_ns_row_*`), and adding the read/write op
bodies inline would double its size.

Decision: **split off into two new files, one per concern**:

| New file | Ownership | Approx size at M3 close |
|:---------|:----------|:------------------------|
| `src/kernel/core/cap/nvme_io_queues.pdx` | Per-controller / per-CPU I/O pair table; MSI-X batch alloc; `CREATE_IO_CQ` / `CREATE_IO_SQ` (production wire-up, superseding R24 scaffolds); PRP-backed READ/WRITE submit + completion drain. | ~700-850 lines |
| `src/kernel/core/cap/kind_blkdev_dispatch.pdx` | `cap_handler_blkdev` — the `BDEV_OP_*` dispatcher.  Row lookup goes through `nvme_ns_row_of_slot` (already in `kind_nvme_namespace.pdx`); reads/writes call into `nvme_io_queues.pdx`. | ~250-350 lines |

Rationale:

- **`nvme_io_queues.pdx`** is a *new* module because there is no
  KIND-scoped file to extend that makes sense: I/O queues are not a
  cap kind (they have no KIND tag), and they are shared by
  `KIND_NVME_CONTROLLER` (owns admin queue → issues `CREATE_IO_*`) and
  by the BDEV route (submits READ/WRITE).  The R24
  `drivers/nvme/io_queue.pdx` is a driver-layer scaffold that predates
  the cap substrate; R51.M3 does not replace it in place (it stays for
  the R24 witness) but the R51-production path lives in
  `core/cap/nvme_io_queues.pdx` where it consults `KIND_NVME_CONTROLLER`
  rows rather than the R24 globals.
- **`kind_blkdev_dispatch.pdx`** is separated from
  `blkdev_cap.pdx` (which stays 196 lines and mint-gate-only) because
  the R51.M3 dispatch needs to reach into two other cap modules
  (`kind_nvme_namespace` for the row, `nvme_io_queues` for the submit).
  Putting the dispatcher there keeps `blkdev_cap.pdx` a pure mint gate
  and prevents circular import shape.

**Files touched at R51.M3 close:**

| File | Change | Reason |
|:-----|:-------|:-------|
| `src/kernel/core/cap/nvme_io_queues.pdx` | NEW | Substrate (§2, §3). |
| `src/kernel/core/cap/kind_blkdev_dispatch.pdx` | NEW | BDEV op router (§3.5). |
| `src/kernel/core/cap/invoke.pdx` | +1 dispatch edge | `call_kind_blkdev` now targets `cap_handler_blkdev` in the new dispatcher (currently the KIND_BLKDEV routing table entry is a fall-through — see `kind_nvme_namespace.pdx` line 27 comment). |
| `src/kernel/core/cap/kind_nvme_controller.pdx` | +1 op (`NVMEC_OP_BRING_UP_IO`) | Admin-side trigger that runs `nvme_io_bring_up_all(ctrl_row)` from the controller-cap dispatch handler.  ~30 lines. |
| `src/kernel/core/cap/kind_nvme_namespace.pdx` | +2 accessors | `nvme_ns_row_ctrl_bar0(ns_row)` and `nvme_ns_row_ctrl_admin_ctx(ns_row)` — small forwarders the BDEV dispatcher uses without knowing the controller layout.  ~40 lines. |
| `src/kernel/core/klog/file_ids.pdx` | +2 rows | FILE_ID assignments for the two new files. |
| `tests/kernel/nvme/kind_nvme_io_queues_synth.pdx` | NEW | R51.M3-006 witness (§6). |
| `tests/r17/shell-shutdown.golden` | +1 fingerprint line | `KIND_NVME_IO OK` (component-named, no round tag). |

No touch: `kind_hw_msix_vector.pdx`, `kind_dma_domain.pdx`, the R24
`drivers/nvme/*.pdx` files.  The R24 `sync.pdx` `nvme_read_blocking` is
kept for backward compatibility with the R24 fixture; R51.M3's submit
path is a separate entry point that consumes a KIND_NVME_CONTROLLER row
handle rather than the R24 globals.

---

## 2. Data structures

### 2.1 The per-controller / per-CPU pair table

Each controller can carry up to `NVME_IO_MAX_CPUS = 8` I/O pairs (one
per CPU on our T14 G4 target, 4C/8T; ceiling of 8 matches R24's
`NVME_IO_MAX_QUEUES` and `_madt_ap_count + 1` under
`min(., NVME_IO_MAX_QUEUES)`).  The pair table is indexed
`_nvme_io_pair_table[ctrl_row_id * NVME_IO_MAX_CPUS + cpu_idx]`.

Row size **64 B** (eight u64 words), consistent with every other
`kind_*.pdx` row layout in the tree.  Field map:

```
    +0    header:   in_use[63:56] | state[15:8] | qid[7:0]
    +8    sq_pa                 (u64)   physical addr of SQ page
    +16   cq_pa                 (u64)   physical addr of CQ page
    +24   doorbells             (u64)   sq_tdbl_off[31:0] | cq_hdbl_off[31:16] | dstrd[7:0]
    +32   cursors               (u64)   sq_tail[47:32] | cq_head[31:16] | cq_phase[7:0]
    +40   msix_row_id           (u64)   row_id in _hw_msix_vector_table (cascade parent = KIND_HW_INTERRUPT)
    +48   owning_cpu            (u64)   cpu_idx (0..NVME_IO_MAX_CPUS-1); 0xFF if unbound (fallback slot)
    +56   reserved              (u64)
```

State byte values (in header bits [15:8]):

```
    NVME_IOP_STATE_FREE      = 0    slot never used or teardown complete
    NVME_IOP_STATE_MSIX      = 1    MSI-X vector minted, no CQ yet
    NVME_IOP_STATE_CQ_LIVE   = 2    CREATE_IO_CQ acked
    NVME_IOP_STATE_SQ_LIVE   = 3    CREATE_IO_SQ acked; pair usable
    NVME_IOP_STATE_QUIESCED  = 4    reserved for R51.M4 queue-reset path
```

`qid` (bits [7:0]) = `cpu_idx + 1` (admin queue is qid=0 by NVMe
convention; §3.1.14 of the base spec).  Storing it explicitly saves a
recompute at doorbell time and makes the row self-describing.

**Capacity:** `NVMEC_MAX_ROWS (8) * NVME_IO_MAX_CPUS (8) * 64 B =
4 KiB` — one page in `.bss`, zero-init preserving the
`in_use=0`/`state=FREE` invariant.

### 2.2 Backing buffers (existing R24 .bss reused)

The R24 `io_queue.pdx` reserves `_nvme_io_cq_buffers` + `_nvme_io_sq_buffers`
(8 × 4 KiB each).  These stay — one page per (ctrl × cpu) is
insufficient for multi-controller systems, but at R51.M3 the target
matrix is single-controller.  R51.M4+ widens to
`_nvme_io_*_buffers[NVMEC_MAX_ROWS][NVME_IO_MAX_CPUS]` if a second
controller ever mints; the row's `sq_pa` / `cq_pa` fields are the
indirection that makes that widening non-breaking.

### 2.3 Doorbell offset math (already landed at R24, referenced here)

Per controller `dstrd` (CAP[35:32] — 2^(2+dstrd) byte stride between
adjacent doorbells):

```
    sq_tdbl_off(qid) = 0x1000 + (2 * qid + 0) * (1 << (2 + dstrd))
    cq_hdbl_off(qid) = 0x1000 + (2 * qid + 1) * (1 << (2 + dstrd))
```

Cached in the row at +24 at mint time so the doorbell write is a single
`mov_d [rbase + off], val` without recomputing.

### 2.4 Completion queue phase-tag discipline

Each CQE carries a Phase Tag bit (byte +14 bit 0 of the 16-B CQE).  The
row remembers the *expected* value in `cursors[7:0]` (`cq_phase`).  On
each drain:

- Read CQE at `cq_pa + cq_head * 16`.
- If phase-tag bit != expected → no new completion, done.
- Else consume, advance `cq_head` (wrap at 64), flip `cq_phase` on wrap,
  write CQyHDBL doorbell.

This is the same phase discipline `dispatch.pdx` (R24) uses for admin
completions; R51.M3 lifts the pattern into `nvme_io_completion_drain`.

---

## 3. API surface

Five new module-lets in `nvme_io_queues.pdx`, plus one dispatcher in
`kind_blkdev_dispatch.pdx`, plus two forwarders added to
`kind_nvme_namespace.pdx`.  All signatures satisfy the paideia-as
`<= 6 args` cap (§7).

### 3.1 `nvme_io_msix_alloc_for_ctrl` (#1645)

```
    pub let nvme_io_msix_alloc_for_ctrl :
        (u64, u64, u64, u64) -> u64 !{mem, sysreg} @{cap}
    // args: ctrl_row_id, hw_int_parent_slot, slot_base, ncpu
    // returns: 0 on OK; NVMEIO_MSIX_ENOSPC (0xFFFFEC50)
    //          or NVMEIO_MSIX_EPARENT (0xFFFFEC51) on error
```

Semantics.  For `cpu_idx` in `0..min(ncpu, NVME_IO_MAX_CPUS)`:
1. Call `msix_cap_mint(slot_base + cpu_idx, hw_int_parent_slot,
   R_MSIX_ALL, table_offset = cpu_idx * 16, msix_data = cpu_idx)`.  If
   the mint fails (parent gate refuses, or `MSIX_MINT_IN_USE`,
   or `MSIX_TAIL_ENOSPC`), roll back every prior mint by
   `msix_cap_revoke(slot_base + k)` for `k in 0..cpu_idx` and return
   the corresponding NVMEIO_MSIX_* error.
2. On success, stamp the pair row's `msix_row_id` (row +40) via the
   descriptor's `target_ptr[15:0]` after `cap_mint_write` — the
   msix_cap_mint path already writes that, so we re-read from
   `cap_table[slot_base + cpu_idx]`.
3. State transition on the pair row: FREE → MSIX.

**Table offset convention.**  `cpu_idx * 16` matches the standard PCIe
MSI-X table entry stride (4 dwords × 4 B).  `msix_data = cpu_idx` gives
the CPU affinity a unique data value distinguishable from the AHCI
family's single-vector data.

**Rollback discipline.**  Every mint failure past index 0 unwinds
already-minted vectors so the driver-process cap slots come back to a
clean state; the pair-table rows for successful CPUs get their state
reset to FREE.  Debuggers looking at a partial failure see either
"all minted" or "none minted"; no dangling `_hw_msix_vector_table`
rows.

**paideia-as posture.**  4 args (r ≤ 6, OK), 5-push callee-save
(rbx = ctrl_row, r12 = cpu_idx, r13 = ncpu, r14 = slot_base,
r15 = parent_slot) leaves `rsp % 16 == 0` on entry to `msix_cap_mint`.

### 3.2 `nvme_io_create_pair` (#1646)

```
    pub let nvme_io_create_pair :
        (u64, u64) -> u64 !{mem, sysreg} @{cap}
    // args: ctrl_row_id, cpu_idx
    // returns: 0 on OK; NVMEIO_CQ_FAILED (0xFFFFEC52),
    //          NVMEIO_SQ_FAILED (0xFFFFEC53),
    //          NVMEIO_STATE_BAD (0xFFFFEC54)
```

Semantics.  Consult pair row: require `state == MSIX` (else
NVMEIO_STATE_BAD).  Then:

1. `sq_pa = &_nvme_io_sq_buffers[cpu_idx * 4096]`,
   `cq_pa = &_nvme_io_cq_buffers[cpu_idx * 4096]`.  Zero both pages.
2. `qid = cpu_idx + 1`.
3. Look up `bar0`, `admin_ctx` from ctrl_row via existing accessors
   (`nvme_ctrl_row_bar0`, `nvme_ctrl_row_admin_ctx`).
4. Look up `vector` from pair-row `msix_row_id` — that gives the
   MSI-X *vector index* on the device (== `cpu_idx` per §3.1's
   table-offset convention).
5. Pack `cdw11_cq = (vector << 16) | (1 << 1) | 1` (IEN=1, PC=1).
   Call the R24 `nvme_create_io_cq(bar0, admin_ctx, qid, cq_pa, 64,
   cdw11_cq)` — this is the existing R24 SQE builder + admin submit
   path.  On non-zero status → NVMEIO_CQ_FAILED (no state change).
6. On success: stamp pair row `cq_pa`, doorbells, cursors initial;
   state → CQ_LIVE.
7. Pack `cdw11_sq = (cqid << 16) | (0 << 1) | 1` (qprio=0=urgent
   irrelevant at R51.M3, PC=1).  Call `nvme_create_io_sq(bar0,
   admin_ctx, qid, sq_pa, 64, cdw11_sq)`.  On failure →
   NVMEIO_SQ_FAILED, roll back: delete CQ via `nvme_delete_io_cq`
   (already in R24), state back to MSIX.
8. On success: stamp pair row `sq_pa`; state → SQ_LIVE.

**paideia-as posture.**  2 args, 6-push callee-save (rbx = ctrl_row,
rbp = cpu_idx, r12 = pair_row_addr, r13 = bar0, r14 = admin_ctx,
r15 = vector) = 48 B; entry rsp%16==8 → 56, sub rsp,8 → 64; %16==0.

### 3.3 `nvme_io_submit_rw` (#1647 + #1648)

One entry point for both READ (opcode 0x02) and WRITE (opcode 0x01).
Same SQE shape, opposite direction.

```
    pub let nvme_io_submit_rw :
        (u64, u64, u64, u64, u64, u64) -> u64 !{mem, sysreg} @{cap}
    // args: ctrl_row, ns_row, opcode, lba, nblocks, dma_iova
    // returns: bytes transferred (nblocks * lba_size) on OK; else
    //          NVMEIO_SUBMIT_ENOROOM (0xFFFFEC55) — queue full,
    //          NVMEIO_SUBMIT_TIMEOUT (0xFFFFEC56) — completion never arrived,
    //          NVMEIO_SUBMIT_CQE_ERR (0xFFFFEC57) — CQE status non-zero
    //                                                (bytes = raw status
    //                                                for the debugger)
```

Exactly 6 args — the paideia-as ceiling.  `dma_iova` is a
driver-process-domain IOVA the caller already programmed via
`dma_domain_map` (R29.M5); this function does NOT walk the DMA domain.
`opcode` distinguishes READ (0x02) / WRITE (0x01); no other values
accepted (a bad opcode returns NVMEIO_SUBMIT_CQE_ERR with
`bytes=0xEEEE`).

Sequence:

1. Pick a pair: `pair_row = nvme_io_pick_pair(ctrl_row)` (§3.4).
2. Check `pair_row.state == SQ_LIVE` (else NVMEIO_STATE_BAD).
3. Bounds:
   - `lba + nblocks <= nvme_ns_row_block_count(ns_row)` — else
     NVMEIO_SUBMIT_CQE_ERR with a distinguishing status of `0xE001`
     (out-of-range LBA; matches NVMe SC=0x80 semantics).
   - `nblocks * lba_size <= (mdts_bytes = 1 << (12 + mdts))`.  Larger
     transfers get NVMEIO_SUBMIT_CQE_ERR with `0xE002` — R51.M3 does
     NOT split; the FS layer chunks.  R51.M4-005 optionally lifts
     this if MDTS on real drives proves too small in practice.
4. Encode PRP from `dma_iova` + `nblocks * lba_size` via existing
   `prp.pdx` (`nvme_prp_encode(iova, len) -> (prp1, prp2)`).  A
   PRP-list page is allocated from the driver's DMA domain if the
   transfer needs > 2 pages; R51.M3 uses the R24 PRP-list page
   allocator unchanged.
5. Build the SQE at `sq_pa + sq_tail * 64`:
   - +0 OPC = opcode, FUSE/PSDT = 0, CID = `sq_tail` (16-bit rolling).
   - +4 NSID = `nvme_ns_row_nsid(ns_row)`.
   - +24 PRP1 = prp1.
   - +32 PRP2 = prp2.
   - +40 CDW10 = `lba[31:0]`.
   - +44 CDW11 = `lba[63:32]`.
   - +48 CDW12 = `(nblocks - 1) & 0xFFFF` (NLB is 0-based).
   - +52..+63 = 0.
6. Advance `sq_tail` (mod 64), write SQyTDBL doorbell.
7. Poll `nvme_io_completion_drain(pair_row, timeout_spins)` until CID
   matches or spin budget exhausted → NVMEIO_SUBMIT_TIMEOUT.  Spin
   budget = `NVME_SYNC_SPIN_MAX = 50_000_000` (same as R24 sync.pdx).
8. On matching CQE:
   - `status_field = cqe[+14][31:17]` (SCT+SC excl phase).  Non-zero
     → NVMEIO_SUBMIT_CQE_ERR with `bytes = status_field`.
   - Zero → return `bytes = nblocks * lba_size`.

**paideia-as posture.**  6 args — hits the ceiling.  Body decomposes
into two 6-push helpers (SQE builder + drain poller) so no single
lambda needs `> 6` args.  All `mov_b [reg + reg]` byte reads on the
CQE use the `[reg + reg * 1]` form per encoder gap G1.

### 3.4 `nvme_io_pick_pair` (#1649)

```
    pub let nvme_io_pick_pair : (u64) -> u64 !{mem} @{}
    // arg: ctrl_row_id
    // returns: pair_row_addr (u64 physical address), or
    //          NVMEIO_PICK_NONE (0xFFFFEC58) if no pair on this ctrl
    //          reached SQ_LIVE.
```

Semantics:

1. Read `cpu_idx = _current_cpu_idx()` — a tiny read of the per-CPU
   `%gs`-based scratch already used elsewhere (falls back to 0 pre-SMP).
2. Compute pair index `ctrl_row * NVME_IO_MAX_CPUS + cpu_idx`.
3. If that row's `state == SQ_LIVE`, return its address (fast path).
4. Else round-robin scan: for `k in 0..NVME_IO_MAX_CPUS`, check row
   `ctrl_row * NVME_IO_MAX_CPUS + (cpu_idx + k) mod NVME_IO_MAX_CPUS`;
   return the first `SQ_LIVE` row's address.
5. If none live → NVMEIO_PICK_NONE.

The fallback path is what #1649 substantiates.  R51.M3's target matrix
is a QEMU 1-vCPU nvme device (fallback exercised) *and* a 4-vCPU
build (fast path exercised at cpu_idx=0..3).

**Rationale for round-robin over "always cpu 0".**  A CPU with no
bound pair (`state != SQ_LIVE`) at the fast-path index would otherwise
starve; the round-robin walk is 8 scans in the worst case, cheap
against the ~10 μs per NVMe I/O.  At R51.M4+ the fallback becomes a
policy hook: soft-affinity, IRQ-steer, etc.

**paideia-as posture.**  1 arg, leaf-ish (calls `_current_cpu_idx`
which is a `%gs`-scratch read + return).  4-push callee-save
(rbx = ctrl_row * MAX_CPU + cpu_idx, r12 = k, r13 = ncpu, r14 = base
addr) = 32 B; entry rsp%16==8 → 40, sub rsp,8 → 48; %16==0.

### 3.5 `cap_handler_blkdev` (new file, ties #1647/#1648 to dispatch)

```
    pub let cap_handler_blkdev :
        (u64, u64, u64) -> u64 !{mem, sysreg} @{cap}
    // args: rights, target_ptr, op_arg     (SysV: rdi/rsi/rdx)
    // returns: op-specific rax
```

Op selection on `op_arg[7:0]`:

| Op | Value | Rights required | R51.M3? |
|:---|:------|:----------------|:--------|
| BDEV_OP_QUERY_GEOM     | 0 | `R_BLK_READ | R_BLK_ADMIN` | yes (returns `lba_size << 32 | block_count[31:0]` — extended-block-count path defers to R51.M4) |
| BDEV_OP_QUERY_FAMILY   | 1 | any non-zero rights | yes (returns `nvme_ns_row_family(ns_row)`) |
| BDEV_OP_QUERY_FEATURES | 2 | any non-zero rights | yes (returns feature bitmap; at M3 only bit 3 = WRITE_CACHE_PRESENT set unconditionally, bit 0 FLUSH cleared until M4) |
| BDEV_OP_READ_LBA       | 3 | `R_BLK_READ`  | yes (#1647) |
| BDEV_OP_WRITE_LBA      | 4 | `R_BLK_WRITE` | yes (#1648) |
| BDEV_OP_FLUSH          | 5 | `R_BLK_FLUSH` | NO (M4) — returns `BDEV_ERR_UNSUPPORTED` |
| BDEV_OP_TRIM           | 6 | `R_BLK_TRIM`  | NO (M4) — returns `BDEV_ERR_UNSUPPORTED` |

Op-arg encoding for READ/WRITE.  `op_arg` is a single u64 — the
dispatch protocol is arity-1.  So the caller packs
`op_arg = (op_code) | (nblocks << 8) | (lba_low << 24)`?  No —
too tight.  The R51.M3 protocol instead spills READ/WRITE args
through a **caller-provided descriptor page**: `op_arg = (op_code) |
(op_desc_iova << 8)` where `op_desc_iova` is a 4-KiB-aligned page
in the driver's DMA domain carrying:

```
    +0    lba        (u64)
    +8    nblocks    (u64)
    +16   dma_iova   (u64)   the target DMA IOVA
    +24   status_out (u64)   written back with result
```

The handler reads those four u64s, calls
`nvme_io_submit_rw(ctrl_row, ns_row, opcode, lba, nblocks, dma_iova)`,
writes `status_out`, returns 0 (or the NVMEIO_* error).

Row lookup: `target_ptr[15:0]` is the row_id in
`_nvme_namespace_table`; the two accessors added to
`kind_nvme_namespace.pdx` (`nvme_ns_row_ctrl_row(ns_row)` — exists —
plus the new `_ctrl_bar0` / `_ctrl_admin_ctx` forwarders) reach the
controller row through `parent_ctrl_row`.

**Why not embed the READ/WRITE args in a wider `op_arg`?**  Because
the cap `invoke` syscall is fixed-arity (kind 0x42 already routes
through `call_kind_blkdev` at `cap/invoke.pdx` line ~1119-style, and
the ABI is `(rights, target_ptr, op_arg)`).  The descriptor-page
indirection is the same shape KIND_PDXFS_TXN and KIND_DMA_DOMAIN use
for their multi-word arg surfaces (e.g. `dma_domain_map` takes a
scatter-gather descriptor page).

**Op-arg[63:8] refused.**  Except for the desc_iova high bits (bits
8..63 encode the aligned page number).  `op_arg[7:0]` = op_code (0..6);
`op_arg[11:8]` = 0 (reserved); `op_arg[63:12]` = page number of
descriptor page.  Any set bit in [11:8] → BDEV_ERR_BAD_ARG.

### 3.6 Additions to `kind_nvme_controller.pdx`

Add a single op to the existing dispatch handler:

```
    NVMEC_OP_BRING_UP_IO : u64 = 7
```

Requires `R_NVMEC_ADMIN | R_NVMEC_MINT_NS`.  Runs
`nvme_io_bring_up_all(ctrl_row) -> u64` — a convenience aggregate that:
1. Calls `nvme_io_msix_alloc_for_ctrl(...)`.
2. Loops CPUs, calls `nvme_io_create_pair(ctrl_row, cpu_idx)`.
3. Returns count of pairs that reached SQ_LIVE.

The supervisor invokes this once, after M1's SET_FEATURES(FID=0x07)
negotiated `num_io_queues`.  It is not called from the BDEV path.
This addition is ~30 lines of dispatch-table extension.

### 3.7 Additions to `kind_nvme_namespace.pdx`

Two forwarders, ~40 lines total:

```
    pub let nvme_ns_row_ctrl_bar0 : (u64) -> u64 !{mem} @{}
      // ns_row -> bar0 of parent controller (via row.parent_ctrl_row)

    pub let nvme_ns_row_ctrl_admin_ctx : (u64) -> u64 !{mem} @{}
      // ns_row -> admin_ctx_pa of parent controller
```

Both call into existing `nvme_ctrl_row_bar0` / `nvme_ctrl_row_admin_ctx`
after looking up `parent_ctrl_row` from the namespace row.  Adding
them here (rather than making the BDEV dispatcher walk two tables)
keeps the controller table's encoding private to `kind_nvme_controller.pdx`.

---

## 4. MSI-X integration

### 4.1 Parent-cap chain

```
    KIND_HW (0x14, R29.M1)                <- boot bundle authority
       |
       +--> KIND_HW_INTERRUPT (0x140, R29.M1-002)
       |       one per PCIe function, minted from the NVMe supervisor's
       |       KIND_PCI_DEV holdings with the function's affinity +
       |       edge/level fields (R29.M1-002)
       |
       +==>   KIND_HW_MSIX_VECTOR (0x141, R29.M1-004)
              one per NVMe I/O CQ (== one per CPU), minted by
              nvme_io_msix_alloc_for_ctrl via msix_cap_mint
```

The `==>` edge is a proper derivation: `msix_cap_mint`'s parent gate
(`kind_hw_msix_vector.pdx` line ~507) requires `parent_slot` to hold
`KIND_HW_INTERRUPT` (0x140) with `RIGHT_MINT`.  The NVMe supervisor
receives that parent cap in its cap table at boot (via R29.M1 boot
seeding), and passes its slot to `nvme_io_msix_alloc_for_ctrl`.

### 4.2 Wire encoding

Each MSI-X row records:
- `msix_table_offset` — byte offset within the device's MSI-X table.
  R51.M3 assigns `cpu_idx * 16` (four dwords per entry: msg addr low,
  msg addr high, msg data, vector control).
- `msix_data` — the u32 payload the device writes to the message
  address to raise the vector.  R51.M3 assigns `cpu_idx` (small u32).

The device-side MSI-X *vector index* — what `CREATE_IO_CQ` passes in
CDW11[31:16] — is the entry index in the table, which equals
`table_offset / 16 = cpu_idx`.  So the same integer flows through
three surfaces (row +40's msix_row_id → decoded table_offset → vector
index → CDW11 field) with a single truthful source (the mint
argument).

### 4.3 Grep-verified integration points

Files that already reference `msix_cap_mint`, from
`grep -rn 'msix_cap_mint' src/`:

- `src/kernel/core/cap/kind_hw_msix_vector.pdx` — the mint entry
  (`msix_cap_mint_inner` line 567, `msix_cap_mint` line 666).
- `src/kernel/boot/witness/r29_audit.pdx` line 482 / 491 — the
  R29 audit witness (unchanged by R51.M3).
- `src/kernel/boot/witness/r29_hw_caps.pdx` line 704+ — the R29 hw-caps
  witness (unchanged by R51.M3).

No production caller of `msix_cap_mint` exists prior to R51.M3.
`nvme_io_msix_alloc_for_ctrl` is the first — the R29.M1 substrate has
been synthetic-witness-only until now.  This is the expected shape
noted in the parent doc (`nvme-and-disk-substrate.md` §1 table row for
R29.M1: "Real callers for the MSI-X allocator (previously exercised
only by synthetic witnesses).").

### 4.4 Revoke cascade

`kind_hw_interrupt.pdx` line ~102 comment: `msix_cascade_revoke_by_parent`
(in `kind_hw_msix_vector.pdx` line ~835) is called BEFORE the
`KIND_HW_INTERRUPT` row itself is scrubbed.  Consequence for R51.M3:
revoking the NVMe function's `KIND_HW_INTERRUPT` tears down every
`KIND_HW_MSIX_VECTOR` R51.M3 minted; the pair-table rows those
vectors were bound to become stale (`msix_row_id` at +40 dangles).

R51.M3 handles the dangle in `nvme_io_submit_rw` by re-validating
`msix_row_id` via `msix_tail_valid` (already in R29.M1) on every
submit — if invalid, the pair row's state is forcibly reset to FREE
and NVMEIO_STATE_BAD is returned.  Sender sees "the queue went away"
and retries via `nvme_io_pick_pair`, which round-robins to a live
pair or returns NVMEIO_PICK_NONE.  This closes the "MSI-X vector
revoked but pair still SQ_LIVE" race without needing a synchronous
revoke callback.

---

## 5. Per-issue implementation order

Six R51.M3 tickets (#1645-#1650).  Dependency edges:

```
    #1645 (MSI-X vector loop)
        |
        v
    #1646 (CREATE_IO_CQ + CREATE_IO_SQ)
        |
        +-----------+-----------+
        v           v           v
    #1647       #1648       #1649
    (READ_LBA)  (WRITE_LBA) (round-robin pick)
        |           |           |
        +-----------+-----------+
                    |
                    v
                #1650 (QEMU witness)
```

Recommended landing order per commit:

### Commit 1 — #1645 R51.M3-001 (MSI-X vector alloc)

**Scope.**  Add `nvme_io_queues.pdx` skeleton (module header + KIND-adjacent
constants + pair-table `.bss` + row accessors).  Land
`nvme_io_msix_alloc_for_ctrl` + companion `nvme_io_msix_revoke_for_ctrl`
(cleanup path).  Add file_ids row.

**Debugger cue on failure.**  Most likely failure: parent-gate mismatch
(`msix_cap_mint` returning `MSIX_MINT_BAD_PARENT = 0xFFFFFFEE`).  Debugger
should verify the caller (test scaffold or supervisor) actually seeded
a `KIND_HW_INTERRUPT` cap at the slot it passes.  Second most likely:
paideia-as arity failure on `msix_cap_mint` (5 args) chained through
`nvme_io_msix_alloc_for_ctrl` (4 args) — check the callee-save
prologue does not stack more than 6 args across the outer call.

### Commit 2 — #1646 R51.M3-002 (CREATE_IO_CQ + CREATE_IO_SQ)

**Scope.**  Land `nvme_io_create_pair` + `nvme_io_bring_up_all` +
`NVMEC_OP_BRING_UP_IO` op on the controller handler.

**Debugger cue.**  Most likely failure: the R24 `nvme_create_io_cq`
in `drivers/nvme/io_queue.pdx` expects `bar0` and `admin_ctx` in a
specific order; sign it against the R24 signature
(`(bar0, ctx, qid, cq_pa, size, cdw11)` — 6 args).  A CDW11 mispack
(missing PC bit) will yield NVMe status `SCT=1 SC=2` (Invalid Field
In Command) which surfaces as NVMEIO_CQ_FAILED with the raw status
in `bytes`.  Second most likely: the pair-row state was still FREE
because commit 1's witness had not run — check
`_nvme_io_pair_table[ctrl * MAX_CPU + cpu]` byte at +1 (state).

### Commit 3 — #1647 R51.M3-003 (BDEV_OP_READ_LBA)

**Scope.**  Land `nvme_io_submit_rw` (both opcodes) + `nvme_io_completion_drain`
+ `nvme_io_pick_pair` (fast-path only; fallback in commit 5).  Land
`kind_blkdev_dispatch.pdx` with the READ/WRITE/QUERY_GEOM/QUERY_FAMILY/
QUERY_FEATURES ops; FLUSH/TRIM return `BDEV_ERR_UNSUPPORTED`.  Wire
`call_kind_blkdev` in `cap/invoke.pdx`.

**Debugger cue.**  Most likely failure: PRP encoding.  `nvme_prp_encode`
in R24 `prp.pdx` may hand back `prp2` as an IOVA where R51.M3 needs a
PRP-list-page IOVA — verify by reading `nblocks * lba_size` and
matching against `prp.pdx`'s split threshold (usually one page for
prp1 + up to `NVME_MPS - 8` bytes for prp2 direct, else a PRP list).
Second most likely: the callee-save 6-push in `nvme_io_submit_rw`
pushes `rsp` off %16 alignment — check `rsp % 16 == 0` at the
`call nvme_admin_submit_poll` site.

### Commit 4 — #1648 R51.M3-004 (BDEV_OP_WRITE_LBA)

**Scope.**  Cosmetic — #1647 already lands both opcodes through
`nvme_io_submit_rw`.  #1648's commit adds the WRITE-side unit
witness at `tests/kernel/nvme/kind_nvme_io_write_synth.pdx`
(if separate from #1650 witness) and updates the golden.

**Debugger cue.**  A WRITE that reports OK but reads-back wrong data
usually indicates DMA direction confusion in the QEMU harness (host
memory not visible to guest device) or a stale IOTLB entry.  Verify
by issuing a READ of the same LBAs after the WRITE; if the read
returns the WRITTEN payload the SW side is right and the harness
disagreement is elsewhere.

### Commit 5 — #1649 R51.M3-005 (round-robin fallback)

**Scope.**  Replace the fast-path-only `nvme_io_pick_pair` with the
scanned variant.  Add witness stub that mints only `ctrl * MAX_CPU + 3`
as SQ_LIVE and asserts a submit from cpu_idx=0 succeeds.

**Debugger cue.**  Most likely failure: `_current_cpu_idx()` not
returning what the test scaffold expects because the `%gs`-scratch
seed differs pre-SMP vs after `_madt_ap_start`.  Test scaffold should
set the scratch explicitly before invoking `nvme_io_pick_pair`.

### Commit 6 — #1650 R51.M3-006 (QEMU witness + golden)

**Scope.**  Land `tests/kernel/nvme/kind_nvme_io_queues_synth.pdx`
(§6).  Update `tests/r17/shell-shutdown.golden` with `KIND_NVME_IO OK`
line.

**Debugger cue.**  If the smoke fails with the fingerprint absent
altogether, the boot never reached the witness — check the witness
placement in the boot ordering (must run after
`kind_nvme_namespace_witness_done`).  If the fingerprint is `KIND_NVME_IO
FAIL`, the witness's `_nvmeiow_stage` field pinpoints the failing
step (§6.4).

### Parallelism

Commits 3, 4, 5 can be prepared in parallel branches after commit 2
merges — they share no code beyond `nvme_io_submit_rw`.  Serial
landing is still recommended so the golden updates don't collide.
Commit 6 gates on all five predecessors.

---

## 6. Witness shape (#1650)

Mirrors `tests/kernel/nvme/kind_nvme_controller_synth.pdx` (M1) and
`tests/kernel/nvme/kind_nvme_namespace_synth.pdx` (M2).  New file:

```
    tests/kernel/nvme/kind_nvme_io_queues_synth.pdx
```

Fingerprint: `KIND_NVME_IO OK\n\0` (25 bytes incl. NUL).  Fail
fingerprint: `KIND_NVME_IO FAIL\n\0` (27 bytes).  **No `R51.M3` in
either string** per `design/policy/output-provenance-strip.md`.

### 6.1 Preconditions the witness synthesises

The witness runs under BIOS-boot smoke where no real NVMe device
exists (MCFG absent → `_pci_device_count == 0`).  To exercise the
substrate against real MMIO the witness would need `-drive
if=none,file=nvme.img,id=n0 -device nvme,drive=n0,serial=deadbeef`
on the QEMU command line.

Two witness modes:

- **Substrate mode** (always runs on smoke): synthesise a
  KIND_NVME_CONTROLLER + KIND_NVME_NAMESPACE row via M1/M2 primitives,
  synthesise a KIND_HW_INTERRUPT parent slot, call
  `nvme_io_msix_alloc_for_ctrl` — expect success (the alloc doesn't
  touch MMIO).  Then attempt `nvme_io_create_pair` — expect
  NVMEIO_CQ_FAILED because the synthesised bar0=0 means the admin
  submit path fails.  Assert the *return code shape* only, not
  hardware liveness.
- **Wire mode** (guarded by `_nvme_device_count > 0`): if a real
  NVMe controller exists (QEMU nvme model), drive the full round-trip:
  bring-up admin queue via M1, discover namespace via M2, allocate
  MSI-X vectors (#1645), create I/O CQ+SQ (#1646), pick a pair
  (#1649), submit READ of LBA 0 into a caller-owned 4-KiB DMA
  buffer (#1647), verify the read completes and returns 4096 bytes
  (the QEMU nvme image's first sector is deterministic).  Submit
  WRITE to LBA 1 (#1648) then READ-BACK to verify.  Assert the
  written pattern round-trips.

### 6.2 Substrate-mode stages

Stage variable `_nvmeiow_stage : u64` — set to N before step N so a
failing step is diagnosable from the pinned value.

```
     1  reset _nvme_io_pair_table + slot range 128..140
     2  mint synth KIND_PCI_DEV parent (slot 128)
     3  mint synth KIND_HW_INTERRUPT parent (slot 129)
     4  mint synth KIND_NVME_CONTROLLER via M1 path (slot 130, row 0, bar0=0x100000)
     5  mint synth KIND_NVME_NAMESPACE + dual-kind KIND_BLKDEV via M2 path
        (ns_slot=131, blk_slot=132, nsid=1, lba=4096, blocks=100)
     6  nvme_io_msix_alloc_for_ctrl(ctrl_row=0, hw_int_parent=129,
        slot_base=133, ncpu=4) -> expect 0, verify slots 133..136 hold
        KIND_HW_MSIX_VECTOR (0x141) with expected table_offset (k*16)
        and msix_data (k)
     7  verify _nvme_io_pair_table rows 0..3 (ctrl 0, cpu 0..3) all
        carry state == MSIX (1) and msix_row_id from step 6
     8  nvme_io_create_pair(ctrl_row=0, cpu_idx=0) -> expect
        NVMEIO_CQ_FAILED (bar0=0x100000 is synthetic, admin submit
        never completes) BUT the row must not corrupt state; verify
        state still == MSIX
     9  nvme_io_pick_pair(ctrl_row=0) -> expect NVMEIO_PICK_NONE (no
        SQ_LIVE pair on this ctrl)
    10  cap_invoke(slot=132, op_arg = descriptor page encoding
        BDEV_OP_QUERY_FAMILY) -> expect return value = 1 (NVME family)
    11  cap_invoke(slot=132, op_arg = descriptor page encoding
        BDEV_OP_QUERY_GEOM) -> expect (lba << 32) | block_count
    12  cap_invoke(slot=132, op_arg = descriptor page encoding
        BDEV_OP_FLUSH) -> expect BDEV_ERR_UNSUPPORTED
    13  cap_invoke(slot=132, op_arg = descriptor page encoding
        BDEV_OP_READ_LBA, lba=0, nblocks=1, dma_iova=<test buffer>)
        -> expect NVMEIO_PICK_NONE (no SQ_LIVE pair)
    14  nvme_io_msix_revoke_for_ctrl(ctrl_row=0, slot_base=133,
        ncpu=4) -> expect 0, verify slots 133..136 scrubbed (kind==0)
        AND pair rows scrubbed (state==FREE)
    15  stamp KIND_NVME_IO OK fingerprint
```

### 6.3 Wire-mode stages (guarded)

```
    16-25  IF _nvme_device_count > 0:
           run M1 bring-up on real ctrl row -> assert state==NEGOTIATED
           run M2 enumeration -> assert at least one ns row
           call nvme_io_bring_up_all(ctrl_row) -> assert count == min(ncpu, num_io_queues)
           allocate 4-KiB DMA buffer via dma_domain_map
           submit BDEV_OP_READ_LBA(lba=0, nblocks=1) -> assert 4096 bytes
           overwrite buffer with 0xA5 pattern
           submit BDEV_OP_WRITE_LBA(lba=1, nblocks=1) -> assert 4096
           zero the buffer
           submit BDEV_OP_READ_LBA(lba=1, nblocks=1) -> assert 4096
           assert buffer[0..4095] all == 0xA5
           teardown: revoke ctrl cap (cascades through everything)
```

Under BIOS smoke, `_nvme_device_count == 0`, wire-mode stages skip
silently and only stages 1..15 stamp OK.  Under `tools/run-smoke.sh
--nvme` (a flag R51.M3 adds to `tools/run-smoke.sh` that appends
`-drive if=none,file=/tmp/nvme.img,id=n0 -device nvme,...` after
first creating the image with `qemu-img create -f raw /tmp/nvme.img
64M`), stages 16..25 run.

### 6.4 Failing-stage disclosure

If any stage fails, the witness:

1. Stamps `KIND_NVME_IO FAIL\n\0` on the fingerprint tape.
2. Leaves `_nvmeiow_stage` set to the failing stage number.
3. Falls through to boot completion (no panic) so the debugger can
   grep the golden diff, subtract from expected, and know exactly
   which sub-step failed.

This matches the M1/M2 witnesses' shape (their fail path also leaves
their stage variable pinned).

### 6.5 Golden update

`tests/r17/shell-shutdown.golden` gets one new line:

```
    KIND_NVME_IO OK
```

Under `--nvme` smoke, appended after that:

```
    KIND_NVME_IO WIRE OK
```

Both strings pass the `output-provenance-strip.md` regex sweep
(component names only, no round/milestone/issue tags).

---

## 7. paideia-as encoder caveats

### 7.1 Reserved labels

`loop`, `if`, `for`, `while`, `let`, `mut`, `pub`, `fn`, `structure`,
`module`, `unsafe`, `effects`, `capabilities`, `justification`,
`block`, `align`, `uninit` are keywords.  Every asm label in the new
files prefixes the function name.  Suggested prefixes:

- `nvme_iom_`  → `nvme_io_msix_alloc_for_ctrl`
- `nvme_ioc_`  → `nvme_io_create_pair`
- `nvme_ios_`  → `nvme_io_submit_rw`
- `nvme_iod_`  → `nvme_io_completion_drain`
- `nvme_iop_`  → `nvme_io_pick_pair`
- `blkdev_h_`  → `cap_handler_blkdev`

Nothing that reads `.._loop:` or `.._if:` — those parse as reserved.

### 7.2 Lambda arity <= 6

The paideia-as v0.22.x lambda ceiling is 6 args (SysV rdi/rsi/rdx/rcx/r8/r9;
the encoder does not spill).  `nvme_io_submit_rw` hits exactly 6
(ctrl_row, ns_row, opcode, lba, nblocks, dma_iova).  If any signature
needs to grow, spill through a caller-owned struct (the pattern
`cap_handler_blkdev` uses for READ/WRITE args via the descriptor page).

### 7.3 Sized loads for byte / word fields

Reading a byte field (e.g. state at pair-row +1) must be:

```
    xor eax, eax
    mov_b al, [row_addr + 1]
```

`mov` (default 64-bit) would over-read.  The `xor` clears high bits
first so the resulting u64 in `rax` is a clean zero-extended byte.

`mov_b [reg + reg]` — the two-register indexed byte form — trips
G1 in v0.22.x.  Use `mov_b al, [reg + reg * 1]` (explicit scale) or
compute the address into a scratch first.

### 7.4 SysV prologue + 16-byte alignment

At function entry `rsp % 16 == 8` (call pushed the return addr).
`k` callee-save pushes leave `rsp` at `(8 + 8k) % 16`, so a call site
needs total `rsp % 16 == 0` before the next `call` instruction.  The
adjustment table:

| k pushes | after pushes | need before `call` | pad required |
|:---------|:-------------|:-------------------|:-------------|
| 0 | rsp%16==8 | 0 | `sub rsp, 8` |
| 1 | rsp%16==0 | 0 | none |
| 2 | rsp%16==8 | 0 | `sub rsp, 8` |
| 3 | rsp%16==0 | 0 | none |
| 4 | rsp%16==8 | 0 | `sub rsp, 8` |
| 5 | rsp%16==0 | 0 | none |
| 6 | rsp%16==8 | 0 | `sub rsp, 8` |

The `nvme_io_create_pair` (6-push) and `nvme_io_submit_rw` (7-push
after the outer helper decompose) both need the `sub rsp, 8` pad.

### 7.5 r11 scratch only for imm32

All R51.M3 constants (KIND_* = 0x140..0x199, R_* < 0x1000,
NVMEIO_* errors 0xFFFFEC50..0xFFFFEC5F) fit in imm32.  `r11` can be
used freely for temporaries.  Any imm64 would need `mov r11, <imm>`
followed by the operation on `r11` — none of R51.M3's data is that
wide.

### 7.6 Failure-code disjointness

R51.M3 claims the band `0xFFFFEC50..0xFFFFEC5F` (16 codes), one slot
past R51.M1's `0xFFFFEC40..0xFFFFEC4F`:

```
    NVMEIO_MSIX_ENOSPC     0xFFFFEC50
    NVMEIO_MSIX_EPARENT    0xFFFFEC51
    NVMEIO_CQ_FAILED       0xFFFFEC52
    NVMEIO_SQ_FAILED       0xFFFFEC53
    NVMEIO_STATE_BAD       0xFFFFEC54
    NVMEIO_SUBMIT_ENOROOM  0xFFFFEC55
    NVMEIO_SUBMIT_TIMEOUT  0xFFFFEC56
    NVMEIO_SUBMIT_CQE_ERR  0xFFFFEC57
    NVMEIO_PICK_NONE       0xFFFFEC58
    NVMEIO_BAD_ARG         0xFFFFEC59
    NVMEIO_BAD_OP          0xFFFFEC5A
    (0xFFFFEC5B..0xFFFFEC5F reserved for R51.M4 timeout/CFS taxonomy)
```

Disjoint from every prior band; the debugger's failure-code lookup
sees a unique R51.M3-scoped code without cross-round overlap.

### 7.7 Module-file audit posture

Both new files carry the standard header block:
- KIND-adjacent constants (no KIND tag of their own — no new
  0x19C..0x1A7 slot needed).
- Failure taxonomy band (§7.6).
- paideia-as encoder-gap posture line (G1 sized stores; G4 full-register
  compares).
- `unsafe` blocks on every asm function (v0.22.x posture).
- `justification:` block on every `pub let` — audit-review material
  per feedback/user memory ("Do not touch `justification:` blocks —
  those are audit-review material").
- `!{mem, sysreg} @{cap}` effect/capability annotation where the
  function touches cap tables; `!{mem} @{}` for pure row accessors.

---

## Appendix A — Cross-reference table

| R51.M3 issue | Section here | Parent doc reference |
|:-------------|:-------------|:---------------------|
| #1645 R51.M3-001 | §3.1, §4, §5 commit 1 | parent §7 line 837 |
| #1646 R51.M3-002 | §3.2, §5 commit 2 | parent §7 line 838 |
| #1647 R51.M3-003 | §3.3, §3.5, §5 commit 3 | parent §7 line 839 |
| #1648 R51.M3-004 | §3.3, §5 commit 4 | parent §7 line 840 |
| #1649 R51.M3-005 | §3.4, §5 commit 5 | parent §7 line 841 |
| #1650 R51.M3-006 | §6, §5 commit 6 | parent §7 line 842 |

## Appendix B — File-size projection at R51.M3 close

| File | Before | After M3 | Delta |
|:-----|:-------|:---------|:------|
| `src/kernel/core/cap/kind_nvme_controller.pdx` | 1635 | ~1670 | +35 (NVMEC_OP_BRING_UP_IO) |
| `src/kernel/core/cap/kind_nvme_namespace.pdx` | 1674 | ~1720 | +46 (two ctrl forwarders) |
| `src/kernel/core/cap/blkdev_cap.pdx` | 196 | 196 | 0 (mint-gate untouched) |
| `src/kernel/core/cap/nvme_io_queues.pdx` | 0 | ~800 | +800 (new file) |
| `src/kernel/core/cap/kind_blkdev_dispatch.pdx` | 0 | ~320 | +320 (new file) |
| `src/kernel/core/cap/invoke.pdx` | (unchanged size, +1 edge) | +8 | +8 |
| `src/kernel/core/klog/file_ids.pdx` | current | +12 | +12 (two rows) |
| `tests/kernel/nvme/kind_nvme_io_queues_synth.pdx` | 0 | ~450 | +450 (new witness) |
| `tests/r17/shell-shutdown.golden` | current | +1..2 | +1..2 lines |

Total added: roughly 1670 lines of `.pdx` + 450 lines of witness.
No single file exceeds ~1720 lines — the split-off decision (§1) is
what keeps that ceiling in reach.

## Appendix C — What R51.M4 inherits

R51.M4 (flush, TRIM, AER, timeout, CFS recovery) extends what this
milestone lands:

- `cap_handler_blkdev` gains real bodies for `BDEV_OP_FLUSH` (opcode
  0x00) and `BDEV_OP_TRIM` (opcode 0x09 DSM).
- The pair-row `state == QUIESCED` (§2.1) becomes reachable via M4's
  3-strike per-queue reset (delete SQ → delete CQ → recreate CQ →
  recreate SQ).
- The failure band `0xFFFFEC5B..0xFFFFEC5F` (§7.6) claimed for M4
  timeout/CFS codes.
- `nvme_io_submit_rw` gains a per-op deadline (default 30 s) enforced
  by a watchdog thread — the R51.M3 spin budget becomes the inner
  wait, the deadline the outer.
- The IRQ endpoint the CQ drain currently polls becomes real: an
  ASYNC_EVENT_REQUEST-driven `KIND_IPC_ENDPOINT` the supervisor
  subscribes on, sharing wire with AER completions.

None of these require R51.M3 to leave affordances beyond what §2.1's
state-byte reserved value `QUIESCED = 4` and §7.6's reserved code band
already provide.

---
