# PaideiaOS — Terminal: History Storage

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Shell history per-user storage. Addresses SH-O6.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| HST-D1 | Per-user history at `/users/<u>/shell/history/` | Privacy |
| HST-D2 | Each entry records command, capability env, result, duration | Auditable |
| HST-D3 | Cap'n Proto-serialized records | Standard |
| HST-D4 | Retention: 10000 entries default; configurable | Standard |
| HST-D5 | Searchable via shell `C-r` and via Datalog queries | Rich access |

---

## 1. Per-entry schema

```capnp
struct HistoryEntry {
  timestamp @0 :UInt64;
  command @1 :Text;
  capabilityEnv @2 :CapEnvSummary;
  result @3 :ExitStatus;
  durationNanos @4 :UInt64;
  outputSchema @5 :Text;
}
```

---

## 2. Datalog access

```
?- history(?e), command(?e, ?c), contains(?c, "find")
```

History is queryable via Datalog as a first-class graph.

---

## 3. Retention

10000 entries default. Older entries optionally compacted to a "summary" form (date range + count of commands).

---

## 4. Privacy

History is per-user; not accessible to other users without the user's explicit grant.

---

## 5. Open issues

| ID | Issue |
|---|---|
| HST-O1 | Search index for performance. |
| HST-O2 | Multi-session synchronization. |

---

*End of document.*
