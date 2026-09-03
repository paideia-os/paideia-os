# PaideiaOS MASTER_PLAN — MECE Breadth-First Ecosystem Implementation Plan

**Status:** DRAFT, awaiting user confirmation before any execution.
**Date drafted:** 2026-09-03.
**Vantage:** Post `R91-XREPO.M1` (satellites produce runnable ELFs, 0 unresolved refs), post `libpdx-argv v1.1.0` cascade (nine real consumers), monorepo at 0 open issues. Both wave-plan artefacts (`design/roadmap/next-wave-synthesis.md` for the 581 driver+GUI issues; `design/roadmap/persistent-home-wave.md` for the R106–R109 multi-user substrate) are frozen and cross-referenced.
**Scope:** 47 GitHub repos in the `paideia-os` org, ~470 open issues today, ~581 next-wave issues to be filed, four cascade waves (Wave 0 through Wave 3), two coordinated cross-repo cascades (R106–R109 persistent-home, R110-XREPO semantic-pipe 2.0), an estimated 6–8 weeks wall-clock at the current continuous-loop tempo.
**Consumed artefacts:** `ECOSYSTEM_STATUS.md` (2026-09-02 refresh), `design/library-status.md`, `design/roadmap/next-wave-synthesis.md`, `design/roadmap/persistent-home-wave.md`, `.plans/next-round-issue-map.tsv` shape (from prior `tools/gh-bootstrap-next-round-issues.sh` precedent).
**Locked design bias:** novel-clean research-backed choices over POSIX/Unix inheritance; content-addressed identity (ML-DSA-65 keypairs, `/system/users/<pk_fp>.pdxuser`, `/home/<pk_fp>/`); capability-first (no ambient auth, no uid/gid).

---

## 1. Preamble — the "why" of MECE breadth-first orchestration

PaideiaOS has reached the size where sequential per-round work leaves most of the ecosystem idle for weeks at a time. The monorepo has closed every open kernel issue as of the 2026-09-02 refresh. The satellite fleet is 46 repos wide, of which nine are `[█████]` and 32 are `[█░░░░]` scaffold-only. Every scaffold-only repo waits on the same three or four upstream libraries to mature, and every library sweep (libpdx-net, libpdx-elevate audit stream, R102 GUI cluster) is independently reachable from HEAD today. The bottleneck is orchestration bandwidth, not architectural readiness.

MECE breadth-first — **M**utually **E**xclusive, **C**ollectively **E**xhaustive, work everything reachable in parallel until only the serialization points remain — collapses the calendar. The estimate below (6–8 weeks wall-clock) assumes ~30 concurrent softarch agents in Wave 0, ~40 in Wave 1, ~50 in Wave 2, ~20–30 in Wave 3, with the main session serializing builds (the `bash tools/build.sh` invariant) and running the debugger after every softarch iteration. The wall-clock savings vs sequential are 5–8× on the same total tokens.

The exclusion invariant is load-bearing: no two agents may touch the same file in the same wave. The 47-repo topology makes this easy — most agents own an entire satellite repo and never see another satellite. Where two agents must touch the same repo (mostly the monorepo), the plan below carves file-disjoint patches per agent and names the exclusion set explicitly.

This plan is **user-confirmed before execution**. Nothing in Sections 4–9 (filing plan, wave dispatches, cascades) runs until the user reads MASTER_PLAN.md end-to-end and issues an explicit `EXECUTE MASTER_PLAN` confirmation. The plan is also idempotent to re-read: every wave section is written so that re-invoking the plan after a partial execution finds and skips already-landed work.

---

## 2. Ecosystem inventory

**47 repos, 12 roles, ~470 open issues (pre-Wave-0), 581 next-wave issues to file (Phase A).**

Sort order within each role: `[█░░░░]` (scaffold-only) first; the highest-blast-radius under-built repos surface at the top of each block.

### 2.1 Kernel + toolchain (2 repos)

| Repo            | Role                            | HEAD tag            | Open | Notes                                                                                                       |
| --------------- | ------------------------------- | ------------------- | ---: | ----------------------------------------------------------------------------------------------------------- |
| `paideia-os`    | monorepo (kernel + bin + tools) | `net-wave-closed` + | 0    | 0 open issues at this snapshot. Wave-0 filing adds R99+ driver-substrate + R106+ persistent-home + R110-XREPO cascade issues here first. |
| `paideia-as`    | assembler compiler              | `v0.29.2` HEAD (`v0.28.1` last-pushed tag) | 2    | R91-XREPO.M1 Phase A satellite-runtime-shim shipped. Full TLS 1.3 crypto substrate + ML-DSA-65 sign/verify shipped. v0.30 crypto-KDF (Argon2id + ChaCha20-Poly1305 + ML-KEM-768) needs filing for R108 blocker. v0.25–v0.32 driver+GUI bundle series needs filing (Q-ROADMAP-1). |

### 2.2 L0 foundational libraries (4 repos — every satellite depends on these)

| Repo              | Maturity  | Open | Blocks                                    |
| ----------------- | :-------: | ---: | ----------------------------------------- |
| `libpdx-cap`      | `[████░]` | 1    | 30 downstream repos                       |
| `libpdx-audit`    | `[████░]` | 1    | 10 downstream repos (destructive-op tools) |
| `libpdx-elevate`  | `[████░]` | 18   | 8 downstream repos (privileged tools)     |
| `libpdx-argv`     | `[████░]` | 14   | 26 CLI-tool repos (9 real consumers today) |

### 2.3 L1 mid-level libraries (6 repos)

| Repo                       | Maturity  | Open | Blocks                                                                     |
| -------------------------- | :-------: | ---: | -------------------------------------------------------------------------- |
| `libpdx-net`               | `[█░░░░]` | 22   | pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust, fetch, ping, remote, pkg (mirror) |
| `libpdx-config`            | `[█░░░░]` | 0    | pkg, shell, pdxtrust                                                        |
| `libpdx-url`               | `[█░░░░]` | 11   | libpdx-net (HTTPS), pdxcurl, pkg, fetch, remote                            |
| `libpdx-volume`            | `[████░]` | 0    | mkfs.pdxfs, mount.pdxfs, umount.pdxfs (all satisfied)                       |
| `libpdx-schema-registry`   | `[████░]` | 0    | libpdx-semantic-pipe, every semantic-pipe consumer                          |
| `libpdx-semantic-pipe`     | `[█████]` | 6    | postui, shell, every schema-emitting tool                                   |

### 2.4 GUI L2 libraries (3 repos)

| Repo             | Maturity  | Open | Blocks                                              |
| ---------------- | :-------: | ---: | --------------------------------------------------- |
| `libpdx-gfx`     | `[█░░░░]` | 13   | svc-compositor, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint |
| `libpdx-font`    | `[█░░░░]` | 11   | libpdx-gfx, svc-wm, pdxterm, pdxclock, pdxwatch, pdxpaint |
| `libpdx-event`   | `[█░░░░]` | 11   | svc-wm, pdxterm, pdxwatch, pdxpaint                 |

### 2.5 TUI library (1 repo)

