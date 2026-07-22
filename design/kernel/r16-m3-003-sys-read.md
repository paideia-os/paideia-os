---
issue: 589
milestone: R16.M3 (fd table + open/read/write/close/dup2)
subsystem: 13 — file-descriptor + open/read/write/close/dup2
topic: sys_read — validate fd; extract vnode_idx+offset; vfs_read; advance offset in fd_table
prereq:
  - "#587 (sys_open — LANDED; freezes the packed fd_entry encoding this doc reads)"
  - "#588 (sys_close — LANDED; freezes the fd validation idiom this doc mirrors, plus the `and rax, 0xFFFF` vnode_idx decoder)"
  - "#577 (vfs_read — LANDED; dispatcher into vops_read consumed here as the backend surface)"
  - "#586 (tmpfs vops wire — LANDED; provides the vops_read → tmpfs_read chain that vfs_read reaches)"
  - "#584 (tmpfs_read — LANDED; the terminal backend that produces the byte count returned here)"
  - "#583 (tmpfs_write — LANDED; used by the witness preamble to seed `/tmp/x` with 100 x 'A')"
  - "#549 (fd_table embed — LANDED; provides fd_get / fd_set / sentinel-0-means-free discipline)"
blocks:
  - "#590 (sys_write — mirror pattern: reads the same encoding, calls vfs_write, advances offset identically)"
  - "#593 (sys_dup2 — will need the entry-copy idiom that composes cleanly over this doc's encoding)"
  - "R16.M5 (TTY) — will extend fd 0/1/2 dispatch beyond the -EBADF frozen here"
  - "R17 (userland shell demo — first ring-3 sys_read caller through SYSCALL entry once batch-wire lands)"
