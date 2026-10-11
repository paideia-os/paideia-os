# sys_mount / sys_umount — Frozen ABI (PFS-01)

**Status:** FROZEN — adopted at paideia-os commit `c49a4bff` (Wave 84, I8
GuC/HuC firmware manifest + submodule).
**Wave:** PFS (pdxfs user-space tool completion), chain-head PFS-01.
**Scope:** Kernel-side syscall contract that the user-space tools
`mount.pdxfs`, `umount.pdxfs`, and (through them) `libpdx-volume`,
`libpdx-elevate` and `mountall.pdxfs` consume.  This is a documentation
pass — no code changes.
**Supersedes:**
- The aspirational cap-slot ABI described in
  `src/kernel/core/syscall/dispatch.pdx` L2400-L2422 (never shipped —
  explicitly retracted by L2429 "ABI adopted (differs from the
  aspirational cap-slot ABI in the §Shim contract comment above — that
  comment described a design that never landed; the shim's actual
  signature is what ships)").
- Every "KERNEL GAP" / "dispatch_mount unwired" / "dispatch_umount
  unwired" assertion in `tools/user/mount.pdxfs/STATUS.md` and
  `tools/user/umount.pdxfs/STATUS.md` prior to this doc.  Those
  assertions were authored before the dispatch wiring landed and are
  stale as of commit `c49a4bff`.

---

## §1 Overview

`sys_mount` (sysno 75) and `sys_umount` (sysno 76) are the ring-3-
facing endpoints of PaideiaOS's volume-mount lifecycle.  They expose
the kernel primitives at `src/kernel/core/fs/mount.pdx` (bootstrap +
submount), `src/kernel/core/fs/pdxfs/mount_block.pdx` (block-backed
PdxFS mount), and `src/kernel/core/fs/pdxfs/umount_block.pdx` (clean
unmount pipeline) to a userland that must:

1. provision a mount from either a tmpfs backend or a block-backed
   PdxFS volume (`mount.pdxfs`);
2. tear a mount down either lazily (drain window) or immediately
   (block-cache flush + checkpoint advance + CLEAN superblock stamp +
   row clear) (`umount.pdxfs`);
3. introspect the mount table for operator tools (`/bin/mount`,
   `mountall.pdxfs`).

Both syscalls use the standard SysV argument-register convention
(rdi/rsi/rdx/rcx/r8/r9) once the dispatch shim at
`src/kernel/core/syscall/dispatch.pdx` has shuffled the raw
`syscall`-site register layout into the shim's call shape.

Callers (expected consumers for the PFS wave):

- `tools/user/mount.pdxfs/src/mount_op.pdx`    (consumes sys_mount)
- `tools/user/umount.pdxfs/src/unmount_op.pdx` (consumes sys_umount)
- `tools/user/libpdx-volume/src/*.pdx`          (library layer — exposes
  the syscall ABI through typed wrappers; today the library has no
  direct syscall-site but will grow one in PFS-02..PFS-15)
- `tools/user/mountall.pdxfs/*` (future, PFS-16+ corpus harness)

Non-callers (ruled out by design): no kernel-side witness, no boot
path, and no init-ring-0 consumer talks to these syscalls.  They are
ring-3-only entry points.

---

## §2 sys_mount — syscall contract

### §2.1 Live source

- Syscall body + shim: `src/kernel/core/syscall/sys_mount.pdx` L274-L842.
  - `sys_mount_body`      L433-L727 (kernel-VA entry point).
  - `sys_mount_shim`      L764-L841 (user-VA entry point, dispatched
    from sysno 75).
- Dispatch wiring:        `src/kernel/core/syscall/dispatch.pdx`
  - sysno-75 arm:         L733-L734 (`cmp rdi, 75; je dispatch_mount`).
  - Dispatch label body:  L2452-L2461 (`dispatch_mount:` register
    shuffle + `call sys_mount_shim`).

### §2.2 Syscall number

```
sysno 75 = SYS_MOUNT
```

Design-doc `volume-lifecycle-mechanism.md §10.1` had reserved 73/74
for the mount/umount pair; sysno 74 was consumed by
`SYS_BLKDEV_CAP_REQUEST` (#1675, R51.M8-001) in the interval, so
R53.M2-001 shifted the pair to 75/76 per §10.1's own "IDs are
negotiable" clause (see `dispatch.pdx` L717-L732 for the rationale
note).

### §2.3 Register ABI (dispatch-site view)

Raw `syscall` instruction with:

```
rax = sysno                   (75)
rdi = sysno (duplicated by the syscall_entry marshaller; see
      dispatch.pdx L~700 for the shape — rax arrives in rdi inside
      dispatch_table)
rsi = a0 = dev_path_va        (user VA, byte buffer, NOT NUL-terminated at
                               this boundary; the shim bounces into kernel
                               scratch, see §2.5)
rdx = a1 = dev_path_len       (u64, bytes;      bounds [1..256])
rcx = a2 = mount_point_va     (user VA, byte buffer, NOT NUL-terminated)
r8  = a3 = mount_point_len    (u64, bytes;      bounds [1..256])
r9  = a4 = backend_id         (u64, legal values: 0 = tmpfs,
                                                  5 = pdxfs_block)
```

`dispatch_mount` (dispatch.pdx L2452-L2461) performs the SysV register
shuffle `rdi←rsi, rsi←rdx, rdx←rcx, rcx←r8, r8←r9`, aligns the stack
with `sub rsp, 8`, and tail-calls `sys_mount_shim`.

Return value in `rax`:

- `[0..7]`                            — mount_slot (success; this is
                                        the `_mount_table[]` row index,
                                        0 is the pinned root slot).
