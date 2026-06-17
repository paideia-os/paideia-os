# PaideiaOS Microkernel Feature Inventory

**Document status:** Draft v0.1
**Date:** 2026-06-17
**Author:** osarch (architectural agent)
**Audience:** Project owner / researcher
**Purpose:** Establish the canonical, prioritized list of features for the PaideiaOS clean-slate microkernel operating system, with rationale, microkernel placement, pillar alignment, and citable references for each. This document is the seed for all subsequent design notes in `design/`.

---

## 0. Preamble — Project Pillars (restated)

PaideiaOS is a clean-slate, research-grade operating system whose design is bound by the following non-negotiable pillars. Every feature decision in this inventory is justified against these pillars; features that violate them are excluded.

1. **x86_64 native, full ISA, no portability layer.** Implementation is in assembly (NASM/GAS dialect TBD), targeting Intel Core i7+ (Skylake-X / Ice Lake / Sapphire Rapids feature levels). AVX, AVX2, AVX-512 (where present), BMI1/2, ADX, RDRAND/RDSEED, CET (IBT + Shadow Stack), MPK/PKU, FSGSBASE, RDTSCP, INVPCID, XSAVE family, and TSX-NI are available from boot.
2. **Multicore-efficient by design.** The kernel data structures, scheduler, and IPC paths are designed for many-core / NUMA from inception. No "big kernel lock" phase ever exists.
3. **Strict microkernel.** Only what *must* be in privileged mode lives there: scheduling, address-space and capability management, IPC, exception/interrupt vectoring, the minimal timer and trap handlers, and the secure-boot/attestation root. Drivers, filesystems, network stacks, and pagers are userspace servers communicating via capability-mediated IPC.
4. **Deadlock-free IPC.** The IPC mechanism is itself an open design problem (see §6). The candidate space includes synchronous L4-style rendezvous, asynchronous capability-passing channels, and hybrid notification + shared-memory queues. The chosen mechanism must admit a *formal* deadlock-freedom argument.
5. **No backwards compatibility.** No POSIX adoption except where POSIX is genuinely the best design (rare). No BIOS, no legacy PIC, no PS/2, no a.out/ELF-legacy quirks. UEFI + ACPI + x2APIC + PCIe + NVMe + USB3+ are the minimum hardware contract.
6. **Hardened security, post-quantum where applicable.** Post-quantum KEMs (ML-KEM / Kyber, FIPS 203), signatures (ML-DSA / Dilithium, FIPS 204; SLH-DSA / SPHINCS+, FIPS 205), and hybrid handshakes (X25519+ML-KEM-768 per draft-ietf-tls-hybrid-design). Capability-based access control. Confidentiality and integrity are construction properties, not afterthoughts.
7. **Forward-looking networking.** Strict layering on a modernized OSI mental model; user-space TCP/QUIC; RFC-compliant; designed for high core counts and RDMA/zero-copy paths.
8. **Semantic terminal.** A shell whose commands operate on typed, semantically queryable objects (closer to PowerShell / Nushell ancestry, but with first-class Unicode and a static-types-by-construction discipline). No byte-stream lowest-common-denominator.
9. **Hierarchical, hot-pluggable drivers.** Driver hierarchies (bus → controller → device → function) are first-class. Hot-plug events are normal control-plane traffic.
10. **Functional discipline in assembly.** Calling conventions, macros, and ABIs encode monadic effect typing, applicative composition, and substructural (linear/affine) capability handling. Safety-by-construction is enforced by the assembler-time macro system and verified by build-time tooling.
11. **Research-driven.** Every design decision must cite recent literature (≥ 2015 preferred), an RFC, an Intel SDM reference, or prior-art system documentation. Speculative / TODO citations are clearly marked.

---

## 1. Tier definitions

| Tier | Definition |
|---|---|
| **Critical** | Without this, PaideiaOS cannot boot, schedule, isolate, or communicate — or it directly violates a pillar. |
| **Essential** | Required for PaideiaOS to be a usable general-purpose OS that honors the pillars (networking, FS, userland runtime, PQ-crypto, semantic shell). |
| **Usual** | Features users of a contemporary OS expect (ACPI, USB, audio, graphics compositor, identity, observability). |
| **Desirable** | Differentiating / forward-looking features (confidential computing, formal verification hooks, AI/ML acceleration, novel FS semantics). |

---

## 2. Tier 1 — Critical Features

### 2.1 Summary table

| # | Feature | Placement | Primary pillar(s) |
|---|---|---|---|
| C1 | Boot path (UEFI + measured boot + handoff) | Kernel + early loader | 5, 6 |
| C2 | Physical memory manager (NUMA-aware) | Kernel | 2 |
| C3 | Virtual memory / address-space objects (5-level paging, PCID, INVPCID) | Kernel | 1, 2, 3 |
| C4 | Capability system (object-capabilities, derivation, revocation) | Kernel | 3, 6 |
| C5 | Thread / scheduling-context objects | Kernel | 2, 3 |
| C6 | SMP-aware scheduler (per-core run queues, work-stealing, NUMA-aware placement) | Kernel | 2 |
| C7 | IPC primitive (synchronous + notification + capability-passing) | Kernel | 3, 4 |
| C8 | Interrupt / exception dispatch (IDT, x2APIC, MSI/MSI-X routing to userspace) | Kernel (vectoring); userspace (handlers) | 3, 5 |
| C9 | High-resolution timer subsystem (TSC-deadline, HPET fallback) | Kernel (arming); userspace (policy) | 2, 3 |
| C10 | Address-space isolation primitives (SMEP/SMAP, CET, PKU, KPTI-style if needed) | Kernel | 6 |
| C11 | Secure-boot / measured-boot root of trust (TPM 2.0 + DRTM) | Early kernel | 6 |
| C12 | Exception handling and #MC machine-check architecture | Kernel | 6 |
| C13 | Page-fault / pager protocol (external pagers in userspace) | Kernel stub + userspace pagers | 3 |
| C14 | Atomic / concurrency primitives ABI (LOCK-prefixed, CMPXCHG16B, MWAIT/UMWAIT, WAITPKG) | Kernel-exposed ABI | 2, 4 |
| C15 | Cryptographic entropy source (RDRAND/RDSEED + jitter + TPM) | Kernel | 6 |
| C16 | Minimal in-kernel logging / panic trace ring | Kernel | 11 |
| C17 | FP/SIMD state management (XSAVES/XSAVEOPT, lazy and eager modes) | Kernel | 1, 10 |
| C18 | Per-CPU data and cross-core IPI primitives | Kernel | 2 |

### 2.2 Detailed entries

#### C1. Boot path (UEFI + measured boot + handoff)

**Description.** UEFI x86_64 boot stub that performs: (a) firmware measurement extension into TPM PCRs, (b) memory map acquisition (`GetMemoryMap`), (c) ACPI RSDP discovery, (d) framebuffer init via GOP, (e) ExitBootServices, (f) jump to long-mode kernel with a typed handoff structure. No Multiboot1/2 legacy.

**Rationale.** Pillar 5 forbids legacy boot. Pillar 6 mandates a measured root of trust from instruction zero.

**Microkernel placement.** Boot loader is a privileged, single-shot component that vanishes after handoff. The kernel proper contains only the post-handoff init path.

**Pillar alignment.** Pillars 5 (no-legacy), 6 (PQ-security: PCR measurements feed later attestation), 11 (UEFI is documented and stable).

**References.**
- UEFI Specification 2.10 (2022), §7 (Services — Boot Services), §8 (Runtime Services).
- TCG PC Client Platform Firmware Profile Specification, Family 2.0, Level 00 Revision 1.05 (2021).
- Intel® 64 and IA-32 Architectures Software Developer's Manual (SDM), Vol. 3A, ch. 9 "Processor Management and Initialization".
- Parno, McCune, Perrig, *Bootstrapping Trust in Modern Computers*, Springer SpringerBriefs in Computer Science, 2011 — measured-boot framing.
- Intel TXT MLE Developer's Guide (Rev. 017, 2017) — DRTM background.

---

#### C2. Physical memory manager (NUMA-aware)

**Description.** Allocator(s) for physical frames in 4 KiB / 2 MiB / 1 GiB granularities. Per-NUMA-domain free lists with cross-domain stealing. Buddy + per-CPU magazine front-ends. Reservations for DMA-capable regions and persistent-memory ranges.

**Rationale.** All higher-level memory abstractions depend on it. NUMA awareness is mandatory under pillar 2.

