# PaideiaOS — ACPI: ACPICA Upstream Tracking

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Commit pin and update cadence for the ACPICA upstream. Addresses AC-O1.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| TRK-D1 | Pin ACPICA to a stable upstream tag | Reproducibility |
| TRK-D2 | Update cadence: every 6 months or on critical security fix | Balance |
| TRK-D3 | Track via Nix package pin | Per dev-env §7.3 |
| TRK-D4 | All updates are merged via PR with review | Standard |
| TRK-D5 | Local patches kept in `acpica-patches/` | Visible |

---

## 1. Current pin

```toml
[acpica]
upstream = "https://github.com/acpica/acpica"
pinned_tag = "R10_15_25"  # (example; actual to be selected at phase 2 start)
pinned_commit_hash = "<TBD>"
nix_derivation = "nix/packages/acpica.nix"
```

---

## 2. Update process

1. Watch upstream releases.
2. Open a PR with new pin.
3. Run full PaideiaOS ACPI test corpus on the new version.
4. If pass: merge.
5. If fail: triage; either delay update or backport patches.

---

## 3. Patches

PaideiaOS-specific patches to ACPICA are kept in `src/userspace/acpica-bubble/upstream-patches/` and re-applied on each upstream sync. Patches should be minimal; whenever possible, contribute fixes upstream.

---

## 4. Open issues

| ID | Issue |
|---|---|
| TRK-O1 | The initial pin selection — coordinate with phase 2 start. |
| TRK-O2 | The patch policy — what's acceptable in PaideiaOS-side patches. |

---

*End of document.*
