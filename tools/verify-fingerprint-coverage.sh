#!/usr/bin/env bash
# R49.M3 / #1578 — emitted-vs-asserted fingerprint coverage gate.
#
# WHAT THIS POLICES
#
# Every "... OK" fingerprint the kernel, the loader stubs or a synth
# witness can print must be asserted by at least one expected/golden
# file under tests/**. A marker that is emitted and asserted nowhere is
# a hole that is INVISIBLE BY CONSTRUCTION: the string still appears in
# the serial log on every boot, so reading the log confirms the
# subsystem ran while proving nothing at all about whether the test
# suite would notice its absence.
#
# That is not hypothetical. Commit 3212fdb found two such markers
# (`R30 KIND_OP_REGION OK`, `R17 BIN TRUE SEED OK`). Issue #1578 then
# found SEVEN more by mechanical sweep, three of them KPTI — the
# kernel/user page-table isolation boundary. If kpti_stacks/isr/desc
# setup had silently stopped running, the whole 14-mode matrix would
# have stayed green. Two occurrences of the same defect class is the
# argument for a gate rather than a third fix.
#
# MATCHING SEMANTICS
#
# tools/run-smoke.sh does ordered-SUBSTRING matching of golden lines
# against the serial log, so this gate mirrors that: an emitted marker
# M is considered asserted if some golden line A satisfies
#
#     M.startswith(A)      — A asserts a prefix of M
#                            (e.g. golden `PAT INIT OK` vs emitted
#                            `PAT INIT OK slot4=WC`)
#  or A.startswith(M)      — the marker is a static prefix and the
#                            golden additionally pins the runtime value
#                            suffix (e.g. emitted tag `M8 MAXLINE OK`
#                            vs golden `M8 MAXLINE OK len=0x`)
#
# and A itself contains the `OK` token. That last clause matters: without
# it the one-character golden line `B` (the very first boot byte) is a
# prefix of `BLOB SIG OK` and silently "covers" it.
#
# WHAT IT DOES *NOT* PROVE
#
# Coverage here means "some golden asserts this string", not "the
# assertion bites". Non-vacuousness is proved per-marker by perturbing
# the golden line and observing the mode fail; see the #1578 commit
# message. This gate is the cheap mechanical half — it stops a NEW
# unwitnessed marker from being introduced at all.
#
# EXTRACTION FORMS
#
#   *.S    — `.ascii` / `.asciz "..."`
#   *.pdx  — `let NAME : [u8; N] = "..."`      (string literal form)
#   *.pdx  — `let NAME : [u8; N] = [ 0xNNu8, ... ]`  (byte-array form;
#            src/kernel/boot/verify_self.pdx uses this, and the #1578
#            sweep that missed `EFI SIGNATURE OK` missed it for
#            exactly this reason)
#
# A VACUITY GUARD fires if the extractor finds implausibly few markers
# or zero asserted lines — i.e. if a future refactor of the tag
# declaration style makes these regexes stop matching. Without it this
# gate would "pass" by scanning nothing, which is the failure mode it
# exists to prevent.
#
# Exit 0 = every emitted marker is asserted or explicitly allowlisted.
# Exit 1 = uncovered marker, stale allowlist entry, or vacuous scan.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

python3 - "${REPO_ROOT}" <<'PYEOF'
import os, re, sys

ROOT = sys.argv[1]

# ---------------------------------------------------------------------------
# ALLOWLIST — markers that are emitted but that NO mode can assert.
#
# Every entry needs a reason that is checkable, not a shrug. "Nothing
# reaches it" is only acceptable when the reason says WHY nothing reaches
# it and what would change that. Entries are verified live: an allowlisted
# marker that has since become asserted, or that no longer exists in the
# tree, FAILS this gate rather than rotting in place.
# ---------------------------------------------------------------------------

