#!/usr/bin/env bash
# Bootstrap GitHub issues for PaideiaOS next-round (R7)
# This script is idempotent: it checks for existing issues before creating them.
# Usage: bash tools/gh-bootstrap-next-round-issues.sh
# Output: creates/updates .plans/next-round-issue-map.tsv with issue numbers

set -euo pipefail

PAIDEIA_OS_REPO="paideia-os/paideia-os"
PAIDEIA_AS_REPO="paideia-os/paideia-as"
ISSUE_MAP=".plans/next-round-issue-map.tsv"
OPERATION_COUNT=0

# Helper: check if issue exists, return issue number or empty
issue_exists() {
    local repo="$1"
    local title="$2"
    # Use grep to find if issue exists; if not found returns empty
    gh issue list --repo "$repo" --search "in:title \"$title\"" --limit 1 2>/dev/null | grep -oP '(?<=#)\d+' || echo ""
}

# Helper: throttle after every 30 operations
throttle() {
    OPERATION_COUNT=$((OPERATION_COUNT + 1))
    if [ $((OPERATION_COUNT % 30)) -eq 0 ]; then
        echo "Throttling: sleeping 30s after 30 operations..."
        sleep 30
    fi
}

# Initialize issue map with header
cat > "$ISSUE_MAP" << 'EOFMAP'
TaskID	Repo	Issue	Title	Milestone	Size
EOFMAP

echo "========================================="
echo "PaideiaOS Next-Round Issue Bootstrap (R7)"
echo "========================================="
echo ""

# ============================================================================
# PAIDEIA-AS PHASE 7 (9 issues)
# ============================================================================

echo "Creating paideia-as Phase 7 issues (PA7)..."
echo ""

declare -a pa7_tasks=(
    "PA7-001:parser + elaborator + emit: multi-statement function body (statement sequence):S"
    "PA7-002:elaborator + emit: inter-fn call dispatch with relocation:S"
    "PA7-003:elaborator + emit: if EXPR { … } else { … } expression lowering:S"
    "PA7-004:elaborator + emit: while COND { … } loop lowering:S"
    "PA7-005:parser + elaborator: let mut at module level + writes to mutable globals:S"
    "PA7-006:elaborator + emit: 3+ argument calls + register-spill ABI:S"
    "PA7-007:elaborator: match EXPR { … } lowering for enum-like u32 dispatch:S"
    "PA7-008:elaborator + emit: loop { … } (infinite) + break value for halt-loop pattern:XS"
    "PA7-009:emit + tests: end-to-end boot to kernel_main smoke fixture:S"
)

for task_spec in "${pa7_tasks[@]}"; do
    IFS=: read task_id task_title task_size <<< "$task_spec"
    title="$task_id: $task_title"

    # Check if issue exists
    existing=$(issue_exists "$PAIDEIA_AS_REPO" "$title")
    if [ -n "$existing" ]; then
        echo "  [SKIP] Issue #$existing already exists: $title"
        echo -e "$task_id\t$PAIDEIA_AS_REPO\t#$existing\t$title\tphase-7-fn-body-minimum-subset\t$task_size" >> "$ISSUE_MAP"
        continue
    fi

    # Create issue
    body="## Summary
$task_title

## Acceptance criteria
- [ ] Implementation complete
- [ ] Tests pass
- [ ] Code review approved

## Files
TBD

## Dependencies
Per osarch plan

## Estimated size
$task_size

## Phase
Phase 7 — Substrate for PaideiaOS kernel reactivation

## Milestone
phase-7-fn-body-minimum-subset

## Repo
paideia-os/paideia-as

## Cross-repo unblock for
Per osarch plan

## Surfaced by
n/a"

    issue_num=$(gh issue create --repo "$PAIDEIA_AS_REPO" \
        --title "$title" \
        --body "$body" \
        --label "phase:7,area:emit-activation,next-round,cross-repo:paideia-as-fix,type:feature,size:${task_size,,}" \
        --milestone "phase-7-fn-body-minimum-subset" \
        2>/dev/null | grep -oP '(?<=#)\d+')

    echo "  [NEW] Issue #$issue_num: $title"
    echo -e "$task_id\t$PAIDEIA_AS_REPO\t#$issue_num\t$title\tphase-7-fn-body-minimum-subset\t$task_size" >> "$ISSUE_MAP"
    throttle
done

echo ""

# ============================================================================
# PAIDEIA-OS REACTIVATION MILESTONES (49 issues)
# ============================================================================

