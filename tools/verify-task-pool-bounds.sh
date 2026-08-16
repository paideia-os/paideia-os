#!/usr/bin/env bash
# R31.M2-1594 (#1594) — task-pool geometry gate.
#
# WHAT THIS POLICES
#
# The task pool is addressed by STRIDE and was sized by STRUCT, and those
# are different numbers:
#
#     _task_pool : [u64; 17792]        142336 bytes  (= 64 * 2224, the STRUCT)
#     task_new   : slab = base + (pid-1) * 4096      (the STRIDE)
#     pid_alloc  : hands out pid up to 63
#
# 142336 / 4096 = 34.75. pid 35 was the last whose 2224-byte construction
# landed fully inside the array. pid 36 began 1024 bytes past its end, and
# every pid from 36 to 63 wrote a complete task_struct into whatever the
# linker had placed next — `_task_kernel_stacks`, i.e. other tasks' kernel
# stacks. Nothing noticed for ~53 iterations because the boot path uses four
# pids, and it was getting closer: 12768dc moved init's children to pid 4.
#
# The defect is not the wrong literal. It is that the SIZE and the CEILING
# were independent literals with no relation between them that anything
# checked, so they could disagree and did. Fixing the literal without
# installing the relation leaves the tree one stride change away from the
# same bug — and a stride change is exactly the kind of edit that looks
# local.
#
# WHY A GATE AND NOT A CONSTANT
#
# The natural fix — `[u64; MAX_PIDS * TASK_SLOT_BYTES / 8]` — does not
# compile. paideia-as (4d0e7b3) requires an array length to be an integer
# LITERAL: crates/paideia-as/src/cmd_build/layout.rs
# `compute_bss_size_from_type` bails to 8 for any length node that is not
# `ExprLiteral`. An arithmetic length would therefore not fail the build; it
# would produce an EIGHT-BYTE `_task_pool`, which is the same defect several
# orders of magnitude worse. So the derivation cannot live in the type, and
# it lives here instead: the constants in task_pool.pdx are the source, this
# script recomputes from them, and the build stops if the declared literal
# has drifted.
#
# WHAT IT CHECKS
#
#   [geometry]   the constants are internally consistent (shift vs stride,
#                qwords vs bytes, struct fits in slot, PID_MAX = MAX_PIDS-1)
#   [pool-size]  THE ASSERTION: pool bytes >= MAX_PIDS * TASK_SLOT_BYTES,
#                and the declared array literal equals TASK_POOL_QWORDS
#   [pid-tables] _pid_table and _pid_gen are MAX_PIDS entries
#   [ceilings]   every pid bound in task_pool.pdx is MAX_PIDS, and
#                task_slab_of_pid shifts by TASK_SLOT_SHIFT
#   [fill-width] every rep_stosq in task_pool.pdx zeroes TASK_STRUCT_QWORDS
#   [struct-full] max(TASK_OFF_*) + 8 <= TASK_STRUCT_BYTES, so a new TCB
#                field above the zero-filled region fails the build
#   [slab-inventory] the standalone (non-pool) task slabs are all exactly
#                TASK_STRUCT_QWORDS, because task_free zero-fills through
#                whatever pointer it is handed
#   [sibling-arrays] the other two pid-indexed arrays (_task_kernel_stacks,
#                _task_xsave_areas) are also sized against MAX_PIDS
#
# A VACUITY GUARD fires if any constant or declaration the script depends on
# cannot be found. A gate that silently stops looking is the failure mode
# this whole class of check exists to prevent.
#
# Exit 0 = geometry consistent. Exit 1 = divergence (build must stop).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

python3 - "${REPO_ROOT}" <<'PYEOF'
import os, re, sys

ROOT = sys.argv[1]
TAG  = "[task-pool-bounds]"

failures = []
notes    = []

def fail(msg):
    failures.append(msg)

