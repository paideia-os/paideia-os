# PaideiaOS — Toolchain Milestones (Custom Assembler)

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** A realistic milestone plan for the custom assembler (`paideia-as`) under a solo-developer team-size assumption. Addresses open issue AS1 from `toolchain/custom-assembler.md`. Establishes phase boundaries, success criteria, risk register, scope-cut priorities, and decision gates that downstream toolchain docs can size against.

**Hard inputs (do not relitigate):**
- `design/toolchain/custom-assembler.md` — the assembler's design (10 binding choices: novel syntax, full substructural lattice, algebraic effects, typed elaborator reflection, multi-pass IR, custom calling convention, ML functors, strict `unsafe` blocks, opt-in optimization passes, SARIF+LSP errors).
- `design/02-development-environment.md` §8 — the three-phase bootstrap plan (NASM → coexistence → paideia-as canonical) with capability-driven phase transitions.
- `design/infrastructure/github-org-and-repos.md` — the assembler lives in **two separate repos**: `paideia-as` (Rust, Linux dev hosts; replaces the original OCaml plan) and `paideia-as-native` (PaideiaOS-native; phase 3+).
- The user's 2026-06-17 decision: implementation language is **Rust** for the Linux host-side assembler (deviation from `custom-assembler.md` §8.3 OCaml; INFRA-O7 records the pending revision).

---

## 0. Decisions summary

### 0.1 Team-size assumption (MS-Q1)

**Solo developer (one full-time-equivalent person), with potential occasional collaborators in later phases.** All calendar estimates below derive from this assumption.

### 0.2 Phase structure (inherited)

| Phase | Description | Assembler in use |
|---|---|---|
| **Phase 0** | Bootstrap-the-bootstrap: design corpus complete, GitHub presence established, repo skeletons ready. | None. |
| **Phase 1** | NASM-only kernel bring-up: boot path, early memory, exception handlers, atomic ABI, per-CPU/IPI. Meanwhile, the Rust-based `paideia-as` (the assembler implementation) is begun in parallel. | NASM in PaideiaOS source; `paideia-as` itself under development in its own repo. |
| **Phase 2** | `paideia-as` reaches minimum viability and enters the PaideiaOS build; coexistence with NASM as subsystems migrate (capability system, IPC primitive, scheduler first). | NASM + `paideia-as` (both). |
| **Phase 3** | `paideia-as` is the canonical assembler; NASM is retired from active use. `paideia-as-native` (self-hosted, written in paideia-as) is begun. | `paideia-as`. |
| **Phase 4** | `paideia-as-native` reaches viability and supersedes `paideia-as` for on-PaideiaOS builds. | `paideia-as-native` (the canonical PaideiaOS toolchain). |

### 0.3 Calendar targets (solo developer)

| Phase transition | Calendar target | Cumulative wall-clock |
|---|---|---|
| Phase 0 → 1 | 2026-09-01 (Q3 2026) | 0–3 months |
| Phase 1 → 2 | 2027-09-01 (Q3 2027) | 12–15 months |
| Phase 2 → 3 | 2029-06-01 (Q2 2029) | 33–36 months |
| Phase 3 → 4 | 2031-06-01 (Q2 2031) | 57–60 months |

Phase 2 minimum-viable is therefore ~21–24 months from project kickoff (2026-06); phase 3 (paideia-as canonical) at ~36 months; phase 4 (native self-hosted) at ~60 months. **A 5-year horizon for a complete solo project.**

These dates are honest; aggressive cuts could compress, but the planning anchor is "what is realistic, not what is optimistic". See §6 for the scope-cut priority that would compress this.

---

## 1. Phase 0 — Bootstrap-the-bootstrap (now → Q3 2026)

### 1.1 Goal

Establish the project's external face: GitHub presence, repo structure, basic CI, license, contributor guidance.

### 1.2 Deliverables

- [ ] `paideia-os/paideia-os` GitHub repo created (per infrastructure plan §9).
- [ ] `paideia-os/paideia-as` GitHub repo created (Rust workspace skeleton).
- [ ] CI configured: GitHub Actions on both repos.
- [ ] LICENSE selected and applied.
- [ ] `CONTRIBUTING.md` written (per dev-env §12.1).
- [ ] Branch protection on `main`.
- [ ] Initial Nix flake for the monorepo (per dev-env §7.1).
- [ ] The complete tier-1 design corpus (already done as of 2026-06-17).

### 1.3 Success criteria

- A new contributor can `git clone` either repo and read the design corpus.
- A new contributor can run `./tools/dev/up` and have a working dev environment.
- The GitHub presence is consistent with the planning doc.

