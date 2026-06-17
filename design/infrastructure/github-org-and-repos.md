# PaideiaOS — GitHub Organization and Repository Plan

**Status:** Plan (not yet executed)
**Date:** 2026-06-17
**Scope:** Plan for hosting PaideiaOS source on GitHub, including organization structure, repository count, naming conventions, and timing of creation. **Nothing has been created yet** — this document is the agreed plan; execution awaits explicit user instruction.

**Hard inputs:**
- `design/02-development-environment.md` §6.1 — the monorepo decision is binding.
- `design/02-development-environment.md` §11.1 — external rebuild attestations are part of the release process.
- `design/02-development-environment.md` §10.2 — GitHub Actions for the public face; self-hosted runners for QEMU/bare-metal stages.

---

## 0. Current state (2026-06-17)

- Local working directory: `/home/snunez/Development/PaideiaOS/`
- Already a local git repository (single initial commit on `main` branch)
- Git user: Santiago Núñez-Corrales
- Not yet hosted at any remote.

---

## 1. The monorepo decision (recap)

Per `02-development-environment.md` §6.1, **monorepo** is the binding choice with five justifications:

1. **Pillar 11 (research-driven)** demands atomic commits binding design + code.
2. **Q3 (custom assembler)** puts the toolchain on the critical path; toolchain source must live alongside the code it compiles.
3. **Q2 (verification-friendly)** pushes correctness into CI; CI is dramatically simpler hermetic over a monorepo.
4. **E14 (linearity checker)** is whole-program; capability flow crosses kernel/userspace server boundaries.
5. **Pillar 10 (FP discipline)** means macro changes ripple across the tree; refactor atomically.

Costs accepted: large repo size (multi-GB within two years once test corpora are committed); partial-clone / sparse-checkout per Git 2.25+ as the mitigation.

---

## 2. Repository plan

### 2.1 Primary (create now)

| Repo | Path on GitHub | Purpose |
|---|---|---|
| `paideia-os` | `github.com/paideia-os/paideia-os` | The monorepo: kernel, userspace, design, tests, CI. Note: the custom assembler is *no longer* in this repo (deviation from §2.4 / §6.1; see §2.5). |

### 2.2 Toolchain — Custom assembler (two repos, per user instruction 2026-06-17)

The custom assembler (Q3 / paideia-as) is **factored out of the monorepo** into its own two repositories. This is a deviation from the original §6.1 monorepo decision (see §2.5 for rationale and trade-offs).

| Repo | Path on GitHub | Language | Target | Purpose |
|---|---|---|---|---|
| **`paideia-as`** | `github.com/paideia-os/paideia-as` | **Rust** | Linux development hosts | The primary Linux-hosted implementation of the custom assembler. Replaces the original OCaml plan (custom-assembler.md §8.3). Used by all PaideiaOS developers on their Linux workstations to assemble paideia-as source files for both phase-1 bootstrap and phase-2 use. |
| **`paideia-as-native`** | `github.com/paideia-os/paideia-as-native` | PaideiaOS-native paideia-as | PaideiaOS | The self-hosted assembler, written in paideia-as itself, running on PaideiaOS. Phase 3+ deliverable (per the custom-assembler.md phase plan). Bootstrapped from `paideia-as` output. |

**Creation timing:**

- `paideia-as`: **create early** — shortly after `paideia-os` is created. Phase 1 needs NASM for bootstrap, but the assembler project should be running in parallel so phase 2 has a working `paideia-as` to migrate onto. Trigger: when active development of the assembler begins.
- `paideia-as-native`: **create when phase 3 starts** — not before. The self-hosted port is gated on `paideia-as` being functional and the PaideiaOS userspace runtime being mature enough to host it.

### 2.3 Auxiliary repositories (create on-demand)

These are *designed-in possibilities*, not pre-creations. Each has a specific justifying need; do not create before the need arises.

