# PaideiaOS — Network: TLS Session Resumption

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** TLS 1.3 session resumption ticket storage. Addresses NET-O4.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| TLR-D1 | Session tickets stored in memory by default | Performance |
| TLR-D2 | Optional persistent storage in CoW FS | For long-lived servers |
| TLR-D3 | 0-RTT supported, but warns on first-write replay risk | Standard |
| TLR-D4 | Default ticket lifetime: 24 hours | Standard |

---

## 1. In-memory storage

The TLS server's process holds active session tickets in memory. Lost on restart.

---

## 2. Persistent storage

For long-running servers, tickets can be persisted to FS. Tickets are encrypted with the server's session-ticket key (rotated periodically).

---

## 3. 0-RTT data

0-RTT data is supported but with the standard caveat: not anti-replay. Applications should mark idempotent or signal anti-replay needed.

---

## 4. Open issues

| ID | Issue |
|---|---|
| TLR-O1 | Session-ticket key rotation cadence. |

---

*End of document.*
