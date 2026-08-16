/* tests/fuzz/aml/aml_fuzz.c — R30.M9-001 (#1085)
 *
 * Structured, opcode-aware fuzzer for the userspace AML interpreter, and
 * the replay engine for the regression corpus it grows.
 *
 * WHY NOT BYTE FLIPPING
 * ---------------------
 * A fuzzer that flips random bytes in an AML stream produces inputs that
 * are overwhelmingly invalid. It therefore exercises the REJECT path
 * thousands of times and the EVALUATE path almost never, which measures
 * the tokenizer's error handling — not where the interesting bugs are.
 * The evaluator's guards (fuel, depth, frames, the arenas) can only be
 * pressed by input that survives the parser.
 *
 * So every mutation here is chosen to keep the stream PLAUSIBLE:
 *
 *   M1  PkgLength perturbation, re-encoded in the SAME number of bytes so
 *       the edit changes a declared extent rather than shifting every
 *       following offset (which would be a truncation wearing a disguise).
 *   M2  Opcode substitution within the same arity class AND the same
 *       encoding length, so the parse survives and the EVALUATOR is what
 *       meets the change.
 *   M3  NameString edits — the 4-character padding rule, the lead-char
 *       class, and the DualName/MultiName/root/parent prefixes.
 *   M4  Truncation at an OBJECT BOUNDARY (a node's recorded src_off),
 *       not at a random offset.
 *   M5  Deep nesting generated to straddle the depth cap (48) and the
 *       bounded frame pool (8).
 *
 * M1..M4 are driven by an actual parse of the buffer being mutated: node
 * offsets come from aml_node_src_off, and opcode substitution consults
 * the real aml_optab. That is what "opcode-aware" means here — the
 * mutator and the parser agree about where things are, so a mutant is a
 * different PROGRAM rather than a different pile of bytes.
 *
 * WHAT IS ASSERTED — INVARIANTS, NOT "DID NOT CRASH"
 * --------------------------------------------------
 * "It did not crash" is a weak oracle: it passes for an evaluator that
 * silently corrupts its arena. Every input, well-formed or not, is
 * checked against the resource contract instead. See
 * design/acpi/fuzz-strategy.md §3 for the full argument.
 *
 *   I1  FUEL. remaining <= budget <= 1000000, and it never increases
 *       across a call. A wrap would show up as remaining > budget.
 *   I2  DEPTH. peak depth <= 48, and depth unwinds to 0.
 *   I3  FRAMES. peak frame index <= 8, and frames unwind to 0.
 *
 *       BE PRECISE ABOUT WHAT I2/I3 CATCH. Both peaks are recorded
 *       AFTER the cap test admits the increment, so the peak can never
 *       exceed the cap that the .pdx actually implements — which means
 *       the `<=` comparisons here cannot fail on any input. What they
 *       DO catch is the .pdx immediate drifting away from the constant
 *       declared in this file: raise the cap in aml_eval.pdx and the
 *       peak climbs past DEPTH_CAP and this fires. That is a real and
 *       wanted regression check (mutation M6 in design/acpi/
 *       fuzz-strategy.md §3.4 is exactly it), but it is a cross-check
 *       between two declarations of the bound, NOT a per-input check
 *       that the evaluator stayed inside it.
 *
 *       The instrument that does per-input work on depth and frames is
 *       the MANIFEST exact-match: every corpus entry pins peak_depth
 *       and peak_frames to the value it produced, so any change to
 *       either is a failed replay that has to be explained.
 *   I4  ARENAS. Every cursor stays inside its fixed capacity.
 *   I5  INTEGRITY — no half-written object. Every allocated node and
 *       every allocated object is swept: kinds must be known, and every
 *       index a record holds (parent, first_child, next_sibling, name,
 *       heap base, element base) must be inside the arena that index
 *       refers to. A torn record — one whose child index names a node
 *       that was never allocated because the error unwound first — is
 *       precisely what this catches.
 *   I6  QUIESCENCE. Once the error latch is set, further evaluation
 *       allocates NOTHING. This is the honest form of "no partial
 *       mutation survives an error"; see the note below.
 *   I7  NO OVER-READ. Every fixture's last byte is the last byte of a
 *       mapped page, with PROT_NONE after it, so a read one byte past
 *       the buffer is a SIGSEGV naming the input rather than a silent
 *       over-read of adjacent heap.
 *   I8  PARSER DEPTH. aml_lex_depth() unwinds to 0.
 *
 * I5/I6 AND WHAT "NO PARTIAL MUTATION" CAN MEAN
 * ----------------------------------------------
 * There is no rollback anywhere in this subsystem, by design: the arena
 * cursors are monotonic within a session and nothing is ever freed. So
 * the literal reading of "a failed evaluation leaves nothing behind" is
 * FALSE here, and asserting it would produce a red corpus that says
 * nothing. It is also the wrong thing to want — ACPI methods have real
 * side effects, and a Store that completed before a later fault
 * genuinely did complete; unwinding it would be a lie told to firmware.
 *
 * The property that MUST hold, and that this asserts, is narrower and
 * sharper: no TORN RECORD (I5) and no post-error drift (I6). A committed
 * side effect is legitimate; a half-constructed object reachable from
 * the arena is a memory-safety bug, and an allocation that happens after
 * the error latch closed means aml_eval_spend's execution-blocking check
 * has a hole in it.
 *
 * CORPUS GROWTH
 * -------------
 * An input is promoted to a permanent corpus entry when it either trips
 * an invariant (always) or reaches an OUTCOME SIGNATURE — the
 * (parse_err, eval_err) pair — not yet represented. Each entry records
 * its full expected outcome vector in MANIFEST.tsv, so replay is an
 * exact-match regression test forever after, and the cost fields of that
 * vector are simultaneously the recorded baseline R30.M9-003 (#1087)
 * gates on.
 *
 * SEEDING
 * -------
 * Seeded from synthetic, structurally-valid fixtures built by this file.
 * The issue asks for a corpus seeded from real T14 G4 tables; that is
 * #1088, which requires physical access to the machine across three BIOS
 * revisions and is NOT satisfied here. No synthetic fixture in this
 * corpus is labelled as a hardware capture. See design/acpi/
 * fuzz-strategy.md §6.
 *
 * USAGE
 *   aml_fuzz replay <corpusdir>          — exact-match replay (the gate)
 *   aml_fuzz soak <corpusdir> <n> <seed> — mutate; promote; may write
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <signal.h>
#include <setjmp.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

/* ---------------------------------------------------------------- AML ABI */

extern void     aml_arena_reset(void);
extern void     aml_region_reset(void);
extern void     aml_ctl_reset(void);
extern uint64_t aml_parse(uint64_t buf, uint64_t len);
extern uint64_t aml_lex_err(void);
extern uint64_t aml_lex_depth(void);

extern uint64_t aml_node_count(void);
extern uint64_t aml_name_count(void);
extern uint64_t aml_u64_count(void);
extern uint64_t aml_node_kind(uint64_t i);
extern uint64_t aml_node_name(uint64_t i);
extern uint64_t aml_node_first_child(uint64_t i);
extern uint64_t aml_node_next_sibling(uint64_t i);
extern uint64_t aml_node_parent(uint64_t i);
extern uint64_t aml_node_src_off(uint64_t i);
extern uint64_t aml_method_argcount(uint64_t i);

extern void     aml_eval_reset(uint64_t revision);
extern uint64_t aml_eval_err(void);
extern uint64_t aml_eval_set_fuel(uint64_t budget);
extern uint64_t aml_eval_fuel(void);
extern uint64_t aml_eval_budget(void);
extern uint64_t aml_eval_depth(void);
extern uint64_t aml_eval_frames(void);
extern uint64_t aml_eval_depth_peak(void);
extern uint64_t aml_eval_frames_peak(void);
extern uint64_t aml_eval_method(uint64_t method_node);

extern uint64_t aml_obj_count(void);
extern uint64_t aml_obj_heap_used(void);
extern uint64_t aml_obj_elem_used(void);
extern uint64_t aml_obj_type(uint64_t o);
extern uint64_t aml_obj_base(uint64_t o);
extern uint64_t aml_obj_len(uint64_t o);

extern uint64_t aml_optab[];
extern uint64_t aml_optab_len;
extern uint64_t aml_optab_find(uint64_t op16);
extern uint64_t aml_optab_argc(uint64_t e);
extern uint64_t aml_optab_class(uint64_t e);

