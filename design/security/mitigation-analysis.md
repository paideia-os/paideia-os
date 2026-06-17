# PaideiaOS — Security: Same-AS Mitigation Optimization Analysis

**Status:** Draft v0.1
**Date:** 2026-06-17
**Scope:** Informal proof that the same-AS mitigation optimization (SCH-Q10) is sound. Addresses SCH-O8.

---

## 0. The claim

When two threads in the same AS context-switch between each other, KPTI's CR3 swap and IBPB can safely be skipped without introducing new Spectre/Meltdown attack surface.

---

## 1. Attack vectors covered

### 1.1 Meltdown

Meltdown reads kernel memory from userspace via transient execution. KPTI defends by removing the kernel mapping from the user CR3 set.

**Same-AS argument:** Both threads share the same address space. The user CR3 set is identical for both. Switching between them does not change what's mapped — no Meltdown attack surface gained.

### 1.2 Spectre v2 (Branch Target Injection)

Spectre v2 leverages mispredicted branches to leak via cache side-channels. IBPB clears branch predictor state across AS boundaries.

**Same-AS argument:** Within an AS, branch predictor state is naturally shared (and intended to be). Two threads in the same AS already see each other's branch history. Skipping IBPB on same-AS switch does not create new leak.

### 1.3 Spectre v1 (Bounds Check Bypass)

Spectre v1 affects within-process speculative execution. Not addressed by KPTI or IBPB; mitigated via lfence and specific code patterns. Independent of context switch.

### 1.4 L1TF (L1 Terminal Fault)

L1TF leverages PTE bits to read L1 cache lines. Addressed via PTE inversion and L1D flush on context switch.

**Same-AS argument:** Both threads have identical PTEs. No new L1TF surface gained.

---

## 2. What still happens on same-AS switch

- The TCB switch (RSP, GPRs, R12-R15) is unconditional.
- Per-thread MSR state (FS-base, GS-base) is switched.
- The scheduler decision happens.

---

## 3. What is skipped

- KPTI CR3 swap (saves ~150 cycles).
- IBPB (saves ~150 cycles).
- RSB stuffing (saves ~20 cycles).

---

## 4. Conclusion

Same-AS context switches can skip cross-AS mitigations without weakening security. The savings (~300 cycles per intra-AS switch) are significant for IPC-heavy workloads.

---

## 5. Formal verification

A mechanized proof in TLA+ or similar is phase 3+. The informal argument above suffices for current confidence.

---

## 6. Open issues

| ID | Issue |
|---|---|
| MA-O1 | Future Spectre variants — re-evaluate when new variants are discovered. |

---

*End of document.*
