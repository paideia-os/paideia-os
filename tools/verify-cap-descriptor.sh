#!/usr/bin/env bash
# R31.M1 / #1579 — cap_mint_write is the SOLE non-zero writer of a
# descriptor's target_ptr field (offset +16).
#
# WHAT THIS POLICES
#
# The descriptor row is 24 bytes: kind at +0, rights at +8, target_ptr
# at +16. `cap_mint_write` (src/kernel/core/cap/mint.pdx) is the one
# function that MINTS a live target_ptr — every other module receives a
# handle and looks the target up through cap_get, it never writes it.
# A stray `mov [<cap_table-base> + 16], <non-zero>` outside mint would
# retarget a LIVE capability: same slot, same kind, same rights, but a
# different object address. Because the kind field is unchanged, every
# gate that guards on kind continues to admit the descriptor, and the
# corruption presents as "the driver keeps writing to what looks like
# the right object but the wrong bytes come out" — the exact shape of
# an R31 defect the milestone exists to close.
#
# Zero-clearing writes at +16 ARE allowed anywhere, because a
# descriptor whose target_ptr is zero is a REVOKED descriptor: the
# `revoke` / `zero` / `_free` paths in this tree clear all three fields
# by writing three zero-source stores in a row and never calling a
# revoke function at all. Those paths are the reason cap_mint_write
# UNCONDITIONALLY clears the owner column at mint time (see
# mint.pdx:114 justification), so that "the new capability is still
# owned by the previous holder" is unreachable by construction rather
# than by the diligence of every revoke path.
#
# HOW
#
# We reuse the same base-classification the [cap-stride] gate uses:
# each `mov <reg>, cap_table` (or `lea` variant) is a base site. From
# each site, we walk forward inside the same unsafe block, tracking
# the register that holds the descriptor address (through `mov <reg>,
# <base>` moves; dropped on kills / calls / labels / rets). We report
# every WRITE of shape `mov [<tracked-reg> + 16], <src>` — or
# `mov [<tracked-reg> + N], <src>` where (N % 24) == 16, for C-form
# multi-slot bases — that is NOT one of:
#
#   (a) inside src/kernel/core/cap/mint.pdx (the sole legitimate site;
#       named by file rather than by function to avoid a rename racing
#       ahead of this gate), OR
#   (b) a zero-source write, defined as either an immediate 0 or a
#       register that was `xor <reg>, <reg>`'d within the preceding
#       WINDOW lines of straight-line code, OR
#   (c) annotated with `// [cap-descriptor-ok: <reason>]` on the same
#       line. The reason text is required and is not parsed: it exists
#       so the exception is argued at the site rather than accumulated
#       in a list somewhere else. The current tree needs six, all in
#       test-fixture seed writers whose justifications already say why
#       the mint path is not the right shape for what they build.
#
# VACUITY GUARD
#
# The gate must find AT LEAST ONE allowed mint-write inside mint.pdx.
# A refactor that moves cap_mint_write's descriptor stores out of the
# recognised idiom would leave the gate silently passing while its
# whole raison d'etre had walked out from under it. Same failure mode
# the [cap-stride] vacuity guards catch, one level down.
#
# Exit 0 = every +16 writer is either cap_mint_write or a zero-clear.
# Exit 1 = a stray writer, named by file and line, or a vacuous scan.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

python3 - "${REPO_ROOT}" <<'PYEOF'
import os, re, sys

ROOT = sys.argv[1]
TAG  = "[cap-descriptor-confine]"

