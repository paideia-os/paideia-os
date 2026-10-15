# `.pds` binary container format (R133.M1)

**Issue:** paideia-os#2620 (UMB-W26 R133.M1)
**Code:** `src/kernel/core/pds/container_reader.pdx`
**Status:** M1 landed; M2..M5 planned.

## 1. What a `.pds` container is, and why

A `.pds` file exists in two shapes along its life cycle:

1. **Source** -- a human-authored UTF-8/NFC-normalised text file (see
   `design/shell/parser-utf8-nfc.md`) whose first lines are **header
   pragmas** processed by `src/kernel/core/pds/header_pragma.pdx`
   (R227.M1, Wave 112). Source files are the input to the
   `paideia-shell` toolchain and are what tab-completion, history
   replay, and interactive editing operate on.

2. **Container** -- a compiled binary form, emitted by the toolchain,
   that packages one or more sections (text, rodata, capability
   declarations, signature, metadata) into a single file suitable for
   loading by the kernel's **R131 pds-loader** (future). Containers
   are what the kernel actually consumes at `pds exec <file>` time;
   they are what gets cached, signed, and shipped between hosts.

The container format addresses the problems the text form cannot:

* **One-shot bounds-checking.** The entire structural shape of a
  compiled program is known from a fixed 16-byte header plus a packed
  array of 32-byte section headers; the kernel can validate the file
  in a single pure-leaf pass with no allocation.
* **Signed loading.** A dedicated `CT_SEC_SIGNATURE` section carries
  an Ed25519 signature over the rest of the file (verification lands
  in R133.M2). The capability-signing root established by R63 is the
  trust anchor; unsigned containers refuse to load in strict mode.
* **Deterministic cap-env binding.** A dedicated `CT_SEC_CAPS_DECL`
  section describes exactly which capabilities the compiled commands
  need and expect; the loader materialises a `KIND_CAP_ENV` row from
  this declaration before any text byte executes (R133.M3). Compare
  with the ELF route from `elf-caps-decl.md`: `.pds` containers reach
  the same destination through a bespoke, kernel-native shape.
* **Hot-replaceable sections.** Each section is addressable by
  offset+size; a future R133.M5 shadow-table swap allows one section
  to be updated without reparsing the rest, same pattern as R123.M6
  UMB-W8 `_cmd_registry_reload`.

### Why not reuse ELF?

Three reasons:

* **Scope.** ELF carries machine-code loading, relocation, dynamic
  linking, and debug information. A `.pds` container ships compiled
  paideia-shell command bytecode, not native code. The kernel decodes
  it into `KIND_CMD_MODULE` rows, not into executable pages. ELF's
  machinery is strictly dead weight for this shape.
* **Verification cost.** ELF validation in a bounded, kernel-internal
  context is painful: the format has 20+ years of accreted shape and
  dozens of edge cases (`.gnu.hash` vs `.hash`, program headers
  overlapping section headers, allocation of segments without
  sections). A 16-byte header + up to 32 fixed-size section records
  can be bounds-checked in ~40 lines of hand-rolled .pdx.
* **Capability substrate alignment.** The `CT_SEC_CAPS_DECL` payload
  shape is designed around `KIND_CAP_ENV`'s wire record; ELF has no
  concept of capabilities and the `elf-caps-decl.md` plan reaches
  this ground by GLUING a sidecar section onto a generic ELF file.
  A native container skips the glue.

## 2. Binary layout

### Container header (16 bytes, offset 0)

| byte range   | field        | type | value / semantics                   |
|--------------|--------------|------|-------------------------------------|
| `[0..4]`     | `magic`      | u32  | `0x50445343` ('PDSC' little-endian) |
| `[4..8]`     | `version`    | u32  | `1` at M1                           |
| `[8..12]`    | `n_sections` | u32  | `0 .. CT_MAX_SECTIONS (32)`         |
| `[12..16]`   | `reserved`   | u32  | zero at M1 (future flags)           |

The magic value is `0x50445343`. Interpreted as four little-endian
bytes on disk, that is `0x43, 0x53, 0x44, 0x50` -- the ASCII bytes
`C`, `S`, `D`, `P` in that order. The `'PDSC'` mnemonic in comments
is the human-readable aid, not the on-disk byte order. Readers do a
single `cmp` against `0x50445343` on a zero-extended u32 load.

