#!/usr/bin/env bash
# Direct bootstrap of R7 next-round issues (simplified, without jq dependency)
# This version uses simpler bash parsing

set -euo pipefail

PAIDEIA_OS_REPO="paideia-os/paideia-os"
PAIDEIA_AS_REPO="paideia-os/paideia-as"
ISSUE_MAP=".plans/next-round-issue-map.tsv"
OP=0

# Backup existing map if it exists
[ -f "$ISSUE_MAP" ] && cp "$ISSUE_MAP" "$ISSUE_MAP.bak"

# Initialize
cat > "$ISSUE_MAP" << 'EOFMAP'
TaskID	Repo	Issue	Title	Milestone	Size
EOFMAP

echo "========================================="
echo "R7 Bootstrap - Direct Mode"
echo "========================================="

create_issue() {
    local repo="$1"
    local task_id="$2"
    local title="$3"
    local milestone="$4"
    local size="$5"
    local labels="$6"

    # Simple check: look for the title in the output
    echo "  Creating: $task_id..."

    # Create the issue
    local output=$(gh issue create --repo "$repo" \
        --title "$title" \
        --body "## Summary
TBD - Per osarch plan

## Acceptance criteria
- [ ] Per osarch plan

## Files
TBD

## Dependencies
Per osarch plan

## Estimated size
$size

## Phase
Per osarch plan

## Milestone
$milestone

## Repo
$repo

## Cross-repo unblock for
Per osarch plan

## Surfaced by
n/a" \
        --label "$labels" \
        --milestone "$milestone" 2>/dev/null)

    # Extract issue number from output (e.g., "https://github.com/paideia-os/paideia-as/issues/786")
    local issue_num=$(echo "$output" | grep -oP 'issues/\K\d+' | head -1)

    if [ -z "$issue_num" ]; then
        echo "    ERROR: Failed to create $task_id"
        return 1
    fi

    echo "    #$issue_num"
    echo -e "$task_id\t$repo\t#$issue_num\t$title\t$milestone\t$size" >> "$ISSUE_MAP"
    OP=$((OP+1))

    # Throttle
    if [ $((OP % 10)) -eq 0 ]; then
        echo "    [Throttle: sleeping 10s after $OP operations]"
        sleep 10
    fi
}

# PA7 (9 issues in paideia-as)
echo "PA7 Phase 7 (paideia-as)..."
create_issue "$PAIDEIA_AS_REPO" "PA7-001" "PA7-001: parser + elaborator + emit: multi-statement function body" "phase-7-fn-body-minimum-subset" "S" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:s
create_issue "$PAIDEIA_AS_REPO" "PA7-002" "PA7-002: elaborator + emit: inter-fn call dispatch with relocation" "phase-7-fn-body-minimum-subset" "S" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:s
create_issue "$PAIDEIA_AS_REPO" "PA7-003" "PA7-003: elaborator + emit: if/else expression lowering" "phase-7-fn-body-minimum-subset" "S" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:s
create_issue "$PAIDEIA_AS_REPO" "PA7-004" "PA7-004: elaborator + emit: while loop lowering" "phase-7-fn-body-minimum-subset" "S" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:s
create_issue "$PAIDEIA_AS_REPO" "PA7-005" "PA7-005: parser + elaborator: let mut at module level" "phase-7-fn-body-minimum-subset" "S" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:s
create_issue "$PAIDEIA_AS_REPO" "PA7-006" "PA7-006: elaborator + emit: 3+ argument calls" "phase-7-fn-body-minimum-subset" "S" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:s
create_issue "$PAIDEIA_AS_REPO" "PA7-007" "PA7-007: elaborator: match expression lowering" "phase-7-fn-body-minimum-subset" "S" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:s
create_issue "$PAIDEIA_AS_REPO" "PA7-008" "PA7-008: elaborator + emit: infinite loop + break" "phase-7-fn-body-minimum-subset" "XS" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:xs"
create_issue "$PAIDEIA_AS_REPO" "PA7-009" "PA7-009: emit + tests: end-to-end boot smoke fixture" "phase-7-fn-body-minimum-subset" "S" "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:s

# R1.5 (6 issues in paideia-os)
echo "R1.5 Boot reactivation (paideia-os)..."
create_issue "$PAIDEIA_OS_REPO" "R1.5-001" "R1.5-001: boot: kernel_main_64 real body" "phase-1.5-reactivation-boot" "S" "phase:1,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R1.5-002" "R1.5-002: boot: uart_init real body" "phase-1.5-reactivation-boot" "S" "phase:1,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R1.5-003" "R1.5-003: boot: uart_puts real body" "phase-1.5-reactivation-boot" "S" "phase:1,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R1.5-004" "R1.5-004: boot: _start orchestrates long-mode entry" "phase-1.5-reactivation-boot" "S" "phase:1,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R1.5-005" "R1.5-005: boot: banner data layout + content" "phase-1.5-reactivation-boot" "XS" "phase:1,phase:reactivation,next-round,type:feature,size:xs"
create_issue "$PAIDEIA_OS_REPO" "R1.5-006" "R1.5-006: tests + closure: integration QEMU smoke" "phase-1.5-reactivation-boot" "XS" "phase:1,phase:reactivation,next-round,type:feature,size:xs"

# R2.5 (8 issues)
echo "R2.5 Capability reactivation (paideia-os)..."
create_issue "$PAIDEIA_OS_REPO" "R2.5-001" "R2.5-001: cap: cap_mint real body" "phase-2.5-reactivation-capability" "S" "phase:2,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R2.5-002" "R2.5-002: cap: slab allocator real body" "phase-2.5-reactivation-capability" "S" "phase:2,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R2.5-003" "R2.5-003: cap: cap_verify real body" "phase-2.5-reactivation-capability" "S" "phase:2,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R2.5-004" "R2.5-004: cap: cap_revoke real body" "phase-2.5-reactivation-capability" "S" "phase:2,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R2.5-005" "R2.5-005: cap: LAM-tag handle encoding" "phase-2.5-reactivation-capability" "S" "phase:2,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R2.5-006" "R2.5-006: cap: cap_invoke dispatcher" "phase-2.5-reactivation-capability" "S" "phase:2,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R2.5-007" "R2.5-007: cap: rights catalog enforcement" "phase-2.5-reactivation-capability" "S" "phase:2,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R2.5-008" "R2.5-008: cap: end-to-end fixture + closure" "phase-2.5-reactivation-capability" "S" "phase:2,phase:reactivation,next-round,type:feature,size:S

# R3.5 (7 issues)
echo "R3.5 IPC reactivation (paideia-os)..."
create_issue "$PAIDEIA_OS_REPO" "R3.5-001" "R3.5-001: ipc: ring data layout" "phase-3.5-reactivation-ipc" "S" "phase:3,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R3.5-002" "R3.5-002: ipc: ipc_enqueue real body" "phase-3.5-reactivation-ipc" "S" "phase:3,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R3.5-003" "R3.5-003: ipc: ipc_dequeue real body" "phase-3.5-reactivation-ipc" "S" "phase:3,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R3.5-004" "R3.5-004: ipc: channel-create capability path" "phase-3.5-reactivation-ipc" "S" "phase:3,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R3.5-005" "R3.5-005: ipc: deadlock-freedom invariant assertion" "phase-3.5-reactivation-ipc" "S" "phase:3,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R3.5-006" "R3.5-006: ipc: NUMA-local channel allocation" "phase-3.5-reactivation-ipc" "S" "phase:3,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R3.5-007" "R3.5-007: ipc: end-to-end fixture + closure" "phase-3.5-reactivation-ipc" "S" "phase:3,phase:reactivation,next-round,type:feature,size:S

# R4.5 (8 issues)
echo "R4.5 Scheduler reactivation (paideia-os)..."
create_issue "$PAIDEIA_OS_REPO" "R4.5-001" "R4.5-001: sched: TCB struct layout" "phase-4.5-reactivation-scheduler" "S" "phase:4,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R4.5-002" "R4.5-002: sched: sched_pick_next" "phase-4.5-reactivation-scheduler" "S" "phase:4,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R4.5-003" "R4.5-003: sched: sched_switch register save/restore" "phase-4.5-reactivation-scheduler" "M" "phase:4,phase:reactivation,next-round,type:feature,size:M
create_issue "$PAIDEIA_OS_REPO" "R4.5-004" "R4.5-004: sched: TCB queue enqueue/dequeue" "phase-4.5-reactivation-scheduler" "S" "phase:4,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R4.5-005" "R4.5-005: sched: sched_yield" "phase-4.5-reactivation-scheduler" "S" "phase:4,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R4.5-006" "R4.5-006: sched: timer-IRQ preemption hook" "phase-4.5-reactivation-scheduler" "S" "phase:4,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R4.5-007" "R4.5-007: sched: per-TCB budget accounting" "phase-4.5-reactivation-scheduler" "XS" "phase:4,phase:reactivation,next-round,type:feature,size:xs"
create_issue "$PAIDEIA_OS_REPO" "R4.5-008" "R4.5-008: sched: end-to-end two-TCB switching fixture" "phase-4.5-reactivation-scheduler" "S" "phase:4,phase:reactivation,next-round,type:feature,size:S

# R5.5 (7 issues)
echo "R5.5 Memory management reactivation (paideia-os)..."
create_issue "$PAIDEIA_OS_REPO" "R5.5-001" "R5.5-001: mm: buddy allocator free-list heads" "phase-5.5-reactivation-memory" "S" "phase:5,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R5.5-002" "R5.5-002: mm: phys_alloc buddy walk" "phase-5.5-reactivation-memory" "S" "phase:5,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R5.5-003" "R5.5-003: mm: aspace_map page-table walk" "phase-5.5-reactivation-memory" "M" "phase:5,phase:reactivation,next-round,type:feature,size:M
create_issue "$PAIDEIA_OS_REPO" "R5.5-004" "R5.5-004: mm: aspace_unmap PTE clear" "phase-5.5-reactivation-memory" "S" "phase:5,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R5.5-005" "R5.5-005: mm: per-CPU magazine + buddy" "phase-5.5-reactivation-memory" "S" "phase:5,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R5.5-006" "R5.5-006: mm: aspace_create + aspace_activate" "phase-5.5-reactivation-memory" "S" "phase:5,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R5.5-007" "R5.5-007: mm: end-to-end alloc-map-touch fixture" "phase-5.5-reactivation-memory" "S" "phase:5,phase:reactivation,next-round,type:feature,size:S

# R6.5 (7 issues)
echo "R6.5 Interrupts reactivation (paideia-os)..."
create_issue "$PAIDEIA_OS_REPO" "R6.5-001" "R6.5-001: int: IDT real install" "phase-6.5-reactivation-interrupts" "S" "phase:6,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R6.5-002" "R6.5-002: int: ISR entry trampoline" "phase-6.5-reactivation-interrupts" "M" "phase:6,phase:reactivation,next-round,type:feature,size:M
create_issue "$PAIDEIA_OS_REPO" "R6.5-003" "R6.5-003: timer: LAPIC TSC-deadline timer init" "phase-6.5-reactivation-interrupts" "S" "phase:6,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R6.5-004" "R6.5-004: timer: timer ISR body" "phase-6.5-reactivation-interrupts" "S" "phase:6,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R6.5-005" "R6.5-005: int: TLB shootdown IPI delivery" "phase-6.5-reactivation-interrupts" "S" "phase:6,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R6.5-006" "R6.5-006: int: CPU exception handlers" "phase-6.5-reactivation-interrupts" "S" "phase:6,phase:reactivation,next-round,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "R6.5-007" "R6.5-007: int: end-to-end preemptive multitasking fixture" "phase-6.5-reactivation-interrupts" "S" "phase:6,phase:reactivation,next-round,type:feature,size:S

# D7 (6 issues)
echo "D7 Driver framework groundwork (paideia-os)..."
create_issue "$PAIDEIA_OS_REPO" "D7-001" "D7-001: design: driver-framework architecture" "phase-7-drivers-groundwork" "S" "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "D7-002" "D7-002: design: PCI enumeration design" "phase-7-drivers-groundwork" "S" "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "D7-003" "D7-003: drivers: PCI scaffolding" "phase-7-drivers-groundwork" "S" "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "D7-004" "D7-004: drivers: driver-registration capability" "phase-7-drivers-groundwork" "S" "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "D7-005" "D7-005: drivers: MMIO + port-IO ABI surface" "phase-7-drivers-groundwork" "S" "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:S
create_issue "$PAIDEIA_OS_REPO" "D7-006" "D7-006: drivers: first-driver placeholder" "phase-7-drivers-groundwork" "S" "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:S

echo ""
echo "========================================="
echo "Bootstrap Complete!"
echo "========================================="
echo "Issue map: $ISSUE_MAP"
echo "Total operations: $OP"
