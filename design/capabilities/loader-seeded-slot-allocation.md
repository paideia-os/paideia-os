# Loader-seeded capability slot allocation (INTERIM)

**Status.** Interim, and deliberately so. Superseded in full by per-task
capability spaces (`design/capabilities/per-task-cspace.md`).
**Issues.** #1596 (the collision), #1597 (the accept set).
**Round.** R31.M2.

---

## 1. The problem this document exists because of

R20b runs **one global `cap_table`** — 256 descriptors in
`src/kernel/core/cap/table.pdx`, shared by every task in the system.
`loader_seed_caps` mints each `_init_caps` sidecar entry at the **absolute
slot number the image names**, and those slot numbers are baked into the
image at build time.

Every sidecar-carrying image in this tree named slot 0.

So spawning any two of them meant the second load re-minted slot 0 over the
first's descriptor — and `cap_mint_write` clears `cap_owner[slot]` on every
mint, so it erased the first task's ownership claim on the way past. One
task lost a capability to another, and nothing anywhere reported it.

### Why it looked fine

`boot_r31_spawn_pair` spawns `echo_client` then `echo_server` and the pair
worked. It worked by **coincidence**:

- both slot-0 entries were `KIND_IPC_ENDPOINT` on endpoint 1, and
- the survivor's rights (`R_IPC_ALL`) were a **superset** of the victim's
  (`R_IPC_WRITE|R_IPC_INVOKE`).

So the client's `sys_ipc_send` on cap slot 0 still passed the dispatch
rights gate and still resolved to endpoint 1. Change either fact — a
different endpoint, a different kind — and the surviving descriptor is still
a perfectly well-formed capability, the rights gate still passes or fails,
and it does so **against the wrong object**, silently.

The golden recorded the damage as the expected value:
`R31 SPAWN CAP SWEEP OK count=1`, where 1 is the number of capabilities the
client still owned after the server took one of its two. It is `count=2` now.

---

## 2. What was done, and what was deliberately not done

### 2.1 The runtime refusal (`LOADER_SEED_SLOT_TAKEN`)

`loader_seed_caps` gained an **ownership pre-pass**. Before minting
anything, it walks every entry in the sidecar and refuses the whole blob if
any slot it names is held by a live owner that is not the seeding task:

```
2.5 PRE-PASS: for each entry, if cap_owner_live_key(slot) is neither
    CAP_OWNER_NONE nor this task's own key -> return LOADER_SEED_SLOT_TAKEN
```

Three points about the shape, each of which was a decision:

- **It is a separate pass, not a check inside the mint loop.** A mid-loop
  refusal is not a refusal. If entry 3 collides after entries 0–2 have been
  minted, the load fails, the caller tears the task down, and three
  descriptors are left in the global table owned by a pid that has just been
  freed and will shortly be reissued. The validator already guarantees "no
  task can observe a partially-seeded cap_table" for structural errors; this
  extends the same guarantee to semantic ones.

- **Liveness is derived, not trusted.** `cap_owner_live_key` (new, in
  `cap/owner.pdx`) answers the column's key only if `pid_gen_read` confirms
  that exact incarnation is still live. A key left behind by a dead task
  does not block anyone. This matters because `pid_alloc` is dense-low-first
  with no aging: a pid-only comparison would report a dead task's slot as
  live and refuse a legitimate seed forever.

- **It is loud.** The return code alone is laundered through
  `elf_lite_load` into `ELF_CAP_SEED_FAILED` and then into
  `BOOT_SPAWN_ERR_ELF_LOAD`, which reads as "the ELF failed to load" — true
  and useless. The refusal therefore emits, at `LEVEL_ERROR`:

  ```
  R31 SEED SLOT TAKEN LIVE slot=<n>
  ```

  The slot number is the only value that makes the condition diagnosable.

### 2.2 What this does **not** do

It does not make the global table safe. It converts exactly one failure —
authority silently changing hands — into a refused spawn that says so. Two
images still cannot both have slot 0. That is a true statement about the
design, and §3 is how the tree lives with it until §4 removes it.

---

## 3. The interim allocation

Absolute slots in the single global `cap_table`, partitioned by image.

| slots | holder | contents |
|---|---|---|
| 0–1 | `echo_client` | 0 = server endpoint (ep 1, `WRITE\|INVOKE`); 1 = own reply endpoint (ep 2, `READ\|INVOKE`) |
| 2 | `echo_server` | own RPC endpoint (ep 1, `R_IPC_ALL`) |
| 3–4 | *reserved* | |
| 5 | **kernel boot witness** | `loader_seed_witness` (`kernel_main.pdx`) mints here |
| 6–7 | *reserved* | |
| 8–9 | `acpi_supervisor` | 8 = RPC endpoint (ep 3, `R_IPC_ALL`); 9 = `KIND_ACPI` (`R_ACPI_READ`) |
| 10–11 | *reserved* | |
| 12–13 | `pci_enumerator` | 12 = RPC endpoint (ep 4, `R_IPC_ALL`); 13 = `KIND_PCI_DEV` (`R_DEV_CONFIG_READ`) |
| 14+ | free | |

Slot 5 is reserved rather than merely avoided: the boot witness genuinely
mints there, and an image that took it would collide with the kernel's own
fixture rather than with another image — a failure that would be read as a
kernel bug.

