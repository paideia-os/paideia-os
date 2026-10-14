# Capability-typed arguments (R125.M6)

**Status:** Accepted (design-only, Wave UMB-W14, 2026-10-13).
**Issue:** paideia-os#2596.
**Depends on:** R125.M1 KIND_CAP_ENV (W87), R125.M2 svc.cap-minter (W96),
R125.M3 ELF `.caps.decl` loader (W98), R125.M4 syscall-entry cap check
(W12), R125.M5 `run --grant` shell surface (W13 / W100).
**Blocks:** R125.M7 (runtime-check emission; ticket to be filed when the
paideia-as toolchain wave for the grammar extension lands).

---

## 1. Why this document exists

R125 (umbrella **paideia-os#2478**, "every command runs in a bounded
cap-flow") has walked a four-landing arc:

| Stage | What it adds | Where the authority lives |
|---|---|---|
| M1 | `KIND_CAP_ENV` substrate: 16 envs × 6 slots. | TCB-adjacent `_cap_env_table`. |
| M2 | `svc.cap-minter` derives a cap narrowed to a rights subset. | `cap_table[row] + 8`. |
| M3 | ELF `.caps.decl` carries the manifest a program is willing to accept. | ELF section at link time. |
| M4 | Syscall-entry gate: `(active_env, sysno) → required rights` subset check. | `_syscall_rights_table`. |
| M5 | `run --grant` CLI lets a shell user attach a one-shot override. | Shell → `/bin/run` → kernel scratch (M5-cont). |

Every one of these is a **substrate** or a **gate**. None of them lets a
**programmer** declare, at the source level, that *this specific argument*
to a function is a cap-slot — a handle into the cap-env row-table — rather
than a plain `u64`. The programmer today still writes:

```paideia-as
let sys_dek_apply
    : (u64, u64, u64, u64, u64) -> u64
      !{crypto, mem, sysreg} @{paideia.crypto, cap}
    = fn (row_id: u64) (buf_user_ptr: u64) (lba: u64) (mode: u64)
         (volume_prefix: u64) -> …
```

and the fact that `row_id` must be a live KIND_DEK slot held by the caller,
with at least `R_DEK_READ | R_DEK_SCRUB` in its rights field, is a **prose
contract in the body's documentation comment** — not a type.

The result is that:
- `caps.decl` lists what caps the program needs at execve time; it says
  nothing about which *arguments* at *which call sites* carry a cap.
- The syscall-entry gate (M4) checks ambient rights for the sysno — it has
  no way to say "the row_id in `rsi` must itself point to a cap with
  `R_DEK_READ`".
- `/bin/run --grant` plumbs the grant through to execve; the receiving
  program's argv/stack carries whatever bits the grant encoded, with no
  type-system check that the receiver's parameters match the grant's
  shape.

R125.M6 (this document) is the **source-language shift** that closes
that gap: a function signature can declare that one or more of its
arguments is a *capability-typed argument*, and the toolchain tracks that
declaration end-to-end.

This landing is design-forward. Milestone M6 defines the contract,
grammar, and one proof-of-concept annotation site; M7 (future ticket)
emits the runtime check.

---

## 2. What a capability-typed argument is

### 2.1 Definition

A **capability-typed argument** is a function parameter whose value is
not an arbitrary `u64` but a **cap-slot index into the caller's active
cap-env**. The parameter's type declaration carries:

1. a **kind constraint** — the slot must hold a cap whose KIND tag is a
   specific value (e.g. `KIND_DEK` = `0x1A4`);
2. a **rights constraint** — the slot's rights field must be a superset
   of a specific mask (e.g. `R_DEK_READ | R_DEK_SCRUB`); and
3. an implicit **liveness constraint** — the cap must still be live in
   the caller's env at the call-site (i.e. not revoked, not destroyed,
   not fallen out of the env's TTL).

### 2.2 Why "typed argument" rather than "ambient rights"

The existing `@{Cap}` set on a function signature says "this function
requires the ambient env to grant Cap". That is an **ambient**
authority — it tells the gate what rights to look up in the active env,
but it does not say which *argument* bears the cap.

Capability-typed arguments make the cap-flow **explicit at the point of
use**. Three concrete gains:

- **Multi-cap functions.** A function that encrypts one block from
  volume A and writes it to volume B needs *two* cap-slots. The ambient
  `@{Vol}` says there is a volume cap in the env; it cannot distinguish
  which argument is which cap.
- **Delegation semantics.** When a function returns a cap-typed value
  or passes a cap-typed arg across an IPC boundary, the toolchain can
  check at the type level that the sender has permission to delegate
  that cap (M7 scope — this doc only declares the shape).
- **Static audit.** `objdump`-equivalent tooling can scan an ELF image
  and list every (function, parameter) pair that is cap-typed. This is
  the type-system analogue of `caps.decl`: the manifest *at the call*
  rather than at the image.

### 2.3 Where it fits in the R125 stack

```
   (M1) KIND_CAP_ENV           ──► per-task substrate
          │
   (M2) svc.cap-minter         ──► derivation primitive
          │
   (M3) ELF .caps.decl         ──► manifest at image level
          │
   (M4) syscall-entry gate     ──► ambient-rights check per sysno
          │
   (M5) /bin/run --grant       ──► one-shot override at execve
          │
   (M6) cap-typed args         ──► source-level per-argument type   ◄── here
          │
   (M7) runtime-check emission ──► per-call-site check at call entry (future)
```

M6 is the first R125 landing whose authority surface is at the **source
level** rather than the kernel ABI. From M6 onward, "which arguments
carry which caps" is a property of a function *declaration*, and the
elaborator can refuse a program that calls a cap-typed function with the
wrong shape (even before any kernel code runs).

---

## 3. Syntax

### 3.1 The `@cap(…)` parameter sigil

A parameter position may be prefixed with a capability-typing sigil:

```paideia-as
fn f(x: u64, @cap(KIND_VOLUME, R_VOL_READ) vol: u64) -> u64
```

Shape:

- `@cap` is a reserved identifier (lexer §3.4 addition).
- The parenthesised body carries exactly two **compile-time constants**:
  the KIND tag and the required-rights mask.
- Both constants resolve against the usual module/import namespace. The
  elaborator rejects anything that is not a `u64` literal or a `pub let`
  constant resolvable at link time.
- The parameter's *surface type* remains `u64`. The sigil is a **type
  refinement**, not a new type constructor. This is deliberate — see
  §3.4.

### 3.2 Composition with existing `@{…}` capability sets

A function may carry both:

```paideia-as
let apply
    : (u64, @cap(KIND_DEK, R_DEK_READ) u64) -> u64
      !{crypto} @{paideia.crypto}
    = …
```

Semantics:

- `@{paideia.crypto}` — ambient capability-set the function requires in
  the active env (unchanged from M1-M5 semantics; this is what the M4
  gate's `_syscall_rights_table` consults for syscall bodies).
- `@cap(KIND_DEK, R_DEK_READ)` — a per-argument refinement that says
  **this `u64` is a KIND_DEK cap-slot handle**, not an arbitrary integer.

The two are orthogonal. A function with only `@{…}` is a plain
ambient-authority function (pre-M6 world). A function with `@cap(…)` on
a parameter but no `@{…}` set is a function that only takes authority
through its arguments. A function with both uses ambient and per-arg
authority side by side.

### 3.3 Grammar extension (surface)

Delta against `design/toolchain/syntax-reference.md` §8:

```
Param        ::= CapSigil? Pattern ":" Type
CapSigil     ::= "@" "cap" "(" CapKind "," CapRights ")"
CapKind      ::= IdentifierExpr                 // resolved to u64 at elab
CapRights    ::= RightsExpr
RightsExpr   ::= IdentifierExpr
               | RightsExpr "|" RightsExpr      // OR-combination of masks
               | "0x" HexDigits                 // literal mask
```

The full grammar normative text lives at
`design/toolchain/paideia-as-cap-typed-args.md`. This doc fixes the
semantics; that one fixes the parser.

### 3.4 Why keep the surface type as `u64`

Three reasons:

1. **ABI compatibility with M1-M5.** The cap-slot ABI is a `u64` passed
   in a SysV register (rsi/rdx/rcx/r8/r9). Making the type a distinct
   `CapHandle<K, R>` would ripple into every lowering recipe and the
   stdlib_lowering table — too wide for M6.
2. **M6 is a *bridge* posture.** The runtime check lands at M7. Until
   then, the sigil carries static information only. A distinct type
   would force M6 to also do the lowering plumbing.
3. **The ambient `@{…}` posture already uses a tag-on-signature style.**
   Keeping the per-arg annotation at the same level — a decoration on a
   `u64`, not a new nominal type — matches the paideia-as idiom.

M7 may upgrade this to a nominal `CapHandle<K, R>` type if the project
decides the surface strengthening is worth the compiler-pipeline cost.
This document reserves that evolution but does not take it.

---

## 4. Caller-side obligation

A call site `f(a, slot)` where `f`'s second parameter is
`@cap(KIND_DEK, R_DEK_READ)` imposes four obligations on the caller.

### 4.1 Slot is live and holds the right KIND

The caller must demonstrate — statically — that `slot` is a cap-slot
value, not an arbitrary integer. In M6 (static-only), the elaborator
checks this by **data-flow origin**: `slot` must be
- a value returned by `svc.cap-minter`'s `_cap_minter_derive`
  (whose return type is `@cap(K, R')` for some `(K, R')`), or
- a value loaded from a `caps.decl`-populated env slot (whose load has
  a `@cap(K, R')` annotation at the loader site), or
- a value that is itself a cap-typed function parameter of compatible
  `(K, R')`, or
- a value forwarded unchanged from one of the above with no arithmetic
  between the source and the call.

Values originating from an arbitrary `u64` computation (addition,
subtraction, memory read without a cap-type annotation, syscall return
of an uncapped sysno) are **rejected**: the elaborator issues
`E0901 (non-cap value passed to @cap argument)`.

### 4.2 Rights at the slot are a superset of the required mask

If the caller's slot is known to hold rights `R'` and the parameter
declares required rights `R`, the elaborator checks `R ⊆ R'` at the
source level. The check is static and based on the slot's declared
rights at its origin (see §4.1 origin list).

If `R'` is only known at runtime (e.g. the slot's rights are the result
of a dynamic narrow via `svc.cap-minter`), M6 **permits** the call with
a diagnostic `D0902 (cap-rights check deferred to M7)`. The deferred
check is what M7 lowers into a runtime guard.

### 4.3 Caller may delegate the cap

A cap-typed argument is passed by *delegation*: the callee receives a
cap-slot handle equivalent to the caller's. M6 does not model
delegation revocation (that lives in M7's runtime check); the elaborator
simply records which call-sites pass which caps, and the manifest-linter
side of M4 (future deliverable) can refuse an image whose declared
caps.decl does not grant it the rights it would need to delegate.

### 4.4 No implicit widening

The caller cannot pass `@cap(K, R')` to a parameter of
`@cap(K, R)` where `R ⊄ R'`. The elaborator rejects
widening attempts with `E0903 (cap-rights widening forbidden)`.

Downcasting (`R ⊋ R'`) is always safe and silent — passing a `R_VOL_RW`
cap into a slot expecting `R_VOL_READ` is fine, since the callee's
required mask is a strict subset.

---

## 5. Callee-side guarantee

A function with cap-typed parameters receives, at entry, a guarantee
chain:

1. **Kind guarantee.** Every cap-typed parameter is a live cap-slot
   handle of the declared KIND. The callee may **assume** this; it does
   not need to re-check at the body entry.
2. **Rights guarantee.** Every cap-typed parameter has at least the
   declared rights mask. The callee may **assume** this.
3. **Env binding.** The slot refers to the caller's env at the moment
   of the call. The callee receives a (slot, env) pair, not a bare slot
   index — crossing the syscall boundary the kernel re-binds the slot
   to the kernel's inspection of the caller's env.

In M6, the guarantee is purely **advisory**: the elaborator enforces
§4, but no runtime check verifies that the caller's elaborator was
honest. A hand-rolled unsafe-block call (per custom-assembler.md §5
*unsafe honesty assumption*) can lie. The project's existing *unsafe
block audit discipline* carries forward unchanged.

At M7 the guarantee becomes **structural**: a per-call-site stub reads
the active env's slot, checks the kind + rights, and refuses the call
on mismatch.

---

## 6. Interaction with R125.M4 syscall-rights table

### 6.1 Two different gates

M4 and M6 are distinct gates with different scopes:

| Gate | Scope | Granularity | Lives in |
|---|---|---|---|
| M4 | Syscall boundary. | One required-rights mask per sysno. | `_syscall_rights_table[sysno]`. |
| M6 | Any function call (syscall or in-process). | One mask per parameter position. | Source signatures + (M7) per-call stub. |

A single syscall body may hit **both** gates:

- M4 checks that the caller's **active env** (ambient) has enough rights
  for the sysno at all.
- M6 checks that the specific **argument** named by `@cap(K, R)` is
  itself a cap-slot of the right shape, independent of what the ambient
  env grants.

Example: `sys_dek_apply` (sysno 137) today has an M4 entry at
`_syscall_rights_table[137*8]` that enforces an ambient-rights mask on
the caller's env. With M6 annotation (§8 below) its `row_id` parameter
additionally declares `@cap(KIND_DEK, R_DEK_READ)` — meaning that even
if the caller's env has the ambient `R_SYS_FS` the sysno expects, the
specific `row_id` passed in `rsi` must also be a live KIND_DEK slot the
caller actually holds. The two together close the gap where a program
with `R_SYS_FS` in its env could call `sys_dek_apply` with any `row_id`
it liked.

### 6.2 Why M6 doesn't fold into M4

Two reasons kept M6 at the per-call-site level rather than widening
`_syscall_rights_table`:

1. **M4 is per-sysno; M6 is per-argument.** M4's table is indexed by
   sysno alone (`sysno*8`); it has no per-argument structure. Growing
   it into a per-argument shape would widen every row from 8 bytes to
   `8 + N_args*16` bytes, which is a cascade through dispatch.pdx not
   justified at M6.
2. **Non-syscall callees also want it.** A pure in-process function
   (e.g. a userspace library helper that walks a cap-typed queue
   descriptor) also wants to type-check its callers. M4's table is
   syscall-only; M6 generalises.

### 6.3 Ordering at the syscall dispatcher

At M7, when a syscall body has both an M4 ambient check and an M6
per-arg check, dispatch order is:

```
1. M4 ambient gate       (dispatch.pdx cap-check preamble)
2. M6 per-arg gate       (syscall body prologue, emitted by paideia-as)
3. Syscall-body logic
```

M4 fires first because it is cheaper (one table lookup, one AND) and
denies the uncapped caller before the per-arg checks run. M6 fires in
the body prologue because the per-arg masks are known to the body, not
to the dispatcher.

### 6.4 Right-mask coherence

A sysno's M4 ambient-rights mask SHOULD imply any M6 per-arg masks on
its parameters. E.g. if `sys_dek_apply`'s M4 mask requires `R_SYS_FS`
and its `row_id` parameter is `@cap(KIND_DEK, R_DEK_READ | R_DEK_SCRUB)`,
then holding `R_SYS_FS` ambient alone is not enough — the caller must
also hold the KIND_DEK cap. The two gates are **conjunctive** (both
must pass), never alternative.

The toolchain's manifest-linter (M4 §6 future deliverable) grows an
extra pass at M6 to verify that an image's `caps.decl` declares every
KIND it names in a per-arg sigil.

---

## 7. M6 bridge posture: what's at M6 vs M7

### 7.1 M6 delivers (this landing)

- Design doc fixing the contract (**this file**).
- Grammar extension spec at
  `design/toolchain/paideia-as-cap-typed-args.md`.
- Prose-only annotation of one existing syscall body (§8) marking the
  cap-typed argument discipline in a comment block pointing back here.

M6 **does not** touch paideia-as source. The grammar extension is a
spec for a future paideia-as wave; this is explicit per the dispatch
brief (umbrella UMB-W14 §Required-work.2).

### 7.2 M7 delivers (future ticket, not yet filed)

- Lexer + parser recognition of `@cap(K, R)`.
- Elaborator checks §4 (origin, rights-subset, no widening).
- Emission of a per-call-site stub that reads the slot, checks kind +
  rights, refuses on mismatch (fail code TBD, likely a new SDA_*/MOUNT_*
  band or a shared `-EACCES` style sentinel).
- Debug-info extension: `.debug_paideia.caps` section grows per-param
  rows with the `@cap(K, R)` shape, consumed by `scripts/gdb/paideia.py`.
- Linter integration: `paideia-as lint` cross-checks a program's
  `caps.decl` against every `@cap` sigil in the image's exported
  signatures.

### 7.3 Rationale for the split

The M6/M7 split follows the R125 rhythm: a design-only step every two
to three code landings, letting the next couple of waves pick up the
contract-shape before the toolchain cost materialises. Specifically:

- M1-M5 landed **substrate** without a surface language shift.
- M6 lands the **surface shift** without touching the toolchain.
- M7 lands the **toolchain**, with the surface shift already stable and
  the kernel's PoC annotation already pointing at it.

This matches `project_novel_clean_design.md` posture: fix the design
before writing the code; retire POSIX-shaped alternatives up front.

---

## 8. Proof-of-concept annotation site

### 8.1 Chosen syscall: `sys_dek_apply`

`src/kernel/core/syscall/sys_dek_apply_body.pdx` (PFS-14 /
paideia-os#2732) is the right proof-of-concept target because:

1. Its `row_id` parameter is **literally** a KIND_DEK cap-slot handle,
   not a plain integer. The body already treats `row_id` as a bounded
   row-table index and invokes `dek_row_valid(row_id)` before use.
2. It is one of the four sysnos that already has an M4 entry in
   `_syscall_rights_table` (sysno 137; the other three are 75, 135,
   136). The M4 ambient check and the M6 per-arg check meet here.
3. It is well-documented (639 lines, with a Section 1 Contract block)
   so the M6 prose annotation can slot in without crowding other
   discipline notes.

### 8.2 What the annotation looks like

An inline comment block is added at the body's Section 1 (CONTRACT),
between the `row_id` subsection and the `buf_user_ptr` subsection:

```
//   row_id            : KIND_DEK row index in [0, DEK_MAX=16).  The row MUST
//                       be live (in_use byte set in the row header).  A
//                       stale row_id returns SDA_INVALID_ROW; this is
//                       library-caller discipline, not an authority gate.
//
//                       R125.M6 CAPABILITY-TYPED ARGUMENT (prose declaration):
//                         @cap(KIND_DEK, R_DEK_READ | R_DEK_SCRUB) row_id
//                       Caller must hold a live KIND_DEK cap-slot whose
//                       rights field is a superset of (R_DEK_READ |
//                       R_DEK_SCRUB) in its active cap-env.  M6 posture:
//                       static annotation only -- the elaborator (future
//                       paideia-as wave) will check origin + rights-subset
//                       at compile time; no runtime check is emitted at
//                       this landing.  The M7 landing (future ticket) will
//                       add a per-call-site stub that reads the slot via
//                       the cap-env row-table and refuses on kind/rights
//                       mismatch.
//                       See design/shell/capability-typed-arguments.md
//                       for the full contract.
//                       TODO(R125.M7): emit runtime kind+rights check.
```

The annotation does not change code — it is a comment block that fixes
the cap-type at the source level so the future paideia-as wave has a
signature to adopt.

### 8.3 Why not `sys_mount`

`sys_mount` was the other candidate the dispatch brief named. It is a
weaker PoC fit because:

- Its `source_path` is a user pointer (byte string), not a cap-slot. A
  future KIND_PATH / KIND_VOLUME-UNMOUNTED cap would make it eligible,
  but that cap does not exist yet (R52/PFS stack lands it later).
- Its `flags` is a bitmask, not a cap-slot.
- Neither of its first two arguments naturally maps to the §2.1
  cap-typed-argument definition at this landing.

`sys_dek_apply.row_id` is the one existing syscall whose argument shape
exactly matches §2.1 today, so it is the clean PoC site.

---

## 9. Comparison with retired alternatives

### 9.1 Linux file descriptors

Linux fds are integer handles into a per-process fd-table whose entries
describe open files / sockets / etc. The programmer's view is a plain
`int`; the kernel enforces at every syscall ("is this fd open? does
this fd point to a thing with the right ops table?"). This is isomorphic
to the pre-M6 state in paideia-os (cap-slot indices are `u64`, with
runtime check at the syscall body).

**Retired because** it offers no source-level visibility into which
arguments carry which authority. A function's `(int, int, int)` tells
the compiler nothing about which int is an fd and which is a flags
word. Paideia-os `@cap(K, R)` reclaims that visibility.

### 9.2 Capsicum capability bits on fd

FreeBSD Capsicum narrows an fd's rights at a per-fd level (`cap_rights_t`)
but the type system still sees `int`. Signatures can't say "this fd
needs CAP_READ". The programmer discipline is identical to the Linux
case; only the enforcement is tighter.

**Retired because** the type-level invisibility problem is unchanged.
Capsicum's rights narrowing is the right *mechanism* and inspires M2's
`svc.cap-minter`; M6 is the *surface-visibility* layer Capsicum chose
to omit.

### 9.3 seL4 CNode caps

seL4's cap-space is a tree of CNodes; a cap is addressed by a CPtr
(bit-string path through the tree). The programmer still handles CPtrs
as integers, and the type system (C in seL4's case) offers no help. The
kernel does rigorous runtime enforcement.

**Retired because** C can't express `@cap(…)`. In a system written in
C, seL4's approach is the correct one — kernel-side enforcement with
disciplined naming conventions. Paideia-os has a type system that can
carry the information; retiring the C-shaped posture is pure gain.

### 9.4 Linear types alone

A natural question: "You have linear types (`↓`); why not just make
cap-slots linear and let the substructural checker enforce usage?"

Linear types track **consumption**, not **authority**. A linear
cap-slot can be used once and then is gone — but during that use, the
type does not say what kind of cap it was or what rights it carried.
The two systems are **composable, not alternative**: a cap-typed
parameter can also be linear or affine, and the substructural class
sits on the surface type (which stays `u64`) while the `@cap(K, R)`
sits on the refinement.

**Not retired, but orthogonal.** M6 does not mandate linearity of
cap-typed arguments; the project may choose to require linearity for
some KINDs (e.g. KIND_DEK) at a future wave.

### 9.5 A dedicated nominal `CapHandle<K, R>` type

Rejected for M6 (§3.4). Reserved for a possible M7-or-later
strengthening if the ABI-cost is accepted.

---

## 10. Open questions deferred to M7+

| ID | Question | Deferral target |
|---|---|---|
| CTA-Q1 | Should `@cap(K, R)` support disjunction (`@cap(K, R_A \| R_B)`)? | M7 — currently §3.1 requires a single mask literal. |
| CTA-Q2 | Can a cap-typed argument be `Option<@cap(K, R)>` (nullable)? | M7 or later — probably yes, with the null case denoted by slot==0. |
| CTA-Q3 | How does a cap-typed arg survive a context switch across IPC? | M7 — ties into the delegation-provenance work R125 §Scope non-goal 2. |
| CTA-Q4 | Can `@cap` appear on return values? | M8-or-later — probably yes, with the same origin discipline flipped. |
| CTA-Q5 | Debug-info ABI version bump? | M7 — `.debug_paideia.caps` grows the per-param record. |

---

## 11. Audit anchors

Fingerprints for future greps:

- `grep -rn 'R125.M6 CAPABILITY-TYPED ARGUMENT' src/kernel/` → the
  prose annotation at every PoC site. M6 lands exactly one such site
  (sys_dek_apply.row_id); M7+ will multiply.
- `grep -rn '@cap(' src/` → actual sigil occurrences in `.pdx` source.
  **Empty at M6 landing** by design; the first non-zero hit announces
  the paideia-as grammar wave.
- `design/shell/capability-typed-arguments.md` (this doc) is the
  authoritative contract text. `design/toolchain/paideia-as-cap-typed-args.md`
  is the paideia-as-side companion.

---

## 12. Encoder-pitfall note

N/A for M6 (no code lands in this wave). The future paideia-as grammar
wave inherits the standard paideia-as encoder-pitfall discipline from
`feedback_pdx_encoder_pitfalls`.

---

## 13. One-line summary

A function parameter prefixed with `@cap(KIND, RIGHTS)` declares that
the parameter's `u64` is a live cap-slot handle of a specific kind and
at-least rights, verified by the elaborator at the source level (M6)
and the per-call stub at runtime (M7).
