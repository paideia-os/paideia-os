/* tests/user/aml/aml_harness.c — R30.M1-001 (#1049) / R30.M1-002 (#1050)
 *
 * Executable corpus for the userspace AML tokenizer and namespace parser.
 *
 * WHY A HOST HARNESS AND NOT A BOOT WITNESS
 * -----------------------------------------
 * The AML tokenizer and parser are pure computation over a byte buffer:
 * no syscalls, no MMIO, no capabilities. paideia-as emits SysV-ABI ELF64
 * objects, so those objects link directly against a native C driver and
 * the SAME MACHINE CODE that will run in the acpi_supervisor process is
 * executed here, in a context where a corpus can actually be asserted
 * against. A boot witness at this milestone could only prove that the
 * code links — there is no runtime path that feeds it a DSDT yet. Proving
 * behaviour is worth more than proving linkage, so this is wired as a
 * build-time check (like tools/verify-elaborator-negatives.sh) rather
 * than as a QEMU witness.
 *
 * WHY A GUARD PAGE
 * ----------------
 * ACPI tables are firmware-supplied. A parser that over-reads on
 * malformed input is a security bug, not a robustness nit. Every fixture
 * — well-formed and malformed alike — is copied so that its LAST BYTE is
 * the last byte of a mapped page, with the following page mapped
 * PROT_NONE. Any read one byte past the end of the buffer is therefore a
 * hard SIGSEGV, not a silently-tolerated over-read of adjacent heap. The
 * fault is caught and reported as a test failure naming the fixture.
 *
 * This is what makes the malformed half of the corpus meaningful: it is
 * not enough that a bad table is rejected with the right code, it must be
 * rejected WITHOUT having read outside the buffer on the way there.
 *
 * ERROR CODES — see design/acpi/aml-parser.md §5.
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

/* ---------------------------------------------------------------- AML ABI */

extern void     aml_lex_init(uint64_t buf, uint64_t len);
extern uint64_t aml_lex_err(void);
extern uint64_t aml_lex_err_off(void);
extern uint64_t aml_lex_pos(void);
extern uint64_t aml_lex_len(void);
extern uint64_t aml_lex_depth(void);
extern uint64_t aml_lex_last_pkglen(void);
extern uint64_t aml_lex_last_pkglen_nbytes(void);
extern uint64_t aml_lex_set_err(uint64_t code);
extern uint64_t aml_lex_require_init(void);
extern uint64_t aml_lex_avail(void);
extern uint64_t aml_lex_seek(uint64_t off);
extern uint64_t aml_lex_u8(void);
extern uint64_t aml_lex_u16(void);
extern uint64_t aml_lex_u32(void);
extern uint64_t aml_lex_u64(void);
extern uint64_t aml_lex_opcode(void);
extern uint64_t aml_lex_pkglength(void);
extern uint64_t aml_lex_pkglength_value(void);
extern uint64_t aml_lex_namechar_ok(uint64_t b);
extern uint64_t aml_lex_leadnamechar_ok(uint64_t b);
extern uint64_t aml_lex_nameseg(void);
extern uint64_t aml_lex_namestring(void);
extern uint64_t aml_lex_integer(void);
extern uint64_t aml_lex_depth_enter(void);
extern void     aml_lex_depth_leave(void);

extern void     aml_arena_reset(void);
extern uint64_t aml_node_count(void);
extern uint64_t aml_name_count(void);
extern uint64_t aml_u64_count(void);
extern uint64_t aml_node_kind(uint64_t i);
extern uint64_t aml_node_flags(uint64_t i);
extern uint64_t aml_node_name(uint64_t i);
extern uint64_t aml_node_first_child(uint64_t i);
extern uint64_t aml_node_next_sibling(uint64_t i);
extern uint64_t aml_node_parent(uint64_t i);
extern uint64_t aml_node_src_off(uint64_t i);
extern uint64_t aml_node_arg0(uint64_t i);
extern uint64_t aml_node_arg1(uint64_t i);
extern uint64_t aml_name_hdr(uint64_t r);
extern uint64_t aml_name_seg(uint64_t r, uint64_t i);
extern uint64_t aml_name_segcount(uint64_t r);
extern uint64_t aml_name_carats(uint64_t r);
extern uint64_t aml_name_root(uint64_t r);
extern uint64_t aml_u64_get(uint64_t r);
extern uint64_t aml_method_argcount(uint64_t i);
extern uint64_t aml_method_serialized(uint64_t i);
extern uint64_t aml_method_synclevel(uint64_t i);
extern uint64_t aml_field_access_type(uint64_t i);
extern uint64_t aml_field_lock_rule(uint64_t i);
extern uint64_t aml_field_update_rule(uint64_t i);

extern uint64_t aml_optab[];
extern uint64_t aml_optab_len;
extern uint64_t aml_optab_find(uint64_t op16);
extern uint64_t aml_optab_op(uint64_t e);
extern uint64_t aml_optab_class(uint64_t e);
extern uint64_t aml_optab_flags(uint64_t e);
extern uint64_t aml_optab_argc(uint64_t e);
extern uint64_t aml_optab_node(uint64_t e);
extern uint64_t aml_optab_selfcheck(void);

extern uint64_t aml_ns_is_namelead(uint64_t b);
extern uint64_t aml_parse(uint64_t buf, uint64_t len);

/* ------------------------------------------------------------- error codes */

enum {
    AML_OK = 0,
    E_EOF = 1, E_PKGLEN_TRUNC = 2, E_PKGLEN_OVERFLOW = 3, E_PKGLEN_TOO_SMALL = 4,
    E_UNKNOWN_OPCODE = 5, E_BAD_NAMECHAR = 6, E_BAD_SEGCOUNT = 7,
    E_NAME_ARENA_FULL = 8, E_NODE_ARENA_FULL = 9, E_UNEXPECTED_OP = 10,
    E_PKG_OVERRUN = 11, E_DEPTH = 12, E_BAD_FIELD_ELEM = 13, E_NO_PROGRESS = 14,
    E_BAD_INTEGER = 15, E_U64_ARENA_FULL = 16, E_FIELD_OFFSET_OVF = 17,
    E_METHOD_INVOCATION = 18, E_NOT_INITIALISED = 19
};

/* node kinds */
enum {
    N_ROOT = 1, N_SCOPE = 2, N_DEVICE = 3, N_METHOD = 4, N_NAME = 5, N_ALIAS = 6,
    N_PROCESSOR = 7, N_POWERRES = 8, N_THERMALZONE = 9, N_OPREGION = 10,
    N_FIELD = 11, N_INDEXFIELD = 12, N_BANKFIELD = 13, N_FIELD_ELEM = 14,
    N_EXTERNAL = 15, N_OPAQUE = 16, N_MUTEX = 17, N_EVENT = 18,
    N_FIELD_LINK = 19, N_FIELD_ACCESS = 20, N_FIELD_RESERVED = 21,
    N_FIELD_CONNECT = 22
};

/* --------------------------------------------------------------- reporting */

static int g_fail;
static int g_checks;
static const char *g_case = "(none)";

static void fail(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[aml-corpus] FAIL %s: ", g_case);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    g_fail++;
}