**Microkernel placement.** Kernel. Physical frames are the lowest-level capability-protected resource (cf. seL4's `Untyped`); userspace cannot be allowed to fabricate physical addresses.

**Pillar alignment.** Pillar 2 (multicore/NUMA), pillar 3 (kernel exposes only typed capabilities to physical memory).

**References.**
- Lameter, *NUMA (Non-Uniform Memory Access): An Overview*, ACM Queue 11(7), 2013.
- Kaminski, *Scalable Memory Allocation Using Jemalloc*, Facebook Engineering tech-note, 2015 — magazine/arena ideas.
- Klein et al., *seL4: Formal Verification of an OS Kernel*, SOSP 2009 — Untyped capability model.
- Intel SDM Vol. 3A, ch. 4 "Paging", §4.5 (4-level / 5-level paging).
- Linux kernel `mm/page_alloc.c` documentation — buddy allocator reference design.

---

#### C3. Virtual memory / address-space objects

**Description.** Address-space objects are first-class capabilities. 4-level and 5-level paging support (CR4.LA57). PCIDs (CR4.PCIDE) and INVPCID for cheap TLB partitioning. Large-page and huge-page support, including transparent promotion in cooperation with userspace pagers. NX, write-protect, user/supervisor, and PKU keys (CR4.PKE) honored.

**Rationale.** Address-space isolation is the bedrock of microkernel safety; PCIDs make per-context switches cheap on many-core machines.

**Microkernel placement.** Page tables are kernel-edited; *policy* (what to map where) is decided by userspace pagers via the fault-redirect protocol (C13).

**Pillar alignment.** Pillars 1 (5-level paging is recent ISA), 2 (PCIDs reduce IPI shootdown pressure), 3 (external pagers).

**References.**
- Intel SDM Vol. 3A, ch. 4 "Paging"; Vol. 3A §4.10 "Caching Translation Information".
- Intel, *5-Level Paging and 5-Level EPT White Paper*, rev. 1.1, 2017.
- Liedtke, *On µ-Kernel Construction*, SOSP 1995 — external pagers.
- Elphinstone & Heiser, *From L3 to seL4 — What Have We Learnt in 20 Years of L4 Microkernels?*, SOSP 2013.

---

#### C4. Capability system

**Description.** All kernel-managed resources (frames, address spaces, threads, endpoints, IRQs, scheduling contexts, IO ports/MMIO ranges, TPM handles) are referenced exclusively by capabilities held in per-process capability tables (CSpaces). Operations: `Derive`, `Mint` (with rights attenuation), `Revoke` (transitive), `Delete`, `Copy` (with badge). Substructural typing at the macro/ABI layer treats capabilities as linear by default.

**Rationale.** Capabilities give a constructive answer to "principle of least authority" and align with pillar 10 (substructural / linear discipline). They also enable confinement proofs.

**Microkernel placement.** Kernel. Capability tables are kernel objects; userspace cannot forge them.

**Pillar alignment.** Pillars 3, 6, 10.

**References.**
- Dennis & Van Horn, *Programming Semantics for Multiprogrammed Computations*, CACM 1966 — original capability concept.
- Shapiro, Smith, Farber, *EROS: A Fast Capability System*, SOSP 1999.
- Klein et al., *seL4: Formal Verification of an OS Kernel*, SOSP 2009; and Sewell et al., *Translation Validation for a Verified OS Kernel*, PLDI 2013.
- Watson et al., *CHERI: A Hybrid Capability-System Architecture*, IEEE S&P 2015 — hardware-capability lineage (informative for future hw bring-up; x86_64 will not have CHERI natively).
- Miller, *Robust Composition: Towards a Unified Approach to Access Control and Concurrency Control*, PhD Thesis, JHU, 2006 — object-capability discipline.

---

#### C5. Thread and scheduling-context objects

**Description.** Threads are passive bundles of register state + CSpace pointer + VSpace pointer + IPC buffer. Scheduling contexts (SC) are separate capabilities encoding budget and period (MCS model). A thread runs only when bound to an SC. This split (à la seL4 MCS) enables principled real-time and prevents priority-inversion exploits via IPC.

**Rationale.** Decoupling thread identity from CPU time enables both rate-monotonic / EDF scheduling and capability-passed temporal isolation.

**Microkernel placement.** Kernel.

**Pillar alignment.** Pillars 2, 3, 4 (priority inversion is an IPC liveness hazard).

**References.**
- Lyons et al., *Mixed-Criticality Support in a High-Assurance, General-Purpose Microkernel*, WMC@RTSS 2014.
- Lyons & Heiser, *Scheduling-Context Capabilities: A Principled, Light-Weight OS Mechanism for Managing Time*, EuroSys 2018.
- Stankovic et al., *Implications of Classical Scheduling Results for Real-Time Systems*, IEEE Computer, 1995 — EDF/RM grounding.

---

#### C6. SMP-aware scheduler

**Description.** Per-core run queues, lock-free or fine-grained-locked. Work stealing across NUMA domains with stealing-distance heuristics. Gang scheduling support for tightly-coupled threads. Topology awareness via CPUID leaf 0x1F (extended topology v2) and ACPI SRAT/SLIT.

**Rationale.** Pillar 2 demands multicore-first; a global run queue or a BKL is structurally disqualified.

**Microkernel placement.** Kernel core mechanism; *policy* (priorities, deadlines) is set via capability invocation by a userspace scheduler manager.

**Pillar alignment.** Pillars 2, 3.

**References.**
- Boyd-Wickizer et al., *Corey: An Operating System for Many Cores*, OSDI 2008.
- Baumann et al., *The Multikernel: A New OS Architecture for Scalable Multicore Systems*, SOSP 2009 — Barrelfish design.
- Lozi et al., *The Linux Scheduler: a Decade of Wasted Cores*, EuroSys 2016 — cautionary tale about NUMA-blind balancing.
- Intel SDM Vol. 3A, ch. 8 "Multiple-Processor Management"; CPUID leaf 0x1F documented in Vol. 2A.
- ACPI Specification 6.5, §5.2.16 (SRAT), §5.2.17 (SLIT).

---

#### C7. IPC primitive

**Description.** *Open design problem (see §6).* Minimum mechanism: synchronous endpoint-based call/reply with capability transfer (seL4-style fast path), augmented with asynchronous notification objects (binary semaphores with badge OR) and userspace-mappable shared queues for bulk data.

**Rationale.** IPC is the microkernel's hot path; its design dominates whole-system performance and liveness.

**Microkernel placement.** Kernel-fast-path; queue memory is in shared userspace mappings.

**Pillar alignment.** Pillars 2 (multicore IPC must avoid cross-core cache-line ping-pong), 3, 4.

**References.**
- Liedtke, *Improving IPC by Kernel Design*, SOSP 1993 — the canonical fast-path paper.
- Elphinstone & Heiser, *From L3 to seL4 — What Have We Learnt in 20 Years of L4 Microkernels?*, SOSP 2013.
- Bershad et al., *Lightweight Remote Procedure Call*, TOCS 1990.
- Härtig et al., *The Performance of µ-Kernel-Based Systems*, SOSP 1997.
- Klein et al., *Comprehensive Formal Verification of an OS Microkernel*, TOCS 2014 — verified IPC.
- Gu et al., *CertiKOS: An Extensible Architecture for Building Certified Concurrent OS Kernels*, OSDI 2016.

---

#### C8. Interrupt and exception dispatch

**Description.** IDT setup, IST stacks for #DF/#MC/NMI, x2APIC (CR4.OSXSAVE + MSR-based APIC), MSI/MSI-X routing such that device interrupts arrive as notification capabilities to userspace driver servers. Legacy PIC and IOAPIC fallback minimized but supported during early boot only.

**Rationale.** Drivers in userspace (pillar 3) require interrupts to be deliverable as IPC events.

**Microkernel placement.** Vectoring and acknowledgement: kernel. Handler logic: userspace.

**Pillar alignment.** Pillars 3, 5, 9.

**References.**
- Intel SDM Vol. 3A, ch. 6 "Interrupt and Exception Handling"; ch. 10 "Advanced Programmable Interrupt Controller (APIC)".
- Leslie et al., *User-Level Device Drivers: Achieved Performance*, JCST 2005.
- Engler, Kaashoek, O'Toole Jr., *Exokernel: An Operating System Architecture for Application-Level Resource Management*, SOSP 1995 — interrupt redirection rationale.

---

#### C9. High-resolution timer subsystem

**Description.** Per-CPU TSC-deadline timers (IA32_TSC_DEADLINE MSR), HPET only as fallback / wall-clock calibration. Invariant TSC (CPUID.80000007H:EDX[8]) is assumed. APIC-timer arming exposed as a kernel capability; timeout *policy* (queues, hierarchies) lives in userspace.

**Rationale.** Pillar 2: per-core deadlines avoid cross-core IPI for timer reprogramming.

**Microkernel placement.** Kernel arms; userspace timer-server multiplexes.

**Pillar alignment.** Pillars 2, 3.

**References.**
- Intel SDM Vol. 3A, §10.5.4 "APIC Timer", §17.17 "Time-Stamp Counter".
- Corbet, *The high-resolution timer API*, LWN, 2006 (background on hrtimer design).
- Brandenburg & Anderson, *On the Implementation of Global Real-Time Schedulers*, RTSS 2009 — per-CPU timer placement.

---

#### C10. Address-space isolation primitives

**Description.** SMEP/SMAP enforced; CET Indirect Branch Tracking + Shadow Stack enabled for both kernel and userspace where supported; MPK/PKU keys used for intra-address-space isolation in userspace servers; LASS (Linear Address Space Separation) where present (Sierra Forest+).

**Rationale.** Defense-in-depth even within the strict microkernel; pillar 6.

**Microkernel placement.** Kernel enables and exposes; userspace servers opt in via capability operations.

**Pillar alignment.** Pillars 1, 6.

**References.**
- Intel SDM Vol. 1, ch. 18 "Control-flow Enforcement Technology (CET)"; Vol. 3A §4.6 (MPK).
- Vahldiek-Oberwagner et al., *ERIM: Secure, Efficient In-process Isolation with Protection Keys (MPK)*, USENIX Security 2019.
- Burow et al., *Control-Flow Integrity: Precision, Security, and Performance*, ACM CSUR 2017.

---

#### C11. Secure-boot / measured-boot root of trust

**Description.** UEFI Secure Boot for the loader; TPM 2.0 PCR extensions for kernel image, initial CSpace, and the first userspace root task; optional DRTM (Intel TXT / SINIT) for late launch. Attestation quotes use a hybrid scheme (ECDSA-P384 + ML-DSA-65) when supported, falling back to ECDSA alone if the TPM lacks PQ support; the OS-level attestation server (userspace) speaks fully PQ-hybrid.

**Rationale.** Pillar 6.

**Microkernel placement.** TPM driver is in userspace; the *measurement* of the early kernel is done in firmware/boot. The kernel only carries the verified PCR digest forward.

**Pillar alignment.** Pillars 6, 11.

**References.**
- TCG TPM 2.0 Library Specification, Part 1 Architecture, Rev. 1.59 (2019).
- UEFI Specification 2.10, §32 "Secure Boot".
- NIST FIPS 203 (ML-KEM), FIPS 204 (ML-DSA), FIPS 205 (SLH-DSA), 2024.
- Bernstein & Lange, *Post-quantum cryptography*, Nature 549, 2017.
- TCG D-RTM Architecture Specification 1.0.0 (2013).

---

#### C12. Machine-check and exception architecture

**Description.** #MC handler with MCA bank decoding (IA32_MCi_STATUS), enhanced MCA, local-MCE delivery. Recoverable errors are forwarded to a userspace RAS (Reliability/Availability/Serviceability) server.

**Rationale.** Robustness; pillar 6 includes integrity under hardware fault.

**Microkernel placement.** Trap entry: kernel. Policy / logging: userspace RAS server.

**References.**
- Intel SDM Vol. 3B, ch. 16 "Machine-Check Architecture".
- Hwang et al., *Cosmic Rays Don't Strike Twice: Understanding the Nature of DRAM Errors*, ASPLOS 2012 — design context.

---

#### C13. Page-fault / external-pager protocol

**Description.** On #PF the kernel synthesizes a fault IPC to the address-space's bound pager capability. The pager responds with map/unmap operations against the address-space capability. Demand paging, copy-on-write, and memory-mapped IO are all expressed this way.

**Rationale.** Pillar 3: paging *policy* belongs in userspace.

**Microkernel placement.** Fault trampoline in kernel; pagers in userspace.

**References.**
- Liedtke, *On µ-Kernel Construction*, SOSP 1995 — external pagers.
- Young et al., *The Duality of Memory and Communication in the Implementation of a Multiprocessor Operating System*, SOSP 1987 — Mach pager precedent.

---

#### C14. Atomic / concurrency primitives ABI

**Description.** A documented, macro-encoded ABI for lock-free queues, MCS locks, RCU-equivalents, and seqlocks using LOCK CMPXCHG / CMPXCHG16B / XADD / LOCK BTS, MONITOR/MWAIT and UMONITOR/UMWAIT (WAITPKG) for low-latency wait, and PAUSE / TPAUSE for spin tuning. TSX-NI (RTM/HLE) is offered as an opt-in fast path with fallback.

**Rationale.** Pillars 2 and 4. Lock-free / wait-free structures are central to the deadlock-freedom argument.

**Microkernel placement.** The kernel implements its own internal structures with this ABI and exposes the *patterns* (not the primitives — those are CPU instructions) to userspace via documentation and macro libraries.

**Pillar alignment.** Pillars 2, 4, 10.

**References.**
- Herlihy & Shavit, *The Art of Multiprocessor Programming*, 2nd ed., 2020.
- Mellor-Crummey & Scott, *Algorithms for Scalable Synchronization on Shared-Memory Multiprocessors*, TOCS 1991 — MCS lock.
- McKenney et al., *Read-Copy Update (RCU)*, in Linux kernel documentation; and Desnoyers et al., *User-Level Implementations of Read-Copy Update*, IEEE TPDS 2012.
- Intel SDM Vol. 2 — TPAUSE/UMWAIT/UMONITOR (WAITPKG), CMPXCHG16B; Vol. 1 ch. 16 "Programming with Intel TSX".
- Yoo et al., *Performance Evaluation of Intel® Transactional Synchronization Extensions for High-Performance Computing*, SC 2013.

---

#### C15. Cryptographic entropy source

**Description.** RDRAND + RDSEED, mixed with TPM `TPM2_GetRandom`, mixed with a CPU-jitter source (Müller's `jitterentropy`-style design), feeding a Hash-DRBG (SHA-3-based) per-CPU pool. Re-seeded on schedule and on entropy-low events. Exposed to userspace via a capability that yields seeded streams.

**Rationale.** Every cryptographic operation in PaideiaOS (PQ KEMs, attestation, secure-boot continuation) requires high-quality entropy.

**Microkernel placement.** Kernel hosts the seed pool (privileged MSR access for RDSEED diagnostics, IA32_TME, etc.). Userspace crypto servers consume via capability.

**References.**
- NIST SP 800-90A Rev.1 (DRBGs), 800-90B (entropy sources), 800-90C (RBG constructions).
- Müller, *CPU Time Jitter Based Non-Physical True Random Number Generator*, BSI tech report, 2014.
- Intel, *Intel® Digital Random Number Generator (DRNG) Software Implementation Guide*, rev. 2.1, 2018.

---

#### C16. In-kernel logging / panic trace ring

**Description.** A small lock-free per-CPU ring buffer for kernel diagnostic events; mirrored to a userspace log server on first opportunity. Panic path dumps registers, last-N events, and current capability of the running thread to a serial / framebuffer sink.

**Rationale.** A microkernel that cannot be debugged is not a microkernel that can be developed. Kept minimal in the kernel; rich tooling lives in userspace.

**Microkernel placement.** Minimal in kernel; full observability in userspace (see U7, D6).

**References.**
- Cantrill et al., *Dynamic Instrumentation of Production Systems*, USENIX ATC 2004 — DTrace lineage (informative).
- Linux `printk` ring buffer design — Documentation/admin-guide/printk-formats.rst (informative).

---

#### C17. FP/SIMD state management

**Description.** XSAVES/XSAVEC/XSAVEOPT with compacted form; per-thread XSAVE area sized from CPUID leaf 0xD. Lazy switching via CR0.TS *only* when measured to win on the target microarchitecture; otherwise eager. AVX-512 state (ZMM, opmask, hi16) gated by feature detection. AMX (TILECFG/TILEDATA) state likewise, where present.

**Rationale.** Pillar 1 (full ISA) and pillar 10 (FP-style runtime may use SIMD heavily) make rigorous FPU state management critical.

**Microkernel placement.** Kernel.

**References.**
- Intel SDM Vol. 1 ch. 13 "Managing State Using the XSAVE Feature Set"; Vol. 2 (XSAVES/XSAVEC/XSAVEOPT/XRSTORS).
- Intel® AMX Architecture Specification, rev. 1.5, 2023.

---

#### C18. Per-CPU data and cross-core IPI primitives

**Description.** GS base (IA32_KERNEL_GS_BASE, FSGSBASE) per-CPU pointer pattern; cross-core IPIs over x2APIC self/destination shorthand; cluster mode where helpful. TLB-shootdown coalescing using PCID generations.

**Rationale.** Pillar 2.

**Microkernel placement.** Kernel.

**References.**
- Intel SDM Vol. 3A §10.6 "Issuing Interprocessor Interrupts".
- Bonwick & Adams, *Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources*, USENIX ATC 2001 — per-CPU patterning lineage.
- Amit & Wei, *The Design and Implementation of Hyperupcalls*, USENIX ATC 2018 — TLB-shootdown reduction techniques.

---

## 3. Tier 2 — Essential Features

### 3.1 Summary table

| # | Feature | Placement | Primary pillar(s) |
|---|---|---|---|
| E1 | Userspace runtime / root task | Userspace | 3, 10 |
| E2 | Binary / capability-aware executable format | Userspace tooling + tiny kernel loader | 3, 6, 10 |
| E3 | Driver framework (hierarchical, hot-pluggable) | Userspace | 3, 9 |
| E4 | PCIe / NVMe / xHCI bus enumeration | Userspace | 3, 5 |
| E5 | Storage stack (NVMe + block translation + crypto-FS) | Userspace | 3, 6 |
| E6 | VFS-equivalent: typed name-resolution graph | Userspace | 3, 8 |
| E7 | Networking stack (modern OSI layering, user-space) | Userspace | 3, 7 |
| E8 | Post-quantum crypto subsystem | Userspace library + kernel entropy hook | 6 |
| E9 | TLS 1.3 + hybrid PQ handshake server | Userspace | 6, 7 |
| E10 | Init / service supervisor (capability spawner) | Userspace | 3 |
| E11 | Hot-plug event bus | Userspace | 3, 9 |
| E12 | Semantic shell + structured pipeline runtime | Userspace | 8 |
| E13 | Native Unicode text subsystem (UAX-compliant) | Userspace | 8 |
| E14 | Build-time formal-property checker for assembly macros | Build tooling | 10, 11 |
| E15 | Time synchronization (NTS, Roughtime) | Userspace | 6, 7 |
| E16 | Identity / principal service (capability-issuing) | Userspace | 6 |
| E17 | Filesystem(s) — at least one CoW + integrity-checked | Userspace | 6 |
| E18 | DNS resolver (DoH/DoT/DoQ; DNSSEC) | Userspace | 7 |
| E19 | Audit / provenance log (append-only, signed) | Userspace | 6, 11 |

### 3.2 Detailed entries

#### E1. Userspace runtime / root task

**Description.** The first userspace process bootstrapped by the kernel. It holds the root CSpace, the device-tree-equivalent (ACPI-derived), and is responsible for spawning system services and applying initial policy. Roughly analogous to seL4's `init` / Genode's `core`.

**Rationale.** A microkernel is incomplete without a defined root-of-policy.

**Pillar alignment.** Pillars 3, 10 (root task is the first place FP-style capability handling is enforced).

**References.**
- Feske, *Genode Operating System Framework — Foundations*, Genode Labs, 2023.
- Klein et al., *seL4 Reference Manual*, 13.0.0, 2023.

---

#### E2. Capability-aware executable format

**Description.** A new, small, ELF-inspired but not ELF-compatible binary format ("PAX" — placeholder name) that carries: (a) code/data sections, (b) a *capability manifest* describing the syscalls / capabilities the binary expects to receive, (c) a signature block (hybrid PQ), (d) a build-tool-emitted effect-type summary for the FP discipline checker.

**Rationale.** Pillars 3, 6, 10. POSIX ELF has accreted too much legacy; clean slate is justified here.

**Pillar alignment.** Pillars 5, 6, 10.

**References.**
- TIS Committee, *Executable and Linkable Format (ELF) Specification* — anti-pattern reference.
- Watson et al., *CheriABI: Enforcing Valid Pointer Provenance and Minimizing Pointer Privilege in the POSIX C Run-time*, ASPLOS 2019 — capability-aware ABI lineage.
- Murray et al., *seL4: From General Purpose to a Proof of Information Flow Enforcement*, IEEE S&P 2013.

---

#### E3. Driver framework (hierarchical, hot-pluggable)

**Description.** Drivers are userspace processes parameterized by capabilities: an MMIO range, an IRQ notification, a DMA-able memory region (with IOMMU-translated bus addresses). Drivers form a tree mirroring bus topology; child drivers are spawned by parents with sub-capability sets. Lifecycle (probe/attach/suspend/detach) is a typed protocol.

**Rationale.** Pillars 3, 9.

**Pillar alignment.** Pillars 3, 9, 10.

**References.**
- Leslie et al., *User-Level Device Drivers: Achieved Performance*, JCST 2005.
- Swift et al., *Improving the Reliability of Commodity Operating Systems*, TOCS 2005 — Nooks/SafeDrive lineage.
- Feske & Helmuth, *Design of the Bastei OS Architecture*, TU Dresden, 2007 — Genode driver hierarchy.
- Boos et al., *Theseus: an Experimental Operating System for Modern Hardware*, OSDI 2020 — intralingual reflection (informative for FP-style discipline).

---

#### E4. PCIe / NVMe / xHCI enumeration

**Description.** A userspace bus-enumeration server walks the PCIe configuration space via the MCFG ECAM region, builds the bus tree, programs the IOMMU (Intel VT-d) for per-device protection domains, then hands child capabilities to the driver framework.

**Rationale.** Pillars 3, 5, 9.

**Pillar alignment.** Pillars 3, 5, 9.

**References.**
- PCI-SIG, *PCI Express Base Specification Revision 6.0* (2022).
- NVM Express Base Specification 2.0c (2022).
- xHCI Specification 1.2 (2019).
- Intel, *Virtualization Technology for Directed I/O (VT-d) Architecture Specification*, rev. 4.1, 2022.
- ACPI 6.5 §5.2.6 (MCFG).

---

#### E5. Storage stack

**Description.** NVMe driver → block-cache server → encryption layer (AES-256-XTS today, ML-KEM-wrapped keys for at-rest re-keying tomorrow) → filesystem(s). Each layer is a separate userspace process communicating via shared-memory ring buffers with capability-passed completion notifications.

**Rationale.** Pillars 3, 6.

**Pillar alignment.** Pillars 3, 6.

**References.**
- Caulfield et al., *Moneta: A High-Performance Storage Array Architecture for Next-Generation, Non-Volatile Memories*, MICRO 2010 — design influence.
- Yang et al., *SPDK: A Development Kit to Build High-Performance Storage Applications*, IEEE Cloud 2017 — user-space NVMe rationale.
- Halcrow et al., *fscrypt design*, Linux Documentation/filesystems/fscrypt.rst — at-rest model.

---

#### E6. VFS-equivalent: typed name-resolution graph

**Description.** Rather than a POSIX VFS of byte-stream files mounted on a single tree, PaideiaOS exposes a *typed* name graph: each node is a typed object (file, directory, capability, service endpoint, semantic record) accessed by capability + path. Mount semantics are replaced by capability composition: a service may *graft* a sub-graph into another principal's namespace.

**Rationale.** Pillars 3, 5, 8 — supports the semantic shell.

**Pillar alignment.** Pillars 3, 5, 8.

**References.**
- Pike et al., *Plan 9 from Bell Labs*, USENIX, 1995 — per-process namespaces.
- Pfaff et al., *The Open vSwitch database management protocol* — JSON-typed records (informative).
- Microsoft, *PowerShell pipelines and object streams*, official docs (informative for shell pipeline typing).
- TODO: verify reference — *Nushell book*, https://www.nushell.sh/book/ (informative for typed pipelines).

---

#### E7. Networking stack (user-space, modern OSI)

**Description.** L2 (Ethernet + 802.1Q/AE), L3 (IPv6-first; IPv4 only via translation), L4 (UDP, TCP, SCTP, QUIC), L5+ as servers. Zero-copy fast-path using DPDK-style polling on cores reserved for I/O when configured; otherwise IRQ-driven. RSS / RPS via Flow Director. Strict layering exposed through capability-typed sockets.

**Rationale.** Pillar 7.

**Pillar alignment.** Pillars 2, 3, 7.

**References.**
- RFC 9293 *Transmission Control Protocol (TCP)*, 2022 (the obsoletes-RFC-793 update).
- RFC 9000 *QUIC: A UDP-Based Multiplexed and Secure Transport*, 2021; RFC 9001 (TLS in QUIC); RFC 9002 (loss detection).
- RFC 8200 *Internet Protocol, Version 6 (IPv6) Specification*, 2017.
- RFC 4960 *Stream Control Transmission Protocol*, 2007.
- Belay et al., *IX: A Protected Dataplane Operating System for High Throughput and Low Latency*, OSDI 2014.
- Jeong et al., *mTCP: a Highly Scalable User-level TCP Stack for Multicore Systems*, NSDI 2014.
- Marty et al., *Snap: a Microkernel Approach to Host Networking*, SOSP 2019.

---

#### E8. Post-quantum crypto subsystem

**Description.** Library of vetted PQ primitives:
- **KEMs:** ML-KEM-512/768/1024 (FIPS 203).
- **Signatures:** ML-DSA-44/65/87 (FIPS 204), SLH-DSA (FIPS 205).
- **Stateful hash-based:** XMSS / LMS for firmware/boot signing (RFC 8391, RFC 8554).
- **Hybrid combiners:** X25519+ML-KEM-768; Ed25519+ML-DSA-65.
- Constant-time implementations vectorized via AVX2/AVX-512.

**Rationale.** Pillar 6.

**Pillar alignment.** Pillars 1 (vectorization), 6.

**References.**
- NIST FIPS 203 *Module-Lattice-Based Key-Encapsulation Mechanism Standard*, 2024.
- NIST FIPS 204 *Module-Lattice-Based Digital Signature Standard*, 2024.
- NIST FIPS 205 *Stateless Hash-Based Digital Signature Standard*, 2024.
- RFC 8391 *XMSS: eXtended Merkle Signature Scheme*, 2018.
- RFC 8554 *Leighton-Micali Hash-Based Signatures*, 2019.
- Bos et al., *CRYSTALS-Kyber: a CCA-secure module-lattice-based KEM*, EuroS&P 2018.
- Ducas et al., *CRYSTALS-Dilithium: A Lattice-Based Digital Signature Scheme*, IACR TCHES 2018.
- Bernstein et al., *SPHINCS+: stateless hash-based signatures*, EUROCRYPT 2019.
- draft-ietf-tls-hybrid-design (current draft) — hybrid handshake construction.

---

#### E9. TLS 1.3 + hybrid PQ handshake server

**Description.** A userspace TLS server (callable as a service by network servers) implementing RFC 8446 with hybrid key share groups (X25519+ML-KEM-768) and PQ-capable certificate chains (ML-DSA / SLH-DSA leaves).

**Rationale.** Pillars 6, 7.

**Pillar alignment.** Pillars 6, 7.

**References.**
- RFC 8446 *The Transport Layer Security (TLS) Protocol Version 1.3*, 2018.
- draft-ietf-tls-hybrid-design — hybrid groups in TLS.
- Stebila & Mosca, *Post-Quantum Key Exchange for the Internet and the Open Quantum Safe Project*, SAC 2016.

---

#### E10. Init / service supervisor

**Description.** Capability-spawning supervisor: declarative service descriptions; dependencies are capability arrival events; restart policies are typed; no shell scripts in the critical path. Each service is launched in a fresh CSpace populated only with the capabilities it declared.

**Rationale.** Pillar 3 (least authority by construction) and pillar 10 (declarative + typed).

**Pillar alignment.** Pillars 3, 6, 10.

**References.**
- Helsley, *runit/s6 supervision suite design notes* (informative).
- Feske, *Genode init component*, Genode Foundations book ch. 8.
- Pope & Vendrov, *systemd considered harmful: a contrasting design study* — TODO: verify reference (use as cautionary tale only if locatable).

---

#### E11. Hot-plug event bus

**Description.** A capability-typed pub/sub bus that delivers `device-arrived` / `device-departed` / `device-failed` events to interested driver-manager servers. Topology-aware (events carry the bus path).

**Rationale.** Pillar 9.

**Pillar alignment.** Pillars 3, 9.

**References.**
- ACPI 6.5 §6.3 (Device Insertion, Removal, and Status Objects).
- PCIe Base Spec 6.0 §6.7 (Hot-Plug).

---

#### E12. Semantic shell + structured pipeline runtime

**Description.** Commands emit typed records (schema-tagged). Pipes carry records, not bytes. Queries are written in a small declarative language (think: SQL-lite + jq + datalog hybrid) operating over the record streams. Tab completion is *type-driven*. History is a queryable database, not a flat file.

**Rationale.** Pillar 8.

**Pillar alignment.** Pillars 5, 8, 10.

**References.**
- TODO: verify reference — Sklar, *PowerShell in Action*, 3rd ed., Manning, 2017 (typed pipelines, informative).
- TODO: verify reference — *Nushell book* (https://www.nushell.sh/book/).
- Pike, *The Text Editor sam*, Software Pract. Exp. 1987 — structural regex lineage.
- Codd, *A Relational Model of Data for Large Shared Data Banks*, CACM 1970 — relational grounding.
- Wadler, *Comprehending Monads*, LFP 1990 — pipeline-as-monad framing.

---

#### E13. Native Unicode text subsystem

**Description.** All text APIs are Unicode 16+ native, normalize on input (NFC default), implement UAX #29 (graphemes), UAX #14 (line break), UAX #15 (normalization), UAX #31 (identifiers), UTS #46 (IDNA), and full BiDi (UAX #9). String types are *grapheme-cluster*-indexed by default, with explicit byte and code-point views.

**Rationale.** Pillar 8.

**Pillar alignment.** Pillars 5, 8.

**References.**
- Unicode Consortium, *The Unicode Standard, Version 16.0*, 2024.
- Unicode Standard Annexes #9, #14, #15, #29, #31; Technical Standard #46.
- Davis, *Unicode Text Segmentation*, UAX #29 (current rev).

---

#### E14. Build-time formal-property checker for assembly macros

**Description.** A tool (likely in a typed functional language at build time — OCaml or Haskell) that consumes the macro-annotated assembly and verifies:
- Capability linearity (no double-use, no drop without explicit `Delete`).
- Effect-type honoring of monadic call conventions.
- Absence of forbidden ISA instructions in security-critical paths (e.g., no indirect branch outside a CET-IBT-protected slot).
- Per-section invariants (e.g., this function has no LOCK prefix; this critical section is bounded).

**Rationale.** Pillars 10, 11.

**Pillar alignment.** Pillars 6, 10, 11.

**References.**
- Necula, *Proof-Carrying Code*, POPL 1997.
- Morrisett et al., *From System F to Typed Assembly Language*, TOPLAS 1999.
- Chlipala, *A Verified Compiler for an Impure Functional Language*, POPL 2010.
- Walker, *Substructural Type Systems*, ch. in *Advanced Topics in Types and Programming Languages*, MIT Press, 2005.

---

#### E15. Time synchronization

**Description.** NTS (Network Time Security, RFC 8915) over NTPv4 for general use; Roughtime as a sanity check; PTP (IEEE 1588) for low-latency LAN cases where supported by NIC.

**Rationale.** Pillars 6, 7. NTP without NTS is incompatible with pillar 6.

**Pillar alignment.** Pillars 6, 7.

**References.**
- RFC 8915 *Network Time Security for the Network Time Protocol*, 2020.
- RFC 5905 *Network Time Protocol Version 4*, 2010.
- Malhotra et al., *Roughtime*, draft-ietf-ntp-roughtime (current draft).
- IEEE 1588-2019 *Precision Time Protocol*.

---

#### E16. Identity / principal service

**Description.** A userspace service that mints principal capabilities, federates with external identity providers via PQ-secured channels, and is the source of truth for ACL-equivalent decisions (which are themselves capability mints).

**Rationale.** Pillar 6.

**Pillar alignment.** Pillars 6, 10.

**References.**
- Lampson et al., *Authentication in Distributed Systems: Theory and Practice*, TOCS 1992.
- Saltzer & Schroeder, *The Protection of Information in Computer Systems*, Proc. IEEE 1975 — principle of least privilege.

---

#### E17. Filesystem(s) — at least one CoW + integrity-checked

**Description.** A CoW filesystem with Merkle-tree integrity (BLAKE3 hashes), per-file encryption keys wrapped by a per-user PQ KEM, snapshots, send/receive. Inspired by ZFS / Btrfs / bcachefs but designed without POSIX permission baggage.

**Rationale.** Pillars 5, 6.

**Pillar alignment.** Pillars 5, 6, 8 (semantic queryability of metadata).

**References.**
- Bonwick et al., *The Zettabyte File System*, USENIX FAST 2003.
- Rodeh et al., *BTRFS: The Linux B-tree Filesystem*, ACM TOS 2013.
- Overstreet, *bcachefs principles of operation*, https://bcachefs.org (informative).
- Aumasson et al., *BLAKE3: one function, fast everywhere*, IACR ePrint 2020/067.

---

#### E18. DNS resolver

**Description.** Userspace recursive / stub resolver supporting DoH (RFC 8484), DoT (RFC 7858), DoQ (RFC 9250), DNSSEC validation (RFC 9364 roadmap), and qname minimization (RFC 9156).

**Rationale.** Pillar 7.

**Pillar alignment.** Pillars 6, 7.

**References.**
- RFC 8484 *DNS Queries over HTTPS (DoH)*, 2018.
- RFC 7858 *Specification for DNS over Transport Layer Security (TLS)*, 2016.
- RFC 9250 *DNS over Dedicated QUIC Connections*, 2022.
- RFC 9156 *DNS Query Name Minimisation to Improve Privacy*, 2021.

---

#### E19. Audit / provenance log

**Description.** Append-only, cryptographically chained (PQ-signed) log of security-relevant events: capability mints, revocations, principal authentication outcomes, attestation quotes, driver loads. Optionally exported to remote witness servers.

**Rationale.** Pillars 6, 11.

**Pillar alignment.** Pillars 6, 11.

**References.**
- Crosby & Wallach, *Efficient Data Structures for Tamper-Evident Logging*, USENIX Security 2009.
- Schneier & Kelsey, *Secure Audit Logs to Support Computer Forensics*, ACM TISSEC 1999.

---

## 4. Tier 3 — Usual Features

### 4.1 Summary table

| # | Feature | Placement | Primary pillar(s) |
|---|---|---|---|
| U1 | ACPI subsystem (interpreter + table parser) | Userspace | 3, 5 |
| U2 | Power management (P-states, C-states, RAPL) | Userspace policy + kernel MSR proxy | 2 |
| U3 | USB stack (xHCI + class drivers) | Userspace | 3, 9 |
| U4 | Audio stack (Intel HDA, USB audio) | Userspace | 3 |
| U5 | Graphics / display stack (DRM-equivalent + GPU drivers) | Userspace | 3 |
| U6 | Compositor / windowing (Wayland-like, capability-typed) | Userspace | 3, 8 |
| U7 | Observability / tracing (eBPF-equivalent? See open questions) | Userspace + kernel hooks | 11 |
| U8 | Container / sandbox primitives (capability-only, no namespaces) | Userspace | 3, 6 |
| U9 | Virtualization (VT-x/VMX, EPT, VT-d for guests) | Userspace VMM | 3 |
| U10 | Multi-user / session management | Userspace | 6 |
| U11 | Package manager (signed, content-addressed) | Userspace | 6 |
| U12 | Battery / thermal / sensor framework | Userspace | 9 |
| U13 | Bluetooth stack | Userspace | 3, 9 |
| U14 | Wi-Fi stack (incl. WPA3 / SAE / OWE) | Userspace | 6, 7 |
| U15 | Printing / document services | Userspace | 5 |
| U16 | Locale and i18n services | Userspace | 8 |

### 4.2 Detailed entries (condensed where straightforward)

#### U1. ACPI subsystem

**Description.** An AML interpreter (likely a port of ACPICA's algorithms reimplemented under PaideiaOS's macro discipline) running in userspace, plus parsers for static tables (MADT, MCFG, SRAT, SLIT, HMAT, PPTT, FACP, DSDT). Kernel only provides raw mapping of the tables.

**Microkernel placement.** Userspace. AML is too large and too quirky for kernel space.

**References.** ACPI Specification 6.5 (UEFI Forum, 2022); ACPICA reference implementation documentation.

---

#### U2. Power management

**Description.** P-state control via HWP (Intel Speed Shift; IA32_HWP_REQUEST), C-state coordination via MWAIT hints, RAPL energy accounting (MSR_RAPL_POWER_UNIT etc.), per-domain policies decided by a userspace power manager.

**Microkernel placement.** Policy in userspace; MSR access mediated by capability.

**References.** Intel SDM Vol. 3B, ch. 14 "Power and Thermal Management"; Hähnel et al., *Measuring Energy Consumption for Short Code Paths Using RAPL*, SIGMETRICS Perf. Eval. Rev. 2012.

---

#### U3. USB stack

**Description.** xHCI driver → core USB transfer engine → class drivers (HID, mass storage, audio class, CDC, video class). All userspace. Each device → process boundary mediated by capability.

**Microkernel placement.** Userspace.

**References.** xHCI Specification 1.2 (2019); USB 3.2 Specification (USB-IF, 2017); USB4 Specification 2.0 (2022).

---

#### U4. Audio stack

**Description.** Intel HDA driver + USB-audio class driver; mixing graph as a userspace dataflow server; low-latency mode bypasses mixing with capability-gated direct access.

**Microkernel placement.** Userspace.

**References.** Intel High Definition Audio Specification Rev. 1.0a (2010); JACK Audio Connection Kit design papers (informative).

---

#### U5. Graphics / display stack

**Description.** GPU driver as userspace (akin to Linux DRM/KMS but without the kernel-mode component). Command-buffer submission via capability-tagged ring buffers; IOMMU isolation per process. Vendor specifics (Intel Xe, AMD, NVIDIA) handled by vendor-specific userspace servers.

**Microkernel placement.** Userspace.

**References.** Larabel et al., *The State of Open-Source GPU Drivers*, Phoronix (informative); Feske et al., *Quality-Assuring Scheduling — Using Stochastic Behavior to Improve Resource Utilization*, RTSS 2005 (frame-pacing relevance).

---

#### U6. Compositor / windowing

**Description.** A Wayland-conceptual compositor where surface protocols are capability-typed object endpoints rather than byte protocols. Native semantic-shell integration: windows expose typed query interfaces.

**Microkernel placement.** Userspace.

**References.** Wayland protocol documentation, https://wayland.freedesktop.org; Pike, *Window Systems Should Be Transparent*, USENIX, 1988.

---

#### U7. Observability / tracing

**Description.** Static tracepoints in the kernel with negligible disabled-cost; user-space aggregation. Choice of dynamic instrumentation mechanism is an open question (§7).

**Microkernel placement.** Hooks in kernel; logic in userspace.

**References.** Cantrill, Shapiro, Leventhal, *Dynamic Instrumentation of Production Systems*, USENIX ATC 2004; Gregg, *BPF Performance Tools*, Addison-Wesley, 2019.

---

#### U8. Container / sandbox primitives

**Description.** No Linux namespaces, no cgroups. Sandboxing falls out for free from capability discipline: spawning a process with a restricted CSpace *is* the sandbox. A "container" is a CSpace template + a namespace graft.

**Microkernel placement.** Userspace.

**References.** Watson et al., *Capsicum: practical capabilities for UNIX*, USENIX Security 2010.

---

#### U9. Virtualization (VT-x)

**Description.** A userspace VMM using VMX root-mode entry through a kernel capability (`VMCS-create`, `VMENTER`, `VMEXIT-dispatch`). EPT for guest paging; VT-d for guest device pass-through; APICv for low-overhead interrupts.

**Microkernel placement.** Kernel handles the privileged VMX transitions; the VMM logic (device emulation, guest scheduling) is userspace.

**References.** Intel SDM Vol. 3C, chs. 23–33 "Intel® Virtual-Machine Extensions"; Belay et al., *Dune: Safe User-Level Access to Privileged CPU Features*, OSDI 2012; Bonzini, *KVM: the Kernel-based Virtual Machine* (informative).

---

#### U10. Multi-user / session management

**Description.** "User" is just a principal capability; sessions are CSpace bundles. Login is an authentication protocol (PQ-hardened) producing a capability set.

**Microkernel placement.** Userspace.

**References.** Saltzer & Schroeder, *The Protection of Information in Computer Systems*, Proc. IEEE 1975.

---

#### U11. Package manager

**Description.** Content-addressed (BLAKE3) packages, signed by hybrid PQ schemes, installed into per-user content stores (Nix-influenced layout). Reproducible builds required.

**Microkernel placement.** Userspace.

**References.** Dolstra, *The Purely Functional Software Deployment Model*, PhD thesis, Utrecht University, 2006; Lamb & Zacchiroli, *Reproducible Builds: Increasing the Integrity of Software Supply Chains*, IEEE Software 2021.

---

#### U12. Battery / thermal / sensor framework

**Description.** Generic sensor capability typed by physical quantity (with units in the type). Battery and thermal are special cases consumed by the power manager.

**Microkernel placement.** Userspace.

**References.** ACPI 6.5 ch. 10 (Power Source and Power Meter Devices); ch. 11 (Thermal Management).

---

#### U13. Bluetooth stack

**Description.** HCI + L2CAP + GATT + classic profiles. PQ considerations: standard BT pairing is *not* PQ-safe; PaideiaOS will warn and gate sensitive use.

**Microkernel placement.** Userspace.

**References.** Bluetooth Core Specification 5.4 (2023); Antonioli et al., *The KNOB is Broken: Exploiting Low Entropy in the Encryption Key Negotiation of Bluetooth BR/EDR*, USENIX Security 2019.

---

#### U14. Wi-Fi stack

**Description.** 802.11ax/be MAC + WPA3-SAE / OWE / 802.1X-EAP-TLS (with hybrid PQ where peer supports). Open question: whether to push the MAC down into NIC firmware (off-host) or maintain a software MAC.

**Microkernel placement.** Userspace.

**References.** IEEE 802.11-2020; IEEE 802.11be (Wi-Fi 7) draft; Vanhoef & Ronen, *Dragonblood: Analyzing the Dragonfly Handshake of WPA3 and EAP-pwd*, IEEE S&P 2020.

---

#### U15. Printing / document services

**Description.** IPP/IPP-Everywhere (RFC 8011) client; PDF-rendering server in userspace.

**Microkernel placement.** Userspace.

**References.** RFC 8011 *Internet Printing Protocol/1.1: Model and Semantics*, 2017.

---

#### U16. Locale and i18n services

**Description.** CLDR-backed locale data, ICU-style collation, formatting, calendar conversions. Locale is a typed object, not an environment variable.

**Microkernel placement.** Userspace.

**References.** Unicode Common Locale Data Repository v45 (2024); Davis & Whistler, *Unicode Collation Algorithm*, UTS #10.

---

## 5. Tier 4 — Desirable Features

### 5.1 Summary table

| # | Feature | Placement | Primary pillar(s) |
|---|---|---|---|
| D1 | Confidential computing (Intel TDX) host & guest | Userspace VMM; kernel SEAM coordination | 6 |
| D2 | Intel SGX enclave host (legacy on Core; deprecated on server) | Userspace + kernel SGX driver shim | 6 |
| D3 | Real-time scheduling guarantees (EDF, MCS, mixed-criticality) | Kernel SC + userspace policy | 2 |
| D4 | Formal verification hooks (refinement to seL4-style proofs) | Build tooling | 10, 11 |
| D5 | Hardware-accelerated FP-style runtime (persistent data structures on AVX-512 + AMX) | Userspace runtime | 1, 10 |
| D6 | AI / ML acceleration primitives (AMX, AVX-512 VNNI, DLB) | Userspace runtime | 1 |
| D7 | Attestation services (TPM + DRTM + remote attestation with PQ quotes) | Userspace | 6 |
| D8 | Advanced semantic-shell capabilities (datalog queries over system state) | Userspace | 8 |
| D9 | Novel filesystem semantics (graph FS, versioned FS, time-travel) | Userspace | 8 |
| D10 | DPU / SmartNIC offload | Userspace | 2, 7 |
| D11 | Persistent-memory / CXL.mem first-class support | Kernel PM manager + userspace | 1, 2 |
| D12 | Disaggregated-memory / far-memory support | Userspace | 2 |
| D13 | Replay / record debugging at IPC granularity | Userspace tooling + kernel timestamps | 11 |
| D14 | Capability-based distributed extension (single-system-image across nodes) | Userspace | 3, 6, 7 |
| D15 | Energy-aware scheduling (joules-per-task accounting) | Userspace policy | 2 |
| D16 | Anti-Spectre/Meltdown microarchitectural mitigations as policy capabilities | Kernel exposes; userspace selects | 6 |
| D17 | Hardware transactional memory (TSX-NI) as a scheduling resource | Kernel | 2, 4 |
| D18 | In-network compute coordination (P4-programmable NIC + OS) | Userspace | 7 |

### 5.2 Detailed entries (selected)

#### D1. Confidential computing (Intel TDX)

**Description.** TDX module-aware host kernel that can host TD guests, with measured launch and PQ-signed attestation reports forwarded by the userspace attestation server. TDX Connect / TEE-IO when generally available.

**Microkernel placement.** TDX SEAM transitions are kernel-mediated capability operations; everything else is userspace.

**References.** Intel, *Intel® Trust Domain Extensions (Intel® TDX) Module Base Architecture Specification*, rev. 1.5, 2023; Cheng et al., *Intel TDX Demystified: A Top-Down Approach*, ACM Computing Surveys 2024.

---

#### D2. Intel SGX

**Description.** SGX is deprecated on recent Xeon Scalable but remains on Core i7 client parts targeted by PaideiaOS. We provide an SGX enclave host for legacy compatibility with existing enclave ecosystems. New code is steered to TDX.

**Microkernel placement.** Userspace SGX driver with kernel capability for EPC management.

**References.** Costan & Devadas, *Intel SGX Explained*, IACR ePrint 2016/086; Van Bulck et al., *Foreshadow: Extracting the Keys to the Intel SGX Kingdom*, USENIX Security 2018 (cautionary).

---

#### D3. Real-time scheduling guarantees

**Description.** EDF and rate-monotonic policies layered on the SC mechanism (C5). Mixed-criticality support per Lyons & Heiser 2018.

**References.** Lyons & Heiser, *Scheduling-Context Capabilities*, EuroSys 2018; Burns & Davis, *Mixed Criticality Systems: A Review*, Univ. York TR (annual updates).

---

#### D4. Formal verification hooks

**Description.** Macro-emitted refinement annotations that allow the assembly to be checked against an abstract specification (Coq/Isabelle/Lean), in the lineage of seL4 / CertiKOS / Komodo / Serval.

**References.** Klein et al., *seL4: Formal Verification of an OS Kernel*, SOSP 2009; Gu et al., *CertiKOS*, OSDI 2016; Nelson et al., *Hyperkernel: Push-Button Verification of an OS Kernel*, SOSP 2017; Nelson et al., *Scaling Symbolic Evaluation for Automated Verification of Systems Code with Serval*, SOSP 2019.

---

#### D5. Hardware-accelerated FP-style runtime

**Description.** Persistent / immutable data structures (HAMTs, finger trees, RRB-vectors) with hot paths vectorized for AVX-512 (e.g., 16-wide gather/scatter for HAMT node lookup) and AMX where tile-shaped (e.g., matrix-like persistent structures).

**References.** Bagwell, *Ideal Hash Trees*, EPFL TR, 2001; Stucki, Bagwell, et al., *RRB Vector: A Practical General Purpose Immutable Sequence*, ICFP 2015; Intel AMX spec.

---

#### D6. AI/ML acceleration primitives

**Description.** First-class kernel and runtime support for AMX (TILECFG/TILEDATA), AVX-512 VNNI (BF16/INT8 matmul), and Intel DLB (Dynamic Load Balancer) as scheduling primitives.

**References.** Intel AMX Architecture Specification rev. 1.5 (2023); Intel® Dynamic Load Balancer (DLB) Programmer's Guide, rev. 2.x (2022).

---

#### D7. Attestation services

**Description.** Remote attestation server speaking IETF RATS (RFC 9334) architecture; quotes signed with hybrid PQ; verifier-side policy expressed in a small DSL.

**References.** RFC 9334 *Remote ATtestation procedureS (RATS) Architecture*, 2023; Coker et al., *Principles of Remote Attestation*, IJIS 2011.

---

#### D8. Advanced semantic-shell capabilities

**Description.** Datalog (or Soufflé-style stratified Datalog) queries over the typed namespace, audit log, capability graph, and live system metrics. Effectively, the OS becomes self-introspectable as a database.

**References.** Abiteboul, Hull, Vianu, *Foundations of Databases*, Addison-Wesley, 1995; Scholz et al., *On Fast Large-Scale Program Analysis in Datalog*, CC 2016 (Soufflé).

---

#### D9. Novel filesystem semantics

**Description.** Versioned / time-travel filesystem; graph-shaped (not strictly tree) semantics; semantic tagging integrated into name resolution.

**References.** Pike et al., *Plan 9 from Bell Labs*, USENIX 1995; Soules et al., *Metadata Efficiency in Versioning File Systems*, FAST 2003; Gifford et al., *Semantic File Systems*, SOSP 1991.

---

#### D10. DPU / SmartNIC offload

**Description.** Recognize and program data-plane offload to BlueField/IPU class devices.

**References.** Firestone et al., *Azure Accelerated Networking: SmartNICs in the Public Cloud*, NSDI 2018.

---

#### D11. Persistent-memory / CXL.mem

**Description.** Treat PMem and CXL-attached memory tiers as first-class NUMA-like domains with explicit capability typing (durability is a *type* on the memory capability).

**References.** Volos et al., *Mnemosyne: Lightweight Persistent Memory*, ASPLOS 2011; CXL Specification 3.1 (2023); Intel Optane PMem Programmer's Reference Manual (informative — historical).

---

#### D12. Disaggregated / far memory

**Description.** Pageable far memory as a userspace pager (cf. C13), driven by RDMA or CXL.

**References.** Aguilera et al., *Remote Regions: a Simple Abstraction for Remote Memory*, ATC 2018; Ruan et al., *AIFM: High-Performance, Application-Integrated Far Memory*, OSDI 2020.

---

#### D13. Replay / record debugging at IPC granularity

**Description.** Deterministic IPC ordering can be recorded (logically clocked) and replayed; powerful debugging primitive given the strict microkernel boundary.

**References.** O'Callahan et al., *Engineering Record and Replay for Deployability*, USENIX ATC 2017 (rr).

---

#### D14. Capability-based distributed extension

**Description.** Capabilities tunneled across PQ-secured network channels; cross-node IPC where local IPC is the model. Speculative but pillar-aligned.

**References.** Hand et al., *Are Virtual Machine Monitors Microkernels Done Right?*, HotOS 2005 (counterpoint); Anderson & Karger, *Capability-Based Distributed Systems*, prior-art lineage; Ousterhout et al., *The Case for RAMCloud*, CACM 2011 (network-locality framing).

---

#### D15. Energy-aware scheduling

**Description.** Per-task joule accounting via RAPL; scheduler policy can optimize for energy-delay product or absolute energy budgets.

**References.** Hähnel et al., 2012 (RAPL); Krishnapura et al., *Energy-Efficient Scheduling on Multicore Processors*, IEEE TPDS.

---

#### D16. Microarchitectural mitigations as policy capabilities

**Description.** STIBP, IBPB, eIBRS, L1D flush, MDS_CLEAR, etc. exposed as capabilities; userspace declares its threat model and pays the cost it chooses.

**References.** Kocher et al., *Spectre Attacks: Exploiting Speculative Execution*, IEEE S&P 2019; Lipp et al., *Meltdown: Reading Kernel Memory from User Space*, USENIX Security 2018; Intel SDM Vol. 3, "Speculative Execution Side Channels" appendix.

---

#### D17. TSX-NI as a scheduling resource

**Description.** RTM regions used opportunistically inside the kernel for short critical sections; fallback path always present. Note: TSX has had a turbulent security history; gate behind microarchitecture detection.

**References.** Intel SDM Vol. 1 ch. 16; Yoo et al., SC 2013; Intel TSX Async Abort (TAA) errata.

---

#### D18. In-network compute coordination

**Description.** OS-level awareness of P4-programmable switches/NICs for offloading select control-plane functions.

**References.** Bosshart et al., *P4: Programming Protocol-Independent Packet Processors*, ACM SIGCOMM CCR 2014; Sapio et al., *Scaling Distributed Machine Learning with In-Network Aggregation*, NSDI 2021.

---

## 6. Cross-Cutting Concerns

### 6.1 IPC mechanism candidates

The choice of IPC mechanism is the most consequential design decision for PaideiaOS. Below are the main candidates with their tradeoff profiles.

#### 6.1.1 Synchronous L4-style call/reply with capability transfer

- **Mechanics.** Sender blocks until a receiver accepts at an endpoint; the kernel performs a single context switch ("direct process switch") if the receiver is ready. Capability and small message register payloads transferred atomically.
- **Pros.** Famous for sub-microsecond latency (Liedtke 1993; Elphinstone & Heiser 2013). Easy to reason about; verified in seL4. Naturally avoids deep kernel queues.
- **Cons.** Inherently bilateral; multicast/anycast must be built atop. Cross-core synchronous IPC is more expensive (IPI + cache pull).
- **Deadlock posture.** Bilateral rendezvous can deadlock if cycles exist in the call graph. Mitigated by *partial order* on endpoint capabilities (statically enforced) and by timeouts (a controversial L4 feature, omitted in seL4).

#### 6.1.2 Asynchronous notification + capability-passing channel

- **Mechanics.** Notification objects are per-bit semaphores (badge-OR). Bulk data flows over shared memory regions whose endpoints are capabilities. Completion via notification.
- **Pros.** Multicore-friendly; producer-consumer pairs need no IPI. Composes naturally with run-to-completion userspace event loops.
- **Cons.** Without back-pressure, queues can grow without bound. Back-pressure requires the receiver to control the producer, which re-introduces synchronization.
- **Deadlock posture.** Easier to make deadlock-free in steady state (no waiting on peer state); harder to reason about *liveness* (starvation).

#### 6.1.3 Hybrid: synchronous endpoints + async notification + shared queues

- This is the modern seL4 MCS posture and Fuchsia's Zircon channels approach.
- We currently recommend this as the *default*, pending an open question (§7) on whether to additionally include a wait-free dataflow primitive.

**References (all of §6.1).**
- Liedtke, *Improving IPC by Kernel Design*, SOSP 1993.
- Elphinstone & Heiser, SOSP 2013.
- Klein et al., *Comprehensive Formal Verification of an OS Microkernel*, TOCS 2014.
- Google Fuchsia / Zircon documentation, https://fuchsia.dev (informative).
- Steinberg & Kauer, *NOVA: A Microhypervisor-Based Secure Virtualization Architecture*, EuroSys 2010 — async-heavy variant.

### 6.2 Deadlock-prevention strategies

| Strategy | Where applied | Notes |
|---|---|---|
| **Static endpoint ordering** | IPC graph | Per Dijkstra resource hierarchy. Enforced by build-time checker (E14). |
| **Lock-free data structures** | Per-CPU run queues, IPC queues | Treiber stacks, Michael-Scott queues; CMPXCHG16B for dual-word. |
| **Wait-free protocols** | Critical structures (capability lookup hot path) | Wait-freedom is stronger than lock-freedom; favored where feasible. |
| **Hierarchical locking** | Where locks unavoidable | With a kernel-checked total order. |
| **RCU** | Read-mostly tables (CSpace ID → address map) | Userspace QSBR-style variant. |
| **Hardware transactional memory (TSX-NI)** | Opportunistic fast path | With a fallback path always present. |
| **Priority inheritance / ceiling on SCs** | Real-time IPC | Per Lyons & Heiser 2018. |
| **Capability linearity** | IPC ownership transfer | Substructural type discipline at macro/ABI layer. |

**References.**
- Dijkstra, *Cooperating Sequential Processes*, 1965 (resource hierarchy).
- Herlihy, *Wait-Free Synchronization*, TOPLAS 1991.
- Michael & Scott, *Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms*, PODC 1996.

### 6.3 Multicore primitives

- **Per-CPU areas** via FSGSBASE.
- **MCS locks** as the default contended lock; **ticket locks** rejected (unfair under NUMA).
- **TLB-shootdown coalescing** via PCID generation counters.
- **Cluster-mode x2APIC** for IPI fan-out.
- **DLB (Dynamic Load Balancer)** as a kernel-mediated work-distribution capability (D6 overlap).
- **WAITPKG (UMWAIT/TPAUSE)** for fine-grained low-latency wait without monopolizing a core.

### 6.4 FP-style encoding in assembly

- **Calling conventions encode monadic effect signatures** via macro-emitted prologues that materialize the effect record on the stack and check linearity.
- **Closures** as a heap-allocated struct + indirect call through a CET-IBT-tagged dispatch slot.
- **Immutable values** carry a one-bit "frozen" tag in the high (canonical) bits of pointers; mutation attempts trap.
- **Linear capabilities** marked by macro discipline + build-time check (E14).
- **Algebraic effects** (handlers) compiled to delimited-continuation captures via a fixed stack-segment protocol.

**References.**
- Plotkin & Power, *Algebraic Operations and Generic Effects*, AAC 2003.
- Bauer & Pretnar, *An Effect System for Algebraic Effects and Handlers*, LMCS 2014.
- Morrisett et al., *From System F to Typed Assembly Language*, TOPLAS 1999.
- Wadler, *Linear Types Can Change the World!*, IFIP Working Conf., 1990.

---

## 7. Open Questions

The following decisions are blocking, in the sense that a future design document cannot be written without them being resolved. Listed in rough priority order.

1. **IPC primitive selection.** Synchronous-rendezvous-only (seL4-MCS style) vs. hybrid sync+async+queues (Zircon-style) vs. a novel wait-free dataflow primitive (research-grade). Affects every userspace server design and the deadlock-freedom proof obligation.

2. **Formal verification ambition level.** Three plausible postures: (a) "verification-friendly but not verified" — keep proofs out of the critical path; (b) "verified kernel, unverified userspace" — seL4 posture; (c) "verified kernel and verified IPC clients" — CertiKOS / Hyperkernel direction. Option (c) is multi-year; option (a) is a research debt we may regret.

3. **Assembler / macro substrate.** NASM, GAS, or a custom in-house assembler that natively understands the linearity / effect-typing discipline? A custom assembler is the most pillar-aligned but is itself a large engineering project.

4. **Filesystem strategy.** One new CoW filesystem from scratch (long timeline, fully pillar-aligned) vs. port an existing design (e.g., bcachefs algorithms reimplemented under the new ABI). Affects E17, D9, U11.

5. **AML / ACPI handling.** Reimplement an AML interpreter under the macro discipline (large) vs. port ACPICA into the userspace runtime with a sandboxing capability bubble (faster, pragmatic). Affects U1, U2, U12.

6. **GPU strategy.** Vendor-blob isolation (driver as a userspace process behind IOMMU; accept the binary) vs. open-source-only (significantly narrows hardware support but maximizes auditability).

7. **Linear-capability enforcement granularity.** Whole-program build-time check (E14) only, vs. additional run-time tag bits (consuming pointer bits or shadow memory). The latter costs space and complexity but covers dynamic capability flows.

8. **Real-time posture.** Soft real-time as a side-effect of the SC model, or first-class hard real-time guarantees with admission control and WCET tooling. Affects D3, scheduler design (C6).

9. **POSIX-compatibility layer.** Pillar 5 says no, but a *transitional* compatibility shim might accelerate bring-up. Decide: never, on-day-one as throwaway, or never-but-via-a-WASM/VM jail.

10. **Networking acceleration default.** IRQ-driven by default + opt-in poll mode, vs. poll-mode by default on a reserved core when core count ≥ N. Affects E7 and U9.

11. **Trusted root for PQ signing.** Use the TPM for storage of PQ private keys (TPM 2.0 PQ extensions are nascent — TODO: verify current TCG draft status) vs. a software root in a confidential-computing enclave (D1) vs. both.

12. **Pointer width / virtual address layout.** 48-bit (4-level paging) default with 57-bit (5-level) opt-in, vs. 57-bit by default. The latter forces canonical-address checks to assume 57 bits everywhere.

13. **Shell pipeline serialization.** In-process typed records (zero serialization between commands sharing a process) vs. always-serialized (Arrow/Cap'n Proto-like) for cross-host transparency. Affects E12, D8.

14. **Driver hot-reload semantics.** Hard restart of driver process on update vs. live state-handoff via capability snapshot. Affects E3, E11.

15. **Speculative-execution mitigation default policy.** Maximum mitigation, or "fast by default, mitigated by capability" (D16). Affects all userspace performance.

---

## 8. Bibliography (consolidated)

### 8.1 Books

- Abiteboul, Hull, Vianu. *Foundations of Databases*. Addison-Wesley, 1995.
- Feske. *Genode Operating System Framework — Foundations*. Genode Labs, 2023.
- Gregg, B. *BPF Performance Tools*. Addison-Wesley, 2019.
- Herlihy, M., and Shavit, N. *The Art of Multiprocessor Programming*, 2nd ed. Morgan Kaufmann, 2020.
- Parno, B., McCune, J., and Perrig, A. *Bootstrapping Trust in Modern Computers*. Springer, 2011.
- Walker, D. "Substructural Type Systems," in *Advanced Topics in Types and Programming Languages*, ed. Pierce. MIT Press, 2005.

### 8.2 Conference and journal papers (chronological-ish)

- Codd, E. F. "A Relational Model of Data for Large Shared Data Banks." *CACM* 13(6), 1970.
- Saltzer, J., and Schroeder, M. "The Protection of Information in Computer Systems." *Proc. IEEE* 63(9), 1975.
- Young, M., et al. "The Duality of Memory and Communication in the Implementation of a Multiprocessor Operating System." SOSP 1987.
- Pike, R. "Window Systems Should Be Transparent." USENIX, 1988.
- Wadler, P. "Comprehending Monads." LFP 1990.
- Wadler, P. "Linear Types Can Change the World!" IFIP WG 2.2, 1990.
- Bershad, B., et al. "Lightweight Remote Procedure Call." *TOCS* 8(1), 1990.
- Herlihy, M. "Wait-Free Synchronization." *TOPLAS* 13(1), 1991.
- Mellor-Crummey, J., and Scott, M. "Algorithms for Scalable Synchronization on Shared-Memory Multiprocessors." *TOCS* 9(1), 1991.
- Gifford, D. K., et al. "Semantic File Systems." SOSP 1991.
- Lampson, B., et al. "Authentication in Distributed Systems: Theory and Practice." *TOCS* 10(4), 1992.
- Liedtke, J. "Improving IPC by Kernel Design." SOSP 1993.
- Pike, R., et al. "Plan 9 from Bell Labs." USENIX, 1995.
- Liedtke, J. "On µ-Kernel Construction." SOSP 1995.
- Engler, D., Kaashoek, M. F., and O'Toole, J. "Exokernel: An Operating System Architecture for Application-Level Resource Management." SOSP 1995.
- Michael, M., and Scott, M. "Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms." PODC 1996.
- Härtig, H., et al. "The Performance of µ-Kernel-Based Systems." SOSP 1997.
- Necula, G. "Proof-Carrying Code." POPL 1997.
- Shapiro, J., Smith, J., and Farber, D. "EROS: A Fast Capability System." SOSP 1999.
- Morrisett, G., et al. "From System F to Typed Assembly Language." *TOPLAS* 21(3), 1999.
- Schneier, B., and Kelsey, J. "Secure Audit Logs to Support Computer Forensics." *ACM TISSEC*, 1999.
- Bonwick, J., and Adams, J. "Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources." USENIX ATC, 2001.
- Bagwell, P. "Ideal Hash Trees." EPFL TR, 2001.
- Bonwick, J., et al. "The Zettabyte File System." USENIX FAST, 2003.
- Plotkin, G., and Power, J. "Algebraic Operations and Generic Effects." *Applied Categorical Structures* 11, 2003.
- Soules, C., et al. "Metadata Efficiency in Versioning File Systems." FAST 2003.
- Swift, M., et al. "Improving the Reliability of Commodity Operating Systems." *TOCS* 23(1), 2005.
- Cantrill, B., Shapiro, M., and Leventhal, A. "Dynamic Instrumentation of Production Systems." USENIX ATC 2004.
- Leslie, B., et al. "User-Level Device Drivers: Achieved Performance." *JCST* 20(5), 2005.
- Hand, S., et al. "Are Virtual Machine Monitors Microkernels Done Right?" HotOS 2005.
- Feske, N., and Helmuth, C. "Design of the Bastei OS Architecture." TU Dresden, 2007.
- Boyd-Wickizer, S., et al. "Corey: An Operating System for Many Cores." OSDI 2008.
- Klein, G., et al. "seL4: Formal Verification of an OS Kernel." SOSP 2009.
- Baumann, A., et al. "The Multikernel: A New OS Architecture for Scalable Multicore Systems." SOSP 2009.
- Crosby, S., and Wallach, D. "Efficient Data Structures for Tamper-Evident Logging." USENIX Security 2009.
- Brandenburg, B., and Anderson, J. "On the Implementation of Global Real-Time Schedulers." RTSS 2009.
- Watson, R., et al. "Capsicum: practical capabilities for UNIX." USENIX Security 2010.
- Caulfield, A., et al. "Moneta: A High-Performance Storage Array Architecture." MICRO 2010.
- Chlipala, A. "A Verified Compiler for an Impure Functional Language." POPL 2010.
- Steinberg, U., and Kauer, B. "NOVA: A Microhypervisor-Based Secure Virtualization Architecture." EuroSys 2010.
- Volos, H., et al. "Mnemosyne: Lightweight Persistent Memory." ASPLOS 2011.
- Coker, G., et al. "Principles of Remote Attestation." *IJIS* 10(2), 2011.
- Hwang, A., et al. "Cosmic Rays Don't Strike Twice: Understanding the Nature of DRAM Errors." ASPLOS 2012.
- Hähnel, M., et al. "Measuring Energy Consumption for Short Code Paths Using RAPL." *SIGMETRICS PER* 40(3), 2012.
- Belay, A., et al. "Dune: Safe User-Level Access to Privileged CPU Features." OSDI 2012.
- Desnoyers, M., et al. "User-Level Implementations of Read-Copy Update." *IEEE TPDS* 23(2), 2012.
- Sewell, T., et al. "Translation Validation for a Verified OS Kernel." PLDI 2013.
- Murray, T., et al. "seL4: From General Purpose to a Proof of Information Flow Enforcement." IEEE S&P 2013.
- Lameter, C. "NUMA: An Overview." *ACM Queue* 11(7), 2013.
- Rodeh, O., et al. "BTRFS: The Linux B-tree Filesystem." *ACM TOS* 9(3), 2013.
- Elphinstone, K., and Heiser, G. "From L3 to seL4 — What Have We Learnt in 20 Years of L4 Microkernels?" SOSP 2013.
- Yoo, R., et al. "Performance Evaluation of Intel® Transactional Synchronization Extensions for HPC." SC 2013.
- Klein, G., et al. "Comprehensive Formal Verification of an OS Microkernel." *TOCS* 32(1), 2014.
- Belay, A., et al. "IX: A Protected Dataplane Operating System for High Throughput and Low Latency." OSDI 2014.
- Jeong, E. Y., et al. "mTCP: a Highly Scalable User-level TCP Stack for Multicore Systems." NSDI 2014.
- Lyons, A., et al. "Mixed-Criticality Support in a High-Assurance, General-Purpose Microkernel." WMC@RTSS 2014.
- Bauer, A., and Pretnar, M. "An Effect System for Algebraic Effects and Handlers." *LMCS* 10(4), 2014.
- Bosshart, P., et al. "P4: Programming Protocol-Independent Packet Processors." *ACM SIGCOMM CCR*, 2014.
- Müller, S. "CPU Time Jitter Based Non-Physical True Random Number Generator." BSI tech report, 2014.
- Watson, R., et al. "CHERI: A Hybrid Capability-System Architecture." IEEE S&P 2015.
- Stucki, N., Bagwell, P., et al. "RRB Vector: A Practical General Purpose Immutable Sequence." ICFP 2015.
- Lozi, J.-P., et al. "The Linux Scheduler: a Decade of Wasted Cores." EuroSys 2016.
- Gu, R., et al. "CertiKOS: An Extensible Architecture for Building Certified Concurrent OS Kernels." OSDI 2016.
- Stebila, D., and Mosca, M. "Post-Quantum Key Exchange for the Internet and the Open Quantum Safe Project." SAC 2016.
- Scholz, B., et al. "On Fast Large-Scale Program Analysis in Datalog." CC 2016.
- Costan, V., and Devadas, S. "Intel SGX Explained." IACR ePrint 2016/086.
- Burow, N., et al. "Control-Flow Integrity: Precision, Security, and Performance." *ACM CSUR*, 2017.
- Bernstein, D., and Lange, T. "Post-quantum cryptography." *Nature* 549, 2017.
- Yang, Z., et al. "SPDK: A Development Kit to Build High-Performance Storage Applications." IEEE Cloud, 2017.
- O'Callahan, R., et al. "Engineering Record and Replay for Deployability." USENIX ATC 2017.
- Nelson, L., et al. "Hyperkernel: Push-Button Verification of an OS Kernel." SOSP 2017.
- Bos, J., et al. "CRYSTALS-Kyber: a CCA-secure module-lattice-based KEM." EuroS&P 2018.
- Ducas, L., et al. "CRYSTALS-Dilithium: A Lattice-Based Digital Signature Scheme." *IACR TCHES* 2018.
- Aguilera, M., et al. "Remote Regions: a Simple Abstraction for Remote Memory." USENIX ATC 2018.
- Lyons, A., and Heiser, G. "Scheduling-Context Capabilities: A Principled, Light-Weight OS Mechanism for Managing Time." EuroSys 2018.
- Van Bulck, J., et al. "Foreshadow: Extracting the Keys to the Intel SGX Kingdom." USENIX Security 2018.
- Lipp, M., et al. "Meltdown: Reading Kernel Memory from User Space." USENIX Security 2018.
- Amit, N., and Wei, M. "The Design and Implementation of Hyperupcalls." USENIX ATC 2018.
- Firestone, D., et al. "Azure Accelerated Networking: SmartNICs in the Public Cloud." NSDI 2018.
- Bernstein, D., et al. "SPHINCS+: stateless hash-based signatures." EUROCRYPT 2019.
- Kocher, P., et al. "Spectre Attacks: Exploiting Speculative Execution." IEEE S&P 2019.
- Vahldiek-Oberwagner, A., et al. "ERIM: Secure, Efficient In-process Isolation with Protection Keys (MPK)." USENIX Security 2019.
- Antonioli, D., et al. "The KNOB is Broken: Exploiting Low Entropy in the Encryption Key Negotiation of Bluetooth BR/EDR." USENIX Security 2019.
- Watson, R., et al. "CheriABI: Enforcing Valid Pointer Provenance and Minimizing Pointer Privilege in the POSIX C Run-time." ASPLOS 2019.
- Marty, M., et al. "Snap: a Microkernel Approach to Host Networking." SOSP 2019.
- Nelson, L., et al. "Scaling Symbolic Evaluation for Automated Verification of Systems Code with Serval." SOSP 2019.
- Boos, K., et al. "Theseus: an Experimental Operating System for Modern Hardware." OSDI 2020.
- Aumasson, J.-P., et al. "BLAKE3: one function, fast everywhere." IACR ePrint 2020/067.
- Vanhoef, M., and Ronen, E. "Dragonblood: Analyzing the Dragonfly Handshake of WPA3 and EAP-pwd." IEEE S&P 2020.
- Ruan, Z., et al. "AIFM: High-Performance, Application-Integrated Far Memory." OSDI 2020.
- Lamb, C., and Zacchiroli, S. "Reproducible Builds: Increasing the Integrity of Software Supply Chains." *IEEE Software* 2021.
- Sapio, A., et al. "Scaling Distributed Machine Learning with In-Network Aggregation." NSDI 2021.
- Cheng, P.-C., et al. "Intel TDX Demystified: A Top-Down Approach." *ACM Computing Surveys* 56(9), 2024.

### 8.3 RFCs and standards

- RFC 4960 *Stream Control Transmission Protocol*, 2007.
- RFC 5905 *Network Time Protocol Version 4*, 2010.
- RFC 7858 *Specification for DNS over Transport Layer Security (TLS)*, 2016.
- RFC 8011 *Internet Printing Protocol/1.1: Model and Semantics*, 2017.
- RFC 8200 *Internet Protocol, Version 6 (IPv6) Specification*, 2017.
- RFC 8391 *XMSS: eXtended Merkle Signature Scheme*, 2018.
- RFC 8446 *The Transport Layer Security (TLS) Protocol Version 1.3*, 2018.
- RFC 8484 *DNS Queries over HTTPS (DoH)*, 2018.
- RFC 8554 *Leighton-Micali Hash-Based Signatures*, 2019.
- RFC 8915 *Network Time Security for the Network Time Protocol*, 2020.
- RFC 9000 *QUIC: A UDP-Based Multiplexed and Secure Transport*, 2021.
- RFC 9001 *Using TLS to Secure QUIC*, 2021.
- RFC 9002 *QUIC Loss Detection and Congestion Control*, 2021.
- RFC 9156 *DNS Query Name Minimisation to Improve Privacy*, 2021.
- RFC 9250 *DNS over Dedicated QUIC Connections*, 2022.
- RFC 9293 *Transmission Control Protocol (TCP)*, 2022.
- RFC 9334 *Remote ATtestation procedureS (RATS) Architecture*, 2023.
- RFC 9364 *DNS Security Extensions (DNSSEC)*, 2023.
- draft-ietf-tls-hybrid-design (active draft) — hybrid PQ key exchange in TLS.
- draft-ietf-ntp-roughtime (active draft) — Roughtime.
- NIST FIPS 203 *Module-Lattice-Based Key-Encapsulation Mechanism Standard*, 2024.
- NIST FIPS 204 *Module-Lattice-Based Digital Signature Standard*, 2024.
- NIST FIPS 205 *Stateless Hash-Based Digital Signature Standard*, 2024.
- NIST SP 800-90A Rev.1; SP 800-90B; SP 800-90C.
- UEFI Specification 2.10, 2022.
- ACPI Specification 6.5, 2022.
- PCI Express Base Specification 6.0, 2022.
- NVM Express Base Specification 2.0c, 2022.
- xHCI Specification 1.2, 2019.
- USB 3.2 Specification, 2017; USB4 Specification 2.0, 2022.
- IEEE 1588-2019 *Precision Time Protocol*.
- IEEE 802.11-2020; IEEE 802.11be draft.
- Bluetooth Core Specification 5.4, 2023.
- TCG TPM 2.0 Library Specification, Part 1, Rev. 1.59, 2019.
- TCG PC Client Platform Firmware Profile Specification, Rev. 1.05, 2021.
- TCG D-RTM Architecture Specification 1.0.0, 2013.
- Unicode Standard 16.0, 2024; UAX #9, #14, #15, #29, #31; UTS #10, #46.
- CXL Specification 3.1, 2023.

### 8.4 Vendor / platform documentation

- Intel® 64 and IA-32 Architectures Software Developer's Manual (SDM), Vols. 1, 2A/B/C/D, 3A/B/C/D, 4 — current revision.
- Intel® Trust Domain Extensions (Intel® TDX) Module Base Architecture Specification, rev. 1.5, 2023.
- Intel® Virtualization Technology for Directed I/O (VT-d) Architecture Specification, rev. 4.1, 2022.
- Intel® Advanced Matrix Extensions (AMX) Architecture Specification, rev. 1.5, 2023.
- Intel® Dynamic Load Balancer (DLB) Programmer's Guide.
- Intel® 5-Level Paging and 5-Level EPT White Paper, rev. 1.1, 2017.
- Intel® DRNG Software Implementation Guide, rev. 2.1, 2018.
- Intel TXT MLE Developer's Guide, rev. 017, 2017.

### 8.5 Marked TODO references (to verify before publication)

- Sklar, *PowerShell in Action*, 3rd ed., Manning, 2017 — informative.
- Nushell book (https://www.nushell.sh/book/) — informative.
- Pope & Vendrov, *systemd considered harmful: a contrasting design study* — verify locatable.
- Bcachefs principles of operation page (https://bcachefs.org) — verify current URL.
- TCG draft on PQ extensions to TPM 2.0 — verify current status with TCG working groups.

---

*End of document.*
