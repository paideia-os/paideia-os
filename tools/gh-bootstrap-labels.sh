#!/usr/bin/env bash
# Bootstrap GitHub labels for PaideiaOS
# Usage: bash tools/gh-bootstrap-labels.sh
# Requires: gh CLI authenticated with paideia-os/paideia-os access

set -euo pipefail

REPO="paideia-os/paideia-os"

# Check GitHub auth
if ! gh auth status >/dev/null 2>&1; then
    echo "✗ GitHub auth failed. Run: gh auth login" >&2
    exit 1
fi

echo "Bootstrapping labels for $REPO..."

# Phase labels (15)
declare -a PHASE_LABELS=(
    "phase:0|Bootstrap — build chain, submodule wiring, skeletal kernel entry, halt loop. **Closed 2026-06-20**."
    "phase:1|Long-mode + UART + banner. Per first-milestone.md §2."
    "phase:2|Capability system — Phase-1 cap API per design/capabilities/phase1-api.md."
    "phase:3|IPC primitive + scheduler bring-up."
    "phase:4|Memory manager — page allocator, virtual-memory regions, per-AS cap tables."
    "phase:5|Driver framework — area:drivers; first real device drivers (PCIe enumeration, AHCI or NVMe)."
    "phase:6|Filesystem — first read-only FS (area:fs); paideia-os-native FS spec consumes it."
    "phase:7|Driver framework + PCIe + NVMe + first NIC (planning only at Phase-4 entry)."
    "phase:8|Network stack — User-space TCP/QUIC (per design/network/*.md)."
    "phase:9|Filesystem — CoW capability-encoded FS (Q4 binding)."
    "phase:10|Userspace runtime — WASM/VM jail (Q9 binding)."
    "phase:11|Semantic terminal — Per design/terminal/*.md."
    "phase:12|UEFI real-hardware boot transition (per BP-D3 deferral)."
    "phase:13|Hardening — Mitigations + PQ trust root + SMP scaling."
    "phase:14|Self-hosting groundwork (Phase 5+ paideia-as side)."
)

for label_def in "${PHASE_LABELS[@]}"; do
    IFS='|' read -r label desc <<< "$label_def"
    gh label create "$label" --repo "$REPO" --description "$desc" --color "5319E7" --force 2>/dev/null || true
done

# Area labels (13)
declare -a AREA_LABELS=(
    "area:boot|src/kernel/boot/** — long-mode trampoline, UART, banner, early init."
    "area:cap|src/kernel/core/cap/** — capability descriptors, ops, revocation, per-AS tables."
    "area:ipc|src/kernel/core/ipc/** — message-passing primitive, port/endpoint abstractions."
    "area:sched|src/kernel/core/sched/** — multicore scheduler, runqueues, IPI plumbing."
    "area:mm|src/kernel/core/mm/** — physical and virtual memory, page tables, allocators."
    "area:drivers|src/kernel/drivers/** — device drivers and the driver framework."
    "area:net|src/kernel/net/** + src/userspace/net/** — kernel net path + userspace stack."
    "area:fs|src/kernel/fs/** + src/userspace/fs/** — filesystem code on both sides."
    "area:terminal|src/userspace/terminal/** — semantically-queryable terminal."
    "area:userspace|src/userspace/** excluding terminal, net, fs — userspace runtime, init, shell."
    "area:security|Cross-cutting; PQ crypto, attestation, audit log, capability-revocation semantics."
    "area:toolchain|tools/paideia-as/ submodule bumps + Linux-host build flow."
    "area:infra|tools/build.sh, tools/run-qemu.sh, nix/, .githooks/, .github/, CI workflows."
)

for label_def in "${AREA_LABELS[@]}"; do
    IFS='|' read -r label desc <<< "$label_def"
    gh label create "$label" --repo "$REPO" --description "$desc" --color "0E8A16" --force 2>/dev/null || true
done

# Type labels (7)
declare -a TYPE_LABELS=(
    "type:feature|New user-visible or kernel-internal capability."
    "type:bug|Fixes a defect; requires a regression test."
    "type:refactor|Behavior-preserving code reshape; tests must pass unchanged."
    "type:perf|Performance change with measurement; requires tools/bench/ artifact."
    "type:test|Test or fixture additions only."
    "type:doc|Documentation only (design docs, /// comments, READMEs)."
    "type:infra|CI / build / tooling / hook changes."
)

for label_def in "${TYPE_LABELS[@]}"; do
    IFS='|' read -r label desc <<< "$label_def"
    gh label create "$label" --repo "$REPO" --description "$desc" --color "1D76DB" --force 2>/dev/null || true
done

# Size labels (4)
declare -a SIZE_LABELS=(
    "size:xs|≤ 50 LOC"
    "size:s|51–200 LOC"
    "size:m|201–500 LOC"
    "size:l|501–1000 LOC"
)

for label_def in "${SIZE_LABELS[@]}"; do
    IFS='|' read -r label desc <<< "$label_def"
    gh label create "$label" --repo "$REPO" --description "$desc" --color "FBCA04" --force 2>/dev/null || true
done

# Status labels (4)
declare -a STATUS_LABELS=(
    "status:blocked|Blocked on another issue or external dependency."
    "status:in-progress|A topic branch exists; work is active."
    "status:review|PR open; self-review pending or in the cooling-off window."
    "status:done|PR merged; issue closed."
)

for label_def in "${STATUS_LABELS[@]}"; do
    IFS='|' read -r label desc <<< "$label_def"
    gh label create "$label" --repo "$REPO" --description "$desc" --color "BFD4F2" --force 2>/dev/null || true
done

# Severity labels (4)
declare -a SEVERITY_LABELS=(
    "severity:p0|Kernel does not boot OR a previously-passing smoke now fails OR security invariant broken."
    "severity:p1|Subsystem regression on main; current phase blocked."
    "severity:p2|Bug that does not block the current phase but must be fixed before the phase boundary."
    "severity:p3|Latent / cosmetic; safe to slip past the phase boundary if needed."
)

for label_def in "${SEVERITY_LABELS[@]}"; do
    IFS='|' read -r label desc <<< "$label_def"
    gh label create "$label" --repo "$REPO" --description "$desc" --color "D93F0B" --force 2>/dev/null || true
done

# Gating labels (3)
declare -a GATING_LABELS=(
    "gated:paideia-as|Waits on a paideia-as walker activation, surface addition, or codegen fix."
    "gated:hardware|Waits on access to real x86_64 hardware (QEMU-only validation is insufficient)."
    "gated:design|Blocked on an open question in a design doc."
)

for label_def in "${GATING_LABELS[@]}"; do
    IFS='|' read -r label desc <<< "$label_def"
    gh label create "$label" --repo "$REPO" --description "$desc" --color "E99695" --force 2>/dev/null || true
done

echo "✓ All labels created."
