# PaideiaOS — First milestone (kernel-banner smoke + capability-system kickoff)

**Status:** Draft v0.1 — Phase-0 + Phase-1 spec.
**Date:** 2026-06-20
**Scope:** Per-phase deliverables for PaideiaOS bring-up. Phase-0 = kernel skeleton + build chain. Phase-1 = long-mode + UART banner. Phase-2 = capability system (FM-D5). Stops short of IPC + scheduler; those have their own milestones.

**Hard inputs:**
- `design/infrastructure/boot-path.md` — boot mechanism (BP-D1..D5).
- `design/infrastructure/build-system.md` — toolchain contract (BS-D1..D6).
- `design/capabilities/phase1-api.md` — Phase-1 capability API spec.
- `design/00-feature-inventory.md` — pillar set.
- `design/01-foundational-decisions.md` — discipline and architecture invariants.

---

## 0. Decisions summary

| ID    | Choice                                                                                            | Rationale                                                                                                          |
|-------|---------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| FM-D1 | Phase-0 is build-chain validation only                                                            | Kernel halts; smoke = "ELF loads, jumps to `_start`." No boot functionality is asserted yet.                       |
| FM-D2 | Phase-1 ships long-mode + serial UART + banner                                                    | Smallest visible-output milestone; observable via QEMU stdio without a framebuffer or graphics stack.              |
| FM-D3 | Serial = 16550 UART at COM1 (0x3F8)                                                               | QEMU default; same code works on most real x86 hardware; no PCI enumeration required.                              |
| FM-D4 | Phase-2 is the capability system (not IPC, not scheduler)                                         | Capabilities unblock IPC + scheduler + drivers; settling the layout first amortises across the rest of the kernel. |
| FM-D5 | Phase-1 banner content: `"PaideiaOS Phase 1 — <version> — capability-system bring-up starts here"` | Establishes versioning discipline + roadmap visibility from the first character emitted.                           |
| FM-D6 | No userspace through Phase-2                                                                      | Per `design/capabilities/phase1-api.md` P1CAP-D6 — kernel-internal caps only at this stage.                        |

---

## 1. Phase-0 (today)

Already in place after the Phase-0 scaffolding commit:

- `src/kernel/boot/entry.pdx` — `module PaideiaKernel`, with `_start = unsafe { cli; hlt; jmp $-1 }`.
- `src/kernel/link.ld` — ELF64 at 1 MiB load address, `ENTRY(_start)`.
- `tools/build.sh`, `tools/run-qemu.sh`, `tools/find-paideia-as.sh` — the build/run chain (BS-D3..D6).
- `tools/paideia-as/` — submodule pinned at `v0.4.0` (BS-D1).

### 1.1 Phase-0 smoke verification

```sh
./tools/build.sh                   # produces build/kernel.elf
file build/kernel.elf              # confirms ELF 64-bit LSB x86-64
readelf -h build/kernel.elf        # Entry point address: 0x100000
./tools/run-qemu.sh                # QEMU starts, kernel halts; Ctrl-A X to exit
```

**Phase-0 closure criterion:** all four commands run without error. No further runtime semantics are asserted — the CPU is still in 32-bit protected mode (per BP-D1) and the kernel deliberately halts.

---

## 2. Phase-1 (next ~1-2 weeks)

Three sub-deliverables, each a separate `.pdx` file under `src/kernel/boot/`. All Phase-1 code is permitted to use `unsafe { }` blocks; no typed I/O port or MSR surface exists yet.

### 2.1 Long-mode transition (`src/kernel/boot/long_mode.pdx`)

The full 32→64 sequence, captured in a single `unsafe { }` block per BP-D4:

1. `cli`; set up minimal 32-bit GDT (null, code, data).
2. Allocate page tables in `.bss` (PML4, PDPT, PD).
3. Identity-map the first 1 GiB via 2 MiB pages (or 1 GiB pages if CPUID `0x80000001:EDX[26]` confirms PDPE1GB).
4. Load CR3 with the PML4 base.
5. Set `CR4.PAE` (bit 5).
6. Set `IA32_EFER.LME` (MSR `0xC0000080`, bit 8).
7. Set `CR0.PG` (bit 31); `CR0.PE` (bit 0) is already asserted by QEMU.
8. `ljmp` to a 64-bit code-segment selector landing on `kernel_main_64`.

**Acceptance:** GDB attached to QEMU (`./tools/run-qemu.sh -s -S`) shows `%rip` in 64-bit code after long-mode entry. The 32-bit trampoline is unreachable thereafter.

### 2.2 COM1 16550 UART driver (`src/kernel/boot/uart.pdx`)

Minimum write-only UART, three functions:

- `uart_init()` — set divisor latch for 115200 baud, configure 8N1, enable FIFO.
- `uart_putc(c: u8)` — poll Line Status Register bit 5 (THRE) until set, then `out 0x3F8, c`.
- `uart_puts(s: *u8, len: u64)` — loop over `len` bytes invoking `uart_putc`.

All three bodies use `unsafe { in / out / hlt }` blocks. No typed I/O port surface is introduced; that arrives with the device-driver subsystem in Phase-3+.

