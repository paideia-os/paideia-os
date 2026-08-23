#!/usr/bin/env bash
# R31.M2 / #1604 — init's ring-3 handoff is written once and read once.
#
# WHAT THIS POLICES
#
# `enter_userland_initial` needs three values: init's task slab, its ELF
# entry point, and the top of its user stack. They are computed early in
# kernel_main_64's init bootstrap and consumed at the very last
# instruction sequence before ring 3.
#
# Between those two points sit SIX CALLS into five witness modules —
# witness_r20b_ipc, witness_r20b_loader, witness_r20b_echo_rpc,
# witness_rpc_servers, witness_r29_cascade, witness_r31_spawn — roughly
# six thousand lines of boot witness across separate files.
#
# Until #1604 the three values crossed that gap in r12/r13/r14, on the
# strength of SysV callee-save discipline being honoured by every witness
# in between, forever, with nothing checking it. Three of the six never
# touched the registers and said so only in prose. rpc_servers.pdx and
# r29_cascade.pdx used r13/r14 as scratch under their own push/pop.
# r20b_ipc.pdx bracketed all three with a push at its line 147 and the
# matching pops 1,545 lines later.
#
# THE DEPENDENCY WAS REAL AND IT WAS BREAKABLE. Inserting a single
# `mov r13, 0xdeadbeef` at the top of witness_r31_spawn made the boot
# fail with `R31 ECHO CLIENT RING3 OK` missing — a ring-3 entry into a
# bogus rip, produced by an edit that no assembler, elaborator, linter or
# unit test in this tree objected to. It was found by mutation, by hand,
# after the fact.
#
# WHAT REPLACED IT
#
# Three .bss slots. R53.M3-001 (#1742) split their DECLARATIONS out to
# src/kernel/boot/handoff.pdx (module Handoff, the single owning module
# for the kernel-side boot handoff record); the store, load and poison
# sites remained in src/kernel/boot/kernel_main.pdx unchanged:
#
#     _init_handoff_task        init task slab pointer
#     _init_handoff_entry_rip   ELF e_entry (user VA)
#     _init_handoff_user_rsp    top of init's user stack
#
# written once, immediately after the setup block that computes them, and
# read once, immediately before `call enter_userland_initial`.
#
# The split changes the shape of the confinement check but not its
# strength: this gate now runs against TWO owner files rather than one
# -- OWNER_DECL for the declarations (and NOTHING ELSE), OWNER_ACCESS
# for the two access sites and the register poison. A reference from
# any third file still fails; a store or load appearing in OWNER_DECL
# still fails; a declaration appearing in OWNER_ACCESS still fails.
#
# WHY THIS GATE EXISTS AT ALL
#
# Moving state out of a register and into a global is not automatically
# an improvement — it can be a lateral move that trades an unenforced
# CALLING convention for an unenforced GLOBAL one, and the global is
# reachable from strictly more places. What makes it an improvement is
# the confinement: two accesses, both in one function, and a build
# failure the moment a third appears. That confinement is not expressible
# in paideia-as (a module-private `let` still emits a global symbol), so
# it is expressed here.
#
# FIVE HALVES
#
#   1. DECLARATION. Each slot is declared exactly once, in OWNER_DECL
#      (src/kernel/boot/handoff.pdx), as `pub let mut <sym> : u64 = 0`.
#      Zero-init is load-bearing: both ends check for zero. Additionally,
#      OWNER_DECL must NOT name the symbol on any other line -- the
#      declaration file is storage-only, so a store or load creeping in
#      here would smuggle a second access site under the split-owner
#      exemption HALF 2 grants it.
#
#   2. CONFINEMENT. Each symbol is named in exactly two files -- OWNER_
#      DECL (declaration) and OWNER_ACCESS (store + load + poison). A
#      reference from any other file fails, named by file and line,
#      whether it is code or a comment. Prose that names the slot from
#      another module is the first step toward code that reads it, and
#      there is no cost to routing such prose through the symbol-free
#      phrase "init's ring-3 handoff".
#
#   3. TWO ACCESSES. Within OWNER_ACCESS (src/kernel/boot/kernel_main.pdx)
#      each symbol has exactly two code references (comments stripped):
#      one store `mov [rip + S], rN` and one load `mov rN, [rip + S]`.
#      Not two stores, not a load in a loop, not a third site "just
#      reading it for a log line".
#
#   4. THE SPAN. Within OWNER_ACCESS, every store precedes every load,
#      and all six witness calls lie strictly between them. This is what
#      makes the gate about the actual hazard rather than about tidiness:
#      if a future edit moved the store to after the witnesses, or moved
#      a witness call outside the span, the arrangement would still have
#      two accesses and would no longer be protecting anything.
#
#   5. THE REGISTER PATH IS DEAD. r12/r13/r14 are poisoned with a
#      non-canonical constant between the store and the first witness
#      call, and kernel_main.pdx names none of the three again between
#      the poison and `call enter_userland_initial`.
#
#      This half is the one that stops the worst outcome, which is not a
#      third .bss reader but a BELT-AND-BRACES arrangement where the
#      registers also still carry the values. That version is strictly
#      worse than either mechanism alone: the register path would remain
#      unenforced AND become untested, because the .bss path would mask
#      every failure of it. Poison converts "nothing downstream reads
#      these" from a claim into a page fault.
#
# A VACUITY GUARD fires if the six witness calls are not all found
# between the accesses, or if a fourth `_init_handoff_*` symbol exists
# that this gate does not know about. Without it a refactor that renamed
# the witness entry points would leave the gate passing while checking
# a span containing nothing.
#
# WHAT IT DOES NOT PROVE
#
# It is a source-level gate over one function, not a dataflow analysis.
# It does not prove the stored values are the right ones — the two
# zero-checks at the read site are the only runtime assertion, and a
# non-zero wrong value would sail through. Non-vacuousness is proved by
# mutation, in both directions, and both experiments are recorded in the
# #1604 commit message: clobbering r13 inside witness_r31_spawn must now
# leave the boot GREEN, and corrupting a .bss slot must make it FAIL.
# The pair is what shows the dependency moved rather than merely became
# invisible.
#
# Exit 0 = three slots, declared once, named in one file, accessed twice,
#          spanning all six witness calls, with the register path poisoned.
# Exit 1 = a divergence, named by file and line, or a vacuous scan.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

