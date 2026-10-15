# `describe <cmd>` Wire Format (R222.M8)

**Status:** v0.1 (R222.M8 — paideia-os#2665)
**Date:** 2026-10-15
**Author:** softarch (Wave UMB-W29-R222M8)
**Scope:** The 256-byte `DescriptorBlob` wire format that materialises a `CommandSig` (R222.M2) into a queryable record for the `describe <cmd>` builtin and the "commands operating on `FileSchema`" semantic-query surface. The record is denormalised from `CommandSig` so that both query shapes are O(1) index lookups rather than requiring per-call reparse.

---

## 1. Why this exists

`design/terminal/semantic-shell.md` §6.4 lists the discovery surface every command exposes to the shell:

> The shell's tab completion queries the registry for available commands. Each command's signature is the discovery surface:
> * Command name
> * Argument names + types
> * Flag names + types
> * Required capabilities
> * Help text
>
> This is the "semantically queryable" feature applied to commands themselves — the user can ask the shell "what commands operate on PDFs?" and get a typed answer.

The authoritative source of each command's signature is already landed:

| Record         | Milestone | Format                                            |
|----------------|-----------|---------------------------------------------------|
| `SchemasSig`   | R222.M1   | INPUT / OUTPUT record shape                       |
| `CommandSig`   | R222.M2   | 128-B header + up to 8×32-B `CapDecl` (identity)  |
| `FunctorInst`  | R222.M3   | per-invocation materialisation                    |
| `ArgSpec`      | R222.M4   | 32-B per positional parameter                     |
| `FlagSpec`     | R222.M4   | 32-B per named flag                               |
| `CmdRegistry`  | R222.M5   | per-session catalogue of the above                |
| `DispatchMode` | R222.M6   | light-vs-heavy classifier over `resource_mask`    |

What those seven records lack is a **flat, denormalised view** suitable for O(1) querying:

- `describe find` needs name + arg list + flag list + cap list + stability in one hit.
- `commands operating on FileSchema` needs to scan every registered command's schema list in one scan.
- `commands requiring type str` needs to scan every registered command's arg-type bitmap.

Rebuilding those views by reparsing `CommandSig` + `SchemasSig` + `ArgSpec` + `FlagSpec` on every query is wasteful; the shell wants a cached, flat image. R222.M8 (this landing) lands that cached image: the `DescriptorBlob`.

**Why a satellite library, not kernel-side.** Same reasoning as R222.M1..M6: the shell runs in user space, the DescriptorBlob is produced once at functor-elaboration time (and refreshed at session boot by walking the registry), and no kernel-side consumer dereferences it. The parser-tier stays leaf.

---

## 2. Wire format — `DescriptorBlob` (256 B)

| offset | size | field              | notes                                                                 |
|--------|------|--------------------|-----------------------------------------------------------------------|
| `0x00` | `u32`  | `magic`          | `DS_BLOB_MAGIC` = `'DESC'` LE = `0x43534544`. Reads as "DESC".        |
| `0x04` | `u16`  | `version`        | `DS_BLOB_VERSION` = `1`. Bumped on any wire-format change.            |
| `0x06` | `u16`  | `flags`          | Low 16 bits of `CommandSigHeader+80` copied verbatim.                 |
| `0x08` | `u64`  | `name_hash`      | FNV-1a 64 of the command name (caller-supplied).                      |
| `0x10` | `u8[32]` | `name_inline`  | First 32 bytes of `CommandSig` `name_inline[48]` (truncated).         |
| `0x30` | `u16`  | `arg_count`      | 0 at raw M8; populated by M8.1 companion-signature folder.            |
| `0x32` | `u16`  | `flag_count`     | 0 at raw M8; populated by M8.1.                                       |
| `0x34` | `u16`  | `schema_count`   | 0 at raw M8; populated by M8.1 (count of valid `schema_hash_ids`).    |
| `0x36` | `u16`  | `reserved`       | zeroed.                                                               |
| `0x38` | `u64`  | `cs_body_ref`    | pointer back to the authoritative `CommandSig` record.                |
| `0x40` | `u8[32]` | `arg_type_mask`| 256-bit bitmap: bit N set iff type_code N appears in any `ArgSpec`.   |
| `0x60` | `u8[32]` | `schema_hash_ids`| list of up to 32 `u8` schema tags, valid at `[0..schema_count)`.    |
| `0x80` | `u8[128]` | `query_payload`| reserved for queryable predicates; format undefined pending R229+.   |

**Total: 256 bytes (`DS_BLOB_BYTES`).**

### 2.1 Field-by-field rationale

- **`magic` + `version`.** Standard wire-format discipline (`CommandSig`'s `'CSIG'`, `FilterOp`'s `'FILT'`, `JobControl`'s `'JOBS'`). `'DESC'` LE is `0x43534544` — the u32 value whose little-endian representation reads as the identifier in a hex-dump sequential scan (per the Wave 125 `SortGroupReduce` magic-reconciliation lesson in `CHANGELOG` and `design/shell/sort-group-reduce.md`). `version = 1` locks M8's commitment surface; a wire-format change bumps the field and the deserializer rejects stale blobs with `DS_ERR_BAD_BLOB`.

- **`flags`.** Low 16 bits of `CommandSig` `flags` u32 at `+80` (M2's `CS_FLAG_HAS_*` triple). A downstream `describe` consumer tests the same bits a `CommandSig` reader would, without having to walk back to the authoritative record. 16 bits leaves headroom for 13 more flag kinds past M2's 3-bit baseline.

- **`name_hash`.** Caller-supplied FNV-1a 64 of the command name. Byte-identical to `R222.M2 _cmd_sig_fnv1a64`, `R222.M3 _fi_fnv1a64`, `R222.M5 _cmdreg_fnv1a64` — the four parser-family FNV leaves share constants (offset basis `0xCBF29CE484222325`, prime `0x100000001B3`) so a hash computed anywhere in the family compares equal everywhere else. The caller passes this value already-computed; `_ds_serialize` does **not** recompute to avoid a second scan of the same bytes.

- **`name_inline[32]`.** First 32 bytes of `CommandSig` `name_inline[48]`. The DescriptorBlob trades a slightly tighter inline window for the whole-record 256-byte stride (power of two → stride multiply is `shl idx, 8`). The `name_hash` preserves full identity for any name length up to `CS_NAME_MAX = 48`. The shell renders the full name by walking back to `cs_body_ref` on demand (e.g., `describe --verbose <cmd>`), which is one of the two consumers of the field anyway.

- **`arg_count` / `flag_count` / `schema_count`.** Three u16 counts of the companion-signature artefacts. Zero at raw M8 (this landing has no companion-signature folder — the serializer is single-source from `CommandSig` only). M8.1 wires in the `ArgSpec` + `FlagSpec` + `SchemasSig` bodies.

- **`cs_body_ref`.** Caller-managed pointer back to the authoritative `CommandSig` record. Opaque at this tier; the shell layer treats it as the handle for "`describe --verbose`" or any query that wants the full cap array (not denormalised into the DescriptorBlob at M8 because the 8×32 B cap array doesn't fit the 128 B `query_payload` slot anyway — the shell layer walks back to `cs_body` on demand).

- **`arg_type_mask[32]`.** 256-bit bitmap over type codes `AFS_TYPE_*` (`u64=1`, `i64=2`, `str=3`, `hex=4`, `hash32=5`, `tsc=6`, `path=8`, `pid=9`, `unknown=255`). Bit N set iff type_code N appears in any `ArgSpec` of the command. "Commands requiring type `str`" is a single `_ds_matches_type(blob, 3)` call per candidate blob. 32 bytes is 4× the headroom needed for M4's eight distinct type codes.

- **`schema_hash_ids[32]`.** List of up to 32 u8 schema tags, valid at indices `[0, schema_count)`. "Commands operating on `FileSchema`" is a `_ds_matches_schema(blob, tag_of_FileSchema)` call per candidate blob. 32 slots covers all reasonable per-command schema counts (every landed `SchemasSig` has at most 2 schemas: one input, one output).

- **`query_payload[128]`.** Reserved for a future semantic-query DSL (R229+). Format intentionally undefined at M8 — the slot exists so later milestones can layer-fill without a wire-format major bump.

### 2.2 Why 256 bytes

- Power-of-two stride → the DescriptorBlob catalogue (an N-blob array) uses `shl idx, 8` for stride multiply, never `imul r, imm` (per `feedback_pdx_encoder_pitfalls`).
- Fits two cache lines on x86-64 (64 B lines). Sequential scan of a catalogue of N commands is 2N line fetches — predictable prefetch behaviour.
- Leaves 128 bytes of reserved tail (`query_payload`) for future expansion; 256 B is 8× the current M8 payload (16 B header + ~40 B active fields + 64 B bitmaps).

---

## 3. Public API — `src/describe_sig.pdx`

```
module DescribeSig = structure {
    _ds_init() -> ()
    _ds_serialize(cs_body, cs_len, name_hash, out, out_cap) -> status
    _ds_deserialize(blob, blob_len, out_cs_body_ref, out_name_hash) -> status
    _ds_matches_type(blob, type_code) -> bool
    _ds_matches_schema(blob, schema_tag) -> bool
}
```

### 3.1 `_ds_init() -> ()`

Idempotent lazy boot hook. M8 holds **no** `.bss` state (the DescriptorBlob is caller-owned on every path), so the body is a bare `ret`. The entry point exists for parallelism with the `DispatchMode` (R222.M6) / `CmdRegistry` (R222.M5) init-hook family. A later landing that adds `.bss` (per-session describe counters, a schema_tag intern table) fleshes it out without an ABI break.

### 3.2 `_ds_serialize(cs_body, cs_len, name_hash, out, out_cap) -> status`

Produce a 256-byte DescriptorBlob at `out[0..256]` from the parsed `CommandSig` record at `cs_body[0..cs_len]`.

Steps:

1. Validate `cs_body != 0`, `cs_len >= CS_HEADER_BYTES (128)`, `CSIG` magic (`0x47495343`) at `[cs_body + 0]`.
2. Validate `out != 0`, `out_cap >= DS_BLOB_BYTES (256)`.
3. Zero-fill the 256-B blob via a u64 stepping loop (32 iterations stepping by 8).
4. Stamp:
   - `magic 'DESC'` u32 at `[+0]`
   - `version` u16 lo byte `1` at `[+4]` (hi byte stays zero from step 3)
   - `flags` lo/hi bytes copied from `[cs_body + 80..82]` to `[+6..+8]`
   - `name_hash` u64 at `[+8]`
5. Copy 32 bytes of `CommandSig` `name_inline` (at `[cs_body + 8..40]`) to `[+16..+48]`.
6. Write `cs_body_ref` u64 (= `cs_body` input) at `[+56]`.
7. Leave `arg_count` / `flag_count` / `schema_count` / `reserved` / `arg_type_mask` / `schema_hash_ids` / `query_payload` zero. M8.1 populates those from companion sigs.
8. Return `DS_OK` (0).

Error returns: `DS_ERR_BAD_RECORD (0x4F00)` on bad `cs_body`, `DS_ERR_OUT_TOO_SMALL (0x4F01)` on bad `out`.

Register map: `(rdi, rsi, rdx, rcx, r8) -> rax`.

### 3.3 `_ds_deserialize(blob, blob_len, out_cs_body_ref, out_name_hash) -> status`

Validate a DescriptorBlob and extract the two load-bearing identity fields.

Steps:

1. Validate `blob != 0`, `blob_len >= 256`, `out_cs_body_ref != 0`, `out_name_hash != 0`.
2. Validate `'DESC'` magic (`0x43534544`) at `[+0]` and `version` lo byte `1` at `[+4]`.
3. Write `*out_cs_body_ref := blob[+56]` u64.
4. Write `*out_name_hash := blob[+8]` u64.
5. Return `DS_OK`.

Error returns: `DS_ERR_BAD_BLOB (0x4F02)` on any validation failure.

Register map: `(rdi, rsi, rdx, rcx) -> rax`.

### 3.4 `_ds_matches_type(blob, type_code) -> bool`

Test bit `type_code` of the `arg_type_mask` bitmap at `[blob + 64..96]`.

Steps:

1. Validate `blob != 0`, `type_code <= 255`. Return 0 on either fail.
2. `byte_idx = type_code >> 3`; `bit_idx = type_code & 7` (imm8 mask).
3. Load `byte = [blob + 64 + byte_idx]` (zero-extended).
4. Return `(byte >> bit_idx) & 1` via `shr r, cl` + `and r, 1`.

At raw M8 the bitmap is zero-filled, so this returns 0 for every type_code until M8.1 wires in the companion-signature folder.

Register map: `(rdi, rsi) -> rax`.

### 3.5 `_ds_matches_schema(blob, schema_tag) -> bool`

Scan `schema_hash_ids` at `[blob + 96..128]` for an entry equal to `schema_tag`.

Steps:

1. Validate `blob != 0`, `schema_tag in [1..255]` (0 is the "no schema" sentinel). Return 0 on fail.
2. Read `schema_count` u16 at `[blob + 52]` via two byte loads (`lo | (hi << 8)`).
3. Cap `schema_count` at `DS_SCHEMA_HASH_IDS_MAX (32)` for safety.
4. If `schema_count == 0`, return 0.
5. Scan `[blob + 96 + i]` for `i in 0..schema_count`; return 1 on the first byte-match, else 0.

At raw M8 the list is empty, so this returns 0 for every schema_tag until M8.1 wires in the companion-signature folder.

Register map: `(rdi, rsi) -> rax`.

---

## 4. Status band — `0x4F00..0x4FFF`

| Code                            | Value   | Returned by                              |
|---------------------------------|---------|------------------------------------------|
| `DS_OK`                         | 0       | success on every entry point             |
| `DS_ERR_BAD_RECORD`             | 0x4F00  | `_ds_serialize`: bad `cs_body` input     |
| `DS_ERR_OUT_TOO_SMALL`          | 0x4F01  | `_ds_serialize`: bad `out` buffer         |
| `DS_ERR_BAD_BLOB`               | 0x4F02  | `_ds_deserialize`: any validation fail   |
| `DS_ERR_TOO_MANY_SCHEMAS`       | 0x4F03  | **reserved** for M8.1 fold path          |

Slots `0x4F04..0x4FFF` reserved for M8.1 (companion-signature folder) and M8.2+ (per-blob fingerprint mismatch, `query_payload` decoder errors, etc.).

The 0x4F00..0x4FFF band carves a non-adjacent kilo-step past Wave 125's 0x4E00..0x4EFF (R229.M4 JobControl). The six prior R222 submodule bands (0x2A00 SchemasSig, 0x3300 CommandSig, 0x3900 FunctorInstance, 0x3C00 ArgFlagSpec, 0x4500 CmdRegistry, 0x4800 DispatchMode) remain error-disjoint so a downstream dispatcher's compound error path can distinguish describe-serialization faults from every other R222 submodule fault.

---

## 5. Encoder discipline

Standard paideia-as discipline, with the module-specific nuance that **every entry point is a PURE LEAF** (zero callee-save pushes, no stack frame, no nested CALL).

- **No `test rN, rN`.** Every zero-check is `cmp reg, 0; je/jne` (precedent: command_sig.pdx, cmd_registry.pdx, dispatch_mode.pdx).
- **No `and rN, imm64`.** Bit-isolation uses imm8 variants: `and rN, 7` for the bit_idx isolate in `_ds_matches_type`, `and rN, 1` for the final bit mask (precedent: dispatch_mode.pdx line 422 `and rax, 0x3C` imm8 variant).
- **No 2-op `imul rN, imm`.** The 256-B zero-fill uses a u64 stepping loop (32 iters stepping by 8); the name copy steps byte-by-byte.
- **Variable shift uses `shl rN, cl` / `shr rN, cl`.** Precedent: `cap_row.pdx:1204 shl rdx, cl` (R224.M4 `_cr_check_env`); also `pdxfs_lite/alloc.pdx:192 shr r11, cl`. The variable shift consumes CL (low byte of RCX) implicitly.
- **No multiline `pub let = "..."`.** Single-line justifications (per `feedback_pdx_encoder_pitfalls`).
- **Module basename.** `DescribeSig` matches `describe_sig.pdx` (per `feedback_pdx_encoder_pitfalls`).
- **Label prefix `ds_`.** Grep-confirmed unique against the parser-tier modules' prior prefixes (u8n_, gi_, wp_, sch_sig_, cmd_sig_, fi_, afs_, pl_, rp_, ll_, cc_, er_, cr_, cmdreg_, hm_, rt_, dl_, se_, te_, cl_, dm_, cl_, fo_, sgr_, jc_, fh_, ast_, sm_, ls_, lex_, eu_). The lone pre-existing `ds_`-family label (`pdxl_in_ds_*` in `src/kernel/core/fs/pdxfs_lite/inode.pdx`) is function-scoped and lives in a disjoint kernel-side linker namespace — the same disjointness pattern `cap_row.pdx` and `cmd_registry.pdx` cite for their own prefixes. The public API still owns `_ds_*` as the entry-point namespace, which is distinct from `ds_*` as the function-local label namespace.
- **No chained-displacement addressing.** All `[base + off + idx]` expressions are precomputed into a scratch register via `add` first, then dereferenced via `[rN + 0]` (precedent: `command_sig.pdx` name-copy loops lines 821-830).
- **Immediates.** All `cmp reg, imm` immediates (0, 1, 7, 32, 128, 255, 256, magic `0x47495343` and `0x43534544`, status codes `0x4F00..0x4F03`, field offsets 0, 4, 6, 8, 16, 48, 50, 52, 54, 56, 64, 96, 128) fit imm32 with bit 31 clear. The two magic values are both `< 0x80000000`, so direct `cmp-imm32` is sign-safe. **No** immediate in this file needs the imm64 encoding.

---

## 6. Register-liveness discipline

All five entry points are pure leaves. The `r11` clobber contract never activates because no CALL fires. Register plans:

| Entry           | Inputs (SysV)        | Scratch         | Return |
|-----------------|----------------------|-----------------|--------|
| `_ds_init`      | —                    | —               | ignored |
| `_ds_serialize` | rdi,rsi,rdx,rcx,r8   | rax,r9,r10,r11  | rax    |
| `_ds_deserialize`| rdi,rsi,rdx,rcx     | rax,r9          | rax    |
| `_ds_matches_type`| rdi,rsi            | rax,rcx,r9,r10  | rax    |
| `_ds_matches_schema`| rdi,rsi          | rax,r8,r9,r10,r11 | rax  |

`_ds_matches_type` uses `rcx` to carry `bit_idx` into `cl` for the variable shift; `rcx` is scratch (not a SysV input slot for a 2-arg function once we're past the Microsoft ABI, and SysV uses `rcx` as the 4th arg which this function doesn't consume).

`_ds_matches_schema` uses `r8` to carry `schema_count` across the scan loop; `r8` is caller-save and clobbered by any CALL, but this function has no CALL so `r8` lives safely.

---

## 7. Lazy-init discipline

**Not applicable at M8.** This module holds no `.bss` state. The DescriptorBlob is caller-owned on both the serialize and deserialize paths; the matches predicates operate as pure bitmap tests over a caller-supplied blob.

The `_ds_init` entry point is a bare `ret` placeholder. A later landing that adds `.bss` (per-session describe counters, a schema_tag intern table) will flesh it out behind the same name.

---

## 8. Acceptance

### 8.1 Fixture

Five `CommandSig` records (M2 landing fixture, reused byte-for-byte):

1. `name: "find", cap: fs_read_dir : 0x01, cap: fs_stat : 0x02, version: "0.1.0", stability: experimental`
2. `name: "grep", cap: fs_read : 0x01, version: "0.2.0", stability: stable`
3. `name: "where", version: "1.0.0", stability: stable`
4. `name: "sort", version: "0.5.0", stability: experimental`
5. `name: "describe", cap: cmdreg_read : 0x01, version: "0.1.0", stability: experimental`

### 8.2 Round-trip test

For each of the five records:

- `_ds_serialize(cs_body, cs_len, name_hash, blob, 256)` returns `DS_OK` and writes a 256-byte blob.
- `_ds_deserialize(blob, 256, &got_cs_ref, &got_hash)` returns `DS_OK`, `got_cs_ref == cs_body`, `got_hash == name_hash`.
- Two independent serializations of the same `(cs_body, cs_len, name_hash)` triple produce byte-identical blobs (the zero-fill prelude guarantees deterministic layout across the reserved regions).

### 8.3 Query predicates (deferred to M8.1)

The brief's acceptance line "`describe find` returns the right ArgSpec set" is a two-stage anchor:

- **M8 raw landing (this spec).** `_ds_serialize` populates magic / version / flags / name_hash / name_inline / cs_body_ref. `_ds_matches_type` and `_ds_matches_schema` return 0 for every query (bitmaps are zero-filled). The 5-record round-trip above is the M8 acceptance.
- **M8.1 companion-signature folder.** `_ds_serialize_full(cs_body, cs_len, args_body, args_len, flags_body, flags_len, schemas_body, schemas_len, name_hash, out, out_cap)` layers the companion signatures into the bitmap slots. The `describe find` acceptance ("the right ArgSpec set") anchors here. The current landing locks the API shape so M8.1 is purely additive.

---

## 9. Consumer pattern

The shell's `describe <cmd>` builtin walks the registered DescriptorBlob catalogue:

```
# pseudo-pdx
let name_buf : [u8; 65] = uninit;
let blob     : [u8; 256] = uninit;

let row = cmdreg_list_first();
while row != CMDREG_LIST_END {
    let entry_ptr = cmdreg_entry_ptr(row);
    let cs_body   = u64 at [entry_ptr + 8];
    let name_hash = u64 at [entry_ptr + 0];
    let _         = ds_serialize(cs_body, 128, name_hash, &blob[0], 256);

    if ds_matches_schema(&blob[0], TAG_OF_FILE_SCHEMA) {
        shell_render_describe_hit(&blob[0]);
    }
    row = cmdreg_list_next(row);
}
```

The "commands operating on `FileSchema`" query is identical minus the `shell_render_describe_hit` call being replaced with a one-line summary emitter.

---

## 10. Where this is NOT

- **Not a replacement for `CommandSig`.** The DescriptorBlob is a denormalised view; the authoritative record stays `CommandSig` at `cs_body`. `describe --verbose` walks back through `cs_body_ref` for the full cap array.
- **Not a cap handle.** The DescriptorBlob does not reify cap handles. The 8×32 B cap array stays at `CommandSig+128`; the shell layer resolves per-cap bindings via `R227.M2` at `exec` time.
- **Not a persistent on-disk format.** The blob lives in RAM only. A later landing may serialise the catalogue to disk under a `/system/shell/describe.cache` path; at M8 the shell rebuilds it at every session boot (walking `CmdRegistry`).
- **Not a cursor.** Catalogue walks use `CmdRegistry`'s `_cmdreg_dump` or the yet-to-land `_cmdreg_list_first`/`_next` iterator (R222.M8.1 companion). This module provides only the per-entry serialization + querying, not the enumeration.
- **Not transactional.** A DescriptorBlob snapshotted at session boot does not reflect per-request registration changes. `CmdRegistry` is write-once-per-session (M5 scope); hot reload (CRG-O1) remains deferred.

---

## 11. File footprint

- `tools/user/libpdx-pds-parser/src/describe_sig.pdx` — new module `DescribeSig`, five public entry points, zero `.bss`.
- `tools/user/libpdx-pds-parser/src/lib.pdx` — version 1.23.0 → 1.24.0; `LPX_PDS_PARSER_R222_M8_READY` 0 → 1.
- `tools/user/libpdx-pds-parser/caps.decl` — new 0x4F00..0x4FFF band section + R222.M8 catalogue paragraph + linker-dep entry.
- `tools/user/libpdx-pds-parser/CHANGELOG.md` — new `[1.24.0]` stanza.
- `tools/user/libpdx-pds-parser/STATUS.md` — R222.M8 landed row + version bump.
- `.plans/scratch/CHANGELOG-R222M8.md` — per-primitive scratch CHANGELOG for main's batch-close consolidator.
- `design/shell/describe-wire-format.md` — this document.

---

## 12. Forward path

- **R222.M8.1 — Companion-signature folder.** New entry point `_ds_serialize_full` (or similar) threads `ArgSpec` / `FlagSpec` / `SchemasSig` bodies in, populates `arg_count` / `flag_count` / `schema_count` / `arg_type_mask` / `schema_hash_ids`. The acceptance "`describe find` returns the right ArgSpec set" anchors here.
- **R222.M8.2 — `describe` builtin wire-up.** The shell-side `describe <cmd>` reads the DescriptorBlob catalogue and renders human-readable output. Lives in `src/user/shell/describe_cmd.pdx` (not this library).
- **R222.M8.3 — `query_payload` decoder.** Once the semantic-query DSL at R229+ is specified, M8.3 lands the layered encoder/decoder for the 128-byte reserved slot.
- **R222.M8.4 — On-disk cache.** Serialise the catalogue to `/system/shell/describe.cache` and reload at session boot (skipping the per-command reparse pass).
- **R222.M8.5 — Fingerprint pass.** Hash the 256-byte DescriptorBlob into a per-command fingerprint the registry client can compare against the `CommandSig` fingerprint at session boot for drift detection.

---

## 13. Related docs

- `design/shell/cmd-functor-command-sig.md` — the authoritative `CommandSig` record this blob denormalises from (R222.M2).
- `design/shell/cmd-functor-schemas-sig.md` — the input/output record shapes `schema_hash_ids` tags refer back to (R222.M1).
- `design/shell/arg-flag-spec-typing.md` — the `ArgSpec` / `FlagSpec` records M8.1 will fold into `arg_type_mask` (R222.M4).
- `design/shell/command-registry-client.md` — the per-session catalogue a DescriptorBlob catalogue tracks (R222.M5).
- `design/shell/light-heavy-dispatch.md` — the sibling R222 primitive that reads `resource_mask` from `CommandSig+84` (R222.M6).
- `design/shell/command-discovery-api.md` — the kernel-side `KIND_CMD_MODULE` enumeration surface the shell layer wraps (R123.M5).
- `design/terminal/semantic-shell.md` §6.4 — the semantically-queryable discovery contract this blob materialises.