extern void     aml_glk_reset(void);
extern void     aml_ec_reset(void);

/* -------------------------------------------------------------- the bounds
 *
 * Hardcoded because the .pdx side declares them as bare immediates, not
 * as exported constants. That is itself a small hazard — these numbers
 * are duplicated here and in aml_eval.pdx / aml_arena.pdx / aml_obj.pdx —
 * so the seed corpus deliberately includes fixtures that press each cap,
 * and their recorded outcomes would change if a cap moved. */
#define FUEL_CEILING   1000000u
#define DEPTH_CAP      48u
#define FRAMES_CAP     8u
#define NODE_CAP       512u
#define NAME_CAP       512u
#define U64_CAP        128u
#define OBJ_CAP        512u
#define OBJ_HEAP_CAP   8192u
#define OBJ_ELEM_CAP   1024u
#define NODE_KIND_MAX  43u

/* The budget every fuzz evaluation runs under. Lower than the 1000000
 * default purely for soak throughput: the invariants under test hold at
 * any budget, and the value is recorded per corpus entry so replay is
 * exact regardless. */
#define FUZZ_FUEL      50000u

#define FZ_MAX_INPUT      4096

/* --------------------------------------------------------------- reporting */

static int         g_fail;
static uint64_t    g_checks;
static const char *g_case = "(none)";

static void fail(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[aml-fuzz] TRIP %s: ", g_case);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    g_fail++;
}

static void want(const char *what, uint64_t got, uint64_t expect)
{
    g_checks++;
    if (got != expect)
        fail("%s = %llu, expected %llu",
             what, (unsigned long long)got, (unsigned long long)expect);
}

static void want_le(const char *what, uint64_t got, uint64_t bound)
{
    g_checks++;
    if (got > bound)
        fail("%s = %llu exceeds bound %llu",
             what, (unsigned long long)got, (unsigned long long)bound);
}

/* ------------------------------------------------- guard-page fixture load
 *
 * Identical in intent to tests/user/aml/aml_harness.c: the fixture's last
 * byte is the last byte of a mapped region with PROT_NONE after it, so
 * invariant I7 is enforced by the MMU rather than by inspection. For a
 * fuzzer this matters more than for a fixed corpus — an over-read is the
 * single most likely finding, and it is invisible without this. */

static uint8_t *g_map;
static size_t   g_maplen;

static const uint8_t *guard_load(const uint8_t *data, size_t n)
{
    long ps = sysconf(_SC_PAGESIZE);
    size_t need = ((n + (size_t)ps - 1) / (size_t)ps) * (size_t)ps;
    if (need == 0) need = (size_t)ps;
    g_maplen = need + (size_t)ps;
    g_map = mmap(NULL, g_maplen, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g_map == MAP_FAILED) { perror("mmap"); exit(2); }
    if (mprotect(g_map + need, (size_t)ps, PROT_NONE) != 0) {
        perror("mprotect"); exit(2);
    }
    uint8_t *p = g_map + need - n;
    if (n) memcpy(p, data, n);
    return p;
}

static void guard_free(void)
{
    if (g_map) munmap(g_map, g_maplen);
    g_map = NULL;
}

static sigjmp_buf            g_jb;
static volatile sig_atomic_t g_armed;

static void on_segv(int sig)
{
    (void)sig;
    if (g_armed) siglongjmp(g_jb, 1);
    static const char msg[] =
        "[aml-fuzz] FATAL — SIGSEGV outside a guarded region\n";
    ssize_t w = write(2, msg, sizeof msg - 1); (void)w;
    _exit(97);
}

/* The evaluator's headline guarantee is termination. Losing it does not
 * produce a false assertion, it produces a fuzzer that never returns —
 * which in a pre-push hook is a wedged shell and no diagnosis at all. */
static void on_alarm(int sig)
{
    (void)sig;
    static const char msg[] =
        "[aml-fuzz] FATAL — did not finish in time; an evaluation guard "
        "(fuel, depth or frames) is not terminating\n";
    ssize_t w = write(2, msg, sizeof msg - 1); (void)w;
    _exit(96);
}

#define GUARDED(...)                                                        \
    do {                                                                    \
        g_armed = 1;                                                        \
        if (sigsetjmp(g_jb, 1) == 0) { __VA_ARGS__; }                       \
        else { fail("SIGSEGV — read past the end of the AML buffer"); }     \
        g_armed = 0;                                                        \
    } while (0)

/* ------------------------------------------------------------------- PRNG
 *
 * splitmix64. Deterministic and seedable: a soak that finds something is
 * reproducible from its seed alone, which is what makes "run it again
 * with --seed N" a usable instruction rather than a hope. */

static uint64_t g_rng;

