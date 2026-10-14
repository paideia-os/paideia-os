# pds-lang header pragmas (R227.M1)

**Issue:** paideia-os#2703 (UMB-W25 R227.M1)
**Code:** `src/kernel/core/pds/header_pragma.pdx`
**Status:** M1 landed; M2+ planned.

## 1. What a header pragma is, and why

The **paideia-shell-language** (`pds`, `.pds`) is the typed, capability-aware
shell / scripting surface that sits on top of the kernel's capability
substrate and the `KIND_CMD_MODULE` registry (R123). A `.pds` file is a
script, a tab-completion target, a history-replay target, and — once R227
closes — a module that can import/export capability bindings.

Before any of that works, the parser has to answer three questions **about
the file itself**, not about the code inside it:

1. **Which version of pds-lang is this?** (so the parser knows which body
   grammar to apply, and whether to refuse a newer-than-me file).
2. **How strict should the body parse be?** (lint-level vs. hard-reject).
3. **How should per-session state be scaled?** (history ring size, charset,
   future knobs).

The POSIX world does this with ad-hoc magic lines (`#!shebang`,
`# -*- coding: utf-8 -*-`, `# vim:` modelines). The RFC/ISO world does it
with a formal pragma block. We take the latter.

A pds **header pragma** is a single line of the form

```
#pragma pds <directive>
```

at the top of a `.pds` file. The block ends at the first line that is
neither blank, nor a `#...` comment, nor a `#pragma pds ...` directive;
the pds body parser takes over from that point. The parser consumes
no capabilities, writes no state, and performs no VFS traffic — it is
a pure byte-level predicate that emits an array of 32-byte records
describing what it found.

### Design rationale

* **One line, one directive.** No multi-line pragmas, no array values,
  no nested blocks. The parser is a single-pass byte scanner with no
  backtracking and no regex, mirroring the discipline of
  `cmd_registry_parser.pdx` (TOML-subset).
* **ASCII-only.** The pragma block is parsed BEFORE any charset
  decision is applied. Pragma text is restricted to 7-bit ASCII so
  the parser does not need an NFC/UTF-8 pass of its own.
* **Comment-tolerant.** Regular `#` comment lines inside the pragma
  block are permitted and skipped. This lets authors annotate their
  pragmas without closing the block prematurely.
* **Block end is cheap.** The parser halts the moment it sees a byte
  that is neither WS, LF, nor `#`. The pds body parser resumes at
  that byte without re-reading anything.
* **Pack 32 bytes per record.** Fixed-size, zero-padded records make
  the output trivially digestible by the capability-schema layer
  (R90) and give callers a stable fingerprint for cache keys.

## 2. Grammar (M1)

```
HEADER        := LINE*
LINE          := BLANK | COMMENT | PRAGMA | HALT
BLANK         := WS* LF
COMMENT       := WS* '#' (not followed by 'pragma pds ') .* LF
PRAGMA        := WS* '#pragma pds ' DIRECTIVE WS* COMMENT_TAIL? LF
HALT          := anything else  (block ends; parser returns cleanly)
DIRECTIVE     := DIR_VERSION | DIR_STRICT | DIR_CHARSET | DIR_HISTORY
DIR_VERSION   := 'version' WS+ '"' VERSION '"'
DIR_STRICT    := 'strict'
DIR_CHARSET   := 'charset' WS+ 'utf8'
DIR_HISTORY   := 'history_default_cap' WS+ NUM

VERSION       := DIGIT+ ('.' DIGIT+)*       ; 1..24 bytes
NUM           := DIGIT+                     ; decimal u64
DIGIT         := [0-9]
WS            := SP (0x20) | HT (0x09) | CR (0x0D)
LF            := 0x0A
COMMENT_TAIL  := '#' .*
```

### Example header

```
#pragma pds version "1.0.0"
#pragma pds strict
#pragma pds charset utf8
#pragma pds history_default_cap 4096

# first non-pragma line below -- parsing halts cleanly here.
let main = fn () -> ...
```

### Blank + comment permissiveness

The following is accepted — comments and blank lines inside the block
are transparent:

```
# My script: build pipeline for driver image.
# Author: SNC, 2026-10-14.

#pragma pds version "1.0.0"

# strict mode: refuse unknown shell builtins
#pragma pds strict

#pragma pds charset utf8
#pragma pds history_default_cap 1024
```

