#!/usr/bin/env bash
# R31.M2-1596/1597 (#1596, #1597) — user-image _init_caps sidecar gate.
#
# Reads the _init_caps sidecar out of every linked image under build/user/
# exactly the way loader_seed_caps_from_symtab does at boot -- through the
# ELF symbol table and section headers, not by re-reading the .pdx source --
# and enforces two policies over what it finds.
#
# ===========================================================================
# POLICY 1 (#1597): EVERY DECLARED KIND MUST BE LOADER-SEEDABLE.
# ===========================================================================
#
# The set of kinds a sidecar may name is KIND_SEEDABLE_TABLE in
# src/kernel/core/cap/kind.pdx, consulted at runtime through
# kind_is_loader_seedable. This gate asserts, at build time, that every kind
# every shipped image actually declares is in that set.
#
# THIS IS THE CHECK WHOSE ABSENCE WAS #1597. KIND_ACPI (0x20) and
# KIND_PCI_DEV (0x30) were declared in the kind registry, named by the
# sidecars of two shipped userspace images, documented in a source comment
# saying the accept set "will grow" to include them -- and rejected by the
# validator, for rounds. The images built clean and were simply unloadable.
# Nothing connected the two facts because nothing ever compared them.
#
# The failure at runtime is loud (INIT_CAPS_BAD_KIND -> LOADER_SEED_FAILED
# -> ELF_CAP_SEED_FAILED -> spawn refused, task torn down), and it should
# stay loud for a genuinely invalid kind. But loud at boot is the wrong
# place to learn that an image you just built can never be run. That belongs
# at the link, next to the image.
#
# It also enforces the other direction of the same drift: the table's own
# entries must each be a KIND_* constant declared in kind.pdx, so a value
# cannot be admitted to the seedable set without a kind to justify it.
#
# ===========================================================================
# POLICY 2 (#1596): NO TWO IMAGES MAY NAME THE SAME ABSOLUTE CAP SLOT.
# ===========================================================================
#
# R20b runs ONE GLOBAL cap_table (256 descriptors) shared by every task, and
# loader_seed_caps mints at the ABSOLUTE slot number the image names. Slot
# numbers are baked into images at build time. Two sidecar-carrying images
# naming the same slot therefore means the second load silently overwrites
# the first's descriptor -- and cap_mint_write clears cap_owner[slot] on
# every mint, so it erases the first task's ownership claim as well.
#
# Before #1596 every one of the four sidecar-carrying images named slot 0.
# The echo pair "worked" only by coincidence: both slot-0 entries were
# KIND_IPC_ENDPOINT on endpoint 1 and the survivor's rights were a superset
# of the victim's, so the client's sends still passed the rights gate and
# still resolved to the right endpoint. Two images whose slot 0 named
# different endpoints or different kinds would have swapped authority in
# silence -- the surviving descriptor is a perfectly well-formed capability,
# and the rights gate passes or fails against the WRONG OBJECT with no
# diagnostic anywhere.
#
# loader_seed_caps now REFUSES to seed a slot a live task already claims
# (LOADER_SEED_SLOT_TAKEN), which turns that silent theft into a visible
# boot failure. This gate is the other half: it makes the refusal
# unreachable in a tree that builds, by proving the shipped images' slot
# sets are pairwise disjoint before anything boots. A runtime refusal you
# can trip by building is a runtime refusal you will trip.
#
# The static allocation both halves police is documented in
# design/capabilities/loader-seeded-slot-allocation.md. It is INTERIM. The
# real answer is per-task capability spaces, at which point the slot an
# image names becomes private to it and this whole policy evaporates --
# along with the reason the refusal exists.
#
# ===========================================================================
# MUTATION TESTS (recorded in the #1596/#1597 commit message)
# ===========================================================================
#
#   - Point two images' sidecars at the same slot -> SLOT-COLLISION.
#   - Name a kind outside KIND_SEEDABLE_TABLE in an image -> KIND-NOT-SEEDABLE.
#   - Put a value in KIND_SEEDABLE_TABLE that is not a declared kind
#     -> TABLE-ENTRY-NOT-A-KIND.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build/user"
KIND_PDX="${REPO_ROOT}/src/kernel/core/cap/kind.pdx"

if [[ ! -d "${BUILD_DIR}" ]]; then
    echo "[cap-sidecars] FAIL — ${BUILD_DIR} does not exist; run tools/build-user.sh first" >&2
    exit 1
fi
if [[ ! -f "${KIND_PDX}" ]]; then
    echo "[cap-sidecars] FAIL — kind registry not found at ${KIND_PDX}" >&2
    exit 1
fi

OUT="$(python3 - "${BUILD_DIR}" "${KIND_PDX}" <<'PYEOF'
import pathlib, re, struct, subprocess, sys

build_dir = pathlib.Path(sys.argv[1])
kind_pdx  = pathlib.Path(sys.argv[2])

problems = []
notes    = []

