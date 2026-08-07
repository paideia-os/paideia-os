# R17-M2-736 (D12): runtime u32→decimal in init's wait_msg

**Status:** landed
**Issue:** paideia-os #736 (aka #723 D12)
**Depends on:** #730 (D10 execve completes), #732 (wait4 arg marshalling), #728 D9 (per-task kernel stack)
**Precondition wire-state:** post-#732 the parent's `sys_wait4` returns the real child pid in `rax` and the kernel writes the real exit status to `wait_status[0]`. Init has both values in memory, but the AC line it emits is still a hardcoded rodata literal (`"WAIT: pid=2 status=42\n"`) — the printed digits are decoupled from the wire values.
**AC target:** the `WAIT:` line's digits are produced by a real runtime formatter that reads the reaped pid (`rax` from `sys_wait4`) and `wait_status[0]`. Wire matches memory.

---

## 1. Wire evidence pre-fix

Current (D10) `tools/run-smoke.sh boot_r17_init` produces:

```
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
WAIT: pid=2 status=42     ← hardcoded literal (rodata bytes 22)
REAPED
```

The `WAIT:` line is `src/user/init.pdx`'s `wait_msg: [u8; 23] = "WAIT: pid=2 status=42\n\0"` printed verbatim via a single `sys_debug_puts(wait_msg, 22)`. `sys_wait4`'s return value is compared against 0 (for the `jl init_shutdown` error branch) and then dropped. `wait_status[0]` is never read.

This is fragile in the exact way #723's AC was written to catch: if `pid_alloc`'s dense-low scan ever hands the child a different pid (as would happen after #735's pid-leak fix inverts, or before it if any prior task consumed pid 2), or if `child_hello.pdx` ever exits with a different status, the wire line still says `pid=2 status=42` and the smoke fingerprint silently accepts the lie.

Post-D12, the wire digits *are* the memory values. A regression in either wait4's marshalling or wait_status writeback (#732 territory) is now caught at the fingerprint layer, not just via GDB.

---

## 2. Design

### 2.1 Split rodata into three fragments

`wait_msg` becomes three separately-emitted string fragments plus two interleaved runtime decimals:

| Symbol | Storage | Emitted len | Contents |
|---|---|---|---|
| `wait_prefix`  | `[u8; 11]` | 10 | `"WAIT: pid=\0"` |
| `wait_sep`     | `[u8; 9]`  | 8  | `" status=\0"` |
| `wait_newline` | `[u8; 2]`  | 1  | `"\n\0"` |

Total emitted bytes (excluding decimals): 19 (vs. 22 for the old fixed line). NUL is stored for `strlen`-safety symmetry with the existing `init_msg` / `reaped_msg` idiom but never sent on the wire — `sys_debug_puts` is length-bounded.

