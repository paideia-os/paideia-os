---
audit_id: pci-config-001
issue: 261
file: src/drivers/pci/config.pdx
function: pci_out_address / pci_in_data / pci_out_data
effects: [sysreg]
capabilities: []
reviewed_by:
date: 2026-06-21
---

# AUDIT pci-config-001 — PCI config-space port I/O (D7-003)

## Justification
PCI legacy config access uses two privileged I/O ports: write the BDF-encoded
address to CONFIG_ADDRESS (0xCF8), then read or write the data at CONFIG_DATA
(0xCFC). Port I/O is privileged → unsafe. The BDF address encoding is ordinary
arithmetic done in the typed surface (`pci_address`).

In the driver framework (D7-001 §3), a userspace bus driver performs these
accesses only while holding a port-range capability for 0xCF8/0xCFC; the kernel
mints that capability. The kernel itself does no PCI enumeration.

Citation: PCI Local Bus Specification rev 3.0 (CONFIG_ADDRESS / CONFIG_DATA
mechanism). **Verification TODO** — confirm the revision and bit layout.

## Intended sequences
- `pci_out_address`: `mov dx, 0xCF8; mov eax, addr; out dx, eax`.
- `pci_in_data`:     `mov dx, 0xCFC; in eax, dx`  (result in EAX).
- `pci_out_data`:    `mov dx, 0xCFC; mov eax, value; out dx, eax`.

## Phase-7-groundwork honest scope gaps
- **32-bit `out`/`in` encoders + port immediate**: not in paideia-as 0.6.0,
  which exposes only the `out_al` form (same limitation as boot/uart.pdx). Each
  unsafe block emits `out_al rax`. Caller pre-loads DX with the port and EAX
  with the address/value/result.
- Implemented for real: the full BDF address composition `pci_address`.

## Verification (QEMU smoke)
```
pci_config_read_u32(0, 0, 0, 0) == 0x12378086   # Intel 440FX (QEMU default)
```
With the `in` encoder, the read returns the live register-0 word. Until then,
`tests/d7/pci_config_smoke.pdx` checks `pci_address(0,0,0,0) == 0x80000000`.