static void eq(const char *what, uint64_t got, uint64_t want)
{
    g_checks++;
    if (got != want)
        fail("%s = 0x%llx, expected 0x%llx",
             what, (unsigned long long)got, (unsigned long long)want);
}

/* ------------------------------------------------- guard-page fixture load */

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
    if (mprotect(g_map + need, (size_t)ps, PROT_NONE) != 0) { perror("mprotect"); exit(2); }
    uint8_t *p = g_map + need - n;
    if (n) memcpy(p, data, n);
    return p;
}

static void guard_free(void)
{
    if (g_map) munmap(g_map, g_maplen);
    g_map = NULL;
}

static sigjmp_buf     g_jb;
static volatile sig_atomic_t g_armed;

static void on_segv(int sig)
{
    (void)sig;
    if (g_armed) siglongjmp(g_jb, 1);
    _exit(97);
}

#define GUARDED(body)                                                        \
    do {                                                                     \
        g_armed = 1;                                                         \
        if (sigsetjmp(g_jb, 1) == 0) { body; }                               \
        else { fail("SIGSEGV — read past the end of the AML buffer"); }      \
        g_armed = 0;                                                         \
    } while (0)

/* Bind the lexer to a guarded copy of `data` and run `body`. */
#define WITH_FIXTURE(name, data, n, body)                                    \
    do {                                                                     \
        g_case = (name);                                                     \
        const uint8_t *_b = guard_load((data), (n));                         \
        aml_arena_reset();                                                   \
        aml_lex_init((uint64_t)(uintptr_t)_b, (uint64_t)(n));                \
        GUARDED(body);                                                       \
        guard_free();                                                        \
    } while (0)

/* Parse a guarded copy of `data` and run `body` with `root` in scope. */
#define WITH_PARSE(name, data, n, body)                                      \
    do {                                                                     \
        g_case = (name);                                                     \
        const uint8_t *_b = guard_load((data), (n));                         \
        volatile uint64_t root = 0;                                          \
        GUARDED(root = aml_parse((uint64_t)(uintptr_t)_b, (uint64_t)(n)));    \
        { body; }                                                            \
        eq("depth unwound", aml_lex_depth(), 0);                             \
        guard_free();                                                        \
    } while (0)

/* --------------------------------------------------------------- utilities */

static uint64_t nth_child(uint64_t node, int n)
{
    uint64_t c = aml_node_first_child(node);
    while (n-- > 0 && c) c = aml_node_next_sibling(c);
    return c;
}

static int count_children(uint64_t node)
{
    int k = 0;
    for (uint64_t c = aml_node_first_child(node); c; c = aml_node_next_sibling(c)) k++;
    return k;
}

#define SEG4(a,b,c,d) ((uint64_t)(uint8_t)(a) | ((uint64_t)(uint8_t)(b) << 8) \
                     | ((uint64_t)(uint8_t)(c) << 16) | ((uint64_t)(uint8_t)(d) << 24))

/* Encode a §20.2.4 PkgLength whose value covers `payload` bytes PLUS the
 * encoding itself, choosing the shortest of the four forms. */
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

/* ============================================================ §20.2.4 tests */

/* Decode-only assertions at every length-form boundary. The raw-integer
 * entry point is used so the four maxima can be asserted without a fixture
 * large enough to satisfy the package bounds check. */
static void test_pkglength_boundaries(void)
{
    struct { const char *name; uint8_t b[4]; size_t n; uint64_t val; uint64_t nb; } v[] = {
        { "pkglen 1-byte min",   { 0x00 },                   1, 0,          0 },
        { "pkglen 1-byte 5",     { 0x05 },                   1, 5,          0 },
        { "pkglen 1-byte max",   { 0x3F },                   1, 63,         0 },
        { "pkglen 2-byte min",   { 0x40, 0x04 },             2, 64,         1 },
        { "pkglen 2-byte mid",   { 0x41, 0x04 },             2, 65,         1 },
        { "pkglen 2-byte max",   { 0x4F, 0xFF },             2, 0xFFF,      1 },
        { "pkglen 3-byte min",   { 0x80, 0x00, 0x01 },       3, 0x1000,     2 },
        { "pkglen 3-byte max",   { 0x8F, 0xFF, 0xFF },       3, 0xFFFFF,    2 },
        { "pkglen 4-byte min",   { 0xC0, 0x00, 0x00, 0x01 }, 4, 0x100000,   3 },
        { "pkglen 4-byte max",   { 0xCF, 0xFF, 0xFF, 0xFF }, 4, 0xFFFFFFF,  3 },
    };
    for (volatile size_t i = 0; i < sizeof v / sizeof v[0]; i++) {
        WITH_FIXTURE(v[i].name, v[i].b, v[i].n, {
            uint64_t got = aml_lex_pkglength_value();
            eq("err", aml_lex_err(), AML_OK);
            eq("value", got, v[i].val);
            eq("nbytes", aml_lex_last_pkglen_nbytes(), v[i].nb);
            eq("cursor", aml_lex_pos(), v[i].n);
        });
    }
}

/* Package semantics: the two checks the raw form deliberately omits. */
static void test_pkglength_package_checks(void)
{
    /* A package exactly as long as the buffer is accepted. */
    {
        uint8_t b[5] = { 0x05, 0, 0, 0, 0 };
        WITH_FIXTURE("pkglen package exact fit", b, sizeof b, {
            eq("value", aml_lex_pkglength(), 5);
            eq("err", aml_lex_err(), AML_OK);
        });
    }
    /* A 1-byte package declaring length 1 is legal: it is just itself. */
    {
        uint8_t b[1] = { 0x01 };
        WITH_FIXTURE("pkglen package degenerate 1", b, sizeof b, {
            eq("value", aml_lex_pkglength(), 1);
            eq("err", aml_lex_err(), AML_OK);
        });
    }
    /* Length 0 is shorter than its own encoding: self-contradictory. */
    {
        uint8_t b[1] = { 0x00 };
        WITH_FIXTURE("pkglen too small", b, sizeof b, {
            eq("value", aml_lex_pkglength(), 0);
            eq("err", aml_lex_err(), E_PKGLEN_TOO_SMALL);
        });
    }
    /* Two-byte form declaring 1: shorter than its own two bytes. */
    {
        uint8_t b[2] = { 0x41, 0x00 };
        WITH_FIXTURE("pkglen too small 2-byte", b, sizeof b, {
            eq("value", aml_lex_pkglength(), 0);
            eq("err", aml_lex_err(), E_PKGLEN_TOO_SMALL);
        });
    }
    /* Declared extent runs past the end of the buffer. */
    {
        uint8_t b[4] = { 0x20, 0, 0, 0 };
        WITH_FIXTURE("pkglen exceeds buffer", b, sizeof b, {
            eq("value", aml_lex_pkglength(), 0);
            eq("err", aml_lex_err(), E_PKGLEN_OVERFLOW);
            /* the decode itself still happened and is inspectable */
            eq("decoded value survived", aml_lex_last_pkglen(), 0x20);
        });
    }
    /* The 4-byte maximum against a tiny buffer: arithmetic right,
     * bounds check right, both observable from one fixture. */
    {
        uint8_t b[4] = { 0xCF, 0xFF, 0xFF, 0xFF };
        WITH_FIXTURE("pkglen 4-byte max rejected by bounds", b, sizeof b, {
            eq("value", aml_lex_pkglength(), 0);
            eq("err", aml_lex_err(), E_PKGLEN_OVERFLOW);
            eq("decoded value survived", aml_lex_last_pkglen(), 0xFFFFFFF);
        });
    }
    /* Lead byte promises trailing bytes that are not there. */
    {
        uint8_t b[1] = { 0x40 };
        WITH_FIXTURE("pkglen truncated 2-byte", b, sizeof b, {
            eq("value", aml_lex_pkglength(), 0);
            eq("err", aml_lex_err(), E_PKGLEN_TRUNC);
        });
    }
    {
        uint8_t b[2] = { 0xC0, 0x00 };
        WITH_FIXTURE("pkglen truncated 4-byte", b, sizeof b, {
            eq("value", aml_lex_pkglength(), 0);
            eq("err", aml_lex_err(), E_PKGLEN_TRUNC);
        });
    }
    /* No lead byte at all. */
    {
        uint8_t b[1] = { 0x00 };
        WITH_FIXTURE("pkglen at end of stream", b, 0, {
            eq("value", aml_lex_pkglength(), 0);
            eq("err", aml_lex_err(), E_EOF);
        });
        (void)b;
    }
}

