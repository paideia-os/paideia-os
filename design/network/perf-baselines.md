# PaideiaOS — Network: Performance Baselines

**Status:** Placeholder
**Date:** 2026-06-17
**Scope:** Performance baselines for the network stack. Addresses NET-O7.

---

## 0. Status

Placeholder. Populated at phase 2 with bare-metal + 25G NIC.

---

## 1. Aspirational targets (from `stack.md` §16)

| Metric | Target |
|---|---|
| Single-flow TCP throughput IRQ-mode | ≥ 10 Gbps |
| Single-flow TCP throughput poll-mode | ≥ 25 Gbps |
| Packet rate poll-mode small packets | ≥ 5 Mpps |
| Single TCP connect-to-handshake | ≤ 100 µs |
| Single QUIC connect with 0-RTT | ≤ 50 µs |
| Hybrid TLS handshake | ≤ 1.5 ms |
| DNS query (UDP, cached) | ≤ 1 µs |

---

*End of placeholder.*