The three fragment lengths are hardcoded in `mov rsi, N` immediates at each `call sys_debug_puts` site; no separate `..._len` u64 rodata entries (they'd match the existing `wait_len` idiom but add three rodata slots for values already known at compile time). This matches the style of `sys_debug_puts` calls that pass literal `mov rsi, 8` for `init_msg` etc.

The old `wait_msg`/`wait_len` symbols are removed. `tools/verify-user-init.sh` line 227 currently `grep -c wait_msg` on the disassembly dump; the check migrates to `wait_prefix` (the new anchor symbol that only exists post-D12).

### 2.2 Formatter: `print_u64_dec(value: u64) -> ()`

A single leaf helper, private to init.pdx (not moved to a libc module — it would drag the shell/child_hello link surface without any current consumer beyond init's own wait line; premature). Takes value in `rdi`, prints its unsigned decimal representation via `sys_debug_puts`, and returns.

Register discipline (SysV, standard):
- **Reads:** `rdi` (value)
- **Preserves:** `rbx, rbp, r12–r15` (callee-save)
- **Clobbers:** `rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11` (caller-save; syscall additionally clobbers `rcx, r11` but they're already in the caller-save set)
- **Stack:** allocates 24 bytes of scratch (20 needed for `u64::MAX = 20 digits`; 24 keeps 16-byte alignment for the subsequent `call sys_debug_puts`)

Effects/capabilities: `!{mem, sysreg} @{}`. `mem` for the stack writes and the sys_debug_puts memory read; `sysreg` for the syscall; no caps needed (sys_debug_puts declares `@{}`).

**Note on u32 vs. u64.** Both `rax` (child pid, u64) and `wait_status[0]` (u64) are u64-sized in the ABI. Naming the helper `print_u64_dec` matches the kernel's existing `u64_to_dec` (src/kernel/core/klog/hex.pdx:77) and avoids a spurious truncation step. For the AC values in scope (pid ≤ few thousand, status ≤ 255), the top 32 bits are always zero — a `u32` label would document intent but the encoded loop is identical.

### 2.3 Algorithm

Standard divide-by-10 with reverse-order digit stash:

```
sub  rsp, 24                    ; 20-byte staging + 4-byte alignment slop
cmp  rdi, 0                     ; zero special case
jne  divide_loop
  ; value == 0 → single '0' digit
  mov  al, 0x30
  mov  [rsp], al
  mov  rdi, rsp
  mov  rsi, 1
  call sys_debug_puts
  add  rsp, 24
  ret

divide_loop:
  mov  r9,  rdi                 ; r9  = remaining value
  mov  r10, rsp
  add  r10, 19                  ; r10 = cursor at last staging byte (rightmost)

loop_top:
  mov  rax, r9
  mov  rcx, 10
  xor  rdx, rdx                 ; zero-extend rdx:rax for div
  div  rcx                      ; rax = quotient, rdx = remainder (0..9)
  add  rdx, 0x30                ; ASCII '0'..'9'
  mov  [r10], dl                ; store digit at cursor
  mov  r9, rax                  ; r9 = quotient
  cmp  r9, 0
  je   loop_done
  sub  r10, 1                   ; advance cursor left
  jmp  loop_top

loop_done:
  ; r10 points at first (most-significant) digit
  ; length = (rsp + 20) - r10
  mov  rax, rsp
  add  rax, 20
  sub  rax, r10                 ; rax = digit count
  mov  rsi, rax                 ; sys_debug_puts arg 2 (count)
  mov  rdi, r10                 ; sys_debug_puts arg 1 (buf)
  call sys_debug_puts
  add  rsp, 24
  ret
```

Key mechanics:

- Cursor advance is **inside** the loop and **after** the store, so the final store on the last-quotient iteration doesn't over-advance. Compare against kernel `u64_to_dec`'s post-loop `add r10, 1` correction (hex.pdx:123) — that version advances *before* checking zero and needs the fixup; we advance *after*, so no fixup needed.
- `div rcx` is the same instruction the kernel's `u64_to_dec` uses successfully at boot (kernel_main.pdx:167) so paideia-as codegen is known-good for this pattern in a nested-fn context.
- Buffer pointer passed to `sys_debug_puts` is stack-resident; the kernel reads it through the KPTI-safe `sys_debug_puts` path so no user-CR3 walk quirk applies.

### 2.4 Test vector table (validated on paper before codegen)

| Input      | Iterations | Cursor start → end | Length | Digits (LSB→MSB in staging, MSB→LSB on wire) |
|------------|------------|--------------------|--------|-----------------------------------------------|
| 0          | 0 (special)| n/a                | 1      | `"0"`                                         |
| 1          | 1          | rsp+19 → rsp+19    | 1      | `"1"`                                         |
| 9          | 1          | rsp+19 → rsp+19    | 1      | `"9"`                                         |
| 10         | 2          | rsp+19 → rsp+18    | 2      | `"10"` (staging: '0'@19, '1'@18)              |
| 42         | 2          | rsp+19 → rsp+18    | 2      | `"42"`                                        |
| 100        | 3          | rsp+19 → rsp+17    | 3      | `"100"`                                       |
| 999        | 3          | rsp+19 → rsp+17    | 3      | `"999"`                                       |
| 4294967295 | 10         | rsp+19 → rsp+10    | 10     | `"4294967295"` (u32::MAX)                     |

All fit within the 20-byte staging (u64::MAX = "18446744073709551615" is exactly 20 digits).

### 2.5 New `init_parent` emission sequence

```
init_parent:
  ; sys_wait4(-1, &wait_status, 0, NULL)
  xor  rdi, rdi
  dec  rdi
  lea  rsi, [rip + wait_status]
  xor  rdx, rdx
  xor  rcx, rcx
  call sys_wait4
  cmp  rax, 0
  jl   init_shutdown

  ; Save child pid in r13 (callee-save across sys_debug_puts + print_u64_dec)
  mov  r13, rax

  ; "WAIT: pid="
  lea  rdi, [rip + wait_prefix]
  mov  rsi, 10
  call sys_debug_puts

  ; child pid as decimal
  mov  rdi, r13
  call print_u64_dec

  ; " status="
  lea  rdi, [rip + wait_sep]
  mov  rsi, 8
  call sys_debug_puts

  ; wait_status[0] as decimal
  lea  rdi, [rip + wait_status]
  mov  rdi, [rdi]
  call print_u64_dec

  ; "\n"
  lea  rdi, [rip + wait_newline]
  mov  rsi, 1
  call sys_debug_puts

  ; existing "REAPED\n" + shutdown
  lea  rdi, [rip + reaped_msg]
  mov  rsi, 7
  call sys_debug_puts
  jmp  init_shutdown
```

`r13` is chosen because it is (a) callee-save under SysV, so preserved across the `sys_debug_puts` and `print_u64_dec` calls that intervene between saving and using it, and (b) not touched anywhere else in `_start`. `wait_status[0]` is re-loaded from memory rather than saved in another callee-save — the memory location is stable and this halves the state we carry.

---

## 3. Fingerprint update strategy

The old fingerprint line was `WAIT: pid=2 status=42` — both digits were **rodata compile-time constants**, so the smoke passed regardless of the values actually flowing through `sys_wait4`. Post-D12 the printed digits *are* the runtime values (`rax` from `sys_wait4`; `wait_status[0]` from memory), and the fingerprint must match what those code paths currently emit.

Empirical observation (from `/tmp/paideia-os-smoke.log` after this landing):

```
WAIT: pid=23 status=0
```

Two things surface that were previously lie-hidden:

1. **`pid=23`** — the reaped child gets pid 23, not pid 2. `pid_alloc`'s dense-low-first scan hands out 23 because the pool has been dirtied by pre-init structural witnesses (task_new / fork smoke fixtures in `kernel_main`). Filed as [#735] (pid-leak). Wire will drop to `pid=2` once #735 lands, which will need a matching one-digit fingerprint update.

2. **`status=0`** — the child (child_hello.pdx) calls `sys_exit(42)`. `sys_exit_body` correctly writes `42` into the parent's slab at offset +1708 (`wait_result_status`), and `dispatch_wait4_writeback` correctly loads `edx=42` on the parent's resume. The `mov [rsi], edx` at `src/kernel/core/syscall/dispatch.pdx:330`, however, runs under **kernel CR3** — and VA `0x700000` (where init's `wait_status : [u64; 1]` sits per the init.ld layout) is covered by the boot PML4's low identity map. So the write lands at physical `0x700000` (kernel's identity view), not at the frame init's own user PML4 maps VA `0x700000` to (a phys_alloc'd .bss page zeroed by the ELF loader). init reads *its own page* under user CR3 and prints the zero it started with.

   Same defect class as #724 D4 (`sys_debug_puts` silent-NUL under kernel CR3), #730 D10c (`dispatch_write_uart` fixed via `user_puts_via_walk`), and #730 D10d (`sys_execve_shim` path copy fixed via `user_read_str_via_walk`). Filed as [#737] with the "user_write_u32_via_walk" mirror-fix outline. Wire will show `status=42` once #737 lands.

Design decision: **land D12 with the fingerprint set to `WAIT: pid=23 status=0`** — the honest observation of what the wire currently produces post-D12. Do not paper over the discovered bugs by keeping the old lie-fingerprint or by widening D12 to swallow the #737 fix.

The fingerprint file `tests/r17/expected-boot-r17-init.txt` cannot carry inline comments (it's a strict line-by-line pattern match — see `tools/run-smoke.sh:243-259`). The trail lives in this design doc + in the two GitHub issues (#735, #737) whose closure will each trigger a matching fingerprint update:

| Issue | When it lands, update fingerprint to  |
|-------|---------------------------------------|
| #735  | `WAIT: pid=2 status=0` (pid restored, status still bugged) |
| #737  | `WAIT: pid=23 status=42` (status restored, pid still bugged) |
| both  | `WAIT: pid=2 status=42` (matches #723's original AC intent) |

[#735]: https://github.com/paideia-os/paideia-os/issues/735
[#737]: https://github.com/paideia-os/paideia-os/issues/737

---

## 4. Verify-script update

`tools/verify-user-init.sh` currently greps the disassembly for the `wait_msg` symbol as a proxy for "AC rodata is present". Post-D12 that symbol is gone; the check migrates to `wait_prefix` — the new anchor symbol that only exists post-D12 and whose presence is the exact structural signal we want (the split-fragment rewrite completed).

No `print_u64_dec` byte-pattern check is added at this landing. The smoke fingerprint (`WAIT: pid=2 status=42`) is a stronger end-to-end assertion than a byte-shape canary — a `div rcx` regression, an off-by-one in the cursor, a botched digit-store: any of those would break the line and fail the fingerprint. A per-symbol canary would double-count without adding coverage.

---

## 5. Bounded risks / follow-ups

- **Effect declarations.** `_start`'s current declaration is `!{sysreg} @{fs}`, missing the `mem` effect that its `sys_fork`/`sys_execve`/`sys_wait4` calls declare. paideia-as's effect checker is lenient enough at R17.M0 for this to have built; adding `print_u64_dec` (which needs `!{mem, sysreg} @{}`) does not tighten the checker, so `_start`'s declaration is left as-is. A separate cleanup pass on user-side effect declarations is a candidate for R17.M4 hygiene.
- **Zero special case.** The branch to the zero-print short path returns *without* falling through into the divide loop; a stray edit that removes the `ret` at the end of the zero branch would silently print an extra digit. Belt-and-suspenders: the branch is labeled and the `ret` is on its own line.
- **Two `mov rdi, [rdi]` on wait_status.** The load-then-dereference sequence is not idiomatic in most paideia-as user code but is used at src/user/dispatch.pdx:243–244 (argc access). Keeping the pattern local rather than defining a `u64_load` helper.
- **paideia-as codegen sensitivity.** kernel_main.pdx §M0-001 documents `#1270` (cmp+jne after mov-reg-pair in top-level-fn context miscompiles). `print_u64_dec` is not a top-level function; it's a `pub let` in `Init`. The same `cmp/jne` pattern is used successfully in `Init._start` today so this class of miscompile is not expected to bite here. If it does, the fallback is `sub`+`jnz` on a temporary (the same workaround kernel_main uses for its own dec-fixture compares).