# R1.5: Boot reactivation (6 issues)
echo "Creating R1.5 Boot reactivation issues..."
declare -a r15_tasks=(
    "R1.5-001:boot: kernel_main_64 real body (uart_init → puts → halt):S"
    "R1.5-002:boot: uart_init real body (7-step COM1 init sequence):S"
    "R1.5-003:boot: uart_puts(ptr, len) real body (loop emitting per-byte writes):S"
    "R1.5-004:boot: _start orchestrates long-mode entry → calls kernel_main_64:S"
    "R1.5-005:boot: banner data layout + content:XS"
    "R1.5-006:tests + closure: integration QEMU smoke + R1.5 closure marker:XS"
)

for task_spec in "${r15_tasks[@]}"; do
    IFS=: read task_id task_title task_size <<< "$task_spec"
    title="$task_id: $task_title"

    existing=$(issue_exists "$PAIDEIA_OS_REPO" "$title")
    if [ -n "$existing" ]; then
        echo "  [SKIP] Issue #$existing: $title"
        echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$existing\t$title\tphase-1.5-reactivation-boot\t$task_size" >> "$ISSUE_MAP"
        continue
    fi

    body="## Summary
$task_title

## Acceptance criteria
- [ ] Implementation complete
- [ ] Tests pass
- [ ] QEMU smoke passes

## Files
src/kernel/boot/

## Dependencies
PA7 issues

## Estimated size
$task_size

## Phase
Phase 1.5 — Reactivation: Real boot path

## Milestone
phase-1.5-reactivation-boot

## Repo
paideia-os/paideia-os

## Cross-repo unblock for
Per osarch plan

## Surfaced by
n/a"

    issue_num=$(gh issue create --repo "$PAIDEIA_OS_REPO" \
        --title "$title" \
        --body "$body" \
        --label "phase:1,phase:reactivation,next-round,type:feature,size:${task_size,,}" \
        --milestone "phase-1.5-reactivation-boot" \
        2>/dev/null | grep -oP '(?<=#)\d+')

    echo "  [NEW] Issue #$issue_num: $title"
    echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$issue_num\t$title\tphase-1.5-reactivation-boot\t$task_size" >> "$ISSUE_MAP"
    throttle
done

echo ""

# R2.5: Capability reactivation (8 issues)
echo "Creating R2.5 Capability reactivation issues..."
declare -a r25_tasks=(
    "R2.5-001:cap: cap_mint(kind, target_ptr, rights) real body — slab alloc + descriptor init:S"
    "R2.5-002:cap: slab allocator real slab_alloc() / slab_free(idx):S"
    "R2.5-003:cap: cap_verify(handle) -> kind | INVALID real body:S"
    "R2.5-004:cap: cap_revoke(handle) increments generation + adds slot to free-list:S"
    "R2.5-005:cap: LAM-tag handle encoding cap_handle_encode(gen, slot) -> u64:S"
    "R2.5-006:cap: cap_invoke(handle, op, arg) -> result dispatcher:S"
    "R2.5-007:cap: rights catalog enforcement at mint + invoke:S"
    "R2.5-008:cap: end-to-end fixture + R2.5 closure marker:S"
)

for task_spec in "${r25_tasks[@]}"; do
    IFS=: read task_id task_title task_size <<< "$task_spec"
    title="$task_id: $task_title"

    existing=$(issue_exists "$PAIDEIA_OS_REPO" "$title")
    if [ -n "$existing" ]; then
        echo "  [SKIP] Issue #$existing: $title"
        echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$existing\t$title\tphase-2.5-reactivation-capability\t$task_size" >> "$ISSUE_MAP"
        continue
    fi

    body="## Summary
$task_title

## Acceptance criteria
- [ ] Implementation complete
- [ ] Tests pass
- [ ] QEMU smoke passes

## Files
src/kernel/core/cap/

## Dependencies
PA7 issues; R1.5 for boot

## Estimated size
$task_size

## Phase
Phase 2.5 — Reactivation: Real capability system

## Milestone
phase-2.5-reactivation-capability

## Repo
paideia-os/paideia-os

## Cross-repo unblock for
Per osarch plan

## Surfaced by
n/a"

    issue_num=$(gh issue create --repo "$PAIDEIA_OS_REPO" \
        --title "$title" \
        --body "$body" \
        --label "phase:2,phase:reactivation,next-round,type:feature,size:${task_size,,}" \
        --milestone "phase-2.5-reactivation-capability" \
        2>/dev/null | grep -oP '(?<=#)\d+')

    echo "  [NEW] Issue #$issue_num: $title"
    echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$issue_num\t$title\tphase-2.5-reactivation-capability\t$task_size" >> "$ISSUE_MAP"
    throttle