### What halts the block

Any first non-WS byte on a line that is **not** `#` and **not** LF
(blank). The parser returns `PDS_HP_OK` with the count of pragmas
parsed; the first byte of the halting line is still in the input
buffer, untouched, for the body parser.

A `#` comment at EOF with no closing LF is also tolerated: the parser
treats it as a regular comment and reaches EOF cleanly.

## 3. Output record shape

Each parsed pragma produces one 32-byte `PdsHpRecord`:

| offset | size | field    | meaning                                   |
|-------:|-----:|----------|-------------------------------------------|
|   0    |  2   | kind     | `PDS_HP_KIND_*` ordinal (u16)             |
|   2    |  2   | len      | payload byte count (u16, 0..24)           |
|   4    |  4   | reserved | zero at M1 (future flags; see §7)         |
|   8    | 24   | value    | per-kind payload (see per-kind rows)      |

### Per-kind payload shape (M1)

| kind                  | ordinal | len | value[0..len)             |
|-----------------------|--------:|----:|---------------------------|
| `KIND_VERSION`        | 1       | 1-24| ASCII version string      |
| `KIND_STRICT`         | 2       | 0   | (unused — all zero)       |
| `KIND_CHARSET`        | 3       | 4   | ASCII `"utf8"`            |
| `KIND_HISTORY_CAP`    | 4       | 8   | u64 little-endian number  |

Unused bytes in the 24-byte value field are zero: the writer zeroes the
entire 32-byte slot before stamping kind + len + payload. Consumers can
rely on this when hashing a record for the capability-schema digest.

### Why the len field distinguishes shape

`len` serves two purposes:

1. **How many of the 24 value bytes to read** for an ASCII payload
   (version, charset).
2. **A sentinel for u64 payload**: `len == 8` on `KIND_HISTORY_CAP`
   tells a consumer to interpret `value[0..8)` as little-endian u64
   rather than as four ASCII characters.

A future kind that stores both an ASCII string AND an integer would
either reserve a flag bit in the `reserved` u32 or occupy a new
`KIND_*` ordinal — this is the first extension axis in §7.

## 4. Return code

`_pds_hp_parse(buf_ptr, buf_len, out_ptr, out_cap_bytes) -> u64` returns a
packed value:

```
bits [15: 0]   = status  (PDS_HP_* code)
bits [31:16]   = 0  (reserved)
bits [63:32]   = count OR byte offset  (per-status; see table)
```

| status                       | code    | bits[63:32]                                              |
|------------------------------|--------:|----------------------------------------------------------|
| `PDS_HP_OK`                  | 0x0000  | pragmas parsed (0..N)                                    |
| `PDS_HP_ERR_SYNTAX`          | 0x2800  | byte offset of first bad byte, measured from buf_ptr     |
| `PDS_HP_ERR_UNKNOWN_PRAGMA`  | 0x2801  | pragmas parsed before the unknown directive              |
| `PDS_HP_ERR_BAD_VERSION`     | 0x2802  | pragmas parsed before the malformed version              |
| `PDS_HP_ERR_OUT_TOO_SMALL`   | 0x2803  | pragmas successfully parsed before the out buffer filled |

The 0x2800 prefix carves pds-header-pragma errors out of the kernel error
space; sibling pds-lang modules in R227.M2+ claim adjacents:

* 0x2810..0x281F reserved for M2 **import/export** errors.
* 0x2820..0x282F reserved for M3 **dependency version resolution**.
* 0x2830..0x283F reserved for M4 **capability-env declarations**.

### Error disambiguation

* **`SYNTAX`** fires on any grammar violation that isn't more
  specifically classified. Examples: a non-digit, non-dot byte between
  `#pragma pds ` and the first keyword letter; a missing WS between
  `version` and the opening quote; garbage characters trailing a
  directive on the same line; an unterminated string literal (LF or
  EOF reached before closing `"`).
* **`UNKNOWN_PRAGMA`** fires when the dispatch first byte is not one
  of `v`/`s`/`c`/`h`, OR when the subsequent byte-match of the
  directive keyword fails (e.g. `#pragma pds strict_mode` would miss
  on byte 7).
* **`BAD_VERSION`** fires on an empty version string, an over-24-byte
  version string, a non-digit non-dot byte inside the version
  string, OR an unrecognised charset value (at M1, anything other
  than `utf8`). The last fold is a deliberate M1 simplification —
  an M2 `BAD_CHARSET` separates these.
