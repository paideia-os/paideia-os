# DNS: Stub Resolver vs. Full Cache

**Status:** informational split.
**Landed:** R93.M3-004 (paideia-os #2057).
**Related:** `design/network/dns-cache.md` (target design),
`src/kernel/core/net/dns.pdx` (current stub).

## What lives where

- `src/kernel/core/net/dns.pdx` is a **stub resolver**. Single UDP
  query per lookup, fixed 0xDEED transaction id, 2-second budget,
  one retry, no cache, no negative caching, no AAAA, no DNSSEC,
  refuses compression pointers beyond one hop, refuses labels > 63
  bytes. Everything the stub does not know how to handle -- NXDOMAIN,
  TRUNCATED, malformed replies, unknown option classes -- is
  answered with a cleanly-refused `0` return so a caller never sees
  garbled state.

- `design/network/dns-cache.md` is the **target design** for once
  a resolver is worth professionalizing. That document specifies a
  10k-entry LRU (100 MiB cap), negative-response caching, per-user
  namespaces, EDNS(0), TTL-driven expiry, cache-side stampede
  protection, and observability hooks. None of that lives in the
  stub.

## Why the split

R93's scope was "make the boot witness resolve one hostname against
QEMU SLIRP's DNS" -- a two-order-of-magnitude smaller problem than
what `dns-cache.md` describes. Landing the full cache at this
milestone would have pulled in an LRU allocator (kernel .bss
budget), a hash table, a TTL wheel, and negative-entry sentinels --
all before there is a second caller of `dns_resolve` to argue for
any specific set of design tradeoffs.

Deferring to a follow-up landing is the R91-plan's stated posture
(§7 R93.M3 "dns-cache.md is the target, not the stub"). This file
crystallises that split so a future contributor asking "why isn't
this file just implementing dns-cache.md?" gets the honest answer
here rather than reading the stub's source header for the same
statement.

## The trigger for upgrading

The stub becomes inadequate the moment ANY of these hold:

1. A second in-tree caller of `dns_resolve` (userspace tool,
   another kernel subsystem) exists. The stub's "no cache, no LRU"
   posture is fine for one boot-witness lookup; two callers arguing
   for the same hostname want a cache.
2. Real-user ring-3 code lands a DNS-consuming daemon (curl-like,
   http client, TLS-with-hostname). The stub's fixed 2-second
   budget and lack of parallelism become user-visible latency.
3. A DNS-answer trust story becomes needed (DNSSEC, DoT, DoH). The
   stub has no room for any of it.
4. NXDOMAIN discrimination matters. The stub returns 0 for both
   NXDOMAIN and TIMEOUT -- a caller that wants to know which is
   which needs the wider return-code shape `dns-cache.md` allocates.

At that point this file is superseded by the `dns-cache.md`
implementation and can be deleted.

## What NOT to do incrementally

Do NOT grow the stub to fit new callers by adding tiny features
piecewise (a 4-entry LRU here, a TTL check there). Any non-trivial
addition to the stub crosses the "worth professionalizing"
threshold and should be the first landing of the `dns-cache.md`
design instead. The whole point of documenting the split here is
so that transition happens once, deliberately, rather than through
drift.
