# PaideiaOS — Terminal: Cross-Host Pipeline Authentication

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Authentication when a pipeline crosses host boundaries. Addresses SH-O13.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| CHA-D1 | Cross-host pipeline uses cross-host IPC bridge per `ipc/cross-host-bridge.md` | Standard |
| CHA-D2 | The remote shell receives the user's identity via the bridge's auth handshake | Identity |
| CHA-D3 | Remote authorizes via per-user capability env | Standard |

---

## 1. Flow

```
local shell: @remote.host find . | ...

local shell: opens cross-host bridge to remote.host
  - Hybrid-KEM handshake (per PQ doc).
  - Local user identity (signed by local supervisor) sent.

remote.host: receives identity
  - Verifies signature (chains to remote's trust).
  - Mints a remote-side per-user capability env.
  - Starts a "shell session" for this user.

remote shell: executes `find .` per local user's identity.
remote shell: streams records back over the bridge.
local shell: consumes records, processes via local stages.
```

---

## 2. Trust requirements

- The remote host's supervisor must trust the local host's identity claim.
- This trust is configured via the federation membership (per `capabilities/distributed.md`).

---

## 3. Open issues

| ID | Issue |
|---|---|
| CHA-O1 | Cross-host capability translation (per distributed.md). |

---

*End of document.*
