# VEX Prefix Encoding for AVX2

**Phase**: R18 (v0.18 SEMANTIC-DS milestone)
**Issue**: PA-R18-011 (#1004) — AVX2 baseline for hash-table probe
**Status**: DELIVERED (v0.18 close)

## 1. Motivation

AVX2 (Advanced Vector Extensions 2) is required for efficient vectorized operations on 256-bit data, especially for SIMD-based search and comparison workloads. The hash-table metadata probe (comparing 16 bytes of metadata in parallel) is a canonical use case targeted for v0.19+ integration.

This document specifies the encoder substrate (v0.18) that makes AVX2 instruction encoding possible. The actual vectorized probe remains v0.19+ work once real application workloads justify the cost of designing a raw-asm YMM-clobber discipline in the ABI (see Deferred, below).

Reference: paideia-as-tactical-issues.md §8.3 (v0.20 WASM/SIMD lowering).

## 2. VEX Prefix Overview

VEX (Vector Extensions) is the prefix encoding used by AVX/AVX2/AVX-512 instructions to encode vector operands and escape codes.

### 2.1 Two-Byte VEX Form (C5)

Used when no high-register extensions (R, X, B) or 64-bit operand (W) are needed.

```
C5 RvvvvLpp

R      [bit 7] = NOT(ModR/M.reg high bit) — inverted destination register high bit
vvvv   [bits 6:3] = 1's complement of second register (src1)
L      [bits 2:1] = Vector length: 0=128-bit, 1=256-bit
pp     [bits 0] = Packed prefix: 0=none, 1=66h, 2=F3h, 3=F2h
```

Opcode map is always 0F (single-byte escape); no explicit 0F byte emitted.

### 2.2 Three-Byte VEX Form (C4)

Required when R, X, B, W, or non-0F opcode maps are needed.

```
C4 RXBmmmmm Wvvvv Lpp

First byte:
R      [bit 7] = NOT(ModR/M.reg high bit)
X      [bit 6] = NOT(SIB.index high bit)
B      [bit 5] = NOT(ModR/M.r/m or SIB.base high bit)
mmmmm  [bits 4:0] = Map select:
                    1 = 0Fh escape (single-byte)
                    2 = 0F 38h escape (two-byte)
                    3 = 0F 3Ah escape (two-byte)

Second byte:
W      [bit 7] = 64-bit operand size (0 for AVX2 SIMD)
vvvv   [bits 6:3] = 1's complement of second register
L      [bits 2:1] = Vector length (0=128-bit, 1=256-bit for AVX2)
pp     [bits 0] = Packed prefix (same as 2-byte form)
```

## 3. Opcode Map Selection

The opcode map (mmmmm field) determines which escape sequence is used:

| mmmmm | Escape | Byte sequence |
|-------|--------|---------------|
| 1     | 0Fh    | Single 0F     |
| 2     | 0F 38h | Two bytes     |
| 3     | 0F 3Ah | Two bytes     |

**For all v0.18 mnemonics (Vpxor, Vpcmpeqb, Vpmovmskb, Vmovdqu)**: map_select = 1 (0Fh single-byte escape).

## 4. RegId Encoding for YMM Registers

### 4.1 RegId Space

The IR's compact `RegId(u8)` namespace reserves band 37–52 for YMM0–YMM15:

```
RegId 0–15:   GPR (rax–r15)
RegId 16–24:  Control registers (cr0–cr8)
RegId 25–32:  Debug registers (dr0–dr7)
RegId 33–36:  Extended low-byte GPRs (spl, bpl, sil, dil)
RegId 37–52:  YMM registers (ymm0–ymm15)
```

### 4.2 VEX Bit Encoding

When encoding a YMM register into VEX prefix fields:

1. Extract register index: `ymm_id = regid - 37` (range 0–15)
2. Low 3 bits → ModR/M reg/rm field: `ymm_id & 0x07`
3. High bit → inverted into VEX.R, VEX.X, or VEX.B:
   - If `ymm_id & 0x08 == 0` (reg 0–7): corresponding VEX bit = 1
   - If `ymm_id & 0x08 != 0` (reg 8–15): corresponding VEX bit = 0

### 4.3 Why Not Enum Widening?

RegId remains `struct RegId(u8)` without an enum breaking change. Rationale:

- No change to `Operand::Reg(RegId)` storage footprint
- All existing GPR encoder helpers (`reg_id & 7` masking) continue to work
- Avoids 50+ site changes in every `Operand` consumer
- YMM sites are raw-asm only in v0.18; no safe-mode type checking needed

## 5. Interaction with Other Prefixes

### 5.1 LOCK / REP Collision

VEX prefixes (C4/C5) do **not** collide with LOCK (F0), REP (F3), or REPNE (F2) at the byte level in practice:

- LOCK is Group 1, always emitted first per Intel SDM Vol 2A §2.1.1
- REP/REPNE are Group 1 (F2/F3), but AVX2 instructions using these bytes use them in the VEX.pp field (packed prefix), not as separate prefix bytes
- **Interaction**: For v0.18, no instruction uses both LOCK and VEX. Future cross-encoder work must document the precedence in a collision matrix (see Follow-up Work, below).

### 5.2 Segment Prefixes

Segment overrides (2E, 36, 3E, 26, 64, 65) are not compatible with VEX. The encoder rejects segment + VEX instruction pairs at encode time (not yet implemented in v0.18, deferred to v0.19 if needed).

## 6. Instruction Encoding Table

| Mnemonic  | Opcode | VEX.pp | pp bits | Form | Example |
|-----------|--------|--------|---------|------|---------|
| vpxor     | EF     | 66h    | 01      | 3-op | C5 FD EF C0 (ymm0, ymm0, ymm0) |
| vpcmpeqb  | 74     | 66h    | 01      | 3-op | C5 FD 74 C0 (ymm0, ymm0, ymm0) |
| vpmovmskb | D7     | 66h    | 01      | 2-op | C5 FD D7 C0 (eax, ymm0) |
| vmovdqu   | 6F/7F  | F3h    | 10      | 2-op | C5 FE 6F 00 (ymm0, [rax]) |

All use map_select = 1 (single-byte 0Fh escape).

**iced-x86 Correspondence**: All four mnemonics are natively decoded by iced-x86 1.x (`iced_x86::Mnemonic::Vpxor`, etc.); no version bump required.

## 7. Follow-up Work

### 7.1 XMM (128-bit) Siblings

v0.18 scope was YMM only (256-bit). XMM equivalents (128-bit vector registers) using the same VEX encoding are deferred to v0.19. They share the same prefix logic; only the L bit (length) changes.

### 7.2 Safe-Mode YMM Types

v0.18 YMM operands are raw-asm only (no type checking). Safe-mode YMM operand types (struct-field spillage, safe SIMD operations) are deferred to v0.19+.

### 7.3 ABI Callee-Save Contract

SysV x86-64 ABI defines XMM/YMM as caller-saved. Encoder support alone does not require ABI extensions; raw-asm unsafe blocks are responsible for YMM clobber discipline. If future code patterns require callee-saved YMM (e.g., library call boundaries), ABI plumbing is a separate v0.19+ workstream.

### 7.4 LOCK/REP/Segment Collision Matrix

Document the full precedence rules for prefix combinations:
- When LOCK + VEX is encountered: error or serialize to separate instructions?
- When REP/REPNE + VEX is encountered: clarify whether VEX.pp encodes the semantic (e.g., F3h movdqu) or the bits conflict.
- Segment + VEX: reject at encode time.

This matrix belongs in a follow-up encoder architectural note once patterns emerge from v0.19 workloads.

## References

- Intel 64 and IA-32 Architectures Software Developer Manual, Volume 2A (Instruction Set Reference A-M), §2.3 (Instruction Prefix)
- iced-x86 Decoder/Encoder library (1.x): https://github.com/0xd4d/iced
- paideia-as-tactical-issues.md §8.3 (v0.20 WASM/SIMD lowering substrate)
