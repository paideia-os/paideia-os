# AML tokenizer and namespace parser

**Round.** R30 — ACPICA userspace bubble + LPSS bus enablement
**Issues.** #1049 (tokenizer) · #1050 (namespace objects) · #1051 (control
flow) · #1052 (data objects) · #1053 (resource templates)
**Status.** Landed — R30.M1 complete. R30.M2 (#1054+) adds the evaluator.

---

## 1. Placement — this is constitutional, not stylistic

Every file described here lives under `src/user/aml/`. None of it may ever
appear under `src/kernel/**`.

Pillar 3 (userspace-first) forbids AML — an interpreted, firmware-supplied
bytecode with a Turing-complete evaluator — from executing in ring 0. The
boundary is enforced mechanically by two independent checks in the pre-push
matrix:

| Check | Polices |
|---|---|
| `tools/lint-no-kernel-aml.sh` (#822) | AML *identifiers* anywhere under `src/kernel/**` |
| `tools/verify-aml-parser.sh` §1 (#1049) | AML *files* under `src/kernel/**` |

The rationale is in [`no-aml-in-kernel.md`](no-aml-in-kernel.md). The
practical consequence for a future contributor: if you find yourself
fighting the guardrail, the code is in the wrong place. Move the code.
Never weaken the lint.

The eventual consumer is the `acpi_supervisor` process
(`src/user/acpi_supervisor.pdx`, #820), which will link `build/user/libaml.a`
when the userspace ACPI bubble wires up in R30.M2+. Until then the archive is
built on every push so the cross-module symbol graph stays resolved.

---

## 2. Module layout

| File | Role | Issue |
|---|---|---|
| `src/user/aml/aml_lex.pdx` | cursor + §20.2 primitive decoders | #1049 |
| `src/user/aml/aml_optab.pdx` | sorted opcode descriptor table + binary search | #1049 |
| `src/user/aml/aml_arena.pdx` | flat index-addressed AST arena | #1050 |
| `src/user/aml/aml_ns.pdx` | namespace-object recursive-descent parser | #1050 |
| `src/user/aml/aml_term.pdx` | control flow, expressions, data objects, method invocation | #1051 / #1052 |
| `src/user/aml/aml_resource.pdx` | resource-descriptor mini-language | #1053 |
| `tests/user/aml/aml_harness.c` | executable byte-fixture corpus | all |
| `tools/verify-aml-parser.sh` | build-time verification, wired into pre-push | all |

`aml_term.pdx` and `aml_resource.pdx` declare **no private storage at
all** — everything they touch is reached through the lexer and arena
accessor APIs. Adding them to the script's `MODULES` list therefore
required no new assertion and made the three existing ones strictly
stronger: they now also prove the term parser and the resource decoder
cannot reach the cursor, the arenas or the opcode table directly (§7).

Each module owns its storage privately, and that ownership is **mechanically
enforced** (§7).

---

## 3. Opcode-table strategy

AML has roughly 120 opcodes. This milestone parses about fifteen of them.
#1051 adds control flow, #1052 adds data objects, R30.M2 adds the evaluator.

If dispatch were a chain of compares, each of those issues would edit
**control flow** inside a hot recursive function, and each edit would be an
opportunity to mis-order a branch or drop a case. Instead there is one sorted
array of packed `u64` descriptors and one binary search. **Adding an opcode
is adding a row.**

### Entry encoding

| Bits | Field | Meaning |
|---|---|---|
| `[15:0]` | `op16` | normalised opcode: `0x00NN` single-byte, `0x5BNN` for an `ExtOpPrefix` escape |
| `[23:16]` | `class` | 1 NAMESPACE, 2 DATA, 3 CONTROL, 4 EXPR, 5 ARG, 6 LOCAL, 7 MISC, 8 NAMELEAD |
| `[31:24]` | `flags` | see below |
| `[39:32]` | `argc` | fixed operand count |
| `[47:40]` | `node` | `AML_NODE_*` to allocate, 0 for none |
| `[55:48]` | `shape` | operand shape (#1051) — see below |
| `[63:56]` | — | reserved, zero |

`class` is never 0, so a real entry can never pack to zero, which makes 0 a
safe "not found" return from `aml_optab_find`.

### Flags

| Bit | Name | Meaning |
|---|---|---|
| `0x01` | `F_PKGLEN` | a PkgLength follows the opcode |
| `0x02` | `F_NAMESTR` | a NameString follows |
| `0x04` | `F_FLAGBYTE` | a flags `ByteData` follows the name |
| `0x08` | `F_TERMLIST` | the package body is a TermList |
| `0x10` | `F_FIELDLIST` | the package body is a FieldList |
| `0x20` | `F_EXTOP` | opcode is a `0x5B` escape |
| `0x40` | `F_M1_HANDLED` | parsed by the R30.M1 parser |
| `0x80` | `F_OPAQUE_OK` | safe to skip wholesale via its PkgLength |

### Operand shape — the `[55:48]` field (#1051)

Sixty of the sixty-six expression opcodes are "`argc` TermArgs, in order"
and need nothing more. The other six interleave a raw `ByteData`,
`WordData`, `DWordData` or `NameString` among their TermArgs at a fixed
position:

| Shape | Name | Operand sequence |
|---|---|---|
| 0 | `REGULAR` | `argc` TermArgs |
| 1 | `NAME_LAST` | `argc-1` TermArgs then a NameString — the `Create*Field` family, whose trailing operand *declares* a name |
| 2 | `MATCH` | TermArg, ByteData, TermArg, ByteData, TermArg, TermArg |
| 3 | `ACQUIRE` | TermArg then a `WordData` timeout |
| 4 | `FATAL` | ByteData, DWordData, TermArg |
| 5 | `NAME_FIRST` | NameString then `argc-1` TermArgs — `Load`, whose first operand names a table |

Reading one of those scalars as a TermArg consumes the wrong number of
bytes and desynchronises the enclosing TermList **silently**. Encoding the
irregularity as *data* keeps `aml_term_expr` a single loop and puts the
six exceptions somewhere `aml_optab_selfcheck` can police them (shape ≤ 5,
and non-zero only on class 4). The alternative — six special cases inside
the operand loop — is six chances to write that bug.

### What #1051/#1052 cost the table

Bringing in every DATA, CONTROL, EXPR, ARG, LOCAL and MISC opcode was a
**regeneration of the rows** plus one new packed field. `aml_optab_find`,
`aml_optab_selfcheck` and the parser's dispatch structure were untouched.
That is the property the table was bought for.

### Why the table is complete, not just sufficient

The table carries **all** single-byte and `0x5B`-escape opcodes as of ACPI
6.5, including the hundred this milestone does not parse. That completeness is
what lets two rejection codes mean genuinely different things:

- `AML_ERR_UNKNOWN_OPCODE` — the byte is not an AML opcode at all. The table
  has been consulted; the stream is corrupt or the parser has lost
  synchronisation.
- `AML_ERR_UNEXPECTED_OP` — the byte **is** a valid opcode, but this
  milestone does not parse it.

Collapsing those would make a genuinely corrupt table indistinguishable from
an unimplemented feature — precisely the distinction an operator needs when a
machine will not boot.

### `F_OPAQUE_OK` is the safety hinge

An unparsed construct is handled one of exactly two ways:

- **Carries a PkgLength** → its extent is self-describing and has already been
  bounds-checked against the buffer. Record an `AML_NODE_OPAQUE` covering it
  and skip. Sound.
- **No PkgLength** → its extent is knowable only by decoding its operands.
  Guessing a skip distance would resynchronise the parser mid-instruction and
  produce a namespace that looks plausible and is wrong. A wrong namespace is
  worse than no namespace: it silently mis-drives hardware. **Refused.**

Six opcodes carried `F_OPAQUE_OK` before #1051/#1052: `Buffer`, `Package`,
`VarPackage`, `If`, `Else`, `While`. All six are now really parsed, and
they were the only PkgLength-bearing opcodes ACPI 6.5 defines — so **no row
carries `F_OPAQUE_OK` any more** and the skip branch is unreachable.

It is kept anyway. It is the only sound way to admit a future
PkgLength-bearing opcode without implementing it, and re-deriving it under
time pressure is exactly how a guessed skip distance gets written. To stop
it rotting untested, the corpus asserts the bearer count is **zero**: a
later issue that adds one fails that assertion and is forced to put the
branch back under test. (This also vindicated the prediction above — the
change really was rows plus handlers, with the skip logic untouched.)

### Self-check

`aml_optab_selfcheck()` walks the table asserting the invariants that the
binary search and the parser depend on:

1. `op16` strictly ascending — one out-of-order row makes lookups *silently
   miss*, the worst failure mode for a table three later issues will edit.
2. `class` in `1..8`.
3. `F_TERMLIST` ⇒ `F_PKGLEN` (a TermList body has no other way to end).
4. `F_FIELDLIST` ⇒ `F_PKGLEN | F_FLAGBYTE`, matching §20.2.5.2.
5. `op16 > 0xFF` ⇒ `F_EXTOP` and a `0x5B` high byte.

The corpus runs it before every fixture and independently re-checks the
ordering from C, so a malformed row fails the push rather than corrupting a
parse.

---

## 4. Arena representation

### Why indices, not pointers

The `acpi_supervisor` process parses AML on one side of an IPC boundary and
serves namespace queries to clients on the other. **A pointer-linked tree
cannot cross that boundary** — the receiver maps the payload at a different
virtual address, so every pointer in it is garbage. Three properties follow:

1. **No pointers anywhere.** Every inter-record reference is a small integer
   index into a named array. A record is meaningful wherever the array is
   mapped.
2. **Fixed-stride records.** A node is exactly 32 bytes. Index `i` lives at
   `base + i*32`, always — no allocator, no relocation pass, no schema
   negotiation for a consumer to walk it.
3. **The arrays are the wire format.** Handing over the namespace is a memcpy
   of three contiguous arrays plus three counts. There is no serialise step
   to get wrong.

Index 0 is the reserved null sentinel in all three arenas; allocation starts
at 1, so `0` unambiguously means *absent* — no child, no sibling, no name —
without a separate presence bit.

### Node record — 4 × u64, 32 bytes

| Word | Bits | Field |
|---|---|---|
| 0 | `[15:0]` | `kind` — `AML_NODE_*` |
| 0 | `[31:16]` | `flags` — kind-specific semantic flags |
| 0 | `[63:32]` | `name_ref` — index into the name arena (0 = unnamed) |
| 1 | `[31:0]` | `first_child` |
| 1 | `[63:32]` | `next_sibling` |
| 2 | `[31:0]` | `parent` |
| 2 | `[63:32]` | `src_off` — byte offset of this node's **opcode** |
| 3 | `[31:0]` | `arg0` — kind-specific |
| 3 | `[63:32]` | `arg1` — kind-specific |

`src_off` is what keeps the record narrow. Fixed scalar operands that do not
drive structure — Processor's `PblkAddr`, PowerResource's `ResourceOrder`, a
Buffer's initialiser bytes — are **not** copied into the node; they stay
recoverable from the source buffer. Anything that *does* drive semantics — a
Method's flags byte, a Field's access rules, a field element's bit offset and
width — **is** stored, because a consumer must not have to re-parse to act
correctly.

### Extra data becomes extra nodes, never wider records

When a construct carries more than the record holds, the answer is another
node. `IndexField` and `BankField` each name two objects; the second name
becomes an `AML_NODE_FIELD_LINK` child. This keeps the stride fixed and keeps
#1051/#1052 from being tempted to grow `word3` into a union.

### Node kinds

| # | Kind | `arg0` / `arg1` / `flags` |
|---|---|---|
| 1 | `ROOT` | `arg1` = buffer length |
| 2 | `SCOPE` | `arg0` = TermList start, `arg1` = package end |
| 3 | `DEVICE` | as SCOPE |
| 4 | `METHOD` | `flags` = MethodFlags; `arg0`/`arg1` = body extent |
| 5 | `NAME` | `flags` = data kind (1 int, 2 string, 3 buffer, 4 package, 5 var-package) |
| 6 | `ALIAS` | `name_ref` = alias name; `arg0` = source `name_ref` |
| 7 | `PROCESSOR` | `flags` = ProcID |
| 8 | `POWERRES` | `flags` = SystemLevel |
| 9 | `THERMALZONE` | as SCOPE |
| 10 | `OPREGION` | `flags` = RegionSpace; `arg0`/`arg1` = u64-arena indices of offset/length |
| 11 | `FIELD` | `flags` = FieldFlags; `arg0`/`arg1` = FieldList extent |
| 12 | `INDEXFIELD` | as FIELD; first child is a `FIELD_LINK` naming the data object |
| 13 | `BANKFIELD` | as FIELD; first child is a `FIELD_LINK` whose `arg0` is the u64-arena index of BankValue |
| 14 | `FIELD_ELEM` | `flags[7:0]` = effective field flags, `flags[15:8]` = access attribute; `arg0` = bit offset, `arg1` = bit width |
| 15 | `EXTERNAL` | `flags[7:0]` = ObjectType, `flags[15:8]` = ArgumentCount |
| 16 | `OPAQUE` | `arg0`/`arg1` = package extent; the opcode is at `src_off` |
| 17 | `MUTEX` | `flags` = SyncFlags |
| 18 | `EVENT` | — |
| 19 | `FIELD_LINK` | second NameString of INDEXFIELD / BANKFIELD |
| 20 | `FIELD_ACCESS` | `flags` as FIELD_ELEM; `arg0` = AccessLength (0 for the short form) |
| 21 | `FIELD_RESERVED` | `arg0` = bit offset, `arg1` = bit width |
| 22 | `FIELD_CONNECT` | `name_ref` (NameString form) or `arg0`/`arg1` (BufferData form) |

### Name arena

A `u32` array. Entry `ref` is a header word followed by `SegCount` NameSeg
words:

```
[ref]           [7:0] SegCount, [15:8] '^' count, [16] '\' root flag
[ref+1 .. +Seg] NameSeg — four ASCII chars packed LE, first char in [7:0]
```

NameSegs use ACPICA's packed order, so comparing against a literal such as
`_HID` is one integer compare rather than a string walk.

### u64 side table

OpRegion offsets and lengths, Name integer values and BankField bank values
are genuinely 64-bit and will not fit a 32-bit argument slot. They go in a
side table and nodes reference them **by index**, preserving property 1.

### Capacities

512 nodes / 512 name words / 128 u64 slots — R30.M1 fixture scale, not
shipping scale. A full DSDT needs roughly two orders of magnitude more, which
is a `.bss` sizing change and nothing else. Exhaustion is a **clean latched
error**, never a wrap and never an overwrite; the corpus proves this with
fixtures that deliberately exhaust each of the three arenas.

### Build-time side table

`aml_node_last` holds, per node, the index of its most recently appended
child, so appending is O(1) rather than a sibling-chain walk. It is **not**
part of the exported representation and is **not** transferred over IPC — the
sibling chain in `word1` is authoritative.

---

## 5. Error taxonomy

Codes are latched in one sticky slot with the *first writer winning*, so
`err` and `err_off` continue to localise the original fault rather than the
cascade of a caller that did not check.

| # | Name | Meaning |
|---|---|---|
| 0 | `AML_OK` | — |
| 1 | `AML_ERR_EOF` | read past the end of the buffer |
| 2 | `AML_ERR_PKGLEN_TRUNC` | PkgLeadByte promises ByteData that are absent |
| 3 | `AML_ERR_PKGLEN_OVERFLOW` | decoded package runs past the buffer end |
| 4 | `AML_ERR_PKGLEN_TOO_SMALL` | package shorter than its own length field |
| 5 | `AML_ERR_UNKNOWN_OPCODE` | byte is not an AML opcode |
| 6 | `AML_ERR_BAD_NAMECHAR` | NameSeg character outside the legal set |
| 7 | `AML_ERR_BAD_SEGCOUNT` | MultiNamePath `SegCount == 0` |
| 8 | `AML_ERR_NAME_ARENA_FULL` | name arena exhausted |
| 9 | `AML_ERR_NODE_ARENA_FULL` | node arena exhausted |
| 10 | `AML_ERR_UNEXPECTED_OP` | real opcode, not handled at this milestone |
| 11 | `AML_ERR_PKG_OVERRUN` | child consumed past its enclosing package end |
| 12 | `AML_ERR_DEPTH` | nesting deeper than `AML_MAX_DEPTH` (64) |
| 13 | `AML_ERR_BAD_FIELD_ELEM` | FieldList element opcode unrecognised |
| 14 | `AML_ERR_NO_PROGRESS` | term loop consumed zero bytes |
| 15 | `AML_ERR_BAD_INTEGER` | expected an integer literal, found something else |
| 16 | `AML_ERR_U64_ARENA_FULL` | u64 side table exhausted |
| 17 | `AML_ERR_FIELD_OFFSET_OVF` | running field bit offset exceeded 2³²−1 |
| 18 | `AML_ERR_METHOD_INVOCATION` | bare NameString in term position (#1051) |
| 19 | `AML_ERR_NOT_INITIALISED` | API used before `aml_lex_init` |

Every code except 14 and 18 is exercised by a corpus fixture. Code 14
(`NO_PROGRESS`) remains **unreachable by construction** — every handler
consumes at minimum the opcode byte itself — and is retained as a
structural guard; #1052's package-element loop carries it for exactly the
same reason. Code 18 is retired, above. Both are documented as untested
rather than given contrived tests.

---

## 6. PkgLength — ACPI 6.5 §20.2.4

The single most error-prone part of AML.

```
PkgLength := PkgLeadByte
           | PkgLeadByte ByteData
           | PkgLeadByte ByteData ByteData
           | PkgLeadByte ByteData ByteData ByteData
```

`PkgLeadByte[7:6]` is the count `n` of trailing `ByteData` (0..3). When
`n == 0`, `[5:0]` **are** the length. Otherwise `[3:0]` are the **low four
bits** and each trailing byte supplies the next 8 bits, little-endian:

| `n` | Value | Max | Encoded size |
|---|---|---|---|
| 0 | `lead & 0x3F` | 63 | 1 |
| 1 | `(lead & 0x0F) \| b1<<4` | 0xFFF | 2 |
| 2 | `… \| b2<<12` | 0xFFFFF | 3 |
| 3 | `… \| b3<<20` | 0xFFFFFFF | 4 |

**The decoded length includes the PkgLength bytes themselves.**

### Two entry points, because the encoding has two meanings

`aml_lex_pkglength()` — **package semantics.** Decode, then reject:
- `len <` its own encoded size → `PKGLEN_TOO_SMALL`. Self-contradictory;
  accepting it would let a 1-byte `0x00` declare a zero-length region that the
  term loop would spin on.
- `pkg_start + len >` buffer length → `PKGLEN_OVERFLOW`. This is the check
  that stops a firmware-supplied length from steering the parser off the end.

`aml_lex_pkglength_value()` — **raw-integer semantics.** §20.2.5.2 reuses the
same encoding for FieldList element **bit widths**, which bear no relation to
the byte buffer. Applying the package bounds check there would reject
perfectly legal firmware the moment a declared field width exceeded the bytes
remaining. *Getting this wrong is the most common way an AML parser fails on
real tables.*

### Testing the boundaries without a 256 MB fixture

Both entry points record the decoded value in `aml_lex_state[last_pkglen]`
**before** the package bounds checks run. The corpus therefore asserts the
decoded arithmetic at all four length maxima — including `0xFFFFF` and
`0xFFFFFFF`, which no reasonable fixture could satisfy — *and* asserts that
the overflow check rejected them, from the same fixture.

---

## 6a. Method invocation — the hardest problem in the format

In AML a bare NameString in term position **may be a method call, and the
number of TermArgs that follow it is not in the byte stream.** It comes
from bits `[2:0]` of the `MethodFlags` byte of the corresponding `Method`
declaration, which may appear *later* in the same table or in a different
table entirely.

Getting the count wrong does not produce a parse error. It produces a
parse that **succeeds and is wrong**: read one argument too few and the
next one is re-interpreted as a statement; read one too many and a
following statement is swallowed as an argument. Everything downstream is
then plausible and incorrect. **The count is never guessed.**

### The strategy: two passes

`aml_parse` runs the buffer twice — the same shape ACPICA uses, for the
same reason.

| | What it does | Why it can |
|---|---|---|
| **Pass A** — declaration | `aml_parse_termlist(root, len, 0)`. Descends only name-defining constructs. Method bodies and If/Else/While packages are recorded as **byte extents** in `arg0`/`arg1` and not entered. | It never needs an arity to walk past a body, because every body is delimited by a PkgLength. |
| **Pass B** — body | `aml_term_bodies()` sweeps the **arena, not the buffer**, and parses the body of every `METHOD` / `IF` / `ELSE` / `WHILE` from its recorded extent. | When it starts, *every* `Method` declaration in the table is already in the arena. |

A forward reference — a method calling one defined later in the same
table, which ASL permits and real DSDTs contain — therefore resolves
correctly. Nothing is parsed twice: pass A allocates the body-bearing
node, pass B allocates only its children, and flags bit 15 marks the node
done so the sweep is idempotent. The high-water mark is sampled once
before the sweep, so nested control flow found *during* pass B (parsed
inline, since arities are all known by then) is never revisited — there is
no third pass and no fixed-point loop.

### Where the arity comes from

`aml_term_lookup` searches, in order:

1. **Interpreter built-ins.** `_OSI` is a one-argument method the
   interpreter supplies and no table declares; `_OS_`, `_REV` and `_GL_`
   are interpreter *objects*. Omitting these would make essentially every
   shipping DSDT unparseable.
2. **A `Method` node** in the arena — arity from `MethodFlags[2:0]`.
3. **An `External` node** declaring ObjectType 8 (`MethodObj`) — arity
   from its `ArgumentCount` byte. This is precisely the mechanism ACPI
   defines for naming an object another table owns, and it is what makes
   the cross-table case *resolvable* rather than guessed.
4. **Any other declaration** of the name — it is an object, not a method,
   so the NameString is a reference and consumes no further bytes.

Matching is on the **final NameSeg**, not the full path: full scope
resolution needs the evaluator's namespace walk (R30.M2), and arity is a
property of the method rather than of the path used to reach it. The
approximation is made *safe* rather than merely convenient — if two
declarations share a final NameSeg and disagree on arity, the parse is
refused with `AML_ERR_AMBIGUOUS_CALL` instead of picking one. Two
same-named methods with different arities are the only input this
approximation could mis-parse, and that input is rejected.

### When it cannot be resolved

A NameString matching nothing at all is refused with
`AML_ERR_UNRESOLVED_CALL`. It is tempting to assume "not a method,
therefore a plain reference" — but that is exactly the mis-parse above:
`Store(FOO(1), Local0)` and `Store(FOO, One)` differ only in whether `FOO`
takes an argument. ACPI *requires* an `External` declaration for any
object a table references but does not own, so refusing is
spec-conformant, and the operator gets a precise code and offset instead
of a wrong namespace.

Two related rules fall out of the same reasoning:

- **Inside a `Package`, a bare NameString is always a reference**, never
  an invocation — §20.2.5.4 admits only data there. Routing package
  elements through the TermArg path would submit every element name to
  arity resolution and could refuse a perfectly legal `_PRT`-shaped
  package of device paths.
- **A `Return` with no operand** is accepted when the cursor is already at
  the enclosing body's end, recorded as an implicit `Zero` via `flags`
  bit 0. The grammar requires an `ArgObject` and iasl always emits one,
  but some shipping firmware does not; parsing the following byte as the
  operand would consume a byte belonging to the enclosing package. This
  is a bounded, *explicitly flagged* concession — a consumer can see
  exactly which Returns were fixed up.

### Known limit, stated rather than papered over

A `Method` declared **inside** an If/While body is invisible to pass A,
which does not enter those bodies. A call to it from a body swept earlier
in pass B is unresolvable and is refused. Descending control flow in pass
A would reintroduce the very circularity the two passes exist to break,
since a control-flow body is arbitrary terms. Conditional method
definitions are rare and are normally called from within the same block,
which pass B parses in order and therefore resolves. **This is a refusal,
never a mis-parse.**

### Complexity

`aml_term_lookup` is a linear scan of the node arena, so resolution is
O(nodes × calls). At 512-node fixture scale that is nothing. When the
arena is grown for a real DSDT (§4) it becomes the first thing to
replace, with a sorted final-NameSeg index built at the end of pass A.
Noted here so the growth and the index land together.

---

## 6b. Resource templates — eager or lazy, and the discriminator

A resource template is a `Buffer` whose *contents* happen to be a list of
resource descriptors — what `_CRS`, `_PRS` and `_SRS` return, and the only
way a driver learns its interrupt, its MMIO window or its I²C address.

**Nothing in the byte stream marks such a buffer.** `Buffer` is `Buffer`.
The distinction is contextual: it comes from the name of the object the
buffer is the value of.

### The choice: lazy

Parsing eagerly at Buffer-parse time means reinterpreting **every** buffer
in the table as a resource list. Ordinary data buffers are common —
firmware blobs, UUIDs, EC scratch — and their first byte will sometimes
land on a plausible small-descriptor tag. Two bad outcomes follow: a data
buffer acquires a fictitious resource tree a consumer may act on, or a
legal data buffer fails resource validation and the whole *table* is
refused. Both are worse than what eager parsing buys, which is nothing —
no consumer needs the resource view until it asks.

So `aml_res_parse(buffer_node)` is called by a consumer that already
knows, from context, that this buffer is a template.

### The discriminator: whole-buffer validation, not a sniff

Context alone is not enough, because the caller's context can be wrong and
the bytes are still firmware-supplied. `aml_res_is_template` answers
structurally, over the **whole buffer**:

> every descriptor from the first byte onward has a tag the specification
> defines and an in-bounds length; the walk arrives **exactly** at an
> EndTag; the EndTag is the last thing in the buffer; and its checksum
> byte is either `0` (§6.4.2.9 "not computed", which iasl emits) or makes
> the sum of every byte in the template zero modulo 256.

A first-byte sniff would accept any buffer beginning `0x22`. This accepts
only a complete, self-consistent, exactly-fitting descriptor list. The
corpus makes the point with a data buffer that *does* begin `0x22` and is
still correctly refused — three bytes in, `0xBE` turns out to be a
reserved large item name.

`aml_res_is_template` **latches nothing**: "not a template" is not a
fault, and a speculative question must not poison a parse that is
otherwise fine. `aml_res_parse` runs the same validation as its first
phase and latches the specific reason, which is the only difference
between the two entry points — a caller who *asserts* the buffer is a
template wants to know why it is not.

### Two phases, so a partial tree cannot exist

Validation runs to completion before a single node is allocated. That is
why `aml_res_build` carries no structural error handling: by the time it
runs, every tag and length has been proven. Duplicating the checks there
would mean two implementations of the same arithmetic that could disagree,
and the failure mode would be a tree describing something the validator
never saw.

### What is decoded

Small items IRQ, DMA, IO, FixedIO, FixedDMA, StartDependent,
EndDependent, VendorShort and EndTag; large items Memory24,
GenericRegister, VendorLong, Memory32, Memory32Fixed, DWord/Word/QWord
address space, ExtendedIRQ, ExtendedSpace, GpioConnection, PinFunction,
GenericSerialBus and the PinGroup family. Reserved names are **refused**,
not skipped by their length — a reserved tag in a buffer a caller believes
is a template is evidence the caller is wrong about the buffer.

Payload bytes are **not copied**: `arg0`/`arg1` delimit each descriptor in
the AML buffer and the accessors read it there, so a `_CRS` with forty
descriptors costs forty 32-byte nodes rather than a copy of the buffer.
Fixed-offset fields are read with `aml_res_u8/u16/u32/u64` at offsets
tabulated in the module header. The three families whose field positions
are *computed* get real accessors, because that arithmetic is where the
bugs are:

- **Address spaces** — `aml_res_space_width/min/max/len`. Minimum is at
  payload `3 + W`, Maximum at `3 + 2W`, Length at `3 + 4W`, where `W` is
  2, 4 or 8 by item name.
- **GPIO** — `aml_res_gpio_pin_count/pin`. `PinTableOffset` is measured
  from the *descriptor's first byte* while the readers index from the
  payload, so the three-byte header is subtracted once, here.
- **Serial bus** — `aml_res_serial_type/i2c_speed/i2c_addr`. The
  type-specific data has a different layout per bus, so the type must be
  tested first; reading an SPI descriptor as I²C yields a valid-looking
  address for a device that is not there.

`aml_res_read` bounds every field against **the descriptor's own extent**,
not merely the buffer. Reading past a descriptor into its neighbour is the
characteristic bug of a hand-written resource decoder, and it produces
plausible garbage rather than a fault.

---

## 7. Security invariants

ACPI tables are firmware-supplied and therefore untrusted. Two properties
hold unconditionally:

**(I1) Single read path.** Every read of the AML buffer goes through
`aml_lex_u8` or `aml_lex_peek_u8`. Both compare `pos` against `len` **before
forming an address**. No other function in the subsystem dereferences the
buffer pointer.

**(I2) The error flag is read-blocking.** Once `err` is non-zero, both readers
return 0 *without touching the buffer*. A caller that ignores an error
therefore cannot be walked off the end by subsequent reads — the worst case is
a tree built from zeroes, never an out-of-bounds access.

### How (I1) stays true

The buffer pointer lives in `aml_lex_state`. `tools/verify-aml-parser.sh`
asserts with `objdump -r` that **`aml_lex_state` is relocated against only
from `aml_lex.o`** — every other module must go through the accessor API. A
future issue that "just peeks" at the state from the parser would quietly void
the invariant; the check fails the push instead. The same treatment confines
the arena arrays to `aml_arena.o` and `aml_optab` to `aml_optab.o`.

The check also refuses to pass vacuously: if the *owning* object has no
relocation against its own symbol (renamed, or the module gutted), that is a
failure too.

### Termination

Three guards make the recursive descent unable to spin or blow the stack:

- **Depth** — `aml_lex_depth_enter` / `_leave`, budget 64, checked *before*
  the increment so the counter stays balanced on failure paths. The corpus
  asserts `depth == 0` after every fixture, accepted and rejected alike.
- **Progress** — every term iteration must advance the cursor
  (`NO_PROGRESS`).
- **Containment** — no iteration may end past its enclosing package end
  (`PKG_OVERRUN`).

---

## 8. Verification

`tools/verify-aml-parser.sh`, wired into the pre-push matrix as the
`aml-parser` step alongside `elaborator-negatives`.

### Why build-time and not a boot witness

At R30.M1 **no runtime path hands this code a DSDT** — the `acpi_supervisor`
process does not yet receive one and the `KIND_ACPI` mapping is not exposed to
ring 3. A QEMU witness could therefore assert only that the objects link,
which the ordinary build already proves. What is worth asserting is
*behaviour*.

The tokenizer and parser are pure computation over a byte buffer: no syscalls,
no MMIO, no capabilities. paideia-as emits SysV-ABI ELF64 objects, so **the
same machine code that will run in the `acpi_supervisor` process** links
directly against a native C harness and runs against a real corpus. That is
strictly more evidence than a dormant boot path, so no runtime witness was
invented for it. This mirrors the posture of
`tools/verify-elaborator-negatives.sh`.

### The guard page

AML is a binary format, so hand-authored byte fixtures are the only honest
test. Every fixture — well-formed and malformed alike — is copied so its
**last byte is the last byte of a mapped page, with the next page
`PROT_NONE`**. A read one byte past the end is a hard `SIGSEGV`, caught and
reported as a failure naming the fixture.

This is what makes the malformed corpus meaningful: it is not enough that a
bad table is rejected with the right code — it must be rejected *without
having read outside the buffer on the way there*.

The harness proves the trap is armed before trusting anything it claims
(`self-check: guard page traps a one-byte over-read`); otherwise every
out-of-bounds assertion would be vacuous.

### Mutation testing

A malformed-input check that is never exercised is decoration. Every
structural check added by #1051/#1052/#1053 was neutralised in turn (by
rewriting its comparison so the branch can never be taken) and the corpus
re-run. **All twelve mutants were killed:**

| Mutation | Killed by |
|---|---|
| If/While containment against the enclosing TermList | `If overruns the enclosing TermList` — `err_off` and node count |
| Package element-count check | `more package elements than declared` |
| Buffer literal-size check | `Buffer size exceeds its extent` |
| Unresolved call treated as a plain reference | `unresolvable invocation` |
| Ambiguous arity resolved by taking the first | `ambiguous method arity` |
| Else/If sibling-kind pairing | `Else after a non-If sibling` |
| EndTag checksum | `resource: bad EndTag checksum` |
| Large-descriptor length overrun | `resource: large length overruns` |
| Per-descriptor bound in `aml_res_read` | `read past the descriptor` |
| EndTag-must-be-last | `resource: trailing bytes after EndTag` |
| Two opcode-table rows transposed | five ordering / lookup failures |
| Two passes collapsed into one | twelve failures, led by `parse forward method invocation` |

Two of those initially **survived**, and both were corpus gaps rather than
code gaps — worth recording because they are the failure mode this
technique exists to find:

- *If containment.* The fixture asserted only the error **code**, and the
  enclosing TermList loop reports the same `PKG_OVERRUN` once the cursor
  has walked out of its parent. The check's real contribution is *when* it
  fires, so the fixture now asserts `err_off` (immediately after the lying
  PkgLength, not at the far end of the damage) and the node count (nothing
  from inside the bogus If was ever allocated).
- *Else/If pairing.* The only fixture had an `Else` with **no** preceding
  sibling, which the null test catches before the kind test is ever
  reached. A second fixture — an `Else` after a `Noop` — exercises the
  kind test.

### Corpus contents (1073 assertions)

**Tokenizer.** All four PkgLength forms at both ends of each range
(1-byte 0/5/63; 2-byte 64/65/0xFFF; 3-byte 0x1000/0xFFFFF;
4-byte 0x100000/0xFFFFFFF); package-semantics acceptance, `TOO_SMALL` in both
the 1- and 2-byte forms, `OVERFLOW`, `TRUNC` in the 2- and 4-byte forms, and
EOF with no lead byte. All NameString forms — NullName, single NameSeg, root
prefix, `^^` prefix, root-then-NullName, DualNamePath, MultiNamePath,
root+MultiNamePath. All integer prefixes including OnesOp. Single-byte and
`ExtOp` opcode decode plus a bare `0x5B` at end of stream. Full opcode-table
round trip: every row findable, ordering re-checked from C, three miss
probes, descriptor spot-checks, and name-lead classification.

**Namespace parser.** Minimal `Scope(\_SB_){}`; `Device(PCI0)` with a `_HID`
of `0x030AD041`; `Method` with 3 args and the serialized bit; `Method` with a
sync level and a body that is recorded but not descended; `OperationRegion` +
`Field` with mixed offsets, a named field, a reserved gap, an `AccessAs`
change and inheritance of the new access byte; `IndexField`; `BankField` with
its bank value; `Mutex`/`Event`/`Alias`/`External`; a `Buffer` payload skipped
by its PkgLength with exact resynchronisation; a top-level `If` recorded as
`OPAQUE`; a string-valued `Name`; the empty buffer; 50 nested `Scope`s.

**Malformed (16 cases + 5 resource-exhaustion/limit cases).** Truncated
PkgLength; PkgLength exceeding the buffer; PkgLength too small; unknown
single-byte and unknown `ExtOp` opcode; a valid-but-unhandled opcode with no
PkgLength; a bare NameString (method invocation); truncated `ExtOp`; illegal
NameSeg character; `MultiName` SegCount 0; truncated NameSeg; a child
overrunning its parent's package; a bad FieldList element; a `Name` with a
computed initialiser; an `OpRegion` with a non-literal offset; a `Method`
package running past the end; 70-deep nesting; and deliberate exhaustion of
the node, name and u64 arenas plus a field bit-offset overflow. Each asserts
a **distinct** error code, that the parse returned 0, and that the depth
counter unwound to zero.

**Control flow and invocation (#1051).** `Method` containing
`If`/`Else`/`While`/`Return`/`Break`, asserting that the `Else` is the
immediately-following sibling of its `If` and that child 0 of an `If` is
its predicate. A **forward** method invocation — `AAAA` calling `BBBB`,
declared after it — which a single-pass parser could not resolve without
guessing, and which is therefore the direct test of the two-pass design.
The `_OSI` built-in. An `External`-declared cross-table callee. A
NameString resolving to a non-method declaration and becoming a reference
rather than a call.

**Data objects (#1052).** `Package` with an integer, a string and a name
reference; an under-filled `Package` (legal — the remainder is
uninitialised); `VarPackage` with a computed count; `Buffer` with
initialisers, asserting the bytes stay in the source buffer;
`Store`/`DerefOf`/`Index` nested three deep and `CondRefOf` through the
two-byte extended form.

**Resource templates (#1053).** A ten-descriptor `_CRS` — IRQ, DMA, IO,
Memory32Fixed, Word/DWord/QWord address space, GpioInt, I2cSerialBus and
a checksummed EndTag — built with a runtime-computed checksum, then
decoded field by field: IRQ mask, DMA channel mask, IO bounds/alignment/
length, memory base and length, address-space min/max/length at all three
widths, GPIO pin count and pin number, I²C bus type, speed and slave
address. Plus the discriminator refusing an ordinary data buffer that
*starts* like an IRQ descriptor, without latching; a field read past a
descriptor returning 0; and the accessors leaving the cursor undisturbed.

**Malformed (#1051/#1052/#1053).** An `If` whose PkgLength overruns the
enclosing TermList (asserted by `err_off` and node count, not just the
code); `Else` with no preceding sibling and `Else` after a non-`If`
sibling; ambiguous method arity; more package elements than declared; a
`Buffer` whose literal size exceeds its extent; control flow in TermArg
position; an unresolvable invocation; `DataRegion` as the
still-unimplemented opcode. For resources: a valid non-zero checksum and
a zero "not computed" checksum both accepted, a wrong checksum, a small
descriptor truncated mid-payload, a large descriptor whose length field
overruns, a large header itself cut short, a missing EndTag, bytes after
the EndTag, reserved small and large item names, an EndTag with the wrong
length nibble, and an empty buffer.

**Invariants.** A hundred reads at end-of-stream fault nothing; a latched
error freezes the cursor and blocks reads; `set_err` is first-writer-wins;
`seek` past the end is refused rather than clamped; a truncated multi-byte
literal is atomic.

---

## 9. Deliberately deferred

| Deferred | To |
|---|---|
| `DataRegion` (three TermArgs plus a NameString) — the one ACPI 6.5 opcode still refused with `UNEXPECTED_OP` | R30.M2 |
| Computed `Name` initialisers — `DataRefObject` admits only literals and aggregates per §20.2.5.1, so a computed one is genuinely malformed and stays refused | — |
| A `Method` declared inside an If/While body, called from a body swept earlier (§6a) — refused, never mis-parsed | R30.M2, with the namespace index |
| Sorted final-NameSeg index to replace the linear arity scan | R30.M2, together with the arena growth |
| Full scope resolution of a NameString to a namespace node | R30.M2 |
| `ExtendedSpace` (large item 11) accessors — different layout from the Word/DWord/QWord family | when a device presents one |
| Evaluation of anything at all — OpRegion access, method execution | R30.M2 (#1054+) |
| Revision-dependent truncation of `OnesOp` to 32 bits | R30.M2 — a parser that truncated would destroy information the evaluator needs |
| `Processor` `PblkAddr`/`PblkLen`, `PowerResource` `ResourceOrder` | recoverable from `src_off`; store them if a consumer ever needs them without re-reading |
| Arena sizing for a full DSDT | a `.bss` change; exhaustion is already a clean error |

That prediction held. #1051 descends method bodies by walking
`[arg0, arg1)` from the node the declaration pass already built: no
re-parse of the buffer, no change to the node representation, and the
`METHOD` record gained nothing but one flag bit.
