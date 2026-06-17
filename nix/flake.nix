{
  description = "PaideiaOS — clean-slate x86_64 microkernel; reproducible dev environment per design/02-development-environment.md §7.1";

  inputs = {
    # Pin nixpkgs to a known-good commit; phase 1 anchor.
    # TODO INFRA: pin to a specific commit via `flake.lock`; for now track stable.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Tool versions pinned for the phase-1 toolchain.
        # See design/02-development-environment.md §7.3 for the pinning policy.
        phase1Tools = with pkgs; [
          # Assembler (phase-1 bootstrap per milestones.md §1)
          nasm

          # QEMU + UEFI firmware + TPM emulator
          qemu          # qemu-system-x86_64, qemu-img, qemu-utils
          OVMF          # UEFI firmware
          swtpm         # TPM 2.0 emulator
          swtpm-tools

          # Disk-image tooling
          xorriso       # ISO 9660 / UEFI-bootable ISO
          mtools        # FAT32 manipulation (for EFI System Partition)
          gptfdisk      # sgdisk (GPT)
          dosfstools    # mkfs.fat

          # Debugging
          gdb
          # mozilla-rr   # Not in nixpkgs as `mozilla-rr` — investigate phase-2

          # C toolchain (for ACPICA, wasmtime port, etc. — phase 2+)
          gcc
          clang
          lld
          cmake
          pkg-config

          # Python (dev scripts, ACPI table dumps, TLA+ glue)
          python3

          # Standard utilities
          coreutils
          findutils
          gnumake
          gnused
          gawk
          which
          file
          jq

          # Git + GitHub CLI
          git
          gh
        ];

        # Phase-2+ tools (TLA+, fuzzers, etc.); not enabled in phase 1 shell
        # but listed here for forward planning.
        # tlapsm = pkgs.tlaplus;        # TLA+ tools (TODO INFRA-O1)
        # apalache = pkgs.apalache;     # symbolic model checker (TODO)
        # libfuzzer = ...;              # phase 2

        # Rust toolchain.
        # paideia-as is its own repo using rustup-managed rust. The kernel build (phase 1
        # NASM-only) does not need Rust. Rust is provided here for convenience for
        # developers who work on both repos from the same shell.
        rustToolchain = pkgs.rust-bin or pkgs.rustup;

      in {
        devShells.default = pkgs.mkShell {
          name = "paideia-os-dev";
          buildInputs = phase1Tools;

          shellHook = ''
            echo ""
            echo "  ┌────────────────────────────────────────────────────────┐"
            echo "  │  PaideiaOS development shell (phase 1)                   │"
            echo "  │  Per design/02-development-environment.md §7.1           │"
            echo "  ├────────────────────────────────────────────────────────┤"
            echo "  │  nasm     $(nasm -v 2>&1 | head -1 | sed 's/.*version //;s/ .*//')                                              │"
            echo "  │  qemu     $(qemu-system-x86_64 --version | head -1 | awk '{print $4}')                                              │"
            echo "  │  swtpm    $(swtpm --version 2>&1 | head -1 | awk '{print $NF}')                                              │"
            echo "  │  gdb      $(gdb --version | head -1 | awk '{print $NF}')                                              │"
            echo "  │  clang    $(clang --version | head -1 | awk '{print $4}')                                              │"
            echo "  └────────────────────────────────────────────────────────┘"
            echo ""
            echo "  Try: ./tools/dev/up   (when scripts are added in phase 1)"
            echo ""

            # Make OVMF firmware paths discoverable
            export OVMF_CODE=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd
            export OVMF_VARS=${pkgs.OVMF.fd}/FV/OVMF_VARS.fd
          '';
        };

        # Aliases for clarity in CI scripts
        devShells.dev = self.devShells.${system}.default;

        # Toolchain version exposure (so `./tools/dev/show-versions` etc. can query)
        packages.toolchainVersions = pkgs.writeText "toolchain-versions.json" (builtins.toJSON {
          nasm = pkgs.nasm.version;
          qemu = pkgs.qemu.version;
          ovmf = pkgs.OVMF.version or "unknown";
          swtpm = pkgs.swtpm.version;
          xorriso = pkgs.xorriso.version;
          gdb = pkgs.gdb.version;
          clang = pkgs.clang.version;
        });
      });
}
