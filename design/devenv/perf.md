# PaideiaOS — Dev Env: Performance Substrate

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Performance measurement substrate (bare-metal vs QEMU). Addresses dev-env H8.

---

## 0. Decision

- **Bare-metal:** required for absolute performance numbers (cycle counts, throughput).
- **QEMU:** acceptable for relative numbers with elevated thresholds.

---

## 1. Bare-metal substrate

- Self-hosted runner with Sapphire Rapids workstation.
- Pinned CPU frequency.
- Quiescent state (no other workload).
- Cycle accuracy from PMU.

## 2. QEMU substrate

- KVM-accelerated (not TCG; TCG times are misleading).
- Reserved CPU pinning to avoid noise.
- Caveat: virtualization overhead may affect numbers.

## 3. Hybrid usage

- Phase 2: QEMU baselines with elevated thresholds.
- Phase 3+: bare-metal baselines as authoritative.
- Both for regression tracking.

## 4. Open issues

| ID | Issue |
|---|---|
| PRF-O1 | PMU access in QEMU/KVM — verify granted. |

---

*End of document.*
