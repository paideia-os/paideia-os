# PaideiaOS — Dev Env: RDSEED Failure Injection

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Mechanism for injecting RDSEED failures in CI. Addresses dev-env J3.

---

## 0. Decision

**Wrapper script around QEMU** that mediates RDSEED. Avoids upstream QEMU patches.

---

## 1. Approach

A small wrapper:
- Intercepts guest's RDSEED via QEMU's `-trace` and `-cpu host,-rdseed` (forces software emulation).
- Or: use QEMU's RDRAND/RDSEED MSR control to selectively fail.

## 2. CI integration

The wrapper has flags:
- `--rdseed-fail-rate 0.1`: 10% of RDSEED calls return CF=0.
- `--rdseed-always-fail`: 100% fail (test fallback path).

CI invokes with the wrapper for entropy-fallback test lanes.

## 3. Open issues

| ID | Issue |
|---|---|
| ET-O1 | Upstream contribution to QEMU for native support. |

---

*End of document.*
