# PaideiaOS — Security: KVM-TDX Upstream Tracking

**Status:** Tracking document
**Date:** 2026-06-17
**Scope:** KVM-TDX upstream usability status. Addresses PQ-O3.

---

## 0. Current status (2026-06-17)

- KVM-TDX patches landed in upstream Linux through mid-2026.
- Upstream QEMU has corresponding `-object tdx-guest` support.
- End-to-end TD boot on stock distro kernels is approaching usability.

## 1. Implication for PaideiaOS

Until KVM-TDX is reliable on stock kernels:
- TDX testing is opportunistic on a dedicated CI host.
- Software-enclave fallback (per PQ-Q5) is the engineering critical path.

## 2. Re-evaluation cadence

Quarterly. When KVM-TDX is reliable:
- Promote TDX from opportunistic to default on server CI lanes.

---

*End of tracking doc.*
