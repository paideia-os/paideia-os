# Command-functor `CommandSig` Body Parser (R222.M2)

**Status:** v0.1 (R222.M2 — paideia-os#2659)
**Date:** 2026-10-14
**Author:** softarch (Wave UMB-W29)
**Scope:** The parser-tier primitive that turns a `command_sig { ... }` body — the SECOND functor parameter of every semantic-shell command module, per SH-D5 — into a flat (CommandSigHeader + CapDecl array) byte image. Companion to R222.M1 `SchemasSig` (which carries input/output record SHAPES). Interacts with `libpdx-pds-parser` R221.M1 (UTF-8/NFC parser-tier wrapper) upstream, R227.M2 (pds cap-decl checker) laterally at `exec` time, and R133.M2 (pds container header pragma gate) at container-load time.

---

## 1. Why this exists

`design/terminal/semantic-shell-language-plan.md` section "R222 — Command-module functor surface + registry client (SH-D5)" tasks R222.M2 with:

> **`CommandSig` signature body** — ML signature declaring a command's FUNCTOR IDENTITY: human-readable name, required capability set, SemVer-shaped version, and stability tier.

The grammar sits inside the paideia-as functor-signature line that every semantic-shell command module satisfies:

```
module Find(Schemas : SchemasSig)(Caps : CommandSig)
    : struct { ... } = struct ... end

signature SchemasSig = schemas_sig { path: path -> name: str, size: u64 }
signature CommandSig = command_sig {
    name:      "find"
    cap:       fs_read_dir : 0x01
    cap:       fs_stat     : 0x02
    version:   "0.1.0"
    stability: experimental
}
```

Where the body of `command_sig { ... }` is a bag of whitespace-separated declarations (NAME, CAP, VERSION, STABILITY — in any order, with duplicates landing last-wins). Later R222 milestones feed the resulting (header + cap array) byte image into:

- the elaborator's per-command record (R222.M3 REPL dispatch),
- the schema-registry fingerprint pipeline (R222.M8 `describe <cmd>` serialization),
- the kernel-side cap-decl checker at `exec` time (R227.M2 — reads the cap array directly off the elf `.caps.decl` section),
- the pds container header pragma gate at container-load time (R133.M2 — compares the on-disk CommandSig fingerprint against the elaborator's view).

R222.M2 (this landing) delivers:

1. the parser-tier primitive `_cs_parse_body` that consumes the body between `{` and `}` and emits a 128-byte header + up to 8 × 32-byte CapDecl descriptors, and
2. two module-private leaves (`_cmd_sig_skip_ws`, `_cmd_sig_fnv1a64`) that keep the parser pure-leaf under `libpdx-pds-parser`'s single-object linking discipline.

**Why a satellite library, not kernel-side.** Same reasoning as R222.M1: the shell runs in user space, the CommandSig record is produced once at functor-elaboration time, and the kernel-side consumers (cap-decl checker at `exec`, container header gate at load) see it only as a flat byte blob. The parser never crosses the KIND boundary. The same pattern R222.M1 (`schemas_sig.pdx`), R223.M1 (`pipeline.pdx`), R224.M1 (`lambda_lit.pdx`), R225.M1 (`hm_core.pdx`), and R226.M1 (`datalog.pdx`) use.

---

## 2. Grammar

```
CommandSig    := Decl*                              (whitespace-separated)
Decl          := NameDecl
               | CapDecl
               | VersionDecl
               | StabilityDecl
NameDecl      := "name"      ":" WS* "\"" NAME "\""
CapDecl       := "cap"       ":" WS* NAME ":" WS* HEX_RIGHTS
VersionDecl   := "version"   ":" WS* "\"" SEMVER "\""
StabilityDecl := "stability" ":" WS* ("stable"
                                     | "experimental"
                                     | "deprecated")
NAME          := [0x21..0x7E except '"']+           (length 1..48)
SEMVER        := [0x21..0x7E except '"']+           (length 1..16)
HEX_RIGHTS    := "0x" [0-9A-Fa-f]+                  (1..16 hex digits)
WS            := 0x20 | 0x09 | 0x0A | 0x0D
```

### 2.1 Entry point input

The entry point consumes the body BETWEEN the `{` and the `}` — the braces and the leading `command_sig` keyword are NOT part of the input. The caller (a later R222 milestone's lexer / AST pass) locates the braces and hands the inner bytes to `_cs_parse_body`.

### 2.2 Decl ordering + duplicates

Decls appear in any order, separated only by whitespace. Duplicates land **last-wins**:

- A second `name :` decl overwrites the first (and zero-pads any trailing bytes so a shorter replacement does not leave stale tail bytes).
- A second `version :` decl overwrites the first analogously.
- A second `stability :` decl overwrites the first byte.
- A second (or later) `cap :` decl appends to the cap array until `CS_MAX_CAPS = 8` is reached (then `CS_ERR_TOO_MANY_CAPS`); duplicate cap names are NOT detected at this parser tier (R222.M2 defers duplicate-cap detection to the elaborator at R222.M3, which has the policy context to reject a duplicate or merge rights).

"Last-wins" is both the cheapest and most forgiving behaviour; the upstream on-disk `commands.toml` schema already enforces uniqueness, and a hand-edited sig that happens to carry a duplicate name/version/stability survives the parser-tier pass unchanged.

### 2.3 Three legal forms (illustrative)

**Minimal:**

```
name: "pwd"
```

**Typical:**

```
name: "find"
cap: fs_read_dir : 0x01
cap: fs_stat     : 0x02
version: "0.1.0"
stability: experimental
```

**Full (max 8 caps):**

```
name: "advanced_grep"
cap: fs_read       : 0x01
cap: fs_stat       : 0x02
cap: fs_readlink   : 0x04
cap: proc_read     : 0x08
cap: proc_cap_list : 0x10
cap: time_realtime : 0x20
cap: time_monotonic: 0x40
cap: audit_emit    : 0x80
version: "2.3.1"
stability: stable
```

### 2.4 Explicit non-grammar at M2

- The leading `command_sig` keyword and surrounding `{` / `}` are not part of the input (same convention as R222.M1).
- No nested cap expressions, no cap name aliases, no `requires` / `provides` separation. Those are M3+ when REPL dispatch wires the policy layer.
- No comments inside the body. The pds-lang lexer upstream strips comments before the brace-matched body is extracted.
- No trailing comma or separator between decls. Whitespace separation is sufficient.
- No empty cap decl shape (e.g. `cap:` with no name) — the ident scan rejects a zero-length cap name as `CS_ERR_SYNTAX`.
- No non-ASCII bytes inside any identifier (NAME / SEMVER values accept printable ASCII; cap names and keywords are strict `[A-Za-z_][A-Za-z0-9_]*`).

---

## 3. Public API

### 3.1 `_cs_parse_body`

```
_cs_parse_body(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed_u64
```

- `rdi` = `bytes_ptr`   — pointer to the first body byte.
- `rsi` = `bytes_len`   — body length in bytes, NOT including the braces.
- `rdx` = `out_ptr`     — pointer to the output buffer (`CS_HEADER_BYTES + CS_MAX_CAPS * CS_CAP_DESC_BYTES = 128 + 256 = 384` bytes is enough for the maximum-sized sig).
- `rcx` = `out_cap`     — output buffer capacity in bytes.
- `rax` = `(bytes_written << 32) | status` — packed. `bytes_written` is meaningful only when `status == CS_OK`; on error the top 32 bits are undefined and callers ignore them.

### 3.2 Internal helpers (module-private)

```
_cmd_sig_skip_ws(bytes_ptr, bytes_len, cursor) -> new_cursor
_cmd_sig_fnv1a64(ptr, len)                     -> u64 hash
```

Both are pure leaves (no callee-save push, no stack frame, no nested CALL). `_cmd_sig_skip_ws` is a byte-for-byte mirror of R222.M1's `_sch_sig_skip_ws` / R224.M1's `_ll_skip_ws` / R226.M1's `_dl_skip_ws` so the whitespace discipline is a shared property across the pds-lang family. `_cmd_sig_fnv1a64` implements the standard FNV-1a 64 hash (offset basis `0xCBF29CE484222325`, prime `0x100000001B3`) via `mul rcx` (one-op unsigned mul — distinct from the pitfall-listed 2-op `imul r, imm`).

### 3.3 Status-code taxonomy

| Code                        | Value   | Meaning |
|-----------------------------|---------|---------|
| `CS_OK`                     | `0`     | parse succeeded; header + cap array fully written |
| `CS_ERR_SYNTAX`             | `0x3300`| grammar mismatch at keyword, `:`, `"`, hex rights, or ident byte-class |
| `CS_ERR_TOO_MANY_CAPS`      | `0x3301`| cap count exceeds `CS_MAX_CAPS` (= 8) |
| `CS_ERR_UNKNOWN_STABILITY`  | `0x3302`| stability value not in the `{stable, experimental, deprecated}` set |
| `CS_ERR_OUT_TOO_SMALL`      | `0x3303`| `out_cap < CS_HEADER_BYTES + n_caps * CS_CAP_DESC_BYTES` |

The band `0x3300..0x33FF` is reserved for R222.M2 cmd-functor-identity parser codes. It is disjoint from every other packed-status band in the paideia-os tree:

- R221 parser-tier wrapper (`0x2700..0x27FF`),
- R222.M1 SchemasSig band (`0x2A00..0x2AFF`),
- R223.M1 pipeline-lang band (`0x2B00..0x2BFF`),
- R224.M1 lambda-lang band (`0x2C00..0x2CFF`),
- R225.M1 hm-core band (`0x2D00..0x2DFF`),
- R226.M1 datalog band (`0x2E00..0x2EFF`),
- R223.M2 record-projection band (`0x3400..0x34FF`),
- user-space `0xFFFFExxx` error-band slices.

A grep at landing confirms disjointness:

```sh
grep -rE '0x330[0-3]' paideia-os/{src,tools,design,tests}
```

returns hits only inside `src/command_sig.pdx`, `caps.decl`, and this design doc.

---

## 4. Record layout

### 4.1 Output buffer

After a successful parse the output buffer carries, in order:

```
[+0     .. +128)        CommandSigHeader (128 B)
[+128   .. +128+n*32)   CapDecl[0..n]    (32 B each, n = n_caps)
```

Total bytes written: `128 + n_caps * 32`. The caller can size the buffer at `CS_HEADER_BYTES + CS_MAX_CAPS * CS_CAP_DESC_BYTES = 128 + 8 * 32 = 384` bytes to accommodate the maximum sig.

### 4.2 `CommandSigHeader` (128 B)

```
offset  size  field                 notes
------  ----  --------------------  --------------------------------------
   0     4   magic         u32     CS_HEADER_MAGIC = 'CSIG' little-endian
                                   = 0x47495343 (reads as the 4-byte
                                   ASCII string "CSIG" in a hex dump)
   4     1   n_caps        u8      0 .. CS_MAX_CAPS (= 8)
   5     1   stability     u8      0 (unset) / 1 (stable) / 2
                                   (experimental) / 3 (deprecated)
   6     1   name_len      u8      0 .. CS_NAME_MAX (= 48)
   7     1   version_len   u8      0 .. CS_VERSION_MAX (= 16)
   8    48   name_inline[48] u8    ASCII name, zero-padded past name_len
  56    16   version_inline[16] u8 ASCII semver, zero-padded past
                                   version_len
  72     4   caps_offset   u32     = CS_HEADER_BYTES (128)
  76     4   caps_len      u32     = n_caps * CS_CAP_DESC_BYTES (32)
  80     4   flags         u32     bitmask
                                      CS_FLAG_HAS_NAME      = 0x01
                                      CS_FLAG_HAS_VERSION   = 0x02
                                      CS_FLAG_HAS_STABILITY = 0x04
  84    44   reserved[44]  u8      zeroed; reserved for R222.M3+
                                   (effect-row id, cap-row id, source
                                   span, etc.)
```

- **48-byte inline name** is the structural fit for `commands.toml`'s observed command-name distribution (`find`, `grep`, `advanced_grep`, `net.remote_mount`, `sys.audit_follow`, …). The hard cap of 48 bytes leaves 16 bytes of slop over the longest observed name (`sys.audit_follow` at 16 chars) with no pointer-arena management.
- **16-byte inline version** fits SemVer-shaped identifiers up to `99.99.99-rc99` (14 chars) with 2 bytes of slop; longer version strings are rejected at the parser tier as `CS_ERR_SYNTAX`.
- **`caps_offset` + `caps_len`** redundantly carry the array header so a downstream reader can skip the fixed-size header without a per-entry size calculation. Both are u32 and fit in imm32 for a `cmp reg, imm32` guard.
- **`flags` u32** records which optional decls were present (useful at R222.M3 when the elaborator needs to distinguish "no name declared" from "name declared empty"; the parser rejects empty name/version/stability as `CS_ERR_SYNTAX`, so the flags are tri-state-free in the current grammar but reserved as such for M3+ relaxation).
- **44-byte reserved tail** is wide enough to accommodate the R222.M3 effect-row id (8 B), cap-row id (8 B), source-span start/end (16 B), and a 12-byte scratch for the elaborator's per-command housekeeping (allocation id, generation counter, etc.).

### 4.3 `CapDecl` descriptor (32 B)

```
offset  size  field                  notes
------  ----  ---------------------  -------------------------------------
   0     8   name_hash   u64        FNV-1a 64 of the FULL cap-name bytes
                                    (identity hash; preserves full name
                                    past the 16-byte inline window)
   8     8   rights      u64        bitmask parsed from HEX_RIGHTS
  16    16   name_inline[16] u8     first 16 bytes of the cap name,
                                    zero-padded; truncated past 16 chars
                                    (name_hash preserves full identity)
```

- **Stride 32 is a power of two** so cap addressing uses `shl rN, 5` — never 2-op `imul r, imm` (per `feedback_pdx_encoder_pitfalls.md`). The same stride-32 shape as R224.M1's Param descriptor; identical motivation.
- **16-byte inline name** is a deliberate truncation choice. Observed cap names (`fs_read`, `fs_write`, `fs_stat`, `proc_read`, `time_realtime`, `audit_emit`, …) all fit in 16 bytes, but the grammar accepts names up to 48 bytes to leave headroom for namespaced names (`net.remote_mount`, `sys.audit_follow`). The `name_hash` preserves full identity for the full name, and R222.M8 serialization writes the full name back out through the authoritative `commands.toml` lookup.
- **`name_hash` is FNV-1a 64**, not BLAKE3. The choice is pragmatic: FNV-1a 64 is a leaf multiply over at most 48 bytes (cheap for a once-per-functor-elaboration path), while BLAKE3 would introduce a linker dependency on `paideia_crypto_blake3_hash` and break this library's "pure-leaf, no external deps" discipline. A later R222.M? that wants a cryptographic cap-name fingerprint can replace `_cmd_sig_fnv1a64` with a BLAKE3 wrapper call without an ABI break (the `name_hash` slot stays u64).
- **Fingerprint input shape (R222.M8 serialization):** the full 128-byte header plus `n_caps * 32` bytes of CapDecl descriptors, byte-identical across host and kernel-side consumers because every field is inline (no pointer dereferences). The fingerprint comparison at R133.M2 (container header pragma gate) and R227.M2 (cap-decl checker at `exec`) hashes exactly these bytes.

---

## 5. Parser mechanism

The parser is a tiny `Decl*` loop over whitespace-separated decls. Register map (6 callee-save pushes + 24-byte stack scratch; `rsp % 16 == 0` steady at every nested CALL):

| Reg          | Role                                          |
|--------------|-----------------------------------------------|
| `rbx`        | `bytes_ptr` (immutable)                       |
| `rbp`        | `bytes_len` (immutable)                       |
| `r12`        | `cursor` (byte offset into body)              |
| `r13`        | `out_ptr` base (immutable)                    |
| `r14`        | `out_cap` (immutable)                         |
| `r15`        | `n_caps` counter                              |
| `[rsp +  0]` | `cap_name_start` (ephemeral; cap decl only)   |
| `[rsp +  8]` | `cap_name_len`   (ephemeral; cap decl only)   |
| `[rsp + 16]` | `cap_rights` u64 (ephemeral; cap decl only)   |

### 5.1 Prologue + header prelude

- Six callee-save pushes (`rbx`, `rbp`, `r12`, `r13`, `r14`, `r15`); `sub rsp, 24` for the three scratch slots.
- `rsp % 16` chain: entry 8, +48 pushes = 8, +24 scratch = `(8 + 48 + 24) mod 16 = 0`. Nested CALLs land aligned.
- Capacity guard: `cmp r14, 128; jb CS_ERR_OUT_TOO_SMALL` (header alone requires 128 bytes).
- Zero-fill the full 128-byte header via a u64-stepping loop (16 iterations stepping by 8), then stamp `magic` and `caps_offset` immediately with `mov_d` writes. Deferring the n_caps / caps_len / flags fields to the coda keeps the per-decl loop body simpler.

### 5.2 Decl loop

```
decl_loop:
    cursor = skip_ws(cursor)
    if cursor == bytes_len: goto done                   (success)
    kw_start = cursor
    scan ident [A-Za-z_][A-Za-z0-9_]*                   (bounded, no cap)
    kw_len = cursor - kw_start
    switch kw_len:
        case 3: compare 'c','a','p'       -> parse_cap_decl
        case 4: compare 'n','a','m','e'   -> parse_name_decl
        case 7: compare "version"         -> parse_version_decl
        case 9: compare "stability"       -> parse_stability_decl
        default:                             CS_ERR_SYNTAX
```

Each per-decl arm (below) finishes by jumping back to `decl_loop`.

### 5.3 `parse_name_decl` / `parse_version_decl`

```
skip_ws
require ':'
skip_ws
require '"'
scan NAME/SEMVER bytes [0x21..0x7E except '"']
    until closing '"'; length bounded at CS_NAME_MAX / CS_VERSION_MAX
require closing '"'
write name_len/version_len (u8)
copy name_inline (zero-pads trailing bytes to the slot end)
set CS_FLAG_HAS_NAME / CS_FLAG_HAS_VERSION in flags u32
```

Last-wins idempotence: a second `name :` / `version :` decl overwrites and zero-pads so no stale tail bytes survive from the first.

### 5.4 `parse_stability_decl`

```
skip_ws
require ':'
skip_ws
scan unquoted ident [A-Za-z][A-Za-z]*
length-switched classify:
    len 6  -> compare "stable"       -> stability = 1
    len 10 -> compare "deprecated"   -> stability = 3
    len 12 -> compare "experimental" -> stability = 2
    else                             -> CS_ERR_UNKNOWN_STABILITY
write stability u8
set CS_FLAG_HAS_STABILITY in flags u32
```

The length-switched classifier is the same pattern R222.M1 / R224.M1 use (`_sch_sig_classify_type`, `_ll_classify_type`). All three stability keywords have distinct lengths so there is no second-pass disambiguation needed.

### 5.5 `parse_cap_decl`

```
count guard:    n_caps < CS_MAX_CAPS                   (else TOO_MANY_CAPS)
capacity guard: 128 + (n_caps + 1) * 32 <= out_cap     (else OUT_TOO_SMALL)
skip_ws + require ':' + skip_ws
scan cap_name ident [A-Za-z_][A-Za-z0-9_]*             (len 1..CS_NAME_MAX)
spill cap_name_start, cap_name_len to [rsp+0], [rsp+8]
skip_ws + require ':' + skip_ws
require '0' + ('x' | 'X')
scan HEX_RIGHTS [0-9A-Fa-f]{1,16}; accumulate via (r << 4) | digit
spill cap_rights to [rsp+16]
call _cmd_sig_fnv1a64(bytes_ptr + cap_name_start, cap_name_len)
    -> rax = name_hash
compute cap_desc_ptr = out_ptr + 128 + n_caps * 32
    (stride multiply via `shl rN, 5` -- never `imul r, imm`)
write cap_desc[0..8]   = name_hash (u64)
write cap_desc[8..16]  = cap_rights (u64)
copy cap_desc[16..32]  = first min(cap_name_len, 16) bytes of cap name,
                         zero-padded past the copy
n_caps += 1
clear scratch slots
```

### 5.6 Success coda

```
done:
    write n_caps u8 at header[+4]
    write caps_len u32 = n_caps * 32 at header[+76]
    bytes_written = 128 + n_caps * 32
    return (bytes_written << 32) | CS_OK
```

### 5.7 Stack alignment

- Entry `rsp % 16 == 8` (SysV, after the implicit CALL that reached us).
- Six callee-save pushes: `rsp % 16` cycles 8 → 0 → 8 → 0 → 8 → 0 → 8 (even pairs round back to 8).
- `sub rsp, 24` for the three scratch slots: `rsp % 16 = (8 - 24) mod 16 = 0`.
- Both nested leaves (`_cmd_sig_skip_ws`, `_cmd_sig_fnv1a64`) run with `rsp % 16 == 0`, satisfying SysV alignment.
- Epilogue: `add rsp, 24; pop r15; …; pop rbx; ret`.

### 5.8 Encoder-pitfall posture

Reproduced from the module header (recorded here for ongoing audit per `feedback_pdx_encoder_pitfalls.md`):

- No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
- No `and rN, imm64` — every mask is imm8 or imm32 (`0xFF`, `0xFFFF`).
- No 2-op `imul r, imm` — cap stride is `shl rN, 5` (× 32). The FNV multiply uses `mul rcx` (one-op unsigned mul: `rdx:rax ← rax * rcx`), which is a distinct instruction shape from the pitfall-listed 2-op `imul r, imm`.
- No multiline `pub let = "..."` — single-line justifications.
- Module basename `CommandSig` matches `command_sig.pdx`.
- Labels prefixed `cmd_sig_` (NEVER `cs_` — `cs_*` is used by 203 kernel-side labels + 30 user-space labels across the repo, grep-confirmed at R222.M2 landing time). The public API still owns the `_cs_*` entry-point namespace since that is a distinct "with-underscore prefix" convention from the `cs_*` kernel label namespace.
- All `cmp reg, imm` immediates `<= 0x3303 < 0x80000000`, so direct `cmp reg, imm32` is sign-extension-safe. The FNV constants (offset basis `0xCBF29CE484222325` and prime `0x100000001B3`) are loaded via `mov rN, imm64` (REX.W + MOV imm64) — the same encoding `mov r10, 0xFFFFFFFFFFFFFFFF` in `libpdx-elevate/src/elevate_client_send.pdx` and `mov r10, 0x00FFFFFFFFFFFFFF` in `mkfs.pdxfs/src/elevate_gate.pdx` take.
- Byte loads via `xor rax, rax; mov_b rax, [base + idx]` (zero-extends into the full qword); byte stores via `mov_b [dst + disp], reg`, same shape as SchemasSig / LambdaLit / Pipeline.
- u32 stores via `mov_d [dst + disp], reg`; u64 stores via `mov [dst + disp], reg`.

---

## 6. Interactions with sibling modules

### 6.1 R221.M1 (`utf8_nfc.pdx`) upstream

The caller is expected to have already run the input bytes through `_u8n_decode_and_normalize` before handing them to `_cs_parse_body`. The parser may therefore assume valid UTF-8 and NFC form. Because the grammar accepts only ASCII keywords, ASCII punctuation (`,`, `:`, `"`, `{`, `}`), and ASCII values (names / versions / stability keywords / hex rights), the parser only ever inspects the ASCII subset of its input. Non-ASCII bytes inside a keyword or ident fall through to `CS_ERR_SYNTAX` via the ident-byte-class check (none of `0x80..0xFF` is in `[A-Za-z0-9_]`).

### 6.2 R222.M1 (`schemas_sig.pdx`) companion

The companion signature. A command's paideia-as functor module takes BOTH `(Schemas : SchemasSig)` and `(Caps : CommandSig)` as parameters; the two parsers run side by side at functor-elaboration time. The two modules do NOT share code (SchemasSig carries its own `_sch_sig_skip_ws` leaf; this module carries `_cmd_sig_skip_ws`) — the duplication is intentional at M1/M2 so neither module becomes a build-order dependency of the other. The fingerprint shapes are byte-identical in character though:

- SchemasSig emits a 16-byte-stride field-descriptor array terminated by an `SS_TYPE_END` sentinel.
- CommandSig emits a 128-byte header followed by an n_caps-sized 32-byte-stride CapDecl array (array length carried in the header, not an in-band sentinel).

Both arrays are pointer-free (every slot is inline), so both hash identically across host and kernel-side consumers.

### 6.3 R222.M3 (REPL dispatch) consumer

Consumes the CommandSig record at each command invocation. The elaborator reads the fields by fixed offset:

- `header[+4] u8` = n_caps (iteration bound),
- `header[+5] u8` = stability (policy gate: a `deprecated` command invoked without `--allow-deprecated` is refused),
- `header[+6]..header[+54] u8` = name (shell-displayed command name),
- `header[+56]..header[+72] u8` = version (shell-displayed in `describe <cmd>`),
- `header[+128]..header[+128 + n_caps * 32] u8` = cap array (iterated at `exec` time to resolve each cap handle against the parent task's cap table).

### 6.4 R222.M8 (serialization) consumer

Round-trips the (header + cap array) byte image through the queryable form the `describe <cmd>` builtin consumes. The 16-byte inline cap name is a stable primary key for the per-cap record; the `name_hash` u64 preserves full identity across truncation when the authoritative cap name (up to 48 bytes) is looked up from `commands.toml`.

### 6.5 R227.M2 (pds cap-decl checker, paideia-os#2650) lateral at `exec`

The kernel-side cap-decl checker reads the CommandSig cap array from the elf `.caps.decl` section at `exec` time and compares each `(name_hash, rights)` pair against the parent task's cap table. The byte-identical layout here (`name_hash` + `rights` at offsets 0 + 8 inside each CapDecl) is the direct match target the checker consumes. The checker's reader is a 16-byte LE u64 load pair per cap entry — no bit-shuffling needed.

### 6.6 R133.M2 (pds container header pragma gate) lateral at load

The pds container's header pragma pass (R227.M1 landed Wave 112) seats the CommandSig fingerprint into the container header; R133.M2 then reads it back at load time to verify the on-disk cap requirements match the elaborator's view. Fingerprint input shape: the full `128 + n_caps * 32` byte sequence, hashed with the standard container-fingerprint primitive (BLAKE3-truncated-64 per the pds container format spec).

### 6.7 R131.M1 (user-space UTF-8 primitives) non-dependency

This module does **not** call `_norm_nfc` or `utf8_decode_cp` directly; the normalisation pass is the caller's responsibility (R221.M1's `_u8n_decode_and_normalize`). Keeping the UTF-8 dependency one level upstream mirrors the compositional pattern elsewhere in the library.

---

## 7. Forward path

| Milestone | Scope | How it uses R222.M2 output |
|-----------|-------|----------------------------|
| R222.M3   | REPL dispatch | Reads n_caps, stability, name, version, flags from the header; iterates the cap array to resolve each cap handle at `exec` time. Also replaces R222.M1's `_ss_match_record` stub with the full record typecheck body. |
| R222.M4   | `ArgSpec` + `FlagSpec` | Adjacent signature parameters to SchemasSig + CommandSig. Reuses the length-switched classifier pattern. |
| R222.M5   | Registry client | Reads a serialized form of the CommandSig record from `/system/shell/commands.toml`; the on-disk form is the same byte sequence this module writes, with an endian-tagged container header. |
| R222.M6   | `commands.toml` bind | Binds a parsed-and-elaborated CommandSig to an elf path. Reads the cap `name_hash` directly to key the cap-table lookup. |
| R222.M8   | Serialization for `describe <cmd>` | Round-trips the (header + cap array) through the queryable form. The 16-byte inline cap name is the primary key; the hash preserves full identity. |

---

## 8. Testing posture (R222.M2)

R222.M2 lands with the parser only. Test fixtures land under R222.M7 (not scheduled yet) and will cover:

1. **Golden parses** — each of the three example forms (§2.3) parses to a byte-expected (header + cap array) sequence.
2. **Decl type coverage** — one fixture per decl (name-only, cap-only, version-only, stability-only), each landing the right header fields with the correct flag bits.
3. **Error taxonomy** — one fixture per error code (`CS_ERR_SYNTAX`, `CS_ERR_TOO_MANY_CAPS`, `CS_ERR_UNKNOWN_STABILITY`, `CS_ERR_OUT_TOO_SMALL`), with the cursor at the right byte on each failure.
4. **Boundary cases** — empty body (succeeds with n_caps=0 and all flags clear); the exactly-8-cap maximum; the exactly-48-character maximum name; the exactly-16-character maximum version; whitespace between every token; multiple consecutive whitespace characters; CRLF line endings between decls.
5. **Decl ordering** — same four decls in all 4! = 24 orderings; identical header + cap array output.
6. **Duplicate decls (last-wins)** — two `name :` decls with different names; verify the second overwrites and zero-pads; same for version and stability.
7. **Capacity exhaustion** — small `out_cap` values that trigger `CS_ERR_OUT_TOO_SMALL` on the N-th cap.
8. **Hex-rights parse** — `0x0`, `0x1`, `0xFFFFFFFFFFFFFFFF` (16 hex digits), `0X` + mixed case, 17-digit overflow.
9. **UTF-8 non-ASCII rejection** — a body containing `caπp:` or similar fails with `CS_ERR_SYNTAX` because `π` is not in `[A-Za-z0-9_]`.
10. **FNV hash determinism** — identical cap names produce identical hashes across runs; distinct cap names produce distinct hashes with no collision across the observed name set.

Until R222.M7 lands these as a fuzz corpus, R222.M3's REPL dispatch canary (a representative command module elaborated end-to-end) exercises the full parse path once.

---

## 9. Open follow-ups

- **R222.M? Hash choice swap.** Once the kernel-side `paideia_crypto_blake3_hash` call is reachable from user-space parser-tier libraries without breaking the "pure-leaf" discipline (likely via a R131.M? trampoline that keeps the linker surface flat), `_cmd_sig_fnv1a64` can be replaced with a BLAKE3-truncated-64 wrapper. The `name_hash` slot stays u64; no ABI break.
- **R222.M? Duplicate-cap detection.** M2 defers duplicate-cap-name detection to the elaborator at R222.M3. A later M-wave may want parser-tier rejection; the fix is an O(n) scan of the already-written cap array before the new write (n ≤ 8, so the cost is bounded).
- **R222.M? Rich cap specs.** Nested cap expressions (`cap: fs : {read, stat}`), cap name aliases, and `requires` / `provides` separation land when R222.M4 (`ArgSpec` / `FlagSpec`) and R222.M5 (registry client) wire the richer policy layer. The grammar extension is a one-production addition to `CapDecl`; backward-compat is preserved by introducing a new rights slot flag (`CS_CAP_FLAG_NESTED`) without changing the 32-byte stride.
- **R222.M? Richer stability tiers.** The current `{stable, experimental, deprecated}` set is the common minimum. Later waves may add `beta`, `internal`, `vendored`, etc. — each adds a new byte code (4..255 reserved) and a new case to the length-switched classifier.
- **R222.M? Empty cap decl list guard.** The current M2 implementation accepts a `command_sig { }` body with zero decls (header stays zero-filled, flags clear). A policy-layer upstream may want to reject commands without a name; the elaborator at R222.M3 enforces this via the `CS_FLAG_HAS_NAME` bit on the parsed header.

---

## 10. References

- paideia-os#2486 — R222 cmd-functor umbrella.
- paideia-os#2659 — THIS ticket, R222.M2 `CommandSig` body.
- paideia-os#2658 — R222.M1 `SchemasSig` body (companion, landed Wave 113).
- paideia-os#2651 — R221.M1 UTF-8/NFC parser-tier wrapper (upstream dependency).
- paideia-os#2650 — R227.M2 pds cap-decl checker (lateral consumer at `exec` time, landed Wave 115).
- paideia-os#2641 — R227.M1 pds header pragma (lateral consumer at container load, landed Wave 112).
- `design/terminal/semantic-shell.md` section 6 — Command modules (SH-D5).
- `design/terminal/semantic-shell-language-plan.md` section "R222 — Command-module functor surface + registry client" — the full R222.M1..M8 milestone sequence.
- `design/shell/cmd-functor-schemas-sig.md` — the R222.M1 design doc; this doc mirrors its section shape.
- `design/shell/pds-cap-decl-checker.md` — the R227.M2 design doc; the cap-decl checker consumes the CapDecl array this module emits.
- `design/shell/pds-header-pragmas.md` — the R227.M1 design doc; the container header carries the CommandSig fingerprint this module's output hashes to.
- `feedback_pdx_encoder_pitfalls.md` — the encoder-pitfall posture reproduced in §5.8.
