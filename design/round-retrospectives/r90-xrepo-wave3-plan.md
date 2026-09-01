# R90-XREPO Wave-3 Plan — Substrate Rounds #1996/#1997/#2000/#2002

Design-only planning document. No code changes proposed here; each sub-issue
below is intended to be filed by a separate agent (mirroring the
networking-plan flow) and then landed via the standard project loop
(softarch → main-build → debugger → commit per iteration).

## §1. Overview

This plan expands four omnibus R90-XREPO tracker issues into landable
sub-issues that each fit the one-loop-per-issue tempo.

| Parent | Title (short) | Sub-issues | New R90-XREPO # |
|--------|---------------|-----------:|-----------------|
| #1996  | R42 PdxFS syscall substrate                | 8  | .010 |
| #1997  | Elevate broker dispatch + policy           | 7  | .011 |
| #2000  | svc.schema-registry stand-up               | 9  | .012 |
| #2002  | Exec-time cap reconciliation (adoption)    | 15 | .013 |
| **Total** |                                        | **39** | |

The next-available R90-XREPO integer is **010** (001–009 are already
filed per `gh issue list --search R90-XREPO`). This plan claims 010–013.

All sub-issues follow existing project conventions:

- Fingerprint discipline: every kernel-side sub-issue lists a boot witness.
- Encoder-conservative: any new sysno reserves its number and lands a
  minimal handler + witness before any consumer wiring.
- Body template: **Scope** (2–4 sentences) · **Files touched** ·
  **Fingerprint** · **Effort** (S/M/L) · **Deps**.
- Cross-repo sub-issues explicitly name their target repo.

Numbering convention (from #1995–#2003 and the M1..Mn convention used
in prior R90 rounds): `R90-XREPO.<NNN>.M<M>-<seq> <short-title>`, where
`M` is a wave inside the sub-round and `<seq>` is a 3-digit ordinal.

---

## §2. R90-XREPO.010 — PdxFS syscall substrate completion (parent #1996)

Foundational R42 wave. Every sub-issue is monorepo-side
(`paideia-os/paideia-os`). Sysno reservations follow the
`design/user/syscall-table.md` conventions refreshed in R90-XREPO.009
(#2003). Available sysno block from that refresh: 96+ (527 already
reserved out-of-band for `sys_pdxfs_fault_inject`).

### R90-XREPO.010.M1-001 KIND_PDXFS_FILE READ_BYTES op

**Scope:** Add a real byte-range read op to the `KIND_PDXFS_FILE`
handler (today only `QUERY_*` and `DEBUG_PRINT` exist). Op copies
`[offset, offset+len)` from the file's data extents into a caller
buffer, returning bytes-read + EOF marker. Backs `sys_pdxfs_read` at
the kind-dispatch layer.

**Files touched:** `src/kernel/core/fs/pdxfs/kind_pdxfs_file.pdx`,
`src/kernel/syscall/sys_pdxfs_read.pdx`,
`design/kernel/pdxfs-syscalls.md` (new or extended),
`design/user/syscall-table.md`.

**Fingerprint:** Boot witness reads a 4 KiB seeded file back byte-exact
via `sys_pdxfs_read` and prints the SHA of the returned buffer
(or content hash) matching the seed.

**Effort:** M

**Deps:** none. Unblocks doc.ENH-022 (`file_read_stub`) and lifts the
last real constraint on `cat`.

### R90-XREPO.010.M1-002 sys_pdxfs_stat_by_inode (mode/size/mtime)

**Scope:** Introduce `sys_pdxfs_stat_by_inode` returning at minimum
`mode_bits`, `size_bytes`, `mtime_ns` for an inode number. Extends the
existing readnext 128-byte record only inside the stat path (do not
widen readnext yet — that is .010.M1-006). Reserve next sysno.

**Files touched:** `src/kernel/core/fs/pdxfs/stat.pdx` (new),
`src/kernel/syscall/dispatch.pdx`,
`design/kernel/pdxfs-syscalls.md`, `design/user/syscall-table.md`.

**Fingerprint:** Boot witness stats a known-mode/size/mtime seeded
inode and prints all three fields matching seed constants.

**Effort:** M

**Deps:** .010.M1-001 recommended for shared inode-lookup helper; not
strict.

### R90-XREPO.010.M1-003 sys_pdxfs_txn_commit / sys_pdxfs_txn_abort

**Scope:** Complete the R42 transaction API — `txn_open` (sysno 70)
already exists; add matching `txn_commit` and `txn_abort` that
finalize/discard the WAL frame opened by `txn_open`. Handler must be
idempotent on double-commit (return error, no crash).

