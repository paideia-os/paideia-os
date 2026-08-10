# PaideiaOS — No In-Kernel AML: Architectural Guardrail

**Status:** Ratified v1.0
**Date:** 2026-08-10
**Round:** R20.M4 (issue #822)
**Owners:** kernel + security
**Enforcement:** `tools/lint-no-kernel-aml.sh` (invoked from `tools/build.sh` and the pre-push hook).

---

## 1. Purpose

Establish, in code and in review process, that **PaideiaOS never runs an AML
interpreter (or any AML-adjacent bytecode) inside the kernel**. The kernel
handles ACPI **static tables only** (RSDP, XSDT/RSDT, MADT, MCFG, FADT, HPET
— everything that is a fixed-layout, header-tagged, checksum-bearing byte
blob). Anything requiring **interpretation** of the ACPI Machine Language
(DSDT, SSDT, `_STA`, `_CRS`, `_PRT`, `_PS0/3`, control methods) is out of
scope for the kernel and lives in the userspace ACPICA bubble planned for
R34.

This document is the design-side promise. `tools/lint-no-kernel-aml.sh`
is the enforcement side.

---

## 2. Rationale — the three pillars this discharges

### 2.1 Pillar 3 — Microkernel discipline

ACPICA is ~200 KLoC of C carrying 25+ years of vendor-firmware workaround
code paths, arbitrary control-flow constructs (AML is Turing-complete),
setjmp/longjmp, mutable global tables, and a subtle re-entrancy model. It
is a substantial *policy engine*. A microkernel that hosts it forfeits the
"only mechanism, no policy" contract irreversibly:

- The kernel's TCB grows by an order of magnitude.
- A single AML control method holds arbitrary firmware-supplied Turing-power
  and can drive memory reads, port I/O, MMIO writes, and IRQ acknowledgements
  as side effects. In-kernel that means every AML method has kernel-mode
  privilege.
- The static-safety story (paideia-as substructural lattice, effect rows,
  capability tags) does not extend to firmware-emitted bytecode; a bytecode
  interpreter in the kernel is a permanent hole in the type-theoretic
  guarantee.

### 2.2 Pillar 6 — Security by construction

The kernel's attack surface is bounded by what it parses. Static-table
parsing is *structural*: signature, length, checksum, then fixed offsets
into typed sub-records. It is a small, closed grammar suitable for the
audit posture we already apply to `src/kernel/acpi/*.pdx` (see
`design/audit/`). AML is an *unbounded* grammar hosted inside a byte blob
whose semantics are firmware-supplied. Interpreting firmware bytecode in
ring-0 is the exact posture that has produced the majority of publicly
disclosed CVEs against ACPICA and other in-kernel AML paths.

The correct architectural posture is: the firmware bytecode enters
user-mode, into a process holding **only** the capabilities the ACPICA
bubble was minted with (see `design/acpi/acpica-bubble.md` §3 AC-D2 —
"the OSL is the capability membrane"). An AML fault becomes a userspace
crash, not a ring-0 fault.

### 2.3 Q5 — Do not reimplement AML from scratch

Locked decision Q5 (see `design/01-foundational-decisions.md`) states we
adopt ACPICA rather than reimplement AML. Q5 makes the AML interpreter's
*existence* a hard input. This guardrail makes Q5's *placement* explicit
and enforceable: ACPICA is welcome — in userspace, behind a capability
membrane, at R34. Never in `src/kernel/`.

---

## 3. What is forbidden — the enforceable rule

Under `src/kernel/**`, the presence of any of the following patterns as
**source-code content** (not comments; not documentation) is a build
error:

| Forbidden pattern | Rationale |
|---|---|
| `AML` (any capitalisation as a bare token in code) | The name of the bytecode |
| `aml_` / `_aml` | Function/variable prefixes/suffixes |
| `amlvm` | AML virtual machine identifier |
| `amlparse` | AML parser identifier |
| `\_SB_` / `\_SB.` | ACPI root scope symbol — only meaningful inside AML |
| `dsdt` | Differentiated System Description Table — AML container |
| `ssdt` | Secondary System Description Table — AML container |
| `acpica` (as a symbol) | ACPICA reference implementation |

**Deliberately in scope** (permitted, not forbidden):

- Static-table headers `RSDP`, `XSDT`, `RSDT`, `MADT`, `MCFG`, `FADT`,
  `HPET` — these are non-AML, structural.
- The **word "AML" appearing in comments or documentation** that *explain
  why AML is not present*. The lint intentionally excludes comment-only
  matches so a kernel file may say "// AML interpretation lives in the
  userspace bubble" without tripping the guard. Enforcement operates on
  code tokens after stripping `//`-to-EOL comments.
- The design tree (`design/**`) and the tests tree (`tests/**`) are
  unrestricted — this guard only fires inside `src/kernel/**`.

---

## 4. The enforcement point

**Script:** `tools/lint-no-kernel-aml.sh`
**Invoked from:**
1. `tools/build.sh` — every kernel build runs the lint before the
   assembler pass. A regression fails the build locally.
2. `.git/hooks/pre-push` — the pre-push regression matrix runs the lint
   as its first check (before the smoke matrix), so a regression cannot
   reach the remote even if a developer skipped `build.sh`.

The lint is a strict `grep -RnE` with two passes:

- Pass A (case-insensitive): the forbidden-pattern set above, over files
  under `src/kernel/**`, with `//`-suffix stripping applied line-by-line
  so comment text is not scanned.
- Pass B (identifier form): `\baml_[a-zA-Z0-9_]*\b`, `\bacpica\b`,
  `\bamlvm\b`, `\bamlparse\b` — bare identifiers only, no substring
  false positives.

Any match: print `[no-aml-lint] FORBIDDEN: <file>:<line>: <content>` and
exit 1. Zero matches: print `[no-aml-lint] OK` and exit 0.

The lint is *itself* excluded from its own scan (it necessarily contains
the forbidden literals as regex patterns).

---

## 5. What lands when — the deferred plumbing

| Concern | Where it lives | When |
|---|---|---|
| Static-table parsing (MADT/MCFG/FADT/HPET) | `src/kernel/acpi/*.pdx` | Landed R20.M1–M3 |
| `KIND_ACPI` derived capability (opaque handle to the RSDT/XSDT byte range) | `src/kernel/core/cap/acpi_cap.pdx` | R20.M4 (scaffolding — this round) |
| IPC wire schema for AcpiEnum / AcpiMadt / AcpiMcfg / AcpiHpet RPCs | `design/ipc/acpi-supervisor-schema.md` | R20.M4 (design; code deferred — this round) |
| Userspace `acpi_supervisor` server binary | `src/user/acpi_supervisor/` | Deferred — needs userspace-server infrastructure that does not yet exist |
| ACPICA bubble (AML interpreter in userspace) | Separate `src/user/acpica_bubble/` process | R34 |

---

## 6. Failure mode this prevents

**Concrete scenario the guardrail catches:**

An engineer implementing power management (R33) sees that ACPICA has a
neat `AmlWalkNamespace()` helper for enumerating device handles and
copies the header into a kernel-side helper thinking it's just table
walking. The lint fires on `AmlWalkNamespace` (matches `\baml_[...]`),
build fails, engineer is told to add the walk to the userspace bubble
instead. No AML interpreter code path ever silently accretes in ring-0.

**What the guardrail deliberately does not catch:** intentional violations
via `unsafe` blocks that hand-emit AML opcodes as raw bytes (there is no
lexical fingerprint). Those are the audit process's job (see
`design/capabilities/derived-kinds.md` §3), not this lint's.

---

## 7. Amendment discipline

The forbidden-pattern list may only be *expanded* — never shrunk — without
a design-document supersession. Adding new AML-related tokens to the
forbidden list is a one-line change; removing tokens requires a fresh
design memo justifying why the microkernel-purity invariant is being
relaxed. As of R20.M4 no such relaxation is contemplated.

---

## 8. Cross-references

- `design/acpi/acpica-bubble.md` — where AML *does* live (userspace, R34).
- `design/01-foundational-decisions.md` §Q5 — the "adopt ACPICA, do not
  reimplement" locked decision.
- `design/capabilities/derived-kinds.md` — derived-kind audit process
  that owns the `unsafe`-block bypass case.
- `src/kernel/core/cap/acpi_cap.pdx` — the KIND_ACPI derived capability
  that gates userspace access to the RSDT/XSDT byte range.
- `design/ipc/acpi-supervisor-schema.md` — the RPC wire schema the
  userspace supervisor will expose over the KIND_ACPI capability.
