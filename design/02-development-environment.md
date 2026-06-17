# PaideiaOS — Development Environment

**Status:** Draft v0.1 (merged)
**Date:** 2026-06-17
**Authors:** `osarch` (Parts I–V) and `softarch` (Parts VI–XII), jointly responsible for §XIII (joint invariants), §XIV (open issues), §XV (references).
**Purpose:** Authoritative specification of the PaideiaOS development environment. Covers target hardware, QEMU configuration, debug surfaces, bare-metal validation, boot-image conventions, repository layout, reproducible builds, the Q3 toolchain bootstrap chain, test taxonomy, the CI/CD pipeline, release-artifact signing, and contributor workflow.

**Hard inputs (do not relitigate):**
- `design/00-feature-inventory.md` — four-tier feature inventory.
- `design/01-foundational-decisions.md` — Q1 through Q15 are binding.

---

## 0. Scope and vocabulary

### 0.1 Scope split

| Part | Owner | Sections |
|---|---|---|
| **I. Target hardware matrix** | osarch | §1 |
| **II. QEMU configuration** | osarch | §2 |
| **III. Debug and observability** | osarch | §3 |
| **IV. Bare-metal validation** | osarch | §4 |
| **V. Boot- and disk-image conventions** | osarch | §5 |
| **VI. Repository layout** | softarch | §6 |
| **VII. Reproducible build environment** | softarch | §7 |
| **VIII. Toolchain bootstrap** | softarch | §8 |
| **IX. Test taxonomy** | softarch | §9 |
| **X. CI/CD pipeline** | softarch | §10 |
| **XI. Release & artifact signing** | softarch | §11 |
| **XII. Contributor workflow** | softarch | §12 |
| **XIII. Joint invariants** | joint | §13 |
| **XIV. Open issues** | joint | §14 |
| **XV. References** | joint | §15 |

### 0.2 Vocabulary

| Term | Meaning |
|---|---|
| **The assembler** | The custom in-house assembler from Q3, when contextually unambiguous. Otherwise *custom assembler* or `paideia-as`. |
| **`paideia-as`** | The custom assembler's binary name (placeholder). |
| **Bootstrap phase 1/2/3** | The three NASM-coexistence phases defined in §8. |
| **CI gate** | A blocking stage in the pipeline; a PR with a failing CI gate cannot land on `main`. |
| **Advisory stage** | A non-blocking stage; failure is reported but does not block landing. |
| **Linearity check** | The build-time static check from feature E14 (Q7 binding). |
| **The IPC primitive** | The Q1 novel wait-free dataflow primitive. |

### 0.3 Pillar discipline

Each major decision below cites the pillar(s) and binding decision(s) (Q1–Q15) it serves. Where a recommendation is *not* directly pillar-derived (e.g., engineering convenience), it is marked as such.

---

# Part I — Target Hardware Matrix

## 1. Target hardware matrix

### 1.1 Q11/Q7/Q12 tension recap

Three binding decisions push in opposing directions on minimum-supported silicon:

- **Q7** (capability runtime tags via LAM) needs Intel **Linear Address Masking**, which is shipped on Sapphire Rapids (4th Gen Xeon Scalable, server) and Meteor Lake (Core Ultra, client) and later. See Intel SDM Vol. 1, the chapter on "Linear Address Masking" (TODO: verify SDM volume/chapter number against current revision — LAM was added in a relatively recent SDM revision and the chapter naming has not been stable).
- **Q11** (TPM + TDX/SGX trust root) needs **TDX** on the server path (Sapphire Rapids and later) or **SGX** on client. SGX is deprecated on Xeon Scalable since Ice Lake-SP and was removed from many client SKUs after the 11th generation (Rocket Lake / Tiger Lake era) — this is documented in Intel ark.intel.com per-SKU feature lists and in Intel's product change notifications (TODO: verify the exact PCN identifying SGX removal on which client SKUs).
- **Q12** (48-bit default, 57-bit opt-in) needs **5-level paging** (CR4.LA57) for the opt-in path. 5-level paging is documented in Intel SDM Vol. 3A ch. 4 "Paging" and the Intel *5-Level Paging and 5-Level EPT White Paper* rev. 1.1 (2017). Hardware availability: Ice Lake-SP and later on the server side; client support varies — TODO: verify which client generation first ships CR4.LA57 capability bit (CPUID.(EAX=7,ECX=0):ECX[bit 16]). Tiger Lake is widely reported as having LA57 support; Alder Lake/Raptor Lake retain it.

These three needs do not converge on a single "minimum i7 generation" without compromise. We therefore stratify support.

### 1.2 Support stratification

We define three tiers of hardware support. The kernel detects the running CPU at boot (CPUID + MSR probing) and selects code paths accordingly.

| Tier | Definition | Pillar/decision rationale |
|---|---|---|
| **Aspirational** | Full hardware acceleration of every Q-decision. LAM, TDX (server) or full SGX (client), 5-level paging, AVX-512, AMX, CET (IBT + SS), all WAITPKG/UMWAIT, MPK/PKU, FSGSBASE, RDSEED. | Pillar 1 (full ISA); Q7, Q11, Q12. |
| **Recommended** | Modern client part with most-but-not-all of the aspirational features. LAM present, no TDX, possibly no SGX. 5-level paging present. AVX-512 may be fused-off. | Pragmatic dev target; Q11 falls back to software enclave. |
| **Minimum** | Older Skylake-class client part. No LAM, no TDX, no SGX (or deprecated), no 5-level paging. AVX-512 may be present (Skylake-X) or absent (Skylake-S). | Q7 software-LAM path; Q12 forced to 48-bit; Q11 software-enclave only. Establishes that PaideiaOS *can* boot on these but accepts weaker isolation. |

### 1.3 Feature × generation matrix

The following table is a best-effort summary keyed to public Intel documentation. Generation names follow Intel's marketing; codenames are given when more precise. **Anything below is to be reverified against ark.intel.com per-SKU and current SDM before being treated as authoritative.**

Legend: ✓ = hardware support; ✗ = absent; **SW** = software fallback path mandatory; **det** = detect-at-boot, behavior depends on SKU even within the family.

| Feature | Skylake (6th gen) | Coffee Lake (8/9th) | Ice Lake-U/Y (10th client) | Tiger Lake (11th) | Alder Lake (12th) | Raptor Lake (13th) | Meteor Lake (Core Ultra 1) | Sapphire Rapids (Xeon) | Emerald/Granite Rapids |
|---|---|---|---|---|---|---|---|---|---|
| AVX2, BMI1/2, ADX | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| AVX-512 (F/CD/BW/DQ/VL) | det (Skylake-X yes; -S no) | det | ✓ | ✓ | det (P-core only, often fused off) | det | det (TODO: verify) | ✓ | ✓ |
| AVX-512 VNNI | ✗ | ✗ | ✓ | ✓ | det | det | det | ✓ | ✓ |
| AMX (TILECFG/TILEDATA) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |
| CET IBT + Shadow Stack | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| MPK/PKU | ✓ (server SKUs first) | det | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| FSGSBASE | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| RDRAND, RDSEED | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| WAITPKG (UMWAIT/TPAUSE) | ✗ | ✗ | ✗ | ✓ (TODO: verify) | ✓ | ✓ | ✓ | ✓ | ✓ |
| INVPCID, PCID | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| x2APIC | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| TSC-deadline | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 5-level paging (LA57) | ✗ | ✗ | ✗ (TODO: verify Ice Lake client) | ✓ (TODO: verify) | ✓ | ✓ | ✓ | ✓ (Ice Lake-SP onward) | ✓ |
| LAM | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ (TODO: verify Meteor Lake LAM bit) | ✓ | ✓ |
| SGX (client) | ✓ | ✓ | ✓ | ✓ (last client gen with SGX, per Intel PCN — TODO: verify) | ✗ (deprecated) | ✗ | ✗ | n/a server | n/a |
| TDX | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ |
| TSX-NI (RTM) | det (microcode-disabled on many parts post-TAA) | det | det | det | det (E-cores lack RTM) | det | det | det | det |
| IBRS / eIBRS / STIBP / IBPB | microcode-added | microcode-added | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| TME / TME-MK / MKTME | det (server) | ✗ client | ✓ (TODO: verify) | ✓ (TODO: verify) | ✓ | ✓ | ✓ | ✓ | ✓ |
| VT-x / VT-d / EPT / APICv | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Cache Allocation Tech. (CAT/CMT) | server only | server only | det | det | server | server | server | ✓ | ✓ |

**Note on the "minimum i7" question.** The PaideiaOS pillars name "Intel i7 (Skylake-X / Ice Lake / Sapphire Rapids feature levels)" as the floor. With LAM only on Meteor Lake+ and TDX server-only, an honest reading is:

- **Minimum supported for full Q7 hardware path:** Meteor Lake (Core Ultra 1), client side; Sapphire Rapids, server side.
- **Minimum supported for software-LAM-fallback PaideiaOS:** Skylake-X (6th-gen Xeon W / X-series), because that is where the pillar floor is set and where AVX-512 is broadly present on client-adjacent silicon.
- **Recommended dev hardware:** any 12th-gen Core or later with VT-d, x2APIC, AVX-512 (where present), and a discrete or firmware TPM 2.0.

### 1.4 Feature × support-path table

For each pillar-relevant feature, this table maps generation availability to the runtime path PaideiaOS takes.

| Feature | Hardware path | Software fallback | Selected by |
|---|---|---|---|
| LAM (Q7 runtime tags) | LAM-on; high 15 bits of canonical VA carry tag; CPU masks on dereference | Manual mask in every capability-deref macro emitted by the custom assembler (Q3); tag stripped before `mov`/`call` | CPUID.(EAX=7,ECX=1):EAX[bit 26] (TODO: verify exact LAM CPUID bit and leaf) at boot; the choice baked into per-CPU code-emission preludes by the build system. |
| 5-level paging (Q12 opt-in) | CR4.LA57=1 for tagged address spaces; PML5 table populated | CR4.LA57=0; address space declared 57-bit fails at creation | CPUID.(EAX=7,ECX=0):ECX[bit 16] = LA57 capability. |
| CET (C10) | CR4.CET=1 + IA32_S_CET / IA32_U_CET MSRs; shadow stacks per thread | Software CFI via build-time check (E14); no shadow stack | CPUID.(EAX=7,ECX=0):ECX[bit 7] = CET_SS; ECX[bit 20] = CET_IBT. |
| MPK/PKU (C10) | WRPKRU-based intra-AS isolation in userspace servers | Page-table swap (expensive) or per-server process split | CPUID.(EAX=7,ECX=0):ECX[bit 3] = PKU. |
| AVX-512 (C17, D5, D6) | ZMM/opmask/hi16 saved in XSAVE area; vectorized PQ-crypto path | AVX2 fallback PQ-crypto path | XCR0 enumeration via CPUID leaf 0xD. |
| AMX (D5, D6) | TILECFG/TILEDATA in XSAVE; matrix runtime fast path | AVX-512 fallback | CPUID.(EAX=7,ECX=0):EDX[bit 24] = AMX-TILE (TODO: verify exact bit). |
| WAITPKG (C14) | UMWAIT/TPAUSE for low-power short waits | PAUSE-spin loop with adaptive backoff | CPUID.(EAX=7,ECX=0):ECX[bit 5] = WAITPKG. |
| TDX (Q11 high-volume signer) | Userspace VMM hosts a TD; PQ-signing service runs inside; TPM attests it | IOMMU-isolated PQ-signer userspace process attested by TPM only | TDX is detected via the TDX module presence; no architectural CPUID-only check is sufficient (host firmware must enable). |
| SGX (Q11 client legacy) | EPC-resident enclave for legacy interop only | Same software-enclave path as TDX-absent client | CPUID.(EAX=7,ECX=0):EBX[bit 2] = SGX. |
| TPM 2.0 (Q11 root) | LPC/SPI/CRB TPM device; PCR extends in firmware + boot | None — PaideiaOS *requires* TPM 2.0; absence is a hard failure on boot | Discovered via ACPI TPM2 table. |
| RDSEED (C15) | True-random seeding | RDRAND + jitter entropy + TPM `TPM2_GetRandom` mix | CPUID.(EAX=7,ECX=0):EBX[bit 18]. |
| Spectre/Meltdown mitigations (Q15) | eIBRS, STIBP, IBPB, MDS_CLEAR, L1D-flush as appropriate | Software KPTI-style page-table separation; retpoline thunks | Per-CPU MSR feature detection; Q15 mandates "max by default". |

**Citations for §1.** Intel SDM Vol. 1 (LAM, CET, AVX-512, AMX), Vol. 2 (CPUID), Vol. 3A ch. 4 (paging, LA57), ch. 6 (interrupts/exceptions), ch. 8 (multi-processor), Vol. 3B ch. 16 (machine check), Vol. 3C chs. 23–33 (VMX). Intel *5-Level Paging and 5-Level EPT White Paper* rev. 1.1 (2017). Intel *TDX Module Base Architecture Specification* rev. 1.5 (2023). Intel *VT-d Architecture Specification* rev. 4.1 (2022). TCG TPM 2.0 Library Specification Part 1 (Architecture), Rev. 1.59 (2019). For per-SKU verification: https://ark.intel.com.

---

# Part II — QEMU as the Primary Development Platform

## 2. QEMU configuration

QEMU is the primary dev/CI platform because (a) it can model every Intel-feature path PaideiaOS cares about via CPUID plumbing, (b) it supports the `swtpm` integration needed for Q11's TPM root, (c) its OVMF integration gives us a clean UEFI Secure Boot path matching C1/C11, (d) it is scriptable in a way that supports the determinism PaideiaOS needs for the novel IPC primitive's correctness work (Q1, D13). Hardware (§4) supplements but does not replace it.

