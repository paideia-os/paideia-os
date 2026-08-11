#!/usr/bin/env bash
# Phase-1 smoke regression: builds the kernel, runs under QEMU with a
# configurable timeout, captures serial output, and asserts deterministic
# bytes.
#
# Usage: tools/run-smoke.sh [MODE | expected_marker | --fingerprint PATTERN]
#   - MODE: one of 'boot_min', 'boot_banner', 'boot_tick', 'boot_r8_only', 'boot_r10', 'boot_r11', 'boot_r12', 'boot_r12_denial', 'boot_r14b_hivma', 'boot_r14b_kpti', 'boot_r14b_ipi', 'boot_r14b_loader', 'boot_r14b_ud', 'boot_r15_ring3', 'boot_r15_process', 'boot_r16_uart_rx', 'boot_r17_init', 'boot_r17_shell_echo_hello', 'boot_r17_shell_multi_command', 'boot_r17_shell_child_process', 'boot_r17_shell_shutdown', 'boot_smp', 'boot_panic', 'boot_panic_halt', 'boot_exc3', 'prod' (mode dispatcher)
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
BUILD_PANIC=0
BUILD_EXC3=0
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
        # not appear elsewhere in the boot log), REAPED (init's second
        # wait4 unblocking on the shell exit).
        #
        # INJECT_HOLD is bumped to 12s (vs echo_hello's 10s) so the
        # pipe stays open long enough for the shell to process five
        # sequential lines through the tty stdin bridge; each line
        # requires a full sys_read → dispatch → puts_new round trip.
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-multi-command.golden"
        TIMEOUT=15
        UART_RX_MODE=1
        : "${INJECT_STRING:=pwd\ncd /tmp\npwd\nhelp\nexit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=12}"
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
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/r17/shell-shutdown.golden"
        TIMEOUT=12
        UART_RX_MODE=1
        : "${INJECT_STRING:=exit\n}"
        : "${INJECT_WAIT_FOR:=SHELL START}"
        : "${INJECT_DELAY:=0.3}"
        : "${INJECT_HOLD:=10}"
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
    boot_panic)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/logging/expected-panic-dump.txt"
        TIMEOUT=8
        EXPECTED=""
        ;;
    boot_panic_halt)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/logging/expected-panic-halt.txt"
        TIMEOUT=5
        BUILD_PANIC=1
        EXPECTED=""
        ;;
    boot_exc3)
        FINGERPRINT_MODE=1
        FINGERPRINT_FILE="${REPO_ROOT}/tests/logging/expected-exc3.txt"
        TIMEOUT=5
        BUILD_EXC3=1
        EXPECTED=""
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

# M8-001 (#706): boot_panic_halt mode builds panic kernel instead of normal kernel
# M3-002 (#715): boot_exc3 mode builds exception kernel instead of normal kernel
if [[ ${BUILD_PANIC} -eq 1 ]]; then
    if ! "${REPO_ROOT}/tools/build-panic.sh" >/dev/null 2>&1; then
        echo "smoke: build-panic failed" >&2
        exit 2
    fi
    KERNEL="${REPO_ROOT}/build/kernel-panic.elf"
elif [[ ${BUILD_EXC3} -eq 1 ]]; then
    if ! "${REPO_ROOT}/tools/build-exc3.sh" >/dev/null 2>&1; then
        echo "smoke: build-exc3 failed" >&2
        exit 2
    fi
    KERNEL="${REPO_ROOT}/build/kernel-exc3.elf"
else
    if ! "${REPO_ROOT}/tools/build.sh" >/dev/null 2>&1; then
        echo "smoke: build failed" >&2
        exit 2
    fi
    KERNEL="${REPO_ROOT}/build/kernel.elf"
fi

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

# QEMU exit codes: 124 = timeout (expected for halt+stay-on); 0 = clean; 35 = panic exit (expected for boot_panic_halt)
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
