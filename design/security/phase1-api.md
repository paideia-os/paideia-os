# PaideiaOS — Security: Phase-1 PQ Trust Root API

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Phase-1 simplified trust-root operations. Addresses PQ-O15.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| P1PQ-D1 | Phase 1 uses classical signatures only (Ed25519); no PQ | Phase-1 dev convenience |
| P1PQ-D2 | No release signing infrastructure; binaries are unsigned in phase 1 | Pre-release |
| P1PQ-D3 | TPM 2.0 used for measured boot only | Q11 partial |
| P1PQ-D4 | No software enclave; signing keys held by the supervisor | Pre-enclave |
| P1PQ-D5 | No remote attestation in phase 1 | Pre-network |

---

## 1. Phase-1 operations

```nasm
; Compute BLAKE3 hash of bytes.
; Inputs: RDI = bytes ptr, RSI = length, RDX = output ptr (32 bytes)
extern p1_blake3

; Sign with Ed25519 (phase-1 development key).
; Inputs: RDI = message ptr, RSI = length, RDX = signature output (64 bytes)
extern p1_ed25519_sign

; Verify Ed25519 signature.
; Inputs: RDI = message, RSI = length, RDX = signature, RCX = public key
; Output: RAX = 1 valid, 0 invalid
extern p1_ed25519_verify

; TPM2_Extend (measured boot).
; Inputs: RDI = PCR index, RSI = hash bytes (32)
extern p1_tpm_extend

; Get random bytes (entropy via RDSEED + RDRAND + jitter).
; Inputs: RDI = output ptr, RSI = length
extern p1_random
```

5 entry points.

---

## 2. Migration to phase 2

Phase 2 adds:
- Hybrid PQ signing (Ed25519 + ML-DSA-65).
- SLH-DSA-128s for boot chain.
- TLS hybrid KEM.
- Software enclave per PQ-Q5.
- Release artifact signing.
- Algorithm catalog.
- Capability-typed delegation hierarchy.

Phase-1 callers continue via wrappers.

---

## 3. Open issues

| ID | Issue |
|---|---|
| P1PQ-O1 | Phase-1 dev key management — currently hardcoded; rotate before first release. |
| P1PQ-O2 | Phase-1 PCR usage — which PCRs are extended for what events. |

---

*End of document.*
