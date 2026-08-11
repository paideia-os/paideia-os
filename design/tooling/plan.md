# PaideiaOS Tooling Ecosystem — Post-R47 Plan

**Status:** approved (2026-08-11 user disambiguation across four scoping questions)
**Depends on:** R47 closure (driver substrate through r47-vmd-driver, semantic-terminal fb+gui at R41/R44, PdxFS v1 at R42, GPU-native GUI G1–G12).
**Scope:** ~95 user-facing tools, each in its own repository under the `paideia-os` GitHub organization.
**Owner:** paideia-os-team, MIT license across the entire ecosystem (per `project_license_and_extensions`).

---

## 0. Reading order

- §1 executive summary
- §2 baseline assumptions (what is standing when tooling begins)
- §3 five load-bearing design decisions (D1–D5), each traceable to a specific user disambiguation
- §4 cross-tool invariants (the levers that address whole categories of historical pain)
- §5 tool catalogue — the ~95 tools, organized by category, one repo per tool
- §6 the package manager `pkg` — the first tool built, spec
- §7 shared cross-tool libraries
- §8 first-slice ordering (which tools ship first, by dependency)
- §9 repository convention (template, CI-equivalent, signing pipeline)
- §10 filing plan — the issues to open in paideia-os to track this work
- §11 open questions for later (deliberately deferred)

---

## 1. Executive summary

The PaideiaOS user story past R47 is: user boots into a semantic terminal running as either an fb-console (R41) or a GPU-native application (R44). They need a coherent set of everyday tools — filesystem operations, sysadmin, editors, communication, productivity. Rather than port GNU coreutils / BSD userland / Linux ecosystem wholesale, we author a fresh set from scratch, leveraging four properties nothing else has:

1. **Semantic pipes** — every tool emits both text and typed schemas + capabilities.
2. **Linear capabilities** — every tool declares which caps it consumes; the runtime enforces.
3. **PdxFS v1 snapshots** — destructive operations are journaled and reversible.
4. **A single coherent windowing/protocol/toolkit stack** (PWP + `libpaideia-ui`) — GUI variants of any tool are cheap.

The plan calls for **Tier 3** breadth (~95 tools), spanning coreutils, sysadmin, comms, productivity, and a small set of Paideia-native new tools. Each tool lives in its own repository under `github.com/paideia-os/<name>`. Install is via a signed package manager `pkg` with a source-fallback path. Every tool honors a fixed set of cross-tool invariants (§4) that eliminate whole categories of historical pain.

The first-slice (P0) — 12 tools including `pkg` itself, the coreutils bootstrap, and a primitive editor — is the minimal set that lets a new user be productive from a fresh install. Everything after P0 fills in categories on a demand-driven order.

---

## 2. Baseline assumptions (post-R47)

By the time tool authoring begins, the following are landed and stable:

