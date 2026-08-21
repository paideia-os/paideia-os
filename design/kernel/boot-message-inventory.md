---
doc: boot-message-inventory
scope: R49.M1-001 — enumerate + classify every boot-time emit site
issues:
  - "R49.M1-001 (#1571): boot-message inventory"
  - "R49.M1-002 (#1572): build-mode / log-level split"
  - "R49.M2-002 (#1574): rewrite release-visible messages"
  - "R49.M2-003 (#1575): release boot status presentation"
  - "R49.M3-001 (#1576): release-mode boot witness + regression gate"
status: R49 initial landing — methodology + classification live; per-line
        table is generated on demand from `tools/generate-boot-inventory.sh`
related:
  - design/kernel/kernel-logging-substrate.md   (klog substrate)
  - design/kernel/boot-presentation.md          (M2-003 spec)
  - src/kernel/core/config/build_mode.pdx        (M1-002 mechanism)
  - src/kernel/core/klog/emit.pdx                (klog_emit_core mute gate)
  - src/kernel/boot/uart.pdx                     (uart_puts mute gate)
  - src/kernel/core/klog/present.pdx             (release presentation)
  - tools/generate-boot-inventory.sh             (mechanical inventory generator)
  - tools/run-smoke.sh                           (boot_release regression gate)
---

# Boot-message inventory + classification

## 0. What this document is

R49.M1-001 requires an enumeration of **every** boot-time message the
kernel or a user image can print, classified as RELEASE, DEBUG, or
REMOVE. Two things make a static hand-typed table the wrong artifact:

1. **Scale.** The mechanical sweep in §3 finds `578` `call
   klog_s1*/klog_emit_core/uart_puts` sites in `src/kernel/**` plus
   `363` `.ascii`/`.asciz` strings in `tools/boot_stub.S`. A static
   table with ~900 rows would be out of date the day it lands.

2. **Locality of information.** The classification (RELEASE / DEBUG /
   REMOVE) is a *policy* — it belongs beside the emit site, not
   duplicated in a doc. §5 below defines the policy, and the
   generator script tags every row from the source without a table
   maintainer in the loop.

The deliverable is therefore a **methodology + classification policy
+ regenerable table**. The regenerable table is written to
`build/boot-message-inventory.tsv` by
`tools/generate-boot-inventory.sh`; this doc pins its shape and the
rules that generate it.

## 1. Population sources

Every byte a booting kernel or user image can put on COM1 (or on the
framebuffer, when the fb console is wired) comes from one of five
mechanical sources:

| # | Source                                                                      | Emit primitive       | Kind of message                                    |
|---|-----------------------------------------------------------------------------|----------------------|----------------------------------------------------|
| 1 | `src/kernel/**/*.pdx` + `src/user/**/*.pdx` — `call klog_s1*`               | `klog_emit_core`     | Structured witness / diagnostic line               |
| 2 | Same — `call klog_emit_core` (direct)                                       | `klog_emit_core`     | Same                                               |
| 3 | Same — `call uart_puts`                                                     | `uart_puts`          | Raw string (typically boot_stub .ascii fixtures)   |
| 4 | `tools/boot_stub.S` — `.global X_msg` + `.ascii "..."`                      | Referenced by (3)    | Static message text (`banner_art`, `kpti_ok_msg`, …) |
| 5 | `src/user/**` — libc `puts` / `write(1, ...)`                               | `sys_write` on fd 1  | Userspace-visible output (`SHELL START`, `$`, …)   |

Sources (1)–(4) are what R49 muted-in-release replaces with the
presentation stream. Source (5) is what a real user program (shell,
init) writes; R49 does not gate it, because it is the *purpose* of
booting — a kernel that muted `sh`'s prompt would be worse, not
better.

## 2. Aggregate counts (snapshot)

Numbers below are the mechanical counts at the R49-landing commit.
`tools/generate-boot-inventory.sh` regenerates the same counts on
every run; a divergence between this section and the generator's
output is a signal that the emit surface has changed and this section
should be re-pinned.

| Source | Count | Notes |
|--------|-------|-------|
| `call klog_s1*` (all arities) + `call klog_emit_core` | ~510 | Structured witness stream |
| `call uart_puts` in `src/kernel/**` | 65   | Raw literal emits (bootstub fixtures + a few witnesses) |
| `.ascii` / `.asciz` in `tools/boot_stub.S`             | 363  | Static message text |
| Userspace `sys_write` sites (out of scope for R49)     | –    | Not muted; not counted here |

