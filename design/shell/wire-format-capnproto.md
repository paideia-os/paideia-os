# Wire Format (Cap'n Proto-ish) for Cross-Boundary Shell Records (R223.M5)

**Status:** v0.1 (R223.M5 — paideia-os#2670)
**Date:** 2026-10-15
**Author:** softarch (Wave UMB-W30-R223M5)
**Scope:** The 32-byte-prelude + variable-payload wire frame that serialises a plaintext shell record into bytes suitable for process- or host-boundary transit, and the inverse. R223.M5 lands the SERIALIZATION LAYER only; the TRANSPORT (TCP + ChaCha20-Poly1305) is the OSARCH half under `svc/remote_record_wire.pdx` (R137.M4, paideia-os#2636).

---

## 1. Why this exists

`design/terminal/semantic-shell.md` names the cross-boundary pipeline as a first-class user surface:

```
find . @remote | sort by size      # R223 acceptance target
ls | filter { |r| r.size > 1024 } @jail:build
```

Both pipelines leave one address space and arrive in another. The receiver cannot just dereference the sender's record pointers; the record bytes must traverse a wire whose shape both ends agree on.

Cap'n Proto is the industry baseline for this shape. Its on-wire story (segment table + struct pointers + inline data) was designed for exactly the "record flows between two processes" use case. R223.M5 lands a MINIMAL SUBSET of Cap'n Proto's wire format sufficient for the acceptance pipeline and extensible to the full Cap'n Proto shape at M5.1+:

- single-segment frames (no segment table at raw M5);
- one top-level struct pointer per frame (no nested records, no pointer sections);
- inline data payload (no far pointers, no capability indirection).

The acceptance line from the brief —

> Cross-process pipeline `find . @remote | sort by size` fingerprint-round-trips; wire bytes match schema.

— decomposes into two invariants we commit to at raw M5:

1. **Byte-for-byte reproducibility.** Two independent serialisations of the same `(record_ptr, record_len, schema_tag)` triple produce byte-identical frames. The zero-fill prelude in `_ws_serialize_record` guarantees deterministic layout across the padded tail and the reserved fields.
2. **Schema identity.** The frame's `segment_id` field carries the caller-supplied `schema_tag` verbatim; the receiver's dispatcher routes by this field alone without having to walk the struct pointer or the payload.

**Why a satellite library, not kernel-side.** The parser-tier stays leaf: this module operates on caller-supplied byte buffers with zero `.bss` state at raw M5. The TRANSPORT (session key, nonce discipline, AEAD seal / open) lives one layer below in `svc/remote_record_wire.pdx` where it belongs; the user-space satellite serializes, the kernel-side transport encrypts and ships.

---

## 2. Wire frame — 32-byte prelude + variable payload

| offset | size | field               | notes                                                              |
|--------|------|---------------------|--------------------------------------------------------------------|
| `0x00` | `u32`  | `magic`           | `WS_FRAME_MAGIC` = `'WSNK'` LE = `0x4B4E5357`. Reads as "WSNK".     |
| `0x04` | `u16`  | `version`         | `WS_FRAME_VERSION` = `1`. Bumped on any wire-format change.         |
| `0x06` | `u16`  | `flags`           | Reserved; zero at M5. M5.1+ bit 0 = far-ptr frame, bit 1 = cap-carrying. |
| `0x08` | `u32`  | `seg_word_count`  | Cap'n Proto segment-table word count = `1 + data_words`.            |
| `0x0C` | `u32`  | `segment_id`      | Cap'n Proto segment id = `schema_tag` (caller-supplied).            |
| `0x10` | `u32`  | `record_len`      | Exact plaintext length (needed for byte-exact round-trip).          |
| `0x14` | `u32`  | `reserved`        | Zeroed.                                                              |
| `0x18` | `u64`  | `struct_pointer`  | Cap'n Proto struct pointer tag (field layout in §2.2 below).         |
| `0x20` | `u8[N]` | `payload`        | `record_ptr` bytes zero-padded to the next 8-byte boundary.         |

**Total frame size = `32 + ceil(record_len / 8) * 8`** with `record_len <= WS_RECORD_MAX (1024)`, so `data_words <= 128` and the maximum frame = `32 + 1024 = 1056` bytes.

### 2.1 Field-by-field rationale

- **`magic` + `version`.** Standard wire-format discipline (`CommandSig`'s `'CSIG'`, `FilterOp`'s `'FILT'`, `JobControl`'s `'JOBS'`, `DescriptorBlob`'s `'DESC'`, `History`'s `'HIST'`). `'WSNK'` LE = `0x4B4E5357` — the u32 whose little-endian representation reads as the identifier in a hex-dump sequential scan (per the Wave 125 `SortGroupReduce` magic-reconciliation lesson). `version = 1` locks the M5 commitment surface; a wire-format change bumps the field and the deserializer rejects stale frames with `WS_ERR_BAD_VERSION`.

- **`flags`.** 16 bits leaves room for 16 orthogonal frame flags; M5.1 will claim bit 0 for the far-pointer multi-segment extension (records exceeding `data_words <= 128`), bit 1 for the capability-carrying payload (records that carry opaque cap handles rather than value-type fields). The M5 serializer always emits 0; the M5 deserializer always IGNORES this field (reserved-bits-ignored discipline) so an M5.1 frame reaching an M5 reader survives the length / struct-pointer geometry gates and errors cleanly only on the unknown wire shape.

- **`seg_word_count` + `segment_id`.** The brief's "8B segment header (word count u32, segment id u32)" verbatim. `seg_word_count` is the Cap'n Proto segment-table word count = `1` (struct pointer word) + `data_words` (= `ceil(record_len / 8)`). `segment_id` carries the caller-supplied `schema_tag`; a receiver's dispatcher routes by this field alone, no struct-pointer walk required.

- **`record_len`.** Cap'n Proto's struct pointer tag carries only word-granularity `data_words` (0..128 at M5). To recover the exact byte length on deserialize, we carry a u32 `record_len` in the frame prelude. This lets the round-trip be byte-for-byte reproducible even when `record_len` is not a multiple of 8.

- **`reserved`.** 4 bytes earmarked for M5.1+ expansion (schema_version u16, payload-flag u16, serialization-sequence u32, etc.). Zeroed at M5; deserializers ignore this field at M5.

- **`struct_pointer`.** The brief's "8B struct pointer tag per field" — specifically, the single top-level struct pointer that describes the record's data section at M5. Cap'n Proto layout: see §2.2.

- **`payload`.** The caller's record bytes verbatim, with the tail zero-padded to the next 8-byte boundary. The pad bytes are **explicitly zeroed** (not undefined) so two independent serialisations of the same `(record_ptr, record_len, schema_tag)` triple produce byte-identical frames — the fingerprint-round-trip invariant from the brief's acceptance line.

### 2.2 `struct_pointer` field layout

The 8-byte struct pointer tag follows the Cap'n Proto convention:

| bits    | field                         | value at M5                                   |
|---------|-------------------------------|-----------------------------------------------|
| 0..1    | `kind`                        | `0` (STRUCT)                                   |
| 2..31   | `offset_in_words` (signed)    | `0` (payload immediately follows this pointer) |
| 32..47  | `data_section_words` (u16)    | `ceil(record_len / 8)` (0..128)               |
| 48..63  | `ptr_section_words` (u16)     | `0` (no pointer section at M5)                 |

Validated byte-for-byte on deserialize:

- low 32 bits (kind + offset) **must** be `0` or `WS_ERR_BAD_STRUCT_PTR`;
- bits 48..63 (ptr_words) **must** be `0` or `WS_ERR_BAD_STRUCT_PTR`;
- bits 32..47 (data_words) **must** equal `ceil(record_len / 8)` or `WS_ERR_BAD_STRUCT_PTR`.

Why the full Cap'n Proto struct pointer and not a bare `data_words` u16: when M5.1+ layers in per-field pointers (nested records, pointer sections), the struct pointer's reserved bits already encode the right geometry — we don't have to migrate every frame that landed under M5 to a new ABI shape. The reader at M5.1 will accept any `ptr_section_words` value (and point-section fields will decode as per the Cap'n Proto FAR pointer rules), while the M5 reader stays strict on zero.

### 2.3 Why 32 bytes of prelude

- Fits exactly in a single cache line's second half on x86-64 (32..64 if the frame is 64-byte aligned, so prelude + first 32 payload bytes fit one line; a 1 KiB max frame spans 17 lines).
- Power-of-two prelude → `(frame_bytes - 32) / 8 = data_words` uses `shr rN, 3` directly, never `imul r, imm`.
- Leaves 8 bytes of reserved tail (`reserved` u32 + unused half of `struct_pointer`'s pointer section if a future wire-format change needs two-pointer frames) for a one-M-version-bump path to the next wire shape.

---

## 3. Public API — `src/wire_sink.pdx`

```
module WireSink = structure {
    _ws_init() -> ()
    _ws_serialize_record(record_ptr, record_len, schema_tag, out, out_cap) -> packed_u64
    _ws_deserialize_record(wire, wire_len, out, out_cap) -> packed_u64
    _ws_schema_hash(name_ptr, name_len) -> u64
}
```

### 3.1 `_ws_init() -> ()`

Idempotent lazy boot hook. M5 holds **no** `.bss` state (every wire frame is caller-owned on both paths; the schema hash is a pure byte walk over a caller-supplied name buffer). The body is a bare `ret`. The entry point exists for parallelism with the parser-family init-hook convention (`_ds_init`, `_dm_init`, `_cmdreg_init`). A later landing that adds `.bss` (per-connection sequence counters, a schema_tag intern table, a per-session serialization-fault counter) fleshes it out behind the same name without an ABI break.

### 3.2 `_ws_serialize_record(record_ptr, record_len, schema_tag, out, out_cap) -> packed_u64`

Produce a wire frame at `out[0..required]` from the plaintext record at `record_ptr[0..record_len]` tagged with `schema_tag`.

Steps:

1. Validate `record_ptr != 0` (`WS_ERR_BAD_RECORD` on failure).
2. Validate `record_len <= WS_RECORD_MAX (1024)` (`WS_ERR_RECORD_TOO_LARGE` on failure).
3. Validate `out != 0`, `out_cap >= 32 + ceil(record_len/8)*8` (`WS_ERR_OUT_TOO_SMALL` on failure).
4. Zero-fill the entire frame region (header + payload + pad).
5. Stamp magic / version / `seg_word_count` / `segment_id` / `record_len` / `struct_pointer` header fields.
6. Copy `record_len` bytes from `record_ptr` to `[out + 32]` byte-by-byte.
7. Return `(frame_bytes << 32) | WS_OK` where `frame_bytes = 32 + ceil(record_len / 8) * 8`.

Register map: `(rdi, rsi, rdx, rcx, r8) -> rax`.

### 3.3 `_ws_deserialize_record(wire, wire_len, out, out_cap) -> packed_u64`

Validate a wire frame and extract the plaintext record bytes.

Steps:

1. Validate `wire != 0`, `wire_len >= 32`, `out != 0` (`WS_ERR_BAD_FRAME` on failure).
2. Validate magic `'WSNK'` at `[+0]` (`WS_ERR_BAD_MAGIC` on failure).
3. Validate `version` lo byte `1` at `[+4]`, hi byte `0` at `[+5]` (`WS_ERR_BAD_VERSION` on failure).
4. Read `seg_word_count` u32 at `[+8]`; validate `1 <= it <= 129` (`WS_ERR_BAD_SEG_HEADER` on failure).
5. Read `record_len` u32 at `[+16]`; validate `<= 1024` (`WS_ERR_RECORD_TOO_LARGE` on failure).
6. Compute `data_words_expected = ceil(record_len / 8)`; validate `seg_word_count == 1 + data_words_expected` (`WS_ERR_BAD_SEG_HEADER` on failure).
7. Read `struct_pointer` u64 at `[+24]`; validate low 32 bits == 0 (kind=0, offset=0), bits 48..63 == 0 (ptr_words=0), bits 32..47 == `data_words_expected` (`WS_ERR_BAD_STRUCT_PTR` on failure).
8. Validate `wire_len >= 32 + data_words_expected * 8` (`WS_ERR_BAD_FRAME` on failure).
9. Validate `out_cap >= record_len` (`WS_ERR_OUT_TOO_SMALL` on failure).
10. Copy `record_len` bytes from `[wire + 32]` to `out` byte-by-byte.
11. Return `(record_len << 32) | WS_OK`.

Register map: `(rdi, rsi, rdx, rcx) -> rax`.

### 3.4 `_ws_schema_hash(name_ptr, name_len) -> u64`

FNV-1a 64 of the schema name bytes. Byte-for-byte identical to `R222.M2 _cmd_sig_fnv1a64`, `R222.M3 _fi_fnv1a64`, `R222.M5 _cmdreg_fnv1a64`, and the inlined FNV in `R229.M5 _h_append`. Offset basis `0xCBF29CE484222325`; prime `0x100000001B3`. A zero-length input returns the offset basis unchanged (standard FNV behaviour).

The caller derives a 32-bit `schema_tag` from this 64-bit hash by truncation. The 32-bit width is tight for a universe-wide namespace (2^32 ~= 4.3e9 distinct tags) but comfortable for a per-session catalogue (hundreds of schemas); collision probability at 1000 schemas per session is ~1.2e-4 (birthday approximation).

Register map: `(rdi, rsi) -> rax`.

---

## 4. Status band — `0x5200..0x52FF`

| Code                            | Value   | Returned by                              |
|---------------------------------|---------|------------------------------------------|
| `WS_OK`                         | 0       | success on every entry point             |
| `WS_ERR_BAD_RECORD`             | 0x5200  | `_ws_serialize_record`: `record_ptr == 0` |
| `WS_ERR_RECORD_TOO_LARGE`       | 0x5201  | serialize: `record_len > 1024`; deserialize: wire's `record_len > 1024` |
| `WS_ERR_OUT_TOO_SMALL`          | 0x5202  | serialize: bad `out` buffer; deserialize: `out_cap < record_len` |
| `WS_ERR_BAD_FRAME`              | 0x5203  | deserialize: `wire == 0`, `wire_len < 32`, or geometry fail |
| `WS_ERR_BAD_MAGIC`              | 0x5204  | deserialize: magic != `'WSNK'`           |
| `WS_ERR_BAD_VERSION`            | 0x5205  | deserialize: version != `1`              |
| `WS_ERR_BAD_SEG_HEADER`         | 0x5206  | deserialize: `seg_word_count` geometry fails |
| `WS_ERR_BAD_STRUCT_PTR`         | 0x5207  | deserialize: struct pointer kind/offset/ptr_words/data_words bad |

Slots `0x5208..0x52FF` reserved for R223.M5.1+ (far-pointer errors, nested-record errors, cap-handle serialization errors, schema_tag conflicts, etc.).

The `0x5200..0x52FF` band carves a non-adjacent kilo-step past Wave 126's `0x5100..0x51FF` (R229.M5 History), `0x5000..0x50FF` (R224.M6 PipelineLambda), and `0x4F00..0x4FFF` (R222.M8 DescribeSig). The four prior R223 submodule bands (`0x2B00` Pipeline, `0x3400` RecordProjection, `0x4C00` FilterOp, `0x4D00` SortGroupReduce) remain error-disjoint so a downstream dispatcher's compound error path can distinguish wire-sink faults from every other R223 submodule fault.

---

## 5. Encoder discipline

Standard paideia-as discipline, with the module-specific nuance that **every entry point is a PURE LEAF** (zero callee-save pushes, no stack frame, no nested CALL).

- **No `test rN, rN`.** Every zero-check is `cmp reg, 0; je/jne` (precedent: command_sig.pdx, cmd_registry.pdx, describe_sig.pdx, history.pdx).
- **No `and rN, imm64`.** The single imm32 mask used (`and rax, 0xFFFF` for the `data_words` extract) has bit 31 clear so `and r64, imm32` sign-extends safely to `0x000000000000FFFF`.
- **No 2-op `imul rN, imm`.** The frame-size compute uses `add +7; shr 3; shl 3` (round-up to 8-byte boundary) and `shl rN, 3` (data_words * 8). The FNV multiply is one-op `mul rcx` (precedent: `_cmd_sig_fnv1a64:450`).
- **Variable shift via `shl rN, cl` / `shr rN, cl`** is **not** used at M5 — every shift amount in this module is a compile-time constant (1, 2, 3, 8, 32, 48).
- **No multiline `pub let = "..."`.** Single-line justifications.
- **Module basename.** `WireSink` matches `wire_sink.pdx` (per `feedback_pdx_encoder_pitfalls`).
- **Label prefix `ws_`.** Grep-confirmed unique against the parser-tier modules' prior prefixes (u8n_, gi_, wp_, sch_sig_, cmd_sig_, fi_, afs_, pl_, rp_, ll_, cc_, er_, cr_, cmdreg_, hm_, rt_, dl_, se_, te_, cl_, dm_, fo_, sgr_, jc_, fh_, ast_, sm_, ls_, lex_, eu_, h_, pl_lam_, ds_). The pre-existing `ws_`-family labels (`bdw_ws_*` in `src/kernel/core/fs/pdxfs/bdev_write.pdx`, `phc_ws_*` in `src/kernel/core/ipc/pcie_hotplug_channel.pdx`) are function-scoped under distinct parent prefixes (`bdw_`, `phc_`) and live in disjoint kernel-side linker namespaces — the same disjointness pattern `cap_row.pdx` and `cmd_registry.pdx` cite for their own prefixes. The public API still owns `_ws_*` as the entry-point namespace, distinct from `ws_*` as the function-local label namespace.
- **No chained-displacement addressing.** All `[base + off + idx]` expressions are precomputed into a scratch register via `add` first, then dereferenced via `[rN + 0]`. The single exception is `_ws_schema_hash`'s FNV loop which uses the two-register addressing form `mov_b r11, [r8 + r10]` byte-for-byte identical to `_cmd_sig_fnv1a64` (line 446) — this pattern is pdx-dialect-valid in the FNV-family precedent.
- **Immediates.** All `cmp reg, imm` immediates (0, 1, 7, 8, 32, 128, 129, 1024, magic `0x4B4E5357`, mask `0xFFFF`, status codes `0x5200..0x5207`, field offsets 0, 4, 5, 8, 12, 16, 24, 32) fit imm32 with bit 31 clear. The magic `0x4B4E5357 < 0x80000000`, so direct `cmp-imm32` is sign-safe. The two FNV constants (`0xCBF29CE484222325`, `0x100000001B3`) are the only >32-bit immediates in this file; both use the standard `mov r64, imm64` encoding.

---

## 6. Register-liveness discipline

All four entry points are pure leaves. The `r11` clobber contract never activates because no CALL fires. Register plans:

| Entry                     | Inputs (SysV)         | Scratch              | Return |
|---------------------------|------------------------|----------------------|--------|
| `_ws_init`                | —                      | —                    | ignored |
| `_ws_serialize_record`    | rdi,rsi,rdx,rcx,r8     | rax,r9,r10,r11       | rax    |
| `_ws_deserialize_record`  | rdi,rsi,rdx,rcx        | rax,r8,r9,r10,r11    | rax    |
| `_ws_schema_hash`         | rdi,rsi                | rax,rcx,rdx,r8..r11  | rax    |

- `_ws_serialize_record`: `rdi` (record_ptr) and `rcx` (out) are the two base pointers held unchanged across all loops; `rsi` (record_len) is read-only throughout (used in the payload-copy loop terminator and in the return frame-size recompute); `rdx` (schema_tag) is stored through to `[out+12]` early then free; `r8` (out_cap) is dead after the capacity validation and is reused as a loop-local address scratch; `r9` holds `data_words` across the header stamp (dies after `struct_pointer` stamp); `r10` holds `required_bytes` across the zero-fill loop (dies after zero-fill); `r11` is the loop index for zero-fill and payload-copy.
- `_ws_deserialize_record`: `rdi` (wire) and `rdx` (out) are the two base pointers held unchanged across all validation and the payload-copy loop; `rsi` (wire_len) is read-only; `rcx` (out_cap) is read-only after the capacity validation; `r8` holds `seg_word_count` across validation; `r9` holds `record_len` across validation and the payload-copy loop (used as copy terminator and return `bytes_written`); `r10` holds `data_words_expected` across the geometry validation; `r11` holds the `struct_pointer` u64 across its three sub-field validations, then is reused as the loop index.
- `_ws_schema_hash`: `rax` = hash accumulator; `rcx` = fnv_prime held across the loop; `rdx` = mul high half clobbered each iteration; `r8` = ptr saved; `r9` = len saved; `r10` = loop idx; `r11` = byte load scratch. Byte-for-byte register map match to `_cmd_sig_fnv1a64`.

---

## 7. Lazy-init discipline

**Not applicable at M5.** This module holds no `.bss` state. The wire frame is caller-owned on both the serialize and deserialize paths; the schema hash operates as a pure byte walk over a caller-supplied name buffer. `_ws_init` is a bare `ret` placeholder; a later landing that adds `.bss` (per-connection sequence counters, a schema_tag intern table, a per-session serialization-fault counter) will flesh it out behind the same name.

---

## 8. Acceptance

### 8.1 Fixture

The acceptance pipeline from the brief:

```
find . @remote | sort by size
```

decomposes into two record flows:

1. `find . @remote` emits a stream of `FileRecord` tuples (one per matched path). Each record is serialised to a wire frame tagged with `schema_tag = _ws_schema_hash("FileSchema", 10)`.
2. The remote host's inverse stage deserialises each frame, applies `sort by size`, and emits the sorted stream back.

**Minimal fixture at raw M5** (independent of the acceptance pipeline, for unit-testing the round-trip):

| record_bytes                 | record_len | schema_tag             | expected frame_bytes |
|------------------------------|-----------:|------------------------|---------------------:|
| `""` (empty)                 | 0          | 0x12345678             | 32                   |
| `"hello"`                    | 5          | 0x11111111             | 40                   |
| `"hello, world!"`            | 13         | 0x22222222             | 48                   |
| 1024-byte binary blob        | 1024       | 0x33333333             | 1056                 |

### 8.2 Round-trip test

For each of the four fixture rows:

- `_ws_serialize_record(record_bytes, record_len, schema_tag, &frame[0], 1056)` returns `(expected_frame_bytes << 32) | WS_OK`.
- `_ws_deserialize_record(&frame[0], expected_frame_bytes, &got[0], 1024)` returns `(record_len << 32) | WS_OK`.
- `got[0..record_len]` byte-equals `record_bytes`.
- Two independent serialisations of the same `(record_bytes, record_len, schema_tag)` triple produce byte-identical frames (the zero-fill prelude guarantees deterministic layout across the reserved regions and the padded tail).

### 8.3 Negative cases

- `record_len = 1025` returns `WS_ERR_RECORD_TOO_LARGE`.
- `out_cap = 31` (less than the minimum header) returns `WS_ERR_OUT_TOO_SMALL`.
- A frame with magic `0x00000000` returns `WS_ERR_BAD_MAGIC` on deserialize.
- A frame with version `2` returns `WS_ERR_BAD_VERSION`.
- A frame with `seg_word_count = 0` returns `WS_ERR_BAD_SEG_HEADER`.
- A frame with `struct_pointer.ptr_words != 0` returns `WS_ERR_BAD_STRUCT_PTR`.

### 8.4 Deferred to R223.M5.1+

- The `find . @remote | sort by size` cross-host round-trip (needs the R137.M4 TCP transport wired through).
- Fingerprint goldens for the smoke-mode asserter (will land alongside R223.M7 pipeline-fuzz corpus).
- 20-record stress test with record_len spanning `0..1024` in steps of 51 (approximates the data_words = 0, 7, 13, ..., 128 geometry corners).

---

## 9. Consumer pattern

The shell's cross-boundary dispatcher wraps `_ws_serialize_record` and `_ws_deserialize_record` in a two-layer sandwich with the R137.M4 ChaCha20-Poly1305 framer:

```
# pseudo-pdx
# -- sender --
let frame : [u8; 1056] = uninit;
let packed = _ws_serialize_record(record_ptr, record_len, schema_tag,
                                   &frame[0], 1056);
let frame_bytes = packed >> 32;
let _ = _rrw_send_record(conn_id, &frame[0], frame_bytes);     # R137.M4

# -- receiver (same code, inverted) --
let frame : [u8; 1056] = uninit;
let got   : [u8; 1024] = uninit;
let packed = _rrw_recv_frame(conn_id, &frame[0], 1056);        # R137.M4
let frame_bytes = packed >> 32;
let out_packed = _ws_deserialize_record(&frame[0], frame_bytes,
                                         &got[0], 1024);
let record_len = out_packed >> 32;
# got[0..record_len] is the plaintext record
```

The R137.M4 layer handles cryptographic confidentiality, integrity, and nonce replay rejection; the R223.M5 layer handles schema identity and byte-exact round-trip. Each layer's acceptance is independent and provable.

---

## 10. Where this is NOT

- **Not a full Cap'n Proto implementation.** M5 lands single-segment frames with one top-level struct pointer and no pointer section. The far-pointer encoding, nested records, and capability tunnelling are deferred to M5.1+. The record wire is compatible-forward with Cap'n Proto's full shape — the struct pointer tag and segment header are byte-exact — but M5's deserializer rejects frames exceeding the minimal subset.
- **Not a transport.** The TCP wire and ChaCha20-Poly1305 AEAD live in `svc/remote_record_wire.pdx` (R137.M4). M5 produces the plaintext payload the AEAD then seals; M5 consumes the plaintext payload after the AEAD opens. The two layers never share state.
- **Not a capability conveyor.** A frame carries bytes, not cap handles. A record that references a capability must serialize an opaque u64 ID that the receiver re-mints against its own capability chain; M5.3 lands the KIND_HANDLE serializer for records that carry opaque cap handles rather than value-type fields.
- **Not a schema registry.** The `schema_tag` is caller-managed. A receiver that dispatches by tag must have the matching schema interned via R222.M5 CmdRegistry (or a sibling schema registry at R222.M1+); M5 does not maintain this mapping.
- **Not a canonical form.** Two records with the same semantic content but different byte representations (e.g. different field ordering in a struct) produce different wire frames. Canonical form landing at R223.M6 — the pipeline-stage canonical-form renderer — is a separate serialization layer that normalises the record BEFORE the wire-sink serialize call.

---

## 11. File footprint

- `tools/user/libpdx-pds-parser/src/wire_sink.pdx` — new module `WireSink`, four public entry points, zero `.bss`.
- `tools/user/libpdx-pds-parser/src/lib.pdx` — version 1.26.0 → 1.27.0; `LPX_PDS_PARSER_R223_M5_READY` 0 → 1.
- `tools/user/libpdx-pds-parser/caps.decl` — new `0x5200..0x52FF` band section + R223.M5 catalogue paragraph + linker-dep entry.
- `tools/user/libpdx-pds-parser/CHANGELOG.md` — new `[1.27.0]` stanza.
- `tools/user/libpdx-pds-parser/STATUS.md` — R223.M5 landed row + version bump.
- `.plans/scratch/CHANGELOG-R223M5.md` — per-primitive scratch CHANGELOG for main's batch-close consolidator.
- `design/shell/wire-format-capnproto.md` — this document.

---

## 12. Forward path

- **R223.M5.1 — Per-field struct pointers.** New entry point `_ws_serialize_record_typed(record_ptr, record_len, schemas_sig_body, schemas_sig_len, schema_tag, out, out_cap)` reads R222.M1 SchemasSig per-field type codes and emits per-field struct pointers inside the data section. Enables nested-record deserialisation on the receiver without walking the opaque payload bytes.
- **R223.M5.2 — Far-pointer / multi-segment framing.** Lifts the `WS_RECORD_MAX = 1024` ceiling by introducing a segment table at the frame prelude and far-pointers inside the struct pointer tag. `flags` bit 0 marks a far-ptr frame; the segment table lives at `[+32..+32+8*n_segments]` ahead of the payload.
- **R223.M5.3 — Capability tunnelling.** `flags` bit 1 marks a cap-carrying payload. Each cap handle inside the record is serialised as an opaque u64 ID the receiver re-mints against its own capability chain; the KIND_HANDLE registry runs the two-sided bind.
- **R223.M5.4 — Zero-copy / scatter-gather deserialize.** Direct-into-arena deserializer that bypasses the byte-copy loop for record payloads already resident at the correct alignment (common on receivers that preallocate a per-schema arena).
- **R223.M5.5 — Fingerprint pass.** Hash the full wire frame into a per-record fingerprint the smoke-mode asserter can compare across sender and receiver for the acceptance pipeline.

---

## 13. Related docs

- `design/shell/remote-record-wire.md` — the R137.M4 ChaCha20-Poly1305 framer one layer below (OSARCH half of the cross-boundary pipeline).
- `design/shell/pipeline-stage-parser.md` — the R223.M1 pipeline stage parser that produces the records this wire format serialises.
- `design/shell/pipeline-record-projection.md` — R223.M2 record projection, the first stage whose records flow across the wire.
- `design/shell/sort-group-reduce.md` — R223.M4 standard aggregation combinators (the acceptance pipeline's `sort by size`).
- `design/shell/cmd-functor-schemas-sig.md` — R222.M1 SchemasSig, which will supply per-field type codes to M5.1's typed serializer.
- `design/shell/describe-wire-format.md` — R222.M8 DescribeSig, the companion serializer for command-signature discovery (same wire-format discipline, different payload shape).
- `design/shell/history-storage.md` — R229.M5 History, the first intra-process record substrate (shares the FNV-1a 64 identity hash).
- `design/terminal/semantic-shell.md` — the user-facing semantic-shell contract this layer serves.
