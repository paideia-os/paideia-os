# R82 Retrospective (DEFERRED): kernel PQ crypto + TPM

**Date:** 2026-08-25
**Milestone:** R82.M1 (single-milestone round)
**Issues:** 0 landed / 2 partial (#1846, #1850) / 7 deferred (#1840,
#1842, #1843, #1845, #1847, #1849, #1851); this doc closes #1852.
**HEAD at audit:** paideia-os bbb3d35 (fresh worktree, no code changes
made by this audit).
**Release tag:** none cut — this round is the least-started of the
seven audited; recommend leaving the milestone open for a genuine
implementation pass rather than tagging `r82-closed`.

## Round intent

Per `design/roadmap/post-r60-daily-use-roadmap.md` (R82 row, "XL"
effort): kernel-side post-quantum cryptography (ML-KEM-768, ML-DSA-65,
SLH-DSA-128f) plus a TPM 2.0 CRB driver and measured-boot PCR chain.
Design intent is thoroughly documented (`design/security/pq-trust-root.md`,
`algorithm-catalog.md`, `tpm-pq-tracking.md`, etc.) but this is design,
not implementation.

## Why this round differs from the others audited

R76/R77/R81/R83/R84 all inherited substantial driver scaffolding from
earlier rounds (R32-R34, R38-R39) that is merely unexercised against
real hardware. **R82 has almost no implementation corpus at all.**
Exhaustive greps found:

- No `kyber`/`ml_kem`/`ml_dsa`/`dilithium`/`slh_dsa`/`pqc` file or
  symbol anywhere in `src/`.
- No `rdrand`/`rdseed`/`sys_random` symbol anywhere in `src/`.
- No `tpm_crb`/`tpm2_crb`/`"CRB"` symbol anywhere in `src/` — the only
  TPM-adjacent file is `src/boot/uefi_tcg2.pdx` (190 lines, R19-M3-004,
  #795), a **boot-time UEFI-protocol wrapper** that calls
  `EFI_TCG2_HASH_LOG_EXTEND_EVENT` to extend PCR 4 with the kernel
  image hash — this is firmware-mediated measured boot, not an
  OS-runtime TPM CRB register driver.
- The one thing that does exist is `src/kernel/core/driver/sig_verify.pdx`
  (455 lines, R29.M4-001, #1032): a **structural** ML-DSA-65 verifier
  surface — dispatch, well-formedness gates, verdict taxonomy — that
  its own header states explicitly contains "NO lattice arithmetic"
  and is designed to return `SIG_UNVERIFIABLE` for any non-zero
  signature until R82 supplies the real math. A dev placeholder signing
  key was added later (`5a3bf12`, R53.M1-003, #1732) but the verifier
  still cannot validate a real signature.

## Per-issue disposition

### #1840 — Entropy pool: RDSEED/RDRAND fallback + sys_random — DEFERRED
No code anywhere. Unstarted.

### #1842 — ML-KEM-768 keypair + encap + decap (FIPS-203) — DEFERRED
No code anywhere. Unstarted. `design/security/pq-trust-root.md §0.2
PQ-Q3/PQ-Q6` specifies ML-KEM-1024 (hybrid X25519) as the confidentiality-
KEM choice, one level above this issue's ML-KEM-768 — worth reconciling
scope against the design doc when this is implemented.

### #1843 — ML-DSA-65 keypair + sign + verify (FIPS-204) — DEFERRED
No lattice-arithmetic code anywhere. The structural verifier surface
that will eventually *consume* this math (`sig_verify.pdx`) already
exists and explicitly names `src/kernel/core/crypto/ml_dsa/verify.pdx`
as where this issue's work should land — that path does not exist yet.

### #1845 — SLH-DSA-128f sign + verify (FIPS-205, stateless fallback) — DEFERRED
No code anywhere. Unstarted.

### #1846 — Sig-verify replacement: PdxFS stub to real ML-DSA-65 verify — PARTIAL
The stub half is genuinely landed: `sig_verify.pdx` (455L, R29.M4)
implements the complete non-cryptographic verification pipeline
(artifact/signature/key well-formedness, algorithm dispatch, verdict
taxonomy) by design, deliberately returning `SIG_UNVERIFIABLE` rather
than a false pass in the current "scaffold epoch." The replacement
itself — swapping the always-`SIG_UNVERIFIABLE` path for a real
ML-DSA-65 verify call — cannot land until #1843 exists. PARTIAL:
structural half landed, blocked on #1843, not a hardware gate.

### #1847 — TPM 2.0 CRB driver: register discovery + command/response +
PCR read/extend — DEFERRED
No CRB driver exists. `src/boot/uefi_tcg2.pdx` is boot-time-firmware-
protocol-mediated, not an OS-runtime MMIO CRB driver, and doesn't
substitute for this issue. Unstarted.

### #1849 — TPM 2.0 PTT discovery + init on T14 G4 — DEFERRED
Blocked on #1847, which does not exist. Also real-hardware-only once
#1847 lands (T14 G4's specific PTT/fTPM implementation).

### #1850 — UEFI TCG2 log consumption: replay event log into TPM PCRs
at boot — PARTIAL
`src/boot/uefi_tcg2.pdx` (190L) implements the **write** side — a
single `HashLogExtendEvent` call extending PCR 4 with the kernel image
hash at boot. The issue asks for the **read/replay** side — consuming
firmware's own accumulated event log (`EFI_TCG2_GET_EVENT_LOG`) and
replaying it into PCRs — which is a different TCG2 protocol method
(`GetEventLog`, offset +8 in the protocol struct per this file's own
layout comment) and is not called anywhere. PARTIAL: adjacent
mechanism landed, the issue's specific direction is not.

### #1851 — Boot smoke `boot_r82_crypto_pcr` (real hw only) — DEFERRED
Does not exist. Blocked on essentially everything above.

### #1852 — Round closure — this document
STATUS + retrospective, this round's own audit.

## Cross-repo escalations

None found.

## Observable proof

None — no code changes made by this audit. The only pre-existing
observable is `sig_verify.pdx`'s deterministic `SIG_UNVERIFIABLE`
return for any non-zero-signature input, unchanged since R29.M4.

## Debt inventory (carried forward)

1. **Entropy pool** (#1840) — RDSEED/RDRAND + jitter mixing (named as
   a hard-inherited constraint at `pq-trust-root.md` C15) + `sys_random`
   syscall. Unstarted, foundational for everything else in this round.
2. **ML-KEM-768/1024** (#1842) — reconcile the issue's -768 against the
   design doc's -1024 choice before implementing.
3. **ML-DSA-65** (#1843) — the actual lattice math `sig_verify.pdx` is
   waiting for.
4. **SLH-DSA-128f** (#1845) — boot-chain signing per `pq-trust-root.md
   PQ-Q3` (SLH-DSA-128s is named there for boot-chain; reconcile -128f
   vs -128s before implementing).
5. **Sig-verify replacement** (#1846) — mechanical once (3) lands.
6. **TPM 2.0 CRB driver** (#1847) — new OS-runtime MMIO driver; `swtpm`
   support noted as testable per the task brief, though not exercised
   in this audit.
7. **TCG2 event-log replay** (#1850) — new `GetEventLog` call site,
   additive to the existing `HashLogExtendEvent` wrapper.
8. **`boot_r82_crypto_pcr`** — write once (1)-(7) land; PCR-specific
   fingerprint is real-hardware-only regardless.

**Next round:** this is the largest non-hardware-gated debt list of
the seven audited rounds — items 1-5 are pure math/kernel work,
entirely buildable and QEMU-testable without real T14 G4 hardware
(per the task brief's own framing: "Crypto is pure math (fully
QEMU)"). Recommend treating R82 as needing a dedicated implementation
wave before any further hardware-blocked audit passes, rather than
resuming the roadmap sequence past it.
