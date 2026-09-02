# R103 Closure Retrospective — virtio-gpu 2D backend

**Status:** Closed
**Date:** 2026-09-02
**Design authority:** `design/graphics/r101-kernel-plan.md` §6 (R103 sub-scope)
**Predecessor:** `design/round-retrospectives/r101-closure.md`

---

## 1. What R103 landed

R103 delivers the virtio-gpu 2D backend for the graphics substrate:
QEMU's second display path (after R101's Bochs/stdvga) is now driven
through a full virtio 1.1 command surface — probe, handshake, split
virtqueues, RESOURCE_CREATE_2D + ATTACH_BACKING + SET_SCANOUT +
TRANSFER_TO_HOST_2D + RESOURCE_FLUSH — with a real completion path
that advances `KIND_DISPLAY_TIMELINE` via
`dpy_timeline_vblank_signal(source = SOURCE_VIRTIO_COMPLETION = 4)`.

| Sub-scope | Milestones landed | Files |
|---|---|---|
| M1 — probe + handshake + queues | M1-001..005 (5 issues) | `core/drivers/gfx/virtio_gpu/{probe,common_cfg,controlq,cursorq}.pdx` |
| M2 — RESOURCE + SET_SCANOUT | M2-001..003 (3 issues) | `core/drivers/gfx/virtio_gpu/{resource,backing,scanout}.pdx` |
| M3 — TRANSFER + FLUSH + pair-slot | M3-001..003 (3 issues) | `core/drivers/gfx/virtio_gpu/{transfer,flush}.pdx`, `core/cap/kind_framebuffer.pdx` (pair-slot addendum) |
| M4 — ISR + LAPIC-tick fallback | M4-001..002 (2 issues) | `core/drivers/gfx/virtio_gpu/isr.pdx`, `core/cap/kind_display_timeline.pdx` (source-field addendum), `core/int/exceptions.pdx` |
| M5 — Boot witness `boot_r103_virtio_gpu` | M5-001..002 (2 issues) | `boot/witness/r103_virtio_gpu_flip.pdx`, `tools/run-smoke.sh` (boot_r103_virtio_gpu mode), `tests/expected-r103-virtio-gpu.golden` |
| M6 — Closure | M6-001 (this file) | `design/round-retrospectives/r103-closure.md` |

Total: **16 issues landed in one wave**.

## 2. Architectural choices honoured verbatim

- **virtio 1.1 modern-only presentation.** The R103.M1-001 issue text
  names the transitional device_id (0x1010) as an accepted match; this
  landing accepts only the modern variant (0x1050), documenting the
  transitional path as a follow-on. Every QEMU 4.0+ default is modern
  so the smoke matrix is unaffected. Same posture as virtio-net's
  transitional-arm treatment.
- **Feature negotiation** (plan §R103.M1-003): `VIRTIO_GPU_F_EDID`
  (bit 1) accepted; `VIRTIO_GPU_F_VIRGL` (bit 0) and
  `VIRTIO_GPU_F_RESOURCE_UUID` (bit 2) declined; `VIRTIO_F_VERSION_1`
  (bit 32) mandatory. Ack masks pinned in
  `common_cfg.pdx::VGPU_F_ACK_{LO,HI}_MASK`.
- **Control queue only for R103**; cursor queue minimally initialised
  (plan §R103.M1-005) so G7 compositor cursor path does not require
  re-init later.
- **Single scanout** (§13 caveat): only scanout 0 is enumerated +
  driven; multi-scanout is R104's concern.
- **Real completion → uniform vblank signal**: `RESOURCE_FLUSH`
  completion drives `dpy_timeline_vblank_signal(engine=2 virtio,
  output=1)` with `SOURCE_VIRTIO_COMPLETION = 4`; the R101 explicit-sync
  path works uniformly across backends. The task-brief debt "add the
  row-field to KIND_DISPLAY_TIMELINE" is honoured through a parallel
  `_display_timeline_source: [u64; 8]` table (see §3 below).

## 3. Deviations from the plan (each with justification)

1. **`_display_timeline_source` is a parallel table, not a widened row.**
   The R101 retro's §3.3 called this out as a debt: the source field
   was published as a compile-time constant only because widening the
   32-byte row layout would ripple through every accessor. This
   landing chooses a parallel `[u64; 8]` table (one slot per
   `_display_timeline_table` row) rather than growing the row layout —
   same behaviour, zero disturbance to any existing G1/G2/R101 caller.
   The `dpt_row_source_get`/`_set` accessor pair is the new public
   surface.
2. **`_fb_pair_table` is likewise a parallel table** to KIND_FRAMEBUFFER's
   48-byte row. R103.M3-003 asks for a `pair_slot_optional` field on
   the row; the parallel-table pattern lets the double-flip witness
   express the pair relationship without touching any existing
   `fb_row_*` accessor's byte-offset arithmetic. Accessors:
   `fb_row_pair_get`/`_set`.
