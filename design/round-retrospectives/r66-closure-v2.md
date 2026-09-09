# R66 v2 Retrospective: Shell polish tier 1 (real close)

**Date:** 2026-09-09
**Milestone:** R66.M1 v2 across `paideia-os/shell` (5 issues: #17–#21)
+ this monorepo's closure gate (`paideia-os/shell#27`, R66v2.SHL-001).
**Issues closed:** shell #17, #18, #19, #20, #21 (all landed); this
doc closes `paideia-os/shell#27` (the v2 closure gate).
**HEAD at closure:** paideia-os (this landing) — carries the retro;
substantive R66 work lives at `paideia-os/shell` HEAD `fea7f28`
(cursor-left/right in-place edit, the last of the five).
**paideia-as pinned at:** unchanged in this landing
(`tools/paideia-as` submodule at v0.34.0-derived `f0050dd`).
**Release tag:** `r66v2-closed` recommended on
`paideia-os/shell` HEAD `fea7f28` first (authoritative record of the
R66 body of work per v1's own stated discipline), then mirrored on
paideia-os HEAD landing this doc.
**Supersedes:** `design/round-retrospectives/r66-closure.md`
(deferred-close placeholder, unchanged per §4.4 of
`design/roadmap/rows-4-5-6-scoping.md`).

---

## Round intent

R66 v1 closed as a deferred-close placeholder (`r66-closure.md`) that
carried no claim about landing status — its whole thesis was "the real
work lives in `paideia-os/shell` and this monorepo can't see it from
inside a paideia-os-only session." R66 v2's job was to turn that
placeholder into a real close by (a) landing the five R66.M1 issues in
the shell repo end-to-end, (b) publishing the reference doc for the
line-editing surface in the paideia-os monorepo, and (c) recording
what actually shipped versus what the R66 v1 charter promised.

The v1 charter (per `design/user/shell-line-editing.md` and
`design/roadmap/rows-4-5-6-scoping.md` §4.4) was: raw-mode TTY input
with an ESC-sequence recognizer, backspace erase on-screen, a history
ring with up/down recall, cursor-left/right in-place edit, and a
design doc pinning the surface. All five landed. One deliberate
deferral — runtime activation of the raw-mode read path through the
cap-typed `KIND_TTY(read)` seam — carries over into R67 tracking; §"Debt
inventory" below records the shape of that deferral.

---

## Per-issue disposition (shell repo)

### shell#17 R66.M1-001 (raw-mode TTY input + ESC-sequence FSM) — LANDED

Commit `600d9d3`. Landed `LR_KEY_*` sentinels in the `0xFFFFEC5x`
band (disjoint from `LR_ERR_*` and raw bytes), the CSI-final lookup
`lr_csi_final_to_key`, and the three-state `lr_read_key` DFA
(`S_GROUND` / `S_ESC` / `S_CSI`) that sits between the byte seam
(`lr_read_one_byte`) and the line assembler
(`line_reader_read_line`). Scaffolded `lr_tty_set_raw` /
`lr_tty_set_cooked` that return `LR_ERR_TTY_UNBOUND` today per the
KIND_TTY seat deferral (see debt inventory). Added the seven-case
CSI/UNKNOWN offline test matrix in `tests/test_line_reader.pdx`.

Notable: `line_reader_read_line` was extended to *dispatch* on key
events (not raw bytes) so that #18/#19/#20 could each fill one
already-recognized branch without touching the seam again — the reason
the four issues could land as small, single-branch commits.

### shell#18 R66.M1-002 (backspace erase on-screen) — LANDED

Commit `5217702`. Filled the `LR_KEY_BACKSPACE` branch #17 had left as
a buffer-shrink no-op with the standard `\b \b` erase sequence, plus
the column-zero no-op (`count == 0` → suppress the write) so a stray
backspace before any input doesn't scribble the prompt.

### shell#19 R66.M1-003 (history ring + up/down recall) — LANDED

Commit `88580b5`. The heaviest of the five. Re-purposed the 8 KiB
`Shell::_sm_hist_buf` from wire-encoded records to flat text
(`<cmd><LF>` per entry), added three ring cursors
(`_sm_hist_head` / `_sm_hist_tail` / `_sm_hist_recall_cursor`),
consolidated the append + on-disk journal write into a single
`sm_hist_ring_commit` helper so the in-memory recall view and the
persisted journal cannot drift out of sync, and wired
`lr_recall_up` / `lr_recall_down` behind the previously-no-op
`LR_KEY_UP` / `LR_KEY_DOWN` branches. Emits
`shell history ok -- entries=<N>` on fd 2 after every commit via
`history_ring_witness`, which walks the ring live rather than
consulting a cached count.

The commit also carried a **retroactive `exec.pdx` alignment fix**
against the shell#44 baseline (see "Lessons learned" §L4).

### shell#20 R66.M1-004 (cursor-left/right in-place edit) — LANDED

Commit `fea7f28`. Added `_sm_line_cursor` and an 8 KiB
`_sm_line_edit_scratch` redraw compose buffer. Bound-checked
LEFT/RIGHT motion (`\b` and `ESC[C` respectively); mid-line INSERT via
`lr_insert_mid` (shift tail right, single `sys_write` of
`byte + tail + \b × tail_len`); mid-line BACKSPACE via `lr_bs_mid`
(shift tail left, single `sys_write` of
`\b + tail + space + \b × (tail_len + 1)`). ENTER short-circuits before
cursor dispatch so a mid-line RETURN still submits the whole buffer.
UP/DOWN recall sets `cursor := new_count` so the next literal appends
normally.

### shell#21 R66.M1-005 (design doc `shell-line-editing.md`) — LANDED

Commit `9534b73` in paideia-os (design docs live in the monorepo, not
the satellite). Pins the raw-mode entry/exit protocol, the ESC-DFA,
the `SK_*` key-code band, the dispatch table, the backspace redraw,
the in-place cursor edit, and the 8 KiB history-ring semantics. This
is the reference doc every subsequent shell polish round (R73 tier 2
and later) must read before touching `line_reader.pdx`.

---

## Per-issue disposition (paideia-os monorepo)

### paideia-os/shell#27 R66v2.SHL-001 (v2 closure retro) — LANDED

This document. No `.pdx`, kernel, or userland code changed on the
paideia-os side; the retro is the whole scope. Closes the v2 gate.
The v1 `r66-closure.md` deferred-close placeholder stays unchanged per
§4.4's explicit instruction ("v1's `r66-closure.md`, a deferred-close
placeholder, stays as-is").

---

## Cross-repo escalations to paideia-as (R66 v2)

**None from this round.** Every alignment / encoder pitfall the round
uncovered was resolved inside the shell repo by adjusting the shell's
prologue shape, not by changing paideia-as. The paideia-as submodule
pin (`f0050dd`, v0.34.0-derived) is unchanged by this closure; the
version discipline lesson in §L1 is a *usage* lesson, not an
escalation.

For contrast: R66 v2 *did* consume prior cross-repo landings — the
KIND_TTY substrate ops from R66v2.POS-001 / POS-002 (`#1986` /
`#1987`) are pre-landed, so #17's scaffolded raw-mode helpers reference
the ordinals directly. That the shell can't yet *invoke* them at
runtime is not a paideia-as gap; see debt inventory §D1.

---

## Observable proof

Live-boot observable proof of R66 v2 is *not* provided from
paideia-os's `bash tools/run-qemu.sh` — the shell doesn't yet run
inside the paideia-os smoke as a foreground interactive. Instead the
proof stack is:

1. **Shell-repo unit tests** (`bash tools/build.sh` + the harness the
   shell repo carries). `tests/test_line_reader.pdx` covers the
   ESC-DFA and every recognized CSI final; `tests/test_tokenizer.pdx`
   (#42, landed alongside #17) covers the tokenizer surface the shell
   invokes on committed lines.
2. **Fingerprints emitted at runtime** when the shell is exec'd
   against a real TTY (once the KIND_TTY seat deferral in §D1 clears):
   `shell history ok -- entries=<N>` on every commit. #17-#20 add no
   dedicated fingerprints of their own — the design doc (#21) at
   `design/user/shell-line-editing.md` §7's worked examples are the
   reference for what the visible output should look like keypress by
   keypress.
3. **The shell repo's own tag `r66v2-closed`** on `fea7f28`
   (recommended cut once this retro lands and the v2 gate is closed).
   That tag, not this doc, is the *authoritative* record of what
   shipped — this doc points at it.

The v1 discipline holds: "the authoritative R66 completion record
lives in `paideia-os/shell`, not here."

---

## Debt inventory at R66 v2 close

### D1 — KIND_TTY(read) seat deferral (carried forward, not blocking R66 v2 close)

`lr_tty_set_raw` / `lr_tty_set_cooked` return `LR_ERR_TTY_UNBOUND`
today. `TTY_OP_READ` (ordinal 6, gated by `R_TTY_READ = 0x080`) *is*
landed on the kernel side (R66v2.POS-001, `#1986`), and the raw-mode
witness (`#1987`) proves the substrate works. What still blocks the
shell-side seam swap is two paideia-os follow-ups the shell repo
tracks at `#46`:

- `KIND_TTY` (0x197) is absent from `KIND_SEEDABLE_TABLE` in
  `src/kernel/core/cap/kind.pdx` — the loader cannot mint a
  `KIND_TTY` row into a fresh cap_table row by kind alone.
- No shell-time TTY-row seed exists at boot — even if the loader
  learned to mint one, nothing binds a live `KIND_TTY` row into the
  shell's cap_table at process spawn.

Until both land, `line_reader_read_line` reads bytes via the VFS
`sys_read(0, ptr, 1)` fd-0 path (which works in the live boot today
via `KIND_PDXFS_FILE` on `/dev/tty0`), and the raw-mode entry/exit
helpers stay stubbed. R66 v2 is *not* held for this: the whole line
of prior R66 v1 discipline was that the shell-repo code shipping
under the fd-0 path *is* R66 tier-1's real deliverable, and the
cap-typed migration is a separate seam swap the shell repo already
tracks under `#46`. See `design/architecture.md` §3.3 in the shell
repo for the full ledger.

### D2 — R106 tokenizer / R73 tier-2 not in scope

Reminder for future audits: #22–#26 in the shell repo (R73 tier 2) are
open but explicitly out of R66 v2's scope per §4.4. R106 tokenizer
(`#42`, landed alongside #17 at `a1b2d9b`) is scaffold-adjacent — its
test infrastructure landed with the R66 batch for scheduling
convenience only, not because R106 is part of R66.

### D3 — Fingerprint coverage

The R66 body of work contributes exactly one runtime fingerprint
(`shell history ok -- entries=<N>` from `history_ring_witness`). No
paideia-os `tools/verify-fingerprint-coverage.sh` allowlist change is
needed on this landing — the shell's fingerprints are its own
observable surface, verified by the shell repo's harness. When the D1
seat clears and the shell runs foreground in a paideia-os boot smoke,
that allowlist would extend to cover this line; the extension is a
follow-up, not part of R66 v2's close.

---

## Lessons learned

### L1 — paideia-as version discipline: pin, don't drift

The R66 round shipped against paideia-as `f0050dd` (v0.34.0-derived,
per the submodule pin). Every encoder pitfall the round hit was
resolvable within that pin — no version bump was required, and one
was *not taken opportunistically*. The lesson pairs with the standing
"paideia-as version discipline" memory: the assembler is the
kernel-repo's own dependency, and rounds that don't need a bump should
not take one, precisely so that rounds which *do* need one land the
bump in isolation, next to the design doc that justified it, and next
to the CHANGELOG entry that names the new intrinsic or opcode. R66 v2
touched none of that machinery, and this retro does not bump the
submodule pin.

If a subsequent round (R73 tier-2 or beyond) discovers a genuine
paideia-as gap while implementing line-editing polish — an encoder
pitfall that cannot be worked around at the shell — the fix belongs
in paideia-as with its own version bump + workspace.version + git tag
+ CHANGELOG entry, per the cross-repo escalation discipline. R66 v2
did not exercise that path.

### L2 — `r11` is paideia-as reserved scratch for `.bss` LEA; keep the shell's use pattern uniform

Across `dispatch.pdx`, `command_record.pdx`, `line_reader.pdx`, and
the R66 v2 additions, `r11` is used exclusively as
`lea r11, [rip + <bss_symbol>]` staging for a subsequent
`mov [r11 + <offset>], <reg>` — never as a general-purpose scratch
that outlives one `.bss` reach. The R66 v2 additions kept that
pattern (see the `lr_recall_up` justification in `line_reader.pdx`,
which walks four different `.bss` symbols each via its own `lea r11`).

The pitfall this discipline heads off: `and r11, imm64` is one of the
paideia-as encoder pitfalls flagged in the standing pdx-encoder memo.
By keeping `r11` scoped to "loaded, immediately dereferenced, then
overwritten by the next `lea`", the shell never emits an operation
against `r11` that would need a wide-immediate `and` / `or` mask —
those go through `r10`-staged compare-and-jump sequences instead. The
R66 v2 recall helpers follow this exactly (`lr_recall_up`'s modular
arithmetic uses `cmp+jb+xor` / `cmp+je+xor` sequences with immediates
that fit `imm32`, precisely to avoid an `r11`-staged compare).

### L3 — Debugger caught the alignment landmine that CI can't

The most consequential lesson of R66 v2 is one shell#19 records
verbatim in its commit body: shell#44's `exec_spawn_and_wait` had a
5-push prologue + `sub rsp, 8`, which moves `rsp % 16` from 8 to 0 at
entry to the prologue's own body but leaves `rsp % 16 == 8` at every
nested `call` (each `call` pushes an 8-byte return address). Every
`sys_write` / `history_format_u64_dec` / `sys_wait4` call in that
frame was silently misaligned from shell#44's landing (2026-08-25 area)
until the R66.M1-003 debugger pass caught it (2026-09-08). Fix was
retroactive: remove the `sub rsp, 8`, since 5 pushes alone give
`rsp % 16 == 0` after the `call`-pushed return address is accounted
for.

The build was green throughout that window — the misalignment was a
live SSE-alignment landmine on the fork/exec path that would surface
only when a nested syscall (or a compiler-emitted SSE spill) actually
tripped over unaligned `%rsp`. **Green build ≠ verified diff** (the
standing "debugger every iteration" memory earned this instance). The
lesson for future rounds: **prologue alignment is a debugger-pass
concern, not a build concern**, and the debugger must re-derive
`rsp % 16` at every nested call site in every helper the round
touches — a single overlooked `sub rsp, 8` under N pushes with the
wrong parity is exactly the shape of bug the build cannot see.

The R66.M1-004 (#20) helpers landed with the alignment discipline
already baked in: `lr_bs_mid` even pushes `r12` purely for 5-push
parity, with an explicit comment marking the push as mathematically
required (not aesthetic). That is the right shape for the discipline
going forward.

### L4 — The `r12`-as-base refactor is the shape R66/R73 polish will keep needing

R66.M1-001 (#17) shipped `line_reader_read_line` with `r12` as a
walking cursor — fine for the append-only fast path #17 needed.
R66.M1-003 (#19) had to flip that: recall helpers set the buffer
length directly (`r14 := new_count`), so `r12` had to become the
buffer *base* (immutable across the call) with byte writes going
through `mov_b [r12 + r14 * 1], rax`. That single refactor unlocked
both #19 (recall replaces the whole line) and #20 (cursor motion needs
the base to compute `buf + cursor`) without touching either helper's
own register plan.

The generalizable lesson: **when a shell builtin adds a new
byte-motion primitive against a shared buffer, the buffer base should
land as an immutable register (typical: `r12`) from the first commit
that anticipates more than append-only writes**. Doing the flip
in-place (as R66.M1-003 did) works but forces every follow-up commit
in the round to re-verify no walking-cursor assumption survives. The
R73 tier-2 issues (kill-line, kill-word, transpose-chars — #22–#26)
will each add another byte-motion primitive against the same buffer;
the R66 v2 refactor means they inherit the base-register discipline
for free rather than each round having to re-establish it.

### L5 — Alignment fixes are safe to bundle with substantive commits when the touched surface overlaps

shell#19's commit body is a hybrid: R66.M1-003's history ring + a
retroactive alignment fix against shell#44's `exec_spawn_and_wait`.
The alternative — landing the alignment fix as its own commit against
its own issue — would have been cleaner in isolation but would have
left the fork/exec path misaligned across the intervening window while
#19's review lane cleared. The commit chose the honest shape: both
bodies fit in one review, both are named in the subject line
(`Fix #19: R66.M1-003 history ring + up/down recall + retroactive #44
alignment fix`), and the CHANGELOG carries both under the same
`Unreleased` heading. Future rounds should bundle only when (a) the
debugger pass on the substantive commit is the *reason* the retroactive
fix was discovered, and (b) leaving the retroactive fix unlanded
across the review window carries genuine risk (here: a live SSE-
alignment landmine). Both held for shell#19; the retro records it as
an intentional pattern, not a slip.

---

## Round v2 close checklist

- [x] shell #17 landed (`600d9d3`)
- [x] shell #18 landed (`5217702`)
- [x] shell #19 landed (`88580b5`, incl. retroactive #44 alignment fix)
- [x] shell #20 landed (`fea7f28`)
- [x] shell #21 landed (`9534b73` — design doc in paideia-os)
- [x] R66v2.SHL-001 (paideia-os/shell#27) closed by this retro
- [ ] `r66v2-closed` tag on `paideia-os/shell` at `fea7f28`
      (recommended, not landed by this doc — the shell repo cuts its
      own tag)
- [ ] `r66v2-closed` tag on paideia-os at this landing (recommended,
      mirrors the shell tag)

R66 tier-1 is done. The KIND_TTY seat deferral (D1) is the only
open thread, and it's a separately-tracked shell-repo issue (#46),
not an R66 hold-over.
