# Capability-row typing — R224.M4

**Issue:** paideia-os#2678
**Umbrella:** R224 (lambda-lang, paideia-os#2488)
**Satellite:** `tools/user/libpdx-pds-parser` (user-space; `src/cap_row.pdx`)
**Upstream substrate:** R225.M2 RowTypes (`design/shell/row-types-remy.md`,
`src/row_types.pdx` — the Rémy row-polymorphic pool and the row-aware
unifier) + R225.M1 HmCore (the shared TypeNode pool and TyVar/TyCon/TyApp
machinery). Parallel of R224.M3 EffectRow (`design/shell/effect-polymorphism.md`,
`src/effect_row.pdx` — same encoding, disjoint label table, disjoint
error band).
**Design axis:** Q-A2, *"substructural capability lattice"* — a lambda's
capability discipline is a first-class row-typed field of its arrow,
unified by the same Rémy pivot that unifies effect and record rows.

**Status at this landing:** M4 lands the capability-polymorphic row
sub-grammar for the paideia-shell lambda surface. A lambda carries a
**capability row** attached to its arrow (`A -> B !{eff} @{cap}`) that
lists the primitive capabilities the lambda requires to execute; at
execution the environment's capability mask is checked against the
required row, and the pure-env-rejection acceptance (passing a lambda
asking for `@{read}` to an env with no caps) is enforced by
`_cr_check_env` returning the E0820_MISSING_CAP diagnostic family.

---

## 1 · Scope and motivation

The semantic-shell plan
(`design/terminal/semantic-shell-language-plan.md` §R224.M4) specifies
that lambdas carry **capability rows** so the type-checker can
distinguish a pure arithmetic lambda from one that reads a file, writes
a system register, allocates heap, or mints a new capability. The
design decision Q-A2 chose the **"substructural capability lattice"**
path: capabilities are a *second* row on the same arrow, disjoint from
the effect row that R224.M3 landed. The two rows are intentionally
separate:

* **Effects** (R224.M3, Q-A3) — what a lambda *does* (reads memory,
  touches a sys-register, performs IO). Effects are *descriptive*; a
  type-checker tracks them so a caller can refuse to accept a function
  that performs more effects than it is willing to tolerate (width-
  covariant subtyping).
* **Capabilities** (R224.M4, Q-A2) — what a lambda *is permitted to
  do*. Capabilities are *prescriptive*; at execution the lambda's
  required row is checked against the environment's capability mask,
  and the lambda is refused invocation if any required capability is
  absent.

Rémy's 1992 formulation — the same substrate R225.M2 landed for record
rows and R224.M3 reused for effect rows — turns out to apply verbatim
to capability rows: a capability row is a sorted sequence of label-only
tokens terminated by either the empty row `∅` or a row variable `ρ`.
The only differences from effect rows are (a) the sigil in surface
syntax is `@` instead of `!`, (b) the label table carries *capability*
primitives drawn from Q-A2's substructural lattice (not the Q-A3
primitive effects), and (c) the check at execution is an environment-
mask covering test rather than a subtype derivation.

The design rejected three alternatives:

* **Q-A2a — effect+capability conflation.** Combine effects and
  capabilities into one row. Rejected because effects are a producer's
  claim about behaviour and capabilities are a consumer's permission to
  invoke; the two have *opposite* subtyping directions (effects are
  width-covariant, capabilities are width-contravariant) and must not
  share a type-level axis.
* **Q-A2b — flat set.** Represent capability demand as a `u64`
  bitmask baked into the arrow kind. Rejected because the row admits a
  row-variable tail — a polymorphic function can leave its capability
  demand open to be instantiated at the call site. A flat bitmask
  closes the universe at compile time and breaks the open-row
  discipline.
* **Q-A2c — nominal cap handles.** Each capability is a nominal
  handle (opaque u64 minted by the kernel), and the row carries
  handles directly. Rejected because the ergonomics break the surface
  syntax (a lambda type can't be hand-typed without knowing kernel-
  minted handles), and the handles are already carried orthogonally by
  the runtime; the type-level row only needs to name the capability
  *class*, which is what Q-A2's label-based lattice provides.