python3 - "${REPO_ROOT}" <<'PYEOF'
import os, re, sys

ROOT = sys.argv[1]
TAG  = "[init-handoff]"
fails = []

# R53.M3-001 (#1742): the storage was factored out of kernel_main.pdx
# into its own module (boot/handoff.pdx). Declaration site and access
# site are now different files; every half below is written against
# the pair, and HALF 2 admits both as exemptions from the foreign-
# reference ban.
OWNER_DECL   = "src/kernel/boot/handoff.pdx"
OWNER_ACCESS = "src/kernel/boot/kernel_main.pdx"
SYMS  = ["_init_handoff_task", "_init_handoff_entry_rip", "_init_handoff_user_rsp"]

# The six calls the handoff has to survive. Named explicitly rather than
# discovered, so deleting one is a change to this list and therefore a
# change a reviewer sees.
WITNESS_CALLS = [
    "witness_r20b_ipc",
    "witness_r20b_loader",
    "witness_r20b_echo_rpc",
    "witness_rpc_servers",
    "witness_r29_cascade",
    "witness_r31_spawn",
]

HANDOFF_REGS = ["r12", "r13", "r14"]
PRUNE = {".git", "paideia-as", "build", "target", "node_modules"}


def fail(msg, *detail):
    fails.append((msg, detail))


def strip_comment(line):
    return line.split("//")[0]


access_path = os.path.join(ROOT, OWNER_ACCESS)
decl_path   = os.path.join(ROOT, OWNER_DECL)
try:
    owner_raw = open(access_path, encoding="utf-8").read().split("\n")
except OSError as e:
    print(f"{TAG} FAIL — cannot read {OWNER_ACCESS}: {e}", file=sys.stderr)
    sys.exit(1)
try:
    decl_raw = open(decl_path, encoding="utf-8").read().split("\n")
except OSError as e:
    print(f"{TAG} FAIL — cannot read {OWNER_DECL}: {e}", file=sys.stderr)
    sys.exit(1)
owner_code = [strip_comment(l) for l in owner_raw]
decl_code  = [strip_comment(l) for l in decl_raw]

# ---------------------------------------------------------------------------
# HALF 1 — the declarations (in OWNER_DECL, and nothing else in that file
# may name the symbol -- otherwise HALF 2's split-owner exemption would
# let a second access site hide there).
# ---------------------------------------------------------------------------
for sym in SYMS:
    decl = re.compile(r"^\s*pub let mut\s+" + sym + r"\s*:\s*u64\s*=\s*0\s*$")
    hits = [i + 1 for i, l in enumerate(decl_code) if decl.match(l)]
    if len(hits) != 1:
        fail(f"`{sym}` must be declared exactly once in {OWNER_DECL} as "
             f"`pub let mut {sym} : u64 = 0` — found {len(hits)}.",
             "  Zero-init is not incidental: the setup block refuses to store a",
             "  zero task slab or entry point, and the ring-3 entry refuses to",
             "  iretq on one, so zero is the agreed 'never written' value.")
    stray = [i + 1 for i, l in enumerate(decl_code)
             if sym in l and not decl.match(l)]
    if stray:
        fail(f"`{sym}` referenced in {OWNER_DECL} outside its declaration:",
             *[f"    line {n}: {decl_code[n-1].strip()}" for n in stray],
             f"  {OWNER_DECL} is the storage-only owner; a store, load, or",
             "  comment naming the symbol here would smuggle a second access",
             "  site under HALF 2's split-owner exemption. Route prose through",
             "  the symbol-free phrase 'init's ring-3 handoff'.")

