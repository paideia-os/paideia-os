// SPDX-License-Identifier: MIT
# ESP Layout — T14 boot wave M6 firmware bundling

**Status:** Draft v0.1 (R111.M6-022, paideia-os #2374 — 2026-09-07).
**Scope:** Canonical on-ESP directory + file layout that the UEFI stub
(`src/boot/uefi_stub.pdx`), the R111.M7-025 image builder
(`tools/mkimage.sh`), and the kernel-side blob loader (R111.M6-022+ —
`src/kernel/core/driver/blob_load.pdx`) all agree on.  Freezes the
boot-time surface: paths, per-file semantics, provenance discipline,
and the two `boot_env_t` slots the UEFI stub uses to carry the
firmware manifest across ExitBootServices.
**Authorities cited:**
- `design/roadmap/t14-bootable-usb-wave.md` §4.F (R111.M6-020..024
  sub-wave — the umbrella narrative for the firmware bundling wave).
- `design/drivers/blob-policy.md` §0..§1 (dual-signature trust model,
  per-driver IOMMU domain, blob-audit posture; the parent policy the
  manifest attests to).
- `design/security/pq-trust-root.md` §0.2 (ML-DSA-65 for release-
  signed artifacts — the manifest's future signature algorithm).
- `src/boot/uefi_env.pdx` (the `boot_env_t` layout the two new
  `+120 / +128` slots extend).
- `src/boot/uefi_stub.pdx` §efi_load_initrd (the SFS+Open+Read
  pattern this milestone parallels for the manifest load).
- `src/kernel/boot/witness/rootfs_mount_witness.pdx` (the mirror
  witness pattern for the manifest witness).

---

## 0. Executive summary

Every T14 G4 boot needs three classes of firmware on the ESP: an
Intel-microcode blob matching the boot CPU's family+model+stepping,
the Iris Xe GuC/HuC pair, and a manifest tying them together so the
kernel-side loader can (a) know what to look for and (b) verify what
it found.  This document freezes the on-ESP layout, the manifest
schema, and the two `boot_env_t` slots that the UEFI stub uses to
hand the manifest across ExitBootServices.

The layout is **read-only** from the OS's perspective — the ESP is a
FAT32 volume the firmware also reads (to find `\EFI\BOOT\BOOTX64.EFI`)
and neither the UEFI stub nor the kernel ever writes to it.  All
mutations happen at image-build time in `tools/mkimage.sh`
(R111.M7-025), which is the only tool authorized to populate
`/paideia/firmware/**`.

The manifest itself lands as `/paideia/firmware/manifest.pdxsig`.
The UEFI stub loads it into an `EfiLoaderData` pool alloc pre-EBS via
the same `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL` chain that
`efi_load_initrd` uses for the rootfs blob, latches
`(pool_pa, file_size)` into two new `boot_env_t` slots at `+120` /
`+128`, and the kernel-side witness
(`src/kernel/boot/witness/fw_manifest_witness.pdx`, added in this
milestone) emits `FW MANIFEST OK pa=0x<pa> size=<n>` or
`FW MANIFEST NONE` at every boot.  The actual manifest **parsing +
signature verification + per-blob load** happens later in
R111.M6-023/024/M7-025; this milestone is scope-capped to layout +
carry + fingerprint, so a downstream driver landing has nothing to
prove about "does the file reach kernel bytes".

Provenance discipline: blob bytes are **not** committed to the
paideia-os monorepo (Intel license terms forbid it).  `mkimage.sh`
takes them from an operator-supplied `--firmware-dir=<path>` and
stages them onto the ESP per this document.

---

## 1. Directory + file layout

The complete on-ESP tree the image builder produces:

```
/EFI/BOOT/BOOTX64.EFI               <- paideia bootloader (uefi_stub.pdx PE emit)
/EFI/PAIDEIA/
    kernel.elf                       <- paideia-os kernel (KERNEL_PHYS_BASE = 0x100000)
    rootfs.pdxfs                     <- R111.M3-013 (paideia-os #2365) rootfs blob
/paideia/firmware/
    microcode/
        06-b7-01.bin                 <- Intel Raptor Lake-U B0 (CPUID 0x0A06B7,
                                        matching Skylake+ microcode filename
                                        convention <family>-<model>-<stepping>.bin)
    gpu/
        guc_70.bin                   <- Iris Xe Gen12.2 GuC firmware (rev 70)
        huc_16.bin                   <- Iris Xe Gen12.2 HuC firmware (rev 16)
    manifest.pdxsig                  <- signed hash chain (this milestone: carry
                                        + witness only; parse + verify at
                                        R111.M6-023)
```

Rationale for the split between `/EFI/PAIDEIA/` and
`/paideia/firmware/`:

- **`/EFI/PAIDEIA/`** carries the bootloader-facing artifacts the
  UEFI stub loads by fixed path.  The `/EFI/*/` convention is what
  UEFI firmware itself understands and what `\EFI\BOOT\BOOTX64.EFI`
  will find via `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL` on the same volume
  handle the firmware launched us from.  Both `kernel.elf` and
  `rootfs.pdxfs` live here because the UEFI stub loads them under
  identical open-and-read discipline.

- **`/paideia/firmware/`** is a lowercase paideia-native tree that
  sits under the volume root, outside the `/EFI/` reserved space
  (UEFI 2.10 §13.3 reserves `/EFI/` for firmware + bootloader
  artefacts).  The manifest + blobs live here because they are
  **kernel-facing** payloads — the UEFI stub only loads the
  manifest as a bootstrap for the kernel's later
  `blob_load.pdx` traversal (R111.M6-022).  Keeping the two trees
  separate keeps the `/EFI/PAIDEIA/` handoff surface small (three
  files: bootloader + kernel + rootfs) and lets the firmware tree
  grow without threatening those three.

Filename conventions:

- **Microcode:** `<family>-<model>-<stepping>.bin` per the Intel
  microcode-update file naming used by every Linux distribution's
  `intel-ucode` package.  The kernel-side loader matches the running
  CPU's `CPUID(1) EAX` masked to family+model+stepping against the
  filename before applying (SDM Vol 3A §9.11.1 header validation
  gates the actual apply).  Multiple microcode blobs may coexist in
  the directory; the loader picks the one whose name matches.

- **GPU firmware (GuC / HuC):** `<kind>_<rev>.bin` where `<kind>` is
  `guc` or `huc` and `<rev>` is the two-digit vendor revision.
  Multiple revisions may coexist; the loader picks the highest-rev
  compatible file.  Naming intentionally omits the PCI-ID prefix
  from the R111.M6-020 initial sketch: revision alone is enough
  because the driver only opens the file after PCI-ID probe has
  already selected an Iris Xe scanout registry entry, so there is no
  cross-vendor ambiguity to disambiguate.

The naming is **case-preserving** and lowercase on the ESP.  FAT32
short-name aliasing is not relied on (UEFI 2.10 firmware supports
long filenames per §13.5), but the lowercase convention keeps the
paths portable to `mkfs.vfat` outputs that some Linux distributions
sanitize differently.

---

## 2. Manifest format (`manifest.pdxsig`)

**Status update (R111.M6-023, paideia-os #2375, 2026-09-07):** the
concrete on-wire binary schema is now frozen at
`src/kernel/core/fw/loader.pdx`'s file-header MANIFEST BINARY FORMAT
narrative (16-byte header + N x 32B entries + 64-byte Ed25519
signature trailer).  §2.1 below records the wire-visible facts; the
whole-manifest signature-verify seam lands in
`src/kernel/core/fw/manifest_sig.pdx` as
`fw_manifest_verify_signature`, and the loader's gate 5.5 refuses to
dispatch a single entry when it fails.  Under R111.M6-023 the
verifier body is a dev-bypass accepting iff the 64-byte trailer is
bytewise all zero (matching pdxfs_lite/verify.pdx's
pdxfs_sb_verify_sig precedent, R25.M5-001); the R32/R82 landing
replaces that body with real Ed25519 verification against the
kernel-embedded trust-root pubkey
(`fw_manifest_trust_root_pubkey`, all-zero placeholder at R111).

### 2.1 On-wire binary layout (R111.M6-023, frozen)

```
Offset (from manifest_pa)         Size    Field
---------------------------------------------------------------
+0                                16      header:
                                            +0  u32 magic       = 0x464D4450 ('P','D','M','F')
                                            +4  u32 version     = 1
                                            +8  u32 entry_count = N
                                            +12 u32 reserved    = 0
+16                               N * 32  entry table (each entry):
                                            +0  u32 kind       (1=microcode, 2=GuC, 3=HuC)
                                            +4  u32 offset     (blob start, relative to manifest_pa)
                                            +8  u32 size       (blob length in bytes)
                                            +12 u8[20] sha256   (leading 20 bytes of SHA-256(blob_body))
+16 + N * 32                      64      Ed25519 signature over bytes [0, +16 + N * 32).
                                            The signature covers the header + entry
                                            table; per-entry SHA256 fields cover the
                                            blob bodies.  Producer:
                                            tools/mkimage.sh (R111.M7-025).
                                            Consumer: fw_manifest_verify_signature
                                            (src/kernel/core/fw/manifest_sig.pdx).
```

**Total manifest size:** `16 + N * 32 + 64` bytes plus the blob
bodies referenced by each entry.offset (which live INSIDE the same
pool alloc, per file layout).  The loader's gate 5 refuses the
manifest if `manifest_size < 16 + N * 32 + 64`; gate 5.5 then runs
`fw_manifest_verify_signature`.

**Trust root:** the kernel embeds `fw_manifest_trust_root_pubkey`
as a 32-byte array (Ed25519 pubkey length per RFC 8032 §5.1.5).  At
R111 the array is all zeros -- this pairs one-for-one with the
dev-bypass accept-all-zero-sig posture: a manifest whose 64-byte sig
trailer AND whose trust-root pubkey are both all-zero passes; a
tamper of either half (real Ed25519 sig with all-zero pubkey, or
non-zero pubkey with all-zero sig) trips the reject.  R32/R82 lands
the real release-line signing pubkey here; the dev-bypass path in
`fw_manifest_verify_signature` drops in the same commit.

**Rationale for hardcoded-in-kernel:** the trust root MUST resist
firmware-time or bootloader-time swap.  A boot_env slot would let a
compromised UEFI stub substitute a pubkey the attacker controls; a
hardcoded array is fixed at kernel-image sign time and inherits the
R28 kernel-image sig-verify (`src/kernel/boot/verify_self.pdx`) as
its own root of trust.  See design/security/secure-boot.md §3 "no
lateral trust escalation" rule.

**Boot policy on sig verify FAIL:** the loader emits `FW MANIFEST
SIG FAIL reason=<FW_SIG_FAIL_*>` and then the umbrella `FW LOAD SKIP
kind=0 reason=10 (FW_SKIP_SIG_FAIL)`, and returns without
dispatching any entry.  This matches design/security/no-silent-
fallback.md's fail-loud rule: a tampered or unsigned manifest gets
no firmware loaded, not "signature failed but we loaded it anyway."

### 2.2 Scope note (R111.M6-022 origin, superseded by §2.1)

The R111.M6-022 landing carried the manifest across boot with the
concrete schema deferred; this section records what that milestone
froze, retained here for historical continuity and for any operator
inspecting an older ESP.  What it fixed (path, container, payload
semantics sketch) still holds; the concrete binary layout is now in
§2.1.

- **Path:** `/paideia/firmware/manifest.pdxsig`.  Case-sensitive
  match by the UEFI stub's `L"\paideia\firmware\manifest.pdxsig"`
  path literal (see §4).  A future rename would break every
  already-staged ESP; this path is now load-bearing.

- **Container:** the paideia signed-artefact format (`.pdxsig`), same
  envelope shape that R32/R82 will use for tool packages and boot
  chain: `SHA3-256(hash-of-payload) || ML-DSA-65(signature-over-hash)
  || payload-bytes`.  Concrete byte layout is deferred to R111.M6-023;
  the extension is fixed **now** so `mkimage.sh` and the UEFI stub
  and any operator inspecting the ESP all agree on the file name.

- **Payload semantics:** one line per blob under `/paideia/firmware/`,
  each carrying `<sha3-256-hex> <path-relative-to-ESP> <length-bytes>`
  (following the roadmap §4.F sketch, upgraded from SHA-256 to
  SHA3-256 to match the PQ trust root's hash-family choice per
  `design/security/pq-trust-root.md` §0.2).

- **Signing:** deferred to R111.M6-023.  R111.M6-022 (this landing)
  carries an unsigned manifest.  The UEFI stub does not parse it —
  it only loads the bytes and hands them across.  A tampered
  manifest at R111.M6-022 produces the same `FW MANIFEST OK` witness
  as a well-formed one; downstream mount + verify arms are the
  authorities.

R111 ships without functional signature verification (per the
`design/security/pe-secure-boot-signing.md` posture — Secure Boot
signing lands at R32/R82).  The manifest itself is unsigned in R111
and tamper-detectable only via the surrounding `verify_self` chain
once R82 lands.  Downstream milestones (R111.M6-023 for microcode,
R111.M6-024 for GPU firmware) enforce that the loader **refuses to
boot** if a required blob is not present in the manifest — matching
the `design/security/no-silent-fallback.md` no-quiet-degrade rule.

---

## 3. boot_env_t slots — `+120` / `+128`

Two new `u64` slots extend the `boot_env_t` reserved tail that
R111.M3-013 (paideia-os #2365) already partially consumed for the
rootfs blob at `+104` / `+112`:

```
boot_env_t layout (256 B, 32-byte aligned) — updated for R111.M6-022:

  offset  size  name                       producer
  ------  ----  -------------------------  ---------------------------
  +0      8     magic                      const 0x564E454244494150
  +8      4     version                    const 1
  +12     4     _pad                       const 0
  +16    32     fb (fb_desc_t)             R19.M3-002 efi_gop_capture
  +48     8     rsdp_pa                    R19.M3-003 efi_find_rsdp
  +56     8     image_base                 R19.M3-005 efi_get_loaded_image
  +64     8     image_size                 R19.M3-005 efi_get_loaded_image
  +72     8     efi_memmap_pa              R19.M4 finalizer (buffer VA=PA)
  +80     8     efi_memmap_size            R19.M2-003 efi_get_memory_map
  +88     4     efi_memmap_desc_size       R19.M2-003 efi_get_memory_map
  +92     4     efi_memmap_desc_ver        R19.M2-003 efi_get_memory_map
  +96     8     runtime_services_pa        R19.M4 finalizer ([ST+88])
  +104    8     initrd_pa                  R111.M3-013 efi_load_initrd    <- was reserved
  +112    8     initrd_size                R111.M3-013 efi_load_initrd    <- was reserved
  +120    8     fw_manifest_pa             R111.M6-022 efi_load_fw_manifest  <- NEW
  +128    8     fw_manifest_size           R111.M6-022 efi_load_fw_manifest  <- NEW
  +136  120     _reserved                  future R111+ additions            <- was 136 B
                                                                                @ +120
```

**Alignment:** every field is naturally aligned within the 32-byte
alignment guarantee.  The two new `u64` slots at `+120` and `+128`
extend the R111.M3-013 pattern of carving from the reserved tail
front — total struct size stays 256 B, and the reserved tail shrinks
from 136 B @ +120 (post-M3-013) to 120 B @ +136 (post-M6-022).

**Producer discipline:** `efi_load_fw_manifest` runs in `efi_main`
between `efi_load_initrd` and `efi_tcg2_measure_kernel`.  On success
it latches `(pool_pa, file_size)` into the two module-level
scratches `_efi_fw_manifest_pa` / `_efi_fw_manifest_size` and the
Phase-1 finalizer copies them into `_boot_env` at `+120` / `+128`
alongside the M3-013 initrd slots.  On any failure (no SFS on the
device handle, path missing, `GetInfo` refused, `AllocatePool`
refused, short read) the two scratches stay at `.bss` zero and the
finalizer stores zeros — the kernel-side witness then emits
`FW MANIFEST NONE`.

**Zero-means-none invariant:** every consumer (the kernel-side
witness at this landing, the R111.M6-023 microcode WRMSR path, the
R111.M6-024 GPU staging path) reads `boot_env->fw_manifest_pa` first
and treats a zero as "no manifest was loaded", preserving the pre-
R111 no-firmware behavior on every boot mode where the ESP does not
carry a manifest (or where the load chain broke).  This matches the
same invariant `initrd_pa` established at R111.M3-013.

---

## 4. UEFI stub load path

`efi_load_fw_manifest(device_handle)` — a new SysV `@no_frame`
lambda in `src/boot/uefi_stub.pdx` that mirrors `efi_load_initrd`'s
seven-step pattern with three differences:

1. **Different fixed path** — `L"\paideia\firmware\manifest.pdxsig"`
   (`_efi_fw_manifest_path : [u16; 34]`, NUL-terminated per UEFI
   2.10 §13.5.2) instead of `L"\EFI\PAIDEIA\rootfs.pdxfs"`.

2. **Different latch slots** — `_efi_fw_manifest_pa` /
   `_efi_fw_manifest_size` instead of `_efi_initrd_pa` /
   `_efi_initrd_size`.

3. **Separate per-op scratch** — `_efi_fw_manifest_file_handle`,
   `_efi_fw_manifest_pool_buf`, `_efi_fw_manifest_info_scratch[512]`,
   `_efi_fw_manifest_info_size`, `_efi_fw_manifest_read_size`.
   Notably NOT reusing the M3-013 initrd scratches — a shared scratch
   would couple two loaders' failure modes (a garbage-tail in the
   initrd scratch could leak into the manifest info parse) which is
   exactly the corruption class the M3-013 landing was written to
   avoid.

Load chain (each step identical to `efi_load_initrd` up to the fixed
path + latch slot substitutions):

1. `OpenProtocol(DeviceHandle, SFS_GUID, 0, 0, BY_HANDLE_PROTOCOL=1)`
   — the SFS interface is re-obtained on this invocation.  UEFI 2.10
   §7.3.9 permits repeated `BY_HANDLE_PROTOCOL` opens on the same
   handle; firmware returns the same interface pointer, and no
   `CloseProtocol` pair is required.  A shared SFS latch across the
   two loaders would be a micro-optimization that isn't worth
   coupling the two failure paths.

2. `sfs->OpenVolume(sfs, &root_out)` — vtable +8.

3. `root->Open(root, &file_out, path, MODE_READ=1, attributes=0)` —
   vtable +8; 5-arg MS x64 with `[rsp+32]=attributes`.

4. `file->GetInfo(file, &FILE_INFO_GUID, &info_size, buffer)` —
   vtable +64; reset `_efi_fw_manifest_info_size` to 512 before the
   call; on success extract `FileSize` from `_efi_fw_manifest_info_
   scratch + 8`.  Guard against zero-length manifest (treat as
   NONE).

5. `BS->AllocatePool(EfiLoaderData=2, size, &pool_buf)` — vtable
   +64 on the BS table.  `EfiLoaderData` survives ExitBootServices.

6. `file->Read(file, &read_size, pool_buf)` — vtable +32;
   `_efi_fw_manifest_read_size` preloaded to `FileSize`.

7. Short-read guard: `cmp read_size, FileSize; jne bail` — a partial
   read would leave garbage tail in the pool alloc (AllocatePool
   does not zero-init per UEFI 2.10 §7.2.4).

On success: latch `_efi_fw_manifest_pa = _efi_fw_manifest_pool_buf`,
`_efi_fw_manifest_size = FileSize`.  On any bail: xor-store zero to
both latches (defensive against partial-success writing the pool-buf
latch before Step 6/7 failed).

Alignment ledger identical to `efi_load_initrd`'s 4-callee-save-push
prologue.  Labels prefixed `elm_` (mirroring `eli_` for
efi_load_initrd) — grep audit 2026-09-07: no `elm_` hits anywhere
else in `src/`.

Call-site placement in `efi_main`: after `efi_load_initrd` returns
(the LoadedImage DeviceHandle is still latched in
`_efi_last_opened_interface + 24`, and no intervening firmware call
has invalidated it).  This ordering is deterministic — the manifest
loader always runs whether or not the initrd loader succeeded, so a
missing rootfs blob does not gate the manifest load, and vice versa.

Finalizer wiring: `efi_finalize_and_handoff` Phase 1 gains two
additional `mov [rdi + 120], rax` / `mov [rdi + 128], rax` stores
right after the M3-013 initrd stores at `+104` / `+112`, before the
Phase-2 memmap / EBS retry loop begins.

---

## 5. Kernel-side witness

`src/kernel/boot/witness/fw_manifest_witness.pdx` — new module
mirroring `rootfs_mount_witness.pdx` byte-for-byte in shape:

- **OK path** (`_boot_env_pa != 0 && boot_env->fw_manifest_pa != 0`):
  emits `FW MANIFEST OK pa=0x<16hex> size=<dec>` via
  `klog_s1_x1_d1(3, SUBSYS_BOOT, tag_fw_manifest_ok, k_pa, pa,
   k_size, size)`.  UEFI-only reachability; allowlisted in
  `tools/verify-fingerprint-coverage.sh` under the same "no OVMF
  smoke mode boots past ExitBootServices yet" posture as
  `UEFI BRIDGE OK` / `UEFI PML4 OK` / `UEFI EBS OK` /
  `ROOTFS MOUNT OK type=pdxfs`.

- **NONE path** (`_boot_env_pa == 0 || boot_env->fw_manifest_pa == 0`):
  emits `FW MANIFEST NONE` via `klog_s1(3, SUBSYS_BOOT,
  tag_fw_manifest_none)`.  No OK token → invisible to the coverage
  extractor; pinned in `tests/r17/shell-shutdown.golden` as an
  ordered-substring line immediately after `ROOTFS MOUNT NONE`.

Call-site placement in `src/kernel/boot/witness/r30_platform.pdx`:
immediately after `rootfs_mount_witness_call`, becoming the new tail
of the boot witness chain.  The R107 → ROOTFS → FW MANIFEST ordering
preserves every prior R52..R55 PdxFS + R107 mount block golden pin.

**Scope cap (mirrors R111.M3-013's cap):** the witness proves the
loader → boot_env carry → kernel read chain works end-to-end, but
does NOT parse the manifest bytes or validate its signature.  A
malformed manifest is a downstream loader concern (R111.M6-023 /
M6-024); this witness's contract is "did the loader hand us bytes?",
not "do those bytes verify?".  A future landing MAY replace the
`FW MANIFEST OK` witness with a stricter variant that emits the
loader's parsed blob count, but the tag prefix stays stable so
allowlist / golden pins survive that refinement.

---

## 6. Sourcing recipe (informational; owned by R111.M7-025)

Blob provenance for operator use (this section is authoritative
today; the image builder that consumes it lands at R111.M7-025):

- **Intel microcode:** extract from `linux-firmware.git`
  `intel-ucode/06-b7-01` (Raptor Lake-U B0 stepping).  Rename to
  `06-b7-01.bin` and stage at `/paideia/firmware/microcode/` in the
  operator's `--firmware-dir=<path>` tree.

- **Iris Xe GuC/HuC:** extract from `linux-firmware.git`
  `i915/tgl_guc_70.<rev>.bin` and `i915/tgl_huc_<rev>.bin`.  Rename
  to `guc_70.bin` / `huc_<rev>.bin` and stage at
  `/paideia/firmware/gpu/`.

- **Manifest:** produced at `mkimage.sh` time by hashing every
  file in `--firmware-dir=<path>` and emitting one line per blob in
  the `<sha3-256-hex> <esp-relative-path> <length>` schema, wrapped
  in the `.pdxsig` envelope (R111.M6-023 lands the wrap; R111.M6-022
  ships an unwrapped-payload variant that the UEFI stub still loads
  identically).

Neither the paideia-os monorepo nor the paideia-as source tree
carries any of these bytes — MIT license terms are incompatible with
Intel's redistribution license.  `mkimage.sh` refuses to run without
`--firmware-dir=<path>` present and populated with all three blob
classes, matching the `design/security/no-silent-fallback.md` fail-
loud rule.

---

## 7. Follow-up landings

This document is the layout **contract**; the following landings
implement its consumers:

| Milestone     | Consumer                             | Status                 |
| ------------- | ------------------------------------ | ---------------------- |
| R111.M6-022   | ESP layout + boot_env carry + fw     | THIS LANDING (#2374)   |
|               | manifest witness                     |                        |
| R111.M6-023   | Firmware manifest signed hash chain: | LANDED 2026-09-07      |
|               | 64B Ed25519 sig trailer + trust-root | (paideia-os #2375)     |
|               | pubkey + verifier seam + per-entry   |                        |
|               | SHA compare + boot-policy gate       |                        |
| R111.M6-024   | GuC/HuC blob staging (KIND_BLOB      | LANDED 2026-09-07      |
|               | mint; no consumer wiring)            | (paideia-os #2376)     |
| R111.M7-025   | `tools/mkimage.sh` — the image       | LANDED 2026-09-07      |
|               | builder that populates the ESP per   | (paideia-os #2377)     |
|               | this document                        |                        |
| R32 / R82     | ML-DSA-65 signature envelope for     | Deferred               |
|               | manifest.pdxsig; verify_self chain   |                        |
| R37 / R77     | Iris Xe modeset actually consuming   | Deferred               |
|               | the staged GuC/HuC blobs             |                        |

Each of the above lands with its own golden update and fingerprint
allowlist entry as needed; this document is amended in-place with a
brief "landed X on <date>" note per row rather than rewritten.
