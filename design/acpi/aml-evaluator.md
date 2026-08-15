# AML evaluator — context, budgets, frames, namespace walk, arithmetic

**Round.** R30 — ACPICA userspace bubble + LPSS bus enablement
**Issues.** #1054 (namespace walker + call frames) · #1055 (arithmetic and
logical operators)
**Status.** Landed. #1056 (string/buffer), #1057 (package/reference/index),
#1058 (invocation + argument promotion), #1059 (Notify), #1060
(recursive/serialized methods) follow.
**Builds on.** [`aml-parser.md`](aml-parser.md) — the R30.M1 tokenizer,
arena and two-pass parser. This document assumes it.

---

## 1. Placement — still constitutional

`src/user/aml/aml_eval.pdx` and `src/user/aml/aml_arith.pdx` are userspace.
Pillar 3 forbids AML in ring 0, and the argument is *stronger* here than for
the parser: parsing firmware bytecode is a bounded computation over a byte
buffer, whereas **evaluating** it is running a Turing-complete program the
firmware vendor wrote. Both mechanical checks —
`tools/lint-no-kernel-aml.sh` and `tools/verify-aml-parser.sh` §1 — cover
the new files without change, because they police the directory rather than
a file list. See [`no-aml-in-kernel.md`](no-aml-in-kernel.md).

---

## 2. The safety property, and why it is in the first commit

R30.M1 answered one threat: a parser that **over-reads** on malformed input.
The answer was a single bounds-checked read path plus a guard-page corpus.

Evaluation adds three the parser could not have:

| Threat | Guard | Code |
|---|---|---|
| Loops forever — `While` predicates are firmware-controlled and `While(One)` is a legal encoding | **fuel**, 1 000 000 steps | 31 `FUEL_EXHAUSTED` |
| Recurses without bound — nested expressions, mutually recursive methods | **depth**, 48 levels | 32 `EVAL_DEPTH` |
| Exhausts memory — one frame per invocation | **frame pool**, 8 frames, fixed `.bss` | 33 `FRAME_OVERFLOW` |

These landed with the first evaluator commit rather than as hardening
afterwards. Retrofitting a fuel counter into an existing evaluator means
auditing every path that could loop, and the paths that get missed are
exactly the ones nobody thought could loop. Threading it from the start puts
the spend in **one place** — `aml_eval_spend` — so every opcode #1056
through #1060 adds inherits the guarantee by construction rather than by
review.

### The limits, and why these numbers

**Fuel — 1 000 000 steps.** One step is one evaluated node, one statement,
or one `While` iteration. A `_CRS` or `_PTS` on real hardware costs a few
thousand. A million bounds any single evaluation to well under a
millisecond of work while making a firmware infinite loop terminate
*deterministically* instead of hanging `acpi_supervisor`.

`aml_eval_set_fuel` lets a caller ask for **less** — a GPE handler running
at interrupt time is not a boot-time `_INI` sweep — and **clamps** to the
constant above. The clamp is the point of the function: no caller,
including a compromised one, can raise the ceiling, so the termination
guarantee does not depend on any caller behaving. A zero request clamps up
to 1 rather than being accepted, because a zero budget reports
`FUEL_EXHAUSTED` for an evaluation that never started, which is a confusing
diagnosis for what is really a caller bug.

**Depth — 48 levels**, deliberately *not* the parser's 64. Distinct so a
depth error is unambiguously attributable to evaluation rather than to
parsing; lower because an evaluator frame is larger than a parser frame,
and 48 levels cost about 5 KiB of native stack — bounded and auditable.
Real firmware nests expressions fewer than twenty deep. Checked **before**
the increment, so a refused enter leaves the counter untouched and the
corpus can assert `depth == 0` after a refused evaluation as strongly as
after an accepted one.

**Frames — 8**, from a fixed pool of nine 256-byte slots (index 0 is the
"no frame" sentinel), 2304 bytes of `.bss`. ACPICA's own default nesting
limit is 10; shipping firmware nests three or four. Exhaustion is an error
and never a heap grow, because "allocate more" under firmware-controlled
recursion is not a mitigation, it is the attack.