By embedding capabilities in the same `TyRow` kind R225.M2 landed, the
row-aware unifier (`_rt_row_unify`) handles capability rows *for free*
— the Rémy pivot works whether the row carries field types, effect
labels, or capability labels. The arg0 slot's packed `(tag, idx)`
convention (established by R224.M3 EffectRow) is reused verbatim; the
label *table* is per-row-flavour (effects in `_er_label_table`,
capabilities in `_cr_label_table`), but the row *nodes* share the pool.

---

## 2 · Grammar

```
CapAnnot    := WS* "@" WS* "{" WS* LabelList? WS* "}"
LabelList   := Label (WS* "," WS* Label)* (WS* "," WS* RowVar)?
             | RowVar
Label       := identifier
                 (one of read | write | exec | net | fs | cap_mint |
                  cap_grant | kalloc | ipc | trap — primitive labels
                  in slots 0..9; or a user-declared label in slots
                  10..31 interned via _cr_label_intern at M4.6+.)
RowVar      := identifier starting with the three bytes "rho"
                 (same convention as EffectRow M3 — any identifier
                  whose first three bytes are 'r','h','o' is a row-
                  variable. Resolves "is `rho` a label or a row-var?"
                  without a reserved-word table. None of the ten
                  primitive capability labels starts with "rho".)
identifier  := [A-Za-z_] [A-Za-z0-9_]*          (len 1..15)
WS          := 0x20 | 0x09 | 0x0A | 0x0D
```

The two annotation sigils (`!` for effect rows at R224.M3 and `@` for
capability rows at M4) are deliberately distinct — a lambda type with
both annotations is syntactically unambiguous:

```
f : (u64) -> u64 !{io, mem} @{read, write}
g : (u64) -> u64 !{} @{read}                 — pure effect; needs read cap
h : (u64) -> u64 !{io} @{}                   — IO effect; needs no cap (uses pre-granted env)
```

R224.M4.5 is the LambdaLit splice point where `_ll_parse` consumes the
optional `!{...}` (M3) and `@{...}` (M4) suffixes after the arrow +
ResultType in either order; raw M4 ships without this integration
because the standalone parser is already consumable by the HM
type-check tier.

---

## 3 · Primitive capability labels

The ten primitives drawn from Q-A2's substructural lattice:

| Idx | Label       | Length | Lattice flavour  | Intent                                     |
|----:|-------------|-------:|------------------|--------------------------------------------|
| 0   | `read`      |  4     | unrestricted     | read bytes from a stream or FS object      |
| 1   | `write`     |  5     | affine           | write bytes to a stream or FS object       |
| 2   | `exec`      |  4     | affine           | execute a binary (grants a process spawn)  |
| 3   | `net`       |  3     | affine           | open or accept a network connection        |
| 4   | `fs`        |  2     | unrestricted     | consult the filesystem (open/stat/readdir) |
| 5   | `cap_mint`  |  8     | linear           | mint a new capability (kernel-side)        |
| 6   | `cap_grant` |  9     | linear           | hand a capability to another principal     |
| 7   | `kalloc`    |  6     | affine           | allocate kernel-visible memory             |
| 8   | `ipc`       |  3     | affine           | send a semantic record via sys_semantic_* |
| 9   | `trap`      |  4     | linear           | issue a kernel trap (debug/syscall)        |

The *lattice flavour* column is informational at M4 — a future landing
(M4.1+) will tighten the row-check so a linear capability's row-ext
cannot be used twice at the same call site. M4 treats every row-ext as
a nominal label (same width-check as EffectRow M3's subtype derivation,
specialised to the env-mask covering direction).

Slot 9's label name `trap` is identical in bytes to EffectRow's slot 4
`trap` label (R224.M3). This is deliberate — the same word names two
distinct things depending on which row-flavour's table is consulted:
in `!{trap}` it means "may raise a trap"; in `@{trap}` it means
"permitted to issue a trap". The two tables are per-module (`_er_label_table`
in R224.M3; `_cr_label_table` in this landing); label name byte-strings
are not shared, only coincident.

The remaining 22 slots (idx 10..31) are reserved for *user-declared*
capability labels (`_cr_label_intern` entry point lives at M4; the
exposed `_cr_declare` surface is deferred to M4.6).

---

## 4 · Pool encoding

A capability row IS a RowTypes row (HM_KIND_TYROW = 4). The three
subkinds reuse R225.M2's codes verbatim:

