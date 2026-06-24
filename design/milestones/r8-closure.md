# PaideiaOS R8 Milestone Closure Document

## Overview

**R8** is the bootstrap and foundational subsystem round of PaideiaOS, spanning **B1–B6** phases plus **B7** integration and closure.

During R8, the kernel transitions from bare-metal QEMU startup (via PVH) through long-mode entry, UART output, capability mint/verify/invoke, and inter-process communication (IPC). The kernel is **fully functional and boots to a stable SPSC (Single-Producer, Single-Consumer) IPC channel state**.

**Final Boot Output:**
```
B
PaideiaOS R8
CAP OK
IPC OK
```

All audit entries referenced below document the implementation decisions and correctness reasoning for each subsystem.

---

## B1: Bootstrap Phase-1 Instrumentation

### Issues Closed

- **B1-001** (PVH ELF Note): ✓ Complete
  - Added `.note.Xen` section to kernel ELF via paideia-as `PA10-001` Xen note emission
  - Linked into all binaries via `link.ld` PHDRS configuration
  - QEMU now recognizes PVH boot protocol and loads kernel.elf directly

- **B1-002** (QEMU isa-debug-exit): ✓ Complete
  - Integrated `isa-debug-exit` device into `run-qemu.sh` and `run-smoke.sh`
  - Implemented `qemu_exit()` and `qemu_exit_success()` in `qemu_exit.pdx`
  - Graceful shutdown path: write byte 0x10 to port 0x501 to exit QEMU with code 33
  - Smoke harness uses this for deterministic test termination

- **B1-003** (Fingerprint Assertion + Closure): ✓ Complete
  - Baseline fingerprint file `tests/r8/expected-boot-min.txt` captures minimal output ("B\n")
  - Fingerprint mode in `run-smoke.sh` validates serial output byte-for-byte
  - Audit entry: `qemu-exit-001.md`

### Key Decisions

- PVH boot avoids legacy BIOS + bootloader complexity; direct ELF load on QEMU + real hardware
- `isa-debug-exit` device (non-standard; QEMU-only) used for deterministic test harness termination
- Fingerprint validation enforces determinism for future regression detection

---

## B2: 32→64 Long-Mode Transition

### Issues Closed

- **B2-001** (GDT Layout + lgdt): ✓ Complete
  - Defined real x86-64 GDT with **null descriptor**, **code descriptor (0x08)**, and **data descriptor (0x10)**
  - Implemented 10-byte `lgdt` instruction with operand reference to GDT base address
  - Audit entry: `boot-gdt-001.md`

- **B2-002** (CR4.PAE / CR3 / EFER.LME / CR0.PG|PE): ✓ Complete
  - Sequenced control register initialization in `boot_stub.S`:
    1. Set CR4.PAE (bit 5) to enable 36-bit physical addressing
    2. Load CR3 with PML4 physical address (pre-zeroed in .bss)
    3. Set EFER.LME (bit 8 via MSR 0xC0000080) to enable 64-bit mode
    4. Set CR0.PG (bit 31) to activate paging
    5. Set CR0.PE (bit 0) to activate protected mode (order: PG after PE)
  - Implemented via Mode32 instruction dispatch in paideia-as v0.11.0:
    - `or r32, imm32` for register bit-set with 32-bit immediate
    - `mov [abs32], imm32` for absolute address writes
  - Audit entry: `boot-longmode-001.md`

- **B2-003** (ljmp 0x08:long_mode_entry): ✓ Complete
  - Implemented far-jump from 32-bit mode to 64-bit entry point
  - Used `ljmp selector,offset` with absolute PLT32 relocation
  - Paideia-as v0.11.0 resolves symbol-relative offsets in [sym + N] memory addressing
  - Audit entry: `_start-b2-status.md`

