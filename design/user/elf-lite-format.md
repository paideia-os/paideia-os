# ELF-lite Format Specification (R15.M1+)

## Purpose

Frozen minimal ELF64 subset that paideia-os accepts for user binaries. The R15.M1 loader (`elf_lite_load` in #517) parses only this subset to simplify kernel implementation without sacrificing portability.

## Scope

- Applies to R15+ user binaries only.
- Kernel enforces strict ELF64 subset for simplicity.
- Later releases may relax constraints as needed.
- All user processes must conform to this specification.

## Required ELF64 Header Fields

| Field | Offset | Size | Value | Description |
|-------|--------|------|-------|-------------|
| e_ident[0:3] | 0 | 4B | 0x7F, 'E', 'L', 'F' | ELF magic number |
| e_ident[4] (EI_CLASS) | 4 | 1B | 2 | ELFCLASS64 (64-bit) |
| e_ident[5] (EI_DATA) | 5 | 1B | 1 | Little-endian |
| e_ident[6] (EI_VERSION) | 6 | 1B | 1 | ELF version |
| e_ident[7] (EI_OSABI) | 7 | 1B | 0 | SYSV ABI |
| e_type | 16 | 2B | 2 | ET_EXEC (executable file) |
| e_machine | 18 | 2B | 0x3E | EM_X86_64 (x86-64) |
| e_version | 20 | 4B | 1 | ELF version (must be 1) |
| e_entry | 24 | 8B | VA | User entry point virtual address |
| e_phoff | 32 | 8B | offset | Program header table byte offset |
| e_phentsize | 54 | 2B | 56 | Program header entry size in bytes |
| e_phnum | 56 | 2B | count | Number of PT_LOAD entries (≥1) |

## Program Header Entry (PT_LOAD Only)

Each PT_LOAD segment occupies 56 bytes:

| Field | Offset | Size | Constraints |
|-------|--------|------|-------------|
| p_type | 0 | 4B | Must be 1 (PT_LOAD) |
| p_flags | 4 | 4B | See permitted combinations below |
| p_offset | 8 | 8B | File offset of segment data (must be valid) |
| p_vaddr | 16 | 8B | Virtual address to map to (no higher-half) |
| p_paddr | 24 | 8B | Physical address (usually equals p_vaddr; ignored) |
| p_filesz | 32 | 8B | Bytes to load from file |
| p_memsz | 40 | 8B | Bytes to allocate in memory (p_memsz ≥ p_filesz) |
| p_align | 48 | 8B | Alignment (typically 4096 for page size) |

## Rejection Rules

The kernel parser **MUST refuse** binaries matching any of:

- Any PT_LOAD with `p_vaddr >= 0xFFFF800000000000` (higher-half canonical range).
- Any PT_LOAD with `p_memsz < p_filesz` (invalid memory layout).
- Presence of PT_DYNAMIC or PT_INTERP program headers (no dynamic linking).
- Presence of SHT_REL or SHT_RELA section headers (no relocations).
- e_type other than ET_EXEC (2).
- Mismatched endianness or bitness.

## Permitted PT_LOAD Flag Combinations

Enforces W^X (write-execute exclusion) invariant:

| p_flags | Binary | Mnemonic | Purpose | Allowed |
|---------|--------|----------|---------|---------|
| 0x5 | PF_R ∪ PF_X | RX | Text segment | ✓ |
| 0x6 | PF_R ∪ PF_W | RW | Data/BSS segment | ✓ |
| 0x4 | PF_R | R | Read-only data (rodata) | ✓ |
| 0x7 | PF_R ∪ PF_W ∪ PF_X | RWX | (REJECTED: W^X violation) | ✗ |
| 0x3 | PF_W ∪ PF_X | WX | (REJECTED: W^X violation) | ✗ |
| 0x1 | PF_X | X | (REJECTED: no read) | ✗ |
| 0x2 | PF_W | W | (REJECTED: no read) | ✗ |

## Reference Implementation

- **Parser**: `elf_lite_parse()` (#516) — validates header, extracts segments.
- **Loader**: `elf_lite_load()` (#517) — maps validated PT_LOAD entries into user VAS.
- Both consume only this frozen subset; later issues may extend.

## Toolchain

R15.M1's `tools/build-user.sh` (#515) produces ELF-lite binaries via:

- **Assembler**: paideia-as (see paideia-as submodule).
- **Linker**: GNU ld with fixed linker script (`src/user/link.ld`).
- Script ensures compliance: single text segment (RX), single data segment (RW), no relocations.