done

echo ""

# R3.5: IPC reactivation (7 issues)
echo "Creating R3.5 IPC reactivation issues..."
declare -a r35_tasks=(
    "R3.5-001:ipc: ring data layout (head, tail, slots[N]) with mut cursors:S"
    "R3.5-002:ipc: ipc_enqueue(ch, ptr, len) -> u32 real body:S"
    "R3.5-003:ipc: ipc_dequeue(ch, ptr, len_out) -> u32 real body:S"
    "R3.5-004:ipc: channel-create capability path (ipc_channel_create() -> cap_handle):S"
    "R3.5-005:ipc: deadlock-freedom invariant assertion (single producer + single consumer):S"
    "R3.5-006:ipc: NUMA-local channel allocation (per Pillar 2):S"
    "R3.5-007:ipc: end-to-end producer-consumer fixture + R3.5 closure:S"
)

for task_spec in "${r35_tasks[@]}"; do
    IFS=: read task_id task_title task_size <<< "$task_spec"
    title="$task_id: $task_title"

    existing=$(issue_exists "$PAIDEIA_OS_REPO" "$title")
    if [ -n "$existing" ]; then
        echo "  [SKIP] Issue #$existing: $title"
        echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$existing\t$title\tphase-3.5-reactivation-ipc\t$task_size" >> "$ISSUE_MAP"
        continue
    fi

    body="## Summary
$task_title

## Acceptance criteria
- [ ] Implementation complete
- [ ] Tests pass
- [ ] QEMU smoke passes

## Files
src/kernel/core/ipc/

## Dependencies
PA7 issues; R2.5 for capabilities

## Estimated size
$task_size

## Phase
Phase 3.5 — Reactivation: Real IPC

## Milestone
phase-3.5-reactivation-ipc

## Repo
paideia-os/paideia-os

## Cross-repo unblock for
Per osarch plan

## Surfaced by
n/a"

    issue_num=$(gh issue create --repo "$PAIDEIA_OS_REPO" \
        --title "$title" \
        --body "$body" \
        --label "phase:3,phase:reactivation,next-round,type:feature,size:${task_size,,}" \
        --milestone "phase-3.5-reactivation-ipc" \
        2>/dev/null | grep -oP '(?<=#)\d+')

    echo "  [NEW] Issue #$issue_num: $title"
    echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$issue_num\t$title\tphase-3.5-reactivation-ipc\t$task_size" >> "$ISSUE_MAP"
    throttle
done

echo ""

# R4.5: Scheduler reactivation (8 issues)
echo "Creating R4.5 Scheduler reactivation issues..."
declare -a r45_tasks=(
    "R4.5-001:sched: TCB struct full layout + per-CPU runqueue array:S"
    "R4.5-002:sched: sched_pick_next() walks priority bitmap, returns TCB:S"
    "R4.5-003:sched: sched_switch(from_tcb, to_tcb) real register save/restore:M"
    "R4.5-004:sched: TCB queue enqueue/dequeue (runqueue_enqueue, runqueue_dequeue_head):S"
    "R4.5-005:sched: sched_yield() — voluntary CPU release:S"
    "R4.5-006:sched: timer-IRQ preemption hook (placeholder body until R6.5):S"
    "R4.5-007:sched: per-TCB budget accounting:XS"
    "R4.5-008:sched: end-to-end two-TCB switching fixture + R4.5 closure:S"
)

for task_spec in "${r45_tasks[@]}"; do
    IFS=: read task_id task_title task_size <<< "$task_spec"
    title="$task_id: $task_title"

    existing=$(issue_exists "$PAIDEIA_OS_REPO" "$title")
    if [ -n "$existing" ]; then
        echo "  [SKIP] Issue #$existing: $title"
        echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$existing\t$title\tphase-4.5-reactivation-scheduler\t$task_size" >> "$ISSUE_MAP"
        continue
    fi

    body="## Summary
$task_title

## Acceptance criteria
- [ ] Implementation complete
- [ ] Tests pass
- [ ] QEMU smoke passes

## Files
src/kernel/core/sched/

## Dependencies
PA7 issues; R2.5 for capabilities

## Estimated size
$task_size

## Phase
Phase 4.5 — Reactivation: Real scheduler

## Milestone
phase-4.5-reactivation-scheduler

