# The ACPI Global Lock

**Issue:** R30.M8-001 (#1082)
**Implementation:** `src/user/aml/aml_glk.pdx`
**Corpus:** `tests/user/aml/aml_harness.c` §glk (8 fixtures)
**Gate:** `tools/verify-aml-parser.sh` — storage confinement, signature
pinning, and a byte-level assertion on the compare-exchange width.

---

## 1. What this exists to make true

> When this process touches a resource the firmware also touches,
> exactly one of the two is touching it, and whichever one finishes
> second was told the other had wanted it.

Both halves matter. The second is the one that gets skipped, and §5
explains why skipping it is the worst outcome available in this module.

## 2. Why this is not an ordinary mutex

`aml_ctl.pdx` already has one. `aml_mutex_pool` serializes AML's own
`Serialized` methods against each other, and it works because every
party to it is code in this process, and code in this process can be
made to wait.

**The other party here is System Management Mode, and it cannot be made
to wait.** An SMI preempts everything — ring 0, interrupts disabled,
NMIs, the lot. It does not schedule, it does not yield, and it does not
consult us. When firmware wants the embedded controller it takes it, and
the only thing between its transaction and ours is one 32-bit word.

Two consequences run through the whole design.

**The read-modify-write must be one atomic instruction.** A load, a
computation and a store is the same thing as a compare-exchange *most of
the time*, which is the worst possible property for a synchronisation
primitive. Firmware can land between any two of our instructions, so the
window between our load and our store is a window in which our store
overwrites a decision firmware already made.

**A fixture where the word never changes underneath us proves nothing.**
It exercises the arithmetic and skips the race — the only case the
protocol exists for. §7 describes the adversary this module ships in
consequence.

## 3. The protocol — ACPI 6.5 §5.2.10.1

The lock is a 32-bit field at FACS offset `0x10`:

| bit | name | meaning |
|---|---|---|
| 0 | `Owned` | someone holds the lock |
| 1 | `Pending` | someone else wants it and must be signalled |

```
ACQUIRE:
    do {
       old = *GL;
       new = (old & ~1) | 1;         // claim Owned
       if (old & 1) new |= 2;        // it was already held: register
    } while (cmpxchg(GL, old, new) != old);
    acquired = ((new & 2) == 0);

RELEASE:
    do {
       old = *GL;
       new = old & ~3;               // drop Owned AND Pending
    } while (cmpxchg(GL, old, new) != old);
    must_signal = ((old & 2) != 0);
```

`(old & ~1) | 1` is arithmetically just `old | 1`, and the code emits the
one-instruction form. The specification's spelling is kept in the
comment because the interesting conditional is the *next* line: **Pending
is set from the OLD value, not the new one.** That is the line a
reimplementation gets wrong.

### You acquired it only if `Pending` came back clear

A successful compare-exchange means our write landed. It does **not**
mean we hold the lock. If firmware held it, the value we successfully
wrote is one that says *"firmware holds it and we are waiting"* — a
correct write of a value that means we lost.

Treating a successful cmpxchg as a successful acquire is the single
easiest way to write this function wrongly, and it produces a driver
that transacts against the EC while SMM is mid-transaction on the same
registers. `aml_glk_try` returns `1` only when `(new & 2) == 0`.

## 4. 32-bit, and why that is load-bearing

The lock is the `u32` at FACS `0x10`. The FACS `Flags` field is the `u32`
at FACS `0x14`, immediately after it.

A 64-bit `lock cmpxchg` at `0x10` read-modify-writes **both** — it
carries `Flags` through our acquire arithmetic and stores it back, so any
firmware update to `Flags` landing inside our window is silently
reverted.

`lock_cmpxchg` and `lock_cmpxchg_d` differ by one character in the source
and by one `REX.W` bit in the machine code, and the wrong one assembles,
links, boots and works on every machine whose `Flags` never changes. So
the claim is asserted in **two** independent places:

* **Statically**, in `tools/verify-aml-parser.sh`: every compare-exchange
  emitted by `aml_glk.o` must carry the 32-bit opcode (`F0 [REX] 0F B1`)
  and none may carry the 64-bit one (`F0 REX.W 0F B1`). A vacuity guard
  requires at least two — the acquire loop and the release loop — so a
  refactor that deleted the atomic cannot satisfy the check trivially.

* **Dynamically**, in the corpus: `aml_glk_facs` reserves `+20` as a
  guard word stamped `0xF1A65ED5`, and every fixture asserts it survives.

## 5. The doorbell, and why omitting it is the worst bug here

If the value we replace on release had `Pending` set, some other party
asked for the lock while we held it and is waiting to be told it is
free. Telling it is a write of `GBL_RLS` to `PM1_CNT`.

**Skip that write and nothing breaks here.** Our acquire count balances,
our release count balances, our transactions complete, our tests pass.
What breaks is the *firmware*, which waits for a signal that never comes
and therefore stops servicing the things only it can service. On the T14
G4 that includes thermal response: the EC's fan and throttle policy is
driven through firmware paths that take this lock.

A machine that overheats because a doorbell write was skipped is the
failure this module is designed against, and it is designed against
twice: the write is on the release path, and `aml_glk_signals()` counts
it, so the corpus asserts **the doorbell rang** rather than asserting
that code which would ring it exists.

### The doorbell is a read-modify-write, not a store

`PM1_CNT` is a control register with live occupants. `SCI_EN` (bit 0) is
what keeps the machine in ACPI mode at all. Writing `0x0004` to it —
which is what "set `GBL_RLS`" looks like if you write the bit you mean —
**clears `SCI_EN` and drops the platform out of ACPI mode.** So
`aml_glk_signal` reads the register first and ORs.

And it masks `SLP_EN` (bit 13) out of the value written back. `SLP_EN` is
write-only and one-shot: writing 1 to it **initiates a sleep
transition**. It reads back as 0 on every part we know of, so the mask is
redundant on every part we know of — which is exactly the argument for
having it. The cost is one instruction; the failure it covers is the
machine suspending in the middle of an EC transaction.

## 6. Binding, and the arity discipline

```
aml_glk_attach(facs_va, pm1_cnt_port, pm1_sts_port) -> 1 | 0
aml_glk_enter() -> 1 held | 0 refused
aml_glk_leave() -> 1 released | 0 refused
```

**No defaults.** `aml_glk_attach` refuses any zero argument rather than
binding a placeholder, for the reason `aml_ec_attach` refuses a zero
port: a default FACS address is a compare-exchange against a guessed
word, and a default `PM1_CNT` port is a doorbell delivered to port 0 —
both are failures that look like success from inside. `bound` is set
last, so no acquire can observe a half-built binding.

**`enter` and `leave` take nothing, and `tools/verify-aml-parser.sh` pins
that verbatim.** There is exactly one Global Lock on a machine — it is a
platform singleton, not a resource with instances. A caller-supplied FACS
address would make "compare-exchange against a word that is not the
platform's lock" expressible, and code doing it would look correct while
serializing this process against nothing at all.

`leave` returns `u64` rather than unit because the release path *can*
refuse (underflow, unbound, compare-exchange stuck). A signature with
nowhere to put that answer invites discarding it silently at every future
call site rather than at the one that has an argument for it.

### Where the addresses come from

`FIRMWARE_CTRL` (FADT +36) / `X_FIRMWARE_CTRL` (FADT +132) give the FACS;
`PM1a_CNT_BLK` and `PM1a_EVT_BLK` give the ports. **None of the three is
plumbed to the AML bubble today.** `src/kernel/acpi/fadt.pdx` declares
`FADT_OFFSET_FIRMWARE_CTRL` and never reads it, and the supervisor wire
schema has no FACS field.

That gap is named here rather than papered over. The binding *interface*
is fixed by this milestone so the shape of what the supervisor must
supply is settled; the supervisor side is R31's, and until it lands the
only caller that attaches is the corpus.

## 7. Nesting

AML may acquire `\_GL` recursively, and ACPI requires OSPM to keep an
ownership count and touch the hardware only at the boundaries: taken at
0→1, dropped at 1→0.

This is not bookkeeping tidiness. **An inner release that dropped the
hardware lock would hand the EC to firmware in the middle of the outer
transaction**, and the outer caller would carry on driving registers it
no longer owned. The corruption appears in whatever firmware did with the
EC in the interval — somewhere else, later, in a subsystem that never
called us.

`aml_glk_nest_enters` / `nest_leaves` count exactly the recursive cases,
so "the nesting path was taken" is assertable rather than inferred from
the hardware counts staying put.

Depth is bounded at `AML_GLK_DEPTH_MAX = 32` and the bound is checked
**before** the increment, so an overflow can never be committed and then
noticed.

## 8. Bounded wait, then refuse

Firmware that never releases must produce a refusal, not a hang — the
discipline #1081 established for the EC's IBF/OBF waits, with the same
honest caveat: `AML_GLK_WAIT_MAX` is a bound on **work**, not on time.
This process has no clock. That is a limitation, and it is named here
rather than hidden behind a constant that looks like microseconds.

The refusal code is `AML_ERR_GLK_TIMEOUT` (77) and it is **distinct**
from `AML_ERR_EC_TIMEOUT_IBF` (69) and `AML_ERR_EC_TIMEOUT_OBF` (70).
Three codes because they are three different machine faults: the EC did
not take our byte, the EC did not answer, and *firmware will not let go*.
The first two are the EC; the third is not the EC's fault at all, and an
operator who conflated them would replace the wrong part.

**Waiting is not spinning on the word.** When firmware holds the lock we
have already registered `Pending`, and the thing that says it is free is
the *release signal* — `GBL_STS` in `PM1_STS`, which firmware raises as
an SCI when it drops a lock somebody was waiting on. Polling the lock
word instead would work by accident and keep working right up until a
firmware that batches its releases. `aml_glk_signalled()` reads the
signal; the wait loop reads `aml_glk_signalled()`.

A refusal does **not** withdraw `Pending`. When firmware eventually does
let go, its release still rings our doorbell; a refusal that had
withdrawn our interest would leave us permanently unnotified.

## 9. The adversary

`aml_glk_smm_step` is called on **every pass of every compare-exchange
loop, in both modes**, after the new value is computed and before it is
written — precisely where an SMI is a correctness problem and nowhere
else.

In hardware mode it observes and returns. In synthetic mode it *is* the
firmware: it mutates the lock word, from outside our sequence, in the
window our sequence is supposed to survive.

This is the `aml_ec_synth` arrangement (#1081) applied to a different
device. **The code under test is byte-identical in both modes** — the
call is unconditional and only the device behind it decides whether to
act — so every corpus assertion about the compare-exchange loop is an
assertion about the shipping loop. The cost in hardware mode is one call
per pass, and paying it unconditionally is what keeps the loop honest; a
version that branched around the call would be testing a different
instruction sequence than it ships.

### The interference is a toggle, not a store

`aml_glk_smm_arm(injections, mask)` applies `word ^= mask`. The choice is
not cosmetic.

**A store of a constant can collide at most once.** The first pass reads
`W`, firmware stores `V`, our compare-exchange expects `W` and fails. The
second pass reads `V`, firmware stores `V` again — the same value the
word already holds — and our compare-exchange expects `V` and succeeds.
Sustained contention is not expressible that way, so a store-based
adversary would leave the retry loop tested to a depth of one and the
retry *bound* never exercised at all.

A toggle is also the more faithful model. Firmware does not park a
constant in the lock word; it acquires and releases, which is exactly
bit 0 going up and down.

### What the adversary buys

With `lock_cmpxchg_d`, an injected mutation makes our write fail, we
retry, and we re-derive from what firmware actually left. With a
load/compute/store in its place, our store lands on top of firmware's
decision and it disappears — **and every other assertion in the corpus
still passes.** Three observables distinguish them, and all three are
asserted:

| | correct | non-atomic |
|---|---|---|
| `cas_retries` | ≥ 1 | 0 (a blind store cannot fail) |
| `aml_glk_try()` | 0 — did not acquire | 1 — claimed a lock firmware holds |
| lock word | `0x3` (firmware's Owned + our Pending) | `0x1` (firmware's write lost) |

## 10. The seam, and the balance assertion that survived it

R30.M7-003 (#1081) placed the seam in `aml_ec_xact` and made it count,
before the lock existed. #1082 put the real lock behind it.

The corpus asserted, when the seam could not fail:

```
glk_enters == glk_leaves == attempted
```

A real lock can be refused, so the invariant **generalises rather than
weakens**:

```
glk_enters == glk_leaves                 (still exact)
glk_enters + glk_denied == attempted     (the new accounting)
```

On every fixture where the lock is obtainable, `glk_denied` is 0 and the
original triple equality is recovered exactly. The test passes because
the property still holds, not because it was relaxed to fit. An
implementation that acquires the lock and leaks it on a timeout path
still fails the first equation, exactly as it was going to in #1081.

### A refused acquire refuses the transaction

`aml_ec_xact` now honours a failed `aml_ec_glk_enter`. A refused acquire
means **firmware holds the EC**; proceeding anyway would drive the same
registers SMM is mid-handshake on, which is the entire condition the lock
exists to prevent. So it is a refusal, not a retry and not a warning.

The refusal code is deliberately **not** overwritten: `aml_glk_enter` has
already latched the specific cause (76 `UNBOUND` / 77 `TIMEOUT` / 80
`CAS_STUCK`), and an EC-flavoured code stamped on top would tell an
operator to replace the embedded controller when the fault is firmware
holding a lock it will not release.

Note the asymmetry with every other refusal in `aml_ec_xact`: this one
releases the transaction claim but does **not** call `aml_ec_glk_leave`,
because nothing was acquired. That is what keeps `glk_enters ==
glk_leaves` exact.

## 11. Placement

`design/acpi/no-aml-in-kernel.md` forbids firmware bytecode in ring 0,
and this module exists to serve the AML bubble's OpRegion accesses. It
sits in `src/user/aml/` for the reason `aml_ec.pdx` does.

It contains **no port instruction**: the doorbell goes through
`aml_region_port_out`, which `tools/verify-aml-parser.sh` pins as one of
only two sites in userspace that may emit one.

## 12. Failure taxonomy

Continuing `aml_ec.pdx`'s 68..75:

| code | name | condition |
|---|---|---|
| 76 | `AML_ERR_GLK_UNBOUND` | no FACS has been attached |
| 77 | `AML_ERR_GLK_TIMEOUT` | firmware would not release; bounded out |
| 78 | `AML_ERR_GLK_UNDERFLOW` | release with no acquisition outstanding |
| 79 | `AML_ERR_GLK_DEPTH` | ownership count would exceed its bound |
| 80 | `AML_ERR_GLK_CAS_STUCK` | compare-exchange lost its race too often |

`UNDERFLOW` is a refusal and **not** a silent no-op: a release with
nothing outstanding means a caller's bracketing is broken, and the next
hardware release would be somebody else's.

`CAS_STUCK` exists because an adversary that mutates the word on every
single pass would otherwise keep a *correct* implementation looping
forever. That is a livelock rather than a hang, and it is no better.

## 13. Mutation results

Each guardrail was verified by inducing its failure.

| mutant | detected by | exact failure |
|---|---|---|
| release skips the `GBL_RLS` doorbell | corpus | `glk: the release doorbell: THE DOORBELL RANG — firmware was told the lock is free = 0x0, expected 0x1` |
| acquire uses load/compute/store | build gate | `[aml-parser] FAIL — aml_glk.o emits 1 32-bit LOCK CMPXCHG(s), expected at least 2` |
| — same mutant, gate bypassed | corpus | `glk: SMM mutates the lock word inside our read-modify-write: and we did NOT acquire it = 0x1, expected 0x0`; `firmware still owns it, and our interest is registered = 0x1, expected 0x3` |
| inner (nested) release drops the hardware lock | corpus | `glk: nested acquisition holds the hardware lock throughout: AND THE HARDWARE LOCK WAS NOT DROPPED = 0x1, expected 0x0` |
| the wait for firmware is unbounded | corpus watchdog | `[aml-corpus] FATAL — the corpus did not finish within 60s` |

## 14. References

* ACPI 6.5 §5.2.10.1 (Global Lock acquire/release), §4.8.3.2 (`PM1_CNT`).
* `design/acpi/embedded-controller.md` — the seam this replaces.
* `design/acpi/no-aml-in-kernel.md` §3 — why this is ring 3.
* `design/acpi/firmware-session-arbitration.md` — the arbitration one
  level up, where the parties are components of this OS rather than
  firmware.