static uint64_t rnd(void)
{
    uint64_t z = (g_rng += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

static uint64_t rnd_below(uint64_t n) { return n ? rnd() % n : 0; }

/* ---------------------------------------------------------- input buffers */

typedef struct { uint8_t b[FZ_MAX_INPUT]; size_t n; } buf_t;

static void b_init(buf_t *b) { b->n = 0; }

static void b_u8(buf_t *b, uint8_t v)
{
    if (b->n < FZ_MAX_INPUT) b->b[b->n++] = v;
}

static void b_raw(buf_t *b, const void *p, size_t n)
{
    if (b->n + n > FZ_MAX_INPUT) n = FZ_MAX_INPUT - b->n;
    memcpy(b->b + b->n, p, n);
    b->n += n;
}

static void b_seg(buf_t *b, const char *s)   /* a 4-character NameSeg */
{
    for (int i = 0; i < 4; i++) b_u8(b, (uint8_t)s[i]);
}

/* §20.2.4 PkgLength covering `payload` bytes PLUS its own encoding. */
static size_t emit_pkglen(uint8_t *out, size_t payload)
{
    static const size_t lim[5] = { 0, 63, 0xFFF, 0xFFFFF, 0xFFFFFFF };
    for (int n = 1; n <= 4; n++) {
        size_t v = payload + (size_t)n;
        if (v <= lim[n]) {
            if (n == 1) { out[0] = (uint8_t)v; return 1; }
            out[0] = (uint8_t)(((size_t)(n - 1) << 6) | (v & 0x0F));
            for (int i = 1; i < n; i++)
                out[i] = (uint8_t)((v >> (4 + 8 * (i - 1))) & 0xFF);
            return (size_t)n;
        }
    }
    return 0;
}

/* op + PkgLength + body. `op` below 0x100 is a one-byte opcode; at or
 * above it, a 0x5B escape followed by the low byte. */
static void b_pkg(buf_t *d, uint16_t op, const buf_t *body)
{
    uint8_t pl[4];
    size_t  npl = emit_pkglen(pl, body->n);
    if (op >= 0x100) { b_u8(d, 0x5B); b_u8(d, (uint8_t)(op & 0xFF)); }
    else             { b_u8(d, (uint8_t)op); }
    b_raw(d, pl, npl);
    b_raw(d, body->b, body->n);
}

/* ============================================================ the seed set
 *
 * Structurally valid AML exercising the constructs whose evaluation can
 * actually press a bound: arithmetic, a bounded loop, method invocation,
 * packages and buffers, and a self-recursive method. Mutants descend from
 * these, so the seeds decide what the fuzzer is able to reach at all. */

/* Method(<nm>, <argc>) { <body> } */
static void seed_method(buf_t *d, const char *nm, uint8_t flags,
                        const buf_t *body)
{
    buf_t t; b_init(&t);
    b_seg(&t, nm);
    b_u8(&t, flags);
    b_raw(&t, body->b, body->n);
    b_pkg(d, 0x14, &t);
}

/* S1 — arithmetic and a literal return. The simple-method baseline. */
static void seed_arith(buf_t *out)
{
    buf_t body; b_init(&body);
    b_u8(&body, 0xA4);                       /* ReturnOp                 */
    b_u8(&body, 0x72);                       /*   Add(                   */
    b_u8(&body, 0x0A); b_u8(&body, 0x2A);    /*     0x2A,                */
    b_u8(&body, 0x0A); b_u8(&body, 0x11);    /*     0x11,                */
    b_u8(&body, 0x00);                       /*     Zero)  [no target]   */
    b_init(out);
    seed_method(out, "MAR0", 0x00, &body);
}

/* S2 — a bounded While. Presses fuel without ever failing to terminate. */
static void seed_loop(buf_t *out)
{
    buf_t pred; b_init(&pred);
    b_u8(&pred, 0x95);                       /* LLessOp                  */
    b_u8(&pred, 0x60);                       /*   Local0,                */
    b_u8(&pred, 0x0A); b_u8(&pred, 0x20);    /*   0x20                   */

    buf_t wbody; b_init(&wbody);
    b_u8(&wbody, 0x72);                      /* Add(                     */
    b_u8(&wbody, 0x60);                      /*   Local0,                */
    b_u8(&wbody, 0x01);                      /*   One,                   */
    b_u8(&wbody, 0x60);                      /*   Local0)                */

    buf_t wpkg; b_init(&wpkg);
    b_raw(&wpkg, pred.b, pred.n);
    b_raw(&wpkg, wbody.b, wbody.n);

    buf_t body; b_init(&body);
    b_u8(&body, 0x70); b_u8(&body, 0x00); b_u8(&body, 0x60);  /* Local0=0 */
    b_pkg(&body, 0xA2, &wpkg);                                /* While    */
    b_u8(&body, 0xA4); b_u8(&body, 0x60);                     /* Return   */

    b_init(out);
    seed_method(out, "MLP0", 0x00, &body);
}

/* S3 — Name declaration plus a method that reads it. Exercises namespace
 * resolution, which is what NameString mutation (M3) aims at. */
static void seed_named(buf_t *out)
{
    b_init(out);
    b_u8(out, 0x08);                          /* NameOp                  */
    b_seg(out, "VAL0");
    b_u8(out, 0x0C);                          /* DWordPrefix             */
    b_u8(out, 0x78); b_u8(out, 0x56); b_u8(out, 0x34); b_u8(out, 0x12);

    buf_t body; b_init(&body);
    b_u8(&body, 0xA4);                        /* Return(                 */
    b_seg(&body, "VAL0");                     /*   VAL0)                 */
    seed_method(out, "MRD0", 0x00, &body);
}

/* S4 — If/Else. The branch that is NOT taken still has to parse, which is
 * where a PkgLength edit (M1) does its most interesting damage. */
static void seed_branch(buf_t *out)
{
    buf_t ipkg; b_init(&ipkg);
    b_u8(&ipkg, 0x01);                        /* predicate One           */
    b_u8(&ipkg, 0x70); b_u8(&ipkg, 0x0A); b_u8(&ipkg, 0x07);
    b_u8(&ipkg, 0x60);                        /* Local0 = 7              */

    buf_t epkg; b_init(&epkg);
    b_u8(&epkg, 0x70); b_u8(&epkg, 0x0A); b_u8(&epkg, 0x09);
    b_u8(&epkg, 0x60);                        /* Local0 = 9              */

    buf_t body; b_init(&body);
    b_pkg(&body, 0xA0, &ipkg);                /* IfOp                    */
    b_pkg(&body, 0xA1, &epkg);                /* ElseOp                  */
    b_u8(&body, 0xA4); b_u8(&body, 0x60);     /* Return(Local0)          */

    b_init(out);
    seed_method(out, "MIF0", 0x00, &body);
}

/* S5 — a Package of literals. Presses the object arena and the element
 * table rather than the node arena. */
static void seed_package(buf_t *out)
{
    buf_t pk; b_init(&pk);
    b_u8(&pk, 0x04);                          /* NumElements = 4         */
    for (int i = 0; i < 4; i++) { b_u8(&pk, 0x0A); b_u8(&pk, (uint8_t)(i + 1)); }

    buf_t body; b_init(&body);
    b_u8(&body, 0xA4);                        /* Return(                 */
    b_pkg(&body, 0x12, &pk);                  /*   Package{1,2,3,4})     */

    b_init(out);
    seed_method(out, "MPK0", 0x00, &body);
}

/* S6 — a self-recursive method. The frame pool (8) is reached before the
 * depth cap (48), which is the ordering aml_eval.pdx's header asserts;
 * this seed is what keeps that claim under test. */
static void seed_recursive(buf_t *out)
{
    buf_t body; b_init(&body);
    b_u8(&body, 0xA4);                        /* Return(                 */
    b_seg(&body, "MRC0");                     /*   MRC0())               */
    b_init(out);
    seed_method(out, "MRC0", 0x00, &body);
}

/* S7 — nested Scopes. The parser's own depth counter, distinct from the
 * evaluator's, and the natural home for M4 truncation. */
static void seed_nested(buf_t *out)
{
    buf_t inner; b_init(&inner);
    b_u8(&inner, 0x08); b_seg(&inner, "DEEP");
    b_u8(&inner, 0x0A); b_u8(&inner, 0x2A);

    for (int d = 0; d < 6; d++) {
        buf_t sc; b_init(&sc);
        char nm[5]; snprintf(nm, sizeof nm, "SC%02d", d);
        b_seg(&sc, nm);
        b_raw(&sc, inner.b, inner.n);
        buf_t wrapped; b_init(&wrapped);
        b_pkg(&wrapped, 0x10, &sc);           /* ScopeOp                 */
        inner = wrapped;
    }
    *out = inner;
}

/* S8 — TWO METHODS, THE FIRST OF WHICH FAULTS.
 *
 * This seed exists specifically to make invariant I6 (quiescence) bite.
 * I6 compares arena cursors across method boundaries AFTER the error
 * latch has closed, so it can only observe anything on an input with at
 * least two methods where an early one fails. Every other seed declares
 * a single method, which would leave I6 asserting over an empty set —
 * passing, and proving nothing.
 *
 * MBAD divides by zero (AML_ERR_DIVIDE_BY_ZERO, 34) at EVALUATION time,
 * not parse time, which is the distinction that matters: a parse failure
 * would stop the session before any method ran and there would be no
 * "after the latch" to observe. MGD0 then must allocate nothing —
 * aml_eval_spend refuses on a latched error, so a post-error allocation
 * would mean some path reaches the arena without passing that gate.
 *
 * MGD0 RETURNS A PACKAGE, and that is not an arbitrary choice. An
 * arithmetic body would allocate no object records at all, so I6's
 * comparison would hold trivially whether the gate worked or not — the
 * invariant would be decoration. A Package allocates an object record
 * AND element slots, so if the gate ever stopped blocking, the cursors
 * move and I6 says so. Verified by mutation: neutralising the
 * error check in aml_eval_spend fires I6 on this fixture. */
static void seed_two_methods(buf_t *out)
{
    b_init(out);

    buf_t bad; b_init(&bad);
    b_u8(&bad, 0x78);                         /* DivideOp                */
    b_u8(&bad, 0x01);                         /*   dividend One          */
    b_u8(&bad, 0x00);                         /*   divisor  Zero  <- !   */
    b_u8(&bad, 0x00);                         /*   remainder (discard)   */
    b_u8(&bad, 0x00);                         /*   quotient  (discard)   */
    seed_method(out, "MBAD", 0x00, &bad);

    buf_t pk; b_init(&pk);
    b_u8(&pk, 0x04);                          /* NumElements = 4         */
    for (int i = 0; i < 4; i++) { b_u8(&pk, 0x0A); b_u8(&pk, (uint8_t)(i + 7)); }

    buf_t good; b_init(&good);
    b_u8(&good, 0xA4);                        /* Return(                 */
    b_pkg(&good, 0x12, &pk);                  /*   Package{7,8,9,10})    */
    seed_method(out, "MGD0", 0x00, &good);
}

typedef void (*seed_fn)(buf_t *);

static const struct { const char *name; seed_fn fn; } g_seeds[] = {
    { "arith",     seed_arith     },
    { "loop",      seed_loop      },
    { "named",     seed_named     },
    { "branch",    seed_branch    },
    { "package",   seed_package   },
    { "recursive", seed_recursive },
    { "nested",    seed_nested    },
    { "twometh",   seed_two_methods },
};
#define NSEEDS (sizeof g_seeds / sizeof g_seeds[0])

/* ==================================================== the structure map
 *
 * Derived from an actual parse, which is what separates this from a byte
 * fuzzer: the mutators edit positions the PARSER agrees are opcodes and
 * object starts, so a mutant is a different program rather than noise. */

#define MAX_SITES 256

typedef struct {
    size_t   off;        /* byte offset of the node's opcode             */
    uint16_t op;         /* op16 as the optab spells it                  */
    uint8_t  oplen;      /* 1, or 2 for a 0x5B escape                    */
} site_t;

typedef struct { site_t s[MAX_SITES]; size_t n; } map_t;

/* True for the opcodes whose grammar puts a PkgLength immediately after
 * the opcode. Kept as an explicit list rather than inferred from optab
 * flags because no single flag bit means "has a PkgLength" — BufferOp
 * carries one without F_NAMESTR, and reading a neighbouring bit would be
 * a guess that happened to work. */
static int op_has_pkglen(uint16_t op)
{
    switch (op) {
    case 0x10:  /* Scope     */ case 0x11:  /* Buffer    */
    case 0x12:  /* Package   */ case 0x13:  /* VarPackage */
    case 0x14:  /* Method    */ case 0xA0:  /* If        */
    case 0xA1:  /* Else      */ case 0xA2:  /* While     */
    /* NOTE: ExternalOp (0x15) is deliberately NOT here. Its grammar is
     * `ExternalOp NameString ObjectType ArgumentCount` — no PkgLength.
     * It was listed once; the effect was harmless (the write is
     * bounds-checked and merely became a different arbitrary edit) but
     * it made mut_pkglen misreport what it was doing. */
    case 0x182: /* Device    */ case 0x181: /* Field     */
    case 0x183: /* Processor */ case 0x184: /* PowerRes  */
    case 0x185: /* ThermalZone */ case 0x186: /* IndexField */
    case 0x187: /* BankField */
        return 1;
    default:
        return 0;
    }
}

static void map_build(map_t *m, const uint8_t *buf, size_t len)
{
    m->n = 0;
    uint64_t nc = aml_node_count();
    for (uint64_t i = 1; i < nc && m->n < MAX_SITES; i++) {
        uint64_t off = aml_node_src_off(i);
        if (off >= len) continue;
        uint8_t  b0    = buf[off];
        uint8_t  oplen = (b0 == 0x5B) ? 2 : 1;
        if (off + oplen > len) continue;
        uint16_t op    = (b0 == 0x5B) ? (uint16_t)(0x100 | buf[off + 1])
                                      : (uint16_t)b0;
        /* De-duplicate: several node kinds can share a source offset. */
        int seen = 0;
        for (size_t k = 0; k < m->n; k++)
            if (m->s[k].off == off) { seen = 1; break; }
        if (seen) continue;
        m->s[m->n].off   = off;
        m->s[m->n].op    = op;
        m->s[m->n].oplen = oplen;
        m->n++;
    }
}

/* ===================================================== the mutation set */

/* M1 — PERTURB A PkgLength.
 *
 * Re-encoded in the SAME number of bytes, so the edit changes a declared
 * extent and nothing else; a re-encoding that changed width would shift
 * every following offset and be a truncation in disguise.
 *
 * ON DIRECTION. §20.2.5.4 makes a package whose initialiser list is
 * SHORTER than its declared element count legal — the remainder is
 * uninitialised, not malformed — so "declared extent disagrees with
 * content" is not by itself a defect and must not be asserted as one.
 * The sound check is the other direction: a PkgLength that reaches
 * BEYOND the enclosing extent or the buffer must be refused, and refused
 * without having read past the end. Both directions are generated; only
 * the overrun direction carries an expectation, and that expectation is
 * I7 (no over-read) plus a latched error — never a specific error code,
 * because several are legitimate. */
static void mut_pkglen(buf_t *b, const map_t *m)
{
    size_t cand[MAX_SITES], nc = 0;
    for (size_t i = 0; i < m->n; i++)
        if (op_has_pkglen(m->s[i].op)) cand[nc++] = i;
    if (!nc) return;

    const site_t *s = &m->s[cand[rnd_below(nc)]];
    size_t p = s->off + s->oplen;
    if (p >= b->n) return;

    uint8_t lead   = b->b[p];
    int     nbytes = (lead >> 6) + 1;
    if (p + (size_t)nbytes > b->n) return;

    /* Decode, perturb, re-encode into exactly `nbytes`. */
    uint64_t v;
    if (nbytes == 1) v = lead & 0x3F;
    else {
        v = lead & 0x0F;
        for (int i = 1; i < nbytes; i++)
            v |= (uint64_t)b->b[p + i] << (4 + 8 * (i - 1));
    }

    switch (rnd_below(5)) {
    case 0: v += 1;                    break;  /* just past the content   */
    case 1: v = (v > 1) ? v - 1 : 0;   break;  /* just short of it        */
    case 2: v += 0x20;                 break;  /* well beyond the buffer  */
    case 3: v = 0;                     break;  /* degenerate              */
    default: v = (uint64_t)nbytes;     break;  /* covers only itself      */
    }

    uint64_t cap = (nbytes == 1) ? 0x3Full
                 : (nbytes == 2) ? 0xFFFull
                 : (nbytes == 3) ? 0xFFFFFull : 0xFFFFFFFull;
    v &= cap;

    if (nbytes == 1) b->b[p] = (uint8_t)v;
    else {
        b->b[p] = (uint8_t)(((nbytes - 1) << 6) | (v & 0x0F));
        for (int i = 1; i < nbytes; i++)
            b->b[p + i] = (uint8_t)((v >> (4 + 8 * (i - 1))) & 0xFF);
    }
}

/* M2 — SUBSTITUTE AN OPCODE WITHIN ITS ARITY CLASS.
 *
 * The replacement is drawn from the REAL optab and must match on argc,
 * on class, and on encoding length. Matching argc is what keeps the
 * parse alive past the edit: the byte after an operator is an argument
 * or a statement depending solely on the count, so a substitution that
 * changed it would desynchronise the stream and we would be back to
 * testing the reject path. Matching encoding length keeps every later
 * offset where the map says it is. */
static void mut_opcode(buf_t *b, const map_t *m)
{
    if (!m->n) return;
    const site_t *s = &m->s[rnd_below(m->n)];
    uint64_t self = aml_optab_find(s->op);
    if (!self) return;

    uint64_t argc  = aml_optab_argc(self);
    uint64_t klass = aml_optab_class(self);

    uint16_t cand[512]; size_t nc = 0;
    for (uint64_t i = 0; i < aml_optab_len && nc < 512; i++) {
        uint64_t e  = aml_optab[i];
        uint16_t op = (uint16_t)(e & 0xFFFF);
        if (op == s->op) continue;
        if (aml_optab_argc(e) != argc)  continue;
        if (aml_optab_class(e) != klass) continue;
        int elen = (op >= 0x100) ? 2 : 1;
        if (elen != s->oplen) continue;
        cand[nc++] = op;
    }
    if (!nc) return;

    /* The map is built once and shared by up to three sequential edits,
     * so a preceding mut_truncate may have shrunk the buffer out from
     * under this site. Without the check the write is still memory-safe
     * (s->off is bounded by the pre-truncation length) but lands in the
     * dead tail past b->n and is silently discarded — an edit budget of
     * three quietly delivering fewer. mut_pkglen and mut_namestring
     * already bounds-check; this brings the third into line. */
    if (s->off + s->oplen > b->n) return;

    uint16_t rep = cand[rnd_below(nc)];
    if (s->oplen == 1) b->b[s->off] = (uint8_t)rep;
    else               b->b[s->off + 1] = (uint8_t)(rep & 0xFF);
}

/* M3 — EDIT A NameString.
 *
 * NameSegs are exactly four characters, blank-padded with '_', with a
 * lead character drawn from [A-Z_] and the rest from [A-Z0-9_]. The
 * padding rule is the interesting one: it is the place a parser is most
 * likely to accept a three-character segment and silently consume the
 * following opcode as the fourth. The prefix bytes (root, parent,
 * DualName, MultiName) turn a single segment into a path, which is the
 * other half of the grammar. */
static void mut_namestring(buf_t *b, const map_t *m)
{
    (void)m;
    /* Locate a plausible NameSeg: four bytes from the legal alphabet. */
    size_t cand[FZ_MAX_INPUT]; size_t nc = 0;
    for (size_t i = 0; i + 4 <= b->n && nc < FZ_MAX_INPUT; i++) {
        uint8_t c0 = b->b[i];
        if (!((c0 >= 'A' && c0 <= 'Z') || c0 == '_')) continue;
        int ok = 1;
        for (int k = 1; k < 4; k++) {
            uint8_t c = b->b[i + k];
            if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
                { ok = 0; break; }
        }
        if (ok) cand[nc++] = i;
    }
    if (!nc) return;

    size_t p = cand[rnd_below(nc)];
    switch (rnd_below(6)) {
    case 0:  /* a digit in the LEAD position — illegal, must be refused */
        b->b[p] = (uint8_t)('0' + rnd_below(10));
        break;
    case 1:  /* a byte outside the alphabet entirely                    */
        b->b[p + 1 + rnd_below(3)] = (uint8_t)(0x80 | rnd_below(0x7F));
        break;
    case 2:  /* rewrite as padded — the 4-character rule head-on        */
        b->b[p + 1] = '_'; b->b[p + 2] = '_'; b->b[p + 3] = '_';
        break;
    case 3:  /* claim a dual-name path where one segment lives          */
        b->b[p] = 0x2E;
        break;
    case 4:  /* claim a multi-name path with an arbitrary count         */
        b->b[p] = 0x2F;
        b->b[p + 1] = (uint8_t)rnd_below(0x10);
        break;
    default: /* root or parent prefix                                   */
        b->b[p] = (rnd_below(2)) ? 0x5C : 0x5E;
        break;
    }
}

/* M4 — TRUNCATE AT AN OBJECT BOUNDARY.
 *
 * At a node's src_off, or immediately after its opcode. Both are places
 * the parser has just committed to reading something more; a random
 * offset would usually land inside a literal, where truncation is far
 * less interesting because the length checks that guard literals are the
 * shallowest ones in the file. */
static void mut_truncate(buf_t *b, const map_t *m)
{
    if (!m->n) { if (b->n > 1) b->n--; return; }
    const site_t *s = &m->s[rnd_below(m->n)];
    size_t cut = (rnd_below(2)) ? s->off : s->off + s->oplen;
    if (cut == 0) cut = 1;
    if (cut < b->n) b->n = cut;
}

/* M5 — GENERATE DEEP NESTING.
 *
 * Aimed squarely at the two caps. `depth` straddles 48 so both the
 * accepted and the refused side are generated; a generator that only
 * ever exceeded the cap would never witness that a legal depth is still
 * admitted, which is the half that a too-tight guard breaks. */
static void gen_nested(buf_t *out, unsigned depth)
{
    buf_t inner; b_init(&inner);
    b_u8(&inner, 0x70); b_u8(&inner, 0x0A); b_u8(&inner, 0x2A);
    b_u8(&inner, 0x60);                       /* Local0 = 0x2A           */

    for (unsigned d = 0; d < depth; d++) {
        buf_t ip; b_init(&ip);
        b_u8(&ip, 0x01);                      /* predicate One           */
        b_raw(&ip, inner.b, inner.n);
        buf_t w; b_init(&w);
        b_pkg(&w, 0xA0, &ip);                 /* IfOp                    */
        if (w.n >= FZ_MAX_INPUT - 32) break;
        inner = w;
    }

    buf_t body; b_init(&body);
    b_raw(&body, inner.b, inner.n);
    b_u8(&body, 0xA4); b_u8(&body, 0x60);     /* Return(Local0)          */

    b_init(out);
    seed_method(out, "MDP0", 0x00, &body);
}

/* ================================================== running one input */

typedef struct {
    uint64_t parse_err;
    uint64_t eval_err;
    uint64_t peak_depth;
    uint64_t peak_frames;
    uint64_t fuel_spent;
    uint64_t nodes;
    uint64_t objs;
    uint64_t budget;
} outcome_t;

/* I5 — the integrity sweep. Every allocated record is examined, error or
 * not. A torn record is one whose index fields name storage that was
 * never allocated; that is what a half-built object looks like from the
 * outside, and it is invisible to any "did it crash" oracle. */
static void sweep_integrity(size_t len)
{
    uint64_t nc = aml_node_count();
    uint64_t mc = aml_name_count();
    for (uint64_t i = 1; i < nc; i++) {
        uint64_t k = aml_node_kind(i);
        g_checks++;
        if (k == 0 || k > NODE_KIND_MAX)
            fail("node %llu has unknown kind %llu",
                 (unsigned long long)i, (unsigned long long)k);
        g_checks++;
        if (aml_node_parent(i) >= nc)
            fail("node %llu parent index %llu is outside the arena (%llu)",
                 (unsigned long long)i,
                 (unsigned long long)aml_node_parent(i),
                 (unsigned long long)nc);
        g_checks++;
        if (aml_node_first_child(i) >= nc)
            fail("node %llu first_child %llu is outside the arena",
                 (unsigned long long)i,
                 (unsigned long long)aml_node_first_child(i));
        g_checks++;
        if (aml_node_next_sibling(i) >= nc)
            fail("node %llu next_sibling %llu is outside the arena",
                 (unsigned long long)i,
                 (unsigned long long)aml_node_next_sibling(i));
        g_checks++;
        if (aml_node_name(i) >= mc)
            fail("node %llu name_ref %llu is outside the name arena (%llu)",
                 (unsigned long long)i,
                 (unsigned long long)aml_node_name(i),
                 (unsigned long long)mc);
        g_checks++;
        if (aml_node_src_off(i) > len)
            fail("node %llu src_off %llu is past the input (%zu)",
                 (unsigned long long)i,
                 (unsigned long long)aml_node_src_off(i), len);
    }

    uint64_t oc = aml_obj_count();
    uint64_t hu = aml_obj_heap_used();
    for (uint64_t o = 1; o < oc; o++) {
        uint64_t t = aml_obj_type(o);
        g_checks++;
        if (!((t <= 14) || t == 20))
            fail("object %llu has unknown type %llu",
                 (unsigned long long)o, (unsigned long long)t);
        /* Strings and buffers carry a heap extent; it must be inside the
         * heap that was actually allocated. */
        if (t == 2 || t == 3) {
            uint64_t base = aml_obj_base(o);
            uint64_t l    = aml_obj_len(o);
            g_checks++;
            if (base > hu || l > hu || base + l > hu)
                fail("object %llu heap extent [%llu,+%llu) escapes the heap "
                     "high-water mark %llu", (unsigned long long)o,
                     (unsigned long long)base, (unsigned long long)l,
                     (unsigned long long)hu);
        }
    }
}

static void run_input(const uint8_t *data, size_t n, outcome_t *o,
                      uint64_t budget)
{
    memset(o, 0, sizeof *o);
    o->budget = budget;

    /* Full reset of every piece of session state, so an outcome is a
     * function of the input alone. Without the region and control resets
     * a table that filled the region table would silently change the
     * verdict on every later input, and replay would stop being exact. */
    aml_region_reset();
    aml_ctl_reset();
    aml_arena_reset();
    /* The Global Lock and EC modules are LINKED IN, and both hold
     * mutable module-scoped state. Nothing in the evaluator reaches them
     * today — there is no call into aml_glk_* or aml_ec_* from
     * aml_eval/aml_region/aml_term — so omitting these is currently
     * harmless. It would stop being harmless the moment a Field with
     * Lock=1 becomes evaluable, which is exactly what #1082/#1086 are
     * building toward, and the failure would be a replay-order
     * dependency inside the gate: entry N's verdict changing because
     * entry N-1 left a lock depth behind. Two lines now, rather than a
     * flaky gate later. */
    aml_glk_reset();
    aml_ec_reset();

    const uint8_t *b = guard_load(data, n);
    volatile uint64_t root = 0;

    GUARDED(root = aml_parse((uint64_t)(uintptr_t)b, (uint64_t)n));
    (void)root;
    o->parse_err = aml_lex_err();

    /* I8 — the parser's own depth counter unwinds on every path. */
    want("parser depth unwound", aml_lex_depth(), 0);

    aml_eval_reset(2);
    aml_eval_set_fuel(budget);

    /* VOLATILE IS LOAD-BEARING, NOT DECORATION. Everything below is live
     * across the sigsetjmp inside GUARDED, so a compiler that kept it in
     * a callee-saved register would be free to leave it indeterminate on
     * the siglongjmp path — the exact path taken when an over-read fires,
     * i.e. the case this fuzzer exists to report accurately. -Wclobbered
     * flags each one. */
    volatile uint64_t prev_fuel = aml_eval_fuel();
    uint64_t nc = aml_node_count();

    /* Evaluate every zero-argument method, in index order. Zero-argument
     * because a method with parameters needs a call site to supply them,
     * and inventing arguments would make the outcome a function of this
     * file rather than of the input. */
    /* THE LATCH MAY ALREADY BE CLOSED BEFORE THE FIRST METHOD RUNS.
     * aml_eval_reset SEEDS the evaluation error slot from the parse
     * latch, so for any input that failed to parse the session starts
     * already-failed. Initialising `latched` to 0 here would snapshot the
     * quiescence baseline only AFTER method #1 had run — baking any
     * post-latch allocation it made into the baseline instead of
     * catching it, and giving the first method a free pass on precisely
     * the inputs most likely to provoke one. */
    volatile int      latched = (aml_eval_err() != 0);
    volatile uint64_t q_nodes = latched ? aml_node_count()    : 0;
    volatile uint64_t q_objs  = latched ? aml_obj_count()     : 0;
    volatile uint64_t q_heap  = latched ? aml_obj_heap_used() : 0;
    volatile uint64_t q_elem  = latched ? aml_obj_elem_used() : 0;

    for (volatile uint64_t i = 1; i < nc; i++) {
        if (aml_node_kind(i) != 4 /* N_METHOD */) continue;
        if (aml_method_argcount(i) != 0) continue;

        GUARDED(aml_eval_method(i));

        /* I1 — fuel never increases, and never exceeds its budget. */
        uint64_t f = aml_eval_fuel();
        g_checks++;
        if (f > prev_fuel)
            fail("fuel rose from %llu to %llu",
                 (unsigned long long)prev_fuel, (unsigned long long)f);
        want_le("fuel <= budget", f, aml_eval_budget());
        prev_fuel = f;

        /* I6 — quiescence. Once the latch is set, nothing further may be
         * allocated. Snapshot at the transition, compare on every later
         * iteration. This is the honest form of "no partial mutation
         * survives an error": not that side effects unwind, but that the
         * execution-blocking check in aml_eval_spend has no hole. */
        if (!latched && aml_eval_err() != 0) {
            latched = 1;
            q_nodes = aml_node_count();
            q_objs  = aml_obj_count();
            q_heap  = aml_obj_heap_used();
            q_elem  = aml_obj_elem_used();
        } else if (latched) {
            want("post-error node arena is quiescent", aml_node_count(), q_nodes);
            want("post-error object arena is quiescent", aml_obj_count(), q_objs);
            want("post-error object heap is quiescent", aml_obj_heap_used(), q_heap);
            want("post-error element table is quiescent", aml_obj_elem_used(), q_elem);
        }
    }

    o->eval_err    = aml_eval_err();
    o->peak_depth  = aml_eval_depth_peak();
    o->peak_frames = aml_eval_frames_peak();
    o->fuel_spent  = aml_eval_budget() - aml_eval_fuel();
    o->nodes       = aml_node_count();
    o->objs        = aml_obj_count();

    /* I2 / I3 — the caps, asserted against the PEAK rather than against
     * the post-unwind reading, which is always zero and would make this
     * pass with the guards deleted. */
    want_le("peak evaluation depth", o->peak_depth, DEPTH_CAP);
    want_le("peak frame index",      o->peak_frames, FRAMES_CAP);
    want("evaluation depth unwound", aml_eval_depth(), 0);
    want("frames unwound",           aml_eval_frames(), 0);

    /* I4 — every arena cursor inside its fixed capacity. */
    want_le("node arena",    aml_node_count(),     NODE_CAP);
    want_le("name arena",    aml_name_count(),     NAME_CAP);
    want_le("u64 arena",     aml_u64_count(),      U64_CAP);
    want_le("object arena",  aml_obj_count(),      OBJ_CAP);
    want_le("object heap",   aml_obj_heap_used(),  OBJ_HEAP_CAP);
    want_le("element table", aml_obj_elem_used(),  OBJ_ELEM_CAP);
    want_le("fuel budget",   aml_eval_budget(),    FUEL_CEILING);

    /* I5 — no torn record. */
    sweep_integrity(n);

    guard_free();
}

/* ================================================== the corpus on disk */

#define MAX_ENTRIES 512

typedef struct {
    char      name[64];
    outcome_t o;
} entry_t;

static entry_t g_entries[MAX_ENTRIES];
static size_t  g_nentries;

static int manifest_load(const char *dir)
{
    char path[512];
    snprintf(path, sizeof path, "%s/MANIFEST.tsv", dir);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        entry_t e;
        memset(&e, 0, sizeof e);
        /* Scan into real `unsigned long long` locals and assign across.
         * Writing through (unsigned long long *)&<uint64_t field> is a
         * type pun that happens to match in size and alignment on LP64;
         * it works, and it costs nothing to not rely on it. */
        unsigned long long pe, ee, pd, pf, fs, nd, ob, bg;
        if (sscanf(line,
                   "%63s\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu",
                   e.name, &pe, &ee, &pd, &pf, &fs, &nd, &ob, &bg) == 9) {
            e.o.parse_err   = pe;
            e.o.eval_err    = ee;
            e.o.peak_depth  = pd;
            e.o.peak_frames = pf;
            e.o.fuel_spent  = fs;
            e.o.nodes       = nd;
            e.o.objs        = ob;
            e.o.budget      = bg;
            if (g_nentries < MAX_ENTRIES) g_entries[g_nentries++] = e;
        }
    }
    fclose(f);
    return 1;
}

static void manifest_write(const char *dir)
{
    char path[512];
    snprintf(path, sizeof path, "%s/MANIFEST.tsv", dir);
    FILE *f = fopen(path, "w");
    if (!f) { perror("MANIFEST.tsv"); exit(2); }
    fprintf(f,
        "# R30.M9-001 (#1085) — AML fuzz regression corpus.\n"
        "#\n"
        "# Every entry is an input that either tripped an invariant or\n"
        "# reached an outcome signature no earlier entry had reached. The\n"
        "# recorded vector is asserted EXACTLY on replay, so an entry is a\n"
        "# regression test forever: a change that alters any field fails\n"
        "# the gate and has to be explained rather than absorbed.\n"
        "#\n"
        "# The three cost columns (peak_depth, peak_frames, fuel_spent) are\n"
        "# also the recorded performance baseline R30.M9-003 (#1087) gates\n"
        "# on. See design/acpi/perf-methodology.md for why the budget is\n"
        "# expressed in work rather than in milliseconds.\n"
        "#\n"
        "# name\tparse_err\teval_err\tpeak_depth\tpeak_frames\tfuel_spent\tnodes\tobjs\tbudget\n");
    for (size_t i = 0; i < g_nentries; i++) {
        const entry_t *e = &g_entries[i];
        fprintf(f, "%s\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\n",
                e->name,
                (unsigned long long)e->o.parse_err,
                (unsigned long long)e->o.eval_err,
                (unsigned long long)e->o.peak_depth,
                (unsigned long long)e->o.peak_frames,
                (unsigned long long)e->o.fuel_spent,
                (unsigned long long)e->o.nodes,
                (unsigned long long)e->o.objs,
                (unsigned long long)e->o.budget);
    }
    fclose(f);
}

static int read_entry(const char *dir, const char *name, buf_t *b)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    b->n = fread(b->b, 1, FZ_MAX_INPUT, f);
    fclose(f);
    return 1;
}