* **`OUT_TOO_SMALL`** fires when the next record would exceed
  `out_ptr + out_cap_bytes`. Earlier records remain valid in the
  caller's buffer; the count in bits[63:32] is honest about how
  many landed.

## 5. ABI contract (M1)

### Entry

```
_pds_hp_parse:
    rdi = buf_ptr        ; non-null; points at .pds source bytes
    rsi = buf_len        ; 0 is legal (empty header -> OK, count=0)
    rdx = out_ptr        ; non-null; aligned any boundary
    rcx = out_cap_bytes  ; capacity of out buffer, bytes;
                         ; 0 is legal only if the file has no pragmas
```

### Return

```
    rax = (count << 32) | status
```

### Side effects

* Writes up to `(out_cap_bytes / 32)` records to `out_ptr`.
* No VFS traffic.
* No klog chatter.
* No capability lookup.
* No stack use beyond the five callee-save pushes.

### Accessors

Three leaf accessors are provided for consumer code to walk the records
without re-parsing byte offsets:

| accessor               | reads             | semantically valid when           |
|------------------------|-------------------|-----------------------------------|
| `_pds_hp_record_kind`  | u16 at `+0`       | always                            |
| `_pds_hp_record_len`   | u16 at `+2`       | always                            |
| `_pds_hp_record_u64`   | u64 at `+8`       | `kind == KIND_HISTORY_CAP`        |

## 6. Encoder discipline notes

The implementation respects every known pdx-encoder pitfall:

* No `test rN, rN` — every zero check is `cmp reg, 0; jcc`.
* No 2-op `imul r, imm` — the NUM parser's `num * 10` uses
  `shl num, 3; shl tmp, 1; add num, tmp`.
* No `and reg, imm64` — not needed in this file.
* **Byte stores limited to `mov_b [reg+off], reg` and
  `mov_b [reg+reg*1], reg`.** The `mov_b [reg+reg*1+off], reg` form
  is **not** supported by the encoder today
  (confirmed by `schema_registry.pdx §cn` and the repo-wide
  sweep logged in `feedback_pdx_encoder_pitfalls`). The byte-copy
  block pre-advances the destination into `rsi` to stay inside the
  supported shape.
* u16 stores use `mov_w [reg+off], reg` (proven in `crs.pdx §bus-range`).
* All `pub let` string declarations are single-line.
* Module basename `HeaderPragma` matches the file basename
  `header_pragma.pdx` (encoder requires exact match).
* Every label is prefixed `pds_hp_` so none clashes with pdx reserved
  words (`loop`, `if`, `let`, `else`, `fn`) or with sibling modules.
* Function is a pure **leaf** — no nested call — so rsp alignment
  inside the body is relaxed. The five callee-save pushes exist only
  to protect the cursor / bound registers through the body.

## 7. M1 → M2+ extension plan

### What M1 covers

* Four directives: `version`, `strict`, `charset`, `history_default_cap`.
* Fixed 32-byte record shape; four kinds.
* Four error codes: SYNTAX / UNKNOWN_PRAGMA / BAD_VERSION / OUT_TOO_SMALL.

### What M1 does NOT cover (deferred)

#### M2 — imports, exports, dependencies

M2 adds the directives below. The record shape is unchanged; the new
kinds extend the `KIND_*` ordinal space.

```
#pragma pds import "<module_name>"              -> KIND_IMPORT (5)
#pragma pds export "<binding_name>"             -> KIND_EXPORT (6)
#pragma pds depends "<module>" ">=" "<version>" -> KIND_DEPENDS (7)
```

* `KIND_IMPORT` value: module name string, up to 24 bytes.
* `KIND_EXPORT` value: binding name string, up to 24 bytes.
* `KIND_DEPENDS` value: packed `{ name_len u8, name[12], ver[11] }`
  OR extended across two consecutive records with a `CONTINUATION`
  flag in `reserved` (open design question — pick when M2 lands).

New error codes (0x2810..0x281F reserved):

* `PDS_HP_ERR_BAD_IMPORT    = 0x2810`
* `PDS_HP_ERR_BAD_EXPORT    = 0x2811`
* `PDS_HP_ERR_BAD_DEPENDS   = 0x2812`
* `PDS_HP_ERR_DUP_EXPORT    = 0x2813` (two `#pragma pds export` for the same binding)

