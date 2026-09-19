# OOM_REASON audit anchor record (τ-05, scaffold)

Wave τ landed the OOM killer substrate (`src/kernel/core/sched/oom.pdx`,
τ-04) and this document establishes the wire format the follow-on
landing will pipe through `sys_semantic_send` (sysno 115) so a
userland audit consumer can decode OOM events without heuristics on
the UART fingerprint.

## Status at τ-05 landing

- `oom_kill_current()` emits the UART fingerprint `OOM KILL PID=NN\n`
  (τ-04 wire artifact) as the only observable OOM signal.
- No anchor record is emitted from the kernel-side OOM path yet: the
  `sys_semantic_send` contract copies its record from user VA via
  `user_read_bytes_via_walk`, which faults from kernel context (no
  user CR3 is loaded, so the walk resolves against the kernel PML4).
- This document defines the wire shape the eventual kernel-facing
  emitter will produce so that a userland `pdx-audit` consumer (see
  `src/user/audit/`) can write its decoder against a stable spec
  BEFORE the emitter lands.

## Wire format (24 bytes, little-endian)

Field layout, absolute offsets from the record base:

    offset  size  field              units / range
    ------  ----  ----------------   ----------------------------------
    +0      8     pid_killed         u64: the OOM'd task's pid, in
                                     [1, MAX_PIDS-1] = [1, 63]
    +8      8     resource_kind      u64: which resource was exhausted
                                     when the kill fired
    +16     8     attempted_bytes    u64: allocation size in bytes the
                                     caller was asking for at the
                                     failure (0 for unknown)

### `resource_kind` union

Match `Rlimits.RLIMIT_*` ordinals where possible so a single decoder
handles both `getrlimit` telemetry and OOM events:

    0    RESOURCE_PHYS_PAGE     phys_alloc exhausted (τ-04 origin)
    1    RESOURCE_ASPACE_PT     aspace_map ran out of frames for PT
                                intermediate tables
    2    RESOURCE_TCB_SLAB      task_pool.pdx pid_alloc refused (63
                                concurrent tasks)
    3    RESOURCE_INODE_POOL    vnode_alloc refused (deferred)
    4    RESOURCE_CAP_TABLE     cap_alloc refused (deferred)
    5    RESOURCE_FD_TABLE      per-task fd_table full (deferred)

Every non-`RESOURCE_PHYS_PAGE` value is reserved at v1: τ-04 only
wires the phys_alloc arm.  Subsequent waves that grow their own OOM
posture pick their ordinal from the reserved set and file an update
here as part of the same landing.

## Schema tag

`sys_semantic_send` takes a `schema` opaque tag the consumer filters
on:

    SEMANTIC_SCHEMA_OOM_REASON = 0x544F4D5F // "OOM_" in little-endian ASCII

The tag is publicly declared in `src/kernel/core/sched/oom.pdx` (once
the emitter lands) and matched by the userland decoder.

## Emitter siting

Two candidate emit sites, ordered by preference:

1. **Kernel-side `semantic_pipe_emit(schema, ptr, len)`** (preferred):
   a new primitive in `src/kernel/core/audit/semantic_pipe.pdx` that
   writes directly into `_semantic_ring` via kernel-VA memcpy, no
   `user_read_bytes_via_walk` involved.  Callable from any kernel
   context, including `oom_kill_current`.  Signature identical to
   `sys_semantic_send_body` minus the user-VA copy.

2. **Ring-3 housekeeping task**: `oom_kill_current` stashes the
   `(pid, resource, bytes)` triple in a per-kernel scratch slot; a
   privileged housekeeping task in ring-3 polls the slot on each tick
   and issues `sys_semantic_send` on the kernel's behalf.  Rejected
   because it adds a scheduling dependency between the OOM event and
   its audit record.

The R110+ audit-canonicalisation wave picks between these and lands
the emitter.

## Interim wire

Until the emitter lands, post-mortem tooling greps the UART transcript
for `OOM KILL PID=<hex>` (τ-04 fingerprint).  The transcript carries
no `resource_kind` or `attempted_bytes` -- both are inferable at
low-fidelity from the surrounding call chain (a phys_alloc failure in
a kernel_main.pdx spawn path implies RESOURCE_PHYS_PAGE), but a
consumer that needs machine-precision waits for the semantic-pipe
emitter.

## Cross-reference

- Substrate: `src/kernel/core/sched/oom.pdx` (τ-04)
- Fingerprint: `OOM KILL PID=<hex>\n` on COM1 UART
- Related capability: `Rlimits.RLIMIT_*` ordinals (τ-03)
- Semantic pipe ring: `src/kernel/core/syscall/handlers/sys_semantic_send.pdx`
