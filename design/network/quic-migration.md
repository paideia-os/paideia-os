# PaideiaOS — Network: QUIC Connection Migration

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** QUIC connection migration interaction with reserved-core poll-mode. Addresses NET-O10.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| QM-D1 | QUIC connections may migrate addresses; reserved-core poll-mode handles this | Standard QUIC feature |
| QM-D2 | Migration is signaled via connection ID change | Per RFC 9000 |
| QM-D3 | The L3 layer's NDP / ARP cache updates on migration | Standard |

---

## 1. Migration flow

1. Client moves to new address (e.g., Wi-Fi to cellular).
2. Client sends packet with same QUIC connection ID from new source address.
3. Server verifies via path challenge.
4. Connection now uses new address.

---

## 2. Reserved-core interaction

The poll-mode reserved core polls all NIC rings continuously. Migration is detected at the QUIC L4 layer; no change to L2/L3 polling.

---

## 3. Open issues

| ID | Issue |
|---|---|
| QM-O1 | Multi-path QUIC (RFC 9440-equivalent) — phase 3+. |

---

*End of document.*
