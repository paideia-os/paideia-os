# /bin/ls v1.1 — userspace cwd-relative path resolution

**Round / issue:** paideia-os/ls#29 (v1.1 landed 2026-09-12).
**Depends on:** R86.M1-003 (paideia-os #1956) — `sys_getcwd` (sysno 86)
kernel body at `src/kernel/core/syscall/sys_getcwd.pdx`.
**Precedents:** paideia-os/mkdir#25 (mkdir v1.1-B, 2026-09-12) and
paideia-os/cp#21 (cp v1.1.0-B, 2026-09-12) — same classify-and-resolve
pattern in the argv path.
**Anchor policy:** `design/user/cwd-semantics.md` §2 (Option A —
caller's `TASK_OFF_CWD`).

---

## §1. Problem

Under `ls` v1.0 (R57.M4-001, paideia-os #1797) the tool:

1. Handed `argv[1]` verbatim to `sys_open`. The kernel's
   `path_resolve(..., cwd=TASK_OFF_CWD)` (R86.M1-005, paideia-os
   #1958) anchored relatives against the caller's cwd, so
   `ls ./sub` and `ls ..` both worked at the kernel boundary — but
   the string handed to `sys_open` was still the same `"./sub"` the
   user typed while the vnode `sys_open` landed on was
   `getcwd()+"/sub"`. Any smoke witness asserting the listed target
   had to consult the kernel's cwd for the prefix, a coupling
   nothing else in the coreutil surface has.

2. Defaulted `argc < 2` to the hardcoded string `"/"` (R62.M1-004,
   paideia-os #1833). That was a pre-R86 M0 stopgap: at the time,
   there was no kernel cwd to fall back on. Once R86.M1 landed the
   real cwd machinery, `ls` with no arguments still listed the
   root, diverging from POSIX `ls(1)` (whose no-arg default is the
   caller's cwd) with no benefit and one clear surprise for users
   coming from any Unix.

paideia-os/ls#29 closes both gaps together.

---

## §2. Decision

v1.1 moves cwd resolution into userspace, using the same shape mkdir
v1.1-B (paideia-os/mkdir#25) and cp v1.1.0-B (paideia-os/cp#21) landed
on 2026-09-12:

`_start` gains a **classify-and-resolve prologue** (Phase 0) that
sets `rdi` to a NUL-terminated absolute path in every arm before
`sys_open` sees it:

| Input                | Arm                | rdi at `ls_open_path_ready`      |
|----------------------|--------------------|----------------------------------|
| `argc < 2`           | `ls_no_arg`        | `&_ls_cwd_scratch` (= sys_getcwd)|
| `argv[1][0] == '/'`  | `ls_use_absolute`  | `argv[1]` verbatim               |
| any other first byte | `ls_do_resolve`    | `&_ls_resolved_scratch` (= join) |

The join computes `cwd + '/' + argv[1]` into `_ls_resolved_scratch`,
eliding the separator when cwd is exactly `"/"` (no double slash on
`ls foo` under root). `"."`, `".."`, `"./sub"`, `"foo"`, `"a/b"` all
flow through the shared resolve arm; the kernel's `path_resolve`
normalises `"."` components and walks `".."` back up via vnode
`parent_idx` inside every absolute we compose.

Absolute paths pass through unchanged (any prefixing would be
actively wrong since `path_resolve` anchors absolutes against the
mount root regardless of cwd).

---

## §3. Behavioural contract

    ls [PATH]

- No `PATH` (argc < 2): list the caller's cwd.
- `PATH` starts with `/`: list `PATH` verbatim.
- Anything else: list `cwd + '/' + PATH`, with the separator elided
  when cwd is `"/"`.
- No flags (`-l`, `-a`, `-R`, …) — v1.1 keeps v1.0's flag-free
  minimum-viable surface.
- Exit contract:
  - `0` = success (directory drained, terminator seen)
  - `1` = `LS_OPEN_FAIL` — `sys_open` returned non-fd
  - `2` = `LS_GETDENTS_FAIL` — `sys_getdents` returned negative
  - `3` = `LS_GETCWD_FAIL` (new) — `sys_getcwd` returned negative
  - `4` = `LS_PATH_TOO_LONG` (new) — resolved `cwd + '/' + argv[1]`
    would exceed the 255-byte-plus-NUL scratch slot

---

## §4. Files touched

- `src/user/ls.pdx` — `_start` Phase 0 rewritten; header comment,
  Control-flow block, SC+ IDs table, and Register-discipline block
  updated; `ls_root_path` (v1.0 `"/"` default) retired; two new
  256-byte `.bss` scratches (`_ls_cwd_scratch`,
  `_ls_resolved_scratch`); two new fail markers
  (`ls_err_gcwd_msg`, `ls_err_tlong_msg`) and their `_len`
  companions; two new terminal labels (`ls_fail_getcwd`,
  `ls_fail_path_too_long`).
- `tools/run-smoke.sh` — `boot_r86_relative_path` recipe:
  `INJECT_STRING` extended with `cd /tmp\nls\n` before `exit`;
  `INJECT_HOLD` bumped 20 → 22 for the extra command latency;
  header comment updated to describe the ls witness. Mode-
  dispatcher summary (line 55) updated to match.
- `tests/expected-r86-relative-path.golden` — two lines appended
  after `/tmp/sub`: `shell cd ok -- path=/tmp` (from the trailing
  `cd /tmp`) and `peer` (the `/bin/ls` listing entry that pins the
  argc<2-defaults-to-cwd fix).
- `src/kernel/boot/witness/r86_relative_path.pdx` — header
  documentation extended to describe the trailing `ls` witness.
- `design/user/ls-cwd-relative.md` — this file.

---

## §5. What v1.1 does NOT change

- `sys_open` kernel body: unchanged. `path_resolve`'s cwd-anchoring
  still fires for any caller that still hands it a relative path;
  v1.1 just stops being one of those callers.
- `sys_getdents` kernel body / record layout: unchanged.
  `ls_walk_top` and every downstream label operate on the same 4 KiB
  scratch and the same +0/+8/+10/+11/+12 header the R56.M3-003
  layout froze.
- No flags (`-l`, `-a`, `-R`, `-1`) — the minimum-viable surface is
  intentionally preserved. A future v1.2 lands `-a` and `-l` behind
  their own libpdx-argv-shaped parse.
- No output ordering change: entries are emitted in the order
  `sys_getdents` returns them (currently tmpfs creation order),
  followed by a `\n` per name.

---

## §6. Witness (paideia-os smoke lane)

`tools/run-smoke.sh boot_r86_relative_path` drives:

    mkdir /tmp
    cd /tmp
    mkdir ./sub
    cd ./sub
    mkdir ../peer
    pwd            # -> /tmp/sub
    cd /tmp
    ls             # -> `peer` and `sub` (order depends on tmpfs
                   #    directory iteration; golden pins `peer` only)
    exit

Golden (`tests/expected-r86-relative-path.golden`) pins, in order,
every mkdir/cd fingerprint, the literal `/tmp/sub` from `pwd`, then
`shell cd ok -- path=/tmp` (the second `cd /tmp`) and `peer` (the
ls output) as the v1.1 fix witness.

**Why `peer` is the right witness:** under v1.0, bare `ls` with no
arguments hardcoded target=`/` and would list ROOT entries
(`bin`, `etc`, `dev`, `home`, ...) — none of which contain `peer`.
Under v1.1, argc<2 defaults to the caller's cwd (`/tmp` at that
point), and the mkdir chain above created `/tmp/peer`. The golden
therefore fails on any tree still running v1.0 ls and passes only
on the v1.1 body.

---

## §7. Encoder-gap discipline

Per `feedback_pdx_encoder_pitfalls`:

- No `test rN, rN` anywhere (every zero-check is `cmp reg, 0`).
- No `and rN, imm64` on r8..r15.
- No 2-op `imul r, imm`.
- No `add reg, [mem]` / `sub reg, [mem]`.
- Every cmp immediate fits imm16 (max seen: `0x1000` = 4096, from
  the pre-existing `cmp rax, 4096` getdents guard).
- Byte loads use `xor rax, rax; mov_b rax, [ptr]` per the #1248
  mitigation pattern that `sys_getcwd_body` itself uses.
- Reserved-label discipline: every label prefixed `ls_`. New labels
  added: `ls_no_arg`, `ls_use_absolute`, `ls_do_resolve`,
  `ls_ulen_top`, `ls_ulen_done`, `ls_sep_done`, `ls_cpy_cwd_top`,
  `ls_cpy_cwd_done`, `ls_cpy_user_start`, `ls_cpy_user_top`,
  `ls_cpy_user_done`, `ls_fail_getcwd`, `ls_fail_path_too_long`.

---

## §8. CHANGELOG

### v1.1 — 2026-09-12 (userspace cwd-relative resolution)

Closes paideia-os/ls#29 (`ls doesn't resolve relative path arguments
against the kernel cwd (R86)`).

Added
- Classify-and-resolve Phase 0 in `_start`: mirrors mkdir v1.1-B /
  cp v1.1.0-B; three arms (`ls_no_arg`, `ls_use_absolute`,
  `ls_do_resolve`) fold into the shared `ls_open_path_ready` label.
- `sys_getcwd` (SC+ ID 86, sysno 86) inlined at the resolve site.
- Two 256-byte `.bss` scratches (`_ls_cwd_scratch`,
  `_ls_resolved_scratch`) matching `SYS_GETCWD_PATH_MAX` /
  `SYS_MKDIR_PATH_MAX` verbatim.
- Two new exit codes: `3` (`LS_GETCWD_FAIL`) and `4`
  (`LS_PATH_TOO_LONG`).
- Two new diagnostic strings routed through `sys_debug_puts`:
  `LS GETCWD FAIL\n` and `LS PATH TOO LONG\n`.
- Golden extension pins `shell cd ok -- path=/tmp` + `peer` as the
  v1.1 fix witness.

Changed
- `argc < 2` default: `"/"` (v1.0) → caller's cwd via `sys_getcwd`
  (POSIX `ls(1)` shape).
- `argv[1]` handling: verbatim (v1.0) → classify by first byte,
  absolute passthrough or userspace join against cwd (v1.1).

Removed
- `ls_root_path` rodata (`"/\0"`) — the sole consumer was
  `ls_use_default_path`, which the classify-and-resolve prologue
  supersedes.

Behavioural contract additions
- `ls` with no args lists cwd (was: root).
- `ls foo` under `cwd=/tmp` lists `/tmp/foo` (was: listed
  whatever `path_resolve` anchored `foo` against — same target on
  the wire, but the string handed to `sys_open` is now the
  absolute).
- `ls /foo` unchanged (absolute path passthrough).
- `ls .` under `cwd=/tmp` lists `/tmp/.` → `/tmp` via kernel `"."`
  normalisation (behavioural output unchanged; userspace string is
  now absolute).
