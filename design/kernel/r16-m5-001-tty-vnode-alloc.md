---
issue: 602
milestone: R16.M5 (TTY / cooked line discipline)
subsystem: 15 — TTY / cooked line discipline
topic: tty_init — allocate the first TTY vnode from _vnode_pool and publish it as _tty0
prereq:
  - "#571 (R16.M1-002 vnode_pool + vnode_alloc — LANDED; provides the leaf `vnode_alloc()` and `vnode_slot(idx)` primitives this issue calls exactly once and reads exactly once from the boot witness)"
  - "#570 (R16.M1-001 vnode struct layout freeze — LANDED; pins VNODE_TYPE_CHRDEV=4, VNODE_TYPE_OFFSET=0, VNODE_FLAGS_OFFSET=1, VNODE_REFCOUNT_OFFSET=4, VNODE_PARENT_IDX_OFFSET=8, VNODE_NAME_SLOT_OFFSET=10, VNODE_OPS_PTR_OFFSET=24, VNODE_BACKEND_PTR_OFFSET=32, VNODE_IDX_NONE=0xFFFF, VNODE_FLAG_VALID=0x01)"
  - "#601 (R16.M4-007 uart_rx_smoke — LANDED; last R16.M4 witness. tty_init and its witness insert immediately after `uart_rx_smoke_witness_done:` in kernel_main.pdx and before the R14b-m5-002 `wrmsr` GS_BASE setup at line 4194)"
blocks:
  - "#603 (r15-m5-002 tty-vops-table — wires `_tty0.ops_ptr` (+24) to `&_tty_vops`; this issue leaves the slot at 0 with a null-guard justification per the mount-table precedent, see §3.4)"
  - "#604 (r15-m5-003 tty line buffer — sibling `.bss` allocation; independent of this issue)"
  - "#605..#607 (r15-m5-004/005/006 tty process_input / read / write — all reach the tty via _tty0)"
  - "#608 (r15-m5-007 connect-tty-to-init-fd012 — init's fd_table[0/1/2] = _tty0's vnode idx; every sys_write(1, …) from init composes through the vnode this issue publishes)"
  - "#609 (r15-m5-008 tty smoke — R16.M5 CLOSER; asserts the end-to-end line-discipline path this issue rooted)"
