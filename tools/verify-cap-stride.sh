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
# FIVE INDEPENDENT HALVES
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
#   5. WHAT IS DEREFERENCED FROM THE BASE. Halves 1–4 police how a
#      descriptor ADDRESS IS COMPUTED and say nothing about which
#      offsets are then read or written through it. #1591 demonstrated
#      the consequence: a single stray `mov [rax + 24], rdx` appended
#      after a correct base computation and a correct three-word write
#      passed all four halves, exit 0, while corrupting the NEXT
#      descriptor's `kind` — the exact #1589 failure shape, reachable
#      without touching table.pdx at all.
#
#      Half 5 walks forward from each classified site, tracking the
#      register that holds the computed base, and checks every constant
#      offset dereferenced through it:
#
#        V sites — the base names descriptor `slot` for a RUNTIME slot,
#          so +24 is descriptor slot+1 at an index nobody chose. Offsets
#          are restricted to {0, 8, 16}. There is no legitimate reason
#          for a variable-slot site to reach outside its own descriptor:
#          a site that wants a different slot recomputes the base, and
#          every one of the 151 V-form dereferences in the tree does.
#
#        C and Z sites — the base names a CONSTANT slot, so +24 is
#          "slot n+1", which kernel_main legitimately does when it seeds
#          a run of descriptors. These are bounds-checked only: each
#          offset must be 8-byte aligned and `base + offset` must land
#          inside cap_table. See WHAT IT DOES NOT PROVE.
#
#      A register-indexed dereference (`[rax + rcx*8]`) through a
#      tracked base is refused for every form, because its offset is not
#      knowable here. If one is genuinely wanted, annotate the line:
#
#        mov [rax + rcx*8], r8;   // [cap-stride-ok: <why this is safe>]
#
#      The reason text is required and is not parsed — it exists so the
#      exception is argued at the site rather than accumulated in a list
#      somewhere else. The tree currently needs none.
#
# A VACUITY GUARD fires if the classifier finds implausibly few sites of
# any form — i.e. if a refactor of the address-computation idiom made
# these regexes stop matching. Without it the gate would "pass" by
# scanning nothing, which is the failure mode it exists to prevent.
# Half 5 has its own floor on dereferences inspected, for the same
# reason: its walk stops at several conditions (below), and a change
# that made it stop immediately everywhere would leave it silently
# checking nothing.
#
# WHAT IT DOES NOT PROVE
#
# Form C is a partial check by construction: a 32-byte stride's constant
# offsets are multiples of 24 for one slot in three, so a third of a
# hypothetical widening would slip past half 4 alone. Halves 1 and 2
# catch the widening at its source, which is where a real one would
# start. Non-vacuousness is proved by mutation, per-half; see the #1589
# and #1592 commit messages.
#
# HALF 5 IS A BOUNDED SCAN, NOT A DATAFLOW ANALYSIS, and the bound is
# stated here rather than left for the next person to discover the way
# #1591 discovered half 4's:
#
#   * THE WALK STOPS at the first `call` (a callee's clobbers are
#     unconstrained, so the base register can no longer be trusted), at
#     the first label (a branch target is a control-flow join and the
#     straight-line assumption ends there), at `ret`, at the end of the
#     unsafe block, and after 80 lines. A stray write placed after any
#     of those, in the same function, IS NOT SEEN. Of the 141 sites, the
#     walk currently ends at a call for 43, at a label for 6, at a `ret`
#     or the block's closing brace for 9, and for the remaining 83 by
#     running out of window or losing track of the register. The 151
#     V-form dereferences it does reach are every V-form dereference in
#     the tree.
#
#   * FOR C AND Z SITES THE OFFSET CHECK IS A BOUND, NOT A PIN. From a
#     slot-aligned constant base every multiple of 8 is some
#     descriptor's field, so no arithmetic here can distinguish "slot
#     n+1's kind, deliberately" from "past the end of slot n, by
#     mistake". The check that survives is alignment and in-range. The
#     12 sites in kernel_main.pdx that reach past +16 are all
#     constant-base descriptor-seeding runs, and they are why the strict
#     rule is applied to V only.
#
#   * TRACKING IS SYNTACTIC. The base is followed through
#     `mov <reg>, <base-reg>`; it is dropped on any other write to the
#     register, on `add <reg>, <immediate>`, and on any `add` after the
#     first dereference. Dropping early costs coverage, never
#     correctness — an untracked register is simply not checked.
#
#   * IT IS BLIND TO ALIASING. A base parked in memory and reloaded, or
#     passed to a callee, is a new value as far as this is concerned.
#
# What half 5 DOES see is the case that has now bitten twice: a
# descriptor written correctly and then written past, in one
# straight-line run, at a slot chosen at runtime.
#
# Exit 0 = struct, storage, constants agree on 24 bytes; every site's
#          address computation is stride-24; and no site dereferences
#          outside the descriptor it computed.
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
# (rel, line_index, base_reg, form, const_base_bytes) for half 5.
sites = []
# rel -> (comment-stripped lines, raw lines); half 5 needs both.
filelines = {}

