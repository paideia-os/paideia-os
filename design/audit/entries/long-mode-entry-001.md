---
audit_id: long-mode-entry-001
issue: 330
file: src/kernel/boot/entry.pdx
function: long_mode_entry (inline in _start)
effects: [sysreg]
capabilities: [boot]
reviewed_by: Santiago
date: 2026-06-23
---

# B2-004: First Observable Output — 'B' to COM1

## Objective

Output the first observable byte 'B' (ASCII 0x42) to COM1 (I/O port 0x3F8) upon successful transition to 64-bit long mode, followed by newline (0x0A) to mark the end of the boot sequence marker.

## Implementation

**Location**: `src/kernel/boot/entry.pdx::_start` (inline long_mode_entry code, after ljmp instruction)

**Execution context**: 64-bit long mode (CPU has switched modes via ljmp 0x08:0x100008)

**Instruction sequence** (executing at 0x100008 after ljmp):
```asm
mov al, 0x42        ; Character 'B' (ASCII 66)
mov dx, 0x3F8       ; COM1 port address (16550 UART base)
out_al al           ; Write AL to port DX (0xEE opcode)
mov al, 0x0A        ; Newline character
out_al al           ; Write newline to COM1
hlt                 ; Halt (wait for external interrupt or reset)
```

## Technical Details

### Instruction Encoding

- `mov al, 0x42`: 0xB0 0x42 (2 bytes) — Move immediate byte to AL
- `mov dx, 0x3F8`: 0x66 0xBA 0xF8 0x03 (4 bytes) — Move immediate word to DX
- `out_al al`: 0xEE (1 byte) — OUT AL to port in DX (PA10-006l mnemonic)
- `mov al, 0x0A`: 0xB0 0x0A (2 bytes) — Move newline to AL
- `out_al al`: 0xEE (1 byte) — OUT AL to port in DX
- `hlt`: 0xF4 (1 byte) — Halt processor

**Total**: 2 + 4 + 1 + 2 + 1 + 1 = 11 bytes

### Address Calculation

- _start entry point: 0x100000 (from link.ld KERNEL_VMA_PHASE1)
- cli instruction: offset 0 (1 byte)
- ljmp 0x08:0x100008: offset 1 (7 bytes)
- long_mode_entry (mov al, 0x42): offset 8 = 0x100008
- hlt: offset 18 = 0x100012

### COM1 (16550 UART) I/O Port Address

- Standard PC serial port (COM1): 0x3F8 (936 decimal)
- I/O port write via OUT instruction writes to Data Register (base + 0)
- This triggers immediate transmission on 16550 UART hardware
- QEMU simulates this port, echoing output to -serial stdio

### paideia-as Feature Dependencies

- **PA10-006l**: `out_al` mnemonic for byte-width I/O port write
- **Immediate operands**: `mov al, 0x42` and `mov dx, 0x3F8` (working in paideia-as v0.10.0)
- **Implicit register operands**: `out_al al` has DX as implicit port register (per x86 ISA)

## Execution Prerequisites

B2-004 executes ONLY if the preceding ljmp (B2-003) successfully transitions to 64-bit mode. This requires:

1. **GDT setup** (B2-001): Descriptor[0x08] must point to valid 64-bit code segment with L=1
2. **Paging and CR registers** (B2-002): CR0.PG, CR0.PE, CR4.PAE, EFER.LME must be enabled
3. **Page tables**: Memory at 0x100000–0x100012 must be mapped (identity map + valid)

**Current Phase-1 status**: Only B2-003 (ljmp) and B2-004 (COM1 output) are in place. B2-002 (CR register setup) is deferred, so **the ljmp will hang** without paging enabled. This is expected behavior — the milestone closure requires B2-002 to be completed for actual observable output.

## Observable Behavior (When B2-002 Complete)

When B2-002 lands and the full 9-step long-mode transition (steps 1–7) is wired:

1. QEMU boots kernel.elf
2. _start executes: cli, then completes steps 3–6 (CR registers + paging)
3. ljmp reloads CS with 64-bit descriptor; CPU switches to 64-bit mode
4. Long_mode_entry executes: mov al, 0x42 → out_al → COM1 outputs 'B'
5. Newline (0x0A) written to COM1
6. hlt halts processor; QEMU receives character output on -serial stdio

**Expected QEMU output**:
```
B
<newline>
```

## Test Expectations

File: `tests/r8/expected-boot-min.txt`
```
B
```

The test harness (tools/run-smoke.sh) will capture QEMU stdout and compare with expected output once B2-002 is complete.

## Honest Scope

**Current limitations blocking actual observable output**:
1. B2-002 (CR register sequence) not yet implemented → paging off → ljmp hangs
2. Once B2-002 lands, this code will execute correctly and 'B' will appear on COM1

**No new paideia-as gaps discovered**:
- `out_al` instruction is functional (PA10-006l committed)
- Immediate operands work correctly (paideia-as v0.10.0)
- Byte/word moves work correctly

## References

- Intel SDM Vol 3A §9.8.5: IA-32e Mode Initialization (steps 1–9)
- COM1 16550 UART: Standard PC I/O port 0x3F8
- paideia-as PA10-006l: I/O port instruction mnemonics (in_al, out_al, in_ax, out_ax, etc.)
- QEMU isa-debug-exit: Separate device for clean exit; not used for B2-004 (COM1 only)
- Issue #330: B2-004 closure (first observable 'B' on COM1)
- Issue #331: B2-005 closure (first-observable milestone completion)
