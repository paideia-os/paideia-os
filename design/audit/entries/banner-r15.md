---
audit_id: banner-r15
issue: 270
file: src/kernel/boot/banner.pdx
function: banner (module-level constant declarations)
effects: []
capabilities: []
reviewed_by: Santiago
date: 2026-06-21
---

# AUDIT banner-r15 — Banner data layout (R1.5-005)

## Justification

Banner data layout for kernel boot message. Text:
```
"PaideiaOS R7 -- kernel_main reached. CPU 0. Halting.\n"
```

Dimensions: 53 printable + newline bytes, padded to 64 bytes (11 zero-padding).

### Data Layout

Declared as 8 packed u64 constants (little-endian, x86-64 ABI):
- `banner_chunk_0..7`: 8-byte chunks covering the 64-byte text array
- `banner_len`: u64 = 53 (printable length, excluding padding)

| Chunk | Bytes | ASCII Content | LE Value |
|-------|-------|---|---|
| 0 | 0-7 | "PaideiaOS" | 0x4f61696564696150 |
| 1 | 8-15 | "S R7 -- " | 0x202d2d2037522053 |
| 2 | 16-23 | "kernel_m" | 0x6d5f6c656e72656b |
| 3 | 24-31 | "ain reac" | 0x63616572206e6961 |
| 4 | 32-39 | "hed. CPU" | 0x555043202e646568 |
| 5 | 40-47 | " 0. Halt" | 0x746c6148202e3020 |
| 6 | 48-55 | "ing.\n" + pad | 0x0000000a2e676e69 |
| 7 | 56-63 | zero pad | 0x0000000000000000 |

## Implementation Status (R1.5-005)

**Honest scope:** paideia-as 0.6.0 parses array literal syntax [u8; 64] = [...] but does
not emit to .rodata/.data sections (limitation in m4-002/m4-003 data-section codegen).

**Workaround:** Declare as 8 packed u64 constants (register-resident). paideia-as emits
mov-immediate instructions for each chunk (movabs, 10-byte encoding each). These constants
are accessible via symbol lookup at link time and can be indexed via RIP-relative addressing
in kernel-main code.

**Full array literal support** (emit to .rodata with proper relocation) deferred to
paideia-as m5-001 (data-section emitter, planned Phase 3).

### Mnemonic Encoding Status

- `movabs $0x4f61696564696150, %rax`: m2-004 (64-bit immediate), 10 bytes + 1-byte mnemonic
- Array literal [u8; 64] parsing: Successful (AST node created)
- Array codegen to .rodata: Deferred (m5-001, Phase 3)

## Blocking Issues

- paideia-as #714: Array-literal codegen to data sections (m5-001, Phase 3)

## Linker Integration

At link time (ld -T link.ld), the 8 banner_chunk_* symbols are resolved via relocation.
Kernel_main_64 can reference banner via:
```
extern banner : &[u8; 64];  // future syntax
lea rax, [rel banner_chunk_0]  // RIP-relative, x86-64
```

Currently (Phase 1), cross-module constant references require manual symbol exports in link.ld.

## Verification

```bash
./tools/paideia-as build --emit elf64 src/kernel/boot/banner.pdx -o banner.o
objdump -s banner.o | grep -A 10 "rodata"
# Output should show: banner_chunk_0..6 text bytes + banner_len (0x35)
```

Expected .rodata contents: 64 bytes of banner text + one u64 for banner_len.
Actual: Mixed in .text and .rodata due to mov-immediate codegen strategy.

## Citation

x86-64 ABI: Little-endian byte order, 8-byte word alignment.
PaideiaOS Phase 1 boot message format: printable text + NUL terminator + padding.
