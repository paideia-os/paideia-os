# PaideiaOS — Security: Secure Boot Configuration

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** UEFI Secure Boot integration: PK/KEK/db/dbx population, measured-boot extension, PaideiaOS-specific PCR usage. Addresses PQ-O4-equivalent.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| SB-D1 | UEFI Secure Boot mandatory at boot | Pillar 6 |
| SB-D2 | PK is ECDSA-P384 (until EDK2 supports PQ signatures) | Industry standard; PQ deferred |
| SB-D3 | The PaideiaOS loader (`paideia-loader.efi`) signed under the project's KEK | Per dev-env §2.5 |
| SB-D4 | Measured boot via TPM 2.0 (extended PCR 0–7 by firmware, 8+ by loader) | TCG standard |
| SB-D5 | When EDK2 supports PQ signatures (PQ-O4), migrate PK/KEK to hybrid | Forward-looking |

---

## 1. PCR usage

| PCR | Use |
|---|---|
| 0 | CRTM, BIOS, host platform extensions |
| 1 | Host platform configuration (ACPI tables) |
| 2 | Option ROMs |
| 3 | Option ROM configuration |
| 4 | MBR / boot loader |
| 5 | GPT |
| 6 | (resume from S4/S5) |
| 7 | Secure Boot state |
| 8 | `paideia-loader.efi` measurement |
| 9 | Kernel image measurement |
| 10 | Root capability bundle measurement |
| 11 | Initial schemas registry |
| 12 | User DSDT override (per ACPI doc §5.3) if used |
| 13–23 | Reserved for application-specific extension |

---

## 2. Loader signature

`paideia-loader.efi` is signed with the project's ECDSA-P384 key (the KEK). When loaded by UEFI Secure Boot, the signature is verified; failure prevents boot.

Phase 2+ when EDK2 supports hybrid PQ:
- The loader is signed with hybrid Ed25519 + ML-DSA-65.
- The KEK is migrated.

---

## 3. The loader's measurement chain

The loader, after being verified by UEFI, performs:
1. Extends PCR 8 with its own measurement.
2. Reads the kernel image from disk.
3. Verifies the kernel's hybrid Ed25519 + ML-DSA-65 signature against the release-line public key.
4. Extends PCR 9 with the kernel measurement.
5. Reads the root-capability bundle.
6. Verifies its signature.
7. Extends PCR 10 with the bundle measurement.
8. Jumps to kernel entry.

The kernel inherits the measurement chain; remote attestation can verify it.

---

## 4. dbx (revocation)

The dbx list contains revoked signatures. PaideiaOS's release process publishes dbx updates when a release-line key is rotated (the old key's signature on artifacts is added to dbx).

dbx updates are distributed via release artifacts; the installer applies them.

---

## 5. Custom PK injection (per dev-env §2.5)

For development:
1. Generate a development PK/KEK pair.
2. Inject via `virt-fw-vars` or `EnrollDefaultKeys`.
3. Sign loader with the development key.
4. Boot.

For production: a single project PK/KEK is used; the project's CA infrastructure distributes signed loaders.

---

## 6. Open issues

| ID | Issue |
|---|---|
| SB-O1 | EDK2 PQ signature timeline. |
| SB-O2 | Per-vendor BIOS quirks in Secure Boot enrollment. |
| SB-O3 | The dbx update distribution mechanism. |

---

*End of document.*