Version 1 is the ONLY accepted version at M1. The parser rejects
`version != 1` with `CT_ERR_BAD_VERSION`; a later milestone adds
`version` dispatch (see §5).

`n_sections` is capped at `CT_MAX_SECTIONS = 32`. This is a kernel
side limit, not a disk-format limit: the container COULD in principle
describe more, but a reader buffer of `32 * 32 = 1024` bytes
accommodates every program the shell command surface will ever ship
at this phase. A future milestone raises the cap only when a real
workload demands it.

`reserved` is written as zero. Readers IGNORE it (no reject-on-nonzero
at M1 -- that gives us room to populate it later without a version
bump).

### Section header (32 bytes each, offset 16 + i*32)

| byte range   | field    | type   | semantics                             |
|--------------|----------|--------|---------------------------------------|
| `[0..4]`     | `kind`   | u32    | `CT_SEC_*` ordinal (§3)               |
| `[4..8]`     | `offset` | u32    | bytes from container start to payload |
| `[8..12]`    | `size`   | u32    | payload byte count                    |
| `[12..16]`   | `flags`  | u32    | per-kind semantics (M1: zero)         |
| `[16..32]`   | `name`   | u8[16] | human mnemonic, NUL-padded ASCII      |

The `name` field is NOT consulted by the loader; it is for operator
diagnosis only (e.g. `pds info foo.pds` prints the names of each
section it finds). Compilers are encouraged to populate it with
something human-meaningful: `"main"`, `"strings"`, `"caps"`, etc.

The `flags` field is reserved for per-kind semantics in M2+:

* `CT_SEC_TEXT` -- future: alignment hint, relocation posture.
* `CT_SEC_CAPS_DECL` -- future: strict-decl vs lax-decl bit.
* `CT_SEC_SIGNATURE` -- future: signature algorithm selector.

### Payload layout

Each section's bytes live at `container_start + section.offset` for
`section.size` bytes. The reader does NOT enforce any ordering,
alignment, or non-overlap of payloads at M1 -- it only checks that
each `offset + size <= buf_len`. Later milestones may add non-overlap
checks (§5).

### Parse-time invariants

A conforming container satisfies all seven invariants the reader
enforces (see `container_reader.pdx` SECTION 1 for the authoritative
list and SECTION 3 for the error-code mapping):

| id | invariant                             | error on failure           |
|----|---------------------------------------|----------------------------|
| I1 | `buf_len >= 16`                       | `CT_ERR_BAD_MAGIC`         |
| I2 | `magic == 0x50445343`                 | `CT_ERR_BAD_MAGIC`         |
| I3 | `version == 1`                        | `CT_ERR_BAD_VERSION`       |
| I4 | `n_sections <= 32`                    | `CT_ERR_SECTION_COUNT`     |
| I5 | `buf_len >= 16 + n_sections*32`       | `CT_ERR_SECTION_OVERRUN`   |
| I6 | per section: `offset + size <= buf_len` | `CT_ERR_SECTION_OVERRUN` |
| I7 | `out_cap >= n_sections*32`            | `CT_ERR_OUT_TOO_SMALL`     |

The `offset + size` arithmetic in I6 is done in 64-bit registers
over two zero-extended u32 loads, so the sum cannot overflow (max
value: `2^33 - 2`). The reader does NOT need a dedicated overflow
check.

## 3. Section kinds (M1)

Five kinds are defined at M1. The reader is agnostic -- it passes
unknown kinds through so a forward-compatible loader can skip them.
Enforcement bindings live in R131/R133 M2+:

| kind                 | value | payload shape                              | consumer                          |
|----------------------|-------|--------------------------------------------|-----------------------------------|
| `CT_SEC_TEXT`        | 1     | compiled paideia-shell command bytecode    | `cmd_module_open_from_pds` (M4)   |
| `CT_SEC_RODATA`      | 2     | raw bytes (strings, constant tables)       | referenced by TEXT                |
| `CT_SEC_CAPS_DECL`   | 3     | `KIND_CAP_ENV` wire record                 | `cap_env_from_decl` (M3)          |
| `CT_SEC_SIGNATURE`   | 4     | 64-byte Ed25519 sig + 32-byte pubkey fprint | `pds_sign_verify` (M2)           |
| `CT_SEC_META`        | 5     | UTF-8 TLV stream                           | `pds info` operator surface       |