static void write_entry(const char *dir, const char *name, const buf_t *b)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); exit(2); }
    fwrite(b->b, 1, b->n, f);
    fclose(f);
}

/* An outcome signature is the (parse_err, eval_err) pair. Two inputs with
 * the same signature exercise the same verdict, so keeping both would
 * grow the corpus without growing what it covers. */
static uint64_t signature(const outcome_t *o)
{
    return (o->parse_err << 16) | o->eval_err;
}

static int signature_known(uint64_t sig)
{
    for (size_t i = 0; i < g_nentries; i++)
        if (signature(&g_entries[i].o) == sig) return 1;
    return 0;
}

/* ============================================================== replay */

static int cmd_replay(const char *dir)
{
    if (!manifest_load(dir)) {
        fprintf(stderr, "[aml-fuzz] no MANIFEST.tsv in %s\n", dir);
        return 2;
    }
    /* VACUITY GUARD. A replay over an empty or unreadable corpus would
     * report PASS while asserting nothing, which is the exact failure
     * mode a regression gate must not have. */
    if (g_nentries < NSEEDS) {
        fprintf(stderr, "[aml-fuzz] corpus has %zu entries, fewer than the "
                        "%zu seeds — refusing to report a vacuous pass\n",
                g_nentries, (size_t)NSEEDS);
        return 1;
    }

    for (size_t i = 0; i < g_nentries; i++) {
        entry_t *e = &g_entries[i];
        buf_t    b;
        b_init(&b);
        if (!read_entry(dir, e->name, &b)) {
            fprintf(stderr, "[aml-fuzz] missing corpus file: %s\n", e->name);
            g_fail++;
            continue;
        }
        g_case = e->name;
        outcome_t got;
        run_input(b.b, b.n, &got, e->o.budget);

        want("parse_err",   got.parse_err,   e->o.parse_err);
        want("eval_err",    got.eval_err,    e->o.eval_err);
        want("peak_depth",  got.peak_depth,  e->o.peak_depth);
        want("peak_frames", got.peak_frames, e->o.peak_frames);
        want("fuel_spent",  got.fuel_spent,  e->o.fuel_spent);
        want("nodes",       got.nodes,       e->o.nodes);
        want("objs",        got.objs,        e->o.objs);
    }

    if (g_fail) {
        fprintf(stderr, "[aml-fuzz] %d trip(s) over %zu corpus entries "
                        "(%llu checks)\n",
                g_fail, g_nentries, (unsigned long long)g_checks);
        return 1;
    }
    printf("[aml-fuzz] replay: %zu corpus entries, %llu assertions PASS\n",
           g_nentries, (unsigned long long)g_checks);
    return 0;
}

