# `.pds` capability-declaration load-time gate (R133.M2)

**Issue:** paideia-os#2621 (UMB-W29 R133.M2)
**Code:** `src/kernel/core/pds/caps_decl_gate.pdx`
**Depends on:**
R133.M1 (`.pds` container reader, Wave 113, #2620);
R227.M2 (pds-lang cap-decl checker, Wave 115, #2704);
R125.M1 (`KIND_CAP_ENV` substrate, Wave 87, #2591).
**Status:** M2 landed; M3+ layered on top.

---

## 1. Problem

R133 is `.pds-pipeline-container`: the compiled binary form of a
paideia-shell-language script, laid out as a 16-byte header plus up
to 32 fixed-size section headers plus their payloads. R133.M1 landed
the pure container READER (`_ctr_parse`, `_ctr_locate_section`). The
reader emits section-header records and resolves a section by kind,
but it is DELIBERATELY agnostic about what each section means. In
particular, the reader treats the capability-declaration section
(kind `CT_SEC_CAPS_DECL = 3`) as opaque bytes.

R227 is `paideia-shell-language`: the typed, capability-aware
scripting surface. R227.M1 landed the SOURCE pragma parser; R227.M2
landed the pure PREDICATE (`_pds_cdc_check`) that answers the
question "do the declared caps satisfy the narrow-only invariant
against the caller's grant env?" The checker's wire format is
`[DeclaredCap]`, where each `DeclaredCap = {name_hash: u64, rights:
u64}` is 16 bytes.

That leaves one piece unbuilt between them: at pds-script LOAD time,
after the container is parsed but BEFORE any TEXT byte is dispatched
to the shell command decoder, SOMETHING must locate the CAPS_DECL
section, decode its DeclaredCap records, and invoke the checker.
Without a dedicated layer, every pds-load call site re-implements
the same boilerplate and the policy decision (what happens when a
container has no CAPS_DECL section?) drifts.

**R133.M2 is that dedicated layer: the load-time GATE.** It is a
thin composition primitive — ~500 LOC of .pdx — that sits between
`_ctr_locate_section` and `_pds_cdc_check` and makes exactly one
policy decision and one wire-format decision explicit.

---

## 2. Role: gate ≠ reader ≠ checker

The three layers decompose cleanly along separation of concerns:

| Layer | File | Role | Decides |
| ----- | ---- | ---- | ------- |
| **Reader** | `pds/container_reader.pdx` | Byte-level validation of the container header + section-header stream. | Nothing about meaning. |
| **Gate** (this file) | `pds/caps_decl_gate.pdx` | Composes reader + checker. Decodes the CAPS_DECL payload. | Policy: no CAPS_DECL = refuse. |
| **Checker** | `pds/cap_decl_check.pdx` | Pure predicate: narrow-only invariant over a `[DeclaredCap]` array against a grant env. | Nothing about containers. |

The gate's rigid role is why it has its own file: it carries the
POLICY and the PAYLOAD-SHAPE decisions. Collapsing it into either
sibling would entangle those decisions with the sibling's narrower
responsibility.

---

## 3. CAPS_DECL section binary layout (M2-defined)

R133.M1 reserved `CT_SEC_CAPS_DECL = 3` for the capability-declaration
bundle but did not pin the payload shape. R133.M2 pins it:

```
+--------------------------------------------------------+
| CapsDeclSectionHeader (8 bytes)                        |
|   [0..4]   n_decls      u32   number of DeclaredCap     |
|                               records that follow      |
|                               (0..CAPS_DECL_MAX = 64)   |
|   [4..8]   reserved     u32   zero at M2                |
+--------------------------------------------------------+
| DeclaredCap[0]  (16 bytes)                             |
|   [0..8]   name_hash  u64   FNV-1a 64 of the cap name   |
|   [8..16]  rights     u64   bit-mask requested          |
| DeclaredCap[1]  (16 bytes)                             |
|   ...                                                  |
| DeclaredCap[n_decls-1]                                 |
+--------------------------------------------------------+
```

### Why this shape

* **DeclaredCap wire shape mirrors R227.M2 exactly.** The checker's
  input array is `[DeclaredCap]` where each record is 16 bytes
  `{name_hash, rights}`. The gate reuses the shape unchanged: the
  CAPS_DECL section payload (after the 8-byte header) IS a flat
  `[DeclaredCap]` stream. The gate hands the checker a pointer
  into the container buffer with no re-encoding step. One wire
  shape, two consumers.

* **8-byte section header, not 0.** Carrying `n_decls` inline in
  the section payload — rather than deriving it from
  `section.size / 16` — keeps the shape self-describing and makes
  the forward-compatible path cleaner: a future R133 milestone can
  add trailing bytes after the DeclaredCap stream (per-cap name
  strings, provenance records) and the loader will still know the
  record count. The `reserved u32` reserves four bytes for a flags
  field (M4+: `TRUST_PRAGMA_FREE`, `WIDEN_PERMITTED`, etc.).

* **No name strings at M2.** The DeclaredCap record carries a 64-bit
  hash of the cap name, not the ASCII bytes. Rationale: the kernel's
  cap-env lookup bridge (R125.M3 pattern reused at R227.M2 §3) maps
  hash → parent slot without needing the string. The names live in
  the SOURCE pragma block (compile-time only); the container is
  intended to be loaded by the kernel, which does not need the
  names. If a future audit log wants the names, a dedicated
  CT_SEC_META sub-record carries them separately.

* **CAPS_DECL_MAX = 64.** Transitional ceiling: 64 records * 16 bytes
  = 1024 bytes, well under one page. The `KIND_CAP_ENV` substrate
  (R125.M1) has only 6 slots at M2, so many declared caps collide
  under the hash-to-slot bridge regardless. R133.M4+ lifts the
  ceiling once `_cap_env_lookup_by_hash` replaces the bridge.

### Invariants the gate enforces

* **(G1)** `caps_size ≥ 8` — section header fits in the payload.
* **(G2)** `n_decls ≤ CAPS_DECL_MAX (64)` — array bound.
* **(G3)** `caps_size ≥ 8 + n_decls * 16` — DeclaredCap stream fits.

Any G1/G2/G3 failure surfaces as `PDS_CDG_ERR_BAD_HEADER = 0x3201`.

Per-record invariants (`name_hash != 0`, narrow-only `rights`)
are enforced DOWNSTREAM by `_pds_cdc_check`, surfaced as
`PDS_CDG_ERR_CHECK_FAILED` with the specific `PDS_CDC_ERR_*` cause
wrapped into bits [31:16] of the return value.

---

## 4. Public API

```
_pds_cdg_gate(container_ptr, container_len, grant_env_handle) -> u64 errno
```

* `container_ptr`, `container_len`: the on-disk `.pds` container
  bytes, pre-read by the loader (R131, M3+). The gate performs its
  own validation; the loader does not need to invoke `_ctr_parse`
  first.
* `grant_env_handle`: a `KIND_CAP_ENV` row handle representing the
  caps the caller is permitted to pass down.
* Return: `PDS_CDG_OK` (0) on success, or an error in the
  `0x3200..0x32FF` band (see §5).

The gate is a PURE PREDICATE: no mint, no cap-env mutation, no
VFS traffic. The sole side effect is a single `klog_s1` fingerprint
per return path (LEVEL_INFO on OK, LEVEL_WARN on each error) for
audit-trail greppability. This matches R227.M2's checker discipline.

### Error-code wrapper accessor

```
_pds_cdg_unwrap_cdc_errno(packed) -> u64
```

Given a `PDS_CDG_ERR_CHECK_FAILED`-wrapped return value, recover
the original `PDS_CDC_ERR_*` cause. Returns 0 if the input is not
a `CHECK_FAILED` code. Used by tests and audit paths; not required
for the normal load path.

---

## 5. Return codes

The gate carves out `0x3200..0x32FF` (new band; grep audit on
2026-10-14 shows no collisions with existing kernel error codes).

| Code | Name | Meaning |
| ---- | ---- | ------- |
| `0x0000` | `PDS_CDG_OK` | All declared caps pass the narrow-only invariant. |
| `0x3200` | `PDS_CDG_ERR_NO_CAPS_DECL` | Container has no section of kind `CT_SEC_CAPS_DECL`. M2 refuses (strict posture; see §6). |
| `0x3201` | `PDS_CDG_ERR_BAD_HEADER` | Container-header validation failed (BAD_MAGIC / BAD_VERSION / SECTION_COUNT / SECTION_OVERRUN surfaced by `_ctr_locate_section`), OR CAPS_DECL section payload geometry failed (G1/G2/G3 §3). |
| `0x3202` + `(cdc << 16)` | `PDS_CDG_ERR_CHECK_FAILED` | `_pds_cdc_check` returned non-zero. The CDC errno is wrapped into bits [31:16] of the return value; the low 16 bits identify the CHECK_FAILED band. |

### Why collapse BAD_MAGIC/BAD_VERSION/SECTION_COUNT/SECTION_OVERRUN
### into one errno

The gate's caller is the pds loader. The loader's response to any
container-header fault is identical: abort the load, emit a klog
fingerprint, surface the errno to the user. A per-cause distinction
at the gate's return would force the loader to re-fan the response,
with no actionable difference. The specific cause is already in
`_ctr_locate_section`'s return value, which is observable in the
klog_s1 fingerprint path (future: `klog_s1_x1` with the inner
errno; deferred to M3).

### Why wrap the checker errno into high bits

The checker already distinguishes four causes (`UNDECLARED`,
`RIGHTS_WIDEN`, `GRANT_INSUFFICIENT`, `BAD_PRAGMA`). Collapsing them
would lose actionable information: `RIGHTS_WIDEN` is a user-script
authorship error ("you asked for more rights than you were granted");
`UNDECLARED` is a loader-pipeline error ("the pragma block and the
decl stream disagree"). The wrapper preserves the distinction
without adding a side-channel:

```
  bits [15: 0] = 0x3202
  bits [31:16] = PDS_CDC_ERR_* (0x3100..0x3103)
  bits [63:32] = 0
```

e.g. `RIGHTS_WIDEN` (0x3101) surfaces as `0x3101_0000_0000_3202`.
The non-zero upper half acts as the passthrough flag. The
`_pds_cdg_unwrap_cdc_errno` accessor recovers the CDC errno for
callers that want to branch on it.

---

## 6. Policy: no CAPS_DECL section = refuse (M2 strict)

At M2 the gate refuses any container without a CAPS_DECL section:

```
container has no CAPS_DECL section            -> PDS_CDG_ERR_NO_CAPS_DECL
container has CAPS_DECL, n_decls = 0          -> PDS_CDG_OK
                                                 (empty declaration;
                                                  script requests no caps)
container has CAPS_DECL, n_decls > 0          -> runs the checker
```

### Rationale for strict

* **Explicit > implicit.** A `.pds` container that fails to declare
  its caps is almost always a toolchain bug (the compiler forgot to
  emit the section) or a security-adversarial payload. The right
  response is to refuse, not to default-allow-nothing.
* **Audit trail.** A refused load emits `pds.cdg: no caps-decl` to
  the klog at LEVEL_WARN. A default-allow would silently load
  payloads with unknown trust posture.
* **Reversibility.** Loosening a strict policy later is easy
  (introduce a flag); tightening a lax policy later is hard
  (existing containers depend on the lax behaviour). The strict
  default locks in the safe side of the fence.

### M3 variant: `ALLOW_EMPTY_IMPLICIT`

A future flag on `_pds_cdg_gate` (or a wrapper function) will
accept missing CAPS_DECL as equivalent to `n_decls = 0`:

```
_pds_cdg_gate_relaxed(container_ptr, container_len,
                      grant_env_handle, flags) -> errno
```

with `flags & PDS_CDG_FLAG_ALLOW_EMPTY_IMPLICIT` tolerating
`NO_CAPS_DECL`. The design decision is deferred to M3 because the
load-time trust model for "container without a declared cap set"
is still being worked out — it depends on R133.M2 signature
verification (planned follow-up in the R133 line) and on
R125.M4+'s cap-env-wide default-deny defaults.

---

## 7. Transitional constraint: nil pragmas array

R227.M2's `_pds_cdc_check` enforces an UNDECLARED cross-check: the
count of KIND_CAP pragmas in its `pragmas_ptr` array must equal
`n_declared`. At R133.M2 the gate hands the checker a NIL pragmas
array (`ptr=0, n=0`) because the BINARY container does not carry
a textual pragma block as a dedicated section — the pragmas live
only in the SOURCE form, consumed by `_pds_hp_parse` at compile
time, not at load time.

Consequence: with `n_pragmas = 0`, the checker's KIND_CAP count is
0. For UNDECLARED to pass, `n_declared` must also be 0. So the
practical effect at M2 is:

| Container shape | `n_decls` | Gate return |
| --------------- | --------- | ----------- |
| No CAPS_DECL section | — | `NO_CAPS_DECL` |
| CAPS_DECL present, empty | 0 | `OK` |
| CAPS_DECL present, non-empty | > 0 | `CHECK_FAILED` (UNDECLARED wrapped) |

### This is a KNOWN transitional constraint

At M2, the binary-container path is reserved for CAPABILITY-FREE
scripts and for signed-code-mobility scenarios where the signer
vouches that the compiled TEXT bytes are safe under the loader's
env unchanged. Scripts that NEED to declare capabilities continue
to load via the SOURCE path (R227.M1 pragma parser + R227.M2
checker directly), which has an authentic pragma stream.

### M4 reconciliation options

Two plans, both preserving the checker's PURE PREDICATE contract:

* **(a) CT_SEC_PRAGMAS section.** The container compiler emits a
  dedicated `CT_SEC_PRAGMAS` section (new kind, likely 6) mirroring
  the source pragma block. The gate parses it before invoking the
  checker. **Favoured:** keeps the checker's shape uniform between
  source-load and binary-load.
* **(b) TRUST_PRAGMA_FREE flag.** The checker gains an explicit
  flag that suppresses the UNDECLARED cross-check for binary-
  container loaders where no pragma stream exists. Simpler, but
  bifurcates the checker's contract.

Plan (a) is the design-doc favourite because it keeps the checker
pure. Plan (b) is the engineering fallback if the pragma-stream
re-encoder proves expensive.

---

## 8. Flow

```
_pds_cdg_gate(container_ptr, container_len, grant_env_handle)
    │
    ▼
Step 1  _ctr_locate_section(container_ptr, container_len,
                             CT_SEC_CAPS_DECL=3,
                             &caps_off, &caps_size)
    │
    ├── CT_ERR_NOT_FOUND           -> PDS_CDG_ERR_NO_CAPS_DECL
    ├── CT_ERR_BAD_MAGIC/VERSION/
    │   SECTION_COUNT/OVERRUN      -> PDS_CDG_ERR_BAD_HEADER
    ▼
Step 2  caps_payload_ptr = container_ptr + caps_off
    │
Step 3  (G1) caps_size >= 8                              [or BAD_HEADER]
Step 4  n_decls = u32 @ (caps_payload_ptr + 0)
         (G2) n_decls <= 64                              [or BAD_HEADER]
         (G3) caps_size >= 8 + n_decls * 16              [or BAD_HEADER]
    ▼
Step 5  declared_caps_ptr = caps_payload_ptr + 8
    │
Step 6  _pds_cdc_check(nil, 0,
                       declared_caps_ptr, n_decls,
                       grant_env_handle)
    │
    ├── 0 (PDS_CDC_OK)                     -> PDS_CDG_OK
    └── nonzero PDS_CDC_ERR_*              -> PDS_CDG_ERR_CHECK_FAILED
                                             | (cdc_errno << 16)
```

---

## 9. Encoder discipline

Standard pdx-encoder posture from `feedback_pdx_encoder_pitfalls`:

* `cmp rN, 0` (never `test rN, rN`).
* No 2-op `imul r, imm`; stride-16 via `shl rN, 4`.
* `and rN, imm` not needed in the main gate; the unwrap accessor
  uses `mov r10, 0xFFFF; and rax, r10` (`and r, imm64` forbidden,
  stage through r10).
* u32 zero-extend via `xor rax, rax; mov eax, [mem]`.
* 5 callee-save pushes + `sub rsp, 16` lands `rsp%16==0` at every
  nested call: `_ctr_locate_section`, `_pds_cdc_check`, `klog_s1`.
* Stack locals `[rsp+0] = caps_off`, `[rsp+8] = caps_size` as
  output pointers to `_ctr_locate_section`, passed via
  `lea rN, [rsp + K]` (precedent: `elf/caps_decl_loader.pdx` L510).
* Module basename `CapsDeclGate` matches `caps_decl_gate.pdx`.
* All labels prefixed `pds_cdg_` (reserved-word discipline;
  distinct from the `pds_cdc_` sibling in `cap_decl_check.pdx`).
* Fingerprint tags sized `N = len(string) + 1` with NUL counted
  (off-by-one hazard called out in encoder-pitfalls memory).

---

## 10. Caller contract (R131/R133.M3 pds-loader)

```
e = _pds_cdg_gate(buf_ptr, buf_len, grant_env_handle)
if e == 0:
    # Proceed: dispatch TEXT section via cmd_module_open_from_pds.
    # [M4+] Mint each declared cap into the session's cap-env via
    #        _cap_minter_derive.
else:
    # Abort the load WITHOUT touching cap-env or any other state.
    # The gate has already emitted a klog_s1 fingerprint; the loader
    # surfaces the errno to the user via its own path.
    return e
```

The gate is the LAST read-only predicate before any load-time side
effect. On OK (0), the loader is cleared to mutate state. On any
error, the loader must NOT mutate: the gate is the TRANSACTION
BOUNDARY for the load.

---

## 11. Testing posture (M2)

Target scenarios for the M3+ test harness:

* **GATE_OK_EMPTY** — container with CAPS_DECL present, `n_decls = 0`
  → returns `PDS_CDG_OK` (0).
* **GATE_NO_CAPS_DECL** — container with no CAPS_DECL section
  → returns `PDS_CDG_ERR_NO_CAPS_DECL` (0x3200).
* **GATE_BAD_HEADER_MAGIC** — container with corrupted magic
  → returns `PDS_CDG_ERR_BAD_HEADER` (0x3201).
* **GATE_BAD_HEADER_G1** — CAPS_DECL section with size < 8
  → `PDS_CDG_ERR_BAD_HEADER`.
* **GATE_BAD_HEADER_G2** — `n_decls = 65`
  → `PDS_CDG_ERR_BAD_HEADER`.
* **GATE_BAD_HEADER_G3** — `n_decls = 3` but section size = 20
  → `PDS_CDG_ERR_BAD_HEADER`.
* **GATE_CHECK_UNDECLARED** — `n_decls = 1`, nil pragmas
  → `0x3100_0000_0000_3202` (CHECK_FAILED wrapping UNDECLARED).
* **GATE_UNWRAP_CDC** — `_pds_cdg_unwrap_cdc_errno(0x3101_0000_0000_3202)`
  → `0x3101` (RIGHTS_WIDEN recovered).

The harness feeds synthetic container buffers (constructed in test
.rodata); no VFS traffic needed. Deferred to M3 alongside the
pds-loader entry point.

---

## 12. Non-goals at M2

* **Signature verification.** `CT_SEC_SIGNATURE` validation lands in
  a separate R133 milestone. The gate does not require signatures
  at M2; a container that passes the gate but fails signature is
  rejected by a sibling check in the loader.
* **Mint integration.** The gate is purely a predicate. The mint
  step (`_cap_minter_derive` for each declared cap into the
  session's cap-env) lands at M4+ or integrated with R123.M3
  functor-invoke.
* **Hot-reload.** Container hot-replacement (M5 shadow-table swap
  pattern from R123.M6 UMB-W8) is out of scope. The gate assumes
  it is called once per load.
* **CT_SEC_PRAGMAS parsing.** The binary-container pragma stream
  does not exist at M2. See §7.

---

## 13. Attribution

Composition primitive building on R133.M1 (Wave 113) container
reader and R227.M2 (Wave 115) cap-decl checker. Policy and
error-code wrapper decisions documented here are the material new
work of R133.M2.
