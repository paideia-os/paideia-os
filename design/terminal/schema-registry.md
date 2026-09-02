# Schema Registry — kernel-side substrate

**Round:** R90-XREPO.012 (parent #2000)
**Landed:** 2026-09-01
**Scope closed by this doc:** M1-002 (#2123), M2-001 (#2124), M2-002 (#2125),
M3-001 (#2126), M5-002 (#2128 consolidation)
**Deferred / follow-up:** M5-001 (#2127 tool wiring — kernel-side API surface
frozen here; `cat`/`doc` wire-up is a separate landing against
`paideia-os/cat` + `paideia-os/doc`).
**Client side:** `libpdx-schema-registry` M1..M4 shipped 2026-09-01 —
`Registry::bind_by_name` now points at a real daemon.

## 1. Why a schema registry belongs in the kernel

Every semantic-pipe consumer (`ls`, `cat`, `doc`, `pdxcurl`, `pdxdig`,
`pdxping`, `pdxsock`, `pdxtrust`, `pkg`, `libpdx-semantic-pipe`) needs
one authoritative answer to the same question: *given the fingerprint
of a schema I received on the wire, what schema is it?* Answering that
in each library independently duplicates the table 10 times and leaves
the tools disagreeing whenever one library's table drifts. Answering
it once in the kernel is the whole point of `svc.schema-registry` — a
single name-space so that a `PdxFsDirEntry` handle minted by `ls` is
byte-for-byte the same handle a downstream `doc` obtains via
`bind_by_name`.

The kernel side is the smallest possible thing that makes the client
libraries stop lying:

- a fixed-size, in-memory registry table (no persistence at R90; a
  future R121 landing takes that up alongside the mount-visible
  `/system/schemas/` directory);
- a name-lookup and name-registration RPC on a well-known endpoint;
- a capability kind (`KIND_SCHEMA_HANDLE`) that carries a resolved
  handle so consumers can hold and pass one via the normal cap
  machinery.

## 2. Record types (M1-002)

Three record types live at the client<->daemon boundary. The first two
match the shape `libpdx-schema-registry` already ships in its M1..M4
sweep (2026-09-01); the third is the kernel's own view.

### 2.1 Field descriptor (client side)

```
Field {
  name       : [u8; 32]    // NUL-terminated
  type_code  : u16         // enum: U8=1, U16=2, U32=3, U64=4, I64=5,
                           //       BYTES=6, STR=7, CAP_REF=8
  offset     : u16         // byte offset within the enclosing record
  size       : u32         // byte width of this field
}
```

Fixed 40-byte descriptor. The type code enum is deliberately closed at
R90 — a caller that needs a type the enum does not name registers a
whole new schema rather than smuggling one through a widened enum.

### 2.2 Schema descriptor (client side)

```
Schema {
  name        : [u8; 32]        // e.g. "PdxFsDirEntry@0.1\0"
  version_maj : u16             // canonical name carries "@<maj>.<min>"
  version_min : u16
  record_size : u32             // bytes per record on the wire
  field_count : u16
  reserved    : [u8; 6]
  fields      : Field[field_count]
}
```

Header + a flat run of `Field` descriptors. Maximum `field_count` at
R90 is bounded by the daemon's `SREG_SCHEMA_MAX_BYTES` (see §4).

### 2.3 SchemaHandle (kernel side — `KIND_SCHEMA_HANDLE` tail)

The capability tail a consumer holds after a lookup. Row layout:

```
SchemaHandle tail (24 bytes = three u64 words)
  [+0]  schema_id  (u32)         // registry-assigned, monotonic from 1
  [+4]  refcount   (u32)         // outstanding handles for this id
  [+8]  owner_pid  (u64)         // pid that first registered the schema
  [+16] flags      (u64)         // reserved (0 at R90)
```

Handles minted by lookup carry `owner_pid = the pid that *registered*`
the schema, not the pid that looked it up — the field describes
authorship, not the current holder. `refcount` is bookkeeping the
kernel maintains as handles are minted and revoked; ring-3 does not
write it. `flags` is reserved (zero on mint); future rounds carry an
`is_evolvable` bit here when the schema-evolution rule below wants a
per-row switch.

Rights on a `KIND_SCHEMA_HANDLE` (M3-001):

- `R_SCHEMA_READ  = 0x001` — every QUERY op gates on this. This is
  what a lookup mints.
- `R_SCHEMA_WRITE = 0x002` — reserved for the schema-evolution
  landing that lets a future round bump a schema's `flags`. Never
  minted at R90.

Ops (dispatched via `cap_invoke`, gated on `R_SCHEMA_READ`):

- `SREG_OP_QUERY_NAME`   (0) — returns the schema's name bytes.
  Copies at most `SREG_NAME_BYTES` (32) bytes into the caller
  buffer; NUL-terminated.
- `SREG_OP_QUERY_HANDLE` (1) — returns `schema_id` as a u64. The
  caller uses this to correlate against records it saw on the wire.

The two ops parallel the client-facade contract `libpdx-schema-
registry` M1 froze: a bound handle answers "what is your name" and
"what is your fingerprint id", nothing more. Every other question
(field list, record shape) is answered by the schema descriptor bytes
themselves, which live in the registry's schema store (§4) and are
read back through a follow-up round's `SREG_OP_QUERY_SCHEMA_BYTES` op.

## 3. Fingerprint semantics

Fingerprint == the 64-bit FNV-1a hash of the schema's name bytes.

The client-side library places a placeholder here pending a BLAKE3
intrinsic in `paideia-as`. The kernel daemon matches: FNV-1a-64 over
the NUL-terminated name string (name-only hash, not
name+field-descriptors — so a schema is uniquely identified by its
name/version pair). Once `paideia-as` ships BLAKE3, both sides move to
`BLAKE3(name || 0x00 || flat_field_descriptors)[0..8]` in the same
release; every stored schema is re-hashed on that upgrade, which
requires bumping every schema's version — see §5.

The FNV-1a-64 constants are:

- offset basis: `0xCBF29CE484222325`
- prime:        `0x00000100000001B3`

Standard byte-at-a-time algorithm: `hash = (hash ^ byte) * prime` for
each byte of the name string (excluding trailing NUL).

## 4. Daemon (M2-001) — `src/kernel/core/ipc/schema_registry.pdx`

Follows the `elevate_broker.pdx` / `audit_journal_broker.pdx` pattern
one-for-one:

- canonical name literal `svc.schema-registry` (19 bytes, NUL-padded to 32);
- well-known endpoint id: `SCHEMA_REGISTRY_ENDPOINT_ID = 18`
  (adjacent to `elevate_broker=16`, `audit_journal=17`);
- `schema_registry_bringup()` — one boot-time call from
  `kernel_main.pdx` claims the endpoint via `endpoint_alloc_at(18)`
  and publishes the name via `svc_register`;
- `sreg_register(name_ptr, name_len, schema_ptr, schema_len)` ->
  `schema_id` or a `SREG_ERR_*` code;
- `sreg_lookup(name_ptr, name_len)` -> `schema_id` or `SREG_LOOKUP_NONE`;
- `sreg_list()` -> current row count.

Storage caps (all statically allocated at .bss):

- `SREG_MAX = 64` schemas — one row per registered schema.
- `SREG_ROW_BYTES = 48` — `{fnv[+0] u64, schema_id[+8] u32,
  owner_pid[+12] u32-hi16-of-u16 pad, len[+16] u32, off[+20] u32,
  in_use[+24] u8, name[+25] u8[23]}` (name field NUL-padded to 23).
- `SREG_SCHEMA_STORE_BYTES = 4096` — one contiguous store where the
  schema descriptor bytes live end-to-end; each row's `off` and
  `len` name a slice of this store.

Name-dedup discipline: on `sreg_register`, compute FNV-1a-64 of the
name; scan every live row for an equal hash AND an exact name-bytes
match (hash-collision robustness); refuse a duplicate register with
`SREG_ERR_DUP` (registrations are idempotent under equal `(name,
schema_bytes)`, refused under a name-collision-with-different-bytes).

Ceilings that refuse:

- `name_len == 0` or `name_len > 22` -> `SREG_ERR_BAD_NAME`
- `schema_len == 0` -> `SREG_ERR_BAD_SCHEMA`
- `schema_len > SREG_SCHEMA_BYTES_MAX (512)` -> `SREG_ERR_TOO_BIG`
- all 64 rows in use -> `SREG_ERR_FULL`
- name already registered with different bytes -> `SREG_ERR_DUP`
- schema-store slack < schema_len -> `SREG_ERR_STORE_FULL`

## 5. Versioning strategy

The canonical schema name carries `@<maj>.<min>` — the M1..M4 client
library has already agreed on `"PdxFsDirEntry@0.1"` and
`"RawByteChunk@0.1"` as the two seeded types. Two adjacent versions
are two distinct schemas as far as the registry is concerned; the FNV
fingerprint differs because the name differs, and both may live in
the registry side by side (once a consumer library needs both).

Evolution rules:

- Additive-only within a `<maj>.<min>` pair: adding a new field at
  the end, widening a reserved zone, or turning a reserved byte into
  a real field is REFUSED as an in-place update. The registrar must
  bump `<min>` and register the new schema alongside the old one so
  every consumer that referenced the old fingerprint keeps resolving
  to the old shape.
- A `<maj>` bump signals a wire-incompatible change (record size or
  field-offset move); the old schema stays live for readers of
  historical streams.
- Because the R90 registry has no persistence, every boot starts
  empty; the initial seed set is registered by whichever consumer
  registers first (typically `libpdx-schema-registry`'s own boot
  init routine when the first tool loads it).

## 6. `svc_broker` name-table entry (M2-002)

The kernel-side `svc_register` primitive is generic — a name
registration is just a call to it with the canonical name and the
endpoint id. `schema_registry_bringup()` in
`src/kernel/core/ipc/schema_registry.pdx` performs the two-step
`endpoint_alloc_at(18) + svc_register("svc.schema-registry", 19, 18)`
sequence, matching the `elevate_broker_bringup()` shape exactly.

After bringup:

- `svc_lookup("svc.schema-registry", 19)` returns endpoint id 18.
- A client's `libpdx-schema-registry::Registry::bind_by_name` call
  becomes a real endpoint bind (not the inert placeholder every M4
  satellite `pipe_wire.pdx` still notes in its README).

## 7. Error semantics — summary

Every failure code sits in the `0xFFFFEB30..0xFFFFEB3F` band (next
free after `KIND_NIC`'s `0xFFFFEB28..0xFFFFEB2F` claim at R91.M1-001):

```
SREG_OK                = 0
SREG_ERR_BAD_NAME      = 0xFFFFEB3F   // len 0 or > 22
SREG_ERR_BAD_SCHEMA    = 0xFFFFEB3E   // schema_len == 0
SREG_ERR_TOO_BIG       = 0xFFFFEB3D   // schema_len > SREG_SCHEMA_BYTES_MAX
SREG_ERR_FULL          = 0xFFFFEB3C   // no free row
SREG_ERR_DUP           = 0xFFFFEB3B   // name collision, different bytes
SREG_ERR_STORE_FULL    = 0xFFFFEB3A   // schema store exhausted
SREG_LOOKUP_NONE       = 0xFFFFFFFFFFFFFFFF   // miss

// KIND_SCHEMA_HANDLE-specific band
KSH_MINT_BAD_ID        = 0xFFFFEB39   // schema_id > SREG_MAX or not live
KSH_BAD_RIGHTS         = 0xFFFFEB38   // op invoked without R_SCHEMA_READ
KSH_BAD_SLOT           = 0xFFFFEB37   // row_id out of range or free
KSH_TAIL_BAD_ARG       = 0xFFFFEB36   // op_arg[63:8] non-zero
KSH_TAIL_ENOSPC        = 0xFFFFEB35   // KIND_SCHEMA_HANDLE pool full
```

## 8. Capability shape (M3-001)

`KIND_SCHEMA_HANDLE = 0x1B2`. The ordinal at R90-XREPO.012 landing:

- 0x1AD -> `KIND_NIC` (R91.M1-001)
- 0x1AE -> reserved for `KIND_DISPLAY_BACKEND` (R101.M1-001, GUI plan)
- 0x1AF -> reserved for `KIND_FRAMEBUFFER` (R101.M3-001)
- 0x1B0 -> reserved for `KIND_PAGE_FLIP` (R104.M4-001)
- 0x1B1 -> reserved for `KIND_HOTPLUG_CHANNEL` (R105.M4-001)
- **0x1B2 -> `KIND_SCHEMA_HANDLE` (this landing)** — first slot past
  the R101..R105 GUI reservation block; grep-verified as unclaimed
  by any `kind_*.pdx` or design doc at landing time.

Base: derived over `KIND_MEMORY = 4` — the schema store the handle
references is ordinary memory, and the derivation gate is the same
"cannot widen memory reach beyond what you already hold" rule
`KIND_PDXFS_MOUNT_TABLE` and `KIND_TUI_CANVAS` use.

Row pool: 32 rows x 32 bytes = 1024 bytes. 32 outstanding schema
handles is one order above the 10-consumer count in `ECOSYSTEM_STATUS.
md` — headroom for the fan-out that will come when every emitter
holds two or three handles simultaneously.

## 9. IPC protocol shape

The daemon exposes three verbs — `REGISTER`, `LOOKUP`, `LIST` — over
its endpoint. Wire format at R90 is deliberately trivial (this is a
kernel-embedded seam, not a network protocol):

- `REGISTER`: caller marshals `{name_bytes, schema_bytes}` into a
  frame; daemon returns `{schema_id, err}`. Idempotent under equal
  `(name, schema_bytes)`.
- `LOOKUP`: caller marshals `{name_bytes}`; daemon returns
  `{schema_id, err}`. `err = SREG_LOOKUP_NONE` on miss.
- `LIST`: caller sends an empty frame; daemon returns
  `{row_count, err}`. Streaming enumeration of the actual rows is
  deferred to a follow-up landing (needs a real record-of-records
  wire format).

The client-facade `libpdx-schema-registry` M1..M4 sweep already
implements these three verbs as its public surface; the kernel-side
daemon here is the final wire endpoint they hit through
`bind_by_name`.

## 10. Size limits — summary

- `SREG_NAME_BYTES     = 32` (Field / Schema descriptor names)
- `SREG_ROW_NAME_MAX   = 22` (daemon-side row name field, incl. NUL padding)
- `SREG_MAX            = 64` schemas
- `SREG_SCHEMA_BYTES_MAX = 512` per schema
- `SREG_SCHEMA_STORE_BYTES = 4096` total store
- `KIND_SCHEMA_HANDLE`  pool: 32 rows x 32 bytes = 1024 bytes

These bounds match one order of magnitude above the current 10-consumer
count. A future round widens the store to a paged allocator when a
consumer registers a genuinely large schema (the doc-tool's roadmap
suggests one is coming for RichText@0.x).

## 11. Adding a new schema (author-facing)

The `libpdx-schema-registry` client library documents the tool
sequence; this section names the kernel-side invariants an author must
respect:

1. Choose a canonical name of the form `<Type>@<maj>.<min>` where
   `<Type>` is CamelCase and `@<maj>.<min>` is monotonic across the
   type's history. Total bytes strictly under 22 (NUL takes byte 22).
2. Freeze the field layout: name/offset/size/type_code per field, in
   declaration order. Adding a field later requires bumping `<min>`.
3. Pack into the `Schema` descriptor (§2.2). Total descriptor bytes
   must fit in `SREG_SCHEMA_BYTES_MAX = 512`.
4. Call `libpdx-schema-registry::register()` with `(name_bytes,
   schema_bytes)` at the tool's boot time. The kernel-side registrar
   returns a `schema_id`; the library caches it and every subsequent
   `bind_by_name` for that name resolves to the same id (until the
   next boot).
5. Emit records on the semantic-pipe prefixed by the returned
   `schema_id` so downstream consumers can either resolve the name
   via a follow-up `bind_by_name` or use the id as an opaque
   correlation key.

## 12. What is NOT closed by this landing

- **Persistence.** The registry is memory-only at R90; a boot
  re-registers every schema. A future round wires `/system/schemas/`
  into pdxfs so authored schemas survive reboot.
- **Streaming LIST enumeration.** `SREG_OP_LIST` returns row count
  only; a real record-of-records enumeration lands with the follow-up
  round that also lands `SREG_OP_QUERY_SCHEMA_BYTES`.
- **Second/third consumer onboarding (M5-001 / #2127).** `cat` and
  `doc` are external tool repos and the wire-up belongs in those
  repos; the kernel-side API surface documented here IS the surface
  they will consume. Tracked as a separate landing against
  `paideia-os/cat` and `paideia-os/doc` — see the follow-up issue
  filed by the M5-001 close-out.
- **BLAKE3 fingerprint.** Both sides move together the release after
  `paideia-as` ships the BLAKE3 intrinsic (`paideia-as#1341` and its
  follow-ons).
- **Schema evolution as a live op.** The `R_SCHEMA_WRITE` right is
  reserved but never minted; a future round adds `SREG_OP_EVOLVE`
  that lets an owning pid replace a schema's bytes at the same id
  (only under strict additive-append rules).

## 13. Files under this milestone

- `design/terminal/schema-registry.md` (this doc — M1-002, M5-002)
- `src/kernel/core/ipc/schema_registry.pdx` — daemon + bringup (M2-001, M2-002)
- `src/kernel/core/cap/kind_schema_handle.pdx` — capability kind (M3-001)
- `src/kernel/core/cap/kind.pdx` — `KIND_SCHEMA_HANDLE = 0x1B2` const
- `src/kernel/core/cap/invoke.pdx` — dispatch branch
- `src/kernel/boot/kernel_main.pdx` — `schema_registry_bringup()` call
