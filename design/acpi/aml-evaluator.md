# AML evaluator — context, budgets, frames, namespace walk, operators, objects

**Round.** R30 — ACPICA userspace bubble + LPSS bus enablement
**Issues.** #1054 (namespace walker + call frames) · #1055 (arithmetic and
logical operators) · #1056 (string/buffer operators + §19.3.5 conversion) ·
#1057 (package/reference/Index semantics)
**Status.** Landed. #1058 (invocation + argument promotion), #1059 (Notify),
#1060 (recursive/serialized methods) follow.
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