Kinds >= 6 are RESERVED at M1 and SHOULD not appear in a conforming
container. A reader that encounters one does NOT reject (it is up
to downstream enforcement) -- this preserves forward compatibility
with later milestones.

### Signature section detail (M2 preview)

The `CT_SEC_SIGNATURE` payload is a fixed 96 bytes:

* `[0..64]` -- Ed25519 signature bytes.
* `[64..96]` -- 32-byte SHA-256 digest of the public key.

The signature is computed over the container prefix `buf[0..sig_off)`
concatenated with the container suffix `buf[sig_off+sig_size..len)`;
that is, over everything EXCEPT the signature section's own bytes.
This lets the signing tool emit the container, hash it, then stamp
in the signature without a chicken-and-egg loop. Verification will
be implemented in R133.M2 against the capability-signing root key
established in R63 (`design/kernel/capability-signing-root.md`).

### Capability-declaration section detail (M3 preview)

The `CT_SEC_CAPS_DECL` payload is a `KIND_CAP_ENV` wire record. This
is the same shape produced by `cap_env_serialize` in R131.M2 and
consumed by `cap_env_from_decl` in R131.M3 (future). The container
reader does NOT decode this payload -- it only locates it and
reports its offset+size to the loader.

Containers SHOULD carry at most ONE `CT_SEC_CAPS_DECL` section. A
reader finding more than one at M3+ enforcement time rejects with a
later-added `CT_ERR_DUPLICATE_CAPS_DECL`; the M1 reader passes
duplicates through (the loader is expected to detect them).

## 4. Return-code taxonomy

The reader returns a packed `u64` from `_ctr_parse`:

```
bits [15: 0]   = status  (CT_* code)
bits [31:16]   = 0 (reserved)
bits [63:32]   = count (on CT_OK) or reserved for future
                 per-section error packing
```

Status codes carve out the `0x2900..0x29FF` block:

| code                        | value   | semantics                                      |
|-----------------------------|---------|------------------------------------------------|
| `CT_OK`                     | `0x0000`| success; `bits[63:32] = n_sections_parsed`     |
| `CT_ERR_BAD_MAGIC`          | `0x2900`| magic != `0x50445343`, or `buf_len < 16`       |
| `CT_ERR_BAD_VERSION`        | `0x2901`| version != 1                                   |
| `CT_ERR_SECTION_COUNT`      | `0x2902`| `n_sections > 32`                              |
| `CT_ERR_SECTION_OVERRUN`    | `0x2903`| section-header stream or payload overshoots    |
| `CT_ERR_OUT_TOO_SMALL`      | `0x2904`| `out_cap < n_sections*32`                      |
| `CT_ERR_NOT_FOUND`          | `0x2905`| `_ctr_locate_section` only                     |

The `0x2900` prefix is adjacent to R227.M1's `0x2800..0x2803` pds
header-pragma block. The `.pds` subsystem thus claims `0x28xx` for
textual-source errors and `0x29xx` for binary-container errors;
future milestones extend both without colliding with sibling kernel
subsystems (see `design/kernel/errno-partitions.md` for the full
map).

### `_ctr_locate_section` returns a BARE errno

The locator does NOT pack a count or offset into the high bits of
its return. It returns one of:

* `CT_OK` (0) on hit, with `*out_offset_ptr` and `*out_size_ptr`
  populated.
* `CT_ERR_BAD_MAGIC` / `BAD_VERSION` / `SECTION_COUNT` / `OVERRUN`
  on container validation failure. The out pointers are LEFT
  UNTOUCHED on any error path.
* `CT_ERR_NOT_FOUND` if no section's `kind` matched the target.

The locator performs its OWN header validation; a caller may invoke
it standalone without a prior `_ctr_parse` -- useful when only one
section is of interest (e.g. the signature-verify path only needs
`CT_SEC_SIGNATURE`'s offset+size and the surrounding container
prefix/suffix bytes).

## 5. Versioning and extensibility

### Version 1 (M1)

The current reader accepts ONLY `version == 1`. The field exists
precisely so a future milestone can add a non-backward-compatible
shape without changing the magic. Any such change bumps the version
to 2 and keeps the reader shape backward-compatible for a transition
window: a v2 reader accepts v1 containers (promotes them in place),
while a v1 reader rejects v2 containers with `CT_ERR_BAD_VERSION`.