# ---------------------------------------------------------------------------
# THE KIND REGISTRY is the whole cap module, not kind.pdx alone.
#
# kind.pdx holds the base enum and the R29/R30 derived blocks, but two of
# the kinds that matter most here are declared by their own subsystems:
# KIND_ACPI (0x20) in acpi_cap.pdx and KIND_PCI_DEV (0x30) in
# device_cap.pdx. That scattering is itself part of what #1597 documents --
# those two values were assigned in different rounds with no registry
# discipline between them -- so this gate reads every cap/*.pdx rather than
# pretending the registry is one file.
# ---------------------------------------------------------------------------
ktext = kind_pdx.read_text()
declared = {}
for src in sorted(kind_pdx.parent.glob("*.pdx")):
    for m in re.finditer(r"^\s*(?:pub\s+)?let\s+(KIND_\w+)\s*:\s*u64\s*=\s*"
                         r"(0x[0-9a-fA-F]+|\d+)\s*(?://.*)?$",
                         src.read_text(), re.M):
        declared.setdefault(m.group(1), int(m.group(2), 0))

if len(declared) < 20:
    problems.append("PARSE-FAIL cap/*.pdx: only %d KIND_* constants parsed "
                    "(vacuity guard; expected >= 20)" % len(declared))

# ---------------------------------------------------------------------------
# The seedable set.
# ---------------------------------------------------------------------------
tm = re.search(r"KIND_SEEDABLE_TABLE\s*:\s*\[u64;\s*(\d+)\]\s*=\s*\[(.*?)\]",
               ktext, re.S)
if not tm:
    problems.append("PARSE-FAIL kind.pdx: KIND_SEEDABLE_TABLE not found")
    seedable = set()
    declared_len = 0
else:
    declared_len = int(tm.group(1))
    body = re.sub(r"//[^\n]*", "", tm.group(2))
    seedable = set()
    for tok in body.split(","):
        tok = tok.strip()
        if tok:
            seedable.add(int(tok, 0))
    if len(seedable) != declared_len:
        problems.append("TABLE-LENGTH KIND_SEEDABLE_TABLE declares [u64; %d] "
                        "but holds %d distinct values"
                        % (declared_len, len(seedable)))

cm = re.search(r"KIND_SEEDABLE_COUNT\s*:\s*u64\s*=\s*(\d+)", ktext)
if not cm:
    problems.append("PARSE-FAIL kind.pdx: KIND_SEEDABLE_COUNT not found")
elif int(cm.group(1)) != declared_len:
    problems.append("TABLE-LENGTH KIND_SEEDABLE_COUNT = %s but "
                    "KIND_SEEDABLE_TABLE is [u64; %d]"
                    % (cm.group(1), declared_len))

# The predicate's own scan bound must match the table, or it would walk off
# the end of it (or stop short and silently refuse a seedable kind).
bm = re.search(r"mov r11, (\d+);\s*//\s*KIND_SEEDABLE_COUNT", ktext)
if not bm:
    problems.append("PARSE-FAIL kind.pdx: kind_is_loader_seedable's scan "
                    "bound not found (expected `mov r11, N; // KIND_SEEDABLE_COUNT`)")
elif int(bm.group(1)) != declared_len:
    problems.append("SCAN-BOUND kind_is_loader_seedable scans %s entries but "
                    "KIND_SEEDABLE_TABLE holds %d"
                    % (bm.group(1), declared_len))

# Every entry in the set must be a kind someone declared.
kind_values = set(declared.values())
name_of = {}
for n, v in declared.items():
    name_of.setdefault(v, n)
for v in sorted(seedable):
    if v not in kind_values:
        problems.append("TABLE-ENTRY-NOT-A-KIND KIND_SEEDABLE_TABLE contains "
                        "0x%x, which is not any KIND_* declared under "
                        "src/kernel/core/cap/" % v)

notes.append("seedable set: " + ", ".join(
    "0x%x (%s)" % (v, name_of.get(v, "?")) for v in sorted(seedable)))

# ---------------------------------------------------------------------------
# Sidecar extraction, the way the loader does it: symtab + section headers.
# ---------------------------------------------------------------------------
def sections(elf):
    out = subprocess.run(["readelf", "-SW", str(elf)],
                         capture_output=True, text=True).stdout
    secs = []
    for m in re.finditer(
            r"^\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)",
            out, re.M):
        secs.append({"name": m.group(1), "type": m.group(2),
                     "addr": int(m.group(3), 16), "off": int(m.group(4), 16),
                     "size": int(m.group(5), 16)})
    return secs

def symbols(elf):
    out = subprocess.run(["readelf", "-sW", str(elf)],
                         capture_output=True, text=True).stdout
    syms = {}
    for m in re.finditer(
            r"^\s*\d+:\s+([0-9a-f]+)\s+(\d+)\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)\s*$",
            out, re.M):
        syms[m.group(3)] = (int(m.group(1), 16), int(m.group(2)))
    return syms