- **B2-004** (First 'B' on COM1): ✓ Complete
  - Boot stub writes character 'B' + newline to UART port 0x3F8 (COM1) immediately upon long-mode entry
  - Simple polling loop: check LSR bit 5 (THRE) before each byte write
  - Demonstrates UART control flow and establishes baseline boot output
  - Audit entry: `boot-longmode-001.md`

### Key Decisions

- **Entry point order:** Boot stub executes in 32-bit mode, transitions to long mode in place, then continues execution
- **Control register sequences:** PAE before EFER.LME before CR0.PG for VMX/EPT compatibility on real hardware
- **UART as system health indicator:** Early character output validates boot path and serial communication

---

## B3: UART Driver + Banner

### Issues Closed

- **B3-001** (UART Init): ✓ Complete
  - Initialized UART (COM1 at port 0x3F8) in kernel_main with full control:
    - Set baud rate to 115200 via DLL+DLM (divisor latch) configuration
    - Configure line control (8N1: 8 data bits, no parity, 1 stop bit)
    - Enable FIFO + clear Tx/Rx
  - Implemented via unsafe inline assembly in kernel.pdx
  - Audit entry: `b3-001-uart-init.md`

- **B3-002** (UART putc): ✓ Complete
  - Implemented character output: poll LSR.5 (THRE), write THR
  - Polling loop: check transmit hold register empty before each byte
  - Handles both stdout banner and IPC success messages
  - Audit entry: `b3-002-uart-putc.md`

- **B3-003** (UART puts): ✓ Complete
  - String output routine: iterate bytes, call putc for each
  - Handles null-termination and newline injection
  - Emits "PaideiaOS R8\n" banner in kernel_main
  - Audit entry: `b3-003-uart-puts.md`

### Key Decisions

- **DLL divisor (0x0C):** Clock 1.8432 MHz ÷ 115200 = 16 (0x0C exact)
- **Polling UART:** No interrupts needed for bootstrap; FIFO enables buffering without ISR overhead
- **Banner timing:** Output early in kernel_main to validate control flow before capability/IPC subsystems

---

## B4: Smoke Harness Modes

### Issues Closed

- **B4-001** (Harness Decomposition): ✓ Complete
  - Created unified smoke test framework with two modes:
    - **Fingerprint mode:** byte-exact output validation against expected files
    - **Null-byte mode:** termination on 0x00 byte (for capability/IPC test fixtures)
  - Implemented in `run-smoke.sh` with test selector argument
  - Supports timeout-based failure detection (5-second default)

- **B4-002** (Test Fixture Integration): ✓ Complete
  - Smoke harness loads kernel.elf, boots via QEMU, captures serial output
  - Fingerprint files: `tests/r8/expected-boot-min.txt` (B1 baseline), `expected-boot-banner.txt` (R8 final)
  - Null-byte fixtures: capability and IPC subsystem tests write 0x00 to signal completion

### Key Decisions

- **Two-mode harness:** Separates deterministic regression tests (fingerprint) from functional E2E (null-byte)
- **QEMU `isa-debug-exit`:** Enables deterministic test termination without timeout fallback

---

## B5: Capability System (mint + verify + invoke)

### Issues Closed

- **B5-001** (Descriptor Table Layout): ✓ Complete
  - Allocated 256-entry descriptor table in kernel .bss (256 × 8 bytes = 2 KiB)
  - Each entry: **64-bit LAM-tagged capability** (low 4 bits: kind; bits 4–63: payload)
  - Added per-CPU **capability counter** for generation tracking (mint iteration count)
  - Audit entry: `b5-001-descriptor-table.md`

- **B5-002** (cap_mint): ✓ Complete
  - Allocates descriptor from free-list (initialized at boot via slab discipline)
  - Encodes kind (4-bit enum: KIND_DEVICE, KIND_MEMORY, KIND_IPC_ENDPOINT, etc.)
  - Composes capability: **kind | (payload << 4)**, stores in descriptor table at slot
  - Returns handle: **slot | (generation << 8)**
  - Audit entry: `b5-002-cap-mint.md`

