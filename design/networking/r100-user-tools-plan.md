# R100 (softarch) — User-Space Networking Tools: pdxcurl + libpdx-net + libpdx-url + pdxping + pdxdig + pdxsock + pdxtrust

**Status:** proposal (2026-09-01, softarch counterpart to osarch R91-R99, renumbered R93→R100 due to osarch R93=DHCP+UDP+DNS collision)
**Companion (osarch):** kernel-side networking round, parallel effort — drivers,
IP/TCP/UDP substrate, ICMP, DHCP, and the TLS-placement decision. This
document is the user-side half. As of this writing no
`design/networking/r*-plan.md` sibling exists yet from osarch; this doc
originally drafted at R93; renumbered to **R100** after osarch claimed R93 for DHCP+UDP+DNS. Retains R93 references in historical narrative below; new work references R100's own fallback instruction and will
renumber if osarch's parallel plan lands under a different round first.
Coordination surface is narrow and named explicitly at §12.
**Depends on:**
- `design/tooling/volume-tooling-ux.md` (R53) — the pattern this plan
  mirrors wholesale: 1 shared library (there, 2 here) + N CLI tools, each
  a satellite repo, each M1..M5, each shipping a signed 1.0.0 release.
- `design/round-retrospectives/r64-closure-v2.md` — the volume-tooling
  wave's honest closure: what actually landed vs. what stubbed out
  (elevate broker, schema registry, real seed loading, device-target
  writes). §11 of this doc inherits every one of those postures rather
  than re-litigating them optimistically.
