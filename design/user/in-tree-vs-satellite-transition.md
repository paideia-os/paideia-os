# In-tree vs. Satellite Transition — /bin Ownership Cutover

Status: Design (fixes paideia-os#2458)
Origin: ECOSYSTEM_STATUS.md 2026-09-12 (fifth refresh), §Delta hazard #33
Scope: `src/user/{cat,cp,mkdir,mv,rm}.pdx` and `src/user/{dispatch,tokenizer}.pdx`
       vs. `tools/user/{cat,cp,mkdir,mv,rm,shell}/`

## 1. Problem

Five coreutils and the shell tokenizer/dispatch pair each exist twice in the
tree today, under two divergent shipping models:

* **In-tree** — `src/user/<name>.pdx` compiled by `tools/build-user.sh` into
  `build/user/<name>.elf`, embedded byte-for-byte into `init.elf` via
  `tools/init_userbin_embed.S`'s `.incbin`, then written to tmpfs at
  `/bin/<name>` by `src/kernel/boot/witness/bin_seeds.pdx::witness_bin_seeds`
  during `boot_continue_after_ring3`. Boot-early, no capability wire required,
  no signature check, no manifest.
* **Satellite** — `tools/user/<name>/` submodule (or, for `shell`, an
  unadopted live clone) with its own `manifest.pdxsig` dual-signed release
  envelope (author + `paideia_root_pk`), semver-tagged CHANGELOG, `caps.decl`,
  `deps.list`, and per-repo `.plans/`. Ships as an installable package via
  `pkg install <name>` once the R32 signing substrate lands.

No cutover plan exists, no CI gate asserts behavior equivalence, and every
future landing on either side silently drifts from its twin. This document
enumerates the pairs, picks an authoritative source per pair, defines the
handoff protocol, and specifies the CI gate that blocks pre-push drift.

## 2. Duplicate inventory (2026-09-12 HEAD)

| Name    | In-tree (`src/user/`) | Satellite (`tools/user/`) | Sat tag | Sat features not in in-tree |
|---------|----------------------:|--------------------------:|:-------:|-----------------------------|
| cat     | 14 816 B, 2026-08-25  | 996 KB, 2026-09-12 | v1.0.0, `v1.1.1-A` unreleased | errno-mapped stderr blobs (ENH-003); ENH-002/ENH-001 still stub |
| cp      | 22 903 B, 2026-08-25  | 956 KB, 2026-09-12 | v1.0.0, v1.1-C doc-only | `sys_getcwd` cwd-relative resolve (v1.1-B); atomicity-claim retirement (v1.1-C) |
| mkdir   |  8 951 B, 2026-08-25  | 908 KB, 2026-09-12 | v1.0.0, v1.1-B unreleased | 12-file M1..M5 stack; userspace cwd-join (v1.1-B) |
| mv      | 10 716 B, 2026-08-25  | 1.1 MB, 2026-09-12 | v1.0.0 | `MoveRecord@0.2`; ENH-004 dst-clobber guard; eight `pdxfs_txn_*` trampolines |
| rm      |  9 522 B, 2026-08-25  | 952 KB, 2026-09-12 | v1.0.1 | full M1..M5 stack + libpdx-audit/elevate/semantic-pipe wire; ENH-007 unknown-flag reject |
| shell   | 17 842 B, 2026-09-12  | 4.0 MB, HEAD `c355368` | (not tagged; 51 commits) | fd-0 line editor; `O_APPEND` history; `bi_cd -` OLDPWD; `help` `/bin` enumerator; tokenizer quote state machine (R106.M1); shell#41/44 fork-before-exec |
| dispatch| in `shell.pdx` module | `tools/user/shell/src/dispatch.pdx` | (as above) | R49/R106 clean-start; argv construction novel-tilde |
| tokenizer| in `shell.pdx` module | `tools/user/shell/src/tokenizer.pdx` | (as above) | `'`/`"` quoting, `\` escape, `$VAR`, `;`/`&`/`\|` |

Every satellite v1.0.0 tag is a milestone-schedule closure (per the
2026-09-12 re-scope walk-back); the real functional bodies live on the
`v1.1-*` and `Unreleased` heads. The in-tree bodies are functional but
feature-frozen at 2026-08-25 and lack every enhancement listed in the last
column.

## 3. Authoritative source, per pair

| Pair | Authoritative | Rationale |
|------|:-------------:|-----------|
| cat  | **satellite** | Diagnostic surface (errno-mapped stderr) is a POSIX-shaped feature that only lives satellite-side; the in-tree body would need every ENH-* backported. Sat wins on features and on shipping model. |
| cp   | **satellite** | cwd-relative resolve landed sat-side v1.1-B; atomicity-claim retired sat-side v1.1-C. |
| mkdir| **satellite** | The 12-file M1..M5 stack + userspace cwd-join is sat-only; the in-tree `mkdir.pdx` is a single 8.9 KB file that predates the extraction. |
| mv   | **satellite** | MoveRecord@0.2 + ENH-004 dst-clobber guard sat-only; `pdxfs_txn_*` wire-up is the last M5 gap. |
| rm   | **satellite** | Full libpdx-audit/elevate/semantic-pipe wire is sat-only; in-tree `rm.pdx` has no audit path. |
| shell| **split → satellite** | In-tree `shell.pdx` is the boot-early bring-up shell required by the `bin_seeds`-seeded `/bin/sh` first-execve. Satellite is target for /bin promotion once adopted as submodule. |
| dispatch, tokenizer | **satellite** | Satellite carries the quote state machine + pipe/redirect grammar the in-tree pair explicitly lacks; port target already named by ECOSYSTEM_STATUS.md#33. |

Universal rule for coreutils: **satellite is master; in-tree is retired.**
For shell: **split-authoritative during transition, satellite-master after
Phase C.**

## 4. Handoff protocol

### Phase A — today (baseline, 2026-09-12)

`witness_bin_seeds` pre-seeds `/bin/{child_hello, sh, true,
elevate_broker_daemon, ls, cat, ps, rm, mv, cp, mkdir, touch, dmesg}` from
in-tree `src/user/*.pdx` sources via `tools/init_userbin_embed.S` `.incbin`
of `build/user/*.elf`. `rootfs_seed` is defence-in-depth (four of seven
manifest entries are still 9-byte stubs; a no-op on normal boot because
`bin_seeds` runs first). Satellite work is authored + released independently
but no output reaches `/bin` at boot.

### Phase B — reroute `bin_seeds` to satellite build output

Wire a manifest that names, per `/bin/<name>` entry, the source of its ELF
payload. Two source kinds:

```
# tools/bin_seeds.manifest — one row per /bin/<name>
# columns: bin_path  source_kind  source_path                        sha256  version
/bin/sh          in-tree   build/user/shell.elf                       <sha>  boot-early
/bin/true        in-tree   build/user/true.elf                        <sha>  boot-early
/bin/child_hello in-tree   build/user/child_hello.elf                 <sha>  boot-early
/bin/cat         sat       tools/user/cat/build-out/cat.elf           <sha>  v1.1.1-A
/bin/cp          sat       tools/user/cp/build-out/cp.elf             <sha>  v1.1-C
...
```

`tools/build-user.sh` invokes each satellite's build (drives `paideia-as
compile` inside the submodule), collects the ELF, and re-emits
`init_userbin_embed.S` to `.incbin` from either `build/user/` (in-tree) or
`tools/user/<name>/build-out/` (satellite). `bin_seeds.pdx`'s writer loop
consumes the same manifest so on-disk `/bin` layout, ELF bytes, and manifest
row are one triple.

Precondition: satellite carries a real `_start` + `.ld` (mv#18 open;
mkdir/rm/cp already have this from the v1.1-A extractions).

### Phase C — retire in-tree coreutils

Remove `src/user/{cat,cp,mkdir,mv,rm}.pdx` + `<name>.ld` + build wiring.
Retain `src/user/{init, shell, dispatch, tokenizer, rootfs_seed,
syscall_shim, string, io, errno, libc, founder_constants, true,
child_hello, echo_client, echo_server, elevate_broker_daemon,
acpi_supervisor, pci_enumerator, audio_supervisor, dmesg,
compositor, input_server, ime, color, a11y, aml, libpaideia_ui,
builtins}.pdx` as the truly-monorepo binaries: boot-early bring-up
(shell/init/true/child_hello), supervisor daemons (acpi/audio/pci/elevate
brokers), and the pure-boot in-kernel witnesses.

Gate: Phase B green for every one of the five pairs for ≥ one full loop
iteration (softarch → main-build → debugger); satellite CHANGELOG carries a
`bin_seeds-adopted` marker; the retired `src/user/*.pdx` file is removed in
the same commit that bumps `bin_seeds.manifest` to the satellite row.

### Phase D — signed-release lifecycle

Each satellite ships v1.x with `manifest.pdxsig` dual-signed (author key +
`paideia_root_pk`), CHANGELOG entry, release notes, and a frozen
`build-out/<name>.elf` at a pinned commit. `bin_seeds.manifest` pins by
`(sha256, version)`. `paideia-as release --sign` (blocked on paideia-as
v0.33-crypto per the manifest headers) is the write path; today the
`signature_ml_dsa_65` fields are `PENDING`, so Phase D activates when R32
lands ML-DSA-65 sign/verify + `sha3_256`.

## 5. CI gate

`tools/verify-bin-seeds-equivalence.sh` (mirror of
`tools/verify-syscall-shim-coverage.sh`, invoked by the pre-push hook):

1. For each row in `tools/bin_seeds.manifest`, boot a QEMU instance with
   `/bin/<name>` from that row, then run a fixture pair against it:
   * `mkdir /tmp/x && ls /tmp` shows `x`
   * `echo hello > /tmp/a && cp /tmp/a /tmp/b && cat /tmp/b` prints `hello`
   * `mv /tmp/b /tmp/c && ls /tmp` shows `c` not `b`
   * `rm /tmp/c && ls /tmp` does not show `c`
2. Repeat with the other side of each duplicate pair (in-tree if the row is
   satellite, satellite if the row is in-tree) at the SAME fixture set.
3. Diff the fingerprint streams. Any divergence — different exit code,
   different stderr blob, different `/tmp` state — fails the gate and
   blocks the push.

Runtime: ~30s per fixture set × 5 pairs = ~2.5 min added to pre-push.
Ordering: runs after `run-smoke.sh` in the pre-push hook chain.

## 6. Shell duplicate (urgent, paideia-os#2438)

`tools/user/shell/` is worse than the coreutil pairs: (1) not in
`.gitmodules` — the working tree at HEAD `c355368` is untracked; (2) 51
landed commits with features that never existed in-tree (fd-0 line editor,
tokenizer quote state machine, `bi_cd -` OLDPWD, `help /bin` enumerator,
fork-before-exec shell#44); (3) divergent dispatch grammar (satellite:
R49/R106 novel-tilde; in-tree: hardcoded `["/bin/","/usr/bin/"]` PATH
prefix); (4) blocks the `sys_execve` cutover — STATUS.md §ENH-008 names
adoption as the still-required paideia-os-side landing.

Recommendation: land paideia-os#2438 (adopt as `.gitmodules` submodule) in
the **next** wave. Every parallel-both-sides landing after this accumulates
merge cost the adoption then has to reconcile.

## 7. Recommendation summary

| Pair | Master | Next action |
|------|:------:|-------------|
| cat, cp, mkdir, mv, rm | satellite | Phase B (`bin_seeds.manifest` reroute) |
| shell | split → satellite | paideia-os#2438 adoption; then Phase B |
| dispatch, tokenizer | satellite | Port satellite bodies into shell submodule (already there); retire in-tree modules with shell.pdx in Phase C |

Order of operations across waves: (1) paideia-os#2438 shell submodule
adoption; (2) `tools/bin_seeds.manifest` + `verify-bin-seeds-equivalence.sh`
land; (3) Phase B reroute one pair at a time (cp first — smallest sat
diff); (4) Phase C retire once all five are green for ≥ 1 loop iteration;
(5) Phase D signed-release lifecycle blocks on paideia-as v0.33-crypto.

## 8. Open questions

* **Manifest format.** TSV (above) vs. `.pdxproj` TOML vs. a `.pdx`
  compile-time table read by both `bin_seeds` and `build-user.sh`. The
  third removes the manifest-vs.-writer drift class but requires
  `paideia-as` to expose a `.rodata` export usable by bash; today it does
  not.
* **`rootfs_seed`'s four 9-byte stubs.** After Phase B, `rootfs_seed`
  becomes a duplicate write path. Retire it, or promote it to the
  authoritative writer and retire `bin_seeds`'s loop? Favors the latter:
  `rootfs_seed` is closer to the eventual `pkg install` flow.
* **Boot-early `/bin/sh`.** Recommend split-authoritative through Phase C:
  in-tree shell stays boot-early, satellite shell replaces it after.
* **Satellite build costs.** Cache satellite ELFs by submodule commit sha
  if aggregate build time crosses the smoke-loop budget.
* **Retired in-tree file disposition.** Recommend history-only; the
  satellite CHANGELOG carries the extraction lineage, and a stale in-tree
  copy invites accidental edits.