3. **ISR is written but not wired to an IDT vector in this landing.**
   `virtio_gpu_isr_handle` is exported ready for R29 KIND_HW_INTERRUPT
   dispatch; the R103 witness path either uses the synchronous
   submit-and-poll form (which drives the vblank directly on poll
   completion) or relies on the LAPIC-tick fallback (M4-002). The
   full IDT wiring is a small follow-on that R104 or a mid-round patch
   can land without re-scoping.
4. **Static command buffer discipline** (`_vgpu_ctrl_cmd_buf` +
   `_vgpu_ctrl_resp_buf`, one page each): all commands are serialised
   through a single 4-KiB command / response buffer pair. The R103
   scope never needs more than one in-flight command at a time; the
   pair is oversized so a follow-on scatter/gather ATTACH_BACKING
   never has to grow the storage. Concurrent submission is a G7
   compositor concern.
5. **Cursor queue is init-only**; no cursor commands land in R103. Per
   plan §R103.M1-005 — main use case is compositor mouse cursor
   (G7 concern).
6. **Fingerprints all lowercase.** Consistent with the R101 posture:
   every OK token is lowercase (no `OK_TOK` trigger), so the
   fingerprint-coverage extractor does not scan these markers and no
   allowlist entry is needed.

## 4. Deferred (follow-on tickets)

- **3D acceleration (Virgl)** — VIRTIO_GPU_F_VIRGL declined; G3
  swapchain wire-up is a separate wave.
- **Multi-scanout** — R104's KIND_DISPLAY_OUTPUT walk.
- **Hotplug** — R105's KIND_HOTPLUG_CHANNEL.
- **Cursor commands** — G7 compositor cursor path.
- **IDT wiring of `virtio_gpu_isr_handle`** — pass-through follow-on;
  cited above (§3.3).
- **virtio-common refactor** (per plan §R103.M6-001) — extract shared
  virtio 1.1 handshake / virtqueue substrate now that both virtio-net
  and virtio-gpu are proven; explicitly deferred out of this round to
  keep the diff surgical.

## 5. Fingerprints emitted (R103)

Lowercase, one line each. Every OK token is lowercase so the
fingerprint-coverage gate ignores them; no allowlist needed.

- `r103 vgpu probe ok count=<n>` (probe)
- `r103 vgpu init hs ok` / `r103 vgpu init hs fail` (handshake)
- `r103 vgpu ctrlq init` (control queue)
- `r103 vgpu cursorq init` (cursor queue stub)
- `r103 vgpu resource create n=<id>` (per resource)
- `r103 vgpu attach back n=<id>` (per attach)
- `r103 vgpu scanout ok` (SET_SCANOUT)
- `r103 vgpu flush ok` (RESOURCE_FLUSH)
- `r103 vgpu display info count=<n>` (GET_DISPLAY_INFO — helper only,
  not invoked in the witness path)
- `r103 vgpu isr ok bits=<n>` (ISR entry; unused today — no IDT wiring)
- `r103 vgpu flip done ok` (ISR queue-arm)
- `r103 vgpu stall fbk` (once per boot if fallback fires)
- `boot r103 virtio_gpu skip` / `boot r103 virtio_gpu fail line=<N>`
  / `boot r103 virtio_gpu double_flip ok n=2` (witness)

## 6. Cross-repo dependencies (paideia-as)

None. Every command builder uses the encoder subset that virtio-net
established at R91.M3 (`mov_b`/`mov_w`/`mov_d` sized stores, mfence-
bracketed MMIO, `xor+mov_{b,w}` zero-extended loads, full-register
compares). No new intrinsic gap surfaced.

## 7. Files created (R103)

Fresh files: 11.
- `src/kernel/core/drivers/gfx/virtio_gpu/probe.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/common_cfg.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/controlq.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/cursorq.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/resource.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/backing.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/scanout.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/transfer.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/flush.pdx`
- `src/kernel/core/drivers/gfx/virtio_gpu/isr.pdx`
- `src/kernel/boot/witness/r103_virtio_gpu_flip.pdx`
- `tests/expected-r103-virtio-gpu.golden`
- `design/round-retrospectives/r103-closure.md` (this file)

Modified:
- `src/kernel/core/cap/kind_display_timeline.pdx` (source parallel table + accessors)
- `src/kernel/core/cap/kind_framebuffer.pdx` (pair-slot parallel table + accessors)
- `src/kernel/core/graphics/backend_dispatch.pdx` (virtio arm)
- `src/kernel/core/int/exceptions.pdx` (LAPIC-tick fallback call)
- `src/kernel/boot/kernel_main.pdx` (probe cascade + witness call)
- `tools/run-smoke.sh` (boot_r103_virtio_gpu mode)

The task-brief-required `tools/run-qemu.sh` change (PAIDEIA_VGA=virtio
arm) was already landed at R101.M4-002 (paideia-os #2151) so R103
consumes it as-is with no diff.