| # | Repo | Trigger | Justification for being separate |
|---|---|---|---|
| 1 | `paideia-os-rebuild-attestations` | First release is cut | External rebuild verifiers (per `02-development-environment.md` §11.1) submit attestations here. Separate write-access boundary: external verifiers should not have write to the main monorepo, but need a contribution path. |
| 2 | `paideia-os-website` | Project goes public-facing | Public site has a different lifecycle (rapid iteration on marketing/landing pages) than the internal design corpus (slow, deliberate). Different reviewers, different cadence. |
| 3 | `paideia-os-lab` | Bare-metal CI stabilizes | Hardware lab configs, board manifests, self-hosted-runner OS images. Hardware-team-owned; access pattern differs from code; could include vendor-specific configurations that don't belong in the main repo. |
| 4 | `paideia-os-fuzz-corpora` | Corpora exceed ~5 GiB | Large binary blobs hurt clone times. Partial-clone is a mitigation; splitting is a cleaner alternative if corpora grow significantly. |

**Updated maximum eventual count: 7 repos.** Median expected within first year: 2 repos (`paideia-os` + `paideia-as`).

### 2.4 Things that are *not* separate repos

The following might be expected to be separate but are explicitly *part* of the monorepo:

- **Algorithm catalog** (`design/security/algorithm-catalog.md` from PQ doc): is in the monorepo; signed via PQ release process; published as a release artifact.
- **Public key manifest** (per PQ doc §10.3): in the monorepo; signed; published.
- **Audit log** (per E19): runtime artifact, not source; not a git repo.
- **Vendored upstream** (ACPICA, wasmtime): in the monorepo under `src/userspace/.../upstream/`; pinned via Nix.
- **TLA+ specifications**: in the monorepo under `design/**/*.tla`.
- **Test corpora** (linearity-regression, integration, system): in the monorepo under `tests/`.

### 2.5 Deviation from §6.1 monorepo — rationale and trade-offs

The original `02-development-environment.md` §6.1 mandated a single monorepo containing the assembler at `src/toolchain/asm/`. The user (2026-06-17) directed that the assembler be factored into two separate repositories (`paideia-as`, `paideia-as-native`). This section records the deviation and its implications.

**Reasons that justify the factoring:**

1. **Different language ecosystem.** `paideia-as` (Rust) and the monorepo (paideia-as + NASM during bootstrap) have completely different toolchains. Cargo workspaces work cleanly within the Rust repo without polluting the monorepo's Nix-based build.
2. **Independent utility.** The custom assembler — a substructural-lattice + algebraic-effect + functor-aware x86_64 assembler with a typed elaborator — has value beyond PaideiaOS. Factoring it out enables hypothetical external adoption.
3. **Independent release lifecycle.** Per `custom-assembler.md` §16, the assembler follows semantic versioning post-phase-3; this is awkward inside a monorepo whose versioning is OS-wide.
4. **Scope realism.** `custom-assembler.md` §0.3 explicitly flagged the assembler as 3–5 person-years of work. Keeping it in its own repo signals that it's a major project, not a sub-component.

**Costs of the factoring:**

1. **Loss of atomic toolchain + kernel commits.** A kernel feature that requires a new assembler feature now spans two repos: assembler PR first, monorepo PR second. The §6.1 reason 2 (Q3 puts toolchain on critical path) is partially undermined. Mitigation: a pinned assembler version in the monorepo's Nix flake; the monorepo pins to a specific `paideia-as` release. Cross-repo dependencies are explicit at the Nix lock level.
2. **Cross-repo PR coordination.** Changes spanning both repos require careful sequencing.
3. **Implementation language change** (OCaml → Rust): the `custom-assembler.md` §8.3 OCaml choice is superseded. The Rust choice has its own rationale (better ecosystem for systems tooling, mature LLVM integration, growing PQ-crypto library availability), but the rationale should be recorded in a future revision of `custom-assembler.md` §8.3.

**Open issues from the factoring:**

- **INFRA-O7**: Update `custom-assembler.md` §8.3 to reflect the Rust choice for stages 0/1 (and §10.2 to reflect the new build integration). Deferred until the user explicitly directs.
- **INFRA-O8**: Define the pin-and-release coordination between `paideia-as` and `paideia-os` monorepo — what's a "release" of `paideia-as` and when does the monorepo bump?
- **INFRA-O9**: Decide whether `paideia-as`'s test corpora include PaideiaOS-specific test inputs (sharing test data across repos is awkward but useful).