### 1.4 Risk

- License selection has implications for long-term contribution patterns; low immediate risk but irreversible.
- Org admin actions are blocking; user must execute manually.

---

## 2. Phase 1 — NASM bootstrap + Rust paideia-as begins (Q4 2026 → Q3 2027)

### 2.1 Goal

Reach a bootable kernel using NASM-built code; meanwhile, build the Rust-based `paideia-as` in parallel toward minimum viability.

### 2.2 PaideiaOS-side deliverables (NASM track)

- [ ] UEFI loader (`paideia-loader.efi`) boots under OVMF/QEMU.
- [ ] Measured-boot PCR extension to TPM (swtpm).
- [ ] Physical memory manager (NUMA-aware, per MEM-Q3).
- [ ] Initial virtual memory: per-CPU NUMA-local direct map (per MEM-Q1).
- [ ] Critical-structures region established at fixed VA.
- [ ] IDT + exception handlers (C8/C12).
- [ ] x2APIC + per-CPU areas (C18).
- [ ] TSC-deadline timer + scheduler refill wheel (basic).
- [ ] Fixed-priority preemptive scheduler (SCH-Q1, simplified — no work stealing yet, no SC donation, no idle hierarchy).
- [ ] Atomic ABI prototype (C14): LOCK / CMPXCHG16B / paused spin.
- [ ] In-kernel logging ring (C16).
- [ ] RDSEED/RDRAND entropy (C15).
- [ ] Hardcoded MADT + MCFG + FADT parser (per ACPI-D8 phase-1 NASM parser, ~2000 LOC).
- [ ] Minimal NVMe driver (NASM, monolithic — enough to read the boot loader from disk).
- [ ] Initial root task spawning.
- [ ] Network stack stub: virtio-net IRQ-driven; loopback + ping reply (no real protocol stack).
- [ ] First-light "hello world" running in a root-task process.

### 2.3 paideia-as-side deliverables (Rust track)

- [ ] `paideia-as` Cargo workspace structure: crates for lexer, parser, elaborator, IR, emitter, LSP.
- [ ] Parser for the novel surface syntax (per `custom-assembler.md` §2.2).
- [ ] Surface AST.
- [ ] Smoke-test elaboration: a trivial source file can be parsed and emit a placeholder.
- [ ] Substructural type checker (ordered/linear/affine/unrestricted) skeleton.
- [ ] Algebraic-effect inference skeleton.
- [ ] Restricted macro form (pattern-based only; full typed elaborator reflection deferred to phase 2 per `custom-assembler.md` §14.5).
- [ ] ELF64 emitter (no PE/COFF yet; the UEFI loader stays NASM-built in phase 1).
- [ ] DWARF emission (basic `.debug_info` + `.debug_line`).
- [ ] Basic structured diagnostics (text + SARIF; LSP deferred).
- [ ] Linearity-regression test harness with initial accept/reject corpus.

### 2.4 Success criteria

- PaideiaOS boots under QEMU OVMF, reaches the root task, prints to virtio-serial.
- `paideia-as` builds and assembles a trivial kernel module that the NASM-built kernel can link against.
- The phase-1 → phase-2 transition gates from `custom-assembler.md` §8.4 are evaluable.

### 2.5 What is *explicitly out of phase 1*

- The novel wait-free IPC primitive (Q1) — phase 2.
- The capability system with derivation trees (CAP-Q7) — phase 2.
- Session-typed channels — phase 2 (requires functor maturity).
- The CoW filesystem (Q4 / B-epsilon + HAMT) — phase 2 (the disk write path uses a write-once log for phase 1).
- ACPICA bubble — phase 2.
- TLS / network protocols beyond ping — phase 2.
- The semantic shell — phase 2 (phase 1 uses a minimal command-line for diagnostics).
- The WASM/VM jail — phase 2.
- The full PQ trust root — phase 2 (phase 1 uses classical signatures for development convenience; release signing is not yet in use).

### 2.6 Risks

| Risk | Mitigation |
|---|---|
| The Rust learning curve (if not already proficient) slows assembler progress | Start with simple, well-understood components (lexer, parser); accept that elaborator + type system will dominate timeline |
| QEMU + OVMF + swtpm + custom code interactions produce hard-to-debug states | Heavy reliance on `-icount rr` (per dev-env §3.4); replay-debug from the start |
| Hardcoded ACPI parser is buggy for vendor-specific tables | Phase 1 only targets QEMU virtual hardware (well-behaved); real hardware quirks are phase 2's ACPICA problem |
| Solo motivation across 12 months | Visible milestones every ~6 weeks; the design corpus is a sustainable reference |

---

