# PaideiaOS — Security: TLS Configuration

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** TLS 1.3 configuration with hybrid PQ KEM. Addresses PQ-O8.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| TLS-D1 | TLS 1.3 only (RFC 8446); no TLS 1.2 fallback | Pillar 5 (no legacy) |
| TLS-D2 | Hybrid KEM: X25519 + ML-KEM-1024 (named group `x25519_mlkem1024`) | Per PQ doc §7 |
| TLS-D3 | Cipher suites: TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256 | Modern subset |
| TLS-D4 | Signature schemes: Ed25519+ML-DSA-65 (hybrid) preferred; ed25519, ecdsa_secp256r1_sha256 supported for compat | PQ doc binding |
| TLS-D5 | Session resumption via PSK + 0-RTT | Standard |
| TLS-D6 | ALPN: HTTP/2, HTTP/3 (QUIC), or application-specific | Forward-looking |
| TLS-D7 | OCSP stapling for revocation | Standard |
| TLS-D8 | Encrypted ClientHello (RFC 9460) when peer supports | Privacy |

---

## 1. Hybrid group codepoint

The named group `x25519_mlkem1024` is registered via IETF for the hybrid KEM. Pending standardization, PaideiaOS uses an interim codepoint:

```
x25519_mlkem1024 = 0x11EC  // interim; subject to IANA
```

Servers and clients negotiate via the standard TLS `supported_groups` extension.

---

## 2. Server configuration

```toml
[tls.server]
listen = "0.0.0.0:443"
cert = "/path/to/cert.pem"
key = "/path/to/key.pem"

[tls.server.protocols]
versions = ["tls1.3"]
groups = ["x25519_mlkem1024"]
ciphers = ["TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256"]
signatures = ["ed25519_mldsa65", "ed25519"]

[tls.server.resumption]
ticket_lifetime = "24h"
zero_rtt = true

[tls.server.alpn]
protocols = ["h3", "h2"]
```

---

## 3. Client configuration

Similar; clients prefer hybrid groups, fall back to classical only if the server refuses hybrid.

PaideiaOS clients by default *do not* fall back to classical-only (per PQ doc §7.3). Compatibility translation at the IPC bridge is the recommended workaround.

---

## 4. Certificate management

Server certificates use hybrid Ed25519 + ML-DSA-65 signatures (the dual-algorithm certificate format per X.509 extensions; details deferred).

---

## 5. Performance

| Metric | Budget |
|---|---|
| Hybrid TLS handshake round-trip | ≤ 1.5 ms |
| Cipher throughput | ≥ 1 GB/s per core |

---

## 6. Open issues

| ID | Issue |
|---|---|
| TLS-O1 | Final IANA codepoint for the hybrid group. |
| TLS-O2 | Dual-algorithm X.509 certificate format. |
| TLS-O3 | Encrypted ClientHello (ECH) configuration. |
| TLS-O4 | The compatibility translation at IPC bridges. |

---

*End of document.*
