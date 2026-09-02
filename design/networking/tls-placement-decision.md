# TLS placement decision (R97.M1-001, paideia-os #2094)

**Round:** R97.M1
**Status:** Ratified 2026-09-01. **This is a ratification, not a fresh
design** — the decision was made at `design/network/stack.md` NET-D6
(2026-06-17); this doc formalises the round-boundary commitment and
records the two independent lines of reasoning that reconfirm it.

## 1. The decision, in one line

**TLS lives entirely in user-space.** No in-kernel TLS termination.
The kernel exposes `connect` / `send` / `recv` / `poll` /
`setsockopt(TCP_NODELAY)` and nothing TLS-specific; the user-space tool
that wants TLS (`pdxcurl` from the R100 wave; `libpdx-net` when its
TLS support lands) does the TLS 1.3 handshake and record layer in its
own address space.

## 2. Two independent lines of reasoning

Either line alone would settle the question. Together they are
overdetermined; if the reader ever finds themselves considering a
switch to in-kernel TLS, both need to move, not just one.

### 2.1 The architecture line — `stack.md` NET-D6 (2026-06-17)

`design/network/stack.md` §8 (NET-D6) specifies a separate `tls-server`
process holding long-term keys, explicitly rejecting a kTLS-style
in-stack integration. The rejection is grounded in three properties
the kernel-native alternative gives up:

* **Key isolation.** A `net-stack` CVE does not leak long-term keys —
  the address space that holds them is a peer, not a caller.
* **Independent update.** TLS lives on RFCs and CVEs that cycle far
  faster than kernel-code review would tolerate; the tool can be
  updated without a kernel rebuild.
* **Multi-implementation coexistence.** Two callers can hold different
  trust postures (one pinned, one CA-chained; one PQ-hybrid, one
  classical-only) without the kernel picking a house policy.

Today there is no `net-stack` server — TCP is in-kernel, reached via
sysnos 87-94 + 98-102. The R100-wave `pdxcurl` tool plays the role
`tls-server` will eventually play, directly against socket syscalls
instead of an IPC schema. This is forward-compatible with the Phase-2
migration (§4).

### 2.2 The crypto-substrate line — paideia-as gap

**A real TLS 1.3 handshake against a real Internet HTTPS server needs
at minimum HKDF-SHA256, SHA-256, and a certificate verification
primitive** — a classical bridge (ECDSA-P256 at minimum; RSA-2048 for
broader server compatibility) since virtually no public server presents
a PQ-only certificate today.

Paideia-as state as of 2026-09-01 (`design/library-status.md` L22):

| Primitive | State | Version |
|---|---|---|
| SHA-256 | **Landed** | v0.25.0 |
| HMAC-SHA256 / HKDF-SHA256 | **Landed** | v0.26.0 |
| X25519 keygen + ECDH | **Landed** | v0.27.0 |
| ChaCha20-Poly1305 AEAD | Landed (R100-PREP prereq) | v0.22.0 |
| Ed25519 sign / verify | **Stalled** (`sc_muladd` bit-off in sign) | umbrella #1336 open |
| **ECDSA-P256 sign / verify** | **NOT landed — no intrinsic** | — |
| **RSA-2048 PKCS#1 / PSS verify** | **NOT landed — no intrinsic** | — |

The paideia-os submodule pointer is still at v0.24.0 per the
2026-09-01 sweep note (line 36), so even the landed post-v0.24
primitives are not yet callable from `.pdx` in this tree until the
submodule bump. But the shape is clear: **cert verification is the
one live gap.** A future R97-follow-on wave that wants in-kernel TLS
would need ECDSA-P256 (minimum) before anything else, and the ask sits
squarely against Pillar 6 (PQ-first posture): ECDSA-P256 is a
classical primitive PaideiaOS's own design does not want to depend on
for its own signature surface (it uses ML-DSA-65).

**User-space termination sidesteps the tension.** `pdxcurl` and other
TLS-using tools can consume classical primitives via linked libraries
or their own bundled implementations — the kernel does not have to
adopt classical crypto to hit real HTTPS. The R97.M4-001 escalation
(§5) files the classical-bridge asks against paideia-as *for those
tools*, not for the kernel.

## 3. What the kernel does NOT build in R97