**Files touched:** `src/kernel/core/fs/pdxfs/txn.pdx`,
`src/kernel/syscall/dispatch.pdx`, `design/kernel/pdxfs-syscalls.md`,
`design/user/syscall-table.md`.

**Fingerprint:** Boot witness opens a txn, writes to it, commits, and
observes the write survive a WAL replay; a second witness aborts and
observes the write reverted.

**Effort:** M

**Deps:** none (sysno 70 substrate already lives).

### R90-XREPO.010.M1-004 sys_pdxfs_undo_write persistence

**Scope:** Add `sys_pdxfs_undo_write` that appends an undo record
(pre-image + inode + offset + length) to the per-file undo log
(satisfies the I5 invariant for cp/mv/rm). Log format documented in
design; readback is deferred to a future round.

**Files touched:** `src/kernel/core/fs/pdxfs/undo.pdx` (new),
`src/kernel/syscall/dispatch.pdx`,
`design/kernel/pdxfs-undo-log.md` (new),
`design/user/syscall-table.md`.

**Fingerprint:** Boot witness writes an undo record, then a second
witness reads it back from the on-disk undo-log region and verifies
pre-image bytes match.

**Effort:** M

**Deps:** .010.M1-003 (undo records only meaningful inside a txn).
Blocks cp.ENH-002/003/007, mv.ENH-003, rm.ENH-005.

### R90-XREPO.010.M1-005 sys_pdxfs_fault_inject (sysno 527)

**Scope:** Land the pre-reserved `sys_pdxfs_fault_inject` (sysno 527
per mv/rm design docs). Fault classes at v1: WAL-write-fail,
inode-alloc-fail, extent-alloc-fail, undo-append-fail. Behind a
kernel-boot flag; refuses to arm in release builds without the flag.

**Files touched:** `src/kernel/core/fs/pdxfs/fault_inject.pdx` (new),
`src/kernel/syscall/dispatch.pdx`, `design/kernel/pdxfs-fault-inject.md`
(new), `design/user/syscall-table.md`.

**Fingerprint:** Boot witness arms `WAL_WRITE_FAIL`, issues a write,
observes the expected `ERR_IO`, then disarms and observes success.

**Effort:** M

**Deps:** .010.M1-003 (txn machinery), .010.M1-004 (undo hooks). Enables
the mv.ENH-001 stack-imbalance-under-fault harness that never existed.

### R90-XREPO.010.M1-006 Real multi-entry readdir replacing 3-entry stub

**Scope:** Replace the fixed 3-entry stub returned by the current
readdir path with a real iterator over the directory's data extents.
Extend the readnext record only as necessary to carry inode + name-len
+ name; keep 128-byte record boundary if possible, escalate to
variable-length if the design demands it (document the choice).

**Files touched:** `src/kernel/core/fs/pdxfs/readdir.pdx`,
`design/kernel/pdxfs-syscalls.md`, `design/user/syscall-table.md`.

**Fingerprint:** Boot witness populates a directory with 17 seeded
names of varying lengths, iterates via readdir, prints all 17 sorted
back; witness asserts count and byte-exact name match.

**Effort:** L

**Deps:** none. Blocks `cp -r`, directory-aware `ls`, and any
recursive-traversal consumer.

### R90-XREPO.010.M1-007 cwd-semantics decision + implementation for sysno 517

**Scope:** Settle the shared cwd-resolution semantics for sysno 517
across mv/rm/cp relative-path resolution (R86 follow-on). Two axes to
pick: (a) does cwd resolution follow the invoker's cwd cap or the
first-supplied file's parent, and (b) is a leading `./` significant?
Land the decision in a short design doc, then implement.

**Files touched:** `src/kernel/syscall/sys_cwd_resolve.pdx` (or
current owner of 517), `design/kernel/cwd-semantics.md` (new),
`design/user/syscall-table.md`.

**Fingerprint:** Boot witness sets a distinguished cwd, resolves three
representative relative paths (`foo`, `./foo`, `sub/foo`) and prints
the resolved absolute paths matching design-doc expectations.

**Effort:** M (design-heavy, code light)

**Deps:** none. Blocks mv/rm/cp relative-path consistency work in
their respective satellite repos.

### R90-XREPO.010.M1-008 R42 design-doc consolidation + syscall-table.md refresh

