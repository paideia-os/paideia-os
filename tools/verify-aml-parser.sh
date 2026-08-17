#!/usr/bin/env bash
# tools/verify-aml-parser.sh — R30.M1-001 (#1049) / R30.M1-002 (#1050)
#                              R30.M2-003/004 (#1056 / #1057)
#                              R30.M1-003/004/005 (#1051 / #1052 / #1053)
#                              R30.M2-001/002 (#1054 / #1055)
#                              R30.M3-002 (#1062)
#                              R30.M3-003/004/005 (#1063 / #1064 / #1065)
#
# Build-time verification of the userspace AML tokenizer, namespace parser
# and evaluator. Wired into `.githooks/pre-push` as the `aml-parser` step, in the
# same slot and the same style as tools/verify-elaborator-negatives.sh.
#
# WHY BUILD-TIME AND NOT A BOOT WITNESS
# ------------------------------------
# At R30.M1 there is no runtime path that hands a DSDT to this code — the
# acpi_supervisor process does not yet receive one, and the KIND_ACPI
# mapping is not exposed to ring 3. A QEMU witness could therefore only
# assert that the objects link, which the ordinary build already proves.
# What IS worth asserting is behaviour, and the tokenizer and parser are
# pure computation over a byte buffer (no syscalls, no MMIO, no
# capabilities), so the very same paideia-as-emitted machine code links
# against a native SysV harness and runs against a real corpus. That is
# strictly more evidence than a dormant boot path, so this check is wired
# build-time rather than as an invented runtime witness.
#
# WHAT IT CHECKS
# --------------
#   1. PLACEMENT. No AML source under src/kernel/**. This is belt and
#      braces alongside tools/lint-no-kernel-aml.sh: that script polices
#      identifiers, this one polices files.
#
#   2. COMPILATION. All thirteen modules build with the pinned paideia-as.
#
#   3. STORAGE ENCAPSULATION. Checked with `objdump -r`, which is the only
#      way to prove it mechanically: a module's private .bss must be
#      relocated against from that module's object and NO OTHER. Namely
#      `aml_lex_state` only from aml_lex.o, the four arena arrays only
#      from aml_arena.o, and `aml_optab` only from aml_optab.o.
#
#      This is not tidiness. The lexer's bounds-check invariant is that
#      EVERY read of the untrusted AML buffer goes through aml_lex_u8 or
#      aml_lex_peek_u8, both of which compare pos against len before
#      forming an address. That invariant holds only for as long as no
#      other module can reach the buffer pointer, and the buffer pointer
#      lives in aml_lex_state. A future issue that "just peeks" at the
#      state from the parser would quietly void the guarantee; this check
#      fails the push instead.
#
#      #1054 added aml_eval.o, whose state carries the fuel and depth
#      counters and the frame pool, so it gets its own assertion — the
#      termination and frame-isolation guarantees both rest on single
#      ownership. #1051/#1052/#1053/#1055 added aml_term.o,
#      aml_resource.o and aml_arith.o with NO private storage of their
#      own, so those needed no new assertion — but adding them to MODULES makes the three existing
#      assertions strictly stronger, because they now also prove that
#      the term parser and the resource decoder cannot reach the lexer
#      cursor, the arenas or the opcode table except through the
#      accessor API. A module added here without storage still gets
#      policed; a module added with storage must extend the checks
#      below.
#
#   3b. PORT I/O CONFINEMENT (#1063). Every `in` and `out` in the emitted
#      machine code must lie inside aml_region_port_in or
#      aml_region_port_out. The corpus deliberately performs no real port
#      I/O, so this static check is where the claim is made; it comes
#      with a vacuity guard requiring those two functions to actually
#      contain port instructions.
#
#   3c. THE EC GATE IS CLOSED (#1065). No object may relocate against
#      aml_region_ec_backing_set. True today because R31's EC driver does
#      not exist, which makes "the transaction is gated" a build-time
#      fact. R31 must update this check.
#
#   4. THE CORPUS. tests/user/aml/aml_harness.c is compiled against the
#      objects and run. Every fixture is loaded so its last byte abuts a
#      PROT_NONE guard page, so an out-of-bounds read is a SIGSEGV rather
#      than a silent over-read; the harness first proves that trap is
#      armed, then runs the well-formed and malformed corpora.
#
# Standalone-runnable:
#
#   $ bash tools/verify-aml-parser.sh
#   [aml-parser] placement: no AML sources under src/kernel/**
#   [aml-parser] compiled 13 module(s)
#   [aml-parser] encapsulation: aml_lex_state confined to aml_lex.o
#   [aml-parser] encapsulation: arena storage confined to aml_arena.o
#   [aml-parser] encapsulation: aml_optab confined to aml_optab.o
#   [aml-parser] encapsulation: evaluator state confined to aml_eval.o
#   [aml-parser] encapsulation: object arena confined to aml_obj.o
#   [aml-parser] encapsulation: aml_conv_tab confined to aml_str.o
#   [aml-parser] encapsulation: notify ring confined to aml_ctl.o
#   [aml-parser] encapsulation: serialized-method mutex pool confined to aml_ctl.o
#   [aml-parser] encapsulation: region binding table confined to aml_region.o
#   [aml-parser] encapsulation: EC gate state confined to aml_region.o
#   [aml-parser] confinement: in/out only in aml_region_port_in/out
#   [aml-parser] EC gate closed: no caller of aml_region_ec_backing_set (R31 opens it)
#   [aml-corpus] NNN assertions PASS
#   [aml-parser] PASS
#
# Exit codes:
#   0 — all checks pass
#   1 — a check failed
#   2 — the environment is unusable (no paideia-as, no C compiler)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
AML_SRC="${REPO_ROOT}/src/user/aml"
HARNESS="${REPO_ROOT}/tests/user/aml/aml_harness.c"
OUT="${REPO_ROOT}/build/aml"