/* ============================================================ §20.2.2 tests */

static void test_namestring_forms(void)
{
    {   /* NullName: a legal name that resolves to the arena's 0 sentinel */
        uint8_t b[1] = { 0x00 };
        WITH_FIXTURE("name NullName", b, sizeof b, {
            eq("ref", aml_lex_namestring(), 0);
            eq("err", aml_lex_err(), AML_OK);
            eq("cursor", aml_lex_pos(), 1);
        });
    }
    {   /* single NameSeg */
        uint8_t b[4] = { '_', 'S', 'B', '_' };
        WITH_FIXTURE("name single seg", b, sizeof b, {
            uint64_t r = aml_lex_namestring();
            eq("err", aml_lex_err(), AML_OK);
            eq("segcount", aml_name_segcount(r), 1);
            eq("carats", aml_name_carats(r), 0);
            eq("root", aml_name_root(r), 0);
            eq("seg0", aml_name_seg(r, 0), SEG4('_','S','B','_'));
        });
    }
    {   /* RootChar prefix */
        uint8_t b[5] = { 0x5C, '_', 'S', 'B', '_' };
        WITH_FIXTURE("name root prefix", b, sizeof b, {
            uint64_t r = aml_lex_namestring();
            eq("err", aml_lex_err(), AML_OK);
            eq("root", aml_name_root(r), 1);
            eq("segcount", aml_name_segcount(r), 1);
            eq("seg0", aml_name_seg(r, 0), SEG4('_','S','B','_'));
        });
    }
    {   /* two ParentPrefixChars */
        uint8_t b[6] = { 0x5E, 0x5E, 'A', 'B', 'C', 'D' };
        WITH_FIXTURE("name parent prefix x2", b, sizeof b, {
            uint64_t r = aml_lex_namestring();
            eq("err", aml_lex_err(), AML_OK);
            eq("carats", aml_name_carats(r), 2);
            eq("root", aml_name_root(r), 0);
            eq("seg0", aml_name_seg(r, 0), SEG4('A','B','C','D'));
        });
    }
    {   /* RootChar followed by NullName — prefix survives, no segments */
        uint8_t b[2] = { 0x5C, 0x00 };
        WITH_FIXTURE("name root then null", b, sizeof b, {
            uint64_t r = aml_lex_namestring();
            eq("err", aml_lex_err(), AML_OK);
            g_checks++;
            if (r == 0) fail("prefixed NullName must still allocate an entry");
            eq("segcount", aml_name_segcount(r), 0);
            eq("root", aml_name_root(r), 1);
        });
    }
    {   /* DualNamePath */
        uint8_t b[9] = { 0x2E, '_', 'S', 'B', '_', 'P', 'C', 'I', '0' };
        WITH_FIXTURE("name dual path", b, sizeof b, {
            uint64_t r = aml_lex_namestring();
            eq("err", aml_lex_err(), AML_OK);
            eq("segcount", aml_name_segcount(r), 2);
            eq("seg0", aml_name_seg(r, 0), SEG4('_','S','B','_'));
            eq("seg1", aml_name_seg(r, 1), SEG4('P','C','I','0'));
            eq("cursor", aml_lex_pos(), 9);
        });
    }
    {   /* MultiNamePath with three segments */
        uint8_t b[14] = { 0x2F, 0x03, 'A','A','A','A', 'B','B','B','B', 'C','C','C','C' };
        WITH_FIXTURE("name multi path", b, sizeof b, {
            uint64_t r = aml_lex_namestring();
            eq("err", aml_lex_err(), AML_OK);
            eq("segcount", aml_name_segcount(r), 3);
            eq("seg0", aml_name_seg(r, 0), SEG4('A','A','A','A'));
            eq("seg1", aml_name_seg(r, 1), SEG4('B','B','B','B'));
            eq("seg2", aml_name_seg(r, 2), SEG4('C','C','C','C'));
            eq("cursor", aml_lex_pos(), 14);
        });
    }
    {   /* root + multi path, the fully-qualified form */
        uint8_t b[11] = { 0x5C, 0x2F, 0x02, '_','S','B','_', 'P','C','I','0' };
        WITH_FIXTURE("name root multi path", b, sizeof b, {
            uint64_t r = aml_lex_namestring();
            eq("err", aml_lex_err(), AML_OK);
            eq("root", aml_name_root(r), 1);
            eq("segcount", aml_name_segcount(r), 2);
            eq("seg1", aml_name_seg(r, 1), SEG4('P','C','I','0'));
        });
    }
    /* ---- malformed ---- */
    {   /* lowercase lead character is not a LeadNameChar */
        uint8_t b[4] = { 'a', 'B', 'C', 'D' };
        WITH_FIXTURE("name bad lead char", b, sizeof b, {
            aml_lex_namestring();
            eq("err", aml_lex_err(), E_BAD_NAMECHAR);
        });
    }
    {   /* punctuation in the trailing characters */
        uint8_t b[4] = { 'A', 'B', 'C', '-' };
        WITH_FIXTURE("name bad trailing char", b, sizeof b, {
            aml_lex_namestring();
            eq("err", aml_lex_err(), E_BAD_NAMECHAR);
        });
    }
    {   /* MultiNamePath with SegCount 0 */
        uint8_t b[2] = { 0x2F, 0x00 };
        WITH_FIXTURE("name multi segcount zero", b, sizeof b, {
            aml_lex_namestring();
            eq("err", aml_lex_err(), E_BAD_SEGCOUNT);
        });
    }
    {   /* NameSeg cut short by the end of the buffer */
        uint8_t b[2] = { 'A', 'B' };
        WITH_FIXTURE("name truncated seg", b, sizeof b, {
            aml_lex_namestring();
            eq("err", aml_lex_err(), E_EOF);
        });
    }
    {   /* MultiNamePath promising more segments than are present */
        uint8_t b[6] = { 0x2F, 0x02, 'A', 'B', 'C', 'D' };
        WITH_FIXTURE("name multi truncated", b, sizeof b, {
            aml_lex_namestring();
            eq("err", aml_lex_err(), E_EOF);
        });
    }
}