We treat QEMU as having three operating modes that are relevant to PaideiaOS:

1. **TCG (Tiny Code Generator) mode** — full emulation, no host KVM. Maximum CPUID-plumbing freedom (we can synthesize any feature combination, including LAM on hosts without LAM). Lower performance, but architecturally faithful to the documented x86_64 semantics. **This is our primary CI mode**, because it lets us test feature-fallback paths without requiring matching hardware.
2. **KVM-accelerated mode** — uses host VMX. Much faster, but the guest CPUID is constrained by what the host CPU supports (and what the kernel exposes). **This is our primary developer-workstation mode** for fast iteration and the source of truth for SMP correctness.
3. **KVM-TDX mode** — TDX guests for D1 and Q11 testing. Requires a TDX-capable host. CI gate, not developer workstation default. (TODO: verify upstream QEMU + Linux KVM-TDX status as of 2026-06.)

### 2.1 Machine choice: `q35` vs `microvm` vs custom

We standardize on **`-machine q35,accel=...`** as the primary machine type.

**Why `q35`:**
- It models a PCIe-native chipset (Q35 + ICH9), matching PaideiaOS's "no legacy" pillar 5: the q35 board has no ISA bus baggage forced into the address map, MSI/MSI-X work as on real PCIe, and PCIe enumeration follows MCFG/ECAM conventions per E4. The older `-machine pc` (i440FX) is PCI not PCIe and is rejected on pillar grounds.
- It supports UEFI boot via OVMF naturally (pillar 5; C1).
- It supports `intel-iommu` for VT-d emulation (E4, U9).
- It supports `swtpm` integration (Q11; C11).
- It is the QEMU machine type that upstream development tracks most actively; new CPU features land here first.

**Why not `microvm`:**
- `microvm` is appealing for fast-boot scenarios but strips PCIe, ACPI, and UEFI. PaideiaOS *requires* ACPI (U1) and PCIe (E4); using `microvm` would mean maintaining a second non-ACPI boot path that exercises code paths we don't ship. Rejected.