| Repo    | Maturity  | Open | Blocks                                              |
| ------- | :-------: | ---: | --------------------------------------------------- |
| postui  | `[█░░░░]` | 40   | postui-dmesg, postui-hex, postui-top, shell, edit, doc |

### 2.6 Services (2 repos)

| Repo             | Maturity  | Open | Notes                                                              |
| ---------------- | :-------: | ---: | ------------------------------------------------------------------ |
| `svc-compositor` | `[█░░░░]` | 16   | Sole holder of `KIND_FB_SCANOUT`; R101–R105 kernel wave landed.    |
| `svc-wm`         | `[█░░░░]` | 12   | Separate process from compositor; tiling policy + `KIND_INPUT_FOCUS`. |

### 2.7 R102 GUI reference apps (4 repos)

| Repo         | Maturity  | Open | Notes                                            |
| ------------ | :-------: | ---: | ------------------------------------------------ |
| `pdxterm`    | `[█░░░░]` | 12   | Framebuffer terminal emulator over `KIND_PTY`.   |
| `pdxpaint`   | `[█░░░░]` | 10   | Pointer routing + drag events + persistent state. |
| `pdxwatch`   | `[█░░░░]` | 10   | Sys-monitor GUI; graphical peer of postui-top.   |
| `pdxclock`   | `[█░░░░]` | 7    | Smallest useful window app: 128×48 clock.        |

### 2.8 Coreutils (6 repos, all `[█████]`)

`cat`, `cp`, `ls`, `mkdir`, `mv`, `rm` — `v1.0.0` in every case. Open issue counts: 7, 4, 20, 4, 7, 7 respectively (39 total, all Enhancement v1.x + R90-XREPO.013 `caps.decl`).

### 2.9 Text tools (3 repos)

| Repo    | Maturity  | Open | Notes                                            |
| ------- | :-------: | ---: | ------------------------------------------------ |
| `doc`   | `[█████]` | 10   | Documentation viewer, semantic-pipe emitter.    |
| `edit`  | `[█░░░░]` | 7    | vi-like modeless TUI editor; gated on postui.   |
| `line`  | `[█░░░░]` | 7    | ed-style scriptable line editor.                 |

### 2.10 Network tools (8 repos)

`pdxcurl` (19 open), `pdxdig` (15), `pdxsock` (14), `pdxping` (13), `pdxtrust` (15), `remote` (7), `fetch` (3), `ping` (3). Every one of these is scaffold-only and blocked on `libpdx-net`.

### 2.11 Shell + pkg (2 repos)

| Repo    | Maturity  | Open | Notes                                                              |
| ------- | :-------: | ---: | ------------------------------------------------------------------ |
| `shell` | `[█████]` | 23   | R66 polish + R73 tier-2 + v2.0 real-exec-substrate.                |
| `pkg`   | `[█████]` | 15   | R70 MVP + Enhancement v1.x + mirror path (buildable post-`#2221`). |

### 2.12 Volume tools (3 repos, all `[█████]`)

`mkfs.pdxfs` v1.1.3, `mount.pdxfs` v1.1.3, `umount.pdxfs` v1.1.2. 6 open across all three (LE-001 elevate-gate + `caps.decl` + libpdx-volume v1.1 adoption).

### 2.13 TUI reference apps (3 repos)

`postui-dmesg`, `postui-hex`, `postui-top` — all scaffold-only and gated on `postui` M1.

**Cross-link:** every entry above traces to `design/library-status.md` (canonical library tracker) and `ECOSYSTEM_STATUS.md` (canonical satellite tracker). This section is a compressed transcription; consult those two documents when a data point matters.

---

## 3. Cross-repo dependency DAG

Cycle check: none — the DAG is a strict tree with `paideia-as` at the root and `paideia-os` monorepo as a peer root (both feed every satellite; they do not depend on each other except via periodic submodule bumps which are serialization points, not dependencies).

### 3.1 ASCII diagram

```
paideia-as ─────────────────────────────────────────────────────────────┐
   │                                                                    │
   │ (every .pdx compilation everywhere)                                │
   ▼                                                                    │
paideia-os monorepo ────────────────────────────────────────────────────┤
   │ (kernel-side KIND_*, syscall table, daemon registry)               │
   ▼                                                                    │
┌────────────────────────────┐                                          │
│ L0 (foundational):         │                                          │
│   libpdx-cap ──────────────┼─▶ every satellite                        │
│   libpdx-audit ────────────┼─▶ every destructive-op tool              │
│   libpdx-elevate ──────────┼─▶ every privileged tool                  │
│   libpdx-argv ─────────────┼─▶ every CLI tool                         │
└────────────────────────────┘                                          │
   │                                                                    │
   ▼                                                                    │
┌────────────────────────────┐                                          │
│ L1 (mid-level):            │                                          │
│   libpdx-schema-registry ──┼─▶ libpdx-semantic-pipe (bind_by_name)    │
│   libpdx-semantic-pipe ────┼─▶ postui + shell + every schema tool     │
│   libpdx-url ──────────────┼─▶ libpdx-net (HTTPS URL validation)      │
│   libpdx-net ──────────────┼─▶ 8 network tools + pkg mirror           │
│   libpdx-volume ───────────┼─▶ mkfs/mount/umount.pdxfs                │
│   libpdx-config ───────────┼─▶ pkg + shell + pdxtrust                 │
└────────────────────────────┘                                          │
   │                                                                    │
   ▼                                                                    │
┌────────────────────────────┐                                          │
│ L2 (GUI):                  │                                          │
│   libpdx-font ─────────────┼─▶ libpdx-gfx + every GUI app             │
│   libpdx-gfx ──────────────┼─▶ svc-compositor + svc-wm + 4 GUI apps   │
│   libpdx-event ────────────┼─▶ svc-wm + 3 event-consuming GUI apps    │
└────────────────────────────┘                                          │
   │                                                                    │
   ▼                                                                    │
┌────────────────────────────┐                                          │
│ Services:                  │                                          │
│   svc-compositor ──────────┼─▶ svc-wm + 4 R102 apps                   │
│   svc-wm ──────────────────┼─▶ 4 R102 apps                            │
└────────────────────────────┘                                          │
   │                                                                    │
   ▼                                                                    │
┌────────────────────────────┐  ┌──────────────────────────────────┐
│ TUI lib + apps:            │  │ Terminal apps (R102):            │
│   postui ──▶ dmesg/hex/top │  │   pdxterm/pdxclock/pdxwatch/     │
│   postui ──▶ shell/edit/doc│  │   pdxpaint (all leaves)          │
└────────────────────────────┘  └──────────────────────────────────┘
                                                                       │
Coreutils (6) + volume tools (3) + pkg + shell — L0+L1 only ───────────┘
Network tools (8) — L0 + libpdx-url + libpdx-net ──────────────────────┘
```

### 3.2 Keystone ranking (by downstream count, ties broken by open-issue count)

