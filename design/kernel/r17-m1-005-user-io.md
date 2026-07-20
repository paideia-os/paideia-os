---
issue: 614
milestone: R17.M1 (libc-lite for userland)
subsystem: 16 — libc-lite for userland
prereq:
  - "#610 (r17-m1-001-syscall-shim) — sys_read/sys_write wrappers (raw returns, no errno translation)"
  - "#611 (r17-m1-002-user-string) — strlen for puts(str) → strlen + sys_write delegation"
  - "#613 (r17-m1-004-user-errno) — syscall_check for error translation (deferred to #615 runtime adoption)"
blocks:
  - "#615 (r17-m1-006-user-smoke-libc) — libc_test.pdx will call puts/getline at runtime with known inputs"
  - "R17.M2 init (#616+), R17.M3 shell (#622+) — all depend on puts/getline for I/O"
touching:
  - src/user/io.pdx                     (update: retire R13 legacy puts, add puts_new + getline)
  - tools/verify-user-io.sh             (new: build-time call-site + symbol canary)
  - tools/build-user.sh                 (add verify-user-io.sh invocation post-link)
  - design/kernel/r17-m1-005-user-io.md (this doc)
related:
  - "#610 (r17-m1-001 syscall_shim — raw wrappers sys_read/sys_write)"
  - "#611 (r17-m1-002 user-string — strlen for puts delegate)"
  - "#613 (r17-m1-004 user-errno — errno support, consumed by callers of puts/getline)"
  - "#615 (r17-m1-006 libc_test — runtime witness for puts/getline)"
  - "design/user/syscall-table.md (SC+ frozen table — sys_read/sys_write behavior defined at kernel boundary)"
  - "design/milestones/r14b-tactical-plan.md §Subsystem 16 (lines 1635–1710 + I/O helpers)"
---

# R17-M1-005 — user I/O helpers (puts/getline) (#614)

## 1. Scope

Implement two user-space I/O wrapper functions in `src/user/io.pdx`:

- **`puts_new(s: u64) -> u64`** — emit a NUL-terminated string to stdout (fd 1).
  On entry, `s` is a pointer to a NUL-terminated string (in `rdi` per SysV ABI).
  Calls `strlen(s)` to compute length, then `sys_write(1, s, length)`.
  Returns the count of bytes written (or negative error from sys_write).

- **`getline(buf: u64, sz: u64) -> u64`** — read up to `sz` bytes from stdin (fd 0) into buffer `buf`.
  On entry, `buf` is in `rdi`, `sz` is in `rsi` (SysV ABI).
  Calls `sys_read(0, buf, sz)` and returns bytes read (or negative error from sys_read).