/* ======================================================= integer literals */

static void test_integers(void)
{
    struct { const char *name; uint8_t b[9]; size_t n; uint64_t v; } ok[] = {
        { "int ZeroOp",  { 0x00 }, 1, 0 },
        { "int OneOp",   { 0x01 }, 1, 1 },
        { "int OnesOp",  { 0xFF }, 1, 0xFFFFFFFFFFFFFFFFull },
        { "int Byte",    { 0x0A, 0x42 }, 2, 0x42 },
        { "int Word",    { 0x0B, 0x34, 0x12 }, 3, 0x1234 },
        { "int DWord",   { 0x0C, 0x78, 0x56, 0x34, 0x12 }, 5, 0x12345678 },
        { "int QWord",   { 0x0E, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, 9,
                          0x1122334455667788ull },
    };
    for (volatile size_t i = 0; i < sizeof ok / sizeof ok[0]; i++) {
        WITH_FIXTURE(ok[i].name, ok[i].b, ok[i].n, {
            uint64_t v = aml_lex_integer();
            eq("err", aml_lex_err(), AML_OK);
            eq("value", v, ok[i].v);
            eq("cursor", aml_lex_pos(), ok[i].n);
        });
    }
    {   /* an expression opcode where a literal is required */
        uint8_t b[1] = { 0x70 };
        WITH_FIXTURE("int rejects StoreOp", b, sizeof b, {
            aml_lex_integer();
            eq("err", aml_lex_err(), E_BAD_INTEGER);
        });
    }
    {   /* truncated DWord: refused atomically, cursor left at the prefix+1 */
        uint8_t b[3] = { 0x0C, 0x01, 0x02 };
        WITH_FIXTURE("int truncated DWord", b, sizeof b, {
            aml_lex_integer();
            eq("err", aml_lex_err(), E_EOF);
        });
    }
}

/* ============================================================ opcode decode */

static void test_opcodes(void)
{
    {
        uint8_t b[1] = { 0x10 };
        WITH_FIXTURE("opcode single byte", b, sizeof b, {
            eq("op16", aml_lex_opcode(), 0x10);
            eq("err", aml_lex_err(), AML_OK);
            eq("cursor", aml_lex_pos(), 1);
        });
    }
    {
        uint8_t b[2] = { 0x5B, 0x82 };
        WITH_FIXTURE("opcode ExtOp escape", b, sizeof b, {
            eq("op16", aml_lex_opcode(), 0x5B82);
            eq("err", aml_lex_err(), AML_OK);
            eq("cursor", aml_lex_pos(), 2);
        });
    }
    {   /* a bare ExtOpPrefix at end of stream must NOT become 0x5B00 */
        uint8_t b[1] = { 0x5B };
        WITH_FIXTURE("opcode truncated ExtOp", b, sizeof b, {
            eq("op16", aml_lex_opcode(), 0);
            eq("err", aml_lex_err(), E_EOF);
        });
    }
}

static void test_optab(void)
{
    g_case = "optab";
    eq("selfcheck", aml_optab_selfcheck(), 0);

    /* every row is findable and reports itself */
    for (uint64_t i = 0; i < aml_optab_len; i++) {
        uint64_t want = aml_optab[i];
        uint64_t op = want & 0xFFFF;
        uint64_t got = aml_optab_find(op);
        g_checks++;
        if (got != want)
            fail("row %llu (op 0x%llx): find returned 0x%llx, expected 0x%llx",
                 (unsigned long long)i, (unsigned long long)op,
                 (unsigned long long)got, (unsigned long long)want);
    }
    /* strictly ascending, independently of the in-module self-check */
    for (uint64_t i = 1; i < aml_optab_len; i++) {
        g_checks++;
        if ((aml_optab[i] & 0xFFFF) <= (aml_optab[i - 1] & 0xFFFF))
            fail("row %llu is not strictly ascending", (unsigned long long)i);
    }
    /* misses report 0 */
    eq("find 0xF0 misses", aml_optab_find(0xF0), 0);
    eq("find 0x5B77 misses", aml_optab_find(0x5B77), 0);
    eq("find 0x0007 misses", aml_optab_find(0x0007), 0);

    /* spot-check the descriptors the parser depends on */
    uint64_t dev = aml_optab_find(0x5B82);
    eq("DeviceOp class", aml_optab_class(dev), 1);
    eq("DeviceOp node", aml_optab_node(dev), N_DEVICE);
    eq("DeviceOp flags", aml_optab_flags(dev), 0x01 | 0x02 | 0x08 | 0x20 | 0x40);
    uint64_t meth = aml_optab_find(0x14);
    eq("MethodOp node", aml_optab_node(meth), N_METHOD);
    eq("MethodOp flags", aml_optab_flags(meth), 0x01 | 0x02 | 0x04 | 0x08 | 0x40);
    uint64_t fld = aml_optab_find(0x5B81);
    eq("FieldOp node", aml_optab_node(fld), N_FIELD);
    eq("FieldOp flags", aml_optab_flags(fld), 0x01 | 0x02 | 0x04 | 0x10 | 0x20 | 0x40);
    uint64_t buf = aml_optab_find(0x11);
    eq("BufferOp flags", aml_optab_flags(buf), 0x01 | 0x80);
    uint64_t add = aml_optab_find(0x72);
    eq("AddOp argc", aml_optab_argc(add), 3);
    eq("AddOp node", aml_optab_node(add), 0);

    /* name-lead classification */
    eq("namelead 'A'", aml_ns_is_namelead('A'), 1);
    eq("namelead '_'", aml_ns_is_namelead('_'), 1);
    eq("namelead '\\'", aml_ns_is_namelead(0x5C), 1);
    eq("namelead '^'", aml_ns_is_namelead(0x5E), 1);
    eq("namelead 0x2E", aml_ns_is_namelead(0x2E), 1);
    eq("namelead 0x2F", aml_ns_is_namelead(0x2F), 1);
    eq("ExtOpPrefix is NOT a namelead", aml_ns_is_namelead(0x5B), 0);
    eq("digit is NOT a lead", aml_ns_is_namelead('0'), 0);
    eq("lowercase is NOT a lead", aml_ns_is_namelead('a'), 0);
}

/* ================================================== invariants (I1) / (I2) */

static void test_bounds_invariants(void)
{
    {   /* a zero-length buffer at the very edge of the guard page:
         * a hundred reads must all report EOF and none may fault */
        uint8_t b[1] = { 0 };
        g_case = "reads at end of stream never fault";
        const uint8_t *p = guard_load(b, 0);
        aml_lex_init((uint64_t)(uintptr_t)p, 0);
        GUARDED({
            for (int i = 0; i < 100; i++) (void)aml_lex_u8();
            eq("err", aml_lex_err(), E_EOF);
            eq("cursor", aml_lex_pos(), 0);
        });
        guard_free();
    }
    {   /* once an error is latched, reads must not touch the buffer even
         * though bytes remain — invariant (I2) */
        uint8_t b[4] = { 0xAA, 0xBB, 0xCC, 0xDD };
        WITH_FIXTURE("sticky error blocks further reads", b, sizeof b, {
            eq("first byte", aml_lex_u8(), 0xAA);
            aml_lex_set_err(E_UNEXPECTED_OP);
            eq("blocked read", aml_lex_u8(), 0);
            eq("cursor frozen", aml_lex_pos(), 1);
            eq("first writer wins", aml_lex_err(), E_UNEXPECTED_OP);
            aml_lex_set_err(E_EOF);
            eq("still first writer", aml_lex_err(), E_UNEXPECTED_OP);
            eq("err_off", aml_lex_err_off(), 1);
        });
    }
    {   /* seek refuses to move past the end rather than clamping */
        uint8_t b[4] = { 1, 2, 3, 4 };
        WITH_FIXTURE("seek past end is refused", b, sizeof b, {
            eq("seek to end ok", aml_lex_seek(4), 0);
            eq("cursor", aml_lex_pos(), 4);
            eq("err", aml_lex_err(), AML_OK);
            eq("seek past end refused", aml_lex_seek(5), 1);
            eq("err", aml_lex_err(), E_EOF);
            eq("cursor unmoved", aml_lex_pos(), 4);
        });
    }
    {   /* multi-byte literals are atomic: a truncated one moves nothing */
        uint8_t b[3] = { 0x11, 0x22, 0x33 };
        WITH_FIXTURE("u32 truncated is atomic", b, sizeof b, {
            eq("value", aml_lex_u32(), 0);
            eq("err", aml_lex_err(), E_EOF);
            eq("cursor unmoved", aml_lex_pos(), 0);
        });
    }
}

/* ========================================================= parse: accepted */

static void test_parse_minimal_scope(void)
{
    /* Scope(\_SB_) {} */
    uint8_t b[] = { 0x10, 0x06, 0x5C, '_', 'S', 'B', '_' };
    WITH_PARSE("parse minimal Scope", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("root", root, 1);
        eq("root kind", aml_node_kind(root), N_ROOT);
        eq("root extent", aml_node_arg1(root), sizeof b);
        eq("children", (uint64_t)count_children(root), 1);
        uint64_t sc = aml_node_first_child(root);
        eq("scope kind", aml_node_kind(sc), N_SCOPE);
        eq("scope src_off", aml_node_src_off(sc), 0);
        eq("scope termlist start", aml_node_arg0(sc), 7);
        eq("scope package end", aml_node_arg1(sc), 7);
        uint64_t nm = aml_node_name(sc);
        eq("scope root-relative", aml_name_root(nm), 1);
        eq("scope segcount", aml_name_segcount(nm), 1);
        eq("scope seg0", aml_name_seg(nm, 0), SEG4('_','S','B','_'));
        eq("cursor consumed all", aml_lex_pos(), sizeof b);
    });
}

