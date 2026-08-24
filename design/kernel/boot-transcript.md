---
doc: boot-transcript
scope: Human-readable serial boot transcript format for paideia-os
status: Design proposal (pre-implementation)
supersedes-format-in: src/kernel/core/klog/emit.pdx (step 6..10 line composition)
related:
  - design/kernel/kernel-logging-substrate.md    (existing substrate — this doc revises §3.3 wire format only)
  - src/kernel/core/klog/emit.pdx                (single point where every klog line is composed)
  - src/kernel/core/klog/subsys.pdx              (subsystem tag strings)
  - src/kernel/core/klog/level.pdx               (level constants + letter table)
  - src/kernel/core/klog/tsc.pdx                 (kread_tsc leaf helper)
  - src/kernel/core/klog/ring.pdx                (ring writer + drain)
  - src/kernel/core/klog/wrappers.pdx            (per-arity KV wrappers)
  - src/kernel/core/klog/keys.pdx                (kv key strings)
  - src/kernel/boot/uart.pdx                     (raw uart_puts — the concatenation source)
  - tools/run-smoke.sh                           (ordered-substring golden matcher)
  - tools/verify-fingerprint-coverage.sh         (coverage gate)
---

# Human-readable boot transcript

## 0. Motivation

The current serial transcript was shaped for a machine: fixed-width hex
timestamp, single-letter severity, four-character subsystem tag, pipe
delimiters with no whitespace, and terse `KIND_X OK` fingerprints whose
meaning only lives in the source. It served the substrate build well —
every field is at a known byte offset, every fingerprint is a plain
substring, and both the smoke driver and the coverage gate parse it
without a library.

Twelve months and eighty subsystems later that format is the wrong
default. A reader who watches a boot in real time cannot answer any of:

- What was the wall-clock (or seconds-from-reset) time of that event?
- Which of the five severities is `P`? `E`? `W`? `D`?
- Which subsystem does `MM__` cover? `CAP_`? `IOMM`? `E1KE`?
- What actually happened when `KIND_GPU_CONTEXT OK` fired?

The reader now has to answer a routine question by reading source, which
is the definition of a bad log. This document specifies a new on-wire
format that is legible on first read while remaining machine-parseable
by everything downstream — the smoke fingerprint matcher, the coverage
gate, the audit-log bridge, the panic dump reader.

The current fingerprint matcher gives the migration a piece of luck we
should not waste: every golden fixture asserts message bodies only
(`CAP OK`, `PAT INIT OK slot4=WC`, `KPTI OK`), never the framing prefix.
The prefix rewrite therefore does not touch a single golden.


## 1. Anti-example — the transcript we have

A representative slice of a real boot (`bash tools/run-qemu.sh` output,
recorded 2026-08-21):

```
000000000fd8ea6a|0|I|BOOT|PaideiaOS
000000000fee2628|0|I|CAP_|CAP OK
000000000ff3ea0a|0|I|IPC_|IPC OK
00000000105cb3b2|0|I|MM__|PAT INIT OK slot4=WC
000000001086a1fa|0|I|BOOT|YMM PRESERVE A OK
00000000109433fa|0|I|TIME|HPET INIT OK period_fs=0x0000000000989680 freq_hz=0x0000000005f5e100
0000000011f7fd4e|0|I|APIC|X2APIC ABSENT
0000000012095dda|0|I|PCI_|PCI ENUM SKIP no MCFG
000000001cdf0946|0|E|BOOT|KIND_INTERRUPT FAIL
 line=8
0000000026eb9314|0|I|CAP_|COOLING ROW
 row=0x0000000000000000
```

Six problems, all fixable at the composer:

1. **Timestamp is raw TSC.** `000000000fd8ea6a` is an unscaled `rdtsc`
   delta from some wall origin. The reader cannot say whether two
   events are ten microseconds or ten seconds apart without dividing by
   a TSC frequency the log itself does not name.
2. **Delimiters are pipes with no whitespace.** Bytes run into each
   other; the eye has to slide along the row counting `|`.
3. **Level is a single letter.** `P E W I D T` requires a lookup.
   `E` in particular is ambiguous with a hex nibble to a fast reader.