for sub in ("src", "tests"):
    for root, dirs, files in os.walk(os.path.join(ROOT, sub)):
        dirs[:] = [d for d in dirs if d not in PRUNE]
        for fn in sorted(files):
            if not fn.endswith(".pdx"):
                continue
            path = os.path.join(root, fn)
            rel  = os.path.relpath(path, ROOT)
            raw = open(path, encoding="utf-8", errors="replace").read().split("\n")
            # Strip line comments: a stride mentioned in prose is not a
            # stride the machine computes. The raw text is kept because
            # half 5's annotation escape lives in a comment.
            lines = [l.split("//")[0] for l in raw]
            filelines[rel] = (lines, raw)
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
                    sites.append((rel, i, reg, "V", None))
                    continue
                nxt = lines[i + 1] if i + 1 < len(lines) else ""
                am = re.search(r"add\s+" + reg + r"\s*,\s*(\d+)\s*;", nxt)
                if not shls and am:
                    off = int(am.group(1))
                    if off % 24 == 0 and off // 24 < 256:
                        nC += 1
                        sites.append((rel, i, reg, "C", off))
                        continue
                    strays.append((rel, i + 1,
                                   f"constant offset {off} is not slot*24 for a slot < 256"))
                    continue
                if not shls and not am:
                    nZ += 1
                    sites.append((rel, i, reg, "Z", 0))
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

# ---------------------------------------------------------------------------
# HALF 5 — what is dereferenced FROM the base. (#1591)
#
# Halves 1–4 classify how the address is computed. Nothing above this
# line looks at the offsets that are then read or written through it,
# which is how a stray `mov [rax + 24], rdx` appended after a correct
# three-word descriptor write passed the gate with exit 0 while
# corrupting the next descriptor's kind.
#
# The walk is bounded and its bound is documented in the header. It
# stops early rather than guessing; an untracked register is simply not
# checked, so every way this can be wrong costs coverage, not
# correctness.
# ---------------------------------------------------------------------------

REGS = r"(?:r[a-d]x|rsi|rdi|rbp|rsp|r8|r9|r1[0-5])"
MEM     = re.compile(r"\[\s*(" + REGS + r")\s*([^\]]*)\]")
MOVREG  = re.compile(r"^\s*mov\s+(" + REGS + r")\s*,\s*(" + REGS + r")\s*;")
ADDREG  = re.compile(r"^\s*add\s+(" + REGS + r")\s*,\s*(\S+?)\s*;")
KILL    = re.compile(r"^\s*(?:mov|lea|pop|xor|shl|shr|sar|and|or|sub|imul|movzx|movsx)\s+("
                     + REGS + r")\s*,")
# A write to a 32-bit alias zero-extends and so clobbers the full
# register. Tracking it as a kill costs a little coverage and can only
# ever remove a false positive, never create one.
ALIAS32 = {"eax": "rax", "ebx": "rbx", "ecx": "rcx", "edx": "rdx",
           "esi": "rsi", "edi": "rdi", "ebp": "rbp", "esp": "rsp",
           **{f"r{n}d": f"r{n}" for n in range(8, 16)}}
KILL32  = re.compile(r"^\s*(?:mov|lea|pop|xor|shl|shr|sar|and|or|sub|add|imul|movzx|movsx)\s+("
                     + "|".join(ALIAS32) + r")\s*,")
LABEL   = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*$")
OFFSET  = re.compile(r"^\+\s*(\d+)$")
OKANN   = re.compile(r"//.*\[cap-stride-ok:\s*(\S[^\]]*)\]")

CANON_FIELD_OFFSETS = (0, 8, 16)
TABLE_BYTES = (tbl_u64s or 0) * 8

WINDOW = 80
offset_hits = 0          # constant dereferences inspected — half 5's vacuity floor
annotated   = 0
inspected_V = 0
bad_offsets = []