### Both limits are separately reachable

A self-recursive method costs one frame and about two depth levels per
level, so eight frames are gone by depth 16 and **frames always win**. If
that were the only way to recurse, the depth cap would be dead code. It is
not: deeply **nested expressions** consume depth without consuming a frame
at all. The corpus reaches each limit through the path that actually
reaches it — 52 nested `Add`s for depth, a self-recursive method for
frames — and each fixture asserts the *code*, so a change that made the
other limit fire first is visible rather than silently equivalent.

### (I3) Error is execution-blocking

`aml_eval_spend` refuses once the session's error is non-zero, **without
consuming fuel**. Because every node, every statement and every `While`
iteration spends, one check makes a latched error halt evaluation
everywhere, immediately, without each caller having to remember. This is
the evaluator's analogue of the lexer's read-blocking invariant (I2) in
`aml-parser.md` §7, and it is what makes a caller that ignores an error
*unable* to spin rather than merely unlikely to.

### The session error slot

Evaluation errors are latched in `aml_eval_state`, **not** in
`aml_lex_state`. The two have different lifetimes: parsing is per-table,
evaluation is per-invocation. Sharing one first-writer-wins slot would mean
the first method to exhaust its fuel or hit an unimplemented opcode
permanently blocked every later evaluation of the same table —
`acpi_supervisor` could evaluate exactly one method per boot.

The code *space* is still shared (31..41 continue the R30.M1 taxonomy), so
a code identifies its origin unambiguously. And `aml_eval_reset` **seeds**
the slot from `aml_lex_err()` rather than merely clearing it, which keeps
the other half of the guarantee: a table that failed to *parse* starts its
session already-failed, so every spend refuses and a caller who forgot to
check the parse result cannot evaluate a half-built arena.

No byte offset is recorded. An evaluation fault localises to an arena
**node**, not to a buffer position, and stamping the current node on every
latch would mean a store per evaluated node inside the fuel loop.
Node-level localisation is a later refinement, noted rather than
half-built.

---

## 3. Integer width is a property of the table

ACPI 6.5 §19.6: AML integers are **32-bit when the DSDT/SSDT revision field
is 1** and 64-bit when it is 2 or greater. This is not a legacy footnote —
iasl emits revision 1 unless told otherwise, so revision-1 tables still
ship. On such a table `Ones` is `0xFFFFFFFF`, `Not(Zero)` is `0xFFFFFFFF`,
`Add` wraps at 2³², and a comparison against `0xFFFFFFFF` must succeed. A
hardcoded 64-bit interpreter mis-evaluates all of it.

The revision is therefore **threaded**: `aml_eval_reset` takes it, it is
normalised to 1 or 2 (width is the only thing it drives, and a raw 5 stored
here would have to be re-interpreted at every use — which is where a
hardcoded 64 sneaks back in), and it is applied at exactly **one choke
point**: `aml_eval_node` truncates every value it returns. Because every
operand of every operator is obtained through `aml_eval_node`, and every
operator result passes through `aml_eval_trunc` before it is stored, no
arithmetic path can bypass it. One choke point, not twenty-six.

Revision 0 is read narrowly: a table claiming revision 0 predates the
64-bit definition.

The two shifts are the one deliberate exception — they need the width as a
*value*, not as a mask, and get it from `aml_eval_width` (see §6).

This discharges a deferral recorded in `aml-parser.md` §9: *"revision-
dependent truncation of `OnesOp` to 32 bits — R30.M2; a parser that
truncated would destroy information the evaluator needs."* The parser still
stores the full `0xFFFFFFFFFFFFFFFF`; the evaluator narrows on read, so one
parse tree serves both revisions.

---

## 4. Namespace resolution — ACPI 6.5 §5.3

### Why absolute paths, and not a walk of the child lists

The arena is a **syntax** tree. The ACPI namespace is not. `Scope(\_SB.PCI0)`
written at the top of a table is lexically a child of the root but
namespace-wise lives two levels down, and a `Name(FOO,1)` inside it is
`\_SB.PCI0.FOO`. Resolving names by walking lexical child lists therefore
gives **wrong answers** — not misses, wrong answers — and a wrong
resolution silently drives the wrong hardware.

