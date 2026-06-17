# PaideiaOS — Foundational Decisions (from Open-Questions Questionnaire)

**Date:** 2026-06-17
**Source:** Questionnaire derived from `00-feature-inventory.md` §7 (Open Questions), answered by Santiago Núñez-Corrales.
**Status:** Authoritative until amended. Subsequent design documents must conform or explicitly request revision.

---

## 1. Decision summary

| # | Question | Decision |
|---|---|---|
| Q1 | IPC primitive | **Novel wait-free dataflow primitive** (research-grade) |
| Q2 | Formal-verification ambition | **Verification-friendly, not mechanized** |
| Q3 | Assembler / macro substrate | **Custom in-house assembler** |
| Q4 | Filesystem | **New CoW filesystem from scratch** |
| Q5 | ACPI / AML | **Port ACPICA into a sandboxed userspace capability bubble** |
| Q6 | GPU | **Open-source-only for now; blob path designed-in as a future capability** |
| Q7 | Linear-capability enforcement | **Both: build-time static check + LAM-backed runtime tag bits** |
| Q8 | Real-time posture | **Soft real-time via the scheduling-context model** |
| Q9 | POSIX compatibility | **Never; external software runs in a WASM/VM jail** |
| Q10 | Networking acceleration default | **Poll-mode on a reserved core when core count ≥ N; IRQ otherwise** |
| Q11 | Trusted root for PQ signing | **TPM 2.0 for root keys + TDX/SGX enclave for high-volume signing** |
| Q12 | Virtual address layout | **48-bit (4-level) default; 57-bit (5-level) opt-in per address space** |
| Q13 | Shell pipeline serialization | **Hybrid — shared schema, in-process by-reference, serialized at host/trust boundaries** |
| Q14 | Driver hot-reload semantics | **Hard restart default; capability-snapshot live handoff as opt-in protocol** |
| Q15 | Speculative-execution mitigation default | **Maximum mitigation by default; relaxation requires an explicit capability** |

---

## 2. Rationale capture (per decision)

### Q1 — Novel wait-free dataflow IPC primitive
Pillar-aligned: multicore-first, FP-discipline-natural (dataflow composes as applicative), naturally deadlock-free when graphs are acyclic. Cost: no production prior art; debugging tooling must be built; correctness proofs are open work. **Carries a research-publication obligation.**

### Q2 — Verification-friendly, not mechanized
Design every kernel and IPC interface as if it would be verified (typed effects, linear capabilities, pure-function specs in `design/`) but do not commit to Isabelle/HOL or Coq/Rocq proofs. Move-fast posture.

### Q3 — Custom in-house assembler
The macro substrate natively understands linearity, effect types, capability flow, and monadic composition. Pillar-maximal. **Critical-path prerequisite** before kernel code can land.

### Q4 — New CoW filesystem from scratch
On-disk format natively encodes capabilities, provenance, and post-quantum signatures. No legacy carryover. Long timeline accepted.

