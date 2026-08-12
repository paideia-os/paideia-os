# PaideiaOS — Security: Self-hosted PE32+ Secure-Boot Signing

**Status:** Draft v0.1 — deferred to R32/R33
**Date:** 2026-08-11
**Round:** R28 — MVP demo consolidation
**Issue:** #1001 (r28-m1-004) — self-hosted PE32+ signing of `PAIDEIA.EFI`
**Cross-repo:** `paideia-as` (PE32+ Certificate Table emit + PKCS#7 wrap)

**Successor:** superseded when the R32 PQ-crypto substrate lands +
                R33 KEK/db enrollment ceremony (see
                `design/security/secure-boot.md` §2).

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| PBS-D1 | R28.M1 ships **unsigned** `PAIDEIA.EFI` / `BOOTX64.EFI` | Signing requires a crypto stack (ML-DSA-65 or fallback ECDSA-P384) that paideia-as / paideia-os do not have until R32 substrate. |
| PBS-D2 | MVP demo boots with **UEFI Secure Boot disabled** | Documented and gated (`design/security/secure-boot.md` SB-D1 relaxed for the pre-R32 demo window only). |
| PBS-D3 | Do **not** emit an empty PE Certificate Table slot in R28 | The PE spec (§5.7) forbids a zero-size WIN_CERTIFICATE record; a stub slot would misrepresent the image as signed. Land the slot at R32 alongside real signature bytes. |
| PBS-D4 | Track PE signing as a `paideia-as v0.24+` blocker | The `paideia-as-emitter-pe` crate needs (a) `IMAGE_DIRECTORY_ENTRY_SECURITY` population, (b) PKCS#7 SignedData wrap, (c) the crypto stack itself. Filed against paideia-as as a single blocker milestone. |
| PBS-D5 | R28 lands a **paideia-native** scaffolding path (`tools/sign-efi.sh` + `.pdxsgn`/`.pdxpk`/`.pdxsig` PE sections) that boots and self-verifies WITHOUT the Secure-Boot / PKCS#7 machinery | Splits the pipeline into two independently landable halves: the paideia-native half (this file's PBS-D1..PBS-D4 domain) stays deferred to R32/R33 for firmware-visible Secure Boot; the scaffolding half (see `design/security/efi-signing.md`) lets R28 already prove sign/verify shape end-to-end under the R25.M5 dev-bypass discipline. The two halves share no bytes on disk — Certificate Table lives at `IMAGE_DIRECTORY_ENTRY_SECURITY`; the paideia-native trailer lives at RVA 0xd000. R33 turns on BOTH: the Certificate Table for firmware trust, and enforcement of the paideia-native trailer for kernel-side trust. |

---

## 1. Why R28.M1 does not sign

Three composed prerequisites are all still under construction:

1. **paideia-as PE Certificate Table emit.** `paideia-as-emitter-pe` at
   `v0.23` writes a well-formed PE32+ header but leaves
   `IMAGE_DATA_DIRECTORY[4]` (`IMAGE_DIRECTORY_ENTRY_SECURITY`) at
   zero. Adding real signature bytes requires:
   - Appending a `WIN_CERTIFICATE` record (aligned to 8 bytes) at the
     end of the PE image.
   - Setting `IMAGE_DIRECTORY_ENTRY_SECURITY.VirtualAddress` to that
     record's file offset (this directory is a *file offset*, not an
     RVA — the only such directory in the PE format).
   - Setting `.Size` to the WIN_CERTIFICATE length.
   - Recomputing the PE header checksum after the append (per PE
     specification §3.4.1 the checksum computation excludes the
     checksum field itself and the certificate table).

2. **PKCS#7 SignedData wrap.** UEFI Secure Boot (per UEFI 2.10 §32.3.3)
   requires the certificate to be `WIN_CERT_TYPE_PKCS_SIGNED_DATA`
   (revision `0x0200`), i.e., an ASN.1 DER PKCS#7 SignedData structure
   with:
   - `contentType` = `SPC_INDIRECT_DATA_OBJID` (Authenticode).
   - `contentInfo` = hash of the PE image with the certificate table
     region and checksum field excluded (Authenticode hash algorithm,
     Microsoft "PE image hash" spec §3.1).
   - `signerInfos[0]` = signer certificate + signed digest.
   PaideiaOS has neither an ASN.1 encoder nor a PKCS#7 encoder yet.
   Both are R32 substrate deliverables (`design/security/algorithm-catalog.md`
   +  the R32 planning doc).