touching:
  - src/kernel/core/syscall/handlers/sys_read.pdx        (new module — ~110 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                      (witness block ~140 LOC + `_sys_read_witness_task` slab)
  - tools/boot_stub.S                                    (3 rodata additions: ok_msg, fail_msg, witness_path_tmp_x)
  - tests/r14b/expected-boot-r14b-loader.txt             (marker: `R16 SYS READ OK`)
  - tests/r15/expected-boot-r15-ring3.txt                (marker)
  - tests/r15/expected-boot-r15-process.txt              (marker)
  - design/kernel/r16-m3-003-sys-read.md                 (this doc)
related:
  - design/kernel/r16-m3-001-sys-open.md                 (#587 — freezes packed fd_entry encoding
                                                          `entry = vnode_idx | (offset<<16)` consumed here via
                                                          `and rax, 0xFFFF` (vnode_idx) and `shr rax, 16` (offset),
                                                          and written back via `entry + (bytes_read<<16)` after
                                                          the read completes)
  - design/kernel/r16-m3-002-sys-close.md                (#588 — the fd-validation idiom
                                                          `cmp fd, 3; jb ...; cmp fd, 32; jae ...` frozen here;
                                                          §7.3 doubly-validated pattern applies verbatim)
  - design/kernel/r16-m1-008-vfs-read-write.md           (#577 — the 4-arg dispatcher consumed here;
                                                          returns bytes_read in `[0, len]` or the
                                                          `0xFFFFFFFFFFFFFFFF` sentinel this doc's §3.4 maps
                                                          to `-EIO`)
  - design/kernel/r16-m2-006-tmpfs-read.md               (#584 — the terminal backend; §7.8 read/write chain
                                                          invariant is what the witness sub-tests A/B rely on)
  - src/kernel/core/syscall/handlers/sys_open.pdx        (the entry producer; established `_sys_open_witness_task`
                                                          slab pattern this doc reuses)
  - design/kernel/r15-m5-007-fd-table-embed.md           (#549 — fd_get / fd_set / sentinel-0 discipline)
  - design/milestones/r14b-tactical-plan.md              §Subsystem 13, item 3
---

# R16-M3-003 — `sys_read`: fd validation + entry decode + vfs_read + offset advance (#589)

## 1. Scope

Land the R16.M3 subsystem-13 issue #589: the read-side sibling of
`sys_open_body` (#587) and `sys_close_body` (#588). Full body sequence
is a **five-step composition** over the packed fd_entry encoding
frozen by #587 §3.2:

```
sys_read_body(current, fd, buf_ptr, len) -> u64
    rdi = current      (task_struct*)
    rsi = fd           (u64 in [3, 32) — validated at the trust boundary)
    rdx = buf_ptr      (u64 kernel VA — destination buffer)
    rcx = len          (u64 byte count requested)
    rax = bytes_read (in [0, len]) on success
    rax = 0                             at EOF (offset >= size)
    rax = 0xFFFFFFFFFFFFFFF7 (-EBADF)   on any of:
                                          (a) fd < 3   (stdio-reserved at R16.M3)
                                          (b) fd >= 32 (out of range)
                                          (c) fd_table[fd] == 0 (not open)
    rax = 0xFFFFFFFFFFFFFFFB (-EIO)     if vfs_read returns its
                                          `0xFFFFFFFFFFFFFFFF` sentinel
                                          (structurally unreachable from
                                          a valid entry — see §6.2)
```

The five steps:

1. **Validate** `fd` in `[3, 32)`. Idiom-identical to `sys_close_body`
   phase 1 (#588 §3.4). Rejecting fd 0/1/2 preserves the R15.M5
   scan-from-3 discipline; those descriptors gain console/TTY
   semantics at R16.M5, not here.
2. **Load** the packed entry via `fd_get(current, fd)`. A zero entry
   means the slot is free — return `-EBADF`.
3. **Decode** the encoding in a single register: `vnode_idx = entry
   & 0xFFFF` (low 16 bits) and `offset = entry >> 16` (high 48 bits),
   per #587 §3.2.
4. **Dispatch** `vfs_read(vnode_idx, buf_ptr, len, offset)`. This
   reaches the tmpfs backend via `vops_read` per the tmpfs vops wire
   (#586). Returns bytes read in `[0, len]` (short at EOF is legal),
   or the vops error sentinel `0xFFFFFFFFFFFFFFFF`.
5. **Advance** the offset half of the entry by `bytes_read` and
   write it back via `fd_set(current, fd, new_entry)`. The
   vnode_idx half is preserved: `new_entry = entry + (bytes_read <<
   16)`. Return `bytes_read` in rax.

### 1.1 What this issue proves

- **The packed fd_entry encoding round-trips through a read.**
  sys_open writes `entry = vnode_idx | (0 << 16)`; sys_read reads
  vnode_idx via `and rax, 0xFFFF`, offset via `shr rax, 16`, then
  writes back `entry + (bytes_read << 16)`, preserving vnode_idx
  byte-identically. Sub-test C verifies the post-read offset field
  equals the requested read length (100).
- **The vfs→backend→syscall chain returns real bytes to a real
  fd-holder.** For the first time in R16.M3 the whole stack composes:
  `sys_read → fd_get → vfs_read → vops_read → tmpfs_read → memcpy →
  destination buffer`. Sub-test B verifies the destination buffer
  contains the source bytes (0x4141414141414141) that `tmpfs_write`
  wrote in the witness preamble.
- **The offset-advance arithmetic is frozen.** `new_entry = entry +
  (bytes_read << 16)` is a single-add pattern that only touches the
  high 48 bits — the vnode_idx low 16 bits are preserved without an
  explicit mask (because `bytes_read <= 65536` at R16.M3 tmpfs bound,
  so `bytes_read << 16 <= 2^32`, far below the vnode_idx boundary at
  bit 16). #590 (sys_write) will reuse the identical arithmetic;
  freezing it here means write is a two-instruction delta from read.
- **The -EBADF error family established by #588 propagates to
  read.** Same sign-extended u64 (`0xFFFFFFFFFFFFFFF7 == -9`), same
  three failure modes at the trust boundary, same doubly-validated
  discipline downstream (§7.3 of #588). Sub-test E actively
  exercises the fd < 3 mode against fd=2.

### 1.2 What this issue deliberately does NOT do

- **No stdio dispatch for fd 0/1/2.** Read-from-stdin, read-from-
  stdout (return -EBADF per POSIX), and read-from-stderr all lie
  outside R16.M3 scope. The R16.M5 TTY milestone will land console
  input backing for fd 0 and route the other two to -EBADF as
  POSIX prescribes. R16.M3 refuses them uniformly.
- **No copy_to_user.** `buf_ptr` is treated as a kernel VA. The
  destination buffer sits in `.bss` / `.data` at witness time. When
  the SYSCALL entry stub lands (R17), it will bounce user-mode
  buffers through a kernel scratch region before calling
  `sys_read_body`; that copy is the stub's concern, not this
  body's.
- **No -EFAULT on invalid buf_ptr.** No page-table walk to
  distinguish valid from unmapped destination memory. R16.M3 has
  no infrastructure for it. If tmpfs_read's `rep_movsb` faults on a
  bad buf_ptr, the fault handler catches it — that path is R17+
  concern (`fixup_extable` idiom).
- **No SYSCALL entry wiring.** Same rationale as #587 §6.2 and
  #588 §1.2 — batch-wire after all five R16.M3 syscall bodies
  compose. `sys_read_body` is testable in kernel context via the
  witness (§5).
- **No signal-interruptible read.** `sys_read` is atomic at R16.M3
  (no preemption during syscall). R18+ signal machinery will add
  EINTR + partial-buffer semantics; the return type (u64 bytes_read)
  already supports partial returns via short reads at EOF, so the
  ABI grows in-place.
- **No refcount rollback on -EIO.** The -EIO branch is structurally
  unreachable at R16.M3 (§6.2). If it were reachable, no rollback
  is needed: `vfs_read` doesn't mutate refcount; the read failed
  after the fd was validated, so the open fd remains live for a
  later retry or close. The path exists for defense in depth.
- **No non-blocking / async semantics.** POSIX `O_NONBLOCK` is
  ignored — R16.M3's tmpfs backend is always synchronous. When
  future backends (pipe, socket) land, non-blocking becomes a
  per-fd flag stored in the R17 24-byte widened fd_entry.
- **No offset-clamp against overflow.** `entry + (bytes_read <<
  16)` could in principle overflow the u48 offset field. At R16.M3
  tmpfs the file cap is 64 KiB so `offset + bytes_read <= 65536`,
  which is < 2^17. Overflow-safe by input contract; the runtime
  guard lands with the multi-page tmpfs read (R16.M2 follow-on).

## 2. Prereq check

### 2.1 What is in place

| Primitive         | Location                                             | Contract used                                                                                                                                                                                     |
|-------------------|------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `sys_open_body`   | `core/syscall/handlers/sys_open.pdx` (#587, LANDED)  | Used by witness preamble to seed fd=3 pointing at `/tmp/x`. Populates entry per #587 §3.2.                                                                                                          |
| `sys_close_body`  | `core/syscall/handlers/sys_close.pdx` (#588, LANDED) | Not called directly — its fd-validation idiom is the pattern we mirror.                                                                                                                            |
| `fd_get`          | `core/fs/fd_table.pdx:16` (#549, LANDED)             | `(task, fd) -> u64`. Single SIB+disp load; no bounds check (this issue enforces the bound at the trust boundary).                                                                                    |
| `fd_set`          | `core/fs/fd_table.pdx:30` (#549, LANDED)             | `(task, fd, val) -> ()`. Writes the offset-advanced new_entry back.                                                                                                                                 |
| `vfs_read`        | `core/fs/vfs_read.pdx` (#577, LANDED)                | `(vnode_idx, buf_ptr, len, offset) -> u64`. Returns bytes_read (in `[0, len]`) or `0xFFFFFFFFFFFFFFFF` on validation failure. Dispatches through vops_read.                                          |
| tmpfs vops wire   | `core/fs/tmpfs/vops.pdx` (#586, LANDED)              | Publishes `vops_read = tmpfs_read_adapter` in the tmpfs vops table; the adapter extracts `inode_idx` from `vnode.backend_ptr` (+32) and calls `tmpfs_read`.                                          |
| `tmpfs_read`      | `core/fs/tmpfs/read.pdx` (#584, LANDED)              | Terminal backend. `(inode_idx, buf, len, offset) -> bytes_read`. Clamps to file size; EOF returns 0; single-page constraint at R16.M2.                                                              |
| `tmpfs_write`     | `core/fs/tmpfs/write.pdx` (#583, LANDED)             | Used by the witness preamble to re-seed `/tmp/x` at offset 0 with 100 × 'A' (idempotent under the existing state; guarantees a known starting condition even if any earlier witness mutated the file). |
| `tmpfs_lookup`    | `core/fs/tmpfs/lookup.pdx` (#581, LANDED)            | Used by the witness preamble to recover `x_idx` from `/tmp` (mirror of the #584 witness preamble).                                                                                                  |
| Packed fd_entry   | `design/kernel/r16-m3-001-sys-open.md` §3.2          | Encoding frozen: `entry = vnode_idx (low 16) | offset (high 48)`. `and rax, 0xFFFF` extracts vnode_idx; `shr rax, 16` extracts offset.                                                              |
| `/tmp/x` state    | Post-#584 witness at `kernel_main.pdx:2578-2636`     | size=100, `page_ptrs[0]` populated with 100 × 'A'. tmpfs_read witness only reads; state is byte-identical entering the sys_read witness. Preamble tmpfs_write is a defensive re-seed (§4.3).         |
| `tmpfs_write_src_buf` | `tools/boot_stub.S:546`                          | 100-byte source buffer, byte-wise 0x41 ('A'). Reused by preamble to seed data; no new symbol.                                                                                                        |
| `tmpfs_read_dst_buf`  | `tools/boot_stub.S:564`                          | 128-byte zero-initialized destination buffer. Reused as the sys_read destination; no new symbol.                                                                                                    |
| `witness_name_tmp` / `witness_name_any` | `tools/boot_stub.S:515, 523`   | `"tmp\0"`, `"x\0"`. Reused by the preamble's `tmpfs_lookup` calls.                                                                                                                                  |

### 2.2 What is NOT in place — one string gap

**No `/tmp/x` NUL-terminated path literal exists in boot_stub.S
today.** The R16.M2 witnesses reached `/tmp/x` inode via
`tmpfs_lookup` chains (not through path strings). `sys_open`'s
witness used `witness_path_slash` ("/") and `witness_path_nope`
("/nope") — neither of which is `/tmp/x`.

We add one 8-byte rodata string:

```asm
.global witness_path_tmp_x
.align 8
witness_path_tmp_x: .ascii "/tmp/x\0"
```

Encoder-wise this is trivial; it lives alongside the existing
`witness_path_slash` / `witness_path_foo_bar` block in
`boot_stub.S:622-645`. Cost: 7 bytes in `.rodata` plus one symbol
entry.

### 2.3 Encoder gaps

**None.** `sys_read_body` uses only patterns proven pervasively:

| Mnemonic                     | Proven at                                                                                       |
|------------------------------|-------------------------------------------------------------------------------------------------|
| `push r64` / `pop r64`       | Every function with a callee-save prologue. 5-push idiom identical to `tmpfs_read.pdx:47-52`.    |
| `mov r64, r64`               | Ubiquitous.                                                                                     |
| `call sym` (direct near)     | Ubiquitous.                                                                                     |
| `cmp r64, imm32`             | `sys_close.pdx:53,55`, `sys_open.pdx:58,67`.                                                     |
| `jb` / `jae` / `je` / `jmp`  | `sys_close.pdx:54,56,64,78`.                                                                    |
| `and r64, imm32`             | `sys_close.pdx:67`, `tmpfs_write.pdx:111`, `tmpfs_read.pdx:112`. Same `0xFFFF` and `0xFFF` sites. |
| `shl r64, imm8`              | `aspace_map.pdx:96,133,170,185`, `idt.pdx:350,447,455,463`, `mount.pdx:178`. `shl rax, 16` is a direct instance of the last (which packs identically for a different purpose). |
| `shr r64, imm8`              | `tmpfs_write.pdx:81,85`, `tmpfs_read.pdx:93,97`. Both use `shr r64, 12`; `shr r64, 16` uses the same encoder path.                                                                       |
| `add r64, r64`               | Ubiquitous.                                                                                     |
| `mov r64, imm64`             | For -EBADF (`0xFFFFFFFFFFFFFFF7`) and -EIO (`0xFFFFFFFFFFFFFFFB`) and the vfs_read sentinel constant.                                                                                    |
| `xor r64, r64`               | Ubiquitous zero-idiom.                                                                          |

No SIB, no REX.B-extended-base gotchas, no XMM/AVX. sys_read is
arithmetically simpler than `sys_open_body` (no argument shuffle
into 4 registers upfront — the SysV incoming regs feed rbx/r12/r13/r14
directly) and adds one non-trivial computation (offset extraction
via `shr` and offset-advance via `shl + add`).

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/syscall/handlers/sys_read.pdx`. Sits
alongside the existing handlers:

```
src/kernel/core/syscall/handlers/
    sys_close.pdx    (#588)
    sys_execve.pdx   (#555)
    sys_exit.pdx     (#557)
    sys_fork.pdx     (#554)
    sys_open.pdx     (#587)
    sys_read.pdx     <-- THIS ISSUE
    sys_wait.pdx     (#556)
```

Module name: `SysRead`. Public export: `sys_read_body`.

### 3.2 Register discipline — 5-push prologue

Five persistent values must survive nested calls (`fd_get`,
`vfs_read`, `fd_set`):

| Reg | Role                                                                                                                                    |
|-----|-----------------------------------------------------------------------------------------------------------------------------------------|
| rbx | `current` — caller's arg1. Survives all three nested calls (fd_get, vfs_read, fd_set).                                                    |
| r12 | `fd` — caller's arg2. Survives all three nested calls.                                                                                    |
| r13 | `buf_ptr` — caller's arg3. Survives `fd_get`; remarshaled to `rsi` for `vfs_read`; dies after.                                             |
| r14 | Dual-role register: (a) `len` before `vfs_read` (remarshaled to `rdx`); (b) `bytes_read` after `vfs_read` (source of the return value).   |
| r15 | Dual-role register: (a) `entry` (packed vnode_idx | offset) after `fd_get`; (b) `new_entry` after the offset-advance arithmetic — same register morphs by a single `add` in place. |

**Why 5 pushes.** SysV entry has `rsp % 16 == 8`; 5 pushes drop rsp
by 40, giving `rsp % 16 == 0` at each nested call site. A 4-push
prologue would leave `rsp % 16 == 8` misaligned. A 3-push (as in
sys_open/sys_close) is insufficient because we need to hold four
live values across `vfs_read` (current, fd, entry, len for post-call
offset-advance context) — plus we need `buf_ptr` before dispatching.

**Why r14 and r15 morph.** The narrative rule from `r16-m2-006`
§3.1 ("keep semantics stable per register") applies within a
single semantic scope; here the morph happens at a hard
control-flow boundary (post-vfs_read) that a reviewer cannot miss:

- `r14 = len` is dead after `vfs_read` (len is never read again).
  `r14 = bytes_read` is the natural post-call meaning — the value
  we ultimately return.
- `r15 = entry` is dead once we compute `new_entry`; but the
  compute is `new_entry = entry + (bytes_read << 16)`, i.e.
  `r15 += (r14 << 16)` — an in-place add. The register carries
  the encoded fd_table entry; the low 16 bits (vnode_idx) never
  change; only the high 48 bits (offset) advance. Semantically
  the register is "the fd_table entry after read"; the
  before/after morph is a monotonic offset advance, not a
  semantic swap.

Documented explicitly in the justification comment (§3.6).

### 3.3 `sys_read_body` — body sequence

```asm
; ================================================================
; sys_read_body(current, fd, buf_ptr, len) -> u64
;   rdi = current       (task_struct*)
;   rsi = fd            (u64, validated in [3, 32))
;   rdx = buf_ptr       (u64 kernel VA — destination)
;   rcx = len           (u64 byte count requested)
;
; Returns rax:
;   bytes_read (in [0, len]) on success (0 == EOF)
;   0xFFFFFFFFFFFFFFF7 (-EBADF)  if fd < 3, fd >= 32, or slot free
;   0xFFFFFFFFFFFFFFFB (-EIO)    if vfs_read returns the sentinel
;                                (structurally unreachable — §6.2)
;
; Register discipline (5-push prologue for rsp%16==0 at nested calls):
;   rbx = current                  (saved across fd_get, vfs_read, fd_set)
;   r12 = fd                       (saved across fd_get, vfs_read, fd_set)
;   r13 = buf_ptr                  (saved across fd_get; passed to vfs_read as rsi)
;   r14 = len | bytes_read         (len before vfs_read; bytes_read after)
;   r15 = entry | new_entry        (entry after fd_get; morphs to new_entry
;                                    via `add r15, rcx` where rcx = bytes_read<<16)
; ================================================================
sys_read_body:
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; --- Save arguments in callee-save regs ---
    mov rbx, rdi                        ; rbx = current
    mov r12, rsi                        ; r12 = fd
    mov r13, rdx                        ; r13 = buf_ptr
    mov r14, rcx                        ; r14 = len

    ; --- Phase 1: validate fd in [3, 32) ---
    cmp r12, 3
    jb  sys_read_ebadf                  ; fd < 3 (stdio reserved at R16.M3)
    cmp r12, 32
    jae sys_read_ebadf                  ; fd >= 32 (out of range)

    ; --- Phase 2: fd_get(current, fd) → rax = entry ---
    mov rdi, rbx
    mov rsi, r12
    call fd_get

    cmp rax, 0
    je  sys_read_ebadf                  ; slot free ↔ fd not open

    mov r15, rax                        ; r15 = entry (packed)

    ; --- Phase 3: dispatch vfs_read(vnode_idx, buf, len, offset) ---
    mov rdi, r15
    and rdi, 0xFFFF                     ; rdi = vnode_idx (low 16)
    mov rsi, r13                        ; rsi = buf_ptr
    mov rdx, r14                        ; rdx = len
    mov rcx, r15
    shr rcx, 16                         ; rcx = offset (high 48)
    call vfs_read                       ; rax = bytes_read or 0xFFFFFFFFFFFFFFFF

    ; --- Phase 4: check vfs_read failure sentinel ---
    ; Legitimate returns are in [0, len] (len <= u64::MAX; tmpfs bounds at 65536).
    ; Sentinel 0xFFFFFFFFFFFFFFFF is unequivocally != any legit value.
    mov rcx, 0xFFFFFFFFFFFFFFFF
    cmp rax, rcx
    je  sys_read_eio

    ; --- Phase 5: advance offset in entry; write back via fd_set ---
    mov r14, rax                        ; r14 = bytes_read (repurposed from `len`;
                                        ;                    also the return value)

    ; new_entry = entry + (bytes_read << 16)
    ; This preserves vnode_idx (low 16 bits) byte-identically because
    ; bytes_read <= 65536 at R16.M3 tmpfs bound; bytes_read << 16 <= 2^32,
    ; which fits entirely within the high 48 bits (offset field).
    mov rcx, r14
    shl rcx, 16                         ; rcx = bytes_read << 16
    add r15, rcx                        ; r15 = new_entry (in-place morph)

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    call fd_set                         ; entry write-back; return ignored

    ; --- Success: return bytes_read ---
    mov rax, r14
    jmp sys_read_done

sys_read_ebadf:
    mov rax, 0xFFFFFFFFFFFFFFF7         ; -EBADF (-9)
    jmp sys_read_done

sys_read_eio:
    mov rax, 0xFFFFFFFFFFFFFFFB         ; -EIO (-5)

sys_read_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
```

**Instruction count**: ~35 across the body (including
prologue/epilogue). Comparable to `tmpfs_read`'s inner path
(~40 instructions) and denser than `sys_close_body` (~22)
because of the offset-advance arithmetic.

### 3.4 Error-code convention

| Return sentinel                | Signed value | Meaning                                             |
|--------------------------------|--------------|-----------------------------------------------------|
| `0..len`                       | success      | bytes actually read (0 at EOF)                      |
| `0xFFFFFFFFFFFFFFF7`           | `-9`         | `-EBADF` — fd < 3, fd >= 32, or slot free           |
| `0xFFFFFFFFFFFFFFFB`           | `-5`         | `-EIO` — vfs_read validation sentinel propagation   |

`EBADF = 9` and `EIO = 5` match Linux errno numbering. The three
`-EBADF` modes are unified per POSIX `read(2)`; distinguishing them
would leak R16.M3-internal policy into the errno namespace (same
rationale as #588 §3.2 for close).

**Why -EIO for the vfs_read sentinel and not -EBADF.** `vfs_read`
returns `0xFFFFFFFFFFFFFFFF` only on structural validation failure
(vnode_idx == 0 or vnode_idx >= 256, per `r16-m1-008-vfs-read-write.md`
§37-38). Both are structurally impossible from `sys_read`'s call
site under R16.M3 invariants:

- vnode_idx == 0 is guarded by phase 2's `cmp rax, 0; je
  sys_read_ebadf` — a valid populated entry has vnode_idx > 0.
- vnode_idx >= 256 is bounded by vnode_alloc's `VNODE_MAX = 256`;
  any entry sourced from `sys_open` obeys this.

If either happens, it means a corrupted fd_table entry has leaked
into the read path — that's an I/O layer integrity issue, not a
bad file descriptor. `-EIO` is the POSIX-idiomatic response.

### 3.5 Why the phase order matters

Same reasoning as #588 §3.5, extended for the offset-advance:

- **Validate before Get.** `fd_get` performs an unbounded SIB
  load. Bounds must be enforced first.
- **Get before Decode.** Trivially — need the u64 to mask.
- **Decode before Dispatch.** Trivially — need vnode_idx and offset
  as arguments.
- **Dispatch before Advance.** We need `bytes_read` to compute
  `new_entry`. The alternative — advance first with `len`, then
  clamp on return — would over-advance the offset on a short read,
  corrupting the next read's starting position.
- **Advance last.** If `fd_set` were to fault (it doesn't — leaf
  function with a single store), the visible side effect is a
  written destination buffer plus an unadvanced offset. That
  duplicates data on retry rather than silently losing bytes — a
  safer failure mode than the reverse.

### 3.6 File contents (skeleton)

```pdx
// src/kernel/core/syscall/handlers/sys_read.pdx — R16-M3-003 (#589)
// sys_read body: fd validate + fd_get + decode + vfs_read + offset advance.
//
// Consumes the packed fd_entry encoding frozen by #587 §3.2:
//   entry = vnode_idx | (offset << 16)
// Reads vnode_idx via `and rax, 0xFFFF`, offset via `shr rax, 16`,
// dispatches vfs_read, then writes back new_entry = entry + (bytes_read << 16)
// preserving vnode_idx byte-identically.
//
// See design/kernel/r16-m3-003-sys-read.md for full contract.

module SysRead = structure {
  // === Error sentinels (negative-errno u64, matches Linux errno signs) ===
  pub let SYS_READ_ERR_EBADF : u64 = 0xFFFFFFFFFFFFFFF7   // -9
  pub let SYS_READ_ERR_EIO   : u64 = 0xFFFFFFFFFFFFFFFB   // -5

  // === Layout constants (from #549 fd_table freeze) ===
  pub let FD_TABLE_STDIO_LO : u64 = 3                     // matches fd_table.pdx:10
  pub let FD_TABLE_MAX      : u64 = 32                    // matches fd_table.pdx:9

  // ==========================================================================
  // sys_read_body — validate fd; decode entry; dispatch vfs_read; advance offset
  //
  // Input:
  //   rdi = current   (task_struct*, must be non-NULL)
  //   rsi = fd        (u64 — validated in [3, 32) at the trust boundary)
  //   rdx = buf_ptr   (u64 kernel VA — destination buffer)
  //   rcx = len       (u64 byte count requested)
  //
  // Output:
  //   rax = bytes_read (in [0, len])       on success (0 == EOF)
  //   rax = 0xFFFFFFFFFFFFFFF7 (-EBADF)    on any of:
  //         (a) fd < 3
  //         (b) fd >= 32
  //         (c) fd_table[fd] == 0
  //   rax = 0xFFFFFFFFFFFFFFFB (-EIO)      on vfs_read sentinel (unreachable
  //                                          from valid entry; defense in depth)
  //
  // Side effects:
  //   on success: destination buffer `buf_ptr[0..bytes_read]` populated;
  //     fd_table[fd] offset half advanced by bytes_read (vnode_idx preserved).
  //   on -EBADF: none (early return before any nested call).
  //   on -EIO: destination buffer untouched (vfs_read's sentinel path returns
  //     before reaching the memcpy stanza per r16-m1-008 §4.5).
  // ==========================================================================
  pub let sys_read_body : (u64, u64, u64, u64) -> u64 !{mem} @{} =
    fn (current: u64) (fd: u64) (buf_ptr: u64) (len: u64) -> unsafe {
      effects: {mem},
      capabilities: {},
      justification: "R16-M3-003 (#589): sys_read — fd validate; fd_get; decode entry; vfs_read; advance offset; fd_set. 4-arg SysV entry. rdi=current, rsi=fd, rdx=buf_ptr, rcx=len. 5-push prologue (rbx, r12, r13, r14, r15) aligns rsp%16==0 for nested calls and saves current/fd/buf/len across three calls. Phase 1: validate fd in [3,32) via cmp+jb / cmp+jae (unsigned semantics — same idiom as sys_close #588 §3.4). Phase 2: fd_get(rbx,r12) → rax = packed entry; cmp rax, 0; je → -EBADF (slot free ↔ fd not open). Phase 3: decode + dispatch — `and rdi, 0xFFFF` extracts vnode_idx from a copy of r15 (entry); `mov rsi, r13` restores buf_ptr; `mov rdx, r14` restores len; `mov rcx, r15; shr rcx, 16` extracts offset. Call vfs_read → rax = bytes_read (in [0,len]) or 0xFFFFFFFFFFFFFFFF sentinel. Phase 4: sentinel check via 8-byte immediate load into rcx + cmp — sentinel maps to -EIO (structurally unreachable at R16.M3 per §6.2 but present for defense in depth). Phase 5: `mov r14, rax` saves bytes_read for return (repurposes r14 from `len`); compute new_entry via `mov rcx, r14; shl rcx, 16; add r15, rcx` — this is an in-place offset advance that preserves vnode_idx byte-identically (bytes_read << 16 ≤ 2^32 at R16.M3 tmpfs bound, entirely within high 48 bits). fd_set(rbx, r12, r15) writes the advanced entry back. Return `mov rax, r14` — the bytes_read value. Register morphs (r14: len→bytes_read; r15: entry→new_entry) happen at hard control-flow boundaries (post-vfs_read) and are documented in the code comments. All nested callees (fd_get leaf, fd_set leaf, vfs_read 5-push prologue) trusted callee-save clean. See design/kernel/r16-m3-003-sys-read.md §3 for full rationale.",
      block: {
        push rbx;
        push r12;
        push r13;
        push r14;
        push r15;

        mov rbx, rdi;                        // rbx = current
        mov r12, rsi;                        // r12 = fd
        mov r13, rdx;                        // r13 = buf_ptr
        mov r14, rcx;                        // r14 = len

        // Phase 1: validate fd in [3, 32)
        cmp r12, 3;
        jb  sys_read_ebadf;
        cmp r12, 32;
        jae sys_read_ebadf;

        // Phase 2: fd_get(current, fd) → rax = entry
        mov rdi, rbx;
        mov rsi, r12;
        call fd_get;

        cmp rax, 0;
        je  sys_read_ebadf;                  // slot free ↔ fd not open

        mov r15, rax;                        // r15 = entry (packed)

        // Phase 3: decode + dispatch vfs_read(vnode_idx, buf, len, offset)
        mov rdi, r15;
        and rdi, 0xFFFF;                     // rdi = vnode_idx (low 16)
        mov rsi, r13;                        // rsi = buf_ptr
        mov rdx, r14;                        // rdx = len
        mov rcx, r15;
        shr rcx, 16;                         // rcx = offset (high 48)
        call vfs_read;                       // rax = bytes_read or sentinel

        // Phase 4: check vfs_read failure sentinel
        mov rcx, 0xFFFFFFFFFFFFFFFF;
        cmp rax, rcx;
        je  sys_read_eio;

        // Phase 5: advance offset; write back new_entry; return bytes_read
        mov r14, rax;                        // r14 = bytes_read (repurposed from `len`)

        // new_entry = entry + (bytes_read << 16); vnode_idx preserved
        mov rcx, r14;
        shl rcx, 16;                         // rcx = bytes_read << 16
        add r15, rcx;                        // r15 = new_entry (in-place morph)

        mov rdi, rbx;
        mov rsi, r12;
        mov rdx, r15;
        call fd_set;

        mov rax, r14;                        // return bytes_read
        jmp sys_read_done;

      sys_read_ebadf:
        mov rax, 0xFFFFFFFFFFFFFFF7;         // -EBADF
        jmp sys_read_done;

      sys_read_eio:
        mov rax, 0xFFFFFFFFFFFFFFFB;         // -EIO

      sys_read_done:
        pop r15;
        pop r14;
        pop r13;
        pop r12;
        pop rbx;
        ret
      }
    }
}
```

## 4. Witness task_struct — decision

### 4.1 Choice: dedicated `_sys_read_witness_task` (mirrors #587 §4.1, #588 §4.1)

Same three-way trade explored by #587/#588 (dedicated slab vs.
`_idle_tcb` vs. reusing a prior witness's slab). Dedicated slab
wins for the same three reasons — no scheduler-init ordering
hazard, no cross-witness state coupling, stylistic uniformity —
plus one read-specific reason:

- **Refcount clarity.** The sys_read witness opens `/tmp/x` once
  and does not close it. The vnode's refcount ends this witness
  `+1` above its pre-witness baseline. With a dedicated slab, the
  refcount delta is attributable to exactly one open call —
  reviewable in isolation. Reusing `_sys_open_witness_task` or
  `_sys_close_witness_task` would blend the delta with the prior
  witness's residue.

### 4.2 Slab declaration

At the tail of `kernel_main.pdx`, alongside `_sys_open_witness_task`
and `_sys_close_witness_task`:

```pdx
// R16-M3-003 (#589): sys_read witness task storage.
// Static .bss blob (2224 bytes = 278 u64s) backing a dedicated
// witness task_struct.  Same rationale as _sys_open_witness_task
// (#587 §4.1) and _sys_close_witness_task (#588 §4.1): witness
// storage stays independent of the scheduler init sequence so
// R16.M3 witnesses run before idle_init / runq_init without
// ordering hazards.
pub let mut _sys_read_witness_task : [u64; 278] = uninit @align(8)
```

### 4.3 Preamble: why tmpfs_write before sys_open (not after)

The parent task-brief lists the preamble as "sys_open then
tmpfs_write to establish data". Two subtleties motivate a slight
re-ordering:

1. **tmpfs_write is idempotent under the existing state.**
   `/tmp/x` already contains 100 × 'A' at offset 0 with size=100
   (from #583's witness at kernel_main.pdx:2520). tmpfs_write
   with the same source buffer at offset 0 leaves the file
   byte-identical. This is a defensive re-seed to make the
   sys_read witness robust to future R16.M2-witness edits that
   might mutate `/tmp/x`.
2. **Ordering-agnostic.** Whether tmpfs_write comes before or
   after sys_open, the outcome is identical: `/tmp/x` has 100 × 'A'
   at offset 0, and sys_open populates fd=3 with offset=0. Neither
   op affects the other's inputs.

The chosen order (tmpfs_write before sys_open) makes the witness
narrative cleaner: "prepare the file, then open it, then read it".

### 4.3.1 Debug addendum — two landing-time defects found in the witness

The design above (and the parent task-brief) assumed `/tmp/x`
was directly reachable by `tmpfs_lookup`/`sys_open_body` at
sys_read-witness time. Landing surfaced two defects, both fixed
in the witness preamble (not in any frozen module):

**Defect 1 — `/tmp/x` was already unlinked.** The #585
`tmpfs_unlink_witness` (kernel_main.pdx, runs before this witness)
unlinks `/tmp/x` as part of its own sub-tests A-D: the directory
entry is spliced out of `/tmp`'s sibling chain and the inode's
bitmap bit is cleared (proven by that witness's own sub-tests B
and D). By the time this witness's preamble runs, `tmpfs_lookup(tmp_idx,
"x")` unconditionally misses. Fix: the preamble now calls
`tmpfs_create(tmp_idx, "x", 1, VNODE_TYPE_REG=1)` — the same
arguments as the #582 `tmpfs_create_witness` — to re-materialize
`/tmp/x` before seeding data and opening it.

**Defect 2 — the persistent (non-scratch) vnode tree was never
wired to the tmpfs vops table.** This is the deeper defect and
predates #589. `path_resolve` (#573) and `vfs_read` (#577) both
resolve a "vnode_idx" by calling `vnode_slot(idx)` and dispatching
through that slot's `ops_ptr`(+24)/`backend_ptr`(+32) fields — but
`vnode_idx` here is, at every step past the very first, actually
a **tmpfs-native inode index** returned by `vops_lookup`/
`tmpfs_lookup`, not a `vnode_alloc`-issued vnode-pool index. The
two index spaces are silently treated as one and the same. Nothing
in the boot sequence up to #589 ever populated `_vnode_pool[idx]`
for `idx` in the tmpfs-inode space:

- The #574 `mount_witness` allocates the root vnode via
  `vnode_alloc` (landing at whatever free slot the pool hands
  out — vnode-pool idx, e.g. 100) and deliberately leaves its
  `ops_ptr` at zero (see `mount.pdx` phase 5 comment). It is never
  wired to `_tmpfs_vops` / `TMPFS_INODE_IDX_ROOT` anywhere.
- The #586 `tmpfs_vops_witness` proves the `_tmpfs_vops` table and
  its 7 adapters are wired correctly, but does so against a
  throwaway **scratch vnode built on the stack** — it never
  touches `_vnode_pool`.
- Every prior `sys_open_body` witness (#587) exercises only
  zero-/single-component paths (`"/"`, `"/nope"`). `"/"` never
  reaches `vops_lookup` at all (path_resolve's NUL-after-skip-slash
  fast path returns the anchor directly). `"/nope"` does call
  `vops_lookup` once, against the never-wired root vnode, and gets
  `VOPS_ERR_NOT_SUPPORTED` from `vops_lookup`'s null-`ops_ptr` guard
  (`vops.pdx`) — which happens to mask down to the same `-ENOENT`
  a real "not found" would produce. The defect was invisible
  because its wrong-for-the-wrong-reason answer coincided with the
  expected one.

  `/tmp/x` is the first **real multi-component** path any witness
  has asked `vfs_open`/`path_resolve` to resolve end-to-end. Walking
  it requires three `vnode_slot` targets in succession — the mount
  root, `/tmp`, and `/tmp/x` — and none of the three had ever been
  wired.

  Fix (confirmed by binary-search instrumentation: temporary debug
  markers inserted after each preamble step and each sub-test,
  removed before commit): the preamble now wires all three
  identity-mapped slots explicitly, immediately after each index is
  obtained —
  ```
  vnode_slot(root_vnode_idx).ops_ptr     = &_tmpfs_vops
  vnode_slot(root_vnode_idx).backend_ptr = TMPFS_INODE_IDX_ROOT (1)
  vnode_slot(tmp_idx).ops_ptr            = &_tmpfs_vops
  vnode_slot(tmp_idx).backend_ptr        = tmp_idx
  vnode_slot(x_idx).ops_ptr              = &_tmpfs_vops
  vnode_slot(x_idx).backend_ptr          = x_idx
  ```
  — before the `tmpfs_write`/`sys_open_body`/`sys_read_body` calls
  that need them. This is a **witness-local workaround**, not an
  architectural fix: it does not generalize to arbitrary paths or
  to directories created outside this witness's control flow. The
  underlying defect — `path_resolve` conflating vnode-pool indices
  with backend-native inode indices — is out of scope for #589 (it
  lives in the frozen #573/#574/#575/#577/#586 modules) and is
  filed as a follow-up issue for a proper fix (e.g. `vfs_open`/
  `path_resolve` allocating a real vnode-pool slot per resolved
  path component instead of reusing the backend's own index).

### 4.4 Position in kernel_main

Inserted immediately after `sys_close_witness_done:` (line 2937)
and before the `wrmsr` at line 2939 that begins IA32_GS_BASE
setup.

That placement satisfies all prereqs:

- vfs_read witnessed at line ~2100 area (#577 canary).
- tmpfs_read witnessed at line 2578 (#584 canary).
- tmpfs vops wire witnessed at line ~2795 (#586 canary).
- sys_open_body witnessed at line 2815 (#587 canary).
- sys_close_body witnessed at line 2880 (#588 canary).
- No coupling to idle/runq/sched_switch witnesses that follow the wrmsr.

## 5. Test canary — kernel_main witness block

### 5.1 Preamble

Inputs:

- `_sys_read_witness_task`: fresh 278-u64 `.bss` blob (all zeros).
- `sys_open_body` proven working (by #587's witness).
- `vfs_read` proven working (by #577's witness).
- `tmpfs_lookup`, `tmpfs_write`, `tmpfs_read` proven (R16.M2
  canaries).
- `witness_path_tmp_x` (new — see §5.5): `"/tmp/x\0"`.
- `witness_name_tmp`, `witness_name_any` already resident.
- `tmpfs_write_src_buf` (100 × 'A') and `tmpfs_read_dst_buf`
  (128 bytes of 0) already resident.

### 5.2 Sub-tests

Matches the parent brief exactly: A/B/C for the success path,
D for EOF idempotency, E for the -EBADF trust-boundary.

**Preamble prep — recover `x_idx`, re-seed data, open fd=3.**
```asm
; --- Recover tmp_idx via lookup on root (VNODE_IDX_ROOT = 1) ---
mov  rdi, 1
lea  rsi, [rip + witness_name_tmp]           ; "tmp\0"
call tmpfs_lookup
cmp  rax, 0
je   sys_read_witness_fail
mov  r12, rax                                ; r12 = tmp_idx (temp, scope-local
                                             ;                to witness block)

; --- Recover x_idx via lookup on /tmp ---
mov  rdi, r12
lea  rsi, [rip + witness_name_any]           ; "x\0"
call tmpfs_lookup
cmp  rax, 0
je   sys_read_witness_fail
mov  r13, rax                                ; r13 = x_idx

; --- Re-seed data: tmpfs_write(x_idx, src_buf, 100, 0) → 100 ---
;    Idempotent under the existing state (see §4.3).
mov  rdi, r13                                ; x_idx
lea  rsi, [rip + tmpfs_write_src_buf]        ; 100 × 'A'
mov  rdx, 100                                ; len
xor  rcx, rcx                                ; offset = 0
call tmpfs_write
cmp  rax, 100
jne  sys_read_witness_fail

; --- sys_open("/tmp/x", 0, 0) → fd = 3 (scan-from-3 on fresh slab) ---
lea  rdi, [rip + _sys_read_witness_task]
lea  rsi, [rip + witness_path_tmp_x]         ; "/tmp/x\0"
xor  rdx, rdx                                ; flags = 0
xor  rcx, rcx                                ; mode = 0
call sys_open_body
cmp  rax, 3
jne  sys_read_witness_fail
```

**Sub-test A**: `sys_read(w, 3, dst_buf, 100)` returns `100`.
```asm
lea  rdi, [rip + _sys_read_witness_task]
mov  rsi, 3                                  ; fd
lea  rdx, [rip + tmpfs_read_dst_buf]         ; buf_ptr
mov  rcx, 100                                ; len
call sys_read_body
cmp  rax, 100
jne  sys_read_witness_fail
```

Proves: (a) fd validation passes for fd=3; (b) fd_get returns
a populated entry; (c) vnode_idx and offset decode correctly;
(d) vfs_read → vops_read → tmpfs_read chain executes end to
end; (e) return value is the byte count.

**Sub-test B**: `tmpfs_read_dst_buf[0..8]` == `0x4141414141414141`.
```asm
lea  r14, [rip + tmpfs_read_dst_buf]
mov  rcx, [r14]                              ; rcx = u64 at dst_buf[0]
mov  rdx, 0x4141414141414141                 ; expected 8 × 'A'
cmp  rcx, rdx
jne  sys_read_witness_fail
```

Proves: `rep_movsb` inside tmpfs_read copied source bytes into
the destination — confirms the full vfs→backend→memcpy chain
delivered the correct payload.

**Sub-test C**: `fd_table[3]` offset field == 100.
```asm
lea  rdi, [rip + _sys_read_witness_task]
mov  rsi, 3                                  ; fd
call fd_get                                  ; rax = current entry
mov  rcx, rax
shr  rcx, 16                                 ; rcx = offset (high 48)
cmp  rcx, 100
jne  sys_read_witness_fail
```

Proves: phase-5 offset advance landed correctly. Specifically:
`new_entry = entry + (100 << 16)`; when extracted via `shr 16`,
the top 48 bits equal 100. Also implicitly proves vnode_idx is
preserved (if `add r15, rcx` had overflowed into the low 16
bits, sub-test D would fail with a corrupted vnode reference).

**Sub-test D**: consecutive `sys_read(w, 3, dst_buf, 100)`
returns `0` (EOF).
```asm
lea  rdi, [rip + _sys_read_witness_task]
mov  rsi, 3                                  ; fd
lea  rdx, [rip + tmpfs_read_dst_buf]         ; buf_ptr
mov  rcx, 100                                ; len
call sys_read_body
cmp  rax, 0
jne  sys_read_witness_fail
```

Proves: (a) the offset now stored in fd_table (100, from sub-test C)
is picked up correctly by phase 3; (b) tmpfs_read's EOF check
(`offset >= size` at `r16-m2-006` §4.5) fires with `offset == size ==
100`; (c) vfs_read forwards the 0 return unchanged; (d) sys_read
propagates 0 to the caller (does not treat it as EOF-as-error).
Also implicitly: the offset advance is `0 + (0 << 16) = 0`, so the
fd_table entry is byte-identical after this read — proven by
sub-test C's post-condition holding under sub-test D's re-read.

**Sub-test E**: `sys_read(w, 2, dst_buf, 100)` returns `-EBADF`.
```asm
lea  rdi, [rip + _sys_read_witness_task]
mov  rsi, 2                                  ; fd = 2 (below stdio_lo=3)
lea  rdx, [rip + tmpfs_read_dst_buf]         ; buf_ptr (irrelevant on -EBADF)
mov  rcx, 100                                ; len (irrelevant)
call sys_read_body
mov  rcx, 0xFFFFFFFFFFFFFFF7                 ; -EBADF
cmp  rax, rcx
jne  sys_read_witness_fail
```

Proves: fd < 3 is unambiguously rejected with -EBADF — no
console fallback yet at R16.M3, no silent zero-return. The
`cmp fd, 3; jb sys_read_ebadf` branch fires early, before any
fd_get load.

### 5.3 Marker

On A, B, C, D, E all green:

```
R16 SYS READ OK
```

Emitted via `uart_puts` on `sys_read_ok_msg`. Fingerprint added
to all three R16.M3-tempo expected-output files, immediately
after the existing `R16 SYS CLOSE OK` line.

### 5.4 Witness assembly (complete block)

```asm
; ============================================================
; R16-M3-003 (#589): sys_read witness — preamble + 5 sub-tests
; ============================================================
sys_read_witness:
    ; --- Preamble: recover x_idx, re-seed data, open fd=3 ---
    mov  rdi, 1
    lea  rsi, [rip + witness_name_tmp]
    call tmpfs_lookup
    cmp  rax, 0
    je   sys_read_witness_fail
    mov  r12, rax                               ; r12 = tmp_idx

    mov  rdi, r12
    lea  rsi, [rip + witness_name_any]
    call tmpfs_lookup
    cmp  rax, 0
    je   sys_read_witness_fail
    mov  r13, rax                               ; r13 = x_idx

    mov  rdi, r13
    lea  rsi, [rip + tmpfs_write_src_buf]
    mov  rdx, 100
    xor  rcx, rcx
    call tmpfs_write
    cmp  rax, 100
    jne  sys_read_witness_fail

    lea  rdi, [rip + _sys_read_witness_task]
    lea  rsi, [rip + witness_path_tmp_x]
    xor  rdx, rdx
    xor  rcx, rcx
    call sys_open_body
    cmp  rax, 3
    jne  sys_read_witness_fail

    ; --- Sub-test A: sys_read(w, 3, dst_buf, 100) → 100 ---
    lea  rdi, [rip + _sys_read_witness_task]
    mov  rsi, 3
    lea  rdx, [rip + tmpfs_read_dst_buf]
    mov  rcx, 100
    call sys_read_body
    cmp  rax, 100
    jne  sys_read_witness_fail

    ; --- Sub-test B: dst_buf[0..8] == 0x4141414141414141 ---
    lea  r14, [rip + tmpfs_read_dst_buf]
    mov  rcx, [r14]
    mov  rdx, 0x4141414141414141
    cmp  rcx, rdx
    jne  sys_read_witness_fail

    ; --- Sub-test C: fd_table[3] offset field == 100 ---
    lea  rdi, [rip + _sys_read_witness_task]
    mov  rsi, 3
    call fd_get
    mov  rcx, rax
    shr  rcx, 16
    cmp  rcx, 100
    jne  sys_read_witness_fail

    ; --- Sub-test D: consecutive sys_read → 0 (EOF) ---
    lea  rdi, [rip + _sys_read_witness_task]
    mov  rsi, 3
    lea  rdx, [rip + tmpfs_read_dst_buf]
    mov  rcx, 100
    call sys_read_body
    cmp  rax, 0
    jne  sys_read_witness_fail

    ; --- Sub-test E: sys_read(w, 2, ...) → -EBADF ---
    lea  rdi, [rip + _sys_read_witness_task]
    mov  rsi, 2
    lea  rdx, [rip + tmpfs_read_dst_buf]
    mov  rcx, 100
    call sys_read_body
    mov  rcx, 0xFFFFFFFFFFFFFFF7
    cmp  rax, rcx
    jne  sys_read_witness_fail

    ; --- All green ---
    lea  rdi, [rip + sys_read_ok_msg]
    call uart_puts
    jmp  sys_read_witness_done

sys_read_witness_fail:
    lea  rdi, [rip + sys_read_fail_msg]
    call uart_puts

sys_read_witness_done:
```

### 5.5 String data — `tools/boot_stub.S`

Append after the sys_close success/fail messages (~line 617):

```asm
# R16-M3-003 (#589): sys_read witness success message
.global sys_read_ok_msg
.align 8
sys_read_ok_msg: .ascii "R16 SYS READ OK\n\0"

# R16-M3-003 (#589): sys_read witness failure message
.global sys_read_fail_msg
.align 8
sys_read_fail_msg: .ascii "R16 SYS READ FAIL\n\0"
```

New path string, inserted alongside the existing
`witness_path_*` block near line 645:

```asm
# R16-M3-003 (#589): sys_read witness path for /tmp/x
.global witness_path_tmp_x
.align 8
witness_path_tmp_x: .ascii "/tmp/x\0"
```

`tmpfs_write_src_buf`, `tmpfs_read_dst_buf`, `witness_name_tmp`,
and `witness_name_any` already exist. No other rodata changes.

### 5.6 Fingerprint files — marker insertion

The line `R16 SYS READ OK` inserts into all three R16.M3-tempo
fingerprint files immediately after the `R16 SYS CLOSE OK` line:

- `tests/r14b/expected-boot-r14b-loader.txt`
- `tests/r15/expected-boot-r15-ring3.txt`
- `tests/r15/expected-boot-r15-process.txt`

Contains-in-order matching means the addition is strictly
additive — no earlier line reorders. All existing 5-mode smoke
stages (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) that do not observe R16 markers stay
byte-identically green.

## 6. Alternatives considered / follow-ups (rejected or deferred)

### 6.1 Follow-up: sys_write body (#590) reuses this doc's arithmetic

**Proposal.** #590 (sys_write) follows the same shape as sys_read:
validate fd → get entry → decode → dispatch vfs_write → advance
offset → return bytes_written. The offset-advance arithmetic
(`new_entry = entry + (bytes_written << 16)`) is byte-identical.

**Not deferred — implicitly enabled.** #590 does not need to
re-derive the arithmetic; it copies this doc's phase 5 verbatim,
substituting `vfs_write` for `vfs_read`. Freezing the arithmetic
here means #590 lands with a two-instruction delta.

### 6.2 Distinguish vfs_read failure modes

**Proposal.** When `vfs_read` returns its `0xFFFFFFFFFFFFFFFF`
sentinel, distinguish "vnode_idx == 0" (fd_table corruption)
from "vnode_idx >= 256" (vnode-pool overflow) via different
errnos.

**Rejected.** Both failure modes are structurally unreachable
from `sys_read`'s call site given a valid entry sourced from
`sys_open` (which pulls vnode_idx from `vfs_open` → `vnode_alloc`,
both of which respect the `[1, 256)` range). The single -EIO
sentinel covers both defensively. Distinguishing them would
require sys_read to know vfs_read's internal failure taxonomy,
which is an abstraction leak.

### 6.3 Refcount consultation before dispatch

**Proposal.** After decoding vnode_idx, load the vnode's
refcount and reject if it's zero — catches "closed fd, entry
somehow still populated" bugs.

**Rejected.** The fd_table entry is the authoritative "fd
liveness" state at R16.M3 — a populated entry (non-zero) means
the fd is live. If refcount is zero on a populated entry, the
fd_table has a stale entry, which is a #588/#591 sys_close/
sys_dup2 correctness issue, not a sys_read enforcement site.
Adding the check here would triple the phase 3 instruction
count for a defense that belongs in the entry-producing
codepaths.

### 6.4 Zero-length read fast path in sys_read

**Proposal.** If `len == 0`, short-circuit before phase 2 —
skip fd_get, skip vfs_read, return 0 immediately. Matches
POSIX `read(2)` with count=0.

**Rejected — deferred to reviewer discretion.** POSIX `read(2)`
with `count == 0` still validates the fd. Skipping fd validation
would make `sys_read(w, 999, buf, 0)` return 0 instead of
-EBADF, which is a wrong answer. Skipping only vfs_read (not
validation) would save two calls but requires an extra
control-flow branch — the two-call path is <30ns at R16.M3
scale, not a hot path. tmpfs_read's own zero-length fast path
(`r16-m2-006` §4.2) already short-circuits the memcpy at the
right layer.

### 6.5 Locking around fd_get + fd_set (concurrent access)

**Proposal.** Bracket phase 2 + phase 5 with a per-task fd_table
lock so that concurrent sys_read/sys_write on the same fd don't
interleave their offset advances.

**Rejected for R16.M3.** No preemption during syscall execution
at R16.M3 (single-threaded kernel). R17's SMP-aware syscall path
adds a per-task fd_table spinlock; that lock will bracket the
entire sys_read body (not just phase 2/5) to make the read
atomic against concurrent close/dup2. Filed for R17.

### 6.6 Handle vfs_read short-return (bytes_read < len) specially

**Proposal.** When vfs_read returns `bytes_read < len` (short
read at EOF), some special-case handling — e.g., a follow-up
call to `vfs_read` to fill the rest, or a distinct return code.

**Rejected.** POSIX `read(2)` returns `bytes_read` verbatim on
short reads; retrying is the caller's job (or moot at EOF). The
short-read case is the whole point of returning bytes_read as
the primary value. `sys_read_body` treats short reads
identically to full reads — same phase 5 arithmetic, same
return.

### 6.7 In-body `test rax, rax` in place of `cmp rax, 0`

**Rejected.** Same as #588 §6.5: `test` is not a resolvable
mnemonic in paideia-as. Every zero-check in the codebase uses
`cmp reg, 0` — matches sys_close, sys_open, phys_alloc.

### 6.8 Extract vnode_idx and offset into dedicated callee-save regs

**Proposal.** Instead of morphing r15 (entry → new_entry) and
r14 (len → bytes_read), use r14 for vnode_idx (fresh), r15 for
offset (fresh), and keep the original entry in a sixth callee-
save reg.

**Rejected.** Would require a 6-push prologue (rbx, r12, r13,
r14, r15, plus one more), which lands `rsp % 16 == 8` misaligned
(6 pushes = 48 B; entry rsp%16==8 → 8-48 = -40 mod 16 = 8).
Would require a 7-push to realign, which uses an extra register
just for alignment — semantically empty. The morph-in-place at
a hard control-flow boundary (post-vfs_read) is a cleaner
resolution.

### 6.9 Return -EINVAL on `buf_ptr == 0` or `len == 0`

**Rejected.** POSIX `read(2)` allows `buf` to be any valid
pointer including 0 (implementation-defined; Linux returns
-EFAULT on a bad address at page-fault time, not at syscall
entry). At R16.M3 without copy_to_user, buf_ptr is a kernel
VA and callers are trusted. Rejecting `buf_ptr == 0` at the
syscall boundary would preempt the page-fault-based validation
that R17 will land uniformly.

## 7. Invariants

### 7.1 fd_entry encoding preserved (read side)

sys_read READS the encoding via `and rax, 0xFFFF` (vnode_idx)
and `shr rax, 16` (offset). It WRITES a new entry via
`add r15, (bytes_read << 16)` — a purely additive update to the
high 48 bits. The low 16 bits (vnode_idx) are byte-identical
pre- and post-read. #587 §3.2's `entry = vnode_idx | (offset <<
16)` remains the single source of truth.

Verification: sub-test D reads at offset 100 with size 100 →
returns 0 → new_entry = entry + (0 << 16) = entry. If the
vnode_idx bits had been clobbered by phase 5, sub-test D would
fail because vfs_read would receive a bogus vnode_idx and
return the sentinel.

### 7.2 Offset advance is monotonic on success

Every successful sys_read advances the fd_table offset by
`bytes_read >= 0`. Because `bytes_read` is unsigned, the offset
is monotonically non-decreasing across successive reads on the
same fd. Underflow is structurally impossible — no branch of
phase 5 subtracts from the offset.

Consequence: a caller can implement "read to end of file" by
looping `while (sys_read(fd, buf, N) > 0) { ... }` — the loop
terminates on the first EOF-yielding 0-return, with the offset
stably at `size`.

### 7.3 Zero-return on EOF is idempotent

`sys_read` at `offset >= size` returns 0. The phase 5 arithmetic
adds `0 << 16 = 0` to the entry, leaving it byte-identical.
Consecutive EOF reads are idempotent: same result, no fd_table
mutation. Verified transitively by sub-test C (post-read
offset=100) followed by sub-test D (re-read at offset=100
returns 0 and does not corrupt the entry).

### 7.4 sys_read_body register discipline

- rbx, r12, r13, r14, r15 pushed in prologue, popped in
  epilogue. Any nested call MUST callee-save-preserve them.
  Currently verified for `fd_get` (leaf, no clobbers), `fd_set`
  (leaf, no clobbers), `vfs_read` (5-push prologue explicitly
  preserves rbx/r12/r13/r14/r15 per `vfs_read.pdx:62-66`).
- rax, rcx, rdx, rsi, rdi are caller-save scratch. Content
  across a nested call is undefined except for the callee's
  documented return in rax.
- r14 and r15 morph semantically at the post-vfs_read boundary
  (§3.2). Neither morph loses information — `len` isn't needed
  after vfs_read; `entry` is transformed monotonically into
  `new_entry` via an in-place add. Documented in the
  justification comment (§3.6).

### 7.5 Buffer non-mutation on failure

On -EBADF (fd validation failure or slot free), no nested call
that could touch the buffer has executed yet — `buf_ptr[0..len]`
is byte-identical to pre-call. On -EIO (vfs_read sentinel),
`vfs_read` returns before dispatching into `vops_read` (per
`r16-m1-008` §4.5 — the failure branch runs after prologue but
before any backend dispatch), so `buf_ptr[0..len]` is untouched
in that path too.

Verified by inspection: no `mov [r13 + ...]` in sys_read_body.

### 7.6 Trust boundary — no downstream bounds check

Once `sys_read_body` has validated `fd in [3, 32)` and confirmed
`entry != 0`, all three downstream primitives (`fd_get`,
`fd_set`, `vfs_read`) are called with values that pre-satisfy
their own contracts:

- `fd_get`/`fd_set` receive `fd < 32`.
- `vfs_read` receives `vnode_idx = entry & 0xFFFF`. Under R16.M3
  invariants, entry's low 16 bits come from `vnode_alloc` which
  is bounded by `VNODE_MAX = 256`. `vfs_read` re-validates
  (`cmp rbx, 0`, `cmp rbx, 256`) but never trips those branches
  in this call site.

The doubly-validated pattern (sys_read pre-guards, vfs_read
re-guards) is defense in depth: if a future R17 fd_table
producer bypasses the encoding contract, `vfs_read`'s bound
check catches the escape.

## 8. Cross-cutting risks

- **Encoding drift across R16.M3 issues.** #590 (sys_write)
  will independently implement the identical offset-advance
  arithmetic. If it substitutes `shl rcx, 8` (byte-count shift
  instead of bit-count) or writes to the low 16 bits, the
  vnode_idx corrupts and subsequent reads fail. Mitigation:
  #590's design doc must copy this doc's phase 5 verbatim,
  and #590's witness must include an equivalent of sub-test D
  (post-write, sys_read at offset returns freshly written
  bytes). Enforced by reviewer discipline; no automated
  invariant.
- **Offset overflow if tmpfs cap grows.** At R16.M3, `bytes_read <=
  65536` (tmpfs single-page bound). If a future backend (or
  the R16.M2 multi-page follow-on) grows the max return past
  2^32, `bytes_read << 16` could exceed 2^48 and overflow into
  a wider offset field. Mitigation: the u48 offset ceiling is
  256 TiB — even a maxed-out multi-page tmpfs can't touch it
  in a single call. When R17 widens fd_entry to 24 bytes
  (#549's reserved padding), the 48-bit ceiling dissolves.
  Filed as design-doc consumer of that widening.
- **Concurrent close during read.** R16.M3 has no preemption
  during syscall, so this is impossible. R17 SMP needs a
  per-task fd_table spinlock; see §6.5.
- **vfs_read contract drift** (mirror of #587 §8, #588 §8).
  If vfs_read changes its failure sentinel (e.g., grows an
  errno set), sys_read's `cmp rax, 0xFFFFFFFFFFFFFFFF; je
  sys_read_eio` would miss the new sentinel and forward
  garbage as bytes_read. Mitigation: vfs_read's contract is
  documented at `r16-m1-008` §37-38 and stable; any drift
  would ripple through this doc's §3.4 in review.
- **-EBADF via wrong branch on huge unsigned fd.** Same as
  #588 §8: unsigned semantics catch `fd = 0xFFFFFFFFFFFFFFFF`
  via `cmp rsi, 32; jae` (fires correctly). Signed-semantics
  regression would misclassify. Verified by the compare
  discipline in sub-test E's mirror in future test additions.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/syscall/handlers/sys_read.pdx` (new)       | ~110       |
|   - module boilerplate + constants + justification          |   ~50      |
|   - `sys_read_body` (~35 instructions)                      |   ~45      |
|   - inline comments                                         |   ~15      |
| `src/kernel/boot/kernel_main.pdx` (witness block + slab)    | ~140       |
|   - `_sys_read_witness_task` declaration                    |    ~5      |
|   - preamble + 5 sub-tests, fail/success labels             |  ~110      |
|   - inline comments                                         |   ~25      |
| `tools/boot_stub.S` (2 messages + 1 path string)            | ~12        |
| 3 expected-output fingerprint files (1 marker each)         | ~3         |
| `design/kernel/r16-m3-003-sys-read.md` (this doc)           | (this)     |
| **Total executable / testing / test-data**                  | **~265**   |

Executable code path: ~110 LOC. Witness + fingerprint: ~155 LOC.

## 10. Tractability

**HIGH.**

- **No paideia-as encoder gap.** Every instruction used has
  landed precedent (§2.3). `shl r64, imm8` is proven at
  `mount.pdx:178` and multiple other sites.
- **Composition of five already-witnessed primitives**
  (`fd_get`, `fd_set`, `vfs_read`, `tmpfs_lookup`, `tmpfs_write`,
  plus `sys_open_body` in the preamble). The only novel logic
  is the offset-advance arithmetic (one `mov + shl + add`
  triple).
- **Witness storage is a single `.bss` blob** (mirror of
  #587's `_sys_open_witness_task`) — no allocator dependency,
  no CR3 flip, no interrupt discipline, no scheduler init
  dependency.
- **Marker line is contains-in-order** — no fingerprint
  reorder risk across other smoke modes.
- **Composes cleanly with #587 (packed encoding) and #588
  (fd validation idiom)** — no new invariants, no encoding
  contract drift.
- **Sizing (~265 LOC total)** matches recent R16.M3 issues
  (#587: ~196 LOC; #588: ~200 LOC) — slightly larger due to
  the multi-step preamble (tmpfs_lookup chain + tmpfs_write
  seed) and the offset-advance arithmetic.
- **No cross-repo escalation risk** (no paideia-as encoder
  growth).

Estimated implementation time: **one workerbee session**.
Estimated risk of regressing an existing smoke mode:
**near-zero** (purely additive: one new emit line, one new
witness block, one new .pdx module, one new path string).

**Known follow-ups (do NOT block #589's landing)**:

- **sys_write (#590)** — the write-side mirror. Reuses this
  doc's phase 5 arithmetic verbatim.
- **SYSCALL entry batch-wire** — install `sys_read_body`
  into the syscall dispatch table so ring-3 code can call it.
  Lands with the R16.M3 batch-wire after all handlers compose.
- **Multi-page vfs_read** — R16.M2's tmpfs_read single-page
  constraint (`r16-m2-006` §4.7) is transparent to sys_read
  (short-return semantics propagate correctly), but a caller
  that requests > 4 KiB from a page-crossing offset today
  gets -EIO. Follow-on tmpfs_read multi-page issue lifts
  this without touching sys_read.
- **R17 SMP concurrent-access lock** (§6.5) — per-task
  fd_table spinlock brackets sys_read atomically against
  concurrent close/dup2.
- **stdio dispatch for fd 0** at R16.M5 — TTY milestone
  extends fd 0 to console input; the current -EBADF branch
  narrows to `fd > 0` at that point.

## 11. References

- Issue: paideia-os#589
- Milestone: paideia-os R16.M3 (fd table + open/read/write/close/dup2)
- Prereq issues: #587 (sys_open packed encoding freeze),
  #588 (sys_close fd validation idiom), #577 (vfs_read),
  #586 (tmpfs vops wire), #584 (tmpfs_read), #583 (tmpfs_write),
  #581 (tmpfs_lookup), #549 (fd_table embed)
- Sibling / successor issues: #590 (sys_write), #591 (sys_dup2)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 13, item 3
- Master plan: `design/milestones/r14b-master-plan.md` §M19 (VFS)
- Prior-art body pattern: `src/kernel/core/syscall/handlers/sys_close.pdx`
  (#588) — fd validation prologue frozen there is copied here verbatim
- Prior-art encoding pattern: `src/kernel/core/syscall/handlers/sys_open.pdx`
  (#587) — packed fd_entry encoding this doc reads and writes
- Prior-art dispatcher pattern: `src/kernel/core/fs/vfs_read.pdx`
  (#577) — the 4-arg dispatcher this doc calls
- Prior-art witness pattern: `design/kernel/r16-m3-002-sys-close.md`
  §5 — `_*_witness_task` `.bss` blob + sub-tests A–E + marker line
  + fingerprint insertion

---

## Amended by R17-M0-665

**Change**: Witness preamble pre-wiring removed. Manual ops_ptr and backend_ptr wiring for root, /tmp, and /tmp/x vnodes is no longer needed.

**Rationale**: 
- R17-M0 lands vnode_cache_or_alloc in path_resolve's regular_lookup block.
- mount() now wires the root vnode at allocation time.
- path_resolve now allocates and wires vnodes on-demand for all non-root components.

**Result**: Witness code is cleaner (60+ LOC preamble removed), and sys_read now correctly relies on the VFS layer's own vnode allocation, not pre-wiring hacks. Sub-test logic unchanged; execution path flows through sys_open → path_resolve → vnode_cache_or_alloc instead of pre-wired slots.
