# net-tools `caps.decl` Adoption Inventory

Round: R90-XREPO.013.M4-002 (paideia-os #2132). Companion of the
M0-001 kernel substrate (`src/kernel/core/cap/reconcile.pdx`) and the
M1-001 format design (`design/architecture/caps-decl-format.md`).

## 1. Scope

Five network CLI tools ship under the R100 network-tooling wave.
None of the target repos live under `tools/user/` at the time of this
adoption inventory; they exist only as targets in the round plan:

- `pdxping` — ICMP echo (privileged protocol, on-demand elevate).
- `pdxcurl` — HTTP/HTTPS client (TLS trust anchor, sockets).
- `pdxsock` — raw socket helper (privileged protocol, on-demand elevate).
- `pdxdig` — DNS lookup (sockets, no elevate).
- `pdxtrust` — TLS trust-anchor administration.

**This document is design-only.** No source in `tools/user/` is
touched here — none of the five repos are locally submoduled. The
concrete embed lands in each tool's own repo via a per-tool follow-up
ticket (see §4 below), gated on each repo's initial ELF pipeline
being in place. This file is the round-side inventory that (a)
states each tool's declared cap-set in the M1-001 format, (b)
records the deferral to the tool-side ticket, and (c) gives the
M5-001 closeout audit the expected-vs-observed table.

## 2. Declared cap-sets (target `caps.decl` per tool)

### 2.1 `pdxping`

```
# pdxping — ICMP echo (privileged protocol, elevate on demand).
# Wave: R100 (design/networking/*) + R90-XREPO.013.M4-002 adoption.

!KIND_USER               0x001   # invoker attribution (audit)
!KIND_NIC                0x001   # QUERY (link state, addr resolution)
 KIND_ICMP_SESSION       0x003   # OPEN + SEND (elevate-gated at runtime)
 KIND_IPC_ENDPOINT       0x001   # semantic-pipe stdout, deferred
```

Notes:
- Elevate cap is deliberately **absent** — `R_NET_PRIVILEGED_PROTOCOL`
  (`src/kernel/core/cap/cap_net_privileged.pdx`) is minted on demand
  by `svc.elevate-broker`, never held at exec. The M5-001 audit
  asserts this exactly (parent holds elevate; child's reconciled
  set drops it).
- `KIND_ICMP_SESSION` is optional so a `--help` invocation that
  never opens a session can run in the strictest reconciled set.

### 2.2 `pdxcurl`

```
# pdxcurl — HTTP/HTTPS client.
# Wave: R100 (design/networking/pdxcurl-design.md §8) +
#       R90-XREPO.013.M4-002 adoption.

!KIND_USER               0x001   # invoker attribution (audit)
!KIND_TCP_SOCKET         0x00F   # connect + read + write + close
 KIND_TLS_TRUST          0x001   # LOOKUP (HTTPS)
 KIND_NIC                0x001   # QUERY (route selection)
 KIND_IPC_ENDPOINT       0x001   # semantic-pipe stdout, deferred
```

Notes:
- `KIND_TCP_SOCKET` is mandatory: no useful invocation runs without
  a socket.
- `KIND_TLS_TRUST` is optional so `http://` (unencrypted) still runs
  under a reconciled set that dropped trust.
- No elevate — pdxcurl is unprivileged by design.

### 2.3 `pdxsock`

```
# pdxsock — raw socket helper (privileged protocol).
# Wave: R100 (design/networking/*) + R90-XREPO.013.M4-002 adoption.

!KIND_USER               0x001   # invoker attribution (audit)
!KIND_NIC                0x001   # QUERY (link state)
 KIND_RAW_SOCKET         0x00F   # OPEN + SEND + RECV + CLOSE (elevate-gated)
 KIND_IPC_ENDPOINT       0x001   # semantic-pipe stdout, deferred
```

Notes:
- Same elevate posture as `pdxping`: `R_NET_PRIVILEGED_PROTOCOL` is
  on-demand only, never in the exec-time decl.
- `KIND_RAW_SOCKET` optional so metadata invocations run in a
  strictly narrower set.

### 2.4 `pdxdig`

```
# pdxdig — DNS lookup.
# Wave: R100 (design/networking/*) + R90-XREPO.013.M4-002 adoption.

!KIND_USER               0x001   # invoker attribution (audit)
!KIND_UDP_SOCKET         0x00F   # bind + sendto + recvfrom + close
 KIND_TCP_SOCKET         0x00F   # optional TCP fallback (RFC 5966)
 KIND_NIC                0x001   # QUERY (route selection)
 KIND_IPC_ENDPOINT       0x001   # semantic-pipe stdout, deferred
```

Notes:
- Fully unprivileged. Elevate is not part of any pdxdig code path.
- TCP fallback optional so pure UDP invocations narrow further.

### 2.5 `pdxtrust`

```
# pdxtrust — TLS trust-anchor administration.
# Wave: R100 (design/networking/*) + R90-XREPO.013.M4-002 adoption.

!KIND_USER               0x001   # invoker attribution (audit)
!KIND_TLS_TRUST          0x00F   # LOOKUP + ADD + REMOVE + LIST
 KIND_PDXFS_FILE         0x003   # READ + WRITE (import from PEM)
 KIND_IPC_ENDPOINT       0x001   # semantic-pipe stdout, deferred
```

Notes:
- `KIND_TLS_TRUST` mandatory with the full rights band — this tool
  administers the trust root.
- `KIND_PDXFS_FILE` optional so a pure `--list` invocation runs
  without file authority.

## 3. Reconciliation-audit expectations

For each tool, the M5-001 closeout audit will run the tool under a
parent process holding a superset of its declared cap-set and record
the post-reconciliation cap-set. Two additional per-tool assertions
matter for the net-tools wave (round plan §5 fingerprint):

- **pdxping** and **pdxsock**: assert `R_NET_PRIVILEGED_PROTOCOL`
  is not held at exec (parent had it, decl omitted it, reconciled
  set drops it).
- **pdxcurl**: assert `KIND_TLS_TRUST` survives when parent had it
  and drops when parent did not.

Expected vs. observed table (populated once tool adoption lands):

| Tool       | Parent-held kinds (superset)                                                  | Expected reconciled cap-set                                     |
|------------|-------------------------------------------------------------------------------|-----------------------------------------------------------------|
| `pdxping`  | + `KIND_ELEVATE_CHANNEL`, + `KIND_TCP_SOCKET`                                 | 4 kinds as declared; elevate and tcp dropped                   |
| `pdxcurl`  | + `KIND_ELEVATE_CHANNEL`, + `KIND_UDP_SOCKET`                                 | 5 kinds as declared; elevate and udp dropped                   |
| `pdxsock`  | + `KIND_ELEVATE_CHANNEL`, + `KIND_TLS_TRUST`                                  | 4 kinds as declared; elevate and trust dropped                 |
| `pdxdig`   | + `KIND_ELEVATE_CHANNEL`, + `KIND_TLS_TRUST`                                  | 5 kinds as declared; elevate and trust dropped                 |
| `pdxtrust` | + `KIND_ELEVATE_CHANNEL`, + `KIND_TCP_SOCKET`                                 | 4 kinds as declared; elevate and tcp dropped                   |

## 4. Follow-up tickets (tool-side adoption)

The concrete `caps.decl` embed lands in each tool's own repo via
these tool-side tickets. They are filed at the same time this
inventory lands so the tool maintainers can pick them up; each
depends on the target repo's initial ELF pipeline being in place
(none exist yet — the repos are named targets in the round plan
but not bootstrapped):

| Ticket # | Repo                       | Title                                                     |
|----------|----------------------------|-----------------------------------------------------------|
| _TBD_    | `paideia-os/pdxping`       | `Adopt R90-XREPO.013 caps.decl format (M4-002)`           |
| _TBD_    | `paideia-os/pdxcurl`       | `Adopt R90-XREPO.013 caps.decl format (M4-002)`           |
| _TBD_    | `paideia-os/pdxsock`       | `Adopt R90-XREPO.013 caps.decl format (M4-002)`           |
| _TBD_    | `paideia-os/pdxdig`        | `Adopt R90-XREPO.013 caps.decl format (M4-002)`           |
| _TBD_    | `paideia-os/pdxtrust`      | `Adopt R90-XREPO.013 caps.decl format (M4-002)`           |

Each ticket references this document + `design/architecture/caps-decl-format.md`.
**Adoption pending tool-side repo creation** — none of the five
repos are locally submoduled at the time of this inventory. The
round plan §5 dep-chain notes the repos are still targets, not
extant.

## 5. Deferrals

- All five target repos are **absent** locally. This inventory is
  the round-side placeholder; the tool-side tickets are filed on the
  monorepo tracker but the actual `caps.decl` embed cannot happen
  until each tool has an initial ELF pipeline.
- `KIND_RAW_SOCKET`, `KIND_ICMP_SESSION`, `KIND_UDP_SOCKET`,
  `KIND_TCP_SOCKET` are R100 network-substrate kinds. Their ordinals
  and rights bands are not fully pinned in `src/kernel/core/cap/`
  at the time of this inventory; the decl entries above use their
  design-doc names, and the eventual embed will substitute the
  ratified ordinal names.
- `R_NET_PRIVILEGED_PROTOCOL` (bit 0x1000, per
  `cap_net_privileged.pdx`) is a *right* on `KIND_NIC` / raw-socket
  kinds, not a KIND unto itself, so it never appears as a decl line.
  Its runtime gate lives in `cap_check_r_net_privileged_protocol`
  and is exercised via `svc.elevate-broker`.

## 6. See also

- `design/architecture/caps-decl-format.md` — the format spec.
- `src/kernel/core/cap/reconcile.pdx` — the kernel substrate.
- `src/kernel/core/cap/cap_net_privileged.pdx` — the elevate right.
- `design/networking/pdxcurl-design.md` §8 — the extant pdxcurl decl draft.
- `design/user/fs-tools-caps.md` — the fs-tools sibling inventory.
- `design/round-retrospectives/r90-xrepo-013-closed.md` — the closeout audit.