Two repairs suggest themselves and both fail. Computing each declaration's
"real container" by resolving its own path prefix is circular: the prefix
resolution needs the same machinery. Excluding compound-named declarations
from the child set is circular for the same reason, because `Scope(\_SB)`
is itself compound-named.

The formulation that is not circular is **absolute paths**, which are
computable from the syntax tree with no lookup at all:

> `abspath(node)` = fold over the node's ancestor chain, root first. For
> each ancestor that *names a namespace object*, apply its own NameString
> to the path so far: a `\` prefix resets it to empty, each `^` pops one
> segment, and every NameSeg is appended.

Resolution is then "find the declaration whose absolute path equals the
target's", and the `Scope(\_SB.PCI0)` case is exactly right with no special
handling.

### Which nodes name something — the row that matters

`aml_eval_names` is a bitmask over node kinds. The predicate is **not**
"has a `name_ref`", and that distinction is the most consequential thing in
the module:

| Kind | Contributes? | Why |
|---|---|---|
| SCOPE, DEVICE, METHOD, NAME, ALIAS, PROCESSOR, POWERRES, THERMALZONE, OPREGION, FIELD_ELEM, EXTERNAL, MUTEX, EVENT | **yes** | genuine declarations |
| FIELD, INDEXFIELD, BANKFIELD | no | carry the **region's** name. Their FIELD_ELEM children live in the scope containing the `Field` declaration, not under the region — so all three must be name-*transparent* or every field element would resolve under a path that does not exist |
| CALL | no | carries the **callee's** name; a call site declares nothing, and counting it would let a call be found as a declaration |
| NAMEREF, FIELD_LINK, FIELD_CONNECT | no | references by construction |
| ROOT | no | the empty path, not a segment |
| everything else | no | not namespace objects |

The corpus asserts this table in both directions for every kind the arena
defines, because the Field kinds and the reference kinds all *do* carry a
`name_ref` — a "has a name" implementation would include them and would
place every field element under its region.

### The search rule — four cases, not interchangeable

| Written | Resolution |
|---|---|
| `\FOO.BAR` | from the **root**, absolutely. The current scope is irrelevant even if it contains a `BAR`. |
| `^^FOO` | pop N levels from the current scope, then resolve **exactly**. No search. |
| `FOO.BAR` | relative to the current scope **only**. No search. *This is the case implementations most often get wrong* — searching upward anyway finds a plausible object under a different device. |
| `FOO` | **only** this case gets the search rule: current scope, then each parent, up to the root; first match wins. |

The search is implemented by noticing that the target segment is always the
**last** element of the candidate path, so ascending one scope level is
exactly "delete the second-to-last element". The loop overwrites
`A[len-2]` with `A[len-1]` and shortens — four instructions, rather than a
re-derivation per level. Termination is monotone: the length strictly
decreases and the root-level probe (length 1) is the last one tried.

Popping more `^` than the scope has levels is `BAD_PARENT_PREFIX` (39) — a
malformed path rather than a miss, and worth its own code because the
operator response differs.

### The corpus makes the cases distinguish

One fixture declares `VALU` twice — at the root and inside `\SCPA` — and
four methods inside `\SCPA` that read it four ways:

| Body | Resolves to | Value |
|---|---|---|
| `Return(VALU)` | `\SCPA.VALU` (search rule, inner wins) | 2 |
| `Return(\VALU)` | `\VALU` (root anchor beats the inner match) | 1 |
| `Return(^VALU)` | `\SCPA.VALU` (the method's parent scope) | 2 |
| `Return(^^VALU)` | `\VALU` (two levels up) | 1 |

The same NameSeg, written four ways, must resolve to two *different*
objects. That is the property that makes the fixture able to fail: an
implementation that ignores the root anchor still finds *a* declaration —
just the wrong one, silently.

The refusal fixture pins the multi-segment rule the same way: `SCPA.VALU`
written inside `\SCPA.MSMD` names `\SCPA.MSMD.SCPA.VALU`, which does not
exist. An implementation that searched upward anyway would find
`\SCPA.VALU` and return 2, so `NAME_NOT_FOUND` here is a real assertion
rather than a tautology.

### Complexity, stated

`aml_eval_find` is a linear scan of the node arena that recomputes each
candidate's absolute path, so a lookup is O(nodes × depth) and a searched
lookup multiplies that by the scope depth. At the 512-node fixture scale of
this milestone that is nothing. It is the **same** scan `aml-parser.md` §6a
already earmarks for replacement by a sorted final-NameSeg index when the
arena grows for a real DSDT. Both callers want that index, so they should
be replaced together.

### One filter that is currently unobservable, and why it stays

`aml_eval_find` restricts candidates to nodes `aml_eval_names` accepts.
Mutation testing showed this filter is *almost* redundant: a
name-transparent node inherits its nearest naming ancestor's path, that
ancestor is a declaration, and parents are always allocated before their
children — so first-match-wins already lands on the declaration.

Almost. A transparent node that carries a `name_ref` and sits at the **top
level** — a `Field`, whose name is its region's — has an *empty* absolute
path, and nothing else does. Without the filter, `aml_eval_find(0)` returns
that `Field` as "the declaration of the empty path". The corpus asserts
exactly that case, which is what turned this from an untested guard into a
killed mutant. The filter also becomes load-bearing the moment the linear
scan is replaced by a sorted index, since index order is not arena order.

---

## 5. Frames — seven args, eight locals

ACPI 6.5 §20.2.6.2 defines `Arg0..Arg6` (**seven**) and `Local0..Local7`
(**eight**). The counts are asymmetric and it is not a choice: the opcode
space allocates `0x68..0x6E` to args and `0x60..0x67` to locals, and
`aml_optab.pdx` already encodes exactly that. Evening them up to seven each
would refuse `Local7`, which real tables use. Both counts are **fixed** —
AML has no dynamic locals — so the pool is statically sized and an
out-of-range slot index is `BAD_SLOT` (37) rather than a growth.

```
frame[f] +0    method node index
         +8    caller frame index (0 = outermost)
         +16   declared argument count
         +24   reserved
         +64   Arg0..Arg6      (7 slots)
         +128  Local0..Local7  (8 slots)
         +192  reserved — #1058 will tag slots that hold object
               references rather than integers, without restriding