## Repo
paideia-os/paideia-os

## Cross-repo unblock for
Per osarch plan

## Surfaced by
n/a"

    issue_num=$(gh issue create --repo "$PAIDEIA_OS_REPO" \
        --title "$title" \
        --body "$body" \
        --label "phase:4,phase:reactivation,next-round,type:feature,size:${task_size,,}" \
        --milestone "phase-4.5-reactivation-scheduler" \
        2>/dev/null | grep -oP '(?<=#)\d+')

    echo "  [NEW] Issue #$issue_num: $title"
    echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$issue_num\t$title\tphase-4.5-reactivation-scheduler\t$task_size" >> "$ISSUE_MAP"
    throttle
done

echo ""

# R5.5: Memory management reactivation (7 issues)
echo "Creating R5.5 Memory management reactivation issues..."
declare -a r55_tasks=(
    "R5.5-001:mm: buddy allocator free-list heads + order representation:S"
    "R5.5-002:mm: phys_alloc(order) -> *Page buddy walk:S"
    "R5.5-003:mm: aspace_map(as, vaddr, paddr, flags) page-table walk + entry write:M"
    "R5.5-004:mm: aspace_unmap(as, vaddr) PTE clear + TLB shootdown placeholder:S"
    "R5.5-005:mm: per-CPU magazine + buddy interaction (Pillar 2 NUMA-local fast path):S"
    "R5.5-006:mm: aspace_create + aspace_activate (PCID-tagged):S"
    "R5.5-007:mm: end-to-end alloc-map-touch fixture + R5.5 closure:S"
)

for task_spec in "${r55_tasks[@]}"; do
    IFS=: read task_id task_title task_size <<< "$task_spec"
    title="$task_id: $task_title"

    existing=$(issue_exists "$PAIDEIA_OS_REPO" "$title")
    if [ -n "$existing" ]; then
        echo "  [SKIP] Issue #$existing: $title"
        echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$existing\t$title\tphase-5.5-reactivation-memory\t$task_size" >> "$ISSUE_MAP"
        continue
    fi

    body="## Summary
$task_title

## Acceptance criteria
- [ ] Implementation complete
- [ ] Tests pass
- [ ] QEMU smoke passes

## Files
src/kernel/core/mm/

## Dependencies
PA7 issues; R1.5 for boot

## Estimated size
$task_size

## Phase
Phase 5.5 — Reactivation: Real memory management

## Milestone
phase-5.5-reactivation-memory

## Repo
paideia-os/paideia-os

## Cross-repo unblock for
Per osarch plan

## Surfaced by
n/a"

    issue_num=$(gh issue create --repo "$PAIDEIA_OS_REPO" \
        --title "$title" \
        --body "$body" \
        --label "phase:5,phase:reactivation,next-round,type:feature,size:${task_size,,}" \
        --milestone "phase-5.5-reactivation-memory" \
        2>/dev/null | grep -oP '(?<=#)\d+')

    echo "  [NEW] Issue #$issue_num: $title"
    echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$issue_num\t$title\tphase-5.5-reactivation-memory\t$task_size" >> "$ISSUE_MAP"
    throttle
done

echo ""

# R6.5: Interrupts reactivation (7 issues)
echo "Creating R6.5 Interrupts reactivation issues..."
declare -a r65_tasks=(
    "R6.5-001:int: IDT real install with 256 vector entries:S"
    "R6.5-002:int: ISR entry trampoline (save regs, call C-style handler, iretq):M"
    "R6.5-003:timer: LAPIC TSC-deadline timer init + periodic re-arm:S"
    "R6.5-004:timer: timer ISR body — calls sched_tick + re-arms:S"
    "R6.5-005:int: TLB shootdown IPI delivery (consumes R5.5-004 mailbox):S"
    "R6.5-006:int: CPU exception handlers (vectors 0,3,6,8,13,14) write trace + halt:S"
    "R6.5-007:int: end-to-end preemptive multitasking fixture + R6.5 closure:S"
)

for task_spec in "${r65_tasks[@]}"; do
    IFS=: read task_id task_title task_size <<< "$task_spec"
    title="$task_id: $task_title"

    existing=$(issue_exists "$PAIDEIA_OS_REPO" "$title")
    if [ -n "$existing" ]; then
        echo "  [SKIP] Issue #$existing: $title"
        echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$existing\t$title\tphase-6.5-reactivation-interrupts\t$task_size" >> "$ISSUE_MAP"
        continue
    fi

    body="## Summary