### Reserved field

The `reserved` u32 at `[12..16]` is written as zero and IGNORED by
the M1 reader. A later milestone may claim bits for:

* flag bits (e.g. "container is compressed", "container has a
  deferred-signature slot"), without a version bump since the
  current reader ignores the field;
* an upper-32 extension to `n_sections` if the 32 cap is ever
  raised past 2^32 (not foreseen).

Readers that need to interpret the field in the future gate on a
version bump; the M1 behavior of IGNORING is intentional and gives
us a free extension slot.

### Later-milestone section kinds

R133.M2..M5 add new kinds adjacent to the current five without
changing the record shape:

* `CT_SEC_DEBUG` (future) -- source-map / line-number payload for
  the shell's `pds backtrace` operator surface.
* `CT_SEC_TESTS` (future) -- embedded unit tests the toolchain can
  run against a container as part of its signing workflow.
* `CT_SEC_IMPORT` (future) -- declared dependencies on other `.pds`
  containers (resolved by the R131 loader at exec time).

Each new kind takes the next unused `CT_SEC_*` ordinal (6, 7, ...)
and is passed through transparently by the M1 reader.

### Payload-overlap check (deferred)

The M1 reader checks each section's `offset + size <= buf_len` but
does NOT check for payload overlap between sections. Overlap is
UNDEFINED behavior at M1 (the toolchain is trusted not to emit
overlapping payloads); a later milestone may add an `OVERLAP`
error code and the n^2 overlap-detection pass.

## 6. Interaction with R227 header pragmas

A `.pds` source file begins with header pragmas; a `.pds` container
does not. The toolchain disambiguates the two shapes by the first
four bytes:

* `0x50445343` (little-endian u32 = magic 'PDSC') -> container.
* anything else -> source. The source parser then dispatches on
  header pragmas (R227.M1).

The toolchain is responsible for emitting ONE OR THE OTHER shape; it
does not interleave them. A compiled container does NOT carry the
original source pragmas as a prefix -- the toolchain SHOULD store a
pragma snapshot in `CT_SEC_META` (as a UTF-8 TLV field) if operator
diagnostics or reproducible-build workflows need it.

The `strict` pragma from R227 applies to the SOURCE parser only;
containers do not have a strict-mode toggle (they are already a
fully-validated bytecode form). The `history_default_cap` pragma is
captured at compile time and may be preserved in `CT_SEC_META` for
operator inspection.

The `charset utf8` pragma is MOOT for containers: the container
format itself is binary and the only text fields are the
section-header `name[16]` (ASCII, NUL-padded) and the `CT_SEC_META`
TLV stream (declared UTF-8 by convention). Future milestones may
add a per-section charset byte to the `flags` field if non-UTF-8
metadata is ever shipped.

## 7. Interaction with R131 pds-loader (future)

The pds-loader (R131, future milestone wave) is the component that
turns a `.pds` container into a running shell command. The expected
sequence:

1. **Open and read.** Load the file into a kernel-owned buffer
   (future: `pds_load_bytes` via the VFS).
2. **Parse the container.** Call `_ctr_parse(buf, len, &records,
   CT_SECTION_SIZE * CT_MAX_SECTIONS)` to get a packed array of
   section-header records. Reject on any `CT_ERR_*`.
3. **Verify signature** (strict mode, R133.M2). Locate
   `CT_SEC_SIGNATURE`; verify Ed25519 signature over the surrounding
   bytes against the capability-signing root; reject on mismatch.
4. **Materialise cap-env** (R131.M3). Locate `CT_SEC_CAPS_DECL`;
   call `cap_env_from_decl` to allocate a `KIND_CAP_ENV` row from
   the payload bytes.
5. **Allocate module row** (R131.M4). Locate `CT_SEC_TEXT`; call
   `cmd_module_open_from_pds` to allocate a `KIND_CMD_MODULE` row,
   binding the cap-env handle from (4).
6. **Rodata attach** (R131.M4). Locate `CT_SEC_RODATA`; thread
   payload bytes to the module row for TEXT-side reference.
7. **Register** in the shell command registry (R123) so
   `pds exec <name>` can dispatch.

Each step after (2) uses `_ctr_locate_section` as its primitive
rather than re-walking the record array. This keeps the loader's
error paths narrow: each step has one input (a found section) and
one failure code (that section-kind's enforcement failure).

## 8. Encoder-pitfall discipline

The parser follows the standing kernel-wide encoder discipline (see
`src/kernel/core/pds/header_pragma.pdx` SECTION 4 for the canonical
list). Highlights specific to this module:

* **u32 zero-extend reads.** Every container-header field load uses
  `xor rax, rax; mov eax, [rbx + off]` so that the 64-bit `cmp`
  that follows operates on a clean zero-extended value. Bare
  `mov eax, [mem]` IS semantically zero-extended by hardware, but
  the explicit `xor` guards against future paideia-as encoder
  churn around 32-bit destination widening (same posture as
  `acpi/rsdp.pdx` `scan`).
* **No `test rN, rN`.** Every zero-check is `cmp rN, 0; jcc`. This
  is a kernel-wide convention; `test rN, rN` has the same semantic
  but a different encoding, and the kernel uses only `cmp` for
  reviewability.
* **Section-index scaling.** `i * 32` is `shl rN, 5`, not a 2-op
  `imul r, imm` (which the encoder does not support).
* **Section-header copy.** The 32-byte copy is four `mov r64, [src+N]
  ; mov [dst+N], r64` pairs for `N in {0, 8, 16, 24}`. Each
  intermediate register move zero-extends naturally; no byte-level
  loop needed. This is intentional: a byte-level loop would run
  into the `mov_b [reg+reg*1+off], reg` encoder gap (G5) and
  require a destination-pointer pre-advance.
* **Pure leaf.** Neither entry point makes a nested call, so the
  five callee-save pushes (rbx, r12, r13, r14, r15 = 40 bytes) land
  with entry `rsp%16==8`, body `rsp%16==0 (8+40=48, 48%16==0 after
  the implicit return-address push of 8 at the call site)`. No
  `sub rsp, 8` padding is needed.

## 9. Boot-time posture

The container reader is a PURE PRIMITIVE: it has no boot hook and
owns no state. It is called by the R131 pds-loader (future) at the
point a user issues `pds exec <file>` or at scripted-boot-time
container discovery; the reader itself runs without touching the
VFS, the capability substrate, or any global state.

Downstream enforcement sites (R133.M2 signature verify, R131.M3
cap-env materialisation, R131.M4 module open) are the components
that touch the capability substrate; the reader is strictly a
byte-level predicate.

## 10. Testing posture

M1 ships the reader without an in-kernel test harness; verification
is by exhaustive witness replay once R131.M4 lands and real
containers are available. A future `witness_r16_pds` (name TBD) will
exercise:

* a known-good minimal container (header + one TEXT section);
* a container with every section kind present once;
* a container with `n_sections == 32` (ceiling);
* a corrupted magic -> `CT_ERR_BAD_MAGIC`;
* `version == 2` -> `CT_ERR_BAD_VERSION`;
* `n_sections == 33` -> `CT_ERR_SECTION_COUNT`;
* truncated section-header stream -> `CT_ERR_SECTION_OVERRUN`;
* a section with `offset + size > buf_len` -> `CT_ERR_SECTION_OVERRUN`;
* `out_cap == 0` with `n_sections > 0` -> `CT_ERR_OUT_TOO_SMALL`;
* `_ctr_locate_section` hit, miss, and all four header-validation
  failure paths.

Until the witness lands, correctness rests on the pure-leaf nature
of the reader (no state, no side effects) and the parallel structure
of `header_pragma.pdx` (R227.M1) and `cmd_registry_parser.pdx`
(R123.M2), both of which share the same error-packing and
cursor-walking idioms and both of which have survived their own
adversarial debugger passes.

## 11. Cross-references

* Code: `src/kernel/core/pds/container_reader.pdx` (this milestone).
* Sibling parser: `src/kernel/core/pds/header_pragma.pdx` (R227.M1).
* Precedent parser: `src/kernel/core/shell/cmd_registry_parser.pdx`
  (R123.M2, Wave 87).
* Future consumer: R131 pds-loader umbrella (not yet filed).
* Signature root: `design/kernel/capability-signing-root.md` (R63).
* Cap-env wire: `design/shell/elf-caps-decl.md` (parallel route for
  ELF-shaped loading).
