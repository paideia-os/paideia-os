# PaideiaOS — Post-Quantum Trust Root

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** The post-quantum trust root: hybrid posture, trust hierarchy, algorithm selection per role, key residency matrix (HSM/KMS/enclave/TPM), software-enclave design for client hardware lacking TDX/SGX, KEM application scope, operational quorum, layered remote attestation, key rotation policy, and algorithm-agile migration. Settles the open items from Q11 of `01-foundational-decisions.md` and `02-development-environment.md` §6.2/§14 (items H1, H2, H6, S1, S4).

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — C11 (secure-boot/measured-boot root), C15 (entropy), E8 (PQ crypto subsystem), E9 (TLS 1.3 + hybrid PQ handshake), E16 (identity), E19 (audit log).
- `design/01-foundational-decisions.md` — Q11 (TPM + TDX/SGX enclave hybrid), Q15 (max mitigations), §3 tension #4 (TDX server-only, SGX deprecated on client).
- `design/02-development-environment.md` — §6.2 (PQ scheme recommendation), §6.4 (key residency draft), §10.7 (CI role model), §14 (open issues H1, H2, H6, S1, S4).
- `design/capabilities/linearity-and-tags.md` — capability-typed delegation; `seal_cap` / `unseal_cap`; audit-log capability kind.
- `design/ipc/wait-free-dataflow.md` — audit-channel transport for security events.

---

## 0. Decisions summary

### 0.1 Inherited (already binding)

| Source | Constraint |
|---|---|
| Q11 | TPM 2.0 + TDX/SGX enclave hybrid is the foundational architecture; software-enclave fallback on hardware lacking both. |
| Q15 | Maximum Spectre/Meltdown mitigations are default; signing operations pay this cost unless the `relax-mitigations` capability is held (and audited). |
| C11 | UEFI Secure Boot is mandatory; measured boot through PCRs 0–7 (firmware) and 8+ (PaideiaOS loader/kernel extends). |
| C15 | RDSEED + RDRAND + jitter pool + `TPM2_GetRandom` mix provides entropy; the PQ subsystem consumes this. |
| `02-development-environment.md` §6.2 | Recommended PQ scheme combination is deferred to *this* document. |
| `02-development-environment.md` §6.4 | Recommended key residency tiers are deferred to *this* document. |
| `02-development-environment.md` §10.7 | CI roles `release-cutter`, `kernel-reviewer`, etc. are the human side of the quorum. |

### 0.2 New decisions in this document