def read_at(elf, secs, vaddr, nbytes):
    for s in secs:
        if s["type"] == "NOBITS" or s["size"] == 0:
            continue
        if s["addr"] <= vaddr < s["addr"] + s["size"]:
            off = s["off"] + (vaddr - s["addr"])
            if off + nbytes > s["off"] + s["size"]:
                return None
            with open(elf, "rb") as fh:
                fh.seek(off)
                return fh.read(nbytes)
    return None

images = sorted(build_dir.glob("*.elf"))
if not images:
    problems.append("PARSE-FAIL no *.elf under %s (vacuity guard)" % build_dir)

slot_owner = {}      # slot -> image name
sidecar_images = 0

for elf in images:
    secs = sections(elf)
    syms = symbols(elf)
    if "_init_caps" not in syms or "_init_caps_count" not in syms:
        continue                              # no sidecar; nothing to police
    sidecar_images += 1

    cnt_va, _ = syms["_init_caps_count"]
    raw = read_at(elf, secs, cnt_va, 8)
    if raw is None:
        problems.append("PARSE-FAIL %s: _init_caps_count not in a loadable "
                        "section" % elf.name)
        continue
    count = struct.unpack("<Q", raw)[0] & 0xFFFF

    ents_va, ents_size = syms["_init_caps"]
    if count * 16 > ents_size:
        problems.append("SIDECAR-OVERRUN %s: _init_caps_count = %d needs %d "
                        "bytes but _init_caps is %d bytes"
                        % (elf.name, count, count * 16, ents_size))
        continue
    raw = read_at(elf, secs, ents_va, count * 16)
    if raw is None:
        problems.append("PARSE-FAIL %s: _init_caps not in a loadable section"
                        % elf.name)
        continue

    entries = []
    for i in range(count):
        slot, kind, rights = struct.unpack_from("<HHI", raw, i * 16)
        target = struct.unpack_from("<Q", raw, i * 16 + 8)[0]
        entries.append((slot, kind, rights, target))

    notes.append("%s: %d entries -> %s" % (
        elf.name, count,
        " ".join("slot=%d kind=0x%x" % (s, k) for s, k, _, _ in entries)))

    for slot, kind, rights, target in entries:
        # POLICY 1 -- the kind must be loader-seedable.
        if seedable and kind not in seedable:
            problems.append(
                "KIND-NOT-SEEDABLE %s slot %d names kind 0x%x, which is not in "
                "KIND_SEEDABLE_TABLE. This image cannot be spawned: "
                "init_caps_validate will answer INIT_CAPS_BAD_KIND, "
                "loader_seed_caps will answer LOADER_SEED_FAILED, and "
                "boot_spawn_user_task will refuse the spawn and tear the task "
                "back down. Either add the kind to the seedable set in "
                "kind.pdx WITH A STATED REASON, or stop declaring it here."
                % (elf.name, slot, kind))
        # POLICY 2 -- the slot must not already belong to another image.
        prev = slot_owner.get(slot)
        if prev is not None and prev != elf.name:
            problems.append(
                "SLOT-COLLISION %s and %s both name absolute cap slot %d. "
                "One global cap_table means the second image loaded silently "
                "overwrites the first's descriptor AND its owner claim. "
                "loader_seed_caps now refuses this at runtime "
                "(LOADER_SEED_SLOT_TAKEN), so the collision is a REFUSED "
                "SPAWN, not a swapped capability -- but it must not be "
                "reachable from a tree that builds. Give the images disjoint "
                "slots per design/capabilities/loader-seeded-slot-allocation.md."
                % (prev, elf.name, slot))
        else:
            slot_owner[slot] = elf.name

if sidecar_images == 0:
    problems.append("PARSE-FAIL no image declared an _init_caps sidecar "
                    "(vacuity guard: this gate would police nothing)")

for n in notes:
    print("NOTE " + n)
print("SUMMARY images=%d sidecars=%d slots=%d"
      % (len(images), sidecar_images, len(slot_owner)))
for pr in problems:
    print("PROBLEM " + pr)
PYEOF
)"

if [[ -z "${OUT}" ]] || ! grep -q "^SUMMARY " <<<"${OUT}"; then
    echo "[cap-sidecars] FAIL — sidecar scan did not complete: ${OUT:-<empty>}" >&2
    exit 1
fi

grep "^NOTE " <<<"${OUT}" | sed 's/^NOTE /[cap-sidecars]   /'
grep "^SUMMARY " <<<"${OUT}" | sed 's/^SUMMARY /[cap-sidecars] /'

if grep -q "^PROBLEM " <<<"${OUT}"; then
    echo "[cap-sidecars] FAIL" >&2
    grep "^PROBLEM " <<<"${OUT}" | sed 's/^PROBLEM /[cap-sidecars] /' >&2
    exit 1
fi

echo "[cap-sidecars] PASS — every declared kind is loader-seedable; no two images share a cap slot"