- `0xFFFFED60`–`0xFFFFED67`           — sys_mount's own failure band
                                        (see §2.6).

The caller discriminates success from failure with
`cmp rax, 8; jae error` — mount_slot ids never reach 8 (MOUNT_MAX=8;
sentinels sit far outside that range by construction).

### §2.4 Path-string encoding

Both path arguments (`dev_path`, `mount_point`) use the same
length-prefixed byte-buffer convention:

- The user passes **(user_va, byte_len)** — the pointer is the start
  of the buffer; the length is the exact byte count, **excluding** any
  trailing NUL.
- The user buffer is NOT required to be NUL-terminated.  The shim
  copies exactly `len` bytes into a 256-byte .bss scratch
  (`_sys_mount_dev_scratch`, `_sys_mount_mp_scratch` —
  `sys_mount.pdx` L361-L362), and `sys_mount_body` consumes the copy
  by `(ptr, len)` pair; no code path within sys_mount_body reads past
  the length.
- Length bounds: `[1..256]` for both paths.  Zero-length → EINVAL_*_LEN;
  `> 256` → EINVAL_*_LEN.  `256` IS legal for sys_mount (the shim's
  gate at L787-L794 uses `ja 256`, so 256 is accepted; the scratch is
  exactly 256 bytes).

**Encoding note vs. sys_umount:** sys_umount's shim writes an explicit
NUL at `scratch[path_len]` (see §3.5) because the body passes the
scratch pointer to `path_resolve`, which still uses end-of-string
semantics internally.  sys_mount's body does NOT NUL-terminate — its
backend arms consume the buffer by `(ptr, len)` throughout.

**UTF-8 posture:** path bytes are opaque to sys_mount — the kernel
performs byte-by-byte comparison for the `/dev/pdxvol<H>` prefix match
(backend_id=5, see §2.7) and byte-by-byte feeds for the tmpfs
`mount()` call.  UTF-8 interpretation (if any) is the responsibility
of the next layer; this ABI treats paths as uninterpreted byte
sequences.

### §2.5 KPTI bounce

Called from ring-3, `sys_mount_shim` is reached with CR3 holding
`_kernel_pml4_pa` under strict-KPTI; raw user VAs cannot be touched
directly.  The shim calls `user_read_bytes_via_walk`
(`src/kernel/core/syscall/user_read.pdx` L577) once per path to copy
the user buffer into the kernel-side .bss scratch via a per-byte
4-level PML4 walk through the current TCB's `user_pml4_va`.  Any
walker refusal (unmapped page, bad CR3 synthesis) returns
`SYS_MOUNT_EFAULT` (`0xFFFFED65`).

A kernel-witness caller (e.g. the boot smoke) that already holds
kernel VAs for the two paths can bypass the shim by calling
`sys_mount_body` directly with kernel-VA pointers — the body does no
walker call and no `user_ptr_ok` gate.  This is explicitly supported
by the body's doc header (`sys_mount.pdx` L245-L249).

### §2.6 Permission / rights model

**Current landing (as of commit `c49a4bff`):** `sys_mount` has NO
caller-side authority gate.  Any ring-3 caller with a valid user-VA
path pair and a legal backend_id can invoke the syscall and reach
either `mount()` (tmpfs path) or `mount_pdxfs_block()` (block path).

Rationale for the no-cap posture:

- `volume-lifecycle-mechanism.md §6.3`'s aspirational `VOL_RIGHT_MOUNT`
  on a per-caller KIND_VOLUME cap-slot gate was retracted when the
  landing shifted to the dev-path-string ABI (dispatch.pdx L2429-L2431
  explicitly retracts the earlier cap-slot design).
- For backend_id=5, authority is enforced *downstream*: the
  `/dev/pdxvol<H>` parser routes through the volume registry
  (`kind_volume.pdx` → `volume_tail_valid` + `volume_row_device_slot`)
  which only admits rows that a R51 block-device driver minted at
  probe time.  A ring-3 caller cannot forge a row_id outside [0..16)
  that resolves to a bdev_cap; forging a row_id *inside* that range
  that no probe populated yields `SYS_MOUNT_ENODEV`.

**Follow-up:** PFS-11 (per the dispatch map) wires a
`VOL_OP_QUERY_DEVICE_SLOT`-style capability check at the `<volume-cap>`
→ dev_path resolution step inside `mount.pdxfs`.  That is a *tool-side*
gate, not a kernel-side cap check — the kernel's position at this
freeze is "all ring-3 callers are equal; authority comes from
whichever bdev_cap the volume registry hands back."

### §2.7 Error-return convention

Band: `0xFFFFED60..0xFFFFED67` (R53 band, slice allocated to
sys_mount in `sys_mount.pdx` L151-L191 and §Failure taxonomy block).

```
0xFFFFED60  SYS_MOUNT_EINVAL_BACKEND     backend_id not in {0, 5}
0xFFFFED61  SYS_MOUNT_EINVAL_MP_LEN      mount_point_len == 0 or > 256
0xFFFFED62  SYS_MOUNT_EINVAL_DEV_LEN     dev_path_len    == 0 or > 256
0xFFFFED63  SYS_MOUNT_UNIMPL_PDXFS_BLOCK (RESERVED — no longer emitted
                                          after R107.M1 landed the
                                          real backend=5 path; retained
                                          for forward-compatibility)
0xFFFFED64  SYS_MOUNT_MOUNT_FAIL         forwarded from either mount()
                                          (tmpfs arm, 0xFFFF
                                          translation) or
                                          mount_pdxfs_block (block arm,
                                          any rax >= 8 fold)
0xFFFFED65  SYS_MOUNT_EFAULT             shim walker rejected a user path
                                          (either dev_path_va or
                                          mount_point_va unmapped under
                                          current TCB's PML4)
0xFFFFED66  SYS_MOUNT_ENODEV             R107.M1: dev_path did not
                                          resolve to a live KIND_BLKDEV
                                          cap (bad prefix, non-hex
                                          index, or syntactically-valid
                                          row_id that no probe
                                          registered)
0xFFFFED67  SYS_MOUNT_ENOMEM_CAP         R107.M1: sys_mount block-arm
                                          cap-slot pool [224..232)
                                          exhausted (8 active block
                                          mounts already)
```

