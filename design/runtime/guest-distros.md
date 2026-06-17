# PaideiaOS — Runtime: VM Guest Distribution Support

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Linux distribution support beyond Alpine in the VM jail. Addresses JAIL-O8.

---

## 0. Decisions summary

| # | Choice | Rationale |
|---|---|---|
| GD-D1 | Alpine Linux: tested, canonical | Small, musl-based |
| GD-D2 | Debian/Ubuntu: best-effort | Common |
| GD-D3 | Fedora: best-effort | RHEL-family |
| GD-D4 | Arch: community-supported | Rolling release |
| GD-D5 | Other: user-supplied, no testing | Flexibility |

---

## 1. Per-distro support level

| Distro | Support | Notes |
|---|---|---|
| Alpine | Full | Default; all features tested |
| Debian Stable | Best-effort | Most-common Linux |
| Ubuntu LTS | Best-effort | Most-common in cloud |
| Fedora | Best-effort | Red Hat ecosystem |
| Arch | Community | Rolling; rapid changes |
| NixOS | Community | Different boot model |
| Custom | User-supplied | Verify PVH support |

---

## 2. Required guest features

Any guest must:
- Support PVH boot (no BIOS legacy needed).
- Support virtio-blk, virtio-net, virtio-console, virtio-rng.
- Not require legacy devices (no VGA, PS/2, IDE).

---

## 3. Open issues

| ID | Issue |
|---|---|
| GD-O1 | Boot wrappers for each distro to handle differences. |
| GD-O2 | Documentation for each distro. |

---

*End of document.*