/* ================================================================ soak */

static void promote(const char *dir, const buf_t *b, const outcome_t *o,
                    const char *why, size_t *grown)
{
    if (g_nentries >= MAX_ENTRIES) return;
    entry_t *e = &g_entries[g_nentries];
    snprintf(e->name, sizeof e->name, "c%03zu-%s.aml", g_nentries, why);
    e->o = *o;
    write_entry(dir, e->name, b);
    g_nentries++;
    (*grown)++;
}

static int cmd_soak(const char *dir, unsigned long iters, uint64_t seed)
{
    manifest_load(dir);
    g_rng = seed;

    size_t grown = 0;

    /* The seeds go in UNCONDITIONALLY — not subject to the signature
     * filter the mutants face. Two reasons. They define what the
     * mutators can reach at all, so a corpus missing one is not
     * reproducible from this file. And several of them share the
     * signature (0,0) — evaluated cleanly — which is exactly the
     * signature a coverage filter discards, so filtering would silently
     * drop every well-formed fixture and leave a corpus made entirely of
     * failures. `arith` in particular is the simple-method baseline
     * R30.M9-003 (#1087) measures against. */
    /* Match the seed name EXACTLY against the entry's `cNNN-<name>.aml`
     * stem. A substring test would be safe only by accident: the moment
     * someone adds a seed called `nest` or `arith2`, an existing entry
     * would look like it already covered it and the seed would be
     * silently dropped from the corpus — which is the one failure this
     * loop exists to prevent. */
    int seeded[NSEEDS];
    memset(seeded, 0, sizeof seeded);
    for (size_t i = 0; i < NSEEDS; i++) {
        for (size_t k = 0; k < g_nentries; k++) {
            const char *nm = g_entries[k].name;
            const char *dash = strchr(nm, '-');
            if (!dash) continue;
            const char *stem = dash + 1;
            size_t stemlen = strlen(stem);
            if (stemlen > 4 && strcmp(stem + stemlen - 4, ".aml") == 0)
                stemlen -= 4;
            if (stemlen == strlen(g_seeds[i].name) &&
                strncmp(stem, g_seeds[i].name, stemlen) == 0)
                seeded[i] = 1;
        }
    }

    for (size_t i = 0; i < NSEEDS; i++) {
        if (seeded[i]) continue;
        buf_t b; g_seeds[i].fn(&b);
        outcome_t o;
        g_case = g_seeds[i].name;
        run_input(b.b, b.n, &o, FUZZ_FUEL);
        promote(dir, &b, &o, g_seeds[i].name, &grown);
    }

    /* The depth generator, straddling the cap in both directions. */
    for (unsigned d = 2; d <= 60; d += 8) {
        buf_t b; gen_nested(&b, d);
        outcome_t o;
        char nm[32]; snprintf(nm, sizeof nm, "nest%u", d);
        g_case = nm;
        run_input(b.b, b.n, &o, FUZZ_FUEL);
        if (!signature_known(signature(&o))) {
            char why[32]; snprintf(why, sizeof why, "nest%u", d);
            promote(dir, &b, &o, why, &grown);
        }
    }

    for (unsigned long it = 0; it < iters; it++) {
        /* Start from a seed or from an existing corpus entry, so mutants
         * chain across generations rather than always being one edit away
         * from well-formed. */
        buf_t b;
        if (g_nentries && rnd_below(2)) {
            if (!read_entry(dir, g_entries[rnd_below(g_nentries)].name, &b))
                g_seeds[rnd_below(NSEEDS)].fn(&b);
        } else {
            g_seeds[rnd_below(NSEEDS)].fn(&b);
        }
        if (!b.n) continue;

        /* Parse once to build the structure map the mutators need, then
         * apply one to three edits. */
        aml_region_reset(); aml_ctl_reset(); aml_arena_reset();
        const uint8_t *gb = guard_load(b.b, b.n);
        GUARDED(aml_parse((uint64_t)(uintptr_t)gb, (uint64_t)b.n));
        map_t m;
        map_build(&m, b.b, b.n);
        guard_free();

        /* INSIST THAT THE MUTANT DIFFERS FROM ITS PARENT.
         *
         * Every mutator has silent no-op paths: no candidate site of the
         * right kind, a bounds check that declines, a PkgLength
         * perturbation that lands back on the original value after
         * masking, a name segment already padded with '_', a truncation
         * offset at or past the current end. Without this loop an
         * "iteration" is sometimes a re-run of the parent, so the
         * headline iteration count overstates how many distinct programs
         * were actually tried — which is the one number a fuzzer must
         * not overstate.
         *
         * Bounded at 8 attempts and then skipped: a parent with no
         * mutable site at all must not spin. */
        buf_t   parent = b;
        unsigned tries = 0;
        int      differs = 0;
        while (tries < 8 && !differs) {
            b = parent;
            unsigned nedits = 1 + (unsigned)rnd_below(3);
            for (unsigned k = 0; k < nedits; k++) {
                switch (rnd_below(4)) {
                case 0: mut_pkglen(&b, &m);     break;
                case 1: mut_opcode(&b, &m);     break;
                case 2: mut_namestring(&b, &m); break;
                default: mut_truncate(&b, &m);  break;
                }
            }
            differs = (b.n != parent.n) ||
                      (b.n && memcmp(b.b, parent.b, b.n) != 0);
            tries++;
        }
        if (!differs) continue;

        char nm[48];
        snprintf(nm, sizeof nm, "soak seed=%llu iter=%lu",
                 (unsigned long long)seed, it);
        g_case = nm;

        int before = g_fail;
        outcome_t o;
        run_input(b.b, b.n, &o, FUZZ_FUEL);

        if (g_fail != before) {
            /* An invariant tripped. This is always a permanent entry —
             * that is the whole point of the exercise. */
            size_t at = g_nentries;
            promote(dir, &b, &o, "trip", &grown);

            /* REPRODUCE VIA THE FILE, NOT VIA THE SEED. Re-running the
             * soak cannot reach this input again: rnd() is one
             * sequential stream, so iteration N is only reachable by
             * replaying all N — and the promotion above has already
             * changed the corpus this run draws its parents from, so
             * even the full re-run picks different parents from here on.
             * The input itself is on disk and is the only reliable
             * handle. Printing a seed-based recipe that cannot work is
             * worse than printing nothing, because it will be trusted at
             * exactly the moment someone is chasing a real trip. */
            fprintf(stderr,
                "[aml-fuzz] TRIPPING INPUT SAVED: %s/%s\n"
                "[aml-fuzz]   reproduce with: aml_fuzz replay %s\n"
                "[aml-fuzz]   (found at iteration %lu of seed %llu; the "
                "soak is NOT re-runnable to this point)\n",
                dir, at < MAX_ENTRIES ? g_entries[at].name : "(corpus full)",
                dir, it, (unsigned long long)seed);
        } else if (!signature_known(signature(&o))) {
            promote(dir, &b, &o, "sig", &grown);
        }
    }

    manifest_write(dir);
    printf("[aml-fuzz] soak: %lu iterations, corpus %zu entries "
           "(+%zu this run), %llu assertions, %d trip(s)\n",
           iters, g_nentries, grown, (unsigned long long)g_checks, g_fail);
    return g_fail ? 1 : 0;
}

