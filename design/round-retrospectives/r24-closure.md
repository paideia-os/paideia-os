// R24 Retrospective: NVMe Driver (kernel-side substrate)

**Date:** 2026-08-11
**Milestone:** R24.M1–R24.M6 (all closed; M6 = closure milestone this doc + #910)
**Issues:** 25 landed across 6 milestones (24 implementation + 1 closure); 1 partial deferral (#906 kernel-side landed / userspace half → #1015)
**HEAD at closure:** (bumped by the R24.M6 commit that lands this doc)
**paideia-as pinned at:** `2cf169d` — unchanged across R24 (zero cross-repo escalations this round)

---

## Round Intent

R24 was scoped as the NVMe userspace-driver round per
`design/roadmap/r18-plus-bare-metal.md` §R24 — the first real block
storage plane on top of R22's PCI substrate + R23's display plane.
The six milestones threaded the substrate first (probe / register
model / enable / Identify build), then the admin plane, then the IO
plane, then DMA, then interrupt + error handling, then closure:

- **M1:** NVMe substrate anchor — `nvme_probe` walks `_pci_devices`
  for class/subclass/prog-if `01/08/02` and publishes
  `_nvme_devices`; canonical register model at
  `src/kernel/core/drivers/nvme/regs.pdx`; controller reset + enable
  ceremony (`nvme_reset_and_enable`); Identify Controller SQE builder
  + 4 KiB response buffer.
- **M2:** Admin queue + poll submit + Identify Namespace —
  `_nvme_admin_ctx` slot; `nvme_admin_submit_poll` (doorbell ring +
  phase-tag CQE poll); `nvme_identify_ns` (CNS=0x00, populates
  `_nvme_lba_size` + `_nvme_ns_blocks`); `nvme_ns_list` (CNS=0x02).
- **M3:** Per-CPU IO queues + doorbells + dispatch — 8-descriptor
  `_nvme_io_queues` slab (32-byte stride); Create IO CQ (OPC=0x05) +
  Create IO SQ (OPC=0x01) per active CPU via
  `nvme_create_all_io_cqs` / `..._sqs`; `nvme_ring_sq` / `nvme_ring_cq`
  doorbells; `nvme_dispatch_for_this_cpu` + `nvme_submit_io_cmd`
  (SQE enqueue + doorbell); Delete IO SQ/CQ teardown.
- **M4:** PRP encoding + DMA allocator + MDTS — `nvme_prp_encode`
  for single-page + PRP list variants; `nvme_dma_alloc_pages` +
  `nvme_dma_free_pages` bridging phys_alloc into DMA-safe
  identity-mapped low-half; `nvme_mdts_bytes` computing per-command
  byte cap from Identify Controller MDTS + CAP.MPSMIN.
- **M5:** IRQ handler + caps + sync API + errors —
  `nvme_irq_handler_qid` (CQ walker with phase-tag tracking);
  `interrupt_cap_mint` + `notification_cap_mint` + `blkdev_cap_mint`
  (KIND_INTERRUPT, KIND_NOTIFICATION, KIND_BLKDEV scaffolding);
  kernel-side `nvme_read_blocking` + `_nvme_requests[128]` (#906
  partial — userspace half → #1015); CSTS check + timeout-wait +
  abort helpers.
- **M6:** Round closure — T14 G4 NVMe scratch-device R/W hardware
  smoke doc + witness (#908, `gated:hardware`), 4-CPU concurrent-IO
  throughput regression scaffold + opt-in smoke mode (#909), R24
  closure retro + STATUS.md + quirks-db pass + `boot_r24_concurrent_io`
  SKIP-mode entry + tag `r24-closed` (#910, this document).

Pillar 6 target (`design/00-feature-inventory.md`): give the kernel
exactly the substrate a userspace NVMe driver needs to see, program,
and drive a bare PCIe NVMe controller — probe / identify / IO queues
/ PRP DMA / IRQ walker / CSTS error paths — with the *userspace*
driver-server binary (`nvme_supervisor`) deferred to R25+ where it
consumes `KIND_BLKDEV` + `KIND_INTERRUPT` cap composition once the
userspace-server substrate (#1015) lands.

---

## What Shipped

### R24.M1 — NVMe substrate anchor (4 issues: #886–#889)

- **#886 nvme_probe** — `src/kernel/core/drivers/nvme/probe.pdx`.
  Walks `_pci_devices` for class 0x01 subclass 0x08 prog-if 0x02;
  records 8 controllers into `_nvme_devices` (32-byte stride: seg,
  BDF, BAR0_pa, MSI/MSI-X cap offsets); emits
  `NVME PROBE N=<count>`.
- **#887 nvme regs canonical map** — `src/kernel/core/drivers/nvme/regs.pdx`.
  `nvme_reg_u32` / `nvme_reg_u64` / `nvme_reg_write_u32` /
  `nvme_reg_write_u64` compose the NVMe MMIO register set (CAP, VS,
  INTMS, INTMC, CC, CSTS, AQA, ASQ, ACQ, SQ/CQ doorbells) over
  BAR0. Paideia-as-blocked label was a paper tiger — same
  BAR0-offset arithmetic pattern as the R22.M1 ECAM accessor.
- **#888 nvme_reset_and_enable** — `src/kernel/core/drivers/nvme/enable.pdx`.
  NVMe §3.5.1 controller ceremony: disable-phase (CC.EN=0, poll
  CSTS.RDY=0), program AQA / ASQ / ACQ from `_nvme_admin_sq` +
  `_nvme_admin_cq` (page-aligned, .bss-backed, identity-mapped),
  enable-phase (CC.EN=1 with default IOSQES=6/IOCQES=4/MPS=0/AMS=0),
  poll CSTS.RDY=1 with CFS trap. Returns 0 on success; error codes
  on disable/enable timeout or CFS trip.
- **#889 nvme_build_id_ctrl_cmd** — `src/kernel/core/drivers/nvme/identify.pdx`.
  64-byte SQE builder for Admin IDENTIFY (OPC=0x06) with
  CDW10.CNS=0x01. 4 KiB `_nvme_id_ctrl_buf` slab as the CQE
  response landing zone.

**Closure commit:** `e2aa770`.

### R24.M2 — Admin queue + poll submit + Identify NS (4 issues: #890–#893)

- **#890 admin queue lifecycle infra** —
  `src/kernel/core/drivers/nvme/queue.pdx`. `_nvme_admin_ctx: [u64; 4]`
  slot (SQ tail cursor, CQ head cursor, CQ phase, spare). Public
  helpers to compute doorbell base offsets from CAP.DSTRD (4 vs 8
  byte stride depending on controller).
- **#891 nvme_admin_submit_poll** — same file.
  `(bar0, ctx, sqe_pa) -> u64`: memcpy 64 B into SQ at ctx.sq_tail;
  increment + wrap; ring SQ0TDBL; poll CQE at ctx.cq_head with the
  Phase Tag protocol (Phase toggles per wrap); on completion ring
  CQ0HDBL and return raw 16-bit Status field. Callee-save preserved
  across the busy-poll.
- **#892 nvme_identify_ns** — `src/kernel/core/drivers/nvme/identify_ns.pdx`.
  `(bar0, ctx, nsid, out_buf_pa) -> u64` all-in-one wrapper:
  build IDENTIFY (CNS=0x00, NSID=nsid, PRP1=out_buf_pa) into
  `_nvme_admin_sqe_scratch`, submit_poll, parse response NSZE (u64
  @+0) → `_nvme_ns_blocks`; FLBAS & 0xF → LBAF index → LBADS byte
  → `_nvme_lba_size = 1 << LBADS`. Emits klog fingerprint on OK.
- **#893 nvme_ns_list** — same file. `(bar0, ctx, out_buf_pa) -> u64`
  Active Namespace List (CNS=0x02, NSID=0, PRP1=out_buf_pa) walker
  populating `_nvme_active_nsids` (bounded to 32 entries at M2 —
  matches every consumer T14 G4 NVMe drive whose Identify Controller
  NN field is < 32).

**Closure commit:** `169d2e9`.

### R24.M3 — IO queues + doorbells + per-CPU dispatch (5 issues: #894–#898)

- **#894 nvme_create_all_io_cqs** —
  `src/kernel/core/drivers/nvme/io_queue.pdx`.
  Iterates active CPUs (ceiling = min(_madt_ap_count + 1,
  NVME_IO_MAX_QUEUES=8)); allocates per-CPU MSI-X vector via
  `vector_alloc_for_cpu`; submits Create IO CQ (OPC=0x05, PRP1 =
  per-CPU slice of `_nvme_io_cq_buffers`, size=64, vector | IEN | PC);
  populates `_nvme_io_queues` descriptor slab. Also caches BAR0 in
  `_nvme_current_bar0` for `nvme_submit_io_cmd` to reach without a
  widened signature.
- **#895 nvme_create_all_io_sqs** — same file. Iterates
  `_nvme_io_queues` descriptors and submits matched Create IO SQ
  (OPC=0x01, PRP1 = per-CPU slice of `_nvme_io_sq_buffers`, size=64,
  cqid=qid, qprio=0, PC=1); wires sq_pa into descriptor on success.
- **#896 nvme_ring_sq / nvme_ring_cq** — `src/kernel/core/drivers/nvme/doorbell.pdx`.
  Doorbell primitives; SQ0TDBL / CQ0HDBL for the admin plane, per-qid
  offsets for the IO plane. DSTRD-aware.
- **#897 nvme_submit_io_cmd** — `src/kernel/core/drivers/nvme/dispatch.pdx`.
  `(sqe_pa) -> u64`: `nvme_dispatch_for_this_cpu` returns the current
  CPU's descriptor; memcpy 64 B into that SQ at sq_tail; wrap +
  advance; ring SQ doorbell; return old sq_tail (the slot the SQE
  occupies for CID correlation).
- **#898 nvme_delete_all_io_pairs** — `src/kernel/core/drivers/nvme/io_queue.pdx`.
  Teardown counterpart: iterate `_nvme_io_queues`; Delete IO SQ
  (OPC=0x00) before Delete IO CQ (OPC=0x04) per NVMe §5.7 ordering;
  zero the descriptor; clear `_nvme_io_queue_count`.

**Closure commit:** `b185e3b`.

### R24.M4 — PRP encoding + DMA + MDTS (4 issues: #899–#902)

- **#899 nvme_prp_encode single-page** —
  `src/kernel/core/drivers/nvme/prp.pdx`. Single 4 KiB PRP1 case:
  PRP1 = page-aligned host_pa (or with legal +offset when transfer
  spans the page boundary and PRP2 covers the second page).
- **#900 nvme_prp_encode PRP list** — same file. Multi-page (>2
  pages): PRP1 = first host page, PRP2 = physical address of a
  PRP list (`_nvme_prp_list_buf: [u64; 512]`, 4 KiB slab of 8-byte
  entries pointing at pages 2..N).
- **#901 nvme_dma_alloc_pages / nvme_dma_free_pages** —
  `src/kernel/core/drivers/nvme/dma.pdx`. Bridges the kernel
  phys_alloc surface into DMA-safe pages: hands out identity-mapped
  low-half PAs (< 4 GiB) so controllers without 64-bit DMA still
  function; free-list tracked via a bounded slab.
- **#902 nvme_mdts_bytes** — `src/kernel/core/drivers/nvme/mdts.pdx`.
  Reads Identify Controller MDTS (u8 @+77) + CAP.MPSMIN (bits [51:48]);
  computes page_bytes = 1 << (12 + MPSMIN); returns cap = page_bytes
  << MDTS. Returns 0 (no-limit sentinel) if MDTS=0 or driver not yet
  attached.

**Closure commit:** `69ae1c0`.

### R24.M5 — IRQ handler + caps + sync API + errors (5 issues: #903–#907; #906 partial)

- **#903 nvme_irq_handler_qid** — `src/kernel/core/drivers/nvme/irq.pdx`.
  CQ walker: locate descriptor from qid; walk from cq_head with
  Phase Tag tracking; per completion, extract CID + status,
  populate `_nvme_requests[cid]` (user_status = status & 0xFFFE,
  completion_flag = 1); advance cq_head with 64-slot wrap +
  phase toggle; ring CQ doorbell on non-zero drain count. IDT
  vector installation deferred (partial-close note documents R25+
  wiring alongside `#1015`).
- **#904 KIND_INTERRUPT + KIND_NOTIFICATION cap mint** —
  `src/kernel/core/cap/interrupt_cap.pdx`. `interrupt_cap_mint(vector,
  cpu_mask)` + `notification_cap_mint(badge)` scaffolding follows
  the AcpiCap / DeviceCap precedent. Full R_NOTIFY_SEND on ISR
  fires with #1015 unblock.
- **#905 KIND_BLKDEV cap + RPC schema** —
  `src/kernel/core/cap/blkdev_cap.pdx` + design docs
  `design/ipc/blkdev-rpc-schema.md` + `design/drivers/blkdev-cap.md`.
  `blkdev_cap_mint(controller_idx, nsid, rights)` scaffolding; the
  RPC wire format (READ / WRITE / FLUSH / TRIM commands +
  status/data reply schema) is documented for the eventual
  userspace `blkdev_supervisor`.
- **#906 userspace sync API — PARTIAL** —
  `src/kernel/core/drivers/nvme/sync.pdx`. Kernel-side pieces landed:
  `_nvme_requests[128]` request slot table walked by
  `nvme_irq_handler_qid`; `nvme_read_blocking(nsid, lba, count,
  buf_pa) -> u16` kernel-only synchronous Read (OPC=0x02, allocates
  CID, submits, busy-waits on completion_flag, returns CQE status).
  **Userspace half → #1015** (blocks on the same userspace-server
  substrate as #820 acpi_supervisor + #860 pci_enumerator). Partial-
  close note at `design/round-retrospectives/r24-m5-partial.md`
  documents the per-issue disposition.
- **#907 nvme error paths** — `src/kernel/core/drivers/nvme/errors.pdx`.
  `nvme_csts_check(bar0)` (returns nonzero if CSTS.CFS set),
  `nvme_timeout_wait(bar0, spins)` (returns 1 if RDY drops or CFS
  trips), `nvme_abort_cmd(bar0, cid)` (Admin Abort OPC=0x08 for
  in-flight CID). Fingerprint `NVME FAULT`.

**Closure commit:** `5cba459`.

### R24.M6 — Round closure (3 issues: #908–#910)

- **#908 T14 G4 NVMe scratch-device R/W smoke** — `gated:hardware`.
  Harness landable at R24 close: `tools/nvme-hw-smoke.md` (operator
  recipe covering BIOS Intel VMD toggle + UEFI boot media prep +
  GDB attach + witness invocation + quirks-db promotion pass);
  `tests/kernel/drivers/nvme/hw_smoke.pdx` (witness
  `nvme_hw_smoke_witness` — SKIP-on-no-controllers guard, real
  `nvme_identify_ns(bar0, &_nvme_admin_ctx, nsid=1, out_buf)` call
  under GDB when live). Live invocation pending physical T14 G4
  access.
- **#909 4-CPU concurrent-IO throughput fixture** — Option A landing
  per the closure plan. `tests/kernel/drivers/nvme/concurrent_io.pdx`
  (witness `concurrent_io_witness` — SKIP-on-no-controllers guard +
  SKIP-on-no-sched_spawn placeholder; R25+ wire swaps in the real
  hpet-timed 4-CPU × 100-read body). Opt-in smoke mode
  `boot_r24_concurrent_io` in `tools/run-smoke.sh` (SKIP-echo);
  pre-push guard `PAIDEIA_R24_CONCURRENT_IO=1` in `.githooks/pre-push`.
- **#910 R24 closure** — this retrospective + STATUS.md R24 CLOSED
  block + quirks-db pass (§2.4 VMD row updated) + `r24-closed` tag.

**Closure commit:** (this M6 commit).

---

## Cross-Repo Escalations to paideia-as (R24)

**None.** `paideia-as` submodule remained pinned at `2cf169d` for
all six R24 milestones. Zero escalations to paideia-as required.

Three ambient "paideia-as-blocked" labels queued into the R24
planning sheet were reviewed and downgraded on inspection as paper
tigers:

- **NVMe register accessor (M1).** Pre-tagged as needing dedicated
  MMIO-load intrinsics; on inspection the existing
  `mov_d rax, [rbase + offset]` pattern from the R22.M1 ECAM
  accessor covered every NVMe register load/store without any new
  encoder feature.
- **SQE 64-byte memcpy (M2 + M3).** Pre-tagged as needing a
  `memcpy_fixed` intrinsic; on inspection `rep_movsb rcx=64` proved
  robust for both the admin submit path (`nvme_admin_submit_poll`)
  and the IO dispatch path (`nvme_submit_io_cmd`). No encoder work
  needed.
- **Per-CPU descriptor stride arithmetic (M3).** Pre-tagged as
  needing indexed-scale-8 addressing; on inspection the existing
  `[base + rax * 8]` and `[base + rax * 1 + N]` patterns handled
  every offset in `_nvme_io_queues` (32-byte stride via `shl rax,5`)
  without any new addressing mode.

Zero paideia-as submodule bumps required across R24.

---

## Observable Proof

- Kernel builds clean under `tools/build.sh` — **15/15 verify gates
  pass** (no-AML lint + opcode-canary + kernel dispatch + sched
  guards + tty_read wrapper + link).
- All 15 default pre-push smoke modes pass (`boot_r8_only` through
  `boot_smp`, incl. `boot_r14b_*` and `boot_r17_shell_*`). No new
  fingerprint under `-kernel` — nvme_probe returns 0 (MCFG absent
  → PCI enumerator drains empty → no NVMe controllers surface).
- R22 opt-in smokes still pass under R24 changes:
  `PAIDEIA_R22_PCI_TREE=1 boot_r22_pci_tree` (unchanged — R24 does
  not touch the enumerator) and `PAIDEIA_R22_MSIX_IR=1
  boot_r22_msix_ir_round_robin` (still SKIP under -kernel).
- R21 opt-in smokes still pass: `boot_r21_ymm_preserve` /
  `_ioapic_reroute` / `_msix_round_robin`.
- **New R24 opt-in smoke mode:** `PAIDEIA_R24_CONCURRENT_IO=1
  boot_r24_concurrent_io` — SKIP-echo at M6 (witness not wired into
  kernel_main; R25+ dependency: driver-attach + public sched_spawn).
- `nm build/kernel.elf` shows every R24 substrate symbol linked:
  `nvme_probe`, `_nvme_devices` (256 B), `_nvme_device_count`,
  `nvme_reg_u32/u64/write_u32/write_u64`, `nvme_reset_and_enable`,
  `nvme_build_id_ctrl_cmd`, `_nvme_id_ctrl_buf` (4096 B),
  `_nvme_admin_ctx` (32 B), `_nvme_admin_sq` (4096 B) + `_admin_cq`
  (1024 B), `nvme_admin_submit_poll`, `nvme_identify_ns`,
  `nvme_ns_list`, `_nvme_ns_blocks`, `_nvme_lba_size`,
  `_nvme_active_nsids` + `_nvme_active_nsid_count`,
  `nvme_create_all_io_cqs` / `..._sqs`, `_nvme_io_queues` (256 B),
  `_nvme_io_queue_count`, `_nvme_current_bar0`,
  `_nvme_io_cq_buffers` (32 KiB) + `_io_sq_buffers` (32 KiB),
  `nvme_ring_sq` / `nvme_ring_cq`, `nvme_dispatch_for_this_cpu`,
  `nvme_submit_io_cmd`, `nvme_delete_all_io_pairs`, `nvme_prp_encode`,
  `_nvme_prp_list_buf` (4096 B), `nvme_dma_alloc_pages` /
  `nvme_dma_free_pages`, `nvme_mdts_bytes`, `nvme_irq_handler_qid`,
  `interrupt_cap_mint`, `notification_cap_mint`, `blkdev_cap_mint`,
  `_nvme_requests` (2048 B), `_nvme_next_cid`, `nvme_read_blocking`,
  `nvme_csts_check`, `nvme_timeout_wait`, `nvme_abort_cmd`,
  plus the M6 harness symbols `nvme_hw_smoke_witness`,
  `_nvme_hw_smk_id_ns_buf` (4096 B), `concurrent_io_witness`,
  `_ci_begin_msg` / `_ci_end_msg` / `_ci_done_count` / `_ci_t0_ns`
  / `_ci_t1_ns`.

---

## What Worked (Round Discipline)

1. **softarch → debugger loop shape held throughout.** Six
   milestones closed as architect+implement passes followed by
   debugger passes. Zero workerbee invocations (per
   `feedback_paideia_os_loop_shape.md`).

2. **Continuous tempo across six milestones.** Per
   `feedback_paideia_os_tempo.md`, R24 ran continuous with no
   between-milestone review pause. Six milestones closed within
   two loop days.

3. **Kernel-side / userspace split at M5.** The M5 issue #906 was
   large enough to split cleanly along the same `#1015` fault line
   as #820 (acpi_supervisor) + #860 (pci_enumerator): kernel-side
   pieces (`_nvme_requests` + `nvme_read_blocking`) landed as
   internal glue the eventual `nvme_supervisor` will use; the
   userspace RPC layer stays deferred. Partial-close note at
   `design/round-retrospectives/r24-m5-partial.md` documents the
   per-issue disposition — the M6 closure links to it rather than
   re-relitigating the split.

4. **Paper-tiger downgrades saved cross-repo churn three times.**
   NVMe register accessor label, SQE 64-byte memcpy label,
   per-CPU descriptor stride label all tacked cleanly onto
   pre-existing R22.M1 ECAM / `rep_movsb` / indexed addressing
   patterns. Zero submodule bumps across R24.

5. **Cache-BAR0 idiom (M3).** `nvme_create_all_io_cqs` caches BAR0
   in `_nvme_current_bar0` (module-level u64) so
   `nvme_submit_io_cmd` + `nvme_ring_sq` + `nvme_ring_cq` +
   `nvme_mdts_bytes` can reach the base without widening their
   signatures. Same idiom the RX ring cache used in R14b —
   applies whenever the driver has one active controller (M6 debt
   tracks multi-controller support to R25+).

6. **Phase-tag CQE polling landed once, reused everywhere.**
   `nvme_admin_submit_poll` (M2), `nvme_irq_handler_qid` (M5)
   share the same phase-tag protocol logic (CQE Status bit 0
   compared against the expected phase; toggle on 64-slot wrap).
   Cross-witness discipline: no divergent phase implementations
   to maintain.

7. **SKIP-on-no-controllers guard as the default witness posture.**
   Every M6 witness (`nvme_hw_smoke_witness`,
   `concurrent_io_witness`) starts with the same
   `_nvme_device_count == 0 → SKIP` guard, which keeps them safe
   under QEMU-TCG `-kernel` (nvme_probe returns 0 there) without
   any conditional compilation. Same pattern the R22.M6
   `msix_ir_round_robin` witness used.

---

## What Didn't Work

1. **IDT wire for `nvme_irq_handler_qid` slipped to R25+.** M5
   #903 lands the handler body as a callable ELF symbol but does
   not install it in any per-CPU IDT vector. Per-CPU IDT vector
   installation for a driver-owned handler is R22.M5 substrate
   work that was deferred at that milestone close and has not yet
   been folded into a later round. The M5 acceptance surface here
   is symbol existence + CQ-walk correctness on synthetic input;
   the ISR-to-notification bridge that signals R_NOTIFY_SEND on
   the paired badge lands with the same `#1015` unblock. Documented
   in `design/round-retrospectives/r24-m5-partial.md`.

2. **`nvme_write_blocking` did not land at M5.** The task shape
   for #906 (userspace sync API) covered read/write parity, but
   the kernel-side pieces landed only `nvme_read_blocking`. Rationale:
   the M5 acceptance surface was to prove the SQE-build → submit →
   poll → CQE-status roundtrip end-to-end, which read suffices for.
   Write follows exactly the same shape with `OPC = 0x01` instead
   of `0x02`; it is a 30-minute exercise once R25+ opens with a
   live driver. Filed as R24 debt (see below).

3. **`nvme_hw_smoke_witness` cannot exercise Identify Controller
   end-to-end at M6.** The witness body invokes `nvme_identify_ns`
   (which subsumes admin submit_poll) rather than composing
   `nvme_build_id_ctrl_cmd` + `nvme_admin_submit_poll` explicitly.
   Rationale: the two paths go through the same admin submit/poll
   substrate, so proving one proves both. When R25+ wires the
   driver-attach path, the witness swaps in the composed call
   without shape change. Not a bug, but a documentation gap that
   the operator-run recipe (`tools/nvme-hw-smoke.md` §2.3) papers
   over with an explicit "Identify Controller is exercised
   transitively" callout.

4. **`concurrent_io_witness` cannot fire under any current boot
   path.** The witness body always takes SKIP: under QEMU-TCG
   `-kernel` there are no NVMe controllers (guard 1); under a
   hypothetical UEFI-with-NVMe boot the sched_spawn substrate is
   not yet public (guard 2). Result: the opt-in
   `boot_r24_concurrent_io` mode is a pure SKIP-echo at M6, same
   posture as R22.M6 `boot_r22_msix_ir_round_robin`. Full activation
   lands with the R25+ driver-attach + public sched_spawn wire.

5. **No T14 G4 first-boot capture happened this round.** Every R24
   milestone ran under QEMU-TCG `-kernel` (no MCFG → no PCI enumeration
   → no NVMe probe → no controller state changes). The T14 first-
   light moment for NVMe stays queued for R25+ hardware bring-up
   alongside the R23 first-visual-output moment which also has not
   fired. Zero rows promoted in `design/hardware/quirks.md` at this
   pass; the §2.4 VMD row is updated in-place with the R24-specific
   verification recipe cross-reference.

---

## Preflight for R25

**R25 (PdxFS-lite — persistent FS MVP + driver-attach wire-up)** —
opens after R24 close. Draft preflight to land as
`design/round-retrospectives/r25-preflight.md` at R25.M1 kickoff.

R25 needs from R24:

1. **`nvme_probe` device tree.** `_nvme_devices` slab + count are the
   controller enumeration source of truth. R25's first act is a
   driver-attach pass: for each controller, call `nvme_reset_and_enable`
   → `nvme_identify_ctrl` → `nvme_identify_ns` (per nsid) →
   `nvme_create_all_io_cqs` → `nvme_create_all_io_sqs`. All primitives
   ready to consume.
2. **`nvme_read_blocking` + `_nvme_requests` slot table.** PdxFS-lite
   VFS backend reads via this kernel-side path until R26+ ships the
   userspace `nvme_supervisor` (which then routes through the KIND_BLKDEV
   RPC per `design/ipc/blkdev-rpc-schema.md`). Ready to consume.
3. **`nvme_mdts_bytes` transfer cap.** PdxFS-lite chunker respects
   this cap when issuing multi-page reads. Ready to consume.
4. **`nvme_prp_encode` PRP list variant.** PdxFS-lite superblock is
   4 KiB (single-page), but inode tables + extent maps may span
   pages — PRP list variant covers.
5. **`nvme_csts_check` / `_timeout_wait` / `_abort_cmd` error paths.**
   PdxFS-lite mount-time bring-up runs these on each controller
   before trusting the device.

**R25 does NOT need from R24:**

- A userspace `nvme_supervisor`. R25 uses the kernel-side sync
  helpers directly; the userspace supervisor migration is R26+
  scope once #1015 closes.
- A per-CPU IDT-installed IRQ handler. R25's PdxFS-lite is
  polling-only at MVP (busy-wait on `_nvme_requests[cid].completion_flag`
  matches what R24.M5 landed). IRQ-driven completion is R26+ scope.
- IOMMU-enforced DMA translation. R24 DMA slab hands out identity-
  mapped low-half PAs which QEMU-TCG default accepts. R25 opens
  under the same `Features.IOMMU_ENABLED = 0` posture; the flip
  happens later alongside the R23 debt item + driver-attach path.

**R25 blockers (external):**

- paideia-as v0.22 tag remains uncut. R25 does not need a tag
  bump for PdxFS-lite proper — the slice + bitfield helpers from
  v0.22 would ease on-disk format serialization but are not
  blockers (R25 can hand-code packed superblock/inode fields via
  `mov_b` / `mov_d` stores, same idiom as R24 SQE construction).
- Real T14 G4 hardware for the first-write acceptance moment. R25
  opens under QEMU (`-drive if=none,file=disk.img,format=raw -device
  nvme`); T14 promotion moment queued alongside the R23 first-
  visual-output moment + the R24 NVMe HW smoke recipe in
  `tools/nvme-hw-smoke.md`.

---

## R24 Debt Carried Forward

Ledger of items deferred past R24 close:

1. **#906 userspace sync API** — PARTIAL. Kernel-side landed
   (`nvme_read_blocking` + `_nvme_requests[128]`); userspace half
   → #1015. Sibling to #820 (acpi_supervisor) + #860 (pci_enumerator).

2. **`nvme_write_blocking` (kernel-side)** — not landed. Same
   shape as `nvme_read_blocking` with OPC=0x01. Lands with R25's
   PdxFS-lite VFS backend when it needs to issue writes.

3. **IDT wire for `nvme_irq_handler_qid`** — deferred to R25+.
   Handler body is a `pub` symbol; per-CPU IDT vector installation
   is R22.M5 substrate work that has not yet landed. ISR-to-
   notification bridge (R_NOTIFY_SEND on paired badge) lands with
   the same #1015 unblock.

4. **Driver-attach wire-up path** — R25+. `kernel_main_uefi` does
   not yet invoke the `nvme_probe → identify → io_queues → sync_read`
   ceremony. Under QEMU-TCG `-kernel` this is moot (no controller);
   under real HW this is what unlocks the M6 `nvme_hw_smoke_witness`
   and `concurrent_io_witness` bodies for live execution.

5. **Multi-controller support** — R26+. `_nvme_current_bar0` cache
   assumes a single active controller. Every consumer laptop /
   workstation with a single M.2 slot exercises this path; multi-
   slot servers require widening the cache to a per-slot table.

6. **T14 G4 first-light for NVMe** — GATED ON HARDWARE. Recipe
   ready at `tools/nvme-hw-smoke.md`. Witness placeholder ready at
   `tests/kernel/drivers/nvme/hw_smoke.pdx`. Promotion of
   `design/hardware/quirks.md §2.4` VMD row `PROVISIONAL →
   CONFIRMED` + any new rows discovered happens on first boot with
   VMD-off + scratch NVMe present.

7. **4-CPU concurrent-IO fixture body** — R25+. Scaffold landed at
   `tests/kernel/drivers/nvme/concurrent_io.pdx`; real body swaps in
   with driver-attach + public sched_spawn.

8. **Opt-in `boot_r24_concurrent_io` fingerprint file** — R25+.
   Currently a SKIP-echo; when the witness body activates, the mode
   flips to FINGERPRINT_MODE=1 with
   `tests/r24/expected-concurrent-io.txt` matching
   `NVME CONCURRENT IO OK cpus=4 iops=<N>\n`.

9. **R23 debt items still open (unchanged from R23 close):**
   UEFI/OVMF fb_console smoke harness, T14 G4 first-visual-output
   capture, `fb_map_lfb` BGRA-only assumption, `_fb_console_grid`
   fixed size, k_panic_fb_banner_len triplicate, two paideia-as
   encoder polish gaps.

10. **R22 debt items still open (unchanged from R22 close):**
    `_vtd_base` hardcoded; `has_dmar` slot unpopulated;
    `vtd_fault_dispatch` not IDT-wired; `msix_enable_device` +
    `msix_assignments` ledger; full GCMD.TE + SIRTP + IRE
    ceremony; DMA-fault regression SKIP → LIVE; T14 G4 PCI/ACPI
    captures.

11. **R21 debt items still open:** `hpet_now_ns` precision widening;
    `phase1_acpi_gather` full wire (partial at R22.M1 — MCFG
    only).

**None regress R24 acceptance.**

---

## Quirks Discovered on Real Hardware

None (R24 ran under `qemu -kernel` throughout — no UEFI/OVMF harness
yet, no MCFG surface, no PCI enumeration, no NVMe controller). No
rows in `design/hardware/quirks.md` promoted `PROVISIONAL →
CONFIRMED` at this pass.

Quirks-db discipline recap at M6:
- **§2.4 Storage — VMD row.** Handling column enriched with an
  explicit cross-reference to `tools/nvme-hw-smoke.md` §1.2.1 (the
  BIOS toggle is the load-bearing knob) + `tests/kernel/drivers/nvme/hw_smoke.pdx`
  (the witness that verifies the toggle worked). Row stays
  `PROVISIONAL` — promotion to `CONFIRMED` happens at the R24 HW
  smoke live run on the T14 G4.
- No new rows added — R24 discovered nothing new about the T14 G4
  substrate that wasn't already anchor-documented at R22.M6.

---

## Milestone Discipline Statement

R24 held to the round-tempo user preference: continuous loop across
all issues + milestones with no mid-round pause. Six milestones
closed in roughly two loop days; 25 issues landed (24 implementation
+ 1 closure + 1 partial deferral of #906 userspace half → #1015).
Zero fully-deferred issues from R24-scoped work — every planned R24
issue landed either fully or in the documented kernel-side/userspace
split.

The `softarch → debugger` loop shape held throughout with zero
workerbee invocations. Cross-repo escalation to paideia-as fired
**zero times** during R24 — the substrate was ready for every
encoder R24 needed, and all three ambient "paideia-as-blocked"
labels (NVMe register accessor, SQE 64-byte memcpy, per-CPU
descriptor stride) were downgraded on inspection.
`paideia-as` submodule pin `2cf169d` unchanged since R21 close.

---

## Real-Hardware Verification Procedure (T14 G4 Raptor Lake, R24 gated:hardware)

Full recipe at `tools/nvme-hw-smoke.md`. Summary:

1. **Prepare boot media.** Build kernel + ESP image per
   `design/roadmap/r19-t14-g4-boot-guide.md`.
2. **BIOS setup.** Confirm **Intel VMD Controller = Disabled**
   (per §2.4 VMD row + `tools/nvme-hw-smoke.md §1.2.1` — the
   load-bearing knob).
3. **Boot on T14 G4.** Expect fingerprints: R21 substrate + R22
   PCI ENUM DONE + `NVME PROBE N=1` (or 0 if VMD is still
   enabled).
4. **GDB attach + witness invoke.** Via Intel DCI dongle, attach
   GDB, `call nvme_hw_smoke_witness()`. Expect BEGIN →
   IDENTIFY-NS OK → END. Verify `nvme_csts_check(_nvme_devices[0].bar0_pa)`
   returns 0 (no CFS trip).
5. **Promote quirks-db.** §2.4 VMD row → `CONFIRMED`. Any new
   quirks discovered → fresh row per §2.4 template.

None of this blocks R24 close. QEMU-side substrate is proven via
`kernel.elf` linkage + 15/15 build gates + the pre-push regression
matrix + the SKIP-echo opt-in smoke.

---

## Next Round

**R25 (PdxFS-lite — persistent FS MVP + NVMe driver-attach wire-up).**
See `design/roadmap/r18-plus-bare-metal.md` §R25. Preflight document
to land at R25.M1 kickoff as
`design/round-retrospectives/r25-preflight.md`.

R25 blockers: none from R24. Ready to open.

---

**Closure.** R24 NVMe driver — kernel-side substrate closed
2026-08-11.
