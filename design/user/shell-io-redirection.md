# R58.M5-001: shell IO redirection (#1805)

## Summary

The shell tokenizer (`src/user/tokenizer.pdx`) now splits `>`, `>>`, and
`<` off as their own argv tokens instead of treating them as ordinary
word characters, and `exec_child` (`src/user/dispatch.pdx`) scans the
tokenized argv for these operators between fork and execve, wiring the
named file onto the target fd via `sys_open` + `sys_dup2` + `sys_close`
before the child execve's. Marker: `shell redirect ok -- argv[0]=<name>
op=<op> file=<path> [legacy: SHELL REDIRECT OK]`.

## Scope (M0)

Accepted shapes only:

- `<cmd> [args...] > <file>` — truncate-or-create, write, stdout (fd 1).
- `<cmd> [args...] >> <file>` — append-or-create, write, stdout (fd 1).
- `<cmd> [args...] < <file>` — read-only, stdin (fd 0).
- Any combination of the three in one command line (e.g. `cat < /tmp/x
  > /tmp/y`), in either order, with or without whitespace between the
  operator and its filename (`>file` and `> file` both work — see
  Tokenizer Changes).

## Scope-negative (explicitly NOT supported at M0)

- `2>&1`, or any fd-to-fd duplication syntax.
- `>|` (clobber override) — irrelevant since there is no noclobber mode.
- `<<HEREDOC` / `<<<here-string`.
- Quoting or escaping of any kind (`"a > b"` still splits on `>`).
- Multiple redirects to the same fd resolving to "last wins" semantics
  are incidental (whichever the scan applies last does win, since each
  dup2 replaces the fd), not a designed feature.
- A redirect operator as `argv[0]` (the command name) is not meaningful
  and is not specially handled; behavior in that case is unspecified.

## Tokenizer changes

`tokenize()` gains a third hard-delimiter class alongside whitespace and
NUL: `0x3E` ('>', possibly doubled) and `0x3C` ('<'). Unlike whitespace,
these characters are not merely consumed — they become their own
argv_buf entries. But an operator's argv_buf slot points at one of three
new rodata constants (`redirect_gt`, `redirect_gtgt`, `redirect_lt`),
never at the line buffer.

This sidesteps a real in-place NUL-termination problem: `>file` has no
whitespace between the operator and the filename, so there is no spare
byte to write a terminating NUL into after the `>` without destroying
`f`. Pointing the token at static rodata instead means the operator's
own content never depends on a line-buffer byte, so nothing needs to
survive being overwritten. The `in_token` scan additionally treats
`0x3E`/`0x3C` as delimiters mid-token: it NULs the in-progress buffer
token at the operator's position (safe, since that position isn't the
operator's own content) without consuming the byte, then fall through to
the same operator-detection code the top-level scan uses. New labels are
`tk_rd_`-prefixed per this tree's reserved-word discipline.

## `exec_child` changes

Between `sys_fork` and the existing `resolve_path`/`sys_execve` call, the
child branch runs an in-place left-compacting scan over `argv_buf`
(`rd_`-prefixed labels): for each token, `strlen` + `memcmp` against
`Tokenizer::redirect_gt/redirect_gtgt/redirect_lt` (not a raw byte
compare — this keeps the check coupled to the same constants the
tokenizer used to build the token) determines whether it is an
operator. On a match, the following token is opened with the flags
matching the operator (`>` → `O_WRONLY|O_CREAT|O_TRUNC` = `0xC1`, `>>` →
`O_WRONLY|O_CREAT|O_APPEND` = `0x241`, `<` → `O_RDONLY` = `0`, per
`vfs_open.pdx`'s frozen flag bits; mode `0644` = `0x1A4` for creates),
`sys_dup2`'d onto fd 1 (`>`/`>>`) or fd 0 (`<`), and the opened fd is
closed. Both the operator and filename tokens are dropped from the
compacted argv; every other token survives untouched. This scan is
child-only — fork gives the child a private (COW) address space, so the
parent's `argv_buf` and `argc` are unaffected.

Register plan: `r12`=argc, `r13`=read index, `r14`=write index,
`r15`=current token pointer / target-fd carrier, `rbx`=the fd returned
by `sys_open` (kept live across `sys_dup2` so `sys_close` closes the
*opened* fd, not `sys_dup2`'s return value). All five are callee-saved
and untouched by `strlen`/`memcmp` or by the `sys_open`/`sys_dup2`/
`sys_close` stubs. Per this file's own documented risk around the
kernel's syscall arg-shuffle disturbing `r8`/`r9`/`r10` across a
`syscall`, no value is trusted to survive a call in those registers —
every `argv_buf[i]` use is reloaded fresh immediately before use,
mirroring `resolve_path`'s existing `rp_hit` reload discipline.

An open failure or an operator with no following token silently drops
the malformed redirect (best-effort M0 behavior, no fingerprint) rather
than aborting the exec.

## Fingerprint

`shell redirect ok -- argv[0]=<name> op=<op> file=<path> [legacy: SHELL
REDIRECT OK]\n`, emitted once per applied redirect from the child via 7
`sys_debug_puts` (SC+ ID 12) calls sandwiching the three runtime-length
fields between four fixed rodata fragments, mirroring
`resolve_path`'s existing `sh_exec_ok_*` fingerprint shape. ASCII `--`
(not U+2014), plain English tokens, per this tree's wire-ASCII
convention.

## Dependency chain

- R57.M4-005 (#1801) shell PATH-prefix `resolve_path` — prerequisite,
  landed at wave-1 (commit `deb505b`). This issue's redirect scan runs
  strictly before `resolve_path` in the child branch and does not
  modify it.
- The golden fixture (`tests/r58/expected-r58-redirect.golden`) is
  **deferred** to a later issue (composite shell smoke plumbing, #1810)
  — it depends on multi-binary shell smoke infrastructure that does not
  exist yet, and is explicitly out of scope here per the issue.
