# PaideiaOS — EFI Self-Signing (R28 scaffolding, R32 substrate, R33 enforce)

**Status:** Landed v0.1 (R28.M1-004 / #1001)
**Date:** 2026-08-12
**Round:** R28 — MVP demo consolidation
**Issue:** #1001 (r28-m1-004) — self-hosted PE32+ signing of `PAIDEIA.EFI`
**Superseded by:** R32 (real ML-DSA-65 crypto substrate) + R33 (KEK enrollment,
                    enforcement flip)

Sibling: `design/security/pe-secure-boot-signing.md` — the deferred UEFI
Secure-Boot / PKCS#7 Certificate-Table path. This document describes the
**paideia-native** signing pipeline that R28 lands as scaffolding.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| ES-D1 | R28 sign-and-verify uses **appended PE sections** (`.pdxsgn`, `.pdxpk`, `.pdxsig`), not the PE Certificate Table | Certificate Table + PKCS#7 wrap requires ASN.1 DER + Authenticode primitives that only land at R32. Appending named sections is a native binutils `objcopy --add-section` operation with no paideia-as encoder dependency. |
| ES-D2 | Signature bytes are **all-zero** at R28 (dev-bypass) | Mirrors the R25.M5 PdxFS-lite superblock verify convention: proves the pipeline shape without the crypto substrate. Verifier accepts all-zero as "signed (dev-bypass)"; a non-zero sig field under R25.M5 fails verify (real crypto not yet scaffolded to consume it). |
| ES-D3 | Verification runs **kernel-side, post-handoff** (`src/kernel/boot/verify_self.pdx`) | The stub is a 3-kilobyte merged translation unit under active flux; growing it with verify + UART logic would multiply the surface area of that file. The kernel already has UART and the boot_env_t handoff carries `image_base` / `image_size` — the verify code drops in naturally after `uefi_physmap_seed_alloc`. |
| ES-D4 | Section RVAs are **fixed** (`0xd000`, `0xe000`, `0xf000`) — the verifier hardcodes them | Avoids a PE section-table walker in the kernel (~200 lines of parser code that only exists to look up three known names). The stub's existing sections occupy `0x1000..0xc110` and `SectionAlignment` is `0x1000`, so `0xd000+` is the natural next slot. The tool and the verifier agree via three compile-time constants. |
| ES-D5 | Enforcement is **log-only** at R28 (`VERIFY_SELF_ENFORCE = 0`) | R28 lands the pipeline; R33 flips enforcement on when the KEK-enrollment ceremony is complete. An unsigned image at R28 boots normally with a warning line; at R33 it will halt with a panic. |

---

## 1. Section layout (kept in lockstep by `tools/sign-efi.sh` and `src/kernel/boot/verify_self.pdx`)

```
image_base +          section     size      contents
 -----------------    -------     ----      --------
 0x00000000           MZ/PE       ~3 KiB    unsigned stub bytes (unchanged)
 0x0000d000           .pdxsgn     32 B      trailer: magic + metadata
 0x0000e000           .pdxpk      1952 B    ML-DSA-65 public key (FIPS 204 §5.4)
 0x0000f000           .pdxsig     3309 B    ML-DSA-65 signature (FIPS 204 §5.4)
```

Signed image `SizeOfImage` = `0x10000` (0xf000 + section-aligned 3309-byte
payload rounds up to 0x10000). The verifier's bounds gate checks
`image_size >= 0x10000` before touching any of the three section regions.

### `.pdxsgn` trailer layout (32 bytes)

```
offset  size  field
------  ----  -----
+0      8     magic          = "PDXSGN01"
+8      4     version        = 1
+12     4     hash_algo_id   = 1 (SHA3-256)
+16     4     sig_algo_id    = 1 (ML-DSA-65)
+20     4     pk_size_bytes  = 1952
+24     4     sig_size_bytes = 3309
+28     4     signed_range_end (input file size at signing time)
```

The magic is verified as a single u64 LE compare against `0x31304E4753584450`.
The other fields are informational at R28; the R32 verify path will
consult `hash_algo_id` / `sig_algo_id` before dispatching to the real
crypto primitive.

---

## 2. Signing pipeline (`tools/sign-efi.sh`)

```
   +-------------------+
   |  unsigned .efi    |     input: build/uefi/uefi_stub.efi
   +---------+---------+
             |
             v
   +-------------------+
   |  SHA3-256 hash    |     structural fingerprint for the sign-run log
   |  (input bytes)    |     (R32 real crypto uses Authenticode PE hash)
   +---------+---------+
             |
             v
   +-------------------+
   |  build .pdxsgn    |     32 B trailer: magic + metadata
   |  trailer blob     |
   +---------+---------+
             |
             v
   +-------------------+
   |  stage .pdxpk     |     1952 B copied from assets/keys/paideia-root-dev.pub
   |  stage .pdxsig    |     3309 B all-zero (R28 dev-bypass; R32 real ML-DSA-65)
   +---------+---------+
             |
             v
   +-------------------+
   |  objcopy          |     --add-section .pdxsgn=... (VMA=0xd000)
   |  --add-section    |     --add-section .pdxpk=...  (VMA=0xe000)
   |  x3               |     --add-section .pdxsig=... (VMA=0xf000)
   |                   |     --set-section-flags each = alloc,readonly,load,contents,data
   +---------+---------+
             |
             v
   +-------------------+
   |  signed .efi      |     output: build/uefi/uefi_stub.signed.efi
   +-------------------+
```

The signed .efi is copied verbatim by `tools/build-uefi-image.sh` to
BOTH ESP paths (`/EFI/BOOT/BOOTX64.EFI` and `/EFI/PAIDEIA/PAIDEIA.EFI`).

---

## 3. Verification pipeline (`src/kernel/boot/verify_self.pdx`)

```
   +-------------------+
   |  kernel_main_uefi |     called post-handoff (RDI = &boot_env_t)
   +---------+---------+
             |
             v
   +-------------------+
   |  latch env_pa,    |     rbp = env->image_base  (@ +56)
   |  image_base+size  |     rbx = env->image_size  (@ +64)
   +---------+---------+
             |
             v
   +-------------------+
   |  bounds gate      |     image_size >= 0x10000 ?
   +----+---------+----+     no -> UNSIGNED (safe: never reads past image)
        |         |
       yes       fail
        |         |
        v         v
   +----+----+  +--------------+
   | magic   |  |   emit       |    "R28 EFI UNSIGNED (R33-gate off)\r\n"
   | check   |  |   UNSIGNED   |    return 0
   +----+----+  +------+-------+
        |              ^
    pass|              | fail (any check)
        |              |
        v              |
   +----+---------+    |
   | [image_base+ |    |
   |   0xd000] == |----+  no
   | 0x31304E4753 |
   |   584450 ?   |
   +----+---------+
        | yes
        v
   +----+---------+
   | sig-all-zero |
   | 414 qwords   |     OR-fold [image_base + 0xf000 .. + 0x10000)
   | starting at  |     any bit set -> unsigned
   | 0xf000       |
   +----+---------+
        | pass
        v
   +----+---------+
   |   emit       |     "R28 EFI SIGNATURE OK\r\n"
   |   OK         |     return 1
   +--------------+
```

Both log lines route through `verify_self_puts` which is byte-identical
in shape to `kernel_main_uefi`'s own banner print (16550D §3.4 THRE-poll
+ THR write at 0x3F8).