**Scope:** Close-out sub-issue. Consolidate the per-sub-issue design
docs (`pdxfs-syscalls.md`, `pdxfs-undo-log.md`, `pdxfs-fault-inject.md`,
`cwd-semantics.md`) into a single R42-substrate index, and refresh
`design/user/syscall-table.md` through the last sysno assigned in
.010.M1-001…007 (mirror the R90-XREPO.009 pattern).

**Files touched:** `design/kernel/r42-substrate-index.md` (new),
`design/user/syscall-table.md`.

**Fingerprint:** n/a (docs-only). Verification: every new sysno
introduced in .010.M1-001…007 appears in `syscall-table.md` with a
matching row.

**Effort:** S

**Deps:** all of .010.M1-001…007.

---

## §3. R90-XREPO.011 — Elevate broker dispatch + policy (parent #1997)

All monorepo-side except .011.M1-006 (client library in
`paideia-os/libpdx-elevate`).

### R90-XREPO.011.M1-001 R51 scheduler-wait syscall dependency

**Scope:** Land the R51 scheduler-wait syscall the broker's blocking
wait depends on (block-on-condition-var equivalent, with wake by
kernel-side notify). Broker consumes it; other services will follow.
Independent of any policy decision.

**Files touched:** `src/kernel/core/sched/wait.pdx`,
`src/kernel/syscall/sys_sched_wait.pdx`,
`design/kernel/sched-wait.md` (new), `design/user/syscall-table.md`.

**Fingerprint:** Boot witness parks a thread on a wait-key, a second
thread notifies the key, first thread returns; witness asserts
wall-clock delta > 0.

**Effort:** M

**Deps:** none. Foundational for .011.M1-003.

### R90-XREPO.011.M1-002 elevate_channel_row_set_expire

**Scope:** Add `elevate_channel_row_set_expire` referenced by
libpdx-elevate design docs as pending. Sets a monotonic-tick expiry
on a per-channel row; expired rows are reaped on next dispatch scan
(reap policy documented, not necessarily eager).

**Files touched:** `src/kernel/core/cap/kind_elevate_channel.pdx`,
`design/security/elevate-broker.md` (new or extended),
`design/user/syscall-table.md`.

**Fingerprint:** Boot witness sets a 100 ms expiry on a channel row,
waits 200 ms, observes the row is refused on next dispatch attempt
with `ELVC_ERR_EXPIRED`.

**Effort:** S

**Deps:** none.

### R90-XREPO.011.M1-003 Broker daemon dispatch body

**Scope:** Replace `ELVB_DISPATCH_STUB` with real dispatch: consult
`/system/policy` (format defined in .011.M1-004) to grant/deny each
`elevate_client_request` and return the real ALLOW/DENY through the
`KIND_ELEVATE_CHANNEL` reply path (no more `ELVC_ERR_TIMEOUT`). Uses
sched-wait (.011.M1-001) for its blocking loop.

**Files touched:** `src/kernel/services/elevate_broker.pdx`,
`src/kernel/core/cap/kind_elevate_channel.pdx`,
`design/security/elevate-broker.md`.

**Fingerprint:** Boot witness — an unprivileged process requests
elevation for a `/system/`-rooted path, receives a real ALLOW/DENY
from a live broker (not `ELVC_ERR_TIMEOUT`); a second variant with a
denied class returns DENY.

**Effort:** L

**Deps:** .011.M1-001 (sched-wait), .011.M1-002 (row expiry),
.011.M1-004 (policy file).

### R90-XREPO.011.M1-004 /system/policy file format + seeding

**Scope:** Define the on-disk `/system/policy` schema (JSON-flavored
PdxRecord, versioned, minimal at v1: rule = {class, path-prefix,
decision}), and seed a default policy at boot into the rootfs. Design
doc plus seed-file wiring in `bin_seeds.pdx` (R90-XREPO.001 pattern).

**Files touched:** `src/kernel/boot/bin_seeds.pdx`,
`src/kernel/services/policy_loader.pdx` (new),
`design/security/policy-file-format.md` (new).

**Fingerprint:** Boot witness parses the seeded `/system/policy`,
prints its rule count matching the seed, and returns one rule by
class lookup.

**Effort:** M

**Deps:** none (independent design + seed).

### R90-XREPO.011.M1-005 uej_append tick_ns population

**Scope:** Populate the currently-zero `tick_ns` field in
`uej_append` (elevate journal audit trail). Source: the kernel's
monotonic-tick clock. Small fix but user-visible in audit records.

**Files touched:** `src/kernel/services/elevate_broker.pdx` (or
wherever `uej_append` lives), `design/security/elevate-broker.md`.

**Fingerprint:** Boot witness triggers two elevate events ~50 ms
apart, reads both audit records back, asserts `tick_ns` non-zero and
monotonically increasing.