/* ============================================== R30.M9-003 (#1087) budget
 *
 * THE WALL-CLOCK BUDGET IN THE ISSUE CANNOT BE MEASURED HERE, and saying
 * so is the honest deliverable. Two things it needs do not exist:
 *
 *   (a) A CLOCK IN THE BUBBLE. There is no time syscall — the handler set
 *       is exactly the fifteen under src/kernel/core/syscall/handlers/,
 *       and none of them reads a clock. That is not an oversight; it is
 *       why the EC and Global Lock timeouts are bounded in ITERATIONS and
 *       why design/acpi/global-lock.md §8 says so in as many words.
 *
 *   (b) A RESERVED LP-E CORE. src/kernel/core/smp/topology.pdx classifies
 *       LP-E cores, but nothing reserves one: there is no affinity field
 *       in any scheduler structure and `process_set_affinity` is a right
 *       in the catalogue with no implementation behind it.
 *
 * A millisecond number produced anyway would be a measurement of this
 * build host's scheduler, on whatever core it happened to get, for code
 * that has never run on the target. It would also be BELIEVED, which is
 * what makes it worse than an absent number.
 *
 * So the budget that is gated is expressed in WORK: fuel steps, peak
 * depth, peak frames. Those are deterministic, they are properties of the
 * interpreter rather than of the machine under it, and they are the terms
 * a regression actually shows up in. See design/acpi/perf-methodology.md.
 *
 * ON HEADROOM. Each ceiling sits well above its measured value. A ceiling
 * equal to the measurement is a change detector, and MANIFEST.tsv already
 * is one — it pins every cost field exactly. This table is the different
 * instrument: it should tolerate a refactor that shifts a constant and
 * fail an algorithmic regression, so the headroom is roughly a factor of
 * two to four and never an order of magnitude. */

