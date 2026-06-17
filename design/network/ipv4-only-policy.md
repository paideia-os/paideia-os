# PaideiaOS — Network: IPv4-Only Network Policy

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Behavior when the local network only provides IPv4. Addresses NET-O12.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| V4-D1 | IPv6 native; IPv4 supported | Per NET-D3 |
| V4-D2 | If only IPv4 available, network works fully via IPv4 | Compatibility |
| V4-D3 | Log audit event on IPv4-only network (informational) | Visibility |

---

## 1. Detection

At boot or when interface comes up:
- Check for IPv6 router advertisement (RA).
- If no RA: IPv4-only.

---

## 2. IPv4-only behavior

- All connections via IPv4.
- Happy Eyeballs degenerates (only A records consulted).
- DNS over UDP/53 if DoT/DoQ unavailable via IPv4 upstream.

---

## 3. User notification

The system records "IPv4-only network detected" in audit log but does not warn the user (this is acceptable, not anomalous).

---

## 4. Open issues

| ID | Issue |
|---|---|
| V4-O1 | Whether to encourage IPv6 deployment via documentation. |

---

*End of document.*
