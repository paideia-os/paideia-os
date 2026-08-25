# R81 Retrospective (PARTIAL): HDA/ALC287 live audio

**Date:** 2026-08-25
**Milestone:** R81.M1 (single-milestone round)
**Issues:** 3 landed-as-scaffold/PROVISIONAL (#1827, #1828, #1830);
1 partial (#1832); 2 deferred (#1831, #1834); this doc closes #1835.
**HEAD at audit:** paideia-os bbb3d35 (fresh worktree, no code changes
made by this audit).
**Release tag:** `r81-closed` recommended as a partial-close — real
remaining work exists (#1831's userspace binary) that is not
hardware-gated.

## Round intent

Per `design/roadmap/post-r60-daily-use-roadmap.md:481-482`: "Operator
hears sound. Controller + codec + CORB/RIRB + BDL all written under
R33; exercise real PCM + jack-detect." Notably, the roadmap itself
names QEMU `ich9-hda` as a viable CI substitute for #1827 — this is
the most QEMU-partial-testable of the seven audited rounds. Corpus:
`src/kernel/core/drivers/hda/`, 17 files, 7,805 lines.

## Per-issue disposition

### #1827 — HDA controller live init on T14 G4 (or QEMU ich9-hda) — LANDED (PROVISIONAL)
`controller.pdx` (425L) + `reset.pdx` (247L) + `corb.pdx` (365L) +
`rirb.pdx` (378L): BAR-window declaration, reset sequencing, CORB/RIRB
ring setup. `controller.pdx`'s own header notes the probe is gated
behind `hda_controller_bind` pending a real BAR handle — same
seam-gated discipline used project-wide. The generic controller/ring
protocol is real HDA spec conformance, independent of ALC287
specifics, so QEMU's `ich9-intel-hda` model is a genuine (if partial)
test path per the roadmap's own framing. LANDED (PROVISIONAL).

### #1828 — ALC287 codec discovery + node graph walk — LANDED (PROVISIONAL)
`codec_discovery.pdx` (573L): generic HDA codec-address-space walk +
`GET_PARAMETER` probing (vendor ID, function groups) — QEMU-partial-
testable against any generic codec model. `widget_graph.pdx` (737L) +
`pin_config.pdx` (398L) + `alc287_init.pdx` (424L): ALC287-specific
vendor coefficient table (SET_COEF_INDEX/SET_PROC_COEF verbs for HP
amp headroom, mic biasing, beamforming-mic AGC) — this half is
real-Realtek-silicon-only; QEMU's HDA codec model does not emulate
ALC287 vendor verbs. LANDED (PROVISIONAL) overall, with the generic/
vendor-specific split noted.

### #1830 — BDL programming for single output stream (44.1kHz stereo) — LANDED (PROVISIONAL)
`bdl.pdx` (574L): Buffer Descriptor List entry construction for a
stereo 44.1kHz PCM stream. Generic HDA stream-descriptor protocol,
QEMU `ich9-hda` partial-testable.

### #1831 — Sine-wave test tone playback via `/bin/sinetone` — DEFERRED
No such binary exists anywhere in the tree (`grep -rli 'sinetone' src/`
returns nothing). The issue explicitly calls for "a new tiny binary" —
this is real, unstarted userspace work, not hardware-gated: writing
`/bin/sinetone` (generate a PCM sine wave, write it into the BDL
buffers #1830 already programs) does not require real ALC287 silicon
to build and could be exercised against the QEMU `ich9-hda` +
`hda-output` device pair.

### #1832 — Jack-detect via unsolicited response wired to real ISR — PARTIAL
`alc287_jack.pdx` (460L) + `alc287_hp_spk.pdx` (442L) +
`alc287_mic.pdx` (469L): unsolicited-response decode and HP/speaker/mic
routing logic exists and is real (landed at R33.M4, referenced
directly by the roadmap: "paideia-os R33.M4 driver exists"). The
issue's own title is "wire to real ISR" — confirming the decode logic
is done and the remaining gap is specifically the interrupt-wiring
step, which is real work independent of the ALC287-silicon-specific
question (an HDA unsolicited-response IRQ line is generic HDA spec,
QEMU-testable in principle). PARTIAL, matching the issue's own framing.

### #1834 — Boot smoke `boot_r81_audio_playback` — DEFERRED
Does not exist. Blocked on #1831's missing binary (not hardware-gated)
and, for the ALC287-specific audible-tone fingerprint, on real T14 G4
hardware. DEFERRED on both grounds.

### #1835 — Round closure — this document
STATUS + retrospective + `r81-closed` tag, partial-close discipline.

## Cross-repo escalations

None found.

## Observable proof

Driver corpus builds under its original R33 landing witnesses; no new
observable produced by this audit (no code changes made). QEMU
`ich9-hda` offers the clearest partial-exercise path of any audited
round for #1827/#1828 (generic half)/#1830, but was not run here per
task scope (no build/QEMU invocation).

## Debt inventory (carried forward)

1. **`/bin/sinetone`** (#1831) — new userspace binary; not
   hardware-gated, buildable and QEMU-`ich9-hda`-testable now.
2. **Unsolicited-response ISR wiring** (#1832) — connect
   `alc287_jack.pdx`'s decode logic to a real interrupt line; generic
   HDA IRQ mechanism, partially QEMU-testable.
3. **ALC287 vendor-verb exercise** (#1828's vendor half) — real
   Realtek-silicon-only, no substitute path.
4. **`boot_r81_audio_playback`** — write once (1)-(2) land; full
   audible-tone fingerprint remains real-hardware-only.

**Next round:** R81 has the shortest non-hardware-gated debt list of
the seven audited rounds (items 1-2 above are both buildable now).
Recommend a small follow-up pass to close those before the next
roadmap round (R82/R83/R84), since they would meaningfully increase
what QEMU can verify pre-hardware.
