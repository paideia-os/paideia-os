---
audit_id: r9-m1-002-idt-install
issue: 352
file: src/kernel/core/int/idt.pdx
function: idt_install, idt_lidt
effects: [sysreg, mem]
capabilities: [boot]
reviewed_by:
date: 2026-06-24
---

# AUDIT r9-m1-002-idt-install — Real IDT install with lidt + entry packing

## Overview

R9-m1-002 implements a real interrupt descriptor table (IDT) installation procedure. The kernel now:

1. Allocates 256 IDT entries (4096 bytes, page-aligned) in `_idt_storage`
2. Packs each entry with the proper x86-64 format (word0 + word1, 16 bytes total)
3. Builds an 10-byte IDTR descriptor (limit + base) in `_idt_descriptor`
4. Loads the IDT via the `lidt` privileged instruction
5. Prints "IDT OK" to confirm successful installation

This is the foundational work for interrupt and exception handling. Per-vector handler installation is deferred to R9-m1-003 (when `_isr_default` and per-vector trampolines exist).

## Justification

### Memory safety: Entry packing

The IDT entry packing arithmetic is ordinary typed computation:

```
word0 = offset_lo(16) | selector(16)<<16 | ist(8)<<32 | type(8)<<40 | offset_mid(16)<<48
word1 = offset_hi(32) | reserved(32)<<32
```

These operations run in the paideia-as typed surface (no `unsafe` blocks required for arithmetic). Only the final register load (`lidt`) is unsafe.

### Unsafe: `lidt` instruction

`idt_lidt` loads the IDTR (interrupt descriptor table register) with a 10-byte descriptor:
- Bytes 0-1: limit (u16) — number of bytes in IDT - 1 (4095 for 256 × 16-byte entries)
- Bytes 2-9: base address (u64) — linear address of the first IDT entry

The `lidt [rdi]` instruction is privileged (requires ring 0) and changes CPU behavior:
- All subsequent interrupt and exception vectors dispatch via the new IDT
- Loading an invalid or incomplete IDT will cause triple-fault on first interrupt
- The IDT must be page-aligned and correctly formatted, per Intel SDM Vol 3A §6.10

**Capability:** The `lidt` instruction requires the `boot` capability (privileged firmware operation).

**Verification:** Execution is via QEMU; QEMU accepts any properly-formatted IDT and correctly dispatches vectors.

### Honest scope for MVP (R9-m1-002)

All 256 IDT entries are packed identically:
- offset = 0 (will be wired to real handlers in m1-003)
- selector = 0x08 (kernel code segment)
- IST = 0 (no interrupt stack table; all vectors use kernel stack)
- type = 0x8E (present, DPL=0, 64-bit interrupt gate)

This means the kernel will triple-fault if an interrupt or exception fires before m1-003 installs real handlers. To avoid this, the boot sequence (kernel_main_64) must:

1. Complete all initialization without taking exceptions
2. Call `idt_install` only when ready to accept interrupts
3. Immediately install real handlers (m1-003) before unmasking interrupts

For the current MVP, no interrupts are taken (CLI is set, LAPIC is not initialized), so this is safe.

## Implementation details

### Storage layout

```pdx
pub let mut _idt_storage : [u64; 512] = uninit    // 256 entries × 16 bytes = 4096 bytes
pub let mut _idt_descriptor : [u64; 2] = uninit   // 10-byte descriptor (bytes 0-1 = limit, bytes 2-9 = base)
```

### Descriptor format

The IDTR descriptor is 10 bytes:

```
Offset   Bytes     Meaning
0-1      [u16]     Limit (IDT size - 1; 4095 for 256 entries)
2-9      [u64]     Base address (linear address of first IDT entry)
```

In our code, `_idt_descriptor` is two u64 words; the first word carries the limit in its low 16 bits, and the base is stored starting at offset 2 (byte-aligned).

### Entry format (16 bytes, two u64 words)

Intel SDM Vol 3A §6.14.1 (64-bit IDT gate descriptor):

```
Bits      Field
0-15      offset[0:15]         (low 16 bits of handler offset)
16-31     selector             (code segment selector)
32-39     IST                  (interrupt stack table index)
40-47     type_attr            (0x8E = present, DPL 0, 64-bit interrupt gate)
48-63     offset[16:31]        (middle 16 bits of handler offset)
64-95     offset[32:63]        (high 32 bits of handler offset)
96-127    reserved             (must be 0)
```

In our packing:

```
word0 = offset[0:15] | (selector << 16) | (ist << 32) | (type_attr << 40) | (offset[16:31] << 48)
word1 = offset[32:63]
```

For MVP (all entries at offset 0), the packed values are:

```
word0 = 0x0000 | (0x08 << 16) | (0 << 32) | (0x8E << 40) | (0 << 48) = 0x8E00_0800
word1 = 0x0000_0000
```

### Build loop

The loop:
1. Iterates RCX from 0 to 255 (vector count)
2. Computes the entry offset in `_idt_storage` as `rcx * 16`
3. Packs word0 (constant 0x8E00_0800 for MVP)
4. Stores word0 and word1 via qword stores to `_idt_storage[offset]`
5. Increments vector counter and continues

### lidt instruction

Per Intel SDM Vol 3A §6.10, `lidt [rdi]` loads the IDTR from the 10-byte descriptor pointed to by RDI. The descriptor must be naturally aligned (in our case, it is, since `_idt_descriptor` is `[u64; 2]`, which is 16-byte aligned).

## Citation

- Intel SDM Vol 3A, Part 1, §6.10 (Interrupt Descriptor Table)
- Intel SDM Vol 3A, §6.14.1 (64-Bit IDT Gate Descriptor Format)
- x86-64 calling convention (RDI = first argument)

## Verification

Build and run:

```bash
rm -rf build && bash tools/build.sh 2>&1 | tail -3
timeout 5 qemu-system-x86_64 -kernel build/kernel.elf -display none -serial stdio -no-reboot -m 256M >/tmp/q.out 2>&1
head -8 /tmp/q.out
```

Expected output (first 8 lines):

```
B
PaideiaOS R8
CAP OK
IPC OK
IDT OK
```

If the output stops before "IDT OK", the IDT installation failed. Common causes:
- Malformed descriptor (limit or base incorrect)
- Incorrect entry packing (offset, selector, IST, or type bits misaligned)
- qemu does not validate or load the IDTR (may emit no diagnostic)

## Future work (m1-003)

- Install per-vector handlers instead of a single stub offset
- Implement `idt_install_vector(vector: u64, handler_offset: u64)` to update individual entries
- Implement `_isr_default` stub that acknowledges the interrupt and halts
- Implement per-vector trampolines for exceptions 0, 3, 6, 8, 13, 14 and IRQs 32, 33