# A fourth slot would be outside everything below.
extra = set()
for sub in ("src", "tests"):
    for root, dirs, files in os.walk(os.path.join(ROOT, sub)):
        dirs[:] = [d for d in dirs if d not in PRUNE]
        for fn in files:
            if not fn.endswith(".pdx"):
                continue
            for l in open(os.path.join(root, fn), encoding="utf-8",
                          errors="replace"):
                for m in re.finditer(r"_init_handoff_[A-Za-z0-9_]+", l):
                    if m.group(0) not in SYMS:
                        extra.add(m.group(0))
if extra:
    fail(f"unknown `_init_handoff_*` symbol(s): {sorted(extra)}.",
         "  Every half below is written against the three slots this gate",
         "  knows by name. A fourth would be unpoliced — add it to SYMS here,",
         "  in the same commit that introduces it, or do not add it.")

# ---------------------------------------------------------------------------
# HALF 2 — confinement to the two owner files (OWNER_DECL + OWNER_ACCESS).
# ---------------------------------------------------------------------------
EXEMPT = {OWNER_DECL, OWNER_ACCESS, "tools/verify-init-handoff.sh"}
foreign = []
for sub in ("src", "tests", "tools"):
    base = os.path.join(ROOT, sub)
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in PRUNE]
        for fn in sorted(files):
            path = os.path.join(root, fn)
            rel  = os.path.relpath(path, ROOT)
            if rel in EXEMPT:
                continue
            if not fn.endswith((".pdx", ".S", ".ld", ".c", ".h")):
                continue
            try:
                lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            except OSError:
                continue
            for i, l in enumerate(lines):
                for sym in SYMS:
                    if sym in l:
                        foreign.append((rel, i + 1, sym))
if foreign:
    fail("the handoff slots are named outside their two owner files:",
         *[f"    {r}:{n} — {s}" for r, n, s in foreign],
         "  These three slots exist to carry state across six witness calls",
         "  into five modules WITHOUT any of those modules being able to reach",
         "  it. A .bss global that half the boot path can name is not an",
         "  improvement on the register convention it replaced — it is the same",
         "  unenforced coupling with a wider reachable set. Refer to it in prose",
         "  as 'init's ring-3 handoff'; do not name the symbol.",
         f"  Owner files: {OWNER_DECL} (declaration only) and {OWNER_ACCESS}",
         "  (store + load + poison). Any other file that names one of these",
         "  symbols is a bug, whether the reference is code or a comment.")

# ---------------------------------------------------------------------------
# HALF 3 — exactly one store and one load, per symbol.
# ---------------------------------------------------------------------------
REG = r"(?:r[a-d]x|rsi|rdi|r8|r9|r1[0-5])"
stores, loads = {}, {}
for sym in SYMS:
    st = re.compile(r"\bmov\s*\[\s*rip\s*\+\s*" + sym + r"\s*\]\s*,\s*(" + REG + r")\s*;")
    ld = re.compile(r"\bmov\s+(" + REG + r")\s*,\s*\[\s*rip\s*\+\s*" + sym + r"\s*\]\s*;")
    s_hits = [i for i, l in enumerate(owner_code) if st.search(l)]
    l_hits = [i for i, l in enumerate(owner_code) if ld.search(l)]
    other  = [i for i, l in enumerate(owner_code)
              if sym in l and i not in s_hits and i not in l_hits
              and not re.match(r"^\s*pub let mut\s+" + sym + r"\b", l)]
    stores[sym], loads[sym] = s_hits, l_hits
    if len(s_hits) != 1 or len(l_hits) != 1:
        fail(f"`{sym}` must have exactly one store and one load in "
             f"{OWNER_ACCESS} — found {len(s_hits)} store(s) at lines "
             f"{[i + 1 for i in s_hits]} and {len(l_hits)} load(s) at lines "
             f"{[i + 1 for i in l_hits]}.",
             "  Expected forms, and only these:",
             f"      mov [rip + {sym}], rN;",
             f"      mov rN, [rip + {sym}];",
             "  A second reader is how a confined handoff becomes an ambient",
             "  global. A second writer is how the read site stops being able",
             "  to say which write it observes.")
    if other:
        fail(f"`{sym}` referenced in {OWNER_ACCESS} outside its store and load:",
             *[f"    line {i + 1}: {owner_code[i].strip()}" for i in other])