```
ROW_EMPTY (0)   the closed empty capability row `@{}`
ROW_EXT   (1)   extension `ℓ ; ρ'`
ROW_VAR   (2)   open row-variable tail `rho`
```

For a ROW_EXT node in a capability row:

```
[+0]   kind      (u8)   4 (HM_KIND_TYROW)
[+1]   arity     (u8)   2
[+2]   subkind   (u8)   1 (ROW_EXT)
[+3]   flags     (u8)   reserved; 0
[+4]   arg0      (u32)  (tag << 24) | idx -- packed label id
[+8]   arg1      (u32)  0 (capability labels are nullary; field type
                         slot unused)
[+12]  arg2      (u32)  pool_idx of rest-of-row
```

The packing convention follows R224.M3 verbatim: low 24 bits = idx
(0..31 at M4; 32-slot cap). High 8 bits = tag (0 = primitive,
1 = user-declared). Example packings: `read` = 0x00_000000; user-decl
at slot 10 = 0x01_00000A.

The arg1 field-type slot is 0 because a capability label is nullary;
two zero pool_idx values match trivially at `_rt_row_unify`'s identity
check, so the degenerate "field type" recursion never looks at an
invalid pool slot. (Same precedent as R224.M3 EffectRow.)

A **capability row and an effect row are indistinguishable at the
TyRow node layer** — both have kind=4, subkind∈{0,1,2}, and an arg0
packed `(tag, idx)` id. Discriminating "is this an effect row or a
capability row?" at a given node is the *caller's* job via the owning
arrow's annotation site (effect-row annotations hang off `!{}` and
capability-row annotations hang off `@{}`); the type-level nodes are
geometrically identical. This has two consequences:

1. The arrow kind carries two separate row refs (one for effects, one
   for capabilities) — a lambda type's canonical form at M4 is
   `TyApp(TyApp(TyCon(ARROW, arity=2), domain), TyApp(TyApp(TyCon(RESULT_WITH_ROWS, arity=3), codomain), effect_row), cap_row)`
   or an equivalent flat 5-slot schema; the arrow-kind encoding is
   R225.M4's responsibility (effect-row unification) and is not
   touched by this landing. At M4 the parser emits a *bare row*
   pool_idx; the HM type-checker binds it to the arrow's cap-row slot
   downstream.
2. The row-aware unifier (`_rt_row_unify`) handles both row-flavours
   with no change — a cap-row-vs-effect-row unification attempt
   returns `RT_ERR_LABEL_MISSING` on the first label whose
   packed `(tag, idx)` differs across the two tables, because the
   label-id packing is per-table and a tag-matching idx-matching pair
   can only come from the same table. This is a *static* disjointness
   guarantee that costs nothing at the unifier.

---

## 5 · Label-table layout

32 slots × 16-byte stride = 512 bytes. Per-slot layout mirrors
R224.M3 EffectRow verbatim:

```
[+0]   len       (u8)    name length (0 = slot empty)
[+1]   tag       (u8)    0 = primitive, 1 = user-declared
[+2]   reserved  (u8)    0
[+3]   reserved  (u8)    0
[+4..16] name    (u8[12]) NFC name bytes, right-padded with zero
```

At module boot (`_cr_init`), slots 0..9 are populated with the ten
primitive labels (`read`, `write`, `exec`, `net`, `fs`, `cap_mint`,
`cap_grant`, `kalloc`, `ipc`, `trap`). Slots 10..31 are reserved for
user-declared labels; M4 does not yet expose `_cr_declare` so slots
10..31 remain empty at raw M4 and an unknown label in `_cr_parse`
returns `CR_ERR_UNKNOWN_CAP`. The `_cr_label_intern` entry point is
already live for M4.6+ harness use.

Static-source table `_cr_primitive_init` is 160 bytes = 10 * 16. The
static table is in `.rodata`; the live table is in `.bss` and
lazy-populated by `_cr_init`.

---

## 6 · Public API

```
_cr_init() -> ()
  Boot hook. Lazy-populates slots 0..9 from the static byte table
  _cr_primitive_init and sets _cr_label_table_count := 10. Idempotent
  (re-call short-circuits on count != 0). Called at the entry of
  _cr_parse, _cr_check_env, and _cr_render so a consumer may invoke
  the surface without a separate init step.

_cr_label_lookup(ptr, len) -> packed_u64
  Linear scan over _cr_label_table[0.._cr_label_table_count). Returns
  (tag << 24) | idx in low 32 of rax on hit, or 0xFFFFFFFF on miss.
  Calls _cr_init at entry (idempotent). Pure leaf-ish; one nested
  CALL to _cr_init.

