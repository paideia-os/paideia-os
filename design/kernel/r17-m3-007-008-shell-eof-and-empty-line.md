# R17.M3-007 + R17.M3-008: shell EOF exit + empty-line reprompt (#627 + #628)

## Summary

Two closely-related shell UX corners handled in one commit:

- **#627 (Ctrl-D EOF exit)**: when `shell_read_line` returns `bytes_read == 0`, jump to `exit_on_eof` which calls `builtin_exit(0)` → `sys_exit(0)`. This branch was already in the shell skeleton (#621) but was never called out by a design doc or covered by a verifier check.
- **#628 (empty-line reprompt)**: when the user hits Enter with no other input, `tokenize` returns `argc == 0`. Skip `dispatch_line` and `exec_child` entirely; jump straight back to `main_loop` so the prompt re-appears.

Marker: extends existing `R17 SHELL READER OK` (added two structural checks — no new verifier script).

## Design Intent

### #627 rationale
`shell_read_line`'s sole EOF signal is `sys_read` returning `≤ 0` (the loop's `jle read_done` at src/user/shell.pdx:38). It returns whatever bytes it accumulated in `rcx`, which is exactly zero on immediate EOF. `_start`'s existing `cmp rax, 0; je exit_on_eof` (lines 83–84) handles this correctly. The design intent worth pinning: this is the shell's *only* clean exit path aside from the `exit` builtin.

### #628 rationale
Before this issue, an empty line (just `\n`) would:
1. tokenize → argc=0
2. dispatch_line → `cmp rax, 0; je dispatch_notfound` → return 1
3. shell _start sees rax==1 → call exec_child
4. exec_child guards on argc==0 → return 1
5. loop back to main_loop

Net effect: correct UX (reprompts), but two wasted calls per empty line. AC "hitting enter shows `$ ` again immediately" is met either way; the cleaner path (early skip after tokenize) is small, obviously correct, and eliminates dead work.

## Implementation

Single 3-line insertion in `src/user/shell.pdx` `_start`, immediately after `call tokenize`:

```
        cmp rax, 0;
        je main_loop;
```

`tokenize` already returns argc in rax (per r17-m3-003 design doc). No new .bss, no new function, no new syscall.

Nothing else changed for #627 — the existing `cmp rax, 0; je exit_on_eof` after `call shell_read_line` and the `exit_on_eof:` block that follows already satisfy it.

## Verification

Extended `tools/verify-user-shell.sh` (no new verifier script) with two structural checks appended after check 10:

11. **#627**: locate `exit_on_eof` label in disassembly; confirm its body calls `builtin_exit` or `sys_exit`. Falls back to checking `_start` contains such a call if the label isn't its own symbol.
12. **#628**: slice `_start` disassembly between `call tokenize` (PC lower bound) and `call dispatch_line` (PC upper bound); require that slice contain both `cmp rax,0x0` and `je`.

Both new checks pass at HEAD.

## Smoke Compliance

5-mode smoke stays byte-identical. `shell.elf` is not linked into `kernel.elf`; this is purely userspace additive.

## paideia-as Posture

No new encoder patterns. All opcodes precedent-live (cmp, je, jmp).

## Deferred

- Trailing whitespace on an "otherwise-empty" line still triggers argc=0 (tokenizer strips whitespace) — no additional handling needed.
- `!!` history recall, up-arrow line recall — R18+.
- Line editing (backspace, cursor movement) — R18+; requires raw-mode TTY handling.

## References

- Issues: paideia-os#627, paideia-os#628.
- Prior: #621 (skeleton), #622 (reader), #623 (tokenizer), #624 (dispatch), #625 (exec_child), #626 (path).
- Related fix: #670 (NUL-termination in shell _start before tokenize).
- Files: `src/user/shell.pdx` (_start), `tools/verify-user-shell.sh` (checks 11–12).
