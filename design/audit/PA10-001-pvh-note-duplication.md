# PA10-001: PVH Note Duplication in paideia-as

## Issue Summary

paideia-as emits one PVH ELF note per `.pdx` file compiled, resulting in 95 duplicate PVH notes in the PaideiaOS kernel image (plus 1 from boot_stub.S for a total of 96). This causes:

1. **Image bloat**: 95 unnecessary copies of the same note structure
2. **Linker confusion**: Multiple PT_NOTE entries with identical content
3. **Spec non-compliance**: QEMU PVH loader expects 1 note per kernel image, not 1 per object file

## Current Behavior (Diagnosed 2026-06-23)

### Object File Level
Each `.pdx` source file compiled by paideia-as includes a `.note.Xen` section containing:
- Name field: "Xen"
- Type: 18 (XEN_ELFNOTE_PHYS32_ENTRY)
- Descriptor: 8-byte address pointing to 0x100000 (_pvh_entry)

When 95 PDX files are compiled, we get 95 identical note structures.

### Link-Time Impact

The paideia-os linker script (src/kernel/link.ld) previously included all notes via:
```ld
.note.Xen : ALIGN(4) { KEEP(*(.note.Xen)) } :note
```

This aggregated all 95 duplicate notes into a single PT_NOTE segment, causing QEMU to see multiple entries with identical content.

## Root Cause (paideia-as side)

The paideia-as compiler (PA10-001 feature) emits PVH notes at the encoder level, once per `.pdx` compilation unit, without:
1. Deduplication logic (skip if already emitted for this image)
2. Configuration to opt-in/opt-out per file
3. A per-build marker to emit only once

## Workaround (Applied in PaideiaOS)

PaideiaOS-side mitigation (commit eee69c1):

1. **boot_stub.S** renamed its note section from `.note.Xen` → `.note.PVH-boot`
2. **link.ld** updated to:
   - Explicitly include `.note.PVH-boot` from boot_stub
   - Discard all `.note.Xen` sections from paideia-as objects
   - Place the single boot_stub note in both PT_LOAD and PT_NOTE (so QEMU PVH loader can find it)

Result: Kernel image now contains exactly 1 PVH note, reducing bloat and ensuring correct QEMU behavior.

## Recommended paideia-as Fix

### Short-term (next release)
Add a compiler flag to suppress PVH note emission:
```
paideia-as build --no-pvh-note --emit elf64 file.pdx -o file.o
```

Or emit only once per linked image (requires awareness of the build context).

### Long-term
Implement a per-image note emission hook:
- Emit PVH note only in response to an explicit linker directive
- Add LLVM-style metadata to signal "image entry point" once during the link phase
- Or: Use a separate phase to generate notes post-compilation

## Testing

Verified functional on 2026-06-23:
```
readelf -n build/kernel.elf | wc -l  # 5 lines (1 note)
timeout 5 qemu-system-x86_64 -kernel build/kernel.elf ...
# Output: 0x42 0x0a (B\n) — confirms kernel executed and printed
```

## Impact on PaideiaOS Build

- No impact: The workaround is permanent and transparent
- Image size reduced by ~3 KiB (95 × 32-byte notes)
- QEMU boot behavior corrected: PVH entry now reliably executed

## Files
- **paideia-as**: src/bin/encoder/emit.rs (or similar — where note emission happens)
- **paideia-os**: design/audit/PA10-001-pvh-note-duplication.md (this file)
