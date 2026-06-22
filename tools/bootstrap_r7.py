#!/usr/bin/env python3
import subprocess
import json
import time
import sys

issues = [
    # R1.5 (6 issues)
    ("R1.5-001", "paideia-os/paideia-os", "R1.5-001: boot: kernel_main_64 real body", "phase-1.5-reactivation-boot", "S", "phase:1,phase:reactivation,next-round,type:feature,size:s"),
    ("R1.5-002", "paideia-os/paideia-os", "R1.5-002: boot: uart_init real body", "phase-1.5-reactivation-boot", "S", "phase:1,phase:reactivation,next-round,type:feature,size:s"),
    ("R1.5-003", "paideia-os/paideia-os", "R1.5-003: boot: uart_puts real body", "phase-1.5-reactivation-boot", "S", "phase:1,phase:reactivation,next-round,type:feature,size:s"),
    ("R1.5-004", "paideia-os/paideia-os", "R1.5-004: boot: _start orchestrates long-mode entry", "phase-1.5-reactivation-boot", "S", "phase:1,phase:reactivation,next-round,type:feature,size:s"),
    ("R1.5-005", "paideia-os/paideia-os", "R1.5-005: boot: banner data layout + content", "phase-1.5-reactivation-boot", "XS", "phase:1,phase:reactivation,next-round,type:feature,size:xs"),
    ("R1.5-006", "paideia-os/paideia-os", "R1.5-006: tests + closure: integration QEMU smoke", "phase-1.5-reactivation-boot", "XS", "phase:1,phase:reactivation,next-round,type:feature,size:xs"),

    # R2.5 (8 issues)
    ("R2.5-001", "paideia-os/paideia-os", "R2.5-001: cap: cap_mint real body", "phase-2.5-reactivation-capability", "S", "phase:2,phase:reactivation,next-round,type:feature,size:s"),
    ("R2.5-002", "paideia-os/paideia-os", "R2.5-002: cap: slab allocator real body", "phase-2.5-reactivation-capability", "S", "phase:2,phase:reactivation,next-round,type:feature,size:s"),
    ("R2.5-003", "paideia-os/paideia-os", "R2.5-003: cap: cap_verify real body", "phase-2.5-reactivation-capability", "S", "phase:2,phase:reactivation,next-round,type:feature,size:s"),
    ("R2.5-004", "paideia-os/paideia-os", "R2.5-004: cap: cap_revoke real body", "phase-2.5-reactivation-capability", "S", "phase:2,phase:reactivation,next-round,type:feature,size:s"),
    ("R2.5-005", "paideia-os/paideia-os", "R2.5-005: cap: LAM-tag handle encoding", "phase-2.5-reactivation-capability", "S", "phase:2,phase:reactivation,next-round,type:feature,size:s"),
    ("R2.5-006", "paideia-os/paideia-os", "R2.5-006: cap: cap_invoke dispatcher", "phase-2.5-reactivation-capability", "S", "phase:2,phase:reactivation,next-round,type:feature,size:s"),
    ("R2.5-007", "paideia-os/paideia-os", "R2.5-007: cap: rights catalog enforcement", "phase-2.5-reactivation-capability", "S", "phase:2,phase:reactivation,next-round,type:feature,size:s"),
    ("R2.5-008", "paideia-os/paideia-os", "R2.5-008: cap: end-to-end fixture + closure", "phase-2.5-reactivation-capability", "S", "phase:2,phase:reactivation,next-round,type:feature,size:s"),

    # R3.5 (7 issues)
    ("R3.5-001", "paideia-os/paideia-os", "R3.5-001: ipc: ring data layout", "phase-3.5-reactivation-ipc", "S", "phase:3,phase:reactivation,next-round,type:feature,size:s"),
    ("R3.5-002", "paideia-os/paideia-os", "R3.5-002: ipc: ipc_enqueue real body", "phase-3.5-reactivation-ipc", "S", "phase:3,phase:reactivation,next-round,type:feature,size:s"),
    ("R3.5-003", "paideia-os/paideia-os", "R3.5-003: ipc: ipc_dequeue real body", "phase-3.5-reactivation-ipc", "S", "phase:3,phase:reactivation,next-round,type:feature,size:s"),
    ("R3.5-004", "paideia-os/paideia-os", "R3.5-004: ipc: channel-create capability path", "phase-3.5-reactivation-ipc", "S", "phase:3,phase:reactivation,next-round,type:feature,size:s"),
    ("R3.5-005", "paideia-os/paideia-os", "R3.5-005: ipc: deadlock-freedom invariant assertion", "phase-3.5-reactivation-ipc", "S", "phase:3,phase:reactivation,next-round,type:feature,size:s"),
    ("R3.5-006", "paideia-os/paideia-os", "R3.5-006: ipc: NUMA-local channel allocation", "phase-3.5-reactivation-ipc", "S", "phase:3,phase:reactivation,next-round,type:feature,size:s"),
    ("R3.5-007", "paideia-os/paideia-os", "R3.5-007: ipc: end-to-end producer-consumer fixture", "phase-3.5-reactivation-ipc", "S", "phase:3,phase:reactivation,next-round,type:feature,size:s"),

    # R4.5 (8 issues)
    ("R4.5-001", "paideia-os/paideia-os", "R4.5-001: sched: TCB struct layout", "phase-4.5-reactivation-scheduler", "S", "phase:4,phase:reactivation,next-round,type:feature,size:s"),
    ("R4.5-002", "paideia-os/paideia-os", "R4.5-002: sched: sched_pick_next", "phase-4.5-reactivation-scheduler", "S", "phase:4,phase:reactivation,next-round,type:feature,size:s"),
    ("R4.5-003", "paideia-os/paideia-os", "R4.5-003: sched: sched_switch register save/restore", "phase-4.5-reactivation-scheduler", "M", "phase:4,phase:reactivation,next-round,type:feature,size:m"),
    ("R4.5-004", "paideia-os/paideia-os", "R4.5-004: sched: TCB queue enqueue/dequeue", "phase-4.5-reactivation-scheduler", "S", "phase:4,phase:reactivation,next-round,type:feature,size:s"),
    ("R4.5-005", "paideia-os/paideia-os", "R4.5-005: sched: sched_yield", "phase-4.5-reactivation-scheduler", "S", "phase:4,phase:reactivation,next-round,type:feature,size:s"),
    ("R4.5-006", "paideia-os/paideia-os", "R4.5-006: sched: timer-IRQ preemption hook", "phase-4.5-reactivation-scheduler", "S", "phase:4,phase:reactivation,next-round,type:feature,size:s"),
    ("R4.5-007", "paideia-os/paideia-os", "R4.5-007: sched: per-TCB budget accounting", "phase-4.5-reactivation-scheduler", "XS", "phase:4,phase:reactivation,next-round,type:feature,size:xs"),
    ("R4.5-008", "paideia-os/paideia-os", "R4.5-008: sched: end-to-end two-TCB switching fixture", "phase-4.5-reactivation-scheduler", "S", "phase:4,phase:reactivation,next-round,type:feature,size:s"),

    # R5.5 (7 issues)
    ("R5.5-001", "paideia-os/paideia-os", "R5.5-001: mm: buddy allocator free-list heads", "phase-5.5-reactivation-memory", "S", "phase:5,phase:reactivation,next-round,type:feature,size:s"),
    ("R5.5-002", "paideia-os/paideia-os", "R5.5-002: mm: phys_alloc buddy walk", "phase-5.5-reactivation-memory", "S", "phase:5,phase:reactivation,next-round,type:feature,size:s"),
    ("R5.5-003", "paideia-os/paideia-os", "R5.5-003: mm: aspace_map page-table walk", "phase-5.5-reactivation-memory", "M", "phase:5,phase:reactivation,next-round,type:feature,size:m"),
    ("R5.5-004", "paideia-os/paideia-os", "R5.5-004: mm: aspace_unmap PTE clear", "phase-5.5-reactivation-memory", "S", "phase:5,phase:reactivation,next-round,type:feature,size:s"),
    ("R5.5-005", "paideia-os/paideia-os", "R5.5-005: mm: per-CPU magazine + buddy", "phase-5.5-reactivation-memory", "S", "phase:5,phase:reactivation,next-round,type:feature,size:s"),
    ("R5.5-006", "paideia-os/paideia-os", "R5.5-006: mm: aspace_create + aspace_activate", "phase-5.5-reactivation-memory", "S", "phase:5,phase:reactivation,next-round,type:feature,size:s"),
    ("R5.5-007", "paideia-os/paideia-os", "R5.5-007: mm: end-to-end alloc-map-touch fixture", "phase-5.5-reactivation-memory", "S", "phase:5,phase:reactivation,next-round,type:feature,size:s"),

    # R6.5 (7 issues)
    ("R6.5-001", "paideia-os/paideia-os", "R6.5-001: int: IDT real install", "phase-6.5-reactivation-interrupts", "S", "phase:6,phase:reactivation,next-round,type:feature,size:s"),
    ("R6.5-002", "paideia-os/paideia-os", "R6.5-002: int: ISR entry trampoline", "phase-6.5-reactivation-interrupts", "M", "phase:6,phase:reactivation,next-round,type:feature,size:m"),
    ("R6.5-003", "paideia-os/paideia-os", "R6.5-003: timer: LAPIC TSC-deadline timer init", "phase-6.5-reactivation-interrupts", "S", "phase:6,phase:reactivation,next-round,type:feature,size:s"),
    ("R6.5-004", "paideia-os/paideia-os", "R6.5-004: timer: timer ISR body", "phase-6.5-reactivation-interrupts", "S", "phase:6,phase:reactivation,next-round,type:feature,size:s"),
    ("R6.5-005", "paideia-os/paideia-os", "R6.5-005: int: TLB shootdown IPI delivery", "phase-6.5-reactivation-interrupts", "S", "phase:6,phase:reactivation,next-round,type:feature,size:s"),
    ("R6.5-006", "paideia-os/paideia-os", "R6.5-006: int: CPU exception handlers", "phase-6.5-reactivation-interrupts", "S", "phase:6,phase:reactivation,next-round,type:feature,size:s"),
    ("R6.5-007", "paideia-os/paideia-os", "R6.5-007: int: end-to-end preemptive multitasking fixture", "phase-6.5-reactivation-interrupts", "S", "phase:6,phase:reactivation,next-round,type:feature,size:s"),

    # D7 (6 issues)
    ("D7-001", "paideia-os/paideia-os", "D7-001: design: driver-framework architecture", "phase-7-drivers-groundwork", "S", "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:s"),
    ("D7-002", "paideia-os/paideia-os", "D7-002: design: PCI enumeration design", "phase-7-drivers-groundwork", "S", "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:s"),
    ("D7-003", "paideia-os/paideia-os", "D7-003: drivers: PCI scaffolding", "phase-7-drivers-groundwork", "S", "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:s"),
    ("D7-004", "paideia-os/paideia-os", "D7-004: drivers: driver-registration capability", "phase-7-drivers-groundwork", "S", "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:s"),
    ("D7-005", "paideia-os/paideia-os", "D7-005: drivers: MMIO + port-IO ABI surface", "phase-7-drivers-groundwork", "S", "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:s"),
    ("D7-006", "paideia-os/paideia-os", "D7-006: drivers: first-driver placeholder", "phase-7-drivers-groundwork", "S", "phase:7,phase:drivers,next-round,area:drivers,type:feature,size:s"),
]

def create_issue(task_id, repo, title, milestone, size, labels):
    cmd = ["gh", "issue", "create", "--repo", repo, "--title", title,
           "--body", "Per osarch plan",
           "--label", labels,
           "--milestone", milestone]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        # Extract issue number from URL
        url = result.stdout.strip()
        issue_num = url.split("/")[-1]
        return issue_num
    else:
        print(f"ERROR: {task_id}: {result.stderr}", file=sys.stderr)
        return None

# Main loop
issue_map = [("TaskID", "Repo", "Issue", "Title", "Milestone", "Size")]
created = 0

for task_id, repo, title, milestone, size, labels in issues:
    issue_num = create_issue(task_id, repo, title, milestone, size, labels)
    if issue_num:
        print(f"  #{issue_num}: {task_id}")
        issue_map.append((task_id, repo, f"#{issue_num}", title, milestone, size))
        created += 1
        if created % 5 == 0:
            time.sleep(2)  # throttle
    else:
        print(f"  SKIP: {task_id} (already exists or error)")

# Write map
with open(".plans/next-round-issue-map.tsv", "w") as f:
    for row in issue_map:
        f.write("\t".join(row) + "\n")

print(f"\nCreated: {created}/49 paideia-os issues")