static void test_parse_device_hid(void)
{
    /* Scope(\_SB_) { Device(PCI0) { Name(_HID, 0x030AD041) } } */
    uint8_t b[] = {
        0x10, 0x17, 0x5C, '_','S','B','_',
          0x5B, 0x82, 0x0F, 'P','C','I','0',
            0x08, '_','H','I','D', 0x0C, 0x41, 0xD0, 0x0A, 0x03
    };
    WITH_PARSE("parse Device with _HID", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        uint64_t sc = aml_node_first_child(root);
        eq("scope kind", aml_node_kind(sc), N_SCOPE);
        eq("scope children", (uint64_t)count_children(sc), 1);
        uint64_t dev = aml_node_first_child(sc);
        eq("device kind", aml_node_kind(dev), N_DEVICE);
        eq("device parent", aml_node_parent(dev), sc);
        eq("device src_off", aml_node_src_off(dev), 7);
        eq("device name", aml_name_seg(aml_node_name(dev), 0), SEG4('P','C','I','0'));
        eq("device children", (uint64_t)count_children(dev), 1);
        uint64_t nm = aml_node_first_child(dev);
        eq("name kind", aml_node_kind(nm), N_NAME);
        eq("name is _HID", aml_name_seg(aml_node_name(nm), 0), SEG4('_','H','I','D'));
        eq("name data kind is integer", aml_node_flags(nm), 1);
        eq("_HID value", aml_u64_get(aml_node_arg0(nm)), 0x030AD041);
    });
}

static void test_parse_method(void)
{
    /* Method(FOO_, 3, Serialized) {} — flags 0x0B */
    {
        uint8_t b[] = { 0x14, 0x06, 'F','O','O','_', 0x0B };
        WITH_PARSE("parse Method 3 args serialized", b, sizeof b, {
            eq("err", aml_lex_err(), AML_OK);
            uint64_t m = aml_node_first_child(root);
            eq("kind", aml_node_kind(m), N_METHOD);
            eq("name", aml_name_seg(aml_node_name(m), 0), SEG4('F','O','O','_'));
            eq("flags byte", aml_node_flags(m), 0x0B);
            eq("argcount", aml_method_argcount(m), 3);
            eq("serialized", aml_method_serialized(m), 1);
            eq("synclevel", aml_method_synclevel(m), 0);
            eq("body start", aml_node_arg0(m), 7);
            eq("body end", aml_node_arg1(m), 7);
            eq("body not descended", (uint64_t)count_children(m), 0);
        });
    }
    /* Method(BAR_, 1, NotSerialized, SyncLevel 5) { Noop, Noop } — flags 0x51 */
    {
        uint8_t b[] = { 0x14, 0x08, 'B','A','R','_', 0x51, 0xA3, 0xA3 };
        WITH_PARSE("parse Method synclevel with body", b, sizeof b, {
            eq("err", aml_lex_err(), AML_OK);
            eq("consumed all", aml_lex_pos(), sizeof b);
            uint64_t m = aml_node_first_child(root);
            eq("argcount", aml_method_argcount(m), 1);
            eq("serialized", aml_method_serialized(m), 0);
            eq("synclevel", aml_method_synclevel(m), 5);
            eq("body start", aml_node_arg0(m), 7);
            eq("body end", aml_node_arg1(m), 9);
            eq("body not descended", (uint64_t)count_children(m), 0);
        });
    }
}