| # | Question | Decision |
|---|---|---|
| PQ-Q1 | Hybrid posture | Hybrid by default everywhere — every signature is `classical ‖ PQ`; every key exchange is hybrid KEM. Pure-PQ only at the strictest boundary (long-lived release root, where size pressure forces it). |
| PQ-Q2 | Trust hierarchy structure | Capability-typed tiered hierarchy: Root → Release-line → Operational → Ephemeral, with each delegation a *signed capability* declaring the child key's scope and lifetime. |
| PQ-Q3 | Algorithm selection per role | Release artifacts: hybrid Ed25519 + ML-DSA-65 (NIST L3). Boot chain: SLH-DSA-128s (NIST L1, hash-based — no lattice assumption). Long-lived release root: SLH-DSA-256s (NIST L5, hash-based, ceremonial). TLS / confidentiality KEM: hybrid X25519 + ML-KEM-1024 (NIST L5). |
| PQ-Q4 | Key residency matrix | Root → offline HSM (FIPS 140-3 Level 3+, ceremony-only, ≥2-of-3 quorum). Release-line → networked HSM or PQ-aware KMS at the CI release runner. Boot-chain → TDX enclave (server), SGX enclave (legacy client where present), software-enclave fallback (per PQ-Q5). Ephemeral → TPM 2.0 on the release runner, per-CI-run rotation. |
| PQ-Q5 | Software enclave design | IOMMU-isolated userspace signer process; key encrypted-at-rest as a TPM-sealed blob bound to the boot PCR set; TME-MK memory encryption layered where the hardware supports it. Every signing request mediated by the supervisor; audited. |
| PQ-Q6 | KEM application scope | Universal: every confidentiality boundary (TLS, cross-host IPC bridges, audit-log transport, attestation handshakes, disk-encryption KEK wrap) uses the same hybrid X25519 + ML-KEM-1024 construction. |
| PQ-Q7 | Quorum for high-stakes signing | Operational M-of-N: Root requires ≥2-of-3 named ceremony participants physically present (HSM-side enforcement). Release-line single-signer with audit. Operational and ephemeral single-signer with audit. |
| PQ-Q8 | Attestation flow | Layered: boot attestation (TPM PCR quote + TDX MR chain where present) + software attestation (release signature chain to the root) + runtime capability attestation (supervisor-signed quote of a process's capability set at a timestamp). |
| PQ-Q9 | Key rotation policy | Hybrid: scheduled cadence per tier (Root 5y, Release-line 12mo, Boot-chain 6mo, Operational 90d, Ephemeral per-run) + event-driven rotation on compromise/anomaly. Public-key manifest carries valid-since/valid-until so historical artifacts remain verifiable. |
| PQ-Q10 | Algorithm agility / migration | Every signature carries a versioned header `{scheme_id, algorithm_id, key_id, timestamp}`; the authoritative algorithm catalog (`design/security/algorithm-catalog.md`) tracks active/deprecated/revoked schemes. Migration is graceful via the catalog and the rotation cadence; the hybrid posture is the multi-algorithm safety net. |

### 0.3 Three meta-positions

1. **Defense in depth, not defense in a single layer.** Hybrid (classical ‖ PQ), tiered hierarchy, layered attestation, scheduled + event-driven rotation, and algorithm agility all stack. No single break — algorithmic, operational, or hardware — collapses the system.

2. **The TPM 2.0 PQ extension is aspirational (H1).** As of mid-2026, `swtpm` and most TPM 2.0 implementations do not expose ML-DSA/SLH-DSA primitives. This document treats the TPM as holding *classical* attestation keys (ECDSA-P384 / RSA-3072) that *anchor* PQ signing performed elsewhere (the enclave). When TCG PQ TPM extensions ship, the TPM may take over the operational signing role; until then, the enclave is load-bearing.

3. **The software-enclave is the engineering critical path, not TDX.** Most PaideiaOS-supported i7 hardware lacks TDX (server-only) and SGX (deprecated on client). The software-enclave (PQ-Q5) is what most installations will use; TDX is opportunistic strengthening. The threat model in this document assumes software-enclave as the baseline.

---

## 1. Architectural overview

```
                ┌─────────────────────────────────────────────────────────────┐
                │  ROOT (offline)                                              │
                │   SLH-DSA-256s, FIPS 140-3 L3+ HSM, ≥2-of-3 ceremony quorum  │
                │   Signs ONLY: release-line key delegations, root rotations,  │
                │               algorithm-catalog updates, emergency revokes   │
                └─────────────────────────────┬───────────────────────────────┘
                                              │ signed delegation capability
                                              ▼
                ┌─────────────────────────────────────────────────────────────┐
                │  RELEASE-LINE                                                │
                │   Hybrid Ed25519 + ML-DSA-65, hardware-KMS / HSM at CI       │
                │   Signs: release artifacts, kernel images, manifest         │
                │           updates, audit-log epoch closes                   │
                │   Rotated annually                                          │
                └─────────────────────────────┬───────────────────────────────┘
                                              │ signed delegation capability
                                              ▼
        ┌───────────────────────────────┬─────┴────────────────────────────┐
        │                               │                                   │
        ▼                               ▼                                   ▼
 ┌────────────────┐         ┌─────────────────────┐              ┌────────────────────┐
 │ BOOT-CHAIN     │         │ AUDIT-LOG signer    │              │ TLS server         │
 │ SLH-DSA-128s   │         │ Hybrid Ed25519 +    │              │ Hybrid Ed25519 +   │
 │ TDX/SGX enclave│         │ ML-DSA-65, in       │              │ ML-DSA-65, in      │
 │ or sw-enclave  │         │ software-enclave or │              │ software-enclave   │
 │ Signs: next    │         │ TDX                 │              │ Signs: TLS         │
 │   kernel image │         │ Signs: audit log    │              │   handshakes,      │
 │   boot loader  │         │   entries; epoch    │              │   short-lived per- │
 │ Rotated 6mo    │         │   roots             │              │   connection certs │
 │                │         │ Rotated 90d         │              │ Rotated 90d        │
 └────────────────┘         └─────────────────────┘              └────────────────────┘
                                              │
                                              │ ephemeral sub-delegation
                                              ▼
                ┌─────────────────────────────────────────────────────────────┐
                │  EPHEMERAL (CI inter-stage, very short-lived)                │
                │   Ed25519 only (classical), TPM 2.0-backed                  │
                │   Signs: per-CI-run artifacts; rotated per run              │
                └─────────────────────────────────────────────────────────────┘

                ┌────────────────── ATTESTATION FLOWS ──────────────────────────┐
                │                                                                │
                │  Boot attestation:  TPM 2.0 quote of PCRs 0-23 signed by AK   │
                │                     + TDX MR chain (server only) → release-   │
                │                       line key signs the AK certificate        │
                │  Software attestation: release-line signature on artifact     │
                │                        verifiable to root via delegation cap   │
                │  Runtime cap quote: supervisor signs "process P holds         │
                │                     cap set C at time T" with operational key │
                └────────────────────────────────────────────────────────────────┘

                ┌────────────────── KEM (CONFIDENTIALITY) ──────────────────────┐
                │                                                                │
                │  Universal: hybrid X25519 + ML-KEM-1024 for all KEX:           │
                │   - TLS 1.3 (RFC 8446 + draft-ietf-tls-hybrid-design and       │
                │     successors)                                                │
                │   - Cross-host IPC bridges (D14 distributed capabilities)      │
                │   - Audit-log transport                                        │
                │   - Remote-attestation handshakes                              │
                │   - Disk-encryption KEK wrapping                               │
                └────────────────────────────────────────────────────────────────┘
```

---

## 2. Hybrid posture (PQ-Q1)

### 2.1 The hybrid rule

Every signature and every key encapsulation produced by PaideiaOS uses *both* a classical and a PQ algorithm in the same operation. Verification requires both components to pass.

For signatures: the output is `classical_sig ‖ pq_sig` over the same message digest. A verifier computes both verifications independently; the signature is valid iff *both* succeed.

For KEMs: the shared secret is derived via a combiner over both the classical Diffie-Hellman output and the PQ KEM output. The combiner is the IETF concat-and-KDF construction:

```
shared_secret = KDF(classical_dh ‖ pq_kem_secret ‖ transcript)
```

per the draft-ietf-tls-hybrid-design pattern (TODO: verify current RFC number — the draft may have advanced to final RFC by 2026-06).

### 2.2 Why hybrid

- **Cryptanalysis insurance against PQ.** ML-DSA and ML-KEM rely on the Module-LWE assumption — younger and less battle-tested than the discrete-log assumption underlying X25519/Ed25519. A future cryptanalysis breakthrough that breaks Module-LWE would be devastating *if* PaideiaOS had bet on PQ alone.
- **Cryptanalysis insurance against classical.** A cryptographically-relevant quantum computer (CRQC) would break X25519 and Ed25519 via Shor's algorithm. The PQ component preserves confidentiality and signature integrity against a CRQC.
- **Industry alignment.** IETF, NSA CNSA 2.0, NIST migration guidance all converge on hybrid as the responsible transition posture.

### 2.3 Pure-PQ exceptions

Pure PQ is used at the strictest boundaries where signature size forces it:

- **Long-lived release root (SLH-DSA-256s):** the root signs few things (delegation caps, catalog updates) over a 5-year lifetime; the ~29 KB signature is amortized; adding a classical co-signature is a noise burden with no proportional benefit (the root is offline and ceremonial — the threat model is fundamentally different).
- **Some constrained-message protocols** (TBD; none currently identified).

Where pure PQ is used, the algorithm choice itself is hash-based (SLH-DSA), not lattice-based — minimizing the risk if the lattice family is broken.

### 2.4 Cost summary

| Operation | Classical-only | Hybrid (PaideiaOS default) | Pure PQ |
|---|---|---|---|
| Release manifest signature | ~64 B (Ed25519) | ~3.4 KB (Ed25519 + ML-DSA-65) | ~3.3 KB (ML-DSA-65) |
| Boot loader signature | ~64 B (Ed25519) | n/a (PQ-Q3 pure-PQ for boot chain) | ~7.8 KB (SLH-DSA-128s) |
| TLS handshake KEM | ~32 B (X25519) | ~1.6 KB (X25519 + ML-KEM-1024) | ~1.6 KB (ML-KEM-1024) |
| Root signature | ~64 B (Ed25519) | n/a (PQ-Q3 pure-PQ for root) | ~29 KB (SLH-DSA-256s) |

---

## 3. Trust hierarchy (PQ-Q2)

### 3.1 The four tiers

| Tier | Algorithm | Lifetime | Residency | Quorum | Signs |
|---|---|---|---|---|---|
| **Root** | SLH-DSA-256s (pure PQ) | 5 years | Offline HSM (FIPS 140-3 L3+) | ≥2-of-3 ceremony | Release-line delegations; root rotations; algorithm-catalog updates; emergency revocations. |
| **Release-line** | Ed25519 + ML-DSA-65 (hybrid) | 12 months | Networked HSM or PQ-aware KMS at CI runner | 1-of-N release-cutter role | Release artifacts; kernel images; audit-log epoch closes; AK certificates for boot attestation; delegations to operational tier. |
| **Operational** (boot-chain, audit-log, TLS server, identity service) | per role; mostly hybrid Ed25519 + ML-DSA-65; boot-chain pure SLH-DSA-128s | Boot-chain 6 months, others 90 days | TDX/SGX enclave where present; software-enclave fallback (PQ-Q5) on client | 1-of-N | Role-specific artifacts (kernel images for boot-chain; audit entries for audit-log signer; TLS handshakes for TLS server; capability attestations for supervisor). |
| **Ephemeral** | Ed25519 (classical only) | per CI run / sub-day | TPM 2.0 on the release runner | 1-of-N | CI inter-stage signatures; never user-visible artifacts. |

### 3.2 Capability-typed delegations

Each parent-to-child delegation is a *signed capability* declaring the child's scope. The delegation format:

```
DelegationCapability {
  parent_key_id      : KeyId
  child_key_id       : KeyId
  child_pubkey       : <algorithm-specific public key bytes>
  scope              : EffectSet               // what the child may sign
  valid_from         : timestamp_t
  valid_until        : timestamp_t
  rotation_cadence   : duration_t              // for scheduled rotation
  attestation_policy : AttestationPolicy       // which attestation paths apply
  algorithm_catalog_version : u32              // the catalog at time of delegation
  parent_signature   : Signature               // parent signs all the above
}
```

The `scope` is an algebraic effect set per the assembler's effect system (Q-A3) — e.g., `!{sign_release_artifact, sign_audit_epoch, sign_ak_cert}`. The child can only sign artifacts whose required effects are a subset of the scope. The kernel's PQ-signer effect handler verifies this on every signature.

### 3.3 Why capability-typed

- Delegation is the same conceptual mechanism as capability minting (per `linearity-and-tags.md` §7) — the same audit, the same revocation discipline.
- The scope effect set is type-checked by the elaborator (Q-A4); a request to sign an artifact whose effects exceed the scope is a compile-time error.
- Revocation cascades through the tree (per CAP-Q8) — revoking a release-line key automatically invalidates every operational key delegated under it.
- The audit log records every delegation; the chain from artifact to root is reconstructible by walking the delegation tree.

### 3.4 The algorithm-catalog reference

Every delegation carries the algorithm-catalog version at the time of issuance. When the catalog updates (e.g., a primitive is deprecated), existing delegations remain valid until rotation but new artifacts must use the current catalog. This bounds the migration window precisely.

---

## 4. Algorithm selection per role (PQ-Q3)

### 4.1 The chosen primitives

| Role | Primitive | NIST Level | Signature / KEM size | Rationale |
|---|---|---|---|---|
| Release artifact signature | hybrid Ed25519 + ML-DSA-65 | 3 | ~3.4 KB | Pragmatic balance; ML-DSA-65 is the FIPS-204 mid level; classical hedge against PQ break. |
| Boot-chain signature | SLH-DSA-128s | 1 | ~7.8 KB | Pure hash-based — no lattice assumption; minimal cryptanalysis risk; size acceptable for the small set of boot artifacts. |
| Long-lived release root | SLH-DSA-256s | 5 | ~29 KB | Strongest hash-based; signs few things; ceremonial; classical co-signature offers no proportional benefit. |
| Operational TLS handshake KEM | hybrid X25519 + ML-KEM-1024 | 5 | ~1.6 KB | Universal KEM (per PQ-Q6); level 5 because KEM extra strength is cheap and protects against harvest-now-decrypt-later. |
| Operational signing (audit log, identity, TLS cert) | hybrid Ed25519 + ML-DSA-65 | 3 | ~3.4 KB | Same as release artifact; one primitive to audit. |
| Ephemeral (CI inter-stage) | Ed25519 only | n/a | ~64 B | Lifetime < 24h; harvest-now-decrypt-later not applicable; the audit log is the policy enforcer. |

### 4.2 Why ML-DSA-65 not ML-DSA-87

ML-DSA-87 (NIST L5) signatures are ~4.6 KB versus ~3.3 KB at L3. The extra ~1.3 KB per signature aggregates substantially over a typical release manifest's hundred-plus signed entries. ML-DSA-65 is widely considered sufficient for current threat models; if future cryptanalysis pushes us up, the algorithm-agility mechanism (PQ-Q10) accommodates the migration.

### 4.3 Why SLH-DSA-128s not the other SLH-DSA variants

SLH-DSA comes in `s` (small signature, slow signing) and `f` (fast signing, larger signature) at each of three levels (128, 192, 256). For the boot chain:
- The number of signatures is small (one per release).
- Signing is rare (release events).
- Verification is on every boot — fast verification matters.

`SLH-DSA-128s` has small signature (good for the bandwidth-constrained boot loader) and slow signing (acceptable for rare events). Fast verification is the same across variants.

For the root, SLH-DSA-256s gives the strongest hash-based strength; the ~29 KB signature is amortized over the root's lifetime.

### 4.4 Why ML-KEM-1024 not ML-KEM-768

The KEM extra strength is cheap: ML-KEM-1024 ciphertext is ~1.6 KB versus ML-KEM-768's ~1.2 KB — a 400 B difference on the handshake. The level-5 strength gives strong defense against harvest-now-decrypt-later for long-lived secrets (the IETF guidance prefers level 5 for KEMs precisely because the cost is asymmetric).

---

## 5. Key residency matrix (PQ-Q4)

### 5.1 Per-tier residency

#### Root: offline HSM

- FIPS 140-3 Level 3 or higher.
- Physically isolated: not network-connected; activated via physical-presence ceremony.
- HSM enforces the ≥2-of-3 quorum at the session level (no individual party can complete a sign operation).
- Located in a tamper-evident safe, geographically distinct from the CI infrastructure.
- The HSM token's *public key* lives in the algorithm catalog; the private never leaves the HSM.

Recommended HSM vendor: TODO: verify HSM vendors with ML-DSA / SLH-DSA support — current candidates include YubiHSM 2 firmware extensions (TODO: verify status), AWS CloudHSM, Thales Luna, Entrust nShield. Selection deferred to `design/security/hsm-procurement.md` (future).

#### Release-line: networked HSM or PQ-aware KMS at CI runner

- A networked HSM mounted on the CI release runner; or
- A cloud KMS that supports ML-DSA-65 with HSM-backed key storage.

**Open issue S4 (KMS support for ML-DSA):** Current cloud KMS coverage for ML-DSA is uncertain; SLH-DSA support is more common (some PQC migration tooling has landed). If no acceptable PQ-aware KMS exists at phase-2 rollout, the fallback is a self-hosted networked HSM. The decision is captured in `design/security/release-line-key-management.md` (to write).

#### Boot-chain: TDX/SGX enclave + software-enclave fallback

- On hardware with TDX (Sapphire Rapids+ server): the boot-chain signer runs inside a TD. The TPM attests the TD at boot; the TD unseals its signing key from a TPM-sealed blob bound to its measurement.
- On hardware with SGX (legacy client, Tiger Lake/Rocket Lake): the boot-chain signer runs as an enclave. SGX deprecation on newer client means this path is legacy-only.
- On hardware without either: the software-enclave fallback (PQ-Q5; §6).

#### Ephemeral: TPM 2.0 on the release runner

- The TPM holds a fresh Ed25519 key per CI run.
- Rotated at the end of each run.
- Used only for CI inter-stage signatures (e.g., signing the output of stage N for consumption by stage N+1); never for user-visible artifacts.

### 5.2 Boundary crossings

| From → To | Mechanism | Notes |
|---|---|---|
| HSM → release-line | Manual: HSM-signed delegation capability transported on a USB key during a ceremony; installed in the CI runner's KMS. | Per ceremony, audited. |
| Release-line → boot-chain | The release-line signs the boot-chain key's delegation capability during the release-line's CI process. | Routine; per release-line rotation. |
| Release-line → audit-log signer | Same pattern. | Per audit-log rotation (90 days). |
| Boot-chain → kernel image | Routine signing operation per release. | The kernel image carries the boot-chain signature. |
| TPM → enclave (sealing/unsealing) | TPM unseals the enclave's key blob bound to PCR state. | Per enclave start. |

---

## 6. Software enclave design (PQ-Q5)

### 6.1 Threat model

The software enclave defends signing keys on PaideiaOS-supported client hardware that lacks TDX (server-only) and SGX (deprecated). The defenders are:

- The kernel and the supervisor (part of the TCB).
- The IOMMU (preventing DMA-based memory snooping).
- The TPM (sealing the key at rest).
- TME-MK / TME (Total Memory Encryption with Multiple Keys) where present, encrypting DRAM cells.

A kernel compromise reveals the key — this is acknowledged. The software enclave is *not* equivalent to hardware TDX; it is a defense-in-depth layer that raises the cost of key extraction on client hardware.

### 6.2 The signer process

Architecture:

```
┌──────────────────────────────────────────────────────────────────┐
│  Userspace                                                        │
│                                                                   │
│  ┌──────────────────┐    ┌──────────────────┐                   │
│  │ Caller process   │ ── │   Supervisor     │                   │
│  │ (audit, TLS,…)   │ →  │  - audits        │                   │
│  └──────────────────┘    │  - rate-limits   │                   │
│                          │  - dispatches    │                   │
│                          └─────────┬────────┘                   │
│                                    │ SignReq                    │
│                                    ▼                             │
│                          ┌──────────────────────┐               │
│                          │  Signer process      │               │
│                          │  - holds unsealed key│               │
│                          │  - in IOMMU isol.    │               │
│                          │  - TME-MK enc memory │               │
│                          │  - never logs key    │               │
│                          └──────────────────────┘               │
└──────────────────────────────────────────────────────────────────┘
```

### 6.3 Key lifecycle in the software enclave

1. **At enclave startup** (system boot): the kernel measures the signer process binary; extends PCR-12 with the measurement. The signer's TPM-sealed key blob is keyed to a specific PCR-12 value; if the boot path or signer binary changed, the seal fails and the signer halts.

2. **Key unseal**: the signer process invokes `TPM2_Unseal` on the sealed blob; the TPM verifies the PCR state and returns the unsealed key into the signer's memory.

3. **Memory protection**:
   - The signer's address space is IOMMU-isolated: no peripheral can read its memory via DMA.
   - Where TME-MK is available (Tiger Lake+ client; Sapphire Rapids+ server), the signer's pages are encrypted with a TME-MK key-id derived from the TPM-sealed blob; physical-memory snooping is defeated.
   - The signer holds the unsealed key in a designated cache-resident region with `clflushopt` discipline to limit DRAM exposure (best-effort).

4. **Signing**: requests arrive over a typed IPC channel from the supervisor. The signer signs and replies; the audit log records the operation.

5. **Key rotation** (per PQ-Q9 cadence): a new sealed blob is provisioned; the signer is restarted with the new blob.

### 6.4 What this does and does not defend

| Threat | Defended? |
|---|---|
| Rogue device DMA reading signer memory | Yes (IOMMU). |
| Cold-boot RAM attack | Partial: TME-MK encrypts DRAM; without TME-MK, key is at risk. |
| Kernel CVE allowing memory read | No — kernel is in TCB. |
| Stolen TPM-sealed blob | No, the blob is encrypted to the TPM and bound to PCRs. |
| Stolen TPM-sealed blob *and* TPM | Defends via PCR binding — must boot the exact measured-boot path. |
| Side-channel: power, EM, timing | Partial: cache-resident discipline limits some side channels; not bulletproof. |
| Supply-chain insertion in the signer binary | The measurement-bound PCR detects on next boot. |

The software enclave is *meaningfully stronger* than a kernel-side signing service (the alternative without an enclave) but *meaningfully weaker* than hardware TDX. This document explicitly does not claim equivalence.

### 6.5 Software enclave attestation

Remote parties can attest the software enclave via the layered attestation flow (PQ-Q8). The boot attestation includes PCR-12 (the signer measurement); a verifier with the project's catalog of known-good measurements can verify the signer is unmodified.

---

## 7. KEM application scope (PQ-Q6)

### 7.1 Universal KEM

The hybrid X25519 + ML-KEM-1024 construction is the *only* confidentiality primitive in PaideiaOS. It applies to:

1. **TLS 1.3 handshakes.** Following draft-ietf-tls-hybrid-design (or its RFC successor) for the wire-format combiner.
2. **Cross-host IPC bridges (D14).** The bridge node (per `wait-free-dataflow.md` §15) negotiates a session via the same KEM construction; thereafter the bridge uses authenticated encryption with the derived key.
3. **Audit-log transport.** The audit log's append channel to a remote archive uses the same KEM at session start.
4. **Remote-attestation handshakes.** Establishing a confidential channel to a remote verifier.
5. **Disk-encryption key wrapping.** A volume's master key is wrapped under a KEM-derived key (where the KEK is itself rotated, the wrap operation is the universal KEM).

### 7.2 The combiner

Following draft-ietf-tls-hybrid-design's pattern:

```
1. classical_shared = X25519(client_eph_priv, server_eph_pub)
2. pq_shared        = ML-KEM-1024.Encap(server_pq_pub)        // returns (ct, ss)
3. shared_secret    = HKDF-Extract(salt=0, ikm = classical_shared ‖ pq_shared)
4. handshake_secret = HKDF-Expand-Label(shared_secret, "handshake", transcript_hash)
```

The handshake transcript binds the shared secret to the full exchange, defeating downgrade attacks where an attacker could try to substitute one component.

### 7.3 Wire format

The client offers a hybrid group identifier in the TLS supported_groups extension (e.g., `x25519_mlkem1024`). If the server supports it, the handshake proceeds; if not, the connection is refused. PaideiaOS does *not* fall back to classical-only; the project's security posture mandates PQ presence.

This is a *deliberate non-interoperability* with classical-only peers; mitigated by the cross-host IPC bridge supporting a "compatibility translation" mode where the bridge runs both PQ-on-internal-side and classical-on-external-side under an explicitly captured policy capability.

### 7.4 Long-term keys for protocol identities

Long-term identity keys (server certificates, client certificates if applicable) follow the operational signature scheme: hybrid Ed25519 + ML-DSA-65. The KEM is used only for ephemeral key exchange; identity authentication is via signatures.

---

## 8. Quorum and ceremony (PQ-Q7)

### 8.1 Root ceremony

- ≥2-of-3 named participants must be physically present at the HSM.
- The HSM enforces this via dual-authentication at the session level (each participant has their own credential; the session requires two).
- The ceremony script is in `design/security/root-ceremony.md` (to write): step-by-step protocol, witness sign-off, video recording policy (TBD), audit-log entry.
- Each ceremony produces a signed record published to the audit log: timestamp, participants (named), operation, witnesses.

### 8.2 Release-line operations

- A single named member of the `release-cutter` role authorizes the operation.
- Every release-line operation is audited (no batched signatures).
- The `release-cutter` role grants are themselves capabilities, granted by the supervisor; revocation cascades.

### 8.3 Operational and ephemeral

- Single-signer with audit.
- The audit log is the safety net; suspicious signing patterns are detectable from the log.

### 8.4 The CI role model

The CI roles defined in `02-development-environment.md` §10.7 (contributor, kernel-reviewer, toolchain-reviewer, ipc-reviewer, release-cutter, infra-admin) are the human-side of the quorum. The PQ trust root respects these roles:

- `release-cutter` may trigger release-line operations.
- `infra-admin` may not (separation of duties).
- `kernel-reviewer` may not (separation of duties).

### 8.5 Lost-quorum recovery

If a root quorum participant becomes unavailable (loss, death, departure), recovery requires:
1. Two remaining participants invoke the root ceremony.
2. They issue a *rotation delegation* that establishes a new root key with a new quorum.
3. The new root re-signs all active release-line delegations.
4. The old root key is destroyed via an HSM-side `key_destroy` operation, audited.

The recovery protocol is rare but must be exercised: an annual *recovery drill* is mandated in `design/security/operations.md` (to write).

---

## 9. Layered attestation (PQ-Q8)

### 9.1 The three layers

| Layer | What is attested | Mechanism | Verifier needs |
|---|---|---|---|
| **Boot** | The hardware-software stack measured during boot | TPM 2.0 quote of PCRs 0–23 signed by AK + (on TDX) MR chain | TPM AK certificate chained to release-line; the known-good PCR set for the running PaideiaOS version. |
| **Software** | The PaideiaOS artifacts installed | Hybrid Ed25519 + ML-DSA-65 release-line signature | Release-line public key (verifiable via root delegation cap). |
| **Runtime** | The capability set held by a process at a specific time | Supervisor signs a quote `"P holds caps C at T"` with operational signing key | The supervisor's operational pubkey; the quote format spec. |

### 9.2 Boot attestation

Standard TCG remote attestation:

```
Verifier ── nonce ──► PaideiaOS-host
                       │
                       │ TPM2_Quote(PCRs 0-23, nonce)
                       │  → quote signed by AK
                       │
              ◄── quote + AK cert + (on TDX) MR chain ──┘

Verifier:
  1. Verify AK cert chains to release-line pubkey, which chains to root via delegation.
  2. Verify quote signature over (PCRs, nonce, AK pubkey).
  3. Compare PCRs to expected values for the running PaideiaOS version.
  4. (On TDX) Verify MR chain.
```

### 9.3 Software attestation

Every release artifact carries its hybrid signature plus a *provenance attestation* (SLSA v1.0 per `02-development-environment.md` §11.3). A verifier checks:

```
1. Verify hybrid signature on artifact (Ed25519 + ML-DSA-65).
2. Verify signature was made with a release-line key (key_id resolves via algorithm catalog).
3. Verify release-line delegation capability (signed by root).
4. Verify root pubkey matches the project's published trust root.
5. Verify SLSA provenance attestation (referenced CI run, reproducible-build attestation, DDC attestation).
```

### 9.4 Runtime capability attestation

A novel PaideiaOS contribution. A process can request the supervisor sign a quote:

```
CapabilityQuote {
  process_id     : ProcessId
  capability_set : list of (kind, rights_bitmask, derivation_path)
  timestamp      : timestamp_t
  nonce          : bytes
  supervisor_sig : Signature        // operational signing key
}
```

A remote verifier can ask: "does process X hold capability Y?" The supervisor signs the quote; the verifier checks the signature chains to the trust root. The quote is timestamped because capability sets change over time (mint, retype, revoke).

Use cases:
- A client wants to know its connected PaideiaOS server is running a specific driver version (the driver process's caps are public to attest).
- A distributed-capability federation (D14) verifies a remote process actually holds the capability before honoring its operations.

The runtime attestation is *phase 2* — the phase-1 trust root ships boot + software attestation; runtime comes online with the rest of the capability infrastructure.

---

## 10. Key rotation (PQ-Q9)

### 10.1 Scheduled cadence

| Tier | Scheduled cadence | Trigger |
|---|---|---|
| Root | 5 years | Cadence + algorithm deprecation. |
| Release-line | 12 months | Cadence + release-cutter departure + suspicion. |
| Boot-chain | 6 months | Cadence + enclave attestation anomaly. |
| Operational | 90 days | Cadence + role change + suspicion. |
| Ephemeral | Per CI run | Automatic. |

### 10.2 Event-driven rotation

Triggers:
- Detected key compromise (forensic evidence).
- Suspected enclave breach (anomaly in attestation).
- Software bug discovered in the signing path (the signer code is part of the TCB).
- Operational change (a release-cutter departs the project; the release-line key rotates).
- Algorithm deprecation (the catalog marks a primitive deprecated; affected keys rotate to the successor scheme).

### 10.3 The public-key manifest

Every published rotation appends to the `public-key-manifest.json` (signed by the root):

```
{
  "key_id": "release-line-2026-Q2",
  "scheme_id": "paideia-pq-hybrid-v1",
  "algorithm_ids": ["ed25519", "ml-dsa-65"],
  "public_keys": { "ed25519": "...", "ml-dsa-65": "..." },
  "valid_from": "2026-04-01T00:00:00Z",
  "valid_until": "2027-04-01T00:00:00Z",
  "delegation_cap": "<signed by root>",
  "status": "active" | "deprecated" | "revoked"
}
```

Historical artifacts remain verifiable: a verifier looks up the artifact's `key_id`, finds the corresponding manifest entry, uses the listed public keys to verify. After a key's `valid_until`, the status moves to `deprecated`; after a project-determined window (default 5 years), to `revoked` (and historical artifacts signed with that key are no longer trusted).

### 10.4 Rotation overlap

During a rotation window (typically 7 days), both old and new keys are *active* — artifacts may be signed with either. After the window, only the new key signs; the old key becomes `deprecated`. This avoids races where in-flight CI processes use the old key just before rotation.

---

## 11. Algorithm agility and migration (PQ-Q10)

### 11.1 The versioned signature header

Every signature emitted by PaideiaOS is preceded by a 32-byte header:

```
SignatureHeader {
  magic            : u32 = 0x50514153    // "PQAS"
  version          : u16 = 1
  scheme_id        : u16   // index into algorithm catalog
  algorithm_ids    : u32 (4 bytes, one per primitive in the scheme)
  key_id           : u64
  timestamp        : u64
}
```

The header is bound into the signature by being prepended to the message before signing (signature input = header ‖ message). A verifier reads the header, consults the algorithm catalog, and selects the correct verification routine.

### 11.2 The algorithm catalog

`design/security/algorithm-catalog.md` (to write) is the authoritative list of schemes. Each entry:

```
scheme paideia-pq-hybrid-v1 = {
  classical: Ed25519
  pq: ML-DSA-65
  combiner: concat-then-sign
  status: active
  introduced: 2026-04-01
  deprecated: null
  revoked: null
}

scheme paideia-pq-hash-v1 = {
  pq: SLH-DSA-128s
  status: active
  ...
}
```

The catalog itself is signed by the root (it is an artifact whose verifier needs an out-of-band trust anchor: the root's published pubkey). Catalog updates trigger a root-ceremony event.

### 11.3 Migration scenarios

**ML-DSA cryptanalysis (lattice family broken):** Catalog marks `ML-DSA-65` deprecated; introduces a successor scheme (e.g., `paideia-pq-hybrid-v2 = Ed25519 + Falcon` or `Ed25519 + future-PQ`). Existing release-line keys rotate via PQ-Q9 cadence + event-driven; new artifacts use v2. Historical artifacts retain v1 verification capability until the root-determined sunset.

**SLH-DSA broken (hash family broken):** This would be unprecedented (the underlying hash assumption is very conservative). If it happens, the boot-chain and root schemes migrate; root migration requires a ceremony. The hybrid posture at the operational tier means PaideiaOS continues operating during migration.

**Classical (Ed25519, X25519) broken:** A CRQC arrives. The classical components are dropped from new artifacts; the hybrid posture becomes pure-PQ at all tiers. The KEM migrates to pure ML-KEM-1024.

### 11.4 The downgrade-attack concern

An attacker who can manipulate the scheme negotiation could try to downgrade a peer to a known-broken scheme. Defenses:

- The catalog status is signed by the root; deprecated/revoked schemes cannot be silently re-marked active.
- The KEM combiner binds the transcript (per §7.2); downgrade in the KEM is detected.
- Signature verification consults the *current* catalog; signatures under deprecated schemes are reported as such.

---

## 12. Wire formats

### 12.1 Hybrid signature wire format

```
hybrid-signature = SignatureHeader ‖ classical_sig ‖ pq_sig

with classical_sig and pq_sig being byte-strings whose lengths are determined by the SignatureHeader's algorithm_ids.
```

A verifier parses the header, looks up the algorithm IDs in the catalog to determine the lengths, splits the signature, and runs both verifications.

### 12.2 Hybrid KEM wire format (in TLS 1.3 extension)

Per IETF draft (TODO: verify current RFC):

```
ClientHello.extension.key_share:
  group = x25519_mlkem1024 (codepoint TBD; project-assigned in interim)
  key_exchange = classical_pubkey ‖ pq_pubkey

ServerHello.extension.key_share:
  group = x25519_mlkem1024
  key_exchange = classical_pubkey ‖ pq_ciphertext
```

The combiner derivation per §7.2 produces the shared secret.

### 12.3 Delegation capability wire format

```
DelegationCap = SignatureHeader ‖ child_pubkey ‖ scope_bytes ‖ valid_from ‖ valid_until ‖ rotation_cadence ‖ catalog_version ‖ parent_signature
```

The parent signature covers all preceding fields. The cap is itself an artifact in the audit log.

---

## 13. Integration with surrounding subsystems

### 13.1 With the audit log (E19)

- Every root ceremony, release-line operation, key rotation, software-enclave start, attestation request, delegation, and revocation emits an audit entry.
- The audit log signer is itself a tier-3 operational key (rotated 90d).
- Audit log epochs are closed periodically by signing an epoch-summary with the release-line key (binds the audit log to the release-line chain).

### 13.2 With the capability system

- Delegation capabilities are first-class capabilities (per `linearity-and-tags.md`); they live in the descriptor table; they participate in the derivation tree; they revoke via the same mechanism as other capabilities.
- The `sign` operation is an algebraic effect (per Q-A3) requiring a delegation capability with the matching scope.
- A process holding `relax-mitigations` (per Q15) for the signer's runtime is logged with every signature.

### 13.3 With the IPC primitive

- Sign requests are typed IPC messages on a `Channel(SignRequestSchema)` from caller to signer.
- The signer's session type is `↓SignRequest . ↑SignResponse . end` (per IPC §6.2).
- Slot-cap discipline (IPC §8) applies: callers hold slot-caps for the signer channel; this is the rate-limiting mechanism.

### 13.4 With the boot path (C1, C11)

- The UEFI loader (`paideia-loader.efi`) is signed with the boot-chain key.
- The boot-chain key's delegation cap is embedded in the loader.
- The loader extends PCRs with the kernel image measurement.
- The TPM attests the boot path to the kernel before it accepts the unsealing of subsequent secrets.

### 13.5 With the network stack (E7, E9)

- TLS 1.3 server certificates carry hybrid Ed25519 + ML-DSA-65 signatures.
- The TLS handshake uses hybrid X25519 + ML-KEM-1024 KEM (per §7).
- The TLS code is in the network-stack server (userspace per pillar 3), with the signing key held in a software-enclave-style isolation.

---

## 14. paideia-as implementation

### 14.1 Module layout

`src/userspace/pq-crypto/` is the userspace PQ crypto subsystem:

```
src/userspace/pq-crypto/
├── ml_dsa.s          # ML-DSA-65 signing / verification
├── ml_kem.s          # ML-KEM-1024 encapsulation / decapsulation
├── slh_dsa.s         # SLH-DSA-128s and 256s
├── ed25519.s         # classical component
├── x25519.s          # classical KEM component
├── hybrid_sig.s      # hybrid signature composition
├── hybrid_kem.s      # hybrid KEM composition + combiner
├── catalog.s         # algorithm catalog reader + verifier
├── effects.s         # Sign / Verify / Encap / Decap effect declarations
└── audit.s           # audit emission for crypto ops
```

`src/userspace/tls/` is the TLS 1.3 implementation with the hybrid handshake.

`src/userspace/sw-enclave/` is the software enclave per PQ-Q5.

`src/userspace/supervisor/pq-trust/` is the supervisor's PQ-trust subsystem managing the trust hierarchy.

### 14.2 Calling convention integration

Sign and verify operations dispatch through the algebraic-effect handler (per Q-A3); the handler in R15 routes the request to the local signer process (for sign requests) or the catalog verifier (for verify operations). R12 carries the delegation capability authorizing the operation; R13 carries the message reference.

### 14.3 Vectorization

ML-DSA, ML-KEM, and SLH-DSA all have AVX-512-vectorized implementations available; SLH-DSA additionally benefits from AVX-512 IFMA (where present) and from VAES for hash acceleration. The paideia-as implementation will use AVX-512 paths on aspirational and recommended-client tiers; AVX2 fallback on minimum tier (per `linearity-and-tags.md` §1.4 / `02-development-environment.md` §10.5).

### 14.4 Phase-1 vs phase-2 split

Phase 1 (NASM bootstrap):
- Hybrid signing for release artifacts (basic, no rotation yet).
- TLS handshake with classical X25519 only (the hybrid KEM is phase 2).
- No software enclave (signing keys held by the supervisor with kernel-mediated isolation).
- No runtime capability attestation.

Phase 2 (paideia-as coexistence):
- Full hybrid KEM in TLS.
- Software enclave with IOMMU + TPM seal.
- Algorithm catalog and migration machinery.
- Runtime capability attestation.

Phase 3 (paideia-as canonical):
- TME-MK integration in software enclave.
- Threshold-signature evaluation (whether to migrate to threshold PQ if standards mature).

---

## 15. Performance budget

| Operation | Budget | Substrate |
|---|---|---|
| ML-DSA-65 sign | ≤ 100 µs | bare-metal Sapphire Rapids w/ AVX-512 |
| ML-DSA-65 verify | ≤ 30 µs | bare-metal |
| SLH-DSA-128s sign | ≤ 50 ms | bare-metal (slow signing is fine for boot chain) |
| SLH-DSA-128s verify | ≤ 100 µs | bare-metal (fast verify matters) |
| SLH-DSA-256s sign | ≤ 500 ms | bare-metal (ceremonial; non-critical path) |
| SLH-DSA-256s verify | ≤ 300 µs | bare-metal |
| ML-KEM-1024 encap | ≤ 30 µs | bare-metal |
| ML-KEM-1024 decap | ≤ 30 µs | bare-metal |
| TLS hybrid handshake round-trip | ≤ 1 ms | bare-metal |
| Software-enclave sign overhead | ≤ 50 µs (over the bare crypto) | bare-metal |
| Audit emission per signature | ≤ 10 ns | bare-metal |

Budgets are aspirational; baselines come from `design/security/perf-baselines.md` (future). The Q15 max-mitigations posture may regress these by 5–20% on the wrapped path; the perf-baseline measurements distinguish.

---

## 16. Verification strategy

### 16.1 Test categories

- **Unit tests** (host-side) for each primitive (signing / verifying / KEM ops against known-answer test vectors from NIST FIPS 203/204/205).
- **Hybrid composition tests** verifying the combiner against published test vectors (TODO: verify presence of published vectors for the IETF hybrid construction).
- **Catalog evolution tests**: synthetic catalog updates that deprecate schemes; verify deployed verifiers handle the transition.
- **Quorum-procedure tests**: simulated root-ceremony scripts with property-based attempts to bypass.
- **Attestation tests**: simulated boot paths producing PCR sequences; verifier must accept good, reject tampered.
- **Performance regression**: against the §15 baselines.

### 16.2 Cross-system property tests

- Property: a signature produced by tier T is verifiable iff the delegation chain from artifact's key to root is intact and unrevoked.
- Property: a TLS handshake with hybrid KEM produces shared secrets equal on both sides; transcripts cannot be downgraded silently.
- Property: a sealed software-enclave key cannot be extracted with read access to user memory (this is property-tested by an adversarial harness that simulates a kernel-CVE-equivalent).

### 16.3 Ceremony rehearsal

The annual recovery drill (per §8.5) is treated as a verification event: the team runs the root recovery protocol against the test HSM, audits the result, and updates `design/security/operations.md` with any procedural failures discovered.

### 16.4 NIST validation

PaideiaOS aims for FIPS 203/204/205 validation of its PQ implementations (TODO: confirm validation budget; the lab fees and timeline are non-trivial). Until validation, the primitives are clearly marked as "claimed conformant".

---

## 17. Open issues

| ID | Issue | Resolution location |
|---|---|---|
| PQ-O1 | KMS support for ML-DSA (S4 from dev-env) — uncertain which cloud KMS providers will support ML-DSA-65 in time for phase-2 release-line bring-up. | `design/security/release-line-key-management.md` (to write) |
| PQ-O2 | TPM 2.0 PQ extension status (H1) — `swtpm` and the TCG WG draft are evolving; revisit at phase 2. | `design/security/tpm-pq-tracking.md` (to write) |
| PQ-O3 | TDX upstream usability (H2) — when is end-to-end KVM-TDX reliable on stock Linux + QEMU? Affects whether the boot-chain signer can use TDX in CI today. | `design/security/tdx-tracking.md` (to write) |
| PQ-O4 | EDK2 PQ Secure Boot status (H6) — whether the OVMF / EDK2 path can ingest PQ-signed PKs at the firmware level; affects whether the boot-chain can be all-PQ or remains classical at the firmware boundary. | `design/security/secure-boot.md` (to write) |
| PQ-O5 | HSM vendor selection for the root — which vendor supports SLH-DSA-256s with the required quorum semantics. | `design/security/hsm-procurement.md` (to write) |
| PQ-O6 | Algorithm catalog format and storage — is it a JSON file in a git repo signed by the root? Or a structured PaideiaOS artifact? | `design/security/algorithm-catalog.md` (to write) |
| PQ-O7 | Root ceremony script — step-by-step protocol for HSM operations; recovery drill cadence. | `design/security/root-ceremony.md` (to write) |
| PQ-O8 | TLS hybrid group codepoint — IETF draft codepoint vs. project-assigned interim codepoint; coordinate with IANA. | `design/security/tls-config.md` (to write) |
| PQ-O9 | Side-channel hardening for the software-enclave signer — what specific mitigations beyond IOMMU and TME-MK; cache-side-channel analysis. | `design/security/side-channels.md` (to write) |
| PQ-O10 | Distributed signing readiness — when threshold ML-DSA / SLH-DSA reach deployment maturity, can PaideiaOS migrate? | revisit phase 3 |
| PQ-O11 | The runtime capability-attestation format and verifier API — phase-2 deliverable, design needed. | `design/security/runtime-attestation.md` (to write) |
| PQ-O12 | NIST validation budget and timeline — pursue or skip. | `design/security/fips-validation.md` (to write) |
| PQ-O13 | Quantum-readiness migration plan — when to drop the classical hedge entirely (the date when a CRQC is plausible). | revisit periodically |
| PQ-O14 | The runtime capability-attestation's interaction with sealed capabilities (CAP-Q9) — can a sealed cap appear in a quote? With what information? | `design/security/runtime-attestation.md` |
| PQ-O15 | Phase-1 fallback API — what subset of the phase-2 PQ trust root is available in phase 1. | `design/security/phase1-api.md` (to write) |

---

## 18. References

### 18.1 PQ algorithms

- NIST FIPS 203: *Module-Lattice-Based Key-Encapsulation Mechanism Standard* (ML-KEM, Kyber). 2024.
- NIST FIPS 204: *Module-Lattice-Based Digital Signature Standard* (ML-DSA, Dilithium). 2024.
- NIST FIPS 205: *Stateless Hash-Based Digital Signature Standard* (SLH-DSA, SPHINCS+). 2024.
- Bernstein, D. J. et al. *SPHINCS+: Submission to the 3rd round of the NIST PQC project*. 2020.
- Ducas, L. et al. *CRYSTALS-Dilithium*. 2018 (submission and follow-ups).

### 18.2 Hybrid constructions

- Stebila, D., Fluhrer, S., Gueron, S. *Hybrid key exchange in TLS 1.3*. IETF draft-ietf-tls-hybrid-design (current revision; TODO: verify final RFC number).
- Bindel, N., Brendel, J., Fischlin, M., Goncalves, B., Stebila, D. *Hybrid Key Encapsulation Mechanisms and Authenticated Key Exchange*. PQCrypto 2019.
- Aviram, N., Gellert, K., Jager, T. *Session Resumption Protocols and Efficient Forward Security for TLS 1.3 0-RTT*. EUROCRYPT 2019.

### 18.3 Attestation

- TCG Trusted Platform Module Library Specification, Family 2.0, current revision.
- TCG PC Client Platform Firmware Profile Specification, current revision.
- Intel® Trust Domain Extensions (TDX) Module Architecture Specification, current revision.
- Coker, G. et al. *Principles of Remote Attestation*. International Journal of Information Security, 2011.

### 18.4 Capability-based security

- Klein, G. et al. *seL4: Formal Verification of an OS Kernel*. SOSP 2009.
- Miller, M. S. *Robust Composition*. PhD thesis, Johns Hopkins, 2006.

### 18.5 Standards bodies and policy

- NIST Special Publication 800-208: *Recommendation for Stateful Hash-Based Signature Schemes*. 2020.
- NSA Commercial National Security Algorithm Suite 2.0 (CNSA 2.0). 2022.
- NIST IR 8413: *Status Report on the Third Round of the NIST PQC Standardization Process*. 2022.
- IETF RFC 8446: *The Transport Layer Security (TLS) Protocol Version 1.3*. 2018.

### 18.6 Software-enclave and confidential computing

- Confidential Computing Consortium. *A Technical Analysis of Confidential Computing*. v1.3, 2022.
- McKeen, F. et al. *Innovative Instructions and Software Model for Isolated Execution* (SGX foundational). HASP 2013.
- Cheng, P. et al. *Intel TDX Demystified: A Top-Down Approach*. ACM Computing Surveys, 2024.

### 18.7 Reproducible and provenance

- SLSA Supply-chain Levels for Software Artifacts, v1.0. https://slsa.dev (informative).
- in-toto Attestation Framework. (informative.)

---

*End of document.*