**Mapping to libpdx-volume `LPV_E_*` taxonomy** (FAILS codes consumed
by the user-space tool):

| Kernel sentinel          | libpdx-volume code (recommended) |
|--------------------------|----------------------------------|
| `SYS_MOUNT_EINVAL_*`     | `LPV_E_INVAL`                    |
| `SYS_MOUNT_MOUNT_FAIL`   | `LPV_E_MOUNT_FAIL`               |
| `SYS_MOUNT_EFAULT`       | `LPV_E_FAULT`                    |
| `SYS_MOUNT_ENODEV`       | `LPV_E_NODEV`                    |
| `SYS_MOUNT_ENOMEM_CAP`   | `LPV_E_NOMEM`                    |

PFS-10 wires this mapping inside `mount.pdxfs/src/mount_op.pdx`.

### §2.8 dev_path convention for backend_id=5 (pdxfs_block)

Syntactic shape (`sys_mount.pdx` L193-L209):

```
/dev/pdxvol<H>   —   12 bytes total
                    H = one hex digit '0'..'9' or 'a'..'f'
                    encodes a volume-registry row_id in [0..16)
```

The parser is a syntactic bridge until the R107.M2 devfs landing
replaces it with a proper tmpfs_lookup chain through a mounted `/dev`
subtree.  Lifting from row_id to KIND_BLKDEV cap happens inside the
kernel via `volume_tail_valid(row_id)` +
`volume_row_device_slot(row_id)` (both landed at R52.M5).

**For PFS-10 (mount.pdxfs rewrite):** the client's `<volume-cap>`
positional (e.g. `cap:volume:0x42`) must be translated into
`/dev/pdxvol4` before the sys_mount syscall.  The mapping is: hex
nibble of the volume cap slot → single-hex-digit of the dev_path.
PFS-11 lands the real `VOL_OP_QUERY_DEVICE_SLOT` wire-through that
builds this string from the volume cap handle.

### §2.9 Fingerprint tag emission on success

On success only (NOT on any `0xFFFFED6*` sentinel), `sys_mount_body`
emits an audit record (`sys_mount.pdx` L652-L706):

```
audit_emit(
  kind         = 0,
  slot         = mount_slot,
  evt          = AUD_EV_MOUNT = 13   (audit_schema.pdx #1754)
  at           = 0,
  result       = 0,
  payload_lo   = (op_disc<<28) | (backend_id<<24) | path_hash_24
)
  where op_disc      = 0  (SYS_MOUNT_OP_DISC_MOUNT)
        backend_id   = 0 or 5 (4-bit slice)
        path_hash_24 = 24-bit djb2 fold of mount_point bytes
                       (NON-CRYPTOGRAPHIC placeholder — blake3(path)
                        follows once blake3_hash32 lands kernel-side,
                        see paideia-as RELEASE-NOTES-v0.20.md Class-A
                        blocker)
```

Audit emission is best-effort — any `AUD_ERR_*` return from
`audit_emit` is discarded by sys_mount_body and does NOT affect the
mount decision (matches audit_schema.pdx §5's every-call-site
convention).

