# Output-provenance strip: release/milestone/issue references leaked into runtime

## Rule

Runtime output — anything a running binary emits — must **not** contain release, milestone, or issue references. That information belongs in three places only:

1. **Design docs** (`design/`)
2. **GitHub issues**
3. **Commit messages** (and CHANGELOG for signed releases)

Anywhere else — klog strings, shell fingerprints, diagnostic message bodies, help text, version banners, embedded `.rodata` strings — it's provenance leaking through the wire. When it's leaked, running the OS produces text that will age instantly and read as archaeology within one release cycle.

## What counts as "past release" leakage

Prohibited in runtime output:

- `R\d+(\.M\d+)?-?\d*` (R42-PREP-007, R51.M2, R30.M4)
- `#\d{2,}` where the digits mean a GitHub issue (`see #1234`)
- `v\d+\.\d+(\.\d+)?` (v0.33-crypto, v0.21)
- `M\d+-\d+` inside human-facing strings (`M4-001`)
- Milestone/round nicknames in fingerprints (`KIND_TTY OK` is fine; `R30-PREP KIND_TTY OK` is not — the runtime doesn't need to know the round name)
- Design-doc paths in log strings
- Bare commit SHAs

Allowed anywhere:

- KIND ordinals (`0x197` is data, not provenance)
- Sysno numbers
- Error codes (`0xFFFFEBxx`)
- Component names (`nvme`, `pdxfs`)

## Surfaces to sweep

### paideia-as (Rust)

1. Diagnostic message bodies (`crates/paideia-as-diagnostics/**`) — remove issue-number citations from user-facing message text; keep only in doc comments
2. `--help` and `--version` output — no "since M-N" text
3. Test-name prefixes — internal only; if any test framework echoes names to CLI, strip
4. Klog / println / eprintln in the binary — no round tags
5. Any string constants in `.rodata` that include the prohibited patterns

### paideia-os (`.pdx`)

1. **`tests/r17/shell-shutdown.golden`** — every fingerprint line prefixed with a round tag (`R30-PREP KIND_TTY OK`, `R42-PREP-007 PDXFS TXN OPS OK`, `R51.M1 KIND_NVME_CONTROLLER OK`, `R51.M2 KIND_NVME_NAMESPACE OK`) — rewrite as component names only
2. Witness fingerprint strings in `tests/kernel/**/*_synth.pdx` — same
3. `klog_s1(...)` call sites throughout `src/kernel/**` where the text names R-numbers
4. Boot banner strings
5. Audit-journal event descriptions in `src/kernel/core/audit/**`
6. Design-comment blocks that get compiled into `.rodata` via string constants
7. Shell prompt / init messages
8. Panic messages
9. `.pdxdoc` files consumed at runtime by `doc` tool (only trim the human-facing rendered text; the front-matter can keep provenance)

## Non-scope

- Do not touch commit messages, CHANGELOGs, issue titles, design docs, or `.plans/` notes.
- Do not touch `justification:` blocks in `.pdx` sources — those are audit-review material, not runtime output.
- Do not remove code comments referencing R/M/#N — comments do not compile into output. Only strip when the string is emitted at runtime.

## Enforcement

After this cleanup wave, add a build-time gate: a regex sweep over emitted `.rodata` strings in the linked ELF that fails the build on any prohibited pattern. That gate lives in `tools/build.sh` (paideia-os) and `cargo test` fixture (paideia-as).

## Rollout

Cleanup filed as a sweep of issues per surface. Each issue names a specific file cluster + expected before/after shape. Landed as separate commits so the diff is greppable and reviewable per-cluster.
