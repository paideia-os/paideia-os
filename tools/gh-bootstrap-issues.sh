#!/usr/bin/env bash
# Bootstrap GitHub issues for PaideiaOS
# Usage: bash tools/gh-bootstrap-issues.sh
# Rate-limit aware: will sleep 60s if throttled

set -euo pipefail

REPO="paideia-os/paideia-os"
ISSUE_MAP=".plans/issue-map.tsv"

# Initialize issue map with header
cat > "$ISSUE_MAP" << 'EOFMAP'
PR	Issue	Title	Phase	Size
EOFMAP

echo 'Creating Phase-0 closure markers...'

BODY="## Summary\ninfra: paideia-as as submodule at tools/paideia-as/\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 0 — Bootstrap (build chain + halt-kernel smoke).\n\n## Milestone\nphase-0-bootstrap"
gh issue create --repo "$REPO" \
    --title "infra: paideia-as as submodule at tools/paideia-as/" \
    --body "$BODY" \
    --label "phase:0,area:toolchain,type:infra,size:xs" \
    --milestone "phase-0-bootstrap" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
echo -e "{task_id}\t$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')\tinfra: paideia-as as submodule at tools/paideia-as/\t0\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ninfra: Nix flake + dev shell\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 0 — Bootstrap (build chain + halt-kernel smoke).\n\n## Milestone\nphase-0-bootstrap"
gh issue create --repo "$REPO" \
    --title "infra: Nix flake + dev shell" \
    --body "$BODY" \
    --label "phase:0,area:infra,type:infra,size:xs" \
    --milestone "phase-0-bootstrap" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
echo -e "{task_id}\t$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')\tinfra: Nix flake + dev shell\t0\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nbuild: tools/build.sh orchestrator (find→compile→link)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 0 — Bootstrap (build chain + halt-kernel smoke).\n\n## Milestone\nphase-0-bootstrap"
gh issue create --repo "$REPO" \
    --title "build: tools/build.sh orchestrator (find→compile→link)" \
    --body "$BODY" \
    --label "phase:0,area:infra,type:infra,size:xs" \
    --milestone "phase-0-bootstrap" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
echo -e "{task_id}\t$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')\tbuild: tools/build.sh orchestrator (find→compile→link)\t0\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nbuild: linker script src/kernel/link.ld (ELF64 @ 0x100000)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 0 — Bootstrap (build chain + halt-kernel smoke).\n\n## Milestone\nphase-0-bootstrap"
gh issue create --repo "$REPO" \
    --title "build: linker script src/kernel/link.ld (ELF64 @ 0x100000)" \
    --body "$BODY" \
    --label "phase:0,area:infra,type:infra,size:xs" \
    --milestone "phase-0-bootstrap" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
echo -e "{task_id}\t$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')\tbuild: linker script src/kernel/link.ld (ELF64 @ 0x100000)\t0\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nkernel: entry _start (cli; hlt; jmp $-1) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 0 — Bootstrap (build chain + halt-kernel smoke).\n\n## Milestone\nphase-0-bootstrap"
gh issue create --repo "$REPO" \
    --title "kernel: entry _start (cli; hlt; jmp $-1) [unsafe]" \
    --body "$BODY" \
    --label "phase:0,area:boot,type:feature,size:xs" \
    --milestone "phase-0-bootstrap" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
echo -e "{task_id}\t$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')\tkernel: entry _start (cli; hlt; jmp $-1) [unsafe]\t0\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ninfra: QEMU smoke harness tools/run-qemu.sh\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 0 — Bootstrap (build chain + halt-kernel smoke).\n\n## Milestone\nphase-0-bootstrap"
gh issue create --repo "$REPO" \
    --title "infra: QEMU smoke harness tools/run-qemu.sh" \
    --body "$BODY" \
    --label "phase:0,area:infra,type:infra,size:xs" \
    --milestone "phase-0-bootstrap" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
echo -e "{task_id}\t$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')\tinfra: QEMU smoke harness tools/run-qemu.sh\t0\tXS" >> "$ISSUE_MAP"
sleep 1

echo 'Closing Phase-0 issues...'

for line in $(tail -n +2 "$ISSUE_MAP" | grep "^P0-"); do
    issue_num=$(echo "$line" | cut -f2)
    if [ "$issue_num" != "?" ] && [ -n "$issue_num" ]; then
        gh issue close "$issue_num" --repo "$REPO" --comment "Closed by Phase-0 bootstrap closure." 2>/dev/null || true
        sleep 1
    fi
done

echo 'Creating Phase-1 issues (14 tasks)...'