**Effort:** S

**Deps:** none.

### R90-XREPO.011.M1-006 libpdx-elevate client-side reconciliation

**Scope:** Update `libpdx-elevate` client API to differentiate the
three broker outcomes now possible (ALLOW / DENY / TIMEOUT) rather
than the current advisory status collapse. Applies the org-wide
policy decision (.011.M1-007) at the client boundary so consumers
stop guessing.

**Files touched (in `paideia-os/libpdx-elevate`):**
`src/elevate_client.pdx`, `README.md`, tests.

**Target repo:** `paideia-os/libpdx-elevate`.

**Fingerprint:** Repo-side test drives all three outcomes against a
mock broker and asserts client returns the correct enum variant for
each.

**Effort:** M

**Deps:** .011.M1-003, .011.M1-007 (policy decision).

### R90-XREPO.011.M1-007 [POLICY DECISION — MAIN-REQUIRED] Org-wide stubbed-broker policy

**Scope:** Decide and document the org-wide policy for what a
*still-stubbed* broker means during the transition. This is a
main-decision because the answer sets rm/pkg security posture and
propagates to every satellite tool that touches elevate.

**Options for main to choose from:**

- **(A) Fail-closed (recommended by this plan).** A stubbed or
  timed-out broker is treated as DENY. Blocks the rm.ENH-001 class of
  bypasses immediately. Cost: any consumer that currently proceeds on
  the advisory status (`rm`) must be updated before the change lands
  or it will start refusing legitimate operations.
- **(B) Fail-open.** Stubbed broker = ALLOW. Faster satellite bring-up
  but perpetuates the elevate-bypass class of bugs and leaves the
  security posture explicitly unsafe until .011.M1-003 lands.
- **(C) Tri-state (STUB distinct from ALLOW/DENY).** Client API
  exposes STUB as its own variant; each consumer decides per-call.
  More honest, more code, more places to get wrong; leaves the
  inconsistency #1997 flags in place until every consumer branches.

**Files touched (docs-only for the decision itself):**
`design/security/elevate-broker.md`,
`design/security/stubbed-broker-policy.md` (new).

**Fingerprint:** n/a (decision). Verification: chosen policy appears
in the design doc and .011.M1-006 client library reflects it.

**Effort:** S (decision) + downstream

**Deps:** none; blocks .011.M1-006 landing cleanly.

---

## §4. R90-XREPO.012 — svc.schema-registry stand-up (parent #2000)

### Repo-shape recommendation (main-decision-adjacent)

**Recommendation: create a new `paideia-os/libpdx-schema-registry`
repo.** Rationale: every other `libpdx-*` (libpdx-audit, libpdx-cap,
libpdx-config, libpdx-argv, libpdx-elevate, libpdx-net, libpdx-url,
libpdx-volume, libpdx-semantic-pipe) lives in its own repo; folding
schema-registry into libpdx-semantic-pipe would break that pattern,
couple the two release cadences, and make the semantic-pipe repo the
owner of a service definition consumed by tools that do not link
semantic-pipe. Cost of a new repo is one-time (README + LICENSE +
find-paideia-as.sh + submodule pin) and the project already runs 20+
satellite repos happily.

Only ambiguity for main: repo name — `libpdx-schema-registry` (fits
the `libpdx-*` shared-library pattern) vs. `svc-schema-registry`
(more accurate — this is a service definition + registry client, not
a general-purpose library). Plan defaults to `libpdx-schema-registry`
per the parent issue's phrasing.

### Sub-issues

### R90-XREPO.012.M1-001 Create libpdx-schema-registry repo scaffolding

**Scope:** Create the new repo with README, MIT LICENSE,
`find-paideia-as.sh` submodule pin (mirror libpdx-audit as template),
`.gitignore`, and an empty `src/` skeleton. No code yet.

**Target repo:** `paideia-os/libpdx-schema-registry` (new).

**Files touched:** entire new repo skeleton.

**Fingerprint:** n/a (scaffolding). Verification: `find-paideia-as.sh`
passes and repo is submodule-addable from paideia-os monorepo.

**Effort:** S

**Deps:** none.

### R90-XREPO.012.M1-002 Schema-record type design

**Scope:** Design doc for the initial schema record types
(`PdxFsDirEntry`, `RawByteChunk`) and the extensibility rule for
adding more. Defines the schema-handle format (opaque 32-byte, per
parent issue) and the semver-adjacent evolution rule.

**Target repo:** `paideia-os/libpdx-schema-registry` +
`paideia-os/paideia-os` (design doc).