MODULES=(aml_lex aml_arena aml_optab aml_ns aml_term aml_resource aml_eval aml_arith
         aml_obj aml_str aml_ref aml_ctl aml_region aml_ec aml_glk aml_thermal aml_fan)

# ── environment ──────────────────────────────────────────────────────
PA_BIN="$(bash "${REPO_ROOT}/tools/find-paideia-as.sh")"
if [[ -z "${PA_BIN}" || ! -x "${PA_BIN}" ]]; then
    echo "[aml-parser] cannot locate paideia-as binary" >&2
    exit 2
fi

CC_BIN="${CC:-cc}"
if ! command -v "${CC_BIN}" >/dev/null 2>&1; then
    echo "[aml-parser] no C compiler (${CC_BIN}) — cannot run the corpus" >&2
    exit 2
fi
if ! command -v objdump >/dev/null 2>&1; then
    echo "[aml-parser] objdump not found — cannot check encapsulation" >&2
    exit 2
fi

if [[ ! -f "${HARNESS}" ]]; then
    echo "[aml-parser] missing corpus: ${HARNESS}" >&2
    exit 2
fi

# ── 1. placement ─────────────────────────────────────────────────────
# The no-AML guardrail forbids AML identifiers in the kernel; this
# forbids AML FILES there, which is the failure mode a well-meaning
# refactor would produce.
stray="$(find "${REPO_ROOT}/src/kernel" -type f -name 'aml*' -print 2>/dev/null || true)"
if [[ -n "${stray}" ]]; then
    echo "[aml-parser] FAIL — AML sources found under src/kernel/**:" >&2
    printf '  %s\n' ${stray} >&2
    echo "  AML must never execute in ring 0. See design/acpi/no-aml-in-kernel.md." >&2
    exit 1
fi
echo "[aml-parser] placement: no AML sources under src/kernel/**"

# ── 2. compilation ───────────────────────────────────────────────────
rm -rf "${OUT}"
mkdir -p "${OUT}"
for m in "${MODULES[@]}"; do
    src="${AML_SRC}/${m}.pdx"
    if [[ ! -f "${src}" ]]; then
        echo "[aml-parser] FAIL — missing module: ${src}" >&2
        exit 1
    fi
    if ! "${PA_BIN}" build --emit elf64 "${src}" -o "${OUT}/${m}.o" >"${OUT}/${m}.log" 2>&1; then
        echo "[aml-parser] FAIL — ${m}.pdx did not compile" >&2
        sed 's/^/    /' "${OUT}/${m}.log" >&2
        exit 1
    fi
