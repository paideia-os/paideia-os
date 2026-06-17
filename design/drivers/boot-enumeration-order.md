# PaideiaOS — Drivers: Boot Enumeration Order

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Order of bus enumeration at boot. Addresses DR-O8.

---

## 0. Order

```
1. ACPI bubble (or phase-1 NASM parser) brings up CPU topology, IOAPIC, PCIe MCFG.
2. PCIe enumerator runs (consumes ACPI MCFG).
3. virtio bus enumerator runs (consumes PCIe enumeration).
4. NVMe / disk drivers load (consume PCIe / virtio).
5. FS server starts (consumes block storage).
6. Network driver loads.
7. Network stack starts.
8. xHCI driver loads.
9. USB hub driver loads.
10. USB device drivers load.
11. ACPI bubble at this point (if phase 2+) starts; takes over from phase-1 parser.
12. Audio / GPU drivers load.
13. Driver framework ready.
```

---

## 1. Dependencies

- PCIe before virtio (virtio devices are PCIe-attached).
- Block storage before FS.
- Network driver before stack.
- USB host before USB devices.

---

## 2. Parallelism

Steps that don't depend on each other can run in parallel (e.g., network and USB after PCIe).

---

## 3. Open issues

| ID | Issue |
|---|---|
| BEO-O1 | Detailed parallelism opportunities to reduce boot time. |

---

*End of document.*
