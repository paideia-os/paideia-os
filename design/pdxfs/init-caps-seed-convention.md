# `_init_caps` seed-cap convention for standalone pdxfs CLI tools (PFS-02)

**Status:** Design-doc landing (PFS-02).  No kernel-side or tool-side
code lands in this wave; kernel enablement is stubbed in §6 and filed as
a dependent follow-up.
**Wave:** PFS (pdxfs user-space tool completion), chain-head PFS-02.
**Target consumers:** `tools/user/mount.pdxfs/` (`src/mount_op.pdx`,
`src/mint_wire.pdx`, `src/elevate.pdx`), `tools/user/umount.pdxfs/`
(`src/unmount_op.pdx`, `src/elevate.pdx`), and the future
`tools/user/libpdx-pipeline-rt/` call sites that will need the same two
seed caps once their syscall-site layer grows.
**Supersedes:** every "no broker-endpoint cap provisioned" /
"placeholder `.bss` elevate_channel_slot" comment in
`tools/user/mount.pdxfs/caps.decl`,
`tools/user/mount.pdxfs/src/mint_wire.pdx`,
`tools/user/mount.pdxfs/src/elevate.pdx`,
`tools/user/umount.pdxfs/caps.decl` and
`tools/user/umount.pdxfs/src/elevate.pdx`.
**Companion freeze:** `design/pdxfs/sys-mount-abi.md` §4
(KIND_PDXFS_MOUNT_TABLE row shape), §5 (PMT_OP_REMOVE_ROW +
VOL_OP_QUERY_HANDLE_COUNT contracts) — this doc complements the frozen
syscall ABI with the cap-table shape a tool must observe at startup to
reach that ABI with authority.

---

## §1 Overview

### §1.1 What the convention is for

`mount.pdxfs` and `umount.pdxfs` are standalone ring-3 ELF images with
their own `_start` symbols (not shared libraries).  Each is spawned by
PID 1 (`src/user/init.pdx` or its successor supervisor) via the
ordinary `sys_fork` + `sys_execve` cycle.  Neither tool is a server:
they execute, perform one mount/unmount, emit a `PdxFsMountRecord` to
the semantic pipe, and exit.

For such a tool to reach a *successful* non-dry-run mount/unmount it
needs, at startup, two authorities it cannot forge itself:

1. **Write authority on the singleton `KIND_PDXFS_MOUNT_TABLE`
   capability** (kind 0x1A5, see `sys-mount-abi.md` §4.1).  Needed by
   `mount.pdxfs/src/mount_op.pdx` to issue `PMT_OP_APPEND_ROW` after a
   successful `sys_mount`, and by `umount.pdxfs/src/unmount_op.pdx`
   step 5 to issue `PMT_OP_REMOVE_ROW` after a clean-unmount pipeline.
2. **A handle to the elevate-broker IPC endpoint**
   (`ELEVATE_BROKER_ENDPOINT_ID = 16`, see
   `src/kernel/core/ipc/elevate_broker.pdx` L59), used on-demand by
   `mount.pdxfs/src/elevate.pdx` and `umount.pdxfs/src/elevate.pdx` to
   mint a per-request `KIND_ELEVATE_CHANNEL` cap (0x191) when the
   mount-point class resolves to `/system/**`, `/boot/**`, `/dev/**`,
   or when `--force` is passed on a non-user-subtree unmount.  The
   broker's own policy (`design/security/elevate-policy-format.md` §2)
   decides approve/deny; the tool just needs the authority to *ask*.

Neither authority is minted at image load today — see the "no
broker-endpoint cap provisioned" blocker both tools' STATUS.md files
cite, and the `mount_mw_elevate_slot` `.bss` placeholder initialised to
0 in `mount.pdxfs/src/mint_wire.pdx`.  Both tools currently fail
closed: every system-tier mount refuses with `MW_ERR_NO_ELEVATE`, every
`--force` unmount with `UO_STUB_ELEVATION_DENIED`, every `/system`
unmount with `UR_RC_SYSTEM_UNMOUNT_REFUSED`.  The dispatch doc map
(PDXFS-dispatch-map §PFS-02) calls out this gap as the single blocker
on PFS-11, PFS-14, PFS-15.

This document fixes the convention by which those authorities arrive
in a tool's `cap_table` before `_start`, naming the slot numbers,
rights masks, encoding, and lifecycle.  It does NOT land the kernel
enablement for the two currently-unseeded kinds — that is a follow-up
tracked in §6.

