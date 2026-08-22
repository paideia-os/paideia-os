#!/usr/bin/env bash
# Phase-1 smoke regression: builds the kernel, runs under QEMU with a
# configurable timeout, captures serial output, and asserts deterministic
# bytes.
#
# Usage: tools/run-smoke.sh [MODE | expected_marker | --fingerprint PATTERN]
#   - MODE: one of 'boot_min', 'boot_banner', 'boot_tick', 'boot_r8_only', 'boot_r10', 'boot_r11', 'boot_r12', 'boot_r12_denial', 'boot_r14b_hivma', 'boot_r14b_kpti', 'boot_r14b_ipi', 'boot_r14b_loader', 'boot_r14b_ud', 'boot_r15_ring3', 'boot_r15_process', 'boot_r16_uart_rx', 'boot_r17_init', 'boot_r17_shell_echo_hello', 'boot_r17_shell_multi_command', 'boot_r17_shell_child_process', 'boot_r17_shell_shutdown', 'boot_smp', 'boot_r31_spawn_pair', 'boot_panic', 'boot_release', 'prod' (mode dispatcher)
#     * boot_min: validates boot_min fingerprint, 5s timeout
#     * boot_banner: validates boot_banner fingerprint, 5s timeout
#     * boot_tick: validates boot_tick fingerprint (with timer TICKs), 5s timeout
#     * boot_r8_only: validates R8-only fingerprint (no timer, no IDT), 5s timeout
#     * boot_r10: validates R10 task alternation fingerprint (Task A/B cooperative yield), 10s timeout
#     * boot_r11: validates R11 softer task alternation fingerprint (Task A/B/A cooperative), 10s timeout
#     * boot_r12: validates R12 capability dispatch fingerprint (5 cap tags + 3 task lines), 8s timeout
#     * boot_r12_denial: validates R12 rights-denial witness (CAP DENIED between CAP INVOKE DEV and CAP DISPATCH OK), 8s timeout
#     * boot_r14b_hivma: validates R14B higher-half execution witness (HI VA FFFF8000), 5s timeout
#     * boot_r14b_kpti: validates R14B KPTI structural witness (KPTI OK), 5s timeout
#     * boot_r14b_ipi: validates R14B IPI structural witness (IPI OK), 5s timeout
#     * boot_r14b_loader: validates R14B LOADER witness, 8s timeout
#     * boot_r14b_ud: validates R14B undefined-instruction witness, 6s timeout
#     * boot_r15_ring3: validates R15 ring-3 + fd_table + single-task witness, 6s timeout
#     * boot_r15_process: validates R15 3-task pool witness with pids=1,2,3, 6s timeout
#     * boot_r16_uart_rx: validates R16.M4-666 real-IRQ UART RX end-to-end smoke, 10s timeout, injects 'abc' via QEMU chardev pipe
#     * boot_r17_init: validates R17 init load structural witness (task_new + elf_lite_load), 8s timeout
#     * boot_r17_shell_echo_hello: injects 'echo hello\nexit\n' after SHELL START, asserts echo + shell-reap chain, 12s timeout (R17.M5 #636/#751/#752)
#     * boot_r17_shell_multi_command: injects 'pwd\ncd /tmp\npwd\nhelp\nexit\n', asserts /tmp + help output + REAPED (R17.M5 #637)
#     * boot_r17_shell_child_process: injects 'true\nexit\n', asserts TRUE OK from /bin/true + shell-reap chain (R17.M5 #638)
#     * boot_r17_shell_shutdown: injects 'exit\n', asserts shell exit + init reap + init shutdown (R17.M5 #639)
#     * boot_smp: validates R18.M1 SMP bring-up fingerprint on -smp 4; BSP wakes 3 APs (APIC IDs 1/2/3), each emits CPU_ID_XX_HELLO; bookended by SMP BRINGUP START / DONE (R18.M1 #764)
#     * boot_panic: validates M3-003 fake-panic emission chain witness, 8s timeout
#     * prod: expects exit code 2 (kernel didn't build), skips verification
#   - expected_marker: defaults to no-check (just confirms QEMU exits or
#     times out cleanly). Pass a string to grep the serial log for.
#   - --fingerprint PATTERN: validate serial output against tests/r8/expected-PATTERN.txt
#     file; checks that all lines from the fingerprint file appear in order in the log
#     (contains-in-order check, not strict equality).
#
# Exit codes:
#   0  — kernel built + booted + (optional) expected marker found
#   1  — kernel built but smoke failed (no marker / unexpected QEMU exit)
#   2  — kernel didn't build
#  33  — kernel graceful clean exit (isa-debug-exit byte 0x10 → QEMU exits (0x10 << 1) | 1 = 33)
#  35  — kernel failed exit (isa-debug-exit byte 0x11 → QEMU exits (0x11 << 1) | 1 = 35)
#  77  — QEMU not installed (test skipped)
# 124  — smoke timeout (5s runner timeout)
# 137  — kernel killed (OOM / other fatal signal)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
EXPECTED="${1:-}"
FINGERPRINT_MODE=0
FINGERPRINT_FILE=""
TIMEOUT=5
UART_RX_MODE=0
# R18-M1 #764: boot_smp knobs.
#   SMP_MODE               — enable multicore QEMU launch (`-smp N`).
#   SMP_CPU_COUNT          — how many CPUs QEMU exposes (BSP + APs).
#                            Kernel's AP list is hard-coded to 3 APs
#                            (ap_list.pdx), so 4 (= BSP + 3 APs) is the
#                            R18.M1 default. Raising it needs the AP list
#                            + N_APS to grow in lockstep (R20-M2 MADT
#                            work).
#   SMP_UNORDERED_HELLO    — treat CPU_ID_XX_HELLO fingerprint lines as
#                            presence-only (no cross-AP ordering).
#                            The BSP START / DONE bookends stay ordered.
SMP_MODE=0
SMP_CPU_COUNT=1
SMP_UNORDERED_HELLO=0
# R21-M2 #832: QEMU_CPU knob for smoke modes that need CPUID feature bits
# beyond qemu64-default (e.g. XSAVE, AVX2 for boot_r21_ymm_preserve).
# Empty (default): no `-cpu` flag → qemu64 default. Set to "max" for the
# widest advertised feature surface — enables XSAVE, AVX2, POPCNT, etc.
QEMU_CPU=""
# #750 + #757: chardev-pipe injection knobs.
#
# Precedence:  caller env  >  mode-branch default  >  global fallback
#
# The case dispatcher below may set mode-specific defaults via
# `: "${VAR:=...}"` — those fire only when the caller did NOT export
# the var (or exported it empty). After the dispatcher, the "Global
# injection defaults" block fills in any remaining unset knobs with
# the historical boot_r16_uart_rx values, keeping that mode byte-for-
# byte unchanged.
#
# Knobs:
#   INJECT_STRING         — bytes to write into FIFO_IN. `printf %b`
#                           interprets escape sequences (`\n`, `\t`).
#   INJECT_DELAY          — seconds to sleep after WAIT_FOR (or on
#                           subshell entry if WAIT_FOR is empty).
#   INJECT_HOLD           — seconds to keep FIFO_IN open after writes
#                           complete, so QEMU's 16550 read side does
#                           not EOF mid-boot.
#   INJECT_WAIT_FOR       — #757: optional pattern; if set, the writer
#                           polls the serial log for this string
#                           before injecting, replacing the blind
#                           sleep-then-write timing. Closes the race
#                           where injection lands before the guest
#                           reaches the readiness state the injection
#                           is meant to exercise (observed ~5/6 failure
#                           rate on shell interactivity when bytes
#                           were written at t≈1s but the shell did not
#                           reach the read window until t≈4-5s, and
#                           earlier tty sub-tests consumed the bytes
#                           silently).
#   INJECT_WAIT_TIMEOUT   — max integer seconds to wait for
#                           INJECT_WAIT_FOR before falling through and
#                           injecting anyway (default 8).
#   INJECT_RETRIES        — number of times to write INJECT_STRING
#                           (default 1). >1 re-injects with
#                           INJECT_RETRY_INTERVAL between attempts;
#                           useful when a single write may not overlap
#                           the guest's read window.
#   INJECT_RETRY_INTERVAL — seconds between retry writes (default 0.5).
#
# `set -u` is on above; the `${VAR-}` form (no colon) is a
# safe-read that yields empty if unset, without triggering an
# unbound-variable error. Do NOT change to `${VAR}` here.
INJECT_STRING="${INJECT_STRING-}"
INJECT_DELAY="${INJECT_DELAY-}"
INJECT_HOLD="${INJECT_HOLD-}"
INJECT_WAIT_FOR="${INJECT_WAIT_FOR-}"
INJECT_WAIT_TIMEOUT="${INJECT_WAIT_TIMEOUT-}"
INJECT_RETRIES="${INJECT_RETRIES-}"
INJECT_RETRY_INTERVAL="${INJECT_RETRY_INTERVAL-}"