done
echo "[aml-parser] compiled ${#MODULES[@]} module(s)"

# ── 3. storage encapsulation ─────────────────────────────────────────
# reloc_count <object> <extended-regex>
reloc_count() {
    objdump -r "$1" 2>/dev/null | grep -cE "$2" || true
}

check_confined() {
    local label="$1" owner="$2" pattern="$3"
    local m rc
    if [[ "$(reloc_count "${OUT}/${owner}.o" "${pattern}")" -eq 0 ]]; then
        echo "[aml-parser] FAIL — ${label}: owner ${owner}.o does not reference it" >&2
        echo "  Either the symbol was renamed or the module was gutted; the" >&2
        echo "  encapsulation check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    for m in "${MODULES[@]}"; do
        [[ "${m}" == "${owner}" ]] && continue
        rc="$(reloc_count "${OUT}/${m}.o" "${pattern}")"
        if [[ "${rc}" -ne 0 ]]; then
            echo "[aml-parser] FAIL — ${label}: ${m}.o has ${rc} relocation(s) against it" >&2
            echo "  Only ${owner}.o may touch this storage directly; everything else" >&2
            echo "  must go through the accessor API. See tools/verify-aml-parser.sh" >&2
            echo "  and the invariant note in src/user/aml/aml_lex.pdx." >&2
            objdump -r "${OUT}/${m}.o" | grep -E "${pattern}" | sed 's/^/    /' >&2
            exit 1
        fi
    done
    echo "[aml-parser] encapsulation: ${label}"
}

# Each storage symbol is matched with an explicit right-hand boundary. A
# bare 'aml_node_last' would also match the ACCESSOR aml_node_last_child
# (#1051), which is a function every module may legitimately call, and the
# check would then fail on a caller that touches no storage at all. The
# temptation at that point is to drop the symbol from the list — which
# would stop policing the storage. Anchoring is the fix: it keeps the
# assertion exactly as strong and makes it mean what it says.
END='([^a-zA-Z0-9_]|$)'

check_confined "aml_lex_state confined to aml_lex.o" aml_lex "aml_lex_state${END}"
check_confined "arena storage confined to aml_arena.o" aml_arena \
               "(aml_node_arena|aml_name_arena|aml_u64_arena|aml_arena_state|aml_node_last)${END}"
check_confined "aml_optab confined to aml_optab.o" aml_optab "aml_optab${END}|aml_optab_len${END}"

# R30.M2-001 (#1054). The evaluator's context is the second piece of state in
# this subsystem with a safety invariant attached to single ownership, so it
# gets the same treatment as the lexer cursor.
#
#   aml_eval_state carries the FUEL COUNTER, the DEPTH COUNTER and the frame
#   top. The termination guarantee — a While(One) over firmware-controlled
#   bytes stops rather than hangs — holds only for as long as the counters are
#   decremented exclusively by aml_eval_spend and aml_eval_enter. A module
#   that wrote the fuel slot directly, or that "just topped it up" inside a
#   loop, would void the guarantee with no other symptom than a hang on
#   hardware nobody has yet. This check fails the push instead.
#
#   aml_frame_pool carries every method's Arg and Local slots. Frame ISOLATION
#   — a callee cannot observe or corrupt its caller's locals — is delivered by
#   indexing every access off the CURRENT frame base inside aml_eval.o. Any
#   other object reaching the pool array would be computing frame addresses
#   itself, which is precisely the arithmetic isolation depends on.
#
#   aml_path_buf and aml_path_anc are the namespace walker's scratch. They are
#   confined for a different reason: they are reused across the search rule's
#   repeated probes, so a second writer would corrupt a resolution in flight
#   and produce a WRONG name binding rather than a failure.
#
# aml_arith.o declares no storage at all, so adding it to MODULES costs no new
# assertion and makes all four of these strictly stronger — they now also
# prove the operator implementations reach none of this state except through
# the accessor API.
check_confined "evaluator state confined to aml_eval.o" aml_eval \
               "(aml_eval_state|aml_frame_pool|aml_path_buf|aml_path_anc)${END}"

