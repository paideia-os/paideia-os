# AML tokenizer and namespace parser

**Round.** R30 — ACPICA userspace bubble + LPSS bus enablement
**Issues.** #1049 (R30.M1-001, tokenizer) · #1050 (R30.M1-002, namespace objects)
**Status.** Landed. #1051 (control flow), #1052 (data objects) and
#1053 (resource templates) extend the structures defined here.

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
| `tests/user/aml/aml_harness.c` | executable byte-fixture corpus | both |
| `tools/verify-aml-parser.sh` | build-time verification, wired into pre-push | both |

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
| `[39:32]` | `argc` | fixed TermArg count — carried now, consumed by #1051/#1052 |
| `[47:40]` | `node` | `AML_NODE_*` to allocate, 0 for none |
| `[63:48]` | — | reserved, zero |

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
| `0x40` | `F_M1_HANDLED` | parsed by R30.M1-002 |
| `0x80` | `F_OPAQUE_OK` | safe to skip wholesale via its PkgLength |

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

Six opcodes carry `F_OPAQUE_OK` today: `Buffer`, `Package`, `VarPackage`,
`If`, `Else`, `While`. #1051 and #1052 replace the opaque treatment by
changing those rows and adding handlers — the skip logic itself never needs
touching.

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

Every code except 14 is exercised by a corpus fixture. **Code 14 is
unreachable by construction at this milestone** — every handler consumes at
minimum the opcode byte itself — and is retained deliberately as a structural
guard for the handlers #1051 and #1052 will add. It is documented as
untested rather than given a contrived test.

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
out-of-bounds assertion would be vacuous. Both properties were confirmed by
mutation: defeating the bounds check in `aml_lex_u8` produces four `SIGSEGV`
failures, and transposing two opcode-table rows produces three ordering
failures.

### Corpus contents (617 assertions)

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

**Invariants.** A hundred reads at end-of-stream fault nothing; a latched
error freezes the cursor and blocks reads; `set_err` is first-writer-wins;
`seek` past the end is refused rather than clamped; a truncated multi-byte
literal is atomic.

---

## 9. Deliberately deferred

| Deferred | To |
|---|---|
| `If` / `Else` / `While` / `Return` bodies, expression TermArgs, method invocation | #1051 |
| `Buffer` / `Package` / `VarPackage` contents; computed `Name` initialisers; `DataRegion` | #1052 |
| Resource templates inside `Buffer` (`_CRS` / `_PRS` decoding) | #1053 |
| Method **bodies** — recorded as `arg0`/`arg1` extents, not descended | #1051 |
| Evaluation of anything at all — namespace resolution, OpRegion access, method execution | R30.M2 (#1054+) |
| Revision-dependent truncation of `OnesOp` to 32 bits | R30.M2 — a parser that truncated would destroy information the evaluator needs |
| `Processor` `PblkAddr`/`PblkLen`, `PowerResource` `ResourceOrder` | recoverable from `src_off`; store them if a consumer ever needs them without re-reading |
| Arena sizing for a full DSDT | a `.bss` change; exhaustion is already a clean error |

When #1051 lands, descending into method bodies is a change to walk
`[arg0, arg1)` — the node already carries the extent, so no re-parse and no
representation change is needed.