# Mode dispatcher: map boot_min/boot_banner/boot_tick/boot_r8_only/boot_r10/boot_r11/prod to fingerprint + timeout
case "${EXPECTED}" in
    boot_min)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-boot-min.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_banner)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-boot-banner.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_tick)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r9/expected-boot-tick.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r8_only)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r9/expected-r8-only.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r10)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r10/expected-boot-r10.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r11)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r11/expected-boot-r11.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r12)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r12/expected-boot-r12.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r12_denial)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r12/expected-boot-r12-denial.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r14b_hivma)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-hivma.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r14b_kpti)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-kpti.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r14b_ipi)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-ipi.txt"
        TIMEOUT=5
        EXPECTED=""
        ;;
    boot_r14b_loader)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-loader.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r14b_ud)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r14b/expected-boot-r14b-ud.txt"
        TIMEOUT=6
        EXPECTED=""
        ;;
    boot_r15_ring3)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r15/expected-boot-r15-ring3.txt"
        TIMEOUT=6
        EXPECTED=""
        ;;
    boot_r15_process)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r15/expected-boot-r15-process.txt"
        TIMEOUT=6
        EXPECTED=""
        ;;
    boot_r16_uart_rx)
        # R16.M4-666 (#666): real IRQ-driven end-to-end UART RX smoke.
        # Kernel witness (kernel_main.pdx: uart_rx_wire_witness) `sti`s
        # briefly before lapic_timer_init, polls _uart_rx_ring for 3 bytes,
        # then emits "UART RX: abc\n" via uart_puts. Fingerprint requires
        # this second "UART RX: abc" line AFTER the #601 structural one.
        # QEMU serial is bridged through a named-pipe chardev so the smoke
        # driver can inject 'abc' after kernel boot has ERBFI armed.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r16/expected-boot-r16-uart-rx.txt"
        TIMEOUT=10
        UART_RX_MODE=1
        EXPECTED=""
        ;;
    boot_r17_init)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/expected-boot-r17-init.txt"
        # paideia-os #747: TIMEOUT reverted 20 → 8. Root cause of the flake
        # (uart_rx_wire_witness cycle-count-bound 200M-iteration busy-wait
        # scaling with host CPU contention) fixed in kernel_main.pdx by
        # replacing the countdown with an rdtsc-referenced ~2 s wall-clock
        # budget. See kernel_main.pdx uart_rx_wire_witness comment block
        # and paideia-os commit that pairs with this revert. The temporary
        # workaround landed at ce3a17f; this revert closes the loop.
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r17_shell_echo_hello)
        # R17.M5 #636 / #751 / #752 (formerly `boot_r17_shell_interactive`
        # from #757): end-to-end shell interactivity smoke. Reuses the
        # boot_r17_init kernel (init forks child_hello then execs /bin/sh
        # from tmpfs seed). Injects `echo hello\nexit\n` via the chardev-
        # pipe path after the shell prints "SHELL START" (INJECT_WAIT_FOR
        # anchors on the shell-entry witness so injection cannot race the
        # earlier tty stdin bridge sub-test into consuming the bytes).
        # Fingerprint asserts the shell interactivity chain: SHELL START,
        # then the echo builtin's "hello" output, then init's second
        # wait4 reaping the shell (REAPED).
        #
        # Rename note: the R14B tactical plan (§Subsystem 20) names the
        # mode + golden per this R17.M5 form. The #757-era name
        # `boot_r17_shell_interactive` was a provisional placeholder that
        # predated the batched R17.M5 landing; it is renamed here so the
        # smoke inventory matches the design doc verbatim. The kernel
        # #758 fix (idle sti+hlt loop, landed pre-#757 close) makes the
        # chain deterministic (5/5 in the sandbox).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-echo-hello.golden"
        TIMEOUT=12
        UART_RX_MODE=1
        # Defaults chosen for interactivity workload. Env overrides
        # (INJECT_STRING/DELAY/HOLD/WAIT_FOR) still win: the top-of-
        # file init leaves each knob empty when the caller did not
        # export it, so `${VAR:=default}` fires here for those, and
        # the global-defaults block below preserves boot_r16 behavior
        # for anything not explicitly set here or by the caller.
        : "${INJECT_STRING:=echo hello\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=10}"
        EXPECTED=""
        ;;
    boot_r17_shell_multi_command)
        # R17.M5 #637: multi-command shell smoke. Injects the tactical-
        # plan's exact script `pwd\ncd /tmp\npwd\nhelp\nexit\n`. Golden
        # asserts, in order: SHELL START (shell entry), `/tmp` (from
        # the second `pwd` after cd), the `echo - echo text to stdout`
        # line (a distinctive fragment of `help`'s output that could
        # not appear elsewhere in the boot log), `hello world` (regression
        # for #1016 — space between multi-token echo args), REAPED (init's
        # second wait4 unblocking on the shell exit).
        #
        # INJECT_HOLD is bumped to 14s (vs echo_hello's 10s) so the
        # pipe stays open long enough for the shell to process six
        # sequential lines through the tty stdin bridge; each line
        # requires a full sys_read → dispatch → puts_new round trip.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-multi-command.golden"
        TIMEOUT=17
        UART_RX_MODE=1
        : "${INJECT_STRING:=pwd\ncd /tmp\npwd\nhelp\necho hello world\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=14}"
        EXPECTED=""
        ;;
    boot_r17_shell_child_process)
        # R17.M5 #638: shell fork+execve+wait4 of /bin/true. The shell
        # sees `true`, resolves to /bin/true via resolve_path, forks,
        # execves the trivial user binary (src/user/true.pdx). The
        # binary writes "TRUE OK\n" to fd 1 then sys_exit(0). Shell's
        # wait4 returns; shell reprompts. Then `exit` unblocks init's
        # second wait4.
        #
        # Golden asserts: SHELL START, TRUE OK (proves /bin/true was
        # tmpfs-seeded, path-resolved, ELF-loaded, ran in ring-3, and
        # wrote to shell-inherited stdout), REAPED (init reap of the
        # shell — pid=3, since /bin/true is pid=4 and is reaped by
        # the shell, not init).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-child-process.golden"
        TIMEOUT=15
        UART_RX_MODE=1
        : "${INJECT_STRING:=true\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=12}"
        EXPECTED=""
        ;;
    boot_r17_shell_shutdown)
        # R17.M5 #639: shell shutdown smoke. Injects `exit\n` only —
        # the shortest script that exercises the full clean-shutdown
        # chain. Shell's exit_builtin calls sys_exit(0); init's second
        # wait4 unblocks with pid=3 status=0; init emits `WAIT: pid=3
        # status=0` + `REAPED` + calls sys_exit(0). Kernel drops back
        # to idle (no more runnable tasks). #639's stricter AC —
        # `qemu` exits with ACPI shutdown handshake — is deferred to
        # a later issue that lands the ACPI shutdown path; here we
        # assert the observable init side of the chain.
        #
        # R31.M5-001 (#1106) bumped this from 12s to 15s: the backlight
        # witness adds one more cluster (KIND_BACKLIGHT OK + BACKLIGHT
        # SCALE OK) plus its debug-print pass, which slid the tail of
        # the sequence past the previous 12s bound.
        #
        # R31.M6-#1580 bumped 15s -> 17s: global_lock_witness adds a
        # synthetic-FADT parse + ec_access_bind_arbitration end-to-end
        # exercise before ec_query_witness, and the added instructions
        # push the tail of the sequence far enough that COOLING SCALE OK
        # was landing after the previous 15s window closed on slower
        # runners.
        #
        # R32.M3-001/002 (#1125/#1126) bumped 17s -> 22s: the KIND_HID_
        # DEVICE and KIND_HID_EVENT witnesses each drive twelve stages
        # of mint / revoke / dispatch through cap_mint_write (which
        # emits an audit record per call) and end with a debug_print
        # KV-line pass, and the added instructions push the tail past
        # the previous 17s window on slower runners. The bump keeps the
        # smoke bound proportional to the ADDED work rather than to any
        # unrelated slowdown -- 5 seconds is roughly two witnesses'
        # worth of the same shape the R31.M5 backlight bump measured.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-shutdown.golden"
        TIMEOUT=22
        UART_RX_MODE=1
        : "${INJECT_STRING:=exit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=13}"
        EXPECTED=""
        ;;
    boot_smp)
        # R18-M1-005 (#764): SMP bring-up smoke.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, post
        # lapic_timer_init): BSP emits "SMP BRINGUP START", calls
        # ap_bring_up_all with the hard-coded AP list
        # (_ap_apic_ids = [1,2,3], _ap_count = 3), busy-waits ~333 ms
        # for the last-woken AP to reach _ap_entry's uart_puts, then
        # emits "SMP BRINGUP DONE". Each AP emits `CPU_ID_XX_HELLO`
        # from _ap_entry (src/kernel/core/smp/ap_entry.pdx) with XX =
        # 2-hex APIC ID (01/02/03 on `-smp 4`).
        #
        # QEMU topology: `-smp 4` = BSP (APIC ID 0) + 3 APs. Matches
        # the hard-coded AP list. Growing beyond 4 requires the kernel
        # AP list + N_APS in ap_stacks.pdx to bump together (R20.M2
        # MADT-driven enumeration retires the hard-code).
        #
        # Fingerprint order handling: the BSP bookends
        # (SMP BRINGUP START / DONE) are strictly ordered around the
        # AP hellos. The three CPU_ID_XX_HELLO lines are
        # presence-checked only — Intel MP-init spec allows the APs
        # to leave the wait-for-SIPI state at slightly different
        # times, and COM1 is unlocked (per ap_entry.pdx concurrency
        # note), so their emission order on the wire is not
        # guaranteed. SMP_UNORDERED_HELLO=1 tells the fingerprint
        # checker to skip cross-AP ordering while still enforcing the
        # bookends.
        #
        # NOT wired into pre-push yet (per #764 task discipline).
        # Promotes to gated smoke after 5/5 consecutive passes.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r18/expected-boot-smp.txt"
        TIMEOUT=10
        SMP_MODE=1
        SMP_CPU_COUNT=4
        SMP_UNORDERED_HELLO=1
        EXPECTED=""
        ;;
    boot_r20b_echo)
        # R20b.M5-001 (#1563): echo-server end-to-end closure witness —
        # closes R20b.M5, the R20b round, and the #1015 userspace-server
        # substrate blocker (unblocks #820 acpi_supervisor + #860
        # pci_enumerator + every post-R20 userspace daemon).
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, immediately
        # after loader_seed_witness_done and before sti): unconditional
        # kernel-driven roundtrip against init's user_pml4 exercising ALL
        # M1..M4 primitives end-to-end — svc_register + sys_svc_lookup_body
        # (which internally cap_mint_writes) + sys_ipc_send_body +
        # sys_ipc_recv_body (server drain) + sys_ipc_reply_body (bit-7 flip)
        # + sys_ipc_recv_body (client drain of reply). Byte-exact hdr +
        # payload verify per hop. Emits "R20b ECHO ROUNDTRIP OK\n" on pass.
        #
        # Fingerprint contract (contains-in-order — matches every prior
        # R20b witness marker plus the M5 closure):
        #   R20b BROKER OK          (M1-003)
        #   R20b IPC BOUNCE OK      (M2-003 — M2 close)
        #   R20b SYS IPC RECV OK    (M3-001)
        #   R20b SYS IPC SEND OK    (M3-002)
        #   R20b SVC LOOKUP OK      (M3-003 — M3 close)
        #   R20b INIT CAPS FMT OK   (M4-001)
        #   R20b LOADER SEED OK     (M4-002 — M4 close)
        #   R20b ECHO ROUNDTRIP OK  (M5-001 — R20b + #1015 close)
        # Enforces ordering because M5 depends on M1..M4 having landed
        # cleanly first — a regression in any earlier witness surfaces as
        # a missing-line failure BEFORE the checker gets to the M5 line.
        #
        # Opt-in only (guarded by PAIDEIA_R20B_ECHO=1 in pre-push): the
        # M5 witness spawns a substantial new smoke path (~250 lines of
        # kernel-side orchestration + 4 syscall body calls per hop). The
        # OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired) but only this mode asserts its presence;
        # promotes to the default matrix after 5/5 consecutive passes on
        # the standard R20b round.
        #
        # NOT SMP (echo witness is UP-only at R20b.M5 — the substrate is
        # single-flow per design/ipc/userspace-server-substrate.md §14 Q3).
        # NOT UART-RX (no chardev injection; the roundtrip is entirely
        # kernel-driven with no ring-3 involvement at this milestone).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r20b/expected-echo-roundtrip.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r20b_rpc)
        # R20b.M6-003 (#1566): dual-endpoint RPC roundtrip witness —
        # closes R20b.M6 (substrate hardening; unblocks #820 acpi_supervisor
        # + #860 pci_enumerator as real userspace tasks).
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx §m6_rpc_witness,
        # immediately after m5_echo_witness_done and before sti): the
        # kernel-driven dual-endpoint roundtrip proves the substrate fix
        # documented in design/ipc/userspace-server-substrate.md §4.4
        # (Option A compact variant — flags field of the v1 hdr
        # repurposed as reply_endpoint_id; sys_ipc_reply_body reads it
        # and routes the reply to the client's reply endpoint instead
        # of the server's own endpoint, closing the same-endpoint
        # request/reply race).
        #
        # Fingerprint contract (contains-in-order — narrow slice of the
        # boot_r20b_echo matrix focused on the M6-003 closure):
        #   R20b ECHO ROUNDTRIP OK   (M5-001; anchors ordering)
        #   R20b RPC ROUNDTRIP OK    (M6-003 — R20b.M6 close)
        # Any regression that breaks M6-003 without breaking M5-001
        # surfaces here as the missing RPC line; the M5 line stays as
        # ordering anchor so a broken M5 witness is diagnosed by
        # boot_r20b_echo (the fuller fingerprint) instead.
        #
        # Opt-in only (guarded by PAIDEIA_R20B_RPC=1 in pre-push): the
        # M6-003 witness spawns ~350 lines of kernel-side orchestration
        # (2 endpoint allocs + 8-step client/server round trip + byte-
        # exact verify per hop + 3 endpoint_is_full state assertions).
        # The OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired inside kernel_main) but only this mode
        # asserts its presence; boot_r20b_echo also asserts it as part
        # of the fuller M1..M6 fingerprint. Promotes to the default
        # matrix after 5/5 consecutive passes on the standard R20b round.
        #
        # NOT SMP (UP-only substrate at R20b per §14 Q3).
        # NOT UART-RX (kernel-driven; no ring-3 involvement at M6-003).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r20b/expected-rpc-roundtrip.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r20b_acpi_rpc)
        # R20-M4-002 (#820): ACPI supervisor RPC witness — closes #820
        # (userspace acpi_supervisor server — accepts KIND_ACPI + serves
        # parse queries).
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx §m4_002_acpi_rpc_witness,
        # immediately after m6_rpc_witness_done and before sti): the
        # kernel-driven four-op RPC roundtrip proves the acpi_supervisor
        # server semantic end-to-end via the "Option B — kernel-side
        # witness driving the RPC" posture (per
        # design/ipc/userspace-server-substrate.md §4.4 Deferred and the
        # matching M5-001 / M6-003 pattern). Loops op ∈ {1, 2, 3, 4} —
        # ACPI_OP_ENUMERATE / GET_MADT / GET_MCFG / GET_HPET — through
        # sys_ipc_send_body → sys_ipc_recv_body (server drain) → kernel
        # dispatch via sup_* helpers (src/kernel/acpi/supervisor_dispatch.pdx)
        # → sys_ipc_reply_body → sys_ipc_recv_body (client drain). TSC
        # delta measured with kread_tsc bracketing each roundtrip; max
        # asserted < 2M ticks (~1 ms @ 2 GHz TSC, matching the AC
        # threshold). Op=1 additionally verifies n_tables >= 4 (q35
        # firmware always publishes at least FADT/MADT/MCFG/HPET).
        #
        # Fingerprint contract (contains-in-order — anchors on M6 and
        # extends with the M4-002 closure):
        #   R20b RPC ROUNDTRIP OK   (M6-003; anchors ordering)
        #   R20b ACPI RPC OK        (M4-002 — #820 close)
        # A regression that breaks M4-002 without breaking M6-003 surfaces
        # here as the missing ACPI line; the M6 line stays as ordering
        # anchor so a broken M6 witness is diagnosed by boot_r20b_rpc.
        #
        # Opt-in only (guarded by PAIDEIA_R20B_ACPI=1 in pre-push): the
        # M4-002 witness spawns ~350 lines of kernel-side orchestration
        # (2 endpoint allocs + 4 iters × 10-sub-step round trip + kernel
        # dispatch to 4 sup_* helpers + TSC gate + verification). The OK
        # fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired inside kernel_main) but only this mode
        # asserts its presence.
        #
        # NOT SMP (UP-only substrate at R20b per §14 Q3).
        # NOT UART-RX (kernel-driven; no ring-3 involvement at M4-002).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r20b/expected-acpi-rpc-roundtrip.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r20b_pci_rpc)
        # R22-M3-005 (#860): PCI enumerator RPC witness — closes #860
        # (userspace pci_enumerator server — walks tree via KIND_DEVICE
        # caps).
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx §m3_005_pci_rpc_witness,
        # immediately after m4_002_acpi_rpc_witness_done and before sti):
        # the kernel-driven three-op RPC roundtrip proves the pci_enumerator
        # server semantic end-to-end via the "Option B — kernel-side
        # witness driving the RPC" posture (per
        # design/ipc/userspace-server-substrate.md §4.4 Deferred and the
        # matching M5-001 / M6-003 / M4-002 pattern). Loops op ∈ {1, 2, 3}
        # — PCI_OP_LIST_DEVICES / DEVICE_INFO / GET_BAR_CAP — through
        # sys_ipc_send_body → sys_ipc_recv_body (server drain) → kernel
        # dispatch via pci_enum_* helpers
        # (src/kernel/core/pci/enumerator_dispatch.pdx) → sys_ipc_reply_body
        # → sys_ipc_recv_body (client drain). Op=1 additionally verifies
        # n_devices >= 4 against a witness-synthesized 4-entry _pci_devices
        # fixture (q35 device topology stand-in — under -kernel MCFG is
        # absent so real pci_enumerate_all returns 0 devices, forcing the
        # witness to seed _pci_devices deterministically before dispatch).
        #
        # Fingerprint contract (contains-in-order — anchors on the ACPI
        # RPC witness and extends with the M3-005 closure):
        #   R20b ACPI RPC OK        (M4-002; anchors ordering)
        #   R20b PCI RPC OK         (M3-005 — #860 close)
        # A regression that breaks M3-005 without breaking M4-002 surfaces
        # here as the missing PCI line; the ACPI line stays as ordering
        # anchor so a broken ACPI witness is diagnosed by
        # boot_r20b_acpi_rpc.
        #
        # Opt-in only (guarded by PAIDEIA_R22_PCI_RPC=1 in pre-push): the
        # M3-005 witness spawns ~300 lines of kernel-side orchestration
        # (2 endpoint allocs + 3 iters × 10-sub-step round trip + kernel
        # dispatch to 3 pci_enum_* helpers + TSC gate + verification). The
        # OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired inside kernel_main) but only this mode
        # asserts its presence.
        #
        # NOT SMP (UP-only substrate at R20b per §14 Q3).
        # NOT UART-RX (kernel-driven; no ring-3 involvement at M3-005).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r20b/expected-pci-rpc-roundtrip.txt"
        TIMEOUT=10
        EXPECTED=""
        ;;
    boot_r21_msix_round_robin)
        # R21-M4-005 (#841): MSI-X round-robin structural smoke.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, immediately
        # after ioapic_reroute_witness): unconditional call to
        # msix_round_robin_witness (tests/kernel/apic/msix_round_robin.pdx).
        # The witness allocates one MSI-X vector per CPU (0..3) via
        # vector_alloc_for_cpu, programs a fabricated 16-entry MSI-X table
        # via msix_program_entry (through the msix_assign_at bookkeeping
        # wrapper), and verifies the 4 × u32 entry fields byte-for-byte.
        # Emits "MSIX ROUND ROBIN OK\n" on pass.
        #
        # Fingerprint contract:
        #   SMP BRINGUP DONE
        #   IOAPIC REROUTE STRUCT OK
        #   MSIX ROUND ROBIN OK
        # The two witnesses run back-to-back, both inside the boot cli
        # window; SMP BRINGUP DONE anchors the ordering.
        #
        # Zero real-MMIO side effects — writes only to the .bss-backed
        # _fake_msix_table.  Uses per-CPU vector-pool bitmaps that stay
        # populated post-witness (bit 0 of word 0 in each CPU's pool),
        # so a follow-up allocator call at boot time would hand out
        # vector 0x61.  This is not currently a problem because M4 has
        # no other MSI-X allocation call sites at boot; when driver-plane
        # MSI-X consumers land (R23+), the witness needs to either
        # release its allocations or run pre-driver-plane.
        #
        # Opt-in only (guarded by PAIDEIA_R21_MSIX=1 in pre-push): this
        # is targeted R21.M4 validation, not a core boot smoke.  The
        # OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired) but only this mode asserts its presence.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r21/expected-msix-round-robin.txt"
        TIMEOUT=10
        SMP_MODE=1
        SMP_CPU_COUNT=4
        SMP_UNORDERED_HELLO=1
        EXPECTED=""
        ;;
    boot_r21_ioapic_reroute)
        # R21-M3-004 (#836): IOAPIC re-route structural smoke.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, immediately
        # after smp_bringup_done_msg): unconditional call to
        # ioapic_reroute_witness (tests/kernel/apic/ioapic_reroute_synth.pdx).
        # The witness saves RTE #4 LO/HI, reprograms IRQ 4 → CPU 1 via
        # ioapic_program_redir, reads back to verify vector + mask + dest,
        # then restores the original RTE via ioapic_write_at. Emits
        # "IOAPIC REROUTE STRUCT OK\n" on pass.
        #
        # Fingerprint contract:
        #   SMP BRINGUP DONE
        #   IOAPIC REROUTE STRUCT OK
        # SMP BRINGUP DONE anchors the ordering — the witness runs right
        # after that emit, so if the fingerprint appears without SMP
        # BRINGUP DONE preceding it, the wire-in has drifted.
        #
        # Runs on -smp 4 (matches boot_smp) so the reroute-to-CPU-1 target
        # is a valid APIC ID. The structural witness would also pass on
        # -smp 1 (dest=1 is a valid RTE bit-pattern regardless of receiver
        # existence, and no interrupt fires mid-witness because IF=0), but
        # -smp 4 keeps the parallel with boot_smp's topology.
        #
        # Opt-in only (guarded by PAIDEIA_R21_IOAPIC=1 in pre-push): this
        # is targeted R21.M3 validation, not a core boot smoke. The
        # OK fingerprint appears in EVERY boot log (the witness is
        # unconditionally wired) but only this mode asserts its presence.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r21/expected-ioapic-reroute.txt"
        TIMEOUT=10
        SMP_MODE=1
        SMP_CPU_COUNT=4
        SMP_UNORDERED_HELLO=1
        EXPECTED=""
        ;;
    boot_r21_ymm_preserve)
        # R21-M2-003 (#832): YMM-preservation regression fixture smoke.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, after
        # cpu_probe_avx512): unconditional calls to
        # ymm_preserve_synth_witness_a and ..._witness_b, both of which
        # SILENTLY SKIP if cpu_avx2_available() returns 0. On qemu64
        # default (no XSAVE, no AVX2) that means no fingerprint appears
        # — so this smoke mode uses `-cpu max` to expose XSAVE + AVX2
        # and force the fixture down its real code path.
        #
        # Fingerprint contract: two lines must appear in order —
        #   YMM PRESERVE A OK
        #   YMM PRESERVE B OK
        # Each witness round-trips YMM0 through xsave_save_for /
        # xsave_restore_for (the same machinery sched_switch_r15 uses)
        # with distinct pid slots (60 / 61) and distinct patterns (0xAA
        # / 0xBB fill). A "YMM PRESERVE FAIL" indicates either the
        # xsaveopt didn't persist YMM state to the area, the xrstor
        # didn't restore it, or the vpxor clobber failed to null YMM0.
        #
        # Opt-in only (guarded by PAIDEIA_R21_YMM=1 in pre-push): this
        # is a targeted validation, not a core boot smoke.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r21/expected-ymm-preserve.txt"
        TIMEOUT=8
        QEMU_CPU="max"
        EXPECTED=""
        ;;
    boot_r22_pci_tree)
        # R22-M2-005 (#855): PCI enumerator fingerprint.
        #
        # Kernel wire-in (src/kernel/boot/kernel_main.pdx, immediately
        # after r22m1_mcfg_done): unconditional call to
        # pci_enumerate_all(0). The enumerator gates on _mcfg_count:
        # if MCFG was NOT discovered by phase1_acpi_gather (the -kernel
        # boot path on QEMU q35), the enumerator emits
        # "PCI ENUM SKIP no MCFG" and returns 0 without touching config
        # space. If MCFG was discovered (UEFI/OVMF path, real hardware),
        # the enumerator walks bus 0 and every bridge descendant,
        # recording up to 256 devices in _pci_devices and emitting
        # "PCI DEV bus=B dev=D vendor=V device=X" per device followed by
        # "PCI ENUM DONE devices=N".
        #
        # Fingerprint (default -kernel path): "PCI ENUM SKIP no MCFG".
        # This is a health-check for the enumerator's skip path — the
        # UEFI/OVMF path with real device records requires the
        # PAIDEIA_UEFI_OVMF flow which is not wired into this smoke
        # yet.  When that wiring lands (R23), the fingerprint file
        # will grow the per-device lines and the DONE marker.
        #
        # Opt-in only (guarded by PAIDEIA_R22_PCI_TREE=1 in pre-push).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r22/expected-pci-tree.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_r22_msix_ir_round_robin)
        # R22-M6-005 (M5 debt fix): opt-in MSI-X-via-IR round-robin smoke.
        #
        # The R22.M5 witness at tests/kernel/iommu/msix_ir_round_robin.pdx
        # (symbol msix_ir_round_robin_witness) is NOT wired into
        # kernel_main at M5 close — same posture as vtd_slpt_synth_witness
        # (M4) and vtd_ir_program-only (M5): symbol existence + build-time
        # link-verification are the acceptance criterion, live invocation
        # is deferred to R23 when GCMD.TE + SIRTP + IRE ceremony wires
        # the IR unit for real dispatch.
        #
        # Under R22.M6, `PAIDEIA_R22_MSIX_IR=1 bash .githooks/pre-push`
        # previously failed because no `boot_r22_msix_ir_round_robin`
        # mode existed in this script — the fingerprint would be sought
        # against a nonexistent expected-file and the run would abort.
        # This SKIP-echo mode closes that gap: the pre-push env-gate
        # remains callable + the mode returns cleanly with a SKIP marker,
        # matching the `boot_r21_ymm_preserve` auto-skip pattern for
        # infra-not-yet-available witnesses.
        #
        # When R23 wires msix_ir_round_robin_witness into kernel_main
        # (behind Features.IOMMU_ENABLED=1 — see
        # design/kernel/iommu-boot-toggle.md §3 wire-up checklist), this
        # mode flips to FINGERPRINT_MODE=1 with a real
        # tests/r22/expected-msix-ir-round-robin.txt file matching the
        # `IR ROUND ROBIN OK\n` witness emit.
        echo "smoke: boot_r22_msix_ir_round_robin — SKIP (witness not wired at R22.M6; R23 dependency per design/kernel/iommu-boot-toggle.md)"
        exit 0
        ;;
    boot_r24_concurrent_io)
        # R24-M6-002 (#909): opt-in 4-CPU concurrent-IO throughput
        # scaffold, gated by PAIDEIA_R24_CONCURRENT_IO=1.
        #
        # The witness at tests/kernel/drivers/nvme/concurrent_io.pdx
        # (symbol concurrent_io_witness) is NOT wired into kernel_main
        # at M6 — same posture as msix_ir_round_robin_witness at
        # R22.M6: symbol existence + build-time link verification are
        # the R24-close acceptance criterion, live invocation is
        # deferred to R25+ when the driver-attach path wires
        # probe → identify → io_queues → sync_read into a boot-time
        # bring-up sequence AND the public sched_spawn substrate lands.
        #
        # QEMU-TCG default `-kernel` has no MCFG → PCI enumerator
        # drains empty → nvme_probe returns 0 → concurrent_io_witness
        # would take the SKIP branch even if it were invoked. So the
        # opt-in mode is a SKIP-echo at M6: the pre-push env-gate
        # stays callable (does not abort the push), the mode returns
        # cleanly with a SKIP marker, matching the R22.M6
        # msix_ir_round_robin pattern.
        #
        # When R25+ wires concurrent_io_witness into a boot-time
        # bring-up (behind PAIDEIA_R24_CONCURRENT_IO gating), this
        # mode flips to FINGERPRINT_MODE=1 with a
        # tests/r24/expected-concurrent-io.txt file matching the
        # "NVME CONCURRENT IO OK cpus=4 iops=<N>\n" witness emit.
        echo "smoke: boot_r24_concurrent_io — SKIP (witness not wired at R24.M6; R25+ dependency: driver-attach + public sched_spawn per design/round-retrospectives/r24-closure.md § Preflight for R25)"
        exit 0
        ;;
    boot_r25_pdxfs_corrupt_sb)
        # R25-M5-003 (#931): opt-in PdxFS-lite superblock corruption
        # fixture, gated by PAIDEIA_R25_PDXFS_CORRUPT=1.
        #
        # The witness at tests/kernel/fs/pdxfs_lite_corrupt_sb.pdx
        # (symbol pdxfs_lite_corrupt_sb_witness) is NOT wired into
        # kernel_main at R25.M5 — same posture as msix_ir_round_robin_
        # witness at R22.M6 close: symbol existence + build-time link
        # verification are the R25.M5 acceptance criterion, live
        # invocation is deferred to a later milestone when the FS
        # bring-up path exercises pdxfs_lite_mount from a real -kernel
        # boot fingerprint (blocked on the KIND_BLKDEV cap plumbing
        # already documented in mount_op.pdx as #1015).
        #
        # Under -kernel the QEMU boot has no NVMe controller → the
        # witness itself would still be callable (it operates on a
        # .bss-backed fake superblock, not a real device), but there
        # is no boot-path caller wired at R25.M5. This SKIP-echo mode
        # keeps the pre-push env-gate callable so PAIDEIA_R25_PDXFS_
        # CORRUPT=1 does not abort the push.
        #
        # When kernel_main wires pdxfs_lite_corrupt_sb_witness into
        # the boot-time bring-up (behind PAIDEIA_R25_PDXFS_CORRUPT
        # gating), this mode flips to FINGERPRINT_MODE=1 with a
        # tests/r25/expected-pdxfs-corrupt-sb.txt file matching
        # "PDXFS CORRUPT SB OK\n". At R32+ (when Features.CRYPTO_ML_
        # DSA_ENABLED=1 flips), the witness body itself is revised
        # to expect verify FAIL on the bit-flipped signed region —
        # see design/filesystem/pdxfs-lite-perf.md §5.
        echo "smoke: boot_r25_pdxfs_corrupt_sb — SKIP (witness not wired at R25.M5; caller wire-up deferred pending KIND_BLKDEV cap plumbing per src/kernel/core/fs/pdxfs_lite/mount_op.pdx header — #1015)"
        exit 0
        ;;
    boot_r25_pdxfs_e2e)
        # R25-M7-001 (#937): opt-in PdxFS-lite end-to-end mount-check
        # witness, gated by PAIDEIA_R25_PDXFS_E2E=1.
        #
        # The witness at tests/kernel/fs/pdxfs_lite_e2e_witness.pdx
        # (symbol pdxfs_lite_e2e_witness) is NOT wired into kernel_main
        # at R25.M7 — same posture as pdxfs_lite_corrupt_sb_witness at
        # R25.M5 close and concurrent_io_witness at R24.M6 close: symbol
        # existence + build-time link verification are the R25.M7
        # acceptance criterion, live invocation is deferred to R26+
        # when the driver-attach ceremony wires nvme_probe → identify →
        # io_queues → pdxfs_lite_mount into kernel_main_uefi (blocked
        # on the same #1015 userspace-server substrate as #820 acpi_
        # supervisor / #860 pci_enumerator / #906 userspace half of
        # nvme_read_blocking).
        #
        # Under -kernel the witness itself would take its SKIP branch
        # (pdxfs_lite_is_mounted returns 0 because no NVMe controller
        # ever surfaces via nvme_probe under q35 default), but at
        # R25.M7 there is no boot-path caller wired. This SKIP-echo
        # mode keeps the pre-push env-gate callable so
        # PAIDEIA_R25_PDXFS_E2E=1 does not abort the push.
        #
        # The full E2E promotion recipe (mkfs → boot → write → reboot
        # → read-verify) lives at tools/pdxfs-lite-e2e-smoke.md. Live
        # end-to-end promotion is queued for R26+ real-HW alongside
        # the R24 first-NVMe-touch moment.
        #
        # When kernel_main wires pdxfs_lite_e2e_witness into the boot-
        # time bring-up (behind PAIDEIA_R25_PDXFS_E2E gating), this
        # mode flips to FINGERPRINT_MODE=1 with a
        # tests/r25/expected-pdxfs-e2e.txt file matching
        # "PDXFS E2E OK mounted=1\n" (or "PDXFS E2E SKIP not mounted\n"
        # if the boot-time caller runs pre-mount for structural proof).
        echo "smoke: boot_r25_pdxfs_e2e — SKIP (witness not wired at R25.M7; live E2E deferred to R26+ per tools/pdxfs-lite-e2e-smoke.md — chained on #906 nvme_write_blocking + driver-attach)"
        exit 0
        ;;
    boot_r31_spawn_pair)
        # R31.M2-1590 (#1590): loader-side multi-task boot spawn — the
        # first time this kernel runs a userspace server as a distinct
        # ring-3 process rather than synthesizing both halves of its RPC
        # from ring 0.
        #
        # Kernel wire-in: src/kernel/boot/kernel_main.pdx, immediately
        # after r29_chaos_witness_done and before sti. Claims endpoint
        # rows 1 and 2 by id (endpoint_alloc_at), witnesses the losing
        # and winning service-lookup orders, then spawns echo_client and
        # echo_server through boot_spawn_user_task (task_new ->
        # elf_lite_load with the owning task -> user_stack_alloc ->
        # fresh-task trampoline -> runq_enqueue) and asserts both tasks'
        # seeded capabilities carry their own (pid, generation) in the
        # cap_owner column.
        #
        # Fingerprint contract (contains-in-order):
        #   SVC ORDER OK                 lookup before register is -ENOENT;
        #                                after register it resolves to the
        #                                registered endpoint.
        #   BOOT SPAWN OK                both tasks created and enqueued.
        #   SPAWN OWNER OK               cap_owner[slot] == pack(pid, gen)
        #                                for each spawned task's own cap.
        #   R31 ECHO CLIENT RING3 OK     printed BY the client, in ring 3.
        #   R31 ECHO SERVER RING3 OK     printed BY the server, in ring 3.
        #   R31 ECHO PAIR OK             printed by the client after it
        #                                verified the reply length and the
        #                                server's FRAME_OP_REPLY_BIT flip —
        #                                a round trip between two real
        #                                processes, driven by the scheduler.
        #   R31 SPAWN CAP SWEEP OK count=2
        #                                the client died and the owner sweep
        #                                MATCHED. The count is asserted, not
        #                                just the marker: a sweep that
        #                                matches zero is exactly the
        #                                signature of capabilities seeded
        #                                but never claimed, which is the bug
        #                                #1590 closes, and a bare marker
        #                                would accept it.
        #
        # Why count is 2, and why it used to be 1 (R31.M2-1596, #1596):
        #
        # echo_client's sidecar seeds slots 0 and 1, so 2 is the number of
        # capabilities it dies holding and always should have been. It read
        # 1 because R20b runs ONE GLOBAL cap_table and every image named
        # slot 0, so the server — spawned second — re-minted the client's
        # slot 0 and cap_mint_write cleared its owner column on the way past.
        # The client lost a capability to another process, silently, and
        # this golden recorded the loss as the expected value.
        #
        # The pair kept working only by coincidence: both slot-0 entries
        # named endpoint 1 and the server's rights were a superset of the
        # client's. Two images whose slot 0 named different objects would
        # have swapped authority with nothing reporting it.
        #
        # #1596 gave the images disjoint slot windows (client 0-1, server 2)
        # and made loader_seed_caps REFUSE to seed a slot a live task holds.
        # So the count is now the count, and a regression to 1 means the
        # overwrite is back.
        #
        # Client spawn order is deliberate: the CLIENT is spawned first,
        # i.e. the order in which a client can run to completion before its
        # server has ever been scheduled. It works because the kernel claims
        # both endpoint rows before either task exists, so the send lands in
        # a live buffer and the recv blocks until the server drains it. A
        # test that always spawns the server first proves nothing about the
        # order that arrives the moment scheduling changes.
        #
        # Opt-in only (PAIDEIA_R31_SPAWN=1 in pre-push) until it has run
        # 5/5 consecutive passes, matching the promotion discipline used
        # for boot_r20b_echo and boot_r20b_rpc. The markers appear in
        # EVERY boot log — the spawn is unconditionally wired — but only
        # this mode asserts them.
        #
        # NOT SMP (the substrate is single-flow per
        # design/ipc/userspace-server-substrate.md §14 Q3, and
        # _iretq_frame_scratch is still one global).
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r31/expected-spawn-pair.txt"
        TIMEOUT=12
        EXPECTED=""
        ;;
    boot_panic)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/logging/expected-panic-dump.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_release)
        # R49.M3-001 (#1576): release-mode boot regression gate.
        #
        # Rebuilds the kernel with PAIDEIA_BUILD_MODE=release (see
        # tools/build.sh; regenerates src/kernel/core/config/build_mode.pdx
        # with _kernel_build_mode = 1), boots under QEMU, and asserts:
        #
        #   1. Fingerprint: every line in tests/release/expected-release-
        #      boot.txt appears in order (banner + copyright + a system-
        #      ready line). Same contains-in-order semantics every other
        #      mode uses.
        #
        #   2. Line-count budget: the release boot fits in
        #      RELEASE_LINE_BUDGET lines (default 40). A regression that
        #      unmuted the witness stream would blow through the budget
        #      immediately (test mode is ~530 lines).
        #
        #   3. Zero R__ / M__-___ identifiers: no line matches
        #      `\bR[0-9]+\b` or `\bM[0-9]+-[0-9]+\b`. The banner_art
        #      copyright includes a numeric year (2026) that must not
        #      match this pattern by construction, and the release
        #      preamble/ready lines are already free of round tags.
        #
        #   4. Zero raw hex TSC timestamps: no line contains a 16-hex-
        #      digit run followed by `|` (klog's TSC column format). A
        #      regression that unmuted klog's drain-to-UART would trip
        #      this immediately.
        #
        # Non-vacuousness (R49.M3-001 acceptance criterion): trip any
        # one of the four gates by re-emitting a raw uart_puts of a
        # dev message inside the release presentation and observe the
        # mode fail. See design/kernel/boot-presentation.md §7.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/release/expected-release-boot.txt"
        TIMEOUT=10
        EXPECTED=""
        BUILD_MODE_OVERRIDE=release
        CHECK_RELEASE_BUDGET=1
        : "${RELEASE_LINE_BUDGET:=40}"
        ;;
    prod)
        # prod mode: expects exit code 2 (kernel didn't build)
        # Skip verification, just exit with code 2
        exit 2
        ;;