static void test_parse_field(void)
{
    /* OperationRegion(ECR_, SystemIO, 0x62, 0x02)
     * Field(ECR_, ByteAcc, Lock, Preserve) {
     *     Offset(2), FLD0, 1, , 3, AccessAs(WordAcc, 0), FLD1, 16
     * } */
    uint8_t b[] = {
        0x5B, 0x80, 'E','C','R','_', 0x01, 0x0A, 0x62, 0x0A, 0x02,
        0x5B, 0x81, 0x17, 'E','C','R','_', 0x11,
            0x00, 0x10,
            'F','L','D','0', 0x01,
            0x00, 0x03,
            0x01, 0x02, 0x00,
            'F','L','D','1', 0x10
    };
    WITH_PARSE("parse OpRegion + Field", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        eq("root children", (uint64_t)count_children(root), 2);

        uint64_t rgn = nth_child(root, 0);
        eq("region kind", aml_node_kind(rgn), N_OPREGION);
        eq("region name", aml_name_seg(aml_node_name(rgn), 0), SEG4('E','C','R','_'));
        eq("region space SystemIO", aml_node_flags(rgn), 1);
        eq("region offset", aml_u64_get(aml_node_arg0(rgn)), 0x62);
        eq("region length", aml_u64_get(aml_node_arg1(rgn)), 0x02);

        uint64_t f = nth_child(root, 1);
        eq("field kind", aml_node_kind(f), N_FIELD);
        eq("field name", aml_name_seg(aml_node_name(f), 0), SEG4('E','C','R','_'));
        eq("field flags", aml_node_flags(f), 0x11);
        eq("access type ByteAcc", aml_field_access_type(f), 1);
        eq("lock rule", aml_field_lock_rule(f), 1);
        eq("update rule Preserve", aml_field_update_rule(f), 0);
        eq("field elements", (uint64_t)count_children(f), 5);

        uint64_t e0 = nth_child(f, 0);
        eq("e0 kind", aml_node_kind(e0), N_FIELD_RESERVED);
        eq("e0 bit offset", aml_node_arg0(e0), 0);
        eq("e0 bit width", aml_node_arg1(e0), 16);

        uint64_t e1 = nth_child(f, 1);
        eq("e1 kind", aml_node_kind(e1), N_FIELD_ELEM);
        eq("e1 name", aml_name_seg(aml_node_name(e1), 0), SEG4('F','L','D','0'));
        eq("e1 bit offset", aml_node_arg0(e1), 16);
        eq("e1 bit width", aml_node_arg1(e1), 1);
        eq("e1 effective access", aml_node_flags(e1) & 0xFF, 0x11);

        uint64_t e2 = nth_child(f, 2);
        eq("e2 kind", aml_node_kind(e2), N_FIELD_RESERVED);
        eq("e2 bit offset", aml_node_arg0(e2), 17);
        eq("e2 bit width", aml_node_arg1(e2), 3);

        uint64_t e3 = nth_child(f, 3);
        eq("e3 kind", aml_node_kind(e3), N_FIELD_ACCESS);
        /* WordAcc replaces the access nibble; Lock/Update bits persist */
        eq("e3 new access byte", aml_node_flags(e3) & 0xFF, 0x12);
        eq("e3 attribute", (aml_node_flags(e3) >> 8) & 0xFF, 0x00);
        eq("e3 access length", aml_node_arg0(e3), 0);

        uint64_t e4 = nth_child(f, 4);
        eq("e4 kind", aml_node_kind(e4), N_FIELD_ELEM);
        eq("e4 name", aml_name_seg(aml_node_name(e4), 0), SEG4('F','L','D','1'));
        eq("e4 bit offset", aml_node_arg0(e4), 20);
        eq("e4 bit width", aml_node_arg1(e4), 16);
        eq("e4 inherits WordAcc", aml_node_flags(e4) & 0xFF, 0x12);
    });
}

static void test_parse_index_and_bank_field(void)
{
    /* IndexField(IDX_, DAT_, ByteAcc, NoLock, Preserve) { AAAA, 8 } */
    {
        uint8_t b[] = {
            0x5B, 0x86, 0x0F, 'I','D','X','_', 'D','A','T','_', 0x01,
                'A','A','A','A', 0x08
        };
        WITH_PARSE("parse IndexField", b, sizeof b, {
            eq("err", aml_lex_err(), AML_OK);
            eq("consumed all", aml_lex_pos(), sizeof b);
            uint64_t f = aml_node_first_child(root);
            eq("kind", aml_node_kind(f), N_INDEXFIELD);
            eq("index name", aml_name_seg(aml_node_name(f), 0), SEG4('I','D','X','_'));
            eq("field flags", aml_node_flags(f), 0x01);
            eq("children", (uint64_t)count_children(f), 2);
            uint64_t link = nth_child(f, 0);
            eq("link kind", aml_node_kind(link), N_FIELD_LINK);
            eq("data name", aml_name_seg(aml_node_name(link), 0), SEG4('D','A','T','_'));
            uint64_t el = nth_child(f, 1);
            eq("elem kind", aml_node_kind(el), N_FIELD_ELEM);
            eq("elem name", aml_name_seg(aml_node_name(el), 0), SEG4('A','A','A','A'));
            eq("elem offset", aml_node_arg0(el), 0);
            eq("elem width", aml_node_arg1(el), 8);
        });
    }
    /* BankField(REG_, BNK_, One, ByteAcc, NoLock, Preserve) { BBBB, 4 } */
    {
        uint8_t b[] = {
            0x5B, 0x87, 0x10, 'R','E','G','_', 'B','N','K','_', 0x01, 0x01,
                'B','B','B','B', 0x04
        };
        WITH_PARSE("parse BankField", b, sizeof b, {
            eq("err", aml_lex_err(), AML_OK);
            eq("consumed all", aml_lex_pos(), sizeof b);
            uint64_t f = aml_node_first_child(root);
            eq("kind", aml_node_kind(f), N_BANKFIELD);
            eq("region name", aml_name_seg(aml_node_name(f), 0), SEG4('R','E','G','_'));
            eq("field flags", aml_node_flags(f), 0x01);
            uint64_t link = nth_child(f, 0);
            eq("link kind", aml_node_kind(link), N_FIELD_LINK);
            eq("bank name", aml_name_seg(aml_node_name(link), 0), SEG4('B','N','K','_'));
            eq("bank value", aml_u64_get(aml_node_arg0(link)), 1);
            uint64_t el = nth_child(f, 1);
            eq("elem name", aml_name_seg(aml_node_name(el), 0), SEG4('B','B','B','B'));
            eq("elem width", aml_node_arg1(el), 4);
        });
    }
}

static void test_parse_misc_named(void)
{
    /* Mutex(MTX_, 3) / Event(EVT_) / Alias(SRC_, DST_) / External(EXT_, 8, 2) */
    uint8_t b[] = {
        0x5B, 0x01, 'M','T','X','_', 0x03,
        0x5B, 0x02, 'E','V','T','_',
        0x06, 'S','R','C','_', 'D','S','T','_',
        0x15, 'E','X','T','_', 0x08, 0x02
    };
    WITH_PARSE("parse Mutex/Event/Alias/External", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        eq("children", (uint64_t)count_children(root), 4);

        uint64_t mx = nth_child(root, 0);
        eq("mutex kind", aml_node_kind(mx), N_MUTEX);
        eq("mutex sync flags", aml_node_flags(mx), 3);

        uint64_t ev = nth_child(root, 1);
        eq("event kind", aml_node_kind(ev), N_EVENT);
        eq("event name", aml_name_seg(aml_node_name(ev), 0), SEG4('E','V','T','_'));

        uint64_t al = nth_child(root, 2);
        eq("alias kind", aml_node_kind(al), N_ALIAS);
        eq("alias is the SECOND name", aml_name_seg(aml_node_name(al), 0),
           SEG4('D','S','T','_'));
        eq("alias source", aml_name_seg(aml_node_arg0(al), 0), SEG4('S','R','C','_'));

        uint64_t ex = nth_child(root, 3);
        eq("external kind", aml_node_kind(ex), N_EXTERNAL);
        eq("external object type", aml_node_flags(ex) & 0xFF, 8);
        eq("external arg count", (aml_node_flags(ex) >> 8) & 0xFF, 2);
    });
}