ALLOWLIST = {
    # -- Section A: production (src/kernel/**) markers on genuinely
    #    unreachable paths. Triaged for #1578.

    # src/kernel/core/iommu/vtd_fault.pdx — vtd_fault_dispatch's own
    # header says "NOT WIRED AT M4 BOOT", and a tree-wide grep confirms
    # no caller in src/ or tests/. The function is reachable only once
    # R23 gives it an IDT handler context. No QEMU mode can reach it,
    # opt-in or otherwise, because nothing calls it.
    "VTD FAULT HANDLER OK":
        "vtd_fault_dispatch has no caller anywhere in the tree (its own "
        "header: 'NOT WIRED AT M4 BOOT'); reachable from R23 IDT wiring.",

    # src/kernel/core/driver/sig_telemetry.pdx — blob_sig_audit selects
    # this tag only for verdict == 0, i.e. a driver blob whose dual
    # signature VERIFIES. Under the R25.M5 dev-bypass convention no boot
    # fixture carries a valid ML-DSA signature, so every audit in every
    # mode lands on verdict 1 (BLOB SIG UNSIGNED) or verdict < 0 (BLOB
    # SIG REJECT) — both of which do appear in the log and neither of
    # which contains an OK token. Becomes assertable when R32 lands the
    # real ML-DSA-65 verify primitive and a signed fixture blob.
    "BLOB SIG OK":
        "emitted only for verdict==0 (signature verifies); no boot fixture "
        "is validly signed under the R25.M5 dev-bypass keyring. Needs R32.",

    # src/kernel/core/mm/pf_handler.pdx — the COW SPLIT arm requires a
    # write fault on a page whose refcount is >= 2. The R14b COW witness
    # builds a private page (refcount 1) and takes the fast-flip arm,
    # which is why PF COW FLIP OK prints and this does not. Asserting it
    # needs a witness that faults on a genuinely shared frame; the
    # R15 CLONE COW witnesses create such frames but never write to them.
    "PF COW SPLIT OK":
        "COW split arm needs a write fault on a refcount>=2 frame; no "
        "witness writes to a shared frame (the R14b COW witness is "
        "refcount==1, hence PF COW FLIP OK).",

    # src/kernel/boot/verify_self.pdx — emitted only on the UEFI boot
    # path (kernel_main_uefi), which the 14-mode matrix never takes: all
    # 14 modes boot via -kernel with tools/boot_stub.S. The one opt-in
    # UEFI path (PAIDEIA_UEFI_OVMF=1 -> tools/run-uefi-ovmf.sh) is a
    # single-marker grep with no golden file, and per
    # design/roadmap/r19-t14-g4-boot-guide.md §4 it stops at the pre-EBS
    # hello banner, before verify_self runs at all.
    "EFI SIGNATURE OK":
        "UEFI-only path; the 14-mode matrix boots via -kernel, and the "
        "opt-in OVMF fixture stops at the pre-EBS banner (R19.M5).",

    # -- Section B: synth-witness markers under tests/**, each emitted
    #    only by an opt-in mode or a real-hardware smoke that the default
    #    matrix never runs. Verified against a full default-matrix boot
    #    log (/tmp/paideia-os-smoke.log): ZERO occurrences of each of the
    #    strings below. These are a test's own product — their absence is
    #    a test-authoring gap in the opt-in mode that owns them, not a
    #    silent production regression, which is the class this gate is
    #    for. Listed individually rather than exempted by directory so
    #    that a NEW test-side marker still trips the gate.
    #
    # #1570 (R49 audit): "ACPI HPET OK", "ACPI MADT OK", "ACPI MCFG OK",
    # "ACPI RSDP OK", "ACPI XSDT OK" were previously listed here as
    # "no default mode" alongside "ACPI FADT OK", but their parsers had
    # the same audit exposure #1066 exposed on the FADT: a witness that
    # exists but is never invoked. They are now wired inside
    # src/kernel/boot/witness/r30_platform.pdx (rsdp_synth_witness_call,
    # acpi_xsdt_synth_witness_call, madt_synth_witness_call,
    # mcfg_synth_witness_call, hpet_synth_witness_call) and asserted in
    # tests/r17/shell-shutdown.golden alongside "ACPI FADT OK".
    "ACPI T14G4 OK":  "tests/kernel/acpi/t14_g4_fixture.pdx — T14 G4 hardware fixture",
    "PCI T14G4 OK":   "tests/kernel/pci/t14_g4_fixture.pdx — T14 G4 hardware fixture",
    "MSIX IR ROUND ROBIN OK":
        "tests/kernel/iommu/msix_ir_round_robin.pdx — PAIDEIA_R22_MSIX_IR opt-in",
    "VTD SLPT WITNESS OK":
        "tests/kernel/iommu/vtd_slpt_synth.pdx — VT-d synth, no default mode",
    "VTD DMA FAULT OK reason=0x22":
        "tests/kernel/iommu/dma_fault_regression.pdx — VT-d synth, no default mode",
    "NVME HW SMOKE IDENTIFY-NS OK":
        "tests/kernel/drivers/nvme/hw_smoke.pdx — PAIDEIA_HW_SMOKE, real hardware only",
    "XHCI KBD SMOKE REPORT OK":
        "tests/kernel/drivers/xhci/keyboard_witness.pdx — PAIDEIA_HW_SMOKE, real hardware only",
    "XHCI KBD SMOKE TRANSLATE OK":
        "tests/kernel/drivers/xhci/keyboard_witness.pdx — PAIDEIA_HW_SMOKE, real hardware only",
    "PDXFS CORRUPT SB OK":
        "tests/kernel/fs/pdxfs_lite_corrupt_sb.pdx — PAIDEIA_R25_PDXFS_CORRUPT opt-in",
    "PDXFS E2E OK mounted=1":
        "tests/kernel/fs/pdxfs_lite_e2e_witness.pdx — PAIDEIA_R25_PDXFS_E2E opt-in",
    "TLB SHOOTDOWN WITNESS OK":
        "tests/kernel/mm/tlb_shootdown_race.pdx — SMP shootdown synth, no default mode",
    "UEFI PHYSMAP SYNTH OK":
        "tests/kernel/mm/uefi_physmap_synthetic.pdx — UEFI physmap synth, no default mode",
    "XSAVE SYNTH OK":
        "tests/kernel/cpu/xsave_synth.pdx — needs QEMU_CPU=max (PAIDEIA_R21_YMM opt-in)",

    # src/tools/mkfs-pdxb/main.pdx — userspace mkfs-pdxb binary's
    # success line (#1730). Not reachable from any QEMU boot mode: the
    # kernel does not exec mkfs-pdxb, and no host-tools build target is
    # wired yet (#1730 flagged as follow-up). Becomes assertable when a
    # host-tools build target lands and a host-side test invokes the
    # binary (see the Python layout test #1735 as the eventual driver).
    "MKFS PDXB OK":
        "userspace mkfs-pdxb binary success line; no boot mode execs it "
        "and no host-tools build target is wired yet (#1730 follow-up).",

    # src/kernel/boot/witness/pdxfs_reboot_verify_smoke.pdx — LIVE arm's
    # first-boot branch (SB_FLAG_CLEAN not set post-mkfs, #1725). The
    # default 14-mode matrix boots substrate (no live NVMe), so mount
    # refuses and the witness lands on the SUBSTRATE fingerprint that
    # IS in the golden. This FIRST branch only fires in phase-1 of the
    # opt-in two-phase LIVE mode (boot_r53_round_trip_phase1, #1751),
    # where the disk is freshly mkfs'd and mounted for the first time.
    "PDXFS REBOOT VERIFY FIRST OK":
        "LIVE first-boot arm: mount succeeds and sb_flags bit 0 CLEAR. "
        "Default modes take the SUBSTRATE arm; assertable via "
        "boot_r53_round_trip_phase1 opt-in (PAIDEIA_R53_DISK=1, #1751).",
}

