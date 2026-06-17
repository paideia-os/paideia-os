# PaideiaOS — paideia-link and the PAX Binary Format

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Specification of the `paideia-link` linker and the PAX (PaideiaOS Application eXecutable) binary format consumed by it. Addresses AS8 from `custom-assembler.md`. Covers the file format, capability-binding sites, functor closure info, effect-signature annotations on exports, linker phases, and the relationship to ELF and PE/COFF.

**Hard inputs:**
- `custom-assembler.md` §5 (E2 PAX format), §12 (object-file emission with PaideiaOS-specific sections).
- `capabilities/linearity-and-tags.md` — capability descriptor layout; LAM tag layout.
- `ipc/wait-free-dataflow.md` — functor-typed channels referenced as capability bindings.
- `kernel/memory-model.md` — page-table-as-capability; the loader establishes initial mappings.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| PL-D1 | Format name: **PAX** (PaideiaOS Application eXecutable) | Distinct from ELF/PE/COFF; identifies PaideiaOS-native binaries |
| PL-D2 | File extension: `.pax` | Conventional |
| PL-D3 | Container: a binary structure with a fixed header + indexed sections | Standard pattern |
| PL-D4 | Capability binding sites recorded in `.paideia.caps` section, consumed at load by the supervisor | Capability discipline foundation |
| PL-D5 | Functor closure info recorded in `.paideia.functors`, resolved at link-time or load-time | Q-A7 functor support |
| PL-D6 | Effect-signature annotations on every export in `.paideia.effects` | Q-A3 effect-row preservation across boundaries |
| PL-D7 | Linker phases: parse → resolve → relocate → emit | Standard 4-phase linker |
| PL-D8 | ELF and PE/COFF are alternate emission targets, but PAX is the canonical format for PaideiaOS-native processes | §12 binding |
| PL-D9 | Linker is `paideia-link`, in the same repo as `paideia-as` | Tightly coupled |
| PL-D10 | PAX is **PQ-signed** by the release-line key per `security/pq-trust-root.md` | Trust chain to root |

---

## 1. PAX file format

### 1.1 Header

```
Offset  Size  Field
0       4     Magic: "PAX\x01" (0x50 0x41 0x58 0x01)
4       2     Format version (currently 1)
6       2     Architecture: 0x0001 = x86_64
8       4     Header size
12      4     Flags: bit 0 = position-independent; bit 1 = PQ-signed; bit 2 = has-functors; bit 3 = has-runtime-deps
16      8     Entry-point file offset (or 0 if not executable on its own)
24      8     Section table offset
32      4     Section count
36      4     Section table entry size
40      8     String table offset
48      8     String table size
56      8     Build timestamp (Unix epoch nanoseconds)
64      32    BLAKE3 hash of all sections (canonical content hash, excluding the signature)
96      ~     PQ signature (hybrid Ed25519 + ML-DSA-65, ~3.4 KB; size declared)
```

The header is fixed-size (~96 bytes) plus a variable-size signature block (~3.4 KB).

### 1.2 Section types

| Type | Name | Contents |
|---|---|---|
| 0x01 | `.code` | Executable instructions (Intel x86_64 machine code) |
| 0x02 | `.rodata` | Read-only data |
| 0x03 | `.data` | Writable data, initialized |
| 0x04 | `.bss` | Writable data, zero-initialized (no contents in file) |
| 0x05 | `.paideia.caps` | Capability-binding-site records |
| 0x06 | `.paideia.effects` | Per-function effect-row annotations |
| 0x07 | `.paideia.functors` | Functor parameter/result signatures and closure data |
| 0x08 | `.paideia.unsafe` | Audit catalog of unsafe blocks |
| 0x09 | `.paideia.opt-passes` | Record of which optimization passes ran |
| 0x0A | `.paideia.lin` | Linearity-check witness data |
| 0x0B | `.debug.info` | DWARF debug info |
| 0x0C | `.debug.line` | DWARF line table |
| 0x0D | `.debug.frame` | DWARF frame info |
| 0x0E | `.debug.paideia.caps` | PaideiaOS DWARF extension for capabilities |
| 0x0F | `.debug.paideia.effects` | PaideiaOS DWARF extension for effects |
| 0x10 | `.symtab` | Symbol table |
| 0x11 | `.relocs` | Relocation records |
| 0x12 | `.imports` | Required runtime services (capabilities) |
| 0x13 | `.exports` | Provided services (capabilities) |
| 0x14 | `.metadata` | Schema-typed structured metadata (build info, version, dependencies) |