**Files touched:** `design/terminal/schema-registry.md` (new, in
monorepo).

**Fingerprint:** n/a (docs).

**Effort:** S

**Deps:** .012.M1-001.

### R90-XREPO.012.M2-001 Kernel schema-registry daemon

**Scope:** Land the daemon at `src/kernel/services/schema_registry.pdx`.
Owns the in-kernel schema handle table; exposes register + lookup ops.
At v1 the table is boot-populated from a static list; dynamic
registration is a future round.

**Files touched:** `src/kernel/services/schema_registry.pdx` (new),
`src/kernel/boot/kernel_main.pdx` (start the daemon).

**Fingerprint:** Boot witness registers `PdxFsDirEntry`, looks it up
by name, prints the returned handle non-zero and stable across two
lookups.

**Effort:** M

**Deps:** .012.M1-002 (design).

### R90-XREPO.012.M2-002 svc_broker name-table entry

**Scope:** Add `svc.schema-registry` to `svc_broker.pdx`'s name table
so `bind_by_name("svc.schema-registry")` returns a live endpoint to
the daemon from .012.M2-001. Retires 304 for this name.

**Files touched:** `src/kernel/services/svc_broker.pdx`,
`design/terminal/schema-registry.md`.

**Fingerprint:** Boot witness calls `bind_by_name("svc.schema-registry")`
and prints resolved endpoint id non-zero.

**Effort:** S

**Deps:** .012.M2-001.

### R90-XREPO.012.M3-001 KIND_SCHEMA_HANDLE capability

**Scope:** Introduce `KIND_SCHEMA_HANDLE` as a first-class capability
kind (dispatched via the standard per-kind pattern). Ops at v1:
`QUERY_NAME`, `QUERY_HANDLE`. This is what consumers actually hold
after a lookup.

**Files touched:** `src/kernel/core/cap/kind_schema_handle.pdx` (new),
`src/kernel/core/cap/dispatch.pdx`,
`design/terminal/schema-registry.md`.

**Fingerprint:** Boot witness obtains a `KIND_SCHEMA_HANDLE` for
`PdxFsDirEntry`, calls `QUERY_NAME`, prints exact-string match.

**Effort:** M

**Deps:** .012.M2-001.

### R90-XREPO.012.M4-001 libpdx-semantic-pipe Registry.bind_by_name real path