#### M3 — capability-env declarations

```
#pragma pds requires "<capability_label>"       -> KIND_REQUIRES_CAP (8)
#pragma pds grants   "<capability_label>"       -> KIND_GRANTS_CAP   (9)
```

A pds script declares the capability labels it REQUIRES at invocation
(e.g. `fs.read`) and the labels it GRANTS to callees (R227 federation
story). The parser emits records; enforcement is upstream.

Error codes 0x2830..0x283F reserved.

#### M4 — strict-mode knobs

A set of sub-directives under `strict`:

```
#pragma pds strict warn_unused
#pragma pds strict reject_shadow
#pragma pds strict no_implicit_cast
```

Open design question: fold these into bitflags on a single
`KIND_STRICT` record (reusing `reserved` u32 as a bitfield), or
emit one record per sub-directive. The former preserves the
one-strict-record invariant; the latter composes better with
downstream rule-engine authors. Pick when M4 lands.

#### M5 — charset extension

Once an NFC-ready text layer exists (R221), `charset` grows:

```
#pragma pds charset utf8
#pragma pds charset ascii        -- strict 7-bit, pre-R221 fallback
#pragma pds charset latin1       -- deprecated; emit a lint warning
```

A separate `BAD_CHARSET` error retires the M1 `BAD_VERSION` fold.

#### M6+ — tool-identity pragmas

```
#pragma pds generated_by "<tool_name>" "<tool_version>"
#pragma pds source_url   "<url>"
#pragma pds license      "<spdx_identifier>"
```

These are informational — they shape digests and audit logs but do
not change parsing. They go in the OUTPUT record stream so a
capability-schema consumer can read them without re-reading the
file.

### Non-goals (will NOT land in R227)

* **No multi-line pragmas.** A directive is always one line. If a
  future need arises for longer payloads, the record stream absorbs
  it (multi-record output, flagged via `reserved`) rather than the
  grammar.
* **No conditional pragmas** (no `#ifdef`-style guards). pds-lang's
  conditional-compilation story is handled inside the body
  (`fn.cond { ... }`), not in the header.
* **No pragma aliases.** Each directive has exactly one spelling.
  Readability wins over typing-economy.

## 8. Consumer wiring (not in M1 scope)

The parser is a pure primitive. Consumer wiring lands in a sibling
milestone:

1. **R227.M2** adds a `pds_session_load` entry point that:
   - allocates a `PdsHpRecord[16]` on the per-session heap,
   - calls `_pds_hp_parse` over the first 4 KiB of the file,
   - walks the record stream and configures the session:
     * `KIND_VERSION` → compare against `PDS_LANG_VERSION_MAJOR/MINOR/PATCH`;
       refuse if MAJOR mismatches.
     * `KIND_STRICT` → set a `strict_mode` bit on the session TCB.
     * `KIND_CHARSET` → gate at the body-parser handoff.
     * `KIND_HISTORY_CAP` → forward the u64 to R127's history scaler.
2. **R123.M8** retrofits the on-disk command registry's companion
   `.pds` script loader to run the pragma block through this parser
   before the body parser sees any byte.
3. **R90-digest** (schema registry) will digest the record stream
   as part of a session's capability fingerprint — the fixed-size
   zero-padded record shape is chosen specifically so a SHA-256 of
   the record array is stable across pragma ordering (the digest
   caller sorts records by kind before hashing).

## 9. Open questions for M2+

* **Pragma ordering.** M1 preserves textual order in the output
  record array. M2 may need to reject conflicting pragmas (e.g.
  two `KIND_VERSION` records); open: fold the dup check into the
  parser, or into the consumer? Parser-side is cheaper to witness.
* **Line-ending tolerance.** M1 accepts `WS* LF` (CRLF reduces to
  `WS LF` since CR is in WS). An LF-only policy would be stricter
  but needs a decision from the overall file-format wave.
* **Max pragma count.** M1 does not cap the number of pragmas; the
  caller's `out_cap_bytes` is the only limit. A future `PDS_HP_MAX`
  constant would catch pathological inputs.
* **Interning.** `KIND_IMPORT` / `KIND_EXPORT` values are strings
  up to 24 bytes. Longer names will need a continuation flag OR an
  intern table (R90-schema's existing one is the natural home).