# Below these counts the extractor has stopped matching rather than the
# tree having gotten cleaner. #1578's sweep found 156 emitted production
# markers; 120 leaves generous headroom for deletions without letting a
# broken regex pass silently.
MIN_EMITTED  = 120
MIN_ASSERTED = 60

PDX_STR = re.compile(
    r'^\s*(?:pub\s+)?let\s+(?:mut\s+)?[A-Za-z_0-9]+\s*:\s*'
    r'\[\s*u8\s*;\s*\d+\s*\]\s*=\s*"((?:[^"\\]|\\.)*)"')
PDX_ARR = re.compile(
    r'^\s*(?:pub\s+)?let\s+(?:mut\s+)?[A-Za-z_0-9]+\s*:\s*'
    r'\[\s*u8\s*;\s*\d+\s*\]\s*=\s*\[')
S_ASCII  = re.compile(r'\.(?:ascii|asciz)\s+"((?:[^"\\]|\\.)*)"')
BYTE_TOK = re.compile(r'0[xX]([0-9a-fA-F]{2})u8')
OK_TOK   = re.compile(r'(^|[^A-Za-z0-9_])OK([^A-Za-z0-9_]|$)')

def unesc(s):
    return (s.replace('\\n', '\n').replace('\\r', '\r').replace('\\t', '\t')
             .replace('\\0', '\0').replace('\\"', '"').replace('\\\\', '\\'))

def norm(s):
    return unesc(s).replace('\0', '').replace('\r', '').strip('\n')

emitted = {}

def add(lit, loc):
    if OK_TOK.search(lit):
        emitted.setdefault(lit, set()).add(loc)

