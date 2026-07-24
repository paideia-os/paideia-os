# R17-M0 #669: kernel-link nondeterminism

## Symptom

Rebuilding `build/kernel.elf` back-to-back with no source changes produces
different SHA-256 hashes. Three clean builds at HEAD 20737f9 produced three
unique hashes (not a two-state alternation — signature of Rust `HashMap`
`RandomState`, which is process-fresh).

## Downstream impact

- Every "N-mode smoke byte-identical" claim in commit messages is
  unverifiable single-run evidence, not multi-run reproducibility.
- ~30-40% pre-push flake rate on boot_r10/r11/r12/r14b_ipi/loader smoke
  modes ("TASK A" missing, log truncated at 554 bytes) — boot timing
  shifts as symbol addresses drift.
- Debugger verify passes are contaminated by boot-timing shifts.

## Root cause (upstream — paideia-as #1253)

`tools/paideia-as/crates/paideia-as-ir/src/side_table.rs:36` — `SparseSideTable<K,V>`
is backed by `std::collections::HashMap<K,V>`. Its `iter()` returns
`hash_map::Iter` "in an unspecified order" (per the type's own doc). The `.rodata`
byte emitter at `crates/paideia-as/src/cmd_build/elf.rs:181` iterates this in the
HashMap's fresh-per-process permutation, so per-object `.rodata` byte order
shuffles across builds. Section headers/sizes/alignments are byte-identical;
only interior byte order drifts. All references are RIP-relative (symbolic
relocations), so the kernel remains functionally correct despite the drift —
but timing/layout shifts cascade into smoke-flake territory.

Per-object split at HEAD 20737f9 (200 objects): SAME=96, DIFF=104.
`boot_stub.o` (GNU `as`) is byte-identical; every differing object is
paideia-as-emitted. Cleared as suspects: GNU `as`, GNU `ld`, `src/kernel/link.ld`,
`tools/build.sh` (uses `find … | sort -z`), `arena.symbols()` (Vec-backed),
`ElfWriter::symbols` / `custom_sections` (HashMaps but driven by insertion-ordered
Vec).

## Fix path

1. Upstream (paideia-as #1253): swap HashMap→BTreeMap in `SparseSideTable`.
   Add defensive `sort_by_key(|(k,_)|k.get())` at the two emission call sites
   as a boundary invariant. Regression test: assemble same .pdx twice, assert
   byte-identical .o.
2. Cut paideia-as v0.20.1 + CHANGELOG entry.
3. Bump `tools/paideia-as` submodule pointer in paideia-os.
4. Rerun `tools/test-reproducibility.sh` and confirm exit 0.

## Local canary

`tools/test-reproducibility.sh` performs three clean builds and asserts
sha256 identity across all three. NOT wired into pre-push hook — it will fail
until step 3 above lands, and wiring it in would block every push. Developers
run it manually: `./tools/test-reproducibility.sh`.

Once #1253 lands + submodule bumps:
- Wire the canary into the pre-push hook (single run, `./tools/test-reproducibility.sh`).
- Close this issue and #1253.

## References

- paideia-os#669 (this ticket).
- paideia-as#1253 (upstream root cause).
- design/kernel/r15-m5-009-smoke-process-mode.md:395-397 (original prediction).
- feedback_cross_repo_escalation (procedure).
