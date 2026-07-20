---
issue: 611
milestone: R17.M1 (libc-lite for userland)
subsystem: 16 — libc-lite for userland
prereq:
  - "None (parallelizable with #610 syscall_shim). This module is pure user-space bytes with no syscall or shim dependency."
  - "build-user.sh (R15-M1-003 / #515) already walks src/user/*.pdx and links every .pdx into shell.elf; new file is auto-picked-up."
blocks:
  - "#612 (r17-m1-003-user-memcpy-memset) — parallelizable; different module (also src/user/string.pdx?) — see §2.3 file-topology decision"
  - "#614 (r17-m1-005-user-puts-getline) — puts_c(str) will call strlen(str) to derive count for sys_write; getline uses no string helper"
  - "#615 (r17-m1-006-user-smoke-libc) — libc_test binary exercises strlen('hello')==5 and memcmp cases at runtime; owns the LIBC TEST OK boot marker"
  - "R17.M3 shell (#622+) — parse loop calls strlen on argv strings; memcmp for builtin name dispatch (strcmp deferred to #612)"
touching:
  - src/user/string.pdx                              (new: strlen, memcmp; ~90 LOC)
  - tools/verify-user-string.sh                     (new: build-time symbol + shape canary; ~90 LOC)
  - tools/build-user.sh                             (append verifier invocation; +3 LOC)
  - design/kernel/r17-m1-002-user-string.md         (this doc)
related:
  - "#610 (r17-m1-001-syscall-shim) — landed HEAD 0d47d17; the byte-pattern-canary discipline this issue mirrors is at tools/verify-syscall-shim.sh"
  - "#612 (r17-m1-003-user-memcpy-memset) — sibling under Subsystem 16; adds memcpy/memset (byte-loop or rep prefix — see #612 dispatch)"
  - "#615 (r17-m1-006-user-smoke-libc) — the runtime witness this issue defers to for actual execution of strlen('hello')"
  - "design/milestones/r14b-tactical-plan.md §Subsystem 16 (lines 1635–1710) — the primary interfaces of libc-lite (strlen, strcmp, strncmp, memset, memcpy)"
  - "design/audit/entries/r17-m1-001-syscall-shim.md — the byte-pattern discipline baseline"
  - "src/kernel/core/fs/tmpfs/lookup.pdx:67-92 — the reference inline-byte-loop compare idiom that memcmp mirrors"
  - "src/kernel/core/fs/tmpfs/create.pdx:99-118 — the reference byte-copy loop idiom (cursor + counter + advance)"
  - "src/kernel/core/fs/path.pdx:229-257 — the reference xor+mov_b+cmp+branch idiom for byte inspection"
---

# R17-M1-002 — user strlen + memcmp — byte-loop implementations in `src/user/string.pdx` (#611)

## 1. Scope

Land the first two user-space `libc-lite` string primitives:

- **`strlen(s: u64) -> u64`** — count bytes until first NUL. Return
  the count (excluding the terminator). Undefined for non-NUL-terminated
  input, matching POSIX `strlen(3)`.
- **`memcmp(a: u64, b: u64, n: u64) -> u64`** — compare `n` bytes at
  `a` and `b`. Return `0` if equal across all `n` bytes, else the
  signed difference of the first differing byte (`a[i] - b[i]` where
  `i` is the first index at which `a[i] != b[i]`), zero-extended to
  64 bits.

Both functions are **branching byte-loops**. Neither uses the `rep
movs`/`rep cmps`/`rep scas` prefix family — those are exclusively the
concern of **#612 (`r17-m1-003-user-memcpy-memset`)**, which lands
`memcpy` and `memset`, and (per §Subsystem 16 line 1663) may choose to
use `rep` for the copy path if paideia-as ships the encoding. This
issue is deliberately encoder-conservative: every instruction it emits
already lands elsewhere in the tree (kernel side, via
`src/kernel/core/fs/tmpfs/lookup.pdx`, `.../fs/tmpfs/create.pdx`,
`.../fs/path.pdx`).

Out of scope (deliberately deferred):

- **`strcmp` / `strncmp`.** #612's scope per §Subsystem 16 line 1663
  (tactical plan lists memcpy/memset for that issue, but strcmp/strncmp
  also live in `string.pdx` per plan line 1653). Per the plan's
  primary-interfaces list (line 1653) all five string helpers should
  land in `string.pdx`; this issue scopes down to the two the
  acceptance criterion names (**strlen** in the AC; **memcmp** in the
  title). #612 can either land memcpy/memset in `string.pdx` alongside
  these two, or split into `mem.pdx` — see §2.3.
- **`rep`-prefix implementations.** #612 owns that decision.
- **`memmove`.** Not in R17.M1 primary interfaces; deferred to a
  post-R17 issue if a legitimate overlapping-copy caller emerges.
- **Wide-character or UTF-8-aware variants.** Bytewise semantics only
  at R17.M1; the shell operates on 7-bit-ASCII input per R17.M3.
- **`_user_errno` interaction.** Neither strlen nor memcmp can fail
  in the POSIX sense — no errno path. #613 does not touch this
  module.
- **Runtime AC (calling `strlen("hello")` against a live ring-3
  binary).** The AC's phrasing "fixture calls strlen(...) returns 5"
  is satisfied at R17.M1 by a **build-time byte-shape canary**
  (§4) plus a **compiled fixture** that #615 (`libc_test.pdx`) will
  actually execute when ring-3 loading lands. The precedent is #610
  (`r17-m1-001-syscall-shim`) — that issue also declared its AC
  compile-only and deferred runtime exercise to #615. See §4.3 for
  why a kernel-side runtime witness is rejected here.