1. **`paideia-as`** — every satellite (46). Any breaking change here cascades to 46 repos via submodule bump. This is why every paideia-as release is a serialization point.
2. **`paideia-os` monorepo** — every satellite via kernel-side `KIND_*` + syscall table. Currently 0 open, so not a bottleneck; but every wave of Section 4 files kernel-side work first.
3. **`libpdx-cap`** — 30 downstream repos. 1 open, externally blocked; near-frozen. Not a bottleneck.
4. **`libpdx-argv`** — 26 downstream (9 real consumers). Just landed v1.1.0; the mangle fix (`#40`) is what let satellites adopt it at all. Near-frozen for the next wave.
5. **`libpdx-semantic-pipe`** — 17 downstream. This is the R110-XREPO cascade target (Q-LIB-2): the 2.0 ABI break happens after R100/R102 M5s land, and its migration is a whole cascade of its own.
6. **`libpdx-net`** — 9 downstream, 22 open. Sole blocker for the R100 network-tools wave; the highest-priority under-built library today.
7. **`postui`** — 6 downstream, 40 open. Sole blocker for shell/edit/doc TUI layer and the three postui reference apps.
8. **`libpdx-gfx` + `libpdx-font` + `libpdx-event`** — jointly the R102 GUI cluster gate. All three at scaffold, ~35 open combined.
9. **`svc-compositor` + `svc-wm`** — the compositor pair. 28 open combined; downstream of the R102 GUI cluster. Neither can begin real body until libpdx-gfx M2 lands.

Keystones 5–9 define the shape of Wave 0 through Wave 2 below.

---

## 4. Filing plan for the 581 next-wave issues (Phase A of MASTER_PLAN)

**Locked decision (Q-ROADMAP-1 = A):** file ALL 581 issues before any Wave 0 code loop dispatches. This section describes how.

### 4.1 What gets filed

Three input streams merge into one filing manifest:

- **Driver axis (R29–R47):** 12 R-rounds + 3 D4/D5 additions (R41, R42, R44) + 1 hardening (R47) = 16 milestones, ~395 issues, per `next-wave-synthesis.md` §9 and §10.
- **GUI axis (G1–G12):** 12 G-milestones, ~186 issues, per `next-wave-synthesis.md` §2 and §9.
- **paideia-as bundle series (v0.25–v0.32):** 8 bundle-milestones, ~40 aggregate issues (one umbrella per bundle plus per-primitive tickets), per `next-wave-synthesis.md` §6.

**Additional filings landed via this same script pass (out-of-band from the 581):**

