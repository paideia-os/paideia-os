# PaideiaOS — Next-Wave Derived-Kind Catalog

**Status:** Living document. First seed at R29.M0-001 (#1017).
**Scope:** Base + derived capability kinds introduced across the next-wave
rounds (R29+). Each entry records the runtime base kind (LAM kind-hint slot),
the descriptor-tail encoding, the rights bitmask, and the round/issue that
lands the derived kind. Structural companion to
`design/capabilities/linearity-and-tags.md` §3.1 and
`design/capabilities/derived-kinds.md` (Phase-2 catalog).

**Ordering discipline:** entries land in dependency order (base kinds before
their derived kinds) and reference their introducing GitHub issue. Every
`KIND_*` mentioned in `design/roadmap/next-wave-softarch.md` §3 or §4 has an
entry here before the corresponding round closes.

---

## Base kinds (R29+)

### `KIND_HW = 14` — hardware-adjacent base kind

**Introduced by:** R29.M0-001 (#1017). Promotes the previously-reserved
slot 14 (paideia-os prior label: "fault") per
`design/roadmap/next-wave-synthesis.md` §10 D6.

**Rationale.** The R29+ driver framework introduces a family of
hardware-adjacent capability kinds (interrupts, MSI-X vectors, IOMMU
domains, hardware timelines) that must be routed hot-path. Rather than
derive each from `KIND_DEVICE` (slot 10, which was overloaded across
device memory + config + register access), R29 opens a dedicated base
slot so the LAM kind-hint (4 bits) can fast-dispatch every
hardware-adjacent cap with a single `cmp rcx, 14; je call_kind_hw`
branch in `cap_invoke_dispatch`.

**Descriptor common header:** the 24-byte cap-table entry shape
inherited from `src/kernel/core/cap/mint.pdx`:

```
+0   kind:u64        = 14 (KIND_HW)
+8   rights:u64      = bitmask (see per-derived-kind tables below)
+16  target_ptr:u64  = pointer to the kind-specific tail (kernel-owned)
```

**Descriptor tail (base `KIND_HW` — no derived refinement):** empty. A
raw `KIND_HW` cap without a derived-kind tag is a *reservation marker*
only — it holds no hardware authority on its own. Derivation to one of
the R29.M1 concrete kinds (KIND_HW_INTERRUPT / KIND_HW_MSIX_VECTOR /
KIND_HW_DMA_DOMAIN / KIND_HW_TIMELINE) is required before any
hardware effect can be invoked.

**Rights bitmask (base):**

| Bit | Right | Meaning |
|-----|-------|---------|
| `RIGHT_OBSERVE` (0x400) | Read the kind label + presence | Introspection only. |
| `RIGHT_MINT`   (0x200) | Derive a concrete R29.M1 kind from this cap | Restricted to the supervisor / driver-registrar. |
| `RIGHT_REVOKE` (0x010) | Revoke the base + all derived children | Cascades per §7.5 of linearity-and-tags. |

All other rights bits (READ/WRITE/EXEC/INVOKE) are **denied** on a raw
`KIND_HW` cap — they are only meaningful on a derived cap where the tail
records the specific hardware handle. The mint gate at R29.M1 refines
the rights subset per derived kind (per the tables below).

**Dispatch today (R29.M0-001).** `cap_invoke_dispatch` has no branch for
`KIND_HW` yet; a freshly minted slot-14 cap falls through to the R8 MVP
identity return (`mov rax, rsi; ret` → returns `target_ptr`). This is
intentional — the dispatch branch + per-derived-kind handler set land as
a coordinated bundle in R29.M1.

**Boot witness.** `kernel_main.pdx §kind_hw_witness` mints a base
`KIND_HW` cap at cap_table slot 14 with `rights = RIGHT_OBSERVE |
RIGHT_MINT`, reads the descriptor back, asserts kind == 14 and rights ==
0x600, then emits `R29 KIND_HW OK`. This is a *structural* witness only
— it proves the enum slot is registered and mintable; the R29.M1
sub-issues add functional-dispatch witnesses per derived kind.

---

## Derived kinds over `KIND_HW` (R29.M1)

The four entries below are *planning skeletons* only — R29.M0-001 (this
issue) does not implement them. Each row is refined into a full spec by
the corresponding R29.M1 sub-issue when it lands.

### `KIND_HW_INTERRUPT` — landed by R29.M1-001 (#1019)

- **Runtime base kind:** `KIND_HW = 14`.
- **Derived-kind tag:** `0x140` (12-bit tag; base slot in low 4 bits, family
  discriminator in high 8 bits — pattern to be finalized at R29.M1-001).
- **Descriptor tail:** `{vector:u8, cpu_mask:u64, trigger:{edge=0|level=1},
  polarity:{high=0|low=1}, ioapic_id:u8, source_id:u16}`.
- **Rights:** `RIGHT_INVOKE` (unmask / ack), `RIGHT_OBSERVE` (read pending
  count / status), `RIGHT_REVOKE` (mask + reclaim vector).
- **Ops:** `OP_UNMASK`, `OP_MASK`, `OP_ACK`, `OP_STATUS` (op-code layout per
  R29.M1-001).
- **Replaces:** the pre-R29 `KIND_INTERRUPT = 9` (slot 9) is deprecated at
  R29.M1-001 close; the slot-9 kind stays alive as a compatibility alias
  until R30 open.

### `KIND_HW_MSIX_VECTOR` — landed by R29.M1-002 (#1020)

- **Runtime base kind:** `KIND_HW = 14`.
- **Derived-kind tag:** `0x141`.
- **Descriptor tail:** `{msix_table_pa:u64, entry_index:u16,
  target_apic_id:u16, message_data:u32, mask_bit:u1}`.
- **Rights:** `RIGHT_READ` (message table), `RIGHT_WRITE` (mask bit only),
  `RIGHT_INVOKE` (redirect target).
- **Ops:** `OP_MASK`, `OP_UNMASK`, `OP_REDIRECT`, `OP_READ_ENTRY`.
- **Depends on:** `KIND_HW_DMA_DOMAIN` (for the underlying device's IOMMU
  domain — MSI-X writes must be domain-consented).

### `KIND_HW_DMA_DOMAIN` — landed by R29.M1-003 (#1021)

- **Runtime base kind:** `KIND_HW = 14`.
- **Derived-kind tag:** `0x142`.
- **Descriptor tail:** `{iommu_ctx_ptr:u64, bdf:u16, ats_enabled:u1,
  pri_enabled:u1, address_width:u8}`.
- **Rights:** `RIGHT_MINT` (map / unmap a page into the domain),
  `RIGHT_REVOKE` (tear the domain down), `RIGHT_OBSERVE` (fault log).
- **Ops:** `OP_MAP`, `OP_UNMAP`, `OP_FLUSH`, `OP_QUERY_FAULT`.
- **Interaction with `KIND_PAGE = 4`:** a `KIND_PAGE` cap must accompany
  every `OP_MAP` — the domain cap authorizes the mapping site, the page
  cap authorizes the physical page. Cross-cap consent per the R29 IOMMU
  invariant.
- **Domain granularity — per-driver-process (D1.b).** One
  `KIND_HW_DMA_DOMAIN` per driver process, shared across every device
  the driver claims. Minted at driver-process spawn by the supervisor
  and delivered via the loader's `_init_caps` sidecar
  (`design/loader/init-caps-sidecar.md`); revoked on process exit,
  which tears down every context entry attributed to it. Full rationale
  (per-driver-process vs per-device vs per-firmware-image), the
  CNVi-shared-domain blast-radius acknowledgment, and the
  `dma_domain_attach(domain, bdf)` supervisor entry point are
  documented in `design/drivers/blob-policy.md` §2. This rule governs
  both blob-consuming drivers (Wi-Fi, BT, IPU6, GuC, SOF) and native
  drivers uniformly.

### `KIND_HW_TIMELINE` — landed by R29.M1-004 (#1022)

- **Runtime base kind:** `KIND_HW = 14`.
- **Derived-kind tag:** `0x143`.
- **Descriptor tail:** `{monotonic_ns_offset:i64, resolution_ns:u32,
  source:{tsc=0|hpet=1|apic=2|dev_clock=3}, clock_id:u16}`.
- **Rights:** `RIGHT_READ` (sample current value), `RIGHT_OBSERVE`
  (metadata: resolution, source, drift bounds).
- **Ops:** `OP_SAMPLE`, `OP_QUERY_META`, `OP_WAIT_UNTIL` (blocking; may be
  gated behind a scheduler-context cap per R29.M4).
- **Foundational for:** every subsequent R30–R40 hardware clock-domain
  crossing carries a `KIND_HW_TIMELINE` cap. GPU→display, GPU→CPU,
  audio-mclk→CPU, USB-SOF→isoch endpoint, network-PTP→application all
  derive from this base (see `next-wave-softarch.md` §4).

---

## Base kinds reserved for later rounds

### `KIND_RESERVED = 15` — confidential-computing / TDX (D1)

Slot 15 remains reserved per CAP-Q9. The R33+ confidential-computing
work (D1) will consume it. Slot 15 is currently *also* used as the
runtime base for the `KIND_DMESG` derived kind (logging-m9-001, tag
`0x16`) — this derivation pattern is orthogonal to any future D1 base
kind and will migrate to a derived-tag over the future D1 kind if a
collision arises.

---

## Change log

| Date | Round | Issue | Change |
|------|-------|-------|--------|
| 2026-08-12 | R29.M0 | #1017 | Initial doc + `KIND_HW = 14` base kind row + R29.M1 derived-kind skeletons. |

---

## References

- `design/capabilities/linearity-and-tags.md` §3.1 — base kind hierarchy.
- `design/capabilities/derived-kinds.md` — Phase-2 derived-kind catalog.
- `design/roadmap/next-wave-synthesis.md` §10 D6 — slot 14 promotion decision.
- `design/roadmap/next-wave-softarch.md` §3 R29 — driver-framework maturation
  round detail; §4 for GPU/display timeline chain.
- `src/kernel/core/cap/kind.pdx` — the KIND_* enum.
- `src/kernel/core/cap/invoke.pdx` — dispatch table.
