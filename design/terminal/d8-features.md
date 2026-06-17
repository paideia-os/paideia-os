# PaideiaOS — Terminal: D8 Advanced Semantic-Shell Features

**Status:** Draft v0.1 (phase 3+)
**Date:** 2026-06-17
**Scope:** Phase 3+ advanced features for the semantic shell (D8 from feature inventory). Addresses SH-O8.

---

## 0. Features

### 0.1 History-as-Datalog

The shell history is itself a graph queryable by Datalog:

```
?- history(?e), command(?e, ?c), contains(?c, "find"), modified(?e) > yesterday
```

This is more powerful than `C-r` reverse search.

### 0.2 Semantic search

Across all past sessions: find commands that produced records matching a schema.

```
?- output(?cmd, ?r), schema(?r, "FileSchema"), tag(?r, "research")
```

### 0.3 Saved query templates

```
saved query "find pdf cited by knuth" = ...
```

User can save complex pipeline + Datalog queries as named templates; recall by name.

### 0.4 Visual program builder

A graphical mode (in addition to the REPL) where pipelines are constructed via drag-and-drop.

---

## 1. Phase 3+ delivery

Phase 2: typed pipelines + Datalog + lambda (the core).
Phase 3+: these advanced features.

---

## 2. Open issues

| ID | Issue |
|---|---|
| D8-O1 | Visual program builder UX — requires GUI work. |

---

*End of document.*