### §1.2 Who provisions, who consumes

```
       ┌───────────────────────────┐
       │ PID 1 — init.elf (or      │
       │ successor supervisor)     │
       │                           │        boot    _init_caps sidecar
       │  owns the authoritative   │  ────────────── mints MOUNT_TABLE,
       │  KIND_PDXFS_MOUNT_TABLE   │                 ELEVATE-BROKER-EP
       │  singleton + the broker-  │                 into PID 1's
       │  endpoint handle minted   │                 cap_table (slots 4
       │  by elevate_broker_init   │                 and 5).
       └──────────┬────────────────┘
                  │
             sys_fork + sys_execve
                  │
                  ▼
     ┌─────────────────────────────┐
     │ child image: mount.pdxfs    │   its own _init_caps sidecar
     │  OR umount.pdxfs            │   declares slot 4 (MOUNT_TABLE)
     │  OR a future libpdx-        │   and slot 5 (ELEVATE broker
     │  pipeline-rt consumer       │   endpoint) with the rights
     │                             │   masks §2 pins; the loader's
     │  reads cap_slot 4/5 at      │   loader_seed_caps_from_symtab
     │  _start                     │   mints both at image-load time
     └─────────────────────────────┘   per §3 of
                                       design/loader/init-caps-sidecar.md.
```

**Provisioner:** PID 1's `_init_caps` sidecar is the authority root.
It declares the two caps in slots 4 and 5 of the global cap_table
(R20b posture — one global 256-descriptor cap_table shared across
tasks; per-task cap_tables are R21+ work, see
`design/capabilities/per-task-cspace.md`).  At boot, the loader
materialises PID 1's caps and the broker-endpoint handle is live.

