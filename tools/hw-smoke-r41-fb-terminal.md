# R41 HW-Smoke — Semantic Terminal (framebuffer frontend)

R41.M5-003 (#1379). Hardware-smoke procedure for the R41 semantic
terminal, framebuffer frontend variant. Per design decision D7
(`gated:hardware`), this smoke stays DORMANT in the CI-less local
smoke matrix until a real T14 Gen 4 machine boots the fb-console +
HID keyboard stack AND executes at least one live query against the
R41.M2 engine. The placeholder at
`tests/kernel/semterm/hw_smoke_r41_placeholder.pdx` returns `0`
unconditionally so `tools/run-smoke.sh` reports GREEN without
pretending a bring-up ran.

## Prerequisites

- Real T14 G4 booted via UEFI on real firmware (not QEMU-OVMF).
- R23 fb-console live: `KIND_FRAMEBUFFER` row bound with the GOP
  base + stride the firmware surfaced; `plt_reset` + `plt_put`
  render into the 80x24 canvas at the resolution the fb-console
  publishes.
- R26 USB HID keyboard live: `xhci_hid` posts `KIND_HID_EVENT`
  rows the fb frontend's `sfb_input_push` seam consumes.
- R41.M1 lexer / parser / types loaded (paideia-as v0.25 elaborator
  gate has passed).
- R41.M2 engine bound to `SRC_SYSCALLS`, `SRC_CAPS`, `SRC_TASKS`,
  `SRC_INTERRUPTS`, `SRC_AUDIT` (all five pre-registered rows at
  reset; providers are dormant until this smoke widens them).
- R41.M3 plot compositor + palette default RGB installed.
- R41.M4 line editor + pager reset.
- R41.M5 session log attached (`slog_attach` yields the fb session
  id) and recovery arbiter EITHER `rec_arm`ed with the safectl
  channel bound (recovery boot) OR left disarmed (shell boot).

## Procedure

1. Reset the R41 stack (from a boot-time init):
   `lex_bind(0, 0)`, `par_alloc(0)`, `tyq_bind(0, 0)`,
   `eng_reset()`, `src_reset()`, `rs_reset()`, `plt_reset()`,
   `lyt_reset()`, `pal_reset()`, `sfb_reset()`, `led_reset()`,
   `pgr_reset()`, `rec_reset()`, `slog_reset()`.
2. If the kernel cmdline contains `recovery=1`:
   - `rec_arm()`; `rec_safectl_bind(KIND_CAP_ROOT, safectl_slot)`;
   - leave `rec_ro` at its default 1 (UPDATE verbs refused).
3. `slog_attach()` yields the fb session id; verify > 0.
4. At the terminal prompt, type:
   `SELECT * FROM tasks LIMIT 10\n`
5. The engine parses, types, and executes the query; the pager
   opens on the returned row-set. The plot compositor renders the
   first page into the 80x24 cell canvas; the fb frontend hands the
   render command to the fb-console blitter.
6. Confirm on screen: 10 rows visible, header line at row 0,
   `1/N` page indicator at row 23.
7. Press `SPACE`; the pager advances one page (`pgr_next_page`
   returns 0); the frontend re-renders.
8. Press `q`; `pgr_quit` sticks; the frontend returns to the prompt.
9. Verify `slog_len() >= 1`, `slog_exec_count() >= 1`, and the
   `slog_get(0, SLOG_F_SESSION_ID)` matches the id from step 3.
10. If recovery-mode:
    - Type `SELECT * FROM safectl.state\n`; `rec_verb(REC_VERB_SELECT_STATE)`
      accepts (verb_count == 1).
    - Type `UPDATE safectl SET rescue_kernel = 'foo'\n`;
      `rec_verb(REC_VERB_UPDATE_RESCUE)` refuses
      (`REC_ERR_RO_REFUSED`, deny_count == 1).
    - Widen: caller invokes `rec_set_ro(0)`; retry the UPDATE;
      `rec_verb` accepts.
11. Take a screenshot of the framebuffer with an external camera
    (the sandbox blocks in-band captures on real hardware); attach
    it to the smoke run's evidence bundle.
12. Detach: `slog_detach()` yields SLOG_OK.

## Success criteria

- Fingerprint emitted: `R41 SEMTERM FB HW OK`
- Screenshot shows 10 rendered rows, page indicator, header.
- `slog_exec_count()` records at least one execution.
- Under recovery boot, `rec_deny_count()` records at least one
  RO_REFUSED refusal AND the accepted UPDATE after widening.
- No panic, no `klog` error line at level >= WARN during the run.

Until real hardware is present, the placeholder witness in
`tests/kernel/semterm/hw_smoke_r41_placeholder.pdx` returns 0 and
the fingerprint above never appears in the shell-shutdown golden.