static void test_parse_opaque_skip(void)
{
    /* Name(BUF_, Buffer(2){0xAA,0xBB}) followed by Scope(ZZZZ){} —
     * the buffer body is skipped by its PkgLength and the parser
     * resynchronises exactly. */
    uint8_t b[] = {
        0x08, 'B','U','F','_', 0x11, 0x05, 0x0A, 0x02, 0xAA, 0xBB,
        0x10, 0x05, 'Z','Z','Z','Z'
    };
    WITH_PARSE("parse Buffer payload skipped by PkgLength", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        eq("children", (uint64_t)count_children(root), 2);
        uint64_t nm = nth_child(root, 0);
        eq("name kind", aml_node_kind(nm), N_NAME);
        eq("data kind is buffer", aml_node_flags(nm), 3);
        eq("payload start", aml_node_arg0(nm), 6);
        eq("payload end", aml_node_arg1(nm), 11);
        uint64_t sc = nth_child(root, 1);
        eq("resynchronised", aml_node_kind(sc), N_SCOPE);
        eq("scope name", aml_name_seg(aml_node_name(sc), 0), SEG4('Z','Z','Z','Z'));
    });

    /* A top-level If: no name, but a known extent, so it becomes OPAQUE. */
    {
        uint8_t b2[] = { 0xA0, 0x03, 0x01, 0x0A, 0x10, 0x05, 'Q','Q','Q','Q' };
        WITH_PARSE("parse If skipped as opaque", b2, sizeof b2, {
            eq("err", aml_lex_err(), AML_OK);
            eq("consumed all", aml_lex_pos(), sizeof b2);
            uint64_t op = nth_child(root, 0);
            eq("opaque kind", aml_node_kind(op), N_OPAQUE);
            eq("opaque src_off", aml_node_src_off(op), 0);
            eq("opaque end", aml_node_arg1(op), 4);
            eq("resynchronised", aml_node_kind(nth_child(root, 1)), N_SCOPE);
        });
    }
}

static void test_parse_string_name(void)
{
    /* Name(STR_, "Hi") */
    uint8_t b[] = { 0x08, 'S','T','R','_', 0x0D, 'H', 'i', 0x00 };
    WITH_PARSE("parse Name with string value", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        uint64_t nm = aml_node_first_child(root);
        eq("data kind is string", aml_node_flags(nm), 2);
        eq("string start", aml_node_arg0(nm), 6);
        eq("string end", aml_node_arg1(nm), 9);
    });
}

static void test_parse_empty(void)
{
    uint8_t b[1] = { 0 };
    g_case = "parse empty buffer";
    const uint8_t *p = guard_load(b, 0);
    uint64_t root = 0;
    GUARDED(root = aml_parse((uint64_t)(uintptr_t)p, 0));
    eq("err", aml_lex_err(), AML_OK);
    eq("root allocated", root, 1);
    eq("node count", aml_node_count(), 2);
    eq("no children", (uint64_t)count_children(root), 0);
    eq("depth unwound", aml_lex_depth(), 0);
    guard_free();
}

static void test_parse_nested_ok(void)
{
    uint8_t tmp[8192], scratch[8192];
    size_t len = 0;
    for (int i = 0; i < 50; i++) {
        uint8_t hdr[16];
        size_t hl = 0, pn;
        uint8_t pk[4];
        pn = emit_pkglen(pk, 4 + len);
        hdr[hl++] = 0x10;
        memcpy(hdr + hl, pk, pn); hl += pn;
        hdr[hl++] = 'A'; hdr[hl++] = 'A'; hdr[hl++] = 'A'; hdr[hl++] = 'A';
        memcpy(scratch, tmp, len);
        memcpy(tmp, hdr, hl);
        memcpy(tmp + hl, scratch, len);
        len += hl;
    }
    WITH_PARSE("parse 50 nested Scopes", tmp, len, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), len);
        uint64_t n = root;
        int d = 0;
        while (aml_node_first_child(n)) { n = aml_node_first_child(n); d++; }
        eq("nesting depth", (uint64_t)d, 50);
    });
}

/* ======================================================== parse: malformed */

struct badcase {
    const char *name;
    uint8_t     b[128];
    size_t      n;
    uint64_t    err;
};

static void test_parse_malformed(void)
{
    struct badcase c[] = {
        /* PkgLength lead byte promises trailing bytes that are absent */
        { "malformed: truncated PkgLength", { 0x10, 0x40 }, 2, E_PKGLEN_TRUNC },
        /* declared package extends past the end of the table */
        { "malformed: PkgLength exceeds buffer",
          { 0x10, 0x20, 0x5C, '_','S','B','_' }, 7, E_PKGLEN_OVERFLOW },
        /* package shorter than its own length field */
        { "malformed: PkgLength too small",
          { 0x10, 0x00, 0x5C, '_','S','B','_' }, 7, E_PKGLEN_TOO_SMALL },
        /* a byte that is not an AML opcode at all */
        { "malformed: unknown opcode", { 0x20 }, 1, E_UNKNOWN_OPCODE },
        { "malformed: unknown ExtOp", { 0x5B, 0x77 }, 2, E_UNKNOWN_OPCODE },
        /* a real opcode with no PkgLength that this milestone cannot skip */
        { "malformed: unexpected opcode", { 0x70, 0x00, 0x00 }, 3, E_UNEXPECTED_OP },
        /* a bare NameString in term position is a method invocation */
        { "malformed: method invocation", { 'A','A','A','A' }, 4, E_METHOD_INVOCATION },
        /* stream ends inside a two-byte opcode */
        { "malformed: truncated ExtOp", { 0x5B }, 1, E_EOF },
        /* illegal character inside a NameSeg */
        { "malformed: bad name character",
          { 0x10, 0x06, 0x5C, 'a','S','B','_' }, 7, E_BAD_NAMECHAR },
        /* MultiNamePath declaring zero segments */
        { "malformed: MultiName segcount zero",
          { 0x10, 0x03, 0x2F, 0x00 }, 4, E_BAD_SEGCOUNT },
        /* NameSeg cut short by the package end */
        { "malformed: truncated NameSeg",
          { 0x10, 0x04, 'A','B','C' }, 5, E_EOF },
        /* a child whose extent runs past its parent's declared end */
        { "malformed: package overrun",
          { 0x10, 0x0C, 0x5C, '_','S','B','_', 0x5B, 0x82, 0x05, 'P','C','I','0' },
          14, E_PKG_OVERRUN },
        /* a FieldList element opcode that is neither 0x00..0x03 nor a name */
        { "malformed: bad field element",
          { 0x5B, 0x81, 0x07, 'E','C','R','_', 0x00, 0x04 }, 9, E_BAD_FIELD_ELEM },
        /* Name with a computed initialiser: deferred to #1052, not guessed */
        { "malformed: Name with non-literal value",
          { 0x08, 'X','X','X','X', 0x70 }, 6, E_UNEXPECTED_OP },
        /* OpRegion whose offset is not a literal */
        { "malformed: OpRegion non-literal offset",
          { 0x5B, 0x80, 'R','G','N','_', 0x00, 0x70 }, 8, E_BAD_INTEGER },
        /* Method body truncated: the declared package runs off the end */
        { "malformed: Method package past end",
          { 0x14, 0x20, 'F','O','O','_', 0x00 }, 7, E_PKGLEN_OVERFLOW },
    };
    for (volatile size_t i = 0; i < sizeof c / sizeof c[0]; i++) {
        WITH_PARSE(c[i].name, c[i].b, c[i].n, {
            eq("rejected", root, 0);
            eq("error code", aml_lex_err(), c[i].err);
        });
    }
}