- **paideia-as v0.33-crypto-kdf** — Argon2id + ChaCha20-Poly1305 + ML-KEM-768 intrinsics (blocks R108). ~5 issues.
- **R106 persistent-home substrate** (6 milestones, ~15 issues), per `persistent-home-wave.md`. This is not part of the 581; it lands *now* per Q10=A hard-close per-round policy but its scaffold + shell-repo cascade fires in Wave 0.
- **paideia-os/shell satellite repo scaffold** — a wave-plan-time chore (created 2026-09-03) so R106.M4 has a landing site.
- **Retirement notices:** `fetch` (superseded by pdxcurl) + `ping` (superseded by pdxping) archive follow-ups; retention window until the R100 network-tools wave lands. 2 issues.
- **Two silent-security gaps in `rm`** (#19, #20, #21): file as Wave-0 priorities. 3 issues (the third is a compound of #20/#21).
- **paideia-as untracked debt** (Q-A-3, three items): 3 issues.

Grand total to file in Phase A: **581 core + 5 v0.33 + 15 R106 + 5 misc + 3 paideia-as untracked = 609 issues across ~34 new milestones.**

### 4.2 How they get filed — scripted, not manual

Extend the existing precedent (`tools/gh-bootstrap-issues.sh`, 1951 lines; `tools/gh-bootstrap-next-round-issues.sh`, 627 lines). A new script `tools/gh-bootstrap-next-wave-issues.sh` reads a TSV manifest and creates milestones + issues idempotently. The manifest lives at `.plans/next-wave-issues.tsv`.

**Manifest shape (`.plans/next-wave-issues.tsv`):**

```
repo                milestone                    issue_title                    labels           body_source
paideia-os          r29-driver-substrate         R29.M1-001 KIND_HW slot 14     next-wave,R29    bodies/r29-m1-001.md
paideia-os          r29-driver-substrate         R29.M1-002 KIND_INTERRUPT      next-wave,R29    bodies/r29-m1-002.md
...
paideia-os          g7-compositor-protocol       G7.M1-005 KIND_SURFACE freeze  next-wave,G7     bodies/g7-m1-005.md
...
paideia-as          v0.25-session-functors       v0.25 session-typed sigs       bundle,v0.25     bodies/pas-v0.25-umbrella.md
paideia-as          v0.33-crypto-kdf             v0.33 argon2id intrinsic       bundle,v0.33     bodies/pas-v0.33-argon2id.md
...
```

**Script sketch (~200 lines new; reuses the existing `throttle`, `issue_exists`, `create_milestone` helpers from `gh-bootstrap-next-round-issues.sh`):**

```bash
#!/usr/bin/env bash
# tools/gh-bootstrap-next-wave-issues.sh
# Idempotent: reads .plans/next-wave-issues.tsv + bodies/ dir; creates
# milestones on first sight; creates issues iff (repo, milestone, title)
# triple not already open.
set -euo pipefail
MANIFEST=".plans/next-wave-issues.tsv"
BODIES_DIR=".plans/next-wave-bodies"
LOG=".plans/next-wave-issue-map.tsv"
: > "$LOG"
milestones_seen=""

while IFS=$'\t' read -r repo milestone title labels body_source; do
    # skip header
    [ "$repo" = "repo" ] && continue

    # create milestone if not seen this run
    key="$repo|$milestone"
    case "$milestones_seen" in
        *"$key"*) ;;
        *) create_milestone "$repo" "$milestone"
           milestones_seen="$milestones_seen $key" ;;
    esac

    # skip if already open
    existing=$(issue_exists "$repo" "$title")
    if [ -n "$existing" ]; then
        echo -e "$repo\t$milestone\t$title\t$existing\tSKIPPED" >> "$LOG"
        continue
    fi

    body_file="$BODIES_DIR/$body_source"
    [ -f "$body_file" ] || { echo "MISSING $body_file"; exit 1; }

    issue_num=$(gh issue create --repo "$repo" \
        --title "$title" --milestone "$milestone" \
        --label "$labels" --body-file "$body_file" \
        | grep -oP '(?<=/issues/)\d+')
    echo -e "$repo\t$milestone\t$title\t$issue_num\tCREATED" >> "$LOG"
    throttle
done < "$MANIFEST"
```

**Body generation:** issue bodies are drafted per-milestone by softarch (batched, one dispatch per milestone). Each softarch invocation reads the relevant milestone's synthesis-doc entry and produces ~15–40 issue body files under `.plans/next-wave-bodies/<round>-<mid>-<seq>.md`. Body drafting is the ~4-hour manual-refinement fraction of §11 of the synthesis doc; it runs in parallel across ~10 softarch agents (one per group of 3–4 milestones), all working on disjoint body files, no MECE conflict.

**Estimated wall-clock:** 1 hour scripted milestone creation (34 milestones × 30 s each including throttle) + 3 hours parallel body drafting + 2 hours scripted issue creation (609 issues × ~10 s each with 30-op throttle) = **~1 workday**.

### 4.3 Owner assignment

Every issue is filed unassigned. The autonomous loop picks work up per `feedback_paideia_os_tempo.md`. Milestone owners (informal, for review-triage):

- Driver axis (R29–R47): osarch as review authority; softarch as landing authority.
- GUI axis (G1–G12): uxdes as review authority (compositor protocol especially); softarch as landing.
- paideia-as bundles: comparch as review authority for HW-adjacent bundles (v0.27 DMA/timeline, v0.28 GPU submit); algogenie for algorithm-adjacent bundles (v0.30 SPIR-V, v0.31 HDR); softarch for surface-typing bundles (v0.25, v0.29, v0.32).

---

## 5. Wave-0 dispatch layout — the parallel MECE partition

**Locked decision (Q-OPS-1 = B):** Wave 0 dispatches immediately in disjoint repos after Phase A filing closes. **Explicit exclusion list** (repos with in-flight work as of 2026-09-03): the R106 persistent-home rootfs_seed thread is not yet merged; the `ls` ENH-wave (9 partials in-flight) touches ls repo; the `shell` v2.0 real-exec-substrate thread; the `paideia-as` crypto sweep (Ed25519 sc_muladd stall, #1341). Wave-0 agents avoid these four repos.

**Wave-0 target:** every scaffold-only repo lands M1 (scaffolding + real body of one core primitive). This unblocks Wave 1 across the ecosystem.

### 5.1 Wave-0 dispatch table (~30 concurrent agents)

| Agent ID | Repo                        | Issue set (M1)                     | Files touched (declared, all under repo root) | MECE-conflict check | Est. size | Priority |
| -------- | --------------------------- | ---------------------------------- | --------------------------------------------- | ------------------- | :-------: | :------: |
| W0-01    | `libpdx-net`                | M1-001..M1-005 (TCP wrapper skel)  | `src/tcp.pdx`, `src/socket.pdx`, `tests/tcp_smoke.pdx` | disjoint | M | P0 |
| W0-02    | `libpdx-url`                | M1-001..M1-003 (parser skel)       | `src/parse.pdx`, `src/authority.pdx`          | disjoint | S | P0 |
| W0-03    | `libpdx-font`               | M1-001..M1-004 (8x16 glyph store)  | `src/glyph.pdx`, `src/metrics.pdx`, `assets/font-8x16.pdx` | disjoint | S | P0 |
| W0-04    | `libpdx-gfx`                | M1-001..M1-005 (BGRA rect/blit)    | `src/surface.pdx`, `src/primitives.pdx`       | disjoint | M | P0 |
| W0-05    | `libpdx-event`              | M1-001..M1-004 (subscribe skel)    | `src/subscribe.pdx`, `src/route.pdx`          | disjoint | S | P0 |
| W0-06    | `postui`                    | postui.M1-001..M1-010 (canvas + widget base) | `src/canvas.pdx`, `src/widget.pdx`, `src/frame.pdx` | disjoint | L | P0 |
| W0-07    | `svc-compositor`            | M1-001..M1-004 (window table skel) | `src/window_table.pdx`, `src/fb_scanout.pdx`  | disjoint | M | P0 |
| W0-08    | `svc-wm`                    | M1-001..M1-003 (tiling policy skel)| `src/tiling.pdx`, `src/focus.pdx`             | disjoint | M | P0 |
| W0-09    | `pdxterm`                   | M1-001..M1-003 (fb ttty skel)      | `src/tty.pdx`, `src/pty_bridge.pdx`           | disjoint | S | P1 |
| W0-10    | `pdxclock`                  | M1-001..M1-002 (window skel)       | `src/main.pdx`, `src/render.pdx`              | disjoint | S | P1 |
| W0-11    | `pdxpaint`                  | M1-001..M1-003 (canvas + pointer)  | `src/canvas.pdx`, `src/pointer.pdx`           | disjoint | S | P1 |
| W0-12    | `pdxwatch`                  | M1-001..M1-002 (sysmon skel)       | `src/main.pdx`, `src/collectors.pdx`          | disjoint | S | P1 |
| W0-13    | `pdxcurl`                   | M1-001..M1-004 (arg parse + config)| `src/main.pdx`, `src/args.pdx`                | disjoint | M | P1 |
| W0-14    | `pdxdig`                    | M1-001..M1-003 (query skel)        | `src/main.pdx`, `src/query.pdx`               | disjoint | S | P1 |
| W0-15    | `pdxsock`                   | M1-001..M1-003 (netcat mode skel)  | `src/main.pdx`, `src/mode.pdx`                | disjoint | S | P1 |
| W0-16    | `pdxping`                   | M1-001..M1-002 (arg + icmp shape)  | `src/main.pdx`, `src/icmp.pdx`                | disjoint | S | P1 |
| W0-17    | `pdxtrust`                  | M1-001..M1-003 (trust CLI skel)    | `src/main.pdx`, `src/anchor.pdx`              | disjoint | S | P1 |
| W0-18    | `remote`                    | M1-001..M1-002 (arg + session skel)| `src/main.pdx`, `src/session.pdx`             | disjoint | S | P2 |
| W0-19    | `edit`                      | M1-001..M1-003 (mode + buffer skel)| `src/main.pdx`, `src/buffer.pdx`, `src/mode.pdx` | disjoint | M | P1 |
| W0-20    | `line`                      | M1-001..M1-003 (ed CLI skel)       | `src/main.pdx`, `src/lexer.pdx`               | disjoint | S | P2 |
| W0-21    | `libpdx-config`             | M1-001..M1-003 (kv parser real body)| `src/parse.pdx`, `src/lookup.pdx`             | disjoint | S | P1 |
| W0-22    | `paideia-as`                | v0.33-crypto-kdf M1 (Argon2id intrinsic) | `crates/paideia-as-crypto/src/argon2id.rs`, tests | disjoint from #1341 Ed25519 | L | P0 |
| W0-23    | `paideia-os` (monorepo)     | R29.M1 draft: `KIND_HW` slot 14 + KIND_INTERRUPT scaffold | `src/kernel/core/cap/kind_hw.pdx`, `design/kernel/linearity-and-tags.md` (§3.1 update) | disjoint from #1341 | M | P0 |
| W0-24    | `paideia-os` (monorepo)     | R106.M1 rootfs_seed extension     | `src/user/rootfs_seed.pdx` (extend, not overlap with in-flight) | **needs coordination with in-flight R106 thread — see exclusion note** | S | P0 |
| W0-25    | `paideia-os` (monorepo)     | R110-XREPO wire-ABI spec draft (Q-SVC-1) | `design/graphics/r102-wire-abi.md` (new file) | disjoint | S | P0 |
| W0-26    | `paideia-os` (monorepo)     | rm silent-security gap fixes (#19/#20/#21 in `rm`; kernel-side audit) | `src/kernel/core/vfs/rm.pdx` + audit-record schema | disjoint | S | P0 |
| W0-27    | `paideia-as`                | untracked-debt items 1..3 (Q-A-3) | (per-item file set; see Section 13) | disjoint from W0-22 | S | P1 |
| W0-28    | `libpdx-elevate`            | LE.M1 unit tests (audit stream)   | `tests/elevate_client_unit.pdx`                | disjoint | M | P1 |
| W0-29    | `libpdx-schema-registry`    | R90-XREPO.012 bind_by_name real path | `src/bind.pdx`                              | disjoint (semantic-pipe co-dep runs Wave-1) | S | P1 |
| W0-30    | `libpdx-argv`               | ENH-027 boundary fixtures (#37)   | `tests/boundary/*.pdx`                        | disjoint | S | P2 |

**Wave-0 total:** ~30 agents, ~110 issues touched across 22 repos and 3 files in the monorepo, all file-disjoint. Estimated ~4 hours of parallel softarch work + ~150 min of main-serialized builds (30 × 5 min avg per build).

### 5.2 Wave-0 exclusions (explicit)

- **`paideia-os/paideia-os` R106.M1** — coordinate with in-flight rootfs_seed thread; W0-24 files a follow-up PR, not a parallel patch to the same lines.
- **`paideia-os/ls`** — the 9-partial-ENH thread is in-flight; do not dispatch to `ls` in Wave 0.
- **`paideia-os/shell` (monorepo copy of shell code)** — the v2.0 real-exec-substrate thread is in-flight.
- **`paideia-as` #1341 Ed25519 sc_muladd** — do not touch `crates/paideia-as-crypto/src/ed25519_ct.rs`; W0-22 and W0-27 both stay clear of Ed25519 code.

---

## 6. Wave-1 sketch (~40 agents)

**Trigger:** every Wave-0 M1 landed + submodule bumps merged. Estimated wall-clock: 4–7 days after Wave 0 kicks off.

**Wave-1 target:** M2 real-body landings across the ecosystem, plus first-round M1 for the Wave-0-blocked layer (svc-compositor/svc-wm can begin real body only once libpdx-gfx M2 lands; the four R102 apps can begin real body only once svc-compositor M2 lands + libpdx-event M2 lands).

### 6.1 Wave-1 dispatch table (excerpt; ~40 agents total)

| Agent ID | Repo                        | Issue set                          | Blocked-on (Wave-0)          | Est. size |
| -------- | --------------------------- | ---------------------------------- | ---------------------------- | :-------: |
| W1-01    | `libpdx-net`                | M2 (UDP + DNS resolver)            | libpdx-net M1               | L |
| W1-02    | `libpdx-net`                | M3 (TLS 1.3 raw-pubkey client)     | libpdx-net M2 + paideia-as v0.29.2 | L |
| W1-03    | `libpdx-url`                | M2 (validator + normalizer)        | libpdx-url M1               | M |
| W1-04    | `libpdx-font`               | M2 (metrics + baseline)            | libpdx-font M1              | M |
| W1-05    | `libpdx-gfx`                | M2 (line + glyph blit)             | libpdx-gfx M1 + libpdx-font M2 | L |
| W1-06    | `libpdx-event`              | M2 (window-scoped subscribe)       | libpdx-event M1             | M |
| W1-07    | `postui`                    | postui.M2 (layout + focus)         | postui M1                   | L |
| W1-08    | `postui`                    | postui.M3 (widget lib base — buttons/lists) | postui.M2          | L |
| W1-09    | `svc-compositor`            | M2 (render loop + input pump)      | libpdx-gfx M2               | L |
| W1-10    | `svc-wm`                    | M2 (focus + shortcuts)             | svc-compositor M2 + libpdx-event M2 | M |
| W1-11–14 | `pdxterm/pdxclock/pdxpaint/pdxwatch` | each M2 (real render body) | libpdx-gfx M2 + svc-compositor M2 | S |
| W1-15    | `pdxcurl`                   | M2 (URL + HTTP GET)                | libpdx-net M2 + libpdx-url M2 | M |
| W1-16    | `pdxdig`                    | M2 (real DNS via libpdx-net)       | libpdx-net M2                | M |
| W1-17    | `pdxsock`                   | M2 (TCP client/server)             | libpdx-net M2                | M |
| W1-18    | `pdxping`                   | M2 (sys_icmp_echo path)            | monorepo sysno 96 landing (Wave-0 add) | M |
| W1-19    | `pdxtrust`                  | M2 (KIND_TLS_TRUST mint)           | monorepo KIND_TLS_TRUST landing (Wave-0 add) | M |
| W1-20    | `paideia-as`                | v0.33 ChaCha20-Poly1305 intrinsic | v0.33 M1 (Argon2id)         | M |
| W1-21    | `paideia-as`                | v0.33 ML-KEM-768 intrinsic         | v0.33 M1                    | L |
| W1-22    | `paideia-as`                | v0.25 session-typed functors umbrella (blocks R29) | v0.25 M1 body drafting | L |
| W1-23    | `paideia-os` (monorepo)     | R29.M2 KIND_MSIX_VECTOR + KIND_DMA_DOMAIN | R29.M1 (Wave-0)      | M |
| W1-24    | `paideia-os` (monorepo)     | R30.M1 ACPICA userspace bubble skel| R29.M1 (Wave-0)             | L |
| W1-25    | `paideia-os` (monorepo)     | R106.M2 init envp HOME retarget    | R106.M1 (Wave-0)            | S |
| W1-26–30 | coreutils (5 of 6)         | Enhancement v1.x + `caps.decl`     | libpdx-argv v1.1.0 (landed) | S |
| W1-31    | `mkfs.pdxfs`                | `#26` LE-001 elevate-gate          | libpdx-elevate v1.1.1       | S |
| W1-32    | `mount.pdxfs`               | `#20` caps.decl                    | libpdx-cap v1.0.1           | S |
| W1-33    | `umount.pdxfs`              | `#22` LE-001 + `#21` libpdx-volume adoption | libpdx-elevate v1.1.1 + libpdx-volume v1.1.5 | S |
| W1-34    | `shell`                     | R66 polish subset (file-disjoint from in-flight v2.0 thread) | (paceable) | M |
| W1-35    | `pkg`                       | mirror path activation (post-`#2221`) | libpdx-net M2            | M |
| W1-36    | `libpdx-elevate`            | LE.M2 real audit-swap              | libpdx-audit v1.1.1 (landed) | M |
| W1-37    | `libpdx-elevate`            | LE.M4 reap                         | libpdx-elevate LE.M2        | M |
| W1-38    | `postui-dmesg`              | M1 (skel — consumes postui M2)     | postui M2                    | S |
| W1-39    | `postui-hex`                | M1                                 | postui M2                    | S |
| W1-40    | `postui-top`                | M1                                 | postui M2                    | S |

**Wave-1 total:** ~40 agents, ~180 issues touched, ~10 different files in the monorepo (still file-disjoint per agent). Estimated ~5 hours of parallel softarch + ~200 min main-serialized builds.

---

## 7. Wave-2 sketch (~50 agents)

**Trigger:** every Wave-1 M2 landed. Estimated wall-clock: 10–14 days after Wave 0 kickoff.

**Wave-2 target:** M3 (audit + elevate + semantic-pipe wire) + R100 M3 (network tools reach real network) + R102 M3 (four R102 apps render to real compositor surfaces) + the postui M2 widget explosion (buttons, lists, text-input, progress-bar, tab, split, tree, table, dialog — ~9 new widgets, all parallelizable).

Wave-2 is where concurrency peaks (~50 agents) because postui splits into 9 parallel widget dispatches, R100 splits into 8 parallel network-tool dispatches, R102 splits into 4 parallel app dispatches, and the driver axis (R29/R30/R32) each has 4–6 parallel M3 issue sets.

### 7.1 Wave-2 category breakdown

- **postui widget explosion (9 agents):** button, list, text-input, progress-bar, tab-strip, split-pane, tree-view, table, dialog. Each agent owns one widget file under `postui/src/widgets/<name>.pdx`. File-disjoint by construction.
- **R100 network-tool M3 (8 agents):** pdxcurl, pdxdig, pdxsock, pdxping, pdxtrust, remote, fetch (final polish), pkg (mirror path close).
- **R102 app M3 (4 agents):** pdxterm, pdxclock, pdxpaint, pdxwatch — each lands its M3 (audit + elevate + semantic-pipe wire).
- **Driver axis M3 (12 agents):** R29 completes; R30 M2; R32 M1; R31 M1; R34 M1 (USB fabric); R36 M1 (display substrate); R38 M1 (Wi-Fi); v0.26–v0.28 paideia-as bundles kick off in parallel; R33 M1 (audio).
- **GUI axis M3 (6 agents):** G1 M1 (`KIND_DISPLAY_TIMELINE`); G3 M1 (Vulkan surface skel); G4 M1 (Vello scene IR); G5 M1 (SDF text pipeline scaffold); G6 M1 (color-profile scaffold); G7 M1 (PWP protocol first draft).
- **L0/L1 hardening (7 agents):** libpdx-cap next enhancement; libpdx-argv ENH backlog; libpdx-audit LA.M1-006 regression; libpdx-elevate LE.M5 attestation + LE.M6 audit sink + LE.M7 revoke cascade; libpdx-semantic-pipe R110-XREPO planning (see §9); libpdx-net M4 (HTTPS via libpdx-url M3).
- **R106–R108 progression (4 agents):** R106.M3–M6 close; R107.M1 file-bdev skel; R108.M1 signed-record read/write prep; paideia-os/shell satellite M1 (tokenizer + dispatcher landing).

**Wave-2 total:** ~50 agents, ~250 issues, ~15 monorepo files touched (still disjoint per agent). Estimated ~6 hours parallel softarch + ~250 min main-serialized builds.

---

## 8. Wave-3+ (M4/M5) — smokes + releases (~20–30 agents)

**Trigger:** every Wave-2 M3 landed. Estimated wall-clock: 3–4 weeks after Wave 0 kickoff.

**Wave-3 target:** M4 (tests + smoke) + M5 (signed release) across every satellite that reached M3. Concurrency drops because the test harnesses share `tools/build.sh`, `tools/run-smoke.sh`, and the QEMU smoke driver — those are session-serialization points.

- **Volume-tool release cascade** (3 agents, serialized): `mkfs.pdxfs`, `mount.pdxfs`, `umount.pdxfs` each release closing their 6 open.
- **Coreutils release cascade** (6 agents, serialized-in-pairs): each of `cat/cp/ls/mkdir/mv/rm` closes v1.1 with the full Enhancement v1.x wave + `caps.decl`.
- **Network-tool release cascade** (8 agents, serialized in pairs): pdxcurl v1.0, pdxdig v1.0, pdxsock v1.0, pdxping v1.0, pdxtrust v1.0, fetch v0.9 (superseded release; see §13), ping (retirement), remote v0.9.
- **R102 app release cascade** (4 agents): pdxterm/pdxclock/pdxpaint/pdxwatch each cut v0.5 or v1.0 depending on M5 completeness.
- **GUI-lib release cascade** (3 agents): libpdx-font v1.0, libpdx-gfx v1.0, libpdx-event v1.0.
- **postui + reference apps cascade** (4 agents): postui v1.0 + postui-dmesg/hex/top v0.5.
- **svc-compositor + svc-wm release** (2 agents): each cuts v0.5 M4/M5.
- **paideia-as bundle releases** (8 agents, one per bundle): v0.25 → v0.32 each cut a signed release.

**Wave-3 total:** ~25–30 agents (many serialized on smoke harness), ~150 release issues, ~50 monorepo submodule bumps. Estimated ~8 hours parallel softarch + ~400 min main-serialized builds + smoke-driver runs.

---

## 9. Cross-repo cascade waves

Two cascades sit outside the Wave 0–3 shape because they touch many repos in a coordinated ABI-break or feature landing.

### 9.1 R106–R109 persistent-home cascade (per `design/roadmap/persistent-home-wave.md`)

Already planned in the referenced doc; not restated here. Its landing schedule interleaves with Wave 0–3:

- **R106** — Wave 0 (rootfs_seed extension) + Wave 1 (init envp + hardcode retirement) + Wave 2 (M4 shell tokenizer in satellite repo) + Wave 3 (M5 boot smoke + M6 closure).
- **R107** — Wave 2 (file-bdev + devfs + mount) + Wave 3 (M5 mount-variant smoke).
- **R108** — Wave 3 (identity substrate; blocked on paideia-as v0.33 landed in Wave 1).
- **R109** — post-Wave-3 (multi-user session + login).

Cross-repo obligations R106–R109 discharge into the org:
- `paideia-os/shell` satellite repo created at wave-plan time (before R106 kickoff; Wave 0 chore).
- paideia-as v0.33 milestone opened + issues filed at Phase A (blocks R108 in Wave 3).

### 9.2 R110-XREPO — libpdx-semantic-pipe 2.0 cascade (Q-LIB-2 = B)

**Locked decision:** the libpdx-semantic-pipe 2.0.0 ABI break happens AFTER R100 M5 (network-tools wave close) and R102 M5 (GUI apps wave close). One coordinated R110-XREPO cascade migrates the 17 downstream consumers in a single planned round.

**Timing:** post-Wave-3, ~5–6 weeks after Wave 0 kickoff. Precedes the R106–R109 R109.M1 session substrate (which will consume the 2.0 API directly).

**Cascade shape (per `libpdx-argv` v1.1.0 satellite cascade precedent, ECOSYSTEM_STATUS.md headline):**

1. **Phase A — 2.0 API design freeze** (softarch dispatch, single agent). Publishes `libpdx-semantic-pipe/design/v2-api.md`. Reviews required by uxdes + comparch.
2. **Phase B — 2.0 library landing** (1 agent, 2–3 M-milestones inside libpdx-semantic-pipe). Cuts `v2.0.0-rc1`.
3. **Phase C — kernel-side ABI update** (1 agent, monorepo). New `KIND_IPC_ENDPOINT` schema slot + audit shape.
4. **Phase D — satellite adoption** (17 agents in parallel, one per consumer): postui, shell, ls, cat, doc, mv, cp, rm, mkfs.pdxfs, mount.pdxfs, umount.pdxfs, pkg, pdxcurl, pdxdig, pdxping, pdxsock, pdxtrust. Each agent owns one repo, touches only that repo's pipe-facing files. File-disjoint by construction. Each cuts a `v1.x.0` release with the 2.0 pipe API adopted.
5. **Phase E — libpdx-semantic-pipe v2.0.0 signed release** (1 agent). Umbrella closes.

**Estimated R110-XREPO wall-clock:** ~5 workdays with the full 17-agent parallel Phase D dispatch.

### 9.3 Retired POSIX-shape cascades (not on this plan)

The plan deliberately does not include:
- A "port GNU coreutils" cascade. Coreutils are already cap-native reimplementations; no port work exists.
- A "systemd equivalent" cascade. The elevate broker + kernel-side supervisor already fill this role.
- A "libc port" cascade. Every satellite links `paideia-satellite-runtime.a` (v0.29.2) directly.

---

## 10. Coordination surface / MECE invariants

The invariants below define what "MECE" means operationally for this plan. Any wave violating one of them regresses to a serialization checkpoint.

### 10.1 Design-doc single authority

Every design document lives in exactly one repo. Cross-references are read-only. Cross-repo design work that requires touching two design docs is a serialization point (only one agent at a time). Named authorities:

- **Kernel + capability architecture:** `paideia-os` monorepo `design/kernel/**` and `design/architecture/**`.
- **Wire ABIs (compositor, IPC, audit records):** `paideia-os` monorepo `design/graphics/**`, `design/ipc/**`, `design/audit/**` (Q-SVC-1 pattern generalizes).
- **Compiler + intrinsics:** `paideia-as` repo `design/**`.
- **Per-satellite architecture:** each satellite's `design/**`.

**Q-SVC-1 concrete implementation:** `design/graphics/r102-wire-abi.md` created as a Wave-0 chore (agent W0-25) in the monorepo. svc-compositor M1 (W0-07) and svc-wm M1 (W0-08) both read it read-only; neither may propose byte-layout changes without a monorepo PR first.

### 10.2 Cross-repo cap-kind allocation

New `KIND_*` slots are allocated in the monorepo before any satellite work references them. R29 slot-14 `KIND_HW` allocation (Wave 0, agent W0-23) is the archetype. Every subsequent `KIND_*` filed in a next-wave issue body carries a canonical numeric slot assignment from the monorepo allocation table.

### 10.3 Version bump + submodule bump serialization

- Every paideia-as workspace-version bump is a session serialization point. Two paideia-as agents may not concurrently propose a version bump.
- Every submodule bump in a satellite is a session serialization point for that satellite. Multiple satellites may bump concurrently, but only one PR per satellite at a time.
- The `paideia-as v0.28.1 last-pushed-tag / v0.29.2 HEAD` gap (per ECOSYSTEM_STATUS.md) is the current standing example: no tag has been pushed for the three in-session bumps yet. R91-XREPO.M1 close will push the tag; Wave-0 agents that need v0.29.x pin against the commit hash, not the tag.

### 10.4 Build serialization

`bash tools/build.sh` is main-only per session discipline (per `feedback_no_background_builds.md`). Sub-agents produce diffs; main executes builds. So ~30 parallel Wave-0 agents produce ~30 parallel diffs; main builds them serially at ~5 min each; total wall-clock is **~150 min for full Wave-0 verification** if all pass. Failures reroute back to their originating agent as debugger dispatches (per §11).

`bash tools/run-smoke.sh` is likewise main-only. Wave-3 releases share the smoke harness; hence Wave-3 concurrency drops to ~20–30 agents.

### 10.5 File-disjoint dispatch invariant

No two agents in the same wave touch the same file. Every dispatch table row above declares its file-touch set explicitly. The wave-orchestration coordinator (a general-purpose agent, dispatched by main once per wave) verifies file-disjointness before dispatching; a conflict blocks the plan until the file-touch set is re-partitioned.

---

## 11. Debugger discipline (session-standing)

Per `feedback_debugger_every_iteration.md` and `feedback_paideia_os_loop_shape.md`:

**softarch → build → debugger — EVERY iteration.** Applies to every agent in every wave. Green build is not verification. A softarch dispatch's exit condition is:

1. softarch produces a diff.
2. main runs `bash tools/build.sh`. On clean build, proceed. On failure, re-dispatch softarch with the error tail.
3. debugger runs — adversarially verifies the diff addresses the issue body, that the debugger's own reproduction path exercises the changed code, and that no silent regression landed in adjacent code.
4. On debugger clean-pass, main commits + pushes. On debugger flag, re-dispatch softarch with the debugger report.

The debugger runs even when the build was clean on first try; a clean build does not skip the debugger. Wave 0–3 estimates in §5–§8 assume ~2 debugger passes per softarch (one clean, one requiring a fix). Waves budget accordingly.

---

## 12. Confirmation checkpoints

The plan runs against explicit user confirmations:

- **CP-0 — Plan freeze.** After MASTER_PLAN.md is written and pushed: **USER CONFIRMS** by issuing `EXECUTE MASTER_PLAN`. Nothing runs before this.
- **CP-1 — Phase A script draft.** After `tools/gh-bootstrap-next-wave-issues.sh` + `.plans/next-wave-issues.tsv` are drafted: user reviews the manifest (a diff of `.plans/next-wave-issues.tsv` — 609 rows). On approval, main runs the script; ~1 workday of scripted filing.
- **CP-2 — Wave 0 dispatch.** After Phase A close (all 609 issues filed): main dispatches Wave 0 immediately per §5, no additional checkpoint. Executes continuously per `feedback_paideia_os_tempo.md`.
- **CP-3 — Wave 3 (R100 + R102 M5).** After Wave 3 M5s land for the R100 network-tools wave + R102 GUI-apps wave: user reviews R110-XREPO cascade shape (§9.2). On approval, main dispatches R110-XREPO Phase A. This is the second and final user checkpoint before the plan reaches its termination condition.
- **CP-4 — Plan termination.** All success criteria in §15 met. User confirms plan closure; a wave-close retrospective doc lands under `design/round-retrospectives/master-plan-2026H2-closed.md`.

---

## 13. Retirement + escalation notices

### 13.1 Retirement — `fetch` and `ping`

Per ECOSYSTEM_STATUS.md §Notes: `fetch` (R63-era HTTP GET) is superseded by `pdxcurl`; `ping` (R80-era ICMP) is superseded by `pdxping`. Both retire on the same schedule:

- **Retention window:** through R100 M5 landing (Wave 3). Rationale: retention gives external observers time to migrate to the successor tool.
- **Retirement issues filed in Phase A:** `fetch#RETIRE` and `ping#RETIRE`, each closing with an archive-follow-up: repo marked archived, README updated to redirect to the successor, tag `v0.9-archived` pushed.
- **Wave-3 dispatch:** two agents (one per repo) file the retirement notice + archive dispatch. ~1 hour work per repo.

### 13.2 Silent-security gaps in `rm` (#19/#20/#21)

Three issues in `rm` around silent-drop-on-cap-denied, silent-partial-recursion, and silent-audit-elision. These are Wave-0 P0 priorities (agent W0-26 handles the kernel-side audit-record schema addition; a Wave-1 companion agent lands the corresponding `rm` fix).

Bodies land in `.plans/next-wave-bodies/rm-19.md`, `rm-20.md`, `rm-21.md` at Phase A.

### 13.3 paideia-as untracked debt (Q-A-3, three items)

Filed as three separate issues in `paideia-as`, Wave 0 (agent W0-27):

1. **Item 1 (name TBD by audit):** ~1 issue.
2. **Item 2:** ~1 issue.
3. **Item 3:** ~1 issue.

The three items' concrete names come from Q-A-3 (Batch B–H question). If the user resolves Q-A-3 before Phase A script runs, this section is refined; otherwise the plan reserves three placeholder issues in `.plans/next-wave-issues.tsv` and the specifics land when Q-A-3 does.

### 13.4 Q-A-2 crypto-intrinsic-registration audit (10 min, pre-Wave-0)

Per locked decision (Q-A-2 = C): first action after user confirms MASTER_PLAN is a 10-minute source audit of paideia-as crypto intrinsic-registration surface. Two outcomes possible:

- **Shared surface (files under `crates/paideia-as-crypto/src/registration.rs` or equivalent are touched by both v0.33 M1 and R91-XREPO Phase A):** file a Wave-0 predecessor refactor issue in paideia-as; W0-22 waits on that refactor; ~1 day slip.
- **Disjoint surface:** dispatch W0-22 in parallel from Wave 0 day 1.

This audit is the very first thing the plan runs. Its output determines Wave-0 layout for W0-22 only.

---

## 14. Deferred (Batch B–H) question dependencies

Mapping each deferred question to the wave by which it must be answered. Every question that gates a wave beyond its deferred position blocks that wave until answered.

| Question             | Blocks                                     | Deadline           | Action if unresolved                              |
| -------------------- | ------------------------------------------ | ------------------ | ------------------------------------------------- |
| Q-A-3                | paideia-as untracked-debt issue filing     | Phase A script run | File placeholder issues; refine on resolution.    |
| Q-PT-1 (pdxtrust `/system/trust` path) | R100.M3 pdxtrust real-body (Wave-2) | Wave-2 dispatch | Block agent W2-05 (`pdxtrust` M3) until answered. |
| Q-COMP-1..N (compositor protocol shape) | G7 M1 draft (Wave-2)          | Wave-2 dispatch | Block agent W2-42 (`G7.M1` protocol draft) until answered. |
| Q-BLOB-1..3 (blob-driver policy details) | R38 M1 (Wi-Fi kick), R40 M1 (camera kick) | Wave-2 dispatch for R38 | Block R38+R40 M1 until answered; already resolved in principle by D1.a/b/c in synthesis doc §10, but per-primitive detail may recur. |
| Q-HW-VMD             | R47 milestone opening                     | Wave-3+ (VMD is post-G-series) | Deferred safely; not a Wave 0–3 gate.       |
| Q-A11Y-1..3 (a11y tree binding shape) | G10 M1 (Wave-2)                | Wave-2 dispatch | Block agent W2-45 (`G10.M1`) until answered.       |
| Q-IME-1..2 (IME session shape)     | G11 M1 (Wave-2)                    | Wave-2 dispatch | Block agent W2-46 (`G11.M1`) until answered.       |
| Q-COLOR-1..2 (HDR + ICC v4 particulars) | G6 M1 (Wave-2)               | Wave-2 dispatch | Block agent W2-44 (`G6.M1`) until answered.        |
| Q-TB-1..2 (TB4 security-level + DMA-consent UX) | R35 M1 (Wave-2)     | Wave-2 dispatch | Block R35 M1 until answered; blob-policy overlap. |
| Q-FIRM-1 (per-vendor firmware distribution license) | R38+R40 M-final | Wave-3            | Block release cut; can be worked around by dropping IPU6.  |
| Q-CONF-1 (TDX slot-15 base kind)   | Post-G-series                     | Not a Wave 0–3 gate | Deferred safely; slot 15 is pre-reserved.   |

The user asks each of these at its deadline; MASTER_PLAN.md is the reference for when each is due.

---

## 15. Success criteria + termination

The plan is considered **landed** when all six conditions hold:

1. **All 609 issues filed** (581 next-wave + 5 v0.33 + 15 R106 + 5 misc + 3 paideia-as debt) — verified by `wc -l .plans/next-wave-issue-map.tsv`.
2. **Wave 0–3 executed** — every dispatch in §5–§8 landed OR explicitly rolled forward with a follow-up issue.
3. **R106–R109 cascade closed** — `r109-closed` tag pushed on the monorepo; per `persistent-home-wave.md` §Round-close checklist.
4. **R110-XREPO cascade executed** — libpdx-semantic-pipe v2.0.0 signed release cut; 17 downstream consumers cut v1.x.0 releases with the 2.0 API.
5. **Retirement notices closed** — `fetch` and `ping` archived; their retirement issues closed with `v0.9-archived` tags.
6. **Wave-close retrospective doc landed** — `design/round-retrospectives/master-plan-2026H2-closed.md` (per CP-4).

**Estimated wall-clock:** 6–8 weeks at current tempo. Breakdown:
- Phase A filing: 1 workday.
- Wave 0: ~1 week (30 agents × 4 hours parallel + 150 min serialized build + 30 debugger passes).
- Wave 1: ~1.5 weeks (40 agents × 5 hours + 200 min build + 40 debugger).
- Wave 2: ~2 weeks (50 agents × 6 hours + 250 min build + 50 debugger).
- Wave 3: ~1.5 weeks (25 agents × 8 hours + 400 min build + smoke).
- R110-XREPO cascade: ~1 week (17 agents parallel Phase D + serialized Phases A, B, C, E).
- R106–R109 landing: ~1 week (interleaved with Wave 2–3).
- Retirements + closure: ~2 days.

Total: **~7 weeks** median; 6 weeks best-case with no re-dispatches; 8 weeks worst-case with two Q-COMP-*/Q-COLOR-* wait-on-user checkpoints.

**Termination signal:** all six success criteria hold; `EXECUTE MASTER_PLAN` is retired; the next `AISSUE` / `ECOTABLE` / roadmap trigger opens the next wave-plan iteration (likely the "beyond G12" plan targeting a self-hosting daily-driver milestone).

---

*End of MASTER_PLAN. This document is the sole authority for the 2026H2 breadth-first execution wave; every wave-scoped design doc and issue body must cite this plan by section. Companion docs: `design/roadmap/next-wave-synthesis.md`, `design/roadmap/persistent-home-wave.md`, `ECOSYSTEM_STATUS.md`, `design/library-status.md`.*
