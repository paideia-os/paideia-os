---
issue: 612
milestone: R17.M1 (libc-lite for userland)
subsystem: 16 — libc-lite for userland
prereq:
  - "None (parallelizable with #610 syscall_shim and #611 strlen/memcmp). Pure user-space bytes; no syscall, no shim dependency."
  - "src/user/string.pdx exists from #611 landing (HEAD f933889); this issue appends two `pub let` blocks to the reserved region marked at that file's line 78."
  - "tools/build-user.sh already invokes tools/verify-user-string.sh (line 47 at HEAD, appended by #611)."
  - "paideia-as 0.20.0 provides `rep_movsb` (F3 A4), `rep_stosb` (F3 AA), and `cld` (FC) — all encoder-audited and (for rep_movsb / cld) live in kernel at HEAD."
blocks:
  - "#613 (r17-m1-004-user-errno) — parallelizable; different module (src/user/errno.pdx). No dep."
  - "#614 (r17-m1-005-user-puts-getline) — puts_c uses strlen (from #611) + sys_write (from #610); does not call memcpy/memset directly at MVP. Indirect dep only if #614's getline copies into a caller buffer via memcpy — see §5.3."
  - "#615 (r17-m1-006-user-smoke-libc) — libc_test binary exercises memcpy round-trip (u8[8] src → dst; then memcmp(src,dst,8)==0) and memset (dst[0..8]='A'; then memcmp(dst,\"AAAAAAAA\",8)==0). Owns the runtime AC (`LIBC TEST OK` boot marker) after ring-3 loader lands (#616+)."
  - "R17.M3 shell (#622+) — parse loop uses memcpy to copy argv strings into stack buffers; memset to clear line buffers between prompts."
touching:
  - src/user/string.pdx                              (append: memcpy + memset; ~70 LOC)
  - tools/verify-user-string.sh                     (extend: two new verify_fn calls with rep-signature check; ~40 LOC)
  - design/kernel/r17-m1-003-user-mem.md            (this doc)
related:
  - "#611 (r17-m1-002-user-string) — landed HEAD f933889; established the file layout (module UserString), the pub-let scaffolding, the byte-shape-canary discipline this issue extends. Design doc: design/kernel/r17-m1-002-user-string.md."
  - "#610 (r17-m1-001-syscall-shim) — landed HEAD 0d47d17; the byte-pattern-canary precedent (verify-syscall-shim.sh)."
  - "#615 (r17-m1-006-user-smoke-libc) — runtime witness venue for the AC 'memcpy round-trip byte-identical'."
  - "design/milestones/r14b-tactical-plan.md §Subsystem 16 line 1663 — 'memset, memcpy — byte-loop (rep movsb once encoder confirmed)'. Encoder is confirmed at paideia-as 0.20.0; this issue lands the rep-prefix form."
  - "paideia-as CHANGELOG PA-R13-008 (#937) — `cld` / `std` (FC/FD) landed. Live in kernel tmpfs/read.pdx:119, tmpfs/write.pdx:118."
  - "paideia-as CHANGELOG PA-R13-011 (#940) — `rep_movsb` (F3 A4) audit-only; encoder was already correct. Live in kernel tmpfs/read.pdx:120, tmpfs/write.pdx:119."
  - "paideia-as CHANGELOG PA-R13-012 (#941) — `rep_stosq` audit. #1228 (Phase 2 of #1064) — BulkMemOps stdlib lowering that formalized `rep_stosb` (F3 AA). Encoder tested at paideia-as/tests/build-emit/rep_stosb_smoke.pdx. NOT yet live in paideia-os kernel — this issue is the first in-tree caller (see §2.4)."
  - "src/kernel/core/fs/tmpfs/read.pdx:109-120 — the canonical rep_movsb call site (rsi=src, rdi=dst, rcx=count, cld, rep_movsb) this issue mirrors."
  - "src/kernel/core/fs/tmpfs/write.pdx:108-119 — the sibling rep_movsb write path."
  - "src/kernel/core/fs/tmpfs/inode.pdx:117-131 — the canonical rep_stosq zero-slot pattern; structural analog for memset (differs only by width: rep_stosb 8-bit vs rep_stosq 64-bit)."
---

# R17-M1-003 — user memcpy + memset — `rep_movsb` / `rep_stosb` primitives in `src/user/string.pdx` (#612)

## 1. Scope

Append two user-space `libc-lite` memory primitives to `src/user/string.pdx`
(reserved region at line 78 of the file at HEAD f933889):

- **`memcpy(dst: u64, src: u64, n: u64) -> u64`** — copy `n` bytes from
  `src` to `dst`. Return `dst` (matching POSIX `memcpy(3)` return
  convention). Undefined for overlapping regions where `dst > src` (POSIX
  `memcpy` behavior; `memmove` is deferred — see §Out-of-scope).
- **`memset(dst: u64, val: u64, n: u64) -> u64`** — fill `n` bytes at
  `dst` with the low 8 bits of `val`. Return `dst`.

Both use the **`rep`-prefix string primitives** (`rep_movsb` for copy;
`rep_stosb` for fill) with a preceding `cld` to force forward direction.
Encoder support is proven at paideia-as 0.20.0 (see §2.2). A byte-loop
fallback is documented in §5.1 (Backtrack A) if a runtime issue emerges,
but is **not** landed at this issue.

Out of scope (deliberately deferred):

- **`memmove`** (overlap-safe copy). Not in R17.M1 primary interfaces per
  tactical plan §Subsystem 16 line 1663. Deferred to a post-R17 issue if
  an overlapping-copy caller emerges. R17.M3 shell has no such caller.
