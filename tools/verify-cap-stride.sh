#!/usr/bin/env bash
# R31.M1 / #1589 — the capability descriptor stride is 24 bytes, everywhere.
#
# WHAT THIS POLICES
#
# `cap_table` is 256 descriptors at a stride of TWENTY-FOUR BYTES:
# kind at +0, rights at +8, target_ptr at +16. That number is not
# written down in one place and consulted; it is OPEN-CODED at 136
# hand-written assembly sites across 36 files, because the descriptor
# address is computed inline every time it is needed.
#
# Until #1589, `struct Capability` in cap/table.pdx also declared
# `generation: u64` and `flags: u32`, and nothing gave them storage —
# the backing array is 256 x 3 u64s, not 256 x 4. At stride 24, struct
# offset +24 (where `generation` sat) is THE KIND FIELD OF DESCRIPTOR
# N+1. Anyone implementing generation by following the declared struct —
# the natural thing to do, since the struct is the documentation — would
# have silently retyped the adjacent capability. `kind` is the first
# thing every gate checks, so the corruption would have surfaced
# arbitrarily far from its cause. Two TODOs in the same tree instructed
# a contributor to do exactly that.
#
# That is a memory-corruption bug reachable by reading the source
# correctly, which is the argument for a BUILD FAILURE rather than a
# review comment.
#
# FOUR INDEPENDENT HALVES
#
#   1. DECLARATIONS. The three constants and the two array declarations
#      appear verbatim in cap/table.pdx. A number that lives only in a
#      comment is a number a future edit can disagree with silently.
#
#   2. THE IDENTITY. CAP_SLOT_MAX * CAP_DESC_BYTES == CAP_TABLE_U64S * 8.
#      This is exactly the equation #1589's mine violates: a struct
#      widened without the array, or an array widened without the
#      stride, breaks it.
#
#   3. THE PHANTOM FIELDS STAY GONE. `struct Capability` must not
#      declare `generation` or `flags`.
#
#   4. EVERY SITE. Each `cap_table` base reference in src/ and tests/ is
#      classified into one of three forms, and anything else fails and
#      is named by file and line:
#
#        V — variable slot:  mov rax, cap_table ; shl rX,3 ; shl rY,4 ; add
#            (slot*8 + slot*16 = slot*24)
#        C — constant slot:  mov rax, cap_table ; add rax, <slot*24>
#            (the immediate must be a multiple of 24 naming a slot < 256)
#        Z — slot 0:         mov rax, cap_table  with no scaling at all
#            (offset 0 is stride-independent)
#
# A VACUITY GUARD fires if the classifier finds implausibly few sites of
# any form — i.e. if a refactor of the address-computation idiom made
# these regexes stop matching. Without it the gate would "pass" by
# scanning nothing, which is the failure mode it exists to prevent.
#
# WHAT IT DOES NOT PROVE
#
# Form C is a partial check by construction: a 32-byte stride's constant
# offsets are multiples of 24 for one slot in three, so a third of a
# hypothetical widening would slip past half 4 alone. Halves 1 and 2
# catch the widening at its source, which is where a real one would
# start. Non-vacuousness is proved by mutation, per-half; see the #1589
# commit message.
#
# Exit 0 = struct, storage, constants and every site agree on 24 bytes.
# Exit 1 = a divergence, named by file and line, or a vacuous scan.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

python3 - "${REPO_ROOT}" <<'PYEOF'
import os, re, sys

ROOT = sys.argv[1]
TAG  = "[cap-stride]"
fails = []

TABLE = os.path.join(ROOT, "src/kernel/core/cap/table.pdx")

def fail(msg, *detail):
    fails.append((msg, detail))

# ---------------------------------------------------------------------------
# HALF 1 — the declarations.
# ---------------------------------------------------------------------------
try:
    table_src = open(TABLE, encoding="utf-8").read()
except OSError as e:
    print(f"{TAG} FAIL — cannot read {TABLE}: {e}", file=sys.stderr)
    sys.exit(1)