_cr_label_intern(ptr, len) -> packed_u64
  On hit, delegates to _cr_label_lookup. On miss (and table not full),
  allocates slot `count` with tag = CR_TAG_USER = 1, copies the name
  bytes, bumps count. Returns the newly packed (tag, idx) or
  0xFFFFFFFF on table-full / over-long name.

_cr_skip_ws(bytes, len, cursor) -> new_cursor
  Advances cursor past WS bytes (0x20/0x09/0x0A/0x0D). Pure leaf.

_cr_parse(bytes, len, out_row_ref) -> status
  Parses a CapAnnot (WS* @ WS* { LabelList? } ). Writes the resulting
  pool_idx into *out_row_ref on success; 0 on error.

_cr_check_env(required_row, env_mask) -> packed_u64
  Walks required_row via _rt_find. For each ROW_EXT reads the packed
  label id, extracts idx (low 24 bits), tests (env_mask >> idx) & 1.
  Bit clear -> returns (packed_id << 32) | CR_ERR_MISSING_CAP (0x4303)
  — the E0820_MISSING_CAP diagnostic. Bit set -> advance cursor via
  arg2. ROW_EMPTY tail -> return CR_OK. ROW_VAR tail -> M4 optimistic
  OK (M4.1 tightens: open demand against a closed env must bind the
  row-var to empty before the check concludes OK).

  env_mask is a u64 bit-indexed by primitive idx:
  bit i == 1 iff the executing environment holds the capability at
  primitive-table idx i. Bits 32..63 are reserved for future table
  growth; M4 reads only bits 0..31.

_cr_render(row_ref, out, out_cap) -> packed_u64
  Walks the row and emits `@{L1, L2, ..., rho}` to the out buffer.
  Returns (bytes_written << 32) | status.