## 3. Phase 2 — `paideia-as` coexistence and minimum viability (Q4 2027 → Q2 2029)

### 3.1 Goal

`paideia-as` reaches minimum-viable; subsystems requiring substructural discipline migrate from NASM to `paideia-as`. PaideiaOS reaches an interesting-to-use state.

### 3.2 paideia-as-side deliverables (advancing)

- [ ] Typed elaborator reflection (full Q-A4 power).
- [ ] Full algebraic effects with handlers (Q-A3).
- [ ] ML-style modules with functors (Q-A7).
- [ ] PE/COFF emitter (for the UEFI loader, replacing NASM-built path).
- [ ] LSP server (Q-A10 phase-2 deliverable).
- [ ] Opt-in optimization passes: peephole, instruction scheduling, macro-fusion-aware emission (the first three from `custom-assembler.md` §6.4 catalog).
- [ ] Cross-build smoke test (per dev-env §8.2) — module built by both NASM and paideia-as produce equivalent output.

### 3.3 PaideiaOS-side deliverables (subsystem migrations)

In dependency order (per `custom-assembler.md` §14.2):

- [ ] Capability system (C4) — kind-tagged variants, derivation tree, retype, revoke (CAP-Q1–CAP-Q10).
- [ ] Wait-free dataflow IPC primitive (Q1) — SPSC algorithm, slot-cap economy, session types.
- [ ] Functor-typed channels (per IPC-Q5).
- [ ] Scheduler upgrade: work stealing, SC donation, tiered idle, mitigations optimization (SCH-Q3, Q6, Q7, Q10).
- [ ] Memory model: page-table-as-capability, CoW from substructural sharing, MMIO/PMem derived kinds (MEM-Q2, MEM-Q6, MEM-Q7).
- [ ] CoW filesystem (Q4) — B-epsilon spine, HAMT directories, Merkle DAG, per-transaction PQ signing (a multi-month subproject in itself).
- [ ] ACPICA bubble (Q5) — wasmtime/C-runtime shim, OSL bridge, capability mediation.
- [ ] Driver framework: PCIe enumerator, NVMe driver, virtio-net driver, USB xHCI driver (Q14 lifecycle FSM).
- [ ] Network stack: IPv6 + IPv4 + TCP + UDP, IRQ-driven first, BBRv3, hybrid-KEM TLS server, DNS resolver, NTS client.
- [ ] PQ trust root: hybrid Ed25519 + ML-DSA-65 signing, software enclave per PQ-Q5.
- [ ] Semantic shell: typed pipelines + Datalog + lambda, ANSI rendering first, native Unicode.
- [ ] WASM jail (foundation only — wasmtime port + WASI Preview 1).
- [ ] Audit log subsystem (E19).

### 3.4 Success criteria

- Boot to semantic shell.
- Interactive shell session with a few useful commands.
- TLS-encrypted network connection out to the world via hybrid KEM.
- A foreign WASI command (e.g., a WASI-compiled `curl`) runs in the WASM jail.
- A user can write a `.pds` script and run it.
- The CoW filesystem stores files persistently across reboots.
- The bare-metal CI lane (single hardware runner) passes the integration suite.

### 3.5 Risks

| Risk | Mitigation |
|---|---|
| The novel wait-free IPC primitive correctness (Q1/Q2) — the deadlock-freedom claim's informal proof | TLA+ spec is a parallel deliverable; property-based testing with adversarial schedules; informal proof published with the primitive's first stable release |
| B-epsilon tree complexity exceeds estimate | The phase-2 FS is the minimum-viable extent of B-epsilon; phase 3 reaches maturity; phase 1 used a write-once log as a safety net (the user always has a path to read previous data) |
| Cross-system coordination (capability system + IPC + scheduler + memory) becomes unwieldy | Strict dependency order in §3.3; one subsystem at a time; integration tests gate each subsystem entry |
| The Rust paideia-as cannot keep up with PaideiaOS subsystems' needs | Defer NASM-on-PaideiaOS retirement to phase 3; subsystems blocking on paideia-as features get NASM workarounds with explicit migration tasks |
| 18-month solo-developer marathon | Quarterly milestones; "ship something" small releases every 3 months even if internal |

### 3.6 What is *explicitly out of phase 2*

- Multi-NIC bonding, VLAN (deferred to phase 3+).
- WireGuard-style overlay (deferred).
- Hardware GPU drivers (Intel iGPU is the eventual phase 3+ deliverable; phase 2 ships virtio-gpu only).
- Multi-device FS pools.
- WASI Preview 2 + component model (Preview 1 only in phase 2).
- VM jail mode (WASM only in phase 2; VM mode is phase 3+).
- Confidential computing (D1/D2).
- Real-time hard guarantees (D3) — phase 4+ if ever.
- Distributed capabilities (D14).
- D8 advanced semantic-shell features (history-as-Datalog, semantic search).

