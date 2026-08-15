# AML evaluator — context, budgets, frames, namespace walk, operators, objects

**Round.** R30 — ACPICA userspace bubble + LPSS bus enablement
**Issues.** #1054 (namespace walker + call frames) · #1055 (arithmetic and
logical operators) · #1056 (string/buffer operators + §19.3.5 conversion) ·
#1057 (package/reference/Index semantics) ·
#1058 (invocation, argument promotion, return type) · #1059 (`Notify`
delivery) · #1060 (recursive and serialized methods)
**Status.** Landed. R30.M2 closed.
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

Everything else was `BAD_TARGET` (41). **The boundary was drawn at "does
this destination need a reference object to describe it"** — a field
element, an `Index()` target, a string/buffer/package destination all do.
**§13 records where that boundary moved to in #1057**, and the four
destinations above are now the *fast path* of a larger store rather than
the whole of it.

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

*(As of #1056–#1060 the first three rows below have landed; they are struck
through rather than deleted so the deferral and its discharge stay
legible.)*

Strings, Buffers, Packages and references are `NOT_EVALUABLE` (35) — a
**refusal**, not a zero. Returning zero for "I cannot read this" would make
a driver that asks for a `_HID` it cannot decode see a valid-looking
answer, and the whole posture of this subsystem is that a wrong value is
worse than no value.