def read(rel):
    p = os.path.join(ROOT, rel)
    try:
        with open(p, "r", encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        fail("cannot read %s: %s" % (rel, e))
        return ""

TASK_POOL_REL = "src/kernel/core/sched/task_pool.pdx"
XSAVE_REL     = "src/kernel/core/cpu/xsave.pdx"

task_pool = read(TASK_POOL_REL)
xsave     = read(XSAVE_REL)

if not task_pool:
    print("%s FAIL — %s is empty or unreadable; the gate would pass vacuously."
          % (TAG, TASK_POOL_REL), file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Constant extraction. `pub let NAME : u64 = <int>`
# ---------------------------------------------------------------------------
def consts_of(text):
    out = {}
    for m in re.finditer(r"pub\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*u64\s*=\s*(\d+)", text):
        out[m.group(1)] = int(m.group(2))
    return out

TP = consts_of(task_pool)
XS = consts_of(xsave)

REQUIRED = ["MAX_PIDS", "PID_MAX", "TASK_SLOT_SHIFT", "TASK_SLOT_BYTES",
            "TASK_STRUCT_QWORDS", "TASK_STRUCT_BYTES", "TASK_POOL_QWORDS",
            "KSTACK_BYTES_PER_TASK", "KSTACK_QWORDS_PER_TASK"]
missing = [k for k in REQUIRED if k not in TP]
if missing:
    print("%s FAIL — constants not found in %s: %s" % (TAG, TASK_POOL_REL, ", ".join(missing)),
          file=sys.stderr)
    print("  These constants ARE the geometry. If they were renamed, this gate stopped",
          file=sys.stderr)
    print("  checking anything and must be updated in the same commit that renamed them.",
          file=sys.stderr)
    sys.exit(1)

MAX_PIDS    = TP["MAX_PIDS"]
PID_MAX     = TP["PID_MAX"]
SLOT_SHIFT  = TP["TASK_SLOT_SHIFT"]
SLOT_BYTES  = TP["TASK_SLOT_BYTES"]
STRUCT_QW   = TP["TASK_STRUCT_QWORDS"]
STRUCT_B    = TP["TASK_STRUCT_BYTES"]
POOL_QW     = TP["TASK_POOL_QWORDS"]
KSTACK_B    = TP["KSTACK_BYTES_PER_TASK"]
KSTACK_QW   = TP["KSTACK_QWORDS_PER_TASK"]

# ---------------------------------------------------------------------------
# Array-length extraction. `pub let mut NAME : [u64; N] = uninit`
# ---------------------------------------------------------------------------
def array_lens(text):
    out = {}
    for m in re.finditer(
            r"let\s+mut\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\[\s*u64\s*;\s*(\d+)\s*\]", text):
        out[m.group(1)] = int(m.group(2))
    return out

TP_ARR = array_lens(task_pool)
XS_ARR = array_lens(xsave)

# ---------------------------------------------------------------------------
# [geometry] — the constants must be internally consistent.
# ---------------------------------------------------------------------------
if (1 << SLOT_SHIFT) != SLOT_BYTES:
    fail("TASK_SLOT_SHIFT=%d implies stride %d, but TASK_SLOT_BYTES=%d.\n"
         "  task_slab_of_pid shifts; every size argument multiplies. They must agree."
         % (SLOT_SHIFT, 1 << SLOT_SHIFT, SLOT_BYTES))

if STRUCT_QW * 8 != STRUCT_B:
    fail("TASK_STRUCT_QWORDS=%d is %d bytes, but TASK_STRUCT_BYTES=%d.\n"
         "  The rep_stosq counts qwords and the layout doc counts bytes."
         % (STRUCT_QW, STRUCT_QW * 8, STRUCT_B))

if STRUCT_B > SLOT_BYTES:
    fail("TASK_STRUCT_BYTES=%d exceeds TASK_SLOT_BYTES=%d — consecutive slabs overlap."
         % (STRUCT_B, SLOT_BYTES))

if PID_MAX != MAX_PIDS - 1:
    fail("PID_MAX=%d but MAX_PIDS=%d. _pid_table and _pid_gen are indexed BY PID with\n"
         "  pid 0 reserved, so the highest allocatable pid is MAX_PIDS-1 = %d."
         % (PID_MAX, MAX_PIDS, MAX_PIDS - 1))

# ---------------------------------------------------------------------------
# [pool-size] — THE ASSERTION. This is #1594.
# ---------------------------------------------------------------------------
need_bytes = MAX_PIDS * SLOT_BYTES
have_bytes = POOL_QW * 8

if have_bytes < need_bytes:
    fail("TASK_POOL_QWORDS=%d is %d bytes; MAX_PIDS(%d) * TASK_SLOT_BYTES(%d) = %d.\n"
         "  The pool holds %.2f slots and pid_alloc hands out %d. Every pid above %d\n"
         "  forms a slab address past the end of the array, and task_new writes %d\n"
         "  bytes through it into whatever the linker placed next.\n"
         "  Size the array from the SLOT, never from the struct: the addressing strides\n"
         "  by the slot. (Xsave._task_xsave_areas gets this right — 65 * 512.)"
         % (POOL_QW, have_bytes, MAX_PIDS, SLOT_BYTES, need_bytes,
            have_bytes / float(SLOT_BYTES), PID_MAX,
            have_bytes // SLOT_BYTES, STRUCT_B))

if "_task_pool" not in TP_ARR:
    fail("_task_pool declaration not found in %s — the gate cannot see the array it exists\n"
         "  to bound." % TASK_POOL_REL)
elif TP_ARR["_task_pool"] != POOL_QW:
    fail("_task_pool is declared [u64; %d] but TASK_POOL_QWORDS=%d.\n"
         "  paideia-as needs a literal length, so the two cannot be the same token; this\n"
         "  check is what keeps them the same NUMBER. Set the array length to %d."
         % (TP_ARR["_task_pool"], POOL_QW, POOL_QW))

# ---------------------------------------------------------------------------
# [pid-tables] — the pid-indexed side tables are MAX_PIDS entries.
# ---------------------------------------------------------------------------
for name in ("_pid_table", "_pid_gen"):
    if name not in TP_ARR:
        fail("%s declaration not found in %s." % (name, TASK_POOL_REL))
    elif TP_ARR[name] != MAX_PIDS:
        fail("%s is declared [u64; %d] but MAX_PIDS=%d. These are indexed BY PID; a table\n"
             "  shorter than the ceiling is an out-of-bounds read on the allocator itself."
             % (name, TP_ARR[name], MAX_PIDS))

# ---------------------------------------------------------------------------
# [ceilings] — every pid bound in task_pool.pdx is MAX_PIDS.
#
# Function-scoped so the message can name the offending function. Each bound
# is a `cmp rXX, <n>` followed by a `jae`; `ja` is the #740 fencepost and is
# rejected here too, in this file only (the sys_exit / sys_wait scanners are
# #1585's territory and are not touched).
# ---------------------------------------------------------------------------
def function_body(text, name):
    m = re.search(r"pub\s+let\s+" + re.escape(name) + r"\s*:", text)
    if not m:
        return None
    nxt = re.search(r"\n  pub\s+let\s", text[m.end():])
    return text[m.start(): m.end() + (nxt.start() if nxt else len(text))]

BOUNDED = ["pid_alloc", "pid_gen_read", "pid_gen_bump", "task_slab_of_pid"]
for fn in BOUNDED:
    body = function_body(task_pool, fn)
    if body is None:
        fail("function %s not found in %s — it carries a pid bound this gate pins."
             % (fn, TASK_POOL_REL))
        continue
    cmps = re.findall(r"cmp\s+r[a-z0-9]+\s*,\s*(\d+)\s*;\s*(?://[^\n]*)?\n\s*(j\w+)", body)
    ceil = [(int(v), j) for (v, j) in cmps if int(v) == MAX_PIDS or int(v) > MAX_PIDS // 2]
    if not ceil:
        fail("%s contains no pid ceiling comparison against MAX_PIDS(%d).\n"
             "  Either the bound was removed — which is the #1594 defect returning — or the\n"
             "  idiom changed and this gate stopped checking it."
             % (fn, MAX_PIDS))
        continue
    for (val, jmp) in ceil:
        if val != MAX_PIDS:
            fail("%s bounds pid at %d but MAX_PIDS=%d." % (fn, val, MAX_PIDS))
        if jmp != "jae":
            fail("%s uses `%s` on its pid ceiling; it must be `jae`. `ja` admits pid == the\n"
                 "  bound, which reads one entry past a [u64; %d] table (the #740 fencepost)."
                 % (fn, jmp, MAX_PIDS))

slab_body = function_body(task_pool, "task_slab_of_pid")
if slab_body is not None:
    shifts = re.findall(r"shl\s+r[a-z0-9]+\s*,\s*(\d+)", slab_body)
    if not shifts:
        fail("task_slab_of_pid contains no `shl` — the pid->slab stride is no longer a shift,\n"
             "  so TASK_SLOT_SHIFT no longer describes the addressing this gate is bounding.")
    for s in shifts:
        if int(s) != SLOT_SHIFT:
            fail("task_slab_of_pid shifts by %s but TASK_SLOT_SHIFT=%d (stride %d).\n"
                 "  A stride change that does not resize _task_pool is exactly #1594."
                 % (s, SLOT_SHIFT, SLOT_BYTES))
    if re.search(r"cmp\s+rdi\s*,\s*0\s*;\s*(?://[^\n]*)?\n\s*je", slab_body) is None:
        fail("task_slab_of_pid does not refuse pid 0. `jae MAX_PIDS` alone admits it, and\n"
             "  (0-1) << %d = 0x%X puts the slab one slot BELOW the pool base."
             % (SLOT_SHIFT, (((1 << 64) - 1) << SLOT_SHIFT) & ((1 << 64) - 1)))

# ---------------------------------------------------------------------------
# [fill-width] — every rep_stosq in task_pool.pdx zeroes TASK_STRUCT_QWORDS.
# ---------------------------------------------------------------------------
lines = task_pool.split("\n")
stosq_idx = [i for i, l in enumerate(lines) if re.match(r"^\s*rep_stosq\s*;?\s*(//.*)?$", l)]
if not stosq_idx:
    fail("no rep_stosq found in %s — task_new/task_free no longer zero the slab through the\n"
         "  idiom this gate measures." % TASK_POOL_REL)
for i in stosq_idx:
    cnt = None
    for j in range(i - 1, max(i - 8, -1), -1):
        m = re.search(r"mov\s+rcx\s*,\s*(\d+)\s*;", lines[j])
        if m:
            cnt = int(m.group(1))
            break
    if cnt is None:
        fail("rep_stosq at %s:%d has no `mov rcx, <n>` within 8 lines above it; the fill width\n"
             "  cannot be checked." % (TASK_POOL_REL, i + 1))
    elif cnt != STRUCT_QW:
        fail("rep_stosq at %s:%d zeroes %d qwords but TASK_STRUCT_QWORDS=%d.\n"
             "  The fill covers the STRUCT, not the SLOT — widening it to the slot would\n"
             "  overrun every standalone [u64; %d] slab task_free can be handed."
             % (TASK_POOL_REL, i + 1, cnt, STRUCT_QW, STRUCT_QW))

# ---------------------------------------------------------------------------
# [struct-full] — no TCB field above the zero-filled region.
#
# sys_fork.pdx pins TASK_OFF_LANDING_RA at +2216, the last qword of the slab.
# A field added above TASK_STRUCT_BYTES would be written by whoever added it
# and zeroed by nobody, so a recycled slot would hand a fresh task the dead
# occupant's bytes through it — the exact leak class this round is closing.
# ---------------------------------------------------------------------------
max_off, max_name, max_file = -1, None, None
n_offsets = 0
for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, "src", "kernel")):
    for fn in filenames:
        if not fn.endswith(".pdx"):
            continue
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, ROOT)
        try:
            with open(p, "r", encoding="utf-8") as f:
                body = f.read()
        except OSError:
            continue
        for m in re.finditer(r"pub\s+let\s+(TASK_OFF_[A-Z0-9_]+)\s*:\s*u64\s*=\s*(\d+)", body):
            n_offsets += 1
            off = int(m.group(2))
            if off > max_off:
                max_off, max_name, max_file = off, m.group(1), rel

if n_offsets < 5:
    fail("only %d TASK_OFF_* constants found across src/kernel — the extractor has stopped\n"
         "  matching and the struct-extent check is vacuous." % n_offsets)
elif max_off + 8 > STRUCT_B:
    fail("%s = %d (in %s) puts a TCB field at [%d, %d) but TASK_STRUCT_BYTES=%d.\n"
         "  task_new zeroes only %d bytes, so this field is never initialised on a recycled\n"
         "  slot. Either the field belongs lower in the slab, or TASK_STRUCT_BYTES and every\n"
         "  standalone slab must grow together."
         % (max_name, max_off, max_file, max_off, max_off + 8, STRUCT_B, STRUCT_B))
else:
    notes.append("struct extent: highest field %s = +%d, fits in %d bytes with %d to spare"
                 % (max_name, max_off, STRUCT_B, STRUCT_B - (max_off + 8)))

# ---------------------------------------------------------------------------
# [slab-inventory] — the standalone task slabs.
#
# task_free zero-fills TASK_STRUCT_QWORDS through whatever pointer it is
# handed. Every one of these is a task_struct that does NOT live in the pool
# and therefore has no slot padding: a fill wider than the struct overruns
# straight into the next .bss object. Pinned by name so that (a) raising
# TASK_STRUCT_QWORDS fails here until they are all resized, and (b) a new
# standalone slab cannot be added at a stale width.
# ---------------------------------------------------------------------------
STANDALONE_SLABS = [
    ("src/kernel/core/sched/idle.pdx",        "_idle_task_slot"),
    ("src/kernel/core/sched/tasks.pdx",       "_sched_witness_boot_tcb"),
    ("src/kernel/core/sched/tasks.pdx",       "_sched_witness_task_a_tcb"),
    ("src/kernel/core/sched/tasks.pdx",       "_sched_witness_task_b_tcb"),
    ("src/kernel/core/sched/tasks.pdx",       "_preempt_witness_task_a_tcb"),
    ("src/kernel/core/sched/tasks.pdx",       "_preempt_witness_task_b_tcb"),
    ("src/kernel/core/driver/chaos.pdx",      "_drv_chaos_fake_tcb"),
    ("src/kernel/boot/kernel_main.pdx",       "_fd_witness_task"),
    ("src/kernel/boot/kernel_main.pdx",       "_sys_open_witness_task"),
    ("src/kernel/boot/kernel_main.pdx",       "_sys_close_witness_task"),
    ("src/kernel/boot/kernel_main.pdx",       "_sys_read_witness_task"),
    ("src/kernel/boot/kernel_main.pdx",       "_sys_write_witness_task"),
    ("src/kernel/boot/kernel_main.pdx",       "_sys_dup2_witness_task"),
    ("src/kernel/boot/kernel_main.pdx",       "_tty_connect_witness_task"),
    ("src/kernel/boot/kernel_main.pdx",       "_r29_restart_wit_fake_tcb"),
    ("src/kernel/boot/kernel_main.pdx",       "_sys_ipc_send_witness_fake_tcb"),
    ("tests/kernel/driver/death_witness.pdx", "_pdw_tcb"),
    ("tests/kernel/driver/death_witness.pdx", "_pdw_client"),
]

file_cache = {}
def cached(rel):
    if rel not in file_cache:
        file_cache[rel] = read(rel)
    return file_cache[rel]

pinned = set()
for rel, sym in STANDALONE_SLABS:
    body = cached(rel)
    m = re.search(r"let\s+mut\s+" + re.escape(sym) + r"\s*:\s*\[\s*u64\s*;\s*(\d+)\s*\]", body)
    if not m:
        fail("standalone slab %s not found in %s.\n"
             "  Either it was removed (drop it from STANDALONE_SLABS in this script) or it was\n"
             "  renamed, in which case the width pin silently stopped applying to it."
             % (sym, rel))
        continue
    pinned.add(sym)
    n = int(m.group(1))
    if n != STRUCT_QW:
        fail("%s in %s is [u64; %d] but TASK_STRUCT_QWORDS=%d.\n"
             "  task_free rep_stosq's %d qwords through any task pointer it is given; a slab\n"
             "  narrower than that is overrun, and one wider is silently under-zeroed."
             % (sym, rel, n, STRUCT_QW, STRUCT_QW))

# Extras: any [u64; TASK_STRUCT_QWORDS] declaration not on the list. Either it
# is a task slab that must be pinned, or it is a coincidence that must be
# renamed or the list widened — both are decisions, and neither is silence.
extras = []
for base in ("src/kernel", "tests/kernel"):
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, base)):
        for fn in filenames:
            if not fn.endswith(".pdx"):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            try:
                with open(p, "r", encoding="utf-8") as f:
                    body = f.read()
            except OSError:
                continue
            for m in re.finditer(
                    r"let\s+mut\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*\[\s*u64\s*;\s*"
                    + str(STRUCT_QW) + r"\s*\]", body):
                if m.group(1) not in pinned:
                    extras.append((rel, m.group(1)))
