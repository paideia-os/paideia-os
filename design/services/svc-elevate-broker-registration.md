# svc.elevate-broker registration — completion plan

Tracking: paideia-os #1760 (`R48-PREP-005-status: svc.elevate-broker
registration incomplete (pkg M3 blocker for real elevate flow)`).
Parent design: `design/tooling/r49-r50-plan.md` §5.0
(paideia-os.R48-PREP-005).

## 1. Problem statement

`pkg M3` (in the external repo `paideia-os/pkg`) landed a
shape-complete `PkgElevate` wrapper whose `elevate_client_request`
call today returns `ELVC_ERR_LOOKUP_FAIL`. The wrapper is a no-op
because there is nothing behind the well-known name
`svc.elevate-broker`:

- `svc_lookup("svc.elevate-broker", 18)` either misses entirely, or
  hits a stale witness-only row (see §2.3) whose endpoint id points
  at no live receiver.
- Consequently every `sys_ipc_send` a client would issue on the
  minted cap either fails at cap-mint time or lands on an empty
  endpoint that never drains.

The same block hits `rm M3` and `mkdir M3` — every tool that requests
a cross-boundary elevation goes through the same path.

The paideia-os fix has three parts, in this order: reserve the
broker's well-known endpoint id, actually publish the name against
that reservation, and spawn a daemon that recognises the wire ops.
This plan lands only the registration path; the real approve / deny
policy is out of scope (§6).

## 2. Current shape (what exists at HEAD, 2026-08-22)

### 2.1 Kernel-side seam (already landed)

`src/kernel/core/ipc/elevate_broker.pdx` (R48b substrate-prep, #1627)
declares:

- `elevate_broker_name : [u8; 20] = "svc.elevate-broker\0\0"` with
  `ELEVATE_BROKER_NAME_LEN = 18`.
- `elevate_broker_register(endpoint_id) -> ELVB_OK | ELVB_REGISTER_*`
  wrapping `svc_register` against the canonical name, translating
  the four `SVC_REGISTER_*` return codes into the `ELVB_*` band, and
  bumping `_elevate_broker_stats` accordingly.
- `elevate_broker_dispatch(op, arg) -> ELVB_DISPATCH_STUB |
  ELVB_DISPATCH_BAD_OP` — recognises the three
  `ELV_OP_REQ / APR / EXP` values from
  `src/kernel/core/cap/kind_elevate_channel.pdx` and returns
  `ELVB_DISPATCH_STUB` on every recognised op.

### 2.2 Sibling analogues

Two shapes to inherit from:

1. `src/kernel/core/ipc/audit_journal_broker.pdx` (#1628) — the
   siblingly-shaped `svc.audit-journal` seam. Same
   register + dispatch-stub + stats pattern; the reservation and
   spawn story owed for `svc.audit-journal` is byte-for-byte the
   same as this one.
2. `src/user/acpi_supervisor.pdx` (R20-M4-002) and
   `src/user/audio_supervisor.pdx` (R33.M5-001) — target-shape
   userspace supervisor daemons whose `_start` runs an infinite
   `sys_ipc_recv → dispatch → sys_ipc_reply` loop over a cap slot
   seeded by `_init_caps`. These are the shape the elevate broker
   daemon binary at §4.M2 inherits.

### 2.3 The registry, and the witness residue problem

`src/kernel/core/ipc/svc_broker.pdx` (R20b.M1-003, #1554) is
**add-only**: `svc_register` refuses duplicates and there is no
`svc_unregister`. A row is "free" iff `row[0] == 0`, and once
installed the row lives for the kernel's lifetime.

The current boot witness at
`tests/kernel/ipc/elevate_broker_synth.pdx` calls
`elevate_broker_register(0x33)` — a synthetic endpoint id, chosen
purely to exercise the seam. Sub-test 3 asserts
`svc_lookup("svc.elevate-broker") == 0x33`. Because the witness
resets `_elevate_broker_stats` on exit but leaves `_svc_broker_table`
untouched, the row publishing the name against endpoint `0x33` **is
permanent** for the rest of the boot. Any later attempt to register
the same name — by a daemon or by kernel init — refuses with
`ELVB_REGISTER_DUP`, and any client resolving the name via
`sys_svc_lookup` receives a cap whose endpoint id (`0x33`) was never
allocated through `endpoint_alloc`, so send / recv fail structurally.

Two clean options exist. This plan picks (a) because it needs no new
primitive:

(a) **Register once, from the kernel, before the witness runs.** The
    kernel reserves a fixed well-known id via `endpoint_alloc_at`
    (§4.M1), calls `elevate_broker_register` against it, and the
    witness then asserts the OK path against the already-populated
    row instead of registering itself. Refusal-of-duplicate is
    asserted by *re-invoking* `elevate_broker_register` from the
    witness against the same name and expecting `ELVB_REGISTER_DUP`.
(b) **Add `svc_unregister` to the broker primitive.** Deferred —
    would widen the R20b add-only contract without pressing need
    once (a) is in place. `svc_unregister` is on the roadmap
    anyway for server-restart at a later round (see
    `src/kernel/core/ipc/svc_broker.pdx` line 50).

### 2.4 The client library

`elevate_client_request` and `ELVC_ERR_LOOKUP_FAIL` do **not** live
in this repo. They live in the external repo `paideia-os/libpdx-elevate`
(§3.5 of `design/tooling/r49-r50-plan.md`), and the three tool
wrappers `PkgElevate` / `RmElevate` / `MkdirElevate` live in
`paideia-os/pkg`, `paideia-os/rm`, and `paideia-os/mkdir`. The
client-side shim performs:

```
sys_svc_lookup("svc.elevate-broker", 18)   → KIND_IPC_ENDPOINT cap slot
sys_ipc_send(slot, hdr{op=ELV_OP_REQ,…}, payload, len)
sys_ipc_recv(slot, hdr_sink, payload_sink, cap)
```

The lookup call already lands: `sys_svc_lookup_body` is
`src/kernel/core/syscall/handlers/sys_svc_lookup.pdx` (R20b.M3-003,
sysno 43). What is missing on the kernel side is a *row it can
resolve to a live endpoint*. Once that row exists and a daemon is
draining the endpoint, `elevate_client_request` returns `ELVC_OK`
(or an `ELVC_STUB_ACK` code introduced at §4.M3) rather than
`ELVC_ERR_LOOKUP_FAIL`.

## 3. What "svc.elevate-broker registration" means concretely

Registration is the pairing of:

1. **A reserved endpoint id.** A stable u16 that both the kernel's
   registry row and the userspace daemon's `_init_caps` sidecar can
   name at build time. Following the existing well-known allocation
   band (echo_server = 1, acpi_supervisor = 3, audio_supervisor = 5),
   this plan reserves:

       ELEVATE_BROKER_ENDPOINT_ID       : u64 = 16
       AUDIT_JOURNAL_BROKER_ENDPOINT_ID : u64 = 17   (reserved
                                                       adjacent for
                                                       #1628's twin
                                                       fix)

   16 sits above every currently-declared supervisor id and well
   within `ENDPOINT_TABLE_SLOTS = 128`. The value lives in
   `src/kernel/core/ipc/elevate_broker.pdx` alongside the name
   string so exactly one file owns the pair.

2. **A live broker-table row.** `_svc_broker_table` gets a row with
   `name = "svc.elevate-broker\0"` and
   `endpoint_id = ELEVATE_BROKER_ENDPOINT_ID`. `svc_lookup` and
   `sys_svc_lookup` both resolve the name to that id.

3. **A live endpoint slot.** `_ipc_endpoint_table` slot 16 is
   claimed via `endpoint_alloc_at(16)` so that `sys_ipc_send` /
   `sys_ipc_recv` against it succeed rather than tripping the
   "row not alive" gate.

4. **A drainer.** A userspace daemon whose `_init_caps` sidecar seeds
   a cap slot with `KIND_IPC_ENDPOINT` targeting endpoint id 16
   (with `R_IPC_ALL` rights), and whose `_start` runs the standard
   `sys_ipc_recv → dispatch → sys_ipc_reply` loop.

All four parts must be in place for `elevate_client_request` to
stop returning `ELVC_ERR_LOOKUP_FAIL`. Parts 1–3 are landed by M1;
part 4 is M2; the witness that proves the roundtrip works is M3.

## 4. Milestone / issue split (R48-PREP-005.M1 … M3)

The following three sub-milestones nest under the parent
`paideia-os.R48-PREP-005` line at `design/tooling/r49-r50-plan.md`
line 354. All three are paideia-os (this repo) issues; the tool
wrappers stay in their respective external repos.

### M1 — Kernel-side reservation + real registration at boot

**Goal.** The registry row publishing `svc.elevate-broker` points
at a real, `endpoint_alloc_at`-reserved endpoint id, established
before any userland runs.

**Scope.**

- Extend `src/kernel/core/ipc/elevate_broker.pdx` with:
  - `ELEVATE_BROKER_ENDPOINT_ID : u64 = 16`.
  - `elevate_broker_bringup() -> u64` that composes
    `endpoint_alloc_at(ELEVATE_BROKER_ENDPOINT_ID)` and
    `elevate_broker_register(ELEVATE_BROKER_ENDPOINT_ID)` with
    the ELVB return-code translation; on any failure it does not
    partially install the row (bail before register if
    `endpoint_alloc_at` refuses).
- Call `elevate_broker_bringup` from `kernel_main.pdx` **before**
  `boot_continue_after_ring3` fires the R30 platform witness that
  runs `elevate_broker_witness_call`.
- Rework `tests/kernel/ipc/elevate_broker_synth.pdx`: sub-test 2 no
  longer registers, it asserts the row is already published via
  `svc_lookup` → `ELEVATE_BROKER_ENDPOINT_ID`; sub-test 4 asserts
  a *re-*register call refuses with `ELVB_REGISTER_DUP` (unchanged
  wire semantic, unchanged fingerprint `R48b ELEVATE_BROKER OK`).

**Missing primitives.** None. `endpoint_alloc_at` already lives at
`src/kernel/core/ipc/endpoint_table.pdx:277` (R31.M2-1590, #1590)
and is proven by four prior boot-time witnesses (§2.2).

**Non-goals.** No userspace daemon yet — `_ipc_endpoint_table`
slot 16 sits reserved but undrained; any client that sent on it
during the M1-only interval would enqueue with no reader. That is
harmless because no client will ship before M2 lands.

**Issue title.** `R48-PREP-005.M1 kernel-side svc.elevate-broker
registration at ELEVATE_BROKER_ENDPOINT_ID = 16 (endpoint_alloc_at +
elevate_broker_register from kernel_main)`

### M2 — Userspace elevate broker daemon binary + init spawn

**Goal.** A userspace process is actually draining
`_ipc_endpoint_table` slot 16 and returning stub replies for the
three recognised `ELV_OP_*` values.

**Scope.**

- New `src/user/elevate_broker_daemon.pdx` + `elevate_broker_daemon.ld`
  mirroring `src/user/acpi_supervisor.pdx` (R20-M4-002) and
  `src/user/audio_supervisor.pdx` (R33.M5-001) in shape:
  - `_init_caps` sidecar declares a single record: cap slot 8 →
    `KIND_IPC_ENDPOINT` with `endpoint_id = 16` and rights
    `R_IPC_ALL`. Reuses the `KIND_SEEDABLE_TABLE` accept path
    (`src/kernel/core/loader/init_caps.pdx`).
  - `_start` runs the standard infinite loop: `sys_ipc_recv` on
    cap slot 8 into `hdr_scratch` + `payload_scratch`; extract
    `op = hdr & 0xFF`; dispatch on `op` against 1 / 2 / 3 (the
    `ELV_OP_REQ / APR / EXP` values from
    `kind_elevate_channel.pdx`); each recognised op writes an
    8-byte payload whose first u64 is `ELVB_DISPATCH_STUB`
    (`0xFFFFEBFB`) and sets `payload_len = 8`; unknown op writes
    `ELVB_DISPATCH_BAD_OP` (`0xFFFFEBFA`); rebuild reply hdr
    (set `FRAME_OP_REPLY_BIT`, stash `payload_len` in bits
    32..63); `sys_ipc_reply`; jump back to `server_loop`. Never
    returns.
  - Same 24-byte stack scratch discipline and same
    `justification:` comment shape the two sibling supervisors
    already use.
- Extend `tools/userbin_embed.S` and the build so the daemon's
  `.elf` is embedded via `_elevate_broker_daemon_bin_start` /
  `_end` (mirrors `_echo_server_bin_start` and
  `_acpi_supervisor_bin_start`).
- Extend `src/user/init.pdx` with a third `fork+exec` cycle after
  the `/bin/sh` fork, targeting `/bin/elevate_broker_daemon`. The
  daemon is a long-lived server, so init does *not* `wait4` on it —
  it forks, execs, and returns; the parent's existing shutdown
  path is untouched. `init.pdx` gets a new witness marker
  (`INIT FORK ELEVATE OK`) to prove control reached the spawn.
- Embed the daemon binary as `/bin/elevate_broker_daemon` in the
  tmpfs seeding path used by `/bin/sh` and `/bin/child_hello`.

**Missing primitives.** None new. Duplicates the shape of every
prior supervisor spawn. The kernel already knows how to seed
`_init_caps`-declared cap slots at task load time (R20b.M4-001,
#1561).

**Interlock with M1.** M2 depends on M1 landing first — the daemon
recv-loops on the endpoint id M1 reserved, and M1's registration
already routes the name to that id.

**Non-goals.** The daemon body remains stub-shaped: it drains, it
counts (via a userspace-local counter in `.bss`; `_elevate_broker_stats`
stays kernel-only), it replies with `ELVB_DISPATCH_STUB`. No policy
evaluation, no request-queue management, no timer-driven expiry.
Those are `libpdx-elevate.M2` (in the external repo) plus a follow-on
paideia-os round for the policy-table wiring called out at
`design/tooling/r49-r50-plan.md` line 354.

**Issue title.** `R48-PREP-005.M2 userspace elevate broker daemon
(src/user/elevate_broker_daemon.pdx + tmpfs seed + init fork/exec)`

### M3 — Client-roundtrip witness (`elevate_client_request` unblocked)

**Goal.** A boot-time witness proves that a client resolving
`svc.elevate-broker` via `sys_svc_lookup` and issuing an
`ELV_OP_REQ` on the resulting cap receives an
`ELVB_DISPATCH_STUB` reply from the M2 daemon, at wire granularity.
This is the fingerprint that the future
`libpdx-elevate.M2 elevate_client_request` will succeed against.

**Scope.**

- New `tests/kernel/ipc/elevate_broker_roundtrip_synth.pdx`
  mirroring the `m5_echo_witness` shape at
  `src/kernel/boot/witness/r20b_echo_rpc.pdx` (lines 50..300):
  - Kernel-driven against init's `user_pml4`, borrowing a scratch
    page in the same `[0x7FFFFFFFB000, 0x7FFFFFFFF000)` window
    (see `m5_echo_witness` §"User-page layout" for the offset
    convention).
  - Sub-tests: (0) resolve — `sys_svc_lookup_body(user_name_va,
    18)` returns a slot in `[0..255]`; (1) publish request hdr
    with `op = ELV_OP_REQ = 1`, `payload_len = 0`; (2) publish
    zero-byte payload; (3) `sys_ipc_send_body` on the slot; (4)
    yield / spin-poll until the endpoint is drained (the M2
    daemon runs on the same scheduler); (5) `sys_ipc_recv_body`
    drains the daemon's reply; (6) verify reply hdr has
    `FRAME_OP_REPLY_BIT` set and `payload_len == 8`; (7) verify
    the first u64 of the reply payload is `ELVB_DISPATCH_STUB
    = 0xFFFFEBFB`. Emit fingerprint `R48-PREP-005 ELEVATE ROUNDTRIP OK`
    on success.
- Register the witness in `src/kernel/boot/witness/r30_platform.pdx`
  after `elevate_broker_witness_call` (which validates the
  standalone seam) and after init has reached ring-3 far enough
  for the daemon to have run at least one `sys_ipc_recv` iteration.
  If the current R30 platform-witness placement fires *before*
  init's third fork+exec, either move the witness later or drive
  the roundtrip from a post-init witness page (this is an
  ordering-only decision made in M3 based on where the R30 witness
  fires relative to init's spawn sequence at M3 land time).

**Missing primitives.**

- **Cooperative scheduling around the send-then-recv gap.** The
  `m5_echo_witness` sidesteps this by driving both sides of the
  IPC synchronously from the kernel; a real client → daemon
  roundtrip needs the daemon to actually run between the send and
  the recv. Options: (a) yield explicitly via a
  `sys_sched_yield`-equivalent; (b) spin-poll on
  `endpoint_is_full` with a bounded retry count. This plan picks
  (b) — mirrors the discipline used by every R31 respawn witness,
  keeps the witness deterministic, and does not require a new
  syscall. If bounded polling proves flaky under real scheduling,
  M3 revises to (a) and files a `sys_sched_yield` prerequisite.
- Everything else is present: `sys_svc_lookup_body`,
  `sys_ipc_send_body`, `sys_ipc_recv_body`, `frame_encode`,
  `endpoint_is_full`, `user_write_bytes_via_walk`,
  `user_read_bytes_via_walk`.

**Issue title.** `R48-PREP-005.M3 elevate broker client-roundtrip
witness (sys_svc_lookup → sys_ipc_send → daemon reply → assert
ELVB_DISPATCH_STUB)`

## 5. Rollup: what changes and where

| File                                                    | M1 | M2 | M3 |
|---------------------------------------------------------|----|----|----|
| `src/kernel/core/ipc/elevate_broker.pdx`                | +  |    |    |
| `src/kernel/kernel_main.pdx` (boot call site)           | +  |    |    |
| `tests/kernel/ipc/elevate_broker_synth.pdx`             | ~  |    |    |
| `src/user/elevate_broker_daemon.pdx` (new)              |    | +  |    |
| `src/user/elevate_broker_daemon.ld` (new)               |    | +  |    |
| `src/user/init.pdx` (spawn cycle)                       |    | +  |    |
| `tools/userbin_embed.S` + tmpfs seed                    |    | +  |    |
| `tests/kernel/ipc/elevate_broker_roundtrip_synth.pdx` (new) |    |    | +  |
| `src/kernel/boot/witness/r30_platform.pdx` (witness call site) |    |    | +  |

Legend: `+` = adds, `~` = reworks in place.

## 6. Explicit non-scope

- **Policy evaluation inside the broker.** Auto-approve rules
  against the table in `src/kernel/core/user/elevate_policy.pdx`,
  approver-side UI, timer-driven expiry, cascade-revoke on denial,
  audit-journal writes on approve / deny — all follow-on. The
  parent line at `design/tooling/r49-r50-plan.md` line 354 pairs
  "elevate broker registration" with "auto-approve policy table
  wiring for KIND_ELEVATE_CHANNEL"; this design carves the
  registration half off as R48-PREP-005.M1..M3 and leaves the
  policy half for R48-PREP-005.M4+ (to be planned when the daemon
  body is being written, not before).
- **`libpdx-elevate.M2` daemon-body work.** Lives in
  `paideia-os/libpdx-elevate`; not paideia-os issues.
- **`pkg` / `rm` / `mkdir` M3 completion.** Those tool repos'
  `PkgElevate` / `RmElevate` / `MkdirElevate` wrappers unblock as
  soon as M3 lands, but the wrapper updates themselves are done
  in the respective external repos and tracked there. This design
  changes zero bytes outside `paideia-os` (this repo).
- **`svc_unregister` primitive.** Deferred; see §2.3(b).
- **`svc.audit-journal` twin fix.** Same shape (see §2.2); a
  parallel R49-PREP-006.M1..M3 plan is owed but not authored here.
  M1 of this plan reserves `AUDIT_JOURNAL_BROKER_ENDPOINT_ID = 17`
  in `elevate_broker.pdx` so the two well-known ids stay adjacent
  and the twin fix inherits the same numeric convention.