### 1.3 Section table entry

```
Offset  Size  Field
0       2     Type (from §1.2)
2       2     Flags: bit 0 = present-in-file; bit 1 = writable; bit 2 = executable
4       4     Name index (into string table)
8       8     File offset (or 0 if not present in file, e.g., .bss)
16      8     Virtual address (where the loader maps it; 0 for non-loadable sections)
24      8     Size on disk
32      8     Size in memory
40      8     Alignment requirement (power of 2)
```

Each section table entry is 48 bytes.

---

## 2. Capability-binding sites (`.paideia.caps`)

### 2.1 Format

Each entry describes a place in the code where a capability is *required at execution*. The supervisor uses this section to mint capabilities at load.

```
Offset  Size  Field
0       4     Site id
4       4     Kind id (PaideiaOS base kind: memory, ipc-endpoint, port, irq, etc.)
8       4     Rights bitmask (initial)
12      4     Linearity class (ordered=0, linear=1, affine=2, unrestricted=3)
16      8     Symbol name (string table index)
24      8     Description (string table index)
32      4     Schema id (for derived kinds via functor application; 0 if base)
36      4     Reserved
```

Each entry is 40 bytes.

### 2.2 Resolution

At load:
1. The supervisor reads the `.paideia.caps` section.
2. For each binding site, the supervisor checks the loader's policy.
3. If the policy permits, the supervisor mints a fresh capability with the declared kind + rights.
4. The capability is recorded in the process's CSpace at the indicated symbol.
5. If the policy denies, the loader fails with audit log entry.

---

## 3. Effect signatures on exports (`.paideia.effects`)

### 3.1 Format

Each entry annotates an exported function with its effect row:

```
Offset  Size  Field
0       4     Function id (symbol table index)
4       4     Effect-row data offset (into the effect-row encoded data)
8       4     Effect-row size
12      4     Required-cap-set offset
16      4     Required-cap-set size
20      4     Linearity-class encoding for arguments (4 bits each, up to 8 args)
24      8     Reserved
```

The effect row is encoded as a sequence of effect-id values (each 16 bits) terminated by 0xFFFF.

### 3.2 Use

A consumer of an exported function checks its effect row at link time:
- If the function's effects are not a subset of the caller's authorized effects, link fails.
- If the function requires capabilities the caller does not hold, link fails.