# R30.M2-003/004 (#1056 / #1057). The OBJECT ARENA is the third piece of state
# with a safety invariant resting on single ownership, and the invariant is the
# same shape as the lexer's.
#
#   aml_obj_table, aml_obj_heap and aml_obj_elem hold every String, Buffer and
#   Package the evaluator has built. EVERY read and write of them is bounds-
#   checked twice — once against the arena's high-water mark and once against
#   the individual object's own recorded length — and both checks live inside
#   aml_obj.o. A module that reached the heap array directly would be computing
#   payload addresses itself, which is exactly the arithmetic that lets an
#   Index() past the end of one Buffer read the next one and return a
#   perfectly plausible byte.
#
#   aml_obj_bind is the map from arena node to current object. It is what makes
#   a store visible WITHOUT mutating the parse tree, so the node arena stays
#   byte-identical across an evaluation and remains valid as the IPC wire
#   format. A second writer here would retype a named object behind the
#   evaluator's back.
#
# aml_str.o and aml_ref.o declare no mutable storage at all, so adding them to
# MODULES costs no new assertion and strengthens every existing one — the
# conversion engine and the reference machinery are now proved unable to reach
# the lexer cursor, the parse arenas, the opcode table, the evaluator context,
# the frame pool or the object arena except through the accessor APIs.
check_confined "object arena confined to aml_obj.o" aml_obj \
               "(aml_obj_state|aml_obj_table|aml_obj_heap|aml_obj_elem|aml_obj_bind)${END}"

# The operand table. Like aml_optab it is READ-ONLY data that is the single
# authority on a decision — here, what type each operator wants in each operand
# position (ACPI 6.5 §19.3.5.5). Its whole value is that the implementations
# and the table cannot disagree, and a second reader with its own copy is
# precisely how they would come to.
check_confined "aml_conv_tab confined to aml_str.o" aml_str \
               "(aml_conv_tab|aml_conv_len)${END}"

# The notification ring (#1059) and the serialized-method mutex pool (#1060).
#
# The ring is the evaluator's only EGRESS and the mutex pool its only
# cross-invocation state, so both are worth one assertion each rather than
# being folded in behind aml_eval.o's.
#
# The ring's guarantee is the accounting identity
#     offered == drained + depth + drops
# and that identity holds only for as long as the three counters move
# together inside aml_notify_enqueue and aml_notify_pop. A second writer --
# an evaluator that "just bumped the drop count" on some other refusal, or a
# supervisor that advanced head without going through pop -- would break it
# with no symptom other than a notification the OS never hears about and
# never learns it missed.
#
# The mutex pool's guarantee is that an acquisition count is incremented in
# exactly one place and decremented in exactly one other, which is what makes
# a recursive serialized method unwind exactly as deep as it nested. A second
# writer here reintroduces the deadlock the recursive acquire exists to
# prevent, or leaks a hold that silently refuses every later acquire in the
# session on SyncLevel grounds.
check_confined "notify ring confined to aml_ctl.o" aml_ctl \
               "(aml_notify_ring|aml_notify_state)${END}"
check_confined "serialized-method mutex pool confined to aml_ctl.o" aml_ctl \
               "(aml_mutex_pool|aml_mutex_state)${END}"

# R30.M3-002 (#1062). THE REGION BINDING TABLE, and this is the most
# consequential assertion in this file.
#
# aml_region_tab holds, per bound OperationRegion, the HOST ADDRESS its
# accesses are performed against. The security property of the whole
# milestone is that such an address exists only as the result of
# aml_region_bind having checked a capability window and having found the
# firmware-declared range contained in it. That property is a property of
# the WRITERS of this table, and it holds only for as long as there is
# exactly one.
#
# A module that reached aml_region_tab directly would be computing a
# host address itself — which is precisely the arithmetic the capability
# check exists to be upstream of. It would not need to be malicious: a
# future issue that "just caches the host base" in the evaluator, or a
# handler for one of the other three address spaces that writes its own
# row, would void the guarantee with no symptom at all until a table
# named an address nobody had granted. This check fails the push instead.
#
# aml_region_state carries the access counter the fuel accounting is
# cross-checked against, for the same reason aml_eval_state is confined:
# a second writer makes the accounting stop meaning anything.
check_confined "region binding table confined to aml_region.o" aml_region \
               "(aml_region_tab|aml_region_state)${END}"