---

## 4. Phase 3 — `paideia-as` canonical + `paideia-as-native` begins (Q3 2029 → Q2 2031)

### 4.1 Goal

`paideia-as` is the only assembler in the PaideiaOS build; NASM is retired. The PaideiaOS-native self-hosted assembler (`paideia-as-native`) begins development inside PaideiaOS itself.

### 4.2 paideia-as-side deliverables (refinement)

- [ ] DDC (per dev-env §7.5) passes on every release.
- [ ] Optimization pass catalog expanded (the remaining items from `custom-assembler.md` §6.4: DSE, REX/EVEX tightening, loop unrolling, branch hints, alignment, constant pooling, tail-call).
- [ ] Editor integration for major editors (VS Code, Helix, Emacs).
- [ ] LSP-driven incremental compilation for fast feedback.

### 4.3 PaideiaOS-side deliverables (advancing toward production)

- [ ] WASI Preview 2 + component model in WASM jail.
- [ ] VM jail mode (custom thin VMM).
- [ ] Intel iGPU driver (open-source per Q6).
- [ ] Multi-device FS pool (mirror, RAID-Z-equivalent).
- [ ] Multi-NIC bonding + VLAN.
- [ ] WireGuard-style overlay.
- [ ] Kitty graphics protocol in the semantic shell.
- [ ] Tag attributes and cross-references in the FS graph.
- [ ] Snapshot diff/rollback.
- [ ] Audio class driver + USB audio device support.
- [ ] HID class driver.
- [ ] D15 energy-aware scheduling hooks active.

### 4.4 paideia-as-native deliverables

- [ ] `paideia-as-native` repo created (per infrastructure plan §2.2).
- [ ] Self-hosting bootstrap: phase 1 of `paideia-as-native` is a translation of `paideia-as`'s key components from Rust to paideia-as.
- [ ] First paideia-as-native build of a trivial PaideiaOS module.

### 4.5 Success criteria

- PaideiaOS is "usable" as a daily research tool for the developer.
- Full bare-metal CI matrix exercised regularly.
- First public release (v0.1.0).
- `paideia-as-native` builds at least one PaideiaOS module that the `paideia-as`-built kernel can link.

### 4.6 Risks

| Risk | Mitigation |
|---|---|
| The 60-month wall-clock is enormous solo | Accept that phase 3 may slip; the user's research interest is the motivation |
| Public release brings ecosystem responsibilities (bug reports, security disclosures, governance) | Keep the project private through phase 2; public release is itself a phase-3 decision |
| Self-hosted assembler bootstrap chain | DDC is the safety check; the original Rust `paideia-as` remains as a "known good" reference |

---

## 5. Phase 4 — `paideia-as-native` canonical (Q3 2031 → ?)

### 5.1 Goal

`paideia-as-native` reaches feature parity with `paideia-as`; PaideiaOS becomes truly self-hosted.

### 5.2 Deliverables

- [ ] Every paideia-as feature is present in `paideia-as-native`.
- [ ] On-PaideiaOS builds use `paideia-as-native` exclusively.
- [ ] The `paideia-as` (Rust) repo continues as the cross-host (Linux-dev) toolchain for contributors who develop on Linux but target PaideiaOS.
- [ ] DDC runs cross-substrate: `paideia-as` (Rust) and `paideia-as-native` (paideia-as) produce bit-identical PaideiaOS binaries.

### 5.3 Open

Phase 4 has no calendar target. Reaching it requires phase 3 to succeed; phase 3 success is itself ambitious.

---

## 6. Scope-cut priority (under pressure)

If the schedule slips, the following are cut **in this order** (last cut is the most pillar-load-bearing, most preserved):

| Order | Cut category | Reasoning |
|---|---|---|
| **1st** | Aspirational features that are research differentiators but not required for daily use | D-features (Tier 4): TDX, RT scheduling, formal verification hooks, ML primitives, attestation, novel FS semantics, distributed capabilities. |
| **2nd** | Phase 3+ features that improve quality of life but are not minimum-viable | Kitty graphics protocol; bonding/VLAN; advanced shell features; hardware GPU drivers; multi-device FS pools. |
| **3rd** | Optimization passes in `paideia-as` beyond the initial three | The basic peephole + scheduling + macro-fusion-aware emission carries the project; loop unrolling and the rest are luxury. |
| **4th** | Some operational tier signatures (run on classical until PQ migration is complete) | The PQ infrastructure is significant; classical signatures unblock the rest. |
| **5th** | LSP server (defer to phase 3+) | The text-based diagnostics are sufficient for solo development. |
| **6th** | The semantic shell's Datalog sub-language (ship typed pipelines + lambda only) | Datalog is the differentiator but typed pipelines are the daily-use core. |
| **7th** | The CoW filesystem's HAMT directories (substitute B-epsilon for directories too) | One data structure is faster than two; HAMT was an optimization. |
| **8th** | The CoW filesystem's B-epsilon trees (substitute simpler CoW B-tree) | At this point the project is admitting that bcachefs-lineage was the right call. |

