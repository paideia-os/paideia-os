# PaideiaOS — Building and running

PaideiaOS is in bootstrap phase. The kernel currently boots under QEMU via
direct `-kernel` load, enters `_start`, and halts. Long-mode transition, a
COM1 UART driver, and the capability system land in subsequent first-milestone
phases. Treat the build as a smoke test of the toolchain end-to-end, not as
a running OS.

## Prerequisites

- `git` with submodule support.
- Rust toolchain (≥ 1.80) — required to build the `paideia-as` assembler.
- GNU `ld` from binutils — links the assembled objects into an ELF64 kernel.
- `qemu-system-x86_64` — runs the resulting kernel.

Debian / Ubuntu:

```sh
sudo apt install git build-essential binutils qemu-system-x86 rustup
rustup default stable
```

Fedora:

```sh
sudo dnf install git binutils qemu-system-x86 rust cargo
```

## First-time setup

Clone with submodules and build the assembler once:

```sh
git clone --recursive https://github.com/paideia-os/paideia-os.git
cd paideia-os

# If you cloned without --recursive:
git submodule update --init --recursive

(cd tools/paideia-as && cargo build --release -p paideia-as)
```

The assembler binary lands at `tools/paideia-as/target/release/paideia-as`.
`tools/find-paideia-as.sh` resolves it and enforces the v0.4.0+ minimum.

## Build

```sh
./tools/build.sh
```

Expected output:

```
[build] paideia-as boot/entry.pdx -> boot/entry.o
[link]  ld -T link.ld -> kernel.elf
[ok]    build/kernel.elf
```

The build script walks `.pdx` sources under `src/kernel/`, invokes
`paideia-as build --emit elf64` for each, then links the objects through
`src/kernel/link.ld` into `build/kernel.elf`.

## Run

```sh
./tools/run-qemu.sh
```

Under the hood:

```sh
qemu-system-x86_64 -kernel build/kernel.elf \
                   -serial stdio -display none \
                   -no-reboot -no-shutdown -m 256M
```

Expected behaviour today: QEMU loads the kernel, jumps to `_start`, and
halts with `cli; hlt; jmp $-1`. There is no serial output yet — the UART
driver lands in the first-milestone Phase-1. Exit QEMU with `Ctrl-A` then `X`.

## Verifying the build

```sh
file build/kernel.elf
readelf -h build/kernel.elf
```

`file` should report an ELF 64-bit LSB executable. `readelf -h` should show
an Entry point address of `0x100000` (1 MiB), matching `link.ld`.

## What works and what does not (today)

Works:

- `paideia-as` submodule resolution via `tools/find-paideia-as.sh`.
- `.pdx` assemble + ELF64 link chain.
- QEMU `-kernel` direct load and execution to halt.

Gated on `paideia-as` walker activation (see
`design/toolchain/phase-transition-4.md` §2): records, generics, borrowed
references, and stdlib types pass `paideia-as check` but `build` for those
forms is per-walker-gated. The kernel `.pdx` sources stay on the Phase-1/2
lowest-common-denominator surface — `let`, `fn`, `match`, `*T`, `unsafe` —
until the relevant walkers activate.

Phase-1 next steps:

- 32 → 64 long-mode transition in `_start`.
- COM1 UART driver in `src/kernel/drivers/uart.pdx`.
- `"PaideiaOS booting..."` serial banner.
- First capability-system primitives per `design/capabilities/phase1-api.md`.

## Pointers

- `design/infrastructure/build-system.md` — full toolchain contract.
- `design/infrastructure/boot-path.md` — boot mechanism details and UEFI deferral.
- `design/infrastructure/first-milestone.md` — Phase-0 smoke, Phase-1 banner, capability-system roadmap.
- `design/00-feature-inventory.md` — project pillars and tier 1–4 feature catalogue.
- `tools/paideia-as/` — assembler submodule (v0.4.0+).

## Updating the paideia-as submodule

```sh
git submodule update --remote tools/paideia-as
(cd tools/paideia-as && cargo build --release -p paideia-as)
git add tools/paideia-as
git commit -m "bump paideia-as to <commit>"
```

Rebuild the kernel afterwards:

```sh
./tools/build.sh
```