Refused mounts emit no audit record.  A user-space tool wanting
INTENT-side audit coverage must emit its own INTENT record before
calling the syscall (which is what `mount.pdxfs/src/audit_wire.pdx`
already does — see PFS-10's incremental edit for the shape).

---

## §3 sys_umount — syscall contract

### §3.1 Live source

- Syscall body + shim: `src/kernel/core/syscall/sys_umount.pdx` L212-L739.
  - `sys_umount_body`         L332-L517 (kernel-VA entry point).
  - `_su_emit_umount_audit`   L564-L629 (module-local audit helper
    shared by both lazy and immediate branches).
  - `sys_umount_shim`         L672-L738 (user-VA entry point).
- Dispatch wiring:            `src/kernel/core/syscall/dispatch.pdx`
  - sysno-76 arm:             L735-L736 (`cmp rdi, 76; je
    dispatch_umount`).
  - Dispatch label body:      L2463-L2470 (`dispatch_umount:` reads
    `_current_tcb` for arg0 and calls `sys_umount_shim`).

### §3.2 Syscall number

```
sysno 76 = SYS_UMOUNT
```

### §3.3 Register ABI (dispatch-site view)

Raw `syscall` instruction with:

```
rax = sysno                   (76)
rsi = a0 = mount_point_va     (user VA, byte buffer, NOT NUL-terminated;
                               the shim copies into _sys_umount_path_
                               scratch and appends its own NUL at
                               scratch[path_len])
rdx = a1 = mount_point_len    (u64, bytes; bounds [1..255];
                               NOT [1..256] like sys_mount — the shim
                               reserves scratch[path_len] for its own
                               NUL write, so path_len must leave one
                               byte of headroom)
rcx = a2 = flags              (u64; bit 0 = UMOUNT_LAZY = 0x1;
                               all other bits reserved → EBADFLAGS)
```

`dispatch_umount` (dispatch.pdx L2463-L2470) marshals arg0 from
`[rip+_current_tcb]` (sys_umount's shim takes a `current` arg for ABI
parity with sys_execve_shim; the arg is unused at R53.M2 but the shim
signature carries it for the eventual TCB-field audit-actor wiring
round) and calls `sys_umount_shim`.

Return value in `rax`:

- `0`                                 — success (lazy flag armed OR
                                        clean-unmount pipeline completed).
- `0xFFFFED68..0xFFFFED6E`            — sys_umount's own failure band
                                        (see §3.6).
- Any other non-zero sentinel         — forwarded verbatim from
                                        `umount_pdxfs_block`
                                        (`umount_block.pdx`'s own
                                        taxonomy, including
                                        `0xFFFF`, `0xFFFFED27`, and
                                        the `sb_/vol_/jnl_` codes).

**Important:** sys_umount's body does NOT rewrite `umount_pdxfs_block`'s
sub-codes into the ED68..6F band — forwarding preserves the substrate
diagnosis for operator or smoke-witness consumption (`sys_umount.pdx`
L75-L82).  A caller cannot assume every non-zero return falls in
ED68..6F.

### §3.4 Path-string encoding

Same opaque-byte-buffer convention as sys_mount's §2.4, with ONE
difference: the shim writes an explicit NUL at `scratch[path_len]`
after the walker copy because the body passes the scratch pointer to
`path_resolve`, which still uses end-of-string semantics internally.

Length bounds for sys_umount: `[1..255]` (the 256-byte scratch minus
one reserved byte for the shim-written NUL).  Zero-length or
`> 255` → `SYS_UMOUNT_ERR_EBADPATH`.

The body's own gate (`sys_umount.pdx` L358-L361) accepts up to 256
for a direct witness-side caller that supplies a kernel-VA path (no
scratch bounce, no NUL required); the stricter 255 cap is a
shim-only concern.

### §3.5 KPTI bounce

Same shape as sys_mount's §2.5: `user_ptr_ok` gate
(`ptr_check.pdx` L42) first, then `user_read_bytes_via_walk` for the
per-byte copy, then a one-byte NUL write at `scratch[path_len]`.
Walker refusal returns `SYS_UMOUNT_ERR_EFAULT` (`0xFFFFED6E`).

### §3.6 Permission / rights model

**Current landing:** sys_umount has NO caller-side cap gate.  Any
ring-3 caller can request either lazy or immediate unmount of any
mount slot their mount_point string resolves to, subject to one hard
refusal:

- **Root umount is refused.**  `sys_umount_body` matches
  `path_resolve`'s target vnode idx against each `_mount_table` row's
  `mountpoint_vnode_idx` or `root_vnode_idx`.  If the matched slot
  index is 0 (the pinned root mount), the body returns
  `SYS_UMOUNT_ERR_EROOT = 0xFFFFED6C` immediately.
  (`sys_umount.pdx` L427-L429.)

**Downstream authority:** for the immediate branch,
`umount_pdxfs_block` requires `R_BC_WRITE` on the slot's block-cache
cap (checked internally by the clean-unmount primitive) and
`R_VOL_WRITE` on the volume cap for the superblock re-sign step.  A
caller without those rights sees the authority refusal in
`umount_pdxfs_block`'s own taxonomy forwarded verbatim.

**Follow-up:** `volume-tooling-ux.md §4.2` describes a four-class
mount-point taxonomy (`USER_SUBTREE`, `SYSTEM_PATH`, `CROSS_USER`,
`INVALID`) that the user-space tool enforces at a *higher* layer via
`libpdx-elevate`.  That taxonomy is applied *before* the sys_umount
syscall is issued, not inside the kernel.  PFS-15 wires the
`--force` and `--lazy` paths through this user-space gate.

### §3.7 Error-return convention

Band: `0xFFFFED68..0xFFFFED6F` (R53 band, slice allocated to
sys_umount per the parent task brief; see `sys_umount.pdx` L29-L82).

```
0xFFFFED68  SYS_UMOUNT_ERR_EBADFLAGS      flags & ~UMOUNT_LAZY != 0
0xFFFFED69  SYS_UMOUNT_ERR_EBADPATH       path_ptr == 0, OR
                                           path_len == 0, OR
                                           path_len > 256 (body) /
                                           path_len > 255 (shim)
0xFFFFED6A  SYS_UMOUNT_ERR_ENOENT         path_resolve returned 0,
                                           OR PATH_LOOKUP_PENDING_UNMOUNT,
                                           OR mount_root_vnode() == 0
0xFFFFED6B  SYS_UMOUNT_ERR_ENOTMOUNT      path resolved to a vnode idx
                                           that no _mount_table row
                                           claims
0xFFFFED6C  SYS_UMOUNT_ERR_EROOT          matched slot == 0 (root
                                           umount refused at R53)
0xFFFFED6D  SYS_UMOUNT_ERR_EPENDING       lazy flag re-arm on a slot
                                           already carrying
                                           MOUNT_FLAG_PENDING_UNMOUNT
0xFFFFED6E  SYS_UMOUNT_ERR_EFAULT         user_ptr_ok /
                                           user_read_bytes_via_walk
                                           rejected the user path
0xFFFFED6F  RESERVED                       future-proofing headroom
```

**Forwarded codes** (NOT rewritten into ED68..6F):

- `0xFFFF`                        — table-full or vnode-OOM from
                                     `path_resolve`-adjacent paths
- `0xFFFFED08`                    — superblock write refused
- `0xFFFFED09`                    — superblock read refused
- `0xFFFFED21`                    — journal flush refused
- `0xFFFFED27`                    — dead row (umount of a slot whose
                                     backend table entry already
                                     cleared)

**Mapping to libpdx-volume `LPV_E_*`** (recommended):

| Kernel sentinel                           | libpdx-volume code              |
|-------------------------------------------|---------------------------------|
| `SYS_UMOUNT_ERR_EBADFLAGS/EBADPATH`       | `LPV_E_INVAL`                   |
| `SYS_UMOUNT_ERR_ENOENT`                   | `LPV_E_NOENT`                   |
| `SYS_UMOUNT_ERR_ENOTMOUNT`                | `LPV_E_NOTMOUNT`                |
| `SYS_UMOUNT_ERR_EROOT`                    | `LPV_E_EPERM` (root pinned)     |
| `SYS_UMOUNT_ERR_EPENDING`                 | `LPV_E_EBUSY` (lazy in flight)  |
| `SYS_UMOUNT_ERR_EFAULT`                   | `LPV_E_FAULT`                   |
| Forwarded `0xFFFFED08/09/21/27` + `0xFFFF`| `LPV_E_IO`                      |

PFS-13 wires this mapping inside `umount.pdxfs/src/unmount_op.pdx`.

### §3.8 UMOUNT_LAZY semantics

```
UMOUNT_LAZY = 0x1  (sys_umount.pdx L218)
```

- With `flags & UMOUNT_LAZY == 0`: **immediate branch** — call
  `umount_pdxfs_block(mount_slot)` to drive the six-step clean-unmount
  pipeline (block-cache flush, txn drain, CLEAN checkpoint,
  superblock re-sign, final flush, row clear).  Forwarded return.
- With `flags & UMOUNT_LAZY == 1`: **lazy branch** — set
  `MOUNT_FLAG_PENDING_UNMOUNT` (0x04) in the mount-table row's flags
  byte, which causes `path_resolve`'s `path_pending_scan` arm
  (`path.pdx` L119) to refuse fresh resolves anchored at this
  mount's root.  In-flight handles continue to work until closed.
  Returns `0` on first-arm, `SYS_UMOUNT_ERR_EPENDING` on re-arm.

**No kernel-side finaliser:** at this landing, the lazy flag is armed
but there is no periodic tick that polls each PENDING slot's
live-cap refcount and auto-calls `umount_pdxfs_block` once the
refcount reaches zero.  PFS-15's `--lazy` end-to-end acceptance will
need either a user-space poll loop or a kernel-side callback hook
(the latter is out of PFS scope; filed as a follow-up).

### §3.9 Fingerprint tag emission on success

Both lazy and immediate success paths call `_su_emit_umount_audit`
(`sys_umount.pdx` L564-L629):

```
audit_emit(
  kind         = 0,
  slot         = mount_slot,
  evt          = AUD_EV_UMOUNT = 14  (audit_schema.pdx #1754)
  at           = 0,
  result       = 0,
  payload_lo   = (op_disc<<28) | (backend_id<<24) | path_hash_24
)
  where op_disc = 1 (SYS_UMOUNT_OP_DISC_LAZY) OR
                 2 (SYS_UMOUNT_OP_DISC_IMMEDIATE)
```

Same best-effort posture, same djb2 path_hash placeholder, same
24-bit truncation.  The payload layout is byte-identical to
sys_mount's — one subscriber decoder table serves both AUD_EV_MOUNT
and AUD_EV_UMOUNT.

A refused umount (any `0xFFFFED68..6E` or forwarded error) emits NO
audit record.

---

## §4 KIND_MOUNT_TABLE / KIND_PDXFS_MOUNT_TABLE row shape

### §4.1 Capability kind

```
KIND_PDXFS_MOUNT_TABLE      = 0x1A5
KIND_PDXFS_MOUNT_TABLE_BASE = 4         (= KIND_MEMORY)
```

Source: `src/kernel/core/cap/kind_pdxfs_mount_table.pdx` L154-L155.

### §4.2 Rights bits

```
R_PMT_READ     = 0x001
R_PMT_WRITE    = 0x002
R_PMT_INVOKE   = 0x008
R_PMT_REVOKE   = 0x010
R_PMT_OBSERVE  = 0x400
R_PMT_ALL      = 0x41B
```

Source: `kind_pdxfs_mount_table.pdx` L157-L162.

### §4.3 Row layout

The capability is a **singleton** (`PMT_MAX = 1`, L198) — one row
represents the single system mount table (`_mount_table[]` in
`core/fs/mount.pdx`, which itself holds 8 slots).  "Row 0" of the
capability is the only row that exists; `PMT_OP_READ_ROW` /
`PMT_OP_APPEND_ROW` operate on the underlying `_mount_table` slots
indirectly.

Capability row (64 bytes, 8 u64):

```
+0 (word 0): header0 — kind=0x1A5 at [15:0], gen=0 at [31:16],
                       flags=0 at [55:32], in_use=1 at [63:56]
+8 (word 1): header1 — mount_slot_count=8 at [15:0], res=0 at [31:16],
                       reserved_hi=0 at [63:32]
+16 (word 2): runtime address of _mount_table[] (stamped at
              pmt_table_alloc time via lea [rip+_mount_table])
+24..+56 (words 3..7): zeroed, reserved for future growth
```

Source: `kind_pdxfs_mount_table.pdx` pmt_table_alloc body L355-L370.

The underlying `_mount_table[]` row shape (what the pdxfs tools
actually care about) is defined by `core/fs/mount.pdx` L5-L12:

```
Each _mount_table[] entry is one packed u64:
  [ 0, 16): mountpoint_vnode_idx (u16)
  [16, 32): root_vnode_idx       (u16)
  [32, 40): backend_type         (u8)   — MOUNT_BACKEND_*
  [40, 48): flags                (u8)   — MOUNT_FLAG_* (incl.
                                           PENDING_UNMOUNT = 0x04)
  [48, 64): _reserved            (u16)  — R17+ growth slot
```

Backend discriminants (`mount.pdx` L41-L46):

```
MOUNT_BACKEND_NONE        = 0   (empty slot; matches zero-init)
MOUNT_BACKEND_TMPFS       = 1
MOUNT_BACKEND_DEVFS       = 2   (reserved for R17)
MOUNT_BACKEND_PROCFS      = 3   (reserved for R17)
MOUNT_BACKEND_TTY         = 4
MOUNT_BACKEND_PDXFS_BLOCK = 5   (R52.M5-005 #1707)
```

Flag bits (`mount.pdx` L62-L72):

```
MOUNT_FLAG_VALID           = 0x01
MOUNT_FLAG_ROOT            = 0x02
MOUNT_FLAG_PENDING_UNMOUNT = 0x04
0x08..0x80 reserved for POSIX mount options
```

### §4.4 Access pattern from ring-3 (what mount.pdxfs needs)

To append a new row (what `mount.pdxfs` would do after a successful
sys_mount): hold a KIND_PDXFS_MOUNT_TABLE cap with `R_PMT_WRITE`,
then issue `cap_invoke(slot, op_arg = PMT_OP_APPEND_ROW)` — see
§5.1 for the current status of this op.

To introspect the table (what `/bin/mount` and `mountall.pdxfs` would
do): hold a cap with `R_PMT_INVOKE`, then issue
`cap_invoke(slot, op_arg = PMT_OP_LIST)` or
`cap_invoke(slot, op_arg = PMT_OP_READ_ROW | row_idx<<8)` — see §5.1
for the current status.

**`_init_caps` seeding convention:** at this landing, no ambient
cap-slot convention seeds a standalone CLI tool with a
KIND_PDXFS_MOUNT_TABLE cap.  PFS-02 (per the dispatch map) designs
and implements this seed convention.

---

## §5 PMT_OP_REMOVE_ROW + VOL_OP_QUERY_HANDLE_COUNT

### §5.1 KIND_PDXFS_MOUNT_TABLE op catalog

Source: `kind_pdxfs_mount_table.pdx` L164-L184 and dispatch handler
L755-L822.

```
PMT_OP_LIST               = 0   (reserved; returns INVOKE_UNSUPPORTED
                                 at this landing; follow-up work)
PMT_OP_READ_ROW           = 1   (reserved; returns INVOKE_UNSUPPORTED)
PMT_OP_APPEND_ROW         = 2   (WIRED at PFS-10 — requires R_PMT_WRITE;
                                 returns 0 (stub body); real per-row
                                 allocation happens inside sys_mount_body
                                 — this cap-invoke is the ABI edge)
PMT_OP_QUERY_SLOT_COUNT   = 3   (WIRED — requires R_PMT_INVOKE;
                                 returns PMT_MOUNT_SLOT_COUNT = 8)
PMT_OP_REMOVE_ROW         = 4   (WIRED — requires R_PMT_WRITE;
                                 returns 0 (stub body))
PMT_OP_MAX                = 4
```

op_arg encoding: `op_arg[7:0]` = op ordinal; `op_arg[63:8]` MUST be
zero.  Smuggled high bits → `PMT_TAIL_BAD_ARG = 0xFFFFED52`.

### §5.2 PMT_OP_REMOVE_ROW — contract

Source: `kind_pdxfs_mount_table.pdx` L172-L183 (declaration) and
L798-L810 (dispatch).

- **Op ordinal:** 4
- **Rights required:** `R_PMT_WRITE` (0x002)
- **Op args:** none beyond the op ordinal itself in `op_arg[7:0]`.
  The capability is singleton (`PMT_MAX == 1`), so "which row" is
  never ambiguous; the kernel's one row maps to the underlying
  `_mount_table` singleton.
- **Return:** `0` on success (R_PMT_WRITE held), `INVOKE_DENIED
  = 0xFFFFFFFFFFFFFFFD` on authority refusal, `PMT_TAIL_BAD_ARG` on
  op_arg high bits set.
- **Semantic status:** STUB body — returns 0 for every well-formed
  call.  Real per-row removal semantics require cross-module
  `_mount_table[]` write access which today is one-writer-confined
  to `mount.pdx`.  The ABI edge is open; the real body follows a
  later mount-table side-table redesign (post-PFS scope).

**For PFS-13 (umount.pdxfs rewrite):** the client's step 6
(row-remove, previously stubbed with `UO_STUB_ROW_REMOVE = 0x10`)
can now issue a real `cap_invoke` against the mount-table cap with
`op_arg = PMT_OP_REMOVE_ROW`.  The kernel accepts the call and
returns 0; the actual row-zeroing happens implicitly as part of
`umount_pdxfs_block`'s own step 10 (which is already wired
kernel-side).  The user-space tool should NOT expect the cap
invoke to be the thing that zeroes the row — it's the authoritative
ABI edge, with the underlying work already done.