BASE = re.compile(r"(?:mov|lea)\s+([a-z0-9]+)\s*,\s*(?:\[rip \+ )?cap_table\b")
SHL  = re.compile(r"shl\s+([a-z0-9]+)\s*,\s*(\d+)")
REGS = r"(?:r[a-d]x|rsi|rdi|rbp|rsp|r8|r9|r1[0-5])"
MEM_WRITE = re.compile(r"^\s*mov\s+\[\s*(" + REGS + r")\s*([^\]]*)\]\s*,\s*(\S+?)\s*;")
MOVREG    = re.compile(r"^\s*mov\s+(" + REGS + r")\s*,\s*(" + REGS + r")\s*;")
ADDREG    = re.compile(r"^\s*add\s+(" + REGS + r")\s*,\s*(\S+?)\s*;")
KILL      = re.compile(r"^\s*(?:mov|lea|pop|xor|shl|shr|sar|and|or|sub|imul|movzx|movsx)\s+("
                       + REGS + r")\s*,")
LABEL     = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*\s*:\s*$")
OFFSET    = re.compile(r"^\+\s*(\d+)$")
XOR_ZERO  = re.compile(r"^\s*xor\s+(" + REGS + r")\s*,\s*(" + REGS + r")\s*;")
OKANN     = re.compile(r"//.*\[cap-descriptor-ok:\s*(\S[^\]]*)\]")

PRUNE = {".git", "paideia-as", "build", "target", "node_modules"}
WINDOW = 80
ZERO_LOOKBACK = 40

MINT_REL = "src/kernel/core/cap/mint.pdx"

# 1. Classify every cap_table base site (same rules as [cap-stride]).
sites = []
filelines = {}
for sub in ("src", "tests"):
    root_dir = os.path.join(ROOT, sub)
    if not os.path.isdir(root_dir):
        continue
    for root, dirs, files in os.walk(root_dir):
        dirs[:] = [d for d in dirs if d not in PRUNE]
        for fn in sorted(files):
            if not fn.endswith(".pdx"):
                continue
            path = os.path.join(root, fn)
            rel  = os.path.relpath(path, ROOT)
            raw = open(path, encoding="utf-8", errors="replace").read().split("\n")
            lines = [l.split("//")[0] for l in raw]
            filelines[rel] = (lines, raw)
            for i, line in enumerate(lines):
                m = BASE.search(line)
                if not m:
                    continue
                reg = m.group(1)
                win = "\n".join(lines[max(0, i - 6): i + 10])
                shls = sorted(a for _, a in SHL.findall(win))
                if shls == ["3", "4"]:
                    sites.append((rel, i, reg, "V", None))
                    continue
                nxt = lines[i + 1] if i + 1 < len(lines) else ""
                am = re.search(r"add\s+" + reg + r"\s*,\s*(\d+)\s*;", nxt)
                if not shls and am:
                    off = int(am.group(1))
                    if off % 24 == 0 and off // 24 < 256:
                        sites.append((rel, i, reg, "C", off))
                    continue
                if not shls and not am:
                    sites.append((rel, i, reg, "Z", 0))

# 2. Walk each site forward. For every MEM_WRITE at (offset % 24 == 16)
#    through the tracked base, classify as allowed or stray.
def is_zero_source(lines, j, src):
    """A write `mov [reg + 16], <src>` is a zero-clear if <src> is the
    immediate 0, or a register just xor'd against itself within the
    preceding ZERO_LOOKBACK lines and not overwritten since."""
    if src == "0":
        return True
    if not re.fullmatch(REGS, src):
        return False
    for k in range(j - 1, max(-1, j - 1 - ZERO_LOOKBACK), -1):
        l = lines[k]
        if not l.strip():
            continue
        xz = XOR_ZERO.match(l)
        if xz and xz.group(1) == src and xz.group(2) == src:
            return True
        # An overwrite of src between here and the write kills the
        # zero-source claim.
        km = KILL.match(l)
        if km and km.group(1) == src:
            return False
    return False

mint_writes = 0
zero_clears = 0
annotated   = 0
strays = []

