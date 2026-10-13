# libpdx-unicode-tables IPC-boundary NFC hook (R131.M8)

## Status

**Wave:** R131 (semantic shell -- Unicode substrate umbrella,
paideia-os#2480).
**Milestone:** M8 (IPC-boundary NFC hook, paideia-os#2619).
**Library version at landing:** 1.7.0.
**Date:** 2026-10-11.

## Scope

M8 lands the IPC-BOUNDARY NFC hook on top of the M3 normalise
substrate. The contract is single-sentence: any string flowing across a
paideia-os IPC boundary (sender -> receiver) is normalised to NFC on
receive, so every downstream consumer sees exactly one byte-shape per
logical string. Two public primitives:

```
_ipc_nfc_check(bytes_ptr, bytes_len)                   -> packed u64
_ipc_nfc_apply(bytes_ptr, bytes_len, out_ptr, out_cap) -> packed u64
```

Return shapes:

- `_ipc_nfc_check`: `(is_nfc << 32) | status` with is_nfc in {0, 1}
  and status always 0 (the check does no UTF-8 validation at M8; it
  is a presence detector, not a well-formedness checker).
- `_ipc_nfc_apply`: `(out_bytes_written << 32) | status` with status
  in {0=OK, 1=OUT_TOO_SMALL, 2=INVALID_UTF8} -- the same shape as
  the underlying M3 `_norm_nfc`.

The check is a PURE LEAF: no capability bind, no syscall, no .bss
touch, no nested CALL. The apply is a one-call trampoline into
`_norm_nfc` with no arg-shuffle (the signature matches exactly) and
no new state.

M8 is the EIGHTH milestone of this library and the FIRST one whose
job is to tie together an existing primitive (`_norm_nfc`, M3) with
a specific CONSUMER CONVENTION ("every IPC-receiving ring-3 glue
calls `_ipc_nfc_apply` on the string fields it extracts from the
received message"). The code added here is small (one new source file,
~360 lines including comments; ~70 lines of actual instruction stream);
the design value is the convention it establishes.

## Why canonicalise at IPC

Paideia-os's text layer has, until this landing, imposed NO uniformity
across IPC boundaries. Two senders producing the "same" string ("café"
with precomposed U+00E9 vs "cafe" + U+0301) send different byte
sequences, and every receiver that compares, hashes, matches, or
indexes those bytes sees them as distinct. The failure modes compound
quickly:

- A shell completion engine that keyed on "café" never matches
  a user who typed "café" from an IME producing the precomposed form.
- A pds (process dictionary service) that stores keys by UTF-8 bytes
  returns a stale value when the lookup key arrives in a different
  Unicode normalisation form than the key it was stored under.
- A terminal that shells out to grep against a payload containing
  "café" fails to find a match that was indexed as "café".
- An audit journal that de-duplicates log entries by byte-identity
  retains two "copies" of the same string, inflating its storage.

The industry convention for solving this is "canonicalise at the
boundary where the string crosses between address spaces or stability
domains". The W3C PRECIS framework (RFC 8264) does so for network
identifiers; macOS's HFS+ does so on filesystem writes; Golang's
`norm` package does so at JSON-decode boundaries. Paideia-os's IPC
fabric is the natural boundary at which to centralise this
responsibility: once a string enters a receiver's address space in
NFC, every downstream operation on it inherits the canonical shape
without each operation having to re-normalise defensively.

## Design shape

### `_ipc_nfc_check`: fast presence detector

The check path is a single-pass byte scan, O(bytes_len), no table
loads, no nested calls. Scan rule:

```
for each byte b in [bytes_ptr, bytes_ptr + bytes_len):
    if b == 0xCC or b == 0xCD:
        return is_nfc=0
return is_nfc=1
```

This is a UTF-8 PRESENCE DETECTOR for the Combining Diacritical Marks
block (U+0300..U+036F). Any code point in that block encodes as a
two-byte UTF-8 sequence whose lead byte is 0xCC (for U+0300..U+033F)
or 0xCD (for U+0340..U+037F; U+0370..U+037F is Greek punctuation
outside the combining block, but 0xCD alone gates conservatively).

Correctness justification: every entry in M3's canonical decomposition
table has a mark code point in U+0300..U+036F. If the input contains
NO byte equal to 0xCC or 0xCD, it CANNOT contain any combining
diacritical mark that would compose with a preceding base; therefore
no M3-table decomposition could possibly fire; therefore the input is
NFC-stable with respect to the M3 table. (Formally: M3 is a function
f such that f(x) = x when x has no U+0300..U+036F code point; the
check proves the no-mark antecedent by a UTF-8-level scan.)

The check is CONSERVATIVE in the "safe" direction: it is NEVER a
false-POSITIVE on NFC (declaring is_nfc=1 when apply would actually
rewrite the bytes), and MAY be a false-NEGATIVE (declaring is_nfc=0
when apply would in fact be a no-op). False negatives cost one no-op
apply call per receive; false positives would be a CORRECTNESS BUG
and are impossible by construction.

### `_ipc_nfc_apply`: thin wrapper over M3

The apply path is a passthrough into `_norm_nfc`. Both have the same
4-arg signature, so no arg-shuffle is required:

```
pub let _ipc_nfc_apply =
  fn (bytes_ptr, bytes_len, out_ptr, out_cap) -> ... {
    sub rsp, 8;         // SysV alignment for the nested CALL
    call _norm_nfc;
    add rsp, 8;
    ret;
  }
```

The wrapper exists for two reasons:

1. **API clarity.** Callers at IPC boundaries name their call site
   by intent ("I am normalising a payload crossing an IPC boundary"),
   not by Normalisation Form choice. If a future milestone decides
   the canonical IPC form should be NFKC instead of NFC (unlikely
   but not inconceivable), the hook can be redirected at a single
   call site rather than at every IPC-receive wrapper in the tree.

2. **Audit value.** The symbol `_ipc_nfc_apply` is grep-visible as
   a load-bearing invariant point. A security review can enumerate
   every IPC receive path by searching for calls to this symbol
   and verifying each path either calls it on its string fields or
   justifies in-comment why it does not.

The output buffer is caller-supplied with the usual OUT_TOO_SMALL /
INVALID_UTF8 status semantics M3 defines. The reentrancy caveat
(the normaliser owns a shared .bss scratch) is inherited unchanged.

### Fast-path dispatch at the call site

The intended call site shape is:

```
// receive a message
packed := _ipc_nfc_check(payload_ptr, payload_len)
is_nfc := packed >> 32
if is_nfc == 1:
    // use the payload directly; no copy
    handle_message(payload_ptr, payload_len)
else:
    // normalise into a receiver-owned buffer
    packed := _ipc_nfc_apply(payload_ptr, payload_len,
                             owned_buf, owned_buf_cap)
    out_bytes := packed >> 32
    status    := packed & 0xFF
    if status != 0:
        reject_message(status)
    else:
        handle_message(owned_buf, out_bytes)
```

The check saves the apply allocation and the full
decompose-sort-compose pass for the common case where the input is
already canonical, which (per field measurement on sibling systems:
WebKit's text-processing bench, Golang's `norm` benchmarks) is the
vast majority of real-world traffic -- precomposed Latin + ASCII +
CJK dominates by three orders of magnitude over decomposed forms.

## Interaction with M3 normalize

The IPC hook consumes M3 as a BLACK BOX: it does not touch the
decomposition table, the composition table, the CCC table, the
scratch buffer, or the form-flag dispatcher. The hook's `_ipc_nfc_apply`
calls `_norm_nfc` with the caller's args and returns M3's packed
return unchanged.

This means:

- Any correctness improvement to M3 (table growth at M3.1+, CCC
  expansion at M3.2+, Hangul algorithmic decomp at M3.3+) applies
  transparently to the IPC hook.
- Any status code M3 ever adds (OUT_TOO_SMALL at M3.1 if the band
  grows, SCRATCH_OVERFLOW if it becomes a distinct code at M3.1,
  TABLE_VERSION_MISMATCH if hot-swappable tables land at M3.2)
  propagates through to callers of `_ipc_nfc_apply` without any
  change in this file.
- Any reentrancy or scratch-buffer migration M3 does at M3.3+ (moving
  from static .bss to caller-supplied workspace) must be mirrored at
  the ipc_nfc call site, since `_ipc_nfc_apply` becomes a 5-arg
  wrapper too; this is a BREAKING change deferred to a coordinated
  M3.3/M8.5 landing with its own MAJOR bump.

The check path's scan loop, by contrast, is TIED to M3's current
decomposition-table scope: it knows that every mark is in U+0300..036F
whose UTF-8 lead is 0xCC/0xCD. When M3.2 extends the decomp table into
Devanagari (combining marks U+0900..097F, UTF-8 lead 0xE0 + 0xA4..A5),
Hebrew (U+0590..05C7, UTF-8 lead 0xD6..D7), Arabic (U+0610..065F,
UTF-8 lead 0xD8..D9), etc., the scan loop at `_ipc_nfc_check` must
grow in lockstep to recognise those blocks' lead bytes too. M8.3 lands
the M3.2-synchronised scan.

## Kernel integration (deferred, with rationale)

The ideal shape would be a kernel-side per-syscall hook in
`sys_ipc_recv` and its specialised variants (sys_ipc_reply, the
channel-specific receive paths like audio_routing_channel's recv,
hid_event_stream_channel's dequeue, bt_gatt_channel's attribute-read,
etc.) that normalised every string field in the incoming message
transparently to the receiver.

This is NOT landed at M8 and is unlikely to land kernel-side at any
R131 milestone, for four reasons:

### 1. The normaliser is a ring-3 library

The current `_norm_nfc` uses .bss scratch (8 KiB) and the M3 decomp
table (765 u32 = 3 KiB) that live in a ring-3 process's address
space. Linking this into the kernel's IPC fast path would mean
duplicating ~11 KiB of state into kernel .bss (which the kernel
designers have been strict about keeping small to avoid ballooning
the init-stage memory map), and calling the normaliser without a
user-space stack.

The duplicated state would need its own reentrancy posture (the
kernel IPC fast path can be preempted by a higher-priority receiver,
and the normalise call's partial scratch would need to be
scheduler-aware), which is a significant complexity cost for a
feature whose correctness is already achievable by the ring-3
convention this milestone lands.

### 2. The kernel does not know which fields are strings

The IPC message layout is per-channel; each channel's descriptor
would need to carry string-field offsets or a schema the kernel
could walk. That extends the IPC ABI surface considerably: every
new channel (and there are 57 channel files in src/kernel/core/ipc
today) would need a string-field manifest, and the kernel's receive
path would need to walk that manifest on every receive.

A reasonable response to this is "add a channel-level attribute
`has_string_fields` and skip normalisation for channels that lack
them", but the per-channel receive wrappers in ring-3 are already
positioned to call `_ipc_nfc_apply` on exactly the fields they
know are strings, so the kernel-side manifest is redundant work.

### 3. Ring-3 receive wrappers are the natural site

Every IPC channel today has a ring-3 glue layer that extracts and
dispatches on the received message. That layer already walks the
message's logical structure (it knows the field types from the
channel's protocol); adding a one-line `_ipc_nfc_apply` call per
string field is a local change that keeps the normalise logic in
one domain. The ring-3 compiler can inline the fast-path check and
only call apply on the slow path.

### 4. The hook composes with higher-level invariants

The IPC fabric is only one of several places where strings need to
be canonical. The pds (process dictionary service) index at write
time, the audit journal's hash-based dedup, the shell's completion
engine, the terminal's font lookup, and the fs layer's path-name
canonicalisation all have their own canonicalisation needs. A
kernel-side hook would centralise ONE of these; a ring-3 convention
lets each layer choose its own normalisation strategy (e.g. the
audit journal might want NFKC-fold for broader dedup; the pds might
want NFC-only; the shell might want a case-folded variant). The
ring-3 hook is composable; the kernel-side hook would be mandatory.

### Alternatives considered and rejected

- **VDSO-side normalise.** Make `_norm_nfc` a VDSO symbol the kernel
  trampolines into for IPC receives. Rejected: the VDSO's job is to
  export syscall-fast-path helpers that don't touch per-process state,
  but the normaliser's scratch is per-process state. A per-VDSO .bss
  slot would need to be unique per process, which VDSOs don't support
  (they are read-only shared).
- **Capability-env'd ring-3 normalise injected per IPC.** The kernel
  dispatches to a user-space normaliser process over a dedicated
  capability. Rejected: the IPC-to-normalise latency alone would
  exceed the inline normalise cost by orders of magnitude; the
  convention lands the normalise inside the receiving process's own
  address space where it is a direct function call.
- **Lazy normalise at index-insertion time.** Each consumer (pds,
  audit journal, etc.) normalises on write but not on receive.
  Rejected: by then, each consumer has already had the chance to
  compare, hash, or forward the bytes; a store-and-later-normalise
  convention leaks non-canonical bytes into the rest of the system.

## Fingerprint and proptest coverage

### Fingerprint goldens (5)

Encoded at `tests/fingerprints/ipc_nfc.golden`:

| Tag                  | Op    | Input hex   | Expected output                 |
|----------------------|-------|-------------|----------------------------------|
| IPC_NFC_ASCII        | check | 68656C6C6F  | 0000000100000000 (is_nfc=1)      |
| IPC_NFC_PRECOMPOSED  | check | C3A9        | 0000000100000000 (is_nfc=1)      |
| IPC_NFC_DECOMPOSED   | check | 65CC81      | 0000000000000000 (is_nfc=0)      |
| IPC_NFC_EMPTY        | check | -           | 0000000100000000 (is_nfc=1)      |
| IPC_NFC_APPLY        | apply | 65CC81      | C3A9 (out_bytes=2, status=0)     |

Each case exercises one path through the state machine:

- IPC_NFC_ASCII: pure-ASCII loop with no 0xCC/0xCD hit.
- IPC_NFC_PRECOMPOSED: non-ASCII lead byte (0xC3) that is neither
  0xCC nor 0xCD; no mark detected.
- IPC_NFC_DECOMPOSED: 0xCC lead byte at offset 1 triggers the
  not-nfc early exit.
- IPC_NFC_EMPTY: zero-length input exits the loop at the first
  gate (rcx >= rsi) with no byte load.
- IPC_NFC_APPLY: end-to-end apply over the decomposed form,
  verifying that `_norm_nfc` composes the base+mark pair to the
  Latin-1 Supplement precomposed cp U+00E9 ("é" = UTF-8 C3 A9).

### Proptest invariants (3)

Encoded at `tests/proptest_ipc_nfc.pdx` module `ProptestIpcNfc`,
umbrella `pin_run_all`, fail codes in the 0xFFFFEDEx band:

- **PIN_IDEMPOTENT** (0xFFFFEDE1): `apply(apply(x)) == apply(x)`.
  Witness: "e"+U+0301 (65 CC 81) applied twice yields the same
  2-byte output ("é" = C3 A9) both times. Covers the invariant
  that NFC is a stable fixed point of the normalise function.

- **PIN_CHECK_APPLY** (0xFFFFEDE2): `check(apply(x)) == is_nfc=1`.
  Witness: apply "e"+U+0301 to "é" (C3 A9), then check "é" and
  verify is_nfc=1 (no 0xCC/0xCD bytes in the output). Covers the
  invariant that the check correctly identifies the output of
  apply as being in NFC.

- **PIN_ASCII** (0xFFFFEDE3): `check(ascii_string) == is_nfc=1`.
  Witness: "hello" (68 65 6C 6C 6F) has no 0xCC/0xCD bytes and so
  returns is_nfc=1. Covers the fast-path heuristic claim that
  pure-ASCII inputs are declared NFC immediately.

## Compatibility

M8 is additive: it introduces one new module (`IpcNfc`) with two
public bindings and preserves every M1 + M2 + M3 + M4 + M5 + M6 + M7
symbol unchanged. v1.7.0 is backward-compatible with every prior
version at every symbol granularity.

The scan loop's byte-level dispatch is designed so later milestones
(M8.3 for Devanagari/Arabic/Hebrew/CJK) can grow it by adding more
`cmp rax, 0xXX; je ipc_chk_not_nfc` lines without touching the
control-flow skeleton. The check's return shape (packed u64 with
is_nfc in the high 32 bits) has room for a future flags byte should
the heuristic ever need to communicate "I did a scan plus a partial
decode" to the caller.

## Roadmap

- **M8.1** -- VPC / pds / shell / terminal receive-wrapper audit.
  Add `_ipc_nfc_apply` calls at every known IPC string-field site;
  record the audit in a design/toolchain/ipc-nfc-audit.md manifest
  so the convention becomes grep-visible and reviewable.
- **M8.2** -- `_ipc_nfc_check_exact(bytes_ptr, bytes_len, workbuf_ptr,
  workbuf_cap) -> packed_u64`. An opt-in exact predicate that calls
  `_norm_nfc` and byte-compares the output against the input. Slow
  (O(n) scan + full normalise + O(n) compare) but zero-false-negative;
  intended for conformance tests and for IPC paths where even one no-op
  apply call is too costly.
- **M8.3** -- Table-synchronised scan growth. As M3 grows (Devanagari
  at M3.2, Arabic/Hebrew at M3.3, CJK at M3.4), extend the check's
  scan loop in lockstep so false-negative rates stay bounded on
  non-Latin inputs.
- **M8.4** -- `_ipc_nfkc_apply(bytes_ptr, bytes_len, out_ptr, out_cap)
  -> packed_u64`. Compatibility-fold sibling for IPC sites that need
  NFKC rather than NFC (e.g. fullwidth-ASCII cleanup for Japanese IME
  input flowing to a sh shell). Thin wrapper over `_norm_nfkc`.
- **M8.5** -- Caller-supplied workspace argument (coordinated with
  M3.3's scratch migration). When M3 moves its scratch from static
  .bss to a caller-supplied workspace argument, `_ipc_nfc_apply`
  grows a workspace argument too. This is a BREAKING change and
  bumps the library's MAJOR version.
- **M8.6** -- Kernel-side hook. Still deferred; may land only when a
  per-channel string-field manifest convention lands independently
  (unlikely in R131).

## Upstream references

- paideia-os#2480: R131 Unicode substrate umbrella issue.
- paideia-os#2612..#2618: M1..M7 of this library.
- paideia-os#2619: THIS M8 ticket.
- unicode.org/reports/tr15: TR#15 Unicode Normalization Forms.
- RFC 8264: PRECIS framework (industry convention for canonicalising
  identifiers at network boundaries).
- `src/kernel/core/ipc/`: paideia-os IPC channel implementations
  whose receive paths are the eventual call sites of this hook
  (deferred to M8.1 ring-3 wrapper audit).
- `tools/paideia-as/crates/paideia-as-unicode/`: Rust-side mirror of
  this library's primitives.
