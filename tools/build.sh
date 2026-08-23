#!/usr/bin/env bash
# Build the PaideiaOS kernel.
#
# Invokes paideia-as on every .pdx file under src/kernel/, links the
# resulting objects via src/kernel/link.ld, produces build/kernel.elf.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PAIDEIA_AS="$("${REPO_ROOT}/tools/find-paideia-as.sh")"
BUILD_DIR="${REPO_ROOT}/build"
KERNEL_SRC="${REPO_ROOT}/src/kernel"
LINK_SCRIPT="${KERNEL_SRC}/link.ld"

if [[ ! -f "${LINK_SCRIPT}" ]]; then
    echo "linker script missing: ${LINK_SCRIPT}" >&2
    exit 1
fi

mkdir -p "${BUILD_DIR}"

# ---------------------------------------------------------------------------
# obj_relocs_against OBJ SYM — "does this object relocate against SYM?"
#
# Every confinement check below is built on this one question, and the
# obvious way to ask it is wrong.
#
#     objdump -r "$obj" | grep -q "$sym"
#
# Under `set -o pipefail` -- which this script sets, and should --
# `grep -q` exits at its first match, `objdump` then takes SIGPIPE, and
# the PIPELINE's status is failure even though the symbol WAS found.
# Whether it happens depends on pipe-buffer timing, so the same tree
# builds on one run and fails on the next.
#
# Both directions of that mistake matter and one of them is dangerous:
#
#   * in an OWNER check it reports "the owner does not reference the
#     symbol" and fails a correct build -- visible, annoying, and the
#     reason this was found at all;
#   * in a STRAY LOOP it reports "this object does not relocate against
#     the symbol" and PASSES A REAL VIOLATION. A guardrail that
#     intermittently stops checking is worse than one that is absent,
#     because nothing tells you which run it skipped.
#
# Snapshotting objdump's output first removes the pipeline entirely: a
# here-string is a redirect, not a pipe, so grep's status is the
# function's status and nothing can take SIGPIPE. A non-zero objdump
# (missing or unreadable object) reports "no reference", which every
# caller already handles -- owner checks fail loudly on it because they
# stat the file first.
# #1612: cache raw objdump output per object. 219 confinement gates each
# stray-loop over ~800 objects, and every gate was re-running objdump on
# the same file. First call for an object runs objdump; subsequent calls
# grep the cached string. Same suffix-boundary regex, same discipline;
# gate phase drops from ~20min to seconds. __ERR__ sentinel encodes
# non-zero objdump exits (owner checks stat the file first, so this only
# fires on legitimately-missing objects and the caller still handles it).
declare -A __OBJDUMP_RELOC_CACHE
obj_relocs_against() {
    local obj="$1" sym="$2"
    if [[ -z "${__OBJDUMP_RELOC_CACHE[$obj]+set}" ]]; then
        if ! __OBJDUMP_RELOC_CACHE[$obj]="$(objdump -r "$obj" 2>/dev/null)"; then
            __OBJDUMP_RELOC_CACHE[$obj]='__ERR__'
        fi
    fi
    [[ "${__OBJDUMP_RELOC_CACHE[$obj]}" == '__ERR__' ]] && return 1
    # Bash-native pattern match (no fork per call). Preserves the
    # suffix-boundary discipline that guards against R35.M9-style
    # `_dpaux_stats` vs `_backlight_dpaux_stats` collisions.
    [[ "${__OBJDUMP_RELOC_CACHE[$obj]}" =~ (^|[^a-zA-Z0-9_])${sym}([^a-zA-Z0-9_]|$) ]]
}

# R20-M4-004 (#822): "No AML in kernel" guardrail. Refuses the build
# if any AML-related identifier (aml*, dsdt, ssdt, acpica, \_SB_) has
# leaked into src/kernel/**. See design/acpi/no-aml-in-kernel.md for
# the full forbidden set and rationale. Runs first so a violation is
# reported before any (slower) assembler work.
echo "[no-aml-lint] tools/lint-no-kernel-aml.sh"
"${REPO_ROOT}/tools/lint-no-kernel-aml.sh" || {
    echo "[FAIL] no-AML kernel guardrail tripped (#822)" >&2
    exit 1
}

# R49.M3 / #1578: emitted-vs-asserted fingerprint coverage gate. Refuses
# the build if any "... OK" fingerprint the tree can print is asserted in
# no expected/golden file. This defect class is invisible by construction
# — the marker prints whether or not anything checks it — and it has now
# recurred twice (3212fdb: 2 markers; #1578: 7 more, three of them KPTI).
# Runs alongside the no-AML lint, before any assembler work, so a new
# unwitnessed marker fails at the point it is introduced rather than
# surviving until someone runs another mechanical sweep.
echo "[fingerprint-coverage] tools/verify-fingerprint-coverage.sh"
"${REPO_ROOT}/tools/verify-fingerprint-coverage.sh" || {
    echo "[FAIL] unwitnessed boot fingerprint (#1578 gate)" >&2
    exit 1
}

# R31.M1 / #1589: the capability descriptor stride is 24 bytes, and the
# struct that documents it must not describe a layout nothing implements.
# `generation` was declared with no storage, and at stride 24 its offset
# (+24) is the NEXT DESCRIPTOR'S kind — so a contributor following the
# struct, which is the natural thing to do since the struct is the
# documentation, would have silently retyped an unrelated capability.
# Because kind is the first thing every gate checks, the symptom would
# have appeared arbitrarily far from the write.
#
# Source-level, so it runs beside the other two pre-assembler gates: a
# stride divergence must fail at the point it is introduced, not after
# 136 sites have been assembled against two different beliefs about how
# wide a descriptor is.
echo "[cap-stride] tools/verify-cap-stride.sh"
"${REPO_ROOT}/tools/verify-cap-stride.sh" || {
    echo "[FAIL] capability descriptor stride divergence (#1589 gate)" >&2
    exit 1
}

# R31.M2 / #1594: the task pool is addressed by STRIDE and was sized by
# STRUCT. `_task_pool : [u64; 17792]` is 142336 bytes = 64 * 2224, but
# task_new strides 4096 per slot and pid_alloc hands out 63 — so the array
# held 34.75 slots and every pid from 36 up wrote a complete task_struct
# past its end, into `_task_kernel_stacks`. A TCB aliased onto another
# task's kernel stack is two writers disagreeing about what the bytes are,
# one of them a return-address chain.
#
# The literal was wrong; the DEFECT is that the size and the ceiling were
# independent numbers with no checked relation, so they could disagree and
# nothing would say so. paideia-as cannot express the relation in the type
# — an arithmetic array length is not an `ExprLiteral` and degrades to an
# 8-byte .bss object rather than failing — so it is expressed here.
#
# Source-level, so it joins the other three pre-assembler gates: a geometry
# divergence must fail at the point it is introduced, not after the pool has
# been assembled against two different beliefs about how wide a slot is.
echo "[task-pool-bounds] tools/verify-task-pool-bounds.sh"
"${REPO_ROOT}/tools/verify-task-pool-bounds.sh" || {
    echo "[FAIL] task pool geometry divergence (#1594 gate)" >&2
    exit 1
}

# R31.M2 / #1604: init's ring-3 handoff (task slab / e_entry / user_rsp)
# crosses six witness calls into five modules. It used to cross them in
# r12/r13/r14 on an unenforced callee-save convention — a dependency the
# verifying debugger broke on purpose with one `mov r13, 0xdeadbeef` and
# which nothing in the toolchain caught before boot. It now crosses in
# three .bss slots, and this gate is what keeps that an improvement
# rather than a lateral move: two accesses, one file, register path
# poisoned. A global anyone can read would be no better than the
# register convention it replaced.
#
# Source-level, so it joins the other pre-assembler gates: a third
# accessor must fail at the point it is written, not at the point a
# ring-3 entry iretqs into a stale value on someone else's machine.
echo "[init-handoff] tools/verify-init-handoff.sh"
"${REPO_ROOT}/tools/verify-init-handoff.sh" || {
    echo "[FAIL] init ring-3 handoff escaped its two access sites (#1604 gate)" >&2
    exit 1
}

# R31.M1 / #1579: cap_mint_write is the SOLE non-zero writer of a
# descriptor's target_ptr field (+16). A stray write at +16 retargets a
# LIVE capability without changing its kind or rights, so every
# downstream kind-check keeps passing and the corruption presents
# arbitrarily far from the write — the exact "wrong bytes at the
# object end" defect shape R31 exists to close. Zero-clearing writes
# (revoke / free paths) are allowed anywhere, because a descriptor
# whose target_ptr is zero is a REVOKED descriptor. Test-fixture
# seeders that deliberately bypass the mint path (their justifications
# say why) carry an on-line annotation.
#
# Source-level, so it joins the other pre-assembler gates: a stray +16
# writer must fail at the point it is introduced, not after 800 objects
# have been assembled against two different beliefs about who mints
# capabilities.
echo "[cap-descriptor-confine] tools/verify-cap-descriptor.sh"
"${REPO_ROOT}/tools/verify-cap-descriptor.sh" || {
    echo "[FAIL] stray target_ptr writer (#1579 gate)" >&2
    exit 1
}

# R31.M1 / #1608: active-mutation markers must not survive into a
# committed source tree. The power-button-inversion incident that
# motivated the ticket is the canonical shape — a mutation left in
# production code, looking legitimate at a glance, that a grep for
# any of six unmistakable marker strings would have caught. Runs
# alongside the other pre-assembler gates because a marker's failure
# mode is silent: it prints nothing at runtime, ships as if it were
# the real thing, and is only discovered by someone else's incident.
# Self-test hook lives in tools/verify-mutation-marker.sh; the tree
# currently carries zero markers by design, so the normal path is
# silent success.
echo "[mutation-marker] tools/verify-mutation-marker.sh"
"${REPO_ROOT}/tools/verify-mutation-marker.sh" || {
    echo "[FAIL] active mutation marker in source tree (#1608 gate)" >&2
    exit 1
}

# #1605: file_ids.pdx is regenerated by tools/gen-file-ids.sh and its
# ordinals shift whenever a .pdx is added, removed, or renamed under
# src/kernel/. Call sites that pass a FILE_ID as a numeric literal
# paired with a `// FILE_ID_*` comment are a silent drift trap: the
# literal keeps assembling but names the wrong file in every panic dump
# after the shift. This gate scans for the literal-plus-comment pair
# and refuses the build if any pair disagrees with the current table.
# Symbolic sites (`mov rsi, FILE_ID_core_fs_vfs_open`) resolve through
# the linker and cannot drift; they are the preferred form and are
# not policed by this gate.
echo "[file-id-hardcodes] tools/verify-file-id-hardcodes.sh"
"${REPO_ROOT}/tools/verify-file-id-hardcodes.sh" || {
    echo "[FAIL] file-id literal drift in kernel source tree (#1605 gate)" >&2
    exit 1
}

# R41.M4 / #1606: @no_frame is a no-op on unsafe-bodied lambdas because
# paideia-as::emit_visit_lambda short-circuits on body_is_unsafe before
# consulting is_lambda_no_frame. Every hand-written asm function in this
# kernel is unsafe-bodied, so the annotation documented intent the
# compiler never enforced. The initial sweep removed 3173 occurrences;
# this gate refuses any reintroduction. See tools/verify-no-frame-
# forbidden.sh for the full argument.
echo "[no-frame-forbidden] tools/verify-no-frame-forbidden.sh"
"${REPO_ROOT}/tools/verify-no-frame-forbidden.sh" || {
    echo "[FAIL] @no_frame reintroduced under src/kernel/** (#1606 gate)" >&2
    exit 1
}

# R49.M1-002 (#1572): (re)generate the build-mode flag file that the
# klog + uart emit paths gate on. Default is TEST (0), keeping the 14-
# mode witness matrix + goldens byte-identical to the pre-R49 tree.
# Callers opt in to a curated human-readable boot with
# PAIDEIA_BUILD_MODE=release. See design/kernel/boot-presentation.md §3
# for the mechanism and the trade-off write-up.
BUILD_MODE_FILE="${KERNEL_SRC}/core/config/build_mode.pdx"
case "${PAIDEIA_BUILD_MODE:-test}" in
    release|RELEASE|1)
        PAIDEIA_BUILD_MODE_VALUE=1
        PAIDEIA_BUILD_MODE_LABEL=release
        ;;
    test|TEST|debug|DEBUG|0|"")
        PAIDEIA_BUILD_MODE_VALUE=0
        PAIDEIA_BUILD_MODE_LABEL=test
        ;;
    *)
        echo "[build-mode] FAIL: PAIDEIA_BUILD_MODE=${PAIDEIA_BUILD_MODE} not recognised (want test|release)" >&2
        exit 1
        ;;
esac
echo "[build-mode] PAIDEIA_BUILD_MODE=${PAIDEIA_BUILD_MODE_LABEL} -> _kernel_build_mode = ${PAIDEIA_BUILD_MODE_VALUE}"
cat > "${BUILD_MODE_FILE}" <<EOF
// src/kernel/core/config/build_mode.pdx — R49.M1-002 (#1572)
//
// GENERATED FILE. Do NOT edit. Regenerated by tools/build.sh from
// \$PAIDEIA_BUILD_MODE (default: test).
//
// Current build: PAIDEIA_BUILD_MODE=${PAIDEIA_BUILD_MODE_LABEL}
//
// See src/kernel/core/config/build_mode.pdx.template header for the full
// contract, and design/kernel/boot-presentation.md §3 for the trade-off.

module BuildMode = structure {
  pub let mut _kernel_build_mode : u64 = ${PAIDEIA_BUILD_MODE_VALUE}
}
EOF

echo "[build-user] ensuring build/user/shell.bin (R15-M1-007 embed prerequisite)"
"${REPO_ROOT}/tools/build-user.sh"

echo "[boot-stub] tools/boot_stub.S -> boot_stub.o (32+64-bit, as --64)"
BOOT_STUB_OBJ="${BUILD_DIR}/boot_stub.o"
as --64 -o "${BOOT_STUB_OBJ}" "${REPO_ROOT}/tools/boot_stub.S"

echo "[userbin] tools/userbin_embed.S -> userbin_embed.o"
USERBIN_OBJ="${BUILD_DIR}/userbin_embed.o"
( cd "${REPO_ROOT}" && as --64 -o "${USERBIN_OBJ}" tools/userbin_embed.S )

# R18-M1-002 (#761): AP boot trampoline. Standalone-link the trampoline
# blob to VMA=0x8000, extract flat bytes via objcopy, then .incbin the
# result into kernel .rodata via tools/ap_trampoline_embed.S. See
# tools/ap_trampoline.S / tools/ap_trampoline.ld for the trampoline
# proper.
echo "[ap-tramp] tools/ap_trampoline.S -> ap_trampoline.bin (real->prot->long)"
AP_TRAMP_OBJ="${BUILD_DIR}/ap_trampoline.o"
AP_TRAMP_ELF="${BUILD_DIR}/ap_trampoline.elf"
AP_TRAMP_BIN="${BUILD_DIR}/ap_trampoline.bin"
as --64 -o "${AP_TRAMP_OBJ}" "${REPO_ROOT}/tools/ap_trampoline.S"
ld -T "${REPO_ROOT}/tools/ap_trampoline.ld" -o "${AP_TRAMP_ELF}" "${AP_TRAMP_OBJ}"
objcopy -O binary "${AP_TRAMP_ELF}" "${AP_TRAMP_BIN}"

echo "[ap-tramp-embed] tools/ap_trampoline_embed.S -> ap_trampoline_embed.o"
AP_TRAMP_EMBED_OBJ="${BUILD_DIR}/ap_trampoline_embed.o"
( cd "${REPO_ROOT}" && as --64 -o "${AP_TRAMP_EMBED_OBJ}" tools/ap_trampoline_embed.S )

# #761: propagate the trampoline's parameter-slot byte offsets from the
# standalone-linked ap_trampoline.elf into kernel.elf as absolute
# symbols. Reads the `_ap_trampoline_{pml4,stack,entry}_offset` values
# from the standalone .set directives via nm and re-emits them via
# `.set` into a generated ap_trampoline_offsets.o. Future issues
# (#762/#763) patching the slots load these constants as immediates.
AP_TRAMP_OFF_SRC="${BUILD_DIR}/ap_trampoline_offsets.S"
AP_TRAMP_OFF_OBJ="${BUILD_DIR}/ap_trampoline_offsets.o"
PML4_OFF=$(nm --defined-only "${AP_TRAMP_ELF}" \
             | awk '$3 == "_ap_trampoline_pml4_offset"  {print $1; exit}')
STACK_OFF=$(nm --defined-only "${AP_TRAMP_ELF}" \
             | awk '$3 == "_ap_trampoline_stack_offset" {print $1; exit}')
ENTRY_OFF=$(nm --defined-only "${AP_TRAMP_ELF}" \
             | awk '$3 == "_ap_trampoline_entry_offset" {print $1; exit}')
if [[ -z "${PML4_OFF}" || -z "${STACK_OFF}" || -z "${ENTRY_OFF}" ]]; then
    echo "[ap-tramp] FAIL: could not locate _ap_trampoline_*_offset symbols in ${AP_TRAMP_ELF}" >&2
    exit 1
fi
cat > "${AP_TRAMP_OFF_SRC}" <<EOF
# Auto-generated by tools/build.sh from build/ap_trampoline.elf .set symbols.
# DO NOT EDIT. See tools/ap_trampoline.S for the source of truth.
.global _ap_trampoline_pml4_offset
.set    _ap_trampoline_pml4_offset,  0x${PML4_OFF}
.global _ap_trampoline_stack_offset
.set    _ap_trampoline_stack_offset, 0x${STACK_OFF}
.global _ap_trampoline_entry_offset
.set    _ap_trampoline_entry_offset, 0x${ENTRY_OFF}
EOF
as --64 -o "${AP_TRAMP_OFF_OBJ}" "${AP_TRAMP_OFF_SRC}"

OBJECTS=()
# Incremental build (#1611): skip paideia-as when the .o is not older than
# any of its dependencies. Dependencies are the .pdx source, this script
# itself (compiler-command flags may have changed), and the paideia-as
# binary (submodule bump). Set NO_INCREMENTAL=1 to force a full rebuild.
# The link step + all confinement gates still run every invocation, so
# cross-object collisions remain caught.
while IFS= read -r -d '' pdx; do
    rel="${pdx#"${KERNEL_SRC}"/}"
    obj="${BUILD_DIR}/${rel%.pdx}.o"
    mkdir -p "$(dirname "${obj}")"
    if [[ -z "${NO_INCREMENTAL:-}" \
          && -f "${obj}" \
          && ! "${pdx}" -nt "${obj}" \
          && ! "${BASH_SOURCE[0]}" -nt "${obj}" \
          && ! "${PAIDEIA_AS}" -nt "${obj}" ]]; then
        OBJECTS+=("${obj}")
        continue
    fi
    echo "[build] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
    "${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
    OBJECTS+=("${obj}")
done < <(find "${KERNEL_SRC}" -name '*.pdx' -print0 | sort -z)

# R18-M5-004 (#778): compile any .pdx fixtures under tests/kernel/ into
# kernel objects too. These live outside src/kernel/ so they do not
# pollute the primary source tree, but they need to be linked into
# kernel.elf so their `pub` witness functions (e.g. tlb_shootdown_witness)
# are callable from bring-up wire-ups. Object paths are namespaced under
# build/tests/kernel/ to keep the build tree unambiguous.
TESTS_KERNEL_DIR="${REPO_ROOT}/tests/kernel"
if [[ -d "${TESTS_KERNEL_DIR}" ]]; then
    while IFS= read -r -d '' pdx; do
        rel="${pdx#"${REPO_ROOT}"/}"
        obj="${BUILD_DIR}/${rel%.pdx}.o"
        mkdir -p "$(dirname "${obj}")"
        if [[ -z "${NO_INCREMENTAL:-}" \
              && -f "${obj}" \
              && ! "${pdx}" -nt "${obj}" \
              && ! "${BASH_SOURCE[0]}" -nt "${obj}" \
              && ! "${PAIDEIA_AS}" -nt "${obj}" ]]; then
            OBJECTS+=("${obj}")
            continue
        fi
        echo "[build] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
        "${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
        OBJECTS+=("${obj}")
    done < <(find "${TESTS_KERNEL_DIR}" -name '*.pdx' \
        -not -path '*/drivers/elaborator/*' \
        -print0 | sort -z)
fi

# R29-M2-002 (#1024): elaborator negatives under tests/kernel/drivers/
# elaborator/ are INTENTIONALLY REJECTED by paideia-as. They must never
# be swept into the kernel build — verified separately via
# tools/verify-elaborator-negatives.sh, wired into .githooks/pre-push
# as the `elaborator-negatives` step. The `-not -path` filter above
# excludes the whole directory; verification lives in the negatives
# script rather than the object-emitting build path.

# R30.M3-001 (#1061): OP-REGION ROW-TABLE CONFINEMENT.
#
# _op_region_table is the only place in the kernel where a {address
# space, base, length} triple lives, and the entire security argument of
# R30.M3 is that its ONLY writer — opregion_tail_alloc — is reachable
# solely through two gates: the root mint, which demands the base-kind
# capability the space requires, and the derive path, which containment-
# checks the request against the parent window and refuses rather than
# clipping.
#
# That argument is a claim about ONE FILE until it is checked. `objdump
# -r` is the only way to check it mechanically: a kernel object that
# relocates against the table is an object that can write a row without
# passing either gate. A future issue that "just pokes the base in" for
# an EC or LPSS window, or a debug helper that fixes up a length, would
# void the guarantee with no symptom until a firmware table reached an
# address nobody granted it. The build fails here instead.
#
# The check is in build.sh rather than in the pre-push hook deliberately:
# it then runs on every build, including inside the smoke matrix, rather
# than only at push time.
OPREG_OWNER="${BUILD_DIR}/core/cap/kind_op_region.o"
if [[ ! -f "${OPREG_OWNER}" ]]; then
    echo "[opregion-confine] FAIL: ${OPREG_OWNER} not built" >&2
    exit 1
fi
if ! obj_relocs_against "${OPREG_OWNER}" '_op_region_table'; then
    echo "[opregion-confine] FAIL: kind_op_region.o does not reference _op_region_table" >&2
    echo "  The symbol was renamed or the module was gutted; the confinement" >&2
    echo "  check would then pass vacuously, so it fails instead." >&2
    exit 1
fi
opreg_strays=""
for o in "${OBJECTS[@]}"; do
    [[ "${o}" == "${OPREG_OWNER}" ]] && continue
    if obj_relocs_against "${o}" '_op_region_table'; then
        opreg_strays="${opreg_strays} ${o#"${BUILD_DIR}"/}"
    fi
done
if [[ -n "${opreg_strays}" ]]; then
    echo "[opregion-confine] FAIL — objects other than kind_op_region.o relocate" >&2
    echo "  against _op_region_table:${opreg_strays}" >&2
    echo "  Only opregion_tail_alloc may write a region row, and only behind the" >&2
    echo "  root-mint and derive gates. See src/kernel/core/cap/kind_op_region.pdx." >&2
    exit 1
fi
echo "[opregion-confine] _op_region_table confined to core/cap/kind_op_region.o"

# R30.M4-001 (#1066) / R30.M4-002 (#1067): SCI/GPE PATH GUARDRAILS.
#
# Three checks, in increasing order of what they buy.
#
# (1) STORAGE CONFINEMENT, the same shape as the OP-REGION check above.
#     _gpe_cfg holds the validated block geometry, _gpe_dispatch_table
#     and _gpe_event_ring hold the registration rows and the queued
#     events, and _gpe_io_mode selects between real port I/O and the
#     synthetic window. Each has exactly one legitimate writing module,
#     and an object outside it that relocates against one of these is
#     an object that can install an unvalidated geometry, register a
#     subscriber without a range check, forge an event, or leave the
#     kernel addressing RAM in place of the platform's GPE block.
#
# (2) PORT-I/O CONFINEMENT. `in`/`out` carry no effect-row or
#     capability coupling in paideia-as yet (paideia-as#1312), so the
#     elaborator cannot refuse a stray port access the way it refuses
#     an uncapability'd MMIO effect. Until it can, "every GPE register
#     access goes through gpe_io_read8 / gpe_io_write8" is enforced
#     here: core/acpi/gpe_io.o is the only object under core/acpi/ that
#     may contain the IN/OUT opcodes at all.
#
# (3) ISR CALL-TARGET ALLOWLIST — the important one. A GPE's meaning is
#     a firmware control method; those are bytecode, the interpreter is
#     a userspace process, and evaluating one can block for
#     milliseconds. "The ISR does not evaluate one" has to be a
#     property of the call graph rather than of anyone's intent, so the
#     set of symbols core/acpi/sci_isr.o references is required to be a
#     SUBSET of the list below. Every entry is a bounded, non-blocking
#     leaf or near-leaf, which makes this simultaneously the no-
#     evaluation guarantee and the boundedness guarantee: adding a call
#     to an interpreter entry point, an IPC send, a scheduler yield, a
#     lock or an allocator fails the build by name.
GPE_CONFINE_OK=1
gpe_confine_one() {
    # $1 = symbol, $2 = owning object path (relative to BUILD_DIR)
    local sym="$1" owner="${BUILD_DIR}/$2" strays=""
    if [[ ! -f "${owner}" ]]; then
        echo "[gpe-confine] FAIL: ${owner} not built" >&2
        GPE_CONFINE_OK=0
        return
    fi
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[gpe-confine] FAIL: $2 does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        GPE_CONFINE_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[gpe-confine] FAIL — objects other than $2 relocate against ${sym}:${strays}" >&2
        GPE_CONFINE_OK=0
    fi
}
gpe_confine_one '_gpe_cfg'            'core/acpi/gpe_block.o'
gpe_confine_one '_gpe_dispatch_table' 'core/acpi/gpe_table.o'
gpe_confine_one '_gpe_event_ring'     'core/acpi/gpe_table.o'
gpe_confine_one '_gpe_io_mode'        'core/acpi/gpe_io.o'
gpe_confine_one '_gpe_io_synth_ram'   'core/acpi/gpe_io.o'
# R30.M4-003 (#1068) / R30.M4-004 (#1069). Same argument, one layer up:
#   _acpi_event_table  — the KIND_ACPI_EVENT rows. The mint gate in
#     kind_acpi_event.o is the only path to a row; confining the symbol is
#     what upgrades that from a convention to a build failure, exactly as
#     it does for _op_region_table.
#   _acpi_evt_ring / _acpi_evt_state — the subscriber stream. Confining
#     the ring is also why acpi_evt_peek is a field accessor rather than a
#     copy-out through a caller-supplied pointer: no other object may hold
#     an address inside it.
gpe_confine_one '_acpi_event_table'   'core/cap/kind_acpi_event.o'
gpe_confine_one '_acpi_evt_ring'      'core/acpi/evt_stream.o'
gpe_confine_one '_acpi_evt_state'     'core/acpi/evt_stream.o'
if [[ "${GPE_CONFINE_OK}" -ne 1 ]]; then
    echo "  See src/kernel/core/acpi/gpe_block.pdx, gpe_table.pdx and" >&2
    echo "  evt_stream.pdx for why each of these has exactly one legitimate" >&2
    echo "  writer." >&2
    exit 1
fi
echo "[gpe-confine] GPE geometry, dispatch table, event ring, I/O seam,"
echo "[gpe-confine] endpoint table and subscriber stream confined"

# ---------------------------------------------------------------------------
# R30.M5-001 (#1070) / R30.M5-002 (#1071): I²C CAPABILITY CONFINEMENT.
#
# I²C is a shared bus. Every peripheral hangs off the same two wires and
# the controller can address any of them, so per-device isolation is not
# a property of the hardware — it exists only if the capability system
# manufactures it. The claim this milestone makes is:
#
#   A capability naming address A cannot be used to address B, and
#   "address B instead" is not a request that can be PHRASED.
#
# That is a claim about the SHAPE of the code, and it is checked here in
# two parts.
#
# (1) STORAGE CONFINEMENT, the same shape as the op-region and GPE
#     checks above. `_i2c_slave_table` is the only place in the kernel
#     where an I²C device address lives, and `_i2c_bus_table` is the
#     only place a controller identity and a device count live. Confining
#     each to its owning object is what makes "the mint gate is the only
#     path to a row" a property of the kernel rather than of one file.
#     It is also what forces kind_i2c_slave.o to maintain the bus's
#     device count through i2c_bus_note_slave_added / _removed instead of
#     reaching into the bus table, which is why that count has exactly
#     two mutators.
#
# (2) ADDRESS-ARGUMENT ARITY PIN. The two address resolvers take a
#     capability (or a row) and nothing else. A mutant that adds an
#     `addr` parameter to either — the natural, helpful-looking change
#     that would quietly destroy the confinement property — changes the
#     declared signature, and this check fails the build on it. The
#     runtime half of the same argument is sub-test O of
#     tests/kernel/cap/i2c_cap_synth.pdx, which calls both resolvers
#     with a neighbouring device's address loaded into every register an
#     added parameter could arrive in.
# ---------------------------------------------------------------------------
I2C_CONFINE_OK=1
i2c_confine_one() {
    local sym="$1"
    local owner="${BUILD_DIR}/$2"
    local strays=""
    if [[ ! -f "${owner}" ]]; then
        echo "[i2c-confine] FAIL: ${owner} not built" >&2
        I2C_CONFINE_OK=0
        return
    fi
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[i2c-confine] FAIL: $2 does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  assertion below would then pass vacuously." >&2
        I2C_CONFINE_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-confine] FAIL — objects other than $2 relocate against ${sym}:${strays}" >&2
        I2C_CONFINE_OK=0
    fi
}
i2c_confine_one '_i2c_bus_table'   'core/cap/kind_i2c_bus.o'
i2c_confine_one '_i2c_slave_table' 'core/cap/kind_i2c_slave.o'
if [[ "${I2C_CONFINE_OK}" -ne 1 ]]; then
    echo "  See src/kernel/core/cap/kind_i2c_bus.pdx and kind_i2c_slave.pdx" >&2
    echo "  for why each table has exactly one legitimate writer." >&2
    exit 1
fi
echo "[i2c-confine] bus row table and slave address table confined"

I2C_SLAVE_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_i2c_slave.pdx"
I2C_XFER_SRC="${REPO_ROOT}/src/kernel/core/drivers/i2c/dw_xfer.pdx"
i2c_addr_pin_in() {
    local src="$1"
    local decl="$2"
    if ! grep -qF -- "${decl}" "${src}"; then
        echo "[i2c-addr-confine] FAIL — expected declaration not found in" >&2
        echo "  ${src#"${REPO_ROOT}"/}:" >&2
        echo "    ${decl}" >&2
        echo "  Every I²C address-bearing entry point takes a CAPABILITY SLOT and" >&2
        echo "  no address. An extra parameter on any of them — an 'addr', a" >&2
        echo "  'mode', a 'bus' the caller supplies — would make 'address a device" >&2
        echo "  other than the one my capability names' expressible, which is" >&2
        echo "  precisely the property KIND_I2C_SLAVE exists to remove on a shared" >&2
        echo "  bus. If this fired because a signature legitimately changed, the" >&2
        echo "  confinement argument in kind_i2c_slave.pdx and dw_xfer.pdx must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
i2c_addr_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${I2C_SLAVE_SRC}"; then
        echo "[i2c-addr-confine] FAIL — expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "  The I²C slave address resolvers take a capability slot (or a row" >&2
        echo "  id) and NOTHING ELSE. An extra parameter here — an 'addr' the" >&2
        echo "  caller supplies — would make 'address a device other than the one" >&2
        echo "  my capability names' expressible, which is precisely the property" >&2
        echo "  KIND_I2C_SLAVE exists to remove on a shared bus. If this fired" >&2
        echo "  because the signature legitimately changed, the confinement" >&2
        echo "  argument in kind_i2c_slave.pdx must be rewritten first." >&2
        exit 1
    fi
}
i2c_addr_pin_one 'pub let i2c_slave_addr_of_slot : (u64) -> u64'
i2c_addr_pin_one 'pub let i2c_slave_row_addr : (u64) -> u64'

# R30.M5-004 (#1073): the pin set extends to the two OTHER identity
# resolvers and to all four transfer entry points.
#
# Mode and bus row are each half of an address on this bus. A 7-bit
# device at 0x1A and a 10-bit device at 0x01A are the same number and
# different byte sequences on the wire; address 0x1A on the touchpad
# controller and 0x1A on the sensor hub are two devices on two pairs of
# wires, which #1071 deliberately permitted at mint by scoping the
# uniqueness key to the bus. A transfer path that accepted either from
# its caller could therefore reach a device its capability does not
# name while passing every address check — so all three resolvers are
# arity one, and all four transfer entry points take a capability slot
# first and no address at all.
i2c_addr_pin_one 'pub let i2c_slave_mode_of_slot : (u64) -> u64'
i2c_addr_pin_one 'pub let i2c_slave_bus_row_of_slot : (u64) -> u64'
i2c_addr_pin_in "${I2C_XFER_SRC}" 'pub let i2c_xfer_write : (u64, u64, u64, u64) -> u64'
i2c_addr_pin_in "${I2C_XFER_SRC}" 'pub let i2c_xfer_read : (u64, u64, u64, u64) -> u64'
i2c_addr_pin_in "${I2C_XFER_SRC}" 'pub let i2c_xfer_write_read : (u64, u64, u64, u64, u64, u64) -> u64'
i2c_addr_pin_in "${I2C_XFER_SRC}" 'pub let i2c_smbus_op : (u64, u64, u64, u64, u64) -> u64'

# R30.M5-005 (#1074): the interrupt-driven entry points are pinned on the
# same terms.
#
# An engine that delivers its completion by interrupt rather than by
# polling has no reason whatsoever to take an address, and every reason
# not to: it is the path a driver will actually use at input rates, so a
# caller-supplied address here would be the address parameter that gets
# used. i2c_xfer_irq_begin is pinned as well as the three transfers,
# because it is the function that actually resolves the capability and a
# parameter added there would reach the wire through all three.
I2C_IRQ_SRC="${REPO_ROOT}/src/kernel/core/drivers/i2c/dw_irq.pdx"
i2c_addr_pin_in "${I2C_IRQ_SRC}" 'pub let i2c_xfer_irq_begin : (u64, u64, u64, u64, u64) -> u64'
i2c_addr_pin_in "${I2C_IRQ_SRC}" 'pub let i2c_xfer_irq_write : (u64, u64, u64, u64) -> u64'
i2c_addr_pin_in "${I2C_IRQ_SRC}" 'pub let i2c_xfer_irq_read : (u64, u64, u64, u64) -> u64'
i2c_addr_pin_in "${I2C_IRQ_SRC}" 'pub let i2c_xfer_irq_write_read : (u64, u64, u64, u64, u64, u64) -> u64'
echo "[i2c-addr-confine] address/mode/bus resolvers and all four transfer"
echo "[i2c-addr-confine] entry points take no caller-supplied address"
echo "[i2c-addr-confine] interrupt-driven entry points likewise"

# ---------------------------------------------------------------------------
# R30.M5-003 (#1072): I²C REGISTER-PATH CONFINEMENT.
#
# The claim: the LPSS controller's registers are reachable ONLY through
# a KIND_OP_REGION capability, resolved on every access.
#
# That claim is a property of one file — core/drivers/i2c/dw_io.pdx —
# until it is checked. Two checks make it a property of the kernel.
#
# (a) The seam's own state (mode, bound window slot, synthetic window,
#     access trace) has exactly one writer object. A second writer could
#     bind a window, or switch the seam to its synthetic side, from
#     somewhere the review never looked.
#
# (b) NO OTHER OBJECT UNDER core/drivers/i2c/ MAY RELOCATE AGAINST
#     opregion_row_base OR opregion_row_len. Those two functions are the
#     only ones in the kernel that can turn a capability into a physical
#     address — _op_region_table is confined to kind_op_region.o by the
#     [opregion-confine] step above — so an object under this directory
#     that calls them is an object forming a device address outside the
#     seam. That is precisely the second, unguarded path to controller
#     registers that R30.M3 spent an issue removing for firmware-declared
#     regions; re-opening it one layer down, for the same physical
#     addresses, would void the argument with no symptom until something
#     wrote a register nobody granted it.
#
# The transfer engine, the bring-up sequence and the probe all reach
# registers through dw_io_read32 / dw_io_write32 and therefore relocate
# against those, not against the address producers.
I2C_MMIO_OK=1
i2c_mmio_owner_only() {
    local sym="$1"
    local owner="${BUILD_DIR}/core/drivers/i2c/dw_io.o"
    if [[ ! -f "${owner}" ]]; then
        echo "[i2c-mmio-confine] FAIL: ${owner} not built" >&2
        I2C_MMIO_OK=0
        return
    fi
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[i2c-mmio-confine] FAIL: dw_io.o does not reference ${sym}" >&2
        echo "  The seam no longer resolves the window capability itself; the" >&2
        echo "  confinement assertion below would then pass vacuously." >&2
        I2C_MMIO_OK=0
        return
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        case "${o}" in
            "${BUILD_DIR}"/core/drivers/i2c/*) ;;
            *) continue ;;
        esac
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-mmio-confine] FAIL — objects under core/drivers/i2c/ other than" >&2
        echo "  dw_io.o relocate against ${sym}:${strays}" >&2
        I2C_MMIO_OK=0
    fi
}
i2c_seam_state_confine() {
    local sym="$1"
    local owner="${BUILD_DIR}/core/drivers/i2c/dw_io.o"
    local strays=""
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[i2c-mmio-confine] FAIL: dw_io.o does not reference ${sym}" >&2
        I2C_MMIO_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-mmio-confine] FAIL — objects other than dw_io.o relocate" >&2
        echo "  against ${sym}:${strays}" >&2
        I2C_MMIO_OK=0
    fi
}
i2c_mmio_owner_only 'opregion_row_base'
i2c_mmio_owner_only 'opregion_row_len'
i2c_seam_state_confine '_dw_io_mode'
i2c_seam_state_confine '_dw_io_win_slot'
i2c_seam_state_confine '_dw_io_synth_ram'
i2c_seam_state_confine '_dw_io_trace'
# The controller table and the abort-source diagnostic likewise have one
# writer each: bring-up and the transfer engine mutate controller state
# only through lpss_probe.o's exported mutators, which is what keeps
# "which controller is wedged" a single fact rather than a race.
i2c_ctrl_confine() {
    local sym="$1"
    local owner="${BUILD_DIR}/$2"
    local strays=""
    if [[ ! -f "${owner}" ]]; then
        echo "[i2c-mmio-confine] FAIL: ${owner} not built" >&2
        I2C_MMIO_OK=0
        return
    fi
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[i2c-mmio-confine] FAIL: $2 does not reference ${sym}" >&2
        I2C_MMIO_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-mmio-confine] FAIL — objects other than $2 relocate against" >&2
        echo "  ${sym}:${strays}" >&2
        I2C_MMIO_OK=0
    fi
}
i2c_ctrl_confine '_lpss_i2c_ctrl'      'core/drivers/i2c/lpss_probe.o'
i2c_ctrl_confine '_i2c_xfer_abort_src' 'core/drivers/i2c/dw_xfer.o'
# R30.M5-005 (#1074): the interrupt engine's FSM contexts and the single
# transfer claim.
#
# _dw_irq_ctx is the one place in the kernel where the state of an
# in-flight I2C transfer lives, and the entire SMP argument for it is
# that its fields have exactly ONE writer at any instant, chosen by the
# state word at offset 0. That argument is a claim about which objects
# can touch the table, and objdump -r is the only way to check it. Note
# that dw_isr.o -- which does more writing into these rows than anything
# else -- is NOT an owner: it reaches them through dw_irq_row, so the
# rows have one relocating object and the ISR's access is exactly the
# access the ownership protocol grants it.
#
# _dw_irq_seam_owner is stronger still: it is a SINGLE cell whose CAS is
# what makes "one transfer in flight at a time" true across both the
# polled and the interrupt engine. A second object writing it would be a
# second way to believe you own the bus.
i2c_ctrl_confine '_dw_irq_ctx'         'core/drivers/i2c/dw_irq.o'
i2c_ctrl_confine '_dw_irq_seam_owner'  'core/drivers/i2c/dw_irq.o'
if [[ "${I2C_MMIO_OK}" -ne 1 ]]; then
    echo "  See src/kernel/core/drivers/i2c/dw_io.pdx for why the window" >&2
    echo "  capability must be re-resolved per access and why no second" >&2
    echo "  address-producing path may exist under core/drivers/i2c/." >&2
    exit 1
fi
echo "[i2c-mmio-confine] controller registers reachable only through the"
echo "[i2c-mmio-confine] window capability; seam and controller state confined"

# (2) Port I/O confinement under core/acpi/.
gpe_io_strays=""
for o in "${OBJECTS[@]}"; do
    case "${o}" in
        "${BUILD_DIR}"/core/acpi/*) ;;
        *) continue ;;
    esac
    [[ "${o}" == "${BUILD_DIR}/core/acpi/gpe_io.o" ]] && continue
    # IN AL,DX = 0xEC ; IN EAX,DX = 0xED ; OUT DX,AL = 0xEE ; OUT DX,EAX = 0xEF
    gpe_io_dis="$(objdump -d "${o}" 2>/dev/null || true)"
    if grep -qE '^\s+[0-9a-f]+:.*\b(in|out)\s+(\(%dx\),%(al|ax|eax)|%(al|ax|eax),\(%dx\))' <<< "${gpe_io_dis}"; then
        gpe_io_strays="${gpe_io_strays} ${o#"${BUILD_DIR}"/}"
    fi
done
if [[ -n "${gpe_io_strays}" ]]; then
    echo "[gpe-portio] FAIL — port I/O outside core/acpi/gpe_io.o:${gpe_io_strays}" >&2
    echo "  Every GPE register access must go through gpe_io_read8 / gpe_io_write8." >&2
    echo "  paideia-as#1312 will make this an effect-row property; until then it is" >&2
    echo "  this check. See src/kernel/core/acpi/gpe_io.pdx." >&2
    exit 1
fi
echo "[gpe-portio] port I/O under core/acpi/ confined to gpe_io.o"

# (3) ISR call-target allowlist.
SCI_ISR_OBJ="${BUILD_DIR}/core/acpi/sci_isr.o"
if [[ ! -f "${SCI_ISR_OBJ}" ]]; then
    echo "[sci-isr-allowlist] FAIL: ${SCI_ISR_OBJ} not built" >&2
    exit 1
fi
SCI_ISR_ALLOWED="
gpe_block_reg_bytes
gpe_block_status_base
gpe_block_enable_base
gpe_block_index_base
gpe_io_read8
gpe_io_write8
gpe_io_eoi
gpe_lookup
gpe_note_strike
gpe_mark_perm_masked
gpe_mark_pending
gpe_event_enqueue
drv_audit_emit
"
sci_isr_refs=$(objdump -r "${SCI_ISR_OBJ}" 2>/dev/null \
    | awk 'NF >= 3 && $1 ~ /^[0-9a-f]+$/ { print $3 }' \
    | sed -e 's/[-+]0x[0-9a-f]*$//' | sort -u)
if [[ -z "${sci_isr_refs}" ]]; then
    echo "[sci-isr-allowlist] FAIL: no relocations found in sci_isr.o" >&2
    echo "  The ISR was gutted or inlined away; the allowlist would then pass" >&2
    echo "  vacuously, so it fails instead." >&2
    exit 1
fi
sci_isr_bad=""
while IFS= read -r sym; do
    [[ -z "${sym}" ]] && continue
    if ! grep -qxF -- "${sym}" <<< "${SCI_ISR_ALLOWED}"; then
        sci_isr_bad="${sci_isr_bad} ${sym}"
    fi
done <<< "${sci_isr_refs}"
if [[ -n "${sci_isr_bad}" ]]; then
    echo "[sci-isr-allowlist] FAIL — core/acpi/sci_isr.o references:${sci_isr_bad}" >&2
    echo "  The SCI ISR may only call bounded, non-blocking primitives. No firmware" >&2
    echo "  method evaluation, no IPC, no scheduling, no allocation, no locks." >&2
    echo "  If a new call really belongs in interrupt context, add it to" >&2
    echo "  SCI_ISR_ALLOWED here AND say in the commit why it is bounded." >&2
    echo "  See src/kernel/core/acpi/sci_isr.pdx §The allowlist." >&2
    exit 1
fi
echo "[sci-isr-allowlist] sci_isr.o call targets within the bounded allowlist"

# ---------------------------------------------------------------------------
# R30.M5-005 (#1074): DESIGNWARE I²C ISR CALL-TARGET ALLOWLIST.
#
# A SECOND, SEPARATE list. It deliberately does not extend the SCI one
# and the SCI one does not extend it: the two routines are bounded for
# different reasons and by different arguments, and a shared list would
# let a symbol justified for one appear, unexamined, in the other.
#
# src/kernel/core/drivers/i2c/dw_isr.pdx contains exactly one function
# for this check's sake. Every symbol below is a bounded, non-blocking
# leaf or near-leaf:
#
#   dw_irq_row           range check plus address arithmetic
#   atomic_load_u64      one aligned load
#   atomic_cas_u64       one LOCK CMPXCHG
#   atomic_xchg_u64      one XCHG
#   atomic_store_u64     one aligned store
#   dw_i2c_select        two table reads and a slot store
#   dw_io_read32         capability re-resolve plus one MMIO load
#   dw_io_write32        capability re-resolve plus one MMIO store
#   dw_xfer_check_abort  straight-line, three register accesses
#   i2c_xfer_last_abort  one load
#   dw_irq_close         two CAS attempts, three stores, one register
#                        write; no loop
#
# None allocates, none takes a lock, none can block, none reaches a
# scheduler, an IPC send, or a firmware-method interpreter. Adding a
# call to anything else fails the build by name.
#
# The routine's own loops are counted against DW_IRQ_TX_BURST and
# DW_IRQ_RX_BURST, both fixed, so its cost does not grow with transfer
# length -- a 256-byte write is thirty-two short invocations, not one
# long one.
DW_ISR_OBJ="${BUILD_DIR}/core/drivers/i2c/dw_isr.o"
if [[ ! -f "${DW_ISR_OBJ}" ]]; then
    echo "[dw-isr-allowlist] FAIL: ${DW_ISR_OBJ} not built" >&2
    exit 1
fi
DW_ISR_ALLOWED="
dw_irq_row
dw_irq_close
dw_i2c_select
dw_io_read32
dw_io_write32
dw_xfer_check_abort
i2c_xfer_last_abort
atomic_load_u64
atomic_store_u64
atomic_cas_u64
atomic_xchg_u64
"
dw_isr_refs=$(objdump -r "${DW_ISR_OBJ}" 2>/dev/null \
    | awk 'NF >= 3 && $1 ~ /^[0-9a-f]+$/ { print $3 }' \
    | sed -e 's/[-+]0x[0-9a-f]*$//' | sort -u)
if [[ -z "${dw_isr_refs}" ]]; then
    echo "[dw-isr-allowlist] FAIL: no relocations found in dw_isr.o" >&2
    echo "  The ISR was gutted or inlined away; the allowlist would then pass" >&2
    echo "  vacuously, so it fails instead." >&2
    exit 1
fi
dw_isr_bad=""
while IFS= read -r sym; do
    [[ -z "${sym}" ]] && continue
    if ! grep -qxF -- "${sym}" <<< "${DW_ISR_ALLOWED}"; then
        dw_isr_bad="${dw_isr_bad} ${sym}"
    fi
done <<< "${dw_isr_refs}"
if [[ -n "${dw_isr_bad}" ]]; then
    echo "[dw-isr-allowlist] FAIL — core/drivers/i2c/dw_isr.o references:${dw_isr_bad}" >&2
    echo "  The I2C service routine may only call bounded, non-blocking" >&2
    echo "  primitives. No allocation, no lock, no scheduling, no IPC, no" >&2
    echo "  unbounded loop behind a call." >&2
    echo "  If a new call really belongs in interrupt context, add it to" >&2
    echo "  DW_ISR_ALLOWED here AND say in the commit why it is bounded." >&2
    echo "  Do NOT widen SCI_ISR_ALLOWED instead; the two lists are separate" >&2
    echo "  on purpose." >&2
    echo "  See src/kernel/core/drivers/i2c/dw_isr.pdx §The allowlist." >&2
    exit 1
fi
echo "[dw-isr-allowlist] dw_isr.o call targets within the bounded allowlist"

# ---------------------------------------------------------------------------
# R30.M6-004 (#1078): GPIO EDGE-ISR CALL-TARGET ALLOWLIST.
#
# A THIRD, SEPARATE list. It does not extend SCI_ISR_ALLOWED and it does
# not extend DW_ISR_ALLOWED, and neither of those extends it, for the
# reason already stated above the I2C one: the three routines are bounded
# by different arguments over different hardware, and a shared list would
# let a symbol justified for the ACPI SCI appear, unexamined, in the
# pad-controller path. If a call belongs in GPIO interrupt context, it
# goes here and the commit says why it is bounded.
#
# src/kernel/core/drivers/gpio/gpio_isr.pdx contains exactly one function
# for this check's sake. Every symbol below is bounded and non-blocking:
#
#   gpio_pad_sub_slot        bounds check plus one load
#   gpio_pad_is_off_of_slot  capability resolve plus table reads; its one
#                            internal loop is bounded by GPIO_COMM_MAX_PINS
#   gpio_pad_bit_of_slot     capability resolve plus a shift loop bounded
#                            by 32
#   gpio_io_read32           window capability re-resolve plus one load
#   gpio_io_write32          window capability re-resolve plus one store
#   gpio_pad_sub_bump        two row accesses and a store, no loop
#   gpio_pad_sub_storm       one GPI_IE read-modify-write, no loop
#
# None allocates, none takes a lock, none can block, none reaches a
# scheduler, an IPC send, or a firmware-method interpreter.
#
# The ISR's own loops are 4 subscriptions x GPIO_ISR_LINE_BUDGET services,
# both compile-time constants, so its cost cannot grow with anything the
# hardware controls -- which is the whole point on a part where a
# mis-triggered pad re-raises its interrupt forever. See
# src/kernel/core/drivers/gpio/gpio_isr.pdx §Why an interrupt storm is a
# livelock.
GPIO_ISR_OBJ="${BUILD_DIR}/core/drivers/gpio/gpio_isr.o"
if [[ ! -f "${GPIO_ISR_OBJ}" ]]; then
    echo "[gpio-isr-allowlist] FAIL: ${GPIO_ISR_OBJ} not built" >&2
    exit 1
fi
GPIO_ISR_ALLOWED="
gpio_pad_sub_slot
gpio_pad_sub_bump
gpio_pad_sub_storm
gpio_pad_is_off_of_slot
gpio_pad_bit_of_slot
gpio_io_read32
gpio_io_write32
"
gpio_isr_refs=$(objdump -r "${GPIO_ISR_OBJ}" 2>/dev/null \
    | awk 'NF >= 3 && $1 ~ /^[0-9a-f]+$/ { print $3 }' \
    | sed -e 's/[-+]0x[0-9a-f]*$//' | sort -u)
if [[ -z "${gpio_isr_refs}" ]]; then
    echo "[gpio-isr-allowlist] FAIL: no relocations found in gpio_isr.o" >&2
    echo "  The ISR was gutted or inlined away; the allowlist would then pass" >&2
    echo "  vacuously, so it fails instead. An ISR that references nothing" >&2
    echo "  trivially satisfies 'references nothing outside the allowlist'." >&2
    exit 1
fi
gpio_isr_bad=""
while IFS= read -r sym; do
    [[ -z "${sym}" ]] && continue
    if ! grep -qxF -- "${sym}" <<< "${GPIO_ISR_ALLOWED}"; then
        gpio_isr_bad="${gpio_isr_bad} ${sym}"
    fi
done <<< "${gpio_isr_refs}"
if [[ -n "${gpio_isr_bad}" ]]; then
    echo "[gpio-isr-allowlist] FAIL — core/drivers/gpio/gpio_isr.o references:${gpio_isr_bad}" >&2
    echo "  The GPIO edge service routine may only call bounded, non-blocking" >&2
    echo "  primitives. No allocation, no lock, no scheduling, no IPC, no" >&2
    echo "  unbounded loop behind a call. A GPIO status bit is level-sticky:" >&2
    echo "  an ISR that cannot finish promptly does not make the machine slow," >&2
    echo "  it stops it, because the interrupt outranks anything that could" >&2
    echo "  diagnose the problem." >&2
    echo "  If a new call really belongs in GPIO interrupt context, add it to" >&2
    echo "  GPIO_ISR_ALLOWED here AND say in the commit why it is bounded." >&2
    echo "  Do NOT widen SCI_ISR_ALLOWED or DW_ISR_ALLOWED instead; the three" >&2
    echo "  lists are separate on purpose." >&2
    echo "  See src/kernel/core/drivers/gpio/gpio_isr.pdx §The allowlist." >&2
    exit 1
fi
echo "[gpio-isr-allowlist] gpio_isr.o call targets within the bounded allowlist"

# ---------------------------------------------------------------------------
# R30.M6-001 (#1075) / R30.M6-002 (#1076): GPIO PIN CONFINEMENT.
#
# A pad controller owns EVERY PIN ON THE PACKAGE. On a T14 G4 those pins
# include device reset asserts, power-rail enables, write-protect straps
# and firmware-flash control. Acting on the wrong one is not a data
# error: a pin has no acknowledgement, no arbitration and no status bit
# that says "that was the wrong pin". It simply becomes whatever the last
# writer made it, and the first symptom appears in whatever hardware the
# pin controls.
#
# The claim this milestone makes is therefore the I²C claim with the
# stakes raised:
#
#   A capability naming pin P cannot be used to act on pin Q, and
#   "act on Q instead" is not a request that can be PHRASED.
#
# That is a claim about the SHAPE of the code, and it is checked here in
# three parts.
#
# (1) STORAGE CONFINEMENT, the same shape as the op-region, GPE and I²C
#     checks above. `_gpio_line_table` is the only place in the kernel
#     where a pin ASSIGNMENT lives; `_lpss_gpio_ctrl` and
#     `_lpss_gpio_comm` are the only places a controller's identity and
#     its pin-to-register geometry live. Confining each to its owning
#     object is what makes "the mint gate is the only path to a row" and
#     "the community table has one validating writer" properties of the
#     kernel rather than of two files.
#
# (2) SEAM CONFINEMENT. `opregion_row_base` / `opregion_row_len` are the
#     only functions in the kernel that can turn a capability into a
#     physical address, so an object under `core/drivers/gpio/` that
#     calls them is an object forming a pad-controller address outside
#     the seam. The seam's own state has one writer for the same reason
#     `dw_io.pdx`'s does: a second writer could bind a window, or switch
#     the seam to its synthetic side, from somewhere the review never
#     looked.
#
# (3) THE PIN-ARGUMENT ARITY PIN, and it is WIDER than the I²C one.
#     A pad's register address is
#
#         community.reg_off + community.padbar + pad_index * stride
#
#     so a caller-supplied COMMUNITY reaches a different pin exactly as
#     surely as a caller-supplied pin does, and a caller-supplied PAD
#     INDEX more surely still. All five capability-form resolvers are
#     therefore pinned — pin, community, pad index, controller identity,
#     and the pad register offset itself — plus the row-form pin
#     resolver. A confinement that guarded only the pin number would
#     leave two doors into the same room.
#
#     `lpss_gpio_pad_off` is confined ON TOP of that. It is the raw
#     arithmetic, it takes (controller, community, pad) with no
#     capability anywhere, and it is exactly what a future driver would
#     reach for. Restricting it to its own object and to the capability
#     module makes `gpio_line_pad_off_of_slot(slot)` the ONLY route in
#     the kernel from anything to a pad register address — capability
#     in, address out, no other parameter. R30.M6-004 (#1078) is the
#     issue that will write PADCFG registers, and this is the check that
#     decides what address it is able to write to.
#
#     The runtime half of the same argument is sub-test J of
#     tests/kernel/cap/gpio_cap_synth.pdx, which calls all five resolvers
#     with a NEIGHBOURING pin's number, community, pad index and register
#     offset loaded into every register an added parameter could arrive
#     in.
# ---------------------------------------------------------------------------
GPIO_CONFINE_OK=1
gpio_confine_one() {
    # $1 = symbol, $2 = owning object path (relative to BUILD_DIR)
    local sym="$1"
    local owner="${BUILD_DIR}/$2"
    local strays=""
    if [[ ! -f "${owner}" ]]; then
        echo "[gpio-confine] FAIL: ${owner} not built" >&2
        GPIO_CONFINE_OK=0
        return
    fi
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[gpio-confine] FAIL: $2 does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  assertion below would then pass vacuously, so it fails instead." >&2
        GPIO_CONFINE_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[gpio-confine] FAIL — objects other than $2 relocate against ${sym}:${strays}" >&2
        GPIO_CONFINE_OK=0
    fi
}
# Unlike gpio_confine_one, this one confines a FUNCTION rather than a
# table, so the two ends of the non-vacuousness check are different: the
# defining object must still DEFINE it (a renamed or deleted function
# would make the stray scan pass on nothing), and the one permitted
# CALLER must still call it (a capability route that stopped using it
# would make the confinement guard a path nobody takes). Used only for
# lpss_gpio_pad_off.
gpio_confine_pair() {
    # $1 = symbol, $2 = defining object, $3 = the one permitted caller
    local sym="$1"
    local a="${BUILD_DIR}/$2"
    local b="${BUILD_DIR}/$3"
    local strays=""
    local defs
    if [[ ! -f "${a}" || ! -f "${b}" ]]; then
        echo "[gpio-confine] FAIL: ${a} or ${b} not built" >&2
        GPIO_CONFINE_OK=0
        return
    fi
    defs="$(nm --defined-only "${a}" 2>/dev/null || true)"
    if ! grep -qE -- "[[:space:]]${sym}\$" <<< "${defs}"; then
        echo "[gpio-confine] FAIL: $2 does not define ${sym}" >&2
        echo "  The symbol was renamed or the function was deleted; the stray" >&2
        echo "  scan below would then pass vacuously, so it fails instead." >&2
        GPIO_CONFINE_OK=0
        return
    fi
    if ! obj_relocs_against "${b}" "${sym}"; then
        echo "[gpio-confine] FAIL: $3 does not reference ${sym}" >&2
        echo "  gpio_line_pad_off_of_slot is meant to be the only capability-" >&2
        echo "  bearing route to a pad address; if it no longer calls this," >&2
        echo "  the confinement below is checking nothing." >&2
        GPIO_CONFINE_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${a}" ]] && continue
        [[ "${o}" == "${b}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[gpio-confine] FAIL — objects other than $2 and $3 relocate against" >&2
        echo "  ${sym}:${strays}" >&2
        echo "  A pad register address may only be formed from a CAPABILITY," >&2
        echo "  through gpio_line_pad_off_of_slot. An object holding the raw" >&2
        echo "  (controller, community, pad) calculator can address any pin on" >&2
        echo "  the package. See src/kernel/core/cap/kind_gpio_line.pdx." >&2
        GPIO_CONFINE_OK=0
    fi
}
gpio_confine_one '_gpio_line_table' 'core/cap/kind_gpio_line.o'
gpio_confine_one '_lpss_gpio_ctrl'  'core/drivers/gpio/lpss_gpio.o'
gpio_confine_one '_lpss_gpio_comm'  'core/drivers/gpio/lpss_gpio.o'
gpio_confine_one '_gpio_io_mode'      'core/drivers/gpio/gpio_io.o'
gpio_confine_one '_gpio_io_win_slot'  'core/drivers/gpio/gpio_io.o'
gpio_confine_one '_gpio_io_bound'     'core/drivers/gpio/gpio_io.o'
gpio_confine_one '_gpio_io_synth_ram' 'core/drivers/gpio/gpio_io.o'
gpio_confine_one '_gpio_io_trace'     'core/drivers/gpio/gpio_io.o'
gpio_confine_one '_gpio_io_trace_n'   'core/drivers/gpio/gpio_io.o'
# R30.M6-004 (#1078): the write-1-to-clear registry decides whether a
# store to a synthetic register is absorbed or acknowledged, so a second
# writer could make a status register behave as storage from somewhere
# the review never looked -- and an interrupt test against a storage
# status register cannot tell a correct acknowledgement from a missing
# one. Same argument as _gpio_io_mode's, which it sits beside.
gpio_confine_one '_gpio_io_w1c'       'core/drivers/gpio/gpio_io.o'
# R30.M6-004 (#1078): the edge-subscription registry. It holds capability
# SLOTS and no cached addresses, and it is what the ISR walks; a second
# writer could enrol a line the capability layer never authorised, and
# the ISR would then be re-deriving a pad address from someone else's
# descriptor on every interrupt.
gpio_confine_one '_gpio_pad_sub'      'core/drivers/gpio/gpio_pad.o'
gpio_confine_pair 'lpss_gpio_pad_off' 'core/drivers/gpio/lpss_gpio.o' 'core/cap/kind_gpio_line.o'

# The address producers, restricted to the seam WITHIN core/drivers/gpio/.
# Same argument as [i2c-mmio-confine]: an object under this directory
# that calls them is a second, unguarded path to controller registers.
gpio_seam_addr_only() {
    local sym="$1"
    local owner="${BUILD_DIR}/core/drivers/gpio/gpio_io.o"
    local strays=""
    if [[ ! -f "${owner}" ]]; then
        echo "[gpio-confine] FAIL: ${owner} not built" >&2
        GPIO_CONFINE_OK=0
        return
    fi
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[gpio-confine] FAIL: gpio_io.o does not reference ${sym}" >&2
        echo "  The seam no longer resolves the window capability itself; the" >&2
        echo "  confinement assertion below would then pass vacuously." >&2
        GPIO_CONFINE_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        case "${o}" in
            "${BUILD_DIR}"/core/drivers/gpio/*) ;;
            *) continue ;;
        esac
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[gpio-confine] FAIL — objects under core/drivers/gpio/ other than" >&2
        echo "  gpio_io.o relocate against ${sym}:${strays}" >&2
        GPIO_CONFINE_OK=0
    fi
}
gpio_seam_addr_only 'opregion_row_base'
gpio_seam_addr_only 'opregion_row_len'
if [[ "${GPIO_CONFINE_OK}" -ne 1 ]]; then
    echo "  See src/kernel/core/cap/kind_gpio_line.pdx and" >&2
    echo "  src/kernel/core/drivers/gpio/lpss_gpio.pdx for why each of these" >&2
    echo "  has exactly one legitimate writer, and gpio_io.pdx for why no" >&2
    echo "  second address-producing path may exist under core/drivers/gpio/." >&2
    exit 1
fi
echo "[gpio-confine] line row table, controller and community tables, seam"
echo "[gpio-confine] state and the pad-address calculator confined"

# ---------------------------------------------------------------------
# R30.M8-002 (#1083): KIND_FW_SESSION storage confinement.
#
# _fw_object_table IS THE ARBITRATION. It carries the writer claim, the
# claim depth and the session refcount for every firmware object in the
# machine. A second writer could:
#
#   * set a holder, making the next release drop a claim this process
#     never took — which lets a second writer into an object in the
#     middle of the first one's update;
#   * clear a holder mid-episode, with the same consequence and no
#     symptom on either side until the object is read back;
#   * write a scope path, merging two distinct firmware objects into one
#     arbitration domain, so that the claim on one silently excludes a
#     writer on the other and fails to exclude its real peer.
#
# None of those has a symptom at the point of the bug. All three surface
# as a firmware object holding interleaved half-updates, somewhere else,
# later.
#
# _fw_session_table binds a capability to an object. A second writer
# there is a capability that arbitrates against a different object than
# the one it was minted for — the same merge failure reached from the
# other side.
#
# _fw_ep_registry is THE SECOND HALF OF THE DERIVATION GATE. It is the
# whole difference between "the parent is an IPC endpoint", which every
# endpoint in the system satisfies, and "the parent is the firmware
# supervisor's endpoint". A second writer could register the shell's
# endpoint and mint arbitration authority over the embedded controller.
FW_SESSION_CONFINE_OK=1
fw_session_confine_one() {
    local sym="$1" owner="${BUILD_DIR}/$2" strays=""
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[fw-session-confine] FAIL — owner $2 does not reference ${sym}" >&2
        echo "  A confinement assertion that names a symbol its owner does not" >&2
        echo "  use is vacuous; it would pass after the storage was deleted." >&2
        FW_SESSION_CONFINE_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[fw-session-confine] FAIL — objects other than $2 relocate against" >&2
        echo "  ${sym}:${strays}" >&2
        FW_SESSION_CONFINE_OK=0
    fi
}
fw_session_confine_one '_fw_object_table'  'core/cap/kind_fw_session.o'
fw_session_confine_one '_fw_session_table' 'core/cap/kind_fw_session.o'
fw_session_confine_one '_fw_ep_registry'   'core/cap/kind_fw_session.o'
if [[ "${FW_SESSION_CONFINE_OK}" -ne 1 ]]; then
    echo "  See src/kernel/core/cap/kind_fw_session.pdx for why each of these" >&2
    echo "  has exactly one legitimate writer. The claim, the object identity" >&2
    echo "  and the derivation gate all rest on single ownership; none of the" >&2
    echo "  three failures a second writer produces has a symptom where the" >&2
    echo "  bug is." >&2
    exit 1
fi
echo "[fw-session-confine] object table, session table and endpoint registry confined"

# R30.M8-002 (#1083): THE ARBITRATION IS THE OBJECT'S, NOT THE SESSION'S.
#
# fw_session_claim and fw_session_unclaim take a SESSION ROW and nothing
# else. The object they arbitrate is the one that session's row names,
# resolved through fw_session_row_obj.
#
# An object parameter here would make "claim an object my capability does
# not name" expressible — and, worse, would let a caller claim object X
# while writing object Y, which is arbitration that reports success and
# excludes nobody. Pinning the arity means a mutant that adds one fails
# the build rather than the review, the discipline #1075 established for
# GPIO pins and #1081 for the EC transaction address.
FW_SESSION_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_fw_session.pdx"
fw_session_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${FW_SESSION_SRC}"; then
        echo "[fw-session-confine] FAIL — expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "  The claim operations take a SESSION ROW and nothing else. An" >&2
        echo "  object, scope or domain parameter would make 'arbitrate against" >&2
        echo "  something other than what my capability names' expressible, and" >&2
        echo "  a caller that claimed one object while writing another would be" >&2
        echo "  excluding nobody while reporting success. If a signature" >&2
        echo "  legitimately changed, the confinement argument in" >&2
        echo "  kind_fw_session.pdx must be rewritten first." >&2
        exit 1
    fi
}
fw_session_pin_one 'pub let fw_session_claim : (u64) -> u64'
fw_session_pin_one 'pub let fw_session_unclaim : (u64) -> u64'
fw_session_pin_one 'pub let fw_session_row_obj : (u64) -> u64'
echo "[fw-session-confine] claim/unclaim/resolve arities pinned"

GPIO_LINE_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_gpio_line.pdx"
gpio_pin_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${GPIO_LINE_SRC}"; then
        echo "[gpio-pin-confine] FAIL — expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "  Every GPIO line resolver takes a CAPABILITY SLOT (or a row id)" >&2
        echo "  and NOTHING ELSE. An extra parameter on any of them -- a 'pin', a" >&2
        echo "  'community', a 'pad' the caller supplies -- would make 'act on a" >&2
        echo "  pin other than the one my capability names' expressible, which is" >&2
        echo "  precisely the property KIND_GPIO_LINE exists to remove on a part" >&2
        echo "  that owns every pin on the package. Note that a pad's register" >&2
        echo "  address is community.reg_off + community.padbar + pad*stride, so" >&2
        echo "  a supplied community or pad index reaches a different pin just as" >&2
        echo "  surely as a supplied pin number does -- which is why all five are" >&2
        echo "  pinned and not only the first. If this fired because a signature" >&2
        echo "  legitimately changed, the confinement argument in" >&2
        echo "  kind_gpio_line.pdx must be rewritten first." >&2
        exit 1
    fi
}
gpio_pin_pin_one 'pub let gpio_line_row_pin : (u64) -> u64'
gpio_pin_pin_one 'pub let gpio_line_pin_of_slot : (u64) -> u64'
gpio_pin_pin_one 'pub let gpio_line_community_of_slot : (u64) -> u64'
gpio_pin_pin_one 'pub let gpio_line_pad_of_slot : (u64) -> u64'
gpio_pin_pin_one 'pub let gpio_line_ctrl_of_slot : (u64) -> u64'
gpio_pin_pin_one 'pub let gpio_line_pad_off_of_slot : (u64) -> u64'
# R30.M6-003 (#1077): the cached-configuration accessors. The getters are
# arity one like every resolver above. The SETTERS take a second
# parameter and it is a six-bit configuration VALUE, never a selector --
# six bits cannot name one of 512 pins, one of 16 communities or one of
# 128 pads, and gpio_line_set_cfg_of_slot refuses anything wider rather
# than masking it. Pinned here so a mutant that widens either second
# parameter into a pin, community or pad argument fails the build.
gpio_pin_pin_one 'pub let gpio_line_cfg_of_slot : (u64) -> u64'
gpio_pin_pin_one 'pub let gpio_line_set_cfg_of_slot : (u64, u64) -> u64'
gpio_pin_pin_one 'pub let gpio_line_edge_of_slot : (u64) -> u64'
gpio_pin_pin_one 'pub let gpio_line_set_edge_of_slot : (u64, u64) -> u64'
# R30.M6-004 (#1078): the pad driver and its interrupt-register helpers.
# THE STAKES ARE HIGHER HERE THAN FOR THE RESOLVERS ABOVE, because these
# functions WRITE. A caller-supplied pin, community or pad on any of them
# would mean a caller choosing which physical net to drive, which
# terminate, or whose interrupt to acknowledge. Every one of them takes a
# capability slot and, at most, a two-bit configuration value.
GPIO_PAD_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpio/gpio_pad.pdx"
gpio_pad_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${GPIO_PAD_SRC}"; then
        echo "[gpio-pin-confine] FAIL — expected pad-driver declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "  Every function in gpio_pad.pdx takes a CAPABILITY SLOT and, at" >&2
        echo "  most, a narrow configuration value. These are the functions that" >&2
        echo "  actually write PADCFG0, PADCFG1, GPI_IS and GPI_IE, so an extra" >&2
        echo "  parameter here is a caller choosing which physical net to drive." >&2
        echo "  If a signature legitimately changed, the confinement argument in" >&2
        echo "  gpio_pad.pdx must be rewritten first." >&2
        exit 1
    fi
}
gpio_pad_pin_one 'pub let gpio_pad_get_level : (u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_set_level : (u64, u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_set_dir : (u64, u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_set_pull : (u64, u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_edge_subscribe : (u64, u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_edge_unsubscribe : (u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_edge_count : (u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_edge_storm : (u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_comm_base_of_slot : (u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_is_off_of_slot : (u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_ie_off_of_slot : (u64) -> u64'
gpio_pad_pin_one 'pub let gpio_pad_bit_of_slot : (u64) -> u64'
echo "[gpio-pin-confine] pin, community, pad, controller and pad-address"
echo "[gpio-pin-confine] resolvers take no caller-supplied pin"
echo "[gpio-pin-confine] pad driver and interrupt-register helpers take no"
echo "[gpio-pin-confine] caller-supplied pin, community or pad"

# =============================================================================
# R31.M1-001/002/003/004/005 (#1089..#1093): THE EMBEDDED-CONTROLLER PATH.
#
# Six private tables, each with exactly one legitimate writer, and the
# arity pins that make "act on a controller other than the one my
# capability names" unexpressible rather than merely refused.
#
# WHY CONFINEMENT MATTERS MORE HERE THAN ANYWHERE ELSE IN THIS FILE.
# The embedded controller owns battery charging, thermal and fan control,
# the lid switch and keyboard power. A stray write outside the range
# firmware declared can change a charge threshold or a fan curve that
# PERSISTS ACROSS A REBOOT, and the register space outside that range is
# vendor-undocumented -- there is no specification saying what does not
# happen. A second writer to _ec_access_state could widen the extent
# every transaction is confined to; a second writer to _ec_query_table
# could forge a subscription to another machine's controller, or a
# delivery count that hides a starved subscriber.
EC_CONFINE_OK=1
ec_confine_one() {
    local sym="$1" owners_rel="$2" strays="" first_owner_rel="${2%% *}"
    local first_owner="${BUILD_DIR}/${first_owner_rel}"
    if ! obj_relocs_against "${first_owner}" "${sym}"; then
        echo "[ec-confine] FAIL - owner ${first_owner_rel} does not reference ${sym}" >&2
        echo "  A confinement assertion that names a symbol its owner does not" >&2
        echo "  use is vacuous; it would pass after the storage was deleted." >&2
        EC_CONFINE_OK=0
        return
    fi
    local owner_full="" o_rel
    for o_rel in ${owners_rel}; do
        owner_full="${owner_full} ${BUILD_DIR}/${o_rel}"
    done
    for o in "${OBJECTS[@]}"; do
        local is_owner=0
        for w in ${owner_full}; do
            [[ "${o}" == "${w}" ]] && { is_owner=1; break; }
        done
        [[ "${is_owner}" == "1" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[ec-confine] FAIL - objects other than ${owners_rel} relocate against" >&2
        echo "  ${sym}:${strays}" >&2
        EC_CONFINE_OK=0
    fi
}
# The subscription rows. core/acpi/ec_route.pdx walks them on every
# query and must do so through the exported selectors -- this assertion
# is what makes that a build fact rather than a convention, and the
# router was written to satisfy it rather than the other way round.
ec_confine_one '_ec_query_table'  'core/cap/kind_ec_query.o'
# The transaction gate's binding and counters.
ec_confine_one '_ec_access_state' 'core/drivers/ec/ec_access.o'
# The router's own accounting.
ec_confine_one '_ec_route_state'  'core/acpi/ec_route.o'
# R31.M1-004/005 (#1092/#1093): the byte-to-class meaning table, its
# binding, and the per-class counters. The map is the most consequential
# of the four to confine: it is what decides whether an event may be shed
# under pressure and which counter a loss lands in, so a second writer
# could reclassify the power button as a droppable hot-key with no
# capability involved and no counter moving. core/acpi/ec_route.o and
# core/cap/kind_ec_query.o both READ it, and both do so through
# ec_event_class_of, which is what keeps this assertion satisfiable.
ec_confine_one '_ec_evt_map'      'core/acpi/ec_event.o'
ec_confine_one '_ec_evt_owner'    'core/acpi/ec_event.o'
ec_confine_one '_ec_evt_stats'    'core/acpi/ec_event.o'
if [[ "${EC_CONFINE_OK}" -ne 1 ]]; then
    echo "  See src/kernel/core/cap/kind_ec_query.pdx and" >&2
    echo "  src/kernel/core/drivers/ec/ec_access.pdx for why each of these has" >&2
    echo "  exactly one legitimate writer." >&2
    exit 1
fi
echo "[ec-confine] subscription rows, transaction gate and router state confined"

# THE ARITIES. Every one of these takes a capability slot, a row id, or
# a value that can only select within the row it was given -- and never
# a controller address, a base or a length from the caller.
#
# ec_access_bind is the load-bearing one. A base or length parameter
# would let a caller declare an extent the capability does not name, and
# every range refusal in ec_access_audit would then be enforcing the
# caller's claim rather than the kernel's grant -- the entire confinement
# property inverted, with no symptom until a write lands outside the
# region on a machine whose firmware declared a smaller one.
#
# ec_query_row_target is the other. It returns an endpoint IDENTITY and
# takes no pointer, which is what lets the router fan out across the
# subscription rows without an address into the table crossing a module
# boundary. Widening it to hand back a row address would satisfy every
# other check here and quietly void the confinement assertion above.
#
# R31.M1-004 (#1092) adds ec_event_map_bind, which is ec_access_bind's
# twin and load-bearing for the same reason: it takes ONE capability slot
# and inherits the controller address from the region row behind it. A
# second parameter would let a caller attach one machine's event meanings
# to a controller the capability never named, and every classification
# thereafter would be confidently wrong -- a lid event labelled as a
# hot-key is then shed under load, which is the one drop this path is
# built to make impossible.
EC_QUERY_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_ec_query.pdx"
EC_ACCESS_SRC="${REPO_ROOT}/src/kernel/core/drivers/ec/ec_access.pdx"
EC_EVENT_SRC="${REPO_ROOT}/src/kernel/core/acpi/ec_event.pdx"
EVT_STREAM_SRC="${REPO_ROOT}/src/kernel/core/acpi/evt_stream.pdx"
ec_pin_one() {
    local src="$1" decl="$2"
    if ! grep -qF -- "${decl}" "${src}"; then
        echo "[ec-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "  The embedded-controller path takes its controller address, its" >&2
        echo "  base and its extent from the capability, never from a caller. An" >&2
        echo "  extra parameter on any of these makes 'transact with a controller" >&2
        echo "  other than the one my capability names', or 'declare an extent" >&2
        echo "  wider than the one I was granted', expressible -- and on this" >&2
        echo "  device an out-of-range write can change a charge threshold that" >&2
        echo "  survives the reboot. If a signature legitimately changed, the" >&2
        echo "  confinement argument in the module header must be rewritten" >&2
        echo "  first." >&2
        exit 1
    fi
}
ec_pin_one "${EC_ACCESS_SRC}" 'pub let ec_access_bind : (u64) -> u64'
ec_pin_one "${EC_ACCESS_SRC}" 'pub let ec_access_base : () -> u64'
ec_pin_one "${EC_ACCESS_SRC}" 'pub let ec_access_len : () -> u64'
ec_pin_one "${EC_ACCESS_SRC}" 'pub let ec_access_arbitrated : () -> u64'
# R31.M6-#1580: the arbitration binder takes three ADDRESSES, not slots,
# because the FACS host VA and the two PM1 ports come out of fadt_parse
# (not out of a cap_table) and are what aml_glk_attach in ring 3 will
# eventually consume. A caller-facing arity that added a "kind of lock"
# or a "revision" argument would make it expressible to bind arbitration
# against a Global Lock that is not the platform's; the FACS is a system
# singleton, exactly as aml_glk_attach's own arity is pinned in
# tools/verify-aml-parser.sh for the same reason.
ec_pin_one "${EC_ACCESS_SRC}" 'pub let ec_access_bind_arbitration : (u64, u64, u64) -> u64'
ec_pin_one "${EC_ACCESS_SRC}" 'pub let ec_access_facs : () -> u64'
ec_pin_one "${EC_ACCESS_SRC}" 'pub let ec_access_pm1_cnt : () -> u64'
ec_pin_one "${EC_ACCESS_SRC}" 'pub let ec_access_pm1_sts : () -> u64'
ec_pin_one "${EC_QUERY_SRC}"  'pub let ec_query_row_addr : (u64) -> u64'
ec_pin_one "${EC_QUERY_SRC}"  'pub let ec_query_row_target : (u64, u64, u64) -> u64'
ec_pin_one "${EC_QUERY_SRC}"  'pub let ec_query_row_narrow : (u64, u64) -> u64'
ec_pin_one "${EC_EVENT_SRC}"  'pub let ec_event_map_bind : (u64) -> u64'
ec_pin_one "${EC_EVENT_SRC}"  'pub let ec_event_class_of : (u64, u64) -> u64'
ec_pin_one "${EC_EVENT_SRC}"  'pub let ec_event_admit : (u64) -> u64'
# R31.M2-002 (#1095): the class is the ONLY input to the policy. A second
# argument — a depth, a "pressure" hint, an override — is how a caller talks
# a safety class into the sheddable set, and the whole point of splitting the
# policy out of ec_event_admit is that the set membership is a property of the
# class and of nothing else.
ec_pin_one "${EC_EVENT_SRC}"  'pub let ec_event_shed_policy : (u64) -> u64'
ec_pin_one "${EC_QUERY_SRC}"  'pub let ec_query_row_class : (u64, u64) -> u64'
# acpi_evt_offer's arity, pinned here because R31.M1-005 (#1093) made the
# meaning of its fifth argument load-bearing for the class of a platform
# event. It has five call sites, every one of them setting argument
# registers by hand, and NOTHING in this file checked its shape before
# now: a sixth parameter added without touching all five would leave a
# call site passing whatever it happened to leave in r9 as an event class,
# which is a silent-failure surface rather than a build failure. #1093
# declined to add that sixth parameter for exactly this reason and pinned
# the arity so the next attempt is loud instead.
ec_pin_one "${EVT_STREAM_SRC}" 'pub let acpi_evt_offer : (u64, u64, u64, u64, u64) -> u64'
echo "[ec-confine] bind, extent, routing-selector and offer arities pinned"

# THE MONOTONE BITMAP. ec_query_row_narrow is the ONLY function in the
# tree that mutates a notify bitmap, and it can only clear a bit. A
# widening counterpart would make the bitmap a preference dressed as a
# boundary: a holder could give up reach and take it back later, so the
# set of events a subscription can receive would no longer be bounded by
# what the mint gate proved its minter held.
#
# This is a grep for the ABSENCE of a symbol, which is a weaker check
# than the arity pins above and is worth having anyway: the natural name
# for the mutant is the one being searched for, and a contributor adding
# it gets told why it must not exist at the moment of adding it rather
# than in review.
if grep -qE 'ec_query_row_(widen|subscribe|set_bit)' "${EC_QUERY_SRC}"; then
    echo "[ec-confine] FAIL - a widening primitive was added to the notify" >&2
    echo "  bitmap. The bitmap starts full and only ever narrows; see" >&2
    echo "  src/kernel/core/cap/kind_ec_query.pdx" >&2
    echo "  THE NOTIFY BITMAP STARTS FULL AND ONLY EVER NARROWS." >&2
    exit 1
fi
echo "[ec-confine] notify bitmap has no widening primitive"

# THE MONOTONE MEANING TABLE — the notify bitmap's mirror image. That one
# starts FULL and only narrows; this one starts EMPTY and only fills, and
# an entry that has a meaning cannot acquire a different one while the map
# is bound. ec_event_map_set is the only per-entry writer and it REFUSES a
# change of meaning; the only wholesale clears are ec_event_reset and
# ec_event_map_unbind, neither of which is a per-entry operation.
#
# What a demotion primitive would cost: every downstream decision on this
# path is taken from the class -- whether the event may be shed under
# pressure, which counter a loss lands in, what a subscriber does when it
# arrives -- so a byte silently remapped from POWER to HOTKEY turns a
# power-button press into a droppable Fn key, and there is no symptom
# until somebody's machine will not turn off.
#
# The same weaker-than-a-pin grep, for the same reason: the natural name
# for the mutant is the one being searched for.
if grep -qE 'ec_event_(remap|unmap|map_clear|map_override|map_force)' "${EC_EVENT_SRC}"; then
    echo "[ec-confine] FAIL - a demotion primitive was added to the query-byte" >&2
    echo "  meaning table. It starts empty and only ever fills, and an installed" >&2
    echo "  meaning cannot change while the map is bound; see" >&2
    echo "  src/kernel/core/acpi/ec_event.pdx §3" >&2
    echo "  A BYTE THAT MEANS POWER MUST NOT LATER MEAN HOTKEY." >&2
    exit 1
fi
echo "[ec-confine] query-byte meaning table has no demotion primitive"

# ---------------------------------------------------------------------------
# R31.M2-002 (#1095): THE ADMISSION POLICY IS TOTAL OVER THE CLASS ENUMERATION.
#
# §7's shed rule used to be one inequality against EC_EVT_CLASS_HOTKEY. That
# form could say which class IS sheddable but never which classes were
# CONSIDERED, so every class added afterwards was admitted unconditionally by
# a default nobody had to look at. The default is right for a singleton event
# (thermal, battery) and WRONG for a high-rate one -- R31.M4's platform
# sensors would quietly consume the same 32-slot tail-drop ring the power
# button shares, which is §7's inversion arriving past the rule that prevents
# it.
#
# So ec_event_shed_policy enumerates BOTH sets, one equality per member, each
# carrying a `policy: <NAME>` marker. This check is what makes the enumeration
# total: every EC_EVT_CLASS_* declared in the file (except the _MAX bound)
# must have a marker in the policy body. A class declared without one fails
# the build here rather than inheriting an admission decision.
#
# Read out of the source rather than pinned as a number, so the check cannot
# drift from the declarations it is about. Two vacuity guards: the class list
# must be non-empty, and the policy body must be found.
EC_EVT_CLASSES_DECLARED="$(grep -oE '^  pub let EC_EVT_CLASS_([A-Z]+)[[:space:]]*:' "${EC_EVENT_SRC}" \
    | sed -E 's/^  pub let EC_EVT_CLASS_([A-Z]+)[[:space:]]*:/\1/' | grep -v '^MAX$' | sort -u)"
if [[ -z "${EC_EVT_CLASSES_DECLARED}" ]]; then
    echo "[ec-confine] FAIL - no EC_EVT_CLASS_* declarations found in" >&2
    echo "  ${EC_EVENT_SRC}" >&2
    echo "  This check is vacuous unless it can read the enumeration." >&2
    exit 1
fi
EC_EVT_POLICY_BODY="$(awk '/pub let ec_event_shed_policy/,/ec_evt_sp_always:/' "${EC_EVENT_SRC}")"
if ! grep -q 'ec_evt_sp_always' <<<"${EC_EVT_POLICY_BODY}"; then
    echo "[ec-confine] FAIL - ec_event_shed_policy not found in" >&2
    echo "  ${EC_EVENT_SRC}" >&2
    echo "  §7's admission policy must be a total function over the class" >&2
    echo "  enumeration; without it every class is admitted by default." >&2
    exit 1
fi
for _cls in ${EC_EVT_CLASSES_DECLARED}; do
    if ! grep -qE "//[[:space:]]*policy:[[:space:]]*${_cls}\$" <<<"${EC_EVT_POLICY_BODY}"; then
        echo "[ec-confine] FAIL - EC_EVT_CLASS_${_cls} is declared but has no" >&2
        echo "  \`policy: ${_cls}\` row in ec_event_shed_policy." >&2
        echo "" >&2
        echo "  A CLASS MUST BE ADMITTED OR SHED BY A DECISION, NEVER BY A" >&2
        echo "  DEFAULT. Add it to the SHED_ALWAYS enumeration if it is a" >&2
        echo "  singleton the machine produced once and cannot replay (AC," >&2
        echo "  lid, power button, a thermal trip), or to SHED_WATERMARK if" >&2
        echo "  it is bursty and its loss costs a keystroke. Both are" >&2
        echo "  enumerations in src/kernel/core/acpi/ec_event.pdx §7; the" >&2
        echo "  marker comment is what this check reads." >&2
        exit 1
    fi
done
echo "[ec-confine] shed policy covers every declared event class"

# ---------------------------------------------------------------------------
# R31.M2-001 (#1094): THE THERMAL PATH.
#
# Three claims, all of them about the same thing: a temperature THRESHOLD is
# never an argument, and a temperature is never converted before it is
# compared.
#
# (a) _thermal_zone_table is the only place in the kernel where a critical
#     threshold lives. A second writer could raise a _CRT with no capability
#     involved and no refusal recorded, and the machine would then run past a
#     limit its firmware set. _thermal_zone_stats is confined for the weaker
#     but adjacent reason ec_event's counters are: they are the only evidence
#     that a zone's readings are being refused as implausible, and evidence a
#     second object can write is not evidence.
#
# (b) Arity pins. The critical threshold comes from the ROW, so the functions
#     that reach one take a capability and nothing else. `crt_of_slot(slot,
#     fallback)` reads as a convenience and is a way to shut a machine down by
#     arithmetic; `assess(slot, temp, threshold)` is a way to keep it running
#     past its limit. Neither is expressible against the pinned signatures.
#     thermal_dk_to_dc is pinned at ONE argument for the sibling reason: a
#     scale or an offset parameter is how a conversion silently becomes the
#     wrong conversion.
#
# (c) Absence greps for the primitives whose natural names a future change
#     would reach for. A _CRT that can be raised is not a critical threshold.
THERMAL_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_thermal_zone.pdx"
if [[ ! -f "${THERMAL_SRC}" ]]; then
    echo "[thermal-confine] FAIL - ${THERMAL_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_thermal_zone_table' 'core/cap/kind_thermal_zone.o'
ec_confine_one '_thermal_zone_stats' 'core/cap/kind_thermal_zone.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_thermal_zone.pdx §1 and §3 for why" >&2
    echo "  the row table has exactly one writer." >&2
    exit 1
fi
echo "[thermal-confine] zone rows and sensor counters confined"

th_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${THERMAL_SRC}"; then
        echo "[thermal-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A THERMAL THRESHOLD COMES FROM THE CAPABILITY'S OWN ROW AND" >&2
        echo "  NEVER FROM A CALLER. An extra parameter on any of these makes" >&2
        echo "  'compare against a critical threshold of my choosing'" >&2
        echo "  expressible, and the two ways that goes wrong are a healthy" >&2
        echo "  machine powered off and a part left running past its limit." >&2
        echo "  If a signature legitimately changed, the confinement argument" >&2
        echo "  in src/kernel/core/cap/kind_thermal_zone.pdx §1 must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
th_pin_one 'pub let thermal_zone_crt_of_slot : (u64) -> u64'
th_pin_one 'pub let thermal_zone_level_of_slot : (u64) -> u64'
th_pin_one 'pub let thermal_zone_crt_latched_of_slot : (u64) -> u64'
th_pin_one 'pub let thermal_zone_row_of_slot : (u64) -> u64'
th_pin_one 'pub let thermal_zone_row_crt : (u64) -> u64'
th_pin_one 'pub let thermal_zone_assess : (u64, u64) -> u64'
th_pin_one 'pub let thermal_dk_to_dc : (u64) -> u64'
th_pin_one 'pub let thermal_dk_plausible : (u64) -> u64'
echo "[thermal-confine] threshold resolvers, assess and unit conversion arities pinned"

# A _CRT THAT CAN BE RAISED IS NOT A CRITICAL THRESHOLD. The trip table is
# installed once per row and _CRT is not part of the installable set at all;
# these are the names a future "the machine keeps shutting down, let me nudge
# the limit" change would be given, and it is the most plausible-sounding
# request anybody will ever make of this file.
if grep -qE 'thermal_zone_(set_crt|crt_set|raise_crt|crt_override|trips_update|trips_set|trip_override|relatch|clear_latch|latch_clear)' "${THERMAL_SRC}"; then
    echo "[thermal-confine] FAIL - a threshold-mutating or latch-clearing" >&2
    echo "  primitive was added to the thermal zone kind." >&2
    echo "" >&2
    echo "  _CRT is set once, by the mint, and the optional trips fill exactly" >&2
    echo "  once; see src/kernel/core/cap/kind_thermal_zone.pdx §1 and §2." >&2
    echo "  A CONFIRMED CRITICAL CROSSING IS ALSO NOT CLEARABLE: a part that" >&2
    echo "  went past its limit did go past it, and a later cool reading is" >&2
    echo "  evidence that something started cooling it, not evidence that it" >&2
    echo "  never happened. Only a revoke clears the latch." >&2
    exit 1
fi
echo "[thermal-confine] no threshold-mutating or latch-clearing primitive"

# The unit discipline, as a build fact. thermal_dk_to_dc is DISPLAY ONLY;
# see §0. A control-path caller would be a place where a deci-Kelvin
# quantity is turned into a deci-Celsius one before a comparison, which is
# the entire class of bug §0 is written about — and it would be invisible,
# because the arithmetic is a single subtraction that never fails.
#
# TWO objects may reach it, not one, and the second is not a weakening.
# core/cap/kind_thermal_zone.o is the printer. tests/kernel/cap/
# thermal_zone_synth.o is the witness that asserts 3000 dK -> 268 dC
# against the two wrong answers a missing offset and a reversed one would
# give, and a confinement that excluded it would be a confinement that
# forbade checking the thing it protects. Both are enumerated by name, so
# a THIRD caller still fails here.
th_dc_owners='core/cap/kind_thermal_zone.o tests/kernel/cap/thermal_zone_synth.o'
th_dc_strays=''
th_dc_seen=0
for o in "${OBJECTS[@]}"; do
    rel="${o#"${BUILD_DIR}"/}"
    if obj_relocs_against "${o}" 'thermal_dk_to_dc'; then
        case " ${th_dc_owners} " in
            *" ${rel} "*) th_dc_seen=$((th_dc_seen + 1)) ;;
            *) th_dc_strays="${th_dc_strays} ${rel}" ;;
        esac
    fi
done
if [[ "${th_dc_seen}" -ne 2 ]]; then
    echo "[thermal-confine] FAIL - expected both the printer and the witness" >&2
    echo "  to call thermal_dk_to_dc; found ${th_dc_seen} of 2." >&2
    echo "  A confinement assertion that names a symbol nobody uses is" >&2
    echo "  vacuous; it would pass after the conversion was deleted, and the" >&2
    echo "  witness half is what proves the conversion is the right one." >&2
    exit 1
fi
if [[ -n "${th_dc_strays}" ]]; then
    echo "[thermal-confine] FAIL - objects other than the printer and its" >&2
    echo "  witness relocate against thermal_dk_to_dc:${th_dc_strays}" >&2
    echo "" >&2
    echo "  thermal_dk_to_dc is the ONLY unit conversion in the thermal path" >&2
    echo "  and it exists for the row printer. Every comparison that decides" >&2
    echo "  anything happens between two deci-Kelvin quantities, which is why" >&2
    echo "  no decision in that module can be wrong about the unit. A third" >&2
    echo "  object calling it is an object that has an opinion about which" >&2
    echo "  scale a threshold is in, and that opinion is where a trip point" >&2
    echo "  silently becomes 178 degrees below zero." >&2
    echo "  See src/kernel/core/cap/kind_thermal_zone.pdx §0." >&2
    exit 1
fi
echo "[thermal-confine] unit conversion reached only by the printer and its witness"

# ---------------------------------------------------------------------------
# R31.M2-003 (#1096): THERMAL POLICY MAP CONFINEMENT.
#
# `_thermal_policy_map` is the only place in the kernel where a
# level-to-intent binding lives, and the whole security argument of §2 is
# that its ONLY writer -- `thermal_policy_map_install` -- is monotone: an
# entry, once filled with an intent, cannot silently mean something
# different later. A kernel object outside `thermal_policy.o` that
# relocated against the table would be an object that could write an
# entry without passing the monotonicity gate, and there would be no
# symptom until an installed NOMINAL that used to mean NONE started
# meaning ACTIVE.
#
# Same shape as the op-region, GPE and thermal-zone table checks above.
# Runs on every build (including inside the smoke matrix) rather than only
# at push time, so a mutant that spread writes across two objects fails
# here before the boot witness has a chance to look like it passed.
#
# The two readers -- `thermal_policy_intent_of_level` and
# `thermal_policy_intent_of_slot` -- ALSO have their arities pinned. A
# level reader that took a second argument would be a lookup a caller
# could satisfy with a value not in the table (§2 in thermal_policy.pdx
# spells the shape). A slot reader that took a second argument would be
# how a caller-supplied "assumed level" reaches a comparison whose
# outcome is a shutdown intent (§3 in thermal_policy.pdx). Both fail
# reviewably; the arity pin is what catches the drift mechanically.
# ---------------------------------------------------------------------------
TP_OWNER="${BUILD_DIR}/core/policy/thermal_policy.o"
if [[ ! -f "${TP_OWNER}" ]]; then
    echo "[thermal-policy-confine] FAIL: ${TP_OWNER} not built" >&2
    exit 1
fi
if ! obj_relocs_against "${TP_OWNER}" '_thermal_policy_map'; then
    echo "[thermal-policy-confine] FAIL: thermal_policy.o does not reference" >&2
    echo "  _thermal_policy_map. The symbol was renamed or the module was" >&2
    echo "  gutted; the confinement check would then pass vacuously." >&2
    exit 1
fi
tp_strays=""
for o in "${OBJECTS[@]}"; do
    [[ "${o}" == "${TP_OWNER}" ]] && continue
    if obj_relocs_against "${o}" '_thermal_policy_map'; then
        tp_strays="${tp_strays} ${o#"${BUILD_DIR}"/}"
    fi
done
if [[ -n "${tp_strays}" ]]; then
    echo "[thermal-policy-confine] FAIL - objects other than" >&2
    echo "  core/policy/thermal_policy.o relocate against _thermal_policy_map:" >&2
    echo " ${tp_strays}" >&2
    echo "  Only thermal_policy_map_install may write an entry, and the" >&2
    echo "  monotonicity gate is the only reason a level cannot silently" >&2
    echo "  change meaning. See src/kernel/core/policy/thermal_policy.pdx §2." >&2
    exit 1
fi
echo "[thermal-policy-confine] level-to-intent map confined"

TP_SRC="${REPO_ROOT}/src/kernel/core/policy/thermal_policy.pdx"
if [[ ! -f "${TP_SRC}" ]]; then
    echo "[thermal-policy-confine] FAIL - ${TP_SRC} not found" >&2
    exit 1
fi
tp_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${TP_SRC}"; then
        echo "[thermal-policy-confine] FAIL - expected declaration not found:" >&2
        echo "  ${decl}" >&2
        echo "  A signature change to either intent reader is how a caller-" >&2
        echo "  supplied value reaches a policy decision it should not be" >&2
        echo "  able to influence. See §2/§3 in thermal_policy.pdx." >&2
        exit 1
    fi
}
tp_pin_one 'pub let thermal_policy_intent_of_level : (u64) -> u64'
tp_pin_one 'pub let thermal_policy_intent_of_slot : (u64) -> u64'
tp_pin_one 'pub let thermal_policy_map_install : (u64, u64) -> u64'
echo "[thermal-policy-confine] intent-reader and map-install arities pinned"

# ---------------------------------------------------------------------------
# R31.M3-001 (#1099): THE BATTERY PATH.
#
# Same shape as the thermal-zone check above. Two claims:
#
# (a) _battery_table is the only place in the kernel where a design
#     capacity lives. A second writer could raise or lower it with no
#     capability involved and no refusal recorded, and every future
#     percent calculation for that pack would then divide by a number
#     the firmware never advertised. _battery_stats is confined for the
#     weaker but adjacent reason ec_event's and thermal_zone's counters
#     are: they are the only evidence that a pack's reports are being
#     refused as implausible, and evidence a second object can write is
#     not evidence.
#
# (b) Arity pins. The static identity (design capacity, index,
#     chemistry) comes from the ROW, so the slot-arity-one resolvers
#     take a capability and nothing else. `design_of_slot(slot, scale)`
#     is how a healthy pack silently becomes a nearly-dead one; refused
#     by the pinned signature. battery_report_install pins at ARITY
#     FOUR: a fifth argument would be a caller-supplied design capacity
#     or index reaching a row §1 declares set-once at mint.
BATTERY_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_battery.pdx"
if [[ ! -f "${BATTERY_SRC}" ]]; then
    echo "[battery-confine] FAIL - ${BATTERY_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_battery_table' 'core/cap/kind_battery.o'
ec_confine_one '_battery_stats' 'core/cap/kind_battery.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_battery.pdx §1 for why the row" >&2
    echo "  table has exactly one writer." >&2
    exit 1
fi
echo "[battery-confine] battery rows and sensor counters confined"

bt_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${BATTERY_SRC}"; then
        echo "[battery-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A BATTERY DESIGN CAPACITY, INDEX AND CHEMISTRY COME FROM THE" >&2
        echo "  CAPABILITY'S OWN ROW AND NEVER FROM A CALLER. An extra" >&2
        echo "  parameter on any of these makes 'report against a battery" >&2
        echo "  other than the one my capability names' expressible, and the" >&2
        echo "  two ways that goes wrong are a healthy pack labelled" >&2
        echo "  CRITICAL and a nearly-flat pack reporting as full. If a" >&2
        echo "  signature legitimately changed, the confinement argument in" >&2
        echo "  src/kernel/core/cap/kind_battery.pdx §1 must be rewritten" >&2
        echo "  first." >&2
        exit 1
    fi
}
bt_pin_one 'pub let battery_design_of_slot : (u64) -> u64'
bt_pin_one 'pub let battery_percent_of_slot : (u64) -> u64'
bt_pin_one 'pub let battery_state_of_slot : (u64) -> u64'
bt_pin_one 'pub let battery_row_of_slot : (u64) -> u64'
bt_pin_one 'pub let battery_row_design : (u64) -> u64'
bt_pin_one 'pub let battery_report_install : (u64, u64, u64, u64) -> u64'
bt_pin_one 'pub let battery_percent_valid : (u64) -> u64'
bt_pin_one 'pub let battery_voltage_valid : (u64) -> u64'
bt_pin_one 'pub let battery_state_valid : (u64) -> u64'
bt_pin_one 'pub let battery_chem_valid : (u64) -> u64'
echo "[battery-confine] static-identity resolvers, report installer and unit validators arities pinned"

# A DESIGN CAPACITY THAT CAN BE CHANGED IS NOT DESIGN DATA. The natural
# names for the mutant are searched for so a contributor adding one gets
# told why it must not exist at the moment of adding it rather than in
# review — the same shape as the thermal-zone latch-clear grep.
if grep -qE 'battery_(set_design|design_set|raise_design|lower_design|design_override|set_chem|chem_set|set_index)' "${BATTERY_SRC}"; then
    echo "[battery-confine] FAIL - a static-identity-mutating primitive was" >&2
    echo "  added to the battery kind." >&2
    echo "" >&2
    echo "  design_cap_mwh, index and chemistry are set once, by the mint," >&2
    echo "  and there is no primitive that changes them; see" >&2
    echo "  src/kernel/core/cap/kind_battery.pdx §1." >&2
    echo "  A DESIGN CAPACITY THAT CAN BE RAISED WOULD MAKE A NEARLY-FLAT" >&2
    echo "  PACK LOOK BARELY USED; ONE THAT CAN BE LOWERED WOULD MAKE A" >&2
    echo "  HEALTHY PACK LOOK NEARLY DEAD." >&2
    exit 1
fi
echo "[battery-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R31.M4-001 (#1103): THE COOLING-DEVICE PATH.
#
# Same shape as the thermal-zone and battery checks above. Two claims:
#
# (a) _cooling_device_table is the only place in the kernel where a
#     cooling state_max lives. A second writer could raise or lower it
#     with no capability involved and no refusal recorded, and every
#     future policy decision for that actuator would then be taken
#     against a range the firmware never advertised. _cooling_device_stats
#     is confined for the weaker but adjacent reason ec_event's,
#     thermal_zone's and battery's counters are: they are the only
#     evidence that a cooler's reports are being refused as
#     implausible, and evidence a second object can write is not
#     evidence.
#
# (b) Arity pins. The static identity (state_max, cooling_type) comes
#     from the ROW, so the slot-arity-one resolvers take a capability
#     and nothing else. `max_of_slot(slot, scale)` is how the
#     advertised range of a fan silently widens or shrinks; refused by
#     the pinned signature. cooling_report_install pins at ARITY TWO:
#     a third argument would be a caller-supplied state_max or index
#     reaching a row §1 declares set-once at mint.
COOLING_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_cooling_device.pdx"
if [[ ! -f "${COOLING_SRC}" ]]; then
    echo "[cooling-confine] FAIL - ${COOLING_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_cooling_device_table' 'core/cap/kind_cooling_device.o'
ec_confine_one '_cooling_device_stats' 'core/cap/kind_cooling_device.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_cooling_device.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[cooling-confine] cooling rows and actuator counters confined"

cool_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${COOLING_SRC}"; then
        echo "[cooling-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A COOLING STATE_MAX, TYPE AND INDEX COME FROM THE CAPABILITY'S" >&2
        echo "  OWN ROW AND NEVER FROM A CALLER. An extra parameter on any of" >&2
        echo "  these makes 'report against a cooler other than the one my" >&2
        echo "  capability names' expressible, and the two ways that goes" >&2
        echo "  wrong are a fan pinned at its top speed regardless of intent" >&2
        echo "  and a part left uncooled because the actuator dropped to its" >&2
        echo "  floor. If a signature legitimately changed, the confinement" >&2
        echo "  argument in src/kernel/core/cap/kind_cooling_device.pdx §1" >&2
        echo "  must be rewritten first." >&2
        exit 1
    fi
}
cool_pin_one 'pub let cooling_max_of_slot : (u64) -> u64'
cool_pin_one 'pub let cooling_state_of_slot : (u64) -> u64'
cool_pin_one 'pub let cooling_type_of_slot : (u64) -> u64'
cool_pin_one 'pub let cooling_row_of_slot : (u64) -> u64'
cool_pin_one 'pub let cooling_row_max : (u64) -> u64'
cool_pin_one 'pub let cooling_report_install : (u64, u64) -> u64'
cool_pin_one 'pub let cooling_type_valid : (u64) -> u64'
echo "[cooling-confine] static-identity resolvers, report installer and type validator arities pinned"

# A STATE_MAX THAT CAN BE CHANGED IS NOT A CONTROL SURFACE. The natural
# names for the mutant are searched for so a contributor adding one gets
# told why it must not exist at the moment of adding it rather than in
# review — the same shape as the battery static-identity-mutant grep.
if grep -qE 'cooling_(set_max|max_set|raise_max|lower_max|max_override|set_min|min_set|set_type|type_set|set_index)' "${COOLING_SRC}"; then
    echo "[cooling-confine] FAIL - a static-identity-mutating primitive was" >&2
    echo "  added to the cooling-device kind." >&2
    echo "" >&2
    echo "  state_min, state_max, cooling_type and index are set once, by" >&2
    echo "  the mint, and there is no primitive that changes them; see" >&2
    echo "  src/kernel/core/cap/kind_cooling_device.pdx §1." >&2
    echo "  A STATE_MAX THAT CAN BE RAISED WOULD WIDEN A FAN'S ADVERTISED" >&2
    echo "  RANGE PAST WHAT THE FIRMWARE APPROVED; ONE THAT CAN BE LOWERED" >&2
    echo "  WOULD MAKE THE TOP SPEED THE PLATFORM IS WILLING TO RUN" >&2
    echo "  UNREACHABLE." >&2
    exit 1
fi
echo "[cooling-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R31.M5-001 (#1106): THE BACKLIGHT PATH.
#
# Same shape as the cooling, battery and thermal-zone checks above. Two
# claims:
#
# (a) _backlight_table is the only place in the kernel where a
#     brightness_max lives. A second writer could raise or lower it
#     with no capability involved and no refusal recorded, and every
#     future policy decision for that panel would then be taken
#     against a range the firmware never advertised.
#     _backlight_stats is confined for the weaker but adjacent reason
#     ec_event's, thermal_zone's, battery's and cooling's counters
#     are: they are the only evidence that a panel's reports are
#     being refused as implausible, and evidence a second object can
#     write is not evidence.
#
# (b) Arity pins. The static identity (brightness_max, backend,
#     index) comes from the ROW, so the slot-arity-one resolvers
#     take a capability and nothing else. `max_of_slot(slot, scale)`
#     is how the advertised range of a panel silently widens or
#     shrinks; refused by the pinned signature.
#     backlight_report_install pins at ARITY TWO: a third argument
#     would be a caller-supplied brightness_max or index reaching a
#     row §1 declares set-once at mint.
BACKLIGHT_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_backlight.pdx"
if [[ ! -f "${BACKLIGHT_SRC}" ]]; then
    echo "[backlight-confine] FAIL - ${BACKLIGHT_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_backlight_table' 'core/cap/kind_backlight.o'
ec_confine_one '_backlight_stats' 'core/cap/kind_backlight.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_backlight.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[backlight-confine] backlight rows and controller counters confined"

bl_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${BACKLIGHT_SRC}"; then
        echo "[backlight-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A BACKLIGHT BRIGHTNESS_MAX, BACKEND AND INDEX COME FROM THE" >&2
        echo "  CAPABILITY'S OWN ROW AND NEVER FROM A CALLER. An extra" >&2
        echo "  parameter on any of these makes 'report against a panel other" >&2
        echo "  than the one my capability names' expressible, and the two" >&2
        echo "  ways that goes wrong are a panel silently pinned at maximum" >&2
        echo "  intensity and one dropped to unreadable dimness. If a" >&2
        echo "  signature legitimately changed, the confinement argument in" >&2
        echo "  src/kernel/core/cap/kind_backlight.pdx §1 must be rewritten" >&2
        echo "  first." >&2
        exit 1
    fi
}
bl_pin_one 'pub let backlight_max_of_slot : (u64) -> u64'
bl_pin_one 'pub let backlight_current_of_slot : (u64) -> u64'
bl_pin_one 'pub let backlight_backend_of_slot : (u64) -> u64'
bl_pin_one 'pub let backlight_row_of_slot : (u64) -> u64'
bl_pin_one 'pub let backlight_row_max : (u64) -> u64'
bl_pin_one 'pub let backlight_report_install : (u64, u64) -> u64'
bl_pin_one 'pub let backlight_backend_valid : (u64) -> u64'
echo "[backlight-confine] static-identity resolvers, report installer and backend validator arities pinned"

# A BRIGHTNESS_MAX THAT CAN BE CHANGED IS NOT A CONTROL SURFACE. The
# natural names for the mutant are searched for so a contributor adding
# one gets told why it must not exist at the moment of adding it rather
# than in review — the same shape as the cooling static-identity-mutant
# grep.
if grep -qE 'backlight_(set_max|max_set|raise_max|lower_max|max_override|set_min|min_set|set_backend|backend_set|set_index)' "${BACKLIGHT_SRC}"; then
    echo "[backlight-confine] FAIL - a static-identity-mutating primitive was" >&2
    echo "  added to the backlight kind." >&2
    echo "" >&2
    echo "  brightness_min, brightness_max, backend and index are set once," >&2
    echo "  by the mint, and there is no primitive that changes them; see" >&2
    echo "  src/kernel/core/cap/kind_backlight.pdx §1." >&2
    echo "  A BRIGHTNESS_MAX THAT CAN BE RAISED WOULD WIDEN A PANEL'S" >&2
    echo "  ADVERTISED RANGE PAST WHAT THE FIRMWARE APPROVED; ONE THAT" >&2
    echo "  CAN BE LOWERED WOULD MAKE THE PANEL'S USABLE PEAK BRIGHTNESS" >&2
    echo "  UNREACHABLE." >&2
    exit 1
fi
echo "[backlight-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R32.M3-001 (#1125): THE HID DEVICE PATH.
#
# Same shape as the backlight / cooling / battery / thermal-zone checks
# above. Two claims:
#
# (a) _hid_device_table is the only place in the kernel where a HID
#     device's report_id_count and identity (vendor:product,
#     transport) live. A second writer could raise the report count
#     or restamp the identity with no capability involved and no
#     refusal recorded, and every future report_install for that
#     device would then be recorded against a shape the class driver
#     never proved. _hid_device_stats is confined for the weaker but
#     adjacent reason ec_event's, thermal_zone's, battery's,
#     cooling's and backlight's counters are: they are the only
#     evidence that reports have been installed at all, and evidence
#     a second object can write is not evidence.
#
# (b) Arity pins. The static identity (transport, vendor, product,
#     rid_count) comes from the ROW, so the slot-arity-one resolvers
#     take a capability and nothing else. `transport_of_slot(slot,
#     assumed)` reads as a convenience and is a way to make a
#     touchpad answer to a subscription filtered on USB by
#     arithmetic; refused by the pinned signature.
#     hid_device_report_install pins at ARITY ONE: a second argument
#     would be a report byte or a pointer to one, and either is a way
#     to feed the class driver's next parse from an address of the
#     caller's choosing (§3).
HID_DEVICE_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_hid_device.pdx"
if [[ ! -f "${HID_DEVICE_SRC}" ]]; then
    echo "[hid-device-confine] FAIL - ${HID_DEVICE_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_hid_device_table' 'core/cap/kind_hid_device.o'
ec_confine_one '_hid_device_stats' 'core/cap/kind_hid_device.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_hid_device.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[hid-device-confine] HID device rows and counter confined"

hidd_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HID_DEVICE_SRC}"; then
        echo "[hid-device-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A HID DEVICE'S REPORT_ID_COUNT, TRANSPORT, VENDOR AND PRODUCT" >&2
        echo "  COME FROM THE CAPABILITY'S OWN ROW AND NEVER FROM A CALLER." >&2
        echo "  An extra parameter on any of these makes 'report against a" >&2
        echo "  device other than the one my capability names' expressible," >&2
        echo "  and the two ways that goes wrong are a touchpad silently" >&2
        echo "  answering to a keyboard subscription and a keyboard silently" >&2
        echo "  answering to a touchpad subscription. If a signature" >&2
        echo "  legitimately changed, the confinement argument in" >&2
        echo "  src/kernel/core/cap/kind_hid_device.pdx §1 must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
hidd_pin_one 'pub let hid_device_rid_count_of_slot : (u64) -> u64'
hidd_pin_one 'pub let hid_device_vendor_of_slot : (u64) -> u64'
hidd_pin_one 'pub let hid_device_product_of_slot : (u64) -> u64'
hidd_pin_one 'pub let hid_device_transport_of_slot : (u64) -> u64'
hidd_pin_one 'pub let hid_device_row_of_slot : (u64) -> u64'
hidd_pin_one 'pub let hid_device_row_rid_count : (u64) -> u64'
hidd_pin_one 'pub let hid_device_report_install : (u64) -> u64'
hidd_pin_one 'pub let hid_device_transport_valid : (u64) -> u64'
echo "[hid-device-confine] static-identity resolvers, report installer and transport validator arities pinned"

# A REPORT_ID_COUNT THAT CAN BE CHANGED IS NOT A DEVICE IDENTITY. The
# natural names for the mutant are searched for so a contributor adding
# one gets told why it must not exist at the moment of adding it rather
# than in review.
if grep -qE 'hid_device_(set_rid_count|rid_count_set|raise_rid_count|set_transport|transport_set|set_vendor|vendor_set|set_product|product_set|set_index|index_set)' "${HID_DEVICE_SRC}"; then
    echo "[hid-device-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the HID device kind." >&2
    echo "" >&2
    echo "  index, transport, vendor_id, product_id and report_id_count are" >&2
    echo "  set once, by the mint, and there is no primitive that changes" >&2
    echo "  them; see src/kernel/core/cap/kind_hid_device.pdx §1." >&2
    echo "  A REPORT_ID_COUNT THAT CAN BE RAISED WOULD LET A CLASS DRIVER" >&2
    echo "  READ PAST THE BUFFER ANY LEGITIMATE PARSER SIZED; ONE THAT CAN" >&2
    echo "  BE LOWERED WOULD LET A LEGITIMATE REPORT ID BECOME UNREACHABLE" >&2
    echo "  AND ITS DATA NEVER ROUTED." >&2
    exit 1
fi
echo "[hid-device-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R33.M1-005 (#1141): THE AUDIO CONTROLLER PATH.
#
# Same shape as the backlight / hid-device checks above. Two claims:
#
# (a) _audio_controller_table is the only place in the kernel where an
#     HDA controller's bar_handle, corb_size and rirb_size live. A
#     second writer could restamp them with no capability involved and
#     no refusal recorded, and every future GET_PARAMETER by the
#     discovery driver would then address a BAR window nobody proved.
#     _audio_ctrl_stats is confined for the weaker but adjacent reason
#     ec_event's / thermal_zone's / hid_device's counters are: they are
#     the only evidence that reports have been installed at all.
#
# (b) Arity pins. The static identity (bar_handle, ring shapes) comes
#     from the ROW, so the slot-arity-one resolvers take a capability
#     and nothing else. `bar_of_slot(slot, default_bar)` reads as a
#     convenience and is a way to widen a controller's advertised BAR.
#     audio_ctrl_report_install pins at ARITY TWO: a third argument
#     would be a caller-supplied bar_handle or ring shape reaching a
#     row §1 declares set-once at mint.
AUDIO_CTRL_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_audio_controller.pdx"
if [[ ! -f "${AUDIO_CTRL_SRC}" ]]; then
    echo "[audio-ctrl-confine] FAIL - ${AUDIO_CTRL_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_audio_controller_table' 'core/cap/kind_audio_controller.o'
ec_confine_one '_audio_ctrl_stats' 'core/cap/kind_audio_controller.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_audio_controller.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[audio-ctrl-confine] audio controller rows and counter confined"

ac_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${AUDIO_CTRL_SRC}"; then
        echo "[audio-ctrl-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  AN HDA CONTROLLER'S BAR_HANDLE, CORB_SIZE AND RIRB_SIZE COME" >&2
        echo "  FROM THE CAPABILITY'S OWN ROW AND NEVER FROM A CALLER. An" >&2
        echo "  extra parameter on any of these makes 'report against a" >&2
        echo "  controller other than the one my capability names'" >&2
        echo "  expressible, and the two ways that goes wrong are one" >&2
        echo "  driver's DMA reaching another driver's BAR window. If a" >&2
        echo "  signature legitimately changed, the confinement argument in" >&2
        echo "  src/kernel/core/cap/kind_audio_controller.pdx §1 must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
ac_pin_one 'pub let audio_ctrl_bar_of_slot : (u64) -> u64'
ac_pin_one 'pub let audio_ctrl_codecs_of_slot : (u64) -> u64'
ac_pin_one 'pub let audio_ctrl_reports_of_slot : (u64) -> u64'
ac_pin_one 'pub let audio_ctrl_row_of_slot : (u64) -> u64'
ac_pin_one 'pub let audio_ctrl_row_bar : (u64) -> u64'
ac_pin_one 'pub let audio_ctrl_report_install : (u64, u64) -> u64'
ac_pin_one 'pub let audio_ctrl_corb_size_valid : (u64) -> u64'
ac_pin_one 'pub let audio_ctrl_rirb_size_valid : (u64) -> u64'
echo "[audio-ctrl-confine] static-identity resolvers, report installer and ring-size validator arities pinned"

# A BAR_HANDLE OR RING SHAPE THAT CAN BE CHANGED IS NOT A CONTROLLER
# IDENTITY. The natural names for the mutant are searched for so a
# contributor adding one gets told why it must not exist at the moment
# of adding it rather than in review.
if grep -qE 'audio_ctrl_(set_bar|bar_set|raise_bar|set_corbsz|corbsz_set|set_rirbsz|rirbsz_set|set_key|key_set)' "${AUDIO_CTRL_SRC}"; then
    echo "[audio-ctrl-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the audio controller kind." >&2
    echo "" >&2
    echo "  hda_key, bar_handle, corb_size and rirb_size are set once, by" >&2
    echo "  the mint, and there is no primitive that changes them; see" >&2
    echo "  src/kernel/core/cap/kind_audio_controller.pdx §1." >&2
    exit 1
fi
echo "[audio-ctrl-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R33.M3-001 (#1147) + R33.M3-005 (#1151): THE PCM STREAM PATH.
#
# Same shape as the audio-controller check above. Two claims:
#
# (a) _pcm_stream_table is the only place in the kernel where a PCM
#     stream's audio_clock_slot, ring_bo_key, sample_format, sample_rate,
#     channels and position live. A second writer could restamp
#     audio_clock_slot with no capability involved and no refusal
#     recorded, and every future presentation-time computation would
#     then be relative to a clock the mint never approved. This is
#     what LINEAR means for this kind. _pcm_stream_stats is confined
#     for the sibling reason (only evidence that mints, xclock refusals
#     and position advances happened at all).
#
# (b) Arity pins. The static identity comes FROM the ROW, so the
#     slot-arity-one resolvers take a capability and nothing else.
#     position_advance pins at ARITY TWO: a third argument would be a
#     caller-supplied clock or ring reaching a §1-set-once field.
PCM_STREAM_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_pcm_stream.pdx"
if [[ ! -f "${PCM_STREAM_SRC}" ]]; then
    echo "[pcm-stream-confine] FAIL - ${PCM_STREAM_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_pcm_stream_table' 'core/cap/kind_pcm_stream.o'
ec_confine_one '_pcm_stream_stats' 'core/cap/kind_pcm_stream.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_pcm_stream.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[pcm-stream-confine] pcm stream rows and counter confined"

pcm_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${PCM_STREAM_SRC}"; then
        echo "[pcm-stream-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A PCM STREAM'S audio_clock_slot, ring_bo_key, sample_format," >&2
        echo "  sample_rate AND channels COME FROM THE CAPABILITY'S OWN ROW" >&2
        echo "  AND NEVER FROM A CALLER. An extra parameter on any of these" >&2
        echo "  makes 'advance a stream against a clock other than the one" >&2
        echo "  my capability names' expressible, and the two ways that goes" >&2
        echo "  wrong are two producers on one ring at two different clocks." >&2
        echo "  If a signature legitimately changed, the LINEAR discipline" >&2
        echo "  in src/kernel/core/cap/kind_pcm_stream.pdx §1 must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
pcm_pin_one 'pub let pcm_stream_clock_of_slot : (u64) -> u64'
pcm_pin_one 'pub let pcm_stream_ring_of_slot : (u64) -> u64'
pcm_pin_one 'pub let pcm_stream_position_of_slot : (u64) -> u64'
pcm_pin_one 'pub let pcm_stream_row_of_slot : (u64) -> u64'
pcm_pin_one 'pub let pcm_stream_position_advance : (u64, u64) -> u64'
pcm_pin_one 'pub let pcm_stream_find_conflicting_ring_clock : (u64, u64) -> u64'
echo "[pcm-stream-confine] LINEAR resolvers, position advancer and xclock invariant scanner arities pinned"

# The natural names for a mutant that would break LINEAR are searched
# for so a contributor gets told why they must not exist at the moment
# of adding them.
if grep -qE 'pcm_stream_(set_clock|clock_set|reparent|set_ring|ring_set|set_format|set_rate|set_channels)' "${PCM_STREAM_SRC}"; then
    echo "[pcm-stream-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the PCM stream kind." >&2
    echo "" >&2
    echo "  audio_clock_slot, ring_bo_key, sample_format, sample_rate and" >&2
    echo "  channels are set once, by the mint, and there is no primitive" >&2
    echo "  that changes them; see src/kernel/core/cap/kind_pcm_stream.pdx" >&2
    echo "  §1." >&2
    exit 1
fi
echo "[pcm-stream-confine] no LINEAR-breaking primitive"

# ---------------------------------------------------------------------------
# R33.M3-003 (#1149): THE AUDIO CLOCK PATH.
#
# Same shape. Two claims: (a) _audio_clock_table is the only place a
# clock's clock_source and nominal_hz live, plus its running current_hz
# and samples_produced. (b) Slot-arity-one resolvers and the report
# installer (arity three: cap + new_current_hz + samples_delta) pin so
# a caller cannot smuggle a clock source or a nominal rate through the
# path.
AUDIO_CLOCK_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_audio_clock.pdx"
if [[ ! -f "${AUDIO_CLOCK_SRC}" ]]; then
    echo "[audio-clock-confine] FAIL - ${AUDIO_CLOCK_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_audio_clock_table' 'core/cap/kind_audio_clock.o'
ec_confine_one '_audio_clock_stats' 'core/cap/kind_audio_clock.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_audio_clock.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[audio-clock-confine] audio clock rows and counter confined"

aclk_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${AUDIO_CLOCK_SRC}"; then
        echo "[audio-clock-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        exit 1
    fi
}
aclk_pin_one 'pub let audio_clock_source_of_slot : (u64) -> u64'
aclk_pin_one 'pub let audio_clock_nominal_of_slot : (u64) -> u64'
aclk_pin_one 'pub let audio_clock_current_of_slot : (u64) -> u64'
aclk_pin_one 'pub let audio_clock_samples_of_slot : (u64) -> u64'
aclk_pin_one 'pub let audio_clock_row_of_slot : (u64) -> u64'
aclk_pin_one 'pub let audio_clock_report_install : (u64, u64, u64) -> u64'
aclk_pin_one 'pub let audio_clock_source_valid : (u64) -> u64'
aclk_pin_one 'pub let audio_clock_hz_valid : (u64) -> u64'
echo "[audio-clock-confine] static-identity resolvers, report installer and validator arities pinned"

if grep -qE 'audio_clock_(set_source|source_set|set_nominal|nominal_set|set_key|key_set)' "${AUDIO_CLOCK_SRC}"; then
    echo "[audio-clock-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the audio clock kind." >&2
    exit 1
fi
echo "[audio-clock-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R33.M5-002 (#1158): THE AUDIO ROUTE PATH.
#
# Same shape as the pcm-stream path. Two claims:
#
# (a) _audio_route_table is the only place in the kernel where a route's
#     source_stream_slot, dest_pcm_slot, gain_q15 and mute live. A second
#     writer could restamp source_stream_slot with no capability involved
#     and no refusal recorded, redirecting one edge's samples silently.
#     _audio_route_stats is confined for the sibling reason.
#
# (b) Arity pins. The static identity (source, dest, key) comes FROM the
#     ROW, so the slot-arity-one resolvers take a capability and nothing
#     else. set_gain and set_mute pin at ARITY TWO: a third argument
#     would be a caller-supplied source or dest reaching a §1-set-once
#     field.
AUDIO_ROUTE_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_audio_route.pdx"
if [[ ! -f "${AUDIO_ROUTE_SRC}" ]]; then
    echo "[audio-route-confine] FAIL - ${AUDIO_ROUTE_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_audio_route_table' 'core/cap/kind_audio_route.o'
ec_confine_one '_audio_route_stats' 'core/cap/kind_audio_route.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_audio_route.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[audio-route-confine] audio route rows and counter confined"

art_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${AUDIO_ROUTE_SRC}"; then
        echo "[audio-route-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "  An AUDIO ROUTE'S source_stream_slot, dest_pcm_slot AND" >&2
        echo "  route_key COME FROM THE CAPABILITY'S OWN ROW AND NEVER" >&2
        echo "  FROM A CALLER. An extra parameter on any of these makes" >&2
        echo "  'redirect a route away from the streams my capability" >&2
        echo "  names' expressible. If a signature legitimately changed," >&2
        echo "  the LINEAR discipline in kind_audio_route.pdx §1 must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
art_pin_one 'pub let audio_route_source_of_slot : (u64) -> u64'
art_pin_one 'pub let audio_route_dest_of_slot : (u64) -> u64'
art_pin_one 'pub let audio_route_gain_of_slot : (u64) -> u64'
art_pin_one 'pub let audio_route_mute_of_slot : (u64) -> u64'
art_pin_one 'pub let audio_route_row_of_slot : (u64) -> u64'
art_pin_one 'pub let audio_route_set_gain : (u64, u64) -> u64'
art_pin_one 'pub let audio_route_set_mute : (u64, u64) -> u64'
echo "[audio-route-confine] LINEAR resolvers and set_gain/set_mute arities pinned"

if grep -qE 'audio_route_(set_source|source_set|reparent|set_dest|dest_set|set_key|key_set)' "${AUDIO_ROUTE_SRC}"; then
    echo "[audio-route-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the audio route kind." >&2
    echo "" >&2
    echo "  source_stream_slot, dest_pcm_slot and route_key are set once," >&2
    echo "  by the mint, and there is no primitive that changes them; see" >&2
    echo "  src/kernel/core/cap/kind_audio_route.pdx §1." >&2
    exit 1
fi
echo "[audio-route-confine] no LINEAR-breaking primitive"

# ---------------------------------------------------------------------------
# R34.M1-003 (#1169): THE USB DEVICE + USB HUB PATH.
#
# Two claims per kind:
#
# (a) _usb_device_table is the only place in the kernel where a USB
#     device's (address, speed) live; _usb_hub_table is the only place
#     where a hub's (port_count, tt_supported, tier) live. A second
#     writer could restamp any of those with no capability involved
#     and no refusal recorded.
#
# (b) Arity pins. The static identity comes FROM THE ROW, so the
#     slot-arity-one resolvers take a capability and nothing else.
USBD_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_usb_device.pdx"
if [[ ! -f "${USBD_SRC}" ]]; then
    echo "[usb-device-confine] FAIL - ${USBD_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_usb_device_table' 'core/cap/kind_usb_device.o'
ec_confine_one '_usb_device_stats' 'core/cap/kind_usb_device.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_usb_device.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[usb-device-confine] USB device rows and counters confined"

usbd_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${USBD_SRC}"; then
        echo "[usb-device-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        exit 1
    fi
}
usbd_pin_one 'pub let usb_device_key_of_slot : (u64) -> u64'
usbd_pin_one 'pub let usb_device_address_of_slot : (u64) -> u64'
usbd_pin_one 'pub let usb_device_speed_of_slot : (u64) -> u64'
usbd_pin_one 'pub let usb_device_row_of_slot : (u64) -> u64'
usbd_pin_one 'pub let usb_device_address_valid : (u64) -> u64'
usbd_pin_one 'pub let usb_device_speed_valid : (u64) -> u64'
echo "[usb-device-confine] static-identity resolvers and validator arities pinned"

if grep -qE 'usb_device_(set_address|address_set|set_speed|speed_set|set_key|key_set)' "${USBD_SRC}"; then
    echo "[usb-device-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the USB device kind." >&2
    exit 1
fi
echo "[usb-device-confine] no static-identity-mutating primitive"

USBH_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_usb_hub.pdx"
if [[ ! -f "${USBH_SRC}" ]]; then
    echo "[usb-hub-confine] FAIL - ${USBH_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_usb_hub_table' 'core/cap/kind_usb_hub.o'
ec_confine_one '_usb_hub_stats' 'core/cap/kind_usb_hub.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_usb_hub.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[usb-hub-confine] USB hub rows and counters confined"

usbh_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${USBH_SRC}"; then
        echo "[usb-hub-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        exit 1
    fi
}
usbh_pin_one 'pub let usb_hub_port_count_of_slot : (u64) -> u64'
usbh_pin_one 'pub let usb_hub_tt_of_slot : (u64) -> u64'
usbh_pin_one 'pub let usb_hub_tier_of_slot : (u64) -> u64'
usbh_pin_one 'pub let usb_hub_row_of_slot : (u64) -> u64'
usbh_pin_one 'pub let usb_hub_port_count_valid : (u64) -> u64'
usbh_pin_one 'pub let usb_hub_tier_valid : (u64) -> u64'
usbh_pin_one 'pub let usb_hub_tt_valid : (u64) -> u64'
echo "[usb-hub-confine] static-identity resolvers and validator arities pinned"

if grep -qE 'usb_hub_(set_ports|ports_set|set_tier|tier_set|set_tt|tt_set|set_key|key_set)' "${USBH_SRC}"; then
    echo "[usb-hub-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the USB hub kind." >&2
    exit 1
fi
echo "[usb-hub-confine] no static-identity-mutating primitive"

# Hub driver + FSM state confinement.
HUB_DRV_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/hub_driver.pdx"
HUB_FSM_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/hub_fsm.pdx"
if [[ ! -f "${HUB_DRV_SRC}" || ! -f "${HUB_FSM_SRC}" ]]; then
    echo "[hub-drivers-confine] FAIL - hub_driver.pdx or hub_fsm.pdx not found" >&2
    exit 1
fi
ec_confine_one '_hub_driver_bound' 'core/drivers/usb/hub_driver.o'
ec_confine_one '_hub_driver_stats' 'core/drivers/usb/hub_driver.o'
ec_confine_one '_hub_fsm_state'    'core/drivers/usb/hub_fsm.o'
ec_confine_one '_hub_fsm_stats'    'core/drivers/usb/hub_fsm.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/drivers/usb/hub_driver.pdx §2 and" >&2
    echo "  hub_fsm.pdx §1 for why these cells have one writer." >&2
    exit 1
fi
echo "[hub-drivers-confine] hub driver + FSM state confined"

# ---------------------------------------------------------------------------
# R34.M2 (#1172/#1175): KIND_USB_INTERFACE + KIND_USB_ENDPOINT confinement.
USBIF_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_usb_interface.pdx"
USBEP_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_usb_endpoint.pdx"
if [[ ! -f "${USBIF_SRC}" || ! -f "${USBEP_SRC}" ]]; then
    echo "[usb-if-ep-confine] FAIL - USB interface/endpoint kind source missing" >&2
    exit 1
fi
ec_confine_one '_usb_interface_table' 'core/cap/kind_usb_interface.o'
ec_confine_one '_usb_interface_stats' 'core/cap/kind_usb_interface.o'
ec_confine_one '_usb_endpoint_table'  'core/cap/kind_usb_endpoint.o'
ec_confine_one '_usb_endpoint_stats'  'core/cap/kind_usb_endpoint.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_usb_interface.pdx §1 and" >&2
    echo "  kind_usb_endpoint.pdx §2 for the row-table one-writer discipline." >&2
    exit 1
fi
echo "[usb-if-ep-confine] USB interface + endpoint rows and counters confined"

if grep -qE 'usb_interface_(set_ifnum|set_alt|set_class|set_key|key_set)' "${USBIF_SRC}"; then
    echo "[usb-if-confine] FAIL - static-identity-mutating primitive added" >&2
    exit 1
fi
if grep -qE 'usb_endpoint_(set_epnum|set_type|set_dir|set_maxpacket|set_key|key_set)' "${USBEP_SRC}"; then
    echo "[usb-ep-confine] FAIL - static-identity-mutating primitive added" >&2
    exit 1
fi
echo "[usb-if-ep-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R34.M2 (#1173/#1174): composite bind + interface parser state confinement.
CBIND_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/composite_bind.pdx"
IFPARSE_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/interface_parser.pdx"
if [[ ! -f "${CBIND_SRC}" || ! -f "${IFPARSE_SRC}" ]]; then
    echo "[usb-composite-confine] FAIL - composite_bind.pdx or interface_parser.pdx missing" >&2
    exit 1
fi
ec_confine_one '_composite_bind_table' 'core/drivers/usb/composite_bind.o'
ec_confine_one '_composite_bind_stats' 'core/drivers/usb/composite_bind.o'
ec_confine_one '_ifparser_stats'       'core/drivers/usb/interface_parser.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See composite_bind.pdx §2 and interface_parser.pdx §2 for the" >&2
    echo "  row/counter one-writer discipline." >&2
    exit 1
fi
echo "[usb-composite-confine] composite bind + interface parser state confined"

# ---------------------------------------------------------------------------
# R34.M3 (#1176/#1178/#1179): KIND_MSC_LUN + KIND_SCSI_DEVICE +
# KIND_USB_URB row-table confinement, mirroring the R34.M2 pair.
MSCLUN_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_msc_lun.pdx"
SCSID_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_scsi_device.pdx"
USBURB_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_usb_urb.pdx"
if [[ ! -f "${MSCLUN_SRC}" || ! -f "${SCSID_SRC}" || ! -f "${USBURB_SRC}" ]]; then
    echo "[usb-msc-confine] FAIL - one of the R34.M3 kind sources missing" >&2
    exit 1
fi
ec_confine_one '_msc_lun_table'     'core/cap/kind_msc_lun.o'
ec_confine_one '_msc_lun_stats'     'core/cap/kind_msc_lun.o'
ec_confine_one '_scsi_device_table' 'core/cap/kind_scsi_device.o'
ec_confine_one '_scsi_device_stats' 'core/cap/kind_scsi_device.o'
ec_confine_one '_usb_urb_table'     'core/cap/kind_usb_urb.o'
ec_confine_one '_usb_urb_stats'     'core/cap/kind_usb_urb.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_msc_lun.pdx §1, kind_scsi_device.pdx §1" >&2
    echo "  and kind_usb_urb.pdx §1 for the row-table one-writer discipline." >&2
    exit 1
fi
echo "[usb-msc-confine] MSC LUN + SCSI device + USB URB rows and counters confined"

# Static-identity-mutating primitive refusal, same shape as
# usb-if-ep-confine.
if grep -qE 'msc_lun_(set_num|num_set|set_key|key_set)' "${MSCLUN_SRC}"; then
    echo "[msc-lun-confine] FAIL - static-identity-mutating primitive added" >&2
    exit 1
fi
if grep -qE 'scsi_device_(set_type|set_blksz|set_blkcnt|set_key|key_set)' "${SCSID_SRC}"; then
    echo "[scsi-device-confine] FAIL - static-identity-mutating primitive added" >&2
    exit 1
fi
if grep -qE 'usb_urb_(set_dir|set_len|set_timeout|set_key|key_set)' "${USBURB_SRC}"; then
    echo "[usb-urb-confine] FAIL - static-identity-mutating primitive added" >&2
    exit 1
fi
echo "[usb-msc-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R34.M3 (#1176/#1177/#1178): BOT / UAS / SCSI-cmd stat-cell confinement.
# Each scaffold module holds one .bss stats array and NOTHING else that any
# other object may touch — the honesty pin lives in the same object.
BOT_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/msc/bot.pdx"
UAS_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/msc/uas.pdx"
SCMD_SRC="${REPO_ROOT}/src/kernel/core/drivers/scsi/scsi_cmd.pdx"
if [[ ! -f "${BOT_SRC}" || ! -f "${UAS_SRC}" || ! -f "${SCMD_SRC}" ]]; then
    echo "[usb-msc-drivers-confine] FAIL - BOT/UAS/scsi_cmd source missing" >&2
    exit 1
fi
ec_confine_one '_bot_stats'      'core/drivers/usb/msc/bot.o'
ec_confine_one '_uas_stats'      'core/drivers/usb/msc/uas.o'
ec_confine_one '_scsi_cmd_stats' 'core/drivers/scsi/scsi_cmd.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See bot.pdx, uas.pdx, scsi_cmd.pdx for the one-writer discipline." >&2
    exit 1
fi
echo "[usb-msc-drivers-confine] BOT/UAS/scsi_cmd stat cells confined"

# ---------------------------------------------------------------------------
# R34.M4 (#1181/#1182/#1183/#1184/#1185): USB-HID full-protocol
# scaffold state confinement.
#
# Each of the five modules holds one .bss stats array; composite_hid
# additionally owns a routing table. Every one of them is the ONE
# WRITER for its own state — a stray writer would let a second path
# bump a counter or add a route without passing this scaffold's gates,
# and no downstream stage could tell the two apart.
HCLS_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/hid/usb_hid_class.pdx"
KBDF_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/hid/kbd_full.pdx"
MUSF_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/hid/mouse_full.pdx"
GPAD_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/hid/gamepad.pdx"
CHID_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/hid/composite_hid.pdx"
if [[ ! -f "${HCLS_SRC}" || ! -f "${KBDF_SRC}" || ! -f "${MUSF_SRC}" \
        || ! -f "${GPAD_SRC}" || ! -f "${CHID_SRC}" ]]; then
    echo "[usb-hid-full-confine] FAIL - one of the R34.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_hid_class_stats'       'core/drivers/usb/hid/usb_hid_class.o'
ec_confine_one '_kbd_full_stats'        'core/drivers/usb/hid/kbd_full.o'
ec_confine_one '_mouse_full_stats'      'core/drivers/usb/hid/mouse_full.o'
ec_confine_one '_gamepad_stats'         'core/drivers/usb/hid/gamepad.o'
ec_confine_one '_composite_hid_table'   'core/drivers/usb/hid/composite_hid.o'
ec_confine_one '_composite_hid_stats'   'core/drivers/usb/hid/composite_hid.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See usb_hid_class.pdx §3, kbd_full.pdx, mouse_full.pdx, gamepad.pdx" >&2
    echo "  and composite_hid.pdx §1 for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[usb-hid-full-confine] USB-HID full-protocol scaffold state confined"

# ---------------------------------------------------------------------------
# R34.M5 (#1186/#1187/#1188/#1189): USB isochronous substrate
# state confinement.
#
# Four modules, each owns its own row table / state block / stats
# array. tools/build.sh confines relocations against each one to its
# owning object so a second writer cannot restamp a stream's
# bandwidth reservation, forge a frame index, admit a TRB behind the
# scheduler's back, or bump the frame counter without a packet.
ISOCHS_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_isoch_stream.pdx"
SOFTL_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/xhci/sof_timeline.pdx"
IRING_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/xhci/isoch_ring.pdx"
UVCSN_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/uvc/uvc_synth.pdx"
if [[ ! -f "${ISOCHS_SRC}" || ! -f "${SOFTL_SRC}" || ! -f "${IRING_SRC}" \
        || ! -f "${UVCSN_SRC}" ]]; then
    echo "[usb-isoch-confine] FAIL - one of the R34.M5 source files missing" >&2
    exit 1
fi
ec_confine_one '_isoch_stream_table' 'core/cap/kind_isoch_stream.o'
ec_confine_one '_isoch_stream_stats' 'core/cap/kind_isoch_stream.o'
ec_confine_one '_sof_state'          'core/drivers/usb/xhci/sof_timeline.o'
ec_confine_one '_sof_stats'          'core/drivers/usb/xhci/sof_timeline.o'
ec_confine_one '_isoch_ring_hdr'     'core/drivers/usb/xhci/isoch_ring.o'
ec_confine_one '_isoch_ring_slots'   'core/drivers/usb/xhci/isoch_ring.o'
ec_confine_one '_isoch_ring_stats'   'core/drivers/usb/xhci/isoch_ring.o'
ec_confine_one '_uvc_state'          'core/drivers/usb/uvc/uvc_synth.o'
ec_confine_one '_uvc_stats'          'core/drivers/usb/uvc/uvc_synth.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_isoch_stream.pdx §2, sof_timeline.pdx §2, isoch_ring.pdx §1" >&2
    echo "  and uvc_synth.pdx for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[usb-isoch-confine] USB isochronous substrate state confined"

# ---------------------------------------------------------------------------
# R34.M6 (#1191/#1192/#1193/#1194): USB fingerprint sensor substrate
# state confinement.
#
# Five modules, each owns its own row table / state block / stats
# array. tools/build.sh confines relocations against each one to its
# owning object so a second writer cannot restamp a sensor's vendor
# id or type, forge a template count behind the class driver's back,
# or bump a vendor-protocol stats cell without going through the
# scaffold's own gates.
FPSN_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_fp_sensor.pdx"
FPCL_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/fp/fp_class.pdx"
FPCC_SRC="${REPO_ROOT}/src/kernel/core/ipc/fp_capture_channel.pdx"
FPGX_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/fp/goodix.pdx"
FPSY_SRC="${REPO_ROOT}/src/kernel/core/drivers/usb/fp/synaptics.pdx"
if [[ ! -f "${FPSN_SRC}" || ! -f "${FPCL_SRC}" || ! -f "${FPCC_SRC}" \
        || ! -f "${FPGX_SRC}" || ! -f "${FPSY_SRC}" ]]; then
    echo "[usb-fp-confine] FAIL - one of the R34.M6 source files missing" >&2
    exit 1
fi
ec_confine_one '_fp_sensor_table'  'core/cap/kind_fp_sensor.o'
ec_confine_one '_fp_sensor_stats'  'core/cap/kind_fp_sensor.o'
ec_confine_one '_fp_class_state'   'core/drivers/usb/fp/fp_class.o'
ec_confine_one '_fp_class_stats'   'core/drivers/usb/fp/fp_class.o'
ec_confine_one '_goodix_stats'     'core/drivers/usb/fp/goodix.o'
ec_confine_one '_synaptics_stats'  'core/drivers/usb/fp/synaptics.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_fp_sensor.pdx §3, fp_class.pdx §3, goodix.pdx and" >&2
    echo "  synaptics.pdx for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[usb-fp-confine] USB fingerprint sensor substrate state confined"

# ---------------------------------------------------------------------------
# R35.M1 (#1195/#1196/#1197/#1198): PCIe hotplug substrate state
# confinement.
#
# Four modules, each owns its own row table / stats array.
# tools/build.sh confines relocations against each one to its owning
# object so a second writer cannot restamp a subscription's endpoint
# identity, forge an event count behind the ISR's back, or bump the
# retrain-success counter without a retrain sequence.
PHE_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_pcie_hotplug_event.pdx"
PHI_SRC="${REPO_ROOT}/src/kernel/core/drivers/pcie/hotplug_isr.pdx"
PHC_SRC="${REPO_ROOT}/src/kernel/core/ipc/pcie_hotplug_channel.pdx"
PLR_SRC="${REPO_ROOT}/src/kernel/core/drivers/pcie/link_retrain.pdx"
if [[ ! -f "${PHE_SRC}" || ! -f "${PHI_SRC}" || ! -f "${PHC_SRC}" \
        || ! -f "${PLR_SRC}" ]]; then
    echo "[pcie-hp-confine] FAIL - one of the R35.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_pcie_hp_evt_table'          'core/cap/kind_pcie_hotplug_event.o'
ec_confine_one '_pcie_hp_evt_stats'          'core/cap/kind_pcie_hotplug_event.o'
ec_confine_one '_pcie_hotplug_isr_stats'     'core/drivers/pcie/hotplug_isr.o'
ec_confine_one '_pcie_hotplug_channel_subs'  'core/ipc/pcie_hotplug_channel.o'
ec_confine_one '_pcie_hotplug_channel_stats' 'core/ipc/pcie_hotplug_channel.o'
ec_confine_one '_pcie_link_retrain_stats'    'core/drivers/pcie/link_retrain.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_pcie_hotplug_event.pdx §3, hotplug_isr.pdx §3," >&2
    echo "  pcie_hotplug_channel.pdx §2 and link_retrain.pdx §2 for" >&2
    echo "  the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[pcie-hp-confine] PCIe hotplug substrate state confined"

# ---------------------------------------------------------------------------
# R35.M2 (#1200/#1201/#1202/#1203/#1204): Thunderbolt 4 / USB4 substrate
# state confinement.
#
# Five modules, each owns its own row table / stats array.
# tools/build.sh confines relocations against each one to its owning
# object so a second writer cannot restamp a domain's route identity,
# forge a CM descriptor behind the ring's back, or claim a router
# discovery that no walker performed.
TBD_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_tb_domain.pdx"
TNP_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/nhi_probe.pdx"
TCM_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/cm_rings.pdx"
TRW_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/router_walk.pdx"
TTC_SRC="${REPO_ROOT}/src/kernel/core/ipc/tb_topology_channel.pdx"
if [[ ! -f "${TBD_SRC}" || ! -f "${TNP_SRC}" || ! -f "${TCM_SRC}" \
        || ! -f "${TRW_SRC}" || ! -f "${TTC_SRC}" ]]; then
    echo "[tb-confine] FAIL - one of the R35.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_tb_domain_table'      'core/cap/kind_tb_domain.o'
ec_confine_one '_tb_domain_stats'      'core/cap/kind_tb_domain.o'
ec_confine_one '_tb_nhi_probe_stats'   'core/drivers/tb/nhi_probe.o'
ec_confine_one '_tb_cm_tx_ring'        'core/drivers/tb/cm_rings.o'
ec_confine_one '_tb_cm_rx_ring'        'core/drivers/tb/cm_rings.o'
ec_confine_one '_tb_cm_tx_idx'         'core/drivers/tb/cm_rings.o'
ec_confine_one '_tb_cm_rx_idx'         'core/drivers/tb/cm_rings.o'
ec_confine_one '_tb_cm_rings_stats'    'core/drivers/tb/cm_rings.o'
ec_confine_one '_tb_router_table'      'core/drivers/tb/router_walk.o'
ec_confine_one '_tb_router_walk_stats' 'core/drivers/tb/router_walk.o'
ec_confine_one '_tb_topology_subs'     'core/ipc/tb_topology_channel.o'
ec_confine_one '_tb_topology_stats'    'core/ipc/tb_topology_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_tb_domain.pdx §3, nhi_probe.pdx §2, cm_rings.pdx §3," >&2
    echo "  router_walk.pdx §3 and tb_topology_channel.pdx §2 for" >&2
    echo "  the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[tb-confine] Thunderbolt 4 substrate state confined"

# ---------------------------------------------------------------------------
# R35.M3 (#1205/#1206/#1207/#1208/#1209): Thunderbolt 4 tunnel-establishment
# + KIND_TB_ROUTE + route-teardown state confinement.
#
# Five modules, each owns its own row table / stats array (and, for the
# DP / USB3 scaffolds, a fixed-capacity resource-slot table).
# tools/build.sh confines relocations against each one to its owning
# object so a second writer cannot restamp a route's identity, forge a
# DDI holder, or double-release a virtual xHCI port behind the
# sequencer's back.
TBR_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_tb_route.pdx"
TPT_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/pcie_tunnel.pdx"
TDP_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/dp_tunnel.pdx"
TU3_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/usb3_tunnel.pdx"
TTD_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/route_teardown.pdx"
if [[ ! -f "${TBR_SRC}" || ! -f "${TPT_SRC}" || ! -f "${TDP_SRC}" \
        || ! -f "${TU3_SRC}" || ! -f "${TTD_SRC}" ]]; then
    echo "[tb3-confine] FAIL - one of the R35.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_tb_route_table'         'core/cap/kind_tb_route.o'
ec_confine_one '_tb_route_stats'         'core/cap/kind_tb_route.o'
ec_confine_one '_pcie_tunnel_stats'      'core/drivers/tb/pcie_tunnel.o'
ec_confine_one '_dp_tunnel_stats'        'core/drivers/tb/dp_tunnel.o'
ec_confine_one '_dp_tunnel_ddi_tab'      'core/drivers/tb/dp_tunnel.o'
ec_confine_one '_usb3_tunnel_stats'      'core/drivers/tb/usb3_tunnel.o'
ec_confine_one '_usb3_tunnel_port_tab'   'core/drivers/tb/usb3_tunnel.o'
ec_confine_one '_route_teardown_stats'   'core/drivers/tb/route_teardown.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_tb_route.pdx §3, pcie_tunnel.pdx §2," >&2
    echo "  dp_tunnel.pdx §3, usb3_tunnel.pdx §3 and route_teardown.pdx §3" >&2
    echo "  for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[tb3-confine] Thunderbolt 4 tunnel substrate state confined"

# ---------------------------------------------------------------------------
# R35.M4 (#1210/#1211/#1212/#1213/#1214): DMA attestation + IOMMU consent
# for Thunderbolt security state confinement.
#
# Five modules. Each owns its own row table / stats array; tools/build.sh
# confines relocations against each to its owning object so a second writer
# cannot forge a consent decision, restamp an IOMMU domain's identity, or
# rewrite an audit ring behind the sequencer's back.
DAT_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_dma_attestation.pdx"
DCC_SRC="${REPO_ROOT}/src/kernel/core/ipc/dma_consent_channel.pdx"
CDG_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/consent_dialog.pdx"
IDM_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/iommu_domain.pdx"
CRV_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/consent_revoke.pdx"
if [[ ! -f "${DAT_SRC}" || ! -f "${DCC_SRC}" || ! -f "${CDG_SRC}" \
        || ! -f "${IDM_SRC}" || ! -f "${CRV_SRC}" ]]; then
    echo "[dma-consent-confine] FAIL - one of the R35.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_dma_attest_table'         'core/cap/kind_dma_attestation.o'
ec_confine_one '_dma_attest_stats'         'core/cap/kind_dma_attestation.o'
ec_confine_one '_dma_consent_reqs'         'core/ipc/dma_consent_channel.o'
ec_confine_one '_dma_consent_stats'        'core/ipc/dma_consent_channel.o'
ec_confine_one '_dma_consent_seq'          'core/ipc/dma_consent_channel.o'
ec_confine_one '_consent_dialog_audit'     'core/drivers/tb/consent_dialog.o'
ec_confine_one '_consent_dialog_head'      'core/drivers/tb/consent_dialog.o'
ec_confine_one '_consent_dialog_policy'    'core/drivers/tb/consent_dialog.o'
ec_confine_one '_consent_dialog_stats'     'core/drivers/tb/consent_dialog.o'
ec_confine_one '_iommu_domain_table'       'core/drivers/tb/iommu_domain.o'
ec_confine_one '_iommu_domain_stats'       'core/drivers/tb/iommu_domain.o'
ec_confine_one '_consent_revoke_stats'     'core/drivers/tb/consent_revoke.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_dma_attestation.pdx §4, dma_consent_channel.pdx §2," >&2
    echo "  consent_dialog.pdx §2, iommu_domain.pdx §3 and consent_revoke.pdx §4" >&2
    echo "  for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[dma-consent-confine] DMA attestation + IOMMU consent state confined"

# ---------------------------------------------------------------------------
# R35.M5 (#1215/#1216/#1217/#1218): TB4 security policy substrate state
# confinement.
#
# Four modules extend the R35.M1..M4 substrate with the security-policy
# layer: cascade validation harness, per-dock security level policy,
# trusted-device enrollment, external-DMA active indicator. Each owns
# its own row table / stats / counter; tools/build.sh confines
# relocations against each to its owning object so a second writer
# cannot forge a policy decision, restamp a trust-table row, or bump
# the DMA-active counter behind the publish seam's back.
CHR_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/cascade_harness.pdx"
SEC_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/security_policy.pdx"
TDV_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/trusted_device.pdx"
DAI_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/dma_active_indicator.pdx"
if [[ ! -f "${CHR_SRC}" || ! -f "${SEC_SRC}" || ! -f "${TDV_SRC}" \
        || ! -f "${DAI_SRC}" ]]; then
    echo "[tb-security-confine] FAIL - one of the R35.M5 source files missing" >&2
    exit 1
fi
ec_confine_one '_cascade_harness_stats'      'core/drivers/tb/cascade_harness.o'
ec_confine_one '_tb_security_policy_table'   'core/drivers/tb/security_policy.o'
ec_confine_one '_tb_security_policy_stats'   'core/drivers/tb/security_policy.o'
ec_confine_one '_tb_trusted_device_table'    'core/drivers/tb/trusted_device.o'
ec_confine_one '_tb_trusted_device_stats'    'core/drivers/tb/trusted_device.o'
ec_confine_one '_tb_dma_active_counter'      'core/drivers/tb/dma_active_indicator.o'
ec_confine_one '_tb_dma_active_stats'        'core/drivers/tb/dma_active_indicator.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See cascade_harness.pdx §3, security_policy.pdx §2," >&2
    echo "  trusted_device.pdx §3 and dma_active_indicator.pdx §3 for" >&2
    echo "  the table/counter one-writer discipline." >&2
    exit 1
fi
echo "[tb-security-confine] TB4 security policy substrate state confined"

# ---------------------------------------------------------------------------
# R35.M6 (#1219/#1220/#1221/#1222): software-CM substrate state confinement.
#
# Four modules: three-tier FSM (path/port/tunnel), host-driven command
# queue, event demultiplexer, firmware-CM interop handshake. Each owns
# its own tier tables / ring / stats / state cells; tools/build.sh
# confines relocations against each to its owning object so a second
# writer cannot forge an FSM transition, restamp a queued command's
# seq_tag, rewrite the demux's last-event cell, or forge the interop
# mode-latch.
SFM_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/sw_cm_fsm.pdx"
SCQ_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/sw_cm_cmdq.pdx"
SEM_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/sw_cm_evtmux.pdx"
SIO_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/sw_cm_fw_interop.pdx"
if [[ ! -f "${SFM_SRC}" || ! -f "${SCQ_SRC}" || ! -f "${SEM_SRC}" \
        || ! -f "${SIO_SRC}" ]]; then
    echo "[sw-cm-confine] FAIL - one of the R35.M6 source files missing" >&2
    exit 1
fi
ec_confine_one '_sw_cm_path_states'         'core/drivers/tb/sw_cm_fsm.o'
ec_confine_one '_sw_cm_port_states'         'core/drivers/tb/sw_cm_fsm.o'
ec_confine_one '_sw_cm_tunnel_states'       'core/drivers/tb/sw_cm_fsm.o'
ec_confine_one '_sw_cm_fsm_stats'           'core/drivers/tb/sw_cm_fsm.o'
ec_confine_one '_sw_cm_cmdq_ring'           'core/drivers/tb/sw_cm_cmdq.o'
ec_confine_one '_sw_cm_cmdq_idx'            'core/drivers/tb/sw_cm_cmdq.o'
ec_confine_one '_sw_cm_cmdq_seq'            'core/drivers/tb/sw_cm_cmdq.o'
ec_confine_one '_sw_cm_cmdq_stats'          'core/drivers/tb/sw_cm_cmdq.o'
ec_confine_one '_sw_cm_evtmux_stats'        'core/drivers/tb/sw_cm_evtmux.o'
ec_confine_one '_sw_cm_evtmux_last'         'core/drivers/tb/sw_cm_evtmux.o'
ec_confine_one '_sw_cm_fw_interop_state'    'core/drivers/tb/sw_cm_fw_interop.o'
ec_confine_one '_sw_cm_fw_interop_stats'    'core/drivers/tb/sw_cm_fw_interop.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See sw_cm_fsm.pdx §2, sw_cm_cmdq.pdx §1," >&2
    echo "  sw_cm_evtmux.pdx §1 and sw_cm_fw_interop.pdx §1 for" >&2
    echo "  the table/ring/state one-writer discipline." >&2
    exit 1
fi
echo "[sw-cm-confine] software-CM substrate state confined"

# ---------------------------------------------------------------------------
# R35.M7 (#1223/#1224/#1225): TB4 topology graph substrate state
# confinement.
#
# Three modules: topology graph vertex+edge ADT, route-string arithmetic
# (pure functions + stats), snapshot/diff on hot-plug. Each owns its own
# row tables / stats / snapshot buffers; tools/build.sh confines
# relocations against each to its owning object so a second writer
# cannot forge a router vertex, restamp an edge's endpoints, or rewrite
# the snapshot buffers behind td_snapshot's back.
TGR_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/topology_graph.pdx"
RAR_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/route_arith.pdx"
TDF_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/topology_diff.pdx"
if [[ ! -f "${TGR_SRC}" || ! -f "${RAR_SRC}" || ! -f "${TDF_SRC}" ]]; then
    echo "[tb-topo-confine] FAIL - one of the R35.M7 source files missing" >&2
    exit 1
fi
ec_confine_one '_tg_routers'         'core/drivers/tb/topology_graph.o'
ec_confine_one '_tg_edges'           'core/drivers/tb/topology_graph.o'
ec_confine_one '_tg_stats'           'core/drivers/tb/topology_graph.o'
ec_confine_one '_ra_stats'           'core/drivers/tb/route_arith.o'
ec_confine_one '_td_snap_routers'    'core/drivers/tb/topology_diff.o'
ec_confine_one '_td_snap_edges'      'core/drivers/tb/topology_diff.o'
ec_confine_one '_td_snap_flag'       'core/drivers/tb/topology_diff.o'
ec_confine_one '_td_diff_added_rt'   'core/drivers/tb/topology_diff.o'
ec_confine_one '_td_diff_removed_rt' 'core/drivers/tb/topology_diff.o'
ec_confine_one '_td_diff_added_ed'   'core/drivers/tb/topology_diff.o'
ec_confine_one '_td_diff_removed_ed' 'core/drivers/tb/topology_diff.o'
ec_confine_one '_tpd_diff_counts'    'core/drivers/tb/topology_diff.o'
ec_confine_one '_tpd_stats'          'core/drivers/tb/topology_diff.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See topology_graph.pdx §1, route_arith.pdx §1 and" >&2
    echo "  topology_diff.pdx §1 for the table/counter/snapshot" >&2
    echo "  one-writer discipline." >&2
    exit 1
fi
echo "[tb-topo-confine] TB4 topology graph substrate state confined"

# ---------------------------------------------------------------------------
# R35.M8 (#1226/#1227/#1228): TB4 tunnel provisioner state confinement.
#
# Three modules: per-link bandwidth arbitration (per-KIND_TB_DOMAIN
# reservation table + per-type + aggregate ceilings), multi-host
# contention scaffold (first-claim-wins over a downstream-adapter claim
# table, R43+ ships the live wiring), and tunnel priority policy
# (compile-time DP > PCIe > USB3 order with per-dock overrides). Each
# owns its own row tables / stats; tools/build.sh confines relocations
# against each to its owning object so a second writer cannot forge a
# reservation, restamp a host claim, or rewrite the priority table.
TAR_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/tunnel_arbiter.pdx"
MHC_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/multi_host_contend.pdx"
TPR_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/tunnel_priority.pdx"
if [[ ! -f "${TAR_SRC}" || ! -f "${MHC_SRC}" || ! -f "${TPR_SRC}" ]]; then
    echo "[tb-provisioner-confine] FAIL - one of the R35.M8 source files missing" >&2
    exit 1
fi
ec_confine_one '_tarb_domains'     'core/drivers/tb/tunnel_arbiter.o'
ec_confine_one '_tarb_stats'       'core/drivers/tb/tunnel_arbiter.o'
ec_confine_one '_mhc_claims'       'core/drivers/tb/multi_host_contend.o'
ec_confine_one '_mhc_stats'        'core/drivers/tb/multi_host_contend.o'
ec_confine_one '_tpri_overrides'   'core/drivers/tb/tunnel_priority.o'
ec_confine_one '_tpri_stats'       'core/drivers/tb/tunnel_priority.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See tunnel_arbiter.pdx §1, multi_host_contend.pdx §1 and" >&2
    echo "  tunnel_priority.pdx §1 for the table/counter one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[tb-provisioner-confine] TB4 tunnel provisioner state confined"

# ---------------------------------------------------------------------------
# R35.M9 (#1229/#1230/#1231): TB4 DP-tunnel bridge to R36 confinement.
#
# Three modules: DP-tunnel virtual DDI shim (per-tunnel row table
# associating tunnel_slot / ddi_index / mst_stream_id, plus placeholder
# ddi_appeared / ddi_removed events R36's KIND_DISPLAY_OUTPUT will
# consume), DP AUX pass-through (16-slot in-flight ring with
# ACK/NACK/DEFER response arbitration per DP 2.1 §2.4 / USB4 §10.6),
# and DP-adapter hot-plug bridge (filters tb_topology_channel events,
# drops non-DP, emits placeholder _dp_output_event records into a
# 16-slot recent-emissions ring). Each owns its own row / ring / stats;
# tools/build.sh confines relocations against each to its owning
# object so a second writer cannot forge a DDI mapping, restamp an AUX
# slot, or fabricate a display hot-plug event.
DPDDI_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/dp_ddi_shim.pdx"
DPAUX_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/dp_aux_passthru.pdx"
DPHP_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/dp_hotplug_bridge.pdx"
if [[ ! -f "${DPDDI_SRC}" || ! -f "${DPAUX_SRC}" || ! -f "${DPHP_SRC}" ]]; then
    echo "[tb-dp-bridge-confine] FAIL - one of the R35.M9 source files missing" >&2
    exit 1
fi
ec_confine_one '_dpddi_rows'  'core/drivers/tb/dp_ddi_shim.o'
ec_confine_one '_dpddi_stats' 'core/drivers/tb/dp_ddi_shim.o'
ec_confine_one '_dpaux_pt_ring'  'core/drivers/tb/dp_aux_passthru.o'
ec_confine_one '_dpaux_pt_stats' 'core/drivers/tb/dp_aux_passthru.o'
ec_confine_one '_dphp_events' 'core/drivers/tb/dp_hotplug_bridge.o'
ec_confine_one '_dphp_stats'  'core/drivers/tb/dp_hotplug_bridge.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See dp_ddi_shim.pdx §1, dp_aux_passthru.pdx §1 and" >&2
    echo "  dp_hotplug_bridge.pdx §1 for the table/ring/counter" >&2
    echo "  one-writer discipline." >&2
    exit 1
fi
echo "[tb-dp-bridge-confine] TB4 DP-tunnel bridge state confined"

# ---------------------------------------------------------------------------
# R35.M10 (#1232/#1233/#1234): closing r35-thunderbolt with USB3 virtual
# xHCI extension, USB-PD contract negotiation, and DP alt-mode SVDMs.
#
# Three modules: USB3-tunnel xHCI extension (per-tunnel (base, count)
# port-range table with placeholder port_added / port_removed events
# R34's USB supervisor will fan out), USB-PD contract negotiator
# (per-port PD 3.1 §6.4 state machine SRC_CAP -> REQUEST -> ACCEPT ->
# PS_RDY with a 100 W safety cap), and DP alt-mode SVDM FSM (per-port
# Enter/Configure/Exit against SVID 0xFF01 with pin assignments A..F).
# Each owns its own row / port table + stats; tools/build.sh confines
# relocations against each to its owning object so a second writer
# cannot forge a port mapping, restamp a PD state, or fabricate a DP
# alt-mode session.
U3XE_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/usb3_xhci_ext.pdx"
PDC_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/usbpd_contract.pdx"
DPAM_SRC="${REPO_ROOT}/src/kernel/core/drivers/tb/dp_altmode.pdx"
if [[ ! -f "${U3XE_SRC}" || ! -f "${PDC_SRC}" || ! -f "${DPAM_SRC}" ]]; then
    echo "[tb-m10-confine] FAIL - one of the R35.M10 source files missing" >&2
    exit 1
fi
ec_confine_one '_u3xe_ports'  'core/drivers/tb/usb3_xhci_ext.o'
ec_confine_one '_u3xe_stats'  'core/drivers/tb/usb3_xhci_ext.o'
ec_confine_one '_pdc_states'  'core/drivers/tb/usbpd_contract.o'
ec_confine_one '_pdc_stats'   'core/drivers/tb/usbpd_contract.o'
ec_confine_one '_dpam_ports'  'core/drivers/tb/dp_altmode.o'
ec_confine_one '_dpam_stats'  'core/drivers/tb/dp_altmode.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See usb3_xhci_ext.pdx §1, usbpd_contract.pdx §1 and" >&2
    echo "  dp_altmode.pdx §1 for the table/counter one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[tb-m10-confine] R35.M10 (USB3 xHCI ext + USB-PD + DP alt-mode) confined"

# ---------------------------------------------------------------------------
# R36.M1 (#1235/#1236/#1237/#1238): Iris Xe display substrate state
# confinement.
#
# Four modules extend the prior lattice with the display engine:
# KIND_DISPLAY_ENGINE (row table + stats), iris_xe_probe scaffold
# (stats), pwr_wells driver (well-state + cdclk + stats), and
# dpclk_config PLL driver (pll-state + stats). Each owns its own
# state; tools/build.sh confines relocations against each to its
# owning object so a second writer cannot forge a power-well
# transition, restamp the CDCLK setpoint, or claim a PLL lock the
# hardware never asserted.
DPE_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_display_engine.pdx"
IXP_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/iris_xe_probe.pdx"
PWR_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/pwr_wells.pdx"
DPCLK_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/dpclk_config.pdx"
if [[ ! -f "${DPE_SRC}" || ! -f "${IXP_SRC}" || ! -f "${PWR_SRC}" \
        || ! -f "${DPCLK_SRC}" ]]; then
    echo "[dpy-confine] FAIL - one of the R36.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_display_engine_table' 'core/cap/kind_display_engine.o'
ec_confine_one '_display_engine_stats' 'core/cap/kind_display_engine.o'
ec_confine_one '_ixp_probe_stats'      'core/drivers/dpy/iris_xe_probe.o'
ec_confine_one '_pwr_well_state'       'core/drivers/dpy/pwr_wells.o'
ec_confine_one '_pwr_cdclk_khz'        'core/drivers/dpy/pwr_wells.o'
ec_confine_one '_pwr_wells_stats'      'core/drivers/dpy/pwr_wells.o'
ec_confine_one '_dpclk_pll_state'      'core/drivers/dpy/dpclk_config.o'
ec_confine_one '_dpclk_pll_stats'      'core/drivers/dpy/dpclk_config.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_display_engine.pdx §3, iris_xe_probe.pdx §2," >&2
    echo "  pwr_wells.pdx §3 and dpclk_config.pdx §3 for the row/" >&2
    echo "  counter one-writer discipline." >&2
    exit 1
fi
echo "[dpy-confine] R36.M1 (Iris Xe display substrate) confined"

# ---------------------------------------------------------------------------
# R36.M2 (#1239/#1240/#1241/#1242/#1243): display output substrate
# (KIND_DISPLAY_OUTPUT + topology + EDID + topo channel + HPD).
#
# Four modules extend the R36.M1 lattice with the output side. Each
# owns its own state; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot forge an output
# row, restamp a DDI wire type, invent an EDID hash, or fabricate an
# HPD debounce transition. display_topology_channel is pure packer
# discipline — no state to confine — but its symbol signatures are
# pinned in situ.
DPO_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_display_output.pdx"
DTOPO_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/topology.pdx"
EDID_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/edid.pdx"
DTC_SRC="${REPO_ROOT}/src/kernel/core/ipc/display_topology_channel.pdx"
HPD_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/hpd_isr.pdx"
if [[ ! -f "${DPO_SRC}" || ! -f "${DTOPO_SRC}" || ! -f "${EDID_SRC}" \
        || ! -f "${DTC_SRC}" || ! -f "${HPD_SRC}" ]]; then
    echo "[dpy-m2-confine] FAIL - one of the R36.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_display_output_table' 'core/cap/kind_display_output.o'
ec_confine_one '_display_output_stats' 'core/cap/kind_display_output.o'
ec_confine_one '_dtopo_paths'          'core/drivers/dpy/topology.o'
ec_confine_one '_dtopo_stats'          'core/drivers/dpy/topology.o'
ec_confine_one '_edid_state'           'core/drivers/dpy/edid.o'
ec_confine_one '_edid_stats'           'core/drivers/dpy/edid.o'
ec_confine_one '_hpd_state'            'core/drivers/dpy/hpd_isr.o'
ec_confine_one '_hpd_stats'            'core/drivers/dpy/hpd_isr.o'
ec_confine_one '_hpd_bound'            'core/drivers/dpy/hpd_isr.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_display_output.pdx §3, topology.pdx §4, edid.pdx" >&2
    echo "  §5 and hpd_isr.pdx §2 for the row/counter one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[dpy-m2-confine] R36.M2 (display output substrate) confined"

# ---------------------------------------------------------------------------
# R36.M3 (#1244/#1245/#1246/#1247/#1248): display modeset substrate
# (KIND_MODESET_TXN + KIND_DISPLAY_MODE + modeset_channel FSM +
# atomic_commit + mode_enum).
#
# Five modules extend the R36.M2 lattice with atomic modeset. Each
# owns its own state; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot forge a
# modeset-transaction row, restamp a mode timing, or fabricate an
# atomic-commit staging bank. modeset_channel is pure FSM discipline
# (a rodata transition table + packers) — no writable state to
# confine — but its transition-table symbol is pinned in situ.
MTX_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_modeset_txn.pdx"
DPM_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_display_mode.pdx"
MCH_SRC="${REPO_ROOT}/src/kernel/core/ipc/modeset_channel.pdx"
ACOM_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/atomic_commit.pdx"
MENUM_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/mode_enum.pdx"
if [[ ! -f "${MTX_SRC}" || ! -f "${DPM_SRC}" || ! -f "${MCH_SRC}" \
        || ! -f "${ACOM_SRC}" || ! -f "${MENUM_SRC}" ]]; then
    echo "[dpy-m3-confine] FAIL - one of the R36.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_modeset_txn_table'    'core/cap/kind_modeset_txn.o'
ec_confine_one '_modeset_txn_stats'    'core/cap/kind_modeset_txn.o'
ec_confine_one '_display_mode_table'   'core/cap/kind_display_mode.o'
ec_confine_one '_display_mode_stats'   'core/cap/kind_display_mode.o'
ec_confine_one '_atomic_commit_state'  'core/drivers/dpy/atomic_commit.o'
ec_confine_one '_atomic_commit_stats'  'core/drivers/dpy/atomic_commit.o'
ec_confine_one '_menum_stats'          'core/drivers/dpy/mode_enum.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_modeset_txn.pdx §3, kind_display_mode.pdx §3," >&2
    echo "  atomic_commit.pdx §3 and mode_enum.pdx §2 for the" >&2
    echo "  row/counter one-writer discipline." >&2
    exit 1
fi
echo "[dpy-m3-confine] R36.M3 (display modeset substrate) confined"

# ---------------------------------------------------------------------------
# R36.M4 (#1249/#1250/#1251/#1252): display plane substrate
# (KIND_DISPLAY_PLANE + plane_primary + plane_overlay + plane_cursor).
#
# Four modules extend the R36.M3 lattice with per-role plane authority.
# Each owns its own state; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot forge a plane row
# or restamp a per-pipe binding.
DPP_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_display_plane.pdx"
PLPRI_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/plane_primary.pdx"
PLOVR_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/plane_overlay.pdx"
PLCUR_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/plane_cursor.pdx"
if [[ ! -f "${DPP_SRC}" || ! -f "${PLPRI_SRC}" \
        || ! -f "${PLOVR_SRC}" || ! -f "${PLCUR_SRC}" ]]; then
    echo "[dpy-m4-confine] FAIL - one of the R36.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_display_plane_table' 'core/cap/kind_display_plane.o'
ec_confine_one '_display_plane_stats' 'core/cap/kind_display_plane.o'
ec_confine_one '_plane_primary_state' 'core/drivers/dpy/plane_primary.o'
ec_confine_one '_plane_primary_stats' 'core/drivers/dpy/plane_primary.o'
ec_confine_one '_plane_overlay_state' 'core/drivers/dpy/plane_overlay.o'
ec_confine_one '_plane_overlay_stats' 'core/drivers/dpy/plane_overlay.o'
ec_confine_one '_plane_cursor_state'  'core/drivers/dpy/plane_cursor.o'
ec_confine_one '_plane_cursor_stats'  'core/drivers/dpy/plane_cursor.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_display_plane.pdx §3, plane_primary.pdx §2," >&2
    echo "  plane_overlay.pdx §3 and plane_cursor.pdx §3 for the" >&2
    echo "  row/counter one-writer discipline." >&2
    exit 1
fi
echo "[dpy-m4-confine] R36.M4 (display plane substrate) confined"

# ---------------------------------------------------------------------------
# R37.M1 (#1253/#1255/#1256): Iris Xe GPU execution substrate — MMIO
# accessors (gpu_mmio), reset primitives (gpu_reset), and register
# audit + safety-region enforcement (gpu_reg_audit).
#
# Three modules open R37 (post-r36-display-substrate). Each owns its
# own state; tools/build.sh confines relocations against each to its
# owning object so a second writer cannot forge a BAR-window
# recording, restamp an engine reset count, or slip an audit-ring
# entry past the guarded-write funnel.
GMMIO_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/gpu_mmio.pdx"
GRST_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/gpu_reset.pdx"
GRAUD_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/gpu_reg_audit.pdx"
if [[ ! -f "${GMMIO_SRC}" || ! -f "${GRST_SRC}" \
        || ! -f "${GRAUD_SRC}" ]]; then
    echo "[gpu-m1-confine] FAIL - one of the R37.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_gmmio_bar_base'    'core/drivers/gpu/gpu_mmio.o'
ec_confine_one '_gmmio_bar_len'     'core/drivers/gpu/gpu_mmio.o'
ec_confine_one '_gmmio_bound'       'core/drivers/gpu/gpu_mmio.o'
ec_confine_one '_gmmio_synth_ram'   'core/drivers/gpu/gpu_mmio.o'
ec_confine_one '_gmmio_stats'       'core/drivers/gpu/gpu_mmio.o'
ec_confine_one '_grst_engine_state' 'core/drivers/gpu/gpu_reset.o'
ec_confine_one '_grst_last_full'    'core/drivers/gpu/gpu_reset.o'
ec_confine_one '_grst_stats'        'core/drivers/gpu/gpu_reset.o'
ec_confine_one '_graud_ring'        'core/drivers/gpu/gpu_reg_audit.o'
ec_confine_one '_graud_head'        'core/drivers/gpu/gpu_reg_audit.o'
ec_confine_one '_graud_seq'         'core/drivers/gpu/gpu_reg_audit.o'
ec_confine_one '_graud_stats'       'core/drivers/gpu/gpu_reg_audit.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See gpu_mmio.pdx §3, gpu_reset.pdx §3 and" >&2
    echo "  gpu_reg_audit.pdx §4 for the row/counter one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[gpu-m1-confine] R37.M1 (Iris Xe GPU execution substrate) confined"

# ---------------------------------------------------------------------------
# R37.M2 (#1257/#1258/#1259): Iris Xe GuC firmware substrate —
# dual-signature admission (guc_verify), WOPCM upload FSM (guc_load),
# and post-load handshake + version + feature negotiation (guc_hs).
#
# Three modules open R37.M2 (post-r37-M1). Each owns its own state;
# tools/build.sh confines relocations against each to its owning
# object so a second writer cannot forge a "verified" flag, restamp a
# WOPCM window, or fake a GuC handshake row.
GUCV_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/guc_verify.pdx"
GUCL_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/guc_load.pdx"
GUCHS_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/guc_hs.pdx"
if [[ ! -f "${GUCV_SRC}" || ! -f "${GUCL_SRC}" \
        || ! -f "${GUCHS_SRC}" ]]; then
    echo "[guc-m2-confine] FAIL - one of the R37.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_gucv_blob_ptr'          'core/drivers/gpu/guc_verify.o'
ec_confine_one '_gucv_blob_len'          'core/drivers/gpu/guc_verify.o'
ec_confine_one '_gucv_verified'          'core/drivers/gpu/guc_verify.o'
ec_confine_one '_gucv_stats'             'core/drivers/gpu/guc_verify.o'
ec_confine_one '_gucl_wopcm_base'        'core/drivers/gpu/guc_load.o'
ec_confine_one '_gucl_wopcm_size'        'core/drivers/gpu/guc_load.o'
ec_confine_one '_gucl_loaded'            'core/drivers/gpu/guc_load.o'
ec_confine_one '_gucl_stats'             'core/drivers/gpu/guc_load.o'
ec_confine_one '_guchs_ready'            'core/drivers/gpu/guc_hs.o'
ec_confine_one '_guchs_version'          'core/drivers/gpu/guc_hs.o'
ec_confine_one '_guchs_features_enabled' 'core/drivers/gpu/guc_hs.o'
ec_confine_one '_guchs_stats'            'core/drivers/gpu/guc_hs.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See guc_verify.pdx §2, guc_load.pdx §3 and" >&2
    echo "  guc_hs.pdx §3 for the row/counter one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[guc-m2-confine] R37.M2 (Iris Xe GuC firmware substrate) confined"

# ---------------------------------------------------------------------------
# R37.M3 (#1262/#1263/#1264/#1265/#1266): GPU BO substrate --
# KIND_GPU_BO (kind_gpu_bo), slab allocator (bo_alloc), tiling encoders
# (tiling), cache-policy classifier (cache_policy), and RPC schema
# (gpu_bo_alloc_channel).
#
# Five modules open R37.M3 (post-r37-M2). Each owns its own state;
# tools/build.sh confines relocations against each to its owning
# object so a second writer cannot forge a BO row, restamp a slab
# claim, tally a tiling counter, restamp a cache-policy counter, or
# ship a synthetic channel event.
KGB_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_gpu_bo.pdx"
BOA_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/bo_alloc.pdx"
TIL_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/tiling.pdx"
CPOL_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/cache_policy.pdx"
BOC_SRC="${REPO_ROOT}/src/kernel/core/ipc/gpu_bo_alloc_channel.pdx"
if [[ ! -f "${KGB_SRC}" || ! -f "${BOA_SRC}" \
        || ! -f "${TIL_SRC}" || ! -f "${CPOL_SRC}" \
        || ! -f "${BOC_SRC}" ]]; then
    echo "[gpu-m3-confine] FAIL - one of the R37.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_gpu_bo_table'         'core/cap/kind_gpu_bo.o'
ec_confine_one '_gpu_bo_stats'         'core/cap/kind_gpu_bo.o'
ec_confine_one '_bo_alloc_pool'        'core/drivers/gpu/bo_alloc.o'
ec_confine_one '_bo_alloc_stats'       'core/drivers/gpu/bo_alloc.o'
ec_confine_one '_tiling_stats'         'core/drivers/gpu/tiling.o'
ec_confine_one '_cache_policy_stats'   'core/drivers/gpu/cache_policy.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_gpu_bo.pdx §2, bo_alloc.pdx §2, tiling.pdx §3," >&2
    echo "  cache_policy.pdx §3 and gpu_bo_alloc_channel.pdx §3 for the" >&2
    echo "  row/counter one-writer discipline." >&2
    exit 1
fi
echo "[gpu-m3-confine] R37.M3 (GPU BO substrate) confined"

# ---------------------------------------------------------------------------
# R37.M4 (#1267/#1268/#1269/#1270/#1271): GPU virtual-memory substrate --
# KIND_GPU_VM (kind_gpu_vm), PPGTT walker (ppgtt_walker), PPGTT bind
# (ppgtt_bind), PPGTT prot composer (ppgtt_prot), GTT scan-out mappings
# (gtt_scanout).
#
# Five modules open R37.M4 (post-r37-M3).  Each owns its own state;
# tools/build.sh confines relocations against each to its owning object
# so a second writer cannot forge a GPU VM row, restamp a walker
# session, drift a bind counter, restamp a prot counter, or ship a
# stray GTT scan-out mapping.
KGVM_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_gpu_vm.pdx"
PPTW_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/ppgtt_walker.pdx"
PPGB_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/ppgtt_bind.pdx"
PPP_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/ppgtt_prot.pdx"
GTTS_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/gtt_scanout.pdx"
if [[ ! -f "${KGVM_SRC}" || ! -f "${PPTW_SRC}" \
        || ! -f "${PPGB_SRC}" || ! -f "${PPP_SRC}" \
        || ! -f "${GTTS_SRC}" ]]; then
    echo "[gpu-m4-confine] FAIL - one of the R37.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_gpu_vm_table'      'core/cap/kind_gpu_vm.o'
ec_confine_one '_gpu_vm_stats'      'core/cap/kind_gpu_vm.o'
ec_confine_one '_pptw_sessions'     'core/drivers/gpu/ppgtt_walker.o'
ec_confine_one '_pptw_stats'        'core/drivers/gpu/ppgtt_walker.o'
ec_confine_one '_ppgb_table'        'core/drivers/gpu/ppgtt_bind.o'
ec_confine_one '_ppgb_stats'        'core/drivers/gpu/ppgtt_bind.o'
ec_confine_one '_ppp_stats'         'core/drivers/gpu/ppgtt_prot.o'
ec_confine_one '_gtts_table'        'core/drivers/gpu/gtt_scanout.o'
ec_confine_one '_gtts_stats'        'core/drivers/gpu/gtt_scanout.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_gpu_vm.pdx §2, ppgtt_walker.pdx §4, ppgtt_bind.pdx §3," >&2
    echo "  ppgtt_prot.pdx §3 and gtt_scanout.pdx §4 for the" >&2
    echo "  row/counter one-writer discipline." >&2
    exit 1
fi
echo "[gpu-m4-confine] R37.M4 (GPU virtual-memory substrate) confined"

# ---------------------------------------------------------------------------
# R37.M5 (#1272/#1273/#1274/#1275): GPU submission-context substrate --
# KIND_GPU_CONTEXT (kind_gpu_context), Logical Ring Context (lrc),
# execlists submission (execlists), context priority + preemption
# (ctx_priority).
#
# Four modules open R37.M5 (post-r37-M4).  Each owns its own state;
# tools/build.sh confines relocations against each to its owning object
# so a second writer cannot forge a GPU CONTEXT row, restamp an LRC
# reservation, drift an ELSP inflight count, or restamp a priority
# counter.
KGCTX_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_gpu_context.pdx"
LRC_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/lrc.pdx"
EXL_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/execlists.pdx"
CTXPRI_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/ctx_priority.pdx"
if [[ ! -f "${KGCTX_SRC}" || ! -f "${LRC_SRC}" \
        || ! -f "${EXL_SRC}" || ! -f "${CTXPRI_SRC}" ]]; then
    echo "[gpu-m5-confine] FAIL - one of the R37.M5 source files missing" >&2
    exit 1
fi
ec_confine_one '_gpu_ctx_table'    'core/cap/kind_gpu_context.o'
ec_confine_one '_gpu_ctx_stats'    'core/cap/kind_gpu_context.o'
ec_confine_one '_lrc_table'        'core/drivers/gpu/lrc.o'
ec_confine_one '_lrc_stats'        'core/drivers/gpu/lrc.o'
ec_confine_one '_exl_engines'      'core/drivers/gpu/execlists.o'
ec_confine_one '_exl_stats'        'core/drivers/gpu/execlists.o'
ec_confine_one '_ctxpri_stats'     'core/drivers/gpu/ctx_priority.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_gpu_context.pdx §2, lrc.pdx §3, execlists.pdx §3," >&2
    echo "  ctx_priority.pdx §3 for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[gpu-m5-confine] R37.M5 (GPU submission-context substrate) confined"

# ---------------------------------------------------------------------------
# R37.M6 (#1276/#1277/#1279): GPU submission substrate --
# KIND_GPU_SUBMIT (kind_gpu_submit), GuC-mediated submission
# (guc_submit), batch buffer builder (batch_builder).
#
# Three modules open R37.M6 (post-R37.M5).  Each owns its own state;
# tools/build.sh confines relocations against each to its owning object
# so a second writer cannot forge a GPU SUBMIT row, drift a queue's
# single-issuer inflight flag, or restamp the batch builder cursor.
KGSUB_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_gpu_submit.pdx"
GSUB_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/guc_submit.pdx"
BAT_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/batch_builder.pdx"
if [[ ! -f "${KGSUB_SRC}" || ! -f "${GSUB_SRC}" || ! -f "${BAT_SRC}" ]]; then
    echo "[gpu-m6-confine] FAIL - one of the R37.M6 source files missing" >&2
    exit 1
fi
ec_confine_one '_gpu_submit_table' 'core/cap/kind_gpu_submit.o'
ec_confine_one '_gpu_submit_stats' 'core/cap/kind_gpu_submit.o'
ec_confine_one '_gsub_queues'      'core/drivers/gpu/guc_submit.o'
ec_confine_one '_gsub_seq'         'core/drivers/gpu/guc_submit.o'
ec_confine_one '_gsub_stats'       'core/drivers/gpu/guc_submit.o'
ec_confine_one '_bat_builder'      'core/drivers/gpu/batch_builder.o'
ec_confine_one '_bat_stats'        'core/drivers/gpu/batch_builder.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_gpu_submit.pdx §2, guc_submit.pdx §3," >&2
    echo "  batch_builder.pdx §3 for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[gpu-m6-confine] R37.M6 (GPU submission substrate) confined"

# ---------------------------------------------------------------------------
# R37.M7 (#1283): GPU sync-primitive substrate --
# GT fence + interrupt path (gt_fence).
#
# One module opens R37.M7 (post-R37.M6).  It owns its own state
# (per-engine last_signaled_seqno + pending waiter record); tools/build.sh
# confines relocations against each so a second writer cannot forge a
# fence advance, drift a waiter slot, or release a blocked task against
# a seqno the CS has not actually reached.
GTF_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/gt_fence.pdx"
if [[ ! -f "${GTF_SRC}" ]]; then
    echo "[gpu-m7-confine] FAIL - ${GTF_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_gtf_engines'      'core/drivers/gpu/gt_fence.o'
ec_confine_one '_gtf_stats'        'core/drivers/gpu/gt_fence.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See gt_fence.pdx §3 for the per-engine record + counter" >&2
    echo "  one-writer discipline." >&2
    exit 1
fi
echo "[gpu-m7-confine] R37.M7 (GPU sync-primitive substrate) confined"

# ---------------------------------------------------------------------------
# R37.M8 (#1285/#1286/#1287/#1288): GPU video-decode enablement --
# HuC firmware loader (huc_load), VCS video engine substrate
# (vcs_engine), HEVC frame plumbing scaffold (hevc_frame), and the
# 100k no-op batch stress rig (gpu_stress).
#
# Four modules close R37.M8 (post-R37.M7).  Each owns its own state;
# tools/build.sh confines relocations against each to its owning
# object so a second writer cannot forge a HuC acceptance flag,
# restamp the VCS wake / inflight record, dirty the HEVC frame ring,
# or drift the stress rig's snapshot bookkeeping.
HUCL_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/huc_load.pdx"
VCS_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/vcs_engine.pdx"
HEVC_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/hevc_frame.pdx"
STRESS_SRC="${REPO_ROOT}/src/kernel/core/drivers/gpu/gpu_stress.pdx"
if [[ ! -f "${HUCL_SRC}" || ! -f "${VCS_SRC}" \
        || ! -f "${HEVC_SRC}" || ! -f "${STRESS_SRC}" ]]; then
    echo "[gpu-m8-confine] FAIL - one of the R37.M8 source files missing" >&2
    exit 1
fi
ec_confine_one '_hucl_blob_ptr'      'core/drivers/gpu/huc_load.o'
ec_confine_one '_hucl_blob_len'      'core/drivers/gpu/huc_load.o'
ec_confine_one '_hucl_wopcm_base'    'core/drivers/gpu/huc_load.o'
ec_confine_one '_hucl_wopcm_size'    'core/drivers/gpu/huc_load.o'
ec_confine_one '_hucl_accepted'      'core/drivers/gpu/huc_load.o'
ec_confine_one '_hucl_stats'         'core/drivers/gpu/huc_load.o'
ec_confine_one '_vcs_state'          'core/drivers/gpu/vcs_engine.o'
ec_confine_one '_vcs_stats'          'core/drivers/gpu/vcs_engine.o'
ec_confine_one '_hevc_ring'          'core/drivers/gpu/hevc_frame.o'
ec_confine_one '_hevc_head'          'core/drivers/gpu/hevc_frame.o'
ec_confine_one '_hevc_admitted'      'core/drivers/gpu/hevc_frame.o'
ec_confine_one '_hevc_stats'         'core/drivers/gpu/hevc_frame.o'
ec_confine_one '_stress_backing'     'core/drivers/gpu/gpu_stress.o'
ec_confine_one '_stress_last'        'core/drivers/gpu/gpu_stress.o'
ec_confine_one '_stress_stats'       'core/drivers/gpu/gpu_stress.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See huc_load.pdx §4, vcs_engine.pdx §3, hevc_frame.pdx §3," >&2
    echo "  gpu_stress.pdx §2 for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[gpu-m8-confine] R37.M8 (GPU video-decode enablement) confined"

# ---------------------------------------------------------------------------
# R38.M1 (#1289/#1291/#1292/#1293): AX211 WiFi bring-up substrate --
# PCI probe + BAR mapping (ax211_probe), UMAC/MVM firmware
# dual-signature verifier (fw_verify), firmware load handshake +
# INIT_ALIVE notification (fw_load), and firmware version
# compatibility matrix (fw_compat).
#
# Four modules open R38.M1 (post-R37 close).  Each owns its own
# state; tools/build.sh confines relocations against each to its
# owning object so a second writer cannot forge a probe stat, a
# verified bundle record, a CSR bank snapshot, or a compat counter.
AXP_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/ax211_probe.pdx"
WFV_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/fw_verify.pdx"
WFL_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/fw_load.pdx"
WCM_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/fw_compat.pdx"
if [[ ! -f "${AXP_SRC}" || ! -f "${WFV_SRC}" \
        || ! -f "${WFL_SRC}" || ! -f "${WCM_SRC}" ]]; then
    echo "[wifi-m1-confine] FAIL - one of the R38.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_axp_probe_stats' 'core/drivers/wifi/ax211_probe.o'
ec_confine_one '_wfv_blob_ptr'    'core/drivers/wifi/fw_verify.o'
ec_confine_one '_wfv_blob_len'    'core/drivers/wifi/fw_verify.o'
ec_confine_one '_wfv_verified'    'core/drivers/wifi/fw_verify.o'
ec_confine_one '_wfv_umac_off'    'core/drivers/wifi/fw_verify.o'
ec_confine_one '_wfv_umac_len'    'core/drivers/wifi/fw_verify.o'
ec_confine_one '_wfv_mvm_off'     'core/drivers/wifi/fw_verify.o'
ec_confine_one '_wfv_mvm_len'     'core/drivers/wifi/fw_verify.o'
ec_confine_one '_wfv_stats'       'core/drivers/wifi/fw_verify.o'
ec_confine_one '_wfl_csr'         'core/drivers/wifi/fw_load.o'
ec_confine_one '_wfl_loaded'      'core/drivers/wifi/fw_load.o'
ec_confine_one '_wfl_alive_iters' 'core/drivers/wifi/fw_load.o'
ec_confine_one '_wfl_stats'       'core/drivers/wifi/fw_load.o'
ec_confine_one '_wcm_stats'       'core/drivers/wifi/fw_compat.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See ax211_probe.pdx §3, fw_verify.pdx §2, fw_load.pdx §3," >&2
    echo "  and fw_compat.pdx §2 for the row/counter one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[wifi-m1-confine] R38.M1 (AX211 WiFi bring-up substrate) confined"

# ---------------------------------------------------------------------------
# R38.M2 (#1294/#1295/#1298): AX211 WiFi transport plumbing --
# CTXT_INFO structure + TX/RX ring backing stores (ctxt_info), TX
# DMA enqueue + doorbell + completion tracking (tx_dma), and the
# per-driver DMA-domain refuse-gate (dma_domain) enforcing D1.b.
#
# Three modules open R38.M2 (post-R38.M1 close).  Each owns its own
# state; tools/build.sh confines relocations against each to its
# owning object so a second writer cannot forge a ring slot, a
# doorbell ring, an in-flight completion, or a domain binding.
WCTX_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/ctxt_info.pdx"
WTXD_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/tx_dma.pdx"
WDD_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/dma_domain.pdx"
if [[ ! -f "${WCTX_SRC}" || ! -f "${WTXD_SRC}" || ! -f "${WDD_SRC}" ]]; then
    echo "[wifi-m2-confine] FAIL - one of the R38.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_wctx_info'       'core/drivers/wifi/ctxt_info.o'
ec_confine_one '_wctx_tx_ring'    'core/drivers/wifi/ctxt_info.o'
ec_confine_one '_wctx_rx_ring'    'core/drivers/wifi/ctxt_info.o'
ec_confine_one '_wctx_indices'    'core/drivers/wifi/ctxt_info.o'
ec_confine_one '_wctx_stats'      'core/drivers/wifi/ctxt_info.o'
ec_confine_one '_wtxd_doorbell'   'core/drivers/wifi/tx_dma.o'
ec_confine_one '_wtxd_inflight'   'core/drivers/wifi/tx_dma.o'
ec_confine_one '_wtxd_stats'      'core/drivers/wifi/tx_dma.o'
ec_confine_one '_wdd_state'       'core/drivers/wifi/dma_domain.o'
ec_confine_one '_wdd_stats'       'core/drivers/wifi/dma_domain.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See ctxt_info.pdx §3, tx_dma.pdx §2 and dma_domain.pdx §3" >&2
    echo "  for the row/counter one-writer discipline." >&2
    exit 1
fi
echo "[wifi-m2-confine] R38.M2 (AX211 WiFi transport plumbing) confined"

# ---------------------------------------------------------------------------
# R38.M3 (#1299/#1300/#1301/#1302/#1303): WiFi capability layer --
# KIND_WIFI_PHY (kind_wifi_phy), KIND_WIFI_VIF (kind_wifi_vif),
# KIND_WIFI_SCAN_TXN (kind_wifi_scan_txn, LINEAR),
# wifi_control_channel and wifi_data_channel.
#
# Five modules open R38.M3 (post-R38.M2 close).  Each cap kind owns
# its own row table + counters; tools/build.sh confines relocations
# against each to its owning object so a second writer cannot forge
# a PHY row, restamp a VIF's MAC or mode, drift a scan's state or
# result count, or bypass the LINEAR triple-check by rewriting the
# frozen linear_flag byte.  The two channels have no private state
# (schema only) and take no confinement.
KWPHY_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_wifi_phy.pdx"
KWVIF_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_wifi_vif.pdx"
KWSCN_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_wifi_scan_txn.pdx"
WCC_SRC="${REPO_ROOT}/src/kernel/core/ipc/wifi_control_channel.pdx"
WDC_SRC="${REPO_ROOT}/src/kernel/core/ipc/wifi_data_channel.pdx"
if [[ ! -f "${KWPHY_SRC}" || ! -f "${KWVIF_SRC}" || ! -f "${KWSCN_SRC}" \
        || ! -f "${WCC_SRC}" || ! -f "${WDC_SRC}" ]]; then
    echo "[wifi-m3-confine] FAIL - one of the R38.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_wifi_phy_table'  'core/cap/kind_wifi_phy.o'
ec_confine_one '_wifi_phy_stats'  'core/cap/kind_wifi_phy.o'
ec_confine_one '_wifi_vif_table'  'core/cap/kind_wifi_vif.o'
ec_confine_one '_wifi_vif_stats'  'core/cap/kind_wifi_vif.o'
ec_confine_one '_wifi_scan_table' 'core/cap/kind_wifi_scan_txn.o'
ec_confine_one '_wifi_scan_stats' 'core/cap/kind_wifi_scan_txn.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_wifi_phy.pdx §1, kind_wifi_vif.pdx §1 and" >&2
    echo "  kind_wifi_scan_txn.pdx §3 for the row/counter one-writer" >&2
    echo "  discipline (linear_flag freeze for KIND_WIFI_SCAN_TXN)." >&2
    exit 1
fi
echo "[wifi-m3-confine] R38.M3 (WiFi capability layer) confined"

# ---------------------------------------------------------------------------
# R38.M4 (#1304/#1305/#1306/#1308): net80211 class driver --
# mgmt frame encode/decode (net80211_mgmt), association state machine
# (net80211_assoc), MLME + PMF (net80211_mlme), regulatory-domain gate
# (net80211_regdom).
#
# Four modules open R38.M4 (post-R38.M3 close).  Each owns its own
# state cells + counters; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot silently forge
# a staged mgmt frame, retire an assoc transition, promote a PMF
# mode, retire an SA Query, or forge a regdom binding.
NMG_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/net80211_mgmt.pdx"
NAS_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/net80211_assoc.pdx"
NML_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/net80211_mlme.pdx"
NRD_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/net80211_regdom.pdx"
if [[ ! -f "${NMG_SRC}" || ! -f "${NAS_SRC}" \
        || ! -f "${NML_SRC}" || ! -f "${NRD_SRC}" ]]; then
    echo "[net80211-m4-confine] FAIL - one of the R38.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_nmg_frame'    'core/drivers/wifi/net80211_mgmt.o'
ec_confine_one '_nmg_pos'      'core/drivers/wifi/net80211_mgmt.o'
ec_confine_one '_nmg_stats'    'core/drivers/wifi/net80211_mgmt.o'
ec_confine_one '_nas_state'    'core/drivers/wifi/net80211_assoc.o'
ec_confine_one '_nas_stats'    'core/drivers/wifi/net80211_assoc.o'
ec_confine_one '_nml_state'    'core/drivers/wifi/net80211_mlme.o'
ec_confine_one '_nml_stats'    'core/drivers/wifi/net80211_mlme.o'
ec_confine_one '_nrd_state'    'core/drivers/wifi/net80211_regdom.o'
ec_confine_one '_nrd_stats'    'core/drivers/wifi/net80211_regdom.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See net80211_mgmt.pdx §3, net80211_assoc.pdx §2," >&2
    echo "  net80211_mlme.pdx §3 and net80211_regdom.pdx §3 for the" >&2
    echo "  per-module one-writer discipline." >&2
    exit 1
fi
echo "[net80211-m4-confine] R38.M4 (net80211 class driver) confined"

# ---------------------------------------------------------------------------
# R38.M5 (#1309/#1310/#1311/#1312/#1313): WPA3-SAE + 4-way handshake +
# KIND_WIFI_KEY (SEALED) + KRACK-safe replay counter + wpa_supplicant
# channel schema.
#
# Five modules open R38.M5 (post-R38.M4 close).  Each owns its own
# state cells + counters; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot silently forge
# a key row, promote an SAE transition, admit a 4-way message, reset
# a replay counter, or repack an RPC.
KWKEY_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_wifi_key.pdx"
SAE_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/wpa3_sae.pdx"
W4H_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/wpa_4way.pdx"
RC_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/replay_counter.pdx"
WSC_SRC="${REPO_ROOT}/src/kernel/core/ipc/wpa_supplicant_channel.pdx"
if [[ ! -f "${KWKEY_SRC}" || ! -f "${SAE_SRC}" || ! -f "${W4H_SRC}" \
        || ! -f "${RC_SRC}" || ! -f "${WSC_SRC}" ]]; then
    echo "[r38-m5-confine] FAIL - one of the R38.M5 source files missing" >&2
    exit 1
fi
ec_confine_one '_wifi_key_table' 'core/cap/kind_wifi_key.o'
ec_confine_one '_wifi_key_stats' 'core/cap/kind_wifi_key.o'
ec_confine_one '_sae_state'      'core/drivers/wifi/wpa3_sae.o'
ec_confine_one '_sae_stats'      'core/drivers/wifi/wpa3_sae.o'
ec_confine_one '_w4h_state'      'core/drivers/wifi/wpa_4way.o'
ec_confine_one '_w4h_stats'      'core/drivers/wifi/wpa_4way.o'
ec_confine_one '_rc_table'       'core/drivers/wifi/replay_counter.o'
ec_confine_one '_rc_stats'       'core/drivers/wifi/replay_counter.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_wifi_key.pdx §2 (SEALED row), wpa3_sae.pdx §2," >&2
    echo "  wpa_4way.pdx §2, and replay_counter.pdx §2 for the per-" >&2
    echo "  module one-writer discipline." >&2
    exit 1
fi
echo "[r38-m5-confine] R38.M5 (WPA3-SAE + 4-way + WIFI_KEY + replay) confined"

# ---------------------------------------------------------------------------
# R38.M6 (#1314/#1315/#1316): regulatory-domain composition -- country-code
# loader + periodic hint schema + geo-hint discovery.
#
# Three modules open R38.M6 (post-R38.M5 close).  Each owns its own
# state cells + counters; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot silently forge
# a country code, promote a hint source, or forge a GNSS lock.
RDL_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/regdom_loader.pdx"
RDC_SRC="${REPO_ROOT}/src/kernel/core/ipc/regdomain_channel.pdx"
GH_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/geo_hint.pdx"
if [[ ! -f "${RDL_SRC}" || ! -f "${RDC_SRC}" || ! -f "${GH_SRC}" ]]; then
    echo "[r38-m6-confine] FAIL - one of the R38.M6 source files missing" >&2
    exit 1
fi
ec_confine_one '_rdl_state'      'core/drivers/wifi/regdom_loader.o'
ec_confine_one '_rdl_stats'      'core/drivers/wifi/regdom_loader.o'
ec_confine_one '_gh_state'       'core/drivers/wifi/geo_hint.o'
ec_confine_one '_gh_stats'       'core/drivers/wifi/geo_hint.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See regdom_loader.pdx §3 and geo_hint.pdx §3 for the per-" >&2
    echo "  module one-writer discipline.  regdomain_channel.pdx is" >&2
    echo "  a pure schema module (no .bss state) and carries no" >&2
    echo "  confinement entry." >&2
    exit 1
fi
echo "[r38-m6-confine] R38.M6 (regdom loader + channel + geo-hint) confined"

# ---------------------------------------------------------------------------
# R38.M7 (#1318/#1319/#1320/#1321): WiFi feature composition -- HE-MCS
# rate table + MU-MIMO metadata, PER-driven rate control, scan-while-
# connected roaming, PTK/GTK rekey rotation.
#
# Four modules open R38.M7 (post-R38.M6 close).  Each owns its own
# state cells + counters; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot silently
# promote a rate, force a step transition, forge a roaming candidate,
# or drive a rekey rotation past its slot-transition window.
HEM_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/he_mcs.pdx"
RC2_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/rate_control.pdx"
RM_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/roaming.pdx"
RK_SRC="${REPO_ROOT}/src/kernel/core/drivers/wifi/rekey.pdx"
if [[ ! -f "${HEM_SRC}" || ! -f "${RC2_SRC}" || ! -f "${RM_SRC}" || ! -f "${RK_SRC}" ]]; then
    echo "[r38-m7-confine] FAIL - one of the R38.M7 source files missing" >&2
    exit 1
fi
ec_confine_one '_hem_state'      'core/drivers/wifi/he_mcs.o'
ec_confine_one '_hem_groups'     'core/drivers/wifi/he_mcs.o'
ec_confine_one '_hem_users'      'core/drivers/wifi/he_mcs.o'
ec_confine_one '_hem_stats'      'core/drivers/wifi/he_mcs.o'
ec_confine_one '_rc2_table'      'core/drivers/wifi/rate_control.o'
ec_confine_one '_rc2_stats'      'core/drivers/wifi/rate_control.o'
ec_confine_one '_rm_state'       'core/drivers/wifi/roaming.o'
ec_confine_one '_rm_table'       'core/drivers/wifi/roaming.o'
ec_confine_one '_rm_stats'       'core/drivers/wifi/roaming.o'
ec_confine_one '_rk_state'       'core/drivers/wifi/rekey.o'
ec_confine_one '_rk_stats'       'core/drivers/wifi/rekey.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See he_mcs.pdx §3, rate_control.pdx §2, roaming.pdx §3" >&2
    echo "  and rekey.pdx §2 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[r38-m7-confine] R38.M7 (HE-MCS + rate control + roaming + rekey) confined"

# ---------------------------------------------------------------------------
# R39.M1 (#1323/#1324/#1325/#1326): Bluetooth HCI substrate over CNVi --
# KIND_BT_ADAPTER (kind_bt_adapter), KIND_BT_HCI_CHANNEL
# (kind_bt_hci_channel), HCI transport over CNVi (hci_cnvi), and the
# bt_hci_channel schema (bt_hci_channel).
#
# Four modules open the R39 tree at the substrate layer; each owns its
# own state; tools/build.sh confines relocations against each to its
# owning object so a second writer cannot forge an ADAPTER row, drift a
# channel row, restamp a TX/RX ring slot, or forge a session-schema
# counter.
KBA_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_bt_adapter.pdx"
KBHC_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_bt_hci_channel.pdx"
HCI_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/hci_cnvi.pdx"
BHC_SRC="${REPO_ROOT}/src/kernel/core/ipc/bt_hci_channel.pdx"
if [[ ! -f "${KBA_SRC}" || ! -f "${KBHC_SRC}" || ! -f "${HCI_SRC}" || ! -f "${BHC_SRC}" ]]; then
    echo "[r39-m1-confine] FAIL - one of the R39.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_bt_adapter_table'  'core/cap/kind_bt_adapter.o'
ec_confine_one '_bt_adapter_stats'  'core/cap/kind_bt_adapter.o'
ec_confine_one '_bt_hci_chan_table' 'core/cap/kind_bt_hci_channel.o'
ec_confine_one '_bt_hci_chan_stats' 'core/cap/kind_bt_hci_channel.o'
ec_confine_one '_hci_tx_ring'       'core/drivers/bt/hci_cnvi.o'
ec_confine_one '_hci_rx_ring'       'core/drivers/bt/hci_cnvi.o'
ec_confine_one '_hci_indices'       'core/drivers/bt/hci_cnvi.o'
ec_confine_one '_hci_stats'         'core/drivers/bt/hci_cnvi.o'
ec_confine_one '_hci_arbitrated'    'core/drivers/bt/hci_cnvi.o'
ec_confine_one '_bhc_sessions'      'core/ipc/bt_hci_channel.o'
ec_confine_one '_bhc_stats'         'core/ipc/bt_hci_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_bt_adapter.pdx §2, kind_bt_hci_channel.pdx §3," >&2
    echo "  hci_cnvi.pdx §3, and bt_hci_channel.pdx §2 for the" >&2
    echo "  per-module one-writer discipline." >&2
    exit 1
fi
echo "[r39-m1-confine] R39.M1 (BT adapter + HCI channel + CNVi transport + schema) confined"

# ---------------------------------------------------------------------------
# R39.M2 (#1327/#1328/#1329/#1330): Bluetooth L2CAP substrate --
# KIND_BT_L2CAP_CHANNEL (kind_bt_l2cap_channel), L2CAP fixed channels
# (l2cap_fixed), L2CAP dynamic channels with LE CBFC (l2cap_dyn), and
# the bt_l2cap_channel schema (bt_l2cap_channel).
#
# Four modules open the L2CAP layer above R39.M1's HCI substrate;
# each owns its own state; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot forge an L2CAP
# CHANNEL row, restamp a fixed-CID handler binding, drift a dynamic
# session's credit balance, or forge a schema counter.
KBL2C_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_bt_l2cap_channel.pdx"
LFX_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/l2cap_fixed.pdx"
LDYN_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/l2cap_dyn.pdx"
BL2C_SRC="${REPO_ROOT}/src/kernel/core/ipc/bt_l2cap_channel.pdx"
if [[ ! -f "${KBL2C_SRC}" || ! -f "${LFX_SRC}" || ! -f "${LDYN_SRC}" || ! -f "${BL2C_SRC}" ]]; then
    echo "[r39-m2-confine] FAIL - one of the R39.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_bt_l2cap_chan_table' 'core/cap/kind_bt_l2cap_channel.o'
ec_confine_one '_bt_l2cap_chan_stats' 'core/cap/kind_bt_l2cap_channel.o'
ec_confine_one '_lfx_channels'        'core/drivers/bt/l2cap_fixed.o'
ec_confine_one '_lfx_stats'           'core/drivers/bt/l2cap_fixed.o'
ec_confine_one '_lfx_init'            'core/drivers/bt/l2cap_fixed.o'
ec_confine_one '_ldyn_sessions'       'core/drivers/bt/l2cap_dyn.o'
ec_confine_one '_ldyn_stats'          'core/drivers/bt/l2cap_dyn.o'
ec_confine_one '_ldyn_init'           'core/drivers/bt/l2cap_dyn.o'
ec_confine_one '_ldyn_next_cid'       'core/drivers/bt/l2cap_dyn.o'
ec_confine_one '_bl2c_sessions'       'core/ipc/bt_l2cap_channel.o'
ec_confine_one '_bl2c_stats'          'core/ipc/bt_l2cap_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_bt_l2cap_channel.pdx §2, l2cap_fixed.pdx §2," >&2
    echo "  l2cap_dyn.pdx §2, and bt_l2cap_channel.pdx §1 for the" >&2
    echo "  per-module one-writer discipline." >&2
    exit 1
fi
echo "[r39-m2-confine] R39.M2 (BT L2CAP channel + fixed + dynamic + schema) confined"

# ---------------------------------------------------------------------------
# R39.M3-001 (#1331): Bluetooth ATT (Attribute Protocol) codec + server
# dispatcher over the R39.M3-002 gatt.pdx attribute database.
#
# One module lands the ATT wire layer BETWEEN R39.M2 (L2CAP) and
# R39.M3-002 (GATT).  It owns the current MTU cell and the dispatch
# counters; tools/build.sh confines relocations against each to its
# owning object so a second writer cannot silently retune the MTU under
# a live connection or forge the dispatch counter tally.
ATT_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/att.pdx"
if [[ ! -f "${ATT_SRC}" ]]; then
    echo "[r39-m3-001-confine] FAIL - att.pdx missing" >&2
    exit 1
fi
ec_confine_one '_att_mtu'   'core/drivers/bt/att.o'
ec_confine_one '_att_stats' 'core/drivers/bt/att.o'
ec_confine_one '_att_init'  'core/drivers/bt/att.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See att.pdx §4 for the MTU / counters / init-flag" >&2
    echo "  one-writer discipline." >&2
    exit 1
fi
echo "[r39-m3-001-confine] R39.M3-001 (BT ATT codec + server dispatch) confined"

# ---------------------------------------------------------------------------
# R39.M3 (#1332/#1333/#1334): Bluetooth GATT substrate --
# KIND_BT_GATT_CONNECTION (kind_bt_gatt_connection), GATT server +
# client + ATT PDU codec (gatt), bt_gatt_channel schema
# (bt_gatt_channel).
#
# Three modules open the R39 tree in this witness ordering.  Each owns
# its own state; tools/build.sh confines relocations against each to
# its owning object so a second writer cannot forge a GATT CONNECTION
# row, restamp an attribute-table entry, drift the discovery walker
# cursor, or forge an RPC-channel counter.
KBGC_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_bt_gatt_connection.pdx"
GATT_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/gatt.pdx"
BTGC_SRC="${REPO_ROOT}/src/kernel/core/ipc/bt_gatt_channel.pdx"
if [[ ! -f "${KBGC_SRC}" || ! -f "${GATT_SRC}" || ! -f "${BTGC_SRC}" ]]; then
    echo "[r39-m3-confine] FAIL - one of the R39.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_bt_gatt_conn_table' 'core/cap/kind_bt_gatt_connection.o'
ec_confine_one '_bt_gatt_conn_stats' 'core/cap/kind_bt_gatt_connection.o'
ec_confine_one '_gatt_attrs'         'core/drivers/bt/gatt.o'
ec_confine_one '_gatt_disc'          'core/drivers/bt/gatt.o'
ec_confine_one '_gatt_stats'         'core/drivers/bt/gatt.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_bt_gatt_connection.pdx §2, gatt.pdx §3" >&2
    echo "  for the row / attribute-table / walker one-writer discipline." >&2
    exit 1
fi
echo "[r39-m3-confine] R39.M3 (BT GATT connection + server + channel) confined"

# ---------------------------------------------------------------------------
# R39.M4 (#1335/#1336/#1337): Bluetooth LE Secure Connections pairing --
# KIND_BT_PAIRING (SEALED) + le_sc pairing driver + bt_pairing_channel
# schema.
#
# Three modules open R39.M4 (post-R39.M3 close).  Each owns its own
# state cells + counters; tools/build.sh confines relocations against
# each to its owning object so a second writer cannot silently forge a
# pairing row, promote an FSM edge, or forge a consent-broker record.
KBTP_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_bt_pairing.pdx"
LESC_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/le_sc.pdx"
BPC_SRC="${REPO_ROOT}/src/kernel/core/ipc/bt_pairing_channel.pdx"
if [[ ! -f "${KBTP_SRC}" || ! -f "${LESC_SRC}" || ! -f "${BPC_SRC}" ]]; then
    echo "[r39-m4-confine] FAIL - one of the R39.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_bt_pairing_table' 'core/cap/kind_bt_pairing.o'
ec_confine_one '_bt_pairing_stats' 'core/cap/kind_bt_pairing.o'
ec_confine_one '_lesc_sessions'    'core/drivers/bt/le_sc.o'
ec_confine_one '_lesc_stats'       'core/drivers/bt/le_sc.o'
ec_confine_one '_lesc_init'        'core/drivers/bt/le_sc.o'
ec_confine_one '_bpc_sessions'     'core/ipc/bt_pairing_channel.o'
ec_confine_one '_bpc_stats'        'core/ipc/bt_pairing_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_bt_pairing.pdx §2 (SEALED row), le_sc.pdx §1," >&2
    echo "  and bt_pairing_channel.pdx §2 for the per-module" >&2
    echo "  one-writer discipline." >&2
    exit 1
fi
echo "[r39-m4-confine] R39.M4 (BT LE SC pairing + KIND_BT_PAIRING + channel) confined"

# ---------------------------------------------------------------------------
# R39.M5 (#1339/#1340/#1341): Bluetooth A2DP -- profile + audio-graph
# bridge + retransmission/resync.
#
# Three modules open R39.M5.  Each owns its own state cells + counters;
# tools/build.sh confines relocations against each to its owning object
# so a second writer cannot silently forge an SEP row, promote an FSM
# edge, forge a bridge record, or hide a dropped ACL packet.
A2DP_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/a2dp.pdx"
A2DB_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/a2dp_bridge.pdx"
A2RTX_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/a2dp_rtx.pdx"
if [[ ! -f "${A2DP_SRC}" || ! -f "${A2DB_SRC}" || ! -f "${A2RTX_SRC}" ]]; then
    echo "[r39-m5-confine] FAIL - one of the R39.M5 source files missing" >&2
    exit 1
fi
ec_confine_one '_a2dp_seps'      'core/drivers/bt/a2dp.o'
ec_confine_one '_a2dp_stats'     'core/drivers/bt/a2dp.o'
ec_confine_one '_a2dp_init'      'core/drivers/bt/a2dp.o'
ec_confine_one '_a2db_bridges'   'core/drivers/bt/a2dp_bridge.o'
ec_confine_one '_a2db_stats'     'core/drivers/bt/a2dp_bridge.o'
ec_confine_one '_a2db_init'      'core/drivers/bt/a2dp_bridge.o'
ec_confine_one '_a2rtx_rows'     'core/drivers/bt/a2dp_rtx.o'
ec_confine_one '_a2rtx_stats'    'core/drivers/bt/a2dp_rtx.o'
ec_confine_one '_a2rtx_init'     'core/drivers/bt/a2dp_rtx.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See a2dp.pdx §4, a2dp_bridge.pdx §2, and a2dp_rtx.pdx §2" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[r39-m5-confine] R39.M5 (BT A2DP + bridge + retx) confined"

# ---------------------------------------------------------------------------
# R39.M6 (#1343/#1344/#1345): Bluetooth profiles that close r39-bluetooth --
# HFP call audio (hfp), BT HID over L2CAP (bt_hid), and LE Audio
# scaffolding (le_audio).
#
# Three modules close the R39 tree.  Each owns its own state cells +
# counters; tools/build.sh confines relocations against each to its
# owning object so a second writer cannot silently forge a session row,
# promote an FSM edge, forge a bind row that misroutes keystrokes to
# the wrong subscriber, or drift the LC3 frame-length contract.
HFP_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/hfp.pdx"
BTHID_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/bt_hid.pdx"
LEAU_SRC="${REPO_ROOT}/src/kernel/core/drivers/bt/le_audio.pdx"
if [[ ! -f "${HFP_SRC}" || ! -f "${BTHID_SRC}" || ! -f "${LEAU_SRC}" ]]; then
    echo "[r39-m6-confine] FAIL - one of the R39.M6 source files missing" >&2
    exit 1
fi
ec_confine_one '_hfp_sessions'   'core/drivers/bt/hfp.o'
ec_confine_one '_hfp_stats'      'core/drivers/bt/hfp.o'
ec_confine_one '_hfp_init'       'core/drivers/bt/hfp.o'
ec_confine_one '_bthid_rows'     'core/drivers/bt/bt_hid.o'
ec_confine_one '_bthid_stats'    'core/drivers/bt/bt_hid.o'
ec_confine_one '_bthid_init'     'core/drivers/bt/bt_hid.o'
ec_confine_one '_leau_rows'      'core/drivers/bt/le_audio.o'
ec_confine_one '_leau_stats'     'core/drivers/bt/le_audio.o'
ec_confine_one '_leau_init'      'core/drivers/bt/le_audio.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See hfp.pdx §4, bt_hid.pdx §2, and le_audio.pdx §5" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[r39-m6-confine] R39.M6 (BT HFP + HID + LE Audio scaffolding) confined"

# ---------------------------------------------------------------------------
# R40.M1 (#1347/#1348/#1349): Intel IPU6 camera bring-up scaffold --
# PCI probe (ipu6_probe), dual-sig firmware verify (ipu6_verify), and
# firmware upload + BOOT_READY handshake (ipu6_load).
#
# Three modules open the R40 tree.  Each owns its own state cells +
# counters; tools/build.sh confines relocations against each to its
# owning object so a second writer cannot silently forge a probe
# match, admit a mis-signed firmware bundle, or leave the CPU_HALT
# bit inconsistent with the loaded flag.
IPP_SRC="${REPO_ROOT}/src/kernel/core/drivers/cam/ipu6_probe.pdx"
IPV_SRC="${REPO_ROOT}/src/kernel/core/drivers/cam/ipu6_verify.pdx"
IPL_SRC="${REPO_ROOT}/src/kernel/core/drivers/cam/ipu6_load.pdx"
if [[ ! -f "${IPP_SRC}" || ! -f "${IPV_SRC}" || ! -f "${IPL_SRC}" ]]; then
    echo "[r40-m1-confine] FAIL - one of the R40.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_ipp_probe_stats' 'core/drivers/cam/ipu6_probe.o'
ec_confine_one '_ipv_blob_ptr'    'core/drivers/cam/ipu6_verify.o'
ec_confine_one '_ipv_blob_len'    'core/drivers/cam/ipu6_verify.o'
ec_confine_one '_ipv_verified'    'core/drivers/cam/ipu6_verify.o'
ec_confine_one '_ipv_code_off'    'core/drivers/cam/ipu6_verify.o'
ec_confine_one '_ipv_code_len'    'core/drivers/cam/ipu6_verify.o'
ec_confine_one '_ipv_stats'       'core/drivers/cam/ipu6_verify.o'
ec_confine_one '_ipl_ctrl'        'core/drivers/cam/ipu6_load.o'
ec_confine_one '_ipl_loaded'      'core/drivers/cam/ipu6_load.o'
ec_confine_one '_ipl_ready_iters' 'core/drivers/cam/ipu6_load.o'
ec_confine_one '_ipl_stats'       'core/drivers/cam/ipu6_load.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See ipu6_probe.pdx §3, ipu6_verify.pdx §2, and ipu6_load.pdx §3" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[r40-m1-confine] R40.M1 (IPU6 probe + verify + load) confined"

# ---------------------------------------------------------------------------
# R40.M2 (#1351/#1352/#1353/#1354): MIPI-CSI + KIND_CSI_CAMERA + sensor
# enumeration + per-sensor init sequences.
#
# Four modules open R40.M2: the KIND_CSI_CAMERA capability (kind_csi_camera),
# the MIPI-CSI D-PHY receiver init driver (csi_phy), the sensor _CID
# enumeration driver (sensor_enum), and the per-sensor init sequence driver
# (sensor_init).  Each owns its own state cells + counters; tools/build.sh
# confines relocations against each to its owning object so a second writer
# cannot silently forge a camera row, bring the PHY up under a stale lane
# mask, bind a spurious _CID to a driver, or program a sensor into a mode
# nobody asked for.
KCCAM_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_csi_camera.pdx"
MCSI_SRC="${REPO_ROOT}/src/kernel/core/drivers/cam/csi_phy.pdx"
SEN_SRC="${REPO_ROOT}/src/kernel/core/drivers/cam/sensor_enum.pdx"
SINIT_SRC="${REPO_ROOT}/src/kernel/core/drivers/cam/sensor_init.pdx"
if [[ ! -f "${KCCAM_SRC}" || ! -f "${MCSI_SRC}" || ! -f "${SEN_SRC}" || ! -f "${SINIT_SRC}" ]]; then
    echo "[r40-m2-confine] FAIL - one of the R40.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_csi_camera_table' 'core/cap/kind_csi_camera.o'
ec_confine_one '_csi_camera_stats' 'core/cap/kind_csi_camera.o'
ec_confine_one '_mcsi_ctrl'        'core/drivers/cam/csi_phy.o'
ec_confine_one '_mcsi_state'       'core/drivers/cam/csi_phy.o'
ec_confine_one '_mcsi_stats'       'core/drivers/cam/csi_phy.o'
ec_confine_one '_sen_bind_table'   'core/drivers/cam/sensor_enum.o'
ec_confine_one '_sen_bind_count'   'core/drivers/cam/sensor_enum.o'
ec_confine_one '_sen_stats'        'core/drivers/cam/sensor_enum.o'
ec_confine_one '_sinit_ctrl'       'core/drivers/cam/sensor_init.o'
ec_confine_one '_sinit_state'      'core/drivers/cam/sensor_init.o'
ec_confine_one '_sinit_stats'      'core/drivers/cam/sensor_init.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_csi_camera.pdx §2 (row table), csi_phy.pdx §2," >&2
    echo "  sensor_enum.pdx §1, and sensor_init.pdx §2 for the" >&2
    echo "  per-module one-writer discipline." >&2
    exit 1
fi
echo "[r40-m2-confine] R40.M2 (MIPI-CSI + KIND_CSI_CAMERA + sensor enum + sensor init) confined"

# ---------------------------------------------------------------------------
# R40.M3 (#1355/#1356/#1357): IPU6 imaging pipeline + KIND_IPU6_STREAM +
# camera capture channel.
#
# Three modules open R40.M3: the IPU6 pipeline stage scaffold
# (ipu6_pipeline), the KIND_IPU6_STREAM capability (kind_ipu6_stream),
# and the camera_capture_channel session schema (camera_capture_channel).
# Each owns its own state cells + counters; tools/build.sh confines
# relocations against each to its owning object so a second writer
# cannot silently forge a stream row, restamp the pipeline CTRL bank
# or advance the session FSM out from under the ring-3 supervisor.
KIPU6S_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_ipu6_stream.pdx"
IPP2_SRC="${REPO_ROOT}/src/kernel/core/drivers/cam/ipu6_pipeline.pdx"
CCC_SRC="${REPO_ROOT}/src/kernel/core/ipc/camera_capture_channel.pdx"
if [[ ! -f "${KIPU6S_SRC}" || ! -f "${IPP2_SRC}" || ! -f "${CCC_SRC}" ]]; then
    echo "[r40-m3-confine] FAIL - one of the R40.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_ipu6_stream_table' 'core/cap/kind_ipu6_stream.o'
ec_confine_one '_ipu6_stream_stats' 'core/cap/kind_ipu6_stream.o'
ec_confine_one '_ipp2_ctrl'         'core/drivers/cam/ipu6_pipeline.o'
ec_confine_one '_ipp2_state'        'core/drivers/cam/ipu6_pipeline.o'
ec_confine_one '_ipp2_stage_counts' 'core/drivers/cam/ipu6_pipeline.o'
ec_confine_one '_ipp2_stats'        'core/drivers/cam/ipu6_pipeline.o'
ec_confine_one '_ccc_state'         'core/ipc/camera_capture_channel.o'
ec_confine_one '_ccc_stats'         'core/ipc/camera_capture_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_ipu6_stream.pdx §2 (row table), ipu6_pipeline.pdx §2," >&2
    echo "  and camera_capture_channel.pdx §1 (session cell) for the" >&2
    echo "  per-module one-writer discipline." >&2
    exit 1
fi
echo "[r40-m3-confine] R40.M3 (IPU6 pipeline + KIND_IPU6_STREAM + camera capture channel) confined"

# ---------------------------------------------------------------------------
# R40.M4 (#1359/#1360/#1361/#1362): WWAN M.2 modem + MBIM.
#
# Four modules open R40.M4: the KIND_WWAN_MODEM capability
# (kind_wwan_modem), the KIND_MBIM_SESSION capability (kind_mbim_session),
# the M.2 WWAN probe + power-gating driver (wwan_probe), and the MBIM
# control / notification substrate (mbim).  Each owns its own state
# cells + counters; tools/build.sh confines relocations against each
# to its owning object so a second writer cannot silently forge a
# modem row, restamp a session's FSM state, admit a spurious M.2
# vendor, or drop the modem into an intermediate power state nobody
# validated.
KWWM_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_wwan_modem.pdx"
KMBS_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_mbim_session.pdx"
WWP_SRC="${REPO_ROOT}/src/kernel/core/drivers/wwan/wwan_probe.pdx"
MBIM_SRC="${REPO_ROOT}/src/kernel/core/drivers/wwan/mbim.pdx"
if [[ ! -f "${KWWM_SRC}" || ! -f "${KMBS_SRC}" || ! -f "${WWP_SRC}" || ! -f "${MBIM_SRC}" ]]; then
    echo "[r40-m4-confine] FAIL - one of the R40.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_wwan_modem_table'   'core/cap/kind_wwan_modem.o'
ec_confine_one '_wwan_modem_stats'   'core/cap/kind_wwan_modem.o'
ec_confine_one '_mbim_session_table' 'core/cap/kind_mbim_session.o'
ec_confine_one '_mbim_session_stats' 'core/cap/kind_mbim_session.o'
ec_confine_one '_wwp_probes'         'core/drivers/wwan/wwan_probe.o'
ec_confine_one '_wwp_probe_count'    'core/drivers/wwan/wwan_probe.o'
ec_confine_one '_wwp_probe_stats'    'core/drivers/wwan/wwan_probe.o'
ec_confine_one '_wwp_pwr_last'       'core/drivers/wwan/wwan_probe.o'
ec_confine_one '_mbim_ctrl_state'    'core/drivers/wwan/mbim.o'
ec_confine_one '_mbim_notif_last'    'core/drivers/wwan/mbim.o'
ec_confine_one '_mbim_signal'        'core/drivers/wwan/mbim.o'
ec_confine_one '_mbim_stats'         'core/drivers/wwan/mbim.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_wwan_modem.pdx §1 (row table), kind_mbim_session.pdx §1," >&2
    echo "  wwan_probe.pdx §4, and mbim.pdx §2 for the per-module one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[r40-m4-confine] R40.M4 (WWAN M.2 modem + KIND_WWAN_MODEM + KIND_MBIM_SESSION + MBIM) confined"

# ---------------------------------------------------------------------------
# R40.M5-001 (#1363): AUDIT SCHEMA ARITY PINS.
#
# audit_schema.pdx is the canonical audit-event row shape and its
# packers/unpackers -- a schema module with no .bss storage of its own
# (the underlying ring stays audit_channel.pdx's _drv_audit_ring), so
# there is no _table to confine.  What there IS to defend is the arity
# of every packer, unpacker, validator and the audit_emit wrapper.  A
# fourth parameter on aud_pack_at is a caller-supplied width that reads
# a different bit range from the composed principal; a seventh parameter
# on audit_emit is a caller-supplied side-channel that quietly emits a
# second record.  Neither is expressible against a pinned signature.
AUDS_SRC="${REPO_ROOT}/src/kernel/core/audit/audit_schema.pdx"
if [[ ! -f "${AUDS_SRC}" ]]; then
    echo "[audit-schema-confine] FAIL - ${AUDS_SRC} not found" >&2
    exit 1
fi
auds_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${AUDS_SRC}"; then
        echo "[audit-schema-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  AN AUDIT SCHEMA FIELD IS DECIDED BY THE SCHEMA AND NEVER BY" >&2
        echo "  A CALLER. An extra parameter on any packer, unpacker or" >&2
        echo "  audit_emit makes 'pack a field my subscriber does not know" >&2
        echo "  about' or 'emit a second record with a caller-supplied" >&2
        echo "  layout' expressible, and both ways that goes wrong silently" >&2
        echo "  reads or writes the wrong bits (an actor becomes a target;" >&2
        echo "  a payload_lo becomes a fabricated timestamp)." >&2
        echo "  If a signature legitimately changed, the schema doc" >&2
        echo "  src/kernel/core/audit/audit_schema.pdx §1/§2 must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
auds_pin_one 'pub let aud_ev_valid : (u64) -> u64'
auds_pin_one 'pub let aud_ev_is_cap : (u64) -> u64'
auds_pin_one 'pub let aud_field_valid : (u64) -> u64'
auds_pin_one 'pub let aud_kind_valid : (u64) -> u64'
auds_pin_one 'pub let aud_pack_at : (u64, u64) -> u64'
auds_pin_one 'pub let aud_unpack_actor : (u64) -> u64'
auds_pin_one 'pub let aud_unpack_target : (u64) -> u64'
auds_pin_one 'pub let aud_pack_payload : (u64, u64) -> u64'
auds_pin_one 'pub let aud_unpack_payload_lo : (u64) -> u64'
auds_pin_one 'pub let aud_pack_principal : (u64, u64) -> u64'
auds_pin_one 'pub let aud_prin_actor : (u64) -> u64'
auds_pin_one 'pub let aud_prin_target : (u64) -> u64'
auds_pin_one 'pub let aud_prin_payload_lo : (u64) -> u64'
auds_pin_one 'pub let audit_emit : (u64, u64, u64, u64, u64, u64) -> u64'
echo "[audit-schema-confine] four validators, three pack/unpack pairs and audit_emit wrapper arities pinned"

# ---------------------------------------------------------------------------
# R41.M1-001/002/003 (#1365/#1366/#1367): SEMTERM CORE CONFINEMENT.
#
# semantic-term-core is the shared backend behind the R41 framebuffer
# terminal and (later) the R44 GUI terminal. Three modules open R41.M1:
# lexer, parser, and query-type-system. Each owns its own state cells;
# tools/build.sh confines relocations against each to its owning object
# so a second writer cannot silently:
#   - forge a token record so a parser sees a keyword the lexer never
#     produced (lexer confinement),
#   - back-write an arena cell so a type checker walks a node shape the
#     recogniser never emitted (parser confinement),
#   - shadow a binding so an environment lookup returns a type the
#     bind path never installed (types confinement).
LEX_SRC="${REPO_ROOT}/src/kernel/core/semterm/lexer.pdx"
PAR_SRC="${REPO_ROOT}/src/kernel/core/semterm/parser.pdx"
TYQ_SRC="${REPO_ROOT}/src/kernel/core/semterm/types.pdx"
if [[ ! -f "${LEX_SRC}" || ! -f "${PAR_SRC}" || ! -f "${TYQ_SRC}" ]]; then
    echo "[semterm-confine] FAIL - one of the R41.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_lex_state'    'core/semterm/lexer.o'
ec_confine_one '_lex_stats'    'core/semterm/lexer.o'
ec_confine_one '_par_arena'    'core/semterm/parser.o'
ec_confine_one '_par_state'    'core/semterm/parser.o'
ec_confine_one '_tyq_env'      'core/semterm/types.o'
ec_confine_one '_tyq_types'    'core/semterm/types.o'
ec_confine_one '_tyq_effects'  'core/semterm/types.o'
ec_confine_one '_tyq_state'    'core/semterm/types.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/lexer.pdx §2, parser.pdx §2, and" >&2
    echo "  types.pdx §4 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-confine] R41.M1 (lexer + parser + types) state confined"

# ARITY PINS. Every entry point takes only the caller-visible arguments
# its contract names. A widening on any of these makes "install a
# fabricated token in the state without going through the scanner",
# "wire the arena into a shape the recogniser never produced", or
# "shadow a binding so the checker walks a different environment"
# expressible in a call site the confinement gate above cannot see.
semterm_pin_one() {
    local src="$1" decl="$2"
    if ! grep -qF -- "${decl}" "${src}"; then
        echo "[semterm-confine] FAIL - expected declaration not found in ${src}:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A SEMTERM CORE ENTRY POINT'S ARITY IS DECIDED BY THE MODULE" >&2
        echo "  AND NEVER BY A CALLER. See the module's §4 arity discipline" >&2
        echo "  note for why a widening voids the confinement argument." >&2
        exit 1
    fi
}
semterm_pin_one "${LEX_SRC}" 'pub let lex_bind : (u64, u64) -> u64'
semterm_pin_one "${LEX_SRC}" 'pub let lex_next : () -> u64'
semterm_pin_one "${LEX_SRC}" 'pub let lex_tok_kind : () -> u64'
semterm_pin_one "${LEX_SRC}" 'pub let lex_kw_match : (u64, u64) -> u64'
semterm_pin_one "${PAR_SRC}" 'pub let par_alloc : (u64) -> u64'
semterm_pin_one "${PAR_SRC}" 'pub let par_node_set : (u64, u64, u64) -> u64'
semterm_pin_one "${PAR_SRC}" 'pub let par_node_get : (u64, u64) -> u64'
semterm_pin_one "${PAR_SRC}" 'pub let par_expect : (u64) -> u64'
semterm_pin_one "${PAR_SRC}" 'pub let par_parse_select : () -> u64'
semterm_pin_one "${TYQ_SRC}" 'pub let tyq_bind : (u64, u64) -> u64'
semterm_pin_one "${TYQ_SRC}" 'pub let tyq_lookup : (u64) -> u64'
semterm_pin_one "${TYQ_SRC}" 'pub let tyq_infer : (u64) -> u64'
semterm_pin_one "${TYQ_SRC}" 'pub let tyq_effect_union : (u64, u64) -> u64'
echo "[semterm-confine] lexer / parser / types entry-point arities pinned"

# ---------------------------------------------------------------------------
# R41.M2-001/002/003 (#1368/#1369/#1370): SEMTERM QUERY-ORCHESTRATION LAYER
# CONFINEMENT.
#
# Three modules open R41.M2 on top of the R41.M1 lexer / parser /
# types stack: engine (evaluator + plan state machine), sources
# (typed data-source registry), resultset (streaming pull buffer).
# Each owns its own state cells; a second writer against any of them
# would let a caller:
#   - install a plan without going through eng_plan (engine
#     confinement) so a caller could smuggle a source_id that
#     src_lookup never returned into eng_next's dispatch,
#   - overwrite a source row so a FROM name resolves to a schema the
#     registrar never installed (sources confinement),
#   - forge a result-set row so a consumer downstream sees a value
#     the engine never emitted (resultset confinement).
ENG_SRC="${REPO_ROOT}/src/kernel/core/semterm/engine.pdx"
SRC_SRC="${REPO_ROOT}/src/kernel/core/semterm/sources.pdx"
RSET_SRC="${REPO_ROOT}/src/kernel/core/semterm/resultset.pdx"
if [[ ! -f "${ENG_SRC}" || ! -f "${SRC_SRC}" || ! -f "${RSET_SRC}" ]]; then
    echo "[semterm-m2-confine] FAIL - one of the R41.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_eng_state'  'core/semterm/engine.o'
ec_confine_one '_src_table'  'core/semterm/sources.o'
ec_confine_one '_src_state'  'core/semterm/sources.o'
ec_confine_one '_rs_buf'     'core/semterm/resultset.o'
ec_confine_one '_rs_state'   'core/semterm/resultset.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/engine.pdx §3, sources.pdx §2, and" >&2
    echo "  resultset.pdx §2 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-m2-confine] R41.M2 (engine + sources + resultset) state confined"

# ARITY PINS for the M2 entry points. Same rationale as the M1 pins
# above: a widening on any of these makes "install a plan the engine
# never validated", "fabricate a source row the registrar never
# accepted", or "push a cell into a row the producer never opened"
# expressible in a call site the confinement gate cannot see.
semterm_pin_one "${ENG_SRC}"  'pub let eng_plan : (u64, u64) -> u64'
semterm_pin_one "${ENG_SRC}"  'pub let eng_next : () -> u64'
semterm_pin_one "${ENG_SRC}"  'pub let eng_close : () -> u64'
semterm_pin_one "${SRC_SRC}"  'pub let src_register : (u64, u64, u64, u64) -> u64'
semterm_pin_one "${SRC_SRC}"  'pub let src_lookup : (u64) -> u64'
semterm_pin_one "${SRC_SRC}"  'pub let src_get_schema : (u64) -> u64'
semterm_pin_one "${SRC_SRC}"  'pub let src_get_provider : (u64) -> u64'
semterm_pin_one "${SRC_SRC}"  'pub let src_get_cap : (u64) -> u64'
semterm_pin_one "${RSET_SRC}" 'pub let rs_open : (u64) -> u64'
semterm_pin_one "${RSET_SRC}" 'pub let rs_push : (u64, u64) -> u64'
semterm_pin_one "${RSET_SRC}" 'pub let rs_next : () -> u64'
semterm_pin_one "${RSET_SRC}" 'pub let rs_get : (u64, u64) -> u64'
semterm_pin_one "${RSET_SRC}" 'pub let rs_pack : (u64, u64) -> u64'
semterm_pin_one "${RSET_SRC}" 'pub let rs_seal : () -> u64'
echo "[semterm-m2-confine] engine / sources / resultset entry-point arities pinned"

# ---------------------------------------------------------------------------
# R41.M3-001/002/003 (#1371/#1372/#1373): SEMTERM CHART-COMPOSITION LAYER
# CONFINEMENT.
#
# Three modules open R41.M3 on top of the R41.M2 engine / sources /
# resultset stack: plot (text-mode cell buffer + glyph primitives),
# layout (grid pane arena + splits), palette (default RGB + ANSI SGR
# mapping + colorblind-safe series + xterm-256 extended formula).
# Each owns its own state cells; a second writer against any of them
# would let a caller:
#   - overwrite a canvas cell without going through plt_put (plot
#     confinement) so a caller could paint a glyph the compositor
#     never emitted,
#   - forge a pane rectangle so a chart draws outside its allotted
#     region (layout confinement),
#   - substitute a palette entry so an ANSI SGR ordinal resolves to
#     a color the module never installed (palette confinement).
PLT_SRC="${REPO_ROOT}/src/kernel/core/semterm/plot.pdx"
LAY_SRC="${REPO_ROOT}/src/kernel/core/semterm/layout.pdx"
PAL_SRC="${REPO_ROOT}/src/kernel/core/semterm/palette.pdx"
if [[ ! -f "${PLT_SRC}" || ! -f "${LAY_SRC}" || ! -f "${PAL_SRC}" ]]; then
    echo "[semterm-m3-confine] FAIL - one of the R41.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_plt_buf'      'core/semterm/plot.o'
ec_confine_one '_plt_state'    'core/semterm/plot.o'
ec_confine_one '_lay_arena'    'core/semterm/layout.o'
ec_confine_one '_lay_state'    'core/semterm/layout.o'
ec_confine_one '_pal_default'  'core/semterm/palette.o'
ec_confine_one '_pal_ansi_fg'  'core/semterm/palette.o'
ec_confine_one '_pal_ansi_bg'  'core/semterm/palette.o'
ec_confine_one '_pal_series'   'core/semterm/palette.o'
ec_confine_one '_pal_state'    'core/semterm/palette.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/plot.pdx §2, layout.pdx §2, and" >&2
    echo "  palette.pdx §3 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-m3-confine] R41.M3 (plot + layout + palette) state confined"

# ARITY PINS for the M3 entry points. Same rationale as the M1/M2 pins
# above: a widening on any of these makes "paint a cell the compositor
# never authored", "carve a pane the layout never allocated", or
# "resolve an SGR ordinal the palette never installed" expressible in
# a call site the confinement gate cannot see.
semterm_pin_one "${PLT_SRC}" 'pub let plt_put : (u64, u64, u64, u64) -> u64'
semterm_pin_one "${PLT_SRC}" 'pub let plt_get : (u64, u64) -> u64'
semterm_pin_one "${PLT_SRC}" 'pub let plt_bar : (u64, u64, u64) -> u64'
semterm_pin_one "${PLT_SRC}" 'pub let plt_line : (u64, u64, u64) -> u64'
semterm_pin_one "${PLT_SRC}" 'pub let plt_dot : (u64, u64) -> u64'
semterm_pin_one "${PLT_SRC}" 'pub let plt_heatmap : (u64, u64, u64) -> u64'
semterm_pin_one "${PLT_SRC}" 'pub let plt_sparkline : (u64, u64, u64) -> u64'
semterm_pin_one "${LAY_SRC}" 'pub let lay_root : (u64, u64) -> u64'
semterm_pin_one "${LAY_SRC}" 'pub let lay_split_h : (u64, u64, u64) -> u64'
semterm_pin_one "${LAY_SRC}" 'pub let lay_split_v : (u64, u64, u64) -> u64'
semterm_pin_one "${LAY_SRC}" 'pub let lay_pane_r0 : (u64) -> u64'
semterm_pin_one "${LAY_SRC}" 'pub let lay_pane_c0 : (u64) -> u64'
semterm_pin_one "${LAY_SRC}" 'pub let lay_pane_rows : (u64) -> u64'
semterm_pin_one "${LAY_SRC}" 'pub let lay_pane_cols : (u64) -> u64'
semterm_pin_one "${PAL_SRC}" 'pub let pal_default_rgb : (u64) -> u64'
semterm_pin_one "${PAL_SRC}" 'pub let pal_ansi_fg : (u64) -> u64'
semterm_pin_one "${PAL_SRC}" 'pub let pal_ansi_bg : (u64) -> u64'
semterm_pin_one "${PAL_SRC}" 'pub let pal_series_color : (u64) -> u64'
semterm_pin_one "${PAL_SRC}" 'pub let pal_extended : (u64) -> u64'
echo "[semterm-m3-confine] plot / layout / palette entry-point arities pinned"

# ---------------------------------------------------------------------------
# R41.M4-001/002/003 (#1374/#1375/#1376): SEMTERM FRAMEBUFFER FRONTEND
# CONFINEMENT.
#
# Three modules open R41.M4 on top of the R41.M3 chart-composition layer:
# fb_frontend (cursor + render-prepare + synthetic HID input queue),
# line_editor (readline-analog insertion buffer + kill/yank + 32-slot
# history + completion hook), and pager (page arithmetic + navigation +
# search hook). Each owns its own state cells; a second writer against
# any of them would let a caller:
#   - park the terminal cursor at a coordinate sfb_cursor_set never
#     stored (fb_frontend confinement), so a downstream blitter would
#     draw a cursor overlay the frontend never authorised,
#   - insert a byte into the line buffer without going through
#     led_insert (line_editor confinement), skipping the printable-ASCII
#     check that keeps control bytes off the visible line,
#   - forge the pager's current_page or quit flag (pager confinement)
#     so a downstream formatter walks rs_get against a range the pager
#     never navigated to.
SFB_SRC="${REPO_ROOT}/src/kernel/core/semterm/fb_frontend.pdx"
LED_SRC="${REPO_ROOT}/src/kernel/core/semterm/line_editor.pdx"
PGR_SRC="${REPO_ROOT}/src/kernel/core/semterm/pager.pdx"
if [[ ! -f "${SFB_SRC}" || ! -f "${LED_SRC}" || ! -f "${PGR_SRC}" ]]; then
    echo "[semterm-m4-confine] FAIL - one of the R41.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_sfb_state'       'core/semterm/fb_frontend.o'
ec_confine_one '_sfb_input_q'     'core/semterm/fb_frontend.o'
ec_confine_one '_led_buf'         'core/semterm/line_editor.o'
ec_confine_one '_led_kill'        'core/semterm/line_editor.o'
ec_confine_one '_led_hist'        'core/semterm/line_editor.o'
ec_confine_one '_led_hist_lens'   'core/semterm/line_editor.o'
ec_confine_one '_led_state'       'core/semterm/line_editor.o'
ec_confine_one '_pgr_state'       'core/semterm/pager.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/fb_frontend.pdx §2, line_editor.pdx §3," >&2
    echo "  and pager.pdx §2 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-m4-confine] R41.M4 (fb_frontend + line_editor + pager) state confined"

# ARITY PINS for the M4 entry points. Same rationale as the M3 pins
# above: a widening on any of these makes "park a cursor coordinate
# never authored", "smuggle a control byte through led_insert", or
# "reach a page pgr_next_page never advanced to" expressible in a call
# site the confinement gate cannot see.
semterm_pin_one "${SFB_SRC}" 'pub let sfb_cursor_set : (u64, u64) -> u64'
semterm_pin_one "${SFB_SRC}" 'pub let sfb_cursor_style_set : (u64) -> u64'
semterm_pin_one "${SFB_SRC}" 'pub let sfb_render_prepare : (u64, u64) -> u64'
semterm_pin_one "${SFB_SRC}" 'pub let sfb_input_push : (u64) -> u64'
semterm_pin_one "${SFB_SRC}" 'pub let sfb_input_pop : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_insert : (u64) -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_backspace : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_delete : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_left : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_right : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_home : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_end : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_kill_line : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_yank : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_history_push : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_history_up : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_history_down : () -> u64'
semterm_pin_one "${LED_SRC}" 'pub let led_get_at : (u64) -> u64'
semterm_pin_one "${PGR_SRC}" 'pub let pgr_open : (u64, u64) -> u64'
semterm_pin_one "${PGR_SRC}" 'pub let pgr_next_page : () -> u64'
semterm_pin_one "${PGR_SRC}" 'pub let pgr_prev_page : () -> u64'
semterm_pin_one "${PGR_SRC}" 'pub let pgr_quit : () -> u64'
semterm_pin_one "${PGR_SRC}" 'pub let pgr_search_set : (u64) -> u64'
semterm_pin_one "${PGR_SRC}" 'pub let pgr_page_start : () -> u64'
semterm_pin_one "${PGR_SRC}" 'pub let pgr_page_end : () -> u64'
echo "[semterm-m4-confine] fb_frontend / line_editor / pager entry-point arities pinned"

# ---------------------------------------------------------------------------
# R41.M5-001/002 (#1377/#1378): SEMTERM RECOVERY + SESSION LOG
# CONFINEMENT.
#
# Two modules close R41 on top of the R41.M4 framebuffer frontend:
# recovery (armed flag + safectl (KIND, cap-slot) bind + RO-by-default
# verb union) and session_log (per-attach session id + 64-slot
# execution ring + audit-forward honesty pin). Each owns its own
# state cells; a second writer against any of them would let a caller:
#   - forge the recovery armed flag or the safectl bind (recovery
#     confinement) so a downstream verb dispatcher walks against a
#     safectl channel the boot cmdline never authorised,
#   - park the recovery ro flag at 0 (recovery confinement) so an
#     UPDATE_* verb sneaks through the RO default without the widening
#     ceremony rec_set_ro(0) records,
#   - append a session_log record with an active_session_id the
#     attach path never issued (session_log confinement) so a
#     downstream audit forwarder emits an event attributed to a
#     session that never existed.
REC_SRC="${REPO_ROOT}/src/kernel/core/semterm/recovery.pdx"
SLOG_SRC="${REPO_ROOT}/src/kernel/core/semterm/session_log.pdx"
if [[ ! -f "${REC_SRC}" || ! -f "${SLOG_SRC}" ]]; then
    echo "[semterm-m5-confine] FAIL - one of the R41.M5 source files missing" >&2
    exit 1
fi
ec_confine_one '_rec_state'   'core/semterm/recovery.o'
ec_confine_one '_slog_state'  'core/semterm/session_log.o'
ec_confine_one '_slog_ring'   'core/semterm/session_log.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/recovery.pdx §2 and session_log.pdx §3" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-m5-confine] R41.M5 (recovery + session_log) state confined"

# ARITY PINS for the M5 entry points. Same rationale as the M4 pins
# above: a widening on any of these makes "arm recovery without a
# cmdline parser", "widen ro without the ceremony", "record a session
# id the attach path never issued", or "read a field the packer never
# produced" expressible in a call site the confinement gate cannot see.
semterm_pin_one "${REC_SRC}"  'pub let rec_arm : () -> u64'
semterm_pin_one "${REC_SRC}"  'pub let rec_safectl_bind : (u64, u64) -> u64'
semterm_pin_one "${REC_SRC}"  'pub let rec_set_ro : (u64) -> u64'
semterm_pin_one "${REC_SRC}"  'pub let rec_verb : (u64) -> u64'
semterm_pin_one "${SLOG_SRC}" 'pub let slog_attach : () -> u64'
semterm_pin_one "${SLOG_SRC}" 'pub let slog_detach : () -> u64'
semterm_pin_one "${SLOG_SRC}" 'pub let slog_record : (u64, u64, u64) -> u64'
semterm_pin_one "${SLOG_SRC}" 'pub let slog_get : (u64, u64) -> u64'
semterm_pin_one "${SLOG_SRC}" 'pub let slog_audit_forward : () -> u64'
echo "[semterm-m5-confine] recovery / session_log entry-point arities pinned"

# ---------------------------------------------------------------------------
# R42.M1-001..004 (#1380..#1383): PDXFS-v1 CoW WALKER CONFINEMENT.
#
# Four modules deliver the PdxFS-v1 copy-on-write skeleton:
#   refcount.pdx  -- per-block 16-bit reference count table + counters.
#   cow_read.pdx  -- snapshot-chain walk log + direct-mapped LBA cache.
#   cow_write.pdx -- physical block payload store + bump allocator +
#                    SHARED/UNIQUE write dispatch.
#   cow_gc.pdx    -- free list + scan/release with duplicate suppression.
#
# Each owns its own state cells; a second writer against any of them would
# let a caller:
#   - forge a refcount cell (refcount confinement) so a SHARED-vs-UNIQUE
#     dispatch in cow_write picks the wrong branch, silently overwriting
#     a snapshot's block in place,
#   - append a chain entry (cow_read confinement) so pxcr_read returns
#     a phys_blk cow_write never allocated,
#   - bump next_free_block (cow_write confinement) so pxcw_alloc_block
#     hands out a block the free list also parks,
#   - grow free_head (cow_gc confinement) so pxgc_free_at returns a
#     block id that was never actually released.
PXRC_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/refcount.pdx"
PXCR_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/cow_read.pdx"
PXCW_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/cow_write.pdx"
PXGC_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/cow_gc.pdx"
if [[ ! -f "${PXRC_SRC}" || ! -f "${PXCR_SRC}" || ! -f "${PXCW_SRC}" || ! -f "${PXGC_SRC}" ]]; then
    echo "[pdxfs-cow-confine] FAIL - one of the R42.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_pxrc_tab'        'core/fs/pdxfs/refcount.o'
ec_confine_one '_pxrc_state'      'core/fs/pdxfs/refcount.o'
ec_confine_one '_pxcr_chain'      'core/fs/pdxfs/cow_read.o'
ec_confine_one '_pxcr_cache'      'core/fs/pdxfs/cow_read.o'
ec_confine_one '_pxcr_state'      'core/fs/pdxfs/cow_read.o'
ec_confine_one '_pxcw_blocks'     'core/fs/pdxfs/cow_write.o'
ec_confine_one '_pxcw_state'      'core/fs/pdxfs/cow_write.o'
ec_confine_one '_pxgc_free_list'  'core/fs/pdxfs/cow_gc.o'
ec_confine_one '_pxgc_state'      'core/fs/pdxfs/cow_gc.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/fs/pdxfs/{refcount,cow_read,cow_write,cow_gc}.pdx §2" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[pdxfs-cow-confine] R42.M1 (refcount + cow_read + cow_write + cow_gc) state confined"

# ARITY PINS for the R42.M1 entry points. Same rationale as R41.M5:
# a widening on any of these makes "bump a refcount without recording
# the inc", "map an lba across the wrong snapshot", "write past a
# READ_MISS", or "park a block already on the free list" expressible
# in a call site the confinement gate cannot see.
semterm_pin_one "${PXRC_SRC}" 'pub let pxrc_get : (u64) -> u64'
semterm_pin_one "${PXRC_SRC}" 'pub let pxrc_inc : (u64) -> u64'
semterm_pin_one "${PXRC_SRC}" 'pub let pxrc_dec : (u64) -> u64'
semterm_pin_one "${PXRC_SRC}" 'pub let pxrc_zero_count : () -> u64'
semterm_pin_one "${PXRC_SRC}" 'pub let pxrc_release_zero_blocks : () -> u64'
semterm_pin_one "${PXCR_SRC}" 'pub let pxcr_snapshot_push : () -> u64'
semterm_pin_one "${PXCR_SRC}" 'pub let pxcr_snapshot_map : (u64, u64, u64) -> u64'
semterm_pin_one "${PXCR_SRC}" 'pub let pxcr_read : (u64) -> u64'
semterm_pin_one "${PXCR_SRC}" 'pub let pxcr_cache_get : (u64) -> u64'
semterm_pin_one "${PXCW_SRC}" 'pub let pxcw_alloc_block : () -> u64'
semterm_pin_one "${PXCW_SRC}" 'pub let pxcw_write : (u64, u64, u64) -> u64'
semterm_pin_one "${PXCW_SRC}" 'pub let pxcw_block_read : (u64) -> u64'
semterm_pin_one "${PXGC_SRC}" 'pub let pxgc_scan : () -> u64'
semterm_pin_one "${PXGC_SRC}" 'pub let pxgc_release : () -> u64'
semterm_pin_one "${PXGC_SRC}" 'pub let pxgc_free_at : (u64) -> u64'
echo "[pdxfs-cow-confine] R42.M1 entry-point arities pinned"

# ---------------------------------------------------------------------------
# R42.M2-001..004 (#1384..#1387): PDXFS-v1 JOURNAL CONFINEMENT.
#
# Four modules deliver the PdxFS-v1 journal skeleton above the R42.M1
# CoW walker:
#   wal.pdx            -- ring buffer of tx records + write-ahead
#                          invariant refusal on wal_block_write before
#                          the covering wal_fsync.
#   journal_fence.pdx  -- commit table naming WAL seqs; refuses commit
#                          without a preceding fence (no-fence) and
#                          duplicate commits (already).
#   journal_replay.pdx -- mount-time classification of WAL records into
#                          APPLIED/DISCARDED via jfn_is_committed.
#   journal_csum.pdx   -- CRC32C-style expected table + tear-detection
#                          refusal on jcs_check_replay_eligible.
#
# Each owns its own state cells. A second writer against any of them
# would let a caller:
#   - stuff a WAL record without observing the fsync gate (wal
#     confinement), which would silently break the write-ahead
#     invariant every callee below assumes,
#   - plant a commit marker without the fence pair (journal_fence
#     confinement), which would let a crash-window tx graduate to
#     APPLIED at replay time with no barrier having actually run,
#   - flip a classification back to APPLIED after the fence table
#     said otherwise (journal_replay confinement), which would let
#     the mount path re-apply uncommitted block writes,
#   - quiet a torn record by planting a matching expected checksum
#     (journal_csum confinement), which would smuggle a torn block
#     past the tear-detection refusal.
WAL_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/wal.pdx"
JFN_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/journal_fence.pdx"
JRP_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/journal_replay.pdx"
JCS_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/journal_csum.pdx"
if [[ ! -f "${WAL_SRC}" || ! -f "${JFN_SRC}" || ! -f "${JRP_SRC}" || ! -f "${JCS_SRC}" ]]; then
    echo "[pdxfs-journal-confine] FAIL - one of the R42.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_wal_ring'         'core/fs/pdxfs/wal.o'
ec_confine_one '_wal_state'        'core/fs/pdxfs/wal.o'
ec_confine_one '_jfn_commits'      'core/fs/pdxfs/journal_fence.o'
ec_confine_one '_jfn_state'        'core/fs/pdxfs/journal_fence.o'
ec_confine_one '_jrp_state_at'     'core/fs/pdxfs/journal_replay.o'
ec_confine_one '_jrp_state'        'core/fs/pdxfs/journal_replay.o'
ec_confine_one '_jcs_expected'     'core/fs/pdxfs/journal_csum.o'
ec_confine_one '_jcs_state'        'core/fs/pdxfs/journal_csum.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/fs/pdxfs/{wal,journal_fence,journal_replay,journal_csum}.pdx §2" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[pdxfs-journal-confine] R42.M2 (wal + journal_fence + journal_replay + journal_csum) state confined"

# ARITY PINS for the R42.M2 entry points. Same rationale as R42.M1:
# a widening on any of these makes "append without observing the
# gate", "commit without a fence covering the tx", "reclassify a
# record without consulting the commit table", or "verify without
# recompute" expressible in a call site the confinement gate
# cannot see.
semterm_pin_one "${WAL_SRC}" 'pub let wal_append : (u64, u64) -> u64'
semterm_pin_one "${WAL_SRC}" 'pub let wal_fsync : () -> u64'
semterm_pin_one "${WAL_SRC}" 'pub let wal_block_write : (u64) -> u64'
semterm_pin_one "${WAL_SRC}" 'pub let wal_seq_at : (u64) -> u64'
semterm_pin_one "${WAL_SRC}" 'pub let wal_checksum_at : (u64) -> u64'
semterm_pin_one "${JFN_SRC}" 'pub let jfn_fence : () -> u64'
semterm_pin_one "${JFN_SRC}" 'pub let jfn_commit : (u64) -> u64'
semterm_pin_one "${JFN_SRC}" 'pub let jfn_is_committed : (u64) -> u64'
semterm_pin_one "${JFN_SRC}" 'pub let jfn_commit_seq_at : (u64) -> u64'
semterm_pin_one "${JRP_SRC}" 'pub let jrp_scan_from : (u64) -> u64'
semterm_pin_one "${JRP_SRC}" 'pub let jrp_replay : (u64) -> u64'
semterm_pin_one "${JRP_SRC}" 'pub let jrp_state_at : (u64) -> u64'
semterm_pin_one "${JCS_SRC}" 'pub let jcs_recompute : () -> u64'
semterm_pin_one "${JCS_SRC}" 'pub let jcs_verify : (u64) -> u64'
semterm_pin_one "${JCS_SRC}" 'pub let jcs_check_replay_eligible : (u64) -> u64'
semterm_pin_one "${JCS_SRC}" 'pub let jcs_seed_torn : (u64) -> u64'
echo "[pdxfs-journal-confine] R42.M2 entry-point arities pinned"

# ---------------------------------------------------------------------------
# R42.M3-001 .. R42.M3-004 (#1388..#1391): PDXFS-v1 SNAPSHOT confinement.
#
# Four modules build the snapshot skeleton the eventual NVMe write path
# (#906) will persist:
#
#   snap_create.pdx     -- name registry + chain-head bump + scaffold
#                          refbump accounting.
#   snap_mount_ro.pdx   -- name-resolved mounts + read-only latch;
#                          write_refuse is the ONE path a write against
#                          a mounted snapshot lands on.
#   snap_diff.pdx       -- bounded per-block diff walker between two
#                          snapshots.
#   snap_prune.pdx      -- retention policy + delete pass + scaffold
#                          refdec accounting.
#
# The confinement gate below is why a widening cannot:
#   - install a name without an atomic snc_create (snap_create
#     confinement), which would let a downstream mount bind to a
#     snapshot the chain-head bump never happened for,
#   - install a mount without name resolution (snap_mount_ro
#     confinement), which would let the read path resolve to a slot
#     whose name the SnapCreate registry never blessed,
#   - quiet a difference by planting a matching result entry
#     (snap_diff confinement), which would smuggle a stale block past
#     a downstream consumer that trusted the diff walker,
#   - quiet a retention decision by planting a matching ts
#     (snap_prune confinement), which would preserve a snapshot the
#     policy would otherwise have deleted.
SNC_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/snap_create.pdx"
SNR_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/snap_mount_ro.pdx"
SND_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/snap_diff.pdx"
SNP_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/snap_prune.pdx"
if [[ ! -f "${SNC_SRC}" || ! -f "${SNR_SRC}" || ! -f "${SND_SRC}" || ! -f "${SNP_SRC}" ]]; then
    echo "[pdxfs-snap-confine] FAIL - one of the R42.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_snc_names'   'core/fs/pdxfs/snap_create.o'
ec_confine_one '_snc_state'   'core/fs/pdxfs/snap_create.o'
ec_confine_one '_snr_slots'   'core/fs/pdxfs/snap_mount_ro.o'
ec_confine_one '_snr_state'   'core/fs/pdxfs/snap_mount_ro.o'
ec_confine_one '_snd_blocks'  'core/fs/pdxfs/snap_diff.o'
ec_confine_one '_snd_result'  'core/fs/pdxfs/snap_diff.o'
ec_confine_one '_snd_state'   'core/fs/pdxfs/snap_diff.o'
ec_confine_one '_snp_ts'      'core/fs/pdxfs/snap_prune.o'
ec_confine_one '_snp_state'   'core/fs/pdxfs/snap_prune.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/fs/pdxfs/{snap_create,snap_mount_ro,snap_diff,snap_prune}.pdx §2" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[pdxfs-snap-confine] R42.M3 (snap_create + snap_mount_ro + snap_diff + snap_prune) state confined"

# ARITY PINS for the R42.M3 entry points. A widening on any of these
# makes "install a name without an atomic create", "mount a snapshot
# with the wrong resolution semantics", "diff between the wrong pair
# of snapshots", or "prune under an unrecognised policy" expressible
# in a call site the confinement gate cannot see.
semterm_pin_one "${SNC_SRC}" 'pub let snc_create : (u64) -> u64'
semterm_pin_one "${SNC_SRC}" 'pub let snc_lookup : (u64) -> u64'
semterm_pin_one "${SNR_SRC}" 'pub let snr_mount : (u64) -> u64'
semterm_pin_one "${SNR_SRC}" 'pub let snr_unmount : (u64) -> u64'
semterm_pin_one "${SNR_SRC}" 'pub let snr_write_refuse : (u64) -> u64'
semterm_pin_one "${SND_SRC}" 'pub let snd_diff : (u64, u64, u64) -> u64'
semterm_pin_one "${SND_SRC}" 'pub let snd_seed : (u64, u64, u64) -> u64'
semterm_pin_one "${SNP_SRC}" 'pub let snp_set_policy : (u64, u64) -> u64'
semterm_pin_one "${SNP_SRC}" 'pub let snp_prune : () -> u64'
echo "[pdxfs-snap-confine] R42.M3 entry-point arities pinned"

# ---------------------------------------------------------------------------
# R42.M4-001 .. R42.M4-003 (#1392..#1394): PDXFS LITE -> V1 UPGRADE + COMPAT.
#
# Three modules complete the PdxFS v1 upgrade story:
#
#   upgrade_v1.pdx      -- in-place upgrade authority. The scaffold
#                          swaps the superblock magic + migrates the
#                          legacy inode + derives the CoW head in ONE
#                          call whose all-or-nothing property the on-
#                          disk widening preserves inside a journal
#                          transaction.
#   upgrade_dryrun.pdx  -- read-only walk that produces a report
#                          (blocks_before, blocks_after, free_delta,
#                          duration) so the caller can decide to
#                          commit without side effects.
#   lite_reader.pdx     -- read-only compat mode for legacy volumes:
#                          the ONE place a write attempt lands is
#                          lit_write_refuse, which returns LIT_ERR_
#                          ROFS unconditionally on a live mount.
#
# The confinement gate below is why a widening cannot:
#   - "flip the superblock magic to v1 without running the migration
#     step" (upgrade_v1 confinement), which would leave a downstream
#     v1 mount reading legacy inodes it never sanctioned,
#   - "quiet a dry-run report by planting matching numbers" (upgrade_
#     dryrun confinement), which would let a commit run against a
#     volume the pre-flight walk never actually approved,
#   - "mount a legacy volume in write mode by planting a mounted-latch
#     value the read API doesn't check" (lite_reader confinement),
#     which would defeat the whole read-only compat story.
UPG_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/upgrade_v1.pdx"
DRY_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/upgrade_dryrun.pdx"
LIT_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/lite_reader.pdx"
if [[ ! -f "${UPG_SRC}" || ! -f "${DRY_SRC}" || ! -f "${LIT_SRC}" ]]; then
    echo "[pdxfs-upg-confine] FAIL - one of the R42.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_upg_sb'      'core/fs/pdxfs/upgrade_v1.o'
ec_confine_one '_upg_state'   'core/fs/pdxfs/upgrade_v1.o'
ec_confine_one '_dry_src'     'core/fs/pdxfs/upgrade_dryrun.o'
ec_confine_one '_dry_state'   'core/fs/pdxfs/upgrade_dryrun.o'
ec_confine_one '_lit_blocks'  'core/fs/pdxfs/lite_reader.o'
ec_confine_one '_lit_sb'      'core/fs/pdxfs/lite_reader.o'
ec_confine_one '_lit_state'   'core/fs/pdxfs/lite_reader.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/fs/pdxfs/{upgrade_v1,upgrade_dryrun,lite_reader}.pdx §2" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[pdxfs-upg-confine] R42.M4 (upgrade_v1 + upgrade_dryrun + lite_reader) state confined"

# ARITY PINS for the R42.M4 entry points. A widening on any of these
# makes "upgrade under an unrecognised precondition set", "dry-run
# against a volume the caller doesn't own", or "read past the block
# capacity without a bounds refusal" expressible in a call site the
# confinement gate cannot see.
semterm_pin_one "${UPG_SRC}" 'pub let upg_upgrade : () -> u64'
semterm_pin_one "${UPG_SRC}" 'pub let upg_seed_lite : (u64, u64) -> u64'
semterm_pin_one "${UPG_SRC}" 'pub let upg_set_journal : (u64) -> u64'
semterm_pin_one "${DRY_SRC}" 'pub let dry_walk : () -> u64'
semterm_pin_one "${DRY_SRC}" 'pub let dry_seed : (u64, u64) -> u64'
semterm_pin_one "${LIT_SRC}" 'pub let lit_mount : () -> u64'
semterm_pin_one "${LIT_SRC}" 'pub let lit_unmount : () -> u64'
semterm_pin_one "${LIT_SRC}" 'pub let lit_read : (u64) -> u64'
semterm_pin_one "${LIT_SRC}" 'pub let lit_write_refuse : (u64, u64) -> u64'
echo "[pdxfs-upg-confine] R42.M4 entry-point arities pinned"

# ---------------------------------------------------------------------------
# R42.M4-004 (#1395) + R42.M5-001 (#1396) + R42.M5-002 (#1397): the R42
# PDXFS v1 closing quartet's STATE + ARITY confinement.
#
#   fs_channel.pdx     -- the RPC schema. No state cells; the confinement
#                         is arity-only: a widening that adds a fifth
#                         parameter to a packer is how a caller-supplied
#                         ceiling reaches the wire.
#   nvme_write.pdx     -- the FS-side batcher. _nvw_sq is the SQ (64
#                         entries * 4 u64), _nvw_state is the counter
#                         block. A second writer would let a caller
#                         "acknowledge a completion for a cid the CoW
#                         walker never submitted" (which would leave the
#                         block-layout bookkeeping ahead of what the
#                         device holds), or "resize the SQ under a live
#                         batch" (which would truncate pending entries
#                         no caller re-enqueued).
#   durability.pdx     -- the fsync + barrier sequencer. _dur_lvl is
#                         the per-fd level table, _dur_state the
#                         counters. A second writer would let a caller
#                         "downgrade an fd's level from SYNC to NONE
#                         without going through dur_set_level", losing
#                         a durability guarantee on a crash.
FSC_SRC="${REPO_ROOT}/src/kernel/core/ipc/fs_channel.pdx"
NVW_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/nvme_write.pdx"
DUR_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/durability.pdx"
if [[ ! -f "${FSC_SRC}" || ! -f "${NVW_SRC}" || ! -f "${DUR_SRC}" ]]; then
    echo "[pdxfs-r42-close-confine] FAIL - one of the R42-close source files missing" >&2
    exit 1
fi
ec_confine_one '_nvw_sq'      'core/fs/pdxfs/nvme_write.o'
ec_confine_one '_nvw_state'   'core/fs/pdxfs/nvme_write.o'
ec_confine_one '_dur_lvl'     'core/fs/pdxfs/durability.o'
ec_confine_one '_dur_state'   'core/fs/pdxfs/durability.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/fs/pdxfs/{nvme_write,durability}.pdx §2/§3" >&2
    echo "  for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[pdxfs-r42-close-confine] R42 (fs_channel + nvme_write + durability) state confined"

# ARITY PINS for the R42-close entry points. A widening on any of these
# makes "smuggle a ceiling into the schema", "acknowledge a completion
# for a cid the walker never named", or "set a per-fd level with the
# level in the fd position" expressible in a call site the confinement
# gate cannot see.
semterm_pin_one "${FSC_SRC}" 'pub let fsc_pack_open_request : (u64, u64) -> u64'
semterm_pin_one "${FSC_SRC}" 'pub let fsc_pack_open_reply : (u64) -> u64'
semterm_pin_one "${FSC_SRC}" 'pub let fsc_pack_fd_len : (u64, u64) -> u64'
semterm_pin_one "${FSC_SRC}" 'pub let fsc_pack_path : (u64) -> u64'
semterm_pin_one "${FSC_SRC}" 'pub let fsc_pack_two_paths : (u64, u64) -> u64'
semterm_pin_one "${FSC_SRC}" 'pub let fsc_pack_stat_reply : (u64, u64) -> u64'
semterm_pin_one "${NVW_SRC}" 'pub let nvw_submit : (u64, u64) -> u64'
semterm_pin_one "${NVW_SRC}" 'pub let nvw_batch_flush : () -> u64'
semterm_pin_one "${NVW_SRC}" 'pub let nvw_completion : (u64) -> u64'
semterm_pin_one "${DUR_SRC}" 'pub let dur_set_level : (u64, u64) -> u64'
semterm_pin_one "${DUR_SRC}" 'pub let dur_fsync : (u64) -> u64'
semterm_pin_one "${DUR_SRC}" 'pub let dur_barrier : (u64) -> u64'
echo "[pdxfs-r42-close-confine] R42-close entry-point arities pinned"

# ---------------------------------------------------------------------------
# R44.M1-001/002/003 (#1400/#1401/#1402): SEMTERM GUI SHELL CONFINEMENT.
#
# Three modules open R44.M1 on top of the R41.M1..M2 semantic-term core:
# gui_shell (window shell + four named regions + input event queue),
# gui_layout (up to 8 tabs, up to 16 panes, nested H/V splits, focus
# routing), and gui_theme (theme + font + size registry with a
# session_log-forward persist counter). Each owns its own state cells;
# a second writer against any of them would let a caller:
#   - park focus on a region gsh_focus_set never authorised
#     (gui_shell confinement), so a downstream event pump would
#     deliver to a region the shell never blessed,
#   - forge a pane's kind field (gui_layout confinement), turning a
#     structural SPLIT into a LEAF the focus router walks into, or
#     shifting pane_alloc_next so gly_pane_split hands out a slot
#     another tab already owns,
#   - forge the theme_id / font_id / font_size fields (gui_theme
#     confinement), so a downstream renderer paints against a
#     configuration no setter ever validated -- bypassing the
#     GTH_ERR_BAD_THEME / _BAD_FONT / _BAD_SIZE refusal band.
GSH_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_shell.pdx"
GLY_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_layout.pdx"
GTH_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_theme.pdx"
if [[ ! -f "${GSH_SRC}" || ! -f "${GLY_SRC}" || ! -f "${GTH_SRC}" ]]; then
    echo "[semterm-r44-confine] FAIL - one of the R44.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_gsh_state'   'core/semterm/gui_shell.o'
ec_confine_one '_gsh_regions' 'core/semterm/gui_shell.o'
ec_confine_one '_gsh_event_q' 'core/semterm/gui_shell.o'
ec_confine_one '_gly_state'   'core/semterm/gui_layout.o'
ec_confine_one '_gly_tabs'    'core/semterm/gui_layout.o'
ec_confine_one '_gly_panes'   'core/semterm/gui_layout.o'
ec_confine_one '_gth_state'   'core/semterm/gui_theme.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/gui_shell.pdx §3, gui_layout.pdx §2," >&2
    echo "  and gui_theme.pdx §3 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-r44-confine] R44.M1 (gui_shell + gui_layout + gui_theme) state confined"

# ARITY PINS for the R44.M1 entry points. Same rationale as the R41
# pins above: a widening on any of these makes "park focus on a
# region no setter authored", "smuggle a session_hash into a pane
# gly_pane_split never populated", or "install a theme the enum
# check never blessed" expressible in a call site the confinement
# gate cannot see.
semterm_pin_one "${GSH_SRC}" 'pub let gsh_region_set : (u64, u64, u64, u64, u64) -> u64'
semterm_pin_one "${GSH_SRC}" 'pub let gsh_region_show : (u64, u64) -> u64'
semterm_pin_one "${GSH_SRC}" 'pub let gsh_focus_set : (u64) -> u64'
semterm_pin_one "${GSH_SRC}" 'pub let gsh_event_push : (u64, u64) -> u64'
semterm_pin_one "${GSH_SRC}" 'pub let gsh_event_pump : () -> u64'
semterm_pin_one "${GSH_SRC}" 'pub let gsh_region_get : (u64, u64) -> u64'
semterm_pin_one "${GLY_SRC}" 'pub let gly_tab_new : (u64) -> u64'
semterm_pin_one "${GLY_SRC}" 'pub let gly_tab_active_set : (u64) -> u64'
semterm_pin_one "${GLY_SRC}" 'pub let gly_pane_split : (u64, u64) -> u64'
semterm_pin_one "${GLY_SRC}" 'pub let gly_pane_kind : (u64) -> u64'
semterm_pin_one "${GLY_SRC}" 'pub let gly_pane_field : (u64, u64) -> u64'
semterm_pin_one "${GLY_SRC}" 'pub let gly_focus_set : (u64) -> u64'
semterm_pin_one "${GLY_SRC}" 'pub let gly_focus_next : () -> u64'
semterm_pin_one "${GTH_SRC}" 'pub let gth_theme_set : (u64) -> u64'
semterm_pin_one "${GTH_SRC}" 'pub let gth_font_set : (u64) -> u64'
semterm_pin_one "${GTH_SRC}" 'pub let gth_font_size_set : (u64) -> u64'
semterm_pin_one "${GTH_SRC}" 'pub let gth_persist_flush : () -> u64'
echo "[semterm-r44-confine] gui_shell / gui_layout / gui_theme entry-point arities pinned"

# ---------------------------------------------------------------------------
# R44.M2-001/002/003 (#1403/#1404/#1405): SEMTERM GUI VELLO / CHARTS /
# SCROLL CONFINEMENT.
#
# Three modules open R44.M2 on top of the R44.M1 GUI scaffold: gui_vello
# (four-layer scene composition + subpixel-aware glyph atlas + result-
# route flow), gui_charts (bar/line/scatter/heatmap chart records +
# palette-series bindings + stroke attributes + emit_path counters),
# and gui_scroll (Q22.10 sub-pixel offset + ease-out cubic animation +
# reproject_glyph). Each owns its own state cells; a second writer
# against any of them would let a caller:
#   - forge a layer's visibility or opacity (gui_vello confinement),
#     so a downstream compositor paints against a scene no setter
#     ever validated -- bypassing the VEL_ERR_BAD_OPACITY refusal
#     band -- or bump result_pending outside of vel_route_result,
#     letting vel_submit_frame flush a stale row_count;
#   - forge a chart's kind or rectangle (gui_charts confinement),
#     turning a HEATMAP record into a BAR one the emitter walks with
#     the wrong glyph primitive, or shift chart_count so cha_chart_new
#     hands out a slot cha_series_add already references;
#   - forge the scroll offset or animation cursors (gui_scroll
#     confinement), so scr_reproject_glyph reports a position the
#     animation curve never computed -- bypassing the ease-out
#     guarantee that keeps glyphs stable across frames.
GVL_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_vello.pdx"
GCH_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_charts.pdx"
GSC_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_scroll.pdx"
if [[ ! -f "${GVL_SRC}" || ! -f "${GCH_SRC}" || ! -f "${GSC_SRC}" ]]; then
    echo "[semterm-r44m2-confine] FAIL - one of the R44.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_vel_state'   'core/semterm/gui_vello.o'
ec_confine_one '_vel_layers'  'core/semterm/gui_vello.o'
ec_confine_one '_vel_atlas'   'core/semterm/gui_vello.o'
ec_confine_one '_cha_state'   'core/semterm/gui_charts.o'
ec_confine_one '_cha_charts'  'core/semterm/gui_charts.o'
ec_confine_one '_cha_series'  'core/semterm/gui_charts.o'
ec_confine_one '_scr_state'   'core/semterm/gui_scroll.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/gui_vello.pdx §4, gui_charts.pdx §3," >&2
    echo "  and gui_scroll.pdx §3 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-r44m2-confine] R44.M2 (gui_vello + gui_charts + gui_scroll) state confined"

# ARITY PINS for the R44.M2 entry points. Same rationale as the R41 /
# R44.M1 pins above: a widening on any of these makes "flush a frame
# no resultset routed", "smuggle a stroke config into a chart record
# the setter never validated", or "animate to an offset the ease-out
# curve never computed" expressible in a call site the confinement
# gate cannot see.
semterm_pin_one "${GVL_SRC}" 'pub let vel_layer_show : (u64, u64) -> u64'
semterm_pin_one "${GVL_SRC}" 'pub let vel_layer_set_opacity : (u64, u64) -> u64'
semterm_pin_one "${GVL_SRC}" 'pub let vel_layer_visible : (u64) -> u64'
semterm_pin_one "${GVL_SRC}" 'pub let vel_layer_opacity : (u64) -> u64'
semterm_pin_one "${GVL_SRC}" 'pub let vel_subpx_set : (u64) -> u64'
semterm_pin_one "${GVL_SRC}" 'pub let vel_atlas_add_glyph : (u64) -> u64'
semterm_pin_one "${GVL_SRC}" 'pub let vel_atlas_glyph_at : (u64) -> u64'
semterm_pin_one "${GVL_SRC}" 'pub let vel_route_result : (u64) -> u64'
semterm_pin_one "${GVL_SRC}" 'pub let vel_submit_frame : () -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_chart_new : (u64, u64, u64, u64, u64) -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_chart_field : (u64, u64) -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_series_add : (u64, u64) -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_series_chart : (u64) -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_series_palette : (u64) -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_aa_set : (u64) -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_cap_set : (u64) -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_join_set : (u64) -> u64'
semterm_pin_one "${GCH_SRC}" 'pub let cha_emit_path : (u64) -> u64'
semterm_pin_one "${GSC_SRC}" 'pub let scr_viewport_set : (u64) -> u64'
semterm_pin_one "${GSC_SRC}" 'pub let scr_content_set : (u64) -> u64'
semterm_pin_one "${GSC_SRC}" 'pub let scr_scroll_to : (u64, u64) -> u64'
semterm_pin_one "${GSC_SRC}" 'pub let scr_animate_step : (u64) -> u64'
semterm_pin_one "${GSC_SRC}" 'pub let scr_reproject_glyph : (u64) -> u64'
echo "[semterm-r44m2-confine] gui_vello / gui_charts / gui_scroll entry-point arities pinned"

# ---------------------------------------------------------------------------
# R44.M3-001/002/003 (#1406/#1407/#1408): SEMTERM GUI IME / A11Y /
# KBDNAV CONFINEMENT.
#
# Three modules close the R44.M3 accessibility axis on top of the
# R44.M2 rendering seams: gui_ime (G11 IME binding -- composing code
# points route into a bounded pre-edit buffer, ime_commit moves the
# run into a committed counter and bumps a notify_pending flag the
# editor pump drains), gui_a11y (G10 accessibility tree -- rooted
# node pool with role/name/value/parent/depth and a publish_pending
# counter the AT bridge drains) and gui_kbdnav (G10 keyboard
# navigation -- Tab / F6 focus routing, arrow-key within-panel
# navigation, focus-ring visibility flag, skip-link hits counter).
# Each owns its own state cells; a second writer against any of them
# would let a caller:
#   - forge the pre-edit buffer or commit counter (gui_ime
#     confinement), so a downstream editor pump reads a run the IME
#     never actually composed -- bypassing the NOTHING_TO_COMMIT
#     refusal -- or bump notify_pending outside of ime_commit,
#     letting the editor treat an empty pre-edit as a committed run;
#   - forge the a11y tree's node pool or root_installed flag
#     (gui_a11y confinement), so the AT bridge walks a forest or
#     encounters a node whose parent index dangles past node_count,
#     bypassing the HAS_ROOT / NO_ROOT / BAD_PARENT refusal band;
#   - forge the focus_panel / focus_widget / widgets_per_panel
#     entries (gui_kbdnav confinement), so the Vello backend paints
#     the focus ring on a widget the router never actually focused,
#     or divides by zero in the modular cycling arithmetic against a
#     zero-widget panel -- bypassing the BAD_COUNT refusal.
GIM_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_ime.pdx"
GAY_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_a11y.pdx"
GKN_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_kbdnav.pdx"
if [[ ! -f "${GIM_SRC}" || ! -f "${GAY_SRC}" || ! -f "${GKN_SRC}" ]]; then
    echo "[semterm-r44m3-confine] FAIL - one of the R44.M3 source files missing" >&2
    exit 1
fi
ec_confine_one '_ime_state'   'core/semterm/gui_ime.o'
ec_confine_one '_ime_preedit' 'core/semterm/gui_ime.o'
ec_confine_one '_a11_state'   'core/semterm/gui_a11y.o'
ec_confine_one '_a11_nodes'   'core/semterm/gui_a11y.o'
ec_confine_one '_knv_state'   'core/semterm/gui_kbdnav.o'
ec_confine_one '_knv_widgets' 'core/semterm/gui_kbdnav.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/gui_ime.pdx §3, gui_a11y.pdx §4," >&2
    echo "  and gui_kbdnav.pdx §5 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-r44m3-confine] R44.M3 (gui_ime + gui_a11y + gui_kbdnav) state confined"

# ARITY PINS for the R44.M3 entry points. Same rationale as the
# R41 / R44.M1 / R44.M2 pins above: a widening on any of these makes
# "smuggle an extra byte into a commit the IME never actually
# emitted", "graft a subtree under a parent id the caller minted from
# nowhere", or "advance focus without touching the panel counters"
# expressible in a call site the confinement gate cannot see.
semterm_pin_one "${GIM_SRC}" 'pub let ime_preedit_push : (u64) -> u64'
semterm_pin_one "${GIM_SRC}" 'pub let ime_preedit_pop : () -> u64'
semterm_pin_one "${GIM_SRC}" 'pub let ime_preedit_clear : () -> u64'
semterm_pin_one "${GIM_SRC}" 'pub let ime_preedit_at : (u64) -> u64'
semterm_pin_one "${GIM_SRC}" 'pub let ime_commit : () -> u64'
semterm_pin_one "${GIM_SRC}" 'pub let ime_notify_ack : () -> u64'
semterm_pin_one "${GAY_SRC}" 'pub let a11_root_add : (u64, u64, u64) -> u64'
semterm_pin_one "${GAY_SRC}" 'pub let a11_child_add : (u64, u64, u64, u64) -> u64'
semterm_pin_one "${GAY_SRC}" 'pub let a11_node_field : (u64, u64) -> u64'
semterm_pin_one "${GAY_SRC}" 'pub let a11_publish_flush : () -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_widgets_set : (u64, u64) -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_widgets_get : (u64) -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_ring_show : (u64) -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_next_widget : () -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_prev_widget : () -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_next_panel : () -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_prev_panel : () -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_arrow : (u64) -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_skip_link_next : () -> u64'
semterm_pin_one "${GKN_SRC}" 'pub let knv_skip_link_prev : () -> u64'
echo "[semterm-r44m3-confine] gui_ime / gui_a11y / gui_kbdnav entry-point arities pinned"

# ---------------------------------------------------------------------------
# R44.M4-001/002 (#1409/#1410): SEMTERM GUI HDR / FEEDBACK
# CONFINEMENT.
#
# Two modules close the R44.M4 milestone on top of the R44.M3
# accessibility seams: gui_hdr (routes a series index to a 24-bit
# RGB value picked from the BT.2020 wide-gamut palette when the
# bound R36 KIND_DISPLAY_OUTPUT reports HDR capability, otherwise
# defers to R41.M3 palette.pdx) and gui_feedback (subscribes to
# G9 KIND_PRESENT_FEEDBACK events, latches last_latency against a
# per-frame budget, and publishes two adaptive flags -- reduced-
# detail hint the chart engine reads and scroll-freeze hint the
# smooth-scroll integrator reads).
# Each owns its own state cells; a second writer against any of
# them would let a caller:
#   - forge the HDR-capability flag or the BT.2020 catalogue
#     (gui_hdr confinement), so hdr_pick_series returns colors from
#     the wrong catalogue for the bound display -- bypassing the
#     R36 supervisor's tone-mapping contract -- or scribble a
#     non-BT.2020 primary into the wide-gamut table, silently
#     collapsing the delta-E >= 15 floor;
#   - forge the last_latency scalar or the two adaptive flags
#     (gui_feedback confinement), so the chart engine reads a
#     reduced-detail hint the compositor never actually reported,
#     or the smooth-scroll integrator freezes on a frame that
#     landed under budget -- bypassing the BAD_TIME / NO_BUDGET
#     refusal band.
GHR_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_hdr.pdx"
GFB_SRC="${REPO_ROOT}/src/kernel/core/semterm/gui_feedback.pdx"
if [[ ! -f "${GHR_SRC}" || ! -f "${GFB_SRC}" ]]; then
    echo "[semterm-r44m4-confine] FAIL - one of the R44.M4 source files missing" >&2
    exit 1
fi
ec_confine_one '_hdr_state'         'core/semterm/gui_hdr.o'
ec_confine_one '_hdr_series_bt2020' 'core/semterm/gui_hdr.o'
ec_confine_one '_pfb_state'         'core/semterm/gui_feedback.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/semterm/gui_hdr.pdx §2 and" >&2
    echo "  gui_feedback.pdx §2 for the per-module one-writer discipline." >&2
    exit 1
fi
echo "[semterm-r44m4-confine] R44.M4 (gui_hdr + gui_feedback) state confined"

# ARITY PINS for the R44.M4 entry points. Same rationale as the
# R41 / R44.M1 / R44.M2 / R44.M3 pins above: a widening on any of
# these makes "pick a color from a catalogue nobody bound",
# "publish a latency the compositor never reported", or "freeze
# scroll on an unrelated event" expressible in a call site the
# confinement gate cannot see.
semterm_pin_one "${GHR_SRC}" 'pub let hdr_set_capable : (u64) -> u64'
semterm_pin_one "${GHR_SRC}" 'pub let hdr_pick_series : (u64) -> u64'
semterm_pin_one "${GFB_SRC}" 'pub let pfb_set_budget : (u64) -> u64'
semterm_pin_one "${GFB_SRC}" 'pub let pfb_report : (u64, u64) -> u64'
echo "[semterm-r44m4-confine] gui_hdr / gui_feedback entry-point arities pinned"

# ---------------------------------------------------------------------------
# G1.M1-001..004 (#1427-#1430): DISPLAY TIMELINE + SYNC CHANNEL + DRIVER
# CONFINEMENT.
#
# Three modules open G1.M1 on top of the R36/R37 display + GPU substrate:
# kind_display_timeline (the drm-syncobj-shaped cap), display_sync_channel
# (the wait_scanout / present_flush RPC schema), and drivers/dpy/timeline
# (the vblank signal seam + the wait primitive). Each owns its own state;
# tools/build.sh confines relocations against each so a second writer
# cannot forge a timeline row, invent a channel counter, or advance a
# scanout value the vblank ISR never latched.
G1_KDT_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_display_timeline.pdx"
G1_DSC_SRC="${REPO_ROOT}/src/kernel/core/ipc/display_sync_channel.pdx"
G1_TLD_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/timeline.pdx"
if [[ ! -f "${G1_KDT_SRC}" || ! -f "${G1_DSC_SRC}" || ! -f "${G1_TLD_SRC}" ]]; then
    echo "[g1-m1-confine] FAIL - one of the G1.M1 source files missing" >&2
    exit 1
fi
ec_confine_one '_display_timeline_table' 'core/cap/kind_display_timeline.o'
ec_confine_one '_display_timeline_stats' 'core/cap/kind_display_timeline.o'
ec_confine_one '_dsc_stats'              'core/ipc/display_sync_channel.o'
ec_confine_one '_dpy_timeline_stats'     'core/drivers/dpy/timeline.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_display_timeline.pdx §2, display_sync_channel.pdx" >&2
    echo "  §0 and drivers/dpy/timeline.pdx §0 for the row/counter" >&2
    echo "  one-writer discipline. The driver reaches the row only" >&2
    echo "  through dpt_find_by_engine_output + dpt_row_signal (both" >&2
    echo "  exported from kind_display_timeline.pdx), so the driver .o" >&2
    echo "  relocates against those selector symbols and NOT against" >&2
    echo "  _display_timeline_table itself." >&2
    exit 1
fi
echo "[g1-m1-confine] G1.M1 (display timeline + sync channel + driver) state confined"

# ---------------------------------------------------------------------------
# G1.M2-001..004 (#1432-#1435): VRR RANGE + VRR CHANNEL + VRR DRIVER
# CONFINEMENT.
#
# Three modules open G1.M2 on top of G1.M1: kind_vrr_range (the VRR
# range capability), vrr_channel (the get_range / enable / disable RPC
# schema), and drivers/dpy/vrr (the DPCD/EDID probe + adaptive-sync
# arming).
G1_KVR_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_vrr_range.pdx"
G1_VRC_SRC="${REPO_ROOT}/src/kernel/core/ipc/vrr_channel.pdx"
G1_VDR_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/vrr.pdx"
if [[ ! -f "${G1_KVR_SRC}" || ! -f "${G1_VRC_SRC}" || ! -f "${G1_VDR_SRC}" ]]; then
    echo "[g1-m2-confine] FAIL - one of the G1.M2 source files missing" >&2
    exit 1
fi
ec_confine_one '_vrr_range_table' 'core/cap/kind_vrr_range.o'
ec_confine_one '_vrr_range_stats' 'core/cap/kind_vrr_range.o'
ec_confine_one '_vrc_stats'       'core/ipc/vrr_channel.o'
ec_confine_one '_vrr_armed_bits'  'core/drivers/dpy/vrr.o'
ec_confine_one '_vrr_probe_stats' 'core/drivers/dpy/vrr.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_vrr_range.pdx §2, vrr_channel.pdx §0 and" >&2
    echo "  drivers/dpy/vrr.pdx §3 for the row/counter/arming" >&2
    echo "  one-writer discipline." >&2
    exit 1
fi
echo "[g1-m2-confine] G1.M2 (VRR range + channel + driver) state confined"

# ---------------------------------------------------------------------------
# G2.M1-001..005 (#1443-#1447) + G2.M2-001..004 (#1448-#1451)
# + G2.M3-001..004 (#1453-#1456): DIRECT-SCANOUT LEASE + CHANNEL +
# DRIVER CONFINEMENT.
#
# Three modules open G2 on top of G1: kind_scanout_lease (the
# leased LINEAR authority over KIND_DISPLAY_PLANE, row table +
# state transitions), scanout_lease_channel (the request_lease /
# present / release RPC schema, session-typed FSM), and
# drivers/dpy/scanout (grant policy, format matrix, HDR attach,
# reserved-plane invariant, expiry sweep, fallback).  Each owns
# its own state; tools/build.sh confines relocations against each
# so a second writer cannot forge a lease row, invent a channel
# counter, or advance a lease state without going through the
# state-transition selector exported by kind_scanout_lease.pdx.
#
# The driver relocates against _scanout_lease_table via the
# exported sl_row_transition + sl_row_state + sl_row_expiry
# selectors -- NOT against the table symbol itself -- so its .o
# stays a valid second writer of the row-state ordinal without
# being able to reshape the row layout.
G2_KSL_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_scanout_lease.pdx"
G2_SLC_SRC="${REPO_ROOT}/src/kernel/core/ipc/scanout_lease_channel.pdx"
G2_SCN_SRC="${REPO_ROOT}/src/kernel/core/drivers/dpy/scanout.pdx"
if [[ ! -f "${G2_KSL_SRC}" || ! -f "${G2_SLC_SRC}" || ! -f "${G2_SCN_SRC}" ]]; then
    echo "[g2-confine] FAIL - one of the G2 source files missing" >&2
    exit 1
fi
ec_confine_one '_scanout_lease_table' 'core/cap/kind_scanout_lease.o'
ec_confine_one '_scanout_lease_stats' 'core/cap/kind_scanout_lease.o'
ec_confine_one '_slc_stats'           'core/ipc/scanout_lease_channel.o'
ec_confine_one '_scanout_stats'       'core/drivers/dpy/scanout.o'
ec_confine_one '_scanout_in_flight'   'core/drivers/dpy/scanout.o'
ec_confine_one '_scanout_hdr_pending' 'core/drivers/dpy/scanout.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_scanout_lease.pdx §2, scanout_lease_channel.pdx" >&2
    echo "  §0 and drivers/dpy/scanout.pdx §0 for the row/counter" >&2
    echo "  one-writer discipline.  The driver reaches the row only" >&2
    echo "  through sl_row_transition + sl_row_state + sl_row_expiry" >&2
    echo "  (all exported from kind_scanout_lease.pdx), so the driver" >&2
    echo "  .o relocates against those selector symbols and NOT" >&2
    echo "  against _scanout_lease_table itself." >&2
    exit 1
fi
echo "[g2-confine] G2 (scanout lease + channel + driver) state confined"

# ---------------------------------------------------------------------------
# G3.M1-001..005 (#1457-#1461) + G3.M2-001..005 (#1462-#1466)
# + G3.M3-001..005 (#1467-#1471) + G3.M4-001..002 (#1472, #1473):
# SWAPCHAIN + PRESENTATION-TIMING CONFINEMENT.
#
# Eight modules open G3 on top of G1 + G2: kind_vk_surface (the WSI
# surface cap), kind_vk_swapchain_image (the LINEAR per-image handle
# carrying two timelines + present_id + target_pts), vk_surface_channel
# (create_swapchain / acquire_image / present_image / destroy_swapchain
# RPC), vk_present_feedback_channel (VK_KHR_present_id + present_wait +
# maintenance1 discard feedback stream), drivers/vk/icd (ICD registry +
# VK_paideia_surface extension + SPIR-V magic-word smoke), drivers/vk/
# swapchain (acquire / present / mode / resize), drivers/vk/features
# (present_id + present_wait + discard-release + P3 fractional-scale
# gcd), drivers/vk/bench (acquire->present latency ring + adaptive
# render policy).
G3_KVS_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_vk_surface.pdx"
G3_KVI_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_vk_swapchain_image.pdx"
G3_VSC_SRC="${REPO_ROOT}/src/kernel/core/ipc/vk_surface_channel.pdx"
G3_VFC_SRC="${REPO_ROOT}/src/kernel/core/ipc/vk_present_feedback_channel.pdx"
G3_ICD_SRC="${REPO_ROOT}/src/kernel/core/drivers/vk/icd.pdx"
G3_SWC_SRC="${REPO_ROOT}/src/kernel/core/drivers/vk/swapchain.pdx"
G3_VKF_SRC="${REPO_ROOT}/src/kernel/core/drivers/vk/vk_features.pdx"
G3_VKB_SRC="${REPO_ROOT}/src/kernel/core/drivers/vk/bench.pdx"
if [[ ! -f "${G3_KVS_SRC}" || ! -f "${G3_KVI_SRC}" || ! -f "${G3_VSC_SRC}" \
    || ! -f "${G3_VFC_SRC}" || ! -f "${G3_ICD_SRC}" || ! -f "${G3_SWC_SRC}" \
    || ! -f "${G3_VKF_SRC}" || ! -f "${G3_VKB_SRC}" ]]; then
    echo "[g3-confine] FAIL - one of the G3 source files missing" >&2
    exit 1
fi
ec_confine_one '_vk_surface_table'          'core/cap/kind_vk_surface.o'
ec_confine_one '_vk_surface_stats'          'core/cap/kind_vk_surface.o'
ec_confine_one '_vk_swapchain_image_table'  'core/cap/kind_vk_swapchain_image.o'
ec_confine_one '_vk_swapchain_image_stats'  'core/cap/kind_vk_swapchain_image.o'
ec_confine_one '_vsc_stats'                 'core/ipc/vk_surface_channel.o'
ec_confine_one '_vfc_queue'                 'core/ipc/vk_present_feedback_channel.o'
ec_confine_one '_vfc_cursor'                'core/ipc/vk_present_feedback_channel.o'
ec_confine_one '_vfc_stats'                 'core/ipc/vk_present_feedback_channel.o'
ec_confine_one '_vki_icd_table'             'core/drivers/vk/icd.o'
ec_confine_one '_vki_stats'                 'core/drivers/vk/icd.o'
ec_confine_one '_vswc_state'                'core/drivers/vk/swapchain.o'
ec_confine_one '_vswc_stats'                'core/drivers/vk/swapchain.o'
ec_confine_one '_vkf_present_id'            'core/drivers/vk/vk_features.o'
ec_confine_one '_vkf_stats'                 'core/drivers/vk/vk_features.o'
ec_confine_one '_vkb_ring'                  'core/drivers/vk/bench.o'
ec_confine_one '_vkb_cursor'                'core/drivers/vk/bench.o'
ec_confine_one '_vkb_stats'                 'core/drivers/vk/bench.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_vk_surface.pdx §2, kind_vk_swapchain_image.pdx §2," >&2
    echo "  vk_surface_channel.pdx §0, vk_present_feedback_channel.pdx §0," >&2
    echo "  and drivers/vk/*.pdx section 0 for the one-writer discipline." >&2
    exit 1
fi
echo "[g3-confine] G3 (VK surface + swapchain image + channels + drivers) state confined"

# ---------------------------------------------------------------------------
# G5.M1-001..005 (#1491-#1495) + G5.M2-001..005 (#1496-#1500)
# + G5.M3-001..004 (#1501-#1504) + G5.M4-001..004 (#1505-#1508):
# SDF FONT ATLAS + TEXT SHAPE CONFINEMENT.
#
# Eight modules open G5 on top of G3 + G4: kind_font_atlas (the on-
# GPU atlas texture cap over KIND_GPU_BO), kind_text_shape (the
# immutable shaped-run cap over KIND_MEMORY), drivers/text/sdf (SDF/
# MSDF generator + format-selection heuristic), drivers/text/shaper
# (OT-feature engine + BiDi + Indic clustering + hinting), drivers/
# text/subpixel (fractional-scale sub-pixel positioning + cache
# invalidation), drivers/text/color_emoji (COLR/CPAL, SBIX, CBDT
# strike selection), ipc/font_load_channel (load / subset / evict
# RPC schema), ipc/text_shape_channel (shape / invalidate / features
# _hash RPC schema).
G5_KFA_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_font_atlas.pdx"
G5_KTS_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_text_shape.pdx"
G5_SDF_SRC="${REPO_ROOT}/src/kernel/core/drivers/text/sdf.pdx"
G5_SHP_SRC="${REPO_ROOT}/src/kernel/core/drivers/text/shaper.pdx"
G5_SPX_SRC="${REPO_ROOT}/src/kernel/core/drivers/text/subpixel.pdx"
G5_CE_SRC="${REPO_ROOT}/src/kernel/core/drivers/text/color_emoji.pdx"
G5_FLC_SRC="${REPO_ROOT}/src/kernel/core/ipc/font_load_channel.pdx"
G5_TSC_SRC="${REPO_ROOT}/src/kernel/core/ipc/text_shape_channel.pdx"
if [[ ! -f "${G5_KFA_SRC}" || ! -f "${G5_KTS_SRC}" || ! -f "${G5_SDF_SRC}" \
    || ! -f "${G5_SHP_SRC}" || ! -f "${G5_SPX_SRC}" || ! -f "${G5_CE_SRC}" \
    || ! -f "${G5_FLC_SRC}" || ! -f "${G5_TSC_SRC}" ]]; then
    echo "[g5-confine] FAIL - one of the G5 source files missing" >&2
    exit 1
fi
ec_confine_one '_font_atlas_table'          'core/cap/kind_font_atlas.o'
ec_confine_one '_font_atlas_stats'          'core/cap/kind_font_atlas.o'
ec_confine_one '_text_shape_table'          'core/cap/kind_text_shape.o'
ec_confine_one '_text_shape_stats'          'core/cap/kind_text_shape.o'
ec_confine_one '_sdf_gen_state'             'core/drivers/text/sdf.o'
ec_confine_one '_sdf_gen_stats'             'core/drivers/text/sdf.o'
ec_confine_one '_shaper_state'              'core/drivers/text/shaper.o'
ec_confine_one '_shaper_stats'              'core/drivers/text/shaper.o'
ec_confine_one '_subpx_cache'               'core/drivers/text/subpixel.o'
ec_confine_one '_subpx_stats'               'core/drivers/text/subpixel.o'
ec_confine_one '_ce_state'                  'core/drivers/text/color_emoji.o'
ec_confine_one '_ce_stats'                  'core/drivers/text/color_emoji.o'
ec_confine_one '_flc_stats'                 'core/ipc/font_load_channel.o'
ec_confine_one '_tsc_stats'                 'core/ipc/text_shape_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_font_atlas.pdx §2, kind_text_shape.pdx §2," >&2
    echo "  drivers/text/*.pdx section 0, ipc/font_load_channel.pdx §0," >&2
    echo "  and ipc/text_shape_channel.pdx §0 for the one-writer discipline." >&2
    exit 1
fi
echo "[g5-confine] G5 (font atlas + text shape + drivers + channels) state confined"

# ---------------------------------------------------------------------------
# G6.M1-001..005 (#1509-#1513) + G6.M2-001..003 (#1514-#1516):
# COLOR MANAGEMENT (ICC v4, CICP, HDR, wide-gamut, tone-map) CONFINEMENT.
#
# Eight modules open G6 on top of G3 + G4 + G5: kind_color_profile
# (KIND_COLOR_PROFILE = 0x18F derived-kind cap over KIND_MEMORY),
# drivers/color/cicp (CICP triplet parser per ITU-T H.273), drivers/
# color/icc (ICC v4 subset parser: matrix/TRC + LUT/A-to-B0),
# ipc/color_management_channel (session schema for query_output_gamut
# / get_tonemap_lut / set_reference_display), drivers/color/surface_
# check (P5 partial: surface commit refused without one live
# KIND_COLOR_PROFILE arg), drivers/color/gpu_convert (six matrix
# conversion pipelines), drivers/color/eotf (sRGB / PQ / HLG / DV
# transfer curves), drivers/color/scrgb (fp16-linear composition
# space + gamut-boundary predicate).
G6_KCP_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_color_profile.pdx"
G6_CICP_SRC="${REPO_ROOT}/src/kernel/core/drivers/color/cicp.pdx"
G6_ICC_SRC="${REPO_ROOT}/src/kernel/core/drivers/color/icc.pdx"
G6_CMC_SRC="${REPO_ROOT}/src/kernel/core/ipc/color_management_channel.pdx"
G6_SC_SRC="${REPO_ROOT}/src/kernel/core/drivers/color/surface_check.pdx"
G6_GCV_SRC="${REPO_ROOT}/src/kernel/core/drivers/color/gpu_convert.pdx"
G6_EOTF_SRC="${REPO_ROOT}/src/kernel/core/drivers/color/eotf.pdx"
G6_SCRGB_SRC="${REPO_ROOT}/src/kernel/core/drivers/color/scrgb.pdx"
if [[ ! -f "${G6_KCP_SRC}" || ! -f "${G6_CICP_SRC}" || ! -f "${G6_ICC_SRC}" \
    || ! -f "${G6_CMC_SRC}" || ! -f "${G6_SC_SRC}" || ! -f "${G6_GCV_SRC}" \
    || ! -f "${G6_EOTF_SRC}" || ! -f "${G6_SCRGB_SRC}" ]]; then
    echo "[g6-confine] FAIL - one of the G6 source files missing" >&2
    exit 1
fi
ec_confine_one '_color_profile_table'   'core/cap/kind_color_profile.o'
ec_confine_one '_color_profile_stats'   'core/cap/kind_color_profile.o'
ec_confine_one '_cicp_stats'            'core/drivers/color/cicp.o'
ec_confine_one '_icc_stats'             'core/drivers/color/icc.o'
ec_confine_one '_cmc_stats'             'core/ipc/color_management_channel.o'
ec_confine_one '_sc_stats'              'core/drivers/color/surface_check.o'
ec_confine_one '_gpu_convert_matrices'  'core/drivers/color/gpu_convert.o'
ec_confine_one '_gpu_convert_stats'     'core/drivers/color/gpu_convert.o'
ec_confine_one '_eotf_tables'           'core/drivers/color/eotf.o'
ec_confine_one '_eotf_stats'            'core/drivers/color/eotf.o'
ec_confine_one '_scrgb_stats'           'core/drivers/color/scrgb.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_color_profile.pdx §2, drivers/color/*.pdx §0," >&2
    echo "  and ipc/color_management_channel.pdx §0 for the one-writer discipline." >&2
    exit 1
fi
echo "[g6-confine] G6 (color profile + CICP + ICC + channels + drivers) state confined"

# ---------------------------------------------------------------------------
# G4.M1-001..005 (#1475-#1479) + G4.M2-001..005 (#1480-#1484)
# + G4.M3-001..003 (#1485-#1487) + G4.M4-001..002 (#1488, #1489):
# VELLO 2D COMPUTE-RENDER CONFINEMENT.
#
# Eight modules open G4 on top of G3 + G5: kind_vello_scene (the
# encoded 2D scene cap), kind_vello_renderer (the compute renderer
# cap), vello_render_channel (encode / submit / await RPC),
# vello_scene_encoder (encoder + upload seam), vello_pipeline
# (STROKE + FILL + BLEND stages), vello_cpu_fallback (llvmpipe-
# equivalent + hash gate), vello_effects (gradient / blur / dash /
# arrow / marker), vello_tiling (coarsening + occupancy).
G4_KVS_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_vello_scene.pdx"
G4_KVR_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_vello_renderer.pdx"
G4_VRC_SRC="${REPO_ROOT}/src/kernel/core/ipc/vello_render_channel.pdx"
G4_VSE_SRC="${REPO_ROOT}/src/kernel/core/drivers/vello/vello_scene_encoder.pdx"
G4_VP_SRC="${REPO_ROOT}/src/kernel/core/drivers/vello/vello_pipeline.pdx"
G4_VCF_SRC="${REPO_ROOT}/src/kernel/core/drivers/vello/vello_cpu_fallback.pdx"
G4_VE_SRC="${REPO_ROOT}/src/kernel/core/drivers/vello/vello_effects.pdx"
G4_VT_SRC="${REPO_ROOT}/src/kernel/core/drivers/vello/vello_tiling.pdx"
if [[ ! -f "${G4_KVS_SRC}" || ! -f "${G4_KVR_SRC}" || ! -f "${G4_VRC_SRC}" \
    || ! -f "${G4_VSE_SRC}" || ! -f "${G4_VP_SRC}" || ! -f "${G4_VCF_SRC}" \
    || ! -f "${G4_VE_SRC}" || ! -f "${G4_VT_SRC}" ]]; then
    echo "[g4-confine] FAIL - one of the G4 source files missing" >&2
    exit 1
fi
ec_confine_one '_vello_scene_table'    'core/cap/kind_vello_scene.o'
ec_confine_one '_vello_scene_stats'    'core/cap/kind_vello_scene.o'
ec_confine_one '_vello_renderer_table' 'core/cap/kind_vello_renderer.o'
ec_confine_one '_vello_renderer_stats' 'core/cap/kind_vello_renderer.o'
ec_confine_one '_vrenc_stats'          'core/ipc/vello_render_channel.o'
ec_confine_one '_vse_state'            'core/drivers/vello/vello_scene_encoder.o'
ec_confine_one '_vse_stats'            'core/drivers/vello/vello_scene_encoder.o'
ec_confine_one '_vp_ring'              'core/drivers/vello/vello_pipeline.o'
ec_confine_one '_vp_stats'             'core/drivers/vello/vello_pipeline.o'
ec_confine_one '_vp_next_id'           'core/drivers/vello/vello_pipeline.o'
ec_confine_one '_vcf_state'            'core/drivers/vello/vello_cpu_fallback.o'
ec_confine_one '_vcf_stats'            'core/drivers/vello/vello_cpu_fallback.o'
ec_confine_one '_ve_ring'              'core/drivers/vello/vello_effects.o'
ec_confine_one '_ve_stats'             'core/drivers/vello/vello_effects.o'
ec_confine_one '_vt_state'             'core/drivers/vello/vello_tiling.o'
ec_confine_one '_vt_stats'             'core/drivers/vello/vello_tiling.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_vello_scene.pdx §2, kind_vello_renderer.pdx §2," >&2
    echo "  vello_render_channel.pdx §0, and drivers/vello/*.pdx §0" >&2
    echo "  for the one-writer discipline." >&2
    exit 1
fi
echo "[g4-confine] G4 (Vello scene + renderer + channel + drivers) state confined"

# ---------------------------------------------------------------------------
# R47.M1..M5 (#1412/#1413/#1414/#1415/#1416/#1417/#1418/#1419/
#             #1421/#1422/#1423/#1424): Intel VMD driver substrate --
# vmd_probe, vmd_endpoint_enum, kind_vmd_endpoint, vmd_root_complex,
# vmd_msix_remap, vmd_hotplug, vmd_nvme_bridge, vmd_nvme_isolation,
# vmd_iommu_domain, vmd_iommu_switch, vmd_bios_off_fallback, and the
# vmd_config_channel schema.
#
# Twelve modules open R47 across four bands (0xFFFFFBD0..FF for M1,
# 0xFFFFFD10..1F + 0xFFFFFD30..3F + 0xFFFFFD70..7F for M2, 0xFFFFFD90..9F
# for M3, 0xFFFFFDD0..DF for M4/M5).  Each owns its own state cells;
# tools/build.sh confines relocations against each so a second writer
# cannot forge a probe count, a child endpoint row, an aperture stat,
# an MSI-X translation, a hotplug counter, an NVMe binding, a QP
# owner, an IOMMU domain assignment, an active-domain cell, a
# fallback tally, or a config-channel session.
VMDP_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/probe.pdx"
VMDE_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/endpoint_enum.pdx"
VMDK_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_vmd_endpoint.pdx"
VMDR_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/root_complex.pdx"
VMDM_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/msix_remap.pdx"
VMDH_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/hotplug.pdx"
VMDNB_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/nvme_bridge.pdx"
VMDNI_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/nvme_isolation.pdx"
VMDID_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/iommu_domain.pdx"
VMDIS_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/iommu_switch.pdx"
VMDBF_SRC="${REPO_ROOT}/src/kernel/core/drivers/vmd/bios_off_fallback.pdx"
VMDCC_SRC="${REPO_ROOT}/src/kernel/core/ipc/vmd_config_channel.pdx"
if [[ ! -f "${VMDP_SRC}" || ! -f "${VMDE_SRC}" || ! -f "${VMDK_SRC}" \
    || ! -f "${VMDR_SRC}" || ! -f "${VMDM_SRC}" || ! -f "${VMDH_SRC}" \
    || ! -f "${VMDNB_SRC}" || ! -f "${VMDNI_SRC}" \
    || ! -f "${VMDID_SRC}" || ! -f "${VMDIS_SRC}" \
    || ! -f "${VMDBF_SRC}" || ! -f "${VMDCC_SRC}" ]]; then
    echo "[r47-confine] FAIL - one of the R47 source files missing" >&2
    exit 1
fi
ec_confine_one '_vmd_probe_stats'          'core/drivers/vmd/probe.o'
ec_confine_one '_vmd_enum_children'        'core/drivers/vmd/endpoint_enum.o'
ec_confine_one '_vmd_enum_stats'           'core/drivers/vmd/endpoint_enum.o'
ec_confine_one '_vmd_endpoint_table'       'core/cap/kind_vmd_endpoint.o'
ec_confine_one '_vmd_endpoint_stats'       'core/cap/kind_vmd_endpoint.o'
ec_confine_one '_vmd_root_stats'           'core/drivers/vmd/root_complex.o'
ec_confine_one '_vmd_msix_map'             'core/drivers/vmd/msix_remap.o'
ec_confine_one '_vmd_msix_stats'           'core/drivers/vmd/msix_remap.o'
ec_confine_one '_vmd_hotplug_stats'        'core/drivers/vmd/hotplug.o'
ec_confine_one '_vmd_nvme_bindings'        'core/drivers/vmd/nvme_bridge.o'
ec_confine_one '_vmd_nvme_stats'           'core/drivers/vmd/nvme_bridge.o'
ec_confine_one '_vmd_qp_owners'            'core/drivers/vmd/nvme_isolation.o'
ec_confine_one '_vmd_iso_stats'            'core/drivers/vmd/nvme_isolation.o'
ec_confine_one '_vmd_iommu_owners'         'core/drivers/vmd/iommu_domain.o'
ec_confine_one '_vmd_iommu_stats'          'core/drivers/vmd/iommu_domain.o'
ec_confine_one '_vmd_iommu_active'         'core/drivers/vmd/iommu_switch.o'
ec_confine_one '_vmd_switch_stats'         'core/drivers/vmd/iommu_switch.o'
ec_confine_one '_vmd_fallback_stats'       'core/drivers/vmd/bios_off_fallback.o'
ec_confine_one '_vcc_sessions'             'core/ipc/vmd_config_channel.o'
ec_confine_one '_vcc_stats'                'core/ipc/vmd_config_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See vmd/probe.pdx §2, endpoint_enum.pdx §1," >&2
    echo "  kind_vmd_endpoint.pdx §1, root_complex.pdx §2," >&2
    echo "  msix_remap.pdx §1, hotplug.pdx §1, nvme_bridge.pdx §1," >&2
    echo "  nvme_isolation.pdx §1, iommu_domain.pdx §1," >&2
    echo "  iommu_switch.pdx §1, bios_off_fallback.pdx §0," >&2
    echo "  and vmd_config_channel.pdx §1 for the per-module" >&2
    echo "  one-writer discipline." >&2
    exit 1
fi
echo "[r47-confine] R47 (VMD probe + enum + cap + root complex + msix + hotplug + nvme bridge + nvme isolation + iommu domain + iommu switch + bios-off + config channel) confined"

# ---------------------------------------------------------------------------
# R48.M1..M3 (#1517-#1530): user-management substrate one-writer discipline.
#
# Three modules open R48: kind_user (the KIND_USER capability + row table
# + cascade revocation), pdxuser (the .pdxuser record parser/writer + sig
# verification seam + revoked-fingerprint blacklist), identity (the
# .identity/ subtree layout + user_sk.enc format + seal/unseal seams +
# in-memory user_sk lifetime + no-back-door diagnostics).
#
# The three tables (_user_table, _pdxuser_blacklist, _identity_sk_slot)
# are the only places in the kernel where user identity state lives; a
# second writer of any of them would let one supervisor read a user's
# authority (or the revoked-blacklist) with no capability involved. Per-
# module confinement is what makes that unreachable by construction.
R48_KU_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_user.pdx"
R48_PU_SRC="${REPO_ROOT}/src/kernel/user/pdxuser.pdx"
R48_ID_SRC="${REPO_ROOT}/src/kernel/user/identity.pdx"
if [[ ! -f "${R48_KU_SRC}" || ! -f "${R48_PU_SRC}" || ! -f "${R48_ID_SRC}" ]]; then
    echo "[r48-confine] FAIL - one of the R48 source files missing" >&2
    exit 1
fi
ec_confine_one '_user_table'           'core/cap/kind_user.o'
ec_confine_one '_user_stats'           'core/cap/kind_user.o'
ec_confine_one '_pdxuser_blacklist'    'user/pdxuser.o'
ec_confine_one '_pdxuser_stats'        'user/pdxuser.o'
ec_confine_one '_identity_sk_slot'     'user/identity.o'
ec_confine_one '_identity_stats'       'user/identity.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_user.pdx §1, pdxuser.pdx §4, identity.pdx §4 for" >&2
    echo "  the per-module one-writer discipline." >&2
    exit 1
fi
echo "[r48-confine] R48 (KIND_USER + .pdxuser records + identity storage) confined"

# ---------------------------------------------------------------------------
# R48b substrate-prep (#1623 / #1624 / #1626): one-writer discipline
# for the three new capability kinds that unblock the R49/R50 tools.
#
#   * kind_pdxfs_file      (KIND_PDXFS_FILE     = 0x195, over KIND_MEMORY)
#   * kind_pdxfs_txn       (KIND_PDXFS_TXN      = 0x196, over KIND_MEMORY)
#   * kind_elevate_channel (KIND_ELEVATE_CHANNEL = 0x191, over KIND_IPC_ENDPOINT)
#
# The three tables (_pdxfs_file_table, _pdxfs_txn_table,
# _elevate_channel_table) plus their _stats siblings are the only
# places in the kernel where these authorities live. A second writer
# would let one supervisor mutate a file authority / transaction state
# / channel row with no capability involved. Per-module confinement
# is what makes that unreachable by construction.
R48B_PFF_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_pdxfs_file.pdx"
R48B_PXT_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_pdxfs_txn.pdx"
R48B_ELVC_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_elevate_channel.pdx"
if [[ ! -f "${R48B_PFF_SRC}" || ! -f "${R48B_PXT_SRC}" || ! -f "${R48B_ELVC_SRC}" ]]; then
    echo "[r48b-confine] FAIL - one of the R48b substrate KIND source files missing" >&2
    exit 1
fi
ec_confine_one '_pdxfs_file_table'          'core/cap/kind_pdxfs_file.o'
ec_confine_one '_pdxfs_file_stats'          'core/cap/kind_pdxfs_file.o'
ec_confine_one '_pdxfs_txn_table'           'core/cap/kind_pdxfs_txn.o'
ec_confine_one '_pdxfs_txn_stats'           'core/cap/kind_pdxfs_txn.o'
ec_confine_one '_elevate_channel_table'     'core/cap/kind_elevate_channel.o'
ec_confine_one '_elevate_channel_stats'     'core/cap/kind_elevate_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_pdxfs_file.pdx §1, kind_pdxfs_txn.pdx §1, and" >&2
    echo "  kind_elevate_channel.pdx §1 for the per-module one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[r48b-confine] R48b (KIND_PDXFS_FILE + KIND_PDXFS_TXN + KIND_ELEVATE_CHANNEL) confined"

# ---------------------------------------------------------------------------
# R30-PREP (#1631): one-writer discipline for KIND_TTY.
#
#   * kind_tty (KIND_TTY = 0x197, over KIND_IPC_ENDPOINT)
#
# _tty_table + _tty_stats are the only places in the kernel where TTY
# sink authority lives.  A second writer would let one supervisor
# mutate a sink row (change advertised dimensions, forge a bytes-
# written total) with no capability involved.  Per-module confinement
# is what makes that unreachable by construction; the sole writer is
# tty_tail_alloc, gated by tty_cap_mint_inner (kind_tty.pdx §1).
R30_TTY_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_tty.pdx"
if [[ ! -f "${R30_TTY_SRC}" ]]; then
    echo "[r30-prep-confine] FAIL - kind_tty.pdx missing" >&2
    exit 1
fi
ec_confine_one '_tty_table'   'core/cap/kind_tty.o'
ec_confine_one '_tty_stats'   'core/cap/kind_tty.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_tty.pdx §1 for the per-module one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[r30-prep-confine] R30-PREP (KIND_TTY) confined"

# ---------------------------------------------------------------------------
# R51.M1-001 (#1633): one-writer discipline for KIND_NVME_CONTROLLER.
#
#   * kind_nvme_controller (KIND_NVME_CONTROLLER = 0x198, over KIND_DEVICE)
#
# _nvme_controller_table + _nvme_controller_stats are the only places
# in the kernel where NVMe-controller authority lives.  A second writer
# would let one supervisor mutate a controller row (change bar0_pa,
# forge a state transition, silently expand MDTS) with no capability
# involved.  Per-module confinement is what makes that unreachable by
# construction; the sole writer is nvme_ctrl_tail_alloc / _tail_free,
# gated by nvme_ctrl_cap_mint_inner and nvme_ctrl_cap_revoke.
R51_NVMEC_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_nvme_controller.pdx"
if [[ ! -f "${R51_NVMEC_SRC}" ]]; then
    echo "[r51-m1-confine] FAIL - kind_nvme_controller.pdx missing" >&2
    exit 1
fi
ec_confine_one '_nvme_controller_table' 'core/cap/kind_nvme_controller.o'
ec_confine_one '_nvme_controller_stats' 'core/cap/kind_nvme_controller.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_nvme_controller.pdx §1 for the per-module one-writer" >&2
    echo "  discipline (the sole writers are nvme_ctrl_tail_alloc + " >&2
    echo "  nvme_ctrl_tail_free + nvme_ctrl_note + nvme_ctrl_table_reset)." >&2
    exit 1
fi
echo "[r51-m1-confine] R51.M1 (KIND_NVME_CONTROLLER) confined"

# ---------------------------------------------------------------------------
# R51.M2-001 (#1639): one-writer discipline for KIND_NVME_NAMESPACE.
#
#   * kind_nvme_namespace (KIND_NVME_NAMESPACE = 0x199, over KIND_MEMORY,
#                          dual-kind with KIND_BLKDEV = 0x42)
#
# _nvme_namespace_table + _nvme_namespace_stats are the only places
# in the kernel where NVMe-namespace authority lives.  A second writer
# would let one supervisor mutate a namespace row (change nsid,
# rewrite block_count, forge a family byte so a KIND_BLKDEV consumer
# reads AHCI geometry from what is really an NVMe row) with no
# capability involved.  Per-module confinement is what makes that
# unreachable by construction; the sole writers are
# nvme_ns_tail_alloc / _tail_free / _note / _table_reset (all in
# kind_nvme_namespace.pdx §1).
R51_NVMEN_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_nvme_namespace.pdx"
if [[ ! -f "${R51_NVMEN_SRC}" ]]; then
    echo "[r51-m2-confine] FAIL - kind_nvme_namespace.pdx missing" >&2
    exit 1
fi
ec_confine_one '_nvme_namespace_table' 'core/cap/kind_nvme_namespace.o'
ec_confine_one '_nvme_namespace_stats' 'core/cap/kind_nvme_namespace.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See kind_nvme_namespace.pdx §1 for the per-module one-writer" >&2
    echo "  discipline (the sole writers are nvme_ns_tail_alloc + " >&2
    echo "  nvme_ns_tail_free + nvme_ns_note + nvme_ns_table_reset)." >&2
    exit 1
fi
echo "[r51-m2-confine] R51.M2 (KIND_NVME_NAMESPACE) confined"

# ---------------------------------------------------------------------------
# R52.M2-001 (#1686): one-writer discipline for the PdxFS-on-block
# superblock-read scratch state.
#
#   * superblock_read (src/kernel/core/fs/pdxfs/superblock_read.pdx)
#
# _sb_read_buf (the 4-KiB landing zone for the just-read LBA-0 block) and
# _sb_read_desc (the BDEV_OP_READ_LBA descriptor page) are the only
# places `sb_read` stages a device read. A second writer could race the
# descriptor page mid-submission (corrupting lba/nblocks/dma_iova between
# the stamp and the cap_invoke) or read a stale/partially-written buffer
# out from under sb_read's own validators.
R52_SBRD_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/superblock_read.pdx"
if [[ ! -f "${R52_SBRD_SRC}" ]]; then
    echo "[r52-m2-confine] FAIL - superblock_read.pdx missing" >&2
    exit 1
fi
ec_confine_one '_sb_read_buf'  'core/fs/pdxfs/superblock_read.o'
ec_confine_one '_sb_read_desc' 'core/fs/pdxfs/superblock_read.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See superblock_read.pdx §Storage for the per-module one-writer" >&2
    echo "  discipline (the sole writer is sb_read)." >&2
    exit 1
fi
echo "[r52-m2-confine] R52.M2 (superblock_read) confined"

# ---------------------------------------------------------------------------
# R52.M2-002 (#1687): one-writer discipline for the PdxFS-on-block
# superblock-write scratch state.
#
#   * superblock_write (src/kernel/core/fs/pdxfs/superblock_write.pdx)
#
# _sb_write_desc (the BDEV_OP_WRITE_LBA descriptor page) is the only
# place `sb_write` stages a device write. A second writer could race the
# descriptor page mid-submission (corrupting lba/nblocks/dma_iova between
# the stamp and the cap_invoke), corrupting a signed-superblock write in
# flight. No `_sb_write_buf` exists here -- unlike sb_read, sb_write
# never owns the superblock bytes (dma_iova points at the caller-supplied
# sb_block_ptr directly, see superblock_write.pdx §Storage).
R52_SBWR_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/superblock_write.pdx"
if [[ ! -f "${R52_SBWR_SRC}" ]]; then
    echo "[r52-m2-confine] FAIL - superblock_write.pdx missing" >&2
    exit 1
fi
ec_confine_one '_sb_write_desc' 'core/fs/pdxfs/superblock_write.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See superblock_write.pdx §Storage for the per-module one-writer" >&2
    echo "  discipline (the sole writer is sb_write)." >&2
    exit 1
fi
echo "[r52-m2-confine] R52.M2 (superblock_write) confined"

# ---------------------------------------------------------------------------
# R52.M2-003 (#1688): one-writer discipline for the mkfs.pdxfs tool's
# scratch state.
#
#   * mkfs (src/kernel/core/fs/pdxfs/mkfs.pdx)
#
# _mkfs_layout_row (the 9-field region-layout result), _mkfs_sb_scratch
# (the in-memory superblock built before sb_write persists it),
# _mkfs_zero_buf (the shared all-zero WRITE_LBA source buffer), and
# _mkfs_zero_desc (the WRITE_LBA descriptor page used by the region-zero
# loop) are all single-writer state confined to this one module -- a
# second writer could race a region-zero write mid-submission or corrupt
# the superblock scratch between mkfs_sb_populate and sb_write.
R52_MKFS_SRC="${REPO_ROOT}/src/kernel/core/fs/pdxfs/mkfs.pdx"
if [[ ! -f "${R52_MKFS_SRC}" ]]; then
    echo "[r52-m2-confine] FAIL - mkfs.pdx missing" >&2
    exit 1
fi
ec_confine_one '_mkfs_layout_row' 'core/fs/pdxfs/mkfs.o tests/kernel/fs/pdxfs/mkfs_probe_witness_synth.o'
ec_confine_one '_mkfs_sb_scratch' 'core/fs/pdxfs/mkfs.o tests/kernel/fs/pdxfs/mkfs_probe_witness_synth.o'
ec_confine_one '_mkfs_zero_buf'   'core/fs/pdxfs/mkfs.o'
ec_confine_one '_mkfs_zero_desc'  'core/fs/pdxfs/mkfs.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See mkfs.pdx §Storage for the per-module one-writer" >&2
    echo "  discipline (the sole writers are mkfs_layout_compute," >&2
    echo "  mkfs_sb_populate, and mkfs_zero_region)." >&2
    exit 1
fi
echo "[r52-m2-confine] R52.M2 (mkfs) confined"

# ---------------------------------------------------------------------------
# R42-PREP-008 (#1630): one-writer discipline for the PdxFS userspace
# directory iterator cursor table.
#
#   * pdxfs_dir_iter (KIND_PDXFS_FILE-shaped dir cap, cursor table for
#                     sys_pdxfs_dir_readnext)
#
# _pdxfs_dir_cursor is a per-row_id cursor byte array parallel to
# _pdxfs_file_table.  The only writers are pdxfs_dir_iter_reset (bulk
# zero at boot), pdxfs_dir_cursor_reset (per-slot zero on open) and
# pdxfs_dir_readnext (per-slot increment on advance), all in one file.
# A second writer would let one caller advance / rewind another
# caller's iterator with no capability check.  Per-module confinement
# is what makes that unreachable by construction.
R42_PDI_SRC="${REPO_ROOT}/src/kernel/core/cap/pdxfs_dir_iter.pdx"
if [[ ! -f "${R42_PDI_SRC}" ]]; then
    echo "[r42-prep-008-confine] FAIL - pdxfs_dir_iter.pdx missing" >&2
    exit 1
fi
ec_confine_one '_pdxfs_dir_cursor' 'core/cap/pdxfs_dir_iter.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See pdxfs_dir_iter.pdx §2 for the per-module one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[r42-prep-008-confine] R42-PREP-008 (pdxfs_dir_iter) confined"

# ---------------------------------------------------------------------------
# R48b substrate-prep (#1627): svc.elevate-broker registration seam.
#
# The kernel-side seam that reserves the well-known service name and
# provides a stub RPC dispatch. Full daemon body arrives later. The
# counter table _elevate_broker_stats has exactly one writer here so
# stray increments cannot silently drift the record of what the broker
# has done.
R48B_ELVB_SRC="${REPO_ROOT}/src/kernel/core/ipc/elevate_broker.pdx"
if [[ ! -f "${R48B_ELVB_SRC}" ]]; then
    echo "[elevate-broker-confine] FAIL - ${R48B_ELVB_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_elevate_broker_stats' 'core/ipc/elevate_broker.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See ipc/elevate_broker.pdx §SCOPE for the counter one-writer" >&2
    echo "  discipline." >&2
    exit 1
fi
echo "[elevate-broker-confine] elevate-broker seam counters confined"

# ---------------------------------------------------------------------------
# R48b substrate-prep (#1628): svc.audit-journal registration seam +
# UEJ_KIND_TOOL_* event constants for tool journalling.
#
# Same shape as the elevate-broker seam. _audit_journal_broker_stats
# has exactly one writer so the record of tool install/remove/invoke/
# error events cannot be silently drifted.
R48B_AJB_SRC="${REPO_ROOT}/src/kernel/core/ipc/audit_journal_broker.pdx"
if [[ ! -f "${R48B_AJB_SRC}" ]]; then
    echo "[audit-journal-confine] FAIL - ${R48B_AJB_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_audit_journal_broker_stats' 'core/ipc/audit_journal_broker.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See ipc/audit_journal_broker.pdx §SCOPE for the counter" >&2
    echo "  one-writer discipline." >&2
    exit 1
fi
echo "[audit-journal-confine] audit-journal seam counters confined"

# ---------------------------------------------------------------------------
# G1.M1-005 (#1431) + G1.M3-005 (#1441): P1 INVARIANT ENFORCEMENT.
#
# Refuses the build if any source file:
#   (a) contains a forbidden legacy-DRM implicit-sync symbol
#       (commit_frame_no_sync / present_now_implicit / drmModePageFlip /
#       atomic_commit_nofence), or
#   (b) defines a `commit_frame` or `present_flush` symbol without also
#       referencing KIND_DISPLAY_TIMELINE / dpt_row_signal /
#       dpy_timeline_wait_le in the same file.
#
# See tools/verify-implicit-sync-forbidden.sh for the argument.
echo "[implicit-sync-forbidden] tools/verify-implicit-sync-forbidden.sh"
"${REPO_ROOT}/tools/verify-implicit-sync-forbidden.sh" || {
    echo "[FAIL] P1 invariant enforcement failed" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# R33.M5-003 (#1159): THE Q15 SAT-ADDER SINGLETON.
#
# One saturating combine, everywhere. Two Q15 adders would let one path
# saturate and the other wrap, and no downstream stage could tell them
# apart. The primitive lives in route_table.pdx per §0 of the file; this
# gate confines its symbol.
Q15_ROUTE_SRC="${REPO_ROOT}/src/kernel/core/drivers/audio/route_table.pdx"
if [[ ! -f "${Q15_ROUTE_SRC}" ]]; then
    echo "[q15-confine] FAIL - ${Q15_ROUTE_SRC} not found" >&2
    exit 1
fi
if ! grep -qF -- 'pub let q15_add_sat : (u64, u64) -> u64' "${Q15_ROUTE_SRC}"; then
    echo "[q15-confine] FAIL - q15_add_sat signature drifted." >&2
    echo "  The saturating combine is the ONE primitive that answers the" >&2
    echo "  amplifier's question about combined gain. See" >&2
    echo "  src/kernel/core/drivers/audio/route_table.pdx §0." >&2
    exit 1
fi
echo "[q15-confine] q15_add_sat signature pinned"

# ---------------------------------------------------------------------------
# R33.M3-002 (#1148): THE HDA BDL PATH.
#
# Confine the five state cells (_hda_bdl_bound / _pa / _entries / _cbl /
# _shadow) and the counters. tools/build.sh confines relocations against
# all of them to core/drivers/hda/bdl.o so a stray writer cannot restamp
# the BDL parameters or shadow entries.
HDA_BDL_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/bdl.pdx"
if [[ ! -f "${HDA_BDL_SRC}" ]]; then
    echo "[hda-bdl-confine] FAIL - ${HDA_BDL_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_hda_bdl_bound' 'core/drivers/hda/bdl.o'
ec_confine_one '_hda_bdl_pa' 'core/drivers/hda/bdl.o'
ec_confine_one '_hda_bdl_entries' 'core/drivers/hda/bdl.o'
ec_confine_one '_hda_bdl_cbl' 'core/drivers/hda/bdl.o'
ec_confine_one '_hda_bdl_shadow' 'core/drivers/hda/bdl.o'
ec_confine_one '_hda_bdl_stats' 'core/drivers/hda/bdl.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/drivers/hda/bdl.pdx §2 for why the BDL" >&2
    echo "  parameters and shadow entries have exactly one writer." >&2
    exit 1
fi
echo "[hda-bdl-confine] hda BDL state confined"

# ---------------------------------------------------------------------------
# R32.M3-002 (#1126): THE HID EVENT PATH.
#
# Same shape as the HID device path above. Two claims:
#
# (a) _hid_event_table is the only place in the kernel where a
#     subscription's (endpoint_id, event_type_mask, subscriber_pid)
#     triple lives. A second writer could install a subscription
#     with no gate involved and no audit record, and every future
#     router delivery would then be one made against a subscription
#     the derivation lattice never blessed.
#     _hid_event_stats is confined for the sibling reason.
#
# (b) Arity pins. The static identity (endpoint, mask, pid) comes
#     from the ROW at mint, so the slot-arity-one resolvers take a
#     capability and nothing else. `mask_of_slot(slot, assumed)`
#     reads as a convenience and is a way to make a router think
#     one subscription wants events it never asked for.
HID_EVENT_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_hid_event.pdx"
if [[ ! -f "${HID_EVENT_SRC}" ]]; then
    echo "[hid-event-confine] FAIL - ${HID_EVENT_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_hid_event_table' 'core/cap/kind_hid_event.o'
ec_confine_one '_hid_event_stats' 'core/cap/kind_hid_event.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_hid_event.pdx §1 for why the row" >&2
    echo "  table has exactly one writer." >&2
    exit 1
fi
echo "[hid-event-confine] HID event rows and counter confined"

hide_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HID_EVENT_SRC}"; then
        echo "[hid-event-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A SUBSCRIPTION'S ENDPOINT, MASK AND PID COME FROM THE" >&2
        echo "  CAPABILITY'S OWN ROW AND NEVER FROM A CALLER. An extra" >&2
        echo "  parameter on any of these makes 'route my subscription as" >&2
        echo "  if it were somebody else's' expressible, and the two ways" >&2
        echo "  that goes wrong are silent event misdelivery and silent" >&2
        echo "  event drop. If a signature legitimately changed, the" >&2
        echo "  confinement argument in src/kernel/core/cap/" >&2
        echo "  kind_hid_event.pdx §1 must be rewritten first." >&2
        exit 1
    fi
}
hide_pin_one 'pub let hid_event_channel_of_slot : (u64) -> u64'
hide_pin_one 'pub let hid_event_mask_of_slot : (u64) -> u64'
hide_pin_one 'pub let hid_event_pid_of_slot : (u64) -> u64'
hide_pin_one 'pub let hid_event_row_of_slot : (u64) -> u64'
hide_pin_one 'pub let hid_event_row_mask : (u64) -> u64'
hide_pin_one 'pub let hid_event_mask_valid : (u64) -> u64'
echo "[hid-event-confine] static-identity resolvers and mask validator arities pinned"

# A MASK THAT CAN BE CHANGED IS NOT A SUBSCRIPTION. §3 states the
# discipline explicitly; these are the names a future "let a subscriber
# add a class after the fact" change would be given.
if grep -qE 'hid_event_(set_mask|mask_set|widen_mask|narrow_mask|mask_add|mask_remove|set_pid|pid_set|set_channel|channel_set)' "${HID_EVENT_SRC}"; then
    echo "[hid-event-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the HID event kind." >&2
    echo "" >&2
    echo "  event_type_mask, subscriber_pid and event_channel_key are set" >&2
    echo "  once, by the mint, and there is no primitive that changes" >&2
    echo "  them; see src/kernel/core/cap/kind_hid_event.pdx §3." >&2
    echo "  A MASK THAT CAN BE WIDENED WOULD LET A SUBSCRIBER GAIN REACH" >&2
    echo "  AT RUNTIME NO GATE VALIDATED; NARROWING IS EXPRESSIBLE BY" >&2
    echo "  REVOKING AND MINTING A FRESH ROW." >&2
    exit 1
fi
echo "[hid-event-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R32.M3-003 (#1127): HID EVENT STREAM FANOUT.
#
# Same shape as the HID device / HID event checks above. Two claims:
#
# (a) _hid_evt_stream_subs, _hid_evt_stream_delivered,
#     _hid_evt_stream_stats and _hid_evt_stream_seq are the only place
#     in the kernel where the fanout's subscriber table, per-subscriber
#     delivery counts and monotone offer sequence live. A second writer
#     could forge a subscriber (a delivery to a slot no capability
#     names) or a delivery count (evidence a subscriber received events
#     it never was matched for), and every future R32.M4 router
#     accounting record would then be recorded against a fanout the
#     subscribe gate never blessed. Confinement here is what makes the
#     subscribe/unsubscribe primitives the ONLY path in.
#
# (b) Arity pins. The subscriber's mask, endpoint and pid come from
#     the KIND_HID_EVENT ROW at mint, so publish() takes only the
#     event class bit and an opaque payload -- never a caller-supplied
#     'this slot only' filter, which would let a producer force a
#     delivery to happen only when the subscriber's mask matched
#     something the producer chose rather than what the subscription
#     recorded. subscribe/unsubscribe likewise take one slot and
#     nothing else.
HID_STREAM_SRC="${REPO_ROOT}/src/kernel/core/drivers/hid/event_stream.pdx"
if [[ ! -f "${HID_STREAM_SRC}" ]]; then
    echo "[hid-stream-confine] FAIL - ${HID_STREAM_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_hid_evt_stream_subs'      'core/drivers/hid/event_stream.o'
ec_confine_one '_hid_evt_stream_delivered' 'core/drivers/hid/event_stream.o'
ec_confine_one '_hid_evt_stream_stats'     'core/drivers/hid/event_stream.o'
ec_confine_one '_hid_evt_stream_seq'       'core/drivers/hid/event_stream.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/drivers/hid/event_stream.pdx §2 for why the" >&2
    echo "  subscriber table, per-subscriber deliveries, stats and seq have" >&2
    echo "  exactly one writer." >&2
    exit 1
fi
echo "[hid-stream-confine] HID event stream subscriber table, deliveries, stats and seq confined"

hes_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HID_STREAM_SRC}"; then
        echo "[hid-stream-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A HID EVENT STREAM SUBSCRIBER'S MASK COMES FROM THE" >&2
        echo "  KIND_HID_EVENT ROW AND NEVER FROM A CALLER. An extra" >&2
        echo "  parameter on publish() would let a producer force a" >&2
        echo "  fanout to happen only when the subscriber's mask matched" >&2
        echo "  something the producer chose rather than what the" >&2
        echo "  subscription recorded, and the silent misdeliveries and" >&2
        echo "  silent drops that would produce have no other refusal." >&2
        echo "  If a signature legitimately changed, the confinement" >&2
        echo "  argument in src/kernel/core/drivers/hid/event_stream.pdx" >&2
        echo "  §2 must be rewritten first." >&2
        exit 1
    fi
}
hes_pin_one 'pub let hid_event_stream_subscribe : (u64) -> u64'
hes_pin_one 'pub let hid_event_stream_unsubscribe : (u64) -> u64'
hes_pin_one 'pub let hid_event_stream_publish : (u64, u64) -> u64'
hes_pin_one 'pub let hid_event_stream_delivered_by : (u64) -> u64'
hes_pin_one 'pub let hid_event_stream_sub_count : () -> u64'
hes_pin_one 'pub let hid_event_stream_seq : () -> u64'
echo "[hid-stream-confine] subscribe / unsubscribe / publish / delivered_by / sub_count / seq arities pinned"

# ---------------------------------------------------------------------------
# R32.M3-004 (#1128): HID EVENT STREAM CHANNEL SCHEMA ARITY PINS.
#
# The schema has no storage of its own -- it is pure pack/unpack -- so
# there is no _table to confine. What there IS to defend is the arity of
# every packer and unpacker. A third parameter on pack_kbd_press is a
# caller-supplied modifier bitmap that lets a producer smuggle receiver-
# side state (shift/ctrl/alt) into the wire; a third parameter on
# pack_mouse_move is a scroll delta that reads as a convenience and
# quietly widens the event class into SCROLL (which is a separate event
# type if it is added at all -- see §3). Neither is expressible against
# a pinned signature.
HESCH_SRC="${REPO_ROOT}/src/kernel/core/ipc/hid_event_stream_channel.pdx"
if [[ ! -f "${HESCH_SRC}" ]]; then
    echo "[hid-stream-schema-confine] FAIL - ${HESCH_SRC} not found" >&2
    exit 1
fi
hesch_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HESCH_SRC}"; then
        echo "[hid-stream-schema-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A HID EVENT STREAM CHANNEL FIELD IS DECIDED BY THE SCHEMA" >&2
        echo "  AND NEVER BY A CALLER. An extra parameter on any packer or" >&2
        echo "  unpacker makes 'pack a field my subscriber does not know" >&2
        echo "  about' or 'extract a bit range my packer never wrote to'" >&2
        echo "  expressible, and both ways that goes wrong silently reads or" >&2
        echo "  writes the wrong bits (a scancode becomes a modifier state," >&2
        echo "  a mouse dy becomes a scroll axis). If a signature" >&2
        echo "  legitimately changed, the schema doc" >&2
        echo "  design/ipc/hid-event-stream-session.md §3 must be rewritten" >&2
        echo "  first." >&2
        exit 1
    fi
}
hesch_pin_one 'pub let hid_event_stream_ch_ev_valid : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_type : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_payload_reserved_ok : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_pack_kbd_press : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_pack_kbd_release : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_kbd_scancode : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_pack_mouse_move : (u64, u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_mouse_dx : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_mouse_dy : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_pack_mouse_click : (u64, u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_click_button : (u64) -> u64'
hesch_pin_one 'pub let hid_event_stream_ch_click_edge : (u64) -> u64'
echo "[hid-stream-schema-confine] event validator, type extractor, reserved-bits gate, four packers and five unpackers arities pinned"

# ---------------------------------------------------------------------------
# R32.M5-001 (#1133): THE SENSOR CHANNEL CAPABILITY.
#
# Same shape as the HID event path. Two claims:
#
# (a) _sensor_channel_table is the only place in the kernel where a
#     sensor subscription's (endpoint_id, sensor_type, rate_hz,
#     subscriber_pid) tuple lives. A second writer could install a
#     subscription with no gate involved and no audit record, and every
#     future sensor-hub delivery would then be one made against a
#     subscription the derivation lattice never blessed.
#     _sensor_channel_stats is confined for the sibling reason.
#
# (b) Arity pins. The static identity (endpoint, type, rate, pid) comes
#     from the ROW at mint, so the slot-arity-one resolvers take a
#     capability and nothing else. `rate_of_slot(slot, assumed)` reads
#     as a convenience and is a way to make a driver think one
#     subscription wants samples faster than the mint approved.
SENSOR_CHANNEL_SRC="${REPO_ROOT}/src/kernel/core/cap/kind_sensor_channel.pdx"
if [[ ! -f "${SENSOR_CHANNEL_SRC}" ]]; then
    echo "[sensor-channel-confine] FAIL - ${SENSOR_CHANNEL_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_sensor_channel_table' 'core/cap/kind_sensor_channel.o'
ec_confine_one '_sensor_channel_stats' 'core/cap/kind_sensor_channel.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/cap/kind_sensor_channel.pdx §1 for why the" >&2
    echo "  row table has exactly one writer." >&2
    exit 1
fi
echo "[sensor-channel-confine] sensor channel rows and counter confined"

sench_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${SENSOR_CHANNEL_SRC}"; then
        echo "[sensor-channel-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A SENSOR SUBSCRIPTION'S ENDPOINT, TYPE, RATE AND PID COME" >&2
        echo "  FROM THE CAPABILITY'S OWN ROW AND NEVER FROM A CALLER. An" >&2
        echo "  extra parameter on any of these makes 'route my subscription" >&2
        echo "  as if it were somebody else's' expressible, and the two ways" >&2
        echo "  that goes wrong are silent sample misdelivery and silent" >&2
        echo "  rate-budget overrun. If a signature legitimately changed," >&2
        echo "  the confinement argument in src/kernel/core/cap/" >&2
        echo "  kind_sensor_channel.pdx §1 must be rewritten first." >&2
        exit 1
    fi
}
sench_pin_one 'pub let sensor_channel_channel_of_slot : (u64) -> u64'
sench_pin_one 'pub let sensor_channel_type_of_slot : (u64) -> u64'
sench_pin_one 'pub let sensor_channel_rate_of_slot : (u64) -> u64'
sench_pin_one 'pub let sensor_channel_pid_of_slot : (u64) -> u64'
sench_pin_one 'pub let sensor_channel_row_of_slot : (u64) -> u64'
sench_pin_one 'pub let sensor_channel_sample_note : (u64) -> u64'
sench_pin_one 'pub let sensor_channel_type_valid : (u64) -> u64'
sench_pin_one 'pub let sensor_channel_rate_valid : (u64) -> u64'
echo "[sensor-channel-confine] static-identity resolvers and validators arities pinned"

# A TYPE, RATE, PID OR ENDPOINT THAT CAN BE CHANGED IS NOT A
# SUBSCRIPTION. §3 states the discipline explicitly; these are the
# names a future "let a subscriber change class or rate after the fact"
# change would be given.
if grep -qE 'sensor_channel_(set_type|type_set|set_rate|rate_set|widen_rate|raise_rate|set_pid|pid_set|set_channel|channel_set)' "${SENSOR_CHANNEL_SRC}"; then
    echo "[sensor-channel-confine] FAIL - a static-identity-mutating primitive" >&2
    echo "  was added to the sensor channel kind." >&2
    echo "" >&2
    echo "  sensor_type, rate_hz, subscriber_pid and event_channel_key are" >&2
    echo "  set once, by the mint, and there is no primitive that changes" >&2
    echo "  them; see src/kernel/core/cap/kind_sensor_channel.pdx §3." >&2
    echo "  A RATE THAT CAN BE RAISED WOULD LET A SUBSCRIBER GAIN A SHARE" >&2
    echo "  OF THE DRIVER'S SAMPLE BUDGET NO GATE VALIDATED; rate changes" >&2
    echo "  are expressible by revoking and minting a fresh row." >&2
    exit 1
fi
echo "[sensor-channel-confine] no static-identity-mutating primitive"

# ---------------------------------------------------------------------------
# R32.M5-002 (#1134): SENSOR HUB DRIVER STATE + ARITY PINS.
#
# Two symbols to confine (same shape as backlight_pwm):
#
#   _sensor_hub_bound  -- the one flag that says the scaffold has been bound
#   _sensor_hub_stats  -- the counters
SENSOR_HUB_SRC="${REPO_ROOT}/src/kernel/core/drivers/sensor_hub.pdx"
if [[ ! -f "${SENSOR_HUB_SRC}" ]]; then
    echo "[sensor-hub-confine] FAIL - ${SENSOR_HUB_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_sensor_hub_bound' 'core/drivers/sensor_hub.o'
ec_confine_one '_sensor_hub_stats' 'core/drivers/sensor_hub.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/drivers/sensor_hub.pdx §2 for why the bind" >&2
    echo "  flag and stats have exactly one writer." >&2
    exit 1
fi
echo "[sensor-hub-confine] bind flag and stats confined"

shub_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${SENSOR_HUB_SRC}"; then
        echo "[sensor-hub-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE THREE MOUNT SEAMS TAKE A SAMPLE AND NOTHING ELSE. An" >&2
        echo "  extra parameter on any of them lets a caller choose which" >&2
        echo "  sensor type this publish counts against, and one call" >&2
        echo "  publishing under two names would let a subscriber count" >&2
        echo "  against a rate budget for a class it never asked about." >&2
        echo "  The bind seam is arity ZERO on purpose (§2/§4): a real" >&2
        echo "  bind takes an MMIO / I²C-HID capability, and leaving the" >&2
        echo "  seam empty stops a caller pretending a capability is there." >&2
        exit 1
    fi
}
shub_pin_one 'pub let sensor_hub_bind : () -> u64'
shub_pin_one 'pub let sensor_hub_sample_als : (u64) -> u64'
shub_pin_one 'pub let sensor_hub_sample_accel : (u64) -> u64'
shub_pin_one 'pub let sensor_hub_sample_gyro : (u64) -> u64'
shub_pin_one 'pub let sensor_hub_arbitrated : () -> u64'
echo "[sensor-hub-confine] bind arity zero, three mount seams arity one, honesty pin arity zero"

# ---------------------------------------------------------------------------
# R32.M5-003 (#1135): SENSOR READ CHANNEL SCHEMA ARITY PINS.
#
# The schema has no storage of its own -- pure pack/unpack -- so there
# is no _table to confine. What there IS to defend is the arity of every
# packer and unpacker. A third parameter on pack_subscribe is a caller-
# supplied option that widens the sample budget; a fourth on
# pack_sample_word1 is a caller-supplied fourth axis (magnetometer)
# that quietly widens the sensor into a class no subscriber asked
# about. Neither is expressible against a pinned signature.
SRCH_SRC="${REPO_ROOT}/src/kernel/core/ipc/sensor_read_channel.pdx"
if [[ ! -f "${SRCH_SRC}" ]]; then
    echo "[sensor-schema-confine] FAIL - ${SRCH_SRC} not found" >&2
    exit 1
fi
srch_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${SRCH_SRC}"; then
        echo "[sensor-schema-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A SENSOR READ CHANNEL FIELD IS DECIDED BY THE SCHEMA AND" >&2
        echo "  NEVER BY A CALLER. An extra parameter on any packer or" >&2
        echo "  unpacker makes 'pack a field my subscriber does not know" >&2
        echo "  about' or 'extract a bit range my packer never wrote to'" >&2
        echo "  expressible, and both ways that goes wrong silently reads" >&2
        echo "  or writes the wrong bits (a rate becomes an option tag, a" >&2
        echo "  z-axis becomes a fourth-sensor field). If a signature" >&2
        echo "  legitimately changed, the schema doc" >&2
        echo "  design/ipc/sensor-read-channel-schema.md §3 must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
srch_pin_one 'pub let sensor_read_ch_ev_valid : (u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_type : (u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_pack_subscribe : (u64, u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_sub_type : (u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_sub_rate : (u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_pack_unsubscribe : () -> u64'
srch_pin_one 'pub let sensor_read_ch_pack_sample_word0 : (u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_pack_sample_word1 : (u64, u64, u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_sample_ts : (u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_sample_x : (u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_sample_y : (u64) -> u64'
srch_pin_one 'pub let sensor_read_ch_sample_z : (u64) -> u64'
echo "[sensor-schema-confine] event validator, subscribe pair, unsubscribe zero, two sample packers and four sample unpackers arities pinned"

# ---------------------------------------------------------------------------
# R31.M3-002 (#1100): BATTERY CHANNEL SCHEMA ARITY PINS.
#
# The schema has no storage of its own -- it is pure pack/unpack -- so
# there is no _table to confine. What there IS to defend is the arity of
# every packer and unpacker. A fifth parameter on pack_reply is a caller-
# supplied scale that turns a percent into per-mille and truncates it to
# a byte; a fourth parameter on any unpacker is a caller-supplied bit
# width that reads a different field from the same word. Neither is
# expressible against a pinned signature.
BCH_SRC="${REPO_ROOT}/src/kernel/core/ipc/battery_channel.pdx"
if [[ ! -f "${BCH_SRC}" ]]; then
    echo "[battery-channel-confine] FAIL - ${BCH_SRC} not found" >&2
    exit 1
fi
bch_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${BCH_SRC}"; then
        echo "[battery-channel-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A BATTERY CHANNEL FIELD IS DECIDED BY THE SCHEMA AND NEVER BY" >&2
        echo "  A CALLER. An extra parameter on any packer or unpacker makes" >&2
        echo "  'pack a field my subscriber does not know about' or 'extract" >&2
        echo "  a bit range my packer never wrote to' expressible, and both" >&2
        echo "  ways that goes wrong silently reads or writes the wrong bits." >&2
        echo "  If a signature legitimately changed, the schema doc" >&2
        echo "  design/ipc/battery-channel-schema.md §3/§4 must be rewritten" >&2
        echo "  first." >&2
        exit 1
    fi
}
bch_pin_one 'pub let battery_channel_op_valid : (u64) -> u64'
bch_pin_one 'pub let battery_channel_ev_valid : (u64) -> u64'
bch_pin_one 'pub let battery_channel_pack_reply : (u64, u64, u64, u64) -> u64'
bch_pin_one 'pub let battery_channel_reply_percent : (u64) -> u64'
bch_pin_one 'pub let battery_channel_reply_state : (u64) -> u64'
bch_pin_one 'pub let battery_channel_reply_voltage : (u64) -> u64'
bch_pin_one 'pub let battery_channel_reply_reports : (u64) -> u64'
bch_pin_one 'pub let battery_channel_pack_state_changed : (u64, u64, u64, u64) -> u64'
bch_pin_one 'pub let battery_channel_pack_low_warning : (u64, u64, u64) -> u64'
echo "[battery-channel-confine] pack and unpack arities pinned"

# ---------------------------------------------------------------------------
# R31.M5-002 (#1107): BACKLIGHT CHANNEL SCHEMA ARITY PINS.
#
# Same shape as the battery-channel-confine block: the schema has no
# storage of its own -- it is pure pack/unpack -- so there is no _table
# to confine. What there IS to defend is the arity of every packer and
# unpacker. A third parameter on pack_get_reply is a caller-supplied
# ceiling that reaches the wire; a second parameter on pack_set_request
# is a caller-supplied brightness_max the packer would silently compare
# against instead of leaving that gate to backlight_report_install.
# Neither is expressible against a pinned signature.
BCHL_SRC="${REPO_ROOT}/src/kernel/core/ipc/backlight_channel.pdx"
if [[ ! -f "${BCHL_SRC}" ]]; then
    echo "[backlight-channel-confine] FAIL - ${BCHL_SRC} not found" >&2
    exit 1
fi
bchl_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${BCHL_SRC}"; then
        echo "[backlight-channel-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A BACKLIGHT CHANNEL FIELD IS DECIDED BY THE SCHEMA AND NEVER BY" >&2
        echo "  A CALLER. An extra parameter on any packer or unpacker makes" >&2
        echo "  'pack a field my subscriber does not know about' or 'extract" >&2
        echo "  a bit range my packer never wrote to' expressible, and both" >&2
        echo "  ways that goes wrong silently reads or writes the wrong bits." >&2
        echo "  If a signature legitimately changed, the schema doc" >&2
        echo "  design/ipc/backlight-channel-schema.md §3/§4 must be rewritten" >&2
        echo "  first." >&2
        exit 1
    fi
}
bchl_pin_one 'pub let backlight_channel_op_valid : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_ev_valid : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_pack_get_reply : (u64, u64) -> u64'
bchl_pin_one 'pub let backlight_channel_get_reply_current : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_get_reply_reports : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_pack_range_reply : (u64, u64) -> u64'
bchl_pin_one 'pub let backlight_channel_range_reply_min : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_range_reply_max : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_pack_set_request : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_set_request_level : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_pack_brightness_changed : (u64, u64) -> u64'
bchl_pin_one 'pub let backlight_channel_bc_prev : (u64) -> u64'
bchl_pin_one 'pub let backlight_channel_bc_new : (u64) -> u64'
echo "[backlight-channel-confine] pack and unpack arities pinned"

# ---------------------------------------------------------------------------
# R31.M5-003 (#1108): PWM BACKLIGHT DRIVER STATE + ARITY PINS.
#
# Two symbols to confine, in the same shape as ec_access_state and
# battery_monitor's per-row tables:
#
#   _backlight_pwm_bound  -- the one flag that says the scaffold has
#                            been bound
#   _backlight_pwm_stats  -- the counters
#
# The bound flag is the load-bearing one. §2 of backlight_pwm.pdx says
# there is ONE WRITER (backlight_pwm_bind), and the whole discipline
# rests on that: a stray relocation against the flag would be a second
# path claiming this driver was initialised without any capability
# check, and when the gated:hardware milestone plumbs the KIND_MMIO_
# WINDOW capability through bind the flag becomes the gate for the
# write path -- a spuriously-set flag then lets writes touch registers
# no capability authorised.
#
# The stats counter is confined for the sibling reason ec_event's,
# thermal_zone's, battery's and cooling's counters are: they are the
# only evidence that the seam was exercised without a real bus
# transaction landing, and evidence a second object can write is not
# evidence.
#
# Arity pins as well: bind/bound/writes at ZERO (any argument on bind
# would let a caller declare a window the capability does not name);
# write at ONE (a second argument is a caller-supplied ceiling or
# offset reaching the register value); arbitrated at ZERO (a value
# a boot pin can assert on, per the honesty argument in §4).
BLPWM_OWNER="${BUILD_DIR}/core/drivers/backlight_pwm.o"
BLPWM_SRC="${REPO_ROOT}/src/kernel/core/drivers/backlight_pwm.pdx"
if [[ ! -f "${BLPWM_SRC}" ]]; then
    echo "[backlight-pwm-confine] FAIL - ${BLPWM_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${BLPWM_OWNER}" ]]; then
    echo "[backlight-pwm-confine] FAIL: ${BLPWM_OWNER} not built" >&2
    exit 1
fi
blpwm_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${BLPWM_OWNER}" "${sym}"; then
        echo "[backlight-pwm-confine] FAIL: backlight_pwm.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${BLPWM_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[backlight-pwm-confine] FAIL - objects other than" >&2
        echo "  core/drivers/backlight_pwm.o relocate against ${sym}:${strays}" >&2
        echo "  Only backlight_pwm_bind may write the bound flag, and only" >&2
        echo "  backlight_pwm_bind/write may write the stats counters. See" >&2
        echo "  src/kernel/core/drivers/backlight_pwm.pdx §2." >&2
        exit 1
    fi
}
blpwm_confine_one '_backlight_pwm_bound'
blpwm_confine_one '_backlight_pwm_stats'
echo "[backlight-pwm-confine] bound flag and stats confined"

blpwm_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${BLPWM_SRC}"; then
        echo "[backlight-pwm-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A PWM BACKLIGHT DRIVER BIND TAKES NO CALLER ARGUMENTS AT THIS" >&2
        echo "  MILESTONE. An extra parameter on any of these is how a" >&2
        echo "  caller-supplied MMIO window or ceiling would reach the register" >&2
        echo "  write path; both are set-once facts the row and the future" >&2
        echo "  KIND_MMIO_WINDOW capability alone define. If a signature" >&2
        echo "  legitimately changed, §2 and §4 of backlight_pwm.pdx must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
blpwm_pin_one 'pub let backlight_pwm_bind : () -> u64'
blpwm_pin_one 'pub let backlight_pwm_bound : () -> u64'
blpwm_pin_one 'pub let backlight_pwm_arbitrated : () -> u64'
blpwm_pin_one 'pub let backlight_pwm_write : (u64) -> u64'
blpwm_pin_one 'pub let backlight_pwm_writes : () -> u64'
echo "[backlight-pwm-confine] bind, bound, arbitrated, write and writes arities pinned"

# ---------------------------------------------------------------------------
# R31.M5-004 (#1109): DPAUX BACKLIGHT DRIVER STATE + ARITY PINS.
#
# Symmetric to backlight-pwm-confine. The DPAUX driver has ONE EXTRA
# refusal code -- BACKLIGHT_DPAUX_FALLBACK_ACPI -- that names the
# outcome for a panel that does not advertise VESA eDP AUX backlight
# capability; the compositor keys off this sentinel to bind an ACPI
# backend instead. The confinement discipline is unchanged: one writer
# of the bound flag, no strays against the stats counters, and the
# same five signatures pinned at the same arities.
BLDPX_OWNER="${BUILD_DIR}/core/drivers/backlight_dpaux.o"
BLDPX_SRC="${REPO_ROOT}/src/kernel/core/drivers/backlight_dpaux.pdx"
if [[ ! -f "${BLDPX_SRC}" ]]; then
    echo "[backlight-dpaux-confine] FAIL - ${BLDPX_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${BLDPX_OWNER}" ]]; then
    echo "[backlight-dpaux-confine] FAIL: ${BLDPX_OWNER} not built" >&2
    exit 1
fi
bldpx_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${BLDPX_OWNER}" "${sym}"; then
        echo "[backlight-dpaux-confine] FAIL: backlight_dpaux.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${BLDPX_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[backlight-dpaux-confine] FAIL - objects other than" >&2
        echo "  core/drivers/backlight_dpaux.o relocate against ${sym}:${strays}" >&2
        echo "  Only backlight_dpaux_bind may write the bound flag, and only" >&2
        echo "  backlight_dpaux_bind/write may write the stats counters. See" >&2
        echo "  src/kernel/core/drivers/backlight_dpaux.pdx §2." >&2
        exit 1
    fi
}
bldpx_confine_one '_backlight_dpaux_bound'
bldpx_confine_one '_backlight_dpaux_stats'
echo "[backlight-dpaux-confine] bound flag and stats confined"

bldpx_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${BLDPX_SRC}"; then
        echo "[backlight-dpaux-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A DPAUX BACKLIGHT DRIVER BIND TAKES NO CALLER ARGUMENTS AT THIS" >&2
        echo "  MILESTONE. An extra parameter on any of these is how a" >&2
        echo "  caller-supplied AUX channel or panel-capability claim would" >&2
        echo "  reach the write path; both are facts the future KIND_AUX_" >&2
        echo "  CHANNEL capability and a DPCD 0x701 probe alone define." >&2
        echo "  If a signature legitimately changed, §2 and §4 of" >&2
        echo "  backlight_dpaux.pdx must be rewritten first." >&2
        exit 1
    fi
}
bldpx_pin_one 'pub let backlight_dpaux_bind : () -> u64'
bldpx_pin_one 'pub let backlight_dpaux_bound : () -> u64'
bldpx_pin_one 'pub let backlight_dpaux_arbitrated : () -> u64'
bldpx_pin_one 'pub let backlight_dpaux_write : (u64) -> u64'
bldpx_pin_one 'pub let backlight_dpaux_writes : () -> u64'
echo "[backlight-dpaux-confine] bind, bound, arbitrated, write and writes arities pinned"

# ---------------------------------------------------------------------------
# R31.M6-001/002/003 (#1111/#1112/#1113): HOT-KEY DISPATCH TABLE CONFINEMENT.
#
# Two symbols to confine to the owning object:
#
#   _hotkey_dispatch_table  — 256 (query byte, sink, action) entries.
#                             The only place in the kernel where a hot-
#                             key meaning lives. A second writer could
#                             silently remap Fn+F4 from VOLUME_MUTE to
#                             BACKLIGHT_UP with no capability involved
#                             and no refusal recorded -- exactly the
#                             failure §2 of core/input/hotkey_dispatch.pdx
#                             exists to prevent.
#
#   _hotkey_dispatch_stats  — the per-sink routing counters. Evidence a
#                             hot-key was decoded and routed to VOLUME/
#                             BACKLIGHT/MEDIA (or refused as UNMAPPED),
#                             and evidence a second object can write is
#                             not evidence -- the sibling reason
#                             ec_event_stats and backlight_stats are
#                             confined to their own owners.
HK_OWNER="${BUILD_DIR}/core/input/hotkey_dispatch.o"
HK_SRC="${REPO_ROOT}/src/kernel/core/input/hotkey_dispatch.pdx"
if [[ ! -f "${HK_SRC}" ]]; then
    echo "[hotkey-confine] FAIL - ${HK_SRC} not found" >&2
    exit 1
fi
ec_confine_one '_hotkey_dispatch_table' 'core/input/hotkey_dispatch.o'
ec_confine_one '_hotkey_dispatch_stats' 'core/input/hotkey_dispatch.o'
if [[ "${EC_CONFINE_OK}" != "1" ]]; then
    echo "  See src/kernel/core/input/hotkey_dispatch.pdx §2 for why" >&2
    echo "  the dispatch table has exactly one writer." >&2
    exit 1
fi
echo "[hotkey-confine] dispatch table and counters confined"

# THE MONOTONE MEANING TABLE — the same shape as ec_event's meaning table
# and for the same reason: the table starts EMPTY and only FILLS, and an
# entry that has a (sink, action) cannot acquire a different one while
# it is bound. hotkey_dispatch_install is the only per-entry writer and
# it REFUSES a change of meaning; the only wholesale clear is
# hotkey_dispatch_reset, which is a boot/teardown operation.
#
# What a demotion primitive would cost: every downstream routing
# decision is taken from the (sink, action) pair, so a byte silently
# remapped from VOLUME_MUTE to BACKLIGHT_UP inverts a physical action
# with no symptom. The natural names for the mutant are the ones being
# searched for.
if grep -qE 'hotkey_dispatch_(remap|unmap|override|force)' "${HK_SRC}"; then
    echo "[hotkey-confine] FAIL - a demotion primitive was added to the" >&2
    echo "  hot-key dispatch table. It starts empty and only ever fills," >&2
    echo "  and an installed meaning cannot change while it is bound; see" >&2
    echo "  src/kernel/core/input/hotkey_dispatch.pdx §2" >&2
    echo "  A HOT-KEY MEANING MUST NOT BE SILENTLY REDEFINED." >&2
    exit 1
fi
echo "[hotkey-confine] hot-key dispatch table has no demotion primitive"

hk_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HK_SRC}"; then
        echo "[hotkey-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A HOT-KEY BYTE'S MEANING IS THE ONLY INPUT TO THE ROUTE, AND" >&2
        echo "  A BACKLIGHT STEP TAKES A CAPABILITY AND NOTHING ELSE. An" >&2
        echo "  extra parameter on any of these is how a caller-supplied" >&2
        echo "  sink override or brightness ceiling would reach the actuator" >&2
        echo "  path -- and on backlight, a caller-controlled ceiling is a" >&2
        echo "  way to blind an operator on a panel whose electronics" >&2
        echo "  cannot survive the substituted duty cycle. If a signature" >&2
        echo "  legitimately changed, §0.1 and §2 of hotkey_dispatch.pdx" >&2
        echo "  must be rewritten first." >&2
        exit 1
    fi
}
hk_pin_one 'pub let hotkey_dispatch_install : (u64, u64, u64) -> u64'
hk_pin_one 'pub let hotkey_dispatch_sink_of : (u64) -> u64'
hk_pin_one 'pub let hotkey_dispatch_action_of : (u64) -> u64'
hk_pin_one 'pub let hotkey_dispatch_route : (u64) -> u64'
hk_pin_one 'pub let hotkey_dispatch_backlight_step : (u64, u64, u64, u64) -> u64'
echo "[hotkey-confine] install, lookup, route and backlight-step arities pinned"

# ---------------------------------------------------------------------------
# R31.M3-003 (#1101): BATTERY MONITOR STATE + ARITY PINS.
#
# Three symbols to confine:
#   _battery_monitor_prev      — the per-row previous-sample cache
#   _battery_monitor_flags     — the per-row pending-flag word
#   _battery_monitor_threshold — the low-warning threshold
#
# The threshold is the most load-bearing of the three. §2 of
# core/policy/battery_monitor.pdx says it is monotone -- a value that
# can only be set once between resets -- and the whole discipline is
# the threshold's ONE WRITER (battery_monitor_threshold_install) plus
# the sole wholesale-reset (battery_monitor_table_reset). A second
# object relocating against the threshold would be an object that can
# raise or lower it with no capability involved, and a hostile process
# holding that path can suppress a LOW_WARNING on a perpetually-
# charging pack (raise the threshold to 100) or fire one on every
# sample (raise it to 100 then drop to 0).
#
# The prev-sample cache is confined for the sibling reason: a second
# writer computes a different account of the pack's last state, and the
# two disagree by exactly one transition every time a subscriber wants
# them to agree (§1). The flag word is the same argument at one remove
# -- a second setter would raise F_STATE_CHANGED on ticks where the
# state did not change.
#
# Arity pins as well: tick pins at ARITY FOUR (a fifth argument would
# be a per-tick threshold, defeating §2's monotonicity in one call
# site); threshold_install at ONE (a second argument is a caller
# supplied override); ack at TWO (row and mask, no third argument that
# could reach LOW_LATCHED).
BM_OWNER="${BUILD_DIR}/core/policy/battery_monitor.o"
BM_SRC="${REPO_ROOT}/src/kernel/core/policy/battery_monitor.pdx"
if [[ ! -f "${BM_SRC}" ]]; then
    echo "[battery-monitor-confine] FAIL - ${BM_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${BM_OWNER}" ]]; then
    echo "[battery-monitor-confine] FAIL: ${BM_OWNER} not built" >&2
    exit 1
fi
bm_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${BM_OWNER}" "${sym}"; then
        echo "[battery-monitor-confine] FAIL: battery_monitor.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${BM_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[battery-monitor-confine] FAIL - objects other than" >&2
        echo "  core/policy/battery_monitor.o relocate against ${sym}:${strays}" >&2
        echo "  Only battery_monitor_tick/_threshold_install/_ack/_table_reset may" >&2
        echo "  write monitor state, and each of those is behind a gate in" >&2
        echo "  core/policy/battery_monitor.pdx. See §1/§2." >&2
        exit 1
    fi
}
bm_confine_one '_battery_monitor_prev'
bm_confine_one '_battery_monitor_flags'
bm_confine_one '_battery_monitor_threshold'
echo "[battery-monitor-confine] prev-sample cache, pending flags and threshold confined"

bm_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${BM_SRC}"; then
        echo "[battery-monitor-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  A BATTERY MONITOR DECISION IS TAKEN FROM THE ROW AND THE" >&2
        echo "  INSTALLED THRESHOLD, NEVER FROM A CALLER. An extra parameter" >&2
        echo "  on tick is how a per-tick threshold reaches the LOW crossing," >&2
        echo "  defeating §2's monotonicity in one call site; an extra" >&2
        echo "  parameter on threshold_install is how a caller-supplied" >&2
        echo "  override reaches the stored value without the monotonicity" >&2
        echo "  gate seeing it; an extra parameter on ack is how a caller" >&2
        echo "  could reach LOW_LATCHED (bit 16) and re-arm the warning" >&2
        echo "  without the pack recovering. If a signature legitimately" >&2
        echo "  changed, §1/§2 of battery_monitor.pdx must be rewritten first." >&2
        exit 1
    fi
}
bm_pin_one 'pub let battery_monitor_tick : (u64, u64, u64, u64) -> u64'
bm_pin_one 'pub let battery_monitor_threshold_install : (u64) -> u64'
bm_pin_one 'pub let battery_monitor_threshold : () -> u64'
bm_pin_one 'pub let battery_monitor_ack : (u64, u64) -> u64'
bm_pin_one 'pub let battery_monitor_flags : (u64) -> u64'
bm_pin_one 'pub let battery_monitor_seen : (u64) -> u64'
echo "[battery-monitor-confine] tick, threshold, ack, flags and seen arities pinned"

# ---------------------------------------------------------------------------
# R32.M1-001 (#1115): I²C-HID TRANSPORT SCAFFOLD STATE + ARITY PINS.
#
# Same shape as [backlight-pwm-confine] and [backlight-dpaux-confine]:
# a bind latch, a stashed opaque bus handle, a stashed descriptor
# register address and the stats counters, each with exactly one
# legitimate writer (i2c_hid_transport_bind for latches; the read/write
# seams for counters). The load-bearing symbol is _i2c_hid_transport_bus:
# a stray writer would be a second path stashing a bus handle no
# capability named, and when R32.M2 plumbs the KIND_I2C_BUS-shaped
# transfer through this transport, the spuriously-set handle would let
# transfers reach a controller the capability did not authorise.
I2CHID_TR_OWNER="${BUILD_DIR}/core/drivers/i2c_hid/transport.o"
I2CHID_TR_SRC="${REPO_ROOT}/src/kernel/core/drivers/i2c_hid/transport.pdx"
if [[ ! -f "${I2CHID_TR_SRC}" ]]; then
    echo "[i2c-hid-transport-confine] FAIL - ${I2CHID_TR_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${I2CHID_TR_OWNER}" ]]; then
    echo "[i2c-hid-transport-confine] FAIL: ${I2CHID_TR_OWNER} not built" >&2
    exit 1
fi
i2chid_tr_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${I2CHID_TR_OWNER}" "${sym}"; then
        echo "[i2c-hid-transport-confine] FAIL: transport.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${I2CHID_TR_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-hid-transport-confine] FAIL - objects other than" >&2
        echo "  core/drivers/i2c_hid/transport.o relocate against ${sym}:${strays}" >&2
        echo "  Only i2c_hid_transport_bind may write the bind latch, and only" >&2
        echo "  the read/write seams may write the stats counters. See" >&2
        echo "  src/kernel/core/drivers/i2c_hid/transport.pdx §2." >&2
        exit 1
    fi
}
i2chid_tr_confine_one '_i2c_hid_transport_bound'
i2chid_tr_confine_one '_i2c_hid_transport_bus'
i2chid_tr_confine_one '_i2c_hid_transport_hid_desc_addr'
i2chid_tr_confine_one '_i2c_hid_transport_stats'
echo "[i2c-hid-transport-confine] bind latch, bus handle, desc addr and stats confined"

i2chid_tr_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${I2CHID_TR_SRC}"; then
        echo "[i2c-hid-transport-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  AN I²C-HID TRANSPORT BIND TAKES THE OPAQUE BUS HANDLE AND THE" >&2
        echo "  ACPI-SUPPLIED DESCRIPTOR REGISTER, NOTHING ELSE. An extra" >&2
        echo "  parameter on bind is how a caller-supplied controller BASE or" >&2
        echo "  EXTENT would reach the transfer path when R32.M2 wires it --" >&2
        echo "  exactly what §2 of ec_access.pdx exists to prevent. If a" >&2
        echo "  signature legitimately changed, §0/§2/§4 of transport.pdx" >&2
        echo "  must be rewritten first." >&2
        exit 1
    fi
}
i2chid_tr_pin_one 'pub let i2c_hid_transport_bind : (u64, u64) -> u64'
i2chid_tr_pin_one 'pub let i2c_hid_transport_bound : () -> u64'
i2chid_tr_pin_one 'pub let i2c_hid_transport_arbitrated : () -> u64'
i2chid_tr_pin_one 'pub let i2c_hid_transport_read : (u64, u64) -> u64'
i2chid_tr_pin_one 'pub let i2c_hid_transport_write : (u64, u64) -> u64'
i2chid_tr_pin_one 'pub let i2c_hid_transport_reads : () -> u64'
i2chid_tr_pin_one 'pub let i2c_hid_transport_writes : () -> u64'
i2chid_tr_pin_one 'pub let i2c_hid_transport_bus : () -> u64'
i2chid_tr_pin_one 'pub let i2c_hid_transport_hid_desc_addr : () -> u64'
echo "[i2c-hid-transport-confine] bind, seams and accessor arities pinned"

# ---------------------------------------------------------------------------
# R32.M1-002 (#1116): I²C-HID DESCRIPTOR SCAFFOLD STATE + ARITY PINS.
#
# The valid latch and the four parsed fields (report_len, input_reg,
# max_input, vendor_product), each confined to descriptor.o. The
# load-bearing symbol is _i2c_hid_desc_vendor_product: a stray writer
# would be a second path claiming a different (vendor, product) key,
# and #1119's quirk table keys off exactly this value to decide whether
# to issue a reset before the first report -- a spuriously-changed
# identifier would misclassify the device and skip the reset.
I2CHID_DESC_OWNER="${BUILD_DIR}/core/drivers/i2c_hid/descriptor.o"
I2CHID_DESC_SRC="${REPO_ROOT}/src/kernel/core/drivers/i2c_hid/descriptor.pdx"
if [[ ! -f "${I2CHID_DESC_SRC}" ]]; then
    echo "[i2c-hid-descriptor-confine] FAIL - ${I2CHID_DESC_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${I2CHID_DESC_OWNER}" ]]; then
    echo "[i2c-hid-descriptor-confine] FAIL: ${I2CHID_DESC_OWNER} not built" >&2
    exit 1
fi
i2chid_desc_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${I2CHID_DESC_OWNER}" "${sym}"; then
        echo "[i2c-hid-descriptor-confine] FAIL: descriptor.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${I2CHID_DESC_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-hid-descriptor-confine] FAIL - objects other than" >&2
        echo "  core/drivers/i2c_hid/descriptor.o relocate against ${sym}:${strays}" >&2
        echo "  Only i2c_hid_descriptor_install may write parsed fields. See" >&2
        echo "  src/kernel/core/drivers/i2c_hid/descriptor.pdx §2." >&2
        exit 1
    fi
}
i2chid_desc_confine_one '_i2c_hid_desc_valid'
i2chid_desc_confine_one '_i2c_hid_desc_report_len'
i2chid_desc_confine_one '_i2c_hid_desc_input_reg'
i2chid_desc_confine_one '_i2c_hid_desc_max_input'
i2chid_desc_confine_one '_i2c_hid_desc_vendor_product'
echo "[i2c-hid-descriptor-confine] valid latch and parsed fields confined"

i2chid_desc_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${I2CHID_DESC_SRC}"; then
        echo "[i2c-hid-descriptor-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE DESCRIPTOR INSTALL SEAM TAKES THE FOUR FIELDS THE HID PATH" >&2
        echo "  CONSUMES, NEVER FEWER AND NEVER MORE. Widening it would let a" >&2
        echo "  caller set fields no live parser would; narrowing it would" >&2
        echo "  strand the ISR's max_input ceiling or the quirk-table key." >&2
        echo "  If a signature legitimately changed, §1/§2/§3 of" >&2
        echo "  descriptor.pdx must be rewritten first." >&2
        exit 1
    fi
}
i2chid_desc_pin_one 'pub let i2c_hid_descriptor_install : (u64, u64, u64, u64) -> u64'
i2chid_desc_pin_one 'pub let i2c_hid_descriptor_valid : () -> u64'
i2chid_desc_pin_one 'pub let i2c_hid_descriptor_fetch : () -> u64'
i2chid_desc_pin_one 'pub let i2c_hid_descriptor_report_len : () -> u64'
i2chid_desc_pin_one 'pub let i2c_hid_descriptor_input_reg : () -> u64'
i2chid_desc_pin_one 'pub let i2c_hid_descriptor_max_input : () -> u64'
i2chid_desc_pin_one 'pub let i2c_hid_descriptor_vendor_product : () -> u64'
echo "[i2c-hid-descriptor-confine] install, fetch, valid and accessor arities pinned"

# ---------------------------------------------------------------------------
# R32.M1-003 (#1117): I²C-HID ISR SCAFFOLD STATE + ARITY PINS.
#
# Two symbols to confine, in the same shape as backlight-pwm-confine.
# The bind latch is the load-bearing one: §1 of isr.pdx says
# i2c_hid_isr_bind is the ONE writer, and when R32.M2 plumbs
# gpio_pad_edge_subscribe through the bind, a spuriously-set bound flag
# would let the ISR's assert path invoke transport reads for a pad no
# capability named. Arity of bind is ZERO for the mirror reason.
I2CHID_ISR_OWNER="${BUILD_DIR}/core/drivers/i2c_hid/isr.o"
I2CHID_ISR_SRC="${REPO_ROOT}/src/kernel/core/drivers/i2c_hid/isr.pdx"
if [[ ! -f "${I2CHID_ISR_SRC}" ]]; then
    echo "[i2c-hid-isr-confine] FAIL - ${I2CHID_ISR_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${I2CHID_ISR_OWNER}" ]]; then
    echo "[i2c-hid-isr-confine] FAIL: ${I2CHID_ISR_OWNER} not built" >&2
    exit 1
fi
i2chid_isr_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${I2CHID_ISR_OWNER}" "${sym}"; then
        echo "[i2c-hid-isr-confine] FAIL: isr.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${I2CHID_ISR_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-hid-isr-confine] FAIL - objects other than" >&2
        echo "  core/drivers/i2c_hid/isr.o relocate against ${sym}:${strays}" >&2
        echo "  Only i2c_hid_isr_bind may write the bind latch, and only" >&2
        echo "  the assert seam may write the stats counters. See" >&2
        echo "  src/kernel/core/drivers/i2c_hid/isr.pdx §1." >&2
        exit 1
    fi
}
i2chid_isr_confine_one '_i2c_hid_isr_bound'
i2chid_isr_confine_one '_i2c_hid_isr_stats'
echo "[i2c-hid-isr-confine] bind latch and stats confined"

i2chid_isr_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${I2CHID_ISR_SRC}"; then
        echo "[i2c-hid-isr-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  AN I²C-HID ISR BIND TAKES NO CALLER ARGUMENTS AT THIS" >&2
        echo "  MILESTONE. An extra parameter on bind is how a caller-supplied" >&2
        echo "  GPIO line would reach gpio_pad_edge_subscribe when R32.M2" >&2
        echo "  wires it -- exactly what §2 of gpio_pad.pdx exists to prevent." >&2
        echo "  If a signature legitimately changed, §0/§1 of isr.pdx must" >&2
        echo "  be rewritten first." >&2
        exit 1
    fi
}
i2chid_isr_pin_one 'pub let i2c_hid_isr_bind : () -> u64'
i2chid_isr_pin_one 'pub let i2c_hid_isr_bound : () -> u64'
i2chid_isr_pin_one 'pub let i2c_hid_isr_arbitrated : () -> u64'
i2chid_isr_pin_one 'pub let i2c_hid_isr_assert : () -> u64'
i2chid_isr_pin_one 'pub let i2c_hid_isr_asserts : () -> u64'
echo "[i2c-hid-isr-confine] bind, bound, arbitrated, assert and asserts arities pinned"

# ---------------------------------------------------------------------------
# R32.M1-004 (#1118): I²C-HID RESET + WAKE SCAFFOLD STATE + ARITY PINS.
#
# Two stats arrays, one per seam, each with exactly one legitimate
# writer -- the seam that dispatches. The load-bearing symbol is
# _i2c_hid_reset_stats: a stray writer would be a second path counting
# a reset that never issued, and the R32.M2 bring-up sequence that
# gates on the reset count would advance without the device having
# been reset. Same applies mirror-fashion to _i2c_hid_wake_stats.
#
# The arity pins are the load-bearing check: both seams are ARITY ZERO
# by design. §0 of reset_wake.pdx: a caller-supplied opcode would let
# arbitrary bytes reach wCommandRegister, and the opcode set is
# enumerated by the spec, not negotiated at the driver.
I2CHID_RW_OWNER="${BUILD_DIR}/core/drivers/i2c_hid/reset_wake.o"
I2CHID_RW_SRC="${REPO_ROOT}/src/kernel/core/drivers/i2c_hid/reset_wake.pdx"
if [[ ! -f "${I2CHID_RW_SRC}" ]]; then
    echo "[i2c-hid-reset-wake-confine] FAIL - ${I2CHID_RW_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${I2CHID_RW_OWNER}" ]]; then
    echo "[i2c-hid-reset-wake-confine] FAIL: ${I2CHID_RW_OWNER} not built" >&2
    exit 1
fi
i2chid_rw_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${I2CHID_RW_OWNER}" "${sym}"; then
        echo "[i2c-hid-reset-wake-confine] FAIL: reset_wake.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${I2CHID_RW_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-hid-reset-wake-confine] FAIL - objects other than" >&2
        echo "  core/drivers/i2c_hid/reset_wake.o relocate against ${sym}:${strays}" >&2
        echo "  Only i2c_hid_reset_send may write _i2c_hid_reset_stats, and only" >&2
        echo "  i2c_hid_wake_send may write _i2c_hid_wake_stats. See" >&2
        echo "  src/kernel/core/drivers/i2c_hid/reset_wake.pdx §1." >&2
        exit 1
    fi
}
i2chid_rw_confine_one '_i2c_hid_reset_stats'
i2chid_rw_confine_one '_i2c_hid_wake_stats'
echo "[i2c-hid-reset-wake-confine] reset and wake stats confined"

i2chid_rw_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${I2CHID_RW_SRC}"; then
        echo "[i2c-hid-reset-wake-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  RESET AND WAKE SEAMS ARE ARITY ZERO. A caller-supplied opcode" >&2
        echo "  would let arbitrary bytes reach wCommandRegister -- the opcode" >&2
        echo "  set is enumerated by HID-over-I²C v1.0 §7, not negotiated at" >&2
        echo "  the driver. If a signature legitimately changed, §0/§2 of" >&2
        echo "  reset_wake.pdx must be rewritten first." >&2
        exit 1
    fi
}
i2chid_rw_pin_one 'pub let i2c_hid_reset_send : () -> u64'
i2chid_rw_pin_one 'pub let i2c_hid_wake_send : () -> u64'
i2chid_rw_pin_one 'pub let i2c_hid_reset_arbitrated : () -> u64'
i2chid_rw_pin_one 'pub let i2c_hid_wake_arbitrated : () -> u64'
i2chid_rw_pin_one 'pub let i2c_hid_reset_count : () -> u64'
i2chid_rw_pin_one 'pub let i2c_hid_wake_count : () -> u64'
echo "[i2c-hid-reset-wake-confine] reset, wake, arbitrated and count arities pinned"

# ---------------------------------------------------------------------------
# R32.M1-005 (#1119): I²C-HID QUIRK TABLE CONFINEMENT + ARITY PINS.
#
# The table itself is a COMPILE-TIME CONSTANT in .rodata, and the row
# count is a compile-time constant beside it. The consumer counter is
# an honesty pin: it is 0 today, and the R32.M2 bring-up sequence that
# calls the lookup for real will flip it -- the boot witness assertion
# `quirks_consumed() == 0` fails at that point, forcing the doc to be
# rewritten with the live consumer's shape.
#
# Confinement of _i2c_hid_quirk_table is the load-bearing check: a
# stray writer -- or a stray reader outside quirks.o forming a row
# address of its own -- would be a second path taking the table's
# contents as authority without going through the lookup gate that
# enforces the wildcard order (§1 of quirks.pdx).
#
# Arity pin: lookup is ARITY ONE (packed key). §1 explains why -- a
# caller that supplies (vendor, product) as two arguments could look
# up a device whose descriptor has not been parsed, and the whole
# quirk-lookup discipline is that the caller must have parsed a
# descriptor first.
I2CHID_QK_OWNER="${BUILD_DIR}/core/drivers/i2c_hid/quirks.o"
I2CHID_QK_SRC="${REPO_ROOT}/src/kernel/core/drivers/i2c_hid/quirks.pdx"
if [[ ! -f "${I2CHID_QK_SRC}" ]]; then
    echo "[i2c-hid-quirks-confine] FAIL - ${I2CHID_QK_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${I2CHID_QK_OWNER}" ]]; then
    echo "[i2c-hid-quirks-confine] FAIL: ${I2CHID_QK_OWNER} not built" >&2
    exit 1
fi
i2chid_qk_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${I2CHID_QK_OWNER}" "${sym}"; then
        echo "[i2c-hid-quirks-confine] FAIL: quirks.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${I2CHID_QK_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[i2c-hid-quirks-confine] FAIL - objects other than" >&2
        echo "  core/drivers/i2c_hid/quirks.o relocate against ${sym}:${strays}" >&2
        echo "  The quirk table and its row count are reachable only through" >&2
        echo "  i2c_hid_quirk_lookup / i2c_hid_quirk_count. See" >&2
        echo "  src/kernel/core/drivers/i2c_hid/quirks.pdx §2." >&2
        exit 1
    fi
}
i2chid_qk_confine_one '_i2c_hid_quirk_table'
i2chid_qk_confine_one '_i2c_hid_quirk_count'
i2chid_qk_confine_one '_i2c_hid_quirk_consumers'
echo "[i2c-hid-quirks-confine] table, count and consumer latch confined"

i2chid_qk_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${I2CHID_QK_SRC}"; then
        echo "[i2c-hid-quirks-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE QUIRK LOOKUP TAKES THE PACKED (vendor << 16 | product) KEY" >&2
        echo "  DESCRIPTOR.PDX ALREADY STORES, NOTHING ELSE. A caller that" >&2
        echo "  supplies (vendor, product) as two arguments could look up a" >&2
        echo "  device whose descriptor has not been parsed -- exactly what §2" >&2
        echo "  of descriptor.pdx exists to prevent. If a signature legitimately" >&2
        echo "  changed, §1 of quirks.pdx must be rewritten first." >&2
        exit 1
    fi
}
i2chid_qk_pin_one 'pub let i2c_hid_quirk_lookup : (u64) -> u64'
i2chid_qk_pin_one 'pub let i2c_hid_quirk_count : () -> u64'
i2chid_qk_pin_one 'pub let i2c_hid_quirks_consumed : () -> u64'
echo "[i2c-hid-quirks-confine] lookup, count and consumed arities pinned"

# ---------------------------------------------------------------------------
# R32.M2-002 (#1121): HID USAGE TABLE CONFINEMENT + ARITY PINS.
#
# The table and its row count are compile-time constants in .rodata; the
# consumer counter is an honesty pin (0 today, flipped when R32.M3 wires
# the class driver -- the boot witness assertion fires at that point).
# The load-bearing check is that no object other than usage.o forms a
# row address of its own; a stray reader would classify a (page, id)
# pair through a table the review never looked at.
HID_US_OWNER="${BUILD_DIR}/core/drivers/hid/usage.o"
HID_US_SRC="${REPO_ROOT}/src/kernel/core/drivers/hid/usage.pdx"
if [[ ! -f "${HID_US_SRC}" ]]; then
    echo "[hid-usage-confine] FAIL - ${HID_US_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HID_US_OWNER}" ]]; then
    echo "[hid-usage-confine] FAIL: ${HID_US_OWNER} not built" >&2
    exit 1
fi
hid_us_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HID_US_OWNER}" "${sym}"; then
        echo "[hid-usage-confine] FAIL: usage.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HID_US_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hid-usage-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hid/usage.o relocate against ${sym}:${strays}" >&2
        echo "  The usage table, its row count and its specific-end split are" >&2
        echo "  reachable only through hid_usage_id_kind / hid_usage_page_known" >&2
        echo "  / hid_usage_row_count. See src/kernel/core/drivers/hid/usage.pdx §2." >&2
        exit 1
    fi
}
hid_us_confine_one '_hid_usage_table'
hid_us_confine_one '_hid_usage_count'
hid_us_confine_one '_hid_usage_specific_end'
hid_us_confine_one '_hid_usage_consumers'
echo "[hid-usage-confine] table, count, specific-end and consumer latch confined"

hid_us_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HID_US_SRC}"; then
        echo "[hid-usage-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE CLASSIFIER SEAM TAKES (page, id) AS TWO ARGS -- a caller" >&2
        echo "  that passed one packed key would have to have already packed" >&2
        echo "  it, which is the packing step this module exists to own. See" >&2
        echo "  src/kernel/core/drivers/hid/usage.pdx §1." >&2
        exit 1
    fi
}
hid_us_pin_one 'pub let hid_usage_id_kind : (u64, u64) -> u64'
hid_us_pin_one 'pub let hid_usage_page_known : (u64) -> u64'
hid_us_pin_one 'pub let hid_usage_row_count : () -> u64'
hid_us_pin_one 'pub let hid_usage_consumed : () -> u64'
echo "[hid-usage-confine] id_kind, page_known, row_count and consumed arities pinned"

# ---------------------------------------------------------------------------
# R32.M2-001 (#1120): HID REPORT-PARSER SCHEMA CONFINEMENT + ARITY PINS.
#
# _hid_report_schema, _hid_report_count and _hid_report_valid are the
# LATCH the parser writes on a successful feed. The collection walker
# in R32.M2-003 READS these three symbols but MUST NOT WRITE them --
# that is the whole point of §3 in report_parser.pdx and §1 in
# collection_walker.pdx. The confinement check refuses any writer other
# than report_parser.o.
#
# The working-state cells (_hid_rp_up, _hid_rp_rsz, ..., _hid_rp_gs) are
# confined too: a stray writer would let a parse in progress diverge
# from the state the emit helper reads back one row later, and the
# schema would carry field values that never appeared in the descriptor.
#
# Arity pins ensure the feed seam continues to accept (ptr, len) and
# the field accessors continue to accept (idx). A widened signature
# would let a caller reach a row of its own choosing behind the
# accessor's bounds check.
HID_RP_OWNER="${BUILD_DIR}/core/drivers/hid/report_parser.o"
HID_RP_SRC="${REPO_ROOT}/src/kernel/core/drivers/hid/report_parser.pdx"
if [[ ! -f "${HID_RP_SRC}" ]]; then
    echo "[hid-report-parser-confine] FAIL - ${HID_RP_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HID_RP_OWNER}" ]]; then
    echo "[hid-report-parser-confine] FAIL: ${HID_RP_OWNER} not built" >&2
    exit 1
fi
# Writer-confined symbols: parser.o is the only object that may WRITE
# these. Readers outside parser.o are allowed (the walker, and the
# witness) because the schema is a read-many, write-once latch.
hid_rp_wconfine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HID_RP_OWNER}" "${sym}"; then
        echo "[hid-report-parser-confine] FAIL: report_parser.o does not reference ${sym}" >&2
        exit 1
    fi
}
# Working-state cells: writer AND reader confined to report_parser.o
# (the emit helper reads them one row later; nothing else has any
# reason to touch them).
hid_rp_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HID_RP_OWNER}" "${sym}"; then
        echo "[hid-report-parser-confine] FAIL: report_parser.o does not reference ${sym}" >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HID_RP_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hid-report-parser-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hid/report_parser.o relocate against ${sym}:${strays}" >&2
        echo "  Parser working state must not leak out of the parser object. See" >&2
        echo "  src/kernel/core/drivers/hid/report_parser.pdx §3." >&2
        exit 1
    fi
}
hid_rp_wconfine_one '_hid_report_schema'
hid_rp_wconfine_one '_hid_report_count'
hid_rp_wconfine_one '_hid_report_valid'
hid_rp_confine_one  '_hid_rp_up'
hid_rp_confine_one  '_hid_rp_rsz'
hid_rp_confine_one  '_hid_rp_rcnt'
hid_rp_confine_one  '_hid_rp_rid'
hid_rp_confine_one  '_hid_rp_lmin'
hid_rp_confine_one  '_hid_rp_lmax'
hid_rp_confine_one  '_hid_rp_ulast'
hid_rp_confine_one  '_hid_rp_umin'
hid_rp_confine_one  '_hid_rp_umax'
hid_rp_confine_one  '_hid_rp_depth'
hid_rp_confine_one  '_hid_rp_gs'
hid_rp_confine_one  '_hid_rp_gsd'
echo "[hid-report-parser-confine] schema latch (reader/writer) and working state confined"

hid_rp_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HID_RP_SRC}"; then
        echo "[hid-report-parser-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE PARSER FEED SEAM TAKES (ptr, len) AND ROW ACCESSORS TAKE" >&2
        echo "  (idx). A widened signature would let a caller reach a row of" >&2
        echo "  its own choosing behind the accessor's bounds check. See" >&2
        echo "  src/kernel/core/drivers/hid/report_parser.pdx §1 / §4." >&2
        exit 1
    fi
}
hid_rp_pin_one 'pub let hid_report_parser_feed : (u64, u64) -> u64'
hid_rp_pin_one 'pub let hid_report_parser_reset : () -> u64'
hid_rp_pin_one 'pub let hid_report_parser_valid : () -> u64'
hid_rp_pin_one 'pub let hid_report_field_count : () -> u64'
hid_rp_pin_one 'pub let hid_report_field_kind : (u64) -> u64'
hid_rp_pin_one 'pub let hid_report_field_aux : (u64) -> u64'
hid_rp_pin_one 'pub let hid_report_field_usage_page : (u64) -> u64'
hid_rp_pin_one 'pub let hid_report_field_usage_id : (u64) -> u64'
hid_rp_pin_one 'pub let hid_report_field_report_size : (u64) -> u64'
hid_rp_pin_one 'pub let hid_report_field_report_count : (u64) -> u64'
hid_rp_pin_one 'pub let hid_report_field_report_id : (u64) -> u64'
hid_rp_pin_one 'pub let hid_report_field_depth : (u64) -> u64'
echo "[hid-report-parser-confine] feed, reset, valid and field accessors pinned"

# ---------------------------------------------------------------------------
# R32.M2-003 (#1122): HID COLLECTION WALKER CONFINEMENT + ARITY PINS.
#
# The walker's only writable state is its honesty counter; a stray
# writer would flip the pin without a live consumer ever landing.
# Everything else the walker touches (schema, count, valid) is
# read-only for this object -- see the parser gate above.
#
# The walk seam takes ARITY ONE (cb pointer); a widened signature
# would let a caller thread out-of-band state through arg registers
# the callback contract does not name.
HID_CW_OWNER="${BUILD_DIR}/core/drivers/hid/collection_walker.o"
HID_CW_SRC="${REPO_ROOT}/src/kernel/core/drivers/hid/collection_walker.pdx"
if [[ ! -f "${HID_CW_SRC}" ]]; then
    echo "[hid-collection-walker-confine] FAIL - ${HID_CW_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HID_CW_OWNER}" ]]; then
    echo "[hid-collection-walker-confine] FAIL: ${HID_CW_OWNER} not built" >&2
    exit 1
fi
hid_cw_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HID_CW_OWNER}" "${sym}"; then
        echo "[hid-collection-walker-confine] FAIL: collection_walker.o does not reference ${sym}" >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HID_CW_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hid-collection-walker-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hid/collection_walker.o relocate against ${sym}:${strays}" >&2
        echo "  Walker honesty counter must not be flipped outside the walker's" >&2
        echo "  own object. See src/kernel/core/drivers/hid/collection_walker.pdx §1." >&2
        exit 1
    fi
}
hid_cw_confine_one '_hid_collection_walker_consumers'
echo "[hid-collection-walker-confine] walker honesty counter confined"

hid_cw_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HID_CW_SRC}"; then
        echo "[hid-collection-walker-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE WALK SEAM TAKES ARITY ONE (cb pointer); accessors take ONE" >&2
        echo "  index. Widening would let a caller thread out-of-band state" >&2
        echo "  through arg registers. See src/kernel/core/drivers/hid/" >&2
        echo "  collection_walker.pdx §0 / §4." >&2
        exit 1
    fi
}
hid_cw_pin_one 'pub let hid_collection_walk : (u64) -> u64'
hid_cw_pin_one 'pub let hid_collection_count : () -> u64'
hid_cw_pin_one 'pub let hid_collection_max_depth : () -> u64'
hid_cw_pin_one 'pub let hid_collection_type_at : (u64) -> u64'
hid_cw_pin_one 'pub let hid_collection_depth_at : (u64) -> u64'
hid_cw_pin_one 'pub let hid_collection_walker_consumed : () -> u64'
echo "[hid-collection-walker-confine] walk, count, max_depth, type_at, depth_at and consumed arities pinned"

# ---------------------------------------------------------------------------
# R32.M2-004 (#1123): HID FIELD EXTRACTOR CONFINEMENT + ARITY PINS.
#
# The extractor's only writable state is its honesty counter; a stray
# writer would flip the pin without a live consumer ever landing. The
# extractor consults NO parser state at its own arity (§0 of
# field_extract.pdx) -- byte/bit offsets within a report are DERIVED
# from a schema walk in the class driver R32.M3 will land, and threading
# the schema into the extractor would let a caller reach a field the
# walk never traversed.
#
# The three seams take (report_ptr, report_len, bit_offset, bit_width)
# or (report_ptr, report_len, byte_offset, index); a widened signature
# would let a caller thread out-of-band state through arg registers the
# gates never validated.
HID_FE_OWNER="${BUILD_DIR}/core/drivers/hid/field_extract.o"
HID_FE_SRC="${REPO_ROOT}/src/kernel/core/drivers/hid/field_extract.pdx"
if [[ ! -f "${HID_FE_SRC}" ]]; then
    echo "[hid-field-extract-confine] FAIL - ${HID_FE_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HID_FE_OWNER}" ]]; then
    echo "[hid-field-extract-confine] FAIL: ${HID_FE_OWNER} not built" >&2
    exit 1
fi
hid_fe_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HID_FE_OWNER}" "${sym}"; then
        echo "[hid-field-extract-confine] FAIL: field_extract.o does not reference ${sym}" >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HID_FE_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hid-field-extract-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hid/field_extract.o relocate against ${sym}:${strays}" >&2
        echo "  Extractor honesty counter must not be flipped outside the" >&2
        echo "  extractor's own object. See src/kernel/core/drivers/hid/" >&2
        echo "  field_extract.pdx §2." >&2
        exit 1
    fi
}
hid_fe_confine_one '_hid_field_extract_consumers'
echo "[hid-field-extract-confine] extractor honesty counter confined"

hid_fe_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HID_FE_SRC}"; then
        echo "[hid-field-extract-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE EXTRACT SEAMS TAKE (report_ptr, report_len, bit_offset," >&2
        echo "  bit_width) or (report_ptr, report_len, byte_offset, index)." >&2
        echo "  Widening would let a caller thread out-of-band state through" >&2
        echo "  arg registers the gates never validated. See" >&2
        echo "  src/kernel/core/drivers/hid/field_extract.pdx §0 / §3." >&2
        exit 1
    fi
}
hid_fe_pin_one 'pub let hid_field_extract_bits : (u64, u64, u64, u64) -> u64'
hid_fe_pin_one 'pub let hid_field_extract_signed : (u64, u64, u64, u64) -> u64'
hid_fe_pin_one 'pub let hid_field_extract_array : (u64, u64, u64, u64) -> u64'
hid_fe_pin_one 'pub let hid_field_extract_consumed : () -> u64'
echo "[hid-field-extract-confine] bits, signed, array and consumed arities pinned"

# ---------------------------------------------------------------------------
# R32.M2-005 (#1124): HID REPORT-IO CONFINEMENT + ARITY PINS.
#
# The GET/SET_REPORT dispatch counters are the ONE state this module
# writes; a stray writer would count a round-trip that never issued,
# and the boot witness assertion (get_deferred/set_deferred moved by
# exactly 1) would advance without the transport having been asked.
# tools/build.sh confines both stats arrays to this object.
#
# The dispatch seams take (report_type, report_id) or
# (report_type, report_id, byte); a widened signature would let a
# caller reach a report-type / id combination the module's gates
# (BAD_TYPE, BAD_ID) never validated.
HID_RI_OWNER="${BUILD_DIR}/core/drivers/hid/report_io.o"
HID_RI_SRC="${REPO_ROOT}/src/kernel/core/drivers/hid/report_io.pdx"
if [[ ! -f "${HID_RI_SRC}" ]]; then
    echo "[hid-report-io-confine] FAIL - ${HID_RI_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HID_RI_OWNER}" ]]; then
    echo "[hid-report-io-confine] FAIL: ${HID_RI_OWNER} not built" >&2
    exit 1
fi
hid_ri_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HID_RI_OWNER}" "${sym}"; then
        echo "[hid-report-io-confine] FAIL: report_io.o does not reference ${sym}" >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HID_RI_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hid-report-io-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hid/report_io.o relocate against ${sym}:${strays}" >&2
        echo "  Only hid_report_get / hid_report_set may count round-trips." >&2
        echo "  See src/kernel/core/drivers/hid/report_io.pdx §1." >&2
        exit 1
    fi
}
hid_ri_confine_one '_hid_report_get_stats'
hid_ri_confine_one '_hid_report_set_stats'
echo "[hid-report-io-confine] get/set round-trip stats confined"

hid_ri_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HID_RI_SRC}"; then
        echo "[hid-report-io-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE GET_REPORT SEAM TAKES (report_type, report_id) AND THE" >&2
        echo "  SET_REPORT SEAM TAKES (report_type, report_id, byte). A" >&2
        echo "  widened signature would let a caller reach a report-type / id" >&2
        echo "  combination the module's gates never validated. See" >&2
        echo "  src/kernel/core/drivers/hid/report_io.pdx §0 / §2." >&2
        exit 1
    fi
}
hid_ri_pin_one 'pub let hid_report_get : (u64, u64) -> u64'
hid_ri_pin_one 'pub let hid_report_set : (u64, u64, u64) -> u64'
hid_ri_pin_one 'pub let hid_report_get_arbitrated : () -> u64'
hid_ri_pin_one 'pub let hid_report_set_arbitrated : () -> u64'
hid_ri_pin_one 'pub let hid_report_get_count : () -> u64'
hid_ri_pin_one 'pub let hid_report_set_count : () -> u64'
hid_ri_pin_one 'pub let hid_report_get_deferred : () -> u64'
hid_ri_pin_one 'pub let hid_report_set_deferred : () -> u64'
echo "[hid-report-io-confine] get, set, arbitrated, count and deferred arities pinned"

# ---------------------------------------------------------------------------
# R33.M1-001 (#1137): HDA CONTROLLER SCAFFOLD STATE + ARITY PINS.
#
# Same shape as [i2c-hid-transport-confine]: a bind latch, a stashed
# opaque BAR handle, and the stats counters, each with exactly one
# legitimate writer (hda_controller_bind for the latch; the read/write
# seams for counters). The load-bearing symbol is _hda_controller_bar:
# a stray writer would be a second path stashing a BAR handle no
# capability named, and when R33.M2 plumbs pci_enumerate_all through
# this frame, the spuriously-set handle would let register I/O reach
# a window the capability did not authorise.
HDA_CT_OWNER="${BUILD_DIR}/core/drivers/hda/controller.o"
HDA_CT_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/controller.pdx"
if [[ ! -f "${HDA_CT_SRC}" ]]; then
    echo "[hda-controller-confine] FAIL - ${HDA_CT_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_CT_OWNER}" ]]; then
    echo "[hda-controller-confine] FAIL: ${HDA_CT_OWNER} not built" >&2
    exit 1
fi
hda_ct_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HDA_CT_OWNER}" "${sym}"; then
        echo "[hda-controller-confine] FAIL: controller.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_CT_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-controller-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hda/controller.o relocate against ${sym}:${strays}" >&2
        echo "  Only hda_controller_bind may write the bind latch, and only" >&2
        echo "  the read/write seams may write the stats counters. See" >&2
        echo "  src/kernel/core/drivers/hda/controller.pdx §2." >&2
        exit 1
    fi
}
hda_ct_confine_one '_hda_controller_bound'
hda_ct_confine_one '_hda_controller_bar'
hda_ct_confine_one '_hda_controller_stats'
echo "[hda-controller-confine] bind latch, BAR handle and stats confined"

hda_ct_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_CT_SRC}"; then
        echo "[hda-controller-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  AN HDA CONTROLLER BIND TAKES THE OPAQUE BAR HANDLE, NOTHING" >&2
        echo "  ELSE. An extra parameter on bind is how a caller-supplied" >&2
        echo "  controller EXTENT would reach the register path when R33.M2" >&2
        echo "  wires it -- exactly what §2 of ec_access.pdx exists to" >&2
        echo "  prevent. If a signature legitimately changed, §0/§2/§4 of" >&2
        echo "  controller.pdx must be rewritten first." >&2
        exit 1
    fi
}
hda_ct_pin_one 'pub let hda_controller_bind : (u64) -> u64'
hda_ct_pin_one 'pub let hda_controller_bound : () -> u64'
hda_ct_pin_one 'pub let hda_controller_bar : () -> u64'
hda_ct_pin_one 'pub let hda_controller_arbitrated : () -> u64'
hda_ct_pin_one 'pub let hda_controller_read : (u64) -> u64'
hda_ct_pin_one 'pub let hda_controller_write : (u64, u64) -> u64'
hda_ct_pin_one 'pub let hda_controller_reads : () -> u64'
hda_ct_pin_one 'pub let hda_controller_writes : () -> u64'
echo "[hda-controller-confine] bind, seams and accessor arities pinned"

# ---------------------------------------------------------------------------
# R33.M1-002 (#1138): HDA RESET SCAFFOLD STATE + ARITY PINS.
#
# One symbol to confine (_hda_reset_stats). The reset seams are arity
# ZERO -- both the register (GCTL) and the value (CRST bit) are
# spec-enumerated and a caller-supplied argument would let arbitrary
# bits reach GCTL.
HDA_RS_OWNER="${BUILD_DIR}/core/drivers/hda/reset.o"
HDA_RS_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/reset.pdx"
if [[ ! -f "${HDA_RS_SRC}" ]]; then
    echo "[hda-reset-confine] FAIL - ${HDA_RS_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_RS_OWNER}" ]]; then
    echo "[hda-reset-confine] FAIL: ${HDA_RS_OWNER} not built" >&2
    exit 1
fi
hda_rs_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HDA_RS_OWNER}" "${sym}"; then
        echo "[hda-reset-confine] FAIL: reset.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_RS_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-reset-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hda/reset.o relocate against ${sym}:${strays}" >&2
        echo "  Only the arm/release seams may write the reset counters. See" >&2
        echo "  src/kernel/core/drivers/hda/reset.pdx §1." >&2
        exit 1
    fi
}
hda_rs_confine_one '_hda_reset_stats'
echo "[hda-reset-confine] reset stats confined"

hda_rs_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_RS_SRC}"; then
        echo "[hda-reset-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE HDA RESET SEAMS TAKE NO CALLER ARGUMENT. Widening either" >&2
        echo "  arm or release to accept a GCTL value would let arbitrary" >&2
        echo "  bits (FCNTRL, UNSOL) be flipped on a reset call, and the" >&2
        echo "  reset sequence only writes the CRST bit. If a signature" >&2
        echo "  legitimately changed, §0/§2/§3 of reset.pdx must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
hda_rs_pin_one 'pub let hda_reset_arbitrated : () -> u64'
hda_rs_pin_one 'pub let hda_reset_arm : () -> u64'
hda_rs_pin_one 'pub let hda_reset_release : () -> u64'
hda_rs_pin_one 'pub let hda_reset_arm_count : () -> u64'
hda_rs_pin_one 'pub let hda_reset_release_count : () -> u64'
echo "[hda-reset-confine] arm, release, arbitrated and count arities pinned"

# ---------------------------------------------------------------------------
# R33.M1-003 (#1139): HDA CORB SCAFFOLD STATE + ARITY PINS.
#
# Same shape as [hda-controller-confine]: init latch, stashed ring
# parameters and stats -- each with exactly one legitimate writer
# (hda_corb_init for the latch/params; hda_corb_submit for stats).
HDA_CB_OWNER="${BUILD_DIR}/core/drivers/hda/corb.o"
HDA_CB_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/corb.pdx"
if [[ ! -f "${HDA_CB_SRC}" ]]; then
    echo "[hda-corb-confine] FAIL - ${HDA_CB_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_CB_OWNER}" ]]; then
    echo "[hda-corb-confine] FAIL: ${HDA_CB_OWNER} not built" >&2
    exit 1
fi
hda_cb_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HDA_CB_OWNER}" "${sym}"; then
        echo "[hda-corb-confine] FAIL: corb.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_CB_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-corb-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hda/corb.o relocate against ${sym}:${strays}" >&2
        echo "  Only hda_corb_init may write the init latch. See" >&2
        echo "  src/kernel/core/drivers/hda/corb.pdx §2." >&2
        exit 1
    fi
}
hda_cb_confine_one '_hda_corb_bound'
hda_cb_confine_one '_hda_corb_ring_pa'
hda_cb_confine_one '_hda_corb_size_code'
hda_cb_confine_one '_hda_corb_stats'
echo "[hda-corb-confine] init latch, ring params and stats confined"

hda_cb_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_CB_SRC}"; then
        echo "[hda-corb-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE HDA CORB INIT SEAM TAKES THE RING PHYSICAL ADDRESS AND" >&2
        echo "  THE ENUMERATED SIZE CODE, NOTHING ELSE. A caller-supplied" >&2
        echo "  virtual address would be a way to reach memory no capability" >&2
        echo "  named -- exactly what §2 of ec_access.pdx exists to prevent." >&2
        echo "  If a signature legitimately changed, §0/§1/§3 of corb.pdx" >&2
        echo "  must be rewritten first." >&2
        exit 1
    fi
}
hda_cb_pin_one 'pub let hda_corb_init : (u64, u64) -> u64'
hda_cb_pin_one 'pub let hda_corb_bound : () -> u64'
hda_cb_pin_one 'pub let hda_corb_ring_pa : () -> u64'
hda_cb_pin_one 'pub let hda_corb_size_code : () -> u64'
hda_cb_pin_one 'pub let hda_corb_arbitrated : () -> u64'
hda_cb_pin_one 'pub let hda_corb_submit : (u64) -> u64'
hda_cb_pin_one 'pub let hda_corb_submits : () -> u64'
echo "[hda-corb-confine] init, submit, arbitrated and accessor arities pinned"

# ---------------------------------------------------------------------------
# R33.M1-004 (#1140): HDA RIRB SCAFFOLD STATE + ARITY PINS.
#
# Same shape as [hda-corb-confine].
HDA_RB_OWNER="${BUILD_DIR}/core/drivers/hda/rirb.o"
HDA_RB_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/rirb.pdx"
if [[ ! -f "${HDA_RB_SRC}" ]]; then
    echo "[hda-rirb-confine] FAIL - ${HDA_RB_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_RB_OWNER}" ]]; then
    echo "[hda-rirb-confine] FAIL: ${HDA_RB_OWNER} not built" >&2
    exit 1
fi
hda_rb_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HDA_RB_OWNER}" "${sym}"; then
        echo "[hda-rirb-confine] FAIL: rirb.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_RB_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-rirb-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hda/rirb.o relocate against ${sym}:${strays}" >&2
        echo "  Only hda_rirb_init may write the init latch. See" >&2
        echo "  src/kernel/core/drivers/hda/rirb.pdx §2." >&2
        exit 1
    fi
}
hda_rb_confine_one '_hda_rirb_bound'
hda_rb_confine_one '_hda_rirb_ring_pa'
hda_rb_confine_one '_hda_rirb_size_code'
hda_rb_confine_one '_hda_rirb_stats'
echo "[hda-rirb-confine] init latch, ring params and stats confined"

hda_rb_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_RB_SRC}"; then
        echo "[hda-rirb-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE HDA RIRB INIT SEAM TAKES THE RING PHYSICAL ADDRESS AND" >&2
        echo "  THE ENUMERATED SIZE CODE, NOTHING ELSE. Same reasoning as" >&2
        echo "  corb.pdx §0. If a signature legitimately changed, §0/§1/§3" >&2
        echo "  of rirb.pdx must be rewritten first." >&2
        exit 1
    fi
}
hda_rb_pin_one 'pub let hda_rirb_init : (u64, u64) -> u64'
hda_rb_pin_one 'pub let hda_rirb_bound : () -> u64'
hda_rb_pin_one 'pub let hda_rirb_ring_pa : () -> u64'
hda_rb_pin_one 'pub let hda_rirb_size_code : () -> u64'
hda_rb_pin_one 'pub let hda_rirb_arbitrated : () -> u64'
hda_rb_pin_one 'pub let hda_rirb_consume : (u64) -> u64'
hda_rb_pin_one 'pub let hda_rirb_solicited : () -> u64'
hda_rb_pin_one 'pub let hda_rirb_unsolicited : () -> u64'
echo "[hda-rirb-confine] init, consume, arbitrated and accessor arities pinned"

# ---------------------------------------------------------------------------
# R33.M2-001 (#1142): HDA CODEC DISCOVERY SCAFFOLD STATE + ARITY PINS.
#
# Same shape as [hda-corb-confine]. One symbol to confine
# (_hda_codec_disc_stats); the discovery driver uses no bind latch of
# its own -- it gates on hda_corb_bound() && hda_rirb_bound().
HDA_CD_OWNER="${BUILD_DIR}/core/drivers/hda/codec_discovery.o"
HDA_CD_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/codec_discovery.pdx"
if [[ ! -f "${HDA_CD_SRC}" ]]; then
    echo "[hda-codec-disc-confine] FAIL - ${HDA_CD_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_CD_OWNER}" ]]; then
    echo "[hda-codec-disc-confine] FAIL: ${HDA_CD_OWNER} not built" >&2
    exit 1
fi
hda_cd_confine_one() {
    local sym="$1"
    if ! obj_relocs_against "${HDA_CD_OWNER}" "${sym}"; then
        echo "[hda-codec-disc-confine] FAIL: codec_discovery.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  check would then pass vacuously, so it fails instead." >&2
        exit 1
    fi
    local strays=""
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_CD_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-codec-disc-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hda/codec_discovery.o relocate against ${sym}:${strays}" >&2
        echo "  Only the discovery seams may write the codec-disc counters. See" >&2
        echo "  src/kernel/core/drivers/hda/codec_discovery.pdx §2." >&2
        exit 1
    fi
}
hda_cd_confine_one '_hda_codec_disc_stats'
echo "[hda-codec-disc-confine] codec discovery stats confined"

hda_cd_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_CD_SRC}"; then
        echo "[hda-codec-disc-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE HDA CODEC DISCOVERY SEAMS TAKE ONLY WIRE-FIELD ARGUMENTS." >&2
        echo "  Widening verb_encode to accept a pre-packed u32 or the driver" >&2
        echo "  probes to accept a raw verb would bypass the §1 field" >&2
        echo "  validator. If a signature legitimately changed, §0/§1/§3 of" >&2
        echo "  codec_discovery.pdx must be rewritten first." >&2
        exit 1
    fi
}
hda_cd_pin_one 'pub let hda_codec_verb_encode : (u64, u64, u64, u64) -> u64'
hda_cd_pin_one 'pub let hda_codec_get_parameter : (u64, u64, u64) -> u64'
hda_cd_pin_one 'pub let hda_codec_walk_function_groups : (u64) -> u64'
hda_cd_pin_one 'pub let hda_codec_walk_widgets : (u64, u64) -> u64'
hda_cd_pin_one 'pub let hda_codec_discovery_probe_all : () -> u64'
hda_cd_pin_one 'pub let hda_codec_discovery_arbitrated : () -> u64'
echo "[hda-codec-disc-confine] encoder, probe seams and honesty pin arities pinned"

# ---------------------------------------------------------------------------
# R33.M2-002 (#1143): HDA WIDGET GRAPH TYPED-RECORD STATE + ARITY PINS.
#
# _hda_widget_graph_rows and _hda_widget_graph_count are the only place
# in the kernel where a codec's widget-node table lives; a second writer
# would let another module invent a widget the codec never advertised
# (row_type / connections list are the wire-face for the graph, and a
# forged row would misroute an audio path). Same shape as the four
# R33.M1 confinements.
HDA_WG_OWNER="${BUILD_DIR}/core/drivers/hda/widget_graph.o"
HDA_WG_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/widget_graph.pdx"
if [[ ! -f "${HDA_WG_SRC}" ]]; then
    echo "[hda-widget-graph-confine] FAIL - ${HDA_WG_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_WG_OWNER}" ]]; then
    echo "[hda-widget-graph-confine] FAIL: ${HDA_WG_OWNER} not built" >&2
    exit 1
fi
hda_wg_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_WG_OWNER}" "${sym}"; then
        echo "[hda-widget-graph-confine] FAIL: widget_graph.o does not reference ${sym}" >&2
        echo "  The symbol was renamed or the module was gutted; the confinement" >&2
        echo "  assertion below would then pass vacuously." >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_WG_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-widget-graph-confine] FAIL - objects other than" >&2
        echo "  core/drivers/hda/widget_graph.o relocate against ${sym}:${strays}" >&2
        echo "  Only hda_widget_graph_add / append_conn may write the table." >&2
        echo "  See src/kernel/core/drivers/hda/widget_graph.pdx §2." >&2
        exit 1
    fi
}
hda_wg_confine_one '_hda_widget_graph_rows'
hda_wg_confine_one '_hda_widget_graph_count'
hda_wg_confine_one '_hda_widget_graph_stats'
echo "[hda-widget-graph-confine] rows, count and stats confined"

hda_wg_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_WG_SRC}"; then
        echo "[hda-widget-graph-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE WIDGET GRAPH SEAMS TAKE ONLY THE FIELDS THE RECORD" >&2
        echo "  DECLARES. A widened 'add' or 'append' would let a caller" >&2
        echo "  claim a connections_len append_conn never advanced, or a" >&2
        echo "  connection slot outside the row. If a signature legitimately" >&2
        echo "  changed, §0/§1/§3 of widget_graph.pdx must be rewritten first." >&2
        exit 1
    fi
}
hda_wg_pin_one 'pub let hda_widget_graph_add : (u64, u64, u64) -> u64'
hda_wg_pin_one 'pub let hda_widget_graph_append_conn : (u64, u64) -> u64'
hda_wg_pin_one 'pub let hda_widget_graph_row_codec : (u64) -> u64'
hda_wg_pin_one 'pub let hda_widget_graph_row_node : (u64) -> u64'
hda_wg_pin_one 'pub let hda_widget_graph_row_type : (u64) -> u64'
hda_wg_pin_one 'pub let hda_widget_graph_row_conn_len : (u64) -> u64'
hda_wg_pin_one 'pub let hda_widget_graph_row_conn : (u64, u64) -> u64'
hda_wg_pin_one 'pub let hda_widget_graph_arbitrated : () -> u64'
echo "[hda-widget-graph-confine] add, append and read-seam arities pinned"

# ---------------------------------------------------------------------------
# R33.M2-003 (#1144): HDA PIN CONFIG DECODER STATE + ARITY PINS.
#
# One symbol to confine (_hda_pin_cfg_stats). The nine field getters are
# pure -- no state escapes -- but each has a FIXED SIGNATURE (arity ONE:
# the 32-bit register value). A widened signature would let a caller
# supply a "field mask" the getter used, defeating the whole point of
# per-field accessors.
HDA_PC_OWNER="${BUILD_DIR}/core/drivers/hda/pin_config.o"
HDA_PC_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/pin_config.pdx"
if [[ ! -f "${HDA_PC_SRC}" ]]; then
    echo "[hda-pin-cfg-confine] FAIL - ${HDA_PC_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_PC_OWNER}" ]]; then
    echo "[hda-pin-cfg-confine] FAIL: ${HDA_PC_OWNER} not built" >&2
    exit 1
fi
hda_pc_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_PC_OWNER}" "${sym}"; then
        echo "[hda-pin-cfg-confine] FAIL: pin_config.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_PC_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-pin-cfg-confine] FAIL - strays for ${sym}:${strays}" >&2
        exit 1
    fi
}
hda_pc_confine_one '_hda_pin_cfg_stats'
echo "[hda-pin-cfg-confine] pin cfg stats confined"

hda_pc_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_PC_SRC}"; then
        echo "[hda-pin-cfg-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  EVERY PIN CFG GETTER TAKES ONE 32-BIT REGISTER VALUE AND" >&2
        echo "  NOTHING ELSE. A widened signature would let a caller pull" >&2
        echo "  bits from where they named -- exactly the class of confusion" >&2
        echo "  per-field accessors exist to stop (§0). If a signature" >&2
        echo "  legitimately changed, §1/§3 of pin_config.pdx must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
hda_pc_pin_one 'pub let hda_pin_cfg_conn : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_gross_loc : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_geom_loc : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_device : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_ctype : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_color : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_misc : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_assoc : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_seq : (u64) -> u64'
hda_pc_pin_one 'pub let hda_pin_cfg_arbitrated : () -> u64'
echo "[hda-pin-cfg-confine] nine field-getter arities and honesty pin pinned"

# ---------------------------------------------------------------------------
# R33.M2-004 (#1145): HDA VERB HELPER STATE + ARITY PINS.
#
# _hda_verb_stats is the only writer of the per-verb send counters.
# The per-verb wrappers take (codec_addr, node_id) + at most one payload
# argument, mirroring their spec-defined verb shape. Widening any of
# them to accept a raw verb id or a raw payload word would bypass the
# per-verb payload-width validation each wrapper embeds.
HDA_VB_OWNER="${BUILD_DIR}/core/drivers/hda/verbs.o"
HDA_VB_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/verbs.pdx"
if [[ ! -f "${HDA_VB_SRC}" ]]; then
    echo "[hda-verbs-confine] FAIL - ${HDA_VB_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_VB_OWNER}" ]]; then
    echo "[hda-verbs-confine] FAIL: ${HDA_VB_OWNER} not built" >&2
    exit 1
fi
hda_vb_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_VB_OWNER}" "${sym}"; then
        echo "[hda-verbs-confine] FAIL: verbs.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_VB_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-verbs-confine] FAIL - strays for ${sym}:${strays}" >&2
        exit 1
    fi
}
hda_vb_confine_one '_hda_verb_stats'
echo "[hda-verbs-confine] verb stats confined"

hda_vb_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_VB_SRC}"; then
        echo "[hda-verbs-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  EVERY VERB WRAPPER TAKES (codec_addr, node_id) PLUS AT MOST" >&2
        echo "  ONE PAYLOAD ARGUMENT, MATCHING THE VERB'S SPEC SHAPE. A" >&2
        echo "  widened signature would bypass the per-verb payload-width" >&2
        echo "  validation each wrapper embeds. If a signature legitimately" >&2
        echo "  changed, §0/§1/§3 of verbs.pdx must be rewritten first." >&2
        exit 1
    fi
}
hda_vb_pin_one 'pub let hda_verb_pack_short : (u64, u64, u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_send_long : (u64, u64, u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_send_short : (u64, u64, u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_get_pin_ctl : (u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_set_pin_ctl : (u64, u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_get_eapd : (u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_set_eapd : (u64, u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_get_power_state : (u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_set_power_state : (u64, u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_get_amp_gain : (u64, u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_set_amp_gain : (u64, u64, u64) -> u64'
hda_vb_pin_one 'pub let hda_verb_arbitrated : () -> u64'
echo "[hda-verbs-confine] pack, send, per-verb wrapper and honesty pin arities pinned"

# ---------------------------------------------------------------------------
# R33.M2-005 (#1146): CODEC_QUERY_CHANNEL SCHEMA ARITY PINS.
#
# No stateful confinement here (the schema is pure pack/unpack); the
# packers are arity-pinned so a widened signature cannot smuggle a
# session-authority field onto the wire that the audio server holds
# through its own capability set instead.
CQCH_SRC="${REPO_ROOT}/src/kernel/core/ipc/codec_query_channel.pdx"
if [[ ! -f "${CQCH_SRC}" ]]; then
    echo "[codec-query-schema] FAIL - ${CQCH_SRC} not found" >&2
    exit 1
fi
cqch_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${CQCH_SRC}"; then
        echo "[codec-query-schema] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE CODEC QUERY SCHEMA PACKERS TAKE ONLY THE FIELDS THE" >&2
        echo "  WIRE CARRIES. A widened signature would let a session-" >&2
        echo "  authority field the audio server holds through its own" >&2
        echo "  capability set be smuggled onto the wire. If a signature" >&2
        echo "  legitimately changed, §0/§1/§3 of codec_query_channel.pdx" >&2
        echo "  and design/ipc/codec-query-channel-schema.md must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
cqch_pin_one 'pub let codec_q_pack_get_widgets_req : (u64) -> u64'
cqch_pin_one 'pub let codec_q_pack_get_pins_req : (u64) -> u64'
cqch_pin_one 'pub let codec_q_pack_set_pin_ctl_req : (u64, u64, u64) -> u64'
cqch_pin_one 'pub let codec_q_pack_set_gain_req : (u64, u64, u64, u64) -> u64'
cqch_pin_one 'pub let codec_q_pack_set_mute_req : (u64, u64, u64, u64) -> u64'
cqch_pin_one 'pub let codec_q_pack_get_widgets_reply : (u64) -> u64'
cqch_pin_one 'pub let codec_q_pack_get_pins_reply : (u64) -> u64'
cqch_pin_one 'pub let codec_q_pack_set_ack : (u64) -> u64'
echo "[codec-query-schema] request / reply packer arities pinned"

# ---------------------------------------------------------------------------
# R33.M4-001 (#1152): ALC287 VENDOR INIT STATE + ARITY PINS.
#
# _hda_alc287_init_stats holds every counter and the bind LATCH for the
# vendor coefficient application. A second writer would let another
# module claim the coefficient set was applied while the codec never
# received the twelve verbs, or forge a latch that lets a second apply
# silently re-run and drift the codec's analog chain. Arity pins hold
# the six seams to their single-argument shape: widening apply() to
# accept a caller-supplied table would let a stray helper inject
# arbitrary coefficients into the codec's analog path.
HDA_AI_OWNER="${BUILD_DIR}/core/drivers/hda/alc287_init.o"
HDA_AI_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/alc287_init.pdx"
if [[ ! -f "${HDA_AI_SRC}" ]]; then
    echo "[hda-alc287-init-confine] FAIL - ${HDA_AI_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_AI_OWNER}" ]]; then
    echo "[hda-alc287-init-confine] FAIL: ${HDA_AI_OWNER} not built" >&2
    exit 1
fi
hda_ai_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_AI_OWNER}" "${sym}"; then
        echo "[hda-alc287-init-confine] FAIL: alc287_init.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_AI_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-alc287-init-confine] FAIL - strays for ${sym}:${strays}" >&2
        echo "  Only alc287_init.o may write the vendor init counters + latch." >&2
        echo "  See src/kernel/core/drivers/hda/alc287_init.pdx §2." >&2
        exit 1
    fi
}
hda_ai_confine_one '_hda_alc287_init_stats'
echo "[hda-alc287-init-confine] init counters + latch confined"

hda_ai_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_AI_SRC}"; then
        echo "[hda-alc287-init-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  THE ALC287 INIT SEAMS TAKE ONLY (codec_addr) AND NO TABLE." >&2
        echo "  A widened apply() would let a stray helper inject arbitrary" >&2
        echo "  coefficients into the codec's analog path -- exactly what" >&2
        echo "  the vendor wrapper exists to stop (§0). If a signature" >&2
        echo "  legitimately changed, §0/§1/§3 of alc287_init.pdx must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
hda_ai_pin_one 'pub let hda_alc287_init_apply : (u64) -> u64'
hda_ai_pin_one 'pub let hda_alc287_init_bound : () -> u64'
hda_ai_pin_one 'pub let hda_alc287_init_reset : () -> u64'
hda_ai_pin_one 'pub let hda_alc287_init_arbitrated : () -> u64'
hda_ai_pin_one 'pub let hda_alc287_init_stat : (u64) -> u64'
echo "[hda-alc287-init-confine] apply/bound/reset/arbitrated/stat arities pinned"

# ---------------------------------------------------------------------------
# R33.M4-002 (#1153): ALC287 HP/SPK PATH STATE + ARITY PINS.
#
# _hda_alc287_hp_spk_stats holds the counters, the bind latch AND the
# current jack-state cell. A second writer would let another module
# claim the codec is muted while its speaker is running. Arity pins
# hold auto_switch to a single jack-state argument (a widened seam
# with codec_addr would let a caller mute a codec they do not own,
# instead of reading from the latch which by construction belongs to
# the bound codec).
HDA_HS_OWNER="${BUILD_DIR}/core/drivers/hda/alc287_hp_spk.o"
HDA_HS_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/alc287_hp_spk.pdx"
if [[ ! -f "${HDA_HS_SRC}" ]]; then
    echo "[hda-alc287-hs-confine] FAIL - ${HDA_HS_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_HS_OWNER}" ]]; then
    echo "[hda-alc287-hs-confine] FAIL: ${HDA_HS_OWNER} not built" >&2
    exit 1
fi
hda_hs_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_HS_OWNER}" "${sym}"; then
        echo "[hda-alc287-hs-confine] FAIL: alc287_hp_spk.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_HS_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-alc287-hs-confine] FAIL - strays for ${sym}:${strays}" >&2
        echo "  Only alc287_hp_spk.o may write the HP/SPK counters + latches." >&2
        echo "  See src/kernel/core/drivers/hda/alc287_hp_spk.pdx §2." >&2
        exit 1
    fi
}
hda_hs_confine_one '_hda_alc287_hp_spk_stats'
echo "[hda-alc287-hs-confine] HP/SPK counters + latches confined"

hda_hs_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_HS_SRC}"; then
        echo "[hda-alc287-hs-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  ALC287 HP/SPK SEAMS: bind takes (codec_addr); auto_switch" >&2
        echo "  takes (jack_state) and reads codec_addr from the latch." >&2
        echo "  A widened auto_switch would let a caller mute a codec they" >&2
        echo "  do not own. If a signature legitimately changed, §0/§1/§3" >&2
        echo "  of alc287_hp_spk.pdx must be rewritten first." >&2
        exit 1
    fi
}
hda_hs_pin_one 'pub let hda_alc287_hp_spk_bind : (u64) -> u64'
hda_hs_pin_one 'pub let hda_alc287_hp_spk_auto_switch : (u64) -> u64'
hda_hs_pin_one 'pub let hda_alc287_hp_spk_bound : () -> u64'
hda_hs_pin_one 'pub let hda_alc287_hp_spk_reset : () -> u64'
hda_hs_pin_one 'pub let hda_alc287_hp_spk_arbitrated : () -> u64'
hda_hs_pin_one 'pub let hda_alc287_hp_spk_stat : (u64) -> u64'
echo "[hda-alc287-hs-confine] bind/auto_switch/read-seams arities pinned"

# ---------------------------------------------------------------------------
# R33.M4-003 (#1154): ALC287 MIC PATH STATE + ARITY PINS.
#
# _hda_alc287_mic_stats holds counters, latch, active-input and nc-
# enabled cells. Arity pins hold select() to (which) and nc_enable()
# to () -- a widened select taking (codec_addr, which) would let a
# caller re-target the ADC selector to a codec they do not own.
HDA_MC_OWNER="${BUILD_DIR}/core/drivers/hda/alc287_mic.o"
HDA_MC_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/alc287_mic.pdx"
if [[ ! -f "${HDA_MC_SRC}" ]]; then
    echo "[hda-alc287-mc-confine] FAIL - ${HDA_MC_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_MC_OWNER}" ]]; then
    echo "[hda-alc287-mc-confine] FAIL: ${HDA_MC_OWNER} not built" >&2
    exit 1
fi
hda_mc_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_MC_OWNER}" "${sym}"; then
        echo "[hda-alc287-mc-confine] FAIL: alc287_mic.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_MC_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-alc287-mc-confine] FAIL - strays for ${sym}:${strays}" >&2
        echo "  Only alc287_mic.o may write the mic counters + latches." >&2
        echo "  See src/kernel/core/drivers/hda/alc287_mic.pdx §2." >&2
        exit 1
    fi
}
hda_mc_confine_one '_hda_alc287_mic_stats'
echo "[hda-alc287-mc-confine] mic counters + latches confined"

hda_mc_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_MC_SRC}"; then
        echo "[hda-alc287-mc-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  ALC287 MIC SEAMS: bind takes (codec_addr); select takes" >&2
        echo "  (which) and reads codec_addr from the latch; nc_enable" >&2
        echo "  takes nothing. If a signature legitimately changed," >&2
        echo "  §0/§1/§3 of alc287_mic.pdx must be rewritten first." >&2
        exit 1
    fi
}
hda_mc_pin_one 'pub let hda_alc287_mic_bind : (u64) -> u64'
hda_mc_pin_one 'pub let hda_alc287_mic_select : (u64) -> u64'
hda_mc_pin_one 'pub let hda_alc287_mic_nc_enable : () -> u64'
hda_mc_pin_one 'pub let hda_alc287_mic_bound : () -> u64'
hda_mc_pin_one 'pub let hda_alc287_mic_reset : () -> u64'
hda_mc_pin_one 'pub let hda_alc287_mic_arbitrated : () -> u64'
hda_mc_pin_one 'pub let hda_alc287_mic_stat : (u64) -> u64'
echo "[hda-alc287-mc-confine] bind/select/nc_enable/read-seams arities pinned"

# ---------------------------------------------------------------------------
# R33.M4-004 (#1155): ALC287 JACK STATE + ARITY PINS.
#
# _hda_alc287_jack_stats holds counters, armed latch, and cached jack
# state. Arity pins hold isr() to (tag, subtag) and publish() to
# (state) -- a widened isr accepting codec_addr would let a caller
# fabricate a jack event against a codec they do not own; a publish()
# with codec_addr would let a caller inject events into the (future)
# jack_channel for arbitrary codecs.
HDA_JK_OWNER="${BUILD_DIR}/core/drivers/hda/alc287_jack.o"
HDA_JK_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/alc287_jack.pdx"
if [[ ! -f "${HDA_JK_SRC}" ]]; then
    echo "[hda-alc287-jk-confine] FAIL - ${HDA_JK_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_JK_OWNER}" ]]; then
    echo "[hda-alc287-jk-confine] FAIL: ${HDA_JK_OWNER} not built" >&2
    exit 1
fi
hda_jk_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_JK_OWNER}" "${sym}"; then
        echo "[hda-alc287-jk-confine] FAIL: alc287_jack.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_JK_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-alc287-jk-confine] FAIL - strays for ${sym}:${strays}" >&2
        echo "  Only alc287_jack.o may write the jack counters + latches." >&2
        echo "  See src/kernel/core/drivers/hda/alc287_jack.pdx §2." >&2
        exit 1
    fi
}
hda_jk_confine_one '_hda_alc287_jack_stats'
echo "[hda-alc287-jk-confine] jack counters + latches confined"

hda_jk_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_JK_SRC}"; then
        echo "[hda-alc287-jk-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  ALC287 JACK SEAMS: arm takes (codec_addr); isr takes" >&2
        echo "  (tag, subtag); publish takes (state). A widened seam" >&2
        echo "  would let a caller fabricate a jack event against a" >&2
        echo "  codec they do not own. If a signature legitimately" >&2
        echo "  changed, §0/§1/§3 of alc287_jack.pdx must be rewritten" >&2
        echo "  first." >&2
        exit 1
    fi
}
hda_jk_pin_one 'pub let hda_alc287_jack_arm : (u64) -> u64'
hda_jk_pin_one 'pub let hda_alc287_jack_isr : (u64, u64) -> u64'
hda_jk_pin_one 'pub let hda_alc287_jack_publish : (u64) -> u64'
hda_jk_pin_one 'pub let hda_alc287_jack_armed : () -> u64'
hda_jk_pin_one 'pub let hda_alc287_jack_reset : () -> u64'
hda_jk_pin_one 'pub let hda_alc287_jack_arbitrated : () -> u64'
hda_jk_pin_one 'pub let hda_alc287_jack_stat : (u64) -> u64'
echo "[hda-alc287-jk-confine] arm/isr/publish/read-seams arities pinned"

# ---------------------------------------------------------------------------
# R33.M6-001 (#1162): SOF DSP FIRMWARE LOADER STATE + ARITY PINS.
#
# _hda_sof_loader_{bound, fw_ptr, fw_len, stage, verified, stats} together
# constitute the whole handshake latch. Arity pins hold bind to
# (fw_ptr, fw_len) and advance to zero args -- a widened bind accepting
# a caller-chosen STAGE would let a helper skip verify by claiming
# BASE_FW_ENTERED without ever having crossed STAGE 0's gate; a
# widened advance would collapse the one-way stage machine into
# something callers could jump.
HDA_SL_OWNER="${BUILD_DIR}/core/drivers/hda/sof_loader.o"
HDA_SL_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/sof_loader.pdx"
if [[ ! -f "${HDA_SL_SRC}" ]]; then
    echo "[hda-sof-loader-confine] FAIL - ${HDA_SL_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_SL_OWNER}" ]]; then
    echo "[hda-sof-loader-confine] FAIL: ${HDA_SL_OWNER} not built" >&2
    exit 1
fi
hda_sl_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_SL_OWNER}" "${sym}"; then
        echo "[hda-sof-loader-confine] FAIL: sof_loader.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_SL_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-sof-loader-confine] FAIL - strays for ${sym}:${strays}" >&2
        echo "  Only sof_loader.o may write the handshake latches." >&2
        echo "  See src/kernel/core/drivers/hda/sof_loader.pdx §2." >&2
        exit 1
    fi
}
hda_sl_confine_one '_hda_sof_loader_bound'
hda_sl_confine_one '_hda_sof_loader_fw_ptr'
hda_sl_confine_one '_hda_sof_loader_fw_len'
hda_sl_confine_one '_hda_sof_loader_stage'
hda_sl_confine_one '_hda_sof_loader_verified'
hda_sl_confine_one '_hda_sof_loader_stats'
echo "[hda-sof-loader-confine] SOF loader latches + stats confined"

hda_sl_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_SL_SRC}"; then
        echo "[hda-sof-loader-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  SOF LOADER SEAMS: bind takes (fw_ptr, fw_len);" >&2
        echo "  advance takes zero args; mark_verified takes zero" >&2
        echo "  args. A widened bind accepting a caller-chosen STAGE" >&2
        echo "  would let a helper skip verify by claiming a stage" >&2
        echo "  the DSP never reached. If a signature legitimately" >&2
        echo "  changed, §0 of sof_loader.pdx must be rewritten" >&2
        echo "  first." >&2
        exit 1
    fi
}
hda_sl_pin_one 'pub let hda_sof_loader_bind : (u64, u64) -> u64'
hda_sl_pin_one 'pub let hda_sof_loader_advance : () -> u64'
hda_sl_pin_one 'pub let hda_sof_loader_mark_verified : () -> u64'
hda_sl_pin_one 'pub let hda_sof_loader_bound : () -> u64'
hda_sl_pin_one 'pub let hda_sof_loader_ready : () -> u64'
hda_sl_pin_one 'pub let hda_sof_loader_stage : () -> u64'
hda_sl_pin_one 'pub let hda_sof_loader_reset : () -> u64'
hda_sl_pin_one 'pub let hda_sof_loader_arbitrated : () -> u64'
echo "[hda-sof-loader-confine] handshake seam arities pinned"

# ---------------------------------------------------------------------------
# R33.M6-002 (#1163): SOF TOPOLOGY PARSER STATE + ARITY PINS.
#
# _hda_sof_topology_stats is the only mutable state the parser owns
# (the parser is pure decode over caller-supplied bytes). Arity pins
# hold parse_header to (buf_ptr, buf_len) -- a caller-supplied COUNT
# would let a helper claim more tuples than the header names, which
# is exactly the confusion the header exists to prevent.
HDA_ST_OWNER="${BUILD_DIR}/core/drivers/hda/sof_topology.o"
HDA_ST_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/sof_topology.pdx"
if [[ ! -f "${HDA_ST_SRC}" ]]; then
    echo "[hda-sof-topology-confine] FAIL - ${HDA_ST_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_ST_OWNER}" ]]; then
    echo "[hda-sof-topology-confine] FAIL: ${HDA_ST_OWNER} not built" >&2
    exit 1
fi
hda_st_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_ST_OWNER}" "${sym}"; then
        echo "[hda-sof-topology-confine] FAIL: sof_topology.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_ST_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-sof-topology-confine] FAIL - strays for ${sym}:${strays}" >&2
        echo "  Only sof_topology.o may write the parser counters." >&2
        echo "  See src/kernel/core/drivers/hda/sof_topology.pdx §2." >&2
        exit 1
    fi
}
hda_st_confine_one '_hda_sof_topology_stats'
echo "[hda-sof-topology-confine] SOF topology stats confined"

hda_st_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_ST_SRC}"; then
        echo "[hda-sof-topology-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  SOF TOPOLOGY SEAMS: parse_header takes (buf_ptr," >&2
        echo "  buf_len); tuple_type / tuple_size take (buf_ptr," >&2
        echo "  buf_len, tup_index). A widened parse_header accepting" >&2
        echo "  a caller-supplied COUNT would let a helper claim more" >&2
        echo "  tuples than the header names. If a signature" >&2
        echo "  legitimately changed, §0 of sof_topology.pdx must be" >&2
        echo "  rewritten first." >&2
        exit 1
    fi
}
hda_st_pin_one 'pub let hda_sof_topology_parse_header : (u64, u64) -> u64'
hda_st_pin_one 'pub let hda_sof_topology_count : (u64) -> u64'
hda_st_pin_one 'pub let hda_sof_topology_tuple_type : (u64, u64, u64) -> u64'
hda_st_pin_one 'pub let hda_sof_topology_tuple_size : (u64, u64, u64) -> u64'
echo "[hda-sof-topology-confine] parser seam arities pinned"

# ---------------------------------------------------------------------------
# R33.M6-003 (#1164): SOF EFFECT PIPELINE STATE + ARITY PINS.
#
# _hda_sof_effects_pipeline holds the eight slot cells and
# _hda_sof_effects_stats the counters. Arity pins hold attach to
# (slot, kind) and detach to (slot) -- a widened attach accepting a
# caller-supplied EFFECT PARAMETER blob would let a helper install
# an arbitrary payload on the codec's analog path, exactly what the
# vendor wrapper exists to stop.
HDA_SFX_OWNER="${BUILD_DIR}/core/drivers/hda/sof_effects.o"
HDA_SFX_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/sof_effects.pdx"
if [[ ! -f "${HDA_SFX_SRC}" ]]; then
    echo "[hda-sof-effects-confine] FAIL - ${HDA_SFX_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_SFX_OWNER}" ]]; then
    echo "[hda-sof-effects-confine] FAIL: ${HDA_SFX_OWNER} not built" >&2
    exit 1
fi
hda_sfx_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_SFX_OWNER}" "${sym}"; then
        echo "[hda-sof-effects-confine] FAIL: sof_effects.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_SFX_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-sof-effects-confine] FAIL - strays for ${sym}:${strays}" >&2
        echo "  Only sof_effects.o may write the pipeline table." >&2
        echo "  See src/kernel/core/drivers/hda/sof_effects.pdx §2." >&2
        exit 1
    fi
}
hda_sfx_confine_one '_hda_sof_effects_pipeline'
hda_sfx_confine_one '_hda_sof_effects_stats'
echo "[hda-sof-effects-confine] SOF effects pipeline + stats confined"

hda_sfx_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_SFX_SRC}"; then
        echo "[hda-sof-effects-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  SOF EFFECTS SEAMS: attach takes (slot, kind); detach" >&2
        echo "  takes (slot). A widened attach accepting a caller-" >&2
        echo "  supplied parameter blob would let a helper install an" >&2
        echo "  arbitrary payload on the codec's analog path. If a" >&2
        echo "  signature legitimately changed, §0 of sof_effects.pdx" >&2
        echo "  must be rewritten first." >&2
        exit 1
    fi
}
hda_sfx_pin_one 'pub let hda_sof_effects_attach : (u64, u64) -> u64'
hda_sfx_pin_one 'pub let hda_sof_effects_detach : (u64) -> u64'
hda_sfx_pin_one 'pub let hda_sof_effects_slot_kind : (u64) -> u64'
hda_sfx_pin_one 'pub let hda_sof_effects_clear : () -> u64'
hda_sfx_pin_one 'pub let hda_sof_effects_arbitrated : () -> u64'
echo "[hda-sof-effects-confine] pipeline seam arities pinned"

# ---------------------------------------------------------------------------
# R33.M6-004 (#1165): SOF DUAL-SIG VERIFY STATE + ARITY PINS.
#
# _hda_sof_verify_stats holds the DUAL verdict counters and
# _hda_sof_verify_arm_tmp is the one-word scratch cell across arm 1's
# and arm 2's calls into driver_sig_verify_algo. Arity pins hold
# verify_dual to (fw_ptr, fw_len, paideia_sig, paideia_pk,
# vendor_sig, vendor_pk) -- widening the seam to accept a signature
# LENGTH would let a caller mint a shorter buffer than the algorithm
# demands, which is exactly what the underlying gate 5 in
# sig_verify.pdx exists to catch; the length is fixed at 3309 per
# ML-DSA-65 FIPS 204 §5.4.
HDA_SV_OWNER="${BUILD_DIR}/core/drivers/hda/sof_verify.o"
HDA_SV_SRC="${REPO_ROOT}/src/kernel/core/drivers/hda/sof_verify.pdx"
if [[ ! -f "${HDA_SV_SRC}" ]]; then
    echo "[hda-sof-verify-confine] FAIL - ${HDA_SV_SRC} not found" >&2
    exit 1
fi
if [[ ! -f "${HDA_SV_OWNER}" ]]; then
    echo "[hda-sof-verify-confine] FAIL: ${HDA_SV_OWNER} not built" >&2
    exit 1
fi
hda_sv_confine_one() {
    local sym="$1" strays=""
    if ! obj_relocs_against "${HDA_SV_OWNER}" "${sym}"; then
        echo "[hda-sof-verify-confine] FAIL: sof_verify.o does not reference ${sym}" >&2
        exit 1
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${HDA_SV_OWNER}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[hda-sof-verify-confine] FAIL - strays for ${sym}:${strays}" >&2
        echo "  Only sof_verify.o may write the dual-sig stats." >&2
        echo "  See src/kernel/core/drivers/hda/sof_verify.pdx §2." >&2
        exit 1
    fi
}
hda_sv_confine_one '_hda_sof_verify_stats'
hda_sv_confine_one '_hda_sof_verify_arm_tmp'
echo "[hda-sof-verify-confine] SOF verify stats + tmp confined"

hda_sv_pin_one() {
    local decl="$1"
    if ! grep -qF -- "${decl}" "${HDA_SV_SRC}"; then
        echo "[hda-sof-verify-confine] FAIL - expected declaration not found:" >&2
        echo "    ${decl}" >&2
        echo "" >&2
        echo "  SOF VERIFY SEAM: verify_dual takes (fw_ptr, fw_len," >&2
        echo "  paideia_sig, paideia_pk, vendor_sig, vendor_pk)." >&2
        echo "  Widening to accept a signature LENGTH would let a" >&2
        echo "  caller mint a shorter buffer than ML-DSA-65 demands." >&2
        echo "  Both signature buffers are 3309 bytes per FIPS 204" >&2
        echo "  §5.4. If a signature legitimately changed, §0 of" >&2
        echo "  sof_verify.pdx must be rewritten first." >&2
        exit 1
    fi
}
hda_sv_pin_one 'pub let hda_sof_verify_dual : (u64, u64, u64, u64, u64, u64) -> u64'
hda_sv_pin_one 'pub let hda_sof_verify_dual_is_ok : (u64) -> u64'
hda_sv_pin_one 'pub let hda_sof_verify_arbitrated : () -> u64'
echo "[hda-sof-verify-confine] dual-sig seam arities pinned"


OBJECTS=( "${BOOT_STUB_OBJ}" "${USERBIN_OBJ}" "${AP_TRAMP_EMBED_OBJ}" "${AP_TRAMP_OFF_OBJ}" "${OBJECTS[@]}" )

if [[ ${#OBJECTS[@]} -eq 0 ]]; then
    echo "no .pdx files found under ${KERNEL_SRC}" >&2
    exit 1
fi

# Symbol export now provides uart_init/uart_puts definitions
# tools/stubs.S is no longer needed for linking
# echo "[stub] tools/stubs.S — Phase-7-in-progress link stubs"
# STUBS_OBJ="${BUILD_DIR}/stubs.o"
# as --64 -o "${STUBS_OBJ}" "${REPO_ROOT}/tools/stubs.S"
# OBJECTS+=("${STUBS_OBJ}")

echo "[link] ld -T link.ld -> kernel.elf"
# paideia-as 0.6.0 doesn't yet emit top-level let-fn bindings as named ELF
# symbols (the encoder ships them as a synthetic `add_one` placeholder), so
# inter-file references like `call uart_init` show up as undefined PLT32
# relocations at link time. tools/stubs.S provides empty `ret` bodies for
# each placeholder symbol; ld resolves the PLT32 relocs against them. The
# kernel returns through these stubs at runtime (no UART, no init) but the
# image links and QEMU can load it. Real symbol-export lands in a later
# paideia-as phase.
ld -nostdlib --warn-common --fatal-warnings -T "${LINK_SCRIPT}" -o "${BUILD_DIR}/kernel.elf" "${OBJECTS[@]}"

echo "[audit] R_X86_64_32 relocations must not target high-VA (>= 0xffff800000000000) symbols"

NM_MAP="${BUILD_DIR}/.nm.map"
SEC_MAP="${BUILD_DIR}/.sec.map"

nm build/kernel.elf | awk 'NF>=3 {print $3, $1}' > "${NM_MAP}"
readelf -SW build/kernel.elf \
    | awk '$2 ~ /^[0-9]+\]$/ && $3 != "NULL" {print $3, $5}' > "${SEC_MAP}"

AUDIT_FAIL=0
for obj in "${OBJECTS[@]}"; do
    while IFS= read -r target; do
        [[ -z "${target}" ]] && continue
        if [[ "${target}" == .* ]]; then
            vma=$(awk -v s="${target}" '$1==s {print $2; exit}' "${SEC_MAP}")
        else
            vma=$(awk -v s="${target}" '$1==s {print $2; exit}' "${NM_MAP}")
        fi
        [[ -z "${vma}" ]] && continue
        if [[ "${vma}" == ffff8* ]]; then
            echo "[audit] FAIL: ${obj#"${BUILD_DIR}"/}: R_X86_64_32 -> ${target} @ 0x${vma}" >&2
            AUDIT_FAIL=1
        fi
    done < <(readelf -r "${obj}" 2>/dev/null \
             | awk '$3 == "R_X86_64_32" || $3 == "R_X86_64_32S" {print $5}' \
             | sort -u)
done

if [[ ${AUDIT_FAIL} -ne 0 ]]; then
    echo "[audit] R_X86_64_32 high-VA audit failed — see #490 census, #494 policy" >&2
    exit 1
fi
echo "[audit] R_X86_64_32 relocations clean (all targets low-VA)"

echo "[verify] kernel syscall dispatch alignment"
"${REPO_ROOT}/tools/verify-syscall-dispatch.sh" "${BUILD_DIR}/kernel.elf" || {
    echo "[FAIL] syscall dispatch verification failed" >&2
    exit 1
}

echo "[verify] sched_block/sched_wake precondition guards (#663)"
"${REPO_ROOT}/tools/verify-sched-guards.sh" "${BUILD_DIR}/kernel.elf" || {
    echo "[FAIL] sched guards verification failed" >&2
    exit 1
}

echo "[verify] tty_read blocking wrapper real body (#667)"
"${REPO_ROOT}/tools/verify-tty-read-wrapper.sh" || {
    echo "[FAIL] tty_read wrapper verification failed" >&2
    exit 1
}

echo "[ok] ${BUILD_DIR}/kernel.elf"
