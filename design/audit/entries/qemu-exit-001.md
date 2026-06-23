---
audit_id: qemu-exit-001
issue: 324
file: src/kernel/boot/qemu_exit.pdx
function: qemu_exit_success, qemu_exit_failure
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-22
---

# AUDIT qemu-exit-001 — qemu_exit_success / qemu_exit_failure

## Justification

QEMU isa-debug-exit device port write at 0xF4 (I/O port space). The `out 0xF4, al`
instruction is a privileged I/O operation (sysreg effect) that terminates QEMU with
a specific exit code per the byte written.

### qemu_exit_success

Writes 0x10 to port 0xF4; QEMU interprets this as exit code (0x10 << 1) | 1 = 33
(decimal), marking clean kernel completion. Called from kernel_main once the boot
sequence finishes (Phase B4 work item).

### qemu_exit_failure

Writes 0x11 to port 0xF4; QEMU interprets this as exit code (0x11 << 1) | 1 = 35
(decimal), marking kernel failure. Available for exception handlers or fatal paths
that need immediate termination.

## Implementation notes

Both functions use `out 0xF4, al` encoding:
- Opcode: 0xE6 (direct I/O port write, immediate port field)
- Operand: AL register (1-byte value)
- Expected encoded size: 2 bytes (port byte + opcode)

**Mnemonic status:** paideia-as v0.9.0 supports `out port, al/ax/eax` via the Phase-5 m2
encoder (I/O port instructions). Operand `out 0xF4, al` is a direct-port variant.

## Spec reference

- Intel SDM Vol 2B §1, page 779 (OUT instruction), variant with direct I/O port.
- QEMU isa-debug-exit device (QEMU source: hw/misc/debugexit.c), exit code formula: `(value << 1) | 1`.

## Callsites (Phase B4+)

Once kernel_main is wired to call this function at boot completion, the kernel
will gracefully exit the QEMU simulation with deterministic exit code. Smoke test
tools/run-smoke.sh interprets exit code 33 as success.