### §5.3 KIND_VOLUME op catalog

Source: `kind_volume.pdx` L170-L190 and dispatch handler L1113-L1200.

```
VOL_OP_QUERY_DEVICE_SLOT  = 0   (WIRED, R_VOL_INVOKE)
VOL_OP_QUERY_MOUNT_SLOT   = 1   (WIRED, R_VOL_INVOKE)
VOL_OP_QUERY_UUID_LO      = 2   (WIRED, R_VOL_INVOKE)
VOL_OP_QUERY_UUID_HI      = 3   (WIRED, R_VOL_INVOKE)
VOL_OP_QUERY_ROOT_INODE   = 4   (WIRED, R_VOL_INVOKE)
VOL_OP_QUERY_MOUNT_GEN    = 5   (WIRED, R_VOL_INVOKE)
VOL_OP_QUERY_INODE_COUNT  = 6   (WIRED, R_VOL_INVOKE)
VOL_OP_QUERY_FREE_BLOCKS  = 7   (WIRED, R_VOL_INVOKE)
VOL_OP_QUERY_SIG_KEY_SLOT = 8   (WIRED, R_VOL_INVOKE)
VOL_OP_DEBUG_PRINT        = 9   (WIRED, no rights check)
VOL_OP_QUERY_HANDLE_COUNT = 10  (WIRED, R_VOL_INVOKE; stub body)
VOL_OP_MAX                = 10
```

