---
doc: boot-presentation
scope: R49.M2-003 — release boot status presentation + M1-002 mechanism
issues:
  - "R49.M1-002 (#1572): build-mode / log-level split"
  - "R49.M2-002 (#1574): rewrite release-visible messages"
  - "R49.M2-003 (#1575): release boot status presentation"
  - "R49.M3-001 (#1576): release-mode boot witness + regression gate"
status: R49 initial landing — mechanism + minimal presentation live; per-
        stage progress lines land in follow-up milestones
related:
  - design/kernel/boot-message-inventory.md
  - design/kernel/kernel-logging-substrate.md
  - src/kernel/core/config/build_mode.pdx
  - src/kernel/core/klog/emit.pdx
  - src/kernel/core/klog/present.pdx
  - src/kernel/boot/uart.pdx
  - tools/build.sh
  - tools/run-smoke.sh
  - tests/release/expected-release-boot.txt
---

# Release boot presentation

## 0. Why this document exists

Two things are true about the boot output of a PaideiaOS shipped to
someone who did not commit code to this repository last week:

- It is what makes the first impression. A person watching a machine
  come up reads it; they do not know the smoke matrix exists.
- It is currently 530 lines of `TSC|CPU|LEVEL|TAG` witnesses aimed at
  a developer bisecting a hang.

R49 splits those into two streams: a **witness stream** (unchanged,
what the smoke matrix asserts, what tools like `bisect` grep) and a
**presentation stream** (what a person sees). This document specifies
the presentation stream, its extension points, and its regression
gate.

## 1. Modes

Two build modes, one binary shape:

- **TEST** (`PAIDEIA_BUILD_MODE=test`; the default). `tools/build.sh`
  with no env-var runs this. The witness stream is byte-for-byte the
  pre-R49 stream. Every existing smoke mode passes unchanged. The
  Present module (see §5) is present in the image but its entry
  points fast-return with no bytes written.

- **RELEASE** (`PAIDEIA_BUILD_MODE=release`). `tools/build.sh` sets
  the `_kernel_build_mode` constant to 1 in the generated
  `src/kernel/core/config/build_mode.pdx`. Two emit primitives gate
  on that constant:
  - `klog_emit_core` still populates its ring buffer (so in-kernel
    dmesg + audit-bridge history stay complete) but skips the
    drain-to-UART. Zero klog lines reach COM1.
  - `uart_puts` fast-returns before touching the port. Every raw
    boot_stub fixture emit (`banner_msg`, `KPTI OK`, `SMP BRINGUP
    DONE`, …) is muted.
  Whatever the `Present` module explicitly emits via `uart_putc`
  bypasses both gates and reaches the wire. That is the entire
  release-visible surface.

## 2. Non-goals

- **No runtime toggle.** There is no boot-command-line switch between
  test and release today; the choice is made at `tools/build.sh`
  invocation time. A future R25+ command-line parser (see
  `kernel-logging-substrate.md` non-goals) could add one; the
  mechanism here is forward-compatible with it (both a compile-time
  `_kernel_build_mode` value and a runtime override would land on the
  same .data qword).
- **No structured RELEASE format on top of `uart_putc`.** The Present
  module writes plain ASCII lines, terminated with `\n`. The klog
  format (TSC + CPU + level + subsystem + tag) is a developer format,
  intentionally absent from the presentation stream.
- **No user-image gating.** `sys_write` on fd 1 from ring-3 is not
  release-muted. A shell prompt or an init log line is user output,
  not developer diagnostic.

## 3. Mechanism trade-off

R49.M1-002 asks for a compile-time-vs-runtime decision. The chosen
mechanism is a **runtime gate on a build-time-set constant**:

- A single .data qword (`_kernel_build_mode`) is the gate.
- `tools/build.sh` regenerates `src/kernel/core/config/build_mode.pdx`
  at every build to reflect `$PAIDEIA_BUILD_MODE`.
- Every emit-entry gate is a two-instruction load + compare.

Why not compile-time strip (release image contains no witness
strings at all)?

- paideia-as at 0.29 has no `#if`/`@if_feature`/dead-branch elim of
  unsafe-block bodies. A real compile-time strip would need two
  parallel copies of every emit site — a maintenance surface that
  doubles the defect surface and rests on two translations staying
  in step.
- The runtime gate survives the assembler's maturity curve. When
  paideia-as gains conditional emit, the *same* `_kernel_build_mode`
  becomes the trigger for real strip, and no emit site changes.

The trade-off cost is that the release image carries the DEBUG
strings in .rodata — a few KB of unused text — even though they
never reach COM1. Documented; accepted; revisited when the
assembler substrate lands.

## 4. Presentation layout

### 4.1 Ordering (at R49 landing)

    <banner_art — five-line ASCII logo, product tagline, copyright>
    Kernel starting. Please wait for system ready.
    System ready.

Everything the machine does between "Kernel starting." and "System
ready." is invisible in release mode at the R49 landing. That is a
deliberate initial posture, not a final one: the R49 landing
establishes the mechanism, the smoke gate, and the presentation
surface (one file, `present.pdx`). Per-stage progress lines land in
follow-up milestones by growing the Present module.

### 4.2 Ordering (target, follow-up milestones)

    <banner_art>
    Kernel starting.
    Firmware:  UEFI (or: BIOS via multiboot2)
    CPU:       Intel Core i7-1370P (14 cores, 20 threads, x2APIC)
    Memory:    31.3 GiB usable (of 32.0 GiB total)
    Storage:   NVMe SSD (INTEL SSDPEKKW512G8), 512 GB
    Input:     Keyboard, Touchpad, Camera
    Network:   Wi-Fi 6E (Intel AX211)
    System ready.

