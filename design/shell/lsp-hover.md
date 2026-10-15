# LSP-embed hover query surface — R225.M8

**Owner:** paideia-os
**Upstream issue:** paideia-os#2689 (R225.M8 LspHover)
**Umbrella:** paideia-os#2489 (R225 — unified HM type checker)
**Module:** `tools/user/libpdx-pds-parser/src/lsp_hover.pdx`
**Status band:** `0x5E00..0x5EFF`
**Status:** landed (raw M8; demo-table-backed)

## 1. Scope

The semantic-shell's line editor raises a `CURSOR_REST` event when
the user's cursor sits on a token for longer than the hover-latency
threshold (R229.M6 LineEditor / R229.M7 ViMode). The LSP transport
side (R220.M9) handles that event by calling `_lh_query` with the
line-buffer bytes, their length, and the cursor's byte offset. The
module returns a 128-byte **HoverResponse** record carrying the
three summary rows the user cares about:

- **type** — the principal HM type for the token (R225.M1 HmCore);
- **effects** — the token's effect row (R224.M3 EffectRow);
- **capabilities** — the token's capability row (R224.M4 CapRow).

The LSP transport serializes the record to a one-line
`textDocument/hover` reply payload via `_lh_render_lsp_json`.

The module is parser-tier, lives user-space (the shell is
user-space), carries NO `.bss` state at raw M8, and consumes no
kernel capability (see `caps.decl` R225.M8 band note).

## 2. Why this exists

An LSP-embed hover surface is table-stakes for a modern typed
shell. Three alternative shapes were considered and rejected:

- **Inline type echo in the prompt** — pollutes the prompt bar;
  cannot carry effect / capability rows without going multi-line
  and breaking the one-line prompt convention.
- **An M-x-style `:type` subcommand** — forces the user to type a
  command every time; defeats the point of an IDE-grade shell. The
  user wants to *see* the triple without acting.
- **Reusing R225.M7 DiagReport's record for hovers** — DiagReport
  is error-shaped: it carries severity, expected / actual, and a
  mechanical suggestion. A hover is not an error; conflating them
  loses the semantic separation that lets a downstream LSP consumer
  route the two payloads to different UI lanes.

LspHover ships a hover-specific record whose only three string
fields are the three rows a hover UI needs. The LSP transport
wraps the record in a `Hover` reply; a terminal-tier renderer can
alternatively paint the three rows as a popover.

## 3. Why not a kernel-side primitive

The hover surface runs entirely over caller-owned buffers (line
buffer + out buffer) and never crosses a KIND boundary. Putting it
in the kernel would force every hover event through a syscall for
no benefit: the HM elaborator state (M8.1+ wire-up) also lives
user-space, so a hover query would hop user -> kernel -> user with
every cursor-rest tick. Keep it user-space; the LSP transport
owns the kernel-side boundary.

## 4. Why not a shared helper surface with DiagReport

DiagReport (R225.M7) has four module-private emit helpers
(`_dr_h_emit_lit`, `_dr_h_emit_cstr`, `_dr_h_emit_u16_hex`,
`_dr_h_emit_u32_dec`). LspHover ships its own copies
(`_lh_h_emit_lit`, `_lh_h_emit_cstr`, `_lh_h_emit_u32_dec`; no
hex emitter since the hover record has no hex-encoded fields).

The two modules deliberately keep disjoint helper surfaces
because:

1. **Each module ships standalone.** A consumer that pulls only
   `lsp_hover.pdx` for a hover-only build does not need the
   DiagReport module's `.rodata` tables or the hex emitter.
2. **Inter-module linker dependency count stays low.** Raw M8 has
   ZERO intra-library linker-visible function references. Pulling
   in DiagReport's helpers would introduce three.
3. **Independent evolution.** A future change to DiagReport's
   byte-emission shape (e.g. UTF-16 LSP columns at R225.M7.2)
   should not force LspHover to co-evolve. Keep them disjoint.

## 5. Record wire format — 128 bytes exactly

Stride 128 (= `1 << 7`) is a power of two so a future per-session
hover queue stores N records at `[base + i << 7]` — `shl r, 7`
addressing, no `imul` pitfall. Mirror of DiagReport's record
discipline.