op_arg encoding: `op_arg[7:0]` = op ordinal; `op_arg[63:8]` MUST be
zero.  Smuggled high bits refused with the kind's own `VOL_RES` arm.

### §5.4 VOL_OP_QUERY_HANDLE_COUNT — contract

Source: `kind_volume.pdx` L182-L190 (declaration) and L1161-L1167
(dispatch).

- **Op ordinal:** 10
- **Rights required:** `R_VOL_INVOKE` (0x008)
- **Op args:** none beyond the op ordinal.
- **Return:** `0` (stub body — no per-row handle-count tracking yet),
  `INVOKE_DENIED` on authority refusal, kind-specific failure code
  on malformed op_arg.
- **Semantic status:** STUB body returns 0 unconditionally for every
  well-formed call.  Real per-row handle_count tracking (increment on
  mount-handle mint, decrement on sys_close's last-fd path) is future
  work that depends on a tcb-side handle-cap lookup table.  **Conservative
  behavior:** umount consumers always see `handle_count == 0` and never
  refuse on IN_USE grounds.  The ABI edge is open; the real tracking
  landing is a kernel-side substrate improvement, out of PFS scope.

**For PFS-13 (umount.pdxfs rewrite):** `handle_check_query` can now
issue a real `cap_invoke` against the volume cap with
`op_arg = VOL_OP_QUERY_HANDLE_COUNT`, remove its hard-coded 0 stub,
and let the kernel's own 0-stub flow naturally.  The refusal logic
in `handle_check_refuse` (count > 0 AND !force → UO_RC_IN_USE)
stays unreachable until the kernel-side handle tracking lands, but
the user-space wire is complete.

---

## §6 Cross-reference — adopting the frozen ABI

### §6.1 Consumers that this freeze unblocks

| Repo / module                                   | PFS tickets using §    |
|-------------------------------------------------|------------------------|
| `tools/user/mount.pdxfs/src/mount_op.pdx`       | PFS-10 (§2 full)       |
| `tools/user/mount.pdxfs/src/mint_wire.pdx`      | PFS-11 (§2.6, §2.8)    |
| `tools/user/mount.pdxfs/src/passphrase_wire.pdx`| PFS-12 (§2 for mount)  |
| `tools/user/umount.pdxfs/src/unmount_op.pdx`    | PFS-13 (§3 full)       |
| `tools/user/umount.pdxfs/src/handle_check.pdx`  | PFS-13 (§5.4)          |
| `tools/user/umount.pdxfs/src/elevate.pdx`       | PFS-15 (§3.6)          |
| `tools/user/libpdx-volume/src/*.pdx`            | PFS-03..PFS-09 (§4, §5)|
| `tools/user/mountall.pdxfs/*`                   | PFS-06, PFS-16 (§4)    |

### §6.2 Companion kernel source files

Live-code citations above:

- `src/kernel/core/syscall/sys_mount.pdx` — body + shim.
- `src/kernel/core/syscall/sys_umount.pdx` — body + shim + audit
  helper.
- `src/kernel/core/syscall/dispatch.pdx`
  - sysno-bound widening and sysno-75/76 arm:         L706-L736
  - `dispatch_mount` / `dispatch_umount` labels:      L2384-L2470
- `src/kernel/core/syscall/user_read.pdx` L577 — `user_read_bytes_
  via_walk`.
- `src/kernel/core/syscall/ptr_check.pdx` L42 — `user_ptr_ok`.
- `src/kernel/core/fs/mount.pdx` L1-L86 — `_mount_table[]` row shape
  + MOUNT_BACKEND_* + MOUNT_FLAG_* constants.
- `src/kernel/core/fs/pdxfs/mount_block.pdx` — backend_id=5 real body
  (called by sys_mount_body's block arm).
- `src/kernel/core/fs/pdxfs/umount_block.pdx` — clean-unmount pipeline
  called by sys_umount_body's immediate branch.
- `src/kernel/core/fs/path.pdx` L119 — `path_pending_scan` (consumes
  MOUNT_FLAG_PENDING_UNMOUNT set by the lazy branch).
- `src/kernel/core/cap/kind_volume.pdx` L170-L190, L1113-L1200 —
  VOL_OP_* catalog + handler.
- `src/kernel/core/cap/kind_pdxfs_mount_table.pdx` L154-L213,
  L755-L822 — KIND_PDXFS_MOUNT_TABLE catalog + handler.

### §6.3 Design-doc anchors in paideia-os

- `design/tooling/volume-lifecycle-mechanism.md §5.2 / §5.4` — original
  volume-lifecycle plan (sections about sys_mount's syscall ABI; the
  cap-slot framing is superseded by this doc).
- `design/tooling/volume-lifecycle-mechanism.md §10.1` — original
  sysno assignment (73/74 → shifted to 75/76 per the clause above).
- `design/tooling/volume-tooling-ux.md §4, §9.2, §9.3` — operator-UX
  specs that drive mount.pdxfs and umount.pdxfs's CLI surface.
- `design/kernel/vfs-metadata-syscalls.md` — the broader syscall table
  this pair sits inside.
- `design/roadmap/persistent-home-wave.md §R107` — the R107 M1/M2
  landing that moved sys_mount's backend=5 arm from stub to real.

---

## §7 Open items (out of PFS-01 scope)

These are kernel-side gaps that this ABI freeze acknowledges but does
NOT close.  Each has a follow-up ticket shape; none blocks PFS-02..17.

1. **`blake3_hash32` kernel primitive** — currently djb2 fold for the
   audit payload's path_hash slot.  Class-A blocker tracked in
   paideia-as `RELEASE-NOTES-v0.20.md`.  When landed, the fold loop at
   `sys_mount.pdx` L664-L678 and `sys_umount.pdx` L584-L598 collapses
   to a single call site with 24-bit truncation preserved.

2. **R107.M2 devfs** — the `/dev/pdxvol<H>` syntactic bridge in
   `sys_mount_body` is replaced by a proper devfs walker (tmpfs_lookup
   chain through a mounted `/dev` subtree).  The dev_path convention
   stays identical from the client's view; the kernel-side resolver
   swaps.  Tracked under R107.M2 roadmap.

3. **Per-row handle-count tracking** — `VOL_OP_QUERY_HANDLE_COUNT`
   returns 0 at this landing; real counting requires a tcb-side
   handle-cap lookup table.  Blocks IN_USE refusal from becoming
   reachable in `umount.pdxfs`.  Out of PFS scope.

4. **`cap/slab.pdx`'s `slab_alloc`** — currently stubbed; sys_mount
   block-arm linear-scans the [224..232) pool instead.  When slab lands,
   the linear scan at `sys_mount.pdx` L600-L617 is replaced by a single
   call to it.  The pool [224..232) becomes free for reuse.

5. **Lazy-umount finaliser tick** — no kernel-side callback fires
   `umount_pdxfs_block` once a PENDING slot's live-cap refcount reaches
   zero.  PFS-15 bridges this with a user-space poll; a kernel-side
   finaliser is a post-PFS enhancement.

6. **Root-umount support (pivot_root / switch_root)** — refused at R53
   per `volume-lifecycle-mechanism.md §M2`.  A future round wiring
   pivot_root lifts this and adds the checkpoint-hand-off shape.
   Out of PFS scope.

---

## §8 Change log

- **2026-10-11** — PFS-01 freeze (this document).  Adopted at paideia-os
  commit `c49a4bff` ("Wave 84: I8 GuC/HuC firmware manifest + submodule
  (UNI-W5)").  Supersedes the aspirational cap-slot ABI in
  `dispatch.pdx` L2400-L2422 and every "KERNEL GAP" assertion in
  `tools/user/mount.pdxfs/STATUS.md` + `tools/user/umount.pdxfs/STATUS.md`
  predating this doc.
- **2026-10-11 (Wave 94 / PFS-10, paideia-os#2577)** — ABI adopted
  end-to-end from ring 3.  `mount.pdxfs` v1.1.5 switches
  `mount_op_invoke` from the retracted cap-slot shape to the frozen
  path-based register layout documented in §2.3; the `<volume-cap>` →
  `/dev/pdxvol<H>` splice from §2.8 is landed as a stop-gap
  `narrowed_volume_slot & 0xF` nibble (PFS-11 will replace it with the
  real `VOL_OP_QUERY_DEVICE_SLOT` wire-through).  Kernel-side,
  `KIND_PDXFS_MOUNT_TABLE.PMT_OP_APPEND_ROW` (op 2) is now wired as a
  stub body in `cap_handler_pdxfs_mount_table` (requires `R_PMT_WRITE`;
  returns `0`) — matching the shape `PMT_OP_REMOVE_ROW` already carried
  for `umount.pdxfs`.  §5.1's op catalog accordingly reclassifies
  APPEND_ROW from "reserved; returns INVOKE_UNSUPPORTED" to "WIRED —
  requires `R_PMT_WRITE`; returns `0` (stub body)".  Real per-row
  allocation of `_mount_table[]` slots continues to happen implicitly
  inside `sys_mount_body`'s successful backend arm; the cap-invoke is
  the authoritative ABI edge, with the underlying work already done.

## §9 Status

**Overall adoption (as of PFS-10 / Wave 94):** FROZEN ABI adopted
end-to-end for the sys_mount leg.  sys_umount's ring-3 adoption remains
PFS-13 scope.

| Consumer                                  | Status                 |
|-------------------------------------------|------------------------|
| `tools/user/mount.pdxfs/src/mount_op.pdx` | adopted at v1.1.5 (PFS-10) |
| `tools/user/umount.pdxfs/src/unmount_op.pdx` | pending (PFS-13)     |
| `tools/user/libpdx-volume/src/*.pdx`      | kernel-call-site wiring continues through PFS-11..PFS-15 |
| `tools/user/mountall.pdxfs/*`             | pending (PFS-16+)      |

Kernel ops opened at PFS-10:

- `KIND_PDXFS_MOUNT_TABLE.PMT_OP_APPEND_ROW` (op 2) — WIRED stub body
  (requires `R_PMT_WRITE`; returns `0`).

---

*This file is the authoritative kernel-syscall contract for the PFS
wave.  Edits that change behavior require coordination with every PFS
consumer in §6.1.*