4. **Subsystem is a four-char tag with underscore padding.** `MM__`,
   `CAP_`, `INT_`, `FS__` were laid out this way to keep byte offsets
   fixed; a human reader gets `MM__` instead of `memory`.
5. **Messages are pattern-matched shorthand.** `KIND_GPU_CONTEXT OK`
   tells you nothing about what the kernel just registered. `LOGP HEX
   OK` and `M8 MAXLINE OK` are internal witness names, not events.
6. **Records concatenate.** Two mechanisms produce this:
   - Some `_msg` blob emitted via raw `uart_puts` omits a trailing
     `\n`, so the next record glues to it (`ACPI FADT OK` and
     `GLOBAL LOCK OK` on lines 365 / 443 of the sample).
   - Some tag payloads contain an embedded `\n` (see
     `kind_cooling_device.pdx`'s `cool_dbg_msg = "COOLING ROW\n\0"`),
     which the composer copies byte-for-byte and which splits a single
     logical record across two physical lines.


## 2. Proposed format

### 2.1 Line template

One record per line. Fixed left-hand prefix, free-form right-hand
message. Fields are separated by single spaces; the transition from
prefix to message is a single space after the closing `]` of the
subsystem column. No pipes.

```
[  <seconds>.<micros>] <LEVEL> cpu<N> <subsystem>: <message>
```

Widths (all measured in ASCII bytes, monospaced-column-aligned):

| Column       | Width       | Padding rule                                 |
|--------------|-------------|----------------------------------------------|
| `[`          | 1           | literal                                      |
| seconds      | 5           | right-justified, space-padded                |
| `.`          | 1           | literal                                      |
| microseconds | 6           | zero-padded, always six digits               |
| `]`          | 1           | literal                                      |
| space        | 1           |                                              |
| level        | 5           | left-justified, space-padded                 |
| space        | 1           |                                              |
| cpu tag      | 5           | `cpu` + one hex digit + one padding space    |
| subsystem    | 8           | left-justified, space-padded                 |
| `:`          | 1           | literal                                      |
| space        | 1           |                                              |
| message      | up to 200   | free-form                                    |

Total fixed prefix width is 32 columns; the message begins at column 33
on every line. Any monospaced reader sees a clean rectangle.

### 2.2 Side-by-side

Existing (from §1) vs proposed:

```
before:  000000000fd8ea6a|0|I|BOOT|PaideiaOS
after:   [    0.001042] INFO  cpu0 boot    : kernel starting: PaideiaOS

before:  000000000fee2628|0|I|CAP_|CAP OK
after:   [    0.001217] INFO  cpu0 cap     : capability system ready

before:  00000000109433fa|0|I|TIME|HPET INIT OK period_fs=0x0000000000989680 freq_hz=0x0000000005f5e100
after:   [    0.017894] INFO  cpu0 time    : HPET initialised: period 10 ns, frequency 100 MHz

before:  000000001cdf0946|0|E|BOOT|KIND_INTERRUPT FAIL
after:   [    0.483210] ERROR cpu0 cap     : kind_interrupt: install failed (see line 8)

before:  0000000026eb9314|0|I|CAP_|COOLING ROW
         row=0x0000000000000000
after:   [    0.719302] INFO  cpu0 cap     : cooling zone row 0 registered (idx=0 type=1 min=0 max=4 cur=0)
```

The last case shows what the composer must do to fix the split-record
bug (§4.5): coalesce the KV cluster the kernel already emits as several
adjacent single-KV lines into one record.


## 3. Field semantics

### 3.1 Timestamp

**Choice: seconds and microseconds since kernel entry.**

Wall clock is not available before RTC / firmware time is read (and
`paideia-os` deliberately defers that). Raw TSC ticks are meaningless
until the kernel has calibrated the TSC against HPET. There is,
however, exactly one moment in the boot that is always available: the
first instruction of the higher-half kernel. Recording every timestamp
as **elapsed time since that instant** is the same discipline every
serious dmesg uses (Linux `[    0.000000]` is precisely this).

Composition rule inside `klog_emit_core`:

1. On the very first call (a one-shot latch, guarded by a `_klog_t0`
   sentinel), snapshot `rdtsc` into `_klog_t0`.
2. On every call, read `rdtsc`, subtract `_klog_t0`, giving a
   monotonically-increasing tick delta.
3. Convert to microseconds using the calibrated TSC-Hz value already
   published to `_tsc_hz_calibrated` (see `time/tsc.pdx`).
4. Before the TSC is calibrated (i.e. before the `TSC CALIBRATED`
   fingerprint), fall back to a *fixed conservative divisor* published
   as `_klog_ts_prehpet_divisor` (default value: the QEMU-typical 2.5
   GHz — deliberately approximate; the first ~50 lines of a real boot
   are the only ones affected and none of them care about sub-µs
   accuracy).
5. Format the microsecond count as `sssss.uuuuuu` with the seconds
   right-justified in a 5-column field. Boots are expected to complete
   in under 100 seconds; the width covers `99999.999999` cleanly, and a
   longer boot simply grows the column by one on every line from that
   point (correct: alignment breaks visibly rather than silently
   truncating).

**Timestamp calibration event.** At the same moment `TSC CALIBRATED` is
emitted today, the composer additionally emits one bookkeeping line:

```
[    0.048291] INFO  cpu0 time    : timestamp base recalibrated from 2.500 GHz to 2.301 GHz (all prior lines are approximate to within 8.6%)
```

A reader is thereby told, once, exactly which lines are approximate and
by how much — never surprised by a silent scale change.

### 3.2 Level

**Choice: full uppercase words, five-column field, left-justified.**

Words are `PANIC INFO WARN ERROR DEBUG TRACE`. `PANIC` and `ERROR` are
the two five-character maxima; `INFO`, `WARN`, `DEBUG`, `TRACE` all fit
with a trailing space. `PANIC` is spelled `PANIC` (not `PANC` — the
current `SUBSYS_PANC` tag is a subsystem name, not a level).

Rejected alternatives:

- **Single letter.** Compact, but the reader currently cannot tell `P`
  (PANIC) from `E` (ERROR) at a glance. This is the primary complaint.
- **Three-letter abbreviations (`INF WRN ERR PNC DBG TRC`).** Saves two
  columns; still requires memorising a convention. The saving does not
  earn the ambiguity.
- **Colour ANSI.** Rejected — the transcript is often read from a
  captured `.log` file or piped through `less -R` on a terminal that
  does not always render colour, and colour cannot be the only signal
  of severity in a kernel log.

### 3.3 CPU

**Choice: `cpu<N>` where `<N>` is one lowercase hex digit.**

Every boot line today already emits one hex nibble of CPU id. The
`cpu` prefix costs three columns and eliminates a class of misreads
(the standalone `0` in the second field of the old format looked like
a level to a first-time reader).

Multi-socket / >16-CPU support: when `_smp_cpu_count > 16`, the
composer widens the field to `cpu<NN>` (two hex digits, always,
uniformly on every line from that boot). The kernel knows this width
at the moment the first line is emitted (SMP topology is fixed after
`SMP BRINGUP DONE`), so widening happens as a single boot-wide switch,
not adaptively per-line.

### 3.4 Subsystem

**Choice: lowercase word, up to eight characters, left-justified,
space-padded.**

The full mapping from current tags to human names:

| Current  | Proposed  | Notes                                    |
|----------|-----------|------------------------------------------|
| `BOOT`   | `boot`    | early kernel bringup                     |
| `MM__`   | `memory`  | page tables, allocators, PAT             |
| `INT_`   | `int`     | exceptions, IDT, IRQ delivery            |
| `TASK`   | `task`    | task struct, fork, exit                  |
| `SCHD`   | `sched`   | runqueue, sched_switch                   |
| `CAP_`   | `cap`     | capability invoke / mint / revoke        |
| `IPC_`   | `ipc`     | endpoints, message pass                  |
| `VFS_`   | `vfs`     | virtual filesystem                       |
| `TTY_`   | `tty`     | terminal line discipline                 |
| `FS__`   | `fs`      | on-disk filesystems (pdxfs, tmpfs)       |
| `USER`   | `user`    | user-side kernel bridge                  |
| `PANC`   | `panic`   | panic dump framing                       |
| `TIME`   | `time`    | HPET, TSC, timer wheel                   |
| `APIC`   | `apic`    | LAPIC, x2APIC, IOAPIC                    |
| `PCI_`   | `pci`     | PCIe enumeration                         |
| `IOMM`   | `iommu`   | VT-d, DMA remap                          |
| `NVME`   | `nvme`    | NVMe storage                             |
| `XHCI`   | `xhci`    | USB host controller                      |
| `E1KE`   | `e1000e`  | Intel network driver                     |
| `NET_`   | `net`     | network stack                            |
| `DRV_`   | `driver`  | driver framework, blob signature         |

Eight columns fit `e1000e ` and `driver  ` with one and two padding
spaces respectively. `iommu` is five, padded to eight. `panic` is
five, padded to eight. `boot` is four, padded to eight.

New subsystems added after this document must fit in eight columns.
That is a soft rule — a nine-character subsystem widens the field for
every line in that boot, the same widening discipline as the CPU
column. In practice the eight-column budget covers everything on
today's roadmap.

### 3.5 Message

**Choice: English sentences. Lowercase first word (kernel-log
convention, not proper prose). Machine tokens (`0x` hex, `=`
key/value) remain acceptable inside the message body.**

Conventions:

- **Result verb over `OK` / `FAIL`.** Prefer `initialised` /
  `registered` / `ready` / `failed` / `denied` / `absent`. `OK` stays
  legal for backwards fingerprint compatibility (see §5.2); new
  messages should use the verb.
- **Units on numbers.** `10 ns` not `period_fs=989680`. `100 MHz` not
  `freq_hz=0x5f5e100`. If the raw value is load-bearing for later
  debug, keep it in parentheses: `100 MHz (freq_hz=0x5f5e100)`.
- **Structured fields at end.** Any `key=value` pairs move to the end
  of the message, comma-separated inside parentheses:
  `(pid=42, cs=0x08, rip=0xdeadbeef)`. This lets a human read the
  narrative first and skip the machine detail unless needed.
- **No leading tag.** The subsystem column already tells the reader
  where the event is from; a message beginning with `CAP` inside the
  `cap` subsystem is duplication.
- **One event per line.** A composite event (e.g. registering a
  cooling zone with six attributes) collapses to one line, not seven.
  The KV wrappers already coalesce ≤4 pairs; the six-pair `COOLING
  ROW` cluster and its siblings need a `klog_s1_x6` wrapper (see §7)
  or a caller-side rewrite that lifts the seven single-KV emits into
  one multi-KV emit.

Example rewrite of the current fingerprint corpus:

| Current message                                      | Rewritten                                                      |
|------------------------------------------------------|----------------------------------------------------------------|
| `PaideiaOS`                                          | `kernel starting: PaideiaOS`                                   |
| `CAP OK`                                             | `capability system ready`                                      |
| `IPC OK`                                             | `ipc endpoints ready`                                          |
| `IDT OK`                                             | `IDT installed`                                                |
| `TSS OK`                                             | `TSS installed`                                                |
| `PAT INIT OK slot4=WC`                               | `PAT initialised (slot 4 = write-combining)`                   |
| `HPET INIT OK period_fs=... freq_hz=...`             | `HPET initialised: period 10 ns, frequency 100 MHz`            |
| `TSC CALIBRATED hz=0x894d2452`                       | `TSC calibrated: 2.301 GHz`                                    |
| `X2APIC ABSENT`                                      | `x2APIC not present on this CPU`                               |
| `MCFG ABSENT`                                        | `ACPI MCFG table absent — PCI enumeration skipped`             |
| `PCI ENUM SKIP no MCFG`                              | (folded into the line above; do not emit twice)                |
| `KPTI OK` .. `KPTI DESC OK` (5 lines)                | `KPTI: page tables, scratch, stacks, ISR, descriptors ready`   |
| `CAP INVOKE MEM` (repeated N times)                  | (kept as `TRACE`, muted from the default transcript — §6)      |
| `CAP DENIED`                                         | `capability invocation denied (kind=..., reason=...)`          |
| `KIND_GPU_CONTEXT OK`                                | `kind_gpu_context: capability class registered`                |
| `KIND_TB_ROUTE OK`                                   | `kind_tb_route: capability class registered`                   |
| `KIND_TB_ROUTE FAIL`                                 | `kind_tb_route: capability class registration failed`          |
| `COOLING ROW row=... idx=... type=... ...` (7 lines) | `cooling zone 0 registered (idx=0, type=1, min=0, max=4, cur=0)` |
| `====== PANIC DUMP BEGIN ======`                     | `--- panic dump begin ---`                                     |
| `TRAP FRAME vec=... err=... rip=... cs=...`          | `trap frame: vec=0x0e (#PF), err=0x03, rip=0xdeadbeef, cs=0x08` |
| `EXC HALT`                                           | `unhandled exception — halted`                                 |

Every rewrite is a **message-body change only**. The prefix rewrite
in §2 is entirely separable from this list; the message rewrite can
land subsystem-by-subsystem after the prefix format is in place.


## 4. What must change at the emitter, and why

### 4.1 Timestamp composition (`emit.pdx` step 6)

Replace the current 16-hex-digit TSC dump with the two-part
seconds/microseconds path from §3.1. This needs three new helpers:

- `klog_t0_snapshot()` — one-shot latch called by `kernel_main` before
  the first klog emit.
- `klog_tsc_to_usec(tsc_delta)` — division by the calibrated TSC-Hz
  (`_tsc_hz_calibrated`) or the pre-HPET divisor.
- `u64_to_padded_dec(value, buf, width, pad_char)` — the current
  `u64_to_dec` is a "minimal digits" formatter; a padded variant is
  needed for the `sssss` and `uuuuuu` fields.

### 4.2 Level word (`emit.pdx` step 8)

Replace the single-byte `klog_level_letter` output with a five-byte
copy from a new lookup table:

```
LEVEL_WORDS : [[u8; 6]; 6] =
  ["PANIC", "ERROR", "WARN ", "INFO ", "DEBUG", "TRACE"]
```

Six bytes per entry (five chars + NUL) so the byte copy is a fixed
five-iteration loop, not a NUL-terminated walk. Storage: 36 bytes
`.rodata`, one lookup per emit.

### 4.3 CPU column (`emit.pdx` step 7)

Prepend the constant string `cpu` before the current one-hex-digit
output. When the boot-wide `_klog_cpu_width` sentinel is `2`, emit two
hex digits instead of one. Trailing space stays.

### 4.4 Subsystem word (`emit.pdx` step 9 + `subsys.pdx`)

Two options, both viable:

**(a) Change the subsystem strings in place.** Rewrite `SUBSYS_MM__` to
hold `"memory\0"`, `SUBSYS_CAP_` to `"cap\0"`, etc. Add a right-pad in
the composer so the printed width is always eight columns. Every
call site (`lea rdi, [rip + SUBSYS_XXXX]`) is unchanged.

**(b) Add a parallel table of long names.** Keep the current
`SUBSYS_XXXX` strings (some external tooling may still key on them);
introduce a matching `SUBSYS_XXXX_LONG` set and dispatch on which one
the emit path reads. This costs one indirection per emit and doubles
the `.rodata` for the tags.

Recommend (a). No external tool keys on the old strings (§5.1 impact
audit); the emitter is the single reader.

### 4.5 Concatenation fixes

There are two distinct bugs that both surface as "records glue
together":

**Bug A: raw `uart_puts` of a message without a terminating `\n`.**
The two witnessed cases (`ACPI FADT OK` at line 365 of the sample,
`GLOBAL LOCK OK` at line 443) come from stray direct `uart_puts` calls
that bypass the klog composer entirely. Their `_msg` string literals
lack a trailing newline, so whatever klog line the composer emits next
runs onto the same physical line.

**Root cause:** these are legacy fingerprint emits from before the
klog substrate landed and were never migrated. Every direct
`uart_puts` in the kernel outside the klog module itself, `present`,
and the AP hello witness is a candidate for migration to `klog_s1`.
The exact list is small — an audit of `grep -rn "uart_puts" src/kernel
--include="*.pdx" | grep -v 'core/klog'` returns roughly 20 call sites,
concentrated in `smp/ap_entry.pdx`, `drivers/xhci/*.pdx`, and a
handful of ACPI paths. Fix per-site: replace the raw `uart_puts` with
`klog_s1(LEVEL_INFO, SUBSYS_XXXX, k_message)` and drop the `\n` from
the tag string (the composer already emits it in step 12).

**Bug B: tag payload contains an embedded `\n`.** Witness:
`kind_cooling_device.pdx` declares
`cool_dbg_msg : [u8; 13] = "COOLING ROW\n\0"`, and the composer's tag
copy loop (`emit.pdx` step 10) copies bytes NUL-terminated. A `\n`
mid-string flushes an incomplete record and the caller then emits the
KV cluster in a follow-up line that arrives without a prefix.

**Root cause:** the tag was authored as a print-line for a debug
session, not as a tag. The fix is at the caller — remove the `\n`
from the string and let the composer emit the whole record (tag + KVs)
on one line. To make the mistake unrepeatable, add a compile-time
assert in `emit.pdx`'s tag-copy loop: if any byte matches `0x0A`, halt
with `PANIC: klog tag contains newline`. This turns a silent
transcript corruption into a boot failure the first time it happens.

### 4.6 Newline discipline in the composer

The composer already emits a single `\n` in step 12. The observed
double-newlines in the sample (blank line after most records) come
from `.pdx` code that emits *both* a fingerprint `_msg` via
`uart_puts` (with its own `\n`) *and* a klog line for the same event.
Consolidate: after the migration in Bug A above, the composer is the
only source of newlines, and every line ends with exactly one `\n`.


## 5. Compatibility contract

### 5.1 Golden fixtures

Audit result: **every** `expected-*.txt` and `*.golden` file under
`tests/` asserts message bodies only (`CAP OK`, `PAT INIT OK slot4=WC`,
`KPTI OK`). No fixture depends on the pipe delimiter, the hex
timestamp, the letter level, or the four-character subsystem tag.

The `tools/run-smoke.sh` matcher does an ordered-substring check
(§ line ~1683 of that file): a fixture line matches if it appears as a
contiguous substring, anywhere on any line, of the transcript.

Consequence: **the prefix rewrite in §2 breaks no golden.** A line
like

```
[    0.001217] INFO  cpu0 cap     : capability system ready
```

still contains the substring `CAP OK` in its old form? No — the message
body is also rewritten (§3.5). The rewritten body is `capability system
ready`, so any golden asserting `CAP OK` breaks.

**Two options for keeping goldens green through the message rewrite:**

- **(A) Rewrite goldens in the same commit as each subsystem.** The
  goldens are small (39 files, largest is 15 lines) and the message
  bodies are the only thing that changes; each rewrite is a
  one-file-in / one-file-out replacement.
- **(B) Keep the old message body as a suffix inside parentheses.**
  Emit
  ```
  [    0.001217] INFO  cpu0 cap     : capability system ready [CAP OK]
  ```
  Every golden still substring-matches; readers see the human
  narrative first, the fingerprint marker second. This is uglier but
  lets the message rewrite land subsystem-by-subsystem without a
  goldens flag day.

Recommend **(B) during migration, (A) as the final state.** The
bracketed legacy marker is a compile-time constant per emit site — a
`LEGACY_FINGERPRINT` symbol declared alongside each new
`k_message` string. When every subsystem is migrated and every golden
is rewritten, one commit removes the legacy suffix everywhere.

### 5.2 Coverage gate (`verify-fingerprint-coverage.sh`)

The gate extracts `"..."` string literals from `.pdx` sources and
checks each is asserted by some golden. It parses source syntax, not
transcript syntax. It is entirely indifferent to the prefix rewrite.

The message-body rewrite touches the gate: a new emit site
`k_capability_ready : [u8; 24] = "capability system ready\0"` must be
asserted by some golden. Under migration strategy (B) above the old
`CAP OK` string can stay in `.pdx` (emitted as the bracketed suffix),
so the gate sees the same set of markers throughout the migration.
The final flag-day commit that removes the suffix removes the old
strings and updates the goldens in the same diff.

### 5.3 Audit-log bridge (`emit.pdx` step 13.5)

`klog_audit_forward` is a byte-copy of the rendered line into the
audit ring. It is format-agnostic — it stores whatever bytes the
composer produced. Nothing changes.

### 5.4 Panic dump reader

`klog_ring_dump_panic` walks the ring byte-for-byte and emits every
byte to UART (and to the framebuffer console when live). It does not
parse. Nothing changes.


## 6. Runtime level and default transcript density

Today `_klog_runtime_level = 3` (INFO). Every `CAP INVOKE X` line is
`INFO` and clutters the transcript — a single boot has hundreds of
them because every subsystem-registration path does its capability
sanity check by invoking the capability once per KV field.

Recommended reclassification alongside the format rewrite:

- `CAP INVOKE X` → `TRACE` (still visible under `--verbose`, muted by
  default). One `capability class registered` line per class remains
  `INFO`.
- `IOMMU DOMAIN BIND` / `UNBIND` cluster → `TRACE`.
- `BATTERY ROW` / `THERMAL ZONE ROW` / `COOLING ROW` per-attribute
  emits → collapse into one `INFO` line per row (§3.5 discipline).

Effect on the sample transcript: a boot that today produces ~2500
serial lines drops to ~500 without losing information — the muted
lines are still in the ring buffer and reachable via `dmesg` when the
kernel later grows a dmesg syscall.

Compile-time gate (`KLOG_COMPILE_LEVEL`) stays at 3 during migration
so no `.pdx` source needs level changes.


## 7. Emitter wrappers that need to grow

The current per-arity wrappers stop at `klog_s1_x4` (four hex KVs) and
`klog_s1_x1_d1` (one hex plus one decimal). The message-body rewrite
in §3.5 collapses several multi-line emit clusters into single
records; two of these need arities the current wrappers do not have.

- Cooling zone row: 5 decimal KVs → need `klog_s1_d5`.
- Battery row: 6 mixed KVs → need `klog_s1_x1_d5` or `klog_s1_d6`.
- Backlight row: 5 decimal KVs → covered by `klog_s1_d5`.
- Trap frame: 4 hex + 1 hex vector name → covered by `klog_s1_x5` (new).

Add `klog_s1_x5`, `klog_s1_x6`, `klog_s1_d5`, `klog_s1_d6` following
the exact stack-frame discipline of the existing wrappers (KV entries
at `[rbp - N]`, caller pushes overflow args, `imul` by 24 for offset).

The compiler ABI cap of six register parameters remains; the fifth,
sixth, seventh, etc. arguments are passed on the stack by the caller,
same convention as `klog_s1_x3` and `klog_s1_x4` today.


## 8. Migration strategy

### 8.1 Phased rollout

1. **Phase A — timestamp + level + subsystem + CPU columns.** All
   prefix fields switched to the new format. Goldens still pass
   (substring semantics). Every message body untouched. One commit
   under `src/kernel/core/klog/` — no `.pdx` outside that directory is
   modified.

2. **Phase B — build-time toggle.** Introduce a
   `_klog_wire_format` constant (0 = old, 1 = new) so a bad release
   can be reverted by flipping one letter, not by reverting a wide
   commit. Compile-time only, no runtime cost. Retire the toggle at
   the end of Phase C.

3. **Phase C — message-body rewrite, subsystem-by-subsystem.** Each
   subsystem's emit sites are rewritten to English; the bracketed
   legacy suffix (§5.1 option B) keeps every golden green. Goldens
   are updated in the same commit as their subsystem's rewrite.
   Order of subsystems, cheap to expensive:
   - `boot`, `memory`, `time`, `int` (small, high-signal, few call sites)
   - `cap`, `ipc` (many call sites but simple messages)
   - `pci`, `apic`, `iommu` (moderate)
   - `nvme`, `xhci`, `e1000e`, `driver` (drivers — large, wait until pattern is well-tuned)
   - `tty`, `vfs`, `fs`, `task`, `sched`, `user` (subsystem-specific)
   - `panic` (last — this is the pattern-heaviest, and mistakes here are the most disruptive)

4. **Phase D — legacy suffix removal.** One commit deletes every
   `LEGACY_FINGERPRINT` bracket and updates every golden that still
   asserts the old marker. Coverage gate stays green because every
   deleted string is deleted from both source and fixture.

5. **Phase E — runtime level reclassification.** `CAP INVOKE X` and
   the other high-volume clusters move to `TRACE`. Default transcript
   density drops ~5x.

### 8.2 Rollback surface

Every phase leaves the fingerprint contract intact (Phase A because it
touches nothing after the prefix; Phase B..D because of the bracketed
suffix; Phase E because level filtering does not change the strings a
golden asserts).

A regression in any phase reverts to the immediately-prior phase with
a one-file revert.


## 9. Impact analysis

Measured from a clean tree, 2026-08-23:

| Surface                                          | Count | Change under this plan                     |
|--------------------------------------------------|-------|--------------------------------------------|
| `.pdx` files calling `klog_s1*`                  | 177   | 0 (Phase A) → ~all (Phase C, incremental)  |
| Individual `klog_s1*` call sites                 | ~800  | 0 (Phase A) → ~all (Phase C, incremental)  |
| Files with `SUBSYS_*` references                 | 178   | 0 (subsystem strings widen in place)       |
| Golden fixtures (`expected-*.txt` + `*.golden`)  | 39    | 0 (Phase A/B) → ~all (Phase C+D)           |
| Coverage-gate strings (`.pdx` `let ... = "..."`) | ~800  | 0 (Phase A/B) → ~all (Phase C+D)           |
| `tools/*.sh` scripts parsing prefix format       | 0     | 0 (none found — gate parses source only)   |
| Direct `uart_puts` calls to migrate (Bug A)      | ~20   | migrated once, before Phase A lands        |
| New wrappers in `wrappers.pdx`                   | 0     | 4 new arities (`_x5`, `_x6`, `_d5`, `_d6`) |
| Files edited in `src/kernel/core/klog/`          | 0     | 5 (`emit`, `level`, `subsys`, `wrappers`, one new `format` helper file) |

Phase A + B together are ≤ 6 files edited; every downstream number in
the table is a phased incremental cost, paid one subsystem at a time.


## 10. Open questions

- **Colour.** ANSI SGR would help human readability enormously
  (`ERROR` red, `WARN` yellow, `PANIC` bold red, subsystem in muted
  cyan). Terminals that capture to file keep the escape bytes. The
  bytes are visible ballast in a captured log grepped by tooling.
  Recommend: emit SGR only when a compile-time
  `_klog_colour = 1` is set; default 0.

- **Wall-clock timestamp.** Once the RTC is read (post-ACPI, deep in
  boot), a second timestamp form becomes possible:
  `[2026-08-23T15:04:12.031894Z]`. The dmesg-style `[    N.uuuuuu]`
  form has to stay for the pre-RTC lines; a dual-line format is ugly.
  Recommend: keep dmesg form only. Wall-clock time lives in the audit
  log's own header, not in the per-line prefix.

- **Structured JSON emit.** A machine consumer (a later dmesg
  syscall, a userspace log daemon) may want JSON. Recommend against
  emitting JSON on the UART: it is unreadable to a human, defeats the
  point of this rewrite, and the same information can be produced on
  demand by a userspace tool reading the ring buffer with the
  existing dmesg reader primitive (`klog_ring_read_tail`).

- **Long messages.** The composer's stack buffer is 256 bytes. A
  fully-rendered new-format line (32 prefix + 200 message) is 232
  bytes, fits with margin. If message length becomes a bottleneck the
  buffer grows in `emit.pdx` step's frame — no ABI or coverage-gate
  implication.


## 11. Recommendation

- **Land Phases A and B first**, as a single reviewable change to the
  five files under `src/kernel/core/klog/`. Every golden stays green
  by construction. The rest of the tree is unmodified.

- **After A/B is stable in main for one full boot cycle**, open the
  Phase C tickets — one per subsystem, in the order §8.1 lists. Each
  ticket is a self-contained diff: one subsystem's `.pdx` message
  bodies rewritten, its goldens updated, its coverage-gate strings
  moved.

- **Phase D is bookkeeping** — schedule after every Phase C ticket
  closes.

- **Phase E is optional** and worth deferring until after a dmesg
  syscall exists in userspace, so operators do not lose the muted
  lines when reclassification hides them from the default transcript.

The user-visible payoff arrives at Phase A: every line of the boot
transcript becomes legible. The transcript is not a machine dump any
more; it is a log.
