# SC+ Syscall Table v2 — Capability Gates & Effects Freeze

## Purpose

`design/user/syscall-table.md` (v1) is the frozen source of truth for
sysno/name/args/return-semantics — this doc does not duplicate that
table. v2 adds the dimension v1 does not cover: **which capability
kind, if any, gates each syscall, at which layer, and what
effects/capabilities annotation the real handler body declares.** This
matters because paideia-os's capability model (see
`design/architecture/security-model-overview.md`) claims "no ambient
authority" as a kernel-wide property, and the honest state of the
syscall table is that this property is enforced unevenly today — one
family has a real dispatch-layer capability-kind gate, and every other
family either gates inside the handler body on an ad-hoc basis or does
not gate on capability kind at all.

Source files:

- `src/kernel/core/syscall/dispatch.pdx` (3387 lines) — the full linear
  `cmp/je` dispatch chain, its own effects header (line 388-391:
  `!{mem, sysreg} @{cap, sched}`), and the `ipc_slot_to_endpoint` gate
  (lines 247-384).
- `src/kernel/core/syscall/handlers/*.pdx` — every `sys_*_body`'s own
  declared `!{effects} @{capabilities}` signature.
- `design/user/syscall-table.md` — arity/args/return semantics (v1,
  referenced not repeated).

## 1. The one real dispatch-layer capability gate: IPC (40/41/42)

`ipc_slot_to_endpoint(cap_slot, required_rights)`
(`dispatch.pdx:307-384`) is the **only** place in the entire syscall
table where the dispatch shim itself resolves a `cap_table` slot,
checks its `kind` field against a specific closed-enum value, and
checks a rights bitmask, before the syscall body ever runs:

