# PaideiaOS — Network: NIC Offload Negotiation Schema

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Concrete schema for what each NIC driver advertises during offload negotiation. Addresses NET-O1.

---

## 0. Schema

```capnp
struct OffloadSet {
  tso @0 :Bool;             # TCP Segmentation Offload
  lro @1 :Bool;             # Large Receive Offload
  gso @2 :Bool;             # Generic Segmentation Offload
  gro @3 :Bool;             # Generic Receive Offload
  checksumTx @4 :Bool;      # TX checksum offload
  checksumRx @5 :Bool;      # RX checksum offload
  rss @6 :Bool;             # Receive Side Scaling
  rssQueueCount @7 :UInt32; # number of RSS queues
  msix @8 :Bool;            # MSI-X support
  msixVectorCount @9 :UInt32;
  jumboFrames @10 :Bool;
  maxFrameSize @11 :UInt32;
  vlanTagging @12 :Bool;
  tlsTx @13 :Bool;          # TLS TX offload (phase 3+)
  tlsRx @14 :Bool;
  timestamping @15 :Bool;   # IEEE 1588 PTP
}
```

The stack queries via `NetIfControlSchema.QueryOffloads`; enables selected via `EnableOffloads(set)`.

---

## 1. Default policy

Enable all available offloads.

---

## 2. Per-policy override

The supervisor may disable specific offloads (e.g., RSS off on small systems).

---

## 3. Open issues

| ID | Issue |
|---|---|
| OFL-O1 | Per-driver advertisement format — vendor-specific extensions. |
| OFL-O2 | Telemetry on offload effectiveness. |

---

*End of document.*
