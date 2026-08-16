# Emitted-vs-asserted fingerprint coverage

**Issue:** #1578. **Gate:** `tools/verify-fingerprint-coverage.sh`, wired
into `tools/build.sh` beside the no-AML lint.

---

## 1. The defect class

Every subsystem in this kernel announces itself on the serial line with a
`... OK` marker. A smoke mode passes by finding an ordered subsequence of
those markers in the log. The failure this document is about is a marker
that is **emitted and asserted nowhere**.

It is invisible by construction. The marker appears in the log whether or
not anything checks it, so reading the boot log to confirm a subsystem
works proves *nothing* about whether the test suite would notice its
absence. A regression in that subsystem leaves the entire matrix green.

It has now happened twice:

* `3212fdb` found two (`R30 KIND_OP_REGION OK`, `R17 BIN TRUE SEED OK`).
* #1578 found **seven** more by mechanical sweep over all 156 production
  markers — `PAT INIT OK`, `HPET INIT OK`, `M1 S1 OK`, `PF COW FLIP OK`,
  `KPTI STACKS OK`, `KPTI ISR OK`, `KPTI DESC OK`.

Three of the seven are KPTI, the kernel/user page-table isolation
boundary. Had `kpti_stacks`/`isr`/`desc` setup silently stopped running,
nothing in the 14-mode matrix would have said so.

Two occurrences of one defect class is the argument for a gate rather
than a third fix.

---

## 2. Matching semantics

`tools/run-smoke.sh` does ordered **substring** matching of golden lines
against the serial log, so the gate mirrors that. An emitted marker `M`
is asserted if some golden line `A` satisfies

* `M.startswith(A)` — the golden asserts a prefix of the marker
  (`PAT INIT OK` vs emitted `PAT INIT OK slot4=WC`), **or**
* `A.startswith(M)` — the marker is a static prefix and the golden
  additionally pins the runtime value suffix (emitted tag
  `M8 MAXLINE OK` vs golden `M8 MAXLINE OK len=0x`),

**and** `A` itself contains the `OK` token as a whole word. That last
clause is not decoration: without it the one-character golden line `B`
(the first boot byte) is a prefix of `BLOB SIG OK` and silently "covers"
it. It also means a perturbed golden line — `R30 GPIO PAD OKZZ` — stops
being an assertion at all, so tampering with a golden trips the gate
directly.

---

## 3. Extraction

| Source | Form |
|---|---|
| `*.S` | `.ascii` / `.asciz "..."` |
| `*.pdx` | `let NAME : [u8; N] = "..."` |
| `*.pdx` | `let NAME : [u8; N] = [ 0xNNu8, ... ]` |

The byte-array form matters: `src/kernel/boot/verify_self.pdx` declares
`R28 EFI SIGNATURE OK` that way, and the first pass of the #1578 sweep
missed it for exactly that reason.

Scope is `src/`, `tools/` and `tests/`. The 156 markers under `src/` and
`tools/` are the production set; the 22 under `tests/` are synth-witness
markers and are handled by the allowlist below.

---

## 4. The vacuity guard

The gate fails if it finds fewer than `MIN_EMITTED` markers or fewer than
`MIN_ASSERTED` golden lines. A future refactor of the tag declaration
style would otherwise make the regexes stop matching, and the gate would
"pass" by scanning nothing — which is the failure mode it exists to
prevent, arriving silently. Same shape as the ISR-allowlist vacuity
guards in `tools/build.sh`.

---

## 5. The allowlist, and why it is not a silent exemption

Some markers genuinely cannot be asserted by any mode. Each gets an
entry **with a reason**, and the reason must say *why* nothing reaches it
and what would change that. Two hygiene checks keep the list honest and
both fail the build:

* **stale** — an allowlisted marker that is no longer emitted anywhere;
* **redundant** — an allowlisted marker that *has since become* asserted.
  The exemption is deleted so the assertion is what holds it.

### 5.1 Production markers (triaged for #1578)

| Marker | Why no mode reaches it |
|---|---|
| `VTD FAULT HANDLER OK` | `vtd_fault_dispatch` has no caller anywhere in the tree; its own header says "NOT WIRED AT M4 BOOT". Reachable from R23 IDT wiring. |
| `BLOB SIG OK` | emitted only for verdict 0 (a dual signature that verifies); no boot fixture is validly signed under the R25.M5 dev-bypass keyring. Needs R32's real ML-DSA-65 verify. |
| `PF COW SPLIT OK` | the COW split arm needs a write fault on a refcount ≥ 2 frame; no witness writes to a shared frame, which is why `PF COW FLIP OK` prints and this does not. |
| `R28 EFI SIGNATURE OK` | UEFI-only path. All 14 modes boot via `-kernel`; the opt-in OVMF fixture is a single-marker grep with no golden and stops at the pre-EBS banner. |

### 5.2 Test-side synth witnesses

Eighteen markers under `tests/**` that no default-matrix mode reaches —
verified as zero occurrences in a full default-matrix boot log. They
belong to opt-in modes (`PAIDEIA_R22_MSIX_IR`, `PAIDEIA_R25_PDXFS_E2E`,
…) or to real-hardware smokes (`PAIDEIA_HW_SMOKE`). They are listed
individually rather than exempted by directory, so a **new** test-side
marker still trips the gate.

---

## 6. What the gate does not prove

Coverage here means "some golden asserts this string", not "the assertion
bites". Non-vacuousness is a separate, per-marker obligation: perturb the
golden line and watch the owning mode fail. All seven markers added by
#1578 were proved that way, and the ordered-position half of the check
was proved by moving a line rather than changing it. An assertion never
observed failing is not evidence of coverage — that is the whole lesson
of this bug class.