- Bounds: `cap_slot < 256`.
- Kind: descriptor `kind == 5` (`KIND_IPC_ENDPOINT`) else `-EBADF`.
- Rights: `(rights & required) == required` else `-EACCES` — required
  is `0x09` (READ|INVOKE) for `sys_ipc_recv` (sysno 40), `0x0A`
  (WRITE|INVOKE) for `sys_ipc_send` (42) and `sys_ipc_reply` (41,
  which delegates to send's body).

This is explicitly a **scaffold artifact of R20b's rollout order**, not
a deliberate architectural singling-out of IPC: `dispatch.pdx:250-256`
notes the earlier M3-001..003 shims "treated a0 as a raw endpoint_id
because userspace had not yet been seeded any KIND_IPC_ENDPOINT caps,"
and `ipc_slot_to_endpoint` was added later (R20b.M6-002, #1565) once
real caps became reachable from ring-3. **Sysno 43 (`sys_svc_lookup`)
is explicitly NOT wired through this gate** — its `a0` is a user-VA
name pointer, not a cap slot; it *creates* a cap rather than checking
one (`dispatch.pdx:259-262`).

## 2. Everywhere else: body-level or no capability-kind gate

Every other syscall that takes what its own comment calls a `cap_slot`
argument (pdxfs txn family, volume mint, GUI framebuffer/page-flip
family, blkdev) passes that slot **straight through to the handler
body** as a raw `u64` with no dispatch-layer kind check — the dispatch
shim does a bare `mov rdi, rsi; // cap_slot (a0)` register shuffle and
nothing else (e.g. `dispatch.pdx:2961, 3047, 3273, 3283, 3292, 3300,
3308`). The capability-kind validation, where it exists, happens
**inside the body**:

- `sys_pdxfs_txn_open_body` / `sys_pdxfs_open_body`: parent slot must
  be `KIND_MEMORY` carrying `RIGHT_MINT` — body's own gate
  (`dispatch.pdx:2030, 2062` comments).
- `sys_pdxfs_dir_readnext_body`: `dir_cap_slot` gated against
  `KIND_PDXFS_FILE` + row-mode inside the body
  (`dispatch.pdx:2079, 2098`).
- Volume mount path: "cap_slot -> KIND_VOLUME lookup + VOL_RIGHT_MOUNT
  rights check (parallels `ipc_slot_to_endpoint` at L222)"
  (`dispatch.pdx:2214-2215`) — the comment's own wording concedes this
  is a body-side re-implementation of the same *pattern*
  `ipc_slot_to_endpoint` established, not a shared primitive.
- `sys_pdxfs_txn_commit_body` / `_abort_body` / `_undo_write_body`:
  "cap_slot -> row_id + state gate" inside the body
  (`dispatch.pdx:3030`).
- The GUI family (`sys_framebuffer_create/map`, `sys_page_flip`,
  `sys_page_flip_wait`, `sys_display_hotplug_subscribe`) passes its
  `*_cap_slot` argument through with a bare register move; the body's
  own justification text is the only place a kind-gate (if any) would
  be documented — not re-verified line-by-line here, but none of these
  dispatch sites contain a `cmp ... kind` sequence the way
  `ipc_slot_to_endpoint` does.

**VFS-classic and socket syscalls have no capability-kind gate at all**:
`sys_open`/`sys_read`/`sys_write`/`sys_close`/`sys_stat`/`sys_mkdir`/
`sys_socket`/`sys_bind`/etc. operate on a plain integer fd resolved
through the process fd_table, with no `cap_table` lookup anywhere in
their dispatch path (consistent with every VFS/socket body's own
declared `@{}`  or `@{cap}`-without-a-kind-check — see §3's distinction
below).

## 3. `@{cap}` in a body's signature ≠ "this syscall checks an incoming capability"

This is the precise distinction ξ-02 exists to draw. A handler body's
`@{cap}` annotation means *the body touches the capability subsystem in
some way* — which includes **minting** a new capability, not only
*checking* one. Two examples that look identical in the table below
but mean opposite things:

- `sys_svc_lookup_body` declares `@{cap}` (`sys_svc_lookup.pdx:190`)
  because it calls `cap_mint_write` to **install a new** descriptor —
  it never checks an incoming cap kind (its only argument-side gate is
  `name_len` range validation).
- `sys_ipc_recv_body` / `sys_ipc_send_body` declare `@{cap}` because
  their **caller** (the dispatch shim, via `ipc_slot_to_endpoint`) has
  already resolved a cap — the body itself receives a plain
  `endpoint_id`, having never touched `cap_table` directly. The `@{cap}`
  here is a widening carried up from the dispatch-layer gate's own
  declared capability set, not evidence the body re-checks anything.

Do not read the `@{cap}` column below as "this syscall is capability-
gated" without checking which of these two shapes applies; §1 and §2
name every syscall where a real kind-check exists.

## 4. Ambient-Authority Tension

`design/architecture/security-model-overview.md` §2 draws its
"how uneven is capability coverage today" narrative directly from this
section, so the two documents must agree on the exact sysno groups.
Restating §1-§3's findings as one explicit split:

- **Actually capability-gated** (real `kind` check somewhere in the
  call path, dispatch-layer or body-level): the IPC family
  (`ipc_recv`/`ipc_reply`/`ipc_send`/`svc_lookup`, sysnos 40-43 — note
  43 mints rather than checks, per §1), the PdxFS transaction/file
  family (`pdxfs_txn_open`/`pdxfs_open`/`pdxfs_dir_readnext`, 70-72,
  and `pdxfs_txn_commit`/`pdxfs_txn_abort`/`pdxfs_undo_write`/
  `volume_mint`, 104-107 and 114), the R105 GUI block
  (`framebuffer_create`/`framebuffer_map`/`page_flip`/
  `page_flip_wait`/`display_hotplug_subscribe`, 109-113), and
  `icmp_echo` (103 — gated on the `R_NET_PRIVILEGED_PROTOCOL` right,
  not a `cap_table` kind lookup, but a real authority check
  nonetheless).
- **Running on ambient authority — no `cap_table` lookup anywhere in
  dispatch:** the legacy POSIX-shaped core (`read`/`write`/`open`/
  `close`/`dup2`/`getpid`/`fork`/`execve`/`exit`/`wait4` — sysnos 0-3,
  32, 39, 56, 59-61), the whole VFS metadata block (`stat`/`getdents`/
  `mkdir`/`rmdir`/`unlink`/`rename`, 77-82), the entire BSD-socket
  surface (`socket` through `poll`, 87-102), and a set of newer,
  non-legacy syscalls that were never wired to any cap check despite
  landing alongside capability-native subsystems: `taskinfo` (83),
  `mountinfo` (84), `chdir`/`getcwd` (85-86), `pdxfs_stat_by_inode`
  (106), `display_enumerate` (108), `semantic_send` (115),
  `sched_wait_ns` (116), and `cwd_resolve` (517).

The legacy block's ambient posture is frozen-by-design (R15.M4,
Linux-numbering compatibility for mechanical userland ports — see
`design/user/syscall-table.md`'s own numbering-rationale section). The
newer ambient syscalls in the second bullet have **no such
justification on record** — they were added alongside the IPC/PdxFS/
GUI subsystems that do enforce a cap-kind check, and simply were not
audited against that discipline. This table does not know of any open
round or issue that owns closing that second gap; a future pass
generalizing `ipc_slot_to_endpoint` (§5) into a shared, family-agnostic
gate is the closest candidate fix on record.

## 5. Effects/capabilities table

Sysno/name/arity per `design/user/syscall-table.md` (not repeated
here); this table adds the gate layer, declared effects, and declared
capabilities pulled from each `sys_*_body`'s own type signature.

| Sysno | Name | Cap-kind gate | Gate layer | Effects `!{...}` | Capabilities `@{...}` |
|---|---|---|---|---|---|
| 0 | read | none (fd) | — | `{mem}` | `{}` |
| 1 | write | none (fd) | — | `{mem}` | `{}` |
| 2 | open | none (path) | — | `{mem}` | `{}` |
| 3 | close | none (fd) | — | `{mem}` | `{}` |
| 13 | dmesg | none | — | `{mem}` | `{}` |
| 32 | dup2 | none (fd) | — | `{mem}` | `{}` |
| 40 | ipc_recv | **KIND_IPC_ENDPOINT** | dispatch (`ipc_slot_to_endpoint`) | `{mem, sysreg}` | `{cap, sched}` |
| 41 | ipc_reply | **KIND_IPC_ENDPOINT** | dispatch (delegates to send's gate) | `{mem, sysreg}` | `{cap, sched}` |
| 42 | ipc_send | **KIND_IPC_ENDPOINT** | dispatch (`ipc_slot_to_endpoint`) | `{mem, sysreg}` | `{cap, sched}` |
| 43 | svc_lookup | none (mints, doesn't check) | body (`cap_mint_write`) | `{mem, sysreg}` | `{cap}` |
| 56 | fork | none | — | `{mem, sysreg}` | `{sched}` |
| 59 | execve | none | — | `{mem, sysreg}` | `{}` |
| 66 | clock_read_ns | none | — | `{mem}` | `{}` |
| 67/68/69 | sched_{set,get}affinity / reserve_lpe_class | none | — | `{mem}` | `{}` |
| 70 | pdxfs_txn_open | **KIND_MEMORY** (parent, RIGHT_MINT) | body | `{mem}` | `{cap}` |
| 71 | pdxfs_open | **KIND_MEMORY** (parent, RIGHT_MINT) | body | `{mem}` | `{cap}` |
| 72 | pdxfs_dir_readnext | **KIND_PDXFS_FILE** (dir_cap_slot) | body | `{mem, sysreg}` | `{cap}` |
| 74 | blkdev_cap_request | not verified (body-internal) | body | — | — |
| 75/76 | mount/umount | not verified (body-internal) | body | — | — |
| 77..82 | stat/getdents/mkdir/rmdir/unlink/rename | none (path/fd) | — | — | — |
| 83 | taskinfo | none | — | — | — |
| 84 | mountinfo | none | — | — | — |
| 85/86 | chdir/getcwd | none | — | — | — |
| 87 | socket | none (creates fd) | — | `{mem}` | `{cap}`* |
| 88 | bind | none (fd) | — | `{mem}` | `{cap}`* |
| 89 | listen | none (fd) | — | `{mem}` | `{cap}`* |
| 90 | accept | none (fd) | — | `{sysreg, mem}` | `{cap, sched, boot}`* |
| 91 | connect | none (fd) | — | `{sysreg, mem}` | `{cap}`* |
| 92 | send | none (fd) | — | `{mem}` | `{cap}`* |
| 93 | recv | none (fd) | — | `{sysreg, mem}` | `{cap, sched, boot}`* |
| 94 | shutdown | none (fd) | — | `{sysreg, mem}` | `{cap}`* |
| 95 | kill | none (pid) | — | `{mem, sysreg}` | `{sched}` |
| 96 | sendto | none (fd) | — | `{mem}` | `{cap}`* |
| 97 | recvfrom | none (fd) | — | `{mem}` | `{cap}`* |
| 98 | getsockopt | none (fd) | — | `{mem}` | `{cap}`* |
| 99 | setsockopt | none (fd) | — | `{mem}` | `{cap}`* |
| 100 | getpeername | none (fd) | — | `{mem}` | `{cap}`* |
| 101 | getsockname | none (fd) | — | `{mem}` | `{cap}`* |
| 102 | poll | none (fd array) | — | `{mem, sysreg}` | `{cap, sched, boot}`* |
| 103 | icmp_echo | none (checks `R_NET_PRIVILEGED_PROTOCOL` right, not a cap-slot kind) | body | `{sysreg, mem}` | `{cap}` |
| 104 | pdxfs_txn_commit | **KIND_PDXFS_TXN** (cap_slot→row_id+state) | body | `{mem, sysreg}` | `{cap}` |
| 105 | pdxfs_txn_abort | **KIND_PDXFS_TXN** (cap_slot→row_id+state) | body | `{mem, sysreg}` | `{cap}` |
| 106 | pdxfs_stat_by_inode | none (inode_no) | — | `{mem, sysreg}` | `{cap}`† |
| 107 | pdxfs_undo_write | **KIND_PDXFS_TXN** (cap_slot→row_id+state) | body | `{mem, sysreg}` | `{cap}` |
| 108 | display_enumerate | none | — | `{mem, sysreg}` | `{cap}`† |
| 109 | framebuffer_create | **KIND_DISPLAY_BACKEND** (per row-comment gate) | body | `{mem, sysreg}` | `{cap}` |
| 110 | framebuffer_map | **KIND_FRAMEBUFFER** (`R_FB_MAP` right) | body | `{mem, sysreg}` | `{cap}` |
| 111 | page_flip | **KIND_PAGE_FLIP** (`R_FLIP_INVOKE`) | body | `{mem, sysreg}` | `{cap, sched}` |
| 112 | page_flip_wait | **KIND_PAGE_FLIP** (`R_FLIP_INVOKE`) | body | `{mem, sysreg}` | `{cap, sched}` |
| 113 | display_hotplug_subscribe | **KIND_HOTPLUG_CHANNEL** (`R_HPCH_SUBSCRIBE`) | body | `{mem, sysreg}` | `{cap}` |
| 114 | volume_mint | **KIND_VOLUME** parent (superblock validation) | body | `{mem, sysreg}` | `{cap}` |
| 115 | semantic_send | none | — | `{mem}` | `{}` |
| 116 | sched_wait_ns | none | — | `{mem, sysreg}` | `{sched, boot}` |
| 517 | cwd_resolve | none | — | `{mem, sysreg}` | `{cap}`† |
| 527 | pdxfs_fault_inject | none (boot-flag gated) | — | `{mem, sysreg}` | `{}` |

`*` = body declares `@{cap}` because it resolves a socket-row / fd
structure that itself carries capability-shaped metadata in this
kernel's fd_table design, not because a `cap_table` slot is checked —
not independently re-verified line-by-line for this freeze; flagged so
a future pass can confirm rather than assume.
`†` = `@{cap}` present in the signature but no `cap_table` kind-check
found in the body's own dispatch path during this survey; likely a
widening carried from a callee, per the §3 distinction — not
independently traced to its source in every case.

## 6. Future work (already deferred per existing comments)

- **Per-task cap_tables (R21+)**: `dispatch.pdx:281-285` and
  `kind_endpoint.pdx` both note R20b's single **global** 256-slot
  `cap_table`; `ipc_slot_to_endpoint`'s own justification says the
  per-task split "will grow a `_current_tcb.cap_table` deref at the
  head; body stays byte-identical" — i.e. the gate mechanism is
  designed to survive that migration unchanged, but the migration
  itself has not landed.
- **Extending real dispatch-layer cap-kind gating beyond IPC**: no
  comment found committing to this as planned work; §2's body-level
  gates for pdxfs-txn/volume/GUI families are the closest present
  analogue, but they are per-family reimplementations of the pattern,
  not a shared dispatch-layer primitive the way `ipc_slot_to_endpoint`
  is for IPC. A future round generalizing `ipc_slot_to_endpoint` into
  a family-agnostic `cap_slot_to_kind_checked` gate for every
  `cap_slot`-shaped syscall argument would close this table's largest
  architectural inconsistency.
