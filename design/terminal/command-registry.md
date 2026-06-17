# PaideiaOS — Terminal: Command Registry

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Command registry storage, update mechanism, and signature verification. Addresses SH-O4.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| CRG-D1 | Registry stored as CoW FS file at `/system/shell/commands.toml` | Standard location |
| CRG-D2 | Updates via PR-style mechanism (transactional commit) | Per FS doc |
| CRG-D3 | Each command entry is PQ-signed | Pillar 6 |
| CRG-D4 | Per-user override registry at `/users/<u>/shell/commands.toml` | Customization |

---

## 1. Registry file format

```toml
[command."find"]
substrate = "wasm"
binary = "/jail/wasm/find/find.wasm"
schema_input = "none"
schema_output = "FileSchema"
capabilities = ["fs.enumerate", "fs.read"]
version = "1.0.0"
signature = "..."

[command."curl"]
substrate = "wasm"
binary = "/jail/wasm/curl/curl.wasm"
schema_input = "none"
schema_output = "string"
capabilities = []  # network granted per-invocation
version = "8.5.0"
signature = "..."
```

---

## 2. Update mechanism

1. Editor of the registry holds `registry_write_cap` (granted by supervisor).
2. The editor stages changes.
3. A `commit` operation atomically updates the registry.
4. New commands available at next shell-session start.

---

## 3. Per-user override

User's `~/shell/commands.toml` can shadow or extend the system registry. Shell looks up: per-user first, then system.

---

## 4. Open issues

| ID | Issue |
|---|---|
| CRG-O1 | Hot-reload — does a running shell session pick up changes? Currently: no, restart required. |
| CRG-O2 | Conflict between user and system on the same command name. |

---

*End of document.*