```

256 bytes per frame, so frame `f` is at `pool + (f << 8)`: one shift, no
multiply. The reserved tail is what keeps it that way when #1058 needs
per-slot type tags.

**Isolation is by construction.** `aml_frame_push` zeroes all 32 slots
before the frame becomes current, so a callee's `Local0` starts at Zero (as
§19.6 requires) and cannot observe the caller's; the caller's frame is
never written. The only link between them is the caller index in slot 1,
which is data, not aliasing.

Testing this needed care. The pool is `.bss`, so a frame that has never
been written reads zero whether or not `push` zeroes it — an isolation test
that only touches virgin frames proves nothing, and the first version of
the fixture let the "frames are not zeroed" mutant survive. The corpus now
**dirties** frame 2, unwinds, and re-enters it.

**Arguments are evaluated in the caller's frame.** `aml_eval_call`
evaluates every argument expression onto the native stack first, and only
then pushes the callee frame and binds. Doing it the other way round would
evaluate `FOO(Local0)` against the callee's freshly-zeroed `Local0` and
pass Zero — silently, with no error — and would let a nested call inside an
argument collide with the half-built frame. The corpus pins it: a caller
sets `Local0 = 9` and passes it to an identity method, which must return 9
and not 0.

---

## 6. Operators — #1055

Twenty-four opcodes in five shapes:

| Shape | Opcodes |
|---|---|
| binary + optional Target | Add `0x72`, Subtract `0x74`, Multiply `0x77`, Mod `0x85`, ShiftLeft `0x79`, ShiftRight `0x7A`, And `0x7B`, Nand `0x7C`, Or `0x7D`, Nor `0x7E`, Xor `0x7F` |
| unary + optional Target | Not `0x80`, FindSetLeftBit `0x81`, FindSetRightBit `0x82` |
| read-modify-write | Increment `0x75`, Decrement `0x76` |
| two destinations | Divide `0x78` |
| logical, no Target | LAnd `0x90`, LOr `0x91`, LNot `0x92`, LEqual `0x93`, LGreater `0x94`, LLess `0x95` |

`aml_arith_handles` is the executable form of that list, asserted by the
corpus in both directions so the header and the dispatch chain cannot
drift. It caught a real defect on first run: written as "two contiguous
ranges", it silently dropped `Mod`, which sits at `0x85` — outside the
`0x72..0x82` arithmetic run, separated from it by `DerefOf` and
`ConcatRes`. The opcode space is *almost* kind here, and the almost is
where the bug was.

### LGreaterEqual, LLessEqual and LNotEqual have no opcodes

ASL spells them; AML does not encode them. §19.6 defines them as negations
of their duals and iasl emits exactly that:

```
LGreaterEqual(a,b)  ->  LNot(LLess(a,b))       0x92 0x95 a b
LLessEqual(a,b)     ->  LNot(LGreater(a,b))    0x92 0x94 a b
LNotEqual(a,b)      ->  LNot(LEqual(a,b))      0x92 0x93 a b
```

So they need no implementation and get none. The corpus asserts them
against the real iasl byte encoding rather than an invented opcode, which
is the only way that assertion means anything.

### The three that are easy to get wrong

**Shift counts at or above the integer width.** ACPI: all bits shifted out,
result Zero. x86: the shift count is **masked** to 6 bits, so a bare
`shl rax, cl` computes `ShiftLeft(One, 64)` as `One`. That is a silent
wrong answer in a construct real firmware writes when it builds a mask from
a computed width. The count is compared against `aml_eval_width` first and
the zero result produced explicitly.

**Divide by zero.** x86 `div` with a zero divisor raises `#DE`, which in a
userspace process is `SIGFPE` — firmware bytecode would be able to kill
`acpi_supervisor`. Both `Divide` and `Mod` test the divisor **before** the
`div` executes and latch `DIVIDE_BY_ZERO` (34). `Divide` also has **two**
destinations, Remainder then Quotient (§19.6.34), in that order, and
returns the quotient; the corpus reads both back and combines them
arithmetically, so swapping them yields a different number rather than an
equally-plausible one.