**Changing an image's slots means changing the image**, because the syscall
arguments are literals in the same source file (`mov rdi, 8` for
`acpi_supervisor`'s `sys_ipc_recv`). The sidecar and the code that uses it
must move together. `tools/verify-user-cap-sidecars.sh` checks the sidecar
half; nothing checks the code half, which is one more reason §4 is the real
answer.

### 3.1 The build-time gate

`tools/verify-user-cap-sidecars.sh` reads each image's sidecar the way the
loader does — ELF symbol table plus section headers, not by re-parsing the
`.pdx` — and enforces that no two images name the same slot.

The point is that **the runtime refusal must be unreachable from a tree that
builds**. A refusal you can trip by building is a refusal you will trip, at
boot, in a mode somebody has to bisect.

### 3.2 A collision this found that nobody had planted

The refusal immediately caught one that had nothing to do with the four
images. `m6_symtab_witness` in `kernel_main.pdx` creates a synthetic task,
loads `echo_server.elf` into it, asserts the seeded descriptor, and frees
the task. It asserted `cap_table[0]`, so when `echo_server` moved to slot 2
it failed at sub-test 3 — and **its failure path skips the `task_free`
cleanup**, leaving a live task permanently owning slot 2. The real
`echo_server` spawn several thousand lines later was then refused with
`LOADER_SEED_SLOT_TAKEN`.

Two separate defects, both previously invisible because a later mint would
silently paper over whatever the column said:

1. the witness asserted a slot the image no longer used, and
2. **`task_free` does not sweep the cap_owner column.** Every *real* death
   reaches `cap_owner_sweep_revoke` via `driver_death_notify`; a task
   disposed of directly with `task_free` never does. The witness now sweeps
   explicitly before freeing. The general fix belongs in `task_free` — which
   is also called on `boot_spawn`'s failure-teardown path — and is filed
   separately rather than made here.

---

## 4. Why this is interim, and what replaces it

Per-task capability spaces. The slot an image names becomes an index into
**its own** descriptor array, no two images can collide by construction,
this document's §3 table evaporates, and the §2.1 refusal has nothing left
to refuse.

The plumbing has been threaded for it since R20b.M4-002:
`loader_seed_caps` and `loader_seed_caps_from_symtab` both take `task_ptr`,
and since #1590 `elf_lite_load` does too and passes the real owning task.
`cap_mint_write` is the one primitive still writing to a fixed global
symbol, and its own header says so.

The `cap_owner` column is that migration's oracle: every descriptor already
records which task it belongs to, so the split is checkable rather than
guessed.

### Why not do it now

It is a round of work, not an iteration. The image-side change alone is not
small: a sidecar that names indices rather than absolute slots requires the
image to learn its own base at runtime, because the syscall arguments are
compile-time literals (`mov rdi, 0`). That is a task-entry ABI change on top
of the kernel-side descriptor-array change, and it touches every `cap_slot`
consumer in the dispatch path.

---

## 5. The accept set (#1597), and why it lives elsewhere

`init_caps_validate` used to accept `kind <= 15 || kind == 0x15 || kind ==
0x16`. `KIND_ACPI` (0x20) and `KIND_PCI_DEV` (0x30) were therefore
un-seedable, which is why `acpi_supervisor` and `pci_enumerator` could not
be loaded at all — the hard block under #1086.

The set now has exactly one definition, `KIND_SEEDABLE_TABLE` in
`cap/kind.pdx`, consulted through `kind_is_loader_seedable`. It lives with
the kinds because it is a statement *about* the kinds. The full argument —
including why `kind <= 15` was never a decision about authority, why the
change is a **narrowing** as well as a widening, and why the numbering
regions are accretion rather than taxonomy — is in the comment block above
that table.

The one-line summary: **seedable = {5, 0x15, 0x16, 0x20, 0x30}**, and the
kernel-object base kinds are refused because their `target_ptr` is an
unvalidated kernel pointer supplied by untrusted image bytes.

---

## 6. Guardrails, and the mutations that prove they bite

| guardrail | tag on failure | induced by |
|---|---|---|
| runtime slot refusal | `R31 SEED SLOT TAKEN LIVE slot=0` | point `echo_server`'s sidecar back at slot 0 |
| build-time slot disjointness | `SLOT-COLLISION` | same |
| build-time kind accept set | `KIND-NOT-SEEDABLE` | name kind 3 in `acpi_supervisor`'s sidecar |
| seedable table integrity | `TABLE-ENTRY-NOT-A-KIND` | put 0x31 in `KIND_SEEDABLE_TABLE` |
| predicate/table agreement | `SCAN-BOUND` | make the predicate scan 4 of 5 entries |
| validator narrowing | `R20b INIT CAPS FMT FAIL` (sub-test 5) | add kind 3 to `KIND_SEEDABLE_TABLE` |

The narrowing mutation was run: re-admitting kind 3 to
`KIND_SEEDABLE_TABLE` makes `init_caps_witness` emit
`R20b INIT CAPS FMT FAIL` at `LEVEL_ERROR`, which fails
`boot_r17_shell_shutdown` (its golden asserts the corresponding
`R20b INIT CAPS FMT OK`). Note that this witness's FAIL path does not
render its `line=` KV even though it passes one to `klog_s1_d1`, unlike
`R31 BOOT SPAWN FAIL line=6` from the same file — a pre-existing
inconsistency, noted rather than fixed here.

Sub-test 5 of `init_caps_witness` tests kind **3**, not the kind 17 that
sub-test 3 already tested. 17 was *always* refused and proves only that the
gate exists; 3 was **accepted before this change**. A witness that tested
only 17 would stay green if the narrowing were reverted.
