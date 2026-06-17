# PaideiaOS — Dev Env: CI Vendor Choice

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Concrete CI vendor decision. Addresses dev-env open issue S2.

---

## 0. Decision

**GitHub Actions for the public-facing pipeline; self-hosted runners for QEMU/bare-metal stages.** Per dev-env §10.2 binding.

## 1. Why GitHub Actions

- Already chosen for the public face.
- Lowest friction for external contributors.
- Integrates with `gh` CLI.
- Free tier sufficient for current scale.

## 2. Portability

The pipeline scripts in `tools/ci/` are CI-system-agnostic. The GitHub Actions YAML in `ci/pipelines/` is a thin wrapper. If GitHub Actions becomes inadequate, scripts port to Buildkite or Jenkins with low effort.

## 3. Open issues

| ID | Issue |
|---|---|
| CV-O1 | Self-hosted runner OS — likely NixOS for reproducibility. |

---

*End of document.*
