# PaideiaOS — Capabilities: Per-Kind Rights Bit Catalogs

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Per-kind bit layouts for the 64-bit rights bitmask carried by each capability descriptor's common header (per `linearity-and-tags.md` §4.3). Addresses CAP-O2.

**Hard inputs:**
- `linearity-and-tags.md` §4 — hybrid bitmask + effect set rights model.
- `linearity-and-tags.md` §3.1 — closed enum of 16 base kinds.

---

## 0. Conventions

- Each kind has its own bit layout (mask is kind-specific).
- The low 32 bits are *common rights* (the most-frequent across kinds where applicable).
- The high 32 bits are *kind-specific extensions*.
- Bit 63 is reserved as a "future extension" sentinel.
- The mapping bit → effect is the canonical mapping function defined per kind (§4.4 of linearity-and-tags.md).

---

## 1. `memory` kind (kind id 0)

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `mem_read` | Load from the region |
| 1 | `mem_write` | Store to the region |
| 2 | `mem_exec` | Execute from the region |
| 3 | `mem_map` | Map into an address space |
| 4 | `mem_share` | Share into another process |
| 5 | `mem_retype` | Consume the region into another kind |
| 6 | `mem_revoke` | Revoke this region's capability |
| 7 | `mem_audit` | Region's accesses are audited |
| 8 | `mem_lam_priv` | LAM tag bits kernel-privileged |
| 9 | `mem_pmem` | Persistent-memory semantics (CLWB discipline) |
| 10 | `mem_cxl` | CXL.mem semantics (bias-mode tracking) |
| 11 | `mem_encrypted` | TME-MK encrypted |
| 12 | `mem_dma` | DMA-capable (IOMMU-mapped) |
| 13 | `mem_far` | Far-memory semantics (latency-class metadata) |
| 14-31 | reserved | |
| 32-62 | kind-specific extensions | |

---

## 2. `ipc-endpoint` kind (kind id 1)

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `ipc_send` | Send on this endpoint |
| 1 | `ipc_recv` | Receive on this endpoint |
| 2 | `ipc_share` | Share endpoint with another process |
| 3 | `ipc_close` | Close the endpoint |
| 4 | `ipc_handoff` | Participate in Q14 handoff |
| 5 | `ipc_cycle_form` | Combine into a cyclic graph |
| 6 | `ipc_audit` | Audited endpoint |

---

## 3. `port` kind (kind id 2)

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `port_in_8` | Read 8 bits via `in` |
| 1 | `port_in_16` | Read 16 bits |
| 2 | `port_in_32` | Read 32 bits |
| 3 | `port_out_8` | Write 8 bits via `out` |
| 4 | `port_out_16` | Write 16 bits |
| 5 | `port_out_32` | Write 32 bits |
| 6 | `port_audit` | Audited port |

---

## 4. `irq` kind (kind id 3)

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `irq_install` | Install handler |
| 1 | `irq_remove` | Remove handler |
| 2 | `irq_mask` | Mask the vector |
| 3 | `irq_unmask` | Unmask the vector |
| 4 | `irq_route` | Configure routing (target CPU) |
| 5 | `irq_audit` | Audited vector |

---

## 5. `process` kind (kind id 4)

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `process_start` | Start execution |
| 1 | `process_stop` | Stop execution |
| 2 | `process_terminate` | Force termination |
| 3 | `process_suspend` | Suspend (per scheduler.md §5.2) |
| 4 | `process_resume` | Resume |
| 5 | `process_observe` | Observe state (for debug/audit) |
| 6 | `process_set_priority` | Modify priority |
| 7 | `process_set_affinity` | Modify CPU/NUMA affinity |
| 8 | `process_handoff` | Participate in Q14 handoff |

---

## 6. `sched-ctx` kind (kind id 5)

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `sc_bind` | Bind to a thread |
| 1 | `sc_unbind` | Detach from a thread |
| 2 | `sc_donate` | Used as donor in sync RPC (per scheduler.md §7) |
| 3 | `sc_modify_budget` | Change budget value |
| 4 | `sc_modify_period` | Change period |
| 5 | `sc_modify_priority` | Change priority |

---

## 7. `slot-cap` kind (kind id 6)

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `slot_consume` | Consume on enqueue |
| 1 | `slot_mint` | Mint back on dequeue |
| (no other bits needed) | | |

---

## 8. `cycle-cap`, `splitter-cap`, `merger-cap`, `handoff-cap` (kind ids 7-10)

Each has minimal rights; the *presence* of the cap is the right.

| Bit | Effect |
|---|---|
| 0 | `use_cap` (always set; the cap is the authorization itself) |
| 1 | `audit` (audited use) |

---

## 9. `audit` kind (kind id 11)

| Bit | Effect | Meaning |
|---|---|---|
| 0 | `audit_write` | Write an entry |
| 1 | `audit_read` | Read entries (audit-log reader role) |
| 2 | `audit_close` | Close an epoch |
| 3 | `audit_sign` | Sign an epoch summary (release-line operator) |

---

## 10. `seal-cap` and `unseal-cap` kinds (kind ids 12, 13)

`seal-cap`:

| Bit | Effect |
|---|---|
| 0 | `seal_apply` | Apply seal to a target capability |
| 1 | `seal_inspect` | Inspect the seal-cap's domain |

`unseal-cap`:

| Bit | Effect |
|---|---|
| 0 | `unseal_reveal` | Unseal a target capability |
| 1 | `unseal_inspect` | Inspect rights of a sealed cap |

---

## 11. Reserved kinds (kind ids 14, 15)

Kind 14 (currently planned: `reserved_core_cap` per `scheduler.md` §5):

| Bit | Effect |
|---|---|
| 0 | `core_hold` | Hold the CPU exclusively |
| 1 | `core_release` | Release |
| 2 | `core_transfer` | Transfer to another holder |

Kind 15 reserved for future use; no bits allocated.

---

## 12. Cross-cutting bits

Some bits apply uniformly across kinds. They are mirrored at the same bit position in each kind:

| Bit | Effect | Universal meaning |
|---|---|---|
| 30 | `audit_inherit` | Inherit audit policy from parent on mint |
| 31 | `reserved_for_future` | Must be 0 |

The kernel checks bit 31 = 0 at every operation; non-zero indicates a forged capability (the kernel doesn't set this bit).

---

## 13. Effect mapping function

For each kind, the canonical `rights_to_effects(bits) → set` and `effects_to_rights(set) → bits` functions are defined. The mapping is total in both directions for each kind.

The implementation is a per-kind table:

```paideia-as
fn memory_rights_to_effects(bits : u64) -> EffectRow =
  let e : EffectRow = !{}
  if bits & 0x01 then e ∪= !{mem_read}
  if bits & 0x02 then e ∪= !{mem_write}
  ...
  return e
```

---

## 14. Open issues

| ID | Issue |
|---|---|
| RCAT-O1 | When new bits are added — process for catalog versioning. |
| RCAT-O2 | Bit-31 reserved-for-future enforcement — kernel-side validation. |
| RCAT-O3 | Derived-kind extension bits — phase 2+ rights extensions for derived kinds (per CAP-Q3 two-tier). |

---

*End of document.*