for top in ('src', 'tools', 'tests'):
    for dp, dns, fns in os.walk(os.path.join(ROOT, top)):
        # tools/paideia-as is the submodule toolchain, not our fingerprints.
        dns[:] = [d for d in dns if d not in ('paideia-as', 'build', 'target')]
        for fn in fns:
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, ROOT)
            try:
                lines = open(p, errors='replace').read().splitlines()
            except OSError:
                continue
            if fn.endswith('.S'):
                for i, ln in enumerate(lines, 1):
                    for m in S_ASCII.finditer(ln):
                        add(norm(m.group(1)), f"{rel}:{i}")
            elif fn.endswith('.pdx'):
                i = 0
                while i < len(lines):
                    ln = lines[i]
                    m = PDX_STR.match(ln)
                    if m:
                        add(norm(m.group(1)), f"{rel}:{i+1}")
                    elif PDX_ARR.match(ln):
                        # Byte-array form: accumulate 0xNNu8 tokens until the
                        # bracket nesting closes (comments stripped first, so
                        # a `]` inside a `//` note cannot end the scan early).
                        buf, j, depth = [], i, 0
                        while j < len(lines) and j < i + 400:
                            seg = lines[j].split('//')[0]
                            buf.append(seg)
                            depth += seg.count('[') - seg.count(']')
                            if depth <= 0:
                                break
                            j += 1
                        bs = BYTE_TOK.findall('\n'.join(buf))
                        if bs:
                            add(norm(bytes(int(b, 16) for b in bs)
                                     .decode('latin-1')), f"{rel}:{i+1}")
                        i = j
                    i += 1

asserted = set()
for dp, dns, fns in os.walk(os.path.join(ROOT, 'tests')):
    for fn in fns:
        if fn.endswith('.golden') or (fn.startswith('expected-')
                                      and fn.endswith('.txt')):
            for ln in open(os.path.join(dp, fn),
                           errors='replace').read().splitlines():
                ln = ln.rstrip()
                if ln and OK_TOK.search(ln):
                    asserted.add(ln)

def covered_by(marker):
    for a in asserted:
        if marker.startswith(a) or a.startswith(marker):
            return a
    return None

fail = 0

# Vacuity guard — see header.
if len(emitted) < MIN_EMITTED or len(asserted) < MIN_ASSERTED:
    print(f"[fingerprint-coverage] VACUOUS SCAN: emitted={len(emitted)} "
          f"(min {MIN_EMITTED}), asserted={len(asserted)} (min {MIN_ASSERTED})",
          file=sys.stderr)
    print("  The extractor matched implausibly little. A tag declaration "
          "style change has almost certainly broken the regexes above; this "
          "gate would otherwise pass by scanning nothing.", file=sys.stderr)
    sys.exit(1)

uncovered = []
for m in sorted(emitted):
    if m in ALLOWLIST:
        continue
    if covered_by(m) is None:
        uncovered.append(m)

if uncovered:
    fail = 1
    print("[fingerprint-coverage] UNWITNESSED FINGERPRINTS (#1578 class):",
          file=sys.stderr)
    for m in uncovered:
        print(f"  {m!r}", file=sys.stderr)
        for loc in sorted(emitted[m]):
            print(f"      emitted at {loc}", file=sys.stderr)
    print("", file=sys.stderr)
    print("  Each of these prints on a boot and is asserted in NO expected/",
          file=sys.stderr)
    print("  golden file. Add it to the golden of a mode that reaches it, at",
          file=sys.stderr)
    print("  the correct ordered position, and prove the assertion bites by",
          file=sys.stderr)
    print("  perturbing the line and watching that mode fail. If no mode can",
          file=sys.stderr)
    print("  reach it, add an ALLOWLIST entry in this file WITH A REASON.",
          file=sys.stderr)

# Stale-allowlist checks: an exemption that is no longer true is a lie in
# the source tree, so it fails just as loudly as a missing assertion.
for m, why in sorted(ALLOWLIST.items()):
    if m not in emitted:
        fail = 1
        print(f"[fingerprint-coverage] STALE ALLOWLIST: {m!r} is allowlisted "
              f"but is no longer emitted anywhere. Delete the entry.",
              file=sys.stderr)
        continue
    a = covered_by(m)
    if a is not None:
        fail = 1
        print(f"[fingerprint-coverage] REDUNDANT ALLOWLIST: {m!r} is now "
              f"asserted by golden line {a!r}. Delete the entry so the "
              f"assertion is what holds it, not the exemption.", file=sys.stderr)

if fail:
    sys.exit(1)

print(f"[fingerprint-coverage] PASS — {len(emitted)} emitted markers, "
      f"{len(emitted) - len(ALLOWLIST)} asserted, "
      f"{len(ALLOWLIST)} allowlisted with reasons")
PYEOF

rc=$?
if [[ ${rc} -ne 0 ]]; then
    echo "[fingerprint-coverage] FAIL (#1578 gate)" >&2
    exit 1
fi
exit 0