- **B5-003** (cap_verify): ✓ Complete
  - Decodes handle into slot and generation
  - Retrieves descriptor from table at slot
  - Cross-checks generation to detect revoked capabilities
  - Returns capability for invoker or 0 on invalid/revoked
  - Audit entry: `b5-003-cap-verify.md`

- **B5-004** (cap_invoke): ✓ Complete
  - Decodes verified capability: extracts kind + payload
  - Nested match on (kind, operation) → dispatcher
  - Routes to subsystem-specific handler (e.g., IPC_SEND for KIND_IPC_ENDPOINT)
  - Audit entry: `b5-004-cap-invoke.md`

- **B5-005** (E2E Fixture + Closure): ✓ Complete
  - Test fixture `tests/r5/cap_mint_verify.pdx`:
    - Mints capability, verifies it, invokes NOOP operation
    - Outputs "CAP OK\n" on success
    - Terminates via 0x00 byte
  - All three subsystem functions tested in single flow
  - Smoke harness validates "CAP OK" in output

### Key Decisions

- **LAM-tagged encoding:** 4-bit kind + 60-bit payload, preserving x86-64 Linear Address Masking tags
- **Generation-based revocation:** Per-slot counter prevents use-after-free; increment on revoke
- **Slab allocator:** Free-list discipline with LIFO for descriptor pool (64 max capability slots)

---

## B6: IPC MVP (Single-Producer, Single-Consumer Channel)

### Issues Closed

- **B6-001** (Channel Pool Placement + Cursor Mutability): ✓ Complete
  - Allocated unified `channel_data[66]` array in kernel .bss
  - Slots 0–63: 64-byte messages (ring buffer)
  - Slots 64–65: head/tail cursors (64-bit each, mutable within unsafe blocks)
  - Channel structure: { pool_index, num_slots, read_cap, write_cap } per endpoint pair
  - Audit entry: `ipc-channel-pool-001.md`

- **B6-002** (Real ipc_enqueue with Copy): ✓ Complete
  - Producer-side operation: write message to ring, advance head cursor
  - Implemented in unsafe assembly block:
    1. Check queue full: if head == (tail − 1) mod 64, return error
    2. Compute ring index: head mod num_slots
    3. Copy message bytes into ring[index] (loop with movq + offset)
    4. Increment head atomically
  - Audit entry: `ipc-enqueue-001.md`

- **B6-003** (Real ipc_dequeue with Copy): ✓ Complete
  - Consumer-side operation: read message from ring, advance tail cursor
  - Implemented in unsafe assembly block:
    1. Check queue empty: if head == tail, return error
    2. Compute ring index: tail mod num_slots
    3. Copy message bytes from ring[index] into output buffer (loop with movq + offset)
    4. Increment tail atomically
  - Audit entry: `ipc-dequeue-001.md`

- **B6-004** (Producer-Consumer Smoke Fixture): ✓ Complete
  - Test fixture `tests/r6/ipc_smoke.pdx`:
    - Enqueues message pair (0xDEAD, 0xBEEF)
    - Dequeues and verifies byte-for-byte match
    - Outputs "IPC OK\n" on success
    - Terminates via 0x00 byte
  - Smoke harness validates "IPC OK" in output

- **B6-005** (Deadlock-Freedom Invariant + Closure): ✓ Complete
  - **Invariant:** Single-producer, single-consumer with head-only enqueue and tail-only dequeue
  - No mutual exclusion needed: producer cannot race with consumer on same cursor
  - Ring wrap-around handled modulo arithmetic; no unbounded pointer chasing
  - Audit entry: `ipc-deadlock-freedom-001.md`

### Key Decisions

- **SPSC discipline:** One producer, one consumer per channel eliminates lock contention
- **Ring capacity:** 64 messages (8 bytes each) = 512 bytes per ring, fits in L1 cache
- **No sync primitives:** Atomic increment (lock cmpxchg) used only for head/tail; no barriers needed due to x86-TSO memory model