if extras:
    fail("declaration(s) sized [u64; %d] that this gate does not pin:\n%s\n"
         "  A %d-qword u64 array is a task_struct slab by every appearance. If it is one, add\n"
         "  it to STANDALONE_SLABS so a future TASK_STRUCT_QWORDS change resizes it too. If it\n"
         "  genuinely is not, say so where it is declared and widen this check."
         % (STRUCT_QW, "\n".join("    %s: %s" % e for e in extras), STRUCT_QW))

# ---------------------------------------------------------------------------
# [sibling-arrays] — the other two pid-indexed arrays.
#
# Same defect class, same constant. _task_kernel_stacks is indexed
# base + (pid-1)*KSTACK_BYTES_PER_TASK with the TOP at base + pid*K, so pid
# PID_MAX needs PID_MAX whole blocks. _task_xsave_areas is indexed BY PID
# directly, so pid PID_MAX needs MAX_PIDS slots.
# ---------------------------------------------------------------------------
if KSTACK_QW * 8 != KSTACK_B:
    fail("KSTACK_QWORDS_PER_TASK=%d is %d bytes but KSTACK_BYTES_PER_TASK=%d."
         % (KSTACK_QW, KSTACK_QW * 8, KSTACK_B))

if "_task_kernel_stacks" not in TP_ARR:
    fail("_task_kernel_stacks declaration not found in %s." % TASK_POOL_REL)