touching:
  - src/kernel/core/tty/init.pdx                            (new file — new directory; ~55 LOC incl. justification)
  - src/kernel/boot/kernel_main.pdx                         (witness block; ~50 LOC after uart_rx_smoke_witness_done at line 4191)
  - tools/boot_stub.S                                       (2 rodata additions: ok_msg, fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt                (marker: `R16 TTY VNODE OK`)
  - tests/r15/expected-boot-r15-ring3.txt                   (marker)
  - tests/r15/expected-boot-r15-process.txt                 (marker)
  - design/kernel/r16-m5-001-tty-vnode-alloc.md             (this doc)
related:
  - design/kernel/vfs-layout.md                             (#570 — offset + type-discriminant freeze; single source of truth for the numbers this issue's justification cites)
  - src/kernel/core/fs/vnode_pool.pdx                       (#571 — provides vnode_alloc + vnode_slot; contract already vetted for the null-return path this issue guards against)
  - src/kernel/core/fs/mount.pdx                            (#574 — structural precedent for "allocate vnode + set type + defer ops_ptr wiring to a later issue"; §3.4 below reproduces that pattern verbatim for tty)
  - src/kernel/core/fs/tmpfs/init.pdx                       (#580 — structural precedent for a "call alloc → initialize frozen offsets → store idx to a boot-published slot" leaf boot init; used as the field-write idiom template)
  - design/milestones/r14b-tactical-plan.md                 §Subsystem 15 (line 1552) — TTY design contract; item 1 is this issue
---

# R16-M5-001 — `tty_init`: alloc the first TTY vnode and publish it as `_tty0` (#602)

## 1. Scope

Land the first R16.M5 subsystem-15 issue: a boot-time leaf initializer
that allocates one vnode from `_vnode_pool`, marks it as a
character-device vnode (`VNODE_TYPE_CHRDEV = 4`), and publishes its
index into a new `.bss` slot `_tty0`. Downstream R16.M5 issues
(#603..#609) attach the ops table, the line buffer, the ISR feed,
and finally the fd-table wire — all through this vnode.

```
tty_init() -> u64
    side effects: {mem}
    postcondition #1: _vnode_pool[<returned idx>].type   == VNODE_TYPE_CHRDEV (4)
    postcondition #2: _vnode_pool[<returned idx>].flags  == VNODE_FLAG_VALID  (1)
    postcondition #3: _vnode_pool[<returned idx>].refcount == 1
    postcondition #4: _vnode_pool[<returned idx>].parent_idx  == VNODE_IDX_NONE (0xFFFF)
    postcondition #5: _vnode_pool[<returned idx>].name_slot_idx == VNODE_IDX_NONE (0xFFFF)
    postcondition #6: _vnode_pool[<returned idx>].ops_ptr      == 0 (deferred to #603)
    postcondition #7: _vnode_pool[<returned idx>].backend_ptr  == 0 (permanent for tty)
    postcondition #8: _tty0 == <returned idx>  (u16 in low 16 bits of the u64 slot)
    return: rax = <returned idx> on success; rax = 0xFFFF on vnode_alloc OOM
```

The witness confirms postconditions #1, #3, and #8 directly (three
sub-tests A/B/C — see §5). Postconditions #2/#4/#5/#6/#7 are
by-construction from the fresh-slot zero-init discipline (see §3.5)
and are not separately asserted.

### 1.1 Correction to the parent brief — CHRDEV = 4, not 5

The originating architect brief lists `type=CHRDEV (5)` as the value
to write. **That is incorrect.** Per
`design/kernel/vfs-layout.md` §3 (frozen at #570):

```
VNODE_TYPE_FREE     = 0
VNODE_TYPE_REG      = 1
VNODE_TYPE_DIR      = 2
VNODE_TYPE_SYMLINK  = 3
VNODE_TYPE_CHRDEV   = 4      ← this issue uses 4
VNODE_TYPE_BLKDEV   = 5      ← the brief's "5" is BLKDEV, wrong for TTY
VNODE_TYPE_FIFO     = 6
VNODE_TYPE_SOCK     = 7
```

TTY is a character device (unbounded stream, per-byte semantics, no
block cache) — not a block device. The value written here is **4**,
matching `VNODE_TYPE_CHRDEV` as pinned by #570. Sub-test C asserts
`type == 4` and would fail loudly on a wrong-value regression.

### 1.2 What this issue proves

- **`vnode_alloc()` composes with a persistent kernel structure.**
  Every prior vnode consumer (mount table's root vnode at #574;
  vfs_open witness scratch vnodes; vops witness fixtures) has either
  been transient (allocated + freed inside a witness) or has lived
  behind an already-wired pointer (mount table's slot 0). This
  issue is the first "allocate + never free + publish via a
  dedicated `.bss` handle" pattern. Sub-tests A/B jointly assert
  that `vnode_alloc`'s return value survives the write to `_tty0`
  and is retrievable via a `mov rax, [rip + _tty0]` in a later
  witness.
- **The 64-byte slot layout applies to CHRDEV vnodes as well as
  DIR / REG vnodes.** Prior R16 witnesses have exercised the layout
  for `VNODE_TYPE_DIR` (mount root, tmpfs root) and `VNODE_TYPE_REG`
  (tmpfs create/read/write); this issue is the first live
  allocation with `VNODE_TYPE_CHRDEV = 4` written to +0. Sub-test C
  probes the same +0 byte with the same `mov cl, [rax + 0]; and rcx,
  0xFF` idiom that tmpfs's own `type == DIR` sub-tests already use
  (kernel_main.pdx:2320-2322), proving the CHRDEV discriminant
  round-trips through the frozen layout.
- **The `_tty0` slot is a single u64 word in `.bss` that stores a
  u16 vnode index (zero-extended).** Same convention as
  `_tmpfs_root_idx` and the mount table's per-entry root_vnode_idx
  field. No new storage discipline invented.

### 1.3 What this issue deliberately does NOT do

- **No vops table.** `_tty0.ops_ptr` (+24) stays at 0. Wired at
  #603 (`_tty_vops` at `src/kernel/core/tty/vops.pdx`). The
  dispatcher discipline in `src/kernel/core/fs/vops.pdx` (all seven
  `vops_*` primitives) already handles `ops_ptr == 0` by returning
  `VOPS_ERR_NOT_SUPPORTED` — the "half-live" vnode this issue ships
  is safe to hold because no path-resolver or fd-table entry
  references it yet (see §3.4 for the invariant argument). This
  mirrors mount.pdx:168 (`// ops_ptr (+24) deliberately left at
  zero`) verbatim — the root vnode allocated at #574 lived with
  `ops_ptr == 0` until #580 (`tmpfs_init` follow-on) wired
  `_tmpfs_vops`. Same pattern here: alloc first, wire ops later,
  no consumer in between.
- **No line buffer allocation.** `_tty_line_buf[256]` and its head
  / tail / complete-line-flag words are #604's concern. This issue
  is a substrate landing — the vnode is the anchor that #604's
  buffer will be reached through (`_tty0.backend_ptr` stays 0 for
  tty because the line buffer is a well-known static, not a per-
  vnode dynamic pointer; see §3.6).
- **No devfs / `/dev/tty0` path binding.** Path-resolver visibility
  of `_tty0` is deferred. R16.M5 does not ship a devfs backend;
  init's fd 0/1/2 are wired directly to `_tty0` at #608. The
  vnode's `name_slot_idx` stays `VNODE_IDX_NONE` (0xFFFF) at this
  landing — the parent brief's "AC: fixture vfs_open("/dev/tty0")
  returns _tty0" belongs to #603 (tty_vops_wire) which is where the
  devfs binding lives.
- **No IRQ enable / ISR feed.** R16.M4 already lands the RX ring
  and its ISR (#597/#598/#599/#600). Feeding bytes into a per-tty
  line buffer happens at #605 (`tty_process_input` — the notify
  consumer). This issue does not touch UART registers.
- **No `.text` code path that dispatches through `_tty0` yet.**
  The only kernel-side reference to `_tty0` at this landing is
  the witness block itself. Every downstream consumer waits for
  its own issue (#603 vops; #605 process_input; #608 init fd wire).
  No smoke mode observes `_tty0` other than through the
  fingerprint marker this issue emits.
- **No `sys_ioctl` / termios / mode bits.** Cooked-mode semantics
  are entirely #604/#605's concern (line-buffer handling, echo,
  \r→\n translation). The vnode carries no per-mode state; that
  data lives in the line buffer's structure.
- **No re-entrancy guard.** `tty_init` is called exactly once at
  boot, from a witness in kernel_main.pdx. Re-entrancy is
  structurally impossible on a single CPU during boot (no
  interrupts yet enabled at this witness point — the R16.M4
  notify-cap witness fired earlier, but its ISR is gated on IRQ 4
  and no RX byte is queued during the boot fingerprint window).

## 2. Prereq check

### 2.1 What is in place

| Primitive                     | Location                                                   | Contract used                                                                                                        |
|-------------------------------|------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| `vnode_alloc()`               | `core/fs/vnode_pool.pdx:57-97` (#571, LANDED)              | Returns free vnode idx in `rax` (u16 semantics) on success; returns 0xFFFF on OOM. Leaf; no callee-save touched.       |
| `vnode_slot(idx)`             | `core/fs/vnode_pool.pdx:148-159` (#571, LANDED)            | Returns `&_vnode_pool[idx * 64]` in `rax`. Leaf; no bounds check; caller has already validated via alloc round-trip.  |
| `_vnode_pool` `.bss` slab     | `core/fs/vnode_pool.pdx:48` (#571, LANDED)                 | 16 KiB, @align(64); a freshly alloc'd slot is zero-filled (either by .bss zero-init on first use, or by vnode_free's 8× unrolled zero-store on reuse). |
| `mov [addr + imm], reg` (u64) | `core/fs/mount.pdx:165-167`, ubiquitous                    | Full-word store proven at every vnode init call site.                                                                 |
| `mov_b`, `mov_w`              | `core/fs/tmpfs/init.pdx:53,57,64,69` (#580, LANDED)        | Narrow stores for u8 / u16 fields (encoder-supported per fd_table + tmpfs precedent).                                 |
| `[rip + sym]` addressing      | Ubiquitous                                                 | RIP-relative addressing for `_tty0`, `tty_ok_msg`, `tty_fail_msg`.                                                    |
| `_tmpfs_root_idx`-style slot  | mount.pdx `_mount_table` (#574)                            | Precedent for a u16 vnode idx stored in a u64-aligned `.bss` slot, zero-extended on load.                             |

### 2.2 What is NOT in place

- **No `src/kernel/core/tty/` directory.** The tactical plan
  (§Subsystem 15, items 1..8) sites every tty module under
  `core/tty/`. Only the sibling `core/uart/` exists today (created
  by #595). This issue creates `core/tty/` — mirroring how #595
  created `core/uart/` before its 4-instruction leaf. All of
  #603..#609 will populate this same directory.
- **No `_tty0` symbol.** Grep across `src/` and `tools/` confirms
  no prior reference. This issue is its sole allocator + publisher.
  Downstream `.pdx` modules will read it via `mov rax, [rip +
  _tty0]`; downstream `.pdx` modules may `and rax, 0xFFFF` to
  extract the u16 index.
- **No `_tty_vops` symbol.** Reserved for #603. This issue's
  design references it by name only — the `ops_ptr` (+24) slot on
  the freshly allocated vnode stays 0 in the meantime (§3.4).
- **No `tty_ok_msg` / `tty_fail_msg` symbols in `boot_stub.S`.**
  Added alongside the R16.M4 witness strings (see §5.4).

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent:

| Mnemonic                        | Proven at                                                                    |
|---------------------------------|------------------------------------------------------------------------------|
| `call sym` (direct)             | Ubiquitous.                                                                  |
| `cmp rax, imm16`                | `core/fs/vnode_pool.pdx:94` (`mov rax, 0xFFFF` sentinel + caller `cmp`).      |
| `je` / `jne` / `jmp`            | Ubiquitous.                                                                  |
| `lea r64, [rip + sym]`          | Ubiquitous.                                                                  |
| `mov [rax + imm], reg` (u64)    | `core/fs/mount.pdx:165` — full-word init store on the fresh root vnode.       |
| `mov_b [reg + imm], reg`        | `core/fs/tmpfs/init.pdx:53,57` — narrow store for u8 type/flags fields.       |
| `mov_w [reg + imm], reg`        | `core/fs/tmpfs/init.pdx:64,70` — narrow store for u16 refcount/parent_idx.    |
| `mov [rip + sym], reg` (u64)    | Ubiquitous for `.bss` publish (`_tmpfs_root`, `_idle_tcb`, etc.).             |
| `and rcx, 0xFFFF`               | `core/fs/mount.pdx:173-175` — u16 sanitization idiom.                        |
| `ret`                           | Ubiquitous.                                                                  |

No SIB, no REX.B-extended-base, no imm64. **Cross-repo escalation
not needed.**

## 3. Design

### 3.1 File and module structure

New file: `src/kernel/core/tty/init.pdx`. Creates the
`src/kernel/core/tty/` directory (empty until this landing) that
#603..#609 will populate:

```
src/kernel/core/tty/
    init.pdx        <-- THIS ISSUE (#602) — vnode alloc + _tty0 publish
    vops.pdx        (#603 — _tty_vops table + devfs binding)
    line_buffer.pdx (#604 — 256-char line buffer + head/tail/complete flag)
    process_input.pdx (#605 — echo + \r→\n + backspace + accumulate)
    read.pdx        (#606 — blocking cooked-mode read)
    write.pdx       (#607 — \n → \r\n translation)
```

Module name: `Tty`. Public exports: `_tty0` (u64 storage) and
`tty_init` (nullary function).

### 3.2 Storage layout — one 8-byte `.bss` slot

```pdx
pub let mut _tty0 : u64 = 0
```

- `u64` alignment matches every other vnode-idx handle in the
  kernel (`_tmpfs_root_idx`, mount table entries' packed root_idx
  field, task_struct's fd_table entries). No `@align(N)` decorator
  needed — natural `u64` alignment is 8 B and matches load / store
  requirements.
- **Initial value 0** doubles as the "not yet initialized"
  sentinel. `_vnode_pool` slot 0 is reserved (per #570 §7.2,
  frozen; `vnode_alloc` never returns 0), so `_tty0 == 0` is
  unambiguously the "pre-init" state — no live vnode idx can
  collide with the sentinel. Sub-test B relies on this
  disambiguation.
- **Only the low 16 bits carry information.** The upper 48 bits
  are always zero. Callers who need only the u16 idx do
  `and rax, 0xFFFF` after `mov rax, [rip + _tty0]` — mirroring
  the mount table's per-entry read discipline
  (`core/fs/mount.pdx:280`).

### 3.3 `tty_init` — body

```asm
; ================================================================
; tty_init() -> u64
;   Allocate one vnode from _vnode_pool. Mark it CHRDEV. Store its
;   index in _tty0. Return the idx.
;
;   Success: rax = idx in [1, 255]  ; also written to _tty0
;   Failure: rax = 0xFFFF           ; _tty0 stays 0 (unchanged from .bss)
;
;   Effects: {mem}   Capabilities: {}
; ================================================================
tty_init:
    call vnode_alloc                     ; rax = vnode idx, or 0xFFFF on OOM
    cmp  rax, 0xFFFF
    je   tty_init_oom

    ; --- Persist idx in _tty0 (before touching slot fields, so that
    ; ---   a fault during slot-init still leaves _tty0 discoverable
    ; ---   for panic-time forensics; safe because no consumer of
    ; ---   _tty0 exists at this landing).
    mov  r8, rax                         ; r8 = saved idx (survives nested call)
    mov  [rip + _tty0], rax              ; write full u64; upper 48 bits = 0

    ; --- Compute &_vnode_pool[idx] via vnode_slot ---
    mov  rdi, rax
    call vnode_slot                      ; rax = &vnode
    ; rax = base pointer; r8 = idx (unchanged; vnode_slot is leaf, no callee-save touched)

    ; --- type = VNODE_TYPE_CHRDEV (4) at +0 (u8) ---
    mov  rcx, 4
    mov_b [rax + 0], rcx

    ; --- flags = VNODE_FLAG_VALID (1) at +1 (u8) ---
    mov  rcx, 1
    mov_b [rax + 1], rcx

    ; --- refcount = 1 at +4 (u16) ---
    ; The vnode is now "held" by _tty0 itself; each of init's
    ; fd 0/1/2 wires at #608 will bump this by one more.
    mov  rcx, 1
    mov_w [rax + 4], rcx

    ; --- parent_idx = VNODE_IDX_NONE (0xFFFF) at +8 (u16) ---
    ; TTY is a detached vnode — no parent directory at #602.
    ; Devfs binding (which would set this to the /dev DIR idx) is #603's
    ; concern.
    mov  rcx, 0xFFFF
    mov_w [rax + 8], rcx

    ; --- name_slot_idx = VNODE_IDX_NONE (0xFFFF) at +10 (u16) ---
    ; Unnamed at #602 (mirrors root/pipe vnodes per vfs-layout §7.3).
    ; Named at #603 when devfs registers "tty0" in _name_slab.
    mov_w [rax + 10], rcx                ; rcx still 0xFFFF

    ; --- Other fields (mode, link_count, uid, gid, size, ops_ptr,
    ; --- backend_ptr, reserved) stay 0 from fresh-slot zero-init.
    ; --- ops_ptr (+24) is deliberately 0 — #603 wires _tty_vops. §3.4.
    ; --- backend_ptr (+32) stays 0 permanently for tty — §3.6.

    mov  rax, r8                         ; return idx (was in _tty0's low 16)
    ret

tty_init_oom:
    ; vnode_alloc returned 0xFFFF; _tty0 is untouched (stays 0);
    ; rax is already 0xFFFF from the alloc return — just propagate.
    ret
```

**Instruction count**: ~18 body + `ret`. Two nested calls
(`vnode_alloc`, `vnode_slot`) so this is NOT a leaf function.
See §3.7 for the register/stack discipline.

### 3.4 The "ops_ptr = 0 for a half-live vnode" invariant argument

`design/kernel/vfs-layout.md` §7.5 states:

> Every vnode with `type != VNODE_TYPE_FREE` has a valid `ops_ptr`.
> `vnode_alloc` sets it before setting `type`; `vnode_free` clears
> `type` before clearing `ops_ptr`.

Strictly read, setting `type = CHRDEV` at this issue with
`ops_ptr = 0` would break §7.5. Two mitigations reconcile the
landing with the freeze:

1. **The mount-table precedent already exercises this pattern.**
   `core/fs/mount.pdx:161-168` allocates the root vnode, sets
   `type = VNODE_TYPE_DIR`, and explicitly leaves `ops_ptr = 0`
   with the comment `// ops_ptr (+24) deliberately left at zero`.
   The root vnode lives in that state from the moment mount()
   returns until R16.M2's `tmpfs_init` follow-on wires
   `_tmpfs_vops`. No panic, no null-deref — because no consumer
   references the vnode in the interval.
2. **The vops dispatchers already tolerate `ops_ptr == 0`.**
   `core/fs/vops.pdx:66-86` (`vops_read`), and the six sibling
   dispatchers, all null-check `ops_ptr` at +24 and return
   `VOPS_ERR_NOT_SUPPORTED` (0xFFFFFFFFFFFFFFFF) on null. Any
   accidental dispatch through the half-live tty vnode would fail
   loudly, not corrupt state.

**Coverage of the "no consumer references the vnode in the
interval" precondition at #602:**

| Potential consumer         | Reference exists at #602 land?                                                                 |
|----------------------------|------------------------------------------------------------------------------------------------|
| `path_resolve`             | No — `_tty0` is not in the mount table, not a child of `/`, not in any dentry chain.           |
| Any fd_table entry         | No — task_new (#552) leaves fd_table zero-filled; init has no fd 0/1/2 wire until #608.        |
| Notification cap (#600)    | No — the RX notify cap wakes a specific task; no task blocks on tty yet.                       |
| Direct callsite by name    | Only the witness in kernel_main.pdx (this issue). The witness never dispatches through vops.  |
| Any smoke-mode probe       | No — the fingerprint reads `_tty0` for the marker, not for a dispatch.                          |

So the half-live window from #602 landing to #603 landing (and
possibly #608 landing before init actually dispatches) has zero
consumers other than the witness block itself. §7.5 is
functionally upheld even though textually strained. #603 will
close the gap with a `mov [rip + _tty0]; ... mov [_vnode +
24], &_tty_vops` sequence in `tty_vops_init` — after which the
freeze is fully re-satisfied.

This same textual-strain argument was accepted at #574 landing;
this issue reuses it verbatim. If a future policy tightens §7.5
to a runtime invariant (e.g., a boot-time sweep asserting every
non-FREE vnode has non-null ops_ptr), that sweep would run **after**
#603 lands and would find `_tty0`'s ops_ptr populated — no
regression.

### 3.5 Fresh-slot zero-fill invariant

`vnode_alloc` returns an idx `i`; the slot `_vnode_pool[i * 64 ..
(i+1) * 64]` is guaranteed zero at return, for two independent
reasons:

1. **`.bss` zero-init** — `_vnode_pool` is
   `uninit @align(64)`; the ELF loader zeroes `.bss` at load time
   (contract used by every kernel witness that assumes a
   pristine slot on first alloc). On the very first `vnode_alloc`
   invocation (mount witness at #574), this is the only reason
   the slot is zeroed.
2. **`vnode_free`'s 8× unrolled zero-store** —
   `core/fs/vnode_pool.pdx:130-139` writes eight `xor rax; mov
   [r8+N], rax` clearing the entire 64 B on free. So any slot
   that has been through an alloc/free cycle is re-zeroed by
   `vnode_free`.

At the point in boot where `tty_init` runs (post-M4-007, so
post-all-M1..M4-witnesses), every witness that allocated a scratch
vnode has either freed it (`vfs_open` / `vfs_close` sub-tests) or
kept the reference (mount slot 0). The pool state is: slot 0
reserved, slot 1 = tmpfs root vnode, remaining slots free +
zero-filled. `tty_init`'s alloc gets a zero-filled slot; the
narrow writes at §3.3 set exactly the five fields called out;
every other field stays at its zero default.

Postconditions #2 (`flags == VNODE_FLAG_VALID`), #4 (`parent_idx
== 0xFFFF`), #5 (`name_slot_idx == 0xFFFF`), #6 (`ops_ptr == 0`),
#7 (`backend_ptr == 0`) are therefore **by-construction** — either
because we wrote them explicitly (flags, parent_idx, name_slot_idx),
or because they were 0 from the fresh-slot invariant and we
didn't touch them (ops_ptr, backend_ptr).

Sub-tests only assert postconditions #1, #3, #8 (the writes with
non-obvious values). Adding sub-tests for zero-init fields would
be pedantry — they hold or the vnode_pool contract itself is
broken, in which case a hundred prior witnesses would have failed
first.

### 3.6 Why `backend_ptr` (+32) stays 0 permanently for tty

`design/kernel/vfs-layout.md` §2 documents `backend_ptr` as
"backend-owned opaque":

> tmpfs: pointer to inline-block header.
> devfs: dev_t packed as `(major<<32) | minor`.
> procfs: task idx.

For TTY, no per-vnode backend state exists — there is exactly
one TTY at R16.M5 (single-console, no multi-terminal support),
so:

- The line buffer is a well-known `.bss` static
  (`_tty_line_buf`, #604), not a per-vnode pointer.
- The UART TX/RX driver is a well-known static (`core/uart/*`),
  not a per-vnode pointer.
- There is no "device number" abstraction until R18+ (multi-tty,
  pty pairs, etc.).

`backend_ptr = 0` is the semantically correct value: "this
character device has no per-vnode backend state; look up the
singleton driver by well-known symbol." When R18 adds pty pairs
or `/dev/ttyS1`, that migration will require a re-freeze of the
tty vnode's backend_ptr semantics (pointer to a per-tty state
struct); this issue's freeze is R16-scoped.

### 3.7 Register + stack discipline (non-leaf)

`tty_init` is NOT a leaf: it calls `vnode_alloc` and `vnode_slot`.
SysV AMD64 requires `rsp % 16 == 0` at every nested `call`.

- Entry: `rsp % 16 == 8` (post outer-call push of return addr).
- **No prologue pushes.** Two nested calls are made, but neither
  callee touches any callee-save reg (both are leaves per
  vnode_pool.pdx). The value `r8` is used as a scratch across the
  second call — since `vnode_slot` is a leaf and doesn't touch
  `r8`, this is safe without a push.
- **BUT**: `vnode_alloc` and `vnode_slot` each execute at `rsp %
  16 == 0` inside the callee (they see the caller's stack after
  the call-push). Both are leaves and do not further call — so
  their entry alignment doesn't matter for correctness. This
  matches the vnode_pool.pdx justification's leaf discipline
  ("No prologue/epilogue, no nested call").
- **The vops dispatchers's `sub rsp, 8` alignment pad** (vops.pdx
  §post-verify amendment) is not needed here — `tty_init` calls
  the leaf primitives `vnode_alloc` and `vnode_slot` directly by
  their concrete symbols (not through an indirect vops slot); the
  ABI contract for direct-symbol leaves is "the callee runs at
  whatever alignment the caller was at", which is fine for a
  leaf.

**Volatility.** On return, `rcx`, `rdx`, `r8`, `r9`, `r10` are
clobbered (SysV caller-saves used by tty_init's body, plus
whatever vnode_alloc / vnode_slot leave behind). `rdi`, `rsi`
are read/written; other caller-saves untouched. No callee-save
mutated. Caller must treat all caller-saves as clobbered
across the call — standard SysV.

### 3.8 File contents (target)

```pdx
// src/kernel/core/tty/init.pdx — R16-M5-001 (#602)
// tty_init — allocate the first TTY vnode and publish it as _tty0.
//
// Per design/kernel/r16-m5-001-tty-vnode-alloc.md and
// design/kernel/vfs-layout.md (#570 — freezes VNODE_TYPE_CHRDEV=4,
// VNODE_TYPE_OFFSET=0, VNODE_FLAGS_OFFSET=1, VNODE_REFCOUNT_OFFSET=4,
// VNODE_PARENT_IDX_OFFSET=8, VNODE_NAME_SLOT_OFFSET=10, VNODE_FLAG_VALID=0x01,
// VNODE_IDX_NONE=0xFFFF):
//
//   tty_init allocates one vnode from _vnode_pool via vnode_alloc,
//   stores its idx into the .bss slot _tty0, then initializes the
//   vnode's frozen offsets: type=CHRDEV, flags=VALID, refcount=1,
//   parent_idx=NONE, name_slot_idx=NONE. ops_ptr (+24) and
//   backend_ptr (+32) stay at 0 — ops_ptr wired at #603, backend_ptr
//   permanently 0 for tty (see design doc §3.4 and §3.6 for the
//   invariant argument).

module Tty = structure {
  // The published handle. Low 16 bits = vnode idx (u16, zero-extended
  // into the u64 slot). 0 = pre-init sentinel (slot 0 in _vnode_pool
  // is reserved and never returned by vnode_alloc, so 0 unambiguously
  // means "tty_init not yet run").
  pub let mut _tty0 : u64 = 0

  // ==========================================================================
  // tty_init() -> u64
  //   Contract: on success, returns idx in [1, 255] and also writes it to
  //             _tty0. On vnode_alloc OOM, returns 0xFFFF and leaves _tty0
  //             at 0 (unchanged from .bss).
  // ==========================================================================
  pub let tty_init : () -> u64 !{mem} @{} =
    fn () -> unsafe {
      effects: { mem },
      capabilities: { },
      justification: "R16-M5-001 (#602): First TTY vnode allocation + publish. Two nested calls (vnode_alloc → vnode_slot); both are leaves per vnode_pool.pdx (#571) and touch no callee-save reg, so no prologue push is needed. Body: call vnode_alloc; cmp rax, 0xFFFF; je oom (propagates 0xFFFF verbatim). On success: mov r8, rax (save idx across the vnode_slot call); mov [rip + _tty0], rax (publish before touching slot fields — safe because no consumer of _tty0 exists at this landing, and publishing first means a fault during slot init still leaves _tty0 discoverable for panic-time forensics); mov rdi, rax; call vnode_slot (returns &vnode in rax). Then five narrow writes to frozen offsets per vfs-layout.md §3: mov_b [rax+0]=4 (type=CHRDEV), mov_b [rax+1]=1 (flags=VALID), mov_w [rax+4]=1 (refcount — _tty0 itself is a hold; init's fd 0/1/2 will bump at #608), mov_w [rax+8]=0xFFFF (parent_idx=NONE — detached until devfs binding at #603), mov_w [rax+10]=0xFFFF (name_slot_idx=NONE — unnamed until devfs). All other frozen fields (mode, link_count, uid, gid, size, ops_ptr, backend_ptr, reserved) stay at 0 from the fresh-slot zero-init invariant (see design doc §3.5). ops_ptr (+24) deliberately stays 0 — wired to _tty_vops at #603; the vops dispatchers (core/fs/vops.pdx) already null-guard ops_ptr==0 by returning VOPS_ERR_NOT_SUPPORTED, and no consumer references _tty0 between #602 and #603 landing (see §3.4 for full analysis; identical pattern to mount.pdx:168). backend_ptr (+32) stays 0 permanently for TTY — no per-vnode backend state at R16.M5 (see §3.6). Return: mov rax, r8; ret. OOM path: rax already 0xFFFF from vnode_alloc, just ret. Audit: r16-m5-001-tty-vnode-alloc.",
      block: {
        call vnode_alloc;
        cmp rax, 0xFFFF;
        je  tty_init_oom;

        mov r8, rax;
        mov [rip + _tty0], rax;

        mov rdi, rax;
        call vnode_slot;                    // rax = &vnode

        mov rcx, 4;
        mov_b [rax + 0], rcx;               // type = CHRDEV
        mov rcx, 1;
        mov_b [rax + 1], rcx;               // flags = VALID
        mov rcx, 1;
        mov_w [rax + 4], rcx;               // refcount = 1
        mov rcx, 0xFFFF;
        mov_w [rax + 8], rcx;               // parent_idx = NONE
        mov_w [rax + 10], rcx;              // name_slot_idx = NONE

        mov rax, r8;
        ret;

      tty_init_oom:
        ret
      }
    }
}
```

## 4. Witness placement

### 4.1 Position in kernel_main.pdx

Inserted after `uart_rx_smoke_witness_done:` (line 4191, the last
R16.M4 witness label) and before the R14b-m5-002 GS_BASE `wrmsr`
block (line 4194). The insertion is structurally independent —
no data flow into or out of any M4 witness or the GS_BASE block.

```
uart_rx_smoke_witness_done:
    pop  r12

<-- INSERT R16.M5-001 WITNESS HERE (§5.2 body) -->

// R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
lea rax, [rip + _cpu_locals];
...
```

If a follow-on R16.M4 amendment slips in between #601 and #602,
the insertion point moves to the actual last-landed M4 witness's
`_done:` label. No M4 witness holds state that #602 reads.

### 4.2 No witness slab needed — but a slot-free preamble IS needed

**Correction (post-implementation, #602 debugging pass):** this
section originally claimed no fixture was needed at all. That is
still true for storage (no scratch vnode, no scratch vops table),
but it missed a preamble that every vnode-allocating witness after
the #571 `vnode_pool` witness must carry: **the vnode pool is
fully exhausted (256/256 slots allocated) by the time any
subsequent boot witness runs.**

`vnode_pool_fill_loop` (#571's sub-test D, `kernel_main.pdx:1663-
1681`) deliberately allocates every remaining slot to prove the
OOM path, and never frees them back. Every later vnode-allocating
witness — `mount` (#574, frees-then-immediately-reclaims slot
100) and `vfs_read`/`vfs_write` (#577, frees-then-permanently-
consumes slot 200) — carries its own "free slot N" preamble for
exactly this reason (see their own comments at `kernel_main.pdx:
1946` and `kernel_main.pdx:2161-2170`). `tty_init`'s witness needs
the identical preamble; §7.2 below is corrected to match.

The witness therefore opens with:

```asm
mov  rdi, 201
call vnode_free
```

Slot 201 is chosen because it is untouched by any other witness
(distinct from #574's slot 100, which now holds the live mount
root vnode, and #577's slot 200, which holds that witness's
now-orphaned-but-still-allocated fixture vnode). Slot 201 was
only ever touched by the #571 fill-loop's bitmap-set (which never
writes slot storage), so its 64 bytes are still zero from the
`.bss` uninit — freeing it recycles the bitmap bit without
disturbing any live vnode, same argument as #577's preamble.

Unlike the tmpfs/vfs witnesses (which use scratch vnodes /
scratch vops tables), `tty_init`'s witness only reads three
things: `rax` from the call, `_tty0` from `.bss`, and the type
byte at offset +0 of the newly allocated vnode. No fixture
allocation, no scratch structure, no per-witness `.bss` slab —
only the one-instruction-pair pool-preamble above.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure

**Three sub-tests, chosen to cover exactly the three write
postconditions that are not by-construction from the zero-init
invariant** (see §3.5 for the by-construction fields):

- **Sub-test A**: `tty_init` returns a non-zero, non-sentinel idx.
  Directly asserts postcondition #8 (return value) and indirectly
  asserts postcondition #1's precondition (the alloc succeeded,
  so type=CHRDEV was actually written to a real slot).
- **Sub-test B**: `_tty0` `.bss` slot, read after `tty_init`
  returns, contains the returned idx. Asserts the publish path
  (`mov [rip + _tty0], rax`) actually reached the storage cell.
  Uses `r12` (callee-save) to carry the returned idx across
  `uart_puts` calls in the emit path.
- **Sub-test C**: `_vnode_pool[_tty0].type` (byte at slot base +0)
  == `VNODE_TYPE_CHRDEV = 4`. Asserts the frozen-offset narrow
  write hit the right byte with the right value. This is the
  test that would catch the parent brief's original "CHRDEV = 5"
  typo — sub-test C would emit `R16 TTY VNODE FAIL` on a 5, and
  the marker would never appear.

Extending to A/B/C/D covering refcount=1, or A/B/C/D/E covering
parent_idx=NONE, would exceed the "prove exactly the writes made"
scope; those fields are asserted by their subsequent-issue
consumers (refcount by #608's fd_inherit at fd wire; parent_idx
by #603's devfs bind).

### 5.2 Witness assembly (complete block)

**Corrected** (see §4.2): the block opens with a pool-preamble
that frees slot 201 before calling `tty_init`, matching the #574 /
#577 precedent for every vnode-allocating witness that runs after
#571's fill-to-OOM sub-test.

```asm
; ============================================================
; R16-M5-001 (#602): tty_init witness — 3 sub-tests, 1 marker
; ============================================================
tty_init_witness:
    push r12                              ; callee-save: carries tty_idx
                                          ; across uart_puts calls

    ; ---------- Preamble: free slot 201 for tty_init's vnode_alloc ----------
    mov  rdi, 201
    call vnode_free

    ; ---------- Sub-test A: tty_init returns a valid idx ----------
    call tty_init
    cmp  rax, 0                           ; slot 0 is reserved — never returned
    je   tty_init_witness_fail
    cmp  rax, 0xFFFF                      ; VNODE_ALLOC_OOM sentinel
    je   tty_init_witness_fail
    mov  r12, rax                         ; r12 = tty_idx for sub-tests B/C

    ; ---------- Sub-test B: _tty0 slot contains the returned idx ----------
    mov  rax, [rip + _tty0]
    and  rax, 0xFFFF                      ; extract u16 idx from u64 slot
    cmp  rax, r12
    jne  tty_init_witness_fail

    ; ---------- Sub-test C: vnode.type at +0 == CHRDEV (4) ----------
    mov  rdi, r12                         ; vnode idx
    call vnode_slot                       ; rax = &_vnode_pool[tty_idx]
    mov  rcx, [rax + 0]                   ; load u64 covering type/flags/mode/refcount/link_count
    and  rcx, 0xFF                        ; extract type byte (+0)
    cmp  rcx, 4                           ; VNODE_TYPE_CHRDEV
    jne  tty_init_witness_fail

    ; ---------- All green ----------
    lea  rdi, [rip + tty_ok_msg]
    call uart_puts
    jmp  tty_init_witness_done

tty_init_witness_fail:
    lea  rdi, [rip + tty_fail_msg]
    call uart_puts

tty_init_witness_done:
    pop  r12
```

Total: ~30 lines including the two labels and the push/pop pair.

**Register discipline of the witness block:** `push r12` before
the sub-tests balances `pop r12` at the exit label, keeping
`rsp % 16 == 0` inside the witness (post-push) so nested calls
(`tty_init`, `vnode_slot`, `uart_puts`) all land at the required
alignment. Same pattern as the tmpfs witnesses at kernel_main.pdx
lines 2306+ (which use `r12`/`r13` around `tmpfs_inode_slot`
calls).

### 5.3 Marker

On all three sub-tests green:

```
R16 TTY VNODE OK
```

Emitted via `uart_puts` on `tty_ok_msg`. Fingerprint added to all
three R14B/R15 expected-output files, inserted **immediately
after** `UART RX: abc` (the R16.M4-007 fingerprint, which is
also the R16.M4 subsystem-closer). Insertion is strictly
additive; contains-in-order matching means no earlier or later
line reorders.

### 5.4 String data — `tools/boot_stub.S`

Append after the last R16.M4 witness string (currently the
`uart_rx_smoke_*_msg` / `uart_rx_smoke_prefix_msg` group at
approximately lines 754-762):

```asm
# R16-M5-001 (#602): tty_init witness success message
.global tty_ok_msg
.align 8
tty_ok_msg: .ascii "R16 TTY VNODE OK\n\0"

# R16-M5-001 (#602): tty_init witness failure message
.global tty_fail_msg
.align 8
tty_fail_msg: .ascii "R16 TTY VNODE FAIL\n\0"
```

No other rodata changes.

### 5.5 Fingerprint files — marker insertion

Insert `R16 TTY VNODE OK` in three files:

| File                                        | Insert after   | Insert before        |
|---------------------------------------------|----------------|----------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `UART RX: abc` | `LOADER OK`          |
| `tests/r15/expected-boot-r15-ring3.txt`     | `UART RX: abc` | `R15 IDLE TASK OK`   |
| `tests/r15/expected-boot-r15-process.txt`   | `UART RX: abc` | `R15 IDLE TASK OK`   |

Contains-in-order matching (per `tools/run-smoke.sh` §L28
comment) makes the addition strictly additive — no earlier line
reorders. All 5-mode smoke stages that do not observe R16 markers
(`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`,
`boot_r12_denial`) stay byte-identically green.

## 6. Alternatives considered / follow-ups

### 6.1 Combine with #603 (`tty_vops_wire`) in one PR

**Rejected.** The tactical plan splits them because they exercise
distinct concerns:

- #602 proves vnode allocation + storage layout for a CHRDEV.
- #603 proves the vops table publish + devfs binding.

A regression in one landing bisects to a small module rather
than a fused ~200 LOC change. This matches the R16.M4 pattern
(#595 alone for `uart_rx_init`; #596/#597 separate for the
ring/ISR).

### 6.2 Store a `*vnode` (pointer) in `_tty0` instead of an idx

**Rejected.** Every other vnode handle in the kernel is a u16
idx into `_vnode_pool` (mount table entries, tmpfs parent_idx /
first_child / next_sibling, task_struct fd_table entries per
R16.M3-005). A pointer discipline for tty would be a lone
outlier; sharing the idx discipline means downstream consumers
(#603, #608) can pass `_tty0`'s low 16 bits directly to any
existing `vnode_slot(idx)` / `vops_read(vnode_ptr = vnode_slot(idx))`
call site without a shape adapter.

### 6.3 Publish `_tty0` **before** `vnode_alloc` succeeds

**Rejected.** The design body §3.3 publishes `_tty0` **after**
`vnode_alloc` succeeds but **before** the field writes. That
ordering is deliberate:

- Publish after alloc — because a failed alloc must leave `_tty0`
  at 0 (the "not yet initialized" sentinel). Publishing eagerly
  would burn the sentinel meaning.
- Publish before field writes — because a fault during a narrow
  store (unlikely — .bss stores can't fault — but structural)
  would still leave `_tty0` pointing at the allocated slot for
  panic-time forensics. Since no consumer of `_tty0` exists
  between #602 and #603 landing, publishing early carries zero
  risk and marginal debuggability upside.

### 6.4 Add sub-tests D..H covering the by-construction fields

**Rejected.** Sub-tests A/B/C cover the three postconditions with
non-obvious values (returned idx, published idx, type
discriminant). The remaining postconditions (flags=VALID,
refcount=1, parent_idx=NONE, name_slot_idx=NONE, ops_ptr=0,
backend_ptr=0) hold **iff** the vnode_pool zero-fill invariant
and the narrow-store encoder both work — and both have been
witnessed a dozen times over by prior R16 issues (vfs_open,
tmpfs_init, mount, path_resolve). Adding these sub-tests would
duplicate prior coverage without adding fault-detection power.

Refcount=1 in particular is a value that #608 (`fd_inherit_hold`)
will assert transitively when it bumps to 4 after wiring init's
fd 0/1/2 — a #608 witness failure caused by a #602 refcount bug
would fingerprint at #608's marker, not miss detection.

### 6.5 Allocate a `_tty1` slot too (multi-tty from day one)

**Rejected.** R16.M5 ships a single-console TTY (one entry in the
tactical plan, one vnode). Multi-tty support requires (a) a per-
tty line buffer array (not a singleton), (b) a device-numbering
scheme (dev_t or major/minor), (c) a `/dev` populated with
`tty0`/`tty1`/... entries, and (d) a controlling-terminal
concept (`sys_setpgid`, TIOCSCTTY). All of that lives in a
future milestone (R18+ multi-tty). Adding `_tty1` here would
ship dead storage. If a follow-on issue proves the need,
allocation of additional tty vnodes is trivial — another
`call tty_init` (renamed to `tty_alloc` at that point) with a
different destination slot.

### 6.6 Emit `R16 TTY VNODE OK` from within `tty_init`

**Rejected.** Same discipline as every other R16 primitive:
callers own emission. `tty_init` is a driver primitive that
may be called from non-witness contexts in R18+ (multi-tty).
Keeping the emit in the witness block keeps the primitive
reusable and matches the R16.M4-001 discipline documented at
`design/kernel/r16-m4-001-uart-rx-init.md` §6.7.

### 6.7 Set `refcount = 0` initially, let #608 bump

**Rejected.** `_tty0` itself is a hold on the vnode: as long as
`_tty0 != 0`, the vnode should never be freed. Setting
`refcount = 1` at init makes this hold explicit (matches every
kernel convention where a persistent structure that names a
vnode idx must have contributed a hold). #608's fd inheritance
will then bump this to 4 (init's fd 0/1/2 + the base `_tty0`
hold). A refcount=0 start would violate `vfs_close` (#576)
semantics — if any code path decremented to -1 it would trigger
a spurious `vops_close` call.

## 7. Invariants

### 7.1 `_tty0 != 0` after successful `tty_init`

Guaranteed by the `mov [rip + _tty0], rax` after the alloc
succeeded and before any potential fault. `vnode_alloc` returns
an idx in `[1, 255]` on success (slot 0 is reserved per #570
§7.2), so the written value is always non-zero on success.

Verified by sub-test B.

### 7.2 `_tty0 == 0` after failed `tty_init` (OOM)

Guaranteed by the branch structure: on `vnode_alloc == 0xFFFF`,
the code jumps to `tty_init_oom` without touching `_tty0`.
`.bss` zero-init makes the initial value 0; nothing else in the
kernel writes `_tty0` before this call. So `_tty0` stays 0 on
the OOM path.

Not exercised by the witness (the `0xFFFF` branch inside
`tty_init` itself is not deliberately triggered). **Correction**
(post-implementation, #602 debugging pass): the parenthetical
originally here — "OOM cannot be induced at boot, where only 1 or
2 vnodes have been allocated out of 255 free slots" — was wrong.
See §4.2: by the time `tty_init` runs, the vnode pool is fully
exhausted (256/256) because #571's `vnode_pool` witness
deliberately fills it to OOM and never frees the fill-loop's 252
slots. The witness's own slot-201-free preamble is what supplies
the one free slot `tty_init`'s `vnode_alloc` call actually
consumes — without it, `vnode_alloc` returns `0xFFFF` on every
boot, `tty_init` propagates it, and sub-test A fails
unconditionally (this is exactly the bug the debugging pass
found and fixed). The `_tty0 == 0`-on-OOM invariant itself remains
by-construction and is still not directly exercised.

### 7.3 The published vnode has `type == VNODE_TYPE_CHRDEV`

Guaranteed by the `mov_b [rax + 0], rcx` with `rcx = 4`, after
`rax = vnode_slot(idx)` returned the slot base. `vnode_slot`'s
contract (vnode_pool.pdx §148-159) guarantees `rax = &_vnode_pool
+ idx * 64` — the correct slot base for the just-returned idx.

Verified by sub-test C.

### 7.4 Idempotence — deliberately NOT held

`tty_init` is NOT idempotent — a second call would leak the
first vnode (allocated, referenced by `_tty0` briefly, then
overwritten with the second-alloc idx; first vnode's refcount
stays 1, so `vnode_free` is never called). This is acceptable
because `tty_init` is called exactly once, from the witness
block. If a future refactor moves the call to a
`bootstrap_all_devices()` sequence, an early guard
(`cmp [rip + _tty0], 0; jne tty_init_already_done`) can be
added without changing the primitive's shape.

### 7.5 Vnode-layout freeze §7.5 (`ops_ptr` non-null for live
    vnodes) — textually strained, functionally upheld

See §3.4 for the full argument. Summary: the strain is
identical to the mount-table root vnode at #574; the strain
window (from #602 landing to #603 landing) has zero live
consumers of `_tty0` other than this issue's witness; the vops
dispatchers already null-guard `ops_ptr == 0`. #603's landing
restores the strict form of §7.5.

## 8. Cross-cutting risks

- **Fresh-slot zero-fill assumption is `.bss`-loader dependent.**
  §3.5's argument that a fresh alloc returns a zero-filled slot
  rests on the ELF loader zeroing `.bss` at load time. This has
  been true across every R14/R15/R16 witness landing; a
  regression would break dozens of other witnesses first (mount,
  tmpfs, task_new). If a future paideia-as change to `.bss`
  handling changed this contract, `tty_init` would inherit the
  breakage but would not be its earliest observer.
- **`vnode_alloc` OOM is not exercised at boot.** By the time
  `tty_init` runs, ~2 of 255 vnode slots are in use. OOM cannot
  be induced by the witness. If a future R17+ boot flow exhausts
  the pool before `tty_init`, the OOM path takes rax=0xFFFF; the
  witness's sub-test A catches this (`cmp rax, 0xFFFF; je fail`).
  The failure mode is loud, not silent.
- **`ops_ptr = 0` half-live window.** §3.4 argues no consumer
  exists in this window. If a future R16.M5 issue lands in a
  different order (e.g., a bring-up that puts a tty vnode into
  the mount table before #603 wires its vops), a null-deref
  would be caught by the vops dispatchers' existing null-guard
  and returned as `VOPS_ERR_NOT_SUPPORTED` — not a panic. Still,
  the tactical plan's linear #602 → #603 order should be
  respected.
- **Sub-test C's `mov rcx, [rax + 0]; and rcx, 0xFF` reads 8
  bytes to extract 1.** Safe because `_vnode_pool` slots are
  64 B aligned and 64 B in size — the 8-byte load at offset 0
  never straddles into a neighbor slot's storage. Same idiom
  used at kernel_main.pdx:2320 for the tmpfs type check;
  landed and stable.
- **Marker line insertion vs. `UART RX: abc` — the trailing
  `\n` on the M4 fingerprint.** `uart_rx_smoke_prefix_msg` is
  "UART RX: \0" (no newline), and the buffer emit is
  `mov_b [r12 + 3], '\n'` (line 4173) so the composite output
  is "UART RX: abc\n". The next line in the fingerprint is
  "R16 TTY VNODE OK\n". No line boundary confusion.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/tty/init.pdx` (new)                        | ~55        |
|   - module boilerplate + `_tty0` storage decl               |   ~8       |
|   - `tty_init` justification (single frozen comment)        |  ~15       |
|   - `tty_init` body (~18 instructions)                      |  ~22       |
|   - inline comments                                         |  ~10       |
| `src/kernel/boot/kernel_main.pdx` (witness block)           | ~50        |
|   - 3 sub-tests + labels                                    |  ~30       |
|   - preceding/trailing comment banner                       |   ~6       |
|   - fail/success emit                                       |  ~10       |
|   - blank lines / structural spacing                        |   ~4       |
| `tools/boot_stub.S` (2 messages)                            | ~8         |
| 3 expected-output fingerprint files (1 marker each)         | ~3         |
| `design/kernel/r16-m5-001-tty-vnode-alloc.md` (this doc)    | (this)     |
| **Total executable / testing / test-data**                  | **~116**   |

Executable code path: ~55 LOC. Witness + fingerprint: ~61 LOC.
Slightly larger than R16.M4-001 (~86 LOC) because tty_init has 3
sub-tests to uart_rx_init's 1, and the body has 5 narrow field
writes to uart_rx_init's 1 port write. Still an order of magnitude
smaller than any R16.M3 syscall issue.

## 10. Tractability

**HIGH — small R16 issue, one leaf-boot-init pattern, three
narrowly-scoped sub-tests.**

- **Zero paideia-as encoder gap.** Every mnemonic proven at
  `core/fs/mount.pdx` (vnode init) and `core/fs/tmpfs/init.pdx`
  (narrow field stores + boot init structure). Both patterns
  landed and stable.
- **One nested-call boundary** (`tty_init` → `vnode_alloc`;
  `tty_init` → `vnode_slot`). Both callees are leaves with clean
  register discipline; no callee-save save/restore needed in
  `tty_init` (§3.7).
- **Three sub-tests** with mechanical structure: A checks return
  value; B checks .bss publish; C checks a byte-write at frozen
  offset +0. No fixture allocation, no scratch structure, no
  cross-subsystem interaction.
- **Marker line is contains-in-order** — strictly additive to
  fingerprints; no reordering risk.
- **No cross-repo escalation risk.**
- **Sizing (~116 LOC total)** is 3-4× smaller than any R16.M3
  syscall issue and comparable to R16.M4 witness landings
  (uart_rx_init: ~86 LOC; uart_rx_ring: ~90 LOC).
- **The parent-brief's CHRDEV=5 typo is caught by sub-test C**
  during implementation review; the design doc's §1.1 makes the
  correction explicit so no downstream reviewer restages the same
  mistake.

Estimated implementation time: **~40 minutes of a workerbee
session** (slightly longer than uart_rx_init because of the 3
sub-tests and 5 field writes).

Estimated risk of regressing an existing smoke mode:
**near-zero** — purely additive (one new file, one new witness
block, one new emit line, two new rodata strings, one new marker
line in three fingerprint files).

**Known follow-ups (do NOT block #602's landing)**:

- **#603 (`tty_vops_wire`)** — creates `_tty_vops` (`read`,
  `write`, `close` at slots +0/+8/+24) and writes it to
  `_tty0.ops_ptr` (+24). Also binds `_tty0.name_slot_idx` to
  `"tty0"` in `_name_slab` via a devfs registration path.
  Closes the §3.4 half-live window.
- **#604 (`tty_line_buffer`)** — `.bss` allocation of the 256-char
  line buffer + head/tail/complete-flag words.
- **#605 (`tty_process_input`)** — feeds bytes from the RX
  notification into the line buffer with echo + \r→\n +
  backspace handling.
- **#606 (`tty_read`)** — blocking cooked-mode read; wakes on
  complete-line notification.
- **#607 (`tty_write`)** — \n → \r\n translation on egress.
- **#608 (`connect-tty-to-init-fd012`)** — task[1].fd_table[0]
  = task[1].fd_table[1] = task[1].fd_table[2] = `_tty0` idx.
  Bumps `_tty0.refcount` from 1 to 4.
- **#609 (R16.M5 CLOSER smoke)** — round-trip "hello\n" through
  the cooked line discipline; assert fingerprint
  `TTY: hello\nHI: hi`.

## 11. References

- Issue: paideia-os#602
- Milestone: paideia-os R16.M5 (TTY / cooked line discipline)
- Prereq issues: #570 (vnode layout freeze), #571
  (vnode_pool / vnode_alloc), #601 (last R16.M4 witness — insert
  point)
- Blocks: #603..#609 (subsystem 15 tail)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 15 line 1552, item 1
- Master plan: `design/milestones/r14b-master-plan.md` §M21 (TTY)
- Prior-art body pattern: `src/kernel/core/fs/mount.pdx:161-168`
  (vnode alloc + type init + ops_ptr deferred to a later issue)
- Prior-art field-write idiom: `src/kernel/core/fs/tmpfs/init.pdx`
  (narrow mov_b / mov_w to frozen offsets on a fresh inode)
- Prior-art witness pattern: `src/kernel/boot/kernel_main.pdx:2303-2371`
  (tmpfs_init witness — same "call init; check return; check
  .bss publish; check first field" three-sub-test shape)
- Layout freeze source: `design/kernel/vfs-layout.md` §3 (constant
  table) — CHRDEV=4 is authoritative here
