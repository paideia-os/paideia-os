# PaideiaOS — Network: WireGuard-Style Overlay (Phase 3+)

**Status:** Draft v0.1 — phase 3+
**Date:** 2026-06-17
**Scope:** PaideiaOS-native WireGuard-style overlay using the universal hybrid KEM. Addresses NET-O9.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| OVR-D1 | WireGuard-inspired (Noise Protocol) handshake | Modern minimal |
| OVR-D2 | Hybrid X25519 + ML-KEM-1024 for key exchange | PQ doc binding |
| OVR-D3 | ChaCha20-Poly1305 for symmetric encryption | WireGuard's choice; PQ-safe |
| OVR-D4 | Phase 3+ feature | Scope |

---

## 1. Why a new overlay vs porting WireGuard

WireGuard's handshake uses Noise IKpsk2 with Curve25519. To PQ-harden, we need to substitute the KEM. The result is a new protocol; not WireGuard-compatible.

Trade-off: lose interop with existing WireGuard deployments, gain PQ-safe overlay.

---

## 2. Handshake

Adapted Noise pattern with hybrid KEM:
- Both parties have static long-term ML-KEM-1024 public keys.
- Handshake messages combine ephemeral X25519 + ML-KEM-1024.
- Session key derived via the hybrid combiner.

---

## 3. Datapath

Same as WireGuard's: ChaCha20-Poly1305 sealed packets, sequence numbers, sliding-window anti-replay.

---

## 4. Configuration

```toml
[overlay.peer."alice"]
public_key_x25519 = "..."
public_key_mlkem = "..."
allowed_ips = ["10.0.0.0/24"]
endpoint = "1.2.3.4:51820"
```

---

## 5. Open issues

| ID | Issue |
|---|---|
| OVR-O1 | Specific Noise pattern for the hybrid handshake. |
| OVR-O2 | Roaming and mobility. |

---

*End of document.*
