# PaideiaOS — Filesystem: Multi-Device Pool

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** Multi-device pool semantics: mirror, RAID-Z-equivalent, erasure-coded storage. Addresses FS-O6. Phase 3+ feature.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MDP-D1 | Pool is a set of devices managed as one logical FS | ZFS / bcachefs lineage |
| MDP-D2 | Replication strategies: mirror (RAID-1), parity (RAID-Z2-equivalent), erasure-coded | Standard set |
| MDP-D3 | Pool capability `pool_cap` granted by supervisor for pool operations | Pillar 6 |
| MDP-D4 | Self-healing: Merkle mismatch triggers automatic recovery from replicas | Standard |
| MDP-D5 | Hot-spare devices: pre-allocated replacements activate on device failure | Standard |
| MDP-D6 | Phase 3+ deliverable | Scope realism |

---

## 1. Pool layout

A pool consists of:
- N devices, each with its own per-device superblock ring.
- A pool-wide superblock listing devices and replication strategy.
- A pool-wide signature over the device set (PQ-signed).

---

## 2. Replication strategies

### 2.1 Mirror

Every extent is written to N devices identically. Reads come from any healthy replica.

| N | Use |
|---|---|
| 2 | Default 2-way mirror |
| 3+ | High-availability |

### 2.2 Parity (RAID-Z-equivalent)

Each stripe of K data extents has M parity extents (M from 1 to 4 typically). Tolerates M device failures.

### 2.3 Erasure-coded

Reed-Solomon or LDPC; configurable data:parity ratio. Most space-efficient for large pools.

---

## 3. Self-healing

When a read's Merkle hash mismatches:
1. Note the bad replica.
2. Fetch from a healthy replica.
3. Verify the healthy replica's hash.
4. Write the correct data back to the bad replica.
5. Audit log records the event.

Periodic scrubbing (background walker) checks all extents.

---

## 4. Hot-spare and replacement

- Hot-spare device: idle, ready to replace.
- On device failure: hot-spare activates; pool rebuilds from remaining replicas.
- Manual device replacement: drain failing device, activate replacement.

---

## 5. Phase 3+ delivery

Phase 1-2: single-device only.
Phase 3+: pool feature lands.

---

## 6. Open issues

| ID | Issue |
|---|---|
| MDP-O1 | Specific erasure-code scheme — Reed-Solomon? LDPC? |
| MDP-O2 | Pool resize operations — add device, remove device. |
| MDP-O3 | Cross-device snapshot diff. |
| MDP-O4 | Stripe-size tuning for different workloads. |

---

*End of document.*