---

## 4. R28 → R32 → R33 upgrade path

### R28 (this round, landed)
- Pipeline shape present: sign tool + kernel-side verify + boot_env_t
  wiring + design doc.
- Sig bytes all-zero (dev-bypass); PK all-zero (fixture at
  `assets/keys/paideia-root-dev.pub`).
- Log-only (`VERIFY_SELF_ENFORCE = 0`).
- Blocked-in-runtime: end-to-end log line requires the UEFI-to-kernel
  ELF loader that R28+ still lacks (the stub currently push-rets to a
  symbolic LMA that no LoadImage has staged). The verify_self symbol
  is linked into `kernel.elf`; `objdump -d` confirms `kernel_main_uefi`
  calls it. See `src/kernel/kernel_main_uefi.pdx` L52-63 for the
  execution-context caveat that governs when this path becomes live.

### R32 (crypto substrate)
- Real ML-DSA-65 keygen + sign + verify primitives.
- `tools/sign-efi.sh` step "sig = all-zero" replaced with:
  `pdx-sign --alg ml-dsa-65 --key <priv-key> --in <hash> --out sig.bin`
  where `<hash>` is the Authenticode PE image hash (see
  `design/security/pe-secure-boot-signing.md` §3).
- `verify_self.pdx` step (4) "sig-all-zero OR-fold" replaced with:
  `call ml_dsa_verify(pk_ptr, sig_ptr, hash_ptr)`.
- `assets/keys/paideia-root-dev.pub` regenerated from a real ML-DSA-65
  keypair; private half stays offline (paideia-keys HSM ceremony).

### R33 (Secure Boot enrollment + enforcement)
- KEK / db enrollment ceremony (see `design/security/secure-boot.md` §3).
- `VERIFY_SELF_ENFORCE` flips to `1`; unsigned image on the ESP causes
  the kernel to halt at verify_self_unsigned with a red-line panic.
- PKCS#7 Certificate-Table wrap lands in parallel for UEFI Secure-Boot
  eligibility (see `pe-secure-boot-signing.md` §3).

---

## 5. Cross-references

- `tools/sign-efi.sh` — signing tool.
- `src/kernel/boot/verify_self.pdx` — kernel-side verifier.
- `src/kernel/kernel_main_uefi.pdx` — call site (Phase 4c).
- `tools/build-uefi-image.sh` — invokes sign-efi.sh before ESP staging.
- `assets/keys/paideia-root-dev.pub` — 1952-byte dev PK fixture.
- `src/kernel/core/fs/pdxfs_lite/verify.pdx` — the R25.M5 dev-bypass
  precedent this design mirrors.
- `design/security/pe-secure-boot-signing.md` — the sibling Secure-Boot
  / Authenticode / PKCS#7 path (deferred to R32/R33).
- `design/security/secure-boot.md` — SB-D1..D5, the destination Secure
  Boot configuration.
- `design/security/algorithm-catalog.md` — ML-DSA-65 algorithm choice.
- `design/roadmap/r18-plus-bare-metal.md` §R32, §R33 — the rounds that
  retire this file's R28-scaffolding language.
