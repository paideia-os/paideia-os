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
