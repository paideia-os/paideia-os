---
issue: 581
milestone: R16.M2 (tmpfs — in-memory VFS backend)
subsystem: 12 — tmpfs
topic: tmpfs_lookup — linear scan of dentry chain (R16-M2-003)
freeze-discipline: strict
  - tmpfs inode layout frozen by R16-M2-001 (#579); this issue reads
    from the frozen offsets `+0` (type), `+144..+176` (name[32]),
    `+178` (next_sibling), and `+180` (first_child) via the exported
    constants from `inode.pdx`. No numeric offset is embedded outside
    that module.
  - `tmpfs_lookup` return convention (u16 in low bits of rax; 0 = not
    found / not-a-dir) is frozen for the entire R16.M2 series;
    downstream #582 (`tmpfs_create`) uses lookup as an existence probe
    before insertion (name collision check) and depends on `0` meaning
    "no such child".
blocks:
  - "R16.M3 tmpfs vops table (`tmpfs_vops`) — a later issue registers a wrapper adapting `tmpfs_lookup(dir_inode_idx, name_ptr)` to the vops shape `(dir_vnode_ptr, name_ptr)` by reading the vnode's `backend_ptr` (+32) as the inode idx."
  - "#582 (`tmpfs_create` — reuses this walker as the pre-insertion name-collision probe; keeps two implementations of the same scan from diverging)."
touching:
  - src/kernel/core/fs/tmpfs/lookup.pdx           (new module — `tmpfs_lookup`; ~85 LOC)
  - src/kernel/boot/kernel_main.pdx               (witness block ~90 LOC)
  - tools/boot_stub.S                             (3 witness name strings + 2 message strings; ~20 LOC)
  - tests/r14b/expected-boot-r14b-loader.txt      (marker: "R16 TMPFS LOOKUP OK")
  - tests/r15/expected-boot-r15-ring3.txt         (marker)
  - tests/r15/expected-boot-r15-process.txt       (marker)
  - design/kernel/r16-m2-003-tmpfs-lookup.md      (this doc)
related:
  - design/kernel/r16-m2-001-tmpfs-inode-pool.md  (#579 — frozen layout §2;
    every field offset this module reads is exported by inode.pdx)
  - design/kernel/r16-m2-002-tmpfs-init.md        (#580 — builds the exact
    root → /tmp chain this walker traverses; sub-test A here is the
    downstream half of that init's acceptance criterion)
  - src/kernel/core/fs/path.pdx                   (#573 — resolver already
    handles null-terminated name strings via `_path_component_buf`;
    tmpfs_lookup is the callee-side terminator of that name-passing
    chain when tmpfs vops are wired at R16.M3)
  - src/kernel/core/fs/vops.pdx                   (#572 — vops_lookup dispatch
    shape; tmpfs_lookup will be reached through the +32 slot once the
    tmpfs vops table is wired at R16.M3)
  - design/milestones/r14b-tactical-plan.md       §Subsystem 12 item 3 —
    "Linear scan of directory's dentry list. Acceptance: lookup existing
    name returns inode; miss returns NULL."
---

# R16-M2-003 — `tmpfs_lookup` (linear dentry-chain scan, #581)

## 1. Scope

Ship the tmpfs directory-scan primitive: given a directory inode index
and a null-terminated ASCII name, walk the intrusive sibling chain
rooted at `first_child` and return the child inode index whose `name`
field byte-compares equal, or `0` for miss / not-a-directory.

Concretely:

- **Enter** with `rdi = dir_inode_idx` (u64 with u16 semantics),
  `rsi = name_ptr` (u64, points at a NUL-terminated byte string). No
  bounds pre-check on `dir_inode_idx` — callers reach us only through
  a live index (either #580's `tmpfs_init` return value, another
  tmpfs primitive's result, or #582's fresh alloc).
- **Type gate.** Compute `dir_ptr = &_tmpfs_inode_pool[dir_inode_idx]`
  via `tmpfs_inode_slot`, load `type` at `+0`. If `type != VNODE_TYPE_DIR`,
  return `0` immediately. Regular files, FREE slots, and any future
  type all short-circuit here — the walker never dereferences a
  child chain hanging off a non-directory.
- **Traversal.** Load `first_child` at `+180`; loop while
  `cur_idx != TMPFS_INODE_IDX_NONE` (`0xFFFF`); compute
  `cur_ptr = &pool[cur_idx]`; inline byte-compare `name_ptr` against
  `cur_ptr + TMPFS_INODE_NAME_OFFSET` up to 32 bytes; on match return
  `cur_idx`; on miss advance `cur_idx = cur_ptr.next_sibling` (u16 at
  `+178`) and loop.
- **Miss.** Fall out of the loop when `cur_idx == 0xFFFF`; return
  `0` (miss).

Out of scope (deliberately deferred):

- **No vnode-side dispatch.** `tmpfs_lookup` is the tmpfs-layer
  primitive; the vops-side function `vops_lookup(dir_vn, name_ptr)`
  is dispatched by `vops.pdx` (#572) and reaches this walker via a
  thin adapter registered in the tmpfs vops table at R16.M3. That
  adapter reads the vnode's `backend_ptr` (+32) as `dir_inode_idx`
  and tail-calls (well, calls-then-returns — `jmp reg` not encoded)
  into `tmpfs_lookup`. This issue does not wire the adapter or the
  table.
- **No caching of the last-hit dentry.** A future R17+ optimization
  can add a per-directory `last_hit_idx` cache (parallel array indexed
  by dir_idx), but at R16.M2 every lookup is an O(fan-out) linear scan.
  Directory fan-out is capped at 64 by TMPFS_MAX, so worst-case scan
  is short.
- **No refcount bump on the hit.** Refcount accounting is a
  vnode-layer concern (#576 `vfs_open` bumps the vnode's refcount at
  +2), not a tmpfs-inode concern at lookup time. The returned inode
  idx is a stable handle only while the caller holds any live
  reference to the containing subtree; `tmpfs_lookup` does not extend
  lifetime.
- **No dot / dot-dot fast path.** Callers reaching us through
  path.pdx (#573) have already handled `.` and `..` structurally
  (§3.4 there), so those names never arrive at tmpfs_lookup with a
  meaningful semantic. A malicious or malformed name of exactly `"."`
  or `".."` reaching us here is scanned linearly like any other
  name; since root and /tmp both have empty `name` field at boot
  (root) and `"tmp"` (/tmp), neither literal `.` nor `..` will
  ever match a real child entry — returning `0` (miss) is the
  correct answer.
- **No `tmpfs_lookup_at_offset` / iterator variant.** `readdir(2)`
  will need a positional iterator (start at N-th child); that lands
  at R17 alongside the directory-listing syscall. `tmpfs_lookup` is
  a name→idx map, not a position→idx iterator.

## 2. Contract

```
tmpfs_lookup : (u64, u64) -> u64 !{mem} @{}
  → rax = child_idx in [1, 63]   on match  (u16 semantics; upper bits zero)
  → rax = 0                      on miss OR when dir is not a directory
```

Nullary on capabilities. `!{mem}` because we read the frozen
`_tmpfs_inode_pool` slab through `tmpfs_inode_slot`; no store into any
pool byte.

**Non-leaf.** Makes one or more nested calls to `tmpfs_inode_slot`
(once for the directory itself, then once per child inode inspected).
This forces a callee-save prologue and rsp%16 alignment discipline.

**Miss / not-a-dir collapse into a single rax=0 return.** Callers that
need to distinguish "not a directory" from "no such child" must
type-check via a separate mechanism (in practice, callers reach tmpfs
inodes only after path.pdx has already verified the vnode is a
directory, so the distinction is not actionable at R16.M2). This
matches vops_lookup's ABI (§Subsystem 3 in r16-m1-003 doc: `0 = ENOENT`)
so the eventual adapter is a direct passthrough with no fixup.

## 3. Register discipline

### 3.1 Push plan — 3 pushes

Three-push callee-save prologue: `rbx`, `r12`, `r13`. That gives
`rsp mod 16 == (8 + 3*8) mod 16 == 32 mod 16 == 0` at every nested
call site, matching the SysV AMD64 rule and reproducing the tmpfs_init
alignment discipline exactly (r16-m2-002 §3.2).

| Reg | Role                                                                 |
|-----|----------------------------------------------------------------------|
| rbx | `name_ptr` — caller's arg2, saved on entry so it survives every nested `call tmpfs_inode_slot`. Read repeatedly (once per candidate child inode) during the inline strncmp; must be callee-save. |
| r12 | `cur_idx` — loop invariant; the current child inode index in [1, 63] or the terminating sentinel 0xFFFF. Must survive `tmpfs_inode_slot`. |
| r13 | `cur_ptr` — current child inode pointer (`&_tmpfs_inode_pool[cur_idx]`). Refreshed each loop iteration from `tmpfs_inode_slot`'s return; must survive the intra-iteration strncmp (no nested calls inside the compare, so caller-save would technically work — but the callee-save shape keeps the register plan uniform with tmpfs_init). |

**Why 3 pushes, not 4.** An initial design draft proposed a 4-push
plan (rbx=dir_ptr, r12=name_ptr, r13=cur_idx, r14=cur_ptr). We reduced
to 3 for two reasons:

1. **dir_ptr is single-use.** The directory pointer is consumed exactly
   twice: once to load the type byte at `+0` and once to load
   `first_child` at `+180`. Both loads happen before the traversal
   loop starts. After we've extracted `first_child` into `r12`
   (cur_idx), `dir_ptr` is dead. A callee-save reg holding a dead
   value is wasted — the value can live in `rax` (return of
   `tmpfs_inode_slot`) or the caller-save `r10` scratch across those
   two reads.
2. **Alignment.** 4 pushes = `rsp mod 16 == 8` at nested call sites,
   which is misaligned and would require a `sub rsp, 8` pad before
   every `call tmpfs_inode_slot` (the vops.pdx idiom). The pad costs
   two instructions per iteration on a hot lookup path. 3 pushes
   avoids the pad entirely and matches the vetted tmpfs_init pattern.

The tradeoff (readability of "one register per semantic role" vs
alignment cleanliness) resolves toward alignment because the pad
would be paid inside the loop (once per candidate child) while the
readability cost of loading dir_ptr into `rax` twice at function head
is paid once total.

### 3.2 Scratch registers

Inline strncmp uses `r8`, `r9`, `rcx` (all caller-save). No nested
call inside the compare, so caller-save is safe. `rdx`, `rax` are the
byte-load destinations. Loop control variables (`r12`, `r13`)
survive because the compare makes no nested calls.

## 4. Algorithm

### 4.1 Prologue + arg stash

```asm
tmpfs_lookup:
    push rbx
    push r12
    push r13                           ; rsp%16 = 0

    mov  rbx, rsi                      ; rbx = name_ptr (saved)
```

`rdi` (dir_inode_idx) is passed through into the first
`tmpfs_inode_slot` call — no stash needed because we're about to call
into slot with exactly that argument.

### 4.2 Directory type gate + first_child extraction

```asm
    call tmpfs_inode_slot               ; rax = &_tmpfs_inode_pool[dir_idx]

    ; type byte at +0 must be VNODE_TYPE_DIR (2). Any other value
    ; (FREE=0, REG=1, future types) short-circuits to miss.
    xor  rcx, rcx
    mov_b rcx, [rax + 0]                ; rcx = type
    cmp  rcx, 2                         ; VNODE_TYPE_DIR
    jne  tmpfs_lookup_miss

    ; first_child at +180 (u16). Load u64 at +176 covering
    ; parent_idx(+176) | next_sibling(+178) | first_child(+180) | pad(+182)
    ; and extract bits [32, 48) via shr 32 + mask 0xFFFF. Same idiom as
    ; tmpfs_init witness sub-test B (r16-m2-002 §5.2) — proven at boot.
    mov  rcx, [rax + 176]
    shr  rcx, 32
    and  rcx, 0xFFFF
    mov  r12, rcx                       ; r12 = cur_idx = first_child
```

The u64-load-then-shift-then-mask is 4 bytes cheaper than a direct
`mov_w rcx, [rax + 180]` narrow-load AND does not depend on the
disp8/disp32 encoder shape at offset +180 (which is exactly at the
edge of the imm8 range: 180 > 127, so a narrow load would need
disp32). The u64 idiom sits at disp8 (offset +176, which fits imm8
directly)... wait, 176 > 127 too, so this is also disp32. Both
shapes are proven — see §8.

### 4.3 Traversal loop

```asm
tmpfs_lookup_loop:
    cmp  r12, 0xFFFF                    ; TMPFS_INODE_IDX_NONE — end of chain
    je   tmpfs_lookup_miss

    ; Compute &_tmpfs_inode_pool[cur_idx]
    mov  rdi, r12
    call tmpfs_inode_slot               ; rax = cur_ptr
    mov  r13, rax                       ; r13 = cur_ptr

    ; --- Inline strncmp: [rbx] vs [r13+144], up to 32 bytes ---
    mov  r8, rbx                        ; r8 = user name cursor
    lea  r9, [r13 + 144]                ; r9 = inode name cursor (name field base)
    xor  rcx, rcx                       ; rcx = compare counter

tmpfs_lookup_cmp:
    xor  rax, rax
    xor  rdx, rdx
    mov_b rax, [r8]                     ; user byte
    mov_b rdx, [r9]                     ; inode byte
    cmp  rax, rdx
    jne  tmpfs_lookup_advance           ; mismatch — advance to next sibling
    cmp  rax, 0                         ; both zero AND both equal → match
    je   tmpfs_lookup_hit

    ; Both non-zero and equal; advance one byte.
    add  r8, 1
    add  r9, 1
    add  rcx, 1
    cmp  rcx, 32                        ; TMPFS_INODE_NAME_MAX byte budget
    jb   tmpfs_lookup_cmp

    ; Ran off the end of the name field (32 bytes equal with no NUL
    ; terminator seen). By invariant §7.3 this is impossible for
    ; well-formed inode names (all names in the pool have NUL within
    ; the 32-byte field). But if a caller passed an over-long user
    ; name AND the inode's name field happens to prefix-match, we
    ; treat that as a match. See §6.1 for the alternative.
    jmp  tmpfs_lookup_hit

tmpfs_lookup_advance:
    ; Load next_sibling at +178 (u16). Same u64-load-shift-mask idiom
    ; as first_child extraction above: load u64 at +176, extract
    ; bits [16, 32) via shr 16 + mask 0xFFFF.
    mov  rcx, [r13 + 176]
    shr  rcx, 16
    and  rcx, 0xFFFF
    mov  r12, rcx                       ; r12 = next cur_idx
    jmp  tmpfs_lookup_loop
```

### 4.4 Epilogue

```asm
tmpfs_lookup_hit:
    mov  rax, r12                       ; return cur_idx
    jmp  tmpfs_lookup_done

tmpfs_lookup_miss:
    xor  rax, rax                       ; rax = 0 (miss / not-a-dir)

tmpfs_lookup_done:
    pop  r13
    pop  r12
    pop  rbx
    ret
```

Total instruction count: ~35 in the primary body plus ~4 in the
prologue/epilogue.

## 5. Inline strncmp — 32-byte bounded byte-compare

### 5.1 Why inline, not a call

A standalone `str_eq` primitive would add a nested call inside the
loop, forcing:

- Another `sub rsp, 8` / `add rsp, 8` alignment adjustment inside
  every iteration (or reshuffling the 3-push plan to 5-push to
  compensate — worse).
- A separate design + witness for the string helper (out-of-scope for
  R16.M2 which explicitly ships one lookup primitive, per tactical
  plan).
- Extra register spill/reload traffic to marshal args across the
  call.

Inlining costs ~12 instructions but keeps the whole scan in one
function with a single register plan.

### 5.2 Termination conditions

The inline compare terminates via one of three paths:

| Path              | Trigger                                | Outcome                       |
|-------------------|----------------------------------------|-------------------------------|
| Both-NUL match    | `rax == rdx == 0` after the first-`cmp` fall-through | `tmpfs_lookup_hit` (return cur_idx). |
| Byte mismatch     | `rax != rdx` at any position           | `tmpfs_lookup_advance` (walk to `next_sibling`). |
| 32-byte overrun   | `rcx == 32` with all bytes equal so far | `tmpfs_lookup_hit` (see §6.1 discussion). |

The order of checks matters: **compare first, then NUL-test.** If we
NUL-tested user's byte before comparing against the inode byte, a
name that legitimately contains a NUL at position K would miss the
opportunity to differ from an inode name with a non-NUL at position
K — although in practice user names arriving via `path.pdx` never
contain embedded NULs (path_resolve's copy loop breaks on NUL and
`/`, per r16-m1-004 §3.3).

### 5.3 32-byte budget

`TMPFS_INODE_NAME_OFFSET = 144`, name field width is 32 bytes
(§2 of r16-m2-001 doc). The counter `rcx` is clamped at 32 via the
`jb` (`cmp rcx, 32; jb tmpfs_lookup_cmp`) guard. Reads past the
name field into `parent_idx` at +176 are impossible.

The 32-byte iteration cap is a **field bound**, not a **name-length
bound**. Names in tmpfs are semantically capped at 31 chars + NUL by
the layout (§2 of #579's doc, quoting: "32 bytes = 31 chars + NUL").
The compare loop enforces that the first 32 bytes match; anything
beyond byte 31 on the user side is not compared. See §6.1.

## 6. Alternatives considered

### 6.1 Reject over-length names explicitly (fail the compare on 32-byte overrun)

**Proposal.** At the 32-byte overrun (all bytes equal, still no NUL
on either side), `jmp tmpfs_lookup_advance` instead of
`tmpfs_lookup_hit`. This treats a 32-byte prefix-equal name as
"different" from any tmpfs inode.

**Rejected for R16.M2.** By layout invariant, every tmpfs inode name
has a NUL within its 32-byte field (either from a shorter name +
`.bss` zero-padding, or via a full-31-char + explicit NUL write by
`tmpfs_create`). The 32-byte overrun path is therefore unreachable
against well-formed inodes; both hit and advance branches produce
identical behavior in practice.

If a caller ever passes an over-long user name where bytes 0..31 all
match a real inode's short-name prefix (e.g., user passes a 40-byte
buffer whose first 3 bytes are "tmp"), the `mov_b rax, [r8]` at
position 3 loads the byte AFTER the user's intent — but the
matching inode byte at position 3 is the NUL terminator, so
`cmp rax, rdx` will fail (unless the user's byte at position 3 is
also 0, in which case the compare hits the both-NUL path and
returns match). Either way the 32-byte overrun path is never taken.

Deferring the explicit rejection saves one instruction on the hot
path. Re-visit if a security review at R17 finds this behavior
exploitable (e.g., an attacker crafts a very long name that
prefix-matches a real inode's short name — but the name-terminator
byte on the inode side always fails the compare, so no exploit).

### 6.2 Split "miss" from "not-a-dir" into distinct return values

**Proposal.** `tmpfs_lookup` returns `0` on miss and `0xFFFF` on
not-a-dir, or `0xFFFE` for a semantically distinct sentinel.

**Rejected.** Callers cannot act on the distinction at R16.M2:
- `vops_lookup`'s ABI is `0 = ENOENT` (per r16-m1-003 §2 table).
  Any other sentinel would need translation at the adapter layer.
- `tmpfs_create` (#582) will use `tmpfs_lookup` as a "does this name
  already exist" probe; both "no such child" and "not a directory"
  are equally "cannot create there" for that caller.
- Path resolver has already checked type via the vnode layer before
  reaching tmpfs; "not a directory" is a can't-happen from that
  path, only reachable via a direct-tmpfs test caller (which is
  fine — the test can inspect `type` separately if it cares).

### 6.3 Extract u16 fields via `mov_w reg, [mem+disp8]` narrow loads

**Proposal.** Replace the `mov rcx, [rax+176]; shr rcx, 32; and rcx, 0xFFFF`
three-instruction extraction with a single `mov_w rcx, [rax+180]`
narrow load.

**Rejected.** Offset +180 exceeds imm8 range (127), so the narrow
load would encode with disp32, not disp8. That shape is not proven
by any existing tmpfs / vfs code (r16-m2-002 §8.1 explicitly notes
this concern for its own +178 / +180 writes). The u64-load-shift-mask
idiom uses `mov r64, [reg+disp32]` which IS proven (path.pdx +180
region uses it via slid pointer). Costs 2 extra instructions per
extraction, saves the encoder risk.

If a future issue proves `mov_w reg, [reg+disp32]` via a dedicated
test, revisit this — trims 4 instructions across the two extraction
sites.

### 6.4 Recursive DFS through child chains

**Proposal.** If a child is itself a directory, recurse into its
child chain. This makes `tmpfs_lookup("/tmp/foo", ...)` a single call
that resolves multi-segment paths.

**Rejected.** Multi-segment path resolution is `path_resolve`'s job
(#573), not tmpfs_lookup's. Splitting on `/` and dispatching per
segment lives entirely at the VFS layer; the tmpfs walker sees only
one name at a time. This separation lets `path_resolve` work
against any backend (tmpfs today; devfs, procfs, disk-fs later) via
the vops dispatch, with no backend needing to know how paths are
tokenized.

### 6.5 Bump inode refcount on match

**Proposal.** On hit, atomically increment the returned inode's
`refcount` at +2 before returning.

**Rejected.** Refcount is a vnode-layer accounting field in this
codebase; the tmpfs inode's `refcount` (+2) exists as a placeholder
for the eventual R16.M3 vnode↔inode binder. tmpfs_lookup is a pure
read primitive — bumping refcount here would double-count with the
vnode's own refcount bump at `vfs_open` (#576) and would require
symmetric decrement paths at every `tmpfs_lookup` caller. Keep lookup
side-effect-free.

### 6.6 Hash the name for O(1) lookup

**Proposal.** Add a hash table to each directory inode; hash the
name and index into buckets for O(1) average lookup.

**Rejected for R16.M2.** Directory fan-out is capped at 64 by
`TMPFS_MAX`, and typical directories at boot have 1–2 children
(root has 1: `/tmp`). A linear scan of ≤64 slots at ~35 instructions
per compare is ~2 240 instructions worst-case — comfortably below any
threshold where hashing would help. Hashing also needs collision
resolution, resize semantics, and a hash function — three separate
design freezes for zero measurable benefit at R16.M2 scale.

Deferred to R18 when directories may exceed 64 entries (post-buddy-
allocator disk-fs backend where names can accumulate to hundreds).

## 7. Invariants

### 7.1 Miss / not-a-dir return is exactly `rax = 0`

Both `tmpfs_lookup_miss` (type != DIR OR chain-end sentinel reached)
and any explicit callee-side fail path return `rax = 0` with upper
32 bits also zeroed (via `xor rax, rax`, which zero-idioms the full
u64). Downstream comparisons using `cmp rax, 0` are safe with the
low-32 form because the whole register is known-clean.

### 7.2 Hit return is a valid inode idx in [1, 63]

By the chain-walk invariant (only bitmap-allocated slots are ever
inserted into a `first_child` / `next_sibling` chain — #582's
insertion contract), `cur_idx` on the hit path is always a live
allocation index. The u16 range [1, 63] is guaranteed by
`TMPFS_MAX = 64` and the `tmpfs_inode_alloc` sentinel discipline
(slot 0 reserved). Upper 48 bits of rax are zero because r12 (the
carrier) was written from an ANDed u16 (`and rcx, 0xFFFF`).

### 7.3 Every reachable inode's name field has a NUL within [+144, +176)

Consequence of `.bss` zero-init + `tmpfs_create`'s name-copy
discipline (bounded at 31 chars + explicit NUL write). tmpfs_lookup's
32-byte compare loop therefore always terminates at the both-NUL
match path or the byte-mismatch path; the 32-byte overrun path
(§5.2 row 3) is unreachable against well-formed inodes.

### 7.4 Chain termination is exactly `next_sibling == 0xFFFF`

`0xFFFF` is `TMPFS_INODE_IDX_NONE` (#579 §4). No live inode has
index `0xFFFF` (TMPFS_MAX = 64), so the sentinel is unambiguous.
The scan's `cmp r12, 0xFFFF; je tmpfs_lookup_miss` at each iteration
top guarantees termination in ≤ 64 iterations (fan-out cap).

### 7.5 Read-only against `_tmpfs_inode_pool`

No `mov [r13 + ...]` writes; every store is to a scratch register.
The `!{mem}` effect on the contract is for the READ side (we access
the pool through a runtime pointer, so the effect tracker flags
`mem`) — no dirty flag or write barrier is triggered.

## 8. Encoder verification

Every mnemonic shape used by this issue's code is proven in
R16.M1 / R16.M2 landed modules. No new encoder work.

| Shape                              | Proven by                                                                        |
|------------------------------------|----------------------------------------------------------------------------------|
| `push` / `pop r64`                 | `tmpfs_init.pdx:30-32, 122-124` (3-push identical shape)                         |
| `mov r64, r64`                     | Ubiquitous (`mov rbx, rsi` at r16-m2-002:44)                                     |
| `call sym`                         | Ubiquitous.                                                                       |
| `xor r64, r64`                     | Ubiquitous zero-idiom.                                                            |
| `mov_b r64, [r64 + disp8]`         | `tmpfs_init.pdx` and `path.pdx:124` (`mov_b rax, [r12]`)                          |
| `mov r64, [r64 + disp32]`          | Proven for +176 via `tmpfs_init` witness sub-test B (kernel_main.pdx:2326 `mov rcx, [r13 + 176]`) — same disp32 shape this module uses. |
| `cmp r64, imm8/imm32`              | Ubiquitous (`cmp rax, 0xFFFF` at r16-m2-002:36, `cmp rcx, 32` — imm8).            |
| `shr r64, imm8`                    | Proven via `mount.pdx:203` (`shr rcx, 32`) and tmpfs_init witness (`shr rcx, 32`). |
| `and r64, imm32`                   | Ubiquitous (`and rcx, 0xFFFF` at r16-m2-002 witness).                             |
| `lea r64, [r64 + disp8]`           | `path.pdx:92, 116` and vops.pdx.                                                  |
| `jmp label` / `je` / `jne` / `jb`  | Ubiquitous.                                                                       |
| `add r64, imm8`                    | `path.pdx:80, 142-145` (all `add r64, 1`).                                        |

The `mov r64, [r64 + disp32]` shape at +176 (176 > imm8 range
[-128, 127]) is the only "atypical disp width" in the body and is
directly witnessed by tmpfs_init's own sub-test B, landed in
kernel_main.pdx line 2326. This is the strongest possible encoder
guarantee — same instruction, same register class, same displacement,
in the same compilation unit that ships alongside this module.

`mov_w reg, [reg + disp32]` is NOT used in this module (rejected in
§6.3), so no risk from that encoder gap.

## 9. Test canary — R16 TMPFS LOOKUP OK

Runs in `kernel_main` immediately after the `R16 TMPFS INIT OK`
marker. Placement rationale: `tmpfs_lookup` reads the chain
`tmpfs_init` just built, so any failure here localizes to the walker
rather than to the initializer or the storage substrate.

Three sub-tests, one marker.

### 9.1 Witness fixture — name strings in boot_stub.S

Three new witness name strings, alongside the existing `witness_path_*`
family (r16-m1-004 idiom):

```s
.global witness_name_tmp
.align 8
witness_name_tmp: .ascii "tmp\0"

.global witness_name_missing
.align 8
witness_name_missing: .ascii "missing\0"

.global witness_name_any
.align 8
witness_name_any: .ascii "x\0"
```

Referenced from kernel_main.pdx via `lea rsi, [rip + witness_name_*]`.

### 9.2 Sub-test A — lookup existing name returns the correct child idx

```asm
    ; --- Recover root_idx from tmpfs_init witness (r12 held it there;
    ; but r12 has since been reused — we re-call tmpfs_init would
    ; leak more inodes. Instead: query root_idx anew via the constant.)
    ; The tmpfs_init witness already validated root_idx; here we accept
    ; TMPFS_INODE_IDX_ROOT (= 1) as the working root handle, matching
    ; the sub-test A assumption "boot fingerprint is a fresh bitmap
    ; with only bit 0 pre-set, so first alloc = 1".
    mov  r12, 1                          ; root_idx = TMPFS_INODE_IDX_ROOT
    lea  rsi, [rip + witness_name_tmp]   ; name = "tmp\0"
    mov  rdi, r12
    call tmpfs_lookup
    cmp  rax, 0
    je   tmpfs_lookup_witness_fail       ; miss where hit was expected
    cmp  rax, 0xFFFF
    je   tmpfs_lookup_witness_fail       ; sentinel — shouldn't happen
    mov  r13, rax                        ; r13 = tmp_idx (for cross-check)

    ; Additional cross-check: the returned idx must be a DIR inode
    ; whose name field says "tmp\0". This proves tmpfs_lookup returned
    ; a live inode index (not some spurious non-zero value).
    mov  rdi, r13
    call tmpfs_inode_slot                ; rax = &tmp_inode
    mov  rcx, [rax + 144]                ; load name[0..8] as u64
    mov  rdx, 0x706D74                   ; expected 'tmp\0' + zero pad
    cmp  rcx, rdx
    jne  tmpfs_lookup_witness_fail
```

Proves: (a) tmpfs_lookup walks the chain, (b) matches "tmp" against
the /tmp inode's name field, (c) returns the correct child idx (not
a bogus non-zero value that would fail the name cross-check).

Uses `TMPFS_INODE_IDX_ROOT = 1` directly here (deliberate deviation
from tmpfs_init's "don't pin the constant" discipline, r16-m2-002
§7.5) — this is a witness, not production code, and the witness
runs at a known point in the boot sequence where the invariant "first
alloc = 1" holds by construction. A production caller would use the
value returned by `tmpfs_init`, but at witness time we don't have
that value in scope any more (tmpfs_init's witness saved it in `r12`
which we've since reused for other witnesses). Re-calling
`tmpfs_init` would leak two more inodes into the bitmap.

**Alternative considered:** re-run `tmpfs_init` and use its return
value. Rejected because it leaks two more inodes into the bitmap on
every boot, and the fresh-bitmap invariant (§7.1 of r16-m2-002) is
airtight enough that pinning `= 1` here is safe.

### 9.3 Sub-test B — lookup missing name returns 0

```asm
    lea  rsi, [rip + witness_name_missing]  ; name = "missing\0"
    mov  rdi, 1                             ; root_idx
    call tmpfs_lookup
    cmp  rax, 0
    jne  tmpfs_lookup_witness_fail          ; miss expected → non-zero is wrong
```

Proves: the walker correctly traverses the whole (one-element)
sibling chain, fails every byte-compare, hits the
`next_sibling == 0xFFFF` terminator, and returns 0. This is the
"lookup existing name returns inode; miss returns NULL" acceptance
criterion from issue #581 verbatim.

### 9.4 Sub-test C — lookup on a non-DIR inode returns 0

**Scratch-slot approach.** Instead of allocating a fresh inode (which
would burn a bitmap bit permanently until #582's `tmpfs_inode_free`
lands), we use slot 63 as a "type-set, bitmap-free" scratch slot.
Slot 63 is bitmap-clear (bit 63 of `_tmpfs_inode_bitmap[0]` is 0 at
boot), so no downstream code considers it allocated; we can set its
type byte at will without leaking pool state.

```asm
    ; --- Set up slot 63 as a non-DIR (REG) scratch inode ---
    mov  rdi, 63
    call tmpfs_inode_slot               ; rax = &_tmpfs_inode_pool[63]
    mov  r13, rax
    mov  rcx, 1                          ; VNODE_TYPE_REG (non-DIR)
    mov_b [r13 + 0], rcx

    ; --- Lookup on the non-DIR inode ---
    lea  rsi, [rip + witness_name_any]   ; any name — should not matter
    mov  rdi, 63                         ; non-DIR inode idx
    call tmpfs_lookup
    cmp  rax, 0
    jne  tmpfs_lookup_witness_fail       ; type-gate should have short-circuited

    ; --- Restore slot 63 to FREE (leave no state behind) ---
    mov  rdi, 63
    call tmpfs_inode_slot                ; rax = &pool[63] (r13 may have been
    mov  r13, rax                        ; clobbered by nested call above)
    xor  rcx, rcx
    mov_b [r13 + 0], rcx                 ; type = VNODE_TYPE_FREE
```

Proves: the type-gate short-circuit in tmpfs_lookup fires and no
child-chain traversal is attempted (the child chain in slot 63 is
uninitialized `.bss` — if the walker touched it, it would read
`first_child = 0` and either dereference slot 0 or fail otherwise;
returning `0` immediately from the type gate is the correct behavior).

**Why not allocate + leak.** Allocating via `tmpfs_inode_alloc`
would burn slot 3 (the next free slot) forever until #582 lands the
free primitive. Downstream witnesses (specifically #582's own witness)
would then have to skip slot 3 or work around a "who was here?" mystery.
The scratch-slot-63 approach leaves the bitmap and every meaningful
pool slot bit-identical to the pre-witness state.

**Why not `tmpfs_inode_alloc` + explicit bitmap cleanup.** We could
alloc and then manually clear the bitmap bit via
`mov rdx, 8; xor rdx, 0xFFF...F; and [r8], rdx`. That works but adds
5 instructions of cleanup for zero benefit over the scratch-slot
approach.

### 9.5 Marker

On all three sub-tests green:

```
R16 TMPFS LOOKUP OK
```

Fingerprint added to:

- `tests/r14b/expected-boot-r14b-loader.txt` — line immediately
  following `R16 TMPFS INIT OK`.
- `tests/r15/expected-boot-r15-ring3.txt` — same position.
- `tests/r15/expected-boot-r15-process.txt` — same position.

The witness failure message is `R16 TMPFS LOOKUP FAIL`; both strings
land in `tools/boot_stub.S` immediately after the `tmpfs_init_*_msg`
pair (line ~514).

## 10. Boot integration

Witness is inserted in kernel_main.pdx between
`tmpfs_init_witness_done` (line 2371) and the `wrmsr` for GS_BASE
(line 2373). Insertion point avoids any interaction with the process
subsystem (whose init runs immediately after) — every kernel-facing
side effect of the witness (scratch slot 63's type byte flip) is
undone before the next stage sees it.

Rough kernel_main.pdx delta:

```asm
      tmpfs_init_witness_done:

      // ============================================================
      // R16-M2-003 (#581): tmpfs_lookup witness — 3 sub-tests, 1 marker
      // ============================================================
      tmpfs_lookup_witness:
          // ---------- Sub-test A: hit ----------
          // ... (see §9.2)
          // ---------- Sub-test B: miss ----------
          // ... (see §9.3)
          // ---------- Sub-test C: not-a-dir ----------
          // ... (see §9.4)

          lea  rdi, [rip + tmpfs_lookup_ok_msg]
          call uart_puts
          jmp  tmpfs_lookup_witness_done

      tmpfs_lookup_witness_fail:
          lea  rdi, [rip + tmpfs_lookup_fail_msg]
          call uart_puts

      tmpfs_lookup_witness_done:

      // R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
      lea rax, [rip + _cpu_locals];
      ...
```

## 11. Cross-references

- Issue: paideia-os#581
- Milestone: R16.M2 (tmpfs — in-memory VFS backend)
- Upstream: paideia-os#580 (R16-M2-002 — builds the exact root → /tmp
  chain this walker traverses); paideia-os#579 (R16-M2-001 — frozen
  layout §2 that every field offset here reads through).
- Downstream consumers:
  - #582 (`tmpfs_create` — reuses this walker as the pre-insertion
    "does this name exist?" probe. If we ever refactor the walker
    shape, that issue's create-collision-check depends on it.)
  - A follow-on R16.M3 issue (tmpfs vops table — registers a thin
    adapter that reads `dir_vn.backend_ptr` (+32) as the inode idx
    and forwards to `tmpfs_lookup`).
  - `vops_lookup` (#572 — the vops dispatch stub; reaches this
    walker via the adapter mentioned above).
- Sibling walker pattern: `path.pdx` (#573) walks the vnode-lattice
  by name at the VFS layer; `tmpfs_lookup` walks the tmpfs sibling
  chain at the backend layer. The two are complementary — path.pdx
  splits `/foo/bar` into two calls into tmpfs_lookup, once per
  component.
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 12 item 3 — "Linear scan of directory's dentry list.
  Acceptance: lookup existing name returns inode; miss returns NULL."