esac

# Global injection defaults. Fills in any INJECT_* knob left unset by
# both the caller's env AND the mode-branch. These values are exactly
# the historical boot_r16_uart_rx defaults, so that mode's behavior is
# preserved byte-for-byte.
: "${INJECT_STRING:=abc}"
: "${INJECT_DELAY:=1.0}"
: "${INJECT_HOLD:=15}"
: "${INJECT_WAIT_FOR:=}"
: "${INJECT_WAIT_TIMEOUT:=8}"
: "${INJECT_RETRIES:=1}"
: "${INJECT_RETRY_INTERVAL:=0.5}"

# Parse arguments: check for --fingerprint flag (backward-compatible)
if [[ "${EXPECTED}" == "--fingerprint" && -n "${2:-}" ]]; then
    FINGERPRINT_MODE=1
    FINGERPRINT_FILE="${REPO_ROOT}/tests/r8/expected-${2}.txt"
    EXPECTED=""
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "smoke: qemu-system-x86_64 not found; skipping" >&2
    exit 77
fi

# Fix #1588: the boot_exc3 / boot_panic_halt reduced kernels + their
# build-{exc3,panic}.sh scripts were archived. The reduced kernels
# (16-25 line kernel_main variants atop a 1319-line alternate boot
# stub) linked against the full kernel tree, and their trees never
# defined the boot-witness rodata + AP-trampoline symbols the tree
# now references — so the scripts broke silently and stayed broken
# with nothing in the default pre-push matrix exercising them. The
# main boot_panic mode uses the FULL kernel and covers the panic-
# emission chain already; no coverage was lost.
# R49.M3-001 (#1576): pass PAIDEIA_BUILD_MODE through when the mode
# dispatcher sets BUILD_MODE_OVERRIDE (currently only boot_release).
# Every other mode inherits the caller's environment unchanged, so the
# 14-mode witness matrix keeps building in TEST mode as before.
BUILD_MODE_OVERRIDE="${BUILD_MODE_OVERRIDE:-}"
CHECK_RELEASE_BUDGET="${CHECK_RELEASE_BUDGET:-0}"
if [[ -n "${BUILD_MODE_OVERRIDE}" ]]; then
    if ! PAIDEIA_BUILD_MODE="${BUILD_MODE_OVERRIDE}" "${REPO_ROOT}/tools/build.sh" >/dev/null 2>&1; then
        echo "smoke: build failed (PAIDEIA_BUILD_MODE=${BUILD_MODE_OVERRIDE})" >&2
        exit 2
    fi
