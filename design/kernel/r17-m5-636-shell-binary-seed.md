# R17-M5-636 partial: /bin/sh tmpfs seed (Option A)

**Status:** landing — first partial of #636
**Issue:** paideia-os #636 (`r17-m5-002-echo-hello-golden`)
**Milestone:** `r17-m5` (Shell integration test harness)
**Depends on:** #730 D10a (`/bin/child_hello` tmpfs seed template), #520/#519 (shell.elf embed via `_shell_bin_start`/`_shell_bin_end`), #560 (child_hello embed template), #587 (vnode-pool slot wiring)
**AC target (from #636):** `tests/r17/shell-echo-hello.golden` = full transcript from cold-boot → `$ ` prompt → `echo hello` → `hello` → `$ ` → `exit`.

This landing does NOT close #636's AC on its own. #636 is a 7-prereq chain (see §2) that must land in bounded partials so the working AC of #723 (`CHILD HELLO 42\nWAIT: pid=2 status=42\nREAPED`) is preserved at each step. This partial lands prereq #2 (the `/bin/sh` tmpfs seed) and files sub-issues for the remaining prereqs.

---

## 1. Wire evidence pre-fix

At head of `main` before this landing, `tools/run-smoke.sh boot_r17_init` prints (tail):

```
R15 CHILD HELLO EMBED OK
R17 BIN CHILD HELLO SEED OK
INIT BOOT OK
INIT ENTERED RING3
INIT OK
CHILD HELLO 42
WAIT: pid=2 status=42
REAPED
```

`shell.elf` is built by `tools/build-user.sh` (composes `shell.pdx` + `dispatch.pdx` + `builtins.pdx` + `io.pdx` + `string.pdx` + `errno.pdx` + `syscall_shim.pdx` + `tokenizer.pdx`) and embedded in the kernel via `tools/userbin_embed.S` at `_shell_bin_start`.._shell_bin_end`. But it exists **only as a rodata blob** — it is never seeded into tmpfs, so `execve("/bin/sh")` from init would return `-ENOENT`.

If init tried to fork+exec `/bin/sh` today it would fall through to `init_error`, just as init used to do before D10a landed `/bin/child_hello`. The shell binary is unreachable at runtime.

---

## 2. The 7-prereq chain for #636's AC

The debugger's prior notes broke #636 down into these prereqs:

| # | Prereq | Status | This landing |
|---|--------|--------|--------------|
| 1 | Shell binary built as ELF via `build-user.sh` | landed (R17.M3 + M4) | — |
| 2 | Shell binary seeded into tmpfs at `/bin/sh` | **this landing** | in scope |
| 3 | tty stdin bridge (`_uart_rx_ring` → `_tty_line_buf`) | not landed | filed as sub-issue |
| 4 | init.pdx path — either exec /bin/sh directly OR fork both /bin/child_hello + /bin/sh OR new smoke mode with shell-init | not landed | filed as sub-issue |
| 5 | QEMU input injection wired for the shell smoke mode | not landed | filed as sub-issue |
| 6 | Golden file `tests/r17/shell-echo-hello.golden` | not landed | filed as sub-issue |
| 7 | New smoke mode `boot_r17_shell_echo_hello` in `tools/run-smoke.sh` | not landed | filed as sub-issue |

Why Option A (this landing) is bounded:
- Reuses the exact D10a pattern (bin_child_hello_seed) — mirror discipline.
- No behavior change to boot flow: init still forks /bin/child_hello (AC preservation).
- No changes to init.pdx, tty layer, sched, UART, or QEMU driver.
- Adds one witness marker (`R17 BIN SH SEED OK`) inserted in fingerprints between the existing bin_child_hello_seed marker and INIT BOOT OK.

Why NOT Option B (stdin bridge) as the first partial:
- The bridge changes tty_read discipline (adds a drain-then-process step); needs its own design analysis (where the drain runs: post-wake in tty_read, or a bottom-half). Bounded, but architecturally larger than a seed clone.
- Without the shell binary in tmpfs, the bridge cannot be end-to-end verified against a real shell — only a synthetic witness. Testing the bridge with a real shell requires prereq #2 landed first.

Why NOT Option C (all seven at once): well-known scope-creep failure mode; prior D10 landings established that each execve-path step warrants its own partial and design doc so failure modes stay localised.

---

## 3. Landing summary

Two touched surfaces:

| Surface | Change |
|---------|--------|
| `src/kernel/boot/kernel_main.pdx` | new `bin_sh_seed` block immediately after `bin_child_hello_seed_done`. Mirrors D10a's 7-step recipe but calls `tmpfs_lookup(1, "bin")` to reuse the /bin dir that D10a just created. |
| `tools/boot_stub.S` + `src/kernel/boot_panic/boot_stub_panic.S` + `src/kernel/boot_exc3/boot_stub_exc3.S` | three new .ascii labels: `sh_seed_name` (= `"sh\0"`), `bin_sh_seed_ok_msg` (= `"R17 BIN SH SEED OK\n\0"`), `bin_sh_seed_fail_msg` (= `"R17 BIN SH SEED FAIL\n\0"`). All three stub variants get the labels so panic/exc3 builds link cleanly. |
| `tests/r17/expected-boot-r17-init.txt` | insert `R17 BIN SH SEED OK` line between `R17 BIN CHILD HELLO SEED OK` and `INIT BOOT OK`. |
| `tests/r16/expected-boot-r16-uart-rx.txt` | same insertion — this fingerprint checks the full boot tail. |

---

## 4. bin_sh_seed — recipe

### 4.1 Preconditions guaranteed at entry

D10a (`bin_child_hello_seed`) has completed, therefore at the point we start:
- tmpfs root vnode's `ops_ptr` = `&_tmpfs_vops`, `backend_ptr` = 1 (root inode idx).
- Inode idx 1 = `/` (DIR, first_child = /tmp).
- `/bin` exists as a DIR inode under root, with `child_hello` as its only child.
- The /bin vnode-pool slot is already wired (D10a step 3) to `&_tmpfs_vops` with `backend_ptr` = bin_inode_idx.
- `_shell_bin_start` / `_shell_bin_end` bracket the shell.elf blob (verified by loader structural witness at line 7677 and by the R15-M1-008b runtime `ELF LOAD OK` witness at line 7688).

### 4.2 The seed sequence

```
bin_sh_seed:
    # ---- Step 1: recover /bin's inode idx via tmpfs_lookup ----
    mov  rdi, 1                          # root_inode_idx
    lea  rsi, [rip + bin_seed_name]      # "bin\0" (reuse D10a's rodata)
    call tmpfs_lookup                    # rax = bin_idx or 0 on miss
    cmp  rax, 0
    je   bin_sh_seed_fail
    mov  r13, rax                        # r13 = bin_idx

    # ---- Step 2: tmpfs_create(bin, "sh", 2, REG=1) ----
    mov  rdi, r13
    lea  rsi, [rip + sh_seed_name]       # "sh\0"
    mov  rdx, 2                          # name_len
    mov  rcx, 1                          # VNODE_TYPE_REG
    call tmpfs_create                    # rax = sh_inode_idx | 0 | 0xFFFF
    cmp  rax, 0
    je   bin_sh_seed_fail
    mov  rcx, 0xFFFF
    cmp  rax, rcx
    je   bin_sh_seed_fail                # TMPFS_INODE_ALLOC_OOM
    mov  r14, rax                        # r14 = sh_inode_idx

    # ---- Step 3: wire /bin/sh vnode-pool slot ----
    mov  rdi, r14
    call vnode_slot                      # rax = &vnode[sh_idx]
    lea  rcx, [rip + _tmpfs_vops]
    mov  [rax + 24], rcx                 # ops_ptr = &_tmpfs_vops
    mov  rcx, r14
    mov  [rax + 32], rcx                 # backend_ptr = sh_inode_idx

    # ---- Step 4: compute image base + length ----
    lea  r15, [rip + _shell_bin_start]
    lea  rax, [rip + _shell_bin_end]
    sub  rax, r15                        # rax = image_len
    mov  r12, rax                        # r12 = image_len (~9856 bytes at R17.M5)
    xor  r13, r13                        # r13 = offset = 0

    # ---- Step 5: write in single-page (≤4096-byte) chunks ----
bin_sh_seed_write_loop:
    cmp  r13, r12
    jae  bin_sh_seed_write_done          # offset >= image_len

    mov  rax, r12
    sub  rax, r13                        # rax = remaining
    mov  rcx, 4096
    cmp  rax, rcx
    jbe  bin_sh_seed_chunk_ok
    mov  rax, rcx                        # clamp to 4096
bin_sh_seed_chunk_ok:

    mov  rdi, r14                        # arg0 = sh_inode_idx
    mov  rsi, r15
    add  rsi, r13                        # arg1 = image_base + offset
    mov  rdx, rax                        # arg2 = chunk_len
    mov  rcx, r13                        # arg3 = offset
    call tmpfs_write                     # rax = bytes_written or sentinel

    mov  rcx, 0xFFFFFFFFFFFFFFFF
    cmp  rax, rcx
    je   bin_sh_seed_fail

    add  r13, rax                        # offset += bytes_written
    jmp  bin_sh_seed_write_loop

bin_sh_seed_write_done:
    mov  rdi, 3
    lea  rsi, [rip + SUBSYS_BOOT]
    lea  rdx, [rip + bin_sh_seed_ok_msg]
    call klog_s1
    jmp  bin_sh_seed_done

bin_sh_seed_fail:
    mov  rdi, 1                          # LEVEL_ERROR
    lea  rsi, [rip + SUBSYS_BOOT]
    lea  rdx, [rip + bin_sh_seed_fail_msg]
    call klog_s1

bin_sh_seed_done:
```

### 4.3 Register plan

| Reg | Role | Lifetime |
|-----|------|----------|
| r13 | bin_idx (steps 1-2); later repurposed to `offset` (steps 5+) | steps 1-2, then reset at step 4 |
| r14 | sh_inode_idx | steps 2-5 |
| r15 | _shell_bin_start (image base) | steps 4-5 |
| r12 | image_len | steps 4-5 |

Matches the D10a register plan (r12/r13/r14/r15) so `sh` and `child_hello` share encoder discipline. No new encoder idioms; every mnemonic used has landed precedent (RIP-relative load/store, cmp reg,imm8, mov reg,reg, call/ret, je/jne/jmp, sub reg,reg, add reg,reg).

### 4.4 Failure semantics

Any failure of `tmpfs_lookup`, `tmpfs_create`, or `tmpfs_write` results in `bin_sh_seed_fail` being taken, which emits `R17 BIN SH SEED FAIL` at LEVEL_ERROR and falls through to `bin_sh_seed_done`. Boot continues. init still forks /bin/child_hello (AC preservation); a failed seed here does not break the existing AC because init does not reference /bin/sh in this partial.

The follow-up sub-issue for prereq #4 (init exec /bin/sh) will need to gate on `_bin_sh_seed_ok` (or equivalent) if it wants to fail gracefully — that's out of scope for this partial.

### 4.5 Size envelope

Current shell.elf: **9856 bytes** = 3 × 4-KiB pages (chunks 0-4095, 4096-8191, 8192-9855). Well under tmpfs' 64-KiB per-file cap (write.pdx §4.4). Growth budget: **~55 KiB** before hitting the cap. If shell.elf ever exceeds 64 KiB, we backtrack by relaxing the tmpfs per-file cap (see write.pdx §4.4 comment).

The `tmpfs_write` primitive's single-page constraint (write.pdx §4.5, `start_page == end_page`) is honored by construction: each write starts at a page-aligned offset (0, 4096, 8192, ...) and is at most 4096 bytes, so `last_byte_offset = offset + chunk_len - 1` never crosses into the next page.

---

## 5. AC preservation matrix

The 20 smoke modes and how each interacts with the new seed marker:

| Mode | Fingerprint file | New marker seen? | Fingerprint update needed? |
|------|------------------|------------------|----------------------------|
| boot_min | expected-boot-min.txt | no (boot exits before this stage) | no |
| boot_banner | expected-boot-banner.txt | no | no |
| boot_tick | expected-boot-tick.txt | no | no |
| boot_r8_only | expected-r8-only.txt | no | no |
| boot_r10 | expected-boot-r10.txt | no | no |
| boot_r11 | expected-boot-r11.txt | no | no |
| boot_r12 | expected-boot-r12.txt | no | no |
| boot_r12_denial | expected-boot-r12-denial.txt | no | no |
| boot_r14b_* (5 modes) | expected-boot-r14b-*.txt | no (boot ends before tmpfs seeding) | no |
| boot_r15_ring3 | expected-boot-r15-ring3.txt | no (78 lines, ends before bin_sh_seed) | no |
| boot_r15_process | expected-boot-r15-process.txt | no (same) | no |
| boot_r16_uart_rx | expected-boot-r16-uart-rx.txt | yes | **yes** |
| boot_r17_init | expected-boot-r17-init.txt | yes | **yes** |
| boot_panic | expected-panic-dump.txt | no | no |
| boot_panic_halt | expected-panic-halt.txt | no | no |
| boot_exc3 | expected-exc3.txt | no | no |

The fingerprint check is contains-in-order (`tools/run-smoke.sh` §226+): each expected line must appear after the previous one. Adding a new wire line between two existing ones (which are already both in the log AND in the fingerprint) is safe on the log side; the fingerprint file just needs the new line inserted at the correct index so the ordered scan still matches.

The kernel_main insertion point is between `bin_child_hello_seed_done` and `uart_rx_wire_witness`, which places `R17 BIN SH SEED OK` on the wire between `R17 BIN CHILD HELLO SEED OK` and `UART RX: abc` (in the r16_uart_rx run) or between `R17 BIN CHILD HELLO SEED OK` and `INIT BOOT OK` (in the r17_init run).

---

## 6. Follow-up sub-issues to file

To be filed after this partial lands (numbered against #636's chain in §2):

- **Prereq #3**: tty stdin bridge — drain `_uart_rx_ring` and feed `tty_process_input` inside `tty_read`'s post-wake path (or as a bottom half). Must land a boot-time witness that shows a byte injected via uart_rx_enqueue reaches `_tty_line_buf` after `tty_read` returns.
- **Prereq #4**: init.pdx path choice — file with three sub-options (a) init execs /bin/sh directly (breaks #723 AC → needs a matching test-mode split); (b) init forks both /bin/child_hello and /bin/sh (AC coexists); (c) a new smoke build with a shell-focused init that only forks /bin/sh. Recommend (c) so #723 AC continues on boot_r17_init.
- **Prereq #5**: QEMU input injection wired for the shell smoke — reuse #666's chardev pipe pattern.
- **Prereq #6**: golden file `tests/r17/shell-echo-hello.golden` (byte-identical transcript).
- **Prereq #7**: new smoke mode `boot_r17_shell_echo_hello` in `tools/run-smoke.sh`.

---

## 7. What could go wrong (adversarial self-check)

1. **`tmpfs_lookup` returns 0** — the /bin dir doesn't exist. Would mean D10a failed silently (the seed_fail marker would have printed instead of `R17 BIN CHILD HELLO SEED OK`). If seed_ok printed, /bin must exist. Guard: fail → emit `R17 BIN SH SEED FAIL`, keep booting.
2. **`tmpfs_create` returns 0xFFFF** — inode pool exhausted. Pool is 64 slots (`tmpfs/inode.pdx`). Boot uses inodes 1 (root), 2 (/tmp), 3 (/bin from D10a), 4 (/bin/child_hello from D10a); this seed uses 5 (/bin/sh). Plenty of headroom.
3. **`tmpfs_write` returns sentinel** — could mean OOM in `phys_alloc`. phys_alloc bitmap is verified sound at boot; unlikely at this early stage where only a handful of pages have been allocated (init aspace + /bin/child_hello's 2 pages). Would fail-fast to `bin_sh_seed_fail`.
4. **Cross-page write** — impossible by construction. Chunks are `min(4096, remaining)` and offsets are page-aligned by induction from offset=0.
5. **Wire ordering** — kernel_main is single-threaded at this point; `R17 BIN SH SEED OK` will always appear after `R17 BIN CHILD HELLO SEED OK` and before `UART RX: abc` / `INIT BOOT OK`. Fingerprint update matches.
6. **Reserved label collision** — `sh_seed_name` is a plain identifier; `sh` is not a paideia-as reserved keyword. `bin_sh_seed_*` labels are prefixed per the memory note. No conflict.

---

## 8. What this does NOT prove

- `execve("/bin/sh")` from init doesn't run yet — init still execs `/bin/child_hello`. To wire up shell exec, prereq #4 needs to land (with the design choice of not breaking #723 AC).
- shell.elf's runtime correctness under real execve is proven only at the loader-structural level (elf_lite_load OK for it, via the #648 witness) at boot time; runtime end-to-end (fork+exec+wait against the shell) awaits prereq #4.
- stdin bytes still do not flow into `_tty_line_buf`. Prereq #3 owns that.

---

## 9. Rollback plan

If this landing surfaces an unexpected regression:
- The `bin_sh_seed` block is self-contained between labels `bin_sh_seed:` and `bin_sh_seed_done:`. Delete those ~40 lines + revert the 3 .ascii additions + revert the 2 fingerprint updates.
- No effect on any other subsystem — the seed only creates one tmpfs inode + writes ~10 KiB of bytes.

