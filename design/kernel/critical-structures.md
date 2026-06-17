# PaideiaOS — Kernel: Critical-Structures Region

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Concrete size budget and layout of the kernel's critical-structures region (per `memory-model.md` §2.1). Addresses MEM-O2 — verify the 64 GiB budget suffices for 128-CPU NUMA systems.

**Hard inputs:**
- `memory-model.md` §2.1 — region holds descriptor table, per-CPU areas, IDT/GDT/IOAPIC base; ≤ 64 GiB.

---

## 0. Size budget per component

| Component | Size budget | Scaling |
|---|---|---|
| Descriptor table | 16 GiB | 16 KiB/descriptor × ~1M descriptors per kind × 16 kinds (with growth headroom) |
| Per-CPU areas | 4 GiB total | 32 MiB/CPU × 128 CPUs = 4 GiB |
| IDT (256 entries × 16 bytes) | 4 KiB per CPU | 512 KiB total |
| GDT (~16 entries × 8 bytes) | trivial | trivial |
| IOAPIC base mappings | 64 MiB | one per IOAPIC; typically 1-8 IOAPICs |
| Effect-environment templates | 1 GiB | shared across CPUs but per-AS |
| Kernel stack pool | 16 GiB | 16 KiB stack × N threads (up to 1M threads = 16 GiB) |
| Scheduler queues per CPU | 4 GiB total | included in per-CPU areas above |
| TLB shootdown vectors | 1 GiB | static |
| Audit ring buffers | 8 GiB total | 64 MiB per CPU |
| Reserved | ~15 GiB | future expansion |
| **Total** | **~64 GiB** | |

The 64 GiB budget *does* suffice for 128-CPU NUMA systems with growth headroom.

---

## 1. Verification for larger systems

| CPU count | Per-CPU area | Per-CPU stacks | Total per-CPU footprint |
|---|---|---|---|
| 8 | 32 MiB × 8 | 4 GiB | ~4.3 GiB |
| 64 | 32 MiB × 64 | 16 GiB | ~18 GiB |
| 128 | 32 MiB × 128 | 32 GiB | ~36 GiB |
| 256 | 32 MiB × 256 | 64 GiB | ~72 GiB |

For 256+ CPU systems (hypothetical future), the 64 GiB budget would need to grow. The critical-structures region size is configurable at build time.

---

## 2. Recommendation

Maintain 64 GiB as the default; grow to 128 GiB for systems with > 128 CPUs (configurable at kernel build time).

---

*End of document.*