---

## B7: Integration + Closure

### Issues Closed

- **B7-001** (Combined Smoke Matrix): ✓ Complete
  - Updated `tests/r8/expected-boot-banner.txt` to include all 4 required outputs:
    ```
    B
    PaideiaOS R8
    CAP OK
    IPC OK
    ```
  - Pre-push hook gates on this file; smoke harness validates fingerprint
  - All B1–B6 subsystems verified in single boot sequence

- **B7-002** (Phase 7 Milestone Document): ✓ Complete
  - This document (`design/milestones/r8-closure.md`)
  - Summarizes all architectural decisions and audit entry references
  - Provides continuity toward Phase 2+ work

- **B7-003** (Round Closure + R9 Kickoff): ✓ Complete
  - STATUS.md updated: R8 marked CLOSED
  - Stub R9 plan created: `design/milestones/r9-kickoff.md`

---

## Audit Entries

The following audit entries document implementation decisions and correctness reasoning:

### Bootstrap & Hardware Bring-up

- `boot-gdt-001.md` — GDT layout and lgdt instruction encoding
- `boot-longmode-001.md` — Long-mode transition sequencing (CR4/CR3/EFER/CR0)
- `qemu-exit-001.md` — isa-debug-exit device integration and exit protocol
- `_start-b2-status.md` — Boot stub entry point and control flow

### UART Subsystem (B3)

- `b3-001-uart-init.md` — UART initialization (baud rate, line control, FIFO)
- `b3-002-uart-putc.md` — Character output with UART polling
- `b3-003-uart-puts.md` — String output routine and banner emission

### Capability System (B5)

- `b5-001-descriptor-table.md` — Descriptor table layout and LAM-tag encoding
- `b5-002-cap-mint.md` — Capability allocation with generation tracking
- `b5-003-cap-verify.md` — Capability validation and revocation detection
- `b5-004-cap-invoke.md` — Capability invocation dispatch

### IPC Subsystem (B6)

- `ipc-channel-pool-001.md` — Ring buffer allocation and cursor management
- `ipc-enqueue-001.md` — Producer-side message insertion with full-queue check
- `ipc-dequeue-001.md` — Consumer-side message removal with empty-queue check
- `ipc-smoke-001.md` — E2E test fixture for SPSC channel
- `ipc-deadlock-freedom-001.md` — Mutual exclusion analysis (SPSC discipline)

---

## Boot Verification

The final boot sequence produces deterministic output validated by the fingerprint harness:

```shell
$ timeout 5 ./tools/run-smoke.sh fingerprint tests/r8/expected-boot-banner.txt
Running kernel via QEMU (fingerprint mode)...
Serial output matches expected-boot-banner.txt ✓
```

Each line output by a distinct subsystem:
1. **"B"** — B2 long-mode entry (boot_stub.S)
2. **"PaideiaOS R8"** — B3 banner (kernel_main UART initialization)
3. **"CAP OK"** — B5 smoke fixture (mint + verify + invoke success)
4. **"IPC OK"** — B6 smoke fixture (enqueue + dequeue success)

---

## Next Phase: R9 (Interrupt & Timer Reactivation)

See `design/milestones/r9-kickoff.md` for the stub plan.

R9 focuses on:
- Interrupt descriptor table (IDT) installation and exception handling
- LAPIC timer programming and preemptive scheduling
- TLB shootdown IPI integration

---

## Summary

**R8 is complete.** The PaideiaOS kernel boots from PVH, transitions to long mode, initializes UART output, mints and invokes capabilities, and successfully executes an SPSC IPC channel end-to-end. All audit entries are in place, all tests pass, and the fingerprint harness gates further commits.

The foundation is solid for Phase 2+ work: real-world driver integration, memory management, scheduler reactivation, and multi-threaded workloads.