```
+------+---------+---------+--------------------------------------+
| Off  | Field   | Width   | Meaning                              |
+------+---------+---------+--------------------------------------+
| 0x00 | magic   | u32     | 'HOVR' = 0x52564F48 LE               |
| 0x04 | tok_off | u32     | Token byte-offset into SOURCE buffer |
|      |         |         | (Q-A5 invariant: not NFC-form).      |
| 0x08 | tok_len | u32     | Token byte-length.                   |
| 0x0C | flags   | u32     | Bit 0 LH_FLAG_TYPE_KNOWN             |
|      |         |         | Bit 1 LH_FLAG_EFFECT_KNOWN           |
|      |         |         | Bit 2 LH_FLAG_CAP_KNOWN              |
|      |         |         | Bit 3 LH_FLAG_IS_IDENT               |
|      |         |         | Bits 4..31 reserved                   |
| 0x10 | type    | u8[32]  | Inferred type name (NUL-padded).     |
| 0x30 | effect  | u8[32]  | Effect row (NUL-padded).             |
| 0x50 | cap     | u8[32]  | Capability row (NUL-padded).         |
| 0x70 | rsvd    | u64     | 0 at raw M8.                         |
| 0x78 | next    | u64     | 0 at raw M8 (M8.2 queue link).       |
+------+---------+---------+--------------------------------------+
Total: 128 bytes.
```

Magic `'HOVR'` = `0x52564F48` LE — byte-sequential: H O V R. Bit 31
clear so `cmp reg, 0x52564F48` is imm32 sign-safe.

The three 32-byte inline strings sit at contiguous offsets
`0x10 / 0x30 / 0x50`. The demo-table hit path (§6) writes them in
a single 96-byte byte-count loop from a 112-byte triple at
`entry+16`.

## 6. Demo-table-driven lookup

Raw M8 ships a 10-entry demo table in `.rodata` at
`_lh_demo_table`. Each entry is 128 bytes stride (power of two;
`shl r, 7` addressing):

```
+------+---------+---------+----------------------+
| Off  | Field   | Width   | Meaning              |
+------+---------+---------+----------------------+
| 0x00 | name    | u8[16]  | NUL-padded name      |
| 0x10 | type    | u8[32]  | NUL-padded type      |
| 0x30 | effect  | u8[32]  | NUL-padded effect    |
| 0x50 | cap     | u8[32]  | NUL-padded cap       |
| 0x70 | rsvd    | u8[16]  | NUL-padded reserved  |
+------+---------+---------+----------------------+
Total: 128 bytes.
```

Entry `[+16..+112]` is a 96-byte `(type, effect, cap)` triple
whose byte layout matches the HoverResponse record's
`[+16..+112]` byte layout exactly, so the hit path is a single
96-byte byte-copy from `entry+16` to `record+16`.

Table lookup is a linear scan over 10 entries. For each entry:

1. Measure name length = `j` such that `entry[j] == NUL` or
   `j == 16` (bounded 0..16).
2. If `j != token_len`: skip.
3. For `k = 0..token_len`: compare `entry[k]` vs
   `token_ptr[k]`; on mismatch, skip.
4. On full match: byte-copy 96 bytes; return flags
   `TYPE_KNOWN | EFFECT_KNOWN | CAP_KNOWN` (= 7).

Miss: return 0 flags. The record's token offset / length / magic
still populate so the caller can tell the token was identified
but no type is known.

The forward-path landing M8.1 replaces this lookup with a live
HmCore / EffectUnify / CapRow query against the AST node
identified by the cursor offset.

## 7. Acceptance corpus — 10 sample expressions

Each row is `(cursor expression, token under cursor, expected
hover triple)`. The acceptance test calls `_lh_query` with the
cursor positioned anywhere inside the named token and expects
`LH_OK` with the type / effect / cap fields matching the demo
table's bytes exactly.