| Deferred | To |
|---|---|
| String and Buffer operators — `Concat`, `SizeOf`, `ToBuffer`, `ToInteger`, `Mid`, … | #1056 |
| `Package`, `Index`, `DerefOf`, `RefOf`, `CondRefOf`, `ObjectType`; reference-typed stores; following an `ALIAS` to its source (the walker *resolves* one, reading through it is refused) | #1057 |
| ~~Argument promotion and implicit conversion at invocation~~ | landed, #1058 — §17 |
| ~~`Notify` delivery~~ | landed, #1059 — §18 |
| ~~Serialized methods, per-method mutexes, `SyncLevel` ordering, real recursion support~~ | landed, #1060 — §19 |
| Explicit `Mutex` / `Acquire` / `Release` / `Event` / `Signal` / `Wait`, and the release-order check §19 defers with them | R30.M3 |
| A second AML execution context, and with it the only fixture that can reach `MUTEX_CONTENTION` (54) | R30.M3 |
| Predefined-method argument signatures (`_OSI` wanting String, …) — a **row** in `aml_conv_tab`, not a code path | when a predefined-method table exists |
| The supervisor-side drain of the notification ring and the `KIND_ACPI_EVENT` mint | **landed R30.M4-003/004 (#1068/#1069)** — kind at `0x151` over `KIND_HW_INTERRUPT`, forwarded through `acpi_evt_notify` |
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


---

## 11. The object model — #1056 / #1057

`src/user/aml/aml_obj.pdx`. Integer, String, Buffer, Package, Reference,
and the storage they live in.

### Why a second arena and not a wider node

The #1050 node arena is a **syntax** tree: it says what the table *says*.
Evaluation needs to say what the table currently *means* — the buffer a
`Name` holds after three stores, a package element assigned at run time, a
reference produced by `Index`. Those are values, they change, and they have
no source-buffer offset.

Two designs were rejected first.

- **Mutate the node arena.** This destroys the property `aml-parser.md` is
  built on: the arena is *the wire format*, memcpy-able to another process,
  and the same bytes for the life of the table. If evaluation mutated it, a
  second evaluation would start where the first finished, `_STA` would
  answer differently on the second boot-time sweep than on the first, and
  the IPC payload would depend on *when* it was taken. **Evaluation never
  writes the node arena.** Not rarely; never — and the corpus asserts the
  `Name` node's data-kind flags are unchanged after a store that retypes
  the object bound to it.
- **Pointers to allocated objects.** The acpi_supervisor process has no
  allocator by design (`acpica-bubble.md`), and a pointer graph
  re-introduces the very thing the arena exists to avoid.

So: a **second index-addressed arena** with the same three properties as
the first — no pointers, fixed 32-byte stride, the arrays *are* the
representation — plus a per-node **binding table** saying which object a
declaration currently holds.

### The record — 4 × u64, 32 bytes, the same stride as a node

```
word0  [15:0]  type       an ACPI ObjectType code
       [23:16] refkind    reference sub-kind, type 20 only
word1  primary field      value / heap offset / element-run start / ref base
word2  length / index     String chars (NUL excluded), Buffer bytes,
                          Package NumElements, or a reference's index
word3  auxiliary          a frame reference's serial
```

**The type codes are the ACPI `ObjectType` codes, deliberately** — 1
Integer, 2 String, 3 Buffer, 4 Package, 5 FieldUnit, … 14 BufferField
(§19.6.101) — with 20 for a reference, following ACPICA's
`ACPI_TYPE_LOCAL_REFERENCE`. `ObjectType` is then nearly a field read, and
there is **one** numbering rather than two with a mapping table between
them. A mapping table is a thing that gets out of step.

### Reference sub-kinds — and why there are six, not three

```
1 REF_NAME       w1 = arena NODE index of the declaration
2 REF_LOCAL      w1 = frame index, w2 = slot 0..7, w3 = frame serial
3 REF_ARG        w1 = frame index, w2 = slot 0..6, w3 = frame serial
4 REF_PKG_ELEM   w1 = package OBJECT, w2 = element index
5 REF_BUF_FIELD  w1 = buffer OBJECT,  w2 = byte index
6 REF_STR_FIELD  w1 = string OBJECT,  w2 = byte index
```

The last three are the point of #1057; see §12.

**Frame references carry a serial, and that is not optional.** Frames are
a pool of eight *reused* slots, so a reference holding only "frame 3, slot
0" silently re-aims at a different method's `Local0` once frame 3 has been
popped and re-pushed — a wrong value produced from a plausible reference.
`aml_frame_push` stamps a monotonically increasing serial into slot +24 (a
word #1054 reserved), a frame reference records it, and a dereference that
finds a different serial is `STALE_REF` (49) rather than a read of someone
else's local.

### Storage, lifetime, confinement

| array | size | holds |
|---|---|---|
| `aml_obj_table` | 512 × 32 B | the object records |
| `aml_obj_heap` | 8192 B | String / Buffer payloads |
| `aml_obj_elem` | 1024 × u32 | Package element slots |
| `aml_obj_bind` | 512 × u32 | node index → current object |
| `aml_obj_state` | 8 × u64 | the three bump cursors |

All five are `.bss` private to `aml_obj.o` and **proved private by
`objdump -r`** in `verify-aml-parser.sh`, the same mechanism as
`aml_lex_state` and the node arena. That is not tidiness: every bounds
check in the file (object index against the high-water mark, byte index
against the object's own length, element index against `NumElements`) is
an invariant only for as long as no other object can form an address into
these arrays.

**Lifetime is the evaluation session.** Allocation is a bump; there is no
free. `aml_eval_reset` calls `aml_obj_reset`, so every session starts with
an empty arena *and an empty binding table*, and therefore re-materialises
each named object from its immutable declaration. Two consequences, both
wanted:

- evaluating the same table twice gives the same answers, because the
  second evaluation cannot see the first one's stores;
- a firmware method that allocates without bound fails with a **latched,
  bounded** error — `OBJ_ARENA_FULL` (42), `OBJ_HEAP_FULL` (43),
  `OBJ_ELEM_FULL` (44) — rather than growing the process. Same posture as
  the frame pool: "allocate more" under firmware-controlled recursion is
  the attack, not the mitigation.

A collector was considered and rejected: the root set is the binding table
plus every live frame slot plus **the evaluator's native stack**, and the
last is not enumerable from here. A bump allocator with a hard ceiling is
honest; a collector that cannot see one of its roots is a use-after-free.

### The binding invariant

`aml_obj_bind[node]` is the object a declaration currently holds, 0 meaning
"not materialised — read the declaration". It is indexed by node so the
node stride stays 32 bytes and the mutation stays outside the wire format.

**An Integer-valued `Name` is never bound.** Its value lives in the u64
side table, which #1054's `aml_eval_store` already writes, so the object
built for an integer read is transient. Every other type *is* bound, and a
bound name is by construction not an Integer. So

> `aml_obj_bind_get(node) != 0` **is** the predicate "this name currently
> holds something other than an Integer"

which is exactly the test the integer fast path needs (§14). Break that
invariant and a stored integer becomes invisible to object readers, or a
stored buffer invisible to integer readers — in both cases silently. The
corpus kills a mutant that binds integer names.

---

## 12. `Index` is three operators wearing one opcode

§19.6.63. `Index(Source, Index, Result)` produces a **different kind of
reference** for each legal source type, and they are not interchangeable:

| source | reference | `DerefOf` yields | a store does |
|---|---|---|---|
| Buffer | `REF_BUF_FIELD` | that byte, as an Integer | writes **one byte**, truncating |
| String | `REF_STR_FIELD` | that character, as an Integer | writes **one byte**, truncating |
| Package | `REF_PKG_ELEM` | the **element object**, of whatever type | **replaces** the element, no conversion |

Conflating the package case with either byte case is what this design is
shaped to prevent. `Store(0x1234, Index(PKG,0))` must leave element 0
holding the Integer `0x1234`; `Store(0x1234, Index(BUF,0))` must leave byte
0 holding `0x34` and discard the rest. An implementation with one
"container reference" kind gets one of the two wrong, **silently** — the
table runs, the value is plausible, and the hardware is programmed with the
low byte of something.

Buffer and String are kept apart at one remove: they behave identically
today, but a String owns a NUL the Buffer does not, so a later growth or
`SizeOf` rule that treated them alike would be wrong for one of them.
Distinct kinds make that a visible choice rather than an accident.

`aml_ref_store_through` switches on the **sub-kind**, never on the base
object's type, and the corpus asserts each `Index` form yields its own kind,
that each `DerefOf` round-trips, and — the headline — that the *same*
Integer stored through a buffer index and through a package index lands
differently. Both bounds are checked at **construction**: a reference that
is out of range is not a valid reference, and letting one be built means the
error surfaces at some unrelated later place. Out of range is `OBJ_RANGE`
(46); a String's NUL is out of range, because it is part of the encoding and
not an addressable character.

An index *within* `NumElements` whose slot was never initialised is a
different fault and gets a different code: §20.2.5.4 permits
`Package(0xFF){}`, so `aml_obj_elem_get` answers 0 without latching and the
**caller** decides — `DerefOf` makes it `UNINIT_ELEMENT` (50), `Match`
treats it as "never matches". Those are the two different right answers the
spec gives to the same condition.

---

## 13. Conversion — §19.3.5, two rules that look like one

This is the classic AML footgun. Implementations that treat it as one rule
work on simple tables and corrupt real ones.

### Rule 1 — operand conversion is keyed by the OPERATOR

There is no universal coercion. `Add` converts a String operand **to** an
Integer; `Concatenate` converts an Integer operand **to** a String or
Buffer. Same operand, same type, opposite conversions, chosen by the
operator.

So the model is two tables, and the split is the whole design:

```
aml_conv_want(op16, pos)  ->  the type this operator wants HERE
aml_conv_cast(obj, want)  ->  the object converted, or a refusal
```

`aml_conv_tab` is the first, **as data**: seventeen rows, each four
want-codes packed one byte per operand position, confined to `aml_str.o` by
`objdump -r` for the same reason as `aml_optab`. Any opcode with no row
gets the default `(Integer, Integer, Target, Integer)` — the shape of every
arithmetic and logical operator — so **#1055's twenty-four operators are
described by the table without occupying a row, and needed no edit at all**
when the object model arrived. Adding an operator is adding a row; it is
never editing a branch.

| want | meaning |
|---|---|
| 0 | ANY — the operator inspects the type itself |
| 1 | Integer |
| 2 | String, **hex** — the implicit Integer/Buffer → String rule |
| 3 | Buffer |
| 4 | Package |
| 12 | String, **decimal** — reachable only from `ToDecimalString` |
| 20 | Reference |
| 100 | **same as operand 0** — `Concatenate`, and only `Concatenate` |
| 101 | TARGET — a destination, never evaluated as a value |

100 exists because §19.6.13 keys `Concatenate`'s second operand off the
*runtime* type of its first. It is the only two-stage lookup in the
specification, and giving it a code keeps it visible in the table instead
of hidden inside one operator's body.

**Four operators are a table row plus a store and have no conversion logic
at all**: `ToBuffer` wants Buffer, `ToInteger` wants Integer, `ToHexString`
wants String-hex, `ToDecimalString` wants String-decimal. The conversion
*is* the operator. That is the strongest evidence the factoring is right,
and it is why those four cannot drift apart from the implicit conversions
`Concatenate` uses — they are literally the same code.

Every operand in `aml_str.pdx` and `aml_ref.pdx` is fetched by
`aml_conv_operand(expr, pos)`, which consults the table. An implementation
that fetched its own operands could disagree with the table and nothing
would notice.

### Rule 2 — store conversion is keyed by the DESTINATION'S EXISTING TYPE

§19.3.5.7. Storing an Integer into a `Name` that currently holds a Buffer
converts **the Integer to a Buffer**. It does *not* retype the `Name`.
Written the other way round it passes every fixture whose Names only ever
hold integers, and then destroys a `_CRS` on real hardware.

`aml_eval_store_named` implements it, and two details are ACPICA's rather
than the prose's:

- a **Buffer** destination **keeps its length**: the converted source is
  copied over the first `min(dst,src)` bytes and the remainder is
  **zeroed** (`AcpiExStoreBufferToBuffer`, ACPI 2.0+). A table that patches
  two bytes of a resource template depends on that;
- a **String** destination is **replaced**, because ACPICA reallocates a
  string target rather than padding it. The two differ deliberately.

The counterpart is §19.3.5.8: a store to a `LocalX` or to `DebugObj` does
**no** conversion and overwrites wholesale, and `CopyObject` (§19.6.20)
does no conversion anywhere. Three behaviours, three code paths, and the
corpus runs `Store` and `CopyObject` **on the same fixture** — because the
only way to prove `Store`'s conversion is doing something is to put it next
to the operator that deliberately does not convert.

### Where this follows ACPICA rather than the prose

Firmware is written against ACPICA, so ACPICA is what is implemented:

- **Integer → String (hex) is fixed width and zero padded**, `width/4`
  characters. `ToHexString(One)` on a 64-bit table is
  `"0000000000000001"`. Suppressing the leading zeros looks tidier and
  breaks every table that indexes into the result at a fixed offset.
- **Integer → String (decimal) suppresses leading zeros.** The two
  disagree, deliberately.
- **Buffer → String is a comma-separated element list**, not a number:
  `"AB,CD,EF"` in hex, `"1,2,3"` in decimal, empty for an empty Buffer.
  Reading a Buffer as one big number loses the fact that it was elements.
- **String → Integer** accepts decimal *and* `0x`-prefixed hex, skips
  leading blanks, and stops at the first character that is not a digit in
  the chosen base. A string with **no digits at all is zero and not an
  error**, which real tables rely on.
- **`ToString` stops at the first NUL *or* at the length, whichever comes
  first.** Both terminators. Stopping only at the NUL loses the length
  argument; stopping only at the length copies embedded NULs into a String
  that then measures longer than it prints.
- **`ToBuffer` of a String includes the terminating NUL** (§19.6.140).
- **`SizeOf` of an Integer is an error** (§19.6.125), not the integer
  width. Answering the width is what an implementation that thinks `SizeOf`
  is `sizeof()` does, and the answer is wrong in a way that only shows up
  when a table branches on it.

### The store boundary, moved

#1055 refused anything needing a reference object. Storable now:

1. the `Zero` literal — the null target, discards;
2. `LocalX` — overwrite, **no** conversion (§19.3.5.8);
3. `ArgX` — overwrite, **except** that an `ArgX` already holding a
   Reference stores **through** it (§19.3.5.8: that is how a method mutates
   an object its caller passed by `RefOf`). `LocalX` does **not** behave
   this way, the asymmetry is the specification's, and the corpus pins both
   halves because an implementation that made them agree would be wrong
   whichever way it made them agree;
4. a `NAMEREF` — convert to the destination's existing type, §19.3.5.7, for
   **every** type and not only integers;
5. `DebugObj` — a real sink; firmware writes to it constantly;
6. an `Index()` expression — evaluated to a reference and stored through,
   per its sub-kind;
7. a `RefOf()` expression, or any operand evaluating to a Reference.

**The new boundary is drawn at objects whose storage is not in this
process.** A **FieldUnit** — an `OperationRegion` field element — is
`BAD_TARGET` (41), because writing one is a bus transaction and belongs to
R30.M3's region handlers. Reading one is refused for the same reason.
Also refused: a Package or Buffer *object* used directly as a destination
without an `Index`, and a Method or Device name, which are declarations
rather than value cells.

### `CondRefOf` — the one place a miss is a value

§19.6.19 is the only construct in AML where a namespace miss is **data**:
`CondRefOf` returns False for an absent name rather than failing.
`aml_eval_set_quiet` suppresses **exactly one** latch —
`NAME_NOT_FOUND` (36) — for the duration of one resolution, and restores
the previous value on every path (which matters because a `CondRefOf` may
appear inside another one's Result target). It does **not** suppress
`BAD_PARENT_PREFIX` (39) or `NAME_TOO_DEEP` (38): a malformed path is not a
miss, and `CondRefOf(^^^^^^FOO)` from the root is a broken table whether or
not `FOO` exists. A flag rather than a third parameter on
`aml_eval_resolve` because resolve has four exit paths and a parameter
would touch all of them; the flag touches one.

### `DerefOf` of a String is refused, deliberately

§19.6.28 also permits a String naming a namespace path. Implementing it
means building a **name-arena entry from heap bytes at evaluation time** —
and the name arena is part of the parse tree, which evaluation is forbidden
to mutate (§11). So it is `BAD_REF` (45), a refusal with a code, waiting for
the evaluator to own name scratch of its own. A wrong dereference is worse
than no dereference.

---

## 14. Two dispatchers, and why the integer one stays

`aml_eval_obj` is the twin of `aml_eval_node`: it evaluates a node in
**object** position and returns an object index. It takes its own step of
fuel and its own level of depth *before* dispatch, so every object-valued
construct inherits the termination and stack guarantees without a single
handler remembering them — nested `Package`s consume depth without looping
and are the construct that reaches the depth guard through this path.

Keeping **two** dispatchers is not a speed optimisation, it is a
correctness requirement of a bounded arena. The object arena is 512 records
with no free, and a `While` loop containing a `Store` — an idiom in
essentially every DSDT — would exhaust it in 512 iterations if every store
allocated. So:

- `aml_eval_node` keeps an allocation-free path for INT, untagged
  `ArgX`/`LocalX`, a `NAMEREF` to an unbound integer `Name`, every #1055
  operator, `CALL`, and `RevisionOp`;
- it delegates to `aml_eval_obj` the moment a type appears that an integer
  cannot represent;
- `StoreOp` gets a fast path guarded by `aml_eval_expr_int_ok`, which is
  `aml_eval_int_shaped(source) && aml_eval_dest_is_int(target)`. Both
  predicates resolve a `NAMEREF` **quietly**, because a miss must not latch
  from inside a predicate — the slow path is about to resolve it again and
  latch the real error at the real site;
- the same predicate is used by the statement dispatcher, so a `Store` in
  statement position and the same `Store` inside an `If` predicate cannot
  take different paths.

Getting `aml_eval_dest_is_int` **too permissive** is the dangerous
direction: it would silently skip the §19.3.5.7 conversion. Too restrictive
only costs allocations.

The corpus asserts an arithmetic-only method leaves `aml_obj_count()` at 1
and touches no heap, and that a hundred-iteration `Store` loop does the
same. A mutant that disables the fast path is killed by exactly those.

### Frame slots as objects

A slot holds a 64-bit word; which *interpretation* applies is a bit in the
frame's tag bitmap at +192 — the tail #1054 reserved for this. Bits 0..6
are `Arg0..Arg6`, bits 8..15 are `Local0..Local7`; the gap at bit 7 keeps
the two runs on nibble boundaries. Clear means AML Integer, set means
object index.

A bitmap and not a byte per slot because a frame's whole type state is then
**one word**: `aml_frame_push` zeroes it with the same loop that zeroes the
slots, so a fresh `Local0` is the Integer Zero (§19.6) with no extra
initialisation, and **an integer write retypes a slot by clearing one bit**
rather than by maintaining a second array that could fall out of step. That
clearing is load-bearing: an object index and a small integer are both
small numbers, and no heuristic can tell them apart, so `Local0 = 3` would
otherwise read back as a reference to object 3.

---

## 15. Error taxonomy — continuing §7

| code | name | meaning |
|---|---|---|
| 42 | `AML_ERR_OBJ_ARENA_FULL` | 512 objects in use |
| 43 | `AML_ERR_OBJ_HEAP_FULL` | 8192 payload bytes in use |
| 44 | `AML_ERR_OBJ_ELEM_FULL` | 1024 package element slots in use |
| 45 | `AML_ERR_BAD_REF` | `DerefOf`/store through a non-reference |
| 46 | `AML_ERR_OBJ_RANGE` | index outside the object's own extent |
| 47 | `AML_ERR_NO_CONVERSION` | §19.3.5 defines no conversion for the pair |
| 48 | `AML_ERR_BAD_OBJTYPE` | an operand type the operator does not accept |
| 49 | `AML_ERR_STALE_REF` | frame reference whose frame has been reused |
| 50 | `AML_ERR_UNINIT_ELEMENT` | package element that was never initialised |

They latch through `aml_eval_set_err` — the object module has **no error
slot of its own**. Object allocation happens only during evaluation, and a
second first-writer-wins slot would mean an arena-full condition that did
not block evaluation, which is precisely the "caller forgot to check"
failure `aml_eval_spend`'s execution-blocking rule exists to make
impossible.

---

## 16. Verification — #1056 / #1057

`tools/verify-aml-parser.sh` now compiles **eleven** modules and carries
two more `objdump -r` confinement assertions: the object arena confined to
`aml_obj.o`, and `aml_conv_tab` confined to `aml_str.o`. `aml_str.o` and
`aml_ref.o` declare no mutable storage at all, so adding them to `MODULES`
cost no new assertion and made every existing one strictly stronger — the
conversion engine and the reference machinery are now proved unable to
reach the lexer cursor, the parse arenas, the opcode table, the evaluator
context, the frame pool or the object arena except through the accessor
APIs.

### Corpus — 2295 assertions, up from 1755

New coverage, in the order the risk was ranked:

- **The §19.3.5.7 direction test.** `Store(0x99, BUFX)` where `BUFX` holds
  `Buffer(4)` leaves a **Buffer of length 4** whose byte 0 is `0x99` and
  whose remaining bytes are zeroed — and `CopyObject(0x99, BUFX)` on the
  same fixture retypes it to Integer. The parse tree is asserted unchanged
  throughout, and a fresh session is asserted to see neither store.
- **Operator-keyed conversion, proven by the pair.** `Add("5", 3)` is 8;
  `ObjectType(Concatenate(5, 3))` is Buffer; `Concatenate("ab", 5)` is
  eighteen characters, because the implicit Integer → String rule is
  fixed-width hex.
- **All three `Index` forms**, each asserted to yield its own reference
  sub-kind, each `DerefOf` round-tripped through AML, and the same Integer
  stored through a buffer index and a package index asserted to land
  differently.
- **`CondRefOf`** on a name declared inside a `Device` and therefore
  invisible from the root: False, no latch, quiet flag restored — while a
  plain `RefOf` of the same name is `NAME_NOT_FOUND`.
- **`ToString`** truncating at the NUL and at the length, on the same
  fixture, plus a buffer with no NUL at all.
- **`ToInteger`** on decimal, `0x`-hex and Buffer sources.
- **`Match`** over a Package, including the `MTR` shortcut and the raw
  `MatchOpcode` bytes coming from the node's `arg0`/`arg1` rather than from
  the child list.
- **`ConcatenateResTemplate`**, with the descriptor chain **walked** to its
  `EndTag` rather than assumed to end in one.
- **Malformed**, each with its own code: `Index` out of bounds (46),
  `DerefOf` of a non-reference (45), `SizeOf` of an Integer (48), package
  element past `NumElements` (46), an uninitialised element within
  `NumElements` (50), a stale frame reference (49), a Package converted to
  an Integer (47).
- **Budgets**: the object dispatcher spends exactly one step on a leaf and
  refuses on a latched error; `Match` spends one step *per element*, proved
  with a `Package(200){}` and a sixty-step budget; a `Concatenate` loop
  terminates on fuel at a small budget and on `OBJ_HEAP_FULL` at the
  default; fifty nested `Package`s reach `EVAL_DEPTH`; all three object
  arenas refuse rather than grow.

### Mutation testing — twenty-five mutants, twenty-four killed

| mutant | killed by |
|---|---|
| store converts to the SOURCE type (§19.3.5.7 inverted) | `SizeOf is still 4 after storing an Integer` |
| a Buffer destination is replaced, not length-preserved | `of the DESTINATION's length` |
| `Index(String)` yields a buffer-field kind | `Index(String,n) is a StringField reference` |
| buffer-field store routed to the element store | `stored through the buffer field` |
| `CondRefOf` no longer suppresses the miss latch | `AND DOES NOT LATCH` |
| `ToString` ignores its length argument | `stops at the LENGTH when that comes first` |
| `ToString` ignores the NUL | `stops at the first NUL` |
| `ToInteger` drops the `0x` prefix rule | `Add takes a hex string too` |
| Integer → String hex is not zero padded | `Concatenate String+Integer converts to hex String` |
| Buffer → String is one number, not a list | `hex elements, comma separated` |
| `Mid` does not clamp its length | `Mid clamps its length to what remains` |
| `SizeOf` of an Integer answers the width | `SizeOf of an Integer is refused` |
| `mk_string` counts the NUL as a character | `SizeOf a String excludes its NUL` |
| the `ToHexString` table row says decimal | `ToHexString wants hex` |
| uninitialised element reads as the null object | `UNINIT_ELEMENT, not OBJ_RANGE` |
| frames are not stamped with a serial | `but not the same serial` |
| `ArgX` overwrites instead of storing through | `THE REFERENCED NAME WAS WRITTEN` |
| an integer Local write does not clear the tag | `AND CLEARS THE TAG` |
| an integer Arg write does not clear the tag | `AND CLEARS THE TAG` |
| the tag bitmap puts locals on the arg run | `AND CLEARS THE TAG` |
| the object dispatcher spends no fuel | `AND IT SPENT EXACTLY ONE STEP` |
| the object dispatcher takes no depth | `nested Packages reach the DEPTH guard` |
| `Match` spends no fuel per element | `FUEL_EXHAUSTED` |
| an Integer-valued Name is bound (invariant broken) | `the reference it stored dereferences` |
| `ObjectType` answers the DECLARED type | `CopyObject retypes the destination` |
| `CopyObject` converts like `Store` | `CopyObject retypes the destination` |
| a session does not reset the object arena | `Concatenate(Int,Int) is a 2*width Buffer` |
| the `Store` fast path is disabled | `the Store fast path allocated nothing` |

One mutant was **equivalent** and is recorded rather than chased: dropping
the `and rax, 255` before a buffer-field store changes nothing, because
`mov_b` truncates at the write. The semantically real version of that
mutation — routing a buffer-field store to the *element* store — is in the
table above and is killed.

Two of the corpus's assertions were added *because* a mutant survived the
first round, which is the failure mode the technique exists to find: the
object dispatcher's fuel spend was invisible until the assertion used a
**leaf** node (an operand that itself evaluates spends through
`aml_eval_node` and hides the omission), and `Match`'s per-element spend
was invisible until a package large enough to matter was in the corpus.

### Toolchain

No paideia-as gap surfaced. The object model exercises `mov_b` stores,
`mov_d` indexed stores into `[u32; N]` arrays, variable shifts through
`cl` and `imul r64, r64` — all already supported. One encoder note for the
record: `mul r64` is not in the resolver table, and `imul r64, r64` is the
supported form; the two differ only in the high half, which no conversion
here needs.

---

## 17. Invocation — #1058

Three things arrive together because they are one mechanism seen from
three sides: what a call *checks*, what it *passes*, and what it *gives
back*.

### The arity cross-check, and why it is defence in depth

`aml_eval_call` has always taken the argument count from the **CALL
node's** flags, which R30.M1's two-pass parser fixed. It now also reads
the count from the **METHOD node** the §5.3 walk actually landed on, and
refuses a disagreement with `ARG_COUNT` (51).

The two numbers have different provenance, and that is the entire reason
to compare them. The parser matched on the **final NameSeg**, because full
scope resolution needs a namespace it does not yet have; the evaluator
resolved the **full path**. When those disagree, the parser consumed the
wrong number of argument bytes and every byte after the call site is
misaligned — a parse that *succeeded* and is wrong, which is the failure
class `aml-parser.md` §3 exists to eliminate.

No AML input reaches it today: `aml_term_lookup` refuses with
`AMBIGUOUS_CALL` (21) the only tables that could produce a disagreement.
That is exactly why the check is a **named function with its own two
parameters**, `aml_eval_arity_ok`, rather than four lines inlined in the
caller — the corpus drives it directly with a mismatched pair, so the
check is tested rather than merely present. Writing an AML fixture for an
unreachable branch would mean writing a fixture that cannot fail.

### Argument promotion — shape, then table

An argument is evaluated in the **caller's** frame (that was #1054's
ordering, and it is unchanged), then routed:

| the argument node is | evaluated by | bound by |
|---|---|---|
| integer-shaped (`aml_eval_int_shaped`) | `aml_eval_node` | `aml_frame_set_arg` |
| anything else | `aml_eval_obj`, then `aml_conv_cast` | `aml_frame_set_arg_obj` |

The shape test first, because the fast path is the point: a loop calling
an arithmetic helper must not allocate an object per call, or the 512-record
arena is gone in 512 iterations. The **table** second, and it is a real
table row rather than a hook:

```
0x000000000000FF01   METHOD ARG   ANY, ANY, ANY, ANY   (§19.6.83)
```

`0xFF01` is not an opcode. op16 is a single byte (`0x00..0xFF`) or an
extended `0x5Bxx`, so nothing in the encoding can collide with it. The row
says **ANY in every position**, which is a positive statement and not a
filler: §19.6.83 gives method arguments no implicit conversion, the callee
sees exactly the object the caller computed — and *without the row* the
default shape applies, which wants **Integer at position 0** and a
**TARGET at position 2**. Both are wrong for an argument and the first
would coerce every Buffer ever passed to a method. The corpus asserts both
halves: that the row says ANY, and that the default would not.

The payoff is that a future predefined-method signature table — `_OSI`
wanting String, `_SRS` wanting Buffer — is a **row**, and `aml_eval_call`
does not change.

### The consequence that is the actual feature

`Store(0x2A, Arg0)` in a callee now means two different things depending
on what the caller passed, and that difference is §19.3.5.8:

```asl
Method (SETA, 1) { Store (0x2A, Arg0) }

Method (BYRF) { SETA (RefOf (TGTR));  Return (TGTR) }   /* -> 0x2A */
Method (BYVL) { SETA (TGTV);          Return (TGTV) }   /* -> 0    */
```

Identical callee, identical body, opposite observable effect. Before
#1058 the question could not arise: every argument was bound with
`aml_frame_set_arg`, which *clears* the object tag, so a `RefOf` argument
was flattened or refused and the two methods would have agreed. The
corpus uses **two** Names rather than one, because a single shared target
could be written by the by-reference call and then read by the by-value
one, and the fixture would pass while proving nothing.

### The return type

The retval slot is one 64-bit word, and an object index is
indistinguishable from an Integer in it. So there is now a tag —
`aml_eval_state + 104`, read through `aml_eval_retval_is_obj` — set by
exactly one place, `aml_eval_stmt`'s `Return` arm, and cleared by the same
store on the integer path.

Without it, `Return (Buffer (4) {...})` had two possible treatments and
both were wrong: refuse it (#1054 did, which refuses every `_CRS` ever
shipped), or flatten it to an Integer (which loses the buffer, silently,
one frame from where it was needed).

Three consumers, three behaviours, and they are deliberately not one:

- **`aml_eval_node`** (the integer dispatcher) converts through
  `aml_conv_cast(·, Integer)` — exactly as an operator wanting an Integer
  would, so `Add(FOO(), 1)` on a String-returning method applies §19.3.5
  rather than a bespoke rule, and on a Package-returning one is refused.
- **`aml_eval_obj`** takes the object with its type intact, which is what
  makes `SizeOf(FOO())` and `Index(FOO(), 0)` work.
- **`aml_eval_method`**, the top-level entry, returns the word plus the
  tag, with **one** unwrapping: an Integer *object* comes back as its
  value and the tag is cleared. An Integer object and an AML Integer are
  the same number, and making every caller unwrap would be ceremony — and
  a caller that forgot would read an arena index as data, which is a small
  plausible number and therefore the kind of wrong answer that survives
  review. Every other type comes back as an index with the tag set, and is
  **not** forced through a conversion: a Package-returning method is a
  perfectly good method, and latching `NO_CONVERSION` at the door would
  poison the session of a caller who only ever wanted the Package.

A `Return` whose child is itself a **CALL** is its own case rather than a
shape test, because `Return(FOO())` must re-return the callee's value
*with its type*, and `aml_eval_int_shaped` answers yes for every CALL.

---

## 18. `Notify` — #1059, and why the evaluator must never block

`Notify(Object, NotificationValue)` (§19.6.85) is the interpreter's only
**egress**: everything else in the evaluator is a pure function of the
arena plus the current frame. It therefore lives in a module of its own,
`aml_ctl.pdx`, with storage of its own and its own confinement assertion.

### The thing that must not be built

Send an IPC message and wait for the supervisor to take it. That is a
supervisor stall with a firmware-controlled trigger, and it is one line of
ASL away:

```asl
While (One) { Notify (\_SB.PCI0, 0x00) }
```

Firmware chooses the loop bound *and* the message rate. A blocking send
parks the interpreter, and every other ACPI consumer — thermal poll, lid
switch, battery — queues behind it. A `Notify` issued while the supervisor
is itself handling a notification deadlocks outright: the drainer is not
draining, because it is inside the evaluator that is trying to enqueue.

### What is built instead

A **bounded ring**, and the evaluator returns from `Notify`
unconditionally.

| | |
|---|---|
| depth | **32** entries, 1 KiB of `.bss`, never grown |
| entry | 4 × u64 — offer sequence, target arena node, notification value, target ObjectType |
| index | monotonic head/tail counters; only the *slot* wraps, so `head == tail` is unambiguously empty |
| drop policy | **tail-drop** |
| on drop | return 0, latch **nothing**, continue |
| fuel | one step, on the accepted **and** the dropped path |

**Tail-drop, not overwrite-oldest**, and the difference is not a
preference. Overwrite-oldest turns bounded *loss* into *reordering*: the
oldest entries are the ones the supervisor is about to act on, and
discarding a pending `Notify(DEV0, 0x03)` — an eject request, the user
pressed the button — because a later `Notify(DEV0, 0x80)` needed the slot
means the eject silently never happens while a thermal event does.
Tail-drop loses the newest, the one the supervisor has formed no
expectation about, and it makes the drop counter mean exactly "events you
were never told about".

**A drop is not an error.** `aml_notify_enqueue` returns 0 and latches
nothing. Making it a latched error would hand firmware a way to halt an
evaluation by filling a ring the supervisor happens not to have drained —
converting a bounded, recoverable loss into a hard failure, which is
backwards.

**Fuel is charged on both paths.** If dropping were cheaper than
succeeding, filling the ring would be the way to make a `Notify` storm
free.

### Observability — three counters and a sequence

```
aml_notify_offered   attempted, accepted and dropped alike
aml_notify_drained   popped by the supervisor
aml_notify_depth     pending
aml_notify_drops     refused
```

with the invariant the corpus asserts on every path, including the error
one:

```
offered == drained + depth + drops
```

The counter that matters is not `drops`. A global drop count tells the
supervisor **that** it missed something; the **per-entry offer sequence**
tells it **where**, because two consecutive drained entries whose
sequences differ by more than one bracket the loss. A supervisor that sees
a gap re-enumerates the affected bus instead of re-enumerating everything
— the difference between a recoverable drop and a useless one.

**The counters do not reset with the evaluation session.** `aml_eval_reset`
is per-invocation; the ring is per-supervisor. Clearing the drop count when
a new method starts would hide exactly the pattern worth seeing (a table
that overruns on every evaluation), and clearing the *ring* would discard
notifications nobody has drained. `aml_eval_reset` therefore calls
`aml_ctl_reset`, which touches the **mutex pool only**; the ring is cleared
by `aml_notify_reset`, which is the supervisor's to call.

### Types, and the two different refusals

Both operands go through `aml_conv_operand`, so the row in `aml_str.pdx`
is what says operand 0 is a Reference and operand 1 an Integer:

```
0x0000000001140086   0x086 Notify   REFERENCE, INTEGER
```

The want of `REFERENCE` does real work. `aml_conv_cast` returns a
Reference unchanged and latches `BAD_REF` (45) for anything else, so
`Notify(5, 0x80)` — and `Notify(SOMEINT, 0x80)`, where the name holds an
Integer — are refused by the **table**, and `Notify`'s body contains no
type test. What the table *cannot* say is that the reference must name a
**Device, Processor or ThermalZone**; that is `BAD_NOTIFY_TARGET` (52),
checked in `aml_ctl_notify_kind_ok`, and the list is closed because the
supervisor's handler table is keyed by those three ObjectTypes and has
nowhere to route anything else. Accepting a fourth would enqueue an event
that can only be dropped later, at a point with no context left to say
which table produced it.

### `Notify` is a statement, and that is load-bearing

§20.2.5.3 makes `DefNotify` a **Type1Opcode** — no value. It is therefore
intercepted in `aml_eval_stmt`, not in either value dispatcher. Two
consequences, both wanted:

- `Store(Notify(D,1), X)` is `NOT_EVALUABLE` rather than a plausible zero;
- a `Notify` allocates **no result object**, so a `While` loop full of them
  exhausts its fuel rather than the 512-record object arena — which means
  the ring-overrun fixture measures the bound it claims to.

### What the supervisor sees

The capability is **not** minted here. Delivery to a consumer is a hop
the supervisor makes *after* draining, and it was R30.M4's. The wire
format was pinned at this point — because a kind whose record shape is
decided in one round and written down in another is a kind whose two
halves disagree — and it survived the implementation, one level down.

**As landed (R30.M4-003, #1068).** `KIND_ACPI_EVENT = 0x151` over
**`KIND_HW_INTERRUPT`**, not `0x21` over `KIND_NOTIFICATION`. The
evaluator's `Notify` is only *one* of the stream's two sources; the other
is a hardware GPE arriving through the SCI, which is masked until the
subscriber acknowledges, and the acknowledgement is a write to the GPE
enable register. The record shape pinned here became the stream record
in `src/kernel/core/acpi/evt_stream.pdx` — widened to 64 B by a `source`
discriminator and a redundant `NEEDS_ACK` flag, so a subscriber can tell
a firmware notification (informational) from a GPE (owed an
acknowledgement) without inspecting the payload. `sequence` survives as
`seq`; the localisability argument is unchanged. Reconciliation table in
`design/architecture/next-wave-derived-kinds.md`; design record in
`design/kernel/r30-m4-sci-gpe-path.md` §§11–12.

---

## 19. Serialized methods — #1060

`MethodFlags` (§20.2.5.2) carries `SerializeFlag` at bit 3 and `SyncLevel`
at bits 4–7. A serialized method holds an implicit mutex at its SyncLevel
for the duration of the invocation.

### The re-entry that must not deadlock

The implicit mutex is **recursive for its owner**. A serialized method
that calls itself — directly, or through a helper that calls back — must
run, not hang. ACPICA implements this with an acquisition **count**
(`AcpiExAcquireMutexObject`: *"Support for multiple acquires by the owning
thread"*), and a straight test-and-set implementation of `Serialized`
deadlocks on the first recursive table it meets. This is not an exotic
input: firmware marks a method `Serialized` precisely because it touches
shared state, and shared-state helpers are exactly what gets called
recursively.

```
count == 0              -> take it, owner := ctx, count := 1
count > 0, owner == ctx -> count += 1, PROCEED
count > 0, owner != ctx -> would block
```

Release decrements and frees the entry at zero, so a recursive method
unwinds exactly as deep as it nested.

### SyncLevel ordering, enforced

§19.6.2, and ACPICA `AcpiExAcquireMutex`:

```
if (mutex->SyncLevel < thread->CurrentSyncLevel) -> AE_AML_MUTEX_ORDER
```

Acquiring **below** the highest level currently held is the error, and it
is `SYNC_LEVEL` (53). This is enforced rather than deferred, because
SyncLevel is what makes lock ordering a *static* property of the table: a
table that cannot deadlock can be distinguished from one that can without
running it, and a table that violates the ordering is one whose
deadlock-freedom nobody has established. Running it anyway is choosing to
find out on hardware.

The check is placed **before** the already-held test, as ACPICA places it,
and the ordering that produces is deliberate: `A(5) → B(7) → A(5)` is
refused, because re-entering the outer lock while holding an inner one is
precisely the cycle SyncLevel exists to expose. Straight self-recursion is
untouched — there `level == current`, and the test is strictly-less-than,
so the recursive case falls out of the same comparison rather than needing
a special case.

On first acquisition the entry saves the `CurrentSyncLevel` it displaced
(ACPICA's `OriginalSyncLevel`) and restores it on final release. Saved
**per mutex** rather than kept as a stack, so release is correct with no
separate unwind structure — and restored rather than recomputed, because a
maximum over the remaining entries would silently differ the moment two
methods share a level.

The release-order check ACPICA also has (`SyncLevel > CurrentSyncLevel` on
release) is **not** implemented, and the reason is that for *implicit*
method mutexes it cannot fire: they are acquired and released around
`aml_eval_body`, so their nesting is the call stack's and is LIFO by
construction. It becomes reachable when explicit `Acquire`/`Release` land
in R30.M3, and belongs there with the fixture that reaches it.

### Acquire and release are paired on every exit

Not on "the body returned". `aml_eval_call` releases after
`aml_eval_body` on the success path *and* on the error path, and
`aml_evc_frameless` releases when the frame pool refused a frame the
acquire had already been taken for. That last one is not hypothetical: it
is precisely what unbounded serialized recursion does — nine acquires,
eight frames, and the ninth call must give its mutex back on the way out.
A release wired only to the success path would leave the method
permanently held, and every later acquire in the session would then be
refused on SyncLevel grounds for reasons nothing in the error would
explain.

`aml_ctl_release` on something not held is a silent 0 and **not** a latch,
for the same reason: it is called on error paths, and a second latch would
replace the code describing what actually went wrong. The latch is
first-writer-wins, so the damage would be to diagnosis rather than to
correctness — which is the kind of damage that is hardest to notice.

`aml_ctl_leaked` counts entries still held when a session resets, and the
pool is forced clean rather than the reset refusing. Silent recovery plus
a visible count beats either a crash or an undetected wedge.

### Pool size

**8**, exactly the frame pool's depth. A mutex is held only while its
method is on the stack and at most 8 frames are live, so a ninth is
unreachable through AML — `aml_frame_push` refuses first with
`FRAME_OVERFLOW` (33). The bound is checked anyway, and the corpus reaches
it through the API, because "unreachable" is a property of *today's* frame
count and a pool that indexed past its end when that changed would corrupt
the notification ring next door.

### One execution context, stated honestly

There is exactly one AML execution context: `acpi_supervisor` evaluates
one method at a time. `aml_ctl_ctx` returns the constant 1, and the
`owner != ctx` arm **is unreachable from any input**. It is implemented
anyway, and it latches `MUTEX_CONTENTION` (54) rather than blocking,
because the thing that must not happen when a second context arrives is a
silent wrong answer — a refusal is a bug report, a fake acquire is a data
race.

The corpus does not pretend to test it. What it tests is what one context
can reach:

- recursive self-entry **succeeds** (the anti-deadlock fixture — under a
  test-and-set mutex this *hangs*, and the 60-second watchdog rather than
  an assertion is what makes that visible);
- the acquisition count **balances** across nested entry and exit, with
  the count and the held-entry count asserted **separately**, because an
  implementation that leaked an entry per recursion would still balance
  the count;
- a SyncLevel violation **errors**, and the legal upward direction still
  **succeeds** — a check that refused every nested acquire would pass a
  one-sided test;
- a leaked acquire is **detected** and recovered.

The owner comparison itself *is* covered: every successful re-entry takes
it, and inverting it turns those re-entries into `MUTEX_CONTENTION`. The
corpus kills that mutant. What has no fixture is the other side of the
comparison, and it stays that way until R30.M3 supplies a second context.

---

## 20. Error taxonomy — continuing §15

| # | Name | Meaning |
|---|---|---|
| 51 | `ARG_COUNT` | a call's arity disagrees with the declaration the walk resolved |
| 52 | `BAD_NOTIFY_TARGET` | `Notify` target is not a Device, Processor or ThermalZone |
| 53 | `SYNC_LEVEL` | serialized acquire below the currently-held maximum |
| 54 | `MUTEX_CONTENTION` | held by another execution context |
| 55 | `MUTEX_POOL_FULL` | more than 8 serialized methods held at once |

51, 54 and 55 are **not reachable from AML** today and each says so above:
51 because the parser refuses the inputs that would produce it, 54 because
there is one execution context, 55 because the frame pool exhausts first.
51 and 55 are reachable — and tested — through the API. 54 is not
reachable at all, and is recorded as such rather than given a fixture that
cannot fail.

---

## 21. Verification — #1058 / #1059 / #1060

`tools/verify-aml-parser.sh`, eleven modules to twelve, and two new
encapsulation assertions:

> `aml_notify_ring` and `aml_notify_state` are relocated against from
> `aml_ctl.o` and no other object.
>
> `aml_mutex_pool` and `aml_mutex_state` are relocated against from
> `aml_ctl.o` and no other object.

The ring's guarantee is the accounting identity, and it holds only for as
long as the three counters move together inside `aml_notify_enqueue` and
`aml_notify_pop`. A second writer — an evaluator that "just bumped the
drop count" on some other refusal, a supervisor that advanced head without
going through `pop` — breaks it with no symptom other than a notification
the OS never hears about and never learns it missed.

The mutex pool's guarantee is that a count is incremented in exactly one
place and decremented in exactly one other. A second writer there
reintroduces the deadlock the recursive acquire exists to prevent, or
leaks a hold that silently refuses every later acquire in the session.

### Corpus — 2723 assertions, up from 2295

Fourteen new fixtures. The ones worth naming:

| fixture | what only it can catch |
|---|---|
| `an argument passed by reference writes through` | two identical callee bodies, opposite effect — the §19.3.5.8 ArgX rule |
| `a Buffer survives being passed and being returned` | object arguments and object return values, neither of which #1054 could express |
| `the return tag says Integer for an Integer` | the tag's *negative* half, including that falling off the end clears a previous invocation's tag |
| `a call's arity is checked against the declaration` | the cross-check, driven directly because no AML input reaches it |
| `a full ring drops, counts, and does not block` | tail-drop *and* the accounting identity, over 40 offers into a 32-deep ring |
| `an unbounded Notify loop ends on fuel, not on a block` | that the ring never blocks — under the watchdog, a regression here hangs |
| `a serialized method may call itself` | the anti-deadlock property; a test-and-set mutex hangs rather than fails |
| `unbounded recursion trips the frame pool, not a leak` | the release on the frame-overflow path |
| `SyncLevel orders acquisition, downward is an error` | both directions, so a check that refused everything would not pass |
| `the mutex pool is bounded and a leak is detected` | the pool bound and the leak counter, both through the API |

### Mutation testing — sixteen mutants, sixteen killed, one after a fix

| mutant | killed by |
|---|---|
| the drop counter never increments | `eight were refused` |
| the enqueue spends no fuel | `and it cost exactly one step` |
| a Device reports its arena kind, not its ObjectType | `the ObjectType, not the arena kind` |
| every node kind is notifiable | `not notifiable` |
| `Notify` operand 0 wants ANY, not REFERENCE | `BAD_REF, from the conversion table` |
| `Notify` is not intercepted in statement position | `callee sets its own Local0` (NOT_EVALUABLE cascade) |
| the serialized acquire is test-and-set | `re-entry by the owner SUCCEEDS` |
| release frees the entry on every release, not at zero | `count 2` |
| the SyncLevel order check is removed | `SYNC_LEVEL` |
| final release does not restore the displaced level | `the level it displaced comes back` |
| no release when the frame pool refuses | `nothing still held` |
| arguments are always bound as integers | `SETA(RefOf(TGTR)) reached the caller's Name` |
| the return tag is never set | `SizeOf a Buffer is its byte count` |
| the arity cross-check is inverted | `caller's Local0 survives the call` |
| the METHOD-ARG table row is removed | `no implicit conversion at any argument position` |
| tail-drop becomes overwrite-oldest | `eight were refused` |

**One mutant survived the first round**, and the fix is the interesting
part. Deleting the fuel spend from `aml_notify_enqueue` passed every
assertion, because the fixture measured fuel *across the whole `Notify`
statement* — and `Notify`'s two operands evaluate through `aml_eval_obj`,
which spends its own steps, so the total still dropped. The corpus now
measures the **leaf**: `aml_notify_enqueue` called directly, asserted to
cost exactly one step on the accepted path and exactly one on the dropped
path. This is the same lesson #1057 recorded for the object dispatcher's
fuel spend, arrived at independently, which is itself worth recording: a
before-and-after measurement across a composite operation cannot see a
missing charge inside it.

### Toolchain

One paideia-as encoder limit met and worked around rather than escalated,
because a workaround exists and is not worse: `sub r64, [mem]` and
`add r64, [mem]` are not in the phase-3-m2-002 encoder minimum
(`error[B1705]: sub form not in phase-3-m2-002 minimum`). The register-
register forms are, so every such site loads through a scratch register
first. No paideia-as issue was filed: the two-instruction form is what the
rest of this subsystem already writes, and a one-off encoder addition for
readability would not have paid for the version churn. `movabs`-width
immediates were likewise avoided — the drop counter saturates by
incrementing and testing for wrap rather than by comparing against
`0xFFFFFFFFFFFFFFFF`, and the owner/level word is split with a
shift pair rather than an `and` against a 32-bit mask.

---

# R30.M3-002 (#1062) — the SystemMemory address-space handler

`src/user/aml/aml_region.pdx`

This is the milestone at which this subsystem stops being pure
computation over a byte buffer. Everything before it could be tested
exhaustively because it touched nothing but its own arenas. A region
handler cannot claim that: its purpose is to read and write addresses
outside the process.

## The mapping / access split

The module is cut in two along the line the security argument already
runs along.

**The mapping step** — `aml_region_bind(node, cap_handle, win_base,
win_len, host_va)`. Takes a capability window and the host address that
window is mapped at, checks the firmware-declared region against it, and
records a binding. It decides *whether* an address may be touched and
*where* it lives. It performs no access.

**The access step** — `aml_region_read_unit` / `aml_region_write_unit`
and the field machinery above them. Takes a **binding index** and a byte
offset. It has no way to name an address: the base it uses is the one
the mapping step recorded, the length it clips to is the one the mapping
step validated.

The corpus therefore exercises the **real** access step — the real
bounds arithmetic, the real access-width selection, the real
read-modify-write — against a synthetic backing buffer, by handing the
mapping step a `host_va` that points at that buffer instead of at mapped
device memory. Not one line of the code under test differs between the
two cases. **No fixture in this repository names a real physical
address**, and none needs to: the part that would differ is the part that
does no arithmetic.

The declared base and length come from the **parse tree** (the untrusted
side — the node's `arg0`/`arg1` index the u64 side table); the window
comes from the **capability** (the trusted side, read out of the
`KIND_OP_REGION` row). They are never the same argument, which is what
makes the containment check a real comparison rather than a value
against itself.

## Why a missing capability cannot be bypassed

Four properties, together:

1. **The access step takes no address.** `aml_region_read_unit(b, off,
   n)` computes `host_base(b) + off`. No entry point in this module
   accepts a raw pointer. A caller that has not been through
   `aml_region_bind` has nothing to pass.
2. **`host_base` has exactly one writer.** Only `aml_region_bind` stores
   to a row, and it refuses before storing if the capability handle is
   zero, the window length is zero, the host address is zero, or the
   declared range is not contained in the window. There is no
   "bind unchecked" variant, because the checked one is the only one.
3. **The storage is confined.** `tools/verify-aml-parser.sh` asserts via
   `objdump -r` that `aml_region_tab` and `aml_region_state` are
   relocated against from `aml_region.o` and no other object. A module
   that reached the table directly could fabricate a row; none can.
4. **The liveness test is the lookup.** Every access path opens with
   `aml_region_row_live`, which requires a non-zero node *and* a
   non-zero capability handle *and* a non-zero host base. A row that
   failed any gate in `aml_region_bind` was never written, so it fails
   here exactly as a free row does — which makes "the bind was refused"
   and "there was never a bind" the same safe outcome at the access
   site, rather than two code paths one of which could be forgotten.

The kernel half is `src/kernel/core/cap/kind_op_region.pdx`: no kernel
path yields a `KIND_OP_REGION` covering a range the caller did not
already hold, and the window this module receives comes out of that
capability's own row — never out of the firmware table.

**Refusal, never truncation.** A declared region exceeding its backing
capability is refused whole at bind time (`AML_ERR_REGION_NOT_COVERED`);
a region with no covering capability at all is
`AML_ERR_REGION_NO_CAP`, refused before any address is formed.

## Access width is declared, not chosen

An AML `Field` carries an AccessType, and it is not a hint. Real
hardware registers latch on the transaction width: servicing a
`DWordAcc` field with four byte reads can return four snapshots of a
register that changed between them; servicing a `ByteAcc` field with a
dword write can touch three neighbouring registers with side effects.

| Declared | Resolved width |
|----------|----------------|
| `AnyAcc` | 8 |
| `ByteAcc` | 8 |
| `WordAcc` | 16 |
| `DWordAcc` | 32 |
| `QWordAcc` | 64 |
| `BufferAcc` | refused (`AML_ERR_REGION_ACCESS_WIDTH`) |

`AnyAcc` resolves to 8 for a memory window: it means "the interpreter
may choose", and the narrowest choice is always inside the permission
granted, where a wider one may not fit near the end of a region. The
resolver is a **table** so that #1064's PCI_Config handler — where dword
is the natural unit and `AnyAcc` must resolve to 32 — becomes a row here
rather than a special case elsewhere. `BufferAcc` is the SMBus /
GenericSerialBus / IPMI protocol form; treating it as `ByteAcc` would
run a protocol field as raw memory.

## Bit-granular fields, and read-modify-write

Fields are bit-granular and need not be aligned. The read loop walks the
field's bit extent one **aligned access unit at the declared width** at a
time, extracting the intersection of the field with each unit and
appending it at the running output bit position.

The write loop is the same walk, with the UpdateRule (§19.5.5.2)
deciding the fate of the bits of a touched unit the field does not cover:

| Rule | Uncovered bits | Reads first? |
|------|----------------|--------------|
| `Preserve` (0) | unchanged | **yes** — this is the RMW |
| `WriteAsOnes` (1) | become 1 | **no** |
| `WriteAsZeros` (2) | become 0 | **no** |

The suppressed read under rules 1 and 2 is deliberate and is *why those
rules exist*: they name registers where reading has a side effect
(clear-on-read status, FIFO pops). An implementation that read anyway
"to be safe" would corrupt exactly the hardware the rule was written to
protect. The corpus asserts the access **count**, which is what makes
the suppression observable: `Preserve` costs two accesses per partial
unit, the other two cost one.

## Straddling is an error, not a narrower access

If an access unit at the declared width would extend past the end of the
region, the access is refused (`AML_ERR_REGION_OOB`). It is not wrapped,
not partially completed, and not silently narrowed to the bytes that fit.

Narrowing is the tempting repair — the bits the field wants are inside
the region, after all. It is wrong twice: it changes the transaction
width the table declared, and it means the region's length no longer
bounds what a table can reach with a well-chosen field offset. The
corpus discriminates the two designs directly: a six-byte region with
two fields over the same bits at byte 4, one `ByteAcc` and one
`DWordAcc`. The byte one reads; the dword one must not.

## The FieldUnit boundary moves here

R30.M2-004 (#1057) left every FieldUnit load and store refused with
`AML_ERR_BAD_TARGET` (41), noting that "writing one is a bus transaction
and belongs to R30.M3's region handlers". This milestone is that, and
three sites in `aml_eval.pdx` move: `aml_eval_read_named`,
`aml_eval_obj`'s NAMEREF arm, and `aml_eval_store_named`.

**Now real:** a load or store of a FieldUnit whose enclosing `Field`
names a **SystemMemory** OperationRegion that has been **bound** to a
capability window.

**The new boundary**, stated so the next issue inherits a line and not a
guess:

| Case | Code | Owner |
|------|------|-------|
| SystemIO, PCI_Config, EmbeddedControl, any other space | `AML_ERR_REGION_SPACE` (62) | #1063 / #1064 / #1065 |
| FieldUnit under an `IndexField` / `BankField` | `AML_ERR_REGION_INDIRECT_FIELD` (64) | R30.M4 |
| Field wider than 64 bits (reads as a Buffer per ACPI) | `AML_ERR_REGION_FIELD_WIDTH` (61) | R30.M4 |
| Region never bound to a capability | `AML_ERR_REGION_UNBOUND` (58) | — this is the refusal |
| A destination that names no cell at all | `AML_ERR_BAD_TARGET` (41) | unchanged |

`AML_ERR_REGION_UNBOUND` replacing `AML_ERR_NOT_EVALUABLE` on this path
is a deliberate sharpening. `NOT_EVALUABLE` said only "I do not know
how", which is no longer true and would hide a **missing grant** behind
an implementation gap. An operator reading a log has to be able to tell
those apart.

## Error codes

Continuing the shared code space of §5.

| Code | Name | Meaning |
|------|------|---------|
| 56 | `AML_ERR_REGION_NO_CAP` | no covering capability at all |
| 57 | `AML_ERR_REGION_NOT_COVERED` | declared range exceeds the window |
| 58 | `AML_ERR_REGION_UNBOUND` | access to a region with no binding |
| 59 | `AML_ERR_REGION_OOB` | outside the region, or straddling its end |
| 60 | `AML_ERR_REGION_ACCESS_WIDTH` | access type illegal for this space |
| 61 | `AML_ERR_REGION_FIELD_WIDTH` | field wider than 64 bits |
| 62 | `AML_ERR_REGION_SPACE` | address space not serviced yet |
| 63 | `AML_ERR_REGION_TABLE_FULL` | binding table exhausted |
| 64 | `AML_ERR_REGION_INDIRECT_FIELD` | `IndexField` / `BankField` element |

## Fuel

Every unit access spends one unit of evaluator fuel through the same
`aml_eval_spend` the termination guarantee rests on. A field spanning
*K* access units costs *K*, not 1 — otherwise a `While` loop over a wide
unaligned field becomes a way to buy unbounded hardware transactions
with a bounded fuel budget. `aml_region_accesses` counts the same events
so the corpus can assert the two agree; the assertion is written as
`fuel_before - fuel_after == accesses_delta` rather than as a bare
"fuel dropped", which is the lesson #1059 recorded about composite
measurements.

## Mutation evidence

Seven mutants of the handler, all killed by the corpus:

| Mutant | Killed by |
|--------|-----------|
| skip the containment check in `bind` | "short window → refused" |
| skip the "is there a capability at all" gate | "no cap → refused" |
| service a `DWordAcc` field with byte accesses | "its declared width is 32" |
| drop the read-modify-write merge | "F0's bits are untouched" |
| drop the upper bounds clip | "one past the end is out" |
| make `aml_region_mask(64)` return 0 | "mask 64 is all ones, not zero" |
| spend no fuel on a unit access | "fuel was spent once per access" |

Three mutants of the kernel capability, all killed by the boot witness:
skipping the containment check on derive, accepting either base kind for
a root, and making the cascade single-pass.

The third of those **initially survived**, and the fix was to the
fixture rather than to the code: the witness had laid its window chain
out with the root at the lowest cap slot, so the ascending cascade scan
happened to reach every descendant in one sweep and the fixed-point loop
was untested while looking tested. Reversing the slot order made it a
real test. That is worth recording as a general shape — *a fixed-point
algorithm tested on input that converges in one step is not tested at
all* — and it is the second time in this subsystem that mutation found a
fixture measuring the wrong thing rather than an implementation bug.

---

# R30.M3-003/004/005 (#1063 / #1064 / #1065) — SystemIO, PCI_Config, EmbeddedControl

R30.M3-002 left three spaces refused and predicted that each would become
"a row in `aml_region_space_supported`, not a branch somewhere else".
That prediction held: the three additions are rows in two tables — the
serviced-space predicate and the access-width resolver — plus one new
transaction primitive, one namespace walk, and one gate.

## The new boundary of `AML_ERR_REGION_SPACE` (62)

Four spaces are serviced: SystemMemory (0), SystemIO (1), PCI_Config (2),
EmbeddedControl (3). Code 62 now means exactly, and only:

| Space | Why it stays refused |
|-------|----------------------|
| SMBus (4) | bus protocol; an access is a command/reply transaction |
| SystemCMOS (5) | index/data pair at 0x70/0x71 — offset *N* is **not** port 0x70+*N* |
| PciBarTarget (6) | needs the BAR resolved through the device's `_CRS` |
| IPMI (7) | request/response over a BMC interface |
| GeneralPurposeIO (8) | pin-addressed, needs `_CRS` `GpioIo` connection |
| GenericSerialBus (9) | protocol-typed access carrying a buffer |
| PCC (10) | mailbox with a doorbell handshake |
| 0x80 and above | vendor-defined; no interpretation exists |

SystemCMOS is the one worth naming twice, because it is the one that
*looks* serviceable on the SystemIO path. It is not: writing the index
register with data is the failure, and it is silent.

## The transaction/logic split, per space

The split established by #1062 is what lets the corpus run the real code.
It falls differently for each space, and stating where is the point.

**PCI_Config** needs *no new transaction primitive at all*, because an
ECAM access **is** a memory access. This is the same fact that makes
`opregion_space_base_kind` map PCI_Config to `KIND_MEMORY`. Everything
#1064 adds is pure logic over the parse tree and is therefore tested
directly, against a 4096-byte synthetic function. No configuration space
is read by the corpus.

**SystemIO** shares the entire logic path with memory. The transaction is
`in`/`out`, confined to `aml_region_port_in` and `aml_region_port_out`,
the only two functions in the repository containing those instructions —
asserted by `tools/verify-aml-parser.sh` against the disassembly, with a
vacuity guard requiring the two functions to actually contain six port
instructions so the check cannot pass by finding nothing.

**The corpus performs no real port I/O**, and that is a refusal rather
than a gap. A ring-3 `in` faults, and it was tempting to use that fault
as proof the sentinel path reaches a real instruction. It is bad
evidence: it holds only while the harness lacks I/O privilege, and an
assertion that evaporates under more privilege is not an assertion. It
would also mean issuing a genuine transaction against whatever PS/2
controller belongs to the machine running the pre-push hook. The path is
pinned two other ways instead — the static confinement check above, and a
behavioural discriminator that needs no transaction: a qword access
through a real-port binding is refused with `ACCESS_WIDTH`, because no
8-byte port instruction exists, whereas a mutant routing the sentinel to
memory dereferences address 1 and dies of a SIGSEGV the harness reports.

**EmbeddedControl** has no transaction to split. See the gate below.

## SystemIO

*Port space is 16 bits.* Not a policy limit: `in`/`out` take the port in
DX and no wider form exists, so a port above 0xFFFF is unaddressable, not
merely unauthorised. Checked at bind with the same overflow-safe shape as
`aml_region_contains` — `decl_base + decl_len` is never formed — and
refused with `AML_ERR_REGION_PORT_RANGE` (65) **before** the containment
check, because it is a property of the space rather than of the grant.

*There is no qword port access.* `QWordAcc` on a SystemIO region resolves
to 0 in `aml_region_acc_bits` and is refused with `ACCESS_WIDTH`. It is
**not** split into two dword transactions: two reads of a port are two
transactions, and on a FIFO or a clear-on-read status register that is a
different and destructive operation. The refusal is doubled — once in the
width table, once inside the real-port branch of the access step — and
the encoder agrees, since paideia-as's `In { width }` admits only 1, 2
and 4.

*The read-modify-write hazard is sharper here than for memory.* A port
read can clear a status bit, pop a FIFO or advance a latch. `Preserve` on
a partial field write therefore performs a genuine destructive read when
the table asks for one. The handler does not second-guess that: **what a
`Preserve` partial write to a port does is exactly one read of the unit
followed by exactly one write, and nothing else.** The table's own remedy
for a port where that is wrong is to declare `WriteAsOnes` or
`WriteAsZeros`, which suppress the read entirely — the machinery #1062
built for precisely this case. The corpus asserts the **access count**,
not merely the resulting bytes, because all three rules produce a
plausible-looking byte and only the count distinguishes them:

| Rule | Coverage | Accesses | Result over 0xA0, field ← 0x5 |
|------|----------|----------|-------------------------------|
| Preserve | partial | **2** (read + write) | 0xA5 |
| WriteAsOnes | partial | **1** (write only) | 0xF5 |
| WriteAsZeros | partial | **1** (write only) | 0x05 |
| Preserve | whole unit | **1** (write only) | 0x3C |

The last row matters on its own: a full-unit write under `Preserve` must
not read "because the rule is Preserve" when there are no bits to
preserve.

## PCI_Config

A PCI_Config OperationRegion carries no bus, device or function. Its
declared offset is an offset into the configuration space of the function
it is *declared inside*. **Getting this wrong is not a fault but silent
corruption**: the region addresses a real but different function, and
every bounds check downstream still passes while another device's BARs
and command register are rewritten.

So the rule is **refuse, never default**. `aml_region_pci_context` walks:

1. the nearest enclosing `Device` — stopping at the root rather than
   treating the root as a device;
2. that device's `_ADR`, which must be a **constant integer `Name`**. An
   `_ADR` written as a Method is *not* evaluated — running vendor AML at
   bind time, to resolve a binding that does not yet exist, is exactly
   the reentrancy a hostile table would aim for — and is refused;
3. `_ADR` well-formedness: 32 bits, device ≤ 31, function ≤ 7. An
   out-of-range `_ADR` is **refused, not masked**. Masking 0x00200003
   down to device 0 addresses a completely different function while
   looking entirely successful;
4. a **positively identified host bridge** above it, by `_HID` of
   PNP0A03 (0x030AD041) or PNP0A08 (0x080AD041).

Only *then* are `_BBN` and `_SEG` read, defaulting to bus 0 and segment 0
when absent. That default is ACPI-sanctioned **for a host bridge**, which
is why step 4 must succeed first: a device with an `_ADR` and no host
bridge in its ancestry is not "probably on bus 0", it is not a PCI device
or the table is malformed, and either way the answer is
`AML_ERR_REGION_PCI_CONTEXT` (66). A present-but-out-of-range `_BBN` or
`_SEG` is refused, not truncated. A `_HID` written as a string rather
than an EisaId integer is not matched, and therefore refuses — the string
form is legal ACPI, but reading it needs the AML buffer, which is
confined to `aml_lex.o`, and guessing that an unreadable `_HID` is
probably a host bridge is the defaulting this issue forbids.

The resolved context is packed into row word 1 above the space —
`VALID` at bit 40, segment [31:16], bus [15:8], device [7:3], function
[2:0] — and exposed by `aml_region_pci_ctx`, so **which** function a
region resolved to is observable. The `VALID` bit exists because
0000:00:00.0 is a real function, typically the host bridge itself: without
it, the exact failure this issue prevents would be spelled `0`. Adding
the context to word 1 is also why `aml_region_space` now masks; a missing
mask is its own mutant, and it is killed.

**R22 reuse.** This module never learns an ECAM base and cannot construct
one. It resolves `{seg, bus, dev, func}`; the supervisor asks the kernel
for an OpRegion capability over that function's configuration space; the
kernel's `src/kernel/core/pci/config.pdx` resolves the segment base
through `mcfg_ecam_base_for_segment` (R20-M3-001) and adds the same
`(bus << 20) | (dev << 15) | (func << 12)` R22 has always used. There is
no second ECAM path. `aml_region_pci_ecam_offset` mirrors the *offset*
arithmetic alone so the corpus can pin the two together; if R22's layout
ever changed, that assertion is what catches this copy drifting.

`AnyAcc` resolves to **32** for PCI_Config — dword is config space's
natural and universally safe unit — which is the row #1062 predicted this
table would need. Offsets are bounded by 4096 (extended) at bind.

## EmbeddedControl — gated on R31

The EC driver is R31 work and does not exist. This milestone lands the
handler contract, the address-space registration and the bind-time
validation, and gates the transaction — the shape iter 32 used for VT-d.

An EC region **binds** (so a malformed one is still reported where the
table is set up), validates its 256-byte extent, and admits **ByteAcc
only**: the EC protocol transfers exactly one byte per handshake, so a
`WordAcc` EC field is a table bug and must not silently become two
handshakes. Every transaction then returns `AML_ERR_REGION_EC_GATED`
(67), produces **no value**, and counts **no access**.

Nothing is simulated. A handler returning plausible bytes would make
thermal, battery and lid code appear to work while reading fiction — a
battery gauge reading 100% from a fabricated EC is worse than one
reporting an error, because nothing downstream can tell.

### What R31 must add

An EC access is not a load. Reading one byte is a handshake over two
ports (ACPI 6.5 §12.2): write `RD_EC` (0x80) to the command port, poll
until IBF clears, write the address to the data port, poll until OBF
sets, read the byte. A write is `WR_EC` (0x81) with an extra phase.
Concretely R31 owes:

1. A driver owning the two ports **taken from the EC device's `_CRS`**,
   not hardcoded to 0x62/0x66 — machines relocate them.
2. Serialisation. The EC has one outstanding transaction; interleaving
   two corrupts both.
3. Timeouts and recovery. A real EC takes milliseconds and can wedge.
   This is the reason the access cannot simply be inlined here: it needs
   to block and to fail, and the evaluator's fuel model has no notion of
   waiting.
4. `_GPE` query handling (`KIND_EC_QUERY`): the EC raises an SCI, the
   driver issues `QR_EC` (0x84), and the returned byte selects a `_Qxx`
   method — a **reentry** into the interpreter, which needs the
   serialisation story settled first.
5. A call to `aml_region_ec_backing_set`, which opens the gate, and
   wiring the transaction at the `amr_ru_ec` / `amr_wu_ec` labels.

### Where the flip-assertion lives

Two places, and both must be updated deliberately when R31 lands:

* **`tests/user/aml/aml_harness.c`**, in
  `test_region_ec_binds_but_does_not_transact`: `aml_region_ec_backing()
  == 0` and `aml_region_ec_hw_committed() == 0`. The committed counter is
  *not* cleared by `aml_region_reset`, so it is a whole-process claim —
  "this process has never performed an EC transaction" — rather than a
  per-session one.
* **`tools/verify-aml-parser.sh`**, the `EC gate closed` check: no object
  may relocate against `aml_region_ec_backing_set`. This is true today
  precisely because the driver does not exist, which makes "the gate is
  still closed" a *build-time fact* rather than a comment. It is the
  stronger of the two, because it holds over code no fixture reaches.

## Error codes — continuing §20

| Code | Name | Means |
|------|------|-------|
| 65 | `AML_ERR_REGION_PORT_RANGE` | a SystemIO region outside 0x0000–0xFFFF |
| 66 | `AML_ERR_REGION_PCI_CONTEXT` | the enclosing PCI device context could not be resolved — **never** substituted with a default |
| 67 | `AML_ERR_REGION_EC_GATED` | EC transaction unavailable until R31's driver registers a backing |

Reused rather than duplicated: `ACCESS_WIDTH` (60) for `QWordAcc` on a
port or on config space and for a non-byte EC access; `NOT_COVERED` (57)
for a PCI offset beyond 4096 or an EC offset beyond 256.

## Verification

`tools/verify-aml-parser.sh` gained three build-time assertions —
EC-gate-state confinement, port-I/O confinement with a vacuity guard, and
the closed-gate relocation check — and the corpus went from 3198 to 3199
assertions across ten new cases. All fixtures load against a `PROT_NONE`
guard page and the whole run is under the 60-second watchdog. The
`no-AML kernel guardrail` passes and `_op_region_table` confinement is
untouched.

## Mutation evidence

Thirteen mutants, **thirteen killed** — twelve on the first pass, one
after a fixture fix.

| Mutant | Killed by |
|--------|-----------|
| default to 00:00.0 when no host bridge is found | "no context is produced" (got `0x100000000fb`) |
| mask an out-of-range `_ADR` device instead of refusing | "device 32 does not exist" |
| mask an out-of-range `_ADR` function instead of refusing | "function 8 does not exist" |
| ignore `_BBN`, default the bus to 0 | "bus 0x20" and the ECAM-offset cross-check |
| `WriteAsOnes` reads the unit first | "EXACTLY ONE ACCESS — NO READ" |
| `WriteAsZeros` reads the unit first | "EXACTLY ONE ACCESS — NO READ" |
| admit `QWordAcc` for SystemIO and split it | "QWordAcc has NO port form" |
| port bound off by one (0x10001) | "one byte past the end of port space" |
| `AnyAcc` resolves to a byte for PCI_Config | "AnyAcc is a DWORD for config space" |
| service an EC region as memory instead of gating | "an EC read produces NOTHING" (returned 0xA5) |
| fail to mask the packed context out of the space | "bound as PCI_Config" (got `0xfb02`) |
| admit `WordAcc` for the EC | "WordAcc is refused for the EC" |
| apply window arithmetic to the real-port sentinel | "host_base is the sentinel, not an address" — *after a fixture fix* |

The last one **initially survived**, and again the defect was in the
fixture rather than the code: the real-port binding used a window whose
base equalled the region's declared base, so the window offset was zero
and `1 + 0 == 1` made the mutation equivalent. Setting the window to
0x50 while the region sits at 0x60 gives an offset of 0x10 and makes the
mutant produce `0x11`; it then dies twice over, once on the sentinel
comparison and once on the SIGSEGV from dereferencing 0x11.

That is the third time in this subsystem that mutation testing found a
fixture measuring the wrong thing rather than an implementation bug, and
the shape is now familiar enough to name: *a test whose inputs make the
mutated arithmetic an identity is not testing that arithmetic.* Choosing
fixture constants that differ from the values a broken implementation
would invent — a non-zero `_BBN`, a non-zero `_SEG`, a window base below
the region base — is what turns these into real tests, and it is why
those constants are what they are.