- **R23** framebuffer + text console + ANSI SGR + panic-to-fb. **Color TUI is viable.**
- **R25** PdxFS-lite; **R42** PdxFS v1 (CoW walker + journal + snapshot). **Undoable destructive ops are viable.**
- **R26** xHCI HID keyboard + touchpad. Input works.
- **R27** e1000e Ethernet + ARP + IPv4 + ICMP + UDP + KIND_UDP_SOCKET. Basic networking works. TCP arrives in an interim round; assume by the time comms tools (mail, IRC) ship, TCP + TLS are landed.
- **R29–R40** — full T14 G4 driver coverage (Wi-Fi, BT, audio, cameras, TB4, GPU execution).
- **R41** `semantic-terminal-fb` — the fb-console frontend of the semantic terminal.
- **R44** `semantic-terminal-gui` — the GPU-accelerated GUI frontend.
- **R47** `r47-vmd-driver` — final driver hardening.
- **G1–G12** GUI stack: display sync, direct-scanout, Vulkan surface, Vello 2D, SDF text, color/HDR, PWP compositor protocol, input routing, windowing, a11y, IME, `libpaideia-ui` toolkit.
- **paideia-as v0.32** — a11y + IME + toolkit substrate; the language + stdlib is by then mature (closures, hash-tables, Option/Result, string/str, pattern guards, or-patterns, bind-and-match, records, session functors, @atomic, @interrupt).
- **`semantic-term-core`** library — shared by R41 and R44 frontends: command lexer, semantic query engine, plot compositor. **Every tool consumes this library, not the terminal frontends directly.**
- **ML-DSA-65 root key from R32** — the signing infrastructure for both firmware blobs (D1.a) and tool packages (this plan's D3).

---

## 3. Design decisions

Each decision below carries a **D-code** for cross-referencing from tool-specific issues.

### D1 — Tool scope: Tier 3 (~95 tools) [user-selected 2026-08-11]

Coreutils + sysadmin daily + comms + productivity. Enough for a solo user to run their daily workflow without external systems. Explicitly excluded from this plan (deferred to a Tier-4 successor plan): image viewer, PDF reader, IDE-analog, git-analog, containerization, spreadsheet, presentation, media player.

**Rationale for stopping at Tier 3:** a self-hosting dev workstation (Tier 4) requires the language to be self-hosting first (paideia-as `#1027` audit landed as v0.20; higher-level Paideia dialect is post-plan). Comms + productivity are self-contained. Media/PDF/IDE benefit from a language + toolkit maturity that the first year after R47 won't yet have.

### D2 — Composition: semantic-first, text-fallback [user-selected 2026-08-11]

Every tool emits three concurrent stream layers on stdout:

- **Rendered text** — for interactive readers and grep-like consumers.
- **Typed schema stream** — a sequence of records typed against a declared schema (`schema ls_out { entries: [FileEntry], total: u64 }`); consumers that understand schemas use them directly.
- **Capability list** — the caps this tool holds and is willing to pass forward on request. A downstream tool that needs `KIND_PDXFS` can accept it from the pipe instead of re-minting.

Concretely:

```
$ ls /home                                     # rendered text
drwx------  snunez  4096  2026-08-11 12:34  .config
-rw-r--r--  snunez  1428  2026-08-11 09:12  notes.md

$ ls /home | select size > 1024 | table        # schema pipe
╔══════════╤════════╤══════╤═══════╗
║ name     │ owner  │ size │ mtime ║
║ notes.md │ snunez │ 1428 │ 09:12 ║
╚══════════╧════════╧══════╧═══════╝

$ ls /home | grep '\.md$'                      # text-fallback still works
notes.md
```

The wire format for the pipe (`semantic-term-core` handles it) carries all three layers; a text-only consumer ignores the schema, a schema-aware consumer ignores the text (or uses it as a display hint).

### D3 — Naming + flag grammar: familiar names, fresh flags [user-selected 2026-08-11]

**Names.** POSIX names for the ~40 core cases where muscle memory is deep: `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir`, `grep`, `find`, `sort`, `uniq`, `wc`, `head`, `tail`, `less`, `tar`, `ssh`, `scp`, `curl`, `ping`, `mail`, etc. Fresh names for tools without a canonical POSIX ancestor.

**Flags.**

- Every flag has a **long form** as its primary (`--long`, `--all`, `--recursive`, `--ignore-case`).
- Short forms are structural — one flag per hyphen (`-l -a -s`), never clustered (`-las` → error with suggestion).
- Typed flag arguments: `--older-than 7d`, `--size > 1MB`, `--after 2026-01-01`, `--context 3`.
- No cryptic single-letter chains inherited from `ps aux` / `tar xzvf` / `find -mtime -7`.

**Behavior.** POSIX behavior is a *starting point*, not a contract. Where POSIX has a wart (grep's `-r` scanning symlinks by default, sed's differing `-i` between GNU/BSD, tar's silent overwrite), we correct it. Every correction is documented in the tool's `--differences-from-posix` help section.

### D4 — Install model: signed binary packages + source fallback [user-selected 2026-08-11]

Every tool ships as a **package** consisting of:
- The built binary (elaborated `.pdx` → ELF-like Paideia format).
- A `manifest.pdxsig` file signed with ML-DSA-65 by two keys (dual signature per D1.a of the driver blob-policy analog):
  - The tool author's key (`author_pk`).
  - The Paideia manifest re-sign key (`paideia_root_pk` from R32).
- A `caps.decl` file declaring exactly which capabilities the tool requests at exec time.
- A `deps.list` file listing shared-library dependencies (§7).

Install:

```
$ pkg install ls
resolved:  ls-1.2.3 (paideia-os/main)
verified:  author=paideia-os-team (ML-DSA-65)
verified:  paideia-manifest (ML-DSA-65 root)
cap-audit: [KIND_PDXFS(read), KIND_TTY(write)]
installed: /pkgs/ls-1.2.3 → /bin/ls
```

Source fallback path (trust-zero):

```
$ pkg install --from-source ls
cloned:    github.com/paideia-os/ls
built:     42 .pdx files → ls-1.2.3-local (paideia-as v0.32)
cap-audit: [KIND_PDXFS(read), KIND_TTY(write)]
installed: /pkgs/ls-1.2.3-local → /bin/ls
```

`--from-source` requires the paideia-as toolchain on the machine (installed by `pkg install paideia-as`, itself dogfooded). The from-source path bypasses author-sig verification (the user built it themselves) but STILL verifies that the source-tree root matches an author-signed commit unless `--trust-my-own-hash` is passed.

### D5 — Ergonomics as a first-class design pillar [user-added 2026-08-11]

Ergonomics is not a checkbox; it is a design pillar equal to correctness, security, and performance. Every tool proposal (a repo's initial `design.md`) must have a section titled "Ergonomics" describing:

- The 5 most common user tasks the tool serves.
- The keystroke/gesture cost of each.
- The failure modes the user is protected from (typos, wrong path, missing cap).
- The recovery path from each failure.

This section is a PR requirement before the tool's first release; missing it blocks the P0 tag.

---

## 4. Cross-tool invariants

The following invariants apply to EVERY tool in the plan. Any tool that violates one is a bug, tracked in the tool's own repo. The invariants split into "cheap" (implementation is a shared library) and "costly" (requires per-tool design work).

### 4.1 Cheap invariants (included by default; live in shared libraries)

**I1 — One regex flavor everywhere.** RE2-family (linearity-guaranteed, no catastrophic backtracking, no PCRE lookaround). The `pdx-regex` shared library is the single dependency for every tool that takes a pattern (grep, find, rewrite, mail-filter, etc.). No BRE, no ERE, no Perl dialect anywhere in the ecosystem.

**I2 — One time/date input format everywhere.** The `pdx-time` shared library exposes a single parser accepting:
- ISO-8601 absolute: `2026-08-11T14:30:00-04:00`.
- Relative English: `1 hour ago`, `next monday`, `3d`, `+2h30m`.
- Nothing else. Ambiguous forms like `Aug 11 2:30` are rejected with a suggestion.

Every tool that accepts or displays time uses this library. No tool invents its own date parser.

**I3 — Standard flag vocabulary.** Every tool implements the following long flags with identical semantics:

| Flag | Meaning |
|------|---------|
| `--help` | Structured help, paginated, hyperlinked into `doc <tool>` |
| `--version` | Semver + build hash + signing key fingerprint |
| `--dry-run` | Preview the effect without executing side-effects |
| `--json` | Emit the schema stream as JSON on stdout, suppressing text |
| `--schema` | Print the tool's output schema definition and exit |
| `--verbose` | Additional diagnostic output on stderr |
| `--quiet` | Suppress non-error stderr |
| `--color=<auto\|always\|never>` | Color emission policy; `auto` respects the tty and NO_COLOR |
| `--no-cap:<name>` | Strip the named capability before exec (see I7 below) |

A tool that doesn't implement all nine is a bug. The `pdx-flags` shared library implements the parser for all nine automatically; a tool adds its own flags on top.

**I4 — Never silent failures.** Every no-op prints a diagnostic on stderr:

```
$ grep 'nothing-here' empty.txt
grep: 0 matches in 1 file (empty.txt is 0 bytes)
$ echo $?
1
```

Exit codes are documented per-tool but obey the shared convention:

| Code | Meaning |
|------|---------|
| 0 | Success (side effects applied, or query matched) |
| 1 | Query returned nothing (grep found no matches; find found no files) |
| 2 | User error (bad flag, malformed input, unknown subcommand) |
| 3 | System error (I/O failure, out of memory, kernel refused) |
| 4 | Capability denied (asked for cap not held, or `--no-cap` stripped it) |
| 5 | Signing/verification failure (package, blob, script) |

### 4.2 Costly invariants (user-approved 2026-08-11 — mandatory per-tool work)

**I5 — Every destructive op is undoable.** `rm`, `mv`, `cp` (over-existing), `pack` (extract-over-existing), `rewrite -i`, `edit`'s save-over — all journal to a per-user snapshot on PdxFS v1 before executing. The `undo` tool (§5.E) reverses the last N operations within a configurable time window (default 24 hours; user can shrink or extend per session).

**Design cost:** every write path in every tool takes a journaled-write wrapper from the `pdx-journal` shared library. The wrapper is transparent to the tool but requires that every write goes through it (raw `sys_write` is discouraged in user tools — auditable but flagged).

**Coupling:** hard dependency on R42 (PdxFS v1 snapshots). Tools shipped before R42 cannot claim I5 — they ship as `I5-pending` and get the invariant retrofitted post-R42. First tools are expected to ship after R42 anyway.

**I6 — Capability handoff visible + refusable.** Every tool at startup prints the caps it will consume to stderr (unless `--quiet`):

```
$ ls /root
ls: caps requested: KIND_PDXFS(read, /root subtree), KIND_TTY(write)
ls: caps granted (audit-id: 4823-a1b7)
[output]
```

The user can strip caps at invocation:

```
$ ls --no-cap:KIND_PDXFS /root
ls: caps requested: KIND_PDXFS(read, /root subtree), KIND_TTY(write)
ls: cap stripped by user: KIND_PDXFS
ls: exit 4 — capability denied for /root read
```

**Design cost:** every tool declares its cap manifest in a `caps.decl` file at repo root; the runtime enforces the manifest at exec. The manifest is signed alongside the binary (see D4).

**I7 — Help + tutorial + example-gallery required per tool.** Every shipping tool has:

1. **`--help`** — structured, paginated, hyperlinked. Emitted via the `pdx-help` shared library; tools declare help topics in a `help.pdx` file.
2. **`doc <tool>`** — the man-equivalent. Longer prose, cross-references, historical context ("this replaces POSIX `<x>`; the differences are…"). Emitted via the `doc` tool (a first-slice P0 tool itself).
3. **`<tool> --tutorial`** — an interactive walkthrough. Guided by prompts, the user does the 5 most common tasks (from the tool's Ergonomics section per D5). ~5 minutes of user time.
4. **`<tool> --examples`** — a gallery of ~10–20 concrete example invocations with expected output. Copy-pasteable.

**All four exist, or the tool doesn't ship.** No exceptions. First-slice tools take an extra day of doc time each; ecosystem-wide this eliminates the class of pain best exemplified by the vim-exit joke.

---

## 5. Tool catalogue (~95 tools, one repo per tool)

Each tool lives at `github.com/paideia-os/<repo-name>`. The `repo-name` matches the invocation name (`ls`, `grep`, `pkg`) or a short descriptive name for fresh tools (`caps`, `undo`, `provenance`). All MIT licensed.

The catalogue is organized into six categories A–F. Priority (P0/P1/P2) governs first-slice ordering (§8).

### Category A — Filesystem + core utilities (25 tools)

| Repo | Purpose | Priority | POSIX ancestor |
|------|---------|----------|----------------|
| `pkg` | Package manager (§6) | P0 | apt/pacman/brew |
| `ls` | List directory | P0 | ls |
| `cat` | Concatenate + print | P0 | cat |
| `cp` | Copy | P0 | cp |
| `mv` | Move / rename | P0 | mv |
| `rm` | Remove | P0 | rm |
| `mkdir` | Make directory | P0 | mkdir |
| `rmdir` | Remove empty directory | P1 | rmdir |
| `ln` | Symlink / hardlink | P1 | ln |
| `touch` | Update mtime / create empty | P1 | touch |
| `perms` | Read/set file caps (chmod/chown-analog, cap-aware) | P1 | chmod+chown+setfacl |
| `find` | Locate files by attribute (typed queries) | P0 | find |
| `locate` | Fast pre-indexed search | P2 | locate |
| `tree` | Recursive tree display | P2 | tree |
| `grep` | Text search | P0 | grep |
| `sort` | Sort lines / schema records | P1 | sort |
| `uniq` | Deduplicate | P1 | uniq |
| `head` | First N | P1 | head |
| `tail` | Last N, follow | P1 | tail |
| `wc` | Word/line/char count | P1 | wc |
| `cut` | Column extract | P2 | cut |
| `tr` | Character translation | P2 | tr |
| `less` | Paginated reader | P0 | less |
| `tee` | Split pipe | P2 | tee |
| `pack` | Archive + compress (tar+xz analog, one tool) | P1 | tar |

### Category B — Sysadmin (25 tools)

| Repo | Purpose | Priority | POSIX ancestor |
|------|---------|----------|----------------|
| `ps` | Process list | P0 | ps |
| `live` | Real-time process display (top-analog, GPU-aware) | P1 | top/htop |
| `kill` | Signal process | P0 | kill/pkill |
| `mount` | Mount filesystems (KIND_PDXFS-aware) | P1 | mount |
| `df` | Free-space report | P1 | df |
| `du` | Space-used report | P2 | du |
| `sysmsg` | Kernel log viewer (dmesg-analog) | P1 | dmesg |
| `journal` | Structured event log (journalctl-analog, schema-native) | P1 | journalctl |
| `svc` | Service manager (systemctl-analog, capability-aware) | P1 | systemctl |
| `disk` | Partition + physical-disk inspector | P2 | fdisk |
| `fmt` | Format PdxFS partition | P2 | mkfs |
| `remote` | Secure remote shell (ssh-analog, ML-KEM key exchange) | P1 | ssh |
| `rcopy` | Copy over secure remote (scp-analog) | P1 | scp |
| `net` | Network state (interfaces, routes, sockets, netstat-analog) | P1 | netstat/ss |
| `ping` | ICMP echo | P1 | ping |
| `fetch` | HTTP GET/POST (curl-analog, streaming + schema-out) | P1 | curl |
| `get` | Recursive download (wget-analog) | P2 | wget |
| `fw` | Firewall rules (iptables-analog, cap-integrated) | P2 | iptables/nftables |
| `ipcfg` | Interface config | P2 | ip |
| `user` | User admin | P1 | useradd/usermod |
| `group` | Group admin | P2 | groupadd |
| `pass` | Password / key admin | P1 | passwd |
| `date` | Print / set date | P1 | date |
| `cal` | Calendar display | P2 | cal |
| `reboot` | Shutdown / reboot wrapper | P1 | reboot |

### Category C — Text processing + editors (10 tools)

| Repo | Purpose | Priority | POSIX ancestor |
|------|---------|----------|----------------|
| `edit` | Primary TUI editor (modeless, syntax-aware) | P0 | nano/vim/emacs |
| `line` | Line editor (scriptable, `ed`-analog) | P2 | ed |
| `stream` | Stream language (awk-analog, typed) | P2 | awk |
| `rewrite` | In-place text rewriter (sed-analog, RE2-only) | P2 | sed |
| `diff` | Text/schema diff | P1 | diff |
| `patch` | Apply diff | P1 | patch |
| `render` | Markdown/AsciiDoc → rendered text | P2 | pandoc (partial) |
| `fold` | Line wrap | P2 | fold |
| `expand` | Tab / rune expansion | P2 | expand |
| `iconv` | Text-encoding converter | P2 | iconv |

### Category D — Comms + productivity (25 tools)

| Repo | Purpose | Priority | POSIX ancestor |
|------|---------|----------|----------------|
| `mail` | Local + IMAP/SMTP mail client, TUI | P1 | mutt |
| `irc` | IRC client, TLS | P2 | irssi/weechat |
| `matrix` | Matrix client | P2 | none common |
| `chat` | Local IPC chat (between users on the same machine) | P2 | wall/write |
| `calc` | Calculator (RPN + infix + symbolic) | P1 | bc/dc |
| `note` | Note-taking (per-user, tag-indexed, PdxFS-backed) | P1 | none common |
| `agenda` | Calendar viewer + editor (ICS-compatible) | P1 | ical/khal |
| `task` | Task tracker (Kanban-style, TUI) | P1 | taskwarrior |
| `timer` | Countdown / stopwatch | P2 | none |
| `alarm` | Alarm scheduler | P2 | none |
| `pomo` | Pomodoro session manager | P2 | none |
| `dict` | Local dictionary + thesaurus | P2 | dict |
| `unit` | Unit converter | P2 | units |
| `weather` | Weather fetch (NOAA-style feed) | P2 | none common |
| `feed` | RSS/Atom reader | P2 | newsboat |
| `todo` | Simple todo list (separate from `task`; single-line focus) | P2 | todo.txt |
| `clip` | Clipboard manager (multi-buffer, cap-aware) | P1 | xclip/wl-clipboard |
| `vault` | Password + key manager (ML-DSA-signed store) | P1 | pass |
| `web` | Minimal HTTP text browser (schema-aware for Paideia-served pages) | P2 | lynx/w3m |
| `mux` | Terminal multiplexer (session persistence, splits) | P1 | tmux/screen |
| `shell` | The command shell itself (successor to R17 shell, schema-native) | P0 | bash/zsh |
| `history` | Cross-session command history + query | P1 | history |
| `bookmark` | Bookmark manager (URLs, files, cap-refs) | P2 | none common |
| `pastebin` | Local snippet store (paste + retrieve) | P2 | none common |
| `snapshot` | Take/list PdxFS snapshots (user-facing wrapper on the FS primitive) | P1 | zfs snapshot |

### Category E — Paideia-native new tools (10 tools)

These tools have no direct POSIX ancestor. They exist because Paideia's semantic + capability + snapshot substrate makes them possible.

| Repo | Purpose | Priority |
|------|---------|----------|
| `caps` | Inspect / audit capability state of a process, file, pipe, self | P0 |
| `undo` | Reverse the last N destructive operations (I5) | P0 |
| `provenance` | Trace how a file's contents came to be (what tool produced them, from what inputs) | P1 |
| `query` | SQL-like over structured streams (`ls /home \| query "size > 1024 order by mtime desc"`) | P1 |
| `schema` | Schema definition, validation, evolution tool | P1 |
| `journal-x` | Interactive audit-log explorer | P1 |
| `doc` | Interactive documentation reader (I7 §2) | P0 |
| `tutor` | Tutorial launcher (I7 §3) | P0 |
| `gallery` | Example-gallery browser (I7 §4) | P0 |
| `pipeviz` | Visualize pipeline topology + schema at each stage (`ls \| grep foo \| sort` → boxed diagram) | P1 |

### Category F — Bootstrap + shared (all P0)

The four tools that must exist before any other tool can be built or installed:

| Repo | Purpose |
|------|---------|
| `pkg` | Package manager (also in Category A, listed here for the P0 role) |
| `paideia-as` | The elaborator/assembler (already exists as the toolchain, packaged for user install) |
| `shell` | The command shell (already in Category D, P0) |
| `doc` | Documentation reader (also in Category E, P0) |

**Total: 25 + 25 + 10 + 25 + 10 = 95 tools, one repo each.**

---

## 6. Package manager `pkg` — first-tool spec

`pkg` is the tool that installs every other tool. It is built first, from source, once, and thereafter installs itself.

### 6.1 Subcommands

| Subcommand | Purpose |
|------------|---------|
| `pkg install <name>[@<version>]` | Install (default: latest signed) |
| `pkg install --from-source <name>` | Clone + build + install |
| `pkg remove <name>` | Uninstall (journals to undo per I5) |
| `pkg upgrade [<name>]` | Upgrade one (or all) |
| `pkg list [--installed \| --available]` | List packages |
| `pkg info <name>` | Show metadata + cap manifest + deps |
| `pkg audit` | Verify all installed packages' signatures still validate against known keys |
| `pkg search <pattern>` | Search package repos |
| `pkg repo add <url>` | Add a package repository |
| `pkg repo list` | List trusted repos |
| `pkg keys list` | List trusted signing keys |
| `pkg keys import <keyfile>` | Import a new author key |
| `pkg pin <name>@<version>` | Pin to a specific version |
| `pkg deps <name>` | Show dependency tree |

### 6.2 Trust model

Two-key ML-DSA-65 dual signature (identical policy to D1.a for firmware blobs):

1. Author key (`author_pk`) — per-tool. Author is typically `paideia-os-team` for first-party tools; third parties can register their own author keys.
2. Paideia root key (`paideia_root_pk`) — the R32 root; also re-signs the manifest, providing a second attestation.

`pkg install` rejects any package where either sig fails. `pkg install --from-source` skips author-sig on the built binary (user built it) but still verifies the source-tree root commit against the author key.

### 6.3 Repository model

Package repositories are static file trees served over HTTP(S), containing:
- `index.pdxsig` — a signed manifest of {name, version, hash} tuples.
- `<name>/<version>/pkg.tar` — the package archive.
- `<name>/<version>/manifest.pdxsig` — the dual-signed manifest.

Default repo: `https://pkgs.paideia-os/main/`. Users can add mirror/private repos.

### 6.4 Local layout

```
/pkgs/
  <name>-<version>/
    bin/<binary>
    lib/*.so    (if any shared libs)
    doc/*.pdxdoc
    caps.decl
    manifest.pdxsig
/bin/  → symlinks into /pkgs/<name>-<version>/bin/
/journal/pkg/  → install/remove journal (for I5 undo)
```

### 6.5 Bootstrap

The first-ever install of `pkg` on a fresh PaideiaOS system:

```
$ curl https://paideia-os/bootstrap/pkg-bootstrap.pdx > /tmp/pkg.pdx
$ paideia-as build /tmp/pkg.pdx -o /tmp/pkg
$ /tmp/pkg install pkg          # self-installs signed binary version
$ pkg install shell doc         # rest of P0
```

The bootstrap script and paideia-as toolchain are the two things that must ship in every PaideiaOS install image.

---

## 7. Shared cross-tool libraries

To keep tool binaries small and enforce cross-tool consistency, the following libraries are dependencies for many tools. Each lives in its own repo under `paideia-os` and is installable via `pkg install <libname>`.

| Library | Consumers | Purpose |
|---------|-----------|---------|
| `pdx-regex` | grep, find, rewrite, mail-filter, etc. | RE2-family engine (I1) |
| `pdx-time` | date, agenda, alarm, journal-x, etc. | Time parsing + formatting (I2) |
| `pdx-flags` | every tool | Standard flag parser (I3) |
| `pdx-help` | every tool | `--help` renderer, help.pdx compiler (I7 §1) |
| `pdx-journal` | every writer tool | Journaled-write wrapper (I5) |
| `pdx-caps-decl` | every tool | Cap manifest parser + declaration API (I6) |
| `pdx-schema` | every tool that emits structured output | Schema definition, serialization, validation (D2) |
| `pdx-color` | every tool with color output | TERMCAP-equivalent, ANSI + PWP color-space handling |
| `semantic-term-core` | shell, edit, mail, etc. | Command lexer, semantic query engine, plot compositor (shared with R41/R44 terminals) |
| `pdx-tls` | remote, rcopy, fetch, mail, matrix, irc | TLS 1.3 + ML-KEM key exchange |
| `libpaideia-ui` | GUI variants (post-G12) | The toolkit; TUI variants don't need it |

Every library is dual-signed like tools, versioned semver, and consumed via `deps.list` in each tool's package manifest.

---

## 8. First-slice (P0) ordering

12 tools ship first, in dependency order. Wall-clock target: 3–4 months from R47 close (one small team, one tool per week average).

**Wave 1 — bootstrap (Week 1–3):**
1. `pkg` — self-hosted after week 2
2. `shell` — succeeds R17 shell, adds schema pipes, mux integration
3. `doc` — reads .pdxdoc, needed for every subsequent tool's --help

**Wave 2 — coreutils survival (Week 4–8):**
4. `ls`
5. `cat`
6. `cp`
7. `mv`
8. `rm`
9. `mkdir`

**Wave 3 — filesystem power (Week 9–11):**
10. `grep`
11. `find`
12. `less`

**Wave 4 — Paideia-native introductions (Week 12–14):**
13. `caps`
14. `undo`
15. `tutor`
16. `gallery`

**Wave 5 — editor (Week 15–17):**
17. `edit` — takes 3 weeks because Ergonomics section (D5) demands genuine design work

At Wave-5 close, the system is a productive daily driver for a single-user text workflow. P1 tools (roughly 40 more) follow on a demand-driven order over the following 6–9 months. P2 tools (the remaining ~38) trickle in indefinitely.

---

## 9. Repository convention

### 9.1 Layout

Every tool repository follows the same top-level layout:

```
<toolname>/
  README.md              # 60-second pitch + install command
  LICENSE                # MIT, always
  design.md              # architecture; MUST include an "Ergonomics" section per D5
  caps.decl              # capability manifest (I6)
  deps.list              # shared-library deps (§7)
  help.pdx               # source for --help (compiled by pdx-help)
  tutorial.pdx           # source for --tutorial (I7 §3)
  examples/              # gallery entries (I7 §4)
  src/
    *.pdx                # source
  tests/
    *.pdx                # tests, run by `paideia-as test`
  smoke/
    *.sh                 # smoke scripts (run against a live shell)
  CHANGELOG.md
```

### 9.2 CI-equivalent

Consistent with `feedback_paideia_os_no_cicd`: **no GitHub Actions.** Every tool has a `tools/verify.sh` script; the repo's contributor rule is that `verify.sh` must pass locally before pushing. This runs:
- `paideia-as build src/*.pdx` (compile).
- `paideia-as test tests/*.pdx` (unit tests).
- `bash smoke/*.sh` (smoke).
- `pdx-help lint help.pdx` (help sanity).
- `pdx-caps-decl lint caps.decl` (cap manifest sanity).

### 9.3 Signing pipeline

Release flow:
1. Author tags the repo (`git tag v1.2.3`).
2. Author runs `paideia-as release --sign` — produces `pkg.tar` + author-signed `manifest.pdxsig`.
3. Author pushes to `pkgs.paideia-os` staging.
4. Paideia signing bot re-signs with root key (`paideia_root_pk`); moves to `pkgs.paideia-os/main/`.
5. `pkg install <tool>` on user machines picks it up on next `pkg upgrade` or explicit install.

The signing bot lives on a machine holding the root key; its policy is human-in-the-loop for now (each first-party tool release is manually re-signed after a reviewer confirms the source-tree matches the author's tag).

---

## 10. Filing plan (issues to open in paideia-os for tracking)

The following issues open in `paideia-os/paideia-os` (the meta repo, NOT the individual tool repos which don't exist yet):

**Meta issues (one per tool):** 95 issues titled `T-<name>: create tool repo + P<0|1|2> scaffolding`. Each carries the label `tooling` + `priority:P<0|1|2>` + `category:<A|B|C|D|E|F>`. Body includes: purpose, POSIX ancestor if any, shared-library deps, expected cap manifest, sketch of design.md.

**Infrastructure issues (one-off):**
- `T-INFRA-001: dual-sign package repository infrastructure (pkgs.paideia-os)`
- `T-INFRA-002: signing bot host + policy for paideia_root_pk`
- `T-INFRA-003: `bootstrap/pkg-bootstrap.pdx` bootstrap script — served over HTTPS from paideia-os`
- `T-INFRA-004: create org-wide repo template with §9.1 layout`
- `T-INFRA-005: shared-libraries repository initialization (11 libs from §7)`

**Cross-cutting invariant issues (one per invariant):**
- `T-INV-I1: pdx-regex library — RE2 engine`
- `T-INV-I2: pdx-time library — parser + formatter`
- `T-INV-I3: pdx-flags library — 9-flag vocabulary`
- `T-INV-I4: exit-code + no-silent-failure discipline (design.md; per-tool audit checklist)`
- `T-INV-I5: pdx-journal library — depends on R42 close`
- `T-INV-I6: pdx-caps-decl library + runtime enforcement`
- `T-INV-I7: pdx-help library + doc/tutor/gallery tool trio (already in Category E)`

**First-slice tracking:**
- `T-P0-WAVE-1: pkg + shell + doc trio (bootstrap)`
- `T-P0-WAVE-2: ls/cat/cp/mv/rm/mkdir (coreutils survival)`
- `T-P0-WAVE-3: grep/find/less (filesystem power)`
- `T-P0-WAVE-4: caps/undo/tutor/gallery (Paideia introductions)`
- `T-P0-WAVE-5: edit (primary TUI editor)`

**Total meta-repo issues to file:** 95 tool issues + 5 infra + 7 invariant + 5 P0-wave = **112 issues.**

Filing convention: use the `tooling` label + one of `category:A..F` + `priority:P<0|1|2>` + when relevant `blocks:R42` (for I5-dependent tools) or `blocks:G-series` (for GUI variants). A next-wave milestone `tooling-p0` (16 tools + 5 waves + 5 infra + 7 invariant = 33 tickets) tracks first-slice; `tooling-p1` and `tooling-p2` track the rest.

**These 112 issues are filed AFTER the current next-wave issue-filing agent completes** (bulk-file softarch is currently mid-run, ~611 next-wave issues). Filing tooling issues in parallel would race the same GitHub API quota and confuse label taxonomy.

---

## 11. Deliberately deferred questions

The following will be resolved when the plan is executed, not now:

- **Tier 4 successor plan** — IDE, browser, PDF, media, spreadsheet. Scoped after the language grows a higher-level dialect that makes 100kLoC tools reasonable to author.
- **Third-party author onboarding** — the author-key registration flow. Trivial for first-party (paideia-os-team key exists); needs a policy document when non-Paideia authors publish their first package.
- **Package repo mirror federation** — for large-scale distribution. Current design assumes single main + local mirrors; global CDN pattern is a later concern.
- **Container-per-tool option** — user chose signed-binary+source-fallback over containers-per-tool. If per-tool isolation ever becomes desired (paranoid deployments), containers can be an opt-in wrapper without re-authoring tools.
- **Cross-platform ports** — the assumption is post-R47 tools run only on PaideiaOS. If we ever want them on Linux (unlikely but possible), a portability layer would need retrofit.
- **Tool retirement policy** — how do we deprecate + eventually remove a tool that has been superseded? Semver's MAJOR version is the mechanism; details of a graceful removal window are a later concern.
- **The naming of `stream` vs `awk`, `rewrite` vs `sed`, `pack` vs `tar`** — the fresh names in Category C break the D3 "familiar names" principle. Rationale: `awk` and `sed` are cryptic DSLs whose names are terrible mnemonics; `tar`'s name is a fossil of tape-archive that no one uses anymore. If the P2 owners disagree at implementation time, they can rename back to POSIX names (D3 permits it).

---

**Ready for filing** once the next-wave issue softarch completes. This plan supersedes any speculative tool discussion elsewhere in the design tree; when tool repos are created, each links back here from its README's "Design lineage" line.
