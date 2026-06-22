#!/usr/bin/env bash
# gh-bootstrap-next-major-round.sh
#
# Bootstrap GitHub state for PaideiaOS v1.0 (R8) next-major-round
# (observable kernel — boot, cap, IPC).
#
# Idempotent: checks for existing labels and issues before creating.
# Two-repo ops: paideia-as for PA10 substrate, paideia-os for B1-B7.
#
# Usage: ./tools/gh-bootstrap-next-major-round.sh
#
# Persists: .plans/next-major-round-issue-map.tsv (TaskID<TAB>Repo<TAB>Issue#<TAB>Title<TAB>Size<TAB>Milestone)

set -euo pipefail

PAIDEIA_OS_REPO="paideia-os/paideia-os"
PAIDEIA_AS_REPO="paideia-os/paideia-as"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ISSUE_MAP="${REPO_ROOT}/.plans/next-major-round-issue-map.tsv"

# Helper: idempotent label creation
create_label_if_missing() {
  local repo="$1" color="$2" name="$3" description="$4"

  if gh label list --repo "$repo" --search "$name" 2>/dev/null | grep -q "$name"; then
    echo "[label] $name already exists on $repo"
    return 0
  fi

  gh label create "$name" \
    --color "$color" \
    --description "$description" \
    --force \
    --repo "$repo"
  echo "[label] created $name on $repo"
}

# Helper: idempotent milestone creation (via GitHub API)
create_milestone_if_missing() {
  local repo="$1" title="$2"

  # Check if milestone exists
  if gh api "repos/$repo/milestones" --jq ".[] | select(.title == \"$title\")" 2>/dev/null | grep -q '"id"'; then
    echo "[milestone] $title already exists on $repo"
    return 0
  fi

  local result=$(gh api "repos/$repo/milestones" \
    -f title="$title" \
    -f description="Milestone for $title" 2>&1)

  if echo "$result" | grep -q '"id"'; then
    echo "[milestone] created $title on $repo"
  elif echo "$result" | grep -q "already_exists"; then
    echo "[milestone] $title already exists on $repo"
  else
    echo "[milestone] error creating $title on $repo: $result"
  fi
}

