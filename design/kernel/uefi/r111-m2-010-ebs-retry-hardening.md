# R111.M2-010 — ExitBootServices retry hardening for Insyde H2O

**Issue:** paideia-os #2362
**Milestone:** R111.M2
**Site of change:** `src/boot/uefi_stub.pdx` §`efi_finalize_and_handoff`
**Fingerprint gate:** `tools/verify-fingerprint-coverage.sh` (allowlist entry `"UEFI EBS OK"`)

## Motivation

Insyde H2O firmware (as shipped on the Lenovo ThinkPad T14 Gen 4 that
gates the R111 boot bring-up matrix) has been observed to return
`EFI_INVALID_PARAMETER` (`0x8000000000000002`) from `ExitBootServices`
when the `MapKey` we hold has been invalidated by an intervening
`AllocatePages` that **firmware itself** performs between our
`GetMemoryMap` probe and our `ExitBootServices` call.

The UEFI 2.10 §7.4.6 canonical workaround is a bounded retry loop that
re-invokes `GetMemoryMap` to refresh the key. The pre-R111 R19.M4-004
implementation:

- capped at **3** attempts (originally sized to OVMF, where firmware
  never allocates during the window, so 1 attempt always suffices;
  3 was a safety pad);
- retried on **any** non-zero status (correct-ish for OVMF where the
  only observed failure mode was stale-key, but ambiguous under real
  firmware where non-retriable statuses are possible).

R111.M2-010 tightens both bounds to match observed Insyde behaviour and
UEFI-spec discipline:

## Hardening

| Aspect            | Before R111.M2-010 | After R111.M2-010 |
|-------------------|--------------------|-------------------|
| Attempt cap       | 3                  | **4** (Insyde retry-depth empirical) |
| Retry condition   | any non-zero       | **only `EFI_INVALID_PARAMETER`** |
| Non-retriable status | retried (up to 3× wasted) | immediate bail via `efi_panic_on_fatal` (pre-R111 error path preserved) |
| Success telemetry | none               | COM1 fingerprint `UEFI EBS OK attempts=<n>` |
| Failure telemetry | ConOut only (`_panic_ebs_msg`) | COM1 fingerprint `UEFI EBS FAIL exhausted=4 last_status=0x<hex>` |

## Wire lines emitted

- Success (n in 1..4):
  ```
  UEFI EBS OK attempts=<n>\r\n
  ```
- Exhaustion (4 consecutive `EFI_INVALID_PARAMETER` returns):
  ```
  UEFI EBS FAIL exhausted=4 last_status=0x<16hex>\r\n
  ```
  (The hex is the raw `EFI_STATUS` from the 4th failing attempt —
  ordinarily `0x8000000000000002`, but any observed value is emitted
  verbatim for post-mortem inspection.)

Both lines are emitted directly to COM1 (`0x3F8` THR, poll `0x3FD` bit 5
THRE) via three stub-local helpers introduced in the same landing:

- `stub_com1_init`  — 7-port NS PC16550D §3.3 canonical init
- `stub_com1_puts`  — `(buf, len)` write with THRE polling
- `stub_u64_to_hex` — byte-identical to `src/kernel/core/klog/hex.pdx`
                       §`u64_to_hex`

These are duplicated in the stub (rather than linked from the kernel)
because `paideia-as v0.20.1 build --target uefi-x86_64` accepts one
`.pdx` translation unit; the multi-file-link enhancement will retire
the duplication.

## Critical invariant preserved

UEFI 2.10 §7.4.6 requires that no other Boot Service is invoked and no
allocation occurs between `GetMemoryMap` and `ExitBootServices` — else
firmware's internal map serial advances and the freshly latched
`MapKey` becomes stale immediately.

The retry-hardening emit paths (`stub_com1_*`) run **after** the loop
terminates: after `ExitBootServices` returns `EFI_SUCCESS` on the OK
path, and after the 4th `EFI_INVALID_PARAMETER` on the FAIL path. Neither
sits inside the critical section. The `_ebs_last_status` latch is a
pure-memory `mov [rip+…], rax` that also does not invalidate the key.

## Register discipline

- `r15` holds the 1-based attempt counter (1..4). Survives across
  `efi_get_memory_map`, `efi_exit_boot_services`, `stub_com1_init`,
  `stub_com1_puts`, and `stub_u64_to_hex` because all callees respect
  SysV/MS-x64 non-volatile discipline for r15 (either explicitly saved
  by firmware wrappers or simply not touched by leaf helpers).
- Helper functions use only volatile scratch (`r10`, `r11`, `rax`,
  `rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r9`) and are declared `@no_frame`.

## Fingerprint-coverage gate

`tools/verify-fingerprint-coverage.sh` extracts byte-array literals
whose content contains an `OK` token and requires each to be either
asserted in a golden or explicitly allowlisted with a reason. The
`_ebs_ok_hdr` array (11 bytes = `"UEFI EBS OK"`) is broken out from
the `" attempts="` separator so the allowlist key matches the literal
exactly — mirroring the `"UEFI BRIDGE OK"` / `"UEFI PML4 OK"`
convention.

The FAIL prefix carries no `OK` token and is therefore invisible to
the extractor by design; no allowlist entry is added for it (and one
would trip the stale-allowlist gate).

## Follow-ups

- Retire the `"UEFI EBS OK"` allowlist entry when R111.M2 opens
  `boot_r111_uefi_bridge` OVMF smoke mode that boots past
  `ExitBootServices` and pins the exact wire line.
- Land a synthetic OVMF fixture (or real-HW T14 G4 smoke per
  `design/roadmap/t14-bootable-usb-wave.md`) that forces the FAIL
  path — currently unreachable in the QEMU/OVMF matrix because OVMF
  does not allocate between our probe and our exit.
- When `paideia-as` multi-file-link lands, migrate
  `stub_com1_init` / `stub_com1_puts` / `stub_u64_to_hex` to their
  canonical kernel-side homes and link them into the stub instead of
  duplicating.
