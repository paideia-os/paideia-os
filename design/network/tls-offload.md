# PaideiaOS — Network: NIC TLS Offload

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** Hardware NIC TLS offload integration. Addresses NET-O11.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| TO-D1 | Phase 3+ feature when NIC offload available | Pillar 1 |
| TO-D2 | Per-connection offload negotiation | Standard |
| TO-D3 | TLS server retains key; NIC encrypts in flight | Security boundary |

---

## 1. Offload flow

```
1. TLS handshake completes (in tls-server).
2. tls-server programs NIC with session key + sequence.
3. Application sends plaintext through tls-server.
4. tls-server passes plaintext + offload-marker to net-stack.
5. NIC encrypts and DMA's the ciphertext.
6. Wire packets are encrypted; receiver sees encrypted bytes.
```

---

## 2. Supported NICs

Intel E810, Mellanox ConnectX-6+, and similar that ship with TLS offload.

---

## 3. Open issues

| ID | Issue |
|---|---|
| TO-O1 | NIC-specific protocols for key programming. |

---

*End of document.*
