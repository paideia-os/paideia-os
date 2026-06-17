# PaideiaOS — Dev Env: CI Profiles Format

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Format of QEMU CPU-feature profile files. Addresses dev-env J1.

---

## 0. Decision

**TOML format** — human-readable, structured, well-supported in both Rust and shell tooling.

---

## 1. Profile file structure

`ci/profiles/<profile_name>.toml`:

```toml
[profile]
name = "aspirational"
description = "Sapphire Rapids modeling all features"

[cpu]
model = "Sapphire-Rapids"
enable = ["la57", "lam", "amx-tile", "amx-bf16", "amx-int8", "avx512vnni"]
disable = []

[machine]
type = "q35"
firmware = "OVMF"
tpm = "swtpm-crb"
intel-iommu = true

[memory]
size = "8G"
numa-domains = 2

[devices]
nics = ["virtio-net-pci"]
storage = ["nvme"]
gpus = []
usb = ["xhci"]

[testing]
mitigations = "max"
testset = "full"
```

---

## 2. Validation

Each profile is validated at CI run time:
- Required fields present.
- CPU model exists in pinned QEMU.
- Feature flags valid for chosen CPU model.

---

## 3. Open issues

| ID | Issue |
|---|---|
| PF-O1 | Profile composition (extend a base profile). |

---

*End of document.*