DECLS = [
    "pub let CAP_SLOT_MAX   : u64 = 256",
    "pub let CAP_DESC_BYTES : u64 = 24",
    "pub let CAP_TABLE_U64S : u64 = 768",
    "pub let cap_table : [u64; 768] = uninit",
    "pub let mut cap_owner : [u64; 256] = uninit",
]
for d in DECLS:
    if d not in table_src:
        fail(
            "expected declaration not found in src/kernel/core/cap/table.pdx:",
            f"    {d}",
            "  The descriptor stride is open-coded at every one of the 136",
            "  cap_table sites in the tree, so the constants that name it are",
            "  the only place a reader can check one against. If a declaration",
            "  legitimately changed, the layout argument in table.pdx and",
            "  design/capabilities/ownership-and-lineage.md §4.2 must be",
            "  rewritten first, and half 4 of this gate updated with it.",
        )

# ---------------------------------------------------------------------------
# HALF 2 — the identity that #1589's mine violates.
# ---------------------------------------------------------------------------
def const_of(name):
    m = re.search(r"pub let\s+" + name + r"\s*:\s*u64\s*=\s*(\d+)", table_src)
    return int(m.group(1)) if m else None

slot_max  = const_of("CAP_SLOT_MAX")
desc_len  = const_of("CAP_DESC_BYTES")
tbl_u64s  = const_of("CAP_TABLE_U64S")

if None in (slot_max, desc_len, tbl_u64s):
    fail("could not parse CAP_SLOT_MAX / CAP_DESC_BYTES / CAP_TABLE_U64S from table.pdx.",
         "  Half 2 cannot evaluate the layout identity without them, and a gate",
         "  that silently skips its own arithmetic is worse than no gate.")
elif slot_max * desc_len != tbl_u64s * 8:
    fail("the layout identity does not hold:",
         f"    CAP_SLOT_MAX * CAP_DESC_BYTES = {slot_max} * {desc_len} = {slot_max*desc_len}",
         f"    CAP_TABLE_U64S * 8            = {tbl_u64s} * 8 = {tbl_u64s*8}",
         "  The struct, the backing array and the stride disagree. This is the",
         "  exact shape of #1589: a descriptor field declared with no storage",
         "  writes into the NEXT descriptor's kind, and kind is the first thing",
         "  every gate checks, so the corruption surfaces far from its cause.")

# Cross-check the array declarations against the constants, so a hand-edit
# of one number cannot satisfy half 1 while contradicting half 2.
m = re.search(r"pub let cap_table\s*:\s*\[u64;\s*(\d+)\]", table_src)
if m and tbl_u64s is not None and int(m.group(1)) != tbl_u64s:
    fail(f"cap_table is declared [u64; {m.group(1)}] but CAP_TABLE_U64S is {tbl_u64s}.")
m = re.search(r"pub let mut cap_owner\s*:\s*\[u64;\s*(\d+)\]", table_src)
if m and slot_max is not None and int(m.group(1)) != slot_max:
    fail(f"cap_owner is declared [u64; {m.group(1)}] but CAP_SLOT_MAX is {slot_max}.",
         "  The owner column is a COLUMN SPLIT of the descriptor, not a side",
         "  table: same key, same cardinality, same lifetime. A cardinality",
         "  mismatch is the one way that claim stops being true.")

# ---------------------------------------------------------------------------
# HALF 3 — the phantom fields stay gone.
# ---------------------------------------------------------------------------
m = re.search(r"struct\s+Capability\s*\{(.*?)\}", table_src, re.S)
if not m:
    fail("struct Capability not found in table.pdx.",
         "  Half 3 has nothing to check, so it fails rather than passing",
         "  vacuously.")
else:
    body = m.group(1)
    for phantom in ("generation", "flags"):
        if re.search(r"\b" + phantom + r"\s*:", body):
            fail(f"struct Capability declares `{phantom}`, which has no storage.",
                 "  The backing array is CAP_SLOT_MAX x 3 u64s. At stride 24, a",
                 "  fourth field's offset (+24) is the NEXT DESCRIPTOR'S kind.",
                 "  Writing it corrupts an unrelated capability's type, and",
                 "  because kind is checked first by every gate, the failure",
                 "  presents arbitrarily far from the write. This is #1589. If",
                 "  the field is wanted for real, widen the table (Option B) and",
                 "  update all 136 sites — do not declare it alone.")
    fields = re.findall(r"(\w+)\s*:\s*u\d+", body)
    if fields != ["kind", "rights", "target_ptr"]:
        fail(f"struct Capability declares {fields}, expected ['kind', 'rights', 'target_ptr'].",
             "  The struct must describe exactly what has storage. Anything else",
             "  is documentation that a contributor can follow into a memory",
             "  corruption.")

