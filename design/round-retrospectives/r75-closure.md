# R75 Retrospective (DEFERRED): ACPI S3 sleep/resume

**Date:** 2026-08-25
**Milestone:** R75.M1 (single-milestone round)
**Issues:** 0 landed / 1 partial (#1945) / 6 deferred (#1946, #1947,
#1948, #1949, #1950, #1951); this doc closes #1952.
**HEAD at audit:** paideia-os bbb3d35 (fresh worktree, no code changes
made by this audit).
**Release tag:** none cut — this round has no forward-progress
substrate to close on; recommend leaving the milestone open rather
than tagging `r75-closed` against essentially unstarted work.

## Round intent

Per `design/roadmap/post-r60-daily-use-roadmap.md:367-383`: "Laptop
actually suspends. Table-stakes for daily use." The plan explicitly
allowed `_PTS(3)` to be M0-stubbed as a direct FADT `PM1a_CNT` write
(bypassing the AML interpreter dependency), which is the only reason
any of this round has even partial code behind it.

## Why this round audits as mostly not started

Unlike R76/R77/R81/R83/R84, which all inherited a substantial
driver-scaffold corpus from earlier rounds (R32-R34), **no S3-specific
code exists anywhere in this tree.** An exhaustive grep across `src/`
for `PM1a_CNT`, `SLP_TYP`, `SLP_EN`, `_PTS`, `_WAK`, `waking_vector`,
`suspend`/`resume`, and `_LID`/lid turns up exactly one relevant hit:
`src/kernel/acpi/fadt.pdx`, which resolves the `PM1a_CNT_BLK` /
`X_PM1a_CNT_BLK` port address — but that parsing landed at R20.M3/
R30.M4/R31.M6 for the **ACPI Global Lock protocol** (`aml_glk.pdx`),
not for S3. It is a genuine, reusable prerequisite, not S3 work in
disguise.

There is no driver-model `suspend()`/`resume()` callback anywhere
(`grep -rn 'suspend\|resume' src/kernel/core/driver/` outside the
FADT parse-comment matches above returns nothing), no code that
constructs or writes a `SLP_TYPa | SLP_EN` value, no waking-vector
install/jump path, no `_WAK` invocation, and no lid-close-to-sleep
dispatcher (`_LID` does not appear in `src/kernel/core/acpi/` or
`src/user/aml/` at all, despite EC event plumbing existing there for
other purposes).

## Per-issue disposition

### #1945 — `_PTS(3)` invocation / M0 FADT PM1a_CNT direct write — PARTIAL
The one prerequisite this milestone can build on already exists:
`src/kernel/acpi/fadt.pdx` (502 lines) resolves `pm1a_cnt_port` (legacy
`PM1A_CNT_BLK` at offset 64, X_-preferred override at offset 172 per
ACPI 6.5 §4.1.3) into a 64-byte `fadt_info` struct, `FADT_INFO_OFFSET_
PM1A_CNT = 8`. This is exactly the port address the M0 stub needs to
target. **Gap:** nothing constructs the `SLP_TYPa` value (codec's
`\_S3` package, byte 0) or `SLP_EN` (bit 13) and writes it to that
port — the write side does not exist. PARTIAL: address resolution
landed (incidentally, via R31.M6 Global Lock work), value-construction
and write do not exist.

### #1946 — Device state save / suspend() driver callback — DEFERRED
No driver-model callback for suspend exists. `grep -rn 'suspend'
src/kernel/core/driver/` (the generic driver-framework directory)
returns nothing. This needs a new callback slot added to whatever
per-driver vtable/registration struct the framework uses — real,
unstarted work, not hardware-gated.

### #1947 — Cache flush + final PM1a_CNT write (SLP_TYPa\|SLP_EN) — DEFERRED
Depends on #1945's missing write half and #1946's missing device-quiesce
step. No `wbinvd`/cache-flush call site found near any ACPI code.
DEFERRED.

### #1948 — Wake path: firmware jumps to waking vector — DEFERRED
No waking-vector install (FACS `FIRMWARE_WAKING_VECTOR` write) or
real-mode/16-bit resume trampoline exists anywhere in `src/boot/` or
`src/kernel/boot/`. This is the single largest missing piece — a
correct implementation needs a low-memory resume stub reminiscent of
the AP trampoline (`src/kernel/core/smp/ap_trampoline_relocate.pdx`)
but for S3, which does not exist. DEFERRED.

### #1949 — `_WAK` + device state restore — DEFERRED
No `_WAK` invocation call site (the generic `aml_eval_method` mechanism
from R78/R30 could invoke it once resolved, but nothing in `src/user/
aml/` or `src/kernel/core/acpi/` calls it), and no device-restore
callback (mirror of #1946's missing suspend callback) exists. DEFERRED.

### #1950 — Lid-close detection via EC to sleep entry — DEFERRED
The EC event plumbing this would ride on (`ec_event.pdx`, `ec_route.pdx`
in `src/kernel/core/acpi/`, landed at R31) is real and reusable, but no
`_LID` NameSeg resolution or lid-specific dispatcher exists — `grep -rli
'lid\|_LID'` across `src/kernel/core/acpi/` and `src/user/aml/` returns
nothing. This is a new consumer of the existing `_Qxx`-style EC dispatch
template (the same template R78's retro flagged as reusable for GPE
`_Lxx`/`_Exx`), not yet written. DEFERRED.

### #1951 — Boot smoke `boot_r75_s3_cycle` — DEFERRED
Does not exist (`find tests tools -iname '*r75*' -o -iname '*s3*'`
returns nothing). Cannot be written meaningfully without #1945-#1950
landing first, and even then it is real-T14-G4-hardware-only: QEMU/OVMF
S3 support is notoriously unreliable and the fingerprint (RTC-alarm
wake, verified state restore) is not something this environment can
produce. DEFERRED, no forward progress possible here regardless of
code state.

### #1952 — Round closure — this document
STATUS + retrospective, following the R58/R59/R74/R78 partial-close
precedent — except this round has essentially no code to partially
close *on*. No `r75-closed` tag recommended; see Debt inventory.

## Cross-repo escalations

None. No paideia-as language/toolchain defect was found while auditing;
the absence here is scope that was never implemented, not a toolchain
blocker.

## Observable proof

None beyond the FADT `PM1a_CNT` port-resolution field, which already
has boot-witness coverage from its original R31.M6 landing
(`src/kernel/boot/witness/r30_platform.pdx` family). No S3-specific
observable exists because no S3-specific code exists.

## Debt inventory (carried forward)

1. **`SLP_TYPa`/`SLP_EN` write path** (#1945's remainder) — construct
   the value from the `\_S3` package (needs either a synthetic-DSDT
   `\_S3` fixture or the AML evaluator's generic method-invocation
   path from R78/R30) and write it to the already-resolved
   `pm1a_cnt_port`.
2. **Driver suspend()/resume() callback slots** (#1946/#1949) — new
   framework surface, not yet designed.
3. **S3 resume trampoline** (#1948) — a low-memory wake stub, likely
   modeled on the existing AP-boot trampoline
   (`src/kernel/core/smp/ap_trampoline_relocate.pdx`) but for the S3
   waking vector.
4. **`_LID` dispatcher** (#1950) — new EC-event consumer, template
   available from the existing `_Qxx` dispatch in `aml_ec.pdx`.
5. **`boot_r75_s3_cycle`** — write once (1)-(4) land; real-hardware-only
   regardless.

**Next round:** given how little of this round exists, recommend
either (a) scoping a dedicated R75-redux planning pass to break
#1945-#1950 into buildable sub-issues before further audit passes, or
(b) resuming the roadmap at R76/R81/R83/R84 (all of which have
landed scaffolds and are purely hardware-blocked) while R75 waits for
a real-hardware session or a scoped implementation pass.