# R30.M3-005 (#1065). The EC gate's storage, for the same reason: word 0
# is the registered transaction entry point, and a second writer could
# open the gate without the EC driver existing.
check_confined "EC gate state confined to aml_region.o" aml_region \
               "(aml_region_ec_state)${END}"

# R30.M7-001/002/003 (#1079 / #1080 / #1081). THE EC DRIVER'S STATE.
#
# aml_ec_state carries THE TWO CLAIMS the whole serialization argument
# rests on — the transaction claim that covers one register handshake,
# and the episode claim that covers a _Qxx dispatch and deliberately
# ADMITS transactions rather than excluding them (see
# design/acpi/embedded-controller.md §4). Both are single-writer
# properties: a second module that cleared xact_busy would let a
# transaction start inside another one's handshake, which corrupts both
# and is exactly the condition the EC has no arbitration for. One that
# wrote the episode depth would void the nesting bound.
#
# It also carries the port binding. A second writer there is a
# transaction against a port the _CRS did not name.
#
# aml_ec_synth and aml_ec_ram are the synthetic controller. They are
# confined for a different and equally load-bearing reason: the corpus
# proves that a read returned THE BYTE IT NAMED, and that claim is worth
# nothing if any module could have written the model behind the
# transaction's back.
check_confined "EC driver state confined to aml_ec.o" aml_ec \
               "(aml_ec_state|aml_ec_synth|aml_ec_ram)${END}"

# R30.M8-001 (#1082). THE GLOBAL LOCK'S STATE.
#
# aml_glk_state carries THE OWNERSHIP DEPTH, and the depth is the whole
# nesting argument. The hardware lock is taken at 0->1 and released at
# 1->0; a second writer that set the depth to 1 would make the next
# release drop a hardware lock this process never took, handing the EC
# to firmware while some other caller is mid-transaction on it. One that
# zeroed the depth mid-episode would make the outer release underflow
# and leave the lock held forever — firmware locked out of its own
# embedded controller until the machine is power-cycled.
#
# It also carries the FACS address and the two PM1 ports. A second
# writer there is a compare-exchange against a guessed address and a
# doorbell delivered to the wrong port, which is to say a doorbell that
# never rings.
#
# aml_glk_facs and aml_glk_smm are the synthetic FACS and the synthetic
# System Management Mode. They are confined for the reason aml_ec_synth
# is, and one reason more. The corpus proves that an adversary which
# mutated the lock word between our read and our write was DETECTED —
# that the compare-exchange failed and we re-derived from the truth. If
# any other object could write either the model or the lock word, the
# detection claim would be worth nothing, because the interference the
# corpus attributes to the injection point could have come from
# anywhere. Single ownership is what makes the adversarial fixture
# evidence rather than decoration.
check_confined "Global Lock state confined to aml_glk.o" aml_glk \
               "(aml_glk_state|aml_glk_facs|aml_glk_smm)${END}"