* **No `KIND_TLS_CONN` implementation.** R97.M2-001 (#2095) reserves
  the ordinal (0x1AA — already reserved in
  `design/architecture/next-wave-derived-kinds.md` L2382 from the R91
  wave; not re-numbered) for a future in-kernel PQ-hybrid TLS round.
  See `next-wave-derived-kinds.md` for the reservation row's own
  ratchet-forward language.
* **No `sys_tls_*` syscall surface.** The socket surface (§4) is what
  user-space TLS consumes.
* **No key material lives in the kernel address space** — for TLS or
  for anything else at this scope. TLS trust anchors surface via
  `KIND_TLS_TRUST` (0x1A7, R100-PREP-001), which is caller-consumed
  handle metadata, not private-key material.

**Ordinal-choice note.** The R97 planning brief (2026-09-01) suggested
`0x1B5` "next after KIND_SCHEMA_HANDLE=0x1B2." This is stale — `0x1AA`
was reserved during the R91 wave and has been referenced in
`kind.pdx` L3012's comment thread ever since. Reusing `0x1AA` keeps
the networking reservation block contiguous.

## 4. R97.M3 audit — is the socket surface sufficient? (#2096/#2097)

**Question:** does a user-space TLS 1.3 client need anything from the
socket surface beyond `connect` / `send` / `recv` / `poll` /
`setsockopt(TCP_NODELAY)` — all landed by R95?

**Audit findings (2026-09-01):**

### 4.1 `MSG_PEEK` — not needed

TLS 1.3 record boundaries are self-framing: a `TLSPlaintext` header
carries an explicit two-byte length prefix (RFC 8446 §5.1) so the
client always knows exactly how many bytes constitute the current
record. A user-space implementation reads the 5-byte header via
`sys_recv`, computes the record length, and calls `sys_recv` again for
the payload. `MSG_PEEK` is a Berkeley-sockets convenience for
protocols whose framing must be inferred from the *content* (line-based
protocols peeking for `\n`); TLS's length prefix means the peek use
case never arises.

**Verdict:** no gap. If a future non-TLS user-space protocol needs
peeking, that is its own separate ask — filing it here would be scope
creep.

### 4.2 Partial-write handling — kernel is fine; caller must loop

R72's `sys_send` caps at 1024 bytes per call (`net/tcp.pdx`
`tcp_send_segment`'s scratch buffer). A TLS record can be up to
16 KiB + framing — larger than a single `sys_send` accepts. Two ways to
reconcile:

* **Grow `sys_send`'s per-call ceiling** — a kernel-side change,
  touching the scratch-buffer sizing across every TCP send path.
* **User-space loops until the full record is sent** — a well-known
  socket-programming pattern (`send` returns bytes-actually-written;
  caller advances the buffer pointer and calls again). This is what
  every mainstream TLS library does anyway (OpenSSL, BoringSSL,
  Rustls) since a userspace `SSL_write` internally loops over the
  underlying transport regardless of `send`'s per-call limit.

**Verdict:** no kernel-side gap. `sys_send`'s per-call cap is a normal
partial-write scenario that TLS libraries handle in user-space by
contract, not a kernel deficiency. The `pdxcurl` (R100 wave) and
`libpdx-net` designs already assume `send`-loop discipline.

### 4.3 R97.M3-002 (#2097) disposition

The audit finds no gap in either dimension. R97.M3-002 was scoped as
"if M3-001 finds a gap, close it or document as no-op." **No-op:**
neither MSG_PEEK nor partial-write requires a kernel change. The
socket surface as it stands after R95 is sufficient for a user-space
TLS 1.3 client. This document is the record of that no-op disposition;
no separate close-out issue is filed.

## 5. R97.M4 — cross-repo escalation to paideia-as (#2098)

Per §2.2, the one live crypto gap for a user-space TLS 1.3 client
against a real Internet HTTPS server is a certificate verification
primitive. Filing scope:

* **ECDSA-P256 sign + verify** (RFC 6979 deterministic nonces;
  section 4.6 for the verify) — **NEW paideia-as issue,
  non-blocking for this wave.**
* **SHA-256** — already landed (paideia-as v0.25.0). No filing.
* **HKDF-SHA256** — already landed (paideia-as v0.26.0). No filing.

An RSA-2048 verify primitive is broader-compatible but a heavier ask
(RSA-PKCS#1 v1.5 + RSA-PSS + key parsing); leaving it out of the
initial escalation and letting the ECDSA-P256 landing find its
consumer before litigating RSA. If the R100 `pdxcurl` wave surfaces a
concrete server the ECDSA-only bridge fails on, that is a follow-on
escalation.

**Framing tension explicitly acknowledged:** the ask is classical
crypto in a project whose signature intrinsic (ML-DSA-65) is
PQ-first. The escalation issue must name this — "the classical
bridge is a compatibility concession for reaching a public Internet
whose CA infrastructure is virtually entirely classical, not a
retreat from Pillar 6." A future round adopts PQ-hybrid TLS trust
paths as those become deployable server-side; the classical bridge is
kept alongside, not in place of, the PQ posture.

## 6. Kernel-side consequence — nothing new to build

Because the decision is user-space termination, R97 does not add
`net/tls_*.pdx`, does not extend `net/tcp*.pdx`, does not touch the
sockets syscall shims (already R95-complete for TLS's needs per §4).
The kernel surface for R97 is:

* A design doc (this file).
* A reservation row (KIND_TLS_CONN, already present at 0x1AA in
  `design/architecture/next-wave-derived-kinds.md`).
* A cross-repo issue (§5).
* An audit disposition (§4).
* A round-closure retrospective (`design/round-retrospectives/r97-closed.md`).

No `.pdx` code, no fingerprint, no witness — the round's product is
docs and one paideia-as issue.

## 7. Cross-references

* `design/network/stack.md` §8 NET-D6 — the primary architecture
  decision this ratifies.
* `design/networking/r91-plan.md` §11 — planning writeup that named
  R97 as the ratification round.
* `design/library-status.md` — paideia-as crypto state
  (2026-09-01 sweep).
* `design/architecture/next-wave-derived-kinds.md` L2382 — the
  KIND_TLS_CONN reservation row.
* `design/security/pq-trust-root.md` — Pillar 6 posture that shapes
  §5's tension.