BODY="## Summary\nboot: GDT32 + GDT64 descriptors + LGDT helper [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "boot: GDT32 + GDT64 descriptors + LGDT helper [unsafe]" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tboot: GDT32 + GDT64 descriptors + LGDT helper [unsafe]\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nboot: identity-mapping page tables in .bss (4 GiB via 1 GiB pages) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "boot: identity-mapping page tables in .bss (4 GiB via 1 GiB pages) [unsafe]" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:s" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tboot: identity-mapping page tables in .bss (4 GiB via 1 GiB pages) [unsafe]\t1\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nboot: long-mode entry sequence (CR4.PAE → EFER.LME → CR0.PG → ljmp) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "boot: long-mode entry sequence (CR4.PAE → EFER.LME → CR0.PG → ljmp) [unsafe]" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:s" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tboot: long-mode entry sequence (CR4.PAE → EFER.LME → CR0.PG → ljmp) [unsafe]\t1\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: linker-script higher-half preview (placeholder symbols only)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "mm: linker-script higher-half preview (placeholder symbols only)" \
    --body "$BODY" \
    --label "phase:1,area:mm,type:feature,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: linker-script higher-half preview (placeholder symbols only)\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: .bss zeroing on entry (rep stosq) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "mm: .bss zeroing on entry (rep stosq) [unsafe]" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: .bss zeroing on entry (rep stosq) [unsafe]\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nuart: COM1 16550 init (divisor latch + 8N1 + FIFO enable) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "uart: COM1 16550 init (divisor latch + 8N1 + FIFO enable) [unsafe]" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tuart: COM1 16550 init (divisor latch + 8N1 + FIFO enable) [unsafe]\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nuart: uart_putc(c: u8) polled TX [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "uart: uart_putc(c: u8) polled TX [unsafe]" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tuart: uart_putc(c: u8) polled TX [unsafe]\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nuart: uart_puts(s: *u8, len: u64) loop\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "uart: uart_puts(s: *u8, len: u64) loop" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tuart: uart_puts(s: *u8, len: u64) loop\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nbanner: static banner string + length\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "banner: static banner string + length" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tbanner: static banner string + length\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nbanner: kernel_main_64 invokes uart_init + uart_puts + halt loop\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "banner: kernel_main_64 invokes uart_init + uart_puts + halt loop" \
    --body "$BODY" \
    --label "phase:1,area:boot,type:feature,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tbanner: kernel_main_64 invokes uart_init + uart_puts + halt loop\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: deterministic-output regression script\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "smoke: deterministic-output regression script" \
    --body "$BODY" \
    --label "phase:1,area:infra,type:test,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: deterministic-output regression script\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: P1 closure note + audit-catalog roll-up\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "docs: P1 closure note + audit-catalog roll-up" \
    --body "$BODY" \
    --label "phase:1,area:infra,type:doc,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: P1 closure note + audit-catalog roll-up\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: open questions for P2 entry resolved\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "docs: open questions for P2 entry resolved" \
    --body "$BODY" \
    --label "phase:1,area:infra,type:doc,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: open questions for P2 entry resolved\t1\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nci: P1 smoke wired into GitHub Actions\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 1 — Long-mode + COM1 UART + kernel banner.\n\n## Milestone\nphase-1-long-mode-uart-banner"
gh issue create --repo "$REPO" \
    --title "ci: P1 smoke wired into GitHub Actions" \
    --body "$BODY" \
    --label "phase:1,area:infra,type:infra,size:xs" \
    --milestone "phase-1-long-mode-uart-banner" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tci: P1 smoke wired into GitHub Actions\t1\tXS" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-2 issues (24 tasks)...'

BODY="## Summary\ncap: phase1_capability descriptor struct (24 bytes, fixed layout) [gate paideia-as#struct-walker]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: phase1_capability descriptor struct (24 bytes, fixed layout) [gate paideia-as#struct-walker]" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: phase1_capability descriptor struct (24 bytes, fixed layout) [gate paideia-as#struct-walker]\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: 256-entry static cap table in .bss (P2 placeholder size) [NUMA]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: 256-entry static cap table in .bss (P2 placeholder size) [NUMA]" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: 256-entry static cap table in .bss (P2 placeholder size) [NUMA]\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: handle encoding (LAM-tagged pointer or software fallback)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: handle encoding (LAM-tagged pointer or software fallback)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:s" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: handle encoding (LAM-tagged pointer or software fallback)\t2\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: kind enum (16 base kinds per linearity-and-tags §3.1)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: kind enum (16 base kinds per linearity-and-tags §3.1)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: kind enum (16 base kinds per linearity-and-tags §3.1)\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: slab allocator over the static table (free-list head)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: slab allocator over the static table (free-list head)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:s" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: slab allocator over the static table (free-list head)\t2\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: generation-counter rollover policy\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: generation-counter rollover policy" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: generation-counter rollover policy\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: cap_verify(handle: u64) -> bool\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: cap_verify(handle: u64) -> bool" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: cap_verify(handle: u64) -> bool\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: cap_has_rights(handle, required: u32) -> bool\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: cap_has_rights(handle, required: u32) -> bool" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: cap_has_rights(handle, required: u32) -> bool\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: cap_mint(kind, target_ptr, rights) -> handle [cap-grant]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: cap_mint(kind, target_ptr, rights) -> handle [cap-grant]" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:s" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: cap_mint(kind, target_ptr, rights) -> handle [cap-grant]\t2\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: cap_revoke(handle) -> i32\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: cap_revoke(handle) -> i32" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: cap_revoke(handle) -> i32\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: cap_destroy(handle) -> i32\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: cap_destroy(handle) -> i32" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: cap_destroy(handle) -> i32\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: cap_invoke(handle, op, arg) -> u64 (dispatch table)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: cap_invoke(handle, op, arg) -> u64 (dispatch table)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:s" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: cap_invoke(handle, op, arg) -> u64 (dispatch table)\t2\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: LAM probe + activation (CR3.LAM57 / CR3.LAM48 set bits)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: LAM probe + activation (CR3.LAM57 / CR3.LAM48 set bits)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:s" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: LAM probe + activation (CR3.LAM57 / CR3.LAM48 set bits)\t2\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: kind-rights validation table (per rights-catalog §1–§16) [cap-grant]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: kind-rights validation table (per rights-catalog §1–§16) [cap-grant]" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:s" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: kind-rights validation table (per rights-catalog §1–§16) [cap-grant]\t2\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: cap_smoke.pdx — create/invoke/revoke/re-invoke\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "smoke: cap_smoke.pdx — create/invoke/revoke/re-invoke" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:test,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: cap_smoke.pdx — create/invoke/revoke/re-invoke\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: revocation-storm test (1024 revoke cycles)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "smoke: revocation-storm test (1024 revoke cycles)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:test,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: revocation-storm test (1024 revoke cycles)\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: forged-handle rejection corpus (50 hostile handles)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "smoke: forged-handle rejection corpus (50 hostile handles)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:test,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: forged-handle rejection corpus (50 hostile handles)\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: rights-mask boundary corpus\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "smoke: rights-mask boundary corpus" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:test,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: rights-mask boundary corpus\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: in-kernel cap_dump(handle) for debugging [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: in-kernel cap_dump(handle) for debugging [unsafe]" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: in-kernel cap_dump(handle) for debugging [unsafe]\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: design/capabilities/phase1-api.md updated with P2 closure note\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "docs: design/capabilities/phase1-api.md updated with P2 closure note" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:doc,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: design/capabilities/phase1-api.md updated with P2 closure note\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: audit-catalog roll-up for P2\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "docs: audit-catalog roll-up for P2" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:doc,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: audit-catalog roll-up for P2\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: dispatch-table extension hook (for P3/P4/P5 ops)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "cap: dispatch-table extension hook (for P3/P4/P5 ops)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:feature,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: dispatch-table extension hook (for P3/P4/P5 ops)\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nperf: cap fast-path microbenchmark (verify+rights+invoke)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "perf: cap fast-path microbenchmark (verify+rights+invoke)" \
    --body "$BODY" \
    --label "phase:2,area:cap,type:perf,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tperf: cap fast-path microbenchmark (verify+rights+invoke)\t2\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nci: P2 smoke + cap-rights-boundary + revoke-storm wired\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 2 — Capability system (Phase-1 API).\n\n## Milestone\nphase-2-capability-system"
gh issue create --repo "$REPO" \
    --title "ci: P2 smoke + cap-rights-boundary + revoke-storm wired" \
    --body "$BODY" \
    --label "phase:2,area:infra,type:infra,size:xs" \
    --milestone "phase-2-capability-system" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tci: P2 smoke + cap-rights-boundary + revoke-storm wired\t2\tXS" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-3 issues (22 tasks)...'

BODY="## Summary\nipc: phase1_channel struct (ring + indices + caps anchor)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "ipc: phase1_channel struct (ring + indices + caps anchor)" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:feature,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipc: phase1_channel struct (ring + indices + caps anchor)\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nipc: channel allocator (fixed slab of 64 channels)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "ipc: channel allocator (fixed slab of 64 channels)" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:feature,size:s" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipc: channel allocator (fixed slab of 64 channels)\t3\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nipc: per-channel slot storage allocation [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "ipc: per-channel slot storage allocation [unsafe]" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:feature,size:s" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipc: per-channel slot storage allocation [unsafe]\t3\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nipc: ipc_enqueue(handle, msg, len) -> i32 (SPSC, head-only writer)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "ipc: ipc_enqueue(handle, msg, len) -> i32 (SPSC, head-only writer)" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:feature,size:s" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipc: ipc_enqueue(handle, msg, len) -> i32 (SPSC, head-only writer)\t3\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nipc: ipc_dequeue(handle, buf, buf_len) -> i64 (SPSC, tail-only reader)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "ipc: ipc_dequeue(handle, buf, buf_len) -> i64 (SPSC, tail-only reader)" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:feature,size:s" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipc: ipc_dequeue(handle, buf, buf_len) -> i64 (SPSC, tail-only reader)\t3\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nipc: memory ordering audit on head/tail updates\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "ipc: memory ordering audit on head/tail updates" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:feature,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipc: memory ordering audit on head/tail updates\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nipc: global lock for MPSC fallback (P1IPC §2.4) [NUMA-aware]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "ipc: global lock for MPSC fallback (P1IPC §2.4) [NUMA-aware]" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:feature,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipc: global lock for MPSC fallback (P1IPC §2.4) [NUMA-aware]\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: register ipc-endpoint dispatch handlers (op codes per rights-catalog §2) [cap-grant]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "cap: register ipc-endpoint dispatch handlers (op codes per rights-catalog §2) [cap-grant]" \
    --body "$BODY" \
    --label "phase:3,area:cap,type:feature,size:s" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: register ipc-endpoint dispatch handlers (op codes per rights-catalog §2) [cap-grant]\t3\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: channel-creation operation creates *two* caps (producer + consumer)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "cap: channel-creation operation creates *two* caps (producer + consumer)" \
    --body "$BODY" \
    --label "phase:3,area:cap,type:feature,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: channel-creation operation creates *two* caps (producer + consumer)\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: ipc_destroy_channel(cap) requires ipc_close right\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "cap: ipc_destroy_channel(cap) requires ipc_close right" \
    --body "$BODY" \
    --label "phase:3,area:cap,type:feature,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: ipc_destroy_channel(cap) requires ipc_close right\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: create→enqueue→dequeue→destroy roundtrip\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "smoke: create→enqueue→dequeue→destroy roundtrip" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:test,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: create→enqueue→dequeue→destroy roundtrip\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: fill-to-full + drain corpus\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "smoke: fill-to-full + drain corpus" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:test,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: fill-to-full + drain corpus\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: wraparound at u32 index boundary\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "smoke: wraparound at u32 index boundary" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:test,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: wraparound at u32 index boundary\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: capability-mismatch (consumer cap on enqueue) rejection\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "smoke: capability-mismatch (consumer cap on enqueue) rejection" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:test,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: capability-mismatch (consumer cap on enqueue) rejection\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: revoked-cap rejection\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "smoke: revoked-cap rejection" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:test,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: revoked-cap rejection\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: kernel-log channel — first real use of IPC\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "smoke: kernel-log channel — first real use of IPC" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:test,size:s" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: kernel-log channel — first real use of IPC\t3\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nperf: SPSC microbench (enqueue+dequeue cycle count)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "perf: SPSC microbench (enqueue+dequeue cycle count)" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:perf,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tperf: SPSC microbench (enqueue+dequeue cycle count)\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nperf: MPSC contention bench (4 producers via P3-007 lock)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "perf: MPSC contention bench (4 producers via P3-007 lock)" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:perf,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tperf: MPSC contention bench (4 producers via P3-007 lock)\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: design/ipc/phase1-api.md closure note + EMSGSIZE, EOVERFLOW addendum\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "docs: design/ipc/phase1-api.md closure note + EMSGSIZE, EOVERFLOW addendum" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:doc,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: design/ipc/phase1-api.md closure note + EMSGSIZE, EOVERFLOW addendum\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: paper-grade deadlock-freedom argument for P3 SPSC (anti-Q1 placeholder)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "docs: paper-grade deadlock-freedom argument for P3 SPSC (anti-Q1 placeholder)" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:doc,size:s" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: paper-grade deadlock-freedom argument for P3 SPSC (anti-Q1 placeholder)\t3\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: audit-catalog roll-up for P3\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "docs: audit-catalog roll-up for P3" \
    --body "$BODY" \
    --label "phase:3,area:ipc,type:doc,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: audit-catalog roll-up for P3\t3\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nci: P3 smoke chain wired\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 3 — IPC primitive (Phase-1 SPSC channel).\n\n## Milestone\nphase-3-ipc-spsc"
gh issue create --repo "$REPO" \
    --title "ci: P3 smoke chain wired" \
    --body "$BODY" \
    --label "phase:3,area:infra,type:infra,size:xs" \
    --milestone "phase-3-ipc-spsc" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tci: P3 smoke chain wired\t3\tXS" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-4 issues (28 tasks)...'

BODY="## Summary\nsched: TCB layout (saved-regs + CSpace ptr + VSpace ptr + state) [gate paideia-as#struct-walker]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: TCB layout (saved-regs + CSpace ptr + VSpace ptr + state) [gate paideia-as#struct-walker]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: TCB layout (saved-regs + CSpace ptr + VSpace ptr + state) [gate paideia-as#struct-walker]\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: TCB allocator (slab of 256 TCBs) + cap_mint(PROCESS, ...) integration [cap-grant]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: TCB allocator (slab of 256 TCBs) + cap_mint(PROCESS, ...) integration [cap-grant]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: TCB allocator (slab of 256 TCBs) + cap_mint(PROCESS, ...) integration [cap-grant]\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: context-switch primitive __switch(prev_tcb*, next_tcb*) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: context-switch primitive __switch(prev_tcb*, next_tcb*) [unsafe]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: context-switch primitive __switch(prev_tcb*, next_tcb*) [unsafe]\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: per-CPU current_tcb slot in GS-base [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: per-CPU current_tcb slot in GS-base [unsafe]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: per-CPU current_tcb slot in GS-base [unsafe]\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: sc_descriptor struct (budget, period, priority, refill state)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: sc_descriptor struct (budget, period, priority, refill state)" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: sc_descriptor struct (budget, period, priority, refill state)\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: p1_sc_create / p1_sc_bind / p1_sc_unbind\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: p1_sc_create / p1_sc_bind / p1_sc_unbind" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: p1_sc_create / p1_sc_bind / p1_sc_unbind\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: budget accounting (TSC-deadline timestamped on switch)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: budget accounting (TSC-deadline timestamped on switch)" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: budget accounting (TSC-deadline timestamped on switch)\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: per-CPU 256-bin priority bitmap + FIFO list per priority [NUMA]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: per-CPU 256-bin priority bitmap + FIFO list per priority [NUMA]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: per-CPU 256-bin priority bitmap + FIFO list per priority [NUMA]\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: sched_pick_next() -> TCB* (BSR + FIFO head)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: sched_pick_next() -> TCB* (BSR + FIFO head)" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: sched_pick_next() -> TCB* (BSR + FIFO head)\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: sched_enqueue(tcb) and sched_dequeue(tcb) (bitmap-aware)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: sched_enqueue(tcb) and sched_dequeue(tcb) (bitmap-aware)" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: sched_enqueue(tcb) and sched_dequeue(tcb) (bitmap-aware)\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: p1_sched_wake(tcb) + p1_sched_block(timeout_ns)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: p1_sched_wake(tcb) + p1_sched_block(timeout_ns)" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: p1_sched_wake(tcb) + p1_sched_block(timeout_ns)\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: p1_sched_yield()\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: p1_sched_yield()" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: p1_sched_yield()\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: p1_sched_current() reads GS:[0]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: p1_sched_current() reads GS:[0]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: p1_sched_current() reads GS:[0]\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: idle TCB per CPU (hlt-only loop) [unsafe] [P1SCH-D4]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: idle TCB per CPU (hlt-only loop) [unsafe] [P1SCH-D4]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: idle TCB per CPU (hlt-only loop) [unsafe] [P1SCH-D4]\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: TSC-deadline timer arming primitive [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: TSC-deadline timer arming primitive [unsafe]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: TSC-deadline timer arming primitive [unsafe]\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: timer IRQ handler — budget tick + reschedule [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: timer IRQ handler — budget tick + reschedule [unsafe]" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: timer IRQ handler — budget tick + reschedule [unsafe]\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsched: minimal IDT entry for timer vector (full IDT in P6)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "sched: minimal IDT entry for timer vector (full IDT in P6)" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsched: minimal IDT entry for timer vector (full IDT in P6)\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: register process kind ops (start/stop/observe/set_priority) [cap-grant]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "cap: register process kind ops (start/stop/observe/set_priority) [cap-grant]" \
    --body "$BODY" \
    --label "phase:4,area:cap,type:feature,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: register process kind ops (start/stop/observe/set_priority) [cap-grant]\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ncap: register sched-ctx kind ops (rebind, set_budget)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "cap: register sched-ctx kind ops (rebind, set_budget)" \
    --body "$BODY" \
    --label "phase:4,area:cap,type:feature,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tcap: register sched-ctx kind ops (rebind, set_budget)\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: two-thread ping-pong over IPC channel\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "smoke: two-thread ping-pong over IPC channel" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:test,size:s" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: two-thread ping-pong over IPC channel\t4\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: priority preemption (low-pri loop, high-pri wakeup)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "smoke: priority preemption (low-pri loop, high-pri wakeup)" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:test,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: priority preemption (low-pri loop, high-pri wakeup)\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: budget exhaustion + refill\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "smoke: budget exhaustion + refill" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:test,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: budget exhaustion + refill\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: yield + round-robin within priority\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "smoke: yield + round-robin within priority" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:test,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: yield + round-robin within priority\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: idle correctness (no runnables → idle)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "smoke: idle correctness (no runnables → idle)" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:test,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: idle correctness (no runnables → idle)\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nperf: context-switch microbench\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "perf: context-switch microbench" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:perf,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tperf: context-switch microbench\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: design/kernel/phase1-sched-api.md closure note\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "docs: design/kernel/phase1-sched-api.md closure note" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:doc,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: design/kernel/phase1-sched-api.md closure note\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: audit-catalog roll-up for P4\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "docs: audit-catalog roll-up for P4" \
    --body "$BODY" \
    --label "phase:4,area:sched,type:doc,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: audit-catalog roll-up for P4\t4\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nci: P4 smoke chain wired\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 4 — Scheduler (fixed-priority preemptive).\n\n## Milestone\nphase-4-scheduler"
gh issue create --repo "$REPO" \
    --title "ci: P4 smoke chain wired" \
    --body "$BODY" \
    --label "phase:4,area:infra,type:infra,size:xs" \
    --milestone "phase-4-scheduler" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tci: P4 smoke chain wired\t4\tXS" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-5 issues (32 tasks)...'

BODY="## Summary\nmm: parse QEMU multiboot-ish memory map [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: parse QEMU multiboot-ish memory map [unsafe]" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: parse QEMU multiboot-ish memory map [unsafe]\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: reserve kernel image + initial page tables + .bss from the free pool\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: reserve kernel image + initial page tables + .bss from the free pool" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: reserve kernel image + initial page tables + .bss from the free pool\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: buddy allocator (4K base, up to 2M block size)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: buddy allocator (4K base, up to 2M block size)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: buddy allocator (4K base, up to 2M block size)\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: per-CPU magazine front-end (16-entry caches, 4K only)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: per-CPU magazine front-end (16-entry caches, 4K only)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: per-CPU magazine front-end (16-entry caches, 4K only)\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: p1_phys_alloc(size, numa_hint) -> phys_addr API\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: p1_phys_alloc(size, numa_hint) -> phys_addr API" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: p1_phys_alloc(size, numa_hint) -> phys_addr API\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: p1_phys_free(addr, size) API\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: p1_phys_free(addr, size) API" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: p1_phys_free(addr, size) API\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: aspace_t struct (PML4 phys, ASID, NUMA home) [gate paideia-as#struct-walker]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: aspace_t struct (PML4 phys, ASID, NUMA home) [gate paideia-as#struct-walker]" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: aspace_t struct (PML4 phys, ASID, NUMA home) [gate paideia-as#struct-walker]\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: p1_aspace_create() — allocate PML4 + zero\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: p1_aspace_create() — allocate PML4 + zero" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: p1_aspace_create() — allocate PML4 + zero\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: PCID allocator (256 entries) [NUMA-aware]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: PCID allocator (256 entries) [NUMA-aware]" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: PCID allocator (256 entries) [NUMA-aware]\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: p1_aspace_activate(cap) — mov cr3, ... with PCID [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: p1_aspace_activate(cap) — mov cr3, ... with PCID [unsafe]" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: p1_aspace_activate(cap) — mov cr3, ... with PCID [unsafe]\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: p1_aspace_destroy(cap) — refcount + reclaim page tables\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: p1_aspace_destroy(cap) — refcount + reclaim page tables" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: p1_aspace_destroy(cap) — refcount + reclaim page tables\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: page-table walk helper walk(pml4, va, create: bool) -> *pte\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: page-table walk helper walk(pml4, va, create: bool) -> *pte" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: page-table walk helper walk(pml4, va, create: bool) -> *pte\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: p1_aspace_map(cap, va, pa, size, flags) — 4K mappings\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: p1_aspace_map(cap, va, pa, size, flags) — 4K mappings" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: p1_aspace_map(cap, va, pa, size, flags) — 4K mappings\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: 2 MiB mapping path (PD-level large pages)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: 2 MiB mapping path (PD-level large pages)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: 2 MiB mapping path (PD-level large pages)\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: p1_aspace_unmap(cap, va, size) + TLB invalidate\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: p1_aspace_unmap(cap, va, size) + TLB invalidate" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: p1_aspace_unmap(cap, va, size) + TLB invalidate\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: page-table reclamation (when PT/PD becomes empty)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: page-table reclamation (when PT/PD becomes empty)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: page-table reclamation (when PT/PD becomes empty)\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: AS teardown completes PT/PD/PDPT reclamation\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: AS teardown completes PT/PD/PDPT reclamation" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: AS teardown completes PT/PD/PDPT reclamation\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: #PF handler (CR2 read, error-code decode) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: #PF handler (CR2 read, error-code decode) [unsafe]" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: #PF handler (CR2 read, error-code decode) [unsafe]\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: panic-trace ring buffer (for #PF and other fatals)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: panic-trace ring buffer (for #PF and other fatals)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: panic-trace ring buffer (for #PF and other fatals)\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: per-NUMA-domain free lists in the buddy [NUMA]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: per-NUMA-domain free lists in the buddy [NUMA]" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: per-NUMA-domain free lists in the buddy [NUMA]\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: per-CPU magazine sized per NUMA-aware refill cost\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: per-CPU magazine sized per NUMA-aware refill cost" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:feature,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: per-CPU magazine sized per NUMA-aware refill cost\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: cap-table per-NUMA migration (deferred from P2-002) [NUMA]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "mm: cap-table per-NUMA migration (deferred from P2-002) [NUMA]" \
    --body "$BODY" \
    --label "phase:5,area:cap,type:feature,size:s" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: cap-table per-NUMA migration (deferred from P2-002) [NUMA]\t5\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: phys-alloc/free torture (1M random 4K alloc/free)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "smoke: phys-alloc/free torture (1M random 4K alloc/free)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:test,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: phys-alloc/free torture (1M random 4K alloc/free)\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: AS create/map/unmap/destroy roundtrip\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "smoke: AS create/map/unmap/destroy roundtrip" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:test,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: AS create/map/unmap/destroy roundtrip\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: 2 MiB large-page mapping\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "smoke: 2 MiB large-page mapping" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:test,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: 2 MiB large-page mapping\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: PCID exhaustion (256 AS creates)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "smoke: PCID exhaustion (256 AS creates)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:test,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: PCID exhaustion (256 AS creates)\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: #PF triggers TCB termination (user fault)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "smoke: #PF triggers TCB termination (user fault)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:test,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: #PF triggers TCB termination (user fault)\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nperf: page-table walk cost\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "perf: page-table walk cost" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:perf,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tperf: page-table walk cost\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nperf: AS-switch cost (with PCID, no flush)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "perf: AS-switch cost (with PCID, no flush)" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:perf,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tperf: AS-switch cost (with PCID, no flush)\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: design/kernel/phase1-mm-api.md closure note\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "docs: design/kernel/phase1-mm-api.md closure note" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:doc,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: design/kernel/phase1-mm-api.md closure note\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: audit-catalog roll-up + critical-structures snapshot\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "docs: audit-catalog roll-up + critical-structures snapshot" \
    --body "$BODY" \
    --label "phase:5,area:mm,type:doc,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: audit-catalog roll-up + critical-structures snapshot\t5\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nci: P5 smoke chain wired\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 5 — Memory management (Phase-1 4K/2M, no CoW).\n\n## Milestone\nphase-5-memory-management"
gh issue create --repo "$REPO" \
    --title "ci: P5 smoke chain wired" \
    --body "$BODY" \
    --label "phase:5,area:infra,type:infra,size:xs" \
    --milestone "phase-5-memory-management" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tci: P5 smoke chain wired\t5\tXS" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-6 issues (25 tasks)...'

BODY="## Summary\nint: 256-entry IDT in .bss with all vectors → panic stub\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "int: 256-entry IDT in .bss with all vectors → panic stub" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tint: 256-entry IDT in .bss with all vectors → panic stub\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nint: IST stacks for #DF (vector 8), NMI (vector 2), #MC (vector 18) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "int: IST stacks for #DF (vector 8), NMI (vector 2), #MC (vector 18) [unsafe]" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tint: IST stacks for #DF (vector 8), NMI (vector 2), #MC (vector 18) [unsafe]\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nint: exception handlers — #UD #GP #PF #DF #MC #NMI\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "int: exception handlers — #UD #GP #PF #DF #MC #NMI" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tint: exception handlers — #UD #GP #PF #DF #MC #NMI\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\napic: x2APIC enablement via IA32_APIC_BASE MSR [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "apic: x2APIC enablement via IA32_APIC_BASE MSR [unsafe]" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tapic: x2APIC enablement via IA32_APIC_BASE MSR [unsafe]\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\napic: LAPIC timer in TSC-deadline mode (replaces P4-015)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "apic: LAPIC timer in TSC-deadline mode (replaces P4-015)" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tapic: LAPIC timer in TSC-deadline mode (replaces P4-015)\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\napic: EOI helper + spurious-interrupt vector\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "apic: EOI helper + spurious-interrupt vector" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tapic: EOI helper + spurious-interrupt vector\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nacpi: discover RSDP/RSDT/XSDT from QEMU multiboot info [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "acpi: discover RSDP/RSDT/XSDT from QEMU multiboot info [unsafe]" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tacpi: discover RSDP/RSDT/XSDT from QEMU multiboot info [unsafe]\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nacpi: MADT walker (LAPIC/x2APIC/IOAPIC/IntOverride entries)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "acpi: MADT walker (LAPIC/x2APIC/IOAPIC/IntOverride entries)" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tacpi: MADT walker (LAPIC/x2APIC/IOAPIC/IntOverride entries)\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\napic: IOAPIC redirection-table programmer [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "apic: IOAPIC redirection-table programmer [unsafe]" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tapic: IOAPIC redirection-table programmer [unsafe]\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\napic: MSI address/data format helper\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "apic: MSI address/data format helper" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tapic: MSI address/data format helper\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\napic: IRQ → notification-cap routing infrastructure [cap-grant]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "apic: IRQ → notification-cap routing infrastructure [cap-grant]" \
    --body "$BODY" \
    --label "phase:6,area:cap,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tapic: IRQ → notification-cap routing infrastructure [cap-grant]\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ntimer: hierarchical timer wheel (8 levels × 64 buckets) [NUMA]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "timer: hierarchical timer wheel (8 levels × 64 buckets) [NUMA]" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\ttimer: hierarchical timer wheel (8 levels × 64 buckets) [NUMA]\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ntimer: timer_add(deadline_ns, cb_channel_cap) API [cap-grant]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "timer: timer_add(deadline_ns, cb_channel_cap) API [cap-grant]" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\ttimer: timer_add(deadline_ns, cb_channel_cap) API [cap-grant]\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ntimer: timer_cancel(timer_cap) + cancellation race handling\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "timer: timer_cancel(timer_cap) + cancellation race handling" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\ttimer: timer_cancel(timer_cap) + cancellation race handling\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ntimer: LAPIC-timer ISR drives the wheel\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "timer: LAPIC-timer ISR drives the wheel" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\ttimer: LAPIC-timer ISR drives the wheel\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nipi: cross-CPU IPI primitive (send vector to APIC ID) [unsafe]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "ipi: cross-CPU IPI primitive (send vector to APIC ID) [unsafe]" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipi: cross-CPU IPI primitive (send vector to APIC ID) [unsafe]\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nmm: TLB-shootdown IPI handler [NUMA]\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "mm: TLB-shootdown IPI handler [NUMA]" \
    --body "$BODY" \
    --label "phase:6,area:mm,type:feature,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tmm: TLB-shootdown IPI handler [NUMA]\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nipi: reschedule IPI (when wake places a TCB on a remote CPU's queue)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "ipi: reschedule IPI (when wake places a TCB on a remote CPU's queue)" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:feature,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tipi: reschedule IPI (when wake places a TCB on a remote CPU's queue)\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: timer-wheel fan-out (1024 timers, all fire on time)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "smoke: timer-wheel fan-out (1024 timers, all fire on time)" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:test,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: timer-wheel fan-out (1024 timers, all fire on time)\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: cancel-during-fire race\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "smoke: cancel-during-fire race" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:test,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: cancel-during-fire race\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: TLB shootdown correctness (4-CPU)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "smoke: TLB shootdown correctness (4-CPU)" \
    --body "$BODY" \
    --label "phase:6,area:mm,type:test,size:s" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: TLB shootdown correctness (4-CPU)\t6\tS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nsmoke: MSI delivery (simulated PCI device IRQ via QEMU)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "smoke: MSI delivery (simulated PCI device IRQ via QEMU)" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:test,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tsmoke: MSI delivery (simulated PCI device IRQ via QEMU)\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nperf: IRQ-to-channel latency\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "perf: IRQ-to-channel latency" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:perf,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tperf: IRQ-to-channel latency\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\ndocs: P6 closure + ACPI partial-consumer note\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "docs: P6 closure + ACPI partial-consumer note" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:doc,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tdocs: P6 closure + ACPI partial-consumer note\t6\tXS" >> "$ISSUE_MAP"
sleep 1


BODY="## Summary\nci: P6 smoke chain (incl. SMP-4 timer + shootdown)\n\n## Acceptance criteria\n- [ ] Implementation complete\n- [ ] Tests pass\n- [ ] Code review approved\n\n## Files\nTBD\n\n## Dependencies\nnone\n\n## Estimated size\nXS\n\n## Phase\nPhase 6 — Interrupt + exception + APIC + timer wheel.\n\n## Milestone\nphase-6-interrupts-apic-timer"
gh issue create --repo "$REPO" \
    --title "ci: P6 smoke chain (incl. SMP-4 timer + shootdown)" \
    --body "$BODY" \
    --label "phase:6,area:infra,type:infra,size:xs" \
    --milestone "phase-6-interrupts-apic-timer" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "{task_id}\t$ISSUE\tci: P6 smoke chain (incl. SMP-4 timer + shootdown)\t6\tXS" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-7 placeholder...'

BODY="## Summary\nPlaceholder for Phase 7 (Driver framework + first drivers). Detailed decomposition will be opened when Gate G6 closes.\n\n## Phase\nPhase 7 — Driver framework + first drivers.\n\n## Milestone\nphase-7-drivers"
gh issue create --repo "$REPO" \
    --title "phase-7: planning + first-task seed" \
    --body "$BODY" \
    --label "phase:7,area:infra,type:feature,size:m" \
    --milestone "phase-7-drivers" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "P{phase_num}-000\t$ISSUE\tphase-7: planning + first-task seed\t7\tm" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-8 placeholder...'

BODY="## Summary\nPlaceholder for Phase 8 (Network stack (user-space TCP/QUIC)). Detailed decomposition will be opened when Gate G7 closes.\n\n## Phase\nPhase 8 — Network stack (user-space TCP/QUIC).\n\n## Milestone\nphase-8-network-stack"
gh issue create --repo "$REPO" \
    --title "phase-8: planning + first-task seed" \
    --body "$BODY" \
    --label "phase:8,area:infra,type:feature,size:m" \
    --milestone "phase-8-network-stack" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "P{phase_num}-000\t$ISSUE\tphase-8: planning + first-task seed\t8\tm" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-9 placeholder...'

BODY="## Summary\nPlaceholder for Phase 9 (Filesystem (CoW, capability-encoded)). Detailed decomposition will be opened when Gate G8 closes.\n\n## Phase\nPhase 9 — Filesystem (CoW, capability-encoded).\n\n## Milestone\nphase-9-filesystem"
gh issue create --repo "$REPO" \
    --title "phase-9: planning + first-task seed" \
    --body "$BODY" \
    --label "phase:9,area:infra,type:feature,size:m" \
    --milestone "phase-9-filesystem" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "P{phase_num}-000\t$ISSUE\tphase-9: planning + first-task seed\t9\tm" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-10 placeholder...'

BODY="## Summary\nPlaceholder for Phase 10 (Userspace runtime (WASM / VM jail)). Detailed decomposition will be opened when Gate G9 closes.\n\n## Phase\nPhase 10 — Userspace runtime (WASM / VM jail).\n\n## Milestone\nphase-10-userspace-runtime"
gh issue create --repo "$REPO" \
    --title "phase-10: planning + first-task seed" \
    --body "$BODY" \
    --label "phase:10,area:infra,type:feature,size:m" \
    --milestone "phase-10-userspace-runtime" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "P{phase_num}-000\t$ISSUE\tphase-10: planning + first-task seed\t10\tm" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-11 placeholder...'

BODY="## Summary\nPlaceholder for Phase 11 (Semantic terminal). Detailed decomposition will be opened when Gate G10 closes.\n\n## Phase\nPhase 11 — Semantic terminal.\n\n## Milestone\nphase-11-semantic-terminal"
gh issue create --repo "$REPO" \
    --title "phase-11: planning + first-task seed" \
    --body "$BODY" \
    --label "phase:11,area:infra,type:feature,size:m" \
    --milestone "phase-11-semantic-terminal" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "P{phase_num}-000\t$ISSUE\tphase-11: planning + first-task seed\t11\tm" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-12 placeholder...'

BODY="## Summary\nPlaceholder for Phase 12 (UEFI real-hardware boot transition). Detailed decomposition will be opened when Gate G11 closes.\n\n## Phase\nPhase 12 — UEFI real-hardware boot transition.\n\n## Milestone\nphase-12-uefi-boot"
gh issue create --repo "$REPO" \
    --title "phase-12: planning + first-task seed" \
    --body "$BODY" \
    --label "phase:12,area:infra,type:feature,size:m" \
    --milestone "phase-12-uefi-boot" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "P{phase_num}-000\t$ISSUE\tphase-12: planning + first-task seed\t12\tm" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-13 placeholder...'

BODY="## Summary\nPlaceholder for Phase 13 (Hardening (mitigations, PQ, attestation, SMP)). Detailed decomposition will be opened when Gate G12 closes.\n\n## Phase\nPhase 13 — Hardening (mitigations, PQ, attestation, SMP).\n\n## Milestone\nphase-13-hardening"
gh issue create --repo "$REPO" \
    --title "phase-13: planning + first-task seed" \
    --body "$BODY" \
    --label "phase:13,area:infra,type:feature,size:m" \
    --milestone "phase-13-hardening" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "P{phase_num}-000\t$ISSUE\tphase-13: planning + first-task seed\t13\tm" >> "$ISSUE_MAP"
sleep 1

echo 'Creating Phase-14 placeholder...'

BODY="## Summary\nPlaceholder for Phase 14 (Self-hosting groundwork). Detailed decomposition will be opened when Gate G13 closes.\n\n## Phase\nPhase 14 — Self-hosting groundwork.\n\n## Milestone\nphase-14-self-hosting"
gh issue create --repo "$REPO" \
    --title "phase-14: planning + first-task seed" \
    --body "$BODY" \
    --label "phase:14,area:infra,type:feature,size:m" \
    --milestone "phase-14-self-hosting" \
    2>/dev/null | tee /tmp/issue_$$ | grep -oP '(?<=#)\d+' >> "$ISSUE_MAP.tmp" || true
ISSUE=$(cat /tmp/issue_$$ | grep -oP '(?<=#)\d+' || echo '?')
echo -e "P{phase_num}-000\t$ISSUE\tphase-14: planning + first-task seed\t14\tm" >> "$ISSUE_MAP"
sleep 1


echo "✓ Issue creation complete."
echo "Issues recorded in $ISSUE_MAP"
echo ""
echo "First 5 issues from each detailed phase:"
for phase in 1 2 3 4 5 6; do
    echo "Phase $phase:"
    grep "^P${phase}-" "$ISSUE_MAP" | head -5 | awk '{print "  " $2 " " $3}'
done