### 2.3 Things that are *not* separate repos

The following might be expected to be separate but are explicitly *part* of the monorepo:

- **Algorithm catalog** (`design/security/algorithm-catalog.md` from PQ doc): is in the monorepo; signed via PQ release process; published as a release artifact.
- **Public key manifest** (per PQ doc §10.3): in the monorepo; signed; published.
- **Audit log** (per E19): runtime artifact, not source; not a git repo.
- **Vendored upstream** (ACPICA, wasmtime): in the monorepo under `src/userspace/.../upstream/`; pinned via Nix.
- **TLA+ specifications**: in the monorepo under `design/**/*.tla`.
- **Test corpora** (linearity-regression, integration, system): in the monorepo under `tests/`.

---

## 3. GitHub organization structure

### 3.1 Recommended: a `paideia-os` organization

Create a GitHub organization named `paideia-os`. All current and future PaideiaOS repos live under it.

Benefits:
- Clean URL structure (`github.com/paideia-os/*`).
- Centralized member management.
- Organization-level secrets and OIDC for CI.
- Suitable for the kind of long-lived research project PaideiaOS is.

### 3.2 Alternative: personal account

The repos could live under `github.com/snunezcr/*`. This is simpler but:
- Doesn't scale if other contributors join.
- Mixes the project with the user's other repos.
- No org-level CI / secret management.

**Recommendation: organization.** The single-repo case works fine under either; the org positions cleanly for future growth.

---

## 4. Local layout

When the GitHub repos are cloned to siblings of the current PaideiaOS directory:

```
/home/snunez/Development/
├── PaideiaOS/                          ← current working dir; already a local git repo
│                                          would push to github.com/paideia-os/paideia-os
│                                          local dir name may be renamed (§5)
├── paideia-as/                         ← create early; Rust implementation
├── paideia-as-native/                  ← create at phase 3
├── paideia-os-rebuild-attestations/    ← if/when needed
├── paideia-os-website/                 ← if/when needed
├── paideia-os-lab/                     ← if/when needed
└── paideia-os-fuzz-corpora/            ← if/when needed
```

The user requested cloning to `..` from the current working directory, which is `/home/snunez/Development/`.

---

## 5. Naming conventions

| Concern | Convention | Notes |
|---|---|---|
| GitHub org name | `paideia-os` | Lowercase, hyphenated, modern convention |
| GitHub repo names | `paideia-os` (primary), `paideia-os-<suffix>` (auxiliaries) | Lowercase, hyphenated |
| Local directory names | `paideia-os` matching GitHub (recommended) OR `PaideiaOS` (current) | User's choice; local clone dir is independent of GitHub repo name |

**Current local dir is `PaideiaOS`**. Options for resolution:

- **Option A**: rename local to `paideia-os` for consistency with GitHub convention. Requires updating any path-hardcoded files (Nix flake, dev-env doc, scripts, the memory file paths, etc.).
- **Option B**: keep local as `PaideiaOS`; GitHub repo is still `paideia-os`. `git clone` accepts a target directory name argument, so this works.

Decision deferred to user. **Recommendation: Option A** (rename for consistency); the cost is a one-time path update.

---

## 6. Repository visibility

Initial recommendation: **private** until the project is ready for public release. The design corpus is research-grade and not yet refined for public consumption; the code is phase-1 not-yet-started. Transitioning to public is straightforward later.

Once made public, the project should adopt:
- A LICENSE (TBD; the existing LICENSE file should be reviewed).
- A CODE_OF_CONDUCT.md.
- A CONTRIBUTING.md (per dev-env §12.1 PR template).
- A SECURITY.md.

---

## 7. CI / GitHub Actions configuration

The dev-env §10.2 decided on GitHub Actions for the public-facing pipeline + self-hosted runners for QEMU and bare-metal stages.