else
    if ! "${REPO_ROOT}/tools/build.sh" >/dev/null 2>&1; then
        echo "smoke: build failed" >&2
        exit 2
    fi
fi
KERNEL="${REPO_ROOT}/build/kernel.elf"

LOG="/tmp/paideia-os-smoke.log"
rm -f "${LOG}"

if [[ ${UART_RX_MODE} -eq 1 ]]; then
    # R16.M4-666 (#666) end-to-end UART RX real-IRQ smoke.
    #
    # QEMU chardev pipe requires two pre-existing named FIFOs at
    # ${FIFO_BASE}.in and ${FIFO_BASE}.out. QEMU opens .in for READ
    # (guest RX) and .out for WRITE (guest TX). Both opens block
    # until the host side has a peer open — so we bring up the reader
    # and the writer BEFORE launching QEMU, in the background, and
    # let them keep the pipe alive for the full boot window.
    #
    # Injection timing: sleep 1.0s after QEMU launch, then write 'abc'.
    # The kernel witness (uart_rx_wire_witness) polls up to ~2s under
    # `sti` right before lapic_timer_init — that window straddles the
    # 1s injection either way (bytes arrive live under sti, or bytes
    # pre-queue in QEMU 16550 RBR and fire IRQ once ERBFI is set at
    # kernel uart_rx_init). See design/kernel/r16-m4-666-uart-rx-e2e-smoke.md §5.
    #
    # Trailing sleep on the writer keeps the pipe open so QEMU's
    # 16550 read side does not EOF mid-boot.
    FIFO_BASE="/tmp/paideia-os-uart-rx-$$"
    FIFO_IN="${FIFO_BASE}.in"
    FIFO_OUT="${FIFO_BASE}.out"
    rm -f "${FIFO_IN}" "${FIFO_OUT}"
    mkfifo "${FIFO_IN}" "${FIFO_OUT}"

    # Background reader: drain guest TX into LOG (matches the default
    # -serial file:${LOG} behavior every other mode relies on).
    # #757: line-buffer via stdbuf so INJECT_WAIT_FOR's grep on LOG
    # sees the readiness marker without waiting for cat's ~4KB stdio
    # buffer to fill. Falls back to bare cat if stdbuf is missing
    # (unlikely on Linux — ships with coreutils — but harmless).
    if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL cat "${FIFO_OUT}" > "${LOG}" &
    else
        cat "${FIFO_OUT}" > "${LOG}" &
    fi
    READER_PID=$!

    # Background writer: hold .in open for QEMU's read side; inject
    # INJECT_STRING after INJECT_DELAY settle so the kernel reaches
    # uart_rx_init (and any wait-for-prompt state) before the bytes
    # hit the 16550. INJECT_HOLD keeps the pipe alive for the full
    # boot window so QEMU's 16550 read side does not EOF mid-boot.
    # #750: parameterized (was hardcoded 'abc' + 1.0s + 15s) so shell
    # smoke modes can specify e.g. "echo hello\nexit\n" + 4.0s + 20s.
    # #757: optional INJECT_WAIT_FOR replaces the blind sleep with a
    # log-poll for a readiness marker (e.g. "SHELL START"), plus
    # INJECT_RETRIES for cases where a single write may not land during
    # the guest's read window. Redirection `> ${FIFO_IN}` opens the
    # pipe at subshell entry and blocks until QEMU opens the read
    # side; the body only runs once QEMU is attached, so the wait/
    # inject sequence is anchored to QEMU-attached time, not host time.
    (
        if [[ -n "${INJECT_WAIT_FOR}" ]]; then
            # Poll the serial log for the readiness marker. LOG is
            # populated by the background `cat ${FIFO_OUT} > ${LOG}`
            # reader started just above, so it grows in real time as
            # the guest writes to serial.
            wait_start=${SECONDS}
            while (( SECONDS - wait_start < INJECT_WAIT_TIMEOUT )); do
                if [[ -s "${LOG}" ]] && grep -q "${INJECT_WAIT_FOR}" "${LOG}" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
        fi
        # INJECT_DELAY still applies (post-ready settle when WAIT_FOR is
        # set; sole pre-write timing when it isn't — preserves the
        # boot_r16_uart_rx byte-for-byte default behavior).
        sleep "${INJECT_DELAY}"
        # Inject INJECT_STRING one or more times. `printf` here is the
        # bash builtin (write(2), no libc stdio buffering), so bytes
        # hit the FIFO promptly. Multiple attempts help when a single
        # write may not overlap the guest's read window (e.g. tty
        # bridge subtests may consume bytes before the shell reads).
        for _ in $(seq 1 "${INJECT_RETRIES}"); do
            printf '%b' "${INJECT_STRING}"
            if (( INJECT_RETRIES > 1 )); then
                sleep "${INJECT_RETRY_INTERVAL}"
            fi
        done
        sleep "${INJECT_HOLD}"
    ) > "${FIFO_IN}" &
    WRITER_PID=$!

    timeout ${TIMEOUT} qemu-system-x86_64 \
        -kernel "${KERNEL}" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -chardev pipe,id=char0,path="${FIFO_BASE}" \
        -serial chardev:char0 \
        -display none \
        -no-reboot \
        -no-shutdown \
        -m 32M \
        >/dev/null 2>&1
    QEMU_RC=$?

    # Tear down background procs (may already be gone if writer sleep expired).
    kill "${WRITER_PID}" 2>/dev/null || true
    kill "${READER_PID}" 2>/dev/null || true
    wait "${WRITER_PID}" 2>/dev/null || true
    wait "${READER_PID}" 2>/dev/null || true
    rm -f "${FIFO_IN}" "${FIFO_OUT}"