if any(len(stores[s]) != 1 or len(loads[s]) != 1 for s in SYMS):
    # Halves 4 and 5 are positional and cannot be evaluated without them.
    for msg, detail in fails:
        print(f"{TAG} FAIL — {msg}", file=sys.stderr)
        for d in detail:
            print(d, file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# HALF 4 — the span: every witness call sits between write and read.
# ---------------------------------------------------------------------------
last_store  = max(stores[s][0] for s in SYMS)
first_load  = min(loads[s][0]  for s in SYMS)
first_store = min(stores[s][0] for s in SYMS)

if last_store >= first_load:
    fail(f"the handoff is read (line {first_load + 1}) before it is fully "
         f"written (line {last_store + 1}).")

missing, outside = [], []
for name in WITNESS_CALLS:
    call = re.compile(r"^\s*call\s+" + name + r"\s*;")
    hits = [i for i, l in enumerate(owner_code) if call.match(l)]
    if not hits:
        missing.append(name)
        continue
    for i in hits:
        if not (last_store < i < first_load):
            outside.append((name, i + 1))

if missing:
    fail(f"vacuous span — witness call(s) not found in {OWNER_ACCESS}: {missing}.",
         "  This gate exists to police a handoff that crosses these six calls.",
         "  If one was renamed or removed, update WITNESS_CALLS here in the",
         "  same commit; a span that crosses nothing proves nothing.")
if outside:
    fail("witness call(s) outside the handoff span:",
         *[f"    line {n} — call {name}" for name, n in outside],
         f"  The handoff is written by line {last_store + 1} and read at line "
         f"{first_load + 1}.",
         "  A witness that runs outside that span is not a witness the .bss",
         "  handoff is protecting anything from — either it moved, or the",
         "  store/load moved, and either way the arrangement no longer matches",
         "  the hazard it was built for.")

# ---------------------------------------------------------------------------
# HALF 5 — the register path is dead, not merely unused.
# ---------------------------------------------------------------------------
POISON = re.compile(r"^\s*mov\s+(r1[234])\s*,\s*(0x[0-9A-Fa-f]+)\s*;")


def non_canonical(v):
    # Canonical x86-64: bits 63:47 all equal. Anything else #GPs on use.
    hi = v >> 47
    return hi != 0 and hi != 0x1FFFF


poisoned = {}
for i in range(last_store + 1, first_load):
    m = POISON.match(owner_code[i])
    if m and non_canonical(int(m.group(2), 16)):
        poisoned.setdefault(m.group(1), i)

unpoisoned = [r for r in HANDOFF_REGS if r not in poisoned]
if unpoisoned:
    fail(f"handoff register(s) not poisoned after the store: {unpoisoned}.",
         "  Each of r12/r13/r14 must be overwritten with a NON-CANONICAL",
         "  constant between the last store and the first witness call, e.g.",
         "      mov r13, 0xDEAD16040DEAD160;",
         "  The point is not tidiness. If the registers keep carrying the",
         "  values alongside the .bss slots, the two mechanisms are both live:",
         "  the register path stays unenforced, and now also untested, because",
         "  the .bss path masks every failure of it. That is strictly worse",
         "  than either mechanism alone. Poison makes a surviving register",
         "  reader fault on its first dereference instead of consuming a value",
         "  that happens to still be correct today.")
else:
    poison_end = max(poisoned.values())
    revived = []
    for i in range(poison_end + 1, first_load):
        for r in HANDOFF_REGS:
            if re.search(r"\b" + r + r"\b", owner_code[i]):
                revived.append((i + 1, r, owner_code[i].strip()))
    if revived:
        fail("handoff register(s) named again after being poisoned:",
             *[f"    line {n} [{r}] — {txt}" for n, r, txt in revived],
             "  Between the poison and the ring-3 entry, kernel_main.pdx must",
             "  not touch r12/r13/r14 at all. Re-establishing one here would",
             "  re-create the convention #1604 removed, in the one region where",
             "  it is least visible.")

# ---------------------------------------------------------------------------
if fails:
    for msg, detail in fails:
        print(f"{TAG} FAIL — {msg}", file=sys.stderr)
        for d in detail:
            print(d, file=sys.stderr)
    sys.exit(1)

print(f"{TAG} 3 slots declared once in {OWNER_DECL}, accessed only in "
      f"{OWNER_ACCESS}, named in no other file; "
      f"written at lines {sorted(stores[s][0] + 1 for s in SYMS)}, "
      f"read at lines {sorted(loads[s][0] + 1 for s in SYMS)}; "
      f"{len(WITNESS_CALLS)} witness calls span the gap; "
      f"r12/r13/r14 poisoned non-canonical and untouched thereafter")
PYEOF