**Scope:** Retire the always-304 return in
`libpdx-semantic-pipe/src/registry.pdx`'s `bind_by_name`; wire it to
`svc.schema-registry` via the daemon from .012.M2-001. Do not remove
the interim schema-id derivation path yet (libpdx-semantic-pipe#11) —
leave both wired behind a feature-flag until the ls cutover
(.012.M4-002) proves the real path.

**Target repo:** `paideia-os/libpdx-semantic-pipe`.

**Files touched:** `src/registry.pdx`, tests.

**Fingerprint:** Repo-side test binds by name against a kernel with
the daemon live, receives a real handle, and round-trips it through
`QUERY_NAME`.

**Effort:** M

**Deps:** .012.M3-001.

### R90-XREPO.012.M4-002 ls migration off placeholder schema hash

**Scope:** Replace the hand-imprinted placeholder schema hash
(`0x01` + 31 zero bytes) in `ls` with a real handle obtained via
libpdx-semantic-pipe's newly-live `bind_by_name`. Proves the
end-to-end path.

**Target repo:** `paideia-os/ls`.

**Files touched:** `src/main.pdx` (or wherever the placeholder lives),
tests.

**Fingerprint:** `ls` output on a live kernel carries the real
`PdxFsDirEntry` handle byte-for-byte matching what a fresh `bind_by_name`
returns.

**Effort:** S

**Deps:** .012.M4-001.

### R90-XREPO.012.M5-001 cat + doc second/third-consumer onboarding

**Scope:** Onboard `cat` (as second consumer, using `RawByteChunk`)
and `doc` (as third consumer, using a doc-specific record — design in
this issue) to prove interop across independent tools. Split into two
commits/PRs but one tracker issue since they are the same pattern.

**Target repos:** `paideia-os/cat`, `paideia-os/doc`.

**Files touched:** `src/main.pdx` in each repo, tests.

**Fingerprint:** A pipeline `ls | cat` (or `cat | doc`) on a live
kernel carries schema handles that both ends resolve to the same
name via `QUERY_NAME`.

**Effort:** M

**Deps:** .012.M4-002.

### R90-XREPO.012.M5-002 design/terminal/schema-registry.md consolidation

**Scope:** Close-out sub-issue. Consolidate the incremental notes
added by .012.M1-002 / .012.M2-* / .012.M3-001 into a single
authoritative design doc; add a "how to add a new schema" section
that reflects lessons from the cat/doc onboarding.

**Files touched:** `design/terminal/schema-registry.md`.

**Fingerprint:** n/a (docs).

**Effort:** S

**Deps:** .012.M5-001.

---

## §5. R90-XREPO.013 — Exec-time cap reconciliation adoption campaign (parent #2002)

Gated on the external prerequisite `shell.ENH-032` (real `sys_execve`
wiring) — the parent issue is explicit that there is no exec path to
reconcile against today. **.013.M2-001 must not land before
shell.ENH-032; the M3/M4/M5 waves depend on both.**

15 sub-issues, batched by tool role.

### R90-XREPO.013.M0-001 Kernel exec-time cap reconciliation substrate

**Scope:** Kernel-side substrate that narrows a child process's caps
at exec against the child's declared `caps.decl`. New syscall
`sys_exec_reconcile_caps` invoked from the sys_execve tail. Refuses to
grant a cap not present in the parent's cap set (narrow-only).

**Files touched:** `src/kernel/core/cap/reconcile.pdx` (new),
`src/kernel/syscall/sys_execve.pdx` (tail-hook),
`design/kernel/exec-time-cap-reconciliation.md` (new),
`design/user/syscall-table.md`.

**Fingerprint:** Boot witness spawns a child with a `caps.decl`
narrower than the parent's caps, prints child's post-exec cap-set
count matching the decl.

**Effort:** L

**Deps:** shell.ENH-032 (external, in `paideia-os/shell`).

### R90-XREPO.013.M1-001 caps.decl format + reconciliation semantics design

**Scope:** Consolidate the design of the `caps.decl` file format
(location per tool: `manifest.pdxsig` sibling), the narrowing
algorithm, and the failure mode (exec refuses, audit logs the
reason).

**Files touched:** `design/security/caps-decl.md` (new),
`design/kernel/exec-time-cap-reconciliation.md`.

**Fingerprint:** n/a (docs).

**Effort:** S

**Deps:** .013.M0-001 (align docs to substrate).

### R90-XREPO.013.M1-002 libpdx-cap: exec-time reconciliation client helper

**Scope:** Add a client helper to `libpdx-cap` that a tool calls at
its entry to obtain the reconciled cap-set and assert its expected
caps are present. Applies R90-XREPO.001 seed pattern for the caps.decl
lookup.

**Target repo:** `paideia-os/libpdx-cap`.

**Files touched:** `src/exec_reconcile.pdx` (new), `README.md`, tests.

**Fingerprint:** Repo-side test drives the helper against a mock
kernel, asserts a narrowed set is reported and a missing expected
cap raises.

**Effort:** M

**Deps:** .013.M0-001.

### R90-XREPO.013.M2-001 shell: wire exec-time reconciliation in sys_execve path

**Scope:** In the real exec path landed by shell.ENH-032, invoke
`sys_exec_reconcile_caps` for every child before returning control.
Publish the child's reconciled caps in the shell's per-job record.

**Target repo:** `paideia-os/shell`.

**Files touched:** `src/exec.pdx`, tests.

**Fingerprint:** Repo-side test spawns a child with a caps.decl
narrower than shell's caps, observes the reconciled set in the shell
job record.

**Effort:** M

**Deps:** .013.M0-001, shell.ENH-032.

### R90-XREPO.013.M3-001 ls — caps.decl + adoption

**Scope:** Land a `caps.decl` for `ls` listing exactly the caps it
uses (KIND_PDXFS_FILE read + directory + KIND_SCHEMA_HANDLE); wire
the libpdx-cap helper at entry; refuse to run if reconciliation
narrows below required set.

**Target repo:** `paideia-os/ls`.

**Files touched:** `caps.decl` (new), `src/main.pdx`.

**Fingerprint:** Repo-side test runs `ls` under a parent with strictly
required caps + one extra; observes reconciled set at entry equal to
required (extra dropped).

**Effort:** S

**Deps:** .013.M1-002, .013.M2-001.

### R90-XREPO.013.M3-002 cat — caps.decl + adoption

**Scope:** As .013.M3-001, for `cat`. Same shape.

**Target repo:** `paideia-os/cat`.

**Files touched:** `caps.decl` (new), `src/main.pdx`.

**Fingerprint:** Repo-side test as above.

**Effort:** S

**Deps:** .013.M1-002, .013.M2-001.

### R90-XREPO.013.M3-003 cp — caps.decl + adoption

**Scope:** As .013.M3-001, for `cp`. `caps.decl` must include undo-log
write.

**Target repo:** `paideia-os/cp`.

**Files touched:** `caps.decl` (new), `src/main.pdx`.

**Fingerprint:** Repo-side test as above; asserts undo-write cap
survives reconciliation.

**Effort:** S

**Deps:** .013.M1-002, .013.M2-001.

### R90-XREPO.013.M3-004 mv — caps.decl + adoption

**Scope:** As .013.M3-001, for `mv`.

**Target repo:** `paideia-os/mv`.

**Files touched:** `caps.decl` (new), `src/main.pdx`.

**Fingerprint:** Repo-side test as above.

**Effort:** S

**Deps:** .013.M1-002, .013.M2-001.

### R90-XREPO.013.M3-005 rm — caps.decl + adoption

**Scope:** As .013.M3-001, for `rm`. `caps.decl` must not include
KIND_ELEVATE_CHANNEL by default — elevate is minted on demand under
R90-XREPO.011, not held at exec. This sub-issue enforces that
narrowing.

**Target repo:** `paideia-os/rm`.

**Files touched:** `caps.decl` (new), `src/main.pdx`.

**Fingerprint:** Repo-side test — `rm` post-exec has no elevate cap
in reconciled set even when parent had one.

**Effort:** S

**Deps:** .013.M1-002, .013.M2-001.

### R90-XREPO.013.M3-006 mkdir — caps.decl + adoption

**Scope:** As .013.M3-001, for `mkdir`.

**Target repo:** `paideia-os/mkdir`.

**Files touched:** `caps.decl` (new), `src/main.pdx`.

**Fingerprint:** Repo-side test as above.

**Effort:** S

**Deps:** .013.M1-002, .013.M2-001.

### R90-XREPO.013.M3-007 doc — caps.decl + adoption

**Scope:** As .013.M3-001, for `doc`. Includes KIND_SCHEMA_HANDLE for
doc-schema.

**Target repo:** `paideia-os/doc`.

**Files touched:** `caps.decl` (new), `src/main.pdx`.

**Fingerprint:** Repo-side test as above.

**Effort:** S

**Deps:** .013.M1-002, .013.M2-001.

### R90-XREPO.013.M3-008 pkg — caps.decl + adoption

**Scope:** As .013.M3-001, for `pkg`. `caps.decl` must include write
to `/pkgs` and `/system/packages`; elevate is on-demand per the R90-XREPO.011
policy.

**Target repo:** `paideia-os/pkg`.

**Files touched:** `caps.decl` (new), `src/main.pdx`.

**Fingerprint:** Repo-side test as above.

**Effort:** S

**Deps:** .013.M1-002, .013.M2-001, .011.M1-007 (policy).

### R90-XREPO.013.M4-001 fs-tools adoption wave (mount / umount / mkfs.pdxfs)

**Scope:** Batch adoption for the three PdxFS admin tools; same
caps.decl+entry-helper pattern as .013.M3-*, batched because they
share a caps profile (KIND_VOLUME + KIND_PDXFS_FILE admin ops). One
sub-issue, three commits.

**Target repos:** `paideia-os/mount.pdxfs`, `paideia-os/umount.pdxfs`,
`paideia-os/mkfs.pdxfs`.

**Files touched:** `caps.decl` + `src/main.pdx` in each of the three.

**Fingerprint:** Each repo's test runs its tool with a narrowed
parent cap-set and observes reconciliation reporting the expected
narrowed set.

**Effort:** M

**Deps:** .013.M1-002, .013.M2-001.

### R90-XREPO.013.M4-002 net-tools adoption wave (pdxping/pdxcurl/pdxsock/pdxdig/pdxtrust)

**Scope:** Batch adoption for the R100 network CLI wave. Same
caps.decl+entry-helper pattern; batched because they share a caps
profile (libpdx-net socket caps + tool-specific narrowing). One
sub-issue, five commits.

**Target repos:** `paideia-os/pdxping`, `paideia-os/pdxcurl`,
`paideia-os/pdxsock`, `paideia-os/pdxdig`, `paideia-os/pdxtrust`.

**Files touched:** `caps.decl` + `src/main.pdx` in each.

**Fingerprint:** Each repo's test as above; `pdxping` and `pdxsock`
also assert the R_NET_PRIVILEGED_PROTOCOL elevate is not held at
exec (on-demand only).

**Effort:** M

**Deps:** .013.M1-002, .013.M2-001, .011.M1-007 (policy).

### R90-XREPO.013.M5-001 Adoption-campaign closeout audit

**Scope:** Closeout sub-issue. Verify every satellite tool listed in
.013.M3-* / .013.M4-* actually reconciles at exec: run each under a
narrowed parent cap-set and record the reconciled set in an audit
report committed to `design/security/`.

**Files touched:** `design/security/caps-reconciliation-adoption-audit.md`
(new, in `paideia-os/paideia-os`).

**Fingerprint:** Report lists every tool with its expected vs
observed reconciled cap-set; all rows match.

**Effort:** M

**Deps:** all of .013.M3-* and .013.M4-*.

---

## §6. Landing order

The four rounds intertwine on a few well-defined joins. Land in
roughly this order (per-round parallelism is fine wherever the
per-issue Deps are satisfied):

1. **R90-XREPO.010 (PdxFS substrate)** — foundational; blocks nothing
   in the other three rounds directly but every satellite tool wants
   it eventually. Internal order: .010.M1-001, .010.M1-002 in
   parallel; then .010.M1-003; then .010.M1-004 and .010.M1-005; then
   .010.M1-006 (parallel with the txn/undo chain); .010.M1-007 any
   time; .010.M1-008 last.
2. **R90-XREPO.011 (Elevate broker)** — internally serial through
   .011.M1-001 → .011.M1-002 → .011.M1-003; .011.M1-004 parallel with
   .011.M1-001..002; .011.M1-005 any time; **.011.M1-007 (policy
   decision) is a hard gate** for .011.M1-006 and downstream tool
   sub-issues (.013.M3-005 rm, .013.M3-008 pkg, .013.M4-002 net-tools).
3. **R90-XREPO.012 (schema-registry)** — .012.M1-001 first (repo);
   then M1-002, M2-001, M2-002 in sequence; then M3-001, M4-001,
   M4-002, M5-001, M5-002 in that order. No cross-round hard gates.
4. **R90-XREPO.013 (exec-cap adoption)** — **gated on
   shell.ENH-032 (external)**. Order once unblocked: .013.M0-001 →
   .013.M1-001 + .013.M1-002 (parallel) → .013.M2-001 → all .013.M3-*
   in parallel → .013.M4-001 and .013.M4-002 in parallel → .013.M5-001
   closeout.

Cross-round joins:

- .013.M3-005 (rm), .013.M3-008 (pkg), .013.M4-002 (net-tools) all
  depend on **.011.M1-007** (policy decision).
- .010.M1-001 unblocks doc/cat/ls schema work but is not a hard gate
  for .012 (the schema-registry itself is orthogonal to PdxFS
  substrate).

## §7. Ambiguities for main to resolve

1. **[POLICY] Stubbed-broker policy (.011.M1-007).** Three options
   documented in §3. This plan recommends fail-closed (option A) but
   the decision is main's — it changes rm/pkg behavior immediately.
2. **[REPO SHAPE] libpdx-schema-registry naming (.012.M1-001).**
   `libpdx-schema-registry` (matches `libpdx-*` pattern) vs.
   `svc-schema-registry` (more accurate — it is a service definition,
   not a general-purpose library). Plan defaults to
   `libpdx-schema-registry` per parent issue #2000 wording.
3. **[SCOPE] readnext record widening in .010.M1-006.** Widen the
   128-byte readnext record vs. escalate to variable-length records.
   The sub-issue scope documents both options and asks the implementer
   to pick during softarch; if main has a preference it belongs here.
4. **[SEQUENCING] shell.ENH-032 landing date.** R90-XREPO.013 is
   entirely blocked on this external gate. If it is far off, defer
   filing .013.M2-001..M5-001 until it is nearer; otherwise file all
   15 up front and let the deps enforce order. Plan assumes file-all-
   fifteen-up-front (matches how R90-XREPO.008 was filed as one
   omnibus in the first place).
5. **[BATCHING] fs-tools and net-tools waves (.013.M4-*).** Currently
   one sub-issue each (3 and 5 tools respectively). If per-tool
   isolation is preferred, split into 3 + 5 = 8 sub-issues, taking
   the campaign total from 15 to 20. Plan defaults to batched.
6. **[CAMPAIGN COMPLETENESS] .013 coverage.** The parent issue says
   "9 satellite tool repos" but the org now has 17+ tool repos. Plan
   covers the 9 audit-set tools individually plus 8 newer ones in two
   batched waves. If some tool (e.g. `postui-*` reference apps) should
   also adopt, add sub-issues; the plan does not cover them today.
