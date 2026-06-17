# PaideiaOS — Network: DNS Resolver Cache

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** DNS resolver cache sizing and policy. Addresses NET-O5.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| DNS-D1 | TTL-respecting cache | RFC 1035 standard |
| DNS-D2 | Default cache: 10,000 entries, 100 MiB max | Reasonable for most use |
| DNS-D3 | LRU eviction | Standard |
| DNS-D4 | DNSSEC verification cached separately | Standard |
| DNS-D5 | Per-user cache namespaces | Privacy |

---

## 1. Cache structure

Each entry: domain, type, value(s), original TTL, expiry time. Indexed by (domain, type).

---

## 2. Per-user namespaces

A multi-user system caches per-user; an entry in user A's cache is not shared with user B (privacy: prevents cross-user DNS fingerprinting).

---

## 3. Negative caching

Failed lookups are cached with a short TTL (default 60s) to avoid hammering upstream.

---

## 4. Open issues

| ID | Issue |
|---|---|
| DNS-O1 | Cache size tuning per workload. |
| DNS-O2 | Cache persistence across reboots — not done by default. |

---

*End of document.*