else
    # R18-M1 #764: multicore launch when SMP_MODE=1. QEMU's `-smp N`
    # exposes N logical CPUs to the guest; the kernel BSP boots first,
    # then wakes SMP_CPU_COUNT-1 APs (assumes contiguous APIC IDs
    # 1..N-1 — matches the QEMU default topology). Passing `-smp 1`
    # (SMP_MODE=0 default) preserves the historical single-CPU launch
    # byte-for-byte for every legacy mode.
    SMP_ARGS=()
    if [[ ${SMP_MODE} -eq 1 ]]; then
        SMP_ARGS=(-smp "${SMP_CPU_COUNT}")
    fi
    # R21-M2 #832: opt-in `-cpu` override for smokes that need feature
    # bits beyond qemu64 default (boot_r21_ymm_preserve → `-cpu max`
    # for XSAVE + AVX2). Empty QEMU_CPU (default) leaves the QEMU
    # `-cpu` unset, preserving qemu64-default behavior for every legacy
    # mode byte-for-byte.
    CPU_ARGS=()
    if [[ -n "${QEMU_CPU}" ]]; then
        CPU_ARGS=(-cpu "${QEMU_CPU}")
    fi
    timeout ${TIMEOUT} qemu-system-x86_64 \
        -kernel "${KERNEL}" \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -serial "file:${LOG}" \
        -display none \
        -no-reboot \
        -no-shutdown \
        -m 32M \
        "${CPU_ARGS[@]}" \
        "${SMP_ARGS[@]}" \
        >/dev/null 2>&1
    QEMU_RC=$?