static void test_parse_depth_limit(void)
{
    uint8_t tmp[16384], scratch[16384];
    size_t len = 0;
    for (int i = 0; i < 70; i++) {
        uint8_t hdr[16];
        size_t hl = 0, pn;
        uint8_t pk[4];
        pn = emit_pkglen(pk, 4 + len);
        hdr[hl++] = 0x10;
        memcpy(hdr + hl, pk, pn); hl += pn;
        hdr[hl++] = 'A'; hdr[hl++] = 'A'; hdr[hl++] = 'A'; hdr[hl++] = 'A';
        memcpy(scratch, tmp, len);
        memcpy(tmp, hdr, hl);
        memcpy(tmp + hl, scratch, len);
        len += hl;
    }
    WITH_PARSE("malformed: nesting exceeds depth budget", tmp, len, {
        eq("rejected", root, 0);
        eq("error code", aml_lex_err(), E_DEPTH);
    });
}

static void test_arena_exhaustion(void)
{
    /* Node arena: empty Buffers are two bytes each and unnamed, so the
     * node arena is the first resource to run out. */
    {
        static uint8_t b[1600];
        for (size_t i = 0; i < sizeof b; i += 2) { b[i] = 0x11; b[i + 1] = 0x01; }
        WITH_PARSE("malformed: node arena exhausted", b, sizeof b, {
            eq("rejected", root, 0);
            eq("error code", aml_lex_err(), E_NODE_ARENA_FULL);
        });
    }
    /* Name arena: each Event costs one header plus one NameSeg word, so
     * 512 words run out after 256 names while only 256 nodes are used. */
    {
        static uint8_t b[1800];
        for (size_t i = 0; i + 6 <= sizeof b; i += 6) {
            b[i] = 0x5B; b[i + 1] = 0x02;
            b[i + 2] = 'A'; b[i + 3] = 'A'; b[i + 4] = 'A'; b[i + 5] = 'A';
        }
        WITH_PARSE("malformed: name arena exhausted", b, 1800, {
            eq("rejected", root, 0);
            eq("error code", aml_lex_err(), E_NAME_ARENA_FULL);
        });
    }
    /* u64 side table: 128 slots, one per integer-valued Name. */
    {
        static uint8_t b[900];
        size_t k = 0;
        for (size_t i = 0; i < 150; i++) {
            b[k++] = 0x08;
            b[k++] = 'A'; b[k++] = 'A'; b[k++] = 'A'; b[k++] = 'A';
            b[k++] = 0x00;
        }
        WITH_PARSE("malformed: u64 arena exhausted", b, k, {
            eq("rejected", root, 0);
            eq("error code", aml_lex_err(), E_U64_ARENA_FULL);
        });
    }
}

static void test_field_offset_overflow(void)
{
    /* Seventeen reserved fields of 0xFFFFFFF bits each carry the running
     * bit offset past 2^32-1, which the 32-bit node slot cannot hold. */
    static uint8_t b[128];
    size_t k = 0;
    uint8_t elems[17 * 5];
    size_t el = 0;
    for (int i = 0; i < 17; i++) {
        elems[el++] = 0x00;
        elems[el++] = 0xCF; elems[el++] = 0xFF; elems[el++] = 0xFF; elems[el++] = 0xFF;
    }
    uint8_t pk[4];
    size_t pn = emit_pkglen(pk, 4 + 1 + el);
    b[k++] = 0x5B; b[k++] = 0x81;
    memcpy(b + k, pk, pn); k += pn;
    b[k++] = 'E'; b[k++] = 'C'; b[k++] = 'R'; b[k++] = '_';
    b[k++] = 0x00;
    memcpy(b + k, elems, el); k += el;
    WITH_PARSE("malformed: field bit offset overflow", b, k, {
        eq("rejected", root, 0);
        eq("error code", aml_lex_err(), E_FIELD_OFFSET_OVF);
    });
}

/* ============================================ self-check on the apparatus */

/* If the guard page is not actually adjacent to the fixture, every
 * out-of-bounds assertion in this corpus is vacuous — a parser that ran
 * off the end would read whatever happened to follow and the tests would
 * still pass. So prove the trap works before trusting anything it claims. */
static void test_guard_page_is_armed(void)
{
    g_case = "self-check: guard page traps a one-byte over-read";
    uint8_t d[4] = { 1, 2, 3, 4 };
    const uint8_t *p = guard_load(d, sizeof d);
    volatile int trapped = 0;
    g_checks++;
    g_armed = 1;
    if (sigsetjmp(g_jb, 1) == 0) {
        volatile uint8_t x = p[sizeof d];      /* exactly one past the end */
        (void)x;
    } else {
        trapped = 1;
    }
    g_armed = 0;
    if (!trapped)
        fail("guard page did NOT trap a one-byte over-read — every "
             "out-of-bounds assertion in this corpus would be vacuous");
    g_checks++;
    if (p[sizeof d - 1] != 4)
        fail("last in-bounds byte is not readable — fixture misplaced");
    guard_free();
}

/* ==================================================================== main */

int main(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_segv;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);

    test_guard_page_is_armed();

    /* Must run first among the lexer tests: aml_lex_init stamps the magic
     * permanently, so "never initialised" is only observable once. */
    g_case = "API misuse before init";
    eq("require_init refuses", aml_lex_require_init(), E_NOT_INITIALISED);
    eq("error latched", aml_lex_err(), E_NOT_INITIALISED);

    test_optab();
    test_pkglength_boundaries();
    test_pkglength_package_checks();
    test_namestring_forms();
    test_integers();
    test_opcodes();
    test_bounds_invariants();

    test_parse_minimal_scope();
    test_parse_device_hid();
    test_parse_method();
    test_parse_field();
    test_parse_index_and_bank_field();
    test_parse_misc_named();
    test_parse_opaque_skip();
    test_parse_string_name();
    test_parse_empty();
    test_parse_nested_ok();

    test_parse_malformed();
    test_parse_depth_limit();
    test_arena_exhaustion();
    test_field_offset_overflow();

    if (g_fail) {
        fprintf(stderr, "[aml-corpus] %d assertion(s) failed out of %d\n",
                g_fail, g_checks);
        return 1;
    }
    printf("[aml-corpus] %d assertions PASS\n", g_checks);
    return 0;
}
