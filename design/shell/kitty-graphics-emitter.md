# Kitty graphics protocol emitter (R129.M2)

Issue: paideia-os#2605
Wave:  UMB-W16
Lands: 2026-10-13

## 1 Why

The paideia-os terminal substrate is text first by discipline, but
the exogenous world is not: an operator inspecting a semantic query
result, a debugger displaying a heap-shape thumbnail, a jail
supervisor rendering a per-container memory map, or a shell command
piping a captured frame all want to put a *bitmap image* inline in
the terminal grid, between prompts, without opening a graphical
window.

Three mainstream terminal emulators -- iTerm2, Kitty, and WezTerm --
answer that with the **Kitty graphics protocol**: a wire format that
wraps pixel bytes in a base64 payload inside an Application Program
Command (APC) escape sequence.  The APC envelope passes through the
tty line discipline transparently: cooked-mode cannot eat it, raw-
mode does not need to be flipped, and the terminal renders the
image at the current cursor row without disturbing the character
grid around it.

R129 is the paideia-os umbrella for terminal-capability features.
R129.M1 (Wave UMB-W15, paideia-os#2604) landed the XTGETTCAP DCS
round-trip helper that lets the kernel ask the terminal which
capabilities it advertises.  **R129.M2 lands the emitter**: a
kernel-side helper that takes a 32-bit RGBA pixel buffer, chunks it
to the Kitty APC payload cap, base64-encodes each chunk, and writes
the resulting APC stream to the UART.

## 2 Wire protocol

### 2.1 APC envelope

```
  ESC '_' G <control-list> ; <base64-payload> ESC '\'
```

where

* `ESC`          = 0x1B
* `'_'`          = 0x5F  (APC introducer; distinct from DCS `'P'`)
* `G`            = 0x47  (Kitty graphics selector)
* `<control-list>` = comma-separated `key=value` pairs
* `';'`          = 0x3B  (separator between controls and payload)
* `<base64>`     = standard RFC 4648 encoding of the pixel bytes,
                   without `=` padding at chunk boundaries
* `ESC '\'`      = 0x1B 0x5C  (String Terminator / ST)

The APC introducer is deliberately different from the DCS
introducer that XTGETTCAP uses (`'P'`): a terminal that understands
one but not the other must be able to tell them apart without any
state-machine ambiguity.  Both share the ST tail byte, which keeps
the dispatcher simple on the receive side.

### 2.2 Control keys emitted at M2

| Key | Value             | Meaning                                      |
| --- | ----------------- | -------------------------------------------- |
| `a` | `T`               | Transmit **and** display (immediate render)  |
| `f` | `32`              | Pixel format = 32-bit RGBA                   |
| `s` | decimal `<W>`     | Image width, in pixels (1..1024)             |
| `v` | decimal `<H>`     | Image height, in pixels (1..1024)            |
| `m` | `0` or `1`        | Chunk continuation: `1` = more follows, `0` = final chunk |

The first chunk of every transmission emits the full
`a=T,f=32,s=<W>,v=<H>,m=<F>;` prefix.  Subsequent chunks emit only
`m=<F>;` -- the Kitty terminal keys subsequent chunks to the same
image id by their arrival order within one APC burst and inherits
the width/height from the first chunk.

### 2.3 Not emitted at M2

The Kitty protocol defines dozens of control keys beyond the five
above.  M2 excludes the following, with rationale:

* `i=<N>` -- explicit image id.  Omitting it lets the terminal
  auto-assign; a future wave gains id control once the kernel wants
  to update an on-screen image rather than re-transmit.
* `z=<N>` -- z-index for layering.  Omitting it uses the terminal's
  default layer (above the character grid, below the cursor).
* `C=<N>` -- cursor-move policy.  Omitting it uses the Kitty
  default (cursor advances by the image's cell footprint).
* `q=<N>` -- quiet mode (suppress terminal-side status replies).
  Omitting it is harmless at M2 because the kernel does not drain
  the status reply; a late reply landing in `_uart_rx_ring` while
  the kernel is idle is dropped by the ring overflow policy.
* `d=<key>` -- image delete / dismiss.  Not needed at M2.
* `f=100` (PNG) / `f=24` (RGB without alpha).  M2 is RGBA-only.

## 3 Chunking policy

### 3.1 Payload cap

The portable Kitty-protocol floor for a single APC payload is
**4096 base64 characters**.  Some terminals accept more (Kitty itself
accepts arbitrarily large APC bodies up to a configurable
`clipboard_max_size`), but 4096 is the number every known
implementation respects.  R129.M2 pins the per-chunk payload at
exactly 4096 base64 characters, which maps to **3072 raw bytes** on
the input side (3 raw bytes -> 4 base64 chars).

### 3.2 Final-chunk tail

The final chunk may carry fewer bytes than the payload cap.  Three
cases:

* `remaining mod 3 == 0` -- the final chunk encodes `remaining`
  raw bytes to `4 * remaining / 3` base64 characters, exactly.
* `remaining mod 3 == 1` -- the final chunk encodes `remaining-1`
  bytes to `4 * (remaining-1) / 3` chars PLUS a 2-char tail
  (sextets `b0 >> 2` and `(b0 & 0x03) << 4`).
* `remaining mod 3 == 2` -- the final chunk encodes `remaining-2`
  bytes to `4 * (remaining-2) / 3` chars PLUS a 3-char tail
  (sextets `b0 >> 2`, `((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0F)`,
  and `(b1 & 0x0F) << 2`).

In all three cases **no `=` padding is emitted on the wire**.  The
Kitty graphics protocol specifically forbids inline padding inside
a multi-chunk transmission; the reassembler keys off `m=0` to
finalise.

### 3.3 Why chunk at the base64 output size, not the raw input size

The APC payload is on the wire as base64, so the terminal's APC
reassembler cares about the base64 character count, not the pre-
encode raw byte count.  Chunking at the raw-input level
(e.g. "always 4096 raw bytes per chunk") would push some chunks over
the terminal's APC-body limit (4096 * 4/3 = 5461 chars) and would
inflate the tail chunk's size variance uselessly.

Chunking at 3072 raw bytes -> 4096 base64 chars gives:

* every intermediate chunk is exactly 4096 chars (payload only;
  the control block adds ~20 chars extra on the first chunk, well
  under any dispatcher's envelope quota);
* the raw chunk size is a multiple of 3, so no intermediate chunk
  carries a partial-sextet tail -- only the final chunk may.

### 3.4 Chunk-count bounds

Max image: 1024 x 1024 pixels x 4 bytes/pixel = 4 MiB raw.
Chunks: ceil(4 MiB / 3072) = ceil(4194304 / 3072) = 1366 chunks.

At 115200 baud over COM1 (`\~14 KB/s` of 8N1 after ASCII framing),
emitting 4 MiB of base64 + control overhead takes ~400 seconds.
A 128 x 128 thumbnail (64 KiB raw, ~87 KiB base64) emits in
~6 seconds.  R129.M3+ can gate large emits on a cooperative
cancellation flag to make the user able to abort mid-transmission.

## 4 Base64 encoder

### 4.1 Alphabet

Standard RFC 4648:

```
  A-Z   -> indices 0..25
  a-z   -> indices 26..51
  0-9   -> indices 52..61
  '+'   -> index 62
  '/'   -> index 63
```

The URL-safe variant (`'-'` and `'_'` in place of `'+'` and `'/'`)
is **not** used.  Kitty's protocol spec is explicit that the
payload is RFC 4648 base64, not the URL-safe variant.

### 4.2 Encoder signature

```
  _kg_b64_encode_chunk(src_ptr, src_len, out_ptr) -> u64
```

Encodes `src_len` bytes from `src_ptr` into base64 characters at
`out_ptr`.  Returns the number of characters written:

```
  out_len = (src_len / 3) * 4                 if src_len mod 3 == 0
          = (src_len / 3) * 4 + 2             if src_len mod 3 == 1
          = (src_len / 3) * 4 + 3             if src_len mod 3 == 2
```

No bounds check on `out_ptr`: the caller sizes the output buffer
to KG_CHUNK_B64 (4096) and never passes `src_len > KG_CHUNK_RAW`.

### 4.3 Encoder shape

The encoder is a leaf (no nested calls), driven by a 64-byte
immutable lookup table (`_kg_b64_table`) indexed by the 6-bit
sextet value.  Three callee-save pushes (rbx = src, r12 = src_len,
r13 = dst) give the body a stable base; the loop keeps i (src
offset) in rcx and j (dst offset) in r9.

Main loop body (one iteration consumes 3 raw bytes and produces
4 base64 chars):

```
  b0 = src[i]
  b1 = src[i+1]
  b2 = src[i+2]

  s0 = (b0 >> 2) & 0x3F
  s1 = ((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0F)
  s2 = ((b1 & 0x0F) << 2) | ((b2 >> 6) & 0x03)
  s3 = b2 & 0x3F

  dst[j]   = alphabet[s0]
  dst[j+1] = alphabet[s1]
  dst[j+2] = alphabet[s2]
  dst[j+3] = alphabet[s3]

  i += 3
  j += 4
```

Tail: when `src_len - i` is 1 or 2, emit the 2- or 3-char tail
without padding and return.

## 5 Capability detection (interaction with R129.M1)

### 5.1 The direct question has no direct answer

There is no XTGETTCAP capability name standardised as "kitty
graphics supported".  The three main implementations each advertise
their support differently:

* **Kitty** -- responds to a Kitty-protocol-specific DA3 report
  (`CSI = c`) and to a dedicated graphics-protocol query
  (`CSI ? 1 c` family).
* **iTerm2** -- advertises via its own XTVERSION reply (`CSI > q`)
  and the `TN` XTGETTCAP cap (`TN=iterm2`), but not as a dedicated
  cap name.
* **WezTerm** -- advertises via XTVERSION (`CSI > q`) and the `TN`
  cap (`TN=wezterm`).

Writing three sniffers for three terminal-string replies is work
that R129.M3+ will do.  M2 uses a **one-way heuristic** instead.

### 5.2 The heuristic: probe `RGB`

Every known Kitty-graphics-capable terminal (iTerm2 >= 3.3, Kitty,
WezTerm) also advertises the `RGB` XTGETTCAP truecolor cap (24-bit
colour).  The contrapositive is also true in practice: terminals
that do **not** advertise `RGB` (xterm in its default build, foot,
VT100 fallbacks, early-boot EFI consoles) do not implement Kitty
graphics either.

M2's `_kitty_graphics_available(tty_fd)` returns:

* **1** iff `_xtgettcap_probe(tty_fd, "RGB", ...)` returns
  `status == XT_OK` AND `bytes_written > 0`.
* **0** otherwise (unknown cap, no response, malformed response,
  or XT_OK with empty value).

This is a one-way inference, not a cryptographic proof:

* **False positive risk**: a hypothetical terminal that advertises
  `RGB` but does not implement Kitty graphics would be mis-classified
  as supporting.  No such terminal is currently known.  The failure
  mode is benign: the APC emit either paints garbage or is dropped
  silently by the terminal's unknown-sequence handler.  Neither
  action breaks the kernel.
* **False negative risk**: a terminal that supports Kitty graphics
  but does not advertise `RGB` would be mis-classified as not
  supporting.  No such terminal is currently known.  The failure
  mode is caller-side: the caller skips a legitimate inline-image
  opportunity and falls back to text.

### 5.3 Caller contract

`_kitty_graphics_available` is a thin wrapper over
`_xtgettcap_probe` and inherits the latter's caller contract:

* The TTY must be in raw mode (SS_RAW_FLAG_RAW_MODE on the current
  shell session; see design/shell/raw-mode-tty.md) so the
  XTGETTCAP response bytes land in `_uart_rx_ring` without being
  consumed by cooked-mode line-discipline processing.
* The probe is bounded by the XTGETTCAP 100 ms deadline; a silent
  terminal costs 100 ms once per session.
* The probe is non-reentrant (shares `_xt_resp_buf` with any
  other XTGETTCAP caller).  R129.M2's own emit path does NOT call
  the probe -- `_kitty_image_rgba` trusts the caller to gate on
  `_kitty_graphics_available` beforehand, so the two never run
  concurrently.

### 5.4 Deferred: direct capability query

R129.M3+ will land a direct Kitty-graphics capability probe based on
one of:

* XTVERSION (`CSI > q`) parsing with a per-terminal brand table.
* Kitty's own `CSI ? 1 c` graphics-support report.
* A dedicated XTGETTCAP cap name registered against the Kitty-
  protocol community (not yet proposed upstream as of 2026-10).

M3's probe will replace M2's heuristic without changing the
`_kitty_graphics_available` signature.

## 6 Interaction with R127.M3 raw-mode (not required)

R127.M3 (Wave UMB-W14, paideia-os#2599) stamped the per-shell-
session raw-mode flag that XTGETTCAP requires.  **Kitty APC
emission does NOT require raw mode on the TX side**.

The reason is that the APC introducer `ESC _ G` is not interpreted
by the cooked-mode line discipline: `tty_process_input` only
inspects RX bytes (what the terminal sends to the kernel), never
TX bytes (what the kernel sends to the terminal).  The kernel's
side of the pipe can emit any byte sequence it likes, including
raw ESC sequences, without disturbing the ICANON+ECHO+ICRNL
state on the inbound line.

The symmetrical observation is important: a Kitty APC emission
**can safely run while the shell is in cooked mode**.  No raw-mode
flip is needed, and no raw-mode flip is undertaken by
`_kitty_image_rgba`.  The caller does not need to coordinate with
the shell-session's raw-mode state the way an XTGETTCAP caller does.

The one caveat: if the caller intends to call
`_kitty_graphics_available` immediately before the emit, that
probe DOES require raw mode (because it waits on an inbound DCS
response).  The common pattern is:

```
  _shell_session_set_raw(sid, SS_RAW_FLAG_RAW_MODE)
  ok = _kitty_graphics_available(tty_fd)
  _shell_session_set_raw(sid, 0)
  if ok:
    _kitty_image_rgba(tty_fd, pixels, W, H)
```

The emit happens *after* raw mode is restored to the shell's
cooked default, which is correct and safe.

## 7 Return codes

| Value   | Symbol                   | Meaning                                       |
| ------- | ------------------------ | --------------------------------------------- |
| 0x0000  | `KG_OK`                  | emission complete; final chunk's `m=0` sent   |
| 0x1700  | `KG_ERR_UNSUPPORTED`     | reserved (not returned by M2's helpers)       |
| 0x1701  | `KG_ERR_IMAGE_TOO_LARGE` | width > 1024 or height > 1024                 |
| 0x1702  | `KG_ERR_BAD_DIMENSIONS`  | width == 0 or height == 0                     |

The 0x17xx band is otherwise unused and leaves room for
`KG_ERR_IO`, `KG_ERR_BAD_FORMAT`, etc. at R129.M3+.

`KG_ERR_UNSUPPORTED` is reserved for the day the emitter gains a
"gate on `_kitty_graphics_available` internally" mode.  M2's
`_kitty_image_rgba` does NOT re-probe (saves 100 ms per emit); the
caller is expected to have gated upstream.  An emission against an
unsupported terminal silently paints garbage or no-ops -- the
kernel does not detect this.

## 8 Scratch allocation

The directive mandates a 32 KiB `.bss` footprint for chunk-staging +
base64 output.  The current layout uses:

| Symbol              | Size (bytes) | Purpose                                      |
| ------------------- | -----------: | -------------------------------------------- |
| `_kg_b64_chunk`     | 4096         | per-chunk base64 output                      |
| `_kg_dec_scratch`   | 32           | decimal-digit reversal for itoa              |
| `_kg_scratch`       | 28640        | reserve for future chunk-reassembly / diffs  |
| **Total**           | **32768**    |                                              |

The 28640-byte reserve is unused at M2 and left in place so a
future wave can allocate (for example) a two-APC reassembly slab
for frame-diff emission without touching the module's export table.

## 9 Supported encoder subset

The module uses only paideia-as mnemonics proven at prior landings:

```
  mov, mov_b, lea, add, sub, and, or, xor, shl, shr, imul, div,
  cmp, je, jne, jb, jbe, ja, jae, jmp, call, ret, push, pop
```

Explicitly avoided (per the recurring pdx encoder pitfall memo):

* `test rN, rN`                 -> replaced with `cmp rN, 0; j{e,ne}`
* 2-op `imul rN, imm`           -> replaced with reg-reg `imul rN, rN`
                                   plus `shl rN, imm` for *4 scaling
* `and rN, imm64`               -> all masks fit in imm8 or imm32
                                   (`0x03`, `0x0F`, `0x3F`)
* multiline `pub let = "..."`   -> every declaration single-line
* `mov rN, [rip + sym]`         -> every RIP-relative load is
                                   `lea rN, [rip + sym]` followed by
                                   a `mov_b` / `mov` through rN

Module basename `KittyGraphics` matches the file name
`kitty_graphics.pdx`.  Label discipline: six prefixes keep the
namespaces non-colliding across sibling modules and avoid pdx-
level reserved keywords.

```
  kgb_     _kg_b64_encode_chunk
  kgd_     _kg_tx_u64_dec
  kge_     _kg_emit_chunk
  kga_     _kitty_graphics_available
  kgi_     _kitty_image_rgba
```

None of these clash with pdx-level reserved keywords (`loop`,
`if`, `let`, `fn`, `else`, `return`, `module`, `pub`, ...).

## 10 Scope boundaries

### 10.1 M2 does NOT

* dispatch on `tty_fd`.  Every byte goes through `uart_putc`;
  the parameter is accepted and ignored, parity with the
  XTGETTCAP probe's M1 contract.
* flip raw mode on behalf of the caller (unnecessary on the TX
  side; see section 6).
* retry on partial-write.  `uart_putc` is a blocking polled
  write; a UART-level stall is impossible to observe from this
  layer and would be surfaced by the UART driver itself.
* re-probe capability on every emit.  Callers gate upstream.
* defend against concurrent emits (shares `_kg_b64_chunk` with
  any other emit in flight; non-reentrant by design, matching
  the XTGETTCAP probe's own non-reentrancy).
* log fingerprints.  The emit is silent on the klog; a caller
  that wants a trace wraps the call in its own klog.
* support non-RGBA pixel formats (f=24, f=100).
* support image placement options (z-index, cursor-move policy,
  explicit image id, delete / dismiss ops).
* support frame diffs or animation (a=f, a=a).
* cancel mid-transmission.  A 4 MiB image at 115200 baud is a
  ~400 second commit; M3+ should expose a cooperative abort flag.

### 10.2 Follow-up tickets

* **R129.M3** -- direct Kitty-graphics capability probe (replaces
  M2's RGB heuristic).  See section 5.4.
* **R129.M4** -- image placement options: z-index, cursor-move
  policy, explicit image id, programmatic delete.
* **R129.M5** -- frame diffs and animation: a=f / a=a controls,
  per-frame id reuse.
* **R129.M6** -- compressed format passthrough (f=100 PNG, f=24
  RGB without alpha).
* **R129.M7** -- cooperative cancellation flag for large emits.

## 11 Reference wire example

A 2x2 red opaque RGBA image (16 bytes raw):

```
  pixels = [
    0xFF, 0x00, 0x00, 0xFF,    // (0,0) red
    0xFF, 0x00, 0x00, 0xFF,    // (1,0) red
    0xFF, 0x00, 0x00, 0xFF,    // (0,1) red
    0xFF, 0x00, 0x00, 0xFF,    // (1,1) red
  ]
```

Call:

```
  _kitty_image_rgba(tty_fd=0, pixels, 2, 2)
```

Wire emission (one chunk; 16 raw bytes fits well under KG_CHUNK_RAW):

* raw bytes = 16, so 16 mod 3 == 1 -> final chunk emits
  `(16/3)*4 = 20` chars plus a 2-char tail = **22 base64 chars**.
* The 16 bytes `0xFF 0x00 0x00 0xFF` repeated 4 times base64-encode
  to `/wAA//8AAP//AAD//wAA` (20 chars) plus the 2-char tail for
  the final byte, giving `/wAA//8AAP//AAD//wAAwA` (22 chars).

Full wire:

```
  1B 5F 47 61 3D 54 2C 66 3D 33 32 2C 73 3D 32 2C 76 3D 32 2C 6D 3D 30 3B
   ESC  _  G  a  =  T  ,  f  =  3  2  ,  s  =  2  ,  v  =  2  ,  m  =  0  ;

  2F 77 41 41 2F 2F 38 41 41 50 2F 2F 41 41 44 2F 2F 77 41 41 77 41
    /  w  A  A  /  /  8  A  A  P  /  /  A  A  D  /  /  w  A  A  w  A

  1B 5C
   ESC  \
```

Total emitted: 3 (introducer) + 20 (controls) + 1 (semicolon) +
22 (payload) + 2 (ST) = **48 bytes on the UART**.

A 128 x 128 thumbnail (65536 raw bytes = 21 chunks of 4096 base64
each + 1 partial) emits in approximately 90000 bytes on the UART,
including per-chunk control overhead.