**Comparisons are unsigned.** AML integers are unsigned. `LGreater` and
`LLess` use `ja`/`jb`, not `jg`/`jl`. Signed compares would rank `Ones` —
the value every logical operator returns for TRUE — below `Zero`, and a
`While(LLess(Local0, Ones))` would exit immediately.

### Stores, and the boundary with #1057

`aml_eval_store` handles exactly four destinations:

1. a literal `Zero` — the **null target**, which iasl emits in the optional
   Target slot to mean "discard". A literal with any other value is refused
   rather than ignored, because ignoring it would silently drop a result;
2. `LocalX` — writes the current frame;
3. `ArgX` — writes the current frame (unusual but legal per §19.6.126, and
   refusing it would refuse real tables);
4. a `NAMEREF` resolving to an **integer-valued** `Name` object — writes
   through to that object's u64 side-table slot, which is what makes
   `Add(One, Two, FOO)` observable.

Everything else is `BAD_TARGET` (41). **The boundary is drawn at "does this
destination need a reference object to describe it"** — a field element, an
`Index()` target, a string/buffer/package destination all do, and they get
their real implementation with the rest of the reference machinery in
#1057. A partial version here would be the placeholder this milestone is
not allowed to ship.

The write-through needed one new arena accessor, `aml_u64_set`. It lives in
`aml_arena.pdx` rather than in the evaluator because `aml_u64_arena` is
storage confined to that object by `verify-aml-parser.sh`; an evaluator
that reached the array directly would void the confinement, and the corpus
would then prove nothing about single-writer discipline.

---

## 7. Error taxonomy — continuing `aml-parser.md` §5