**Acceptance:** `uart_puts("hello\n", 6)` produces `hello\n` on QEMU serial stdio (the `-serial mon:stdio` channel configured in `tools/run-qemu.sh`).

### 2.3 Banner emit (`src/kernel/boot/banner.pdx`)

```paideia
let banner_text : *u8 = "PaideiaOS Phase 1 — 0.0.1 — capability-system bring-up starts here\n"
let banner_text_len : u64 = 70

let kernel_main_64 = fn () -> {
  uart_init();
  uart_puts(banner_text, banner_text_len);
  loop { unsafe { cli; hlt } }
}
```

**Acceptance:** `./tools/run-qemu.sh` shows the banner on stdio then hangs. This is the first observable PaideiaOS boot.

### 2.4 Phase-1 closure criterion

All three sub-deliverables in place; the QEMU run reproduces the banner deterministically on three consecutive invocations; GDB confirms long-mode entry.

---

## 3. Phase-2 (capability system)

Per FM-D4, the first non-trivial subsystem. The authoritative spec is `design/capabilities/phase1-api.md`; this section names only the bring-up deliverables.

Each sub-deliverable is a `.pdx` file under `src/kernel/core/cap/`.

### 3.1 Capability descriptor (`src/kernel/core/cap/descriptor.pdx`)

The fixed-layout 32-byte `phase1_capability` struct (per `design/capabilities/phase1-api.md`):

- Type tag (`u8`).
- Rights bitmask (`u16`).
- Flags (`u8`) — revoked, immutable, etc.
- Object reference (`u64`) — kernel-internal pointer.
- LAM tag bits (`u4` in the high bits of the object ref on hardware that supports Linear Address Masking).
- Reserved (varies; pads to 32 bytes).

Code form: a paideia-as `struct CapDescriptor { ... }` plus a `static caps : [CapDescriptor; 256]` table living in `.bss`.

### 3.2 Core capability ops (`src/kernel/core/cap/ops.pdx`)

Three entry points; signatures match `design/capabilities/phase1-api.md`:

- `cap_create(type: u8, rights: u16, obj: u64) -> u64 /* handle */`
- `cap_revoke(handle: u64) -> ()`
- `cap_invoke(handle: u64, op: u64, arg: u64) -> u64`

Initially all caps live in a single kernel-AS table; userspace exposure is Phase-3+ (FM-D6).

### 3.3 Capability smoke (`tests/smoke/cap_smoke.pdx`)

A driver function that:

1. Creates a cap (`cap_create`).
2. Invokes it (`cap_invoke`) and asserts the result.
3. Revokes it (`cap_revoke`).
4. Re-invokes (expecting failure).
5. Prints the verdict via `uart_puts`.

**Acceptance:** smoke runs in QEMU and prints `cap_smoke: ok` on stdio.

---

## 4. Sequencing summary

```
Phase-0  (done)        kernel skeleton + build chain + halt
Phase-1  (next)        long_mode + uart + banner            (~1-2 weeks)
Phase-2  (then)        capability system + smoke             (~2-4 weeks)
Phase-3+ (later)       IPC primitive + scheduler + drivers
```

No date commitments; wall-clock is variable per the solo-developer assumption in `design/toolchain/milestones.md` §0.3.

---

## 5. Paideia-as walker-activation dependency

Per `design/infrastructure/build-system.md` §3, `paideia-as build` for the Phase-4 surface (records / generics / borrowed-refs / stdlib types) gates on per-walker activation. Phase-0 and Phase-1 use **only** the LCD surface — `let`, `fn`, lambda, `match`, `*T`, `unsafe`.

Phase-2 (capability system) **requires struct** support to build §3.1 `CapDescriptor`. The struct surface ships through paideia-as parse-clean, but build-side activation gates on the m1-005/006 walker chain.

**Gate:** Phase-2 cannot start until either:

- **(a)** the user activates the paideia-as walker chain (a paideia-as-side issue, not PaideiaOS work), or
- **(b)** the capability descriptor is encoded as a raw byte buffer with manual offset arithmetic (less ergonomic; does not need struct typed-surface activation).

The recommended path is **(a)**: close the paideia-as activation gap before Phase-2 starts. This couples PaideiaOS Phase-2 entry to a paideia-as side-issue and keeps PaideiaOS code on the typed surface.

---

## 6. Open questions for Phase-2 entry

- **Q1.** Does Phase-2 wait for paideia-as struct build-side activation, or proceed with raw-byte cap encoding?
- **Q2.** What is the cap table size? `256` entries is a placeholder; per-AS cap tables come later.
- **Q3.** Does Phase-2 include the LAM hardware path or only the software-tag fallback (per P1CAP-D2)?

These are the user's calls; documented here as open.

---

## 7. Forward links

- `design/infrastructure/boot-path.md` — boot mechanism (BP-D1..D5).
- `design/infrastructure/build-system.md` — toolchain contract (BS-D1..D6).
- `design/capabilities/phase1-api.md` — Phase-1 capability API spec.
- `design/ipc/phase1-api.md` — Phase-1 IPC API (consumes caps from §3 once Phase-3 begins).
- `design/kernel/phase1-sched-api.md` — Phase-1 scheduler API (also Phase-3).
- `tools/paideia-as/design/toolchain/phase-transition-4.md` §2 — walker-activation gate.