for rel, i, reg, form, cbase in sites:
    lines, raw = filelines[rel]
    tracked = {reg}
    derefed = False
    for j in range(i + 1, min(len(lines), i + WINDOW)):
        l = lines[j]
        if not l.strip():
            continue
        # Stop conditions. Each one is a place where the base register
        # stops being something this scan can reason about.
        if LABEL.match(l):
            break
        if re.search(r"\bcall\b", l) or re.search(r"\bret\b", l) or re.match(r"^\s*\}", l):
            break

        for dm in MEM.finditer(l):
            if dm.group(1) not in tracked:
                continue
            derefed = True
            expr = dm.group(2).strip()
            if OKANN.search(raw[j] if j < len(raw) else ""):
                annotated += 1
                continue
            om = OFFSET.match(expr) if expr else None
            if not expr:
                off = 0
            elif om:
                off = int(om.group(1))
            else:
                bad_offsets.append((
                    rel, j + 1, form,
                    f"dereference `[{dm.group(1)}{(' ' + expr) if expr else ''}]` through a "
                    f"cap_table descriptor base is not a constant offset, so this gate cannot "
                    f"bound it"))
                continue
            offset_hits += 1
            if form == "V":
                inspected_V += 1
                if off not in CANON_FIELD_OFFSETS:
                    bad_offsets.append((
                        rel, j + 1, form,
                        f"offset +{off} on a VARIABLE-slot descriptor base; the descriptor is "
                        f"{desc_len} bytes and its only fields are +0 kind, +8 rights, "
                        f"+16 target_ptr, so this addresses descriptor "
                        f"slot+{off // (desc_len or 24)} at a slot nobody chose"))
            else:
                absolute = (cbase or 0) + off
                if off % 8 != 0:
                    bad_offsets.append((
                        rel, j + 1, form,
                        f"offset +{off} is not 8-byte aligned; cap_table is a u64 array"))
                elif TABLE_BYTES and absolute >= TABLE_BYTES:
                    bad_offsets.append((
                        rel, j + 1, form,
                        f"offset +{off} from a base at byte {cbase} addresses byte "
                        f"{absolute}, past the end of cap_table ({TABLE_BYTES} bytes)"))

        mm = MOVREG.match(l)
        if mm:
            dst, src = mm.group(1), mm.group(2)
            if src in tracked:
                tracked.add(dst)          # the base, parked in a second register
            elif dst in tracked:
                tracked.discard(dst)
            if not tracked:
                break
            continue

        am2 = ADDREG.match(l)
        if am2 and am2.group(1) in tracked:
            # `add rax, r8` is how the V-form base is finished. An
            # immediate add, or any add once the descriptor has already
            # been dereferenced, is re-basing: stop trusting it.
            if re.match(r"^\d+$", am2.group(2)) or derefed:
                tracked.discard(am2.group(1))
            if not tracked:
                break
            continue

        km = KILL.match(l)
        if km and km.group(1) in tracked:
            tracked.discard(km.group(1))
            if not tracked:
                break
            continue

        k32 = KILL32.match(l)
        if k32 and ALIAS32[k32.group(1)] in tracked:
            tracked.discard(ALIAS32[k32.group(1)])
            if not tracked:
                break

if bad_offsets:
    fail("dereferences outside the descriptor the site computed:",
         *[f"    {r}:{n} [{f}] — {why}" for r, n, f, why in bad_offsets],
         "  The base register at this site was established as a cap_table",
         "  DESCRIPTOR address. Reading or writing outside +0/+8/+16 of it",
         "  touches an ADJACENT, LIVE capability — and because `kind` is the",
         "  first thing every gate checks, the corruption presents arbitrarily",
         "  far from the write. This is #1589's failure shape reached without",
         "  changing any declaration, which is #1591.",
         "  If the access is genuinely correct, annotate the line and say why:",
         "      mov [rax + N], rX;   // [cap-stride-ok: <reason>]")

# Half 5's own vacuity floor. The walk has several stop conditions, and
# a change that made it stop immediately everywhere would leave it
# passing without inspecting anything. Current tree: 151 V-form
# dereferences, 312 constant dereferences in total.
MIN_V_DEREFS, MIN_DEREFS = 120, 240
if inspected_V < MIN_V_DEREFS or offset_hits < MIN_DEREFS:
    fail(f"vacuous half 5 — {inspected_V} variable-slot dereferences inspected "
         f"(min {MIN_V_DEREFS}), {offset_hits} constant dereferences in total "
         f"(min {MIN_DEREFS}).",
         "  The forward walk stopped finding dereferences through the computed",
         "  base, so half 5 is checking little or nothing — the same failure",
         "  mode the half-4 vacuity guard exists to prevent, one level down. If",
         "  the address-computation or dereference idiom legitimately changed,",
         "  update the walk here and re-baseline these floors in the same",
         "  commit.")

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
      f"{total} sites pinned (V={nV} C={nC} Z={nZ}); "
      f"{offset_hits} dereferences bounded ({inspected_V} of them pinned to "
      f"+0/+8/+16), {annotated} annotated")
PYEOF
