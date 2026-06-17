# PaideiaOS — Network: HTTP Library Choice

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** HTTP/1.1, HTTP/2, HTTP/3 client and server library implementation. Addresses NET-O8.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| HTTP-D1 | Built-in PaideiaOS implementation in paideia-as | FP discipline + integration |
| HTTP-D2 | HTTP/1.1, HTTP/2, HTTP/3 all supported | Forward-looking |
| HTTP-D3 | Consume TCP, QUIC channels from net-stack | Standard pattern |
| HTTP-D4 | TLS via the tls-server (mediated) | Pillar 6 |
| HTTP-D5 | Functor-typed: `module Http3Client(Tls)(Net) : Http3ClientSig` | Per NET-D13 |

---

## 1. Why built-in not port

- Existing Rust libraries (hyper, reqwest) would need to be ported to paideia-as eventually.
- An idiomatic PaideiaOS implementation is more aligned with the FP-discipline pillar.
- HTTP is a finite specification; reimplementation is bounded work.

---

## 2. HTTP/3 priority

HTTP/3 over QUIC is the forward-looking default; HTTP/1.1 and HTTP/2 are for compatibility.

---

## 3. Phase 2 vs 3+

Phase 2: HTTP/1.1 + HTTP/2.
Phase 3+: HTTP/3 (requires QUIC mature).

---

## 4. Open issues

| ID | Issue |
|---|---|
| HTTP-O1 | Server-side architecture — separate process per virtual host? |
| HTTP-O2 | HTTP semantics RFCs to track (RFC 9110, 9111, 9112, 9113, 9114). |

---

*End of document.*