for rel, i, reg, form, cbase in sites:
    lines, raw = filelines[rel]
    tracked = {reg}
    for j in range(i + 1, min(len(lines), i + WINDOW)):
        l = lines[j]
        if not l.strip():
            continue
        if LABEL.match(l):
            break
        if re.search(r"\bcall\b", l) or re.search(r"\bret\b", l) or re.match(r"^\s*\}", l):
            break

        wm = MEM_WRITE.match(l)
        if wm and wm.group(1) in tracked:
            expr = wm.group(2).strip()
            src  = wm.group(3)
            om = OFFSET.match(expr) if expr else None
            if not expr:
                off = 0
            elif om:
                off = int(om.group(1))
            else:
                # Register-indexed write through a cap_table base — the
                # [cap-stride] gate flags this if unannotated, so we do
                # not double-report it here.
                off = None
            if off is not None and (off % 24) == 16:
                raw_line = raw[j] if j < len(raw) else ""
                if OKANN.search(raw_line):
                    annotated += 1
                elif rel == MINT_REL:
                    mint_writes += 1
                elif is_zero_source(lines, j, src):
                    zero_clears += 1
                else:
                    strays.append((rel, j + 1, f"mov [{wm.group(1)}"
                                              f"{(' ' + expr) if expr else ''}], {src}"))

        mm = MOVREG.match(l)
        if mm:
            dst, src = mm.group(1), mm.group(2)
            if src in tracked:
                tracked.add(dst)
            elif dst in tracked:
                tracked.discard(dst)
            if not tracked:
                break
            continue

        am2 = ADDREG.match(l)
        if am2 and am2.group(1) in tracked:
            if re.match(r"^\d+$", am2.group(2)):
                tracked.discard(am2.group(1))
            if not tracked:
                break
            continue

        km = KILL.match(l)
        if km and km.group(1) in tracked:
            tracked.discard(km.group(1))
            if not tracked:
                break

if strays:
    print(f"{TAG} FAIL — {len(strays)} stray target_ptr writer(s):", file=sys.stderr)
    for rel, ln, txt in strays:
        print(f"    STRAY WRITER: {rel}:{ln}    {txt}", file=sys.stderr)
    print("", file=sys.stderr)
    print("  cap_mint_write is the SOLE non-zero writer of the +16 target_ptr", file=sys.stderr)
    print("  field. A stray write here retargets a LIVE capability without", file=sys.stderr)
    print("  changing its kind or rights, so every downstream kind-check passes", file=sys.stderr)
    print("  and the corruption presents at the object end. Zero-clearing", file=sys.stderr)
    print("  writes (revoke / free paths) are allowed anywhere; move the write", file=sys.stderr)
    print("  into cap_mint_write, or clear via an xor-zeroed register.", file=sys.stderr)
    print("  If the write is genuinely correct (test-fixture seeder that", file=sys.stderr)
    print("  intentionally bypasses the mint path), annotate the line:", file=sys.stderr)
    print("      mov [rax + 16], rcx;   // [cap-descriptor-ok: <reason>]", file=sys.stderr)
    sys.exit(1)

# Vacuity guard: the gate must have SEEN the legitimate writer at least
# once, otherwise a rename or a refactor has moved the mint writes out of
# the recognised idiom and this gate is passing on a scan that inspected
# nothing.
if mint_writes < 1:
    print(f"{TAG} FAIL — vacuous scan: cap_mint_write's target_ptr write not",
          file=sys.stderr)
    print(f"  observed at {MINT_REL}. The gate is passing without checking",
          file=sys.stderr)
    print("  anything — the same failure mode the [cap-stride] vacuity guards",
          file=sys.stderr)
    print("  catch, one level down. If cap_mint_write legitimately moved,",
          file=sys.stderr)
    print("  update MINT_REL here and re-baseline in the same commit.",
          file=sys.stderr)
    sys.exit(1)

print(f"{TAG} descriptor writes confined "
      f"({mint_writes} cap_mint_write, {zero_clears} zero-clears, "
      f"{annotated} annotated)")
PYEOF