| # | Name | Meaning |
|---|---|---|
| 31 | `FUEL_EXHAUSTED` | step budget spent |
| 32 | `EVAL_DEPTH` | evaluator recursion past 48 |
| 33 | `FRAME_OVERFLOW` | method nesting past 8 |
| 34 | `DIVIDE_BY_ZERO` | `Divide`/`Mod` with a zero divisor |
| 35 | `NOT_EVALUABLE` | node kind or opcode not evaluated yet |
| 36 | `NAME_NOT_FOUND` | resolution found no declaration |
| 37 | `BAD_SLOT` | ArgX/LocalX index out of range |
| 38 | `NAME_TOO_DEEP` | path over 16 segments, or an ancestor chain over 64 |
| 39 | `BAD_PARENT_PREFIX` | more `^` than the scope has levels |
| 40 | `NO_FRAME` | ArgX/LocalX with no active frame |
| 41 | `BAD_TARGET` | store destination is not storable |

Every one has a corpus fixture. `NAME_TOO_DEEP` (38) is the only one
reached solely through the 16-segment path bound rather than through a
hand-written table, and is noted as such.

---

## 8. Deliberately not evaluated

Strings, Buffers, Packages and references are `NOT_EVALUABLE` (35) — a
**refusal**, not a zero. Returning zero for "I cannot read this" would make
a driver that asks for a `_HID` it cannot decode see a valid-looking
answer, and the whole posture of this subsystem is that a wrong value is
worse than no value.

| Deferred | To |
|---|---|
| String and Buffer operators — `Concat`, `SizeOf`, `ToBuffer`, `ToInteger`, `Mid`, … | #1056 |
| `Package`, `Index`, `DerefOf`, `RefOf`, `CondRefOf`, `ObjectType`; reference-typed stores; following an `ALIAS` to its source (the walker *resolves* one, reading through it is refused) | #1057 |
| Argument promotion and implicit conversion at invocation | #1058 |
| `Notify` delivery | #1059 |
| Serialized methods, per-method mutexes, `SyncLevel` ordering, real recursion support | #1060 |
| OpRegion access — the point of the whole round | #1061+ |
| `DebugOp` and `TimerOp` in value position | when there is somewhere to send them |
| Node-level error localisation (which arena node faulted) | a store per node in the fuel loop; deferred deliberately |
| Sorted final-NameSeg index to replace the linear scan | with the arena growth, together with `aml_term_lookup` |

---

## 9. Verification

`tools/verify-aml-parser.sh`, extended from six modules to eight. The
evaluator adds a fourth encapsulation assertion:

> `aml_eval_state`, `aml_frame_pool`, `aml_path_buf` and `aml_path_anc` are
> relocated against from `aml_eval.o` and no other object.

This is not tidiness. The **termination** guarantee holds only for as long
as the fuel and depth counters are decremented exclusively by
`aml_eval_spend` and `aml_eval_enter` — a module that "just topped up" the
fuel slot inside a loop would void it with no symptom other than a hang on
hardware nobody has yet. **Frame isolation** is delivered by indexing every
access off the current frame base inside `aml_eval.o`; any other object
reaching the pool would be computing frame addresses itself, which is
precisely the arithmetic isolation depends on. The two path buffers are
reused across the search rule's repeated probes, so a second writer would
corrupt a resolution in flight and produce a **wrong** binding rather than
a failure.

`aml_arith.o` declares no storage at all, so adding it to `MODULES` costs
no new assertion and makes all four existing ones strictly stronger.

### The watchdog

The evaluator's headline guarantee is that `While(One)` **terminates**. The
failure mode of losing it is not an assertion reporting false — it is a
corpus that never returns, which in the pre-push matrix is a wedged hook
and no diagnosis at all. Mutation testing demonstrated exactly that:
neutralising `aml_eval_spend` produced a hang.

So the whole corpus now runs under a 60-second `alarm(2)`, roughly two
orders of magnitude more than it needs, and the handler names the cause.
The unarmed-`SIGSEGV` path likewise now writes a message before exiting
instead of returning a bare 97 — that path is reached by exactly the class
of bug (an index escaping a fixed-size pool) worth naming.

### Corpus — 1755 assertions, up from 1073

