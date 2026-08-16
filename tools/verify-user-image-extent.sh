#!/usr/bin/env bash
# R31.M2-1595 (#1595) — user-image PT_LOAD extent gate.
#
# WHAT THIS POLICES
#
# Two properties of every linked user image under build/user/:
#
#   (1) NO PT_LOAD MAY DESCRIBE A HOLE.
#       A segment's p_memsz must not exceed the sum of the sizes of the
#       sections mapped into it, plus one segment-alignment of slack per
#       section. That slack is the most any honest packing can need: a
#       section starts at most p_align-1 bytes past the end of the one
#       before it. Anything beyond it is address space the linker was
#       TOLD to skip, and the loader will faithfully map.
#
#   (2) NO IMAGE MAY EXCEED A STATED PAGE BUDGET.
#       Sum over PT_LOADs of ceil(p_memsz / 4096) must be <=
#       USER_IMAGE_MAX_PAGES.
#
# WHY THIS GATE EXISTS
#
# Seven linker scripts under src/user/ drifted into the same defect and
# nothing looked. Each declared two program headers, assigned BOTH .data
# and .bss to the second one, and then forced them 1 MiB apart:
#
#     . = 0x00600000;
#     .data : ALIGN(4K) { *(.data .data.*) } :data
#     . = 0x00700000;
#     .bss (NOLOAD) : ALIGN(4K) { ... } :data
#
# That does not create a second segment. It stretches the one segment
# across the gap, and for any image with a non-empty .data the linker
# emits p_memsz = 0x102000 -- a 1 MiB program header for a few KiB of
# real content.
#
# It was inert for as long as (a) nothing loaded these images and (b)
# every one of them happened to have an empty .data. Both stopped being
# true. #1590 spawned user images as real ring-3 tasks AND fixed
# elf_lite_load's per-page mapping loop, which had been mapping only
# page 0 of each segment; with the whole extent now mapped, elf_lite_load
# allocates one frame per 4 KiB, so such an image asks for 258 frames out
# of a 1024-frame pool for a program needing about six.
#
# The trigger for all of that is ADDING ONE INITIALISED MUTABLE to a .pdx
# file under src/user/ -- an entirely ordinary edit with no visible
# connection to memory layout. The symptom is a 258-frame allocation
# demand or an ELF_BAD_SIZE rejection, neither of which points at a
# linker script. Seven scripts drifted the same way because nothing
# looked; an eighth will.
#
# WHY A BUDGET AND NOT ONLY A SPARSITY CHECK
#
# The sparsity rule catches a hole. It does not catch an image that
# honestly grew too large. boot_spawn_user_task refuses to begin a spawn
# unless phys_alloc_free_count >= BOOT_SPAWN_MIN_FREE_FRAMES (64), and
# the image's own pages are only part of what a spawn costs: a PML4 root,
# up to three intermediate page-table levels per fresh 2 MiB region, and
# four user-stack pages. An image above the budget below is one whose
# growth has started eating the margin that pre-check was sized for, and
# that is worth a build failure and a deliberate re-budgeting rather than
# an OOM diagnosed at an arbitrary later instruction.
#
# CALIBRATION (measured, post-#1595)
#
#   image             text pages   data pages   total
#   echo_client            1            3          4     <- largest
#   acpi_supervisor        1            1          2
#   echo_server            1            1          2
#   init / shell           1            1          2
#   pci_enumerator         1            1          2
#   child_hello / true     1            0          1
#
# The budget is 16 -- four times the current worst case, and still a
# quarter of BOOT_SPAWN_MIN_FREE_FRAMES. Raising it is a legitimate
# change; making it silently unnecessary is what this gate prevents.
#
# MUTATION TEST
#
# Restoring `. = 0x00700000;` to any one of the src/user/*.ld scripts and
# rebuilding must fail this gate with EXTENT-HOLE on that image. That is
# recorded in the #1595 commit message.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BUILD_DIR="${REPO_ROOT}/build/user"

# Total mapped pages permitted per user image. See §CALIBRATION.
USER_IMAGE_MAX_PAGES="${USER_IMAGE_MAX_PAGES:-16}"

if [[ ! -d "${BUILD_DIR}" ]]; then
    echo "[user-image-extent] FAIL — ${BUILD_DIR} does not exist; run tools/build-user.sh first" >&2
    exit 1
fi