### Q5 — ACPICA in a userspace capability bubble
Pragmatic: the AML vendor-quirk graveyard is a tar pit. Microkernel pillar preserved (it's userspace). C runtime shim accepted as a localized impurity.

### Q6 — Open-source GPU drivers only (blob path designed-in)
Intel iGPU, AMDGPU, Nouveau. NVIDIA modern is degraded. Framework (E3) must be capable of hosting an isolated blob driver later without redesign.

### Q7 — Static + LAM-backed runtime tags
Build-time check handles intra-program linearity via the custom assembler's type system. LAM (Linear Address Masking) provides 15 free high-bit tags for IPC-crossing capabilities at 4-level paging.

### Q8 — Soft real-time via SC model
Scheduling-context budgets give bounded latency for cooperating threads — enough for audio, video, network, UI. No WCET tooling commitment.

### Q9 — POSIX never; WASM/VM jail for external software
Native API is clean-slate. WASI runtime or lightweight VM hosts external software at a capability membrane. Pillar 5 intact.

### Q10 — Hybrid poll-mode / IRQ networking
Reserved core for poll-mode when ≥ N cores (N TBD; suggest N=8); IRQ-driven on small/laptop systems. Energy-aware fallback.

### Q11 — Hybrid PQ-signing trust root
TPM 2.0 holds root attestation keys; high-volume PQ signing runs inside a TDX VM (or SGX fallback) attested at boot by the TPM. Defense in depth.

### Q12 — 48-bit default, 57-bit opt-in
Preserves full LAM tag space for capability-heavy address spaces. 5-level paging available per address space for very large workloads (CXL.mem, in-memory DB).

### Q13 — Hybrid pipeline data model
Shared schema between in-process and on-wire forms. Local hops pass by capability/handle through shared-memory rings on the novel IPC primitive; host/trust boundaries serialize via Arrow or Cap'n Proto.

### Q14 — Hard restart default, opt-in live handoff
Most drivers hard-restart. Drivers with continuity needs (NIC, NVMe, audio) implement an explicit `serialize-live-state-to-capability` protocol.

### Q15 — Max mitigations default, capability-gated relax
Userspace runs with full Spectre/Meltdown-family mitigations enabled by default. A `relax-mitigations` capability allows opt-out for single-tenant trusted workloads. Auditable.

---

## 3. Cross-decision tensions to track

These are real engineering tensions created by the combination of decisions. They are not decisions to revisit; they are constraints to honor.

1. **Q1 + Q2: Unproven deadlock-freedom.** The novel IPC primitive's main selling point is correctness, but Q2 declined mechanized proofs. **Mitigation:** `design/ipc/` must contain a *paper-grade* informal proof of deadlock-freedom with property-based testing harnesses. Treat the proof as a public artifact even if not mechanized.

2. **Q3 + Q2: Custom assembler on the critical path.** Q3 commits to a 1–2 person-year prerequisite project, but Q2's "move fast" posture is in tension with that runway. **Mitigation:** Bootstrap on NASM for the very first kernel-development sprints (boot path, basic memory, exception handlers) while the custom assembler is being built in parallel; migrate code as the assembler comes online. Document the bootstrap path in `design/toolchain/`.

3. **Q7 + Q12: LAM availability across i7 generations.** LAM ships on Sapphire Rapids+ (server) and Meteor Lake+ (client). Older i7 (Skylake–Raptor Lake) lacks hardware LAM and must use software masking on every capability dereference. **Mitigation:** `design/capabilities/` must specify the software-LAM fallback and the runtime branch (CPUID-based) that selects between hardware and software paths. Decide the minimum supported i7 generation; cite Intel SDM Vol. 3 §X (TODO: verify section number for LAM in current SDM).

4. **Q11 + Intel hardware reality.** TDX is server-only (Sapphire Rapids+, Emerald Rapids, Granite Rapids). SGX is **deprecated on client CPUs** since Ice Lake / 11th-gen. Targeting "Intel i7 family broadly" leaves client systems without a hardware enclave path. **Mitigation:** `design/security/pq-trust-root.md` must define a software-enclave fallback (e.g., a verified-by-construction signing service in an IOMMU-isolated userspace process attested by the TPM) for client hardware lacking TDX/SGX. Acknowledge that client systems get weaker isolation guarantees than server.

5. **Q1 + Q14: State-handoff on a wait-free IPC primitive.** Live state-handoff requires the new driver to be a *receiver* of a capability snapshot from the old driver while in-flight messages are still draining. The wait-free dataflow primitive must define handoff semantics: are queue entries forwarded? drained? rerouted? **Mitigation:** specify handoff in the IPC primitive's design, not as a driver-framework afterthought. `design/ipc/handoff.md`.

6. **Q4 + Q11: PQ-signed on-disk format.** Q4 wants PQ signatures baked into the on-disk format. ML-DSA signatures are 2.4–4.6 KB; SLH-DSA can reach 30+ KB. Per-block signing is infeasible; per-extent or per-snapshot signing is the realistic scope. **Mitigation:** `design/filesystem/integrity.md` must lay out the granularity decision before implementation begins.

7. **Q10 + Q15: Reserved-core poll-loop and mitigations.** A core dedicated to poll-mode networking is a long-running kernel-domain context with frequent userspace transitions. Max mitigations make those transitions expensive. **Mitigation:** the reserved poll-core may need a `relax-mitigations` capability scoped to that core only; document the implications in `design/network/poll-mode.md`.

---

## 4. Implied next-step design documents

The decisions above unlock (and require) the following design documents, in roughly this order:

1. `design/toolchain/custom-assembler.md` — spec for the linearity-aware assembler; NASM bootstrap plan.
2. `design/ipc/wait-free-dataflow.md` — primitive semantics, deadlock-freedom argument, scheduling interaction, handoff protocol.
3. `design/capabilities/linearity-and-tags.md` — static check + LAM strategy + software-LAM fallback.
4. `design/security/pq-trust-root.md` — TPM + TDX/SGX/software-enclave architecture; client-vs-server posture.
5. `design/kernel/memory-model.md` — paging modes, address layout, per-AS 4/5-level selection.
6. `design/kernel/scheduler.md` — SC-based scheduler, reserved-core policy, mitigation interaction.
7. `design/filesystem/cow-design.md` — on-disk format, PQ-signing granularity, integrity-check scheme.
8. `design/acpi/acpica-bubble.md` — userspace ACPICA isolation; capability surface; C-runtime shim scope.
9. `design/drivers/framework.md` — hierarchical driver model; hard-restart-and-handoff lifecycle; blob-path future hooks.
10. `design/network/stack.md` — modern OSI stack; poll-mode/IRQ hybrid; PQ TLS integration.
11. `design/terminal/semantic-shell.md` — typed records, in-process by-reference + boundary serialization; Unicode model.
12. `design/runtime/wasm-vm-jail.md` — POSIX-software hosting model; capability membrane.

---

## 5. Items still open

The questionnaire resolved §7's 15 questions, but a handful of downstream parameters were deferred:

- **N for poll-mode threshold (Q10).** Suggest N=8; needs validation against energy budget on representative laptops.
- **Minimum supported i7 generation (Q11/Q7/Q12 interaction).** Decision needed before LAM/TDX/SGX/5-level fallbacks can be fully designed.
- **PQ signature scheme selection (Q11/Q4).** ML-DSA-{44,65,87} vs. SLH-DSA vs. hybrid. Affects key sizes and on-disk format budgets.
- **Verified-equivalent informal-proof tooling (Q1/Q2).** Property-based testing framework choice; model-checker (TLA+, Alloy, P) for the IPC primitive.
- **Custom-assembler implementation language.** Itself written in assembly? In a verified host language? Bootstrap decision affects timeline.

These should be tracked as TODO items in their corresponding `design/` documents as they are drafted.