# Helper: idempotent issue creation
create_issue_if_missing() {
  local repo="$1" task_id="$2" title="$3" size="$4" milestone="$5" labels="$6"

  # Check if title already exists
  if gh issue list --repo "$repo" --search "in:title $task_id" --state open 2>/dev/null | grep -q "$task_id"; then
    echo "[issue] $task_id already exists on $repo"
    return 1
  fi

  local body_file="/tmp/issue_${task_id}.md"
  cat > "$body_file" << EOF
## Repo
$repo

## Summary
Per \`.plans/next-major-round-osarch-plan.md\`.

## Acceptance criteria
[Per osarch plan section]

## Files created / modified
[From osarch plan]

## Dependencies
[From osarch plan]

## Estimated size
$size

## Milestone
$milestone

## Surfaced by
.plans/next-major-round-osarch-plan.md

## Definition of done
Observable acceptance per osarch plan + smoke green (if applicable).

## Notes
Bootstrap issue. Details in .plans/next-major-round-osarch-plan.md.
EOF

  local issue_output=$(gh issue create \
    --repo "$repo" \
    --title "$title" \
    --label "$labels" \
    --milestone "$milestone" \
    --body-file "$body_file" 2>&1)

  # Extract issue number from URL output
  local issue_num=$(echo "$issue_output" | grep -oP 'issues/\K[0-9]+' | head -1)

  rm -f "$body_file"

  if [ -z "$issue_num" ]; then
    echo "[issue] ERROR: Failed to create $task_id (title: $title)"
    return 2
  else
    echo "[issue] Created $task_id: #$issue_num"
    echo "$task_id	$repo	$issue_num	$title	$size	$milestone" >> "$ISSUE_MAP"
    return 0
  fi
}

# Helper: sleep with jitter every 30 ops
op_count=0
check_rate_limit() {
  op_count=$((op_count + 1))
  if (( op_count % 30 == 0 )); then
    echo "[rate-limit] sleeping 30s after $op_count operations..."
    sleep 30
  fi
}

echo "=== PaideiaOS v1.0 (R8) GitHub Bootstrap ==="
echo

# ============================================================================
# SECTION 1: CREATE LABELS
# ============================================================================
echo "--- Section 1: Creating labels ---"

# 9 new paideia-os labels
create_label_if_missing "$PAIDEIA_OS_REPO" "FFB300" "v1.0" "v1.0 round bookmark (first runnable kernel)"
check_rate_limit
create_label_if_missing "$PAIDEIA_OS_REPO" "00897B" "observable" "AC requires runtime behaviour (UART/exit code)"
check_rate_limit
create_label_if_missing "$PAIDEIA_OS_REPO" "3F51B5" "b1-boot-harness" "B1 boot harness reliable"
check_rate_limit
create_label_if_missing "$PAIDEIA_OS_REPO" "673AB7" "b2-long-mode" "B2 long-mode entry verified"
check_rate_limit
create_label_if_missing "$PAIDEIA_OS_REPO" "2196F3" "b3-uart-driver" "B3 UART driver init + putc"
check_rate_limit
create_label_if_missing "$PAIDEIA_OS_REPO" "4CAF50" "b4-banner" "B4 banner observable on COM1"
check_rate_limit
create_label_if_missing "$PAIDEIA_OS_REPO" "FF9800" "b5-cap-observable" "B5 cap mint/verify/invoke observable"
check_rate_limit
create_label_if_missing "$PAIDEIA_OS_REPO" "F44336" "b6-ipc-observable" "B6 SPSC IPC byte-level observable"
check_rate_limit
create_label_if_missing "$PAIDEIA_OS_REPO" "607D8B" "b7-closure" "B7 round closure + v1.0 tag + retro"
check_rate_limit

# 1 paideia-as label
create_label_if_missing "$PAIDEIA_AS_REPO" "FFB300" "v1.0-escalation" "Cross-repo gap surfaced by paideia-os v1.0 round"
check_rate_limit

echo "Labels complete."
echo

# ============================================================================
# SECTION 2: CREATE MILESTONES
# ============================================================================
echo "--- Section 2: Creating milestones ---"

# 7 paideia-os milestones (B1-B7)
create_milestone_if_missing "$PAIDEIA_OS_REPO" "v1.0 B1 — QEMU boot harness reliable"
check_rate_limit
create_milestone_if_missing "$PAIDEIA_OS_REPO" "v1.0 B2 — Long-mode entry verified"
check_rate_limit
create_milestone_if_missing "$PAIDEIA_OS_REPO" "v1.0 B3 — UART driver init + write"
check_rate_limit
create_milestone_if_missing "$PAIDEIA_OS_REPO" "v1.0 B4 — First observable banner"
check_rate_limit
create_milestone_if_missing "$PAIDEIA_OS_REPO" "v1.0 B5 — Cap mint/verify/invoke observable"
check_rate_limit
create_milestone_if_missing "$PAIDEIA_OS_REPO" "v1.0 B6 — IPC byte-level integrity observable"
check_rate_limit
create_milestone_if_missing "$PAIDEIA_OS_REPO" "v1.0 B7 — Closure (STATUS, retrospective, tag)"
check_rate_limit

# 1 paideia-as milestone (PA10)
create_milestone_if_missing "$PAIDEIA_AS_REPO" "PA10 — v1.0 substrate gaps"
check_rate_limit

echo "Milestones complete."
echo

# ============================================================================
# SECTION 3: CREATE ISSUES
# ============================================================================
echo "--- Section 3: Creating issues ---"

# Initialize issue map
: > "$ISSUE_MAP"
echo "TaskID	Repo	Issue#	Title	Size	Milestone" >> "$ISSUE_MAP"

# ============================================================================
# PA10 ISSUES (paideia-as)
# ============================================================================

create_issue_if_missing "$PAIDEIA_AS_REPO" "PA10-001" "PA10-001: PVH ELF Note for QEMU -kernel acceptance" "S" "PA10 — v1.0 substrate gaps" "v1.0-escalation,type:feature,area:toolchain" && check_rate_limit
create_issue_if_missing "$PAIDEIA_AS_REPO" "PA10-002" "PA10-002: string literal lowering to [u8; N] in .rodata" "S" "PA10 — v1.0 substrate gaps" "v1.0-escalation,type:feature,area:parser" && check_rate_limit
create_issue_if_missing "$PAIDEIA_AS_REPO" "PA10-003" "PA10-003: real Imul / And / Or / Xor encoders" "S" "PA10 — v1.0 substrate gaps" "v1.0-escalation,type:feature,area:encoder" && check_rate_limit
create_issue_if_missing "$PAIDEIA_AS_REPO" "PA10-004" "PA10-004: narrow-form Mov (r16-imm, r8-imm)" "S" "PA10 — v1.0 substrate gaps" "v1.0-escalation,type:feature,area:encoder" && check_rate_limit
create_issue_if_missing "$PAIDEIA_AS_REPO" "PA10-005" "PA10-005: residual let-of-Var resolution in deep block bodies" "S" "PA10 — v1.0 substrate gaps" "v1.0-escalation,type:feature,area:elaborator" && check_rate_limit
create_issue_if_missing "$PAIDEIA_AS_REPO" "PA10-006" "PA10-006: closure — boot-to-banner-and-cap-smoke PA10 fixture" "S" "PA10 — v1.0 substrate gaps" "v1.0-escalation,type:feature,area:integration" && check_rate_limit

# ============================================================================
# B1 ISSUES (paideia-os)
# ============================================================================

create_issue_if_missing "$PAIDEIA_OS_REPO" "B1-001" "B1-001: simplify tools/run-qemu.sh to -kernel form" "XS" "v1.0 B1 — QEMU boot harness reliable" "v1.0,observable,b1-boot-harness,type:feature,area:boot" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B1-002" "B1-002: QEMU isa-debug-exit device for deterministic exit codes" "S" "v1.0 B1 — QEMU boot harness reliable" "v1.0,observable,b1-boot-harness,type:feature,area:boot" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B1-003" "B1-003: serial-log fingerprint assertion + B1 closure" "S" "v1.0 B1 — QEMU boot harness reliable" "v1.0,observable,b1-boot-harness,type:feature,area:boot" && check_rate_limit

# ============================================================================
# B2 ISSUES (paideia-os)
# ============================================================================

create_issue_if_missing "$PAIDEIA_OS_REPO" "B2-001" "B2-001: GDT real layout + lgdt sequence in _start" "S" "v1.0 B2 — Long-mode entry verified" "v1.0,observable,b2-long-mode,type:feature,area:boot" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B2-002" "B2-002: page tables + CR4.PAE / CR3 / EFER.LME / CR0.PG sequence" "M" "v1.0 B2 — Long-mode entry verified" "v1.0,observable,b2-long-mode,type:feature,area:boot" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B2-003" "B2-003: far-jmp to 64-bit code segment" "S" "v1.0 B2 — Long-mode entry verified" "v1.0,observable,b2-long-mode,type:feature,area:boot" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B2-004" "B2-004: first observable byte on COM1 — out 0x3F8, 'B'" "XS" "v1.0 B2 — Long-mode entry verified" "v1.0,observable,b2-long-mode,type:feature,area:boot" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B2-005" "B2-005: B2 milestone closure + STATUS.md update" "XS" "v1.0 B2 — Long-mode entry verified" "v1.0,b2-long-mode,type:chore,area:boot" && check_rate_limit

# ============================================================================
# B3 ISSUES (paideia-os)
# ============================================================================

create_issue_if_missing "$PAIDEIA_OS_REPO" "B3-001" "B3-001: real uart_init 7-step COM1 sequence" "S" "v1.0 B3 — UART driver init + write" "v1.0,observable,b3-uart-driver,type:feature,area:kernel-drivers" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B3-002" "B3-002: uart_putc(b: u8) polling-write helper" "S" "v1.0 B3 — UART driver init + write" "v1.0,observable,b3-uart-driver,type:feature,area:kernel-drivers" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B3-003" "B3-003: uart_puts(ptr, len) + banner content via string literal" "S" "v1.0 B3 — UART driver init + write" "v1.0,observable,b3-uart-driver,type:feature,area:kernel-drivers" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B3-004" "B3-004: integrated kernel_main_64 calls uart_init then uart_puts then halts" "S" "v1.0 B3 — UART driver init + write" "v1.0,observable,b3-uart-driver,type:feature,area:kernel-drivers" && check_rate_limit

# ============================================================================
# B4 ISSUES (paideia-os)
# ============================================================================

create_issue_if_missing "$PAIDEIA_OS_REPO" "B4-001" "B4-001: distinguish boot-to-banner smoke from boot-to-halt production" "S" "v1.0 B4 — First observable banner" "v1.0,observable,b4-banner,type:feature,area:boot" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B4-002" "B4-002: integration smoke + B4 closure marker" "XS" "v1.0 B4 — First observable banner" "v1.0,observable,b4-banner,type:chore,area:boot" && check_rate_limit

# ============================================================================
# B5 ISSUES (paideia-os)
# ============================================================================

create_issue_if_missing "$PAIDEIA_OS_REPO" "B5-001" "B5-001: descriptor-table physical layout + module-level static" "S" "v1.0 B5 — Cap mint/verify/invoke observable" "v1.0,observable,b5-cap-observable,type:feature,area:kernel-cap" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B5-002" "B5-002: real cap_mint with descriptor write" "S" "v1.0 B5 — Cap mint/verify/invoke observable" "v1.0,observable,b5-cap-observable,type:feature,area:kernel-cap" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B5-003" "B5-003: real cap_verify with descriptor read" "S" "v1.0 B5 — Cap mint/verify/invoke observable" "v1.0,observable,b5-cap-observable,type:feature,area:kernel-cap" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B5-004" "B5-004: real cap_invoke dispatcher with one observable op" "S" "v1.0 B5 — Cap mint/verify/invoke observable" "v1.0,observable,b5-cap-observable,type:feature,area:kernel-cap" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B5-005" "B5-005: end-to-end cap smoke fixture + B5 closure" "S" "v1.0 B5 — Cap mint/verify/invoke observable" "v1.0,observable,b5-cap-observable,type:feature,area:kernel-cap" && check_rate_limit

# ============================================================================
# B6 ISSUES (paideia-os)
# ============================================================================

create_issue_if_missing "$PAIDEIA_OS_REPO" "B6-001" "B6-001: channel pool placement in .bss + cursor mutability" "S" "v1.0 B6 — IPC byte-level integrity observable" "v1.0,observable,b6-ipc-observable,type:feature,area:kernel-ipc" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B6-002" "B6-002: real ipc_enqueue with rep movsb copy" "S" "v1.0 B6 — IPC byte-level integrity observable" "v1.0,observable,b6-ipc-observable,type:feature,area:kernel-ipc" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B6-003" "B6-003: real ipc_dequeue with rep movsb copy" "S" "v1.0 B6 — IPC byte-level integrity observable" "v1.0,observable,b6-ipc-observable,type:feature,area:kernel-ipc" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B6-004" "B6-004: producer-consumer fixture body (ipc_smoke)" "S" "v1.0 B6 — IPC byte-level integrity observable" "v1.0,observable,b6-ipc-observable,type:feature,area:kernel-ipc" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B6-005" "B6-005: deadlock-freedom invariant + B6 closure" "S" "v1.0 B6 — IPC byte-level integrity observable" "v1.0,observable,b6-ipc-observable,type:feature,area:kernel-ipc" && check_rate_limit

# ============================================================================
# B7 ISSUES (paideia-os)
# ============================================================================

create_issue_if_missing "$PAIDEIA_OS_REPO" "B7-001" "B7-001: combined smoke matrix integration test" "S" "v1.0 B7 — Closure (STATUS, retrospective, tag)" "v1.0,b7-closure,type:chore,area:boot" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B7-002" "B7-002: design — Phase 7 milestone document" "S" "v1.0 B7 — Closure (STATUS, retrospective, tag)" "v1.0,b7-closure,type:chore,area:design" && check_rate_limit
create_issue_if_missing "$PAIDEIA_OS_REPO" "B7-003" "B7-003: round closure — STATUS.md + retrospective + R9 kickoff" "XS" "v1.0 B7 — Closure (STATUS, retrospective, tag)" "v1.0,b7-closure,type:chore,area:design" && check_rate_limit

echo "Issues complete."
echo

# ============================================================================
# SECTION 4: VERIFICATION
# ============================================================================
echo "--- Section 4: Verification ---"

paideia_os_count=$(gh issue list --repo "$PAIDEIA_OS_REPO" --label "v1.0" --state open --limit 1000 2>/dev/null | wc -l)
paideia_as_count=$(gh issue list --repo "$PAIDEIA_AS_REPO" --label "v1.0-escalation" --state open --limit 1000 2>/dev/null | wc -l)

echo "paideia-os v1.0 issues: ~$paideia_os_count (expected ~27)"
echo "paideia-as v1.0-escalation issues: ~$paideia_as_count (expected ~6)"
echo

# Show issue map
echo "Issue map saved to: $ISSUE_MAP"
echo "Total issues in map: $(wc -l < "$ISSUE_MAP")"
echo "Sample (first 5 created issues):"
grep -v '^TaskID' "$ISSUE_MAP" | head -5
echo

echo "=== Bootstrap complete ==="