Termination: `While(One)` at both a narrowed budget and the real
1 000 000-step default; the clamp in both directions; 52 nested `Add`s
hitting the depth cap with fuel to spare; a self-recursive method
exhausting the frame pool with fuel *and* depth to spare; a spent session
not poisoning the next; a failed parse blocking evaluation entirely.

Frames: eight allocated and a ninth refused; `Arg6` in range and `Arg7`
not; `Local7` in range and `Local8` not; ArgX/LocalX with no frame; a
dirtied frame coming back zeroed on reuse; a callee's write leaving the
caller's slot untouched, through both the API and real AML; arguments
evaluated in the caller's frame; two arguments binding in order.

Namespace: the four §5.3 cases resolving the same NameSeg to two different
objects; a multi-segment relative name refused rather than searched; too
many `^` refused with its own code; a field element resolving in the scope
of its `Field` rather than under its region; the name-contributing
predicate asserted for every kind the arena defines; the empty path naming
nothing.

Statements: `If` taking each arm; a `While` with a real predicate summing
1..5; `Break` leaving an otherwise infinite loop with no error latched.

Operators: all twenty-four, plus shift-at-and-beyond-width, the unsigned
comparisons, the three `LNot`-composed comparisons at their real iasl
encodings, `Divide` with both destinations read back, divide-by-zero and
mod-by-zero, and the deferred-opcode refusals.

Width: `Ones`, `Not(Zero)`, `Add` wrap, `ShiftLeft(One,32)` and
`LEqual(Ones, 0xFFFFFFFF)` each asserted at revision 1 **and** revision 2
with different expected answers, so the revision is doing real work in both
directions rather than one.

### Mutation testing — sixteen mutants, sixteen killed

| Mutation | Killed by |
|---|---|
| fuel guard removed (`spend` a no-op) | the 60s watchdog — *the corpus hangs without it* |
| fuel accounting neutralised | 72 assertions, led by the `While(One)` fixture |
| depth cap raised past reach | `nested expressions hit the depth cap` |
| frame cap raised past the pool size | `SIGSEGV outside a guarded region` — the cap is also what keeps frame indices inside the pool |
| new frame not zeroed | `frame pool isolation and bounds` |
| arguments evaluated after the frame push | 4 fixtures, led by `arguments evaluate in the caller's frame` |
| search rule applied to multi-segment names | `§5.3 refusals` |
| root anchor ignored | `§5.3 scoping` |
| parent-prefix pop ignored | `§5.3 scoping` |
| FIELD kinds made name-contributing | `a field element is not under its region` |
| declaration filter dropped from the arena scan | `the empty path is the declaration of nothing` |
| revision-1 truncation disabled | 5 revision-1 fixtures |
| session error slot cleared instead of seeded | `a failed parse blocks evaluation` |
| shift count not checked against the width | 3 shift fixtures |
| comparisons made signed | `LGreater is unsigned` |
| divide-by-zero not latched | `Divide by zero`, `Mod by zero` |
| `Divide` destinations swapped | `Divide fills Remainder then Quotient` |

Two initially **survived**, and both were corpus gaps rather than code
gaps — which is the failure mode the technique exists to find:

- *Frames not zeroed.* The pool is `.bss`, and the fixture only ever
  entered frames that had never been written, so zero was zero either way.
  Fixed by dirtying frame 2 and re-entering it.
- *Declaration filter.* Genuinely unobservable through any path the corpus
  had, for the structural reason in §4 — and the analysis of *why* is what
  produced the one case where it is observable (the empty path), which now
  kills it.

---

## 10. Toolchain

`not r64` was unreachable from `.pdx` source: `Mnemonic::Not`, `encode_not`,
its dispatch arm and two byte-exact encoder unit tests all existed, but the
`("not", Mnemonic::Not)` row in the elaborator's resolver table did not.
ACPI's `Not`, `Nand` and `Nor` are each a one's complement, so this blocked
#1055. Filed and fixed as paideia-as **#1311** (`4d0e7b3`), with a guard
test that starts from a `.pdx` fixture and asserts the emitted `.text`
bytes — the pre-existing encoder tests built an `Instruction` by hand and
passed throughout the entire period the bug existed.
