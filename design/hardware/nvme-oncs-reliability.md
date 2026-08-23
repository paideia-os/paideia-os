# NVMe ONCS-gated Ops + Reliability Tier (R51.M4)

**Status.**  Draft v0.1 (R51.M4 planning, 2026-08-22).
**Parent.**  `design/hardware/nvme-and-disk-substrate.md`
- §2.3 (I/O commands) — FLUSH / DSM / GET_LOG_PAGE / AER opcodes.
- §2.6 (Timeouts + error recovery + queue reset) — the reliability
  charter this milestone substantiates.
- §7 R51 milestone table (M4 block, lines 844-851) — the six R51.M4-00N
  ticket titles.
**Sibling.**  `design/hardware/nvme-io-queues.md` (R51.M3 planning
doc, landed).  This M4 doc extends its file-split rationale, its per-
issue ordering shape, and its paideia-as encoder-caveats block.
**Depends on** (all landed):
- R51.M1 — `KIND_NVME_CONTROLLER = 0x198` at
  `src/kernel/core/cap/kind_nvme_controller.pdx` (1681 lines).  Row
  `+32` already caches ONCS (low 16 bits) from IDENTIFY(controller)
  offset 520.  Accessor: `nvme_ctrl_row_oncs(row_id) -> u64`.
- R51.M2 — `KIND_NVME_NAMESPACE = 0x199` + dual-kind `KIND_BLKDEV`
  mint at `src/kernel/core/cap/kind_nvme_namespace.pdx` (1674 lines).
- R51.M3 — `nvme_io_queues.pdx` (1533 lines), `cap_handler_blkdev.pdx`
  (298 lines), `NVMEC_OP_BRING_UP_IO = 8` on the controller handler.
  Per-CPU I/O pair table `_nvme_io_pair_table[512]` (64-B rows).
  Pair-row `state == NVME_IOP_STATE_QUIESCED (4)` is *reserved* here
  for M4's queue-reset path (M3 file-header note).  Pair row `+56`
  (currently `reserved`) is available for M4 use.
- R24 drivers — `drivers/nvme/regs.pdx` (`NVME_REG_NSSR = 0x20`,
  `NVME_CSTS_CFS = 0x2`, `NVME_CSTS_NSSRO = 0x10`,
  `NVME_CAP_NSSRS_BIT = 36`), `drivers/nvme/identify.pdx`
  (`NVME_ID_CTRL_AERL = 259`), `drivers/nvme/dispatch.pdx`
  (`nvme_admin_submit_poll(bar0, ctx, sqe)`), `drivers/nvme/io_queue.pdx`
  (`nvme_delete_io_sq`, `nvme_delete_io_cq` — the M4 queue-reset needs
  no new admin-side scaffolding).
- R21 — TSC calibrated at boot; `tsc_ns_to_ticks(ns)` and `_tsc_hz`
  in `src/kernel/core/time/tsc.pdx`.  Watchdog deadline math sources
  the tick base from `rdtsc`.
- `design/policy/output-provenance-strip.md` — runtime output must not
  carry `R51.M4-*` or `#165*` tags; witness fingerprint text is
  component-named.

**Scope of this doc.**  Everything R51.M4 substantiates:

- §1 File layout — the three-file split-off decision.
- §2 ONCS gating pattern — where the bit is read, where the gate
  fires, and how a cleared bit surfaces to userspace.
- §3 Data structures new in M4 (deadline table, AER pool, watchdog
  strike counters, CFS state).
- §4 New BDEV op codes + descriptor-page encodings + error taxonomy
  band `0xFFFFEC70..0xFFFFEC7F`.
- §5 Per-op semantic bodies — FLUSH (§5.1), TRIM (§5.2), AER
  refill (§5.3), GET_LOG_PAGE (§5.4), watchdog + queue reset (§5.5),
  CFS + NSSR recovery (§5.6).
- §6 Per-issue implementation order + dependency edges + parallelism.
- §7 Witness plan.
- §8 paideia-as encoder-gap caveats (repeat / delta from M3).
- Appendices — cross-reference, file-size projection, ONCS bit-field
  reference.

**Out of scope for R51.M4** (deferred to M5+ and R52):
- AHCI family (M5..M6).
- The BDEV↔FS rename (`nvme_write.pdx` → `bdev_write.pdx`) — M7.
- Userspace `smartctl`-equivalent — R52+.  This milestone lands the
  admin-side GET_LOG_PAGE plumbing; consumption is a later concern.
- Namespace hot-attach / hot-detach.  AER-delivered namespace-attach
  notices at this milestone are surfaced through the IPC endpoint;
  the mint / revoke cascade against the surfaced NSID list is R52.

---

## 1. File layout — three new files, no in-place growth

`nvme_io_queues.pdx` at M3 close is **1533 lines** (57 KB); pushing
FLUSH + TRIM + AER + LOG_PAGE + watchdog + CFS/NSSR into it would land
it near 3500 lines and re-create exactly the god-file pressure the M3
split-off resolved.  `kind_nvme_controller.pdx` (1681 lines) faces
the same problem for the AER-endpoint hook and the CFS recovery
driver; adding either inline would flip it back over the god-file
threshold the R51 refactor round already committed to holding.

Decision: **three new files, one per concern-cluster**.

| New file | Ownership | Approx size at M4 close |
|:---------|:----------|:------------------------|
| `src/kernel/core/cap/nvme_reliability.pdx` | I/O-queue-side optional ops: `nvme_io_submit_flush` (FLUSH opcode 0x00, ONCS[0] gate) and `nvme_io_submit_trim` (DSM opcode 0x09, ONCS[2] gate, 16-B range-descriptor packing).  Extends the R51.M3 submit path but stays out of `nvme_io_queues.pdx` to keep that file near 1500 lines. | ~500 lines |
| `src/kernel/core/cap/nvme_admin_events.pdx` | Admin-queue-side event surface: AER refill state machine (`nvme_aer_pool_init` / `nvme_aer_refill_one` / `nvme_aer_drain_one`) and GET_LOG_PAGE (`nvme_log_smart_fetch`, `nvme_log_error_info_fetch`).  Both live around the admin queue and share result-page infrastructure. | ~700 lines |
| `src/kernel/core/cap/nvme_recovery.pdx` | Watchdog scanner + 3-strike escalation + queue reset (delete/re-create SQ+CQ pair) + Controller Fatal Status detection + NSSR escalation + controller re-init driver.  All lifecycle/recovery. | ~700 lines |

Rationale for three files rather than one aggregated
`nvme_reliability.pdx`:

- **Ops vs. state machines vs. recovery are three different execution
  shapes.**  FLUSH/TRIM are synchronous callable ops (same shape as
  `nvme_io_submit_rw`).  AER is a persistent pool that has to be
  refilled on every completion (not a caller-driven op).  Watchdog is
  a periodic scanner that runs on a timer tick (nobody calls it).
  CFS handling is a poll-and-react driver.  A file per shape keeps
  the per-file mental model narrow.
- **Cross-file dependencies are one-way.**  `nvme_reliability.pdx`
  → `nvme_io_queues.pdx` (uses pair rows).  `nvme_admin_events.pdx`
  → R24 admin submit surface only (no dependence on I/O queues).
  `nvme_recovery.pdx` → both (watchdog reads I/O pair rows;
  CFS handler drives controller-level re-init through M1 primitives).
  No circular chain, no dependency edge that forces one file to
  precede the others in the build DAG beyond what M3 already imposes.
- **The god-file-refactor directive** (user memory, 2026-08-11)
  applies to `stdlib_lowering.rs` and friends; the same discipline
  imposed proactively on the M4 additions keeps the M5-M8 land plan
  from needing a second refactor round on the kernel side.

**Files touched at R51.M4 close:**

