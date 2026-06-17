# PaideiaOS — Runtime: Multi-Jail Interactions

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Pipeline-record passing between jails. Addresses JAIL-O10.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| MJ-D1 | Jails communicate via typed channels mediated by the shell | Standard |
| MJ-D2 | Direct memory sharing between jails not supported | Isolation |
| MJ-D3 | For shared memory: use a host-mediated file in PaideiaOS-typed memory | Indirection |

---

## 1. Inter-jail pipeline

```
shell> cmd1 | cmd2 | cmd3
```

If `cmd2` and `cmd3` are foreign:
- Shell creates two typed channels.
- Each jail receives cap halves at start.
- Within each jail, the WASI bridge presents stdin/stdout to the WASM side.

---

## 2. Schema across jails

The pipeline records use the schema declared in each foreign command's registry entry. The bridge converts between PaideiaOS records and the jail-internal form.

---

## 3. Open issues

| ID | Issue |
|---|---|
| MJ-O1 | Performance under high inter-jail throughput. |

---

*End of document.*