What is **never cut**: the substructural lattice + algebraic effects + capability discipline + IPC primitive correctness + PQ defense in depth. These are the project's spine; cutting any of them invalidates the rest.

---

## 7. Decision gates

| Gate | Question | Trigger |
|---|---|---|
| G1 | Phase 0 complete? | All §1.2 boxes checked. |
| G2 | Phase 1 → 2 ready? | Phase 1 §2.3 + §2.4 + the §8.4 criteria from custom-assembler.md. |
| G3 | Phase 2 minimum-viable? | Phase 2 §3.3 critical-path subsystems online; bare-metal CI passes. |
| G4 | Phase 2 → 3 ready? | Cross-build smoke test passes consistently; `paideia-as` covers every PaideiaOS need; the §8.4 phase 2→3 criteria from custom-assembler.md. |
| G5 | Phase 3 → 4 ready? | `paideia-as-native` builds a trivial module; DDC works cross-substrate. |
| G6 | Public release v0.1.0? | Phase 3 milestone; license + governance ready; user explicitly decides to go public. |
| G7 | Phase 4 reached? | `paideia-as-native` is feature-complete and replaces `paideia-as` for on-PaideiaOS builds. |

Each gate is a checklist + a user decision. None can be reached by drift; each requires explicit affirmation.

---

## 8. Sustainability for solo development

A 5-year solo project is unusual. Sustainability considerations:

### 8.1 Health

- Sustainable pace: target ~6 productive hours/day, not 12. Burnout ends the project.
- Visible milestones every 4–6 weeks. Even small ones.
- Public design corpus is itself a milestone — the work is real even before code lands.

### 8.2 Motivation

- The research-grade pillars are the *interest* — implement the novel pieces (wait-free IPC, B-epsilon FS, custom assembler) when motivation is high.
- The pragmatic pieces (NASM phase-1 parser, ACPICA bubble, wasmtime port) when motivation is normal.

### 8.3 External visibility

- Optional: publish design corpus publicly during phase 2 to attract collaborators.
- Optional: write up the wait-free IPC primitive as a research paper.
- Optional: present at a research venue.

### 8.4 Contingency

- If the project must pause: the design corpus + the GitHub repos are the snapshot.
- Resumption from a paused state should be possible from the design corpus alone.

---

## 9. Open issues

| ID | Issue |
|---|---|
| MS-O1 | License decision (per infrastructure plan INFRA-O2) — affects whether public release is even possible. |
| MS-O2 | Whether to publicize the design corpus during phase 1 or wait until phase 2. |
| MS-O3 | The exact phase 0 completion target — when does the user authorize the GitHub presence creation? |
| MS-O4 | Whether to write the wait-free IPC primitive as a research paper independent of the OS — could accelerate external validation. |
| MS-O5 | The "first interesting collaborator" recruitment plan — what would make someone want to join this project? |
| MS-O6 | The pace of design-doc revision — as implementation reveals issues, the design corpus needs updates. Define a revision cadence. |
| MS-O7 | INFRA-O7 follow-up: when does `custom-assembler.md` §8.3 get revised to reflect Rust instead of OCaml? Suggested: when phase 1 actively begins. |
| MS-O8 | The phase-3+ public-release decision — go public or stay private? Affects all downstream planning. |

---

## 10. References

### 10.1 Software-engineering scope estimation

- Brooks, F. P. *The Mythical Man-Month*. Addison-Wesley, 1975.
- DeMarco, T., Lister, T. *Peopleware*. Dorset House, multiple editions.

### 10.2 Long-horizon solo project case studies

- Various: TempleOS (Terry Davis), MenuetOS (Ville Turjanmaa), ToaruOS — comparable solo OS projects for calendar reference (none reached PaideiaOS's ambition; their timelines are informative for what's achievable).
- nim (Andreas Rumpf) — solo-led language for first decade, then grew.
- Zig (Andrew Kelley) — solo-led language for several years before broader adoption.

---

*End of document.*