static const struct {
    const char *seed;
    uint64_t    fuel_ceiling;
    uint64_t    depth_ceiling;
    uint64_t    frames_ceiling;
    uint64_t    want_parse_err;
    uint64_t    want_eval_err;
} g_budgets[] = {
    /* THE SIMPLE-METHOD BASELINE — the closest thing this system has to
     * the issue's "method round-trip". Measured: 4 steps, depth 3. */
    { "arith",      16,  8,  2,  0,  0 },
    /* A 32-iteration While. Measured 266 steps, i.e. ~8 per iteration;
     * the ceiling admits ~16 per iteration and refuses a per-iteration
     * cost that has doubled. */
    { "loop",      512,  8,  2,  0,  0 },
    { "named",      16,  8,  2,  0,  0 },
    { "branch",     32,  8,  2,  0,  0 },
    { "package",    32,  8,  2,  0,  0 },
    /* Self-recursion. Frames is the binding constraint at exactly 8, and
     * the ceiling is 8 rather than a rounder number on purpose: the pool
     * bound IS the budget here, and headroom would defeat the point.
     * Its expected verdict is AML_ERR_FRAME_OVERFLOW (33): this fixture
     * measures the cost of REACHING the bound, so "it evaluated cleanly"
     * would mean the bound moved. */
    { "recursive",  64, 16,  8,  0, 33 },
    /* `nested` is DELIBERATELY ABSENT. It declares Scopes and a Name and
     * no Method, so it never enters the evaluator: its cost is 0/0/0,
     * every ceiling comparison is 0 <= n, and all three assertions are
     * unfalsifiable. It was here, exempted by name from the
     * forward-progress check below — which is to say the guard written
     * to catch exactly this was amended to permit it. Deleting the row
     * was the correct fix; `nested` remains a fuzz SEED, where parsing
     * without evaluating is precisely what it contributes. */
};
#define NBUDGETS (sizeof g_budgets / sizeof g_budgets[0])