# ── 3b. R30.M3-003 (#1063): PORT I/O CONFINEMENT ─────────────────────
#
# The SystemIO handler's transaction/logic split rests on `in` and `out`
# existing in exactly two functions — aml_region_port_in and
# aml_region_port_out. Everything else on the port path is shared with
# the memory path and is exercised by the corpus against a synthetic
# backing buffer.
#
# The corpus deliberately performs NO REAL PORT I/O (see the section
# header in tests/user/aml/aml_harness.c: leaning on the ring-3 #GP would
# be evidence that evaporates the moment the harness is run with I/O
# privilege). So the claim "the port path is confined" is asserted HERE
# instead, statically, against the emitted machine code — which is a
# stronger statement than any runtime probe could make, because it covers
# code no fixture happens to reach.
#
# A stray `in`/`out` anywhere else in the AML tree would mean some other
# function performs a bus transaction directly, bypassing the bounds
# check, the fuel spend and the capability-derived binding all at once.
port_io_confined() {
    local m dis fn bad=0
    for m in "${MODULES[@]}"; do
        dis="$(objdump -d --no-show-raw-insn "${OUT}/${m}.o" 2>/dev/null || true)"
        # Walk the disassembly tracking the enclosing symbol, and report
        # any in/out that is not inside one of the two port primitives.
        while IFS= read -r line; do
            case "${line}" in
                *'>:') fn="${line##*<}"; fn="${fn%>:}" ;;
                *$'\t'in' '*|*$'\t'out' '*)
                    if [[ "${fn}" != "aml_region_port_in" &&
                          "${fn}" != "aml_region_port_out" ]]; then
                        echo "[aml-parser] FAIL — port I/O outside the two port primitives:" >&2
                        echo "    ${m}.o  ${fn}:  ${line#*$'\t'}" >&2
                        bad=1
                    fi
                    ;;
            esac
        done <<< "${dis}"
    done
    return "${bad}"
}
if ! port_io_confined; then
    echo "  Only aml_region_port_in and aml_region_port_out may contain in/out." >&2
    echo "  Every other port-path line is shared with the memory path and is" >&2
    echo "  exercised by the corpus; a transaction elsewhere bypasses the" >&2
    echo "  bounds check, the fuel spend and the capability binding at once." >&2
    exit 1
fi
# Vacuity guard: the two primitives must actually CONTAIN port I/O, or
# the check above passes by having nothing to find.
if [[ "$(objdump -d --no-show-raw-insn "${OUT}/aml_region.o" 2>/dev/null \
         | grep -cE $'\t'"(in|out) ")" -lt 6 ]]; then
    echo "[aml-parser] FAIL — the port primitives contain no port I/O;" >&2
    echo "  the confinement check above would pass vacuously." >&2
    exit 1
fi
echo "[aml-parser] confinement: in/out only in aml_region_port_in/out"

# R30.M3-005 (#1065), INVERTED BY R30.M7-001 (#1079). THE EC GATE.
#
# #1065 asserted that NOTHING relocated against aml_region_ec_backing_set,
# which made "the EC transaction is gated" a build-time fact. Its own
# comment said the milestone that landed the driver must update this
# check, because a gate that could be left shut after the hardware
# arrived would be as much of a defect as one opened before it.
#
# R30.M7 lands the driver, so the assertion inverts rather than
# disappearing — and it inverts to something JUST AS STRONG. The
# registration point must have EXACTLY ONE caller, and that caller must
# be aml_ec.o. A second registrant, or a registrant in any other module,
# means something other than the EC driver is deciding what services
# EmbeddedControl accesses — which on a part that owns battery charging
# and fan control is the failure this gate was built for.
ec_owner_refs="$(reloc_count "${OUT}/aml_ec.o" "aml_region_ec_backing_set${END}")"
if [[ "${ec_owner_refs}" -ne 1 ]]; then
    echo "[aml-parser] FAIL — aml_ec.o registers the EC backing ${ec_owner_refs} time(s), expected exactly 1." >&2
    echo "  0 means the driver no longer opens the gate and every EC access" >&2
    echo "  silently returns AML_ERR_REGION_EC_GATED — the subsystem would" >&2
    echo "  look present and do nothing. More than 1 means there are two" >&2
    echo "  registration paths and the last one to run wins." >&2
    echo "  See design/acpi/embedded-controller.md §10." >&2
    exit 1
fi
ec_stray=""
for m in "${MODULES[@]}"; do
    [[ "${m}" == "aml_ec" ]] && continue
    if [[ "$(reloc_count "${OUT}/${m}.o" "aml_region_ec_backing_set${END}")" -ne 0 ]]; then
        ec_stray="${ec_stray} ${m}.o"
    fi
