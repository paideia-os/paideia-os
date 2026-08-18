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
obj_relocs_against() {
    local out
    out="$(objdump -r "$1" 2>/dev/null)" || return 1
    grep -qE -- "$2([^a-zA-Z0-9_]|\$)" <<< "${out}"
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
while IFS= read -r -d '' pdx; do
    rel="${pdx#"${KERNEL_SRC}"/}"
    obj="${BUILD_DIR}/${rel%.pdx}.o"
    mkdir -p "$(dirname "${obj}")"
    echo "[build] paideia-as ${rel} -> ${obj#"${BUILD_DIR}"/}"
    "${PAIDEIA_AS}" build --emit elf64 "${pdx}" -o "${obj}"
    OBJECTS+=("${obj}")
done < <(find "${KERNEL_SRC}" -name '*.pdx' -not -path '*/boot_panic/*' -not -path '*/boot_exc3/*' -print0 | sort -z)

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
    local sym="$1" owner="${BUILD_DIR}/$2" strays=""
    if ! obj_relocs_against "${owner}" "${sym}"; then
        echo "[ec-confine] FAIL - owner $2 does not reference ${sym}" >&2
        echo "  A confinement assertion that names a symbol its owner does not" >&2
        echo "  use is vacuous; it would pass after the storage was deleted." >&2
        EC_CONFINE_OK=0
        return
    fi
    for o in "${OBJECTS[@]}"; do
        [[ "${o}" == "${owner}" ]] && continue
        if obj_relocs_against "${o}" "${sym}"; then
            strays="${strays} ${o#"${BUILD_DIR}"/}"
        fi
    done
    if [[ -n "${strays}" ]]; then
        echo "[ec-confine] FAIL - objects other than $2 relocate against" >&2
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