3. **The signature itself.** PBS-D2 in
   `design/security/secure-boot.md` specifies ECDSA-P384 as the
   interim PK algorithm (until EDK2 supports PQ signatures per PQ-O4).
   PaideiaOS has no ECDSA-P384 signing primitive today; the R32 substrate
   lands ML-DSA-65 first (PQ mainline) with ECDSA-P384 as a compatibility
   shim so we can be Secure Boot–eligible on unmodified firmware.

Together, these are `paideia-as v0.24+` scope, not R28 scope.

## 2. Why we don't ship an empty Certificate Table slot at R28

A zero-size `WIN_CERTIFICATE` record is not valid per PE §5.7 — the
size field must span at least the record header (`dwLength >= 8`).
Any firmware that consults the Certificate Table (which is exactly the
firmware we care about, i.e., Secure-Boot-enabled) will read the slot
and either:

- reject the image (`EFI_SECURITY_VIOLATION`), or
- treat garbage after the header as the certificate blob, which
  is a signature-oracle risk we categorically refuse.

The safe pattern is: no directory entry at all until we can emit a
real, correctly-hashed, correctly-signed WIN_CERTIFICATE. The R32
retrofit is a one-shot append + directory-entry update, not a header
restructure — the PE layout tolerates the addition without moving any
existing section.

## 3. What the R32/R33 retrofit looks like

R32 (crypto substrate) delivers:

- ML-DSA-65 keygen + sign + verify (`src/kernel/core/crypto/mldsa/*`
  and `src/user/tools/pdx-sign/*`).
- ECDSA-P384 sign (compatibility shim for pre-PQ EDK2).
- ASN.1 DER encoder.
- PKCS#7 SignedData constructor.
- Authenticode "PE image hash" primitive.

Then a new `tools/sign-efi.sh` (R32-M?-001, tracked at R32 open time)
walks:

```
sign-efi.sh --key <pem> --cert <der> --in PAIDEIA.EFI --out PAIDEIA.EFI.signed
```

1. Compute the Authenticode hash of the input PE (skip `.PE.Checksum`,
   `.PE.CertificateTable`, and the certificate table region).
2. Build the PKCS#7 SignedData over that hash.
3. Wrap in a `WIN_CERTIFICATE` record; 8-byte-align.
4. Append the record to a copy of the PE image.
5. Update `IMAGE_DIRECTORY_ENTRY_SECURITY.{VirtualAddress, Size}`.
6. Recompute `PE.Checksum`.
7. Emit `PAIDEIA.EFI.signed`.

R33 (Secure Boot enrollment ceremony) delivers:

- Owner-key material generation (paideia-os project root key).
- KEK, db, dbx population (`design/security/secure-boot.md` §2 + §3).
- First-boot db enrollment (either via the firmware setup GUI or the
  `EFI_IMAGE_EXECUTION_INFO_TABLE` self-enroll path — decision at R33
  open).

Once R32+R33 are live, R28's `PAIDEIA.EFI` is re-emitted through the
signing tool and the MVP demo image is republished. No format-level
breaking change is required on the ESP layout — only the .efi bytes
change.

## 4. MVP-demo operator guidance (until R32/R33 land)

The R28 MVP image is bootable only with Secure Boot disabled. Operator
instructions for the T14 G4 real-hardware smoke:

1. Enter firmware setup (F1 during POST).
2. Navigate to **Security → Secure Boot → Secure Boot** and set to
   **Disabled**.
3. **Do not** clear the platform key (PK) — clearing PK puts the
   firmware in Setup Mode, which the T14 G4 exposes different
   OS-loader search paths for. Keep PK intact; the disabled state is
   sufficient to boot an unsigned loader without changing the trust
   anchor.
4. Save & Exit; the R28 image now boots via the
   `/EFI/BOOT/BOOTX64.EFI` fallback (or the `/EFI/PAIDEIA/PAIDEIA.EFI`
   canonical path if you registered an NVRAM Boot#### entry).

The R33 enrollment ceremony rolls a paideia-project PK/KEK, enrolls
the paideia-signed db entry, and re-enables Secure Boot. That is the
first R28+ demo image that boots on unmodified enterprise firmware
without operator setup.

## 5. Cross-references

- `design/security/secure-boot.md` — the destination Secure Boot
  configuration (SB-D1..D5) that this doc defers into.
- `design/security/algorithm-catalog.md` — ML-DSA-65 + ECDSA-P384
  algorithm choices this doc will consume once R32 lands.
- `design/roadmap/r18-plus-bare-metal.md` §R32, §R33 — the rounds that
  unblock this deferral.
- paideia-as: PE Certificate Table emit + PKCS#7 wrap
  (`paideia-as v0.24+` blocker, to be filed as a milestone-scoped
  issue against `paideia-as/paideia-as`).
