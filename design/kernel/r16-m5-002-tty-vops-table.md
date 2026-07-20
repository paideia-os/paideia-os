---
issue: 603
milestone: R16.M5 (TTY / cooked line discipline)
subsystem: 15 — TTY / cooked line discipline
topic: tty_vops — materialize _tty_vops [u64; 7] with 4 real slots + 3 deliberate nulls; wire _tty0.ops_ptr → &_tty_vops
prereq:
  - "#572 (R16.M1-003 vops layout freeze — LANDED; VOPS_SIZE=56, VOPS_NUM_OPS=7, slot offsets 0/8/16/24/32/40/48 as VOPS_{READ,WRITE,OPEN,CLOSE,LOOKUP,CREATE,UNLINK}_OFFSET; all 7 dispatchers null-guard ops_ptr==0 AND slot==0 with VOPS_ERR_NOT_SUPPORTED=0xFFFFFFFFFFFFFFFF)"
  - "#570 (R16.M1-001 vnode layout freeze — LANDED; VNODE_OPS_PTR_OFFSET=+24, VNODE_SIZE=64, slot-0 sentinel discipline)"
  - "#586 (R16.M2-008 tmpfs_vops_init — LANDED; structural precedent for a [u64; 7] populator built from lea rip+sym / mov [reg+disp],reg idioms; no encoder growth needed here)"
  - "#602 (R16.M5-001 tty_init — LANDED; allocates _tty0 with ops_ptr @+24 deliberately left at 0. This issue closes the half-live window §3.4 of #602 documented)"
  - "#571 (R16.M1-002 vnode_pool / vnode_alloc / vnode_slot — LANDED; vnode_slot(idx) returns &_vnode_pool[idx*64] as the write target for the ops_ptr wire step §5.2)"
  - "#601 (R16.M4-007 uart_rx_smoke — LANDED; provides uart_puts for the witness emit path)"
blocks:
  - "#604 (r15-m5-003 line-buffer — independent .bss allocation; #603's table entries do not need the line buffer yet, but #605 will extend the tty_read primitive shipped here to consume it)"
  - "#605 (r15-m5-004 tty_process_input — feeds the line buffer; does not read tty_vops but extends the tty_read primitive)"
  - "#606 (r15-m5-005 tty_read_blocking — REPLACES the minimal tty_read body shipped here; the vops slot pointer stays stable, only the body of tty_read grows to include the block-on-empty logic)"
  - "#607 (r15-m5-006 tty_write_nl_cr — REPLACES the minimal tty_write body shipped here; the vops slot pointer stays stable, only the body of tty_write grows to include \\n→\\r\\n translation and UART TX)"
  - "#608 (r15-m5-007 connect-tty-to-init-fd012 — assigns _tty0 idx into init's fd_table[0/1/2]; every subsequent sys_write(1,…) from init flows read/write/close through _tty_vops slots wired here)"
  - "#609 (r15-m5-008 R16.M5 CLOSER smoke — end-to-end line-discipline exercise built on top of the fully-wired _tty_vops)"