```

### Register maps (SysV)

```
_cr_init()                                       -> rax (ignored)
_cr_label_lookup(rdi, rsi)                       -> rax
_cr_label_intern(rdi, rsi)                       -> rax
_cr_skip_ws(rdi, rsi, rdx)                       -> rax
_cr_parse(rdi, rsi, rdx)                         -> rax
_cr_check_env(rdi, rsi)                          -> rax
_cr_render(rdi, rsi, rdx)                        -> rax
```

### Diagnostic family mapping

The brief names an **E0820-family** of type-check diagnostics. The
mapping to this landing's packed-status codes:

| Diagnostic name          | Status code | Description                                       |
|--------------------------|-------------|---------------------------------------------------|
| `E0820_MISSING_CAP`      | `0x4303`    | `_cr_check_env` saw a required cap absent in env  |
| `E0821_UNSATISFIABLE_ROW`| `0x4307`    | row internally inconsistent (reserved for M4.1+)  |
| `E0822_UNKNOWN_CAP`      | `0x4301`    | `_cr_parse` saw an unknown label                  |
| `E0823_INFLATED_ROW`     | `0x4308`    | row demands more caps than Q-A2 allows (reserved) |

The adversarial acceptance test (§7 case 11-18) exercises
`E0820_MISSING_CAP` (0x4303) with eight distinct primitive-cap-rows
against env_mask=0; each returns the packed `(packed_id << 32) |
0x4303` diagnostic with the offending label id in the high 32 bits.

---

## 7 · Acceptance corpus (20 cases)

### Parse-shape cases (1-10)

| # | Input                      | Expected                                                                 |
|---|----------------------------|--------------------------------------------------------------------------|
| 1 | `@{}`                      | CR_OK; row = ROW_EMPTY                                                   |
| 2 | `@{read}`                  | CR_OK; row = ROW_EXT(read; ROW_EMPTY)                                    |
| 3 | `@{read, write}`           | CR_OK; row = ROW_EXT(read; ROW_EXT(write; ROW_EMPTY))                    |
| 4 | `@{rho}`                   | CR_OK; row = ROW_VAR                                                     |
| 5 | `@{read, rho}`             | CR_OK; row = ROW_EXT(read; ROW_VAR)                                      |
| 6 | `@{read, write, exec, net, fs, cap_mint, cap_grant, kalloc, ipc, trap}` | CR_OK; row with 10 primitive ROW_EXTs onto ROW_EMPTY |
| 7 | `@{bogus}`                 | CR_ERR_UNKNOWN_CAP (0x4301) — intern-miss on a non-primitive at M4       |
| 8 | `@{read, read}`            | CR_OK at M4 (duplicate-label SYNTAX deferred to M4.1)                    |
| 9 | `@{`                       | CR_ERR_SYNTAX (0x4300) — EOI before close brace                          |
| 10 | `read`                    | CR_ERR_SYNTAX (0x4300) — no leading `@`                                  |

### Env-check cases (11-20) — adversarial

Each lambda l_i has type `(u64) -> u64 !{} @{cap_i}` where cap_i is the
i-th primitive capability. The env_mask is 0 (environment grants no
caps). The acceptance anchor is that each `_cr_check_env` call returns
`(packed_id_i << 32) | 0x4303 = (0x00_000000i << 32) | 0x4303` where
packed_id_i = `(tag=0 << 24) | idx=i`.

| #  | Lambda cap-row  | env_mask | Expected packed_u64 return               | Diagnostic         |
|----|-----------------|----------|------------------------------------------|--------------------|
| 11 | `@{read}`       | 0        | `0x00000000_00004303`                    | E0820 (read)       |
| 12 | `@{write}`      | 0        | `0x00000001_00004303`                    | E0820 (write)      |
| 13 | `@{exec}`       | 0        | `0x00000002_00004303`                    | E0820 (exec)       |
| 14 | `@{net}`        | 0        | `0x00000003_00004303`                    | E0820 (net)        |
| 15 | `@{fs}`         | 0        | `0x00000004_00004303`                    | E0820 (fs)         |
| 16 | `@{cap_mint}`   | 0        | `0x00000005_00004303`                    | E0820 (cap_mint)   |
| 17 | `@{cap_grant}`  | 0        | `0x00000006_00004303`                    | E0820 (cap_grant)  |
| 18 | `@{kalloc}`     | 0        | `0x00000007_00004303`                    | E0820 (kalloc)     |

The brief's acceptance target of **8 adversarial lambdas** is satisfied
by cases 11-18 (one per primitive cap in the first 8 of the 10-cap
table). Cases 19-20 exercise the complementary positive paths:

| #  | Lambda cap-row  | env_mask                 | Expected packed_u64 return  | Notes               |
|----|-----------------|--------------------------|------------------------------|---------------------|
| 19 | `@{read}`       | `0x00000001` (bit 0 set) | `0x00000000_00000000` = CR_OK | positive path       |
| 20 | `@{read, write}`| `0x00000003` (bits 0+1)  | `0x00000000_00000000` = CR_OK | multi-cap positive  |

---

## 8 · Error band

Band `0x4300..0x43FF`, carved on a kilo-step boundary past the
Wave-120 bands (R221.M3 WidthPass at `0x3F00..0x3FFF`; R224.M3
EffectRow at `0x4000..0x40FF`; R133.M5 kernel-side reserved at
`0x3E00..0x3EFF`; R133.M6 kernel-parallel reserved at
`0x4100..0x41FF`; R221.M4 reserved at `0x4200..0x42FF`).

| Slot    | Code                  | Description                                                                      |
|---------|-----------------------|----------------------------------------------------------------------------------|
| 0x4300  | CR_ERR_SYNTAX         | grammar fault at `@`, `{`, `,`, `}`, or ident byte-class                         |
| 0x4301  | CR_ERR_UNKNOWN_CAP    | `_cr_parse` saw a non-primitive ident not yet interned (E0822)                   |
| 0x4302  | CR_ERR_LABEL_TABLE_FULL | `_cr_label_intern` on a full 32-slot table                                     |
| 0x4303  | CR_ERR_MISSING_CAP    | `_cr_check_env` saw a required cap absent in env_mask (E0820, the anchor)        |
| 0x4304  | CR_ERR_POOL_FULL      | HmCore pool exhausted during `_rt_row_extend` / `_rt_row_var` in build phase     |
| 0x4305  | CR_ERR_OUT_TOO_SMALL  | `_cr_render`: out_cap smaller than the rendered byte count                       |
| 0x4306  | CR_ERR_KIND_MISMATCH  | `_cr_check_env` / `_cr_render` saw a non-row kind on a walked cursor             |
| 0x4307  | CR_ERR_UNSATISFIABLE_ROW | reserved for M4.1 open-row discipline (row demands become unprovable; E0821)   |
| 0x4308  | CR_ERR_INFLATED_ROW   | reserved for M4.1 Q-A2 lattice-aware row cap (E0823)                             |
| 0x4309  | CR_ERR_UNKNOWN_ROWVAR | reserved for M4.3 per-row-var naming (currently emits bare "rho")                |

Slots `0x430A..0x43FF` reserved for M4.1+ follow-ups (duplicate-label
SYNTAX refinement, open-row discipline tighten, per-row-var naming,
`_cr_declare` BAD_NAME, LambdaLit splice-point diagnostics, Q-A2
substructural-lattice violations, linear-cap double-use).

The 0x4300..0x43FF range is reserved for capability-row parser-tier
packed-status codes across R224.M4+. R224.M1 (lambda_lit) owns
`0x2C00..0x2CFF`; R224.M2 (closure_capture) owns `0x3500..0x35FF`;
R224.M3 (effect_row) owns `0x4000..0x40FF`. The four R224 submodules
do not share status codes because a downstream dispatcher's compound
error path must distinguish "the lambda header faulted" from "the
capture list faulted" from "the effect annotation faulted" from "the
capability annotation faulted".

---

## 9 · Linker dependencies

### Intra-library (two deps)

* **R225.M2 RowTypes** — called at:
  * `_rt_row_empty` — allocate the closed empty-row tail
    (`_cr_parse` build phase).
  * `_rt_row_var` — allocate a fresh row-variable tail (`_cr_parse`
    build phase on `, rho}` or bare `rho`).
  * `_rt_row_extend` — prepend a capability-row ROW_EXT onto the
    accumulator (`_cr_parse` build phase).
  * `_rt_find` — resolve the current row cursor through a ROW_VAR
    resolved chain (`_cr_check_env` and `_cr_render` loop head).

* **R225.M1 HmCore** — touches ONLY the shared `.bss` row-graph pool
  indirectly, via R225.M2 primitives above; no direct call into
  HmCore. The `_hm_pool` `.bss` symbol IS loaded by `_cr_check_env`
  and `_cr_render` via `lea r11, [rip + _hm_pool]` to compute node
  addresses on walked cursors.

No external cross-library linker dependency. All seven public entry
points (`_cr_init`, `_cr_label_lookup`, `_cr_label_intern`,
`_cr_skip_ws`, `_cr_parse`, `_cr_check_env`, `_cr_render`) can be
linked against the RowTypes/HmCore objects that R225.M1/M2 already
consume; no new `--extra-obj-dir` is introduced.

CapRow uses its own `.bss` scratch (`_cr_parse_scratch`, 64 B =
16 u32 packed-label-id slots) — deliberately disjoint from R225.M1
`_hm_subst_table`, R225.M2 `[384..512)` restrict/concat slice, AND
R224.M3 `_er_parse_scratch`. The two row-flavour parsers (effects vs
capabilities) could in principle share scratch at a later M, but the
disjoint carve-out keeps the two sub-languages independently
reviewable and lets both parsers be invoked from the same shell turn
without interleave hazards.

---

## 10 · Forward path

| Milestone | Addition                                                                                     |
|-----------|----------------------------------------------------------------------------------------------|
| R224.M4.1 | Duplicate-label SYNTAX in `_cr_parse` (`@{read, read}` returns CR_ERR_SYNTAX)                |
| R224.M4.2 | Tightened open-row discipline — ROW_VAR tail against closed env must bind to empty           |
| R224.M4.3 | Per-row-var naming (ROW_VAR carries var_id → name)                                           |
| R224.M4.5 | `_ll_parse` consumes optional `@{...}` suffix after arrow + ResultType (dual with M3.5)      |
| R224.M4.6 | Expose `_cr_declare` for user-declared capabilities (user-level cap vocabulary)              |
| R224.M4.7 | Q-A2 substructural-lattice enforcement: linear caps row-ext cannot repeat at a call site    |
| R224.M4.8 | `_cr_check_env` reads the per-session cap mask from the kernel-side cap table (R107)         |
| R224.M4.9 | 20-test proptest corpus (cases 1-20 above) + fingerprint goldens                             |
| R224.M5   | Nested lambda + let-rec scoping (shared with M3 effect-row scoping)                          |
| R224.M7   | Linear/affine propagation across pipeline-record boundary (consumes M4.7 lattice enforcement)|

---

## 11 · paideia-as encoder discipline (absolute)

* No `test rN, rN` — every zero-check is `cmp reg, 0; je/jne`.
* No `and rN, imm64` — idx isolation uses `shl r, 40; shr r, 40` to
  isolate the low 24 bits (same precedent as R224.M3); env-mask bit
  isolation uses `shr rdx, cl` + `and r, 1` (imm8, trivially
  imm32-safe; same precedent as `row_types.pdx` documents).
* No 2-op `imul r, imm` — label-table stride is `shl r, 4`;
  u32 scratch stride is `shl r, 2`.
* No multiline `pub let = "..."` — single-line justifications.
* Module basename `CapRow` matches `cap_row.pdx`.
* Labels prefixed `cr_` (unique against sibling parser-tier modules:
  u8n_, gi_, wp_, sch_sig_, cmd_sig_, fi_, afs_, pl_, rp_, ll_, cc_,
  hm_, rt_, dl_, se_, te_, er_).
* All `cmp reg, imm` immediates (0, 1, 2, 3, 4, 5, 6, 10, 12, 15, 16,
  32, 160, status codes 0x4300..0x4309, byte codes 0x09, 0x0A, 0x0D,
  0x20, 0x2C, 0x30, 0x39, 0x40, 0x41, 0x5A, 0x5F, 0x61, 0x68, 0x6F,
  0x72, 0x7A, 0x7B, 0x7D) fit imm32 with bit 31 clear.
* Byte loads via `xor r,r; mov_b r,[base + idx * 1]` (paideia-as
  #1248 mitigation).
* Byte stores decomposed via staging register (`mov r11, base; add
  r11, offset; mov_b [r11], src`).
* Cross-module `.bss` writes via `lea r11, [rip + sym]; mov [r11],
  rax`.
* Register-liveness: r11 clobbered by every nested CALL. Every value
  that must survive a nested CALL lives in r12..r15 (callee-save) or
  in the module's own `.bss` scratch `_cr_parse_scratch` (never in
  `_hm_subst_table`, deliberately disjoint from both R225.M2 and
  R224.M3's slices).
* `_cr_parse` / `_cr_check_env` / `_cr_render` are self-contained
  (no self-recursion). `_cr_parse` calls `_cr_skip_ws` (nested) and
  `_cr_label_lookup` (nested), then calls `_rt_row_var` /
  `_rt_row_empty` / `_rt_row_extend` (nested, cross-module into
  R225.M2). `_cr_check_env` calls `_rt_find` (nested).
  `_cr_render` calls `_rt_find` (nested).

### Wave 120 lesson — lazy init at every entry point

R224.M3 EffectRow at its M3 landing had a lazy-init bug: the lookup
helper read `_er_label_table_count` without ever calling `_er_init`,
so the first `_er_parse` saw a count=0 table and every primitive-label
lookup missed. The debugger-patch pattern was to insert `call _er_init`
at the top of `_er_label_lookup` (idempotent, cheap). THIS landing
replicates the pattern at *every* entry point that reads the label
table: `_cr_label_lookup`, `_cr_label_intern`, `_cr_parse`,
`_cr_check_env`, and `_cr_render` each call `_cr_init` at their first
instruction after the SysV prologue, before any read of
`_cr_label_table` or `_cr_label_table_count`. `_cr_init` is a pure-leaf
idempotent short-circuit (count != 0 → return) so the cost is a single
compare on the hot path and the correctness guarantee is unconditional.

---

## 12 · Upstream + related

* Upstream: paideia-os#2678 (R224.M4, THIS landing).
* Umbrella: paideia-os#2488 (R224 lambda-lang).
* Precedent landing: paideia-os#2677 (R224.M3 EffectRow —
  `design/shell/effect-polymorphism.md`,
  `tools/user/libpdx-pds-parser/src/effect_row.pdx`).
* Substrate: paideia-os#2683 (R225.M2 RowTypes —
  `design/shell/row-types-remy.md`,
  `tools/user/libpdx-pds-parser/src/row_types.pdx`).
* Related plans: `design/terminal/semantic-shell-language-plan.md`
  §R224.M4; `design/shell/elf-caps-decl.md` (the kernel-side cap
  declaration format that M4.8 will reconcile against the shell's
  per-session env mask).