done
if [[ -n "${ec_stray}" ]]; then
    echo "[aml-parser] FAIL — the EC gate is opened outside the driver:${ec_stray}" >&2
    echo "  Only src/user/aml/aml_ec.pdx may register an EC transaction entry." >&2
    exit 1
fi
echo "[aml-parser] EC gate open: aml_ec.o is the sole registrant of aml_region_ec_backing_set"

# R30.M7-001/003 (#1079/#1081). THE EC TRANSACTION SIGNATURE.
#
# THE SIGNATURE IS THE SECURITY ARGUMENT, so it is pinned verbatim
# rather than described in a comment. aml_ec_xact takes an EC-SPACE
# ADDRESS that aml_region derived from the binding row's own offset
# arithmetic — the same confined footing #1075/#1076 put the GPIO pad
# path on. There is no base parameter and no region parameter, and a
# mutant that adds one must fail the BUILD rather than the review:
# an EC write outside the range firmware declared can do things no
# specification describes, on a part that owns battery charging, fan
# control and the lid switch.
#
# aml_ec_query_pump is pinned at ARITY ZERO for the same reason. The
# namespace scope _Qxx resolves in comes from aml_ec_attach, not from
# the caller; a caller-supplied scope would let a query dispatch some
# OTHER device's _Q80, which is the same class of mistake one level up.
pin_signature() {
    local file="$1" sig="$2" why="$3"
    if ! grep -qF -- "${sig}" "${file}"; then
        echo "[aml-parser] FAIL — signature not found verbatim in ${file#"${REPO_ROOT}"/}:" >&2
        echo "    ${sig}" >&2
        echo "  ${why}" >&2
        exit 1
    fi
}
EC_SRC="${AML_SRC}/aml_ec.pdx"
pin_signature "${EC_SRC}" \
    "pub let aml_ec_xact : (u64, u64, u64) -> u64 !{mem} @{} =" \
    "The transaction takes (op, EC-space address, value) and NOTHING ELSE. A base, a region handle or a length parameter here would let a caller name a byte the binding row does not cover. See design/acpi/embedded-controller.md §6.1."
pin_signature "${EC_SRC}" \
    "pub let aml_ec_query_pump : () -> u64 !{mem} @{} =" \
    "The query pump takes NO arguments. The EC's namespace scope comes from aml_ec_attach; a caller-supplied scope would dispatch another device's _Qxx. See design/acpi/embedded-controller.md §6.1."
pin_signature "${EC_SRC}" \
    "pub let aml_ec_attach : (u64, u64, u64) -> u64 !{mem} @{} =" \
    "Both EC ports come from the device's _CRS through this one entry point. If it grew a default, a machine that relocates the EC would be transacted against at 0x62/0x66 anyway."
echo "[aml-parser] signatures pinned: aml_ec_xact / aml_ec_query_pump / aml_ec_attach"

# R30.M8-001 (#1082). THE GLOBAL LOCK'S ARITIES.
#
# aml_glk_enter and aml_glk_leave take NOTHING. The lock they operate on
# is the one aml_glk_attach bound, and there is exactly one Global Lock
# on a machine — it is a platform singleton, not a resource with
# instances. A caller-supplied FACS address here would be the same class
# of defect as the caller-supplied EC base #1081 refused: it would make
# "compare-exchange against a word that is not the platform's lock"
# expressible, and the code that did it would look correct and would
# serialize this process against nothing at all.
#
# aml_glk_leave is pinned as returning u64 rather than unit for a
# narrower reason: the release path CAN refuse (underflow, unbound,
# compare-exchange stuck), and a signature with nowhere to put that
# answer is a signature that invites discarding it silently at every
# future call site rather than at the one that has an argument for it.
GLK_SRC="${AML_SRC}/aml_glk.pdx"
pin_signature "${GLK_SRC}" \
    "pub let aml_glk_enter : () -> u64 !{mem} @{} =" \
    "The acquire takes NO arguments. The FACS comes from aml_glk_attach; a caller-supplied address would compare-exchange a word that is not the platform's Global Lock, serializing this process against nothing. See design/acpi/global-lock.md §6."
pin_signature "${GLK_SRC}" \
    "pub let aml_glk_leave : () -> u64 !{mem} @{} =" \
    "The release takes NO arguments and RETURNS one. See design/acpi/global-lock.md §6."
