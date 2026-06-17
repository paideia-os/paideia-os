# PaideiaOS — Runtime: GPU Passthrough Authorization

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** User-consent flow for GPU passthrough to VM jails. Addresses JAIL-O5.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| GPU-D1 | GPU passthrough requires `gpu_passthrough_cap` granted by user | Pillar 6 |
| GPU-D2 | Host GPU driver releases device cap on grant | Standard |
| GPU-D3 | VT-d remaps for VM access | Hardware isolation |
| GPU-D4 | Revoke: host reclaims GPU | Standard |

---

## 1. Activation flow

```
user: "Run firefox in VM jail with GPU"
system:
  - Check user has gpu_passthrough_cap (granted at install for trusted apps).
  - If not: prompt user; record consent.
  - Host GPU driver releases device.
  - VMM remaps GPU via VT-d.
  - VM starts with GPU access.
  - On VM exit: host reclaims GPU.
```

---

## 2. Trade-offs

- Pro: VM can use real GPU (gaming, ML).
- Con: While VM holds GPU, host has no display.

---

## 3. Open issues

| ID | Issue |
|---|---|
| GPU-O1 | Time-shared GPU (host and VM both use simultaneously) — not supported in phase 3+. |

---

*End of document.*
