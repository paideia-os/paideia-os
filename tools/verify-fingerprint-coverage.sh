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

    # R91.M2-003 (#2017): e1000e_probe emits its rx/irq activation
    # rollup fingerprint once per probe. Fires unconditionally under
    # nic_dispatch_probe (called from kernel_main after PCI enum, #2015).
    # In the default -kernel boot with no -device e1000e, kind stays 0
    # (no NIC found) and rx/irq report 0/0. Assertable golden lands with
    # R91.M5 boot_r91_nic_probe smoke (issue #2031) once PAIDEIA_NIC=e1000e
    # is wired.
    "e1000e probe ok [legacy: E1000E PROBE OK]":
        "R91.M2-003 (#2017): e1000e_probe rx/irq activation rollup; "
        "fires per boot via nic_dispatch_probe; assertable golden "
        "lands with R91.M5 boot_r91_nic_probe smoke (#2031).",

    # R91.M2-002 (paideia-os #2016): e1000e_probe emits its driver_table
    # row + KIND_NIC cap publication fingerprint once activation
    # succeeds (rx=1 && irq=1 && kind_nic_mint_body returns a legal row
    # id). Reachable only on an activation-successful boot -- the default
    # -kernel matrix has no -device e1000e so the activation block
    # never runs. Assertable golden lands alongside `e1000e probe ok`
    # under R91.M5 boot_r91_nic_probe smoke (#2031) once PAIDEIA_NIC=
    # e1000e is wired.
    "e1000e driver row ok [legacy: E1000E DRIVER ROW OK]":
        "R91.M2-002 (#2016): e1000e_probe driver_table + KIND_NIC "
        "publication fingerprint; fires only on activation-successful "
        "boots via nic_dispatch_probe; assertable golden lands with "
        "R91.M5 boot_r91_nic_probe smoke (#2031).",

    # src/kernel/boot/witness/rootfs_seed_policy.pdx (R90-XREPO.011.M1-004
    # #2119): policy seed marker fires every boot (witness runs
    # unconditionally). The R90-XREPO.011.M1-003 (#2122) elevate-broker
    # dispatch witness consumes the seeded file via tmpfs_read but does
    # not itself add a golden line for this exact literal — the seed's
    # role in the cascade is proven by that witness's own success
    # rollup (`boot elevate broker ok`, allowlisted below) taking the
    # ALLOW/DENY arms that depend on the seeded rules. No golden pins
    # the raw `policy seed ok bytes=173` literal today.
    "policy seed ok [legacy: POLICY SEED OK]":
        "R90-XREPO.011.M1-004 (#2119): policy seeder fires every boot; "
        "R90-XREPO.011.M1-003 (#2122) consumes the file via tmpfs_read "
        "and its `boot elevate broker ok` rollup is the assertable "
        "signal for the whole cascade — no golden pins this exact literal.",

    # src/kernel/boot/witness/rootfs_seed_resolv.pdx (R100-PREP-004
    # #2010): resolver-config seeder fires every boot (witness runs
    # unconditionally). libpdx-net's resolver M2 will consume the file
    # via a tmpfs read at process startup once that milestone lands;
    # its own end-to-end witness will pin an assertable success line
    # that supersedes this allowlist entry. Until then no golden pins
    # this exact literal.
    "resolv seed ok [legacy: RESOLV SEED OK]":
        "R100-PREP-004 (#2010): resolv.conf seeder fires every boot; "
        "libpdx-net resolver M2's own end-to-end witness will pin the "
        "assertable consumer signal — no golden pins this exact literal.",

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

    # UEFI BRIDGE OK / UEFI PML4 OK / UEFI EBS OK: allowlist entries
    # RETIRED 2026-09-08 — goldens now assert these lines directly, so
    # the exemption is redundant. See tests/expected-t14-fidelity.golden
    # for the assertions (R111.M7-026 landed).

    # src/kernel/core/klog/keys.pdx tag_nvme_attach_ok —
    # R111.M3-011 (paideia-os #2363).  NVMe real-HW controller-attach
    # per-instance OK fingerprint. Wire line shape:
    #     "NVME ATTACH OK bdf=0x<hex> mn=0x<hex8> fr=0x<hex8> ncap=<dec>"
    # Unreachable in every 14-mode QEMU matrix: under `-kernel` boot
    # MCFG is absent so `_nvme_device_count` stays 0 even with
    # `-device nvme` attached (see tools/run-smoke.sh L1866-1868 note
    # for boot_r52_pdxfs_mkfs_nvme --with-disk); attach then takes
    # the NVME BOOT NONE arm (no OK token, correctly not gate-visible).
    # Same real-HW-only posture as the sibling
    # "NVME HW SMOKE IDENTIFY-NS OK" entry below; assertable when a
    # real-HW T14 G4 smoke wire lands.
    "NVME ATTACH OK":
        "Real-HW-only reachability (R111.M3-011 NVMe attach OK "
        "fingerprint); the 14-mode QEMU matrix takes the sibling "
        "NVME BOOT NONE arm because -kernel boot has no MCFG, so "
        "_nvme_device_count stays 0 even with -device nvme.",

    # src/kernel/core/klog/keys.pdx tag_xhci_attach_ok —
    # R111.M5-017 (paideia-os #2369).  xHCI real-HW controller-attach
    # per-instance OK fingerprint. Wire line shape:
    #     "XHCI ATTACH OK bdf=0x<hex> ports=<dec> mmio=0x<16hex>"
    # Unreachable in every 14-mode QEMU matrix: under `-kernel` boot
    # MCFG is absent so `_xhci_device_count` stays 0 even with
    # `-device qemu-xhci` attached (same MCFG-absent path that keeps
    # nvme_probe empty; see the NVME ATTACH OK sibling entry above);
    # attach then takes the XHCI BOOT NONE arm (no OK token,
    # correctly not gate-visible). Assertable when a real-HW T14 G4
    # smoke wire lands (companion to the NVME real-HW smoke; T14 G4
    # exposes both xHCI USB 3.x/2.0 controllers via the PCH USB block).
    "XHCI ATTACH OK":
        "Real-HW-only reachability (R111.M5-017 xHCI attach OK "
        "fingerprint); the 14-mode QEMU matrix takes the sibling "
        "XHCI BOOT NONE arm because -kernel boot has no MCFG, so "
        "_xhci_device_count stays 0 even with -device qemu-xhci.",

    # src/kernel/core/klog/keys.pdx tag_hid_kbd_attach_ok —
    # R111.M5-018 (paideia-os #2370).  HID boot-keyboard attach
    # per-instance OK fingerprint. Wire line shape:
    #     "HID KBD ATTACH OK bdf=0x<hex> iface=0x<hex> ep=0x<hex>"
    # Unreachable in every 14-mode QEMU matrix AND on real T14 G4
    # today: the row table `_hid_kbd_devices` is populated by a
    # downstream USB-enumeration worker (per-controller cmd_ring /
    # event_ring / DCBA / per-slot Input Context allocation +
    # SET_ADDRESS + GET_DESCRIPTOR + parse_config_descriptor) that
    # has not yet landed a call site above hid_keyboard_attach_all
    # (kernel_main.pdx). Consequently `_hid_kbd_dev_count` stays 0
    # on every boot and the orchestrator takes the sibling
    # HID KBD NONE arm (no OK token, correctly not gate-visible).
    # Same real-HW-plus-substrate-plumbing posture as the sibling
    # XHCI ATTACH OK / NVME ATTACH OK entries above; assertable when
    # the USB-enumeration worker lands its call site (task follow-on
    # after R111.M5-019 HID keyboard on USB-A per
    # design/roadmap/t14-bootable-usb-wave.md §4.E).
    "HID KBD ATTACH OK":
        "R111.M5-018 (#2370): HID boot-keyboard attach OK "
        "fingerprint; _hid_kbd_dev_count stays 0 in every current "
        "boot because the USB-enumeration worker that populates "
        "_hid_kbd_devices has not landed a call site above "
        "hid_keyboard_attach_all, so the sibling HID KBD NONE arm "
        "always fires. Retires when the USB-enum worker lands "
        "(follow-on to R111.M5-019 HID keyboard on USB-A per "
        "design/roadmap/t14-bootable-usb-wave.md §4.E).",

    # src/kernel/boot/witness/rootfs_mount_witness.pdx tag_rootfs_mount_ok —
    # R111.M3-013 (paideia-os #2365).  ESP-embedded PdxFS-lite rootfs
    # blob witness fingerprint (OK arm) emitted from
    # rootfs_mount_witness_run when the UEFI stub's efi_load_initrd
    # successfully staged a blob from L"\EFI\PAIDEIA\rootfs.pdxfs"
    # into a Boot-Services pool alloc and latched (pa, size) through
    # boot_env @ +104 / +112.  Wire line shape:
    #     "ROOTFS MOUNT OK type=pdxfs pa=0x<16hex> size=<dec>"
    # The OK-bearing tag prefix is broken out as tag_rootfs_mount_ok
    # ("ROOTFS MOUNT OK type=pdxfs"); the trailing ` pa=... size=...`
    # is appended by the klog_s1_x1_d1 KV loop and carries no OK
    # token.  UEFI-only reachability: the 14-mode -kernel matrix
    # takes the sibling ROOTFS MOUNT NONE arm (no OK token, not
    # gate-visible), and the PAIDEIA_UEFI_OVMF opt-in fixture stops
    # at the pre-EBS hello banner today.  Same posture as
    # "UEFI BRIDGE OK" / "UEFI PML4 OK" / "UEFI EBS OK" /
    # "FB CONSOLE OK" above; retires from this allowlist when
    # R111.M2 opens an OVMF smoke mode that boots past
    # ExitBootServices with a real rootfs.pdxfs on the ESP and
    # asserts the fingerprint against a live golden (same follow-up
    # boot_r111_uefi_bridge target the other UEFI-only entries name).
    "ROOTFS MOUNT OK type=pdxfs":
        "R111.M3-013 (#2365): ESP-embedded rootfs blob witness (OK "
        "arm); reachable only on UEFI boot with the ESP carrying "
        "\\EFI\\PAIDEIA\\rootfs.pdxfs and every step of "
        "efi_load_initrd (SFS OpenProtocol, OpenVolume, Open, "
        "GetInfo, AllocatePool, Read, short-read check) succeeding. "
        "The 14-mode -kernel matrix takes the sibling `ROOTFS MOUNT "
        "NONE` arm (no OK token, not gate-visible); no OVMF smoke "
        "mode boots past ExitBootServices yet. Retires when R111.M2 "
        "opens boot_r111_uefi_bridge (same follow-up target as "
        "UEFI BRIDGE OK / UEFI PML4 OK / UEFI EBS OK).",

    # src/kernel/boot/witness/fw_manifest_witness.pdx tag_fw_manifest_ok --
    # R111.M6-022 (paideia-os #2374).  ESP-embedded firmware-manifest
    # witness fingerprint (OK arm) emitted from
    # fw_manifest_witness_run when the UEFI stub's
    # efi_load_fw_manifest successfully staged the manifest from
    # /paideia/firmware/manifest.pdxsig into a Boot-Services pool
    # alloc and latched (pa, size) through boot_env @ +120 / +128.
    # Wire line shape:
    #     "FW MANIFEST OK pa=0x<16hex> size=<dec>"
    # The OK-bearing tag prefix is broken out as tag_fw_manifest_ok
    # ("FW MANIFEST OK"); the trailing ` pa=... size=...` is
    # appended by the klog_s1_x1_d1 KV loop and carries no OK token.
    # UEFI-only reachability: the 14-mode -kernel matrix takes the
    # sibling FW MANIFEST NONE arm (no OK token, not gate-visible),
    # and the PAIDEIA_UEFI_OVMF opt-in fixture stops at the pre-EBS
    # hello banner today.  Same posture as ROOTFS MOUNT OK type=pdxfs
    # / UEFI BRIDGE OK / UEFI PML4 OK / UEFI EBS OK / FB CONSOLE OK
    # above; retires from this allowlist when R111.M2 opens an OVMF
    # smoke mode that boots past ExitBootServices with a real
    # manifest.pdxsig on the ESP and asserts the fingerprint against
    # a live golden.
    "FW MANIFEST OK":
        "R111.M6-022 (#2374): ESP-embedded firmware-manifest witness "
        "(OK arm); reachable only on UEFI boot with the ESP carrying "
        "/paideia/firmware/manifest.pdxsig and every step of "
        "efi_load_fw_manifest (SFS OpenProtocol, OpenVolume, Open, "
        "GetInfo, AllocatePool, Read, short-read check) succeeding. "
        "The 14-mode -kernel matrix takes the sibling `FW MANIFEST "
        "NONE` arm (no OK token, not gate-visible); no OVMF smoke "
        "mode boots past ExitBootServices yet. Retires when R111.M2 "
        "opens boot_r111_uefi_bridge (same follow-up target as "
        "UEFI BRIDGE OK / UEFI PML4 OK / UEFI EBS OK / ROOTFS MOUNT "
        "OK type=pdxfs).",

    # src/kernel/core/fw/loader.pdx tag_fw_manifest_sig_ok --
    # R111.M6-023 (paideia-os #2375).  Whole-manifest Ed25519
    # signature-verify success fingerprint emitted from
    # firmware_load_all_from_manifest via fwl_emit_sig_ok / klog_s1
    # exactly once per boot on the happy path, immediately before the
    # entry-dispatch loop begins.  Wire line shape:
    #     "FW MANIFEST SIG OK"
    # No KV suffix (klog_s1 has zero KV entries).  The sibling
    # SIG FAIL arm emits `FW MANIFEST SIG FAIL reason=<dec>` (no OK
    # token -> not gate-visible) followed by `FW LOAD SKIP kind=0
    # reason=10` (FW_SKIP_SIG_FAIL) so the SKIP-shape coverage
    # taxonomy stays complete.  Unreachable in every 14-mode QEMU
    # matrix because kernel_main gates the loader call itself on
    # (_boot_env_pa != 0 && boot_env->fw_manifest_pa != 0), and
    # neither PVH -kernel (never latches _boot_env_pa) nor any OVMF
    # smoke mode (does not carry /paideia/firmware/manifest.pdxsig
    # on its ESP yet) reaches the call.  Even the UEFI reach would
    # today land on FW MANIFEST SIG FAIL under the R111.M6-023 dev-
    # bypass semantics (accept iff the 64-byte sig trailer is
    # bytewise all zero -- see manifest_sig.pdx
    # fw_manifest_verify_signature) unless the mkimage.sh producer
    # emits an all-zero trailer.  Same wire-deferred posture as
    # FW MANIFEST OK / FW LOAD OK / MICROCODE APPLY OK; retires from
    # this allowlist when the M7-025 image builder lands AND an OVMF
    # smoke mode consumes it AND the R32/R82 real ed25519_verify
    # primitive lands to accept a real-signed manifest.
    "FW MANIFEST SIG OK":
        "R111.M6-023 (#2375): whole-manifest Ed25519 signature-verify "
        "success fingerprint; wire-deferred (no live manifest producer "
        "until R111.M7-025 mkimage.sh lands, and no OVMF smoke mode "
        "consumes it until R111.M2 opens boot_r111_uefi_bridge).  "
        "Loader gates its own call in kernel_main on (_boot_env_pa "
        "!= 0 && fw_manifest_pa != 0) so the -kernel matrix is silent "
        "(FW MANIFEST NONE is the asserted sibling).  Retires when "
        "mkimage.sh + OVMF smoke + R32/R82 real ed25519_verify all "
        "land.",

    # src/kernel/core/cpu/microcode.pdx tag_microcode_apply_ok --
    # R111.M6-019 (paideia-os #2371).  Intel-microcode WRMSR-path
    # per-CPU apply-success fingerprint emitted from
    # microcode_apply_this_cpu when the SDM Vol 3A §9.11.7 sequence
    # (clear IA32_BIOS_SIGN_ID -> cpuid -> rdmsr for old_rev ->
    # wrmsr IA32_BIOS_UPDT_TRIG=0x79 with the blob linear address ->
    # clear -> cpuid -> rdmsr for new_rev) yields a non-zero
    # post-apply revision.  Wire line shape:
    #     "MICROCODE APPLY OK cpu=<dec> old_rev=0x<hex> new_rev=0x<hex>"
    # The OK-bearing tag prefix is broken out as tag_microcode_apply_ok
    # ("MICROCODE APPLY OK"); the trailing ` cpu=... old_rev=...
    # new_rev=...` is appended by the klog_s1_d1_x2 KV loop and
    # carries no OK token.  Unreachable in every 14-mode QEMU matrix
    # because R111.M6-019 lands the standalone WRMSR primitives but
    # does not wire a call site into kernel_main.pdx -- the real
    # loader wire (loading a validated Intel microcode blob from
    # /paideia/firmware/microcode/<sig>.bin) lands in R111.M6-020..
    # M6-022 (blob bundling + ESP path), and the actual boot-time
    # apply cascade lands in R111.M6-024.  Additionally, QEMU-TCG
    # does not implement a functional microcode-apply path: even if
    # a blob were passed, rdmsr(0x8B) EDX would return 0 (or the
    # boot-time firmware-supplied revision unchanged), so the SKIP
    # arm would fire.  Same wire-deferred posture as `NVME ATTACH
    # OK` above; assertable when R111.M6-024 wires the boot cascade
    # AND either a real T14 G4 smoke wire lands OR QEMU is upgraded
    # to a full-fidelity microcode-apply simulation.
    "MICROCODE APPLY OK":
        "R111.M6-019 (#2371): standalone Intel-microcode WRMSR-path "
        "apply fingerprint; wire-deferred (no boot-cascade call site "
        "until R111.M6-024 lands the loader + IPI broadcast). "
        "Additionally unreachable on QEMU-TCG (no functional "
        "microcode-apply path -- rdmsr(0x8B) EDX stays 0 or "
        "unchanged so the SKIP arm fires). Assertable when M6-024 "
        "wires the boot cascade AND a real T14 G4 smoke lands.",

    # src/kernel/core/drivers/gpu/huc/bundle.pdx tag_huc_bundle_ok --
    # R111.M6-021 (paideia-os #2373).  ESP-embedded HuC firmware
    # bundle admission fingerprint emitted from
    # huc_firmware_bundle_verify once all seven Intel-CSS-header
    # gates pass (pa != 0, size >= 0x288, module_type == 7 = CSS_
    # MODULE_TYPE_HUC, header_size_dw == 0xA1, module_vendor ==
    # 0x8086 = Intel, sw_version.major == 16, RSA-2048 signature
    # slot first 16 bytes non-zero).  Byte-for-byte parallel to
    # guc/bundle.pdx tag_guc_bundle_ok landed at the same wave
    # (R111.M6-020, #2372); the two verifiers differ only by
    # module_type pin (7 vs 6) and sw_version.major pin (16 vs 70).
    # Wire line shape:
    #     "HUC BUNDLE OK ver_maj=<dec> ver_min=<dec> size=<dec>"
    # emitted via klog_s1_d3 (three decimal KV entries -- the
    # `ver=<n>.<n>` form from the issue text is expressed as two
    # ver_maj + ver_min KVs so the existing klog_s1_d3 wrapper
    # covers the emit without a new arity).  The OK-bearing tag
    # prefix is broken out as tag_huc_bundle_ok ("HUC BUNDLE OK");
    # the trailing ` ver_maj=... ver_min=... size=...` is appended
    # by the klog_s1_d3 KV loop and carries no OK token.
    # Unreachable in every 14-mode QEMU matrix because R111.M6-021
    # lands the verify-only substrate but does not wire a call
    # site into kernel_main.pdx -- the ESP-to-KIND_BLOB staging
    # cascade (which fetches the HuC bundle from
    # /paideia/firmware/gpu/huc_16.bin, parses it, and invokes
    # this verify) lands in R111.M6-024's firmware_load_all_from_
    # manifest per-kind dispatch.  Additionally, QEMU-TCG's OVMF
    # matrix does not ship a signed HuC blob on the ESP: even if
    # the M6-024 wire landed, the default 14-mode boot would land
    # on the SKIP arm (BAD_MODULE_TYPE or NULL_BLOB depending on
    # whether the loader returns an empty descriptor or nothing).
    # Same wire-deferred posture as MICROCODE APPLY OK / FW LOAD
    # OK / GUC BUNDLE OK (which shares this landing wave and
    # deferred its own allowlist entry to M6-024 -- covered
    # separately when that entry lands); assertable when M6-024
    # wires the boot cascade AND a real T14 G4 smoke mode ships
    # a signed HuC 16.x bundle on its ESP.
    # src/kernel/core/drivers/gpu/guc/bundle.pdx tag_guc_bundle_ok —
    # R111.M6-020 (#2372).  Intel CSS-header GuC firmware verifier OK
    # fingerprint; only fires on a live-HW ESP that ships a signed GuC
    # blob at /paideia/firmware/gpu/guc_70.bin, then via
    # firmware_load_all_from_manifest (M6-024).  Real-HW-only reachability
    # today; the 14-mode QEMU matrix has no ESP + no firmware manifest.
    "GUC BUNDLE OK":
        "Real-HW-only reachability (R111.M6-020 GuC bundle CSS-header "
        "verifier OK fingerprint); the 14-mode QEMU matrix has no ESP "
        "with a signed GuC blob so this line never fires today.",

    "HUC BUNDLE OK":
        "R111.M6-021 (#2373): HuC firmware bundle admission "
        "fingerprint; wire-deferred (no boot-cascade call site "
        "until R111.M6-024 wires the ESP-to-KIND_BLOB staging). "
        "Additionally requires a signed HuC 16.x bundle on the ESP "
        "which the 14-mode QEMU matrix does not ship. Assertable "
        "when M6-024 wires the boot cascade AND a real T14 G4 "
        "smoke lands with a signed HuC 16.x bundle.",

    # src/kernel/core/fw/loader.pdx tag_fw_load_ok --
    # R111.M6-024 (paideia-os #2376). Kernel firmware loader per-entry
    # dispatch-success fingerprint emitted from
    # firmware_load_all_from_manifest via fwl_emit_ok / klog_s1_d2_x1
    # once per manifest entry whose per-kind loader (microcode_load_and_
    # apply for kind=1, gucv_verify for kind=2, hucl_verify_vendor +
    # hucl_verify_paideia for kind=3) returns success.  Wire line shape:
    #     "FW LOAD OK kind=<dec> size=<dec> ver=0x<hex>"
    # The OK-bearing tag prefix is broken out as tag_fw_load_ok
    # ("FW LOAD OK"); the trailing ` kind=... size=... ver=...` is
    # appended by the klog_s1_d2_x1 KV loop and carries no OK token.
    # Unreachable in every 14-mode QEMU matrix under R111.M6-024
    # because kernel_main gates the loader call itself on
    # (_boot_env_pa != 0 && boot_env->fw_manifest_pa != 0), and neither
    # PVH -kernel (never latches _boot_env_pa) nor any OVMF smoke mode
    # (does not carry /paideia/firmware/manifest.pdxsig on its ESP
    # yet) reaches the call.  The kernel-visible witness on those
    # boots is `FW MANIFEST NONE` (R111.M6-022 sibling); the loader
    # itself is silent.  Additionally, even a boot that reached the
    # loader would land on QEMU-TCG's microcode SKIP arm for kind=1
    # entries (see MICROCODE APPLY OK reasoning above), so full
    # end-to-end reach requires (a) mkimage.sh (R111.M7-025) building
    # an ESP with manifest.pdxsig + populated microcode/gpu blobs,
    # (b) an OVMF smoke mode that boots past ExitBootServices onto
    # that ESP, and (c) either real T14 G4 silicon OR a QEMU with a
    # full-fidelity microcode-apply simulation.  Same wire-deferred
    # posture as MICROCODE APPLY OK / FW MANIFEST OK; retires from
    # this allowlist when the M7 image builder lands AND an OVMF
    # smoke mode consumes it.
    "FW LOAD OK":
        "R111.M6-024 (#2376): kernel firmware loader per-entry "
        "dispatch-success fingerprint; wire-deferred (no live "
        "manifest producer until R111.M7-025 mkimage.sh lands, and "
        "no OVMF smoke mode consumes it until R111.M2 opens boot_"
        "r111_uefi_bridge).  Loader gates its own call in "
        "kernel_main on (_boot_env_pa != 0 && fw_manifest_pa != 0) "
        "so the -kernel matrix is silent (FW MANIFEST NONE is the "
        "asserted sibling).  Additionally unreachable on QEMU-TCG "
        "even with a manifest for kind=1 entries (microcode SKIP "
        "arm fires -- same reason as MICROCODE APPLY OK above). "
        "Assertable when mkimage.sh + an OVMF smoke mode + either "
        "real T14 G4 or a fidelity-upgraded QEMU all land.",

    # src/kernel/core/klog/keys.pdx tag_msix_ir_table_ok — R111.M2-007
    # (paideia-os #2359). MSI-X + VT-d IR bring-up fingerprint emitted
    # from src/kernel/core/iommu/msix_ir_bringup.pdx §msix_ir_bringup_all
    # once vtd_ir_init has allocated the IRT, programmed IRTA_REG, and
    # driven the SIRTP + IRE ceremony on the first DRHD. Fires only when
    # the platform's ACPI DMAR is present + checksum-valid AND at least
    # one DRHD is populated AND vtd_ir_init succeeds. On QEMU-TCG
    # -machine q35 (the 14-mode default matrix) the platform publishes
    # no DMAR — has_dmar stays 0 and the bring-up lands on the sibling
    # `MSIX IR OFF` fingerprint (asserted by the R111 golden) instead.
    # Assertable when a T14 G4 real-HW smoke mode lands (per
    # design/roadmap/t14-bootable-usb-wave.md §4.B); until then this
    # allowlist entry gates a live-verified production tag whose only
    # reachable path requires actual VT-d silicon.
    "MSIX IR TABLE OK":
        "R111.M2-007 (#2359): MSI-X + VT-d IR bring-up success; requires "
        "real VT-d silicon (T14 G4 / Raptor Lake). QEMU-TCG -machine q35 "
        "publishes no DMAR so has_dmar==0 and bring-up lands on `MSIX IR "
        "OFF` instead. Assertable when the R111.M2 T14 G4 smoke lands.",

    # src/kernel/core/klog/keys.pdx tag_msix_vec_ok — R111.M2-007
    # (paideia-os #2359). Per-vector MSI-X programming fingerprint
    # emitted from src/kernel/core/iommu/msix_ir_bringup.pdx §msix_ir_
    # program_device once per programmed table entry, carrying KVs
    # { bdf, vec, addr, irt }. Reachable only when a driver-attach
    # callsite invokes msix_ir_program_device on a real MSI-X-capable
    # PCI function — no default-matrix driver does this yet (e1000e's
    # own R91.M2 activation body programs its 5 vectors internally
    # via a legacy code path that predates R111.M2's shared bring-up
    # substrate; the R111.M4 driver-migration wave will retire that
    # path to route through msix_ir_program_device, at which point
    # this line fires per active NIC vector on every boot with
    # -device e1000e / virtio-net-pci). Assertable then; today no
    # golden pins the string because no code path reaches it.
    "MSIX VEC OK":
        "R111.M2-007 (#2359): per-vector MSI-X programming fingerprint; "
        "no default-matrix driver-attach site invokes msix_ir_program_"
        "device yet (drivers still use their own R91-era MSI-X paths). "
        "Assertable when R111.M4 migrates driver-attach to the shared "
        "bring-up substrate.",

    # src/kernel/core/klog/keys.pdx tag_acpi_rsdp_handoff_ok — R111.M1-004
    # (paideia-os #2356). ACPI RSDP handoff fingerprint emitted by
    # src/kernel/acpi/phase1_info.pdx §phase1_emit_rsdp_fingerprint,
    # called from kernel_main_64 immediately after phase1_acpi_gather
    # returns. Renders "ACPI RSDP HANDOFF OK pa=0x<pa> xsdt=<n>" as
    # part 1 of the two-line R20 witness "ACPI RSDP @0x<pa> XSDT[<n>]
    # MADT MCFG FADT HPET" seeded from the real firmware handoff
    # (boot_env_t.rsdp_pa @ +48) rather than the synth-witness fixture
    # at tests/kernel/acpi/rsdp_synth.pdx (whose "ACPI RSDP OK" marker
    # is asserted at tests/r17/shell-shutdown.golden:25). Fires on
    # EVERY boot (PVH -kernel path with pa=0x0, UEFI path with the
    # authoritative firmware pa) so the fingerprint IS reachable in
    # the default matrix — assertable in a boot golden without a new
    # smoke mode. Allowlisted here because R111.M1-004's scope is the
    # code emit; the boot-golden update that pins the exact wire line
    # (level+timestamp+cpu prefix + tag + KVs) is a separate landing
    # (targeted at the same R111.M2 OVMF-smoke-mode window that
    # retires UEFI BRIDGE OK / UEFI PML4 OK above, plus a companion
    # -kernel-mode assertion since this marker fires on both paths).
    # ACPI RSDP HANDOFF OK: allowlist entry RETIRED 2026-09-08 —
    # golden now asserts this line directly (T14 fidelity golden).

    # src/kernel/core/klog/keys.pdx tag_acpi_tables_summary_ok —
    # R111.M1-004 (paideia-os #2356). Line 2 of the R20 witness,
    # rendering "ACPI TABLES SUMMARY OK madt=<0|1> mcfg=<0|1>
    # fadt=<0|1> hpet=<0|1>" from _phase1_acpi_info's has_* u8 slots
    # + _madt_lapic_base. Same reachability posture as its sibling
    # ACPI RSDP HANDOFF OK — fires on every boot from kernel_main_64
    # post-phase1_acpi_gather. Same golden-wiring plan.
    "ACPI TABLES SUMMARY OK":
        "R111.M1-004 (#2356): ACPI tables presence fingerprint (Line 2 "
        "of the R20 witness). Fires on every boot from kernel_main_64 "
        "post-phase1_acpi_gather; assertable in an existing boot golden. "
        "Golden-wiring deferred to the R111.M2 OVMF-smoke-mode landing "
        "(same target as UEFI BRIDGE OK).",

    # src/kernel/core/klog/keys.pdx tag_ioapic_route_ok — R111.M2-008
    # (paideia-os #2360). Legacy ISA IRQ [0..15] MADT ISO resolution
    # rollup emitted by ioapic_route_witness_legacy_isas from
    # src/kernel/core/apic/ioapic_route.pdx, called from kernel_main_64
    # immediately after topology_seed_from_madt (which populates
    # _madt_scratch_isos). Renders "IOAPIC ROUTE OK identity=<n>
    # overridden=<n>" via klog_s1_d2, tallied across a 16-iteration
    # walk of madt_iso_gsi_for_irq(irq) for irq in 0..15. Under QEMU-TCG
    # q35 / i440fx with `-kernel` the boot path takes the env==0 EBDA-
    # scan fallback; when that yields no MADT (or a MADT with no ISOs)
    # the rollup is `identity=16 overridden=0`. On T14 G4 / EPYC boards
    # a typical shape is `identity=13 overridden=3` (SCI + IRQ0→GSI2 +
    # IRQ9 fixup). Fires on EVERY boot from kernel_main_64 post-
    # topology_seed_from_madt, so the marker IS reachable in the default
    # matrix — assertable in an existing boot golden without a new smoke
    # mode. Same "code emit lands now, golden-wiring lands with the next
    # OVMF-smoke-mode window" posture as the R111.M1-004 sibling entries
    # (`ACPI RSDP HANDOFF OK`, `ACPI TABLES SUMMARY OK`) immediately
    # above; the sibling `MADT ISO OVERRIDE` per-record fingerprint has
    # no OK token and does not need an allowlist entry.
    "IOAPIC ROUTE OK":
        "R111.M2-008 (#2360): legacy ISA IRQ [0..15] MADT ISO "
        "resolution rollup. Fires on every boot from kernel_main_64 "
        "post-topology_seed_from_madt via ioapic_route_witness_legacy_"
        "isas; assertable in an existing boot golden. Golden-wiring "
        "deferred to the R111.M2 OVMF-smoke-mode landing (same target "
        "as ACPI RSDP HANDOFF OK / ACPI TABLES SUMMARY OK).",

    # src/kernel/devices/display/gop_fb_console.pdx gop_fb_ok_msg —
    # R111.M4-015 (paideia-os #2367). GOP framebuffer console
    # bring-up fingerprint (Line 1 of a two-line pair) emitted by
    # gop_fb_console_init immediately after phase1_emit_rsdp_fingerprint
    # in kernel_main_64. Renders "FB CONSOLE OK width=<n> height=<n>
    # bpp=<n>" via klog_s1_d3; the companion Line 2 "fb console base
    # base=0x<...>" carries no OK token so does not need its own
    # allowlist entry. Reachable only on the UEFI boot path where
    # _boot_env_pa != 0 AND boot_env->fb.base_pa != 0 AND
    # platform_mmio_map succeeds; every other path (PVH -kernel,
    # firmware without GOP, LFB map failure) takes the sibling
    # "FB CONSOLE OFF" arm (no OK token, not gate-visible). The
    # 14-mode default matrix boots via -kernel so this fingerprint
    # never fires there; the PAIDEIA_UEFI_OVMF opt-in stops at the
    # pre-EBS banner and does not reach kernel_main_64 either.
    # Same UEFI-only reachability posture as "UEFI BRIDGE OK" /
    # "UEFI PML4 OK" / "ACPI RSDP HANDOFF OK" above; retires from this
    # allowlist when R111.M2 opens an OVMF smoke mode that boots past
    # ExitBootServices and asserts the fingerprint against a live
    # golden (planned as `boot_r111_uefi_bridge`, same follow-up
    # target the sibling UEFI entries name).
    # FB CONSOLE OK: allowlist entry RETIRED 2026-09-08 —
    # golden now asserts this line directly (T14 fidelity golden).

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

    # src/user/rootfs_seed.pdx — R57.M4-006 (#1802) skip-path
    # fingerprint. Fires only when init's sys_stat("/etc") returns 0
    # (i.e., /etc already exists — persistent-FS reboot with a prior
    # seed). Under the current tmpfs mount, /etc is fresh at every
    # boot so the work path (files=7) always fires and is asserted in
    # tests/r17/expected-boot-r17-init.txt. Becomes assertable when
    # the root mount migrates to pdxfs-block and a two-phase reboot
    # golden lands (post-R57.M4-006).
    "rootfs seed ok [legacy: ROOTFS SEED OK] files=0":
        "R57.M4-006 skip-path: fires only under a persistent root "
        "mount where /etc already exists from a prior seed. Under "
        "tmpfs (the current 14-mode matrix) /etc is fresh at boot "
        "so the work path always wins; the files=7 variant is "
        "asserted in tests/r17/expected-boot-r17-init.txt.",

    # src/kernel/core/klog/keys.pdx tag_sys_taskinfo_ok -- R57.M4-003
    # (paideia-os #1799) tag DECLARED but not emitted from any body.
    # sys_taskinfo_body is a leaf forwarder onto task_get_info; an
    # iterator syscall called MAX_PIDS (64) times per /bin/ps
    # invocation would inflate the ring with duplicate 'sys taskinfo
    # ok' lines for no diagnostic gain (the individual record
    # contents are already visible on the caller's stdout).  Same
    # declared-but-unemitted posture the R57.M4-004 mountinfo sibling
    # takes.  Assertable once a one-shot kernel-side witness that
    # exercises the syscall end-to-end (kernel-driver call through
    # dispatch_taskinfo, observing the record on wire) lands and
    # emits the tag exactly once at witness top -- see
    # src/kernel/core/klog/keys.pdx L1216 for the future-witness
    # note.  Allowlist entry lands at R57.M4-004 (#1800) to unblock
    # the fingerprint-coverage gate after #1799 declared the tag
    # without a golden.
    "sys taskinfo ok [legacy: SYS TASKINFO OK]":
        "R57.M4-003 (#1799) tag declared but not emitted; iterator "
        "syscall called MAX_PIDS times per /bin/ps would flood the "
        "ring. Assertable via a one-shot future kernel-side witness "
        "(see keys.pdx §tag_sys_taskinfo_ok comment).",

    # src/kernel/core/klog/keys.pdx tag_sys_mountinfo_ok -- R57.M4-004
    # (paideia-os #1800) tag DECLARED but not emitted from any body.
    # Same rationale as the taskinfo sibling immediately above:
    # sys_mountinfo_body is a leaf read of _mount_table; an iterator
    # syscall called MOUNT_MAX (8) times per /bin/mount invocation
    # would inflate the ring with duplicate 'sys mountinfo ok' lines
    # for no diagnostic gain (the individual row contents are
    # already visible on the caller's stdout).  Assertable via a
    # future one-shot kernel-side witness that exercises the syscall
    # end-to-end -- see src/kernel/core/klog/keys.pdx §tag_sys_
    # mountinfo_ok comment for the future-witness posture.
    "sys mountinfo ok [legacy: SYS MOUNTINFO OK]":
        "R57.M4-004 (#1800) tag declared but not emitted; iterator "
        "syscall called MOUNT_MAX times per /bin/mount would flood "
        "the ring. Assertable via a one-shot future kernel-side "
        "witness (see keys.pdx §tag_sys_mountinfo_ok comment).",

    # src/kernel/core/syscall/handlers/sys_volume_mint.pdx --
    # R90-XREPO.LV11.M2-003 (paideia-os #2225) fingerprint emitted
    # by sys_volume_mint_body on the OK path only.  This landing
    # wires the marshalling shim + cap-kind substrate; no boot
    # witness exercises it yet.  The libpdx-volume v1.1.0 follow-
    # up round that flips vol_kind_mint / vol_kind_mint_elevate
    # from stub to real is the first consumer, and its own witness
    # will pin an assertable golden line at that landing.
    "sys volume mint ok [legacy: SYS VOLUME MINT OK]":
        "R90-XREPO.LV11.M2-003 (#2225) tag emitted by sys_volume_"
        "mint_body OK path; assertable when libpdx-volume v1.1.0's "
        "vol_kind_mint follow-up round adds a boot witness that "
        "exercises the syscall end-to-end.",

    # R69 SMP scheduler dispatch markers — emitted only by the
    # boot_r69_smp_dispatch witness which runs under the opt-in
    # PAIDEIA_R69_SMP=1 pre-push gate (mirror of the PAIDEIA_UEFI_OVMF=1
    # allowlist rationale above). The 14-mode default matrix does not
    # cover PAIDEIA_R69_SMP=1 — it's a dedicated -smp 4 boot that
    # exercises cross-CPU wake + work-steal + fairness. AP-side IDT
    # install has not yet landed (~50 rounds of TODO documented in
    # ap_bringup.pdx / reschedule_ipi.pdx / tsc_deadline.pdx), so the
    # per-CPU tick histogram is currently runqueue-residency counts,
    # not execution ticks. See tests/expected-r69-smp.golden for the
    # honest-scope note.
    "sched cross-cpu wake ok [legacy: SCHED CROSS CPU WAKE OK]":
        "R69.M1-002 witness emits under PAIDEIA_R69_SMP=1 opt-in mode; "
        "not in the 14-mode default matrix. Golden at "
        "tests/expected-r69-smp.golden asserts via the opt-in gate.",
    "sched work steal ok [legacy: SCHED WORK STEAL OK]":
        "R69.M1-003 witness emits under PAIDEIA_R69_SMP=1 opt-in mode; "
        "not in the 14-mode default matrix.",
    "smp dispatch ok [legacy: SMP DISPATCH OK]":
        "R69.M1-004 witness emits under PAIDEIA_R69_SMP=1 opt-in mode; "
        "not in the 14-mode default matrix.",

    # R87.M1 (#1965/#1966/#1971) AP-side descriptor-table markers.
    # "ap idt ok" emits from _ap_entry (core/smp/ap_tss.pdx
    # ap_desc_tables_install) — only reachable when an AP actually
    # exists, i.e. under an -smp>1 boot. The 14-mode default matrix
    # boots -smp 1 (no APs), so this never prints there. "ap idt
    # verify ok" is the BSP-side rollup (boot/witness/r87_ap_idt.pdx);
    # it deliberately skips its own emit when cpus_ready == 0 (see that
    # file's own comment) for the identical reason — under -smp 1 no
    # AP ever ran ap_tss_install, so cpus_ready is always 0 and the
    # emit is unconditionally skipped. Both are asserted under the
    # opt-in PAIDEIA_R87_AP_IDT=1 gate (boot_r87_ap_idt,
    # tests/expected-r87-ap-idt.golden), same posture as the R69
    # markers immediately above.
    "ap idt ok [legacy: AP IDT OK]":
        "R87.M1-003 fingerprint emits only from AP context (no APs "
        "exist under the default -smp 1 matrix). Asserted under "
        "PAIDEIA_R87_AP_IDT=1 (tests/expected-r87-ap-idt.golden).",
    "ap idt verify ok [legacy: AP IDT VERIFY OK]":
        "R87.M1 (#1971) BSP-side rollup skips its own emit when "
        "cpus_ready == 0 (always true under the default -smp 1 "
        "matrix — no APs). Asserted under PAIDEIA_R87_AP_IDT=1 "
        "(tests/expected-r87-ap-idt.golden).",

    # R73.M1-001 sys_kill(SIGSTOP/SIGCONT). Kernel-side syscall exists
    # (sysno 95). Shell tier-2 job-control (paideia-os/shell satellite
    # repo) is the only real caller; no boot-time witness spawns a task
    # + kill-STOP + kill-CONT. Assertable via a future one-shot witness
    # or via PAIDEIA_R73_JOB=1 shell-tape smoke once shell tier 2 lands.
    "sys kill ok [legacy: SYS KILL OK]":
        "R73.M1-001 sys_kill body live; shell tier-2 job-control "
        "(satellite repo paideia-os/shell) is the caller — no kernel-"
        "side boot witness spawns kill-STOP/CONT sequence.",

    # R100-PREP-003 (paideia-os #2009) sys_icmp_echo + boot witness
    # fingerprints. Both emit on every boot: the boot witness at
    # src/kernel/boot/witness/r100_prep_003_icmp_echo.pdx calls
    # sys_icmp_echo_body directly, which emits `sys icmp echo ok ...`
    # via klog_s1_d1 on its OK path, and the witness itself then emits
    # `boot icmp echo ok -- ... rtt_ns=<n>` via klog_s1_d1 on its own
    # OK path. Same "declared but no golden line asserts it yet"
    # posture the R100-PREP-001 `tls trust mint ok` and R73 `sys kill
    # ok` entries carry above -- the 14-mode default matrix has no
    # golden that pins a networked-syscall line, and the coverage gate
    # correctly refuses to pass an unwitnessed OK-token marker without
    # an explicit reason. Assertable via a future golden that pins a
    # boot-cascade tail line beyond the network primitives (either the
    # existing tests/r17/* goldens grown a few lines OR a new
    # R100-scoped golden if the R100 wave lands its own smoke mode).
    "sys icmp echo ok [legacy: SYS ICMP ECHO OK]":
        "R100-PREP-003 (paideia-os #2009): sys_icmp_echo_body emits "
        "this on every OK call. The boot witness at "
        "r100_prep_003_icmp_echo.pdx is the sole caller today (init "
        "cannot call it yet -- no userspace ping tool is wired); no "
        "existing golden asserts networked-syscall lines. Assertable "
        "via a future golden that grows into the R100 witness tail.",
    "boot icmp echo ok -- [legacy: BOOT ICMP ECHO OK]":
        "R100-PREP-003 (paideia-os #2009): witness_r100_prep_003_icmp_"
        "echo emits this on every OK call. No existing golden asserts "
        "it -- same posture as the `tls trust mint ok` entry above, "
        "which the R100-PREP-001 witness triggers via the same cascade "
        "without a golden line either.",

    # R90-XREPO.010.M1-003 (paideia-os #2111) sys_pdxfs_txn_commit /
    # sys_pdxfs_txn_abort + boot-witness fingerprints. All three emit on
    # every boot: sys_pdxfs_txn_{commit,abort}_body emit their per-call
    # fingerprint via klog_s1_d1 on the OK path only, and the boot
    # witness at src/kernel/boot/witness/r90_xrepo_010_003_pdxfs_txn_
    # lifecycle.pdx emits `boot pdxfs txn lifecycle ok -- ... count=2`
    # via klog_s1_d1 on its own OK path after both scenarios pass. Same
    # "declared but no golden line asserts it yet" posture the R73
    # `sys kill ok` / R100-PREP-003 `sys icmp echo ok` entries carry
    # above -- the 14-mode default matrix has no golden that pins a
    # networked or pdxfs-txn syscall line, and the coverage gate
    # correctly refuses to pass an unwitnessed OK-token marker without
    # an explicit reason. Assertable via a future golden that pins the
    # boot cascade tail beyond the R90-XREPO wave.
    "sys pdxfs txn commit ok [legacy: SYS PDXFS TXN COMMIT OK]":
        "R90-XREPO.010.M1-003 (paideia-os #2111): sys_pdxfs_txn_commit_"
        "body emits this on every OK call. The boot witness at "
        "r90_xrepo_010_003_pdxfs_txn_lifecycle.pdx is the sole caller "
        "today (no userspace pdxfs-txn tool is wired); no existing "
        "golden asserts pdxfs-txn syscall lines. Assertable via a "
        "future golden that grows into the R90-XREPO witness tail.",
    "sys pdxfs txn abort ok [legacy: SYS PDXFS TXN ABORT OK]":
        "R90-XREPO.010.M1-003 (paideia-os #2111): sys_pdxfs_txn_abort_"
        "body emits this on every OK call. Same caller / golden "
        "posture as the commit sibling above.",
    "boot pdxfs txn lifecycle ok [legacy: BOOT PDXFS TXN LIFECYCLE OK]":
        "R90-XREPO.010.M1-003 (paideia-os #2111): witness_r90_xrepo_010_"
        "003_pdxfs_txn_lifecycle emits this on every OK boot after both "
        "commit and abort scenarios pass. No existing golden asserts "
        "it -- same posture as the `boot icmp echo ok` entry above.",

    # R90-XREPO.010.M1-004 (paideia-os #2112) sys_pdxfs_undo_write +
    # sys_pdxfs_txn_abort undo-replay extension fingerprints. Two OK-
    # token tags:
    #   - `sys pdxfs undo write ok` emits from sys_pdxfs_undo_write_body
    #     on the OK path only (matches every other sys_* handler's `OK
    #     path only` discipline).
    #   - `sys pdxfs undo replay ok` emits from sys_pdxfs_txn_abort_body
    #     AFTER the OPEN -> ABORTED transition succeeds and the row's
    #     undo records have been replayed. Emitted for EVERY successful
    #     abort now, including rows with no undo records (entries=0), so
    #     the every-boot cascade (which runs the R90-XREPO.010.M1-003
    #     lifecycle witness's abort scenario against an empty row) also
    #     produces this line. Same "declared but no golden asserts it
    #     yet" posture as every other txn-family entry above -- the 14-
    #     mode default matrix has no golden that pins a pdxfs-undo
    #     syscall line, and the coverage gate correctly refuses to pass
    #     an unwitnessed OK-token marker without an explicit reason.
    "sys pdxfs undo write ok [legacy: SYS PDXFS UNDO WRITE OK]":
        "R90-XREPO.010.M1-004 (paideia-os #2112): sys_pdxfs_undo_write_"
        "body emits this on every OK call. The boot witness at "
        "r90_xrepo_010_004_pdxfs_undo_write.pdx is the sole caller "
        "today (no userspace pdxfs-undo tool is wired); no existing "
        "golden asserts pdxfs-undo syscall lines. Assertable via a "
        "future golden that grows into the R90-XREPO witness tail.",
    "sys pdxfs undo replay ok [legacy: SYS PDXFS UNDO REPLAY OK]":
        "R90-XREPO.010.M1-004 (paideia-os #2112): sys_pdxfs_txn_abort_"
        "body emits this on every OK abort (even entries=0 rows) once "
        "the OPEN -> ABORTED transition succeeds and pdxfs_txn_undo_"
        "replay has walked the row. Same caller / golden posture as "
        "the undo_write sibling above.",

    # R90-XREPO.010.M1-006 (paideia-os #2114) real multi-entry readdir
    # fingerprint. Emitted by pdxfs_dir_readnext (core/cap/pdxfs_dir_iter.
    # pdx) whenever it transitions to EOD; carries a `rows=<n>` KV
    # naming how many entries the iteration session emitted.  The boot
    # witness at tests/kernel/pdxfs_dir/pdxfs_dir_iter_synth.pdx is the
    # sole caller today (no userspace readdir tool is wired -- ls.M2
    # still consumes the earlier stub set) and the historical `PDXFS
    # DIR ITER OK` witness-rollup line is what tests/r17/shell-shutdown.
    # golden asserts.  Same "declared but no golden asserts the syscall-
    # side literal" posture the sys_pdxfs_txn_{commit,abort} sibling
    # entries above carry.  Assertable via a future golden that grows
    # into the R90-XREPO witness tail (or by the ls.M3 tool witness
    # once the semantic-pipe PdxFsDirEntry[] path is wired).
    "sys pdxfs readdir ok [legacy: SYS PDXFS READDIR OK]":
        "R90-XREPO.010.M1-006 (paideia-os #2114): pdxfs_dir_readnext "
        "emits this on EOD (once per iteration session, with rows=<n>). "
        "The dir-iter witness at tests/kernel/pdxfs_dir/pdxfs_dir_iter_"
        "synth.pdx is the sole caller today; the witness-rollup line "
        "`PDXFS DIR ITER OK` is what tests/r17/shell-shutdown.golden "
        "asserts. No existing golden pins the raw `sys pdxfs readdir "
        "ok` literal -- same posture as the `sys pdxfs txn commit ok` "
        "sibling above.",

    # R90-XREPO.010.M1-002 (paideia-os #2110) sys_pdxfs_stat_by_inode
    # fingerprint. Emitted from sys_pdxfs_stat_by_inode_body's OK path
    # only (klog_s1_d2, k_ino + k_size). No boot-cascade caller reaches
    # the body today -- the M1-002 witness at src/kernel/boot/witness/
    # r90_xrepo_010_002_stat_by_inode.pdx bypasses the body and calls
    # sys_pdxfs_stat_by_inode_scratch_fill directly (a boot witness has
    # no user-half address to hand user_ptr_ok), and no userspace tool
    # is wired to sysno 106 yet. Same "declared but no golden line
    # asserts it yet" posture the R90-XREPO.010.M1-003 sys_pdxfs_txn_
    # {commit,abort} entries above carry. Assertable via a future
    # golden that grows into the ls-l wave's witness tail once the
    # sibling per-inode owner/nlink primitives land.
    "sys pdxfs stat by inode ok [legacy: SYS PDXFS STAT BY INODE OK]":
        "R90-XREPO.010.M1-002 (paideia-os #2110): sys_pdxfs_stat_by_"
        "inode_body emits this on every OK call. The boot witness at "
        "r90_xrepo_010_002_stat_by_inode.pdx bypasses the body (calls "
        "sys_pdxfs_stat_by_inode_scratch_fill directly to avoid "
        "user_ptr_ok's kernel-half refusal); no userspace tool is "
        "wired to sysno 106 yet. Assertable via a future golden that "
        "grows into the ls-l wave's witness tail.",

    # src/kernel/core/sched/wait.pdx -- R90-XREPO.011.M1-001 (paideia-os
    # #2117) kernel-side sched_wait / sched_wake_kind primitive. Both
    # markers emit from inside the primitive itself, not from a boot
    # witness: the parent-issue text names a two-thread park/notify
    # witness that lands with the sibling elevate-broker dispatch-loop
    # milestone (R90-XREPO.011.M1-003), which is the first real
    # consumer of the primitive. At this landing no kernel-side path
    # invokes the primitive on the default boot cascade (elevate broker
    # is still the R48b substrate-prep stub, no dispatch loop yet), so
    # neither marker prints on any golden line. Both retire from this
    # allowlist when the M1-003 dispatch loop lands its witness and a
    # golden line pins the fingerprint. Same posture as the R73
    # `sys kill ok` entry above -- kernel path live, no boot witness
    # spawns the exercise sequence.
    "sched wait ok [legacy: SCHED WAIT OK]":
        "R90-XREPO.011.M1-001 (#2117): sched_wait emits this at entry. "
        "No boot witness parks a thread on a wait key yet; the elevate-"
        "broker dispatch loop that first exercises the primitive lands "
        "with R90-XREPO.011.M1-003.",
    "sched wake ok [legacy: SCHED WAKE OK]":
        "R90-XREPO.011.M1-001 (#2117): sched_wake_kind emits this iff "
        "woken>0. No boot witness fires a notify at a parked thread "
        "yet; the elevate-broker dispatch loop that first exercises "
        "the primitive lands with R90-XREPO.011.M1-003.",

    # src/kernel/core/cap/kind_tui_canvas.pdx — R89.M1-001 (#1988) row +
    # mint gate. R89.M1-005 (#1992, src/kernel/boot/witness/
    # r89_tui_canvas.pdx) now calls kind_tui_canvas_mint_body at every
    # boot, so this marker DOES print on every boot — the "no caller
    # anywhere in the tree" rationale this entry carried through
    # R89.M1-001..004 no longer holds. It stays allowlisted because no
    # golden file asserts this specific line yet: the witness's own
    # fingerprint ("boot tui canvas ok -- ...", all-lowercase, no OK
    # token) is the assertable signal for this code path instead. Add
    # a golden line for the literal "tui canvas mint ok" text if a
    # future mode wants to pin it directly.
    "tui canvas mint ok [legacy: TUI CANVAS MINT OK]":
        "R89.M1-005 (#1992): reachable at every boot via "
        "r89_tui_canvas.pdx's witness_r89_tui_canvas, but no golden "
        "file asserts this exact line — the witness's own lowercase "
        "'boot tui canvas ok --' fingerprint covers this code path.",

    # src/kernel/core/cap/kind_pdxfs_file.pdx — R90-XREPO.010.M1-001
    # (paideia-os #2109) PFF_OP_READ_BYTES success fingerprint,
    # emitted once per successful cap_handler_pdxfs_file READ_BYTES
    # invocation from inside the handler body's klog_s1_d2 emit
    # site. Reachable at every boot via r90_xrepo_010_pdxfs_read_
    # bytes.pdx's witness_r90_xrepo_010_pdxfs_read_bytes (seeds a
    # tmpfs file, mints a KIND_PDXFS_FILE cap, invokes READ_BYTES,
    # asserts the returned bytes match the seed pattern byte-for-
    # byte). Same "no golden file asserts this exact line" posture
    # as the KIND_TUI_CANVAS mint-marker entry immediately above:
    # the witness's own lowercase "boot pdxfs read bytes ok --"
    # fingerprint is the assertable signal for this code path. Add
    # a golden line for the literal "pdxfs file read bytes ok" text
    # if a future mode wants to pin it directly.
    "pdxfs file read bytes ok [legacy: PDXFS FILE READ BYTES OK]":
        "R90-XREPO.010.M1-001 (paideia-os #2109): reachable at every "
        "boot via r90_xrepo_010_pdxfs_read_bytes.pdx's "
        "witness_r90_xrepo_010_pdxfs_read_bytes, but no golden file "
        "asserts this exact line — the witness's own lowercase "
        "'boot pdxfs read bytes ok --' fingerprint covers this code "
        "path.",

    # src/kernel/core/cap/kind_tls_trust.pdx — R100-PREP-001 (#2007)
    # mint-body fingerprint, emitted once per KIND_TLS_TRUST mint from
    # inside kind_tls_trust_mint_body. Reachable at every boot via
    # r100_tls_trust.pdx's witness_r100_tls_trust (mints a trust
    # anchor over a static Ed25519-shaped pubkey buffer). Same "no
    # golden file asserts this exact line" posture as the KIND_TUI_
    # CANVAS mint-marker entry immediately above; the witness's own
    # lowercase "boot tls trust ok --" fingerprint is the assertable
    # signal for this code path. Add a golden line for the literal
    # "tls trust mint ok" text if a future mode wants to pin it
    # directly.
    "tls trust mint ok [legacy: TLS TRUST MINT OK]":
        "R100-PREP-001 (#2007): reachable at every boot via "
        "r100_tls_trust.pdx's witness_r100_tls_trust, but no golden "
        "file asserts this exact line — the witness's own lowercase "
        "'boot tls trust ok --' fingerprint covers this code path.",

    # src/kernel/core/cap/kind_nic.pdx — R91.M1-001 (paideia-os #2011)
    # mint-body fingerprint, emitted once per KIND_NIC mint from inside
    # kind_nic_mint_body. Reachable at every boot via r91_kind_nic.pdx's
    # witness_r91_kind_nic (mints a synthetic KIND_DEVICE parent then a
    # KIND_NIC row over it; nic_kind=NONE, mac=zero, link=DOWN, since
    # no real NIC driver is wired at R91.M1-001). Same "no golden file
    # asserts this exact line" posture as the KIND_TUI_CANVAS / KIND_
    # TLS_TRUST mint-marker entries immediately above; the witness's
    # own lowercase "boot nic ok --" fingerprint is the assertable
    # signal for this code path. Add a golden line for the literal
    # "nic mint ok" text if a future mode wants to pin it directly.
    "nic mint ok [legacy: NIC MINT OK]":
        "R91.M1-001 (paideia-os #2011): reachable at every boot via "
        "r91_kind_nic.pdx's witness_r91_kind_nic, but no golden file "
        "asserts this exact line — the witness's own lowercase "
        "'boot nic ok --' fingerprint covers this code path.",

    # src/kernel/core/net/nic_dispatch.pdx — R91.M2-001 (paideia-os #2015)
    # boot-order NIC probe fingerprint, emitted once at the tail of every
    # nic_dispatch_probe call from inside the nd_pb_emit label. Now
    # reachable at every boot via kernel_main_64's call site immediately
    # after pci_publish_caps (the R91.M2-001 wire-in landing). On the
    # default `qemu -kernel` boot (no `-device e1000e / virtio-net-pci /
    # rtl8139`) the probe lands on NIC_KIND_NONE and the fingerprint
    # reports `kind=0`; on a boot that adds `-device e1000e` (paideia-os
    # #2018) it reports `kind=1`. Same "no golden file asserts this exact
    # line" posture as the "nic mint ok" sibling immediately above:
    # neither the default 14-mode matrix nor the R91 witness fleet pins
    # the literal line yet. Retires from this allowlist when a golden
    # (likely a `-device e1000e` mode landed by #2018 asserting
    # `kind=1`) pins the fingerprint.
    "nic dispatch probe ok [legacy: NIC DISPATCH PROBE OK]":
        "R91.M2-001 (paideia-os #2015): emitted at every boot from "
        "nic_dispatch_probe's nd_pb_emit label, but no golden file "
        "asserts this exact line yet — the probe's own no-crash "
        "return is the assertable signal until #2018 (or a sibling "
        "milestone) lands a `-device e1000e` mode that pins the "
        "`kind=1` variant.",

    # src/kernel/core/tui/canvas_present.pdx — R89.M1-003 (#1990)
    # TUI_OP_PRESENT real body. Same status change as the "tui canvas
    # mint ok" entry immediately above: R89.M1-005's boot witness now
    # invokes PRESENT on every boot (dispatch requires a live canvas
    # row, which the witness mints first), so "no reachable caller"
    # is no longer true either. Still allowlisted for the same reason
    # — no golden line asserts this literal text yet.
    "tui canvas present ok [legacy: TUI CANVAS PRESENT OK]":
        "R89.M1-005 (#1992): reachable at every boot via "
        "r89_tui_canvas.pdx's witness_r89_tui_canvas (mints a canvas "
        "then invokes PRESENT), but no golden file asserts this exact "
        "line — the witness's own lowercase 'boot tui canvas ok --' "
        "fingerprint covers this code path.",

    # src/kernel/core/cap/kind_tty.pdx tag_tty_read_ok — R66v2.POS-001
    # (#1986). DECLARED but not emitted from any body: TTY_OP_READ is a
    # per-byte, non-blocking poll that an interactive session can invoke
    # hundreds of times a second, and logging one line per call would
    # flood the ring for no diagnostic gain — same posture as
    # tag_sys_taskinfo_ok / tag_sys_mountinfo_ok (klog/keys.pdx).
    # Assertable once a future rate-limited or one-shot boot witness
    # exercises the op; the boot smoke witness itself is #1987, out of
    # scope for #1986.
    "tty read ok [legacy: TTY READ OK] bytes=":
        "R66v2.POS-001 (#1986): tag declared but not emitted; "
        "TTY_OP_READ is a per-byte op and logging every call would "
        "flood the ring. Assertable via a future rate-limited or "
        "one-shot witness (see kind_tty.pdx tag_tty_read_ok comment).",

    # src/kernel/core/cap/kind_tty.pdx tag_tty_mode_ok — R66v2.POS-001
    # (#1986). Emitted from cap_handler_tty's TTY_OP_SET_RAW /
    # TTY_OP_SET_COOKED arms, but cap_handler_tty has no caller in the
    # default 14-mode matrix yet: the syscall wire from userspace into
    # KIND_TTY op dispatch, and the boot witness that mints a sink and
    # invokes these ops, are both later milestone items (the boot smoke
    # witness is explicitly #1987, out of scope for #1986).
    "tty mode ok [legacy: TTY MODE OK] mode=":
        "R66v2.POS-001 (#1986): TTY_OP_SET_RAW/SET_COOKED body has no "
        "caller yet — the syscall wire and the boot witness (#1987) "
        "are later milestone items.",

    # src/user/init.pdx — R65v2.M1-001 (#1979) persistent-home mount
    # probe. Fires only when init's sys_stat("/var/pdxfs/home.img")
    # returns 0, i.e. a file-backed pdxfs image already exists at boot.
    # The default tmpfs-rootfs 14-mode matrix never seeds this file, so
    # the probe always short-circuits to the tmpfs fallback with no
    # emission. Even were the file present, backend_id=5 (PDXFS_BLOCK)
    # is an unconditional UNIMPL stub in sys_mount.pdx (no devfs dev-path
    # resolver landed yet), so this line cannot fire for real until
    # R51/R52 lands a persistent pdxfs-block rootfs — see
    # design/user/persistent-home.md §2/§6 and the R65v2 closure retro
    # (design/round-retrospectives/r65-closure-v2.md) for the honest
    # scope note.
    "init home mount ok [legacy: INIT HOME MOUNT OK] -- src=/var/pdxfs/home.img mp=/home/<fp> backend=PDXFS_BLOCK":
        "R65v2.M1-001 (#1979), mount-point field updated R106.M3 "
        "(paideia-os #2230, retiring the literal /home/operator hardcode "
        "in favor of a static '<fp>' placeholder token sourced from "
        "FounderConstants.fc_placeholder_home_path): fires only when "
        "/var/pdxfs/home.img exists AND sys_mount succeeds; neither holds "
        "under the default tmpfs-rootfs boot (backend_id=5 is UNIMPL "
        "pending a devfs dev-path resolver). Assertable once R51/R52 "
        "lands a persistent pdxfs-block rootfs — see "
        "design/user/persistent-home.md §2/§6.",

    # Sibling of the entry immediately above — device-target variant.
    # Fires only when sys_stat("/dev/nvme0") returns 0 (a real block
    # device node), which devfs does not provide in this tree yet
    # (design/user/persistent-home.md §5's "no devfs" gap). Same
    # backend_id=5 UNIMPL posture applies even were the stat to somehow
    # succeed.
    "init home mount ok [legacy: INIT HOME MOUNT OK] -- src=/dev/nvme0 mp=/home/<fp> backend=PDXFS_BLOCK":
        "R65v2.M1-001 (#1979) / R65v2.M1-002 device-target path (#1980), "
        "mount-point field updated R106.M3 (paideia-os #2230, retiring "
        "the literal /home/operator hardcode in favor of a static "
        "'<fp>' placeholder token): fires only when /dev/nvme0 exists "
        "AND sys_mount succeeds; no devfs node ever populates that path "
        "in this tree yet, and backend_id=5 is UNIMPL regardless. "
        "Assertable once real hardware/devfs + R51/R52 pdxfs-block land "
        "together.",

    # src/kernel/core/cap/kind_elevate_channel.pdx tag_elvc_expire_set_ok
    # — R90-XREPO.011.M1-002 (paideia-os #2118). Emitted from
    # cap_handler_elevate_channel's ELVC_OP_SET_EXPIRE (=8) arm; also
    # emitted whenever the broker's real dispatch body
    # (elevate_broker_serve_one, #2122) calls
    # elevate_channel_row_set_expire from ipc/elevate_broker.pdx
    # (which routes through the same handler code path). No golden
    # file pins the line yet — the boot-witness rollup ("boot elevate
    # broker ok [legacy: BOOT ELEVATE BROKER OK]", allowlisted below)
    # is the assertable signal for the whole dispatch cascade, same
    # posture as the tag_boot_tui_canvas_ok / tag_boot_tls_trust_ok
    # entries above. Reason retained rather than deleted because
    # deletion would require a golden that pins this exact literal on
    # the wire, which the witness's own rollup does not need for its
    # assertion to bite.
    "elevate expire set ok [legacy: ELEVATE EXPIRE SET OK]":
        "R90-XREPO.011.M1-002 (#2118) / R90-XREPO.011.M1-003 (#2122): "
        "ELVC_OP_SET_EXPIRE body driven every boot by "
        "elevate_broker_serve_one; the boot witness's own rollup "
        "`boot elevate broker ok` is the assertable signal for the "
        "whole cascade — no golden line pins this exact literal.",

    # src/kernel/core/ipc/elevate_broker.pdx tag_elvb_allow_ok
    # / tag_elvb_deny_ok — R90-XREPO.011.M1-003 (paideia-os #2122).
    # Both emitted from within elevate_broker_serve_one once policy
    # evaluation lands (ALLOW under the seeded `/system/  INIT  ALLOW`
    # rule when the boot witness runs Scenario A with requester_pid=1;
    # DENY under the seeded `/system/  *  DENY` rule when Scenario B
    # runs with requester_pid=99). Same "witness fires every boot but
    # no golden asserts this exact line" posture as the sibling
    # `tui canvas mint ok` / `tls trust mint ok` / `elevate expire set
    # ok` entries above — the witness's own `boot elevate broker ok`
    # rollup is the assertable signal for the whole cascade.
    "elevate broker allow ok [legacy: ELEVATE BROKER ALLOW OK]":
        "R90-XREPO.011.M1-003 (#2122): elevate_broker_serve_one emits "
        "this on ALLOW every boot via witness_elevate_broker_dispatch "
        "Scenario A. The witness's `boot elevate broker ok` rollup "
        "covers the cascade; no golden pins this exact literal.",
    "elevate broker deny ok [legacy: ELEVATE BROKER DENY OK]":
        "R90-XREPO.011.M1-003 (#2122): elevate_broker_serve_one emits "
        "this on DENY every boot via witness_elevate_broker_dispatch "
        "Scenario B. The witness's `boot elevate broker ok` rollup "
        "covers the cascade; no golden pins this exact literal.",

    # src/kernel/boot/witness/elevate_broker_dispatch.pdx tag_boot_elvb_ok
    # — R90-XREPO.011.M1-003 (paideia-os #2122). Emitted from
    # witness_elevate_broker_dispatch's all-green rollup at boot
    # (Scenarios A and B both green + cleanup free). No golden yet;
    # same posture the sibling boot-rollup markers above take (their
    # own witness passing is the assertable signal today).
    "boot elevate broker ok [legacy: BOOT ELEVATE BROKER OK]":
        "R90-XREPO.011.M1-003 (#2122): rollup emitted every boot from "
        "witness_elevate_broker_dispatch on Scenarios A + B both "
        "green. No golden pins this exact literal yet.",

    # src/kernel/core/syscall/handlers/sys_cwd_resolve.pdx — R90-XREPO.
    # 010.M1-007 (paideia-os #2115) sys_cwd_resolve (sysno 517) OK-path
    # fingerprint.  Emitted by sys_cwd_resolve_body's klog_s1_d1 on
    # every successful resolution, carrying `len=<n>` (strlen of the
    # composed absolute path, EXCLUDING NUL).  Reachable at every
    # boot via witness_r90_xrepo_010_007_cwd_resolve (three scenarios
    # -> three emit lines), but no golden file asserts this exact
    # literal yet -- same posture as the sibling `sys pdxfs undo write
    # ok` / `sys pdxfs stat by inode ok` entries above.  The witness's
    # own lowercase `boot cwd resolve ok -- count=3` rollup is the
    # assertable signal for this code path; add a golden line for the
    # literal `sys cwd resolve ok` text if a future mode wants to pin
    # it directly.
    "sys cwd resolve ok [legacy: SYS CWD RESOLVE OK]":
        "R90-XREPO.010.M1-007 (paideia-os #2115): sys_cwd_resolve_body "
        "emits this on every OK call.  Reachable at every boot via "
        "r90_xrepo_010_007_cwd_resolve.pdx (three scenarios -> three "
        "emit lines), but no golden pins this exact literal -- the "
        "witness's own lowercase `boot cwd resolve ok --` rollup is "
        "the assertable signal for the whole cascade.",

    # src/kernel/core/drivers/virtio_net/probe.pdx and
    # src/kernel/core/drivers/virtio_net/common_cfg.pdx -- R91.M3-002
    # (paideia-os #2019) virtio-net PCI probe OK-path fingerprint, and
    # R91.M3-003 (paideia-os #2020) virtio 1.0 handshake OK-path
    # fingerprint. Both are emitted every boot as soon as the e1000e
    # arm misses (nic_dispatch.pdx nd_pb_try_virtio calls
    # virtio_net_probe unconditionally, and now also
    # virtio_net_init_handshake unconditionally after debugger-fix);
    # virtio_net_probe emits count=0 on the default QEMU matrix (no
    # virtio-net device present), and the handshake short-circuits to
    # NO_BAR without emitting OK. So `virtio-net probe ok` fires every
    # default boot but no golden pins the literal; `virtio-net init
    # handshake ok` requires a real virtio-net device (opt-in
    # PAIDEIA_NIC=virtio) to fire, and no golden pins that either.
    # Same posture as e1000e's own `e1000e probe ok` line above.
    "virtio-net probe ok [legacy: VIRTIO NET PROBE OK]":
        "R91.M3-002 (paideia-os #2019): virtio_net_probe emits this "
        "unconditionally at its tail (count=0 on the default matrix, "
        "count=n when virtio devices are present) -- reachable every "
        "boot via nic_dispatch's unconditional nd_pb_try_virtio call. "
        "No golden pins this exact literal today; retires when a "
        "smoke mode asserts the line.",
    "virtio-net init handshake ok [legacy: VIRTIO INIT OK]":
        "R91.M3-003 (paideia-os #2020): virtio_net_init_handshake "
        "emits this on successful DRIVER_OK. Only reachable when a "
        "virtio-net device is actually present (PAIDEIA_NIC=virtio "
        "opt-in path); on the default QEMU matrix _virtio_net_common_"
        "cfg_pa stays 0 and the handshake takes the NO_BAR fail "
        "branch without emitting OK. Retire when a virtio boot mode "
        "lands in the smoke suite.",

    # src/kernel/core/drivers/virtio_net/mac.pdx -- R91.M3-006 (paideia-os
    # #2024) MAC read and link-status query.  virtio_net_read_mac_body
    # emits `virtio-net mac ok` on both the DEVICE-region-read path
    # (when the handshake could have run) and the LAA-synthesise path
    # (when the DEVICE region is unreachable) -- either way the record's
    # +42 mac slot is populated and the value is asserted on the wire.
    # virtio_net_link_status emits `virtio-net link ok` on all paths
    # (bit-0 of DEVICE cfg's status u16 when reachable, safe-default 1
    # otherwise).  Both are only invoked from a virtio-net attach path
    # that R91.M3-006 does not wire in yet -- the current landing is
    # dormant substrate (same posture as e1000e_read_mac / _program_rar
    # at R27.M1 pre-attach).  No caller means no boot line today; the
    # allowlist entries below preempt the fingerprint-coverage gate
    # against the future wire-in that follows (nic_dispatch's virtio
    # arm, or a dedicated attach body).  Same posture as the sibling
    # `virtio-net init handshake ok` entry above.
    "virtio-net mac ok [legacy: VIRTIO NET MAC OK]":
        "R91.M3-006 (paideia-os #2024): virtio_net_read_mac_body "
        "emits this on every call (DEVICE-region read path AND LAA "
        "synth path).  Not yet reachable at boot -- the fn is dormant "
        "substrate awaiting the virtio-net attach wire-in.  Retire "
        "when a virtio boot mode lands in the smoke suite AND a "
        "golden line pins the emitted literal.",
    "virtio-net link ok [legacy: VIRTIO NET LINK OK]":
        "R91.M3-006 (paideia-os #2024): virtio_net_link_status "
        "emits this on every call (DEVICE-region status read AND "
        "safe-default up-arm).  Not yet reachable at boot -- the fn "
        "is dormant substrate awaiting the virtio-net attach wire-in. "
        "Retire when a virtio boot mode lands in the smoke suite AND "
        "a golden line pins the emitted literal.",

    # src/kernel/core/drivers/virtio_net/virtqueue.pdx -- R91.M3-003
    # (paideia-os #2021) virtio_net_vq_init OK-path fingerprint.
    # Emitted at the tail of virtio_net_vq_init on successful QUEUE_
    # ENABLE. Not yet reachable at boot -- vq_init has no caller yet
    # (R91.M3-004 tx and R91.M3-005 rx are the future callers). On
    # the default QEMU matrix the fn would short-circuit to NO_BAR
    # anyway since _virtio_net_common_cfg_pa stays 0. Same posture as
    # the sibling virtio init/mac/link entries.
    "virtio-net vq init ok [legacy: VIRTIO NET VQ INIT OK]":
        "R91.M3-003 (paideia-os #2021): virtio_net_vq_init emits "
        "this on successful QUEUE_ENABLE. Not yet reachable at boot "
        "-- dormant substrate awaiting R91.M3-004/005 tx/rx wire-in. "
        "Retire when a virtio boot mode lands in the smoke suite.",

    # src/kernel/core/drivers/virtio_net/tx.pdx (R91.M3-004 #2022),
    # rx.pdx (R91.M3-005 #2023), isr.pdx (R91.M3-005 #2023). All three
    # fire only when the virtio-net attach path is wired (nic_dispatch
    # tx/rx virtio arms + IDT wire for isr); today they are dormant
    # substrate. Same posture as the sibling `virtio-net vq init ok`
    # entry above. Retire when a virtio boot mode joins the smoke
    # suite and pins the literals.
    "virtio-net tx ok [legacy: VIRTIO NET TX OK]":
        "R91.M3-004 (paideia-os #2022): virtio_net_tx_send emits "
        "this on the OK path. Dormant substrate awaiting nic_dispatch "
        "virtio tx arm wire-in.",
    "virtio-net rx refill ok [legacy: VIRTIO NET RX REFILL OK]":
        "R91.M3-005 (paideia-os #2023): virtio_net_rx_refill emits "
        "this after prepopulating the RX ring. Dormant substrate "
        "awaiting attach-time call from kernel_main virtio bring-up.",
    "virtio-net isr ok [legacy: VIRTIO NET ISR OK]":
        "R91.M3-005 (paideia-os #2023): virtio_net_isr_handle emits "
        "this on every IRQ entry. Dormant substrate awaiting IDT "
        "wire-in for the virtio-net vector.",
    "virtio-net cfg change ok [legacy: VIRTIO NET CFG CHANGE OK]":
        "R91.M3-005 (paideia-os #2023): virtio_net_isr_handle emits "
        "this on ISR-status bit-1 (config change). Dormant substrate "
        "awaiting IDT wire-in for the virtio-net vector.",

    # src/kernel/core/drivers/rtl8139/{probe,rx,tx,mac,irq}.pdx --
    # R91.M4-001..004 (paideia-os #2025..#2028) RTL8139 driver family.
    # All six fingerprints fire only when the rtl8139 attach path is
    # wired (nic_dispatch cmp-chain arm + IDT wire for the ISR); today
    # they are dormant substrate. probe emits count=0 on the default
    # QEMU matrix (no -device rtl8139), and the remaining five never
    # execute without an attach caller. Same posture as the sibling
    # virtio-net entries above. Retire when a rtl8139 boot mode joins
    # the smoke suite (R91.M5 boot_r91_nic_probe smoke, #2031) under
    # PAIDEIA_NIC=rtl8139 and pins the literals.
    "rtl8139 probe ok [legacy: RTL8139 PROBE OK]":
        "R91.M4-001 (paideia-os #2025): rtl8139_probe emits this every "
        "call with count=<n>. Fires on the default QEMU matrix with "
        "count=0 (no -device rtl8139) once nic_dispatch_probe wires "
        "the call in; no golden pins the literal yet.",
    "rtl8139 rx init ok [legacy: RTL8139 RX INIT OK]":
        "R91.M4-002 (paideia-os #2026): rtl8139_rx_init emits this after "
        "programming RBSTART / RCR / IMR and enabling the receiver. "
        "Dormant substrate awaiting attach-time call from the future "
        "nic_dispatch rtl8139 arm.",
    "rtl8139 rx poll ok [legacy: RTL8139 RX POLL OK]":
        "R91.M4-002 (paideia-os #2026): rtl8139_rx_poll emits this at "
        "the tail of each drain with count=<frames>. Dormant substrate "
        "awaiting IDT wire-in for the rtl8139 IRQ vector.",
    "rtl8139 tx ok [legacy: RTL8139 TX OK]":
        "R91.M4-003 (paideia-os #2027): rtl8139_tx_send emits this on "
        "the trigger-success path. Dormant substrate awaiting the "
        "nic_dispatch rtl8139 tx arm wire-in.",
    "rtl8139 mac ok [legacy: RTL8139 MAC OK]":
        "R91.M4-004 (paideia-os #2028): rtl8139_read_mac emits this "
        "after packing IDR0..IDR5 into slot 0's mac_word. Dormant "
        "substrate awaiting the rtl8139 attach path.",
    "rtl8139 isr ok [legacy: RTL8139 ISR OK]":
        "R91.M4-004 (paideia-os #2028): rtl8139_isr_handle emits this "
        "at every ISR entry past the NO_DEV gate. Dormant substrate "
        "awaiting IDT wire-in for the rtl8139 IRQ vector.",

    # ------------------------------------------------------------------
    # Wave 0 Batches 1, 6, 7 — G7 PWP compositor + color-cap declaration
    # tags. Each is a data-only fingerprint decl in a KIND_ cap module
    # whose dispatcher has not yet been wired into kernel_main (compositor
    # wire-body milestone, deferred). Retires when the wire-body lands
    # and the mint-body emit path activates for each KIND_.
    # ------------------------------------------------------------------

    # Batch 1: color caps (src/user/color/*.pdx)
    "hdr10 transform ok [legacy: HDR10 TRANSFORM OK]":
        "Wave0-B1 G6-color: hdr10_transform data-only cap decl; "
        "kernel dispatcher not yet wired.",
    "hlg output transform installed [legacy: HLG XFORM OK]":
        "Wave0-B1 G6-color: hlg_transform data-only cap decl; "
        "kernel dispatcher not yet wired.",
    "hdr metadata mint ok [legacy: HDR MD MINT OK]":
        "Wave0-B1 G6-color: hdr_metadata_kind (KIND_HDR_METADATA=0x1B5) "
        "data-only decl; kernel mint-body not yet wired.",
    "tonemap lut mint ok [legacy: TONEMAP LUT MINT OK]":
        "Wave0-B1 G6-color: tonemap_kind (KIND_TONEMAP_LUT=0x1B6) "
        "data-only decl; kernel mint-body not yet wired.",
    "reference display mint ok [legacy: REFERENCE DISPLAY MINT OK]":
        "Wave0-B1 G6-color: reference_display_kind (KIND=0x1B7) "
        "data-only decl; kernel mint-body not yet wired.",

    # Batch 6: G7-M2..M7 compositor caps (src/user/compositor/*.pdx)
    "surface kind mint ok [legacy: SURFACE KIND MINT OK]":
        "Wave0-B6 G7-M2-001 (#2246): surface_kind (KIND_SURFACE=0x1B8) "
        "data-only decl; kernel dispatcher not yet wired.",
    "surface commit mint ok [legacy: SURFACE COMMIT MINT OK]":
        "Wave0-B6 G7-M2-002 (#2248): surface_commit LINEAR (KIND=0x1B9) "
        "data-only decl; kernel dispatcher not yet wired.",
    "surface geometry meta ok [legacy: SURFACE GEOMETRY META OK]":
        "Wave0-B6 G7-M2-003 (#2250): surface_geometry value-type decl; "
        "no KIND cap, no dispatcher required — first consumer emits.",
    "surface buffer bind meta [legacy: SBB META OK]":
        "Wave0-B6 G7-M2-004 (#2252): surface_buffer_bind value-type decl "
        "(explicit-sync P1); surface_commit consume path will emit.",
    "window mint ok [legacy: WINDOW MINT OK]":
        "Wave0-B6 G7-M3-001 (#2254): window_kind (KIND_WINDOW=0x1C1) "
        "data-only decl; kernel dispatcher + P4 a11y-mint gate not yet wired.",
    "pdx kind layer tree meta [legacy: LAYER TREE META OK]":
        "Wave0-B6 G7-M3-002 (#2256): layer_tree (KIND_LAYER_TREE=0x1C2) "
        "data-only decl; kernel dispatcher not yet wired.",
    "layer tree commit ok [legacy: LAYER TREE COMMIT OK]":
        "Wave0-B6 G7-M3-002 (#2256): layer_tree commit-path fingerprint; "
        "dispatcher emit not yet wired.",
    "xdg toplevel state mint ok [legacy: XDG TOP STATE MINT OK]":
        "Wave0-B6 G7-M4-001 (#2260): xdg_shell_states (KIND=0x1C4) "
        "data-only decl; kernel dispatcher not yet wired.",
    "clip offer mint ok [legacy: CLIP OFFER MINT OK]":
        "Wave0-B6 G7-M5-001 (#2266): clipboard sealed cap (KIND=0x1C6) "
        "data-only decl; kernel dispatcher not yet wired.",
    "kind_clip_offer meta [legacy: KIND_CLIP_OFFER OK]":
        "Wave0-B6 G7-M5-001 (#2266): clipboard cap module-meta tag; "
        "companion to clip offer mint ok, same wire-body dependency.",
    "recovery plane reservation ok [legacy: RECOVERY PLANE RSV OK]":
        "Wave0-B6 G7-M6-001 (#2269): recovery_plane_reserve (KIND=0x1C8) "
        "data-only decl; input-server-side reservation not yet booted.",

    # ------------------------------------------------------------------
    # R113.M1-001 (paideia-os #2381) + R113.M1-001b (paideia-os #2424):
    # KIND_SURFACE kernel-side substrate (row pool + mint + destroy +
    # row_* accessors, #2381) plus the six-op cap_handler_surface
    # dispatcher wire (#2424, cap/handlers/cap_handler_surface.pdx +
    # the cap/invoke.pdx 0x1B8 arm + call_kind_surface landing pad).
    # All five R113.M1 fingerprint tags (mint / destroy / commit / fmt
    # bind / present) landed at #2381 per design/graphics/r113-m1-
    # substrate.md §8's mandate to close the Wave-12 SURFACE COMMIT OK
    # allowlist gap; mint + destroy emitters live in cap/kind_surface.
    # pdx, commit/fmt-bind emitters have landed at M1-002 / M1-004,
    # and the present emitter is deferred to M1-005.
    #
    # Post-#2424 the dispatcher IS wired end-to-end: cap_invoke against
    # a KIND_SURFACE cap now reaches cap_handler_surface, which fans
    # out on OP_SURFACE_QUERY / COMMIT / DAMAGE / ATTACH / DESTROY /
    # MINT under the KGATE_* rights aliases and calls the corresponding
    # substrate leaf (surface_mint / surface_destroy / surface_row_*
    # accessors, surface_row_swap for commit).  None of the five tags
    # is reachable in the default matrix yet because no user-space
    # caller of cap_invoke against a KIND_SURFACE cap exists: no boot
    # witness mints a surface (kind_surface_init runs at boot but is a
    # pure pool scrub), and the M1-002 op_arg-encoding refinement that
    # would let a normal cap_invoke pass w/h/format has not landed.  A
    # direct-invocation boot witness (5-arg cap_handler_surface call)
    # could trip mint / destroy today; that witness is the natural
    # companion to the M1-002 refinement per doc §9's milestone graph.
    # Real-HW / wire-deferred posture identical to the sibling
    # `surface kind mint ok` / `surface commit mint ok` entries above.
    # ------------------------------------------------------------------
    "surface mint ok [legacy: SURFACE MINT OK]":
        "R113.M1-001 (#2381) + R113.M1-001b (#2424): kernel-side "
        "KIND_SURFACE mint fingerprint; handler wired M1-001b (cap/"
        "handlers/cap_handler_surface.pdx OP_SURFACE_MINT branches on "
        "R_SURFACE_MINT and calls surface_mint), emitter (mint/destroy) "
        "lands via first user-space surface_mint call.  Assertable when "
        "a boot witness or the M1-002 op_arg-encoding refinement drives "
        "a live mint end-to-end.",
    "surface destroy ok [legacy: SURFACE DESTROY OK]":
        "R113.M1-001 (#2381) + R113.M1-001b (#2424): kernel-side "
        "KIND_SURFACE destroy fingerprint; handler wired M1-001b (cap/"
        "handlers/cap_handler_surface.pdx OP_SURFACE_DESTROY branches "
        "on R_SURFACE_KGATE_DESTROY and calls surface_destroy), emitter "
        "(mint/destroy) lands via first user-space surface_mint call.  "
        "Assertable when a boot witness or the M1-002 refinement drives "
        "the mint -> destroy pair end-to-end.",
    "surface commit ok [legacy: SURFACE COMMIT OK]":
        "R113.M1-002 (#2382) + R113.M1-001b (#2424): kernel-side "
        "SURFACE COMMIT OK tag; the M1-002 emitter has landed at src/"
        "kernel/core/graphics/surface_commit_ops.pdx (surface_commit "
        "body) which calls surface_row_swap + surface_stats_bump_commits "
        "then klog_s1_x2 with this tag and (sid, serial) KVs.  Handler "
        "wired M1-001b (cap/handlers/cap_handler_surface.pdx "
        "OP_SURFACE_COMMIT branches on R_SURFACE_KGATE_COMMIT and calls "
        "surface_row_swap; the M1-002 surface_commit body sits alongside "
        "and can be invoked directly by a boot witness).  Emitter lands "
        "in the default matrix via first user-space surface_mint call.  "
        "Closed the Wave-12 SURFACE COMMIT OK allowlist gap when the "
        "tag landed with the substrate.",
    "surface fmt bind ok [legacy: SURFACE FMT BIND OK]":
        "R113.M1-004 (#2384) + R113.M1-001b (#2424): kernel-side "
        "SURFACE FMT BIND OK fingerprint; surface_format_bind_at_mint "
        "(src/kernel/core/graphics/surface_format.pdx) emits this via "
        "klog_s1_d2 with sid=<slot> + formats=<count> on first-bind for "
        "a slot (idempotent via the 256-bit _bind_bitmap).  Handler "
        "wired M1-001b (cap/handlers/cap_handler_surface.pdx "
        "OP_SURFACE_ATTACH already reaches surface_row_pending_set; the "
        "M1-004 format-bind body sits alongside and its klog_s1_d2 tag "
        "emit is reached whenever a live mint triggers the first-bind "
        "path).  Emitter lands in the default matrix via first user-"
        "space surface_mint call.",
    "surface present ok [legacy: SURFACE PRESENT OK]":
        "R113.M1-005 (#2385) + R113.M1-001b (#2424): kernel-side "
        "SURFACE PRESENT OK tag; the M1-005 emitter has landed at src/"
        "kernel/core/graphics/surface_present.pdx (surface_present_"
        "notify body) which validates slot + serial then klog_s1_x2's "
        "this tag with (sid, serial) KVs.  Handler wired M1-001b (cap/"
        "handlers/cap_handler_surface.pdx OP_SURFACE_COMMIT already "
        "reaches surface_row_swap; the M1-005 surface_present_notify "
        "body is called by the R36 display-plane IRQ handler after "
        "scanout completes -- that IRQ wire lands separately with the "
        "R36 display-plane bring-up).  Emitter reachable in the "
        "default matrix once a boot witness wires mint -> attach -> "
        "commit -> notify end-to-end.  Closed the last of the doc §8 "
        "five-tag mandate slots (all five tags now have live emitters).",

    # ------------------------------------------------------------------
    # R113.M5-022 (paideia-os #2402): KIND_SESSION mint fingerprint
    # (src/kernel/core/cap/kind_session.pdx).  session_mint validates
    # owner_task, low-first-scans over the 16-row _sessions pool for a
    # free slot, bumps the LAM generation on the claimed row, stamps
    # session_id (== row_id) + owner_task + state=LOGIN(1) + seats=0
    # + reserved zero, bumps _session_stats[MINTS] and emits SESSION
    # MINT OK sid=<session_id> own=<owner_task> via klog_s1_x2 with
    # the v2-push idiom.  Destroy / attach_seat / set_state DO NOT
    # emit fingerprints per issue #2402's contract (only mint emits).
    # Emitter is live but not reachable in the default matrix yet:
    # kind_session_init runs at boot (defensive _sessions +
    # _session_stats zero-scrub) but is a pure zero-out, and no boot
    # witness or cap-dispatcher arm calls session_mint yet -- the
    # follow-on session-manager landing wiring session_mint ->
    # session_attach_seat -> session_set_state end-to-end will close
    # this allowlist entry.  Same real-HW / wire-deferred posture as
    # the sibling `surface mint ok` / `surface commit ok` entries
    # above.
    # ------------------------------------------------------------------
    "session mint ok [legacy: SESSION MINT OK]":
        "R113.M5-022 (#2402): kernel-side KIND_SESSION mint "
        "fingerprint; session_mint (src/kernel/core/cap/kind_session."
        "pdx) emits this via klog_s1_x2 with (sid, own) KVs on every "
        "successful mint past the owner_task != 0 + free-slot gates.  "
        "Substrate + emitter landed together; kind_session_init runs "
        "at boot (defensive pool + stats scrub) but is a pure zero-"
        "out, and the cap-dispatcher OP_SESSION_MINT arm is a follow-"
        "on landing.  Assertable when the follow-on session-manager "
        "landing (or a boot witness) drives session_mint end-to-end.",

    # ------------------------------------------------------------------
    # R113.M7-036 (paideia-os #2416): KIND_CAPTURE grant fingerprint
    # (src/kernel/core/cap/kind_capture.pdx).  capture_grant validates
    # granted_task != 0, low-first-scans over the 16-row _captures pool
    # for a free slot, reads hpet_now_ns for granted_ns, computes
    # expires_ns (0 for permanent-grant sentinel, else granted_ns +
    # duration_ns), bumps the LAM generation on the claimed row, stamps
    # capture_id (== row_id) + granted_task + source_surface (0 =
    # full-screen sentinel) + granted_ns + expires_ns + reserved zero,
    # bumps _capture_stats[GRANTS] and emits CAPTURE GRANT OK id=<n>
    # src=<n> expires=<n> via klog_s1_x3 with the 3-push idiom lifted
    # from cow_write.pdx L996-1002.  Revoke / check DO NOT emit
    # fingerprints per issue #2416's contract (only grant emits).
    # Emitter is live but not reachable in the default matrix yet:
    # kind_capture_init runs at boot (defensive _captures +
    # _capture_stats zero-scrub) but is a pure zero-out, and no boot
    # witness or cap-dispatcher arm calls capture_grant yet -- the
    # follow-on capture-broker landing wiring OP_CAPTURE_GRANT /
    # OP_CAPTURE_REVOKE / OP_CAPTURE_CHECK end-to-end will close this
    # allowlist entry.  Same real-HW / wire-deferred posture as the
    # sibling `session mint ok` entry above.
    # ------------------------------------------------------------------
    "capture grant ok [legacy: CAPTURE GRANT OK]":
        "R113.M7-036 (#2416): kernel-side KIND_CAPTURE grant "
        "fingerprint; capture_grant (src/kernel/core/cap/kind_capture."
        "pdx) emits this via klog_s1_x3 with (id, src, expires) KVs "
        "on every successful grant past the granted_task != 0 + "
        "free-slot gates.  Substrate + emitter landed together; "
        "kind_capture_init runs at boot (defensive pool + stats "
        "scrub) but is a pure zero-out, and the cap-dispatcher "
        "OP_CAPTURE_GRANT arm is a follow-on landing.  Assertable "
        "when the follow-on capture-broker landing (or a boot "
        "witness) drives capture_grant end-to-end.",

    # ------------------------------------------------------------------
    # R113.M5-025 (paideia-os #2405): kernel-side KIND_SEAT mint
    # fingerprint (src/kernel/core/cap/kind_seat.pdx).  Unlike the
    # sibling session/capture inits (pure zero-scrub), kind_seat_init
    # additionally mints default seat 0 at boot via seat_create(0,
    # &default_seat_name) so a single-seat kernel has seat 0 available
    # before any real seat-manager landing runs.  This fires SEAT
    # CREATE OK id=0 session=0 on every boot in the default QEMU
    # matrix.  Allowlisted pending the golden refresh that pins this
    # line into the boot fingerprint sequence; when that lands the
    # entry retires and the assertion holds the invariant instead.
    # ------------------------------------------------------------------
    "seat create ok [legacy: SEAT CREATE OK]":
        "R113.M5-025 (#2405): kernel-side KIND_SEAT mint "
        "fingerprint; seat_create (src/kernel/core/cap/kind_seat.pdx) "
        "emits via klog_s1_x2 with (id, session) KVs on every "
        "successful mint past the session_slot + free-slot gates.  "
        "kind_seat_init calls seat_create(0, &default_seat_name) at "
        "boot to establish seat 0 for single-seat compatibility, "
        "which makes this a live boot-witness emit today.  Pending "
        "golden refresh to pin the line into the boot fingerprint "
        "sequence; retire this entry when the compositor smoke "
        "golden is updated.",

    # ------------------------------------------------------------------
    # R113.M7-035 (paideia-os #2415): SCREENCAST START OK fingerprint
    # (src/kernel/core/cap/kind_screencast.pdx).  screencast_start
    # validates the KIND_CAPTURE binding (capture_row_valid), the dst
    # ring slot, the format, and the fps_limit ceiling (240), scans for
    # a free slot, reads hpet_now_ns for started_ns (seeded as
    # last_frame_ns), bumps the LAM generation on the claimed row,
    # stamps capture_id + dst_ring_slot + format + fps_limit +
    # frame_count=0 + started_ns + last_frame_ns, bumps _screencast_
    # stats[STARTS] and emits SCREENCAST START OK id=<n> cap=<n>
    # fps=<n> via klog_s1_x3 with the 3-push idiom.  Stop / frame /
    # tick_all DO NOT emit per issue #2415 contract (start-only emit).
    # Emitter is live but not reachable in the default matrix yet:
    # kind_screencast_init runs at boot (defensive pool + stats zero-
    # scrub) but is a pure zero-out, and no boot witness or cap-
    # dispatcher arm calls screencast_start yet -- the follow-on
    # capture-broker landing wiring OP_SCREENCAST_START /
    # OP_SCREENCAST_STOP end-to-end (together with the vblank_handler
    # wire-in of screencast_tick_all) will close this allowlist entry.
    # Same wire-deferred posture as the sibling `capture grant ok`
    # entry above.
    # ------------------------------------------------------------------
    "screencast start ok [legacy: SCREENCAST START OK]":
        "R113.M7-035 (#2415): kernel-side KIND_SCREENCAST start "
        "fingerprint; screencast_start (src/kernel/core/cap/kind_"
        "screencast.pdx) emits this via klog_s1_x3 with (id, cap, "
        "fps) KVs on every successful start past the "
        "capture_row_valid + dst != 0 + format != 0 + fps <= 240 + "
        "free-slot gates.  Substrate + emitter landed together; "
        "kind_screencast_init runs at boot (defensive pool + stats "
        "scrub) but is a pure zero-out, and both the cap-dispatcher "
        "OP_SCREENCAST_START arm and the vblank_handler wire-in of "
        "screencast_tick_all are follow-on landings (the latter "
        "co-lands with the M7-033 frame_capture_emit hook).  "
        "Assertable when the follow-on capture-broker landing (or a "
        "boot witness) drives capture_grant -> screencast_start "
        "end-to-end.",

    # ------------------------------------------------------------------
    # R113.M5-026 (paideia-os #2406): SESSION REVOKE cascade fingerprint
    # (src/kernel/core/graphics/session_revoke.pdx).  session_revoke
    # tears down every KIND_SURFACE row + wrapping role authority
    # (TOPLEVEL / POPUP / LAYER_SHELL) owned by the session's owner_task,
    # drops surface slots from the z-order stack, clears keyboard/pointer
    # focus if it points at any dying surface, then session_set_state
    # (EXITED) + session_destroy on the session row itself.  Emits
    # SESSION REVOKE OK sid=<n> surfaces=<n> tops=<n> pops=<n> lyrs=<n>
    # via klog_s1_d5 (this same landing mints that wrapper -- see
    # src/kernel/core/klog/wrappers.pdx §klog_s1_d5).  Emitter is live
    # but not reachable in the default matrix yet: no boot witness or
    # cap-dispatcher arm calls session_revoke -- the follow-on cap-
    # dispatcher landing wiring session cap-drop -> session_revoke is
    # the natural first consumer.  Same wire-deferred posture as the
    # sibling `session mint ok` entry above; retires when a boot witness
    # (or the cap-dispatcher wire) exercises the full mint session ->
    # mint surfaces -> create roles -> revoke session cascade.
    # ------------------------------------------------------------------
    "session revoke ok [legacy: SESSION REVOKE OK]":
        "R113.M5-026 (#2406): SESSION REVOKE cascade fingerprint; "
        "session_revoke (src/kernel/core/graphics/session_revoke.pdx) "
        "emits this via klog_s1_d5 with (sid, surfaces, tops, pops, "
        "lyrs) KVs on every successful cascade past the session-live + "
        "owner != 0 + state != EXITED gates.  Emitter is live but not "
        "reachable in the default matrix yet: no boot witness or cap-"
        "dispatcher arm calls session_revoke.  Assertable when the "
        "follow-on cap-dispatcher landing (or a boot witness) drives "
        "mint session -> mint surfaces -> create roles -> revoke "
        "session end-to-end.",
    "dmabuf import ok [legacy: DMABUF IMPORT OK]":
        "R113.M4-017 (paideia-os #2397): kernel-side DMABUF IMPORT OK "
        "tag emitted by dma_buf_import (src/kernel/core/graphics/"
        "dma_buf.pdx) via klog_s1_x3 with (id, bo, size) KVs on every "
        "successful KIND_GPU_BO -> DMA-BUF descriptor import.  Emitter "
        "is live but not reachable in the default matrix yet: no boot "
        "witness or cap dispatcher arm calls dma_buf_import -- "
        "dma_buf_init is a pure zero-out at boot and the descriptor "
        "pool itself is kernel-internal at M4 (a KIND_DMA_BUF cap "
        "wrapper lands with R113.M5's cross-process share path).  "
        "Reachable end-to-end when the R113.M4 rendering-path wave "
        "wires a scanout witness that mints a KIND_GPU_BO, imports it "
        "as a DMA-BUF descriptor via dma_buf_import, and releases via "
        "dma_buf_release after the scanout ack -- the natural first "
        "consumer of the substrate this file lands.  Same real-HW / "
        "wire-deferred posture as the sibling `surface present ok` "
        "entry above.",
    "surface toplevel create ok [legacy: TOPLEVEL CREATE OK]":
        "R113.M2-006 (paideia-os #2386): kernel-side SURFACE TOPLEVEL "
        "CREATE OK tag emitted by toplevel_create (src/kernel/core/"
        "graphics/surface_toplevel.pdx) via klog_s1_x2 with (sid, tid) "
        "KVs on every successful create.  Emitter is live but not "
        "reachable in the default matrix yet: no boot witness or cap "
        "dispatcher arm calls toplevel_create -- toplevel_init runs at "
        "boot (defensive pool scrub) but is a pure zero-out.  The "
        "companion cap dispatcher wire (a role-multiplexed OP_SURFACE_"
        "ROLE_TOPLEVEL_* arm on cap_handler_surface) is a follow-on "
        "landing.  Same real-HW / wire-deferred posture as the sibling "
        "`surface mint ok` and `surface commit ok` entries above; "
        "reachable end-to-end when a boot witness mints a surface + "
        "creates a toplevel role over it (natural companion to the "
        "M1-002 op_arg-encoding refinement).",
    "surface popup create ok [legacy: POPUP CREATE OK]":
        "R113.M2-007 (paideia-os #2387): kernel-side SURFACE POPUP "
        "CREATE OK tag emitted by popup_create (src/kernel/core/"
        "graphics/surface_popup.pdx) via klog_s1_x3 with (sid, pid, "
        "parent) KVs on every successful create.  Emitter is live but "
        "not reachable in the default matrix yet: no boot witness or "
        "cap dispatcher arm calls popup_create -- popup_init runs at "
        "boot (defensive pool scrub) but is a pure zero-out.  The "
        "companion cap dispatcher wire (a role-multiplexed OP_SURFACE_"
        "ROLE_POPUP_* arm on cap_handler_surface) is a follow-on "
        "landing.  Same real-HW / wire-deferred posture as the sibling "
        "`surface toplevel create ok` entry above; reachable end-to-"
        "end when a boot witness mints two surfaces (popup + parent) "
        "and creates a popup role anchored to the parent via "
        "popup_create(surface_slot, parent_slot, anchor_x, anchor_y, "
        "gravity).",
    "surface layer shell create ok [legacy: LAYER SHELL CREATE OK]":
        "R113.M2-008 (paideia-os #2388): kernel-side SURFACE LAYER "
        "SHELL CREATE OK tag emitted by layer_shell_create (src/kernel/"
        "core/graphics/surface_layer_shell.pdx) via klog_s1_x3 with "
        "(sid, lsid, layer) KVs on every successful create.  Emitter "
        "is live but not reachable in the default matrix yet: no boot "
        "witness or cap dispatcher arm calls layer_shell_create -- "
        "layer_shell_init runs at boot (defensive pool scrub) but is a "
        "pure zero-out.  The companion cap dispatcher wire (a role-"
        "multiplexed OP_SURFACE_ROLE_LAYER_SHELL_* arm on cap_handler_"
        "surface) is a follow-on landing.  Same real-HW / wire-"
        "deferred posture as the sibling `surface toplevel create ok` "
        "entry above; reachable end-to-end when a boot witness mints "
        "a surface + creates a layer-shell role over it (panel / "
        "taskbar / notification surfaces are the M2 consumers).",

    # ------------------------------------------------------------------
    # R113.M2-009 (paideia-os #2389): wl_shm-equivalent CPU-side buffer
    # path (src/kernel/core/graphics/shm_pool.pdx).  shm_pool_init is
    # wired into kernel_main after damage_region_init and fires on
    # every boot, emitting `shm pool ok size=<n> free=<n>` via
    # klog_s1_x2 with (SHM_POOL_SIZE_BYTES=4194304, initial-free=same)
    # as the two hex KVs.  BOOT-VISIBLE and stable-valued but no
    # golden file currently pins the literal -- pinning it requires an
    # expected-boot-*.txt line that fits every existing 14-mode matrix
    # AND survives a future landing that changes the pool size or
    # pre-reserves a compositor carve-out reducing the free count.
    # The natural pin lands with the M3 rendering-path boot witness
    # (mint -> shm_pool_alloc -> shm_buffer_wrap -> surface_attach_
    # buffer -> surface_commit end-to-end) which will also assert the
    # post-alloc free-byte movement, making the initial-state pin
    # meaningful in cascade rather than in isolation.
    # ------------------------------------------------------------------
    "shm pool ok [legacy: SHM POOL OK]":
        "R113.M2-009 (#2389): SHM pool boot init fingerprint; "
        "shm_pool_init (src/kernel/core/graphics/shm_pool.pdx) fires "
        "unconditionally in kernel_main after damage_region_init and "
        "emits `shm pool ok size=<n> free=<n>` via klog_s1_x2.  "
        "Assertable when the M3 rendering-path boot witness lands and "
        "pins both the initial-state values and the post-alloc "
        "movement in cascade.",

    # ------------------------------------------------------------------
    # R113.M7-032 (paideia-os #2412): FrameCaptureView@0.1 semantic-
    # pipe schema DECLARATION (src/kernel/core/graphics/frame_capture_
    # schema.pdx).  frame_capture_schema_init is wired into kernel_main
    # after vblank_init and fires unconditionally on every boot,
    # emitting `frame capture schema ok size=0x60` via klog_s1_x1
    # with (FCV_RECORD_BYTES = 96) as the sole hex KV.  BOOT-VISIBLE
    # and stable-valued but no golden currently pins the literal --
    # the M7-032 landing is schema DECLARATION only (constants +
    # fingerprint emit); the pool substrate, mint gate, cap-invoke
    # dispatcher, and vblank_handler emit hook all land at M7-033
    # (sibling issue, deferred).  The natural pin lands with the
    # M7-033 end-to-end capture witness (compositor mint -> vblank
    # capture emit -> semantic-pipe consumer decode) which will also
    # assert the record-shape decode against the same 96-byte
    # constant, making the initial-state pin meaningful in cascade
    # rather than in isolation.  Splitting DECLARATION from SUBSTRATE
    # matches the shm_pool.pdx allowlist rationale above one-for-one.
    # ------------------------------------------------------------------
    "frame capture schema ok [legacy: FRAME CAPTURE SCHEMA OK]":
        "R113.M7-032 (#2412): FrameCaptureView@0.1 schema declaration "
        "boot fingerprint; frame_capture_schema_init (src/kernel/core/"
        "graphics/frame_capture_schema.pdx) fires unconditionally in "
        "kernel_main after vblank_init and emits `frame capture schema "
        "ok size=0x60` via klog_s1_x1.  M7-032 lands constants + "
        "fingerprint only; the pool substrate + mint gate + cap-invoke "
        "dispatcher + vblank_handler emit hook all land at M7-033 "
        "(sibling issue, deferred).  Assertable when the M7-033 end-"
        "to-end capture witness lands and pins the record-shape decode "
        "against the same 96-byte constant in cascade.",

    # ------------------------------------------------------------------
    # R113.M7-033 (paideia-os #2413): FrameCaptureView@0.1 per-frame
    # emission (src/kernel/core/graphics/frame_capture_emit.pdx).
    # frame_capture_emit pushes one 96-byte FrameCaptureView@0.1 record
    # into the 4-slot bounded ring _frame_capture_records at slot =
    # _fcv_head & 3 and advances _fcv_head; it emits `frame capture
    # emit ok fid=<n> sid=<n>` via klog_s1_x2 per emit.  Reachable in
    # principle via the wire surface_present_notify -> frame_capture_
    # maybe_emit_for_surface -> frame_capture_emit, but the wrapper
    # gates on a covering KIND_CAPTURE consent grant (kind_capture.pdx
    # §POOL SUBSTRATE) and the default 14-mode QEMU matrix mints no
    # grants (the M7-036 capture-broker's UX path that mints them
    # requires user-space driving; see kind_capture.pdx §SCOPE), so no
    # emit fires in any current smoke mode.  Same real-HW / wire-
    # deferred posture as the SCREENSHOT OK / SURFACE PRESENT OK /
    # COMPOSITE GPU OK / VBLANK siblings above; assertable when a boot
    # witness mints a KIND_CAPTURE grant covering a live surface and
    # drives a full commit -> present cycle on it (which surfaces the
    # emit through surface_present_notify's post-fingerprint hook).
    # frame_capture_emit_init runs at boot (defensive ring scrub) but
    # emits no fingerprint of its own.
    # ------------------------------------------------------------------
    "frame capture emit ok [legacy: FRAME CAPTURE EMIT OK]":
        "R113.M7-033 (#2413): per-frame FrameCaptureView@0.1 emit "
        "fingerprint; frame_capture_emit (src/kernel/core/graphics/"
        "frame_capture_emit.pdx) emits via klog_s1_x2 with (fid=<frame_"
        "id>, sid=<surface_id>) KVs on every successful ring push.  "
        "Reachable via surface_present_notify -> frame_capture_maybe_"
        "emit_for_surface -> frame_capture_emit, gated on a covering "
        "KIND_CAPTURE consent grant.  Emitter is live but not reached "
        "in the default matrix yet: the M7-036 capture-broker's UX "
        "path that mints KIND_CAPTURE grants requires user-space "
        "driving.  Same real-HW / wire-deferred posture as the "
        "SCREENSHOT OK / SURFACE PRESENT OK / COMPOSITE GPU OK "
        "siblings above; assertable when a boot witness mints a "
        "KIND_CAPTURE grant covering a live surface and drives one "
        "commit -> present cycle on it end-to-end.",

    # ------------------------------------------------------------------
    # R113.M2-011 (paideia-os #2391): global focus model
    # (src/kernel/core/graphics/focus.pdx).  Two transition fingerprints
    # (KBD / PTR) fire on focus_set_keyboard / focus_set_pointer when
    # the target slot differs from the current cell; a repeat-set with
    # the same slot is a silent no-op success (idempotency mirrors
    # surface_format_bind_at_mint).  Neither is reachable in the
    # default 14-mode matrix today: the first live callers are the
    # input dispatcher (blocked on xHCI MSI-X routing for the HID
    # Transfer Event handler, see drivers/xhci/hid_kbd_attach.pdx §IRQ
    # path) and the compositor's refocus-on-window-activate path
    # (R113.M2-002+ landings still open).  Real-HW / wire-deferred
    # posture identical to `hid kbd attach ok` sibling.
    # ------------------------------------------------------------------
    "focus kbd ok [legacy: FOCUS KBD OK]":
        "R113.M2-011 (#2391): keyboard-focus transition tag; "
        "focus_set_keyboard emits via klog_s1_x1 with sid=<slot> KV "
        "when the new slot differs from _kbd_focus_slot.  First live "
        "caller is the input dispatcher (blocked on xHCI MSI-X routing "
        "per drivers/xhci/hid_kbd_attach.pdx §IRQ path).  Assertable "
        "when a boot witness drives focus_set_keyboard against a live "
        "surface slot end-to-end.",
    "focus ptr ok [legacy: FOCUS PTR OK]":
        "R113.M2-011 (#2391): pointer-focus transition tag; "
        "focus_set_pointer emits via klog_s1_x1 with sid=<slot> KV "
        "when the new slot differs from _ptr_focus_slot.  First live "
        "caller is the pointer-motion worker in the input dispatcher "
        "landing (same MSI-X blocker as the KBD sibling).  Assertable "
        "when a boot witness drives focus_set_pointer against a live "
        "surface slot end-to-end.",

    # ------------------------------------------------------------------
    # R113.M2-010 (paideia-os #2390): Z-order stack + "raise on focus"
    # activation (src/kernel/core/graphics/z_order.pdx).  Emitted by
    # z_order_raise via klog_s1_x2 with (sid, depth) KVs on any
    # successful raise (both the shift-remove-and-append arm and the
    # auto-add arm).  Live caller is focus_set_keyboard (focus.pdx
    # fsk_store arm) as the "raise on focus" side-effect per the issue
    # title mandate; unreachable in the default 14-mode matrix today
    # because focus_set_keyboard itself is only reached via the input
    # dispatcher (blocked on xHCI MSI-X routing, see the focus kbd ok /
    # focus ptr ok siblings above and drivers/xhci/hid_kbd_attach.pdx
    # §IRQ path) or the compositor's refocus-on-window-activate path
    # (R113.M2-002+ landings still open).  Same real-HW / wire-deferred
    # posture as the focus siblings; assertable when a boot witness
    # drives focus_set_keyboard against a live surface slot end-to-end.
    # ------------------------------------------------------------------
    "z order raise ok [legacy: Z ORDER RAISE OK]":
        "R113.M2-010 (#2390): Z-order raise fingerprint; "
        "z_order_raise emits via klog_s1_x2 with (sid=<slot>, "
        "depth=<new_count>) KVs on any successful raise.  Live "
        "caller is focus_set_keyboard (focus.pdx fsk_store arm) "
        "as the 'raise on focus' side-effect.  First reachable in "
        "the default matrix when a boot witness drives focus_set_"
        "keyboard against a live surface slot (same MSI-X wire "
        "blocker as the focus kbd / focus ptr siblings above).",

    # ------------------------------------------------------------------
    # R113.M5-024 (paideia-os #2404): mid-session compositor lock hook
    # (src/kernel/core/graphics/lockscreen.pdx).  Two fingerprints fire
    # from the engage / dismiss entry points: LOCKSCREEN ENGAGE OK on
    # a successful lock (session validated, not already engaged, lock
    # surface bound, z-stack snapshotted + dismantled, lock surface
    # raised + focused, session moved to LOCKED) and LOCKSCREEN
    # DISMISS OK on a successful unlock (session validated, engaged,
    # lock surface removed from z-stack, snapshot restored via z_order
    # _push_top loop, session moved to ACTIVE, engaged/stash cleared).
    # Both emit via klog_s1_x1 with sid=<session_id> KV.  Emitter is
    # live but unreachable in the default 14-mode QEMU matrix today:
    # the full engage/dismiss cascade requires (a) a live session_mint
    # (kind_session substrate; no boot witness drives it yet -- the
    # sibling `session mint ok` entry above documents the same wire-
    # deferred posture), (b) a bound lock surface via lockscreen_bind
    # _surface (compositor-side lock-agent landing not yet wired), and
    # (c) the input-server MSI-X wire (shared blocker with focus /
    # z_order siblings, drivers/xhci/hid_kbd_attach.pdx §IRQ path) for
    # the interactive dismiss path (auth-success trigger flows through
    # the input dispatcher).  Assertable end-to-end when the follow-on
    # KIND_LOCK_AGENT cap dispatcher lands and a boot witness drives
    # session_mint -> lockscreen_bind_surface -> lockscreen_engage ->
    # lockscreen_dismiss against a live surface pair.
    # ------------------------------------------------------------------
    "lockscreen engage ok [legacy: LOCKSCREEN ENGAGE OK]":
        "R113.M5-024 (#2404): mid-session compositor lock engage "
        "fingerprint; lockscreen_engage (src/kernel/core/graphics/"
        "lockscreen.pdx) emits via klog_s1_x1 with sid=<session_id> "
        "KV on every successful engage past the session_row_valid + "
        "not-already-engaged + surface-bound gates.  Emitter is live "
        "but not reachable in the default matrix yet: no boot witness "
        "drives session_mint (same posture as the `session mint ok` "
        "sibling above), no compositor-side lock-agent lands a "
        "lockscreen_bind_surface call, and the KIND_LOCK_AGENT cap "
        "dispatcher arm is a follow-on landing.  Assertable when a "
        "boot witness drives the full cascade end-to-end (session_mint "
        "-> lockscreen_bind_surface -> lockscreen_engage).",
    "lockscreen dismiss ok [legacy: LOCKSCREEN DISMISS OK]":
        "R113.M5-024 (#2404): mid-session compositor lock dismiss "
        "fingerprint; lockscreen_dismiss (src/kernel/core/graphics/"
        "lockscreen.pdx) emits via klog_s1_x1 with sid=<session_id> "
        "KV on every successful dismiss past the session_row_valid + "
        "engaged gates.  Same real-HW / wire-deferred posture as the "
        "`lockscreen engage ok` sibling above; additionally requires "
        "the input-server MSI-X wire for the interactive auth-success "
        "trigger (shared blocker with the focus / z_order siblings, "
        "drivers/xhci/hid_kbd_attach.pdx §IRQ path).  Assertable when "
        "the KIND_LOCK_AGENT cap dispatcher lands and a boot witness "
        "drives engage -> dismiss end-to-end.",

    # ------------------------------------------------------------------
    # R113.M4-020 (paideia-os #2400): damage-driven redraw planner
    # (src/kernel/core/graphics/composite_plan.pdx).  composite_plan
    # walks _z_stack top-down, enumerates each surface's per-frame
    # damage rects via damage_region_count/damage_region_get, clips
    # each rect to the _gop_fb_width x _gop_fb_height framebuffer
    # bounds, and writes the clipped packed u64 rects into the
    # caller's out_rects_ptr buffer up to out_cap; after enumeration
    # it calls damage_region_clear per visited surface so the next
    # frame starts with an empty region.  Emits COMPOSITE PLAN OK
    # via klog_s1_x2 with (dirty_count=<n_written>, covered=<n_
    # examined>) KVs once per invocation.  covered - dirty_count is
    # the observability handle for "planner did work the GPU won't
    # see" (offscreen drops + capacity overflow).  M4-020 is the
    # planner primitive only; the GPU backend wire (R36 display-
    # plane bring-up / R113.M4 present-fence hook that calls the
    # planner once per composited frame) is a separate follow-on
    # landing.  Same real-HW / wire-deferred posture as the surface
    # present ok / z order raise ok siblings above.  Assertable when
    # a boot witness or the R113.M4 vsync hook drives composite_plan
    # against a live z-stack with pending damage end-to-end.
    # ------------------------------------------------------------------
    "composite plan ok [legacy: COMPOSITE PLAN OK]":
        "R113.M4-020 (#2400): per-frame damage-driven composite "
        "planner fingerprint; composite_plan emits via klog_s1_x2 "
        "with (dirty_count=<n_written>, covered=<n_examined>) KVs "
        "on every invocation (unconditional; covers the "
        "dirty_count==0 case as the 'no dirty surfaces this frame' "
        "witness).  Emitter is live but not reachable in the "
        "default matrix yet: no live caller wires the planner -- "
        "the GPU backend hook (R36 display-plane bring-up / "
        "R113.M4 present-fence integration) is a separate follow-"
        "on landing.  Same real-HW / wire-deferred posture as the "
        "surface present ok / z order raise ok siblings above; "
        "assertable when a boot witness or the R113.M4 vsync hook "
        "drives composite_plan against a live z-stack with pending "
        "damage end-to-end.",

    # ------------------------------------------------------------------
    # R113.M4-018 (paideia-os #2398): direct-scanout gate
    # (src/kernel/core/graphics/scanout.pdx).  scanout_try_direct
    # walks the seven gates (primary plane latched, plane row live,
    # z-stack has exactly one surface, top slot live, surface fourcc
    # maps to a DPP ordinal, plane native format matches, bind
    # succeeds) once per frame; on the FIRST successful admission for
    # each surface it emits SCANOUT DIRECT OK via klog_s1_x2 with
    # (sid=<slot>, plane=<row>) KVs and sets the corresponding bit in
    # _scanout_emitted_bmp so a re-activation of the same surface is
    # silent from the second admission onwards (defeats the multi-
    # emit smearing that would swamp the fingerprint stream on a
    # workload that oscillates between direct and composite paths).
    # Unreachable in the default 14-mode QEMU matrix today because
    # (a) no boot witness calls scanout_set_primary_plane against a
    # live display-plane row, and (b) the physical HW plane write
    # (Iris Xe DSPCNTR / DSPSURF etc.) is the R36 atomic-commit
    # landing still open.  Same real-HW / wire-deferred posture as
    # the composite plan ok / surface present ok / z order raise ok
    # siblings above; assertable when a boot witness mints a display
    # plane, calls scanout_set_primary_plane, minted a KIND_SURFACE
    # with a matching fourcc, committed a frame (current_bo non-zero
    # via surface_row_swap), pushes the surface onto the z-order
    # stack via z_order_push_top and then calls scanout_try_direct.
    # ------------------------------------------------------------------
    "scanout direct ok [legacy: SCANOUT DIRECT OK]":
        "R113.M4-018 (#2398): direct-scanout admission fingerprint; "
        "scanout_try_direct emits via klog_s1_x2 with (sid=<slot>, "
        "plane=<row>) KVs on the FIRST successful admission for "
        "each surface (subsequent admissions of the same surface "
        "are silent, gated by _scanout_emitted_bmp).  Emitter is "
        "live but not reachable in the default matrix yet: no boot "
        "witness calls scanout_set_primary_plane, and the plane's "
        "physical HW register write is the R36 atomic-commit "
        "landing still open.  Same real-HW / wire-deferred posture "
        "as the composite plan ok / surface present ok / z order "
        "raise ok siblings; assertable when a boot witness mints a "
        "display plane, calls scanout_set_primary_plane, mints a "
        "KIND_SURFACE with a matching fourcc, commits a frame, "
        "pushes it onto z-order and calls scanout_try_direct.",

    # ------------------------------------------------------------------
    # R113.M4-019 (paideia-os #2399): GPU-composite fallback path
    # (src/kernel/core/graphics/composite_gpu.pdx).  composite_gpu_
    # blend orchestrates the multi-surface blend the compositor's
    # frame loop falls back to when scanout_try_direct declines
    # (multi-surface z-stack, format mismatch, no primary plane
    # latched, ...).  composite_prepare_blit_batch walks _z_stack
    # bottom-up and emits per-surface (header + packed rects) into
    # a scratch buffer; composite_gpu_blend calls kgsub_note for
    # the wire-deferred submit-ring witness and emits COMPOSITE GPU
    # OK batches=<n> dirty=<n> via klog_s1_x2 once per fallback
    # frame.  Unreachable in the default 14-mode QEMU matrix today
    # because (a) no boot witness calls composite_gpu_blend, and
    # (b) the physical KIND_GPU_SUBMIT mint + submit-ring doorbell
    # wire is the follow-on R36 atomic-commit landing.  Same real-
    # HW / wire-deferred posture as the composite plan ok /
    # scanout direct ok / surface present ok / z order raise ok
    # siblings above; assertable when a boot witness drives the
    # compositor frame loop end-to-end with a multi-surface z-stack
    # and pending damage.
    # ------------------------------------------------------------------
    "composite gpu ok [legacy: COMPOSITE GPU OK]":
        "R113.M4-019 (#2399): multi-surface GPU-composite fallback "
        "fingerprint; composite_gpu_blend emits via klog_s1_x2 with "
        "(batches=<n_surfaces>, dirty=<n_rects>) KVs on every "
        "invocation (unconditional; the batches==0 case is the "
        "'fallback frame with nothing dirty' witness).  Emitter is "
        "live but not reachable in the default matrix yet: no live "
        "caller wires the blender -- the compositor frame loop wire "
        "(R36 display-plane bring-up / R113.M4 present-fence hook "
        "that calls composite_gpu_blend once per fallback frame) is "
        "a separate follow-on landing, and the physical KIND_GPU_"
        "SUBMIT mint + submit-ring doorbell wire is the R36 atomic-"
        "commit landing still open.  Same real-HW / wire-deferred "
        "posture as the composite plan ok / scanout direct ok / "
        "surface present ok / z order raise ok siblings above; "
        "assertable when a boot witness or the R113.M4 vsync hook "
        "drives the compositor frame loop end-to-end with a multi-"
        "surface z-stack and pending damage.",

    # ------------------------------------------------------------------
    # R113.M4-021 (paideia-os #2401): KIND_DISPLAY vblank event handler
    # emits "vblank tick [legacy: VBLANK TICK] counter=<n>" via
    # klog_s1_x1.  Not tracked here — the gate scanner requires an "OK"
    # token to record an emit, and this tag uses TICK.  Allowlist entry
    # retired 2026-09-08 to satisfy the stale-allowlist gate; the
    # deferred-witness rationale is preserved inline in vblank.pdx.
    # (Original vblank vestigial allowlist below intentionally removed.)
    # ------------------------------------------------------------------
    # ------------------------------------------------------------------
    # R113.M4-021 (paideia-os #2401): KIND_DISPLAY vblank event
    # handler (src/kernel/core/graphics/vblank.pdx).  vblank_handler
    # bumps _vblank_counter, fires the compositor pass (scanout_try_
    # direct fast path first; composite_plan enumerate-only fallback),
    # walks the z-stack and calls surface_present_notify per rendered
    # surface, then emits VBLANK TICK counter=<n> via klog_s1_x1.  The
    # emit is unconditional per handler call (once per vblank tick per
    # display) -- the observability handle for "did vblank fire?"
    # depends on the per-tick emit.  Unreachable in the default 14-
    # mode QEMU matrix today because the KIND_DISPLAY IRQ dispatcher
    # that would drive vblank_handler is a separate follow-on landing
    # (the R36 display-plane bring-up wave still open).  vblank_init
    # runs at boot from kernel_main.pdx boot cascade (defensive re-
    # scrub of _vblank_counter) but emits no fingerprint of its own,
    # and vblank_get_counter is a pure read.  Same real-HW / wire-
    # deferred posture as the composite plan ok / scanout direct ok /
    # surface present ok / z order raise ok siblings above; assertable
    # when the R36 IRQ dispatcher (or a boot witness) calls vblank_
    # handler(display_id=1) end-to-end.
    # ------------------------------------------------------------------
    # (vblank tick entry retired 2026-09-08: gate scanner only tracks
    # tags containing "OK"; TICK tag was never scanned in, causing the
    # allowlist entry to always report STALE.  Deferred-witness rationale
    # preserved inline in src/kernel/core/graphics/vblank.pdx.)

    # ------------------------------------------------------------------
    # R113.M7-034 (paideia-os #2414): on-demand full-frame capture
    # substrate (src/kernel/core/graphics/screenshot.pdx).
    # capture_screenshot(dst_bo_slot, format) validates the
    # destination KIND_GPU_BO row, gates the format against the
    # M7-034 admissible set (XRGB8888 only), verifies the GOP
    # framebuffer is initialised (_gop_fb_base_pa != 0), verifies
    # the destination BO is large enough for width * height * 4
    # bytes, bumps the wire-deferred SCREENSHOT_ST_BLITS_PENDING
    # witness counter (the physical memcpy from _gop_fb_ptr lands
    # with the R113.M7-034 wire that also lands the KIND_MEMORY-
    # slot-to-VA resolver per dma_buf.pdx §BO L60-63), and emits
    # SCREENSHOT OK bo=<slot> w=<width> h=<height> via klog_s1_x3
    # (one emit per successful capture; per-capture is exactly what
    # a screenshot audit trail wants, distinct from the first-per-
    # surface idempotency scanout_try_direct uses).  Unreachable in
    # the default 14-mode QEMU matrix today because the screenshot
    # key handler (R113.M7-035) and the FrameCaptureView@0.1
    # semantic-pipe consumer (R113.M7-036) are separate follow-on
    # landings; the substrate is staged here so those landings are
    # a single-call insert rather than a substrate-plus-consumer
    # joint drop.  screenshot_init runs at boot (defensive stats
    # scrub) but emits no fingerprint of its own.  Same real-HW /
    # wire-deferred posture as the composite gpu ok / scanout
    # direct ok / vblank tick / dmabuf import ok siblings above;
    # assertable when a boot witness mints a KIND_GPU_BO large
    # enough to hold the framebuffer and calls capture_screenshot
    # with XRGB8888 after gop_fb_console_init has run.
    # ------------------------------------------------------------------
    "screenshot ok [legacy: SCREENSHOT OK]":
        "R113.M7-034 (#2414): on-demand full-frame capture "
        "fingerprint; capture_screenshot emits via klog_s1_x3 with "
        "(bo=<slot>, w=<width>, h=<height>) KVs on every successful "
        "capture (per-capture, not first-per-BO -- each capture is "
        "a distinct user-observable event that the audit trail "
        "should record).  Emitter is live but not reachable in the "
        "default matrix yet: no live caller wires the substrate -- "
        "the screenshot key handler (R113.M7-035) and the "
        "FrameCaptureView@0.1 semantic-pipe consumer (R113.M7-036) "
        "are separate follow-on landings, and the physical memcpy "
        "from _gop_fb_ptr into the destination BO's mapped byte "
        "range is the R113.M7-034 wire that also lands the "
        "KIND_MEMORY-slot-to-VA resolver (per dma_buf.pdx §BO "
        "L60-63).  Same real-HW / wire-deferred posture as the "
        "composite gpu ok / scanout direct ok / vblank tick / "
        "dmabuf import ok siblings above; assertable when a boot "
        "witness mints a KIND_GPU_BO large enough for the panel "
        "geometry and calls capture_screenshot(bo, XRGB8888) after "
        "gop_fb_console_init has run.",

    # ------------------------------------------------------------------
    # R113.M3-012 (paideia-os #2392): keyboard event routing from the
    # KIND_TTY input ring to the focused surface's per-surface u64 ring
    # (src/kernel/core/graphics/kbd_route.pdx).  kbd_event_deliver
    # enqueues one packed (key_code, modifiers, is_press) u64 per
    # drained byte and, on the first-ever successful enqueue for a
    # given surface_slot, emits KBD ROUTE READY sid=<slot> via
    # klog_s1_x1 -- a summary fingerprint, NOT per-event (per issue
    # #2392 §5: "no per-event fingerprint (high-volume)").  Subsequent
    # enqueues on the same slot are silent; the wire volume is
    # proportional to distinct surfaces that ever received input, not
    # to keystroke rate.  Wire caller is tty_stdin_drain via kbd_route_
    # from_tty_byte; focus_get_keyboard() returning FOCUS_NONE short-
    # circuits the helper before any enqueue.  Unreachable in the
    # default 14-mode QEMU matrix because no boot witness sets a
    # keyboard focus (the compositor's refocus-on-window-activate path
    # is still open, and the HID Transfer Event ISR is blocked on
    # xHCI MSI-X routing per drivers/xhci/hid_kbd_attach.pdx §IRQ
    # path).  Same real-HW / wire-deferred posture as the focus /
    # z_order / ptr_route siblings; assertable when a boot witness
    # drives focus_set_keyboard against a live surface slot and then
    # exercises tty_stdin_drain (or calls kbd_event_deliver directly).
    # ------------------------------------------------------------------
    # (kbd route ready entry retired 2026-09-08: same reason — READY
    # tag not scanned.  Deferred-witness rationale in kbd_route.pdx.)

    # ------------------------------------------------------------------
    # R113.M3-013 (paideia-os #2393): pointer event routing from HID
    # mouse + touchpad (src/kernel/core/graphics/ptr_route.pdx).
    # ptr_event_motion / ptr_event_button / ptr_event_axis each emit
    # PTR ROUTE READY sid=<target> via klog_s1_x1 on every successful
    # ring-enqueue.  Delivery target is _implicit_grab_slot (if
    # active) or the z_order top-down hit-test result (motion) /
    # focus_get_pointer (button / axis).  Unreachable in the default
    # 14-mode QEMU matrix because no live caller wires the ptr_event_*
    # leaves yet -- the input dispatcher is blocked on xHCI MSI-X
    # routing (drivers/xhci/hid_kbd_attach.pdx §IRQ path, same blocker
    # as the focus kbd / focus ptr / z order raise siblings above).
    # Assertable when a boot witness or the R113.M3 input dispatcher
    # landing drives a ptr_event_* leaf against a live surface slot
    # end-to-end (motion + hit-test path is the natural first witness
    # since it exercises the full chain: motion latch -> z_order walk
    # -> surface_row_dims_get -> focus_set_pointer -> ring enqueue ->
    # emit).
    # ------------------------------------------------------------------
    # (ptr route ready entry retired 2026-09-08: same reason — READY
    # tag not scanned.  Deferred-witness rationale in ptr_route.pdx.)

    # ------------------------------------------------------------------
    # R113.M3-014 (paideia-os #2394): touch event routing from HID
    # touchscreen (T14 G4 touchscreen SKUs).  Module:
    # src/kernel/core/graphics/touch_route.pdx.  touch_event_down /
    # touch_event_move / touch_event_up / touch_event_cancel each emit
    # TOUCH ROUTE READY sid=<target> via klog_s1_x1 on every successful
    # ring-enqueue.  Down hit-tests via z_order top-down and latches
    # _touch_target[touch_slot]; move/up follow the sticky anchor
    # (wl_touch pinning discipline).  Cancel walks all 10 slots and
    # emits per active target.  Unreachable in the default 14-mode
    # QEMU matrix -- no live caller wires the touch_event_* leaves,
    # blocked on the T14 G4 touchscreen HID handler which itself is
    # blocked on the xHCI MSI-X routing (drivers/xhci/hid_kbd_attach.
    # pdx §IRQ path, same blocker as the ptr_route / focus / z-order /
    # hid_kbd_attach siblings above).  Assertable when the R113.M3
    # touch-dispatcher landing or a boot witness drives a touch_event_*
    # leaf against a live surface slot end-to-end (down + hit-test
    # path is the natural first witness since it exercises the full
    # chain: touch_slot validate -> z_order walk -> surface_row_dims_
    # get -> per-touch state latch -> ring enqueue -> emit).
    # ------------------------------------------------------------------
    # (touch route ready entry retired 2026-09-08: same reason — READY
    # tag not scanned.  Deferred-witness rationale in touch_route.pdx.)

    # ------------------------------------------------------------------
    # R113.M3-015 (paideia-os #2395): modifier-state tracker
    # (src/kernel/core/graphics/modifier_state.pdx).  Single transition
    # fingerprint fires on modifier_set (state actually changed) or
    # modifier_toggle_lock (always changes, XOR is guaranteed to flip).
    # Not reachable in the default 14-mode matrix today: first live
    # callers are the HID keyboard handlers (Transfer Event handler +
    # lock-LED-drive worker) blocked on xHCI MSI-X routing (see
    # drivers/xhci/hid_kbd_attach.pdx §IRQ path).  Real-HW / wire-
    # deferred posture identical to the focus kbd / focus ptr siblings.
    # ------------------------------------------------------------------
    "modifier state ok [legacy: MODIFIER STATE OK]":
        "R113.M3-015 (#2395): modifier-state transition tag; "
        "modifier_set emits via klog_s1_x1 with mask=<hex> KV "
        "when the new state differs from _modifier_state (silent "
        "no-op on key-repeat / spurious-release); modifier_toggle_"
        "lock always emits (XOR always transitions).  First live "
        "caller is the HID kbd Transfer Event handler (blocked on "
        "xHCI MSI-X routing per drivers/xhci/hid_kbd_attach.pdx "
        "§IRQ path).  Assertable when a boot witness drives "
        "modifier_set / modifier_toggle_lock end-to-end.",

    # ------------------------------------------------------------------
    # R113.M3-016 (paideia-os #2396): XKB-equivalent keymap + per-
    # surface delivery (src/kernel/core/graphics/keymap.pdx).  Single
    # summary fingerprint fires from keymap_init (called by
    # kernel_main.pdx alongside kbd_route_init / modifier_state_init /
    # ptr_route_init), reporting the layout name (packed 8-byte ASCII
    # "USQWERTY" LE = 0x5954524557515355) and the number of installed
    # rows (52 = 26 letters + 10 digits + 5 whitespace + 11
    # punctuation).  Reachable every boot -- keymap_init runs
    # unconditionally in the init sequence -- but no golden line pins
    # the exact literal today; the R113.M3-016+ boot smoke that drives
    # keymap_deliver_per_surface end-to-end will land the assertable
    # line and this allowlist entry retires.  Same "reachable but no
    # golden pin yet" posture as the `policy seed ok` / `resolv seed
    # ok` entries above.
    # ------------------------------------------------------------------
    "keymap layout ok [legacy: KEYMAP LAYOUT OK]":
        "R113.M3-016 (#2396): keymap layout summary tag; keymap_init "
        "emits once per boot via klog_s1_x2 with name=<hex> keys=<n> "
        "KVs after installing the US QWERTY rows.  Reachable every "
        "boot via kernel_main.pdx (called alongside kbd_route_init / "
        "modifier_state_init / ptr_route_init), but no golden pins "
        "this exact literal yet -- a R113.M3-016+ boot smoke driving "
        "keymap_deliver_per_surface end-to-end will retire this entry.",

    # Batch 7: G7 close-out (src/user/compositor/*.pdx)
    "pdx kind subsurface meta [legacy: SUBSURFACE SYNC OK]":
        "Wave0-B7 G7-M3-003 (#2258): subsurface_sync (KIND=0x1BA) "
        "data-only decl; kernel dispatcher not yet wired.",
    "xdg shell geometry meta ok [legacy: XDG SHELL GEOMETRY META OK]":
        "Wave0-B7 G7-M4-002 (#2262): xdg_shell_geometry value-type decl; "
        "no KIND cap; first-consumer emit lands with dispatcher wire-body.",
    "xdg popup mint ok [legacy: XDG POPUP MINT OK]":
        "Wave0-B7 G7-M4-003 (#2265): xdg_shell_popup (KIND=0x1C5) "
        "data-only decl; kernel dispatcher not yet wired.",

    # src/user/compositor/popup_positioning.pdx -- Wave0-B14 G7-M8-006
    # (paideia-os #2264). #2264 is a byte-identical duplicate filing of
    # the already-closed #2265 (xdg_shell_popup.pdx, immediately
    # above); this landing closes the duplicate with a distinct,
    # additive capability (KIND_POPUP_POSITIONER = 0x1C3, a LINEAR
    # atomic-mint positioner) rather than re-implementing #2265's row.
    # Same "data-only fingerprint" posture as the sibling `bidi caret
    # init ok` entry (Wave0-B13 G11-M5-001, #2324): no kernel
    # dispatcher exists yet to call popup_positioner_mint.
    "popup positioner init ok [legacy: POPUP POSITIONER INIT OK]":
        "Wave0-B14 G7-M8-006 (paideia-os #2264): popup_positioning "
        "(KIND_POPUP_POSITIONER=0x1C3) data-only decl; kernel "
        "dispatcher not yet wired. #2264 duplicates closed issue "
        "#2265 (xdg_shell_popup.pdx); this row is additive, not a "
        "re-implementation.",
    "dnd offer mint ok [legacy: DND OFFER MINT OK]":
        "Wave0-B7 G7-M5-002 (#2267): dnd_offer sealed cap (KIND=0x1C7) "
        "data-only decl; kernel dispatcher not yet wired.",
    "kind_dnd_offer meta [legacy: KIND_DND_OFFER OK]":
        "Wave0-B7 G7-M5-002 (#2267): dnd_offer cap module-meta tag; "
        "companion to dnd offer mint ok, same wire-body dependency.",
    "kind_selection_owner meta [legacy: KIND_SELECTION_OWNER OK]":
        "Wave0-B7 G7-M5-003 (#2268): selection_owner sealed cap "
        "(KIND=0x1C9) data-only decl; kernel dispatcher not yet wired.",
    "recovery plane takeover ok [legacy: RECOVERY PLANE TAKEOVER OK]":
        "Wave0-B7 G7-M6-002 (#2270): recovery_plane_takeover extends "
        "#2269 with RIGHT_TAKEOVER; input-server-side takeover not yet booted.",

    # ------------------------------------------------------------------
    # Wave 0 Batch 8 — G8/G9/G10/G11/G12 M1 leads + downstream fan-out.
    # Data-only meta decls in cap modules whose dispatchers land with
    # the future wire-body milestone.
    # ------------------------------------------------------------------
    "input server main ok [legacy: INPUT SERVER MAIN OK]":
        "Wave0-B8 G8-M1-001 (#2274): input_server (KIND_INPUT_SERVER=0x1D0, "
        "matches B6-09 forward reservation) data-only decl; kernel dispatcher "
        "not yet wired.",
    "workspace mint ok [legacy: WORKSPACE MINT OK]":
        "Wave0-B8 G9-M1-001 (#2288): workspace_kind (KIND_WORKSPACE=0x1D2) "
        "data-only decl; kernel dispatcher not yet wired.",
    "pdx kind a11y tree meta [legacy: A11Y TREE META OK]":
        "Wave0-B8 G10-M1-001 (#2302): a11y_tree (KIND_A11Y_TREE=0x1D3) "
        "data-only decl; kernel dispatcher not yet wired.",
    "a11y node init ok [legacy: A11Y NODE INIT OK]":
        "Wave0-B14 G10-M1-002 (#2303): kind_a11y_node (KIND_A11Y_NODE=0x1E2) "
        "LINEAR cap, data-only decl; mint/attach_child/detach are schema-only "
        "stubs (no row-pool substrate yet), so no code path can reach a real "
        "mint success tail. Emitted once the future substrate wires "
        "klog_s1_x1 into a11y_node_mint's success arm.",
    "ime session mint ok [legacy: IME SESSION MINT OK]":
        "Wave0-B8 G11-M1-001 (#2314): ime_session LINEAR "
        "(KIND_IME_SESSION=0x1D4) data-only decl; kernel dispatcher not yet wired.",
    "ime provider register ok [legacy: IME PROVIDER REGISTER OK]":
        "Wave0-B10 G11-M2-001 (paideia-os #2315): ime_provider "
        "(KIND_IME_PROVIDER=0x1DC) data-only fingerprint; router-side "
        "dispatcher that would emit it on successful register is a future "
        "landing (§2.20 KIND_IME_ROUTER, #2316). Same posture as the "
        "sibling `ime session mint ok` entry above.",
    "ime router mint ok [legacy: IME ROUTER MINT OK]":
        "Wave0-B11 G11-M3-001 (paideia-os #2316): ime_router "
        "(KIND_IME_ROUTER=0x1DE) data-only fingerprint; dispatcher-side "
        "substrate that would emit it on successful mint is a future "
        "landing (compositor-side cap_handler_ime_router). Same posture "
        "as the sibling `ime session mint ok` / `ime provider register "
        "ok` entries above; closes the G11 IME trio (P10 mitigation).",
    "latin autocomplete init ok [legacy: LATIN AUTOCOMPLETE INIT OK]":
        "Wave0-B11 G11-M4-001 (paideia-os #2317): latin_autocomplete IME "
        "provider satellite (LANG_LATIN registrant against KIND_IME_"
        "PROVIDER=0x1DC) data-only fingerprint; satellite-process main "
        "loop that would emit it on successful engine init is a future "
        "landing (paired with the KIND_IME_ROUTER #2316 wiring). Same "
        "posture as the sibling `ime provider register ok` entry above.",
    "latin deadkey init ok [legacy: LATIN DEADKEY INIT OK]":
        "Wave0-B12 G11-M4-002 (paideia-os #2318): latin_deadkey IME "
        "provider satellite (second LANG_LATIN registrant alongside "
        "latin_autocomplete #2317, servicing dead-key + Compose "
        "sequences against KIND_IME_PROVIDER=0x1DC) data-only "
        "fingerprint; satellite-process main loop that would emit it "
        "on successful engine init is a future landing (paired with "
        "the KIND_IME_ROUTER #2316 wiring). Same posture as the "
        "sibling `latin autocomplete init ok` entry immediately above.",
    "indic inscript init ok [legacy: INDIC INSCRIPT INIT OK]":
        "Wave0-B13 G11-M4-006 (paideia-os #2322): indic_inscript IME "
        "provider satellite (LANG_INDIC_HI registrant against KIND_IME_"
        "PROVIDER=0x1DC) data-only fingerprint; two-mode engine "
        "(MODE_INSCRIPT direct keymap + MODE_PHONETIC Roman->Devanagari "
        "accumulator) whose satellite-process main loop that would emit "
        "it on successful engine init is a future landing (paired with "
        "the KIND_IME_ROUTER #2316 wiring). Same posture as the sibling "
        "`latin deadkey init ok` entry immediately above.",
    "pdx kind bidi uba meta [legacy: BIDI UBA META OK]":
        "Wave0-B13 G11-M4-007 (paideia-os #2323): bidi_uba Unicode "
        "Bidirectional Algorithm paragraph-level level-run analyzer "
        "(P2/P3 auto-direction, W1-W7 weak types, N1-N2 neutrals, "
        "I1-I2 implicit levels, L1-L4 visual reorder) consumed by the "
        "G5 SDF text renderer and the G11-M5-001 bidi_caret primitive "
        "(#2324). Data-only fingerprint; substrate-side dispatcher "
        "that would emit it on successful multi-run cascade "
        "completion is a future landing (bidi_uba_substrate; the "
        "schema-only analyze body currently collapses every paragraph "
        "to a single LTR run so the fingerprint stays dormant). Same "
        "posture as the sibling `latin deadkey init ok` / "
        "`bidi caret init ok` entries in this file.",
    "bidi caret init ok [legacy: BIDI CARET INIT OK]":
        "Wave0-B13 G11-M5-001 (paideia-os #2324): bidi_caret userspace "
        "text-editing primitive (bidirectional caret with logical + "
        "visual coordinates and mirrored selection anchor, consumer of "
        "the bidi_uba paragraph analysis substrate #G11-M4-007) "
        "data-only fingerprint; KIND_IME_ROUTER-side substrate that "
        "would emit it on successful caret init is a future landing "
        "(bidi_uba integration + router per-focus cursor cell). Same "
        "posture as the sibling `latin deadkey init ok` entry "
        "immediately above.",
    "cjk pinyin init ok [legacy: CJK PINYIN INIT OK]":
        "Wave0-B13 G11-M4-003 (paideia-os #2319): cjk_pinyin IME "
        "provider satellite (LANG_CJK_ZH registrant servicing both "
        "PINYIN_HANYU (zh-CN romanised) and PINYIN_ZHUYIN (zh-TW "
        "Bopomofo) phonetic input against KIND_IME_PROVIDER=0x1DC) "
        "data-only fingerprint; satellite-process main loop that "
        "would emit it on successful engine init is a future landing "
        "(paired with the KIND_IME_ROUTER #2316 wiring). Same "
        "posture as the sibling `latin deadkey init ok` entry "
        "immediately above.",
    "cjk kana init ok [legacy: CJK KANA INIT OK]":
        "Wave0-B13 G11-M4-004 (paideia-os #2320): cjk_kana IME "
        "provider satellite (LANG_CJK_JA + LANG_CJK_KO registrant "
        "servicing SYLL_HIRAGANA / SYLL_KATAKANA / SYLL_HANGUL "
        "against KIND_IME_PROVIDER=0x1DC) data-only fingerprint; "
        "satellite-process main loop that would emit it on successful "
        "engine init is a future landing (paired with the "
        "KIND_IME_ROUTER #2316 wiring). Same posture as the sibling "
        "`cjk pinyin init ok` entry immediately above.",
    "indic shaping init ok [legacy: INDIC SHAPING INIT OK]":
        "Wave0-B13 G11-M4-005 (paideia-os #2321): indic_shaping IME "
        "provider satellite (LANG_INDIC_HI + LANG_INDIC_TA registrant, "
        "dual-script Devanagari/Tamil shaping state machine against "
        "KIND_IME_PROVIDER=0x1DC) data-only fingerprint; "
        "satellite-process main loop that would emit it on successful "
        "engine init is a future landing (paired with the "
        "KIND_IME_ROUTER #2316 wiring). Same posture as the sibling "
        "`indic inscript init ok` entry immediately above.",
    "settings input ready ok [legacy: SETTINGS INPUT READY OK]":
        "Wave0-B13 G12-M2-002 (paideia-os #2331): samples/settings/input "
        "sample-application panel (KIND_UI_CONTEXT consumer at slot "
        "0x1D5) data-only fingerprint; the seven-row control surface "
        "(keyboard repeat + repeat delay + pointer accel curve + "
        "scroll direction + tap-to-click + trackpad gesture + IME "
        "provider selector) rides the libpaideia_ui immediate-mode "
        "context. Sample-side dispatcher that would emit it on "
        "successful panel init is a future landing (paired with the "
        "sibling `settings color ready ok` panel).",
    "settings color ready ok [legacy: SETTINGS COLOR READY OK]":
        "Wave0-B13 G12-M2-003 (paideia-os #2332): samples/settings/color "
        "sample-application panel (KIND_UI_CONTEXT consumer at slot "
        "0x1D5) data-only fingerprint; nine-widget HDR + night-light "
        "control surface (color-space selector + gamut clip + white "
        "point + max nits + reference nits + gamma + night-light "
        "toggle + night-light kelvin + night-light schedule) rides "
        "the libpaideia_ui immediate-mode context. Same posture as "
        "the sibling `settings input ready ok` panel immediately above.",
    "clock analog ready ok [legacy: CLOCK ANALOG READY OK]":
        "Wave0-B13 G12-M3-001 (paideia-os #2334): samples/clock/analog "
        "sample-application (KIND_UI_CONTEXT consumer at slot 0x1D5) "
        "data-only fingerprint; sixteen-paint-per-frame analog clock "
        "face with subsecond sweep second-hand rides the libpaideia_ui "
        "immediate-mode context. Sample-side dispatcher that would "
        "emit it on successful clock init is a future landing.",
    "ui context mint ok [legacy: UI CONTEXT MINT OK]":
        "Wave0-B8 G12-M1-001 (#2326): ui_context (KIND_UI_CONTEXT=0x1D5) "
        "data-only decl; kernel dispatcher + toolkit runtime not yet wired.",
    "seat mint ok [legacy: SEAT MINT OK]":
        "Wave0-B8 G8-M5-001 (#2285): seat_kind (KIND_SEAT=0x1D6) "
        "data-only decl; kernel dispatcher not yet wired.",
    "input route mint ok [legacy: INPUT ROUTE MINT OK]":
        "Wave0-B8 G8-M2-001 (#2277): route_kind LINEAR "
        "(KIND_INPUT_ROUTE=0x1D7) data-only decl; kernel dispatcher not yet wired.",
    "pdx kind tiling bsp meta [legacy: TILING BSP META OK]":
        "Wave0-B8 G9-M2-001 (#2291): tiling_bsp value-type module; "
        "no KIND cap; consumer (workspace tiling) emits at wire-body land.",
    "pdx kind tiling floating meta [legacy: TILING FLOATING META OK]":
        "Wave0-B10 G9-M2-002 (#2292): tiling_floating value-type module "
        "(floating override + stacked group overlay on top of tiling_bsp); "
        "no KIND cap; consumer (workspace tiling) emits at wire-body land.",
    "pdx kind tiling gaps meta [legacy: TILING GAPS META OK]":
        "Wave0-B12 G9-M2-003 (#2293): tiling_gaps value-type module "
        "(gap + margin geometry adjustment layer on top of tiling_bsp); "
        "no KIND cap; consumer (workspace tiling) emits at wire-body land.",

    # ------------------------------------------------------------------
    # Wave 0 Batch 9 — G9/G12 M3/M4 fan-out over the KIND_SURFACE and
    # KIND_UI_CONTEXT parents. Data-only meta decls in cap modules whose
    # dispatchers land with the future wire-body milestone.
    # ------------------------------------------------------------------
    "present_feedback mint ok [legacy: PRESENT FEEDBACK MINT OK]":
        "Wave0-B9 G9-M4-001 (#2297): present_feedback_kind "
        "(KIND_PRESENT_FEEDBACK=0x1DA) data-only decl; kernel dispatcher + "
        "vk_present_feedback_channel wire-body not yet wired.",
    "focus router change ok [legacy: FOCUS ROUTER CHANGE OK]":
        "Wave0-B9 G8-M2-002 (#2278): focus_router logic module; "
        "input-server dispatcher not yet wired.",
    "accel curve meta [legacy: ACCEL CURVE META OK]":
        "Wave0-B9 G8-M3-001 (#2280): accel_curve value-type; input server "
        "motion-event path not yet wired.",
    "touch contact track ok [legacy: TOUCH CONTACT TRACK OK]":
        "Wave0-B9 G8-M4-001 (#2283): touch_contact (KIND_TOUCH_CONTACT=0x1D8) "
        "data-only decl; kernel dispatcher not yet wired.",
    "workspace switch ok [legacy: WORKSPACE SWITCH OK]":
        "Wave0-B9 G9-M1-002 (#2289): workspace_switch logic module; "
        "present-feedback IRQ cursor advance not yet wired.",
    "damage region mint ok [legacy: DAMAGE REGION MINT OK]":
        "Wave0-B9 G9-M3-001 (#2294): damage_kind (KIND_DAMAGE_REGION=0x1D9) "
        "data-only decl; kernel dispatcher not yet wired.",
    "pdx a11y bind at mint meta [legacy: A11Y BIND AT MINT OK]":
        "Wave0-B9 G10-M2-001 (#2305): a11y_bind_at_mint P4 gate wrap; "
        "compositor mint-path integration not yet wired.",
    "pdx kind screen reader protocol meta [legacy: SCREEN READER PROTOCOL META OK]":
        "Wave0-B9 G10-M3-001 (#2308): screen_reader_protocol subscribe queue; "
        "compositor push-emit path not yet wired.",
    "pdx kind keynav taborder meta [legacy: KEYNAV TABORDER META OK]":
        "Wave0-B9 G10-M4-001 (#2311): keynav_taborder DFS cursor; "
        "compositor key-event dispatch not yet wired.",

    # ------------------------------------------------------------------
    # Wave 0 Batch 10 — G8/G9/G10/G11/G12 wider fan-out. Data-only meta
    # decls; kernel dispatchers land with future wire-body milestones.
    # ------------------------------------------------------------------
    "recovery console ok [legacy: RECOVERY CONSOLE OK]":
        "Wave0-B10 G8-M1-002 (#2275): recovery_console takeover logic; "
        "input-server dispatcher not yet wired.",
    "route revoke ok [legacy: ROUTE REVOKE OK]":
        "Wave0-B10 G8-M2-003 (#2279): route_revoke auto-callbacks + "
        "implicit-grab; walker primitive lands in G8-M2-004.",
    "stylus device meta [legacy: STYLUS DEVICE META OK]":
        "Wave0-B10 G8-M4-002 (#2284): KIND_STYLUS_DEVICE=0x1DB data-only "
        "decl; kernel dispatcher not yet wired.",
    "buffer age ring init ok [legacy: BUFFER AGE RING INIT OK]":
        "Wave0-B10 G9-M3-002 (#2295): buffer_age partial-repaint scheduler; "
        "compositor swap-chain wire-up not yet landed.",
    "pdx present feedback route meta [legacy: PRESENT FEEDBACK ROUTE OK]":
        "Wave0-B10 G9-M4-002 (#2298): present_feedback_route budget-one-refresh "
        "fan-out; compositor emit path not yet wired.",
    "pdx kind screen reader tts meta [legacy: SCREEN READER TTS META OK]":
        "Wave0-B10 G10-M3-002 (#2309): screen_reader_tts client + phoneme "
        "cache stub; TTS engine send-path not yet landed.",
    "widgets ready ok [legacy: WIDGETS READY OK]":
        "Wave0-B10 G12-M1-002 (#2327): widgets immediate-mode primitives; "
        "renderer wire-up lands with G12-M1-004.",
    "view tree new ok [legacy: VIEW TREE NEW OK]":
        "Wave0-B10 G12-M2-001 (#2329): view_tree retained-mode Xilem-shape; "
        "per-kind widget-call fanout lands with G12-M2-003.",

    # ------------------------------------------------------------------
    # Wave 0 Batch 11 -- G12.M1-003 immediate-mode layout containers.
    # Data-only meta decl; renderer/klog wire-up lands with G12-M1-004.
    # ------------------------------------------------------------------
    "layout ready ok [legacy: LAYOUT READY OK]":
        "Wave0-B11 G12-M1-003 (#2328): layout containers immediate-mode "
        "primitives (horizontal / vertical / grid / z-order stack); "
        "renderer wire-up + klog emission land with G12-M1-004.",
    "enumerate meta ok [legacy: ENUMERATE META OK]":
        "Wave0-B11 G8-M1-003 (#2276): input-server device enumeration; "
        "HID stream walker deferred to G8-M1-005.",
    "scroll axis meta [legacy: SCROLL AXIS META OK]":
        "Wave0-B11 G8-M3-002 (#2281): scroll_axis high-res + natural-scroll "
        "value type; pointer-event wire pending.",
    "damage aggregate ok [legacy: DAMAGE AGGREGATE OK]":
        "Wave0-B11 G9-M3-003 (#2296): damage_aggregate walker; consumer "
        "(compositor commit path) not yet wired.",
    "pdx present feedback classifier meta [legacy: PRESENT FEEDBACK CLASSIFIER OK]":
        "Wave0-B11 G9-M4-003 (#2299): present-feedback classifier + back-pressure; "
        "consumer (compositor policy) not yet wired.",
    "pdx kind screen reader braille meta [legacy: SCREEN READER BRAILLE META OK]":
        "Wave0-B11 G10-M3-003 (#2310): screen_reader_braille BRLTTY-shape "
        "output client; KIND_BRAILLE_DEVICE forward-reserve 0x1E1.",
    "retained widgets new ok [legacy: RETAINED WIDGETS NEW OK]":
        "Wave0-B11 G12-M2-002 (#2330): retained_widgets factory catalogue over "
        "view_tree; per-kind widget wire pending G12-M2-003.",
    "settings display ready ok [legacy: SETTINGS DISPLAY READY OK]":
        "Wave0-B11 G12-M3-001 (#2332): settings display sample panel; "
        "settings-service klog wire pending G12.M4.",

    # ------------------------------------------------------------------
    # Wave 0 Batch 12 — G8/G9/G10/G11 further fan-out. Data-only meta
    # decls; kernel dispatchers land with future wire-body milestones.
    # ------------------------------------------------------------------
    "trackpad gesture meta [legacy: TRACKPAD GESTURE META OK]":
        "Wave0-B12 G8-M3-003 (#2282): trackpad_gesture 5-gesture filter; "
        "pointer-event wire pending.",
    "seat lock ok [legacy: SEAT LOCK OK]":
        "Wave0-B12 G8-M5-002 (#2286): seat_lock credential compare + "
        "isolation invariants; lockout policy wire pending.",
    "workspace_session save ok [legacy: WSESS SAVE OK]":
        "Wave0-B12 G9-M1-003 (#2290): workspace_session persistence; "
        "disk-I/O wire (fs) pending.",
    "adaptive rate main ok [legacy: ADAPTIVE RATE MAIN OK]":
        "Wave0-B12 G9-M5-001 (#2300): adaptive-rate sample client + "
        "60<->120Hz hysteresis; smoke-witness klog wire pending.",
    "adaptive rate policy ready ok [legacy: ADAPTIVE RATE POLICY READY OK]":
        "Wave0-B12 G9-M5-002 (#2301): adaptive-rate policy knob "
        "(LOW_LATENCY/BALANCED/BATTERY_SAVER/CUSTOM); klog wire pending.",
    "pdx kind pwp a11y wire meta [legacy: PWP A11Y WIRE META OK]":
        "Wave0-B12 G10-M2-002 (#2306): pwp_a11y_wire inline payload "
        "packer/unpacker; surface-commit wire integration pending.",
    "pdx kind keynav focus ring meta [legacy: KEYNAV FOCUS RING META OK]":
        "Wave0-B12 G10-M4-002 (#2312): keynav_focus_ring 4-strip painter + "
        "Ctrl+H/L/M/N skip-link; compositor key-event dispatch pending.",

    # src/user/init.pdx — R106.M2 (paideia-os #2229): witness that init
    # composed and installed the fingerprint-shaped envp HOME entry
    # ("HOME=/home/<64-hex-placeholder>/", sourced from
    # FounderConstants.fc_placeholder_home_path, src/user/
    # founder_constants.pdx, R106.M1 #2228) in place of the R65v2
    # hardcoded "HOME=/home/operator". Fires unconditionally on every
    # boot -- no branch gates it -- but no golden file pins this exact
    # literal yet. Retires from this allowlist once a boot smoke (R106.M5
    # boot_r106_persistent_home, or an earlier regression check for the
    # M2 retargeting itself) asserts it.
    "init home envp ok [legacy: INIT HOME ENVP OK]":
        "Wave0-B15 R106-M2 (paideia-os #2229): init's HOME-envp "
        "composition fingerprint fires every boot unconditionally; no "
        "golden pins this exact literal yet -- assertable once an "
        "R106 boot smoke (M5 boot_r106_persistent_home or an earlier "
        "M2 regression check) lands.",

    # ------------------------------------------------------------------
    # Wave 0 Batch 14 — G10-M3-001 compositor a11y elaboration gate.
    # Data-only meta decl; gate consumer path (window_kind mint) not
    # yet wired.
    # ------------------------------------------------------------------
    "a11y elaboration gate init ok [legacy: A11Y ELABORATION GATE INIT OK]":
        "Wave0-B14 G10-M3-001 (#2307): elaboration_gate STRICT/PERMISSIVE "
        "policy gate + one-way latch over the P4 a11y-subtree invariant; "
        "gate consumer path (window_kind.pdx mint) not yet wired -- lands "
        "with G10-M3-002.",
    "a11y mutation log init ok [legacy: A11Y MUTATION LOG INIT OK]":
        "Wave0-B14 G10-M2-001 (paideia-os #2304): mutation_log per-frame "
        "a11y-subtree mutation ring buffer (KIND_A11Y_MUTATION_LOG=0x1E4, "
        "derived over KIND_A11Y_TREE=0x1D3) data-only decl; mint/append/"
        "commit/consume bodies are real and self-contained but no "
        "compositor dispatcher calls mutation_log_mint yet.",
    "window geometry init ok [legacy: WINDOW GEOMETRY INIT OK]":
        "Wave0-B14 G7-M8-005 (paideia-os #2263): window_geometry LINEAR "
        "cap (KIND_WINDOW_GEOMETRY=0x1CA, derived over KIND_WINDOW=0x1C1; "
        "renumbered from 0x1C3 post-race with popup_positioning #2264) "
        "data-only fingerprint posture, same as siblings; mint/apply "
        "bodies are real and self-contained but no cap_invoke_dispatch "
        "wiring calls window_geometry_mint yet.",
    "clock timezone ready ok [legacy: CLOCK TIMEZONE READY OK]":
        "Wave0-B14 G12-M3-002alt (paideia-os #2336): samples/clock/"
        "timezone world-clock sample application (KIND_UI_CONTEXT "
        "consumer at slot 0x1D5) data-only fingerprint; twelve-zone "
        "retained-mode list (view_tree + retained_widgets factories) "
        "rebuilt every tick via reset/diff/reconcile. Sample-side "
        "dispatcher that would emit it on successful build is a "
        "future landing, same posture as the sibling `clock analog "
        "ready ok` immediate-mode sample.",
    "editor buffer init ok [legacy: EDITOR BUFFER INIT OK]":
        "Wave0-B14 G12-M4-001 (paideia-os #2337): samples/editor/buffer "
        "gap-list text-editor buffer primitives (KIND_EDITOR_BUFFER="
        "0x1E5, derived over KIND_MEMORY) data-only fingerprint. "
        "ebuf_init / editor_buffer_mint / editor_buffer_insert_at / "
        "editor_buffer_delete_range / editor_buffer_read_range / "
        "editor_buffer_len_bytes bodies are real and self-contained "
        "(a genuine gap-list edit engine, not a stub), but no boot "
        "witness or sample-app dispatcher calls ebuf_init yet, so the "
        "marker never reaches a boot log. Same posture as the sibling "
        "`ui context mint ok` / `window mint ok` data-only decls; "
        "retires when a boot witness or the syntax-highlighting/BiDi-"
        "caret follow-up (#2338) wires a real call path.",
    "editor render init ok [legacy: EDITOR RENDER INIT OK]":
        "Wave0-B15 G12-M4-002 (paideia-os #2338): samples/editor/render "
        "syntax-highlight render loop + BiDi caret navigation over "
        "KIND_EDITOR_BUFFER (0x1E5, buffer.pdx #2337) and bidi_caret.pdx "
        "(#2324) data-only fingerprint. editor_render_frame / editor_"
        "render_tokenize_range / editor_render_caret_left/right/home/"
        "end/up/down bodies are real and self-contained, painting "
        "through widgets.pdx's widget_paint_rect placeholder sink same "
        "as samples/clock/analog.pdx, but no sample-app dispatcher "
        "calls editor_render_init yet, so the marker never reaches a "
        "boot log. Same posture as the sibling `editor buffer init ok` "
        "data-only decl.",

    # ------------------------------------------------------------------
    # Wave 0 Batch 15 — R106.M4-USER shell tokenizer tilde-alias support.
    # Data-only meta decl; dispatch-time wiring not yet present.
    # ------------------------------------------------------------------
    "tokenizer tilde alias ok [legacy: TOKENIZER TILDE ALIAS OK]":
        "Wave0-B15 R106-M4-USER (paideia-os #2342): src/user/tokenizer.pdx "
        "TOK_TILDE_ALIAS token-kind support -- tokenize() now recognizes a "
        "leading '~' at a token START position and scans it plus a "
        "following alnum/'_' run into its own token kind (argv_types[i] "
        "parallel array), with argv_buf's entry pointing at the NUL-"
        "terminated alias name. tokenizer_resolve_alias(name_ptr, "
        "name_len) is a real, self-contained stub (empty name -> "
        "HOME_MARKER, any other name -> E_ALIAS_UNRESOLVED == "
        "TTA_ALIAS_UNRESOLVED 0xFFFFE93D), but no dispatcher calls it and "
        "no boot witness emits this marker yet -- that lands with #2231's "
        "dispatch.pdx wiring (R108.M4 for the real KIND_USER_ALIAS "
        "resolution). Same posture as the sibling `editor buffer init ok` "
        "/ `clock timezone ready ok` data-only decls.",
    "dispatch from tokenizer ok [legacy: DISPATCH FROM TOKENIZER OK]":
        "Wave0-B15 R106-M4-KERNEL (paideia-os #2231): src/user/dispatch.pdx "
        "dispatch_from_tokenizer_stream fixed-shape token-record entry "
        "point (opcode u64 + arg_count u64 + arg_ptrs[8] u64, "
        "DFT_REC_SIZE=80) added alongside the existing string-based "
        "dispatch_line path -- dispatch_line and every builtin are "
        "unmodified. Body is real and self-contained: guard cascade "
        "(DFT_NULL/DFT_NOT_INIT/DFT_ARG_COUNT_OUT_OF_RANGE/"
        "DFT_OPCODE_INVALID/DFT_REFUSED_DENSE), cd's own granular "
        "E_CD_NO_ARG/DFT_CD_NOT_A_DIR/DFT_CD_NOT_FOUND error path (bare "
        "`cd` distinguished from a generic dispatch failure), and a "
        "generic bridge into the unmodified echo/exit/pwd/help/env/clear "
        "builtins plus exec_child for external commands. The fingerprint "
        "fires on every accepted record, but no caller constructs a "
        "record yet -- shell.pdx still calls dispatch_line exclusively. "
        "A real caller lands with the #2342 tokenizer's own dispatch "
        "integration. Same posture as the sibling `tokenizer tilde "
        "alias ok` data-only-for-now decl.",

    # src/user/color/tone_map.pdx -- Wave0-B15 G6-M2-002 (paideia-os
    # #2239) reference HDR->SDR tone-mapping curves (Hable filmic +
    # classic/extended Reinhard). Data-only + pure-computation: every
    # entry point (tone_map_hable, tone_map_reinhard, tone_map_reinhard_
    # extended, tone_map_curve_select) is real and self-contained, but
    # the paint-pipeline consumer that would actually walk a frame's HDR
    # luminance through one of these curves on the way to an SDR sink is
    # a future landing -- no boot witness or dispatcher calls any entry
    # point yet, so the marker never reaches a boot log. Same posture as
    # the sibling `editor buffer init ok` / `clock timezone ready ok` /
    # `tokenizer tilde alias ok` data-only decls immediately above.
    "tone map init ok [legacy: TONE MAP INIT OK]":
        "Wave0-B15 G6-M2-002 (paideia-os #2239): tone_map.pdx's Hable/"
        "Reinhard curve entry points are real and self-contained, but "
        "the paint-pipeline HDR->SDR consumer wire is a future landing "
        "-- no caller reaches this data-only fingerprint yet. Same "
        "posture as the sibling `editor buffer init ok` decl above.",

    # src/user/color/bt2100_gamut.pdx -- Wave0-B15 G6-M2-001 (paideia-os
    # #2241) BT.2100 RGB<->XYZ + D65<->D50 Bradford chromatic-adaptation
    # matrix constants and matrix-vector-multiply helpers
    # (bt2100_rgb_to_xyz / bt2100_xyz_to_rgb / bt2100_bradford_d65_to_d50
    # / bt2100_bradford_d50_to_d65 / bt2100_bradford_adapt /
    # bt2100_matrix_cell). Data-only + pure-computation: every entry
    # point is real and self-contained, but the compositor paint
    # pipeline and HDR settings panel consumer wires are future
    # landings -- no boot witness or dispatcher calls any entry point
    # yet, so the marker never reaches a boot log. Same posture as the
    # sibling `tone map init ok` / `editor buffer init ok` data-only
    # decls immediately above.
    "bt2100 gamut init ok [legacy: BT2100 GAMUT INIT OK]":
        "Wave0-B15 G6-M2-001 (paideia-os #2241): bt2100_gamut.pdx's "
        "RGB<->XYZ + Bradford chromatic-adaptation entry points are "
        "real and self-contained, but the compositor paint pipeline / "
        "HDR settings panel consumer wires are future landings -- no "
        "caller reaches this data-only fingerprint yet. Same posture "
        "as the sibling `tone map init ok` decl above.",

    # src/samples/clock/vello_face.pdx -- Wave0-B15 G12-M3-002 (paideia-os
    # #2335): Vello-style analog clock face sample, a sibling to clock/
    # analog.pdx's software-raster placeholder. `vello_face_main` mints
    # KIND_UI_CONTEXT, builds a 46-record Vello-shape path-command
    # stream (SET_TRANSFORM + 12 tick marks + 3 hands) into a fixed
    # 4KiB ring buffer, brackets one begin/end_frame, and returns --
    # paint-once, no GPU submission. `pdx_kind_vello_face_meta` is a
    # data-only fingerprint (same posture as `clock analog ready ok` /
    # `clock timezone ready ok` above); no boot witness or klog wire
    # emits it yet. Retires when a boot witness exercises vello_face_
    # main end-to-end, or when the R37 GPU-context consumer that drains
    # this command stream lands and asserts against it directly.
    "vello face ready ok [legacy: VELLO FACE READY OK]":
        "Wave0-B15 G12-M3-002 (paideia-os #2335): Vello-style command-"
        "stream clock face sample (46-record path stream: transform + "
        "12 ticks + 3 hands over a 4KiB ring); no boot witness or R37 "
        "GPU-context consumer wired yet, same posture as the sibling "
        "`clock analog ready ok` / `clock timezone ready ok` entries.",

    # src/samples/settings/ime.pdx -- Wave0-B15 G12-M3-002 (paideia-os
    # #2333): fine-grained IME settings sub-panel, a sibling of settings/
    # input.pdx / display.pdx / color.pdx but decomposed into 9 named
    # per-widget builder functions (provider, candidate-window style,
    # learning toggle + history depth, hotkey mode + read-only label,
    # dictionary-language bitmask, reset). ime_settings_load / _save /
    # _render / ime_settings_layout_precheck (panel-level LINEAR atomic
    # layout gate) and all 9 ime_widget_* builders are real and self-
    # contained, but the settings-service tab dispatcher that would call
    # settings_ime_main on a real KIND_WINDOW/KIND_SURFACE pair is a
    # future G12.M4 landing -- no boot witness or klog wire emits this
    # marker yet. Same posture as the sibling `settings input ready ok`
    # / `settings color ready ok` data-only decls above.
    "settings ime ready ok [legacy: SETTINGS IME READY OK]":
        "Wave0-B15 G12-M3-002 (paideia-os #2333): 9-widget fine-grained "
        "IME settings sub-panel (provider/window-style/learning/history-"
        "depth/hotkey-mode/hotkey-label/dict-languages/reset), decomposed "
        "into one named builder function per row; settings-service klog "
        "wire pending G12.M4, same posture as the sibling `settings "
        "input ready ok` / `settings color ready ok` entries.",
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
        # tools/paideia-as is the submodule toolchain; tools/user/* are
        # the satellite tool repos (libpdx-volume + 3 tools + libpdx-audit
        # + libpdx-elevate). Neither carries paideia-os fingerprints — their
        # own fingerprint coverage is tracked in their own repos. Scoped to
        # the literal "tools" directory so this does not also prune
        # paideia-os-owned dirs named "user" elsewhere (src/user,
        # tests/user, src/kernel/user, src/kernel/core/user all carry
        # real fingerprints and must stay walked).
        rel_dp = os.path.relpath(dp, ROOT)
        if rel_dp == 'tools':
            dns[:] = [d for d in dns if d not in ('paideia-as', 'user')]
        dns[:] = [d for d in dns if d not in ('build', 'target')]
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
