# PaideiaOS — paideia-as Debug Information (DWARF + Vendor Extensions)

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** DWARF 5 emission conventions and PaideiaOS-specific vendor extensions for capability and effect annotations. Addresses AS7 from `custom-assembler.md`.

**Hard inputs:**
- `custom-assembler.md` §12.4 — DWARF emission requirement; vendor extensions for capabilities and effects.
- DWARF Debugging Information Format, Version 5, DWARF Standards Committee, 2017.
- `capabilities/linearity-and-tags.md` — capability metadata that the extensions describe.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DBG-D1 | DWARF version: **5** | Modern; widely supported |
| DBG-D2 | Vendor identifier: `paideia` registered via DWARF 5 §7.4 vendor-extension encoding | Required by DWARF spec |
| DBG-D3 | Sections emitted: `.debug.info`, `.debug.line`, `.debug.frame`, `.debug.loc` mandatory; `.debug.aranges`, `.debug.str` optional but emitted | Standard set |
| DBG-D4 | PaideiaOS vendor extensions: `.debug.paideia.caps`, `.debug.paideia.effects` | Custom-assembler.md §12.4 |
| DBG-D5 | Source-span granularity: byte offsets, not line+column only | More precise; supports rich diagnostic display |
| DBG-D6 | Split debug info supported: `.debug.info.split` for stripping production binaries | Modern tool convention |
| DBG-D7 | Compression: Zstd for large debug sections | Standard option per DWARF 5 |

---

## 1. Standard DWARF sections

### 1.1 `.debug.info`

Contains the DIE (Debug Information Entry) tree describing compilation units, functions, types, variables. Standard DWARF 5 format.

PaideiaOS extensions:
- Function DIEs carry an additional `DW_AT_paideia_effects` attribute (vendor-defined, see §3).
- Variable DIEs of capability type carry `DW_AT_paideia_kind` and `DW_AT_paideia_class`.

### 1.2 `.debug.line`

The line table maps PC ranges to source positions. Standard DWARF 5.

PaideiaOS extension:
- Each entry includes byte offset within line (in addition to line/column) via `DW_LNS_set_paideia_byte_offset`.

### 1.3 `.debug.frame`

Frame description records (.debug_frame / CIE/FDE) for unwinder. Standard DWARF 5.

PaideiaOS extension:
- Frame includes whether R12/R13 (capability) and R14/R15 (effect) are saved at known offsets.

### 1.4 `.debug.loc`

Location lists. Standard DWARF 5.

---

## 2. PaideiaOS DWARF vendor encoding

Vendor identifier:

```
DW_VENDOR_paideia = (TODO: allocate; tentative 0xA0)
```

The 0xA0 reservation is project-internal until DWARF Standards Committee assignment.

Vendor attribute numbers use the range `DW_AT_lo_user .. DW_AT_hi_user` (0x2000 .. 0x3FFF):

```
DW_AT_paideia_effects        = 0x2100
DW_AT_paideia_kind           = 0x2101
DW_AT_paideia_class          = 0x2102
DW_AT_paideia_caps_required  = 0x2103
DW_AT_paideia_session_type   = 0x2104
DW_AT_paideia_handler_table  = 0x2105
DW_AT_paideia_unsafe         = 0x2106
```

---

## 3. `.debug.paideia.caps` (capability metadata)

### 3.1 Purpose

Lets a debugger (or `scripts/gdb/paideia.py`) decode capability handles at runtime: identify the kind, the rights, the LAM tag layout.

### 3.2 Format

A sequence of records, each describing a capability type:

```
Offset  Size  Field
0       4     Type id
4       4     Base kind (memory, ipc-endpoint, …)
8       4     LAM tag layout: bits used for epoch, kind hint, linearity, sealed
12      4     Rights bitmask layout (per-kind interpretation)
16      8     Schema name (.debug.str offset)
24      8     Reserved
```

### 3.3 Use by debugger

A debugger displaying register R12 (capability) consults this section:
- Reads the LAM tag bits from R12's high 15 bits.
- Looks up the kind in the table.
- Looks up the descriptor in kernel memory via the LAM-stripped pointer.
- Formats and displays.

---

## 4. `.debug.paideia.effects` (effect metadata)

### 4.1 Purpose

Lets a debugger display the effect environment R15 holds at each PC.

### 4.2 Format

A sequence of records, each describing an effect declaration:

```
Offset  Size  Field
0       4     Effect id
4       4     Effect name (.debug.str offset)
8       4     Operation count
12      4     Reserved
16      ~     Per-operation records:
              {
                 Op id    : u32
                 Op name  : u32 (string offset)
                 Op type  : u32 (type-signature offset)
              } repeated
```

### 4.3 Use by debugger

A debugger inspecting R15:
- Reads the effect-table-id (first 4 bytes of the table).
- Looks up the table layout in this section.
- For each effect, displays which handler is currently installed.

This is how `scripts/gdb/paideia.py` provides the "show effects" command.

---

## 5. Source-span emission

### 5.1 Resolution

Source spans are emitted at byte-granularity (not just line/column). The lexer records:
- File path (string-table offset).
- Start byte offset in file.
- Length in bytes.
- Equivalent line + column (for display compatibility).

### 5.2 Why byte-offset

Editor/LSP integration uses byte offsets. Line + column is fragile across encoding-aware tools (a multi-byte UTF-8 character occupies one column but multiple bytes). Both are emitted.

---

## 6. Split debug info

### 6.1 Purpose

Production PAX binaries strip debug sections to reduce size. The `.debug.info.split` mechanism allows debug info to live in a separate file (`*.pax.dwp`), keyed by a build-id.

### 6.2 Build ID

Every PAX has a 32-byte build-id (BLAKE3 of the canonical content). The split debug-info file is named `<build_id>.dwp`.

### 6.3 Loading

A debugger looking up debug info for an unstripped binary uses the in-PAX sections. For a stripped binary, it falls back to the `.dwp` file in the debug-info repository (configurable path).

---

## 7. Compression

`.debug.*` sections may be Zstd-compressed (level 19 for size). The DWARF 5 compression header indicates compression.

The toolchain emits compressed debug sections by default for release builds; uncompressed for debug builds.

---

## 8. Debugger integration

### 8.1 GDB Python scripts

`scripts/gdb/paideia.py` provides commands:
- `paideia caps` — show all capabilities in scope.
- `paideia effects` — show installed effect handlers.
- `paideia ipc` — show IPC channel state for the current process.
- `paideia replay` — load a `-icount rr` replay file and step.

The script reads PaideiaOS vendor extensions from `.debug.paideia.*` sections.

### 8.2 LLDB plugin

A future LLDB plugin will provide the same commands. Phase 3+ work.

### 8.3 LSP integration

The LSP server (per `custom-assembler.md` §11.3) consumes the vendor extensions for hover info: hovering over a capability variable shows its kind, rights, and current scope class.

---

## 9. Open issues

| ID | Issue |
|---|---|
| DBG-O1 | Official DWARF vendor identifier registration with the DWARF Standards Committee — pending. |
| DBG-O2 | The LLDB plugin (DBG §8.2) — phase 3+ work. |
| DBG-O3 | Cross-architecture DWARF (when PaideiaOS gains ARM64/RISC-V) — currently x86_64-only. |
| DBG-O4 | Compressed-debug-info performance — measure load overhead. |
| DBG-O5 | Debug info for inlined functions — DWARF supports it; PaideiaOS-specific inlining is rare (no aggressive inlining in the optimizer) but must be handled. |
| DBG-O6 | The `.debug.paideia.session_type` extension — session types in IPC need their own attribute. Not yet specified. |

---

*End of document.*