**Why not a custom QEMU machine model:**
- Tempting for a clean-slate OS, but writing a QEMU machine model is a research project of its own and would couple PaideiaOS development to a fork of QEMU. Rejected pending Tier-4 future where a `paideia-virt` machine could expose research devices (e.g., a model of the wait-free IPC primitive's hardware-assisted variant if one is ever proposed).

**Concrete invocation skeleton:**

```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm,kernel-irqchip=split \
  -cpu host,migratable=off,+invtsc,+rdseed,+rdrand,+x2apic \
  -smp cpus=8,sockets=1,cores=8,threads=1 \
  -m 8G \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=OVMF_CODE.fd \
  -drive if=pflash,format=raw,unit=1,file=OVMF_VARS.fd \
  -chardev socket,id=chrtpm,path=/tmp/swtpm-sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
  -device intel-iommu,intremap=on,caching-mode=on \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-blk-pci,drive=disk0 \
  -drive if=none,id=disk0,format=raw,file=paideia.img \
  -serial mon:stdio \
  -display none \
  -d guest_errors,unimp -D qemu.log
```

`kernel-irqchip=split` is required for `intel-iommu` interrupt remapping (`intremap=on`). `caching-mode=on` on `intel-iommu` makes the IOMMU report TLB-invalidation faults that PaideiaOS's E4 server needs to exercise. See QEMU docs `docs/system/devices/intel-iommu.rst` (TODO: verify current QEMU docs path).

### 2.2 CPU model

Three regimes; each maps to a CI lane.

| `-cpu` model | When to use | What it gives | What it does not give |
|---|---|---|---|
| `host` | KVM developer workstation; SMP correctness floor | All host CPU features (LAM, TDX-host, AVX-512, etc.) up to host's capability | Cannot mask features below host's set; cannot synthesize features the host lacks |
| `Sapphire-Rapids` (or `Sapphire-Rapids-v2` etc.) | TCG CI lane modeling the *aspirational* tier | LAM, AVX-512 + AMX, CET, WAITPKG, MKTME, etc. as defined in QEMU's named CPU model | TDX (TDX requires host TDX module; not synthesizable by TCG) |
| `Icelake-Server` | TCG CI lane modeling the *recommended* tier | AVX-512, CET, MPK, 5-level paging, no LAM, no AMX | LAM, AMX (good — we want to exercise the LAM-absent path) |
| `Skylake-Client` or `Skylake-Server` | TCG CI lane modeling the *minimum* tier | Baseline AVX2/BMI/ADX/RDSEED, no AVX-512 on Client, no CET, no LAM, no 5-level paging | The full set of features Q7/Q11/Q12 require — exercises software fallbacks |
| `Meteor-Lake` (TODO: verify QEMU CPU model name) | TCG CI lane modeling client LAM target | Client LAM, no TDX, possibly no AVX-512 | Server features |

Use `-cpu <model>,+feature,-feature` to fine-tune. For example, to model a Sapphire Rapids-class CPU but force the AMX-fallback code path:

```
-cpu Sapphire-Rapids,-amx-tile,-amx-int8,-amx-bf16
```

**CPUID-plumbing verification.** The kernel's boot-time CPU detection must be tested against the QEMU-presented CPUID. We add a `cpuid-dump` early-boot diagnostic (writing to the C16 ring) and a CI assertion that compares the dump to the `-cpu`-model expected feature set. This catches mistakes such as testing on `-cpu host` when intending to test the minimum tier.

### 2.3 CPU-feature masking for fallback-path CI

This is the most important point in §2.

A clean-slate OS lives or dies by the discipline that **every fallback code path is exercised in CI**, not only on antique hardware that nobody has on their desk. Q7 (software-LAM), Q11 (software-enclave), Q12 (forced 48-bit), Q15 (mitigation modes), C10 (CET absent), C14 (TSX absent), all need explicit CI lanes.

We define the following named CI feature profiles, each a `-cpu <base>,±feature,...` invocation. The *content* of each profile is owned here; the CI orchestration that consumes them is in §10.

| Profile name | Base | Toggles | Tests |
|---|---|---|---|
| `aspirational` | `Sapphire-Rapids` | `+la57,+lam,+pks,+amx-tile,+amx-bf16,+amx-int8,+avx512vnni` | Hardware LAM, AMX, 5-level, CET; no TDX (TCG can't) |
| `recommended-client` | `Meteor-Lake` (TODO: verify) | `+la57,+lam,-amx-tile` | Client LAM, no AMX; exercises Q11 client fallback (software enclave) |
| `recommended-server-no-tdx` | `Sapphire-Rapids` | `-tdx` (TODO: verify if a QEMU toggle exists; otherwise omit the TDX module) | Server features minus TDX; exercises Q11 server fallback path |
| `minimum-skylake-x` | `Skylake-Server` | `+avx512f,+avx512cd,+avx512bw,+avx512dq,+avx512vl,-la57,-cet-ss,-cet-ibt,-lam,-waitpkg,-amx-tile` | Q7 software LAM, Q12 forced-48-bit, C10 software-CFI fallback |
| `minimum-skylake-s` | `Skylake-Client` | `-avx512f,...,-la57,-cet,-lam,-waitpkg,-amx-tile` | Adds AVX-512-absent fallback (PQ crypto vectorization falls to AVX2) |
| `paranoid-mitigations` | `Sapphire-Rapids` | `+spec-ctrl,+stibp,+ssbd,+ibpb,+ibrs,+md-clear,+l1d-flush` (TODO: verify QEMU naming for each Spectre/Meltdown feature toggle) | Q15 max-mitigations on by default |
| `relax-mitigations` | `Sapphire-Rapids` | mitigation features off | Q15 `relax-mitigations` capability path; verify Q15's auditing fires |

**Why TCG matters here.** Under KVM, `-cpu host,-feature` cannot synthesize a feature the host lacks; it can only hide features. To synthesize LAM on a non-LAM host or AMX on a non-AMX host you must use TCG. This is the strongest reason TCG is in the CI critical path — it lets us run the LAM-on path on any CI box, not only on Meteor Lake hardware.

### 2.4 Memory model

PaideiaOS needs to exercise:

- **48-bit vs 57-bit page tables** (Q12). The choice is per-address-space; the kernel's page-table builder must work for both. CI runs the entire test matrix under both `+la57` and `-la57`.
- **NUMA topology** (C2, C6). QEMU's `-numa` option synthesizes NUMA domains:
  ```
  -object memory-backend-ram,id=mem0,size=4G
  -object memory-backend-ram,id=mem1,size=4G
  -numa node,nodeid=0,memdev=mem0,cpus=0-3
  -numa node,nodeid=1,memdev=mem1,cpus=4-7
  -numa dist,src=0,dst=1,val=20
  ```
  This is mandatory for testing C6's NUMA-aware work stealing and C2's per-domain free lists. CI should include a 2-domain and a 4-domain configuration.
- **Hugepages.** `-mem-prealloc` plus host-side `madvise(MADV_HUGEPAGE)`, or backing memory with `memory-backend-file` on `hugetlbfs`. Exercises C3's huge-page paths (2 MiB, 1 GiB).
- **memory-backend-file for persistent-memory experiments** (D11). Maps a host file as guest-visible memory; PaideiaOS's PMem-typed memory capability can be exercised even though we are not modeling true PMem semantics (no `clwb` durability on host file). Mark CXL.mem as out-of-scope for Q4 2026 dev work; revisit when QEMU CXL device model matures (TODO: verify current state of QEMU `-device cxl-type3` and `-machine cxl=on` flags).

### 2.5 Firmware: OVMF (UEFI) and Secure Boot

UEFI boot is required by pillar 5 and C1.

- **OVMF distribution.** OVMF (the Open Virtual Machine Firmware, an EDK2 build) is distributed by upstream EDK2 and packaged by most Linux distros (`/usr/share/OVMF/OVMF_CODE.fd`, `/usr/share/OVMF/OVMF_VARS.fd`). We pin a known-good OVMF revision in the Nix package set (§7.3).
- **Secure Boot path.** OVMF supports Secure Boot when built with the `SECURE_BOOT_ENABLE` flag. To exercise C11's measured-boot continuation, the PaideiaOS bootloader must be signed with a PK injected into the OVMF NVRAM at first boot.
- **Custom PK injection.** The recommended workflow is:
  1. Generate a PK/KEK pair (we will start with ECDSA-P384 and add ML-DSA-65 hybrid once OVMF supports PQ signature parsing — TODO: verify upstream EDK2 PQ-signature status; as of mid-2026, EDK2 PQ work was in progress and may or may not have landed).
  2. Use `virt-fw-vars` (from `virt-firmware` Python package; TODO: verify package name and current location) or the `EnrollDefaultKeys` approach to populate `OVMF_VARS.fd` ahead of boot.
  3. Sign the PaideiaOS UEFI loader (`paideia-loader.efi`) with the matching SB key.
- **Measured boot (PCR extension).** OVMF, when given a vTPM, performs UEFI/TCG measurements into PCRs 0–7 per the TCG PC Client Platform Firmware Profile Spec. PaideiaOS's loader extends measurements into PCRs 8+ for kernel image, root CSpace, and root task. Citation: TCG PC Client Platform Firmware Profile Specification Family 2.0, Level 00 Revision 1.05 (2021).

### 2.6 TPM via `swtpm`

`swtpm` is the user-space TPM 2.0 emulator that pairs with QEMU. It implements the TPM 2.0 spec sufficiently for measured boot, PCR extension, attestation key creation, and `TPM2_GetRandom` mixing into C15.

- **Invocation.** A typical CI setup runs `swtpm socket --tpm2 --tpmstate dir=$STATE --ctrl type=unixio,path=$STATE/sock` and points QEMU at it via `-chardev socket,id=chrtpm,path=$STATE/sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0`. We use the **CRB** (Command Response Buffer) interface, not TIS, because CRB is the PCIe-era interface and pillar 5 disfavors legacy TIS.
- **PQ-signing root (Q11).** As of mid-2026, TPM 2.0 PQ signature support is *not generally available* — TCG has work in flight on PQ extensions, but the available `swtpm` builds do not yet expose ML-DSA or SLH-DSA primitives (**TODO: verify** TCG PQ TPM working group status and `swtpm` upstream PQ patch series, if any). Consequence: our Q11 design must, for the next iteration of this document, assume:
  - TPM holds classical (ECDSA-P384 or RSA-3072) attestation keys.
  - PQ signing is performed by a userspace signer attested by the TPM (per Q11's "TDX/SGX enclave" branch on capable hardware, or by the software-enclave fallback on client hardware).
  - The first opportunity to make the TPM itself PQ-aware is gated on `swtpm` upstream merging PQ support.

This is one of the document's top open issues; see §14.

### 2.7 TDX / SGX

**TDX status under QEMU/KVM (2026-06).** KVM-TDX patches have been moving through upstream Linux for several cycles. Upstream QEMU has corresponding `-object tdx-guest` and `-machine ...,confidential-guest-support=tdx0` support landing alongside (TODO: verify the exact options against the current upstream QEMU master). At the time of writing, end-to-end "boot a TD on a Sapphire Rapids workstation under upstream Linux + upstream QEMU without out-of-tree patches" is *just becoming* viable on cutting-edge distro kernels. PaideiaOS dev assumption: TDX testing is **opportunistic**, not a CI gate, until the upstream stack stabilizes.

Workaround if TDX is unusable:
- Implement the Q11 software-enclave fallback path *first*; treat TDX as a future acceleration.
- Reserve a single dedicated CI host with TDX-capable Xeon as the only TDX gate (this affects CI runner topology — see §10.6).

**SGX status (2026-06).** SGX on client is dead; SGX on server (Xeon SP) was removed after Ice Lake-SP. QEMU's SGX support targets the older epoch and is unlikely to advance. Recommendation: do not invest in SGX-via-QEMU testing. Restrict SGX support to legacy-interop on client hardware that has SGX in firmware, treated as a *desirable* (D2), not a *required* path. **This decision should be acknowledged in `design/security/pq-trust-root.md` when written.**

### 2.8 IOMMU (VT-d emulation)

PaideiaOS's strict-microkernel pillar puts drivers in userspace (pillar 3, E3, E4). The IOMMU is therefore not optional; it is the mechanism by which userspace drivers are *isolated* from the rest of memory.

Configuration: `-device intel-iommu,intremap=on,caching-mode=on,device-iotlb=on`. Key flags:

- `intremap=on` — enables IRQ remapping. Required so MSI/MSI-X to userspace driver servers is routed correctly. Requires `-machine ...,kernel-irqchip=split`.
- `caching-mode=on` — the IOMMU reports IOTLB invalidation events. Necessary to exercise PaideiaOS's E4 IOMMU manager's invalidation paths under realistic conditions.
- `device-iotlb=on` — enables ATS (Address Translation Services). Realistic for modern PCIe devices.
- `aw-bits=48` (or 57 to match Q12 opt-in) — address-width configuration. CI should run both. (TODO: verify QEMU's current default aw-bits and how it interacts with guest LA57.)

We also enable a second QEMU CI lane with `-device intel-iommu,...,passthrough=on` (no translation) to test the path where PaideiaOS handles devices without an IOMMU — this should *fail closed*: such devices must not be passed to userspace drivers without an IOMMU, per pillar 6.

### 2.9 Devices and the microkernel servers they exercise

Every QEMU device must correspond to a PaideiaOS userspace server it exercises. The CI lanes select device combinations to fan out coverage.

| QEMU device | PaideiaOS server / subsystem exercised | Notes |
|---|---|---|
| `virtio-blk-pci` | NVMe driver server (E5 stand-in); block-cache server | Use as primary disk until native NVMe model is exercised |
| `nvme` | E4 PCIe enumeration + E5 NVMe driver | Real NVMe-class device; preferred for E5 testing |
| `virtio-net-pci` | E3 driver framework + E7 network stack | Use for fast iteration; switch to `e1000e` or `igb` (if available) for real-driver work |
| `virtio-scsi-pci` | Optional; exercises SCSI translation only if we choose to support it (not currently required by any tier) | Likely defer |
| `virtio-gpu-pci` | U5 graphics stack — initial bring-up only | A real Intel GPU is via VFIO passthrough on bare metal |
| `virtio-serial`, `pci-serial` | C16 in-kernel log → userspace log server | Primary debug sink early |
| `usb-host`, `nec-usb-xhci`, `qemu-xhci` | U3 xHCI driver + USB class drivers | xHCI is the correct controller (pillar 5: no EHCI/UHCI) |
| `intel-hda` + `hda-duplex` | U4 audio stack | Only for late-bring-up audio work |
| `tpm-crb` (with swtpm) | C11 / Q11 root-of-trust | CRB only; no TIS (pillar 5) |
| `virtio-9p-pci` (`-virtfs`) | **Early dev only:** host-fs passthrough for `paideia-loader.efi` and kernel image during inner-loop iteration. Not a shipped FS. | Replace with native CoW FS (Q4) once available |
| `vhost-vsock-pci` | Optional: cross-VM IPC experimentation, D14 distributed-capability prototype | Use `-netdev socket` first; revisit vsock for low-overhead host-guest control plane |

### 2.10 Multicore (`-smp`) and KVM vs TCG

- **CI baseline:** `-smp cpus=4,sockets=1,cores=4,threads=1` (4-core) for fast lanes; `-smp cpus=8,sockets=2,cores=4,threads=1` paired with `-numa` for the NUMA lane; `-smp cpus=16` for scheduler stress on a single NUMA domain.
- **Heterogeneous (P+E core) emulation.** QEMU TCG does not faithfully model Intel's hybrid topology by default; CPUID leaf 0x1F (extended topology v2) reporting heterogeneous cores requires explicit topology fiddling (TODO: verify QEMU's `-smp` "module" / "cluster" parameters and their interaction with CPUID 0x1F). For C6's heterogeneous-aware path, **KVM on Alder Lake or later host** is the source of truth; TCG can do best-effort.
- **KVM-on-bare-metal as SMP correctness floor.** Wait-free / lock-free correctness (Q1, C14) is sensitive to memory-model fidelity. TCG implements x86_64 TSO but is single-threaded internally for many emulation tasks; cross-vCPU race timing differs from real hardware. **Conclusion:** *correctness* (does the algorithm ever deadlock or produce a torn read) must be validated under KVM on real SMP hardware; TCG is for code-path *coverage*, not concurrency *correctness*. This is a load-bearing distinction and should be repeated in CI lane documentation.

### 2.11 Networking

E7 (networking stack) is a top-tier essential feature. QEMU offers several `-netdev` backends; we use them in distinct roles.

| `-netdev` backend | Purpose | When |
|---|---|---|
| `user` (SLIRP) | Default; no host config; gives outbound NAT | Inner-loop dev; CI smoke tests |
| `tap` | Layer-2 to host bridge; lets two guests share an L2 segment | Cross-VM E7 integration tests; distributed-capability D14 prototypes |
| `socket` (`listen=`, `connect=`, `mcast=`) | Connects multiple QEMU instances over a unix socket or UDP multicast at L2 | D14 distributed-capability experiments; multi-node testing without a host bridge |
| `vhost-user` (with DPDK / SPDK) | Userspace dataplane on host; lowest overhead | Performance work for E7 fast path; not a CI requirement |

Recommendation: CI defaults to `user`; an integration lane runs two-guest `socket` topology to exercise PaideiaOS's E7 across a non-trivial L2 hop.

---

# Part III — Debug and Observability

## 3. Debug and observability

PaideiaOS is a clean-slate OS; the cost of *not* having good debug surfaces is paid every day. The QEMU debug surface is enormous; we use a curated subset.

### 3.1 gdbstub

QEMU's `-s -S` exposes a gdbstub on TCP 1234 and halts the CPU at reset. The recommended development workflow:

```
qemu-system-x86_64 ... -s -S
```

Then in another shell:

```
gdb paideia-kernel.elf
(gdb) target remote :1234
(gdb) hbreak _start
(gdb) c
```

Notes:

- `hbreak` (hardware breakpoint) is needed because soft breakpoints rely on writable code, which our 16-bit→64-bit early boot path may not honor before paging is configured.
- Source-level debug needs DWARF in the kernel ELF. The custom assembler (Q3) must emit DWARF .debug_info and .debug_line at minimum. This is a hard requirement on the assembler; flag it for `design/toolchain/custom-assembler.md`.
- We will maintain a `scripts/gdb/paideia.py` script that decodes capability tables, CSpace contents, and the C16 log ring. The *shape* of those structures is owned by the kernel/toolchain teams; the script lives under `tools/` and ships with the dev shell (§7.3).

### 3.2 QEMU `-d` flags and `-trace`

Useful default for kernel bring-up:

```
-d guest_errors,unimp,cpu_reset -D qemu.log
```

`cpu_reset` is essential — it dumps the full CPU state on any reset (triple-fault). `unimp` catches PaideiaOS attempts to use a feature QEMU didn't emulate (commonly an unsupported MSR or an LAM bit on a TCG model that doesn't have LAM).

For deep debugging, `-d int,exec,in_asm` is exhaustive but produces gigabytes of output. Use sparingly with `-singlestep`.

`-trace event=...` is the targeted alternative. Useful events for PaideiaOS:

- `apic_*` — for x2APIC and IPI debugging (C8, C18).
- `kvm_*` — when running under KVM, to see vmexits.
- `vfio_*` — for device passthrough.
- `tpm_*` — for measured-boot debugging.

Integration with the C16 in-kernel log ring: PaideiaOS's log ring should also be readable from a host-side tool that snapshots the guest's physical memory (via QEMU's `pmemsave` monitor command or the `gdb` `dump memory` command). We will publish a small parser; this is part of the dev tooling.

### 3.3 Performance counters (PMU)

QEMU TCG **does not** faithfully emulate the Intel PMU. CPUID may report PMU features, but the counters do not reflect actual microarchitectural events. Consequence:

- **PMU correctness:** test only under KVM on bare metal. TCG PMU is for code-path testing (does our perfmon driver compile and call the right MSRs?), not perfmon correctness (do the counter values mean anything?).
- KVM PMU passthrough requires the host to make PMU events available to the guest. By default, modern KVM exposes a subset. For PaideiaOS we will need PMC events related to TLB misses, cache misses, retired branches (for the wait-free IPC primitive's empirical evaluation, Q1). `-cpu host,migratable=off,+pmu` is the relevant invocation (TODO: verify the precise QEMU/KVM flags for full PMU passthrough as of the current QEMU release).

This delineation between TCG and KVM matters and should be reinforced in CI lane docs.

### 3.4 Record / replay (deterministic debugging)

This is the single most important QEMU capability for Q1 (novel wait-free dataflow IPC primitive).

QEMU supports record/replay via:

```
qemu-system-x86_64 ... -icount shift=auto,rr=record,rrfile=replay.bin
```

and later

```
qemu-system-x86_64 ... -icount shift=auto,rr=replay,rrfile=replay.bin
```

This serializes the guest execution to be deterministically replayable. For PaideiaOS:

- **Use case 1 (Q1 wait-freedom shake-out):** record a workload that exercises the IPC primitive, then replay under gdb to isolate the exact instruction sequence where a hazard manifests. Without this, debugging a multi-vCPU wait-free protocol violation is heroic.
- **Use case 2 (D13 record/replay debugging at IPC granularity):** the kernel can emit replay marker events that pair with QEMU's record stream, giving us IPC-event-level replay over CPU-instruction-level replay.
- **Constraints.** `-icount` forces TCG (no KVM record/replay). SMP record/replay is supported in recent QEMU (TODO: verify the QEMU version where SMP rr became reliable; historically it was uniprocessor-only). Even where SMP rr works, deterministic-replay overhead is significant — this is for debugging, not performance.

**Implication for the IPC primitive design.** `design/ipc/wait-free-dataflow.md` should specify what *replay markers* the IPC primitive emits (e.g., on each enqueue, dequeue, and capability-pass), and the format of those markers, so the debugger can map QEMU's instruction-stream replay onto logical IPC events. This is a constraint imposed on the IPC design from outside.

### 3.5 Snapshots

`savevm <name>` and `loadvm <name>` from the QEMU monitor (or `-loadvm` at startup) save and restore guest state to a qcow2 internal snapshot. We use snapshots to:

- Skip slow init (UEFI boot, ACPI enumeration) on the inner dev loop.
- Save a "just-booted" snapshot per CPU-feature profile (`aspirational.snap`, `minimum.snap`, etc.) for quick CI test-case startup.
- Save a "just-before-IPC-test" snapshot for replay-style debugging of IPC scenarios.

Snapshots require qcow2-backed storage; the disk image convention (§5) accommodates this.

---

# Part IV — Bare-Metal Validation

## 4. Bare-metal validation

QEMU is the inner loop; bare metal is the floor. There are several classes of behavior QEMU does not (and cannot) model faithfully.

### 4.1 Where QEMU fidelity ends

- **Cache coherency edge cases.** TCG does not model the actual cache hierarchy; KVM passes through but the timing differs from native execution. Hazards involving non-temporal stores (`movnt*`), `clwb`/`clflushopt`/`clflush` ordering, and write-combining (WC) memory all need bare-metal verification.
- **Microarchitectural side channels.** Spectre/Meltdown-family mitigations (Q15) are about microarchitectural state. QEMU does not implement speculation in its CPU model; KVM passes through but the *measurement* of mitigation efficacy must be done on real hardware with real workloads.
- **Real TDX and SGX measurements.** QEMU+KVM-TDX can run a TD, but the actual SEAM measurement chain (MRCONFIGID, MRTD, RTMR) is only authoritative on real TDX silicon.
- **Real TPM behavior.** `swtpm` implements the TPM 2.0 spec but does not model real TPM quirks: SPI timing, vendor-specific NV behavior, PCR-extend latency. Attestation flows must be tested against a real discrete or fTPM.
- **Real NIC offloads.** TSO, LRO, RSS with real Toeplitz hash, RoCE, RDMA, DPDK fast paths — all require real silicon.
- **Cache Allocation Technology, RAPL counters, hardware P-states (HWP).** QEMU exposes the MSR interface but the *values* are synthetic. RAPL energy accounting (D15) is only meaningful on bare metal.
- **CET shadow stack runtime behavior.** QEMU TCG implements CET to some extent (TODO: verify TCG CET coverage in current QEMU); real CPUs have subtle behavior around interaction with VMX, NMIs, and `INT n`. Bare-metal validation required for security claims.

### 4.2 Minimum bare-metal validation matrix

This matrix is aspirational; the project will hit it asymptotically. The point is to enumerate what we want to be able to claim, and on what silicon, before declaring PaideiaOS "validated" on a feature.

| Hardware class | Why this slot | Features validated |
|---|---|---|
| One Skylake-era client (e.g., 6th/8th gen Core i7) | Minimum tier floor | Software LAM, forced 48-bit, no CET, no AVX-512 (or Skylake-X for AVX-512), software enclave |
| One Tiger Lake / Rocket Lake client with SGX | Last client with SGX; client measured boot | Q11 client SGX legacy path; CET present; AVX-512 client variant |
| One Alder Lake / Raptor Lake client | Hybrid topology; CET; AVX-512 fused-off variant; no LAM | C6 P+E scheduler validation; CET; mitigations |
| One Meteor Lake (Core Ultra) client | Client LAM target | Q7 hardware LAM client path |
| One Sapphire Rapids Xeon | Aspirational tier server | TDX (Q11), AMX (D5/D6), LAM, full 5-level paging, MKTME, AVX-512 + VNNI |
| One Emerald Rapids or Granite Rapids Xeon | Forward target | Same as above plus newer mitigations; future features |
| One NUMA 2-socket Xeon | NUMA real-world | C2/C6 NUMA pathologies, IPI fan-out, cross-socket cache-coherence pathologies |

This is what the project should be looking to acquire over time. **None of this is required for Q1 development to begin** — QEMU is sufficient — but the bare-metal program needs to start in parallel because lead time on TDX-capable hardware is non-trivial.

---

# Part V — Boot- and Disk-Image Conventions

## 5. Boot-image and disk-image conventions

### 5.1 Build artifacts

The build produces (and the CI pipeline of §10 must understand):

| Artifact | Format | Purpose | Consumers |
|---|---|---|---|
| `paideia-loader.efi` | PE/COFF (UEFI x86_64 application) | UEFI-stub bootloader; performs measured-boot extends; loads kernel | OVMF, real UEFI firmware |
| `paideia-kernel.elf` | ELF64 (relocatable or fully-linked depending on bring-up phase) | The kernel image; carries DWARF for debug | gdb; the loader (via internal ELF parser) |
| `paideia-kernel.bin` | Flat binary | Raw image for QEMU `-kernel` direct boot during inner loop | QEMU `-kernel` |
| `paideia-roottask.pax` | Custom (PAX, per E2) | Initial userspace root task in the capability-aware format | Loaded by kernel from initial bundle |
| `paideia-initcaps.bundle` | TBD (likely Cap'n Proto, since Q13 names it as the wire format) | Initial capability set for the root task: ACPI tables, framebuffer, log endpoint | Kernel hands to root task at startup |
| `paideia.iso` | El Torito-less, UEFI-bootable ISO image | Full disk-image boot for QEMU UEFI mode and real hardware install | QEMU `-cdrom`; real-hardware test boots |
| `paideia.img` (qcow2) | qcow2 with GPT, EFI System Partition, PaideiaOS-CoW partition | Primary QEMU disk for CI and dev | QEMU `-drive` |

Notes:

- **No initrd-equivalent in the Linux sense.** PaideiaOS's "initrd-equivalent" is the *root capability bundle* (`paideia-initcaps.bundle`). It is not a filesystem image; it is a serialized capability graph that the kernel materializes into the root task's CSpace at startup. This is a direct consequence of pillar 3 (strict microkernel — the root task spawns the rest of the system) and Q4 (we have no filesystem ready at the very earliest boots).
- **PAX format.** The capability-aware executable format (E2) is itself a design artifact that doesn't yet exist. For the very early kernel sprints, the root task may be a flat ELF or even a flat binary embedded in the kernel image; PAX support is added in concert with E2's design document.

### 5.2 Boot configurations under QEMU

Three QEMU boot configurations are supported. The choice depends on what is being tested.

| Configuration | Invocation flavor | When to use | What is exercised |
|---|---|---|---|
| **Direct kernel boot** | `-kernel paideia-kernel.bin -append "..."` | Fastest inner-loop iteration; skips UEFI and bootloader entirely | Kernel proper only; **does not exercise C1 boot path, C11 measured boot** |
| **UEFI / OVMF / Secure Boot** | OVMF pflash, ISO or virtual disk containing `paideia-loader.efi` and kernel | Full boot-path testing; C1, C11, Q11 | Every link of the trust chain |
| **Full disk image** | qcow2 disk with EFI System Partition + PaideiaOS root | End-to-end including filesystem (Q4) | Adds storage stack (E5) and CoW FS exercise |

Inner-loop dev should use direct kernel boot for speed. CI should run all three; the UEFI lane is the only one that exercises measured boot, and the disk-image lane is the only one that exercises the on-disk format.

### 5.3 Disk-image layout for Q4 CoW filesystem testing

For testing the new CoW filesystem (Q4) under QEMU:

- **GPT partitioning.** UEFI requires GPT. We use:
  - Partition 1: EFI System Partition, FAT32, ~256 MiB. Holds `paideia-loader.efi` and the kernel image. This partition is the *only* concession to a legacy filesystem; it exists because UEFI mandates it. Pillar-5-conformant by exception.
  - Partition 2: PaideiaOS CoW root, format TBD by Q4 work.
  - Optional Partition 3: scratch / test partition for FS torture testing.
- **GUID for the PaideiaOS partition type.** We will mint a new partition type GUID; allocation owned by `design/filesystem/cow-design.md`. Listed as a TODO output.
- **qcow2 with backing files.** CI uses a base qcow2 image (UEFI partition + empty CoW partition, signed-known-good) and per-test overlays. This lets tests start from a known disk state in microseconds (qcow2 CoW), test, and discard.

---

# Part VI — Repository Layout

## 6. Repository layout

### 6.1 Monorepo vs. polyrepo — **decision: monorepo.**

**Justification.**
1. Pillar 11 (research-driven) demands that every change be cite-able against the design corpus in `design/`. A monorepo lets a single commit atomically update kernel code, driver code, and the design document that justifies them — which is exactly what the §12.3 "design-doc precedes code" rule needs.
2. Q3 puts the toolchain itself on the critical path. The custom assembler's source must live alongside the assembly it compiles so that an assembler change and the code that depends on it can land in a single commit (a polyrepo would force two-PR dances and a broken-`main` window).
3. Q2's verification-friendly-not-mechanized posture pushes correctness work into CI. CI is dramatically simpler to run hermetically across a monorepo than to orchestrate cross-repo builds with version pinning. (Prior art: Google's monorepo rationale per Potvin & Levenberg, *Why Google Stores Billions of Lines of Code in a Single Repository*, CACM 2016.)
4. The E14 linearity checker is whole-program: capability flow crosses kernel / userspace server boundaries. A polyrepo would require per-PR "linearity preview" infrastructure that does not currently exist anywhere.
5. Pillar 10 (FP discipline encoded by macros) means widespread macro changes ripple across the tree. Monorepo lets us refactor atomically.

**Costs accepted.**
- Repo size will grow large (we expect multi-GB within two years once test corpora are committed). Partial clone / sparse-checkout per Git 2.25+ is the mitigation; CI uses full clones.
- A single CI run touches the whole world. We compensate with build-graph-aware change detection (§10.1).

### 6.2 Directory tree (canonical)

```
PaideiaOS/
├── README.md
├── LICENSE
├── CONTRIBUTING.md                  # PR rules, design-doc-first rule
├── CODEOWNERS                       # per-subtree review requirements
├── .editorconfig
├── .gitattributes                   # text=auto eol=lf; binary patterns
├── .gitignore
├── design/                          # mandated; pillar 11
│   ├── 00-feature-inventory.md      # (existing)
│   ├── 01-foundational-decisions.md # (existing)
│   ├── 02-development-environment.md# (this doc)
│   ├── toolchain/                   # per implied-doc list §4 of 01-foundational
│   ├── ipc/
│   ├── capabilities/
│   ├── kernel/
│   ├── security/
│   ├── filesystem/
│   ├── drivers/
│   ├── network/
│   ├── acpi/
│   ├── terminal/
│   └── runtime/
├── src/
│   ├── kernel/                      # privileged-mode code; per pillar 3, kept small
│   │   ├── boot/                    # UEFI handoff stub (C1)
│   │   ├── mm/                      # physical + virtual memory (C2, C3)
│   │   ├── cap/                     # capability tables (C4)
│   │   ├── sched/                   # SC + per-core run queues (C5, C6)
│   │   ├── ipc/                     # kernel side of the Q1 primitive (C7)
│   │   ├── trap/                    # IDT, x2APIC, MSI routing (C8)
│   │   ├── time/                    # TSC-deadline, HPET (C9)
│   │   ├── isol/                    # SMEP/SMAP/CET/PKU/LAM/LASS (C10, Q7, Q12)
│   │   ├── attest/                  # secure-boot/PCR forwarding (C11)
│   │   ├── mca/                     # machine-check (C12)
│   │   ├── pf/                      # external-pager trampoline (C13)
│   │   ├── atomic/                  # ABI macros for LOCK/CMPXCHG16B/WAITPKG (C14)
│   │   ├── entropy/                 # RDRAND/RDSEED + jitter pool (C15)
│   │   ├── log/                     # in-kernel ring buffer (C16)
│   │   ├── xsave/                   # FP/SIMD state (C17)
│   │   └── percpu/                  # FSGSBASE, IPIs (C18)
│   ├── ipc-protocols/               # wire-level definitions of all userspace IPC
│   │   ├── _spec/                   # protocol specs; one .md + one .pdx schema per protocol
│   │   ├── pager/
│   │   ├── driver/
│   │   ├── attest/
│   │   └── ...
│   ├── userspace/
│   │   ├── root-task/               # E1
│   │   ├── pq-crypto/               # E8
│   │   ├── tls/                     # E9
│   │   ├── init/                    # E10 supervisor
│   │   ├── acpica-bubble/           # U1 / Q5; only C-runtime shim in the tree
│   │   ├── drivers/
│   │   │   ├── framework/           # E3 hierarchical driver core
│   │   │   ├── pcie/                # E4 enumeration
│   │   │   ├── nvme/                # E5 storage
│   │   │   ├── xhci/                # U3 USB host
│   │   │   ├── intel-igpu/          # U5 Intel iGPU (open-source path per Q6)
│   │   │   ├── amdgpu/              # U5 AMD (open-source path per Q6)
│   │   │   └── nouveau/             # U5 NVIDIA (degraded; open-source path per Q6)
│   │   ├── fs-cow/                  # E17 / Q4 the new CoW filesystem
│   │   ├── net/                     # E7 stack (L2..L4 servers)
│   │   ├── dns/                     # E18
│   │   ├── time/                    # E15 NTS/Roughtime
│   │   ├── identity/                # E16
│   │   ├── audit/                   # E19
│   │   ├── shell/                   # E12 semantic shell
│   │   ├── unicode/                 # E13
│   │   └── wasm-jail/               # Q9 POSIX-foreign software jail
│   └── toolchain/                   # Q3 — the toolchain is project source
│       ├── asm/                     # the custom assembler (paideia-as)
│       │   ├── stage0-nasm/         # NASM macros used in bootstrap phase 1
│       │   ├── stage1/              # phase-2 self-bootstrap shim
│       │   ├── stage2/              # phase-3 self-hosted assembler
│       │   └── docs/                # assembler manual; macro language reference
│       ├── linker/                  # PAX binary format emitter (E2)
│       ├── linearity-check/         # E14 build-time checker
│       ├── effect-check/            # monadic-effect-type checker (subset of E14)
│       ├── pax-tool/                # capability-manifest inspector / signer (E2)
│       └── pq-sign/                 # PQ artifact signer (Q11)
├── tests/
│   ├── unit/                        # host-side, fast; §9.1
│   ├── integration/                 # QEMU, microkernel + a few servers; §9.2
│   ├── system/                      # QEMU, full-stack flows; §9.3
│   ├── property/                    # PBT + model checker; §9.4
│   ├── fuzz/                        # corpora + harnesses; §9.5
│   ├── linearity-regression/        # known-good / known-bad capability flows; §9.6
│   ├── perf/                        # benchmark + baseline files; §9.7
│   └── _common/                     # shared test infra (QEMU runner, expect helpers)
├── benchmarks/                      # standalone micro/macro benches (not pass/fail)
├── tools/
│   ├── dev/                         # devshell entry points; one-command bring-up
│   ├── ci/                          # scripts referenced by ci/ workflows
│   └── release/                     # release packaging, signing entry points
├── ci/                              # CI configuration (see §10)
│   ├── pipelines/                   # one file per pipeline (PR, main, nightly, release)
│   ├── runners/                     # runner labels, hardware-runner manifests
│   ├── profiles/                    # QEMU CPU-feature profiles from §2.3
│   └── policies/                    # gating policy (which stages block; thresholds)
├── nix/                             # Nix flake; pin set; per §7
│   ├── flake.nix
│   ├── flake.lock
│   ├── packages/                    # toolchain derivations (paideia-as, etc.)
│   └── shells/                      # devShell variants (dev, ci, release)
├── build/                           # .gitignored; intermediate outputs
├── target/                          # .gitignored; final artifacts (kernel image, root FS)
└── docs/                            # user-facing docs (NOT design docs); empty until tier 3
```

**Conventions.**
- All source files end in `.s` (assembly), `.pdx` (capability manifest / protocol schema, *placeholder name*), `.ml` (OCaml for build tooling — see §8.3), or `.md` (design docs only).
- No `src/X/` directory exists without a corresponding `design/X/` directory. This is enforced by a CI lint (§12.3).
- `build/` and `target/` are never committed; they are the canonical output locations for the build system.
- `ci/profiles/` holds the QEMU CPU-feature profiles defined in §2.3, in a data format both osarch and softarch can edit (TOML or YAML; final choice deferred). This is a deliberate co-owned area; see §13.

### 6.3 Where tests live

Tests live in `tests/` rather than co-located with sources (à la Rust's `#[cfg(test)]`) for three reasons:
1. The Q3 toolchain has no language-level test attribute concept; co-location would require us to invent one and have the assembler ignore the right sections.
2. Unit tests run on the host; integration / system tests run in QEMU. Different execution substrates argue for physical separation in the tree.
3. The linearity-regression corpus contains *deliberately malformed* assembly. Keeping it under `src/` would create false positives for editor tooling and would have to be excluded from every static-analysis sweep.

Tests mirror the source tree:

```
tests/unit/kernel/mm/   ↔  src/kernel/mm/
tests/integration/ipc/  ↔  src/kernel/ipc/ + src/ipc-protocols/
```

### 6.4 Where build outputs live

- `build/` — intermediate object files, generated headers, dependency graphs. Reproducible: a `build/` directory deleted and rebuilt from the same git SHA + the same Nix lock yields byte-identical output.
- `target/` — final artifacts (kernel image, root FS image, signed release tarball, signature files).
- `result` / `result-*` — Nix's default symlink, used by the devshell entry points.

### 6.5 Branching strategy — **decision: trunk-based, with hardened release tags.**

Given Q2 (verification-friendly, *not* mechanized), CI is the only thing standing between buggy code and `main`. Long-lived release branches would dilute that single point of enforcement and create rebase tax for kernel-touching changes.

| Rule | Rationale |
|---|---|
| `main` is always green (all CI gates pass). | Single source of truth; cheap to bisect. |
| Feature work happens on short-lived branches (`topic/<author>/<slug>`). | Rebase, not merge, into `main`. |
| Release artifacts come from tags (`v0.X.Y`), not branches. | Tag = signed manifest; nothing to drift. |
| Hotfix to a released tag: cherry-pick into `main` first; *then* a new tag is cut from `main`. The hotfix is never landed on a branch. | Preserves linear history; avoids the "two histories" problem common with release branches. |
| Force-push to `main` is impossible. Force-push to topic branches is allowed before review. | Protects history. |
| Merge commits are forbidden on `main`. Squash-merge is the only landing operation. | Keeps `main`'s history bisectable and `git log --first-parent` meaningful. |

**Caveat we will live with.** Trunk-based + monorepo + a long-running custom-assembler effort means a stretch of `main`'s history where part of the tree is "phase-1 NASM only". That is expected and documented (§8). We do *not* keep an `assembler-rewrite` long-lived branch; instead, the assembler is built incrementally on `main` with feature flags (§8.2).

---

# Part VII — Reproducible Build Environment

## 7. Reproducible build environment

### 7.1 Choice — **decision: Nix flakes as the canonical hermetic-build substrate, with a thin container image for CI runners.**

**Considered alternatives.**

| Option | Why rejected as canonical |
|---|---|
| **Bare devcontainer / Dockerfile.** | Image-layer caching is a usability win but layer determinism is not bit-for-bit. Reproducible builds (per reproducible-builds.org) are a hard project requirement because of Q11 (release signing) and SLSA provenance (§11.3). |
| **Bazel-style hermetic builds (Bazel / Buck2 / Please).** | Hermeticity is real, but Bazel's strength is in caching at the *target* level for large many-language repos. PaideiaOS is overwhelmingly assembly + a small typed-functional build-tool sidecar (§8.3); Bazel's complexity buys little here. Worth re-evaluating at tier-3 scale. |
| **Custom build script + version-pinned tarballs.** | Reinvents Nix's job, badly. Provenance becomes a manual artifact. Rejected. |

**Why Nix wins.**

1. **Bit-reproducible by construction.** Nix derivations are pure functions of their inputs; `flake.lock` pins every input by content hash. Same lock → same outputs, modulo a small known list of impurities (timestamps in archive headers, etc.) that we address per reproducible-builds.org guidance.
2. **The toolchain is itself a derivation.** Q3 makes the custom assembler a build artifact. Nix already treats compilers, linkers, etc. as derivations. `paideia-as` slots in naturally.
3. **Local-vs-CI parity is free.** The CI runner enters the same `nix develop` shell that the contributor uses locally. There is no "works on my machine" because the machine, in the relevant sense, *is* the lock file.
4. **Cross-distro.** Contributors on NixOS, Ubuntu, Fedora, macOS-on-x86_64 (cross-compile only — kernel targets x86_64 native) all get the same toolchain.
5. **NixOS itself provides reproducible-build evidence.** Cite NixOS / r13y.com for prior art.

**Costs accepted.**
- Nix is unfamiliar to many contributors. Mitigated by a thin `tools/dev/` wrapper that hides the `nix` CLI behind verbs (`./tools/dev/up`, `./tools/dev/test`, `./tools/dev/qemu`).
- macOS contributors cannot run the kernel directly (no x86_64 emulation on Apple Silicon at usable speed via Nix-provided QEMU). They use the Nix devshell to build, then push to a Linux runner for QEMU work. Documented in `CONTRIBUTING.md`.

### 7.2 From `git clone` to a running QEMU instance — **one command.**

```bash
git clone <repo-url> PaideiaOS && cd PaideiaOS && ./tools/dev/up
```

What `./tools/dev/up` does (idempotently):

1. Verifies Nix is installed; if not, prints a single-line install command and exits with a clear error. (We do *not* auto-install Nix; that is a privileged operation.)
2. `nix develop --command true` — pre-warms the devshell, fetches all pinned inputs into the local Nix store. First run is slow (TODO: verify expected wall-clock — *initial estimate 5–20 min depending on cache hit rate*); subsequent runs are seconds.
3. Builds the toolchain (`paideia-as` at the current bootstrap phase, the linker, the linearity checker, the PQ signer).
4. Builds the kernel and the minimum set of userspace servers needed for the "default boot demo".
5. Builds a root FS image.
6. Launches QEMU via `./tools/dev/qemu` (which dispatches to the canonical QEMU profile from §2 / `ci/profiles/`).
7. Prints the serial console URL and the GDB-stub port.

`./tools/dev/qemu` is the *only* sanctioned way to invoke QEMU during development; it forwards all options to a single canonical script so that local and CI runs use identical QEMU flags. (Local-vs-CI parity, §7.4.)

### 7.3 Toolchain pinning

| Tool | Pinned by | Notes |
|---|---|---|
| **NASM** | `nix/packages/nasm.nix` (specific version, hash in `flake.lock`). | Required during bootstrap phases 1 and 2 (§8). Pin documented as TODO: verify — *recommended: latest stable at project start, then frozen*. |
| **paideia-as** | Derivation in `nix/packages/paideia-as.nix`; source under `src/toolchain/asm/`. | The hash in `flake.lock` *is* the bootstrap commitment (§7.5). |
| **paideia-link** | `nix/packages/paideia-link.nix`. | Linker; emits PAX binaries (E2). |
| **linearity-check / effect-check** | `nix/packages/build-tools.nix`. | The E14 checker; OCaml derivation. |
| **pq-sign** | `nix/packages/pq-sign.nix`. | The signer; pinned with its PQ library (liboqs or similar — TODO: verify acceptable PQ library for production-grade ML-DSA / SLH-DSA, given Q11). |
| **QEMU** | `nix/packages/qemu.nix`. | Version sufficient for Sapphire-Rapids/Meteor-Lake CPU models, intel-iommu, `-icount rr` SMP support, KVM-TDX hooks. TODO: verify minimum upstream release. |
| **OVMF** | `nix/packages/ovmf.nix`. | Secure-boot variables provisionable. |
| **swtpm** | `nix/packages/swtpm.nix`. | CRB interface; PCR-extension support. |
| **GDB** | `nix/packages/gdb.nix`. | With x86_64 target; remote-target stub-compatible. |
| **rr (Mozilla record-replay)** | `nix/packages/rr.nix`. | Available for failure postmortem; canonical substrate (QEMU `-icount rr` vs. `rr`) decided in §13.4. |
| **TLA+ / Apalache** | `nix/packages/tlaplus.nix`. | For IPC primitive model checking (§9.4). |
| **PBT framework** | `nix/packages/pbt.nix`. | See §9.4 for choice. |
| **Fuzzers** | `nix/packages/fuzzers.nix`. | libFuzzer + AFL++; honggfuzz advisory. |

The whole pin set is owned by `flake.lock`; updating any pin is a discrete PR (§12).

### 7.4 Local-vs-CI parity

Three identical entry points; the difference is *where* they run.

| Entry point | Local | CI |
|---|---|---|
| `nix develop` | Contributor shell. | Pipeline jobs run `nix develop --command <verb>`. |
| `./tools/dev/build` | Same script, same Nix derivation. | Same script. |
| `./tools/dev/test [tier]` | Same harness. | Same harness; `tier` differs by stage. |
| `./tools/dev/qemu` | Same QEMU invocation. | Same QEMU invocation; only the headless flag differs. |

CI never invokes a tool that the contributor cannot invoke locally with the same arguments. If a CI failure cannot be reproduced locally with the equivalent command, that is itself a bug in the CI design and must be fixed.

### 7.5 Q3 chicken-and-egg: bootstrap chain storage and verification

The custom assembler compiles assembly. The assembler is itself written in assembly (stage 2) and in OCaml (stages 0/1 — see §8.3). The chicken-and-egg is:

- Stage 0 is built by NASM from `src/toolchain/asm/stage0-nasm/`. NASM is third-party and trusted.
- Stage 1 is built by stage 0 from `src/toolchain/asm/stage1/`.
- Stage 2 (self-hosted) is built by stage 1 from `src/toolchain/asm/stage2/`.
- Day-to-day kernel work uses stage 2.

**Bootstrap chain artifact.** We commit `nix/bootstrap/` containing:
- Source for the current stage 0 (under version control, like everything else).
- A *binary fingerprint set* (`SHA-3-256` + `BLAKE3` hashes of the stage-0, stage-1, and stage-2 outputs from the most recent successful "trusted bootstrap" run).
- A signed statement (PQ-signed per §11) attesting which commit's CI run produced those binaries.

**Diverse double-compilation (DDC), per Wheeler's *Countering Trusting Trust through Diverse Double-Compiling*, 2009.**

To guard against compiler-Trojan-style attacks (Thompson, *Reflections on Trusting Trust*, CACM 1984), the nightly CI runs a **DDC stage**:

1. Build stage 0 from source using NASM (this is the "primary" path).
2. Build stage 0 from source using an independent assembler (GNU `as`; or, as the project matures, an alternative version of NASM). This is the "secondary" path.
3. Use both stage-0 outputs to build stage 1 *and then* stage 2.
4. The two resulting stage-2 binaries must be bit-identical (modulo a documented list of permitted non-determinism — none expected; see reproducible-builds.org).

If they diverge, the build is rejected, an alert fires, and the release pipeline is halted until the divergence is explained.

The DDC stage is a CI gate on the release pipeline, advisory on `main` (because it is slow), and not run on PRs.

---

# Part VIII — Toolchain Bootstrap

## 8. Toolchain bootstrap

This section discharges the §3 tension between Q2 ("move fast") and Q3 ("custom assembler is a 1–2 person-year prerequisite"). The plan is to bootstrap on NASM and migrate per subsystem, with both assemblers coexisting through phase 2.

### 8.1 Phase definitions

| Phase | Duration (estimated; TODO: verify) | Assembler in use | What can be built |
|---|---|---|---|
| **Phase 1: NASM only** | Month 0 → ~month 9 | NASM + Nix-pinned macros that simulate (but do not check) linearity / effect typing. | Boot path (C1), early memory (C2/C3), exception handlers (C8/C12), atomic ABI prototype (C14), per-CPU/IPI (C18). Anything that does *not* depend on linearity-checked capability flow can land. |
| **Phase 2: NASM + early `paideia-as`** | ~month 9 → ~month 24 | Both. New code prefers `paideia-as`; existing NASM code is migrated subsystem-by-subsystem. | The IPC primitive (C7), capability system (C4), scheduler (C6) — *anything that depends on linearity checking* must use `paideia-as`. Phase-1 modules stay on NASM until migrated. |
| **Phase 3: `paideia-as` canonical** | month 24+ | `paideia-as` only. | All of PaideiaOS. NASM is retired from the build graph but retained in `nix/legacy/` as a forensic tool. |

These durations are estimates; the assembler effort may slip. The phase-transition criteria (§8.4) are *not* date-based.

### 8.2 Coexistence rules during phase 2

The risk in phase 2 is **bootstrap drift**: NASM-built object files and `paideia-as`-built object files must remain ABI-compatible, otherwise the kernel will link but mysteriously crash.

We enforce ABI compatibility with three mechanisms:

1. **A single, versioned, machine-readable ABI document** at `design/toolchain/abi.md` + `src/toolchain/abi/abi.pdx`. Both NASM macros and `paideia-as` consume the same `.pdx` definition. Any ABI change is a discrete PR that updates both backends and bumps `ABI_VERSION`.
2. **A linker-emitted version stamp.** Every object file declares the ABI version it was built against; the linker refuses to link mismatched objects.
3. **A cross-build smoke test (CI gate).** A subset of kernel modules is built twice per CI run during phase 2 — once with each assembler — and a binary differ checks that the *semantic* output is identical (instruction stream, not bytes, since macros may emit differently — TODO: verify the right level of abstraction here; possibly a disassembler-based diff or an internal-IR diff).

### 8.3 Custom assembler implementation language

**Decision: stages 0 and 1 in OCaml; stage 2 in itself.** Rationale:

- The E14 linearity / effect-type checker is best written in a typed functional language. OCaml is mature, has excellent pattern matching, and is the language the seL4 verification toolchain uses (Isabelle/HOL infrastructure is OCaml-heavy, per Klein et al. 2009 lineage).
- Haskell was considered. OCaml chosen for predictable memory residency (relevant when CI runs many parallel jobs) and faster compilation of the toolchain itself.
- Stage 2 (self-hosting) drops the OCaml dependency from the runtime build, which is a long-term simplification.

Reflects the open item from `01-foundational-decisions.md` §5 ("Custom-assembler implementation language. Itself written in assembly? In a verified host language? Bootstrap decision affects timeline.")

### 8.4 Phase-transition gates

The transitions are *capability-driven*, not date-driven:

| Transition | Required to enter |
|---|---|
| Phase 1 → Phase 2 | (a) `paideia-as` can assemble a non-trivial kernel module (suggested: `src/kernel/cap/`) such that the linearity checker accepts it and the result boots in QEMU; (b) the ABI document (§8.2) is published; (c) the cross-build smoke test passes for that module. |
| Phase 2 → Phase 3 | (a) Every kernel and userspace subsystem builds under `paideia-as`; (b) the cross-build smoke test has run with zero divergences for 30 consecutive days on `main`; (c) DDC (§7.5) succeeds on stage 2. |

Transition is announced via a `design/toolchain/phase-transition-N.md` retrospective and a PR that flips the default in `flake.nix`.

### 8.5 Toolchain version policy

Once phase 3 is reached, `paideia-as` versions follow:
- **Major** (`vN.*.*`) — ABI break. Forbidden between releases of the kernel; allowed only at major-version OS releases.
- **Minor** (`v*.N.*`) — new ISA features supported, new macros, no ABI break.
- **Patch** (`v*.*.N`) — bug fixes only.

The toolchain's own PRs are reviewed under the heaviest review policy in the repo (kernel-touching + assembler-touching; §12.2).

---

# Part IX — Test Taxonomy

## 9. Test taxonomy

The test taxonomy is *the* compensation for Q2 (not-mechanized verification). It must catch what an unwritten proof would have caught.

### 9.1 Unit tests

| Property | Value |
|---|---|
| Substrate | Host-side, native execution; no QEMU. |
| Targets | Arithmetic helpers, fixed-size data structures, parsers (UEFI memory map, ACPI tables, PAX format), the assembler/linker themselves, the linearity checker on synthetic inputs. |
| Framework | OCaml unit tests for tools; for kernel-data-structure tests, a thin host-runnable harness (assembly modules built as ordinary x86_64 ELF objects and linked into a host test runner). |
| Speed budget | Whole suite under 60 s. |
| CI policy | Blocking gate on every PR. |

### 9.2 Integration tests

| Property | Value |
|---|---|
| Substrate | QEMU (default config from §2). |
| Scope | Microkernel + one or two userspace servers. |
| Examples | Boot + memory bring-up + first IPC; root task spawns a child via the capability spawner (E10) and exchanges one message; the page-fault protocol (C13) round-trips through a userspace pager. |
| Framework | A test harness that boots QEMU with a tagged "test root task" whose only job is to drive a scripted scenario and emit a typed test verdict over the serial port, parsed by the host. |
| Speed budget | Each test under 30 s wall-clock; suite under 15 min wall-clock with parallelism. |
| CI policy | Blocking gate on every PR. |

### 9.3 System tests

| Property | Value |
|---|---|
| Substrate | QEMU, full image. |
| Scope | End-to-end flows: secure-boot up to a signed-in shell session; loading a filesystem image, mounting (grafting), reading; networking a packet round-trip through the userspace stack; driver hot-restart per Q14. |
| Framework | The integration-test harness, escalated to full system images. |
| Speed budget | Each scenario under 5 min; the suite under 60 min. |
| CI policy | Blocking gate on `main` merges; advisory (preview) on PR runs (so PR feedback time stays reasonable). |

### 9.4 Property-based tests / model checking — **the Q1/Q2 mitigation**

The wait-free dataflow IPC primitive (Q1) is the riskiest single design decision in the project, and Q2 explicitly declines mechanized proof. Property-based testing + model checking is *not optional*; it is the agreed-on compensation.

#### 9.4.1 Two layers

**Layer A — TLA+ specification, checked with TLC and Apalache.**

- Write the primitive as a TLA+ spec (`design/ipc/wait-free-dataflow.tla`).
- Properties to check:
  1. *Type invariant* — queue states are always well-formed.
  2. *Deadlock freedom* — `<>[](some progress predicate)`; this is the Q1 binding requirement.
  3. *Linearizability of the dataflow operations* — adapt the standard model-checked linearizability witness pattern (TODO: verify the most current reference; possibly Doolan et al. on TLA+ linearizability harnesses).
  4. *Wait-freedom* — every operation completes within a bounded number of its own steps regardless of others' progress (per Herlihy 1991).
- Apalache (a symbolic model checker for TLA+) is used to push the state space; TLC for exhaustive small-model checks. Both are pinned in Nix (§7.3).

**Layer B — Implementation property-based tests.**

- Test framework choice — **decision: a custom QuickCheck-style harness in OCaml**, driving the assembled IPC code in a hosted simulator. Rationale: existing PBT frameworks (Hypothesis, fast-check) are tied to high-level languages; we need to drive against assembly outputs and the linearity checker. OCaml + the project's toolchain are already a dependency.
- Properties mirror layer A's: random schedule, random message sequence, no observed deadlock, observed bounded operation counts.
- Coverage-guided shrinking — failing schedules are minimized for human inspection.
- Stress mode — randomized scheduler interleavings via thread injection in the simulator; not a substitute for hardware testing, but a strong filter.

Both layers are gates on PRs that touch `src/kernel/ipc/` or `design/ipc/`. Other PRs run them advisory.

#### 9.4.2 Why TLA+ rather than Alloy or P

- **TLA+** has the strongest track record for distributed-systems and concurrency specs (AWS S3 case studies; Newcombe et al., *How Amazon Web Services Uses Formal Methods*, CACM 2015).
- **Alloy** excels at structural / relational properties but is weaker on temporal properties, which is where deadlock-freedom lives.
- **P** is excellent for actor-style systems with explicit messages, which is *close* to a dataflow primitive — re-evaluate at phase 2 if TLA+ ergonomics prove painful. Tracked as TODO in §14.

### 9.5 Fuzzing

Fuzz targets (in priority order):

| Target | Why | Harness |
|---|---|---|
| Capability handle decoding (kernel side) | Pillar 6 attack surface; one decode bug = full kernel compromise. | libFuzzer-style on a host-built harness wrapping the kernel decoder; corpus seeded from valid traces. |
| IPC message parsing (the Q1 primitive) | Same. | As above. |
| ACPI table parsers (U1; Q5 makes ACPICA userspace but the static-table parsers stay in our code) | Vendor firmware emits garbage; ACPI tables are externally-attacker-controlled. | Corpus seeded from a wide vendor sample; structure-aware mutation. |
| The CoW filesystem (Q4 / E17) — block layout, metadata, snapshots | New code; on-disk format = persistent attack surface. | A two-mode fuzzer: format fuzzing on disk images; operation fuzzing through the FS server's IPC interface. |
| UEFI handoff structure | One-shot but critical. | Smaller corpus; mutation focused on memory-map edge cases. |
| PAX binary format loader (E2) | Capability-aware ELF replacement; loader bugs = code injection. | libFuzzer-style harness on the loader. |

| Property | Value |
|---|---|
| Frameworks | libFuzzer (primary), AFL++ (secondary), honggfuzz (advisory). |
| Corpora | Committed under `tests/fuzz/<target>/corpus/`; new corpus inputs from CI failures are auto-committed by a bot. |
| CI policy | Time-boxed (default 20 min per target) on `main`; longer (4 h) on nightly; one weekly long-run (24 h) on each high-priority target. |
| Failure policy | Any new crash = blocking on `main`; new crash in a PR's diff scope = blocking on that PR. |
| Sanitizers | ASan / MSan / UBSan equivalents for the OCaml host harnesses; for kernel code under fuzz, build with our `-fsanitize`-equivalent macros (TODO: verify what we will offer; AFL-style instrumentation is straightforward, sanitizer-style memory checking will require a project-specific story given assembly source). |

### 9.6 Regression tests for the linearity checker (E14)

The E14 linearity check from Q7 is on the build-time critical path. A regression in the checker would silently break the project's primary safety invariant.

| Property | Value |
|---|---|
| Corpus | `tests/linearity-regression/`. Two subdirectories: `accept/` (known-good capability flows) and `reject/` (known-bad). Each file is annotated with the specific rule it exercises. |
| Run | Every PR. The checker must accept every `accept/` input and reject every `reject/` input with the *exact* expected error code. |
| New rules | Adding a rule = adding ≥ 3 accept and ≥ 3 reject examples in the same PR. |
| Speed budget | Under 60 s. |
| CI policy | Blocking gate on every PR. |

### 9.7 Performance regression tests

| Property | Value |
|---|---|
| Baselines | Per-microbenchmark JSON files at `benchmarks/baselines/`. Updated by a sanctioned "baseline-roll" PR after intentional perf-impacting changes. |
| Microbenchmarks | IPC round-trip latency (the headline); capability lookup; page-fault round-trip; context switch; null syscall. |
| Macrobenchmarks | Kernel build time (proxy for CI cost); cold-boot to login (proxy for the whole stack); fio-equivalent on the CoW FS. |
| Alert thresholds | Microbench: > 5% regression = blocking on PR; > 2% = advisory. Macrobench: > 10% = blocking on `main`; > 5% = advisory. |
| Statistical guard | Each bench is run k times (k pinned per bench, ≥ 5); compare medians + a Mann-Whitney U test against baseline. |
| Substrate | QEMU is *unsuitable for absolute numbers* (§3.3, §4.1). Perf gates run on bare-metal runners (§10.6) when available; on QEMU otherwise, with elevated thresholds and a flag indicating reduced confidence. |
| CI policy | Blocking on `main`; advisory on PR (since perf numbers are noisy under shared CI capacity). |

---

# Part X — CI/CD Pipeline

## 10. CI/CD pipeline

### 10.1 Architectural posture

- Build-graph-aware change detection. Each PR computes its "affected set" (which subsystems' inputs changed) and runs the minimal sufficient stage subset, *plus* the full set on a parallel best-effort job that does not block. Inspired by Bazel-style query, implemented over the Nix derivation graph.
- All stages run inside `nix develop`. No stage depends on a tool that isn't pinned.
- Each stage writes a typed artifact manifest to the pipeline run; downstream stages consume these by content hash.
- A stage's expected wall-clock is recorded and tracked; a stage that exceeds 2× its expected wall-clock alerts the build infrastructure team (a regression of the CI itself).

### 10.2 Tooling — **decision: GitHub Actions for the public face; self-hosted runners for QEMU/bare-metal stages.**

| Concern | Choice | Rationale |
|---|---|---|
| Public pipeline definition | GitHub Actions YAML under `ci/pipelines/`. | Lowest friction for external contributors and security researchers reviewing the project. |
| Runner pool | Self-hosted Linux runners for QEMU stages; self-hosted bare-metal runners for §10.6; GitHub-hosted runners for host-only stages (lint, unit). | QEMU and bare-metal stages need predictable performance and access to nested virtualization and physical hardware respectively. |
| Long-form alternative | Buildkite or Jenkins. Either could replace GitHub Actions; the pipeline scripts themselves live in `tools/ci/` and are CI-system-agnostic. TODO: verify whether to commit to GitHub Actions long-term or design for portability from day one — *current recommendation: portable scripts, GA-flavored YAML.* |

### 10.3 Pipeline diagram

```
                                    +---------------------------+
                                    |  TRIGGER                  |
                                    |   PR | main | nightly | release
                                    +-------------+-------------+
                                                  |
                  +-------------------------------+--------------------------------+
                  |                                                                |
                  v                                                                v
         +--------+--------+                                              +--------+--------+
         | LINT / FORMAT   |                                              | NIGHTLY EXTRA   |
         | + LINEARITY     |                                              |  - long fuzz    |
         | CHECK (E14)     |   <- BLOCKING on PR/main                     |  - DDC          |
         | ~5 min          |                                              |  - 24h soak     |
         +--------+--------+                                              +-----------------+
                  |
                  v
         +--------+--------+
         | TOOLCHAIN BUILD |
         | paideia-as,     |   <- BLOCKING; cached aggressively
         | linker, checker |
         | ~3-10 min cold  |
         +--------+--------+
                  |
                  v
         +--------+--------+
         | KERNEL+SERVERS  |
         | BUILD           |   <- BLOCKING
         | ~5-15 min       |
         +--------+--------+
                  |
        +---------+---------+----------------+---------------+------------+
        |                   |                |               |            |
        v                   v                v               v            v
   +----+----+        +-----+-----+    +-----+-----+   +-----+-----+ +----+----+
   | UNIT    |        | INTEGR.   |    | INTEGR.   |   | PROPERTY/ | | FUZZ    |
   | TESTS   |        | TESTS     |    | TESTS     |   | MODEL-CK  | | (time-  |
   | host    |        | QEMU      |    | QEMU      |   | TLA+/PBT  | | boxed)  |
   |         |        | default   |    | feature-  |   |           | |         |
   |         |        | hw cfg    |    | masked    |   |           | |         |
   | <60 s   |        | ~15 min   |    | ~15 min   |   | ~10-30 min| | 20 min  |
   +----+----+        +-----+-----+    +-----+-----+   +-----+-----+ +----+----+
        |                   |                |               |            |
        +-------------------+----------------+---------------+------------+
                                             |
                                             v
                                    +--------+--------+
                                    | SYSTEM TESTS    |
                                    | QEMU full image |   <- BLOCKING on main; advisory on PR
                                    | ~30-60 min      |
                                    +--------+--------+
                                             |
                                             v
                                    +--------+--------+
                                    | PERF REGRESSION |   <- BLOCKING on main; advisory on PR
                                    | bare-metal pref.|
                                    | ~30 min         |
                                    +--------+--------+
                                             |
                                             v
                                    +--------+--------+
                                    | BARE-METAL      |   <- gated on hardware-runner avail.
                                    | (see §10.6)     |      Blocking only on release.
                                    +--------+--------+
                                             |
                                             v
                                    +--------+--------+
                                    | RELEASE SIGNING |   <- release trigger only
                                    | PQ + SLSA atts. |
                                    +--------+--------+
                                             |
                                             v
                                    +--------+--------+
                                    | ARTIFACT PUBLISH|
                                    | + audit log     |
                                    | (E19 linkage)   |
                                    +-----------------+
```

### 10.4 Stage detail table

| # | Stage | Trigger | Failure policy | Expected wall-clock |
|---|---|---|---|---|
| 1 | Lint / format / linearity check | PR, main | Blocking | ~5 min |
| 2 | Toolchain build | PR, main | Blocking; aggressive caching | 3 min warm / 10 min cold |
| 3 | Kernel + servers build | PR, main | Blocking | 5–15 min |
| 4 | Unit tests | PR, main | Blocking | < 60 s |
| 5a | Integration QEMU (default machine) | PR, main | Blocking | ~15 min |
| 5b | Integration QEMU (feature-masked) | PR, main | Blocking | ~15 min |
| 6 | Property / model-checker stage | PR (advisory) / required on IPC-touching PR / main (blocking) | See §9.4 | 10–30 min |
| 7 | Fuzz (time-boxed) | PR (20 min cap) / main (20 min) / nightly (4 h) / weekly (24 h) | Blocking on new crashes only | per cap |
| 8 | System tests | PR (advisory) / main (blocking) | as noted | 30–60 min |
| 9 | Perf regression | PR (advisory) / main (blocking) | as noted | ~30 min |
| 10 | Bare-metal | gated on runner availability; blocking on release | blocking on release | osarch-defined per §4.2 |
| 11 | DDC | nightly + release | blocking on release | ~30 min |
| 12 | Release signing | release | blocking on release | ~5 min |
| 13 | Artifact publish + audit log entry | release | blocking on release | ~5 min |

### 10.5 Feature-masked integration stage (5b) — what gets masked

The integration suite runs a second time with selected CPU features masked off, to exercise the software fallbacks the §1.1 tension makes necessary. Each mask corresponds to one of the named CPU-feature profiles in §2.3.

1. **No LAM.** Forces the software-LAM fallback per Q7/Q12. Tests that capability tag bits are still respected when LAM is unavailable.
2. **No TDX, no SGX.** Forces the software-enclave fallback per Q11. Tests that PQ signing still happens in an IOMMU-isolated userspace process attested by the TPM.
3. **No 5-level paging.** Tests the 48-bit default per Q12; verifies that per-AS opt-in to 57-bit fails gracefully when the CPU does not advertise the feature.
4. **No CET (IBT + Shadow Stack).** Tests the no-CET configuration (older silicon); the build still passes but the security posture is downgraded; the audit log notes this on boot.
5. **No AVX-512.** Tests the AVX2 fallback paths in the PQ crypto subsystem (E8) and the FP runtime (D5).
6. **No WAITPKG (UMWAIT/TPAUSE).** Tests the PAUSE-based spin fallback for the atomic ABI (C14).

### 10.6 Bare-metal stage

- The bare-metal stage is a CI stage like any other; it consumes the kernel image produced by stage 3 and reports a typed test verdict.
- It is gated on a self-hosted runner label (`hw:<board-id>`) being available; if no runner is available, the stage is skipped with a clear status (not failure).
- On release, the stage is *mandatory*; release will not proceed without a successful bare-metal run on at least one board per the §4.2 release matrix.
- CI infrastructure provides the runner-side ingestion of bare-metal results into the pipeline; the runner OS image and lab setup are owned per §4.2.

### 10.7 CI permission / role model — Q15 implications

Q15 makes Spectre/Meltdown mitigation relaxation a capability operation. By extension, CI must mirror this with a permission model so that, e.g., a contributor cannot land a PR that flips the project default mitigation level.

CI roles (mapping to GitHub Actions environments and OIDC role assertions):

| Role | Granted to | Powers |
|---|---|---|
| `contributor` | Any opener of a PR. | Trigger PR stages (1–9); no access to release secrets. |
| `kernel-reviewer` | A maintainer with kernel review authority (see §12.2). | Approve kernel-touching changes. |
| `toolchain-reviewer` | A maintainer with toolchain review authority. | Approve toolchain-touching changes. |
| `ipc-reviewer` | A maintainer with IPC-primitive review authority. | Approve IPC-touching changes; gate property/model-check results. |
| `release-cutter` | A small, named subset of maintainers (≥ 2 required by signature policy, §11.4). | Trigger the release pipeline; access to PQ release-signing key (offline HSM). |
| `infra-admin` | The smallest possible set. | Modify CI configuration, runner pool, secrets. |

These roles are configured in `ci/policies/roles.yaml` (TODO: verify final filename) and reconciled into GitHub via a documented process.

---

# Part XI — Release & Artifact Signing

## 11. Release / artifact signing

### 11.1 Reproducible-build proof

For every release:

1. The release pipeline produces all artifacts under a fixed `SOURCE_DATE_EPOCH` (timestamp normalization per reproducible-builds.org).
2. After the release pipeline succeeds, a second CI run (`rebuild`) on a separate runner rebuilds the same artifacts.
3. The two artifact sets must be byte-identical. The hash list is published alongside the release.
4. External verifiers (project policy: at least one designated independent rebuilder per release) submit attestations to `ci/rebuild-attestations/` and these are referenced in the release notes.

Cite: reproducible-builds.org spec; Lamb & Zacchiroli, *Reproducible Builds: Increasing the Integrity of Software Supply Chains*, IEEE Software 2021.

### 11.2 PQ signature scheme — **decision pending; recommendation below**

Q11 binds us to PQ release signing. The choice between ML-DSA and SLH-DSA is deferred in `01-foundational-decisions.md` §5 ("PQ signature scheme selection").

**Recommendation:**

- **Release artifact signature: hybrid Ed25519 + ML-DSA-65.** ML-DSA-65 is the FIPS-204 mid level; Ed25519 is the classical hedge per draft-ietf-tls-hybrid-design's combiner pattern. Signature size on the order of 3.4 KB, acceptable for release manifests.
- **Boot-chain signature (the next kernel image): SLH-DSA-128s.** Stateless hash-based, no lattice assumption — minimal risk if a lattice break occurs. Signature size ~7.8 KB, also acceptable since the boot chain is small.
- **Long-lived release-line root signature: SLH-DSA-256s with a state-managed XMSS chain for ancillary keys.** Strongest available; signatures are large, but the root signs few things.

This recommendation should be debated in `design/security/pq-trust-root.md`; we surface it here because §11 cannot be specified without it.

### 11.3 SLSA provenance

Every release ships an in-toto / SLSA v1.0 provenance attestation (cite: slsa.dev). The attestation declares:

- The git commit (full SHA-3-256 hash, not just SHA-1).
- The `flake.lock` content hash.
- The Nix derivation hash of each artifact.
- The CI run ID and the runner OIDC identity.
- The signing key identifier (PQ public key fingerprint).
- The DDC (§7.5) and reproducible-build (§11.1) attestations as references.

Target SLSA Build Level: **L3** at v1.0 (hardened build platform, signed provenance, isolated builds). L4-equivalent (hermetic + reproducible verified) is the project's longer-term aim.

### 11.4 Key residency — HSM / TPM split

| Key | Residency | Use |
|---|---|---|
| Release root (SLH-DSA-256s) | **Offline HSM**, ceremonial use only. Physical access controlled by the release-cutter role (§10.7). | Signs new release-line roots and the long-term project key. ≥ 2-of-N quorum required. |
| Release-line signing key (Ed25519 + ML-DSA-65) | **Hardware-backed in CI** — TPM 2.0 on the release runner, or a cloud KMS (TODO: verify which KMS providers support ML-DSA — *unclear as of this draft; SLH-DSA support is more common*). | Signs every release artifact. |
| Boot-chain signing key (SLH-DSA-128s) | TDX or SGX enclave on a release runner where available (per Q11). Software fallback on client-only runners with TPM-attested isolation (per the §1.1 tension mitigation). | Signs the *next* shipped kernel image. |
| CI ephemeral signing keys | TPM-backed per-run; rotated automatically. | Signs intermediate CI artifacts for inter-stage trust. |

Audit log entries (E19) reference the key identifier used for each release signature.

### 11.5 Release audit log

E19's append-only PQ-signed audit log is *also* the release log. Every release event (toolchain bump, kernel release, security advisory) writes an entry. The audit log is published; external mirrors are encouraged.

---

# Part XII — Contributor Workflow

## 12. Contributor workflow

### 12.1 PR template (canonical)

`.github/pull_request_template.md`:

```markdown
## Summary
<1-3 sentences>

## Pillar / decision impact
<which of pillars 1-11 and decisions Q1-Q15 this PR touches; "none" is valid>

## Design-doc change
<link to the design/ file updated in this same PR, or justify why no update is needed>

## CI status
- [ ] Lint / linearity check passing
- [ ] Toolchain build passing
- [ ] Unit + integration passing
- [ ] System tests (advisory) — pass / known-fail with link
- [ ] Property / model-check stage — required if `src/kernel/ipc/` or `design/ipc/` touched
- [ ] Perf — no regression beyond threshold

## Linearity-check impact
<if any reject/ or accept/ entries were added or modified, list them>

## Risk and rollback
<how this is rolled back if it breaks main>

Co-Authored-By: <as appropriate>
```

### 12.2 Required reviews (CODEOWNERS)

| Subtree | Reviewers required |
|---|---|
| `src/kernel/**` | 1 kernel-reviewer + 1 additional maintainer. |
| `src/kernel/ipc/**` or `design/ipc/**` | 1 ipc-reviewer + 1 kernel-reviewer; property-test impact analysis attached. |
| `src/toolchain/**` | 1 toolchain-reviewer + 1 additional maintainer. The toolchain has the heaviest review policy because it is in the trust base for everything. |
| `src/userspace/pq-crypto/**`, `src/userspace/tls/**`, `src/userspace/identity/**`, `src/userspace/audit/**` | 1 security-reviewer + 1 additional maintainer. |
| `ci/**`, `tools/ci/**`, `nix/**` | 1 infra-admin + 1 additional maintainer. |
| `ci/profiles/**` | 1 kernel-reviewer (osarch-side) + 1 infra-admin (softarch-side). The CPU-feature profiles are jointly owned per §13.1. |
| `design/**` (only) | 1 maintainer (lighter — design docs evolve fast). |
| Everywhere else | 1 maintainer. |

### 12.3 The "design doc precedes code" rule — CI enforcement

A CI lint at stage 1 enforces:

- If `src/X/` paths are modified, the PR must also modify a file under `design/X/` *or* include a top-level commit-message line `Design-Doc-Waiver: <reason>` that is reviewed by ≥ 2 maintainers.
- New `src/X/` directories require a corresponding new `design/X/` directory created in the same PR — no waiver.
- New `design/X/` files require a corresponding `src/X/` placeholder or a labeled `design-only` PR.

The lint is implemented as a path-matrix walker; rules are declared in `ci/policies/design-pairing.yaml`.

### 12.4 Issue / RFC process for cross-cutting changes

Two tiers:

1. **Regular issues** for bugs, small features, doc fixes. Standard GitHub issues; no extra ceremony.
2. **RFCs** for any change that:
   - Touches more than one subtree in `src/`.
   - Modifies any pillar (1–11) or decision (Q1–Q15) interpretation.
   - Introduces a new tier-1/tier-2 feature (per `00-feature-inventory.md`).
   - Modifies the toolchain ABI or the linearity-check rule set.

An RFC is a PR under `design/rfcs/NNNN-<slug>.md` following a template (TODO: write the template). Discussion happens on the PR. Acceptance requires a maintainer-quorum vote and the RFC PR's merge. Implementation PRs reference the merged RFC.

### 12.5 Documentation feedback loop

Every PR that fixes a CI false-positive or surfaces an unclear error message must also include a corresponding update to `design/toolchain/diagnostics.md` (when touching the toolchain) or the relevant `design/<area>/` doc. This is policy, not CI-enforced (the cost of CI'ing it is too high relative to the benefit).

---

# Part XIII — Joint Invariants

## 13. Joint invariants

This section is the explicit contract between the hardware/QEMU half of this document (Parts I–V) and the build/CI/CD half (Parts VI–XII). Where they touch, the following invariants hold; a change to either side that breaks one of them is a joint design discussion, not a unilateral edit.

### 13.1 Co-owned: `ci/profiles/`

The QEMU CPU-feature profiles defined in §2.3 live as data files under `ci/profiles/` (format: TOML or YAML; choice deferred). They are written by people working on the hardware-presentation side and consumed by the CI orchestration. Changing the set or content of profiles is a kernel-reviewer + infra-admin two-signature PR (§12.2). The set is closed: a PR that needs a new profile must add it explicitly.

### 13.2 Single QEMU invocation script

`./tools/dev/qemu` is the only sanctioned QEMU entry point. It accepts a named profile (`--profile aspirational`, `--profile minimum-skylake-x`, …) and dispatches to the corresponding `ci/profiles/<profile>.toml`. Both local developers and CI use it. There is no second QEMU invocation path anywhere in the repo.

### 13.3 Pinning: who picks which version

- **What hardware QEMU emulates** is decided by Parts I–V (target hardware matrix, CPU feature matrix, devices).
- **Which exact upstream version is pinned** is decided by Part VII (Nix flake), reading the constraints from Parts I–V. Concretely, `nix/packages/{qemu,ovmf,swtpm}.nix` carry the minimum-version constraints derived from §2.5–§2.8.

### 13.4 Failure-investigation substrate

Two complementary determinism tools are available:

- QEMU's built-in `-icount rr` record/replay (§3.4) is the primary substrate when the failure is reproducible under TCG and the kernel itself is suspect.
- Mozilla `rr` is available in the dev shell (§7.3) for the OCaml host-side tools and for userspace simulators.

The CI failure-postmortem workflow:
1. A failing integration / system test captures the QEMU `replay.bin`, the serial-console transcript, the GDB-stub session log (if one was attached), and the kernel log ring snapshot.
2. The bundle is uploaded as a CI artifact, addressable from the failing run.
3. A contributor can `./tools/dev/replay <artifact-bundle>` to relive the failure deterministically on their workstation.

### 13.5 Bare-metal contract

- Runner labels (`hw:<board-id>`) and pipeline integration are CI/infrastructure concerns (Part X).
- Runner OS image, lab setup, board provisioning, and the §4.2 hardware matrix are hardware-side concerns (Part IV).
- A board is added by a joint PR: a runner manifest under `ci/runners/`, a board entry under `design/hardware/bare-metal/<board>.md`, and an update to the §4.2 table.

### 13.6 Performance-substrate contract

- Absolute perf numbers come from bare-metal (§4, §10.6).
- Relative perf numbers from QEMU are acceptable with elevated thresholds and a confidence flag (§9.7).
- The QEMU configuration that minimizes timing noise (e.g., no KVM nested-virt for perf runs) is documented as a dedicated profile (`perf-qemu`) in `ci/profiles/`.

### 13.7 RDSEED-failure injection

The kernel's reseed logic (C15) must handle RDSEED failure (CF=0). QEMU's RDSEED returns success deterministically under TCG (TODO: verify); a CI hook is needed to inject failure for fallback testing. This may require a small QEMU patch or a wrapper that mediates RDSEED — both halves of this document acknowledge that this is an open engineering task and that the right owner depends on the chosen mechanism.

---

# Part XIV — Open Issues

## 14. Open issues

These are flagged for explicit resolution before downstream design documents are finalized.

### 14.1 Hardware / emulation issues (Parts I–V)

| ID | Issue | Resolution location |
|---|---|---|
| H1 | TPM 2.0 PQ extension status (Q11 root). TCG has work in progress on PQ TPM extensions, but `swtpm` does not yet expose ML-DSA/SLH-DSA primitives (TODO: verify TCG WG, OpenSSL OQS provider docs, `swtpm` upstream master). Q11's "TPM holds PQ-signing root keys" is *aspirational*. | `design/security/pq-trust-root.md` |
| H2 | KVM-TDX upstream usability in 2026-06. KVM-TDX has been iterating in upstream Linux + QEMU; end-to-end TD boot on stock distro kernel + upstream QEMU is uncertain. Affects how seriously the `tdx-host` stage can be treated. Fallback: TDX is opportunistic. | `design/security/pq-trust-root.md` |
| H3 | Minimum supported i7 generation. §1.2 stratifies, but the project owes itself an *advertised* minimum. Recommendation: Meteor Lake (client) / Sapphire Rapids (server) advertised; best-effort Skylake-Server and later under software fallbacks. | `design/01-foundational-decisions.md` §5 (deferred items) |
| H4 | Exact CPUID leaf/bit for LAM and AMX-TILE. | `design/capabilities/linearity-and-tags.md` |
| H5 | QEMU CPU model name for Meteor Lake-class behavior. | `ci/profiles/recommended-client.*` |
| H6 | Upstream EDK2 status of PQ signature verification for Secure Boot. | `design/security/pq-trust-root.md` |
| H7 | QEMU CXL device modeling maturity for D11. | `design/kernel/memory-model.md` (future) |
| H8 | QEMU+KVM PMU passthrough completeness. | `design/devenv/perf.md` (to write) |
| H9 | SMP record/replay stability in current QEMU. | `design/ipc/wait-free-dataflow.md` |
| H10 | TCG CET shadow-stack coverage. | `design/security/isolation.md` (future) |
| H11 | Per-SKU SGX deprecation timeline. | `design/security/pq-trust-root.md` |

### 14.2 Build / CI / workflow issues (Parts VI–XII)

| ID | Issue | Resolution location |
|---|---|---|
| S1 | Final PQ signature scheme selection (recommendation in §11.2). Affects release manifest size, boot-chain budget, and key-management ceremony. | `design/security/pq-trust-root.md` |
| S2 | Concrete CI vendor choice (GitHub Actions vs. Buildkite vs. Jenkins) and the long-term portability story of `tools/ci/`. Recommendation: portable scripts, GA-flavored YAML. | `design/devenv/ci-vendor.md` (to write) |
| S3 | Property-based test framework — is the custom OCaml QuickCheck the right call, or should we adopt P alongside / instead of TLA+? Re-evaluate at end of bootstrap phase 1. | `design/ipc/wait-free-dataflow.md` |
| S4 | KMS support for ML-DSA — current cloud KMS coverage is unclear (SLH-DSA more common). Affects §11.4 key residency. | `design/security/pq-trust-root.md` |
| S5 | DDC mechanism — does NASM have a sufficiently diverse alternative for the second compilation? GNU `as` is the obvious candidate but its assembly dialect differs enough that we may need to maintain two stage-0 source trees. | `design/toolchain/bootstrap.md` |
| S6 | Cross-build smoke test diff level — instruction stream vs. internal IR vs. byte-for-byte. §8.2 leaves this open. | `design/toolchain/abi.md` |
| S7 | Sanitizer story for assembly-source kernel code under fuzz. §9.5 footnote. | `design/devenv/sanitizers.md` (to write) |
| S8 | Test runner for assembly-as-host-test-target (§9.1). The harness that links assembled kernel data-structure code into a host process needs design. | `design/devenv/host-test-harness.md` (to write) |

### 14.3 Joint / cross-cutting issues (Part XIII)

| ID | Issue | Resolution location |
|---|---|---|
| J1 | Final format for `ci/profiles/` (TOML vs. YAML vs. a project-specific schema). | `design/devenv/profiles-format.md` (to write) |
| J2 | Canonical record/replay substrate — QEMU `-icount rr` vs. Mozilla `rr` — for the integration/system test postmortem flow (§13.4). | `design/devenv/postmortem.md` (to write) |
| J3 | RDSEED-failure injection mechanism (§13.7) — wrapper script, QEMU patch, or a guest-side test harness. | `design/devenv/entropy-testing.md` (to write) |

---

# Part XV — References

## 15. References

### 15.1 Intel documentation

- Intel® 64 and IA-32 Architectures Software Developer's Manual, Vols. 1, 2A/B/C/D, 3A/B/C/D, 4 — current revision. Cited throughout for CPUID, paging, MSRs, VMX, interrupts, MCA, CET, MPK, LAM (LAM chapter in Vol. 1; exact chapter number TODO: verify).
- Intel® *5-Level Paging and 5-Level EPT White Paper*, rev. 1.1, 2017.
- Intel® *Trust Domain Extensions (Intel® TDX) Module Base Architecture Specification*, rev. 1.5, 2023.
- Intel® *Virtualization Technology for Directed I/O (VT-d) Architecture Specification*, rev. 4.1, 2022.
- Intel® *Advanced Matrix Extensions (AMX) Architecture Specification*, rev. 1.5, 2023.
- Intel® *DRNG Software Implementation Guide*, rev. 2.1, 2018.
- Intel® *TXT MLE Developer's Guide*, rev. 017, 2017 (DRTM background).
- Per-SKU feature lookup: https://ark.intel.com.

### 15.2 Standards & specifications

- UEFI Specification 2.10, 2022 — §7 Boot Services; §32 Secure Boot.
- ACPI Specification 6.5, 2022 — §5.2.6 MCFG; §5.2.16 SRAT; §5.2.17 SLIT.
- TCG TPM 2.0 Library Specification, Part 1 (Architecture), Rev. 1.59, 2019.
- TCG PC Client Platform Firmware Profile Specification, Family 2.0, Level 00 Rev. 1.05, 2021.
- TCG D-RTM Architecture Specification 1.0.0, 2013.
- PCI Express Base Specification 6.0, 2022.
- NVM Express Base Specification 2.0c, 2022.
- xHCI Specification 1.2, 2019.
- NIST FIPS 203 (ML-KEM), 204 (ML-DSA), 205 (SLH-DSA), 2024.
- RFC 8391 *XMSS*, 2018; RFC 8554 *LMS*, 2019.
- SLSA Supply-chain Levels for Software Artifacts, v1.0. https://slsa.dev (informative).
- reproducible-builds.org — definitions and recommendations. https://reproducible-builds.org (informative).
- in-toto Attestation Framework spec (informative).

### 15.3 QEMU / emulator references

- QEMU System Emulation documentation (`docs/system/`): machine types, CPU models, IOMMU, TPM, KVM-TDX. TODO: cite the specific QEMU release whose doc URLs we pin against.
- `swtpm` project documentation (upstream): https://github.com/stefanberger/swtpm. TODO: verify current docs URL.
- EDK2 / OVMF documentation: https://github.com/tianocore/edk2. TODO: verify Secure Boot configuration documentation pointer.
- `virt-firmware` / `virt-fw-vars` for OVMF variable enrollment. TODO: verify upstream maintenance status.

### 15.4 Academic and engineering literature

- Klein et al., *seL4: Formal Verification of an OS Kernel*, SOSP 2009.
- Elphinstone & Heiser, *From L3 to seL4 — What Have We Learnt in 20 Years of L4 Microkernels?*, SOSP 2013.
- Herlihy, *Wait-Free Synchronization*, TOPLAS 13(1), 1991.
- O'Callahan et al., *Engineering Record and Replay for Deployability*, USENIX ATC 2017 (rr).
- Lozi et al., *The Linux Scheduler: a Decade of Wasted Cores*, EuroSys 2016 (NUMA-blindness cautionary tale).
- Cheng et al., *Intel TDX Demystified: A Top-Down Approach*, ACM Computing Surveys 2024.
- Costan & Devadas, *Intel SGX Explained*, IACR ePrint 2016/086.
- Dolstra, *The Purely Functional Software Deployment Model* (Nix), PhD thesis, Utrecht University, 2006.
- Potvin & Levenberg, *Why Google Stores Billions of Lines of Code in a Single Repository*, CACM 59(7), 2016.
- Wheeler, *Countering Trusting Trust through Diverse Double-Compiling*, ACSAC 2005 / PhD 2009.
- Thompson, *Reflections on Trusting Trust*, CACM 27(8), 1984.
- Newcombe et al., *How Amazon Web Services Uses Formal Methods*, CACM 58(4), 2015.
- Lamb & Zacchiroli, *Reproducible Builds: Increasing the Integrity of Software Supply Chains*, IEEE Software 2021.
- Necula, *Proof-Carrying Code*, POPL 1997.
- Walker, *Substructural Type Systems*, in *Advanced Topics in Types and Programming Languages*, MIT Press, 2005.

### 15.5 Tooling (informative — pin versions in `flake.lock`)

- NixOS / Nix flakes.
- TLA+ / TLC / Apalache.
- libFuzzer (LLVM); AFL++; honggfuzz.
- GitHub Actions; Buildkite; Jenkins (alternatives).

### 15.6 References marked TODO: verify

The following are referenced above without full confidence; they must be verified before this document is finalized:

- The exact Intel SDM Vol. 1 chapter that documents LAM.
- The exact CPUID leaf/sub-leaf and bit for LAM and AMX-TILE.
- Intel PCN identifying SGX removal from specific client SKUs.
- QEMU CPU model name for Meteor Lake.
- QEMU release where Sapphire-Rapids model gained LAM; QEMU release where SMP `-icount rr` became reliable.
- Current state of upstream EDK2 PQ Secure Boot.
- Current state of upstream QEMU + Linux KVM-TDX (whether out-of-tree patches are still required).
- `swtpm` PQ support status.
- `virt-firmware` package maintenance status and current upstream location.
- QEMU CXL `-machine cxl=on` and `-device cxl-type3` maturity for D11.
- Whether TCG CPU models support `+cet-ss` and `+cet-ibt` faithfully.
- Initial `nix develop` cold wall-clock estimate.
- NASM pinned version.
- liboqs (or equivalent) production-grade status for ML-DSA / SLH-DSA in PQ signer.
- Sanitizer toolchain for assembly-source code under fuzz.
- KMS providers with ML-DSA support.
- `rr` vs. QEMU record/replay choice for x86_64 kernel postmortem (resolved in §13.4 as offering both; final canonical choice deferred).
- Linearizability-witness-pattern reference for TLA+ (§9.4).

These are the surface area to audit in the first revision pass.

---

*End of document.*
