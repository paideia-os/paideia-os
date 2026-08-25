# R78 Retrospective (PARTIAL): ACPICA/AML interpreter

**Date:** 2026-08-25
**Milestone:** R78.M1 (single-milestone round; PARTIAL close by this doc)
**Issues:** 6 landed / satisfied by pre-existing R30+R31 code (#1906,
#1908, #1909, #1912, #1913, #1914-partial); 1 partial with real
remaining work (#1915); 2 deferred to real T14 G4 hardware (#1917,
and the hardware-observable slice of #1914); this doc closes #1919.
**HEAD at closure:** paideia-os e65cd00 + this commit.
**Release tag:** `r78-closed` (partial-close discipline, per R58/R59/
R74 precedent).

## Why this round audits as mostly-already-landed

R78 was scoped as if the AML tokenizer/parser/evaluator/opregion stack
were greenfield. It is not. R30 ("ACPICA userspace bubble + LPSS bus
enablement") and R31 (fan/thermal/backlight AML consumers) already
landed an 18-file, ~24,800-line native paideia-as AML interpreter under
`src/user/aml/` — see `design/acpi/aml-parser.md` and
`design/acpi/aml-evaluator.md`. The original `acpica-bubble.md` draft
(hosting upstream C ACPICA) was superseded by this native
implementation; `tools/lint-no-kernel-aml.sh` polices the
kernel/userspace boundary (Pillar 3) for it. This retro's job is to
map each R78 sub-issue onto what that prior work already proves, not
to re-implement it.

## Per-issue disposition

### #1906 — AML tokenizer — LANDED
`src/user/aml/aml_lex.pdx` (1080 lines). `aml_lex_opcode` decodes
single-byte and `0x5B`-ExtOp-prefixed opcodes into a normalised 16-bit
form (§20.2.3); `aml_lex_int` decodes `ZeroOp`/`OneOp`/`OnesOp`/byte/
word/dword/qword integer literals; PkgLength decoding is covered in
`aml_ns.pdx §aml_ns_pkg_open`; `aml_lex_lnc`/NameSeg helpers implement
LeadNameChar/NameChar per §20.2.2. Exercised against the fuzz corpus
`tests/fuzz/aml/corpus/c000..c032*.aml` via `tests/user/aml/
aml_harness.c` (8093 lines). Landed at R30.M1-001 (#1049).

### #1908 — AML term parser — LANDED
`src/user/aml/aml_term.pdx` (1513 lines): `aml_term_expr`,
`aml_term_obj`, `aml_term_buffer`, `aml_term_package`,
`aml_term_arg`, `aml_term_bodies` build the arena-indexed AML-op tree
from the tokenizer's stream (`design/acpi/aml-parser.md §4` — 4×u64
node records, indices not pointers). Nested (`c006-nested.aml`) and
recursive (`c005-recursive.aml`) fixtures are in the corpus and driven
by the harness. Landed at R30.M1-002/003 (#1050/#1051).

### #1909 — AML namespace — LANDED against synthetic tables; DEFERRED
against real T14 G4 DSDT
`src/user/aml/aml_ns.pdx` (1279 lines): `aml_parse` /
`aml_parse_termlist` walk a table's TermList and populate the arena
with named scopes (`aml_ns_pkg_open`, `aml_ns_open_pkg_named`,
`aml_ns_fieldlist`); `aml_eval_abspath` (aml_eval.pdx) computes
absolute namespace paths (`\_SB.PCI0...`) from the lexical tree,
which is the mechanism that actually answers "populate `\_SB`,
`\_TZ`, `\_PR`" — path computation is namespace-shape-agnostic, so it
already handles any legal scope nesting the fuzz corpus exercises.
**Gap:** `tools/capture-t14-g4-acpi.md` (R20.M5-001, #823) explicitly
defers DSDT/SSDT *content* capture — "deferred to the R34 ACPICA
[bubble]" — and no such capture ever landed (the bubble draft was
superseded by the native interpreter above). There is **no real T14
G4 DSDT/SSDT fixture in this tree**; only the synthetic
`tests/kernel/acpi/*_synth.pdx` and the synthetic fuzz corpus exist.
The issue's own fingerprint ("walking the T14 G4 DSDT/SSDT fixtures")
cannot be satisfied without that capture. DEFERRED for the
real-hardware slice; LANDED for the mechanism.

### #1912 — AML interpreter core — LANDED
`aml_eval.pdx` (3867 lines) + `aml_ctl.pdx` (985) + `aml_arith.pdx`
(607) + `aml_obj.pdx` (1135). `aml_eval_stmt` dispatches If/Else
(§1809-1841), While (§1842-1873, fuel-spent per iteration),
Return (§1874-1919, including object-typed returns — Buffer/Package
— not just integers), and Store (§evsm/evst — four legal targets:
null-target, LocalX, ArgX, named-integer). `aml_arith_eval` covers
And/Or/Add/Subtract and the rest of the §19.3.5 arithmetic set.
`aml_obj_pkg_alloc`/`aml_obj_buf_alloc`/`aml_obj_elem_get`/`_set`
cover Package and Buffer; Field element handling is in
`aml_ns_fieldlist`. Guarded by fuel (1,000,000 steps), depth (48),
and an 8-frame pool (`design/acpi/aml-evaluator.md §2`) — the
termination and memory-safety properties #1912 implicitly requires.
Fingerprint harness is `tests/user/aml/aml_harness.c` against the
same corpus. Landed at R30.M2-001..007 (#1054, #1056-#1060).

### #1913 — Operation region I/O — LANDED
`src/user/aml/aml_region.pdx` (2807 lines): `aml_region_space_
supported` enumerates SystemMemory(0)/SystemIO(1)/PCI_Config(2)/
EmbeddedControl(3) as serviced, and explicitly refuses (not silently
ignores) SMBus/CMOS/GPIO/GenericSerialBus/PCC/vendor spaces with
`AML_ERR_REGION_SPACE`. `aml_region_port_in`/`_port_out` do the
SystemIO transaction with correct narrow-width `in`/`out` forms (no
8-byte port emulation, deliberately, so a FIFO port is never
double-popped). EmbeddedControl "binds but does not transact" —
every EC access routes through the R31 EC path
(`aml_region_ec_backing`/`_ec_gated`) into `aml_ec.pdx`, per the
design note in `aml_region.pdx §217-260`. Landed at R30.M3-001..003
(#1061-#1063), EC integration at R30.M7 (#1080, #1104).

### #1914 — Method invocation (`_STA`/`_INI`/`_CRS`/`_Qxx`/`_PSR`/
`_BAT`) — PARTIAL
`aml_eval_method` (aml_eval.pdx, ~L2278) is the generic top-level
entry point: "This is what the acpi_supervisor process will call to
evaluate a `_STA` or a `_CRS`" (its own header comment). Combined
with `aml_eval_find_in_scope`, this generic mechanism resolves and
invokes **any** zero-argument named method or reads any named
integer — so `_STA`, `_INI`, and `_CRS` are mechanically LANDED
(proven concretely for `_STA` by `aml_fan_read_sta`/
`aml_fan_read_child`, and for `_CRS` by the resource-descriptor
decode in `aml_resource.pdx`). `_Qxx` is LANDED with its own
purpose-built dispatcher: `aml_ec_query_seg`/`aml_ec_query_pump` in
`aml_ec.pdx` synthesize the `_Qxx` NameSeg from the queried byte and
invoke it in the EC device's own scope (§1176-1384), landed at
R30.M8 (#1082) / R30.M9. **Gap:** `_PSR` (AC adapter) and `_BAT`
(battery status/info, `_BST`/`_BIF`) have **no code anywhere** in
`src/user/aml/` — no reader wrapper analogous to `aml_thermal.pdx`/
`aml_fan.pdx`, and no package-decode logic for the `_BST`/`_BIF`
return shapes (ACPI 6.5 §10.2). This is genuine remaining work
(a new `aml_battery.pdx`), not hardware-gated in principle since the
generic invocation mechanism already exists — but validating the
`_BST`/`_BIF` decode is far more useful against the real T14 G4
DSDT than a synthetic fixture, so implementation should land WITH
the #1909 real-hardware capture, not before it.

### #1915 — GPE dispatcher via AML `_Lxx`/`_Exx` — PARTIAL
Kernel-side GPE plumbing is fully landed and unit-tested:
`src/kernel/core/acpi/gpe_table.pdx` (dispatch table + strike/storm
accounting, 713 lines), `gpe_block.pdx` (register geometry + FADT
config, 703 lines), `gpe_ack.pdx` (enable/disable/clear-status/ack,
285 lines), `gpe_io.pdx` (port + synthetic-mode I/O + trace ring,
538 lines) — all from R30.M4 (#1066-#1069). This is a real,
production-grade masked-dispatch-to-userspace pipeline (SCI ISR →
GPE table → `KIND_ACPI_EVENT` notify ring, per
`src/kernel/core/cap/kind_acpi_event.pdx`).
**Gap:** nothing resolves a fired GPE index to a `_Lxx`/`_Exx`
NameSeg and invokes it through the AML evaluator. `grep`ing the
entire `src/user/aml/` tree for `_Lxx`/`_Exx`/`gpe` turns up exactly
one incidental comment (`aml_ec.pdx:493`, an analogy, not a call).
The `_Qxx` dispatcher in `aml_ec.pdx` (`aml_ec_query_seg` /
`aml_ec_query_pump`) is the exact template this needs — synthesize
`_L<hex>` or `_E<hex>`, resolve in the GPE-owning scope via
`aml_eval_find_in_scope`, invoke via `aml_eval_method` — but the
file (likely `aml_gpe.pdx`) does not exist. This is real remaining
work, and unlike #1909/#1914's hardware slice, it is fully
testable against a **synthetic** DSDT that defines `_L01`/`_E02`
methods (the same posture the `_Qxx` corpus fixture already uses)
— it does not require the real T14 G4 capture. Recommend as the
first R81-or-later follow-up issue, scoped from this gap analysis
directly rather than re-opened blind.

### #1917 — Boot smoke `boot_r78_aml_fn_keys` — DEFERRED
`tests/r78/boot_r78_aml_fn_keys.pdx` does not exist, and cannot be
written meaningfully without: (a) the real T14 G4 DSDT `_Q05`/`_Q06`
(or equivalent) fn-key query methods from #1909's undone capture,
(b) the #1915 GPE-to-`_Lxx`/`_Exx`-to-`_Qxx` dispatch chain wired
end-to-end, and (c) physical Fn+F5/Fn+F6 keypresses and a real
brightness register on a live ThinkPad T14 Gen 4 — none of which
QEMU/OVMF can synthesize. The M0 QEMU DSDT is a minimal synthetic
table with no backlight/HID method surface at all. DEFERRED,
real-hardware-only, no forward progress possible in this
environment.

### #1919 — Round closure — this document
STATUS + retrospective + `r78-closed` tag, following the R58/R59/R74
partial-close precedent (defer sub-issues that need artifacts this
environment cannot produce, close the round honestly, resume the
roadmap).

## Cross-repo escalations

None. All R78 code (existing and gapped) lives in the paideia-os
monorepo; no paideia-as language/toolchain defect was found while
auditing.

## Debt inventory (carried forward)

1. **Real T14 G4 DSDT/SSDT capture** (blocks #1909's hardware slice,
   #1914's `_PSR`/`_BAT`, and #1917 entirely) — run
   `tools/capture-t14-g4-acpi.md` on physical hardware; this was
   deferred once already at R20.M5 and never revisited.
2. **`_PSR`/`_BAT` reader** (`aml_battery.pdx`, new file) — mechanism
   exists (`aml_eval_method`), decode logic for `_BST`/`_BIF` package
   shapes does not.
3. **GPE `_Lxx`/`_Exx` dispatcher** (`aml_gpe.pdx`, new file) — the
   one piece of R78 that is neither landed nor hardware-gated;
   template it directly off `aml_ec_query_seg`/`_query_pump`.
4. **`boot_r78_aml_fn_keys`** — write once (1)-(3) above land.

**Next round:** R81 (HDA audio) per the post-R60 daily-use roadmap,
or a dedicated hardware-capture pass to unblock the R78 debt above.