| # | Buffer      | Cursor | Token | Type               | Effect   | Cap          |
|---|-------------|--------|-------|--------------------|----------|--------------|
| 1 | `x`         | 0      | x     | `u64`              | `{}`     | `{}`         |
| 2 | `s`         | 0      | s     | `str`              | `{}`     | `{}`         |
| 3 | `p`         | 0      | p     | `path`             | `{}`     | `{}`         |
| 4 | `pid`       | 1      | pid   | `pid`              | `{}`     | `{}`         |
| 5 | `echo hi`   | 2      | echo  | `str -> str`       | `{io}`   | `{tty}`      |
| 6 | `cat /etc`  | 1      | cat   | `path -> str`      | `{io,fs}`| `{fs,tty}`   |
| 7 | `ls`        | 1      | ls    | `path -> [path]`   | `{fs}`   | `{fs,tty}`   |
| 8 | `ps`        | 0      | ps    | `() -> [pid]`      | `{proc}` | `{proc}`     |
| 9 | `pwd`       | 2      | pwd   | `() -> path`       | `{fs}`   | `{fs}`       |
|10 | `map f xs`  | 0      | map   | `(a->b)->[a]->[b]` | `{}`     | `{}`         |

The ten tokens cover: four nullary base-type identifiers
(`x` / `s` / `p` / `pid`); four shell builtins with non-empty
effect and capability rows (`echo` / `cat` / `ls` / `ps`); a
nullary builtin with a capability dependency (`pwd`); a
higher-order combinator (`map`). Together they exercise the
record's three inline string fields (type / effect / cap) with
non-trivial content, plus the empty-row shape `{}`.

## 8. Token-boundary heuristic

Raw M8 accepts the ASCII identifier charset `[a-zA-Z0-9_-]`
(0x30..0x39 | 0x41..0x5A | 0x5F | 0x61..0x7A | 0x2D). M8.3 extends
to the TR#31 identifier profile over NFC-normalised bytes
(R221.M1 + R221.M2 wire-up).

The scan algorithm (`_lh_h_scan_token`):

1. If `buffer_len == 0` or `cursor > buffer_len`: return no-token.
2. If `cursor == buffer_len` (end-of-line): clamp
   `cursor = buffer_len - 1`.
3. If `_lh_h_is_ident(buffer[cursor]) == 0`: return no-token.
4. Grow left: `start = cursor`; while `start > 0 and
   is_ident(buffer[start-1])`: `start -= 1`.
5. Grow right: `end = cursor`; while `end < buffer_len and
   is_ident(buffer[end])`: `end += 1`.
6. Return packed `(start << 32) | (end - start)`.

The scan is cluster-naive at raw M8: a multi-byte UTF-8 sequence
whose leading byte sits in the ASCII identifier range (impossible
by UTF-8 construction) would never match; a multi-byte sequence
in `0x80..0xFF` is simply not an identifier char. The real UTF-8
identifier scan lands at M8.3 via the `_gi_next_cluster` /
`_gi_prev_cluster` helpers.

## 9. LSP JSON wire format

`_lh_render_lsp_json` serializes the record to a one-line
LSP `Hover` payload. The LSP transport wraps it in the standard
`textDocument/hover` reply envelope with the request id. The
shape:

```json
{"contents":{"kind":"markdown","value":"**type**: <t>
\n**effects**: <e>
\n**capabilities**: <c>"},"range":{"start":{"line":0,"character":<n>},"end":{"line":0,"character":<n>}}}
```

(Shown wrapped for readability; the actual output is one line
with literal `\n` escapes inside the JSON string.)

Fields:

- `contents.kind == "markdown"` — renders the three rows as
  bolded headers in LSP clients that support MarkupContent 3.17.
- `contents.value` — three lines with `**bold**` labels. The
  `effects` and `capabilities` lines are OMITTED entirely when
  the respective inline string's first byte is NUL (demo-table
  miss or caller-reset).
- `range` — LSP range at raw M8 uses `line=0, character=<byte>`
  as the byte-level fallback (same convention DiagReport
  uses pre-M7.2). M8.3 refines to UTF-16 character columns.

Error paths:

- `LH_ERR_BAD_INPUT` (0x5E00) — record_ptr or out == 0.
- `LH_ERR_BAD_RECORD` (0x5E05) — record_len < 128 or magic
  mismatch.
- `LH_ERR_RENDER_OVERFLOW` (0x5E06) — output exceeded out_cap.

