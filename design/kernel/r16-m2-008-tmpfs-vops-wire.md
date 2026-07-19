---
issue: 586
milestone: R16.M2 (tmpfs — in-memory VFS backend)
subsystem: 12 — tmpfs
topic: tmpfs vops table + inode-idx adapter wrappers (R16-M2-008)
freeze-discipline: strict
  - The vops table layout is frozen by R16-M1-003 (#572); this issue does
    not change offsets, sizes, or return conventions — it materialises a
    concrete `[u64; 7]` at `_tmpfs_vops` and populates 5 real slots + 2
    stubs. Every downstream vnode of tmpfs backend type carries a pointer
    to this shared table in its `ops_ptr` slot (vnode +24).
  - vnode.backend_ptr (frozen at +32 by #570, `VNODE_BACKEND_PTR_OFFSET`)
    is the sole channel through which the adapters recover the tmpfs
    inode identity from a vnode pointer. Per vfs-layout.md §3 row 8, the
    backend-owned semantics of that slot are the backend's choice; this
    issue pins them for tmpfs as **"low 16 bits hold `inode_idx`; upper
    bits reserved zero at R16.M2, reserved for future generation-count
    tagging."**
  - This backend_ptr contract is a strict-freeze event for tmpfs: every
    tmpfs vnode ever produced by any code path (R16.M3 `sys_open`,
    R17 shell demo, R19 devfs-style views of tmpfs) MUST publish
    `inode_idx` into the low 16 bits of backend_ptr before the vnode's
    type is set to a non-FREE value. This mirrors the ops_ptr
    set-before-type-published invariant already frozen by
    vfs-layout.md §7.5.
  - Adapters take the "index-in-backend_ptr" form (Option 2 from the
    #586 planning note) not the "pointer-to-inode-in-backend_ptr" form
    (Option 1). Rationale is §6.1: an idx-form backend_ptr survives inode
    pool relocation (never happens, but conceptually cleaner), keeps the
    adapter arithmetic to a single `and rax, 0xFFFF` (no subtraction or
    shift), and lets a future generation counter share the same 64-bit
    slot in the high 48 bits without changing any adapter.
  - `open` and `close` slots carry stub function pointers, not null. This
    is a **substantive** choice (§6.2): a null slot returns
    `VOPS_ERR_NOT_SUPPORTED` per #572 §2.1, which would surface as
    `sys_open` failing on every tmpfs path at R16.M3+. Real tmpfs has
    no per-open state to initialise or teardown at R16.M2 — the stubs
    just return 0 (success). The stubs live in `tmpfs/vops.pdx` next
    to the adapters and are conceptually the tmpfs "open/close is a
    no-op" primitive.
blocks:
  - "R16.M3 fd table + vfs_open/vfs_read/vfs_write integration —
    depends on the backend_ptr low-16-bits-hold-inode-idx contract
    frozen here for tmpfs vnode publication."
  - "R17 `sys_open`, `sys_read`, `sys_write`, `sys_close`,
    `sys_unlink`, `sys_create` — user-facing entry points that will
    dispatch through the vops table populated here."
  - "R17 tmpfs mount-point installation — the code path that
    materialises the tmpfs root vnode (`ops_ptr = &_tmpfs_vops`,
    `backend_ptr = TMPFS_INODE_IDX_ROOT`)."
touching:
  - src/kernel/core/fs/tmpfs/vops.pdx           (new module — table + adapters + stubs + init; ~200 LOC)
  - src/kernel/boot/kernel_main.pdx             (call `tmpfs_vops_init` + witness block ~110 LOC)
  - tools/boot_stub.S                           (2 message strings; ~10 LOC)
  - tests/r14b/expected-boot-r14b-loader.txt    (marker: "R16 TMPFS VOPS OK")
  - tests/r15/expected-boot-r15-ring3.txt       (marker)
  - tests/r15/expected-boot-r15-process.txt     (marker)
  - design/kernel/r16-m2-008-tmpfs-vops-wire.md (this doc)
related:
  - design/kernel/r16-m1-003-vops.md            (#572 — vops table layout
    freeze §2, dispatch discipline §3, null-slot semantics §2.1. This
    issue populates the concrete table whose shape #572 pinned; all
    offset immediates re-use the exported constants from
    `src/kernel/core/fs/vops.pdx`.)
  - design/kernel/vfs-layout.md                 (#570 — VNODE_OPS_PTR_OFFSET
    at +24, VNODE_BACKEND_PTR_OFFSET at +32. §7.5's ops_ptr-set-before-
    type-published invariant extends here to backend_ptr for the tmpfs
    idx contract.)
  - design/kernel/r16-m2-001-tmpfs-inode-pool.md (#579 — the inode pool
    into which the adapters funnel the caller. The adapters do NOT
    validate idx; they trust the vnode-publication invariant.)
  - design/kernel/r16-m2-003-tmpfs-lookup.md    (#581 — the primitive
    reached through the `lookup` slot. Adapter drops `rsi` (name_ptr)
    unchanged; forwards `rdi = idx` extracted from vnode.backend_ptr.)
  - design/kernel/r16-m2-004-tmpfs-create.md    (#582 — the primitive
    reached through the `create` slot. Adapter maps vops's 3-arg
    `(dir_vn, name, mode)` to primitive's 4-arg `(dir_idx, name,
    name_len, type)` per §4.4.)
  - design/kernel/r16-m2-005-tmpfs-write.md     (#583 — the primitive
    reached through the `write` slot. Adapter forwards buf/len/off
    unchanged.)
  - design/kernel/r16-m2-006-tmpfs-read.md      (#584 — the primitive
    reached through the `read` slot. Same forwarding shape as write.)
  - design/kernel/r16-m2-007-tmpfs-unlink.md    (#585 — the primitive
    reached through the `unlink` slot. Same shape as lookup.)
  - design/milestones/r14b-tactical-plan.md     §Subsystem 12 item 8 —
    "Populate `_tmpfs_vops` with pointers to the above." R16.M2 close
    condition; R16.M3 dispatch integration is the immediate successor.
---

# R16-M2-008 — tmpfs vops table wire-up + adapter wrappers (#586)

## 1. Scope

Materialise the concrete `_tmpfs_vops : [u64; 7]` shared function-pointer
table for the tmpfs backend, and ship the thin adapter wrappers that
bridge the two-signature gap between:

- **The frozen vops shape (#572 §2):** every op takes a `vnode_ptr`
  in `rdi`.
- **The tmpfs primitives (R16-M2-003..007):** every op takes an
  `inode_idx` (u16 in low 16 bits of `rdi`).

The bridge is one dedicated adapter per real op — 5 adapters total
(`_tmpfs_read_adapter`, `_tmpfs_write_adapter`, `_tmpfs_lookup_adapter`,
`_tmpfs_create_adapter`, `_tmpfs_unlink_adapter`) — plus two "no-op"
stubs for `open` and `close` (which tmpfs backs with no per-open
state at R16.M2). Every adapter is a 4-to-6-instruction leaf that
recovers `inode_idx` from `vnode.backend_ptr` (frozen at +32 by #570)
and tail-shape-transforms the argument set to what the tmpfs primitive
expects.

Out of scope (deliberately deferred to R16.M3+):

- **Real vnode publication for tmpfs.** No code path in this issue
  produces a live tmpfs vnode with `ops_ptr = &_tmpfs_vops` and
  `backend_ptr = inode_idx`. That's the R16.M3 mount-point + fd-table
  integration issue. The R16.M2 witness therefore verifies the table
  by pointer identity (§5.1), not by an end-to-end vfs dispatch.
- **Mode → type translation.** The `create` adapter forwards `rdx`
  (mode) directly to tmpfs_create as `type`. At R16.M2 the caller (the
  witness) supplies a raw `VNODE_TYPE_*` constant. R16.M3+ layers mode
  bits over this via a `mode_to_type` helper that lives with the
  syscall boundary, not the adapter.
- **name_len derivation.** The `lookup` / `create` / `unlink` primitives
  already treat the name as NUL-terminated up to 32 bytes; the adapters
  pass `name_len = 32` (the max) into `create`, letting the primitive's
  own cap-at-31-and-NUL logic handle string termination. Real strnlen
  lives with the syscall boundary at R17.
- **Refcount bump on lookup/create returns.** Vops's return convention
  is a bare u16 idx; the caller manages refcount discipline. Adapters
  are pass-through on `rax` — the primitive's return goes back through
  the dispatcher untouched.

## 2. `_tmpfs_vops` table layout — concrete population

The table is a `[u64; 7]` allocated in `.bss` with `@align(8)`. All
7 slots are populated at boot by `tmpfs_vops_init` (§4). The pattern
mirrors the witness table used by #572 §5, but with real primitives
instead of the magic-constant stub.

| Offset (const)             | Slot | Vops op   | Points to                    | Backing primitive                                                |
|----------------------------|------|-----------|------------------------------|------------------------------------------------------------------|
| `VOPS_READ_OFFSET`   (+0)  | 0    | `read`    | `_tmpfs_read_adapter`        | `tmpfs_read(idx, buf, len, off)`         (R16-M2-006, #584)      |
| `VOPS_WRITE_OFFSET`  (+8)  | 1    | `write`   | `_tmpfs_write_adapter`       | `tmpfs_write(idx, buf, len, off)`        (R16-M2-005, #583)      |
| `VOPS_OPEN_OFFSET`   (+16) | 2    | `open`    | `_tmpfs_open_stub`           | none — stub returns 0                                            |
| `VOPS_CLOSE_OFFSET`  (+24) | 3    | `close`   | `_tmpfs_close_stub`          | none — stub returns 0                                            |
| `VOPS_LOOKUP_OFFSET` (+32) | 4    | `lookup`  | `_tmpfs_lookup_adapter`      | `tmpfs_lookup(dir_idx, name)`            (R16-M2-003, #581)      |
| `VOPS_CREATE_OFFSET` (+40) | 5    | `create`  | `_tmpfs_create_adapter`      | `tmpfs_create(dir_idx, name, len, type)` (R16-M2-004, #582)      |
| `VOPS_UNLINK_OFFSET` (+48) | 6    | `unlink`  | `_tmpfs_unlink_adapter`      | `tmpfs_unlink(dir_idx, name)`            (R16-M2-007, #585)      |

**All offset immediates in `tmpfs_vops_init` are the exported constants
from `src/kernel/core/fs/vops.pdx`** — this module does NOT hard-code
`0, 8, 16, 24, 32, 40, 48`. That coupling flows through the single
source of truth pinned by #572 §4.

## 3. Adapter wrapper design — index-in-backend_ptr form

### 3.1 backend_ptr encoding contract for tmpfs (frozen here)

For every tmpfs vnode (any code path, any time, R16.M3 onward), the
publication invariant is:

```
vnode.backend_ptr @+32  =  inode_idx & 0xFFFF   ; bits [0, 16)
                            0                    ; bits [16, 64) reserved
```

Bits [16, 64) are reserved for a future generation counter (a
lookup-safety mechanism to detect stale-vnode use across close-then-
reopen races at R17 concurrency). At R16.M2 the reservation is
soft — the adapters mask with `and rax, 0xFFFF`, so any bits set in
[16, 64) are silently discarded. R17 will formalise the generation
tag; the mask stays the same.

**Rationale for storing an index instead of a pointer.** The two
options considered were:

- **Option 1 — pointer form.** `backend_ptr = &_tmpfs_inode_pool[idx]`.
  Adapter body: `mov rdi, [rdi + 32]` (one load, no arithmetic).
  Downside: any pointer form implies the primitive takes a
  `inode_ptr` not a `inode_idx` — but every landed primitive
  (`tmpfs_read`, `tmpfs_write`, `tmpfs_lookup`, ...) takes idx.
  Adapting via `(ptr - &_tmpfs_inode_pool) >> 8` reconstructs idx
  at every call — 3 extra instructions per adapter.
- **Option 2 — idx form** (chosen). `backend_ptr = idx` (in low
  16 bits). Adapter body: `mov rdi, [rdi + 32]; and rdi, 0xFFFF`
  (two instructions). Downside: none for R16 — primitives already
  take idx.

Option 2 wins on:
- Adapter is 1 instruction shorter per call (2 vs 3).
- Primitives stay idx-native; no signature churn.
- Generation-tag reservation composes with the mask trivially at R17.

The pointer form's only virtue — "the adapter body is one instruction
shorter if the primitive is rebuilt to take a pointer" — costs a
1-mile refactor of 5 primitives to save 1 mile of adapter code.
Rejected on the wrong side of the ratio.

### 3.2 Adapter shape — uniform leaf, 4 to 6 instructions

Every adapter is a **leaf function** — no callee-save prologue, no
nested call after the primitive tail-call... except we cannot
tail-call yet (`jmp reg64` is not encoder-supported per #572 §2.4).
Every adapter is therefore a `call` + `ret`, which makes it a
non-leaf under SysV. That means it needs the same 8-byte
alignment pad around `call` that the vops dispatcher itself has
(#572 §3.2 verify-pass correction).

Simplification: **use direct `call` (not indirect).** The primitive
symbol is known at assembly time — no need to go through `rax`.
This drops the `mov rax, [table + N]` step that the vops dispatcher
must do. The adapter body is:

```asm
; _tmpfs_read_adapter(vn=rdi, buf=rsi, len=rdx, off=rcx) -> rax
mov  rdi, [rdi + 32]         ; load vnode.backend_ptr
and  rdi, 0xFFFF             ; mask to inode_idx (bits [0,16))
; rsi/rdx/rcx pass through untouched
sub  rsp, 8                  ; SysV alignment pad around nested call
call tmpfs_read              ; direct call — primitive symbol
add  rsp, 8                  ; undo pad
ret
```

**7 instructions total.** Shape is identical across the 4-arg
adapters (read, write). 2-arg adapters (lookup, unlink) skip the
"rsi/rdx/rcx pass-through" comment — rsi still passes; rdx/rcx are
whatever the caller left, safely ignored by the primitive.

The `create` adapter is one instruction longer — it must inject
`name_len = 32` into rdx and shuffle mode (rdx) into rcx (§4.4).

The 2 stubs are 2-instruction leaves — `xor eax, eax; ret`.

### 3.3 Alignment discipline recap

Every adapter makes a nested `call`, so it is not a SysV leaf even
though it has no prologue. The `sub rsp, 8; call ...; add rsp, 8`
pattern is inherited from #572 §3.2 verbatim — same rationale, same
byte count, same idiom already used by every vops dispatcher in
`src/kernel/core/fs/vops.pdx`.

No callee-save register is touched by any adapter. `rax` is scratch
(mostly unused pre-`call`; the primitive fills it with the return
value). `rdi/rsi/rdx/rcx` are the arg-passing regs — the adapter
either passes them through unchanged or rewrites them once.

## 4. Per-adapter contract table

### 4.1 `_tmpfs_read_adapter` — 4-arg pass-through

```
vops signature:  read(vn, buf, len, off)
                 rdi=vn,  rsi=buf, rdx=len, rcx=off
prim signature:  tmpfs_read(idx, buf, len, off)
                 rdi=idx, rsi=buf, rdx=len, rcx=off

Adapter body:
    mov  rdi, [rdi + 32]      ; backend_ptr
    and  rdi, 0xFFFF          ; low 16 bits = idx
    sub  rsp, 8
    call tmpfs_read
    add  rsp, 8
    ret
```

### 4.2 `_tmpfs_write_adapter` — 4-arg pass-through

Identical shape to §4.1 with `call tmpfs_write`.

### 4.3 `_tmpfs_lookup_adapter` — 2-arg pass-through

```
vops signature:  lookup(dir_vn, name_ptr)
                 rdi=dir_vn, rsi=name_ptr
prim signature:  tmpfs_lookup(dir_idx, name_ptr)
                 rdi=dir_idx, rsi=name_ptr

Adapter body:
    mov  rdi, [rdi + 32]
    and  rdi, 0xFFFF
    sub  rsp, 8
    call tmpfs_lookup
    add  rsp, 8
    ret
```

### 4.4 `_tmpfs_create_adapter` — arg-shape transform

```
vops signature:  create(dir_vn, name_ptr, mode)
                 rdi=dir_vn, rsi=name_ptr, rdx=mode
prim signature:  tmpfs_create(dir_idx, name_ptr, name_len, type_)
                 rdi=dir_idx, rsi=name_ptr, rdx=name_len, rcx=type

Adapter body:
    mov  rdi, [rdi + 32]
    and  rdi, 0xFFFF          ; rdi = dir_idx
    mov  rcx, rdx             ; rcx = mode (becomes type for R16.M2)
    mov  rdx, 32              ; rdx = name_len = TMPFS_INODE_NAME_MAX
    sub  rsp, 8
    call tmpfs_create
    add  rsp, 8
    ret
```

The **argument transform** for create:

- **vops `mode` (rdx) → primitive `type` (rcx).** At R16.M2 the
  caller (witness) supplies a raw `VNODE_TYPE_*` constant (1=REG,
  2=DIR); the adapter forwards it as-is. R17 grows a mode→type
  helper at the syscall boundary; the adapter's contract stays
  "forward whatever `mode` bits arrive."
- **primitive `name_len` (rdx) = 32.** The primitive's own name
  loop (create.pdx §4.5, lines 103-114) terminates on
  `counter == name_len` OR `counter == 31`. Passing 32 lets the
  cap-at-31 branch win, giving effective "up to 31 bytes then NUL"
  behaviour — the same shape a strnlen-driven adapter would produce
  for any name shorter than 32 bytes. The extra byte cost is zero
  (the primitive already writes NUL at the cursor after the loop).

**Instruction count: 9** (2 for idx extract, 2 for arg shuffle,
sub/call/add/ret is 4, alignment pad accounts for 1) — one longer
than the shape-preserving adapters, still leaf-shaped.

### 4.5 `_tmpfs_unlink_adapter` — 2-arg pass-through

Identical shape to §4.3 with `call tmpfs_unlink`.

### 4.6 `_tmpfs_open_stub` — success no-op

```
vops signature:  open(vn, flags)
                 rdi=vn, rsi=flags
Adapter body:
    xor  eax, eax             ; return 0 (success)
    ret
```

**2 instructions.** No arg touched, no side effect. Rationale
(§6.2): tmpfs has no per-open state; every real open on a tmpfs
file/dir succeeds trivially. Null slot would return E_NOT_SUPPORTED
(#572 §2.1), which would make vfs_open unusable for tmpfs at
R16.M3+ — a substantive behaviour bug the stub prevents.

### 4.7 `_tmpfs_close_stub` — success no-op

```
vops signature:  close(vn)
                 rdi=vn
Adapter body:
    xor  eax, eax             ; return 0 (success)
    ret
```

Same shape and rationale as §4.6.

## 5. `tmpfs_vops_init` — table populator

Single boot-time populator. Called from `kernel_main` once, before any
consumer of the table exists. Idempotent — safe to call twice.

```
tmpfs_vops_init() -> u64
    Storage: _tmpfs_vops : [u64; 7] at .bss @align(8)
    Contract: populate all 7 slots from the layout in §2. Return 0.
```

Register discipline: leaf function, no callee-save. Uses `rax`, `r8`
as scratch. Ends with `xor eax, eax; ret`.

Body sketch:

```asm
; Compute base address once, then store each pointer at its offset.
lea  r8, [rip + _tmpfs_vops]

lea  rax, [rip + _tmpfs_read_adapter]
mov  [r8 + 0], rax                     ; VOPS_READ_OFFSET

lea  rax, [rip + _tmpfs_write_adapter]
mov  [r8 + 8], rax                     ; VOPS_WRITE_OFFSET

lea  rax, [rip + _tmpfs_open_stub]
mov  [r8 + 16], rax                    ; VOPS_OPEN_OFFSET

lea  rax, [rip + _tmpfs_close_stub]
mov  [r8 + 24], rax                    ; VOPS_CLOSE_OFFSET

lea  rax, [rip + _tmpfs_lookup_adapter]
mov  [r8 + 32], rax                    ; VOPS_LOOKUP_OFFSET

lea  rax, [rip + _tmpfs_create_adapter]
mov  [r8 + 40], rax                    ; VOPS_CREATE_OFFSET

lea  rax, [rip + _tmpfs_unlink_adapter]
mov  [r8 + 48], rax                    ; VOPS_UNLINK_OFFSET

xor  eax, eax
ret
```

Instruction count: 16 (7 × 2 for lea+mov, plus lea r8, xor eax, ret).
All patterns proven (`lea rip+sym`, `mov [reg + disp], reg` — already
in vnode_pool.pdx:133-138, tmpfs/inode.pdx:56).

**Integration point.** `kernel_main.pdx` inserts `call tmpfs_vops_init`
between the R16-M2-002 tmpfs_init witness and the R16-M2-008 vops
witness. `tmpfs_init` is NOT modified — this preserves the
byte-identical fingerprint of every prior R16.M2 witness.

## 6. Alternatives considered (rejected)

### 6.1 Pointer form for backend_ptr (§3.1 Option 1)

**Proposal.** Store `&_tmpfs_inode_pool[idx]` in `backend_ptr` so the
adapter is a single `mov rdi, [rdi + 32]` load.

**Rejected.** Every landed tmpfs primitive takes `inode_idx`. Storing
a pointer forces the adapter to reconstruct idx via
`(ptr - &_tmpfs_inode_pool) >> 8` (3 extra instructions per adapter)
OR forces all 5 primitives to be rewritten to take pointers (~200
LOC of churn to save ~15 LOC of adapter). The 1:15 ratio is on the
wrong side. Also loses the "high 48 bits reservable for generation
tag" property (§3.1) — a pointer needs all 48-64 bits.

### 6.2 Null slots for `open` and `close`

**Proposal.** Leave slots +16 (open) and +24 (close) as null. The vops
dispatcher already returns `VOPS_ERR_NOT_SUPPORTED` for null slots
(#572 §2.1), which the caller can interpret as "no-op."

**Rejected.** `VOPS_ERR_NOT_SUPPORTED` is `-1` semantically — an error
sentinel, not a success indicator. Downstream at R16.M3, `sys_open`
will call `vops_open` and check for `-1` as "operation failed" — a
tmpfs file that trivially supports open would then fail sys_open.
The fix at R16.M3 would be either (a) special-casing null slots as
success at every call site (viral through the syscall layer) or
(b) providing stubs here. The stubs cost 4 instructions total and
localise the "tmpfs has no per-open state" fact to one place.

### 6.3 Adapters embedded inline in primitives (no wrapper functions)

**Proposal.** Extend every primitive to take a `vnode_ptr` as `rdi`,
extract idx internally. No separate adapter functions; `_tmpfs_vops`
points directly at primitives.

**Rejected.** Contaminates 5 primitives with vnode awareness, coupling
them to the R16 vnode layout. R17+ might use tmpfs primitives from
non-vnode call sites (test harnesses, kernel internal code paths);
those callers should not have to construct a fake vnode. Adapters
keep the primitives pure — they know only about the inode pool.
Also matches the design contract from #586's planning note ("choose
Option 2 — adapter wrappers. Otherwise tmpfs functions become
vnode-aware and lose independence.").

### 6.4 Tail-call adapters via `jmp reg64`

**Proposal.** Save one stack frame per adapter dispatch by
tail-calling the primitive: `mov rax, sym; jmp rax`.

**Rejected.** The paideia-as encoder does not yet support `jmp reg64`
(#572 §2.4 confirms this). Rewriting is a re-encoder pass when
that lands. Direct `call sym; ret` is 2 instructions and idempotent
under future encoder growth — the adapter can be trivially recut
to `jmp sym` (direct near-jmp is already supported) or `jmp rax`
when reg-form lands.

### 6.5 `mode → type` translation at the adapter

**Proposal.** The vops signature uses POSIX-shaped `mode`
(`S_IFREG | 0644`). The adapter should decode the top bits into
`VNODE_TYPE_REG` etc. before calling `tmpfs_create`.

**Rejected for R16.M2.** No R16.M2 caller supplies a POSIX mode —
the witness (and R16.M3 fd table sub-tests) will pass raw
`VNODE_TYPE_*` values. Mode → type is a syscall-layer concern
that lands with `sys_create` at R17. Doing it in the adapter now
means either (a) inventing a mode-decode helper that no caller
needs OR (b) picking a mode-bit convention that R17 might revise.
The adapter's contract is "forward whatever mode bits the caller
provides; the caller owns the encoding."

### 6.6 `_tmpfs_vops` in `.rodata` with static initializer

**Proposal.** Declare the table with an initializer that pins each
slot to the correct adapter symbol at link time. No `tmpfs_vops_init`
runtime populator needed.

**Rejected.** paideia-as does not (yet) resolve symbol addresses
into static initializers of `[u64; N]` arrays — the ergonomic
`= [&fn_a, &fn_b, ...]` form is not the encoder's shape at
R16.M2. The runtime populator is 16 instructions of proven idioms
(`lea rip+sym`, `mov [reg + disp], reg`) and needs no encoder growth.
When the paideia-as syntax for symbol-in-initializer lands, this
whole populator collapses to a one-line static — the boot call
in kernel_main disappears with it, and no other file changes.
Deferred to a follow-on issue in the paideia-as backlog.

## 7. Witness — R16 TMPFS VOPS OK

The witness runs in `kernel_main` immediately after the R16-M2-007
tmpfs_unlink witness (line 2705 area). It inherits the
inode-pool + root+/tmp state from prior R16.M2 witnesses, but does
not depend on any pool state — the checks are pointer-identity only.

### 7.1 Preamble: populate the table

```asm
call tmpfs_vops_init                    ; populates 7 slots
```

This is the ONLY new call the witness introduces to kernel_main
beyond the 7 sub-tests below.

### 7.2 Sub-tests A-G: pointer identity per slot

Uniform shape per slot: load slot's u64, `lea` the expected adapter
address, compare, branch to fail on mismatch.

```asm
; Sub-test A: read slot
lea  rax, [rip + _tmpfs_vops]
mov  rcx, [rax + 0]                     ; VOPS_READ_OFFSET
lea  rdx, [rip + _tmpfs_read_adapter]
cmp  rcx, rdx
jne  tmpfs_vops_witness_fail

; Sub-test B: write slot   (offset +8,  &_tmpfs_write_adapter)
; Sub-test C: open slot    (offset +16, &_tmpfs_open_stub)
; Sub-test D: close slot   (offset +24, &_tmpfs_close_stub)
; Sub-test E: lookup slot  (offset +32, &_tmpfs_lookup_adapter)
; Sub-test F: create slot  (offset +40, &_tmpfs_create_adapter)
; Sub-test G: unlink slot  (offset +48, &_tmpfs_unlink_adapter)
```

Each sub-test is ~4 instructions. Seven sub-tests → ~28 instructions
of witness body.

### 7.3 Sub-test H (optional, high-value): end-to-end via `vops_lookup`

Materialise a **scratch vnode** on the stack (32 bytes suffice for the
head half — the dispatcher only touches +24 for ops_ptr and the
adapter only touches +32 for backend_ptr):

```asm
sub  rsp, 64                            ; scratch vnode (64 B = VNODE_SIZE)
mov  rax, rsp
xor  rcx, rcx
mov  [rax + 0], rcx                     ; zero head half (type=FREE, ...)
mov  [rax + 8], rcx
mov  [rax + 16], rcx
lea  rcx, [rip + _tmpfs_vops]
mov  [rax + 24], rcx                    ; ops_ptr = &_tmpfs_vops
mov  rcx, 1                             ; TMPFS_INODE_IDX_ROOT
mov  [rax + 32], rcx                    ; backend_ptr = root_idx (low 16 bits)
xor  rcx, rcx
mov  [rax + 40], rcx                    ; zero cold half remainder
mov  [rax + 48], rcx
mov  [rax + 56], rcx

; Dispatch vops_lookup(&scratch_vnode, "tmp") through the table
mov  rdi, rax                           ; dir_vn
lea  rsi, [rip + witness_name_tmp]      ; "tmp\0"
call vops_lookup                        ; goes through _tmpfs_vops[+32]
                                        ; → _tmpfs_lookup_adapter
                                        ; → tmpfs_lookup(root_idx, name)
                                        ; returns /tmp inode idx (== 2)

add  rsp, 64                            ; unwind scratch vnode

; Assert: rax non-zero AND rax != 0xFFFF
cmp  rax, 0
je   tmpfs_vops_witness_fail
cmp  rax, 0xFFFF
je   tmpfs_vops_witness_fail
```

**Sub-test H proves the full dispatch chain works end-to-end** —
vops_lookup loads ops_ptr from vnode+24, indirect-calls
_tmpfs_lookup_adapter, adapter extracts idx from vnode+32,
tail-shape-transforms and directly-calls tmpfs_lookup, which walks
the /tmp inode's sibling chain and returns the child idx. Every
element of the R16.M2 dispatch chain is exercised.

The scratch-vnode-on-stack pattern is safe because the dispatcher
only reads (never writes) the vnode; the 64 bytes disappear on
`add rsp, 64` before the marker emit.

### 7.4 Marker

On all sub-tests green:

```
R16 TMPFS VOPS OK
```

Fingerprint added to `tests/r14b/expected-boot-r14b-loader.txt`,
`tests/r15/expected-boot-r15-ring3.txt`, and
`tests/r15/expected-boot-r15-process.txt` on the line immediately
following `R16 TMPFS UNLINK OK`.

## 8. Invariants

### 8.1 Layout-freeze inheritance

All vops offset constants stay sourced from `src/kernel/core/fs/vops.pdx`
(#572 §4). No file outside that module — including `tmpfs/vops.pdx` —
embeds a numeric vops offset. `tmpfs_vops_init` uses them via the
`VOPS_*_OFFSET` symbols.

### 8.2 Publication invariant for tmpfs vnodes

Any code path that produces a tmpfs vnode (R16.M3+) MUST publish
`vnode.backend_ptr = inode_idx & 0xFFFF` **before** writing a
non-FREE value to `vnode.type`. This extends vfs-layout.md §7.5's
ops_ptr set-before-type-published invariant to backend_ptr for
tmpfs specifically. Violations surface as adapters extracting
garbage idx values, which the primitives will index into
`_tmpfs_inode_pool` — undefined behaviour if idx > 63.

### 8.3 backend_ptr high-48-bits reservation

Bits [16, 64) of `vnode.backend_ptr` are reserved for tmpfs. At
R16.M2 they are required to be zero on publication (soft: adapters
mask to low 16). R17 will formalise a generation counter in bits
[16, 48) with `vnode_pool` bumping it on vnode allocation; adapters
stay unchanged (the mask discards the generation). Bits [48, 64) stay
reserved indefinitely.

### 8.4 Adapter register discipline

Every adapter is a non-leaf under SysV (nested `call`) but touches
no callee-save register. `rax` is scratch; `rdi/rsi/rdx/rcx` are the
arg-passing regs which the adapter either forwards or one-shot
rewrites. The `sub rsp, 8; call; add rsp, 8` pattern maintains the
correct `rsp % 16 == 8` entry state for the primitive (mirrors
#572 §3.2).

### 8.5 Null slot vs. stub slot policy

Tmpfs deliberately picks **stub-slot over null-slot** for `open` and
`close`. Downstream code (R16.M3+ sys_open, sys_close) may safely
assume that for tmpfs-backed vnodes, `vops_open` and `vops_close`
return 0 on success and never `VOPS_ERR_NOT_SUPPORTED`. Any future
backend that genuinely does not support open/close leaves those
slots null; only tmpfs guarantees the stub behaviour.

## 9. Cross-references

- Issue: paideia-os#586
- Milestone: R16.M2 (tmpfs — in-memory VFS backend); R16.M2 close
  condition (item 8 of Subsystem 12)
- Upstream: #572 (vops table layout freeze — provides the 7 offset
  constants and dispatcher shape), #570 (vnode layout freeze —
  provides `VNODE_OPS_PTR_OFFSET` and `VNODE_BACKEND_PTR_OFFSET`),
  #579-585 (the five tmpfs primitives that the adapters wrap).
- Downstream consumers: R16.M3 fd table + sys_open integration
  (uses `_tmpfs_vops` via published mount point); R17 shell demo
  (turns the acceptance criteria "create, write, read, close" into
  end-to-end syscall traffic); any future tmpfs mount point
  (init sequence copies `&_tmpfs_vops` into the root vnode's
  `ops_ptr`).
- Encoder verification:
  - `lea r64, [rip + sym]` — proven by every existing `.pdx` file
    that references a static (tmpfs/inode.pdx:56 etc.).
  - `mov r64, [r64 + disp8]` — proven by fd_table.pdx and every
    inode-field-load site (write.pdx:63, read.pdx:68).
  - `and r64, imm32` (0xFFFF fits) — proven by lookup.pdx:100
    (`and rcx, 0xFFFF`) and every 16-bit-extract site in tmpfs.
  - `mov [r64 + disp8], r64` — proven by vnode_pool.pdx:133-138.
  - `sub rsp, 8` / `add rsp, 8` — proven by every vops dispatcher
    in `src/kernel/core/fs/vops.pdx` (7 uses).
  - `call sym` (direct near) — proven pervasively.
  - `xor eax, eax` — proven pervasively (used as "return 0" idiom
    throughout).

## 10. LOC and tractability summary

| Component                                              | LOC       |
|--------------------------------------------------------|-----------|
| `src/kernel/core/fs/tmpfs/vops.pdx` (new)              | ~200      |
|   - Header + module boilerplate                        |   ~20     |
|   - `_tmpfs_vops` storage + comment                    |   ~10     |
|   - 5 adapters (~20 LOC each incl. justification)      |  ~100     |
|   - 2 stubs (~10 LOC each incl. justification)         |   ~20     |
|   - `tmpfs_vops_init` populator                        |   ~40     |
|   - Cross-refs / footer                                |   ~10     |
| `src/kernel/boot/kernel_main.pdx` (witness block)      |  ~110     |
|   - `call tmpfs_vops_init`                             |    1      |
|   - Sub-tests A-G (7 × 4 instr)                        |   ~40     |
|   - Sub-test H (scratch vnode + vops_lookup)           |   ~30     |
|   - fail/success labels + marker emit                  |   ~15     |
|   - inline comments                                    |   ~20     |
| `tools/boot_stub.S` (2 message strings)                |   ~10     |
| 3 expected-output test files (1 marker each)           |    3      |
| **Total code**                                         |  **~325** |

**Tractability: high.** No encoder gaps; every mnemonic used has
been landed and re-used in prior R16.M2 issues. The 5 adapters are
near-copy-paste with only the target symbol changing. The
`tmpfs_vops_init` populator is a straight repetition of a proven
2-instruction idiom (`lea sym; mov [table + N], rax`) seven times.
The witness is pointer-identity checks (very cheap) plus one
end-to-end sub-test that exercises the whole dispatch chain
without needing vnode_pool integration.

**Expected first-pass workerbee landing.** The only judgment call
in the implementation is (a) whether to include Sub-test H (§7.3) —
recommended: yes, because pointer-identity alone is a very shallow
witness — and (b) whether to inject `tmpfs_vops_init` as its own
symbol or fold into tmpfs_init — recommended: separate symbol, called
from kernel_main between witness blocks, to preserve the byte-
identical fingerprint of every prior R16.M2 witness.

**Risk anchors.**
- **Rejected risk:** encoder churn. All patterns proven.
- **Rejected risk:** semantic regression in prior witnesses. `tmpfs_init`
  is not modified; witness fingerprints upstream stay byte-identical.
- **Live risk:** the scratch-vnode sub-test H allocates 64 bytes on
  stack in the witness block. `kernel_main`'s stack is the boot stack
  (large, always aligned to 16 at entry per bootloader contract);
  the `sub rsp, 64` + `add rsp, 64` pattern is stack-neutral. No
  callee-save is touched by any code within the sub-test.