| File | Change | Reason |
|:-----|:-------|:-------|
| `src/kernel/core/cap/nvme_reliability.pdx` | NEW | FLUSH + TRIM (§5.1, §5.2). |
| `src/kernel/core/cap/nvme_admin_events.pdx` | NEW | AER refill + GET_LOG_PAGE (§5.3, §5.4). |
| `src/kernel/core/cap/nvme_recovery.pdx` | NEW | Watchdog + queue reset + CFS + NSSR (§5.5, §5.6). |
| `src/kernel/core/cap/cap_handler_blkdev.pdx` | +2 op bodies | `BDEV_OP_FLUSH` (op 5) and `BDEV_OP_TRIM` (op 6) stop returning `BDEV_ERR_UNSUPPORTED`; dispatch into `nvme_reliability.pdx`.  ~120 lines. |
| `src/kernel/core/cap/blkdev_cap.pdx` | Rights extension | `R_BLK_FLUSH = 0x08`, `R_BLK_TRIM = 0x10`; `R_BLK_ALL` widens `0x07 → 0x1F`.  Matches parent doc §7 R51.M7-002 (the widening lands at M4 — M7 only claims the userspace naming).  ~10 lines. |
| `src/kernel/core/cap/kind_nvme_controller.pdx` | +2 op wires | New `NVMEC_OP_SET_AER_ENDPOINT = 9` (supervisor programs the KIND_IPC_ENDPOINT slot for AER delivery); new `NVMEC_OP_START_WATCHDOG = 10` (supervisor kicks the periodic-tick registration).  ~50 lines. |
| `src/kernel/core/cap/kind_nvme_namespace.pdx` | 0 lines | Nothing in M4 changes namespace semantics; the BDEV dispatcher already forwards through `nvme_ns_row_parent`. |
| `src/kernel/core/klog/file_ids.pdx` | +3 rows | FILE_ID assignments for the three new files. |
| `tests/kernel/nvme/kind_nvme_reliability_synth.pdx` | NEW | R51.M4 witness (§7).  Single witness covers all six issues in staged form (mirroring M3's single-witness shape). |
| `tests/r17/shell-shutdown.golden` | +1..2 fingerprint lines | `KIND_NVME_REL OK` (component-named, no round tag). |

**No touch:** `kind_hw_msix_vector.pdx`, `kind_dma_domain.pdx`, R24
`drivers/nvme/*.pdx` (the M4 uses `nvme_admin_submit_poll` and
`nvme_delete_io_sq` / `nvme_delete_io_cq` unchanged; no new admin-
side scaffold is required).

---

## 2. ONCS gating pattern

### 2.1 Where ONCS is parsed and cached

R51.M1-004 already does the work:

- `src/kernel/core/drivers/nvme/identify_ctrl.pdx` line 62:
  `NVME_IDCTRL_OFF_ONCS : u64 = 520` (u16 within the 4096-byte
  IDENTIFY controller data structure).
- The same file reads the u16 with `mov_w rax, [r13 + 520]` and packs
  it into bits [23:8] of the caller's return value.
- `kind_nvme_controller.pdx` line 1369-1372: on `IDENTIFY_CONTROLLER`
  completion, `and r14, 0xFFFF; call nvme_ctrl_row_oncs_set` stamps
  the u16 into the controller row at `+32` (low 16 bits, remaining 48
  bits zero-padded).
- Public accessor: `nvme_ctrl_row_oncs(ctrl_row_id : u64) -> u64`
  at line 605.  Returns the 16-bit ONCS or `NVMEC_DECODE_BAD`
  (`0xFFFFFFFFFFFFFFFF`) on out-of-range row.

**M4 consumes the cached value.**  No re-issue of IDENTIFY on the
FLUSH/TRIM path — the ONCS bits are stable across a live controller
(they can only change across NSSR, which cascades to a
KIND_NVME_CONTROLLER teardown + fresh mint anyway).

### 2.2 ONCS bit assignment used by R51.M4

Per NVMe spec §5.15.2 (IDENTIFY Controller data structure, ONCS
field at offset 520, u16):

| Bit | Spec name | R51.M4 use |
|:----|:----------|:-----------|
| 0 | Compare | **Gates BDEV_OP_FLUSH** (see 2.3 note). |
| 1 | Write Uncorrectable | Unused at M4. |
| 2 | Dataset Management | **Gates BDEV_OP_TRIM** (matches spec — DSM = TRIM). |
| 3 | Write Zeroes | Unused at M4. |
| 4 | Save/Select nonzero | Unused at M4. |
| 5 | Reservations | Unused at M4. |
| 6 | Timestamp | Unused at M4. |
| 7 | Verify | Unused at M4. |

**Note on the FLUSH ↔ ONCS[0] mapping.**  NVMe FLUSH (opcode 0x00) is
strictly mandatory per §5.8 — a spec-conformant controller ALWAYS
implements it, and ONCS[0] is Compare, not FLUSH.  The parent
substrate doc (`nvme-and-disk-substrate.md` §7 line 846) and this
milestone's issue #1651 nevertheless specify FLUSH as ONCS[0]-gated.
Two consistent readings:

1. **Defensive-uniform** (adopted here): treat FLUSH like every other
   optional op behind an ONCS bit.  Since every modern SSD sets
   Compare (bit 0), the gate is effectively vacuous on real hardware
   and preserves shape symmetry with TRIM's gate.  A synthetic /
   fuzzed controller that clears ONCS[0] gets `BDEV_ERR_UNSUPPORTED`
   on FLUSH, which is defensible (the caller should have consulted
   `BDEV_OP_QUERY_FEATURES` first).
2. **Reinterpret ONCS[0] as "FLUSH advertised"** — a private
   PaideiaOS reading, not spec-conformant.  Unnecessary given (1).

Reading (1) needs no code change if a real controller ever clears
ONCS[0] and refuses FLUSH — the driver will already return
`BDEV_ERR_UNSUPPORTED`, which the FS layer's WAL discipline must
already tolerate for AHCI (where write-cache-present is not
universal).  The gate stays.  Any spec-strict future revision can
drop the FLUSH gate and always-advertise the op — the API surface is
forward-compatible either way (feature bit gets clamped, error stops
being raised).

### 2.3 Gating shape at the callsite

FLUSH path (in `nvme_reliability.pdx`):

```
    call nvme_ctrl_row_oncs               // rax = 16-bit ONCS or DECODE_BAD
    mov r11, 0xFFFFFFFFFFFFFFFF           // imm64 needs r11 (§8.5)
    cmp rax, r11
    je  nvme_rel_flush_bad_row            // → BDEV_ERR_BAD_ROW
    and rax, 1                            // ONCS[0]
    cmp rax, 0
    je  nvme_rel_flush_unsup              // → BDEV_ERR_UNSUPPORTED
    // fall through: build FLUSH SQE + submit through I/O queue
```

TRIM path: same shape with `and rax, 4` (bit 2).

`BDEV_OP_QUERY_FEATURES` in `cap_handler_blkdev.pdx` (currently
hardcodes `0x8` = `WRITE_CACHE_PRESENT` only) grows to consult
`nvme_ctrl_row_oncs` and set:

- bit 0 = `BDEV_FEATURE_FLUSH_SUPPORTED` iff ONCS[0].
- bit 1 = `BDEV_FEATURE_TRIM_SUPPORTED` iff ONCS[2].
- bit 2 = `BDEV_FEATURE_WRITE_ZEROES_SUPPORTED` iff ONCS[3] (bit
  wired but no M4 body; caller sees the bit but a WRITE_ZEROES op
  hasn't been minted).  Reserved for R51.M6+.
- bit 3 = `BDEV_FEATURE_WRITE_CACHE_PRESENT` (unconditional at M4
  — becomes conditional on the SET_FEATURES(FID=0x06) volatile-write-
  cache reply at R51.M7 or later; the R51.M3 hardcoding continues
  its useful-lie tenure through M4).

This is the single caller-facing surface for "what does this device
support" — a well-behaved FS mounter consults it before ever
attempting FLUSH/TRIM/etc.  The `BDEV_ERR_UNSUPPORTED` reply is the
fallback discipline for callers that didn't.

---

## 3. Data structures new in M4

### 3.1 Per-CID deadline table (watchdog input)

Every submitted I/O carries a deadline; the watchdog reads the table
each tick and synthesises a timeout CQE for any entry whose deadline
is past.

```
    _nvme_inflight_deadline : [u64; NVMEC_MAX * NVME_IO_MAX_CPUS * 64]
                                          @align(64) @section(.bss)
```

Layout: `[ctrl_row * 8 + cpu_idx][cid]` — 8 × 8 × 64 × 8 B = 32 KiB
(8 pages), zero-init.  A zero entry means "no in-flight command at
this CID" (a valid deadline is always a large TSC-tick count, so 0 as
sentinel is disjoint from live values).

**Write cadence.**  `nvme_io_submit_rw` (M3), `nvme_io_submit_flush`
(M4), `nvme_io_submit_trim` (M4) all stamp:

```
    rdtsc                                // rdx:rax = current TSC
    shl rdx, 32
    or  rax, rdx                         // rax = 64-bit TSC now
    mov r11, <ticks_for_30s>             // computed once via tsc_ns_to_ticks(30_000_000_000)
    add rax, r11                         // deadline = now + 30s in ticks
    mov [_nvme_inflight_deadline + (ctrl*8 + cpu)*512 + cid*8], rax
```

`nvme_io_completion_drain` (M3, patched at M4) zeroes the entry when
it consumes the matching CQE.

**Deadline default.**  Parent doc §2.6 line 270: "30 s for I/O, 5 s
for admin".  M4 hardcodes both; a SET_FEATURES-driven override is
deferred to R52.

### 3.2 Per-queue strike counter (watchdog escalation)

Add to the pair-row `+56` (currently `reserved` per M3 §2.1
comment):

```
    +56   strikes_and_last : u64
          strikes[15:0]           consecutive timeouts on this queue
          last_reset_tsc[63:16]   TSC-tick when last queue-reset
                                  completed (0 pre-reset); shifted
                                  down by 16 to fit (TSC granularity
                                  = 64K ticks, sufficient for a
                                  seconds-scale "how recent" test)
```

Zero-init means `strikes = 0`, `last_reset_tsc = 0`.  Watchdog
increments strikes on each timeout, calls queue-reset at strike 3,
resets strikes to 0 and stamps last_reset_tsc.  A queue with
`last_reset_tsc` less than 60 s old that hits strike 3 again escalates
to controller-fatal (delegated to §5.6).

### 3.3 AER pool table

```
    _nvme_aer_inflight : [u64; NVMEC_MAX * NVME_AER_MAX]
                                          @align(64) @section(.bss)
    where NVME_AER_MAX = 4                // matches typical AERL and
                                          // parent doc §7 line 848
```

Each entry is a packed 64-bit descriptor:

```
    bits [7:0]   cid          the CID we submitted the AER with
    bits [15:8]  state        NVME_AER_ST_FREE = 0
                              NVME_AER_ST_SUBMITTED = 1
                              NVME_AER_ST_LOG_PENDING = 2
                              (M4 posts LOG_PAGE on demand only, so
                               state 2 is an M5+ hook — for now,
                               completion cycles FREE→SUBMITTED→FREE)
    bits [63:16] reserved     zero
```

Table size: 8 × 4 × 8 B = 256 B.

`nvme_aer_pool_init(ctrl_row_id)` seeds four AERs at controller
bring-up (after `nvme_io_bring_up_all`).

### 3.4 AER-delivery IPC endpoint slot (per controller)

The supervisor programs an endpoint slot the controller-row uses to
route AER completions.  Add to the controller row header at `+56`
(currently `reserved` per M1 §1 layout line 53):

```
    +56  header:
         aer_endpoint_slot[15:0]   cap slot the AER completion is sent to
         reserved[63:16]           zero
```

Set by `NVMEC_OP_SET_AER_ENDPOINT` (new op at value 9, see §1 table).
Zero means "no endpoint yet, drop AER completions on the floor"
(default at bring-up until supervisor connects).

### 3.5 GET_LOG_PAGE result buffers

Two static 4 KiB result pages (one per LID we support at M4), one per
controller — sized for the maximum single-page log payload:

```
    _nvme_log_smart_buf   : [u8; NVMEC_MAX * 4096] @align(4096) @section(.bss)
    _nvme_log_error_buf   : [u8; NVMEC_MAX * 4096] @align(4096) @section(.bss)
```

Total 8 × 4 KiB × 2 = 64 KiB (16 pages).  Alternative: one shared
buffer with a per-controller lock.  M4 takes the static-per-controller
route for simplicity — 16 pages against a 512 MiB RAM budget is
noise.  R52+ can consolidate when SMART consumption crosses into
userspace.

### 3.6 Watchdog periodic-tick hook

Registered against the existing `src/kernel/core/timer/wheel.pdx`
tick.  M4 introduces:

```
    _nvme_watchdog_last_tick : u64        // TSC of last scan
    _nvme_watchdog_period    : u64        // ticks between scans;
                                          // = tsc_ns_to_ticks(1_000_000_000)
                                          // (1 s scan cadence)
```

Both `.bss`, initialised by `nvme_recovery_init(ctrl_row_id)` at
bring-up.  The wheel calls `nvme_watchdog_scan_all()` — a leaf entry
in `nvme_recovery.pdx` — on each tick if `rdtsc - last_tick >=
period`; else no-op.

**Cadence rationale.**  1 s is long enough to fit dozens of I/O
completions between scans (typical NVMe latencies are microseconds),
short enough that a 30 s deadline is caught within one period after
breach.  CFS polling shares the same tick (§5.6).

---

## 4. New BDEV op codes + descriptor pages + error taxonomy

### 4.1 BDEV op inventory after M4

R51.M3 already declared ops 5 and 6 as `BDEV_OP_FLUSH` / `BDEV_OP_TRIM`
(returning `BDEV_ERR_UNSUPPORTED`).  M4 gives them bodies.

| Op | Value | Rights required | Behavior at M4 |
|:---|:------|:----------------|:---------------|
| BDEV_OP_QUERY_GEOM     | 0 | `R_BLK_READ | R_BLK_ADMIN` | unchanged from M3 |
| BDEV_OP_QUERY_FAMILY   | 1 | any non-zero | unchanged from M3 |
| BDEV_OP_QUERY_FEATURES | 2 | any non-zero | **grows** — bits 0/1/2 now driven by ONCS (§2.3) |
| BDEV_OP_READ_LBA       | 3 | `R_BLK_READ` | unchanged from M3 |
| BDEV_OP_WRITE_LBA      | 4 | `R_BLK_WRITE` | unchanged from M3 |
| BDEV_OP_FLUSH          | 5 | `R_BLK_FLUSH` (new bit 0x08) | **body lands** (§5.1) |
| BDEV_OP_TRIM           | 6 | `R_BLK_TRIM` (new bit 0x10) | **body lands** (§5.2) |

`R_BLK_ALL` widens `0x07 → 0x1F` in `blkdev_cap.pdx`.  Older mints
that used `R_BLK_ALL` implicitly get FLUSH/TRIM authorisation for
free — intentional (an admin/write cap should carry FLUSH/TRIM).
An explicit `rights & R_BLK_FLUSH` check gates op 5; ditto TRIM.
Without R_BLK_FLUSH, op 5 returns `INVOKE_DENIED`
(`0xFFFFFFFFFFFFFFFD`) — same shape as M3's rights denials.

### 4.2 Descriptor-page encoding — FLUSH

FLUSH takes no data, no ranges — the descriptor page carries only
the status handshake.  Reuse the M3 page shape with degenerate
fields:

```
    +0    unused         (u64) — MUST be 0 (defensive; ignored)
    +8    unused         (u64) — MUST be 0
    +16   unused         (u64) — MUST be 0
    +24   status_out     (u64) — written back with submit result
```

`op_arg` encoding matches M3: `[7:0]` = op_code (5), `[11:8]` = 0,
`[63:12]` = descriptor-page number.  A caller passing all-zero
`+0..+16` is well-formed; any non-zero value there is silently
ignored (M4 posture; a `BDEV_ERR_BAD_ARG` check on those bytes is
strictly redundant and adds encoder cost).

### 4.3 Descriptor-page encoding — TRIM

TRIM needs a range descriptor list, not a single (lba, nblocks) pair.
The NVMe DSM range descriptor is 16 B per range (Context Attributes
u32 + Length in LBAs u32 + Starting LBA u64), padded to a multiple of
16 with a maximum of 256 entries per DSM command.  So the caller
provides:

```
    +0    range_count    (u64)    number of 16-B descriptors (1..256)
    +8    dsm_desc_iova  (u64)    IOVA of the range-descriptor page
                                  (page-aligned, caller-owned, mapped
                                  into the driver's DMA domain via
                                  R29.M5 dma_domain_map before invoke)
    +16   flags          (u64)    bits [0:0]  ad_bit (1 = deallocate;
                                              only mode we support at M4)
                                  bits [1:1]  idw_bit (integral dataset
                                              for write, unused at M4)
                                  bits [2:2]  idr_bit (unused at M4)
                                  bits [63:3] must be 0
    +24   status_out     (u64)    written back with submit result
```

The range-descriptor page (pointed to by `+8`) is a caller-owned
4-KiB page carrying up to 256 × 16 B entries.  M4 hands it verbatim
to PRP1; the DMA domain enforces the driver-visible IOVA.

### 4.4 Failure taxonomy — the M4 band

Claim `0xFFFFEC70..0xFFFFEC7F` (16 codes, one slot past the M3 blkdev
band `0xFFFFEC60..0xFFFFEC6F`):

```
    NVMEREL_FLUSH_UNSUP        0xFFFFEC70   (ONCS[0] clear)
    NVMEREL_TRIM_UNSUP         0xFFFFEC71   (ONCS[2] clear)
    NVMEREL_TRIM_BAD_RANGES    0xFFFFEC72   (range_count 0 or > 256)
    NVMEREL_TRIM_BAD_FLAGS     0xFFFFEC73   (reserved flag bits set)
    NVMEREL_TRIM_BAD_IOVA      0xFFFFEC74   (dsm_desc_iova not page-aligned)
    NVMEREL_AER_NO_ENDPOINT    0xFFFFEC75   (AER completion arrived,
                                             no endpoint programmed —
                                             logged, dropped, counted)
    NVMEREL_AER_POOL_FULL      0xFFFFEC76   (refill attempt with all
                                             4 slots already SUBMITTED)
    NVMEREL_LOG_BAD_LID        0xFFFFEC77   (LID not in {0x01, 0x02})
    NVMEREL_LOG_TIMEOUT        0xFFFFEC78   (admin submit poll drained)
    NVMEREL_WD_TIMEOUT_INJECT  0xFFFFEC79   (synthetic CQE stamp;
                                             what nvme_io_completion_drain
                                             returns for a watchdog-
                                             synthesized completion)
    NVMEREL_QRESET_FAILED      0xFFFFEC7A   (delete/create loop failed;
                                             escalate to CFS-recovery path)
    NVMEREL_CFS_OBSERVED       0xFFFFEC7B   (informational; return to
                                             callers whose ctrl is CFS)
    NVMEREL_NSSR_FIRED         0xFFFFEC7C   (informational; NSSR
                                             executed successfully)
    NVMEREL_NSSR_NOT_SUPPORTED 0xFFFFEC7D   (CAP.NSSRS clear — CFS
                                             escalation stops here;
                                             namespace revoke cascade
                                             still fires and supervisor
                                             re-mints from scratch)
    (0xFFFFEC7E, 0xFFFFEC7F reserved for R52 attach/detach codes)
```

All sixteen fit imm32 (highest bit set is bit 31, sign-extension
concerns still apply — every compare in the reliability files uses
the R51.M3 `mov r11, <imm>; cmp reg, r11` staged idiom, not the bare
`cmp reg, <imm>` form, per encoder gap G4).

The M3 blkdev-dispatch band (`0xFFFFEC60..EC6F`) is disjoint; the M4
band is disjoint from every earlier band.  A debugger's failure-code
lookup sees a unique code with the file it originated in.

### 4.5 BDEV_OP_QUERY_FEATURES bit-field extension

Currently: hardcoded `0x8` (`BDEV_FEATURE_WRITE_CACHE_PRESENT`) only.
After M4:

| Bit | Constant | Source |
|:----|:---------|:-------|
| 0 | `BDEV_FEATURE_FLUSH_SUPPORTED`         | ONCS[0] |
| 1 | `BDEV_FEATURE_TRIM_SUPPORTED`          | ONCS[2] |
| 2 | `BDEV_FEATURE_WRITE_ZEROES_SUPPORTED`  | ONCS[3] |
| 3 | `BDEV_FEATURE_WRITE_CACHE_PRESENT`     | unconditional at M4 |
| 4 | `BDEV_FEATURE_SMART_AVAILABLE`         | unconditional at M4 (every NVMe implements SMART LID=0x02) |
| 5..63 | reserved | zero |

The handler consults `nvme_ctrl_row_oncs(ctrl_row)` via the M2
forwarder chain (`nvme_ns_row_parent` → ctrl_row_id →
`nvme_ctrl_row_oncs`), then packs the u64 result.

---

## 5. Per-op semantic bodies

### 5.1 FLUSH — `nvme_io_submit_flush` (#1651)

```
    pub let nvme_io_submit_flush :
        (u64, u64) -> u64 !{mem, sysreg} @{cap}
    // args: ctrl_row_id, ns_row_id
    // returns: 0 on OK; NVMEREL_FLUSH_UNSUP if ONCS[0] clear;
    //          NVMEIO_STATE_BAD/SUBMIT_ENOROOM/SUBMIT_TIMEOUT/
    //          SUBMIT_CQE_ERR from the shared submit tail.
```

Sequence:

1. Read `nvme_ctrl_row_oncs(ctrl_row_id)`; check bit 0 (§2.3 shape).
2. Pick a pair via `nvme_io_pick_pair(ctrl_row_id)`.
3. Build SQE at `sq_pa + sq_tail * 64`:
   - `+0` OPC=0x00, CID=`sq_tail & 0xFFFF`.
   - `+4` NSID=`nvme_ns_row_nsid(ns_row)`.
   - `+24..+63` = 0 (no PRP; FLUSH takes no data).
4. Stamp deadline (§3.1) at
   `_nvme_inflight_deadline[ctrl*8+cpu][cid]`.
5. Advance `sq_tail`, doorbell.
6. Poll `nvme_io_completion_drain` for the matching CID with the
   30 s spin budget (M3-inherited).
7. On matching CQE, clear deadline entry, return 0 or the CQE-status
   sentinel through the M3 error taxonomy.

**paideia-as posture.**  2 args, 6-push (rbx=ctrl_row, rbp=ns_row,
r12=pair_row_addr, r13=cid, r14=cpu_idx, r15=deadline) → 48 B; entry
rsp%16==8 → 56, sub rsp,8 → 64, %16==0.

**Rights check.**  The BDEV handler enforces `R_BLK_FLUSH` before
calling into this function; `nvme_io_submit_flush` itself does not
consult rights.

### 5.2 TRIM — `nvme_io_submit_trim` (#1652)

```
    pub let nvme_io_submit_trim :
        (u64, u64, u64, u64, u64) -> u64 !{mem, sysreg} @{cap}
    // args: ctrl_row_id, ns_row_id, range_count, dsm_desc_iova, flags
    // returns: 0 on OK; NVMEREL_TRIM_UNSUP if ONCS[2] clear;
    //          NVMEREL_TRIM_BAD_RANGES/BAD_FLAGS/BAD_IOVA on validation;
    //          NVMEIO_* from the shared submit tail.
```

Sequence:

1. Read `nvme_ctrl_row_oncs`; check bit 2.
2. Validate: `range_count in [1, 256]` → else BAD_RANGES.
   `flags & ~0x7 == 0` → else BAD_FLAGS.
   `dsm_desc_iova & 0xFFF == 0` → else BAD_IOVA.
3. Pick pair, build SQE:
   - `+0` OPC=0x09, CID=`sq_tail & 0xFFFF`.
   - `+4` NSID=`nvme_ns_row_nsid(ns_row)`.
   - `+24` PRP1 = `dsm_desc_iova`.
   - `+32` PRP2 = 0 (range list ≤ 256 × 16 B = 4096 B fits one PRP).
   - `+40` CDW10 = `range_count - 1` (0-based per NVMe §6.6).
   - `+44` CDW11 = flags-with-AD bit pack per §6.6 (`AD << 2 |
     IDW << 1 | IDR`; we ship `AD=1` unconditionally at M4).
   - `+48..+63` = 0.
4. Stamp deadline, doorbell, poll, drain — identical tail to §5.1.

**paideia-as posture.**  5 args (under the 6-arg ceiling), 6-push
callee-save; same alignment shape as FLUSH.

### 5.3 AER refill loop (#1653)

State machine per AER slot (§3.3):

```
    FREE ── nvme_aer_refill_one ─▶ SUBMITTED
      ▲                                │
      │                                │ CQE arrives on admin queue
      │                                ▼
      └────── nvme_aer_drain_one ◀──── (deliver to IPC endpoint,
                                         then free the slot and
                                         immediately refill it)
```

Public API:

```
    pub let nvme_aer_pool_init :
        (u64) -> u64 !{mem, sysreg} @{cap}
    // arg: ctrl_row_id
    // Seeds all NVME_AER_MAX slots by calling nvme_aer_refill_one
    // in a loop.  Returns count of slots that reached SUBMITTED
    // (equal to NVME_AER_MAX on healthy bring-up).

    pub let nvme_aer_refill_one :
        (u64) -> u64 !{mem, sysreg} @{cap}
    // arg: ctrl_row_id
    // Locates the first FREE slot in _nvme_aer_inflight[ctrl_row * NVME_AER_MAX .. +NVME_AER_MAX];
    // builds ASYNC_EVENT_REQUEST SQE (OPC=0x0C, no PRP, no NSID) with a
    // fresh CID; submits through nvme_admin_submit_poll BUT DOES NOT
    // POLL (AER completions arrive asynchronously — this is the entire
    // point of the opcode).  Instead: after submitting, mark slot state
    // as SUBMITTED with the chosen CID, and return.  Returns 0 on OK,
    // NVMEREL_AER_POOL_FULL if no FREE slot.

    pub let nvme_aer_drain_one :
        (u64, u64) -> u64 !{mem, sysreg} @{cap}
    // args: ctrl_row_id, aer_cqe_addr (physical address of a 16-B CQE
    //       harvested by the admin-queue drain path)
    // Parses CQE at aer_cqe_addr (bytes +0..+15) — extracts CID, DW0
    // event info (Event Type[2:0], Event Info[15:8], Log Page ID[23:16]).
    // Locates the AER slot whose CID matches; marks it FREE.
    // Loads the ctrl-row aer_endpoint_slot; if zero, bumps NVMEREL_AER_NO_ENDPOINT
    // counter and returns (drop on the floor).  Else calls
    // endpoint_send(slot, payload_u64) with payload =
    //   (log_page_id << 16) | (event_info << 8) | event_type.
    // Then calls nvme_aer_refill_one(ctrl_row_id) to keep the pool full.
    // Returns 0 on OK.
```

**Non-polling submit is the key semantic.**  AER completions can
arrive minutes after submit; blocking the admin queue is wrong.  R24
`nvme_admin_submit_poll` polls to completion — M4 needs a
**non-polling admin submit** variant.  Extension proposal:

- Add `nvme_admin_submit_nopoll(bar0, ctx, sqe) -> u16` to
  `drivers/nvme/dispatch.pdx` (R24 area but strictly a helper —
  ~40 lines).  Splits `nvme_admin_submit_poll` at the doorbell
  boundary: build+submit → return.
- CQE arrival is picked up on the next admin-queue drain path (M4
  adds a periodic `nvme_admin_drain_cqes` call, driven by the same
  watchdog tick — §3.6).  For each CQE with OPC == 0x0C in its
  associated SQE, invoke `nvme_aer_drain_one`.

Alternative: reuse the R24 admin poll and just accept that the
polling call will spin for AER wait.  Rejected — a single AER pending
would block every subsequent admin command (IDENTIFY, SET_FEATURES,
future GET_LOG_PAGE).

**CID space.**  AER slots take CIDs `0x0100..0x0103` (four values,
picked from a range not used by IDENTIFY (typically 0x0000) or
GET_LOG_PAGE (typically 0x0200..0x0203).  The exact allocation lives
in `nvme_admin_events.pdx` as a private constant.

### 5.4 GET_LOG_PAGE — SMART + error-info (#1654)

```
    pub let nvme_log_smart_fetch :
        (u64) -> u64 !{mem, sysreg} @{cap}
    // arg: ctrl_row_id
    // Submits GET_LOG_PAGE (OPC=0x02) with LID=0x02 (SMART/Health),
    // NUMD = (512/4 - 1) = 127 (in 4-B units; SMART is 512 B), NSID
    // = 0xFFFFFFFF (controller-wide), PRP1 = &_nvme_log_smart_buf[ctrl_row * 4096].
    // Polls admin queue (via nvme_admin_submit_poll; ≤ 100 ms typical).
    // On success returns 0; on error returns NVMEREL_LOG_TIMEOUT or
    // raw CQE status.
    //
    // Caller reads the SMART page from _nvme_log_smart_buf at its
    // ctrl_row slice.  Key fields per NVMe §5.14.1.2:
    //   +0    critical_warning  (u8)
    //   +1    composite_temp    (u16, Kelvin)
    //   +5    percentage_used   (u8)
    //   +32   data_units_read   (u128; low u64 usually sufficient)
    //   +48   data_units_written (u128)
    //   ... (many more)

    pub let nvme_log_error_info_fetch :
        (u64) -> u64 !{mem, sysreg} @{cap}
    // arg: ctrl_row_id
    // Submits GET_LOG_PAGE with LID=0x01 (Error Information),
    // NUMD = (64/4 - 1) = 15 (single 64-B error record; NVMe supports
    // returning up to 63 records but M4 fetches only the latest for
    // the fingerprint witness).  PRP1 = &_nvme_log_error_buf[ctrl_row * 4096].
    // Returns 0 on OK, NVMEREL_LOG_TIMEOUT or raw status on error.
```

**Op layout.**  SQE for GET_LOG_PAGE (opcode 0x02) per NVMe §5.14:

```
    +0    OPC = 0x02, CID = <alloc>
    +4    NSID = 0xFFFFFFFF (controller-wide log)
    +24   PRP1 = &target_buffer
    +32   PRP2 = 0 (all M4 log pages fit in one PRP)
    +40   CDW10 = ((numd_low & 0xFFFF) << 16) | (lsp << 8) | lid
                  lid = 0x02 (SMART) or 0x01 (Error Info)
                  lsp = 0 (Log Specific Field, unused for these LIDs)
                  numd_low = number-of-dwords lower 16 bits
    +44   CDW11 = numd_high[15:0] << 0  (numd = numd_high:numd_low, dwords)
    +48   CDW12 = 0 (Log Page Offset Lower — M4 fetches from offset 0)
    +52   CDW13 = 0 (Log Page Offset Upper)
    +56..+63 = 0
```

`numd` is 0-based; for a 512 B SMART page, `numd = (512/4)-1 = 127`
(fits low 16 bits alone).

**No BDEV-dispatch surfacing at M4.**  A `BDEV_OP_QUERY_HEALTH` at
value 7 would be a natural extension but the parent doc's M7 op
table (line 876) does not include it — SMART surfacing to userspace
is a R52+ concern.  M4 lands the plumbing so future observability
tooling can consume it; the R51.M4 witness (§7) exercises it by
calling the fetch functions directly and verifying the byte-0 (critical
warning) field is zero on a fresh QEMU nvme drive.

**paideia-as posture.**  1-arg leaf-shaped call to admin_submit_poll;
3-push callee-save (rbx=ctrl_row, r12=bar0, r13=admin_ctx) leaves
rsp%16==0; no pad needed.

### 5.5 Watchdog + 3-strike queue reset (#1655)

```
    pub let nvme_watchdog_scan_all :
        () -> u64 !{mem, sysreg} @{cap}
    // Called by wheel tick.  Per §3.6: no-op if
    // (rdtsc - _nvme_watchdog_last_tick) < _nvme_watchdog_period.
    // Else: update last_tick, then for each (ctrl_row_id, cpu_idx,
    // cid) in the deadline table, if deadline != 0 and rdtsc >
    // deadline, synthesize a timeout CQE and bump the pair-row's
    // strike counter (§3.2).  Returns count of timeouts injected.

    let nvme_watchdog_inject_timeout :
        (u64, u64, u64) -> () !{mem, sysreg} @{cap}   // private
    // args: ctrl_row_id, cpu_idx, cid
    // Writes a synthetic CQE at cq_pa + cq_head * 16 with SCT=0x3
    // SC=0x83 (Media and Data Integrity — Timeout, NVMe §3.3.3.2 Fig 121)
    // and the caller's CID.  Advances cq_head + phase.  Zeroes the
    // deadline table entry.  Increments strike counter; if strikes
    // reach 3, calls nvme_queue_reset (below).
    //
    // CAREFUL: the CQE we write races the device's own CQE if the
    // timeout was spurious (the command completed just as we scanned).
    // The R24 drain path already tolerates unexpected CQEs because
    // it consumes by phase-tag not by expected-CID; our synthesised
    // CQE (phase-tag correctly flipped) is indistinguishable from a
    // real one at the drain-path level.  If the device's real CQE
    // arrives after our synth, it appears as a *second* completion
    // for the same CID — the drain loop, seeing an unknown CID
    // (we've already cleared the caller's wait state), simply
    // advances the head and ignores it.  This is safe but does
    // consume one CQ slot briefly.  A doorbell-side re-arm of the
    // completion vector on any injection is not required.

    let nvme_queue_reset :
        (u64, u64) -> u64 !{mem, sysreg} @{cap}   // private
    // args: ctrl_row_id, cpu_idx
    // Per parent §2.6: DELETE_IO_SQ (0x00) via R24 nvme_delete_io_sq;
    // DELETE_IO_CQ (0x04) via R24 nvme_delete_io_cq; state → QUIESCED
    // (M3 §2.1 reserved value 4); zero the SQ/CQ buffers; recreate
    // CQ+SQ via nvme_io_create_pair (M3), rebinding the same MSI-X
    // vector — the pair-row's msix_row_id at +40 is preserved across
    // this operation.  On success reset strikes=0, stamp last_reset_tsc.
    // On failure returns NVMEREL_QRESET_FAILED and leaves state at
    // QUIESCED for the CFS path to escalate (§5.6).
```

**Two-strike vs. three-strike.**  The parent doc (§2.6) explicitly
says "3 consecutive timeouts".  Consecutive here means "no
successful completion drained on this queue between the timeouts" —
implemented as: `nvme_io_completion_drain` (M3), on any real
successful CQE, resets the pair-row's strike counter to 0.  The
strike counter increments only on watchdog-injected timeout CQEs.

**Wall-clock granularity.**  With 1 s scan cadence, a 30 s deadline
gets caught in the interval `[30, 31)` s.  Strike 3 requires three
timeouts on the same queue with no intervening success — call it
90 s minimum before queue reset fires.  This matches Linux nvme's
default: it waits three watchdog intervals before per-queue reset.

**CFS check first.**  Every watchdog tick reads CSTS.CFS first (§5.6);
if set, the timeout injection is *skipped* for the affected controller
— the CFS-recovery path already synthesises abort CQEs for every
in-flight command per parent §2.6.  Double-injection would corrupt
the CQE stream.

**paideia-as posture.**  `nvme_watchdog_scan_all` is a triple-nested
loop (over ctrl_rows × cpu_idxs × cids); the inner two collapse into
a linear scan through `_nvme_inflight_deadline`.  6-push callee-save
plus `sub rsp, 8` (7 slots effectively) — the outer loop pushes
rbx=idx, rbp=deadline_now, r12=timeout_count.  No lambda exceeds 3
args.

### 5.6 Controller Fatal Status + NSSR (#1656)

```
    pub let nvme_cfs_scan_all :
        () -> u64 !{mem, sysreg} @{cap}
    // Called from the same wheel tick as the watchdog (§3.6) —
    // scan iterates over live controller rows, calls
    // nvme_cfs_check_one on each.  Returns count of CFS-observed
    // controllers.

    let nvme_cfs_check_one :
        (u64) -> u64 !{mem, sysreg} @{cap}   // private
    // arg: ctrl_row_id
    // Reads CSTS.CFS via mmio_read_u32(bar0 + 0x1C) & NVME_CSTS_CFS.
    // If zero, return 0 (healthy).  Else:
    //   1. Bump NVMEC_ST_CFS_OBSERVED counter (add to controller-stats
    //      table if not already present).
    //   2. Synthesise abort CQEs (SCT=0x0 SC=0x07 = Command Aborted
    //      due to Failed Fused Command; approximate — the NVMe spec
    //      has no explicit "controller fatal abort" SC, but any
    //      abort-class SC lets callers unblock without misinterpreting
    //      the data path) for every in-flight command across every
    //      pair on this controller — walks _nvme_inflight_deadline
    //      slice and injects via nvme_watchdog_inject_timeout with a
    //      distinguishing SCT/SC.
    //   3. Attempt CC.EN toggle: nvme_reset_controller_soft(bar0) —
    //      new helper in R24 nvme/enable.pdx area (~50 lines).  Poll
    //      CSTS.RDY == 0 with CAP.TO deadline.  If RDY cleared, run
    //      the M1 bring-up sequence (nvme_ctrl_enable →
    //      nvme_identify_ctrl → set_features nvqs → bring_up_io);
    //      preserved row_id, preserved cap slots.  If bring-up
    //      succeeds, return NVMEREL_CFS_OBSERVED (informational).
    //   4. If soft reset failed (RDY stuck), check CAP.NSSRS (bit 36):
    //         if 0: return NVMEREL_NSSR_NOT_SUPPORTED.  Cascade-revoke
    //               every KIND_NVME_NAMESPACE derived from this
    //               controller (kind_nvme_namespace already has the
    //               teardown path); the controller row itself is
    //               left in NEGOTIATED state but with a stamped
    //               "unhealthy" flag (bit in row +56[63:32]) so
    //               subsequent submits refuse with STATE_BAD.  A
    //               supervisor-driven manual re-mint is the recovery
    //               path from this state.
    //         if 1: nvme_nssr_fire(bar0) — writes 0x4E564D65 to
    //               NSSR register (bar0 + 0x20).  Poll CSTS.NSSRO
    //               (bit 4) until observed (CAP.TO deadline).  Cascade-
    //               revoke every KIND_NVME_NAMESPACE.  Reset the
    //               controller row to state = MINTED (undoing
    //               everything past M1 bring-up).  Return
    //               NVMEREL_NSSR_FIRED.  Supervisor re-runs the M1
    //               bring-up + M2 namespace enumeration through its
    //               normal path.
```

**NSSR discipline.**  0x4E564D65 = ASCII "NVMe" (little-endian).  The
NVMe spec §7.3.1 requires exactly this magic; writing any other value
does nothing.

**Namespace revoke cascade.**  Already implemented at R51.M2 —
`kind_nvme_namespace.pdx` has the teardown path.  M4 needs the
"cascade all namespaces on this controller" walker, which is a small
loop over `_nvme_namespace_table` filtering by `parent_ctrl_row`.
Add a public entry `nvme_ns_cascade_revoke_by_ctrl(ctrl_row_id)` in
`kind_nvme_namespace.pdx` (~30 lines).  Wait — the "no touch" table
in §1 said 0 lines to that file.  Correction: this cascade walker
lives in **`nvme_recovery.pdx`** and walks the table by row_id
comparison, calling the existing `nvme_ns_row_revoke` per-row entry.
No new function needs to be exported from `kind_nvme_namespace.pdx`.

**Preserving cap slots.**  Soft reset (case 3) preserves the
KIND_NVME_CONTROLLER cap slot the supervisor holds — the row's data
gets zeroed except for the header's ctrl_idx and state (state → MINTED),
so the supervisor's cap slot handle stays valid.  Namespace slots
are revoked (their caps become invalid to their holders); mounts
above them see EIO on the next op and unmount.

**NSSR path (case 4).**  Same slot-preservation logic; the
controller row survives but at MINTED state.  A supervisor observing
`NVMEC_OP_QUERY_STATE = MINTED` on a controller it had at NEGOTIATED
knows a recovery happened and re-runs bring-up.

**paideia-as posture.**  `nvme_cfs_check_one` is 1-arg but nested
(MMIO read → conditional → soft-reset call → optional NSSR call);
5-push callee-save (rbx=ctrl_row, rbp=bar0, r12=csts, r13=cap_low,
r14=nssrs_bit) leaves rsp%16==0.  `nvme_nssr_fire` is a leaf
(2-push: rbx=bar0, r12=nssro_deadline).

---

## 6. Per-issue implementation order

Six R51.M4 tickets (#1651-#1656).  Dependency edges:

```
    #1653 (AER pool)
        │                       #1651 (FLUSH)     #1652 (TRIM)
        │                            │                │
        │  (share nvme_admin_events) │                │
        │                            └──── shared ────┘
        │                                     │
        ▼                                     ▼
    #1654 (GET_LOG_PAGE)              (cap_handler_blkdev updates
        │                              flow from both)
        │                                     │
        │                                     │
        │        ┌────────────────────────────┘
        │        │
        │        ▼
        │    #1655 (watchdog + queue reset)
        │        │
        │        │  (share scan tick)
        │        ▼
        └────▶ #1656 (CFS + NSSR)
```

Dependency notes:
- **#1651 (FLUSH) ‖ #1652 (TRIM)** — both extend the same submit
  surface but do not depend on each other.  Can land in parallel
  branches or one commit each; the shared `cap_handler_blkdev`
  update is straightforward to merge across the two.
- **#1653 (AER)** is independent — its state machine and refill
  path touch only the admin queue and the new IPC-endpoint hook.
  Can begin before #1651/#1652.  Its non-polling admin submit
  (§5.3) does add a `drivers/nvme/dispatch.pdx` helper that
  #1654 also wants (a caller that submits GET_LOG_PAGE via
  poll but structures the code around the same split), so land
  #1653 first, then #1654 shares its scaffolding.
- **#1655 (watchdog)** depends on the deadline-stamp
  instrumentation being added to `nvme_io_submit_rw` (M3) and to
  `nvme_io_submit_flush` (#1651) / `nvme_io_submit_trim`
  (#1652) — so it lands after those three, otherwise the watchdog
  would scan an empty table and never fire.
- **#1656 (CFS)** depends on #1655's scan-tick cadence — they
  share the wheel-tick registration; #1656 adds `nvme_cfs_scan_all`
  as a second call from the same tick handler.

Recommended landing order per commit:

### Commit 1 — #1653 R51.M4-003 (AER refill loop)

**Scope.**  Add `nvme_admin_events.pdx` with `NVME_AER_MAX = 4`,
`_nvme_aer_inflight` table, `nvme_aer_pool_init`,
`nvme_aer_refill_one`, `nvme_aer_drain_one`.  Add
`nvme_admin_submit_nopoll` to `drivers/nvme/dispatch.pdx`
(~40 lines).  Add `NVMEC_OP_SET_AER_ENDPOINT = 9` to controller
handler with rights `R_NVMEC_ADMIN`.  Add `aer_endpoint_slot` field
to controller row `+56` (§3.4).  Add file_ids row.

**Debugger cue on failure.**  Most likely failure: AER SQE format
error — verify OPC = 0x0C, NSID = 0, no PRP, all data words 0.
Second most likely: pool state confusion; the SUBMITTED-slot
locator scans the table linearly, and a bug in the linear scan
(off-by-one on the range `[ctrl_row * NVME_AER_MAX, +NVME_AER_MAX)`)
would either leak slots or oversubscribe.  Third: the non-polling
admin submit must not return `nvme_admin_submit_poll`'s status —
it returns 0 immediately after doorbell, so any non-zero return
means the doorbell path itself broke.

### Commit 2 — #1654 R51.M4-004 (GET_LOG_PAGE)

**Scope.**  Add `nvme_log_smart_fetch` and `nvme_log_error_info_fetch`
to `nvme_admin_events.pdx`.  Reserve
`_nvme_log_smart_buf` / `_nvme_log_error_buf` in `.bss` (§3.5).
No BDEV wiring at this commit — witness calls fetch functions
directly.

**Debugger cue.**  Most likely failure: CDW10 pack — `numd = 127`
for SMART fits low 16 bits alone; CDW11 = 0 (numd_high = 0).  The
LID goes in the LOW byte of CDW10 (bits [7:0]), not the high byte.
Verify against the R24 IDENTIFY submit's CDW10 shape.  Second most
likely: PRP1 alignment — the buffer must be page-aligned; the
`.bss` `@align(4096)` directive is load-bearing.

### Commit 3 — #1651 R51.M4-001 (BDEV_OP_FLUSH)

**Scope.**  Add `nvme_reliability.pdx` with `nvme_io_submit_flush`.
Wire `cap_handler_blkdev` op 5 (FLUSH) — replace M3's
`BDEV_ERR_UNSUPPORTED` return with rights-check +
`nvme_ctrl_row_oncs` gate + call into `nvme_io_submit_flush`.
Add `R_BLK_FLUSH = 0x08` to `blkdev_cap.pdx` and widen `R_BLK_ALL`.
Extend `BDEV_OP_QUERY_FEATURES` to consult ONCS and set bit 0
accordingly (§4.5).  Add file_ids row.

**Debugger cue.**  Most likely failure: FLUSH SQE builder writes
non-zero to the PRP fields — FLUSH takes no data and NVMe requires
PRP1/PRP2 = 0 on FLUSH per §5.8; a non-zero PRP1 typically gets
back an "Invalid Field In Command" (SC=0x02).  Verify by decoding
the CQE status the NVMEIO_SUBMIT_CQE_ERR reports.  Second: rights
check — R_BLK_FLUSH is a *new* bit at 0x08; a mount that got
`R_BLK_ALL = 0x07` under the M3 encoding cannot FLUSH.  This is a
one-time BUT DELIBERATE break: every M3-era mount was made without
FLUSH authorisation; those callers must re-mint.  The blkdev_cap
version bump (implicit in the `R_BLK_ALL` widening) is the audit
signal.

### Commit 4 — #1652 R51.M4-002 (BDEV_OP_TRIM)

**Scope.**  Add `nvme_io_submit_trim` to `nvme_reliability.pdx`.
Wire `cap_handler_blkdev` op 6 (TRIM) — replace M3's `BDEV_ERR_UNSUPPORTED`.
Add `R_BLK_TRIM = 0x10` to `blkdev_cap.pdx`.  Extend
`BDEV_OP_QUERY_FEATURES` bit 1 (§4.5).

**Debugger cue.**  Most likely failure: range-descriptor pack.
Each 16-B descriptor is `{ctx_attr:u32, length:u32, slba:u64}`; the
common bug is swapping length and slba positions.  Verify by feeding
a single well-known range and checking the CQE status.  Second:
CDW10 pack — the range count is `nr - 1` (0-based per NVMe §6.6),
not `nr`; a bare `range_count` gives one more range than intended
and often reads garbage past the descriptor buffer.  Third: PRP1
alignment on `dsm_desc_iova` — the R51.M4-002 validation catches
non-page-aligned IOVAs upfront; a stale bug that skips the
validation would let the device fault.

### Commit 5 — #1655 R51.M4-005 (watchdog + queue reset)

**Scope.**  Add `nvme_recovery.pdx` skeleton.  Add
`_nvme_inflight_deadline` in `.bss`.  Add strike-counter fields
to pair-row `+56` (§3.2).  Extend `nvme_io_submit_rw` (M3) +
`nvme_io_submit_flush` (#1651) + `nvme_io_submit_trim` (#1652) to
stamp deadlines on submit and clear on completion (three separate
one-line edits, each within the existing 5-push posture — no
alignment change required).  Add `nvme_watchdog_scan_all`,
`nvme_watchdog_inject_timeout`, `nvme_queue_reset`.  Register the
tick handler with `timer/wheel.pdx`.  Add file_ids row.

**Debugger cue.**  Most likely failure: the tick handler is
registered but the wheel never fires it — verify by adding a klog
counter that bumps once per scan and reading it after boot.  Second:
CQE-injection phase-tag confusion — the synth CQE must set the
phase-tag bit to the *expected* value from the pair-row cursor
(`cursors[7:0]`), NOT to the observed device value.  Third: strike
counter increment on real-completion is skipped in a subtle way —
the M3 drain loop already advances cq_head; the M4 patch must add
"if this CQE's SCT/SC == 0, clear strikes" AT THE SAME SITE without
disturbing the M3 phase-tag logic.

### Commit 6 — #1656 R51.M4-006 (CFS + NSSR)

**Scope.**  Add `nvme_cfs_scan_all` / `nvme_cfs_check_one` /
`nvme_nssr_fire` to `nvme_recovery.pdx`.  Add `nvme_reset_controller_soft`
to R24 area (`drivers/nvme/enable.pdx` extension, ~50 lines) as an
alternative entry to the M1 enable path that starts from
`CC.EN=1` and drives back to 0 first.  Register `nvme_cfs_scan_all`
on the same wheel tick.  Add the namespace-cascade walker inside
`nvme_recovery.pdx` (§5.6 note: no export needed from
`kind_nvme_namespace.pdx`).

**Debugger cue.**  Most likely failure: NSSR magic byte-order.
0x4E564D65 is "NVMe" LE — a big-endian write would land 0x654D564E
and be a no-op.  Verify via a 4-byte hex dump at bar0+0x20 after
the write.  Second: CAP.NSSRS bit index — bit 36 spans a 32-bit
boundary if the driver reads CAP as two u32s; the R24 `regs.pdx`
uses `nvme_reg_u64` for CAP so this is not an issue in the M4 code
but is a common site for a debugger's misdiagnosis if they inspect
CAP with a u32 accessor.

### Parallelism

Commits 1, 2, 3, 4 can all begin in parallel branches:
- 1+2 share `nvme_admin_events.pdx` — 2 must wait for 1's file to
  land.
- 3+4 share `nvme_reliability.pdx` — 4 must wait for 3's file to
  land, and both share the `cap_handler_blkdev` edit.

Commits 5 and 6 are strictly sequential after 3+4 (need deadline
stamps on all submit paths) and after each other (5 registers the
wheel tick that 6 hooks a second scan onto).

Practical serial order for the loop shape (feedback/paideia-os
loop shape) — 1 → 2 → 3 → 4 → 5 → 6 — one commit per push, main
builds between each.  Parallel branches make sense only if the
loop tempo hits a debugger stall on one of the earlier commits;
then a second branch on the independent-thread issue keeps forward
progress.

---

## 7. Witness shape

Mirrors R51.M3's single-witness shape.  New file:

```
    tests/kernel/nvme/kind_nvme_reliability_synth.pdx
```

Fingerprint: `KIND_NVME_REL OK\n\0` (18 bytes).  Fail fingerprint:
`KIND_NVME_REL FAIL\n\0` (20 bytes).  **No `R51.M4` or `#165*` in
either string** per `design/policy/output-provenance-strip.md`.

### 7.1 Substrate-mode stages

Runs on every smoke (no `--nvme` requirement — the synthetic
controller row + ONCS forgery lets us exercise the gates without
real MMIO).  Stage variable `_nvmerelw_stage : u64`.

```
     1  reset _nvme_io_pair_table, _nvme_aer_inflight,
        _nvme_inflight_deadline, slot range 128..144
     2  mint synth KIND_NVME_CONTROLLER with ONCS = 0x0000
        (Compare = 0 → FLUSH will refuse; DSM = 0 → TRIM will refuse)
     3  BDEV_OP_QUERY_FEATURES on the dual-kind KIND_BLKDEV slot;
        assert bits 0/1/2 all clear (only bit 3 WRITE_CACHE + bit 4
        SMART_AVAILABLE set)
     4  BDEV_OP_FLUSH → assert NVMEREL_FLUSH_UNSUP
     5  BDEV_OP_TRIM  → assert NVMEREL_TRIM_UNSUP
     6  overwrite ONCS row-field to 0x0005 (Compare | DSM set)
     7  BDEV_OP_QUERY_FEATURES again; assert bits 0 and 1 now set
     8  BDEV_OP_FLUSH → assert NVMEIO_PICK_NONE (no SQ_LIVE pair;
        the gate passed, the submit refused for the M3-consistent
        reason)
     9  BDEV_OP_TRIM with degenerate descriptor (range_count=1,
        dsm_desc_iova=&_test_dsm_page, flags=0x1) → assert
        NVMEIO_PICK_NONE
    10  BDEV_OP_TRIM with range_count=0 → assert NVMEREL_TRIM_BAD_RANGES
    11  BDEV_OP_TRIM with flags=0x100 → assert NVMEREL_TRIM_BAD_FLAGS
    12  BDEV_OP_TRIM with dsm_desc_iova=0x1001 → assert NVMEREL_TRIM_BAD_IOVA
    13  nvme_aer_pool_init(ctrl_row=0) → assert 4 (pool full);
        verify _nvme_aer_inflight[0..4] all in SUBMITTED
    14  nvme_aer_refill_one(ctrl_row=0) → assert NVMEREL_AER_POOL_FULL
    15  synthesise an AER CQE at a scratch page with CID matching
        slot 0's CID; call nvme_aer_drain_one; assert slot 0 back
        to FREE and slot 4 (the immediate refill) in SUBMITTED with
        a fresh CID; assert NVMEREL_AER_NO_ENDPOINT counter bumped
        (no endpoint set yet)
    16  NVMEC_OP_SET_AER_ENDPOINT with slot=128 (a KIND_IPC_ENDPOINT
        pre-minted at stage 1); assert 0 return; verify row +56
        holds slot=128
    17  drain another synth AER CQE; assert endpoint_send was
        called (side-channel: increment a witness-observed counter
        in the mocked endpoint's send path)
    18  seed _nvme_inflight_deadline[0][0..3] with a deadline
        already in the past; call nvme_watchdog_scan_all; assert
        3 timeouts injected; verify pair row 0 strikes == 3;
        verify _nvme_inflight_deadline entries zeroed
    19  assert nvme_queue_reset was called (strikes reached 3);
        assert pair row 0 state == QUIESCED → SQ_LIVE round trip
        (or synthesised SQ_LIVE if no real device)
    20  mock CSTS.CFS = 1 via a scratch bar0 page; call
        nvme_cfs_scan_all; assert NVMEREL_CFS_OBSERVED counter bumped;
        assert (if CAP.NSSRS mocked as 0) NVMEREL_NSSR_NOT_SUPPORTED
        code observed; verify namespace cascade fired (namespace row
        scrubbed)
    21  mock CAP.NSSRS = 1; observe NSSR write at bar0+0x20 = 0x4E564D65
        (byte-order verified); assert NVMEREL_NSSR_FIRED
    22  stamp KIND_NVME_REL OK fingerprint
```

### 7.2 Wire-mode stages (guarded by `_nvme_device_count > 0`)

Optional, gated on real NVMe presence (`tools/run-smoke.sh --nvme`).
Same shape as M3's wire-mode extension:

```
    23  after M1/M2/M3 bring-up (pair reaches SQ_LIVE), issue
        BDEV_OP_FLUSH on a real namespace; assert 0 return
    24  issue BDEV_OP_TRIM with a single 128-block range starting
        at LBA 1024; assert 0 return
    25  fetch SMART via nvme_log_smart_fetch; assert byte 0
        (critical_warning) == 0 on a fresh QEMU nvme drive
    26  fetch error-info via nvme_log_error_info_fetch; assert
        byte 0 (error_count) == 0
    27  stamp KIND_NVME_REL WIRE OK
```

### 7.3 Failing-stage disclosure

On stage failure:
1. Stamp `KIND_NVME_REL FAIL\n\0`.
2. Leave `_nvmerelw_stage` at the failing stage number.
3. Fall through to boot completion (no panic).

Matches M1/M2/M3 witness discipline.

### 7.4 Golden update

`tests/r17/shell-shutdown.golden` gets:

```
    KIND_NVME_REL OK
```

Under `--nvme`, appended:

```
    KIND_NVME_REL WIRE OK
```

Both pass `output-provenance-strip.md` (component names, no round /
milestone / issue tag).

---

## 8. paideia-as encoder-gap caveats

Nothing here departs from R51.M3's posture (`nvme-io-queues.md` §7);
the M4 additions land within the same encoder-version window
(v0.22.x, G1+G4+lambda-arity ceilings).  Below: only the deltas.

### 8.1 Reserved-label discipline

Prefixes for the three new files:

- `nvme_rel_`  → `nvme_reliability.pdx` (all functions)
- `nvme_ae_`   → `nvme_admin_events.pdx` (AER family)
- `nvme_lg_`   → `nvme_admin_events.pdx` (LOG_PAGE family)
- `nvme_wd_`   → `nvme_recovery.pdx` (watchdog family)
- `nvme_cfs_`  → `nvme_recovery.pdx` (CFS family)

No label uses `loop`, `if`, `for`, `while`, `let`, `mut`, `pub`,
`fn`, `structure`, `module`, `unsafe`, `effects`, `capabilities`,
`justification`, `block`, `align`, `uninit` even as a bare
identifier.

### 8.2 Lambda arity ≤ 6

Every M4 function stays under the 6-arg ceiling:
- `nvme_io_submit_flush`: 2 args.
- `nvme_io_submit_trim`: 5 args.
- `nvme_aer_pool_init`: 1 arg.
- `nvme_aer_refill_one`: 1 arg.
- `nvme_aer_drain_one`: 2 args.
- `nvme_log_smart_fetch`: 1 arg.
- `nvme_log_error_info_fetch`: 1 arg.
- `nvme_watchdog_scan_all`: 0 args.
- `nvme_watchdog_inject_timeout`: 3 args.
- `nvme_queue_reset`: 2 args.
- `nvme_cfs_scan_all`: 0 args.
- `nvme_cfs_check_one`: 1 arg.
- `nvme_nssr_fire`: 1 arg.

No spilling required.

### 8.3 Sized loads for byte / word fields

Watchdog byte reads (strike counter at pair-row +56 bits [15:0]) and
AER state byte reads use the M3-established:

```
    xor eax, eax
    mov_b al, [row_addr + off]        // OR mov_w if u16
```

CQE-inject byte writes (synth CQE bytes) also 8-bit clean via
`mov_b [dest], al`.

`mov_b [reg + reg]` — the two-register indexed byte form — trips G1.
The reliability files must use `mov_b al, [reg + reg * 1]` (explicit
scale) or compute the address into a scratch first.  Same rule the
M3 CQE-drain path already follows.

### 8.4 SysV prologue + 16-byte alignment

Deltas from M3's alignment table:

- `nvme_io_submit_flush` (6-push including deadline stamp
  temporaries) needs `sub rsp, 8`.
- `nvme_io_submit_trim` (7-push in worst case) needs `sub rsp, 8`.
- `nvme_aer_drain_one` (5-push: rbx=ctrl_row, r12=cqe_addr,
  r13=cid, r14=slot_idx, r15=endpoint_slot) leaves rsp%16==0.
- `nvme_watchdog_scan_all` (6-push: rbx=idx, rbp=deadline_now,
  r12=timeout_count, r13=ctrl_row, r14=cpu_idx, r15=cid) needs
  `sub rsp, 8`.
- `nvme_cfs_check_one` (5-push, unchanged).

### 8.5 r11 scratch — imm64 pattern

All M4 constants (`NVMEREL_*` errors `0xFFFFEC70..EC7F`,
`NVME_AER_MAX = 4`, ONCS mask bits) fit imm32.  The one imm64
consumer is the DECODE_BAD compare (`0xFFFFFFFFFFFFFFFF`) already
established as the M3/M1 idiom — `mov r11, 0xFFFFFFFFFFFFFFFF;
cmp rax, r11`.  NSSR magic (`0x4E564D65`) fits imm32.

### 8.6 Failure-code disjointness

R51.M4 claims `0xFFFFEC70..EC7F`, one slot past R51.M3's
`0xFFFFEC60..EC6F` (blkdev dispatcher band).  Full R51-band map
after M4:

```
    KIND_NVME_CONTROLLER   0xFFFFEC40..EC4F   (M1)
    NVMEIO_ (nvme_io_queues)  0xFFFFEC50..EC5F   (M3)
    BDEV_ERR_ (blkdev)     0xFFFFEC60..EC6F   (M3)
    NVMEREL_ (reliability) 0xFFFFEC70..EC7F   (M4 — this file)
    (0xFFFFEC80..EC8F reserved for R51.M5 AHCI band)
```

Debugger's failure-code lookup stays unique per code across the
whole R51 family.

### 8.7 Module-file audit posture

Each new file carries the standard header block, mirroring M3:
- KIND-adjacent constants (no new KIND tags; `NVMEREL_*` is a
  utility constant, not a KIND).
- Failure taxonomy band (§4.4).
- paideia-as encoder-gap posture line (G1 sized stores; G4
  full-register compares).
- `unsafe` blocks on every asm function (v0.22.x posture).
- `justification:` block on every `pub let` — audit-review material
  per user memory ("Do not touch `justification:` blocks — those are
  audit-review material").
- `!{mem, sysreg} @{cap}` effect/capability annotation for cap-touching
  functions; `!{mem} @{}` for pure row accessors.

---

## Appendix A — Cross-reference table

| R51.M4 issue | Section here | Parent doc reference |
|:-------------|:-------------|:---------------------|
| #1651 R51.M4-001 (FLUSH)      | §5.1, §6 commit 3 | parent §7 line 846 |
| #1652 R51.M4-002 (TRIM)       | §5.2, §6 commit 4 | parent §7 line 847 |
| #1653 R51.M4-003 (AER)        | §5.3, §6 commit 1 | parent §7 line 848 |
| #1654 R51.M4-004 (LOG_PAGE)   | §5.4, §6 commit 2 | parent §7 line 849 |
| #1655 R51.M4-005 (watchdog)   | §5.5, §6 commit 5 | parent §7 line 850 |
| #1656 R51.M4-006 (CFS+NSSR)   | §5.6, §6 commit 6 | parent §7 line 851 |

## Appendix B — File-size projection at R51.M4 close

| File | Before M4 | After M4 | Delta |
|:-----|:----------|:---------|:------|
| `src/kernel/core/cap/nvme_io_queues.pdx` | 1533 | 1533..1560 | 0..27 (deadline stamps in submit paths) |
| `src/kernel/core/cap/cap_handler_blkdev.pdx` | 298 | ~420 | +120 (FLUSH/TRIM bodies + QUERY_FEATURES extension) |
| `src/kernel/core/cap/blkdev_cap.pdx` | 196 | ~210 | +14 (R_BLK_FLUSH/R_BLK_TRIM/R_BLK_ALL) |
| `src/kernel/core/cap/kind_nvme_controller.pdx` | 1681 | ~1730 | +50 (SET_AER_ENDPOINT + START_WATCHDOG ops; +56 field wiring) |
| `src/kernel/core/cap/nvme_reliability.pdx` | 0 | ~500 | +500 (new) |
| `src/kernel/core/cap/nvme_admin_events.pdx` | 0 | ~700 | +700 (new) |
| `src/kernel/core/cap/nvme_recovery.pdx` | 0 | ~700 | +700 (new) |
| `src/kernel/core/drivers/nvme/dispatch.pdx` | 188 | ~230 | +42 (nvme_admin_submit_nopoll) |
| `src/kernel/core/drivers/nvme/enable.pdx` | 267 | ~320 | +53 (nvme_reset_controller_soft) |
| `src/kernel/core/klog/file_ids.pdx` | current | +18 | +18 (three rows) |
| `tests/kernel/nvme/kind_nvme_reliability_synth.pdx` | 0 | ~600 | +600 (new witness) |
| `tests/r17/shell-shutdown.golden` | current | +1..2 lines | +1..2 |

Total added: roughly 1900 lines of new production `.pdx` + 600
lines of witness.  No single file exceeds ~1730 lines — the
three-file split (§1) is what keeps that ceiling in reach.

## Appendix C — ONCS bit-field reference

Per NVMe base spec v2.0 §5.15.2.4 (IDENTIFY Controller data
structure, ONCS at offset 520, u16 little-endian):

```
    bit 0   Compare (opcode 0x05)
    bit 1   Write Uncorrectable (opcode 0x04)
    bit 2   Dataset Management (opcode 0x09 — TRIM)
    bit 3   Write Zeroes (opcode 0x08)
    bit 4   Save/Select non-zero (SET_FEATURES SV bit)
    bit 5   Reservations
    bit 6   Timestamp (SET_FEATURES FID=0x0E)
    bit 7   Verify (opcode 0x0C in the NVM command set — distinct
            from the admin AER opcode 0x0C in the admin command set)
    bit 8   Copy (opcode 0x19)
    bits [15:9]  reserved
```

R51.M4 consumes bits 0 (FLUSH gate, per §2.2 note), 2 (TRIM gate),
and 3 (WRITE_ZEROES feature-bit surfacing without a body).  Bits
5, 6, 8 are R52+ targets.

## Appendix D — What R51.M5+ inherits from M4

- The reliability-tier file split is a template — R51.M5 AHCI
  gets its own `ahci_reliability.pdx` / `ahci_events.pdx` /
  `ahci_recovery.pdx` triple, with the same concern-cluster
  decomposition.
- The deadline table extends to AHCI naturally: rename to
  `_bdev_inflight_deadline` and dimension by `(family, ctrl_idx,
  port_or_cpu, tag_or_cid)` — the M4 shape already tolerates a
  family dimension by using `ctrl_row * 8 + cpu` as the index; a
  second dimension for `family_tag` folds in without a rewrite.
- The watchdog scan tick is family-agnostic; M5 hooks
  `ahci_watchdog_scan_all` to the same wheel tick.
- The failure-code band discipline continues:
  `0xFFFFEC80..EC8F` for R51.M5, `EC90..EC9F` for M6, etc.
- The AER equivalent on AHCI is the port-interrupt path
  (PxIS + PxIE) — different shape, but the same "background
  event delivery to an IPC endpoint" pattern applies; the
  `KIND_IPC_ENDPOINT` protocol M4 defines for AER is reusable.

---