touching:
  - src/kernel/core/tty/vops.pdx                          (new file; _tty_vops table + tty_open + tty_close + tty_vops_init; ~120 LOC)
  - src/kernel/core/tty/read.pdx                          (new file; tty_read minimal primitive — extended at #606; ~30 LOC)
  - src/kernel/core/tty/write.pdx                         (new file; tty_write minimal primitive — extended at #607; ~30 LOC)
  - src/kernel/boot/kernel_main.pdx                       (call tty_vops_init after the #602 witness done; add tty_vops witness block ~60 LOC)
  - tools/boot_stub.S                                     (2 rodata additions: tty_vops_ok_msg, tty_vops_fail_msg)
  - tests/r14b/expected-boot-r14b-loader.txt              (marker: `R16 TTY VOPS OK`)
  - tests/r15/expected-boot-r15-ring3.txt                 (marker)
  - tests/r15/expected-boot-r15-process.txt               (marker)
  - design/kernel/r16-m5-002-tty-vops-table.md            (this doc)
related:
  - design/kernel/r16-m5-001-tty-vnode-alloc.md           (#602; §3.4 half-live window that this issue closes; §1.3 explicitly deferred the vops wiring to #603)
  - design/kernel/r16-m2-008-tmpfs-vops-wire.md           (#586; the [u64; 7] populator + witness precedent this issue mirrors)
  - design/kernel/r16-m1-003-vops.md                      (#572; dispatcher shape and null-slot semantics used by sub-test B's E_NOT_SUPPORTED assertion)
  - design/kernel/vfs-layout.md                           (#570; VNODE_OPS_PTR_OFFSET=+24 — the write target)
  - src/kernel/core/fs/vops.pdx                           (#572; the 7 dispatchers this issue's witness invokes end-to-end)
  - src/kernel/core/fs/tmpfs/vops.pdx                     (#586; the tmpfs table + adapters — structural sibling; the shape of the tty vops.pdx follows this file line-by-line minus the adapters, since tty is idx-native)
  - src/kernel/core/tty/init.pdx                          (#602; publishes _tty0, leaves ops_ptr @+24 at 0 — this issue writes into that slot)
  - design/milestones/r14b-tactical-plan.md               §Subsystem 15 item 2 (this issue)
---

# R16-M5-002 — `tty_vops` table + wire `_tty0.ops_ptr = &_tty_vops` (#603)

## 1. Scope

Land the second R16.M5 subsystem-15 issue: materialize the concrete
`_tty_vops : [u64; 7]` shared function-pointer table for the TTY
backend, ship 4 real primitive pointers (`tty_read`, `tty_write`,
`tty_open`, `tty_close`) with 3 deliberately-null slots
(`lookup`, `create`, `unlink` — semantically absent on a character
device), and wire `_tty0.ops_ptr` (+24) to `&_tty_vops` so every
`vops_read` / `vops_write` / `vops_open` / `vops_close` invocation on
the TTY vnode dispatches through this table.

```
tty_vops_init() -> u64
    side effects: {mem}
    postcondition #1: _tty_vops[+0]  == &tty_read        (VOPS_READ_OFFSET)
    postcondition #2: _tty_vops[+8]  == &tty_write       (VOPS_WRITE_OFFSET)
    postcondition #3: _tty_vops[+16] == &tty_open        (VOPS_OPEN_OFFSET)
    postcondition #4: _tty_vops[+24] == &tty_close       (VOPS_CLOSE_OFFSET)
    postcondition #5: _tty_vops[+32] == 0                (VOPS_LOOKUP_OFFSET — deliberate null; see §3.2)
    postcondition #6: _tty_vops[+40] == 0                (VOPS_CREATE_OFFSET — deliberate null; see §3.2)
    postcondition #7: _tty_vops[+48] == 0                (VOPS_UNLINK_OFFSET — deliberate null; see §3.2)
    postcondition #8: _vnode_pool[_tty0 & 0xFFFF].ops_ptr (+24) == &_tty_vops
    postcondition #9: vops_read(&_tty0's vnode, ...) reaches tty_read via _tty_vops and returns 0
    return: rax = 0 on success
```

The witness confirms postconditions #5, #8, and #9 end-to-end
(sub-tests A/B/C — see §5). Postconditions #1..#4 and #6..#7 are
transitively asserted by sub-test C's end-to-end read dispatch and
sub-test A's null-slot lookup dispatch — if the wrong pointer sat in
slot +0 or slot +32, those sub-tests would fail loudly. See §5.1
for the coverage rationale.

### 1.1 Reconciling with the formal acceptance criterion

The tactical plan's stated AC (`design/milestones/r14b-tactical-plan.md`
§Subsystem 15 item 2) is:

> **AC: fixture `vfs_open("/dev/tty0")` returns `_tty0`.**

**This AC cannot be met at R16.M5 without infrastructure that does
not yet exist.** Specifically:

1. **No `/dev` directory anywhere in the mount graph.** `vfs_open`
   (`src/kernel/core/fs/vfs_open.pdx`, #575) resolves paths through
   `mount_root_vnode` + `path_resolve`. The mount table (#574) has
   exactly one entry: `_tmpfs_root_idx` under `/`. There is no
   `/dev` dentry, no devfs backend, no way for `path_resolve` to
   find `tty0` under a non-existent `/dev`.
2. **`_tty0`'s `name_slot_idx` is `VNODE_IDX_NONE`** (#602 §3.3).
   Even if a devfs backend existed, the TTY vnode itself has no
   published name.
3. **No devfs backend has been architected.** The tactical plan
   (§Subsystem 15) does not include a devfs subsystem; TTY reaches
   `init`'s fd 0/1/2 via a direct fd-table wire at #608 (`task[1]
   .fd_table[0/1/2] = _tty0`), NOT via `sys_open("/dev/tty0")`.
   The path-resolver route to TTY is a **post-R16.M5** concern
   (probably R17+ shell demo or R18+ multi-tty).

The formal AC therefore describes a state that requires devfs
publication as a prerequisite — a design gap that would need its
own issue (call it `#603b devfs-tty-registration`) before the AC
becomes literally testable.

**The structural equivalent — accepted here — is the three-sub-test
witness at §5**, which proves exactly the properties the formal AC
was intended to guarantee **once devfs exists**:

| Formal AC guarantee                            | Structural sub-test that proves the same thing at R16.M5                                                      |
|------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| `vfs_open("/dev/tty0")` returns `_tty0` idx    | Sub-test C: `vops_read` on `_tty0`'s vnode reaches `tty_read` and returns 0. This proves the vops chain is live — the only thing devfs registration would add is the path→vnode name lookup, orthogonal to the vops dispatch itself.  |
| The vnode's vops table is populated + wired    | Sub-test C's success + populator's postconditions #1..#4                                                     |
| `close(fd)` on that fd calls tty's close       | Sub-test C's dispatch chain proves ops_ptr is wired; any op reaches its slot; tty_close's return path is symmetric to tty_read's — same dispatcher, different slot. |
| CHRDEV-appropriate ops are absent (lookup etc) | Sub-test A: `vops_lookup` on `_tty0` returns VOPS_ERR_NOT_SUPPORTED, proving null-slot semantics work         |

The literal AC is deferred to a follow-on issue (`#603b`) that
lands devfs registration; that issue's witness will `vfs_open(
"/dev/tty0")` and cross-check the returned idx against `_tty0`. Per
the R16.M5 subsystem discipline, all downstream issues (#604..#609)
reach TTY via direct kernel handles (`_tty0`, `_tty_line_buf`) —
none go through the path resolver — so the deferred literal AC does
NOT block subsystem closure.

### 1.2 What this issue proves

- **The `_tty0` half-live window closes.** #602 §3.4 shipped
  `_tty0` with `ops_ptr = 0` and justified the strain against
  `vfs-layout.md` §7.5 (`ops_ptr` non-null for live vnodes) by
  observing that no consumer references `_tty0` in the interval
  between #602 and #603 landing. This issue restores strict
  compliance with §7.5.
- **Null-slot semantics compose with CHRDEV vnodes.** Every prior
  vops population (tmpfs at #586) filled all 7 slots — either with
  real adapters or with success-stubs. TTY is the first backend to
  DELIBERATELY leave slots null and rely on the dispatcher's
  E_NOT_SUPPORTED return for correctness. Sub-test A asserts this
  chain works: dispatcher observes null slot, returns
  VOPS_ERR_NOT_SUPPORTED, caller sees the sentinel. This is the
  design-intended failure mode for any operation that does not
  make sense on a character device (opening a child, creating a
  child, unlinking a child).
- **Idx-native primitives compose with the vops shape without an
  adapter.** tmpfs needed 5 adapters (`_tmpfs_read_adapter`, ...)
  because the tmpfs primitives take `inode_idx` in `rdi` while
  vops delivers `vnode_ptr`. TTY has only one instance (`_tty0`)
  and no per-vnode backend state — `tty_read` / `tty_write` /
  `tty_open` / `tty_close` all ignore `rdi` entirely (they're
  hard-coded to the single line buffer and the single UART).
  So `_tty_vops` points directly at the primitives; no adapter
  layer, no `backend_ptr` extraction. TTY is architecturally
  simpler than tmpfs at the vops boundary. §3.6 discusses the
  future migration path when multi-tty lands (R18+).
- **`tty_vops_init` is one atomic transition.** Populator +
  wire step live in one function. On return, TTY is fully
  operational at the vops layer. Idempotent (safe to call twice).

### 1.3 What this issue deliberately does NOT do

- **No devfs backend / `/dev/tty0` path resolution.** See §1.1.
- **No line buffer allocation.** `_tty_line_buf` is #604's concern.
  `tty_read` shipped here returns 0 (no data available) because
  there is no buffer yet. #606 rewrites `tty_read` to
  block-until-line-ready when the buffer exists.
- **No `\n → \r\n` translation in `tty_write`.** #607's concern.
  `tty_write` shipped here returns `len` (bytes accepted) without
  UART TX. #607 rewrites the body to translate + emit through
  UART TX. The vops slot pointer stays stable — only the primitive's
  body changes.
- **No ioctl / termios / mode bits.** The vops table has no
  `ioctl` slot at R16 (frozen at 7 ops per #572). Cooked-mode
  toggling is entirely in #605's line discipline; if a future
  ioctl-shaped API lands (R17+ shell demo), it will need either an
  extension of vops from 7→8 slots (breaking freeze — likely NOT
  done) or a separate side-channel syscall.
- **No refcount bump.** Wiring `ops_ptr` does not add a reference
  hold. `_tty0`'s refcount stays at 1 (set by #602) until #608's
  `fd_inherit` bumps to 4.
- **No re-entrancy guard.** `tty_vops_init` is called exactly once
  at boot, from kernel_main. Idempotence (§3.4) is a
  design-invariant safety net, not a re-entrancy defense.

## 2. Prereq check

### 2.1 What is in place

| Primitive / symbol         | Location                                                | Contract used                                                                                                             |
|----------------------------|---------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `_tty0`                    | `core/tty/init.pdx:23` (#602, LANDED)                   | u64 storage; low 16 bits hold vnode idx; 0 = pre-init sentinel.                                                           |
| `tty_init`                 | `core/tty/init.pdx:31-63` (#602, LANDED)                | Allocates vnode + sets type=CHRDEV/refcount=1; leaves ops_ptr=0. `_tty0` is non-zero on return.                           |
| `vnode_slot(idx)`          | `core/fs/vnode_pool.pdx:148-159` (#571, LANDED)         | Returns `&_vnode_pool[idx*64]` in `rax`. Leaf; no clobbers.                                                               |
| `_vnode_pool`              | `core/fs/vnode_pool.pdx:48` (#571, LANDED)              | 16 KiB @align(64); each slot is 64 B; slot 0 reserved.                                                                     |
| `VOPS_*_OFFSET` constants  | `core/fs/vops.pdx:45-51` (#572, LANDED)                 | +0/+8/+16/+24/+32/+40/+48 — table slot layout, frozen for R16 series.                                                     |
| `VNODE_OPS_PTR_OFFSET`     | `core/fs/vops.pdx:54` (#572, LANDED)                    | +24 — target byte offset of the wire step §5.2.                                                                            |
| `VOPS_ERR_NOT_SUPPORTED`   | `core/fs/vops.pdx:58` (#572, LANDED)                    | 0xFFFFFFFFFFFFFFFF sentinel returned by every dispatcher on null slot or null ops_ptr.                                    |
| `vops_read` / `vops_lookup`| `core/fs/vops.pdx:66-86 / 175-195` (#572, LANDED)       | Dispatchers used by the witness's sub-tests C and A.                                                                       |
| `_tmpfs_vops` populator    | `core/fs/tmpfs/vops.pdx:178-210` (#586, LANDED)         | Structural precedent for `lea rip+sym; mov [r8+disp],rax` ×7 populator idiom used verbatim here (with only 4 populated).  |
| `uart_puts`                | `core/uart/*` (#601 and prior, LANDED)                  | Witness marker emit path.                                                                                                  |
| `push`/`pop r12`           | Ubiquitous witness idiom                                | Callee-save preservation across `uart_puts` / `vnode_slot` / `vops_*` calls.                                              |

### 2.2 What is NOT in place

- **No `src/kernel/core/tty/vops.pdx`.** This issue creates it,
  populating the module directory scaffold that #602 established.
- **No `src/kernel/core/tty/read.pdx` or `write.pdx`.** #602's
  design doc §3.1 enumerated these as post-#602 additions; this
  issue creates the minimal correct versions that #605/#606/#607
  will extend.
- **No `_tty_vops` / `tty_open` / `tty_close` / `tty_read` /
  `tty_write` symbols.** Grep across `src/` confirms no prior
  reference. This issue is the sole allocator for the storage
  cell and the sole definer of every primitive.
- **No `tty_vops_init` call site in kernel_main.pdx.** Inserted
  immediately after `tty_init_witness_done:` (line 4253) and
  before the R14b-m5-002 GS_BASE `wrmsr` block (currently at
  line 4255 area). See §4.1 for the exact insertion point.
- **No `tty_vops_ok_msg` / `tty_vops_fail_msg` in `tools/
  boot_stub.S`.** Added alongside the R16.M5-001 witness strings
  (see §5.4).

### 2.3 Encoder gaps

**None.** Every mnemonic used has landed precedent:

| Mnemonic                        | Proven at                                                                    |
|---------------------------------|------------------------------------------------------------------------------|
| `lea r64, [rip + sym]`          | Ubiquitous; `tmpfs/vops.pdx:184-204` uses it exactly 8× in the populator.    |
| `mov [r64 + imm8], r64`         | `tmpfs/vops.pdx:187-205` — the populator's 7 slot stores.                    |
| `mov r64, [rip + sym]` (load)   | Ubiquitous (`_tty0` load, `_tmpfs_root_idx` load, etc.).                     |
| `mov r64, [r64 + imm8]` (load)  | Ubiquitous (vops dispatchers, vnode field loads).                            |
| `and r64, imm32` (0xFFFF fits)  | `core/fs/mount.pdx:173`; `fd_inherit.pdx` — u16 extract idiom.                |
| `xor r64, r64` (or `xor eax, eax`) | Ubiquitous "return 0" and "arg = 0" idioms.                              |
| `mov r64, imm64`                | `core/fs/vops.pdx:83` — E_NOT_SUPPORTED sentinel.                            |
| `cmp r64, r64` / `cmp r64, imm` | Ubiquitous.                                                                  |
| `je` / `jne` / `jmp`            | Ubiquitous.                                                                  |
| `call sym` (direct)             | Ubiquitous.                                                                  |
| `push r64` / `pop r64`          | Ubiquitous witness idiom for r12 preservation.                               |
| `ret`                           | Ubiquitous.                                                                  |

No SIB, no REX.B-extended-base beyond r8/r12, no shift-by-reg, no
`jmp reg64`. **Cross-repo escalation not needed.**

## 3. Design

### 3.1 File and module structure

Three new files under `src/kernel/core/tty/`:

```
src/kernel/core/tty/
    init.pdx        (#602, LANDED — unchanged)
    vops.pdx        <-- THIS ISSUE (#603) — _tty_vops + tty_open + tty_close + tty_vops_init
    read.pdx        <-- THIS ISSUE (#603) — tty_read (minimal; extended at #606)
    write.pdx       <-- THIS ISSUE (#603) — tty_write (minimal; extended at #607)
    line_buffer.pdx (#604 — future)
    process_input.pdx (#605 — future)
```

Module names: `Vops` (for `vops.pdx`), `Read` (for `read.pdx`),
`Write` (for `write.pdx`). Following #602's `Init` module naming.

**Why three files, not one.** Each primitive's body will grow in
its dedicated issue:

- `tty_read` will grow **substantially** at #606 (blocking on
  line-ready notification, copy-out of line buffer, buffer
  head/tail advance).
- `tty_write` will grow at #607 (byte-loop with `\n → \r\n`
  translation, UART TX per byte via `uart_putc`).
- `tty_open` and `tty_close` are permanent 2-instruction no-ops
  (character device has no per-open state at R16.M5, and this
  is not expected to change even in R18+ multi-tty — the per-open
  state would live on the fd_entry, not the vnode).

Splitting now avoids future churn: the #606/#607 issues touch only
their target file. `vops.pdx` stays a table + init module,
untouched by primitive-body evolution. This matches the tmpfs
layout precedent (`tmpfs/vops.pdx` for table + adapters + stubs;
`tmpfs/read.pdx`, `write.pdx`, `lookup.pdx`, `unlink.pdx`,
`create.pdx` for primitives).

### 3.2 The `_tty_vops` table — 4 populated + 3 deliberate nulls

The table is a `[u64; 7]` allocated in `.bss` with `@align(8)`,
mirroring `_tmpfs_vops`. All 7 slots initialized by
`tty_vops_init` (§3.4). Layout:

| Offset (const)               | Slot | Vops op   | Points to      | Rationale                                                    |
|------------------------------|------|-----------|----------------|--------------------------------------------------------------|
| `VOPS_READ_OFFSET`   (+0)    | 0    | `read`    | `tty_read`     | Minimal at #603 (returns 0 = no data); extended at #606       |
| `VOPS_WRITE_OFFSET`  (+8)    | 1    | `write`   | `tty_write`    | Minimal at #603 (returns len = accepted); extended at #607    |
| `VOPS_OPEN_OFFSET`   (+16)   | 2    | `open`    | `tty_open`     | Permanent no-op (returns 0 = success); §3.3                   |
| `VOPS_CLOSE_OFFSET`  (+24)   | 3    | `close`   | `tty_close`    | Permanent no-op (returns 0 = success); §3.3                   |
| `VOPS_LOOKUP_OFFSET` (+32)   | 4    | `lookup`  | 0 (null)       | CHRDEV has no children — E_NOT_SUPPORTED is correct; §3.2.1   |
| `VOPS_CREATE_OFFSET` (+40)   | 5    | `create`  | 0 (null)       | CHRDEV cannot have children — E_NOT_SUPPORTED is correct      |
| `VOPS_UNLINK_OFFSET` (+48)   | 6    | `unlink`  | 0 (null)       | CHRDEV cannot have children — E_NOT_SUPPORTED is correct      |

**All offset immediates in `tty_vops_init` are the frozen
constants from `core/fs/vops.pdx`** — this module does NOT
hard-code `0, 8, 16, 24, 32, 40, 48`. That coupling flows through
the single source of truth pinned by #572 §4.

#### 3.2.1 Divergence from the tmpfs `open/close` stub decision

`_tmpfs_vops` (#586 §6.2) rejected null slots for `open` and
`close`, arguing that E_NOT_SUPPORTED would fail `sys_open` /
`sys_close` on any tmpfs file. **For `lookup` / `create` /
`unlink`, tmpfs populates real adapters** because tmpfs is a
hierarchical FS — a directory has children.

TTY inverts this for lookup/create/unlink:

- **A CHRDEV has no children.** A tty vnode is a leaf in the
  filesystem graph. `path_resolve` walking into `/dev/tty0` and
  then trying to walk into `/dev/tty0/something` would call
  `vops_lookup` on the tty vnode. E_NOT_SUPPORTED is the
  correct outcome — that path element does not exist.
- **`sys_create` at `/dev/tty0/foo` should fail loudly.**
  Same argument.
- **`sys_unlink` at `/dev/tty0/foo` should fail loudly.**
  Same argument.

For open/close, TTY populates real primitives (stubs that return
0) for the same reason tmpfs does — `sys_open("/dev/tty0")` and
`sys_close(fd)` must succeed. tmpfs uses stubs (`_tmpfs_open_stub`
returns 0); TTY does the same (`tty_open` returns 0). No divergence
here.

**Summary of the two backends' choices:**

| Slot          | tmpfs             | tty                        | Reason for the divergence                                  |
|---------------|-------------------|----------------------------|------------------------------------------------------------|
| `read`        | adapter → prim    | direct prim                | tty is idx-agnostic (single instance)                       |
| `write`       | adapter → prim    | direct prim                | same                                                        |
| `open`        | stub → 0          | stub → 0                   | both: no per-open state                                     |
| `close`       | stub → 0          | stub → 0                   | both: no per-open teardown                                  |
| `lookup`      | adapter → prim    | **null (E_NOT_SUPPORTED)** | tmpfs is hierarchical; tty is a leaf                        |
| `create`      | adapter → prim    | **null (E_NOT_SUPPORTED)** | same                                                        |
| `unlink`      | adapter → prim    | **null (E_NOT_SUPPORTED)** | same                                                        |

The tty pattern is expected to hold for every future CHRDEV
backend (`/dev/null`, `/dev/random`, `/dev/console` when they
land at R17+). Only pseudo-directory devices (`/proc`,
`/sys` at R18+) would populate lookup slots.

### 3.3 Primitives — 4 leaves

#### 3.3.1 `tty_open(vn, flags) -> u64` — permanent no-op

```asm
; vops signature: open(vn, flags)  [rdi=vn, rsi=flags]
; TTY has no per-open state at any R16 milestone.
tty_open:
    xor  eax, eax           ; return 0 (success)
    ret
```

**Instruction count**: 2. Leaf. `vn` and `flags` ignored.

#### 3.3.2 `tty_close(vn) -> u64` — permanent no-op

```asm
; vops signature: close(vn)  [rdi=vn]
; TTY has no per-open teardown at any R16 milestone.
tty_close:
    xor  eax, eax           ; return 0 (success)
    ret
```

**Instruction count**: 2. Leaf. `vn` ignored.

Justification for permanence: At R18+ multi-tty, per-open state
(controlling-terminal PID, cooked-mode toggle) lives on the
fd_entry (per-fd state), not the vnode (per-device state). tty_open
/ tty_close on the vnode remain no-ops. If a future backend needs
per-open bookkeeping (unlikely for character devices), the
primitives would be extended; the vops slot pointer stays stable.

#### 3.3.3 `tty_read(vn, buf, len, off) -> u64` — minimal at #603

```asm
; vops signature: read(vn, buf, len, off)
;   [rdi=vn, rsi=buf, rdx=len, rcx=off]
; #603: no line buffer exists yet; return 0 = "no bytes available".
; #606: rewritten to block-until-line-ready + copy-out from _tty_line_buf.
tty_read:
    xor  eax, eax           ; return 0 (no bytes)
    ret
```

**Instruction count**: 2. Leaf. All args ignored.

**Semantic correctness at #603**: "no bytes available right now"
is a valid `read` return per POSIX (would be `EAGAIN` in
non-blocking mode, but at R16 the caller has no fd-level flag
distinction). #606 extends this to the cooked-mode blocking read.
The vops slot pointer at `_tty_vops[+0]` stays stable — only the
body of `tty_read` changes.

**This is NOT a stub in the discipline sense.** The R16.M5 issue
body's "no stubs" clause forbids placeholder code that fakes
absent behavior. `tty_read` at #603 encodes the correct behavior
**given the current state of the subsystem**: there is no line
buffer, so no line is available, so read returns 0. The primitive
grows monotonically at #606 — same file, same symbol, same slot
pointer, larger body.

#### 3.3.4 `tty_write(vn, buf, len, off) -> u64` — minimal at #603

```asm
; vops signature: write(vn, buf, len, off)
;   [rdi=vn, rsi=buf, rdx=len, rcx=off]
; #603: no UART wiring yet through TTY; return len = "bytes accepted".
; #607: rewritten to byte-loop with \n→\r\n translation + uart_putc emit.
tty_write:
    mov  rax, rdx           ; return len (bytes accepted; caller sees full write)
    ret
```

**Instruction count**: 2. Leaf. `vn` / `buf` / `off` ignored;
`len` from `rdx` returned in `rax`.

**Semantic correctness at #603**: The vops write contract is
"return bytes written." Returning `len` claims all bytes were
written — from the caller's perspective (which at R16.M5 is the
witness alone; no init fd wire yet at #608), the buffer is
consumed. No UART TX happens, so no observable side effect —
which is acceptable because the only caller at #603 landing is
the witness that ignores the return path anyway. #607 replaces
the body with the real UART TX + translation.

**Alternative considered**: return 0 (0 bytes written). Rejected
because a subsequent caller (e.g., if #608 or a later regression
test invokes tty_write before #607 lands) would loop retrying,
believing no progress was made. Returning `len` is the
"lie forward" that keeps callers unblocked during the M5
build-out. This is documented as a temporary contract in the
body comment; #607's landing turns the lie into truth.

**Not a stub per the discipline argument**: same reasoning as
§3.3.3 — this is the current-state-correct body of a primitive
whose semantics deepen at #607.

### 3.4 `tty_vops_init` — populator + wire step (one atomic function)

**Choice: fold both populate AND wire into one function.**
Alternative considered was to split them: `tty_vops_init` (populate
table only) + `tty_vops_wire` (write `_tty0.ops_ptr`) as two
functions called separately from `kernel_main`. Rejected because:

- **One transition, one function.** The "TTY vops bring-up" is
  logically atomic — no code path in the kernel wants the table
  populated but the vnode not wired, or vice versa. Splitting
  invites a witness-time race where a partial state is observed.
- **Precedent.** `tmpfs_vops_init` (#586) is a single function
  that does the population (tmpfs's transition is populate-only
  because tmpfs vnodes are ephemeral — allocated per `sys_open`
  at R16.M3+, so there's no persistent vnode to wire at boot).
  TTY has the added wire step, but the "one function per
  transition" shape carries over.
- **`_tty0` dependency is trivial to check.** The function reads
  `_tty0` once. If it's 0 (pre-init sentinel, would indicate
  `tty_init` never ran), the wire step is skipped — a soft
  no-op that returns 0 rather than corrupting slot 0's ops_ptr.
  In practice `tty_init` is guaranteed to have run first because
  `kernel_main` calls them in order (§4.1); the guard is a
  belt-and-suspenders safety net.

**Explicitly rejecting the alternative of extending `tty_init`
itself to do the wire step:**

The task-brief steer suggested modifying `tty_init` in `init.pdx`
to add `mov [rax + 24], &_tty_vops` at the end of the field
writes. This works — it's 2 additional instructions in `tty_init`
— but:

1. **Couples `init.pdx` to `vops.pdx` at the symbol level.**
   `init.pdx` would need to reference `_tty_vops`, a forward
   reference to a module it currently has no knowledge of. Every
   future TTY vnode allocator (multi-tty at R18+) would either
   duplicate the wire step or refactor to a shared helper.
2. **Silently regresses the #602 landing's contract.** #602
   §3.3's contract postcondition #6 is `ops_ptr == 0 (deferred
   to #603)`. Modifying `tty_init` changes this postcondition,
   requiring #602's design doc to be amended. Adding a separate
   `tty_vops_init` in this issue's file (`vops.pdx`) leaves
   `tty_init` byte-identical.
3. **Puts vops-layer concern in the init-layer file.** The
   architectural separation "init.pdx owns the vnode; vops.pdx
   owns the vops table" reads more cleanly if the wire step
   (which touches both) lives with the newer of the two — the
   one where the vops table is defined.

Going with `tty_vops_init` in `vops.pdx` that does both. This is
where I differ from the task-brief steer; the architectural
argument above justifies the deviation.

### 3.5 `tty_vops_init` body

```asm
; ================================================================
; tty_vops_init() -> u64
;   Populate _tty_vops with 4 primitive pointers (read/write/open/
;   close) + wire _tty0's vnode's ops_ptr @+24 to &_tty_vops.
;   Idempotent. Returns 0 on success.
;
;   Non-leaf: nested call to vnode_slot. No callee-save touched.
; ================================================================
tty_vops_init:
    ; ---- Populate _tty_vops slots (4 populated; 3 stay null from .bss) ----
    lea  r8, [rip + _tty_vops]

    lea  rax, [rip + tty_read]
    mov  [r8 + 0], rax                     ; VOPS_READ_OFFSET

    lea  rax, [rip + tty_write]
    mov  [r8 + 8], rax                     ; VOPS_WRITE_OFFSET

    lea  rax, [rip + tty_open]
    mov  [r8 + 16], rax                    ; VOPS_OPEN_OFFSET

    lea  rax, [rip + tty_close]
    mov  [r8 + 24], rax                    ; VOPS_CLOSE_OFFSET

    ; Slots +32 (lookup), +40 (create), +48 (unlink) stay null from .bss
    ; zero-init. See §3.2.1 for the CHRDEV-no-children rationale.

    ; ---- Wire _tty0's vnode's ops_ptr @+24 to &_tty_vops ----
    ; Guard: if _tty0 == 0 (tty_init never ran), skip the wire step
    ; without corrupting slot 0. Belt-and-suspenders; kernel_main
    ; guarantees the call order (§4.1).
    mov  rax, [rip + _tty0]
    cmp  rax, 0
    je   tty_vops_init_no_tty0

    and  rax, 0xFFFF                       ; extract u16 idx from u64 slot
    sub  rsp, 8                            ; SysV alignment pad around vnode_slot
    mov  rdi, rax
    call vnode_slot                        ; rax = &_vnode_pool[idx]
    add  rsp, 8

    lea  rcx, [rip + _tty_vops]
    mov  [rax + 24], rcx                   ; VNODE_OPS_PTR_OFFSET

tty_vops_init_no_tty0:
    xor  eax, eax                          ; return 0
    ret
```

**Instruction count**: ~20 body + labels. One nested call
(`vnode_slot`) — this is NOT a leaf. See §3.7 for register/stack
discipline.

### 3.6 Why no adapter layer (contrast with tmpfs)

tmpfs shipped 5 adapters (`_tmpfs_read_adapter`, ...) to bridge
the vops-signature (`vnode_ptr` in rdi) to tmpfs-primitive
signature (`inode_idx` in rdi). At R16.M2 tmpfs already had
multiple inodes and needed per-vnode identity.

TTY at R16.M5 has **exactly one instance** (`_tty0`). Every
`tty_read` invocation reaches the same singleton line buffer;
every `tty_write` reaches the same singleton UART. The primitives
are **vnode-agnostic** — they ignore `rdi` entirely and access
their state via well-known static symbols (`_tty_line_buf` at
#604, `_uart_rx_ring` / UART TX registers at R16.M4).

This means the vops table can point **directly** at the
primitives. No adapter, no `backend_ptr` extraction, no
signature bridging. Simplest possible vops layout for a backend.

**Migration path for multi-tty (R18+).** When `/dev/ttyS1`,
`/dev/tty1`, or pty pairs land, each tty vnode's identity will
matter (which line buffer, which UART). The migration is:

1. Extend `_tty_line_buf` to an array indexed by tty_idx.
2. Add `_tty_uart_map` — an array mapping tty_idx to UART base.
3. Add adapters (`_tty_read_adapter`, etc.) that extract tty_idx
   from `vn.backend_ptr` (frozen: low 16 bits hold tty_idx),
   dispatch to `tty_read(tty_idx, buf, len, off)`.
4. Rewrite `_tty_vops` to point at adapters instead of primitives.
5. Rewrite each primitive's signature to take `tty_idx` in rdi.

**Cost of that migration**: ~5 adapters × ~7 instructions each
= ~35 instructions of new code + signature changes on 4
primitives. Comparable to the tmpfs adapter layer's cost. This
issue's "point directly at primitives" choice is not a dead-end —
it's the minimum viable shape at R16.M5, and the migration is
mechanical.

**Decision recorded here so R18+ doesn't relitigate**: multi-tty
migration will preserve the vops table shape (7 slots, same
offsets) and extend the primitive-signature convention. No vops
freeze breakage.

### 3.7 Register and stack discipline

`tty_vops_init` is NOT a leaf: it calls `vnode_slot`. SysV
AMD64 requires `rsp % 16 == 0` at every nested `call`.

- Entry: `rsp % 16 == 8` (post outer-call push of return addr).
- The `sub rsp, 8 / call vnode_slot / add rsp, 8` triad restores
  `rsp % 16 == 0` at the callee's entry. Same pattern as every
  vops dispatcher (`core/fs/vops.pdx` §post-verify amendment) and
  every tmpfs adapter (`tmpfs/vops.pdx:41-46`).
- **No prologue pushes.** `vnode_slot` is a leaf and doesn't
  touch any callee-save reg (per vnode_pool.pdx contract), so no
  save/restore needed. `r8` is caller-save and used as scratch
  across the wire step — safe because `vnode_slot` doesn't
  touch `r8`.

For the 4 primitives (`tty_read`, `tty_write`, `tty_open`,
`tty_close`) — all leaves. No prologue, no epilogue, no
alignment concerns. `rax` is the only writer; every other reg
untouched.

## 4. Integration points

### 4.1 kernel_main.pdx insertion

Insert **one new call** immediately after `tty_init_witness_done:`
(currently line 4253) and the tty_vops_witness block right after
that. The final structure:

```
uart_rx_smoke_witness_done:
    pop r12

; ============================================================
; R16-M5-001 (#602): tty_init witness  (UNCHANGED)
; ============================================================
tty_init_witness:
    ...  (unchanged)
tty_init_witness_done:
    pop r12

; ============================================================
; R16-M5-002 (#603): tty_vops table wire-up + witness
; ============================================================
call tty_vops_init                          ; populates + wires ops_ptr

tty_vops_witness:
    ...  (§5.2 body)
tty_vops_witness_done:

; R14b-m5-002 (#507): IA32_GS_BASE = &_cpu_locals[0] on CPU0.
lea rax, [rip + _cpu_locals];
...
```

**Ordering guarantee**: `tty_init` runs first (inside the #602
witness), then `tty_vops_init` — so `_tty0 != 0` when
`tty_vops_init`'s wire step reads it. The `_tty0 == 0` guard in
`tty_vops_init` (§3.5) is defense-in-depth.

**No modification to any previously-landed witness block.** The
#602 witness is byte-identical.

### 4.2 boot_stub.S — 2 new rodata strings

Append after the R16-M5-001 witness strings (`tty_ok_msg` /
`tty_fail_msg` at approximately lines 764-772):

```asm
# R16-M5-002 (#603): tty_vops_init witness success message
.global tty_vops_ok_msg
.align 8
tty_vops_ok_msg: .ascii "R16 TTY VOPS OK\n\0"

# R16-M5-002 (#603): tty_vops_init witness failure message
.global tty_vops_fail_msg
.align 8
tty_vops_fail_msg: .ascii "R16 TTY VOPS FAIL\n\0"
```

### 4.3 Expected-output fingerprint files

Insert `R16 TTY VOPS OK` in three files:

| File                                        | Insert after           | Insert before        |
|---------------------------------------------|------------------------|----------------------|
| `tests/r14b/expected-boot-r14b-loader.txt`  | `R16 TTY VNODE OK`     | `LOADER OK`          |
| `tests/r15/expected-boot-r15-ring3.txt`     | `R16 TTY VNODE OK`     | `R15 IDLE TASK OK`   |
| `tests/r15/expected-boot-r15-process.txt`   | `R16 TTY VNODE OK`     | `R15 IDLE TASK OK`   |

Contains-in-order matching (per `tools/run-smoke.sh`) makes this
strictly additive.

## 5. Test canary — kernel_main witness block

### 5.1 Sub-test structure — 3 sub-tests, chosen for coverage-per-cost

**Three sub-tests, each end-to-end, chosen to jointly cover all
9 postconditions from §1.**

- **Sub-test A** — `vops_lookup(&_tty0_vnode, name=NULL)` returns
  `VOPS_ERR_NOT_SUPPORTED` (0xFFFFFFFFFFFFFFFF).
  - Proves: postcondition #5 (`_tty_vops[+32] == 0`), postcondition
    #8 (`_tty0.ops_ptr == &_tty_vops`), AND the null-slot
    dispatcher path in `vops_lookup` (already tested by #572's own
    witness but re-verified here in the composed setting).
  - Rationale: this is the sub-test that would fail loudly if the
    tmpfs-style "fill all 7 slots with success stubs" mistake were
    made here. If `_tty_vops[+32]` were accidentally populated
    with, say, `tty_open` (a return-0 stub), the dispatch would
    return 0, not `VOPS_ERR_NOT_SUPPORTED`. Sub-test A distinguishes.
- **Sub-test B** — `vops_open(&_tty0_vnode, flags=0)` returns 0.
  - Proves: postcondition #3 (`_tty_vops[+16] == &tty_open`),
    postcondition #8, AND that `tty_open` returns 0.
  - Also transitively proves postcondition #4 (close symmetric —
    same dispatch shape, different slot — a wiring error in slot
    +16 vs +24 would fail one of the two).
- **Sub-test C** — `vops_read(&_tty0_vnode, buf=0, len=0, off=0)`
  returns 0.
  - Proves: postcondition #1 (`_tty_vops[+0] == &tty_read`),
    postcondition #8 (ops_ptr wired), postcondition #9 (end-to-end
    read dispatch), AND that `tty_read` returns 0.
  - This is the "structural equivalent" of the formal AC per §1.1.

**Coverage of the 9 postconditions**:

| Postcondition                                | Covered by                     |
|----------------------------------------------|--------------------------------|
| #1: `_tty_vops[+0] == &tty_read`             | Sub-test C (dispatch reaches it) |
| #2: `_tty_vops[+8] == &tty_write`            | Symmetry with #1; if slot +8 were mis-wired to a non-write primitive, and #607 later dispatches through it, the failure would surface at #607's witness. Not directly asserted here — accepted risk (§5.1.1). |
| #3: `_tty_vops[+16] == &tty_open`            | Sub-test B                      |
| #4: `_tty_vops[+24] == &tty_close`           | Symmetry with #3; same dispatch shape.  Not directly asserted here — accepted risk. |
| #5: `_tty_vops[+32] == 0`                    | Sub-test A                      |
| #6: `_tty_vops[+40] == 0`                    | Symmetry with #5; same dispatch shape. Not directly asserted here — accepted risk. |
| #7: `_tty_vops[+48] == 0`                    | Symmetry with #5; same dispatch shape. Not directly asserted here — accepted risk. |
| #8: `_tty0.ops_ptr == &_tty_vops`            | Sub-tests A, B, C (each requires it to succeed) |
| #9: `vops_read` end-to-end returns 0         | Sub-test C                      |

#### 5.1.1 Accepted risk: pointer-identity of unwitnessed slots

Postconditions #2, #4, #6, #7 are not directly asserted. A
mis-wiring of any of those slots (say, `_tty_vops[+8]` set to
`&tty_read` instead of `&tty_write`) would ship undetected past
this witness. The mitigations:

1. **The populator body has 4 sequential `lea rax, [rip + tty_*]
   ; mov [r8 + N], rax` pairs — visual diff catches a swap.**
   The pattern is regular; a swap is visible in code review at a
   glance.
2. **Any subsequent dispatch through the mis-wired slot would
   fail loudly.** #607's witness will invoke `vops_write` on
   `_tty0`; if slot +8 points at `tty_read` (returns 0), a write
   of "hi\r\n" would return 0 instead of 5, and #607's canary
   catches it.
3. **Pointer-identity witness for all 7 slots is available as a
   fallback.** The tmpfs precedent's 7 sub-tests A-G (§7.2) is the
   template. We could add 4 more sub-tests here (~15 more lines
   of witness) to cover #2, #4, #6, #7 directly. The trade-off
   is witness bloat versus catch-window. I recommend the 3-sub-test
   version at first-pass landing; if a #607 (or later) failure
   traces back to a #603 mis-wire, we backfill the pointer-identity
   sub-tests.

**Alternative considered**: expand to 7 sub-tests (4 pointer-identity
+ 3 end-to-end). Rejected on the "witness size ~ 100 LOC would
double" trade-off — same coverage at first-pass landing is not worth
the extra 50 LOC. The 3-sub-test version is chosen; §5.1.1's
mitigation argument is on record.

### 5.2 Witness assembly (complete block)

```asm
; ============================================================
; R16-M5-002 (#603): tty_vops_init witness — 3 sub-tests, 1 marker
;
; Runs immediately after `call tty_vops_init` populates the table
; and wires _tty0.ops_ptr. Sub-tests exercise the vops dispatch
; chain end-to-end for one populated slot (read), one populated
; stub slot (open), and one deliberately-null slot (lookup).
; ============================================================
tty_vops_witness:
    push r12                              ; callee-save: carries &_tty0_vnode
                                          ; across uart_puts and vops_* calls

    ; ---- Recover &_tty0's vnode (used by all 3 sub-tests) ----
    mov  rax, [rip + _tty0]               ; load u64 slot
    and  rax, 0xFFFF                      ; extract u16 idx
    mov  rdi, rax
    call vnode_slot                       ; rax = &_vnode_pool[tty_idx]
    mov  r12, rax                         ; r12 = &_tty0_vnode

    ; ---- Sub-test A: vops_lookup on null slot returns E_NOT_SUPPORTED ----
    mov  rdi, r12                         ; dir_vn = &_tty0_vnode
    xor  rsi, rsi                         ; name_ptr = 0 (unused; dispatcher
                                          ;   short-circuits on null slot)
    call vops_lookup                      ; -> _tty_vops[+32] == 0
                                          ; -> VOPS_ERR_NOT_SUPPORTED
    mov  rcx, 0xFFFFFFFFFFFFFFFF          ; E_NOT_SUPPORTED sentinel
    cmp  rax, rcx
    jne  tty_vops_witness_fail

    ; ---- Sub-test B: vops_open on wired slot returns 0 ----
    mov  rdi, r12                         ; vn = &_tty0_vnode
    xor  rsi, rsi                         ; flags = 0
    call vops_open                        ; -> _tty_vops[+16] == &tty_open
                                          ; -> tty_open returns 0
    cmp  rax, 0
    jne  tty_vops_witness_fail

    ; ---- Sub-test C: vops_read on wired slot returns 0 ----
    mov  rdi, r12                         ; vn = &_tty0_vnode
    xor  rsi, rsi                         ; buf = 0
    xor  rdx, rdx                         ; len = 0
    xor  rcx, rcx                         ; off = 0
    call vops_read                        ; -> _tty_vops[+0] == &tty_read
                                          ; -> tty_read returns 0
    cmp  rax, 0
    jne  tty_vops_witness_fail

    ; ---- All green ----
    lea  rdi, [rip + tty_vops_ok_msg]
    call uart_puts
    jmp  tty_vops_witness_done

tty_vops_witness_fail:
    lea  rdi, [rip + tty_vops_fail_msg]
    call uart_puts

tty_vops_witness_done:
    pop r12
```

**Instruction count**: ~35 including labels + push/pop pair.
Slightly larger than tmpfs's per-slot pointer-identity witness
(§7.2 of #586) because each sub-test does a full dispatch instead
of a pointer compare, but simpler in that we don't need to
allocate a scratch vnode (we use the real `_tty0` vnode via
`vnode_slot`).

**Register discipline**: `push r12` before sub-tests balances
`pop r12` at the exit label. `r12` carries the vnode ptr across
`uart_puts` (which is caller-save-hostile per its own signature).
`rsp % 16 == 0` inside the witness (post-push) so nested calls
(`vnode_slot`, `vops_lookup`, `vops_open`, `vops_read`,
`uart_puts`) land at the required SysV alignment. Same pattern as
the #602 witness at kernel_main.pdx:4214.

### 5.3 Marker

On all three sub-tests green:

```
R16 TTY VOPS OK
```

Fingerprint added to all three R14B/R15 expected-output files.
Contains-in-order matching (per `tools/run-smoke.sh` §L28
comment) makes the addition strictly additive.

## 6. Alternatives considered / follow-ups

### 6.1 Populate all 7 slots (fill lookup/create/unlink with return-error stubs)

**Rejected.** The null-slot semantic in `vops.pdx` (return
`VOPS_ERR_NOT_SUPPORTED`) is exactly what we want for
CHRDEV-inappropriate operations. A stub that returns
`VOPS_ERR_NOT_SUPPORTED` explicitly would be functionally
equivalent but adds 3 extra 2-instruction functions and 3 extra
populator writes for no observable difference. The .bss
zero-init already gives us the correct behavior — free of cost.

Also: tests demonstrating "lookup on a chrdev is not supported"
would fail identically whether the slot is null or a return-error
stub; the sentinel is the same. So no debuggability advantage
either.

### 6.2 Split `tty_vops_init` into `tty_vops_populate` + `tty_vops_wire`

**Rejected.** See §3.4 second half. One transition, one function.
Idempotent. `_tty0 == 0` guard handles the ordering violation
softly.

### 6.3 Extend `tty_init` to do the wire step

**Rejected.** See §3.4 third half. Would couple `init.pdx` to
`vops.pdx` and regress the #602 landing's `ops_ptr = 0` contract.

### 6.4 Skip creating `tty_read` / `tty_write` files at #603; add them at #605/#607

**Rejected.** The vops populator needs symbol addresses at
`lea rip + sym` time — `tty_read` and `tty_write` must be defined
symbols at link time when `tty_vops_init` is assembled. If we
skip them at #603, the populator can't populate slots +0 / +8,
and sub-tests B/C fail (or the linker fails, depending on
whether the encoder catches missing forward references).

**The alternative** — populating slots +0/+8 with null and having
#605/#607 backfill — is inconsistent: it'd say "sys_read / sys_write
on TTY fail with E_NOT_SUPPORTED until #605/#607", which is
technically true but hostile to any intermediate integration
testing (e.g., a #608 fd-inheritance witness that wants to prove
TTY read/write are reachable via fd).

Creating minimal primitives at #603 is the right shape. §3.3
justifies each primitive's minimal body as current-state-correct,
not a stub.

### 6.5 Emit `R16 TTY VOPS OK` from within `tty_vops_init`

**Rejected.** Same discipline as every other R16 primitive:
callers own emission. `tty_vops_init` is a driver primitive that
may be called from non-witness contexts in R18+ (multi-tty). See
#602 §6.6 for the same argument.

### 6.6 Use a static initializer for `_tty_vops` instead of a runtime populator

**Rejected.** paideia-as does not (yet) resolve symbol addresses
into static initializers of `[u64; N]` arrays. Same encoder gap
that #586 §6.6 called out. When the paideia-as syntax for
symbol-in-initializer lands, `tty_vops_init` collapses to a null
function (or vanishes entirely, since the wire step could be
part of `tty_init` at that point). Deferred to a follow-on issue
in the paideia-as backlog.

### 6.7 Merge `read.pdx` and `write.pdx` back into `vops.pdx`

**Rejected.** #606 will grow `tty_read` substantially (~50 LOC
with the blocking + copy-out); #607 will grow `tty_write` by
~30 LOC with translation loop. Keeping each primitive in its
own file matches tmpfs's per-primitive file split and avoids
`vops.pdx` becoming a catch-all module. Also matches the tactical
plan's per-file "Touching" annotations (each of #605/#606/#607
touches exactly one primitive's file, not `vops.pdx`).

## 7. Invariants

### 7.1 `_tty_vops[+0..+24]` are non-null after `tty_vops_init` returns

Guaranteed by the 4 populator writes. Verified transitively by
sub-tests B (open slot) and C (read slot). Not directly verified
for slots +8 (write) and +24 (close) — see §5.1.1 for the
accepted-risk rationale.

### 7.2 `_tty_vops[+32..+48]` stay null

Guaranteed by `.bss` zero-init and no populator write to those
offsets. Verified by sub-test A (lookup slot returns E_NOT_SUPPORTED,
which requires slot +32 to be null).

### 7.3 `_tty0.ops_ptr == &_tty_vops` after `tty_vops_init` returns

Guaranteed by the wire step (`mov [rax + 24], rcx` where `rax =
vnode_slot(_tty0 & 0xFFFF)` and `rcx = &_tty_vops`). Verified
transitively by all three sub-tests — each requires this
invariant to hold for its dispatch to reach the correct slot.

### 7.4 `#602`'s §7.5 half-live-window strain is closed

Per #602 §7.5, the vnode-layout freeze's "every vnode with `type
!= FREE` has a valid `ops_ptr`" invariant was textually strained
between #602 and #603 landing. After this issue's wire step,
`_tty0.ops_ptr != 0`. Combined with `_tty0.type = CHRDEV` (set
by #602), the freeze is fully re-satisfied. A future boot-time
sweep that asserts "every non-FREE vnode has non-null ops_ptr"
would pass on _tty0 post-#603.

### 7.5 Idempotence

`tty_vops_init` is idempotent — a second call re-populates the
same 4 slots with the same 4 addresses and re-wires the same
`_tty0.ops_ptr` to the same `&_tty_vops`. No observable state
change on the second call. Not exercised by the witness (called
exactly once), but the `_tty0 == 0` guard's `xor eax, eax; ret`
fallthrough also guarantees no crash if invoked before
`tty_init` runs.

## 8. Cross-cutting risks

- **Symbol resolution order.** `_tty_vops` is defined in `vops.pdx`
  but referenced by `tty_vops_init` (same file — trivially resolves)
  AND by any future consumer that wants the table's address.
  `_tty0` is defined in `init.pdx` (#602) and referenced by
  `vops.pdx`'s `tty_vops_init` — cross-module reference; standard
  paideia-as symbol table handles this.
- **`vnode_slot` clobbers.** `vnode_slot` is a leaf per its own
  contract, but leaves `rdi` at whatever the caller passed. `r8`
  (used as the `_tty_vops` base in the populator) is NOT touched
  by `vnode_slot`. Safe.
- **The `_tty0` guard is soft.** If `tty_vops_init` runs before
  `tty_init` (kernel_main call-order regression), the table is
  populated but the wire step is skipped. `_tty0` stays at 0
  (pre-init sentinel). Subsequent `tty_init` would allocate the
  vnode but leave its ops_ptr at 0 — the #602 half-live state.
  No downstream code observes _tty0 at that point in boot (per
  #602 §3.4 analysis), so the failure mode is silent but
  detectable at the next boot-time sub-test that dispatches
  through the vnode. Recommend keeping the ordering strict in
  kernel_main — the current insertion point (§4.1) guarantees it.
- **Sub-test A relies on `vops_lookup`'s null-slot path.** If a
  future amendment to `vops.pdx` (#572) changed the null-slot
  return from `VOPS_ERR_NOT_SUPPORTED` to something else, sub-test
  A would break. Cross-referenced: #572's null-slot semantic is
  frozen at design/kernel/r16-m1-003-vops.md §2.1; any change
  requires that doc's amendment first.
- **Marker line insertion is strictly additive.** No prior
  fingerprint line is reordered. 5-mode smoke (`boot_r8_only`,
  `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) does not
  observe R16 markers — byte-identical fingerprint preserved.

## 9. LOC estimate

| File                                                        | LOC        |
|-------------------------------------------------------------|------------|
| `src/kernel/core/tty/vops.pdx` (new)                        | ~120       |
|   - Module boilerplate + `_tty_vops` storage decl           |  ~15       |
|   - `tty_open` (2 instructions + justification)             |  ~15       |
|   - `tty_close` (2 instructions + justification)            |  ~15       |
|   - `tty_vops_init` (populator + wire step + justification) |  ~55       |
|   - Inline comments / spacers                               |  ~20       |
| `src/kernel/core/tty/read.pdx` (new)                        | ~30        |
|   - Module boilerplate                                      |   ~8       |
|   - `tty_read` minimal body + justification for #603 scope  |  ~22       |
| `src/kernel/core/tty/write.pdx` (new)                       | ~30        |
|   - Module boilerplate                                      |   ~8       |
|   - `tty_write` minimal body + justification for #603 scope |  ~22       |
| `src/kernel/boot/kernel_main.pdx` (call + witness block)    | ~55        |
|   - `call tty_vops_init` line                               |    1       |
|   - Comment banner                                          |   ~8       |
|   - Vnode-ptr recovery preamble                             |   ~6       |
|   - 3 sub-tests                                             |  ~24       |
|   - fail/success labels + marker emit                       |  ~12       |
|   - Inline comments                                         |   ~4       |
| `tools/boot_stub.S` (2 messages)                            |  ~10       |
| 3 expected-output fingerprint files (1 marker each)         |   ~3       |
| `design/kernel/r16-m5-002-tty-vops-table.md` (this doc)     | (this)     |
| **Total executable / testing / test-data**                  | **~248**   |

Executable code path: ~180 LOC (vops.pdx + read.pdx + write.pdx).
Witness + fingerprint: ~68 LOC. Comparable to #586's tmpfs vops
wire-up (~325 LOC) but smaller because TTY has no adapters (§3.6)
and only 4 populated slots instead of 7.

## 10. Tractability

**HIGH — small R16 issue, one populator pattern, three end-to-end
sub-tests.**

- **Zero paideia-as encoder gap.** Every mnemonic proven at
  `core/fs/tmpfs/vops.pdx` (populator + primitives) and
  `core/fs/vops.pdx` (dispatchers). Both patterns landed and
  stable.
- **One nested-call boundary** (`tty_vops_init` → `vnode_slot`).
  Alignment pad idiom from `tmpfs/vops.pdx` verbatim.
- **Four 2-instruction primitive leaves** (`tty_open`, `tty_close`,
  `tty_read`, `tty_write`) — trivial to write, trivial to review.
  `tty_open`/`tty_close` are permanent no-ops; `tty_read`/`tty_write`
  grow monotonically at #605/#606/#607.
- **Three sub-tests** with mechanical structure: each does one
  `vops_*` call on `_tty0`'s vnode and checks the return. No
  fixture allocation (uses the real `_tty0` vnode); no scratch
  vops table (uses the real `_tty_vops`).
- **Marker line is contains-in-order** — strictly additive to
  fingerprints; no reordering risk.
- **No cross-repo escalation risk.**
- **Sizing (~248 LOC total)** is roughly 2× #602's ~116 LOC
  (three primitives + one populator + one witness vs. one init +
  one witness).
- **The literal AC (`vfs_open("/dev/tty0") returns _tty0`) is
  deferred to a follow-on issue** (`#603b devfs-tty-registration`)
  per §1.1. The structural equivalent (3-sub-test witness) is
  accepted here.

Estimated implementation time: **~60 minutes of a workerbee
session** (slightly longer than #602 because of the three new
files and the three-sub-test witness).

Estimated risk of regressing an existing smoke mode:
**near-zero** — purely additive (three new files, one new call
site + one new witness block, one new emit line, two new rodata
strings, one new marker line in three fingerprint files, zero
modifications to any previously-landed source or witness).

**Known follow-ups (do NOT block #603's landing)**:

- **`#603b devfs-tty-registration`** (proposed, not yet filed) —
  Land a devfs backend that publishes `_tty0` as `/dev/tty0`.
  Enables the literal AC `vfs_open("/dev/tty0") returns _tty0`.
  Not blocking any downstream #604..#609 issue.
- **#604 (`tty_line_buffer`)** — `.bss` allocation of the 256-char
  line buffer + head/tail/complete-flag words.
- **#605 (`tty_process_input`)** — feeds bytes from RX
  notification into the line buffer.
- **#606 (`tty_read_blocking`)** — extends `read.pdx`'s `tty_read`
  body to block-until-line-ready + copy-out from `_tty_line_buf`.
  Preserves the `_tty_vops[+0]` slot pointer.
- **#607 (`tty_write_nl_cr`)** — extends `write.pdx`'s
  `tty_write` body to translate `\n → \r\n` + emit through UART TX.
  Preserves the `_tty_vops[+8]` slot pointer.
- **#608 (`connect-tty-to-init-fd012`)** — assigns `_tty0` idx to
  `task[1].fd_table[0/1/2]`. Bumps `_tty0.refcount` from 1 to 4.
- **#609 (R16.M5 CLOSER smoke)** — end-to-end line discipline
  round-trip through the fully-wired vops table.

## 11. References

- Issue: paideia-os#603
- Milestone: paideia-os R16.M5 (TTY / cooked line discipline)
- Prereq issues: #572 (vops layout freeze), #570 (vnode layout
  freeze), #586 (tmpfs vops wire-up — structural sibling), #602
  (tty_init — the vnode allocator whose ops_ptr slot this issue
  writes), #571 (vnode_pool / vnode_slot)
- Blocks: #604..#609 (subsystem 15 tail)
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 15 line 1588, item 2
- Prior-art body pattern: `src/kernel/core/fs/tmpfs/vops.pdx`
  (`_tmpfs_vops` + `tmpfs_vops_init` populator — structural
  precedent used verbatim here for the 4-slot subset)
- Prior-art witness pattern: `src/kernel/boot/kernel_main.pdx`
  §tmpfs_vops witness (§7.2 of #586's doc)
- Layout freeze sources: `design/kernel/vfs-layout.md` §3
  (VNODE_OPS_PTR_OFFSET = +24), `design/kernel/r16-m1-003-vops.md`
  §2 (VOPS_*_OFFSET constants, null-slot semantics)