A typical boot under `boot_r17_shell_echo_hello` renders ~530 lines
on COM1. Of those, ~167 are `... OK` witness fingerprints the smoke
matrix asserts. R49 does not shrink the TEST-mode stream by even one
byte; it only produces a distinct, curated RELEASE stream.

## 3. Mechanical enumeration

`tools/generate-boot-inventory.sh` produces
`build/boot-message-inventory.tsv` with one row per emit site. Columns:

    file<TAB>line<TAB>primitive<TAB>message_symbol<TAB>class

Extraction rules:

- **klog sites**: `grep -rEn 'call (klog_emit_core|klog_s1(_(x|d)[0-9]+)?)\b'` under `src/kernel/**` and `src/user/**`. The
  `message_symbol` column is the `SUBSYS_*` + `*_msg` names the caller
  loads into rdi/rsi/rdx immediately above the call (walked back at
  most 12 lines by the extractor).
- **uart_puts sites**: `grep -rEn 'call uart_puts\b'` under `src/kernel/**`. The `message_symbol` is the `[rip + X]` argument
  passed in rdi immediately above the call.
- **boot_stub fixtures**: every `.global` symbol in
  `tools/boot_stub.S` followed by an `.ascii`/`.asciz` directive.

## 4. Classification policy

Each row lands in exactly one of three buckets. Per §5 of the R49.M1-002
mechanism, only RELEASE rows survive on the wire in release mode
(TEST mode continues to emit everything).

- **RELEASE** — bytes a person needs to see on a boot they did not ask
  to debug. Wording must satisfy the R49.M2-002 rules (no `R__` /
  `M__-___` identifier; no raw hex TSC; no truncated 4-char subsystem
  tag; no repeated-per-call trace). The banner + copyright, a
  "Kernel starting." preamble, and a "System ready." close are
  RELEASE at the R49 landing; every future stage-progress line
  (firmware, memory, CPUs, storage, input, network) is added here by
  moving its emit into `Present`.

- **DEBUG** — witness fingerprints the smoke matrix asserts, and every
  klog line whose consumer is a kernel developer. These stay muted in
  release. They do NOT need to be rewritten; they are correct as they
  are, they are just not release-visible.

- **REMOVE** — a message no consumer reads. Nothing in the R49.M1-001
  sweep is currently REMOVE: every ` OK` fingerprint the tree can
  print is asserted in at least one golden (R49.M3 / #1578 gate).
  This column exists so that future landings can name a message as
  removable, but at R49 the answer is "none".

The classification is applied by `tools/generate-boot-inventory.sh`
per these rules:

- boot_stub symbol matches `^banner_(art|msg)$` → RELEASE.
- boot_stub symbol contains `_ok_msg`, `_fail_msg`, ends in `_msg` →
  DEBUG.
- Any klog site whose emit walks through the `Present` module → RELEASE.
- Every other klog site → DEBUG.
- Every `call uart_puts` under `src/kernel/**` whose target symbol is
  a boot_stub fixture → same classification as the fixture.

## 5. What R49 changes

R49 does not touch the DEBUG rows: their bytes still land on COM1 in
TEST builds (default), and the 14-mode witness matrix keeps asserting
them unchanged.

R49 changes the RELEASE rows in one way: **they are moved to
`src/kernel/core/klog/present.pdx`**. Every release-visible message
lives in that file. A subsequent stage-progress landing (per
`boot-presentation.md` §4) grows the Present module rather than
scattering release output across the tree.

## 6. Regeneration recipe

    $ bash tools/generate-boot-inventory.sh
    [inventory] scanning src/kernel + src/user + tools/boot_stub.S
    [inventory] wrote build/boot-message-inventory.tsv (rows=…)
    [inventory] release=… debug=… remove=…

The script is deterministic; the same commit produces the same TSV.
It is not run by `tools/build.sh` (adds seconds to every build for
no build-blocking failure it can catch — a stale TSV does not break
anything). Run it manually when writing an R49-follow-up milestone
or when auditing what a person actually sees at boot.