Each line above is added as a distinct `present_*` entry point in
`present.pdx`. Every entry point checks `_kernel_build_mode` and no-
ops in TEST — so growing the Present module never affects the
witness matrix.

### 4.3 Grouping

- **Boot identity** (banner + copyright) — first bytes.
- **Firmware / CPU / Memory** — the fixed facts about the machine.
- **Storage / Input / Network** — the discovered facts. Ordered by
  probe order, not alphabetically, so a person watching the boot
  can see which device is being probed if a hang follows.
- **System ready.** — the final line. If it does not appear, the
  release machine did not finish booting.

### 4.4 Progress display

Per-stage lines print on **completion**, not per-poll. A device that
takes 500 ms to enumerate produces one line (its result), not a
progress bar. Rationale: a boot log a person reads is a sequence of
outcomes, not a live trace. The witness stream is where the trace
lives (in TEST mode, and in the ring buffer even in RELEASE).

### 4.5 Failure and degraded-device surfacing

R49.M2-003 explicitly requires that a device that failed to probe
appear on the wire, not be silently absent. The rule:

- **Attached device probed OK** → single presentation line with
  identifier.
- **Attached device probed and failed** → single presentation line
  with `(failed: <reason>)` suffix. Example:
      Input:     Keyboard, Touchpad, Camera (failed: descriptor read timeout)
- **No device of a class present** → the line is omitted (a machine
  without Wi-Fi does not print `Network:`).
- **Whole subsystem missing** (e.g. no storage detected on a machine
  with an NVMe slot expected) → the line prints with
  `(none detected)`, and the machine still reaches "System ready."
  Rationale: a booting system that finishes booting deserves to
  say so; a subsystem outage is a subsystem outage, not a boot
  failure.

Fatal failures (a panic before "System ready.") do not go through
Present. They go through `klog_panic`, which is *not* muted in
release — a machine that panics before it is up must say what
happened. Panic output is intentionally verbose in both modes.

### 4.6 Verbose escape hatch

Two paths are reserved:

- **In-kernel dmesg.** Even in release mode, the klog ring is
  populated. A user-space `dmesg`-equivalent (planned) can read the
  full developer trace after boot. This is R50+ work; the ring
  substrate is already in place (`design/kernel/kernel-logging-
  substrate.md`).
- **Boot-time `PAIDEIA_BUILD_MODE=test`.** A person who wants the
  full trace at boot rebuilds with test mode. The bar for a person
  who wants to bisect a boot hang is "rebuild"; that is right,
  because the bar for someone who does not want to bisect is
  "everything is a sentence."

## 5. Present module contract

`src/kernel/core/klog/present.pdx` is the *only* file whose changes
affect the release-visible surface. Its interface at R49 landing:

    pub let present_boot_start : () -> () !{sysreg, mem} @{}
    pub let present_boot_ready : () -> () !{sysreg, mem} @{}
    pub let present_puts       : (u64) -> () !{sysreg, mem} @{}

Rules:

- Every `present_*` entry point checks `_kernel_build_mode` and
  no-ops in TEST mode.
- Every release-visible byte is written via `present_puts`, which
  calls `uart_putc` directly — bypassing the release mute on
  `uart_puts`.
- Wording obeys R49.M2-002: no `R__` / `M__-___`, no raw hex TSC,
  no truncated 4-char tag, no per-call trace repetition.

Growth pattern (follow-up milestones):

    pub let present_firmware : (u64 firmware_kind) -> () !{sysreg, mem} @{}
    pub let present_cpu      : (u64 core_count, u64 thread_count) -> ...
    pub let present_memory   : (u64 usable_kib) -> ...
    pub let present_device_line : (u64 tag_ptr, u64 detail_ptr, u64 flags) -> ...

Every future stage-progress line is a new `present_*` entry point
called from the appropriate boot-flow point in
`src/kernel/boot/kernel_main.pdx`. It automatically inherits the
TEST-mute + release-emit gate. The Present module carries the
presentation *and* the wording rules in one place.

## 6. Regression gate (R49.M3-001)

`tools/run-smoke.sh boot_release` boots the kernel in RELEASE mode
under QEMU and asserts:

1. **Fingerprint** — `tests/release/expected-release-boot.txt` lines
   appear in order in the log.
2. **Line-count budget** — `wc -l < LOG ≤ RELEASE_LINE_BUDGET`
   (default 40, tunable per-run).
3. **No round / milestone identifiers** — `grep -E '\b(R[0-9]+|M[0-9]+-[0-9]+)\b'` returns nothing.
4. **No raw hex TSC** — `grep -E '[0-9a-f]{16}\|'` returns nothing.

The mode passes `PAIDEIA_BUILD_MODE=release` to `tools/build.sh`,
so the file `src/kernel/core/config/build_mode.pdx` is regenerated
with `_kernel_build_mode = 1` before assembly.

Wired into `.githooks/pre-push` as an opt-in gate under
`PAIDEIA_R49_RELEASE=1`; promotes to the default matrix after 5/5
consecutive passes, matching the R20b substrate-witness promotion
convention.

## 7. Non-vacuousness

The R49.M3-001 acceptance criterion is that the gate not just pass
but *bite*. Demonstrate by inserting the following inside
`present_boot_start` and rebuilding + running `boot_release`:

    lea rdi, [rip + banner_msg];   // "PaideiaOS R8\n\0"
    call present_puts;

The line-count budget stays fine, but the round-identifier gate
matches `R8` and the mode fails with:

    smoke: release log contains a round/milestone identifier —
           regression against R49.M2-002 (#1574)
    3:PaideiaOS R8

Revert the insertion and the mode passes again. Ditto for a klog
line: temporarily remove the `klog_drain_muted` label branch in
`src/kernel/core/klog/emit.pdx` and any klog fires immediately trip
the hex-TSC gate.