static int cmd_budget(void)
{
    printf("[aml-budget] deterministic cost of the baseline fixtures\n");
    printf("[aml-budget] %-12s %8s %8s %8s   %s\n",
           "fixture", "fuel", "depth", "frames", "ceilings (fuel/depth/frames)");

    for (size_t i = 0; i < NBUDGETS; i++) {
        seed_fn fn = NULL;
        for (size_t k = 0; k < NSEEDS; k++)
            if (strcmp(g_seeds[k].name, g_budgets[i].seed) == 0) fn = g_seeds[k].fn;
        if (!fn) { fail("budget names unknown seed %s", g_budgets[i].seed); continue; }

        buf_t b; fn(&b);
        outcome_t o;
        g_case = g_budgets[i].seed;
        run_input(b.b, b.n, &o, FUZZ_FUEL);

        printf("[aml-budget] %-12s %8llu %8llu %8llu   %llu/%llu/%llu\n",
               g_budgets[i].seed,
               (unsigned long long)o.fuel_spent,
               (unsigned long long)o.peak_depth,
               (unsigned long long)o.peak_frames,
               (unsigned long long)g_budgets[i].fuel_ceiling,
               (unsigned long long)g_budgets[i].depth_ceiling,
               (unsigned long long)g_budgets[i].frames_ceiling);

        want_le("fuel steps",  o.fuel_spent,  g_budgets[i].fuel_ceiling);
        want_le("peak depth",  o.peak_depth,  g_budgets[i].depth_ceiling);
        want_le("peak frames", o.peak_frames, g_budgets[i].frames_ceiling);

        /* THE FIXTURE MUST STILL WORK. Ceilings alone would pass a
         * regression that made `arith` fault after four steps — it would
         * post 4/3/1 and sail under every bound. A performance baseline
         * for a method that no longer evaluates is not a baseline, so the
         * verdict is pinned alongside the cost. */
        want("parse verdict", o.parse_err, g_budgets[i].want_parse_err);
        want("eval verdict",  o.eval_err,  g_budgets[i].want_eval_err);

        /* And a fixture that stopped being reached at all would post a
         * cost of zero and sail under every ceiling too. Requiring
         * forward progress is what stops this gate passing vacuously.
         * There is no exemption: a row that cannot spend fuel does not
         * belong in this table. */
        g_checks++;
        if (o.fuel_spent == 0)
            fail("%s spent no fuel — the fixture is not being evaluated, "
                 "so its budget is vacuous", g_budgets[i].seed);
    }

    if (g_fail) {
        fprintf(stderr, "[aml-budget] %d budget violation(s)\n", g_fail);
        return 1;
    }
    printf("[aml-budget] %llu assertions PASS\n", (unsigned long long)g_checks);
    return 0;
}

/* ================================================================ main */

int main(int argc, char **argv)
{
    /* AN ALTERNATE SIGNAL STACK IS NOT OPTIONAL FOR THIS FUZZER.
     *
     * M5 / gen_nested deliberately generates up to 60 levels of nesting
     * aimed at a recursive-descent parser — which is the textbook way to
     * exhaust the host stack. A SIGSEGV handler cannot run on an
     * exhausted stack without an alternate one, so without this the
     * single most likely finding degrades from the intended
     * "read past the end of the AML buffer" diagnostic into an
     * uninformative process kill with no attribution at all.
     *
     * SA_ONSTACK is what actually routes the handler here; sigaltstack
     * alone does nothing. */
    /* A fixed 64 KiB rather than SIGSTKSZ: on glibc 2.34+ SIGSTKSZ
     * expands to sysconf(_SC_SIGSTKSZ) and is no longer a compile-time
     * constant, so it cannot size a static array. 64 KiB is comfortably
     * above every historical SIGSTKSZ and this handler only ever calls
     * siglongjmp or write(). */
    static char altstack[65536];
    stack_t ss;
    memset(&ss, 0, sizeof ss);
    ss.ss_sp    = altstack;
    ss.ss_size  = sizeof altstack;
    ss.ss_flags = 0;
    if (sigaltstack(&ss, NULL) != 0) perror("sigaltstack");

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_segv;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_alarm;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, NULL);

    if (argc >= 2 && strcmp(argv[1], "budget") == 0) {
        alarm(120);
        return cmd_budget();
    }
    if (argc >= 3 && strcmp(argv[1], "replay") == 0) {
        alarm(120);
        return cmd_replay(argv[2]);
    }
    if (argc >= 5 && strcmp(argv[1], "soak") == 0) {
        unsigned long iters = strtoul(argv[3], NULL, 0);
        uint64_t      seed  = strtoull(argv[4], NULL, 0);
        /* Generous but finite: a soak that wedges must still report. */
        alarm(argc >= 6 ? (unsigned)strtoul(argv[5], NULL, 0) : 3600);
        return cmd_soak(argv[2], iters, seed);
    }

    fprintf(stderr,
        "usage: aml_fuzz replay <corpusdir>\n"
        "       aml_fuzz soak <corpusdir> <iters> <seed> [alarm_secs]\n"
        "       aml_fuzz budget\n");
    return 2;
}