## 10. Status-code taxonomy

| Code                       | Hex     | Meaning                                        |
|----------------------------|---------|------------------------------------------------|
| `LH_OK`                    | 0x0000  | Success.                                       |
| `LH_ERR_BAD_INPUT`         | 0x5E00  | `buffer_ptr == 0` or `out == 0`.               |
| `LH_ERR_OUT_TOO_SMALL`     | 0x5E01  | `out_cap < 128` on `_lh_query`.                |
| `LH_ERR_CURSOR_OOB`        | 0x5E02  | `cursor_byte > buffer_len`.                    |
| `LH_ERR_NO_TOKEN`          | 0x5E03  | Cursor sits on non-identifier byte.            |
| `LH_ERR_UNKNOWN_TOKEN`     | 0x5E04  | Reserved for future miss distinction.          |
| `LH_ERR_BAD_RECORD`        | 0x5E05  | Render saw bad magic or `record_len < 128`.    |
| `LH_ERR_RENDER_OVERFLOW`   | 0x5E06  | Render output exceeded `out_cap`.              |

Slots `0x5E07..0x5EFF` are reserved for M8.1+ follow-ups.

## 11. Forward path

| Milestone | Scope                                                                             |
|-----------|-----------------------------------------------------------------------------------|
| M8.1      | Replace demo-table with live HmCore / EffectUnify / CapRow queries against AST.   |
| M8.2      | `.bss` session-local hover-queue head + enqueue helper (parallels R225.M7.1).     |
| M8.3      | TR#31 identifier profile + UTF-8-aware byte -> line/column resolver + LSP range.  |
| M8.4      | `_lh_set_env(te_ref)` TypeEnv pointer stash for the elaborator wire-up.           |
| M8.5      | 60-expression acceptance corpus + golden LSP JSON outputs.                        |
| M8.6      | Kernel-side wire-up at the LSP transport dispatch tier (R220.M9).                 |
| M8.7      | Chained hover payload for lambda-literal argument types via `next_hover_ref`.     |

## 12. paideia-as encoder discipline

Verbatim mirror of the discipline enforced in `diag_report.pdx`:

- No `test rN, rN` — zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — band values `0x5E00..0x5EFF` fit imm32;
  token-length zero-extension via `shl r, 32; shr r, 32` rather
  than `and r, 0xFFFFFFFF` (whose imm32 encoding would
  sign-extend because bit 31 is set).
- No 2-op `imul r, imm` — 128-byte strides via `shl r, 7`; 32-byte
  via `shl r, 5`; 4-byte via `shl r, 2`.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `LspHover` matches `lsp_hover.pdx`.
- Labels prefixed `lh_` (public entries + ident / scan / lookup
  helpers) and `lh_h_` (byte-emit helpers). Grep-confirmed unique
  against every landed parser-tier prefix.
- Byte loads via `xor r,r; mov_b r,[base + idx]`; u32 loads via
  `xor r,r; mov_d r,[base + disp]` (zero-extends per SDM Vol.1
  3.4.1.1). u32 stores via `mov_d`; u8 stores via `mov_b`.
- No chained-displacement operands — three-term address
  computations pre-computed into a register via `mov; shl; add`.
- Register-liveness audit per public entry documented in the
  module header.

## 13. Cross-references

- Parent umbrella: `design/terminal/semantic-shell-language-plan.md`
  (R225 — unified HM type checker).
- Sibling R225.M* design docs:
  `design/shell/hm-algorithm-w-core.md` (R225.M1),
  `design/shell/row-types-remy.md` (R225.M2),
  `design/shell/effect-row-unification.md` (R225.M4),
  `design/shell/rank-restricted-polymorphism.md` (R225.M6),
  `design/shell/diagnostic-reporting.md` (R225.M7).
- Row-type dependencies:
  `design/shell/effect-polymorphism.md` (R224.M3),
  `design/shell/capability-row-typing.md` (R224.M4).
- Cursor source:
  `design/shell/line-editor-emacs.md` (R229.M6),
  `design/shell/line-editor-vi.md` (R229.M7).
- Invariant: `design/shell/span-map-nfc.md` (R221.M6 Q-A5 source
  byte-offset discipline).
