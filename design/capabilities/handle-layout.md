# PaideiaOS Capability Handle Layout (Phase 2.5)

**Author:** R2.5-005 implementation  
**Date:** 2026-06-21  
**Status:** Phase 2.5 (PA7 surface, placeholder bytes)

## Overview

Capability handles are 64-bit values encoding a (generation, slot) pair into a LAM-aware (Linear Address Masking) layout. This document specifies the bit-layout and verification properties per Pillar 1 (LAM-tagged pointer scheme) and Pillar 10 (functional discipline: linear capabilities).

## Handle Bit Layout

```
Bits 63-60: generation (4 bits, in software fallback; full 8 bits in hardware LAM)
Bits 59-48: reserved/future expansion (12 bits)
Bits 47-0:  slot index (48 bits, but only lower 8 bits used: [0, 255])
```

### Encoding Formula

```
handle = ((generation & 0xF) << 60) | (slot & 0xFF)
```

### Decoding Formula

```
generation = (handle >> 60) & 0xF
slot = handle & 0xFF
```

## Phase 2.5 Software Fallback

In Phase 2.5, hardware LAM (Intel Linear Address Masking) is **not yet enabled**. The handle encoding uses a software-fallback scheme that preserves the bit-layout for when LAM is activated in Phase 3+ (per design/infrastructure/phase-2-entry.md Q3).

### Tag Bit Width Justification

- **Generation:** 4 bits (16 possible generations). Phase 2 wraps on overflow; Phase 8+ implements per-descriptor generation trees with overflow handling.
- **Reserved:** 12 bits. Available for future expansion of the generation epoch or new metadata fields.
- **Slot:** 8 bits (256 slots). Matches CAP_SLAB_CAPACITY in `src/kernel/core/cap/slab.pdx`.

## Verification Procedure

Upon capability invocation or use, the kernel verifies:

1. **Slot Bounds:** `slot < 256` (via mask `& 0xFF` automatically ensures this).
2. **Generation Match:** Retrieve descriptor at `&slab[slot]`, read `descriptor.generation`, compare with tag's generation. If mismatch → stale handle → INVALID.
3. **Kind Check:** Read `descriptor.kind` and verify it matches the expected kind for the operation.

See `src/kernel/core/cap/verify.pdx` for the verification implementation.

## Hardware LAM Integration (Phase 3+)

When hardware LAM becomes available:

1. The bit-layout **must remain unchanged** to ensure compatibility.
2. Intel LAM will enforce the high-bit masking in hardware, making the kernel's manual masking in `cap_verify` redundant (but kept for safety).
3. Addresses with valid capability tags will automatically pass LAM checks; invalid tags will trap.

**Reference (pending verification):** Intel TDX Module Specification §2.1, Intel CET Architecture Specification §3.4. See `[[reference-tbd]]` in the PR description.

## Implementation Status

- **Phase 2.5:** Software encoding/decoding in `src/kernel/core/cap/handle.pdx` (PA7-005 complete).
- **Phase 3+:** Hardware LAM probe and verification (Phase 8+ work).
- **Audit:** Escalation flag for hwman review before R7 closure per `src/kernel/core/cap/handle.pdx` comments.

## References

- `design/capabilities/linearity-and-tags.md` §5 (LAM encoding rationale)
- `design/infrastructure/phase-2-entry.md` Q3 (software fallback justification)
- `src/kernel/core/cap/handle.pdx` (PA7 implementation)
- `src/kernel/core/cap/verify.pdx` (verification logic)