pin_signature "${GLK_SRC}" \
    "pub let aml_glk_attach : (u64, u64, u64) -> u64 !{mem} @{} =" \
    "The FACS address and both PM1 ports enter through this one point, with no defaults. A default FACS address is a compare-exchange against a guessed word; a default PM1_CNT port is a doorbell that never rings. See design/acpi/global-lock.md §6."
echo "[aml-parser] signatures pinned: aml_glk_enter / aml_glk_leave / aml_glk_attach"

# R30.M8-001 (#1082). THE COMPARE-EXCHANGE IS 32-BIT, ASSERTED IN BYTES.
#
# The ACPI Global Lock is the u32 at FACS+0x10. The FACS `Flags` field is
# the u32 at FACS+0x14, immediately after it. A 64-bit compare-exchange
# at +0x10 read-modify-writes BOTH — it carries Flags through the acquire
# arithmetic and stores it back, silently reverting any firmware update
# that landed in the window.
#
# `lock_cmpxchg` and `lock_cmpxchg_d` differ by one character in the
# source and by one REX.W bit in the emitted machine code, and the wrong
# one assembles, links, boots and works on every machine whose Flags
# field happens not to change. So the assertion is made HERE, in bytes,
# in the style of tools/verify-atomics.sh: every compare-exchange emitted
# by this module must carry the 32-bit opcode, and NONE may carry the
# 64-bit one.
#
# The vacuity guard matters as much as the assertion: a refactor that
# removed the compare-exchange entirely would otherwise satisfy "no
# 64-bit form present" trivially.
GLK_OBJ="${OUT}/aml_glk.o"
glk_dis="$(objdump -d "${GLK_OBJ}" 2>/dev/null || true)"
glk_cx32="$(printf '%s\n' "${glk_dis}" | grep -c 'f0 41\{0,1\} *0f b1' || true)"
glk_cx64="$(printf '%s\n' "${glk_dis}" | grep -cE 'f0 4[89abcdef] 0f b1' || true)"
if [[ "${glk_cx32}" -lt 2 ]]; then
    echo "[aml-parser] FAIL — aml_glk.o emits ${glk_cx32} 32-bit LOCK CMPXCHG(s), expected at least 2" >&2
    echo "  The acquire loop and the release loop must each compare-exchange the" >&2
    echo "  Global Lock. Fewer than two means one of them lost its atomic — which" >&2
    echo "  still assembles and still works whenever firmware does not interleave." >&2
    exit 1
fi
if [[ "${glk_cx64}" -ne 0 ]]; then
    echo "[aml-parser] FAIL — aml_glk.o emits a 64-bit LOCK CMPXCHG (F0 REX.W 0F B1)" >&2
    echo "  The Global Lock is the u32 at FACS+0x10 and FACS Flags is the u32 at" >&2
    echo "  +0x14. A 64-bit compare-exchange read-modify-writes both, reverting any" >&2
    echo "  firmware update to Flags that lands inside the window. Use" >&2
    echo "  lock_cmpxchg_d. See design/acpi/global-lock.md §4." >&2
    exit 1
fi
echo "[aml-parser] Global Lock: ${glk_cx32} 32-bit LOCK CMPXCHG, 0 64-bit"

# ── 4. the corpus ────────────────────────────────────────────────────
OBJS=()
for m in "${MODULES[@]}"; do OBJS+=("${OUT}/${m}.o"); done

if ! "${CC_BIN}" -std=c11 -O1 -Wall -Wextra -no-pie -z noexecstack \
        -o "${OUT}/aml_harness" "${HARNESS}" "${OBJS[@]}" \
        >"${OUT}/harness.log" 2>&1; then
    echo "[aml-parser] FAIL — corpus harness did not build" >&2
    sed 's/^/    /' "${OUT}/harness.log" >&2
    exit 1
fi

if ! "${OUT}/aml_harness"; then
    echo "[aml-parser] FAIL — corpus assertions failed" >&2
    exit 1
fi

echo "[aml-parser] PASS"
exit 0