fi

# QEMU exit codes: 124 = timeout (expected for halt+stay-on); 0 = clean; 35 = panic exit
if [[ ${QEMU_RC} -ne 0 && ${QEMU_RC} -ne 124 && ${QEMU_RC} -ne 35 ]]; then
    echo "smoke: qemu exited with rc=${QEMU_RC}" >&2
    exit 1
fi

if [[ ${FINGERPRINT_MODE} -eq 1 ]]; then
    # Fingerprint mode: validate serial output against expected lines
    if [[ ! -f "${FINGERPRINT_FILE}" ]]; then
        echo "smoke: fingerprint file not found: ${FINGERPRINT_FILE}" >&2
        exit 1
    fi

    # Read fingerprint file and check each line appears in order in the log
    log_content="$(cat "${LOG}" 2>/dev/null || echo "")"
    line_num=0
    search_offset=0

    while IFS= read -r line; do
        ((line_num++))
        if [[ -z "${line}" ]]; then
            # Skip empty lines in fingerprint file
            continue
        fi
        # R18-M1 #764: boot_smp — CPU_ID_XX_HELLO lines are presence-
        # only (no cross-AP ordering). Intel MP-init lets APs leave
        # wait-for-SIPI at slightly different times, and COM1 is
        # unlocked (ap_entry.pdx concurrency note), so on-wire order
        # of the three AP HELLOs is not deterministic. Bookend lines
        # (SMP BRINGUP START / DONE) still go through the ordered
        # check below, anchoring the AP HELLOs between them.
        if [[ ${SMP_UNORDERED_HELLO} -eq 1 && "${line}" =~ ^CPU_ID_[0-9a-f][0-9a-f]_HELLO$ ]]; then
            if [[ "${log_content}" == *"${line}"* ]]; then
                # Presence confirmed; do NOT advance search_offset (unordered).
                continue
            else
                echo "smoke: unordered fingerprint line ${line_num} ('${line}') NOT found anywhere in serial log (log size: $(stat -c%s "${LOG}" 2>/dev/null || echo 0))" >&2
                exit 1
            fi
        fi
        # #673: search remaining log starting at search_offset (real ordered check)
        remaining="${log_content:search_offset}"
        if [[ "${remaining}" == *"${line}"* ]]; then
            # Line found; advance search_offset past this occurrence
            prefix="${remaining%%"${line}"*}"
            search_offset=$((search_offset + ${#prefix} + ${#line}))
        else
            echo "smoke: fingerprint line ${line_num} ('${line}') NOT found in serial log after position ${search_offset} (log size: $(stat -c%s "${LOG}" 2>/dev/null || echo 0))" >&2
            exit 1
        fi
    done < "${FINGERPRINT_FILE}"

    echo "smoke: fingerprint check passed (all ${line_num} lines found in order)"

    # R49.M3-001 (#1576): release-mode extended assertions. Runs ONLY
    # for modes that set CHECK_RELEASE_BUDGET (boot_release). All four
    # gates operate on the SAME serial log the fingerprint check just
    # ran against.
    if [[ ${CHECK_RELEASE_BUDGET} -eq 1 ]]; then
        release_line_count=$(wc -l < "${LOG}")
        if [[ ${release_line_count} -gt ${RELEASE_LINE_BUDGET} ]]; then
            echo "smoke: release-mode line budget exceeded (${release_line_count} > ${RELEASE_LINE_BUDGET}); see design/kernel/boot-presentation.md §6" >&2
            exit 1
        fi
        # Zero R__ / M__-___ round or milestone identifiers. Excludes
        # the banner_art copyright year (four digits, no leading R/M).
        if grep -Eq '\b(R[0-9]+|M[0-9]+-[0-9]+)\b' "${LOG}"; then
            echo "smoke: release log contains a round/milestone identifier — regression against R49.M2-002 (#1574)" >&2
            grep -Enm 3 '\b(R[0-9]+|M[0-9]+-[0-9]+)\b' "${LOG}" >&2 || true
            exit 1
        fi
        # Zero raw hex TSC timestamps. klog's TSC column is 16 hex
        # digits immediately followed by `|` — no other release-visible
        # line has that shape.
        if grep -Eq '[0-9a-f]{16}\|' "${LOG}"; then
            echo "smoke: release log contains a raw hex TSC timestamp — klog drain unmuted?" >&2
            grep -Enm 3 '[0-9a-f]{16}\|' "${LOG}" >&2 || true
            exit 1
        fi
        echo "smoke: release-mode gates passed (lines=${release_line_count}, budget=${RELEASE_LINE_BUDGET}, no round/hex tags)"
    fi
    exit 0
fi

if [[ -n "${EXPECTED}" ]]; then
    if [[ -s "${LOG}" ]] && grep -q "${EXPECTED}" "${LOG}"; then
        echo "smoke: marker '${EXPECTED}' found in serial log"
        exit 0
    else
        echo "smoke: marker '${EXPECTED}' NOT in serial log (log size: $(stat -c%s "${LOG}" 2>/dev/null || echo 0))" >&2
        exit 1
    fi
fi

echo "smoke: kernel built + booted (no marker check requested)"
exit 0