When the GitHub repo is created, the following must be configured:
- GitHub Actions enabled.
- Self-hosted runner pool (initially: none; phase-1 uses GitHub-hosted only).
- Branch protection on `main`: require PR, require status checks, no direct push, no force-push.
- CODEOWNERS file (per dev-env §12.2) once the maintainer set exists.
- Secrets for PQ signing keys (per PQ-Q4 key residency); initially CI uses placeholder keys until the real ceremony.

---

## 8. Trigger checklist for repos

When should each repo actually be created? Concrete triggers:

### `paideia-as` (Rust assembler implementation)
- [ ] `paideia-os` monorepo created on GitHub.
- [ ] User explicitly directs creation.
- [ ] Project structure for the Rust workspace has been sketched (Cargo workspace layout, crate split).

### `paideia-as-native` (PaideiaOS-native self-hosted assembler)
- [ ] Phase 3 of the PaideiaOS plan has begun.
- [ ] `paideia-as` (the Rust impl) is stable enough that a self-hosted port can target a known specification.
- [ ] The PaideiaOS userspace can host a paideia-as-built process.

### `paideia-os-rebuild-attestations`
- [ ] First versioned release (v0.1.0 or later) is cut.
- [ ] At least one external party has expressed interest in independent rebuild verification.
- [ ] The release process has stabilized enough that external rebuilds are reproducible.

### `paideia-os-website`
- [ ] The project decides to go public.
- [ ] At least one introductory write-up exists.
- [ ] A domain name has been acquired (e.g., `paideia-os.org`).

### `paideia-os-lab`
- [ ] At least one bare-metal CI runner is operational.
- [ ] Hardware acquisition has reached more than a single board.
- [ ] The hardware team (if any) emerges as distinct from the software team.

### `paideia-os-fuzz-corpora`
- [ ] Fuzz corpora in the monorepo exceed 5 GiB.
- [ ] Clone times become a contributor friction.
- [ ] Partial-clone has been evaluated and found insufficient.

---

## 9. Execution

The user will instruct when to create the org and `paideia-os` repo. Until then:

- No `gh` commands will be run.
- No GitHub assets exist for PaideiaOS.
- The local repo at `/home/snunez/Development/PaideiaOS/` is the source of truth.

When the user is ready, execution should be:
1. Create the `paideia-os` organization on GitHub (via `gh api` or the web UI — this is a one-time admin action).
2. Create the `paideia-os` repository in that org (`gh repo create paideia-os/paideia-os --private --description "PaideiaOS: a clean-slate x86_64 microkernel"`).
3. Configure branch protection on `main`.
4. Add the GitHub remote to the local repo and push.

Each step should be confirmed before execution.

---

## 10. Open issues

| ID | Issue |
|---|---|
| INFRA-O1 | The local directory rename (PaideiaOS → paideia-os) decision (§5). |
| INFRA-O2 | The license choice (the existing LICENSE file should be reviewed for compatibility with the project's pillars and the eventual release model). |
| INFRA-O3 | Whether to use GitHub Actions for everything or to also support a portable CI vendor abstraction (per dev-env open issue S2). |
| INFRA-O4 | The CODEOWNERS structure (waiting for the maintainer set to emerge). |
| INFRA-O5 | GitHub Sponsors or other funding integration (deferred; only relevant once public). |
| INFRA-O6 | Whether to set up GitHub Pages for the website or a separate web hosting provider. |
| **INFRA-O7** | **Revise `custom-assembler.md` §8.3** to reflect the Rust implementation language choice for stages 0/1 (replacing OCaml) and §10.2 to reflect the new build integration (the assembler is a pinned Nix dependency, not in-tree source). Deferred until user direction. |
| **INFRA-O8** | Define the pin-and-release coordination between `paideia-as` and `paideia-os` monorepo — what's a "release" of `paideia-as` and when does the monorepo bump? |
| **INFRA-O9** | Decide whether `paideia-as`'s test corpora include PaideiaOS-specific test inputs (sharing test data across repos is awkward but useful). |
| **INFRA-O10** | Decide whether `paideia-as-native`'s source is a *direct port* of `paideia-as` (auto-translated) or a *fresh implementation* of the same spec. The phase-3 choice affects how the two repos evolve. |

---

*End of document.*