Both functions delegate syscall invocation to the R17.M1-001 syscall shim (#610)
and string helpers to R17.M1-002 (#611), maintaining the separation of concerns:
- **Syscall shim (#610)** — raw SYSCALL instruction wrappers with no error translation.
- **String helpers (#611)** — pure user-space byte manipulation (strlen for puts).
- **This issue (#614)** — high-level I/O abstractions that compose syscall + string helpers.

Backward compatibility note:

- **R13 legacy `puts(msg_ptr, msg_len)` retained.** The old two-arg form that
  delegates to `sys_debug_puts` is kept in `src/user/io.pdx` for source-level
  compat with existing `shell.pdx` callers (issue #483). It is marked DEPRECATED
  in the source comment and in design docs. Future R17.M3+ code should use `puts_new`.

Out of scope (deliberately deferred):

- **errno translation on puts/getline returns.** #615 (libc_test) will adopt
  `syscall_check` wrappers if needed for POSIX-conform -1/(errno) returns.
  This issue lands only the raw sys_read/sys_write delegation path.
- **File descriptor abstraction.** puts and getline hardcode fd 1 and 0.
  A generic `write_fd(fd, buf, count)` is future work if R17.M3+ needs it.
- **Non-blocking I/O or timeout.** Both calls block until completion or error.
- **Buffering.** No internal buffers; every call goes directly to the syscall.

## 2. Design

### 2.1 `puts_new(s: u64) -> u64`

**Semantic description**: `puts_new(s) ≡ sys_write(1, s, strlen(s))`.

**SysV entry**: `rdi = s` (pointer to NUL-terminated bytes).

**SysV return**: `rax = bytes written` (or negative error code from sys_write).

**Clobbers**: `rdi` (caller-saved), `rdx` (caller-saved), `r9` (caller-saved, temp storage for s).

**Preserves**: `rsi`, `r8`, `r10..r15`, `rbx`, `rbp`, `rsp` (except across stack writes if any).

**Implementation strategy**:
1. Save `s` (in `rdi`) to `r9` (caller-saved temp storage).
2. Call `strlen(s)` — expects `s` in `rdi`, returns count in `rax`, clobbers `rdi`.
3. After strlen, set up for sys_write:
   - `rdi = 1` (fd stdout)
   - `rsi = r9` (saved string pointer)
   - `rdx = rax` (count from strlen)
4. Call `sys_write(rdi=1, rsi=buf, rdx=count)`.
5. Return with `rax` containing the bytes-written result (or negative error).

**Byte size estimate** (per paideia-as emit):
- `mov r9, rdi` (save): 3 bytes
- `call strlen`: 5 bytes (direct call to named label)
- `mov rdi, 1`: 3 bytes (mov r64, imm8)
- `mov rsi, r9` (restore): 3 bytes (mov r64, r64)
- `mov rdx, rax`: 3 bytes (mov r64, r64)
- `call sys_write`: 5 bytes
- `ret`: 1 byte
- **Total**: ~23 bytes; budget 20–40 bytes.

### 2.2 `getline(buf: u64, sz: u64) -> u64`

**Semantic description**: `getline(buf, sz) ≡ sys_read(0, buf, sz)`.

**SysV entry**: `rdi = buf`, `rsi = sz`.

**SysV return**: `rax = bytes read` (or negative error code from sys_read).

**Clobbers**: `rdi`, `rsi`, `rdx` (all caller-saved).

**Preserves**: `r8..r15`, `rbx`, `rbp`, `rsp`.

**Implementation strategy**:
Since `getline` takes two args (buf, sz) but must call sys_read which also takes
three args (fd, buf, count), we rearrange registers in place:
1. On entry: `rdi = buf`, `rsi = sz`.
2. sys_read needs: `rdi = 0` (fd), `rsi = buf`, `rdx = sz`.
3. Rearrangement (no temp storage needed):
   - `mov rdx, rsi` (move sz into rdx)
   - `mov rsi, rdi` (move buf into rsi)
   - `mov rdi, 0` (load fd=0 into rdi)
4. Call `sys_read(rdi=0, rsi=buf, rdx=sz)`.
5. Return with `rax` containing the bytes-read result (or negative error).

**Byte size estimate**:
- `mov rdx, rsi`: 3 bytes
- `mov rsi, rdi`: 3 bytes
- `mov rdi, 0`: 3 bytes (mov r64, imm8)
- `call sys_read`: 5 bytes
- `ret`: 1 byte
- **Total**: ~15 bytes; budget 12–35 bytes.

### 2.3 Module structure

Both functions are added to `src/user/io.pdx` alongside the R13 legacy `puts`.

### 2.4 Effect signatures

- **`puts_new`** — `!{mem, sysreg} @{fs}`.
  - `mem`: reads memory at `[s, s + strlen(s)]` (the string).
  - `sysreg`: SYSCALL instruction (inside sys_write delegation).
  - `fs`: file descriptor capability required for writing to fd 1 (stdout).

- **`getline`** — `!{mem, sysreg} @{fs}`.
  - `mem`: writes memory at `[buf, buf + sz)` (caller's buffer).
  - `sysreg`: SYSCALL instruction (inside sys_read delegation).
  - `fs`: file descriptor capability required for reading from fd 0 (stdin).

### 2.5 Interaction with existing modules

- **`strlen` from #611** — `puts_new` calls strlen to compute string length before
  delegating to sys_write. No explicit dependency declaration in the .pdx source
  (the linker resolves the `call strlen` symbol at link time).

- **`sys_read`/`sys_write` from #610** — both functions call these syscall wrappers.
  These symbols are defined in `syscall_shim.pdx` and linked together by `tools/build-user.sh`.

- **R13 legacy `puts`** — retained for backward compatibility with existing callers.

## 3. Test canary — build-time call-site + symbol verifier

The AC's phrasing ("puts('hello') emits 'hello' on serial") requires runtime
execution. R17.M1 has no ring-3 execution surface yet. This issue provides a
**build-time canary** that verifies:

1. **Symbol existence** — `puts_new` and `getline` appear as global symbols in `shell.elf`.
2. **Call-site signatures** — both functions contain `call` instructions to expected helpers.
3. **NO direct SYSCALL** — each function must delegate, not emit SYSCALL directly.
4. **Function size sanity** — bytes fall within documented budgets.

Runtime exercise is deferred to **#615 (libc_test.pdx)**.

### 3.1 `tools/verify-user-io.sh` (new)

A shell script that uses `objdump -d` to extract function bytecode from `shell.elf`,
verifies symbol existence, function size, call-site signatures, and absence of
direct SYSCALL opcodes.

Exit codes:
- 0: `R17 USER IO OK` — all verifications passed.
- 1: `R17 USER IO FAIL` — one or more verifications failed.

### 3.2 `tools/build-user.sh` — append verifier invocation

Two-line append after the existing `verify-user-errno.sh` invocation.

## 4. LOC estimate

| File                                                  | LOC delta |
|-------------------------------------------------------|-----------|
| `src/user/io.pdx` (update: add puts_new + getline)   | +50       |
| `tools/verify-user-io.sh` (new)                       | +60       |
| `tools/build-user.sh` (append verifier invocation)    | +2        |
| `design/kernel/r17-m1-005-user-io.md` (this doc)      | ~300      |
| **Total**                                             | **~412**  |

## 5. Tractability

**HIGH.** Every instruction is emitted elsewhere in the tree. No kernel changes.
No smoke-fingerprint drift. AC directly testable at build time.

## 6. Known follow-ups (not blockers for #614)

- **#615 (r17-m1-006-user-smoke-libc)** — runtime witness.
- **Error path adoption.** #615 will demonstrate wrapping via `syscall_check`.
- **R17.M3 shell (#622+)** — adopts puts_new for output; adopts getline for input.

## 7. References

- Issue: paideia-os#614
- Milestone: paideia-os milestones/69 (R17.M1 libc-lite for userland)
- Sibling issues (R17.M1): #610 syscall shim, #611 strlen/memcmp, #612 memcpy/memset, #613 errno slot, #615 libc smoke
- Syscall shim design: `design/kernel/r17-m1-001-syscall-shim.md`
- String helpers design: `design/kernel/r17-m1-002-user-string.md`
- errno slot design: `design/kernel/r17-m1-004-user-errno.md`
- User-space link map: `src/user/link.ld` (R15-M1-003) — no edit required
- Build orchestrator: `tools/build-user.sh` — extended by +2 lines