shopt -s nullglob
IMAGES=("${BUILD_DIR}"/*.elf)
shopt -u nullglob

if [[ ${#IMAGES[@]} -eq 0 ]]; then
    # VACUITY GUARD. A gate that scans nothing passes for the wrong
    # reason; this is the failure mode tools/verify-fingerprint-coverage.sh
    # names explicitly and it applies identically here.
    echo "[user-image-extent] FAIL — no *.elf found under ${BUILD_DIR} (vacuity guard)" >&2
    exit 1
fi

RC=0

for elf in "${IMAGES[@]}"; do
    name="$(basename "${elf}")"

    # readelf -SW carries section sizes; readelf -lW carries the program
    # headers AND the section-to-segment map. Both are fed to one parser
    # as a concatenated stream rather than asking readelf for `-lSW` in a
    # single invocation, because that interleaves the two tables and puts
    # the segment map after both, making the parse depend on readelf's
    # output ordering rather than on the table headings.
    report="$( { readelf -SW "${elf}"; readelf -lW "${elf}"; } 2>/dev/null | python3 -c '
import re, sys

PAGE = 4096
text = sys.stdin.read()

loads = []
for m in re.finditer(
        r"^\s+LOAD\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+"
        r"(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+([RWE ]+)\s+(0x[0-9a-f]+)\s*$",
        text, re.M):
    loads.append({"memsz": int(m.group(5), 16),
                  "align": int(m.group(7), 16) or PAGE})

seg_map = {}
in_map = False
for line in text.splitlines():
    if "Section to Segment mapping" in line:
        in_map = True
        continue
    if not in_map:
        continue
    m = re.match(r"^\s+(\d\d)\s+(.*)$", line)
    if m:
        seg_map[int(m.group(1))] = m.group(2).split()

sizes = {}
for m in re.finditer(
        r"^\s*\[\s*\d+\]\s+(\.\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)",
        text, re.M):
    sizes[m.group(1)] = int(m.group(4), 16)

if not loads:
    sys.stdout.write("PARSE-FAIL no-PT_LOAD\n")
    raise SystemExit(0)

total_pages = 0
for i, seg in enumerate(loads):
    names = seg_map.get(i, [])
    if not names:
        sys.stdout.write("PARSE-FAIL segment-%d-has-no-sections\n" % i)
        raise SystemExit(0)
    unknown = [n for n in names if n not in sizes]
    if unknown:
        sys.stdout.write("PARSE-FAIL unknown-section-%s\n" % ",".join(unknown))
        raise SystemExit(0)
    content = sum(sizes[n] for n in names)
    slack = seg["align"] * len(names)
    pages = (seg["memsz"] + PAGE - 1) // PAGE
    total_pages += pages
    sys.stdout.write("SEG %d memsz=%d content=%d limit=%d pages=%d sections=%s\n"
                     % (i, seg["memsz"], content, content + slack, pages,
                        ",".join(names)))
sys.stdout.write("TOTAL pages=%d\n" % total_pages)
')"

    if [[ -z "${report}" ]] || grep -q "PARSE-FAIL" <<<"${report}"; then
        # A parse failure is a FAILURE, not a skip. If readelf's output
        # shape ever changes, this gate must stop passing rather than
        # start scanning nothing.
        echo "[user-image-extent] FAIL ${name} — could not parse headers: ${report:-<empty>}" >&2
        RC=1
        continue
    fi

    while read -r kind rest; do
        case "${kind}" in
        SEG)
            seg_idx="${rest%% *}"
            memsz=$(grep -o 'memsz=[0-9]*' <<<"${rest}" | cut -d= -f2)
            content=$(grep -o 'content=[0-9]*' <<<"${rest}" | cut -d= -f2)
            limit=$(grep -o 'limit=[0-9]*' <<<"${rest}" | cut -d= -f2)
            sections=$(grep -o 'sections=[^ ]*' <<<"${rest}" | cut -d= -f2)
            if (( memsz > limit )); then
                echo "[user-image-extent] FAIL ${name} — EXTENT-HOLE in PT_LOAD ${seg_idx}:" >&2
                echo "    p_memsz  = ${memsz} bytes" >&2
                echo "    content  = ${content} bytes  (sections: ${sections})" >&2
                echo "    permitted= ${limit} bytes  (content + one p_align per section)" >&2
                echo "    hole     = $(( memsz - content )) bytes" >&2
                echo "  A PT_LOAD is describing address space no section occupies." >&2
                echo "  Check src/user/$(basename "${name}" .elf).ld for an explicit" >&2
                echo "  '. = <addr>;' between two sections assigned to the SAME PHDR." >&2
                echo "  See the header of this script and #1595." >&2
                RC=1
            fi
            ;;
        TOTAL)
            pages=$(grep -o 'pages=[0-9]*' <<<"${rest}" | cut -d= -f2)
            if (( pages > USER_IMAGE_MAX_PAGES )); then
                echo "[user-image-extent] FAIL ${name} — PAGE-BUDGET: ${pages} mapped pages > ${USER_IMAGE_MAX_PAGES}" >&2
                echo "  elf_lite_load allocates one frame per 4 KiB of p_memsz out of a" >&2
                echo "  1024-frame pool, and boot_spawn_user_task pre-checks only 64 free" >&2
                echo "  frames for the WHOLE spawn (image + PML4 + intermediates + stack)." >&2
                echo "  Raise USER_IMAGE_MAX_PAGES deliberately, or shrink the image." >&2
                RC=1
            else
                echo "[user-image-extent] ${name}: ${pages}/${USER_IMAGE_MAX_PAGES} pages OK"
            fi
            ;;
        esac
    done <<<"${report}"
done


# ---------------------------------------------------------------------------
# RULE 3 — LINKER-SCRIPT LINT: no location-counter jump between two output
#          sections that share one program header.
#
# WHY THIS RULE EXISTS SEPARATELY FROM RULES 1 AND 2
#
# Rules 1 and 2 read the LINKED ELF, and there is a case they provably
# cannot see. If `.data` is EMPTY, ld drops the zero-size section from the
# segment entirely and the segment simply begins at `.bss` -- p_memsz comes
# out as the real bss size and no hole appears in any program header. That
# is not a hypothesis; it is measured:
#
#     init.ld with `. = 0x00700000;` restored, .data empty
#       LOAD 0x000000 0x0000000000700000 ... 0x000000 0x001000 RW
#       [user-image-extent] init.elf: 2/16 pages OK      <- rules 1+2 PASS
#
# So the ELF-level rules catch this defect only at the moment it goes
# LIVE -- i.e. when somebody adds an initialised mutable. That is a useful
# moment to catch it, but it is not the moment the defect is INTRODUCED,
# and it is exactly why seven scripts were able to carry it for rounds
# without anything noticing. A gate that would itself have passed on all
# seven of the scripts it exists to police is not a gate.
#
# This rule reads the SOURCE, where the defect actually lives, and fails on
# the latent form. The two levels are complementary: rule 3 stops the
# script from being written, rules 1 and 2 stop any other route to an
# oversized segment (a genuinely huge .bss, a third PHDR, a hand-edited
# script this parser does not understand).
# ---------------------------------------------------------------------------

echo "[user-image-extent] linting src/user/*.ld for intra-segment location-counter jumps"

LINT_OUT="$(python3 - "${REPO_ROOT}/src/user" <<'PYEOF'
import pathlib, re, sys

src = pathlib.Path(sys.argv[1])
scripts = sorted(src.glob("*.ld"))
if not scripts:
    print("PARSE-FAIL no-linker-scripts")           # vacuity guard
    raise SystemExit(0)

failed = False
for path in scripts:
    text = path.read_text()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)   # strip C comments

    m = re.search(r"\bSECTIONS\b\s*\{", text)
    if not m:
        print("PARSE-FAIL %s no-SECTIONS-block" % path.name)
        failed = True
        continue

    # Walk the SECTIONS body with a brace counter, recording an ordered
    # event list. Only depth-1 constructs matter: a `. = <expr>;` directly
    # inside SECTIONS is a location-counter jump, and an output section
    # definition at depth 1 carries the `:phdr` on its closing brace.
    i = m.end()
    depth = 1
    events = []            # ("DOT", lineno) | ("SEC", name, phdr, lineno)
    pending = None         # (name, lineno) for the section currently open
    buf = ""
    line = text[:i].count("\n") + 1

    while i < len(text) and depth > 0:
        ch = text[i]
        if ch == "\n":
            line += 1
        if ch == "{":
            if depth == 1:
                sm = re.search(r"([.\w/]+[\w.*]*)\s*(?:\(NOLOAD\))?\s*:\s*"
                               r"(?:ALIGN\([^)]*\)\s*)?$", buf.strip())
                pending = (sm.group(1) if sm else "?", line)
            depth += 1
            buf = ""
        elif ch == "}":
            depth -= 1
            if depth == 1 and pending is not None:
                tail = text[i + 1:i + 64]
                pm = re.match(r"\s*:\s*(\w+)", tail)
                events.append(("SEC", pending[0], pm.group(1) if pm else None,
                               pending[1]))
                pending = None
            buf = ""
        elif ch == ";":
            # The statement is the LAST LINE of the buffer, not the whole
            # buffer: after a section closes, the buffer carries the ` :phdr`
            # suffix that followed its `}`, so anchoring the match at the
            # start of `buf` never fires. That bug made this lint pass on a
            # deliberately reintroduced hole; the mutation test below is what
            # caught it, which is the argument for running one.
            stmt = buf.rsplit("\n", 1)[-1]
            if depth == 1 and re.match(r"^\s*\.\s*=", stmt):
                events.append(("DOT", stmt.strip(), line))
            buf = ""
        else:
            buf += ch
        i += 1

    if not any(e[0] == "SEC" for e in events):
        print("PARSE-FAIL %s no-output-sections-parsed" % path.name)
        failed = True
        continue
    # VACUITY GUARD. The whole rule is a comparison between sections that
    # share a PHDR. If no section parsed with a `:phdr` suffix there is
    # nothing to compare and the script would pass without looking.
    if not any(e[0] == "SEC" and e[2] for e in events):
        print("PARSE-FAIL %s no-section-carries-a-phdr" % path.name)
        failed = True
        continue
    if not any(e[0] == "DOT" for e in events):
        # Every script in this tree sets the location counter at least once
        # (`. = 0x00400000;` before .text). None parsing means the statement
        # scanner is broken, which is exactly the bug fixed above.
        print("PARSE-FAIL %s no-location-counter-statement-parsed" % path.name)
        failed = True
        continue

    # For each pair of sections sharing a PHDR, was there a location-counter
    # jump between them?
    last_by_phdr = {}      # phdr -> (index into events, section name)
    for idx, ev in enumerate(events):
        if ev[0] != "SEC":
            continue
        name, phdr = ev[1], ev[2]
        if phdr is None:
            continue
        prev = last_by_phdr.get(phdr)
        if prev is not None:
            between = [e for e in events[prev[0] + 1:idx] if e[0] == "DOT"]
            if between:
                print("HOLE %s %s %s %s %d %s"
                      % (path.name, phdr, prev[1], name,
                         between[-1][2], between[-1][1]))
                failed = True
        last_by_phdr[phdr] = (idx, name)

print("LINT-DONE %d scripts" % len(scripts))
PYEOF
)"

if [[ -z "${LINT_OUT}" ]] || ! grep -q "LINT-DONE" <<<"${LINT_OUT}"; then
    echo "[user-image-extent] FAIL — linker-script lint did not complete: ${LINT_OUT:-<empty>}" >&2
    RC=1
elif grep -q "PARSE-FAIL" <<<"${LINT_OUT}"; then
    echo "[user-image-extent] FAIL — linker-script lint could not parse:" >&2
    grep "PARSE-FAIL" <<<"${LINT_OUT}" >&2
    RC=1
elif grep -q "^HOLE " <<<"${LINT_OUT}"; then
    while read -r _ script phdr first second lineno jump; do
        echo "[user-image-extent] FAIL ${script} — SCRIPT-HOLE: a location-counter jump sits" >&2
        echo "    between two output sections assigned to the SAME program header." >&2
        echo "      phdr     : ${phdr}" >&2
        echo "      sections : ${first} ... ${second}" >&2
        echo "      jump     : '${jump};' at ${script}:${lineno}" >&2
        echo "  Both sections share one PT_LOAD, so this does not create a second" >&2
        echo "  segment -- it stretches the one segment across the gap, and p_memsz" >&2
        echo "  grows to span it the moment the earlier section is non-empty." >&2
        echo "  Let the later section follow the earlier one contiguously, or give" >&2
        echo "  it a PHDR of its own. See #1595." >&2
        RC=1
    done < <(grep "^HOLE " <<<"${LINT_OUT}")
else
    echo "[user-image-extent] ${LINT_OUT##*$'\n'} — no intra-segment jumps"
fi

if (( RC != 0 )); then
    echo "[user-image-extent] FAIL" >&2
    exit 1
fi

echo "[user-image-extent] PASS — ${#IMAGES[@]} images, all PT_LOADs dense, all within ${USER_IMAGE_MAX_PAGES} pages, no script-level holes"
