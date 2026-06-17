# PaideiaOS — Network: NTS Upstream Server Selection

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** NTS upstream server pool and trust criteria. Addresses NET-O6.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| NTS-D1 | Default upstreams: 4 from diverse providers | Quorum |
| NTS-D2 | Configurable per user | Flexibility |
| NTS-D3 | Median-based clock sync | Outlier resistance |

---

## 1. Default upstream pool (illustrative; TODO: verify current operators)

- `time.cloudflare.com` (NTS support)
- `nts.netnod.se`
- `nts.ptb.de`
- One additional regionally-diverse server

---

## 2. Trust criteria for upstreams

- TLS cert chains to a recognized CA.
- NTS-KE handshake succeeds.
- Sustained service availability.

---

## 3. Anomaly handling

If one upstream consistently disagrees with the median, exclude it; alert.

---

## 4. Open issues

| ID | Issue |
|---|---|
| NTS-O1 | Real upstream selection. |

---

*End of document.*