This is the static effect-checking at link granularity (per the substructural type system's whole-program rule).

---

## 4. Functor closure info (`.paideia.functors`)

### 4.1 Format

A functor's `.pax` carries:
- The functor's parameter signatures (one per parameter).
- The functor's result signature.
- The functor's closure data (for partial applications).

```
Offset  Size  Field
0       4     Functor id (symbol table index)
4       4     Parameter count
8       4     Parameter signatures offset (into a sub-section of structured signature data)
12      4     Result signature offset
16      4     Closure data offset (or 0 if no closure)
20      4     Closure data size
24      8     Reserved
```

### 4.2 Resolution

At link or load time:
1. The linker resolves functor applications by reading the functor's signature.
2. The applied arguments' signatures are checked for compatibility.
3. If compatible, the resulting structure is constructed (or recorded for late resolution).

Functor applications can be resolved either at link time (fully-applied functors become regular modules) or at load time (partial applications resolved against runtime services).

---

## 5. Imports and exports

### 5.1 Imports (`.imports`)

A PAX may require services from other components. Each import:

```
Offset  Size  Field
0       4     Service name (string table)
4       4     Schema name (string table)
8       4     Required version (encoded)
12      4     Reserved
```

At load, the supervisor resolves each import against the running services. Missing imports are a load failure (configurable: allow soft-fail for optional imports).

### 5.2 Exports (`.exports`)

A PAX may provide services to other components:

```
Offset  Size  Field
0       4     Service name (string table)
4       4     Schema name (string table)
8       4     Provided version
12      4     Reserved
```

At load, the supervisor registers each export in the service registry.

---

## 6. `paideia-link` — the linker

### 6.1 Phases

```
Input: one or more PAX or .o (relocatable) files
Output: a single PAX file

Phase 1: Parse
  For each input file, read its sections, symbol table, relocs, and effect/cap/functor metadata.

Phase 2: Resolve
  For each symbol reference:
    Look up the symbol in the union of input symbol tables.
    If not found, look up in the imports.
    If still not found, error.
  For each functor application:
    Resolve to a concrete module if possible.
  For each effect-row constraint:
    Check that the providing function's effects are a subset of the consumer's expected effects.
  For each capability-binding site:
    Verify the kind and rights against what the supervisor will permit (optional pre-check).

Phase 3: Relocate
  Compute final addresses for each section.
  Apply relocations to code and data.
  Generate PIC stubs if needed.
  Build final symbol table.

Phase 4: Emit
  Construct the output PAX file header.
  Concatenate sections.
  Compute the BLAKE3 hash.
  Sign with the release-line key (PQ + classical hybrid).
  Write the output file.
```

### 6.2 Multi-target emission

`paideia-link` can emit:
- PAX (default)
- ELF64 (for kernel images and debugging)
- PE/COFF (for `paideia-loader.efi` UEFI loader)

The emission backend is selected by `--emit pax|elf64|pe-coff`.

### 6.3 Optimization at link time

`paideia-link` runs link-time optimization:
- Dead-code elimination (removes unused functions).
- Dead-data elimination.
- Section consolidation.
- Layout optimization for cache friendliness.

These are *not* the `#[peephole]` etc. opt-passes from `custom-assembler.md` §6.4 — those are per-function annotations at assembly time. Link-time optimization is across-translation-unit.

### 6.4 LTO interaction with capabilities

Link-time optimization must preserve the capability-binding sites; eliminating dead code that has cap-binding sites would silently change the runtime requirements. LTO must not remove a function with a `.paideia.caps` entry without also removing the entry.

### 6.5 PQ signing

The final PAX is signed:
1. Compute BLAKE3 of all sections (excluding the signature itself).
2. Submit to the supervisor's release-line signing service.
3. The signature is written into the header.

The signature is verified at load by every consumer.

---

## 7. Loading

### 7.1 Loader operations

A PaideiaOS process loader (typically the supervisor):

```
1. Open the .pax file (via FS cap).
2. Verify the PAX header (magic, version, architecture).
3. Verify the PQ signature against the release-line public key.
4. Verify the BLAKE3 hash matches.
5. Read the section table.
6. For each loadable section:
     a. Allocate memory (retype memory caps).
     b. Map at the section's virtual address.
     c. Copy bytes from file to memory.
7. Apply load-time relocations (RIP-relative addresses adjusted).
8. Read the .paideia.caps section.
9. For each binding site:
     a. Mint a capability of the declared kind with the declared rights.
     b. Install in the process's CSpace.
10. Read .imports; resolve each.
11. Read .exports; register each in the service registry.
12. Jump to entry point.
```

### 7.2 Error handling

Each step can fail. Failures are audited; the process is not started.

---

## 8. Examples

### 8.1 A minimal "hello world" PAX

```
Sections:
- .code (1 KiB, executable)
- .rodata (256 bytes, includes the "hello\n" string)
- .paideia.caps (1 entry: stdout capability)
- .paideia.effects (1 entry: main function effects = !{audit_log})
- .symtab (1 symbol: main, the entry point)
- .imports (1 import: audit-log channel)
- .exports (none)
- .metadata (build info)
```

### 8.2 A driver PAX

```
Sections:
- .code (50 KiB)
- .rodata (2 KiB)
- .data (1 KiB)
- .bss (16 KiB)
- .paideia.caps (3 entries: MMIO regions, IRQ vector, audit cap)
- .paideia.effects (many: every entry point with its effect row)
- .paideia.functors (the driver is a functor over PCI and MMIO signatures)
- .imports (PCI bus driver service)
- .exports (this driver's NIC service)
- ...
```

---

## 9. Open issues

| ID | Issue |
|---|---|
| PL-O1 | The exact encoding of functor parameter signatures — needs a normative ABI document. |
| PL-O2 | Compression of large sections (PAX can become large for drivers with many embedded firmware blobs) — possibly Zstd. |
| PL-O3 | Cross-architecture PAX (ARM64, RISC-V) — out of phase 1–2 scope; format must accommodate. |
| PL-O4 | Lazy-loading sections (mmap-style on-demand) for very large PAXes — phase 3+. |
| PL-O5 | Whether `.paideia.functors` is resolved at link or load — currently both supported; pick a default. |
| PL-O6 | PAX runtime version tags for hot-reload (Q14 handoff) — needs design. |
| PL-O7 | The `.metadata` schema — what fields are mandatory, what optional. |

---

*End of document.*
