// R20b Retrospective: Userspace-Server Substrate (unblocks #1015)

**Date:** 2026-08-21
**Milestone:** R20b.M1–R20b.M4 (all closed via backfill; M5 + M6 landed post-close as sub-rounds).
**Issues:** 11 landed across M1..M4 (#1552–#1562). All shipped in prior commits; this document is the formal closure that binds each sub-issue to its landing commit and lands the fingerprint-observability contract.
**HEAD at closure:** bumped by the R20b-closure commit that lands this doc + STATUS entry.
**paideia-as pinned at:** unchanged during R20b — every mnemonic (rdmsr/wrmsr/rep_movsb/mov_b/mov_w/imul/div, plus the KPTI walker call graph) was pre-existing in the substrate.

---

## Round Intent

R20b was scoped as the userspace-server substrate cluster per `design/ipc/userspace-server-substrate.md`, opened as blocker **#1015** by the R20.M4 deferral of **#820 acpi_supervisor** — the R20 ACPI static-table pipeline could not publish its parse-query surface to userspace because no named-endpoint / cap-transfer plumbing existed. R20b delivers exactly that plumbing (named endpoints, service broker, variable-length IPC framing with a KPTI-safe payload copy, three new syscalls for the server-process model, and the loader hook that seeds an image's initial cap set) so that #820 and #860 (`pci_enumerator`) can land on top.

Four milestones threaded the substrate:

- **M1 — Named endpoint substrate.** KIND_IPC_ENDPOINT tail formalization (#1552), the 128-slot endpoint table + 128×4 KiB payload arena (#1553), and the 32-row `svc.<name> → endpoint_id` broker (#1554).
- **M2 — Framed variable-length IPC.** 8-byte packed header + encode/decode primitives (#1555), single-in-flight pending-msg semantics (#1556), and the KPTI-safe user↔kernel payload bounce (#1557).
- **M3 — Server-process model syscalls.** `sys_ipc_recv` with blocking-recv scheduler state (#1558), `sys_ipc_send` / `sys_ipc_reply` with waiter wake (#1559), and `sys_svc_lookup` with client cap-slot mint (#1560).
- **M4 — Loader capability seed.** InitCap sidecar record format + validator (#1561) and the `loader_seed_caps` hook wired into `elf_lite_load` (#1562).

Every acceptance criterion sits behind a boot-fingerprint contract asserted by `tests/r17/shell-shutdown.golden` — the pre-push smoke matrix's regression gate. All 11 fingerprints emit in order between R20 close and the R17 shell handoff.

---

## What Shipped

### R20b.M1 — Named endpoint substrate (3 issues: #1552–#1554)

- **#1552 KIND_IPC_ENDPOINT tail encoding** — `src/kernel/core/cap/kind_endpoint.pdx`. Formalizes `target_ptr` as `(endpoint_id[15:0], direction[17:16], reserved[63:18])` per design §3.1. Direction constants (SEND=0, RECV=1, BIDI=2, reserved=3) are a static refinement — OP_SEND on RECV-only cap returns INVOKE_UNSUPPORTED; ditto OP_RECV on SEND-only. Ships `endpoint_tail_encode` / `endpoint_tail_decode`, `endpoint_rights_valid` (naming avoids the device_cap.pdx `rights_valid` global-symbol collision, mirroring `blk_rights_valid` precedent), and `endpoint_cap_mint`. Boot witness `endpoint_cap_witness` (in `src/kernel/boot/witness/r29_hw_caps.pdx`) runs 7 sub-tests including a descriptor round-trip via `cap_mint_write` into slot 11. Fingerprint: **R20b ENDPOINT CAP OK**. Closure commit: `3dd41bb`.

- **#1553 Endpoint table + payload arena** — `src/kernel/core/ipc/endpoint_table.pdx` (128 × 48 B, low-first scan, row-header `((in_use<<16) | id)` collapses the free/live test to a single u64 compare) + `src/kernel/core/ipc/payload_arena.pdx` (128 × 4 KiB @align(4096); `payload_buf_pa_for(id)` is O(1) index arithmetic). Witness `endpoint_alloc_witness` (in `r20b_substrate.pdx`) runs 11 sub-tests A..K covering alloc round-trip (128 → sentinel → free-all → 128 again), lookup gate, alignment, and adjacent/long-range contiguity. Fingerprint: **R20b ENDPOINT ALLOC OK**. Closure commit: `d2cfbc8`.

- **#1554 svc broker table + primitives** — `src/kernel/core/ipc/svc_broker.pdx` (32 × 48 B `_svc_broker_table`; free-row discipline: `name[0]==0` iff free). `svc_register(name_ptr, name_len, endpoint_id)` returns 0/NAME_LEN(1)/DUPLICATE(2)/TABLE_FULL(3). `svc_lookup(name_ptr, name_len)` returns endpoint_id or `SVC_LOOKUP_NONE` (0xFFFF…FFFF). Match discipline requires full name_len byte equality AND row[name_len]==0 so `svc.foo` cannot alias `svc.foobar` (same NUL-tail pattern as `pdxfs_lite/readdir.pdx:336`). Witness `broker_witness` runs 8 sub-tests A..H. Fingerprint: **R20b BROKER OK**. Closure commit: `f7fd067`.

### R20b.M2 — Framed variable-length IPC (3 issues: #1555–#1557)

- **#1555 8-byte header + frame primitives** — `src/kernel/core/ipc/frame.pdx`. Layout matches `design/ipc/acpi-supervisor-schema.md` §3 byte-exactly: `op:u8, ver:u8, flags:u16 LE, payload_len:u32 LE` (≤4088). Because x86-64 stores u64 in native LE, the packed header IS byte-identical to a single u64 store — `frame_encode` composes the packed u64 with per-field masking (defends against caller-side field smearing) and writes once; `frame_decode` is one `mov`. The u64-natural shape lets the M2 send path cache the whole 8-byte header in the endpoint row's `pending_hdr` field at offset +24. `FRAME_MAX_PAYLOAD=4088`, `FRAME_HEADER_SIZE=8`, `FRAME_OP_REPLY_BIT=0x80`. Buf is not touched on rejection (H sub-test). Witness `frame_witness` runs 10 staged sub-tests. Fingerprint: **R20b FRAME HDR OK**. Closure commit: `f53ff8b`.

- **#1556 Pending-msg primitives** — `endpoint_write_pending` / `endpoint_take_pending` / `endpoint_is_full` in `endpoint_table.pdx`. The row's `pending_hdr` at +24 doubles as the empty/full discriminator: zero == empty, non-zero == valid header (safe because every valid header has `ver >= 1` in bits 8..15). Publish order: `write_pending` copies payload BEFORE stamping hdr; `take_pending` clears hdr AFTER copying payload out — preserves the invariant `pending_hdr != 0 → payload fully published` that R21+ SMP consumers assume. Sentinels: `PENDING_WRITE_ERR_EAGAIN=1`, `_BAD_ID=2`, `_PAYLOAD_LEN=3`; `PENDING_TAKE_EMPTY = 0xFFFF…FFFF`. Witness `pending_msg_witness` runs 14 sub-tests. Fingerprint: **R20b PENDING MSG OK**. Closure commit: `004c663`.

- **#1557 KPTI-safe payload bounce** — `src/kernel/core/ipc/user_bounce.pdx`. Thin wrappers `user_bounce_send` and `user_bounce_recv` fuse the KPTI-aware per-byte walkers (`user_read_bytes_via_walk` / `user_write_bytes_via_walk` from `syscall/user_read.pdx`, the #737/#738/#739 precedent) with the M2-002 pending-msg primitives. POSIX short-read semantics on recv: `write_len = min(payload_len, user_payload_max)` and return true payload_len so callers can detect truncation. Witness `ipc_bounce_witness` (in `r20b_ipc.pdx`) borrows the deepest of init's 4 mapped stack pages (0x7FFFFFFFB000..0x7FFFFFFFC000) as the "user" buffer so the walker exercises init's real `user_pml4` — not a synthetic kernel-only alias — and drives 12 staged sub-tests including a byte-exact hdr + first-byte + last-byte verify on a 4088-byte payload. Fingerprint: **R20b IPC BOUNCE OK**. Closes M2. Closure commit: `a80a25e`.

### R20b.M3 — Server-process model syscalls (3 issues: #1558–#1560)

- **#1558 sys_ipc_recv (sysno 40)** — `src/kernel/core/syscall/handlers/sys_ipc_recv.pdx`. Drain-or-block-and-retry loop: empty path installs `endpoint.waiter_tcb` at row +32 + `_current_tcb.wait_endpoint_id` at TCB +120 (see NEW `src/kernel/core/sched/state.pdx` for the canonical TASK_STATE_* enum) before `sched_block`; on wake both slots are cleared defensively before retry. `sched_block`'s #663 RUNNABLE-required guard means the actual in-block state is WAITING (2), not WAITING_IPC (4) — the latter is a scaffolding constant for the design's differentiated-wait-state model. Wake-time discrimination between IPC waiters and `wait4` waiters uses `endpoint.waiter_tcb` + `wait_endpoint_id`, not the state field. Dispatch shim in `dispatch.pdx` gates `user_hdr_va` (8 B) + `user_payload_va` (user_payload_max) via `user_ptr_ok` (#741 defense-in-depth). Witness `sys_ipc_recv_witness` runs 10 sub-tests on the non-empty path (empty-path testability is documented as gated on M3-002's producer). Fingerprint: **R20b SYS IPC RECV OK**. Closure commit: `2110d2d`.

- **#1559 sys_ipc_send (sysno 42) + sys_ipc_reply (sysno 41)** — `handlers/sys_ipc_send.pdx` + `handlers/sys_ipc_reply.pdx`. `send`: delegate publish to `user_bounce_send`, read `endpoint.waiter_tcb`; if non-null clear the slot and call `sched_wake` (state WAITING → RUNNABLE + runq_enqueue via the canonical wake primitive so the receiver's post-`sched_block` retry loop finds the runqueue coherent). Pass-through of `user_bounce_send` return codes (0=OK, 1=EAGAIN, 2=BAD_ID, 3=E2BIG, -EFAULT). `reply`: pre-check `hdr.op & 0x80` via a 1-byte `user_read_bytes_via_walk` into a dedicated scratch; reject with -EINVAL if unset, else tail-call `sys_ipc_send_body`. Bit-7 assertion sits above the send body so the send API stays symmetric across request and reply. Witness `sys_ipc_send_witness` runs 18 sub-tests including all four acceptance-criteria scenarios (no-waiter publish, EAGAIN on full endpoint, waiter wake with direct positive evidence via `CB.tail == &fake_tcb`, reply with/without bit 7); the fake TCB is `runq_dequeue`'d before `enter_userland_initial` so it cannot be scheduled. Fingerprint: **R20b SYS IPC SEND OK**. Closure commit: `962d6fe`.

- **#1560 sys_svc_lookup (sysno 43)** — `handlers/sys_svc_lookup.pdx`. Walker-bounces a user-VA name into a kernel scratch, looks up the broker row via the new `svc_lookup_row` helper (returns row PA so `endpoint_id` + `rights_gate` are readable atomically), derives the endpoint cap's direction from the row's `rights_gate` (READ+WRITE→BIDI, READ-only→RECV, else→SEND), scans the caller's cap_table for a free slot (`kind == KIND_NULL`), and mints via `cap_mint_write`. Errno taxonomy: `-EINVAL` / `-EFAULT` / `-ENOENT` / `-ENOSPC` so a caller can discriminate the four failure modes with a single sign test + range check (`rax < 256 → slot; else errno`). Witness `sys_svc_lookup_witness` runs 10 sub-tests covering happy path + `-ENOENT` and verifies minted cap kind/rights/tail. Closes M3. Fingerprint: **R20b SVC LOOKUP OK**. Closure commit: `274b6a8`.

### R20b.M4 — Loader capability seed (2 issues: #1561–#1562)

- **#1561 InitCap sidecar format + validator** — `src/kernel/core/loader/init_caps.pdx` + `design/loader/init-caps-sidecar.md`. 16-byte record: `slot:u16, kind:u16, rights:u32, target_ptr:u64` (natural 8-byte alignment). Sidecar blob layout: `count:u16` at +0, 14-byte reserved padding, `InitCap[count]` from +16. `init_caps_validate(image_base, image_len)` rejects: malformed count (`< 16-byte header` or `16 + count*16 > image_len`) → BAD_COUNT; slot ≥ 256 → BAD_SLOT; kind not in `{0..15, 0x15 KIND_DRIVER, 0x16 KIND_DMESG}` → BAD_KIND. Witness `init_caps_witness` (in `r20b_loader.pdx`) synthesizes a 2-entry sidecar in `.bss` and drives 4 sub-tests (accept + BAD_COUNT + BAD_SLOT + BAD_KIND). Fingerprint: **R20b INIT CAPS FMT OK**. Closure commit: `e166294`.

- **#1562 loader_seed_caps hook** — `src/kernel/core/loader/seed_caps.pdx`. `loader_seed_caps(task_ptr, sidecar_base, sidecar_len) → rc`: validates via `init_caps_validate` (fail-fast — on any non-zero rc returns `LOADER_SEED_FAILED = 0xFFFFFFF9` without minting anything), then iterates `count` entries at `sidecar_base + 16 + i*16` and calls `cap_mint_write(slot, kind, rights, target_ptr)` per entry. 5-push callee-save prologue aligns `rsp % 16` across the nested validator + mint call graph. `task_ptr` is threaded through for R21+ per-task cap_tables (unused at R20b — single global cap_table per `cap/table.pdx`). Also ships `_loader_seed_empty_sidecar` — a 16-byte zero blob for the elf_lite phase-1 wire-in (M6-001 later replaces this with the real symbol-walker sidecar). `elf_lite.pdx` grows the `ELF_CAP_SEED_FAILED = 0xFFFFFFF9` sentinel (directly below `ELF_MAP_ERR` in the descending taxonomy) plus a call site inside `elf_load_done` that invokes the hook and jumps to `elf_load_seed_error` on non-zero rc — propagating `ELF_CAP_SEED_FAILED` to `sys_execve`. Witness `loader_seed_witness` runs 2 sub-tests (ACCEPT: mint KIND_TIMER cap into slot 5 with read-back verify; REJECT: patch count to 0xFFFF and verify slot 5 unchanged proving fail-fast). Closes M4. Fingerprint: **R20b LOADER SEED OK**. Closure commit: `64a3487`.

---

## Cross-Repo Escalations to paideia-as (R20b)

**None.** Every mnemonic exercised by the R20b substrate was pre-existing at the paideia-as pin R20b opened on. No encoder gap was hit that required a paideia-as bump.

---

## Observable Proof

- Kernel builds clean under `tools/build.sh` at R20b close — all 11 fingerprints are read out of `nm build/kernel.elf` and asserted by the pre-push matrix.
- `tests/r17/shell-shutdown.golden` asserts the 11 R20b markers as an ordered subsequence between the R20 close markers and `INIT ENTERED RING3` — a witness that silently stops running trips the golden mismatch immediately.
- Full pre-push smoke matrix (14 modes) passes at R20b close: `boot_r8_only`, `boot_r10..r12` + `_denial`, `boot_r14b_{hivma,kpti,ipi,loader}`, `boot_r17_shell_{echo_hello,multi_command,shutdown,child_process}`, `boot_smp`.
- `tools/verify-syscall-dispatch.sh` gates the three new sysnos (40 = `SYS_IPC_RECV`, 41 = `SYS_IPC_REPLY`, 42 = `SYS_IPC_SEND`, 43 = `SYS_SVC_LOOKUP`) — TOTAL_CHECKS bumped 15 → 19 across M3.
- Round-close witness for R20b.M5 (echo-server end-to-end round-trip, unblocks #820/#860 via #1015) landed in `d69ab95` and lives in `src/kernel/boot/witness/r20b_echo_rpc.pdx` — the composition test that binds M1..M4 into a client-server RPC across a real ring-3 boundary. Post-M5 sub-issues M6-001..M6-003 (loader phase-2 ELF-symbol walker, dispatch cap_slot lookup, same-endpoint request/reply race) landed as `7138ab0` / `42a58f4` / `9fb86a3`.

---

## R20b Debt Carried Forward

None. #1015 discharged in `d69ab95` (R20b.M5-001 closure witness). #820 and #860 (acpi_supervisor + pci_enumerator userspace servers, formerly blocked on #1015) landed in `ca9a289` and `2461f1d` respectively. The single global cap_table per `cap/table.pdx` is a known R21+ item (see the `task_ptr` argument threaded through `loader_seed_caps` for the eventual per-task cap_table split) — tracked independently of R20b, not a debt of this round.

---

## Milestone Discipline Statement

R20b was implemented across the M1..M4 sub-issues (#1552–#1562) in one continuous loop under the `softarch → debugger` shape, each sub-issue landing with its own boot fingerprint and its own golden-line assertion. The 11 issues stayed open on the GitHub tracker because the historical per-issue commits used cross-reference syntax (`(partial #1015)`, `(#1559)`) rather than the exact closing keyword (`Closes #N.` — one keyword per issue per `feedback_github_closing_keywords`) — this closure commit repairs that by carrying the correct closing-keyword sequence for all 11.

---

## Next Round

R20b was a substrate round, not a milestone in the linear roadmap. Its closure unblocks the queued userspace-server work already landed in the tree (#820 + #860) and enables every post-R20 userspace daemon to publish itself via `svc_register` + await requests via `sys_ipc_recv`. The kernel roadmap continues at R21 (already closed) and beyond.

---

**Closure.** R20b userspace-server substrate — closed 2026-08-21 (backfill).