- **`R17 STRLEN OK` boot marker.** Not emitted from `kernel_main.pdx`.
  The verifier script (§4.1) emits `R17 USER STRING OK` to stdout of
  `build-user.sh` (not to the boot UART). Every smoke fingerprint
  (`boot_r8_only`, `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`)
  stays byte-identically green through this commit. This matches
  #610's `R17 SYSCALL SHIM OK` discipline exactly.

## 2. Prereq check

### 2.1 What's in place

- **`src/user/` builds today** — `tools/build-user.sh` walks
  `find src/user -name '*.pdx'` (line 20-27) and assembles each into
  `.o`, then links via `link.ld`. Adding `src/user/string.pdx` requires
  **zero** build-script changes for the compile+link path; only the
  post-link verifier invocation (§4.2) needs a one-line update.
- **paideia-as encodes every instruction this issue needs.**
  Enumerated in §2.2 — every mnemonic has ≥2 live callers in the
  kernel tree today. No paideia-as gap.
- **Kernel-side byte-loop reference implementations** — see
  `src/kernel/core/fs/tmpfs/lookup.pdx:67-92` (an inline strncmp,
  the exact structural analog of the memcmp this issue lands) and
  `src/kernel/core/fs/tmpfs/create.pdx:99-118` (an inline bounded
  memcpy, the structural analog of strlen's cursor advance). These
  are the **audited templates** this issue's user-space
  implementations mirror.
- **User-space `pub let` function form is proven** — every wrapper
  in `src/user/syscall_shim.pdx` uses the exact
  `pub let f : (…) -> u64 !{effects} @{caps} = fn(...) -> unsafe {…}`
  form. The new file needs no new syntactic surface.
- **Byte-pattern canary discipline is proven** at
  `tools/verify-syscall-shim.sh` — the objdump-parse-then-compare
  pattern is directly reusable, with a per-function complexity
  adjustment for branch instructions (§4.1).

### 2.2 paideia-as encoder inventory (no gaps expected)

| Mnemonic (form used here)        | Live use site (kernel)                                            |
|----------------------------------|-------------------------------------------------------------------|
| `xor rax, rax` (reg self)        | `src/kernel/core/fs/path.pdx:236, 254`; many more                 |
| `xor rcx, rcx` (reg self)        | `src/kernel/core/fs/vfs_close.pdx:82`; `.../vnode_pool.pdx:64`    |
| `xor r8, r8`  (reg self)         | Not seen at head; `xor r8, r8` = `4D 31 C0` — same REX.WB+31+ModRM family as `xor r9, r9` and `xor r10, r10`. **See §2.4 for verification action**. |
| `mov_b rcx, [rdi]`               | `src/kernel/core/fs/tmpfs/write.pdx:63` (`mov_b rcx, [r15+0]`)    |
| `mov_b rcx, [rsi]`               | `src/kernel/core/fs/path.pdx:237` (via `mov_b rax, [rsi]`)        |
| `mov_b r8,  [rdi]`               | Analogous to `mov_b rax, [r9]` at `.../tmpfs/create.pdx:109` — REX.WR/B extension already exercised (mov_b to r8/r9 also used in `.../fs/tmpfs/init.pdx:53-100`). |
| `cmp rcx, 0`                     | `src/kernel/core/fs/tmpfs/lookup.pdx:79` (`cmp rax, 0`); ubiquitous |
| `cmp rcx, r8` (reg vs reg)       | `src/kernel/core/fs/tmpfs/create.pdx:104` (`cmp rcx, r13`)        |
| `je <label>`                     | `src/kernel/core/fs/tmpfs/lookup.pdx:60, 80`; many more           |
| `jne <label>`                    | `src/kernel/core/fs/tmpfs/lookup.pdx:78`; `.../path.pdx:242`      |
| `jmp <label>` (unconditional)    | `src/kernel/core/fs/tmpfs/create.pdx:114`; `.../lookup.pdx:92`    |
| `add rax, 1`                     | `src/kernel/core/fs/tmpfs/create.pdx:113`; ubiquitous             |
| `add rdi, 1`                     | Same encoding family (imm8-form ADD r64,imm8 = `48 83 C7 01`) — used across kernel for cursor advances. If specifically `add rdi, 1` has not landed, the sibling `add r8, 1` / `add r9, 1` / `add rax, 1` share encoding modulo ModRM byte, all live. |
| `add rsi, 1`                     | Same as above; `add r9, 1` at `.../tmpfs/create.pdx:112`.         |
| `sub rdx, 1`                     | `src/kernel/core/fs/tmpfs/write.pdx:84`                           |
| `sub rcx, r8` (reg reg)          | `src/kernel/core/mm/kpti.pdx:184, 193`; `.../aspace_map.pdx:183`; `.../elf_lite.pdx:406` |
| `mov rax, rcx` (reg reg)         | `src/kernel/core/fs/path.pdx:200` (`mov rax, rbx`); ubiquitous    |
| `ret`                            | Every function.                                                    |

**Local labels inside a single `unsafe { block: {…} }` block** are
proven by `src/kernel/core/fs/tmpfs/lookup.pdx:59-116`, which uses
five local labels (`tmpfs_lookup_loop`, `tmpfs_lookup_cmp`,
`tmpfs_lookup_advance`, `tmpfs_lookup_hit`, `tmpfs_lookup_miss`,
`tmpfs_lookup_done`) inside one function body. Naming discipline:
this issue prefixes every label with the function name
(`strlen_loop`, `strlen_done`, `memcmp_loop`, `memcmp_diff`,
`memcmp_done`) to prevent link-time symbol collision with #612's
future `memcpy_loop` / `memset_loop`.

### 2.3 What is *not* in place (design decisions embedded in this doc)

#### 2.3.1 File topology: one `string.pdx` or split `mem.pdx`?

The tactical plan §Subsystem 16 line 1653 lists both string
(`strlen`, `strcmp`, `strncmp`) and mem (`memset`, `memcpy`)
primitives in one module `src/user/string.pdx`. **This issue lands
strlen + memcmp in that single file**; #612 will co-locate
memcpy/memset there.

**Alternative rejected** — split into `src/user/string.pdx` (strlen,
strcmp, strncmp) and `src/user/mem.pdx` (memset, memcpy, memcmp).
Cleaner name-space, but at ≤5 functions the whole libc-lite fits on
one screen and the split is premature. #612's coordination is
easier when both issues touch the same file (each issue owns
disjoint `pub let` blocks; no merge conflict risk).

**Decision.** One file: `src/user/string.pdx`. #612 appends to it.

#### 2.3.2 `strlen` — return via counter vs. pointer-subtraction?

Two idioms exist:

- **Counter idiom** — maintain a separate `rax = count` register,
  increment each byte, return `rax`. Uses two registers total
  (cursor + counter) or one register if cursor==counter with base
  offset (`[rdi + rax]` indexed addressing).
- **Pointer-subtraction idiom** — advance `rdi` byte-by-byte until
  NUL, then compute `rax = rdi - rdi_original`. Uses two registers
  total (start-pointer saved + cursor).

**Decision — counter idiom, distinct cursor register.** The
`[rdi + rax]` indexed-addressing form is **not** used anywhere in
the kernel today; every byte-load in the kernel uses the simpler
`[reg]` or `[reg + disp]` forms (see `src/kernel/core/fs/path.pdx:237`,
`.../tmpfs/create.pdx:109`, `.../tmpfs/lookup.pdx:75-76`). Rather than
be the first user of an unaudited addressing form, we take the
distinct-cursor path: clobber `rdi` (caller-saved per SysV — the
caller must not expect its `s` argument preserved across the call,
per the exact same convention that lets `syscall_shim.pdx` clobber
`rax/rcx/r11`) and keep a separate counter in `rax`. Loop body is
6 instructions.

Pointer-subtraction is rejected because it requires stashing the
original `rdi` (either onto the stack — 3-byte push + 3-byte pop
prologue/epilogue, or into a callee-saved register — 3-byte push/pop
of `rbx`). Both add bytes without buying anything: the counter form
already returns the count directly.

#### 2.3.3 `memcmp` — return type u64 or i64?

POSIX `memcmp` returns `int` where the sign carries information. In
this codebase every `pub let` returns `u64` (the paideia-as
convention — see every `syscall_shim.pdx` wrapper). The physical
return value is 64 bits in `rax`, and the caller's interpretation is
signed vs. unsigned. **Convention: `memcmp` returns `u64`; callers
that care about sign do `mov rax, rax; sar rax, 63` (or equivalent)
if they need the sign as a boolean.** In practice, R17.M3 shell only
calls memcmp for equality (`memcmp(cmd, "help", 4) == 0`) — sign
doesn't matter. If a future caller needs the signed diff, it is
computed correctly (single-byte diff always fits in 9 bits including
sign; sign-extended in `sub rcx, r8` at §3.3).

**Decision — return `u64`.** Match the codebase convention. Document
in the source comment.

#### 2.3.4 `memcmp` — return raw diff or sign-normalized `{-1, 0, +1}`?

Some implementations return only `{-1, 0, +1}`. POSIX allows both.
**Decision — return raw diff (`a[i] - b[i]`)**. Matches glibc; simpler
implementation (no additional sign-normalize branch); callers that
need the tri-state form can do `sign(rax) = (rax > 0) - (rax < 0)`
at the call site if ever needed. R17.M3 shell only uses `== 0`.

### 2.4 One paideia-as verification action before implementation

`xor r8, r8` (used in memcmp — §3.3) does not appear at HEAD in the
kernel tree. It is a 3-byte instruction: `4D 31 C0` — the REX.WB
prefix (`0x4D`) is the same one paideia-as already emits for
`xor r10, r10` (used implicitly by `mov r10, rcx` shuffle families
and `xor r10, r10` at `.../fs/vfs_close.pdx`? — grep shows only
`xor rcx, rcx`) and `mov r10, rcx` (`49 89 CA` at
`.../syscall_shim.pdx`). The XOR opcode `31 C0` for the `rax`-family
is exercised in every `xor rax, rax` / `xor rcx, rcx` at head. The
combination `4D 31 C0` is a **compositional lift** of two proven
encoder features — high probability of already working.

**Verification action for the implementer.** Before landing
`string.pdx`, spot-check with a two-line paideia-as `.pdx` fixture:

```pdx
pub let _probe_xor_r8 : () -> u64 !{} @{} =
  fn () -> unsafe {
    effects: {}, capabilities: {},
    justification: "R17-m1-002 probe: verify xor r8, r8 encoder round-trip before landing string.pdx.",
    block: { xor r8, r8; ret }
  }
```

`paideia-as build --emit elf64 probe.pdx -o probe.o` then
`objdump -d probe.o`; expect `4d 31 c0 c3` (four bytes). If the
encoder emits a different form or fails, escalate to paideia-as per
`feedback_cross_repo_escalation.md` (file issue → fix → push → bump
submodule) BEFORE landing this issue. If green, discard the probe
and proceed. Estimated escalation risk: <5% — the encoder family is
fully exercised.

**Alternative to `xor r8, r8`.** If the probe fails and paideia-as
escalation would delay the milestone, substitute
`mov r8, 0` (7 bytes: `49 C7 C0 00 00 00 00`) — mirrors the
`mov rax, imm32` form ubiquitous in the shim. Adds 4 bytes to the
memcmp loop; still correct.

## 3. Design

### 3.1 `strlen(s: u64) -> u64`

**SysV entry**: `rdi = s` (pointer to NUL-terminated bytes).
**Return**: `rax = count of non-NUL bytes` (0 if `*s == 0`).
**Clobbers**: `rdi` (caller-saved), `rcx` (caller-saved).
**Reads**: bytes at `[s, s + strlen(s)]` inclusive of the terminator.
**Preserves**: `rsi`, `rdx`, `r8..r15`, `rbx`, `rbp`, `rsp`.

```pdx
// strlen(s) → count of bytes at s before the first NUL.
// s in rdi; result in rax.
// Loop invariant: rdi points at the next byte to inspect;
//                 rax counts inspected non-NUL bytes.
pub let strlen : (u64) -> u64 !{mem} @{} =
  fn (s: u64) -> unsafe {
    effects: {mem}, capabilities: {},
    justification: "R17-m1-002 (#611) §3.1: byte-loop strlen. Load [rdi], test for NUL, inc counter, inc pointer, loop. rdi clobbered per SysV caller-save convention. No callee-save prologue (leaf; touches only rax, rcx, rdi). Encoder inventory: xor/mov_b/cmp/je/add/jmp/ret — all live in kernel byte-loop precedents (path.pdx, tmpfs/lookup.pdx, tmpfs/create.pdx).",
    block: {
      xor rax, rax;                    // rax = counter = 0

    strlen_loop:
      xor rcx, rcx;                    // clear rcx before narrow load
      mov_b rcx, [rdi];                // rcx = *(u8*)s (zero-extended low byte)
      cmp rcx, 0;                      // NUL?
      je strlen_done;                  // yes → return counter
      add rax, 1;                      // no → count this byte
      add rdi, 1;                      // advance cursor
      jmp strlen_loop;

    strlen_done:
      ret
    }
  }
```

**Byte size** (paideia-as emit expected):

| Instruction              | Encoding       | Bytes |
|--------------------------|----------------|-------|
| `xor rax, rax`           | `48 31 C0`     | 3     |
| `xor rcx, rcx`           | `48 31 C9`     | 3     |
| `mov_b rcx, [rdi]`       | `48 0F B6 0F`* | 4     |
| `cmp rcx, 0`             | `48 83 F9 00`  | 4     |
| `je strlen_done`         | `74 <rel8>`    | 2     |
| `add rax, 1`             | `48 83 C0 01`  | 4     |
| `add rdi, 1`             | `48 83 C7 01`  | 4     |
| `jmp strlen_loop`        | `EB <rel8>`    | 2     |
| `ret`                    | `C3`           | 1     |
| **Function total**       |                | **27**|

*`mov_b` in paideia-as is `movzx r64, byte ptr [r64]` — the
`48 0F B6 XX` form. Confirmed by inspecting the assembled bytes of
`src/kernel/core/fs/path.pdx:237` after `build.sh` runs (if the
implementer wants to double-check, `objdump -d build/kernel/…/path.o`
displays the exact bytes; the canary in §4.1 doesn't depend on the
specific form as long as the emit is deterministic).

### 3.2 `memcmp(a: u64, b: u64, n: u64) -> u64`

**SysV entry**: `rdi = a`, `rsi = b`, `rdx = n`.
**Return**: `rax = 0` if `a[0..n] == b[0..n]`, else
`(u64)(a[i] - b[i])` where `i` is the first mismatch index (sign of
the diff is preserved via two's-complement modular arithmetic).
**Clobbers**: `rdi`, `rsi`, `rdx` (caller-saved), `rcx`, `r8` (caller-saved).
**Reads**: bytes at `[a, a+n)` and `[b, b+n)`.
**Preserves**: `r9..r15`, `rbx`, `rbp`, `rsp`.

```pdx
// memcmp(a, b, n) → 0 if equal else (a[i] - b[i]) at first mismatch.
// a in rdi, b in rsi, n in rdx; result in rax.
// Loop invariant: rdi/rsi point at next byte pair; rdx = remaining.
pub let memcmp : (u64, u64, u64) -> u64 !{mem} @{} =
  fn (a: u64) (b: u64) (n: u64) -> unsafe {
    effects: {mem}, capabilities: {},
    justification: "R17-m1-002 (#611) §3.2: byte-loop memcmp. For i in 0..n: load a[i], b[i]; on mismatch return (a[i]-b[i]) via signed subtract; on n exhaustion return 0. rdi/rsi/rdx clobbered per SysV. Preserves r9..r15, rbx, rbp. Encoder: xor/mov_b/cmp/jne/je/add/sub/jmp/mov/ret — all live in kernel byte-loop precedents. Note xor r8,r8 — see §2.4 probe.",
    block: {
      xor rax, rax;                    // rax = result = 0 (empty range == equal)

    memcmp_loop:
      cmp rdx, 0;                      // n == 0?
      je memcmp_done;                  // yes → return 0

      xor rcx, rcx;                    // clear before narrow loads
      xor r8, r8;
      mov_b rcx, [rdi];                // rcx = a[i] (zero-extended)
      mov_b r8,  [rsi];                // r8  = b[i] (zero-extended)

      cmp rcx, r8;                     // a[i] vs b[i]
      jne memcmp_diff;                 // mismatch → return diff

      add rdi, 1;                      // advance a cursor
      add rsi, 1;                      // advance b cursor
      sub rdx, 1;                      // consume one from budget
      jmp memcmp_loop;

    memcmp_diff:
      sub rcx, r8;                     // rcx = a[i] - b[i] (signed diff, 9-bit range)
      mov rax, rcx;                    // return in rax
      ret

    memcmp_done:
      ret                              // rax = 0 (still zeroed from entry)
    }
  }
```

**Byte size** (paideia-as emit expected, per §3.1 encoding table
extended):

| Instruction              | Encoding             | Bytes |
|--------------------------|----------------------|-------|
| `xor rax, rax`           | `48 31 C0`           | 3     |
| `cmp rdx, 0`             | `48 83 FA 00`        | 4     |
| `je memcmp_done`         | `74 <rel8>`          | 2     |
| `xor rcx, rcx`           | `48 31 C9`           | 3     |
| `xor r8, r8`             | `4D 31 C0`           | 3     |
| `mov_b rcx, [rdi]`       | `48 0F B6 0F`        | 4     |
| `mov_b r8,  [rsi]`       | `4C 0F B6 06`        | 4     |
| `cmp rcx, r8`            | `4C 39 C1`           | 3     |
| `jne memcmp_diff`        | `75 <rel8>`          | 2     |
| `add rdi, 1`             | `48 83 C7 01`        | 4     |
| `add rsi, 1`             | `48 83 C6 01`        | 4     |
| `sub rdx, 1`             | `48 83 EA 01`        | 4     |
| `jmp memcmp_loop`        | `EB <rel8>`          | 2     |
| `sub rcx, r8`            | `4C 29 C1`           | 3     |
| `mov rax, rcx`           | `48 89 C8`           | 3     |
| `ret`                    | `C3`                 | 1     |
| `ret` (memcmp_done)      | `C3`                 | 1     |
| **Function total**       |                      | **50**|

**Sign preservation** — the `sub rcx, r8` computes `a[i] - b[i]` in
9-bit two's-complement space (bytes are 0..255; diff is -255..+255).
Because `rcx` was zero-extended from a byte on entry, and `r8`
likewise, the subtraction yields a value in `[-255, +255]`
represented as a 64-bit two's-complement integer. Storing that in
`rax` gives the caller a signed `i64` result the caller can
interpret. The `u64` return type at the paideia-as boundary is a
representation, not a semantic constraint — bit patterns are
identical between i64 and u64.

### 3.3 Module structure

```pdx
// src/user/string.pdx — R17-m1-002 (#611) + #612 (memcpy/memset appends here)
// User-space libc-lite string primitives. Byte-loop implementations; no rep prefix
// at R17.M1 (#612 may add rep-prefix variants if paideia-as gains the encoding).
// See design/kernel/r17-m1-002-user-string.md for design, canary, and rationale.

module UserString = structure {

  // ==========================================================================
  // §3.1 — strlen: NUL-terminated byte count
  // ==========================================================================

  pub let strlen : (u64) -> u64 !{mem} @{} = ...   // 27 bytes per §3.1 table

  // ==========================================================================
  // §3.2 — memcmp: bounded byte compare, first-diff return
  // ==========================================================================

  pub let memcmp : (u64, u64, u64) -> u64 !{mem} @{} = ...  // 50 bytes per §3.2 table

  // ==========================================================================
  // Reserved for #612 append: memcpy, memset (and possibly strcmp, strncmp)
  // ==========================================================================
}
```

The module name `UserString` follows the convention set by
`SyscallShim`, `Builtins`, `Io`, `Shell`. If the codebase's naming
preference is otherwise, the implementer picks per prevailing style
— this is a leaf decision.

### 3.4 Interaction with the linker script

`src/user/link.ld` (R15-M1-003) puts all `.text .text.*` into a
single `.text` output section, and all `.rodata .rodata.*` into
`.rodata`. `string.pdx` contributes only `.text` bytes (no data;
strlen/memcmp are pure functions on pointer arguments). No linker
script edit required.

The `KEEP(*(.text._start))` line in link.ld pins the shell's `_start`
symbol at the entry of `.text`. Because paideia-as emits every `pub let`
into its own `.text.<name>` section (per the R13 baseline convention),
`strlen` and `memcmp` land in `.text.strlen` and `.text.memcmp`
respectively, which fall under the `*(.text .text.*)` wildcard, after
`_start`. Their absolute addresses in `shell.elf` are stable modulo
addition of new user-space symbols before them alphabetically. The
canary (§4) does not depend on absolute address — it looks up
symbols by name.

### 3.5 Effect signatures

- **`strlen`** — `!{mem} @{}`. Reads memory at `[s, s + N)`. No
  capability required (user-space call; kernel isn't involved). If
  R17's effect system distinguishes user-mem reads from
  kernel-mem reads, this is `!{u_mem}` (or whatever the convention
  is); at the current effect vocabulary in `syscall_shim.pdx`, `mem`
  is the umbrella label.
- **`memcmp`** — `!{mem} @{}`. Same rationale (reads `[a,a+n)` and
  `[b,b+n)`).

Both are effect-narrower than any syscall wrapper (no `sysreg` — no
`SYSCALL` instruction). This is the correct effect signature for a
pure-computation user-space helper.

## 4. Test canary — build-time symbol + shape verifier

The AC's phrasing ("fixture calls strlen('hello') returns 5") does
not literally require boot-time execution — it requires that a fixture
exists that would produce 5 when executed. The R17.M1 milestone has
no ring-3 execution surface yet (`shell.bin` is embedded in
`.rodata.userbin` via `tools/userbin_embed.S` but never JMP'd to at
boot — that requires the R17.M2 init loader in #616+). The correct
runtime venue is #615 `libc_test.pdx`, which extends `shell.pdx` (or
adds a separate binary) to call every libc-lite primitive with known
inputs and print `LIBC TEST OK`.

For **this** issue, the canary is:

1. **Symbol existence** — `strlen` and `memcmp` appear as global
   symbols in `build/user/shell.elf`.
2. **Function size sanity** — each function's bytes fall within a
   documented budget (strlen: 20–40 bytes; memcmp: 40–70 bytes). A
   wildly out-of-budget size means the encoder deviated from expected
   emission or the source drifted.
3. **Opcode signature** — each function contains at least one
   `movzx` (opcode byte `0F B6`), at least one conditional branch
   (`74` = `je` short, `75` = `jne` short), and at least one
   unconditional branch (`EB` = `jmp` short) and a `ret` (`C3`).
   These four opcode families are the fingerprint of a byte-loop —
   their absence indicates the emit is no longer a byte-loop.
4. **NO `syscall` opcode** (`0F 05`) — strlen and memcmp must not
   call the kernel. A `0F 05` byte in either function's range
   indicates a design regression.

### 4.1 `tools/verify-user-string.sh` (new)

```bash
#!/usr/bin/env bash
# Build-time shape canary for src/user/string.pdx (R17-M1-002 / #611).
# Verifies strlen and memcmp exist, sit within size budgets, contain
# byte-loop opcode signatures, and do NOT contain the syscall opcode.
# Exits with "R17 USER STRING OK" or "R17 USER STRING FAIL".
set -euo pipefail

ELF="${1:-build/user/shell.elf}"

if [[ ! -f "$ELF" ]]; then
    echo "R17 USER STRING FAIL" >&2
    echo "ELF file not found: $ELF" >&2
    exit 1
fi

FAIL=0

# Verify a function: name, min_bytes, max_bytes.
verify_fn() {
    local name="$1" lo="$2" hi="$3"

    # Extract the function's disassembly (bytes column only).
    local dump
    dump=$(objdump -d -M intel "$ELF" 2>/dev/null | awk -v sym="$name" '
        BEGIN { seen = 0; buf = "" }
        $0 ~ "<"sym">:"       { seen = 1; next }
        seen && $0 ~ /^[0-9a-f]+ </ { exit }         # next symbol
        seen && $0 ~ /^[[:space:]]+[0-9a-f]+:/ {
            # Line: "  400071:\t48 c7 c0 00 00 00 00\tmov rax,0x0"
            after_colon = substr($0, index($0, ":") + 1)
            n = split(after_colon, parts, "\t")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[1])
            buf = buf " " parts[1]
        }
        END { print buf }
    ' | tr -s ' ' | sed 's/^ //;s/ $//')

    if [[ -z "$dump" ]]; then
        echo "[FAIL] $name: symbol not found in ELF"
        FAIL=1
        return
    fi

    # Count bytes (each byte is 2 hex chars + separator).
    local nbytes
    nbytes=$(echo "$dump" | tr ' ' '\n' | grep -c '^[0-9a-f][0-9a-f]$' || true)

    if (( nbytes < lo || nbytes > hi )); then
        echo "[FAIL] $name: $nbytes bytes outside budget [$lo, $hi]"
        FAIL=1
        return
    fi

    # Signature: must contain movzx (0f b6), a conditional branch (74 or 75),
    # an unconditional short jmp (eb), a ret (c3), and NO syscall (0f 05).
    if ! echo "$dump" | grep -q '0f b6'; then
        echo "[FAIL] $name: missing movzx (byte-load) opcode 0f b6"
        FAIL=1
    fi
    if ! echo "$dump" | grep -qE '(74|75) '; then
        echo "[FAIL] $name: missing conditional short branch (74/75)"
        FAIL=1
    fi
    if ! echo "$dump" | grep -q 'eb '; then
        echo "[FAIL] $name: missing unconditional short jmp (eb)"
        FAIL=1
    fi
    if ! echo "$dump" | grep -q 'c3'; then
        echo "[FAIL] $name: missing ret (c3)"
        FAIL=1
    fi
    if echo "$dump" | grep -q '0f 05'; then
        echo "[FAIL] $name: contains syscall opcode 0f 05 — must be pure userland"
        FAIL=1
    fi

    if (( FAIL == 0 )); then
        echo "[ok]   $name: $nbytes bytes; signature OK"
    fi
}

verify_fn strlen 20 40
verify_fn memcmp 40 70

if (( FAIL == 0 )); then
    echo "R17 USER STRING OK"
    exit 0
else
    echo "R17 USER STRING FAIL"
    exit 1
fi
```

### 4.2 `tools/build-user.sh` — append verifier invocation

Two-line append after the existing `verify-syscall-shim.sh` line
(line 44 at HEAD):

```bash
echo "[verify-user] byte-shape canary on strlen/memcmp in shell.elf"
"${REPO_ROOT}/tools/verify-user-string.sh" "${BUILD_DIR}/shell.elf"
```

Ordering: after the syscall-shim verifier, before the final `[ok]`
lines. This way both canaries run and both must pass; a failure of
either fails `build-user.sh` with a non-zero exit, which the
`tools/build.sh` orchestrator (and the pre-push hook, per
`feedback_paideia_os_no_cicd.md`) picks up locally.

### 4.3 Why no kernel-side runtime witness at R17.M1

Three reasons, mirroring #610 §4.3:

1. **No ring-3 execution surface yet.** `shell.bin` is embedded in
   `.rodata.userbin` but the kernel never JMP's into it at boot;
   that lands with the R17.M2 init loader (#616+). A kernel-side
   witness that calls user-space `strlen` from ring-0 would either
   (a) require duplicating the strlen bytes into a kernel `.text`
   section — defeating the point of testing the user version, or
   (b) build a fake user-context to jump into — duplicating the
   R15.M2 ring3_hello plumbing without adding coverage.

2. **Runtime venue is #615.** `libc_test.pdx` is scoped for exactly
   this — a ring-3 binary that calls every libc-lite function with
   known inputs, prints `LIBC TEST OK`, and exits. It lives after
   #615 lands the ring-3 loader wiring. That is the correct altitude.

3. **The AC does not require boot execution.** "Fixture calls
   strlen('hello') returns 5" is satisfiable by
   `libc_test.pdx` at #615 time. This issue's job is landing the
   implementation with a shape guarantee.

### 4.4 Optional: pre-stage the fixture inside shell.pdx (deferred to #615)

If the implementer wants to pre-stage the fixture for #615 to
extend, they *could* add a trivial call site inside `shell.pdx`'s
`_start`:

```asm
// Fixture placeholder for R17-M1-002 (#611) → exercised at R17.M1 close by #615.
lea rdi, [rip + hello_msg];      // "hello\0"
call strlen;                     // rax = 5
// (result discarded; #615 will inspect it via sys_debug_puts or an exit code)
```

**Not recommended for this issue.** The `_start` today drops through
to `builtin_exit`, which never returns. Adding an intermediate
`call strlen` between `dispatch_cap` and `builtin_exit` is a valid
one-line addition, but it (a) puts a call to a not-yet-runtime-tested
function in the boot path (dead code, but still noise); (b) is
scope-creep past the issue's declared `Touching: src/user/string.pdx`
line; (c) is trivially added by #615 when the ring-3 loader is
ready. Deferred as a #615 concern.

## 5. Backtrack candidates

Ordered by preference.

### 5.1 Backtrack A — Merge with #612; land all 4-5 primitives in one PR

Land `strlen`, `memcmp`, `memcpy`, `memset` (and possibly `strcmp`,
`strncmp`) in one commit against `src/user/string.pdx`. Close #611
and #612 together.

Consequence: reduces churn (one file, one PR, one canary invocation
addition); ships the full libc-lite string surface in one motion.
Loses the parallel-tempo advantage — #612 lists no shim dep so it
can proceed in parallel today.

**Consider as first backtrack** if #612 has already been architected
by the time this doc is reviewed and both agents can coordinate on
one file. Otherwise the split is fine — the file structure §3.3
reserves space for #612's additions.

### 5.2 Backtrack B — Use `[rdi + rax]` indexed addressing in strlen

Emit `mov_b rcx, [rdi + rax]` instead of clobbering `rdi`. Saves
one `add rdi, 1` per iteration; single-cursor scheme.

Consequence: first user of this addressing form in the tree. Requires
a paideia-as probe similar to §2.4. Non-blocking risk but adds an
encoder-surface bet on top of what's already needed. Buys 4 bytes
per strlen function (net; save `add rdi, 1` but pay slightly more
for the indexed ModRM).

**Reject as primary.** The current design uses only fully-audited
addressing forms; the byte savings are negligible at R17.M1's
altitude.

### 5.3 Backtrack C — Prefer callee-saved registers for cursors

Push `rbx, r12, r13` at entry, use them as cursors, pop at exit.
Preserves `rdi/rsi/rdx` (SysV callee-save is `rbx, rbp, r12-r15`).

Consequence: caller-side call sites don't need to reload their
`rdi/rsi/rdx` after the call. Adds 3 push + 3 pop = 6 bytes of
prologue/epilogue per function. Buys back some CPU cycles on the
caller side.

**Reject.** SysV calling convention explicitly declares
`rdi, rsi, rdx, rcx, r8, r9` as *argument registers* which are
*caller-saved*. Every caller of a SysV C function already treats
them as clobbered. Adding push/pop discipline is redundant and
grows code size for no correctness benefit. The `syscall_shim.pdx`
wrappers clobber `rcx, r11` freely for the same reason.

### 5.4 Backtrack D — Emit kernel-side witness by linking user object into kernel

Bring `build/user/string.o` into the kernel link (via
`tools/build.sh` orchestration), have `kernel_main.pdx` witness call
`strlen("hello")` from ring-0 with a stack pointer, assert `rax == 5`,
print `R17 STRLEN OK` marker.

Consequence: real runtime AC at R17.M1 close. Cost: kernel `.text`
grows by 77 bytes (27 strlen + 50 memcmp) permanently even after
ring-3 is fully wired; symbol namespace bleeds user↔kernel;
`build.sh` grows an extra link input; smoke fingerprints for every
`boot_r8_only..boot_r12_denial` change because a new marker prints.

**Reject.** The whole point of having a separate `build-user.sh`
and userland ELF is to keep user-space and kernel-space link graphs
disjoint. Bleeding user code into the kernel to test it defeats the
architecture. #615 is the correct venue.

### 5.5 Backtrack E — Skip the shape canary; rely on paideia-as compile success only

Ship `string.pdx` and rely on the fact that `build-user.sh` exits
zero as sufficient AC. No new verifier script.

Consequence: fastest to land (-90 LOC of shell script). No
guarantee that the assembler didn't emit something structurally
different (e.g., a straight-line `xor rax, rax; ret` if the source
had a typo that produced an empty function body — paideia-as would
happily emit that).

**Reject.** #610 established the canary discipline. Departing from
it for #611 would set a soft precedent to also skip it for #612,
#613, #614 — eroding the pattern. The 90-LOC canary is proportionate
insurance against silent encoder drift and source typos.

## 6. LOC estimate

| File                                                          | LOC delta |
|---------------------------------------------------------------|-----------|
| `src/user/string.pdx` (new)                                   | +90       |
| `tools/verify-user-string.sh` (new)                           | +90       |
| `tools/build-user.sh` (append verifier invocation)            | +3        |
| `design/kernel/r17-m1-002-user-string.md` (this doc)          | +550      |
| **Total**                                                     | **~733**  |

Executable / build code: ~183 LOC (90 pdx + 90 shell + 3 build).
Design + prose: ~550 LOC. The 90-LOC pdx figure assumes:
- `strlen`: ~30 LOC (11 lines of block body + 8 lines of
  `pub let/fn/unsafe/justification/effects/capabilities/block: {`
  scaffolding + 10 lines of comment + blank lines).
- `memcmp`: ~40 LOC (17 lines of block body + 8 lines of scaffolding
  + 10 lines of comment + blank lines).
- Module header, banner comments, reserved-for-#612 comment: ~20 LOC.

## 7. Tractability

**HIGH.**

- **Zero paideia-as encoder gap expected.** Every mnemonic used
  has 2+ live-tree callers (§2.2). The single uncertain compositional
  emit (`xor r8, r8` = `4D 31 C0`) is a two-line probe (§2.4) whose
  failure has a documented workaround (`mov r8, 0`; +4 bytes,
  functionally identical).
- **Zero kernel-side change.** `string.pdx` lives entirely under
  `src/user/`; the kernel's link graph is untouched. `build.sh` is
  unaware.
- **Zero smoke-fingerprint drift.** No boot marker is emitted. The
  canary's `R17 USER STRING OK` line goes to `build-user.sh`'s
  stdout only. Every `boot_r8_only`..`boot_r12_denial` mode stays
  byte-identically green.
- **Zero cross-repo escalation expected.** Modulo the §2.4 probe
  outcome, no paideia-as feature is missing.
- **~180 LOC executable across one new `.pdx` + one new shell script
  + a 3-line append.** Fits the milestone tempo of the other R17.M1
  issues (#610 landed with a similar shape: 240 exec LOC + 410
  design LOC).
- **Byte budget honored.** Each function's expected byte size
  (27 for strlen, 50 for memcmp) sits comfortably inside the
  canary's budget windows (20-40 and 40-70), leaving room for
  paideia-as to select a different encoding for any individual
  instruction (e.g., `cmp reg, 0` might collapse to `test reg, reg`
  = 3 bytes instead of 4) without failing the canary.
- **AC is directly testable.** The build-time canary reads
  `[ok]   strlen: 27 bytes; signature OK` /
  `[ok]   memcmp: 50 bytes; signature OK` /
  `R17 USER STRING OK` — three exit-visible lines that pin the
  landing.

Known follow-ups (not blockers for #611):

- **#612 (`r17-m1-003-user-memcpy-memset`)** — parallelizable;
  appends `memcpy`/`memset` (and possibly `strcmp`/`strncmp`) to the
  same `string.pdx` file. The canary in §4.1 can be extended
  trivially to verify each new function.
- **#614 (`r17-m1-005-user-puts-getline`)** — `puts_c(str)` will
  call `strlen(str)` to derive length for `sys_write(1, str, len)`.
  This module's strlen is #614's dependency.
- **#615 (`r17-m1-006-user-smoke-libc`)** — runtime witness that
  actually executes `strlen("hello")` inside a ring-3 fixture and
  emits `LIBC TEST OK` to boot fingerprint. This issue's
  compile-time canary + #615's runtime witness together give the
  strong AC.
- **R17.M3 shell (#622+)** — dispatches builtin names via `memcmp`;
  computes argv string lengths via `strlen`.

## 8. Cross-cutting risks

- **paideia-as `xor r8, r8` emission uncertainty.** Mitigated by
  §2.4's two-line probe. Fallback: `mov r8, 0`. Not a blocking risk.
- **paideia-as `mov_b r64, [r64]` emission for r8/r9.** The
  extension-register form uses REX.WR (`0x4C`) prefix. This is
  the same prefix family already exercised for `mov_b r8`/`r9`
  stores in `.../tmpfs/init.pdx:53-100`, so the load form should
  round-trip. If it doesn't, escalate to paideia-as with a probe.
- **Short-branch reach.** All conditional/unconditional branches
  in strlen (max 15-byte reach) and memcmp (max 30-byte reach)
  are safely within `rel8` range (-128..+127). paideia-as should
  select the 2-byte short form; if it selects the 6-byte
  `0F 8x rel32` form, the canary's byte budget still accommodates
  it (function grows by ~24 bytes at most — fits 40/70 budgets).
- **Symbol-name collision with a future kernel-side `strlen`.**
  The kernel does not currently expose a `strlen` symbol; the
  closest analog is inline strncmp inside `tmpfs_lookup`. If a
  future kernel-side `strlen` lands, its symbol lives in
  `kernel.elf` and this issue's lives in `shell.elf` — two separate
  ELFs. No collision. If either kernel or user ever adopts symbol
  visibility scoping (STB_LOCAL for internal helpers), this
  becomes even more explicit.
- **Canary false positive from binutils version drift.** If
  `objdump`'s output columns shift, the awk parser in §4.1 may
  fail to extract bytes. Mitigation: canary MUST exit non-zero if
  it extracts zero bytes for a symbol it looked up (`nbytes < 1`
  check is subsumed by `nbytes < 20` for strlen).
- **`memcmp` sign-return convention drift.** If a future caller
  interprets `memcmp` return as strictly `{-1, 0, +1}` (per POSIX
  literal reading), the raw-diff form breaks that assumption.
  Mitigation: the source comment declares raw-diff; document also
  in `design/user/` (future issue) when a caller needs
  sign-normalized form.

## 9. References

- Issue: paideia-os#611
- Milestone: paideia-os milestones/69 (R17.M1 libc-lite for userland)
- Sibling issues (R17.M1): #610 syscall shim (landed HEAD 0d47d17),
  #612 memcpy/memset, #613 errno slot, #614 puts/getline, #615
  libc smoke
- Tactical plan: `design/milestones/r14b-tactical-plan.md`
  §Subsystem 16 (lines 1635–1710) — primary interfaces of libc-lite
- Master plan: `design/milestones/r14b-master-plan.md` §R17 (libc)
- Predecessor design doc: `design/kernel/r17-m1-001-syscall-shim.md`
  — the canary and no-runtime-witness-yet discipline this doc
  mirrors
- Kernel byte-loop precedents:
  - `src/kernel/core/fs/tmpfs/lookup.pdx:67-92` — inline strncmp
    (structural analog for memcmp)
  - `src/kernel/core/fs/tmpfs/create.pdx:99-118` — inline bounded
    byte copy (structural analog for strlen's cursor advance)
  - `src/kernel/core/fs/path.pdx:229-257` — xor+mov_b+cmp+branch
    idiom (the innermost pattern this issue's loops replicate)
- User-space link map: `src/user/link.ld` (R15-M1-003) — no edit
  required
- Build orchestrator: `tools/build-user.sh` — extended by +3 lines
- Prior canary: `tools/verify-syscall-shim.sh` (R17-M1-001) —
  the byte-shape-canary pattern this issue reuses