$task_title

## Acceptance criteria
- [ ] Implementation complete
- [ ] Tests pass
- [ ] QEMU smoke passes

## Files
src/kernel/core/int/, src/kernel/core/timer/

## Dependencies
PA7 issues; R4.5 for scheduler

## Estimated size
$task_size

## Phase
Phase 6.5 — Reactivation: Real interrupts and timer

## Milestone
phase-6.5-reactivation-interrupts

## Repo
paideia-os/paideia-os

## Cross-repo unblock for
Per osarch plan

## Surfaced by
n/a"

    issue_num=$(gh issue create --repo "$PAIDEIA_OS_REPO" \
        --title "$title" \
        --body "$body" \
        --label "phase:6,phase:reactivation,next-round,type:feature,size:${task_size,,}" \
        --milestone "phase-6.5-reactivation-interrupts" \
        2>/dev/null | grep -oP '(?<>#)\d+')

    echo "  [NEW] Issue #$issue_num: $title"
    echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$issue_num\t$title\tphase-6.5-reactivation-interrupts\t$task_size" >> "$ISSUE_MAP"
    throttle
done

echo ""

# D7: Driver framework groundwork (6 issues)
echo "Creating D7 Driver framework groundwork issues..."
declare -a d7_tasks=(
    "D7-001:design: driver-framework architecture document:S"
    "D7-002:design: PCI enumeration design (config-space access via port 0xCF8/0xCFC + MMCONFIG):S"
    "D7-003:drivers: PCI scaffolding — config-space accessor fns (no enumeration loop yet):S"
    "D7-004:drivers: driver-registration capability + manifest format:S"
    "D7-005:drivers: MMIO + port-IO ABI surface (mappable region cap, no driver bodies yet):S"
    "D7-006:drivers: first-driver placeholder — virtio-net header-walk only:S"
)

for task_spec in "${d7_tasks[@]}"; do
    IFS=: read task_id task_title task_size <<< "$task_spec"
    title="$task_id: $task_title"

    existing=$(issue_exists "$PAIDEIA_OS_REPO" "$title")
    if [ -n "$existing" ]; then
        echo "  [SKIP] Issue #$existing: $title"
        echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$existing\t$title\tphase-7-drivers-groundwork\t$task_size" >> "$ISSUE_MAP"
        continue
    fi

    body="## Summary
$task_title

## Acceptance criteria
- [ ] Implementation complete
- [ ] Tests pass
- [ ] QEMU smoke passes

## Files
design/drivers/, src/drivers/

## Dependencies
R2.5 for capabilities; R5.5 for memory management

## Estimated size
$task_size

## Phase
Phase 7 — Driver framework groundwork

## Milestone
phase-7-drivers-groundwork

## Repo
paideia-os/paideia-os

## Cross-repo unblock for
none

## Surfaced by
n/a"

    issue_num=$(gh issue create --repo "$PAIDEIA_OS_REPO" \
        --title "$title" \
        --body "$body" \
        --label "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:${task_size,,}" \
        --milestone "phase-7-drivers-groundwork" \
        2>/dev/null | grep -oP '(?<=#)\d+')

    echo "  [NEW] Issue #$issue_num: $title"
    echo -e "$task_id\t$PAIDEIA_OS_REPO\t#$issue_num\t$title\tphase-7-drivers-groundwork\t$task_size" >> "$ISSUE_MAP"
    throttle
done

echo ""
echo "========================================="
echo "Bootstrap complete!"
echo "Issue map written to: $ISSUE_MAP"
echo "========================================="
echo ""

# Verification
echo "Verification:"
pa7_count=$(gh issue list --repo "$PAIDEIA_AS_REPO" --label "next-round" --state open --limit 50 2>/dev/null | grep -c '^' || echo "0")
paideia_os_count=$(gh issue list --repo "$PAIDEIA_OS_REPO" --label "next-round" --state open --limit 100 2>/dev/null | grep -c '^' || echo "0")

echo "  paideia-as (PA7): $pa7_count issues (expected 9)"
echo "  paideia-os (R/D): $paideia_os_count issues (expected 49)"
echo "  Total: $((pa7_count + paideia_os_count)) issues (expected 58)"
echo ""

if [ "$pa7_count" -eq 9 ] && [ "$paideia_os_count" -eq 49 ]; then
    echo "SUCCESS: All 58 issues created!"
    exit 0
else
    echo "WARNING: Expected 58 issues total, got $((pa7_count + paideia_os_count))"
    exit 1
fi
