# pci_enumerator — userspace PCI-tree walker server

**Round anchor:** R22.M3 (design-only; implementation blocked on
[#1015](https://github.com/anthropic/paideia-os/issues/1015)).
**Issue:** [#860](https://github.com/anthropic/paideia-os/issues/860)
**Related:** [#820](https://github.com/anthropic/paideia-os/issues/820)
(acpi_supervisor, blocked on the same substrate).

## Purpose

Once the kernel finishes bus enumeration (`pci_enumerate_all`, R22.M2)
and publishes one KIND_PCI_DEV capability per function
(`pci_publish_caps`, R22.M3), all further PCI-tree traversal must
happen from ring-3 through those capabilities. The `pci_enumerator`
server is the canonical broker: it holds the R_DEV_CONFIG_READ root
cap, walks the tree on request, and answers RPC queries about it.

Keeping the walker in userspace preserves the kernel's "no policy"
posture — the kernel exports the raw capability tree; the enumerator
decides how to present it (topology, per-device metadata, driver
matching hints).

## Blocker

`pci_enumerator` is a userspace server binary in the shape of
acpi_supervisor (#820). It cannot land until #1015 delivers:

1. Named-endpoint IPC (`svc.pci_enumerator` → endpoint capability).
2. Variable-length IPC message support (a `PciEnumRep` naming every
   enumerated function overshoots the current fixed-length IPC frame
   by many multiples).
3. Initial-capability-transfer slot in process creation — the
   R_DEV_CONFIG_READ root cap minted at boot must be planted in the
   enumerator's CSpace before its first schedule.
4. Second server binary substrate in `src/user/` — the shell binary
   does not exercise the linkable + startable pattern a server needs
   (it is a foreground REPL, not a request/reply loop).

`design/round-retrospectives/r20-closure.md` §Deferrals catalogues the
same four gaps for #820. When #1015 closes, #820 and #860 land
together as siblings in the userspace-server round.

## RPC surface (target)

All RPCs are request-reply on the `svc.pci_enumerator` endpoint. The
request word is a 32-bit opcode; replies vary per opcode. Every field
is little-endian, packed, aligned to its natural boundary.

### `PCI_ENUM_LIST` (0x0001)

Enumerate every function known to the enumerator.

```
Request:  { op: u32 = 0x0001 }
Reply:    { count: u32, entries: [PciEnumEntry; count] }

PciEnumEntry (28 bytes):
  +0    u16 seg
  +2    u8  bus
  +3    u8  dev
  +4    u8  fn
  +5    u8  class
  +6    u8  subclass
  +7    u8  header_type      // top bit stripped
  +8    u16 vendor_id
  +10   u16 device_id
  +12   u16 bar_kinds_bitmap
  +14   u16 _pad
  +16   u64 cap_id           // opaque enumerator-issued handle
  +24   u32 rights           // R_DEV_* bitmap on the cap
```

The `cap_id` is not the kernel cap handle — it is an enumerator-issued
opaque token. Clients trade it in for a real KIND_PCI_DEV cap via
`PCI_ENUM_MINT`.

### `PCI_ENUM_LOOKUP` (0x0002)

Find one function by BDF.

```
Request:  { op: u32 = 0x0002, bdf: u64 }
Reply:    { present: u32, entry: PciEnumEntry }
```

`bdf` is packed per `DeviceCap.bdf_pack` (fn[7:0] | dev[15:8] |
bus[23:16] | seg[39:24]).

### `PCI_ENUM_MINT` (0x0003)

Ask the enumerator to derive a per-caller KIND_PCI_DEV cap from its
root cap. The enumerator gates on `rights ⊆ root_rights` and on any
policy the broker enforces (e.g. "only one caller may hold
R_DEV_CONFIG_WRITE on a given function").

```
Request:  { op: u32 = 0x0003, cap_id: u64, rights: u32 }
Reply:    { result: u32, cap_handle: u64 }
```

`result == 0` on success and `cap_handle` is a real KIND_PCI_DEV
handle transferred to the caller's CSpace via the initial-cap-transfer
slot (#1015). Non-zero result codes mirror
`DeviceCap.PCI_DEV_MINT_*`.

### `PCI_ENUM_TOPO` (0x0004)

Return the bridge/downstream-bus adjacency graph. Same shape as
`PCI_ENUM_LIST` but emits only Type-1 header devices plus their
secondary-bus number. Consumers that render a tree UI (or feed a
driver-matching walker) call this once at start.

## Startup sequence

1. Kernel boot completes `pci_enumerate_all` + `pci_publish_caps`.
2. Kernel spawns the `pci_enumerator` process with a CSpace containing
   the root R_DEV_CONFIG_READ|R_DEV_BAR_MAP|R_DEV_IRQ_BIND cap and an
   endpoint cap for `svc.pci_enumerator`.
3. Enumerator registers its endpoint with the service broker under
   the name `svc.pci_enumerator`.
4. Enumerator enters its request loop: `ipc_recv` → dispatch on
   opcode → `ipc_reply`.

## Testing plan

The server itself is exercised via golden-file smokes analogous to
the shell's `tests/user/shell/*.golden` under `tests/user/pci_enum/`:
one file per opcode, feeding a scripted request into a smoke client
via the same IPC substrate the shell uses.

Additionally the kernel-side fingerprint `PCI CAP PUBLISH N=<count>`
(emitted by `pci_publish_caps` at R22.M3) remains the CI gate on the
publication having produced the capability tree the enumerator later
consumes.

## Deferred design choices

- **Cap-invalidation on hot-remove.** When the eventual PCIe hotplug
  path detects a device removal, the enumerator must (a) invalidate
  every derived cap it has minted for that device, (b) drop the entry
  from its LIST reply. The revocation cascade shape is left to the
  R23 hotplug scoping round.
- **Multi-segment ECAM.** `pci_publish_caps` iterates only
  `_pci_devices` (single-segment for now); when the kernel adds
  multi-segment MCFG walking, the enumerator's `LIST` reply gains
  segment-scoped grouping. No RPC-shape change required — the `seg`
  field is already present.
- **Cap payload versioning.** `PciEnumEntry` is not yet versioned.
  Wrap it in a `{ version: u32, payload: ... }` envelope at the
  first backward-incompatible change; the initial ABI is anchored to
  version 1 implicitly.
