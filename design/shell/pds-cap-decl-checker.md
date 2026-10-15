# pds-lang capability-declaration checker (R227.M2)

**Issue:** paideia-os#2704 (UMB-W28 R227.M2)
**Code:** `src/kernel/core/pds/cap_decl_check.pdx`
**Depends on:** R227.M1 (header pragma parser, Wave 112, #2703);
R125.M1 (`KIND_CAP_ENV` substrate, Wave 87, #2591); R125.M3 (ELF
`.caps.decl` loader, Wave 98, #2593); R125.M4 (syscall cap-check, UMB-W12,
#2594).
**Status:** M2 landed; follow-up milestones (M3+) layered on top.

---

## 1. Problem

The paideia-shell-language (pds, `.pds`) is a capability-aware scripting
surface: every effect a script executes flows through a capability held
in the session's `KIND_CAP_ENV`. R227.M1 landed the *parser* for a
pds file's header pragma block — the byte-level predicate that recognises
`#pragma pds <directive>` lines and emits a stream of 32-byte PdsHpRecord
entries. The parser is PURE: no cap lookups, no VFS traffic, no env
mutation. It answers one question: *what did the file say?*

That leaves two more questions unanswered before the pds body parser
can take over:

1. **Are the file's declared caps a subset of what the caller is allowed
   to pass through?** If a `.pds` file asks for `R_FS_WRITE | R_NET_BIND`
   but the caller only holds `R_FS_READ`, the kernel must refuse the
   load. The parent cannot pass down authority they do not hold.
2. **Does the file's declared cap list match the pragma stream?** If
   the pragma block declared three caps but the loader surfaced only
   two to the checker, the pipeline is desynced; the script should
   not be loaded.

**R227.M2 (this document) is the predicate that answers both.**

The checker is deliberately a PURE PREDICATE. It performs no mint, no
env insert, no state mutation of any kind. Its contract is: given a
pre-parsed pragma stream, a pre-parsed declared-cap stream, and the
caller's grant env, return a 64-bit errno saying whether the pds load
pipeline is allowed to continue. The mint step lands in a later
milestone (M3 or integrated with R123.M3 functor-invoke); M2 is the
*gate*, not the *gate opener*.

---

## 2. Design goals

1. **Pure predicate.** No env mutation; no cap_table traffic; no VFS
   traffic. One klog line per invocation (success or failure) for
   audit; nothing else.
2. **Narrow-only invariant.** For every declared cap D with grant G
   resolved from the caller's env, require `D.rights ⊆ G.rights`. This
   is the same invariant the kernel enforces at mint time
   (`_cap_minter_derive` step 7) and at `.caps.decl` loader time
   (`caps_decl_apply`). M2 pushes the check *earlier* — before any
   load-time side effect.
3. **Fail-closed, fail-fast.** Any inconsistency (undeclared cap,
   missing grant, rights widening, malformed record) returns a
   distinct errno band in the 0x3100..0x31FF carve-out. Partial
   validation is never reported — if the loop exits early with an
   error, the caller treats the entire script as unloadable.
4. **Zero-cost absent.** A `.pds` file with no cap declarations
   (`n_declared == 0`) passes in O(n_pragmas) with no cap_env traffic.
5. **Composable with the mint step.** M3 (or R123.M3 functor-invoke)
   layers the mint call *after* M2's predicate succeeds. On success,
   the mint path can call `_cap_minter_derive` with confidence that
   the narrow-only check will not re-trip; on failure, the mint path
   is never entered.

---

## 3. Public API

```
_pds_cdc_check(pragmas_ptr: u64,
               n_pragmas: u64,
               declared_caps_ptr: u64,
               n_declared: u64,
               grant_env_handle: u64) -> u64 errno
```

### 3.1 Inputs

| Arg | Reg | Meaning |
| --- | --- | ------- |
| `pragmas_ptr` | rdi | Base of `PdsHpRecord[n_pragmas]` from `_pds_hp_parse` (32 B stride). |
| `n_pragmas` | rsi | Count of PdsHpRecord entries. 0 means "no pragma block". |
| `declared_caps_ptr` | rdx | Base of `DeclaredCap[n_declared]` (16 B stride). |
| `n_declared` | rcx | Count of DeclaredCap entries. 0 is OK (trivial pass). |
| `grant_env_handle` | r8 | `KIND_CAP_ENV` handle representing the grants the caller may pass to the pds session. |

### 3.2 DeclaredCap record (16 bytes)

| Offset | Type | Field |
| ------:| ---- | ----- |
| `0x00` | u64 | `name_hash` — FNV-1a 64 of the parent cap's name. `0` is reserved for "unused slot" (fails `ERR_BAD_PRAGMA`). |
| `0x08` | u64 | `rights` — bit mask the declared cap requests. |

### 3.3 Return codes

| Code | Hex | Meaning |
| ---- | --- | ------- |
| `PDS_CDC_OK` | 0 | All declared caps pass the narrow-only invariant against the grant env. |
| `PDS_CDC_ERR_UNDECLARED` | 0x3100 | KIND_CAP pragma count ≠ `n_declared` (pipeline mismatch, see §6). |
| `PDS_CDC_ERR_RIGHTS_WIDEN` | 0x3101 | A declared cap's rights have bits beyond its grant env parent's rights. |
| `PDS_CDC_ERR_GRANT_INSUFFICIENT` | 0x3102 | `cap_env_lookup(grant_env_handle, parent_slot)` returned 0. |
| `PDS_CDC_ERR_BAD_PRAGMA` | 0x3103 | A declared record is structurally malformed (`name_hash == 0`). |

**Band audit (2026-10-14):** `grep -rnE '0x31[0-9A-F]{2}\b' src/ 2>/dev/null`
returned zero hits — clean band with no adjacent namespace. The 0x31xx
carve-out sits above the pds-header-pragma band 0x2800..0x28FF with a
full 0x200 of headroom for future pds-lang error ordinals.

---

## 4. The narrow-only invariant

For every declared cap `D` in `declared_caps[0..n_declared]`:

```
Let parent_slot = (D.name_hash & 0xFF) mod CAP_ENV_SLOTS.
Let G = cap_env_lookup(grant_env_handle, parent_slot).
Require G != 0.
Require (D.rights & G) == D.rights.
```

### 4.1 Why `(D & G) == D` rather than `D & ~G == 0`

Both expressions are algebraically equivalent, but the paideia-as
encoder does not emit `not reg`. The equivalent form avoids the gap and
mirrors R125.M2 `_cap_minter_derive` step 7, which uses the same
sequence:

```
mov rax, declared;
and rax, granted;
cmp rax, declared;
jne widen;
```

Using the kernel-wide idiom keeps the invariant-check surface uniform
across the three enforcement sites (`_cap_minter_derive`, `caps_decl_
parse`, and now `_pds_cdc_check`), which makes a single-point audit
sufficient to prove narrow-only is enforced everywhere.

### 4.2 Why rights are read directly from the slot

R125.M4's syscall cap-check (§2 of `design/shell/syscall-cap-check.md`)
adopts a simplification: the u64 stored in a `KIND_CAP_ENV` slot is
read as a rights mask directly, rather than being dereferenced into
`cap_table[idx*24 + 8]` to recover a full capability descriptor.
Rationale (shared across R125.M4 and R227.M2):

* At the current era the shell inserts rights-level masks into env
  slots directly, so the direct read is faithful to the data in flight.
* The cap_table dereference layer stays available for M5+ without any
  change to the on-disk `.caps.decl` format, the pragma record shape,
  or the DeclaredCap record shape — the resolver is kernel-internal.

A follow-up (not scoped to R227.M2) swaps the direct read for the
cap_table dereference when R125.M5 or a later milestone lands the
richer slot interpretation. The checker's return codes do not change.

---

## 5. The hash → slot bridge

R125.M3 (`src/kernel/core/elf/caps_decl_loader.pdx` §1) adopted a
bridge: `parent_slot = (name_hash & 0xFF) mod CAP_ENV_SLOTS`. R227.M2
inherits this bridge verbatim. Reasons:

1. The real resolver `_cap_env_lookup_by_hash` is still not landed at
   R227.M2's shipping date. The bridge unblocks M2 without widening
   the scope of a follow-on milestone.
2. Hash collisions are 2^-56 per request pair: the bridge is a
   *semantic* convenience, not a *security* weakening. The narrow-only
   check still runs on whatever cap the resolver returns — a
   collision-induced wrong parent will almost always surface as a
   RIGHTS_WIDEN or GRANT_INSUFFICIENT, not a false pass.
3. The on-wire DeclaredCap record shape (hash, not slot id) is forward-
   compatible with the real resolver when it lands. No format change
   is needed to swap the bridge for the real lookup.

---

## 6. The UNDECLARED cross-check

The pragma stream contains PdsHpRecord entries, each 32 bytes with a
u16 `kind` ordinal at offset 0. R227.M1 recognises ordinals 1..4
(version, strict, charset, history_default_cap). **R227.M2 reserves
ordinal 5 for `KIND_CAP`**, the pragma emitted when the parser's
follow-up milestone adds support for `#pragma pds caps "<spec>"`
lines.

M2 scans the pragma stream to count KIND_CAP ordinals and compares the
count to `n_declared`:

* **Match → continue to the per-record loop.** The pragma stream and
  the loader's declared_caps array agree on the number of cap
  declarations.
* **Mismatch → `PDS_CDC_ERR_UNDECLARED`.** The pipeline is desynced.
  Either the pragma block declared a cap the loader did not surface,
  or the loader surfaced a cap the pragma block did not declare. Both
  are loader bugs that the checker trips cleanly.

### 6.1 Why this check is useful even before KIND_CAP lands

At R227.M2's shipping date, the pragma parser does not yet emit
KIND_CAP (that is a future milestone). The count is therefore always 0
in the current era, which means the only passing case is `n_declared
== 0`. That is the correct behaviour: at the current era a `.pds` file
cannot declare caps (the pragma parser does not recognise the
directive), so the only legitimate state is "no caps declared". A
loader that pre-populates `declared_caps` from some non-pragma channel
would trip UNDECLARED, which is desirable — pre-pragma-era population
is not a sanctioned data flow.

Once the pragma parser extends to emit KIND_CAP records (follow-on
milestone), the UNDECLARED check becomes a positive consistency gate:
`n` pragma records must correspond to `n` declared caps.

---

## 7. Interaction with the surrounding stack

### 7.1 R227.M1 (pragma parser)

M1 emits the `pragmas_ptr` / `n_pragmas` pair M2 consumes. M2 reads
only the u16 `kind` at offset 0 of each record; the payload bytes 8..31
are untouched by the UNDECLARED cross-check. M1's record shape
(32 bytes, zero-padded) is stable across milestones.

### 7.2 R125.M3 (ELF .caps.decl loader)

Structurally parallel: both files take a pre-parsed cap-declaration
stream and check it against a grant env with the same hash → slot
bridge and the same narrow-only invariant. The code organisations
differ because they sit in different sections of the loader:

| Site | Trigger | Scope |
| ---- | ------- | ----- |
| `caps_decl_apply` | execve-time | ELF `.caps.decl` section |
| `_pds_cdc_check` | pds load | pragma block of a `.pds` file |

Both call `cap_env_lookup` and both use the direct-mask slot read.
When `_cap_env_lookup_by_hash` lands, both will migrate; the migration
is a one-site change in each file.

### 7.3 R125.M4 (syscall cap-check)

Runtime enforcement: once the pds session is loaded and running,
every syscall the body makes passes through the cap-check gate. The
rights masks M2 validates at *load* time are the same masks M4
compares against at *syscall* time. M2 is the compile-time check;
M4 is the runtime check. Together they bracket the capability flow.

### 7.4 Future: integration with R123.M3 functor-invoke

R123.M3 lands the functor-invoke ABI that executes a pds script in
its own cap-env. M3 of R227 (or an integrated milestone) will call
`_pds_cdc_check` on the way into functor-invoke; on OK, it mints
the declared caps via `_cap_minter_derive` into the child env; on
error, functor-invoke aborts with EACCES before executing a single
pds instruction.

---

## 8. Encoder discipline

Standard pdx-encoder discipline (per `feedback_pdx_encoder_pitfalls`):

* `cmp rN, 0` — never `test rN, rN`.
* Stride-16 declared-cap access via `shl rN, 4`; stride-32 pragma
  access via `shl rN, 5`. No 2-op `imul r, imm`.
* `and rN, imm8/imm32` is sign-ext safe (bit 31 clear in all masks
  used here: 0xFF, 0xFFFF, 6). `and rN, imm64` not used.
* u16 reads done as full u64 load + `and rN, 0xFFFF` mask (dialect
  per `caps_decl_loader.pdx`; no movzx; no `byte ptr` / `word ptr`;
  no r*d size qualifiers).
* Single-line `pub let` string literals (fingerprint tags in §9 of
  the file).
* Module basename `CapDeclCheck` matches file basename
  `cap_decl_check.pdx`. Encoder requires exact match.
* Fingerprint tags: `N = len(string) + 1` (NUL counted) — the five
  tags in SECTION 9 of the file state their N explicitly in a comment.
* All labels prefixed `pds_cdc_` (reserved-word discipline — `loop`,
  `if`, `let`, `else`, `fn` are keywords; the pds_cdc_ prefix never
  collides).
* Narrow-only invariant uses the `mov rax, D; and rax, G; cmp rax, D;
  jne widen` idiom to avoid the paideia-as `not reg` encoder gap.
  Mirrors R125.M2 `_cap_minter_derive` step 7 for cross-site audit.

### 8.1 Register / stack plan

`_pds_cdc_check` uses 5 callee-save pushes + `sub rsp, 16`:

```
push rbx    ; rbx = pragmas_ptr        (needed in UNDECLARED scan)
push r12    ; r12 = n_pragmas          (needed in UNDECLARED scan)
push r13    ; r13 = declared_caps_ptr  (needed in main loop)
push r14    ; r14 = n_declared         (needed in main loop)
push r15    ; r15 = grant_env_handle   (needed in main loop)
sub rsp, 16 ; [rsp+0]=i loop counter, [rsp+8]=declared.rights spill
```

Entry rsp%16==8; +5 pushes = +40 → rsp%16==0; `sub rsp, 16` →
rsp%16==0. All nested calls (`_pds_cdc_count_cap_pragmas`,
`cap_env_lookup`, `klog_s1`) see rsp%16==0 at entry.

`_pds_cdc_count_cap_pragmas` is a pure leaf: no pushes, no stack use,
no nested calls. Entry rsp%16==8 undisturbed on exit.

---

## 9. Testing posture (M2 scope)

The checker is a pure predicate. Verification posture:

1. **Boot-time self-tests** — invoke `_pds_cdc_check` from a
   witness in `kernel_main.pdx` with a hand-crafted scenario per
   return code:
   * `n_declared=0, n_pragmas=0` → OK.
   * One DeclaredCap with `name_hash=0` → BAD_PRAGMA.
   * One DeclaredCap, grant env empty slot → GRANT_INSUFFICIENT.
   * One DeclaredCap, `rights=0x7`, grant env slot=`0x3` →
     RIGHTS_WIDEN.
   * One DeclaredCap, `rights=0x3`, grant env slot=`0x7` → OK.
2. **UNDECLARED path** — currently untestable from `kernel_main` because
   the pragma parser does not yet emit KIND_CAP. Lands with the
   follow-on milestone that extends `header_pragma.pdx` to recognise
   `#pragma pds caps "..."`.
3. **No negative tests** — M2 does not test cap_env or minter paths;
   those are covered by R125.M1..M4's own witness suites.

The witness lines are not part of M2's deliverable (they land in the
pds integration milestone); M2 ships the predicate and the audit
fingerprints alone.

---

## 10. Non-goals (for R227.M2)

* **Minting.** M2 does not call `_cap_minter_derive`. The mint step
  lands in M3 or integrated with R123.M3 functor-invoke.
* **Full KIND_CAP pragma parsing.** M2 reserves ordinal 5 and reads
  the kind field, but does not add parsing of `#pragma pds caps
  "<spec>"` to `header_pragma.pdx`. That extension is a follow-on
  milestone.
* **Hash resolver.** M2 inherits the R125.M3 hash → slot bridge; the
  real `_cap_env_lookup_by_hash` surface lands later (same migration
  path as R125.M3 and R125.M4).
* **Cap_table dereference.** M2 reads env slot values as rights
  masks directly (R125.M4 pattern). The cap_table dereference layer
  is a follow-on migration shared with R125.M4+ and `caps_decl_parse`.

---

## 11. Comparative design note

The POSIX heritage has no analogue of the pds cap-decl checker: scripts
run with ambient parent authority, modulated only by file-system
permission bits and process credentials inherited at exec. The novelty
of R227.M2 is to put the check *in the load pipeline of the script
itself*, before any body code runs — a static, auditable gate between
the file bytes and the cap-env the script will execute under.

The nearest related work is Capsicum's `cap_enter` (FreeBSD) and Google
Fuchsia's `fdio` capability inheritance: both check caps at *process*
boundaries. R227.M2 extends the check to the *script* boundary — a
`.pds` file loaded via the pds-lang pipeline is a smaller unit than a
process, which lets the shell catch widening attempts before process
creation. This fits the paideia-os "novel + clean" design bias (per
`feedback_novel_clean_design.md`): no POSIX inheritance; a research-
backed static gate instead.

---

## 12. Open questions (deferred past M2)

1. **Should the checker fail-closed or fail-open on an unknown-kind
   pragma?** M2 ignores unknown kinds (anything not == 5) when counting
   KIND_CAP ordinals, which lets the pragma parser's future kinds (6+)
   land without reworking the checker. A follow-on may add a strict
   mode that rejects unknown kinds.
2. **Where does the audit log live?** M2 emits one klog line per
   invocation (success or failure) via `klog_s1` under `SUBSYS_CAP_`.
   A future audit upgrade may introduce `SUBSYS_PDS_` and route pds-
   specific chatter there.
3. **Should the `n_pragmas == 0` case fail-fast?** M2 scans the
   (empty) pragma array in O(1) via the UNDECLARED cross-check; if
   `n_declared == 0` too, the result is OK. A fail-fast policy would
   require `n_declared == 0` here, which the current implementation
   satisfies anyway (UNDECLARED fires when the counts diverge).

---

*Closes paideia-os#2704.*
