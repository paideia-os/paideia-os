# PaideiaOS — Driver Framework Architecture (R7 / D7-001)

**Status:** Draft v0.1 (R7 groundwork)
**Date:** 2026-06-21
**Issue:** D7-001 (#259)
**Scope:** The architecture of the PaideiaOS driver framework as it is realised
at the start of Phase 7. This document is the entry point for the driver
groundwork issues D7-002..006; the exhaustive specification lives in
`design/drivers/framework.md` (Draft v0.1). This file states the model in the
concrete terms the R7 code touches: lifecycle, userspace placement,
capability-mediated device access, IRQ delivery, and hot-plug.

## Pillar alignment

- **Pillar 3 (microkernel — drivers run in userspace).** The kernel never
  embeds driver logic. It does exactly four things for a driver: (1) routes the
  device's IRQ to the driver as an IPC message, (2) mediates MMIO / port-IO /
  DMA access through capabilities, (3) provides IOMMU isolation for DMA, and
  (4) delivers hot-plug events. Everything device-specific is driver code in a
  userspace task.
- **Pillar 9 (hierarchically defined, hot-pluggable).** The framework's data
  model is a tree rooted at the PCI host bridge. Each bus driver is itself a
  mini-framework for its children. Hot-plug is a structural edit of that tree,
  expressed as capability revocation (node removed) plus a new capability grant
  (node added).

## 1. Driver lifecycle

A driver is a userspace task that moves through a fixed lifecycle:

```
        probe ──► init ──► run ──► suspend ──► resume ──► run
                                      │                     │
                                      └──────► exit ◄───────┘
```

- **probe** — the framework hands the driver a *driver capability* (D7-004)
  scoped to a specific `(vendor, device)`. The driver reads enough config space
  (D7-003) to confirm it can drive the device, then returns accept/reject.
- **init** — the driver requests its MMIO regions (D7-005), an IRQ endpoint, and
  DMA buffers; programs the device into a known state.
- **run** — steady state: the driver services IRQ messages and IPC requests from
  clients.
- **suspend / resume** — power-management transitions (ACPI-driven). Default per
  Q14 is *hard restart* on driver update; live state-handoff is opt-in.
- **exit** — the driver releases its capabilities; the framework reclaims them.

## 2. Userspace placement (Pillar 3)

Each driver is an ordinary scheduled task (a TCB per R4.5) in its own address
space (an aspace per R5.5). It holds no ambient authority: it can touch only the
memory and ports named by the capabilities it was granted. A crashing driver
faults in its own aspace; the framework observes the fault (via the kernel's
exception path, R6.5-006) and restarts the driver without touching kernel state.

## 3. Capability-mediated device access

Three access classes, each a derived capability kind:

- **MMIO** — `request_mmio_mapping(driver_cap, phys_base, length, flags)`
  (D7-005) mints a region capability and calls `aspace_map` (R5.5-003) to map
  the device's BAR window into the driver's aspace. The driver then reads/writes
  registers as ordinary (uncached) memory.
- **port-IO** — for legacy devices, a port-range capability authorises `in`/`out`
  to a bounded port window. The PCI config accessors (D7-003) are the first
  consumer (ports 0xCF8/0xCFC).
- **DMA** — a DMA-buffer capability is backed by IOMMU page-table entries so the
  device can only reach the buffers the driver was granted. (IOMMU programming
  is Phase 7 proper; D7 only reserves the capability kind.)

## 4. IRQ delivery via IPC endpoint

The kernel owns the IDT (R6.5-001) and the LAPIC. A device IRQ enters a kernel
trampoline (R6.5-002), which converts it into an IPC notification on the
driver's *IRQ endpoint* capability. The driver blocks receiving on that endpoint;
on each IRQ it wakes, services the device, and acknowledges. This keeps all
device-specific interrupt handling in userspace while the kernel only does the
vector → endpoint routing and the EOI.

## 5. Hot-plug events

A hot-plug *insert* is: the bus driver discovers a new device, the framework
mints a fresh driver capability for it, and a matching driver is probed. A
hot-plug *remove* is: the framework revokes the device's capabilities (which, by
the revocation cascade, invalidates every derived MMIO/IRQ/DMA cap the driver
held), then signals the driver to exit. Because removal is modelled as
capability revocation, a driver can never retain access to a departed device.

## 6. Open questions surfaced (for Phase 7 proper)

- **MSI-X vector routing.** How does a driver request a specific MSI-X vector,
  and how does the kernel map that vector to the driver's IRQ endpoint? The
  current model assumes one endpoint per device; multi-vector MSI-X needs a
  vector → endpoint table per driver.
- **DMA capability model.** The exact shape of the IOMMU-backed DMA capability
  (per-buffer vs. per-device domain, IOMMU page-table ownership) is unresolved.
- **Hot-plug event throttling.** A device that flaps (rapid insert/remove) could
  generate an unbounded event stream; the framework needs a debounce / rate-limit
  policy so a flapping device cannot DoS the supervisor.

## 7. Citations (verification TODO)

- seL4 driver framework — Heiser & Elphinstone (2016), "L4 Microkernels: The
  Lessons from 20 Years of Research and Deployment." **Verify** full citation,
  venue, and that the driver-framework claims attributed here match the paper.
- Fuchsia DDK (Driver Development Kit) — Google developer documentation.
  **Verify** snapshot date and the lifecycle correspondence.
- Genode 22.05 component/driver model RFC. **Verify** version and applicability.

> Reference discipline: the three citations above are carried from the round
> plan as **unverified**. They must be checked against primary sources before
> this document loses its Draft status. Do not cite them as settled.