**Consumers:** every pdxfs CLI tool (and every future
`libpdx-pipeline-rt` consumer that performs filesystem IO through the
same two authorities) declares the matching slot-4 and slot-5 entries
in its *own* `_init_caps` sidecar.  Per the R20b global cap_table
semantics (loader-seed-caps #1596 posture), the slot numbers are
global: slots 4 and 5 are reserved to this convention and no other
image's sidecar may name them.

**Non-consumers:** every image that does not touch the mount table or
the elevate broker — `init.elf`'s immediate children `child_hello`,
`/bin/sh` fallback, `echo_server`, `echo_client`, `acpi_supervisor`,
`pci_enumerator`, `audio_supervisor`, `compositor_selftest` — never
declares slots 4 or 5.  The build-time gate
(`tools/verify-user-cap-sidecars.sh`, policy §1 and §2) enforces this
by rejecting any sidecar whose kind field names 0x1A5 or 0x191
unless the slot number also matches §2.1 below.

---

## §2 Slot assignments

### §2.1 Reserved slots

The R20b global cap_table runs 256 descriptors (`cap/table.pdx`
§Table).  The pre-PFS allocations are:

```
  slot  kind                          holder image(s)                 Introduced
  ────  ────────────────────────────  ─────────────────────────────   ─────────────
   0    KIND_IPC_ENDPOINT (0x005)     echo_client / echo_server       R20b.M5-001
   1    KIND_IPC_ENDPOINT (0x005)     echo_client (reply endpoint)    R20b.M6-003
   2    KIND_IPC_ENDPOINT (0x005)     echo_server (own endpoint)      R20b.M5-001
   3    — (reserved for libpdx-rpc)                                   open
   4    KIND_PDXFS_MOUNT_TABLE (0x1A5) mount.pdxfs, umount.pdxfs,    PFS-02 (this doc)
                                       libpdx-pipeline-rt
   5    KIND_IPC_ENDPOINT (0x005)     mount.pdxfs, umount.pdxfs,     PFS-02 (this doc)
         → elevate-broker handle       libpdx-pipeline-rt
   6, 7 — (reserved for pdxfs tools follow-ons)                       open
   8    KIND_IPC_ENDPOINT (0x005)     acpi_supervisor                 R20-M4-002
   9    KIND_ACPI (0x020)             acpi_supervisor                 R20-M4-002
  10,11 — (reserved for driver supervisors)                            open
  12    KIND_IPC_ENDPOINT (0x005)     pci_enumerator                   R30
  13    KIND_PCI_DEV (0x030)          pci_enumerator                   R30
  14    KIND_IPC_ENDPOINT (0x005)     audio_supervisor                 R33.M5-001
  15    KIND_IPC_ENDPOINT (0x005)     audio_supervisor                 R33.M5-001
  16    KIND_IPC_ENDPOINT (0x005)     elevate_broker_daemon            R48-PREP-005.M2
                                       (daemon-side listener)
```

**PFS-02 proposes slot 4 and slot 5 — currently unassigned** — as the
canonical pdxfs tool seed slots.  The slot numbers are stable across
every pdxfs tool so a shared helper in a future
`libpdx-pipeline-rt`/`libpdx-pdxfs-common` can address them by name:

```
  LPX_SEED_SLOT_MOUNT_TABLE : u64 = 4
  LPX_SEED_SLOT_ELEVATE_EP  : u64 = 5
```

The numeric gap at slots 6/7 is left open for pdxfs follow-on tools
(e.g. `fsck.pdxfs`, `mountall.pdxfs`) that may need additional
authorities without perturbing the above.

### §2.2 Slot 4 — KIND_PDXFS_MOUNT_TABLE

Full `_init_caps` sidecar entry (16 bytes, see
`design/loader/init-caps-sidecar.md` §1):

```
  +0  u16 slot    = 0x0004       (slot 4, LPX_SEED_SLOT_MOUNT_TABLE)
  +2  u16 kind    = 0x01A5       (KIND_PDXFS_MOUNT_TABLE, cap/kind.pdx L2600+)
  +4  u32 rights  = 0x0000_000A  (R_PMT_INVOKE | R_PMT_WRITE)
  +8  u64 target_ptr = 0         (singleton — PMT_MAX = 1; the "row"
                                  argument is kind-fixed, see
                                  sys-mount-abi.md §4.3)
```

Packed as two little-endian u64 words (same shape as every sibling
sidecar):

```
  word 0 = 0x0000_000A_01A5_0004
  word 1 = 0x0000_0000_0000_0000
```

**Rights rationale:**

- `R_PMT_WRITE` (0x002) — required by `PMT_OP_APPEND_ROW` (reserved
  ordinal 2, dispatch arm pending — see sys-mount-abi.md §5.1 for the
  landed-vs-reserved op catalog) and `PMT_OP_REMOVE_ROW` (ordinal 4,
  wired per sys-mount-abi.md §5.2).
- `R_PMT_INVOKE` (0x008) — required by `PMT_OP_QUERY_SLOT_COUNT`
  (ordinal 3, wired) and the eventual `PMT_OP_LIST` / `PMT_OP_READ_ROW`
  ops that `umount.pdxfs/src/target_resolve.pdx`'s mount-table walk
  needs to resolve `<mount-point>` → `mount_id`.
- `R_PMT_READ` (0x001) — DELIBERATELY ABSENT.  Current pdxfs tooling
  reads the mount table through its `R_PMT_INVOKE`-gated query ops,
  never through a raw read; narrowing by one bit matches the
  mandatory-narrower-than-decl rule (`caps-decl-format.md` §4).
- `R_PMT_REVOKE` (0x010) — DELIBERATELY ABSENT.  A pdxfs CLI tool
  must never cascade-revoke the mount-table singleton — that is PID
  1's prerogative on supervisor shutdown.
- `R_PMT_OBSERVE` (0x400) — DELIBERATELY ABSENT.  Debug-print access
  belongs to `/bin/mount` + diagnostic shells, not the mount/unmount
  tools proper.

**Target-ptr rationale:** `KIND_PDXFS_MOUNT_TABLE` is a singleton
(`PMT_MAX = 1`, `kind_pdxfs_mount_table.pdx` L198), so no row index
is encoded in the sidecar.  The kernel's dispatch binds the one row
at `pmt_table_alloc` time; the sidecar's seeded descriptor just
copies the kernel's existing row handle.  target_ptr=0 matches the
"singleton row" convention — the loader's mint path uses the kind
alone to resolve the authoritative row.

### §2.3 Slot 5 — KIND_IPC_ENDPOINT (elevate-broker handle)

Full `_init_caps` sidecar entry:

```
  +0  u16 slot    = 0x0005       (slot 5, LPX_SEED_SLOT_ELEVATE_EP)
  +2  u16 kind    = 0x0005       (KIND_IPC_ENDPOINT — base per cap/kind.pdx)
  +4  u32 rights  = 0x0000_000A  (R_IPC_WRITE | R_IPC_INVOKE)
  +8  u64 target_ptr = (ELEVATE_BROKER_ENDPOINT_ID = 16)
                     | (DIR_BIDI = 2) << 16
                     = 0x0000_0000_0002_0010
```

Packed as two little-endian u64 words:

```
  word 0 = 0x0000_000A_0005_0005
  word 1 = 0x0000_0000_0002_0010
```

**Why KIND_IPC_ENDPOINT, not KIND_ELEVATE_CHANNEL:** a
`KIND_ELEVATE_CHANNEL` cap is PER-REQUEST — it reifies the state of
ONE in-flight elevation (REQUESTED → APPROVED / DENIED / EXPIRED /
REVOKED, see `kind_elevate_channel.pdx` §Section 1).  A tool mints a
fresh `KIND_ELEVATE_CHANNEL` on each elevation request by invoking
`elevate_channel_cap_mint_inner` with its endpoint cap as the parent
(the mint gate's "parent is a live endpoint" check,
`kind_elevate_channel.pdx` §Section 0).  Seeding a
KIND_ELEVATE_CHANNEL at image load would stamp a specific request_id
+ expire_ns at exec time, which no tool can use — every real elevate
request wants a fresh row.  The correct seed is the broker-endpoint
handle, from which the per-request channel is minted on demand.

**Rights rationale:**

- `R_IPC_WRITE` (0x002) — required by `sys_ipc_send` (SC+ ID 42) to
  publish an ELV_OP_REQ frame to the broker's listening endpoint.
- `R_IPC_INVOKE` (0x008) — required by the mint gate for
  `elevate_channel_cap_mint_inner` (consumes the endpoint cap as a
  parent authority during the derive step).
- `R_IPC_READ` (0x001) — DELIBERATELY ABSENT.  The tool never
  `recv`s from the broker on this cap; the broker's reply arrives on
  the per-request `KIND_ELEVATE_CHANNEL` whose `broker_endpoint_id`
  tail field (`kind_elevate_channel.pdx` §Section 1 row +40) names
  the reply route.

**Direction (`DIR_BIDI = 2`):** the broker-handle endpoint cap is
bidirectional at the IPC-endpoint level even though the tool's use is
send-plus-mint-only — the mint gate's parent-gate check accepts BIDI
or SEND; BIDI is the superset and matches the daemon-side
`elevate_broker_daemon`'s own sidecar entry (`src/user/elevate_broker_
daemon.pdx` L166 target 0x0000_0000_0002_0010).

**Why not seed the elevate_broker's listening endpoint directly:**
the daemon-side sidecar (slot 16) binds the LISTENING side of
endpoint_id=16 (the daemon that runs the request loop).  The CLIENT
side (what mount/unmount tools need) is the SEND-plus-mint handle to
the same endpoint_id — a distinct cap_table row with distinct rights
on the same underlying endpoint, resolved through
`endpoint_table_lookup` at IPC time.

### §2.4 Build-time gate update

`tools/verify-user-cap-sidecars.sh` (R31.M2-1596/1597) currently
rejects any sidecar entry whose kind is not in `KIND_SEEDABLE_TABLE`
(cap/kind.pdx L3528 — 6 entries at this landing).  Admitting the two
PFS-02 seed caps requires the kernel to grow that table by two
entries (§6), after which the gate accepts the slot-4/slot-5
assignments above without further change — the gate's slot-collision
check (policy §2) already rejects duplicates, so the slot numbers §2.1
pins are enforced from first landing.

---

## §3 Lifecycle

### §3.1 Mint

**At boot:** `kernel_main.pdx`'s init-image load path invokes
`loader_seed_caps_from_symtab` (`src/kernel/core/loader/seed_caps.pdx`
L170+) on `init.elf`'s image bytes.  The walker resolves `_init_caps`
+ `_init_caps_count` via the ELF symtab, colocates them into the
`_loader_symtab_sidecar_scratch` buffer, calls
`init_caps_validate` for structural correctness, then iterates each
entry minting via `cap_mint_write` into the global cap_table at the
declared slot.

**Precondition for slot 4:** `pmt_table_alloc`
(`src/kernel/core/cap/kind_pdxfs_mount_table.pdx` L355+) runs at boot
BEFORE PID 1's image load — it stamps a kind=0x1A5, in_use=1 row for
the singleton mount-table cap.  The validator's §6 kernel update
rewires `loader_seed_caps` so that a sidecar entry with kind=0x1A5
copies the already-materialised row into the target cap_table at the
declared slot, rather than minting a fresh row (there is only one
mount table).

**Precondition for slot 5:** `elevate_broker_init`
(`src/kernel/core/ipc/elevate_broker.pdx` L200+) runs at boot BEFORE
PID 1's image load — it claims `ELEVATE_BROKER_ENDPOINT_ID = 16` via
`endpoint_alloc_at(16)` + `elevate_broker_register(16)`.  The
validator's §6 kernel update rewires `loader_seed_caps` so that a
sidecar entry with kind=0x005 and target_ptr naming endpoint_id=16
mints a fresh KIND_IPC_ENDPOINT cap bound to that endpoint row at the
declared slot — the same shape the elevate_broker_daemon's own
sidecar uses for its listener side.

### §3.2 Inherit

**`sys_fork`:** fork does NOT clone the cap_table at R20b
(`sys_fork.pdx` phase 4 copies only `fd_table[]`, not caps).  A fork
without exec therefore inherits NOTHING from the parent's cap_table.
This is intentional — the R20b global cap_table is per-process
notionally but per-image-identity in practice.  A ring-3 code path
that forks without execving a fresh image sees whatever caps its own
image declared, independent of parent.

**`sys_execve`:** execve LOADS the child image's own `_init_caps`
sidecar via `elf_lite_load` → `loader_seed_caps_from_symtab`
(`sys_execve.pdx` §step 3.5 at commit `b238c3a0`).  The parent's
caps are torn down with the parent aspace (`aspace_teardown`).  So a
mount.pdxfs child spawned by PID 1 reads its caps FROM ITS OWN
SIDECAR, not from PID 1's.

This matters: for the PFS-02 convention, every pdxfs tool declares
its OWN slot-4/slot-5 entries.  PID 1's role is NOT to "pass down"
its caps; PID 1's role is to be the trusted-origin task whose
init-time cap seed proves to the kernel that slot 4 and slot 5 are
reserved to this convention (the build-time gate's uniqueness check
ensures no competing image claims either slot).

**Future R21 per-task cspace:** when per-task cap_tables land, the
convention stays identical — the slot numbers are local to each
tool's cap_table, and the loader seeds them from the tool's own
sidecar on each exec.  No inheritance primitive is needed.

### §3.3 Revoke

**At process exit:** `sys_exit` → `task_teardown` already walks the
exiting task's cap-ownership map and revokes every row the task
owned.  The slot-4 entry (singleton KIND_PDXFS_MOUNT_TABLE) is
*referenced*, not owned by, the tool — its ownership stays with PID
1 across the tool's lifetime, so the tool's exit does NOT cascade to
the kernel's authoritative row.  The slot-5 entry (KIND_IPC_ENDPOINT
to the broker) is similarly a reference to the daemon's endpoint,
not an owned endpoint, and the daemon's row survives the tool.

**On the tool's own cap_table teardown**: the row descriptors at
slot 4 and slot 5 are zeroed as part of the ordinary cap_table
teardown; the kernel-side singleton and the broker-endpoint row
remain untouched.

**Explicit revoke:** no PFS tool should ever call `cap_revoke` on
slot 4 or slot 5.  A tool that does so cascade-revokes PID 1's own
authority on the mount table or the broker endpoint and bricks every
subsequent fs tool.  `caps.decl`'s rights fields DO NOT include
`R_PMT_REVOKE` or `R_IPC_REVOKE` for either slot, so a well-formed
cap_invoke sequence cannot reach the revoke op.

---

## §4 Testing contract

### §4.1 User-space smoke test

A new ring-3 fixture, `src/user/pdxfs_seed_probe.pdx` (filed as a
PFS-02 follow-up, not landed in this wave), declares its own
`_init_caps` sidecar with the §2.2/§2.3 entries and, in its `_start`
body, confirms both caps are live by:

1. **Slot 4 probe:** `cap_invoke(slot=4, op_arg=PMT_OP_QUERY_SLOT_
   COUNT=3)` — expect `rax = 8` (PMT_MOUNT_SLOT_COUNT).  Any other
   return (notably `INVOKE_DENIED = 0xFFFFFFFFFFFFFFFD`) indicates
   the slot-4 entry was not seeded or was seeded with insufficient
   rights.
2. **Slot 5 probe:** encode a minimal ELV_OP_PING frame
   (op=0x7F, ver=1, reply_endpoint_id=<self>, payload_len=0) and
   `sys_ipc_send(slot=5, hdr_va, payload_va, 0)`.  `rax = 0` on
   success; a negative errno (notably `-EBADF`) indicates the slot-5
   entry was not seeded.

Both probes emit a `sys_debug_puts` fingerprint
(`PFS02 SEED PROBE OK\n` for the double-success case, with per-probe
failure markers in the failure arms) and `sys_exit(0 | 1)` with the
exit status.

### §4.2 Kernel-witness smoke test

A kernel-side witness in `src/kernel/boot/witness/pfs02_seed.pdx`
(filed as the §6 kernel-side follow-up's companion witness, not
landed in this wave) synthesises a 2-entry sidecar in `.bss` with the
§2.2/§2.3 entries and drives `loader_seed_caps` directly, then reads
the resulting cap_table rows at slot 4 and slot 5 to confirm:

- Slot 4 is kind=0x1A5, rights=0x00A, in_use=1.
- Slot 5 is kind=0x005, rights=0x00A, in_use=1, and its tail resolves
  to endpoint_id=16.

Emits `R PFS02 SEED WITNESS OK` on the serial log on
double-success, or a `R PFS02 SEED WITNESS FAIL <code>` fingerprint
on any mismatch.  Matches the shape every other R20b-substrate
witness uses (`r20b_loader.pdx`, `init_caps_witness_done`,
`elevate_broker_dispatch.pdx`).

### §4.3 QEMU-smoke integration

PFS-16's corpus harness exercises the end-to-end path (mount →
write → umount → remount → readback) which only succeeds if both
seed caps are live for each of the ten+ cases.  A missing slot-4
seed surfaces as `mount_op_invoke` → `PMT_OP_APPEND_ROW` ->
`INVOKE_DENIED`; a missing slot-5 seed surfaces as
`elevate.pdx`'s request path returning `MW_ERR_NO_ELEVATE` on any
`/system` case.  PFS-02's build-time gate (§2.4) plus PFS-16's
end-to-end verifier together close the convention's acceptance
contract.

---

## §5 Cross-reference

### §5.1 Tool-side consumption sites

| Submodule                              | File                                      | Site                                                                | Depends on slot |
|----------------------------------------|-------------------------------------------|----------------------------------------------------------------------|----------------|
| `tools/user/mount.pdxfs/`              | `src/mount_op.pdx`                        | `PMT_OP_APPEND_ROW` cap_invoke after successful `sys_mount`         | 4              |
| `tools/user/mount.pdxfs/`              | `src/mint_wire.pdx`                       | `mount_mw_elevate_slot` placeholder → real slot-5 handle            | 5              |
| `tools/user/mount.pdxfs/`              | `src/elevate.pdx`                         | `mount_elev_require_system` broker-request path                     | 5              |
| `tools/user/umount.pdxfs/`             | `src/unmount_op.pdx`                      | `PMT_OP_REMOVE_ROW` cap_invoke at step 5                            | 4              |
| `tools/user/umount.pdxfs/`             | `src/target_resolve.pdx`                  | `PMT_OP_LIST` / `PMT_OP_READ_ROW` mount-table walk (future ops)     | 4              |
| `tools/user/umount.pdxfs/`             | `src/elevate.pdx`                         | `elevate_request_force_unmount`, `elevate_request_system_unmount`   | 5              |
| `tools/user/umount.pdxfs/`             | `src/handle_check.pdx`                    | `VOL_OP_QUERY_HANDLE_COUNT` cap_invoke (uses KIND_VOLUME, not        |                |
|                                        |                                           | this convention — listed for completeness per sys-mount-abi.md §5.4) | n/a (vol cap)  |
| `tools/user/libpdx-pipeline-rt/` (future) | TBD                                    | pdxfs IO path's syscall layer                                       | 4, 5           |

Every one of the mount.pdxfs / umount.pdxfs sites above currently
fails closed on the "no cap provisioned" blocker (see each file's
own module header).  PFS-02's §6 enablement + each tool's PFS-10/11/
13/14/15 rewrite replaces the placeholder with a real `cap_invoke`
against slot 4 or slot 5.

### §5.2 Companion design docs

- `design/pdxfs/sys-mount-abi.md` §4 (KIND_PDXFS_MOUNT_TABLE row
  shape), §5.1 (PMT_OP catalog), §5.2 (PMT_OP_REMOVE_ROW contract),
  §6.1 (consumer map).
- `design/loader/init-caps-sidecar.md` §1 (16-byte record layout),
  §2 (image-side symbol convention), §3 (sidecar wire shape), §5
  (loader walker contract).
- `design/security/elevate-broker.md` (broker protocol, request/reply
  frame shapes).
- `design/security/elevate-policy-format.md` §2 (policy grammar the
  broker consumes).
- `design/architecture/caps-decl-format.md` §4/§5 (mandatory /
  optional rights-narrowing rule).
- `design/user/fs-tools-caps.md` §2.2 (mount.pdxfs cap set), §2.3
  (umount.pdxfs cap set) — this doc UPDATES both subsections to add
  slot 5 as a mandatory kind once §6 lands.

### §5.3 Kernel-side source citations

- `src/kernel/core/loader/init_caps.pdx` — `init_caps_validate`
  (R20b.M4-001, #1561).
- `src/kernel/core/loader/seed_caps.pdx` — `loader_seed_caps` +
  `loader_seed_caps_from_symtab` (R20b.M4-002/M6-001, #1562/#1564).
- `src/kernel/core/cap/kind.pdx` L3524 — `KIND_SEEDABLE_COUNT`,
  L3528 — `KIND_SEEDABLE_TABLE`, L3550 — `kind_is_loader_seedable`
  (R31.M2-1597, #1597).
- `src/kernel/core/cap/kind_pdxfs_mount_table.pdx` L154
  (KIND_PDXFS_MOUNT_TABLE = 0x1A5), L164–L184 (op catalog), L355+
  (`pmt_table_alloc` singleton materialisation).
- `src/kernel/core/cap/kind_elevate_channel.pdx` L84
  (KIND_ELEVATE_CHANNEL = 0x191), §Section 0 (parent-gate posture).
- `src/kernel/core/ipc/elevate_broker.pdx` L59
  (`ELEVATE_BROKER_ENDPOINT_ID = 16`), L200+
  (`elevate_broker_init`).
- `tools/verify-user-cap-sidecars.sh` — build-time gate; §2.4 above
  describes the two-line update required after §6 lands.

---

## §6 Kernel changes required to implement this convention (STUB — not landed in PFS-02)

PFS-02 is a design-doc wave.  The code below is **described, not
written**; a separate issue (filed as the §6 follow-up alongside
PFS-02's close) tracks the implementation.  Each change is small and
mechanical; none changes the behavior of any landed consumer that is
not already waiting on this convention.

### §6.1 Grow `KIND_SEEDABLE_TABLE`

`src/kernel/core/cap/kind.pdx` L3524: bump `KIND_SEEDABLE_COUNT`
from 6 to 8.
L3528: add two entries at the correct ascending position:

```
  pub let KIND_SEEDABLE_TABLE : [u64; 8] = [
    5,      // KIND_IPC_ENDPOINT
    0x15,   // KIND_DRIVER
    0x16,   // KIND_DMESG
    0x20,   // KIND_ACPI
    0x30,   // KIND_PCI_DEV
    0x191,  // KIND_ELEVATE_CHANNEL — PFS-02 (slot 5 holder is
            // KIND_IPC_ENDPOINT, but this entry is kept here so a
            // future tool that seeds the per-request channel cap
            // directly stays admissible)
    0x197,  // KIND_TTY — R106.SHELL (paideia-os #2425)
    0x1A5   // KIND_PDXFS_MOUNT_TABLE — PFS-02
  ]
```

Per-entry rationale lives next to each kind's declaration (same
convention as the existing six entries); each new entry gets a
comment block near the kind's `pub let KIND_* = …` declaration
citing PFS-02 as the admission reason.

The `kind_is_loader_seedable` linear-scan body (L3555) grows from a
6-entry walk to an 8-entry walk — the loop bound at L3556 (`mov r11,
6`) becomes `mov r11, 8`; nothing else changes.

### §6.2 `loader_seed_caps` singleton-row handling

`src/kernel/core/loader/seed_caps.pdx` grows a specialisation in its
mint loop: for a sidecar entry whose kind is 0x1A5
(KIND_PDXFS_MOUNT_TABLE), `cap_mint_write` is called with the
pre-existing singleton row address (from `pmt_table_alloc`'s module-
local pointer) instead of synthesising a fresh row.  The target_ptr
field in the sidecar entry is ignored for singleton kinds (hence §2.2's
`target_ptr = 0`).

Alternative: `cap_mint_write`'s inner mint-table lookup grows a
"kind-is-singleton" branch that resolves to the one row the kind
owns.  Either shape works; the second keeps `loader_seed_caps`
kind-agnostic and is preferred.  Both land in the §6 follow-up.

### §6.3 Broker-endpoint seed-time gate

`src/kernel/core/loader/seed_caps.pdx`'s mint path for a slot-5
candidate (kind=0x005, target_ptr naming endpoint_id=16) verifies at
mint time that endpoint_id=16 is live (via
`endpoint_table_slot_in_use(16)`); if the broker daemon has not
registered yet, mint returns a new sentinel
`LOADER_SEED_BROKER_NOT_READY = 0xFFFFFFF8` which
`elf_lite_load` propagates as `ELF_CAP_SEED_FAILED`.  This is a
boot-ordering constraint (the broker daemon must register before any
image declaring slot-5 is loaded); in practice PID 1's own sidecar
declares the two seeds and PID 1's successor-spawn chain ensures the
daemon is up before any pdxfs tool loads.

### §6.4 Build-time gate update

`tools/verify-user-cap-sidecars.sh`:

- Policy §1 (seedable-set check): regenerates from the grown
  `KIND_SEEDABLE_TABLE` automatically once the kernel update lands.
  No script edit required.
- Policy §2 (slot-collision check): add two reserved-slot entries
  for 4 and 5 that admit mount.pdxfs / umount.pdxfs / future
  libpdx-pipeline-rt by name, reject every other image.

### §6.5 CHANGELOG discipline

The §6 follow-up ticket produces per-primitive scratch CHANGELOG
entries at
`.plans/scratch/CHANGELOG-PFS-02-init-caps-seed-{kernel,gate}.md`
per the parallel CHANGELOG convention; main consolidates at phase
close.  PFS-02 (this doc) emits a doc-only scratch entry.

---

## §7 Open items (out of PFS-02 scope)

1. **Per-task cspace migration (R21+).**  When per-task cap_tables
   land (`design/capabilities/per-task-cspace.md`), the slot numbers
   §2.1 pins become per-task slot numbers — identical shape, no
   convention change required.  Noted here so the per-task cspace
   round plan is aware.
2. **libpdx-pipeline-rt syscall-layer wiring.**  The library will
   grow a `pdxfs_rt_init()` wrapper that confirms both seed caps are
   live at startup and returns a well-known error if either is
   missing.  Filed as a libpdx-pipeline-rt-side ticket once that
   library's syscall-site exists.
3. **mountall.pdxfs seed inheritance.**  `mountall.pdxfs` (PFS-16
   corpus harness, future tool) spawns many mount.pdxfs children in
   sequence.  Each child's image sidecar declares slots 4 and 5 the
   usual way; `mountall.pdxfs`'s own sidecar also declares them
   (same slot numbers, same rights).  No seed-inheritance primitive
   is needed because every image loads its own sidecar on exec.
4. **Future `/bin/mount` + `/bin/umount` POSIX wrappers.**  Any
   future POSIX-compat wrapper that forwards to the pdxfs tools
   inherits the convention — the wrappers themselves need the same
   seeds if they bypass the pdxfs CLI and invoke syscalls directly.
   Noted as a `/bin/mount` scope item once that wrapper is filed.

---

## §8 Change log

- **2026-10-11** — PFS-02 landing (this document).  Companion to
  PFS-01's sys-mount-abi.md freeze.  Fixes the slot numbers (4 and
  5), rights masks (0x00A on both), and target_ptr encodings for the
  two seed caps every pdxfs CLI tool consumes.  Kernel enablement
  (grow KIND_SEEDABLE_TABLE by two entries, singleton-row mint path,
  broker-endpoint seed-time gate) is stubbed in §6 and tracked as a
  follow-up ticket — PFS-02 does not land kernel code.
  Updates STATUS.md in `tools/user/mount.pdxfs/` and
  `tools/user/umount.pdxfs/` to reference this convention.

---

*This file is the authoritative seed-cap convention for the pdxfs
tool family.  Edits that change slot numbers, kinds, or rights masks
require coordination with every consumer in §5.1.*