- **`memcmp`.** Landed at #611 (`src/user/string.pdx:44` — `memcmp` byte-loop).
- **`bzero` / `explicit_bzero`.** Not in the tactical plan's libc-lite
  surface. Callers write `memset(p, 0, n)`.
- **Alignment optimizations** (`rep movsq` for the 8-byte aligned middle,
  `rep movsb` for the head/tail). Modern x86_64 microcode ("ERMS" — Enhanced
  REP MOVSB) makes `rep movsb` competitive for all sizes ≥ ~128 bytes and
  optimal for small sizes. Tiered dispatch (movsb + movsq + AVX) is a
  post-R17 optimization if a real profile shows a hot memcpy path — R17.M1
  chooses the simplest correct primitive.
- **`_user_errno` interaction.** Neither `memcpy` nor `memset` can fail in
  POSIX semantics — no errno path. #613 does not touch this module.
- **Runtime AC exercise.** The AC "memcpy round-trip byte-identical" is
  satisfied at R17.M1 by a **build-time byte-shape canary** (§4) plus a
  compiled fixture that #615 (`libc_test.pdx`) will exercise once the
  ring-3 loader lands. See §4.3 for why a kernel-side runtime witness is
  rejected (mirrors #611 §4.3 exactly).
- **`R17 MEMCPY OK` boot marker.** Not emitted from `kernel_main.pdx`.
  Verifier script (§4.1) emits `R17 USER MEM OK` to stdout of
  `build-user.sh` only. Every smoke fingerprint (`boot_r8_only`,
  `boot_r10`, `boot_r11`, `boot_r12`, `boot_r12_denial`) stays
  byte-identically green through this commit.

## 2. Prereq check

### 2.1 What's in place

- **`src/user/string.pdx` exists at HEAD f933889** with `strlen` and
  `memcmp` landed by #611. Line 78 marks the reserved append point:
  `// Reserved for #612 append: memcpy, memset (and possibly strcmp, strncmp)`.
  This issue lands `memcpy` and `memset` there — `strcmp`/`strncmp` are
  deferred to a distinct issue (not in this issue's title or AC).
- **`tools/build-user.sh` already runs the shape canary** at line 47
  (`verify-user-string.sh`). This issue extends that canary (rather than
  minting a new one) — one script call, four functions verified.
- **paideia-as encoder coverage**:
  - `rep_movsb` (F3 A4) — **live at kernel HEAD** (tmpfs/read.pdx:120,
    tmpfs/write.pdx:119). Audit landed at paideia-as PA-R13-011 (#940).
  - `rep_stosb` (F3 AA) — encoder-tested at paideia-as
    `tests/build-emit/rep_stosb_smoke.pdx`, part of the BulkMemOps
    stdlib lowering (#1228, Phase 2 of #1064). **Not yet in kernel tree**;
    this user issue is the first paideia-os caller. See §2.4 for the
    verification action.
  - `cld` (FC) — landed paideia-as PA-R13-008 (#937). Live in kernel at
    tmpfs/read.pdx:119, tmpfs/write.pdx:118.
- **Register-move idioms** (`mov r8, rdi`, `mov rax, r8`, `mov rax, rsi`,
  `mov rcx, rdx`) — all live in kernel across dozens of call sites; every
  REX-prefix combination this issue uses is already exercised.
- **`ret` (C3)** — every function.

### 2.2 paideia-as encoder inventory (no gaps expected)

| Mnemonic (form used here)    | Bytes         | Live use site (kernel or paideia-as)                              |
|------------------------------|---------------|-------------------------------------------------------------------|
| `mov r8, rdi`                | `49 89 F8`    | Analogous to `mov r10, rcx` at `src/user/syscall_shim.pdx` (REX.WB family, live) |
| `mov rcx, rdx`               | `48 89 D1`    | `src/kernel/core/fs/tmpfs/read.pdx:118` (same instruction, same context) |
| `mov rsi, r8`                | `4C 89 C6`    | `src/kernel/core/fs/tmpfs/read.pdx:116` (same instruction, same context) |
| `mov rdi, rbx`               | `48 89 DF`    | `src/kernel/core/fs/tmpfs/read.pdx:117` (adjacent to rep_movsb site) |
| `mov rax, rsi`               | `48 89 F0`    | Ubiquitous mov-reg-reg family; live across shim wrappers          |
| `mov rax, r8`                | `4C 89 C0`    | REX.WR mov-reg-reg family — same encoding-class as `mov rax, r10` (live) |
| `cld`                        | `FC`          | `src/kernel/core/fs/tmpfs/read.pdx:119`, `.../write.pdx:118`      |
| `rep_movsb`                  | `F3 A4`       | `src/kernel/core/fs/tmpfs/read.pdx:120`, `.../write.pdx:119`      |
| `rep_stosb`                  | `F3 AA`       | paideia-as `tests/build-emit/rep_stosb_smoke.pdx` (encoder audit) — see §2.4 |
| `ret`                        | `C3`          | Every function.                                                    |

All four "rep-adjacent" mnemonics (`cld`, `rep_movsb`, `rep_stosb`) have
audit-only test coverage in paideia-as. The compositional risk is nearly
zero.

### 2.3 What is *not* in place (design decisions embedded in this doc)

#### 2.3.1 File topology — append to `string.pdx` (per #611 §2.3.1 decision)

#611 explicitly reserved this space (`src/user/string.pdx:78`). One file
holds all libc-lite string/mem primitives (strlen, memcmp, memcpy, memset,
and future strcmp/strncmp). No new module.

**Alternative rejected** — split into `src/user/mem.pdx`. #611 already
argued against this: at ≤5 functions the whole surface fits on one screen,
and coordination during parallel development is easier when both siblings
touch the same file (each issue owns disjoint `pub let` blocks).

#### 2.3.2 Return convention — return `dst` or return `void`?

POSIX `memcpy`/`memset` return `void *` — the destination pointer. Some
freestanding implementations return `void`. In this codebase every
`pub let` returns `u64` (paideia-as convention — see every
`syscall_shim.pdx` wrapper). We return the destination pointer for
POSIX compatibility (some future C-idiom caller may chain
`p = memcpy(dst, src, n)`).

**Decision — return `u64` (the destination pointer).** Costs one extra
`mov rax, r8` at exit (3 bytes) but preserves POSIX call-site semantics
for any future higher-level caller.

**Alternative rejected** — return the paideia-as convention `u64` = 0 for
success. Zero information; requires callers to remember `dst` themselves.
Not idiomatic.

#### 2.3.3 memset — how to move `val` into AL for `rep_stosb`?

`rep_stosb` reads AL (low 8 bits of RAX) and writes it n times to `[rdi]`.
The `val` argument arrives in `rsi` per SysV. Two forms:

- **`mov rax, rsi`** (3 bytes) — moves all 64 bits, but `rep_stosb` reads
  only AL, so the upper bytes are silently ignored. Simplest; consistent
  with how the kernel does register-to-register moves.
- **`mov al, sil`** (3-4 bytes; `mov r/m8, r8` with REX for SIL access) —
  byte-narrow move; more precise. Requires the encoder to emit an
  8-bit mov reg-to-reg form. **This form may not be encoder-live in
  paideia-as**; the tree uses `mov_b [mem], reg` (byte store) and
  `mov_b reg, [mem]` (byte load, zero-extended = movzx), but no
  register-to-register byte mov appears. Verifying would add a
  cross-repo escalation.

**Decision — `mov rax, rsi` (full 64-bit)**. Guaranteed encoder support
(mov-reg-reg family is ubiquitous); the semantic result is identical since
`rep_stosb` reads only AL. Adds no bytes vs. the byte-narrow form. No
paideia-as risk.

Precondition on caller: caller must pass `val ∈ [0, 255]`. If a caller
passes `val > 255`, only the low byte is used — this matches POSIX
semantics exactly (`int c` in POSIX `memset(void*, int c, size_t)` is
"converted to `unsigned char`"). Document in source comment.

#### 2.3.4 memcpy — preserve dst via stack push or register stash?

Two idioms to save `dst` (rdi) across the `rep_movsb` sequence (which
clobbers `rdi`, `rsi`, `rcx`):

- **Stack** — `push rdi` at entry, `pop rax` at exit. 1 byte + 1 byte = 2
  bytes. Modifies `rsp` briefly; requires care if any nested call happens
  (none here — leaf function).
- **Register** — `mov r8, rdi` at entry, `mov rax, r8` at exit. 3 + 3 = 6
  bytes. No stack traffic; SysV caller-save so `r8` is legitimately
  clobberable.

**Decision — register stash** (`mov r8, rdi` … `mov rax, r8`). Costs 4
extra bytes vs. push/pop but avoids stack alignment concerns entirely
(memcpy is a leaf so alignment doesn't matter for correctness, but keeping
`rsp` untouched simplifies mental model and matches `syscall_shim.pdx`
convention which touches no stack). Mirrors the exact pattern at
`src/kernel/core/fs/tmpfs/inode.pdx:118` (`mov r10, rdi` before
`rep_stosq`).

#### 2.3.5 memset — same question, `r8` as scratch?

`rep_stosb` clobbers `rdi` (dst pointer, incremented) and `rcx` (count,
decremented to 0). To return `dst`, save the original `rdi` before the
sequence. Choice: `r8` (as memcpy). No conflict because memset's arg-3
(count) is in `rdx` (already moved to `rcx` before the rep), and `r8` is
untouched.

**Decision — save `rdi` in `r8`; restore to `rax` on exit.** Same 6-byte
overhead. Symmetric with memcpy.

#### 2.3.6 n==0 handling

`rep_movsb` and `rep_stosb` with `rcx=0` are architectural no-ops (Intel
SDM: "If ECX is 0, no iterations occur"). Both functions correctly
handle `n=0`: the register saves and `rax = dst` restore happen; the rep
loop runs zero iterations; `ret`. No explicit branch needed.

This matches POSIX: `memcpy(dst, src, 0)` and `memset(dst, val, 0)` are
both well-defined and return `dst` unmodified.

### 2.4 One paideia-as verification action before implementation

`rep_stosb` (F3 AA) is encoder-audited in paideia-as at
`tests/build-emit/rep_stosb_smoke.pdx` but has **no live caller in the
paideia-os tree today** — the kernel uses `rep_stosq` (qword form,
`F3 48 AB`) for all zero-init patterns because they operate on 8-byte-
aligned regions (page tables, task pool slots, tmpfs inode slots).

**Verification action for the implementer.** Before landing the `.pdx`
update, spot-check with a two-line fixture:

```pdx
module RepStosbProbe = structure {
  pub let _probe : () -> () !{mem} @{} =
    fn (_: ()) -> unsafe {
      effects: {mem}, capabilities: {},
      justification: "R17-m1-003 probe: verify rep_stosb encoder round-trip before landing memset.",
      block: { cld; rep_stosb; ret }
    }
}
```

Compile with `paideia-as build --emit elf64 probe.pdx -o probe.o` and
`objdump -d probe.o`; expect `FC F3 AA C3` (four bytes). If the encoder
emits a different form or errors, escalate to paideia-as per
`feedback_cross_repo_escalation.md` — but note that paideia-as
`tests/build-emit/rep_stosb.rs` asserts exactly `F3 AA C3` for the bare
form, so failure would indicate a regression to open against paideia-as.
Estimated escalation risk: <2%.

**Backup plan if probe fails.** Use the byte-loop fallback (§5.1) —
memset becomes 6 lines of `mov_b [rdi+0], rax; add rdi, 1; sub rdx, 1;
cmp rdx, 0; jne loop; ret` (approximately 25 bytes). Correctness is
unchanged; performance drops from 1 byte/cycle (rep) to ~5 bytes/cycle
(loop). Not a milestone blocker.

## 3. Design

### 3.1 `memcpy(dst: u64, src: u64, n: u64) -> u64`

**SysV entry**: `rdi = dst`, `rsi = src`, `rdx = n`.
**Return**: `rax = dst` (unmodified pointer).
**Clobbers**: `rdi`, `rsi`, `rdx` (arg registers per SysV; caller-saved),
`rcx`, `r8` (caller-saved scratch).
**Reads**: bytes at `[src, src+n)`.
**Writes**: bytes at `[dst, dst+n)`.
**Preserves**: `rbx`, `rbp`, `r9..r15`, `rsp`.
**Behavior on overlap**: undefined if `dst > src && dst < src+n` (POSIX
`memcpy` semantics; `memmove` deferred).
**Behavior on n=0**: writes nothing; returns `dst`.

```pdx
// memcpy(dst, src, n) → dst. Copy n bytes forward from src to dst.
// dst in rdi, src in rsi, n in rdx; result in rax = dst.
// Uses rep_movsb (F3 A4) with a leading cld (FC) — matches the kernel
// idiom at src/kernel/core/fs/tmpfs/read.pdx:115-120 and write.pdx:114-119.
// Overlapping regions where dst > src are undefined (use memmove; deferred).
pub let memcpy : (u64, u64, u64) -> u64 !{mem} @{} =
  fn (dst: u64) (src: u64) (n: u64) -> unsafe {
    effects: {mem}, capabilities: {},
    justification: "R17-m1-003 (#612) §3.1: memcpy via rep_movsb. Save rdi (dst) in r8 across the string primitive so we can return it. Move n → rcx (rep count), cld to force forward direction, rep_movsb (uses rsi=src, rdi=dst, rcx=count). Restore dst from r8 into rax. r8 caller-saved per SysV. Encoder: mov reg-reg + cld + rep_movsb + ret — all live in kernel (tmpfs/read.pdx, tmpfs/write.pdx). n=0 handled implicitly (rep with rcx=0 is a no-op). Overlap undefined per POSIX memcpy.",
    block: {
      mov r8, rdi;                     // r8 = dst (save for return)
      mov rcx, rdx;                    // rcx = count (rep prefix reads rcx)
      cld;                             // DF=0 (forward copy)
      rep_movsb;                       // *rdi++ = *rsi++; rcx--; while rcx != 0
      mov rax, r8;                     // rax = dst (return value)
      ret
    }
  }
```

**Byte size** (paideia-as emit expected):

| Instruction              | Encoding       | Bytes |
|--------------------------|----------------|-------|
| `mov r8, rdi`            | `49 89 F8`     | 3     |
| `mov rcx, rdx`           | `48 89 D1`     | 3     |
| `cld`                    | `FC`           | 1     |
| `rep_movsb`              | `F3 A4`        | 2     |
| `mov rax, r8`            | `4C 89 C0`     | 3     |
| `ret`                    | `C3`           | 1     |
| **Function total**       |                | **13**|

Canary budget: 10–30 bytes (§4).

### 3.2 `memset(dst: u64, val: u64, n: u64) -> u64`

**SysV entry**: `rdi = dst`, `rsi = val` (low 8 bits used), `rdx = n`.
**Return**: `rax = dst` (unmodified pointer).
**Clobbers**: `rax`, `rdi`, `rsi`, `rdx`, `rcx`, `r8` (all caller-saved).
**Writes**: bytes at `[dst, dst+n)`.
**Preserves**: `rbx`, `rbp`, `r9..r15`, `rsp`.
**Behavior on n=0**: writes nothing; returns `dst`.
**Val truncation**: only the low 8 bits of `val` are used (POSIX `int c`
→ `unsigned char` conversion). Caller passing `val=0x1FF` writes `0xFF`.

```pdx
// memset(dst, val, n) → dst. Fill n bytes at dst with (val & 0xFF).
// dst in rdi, val in rsi (low 8 bits used), n in rdx; result in rax = dst.
// Uses rep_stosb (F3 AA) with a leading cld (FC).
// Val truncation matches POSIX memset("int c ... converted to unsigned char").
pub let memset : (u64, u64, u64) -> u64 !{mem} @{} =
  fn (dst: u64) (val: u64) (n: u64) -> unsafe {
    effects: {mem}, capabilities: {},
    justification: "R17-m1-003 (#612) §3.2: memset via rep_stosb. Save rdi (dst) in r8 for return. Move val → rax (rep_stosb reads only AL; upper bytes ignored, matching POSIX unsigned-char truncation). Move n → rcx. cld to force forward. rep_stosb (rdi=dst, rcx=count, al=fill_byte). Restore dst from r8 to rax. r8 caller-saved. Encoder: mov reg-reg + cld + rep_stosb + ret. rep_stosb (F3 AA) is encoder-audited (paideia-as #1228) but not yet live in paideia-os kernel — see design doc §2.4 for probe. n=0 handled implicitly (rep with rcx=0 is no-op).",
    block: {
      mov r8, rdi;                     // r8 = dst (save for return)
      mov rax, rsi;                    // al = val (rep_stosb reads AL only)
      mov rcx, rdx;                    // rcx = count (rep prefix reads rcx)
      cld;                             // DF=0 (forward store)
      rep_stosb;                       // *rdi++ = al; rcx--; while rcx != 0
      mov rax, r8;                     // rax = dst (return value — overwrites al/rax; harmless post-stos)
      ret
    }
  }
```

**Byte size** (paideia-as emit expected):

| Instruction              | Encoding       | Bytes |
|--------------------------|----------------|-------|
| `mov r8, rdi`            | `49 89 F8`     | 3     |
| `mov rax, rsi`           | `48 89 F0`     | 3     |
| `mov rcx, rdx`           | `48 89 D1`     | 3     |
| `cld`                    | `FC`           | 1     |
| `rep_stosb`              | `F3 AA`        | 2     |
| `mov rax, r8`            | `4C 89 C0`     | 3     |
| `ret`                    | `C3`           | 1     |
| **Function total**       |                | **16**|

Canary budget: 12–30 bytes (§4).

### 3.3 Module structure — append point in `string.pdx`

`src/user/string.pdx` at HEAD f933889 ends with:

```pdx
  // ==========================================================================
  // Reserved for #612 append: memcpy, memset (and possibly strcmp, strncmp)
  // ==========================================================================
}
```

This issue **replaces those comment lines with the two new `pub let`
blocks + a fresh reserved-region marker** (in case a future issue adds
strcmp/strncmp). Post-landing shape:

```pdx
  // ==========================================================================
  // §3.1 (this issue) — memcpy: rep_movsb copy
  // ==========================================================================

  pub let memcpy : (u64, u64, u64) -> u64 !{mem} @{} = ...   // 13 bytes per §3.1

  // ==========================================================================
  // §3.2 (this issue) — memset: rep_stosb fill
  // ==========================================================================

  pub let memset : (u64, u64, u64) -> u64 !{mem} @{} = ...   // 16 bytes per §3.2

  // ==========================================================================
  // Reserved for future append: strcmp, strncmp (post-R17.M1 if needed)
  // ==========================================================================
}
```

No module-name change; no import changes; no linker-script change (the
existing `KEEP(*(.text._start))` + `*(.text .text.*)` wildcards absorb
`.text.memcpy` and `.text.memset` automatically).

### 3.4 Direction-flag discipline

Both `rep_movsb` and `rep_stosb` respect the direction flag (DF). SysV
AMD64 ABI Section 3.4.1 guarantees DF=0 on function entry — but that's a
CALLER-observed contract, and our helpers are invariant under a
potentially-DF-set caller. **We emit `cld` unconditionally.** Cost: 1
byte. Benefit: no dependency on caller's DF hygiene; matches the kernel
idiom at tmpfs/read.pdx:119 and tmpfs/write.pdx:118. paideia-as `cld`
encoder landed at PA-R13-008 (#937).

**Alternative rejected — skip cld and rely on SysV DF=0 invariant.** The
kernel-side memcpy sites emit `cld` explicitly; #937 CHANGELOG note
explicitly retires the "rely on SysV DF=0" workaround. Consistency wins;
1 byte is negligible.

### 3.5 Effect signatures

- **`memcpy`** — `!{mem} @{}`. Reads `[src, src+n)`, writes
  `[dst, dst+n)`. No capability (user-space only; no syscall).
- **`memset`** — `!{mem} @{}`. Writes `[dst, dst+n)`. No capability.

Both narrower than any syscall wrapper (no `sysreg` — no `SYSCALL`
instruction). Matches `strlen`/`memcmp` effect discipline exactly (see
#611 §3.5).

### 3.6 Interaction with the linker script

Unchanged from #611 §3.4. `src/user/link.ld` puts `.text.memcpy` and
`.text.memset` under `*(.text .text.*)` — no edit needed. The canary
(§4) looks up symbols by name via objdump, independent of absolute
address.

## 4. Test canary — extend `verify-user-string.sh`

The AC's phrasing ("memcpy round-trip byte-identical") requires runtime
verification — copy X bytes into Y, then compare X and Y byte-by-byte
and assert equality. As with #611, the runtime venue is #615
(`libc_test.pdx`) once the ring-3 loader lands; for **this** issue, the
canary is compile-time-only:

1. **Symbol existence** — `memcpy` and `memset` appear as global symbols
   in `build/user/shell.elf`.
2. **Function size sanity** — each function's bytes fall within a
   documented budget (memcpy: 10–30; memset: 12–30). Out-of-budget size
   indicates encoder drift or source typo.
3. **rep-prefix opcode signature** — each function contains the specific
   byte sequence `f3 a4` (for memcpy → `rep_movsb`) or `f3 aa` (for memset
   → `rep_stosb`), and the direction-clear byte `fc` (`cld`), and a `c3`
   (`ret`).
4. **NO `syscall` opcode** (`0f 05`) — pure userland, no kernel entry.

The existing `verify_fn` helper in `verify-user-string.sh` handles items
(1), (2), (4), and a generic branch signature that was appropriate for
byte-loops. This issue **adds a second, rep-specific verifier
function** (`verify_rep_fn`) that checks for the specific `f3 XX` byte
pair. The reason for a separate helper: byte-loops require `0f b6` +
branch + jmp; rep-based helpers do NOT contain those bytes (no loop, no
branch — the CPU's microcode is the loop). Applying the byte-loop
signature check to memcpy/memset would spuriously fail.

### 4.1 `tools/verify-user-string.sh` (extend, ~40 LOC delta)

Add a new helper `verify_rep_fn` and two new verification calls:

```bash
# Verify a rep-prefix function: name, min_bytes, max_bytes, rep_opcode.
# rep_opcode: "a4" for rep_movsb, "aa" for rep_stosb.
verify_rep_fn() {
    local name="$1" lo="$2" hi="$3" rep_op="$4"

    # (Same objdump-parse-then-buffer logic as verify_fn — extract $2 hex bytes column)
    local dump
    dump=$(objdump -d -M intel "$ELF" 2>/dev/null | awk -v sym="$name" -F '\t' '
        BEGIN { seen = 0; buf = "" }
        $0 ~ "<"sym">:"       { seen = 1; next }
        seen && $0 ~ /^[0-9a-f]+ </ { exit }
        seen && NF >= 2 && $1 ~ /^[[:space:]]+[0-9a-f]+:/ {
            hex_bytes = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", hex_bytes)
            if (hex_bytes != "") buf = buf " " hex_bytes
        }
        END { print buf }
    ' | tr -s ' ' | sed 's/^ //;s/ $//')

    if [[ -z "$dump" ]]; then
        echo "[FAIL] $name: symbol not found in ELF"
        FAIL=1
        return
    fi

    local nbytes
    nbytes=$(echo "$dump" | tr ' ' '\n' | grep -c '^[0-9a-f][0-9a-f]$' || true)

    if (( nbytes < lo || nbytes > hi )); then
        echo "[FAIL] $name: $nbytes bytes outside budget [$lo, $hi]"
        FAIL=1
        return
    fi

    # rep-signature: must contain "fc" (cld), "f3 <rep_op>" (rep prefix +
    # movsb/stosb), and "c3" (ret). Must NOT contain 0f 05 (syscall).
    if ! echo "$dump" | grep -q "fc"; then
        echo "[FAIL] $name: missing cld (fc)"
        FAIL=1
    fi
    if ! echo "$dump" | grep -q "f3 ${rep_op}"; then
        echo "[FAIL] $name: missing rep prefix f3 ${rep_op}"
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
        echo "[ok]   $name: $nbytes bytes; rep signature OK"
    fi
}

# Existing byte-loop verifications (unchanged):
verify_fn strlen 20 40
verify_fn memcmp 40 70

# New rep-prefix verifications:
verify_rep_fn memcpy 10 30 a4
verify_rep_fn memset 12 30 aa
```

Terminal marker changes from `R17 USER STRING OK` to `R17 USER MEM OK` on
success — the script now covers both string (strlen, memcmp) and mem
(memcpy, memset) primitives. `build-user.sh` line 46 comment updates:
`[verify-user] byte-shape canary on strlen/memcmp/memcpy/memset in shell.elf`.

**Alternative rejected — separate `verify-user-mem.sh` script.** Would
require two script invocations in `build-user.sh` and duplicate the
objdump-parse boilerplate. One extended script keeps the interface
narrow: the canary discipline is "shape of user string.pdx symbols", not
"shape of memcpy specifically". The two `verify_*_fn` helpers share the
same awk parser and same FAIL accumulator.

### 4.2 `tools/build-user.sh` — no change

The existing invocation at line 47 (`verify-user-string.sh
${BUILD_DIR}/shell.elf`) covers the extended canary automatically. Only
the log message could be tightened (optional):

```bash
# Optional: update comment on line 46 from
#   "byte-shape canary on strlen/memcmp in shell.elf"
# to
#   "byte-shape canary on strlen/memcmp/memcpy/memset in shell.elf"
```

### 4.3 Why no kernel-side runtime witness at R17.M1

Same three reasons as #611 §4.3 (mutatis mutandis):

1. **No ring-3 execution surface yet.** `shell.bin` embedded in
   `.rodata.userbin` but kernel never JMP's into it at boot; that lands
   with R17.M2 init loader (#616+). A kernel-side memcpy witness would
   require duplicating memcpy bytes into `.text.kernel` — defeating the
   test's purpose (we'd be testing a kernel copy of memcpy, not the
   user-space `.text.memcpy` symbol).
2. **Runtime venue is #615.** `libc_test.pdx` is the correct altitude —
   a ring-3 binary that calls memcpy/memset with known inputs, verifies
   round-trip byte-identical via memcmp, prints `LIBC TEST OK`. That is
   where the AC "memcpy round-trip byte-identical" is exercised.
3. **AC does not require boot execution.** #610 and #611 both set the
   precedent: compile-time shape canary + deferred #615 runtime witness.

### 4.4 Optional: pre-stage the fixture inside shell.pdx (deferred to #615)

As with #611 §4.4 — implementer *could* add a call site inside
`shell.pdx`'s `_start`:

```asm
// Fixture placeholder for R17-M1-003 (#612):
lea rdi, [rip + scratch_buf];
lea rsi, [rip + hello_msg];
mov rdx, 5;
call memcpy;                     // dst=scratch, src="hello", n=5
```

**Not recommended.** Same rationale as #611: scope creep past
`Touching: src/user/string.pdx`; adds dead code in the current boot
path; trivially added by #615 when ring-3 loading is ready.

## 5. Backtrack candidates

Ordered by preference.

### 5.1 Backtrack A — Byte-loop fallback (rep encoder failure)

If §2.4's `rep_stosb` probe fails (encoder emits wrong bytes or errors),
land byte-loop versions of both memcpy and memset instead. Estimated
byte size: 25–30 per function.

```pdx
// memset byte-loop fallback (~28 bytes):
pub let memset : (u64, u64, u64) -> u64 !{mem} @{} =
  fn (dst: u64) (val: u64) (n: u64) -> unsafe {
    effects: {mem}, capabilities: {},
    justification: "R17-m1-003 (#612) BACKTRACK A: byte-loop memset. rep_stosb encoder unavailable at paideia-as HEAD; loop until rdx==0.",
    block: {
      mov r8, rdi;                     // save dst
      mov rax, rsi;                    // val (low 8 bits used)

    memset_loop:
      cmp rdx, 0;                      // n == 0?
      je  memset_done;
      mov_b [rdi + 0], rax;            // *rdi = al
      add rdi, 1;
      sub rdx, 1;
      jmp memset_loop;

    memset_done:
      mov rax, r8;
      ret
    }
  }

// memcpy byte-loop fallback (~35 bytes):
// Loop: load [rsi], store [rdi], advance both, decrement rdx, until rdx==0.
```

Consequence: doubles per-function bytes; runs at ~5 bytes/cycle instead
of ERMS's ~30 bytes/cycle. R17.M3 shell's memcpy calls are ≤128 bytes
per invocation — negligible performance cost. Only used if rep encoder
regresses.

**Consider only after §2.4 probe failure.** Rep prefix is the primary
plan.

### 5.2 Backtrack B — Merge with #611 retroactively

Land memcpy/memset in the same commit as #611 (retroactive amend of
`src/user/string.pdx`). Requires rebasing #611's landing commit —
inconsistent with paideia-os's forward-only commit discipline (per
`feedback_paideia_os_no_cicd.md`: verification is local, but commits
are append-only).

**Reject.** #611 already landed at f933889; this issue adds two functions
on top. The `Reserved for #612 append` marker (line 78) is precisely
this issue's target.

### 5.3 Backtrack C — Prefer callee-saved r13/r14 for dst-save

Push `rbx` at entry, use `rbx` to save `dst` across the rep sequence,
pop at exit. 3-byte prologue + 3-byte epilogue = 6 bytes, same total as
`mov r8, rdi` / `mov rax, r8` (which is 6 bytes). No net savings; adds
stack traffic; requires alignment discipline if a nested call ever
appears (unlikely — these are leaves).

**Reject.** No net benefit. `r8` scratch is simpler.

### 5.4 Backtrack D — Two-tier memcpy (rep_movsq middle + rep_movsb tails)

Detect 8-byte alignment of `dst` and `src`, jump to a `rep_movsq` middle
loop (8× throughput on non-ERMS uarchs), then a `rep_movsb` tail for
`n & 7` bytes. ~40 bytes of code.

Consequence: 2-4x faster for large (>512-byte) aligned copies on
pre-ERMS silicon. R17.M1's expected callers (shell argv, line buffers)
are always small (<128 bytes) — no measurable benefit. Adds complexity
+ additional canary logic.

**Reject at R17.M1.** Revisit if a hot memcpy path emerges in profiling
data post-R17 shell landing. Filed as a follow-up thought, not a blocker.

### 5.5 Backtrack E — Skip the shape canary extension

Ship memcpy/memset without extending `verify-user-string.sh`; rely on
`build-user.sh` compilation success alone.

**Reject.** #611 established the extended-canary discipline for every
new libc-lite function. Departing here would (a) create a silent hole
if rep_stosb encoder ever regresses; (b) set a soft precedent for #614
and #615 to also skip. 40-LOC extension is proportionate insurance.

## 6. LOC estimate

| File                                                          | LOC delta |
|---------------------------------------------------------------|-----------|
| `src/user/string.pdx` (append memcpy + memset)                | +70       |
| `tools/verify-user-string.sh` (extend with verify_rep_fn)     | +40       |
| `design/kernel/r17-m1-003-user-mem.md` (this doc)             | +560      |
| **Total**                                                     | **~670**  |

Executable / build code: **~110 LOC** (70 pdx + 40 shell). Design + prose:
~560 LOC. The 70-LOC pdx figure assumes:

- `memcpy`: ~28 LOC (7 lines of block body + 8 lines of scaffolding
  `pub let/fn/unsafe/justification/effects/capabilities/block: {` +
  10 lines of comment + blank lines).
- `memset`: ~30 LOC (8 lines of block body + 8 lines of scaffolding +
  10 lines of comment + blank lines).
- Section-banner comments + reserved-for-future marker: ~12 LOC.
- Module-header comment update (extend header to mention memcpy/memset):
  0 LOC (existing header at lines 1-4 already parametric).

## 7. Tractability

**HIGH.**

- **Zero paideia-as encoder gap expected.** `rep_movsb` (F3 A4) and `cld`
  (FC) both have 2 live-tree callers each (§2.2). `rep_stosb` (F3 AA)
  is encoder-audited (paideia-as #1228) but not yet paideia-os-live; the
  two-line probe (§2.4) confirms it before landing. Backtrack plan A
  documented if probe fails (unlikely: <2%).
- **Zero kernel-side change.** All work under `src/user/`; kernel link
  graph untouched. `tools/build.sh` unaware.
- **Zero smoke-fingerprint drift.** No new boot marker. Canary's
  `R17 USER MEM OK` line goes to `build-user.sh` stdout only. Every
  `boot_r8_only`..`boot_r12_denial` mode stays byte-identically green.
- **Zero cross-repo escalation expected.** All required paideia-as
  features landed at 0.20.0. Modulo the §2.4 probe, no work upstream.
- **~110 LOC executable across one .pdx append + one shell script
  extension.** Fits R17.M1 tempo (#610: 240 exec LOC; #611: 180 exec LOC;
  #612: 110 exec LOC — decreasing as reserved patterns are reused).
- **Byte budget honored.** Each function's expected size (13 for memcpy,
  16 for memset) sits comfortably inside canary windows (10–30, 12–30),
  leaving room for paideia-as to select a different mov-reg-reg encoding
  form (e.g., 2-byte short form via `mov r/m64, r64` with implicit REX)
  without failing the canary.
- **AC is directly testable at compile time.** Canary emits:
  - `[ok]   memcpy: 13 bytes; rep signature OK`
  - `[ok]   memset: 16 bytes; rep signature OK`
  - `R17 USER MEM OK`
  Three exit-visible lines pin the landing.
- **Runtime AC** (`memcpy round-trip byte-identical`) satisfied at #615
  via `libc_test.pdx` — the fixture writes 8 bytes to a scratch buffer,
  copies via memcpy, calls memcmp on the two ranges, expects 0.

**Rep encoder confirmed.** `rep_movsb` audited (#940), live at kernel
HEAD (tmpfs/read.pdx:120, write.pdx:119). `rep_stosb` audited (#1228),
encoder tests green in paideia-as. `cld` audited (#937), live at
kernel HEAD.

Known follow-ups (not blockers for #612):

- **#615 (`r17-m1-006-user-smoke-libc`)** — runtime witness executes
  memcpy/memset in ring-3 and emits `LIBC TEST OK`.
- **#614 (`r17-m1-005-user-puts-getline`)** — puts uses strlen only; no
  memcpy dep. Getline may use memcpy for token-copy — decision deferred
  to #614's design doc.
- **R17.M3 shell (#622+)** — memcpy for argv token slicing; memset for
  line-buffer clear.
- **Post-R17 memmove** — overlap-safe copy, filed as a distinct issue
  when a caller emerges.

## 8. Cross-cutting risks

- **`rep_stosb` first-in-tree caller.** Mitigated by §2.4's probe;
  encoder tested in paideia-as. Fallback: byte-loop memset (§5.1). Not a
  blocking risk (<2%).
- **paideia-as `mov r/m64, r64` REX.WB variants for r8-family.** All
  four mov-reg-reg forms used here (`mov r8, rdi`, `mov rax, r8`,
  `mov rax, rsi`, `mov rcx, rdx`) are ubiquitous in the tree.
- **Direction-flag hygiene.** We `cld` unconditionally — no dependency
  on caller's DF state. Cost: 1 byte. Kernel precedent identical.
- **Return-register clobber on n=0.** `mov rax, rsi` in memset happens
  BEFORE the rep, so even if n=0 (rep is no-op), `rax` is transiently
  the passed `val` and then overwritten by `mov rax, r8` (dst). Final
  `rax = dst`. Correct.
- **Overlap undefined behavior.** POSIX `memcpy` semantics; caller
  responsibility. If a caller ever wants `memmove` semantics, file a
  post-R17 issue for a separate `memmove` (or a runtime overlap check
  + reverse-direction copy). R17.M3 shell has no such caller.
- **Canary false positive from binutils version drift.** Same risk as
  #611: objdump output columns could shift; awk parser could fail.
  Mitigated by the `nbytes < lo` check (0 bytes always fails 10-byte
  minimum for memcpy).
- **Val > 255 in memset.** Silent truncation to low 8 bits — matches
  POSIX. Documented in source comment. No runtime check (cost > benefit;
  no caller error is realistic).
- **Symbol collision with future kernel-side `memcpy`.** Kernel does
  not currently expose a global `memcpy` symbol; the kernel's copy
  logic is inline within tmpfs/read.pdx and tmpfs/write.pdx (no named
  wrapper). If a future kernel-side `memcpy` lands, its symbol lives in
  `kernel.elf` and this issue's lives in `shell.elf` — two ELFs, no
  collision.

## 9. References

- Issue: paideia-os#612
- Milestone: paideia-os milestones/69 (R17.M1 libc-lite for userland)
- Sibling issues (R17.M1): #610 syscall shim (landed 0d47d17), #611
  strlen/memcmp (landed f933889), #613 errno slot, #614 puts/getline,
  #615 libc smoke.
- Tactical plan: `design/milestones/r14b-tactical-plan.md` §Subsystem 16
  line 1663 — "memset, memcpy — byte-loop (rep movsb once encoder
  confirmed)". Encoder confirmed at paideia-as 0.20.0.
- Master plan: `design/milestones/r14b-master-plan.md` §R17 (libc).
- Predecessor design doc: `design/kernel/r17-m1-002-user-string.md` —
  file topology, canary discipline, no-runtime-witness-yet stance this
  doc inherits.
- Kernel `rep_movsb` precedents:
  - `src/kernel/core/fs/tmpfs/read.pdx:109-120` — the read path this
    issue's memcpy structurally mirrors (rsi=src, rdi=dst, rcx=count,
    cld, rep_movsb).
  - `src/kernel/core/fs/tmpfs/write.pdx:108-119` — the write sibling.
- Kernel `rep_stosq` precedent (structural analog for memset,
  differing only by width):
  - `src/kernel/core/fs/tmpfs/inode.pdx:117-131` — zero-slot via
    rep_stosq (save rdi in r10, count in rcx, fill in rax, cld,
    rep_stosq, restore).
- paideia-as CHANGELOG:
  - PA-R13-008 (#937) — `cld` (FC).
  - PA-R13-011 (#940) — `rep_movsb` (F3 A4).
  - PA-R13-012 (#941) — `rep_stosq` (F3 48 AB); sibling to rep_stosb.
  - #1064 / #1228 — BulkMemOps stdlib including `rep_stosb` (F3 AA).
- paideia-as encoder tests:
  - `tests/build-emit/rep_movsb_smoke.pdx` — 4 sub-tests.
  - `tests/build-emit/rep_stosb_smoke.pdx` — 4 sub-tests.
- User-space link map: `src/user/link.ld` (R15-M1-003) — no edit needed.
- Build orchestrator: `tools/build-user.sh` — no edit needed (existing
  invocation at line 47 covers extended canary).
- Prior canary: `tools/verify-user-string.sh` (R17-M1-002) — extended
  by ~40 LOC with `verify_rep_fn` helper and two additional calls.
