# PaideiaOS — Security: Side-Channel Hardening for Software Enclave

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Side-channel mitigations for the PaideiaOS software enclave (per PQ-Q5). Addresses PQ-O9.

---

## 0. Threat model

The software enclave is a userspace process holding sensitive keys (PQ signing keys, KEK material). Threats:
- **Cache side-channels** (Prime+Probe, Flush+Reload).
- **Timing side-channels** (variable-time crypto operations).
- **Power and EM side-channels** (out of software's control without hardware support).
- **Branch-prediction side-channels** (Spectre v1, v2 — covered by Q15).

---

## 1. Mitigations

### 1.1 Constant-time crypto

All cryptographic operations within the enclave use constant-time implementations:
- ML-DSA-65 reference implementation (NIST-vetted constant time).
- SLH-DSA constant time.
- AES-256-GCM via AES-NI (hardware constant time).
- BLAKE3 constant time.
- Comparison operations use `cmoveq` / `setne` patterns.

### 1.2 Cache-line discipline

The enclave's key material is held in cache-line-aligned buffers. Each operation:
- Loads the key into registers explicitly.
- Performs the operation entirely in registers (where possible).
- Clears the cache line containing the key via `clflushopt` after the operation.
- Avoids data-dependent memory accesses.

### 1.3 Avoiding leak patterns

- Power state: enclave runs with thermal management at standard mode (no power-save during signing — leaks frequency).
- Branch hints: signing path is straight-line where possible.
- Speculative execution: Q15 mitigations apply.

---

## 2. What this does NOT defend

- Cold-boot RAM attacks (defense via TME-MK only).
- Physical EM / power analysis (requires hardware countermeasures).
- Kernel CVEs (the kernel is in the TCB).
- Sophisticated attacker with sustained access (out of threat model).

---

## 3. Validation

- Constant-time analysis: tools like `dudect` or `ct-verify` run against the enclave binary.
- Test cases include adversarial inputs designed to leak.

---

## 4. Open issues

| ID | Issue |
|---|---|
| SC-O1 | Specific constant-time validation tooling. |
| SC-O2 | Hardware mitigation availability per CPU generation. |
| SC-O3 | When to use Intel CET to constrain control flow within the enclave. |

---

*End of document.*
