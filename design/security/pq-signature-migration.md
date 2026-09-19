# PaideiaOS — Post-Quantum Signature Migration (Ed25519 → Ed25519 ‖ ML-DSA-65)

**Status:** Draft v0.1
**Date:** 2026-09-18
**Scope:** Migration plan for every PaideiaOS signature-bearing artifact
(`.pdxpkg` packages, `.pdxtrust` trust anchors, `.pdxfs` volume
superblocks, satellite unmount receipts) from classical-only
Ed25519 signing to dual-signing (Ed25519 ‖ ML-DSA-65). Companion to
`pq-trust-root.md` (algorithm selection per role) and
`quantum-migration.md` (post-CRQC pure-PQ pivot).

**Hard inputs.** `pq-trust-root.md` §0.2 PQ-Q1 (hybrid by default),
PQ-Q3 (release artifacts hybrid Ed25519 + ML-DSA-65). `algorithm-
catalog.md` (per-algorithm status labels). `paideia-as` v0.36.4
Wave υ ML-DSA-65 compact-ABI FFI landing.

---

## 1. Rationale

**HNDL (harvest-now-decrypt-later) threat model.** A CRQC has not
emerged, but adversaries with long-horizon retention capacity can
harvest signature-bearing artifacts today and forge new artifacts
against a compromised classical key later. The threat is asymmetric:
the trust anchor (`.pdxtrust`) has a life measured in years —
production artifacts signed under a today-classical trust anchor are
verifiable for the anchor's entire lifetime, which straddles the
CRQC-emergence horizon. Ed25519-only signing on those artifacts
becomes an unforgeability gap the day a CRQC lands.

**Hybrid, not pure-PQ.** Per `pq-trust-root.md` PQ-Q1, every
signature is `classical ‖ PQ` until CRQC-emergence triggers the
pure-PQ pivot described in `quantum-migration.md`. Rationale: PQ
schemes are young enough (FIPS 204 finalised August 2024) that
lattice-cryptanalysis surprises remain plausible, and the hybrid
construction lets one component fail without the artifact losing all
authentication. Verify requires BOTH signatures to validate; the
classical component hedges against PQ cryptanalysis while the PQ
component hedges against CRQC.

## 2. Timeline

| Wave    | State                                                                    |
|---------|--------------------------------------------------------------------------|
| Now (υ) | ML-DSA-65 compact-ABI FFI lands in `paideia-as-crypto` (`mldsa65_verify` / `mldsa65_sign`). No consumer wiring; `.pdxpkg` / `.pdxtrust` verify chains still classical-only. |
| υ+1     | `.pdxtrust` dual-signature verify chain (Wave υ-03 pending on the pdxtrust satellite existing). Anchor loader refuses if either signature fails. |
| υ+2     | `.pdxpkg` install-time dual-signature verify (Wave υ-04 pending on the pkg satellite existing). `pkg install` refuses if either signature fails. |
| υ+3     | `mkfs.pdxfs` superblock dual-signature at format time; `mount.pdxfs` verify chain (`pdxb_verify_superblock`) refuses if either signature fails. Consumes the compact-ABI `MlDsa65C` trait; retires `MlDsa65` calls. |
| υ+4     | All CI release runners emit dual signatures. Legacy Ed25519-only artifacts still verifiable through the deprecation window (see §3). |
| v1.0.0-real (bar) | Every trust-anchor and package artifact is dual-signed. Ed25519-only artifacts refused by default; a `--allow-classical-only` flag on `pkg install` gates a documented deprecation grace period. |

## 3. Backward compatibility

**Ed25519-only artifacts remain verifiable through the deprecation
window.** Wave υ+1..υ+3 verify chains distinguish three states:

- Both signatures present → BOTH must validate; refuse otherwise.
- Only Ed25519 present → validate Ed25519; audit-log
  `PQ_HYBRID_MISSING` warning; accept unless
  `strict_hybrid` capability is held (default off through υ+3,
  default on at v1.0.0-real).
- Only ML-DSA-65 present → validate ML-DSA-65; audit-log
  `CLASSICAL_MISSING` warning; accept under the same rule.

Post-CRQC (per `quantum-migration.md` §2 step 3), the classical
branch is retired and Ed25519-only artifacts become unverifiable;
the transition is signalled by the algorithm catalog flipping
Ed25519 to `deprecated`.

## 4. Tooling adoption

| Tool               | Signs?  | Verifies? | Adoption wave |
|--------------------|---------|-----------|---------------|
| `pkg`              | no      | yes       | υ+2           |
| `pdxtrust`         | yes (CI release runner) | yes (kernel + userspace loaders) | υ+1 |
| `mkfs.pdxfs`       | yes (at format time)    | no                               | υ+3 |
| `mount.pdxfs`      | no      | yes       | υ+3           |
| `umount.pdxfs`     | yes (unmount receipt)   | no                               | υ+3 |
| `paideia-pq-sign` CLI | yes  | yes       | already dual-capable |

The sign side uses `paideia-pq-sign` (std-linked, HSM/SoftHSM
back-ends per `pq-trust-root.md` PQ-Q4); the verify side uses
`paideia-as-crypto::ffi::mldsa65_verify`. As landed in Wave υ, the
compact-ABI thunks in `paideia-as-crypto::ffi::ml_dsa_65` are
`#[cfg(feature = "std")]`-gated because RustCrypto's `ml-dsa` 0.1.1
drags `crypto_common`'s `std` dep chain, which conflicts with
`paideia-satellite-runtime`'s `#![no_std]` panic_impl. The elaborator
binary itself (`paideia-as`) does not currently enable `std` on the
`paideia-as-crypto` dep chain either, so the thunks are scaffolded
but NOT reachable in any current build target: consumer wiring — a
std-linked crate that both re-exports the thunks and gets pulled into
the elaborator's dep graph, OR a no_std alternative to `ml-dsa` that
does not drag `crypto_common`/`std` — is a follow-up wave (tracked
alongside υ-03/υ-04 satellite adoption). Every verifier holds both
Ed25519 and ML-DSA-65 verifying keys in the artifact's authenticated
envelope; the wire format is finalized in this wave, the on-boot
verify path is not.

## 5. Test evidence

Wave-υ landing evidence lives in the paideia-as CHANGELOG scratch
entry and the crate test suites:

- `paideia-as-crypto` unit + FFI tests: round-trip sign→verify,
  flipped-signature rejection, wrong-message rejection, empty-
  message round-trip, NULL-pointer rejection on every reachable
  input, undersized-output rejection, wrong-length rejection.
- `paideia-as-elaborator` `cryptoops::mldsa65` tests: `MlDsa65C::sign`
  and `MlDsa65C::verify` lower to `extern_target` recipes with the
  expected `SysVRegs` argument convention and symbol names.

Wave υ+1..υ+3 test evidence (dual-verify smoke on `.pdxtrust` /
`.pdxpkg` / `.pdxfs` superblocks) lands with each consumer wave.
Each smoke must exercise all three §3 states (dual, classical-only,
PQ-only) plus a tampered-signature rejection per component.

## 6. Rollback

The compact `MlDsa65C` trait coexists with the pre-existing
`MlDsa65` (pq-sign runtime-entry) trait for the entire migration.
If a compact-ABI thunk regresses, consumers can revert their
`MlDsa65C::verify` call sites to `MlDsa65::verify` — the pq-sign
runtime-entry surface remains intact through v1.0.0-real. The
retirement of `MlDsa65` is scheduled for the wave that closes out
the last non-compact consumer, and gated on green smokes across
every satellite build.

---

*End of document.*
