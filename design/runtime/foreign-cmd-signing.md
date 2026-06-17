# PaideiaOS — Runtime: Foreign Command Signing Verification

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Foreign command registry signature verification. Addresses JAIL-O6.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| FCS-D1 | Every foreign command's registry entry is PQ-signed | Standard |
| FCS-D2 | Signer: project release-line, or trusted-third-party for community packages | Trust chain |
| FCS-D3 | Verifier checks chain at registration | Pillar 6 |

---

## 1. Verification

When a foreign command is registered:
1. Read signature from registry entry.
2. Verify against release-line public key (or trusted-third-party key).
3. Verify chain to root via algorithm catalog.
4. If verified: install.
5. If failed: refuse + audit.

---

## 2. Trusted third parties

Community-distributed foreign commands can be signed by community-vetted keys. Each user opts in to which community packagers they trust.

---

## 3. Open issues

| ID | Issue |
|---|---|
| FCS-O1 | Community key infrastructure. |

---

*End of document.*