- `design/user/syscall-table.md` — the frozen SC+ table through sysno 95;
  `socket`/`bind`/`listen`/`accept`/`connect`/`send`/`recv`/`shutdown`
  (87–94) landed at R72.M1 (#1927), **AF_INET + SOCK_STREAM (TCP) only**.
  This is the single load-bearing fact behind this entire plan's staging
  order (see §0.3).
- `design/network/stack.md`, `design/network/http.md`,
  `design/network/ipv4-only-policy.md` — the June-2026 "Draft v0.1"
  aspirational network-stack vision (single `net-stack` server, separate
  `tls-server`/`dns-resolver`/`nts-client` processes, algebraic-effect
  layering, QUIC/HTTP-3-first). **This plan does not build toward that
  vision.** The vision predates the round-based execution model; what
  actually shipped by R72 is direct in-kernel socket syscalls with no
  userspace `net-stack` mediator. §0.4 states the divergence explicitly
  so nobody reconciles the two documents by accident.
- `tools/user/mkfs.pdxfs/`, `tools/user/mount.pdxfs/`,
  `tools/user/umount.pdxfs/`, `tools/user/libpdx-volume/`,
  `tools/user/libpdx-audit/` — the concrete repo shape (`caps.decl`,
  `link.ld`, `tools/build.sh`, `src/`, `tests/`, `release/`, `.pdxdoc`)
  every new repo in this plan reuses verbatim.
- `tools/build.sh` lines ~244–339 (the `r64v2-tools` stage) — the
  paideia-os-side integration mechanics (sibling-lib pre-build, filtered
  `-link` obj dirs, `user-sign-stub.pdx` substitution for runtime-hostless
  intrinsics, parallel tool build, `userbin_embed.S` `.incbin` staging)
  this plan's §9 extends with an `r93-tools` stage of the same shape.

**Sibling documents to keep in step:**
- osarch names its kernel-half document R91-plan.md; grep — grep
  `design/networking/r*-plan.md` and `design/kernel/*network*` before
  opening R100.M1 on any repo below; if osarch's round number differs,
  rename this doc's headers to match (content unaffected).
- `design/architecture/next-wave-derived-kinds.md` — gains a row for
  `KIND_TLS_TRUST` on landing (§8).

---

## 0. Reading order and framing

- §0.1 what "R100 user tools" delivers — 2 libraries + 5 CLIs.
- §0.2 the honesty rule — every capability this plan claims is checked
  against what's *actually* landed, not what an earlier vision document
  wished for.
- §0.3 the one fact that shapes every milestone: sockets are TCP-only.
- §0.4 divergence from `design/network/stack.md`'s aspirational net-stack.
- §1 tool inventory — 7 repos, one-line purpose, wave placement.
- §2 `libpdx-net` — the client SDK; TCP/UDP wrappers, resolver, TLS, HTTP.
- §3 `libpdx-url` — URL parser/validator.
- §4 `pdxcurl` — the flagship CLI; full design in the companion doc.
- §5 `pdxping` — ICMP echo; the raw-privilege boundary case.
- §6 `pdxdig` — DNS query CLI.
- §7 `pdxsock` — general TCP/UDP client/server.
- §8 `pdxtrust` — trust-anchor minting for `pdxcurl`.
- §9 paideia-os integration (build.sh, userbin_embed, boot smoke).
- §10 semantic-pipe record schemas.
- §11 what this wave will NOT achieve — the honest debt inventory, written
  before the fact this time.
- §12 coordination points for osarch (the syscall-boundary contract).
- §13 milestone + issue breakdown, all 7 repos + substrate prep.
- §14 first end-to-end smoke.

### 0.1 What R100 delivers

Two libraries and five CLIs, each a `github.com/paideia-os/<name>` satellite
repo:

| Repo | Kind | Purpose |
|---|---|---|
| `libpdx-net` | library | TCP/UDP socket wrappers, DNS resolver, TLS client, HTTP/1.1 client |
| `libpdx-url` | library | URL parse + validate (RFC 3986 subset) |
| `pdxcurl` | CLI | improved-curl: capability-native, audit-first, PQ-by-default HTTP(S) client |
| `pdxping` | CLI | ICMP echo |
| `pdxdig` | CLI | DNS query tool |
| `pdxsock` | CLI | general TCP/UDP client + server (netcat-adjacent) |
| `pdxtrust` | CLI | mints `KIND_TLS_TRUST` caps from `.pubkey` files |

`pkg` (existing satellite, R49/R50 wave) becomes a consumer of
`libpdx-net` + `libpdx-url` in a follow-up round once its own maintainers
pick that up — not part of this wave's milestone count (see §11.7).

### 0.2 The honesty rule

`r64-closure-v2.md` is this plan's single most important input. Four
satellite repos landed ~5400 LOC in R64 v2, and *every one* of the
following stubbed rather than shipped for real: libpdx-elevate integration
(no broker cap for standalone CLIs), the schema registry (semantic-pipe
records fall back to line-based text), real key-seed loading (signatures
are well-formed but unverifiable), and device-target writes (no
`sys_cap_query`). None of that is a failure of R64 v2 — it is what
"land the chain end-to-end at the scope that's actually buildable" looks
like when the substrate underneath is itself mid-construction.

This plan inherits every one of those postures rather than assuming they
got fixed in between. Concretely:
- `libpdx-elevate` calls in this wave's tools are written for real but
  **fail closed** until paideia-os#1997 (broker dispatch body) lands —
  same as mkfs/mount/umount.
- Semantic-pipe records in this wave bind a schema fingerprint constant
  but **emit line-based text** until paideia-os#2000 (schema registry)
  lands — same fallback header convention as `PdxFsFormatRecord@0.1`.
  Copy the fallback-header string exactly (`libpdx-audit`/`libpdx-volume`
  callers should be grep-able as one family).
- `libpdx-audit` calls are real IPC sends against a daemon whose dispatch
  may be stubbed — "forgiving daemon-stub posture," not a hard dependency.
- Any place this plan needs a kernel primitive that does not exist yet
  (UDP-via-socket, ICMP, a new derived KIND) is named as a coordination
  point at §12 and the tool's own milestone is staged so a fail-closed
  stub is not a build blocker — mirroring mkfs.pdxfs's device-target path
  (parses, doesn't write, ships anyway).

### 0.3 The load-bearing fact: sockets are TCP-only

`src/kernel/core/syscall/handlers/sys_socket.pdx`'s own header is explicit:

> MVP scope: AF_INET (2) / SOCK_STREAM (1) only; proto is not inspected
> (0 or IPPROTO_TCP=6 both mean "TCP", the only protocol...)

No `SOCK_DGRAM`, no `AF_UNIX`, no raw sockets. This single fact determines
almost every staging decision below:

- **HTTP/HTTPS over TCP** (`pdxcurl`, `libpdx-net` HTTP client) — fully
  buildable today against the landed syscalls. No blocker.
- **DNS resolution** (`libpdx-net` resolver, `pdxdig`) — needs UDP
  datagrams to a well-known server (the DNS server's IP:53). **Blocked**
  until osarch extends the socket family to `SOCK_DGRAM` (§12.1).
- **ICMP echo** (`pdxping`) — needs either a raw socket or a dedicated
  syscall. **Blocked** until osarch lands one (§12.2).
- **TLS** (`libpdx-net` TLS client, `pdxcurl` HTTPS) — rides over TCP so
  the transport is available today, but the cryptographic primitives
  needed for a real TLS 1.3 handshake (SHA-256, HKDF, an ECDH/KEM group,
  a certificate/raw-key signature-verify routine) **do not exist in
  paideia-as yet** (§0.5, §12.4). This is the single largest blocker in
  the whole plan and gets a dedicated staging strategy.

There is also a separate, older, half-built path worth naming so nobody
resurrects it by accident: `KIND_UDP_SOCKET = 0x50` (R27.M6, #994) is a
mint-gate-only stub for an RPC-based UDP-socket-server design that never
got a real dispatch body — it was blocked on a "userspace-server
substrate" (#1015) that itself never landed a real ring-3 spawn path
(per its own R31.M1 reassessment comment). **This plan's UDP ask (§12.1)
is to extend the modern direct-syscall TCP path (SC+ 87–94, no RPC, no
cap_invoke dispatch) to accept `SOCK_DGRAM`, not to resurrect the R27
RPC scheme.** The two designs are incompatible in spirit (direct-syscall
vs. RPC-mediated) and osarch should treat `KIND_UDP_SOCKET`/0x50 as dead
weight for this wave's purposes — worth a deprecation note, not a
resurrection.

### 0.4 Divergence from the aspirational `design/network/stack.md`

`design/network/stack.md` (2026-06-17, "Draft v0.1") describes a single
`net-stack` userspace server with algebraic-effect-layered L2/L3/L4,
separate `tls-server`/`dns-resolver`/`nts-client` processes, QUIC/HTTP-3
as the forward-looking default, and BBRv3 congestion control. **None of
this exists.** What actually landed by R72 is direct in-kernel socket
syscalls (§0.3) with no userspace mediator process at all. This plan
targets the *real* R72 architecture, not the June vision doc. Concretely:

- No `tls-server` process exists to hand a `Channel(TcpConnectSchema)`
  to — `libpdx-net`'s TLS client (§2.4) is a **userspace library that
  wraps the TCP socket fd directly**, performing the TLS record layer and
  handshake in the calling process's own address space. This is a
  deliberate scope reduction, not an oversight: standing up a
  capability-isolated `tls-server` AS is a substrate project on the order
  of the whole volume-tooling wave, and nothing in this plan's scope
  needs long-lived TLS keys to be isolated from the calling CLI process
  (a one-shot `pdxcurl` invocation has nothing to protect a key *from*
  within its own lifetime).
- No `dns-resolver` process exists — `libpdx-net`'s resolver (§2.3) is a
  library function the calling process runs itself, one UDP round-trip
  per lookup, no daemon, no cache shared across processes (a per-process
  in-memory TTL cache is in scope; a system-wide cache is not).
- QUIC/HTTP-3 are out of scope entirely — `libpdx-net`'s HTTP client is
  HTTP/1.1 only (§2.5). HTTP/2's multiplexing needs the same kind of
  substrate QUIC does and is deferred with it.
- If/when osarch's future kernel-networking rounds actually stand up a
  `net-stack` mediator process and a real capability-typed channel
  substrate, `libpdx-net`'s internals get re-plumbed underneath its
  existing public API (`net_socket`/`net_connect`/... stay stable); this
  plan does not attempt to pre-build for that future.

This divergence should be recorded in `design/network/stack.md` itself
(a status-update pass, not this doc's job) so a future reader does not
mistake the aspirational doc for the current architecture.

### 0.5 The TLS trust-model decision (headline, expanded at §2.4)

Because there is no ambient CA store (a deliberate posture the task brief
itself asks for, and one this plan endorses on independent grounds —
X.509 ASN.1 parsing is one of the most CVE-dense parser surfaces in all
of networked software, and PaideiaOS has no ASN.1 parser and no reason to
write one under time pressure), `pdxcurl`'s HTTPS path does **not**
validate a CA-issued certificate chain. Instead:

- The server authenticates via **TLS 1.3 raw public keys** (RFC 7250) —
  no X.509 certificate, no chain, no CA.
- The client holds a `KIND_TLS_TRUST` cap (minted by `pdxtrust`, §8) that
  pins the *exact* public key (and hybrid-signature algorithm) the server
  is expected to present.
- A handshake against a server presenting any other key is a hard
  refusal (`TLS_KEY_MISMATCH`), full stop — there is no partial-trust,
  no "warn but continue."

**The trade-off, stated plainly:** `pdxcurl` v1 cannot browse the public
HTTPS internet (real-world servers present X.509 certs signed by public
CAs, not raw pinned keys a PaideiaOS operator minted by hand). It can
talk to any HTTPS endpoint the operator controls or has been told to
pin — PaideiaOS-native services, an intranet fleet, a package mirror
whose operator publishes a pubkey out of band. Widening to interoperate
with the public CA ecosystem (X.509 parsing, a curated root store,
OCSP/CRL or short-lived-cert freshness policy) is a distinct, much larger
future round this plan explicitly does not claim to be a stepping stone
toward — it would need its own trust-model document. **This is flagged
in the report as the one decision main should sanity-check hardest**: it
determines whether `pkg`'s future network-fetch path (real package
mirrors, presumably CA-signed) can ever reuse `pdxcurl`/`libpdx-net`'s
TLS client as-is, or needs a second TLS mode.

---

## 1. Tool inventory

Seven new public repos under `github.com/paideia-os/`. Repository shape
mirrors R53 exactly: paideia-as manifest at root, `caps.decl` at root,
`src/` module tree, `tests/`, `release/`, `doc/<name>.pdxdoc`, dual-signed
`manifest.pdxsig` at 1.0.0.

### 1.1 `libpdx-net` — client-side network SDK

**Purpose.** The one library every other repo in this wave links (except
`libpdx-url`, which it itself consumes). Ships socket wrappers, address
parsing, a resolver, a TLS client, and an HTTP/1.1 client.
**Ships in wave:** R100.M1..M5. Blocks `pdxcurl`, `pdxping`, `pdxdig`,
`pdxsock` M2+ (their M1 scaffolds can open in parallel against stub
signatures, matching R53's `libpdx-volume`-blocks-M2 pattern).

### 1.2 `libpdx-url` — URL parser/validator

**Purpose.** RFC 3986 subset parser + an SSRF-hardening validator (reject
schemes other than `http`/`https` by default; flag but do not silently
resolve `localhost`/loopback/link-local targets — see §3.3). Separated
from `libpdx-net` because `pkg` needs it without needing sockets/TLS/HTTP
at all (`pkg` validates a URL argument before ever opening a connection).
**Ships in wave:** R100.M1..M5. Blocks `pdxcurl`.M2, `libpdx-net`.M3 (HTTPS
URL parsing consumes it).

### 1.3 `pdxcurl` — improved-curl CLI

**Purpose.** The flagship. Full design in the companion doc
`design/networking/pdxcurl-design.md`. Capability-native (`KIND_TLS_TRUST`
instead of an ambient CA store), semantic-pipe output, audit-first,
PQ-preferring, explicit-trust, `--dry-run`/`--audit-only`, structured
error taxonomy.
**Ships in wave:** R100.M1..M5. Opens after `libpdx-net`.M1 + `libpdx-url`.M1.

### 1.4 `pdxping` — ICMP echo CLI

**Purpose.** Minimal, complete `ping`-equivalent. Exercises the kernel's
ICMP path end to end; small enough to be the first tool that proves out
the new privileged-protocol elevate class (§5.4, §12.2).
**Ships in wave:** R100.M1..M5. Opens after `libpdx-net`.M1; M2+ blocked on
osarch's ICMP syscall (§12.2) — M1 ships regardless (dry-run only).

### 1.5 `pdxdig` — DNS query CLI

**Purpose.** `dig`-equivalent. Exercises the kernel's UDP path (once it
exists) + `libpdx-net`'s resolver end to end.
**Ships in wave:** R100.M1..M5. Opens after `libpdx-net`.M1; M2+ blocked on
osarch's UDP-via-socket extension (§12.1).

### 1.6 `pdxsock` — general TCP/UDP client + server

**Purpose.** `netcat`-adjacent. TCP client + TCP server (bind/listen/
accept — already landed, no blocker) at M2; UDP client (connected mode)
at M3, blocked on §12.1 same as `pdxdig`.
**Ships in wave:** R100.M1..M5. Opens after `libpdx-net`.M1.

### 1.7 `pdxtrust` — trust-anchor management CLI

**Purpose.** Mint `KIND_TLS_TRUST` caps from a directory of `.pubkey`
files; list/revoke/inspect trust anchors. The tool `pdxcurl`'s HTTPS path
depends on (§0.5).
**Ships in wave:** R100.M1..M5. Opens after `libpdx-net`.M1 (shares the raw
public-key encoding types); blocked on `KIND_TLS_TRUST` landing (§12.3)
for M2's real mint path — M1 ships against a stub.

---

## 2. `libpdx-net` — client-side network SDK

### 2.1 Public API surface (frozen at M1, stub bodies)

```
net_socket(domain, sock_type, proto)         -> Result<Fd, NetErr>
net_bind(fd, local_addr)                     -> Result<(), NetErr>
net_connect(fd, addr)                        -> Result<(), NetErr>
net_send(fd, buf, len)                       -> Result<usize, NetErr>
net_recv(fd, buf, len)                       -> Result<usize, NetErr>
net_close(fd)                                -> Result<(), NetErr>
net_inet_pton(family, str) -> Ipv4Addr        # dotted-quad parse only at v1
net_resolve(hostname, qtype) -> Result<Vec<IpAddr>, DnsErr>
net_tls_wrap(fd, trust_cap, sni) -> Result<TlsConn, TlsErr>
net_tls_send(conn, buf, len)                 -> Result<usize, TlsErr>
net_tls_recv(conn, buf, len)                 -> Result<usize, TlsErr>
net_tls_close(conn)                          -> Result<(), TlsErr>
http_get(url, headers, trust_cap) -> Result<HttpResponse, HttpErr>
http_post(url, headers, body, trust_cap) -> Result<HttpResponse, HttpErr>
```

`NetErr`/`DnsErr`/`TlsErr`/`HttpErr` are small closed enums (not a shared
errno space) — each layer's failure taxonomy is distinct and each maps
independently onto the semantic-pipe result-code fields at §10.

### 2.2 M2 — TCP wrapper, endian helpers, `inet_pton`

- `net_socket`/`net_connect`/`net_send`/`net_recv`/`net_close` become
  thin, real wrappers over SC+ 87/91/92/93/3 (`close` is the generic
  fd-close syscall, not a dedicated socket-close — confirm with osarch
  that a TCP socket fd closes cleanly through the generic path; if not,
  this is a §12 coordination item).
- `net_bind`/`net_listen`/`net_accept` wrap SC+ 88/89/90 for `pdxsock`'s
  server mode.
- Endian helpers: `htons`/`ntohs`/`htonl`/`ntohl` — paideia-as is
  little-endian native (x86_64); network byte order is big-endian, so
  these are real byte-swaps, not no-ops. Every wire-format encoder in
  this wave (DNS header, IPv4 dotted-quad, TCP/UDP port fields as seen
  in sockaddr structs) goes through these rather than ad hoc `bswap`
  call sites, so a future audit can grep one call site family.
- `net_inet_pton`: dotted-quad IPv4 string → `u32`. No hostname
  resolution here (that is `net_resolve`, §2.3) and no IPv6 at v1 (no
  kernel IPv6 socket support exists — `AF_INET` only per §0.3, so an
  IPv6 parser would have nothing to connect to; deferred with the kernel
  capability).

### 2.3 M2/M3 — resolver

- `net_resolve(hostname, qtype)`: builds a DNS query packet (RFC 1035
  header + question section, one question, `qtype` typically `A`),
  `net_connect`s a `SOCK_DGRAM` socket to the configured resolver's
  IP:53 (read from the boot-seeded resolv-equivalent, §9.4 — **not**
  parsed from `/etc/resolv.conf` by path convention until R65v2
  persistent-home lands; v1 reads a fixed boot-time-seeded single-file
  path), `net_send`s the query, `net_recv`s the response with a 5-second
  default timeout, parses the response into a small `Vec<Ipv4Addr>` for
  `A`-record answers.
- Response parsing handles exactly: header (id match, rcode check,
  ancount), one question echoed back (skipped, not re-validated against
  the sent question beyond ID match — a v1 simplification; DNS
  transaction-ID randomization for cache-poisoning resistance is real
  and required even at v1, see §2.3.1), and `ancount` answer RRs of type
  `A`/`CNAME` (one level of CNAME-follow, no loop-guard beyond a
  hop-count cap of 4). `AAAA`/`MX`/`TXT`/`NS`/`SRV` parsing is
  explicitly out of scope for R100 — `pdxdig` v1 can only usefully query
  `A` records (its argv still accepts `--type=`, but unsupported types
  return `UNSUPPORTED_QTYPE` cleanly rather than silently mis-parsing).
- **This entire section is blocked on §12.1** (UDP-via-socket). M2's
  actual landing, if UDP is not yet available, ships the query-builder
  and response-parser as pure functions over byte buffers (fully
  testable without a live socket) and stubs the socket half exactly the
  way `mkfs.pdxfs` stubbed its device-target write path — parses,
  doesn't transmit, ships anyway, named as a known gap.

#### 2.3.1 Transaction-ID randomization is non-negotiable

Even at v1 scope, the resolver **must** use a cryptographically random
16-bit transaction ID per query and must verify the response's ID
matches before trusting any answer — this is the minimum bar against
off-path DNS response spoofing and is cheap to get right at initial
implementation (expensive to retrofit once callers depend on a
predictable ID). Source of randomness: whatever CSPRNG primitive
paideia-as already exposes for other capability work (confirm the exact
call site with osarch/paideia-as at M2-open; if none exists at
process-start entropy, a fallback of `hpet_now_ns() ^ pid ^
small-counter` is acceptable for R100 but must be labeled
`WEAK_ENTROPY_FALLBACK` in a code comment so a future round can find and
replace it before this tool is exposed on anything but a lab network).

### 2.4 M3 — TLS client

Per §0.5's trust model: **TLS 1.3, RFC 7250 raw public keys, no X.509,
no CA store.** Concretely:

- Cipher suite: `TLS_CHACHA20_POLY1305_SHA256` — chosen because
  ChaCha20-Poly1305 is the one AEAD paideia-as already ships an intrinsic
  for (`ChaCha20Poly1305::seal`/`open`, landed #1305/v0.33-004). No AES
  intrinsic exists; standardizing on the suite paideia-as can already do
  removes one blocker from an already-blocker-heavy milestone.
- Key exchange: **X25519**, not the hybrid ML-KEM combiner the
  aspirational `design/network/stack.md` NET-D6/PQ-doc envisions —
  neither X25519 nor ML-KEM has a paideia-as intrinsic today (§12.4), so
  this is a real new-crypto ask regardless of which curve/KEM is picked;
  X25519 is picked because it is dramatically simpler to implement
  correctly (a single Montgomery-ladder scalar mult, well-trodden
  constant-time reference code) than ML-KEM-768/1024's polynomial
  arithmetic, and the trust boundary here is a pinned raw public key, not
  a CA — the confidentiality property X25519 buys is "an on-path
  attacker cannot read the bytes," which does not need PQ-hardness to be
  a meaningful improvement over plaintext HTTP. **Upgrading to a hybrid
  X25519+ML-KEM combiner once paideia-as ships an ML-KEM intrinsic is a
  drop-in future round** — `net_tls_wrap`'s public signature does not
  encode the KEM choice, so this is an internal swap, not an API break.
  This is a deliberate, named departure from the PQ-universal-KEM
  decision at PQ-doc §7 / NET-D6, and belongs in main's sanity-check list
  (§ report) precisely because "post-quantum by default" is one of the
  seven feature-request bullets in this wave's brief and X25519-only is
  not that, yet.
- Authentication: the server signs the handshake transcript with the key
  pinned in the `KIND_TLS_TRUST` cap. **Signature algorithm**: prefer
  Ed25519 over ML-DSA-65 for v1, for exactly the same "what actually has
  an intrinsic" reason — paideia-as ships `mldsa65_sign` but explicitly
  **no `mldsa65_verify`** (r64v2 debt item 5 confirms this gap is still
  open as of the volume-tooling wave), and no Ed25519 intrinsic either.
  **Both signature-verify paths are new paideia-as work** (§12.4);
  between the two, Ed25519 verify is the smaller, more mechanical lift
  (a handful of well-known constant-time field/curve routines) versus
  ML-DSA-65 verify (a full Dilithium-family NTT + rejection-sampling
  verifier). `pdxcurl`'s task brief explicitly wants "if the server
  offers ML-DSA sig algorithms, prefer them; refuse RSA<2048" — **this
  plan defers the ML-DSA-65-verify path to a follow-up round** and ships
  Ed25519-only verification at R100, with the algorithm negotiated as a
  single-byte tag inside the (non-X.509) raw-key trust record so a
  future ML-DSA-65 addition is additive, not a format break. RSA is not
  supported at all (no X.509, no RSA intrinsic, no reason to add one for
  a raw-public-key-only trust model).
- Record layer: length-prefixed ChaCha20-Poly1305-sealed application
  records per RFC 8446 §5.2, sequence-number nonce derivation per
  §5.3 — implemented directly against the existing AEAD intrinsic, no
  new crypto primitive needed for this part.
- **HKDF is required** for TLS 1.3's key schedule (early/handshake/
  master secret derivation) and paideia-as has no HKDF intrinsic and no
  SHA-256 intrinsic to build one from (§12.4). This is the actual
  hardest blocker in the whole plan, harder than the KEM/signature
  choice above — without SHA-256 there is no way to compute the
  transcript hash TLS 1.3 signs over, regardless of which signature
  algorithm is chosen. **M3 cannot produce a working handshake until
  paideia-as ships at minimum: SHA-256, HMAC-SHA256 (or the primitives
  to build it), HKDF-Extract/Expand, X25519 scalar-mult, and Ed25519
  sign+verify.** This is the single largest cross-repo escalation this
  plan generates (§12.4) and should be filed and started **before**
  `libpdx-net`.M3 opens, not discovered when M3 stalls.
- `TlsHandshakeRecord@0.1` (§10.3) is emitted regardless of outcome,
  including on `TLS_KEY_MISMATCH` — a refused handshake is exactly the
  kind of event the audit trail exists to make legible.

### 2.5 M4 — HTTP/1.1 client

- `http_get`/`http_post` over a `net_tls_wrap`ped connection (HTTPS) or a
  bare `net_connect`ed one (HTTP). Request-line + headers + optional body
  encode; response status-line + headers + body decode.
- **Content-Length** and **chunked transfer-encoding** both supported on
  decode (chunked is common enough on real servers that skipping it
  makes the tool unable to talk to a meaningful fraction of HTTP/1.1
  servers). Encode side only ever sends `Content-Length` (no chunked
  request bodies at v1 — `pdxcurl --data` always knows its length up
  front).
- **Connection reuse**: a single `HttpClient` handle keeps one connection
  open across calls to the same `(host, port, scheme)` tuple within a
  process's lifetime (no cross-process/persistent connection pool — each
  `pdxcurl` invocation is a fresh process, so reuse only matters within
  `libpdx-net`'s own multi-request test fixtures and any future daemon
  consumer).
- **Redirects**: 301/302/303/307/308 handled with the correct
  method-preservation semantics per RFC 9110 §15.4 (303 always becomes
  GET; 307/308 preserve method and body; 301/302 preserve method for
  non-POST, degrade POST→GET — matches real browser/curl behavior, not
  the letter-of-RFC-7231-ambiguous historical behavior). Redirect chains
  capped at 10 hops (`TOO_MANY_REDIRECTS`); cross-scheme redirects
  (https→http) are followed only with an explicit `--allow-downgrade`
  flag at the `pdxcurl` layer, refused by default at the library layer
  unless the caller passes an explicit `allow_downgrade: true`.

### 2.6 M5 — signed release

Dual-signed manifest, `.pdxdoc`, CHANGELOG-1.0, mirror push. Standard.

---

## 3. `libpdx-url` — URL parser/validator

### 3.1 Scope

RFC 3986 generic syntax, restricted to what `http`/`https` URLs need:
scheme, userinfo (parsed, immediately rejected — `pdxcurl` does not
support embedding credentials in a URL; use a header), host (dotted-quad
IPv4 or a hostname string — no IPv6 literal support, matching §2.2's
no-IPv6 posture), port (default 80/443 by scheme), path, query, fragment
(parsed, dropped before any network use — fragments are never sent to a
server per spec).

### 3.2 API

```
url_parse(s) -> Result<Url, UrlErr>
url_to_string(url) -> String
url_is_https(url) -> bool
url_default_port(url) -> u16
```

### 3.3 Validation / SSRF posture

`url_parse` succeeds on any syntactically valid `http(s)` URL, including
ones pointing at loopback/link-local/private-range addresses — **this
library does not itself refuse them**; it is a parser, not a policy
engine. `pdxcurl` (§4) is the place a `--no-local` policy flag would live
if a future round wants one; documented here as an explicit non-decision
so nobody assumes SSRF-hardening is silently happening inside the
library. This mirrors `libpdx-url`'s stated purpose ("shared between
pdxcurl and pkg") — `pkg`'s SSRF posture (fetching from a fixed,
operator-controlled mirror list) and `pdxcurl`'s (arbitrary
operator-supplied URLs from the command line) are different enough that
baking one policy into the parser would be wrong for one of the two
callers.

### 3.4 Milestones

M1 scaffold + grammar constants; M2 parser; M3 validator (scheme
allow-list, malformed-percent-encoding rejection, oversized-URL cap);
M4 tests (RFC 3986 Appendix B/C test vectors + fuzz); M5 release.

---

## 4. `pdxcurl` — improved-curl CLI

Full design in `design/networking/pdxcurl-design.md`. Summary of the
distinguishing-from-curl features (task brief §3, restated as committed
decisions):

1. **Capability-native trust**: `--trust=<cap-uri>` names a
   `KIND_TLS_TRUST` cap; there is no `-k`/`--insecure` escape hatch and
   no bundled CA list (§0.5). An HTTP (non-TLS) URL needs no trust cap.
2. **Semantic-pipe output**: status/headers/body-chunks as typed records
   via the same fallback-to-line-based posture as every other tool in
   this repo generation (§0.2).
3. **Audit-first**: an `HttpRequestRecord@0.1` (INTENT) is journaled via
   `libpdx-audit` before any byte reaches the wire; a RESULT record
   follows the same INTENT/RESULT pairing `mount.pdxfs` established.
4. **PQ-preferring, honestly scoped**: v1 ships Ed25519-only
   verification (§2.4) — the "prefer ML-DSA" behavior is a documented
   **future** capability this plan stages for but does not deliver at
   R100 (see §11.2). `pdxcurl --verbose` reports which algorithm a given
   handshake actually used so this gap is visible at runtime, not just
   in a design doc.
5. **`--dry-run`**: prints the exact request line + headers + (if
   `--data`) body that would be sent, with no network I/O — the
   `HttpRequestRecord@0.1`'s `dry_run: true` field distinguishes this
   from a real send in the audit trail, exactly like
   `PdxFsFormatRecord@0.1`'s field of the same name.
6. **`--audit-only`**: journals the INTENT record and prints it, sends
   nothing. Distinct from `--dry-run` in that `--dry-run` still fully
   resolves DNS and computes the wire bytes (useful for "what would this
   send" debugging); `--audit-only` is for "record that this was
   requested" without even a DNS lookup (useful for a policy layer that
   wants a provenance trail of *intent* before deciding whether to permit
   the resolve at all — not wired to any actual gate at R100, but the
   distinction is real and worth having in the CLI surface now).
7. **Structured error taxonomy**: every failure mode (DNS NXDOMAIN,
   connection refused, TLS key mismatch, HTTP 4xx/5xx, redirect loop,
   timeout) maps to a distinct exit code *and* a distinct
   `result_code` enum value in the semantic-pipe record — never a bare
   "curl: (7) Failed to connect" string.

---

## 5. `pdxping` — ICMP echo CLI

### 5.1 Argv

```
pdxping [--count=N] [--interval-ms=N] [--timeout-ms=N] [--dry-run] <host-or-ip>
```

### 5.2 Why this tool is small on purpose

`pdxping` exists to give the kernel's ICMP path (once osarch lands one, §12.2)
an end-to-end user-facing exerciser, and to be the first tool that proves
out a **privileged-protocol elevate class** rather than the
mount-point-class table R53 used. It intentionally does nothing else —
no traceroute, no MTU discovery, no flood mode.

### 5.3 Kernel surface needed

Per §0.3, raw ICMP access is a materially different privilege ask than
the TCP-socket family (a raw socket historically means "read/write
arbitrary IP-layer bytes," Linux's `CAP_NET_RAW`). This plan recommends
against a general raw-socket kind for R100 — the attack surface (arbitrary
packet crafting) is large for a single narrow use case. Instead:

- **A dedicated syscall**, `sys_icmp_echo(dst_addr, seq, payload_ptr,
  payload_len, timeout_ms) -> rtt_ns | -errno` (SC+ number placeholder
  96, next free after `kill`=95). One echo request, one blocking wait for
  the matching reply (by ID+seq), one return value. No packet crafting
  surface beyond a caller-supplied payload buffer.
- This is narrower than a raw socket, cheaper for osarch to reason about
  and audit, and sufficient for everything `pdxping` needs. If a future
  round genuinely needs general raw-socket access (a real traceroute,
  arbitrary ICMP type/code), that is a separate, larger design
  conversation this plan does not try to pre-empt.

### 5.4 Elevate: does ICMP need it?

**Yes, by policy, no by mechanism (yet).** Linux gates raw ICMP behind
`CAP_NET_RAW` (or the `net.ipv4.ping_group_range` sysctl escape hatch)
because unrestricted raw-socket access is a DoS/spoofing vector; a single
narrow `sys_icmp_echo` syscall (§5.3) has a much smaller version of that
concern (a process could still hammer a target with 1-per-syscall echo
requests, i.e., a ping flood, absent kernel-side rate limiting osarch
should consider independently of this plan). This plan's recommendation:
introduce a new elevate policy class, `R_NET_PRIVILEGED_PROTOCOL`,
requested once per `pdxping` session before its first `sys_icmp_echo`
call. Per §0.2's honesty rule, this **fails closed** exactly like every
other elevate call in this repo generation until paideia-os#1997 lands —
`pdxping` M3 wires the real request-and-fail-closed path, not a
"pretend it succeeded" stub, so the day #1997 lands `pdxping` needs zero
code changes to start actually granting.

### 5.5 Semantic record

`PingRecord@0.1`: `target_ip`, `seq`, `rtt_ns` (0 on timeout),
`result_code: enum{OK, TIMEOUT, UNREACHABLE, NO_PERMISSION, DRY_RUN}`,
`ts_ns`. One record per echo, not one per session — a `pdxping --count=4`
run emits 4 records, letting a downstream semantic-pipe consumer compute
loss/jitter itself rather than `pdxping` pre-aggregating.

### 5.6 Milestones

M1 scaffold+argv+dry-run; M2 real `sys_icmp_echo` call (blocked on §12.2,
ships as a documented stub otherwise) + RTT stats printer; M3 elevate
wiring (fail-closed per §5.4) + audit + semantic-pipe `PingRecord@0.1`;
M4 smokes (happy path against a QEMU-reachable gateway, timeout path,
unreachable-host path, elevate-denied path); M5 release.

---

## 6. `pdxdig` — DNS query CLI

### 6.1 Argv

```
pdxdig [--type=A] [--server=<ip>] [--timeout-ms=N] [--dry-run] <name>
```

`--type=` accepts only `A` at v1 (§2.3 — `libpdx-net`'s resolver parses
no other RR type); any other value returns `UNSUPPORTED_QTYPE` (exit
code distinct from a real DNS failure — this is a client-side capability
gap, not a server response).

### 6.2 Elevate

None needed — UDP DNS queries need no more privilege than the TCP
sockets `mount.pdxfs` et al. already use without elevate.

### 6.3 Semantic record

`DnsQueryRecord@0.1` — see §10.2.

### 6.4 Milestones

M1 scaffold+argv+dry-run; M2 real UDP query via `libpdx-net.net_resolve`
(blocked on §12.1, ships with query-builder/response-parser as pure
functions otherwise, per §2.3's staging note); M3 audit + semantic-pipe
+ transaction-ID-randomization correctness test (§2.3.1); M4 smokes
(happy path, NXDOMAIN, timeout, malformed-response fuzz-derived
fixtures, CNAME-follow correctness); M5 release.

---

## 7. `pdxsock` — general TCP/UDP client + server

### 7.1 Argv

```
pdxsock [-l] [-u] [--dry-run] <host> <port>      # client mode (default)
pdxsock -l [-u] [--dry-run] <port>                # listen mode
```

`-l` listen mode, `-u` UDP mode (default TCP). Stdin→socket,
socket→stdout, matching netcat's basic contract; no `-e` exec-on-connect
(a known netcat foot-gun this tool deliberately omits).

### 7.2 What's real at which milestone

- **TCP client** (`pdxsock host port`): fully buildable at M2 — `connect`
  + `send`/`recv` loop, no kernel blocker.
- **TCP server** (`pdxsock -l port`): fully buildable at M2 —
  `bind`/`listen`/`accept` all landed at R72.M1 alongside the client
  syscalls. Single-connection-at-a-time at v1 (accepts one client, serves
  it to completion, exits — no concurrent-client fan-out; that needs a
  process-per-connection or event-loop design this small tool doesn't
  need yet).
- **UDP client** (`pdxsock -u host port`): connected-UDP mode, same
  §12.1 blocker as `pdxdig`.
- **UDP server** (`pdxsock -lu port`): **out of scope for R100.** A UDP
  server needs to receive from an arbitrary, not-yet-known peer address
  (classic `recvfrom` semantics) which connected-UDP (§12.1's minimal
  ask) does not provide. Flagged honestly rather than half-implemented;
  a future round's `recvfrom`/`sendto` syscall pair (or an
  address-out-param on `recv`) would unblock this.

### 7.3 Milestones

M1 scaffold+argv (mode flags); M2 TCP client+server real bodies; M3 UDP
client (blocked §12.1) + audit + semantic-pipe (a generic
`SockSessionRecord@0.1` — bytes-in, bytes-out, peer, duration, not one of
the three named record types in §10, since this tool is closer to a raw
pipe than a protocol client); M4 smokes (TCP echo round-trip against a
`pdxsock -l` fixture, UDP echo once §12.1 lands, server-refuses-second-
connection behavior documented); M5 release.

---

## 8. `pdxtrust` — trust-anchor management CLI

### 8.1 Argv

```
pdxtrust import <name> <pubkey-file> [--system]
pdxtrust list
pdxtrust show <name>
pdxtrust remove <name> [--system]
```

`.pubkey` file format: a small self-describing binary blob —
`{algo: u8 (0=Ed25519, 1=ML-DSA-65 reserved), key_bytes: [u8;32 or 1952],
label: string}`. `pdxtrust import` reads this file, validates the length
matches the declared algorithm, and mints a `KIND_TLS_TRUST` cap over it.

### 8.2 Trust-store location and elevate

- **User-scope** (default): `~/.config/pdxtrust/<name>.trust` —
  no elevate; a user's own trust decisions are their own subtree, same
  posture R53's mount-point-class table gives `/home/<$user>/**`.
- **System-scope** (`--system`): a shared system trust directory (path
  TBD alongside R65v2 persistent-home — no such directory can be durable
  before then; v1's `--system` writes to a boot-session-scoped location
  and documents the non-persistence honestly, same posture §9.4's
  resolv-equivalent takes). Requires elevate — reuses the existing
  mount-point-class-table pattern's spirit (`/system/**` always elevates)
  even though `pdxtrust` isn't a mount tool; the elevate call is real,
  fails closed per §0.2 until #1997 lands.

### 8.3 Semantic record

`TrustAnchorRecord@0.1`: `action: enum{IMPORT, REMOVE, LIST}`, `name`,
`algo`, `key_hash` (BLAKE3 of the pinned key, not the key itself — the
audit trail should be able to prove "this exact key was ever imported"
without the log itself becoming a second copy of every trust anchor),
`scope: enum{USER, SYSTEM}`, `result_code`, `ts_ns`.

### 8.4 Milestones

M1 scaffold+argv (`.pubkey` file format spec + parser); M2 real
`KIND_TLS_TRUST` mint (blocked on §12.3, ships as a validated-parse-only
stub otherwise — matches mkfs.pdxfs's device-cap-target precedent
exactly) + user-scope trust-store read/write; M3 system-scope + elevate
wiring + audit + semantic-pipe; M4 smokes (import→list→show→remove
round-trip, malformed-`.pubkey`-file rejection matrix, system-scope
elevate-denied path); M5 release.

---

## 9. paideia-os integration

### 9.1 Submodules

Seven new `[submodule "tools/user/<name>"]` entries in `.gitmodules`,
pinned at each repo's `r93-closed` tag once cut, mirroring the six
existing `tools/user/*` entries exactly.

### 9.2 `tools/build.sh` — new `r93-tools` stage

A new stage parallel to (not replacing) the existing `r64v2-tools` stage
at lines ~244–339, same shape:

```
SAT_LIBS_R93=(libpdx-net libpdx-url)
SAT_APPS_R93=(pdxcurl pdxping pdxdig pdxsock pdxtrust)
SAT_STAMP_R93="${BUILD_DIR}/user/.r93-tools-stamp"
```

Same incremental-stamp discipline, same filtered `-link` obj-dir staging
for any object that references a runtime-hostless intrinsic (by §2.4,
this wave's TLS crypto calls are the new candidates for a
`tools/user-net-crypto-stub.pdx` substitution, exactly analogous to
`tools/user-sign-stub.pdx`'s role for `pdxb_sign.o` — **only needed if**
paideia-as's eventual SHA-256/HKDF/X25519/Ed25519 intrinsics land with
the same "extern-C thunk with no userspace host" shape `mldsa65_sign`
did; confirm at §12.4 escalation time, don't assume). Same parallel
tool-ELF build, same `.elf` copy into `build/user/` for
`userbin_embed.S`'s `.incbin` lines.

### 9.3 `tools/userbin_embed.S` + `bin_seeds.pdx`

Five new `.incbin` lines (one per CLI; libraries are not directly
embedded, only linked) and five new `/bin/<tool>` seed rows in
`bin_seeds.pdx`, mirroring the existing three volume-tool rows. Per
r64v2's own debt item 7 (paideia-os#1976/#1977, "how do we cross-build a
satellite `.pdx` tool from paideia-os's build system" — resolved by the
`r64v2-tools` stage itself, which this plan's `r93-tools` stage directly
copies), this integration point is now a known, working pattern, not an
open question — R100.s wrapper issues should land faster than R64v2's did
because the plumbing decision is already made.

### 9.4 Boot-seeded resolver config

Per §2.3, v1 does not implement a real `/etc/resolv.conf` parser (no
`/etc` persistence exists before R65v2). Instead: a single boot-time
constant (or a tiny seeded file at a fixed tmpfs path, e.g.
`/boot/resolv.default`) names one resolver IP, written by the loader the
same way other boot-seeded defaults land. `libpdx-net`'s resolver reads
this one path; there is no multi-resolver fallback list at v1 (a second,
honest scope cut). A `--server=` override on `pdxdig` bypasses this
entirely for testing, as does a hypothetical future `pdxcurl --resolve=`
(not committed to this wave's milestone list, flagged as a natural
follow-on issue).

### 9.5 Boot smoke mode

A new `boot_r93_curl` smoke mode (mirroring `boot_r57_cat_motd` etc.)
drives a real `pdxcurl` invocation against a QEMU-side loopback HTTP
fixture server (the smoke harness's own responsibility to stand up — out
of this plan's scope to design, named here so main tracks it as a
paired osarch/softarch smoke-infra item). At minimum: `pdxcurl
http://<qemu-host-ip>:<port>/` returns 200 and the fingerprint line
`curl ok status=200 bytes=<n>` appears in the boot log.

---

## 10. Semantic-pipe record schemas

All three register with the schema registry (paideia-os#2000) the day it
lands; until then, every emission carries the same
already-established-by-precedent line-based fallback + deferral header.

### 10.1 `HttpRequestRecord@0.1`

```
HttpRequestRecord@0.1 {
  audit_id:        u64
  method:          enum { GET, POST, HEAD, PUT, DELETE }
  url:             string
  scheme:          enum { HTTP, HTTPS }
  status:          u16          # 0 on INTENT / pre-send
  header_summary:  string       # a bounded (256-byte) joined-header preview, not the full header block
  body_bytes:      u64          # response body length; 0 on INTENT
  tls_used:        bool
  redirect_count:  u8
  invoker_user:    KIND_USER_ref
  result_code:     enum { OK, DNS_FAILED, CONN_REFUSED, TLS_KEY_MISMATCH,
                           TLS_HANDSHAKE_FAILED, HTTP_4XX, HTTP_5XX,
                           TIMEOUT, TOO_MANY_REDIRECTS, NO_PERMISSION,
                           DRY_RUN, AUDIT_ONLY, INTENT }
  ts_ns:           i128
}
```

Two records per real invocation (INTENT before DNS/connect, RESULT
after), one record for `--dry-run` (`result_code: DRY_RUN`), one for
`--audit-only` (`result_code: AUDIT_ONLY`) — same INTENT/RESULT pairing
convention `mount.pdxfs` established, extended with the two CLI-specific
terminal states neither mount nor umount needed.

### 10.2 `DnsQueryRecord@0.1`

```
DnsQueryRecord@0.1 {
  audit_id:      u64
  qname:         string
  qtype:         enum { A, UNSUPPORTED }
  answer_ip:     u32           # 0 if no answer
  ttl:           u32
  cname_hops:    u8
  txn_id:        u16           # the randomized transaction ID used (§2.3.1) — present so an
                                 # audit reviewer can independently confirm randomization happened
  result_code:   enum { OK, NXDOMAIN, TIMEOUT, MALFORMED_RESPONSE,
                         UNSUPPORTED_QTYPE, DRY_RUN }
  ts_ns:         i128
}
```

### 10.3 `TlsHandshakeRecord@0.1`

```
TlsHandshakeRecord@0.1 {
  audit_id:            u64
  server_name:         string     # SNI value sent, if any
  negotiated_cipher:   enum { CHACHA20_POLY1305_SHA256 }   # single-valued at v1; enum shape anticipates growth
  negotiated_kex:      enum { X25519 }                      # ditto — see §2.4's hybrid-KEM future note
  sig_algo:            enum { ED25519, MLDSA65_RESERVED }
  trust_cap_name:      string     # the pdxtrust-assigned name, not the raw key
  cert_chain_hash:     [u8;32]    # BLAKE3 of the single pinned key (no chain exists at v1; field name
                                    # kept for schema-shape continuity with a future X.509 mode, always
                                    # a 1-element "chain" today)
  verdict:             enum { OK, KEY_MISMATCH, HANDSHAKE_FAILED, TIMEOUT }
  ts_ns:               i128
}
```

---

## 11. What this wave will NOT achieve — debt inventory, stated up front

Written now, not discovered at closure, per §0.2's rule:

1. **No hybrid PQ KEM, no ML-DSA-65 verify.** §2.4's X25519+Ed25519
   choice is a real, load-bearing scope cut against the brief's own
   "post-quantum by default" ask. Upgrading needs paideia-as intrinsics
   that don't exist (§12.4) plus a follow-up `libpdx-net` milestone.
2. **No X.509 / CA-chain support**, hence no public-internet HTTPS
   browsing (§0.5). This is a deliberate architectural bet, not an
   oversight, but it is a real capability gap `pkg`'s future
   real-mirror-fetching plans need to reckon with (§11.7).
3. **No UDP server mode anywhere in this wave** (`pdxsock -lu`, a
   hypothetical multi-client DNS-server-side tool) — connected-UDP only
   (§12.1's minimal ask), because `recvfrom`/`sendto` with peer-address
   out-params doesn't exist.
4. **No raw sockets, no general packet crafting** — `pdxping`'s narrow
   `sys_icmp_echo` (§5.3) is deliberately not a stepping stone to a
   general raw-socket kind.
5. **Elevate fails closed everywhere** until paideia-os#1997 lands —
   `pdxping`'s privileged-protocol gate and `pdxtrust --system`'s write
   gate are both real-code-fails-closed, inherited directly from R64v2's
   debt item 3.
6. **Semantic-pipe records degrade to line-based text** until
   paideia-os#2000 lands — inherited directly from R64v2's debt item 6.
7. **`pkg` does not consume `libpdx-net`/`libpdx-url` in this wave.** The
   task brief lists this as an eventual integration; this plan's issue
   count does not include `pkg`-side work, both because `pkg`'s
   maintainers are a separate workstream and because `pkg`'s real
   use case (fetching from a package mirror) almost certainly needs the
   X.509/CA-chain mode this wave explicitly does not build (§11.2) —
   wiring `pkg` to `pdxcurl`'s raw-pubkey-only TLS mode now would either
   force every package mirror to publish a pinned raw key (operationally
   heavy) or leave `pkg` HTTP-only (a real security regression versus
   even a partial-trust HTTPS). Recommend treating "`pkg` over the
   network" as its own future-round design question, not a checkbox this
   wave can honestly claim.
8. **No IPv6 anywhere** (§2.2) — the kernel has no IPv6 socket support at
   R72; nothing in this library speaks it either.
9. **DNS resolver has no cache** beyond a single process's lifetime
   (§0.4) and parses only `A`/`CNAME` records (§2.3).

---

## 12. Coordination points for osarch (syscall-boundary contract)

Four items, in priority order (§12.4 is the largest, §12.1 is the most
milestone-blocking):

### 12.1 UDP-via-socket (blocks `libpdx-net`.M2/M3, `pdxdig`, `pdxsock`.M3)

Extend SC+87 (`sys_socket`) to accept `domain=AF_INET(2)`,
`sock_type=SOCK_DGRAM(2)`. Extend SC+91 (`sys_connect`) to, for a UDP
socket, set a default peer without a handshake (no SYN/ACK). SC+92/93
(`send`/`recv`) on a connected UDP socket send/receive one datagram per
call, preserving message boundaries (a `recv` into a too-small buffer
truncates the datagram rather than blocking for more, matching BSD-socket
UDP semantics). SC+88 (`bind`) on a UDP socket claims a local port —
needed if a caller wants a stable source port; ephemeral auto-assignment
on `connect()`-without-`bind()` (Linux's own default behavior) is
acceptable and probably simplest. **No `sendto`/`recvfrom` with an
address out-param at this round** — connected-UDP-only is a deliberately
minimal ask that unblocks every consumer in this plan (DNS query to a
known server, `pdxsock -u` to a known peer) without touching the larger
"receive from an arbitrary sender" design space (§11.3). Recommend
retiring/ignoring the R27 `KIND_UDP_SOCKET`/0x50 RPC-based path (§0.3) —
it is not what this ask ties into.

### 12.2 ICMP echo syscall (blocks `pdxping`.M2)

A dedicated `sys_icmp_echo(dst_addr, seq, payload_ptr, payload_len,
timeout_ms) -> rtt_ns | -errno` at the next free SC+ ordinal (placeholder
96). See §5.3 for the narrow-surface rationale. Gated by a new elevate
policy class `R_NET_PRIVILEGED_PROTOCOL` at the calling convention level
(the syscall itself can be unconditional at the kernel layer if elevate
is enforced entirely in userspace via the existing fail-closed
`libpdx-elevate` pattern — osarch's call whether a kernel-side capability
check is also warranted; this plan does not require one, but flags it as
worth osarch's own security judgment given ping-flood/DoS potential).

### 12.3 `KIND_TLS_TRUST` derived kind (blocks `pdxtrust`.M2, `pdxcurl`.M3)

**Before allocating**, resolve or explicitly confirm-harmless the
existing **0x1A5 ordinal collision** between `KIND_PDXFS_MOUNT_TABLE`
(R53, base `KIND_MEMORY`, dispatched via `cap_invoke_dispatch`) and
`KIND_TCP_SOCKET` (R72, base `KIND_IPC_ENDPOINT`, explicitly *not*
dispatched via `cap_invoke_dispatch` per its own design comment in
`cap/kind.pdx`). Both currently define the numeric tag `0x1A5`. This is
almost certainly latent-harmless today (TCP sockets never reach the
generic `cap_invoke` dispatch path per their own design note), but it is
a live registry-integrity defect this plan does not want to compound by
allocating a third overlapping tag. Recommend a documentation pass (at
minimum, a cross-reference comment in both files acknowledging the
shared numeric value and why it's safe) or a renumber of one of the two,
done by main/osarch, **before** `KIND_TLS_TRUST` lands.

Proposed placeholder ordinal (chosen to sit safely past every currently
allocated tag, including the collision above, regardless of how it
resolves): `KIND_TLS_TRUST = 0x1A7`, derived over `KIND_MEMORY` (base
4) — the underlying resource (a raw public key + algorithm tag + label,
~64 bytes) is exactly the same shape of "inert descriptor over a memory
page" as `KIND_SIG_KEY`/`KIND_PDXFS_MOUNT_TABLE`, so it should follow
their dispatch pattern (a `cap_invoke_dispatch` branch, mint-gate
validated) rather than the TCP-socket family's direct-syscall pattern —
`pdxcurl` reads a `KIND_TLS_TRUST` cap's contents once per invocation at
setup, not on a hot per-packet path, so `cap_invoke`'s dispatch overhead
is irrelevant here.

Rights: `R_TLS_TRUST_READ` (bit 0) only — no write/mint/revoke rights
needed by a *consumer* (`pdxcurl`); `pdxtrust` itself, as the *minter*,
needs the kernel-side mint gate but not a "write" right on an already-
minted cap (trust anchors are immutable once minted; "update" is
"remove, then re-import" at the `pdxtrust` CLI layer, §8.1).

### 12.4 paideia-as crypto-intrinsic escalation (blocks `libpdx-net`.M3 entirely)

File this against **paideia-as**, not paideia-os, and start it as early
as possible — it is the longest-lead-time item in the whole plan. Needed,
in dependency order:

1. **SHA-256** — needed for TLS 1.3's transcript hash and as the HMAC
   base. No existing paideia-as intrinsic computes any SHA family hash
   (BLAKE3 exists per the self-hosting roadmap's stdlib-expansion list,
   but TLS 1.3 is specified against SHA-256, not BLAKE3 — this is not a
   place PaideiaOS gets to pick its own hash and still interoperate).
2. **HMAC-SHA256 + HKDF-Extract/Expand** (RFC 5869) — TLS 1.3's key
   schedule is defined entirely in terms of HKDF. Mechanical once SHA-256
   exists.
3. **X25519** (RFC 7748) — the key-exchange primitive per §2.4's
   near-term choice. A single well-known constant-time Montgomery-ladder
   implementation; reference test vectors are widely available (RFC 7748
   §5.2).
4. **Ed25519 sign + verify** (RFC 8032) — the signature primitive per
   §2.4. Sign is needed only if a future round wants PaideiaOS-side
   servers to authenticate with Ed25519 too (not required for `pdxcurl`
   as a pure client, which only ever *verifies*); verify is the hard
   client-side requirement.
5. **(Follow-up, not blocking R100)** `mldsa65_verify` — closes the debt
   item r64v2 already flagged and is the prerequisite for this plan's
   deferred §11.1 hybrid-PQ upgrade.

Suggest filing items 1–4 as a single paideia-as milestone (mirroring how
`mldsa65_sign` landed as one clean issue+version-bump pair, #1330/#1331)
since they are used together and nothing in `libpdx-net` needs them
piecemeal — a partial landing (say, SHA-256 alone) unblocks nothing on
its own.

---

## 13. Milestone + issue breakdown

R100.M1..M5 across seven repos + one substrate-prep batch, mirroring R53
discipline (M1 scaffold, M2 real body, M3 audit+elevate+semantic-pipe,
M4 tests+smoke, M5 signed release).

### §13.0 Substrate prep (paideia-os + paideia-as, before tool M2/M3s open)

```
paideia-os.R100-PREP-000 Resolve or confirm-harmless the KIND_PDXFS_MOUNT_TABLE / KIND_TCP_SOCKET 0x1A5 ordinal collision (§12.3)
paideia-os.R100-PREP-001 KIND_TLS_TRUST = 0x1A7 derived-kind + witness (cap_invoke_dispatch branch, mint-gate, R_TLS_TRUST_READ)
paideia-os.R100-PREP-002 Extend sys_socket/sys_connect/sys_send/sys_recv/sys_bind (SC+87/88/91/92/93) to accept SOCK_DGRAM/AF_INET, connected-UDP semantics only (§12.1)
paideia-os.R100-PREP-003 sys_icmp_echo new syscall (SC+ placeholder 96) + R_NET_PRIVILEGED_PROTOCOL elevate policy class (§12.2)
paideia-os.R100-PREP-004 Boot-seeded resolver config file/path (single resolver IP, tmpfs-scoped) for libpdx-net's resolver to consume (§9.4)
paideia-as.R100-PREP-005 Crypto-intrinsic escalation: SHA-256, HMAC-SHA256, HKDF-Extract/Expand, X25519 keygen+scalarmult, Ed25519 sign+verify (§12.4) — single milestone, four primitives
```

**Ordering.** PREP-000 blocks PREP-001. PREP-001 blocks `pdxtrust`.M2 and
`pdxcurl`.M3 (real trust-anchor consumption). PREP-002 blocks
`libpdx-net`.M2's UDP half, `pdxdig`.M2, `pdxsock`.M3. PREP-003 blocks
`pdxping`.M2. PREP-004 blocks `libpdx-net`.M2's resolver-config read.
PREP-005 blocks `libpdx-net`.M3 entirely (TLS cannot produce a working
handshake without it) — this is the one item main should consider
opening *immediately*, in parallel with every repo's M1, since it has no
dependency on anything else in this plan and the longest lead time.

Every M1 across all seven repos can open **immediately**, in parallel,
against stub signatures — none of PREP-000..005 blocks a scaffold.

### §13.1 `libpdx-net` (paideia-os/libpdx-net) — 22 issues

**M1** (#1–#3): scaffold + module boundary; public API stubs (§2.1); NetErr/DnsErr/TlsErr/HttpErr enum shapes.
**M2** (#4–#10): TCP wrapper (net_socket/connect/send/recv/close/bind/listen/accept, real, §2.2); endian helpers (htons/ntohs/htonl/ntohl); net_inet_pton; DNS query builder + response parser as pure functions (§2.3, real regardless of PREP-002 status); net_resolve socket-transport half (blocked on PREP-002, ships stubbed if not landed).
**M3** (#11–#16): net_tls_wrap + TLS 1.3 handshake (X25519 + Ed25519-verify + ChaCha20-Poly1305 record layer, blocked on PREP-005); KIND_TLS_TRUST consumption (blocked on PREP-001); TlsHandshakeRecord@0.1 emission; transaction-ID randomization for the resolver (§2.3.1).
**M4** (#17–#20): HTTP/1.1 client (http_get/http_post, chunked decode, redirect handling per §2.5).
**M5** (#21–#22): dual-signed release + .pdxdoc + CHANGELOG.

```
libpdx-net.M1-001 scaffold + module boundary
libpdx-net.M1-002 public API stubs: net_socket/bind/connect/send/recv/close/inet_pton/resolve/tls_wrap (§2.1)
libpdx-net.M1-003 NetErr/DnsErr/TlsErr/HttpErr enum shapes + first-runnable stub test
libpdx-net.M2-001 real TCP wrapper: net_socket/connect/send/recv/close over SC+87/91/92/93/3
libpdx-net.M2-002 real net_bind/net_listen/net_accept over SC+88/89/90 (for pdxsock server mode)
libpdx-net.M2-003 endian helpers: htons/ntohs/htonl/ntohl (real byte-swap, one call-site family)
libpdx-net.M2-004 net_inet_pton: dotted-quad IPv4 string parse
libpdx-net.M2-005 DNS query builder: RFC 1035 header + one-question encode (pure function, no socket)
libpdx-net.M2-006 DNS response parser: header/rcode/ancount + A/CNAME record decode (pure function, no socket)
libpdx-net.M2-007 net_resolve socket transport: UDP connect+send+recv to configured resolver (blocked on R100-PREP-002)
libpdx-net.M3-001 net_tls_wrap: TLS 1.3 ClientHello/ServerHello over X25519 (blocked on R100-PREP-005)
libpdx-net.M3-002 TLS 1.3 key schedule: HKDF-based early/handshake/master secret derivation (blocked on R100-PREP-005)
libpdx-net.M3-003 Ed25519 transcript-signature verify against KIND_TLS_TRUST-pinned key (blocked on R100-PREP-001 + R100-PREP-005)
libpdx-net.M3-004 ChaCha20-Poly1305 record layer: seal/open application data per RFC 8446 §5.2-5.3
libpdx-net.M3-005 TlsHandshakeRecord@0.1 schema bind + emit (OK and every refusal path)
libpdx-net.M3-006 resolver transaction-ID randomization + response-ID verification (§2.3.1)
libpdx-net.M4-001 http_get: request-line + header encode, status-line + header decode
libpdx-net.M4-002 http_post: Content-Length body encode
libpdx-net.M4-003 chunked transfer-encoding decode
libpdx-net.M4-004 redirect handling: 301/302/303/307/308 method-preservation matrix + 10-hop cap + cross-scheme-downgrade refusal
libpdx-net.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc for doc libpdx-net
libpdx-net.M5-002 mirror push
```

(count: 22)

### §13.2 `libpdx-url` (paideia-os/libpdx-url) — 11 issues

```
libpdx-url.M1-001 scaffold + module boundary + grammar constants (RFC 3986 subset)
libpdx-url.M1-002 Url struct shape + url_parse/url_to_string stubs
libpdx-url.M2-001 scheme + host + port parse
libpdx-url.M2-002 path + query + fragment parse (fragment dropped before any network use)
libpdx-url.M2-003 userinfo parse + immediate rejection (no embedded credentials)
libpdx-url.M3-001 scheme allow-list validator (http/https only)
libpdx-url.M3-002 malformed-percent-encoding rejection + oversized-URL cap
libpdx-url.M4-001 RFC 3986 Appendix B/C test vectors
libpdx-url.M4-002 fuzz target: 10^5 random byte strings never panic, always Result
libpdx-url.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc
libpdx-url.M5-002 mirror push
```

(count: 11)

### §13.3 `pdxcurl` (paideia-os/pdxcurl) — 20 issues

Full argv/record detail in `design/networking/pdxcurl-design.md`.

```
pdxcurl.M1-001 scaffold + caps.decl (KIND_USER, KIND_TLS_TRUST placeholder, KIND_IPC_ENDPOINT placeholder)
pdxcurl.M1-002 argv surface: method flags, --output, --data, --header, --trust, --dry-run, --audit-only, <url>
pdxcurl.M1-003 first runnable: --dry-run prints the HttpRequestRecord it would emit, no network I/O
pdxcurl.M2-001 libpdx-url integration: parse + validate <url>
pdxcurl.M2-002 HTTP-only (no TLS) GET against libpdx-net.http_get
pdxcurl.M2-003 --output FILE: write response body to a file
pdxcurl.M2-004 --data / POST body support
pdxcurl.M3-001 HTTPS path: --trust=<cap-uri> resolution + libpdx-net.net_tls_wrap wiring
pdxcurl.M3-002 libpdx-audit: INTENT record before DNS/connect, RESULT record after (shared audit_id)
pdxcurl.M3-003 semantic-pipe: HttpRequestRecord@0.1 schema bind + emit
pdxcurl.M3-004 --audit-only: INTENT-only path, no network I/O, distinct result_code
pdxcurl.M3-005 structured error taxonomy: map every failure mode to a distinct exit code + result_code (§4 point 7)
pdxcurl.M4-001 happy-path smoke: HTTP GET against a fixture server
pdxcurl.M4-002 HTTPS happy-path smoke: TLS handshake + GET against a pinned-key fixture server
pdxcurl.M4-003 failure-matrix smoke: connection refused, DNS NXDOMAIN, TLS_KEY_MISMATCH, HTTP 4xx/5xx
pdxcurl.M4-004 audit-trail assertion: every smoke run's audit journal has a matching INTENT/RESULT pair
pdxcurl.M4-005 redirect-chain smoke: 301/302/303/307/308 method-preservation cases
pdxcurl.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc for doc pdxcurl
pdxcurl.M5-002 mirror push
```

(count: 18; two more land if the redirect + audit-trail smokes split further — treat 18–20 as the working range)

### §13.4 `pdxping` (paideia-os/pdxping) — 13 issues

```
pdxping.M1-001 scaffold + caps.decl (KIND_USER, KIND_ELEVATE_CHANNEL placeholder)
pdxping.M1-002 argv surface: --count, --interval-ms, --timeout-ms, --dry-run, <host-or-ip>
pdxping.M1-003 first runnable: --dry-run prints the PingRecord it would emit
pdxping.M2-001 real sys_icmp_echo call + RTT capture (blocked on R100-PREP-003)
pdxping.M2-002 --count loop + summary stats (min/avg/max RTT, loss %)
pdxping.M3-001 R_NET_PRIVILEGED_PROTOCOL elevate request (fail-closed per §5.4)
pdxping.M3-002 libpdx-audit: one record per echo (not per session)
pdxping.M3-003 semantic-pipe: PingRecord@0.1 schema bind + emit
pdxping.M4-001 happy-path smoke: echo against a QEMU-reachable gateway
pdxping.M4-002 timeout-path smoke: unreachable host
pdxping.M4-003 elevate-denied-path smoke: confirms fail-closed behavior + correct exit code
pdxping.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc
pdxping.M5-002 mirror push
```

(count: 13)

### §13.5 `pdxdig` (paideia-os/pdxdig) — 15 issues

```
pdxdig.M1-001 scaffold + caps.decl (KIND_USER)
pdxdig.M1-002 argv surface: --type, --server, --timeout-ms, --dry-run, <name>
pdxdig.M1-003 first runnable: --dry-run prints the DnsQueryRecord it would emit
pdxdig.M2-001 real UDP query via libpdx-net.net_resolve (blocked on R100-PREP-002)
pdxdig.M2-002 --server= override (bypass boot-seeded resolver config)
pdxdig.M2-003 UNSUPPORTED_QTYPE handling for any --type beyond A
pdxdig.M3-001 libpdx-audit integration
pdxdig.M3-002 semantic-pipe: DnsQueryRecord@0.1 schema bind + emit (txn_id field, §2.3.1)
pdxdig.M4-001 happy-path smoke: A-record lookup against a fixture DNS server
pdxdig.M4-002 NXDOMAIN smoke
pdxdig.M4-003 timeout smoke
pdxdig.M4-004 malformed-response fuzz-derived fixture matrix
pdxdig.M4-005 CNAME-follow correctness (one hop, loop-guard at 4 hops)
pdxdig.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc
pdxdig.M5-002 mirror push
```

(count: 15)

### §13.6 `pdxsock` (paideia-os/pdxsock) — 17 issues

```
pdxsock.M1-001 scaffold + caps.decl (KIND_USER)
pdxsock.M1-002 argv surface: -l, -u, <host> <port> | <port>
pdxsock.M1-003 first runnable: --dry-run prints the mode + target it would use
pdxsock.M2-001 TCP client: connect + stdin-to-socket + socket-to-stdout loop
pdxsock.M2-002 TCP server: bind+listen+accept, single-connection-at-a-time
pdxsock.M3-001 UDP client: connected-UDP mode (blocked on R100-PREP-002)
pdxsock.M3-002 libpdx-audit integration
pdxsock.M3-003 semantic-pipe: SockSessionRecord@0.1 (bytes-in/out, peer, duration)
pdxsock.M4-001 TCP echo round-trip smoke (client against a pdxsock -l fixture)
pdxsock.M4-002 UDP echo round-trip smoke (once R100-PREP-002 lands)
pdxsock.M4-003 server-refuses-second-connection behavior smoke + documentation
pdxsock.M4-004 large-transfer smoke (buffer-boundary correctness, >64KiB stream)
pdxsock.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc
pdxsock.M5-002 mirror push
```

(count: 14; pad to 16–17 in refinement with a `-u` listen-mode-refusal issue + a `--dry-run` UDP-mode issue if main wants exact parity with other repos' issue density)

### §13.7 `pdxtrust` (paideia-os/pdxtrust) — 15 issues

```
pdxtrust.M1-001 scaffold + caps.decl (KIND_USER, KIND_TLS_TRUST placeholder, KIND_ELEVATE_CHANNEL placeholder)
pdxtrust.M1-002 argv surface: import/list/show/remove subcommands
pdxtrust.M1-003 .pubkey file format parser (algo tag + key bytes + label, §8.1)
pdxtrust.M2-001 real KIND_TLS_TRUST mint from a parsed .pubkey (blocked on R100-PREP-001)
pdxtrust.M2-002 user-scope trust-store read/write (~/.config/pdxtrust/)
pdxtrust.M2-003 list/show real bodies against the user-scope store
pdxtrust.M3-001 --system scope + elevate wiring (fail-closed per §0.2)
pdxtrust.M3-002 libpdx-audit integration
pdxtrust.M3-003 semantic-pipe: TrustAnchorRecord@0.1 schema bind + emit
pdxtrust.M4-001 import->list->show->remove round-trip smoke
pdxtrust.M4-002 malformed-.pubkey-file rejection matrix (bad algo tag, wrong key length, oversized label)
pdxtrust.M4-003 system-scope elevate-denied-path smoke
pdxtrust.M4-004 duplicate-name-import refusal + --force override + audit-trail assertion
pdxtrust.M5-001 dual-signed manifest.pdxsig + CHANGELOG-1.0 + .pdxdoc
pdxtrust.M5-002 mirror push
```

(count: 15)

### §13.8 Wave summary

| Repo | Issues | Opens after | Real body blocked on |
|---|---:|---|---|
| libpdx-net | 22 | (immediate M1) | PREP-002 (M2 UDP half), PREP-005 (M3 all), PREP-001 (M3 trust) |
| libpdx-url | 11 | (immediate M1) | — (no kernel/paideia-as dependency at all) |
| pdxcurl | 18–20 | libpdx-net.M1 + libpdx-url.M1 | PREP-001, PREP-005 (M3) |
| pdxping | 13 | libpdx-net.M1 | PREP-003 (M2) |
| pdxdig | 15 | libpdx-net.M1 | PREP-002 (M2) |
| pdxsock | 14–17 | libpdx-net.M1 | PREP-002 (M3 UDP half only) |
| pdxtrust | 15 | libpdx-net.M1 | PREP-001 (M2) |
| Substrate prep | 6 | (immediate) | Blocks the wave's M2/M3 gate, not M1 |
| **Total** | **~114–119** | | |

---

## 14. First end-to-end smoke

Once PREP-001/002/003/005 have all landed (the wave's real completion
gate, not any individual repo's M5), the acceptance scenario:

1. QEMU boot reaches shell prompt with a loopback HTTP fixture server
   reachable at a known QEMU-host IP:port (harness responsibility).
2. `pdxtrust import fixture-server /boot/fixture.pubkey` — mints a
   `KIND_TLS_TRUST` cap.
3. `pdxcurl --trust=fixture-server https://<fixture-ip>/` — real TLS 1.3
   handshake (X25519 + Ed25519 verify + ChaCha20-Poly1305), real HTTP GET,
   200 response, audit trail has one INTENT + one RESULT record.
4. `pdxdig fixture-server-hostname` — real UDP DNS query against a
   fixture resolver, returns the fixture server's IP.
5. `pdxping <fixture-ip>` — real ICMP echo, non-zero RTT, elevate granted
   (assumes #1997 has also landed by this point — if not, this step's
   smoke instead asserts the correct fail-closed exit code, which is
   still a passing smoke, just a different assertion).
6. `pdxsock -l 9000` in one shell path / `echo hi | pdxsock <host> 9000`
   in another — TCP round-trip.

Each stage lands a fingerprint line in the boot smoke golden, mirroring
R53's `tests/r53/shell-shutdown.golden` discipline.

---

*End of document.*