else:
    have = TP_ARR["_task_kernel_stacks"] * 8
    need = PID_MAX * KSTACK_B
    if have < need:
        fail("_task_kernel_stacks is %d bytes; pid %d needs its top at base + %d.\n"
             "  kstack_top(pid) = base + pid*%d, so the array must cover PID_MAX whole blocks."
             % (have, PID_MAX, need, KSTACK_B))

if not xsave:
    fail("cannot read %s — the XSAVE sibling-array check is vacuous." % XSAVE_REL)
else:
    xs_slot = XS.get("XSAVE_AREA_SLOT_BYTES")
    if xs_slot is None:
        fail("XSAVE_AREA_SLOT_BYTES not found in %s." % XSAVE_REL)
    elif "_task_xsave_areas" not in XS_ARR:
        fail("_task_xsave_areas declaration not found in %s." % XSAVE_REL)
    else:
        have = XS_ARR["_task_xsave_areas"] * 8
        need = MAX_PIDS * xs_slot
        if have < need:
            fail("_task_xsave_areas is %d bytes; xsave_area_for indexes BY PID at stride %d,\n"
                 "  so pid %d needs %d. xsave_area_for has no bound of its own — its own\n"
                 "  justification says 'any pid > 64 walks off the array' — so this array's\n"
                 "  size IS its bound." % (have, xs_slot, PID_MAX, need))

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if failures:
    print("%s FAIL" % TAG, file=sys.stderr)
    for f in failures:
        print("  * %s" % f, file=sys.stderr)
    print("", file=sys.stderr)
    print("  The geometry constants live in %s and are the single source." % TASK_POOL_REL,
          file=sys.stderr)
    print("  See design/kernel/r31-m2-1594-task-pool-sizing.md.", file=sys.stderr)
    sys.exit(1)

print("%s pool %d B >= MAX_PIDS(%d) * stride(%d) = %d B; %d slots for pids 1..%d"
      % (TAG, have_bytes, MAX_PIDS, SLOT_BYTES, need_bytes, have_bytes // SLOT_BYTES, PID_MAX))
print("%s %d pid bounds, %d rep_stosq fills at %d qwords, %d standalone slabs pinned"
      % (TAG, len(BOUNDED), len(stosq_idx), STRUCT_QW, len(pinned)))
for n in notes:
    print("%s %s" % (TAG, n))
PYEOF
