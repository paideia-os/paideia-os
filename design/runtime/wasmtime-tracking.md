# PaideiaOS — Runtime: wasmtime Upstream Tracking

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** wasmtime upstream commit pin and update cadence. Addresses JAIL-O1.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| WT-D1 | Pin to a stable upstream release | Reproducibility |
| WT-D2 | Update cadence: every 6 months or on critical fix | Balance |
| WT-D3 | Track via Nix package pin per dev-env §7.3 | Standard |
| WT-D4 | PaideiaOS-side patches in `wasmtime-patches/` | Visible |

---

## 1. Current pin (illustrative)

```toml
[wasmtime]
upstream = "https://github.com/bytecodealliance/wasmtime"
pinned_release = "v25.0.0"  # subject to selection
pinned_commit_hash = "<TBD>"
nix_derivation = "nix/packages/wasmtime.nix"
```

---

## 2. Update process

1. Watch upstream releases.
2. Test against PaideiaOS WASI conformance corpus.
3. Open update PR.
4. Merge.

---

## 3. Open issues

| ID | Issue |
|---|---|
| WT-O1 | Initial pin at phase 2 start. |
| WT-O2 | Patch policy. |

---

*End of document.*