# ---------------------------------------------------------------------------
# HALF 4 — every cap_table site.
# ---------------------------------------------------------------------------
BASE = re.compile(r"(?:mov|lea)\s+([a-z0-9]+)\s*,\s*(?:\[rip \+ )?cap_table\b")
SHL  = re.compile(r"shl\s+([a-z0-9]+)\s*,\s*(\d+)")
PRUNE = {".git", "paideia-as", "build", "target", "node_modules"}

nV = nC = nZ = 0
strays = []

for sub in ("src", "tests"):
    for root, dirs, files in os.walk(os.path.join(ROOT, sub)):
        dirs[:] = [d for d in dirs if d not in PRUNE]
        for fn in sorted(files):
            if not fn.endswith(".pdx"):
                continue
            path = os.path.join(root, fn)
            rel  = os.path.relpath(path, ROOT)
            # Strip line comments: a stride mentioned in prose is not a
            # stride the machine computes.
            lines = [l.split("//")[0] for l in
                     open(path, encoding="utf-8", errors="replace").read().split("\n")]
            for i, line in enumerate(lines):
                m = BASE.search(line)
                if not m:
                    continue
                reg = m.group(1)
                # A slot scale may be computed just before the base load
                # (sys_svc_lookup, kernel_main) or just after it (the
                # common idiom), so the window spans both.
                win = "\n".join(lines[max(0, i - 6): i + 10])
                shls = sorted(a for _, a in SHL.findall(win))
                if shls == ["3", "4"]:
                    nV += 1
                    continue
                nxt = lines[i + 1] if i + 1 < len(lines) else ""
                am = re.search(r"add\s+" + reg + r"\s*,\s*(\d+)\s*;", nxt)
                if not shls and am:
                    off = int(am.group(1))
                    if off % 24 == 0 and off // 24 < 256:
                        nC += 1
                        continue
                    strays.append((rel, i + 1,
                                   f"constant offset {off} is not slot*24 for a slot < 256"))
                    continue
                if not shls and not am:
                    nZ += 1
                    continue
                strays.append((rel, i + 1,
                               f"scaling by shl {{{','.join(shls)}}} is not slot*8 + slot*16"))

if strays:
    fail("cap_table address computations that are not stride 24:",
         *[f"    {r}:{n} — {why}" for r, n, why in strays],
         "  Every descriptor address in this tree is open-coded as",
         "  slot*8 + slot*16, or as a literal multiple of 24, or as slot 0.",
         "  A site that scales differently reads a DIFFERENT, LIVE descriptor",
         "  rather than faulting — the failure mode #1589 names, at whichever",
         "  slot the arithmetic happens to land on.")

# Vacuity guard. Current tree: V=71, C=30, Z=35, total 136.
MIN_V, MIN_C, MIN_TOTAL = 60, 20, 120
total = nV + nC + nZ
if nV < MIN_V or nC < MIN_C or total < MIN_TOTAL:
    fail(f"vacuous scan — V={nV} (min {MIN_V}), C={nC} (min {MIN_C}), "
         f"total={total} (min {MIN_TOTAL}).",
         "  The classifier stopped matching the address-computation idiom, so",
         "  half 4 is checking little or nothing. A gate that passes by",
         "  scanning nothing is the failure mode it exists to prevent. If the",
         "  idiom legitimately changed, update BASE/SHL here and re-baseline",
         "  these floors in the same commit.")

if fails:
    for msg, detail in fails:
        print(f"{TAG} FAIL — {msg}", file=sys.stderr)
        for d in detail:
            print(d, file=sys.stderr)
    sys.exit(1)

print(f"{TAG} struct, storage and constants agree on 24 bytes; "
      f"{total} sites pinned (V={nV} C={nC} Z={nZ})")
PYEOF
