/* tests/user/aml/aml_harness.c — R30.M1-001 (#1049) / R30.M1-002 (#1050)
 *                                 R30.M1-003 (#1051) / R30.M1-004 (#1052)
 *                                 R30.M1-005 (#1053)
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
extern uint64_t aml_optab_shape(uint64_t e);
extern uint64_t aml_optab_selfcheck(void);

extern uint64_t aml_ns_is_namelead(uint64_t b);
extern uint64_t aml_parse(uint64_t buf, uint64_t len);
extern uint64_t aml_node_last_child(uint64_t i);

/* #1051 / #1052 — term parser */
extern uint64_t aml_term_final_seg(uint64_t name_ref);
extern uint64_t aml_term_lookup(uint64_t name_ref);
extern uint64_t aml_term_bodies(void);

/* #1053 — resource templates */
extern uint64_t aml_res_validate(uint64_t start, uint64_t end);
extern uint64_t aml_res_is_template(uint64_t node);
extern uint64_t aml_res_parse(uint64_t node);
extern uint64_t aml_res_tag(uint64_t d);
extern uint64_t aml_res_large(uint64_t d);
extern uint64_t aml_res_data_off(uint64_t d);
extern uint64_t aml_res_data_len(uint64_t d);
extern uint64_t aml_res_u8(uint64_t d, uint64_t off);
extern uint64_t aml_res_u16(uint64_t d, uint64_t off);
extern uint64_t aml_res_u32(uint64_t d, uint64_t off);
extern uint64_t aml_res_u64(uint64_t d, uint64_t off);
extern uint64_t aml_res_space_width(uint64_t d);
extern uint64_t aml_res_space_min(uint64_t d);
extern uint64_t aml_res_space_max(uint64_t d);
extern uint64_t aml_res_space_len(uint64_t d);
extern uint64_t aml_res_gpio_type(uint64_t d);
extern uint64_t aml_res_gpio_pin_count(uint64_t d);
extern uint64_t aml_res_gpio_pin(uint64_t d, uint64_t i);
extern uint64_t aml_res_serial_type(uint64_t d);
extern uint64_t aml_res_i2c_speed(uint64_t d);
extern uint64_t aml_res_i2c_addr(uint64_t d);

/* ------------------------------------------------------------- error codes */

enum {
    AML_OK = 0,
    E_EOF = 1, E_PKGLEN_TRUNC = 2, E_PKGLEN_OVERFLOW = 3, E_PKGLEN_TOO_SMALL = 4,
    E_UNKNOWN_OPCODE = 5, E_BAD_NAMECHAR = 6, E_BAD_SEGCOUNT = 7,
    E_NAME_ARENA_FULL = 8, E_NODE_ARENA_FULL = 9, E_UNEXPECTED_OP = 10,
    E_PKG_OVERRUN = 11, E_DEPTH = 12, E_BAD_FIELD_ELEM = 13, E_NO_PROGRESS = 14,
    E_BAD_INTEGER = 15, E_U64_ARENA_FULL = 16, E_FIELD_OFFSET_OVF = 17,
    E_METHOD_INVOCATION = 18, E_NOT_INITIALISED = 19,
    /* #1051 / #1052 */
    E_UNRESOLVED_CALL = 20, E_AMBIGUOUS_CALL = 21, E_PKG_ELEM_COUNT = 22,
    E_BUF_SIZE_OVF = 23, E_ELSE_WITHOUT_IF = 24,
    /* #1053 */
    E_RES_CHECKSUM = 25, E_RES_TRUNCATED = 26, E_RES_LENGTH = 27,
    E_RES_NO_ENDTAG = 28, E_RES_BAD_TAG = 29,
    E_BAD_TERMARG = 30
};

/* node kinds */
enum {
    N_ROOT = 1, N_SCOPE = 2, N_DEVICE = 3, N_METHOD = 4, N_NAME = 5, N_ALIAS = 6,
    N_PROCESSOR = 7, N_POWERRES = 8, N_THERMALZONE = 9, N_OPREGION = 10,
    N_FIELD = 11, N_INDEXFIELD = 12, N_BANKFIELD = 13, N_FIELD_ELEM = 14,
    N_EXTERNAL = 15, N_OPAQUE = 16, N_MUTEX = 17, N_EVENT = 18,
    N_FIELD_LINK = 19, N_FIELD_ACCESS = 20, N_FIELD_RESERVED = 21,
    N_FIELD_CONNECT = 22,
    /* #1051 / #1052 */
    N_CALL = 23, N_EXPR = 24, N_IF = 25, N_ELSE = 26, N_WHILE = 27,
    N_RETURN = 28, N_BREAK = 29, N_CONTINUE = 30, N_NOOP = 31,
    N_BREAKPOINT = 32, N_INT = 33, N_STRING = 34, N_BUFFER = 35,
    N_PACKAGE = 36, N_VARPACKAGE = 37, N_NAMEREF = 38, N_ARGX = 39,
    N_LOCALX = 40, N_MISC = 41,
    /* #1053 */
    N_RESOURCE = 42, N_RESDESC = 43
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
    eq("BufferOp flags", aml_optab_flags(buf), 0x01 | 0x40);
    eq("BufferOp node", aml_optab_node(buf), N_BUFFER);
    uint64_t add = aml_optab_find(0x72);
    eq("AddOp argc", aml_optab_argc(add), 3);
    eq("AddOp node", aml_optab_node(add), N_EXPR);
    eq("AddOp shape is regular", aml_optab_shape(add), 0);

    /* #1051: the five irregular operand shapes, and only those. */
    eq("MatchOp shape", aml_optab_shape(aml_optab_find(0x89)), 2);
    eq("CreateDWordField shape", aml_optab_shape(aml_optab_find(0x8A)), 1);
    eq("CreateField shape", aml_optab_shape(aml_optab_find(0x5B13)), 1);
    eq("LoadOp shape", aml_optab_shape(aml_optab_find(0x5B20)), 5);
    eq("AcquireOp shape", aml_optab_shape(aml_optab_find(0x5B23)), 3);
    eq("FatalOp shape", aml_optab_shape(aml_optab_find(0x5B32)), 4);
    eq("IfOp node", aml_optab_node(aml_optab_find(0xA0)), N_IF);
    eq("ReturnOp argc", aml_optab_argc(aml_optab_find(0xA4)), 1);
    eq("Local3Op node", aml_optab_node(aml_optab_find(0x63)), N_LOCALX);
    eq("Arg2Op node", aml_optab_node(aml_optab_find(0x6A)), N_ARGX);
    eq("DebugOp node", aml_optab_node(aml_optab_find(0x5B31)), N_MISC);

    /* Every shape is on an expression opcode, and every non-namespace
     * opcode this parser claims to handle really does carry a node kind
     * for it to allocate — a row with F_M1_HANDLED and no node would
     * dispatch to nothing. */
    for (uint64_t i = 0; i < aml_optab_len; i++) {
        uint64_t e = aml_optab[i];
        g_checks++;
        if (aml_optab_shape(e) && aml_optab_class(e) != 4)
            fail("row %llu carries a shape but is not an expression",
                 (unsigned long long)i);
        g_checks++;
        if ((aml_optab_flags(e) & 0x40) && aml_optab_class(e) != 1
            && aml_optab_node(e) == 0)
            fail("row %llu is handled but allocates no node",
                 (unsigned long long)i);
    }

    /* The opaque-skip path is currently unreachable: #1051/#1052 parse
     * every PkgLength-bearing opcode ACPI 6.5 defines. If a later issue
     * adds an unhandled one, this assertion fires and forces the opaque
     * path back under test rather than letting it rot. */
    {
        int opaque_rows = 0;
        for (uint64_t i = 0; i < aml_optab_len; i++)
            if (aml_optab_flags(aml_optab[i]) & 0x80) opaque_rows++;
        eq("no opcode still needs the opaque path", (uint64_t)opaque_rows, 0);
    }

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
            /* bit 15 is the "body parsed" mark #1051 adds, so the
             * MethodFlags byte is read out of the low half. */
            eq("flags byte", aml_node_flags(m) & 0xFF, 0x0B);
            eq("body pass mark", (aml_node_flags(m) >> 15) & 1, 1);
            eq("argcount", aml_method_argcount(m), 3);
            eq("serialized", aml_method_serialized(m), 1);
            eq("synclevel", aml_method_synclevel(m), 0);
            eq("body start", aml_node_arg0(m), 7);
            eq("body end", aml_node_arg1(m), 7);
            eq("empty body has no children", (uint64_t)count_children(m), 0);
            eq("body pass ran", (aml_node_flags(m) >> 15) & 1, 1);
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
            /* #1051: the body IS descended now — two Noops. */
            eq("body descended", (uint64_t)count_children(m), 2);
            eq("noop 0", aml_node_kind(nth_child(m, 0)), N_NOOP);
            eq("noop 1", aml_node_kind(nth_child(m, 1)), N_NOOP);
            eq("method flags survive the body mark", aml_node_flags(m) & 0xFF,
               0x51);
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
        /* #1052: the payload is no longer merely skipped. */
        uint64_t bf = aml_node_first_child(nm);
        eq("buffer node", aml_node_kind(bf), N_BUFFER);
        eq("buffer size is a literal 2",
           aml_u64_get(aml_node_arg0(aml_node_first_child(bf))), 2);
        eq("buffer data start", aml_node_arg0(bf), 9);
        eq("buffer data end", aml_node_arg1(bf), 11);
        uint64_t sc = nth_child(root, 1);
        eq("resynchronised", aml_node_kind(sc), N_SCOPE);
        eq("scope name", aml_name_seg(aml_node_name(sc), 0), SEG4('Z','Z','Z','Z'));
    });

    /* #1051: a top-level If is now really parsed. Pass A records its
     * extent, pass B fills in predicate and body, and the term after it
     * still resynchronises exactly. */
    {
        /* If (One) { Noop }  followed by  Scope(QQQQ) {} */
        uint8_t b2[] = { 0xA0, 0x03, 0x01, 0xA3, 0x10, 0x05, 'Q','Q','Q','Q' };
        WITH_PARSE("parse top-level If", b2, sizeof b2, {
            eq("err", aml_lex_err(), AML_OK);
            eq("consumed all", aml_lex_pos(), sizeof b2);
            uint64_t op = nth_child(root, 0);
            eq("if kind", aml_node_kind(op), N_IF);
            eq("if src_off", aml_node_src_off(op), 0);
            eq("predicate start", aml_node_arg0(op), 2);
            eq("package end", aml_node_arg1(op), 4);
            eq("body pass ran", (aml_node_flags(op) >> 15) & 1, 1);
            /* child 0 is the predicate; the body follows it */
            eq("children", (uint64_t)count_children(op), 2);
            eq("predicate is One", aml_node_kind(nth_child(op, 0)), N_INT);
            eq("predicate value",
               aml_u64_get(aml_node_arg0(nth_child(op, 0))), 1);
            eq("body term", aml_node_kind(nth_child(op, 1)), N_NOOP);
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
        /* a real opcode with no PkgLength that this milestone cannot skip.
         * StoreOp used to sit here; #1051 parses it, so the case moved to
         * DataRegionOp, which ACPI 6.5 defines and R30.M1 still does not
         * implement — the distinction UNEXPECTED_OP exists to draw. */
        { "malformed: unexpected opcode", { 0x5B, 0x88, 0x00 }, 3, E_UNEXPECTED_OP },
        /* a control-flow opcode where a value is required: Noop is a
         * statement, never a TermArg, and the buffer size operand is a
         * TermArg position */
        { "malformed: control flow in TermArg position",
          { 0x08, 'X','X','X','X', 0x11, 0x02, 0xA3 }, 8, E_BAD_TERMARG },
        /* #1051: a bare NameString naming nothing at all cannot have its
         * arity determined, and is refused rather than assumed to be a
         * zero-argument reference. */
        { "malformed: unresolvable invocation", { 'A','A','A','A' }, 4,
          E_UNRESOLVED_CALL },
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
    /* Node arena: a Noop is one byte and allocates one unnamed node with
     * no side-table entry, so the node arena is the only resource it can
     * exhaust. (#1051 changed this fixture from empty Buffers, which now
     * really parse and would hit the u64 side table first.) */
    {
        static uint8_t b[600];
        for (size_t i = 0; i < sizeof b; i++) b[i] = 0xA3;
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

/* ================================================ #1051 control flow */

/* Method(CTRL, 0) {
 *     If (One)  { Return (Zero) }
 *     Else      { Noop }
 *     While (Zero) { Break }
 * }
 * Every body here is reached only by PASS B — pass A records the extents
 * and does not enter them — so this fixture is simultaneously a test of
 * control-flow parsing and of the two-pass loader. */
static void test_parse_control_flow(void)
{
    uint8_t b[] = {
        0x14, 0x12, 'C','T','R','L', 0x00,
            0xA0, 0x04, 0x01, 0xA4, 0x00,
            0xA1, 0x02, 0xA3,
            0xA2, 0x03, 0x00, 0xA5
    };
    WITH_PARSE("parse If/Else/While/Return/Break", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        uint64_t m = aml_node_first_child(root);
        eq("method kind", aml_node_kind(m), N_METHOD);
        eq("method children", (uint64_t)count_children(m), 3);

        uint64_t iff = nth_child(m, 0);
        eq("if kind", aml_node_kind(iff), N_IF);
        eq("if children", (uint64_t)count_children(iff), 2);
        eq("if predicate", aml_node_kind(nth_child(iff, 0)), N_INT);
        uint64_t rt = nth_child(iff, 1);
        eq("return kind", aml_node_kind(rt), N_RETURN);
        eq("return has an operand", (uint64_t)count_children(rt), 1);
        eq("return operand is Zero",
           aml_u64_get(aml_node_arg0(aml_node_first_child(rt))), 0);
        eq("return operand was explicit", aml_node_flags(rt) & 1, 0);

        /* the Else is the IMMEDIATELY FOLLOWING SIBLING of its If */
        uint64_t el = nth_child(m, 1);
        eq("else kind", aml_node_kind(el), N_ELSE);
        eq("else follows the if", aml_node_next_sibling(iff), el);
        eq("else children", (uint64_t)count_children(el), 1);
        eq("else body", aml_node_kind(aml_node_first_child(el)), N_NOOP);

        uint64_t wh = nth_child(m, 2);
        eq("while kind", aml_node_kind(wh), N_WHILE);
        eq("while children", (uint64_t)count_children(wh), 2);
        eq("while predicate", aml_node_kind(nth_child(wh, 0)), N_INT);
        eq("while body", aml_node_kind(nth_child(wh, 1)), N_BREAK);
    });
}

/* THE test for the two-pass design: AAAA calls BBBB, which is declared
 * AFTER it. A single-pass parser cannot know BBBB's argument count when
 * it reaches the call, and would have to guess. */
static void test_parse_forward_call(void)
{
    uint8_t b[] = {
        0x14, 0x0B, 'A','A','A','A', 0x00, 'B','B','B','B', 0x01,
        0x14, 0x07, 'B','B','B','B', 0x01, 0xA3
    };
    WITH_PARSE("parse forward method invocation", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        eq("root children", (uint64_t)count_children(root), 2);
        uint64_t a = nth_child(root, 0);
        eq("caller children", (uint64_t)count_children(a), 1);
        uint64_t c = aml_node_first_child(a);
        eq("call kind", aml_node_kind(c), N_CALL);
        eq("callee", aml_name_seg(aml_node_name(c), 0), SEG4('B','B','B','B'));
        eq("arity taken from the later declaration", aml_node_flags(c), 1);
        eq("argument parsed", (uint64_t)count_children(c), 1);
        eq("argument value",
           aml_u64_get(aml_node_arg0(aml_node_first_child(c))), 1);
        eq("argument extent start", aml_node_arg0(c), 11);
        eq("argument extent end", aml_node_arg1(c), 12);
    });
}

/* _OSI is supplied by the interpreter and declared by no table. Without
 * the built-in, essentially every shipping DSDT would be unparseable. */
static void test_parse_osi_builtin(void)
{
    uint8_t b[] = {
        0x14, 0x0D, 'T','O','S','I', 0x00,
            '_','O','S','I', 0x0D, 'W', 0x00
    };
    WITH_PARSE("parse _OSI built-in invocation", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        uint64_t c = aml_node_first_child(aml_node_first_child(root));
        eq("call kind", aml_node_kind(c), N_CALL);
        eq("built-in arity", aml_node_flags(c), 1);
        eq("argument is a string",
           aml_node_kind(aml_node_first_child(c)), N_STRING);
    });
}

/* External(EEEE, MethodObj, 2) is exactly the mechanism ACPI defines for
 * naming a method another table owns, and it is where the arity comes
 * from when the callee is not in this table at all. */
static void test_parse_external_call(void)
{
    uint8_t b[] = {
        0x15, 'E','E','E','E', 0x08, 0x02,
        0x14, 0x0C, 'C','C','C','C', 0x00, 'E','E','E','E', 0x00, 0x01
    };
    WITH_PARSE("parse External-declared invocation", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        uint64_t c = aml_node_first_child(nth_child(root, 1));
        eq("call kind", aml_node_kind(c), N_CALL);
        eq("arity from the External", aml_node_flags(c), 2);
        eq("both arguments parsed", (uint64_t)count_children(c), 2);
    });
}

/* A NameString that resolves to a non-method declaration is a reference
 * and consumes no further bytes — the other half of the same lookup. */
static void test_parse_nameref_not_call(void)
{
    uint8_t b[] = {
        0x08, 'A','B','C','D', 0x00,
        0x14, 0x0C, 'R','E','F','_', 0x00, 0x70, 'A','B','C','D', 0x60
    };
    WITH_PARSE("parse NameString as a reference", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        uint64_t st = aml_node_first_child(nth_child(root, 1));
        eq("store kind", aml_node_kind(st), N_EXPR);
        eq("store opcode", aml_node_flags(st), 0x70);
        eq("store operands", (uint64_t)count_children(st), 2);
        eq("source is a name reference",
           aml_node_kind(nth_child(st, 0)), N_NAMEREF);
        eq("target is Local0", aml_node_kind(nth_child(st, 1)), N_LOCALX);
        eq("local index", aml_node_flags(nth_child(st, 1)), 0);
    });
}

/* ================================================ #1052 data objects */

static void test_parse_package(void)
{
    /* Name(PKG_, Package(3){ 0x11, "hi", ABCD }) */
    uint8_t b[] = {
        0x08, 'P','K','G','_',
        0x12, 0x0C, 0x03,
            0x0A, 0x11,
            0x0D, 'h','i', 0x00,
            'A','B','C','D'
    };
    WITH_PARSE("parse Package with mixed elements", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        uint64_t nm = aml_node_first_child(root);
        eq("name data kind is package", aml_node_flags(nm), 4);
        uint64_t pk = aml_node_first_child(nm);
        eq("package kind", aml_node_kind(pk), N_PACKAGE);
        eq("declared element count", aml_node_flags(pk), 3);
        eq("elements parsed", (uint64_t)count_children(pk), 3);
        eq("element 0 is an integer", aml_node_kind(nth_child(pk, 0)), N_INT);
        eq("element 0 value",
           aml_u64_get(aml_node_arg0(nth_child(pk, 0))), 0x11);
        eq("element 1 is a string", aml_node_kind(nth_child(pk, 1)), N_STRING);
        /* a bare name inside a package is ALWAYS a reference — it is not
         * submitted to arity resolution, which is what lets a _PRT-shaped
         * package of device paths parse at all */
        eq("element 2 is a name reference",
           aml_node_kind(nth_child(pk, 2)), N_NAMEREF);
        eq("element 2 name",
           aml_name_seg(aml_node_name(nth_child(pk, 2)), 0),
           SEG4('A','B','C','D'));
    });
}

static void test_parse_varpackage_and_buffer(void)
{
    {   /* Name(VPK_, VarPackage(One){ Zero }) */
        uint8_t b[] = { 0x08, 'V','P','K','_', 0x13, 0x03, 0x01, 0x00 };
        WITH_PARSE("parse VarPackage", b, sizeof b, {
            eq("err", aml_lex_err(), AML_OK);
            uint64_t pk = aml_node_first_child(aml_node_first_child(root));
            eq("kind", aml_node_kind(pk), N_VARPACKAGE);
            eq("count is not a literal", aml_node_flags(pk), 0xFFFF);
            eq("children are count + element",
               (uint64_t)count_children(pk), 2);
        });
    }
    {   /* Name(BUF2, Buffer(3){ 0x11, 0x22, 0x33 }) */
        uint8_t b[] = { 0x08, 'B','U','F','2',
                        0x11, 0x06, 0x0A, 0x03, 0x11, 0x22, 0x33 };
        WITH_PARSE("parse Buffer with initialisers", b, sizeof b, {
            eq("err", aml_lex_err(), AML_OK);
            eq("consumed all", aml_lex_pos(), sizeof b);
            uint64_t bf = aml_node_first_child(aml_node_first_child(root));
            eq("kind", aml_node_kind(bf), N_BUFFER);
            eq("size operand", (uint64_t)count_children(bf), 1);
            eq("size value",
               aml_u64_get(aml_node_arg0(aml_node_first_child(bf))), 3);
            /* the initialiser bytes stay in the source buffer */
            eq("data start", aml_node_arg0(bf), 9);
            eq("data end", aml_node_arg1(bf), 12);
        });
    }
}

static void test_parse_reference_ops(void)
{
    /* Name(ABCD, Zero)
     * Method(REFS, 0) {
     *     Store(DerefOf(Index(ABCD, One, Zero)), Local0)
     *     CondRefOf(ABCD, Local1)
     * } */
    uint8_t b[] = {
        0x08, 'A','B','C','D', 0x00,
        0x14, 0x17, 'R','E','F','S', 0x00,
            0x70, 0x83, 0x88, 'A','B','C','D', 0x01, 0x00, 0x60,
            0x5B, 0x12, 'A','B','C','D', 0x61
    };
    WITH_PARSE("parse RefOf/DerefOf/Index/CondRefOf", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), sizeof b);
        uint64_t m = nth_child(root, 1);
        eq("statements", (uint64_t)count_children(m), 2);
        uint64_t st = nth_child(m, 0);
        eq("Store", aml_node_flags(st), 0x70);
        uint64_t dr = nth_child(st, 0);
        eq("DerefOf", aml_node_flags(dr), 0x83);
        eq("DerefOf arity", (uint64_t)count_children(dr), 1);
        uint64_t ix = aml_node_first_child(dr);
        eq("Index", aml_node_flags(ix), 0x88);
        eq("Index arity", (uint64_t)count_children(ix), 3);
        eq("Index source", aml_node_kind(nth_child(ix, 0)), N_NAMEREF);
        /* the two-byte extended form reaches the same expression path */
        uint64_t cr = nth_child(m, 1);
        eq("CondRefOf", aml_node_flags(cr), 0x5B12);
        eq("CondRefOf arity", (uint64_t)count_children(cr), 2);
        eq("CondRefOf target", aml_node_kind(nth_child(cr, 1)), N_LOCALX);
        eq("CondRefOf target index", aml_node_flags(nth_child(cr, 1)), 1);
    });
}

/* ============================================ #1051/#1052 malformed */

static void test_parse_term_malformed(void)
{
    struct badcase c[] = {
/* (the If-overrun case has its own test below: the CODE alone does not
 * witness the containment check, because the enclosing TermList loop
 * would eventually report the same one) */
        /* Else with nothing before it at all */
        { "malformed: Else without If",
          { 0x14, 0x09, 'H','H','H','H', 0x00, 0xA1, 0x02, 0xA3 }, 10,
          E_ELSE_WITHOUT_IF },
        /* Else with a preceding sibling that is not an If. Distinct from
         * the case above: that one is caught by the "no sibling at all"
         * test, this one exercises the KIND test, and a mutation that
         * disabled only the latter would otherwise survive. */
        { "malformed: Else after a non-If sibling",
          { 0x14, 0x0A, 'J','J','J','J', 0x00, 0xA3, 0xA1, 0x02, 0xA3 }, 11,
          E_ELSE_WITHOUT_IF },
        /* two declarations of one name that disagree on arity: refused
         * rather than resolved by picking either */
        { "malformed: ambiguous method arity",
          { 0x14, 0x06, 'F','F','F','F', 0x01,
            0x14, 0x06, 'F','F','F','F', 0x02,
            0x14, 0x0B, 'G','G','G','G', 0x00, 'F','F','F','F', 0x00 }, 26,
          E_AMBIGUOUS_CALL },
        /* a package whose encoded initialiser list is LONGER than the
         * element count it declares */
        { "malformed: more package elements than declared",
          { 0x08, 'B','A','D','P', 0x12, 0x04, 0x01, 0x00, 0x01 }, 10,
          E_PKG_ELEM_COUNT },
        /* a buffer whose literal size exceeds the bytes its PkgLength
         * reserved */
        { "malformed: Buffer size exceeds its extent",
          { 0x08, 'B','A','D','B', 0x11, 0x03, 0x0A, 0x10 }, 9,
          E_BUF_SIZE_OVF },
    };
    for (volatile size_t i = 0; i < sizeof c / sizeof c[0]; i++) {
        WITH_PARSE(c[i].name, c[i].b, c[i].n, {
            eq("rejected", root, 0);
            eq("error code", aml_lex_err(), c[i].err);
        });
    }
}

/* An If whose PkgLength runs past the end of the method body containing
 * it. The If still fits the BUFFER, so the lexer's bound does not catch
 * it — and neither does the error CODE distinguish anything, because the
 * enclosing TermList loop reports AML_ERR_PKG_OVERRUN too once the cursor
 * has walked out of the parent. What distinguishes them is WHERE the
 * error is latched: the containment check fires immediately after the
 * lying PkgLength, before a single byte of the body has been read or a
 * single node allocated from bytes that belong to the parent. So the
 * witness is err_off, not err. */
static void test_if_containment_is_early(void)
{
    uint8_t b[] = { 0x14, 0x09, 'I','I','I','I', 0x00, 0xA0, 0x05, 0x01,
                    0x10, 0x05, 'Z','Z','Z','Z' };
    WITH_PARSE("malformed: If overruns the enclosing TermList", b, sizeof b, {
        eq("rejected", root, 0);
        eq("error code", aml_lex_err(), E_PKG_OVERRUN);
        eq("latched at the PkgLength, not at the far end of the damage",
           aml_lex_err_off(), 9);
        /* root, the method and the Scope after it — and nothing at all
         * from inside the bogus If, not even the If node itself */
        eq("nodes allocated", aml_node_count(), 4);
    });
}

/* A Package whose declared count EXCEEDS what it encodes is legal — the
 * remainder is uninitialised — and rejecting it would refuse real
 * firmware. This asserts the check runs one way only. */
static void test_parse_package_underfilled(void)
{
    uint8_t b[] = { 0x08, 'U','N','D','R', 0x12, 0x04, 0xFF, 0x00, 0x01 };
    WITH_PARSE("parse under-filled Package is legal", b, sizeof b, {
        eq("err", aml_lex_err(), AML_OK);
        uint64_t pk = aml_node_first_child(aml_node_first_child(root));
        eq("declared", aml_node_flags(pk), 0xFF);
        eq("encoded", (uint64_t)count_children(pk), 2);
    });
}

/* ============================================== #1053 resource templates */

static void putle(uint8_t *b, size_t off, uint64_t v, int w)
{
    for (int i = 0; i < w; i++) b[off + (size_t)i] = (uint8_t)(v >> (8 * i));
}

/* Append the EndTag and a checksum that makes the whole template sum to
 * zero modulo 256. */
static size_t res_finish(uint8_t *b, size_t k)
{
    unsigned sum = 0;
    b[k++] = 0x79;
    for (size_t i = 0; i < k; i++) sum += b[i];
    b[k++] = (uint8_t)((0x100u - (sum & 0xFFu)) & 0xFFu);
    return k;
}

/* Name(<seg>, Buffer(n){ data }) */
static size_t emit_name_buffer(uint8_t *out, const char *seg,
                               const uint8_t *data, size_t n)
{
    uint8_t payload[768];
    size_t pl = 0;
    payload[pl++] = 0x0B;                       /* WordPrefix size */
    payload[pl++] = (uint8_t)(n & 0xFF);
    payload[pl++] = (uint8_t)(n >> 8);
    memcpy(payload + pl, data, n); pl += n;

    uint8_t pk[4];
    size_t pn = emit_pkglen(pk, pl), k = 0;
    out[k++] = 0x08;
    memcpy(out + k, seg, 4); k += 4;
    out[k++] = 0x11;
    memcpy(out + k, pk, pn); k += pn;
    memcpy(out + k, payload, pl); k += pl;
    return k;
}

static size_t build_crs(uint8_t *r)
{
    size_t k = 0;
    /* IRQ, small item 4: mask = IRQ 4 */
    r[k++] = 0x22; putle(r, k, 0x0010, 2); k += 2;
    /* DMA, small item 5: channel 2, flags 0 */
    r[k++] = 0x2A; r[k++] = 0x04; r[k++] = 0x00;
    /* IO, small item 8: 0x60..0x60, align 1, length 2 */
    r[k++] = 0x47; r[k++] = 0x01;
    putle(r, k, 0x60, 2); k += 2;
    putle(r, k, 0x60, 2); k += 2;
    r[k++] = 0x01; r[k++] = 0x02;
    /* Memory32Fixed, large item 6 */
    r[k++] = 0x86; putle(r, k, 9, 2); k += 2;
    r[k++] = 0x01;
    putle(r, k, 0xFED00000u, 4); k += 4;
    putle(r, k, 0x1000, 4); k += 4;
    /* WordSpace, large item 8: bus range 0..0xFF */
    r[k++] = 0x88; putle(r, k, 13, 2); k += 2;
    r[k++] = 0x02; r[k++] = 0x00; r[k++] = 0x00;
    putle(r, k, 0, 2); k += 2;                    /* granularity */
    putle(r, k, 0x0000, 2); k += 2;               /* min */
    putle(r, k, 0x00FF, 2); k += 2;               /* max */
    putle(r, k, 0, 2); k += 2;                    /* translation */
    putle(r, k, 0x0100, 2); k += 2;               /* length */
    /* DWordSpace, large item 7 */
    r[k++] = 0x87; putle(r, k, 23, 2); k += 2;
    r[k++] = 0x00; r[k++] = 0x00; r[k++] = 0x00;
    putle(r, k, 0, 4); k += 4;
    putle(r, k, 0x80000000u, 4); k += 4;
    putle(r, k, 0x8FFFFFFFu, 4); k += 4;
    putle(r, k, 0, 4); k += 4;
    putle(r, k, 0x10000000u, 4); k += 4;
    /* QWordSpace, large item 10 */
    r[k++] = 0x8A; putle(r, k, 43, 2); k += 2;
    r[k++] = 0x00; r[k++] = 0x00; r[k++] = 0x00;
    putle(r, k, 0, 8); k += 8;
    putle(r, k, 0x100000000ull, 8); k += 8;
    putle(r, k, 0x1FFFFFFFFull, 8); k += 8;
    putle(r, k, 0, 8); k += 8;
    putle(r, k, 0x100000000ull, 8); k += 8;
    /* GpioInt, large item 12 — pin table at descriptor offset 23 */
    r[k++] = 0x8C; putle(r, k, 23, 2); k += 2;
    r[k++] = 0x01;                                /* revision */
    r[k++] = 0x00;                                /* GpioInt */
    putle(r, k, 0, 2); k += 2;                    /* general flags */
    putle(r, k, 0x0009, 2); k += 2;               /* interrupt flags */
    r[k++] = 0x00;                                /* pin config */
    putle(r, k, 0, 2); k += 2;                    /* drive strength */
    putle(r, k, 0, 2); k += 2;                    /* debounce */
    putle(r, k, 23, 2); k += 2;                   /* PinTableOffset */
    r[k++] = 0x00;                                /* source index */
    putle(r, k, 25, 2); k += 2;                   /* SourceNameOffset */
    putle(r, k, 26, 2); k += 2;                   /* VendorDataOffset */
    putle(r, k, 0, 2); k += 2;                    /* VendorDataLength */
    putle(r, k, 0x004B, 2); k += 2;               /* the one pin */
    r[k++] = 0x00;                                /* source name */
    /* I2cSerialBus, large item 14 — 400 kHz, slave 0x2C */
    r[k++] = 0x8E; putle(r, k, 16, 2); k += 2;
    r[k++] = 0x01;                                /* revision */
    r[k++] = 0x00;                                /* source index */
    r[k++] = 0x01;                                /* SerialBusType = I2C */
    r[k++] = 0x00;                                /* general flags */
    putle(r, k, 0, 2); k += 2;                    /* type flags */
    r[k++] = 0x01;                                /* type revision */
    putle(r, k, 6, 2); k += 2;                    /* type data length */
    putle(r, k, 400000, 4); k += 4;               /* connection speed */
    putle(r, k, 0x002C, 2); k += 2;               /* slave address */
    r[k++] = 0x00;                                /* source name */
    return res_finish(r, k);
}

static void test_resource_template(void)
{
    static uint8_t res[512], aml[768];
    size_t rn = build_crs(res);
    size_t n = emit_name_buffer(aml, "_CRS", res, rn);

    WITH_PARSE("parse and decode a _CRS resource template", aml, n, {
        eq("err", aml_lex_err(), AML_OK);
        uint64_t nm = aml_node_first_child(root);
        uint64_t bf = aml_node_first_child(nm);
        eq("buffer kind", aml_node_kind(bf), N_BUFFER);
        eq("descriptor bytes", aml_node_arg1(bf) - aml_node_arg0(bf),
           (uint64_t)rn);

        /* the discriminator accepts it, and parsing is LAZY — nothing
         * resource-shaped exists until asked for */
        eq("no resource node before the request",
           (uint64_t)count_children(bf), 1);
        eq("discriminator accepts", aml_res_is_template(bf), 1);
        eq("asking did not latch", aml_lex_err(), AML_OK);

        uint64_t rs = aml_res_parse(bf);
        eq("parsed", (uint64_t)(rs != 0), 1);
        eq("err", aml_lex_err(), AML_OK);
        eq("resource kind", aml_node_kind(rs), N_RESOURCE);
        eq("descriptors", (uint64_t)count_children(rs), 10);

        uint64_t d;
        d = nth_child(rs, 0);
        eq("IRQ tag", aml_res_tag(d), 4);
        eq("IRQ is small", aml_res_large(d), 0);
        eq("IRQ mask", aml_res_u16(d, 0), 0x0010);
        eq("IRQ payload length", aml_res_data_len(d), 2);

        d = nth_child(rs, 1);
        eq("DMA tag", aml_res_tag(d), 5);
        eq("DMA channel mask", aml_res_u8(d, 0), 0x04);

        d = nth_child(rs, 2);
        eq("IO tag", aml_res_tag(d), 8);
        eq("IO min", aml_res_u16(d, 1), 0x60);
        eq("IO max", aml_res_u16(d, 3), 0x60);
        eq("IO alignment", aml_res_u8(d, 5), 1);
        eq("IO length", aml_res_u8(d, 6), 2);

        d = nth_child(rs, 3);
        eq("Memory32Fixed tag", aml_res_tag(d), 6);
        eq("Memory32Fixed is large", aml_res_large(d), 1);
        eq("Memory32Fixed base", aml_res_u32(d, 1), 0xFED00000u);
        eq("Memory32Fixed length", aml_res_u32(d, 5), 0x1000);

        d = nth_child(rs, 4);
        eq("WordSpace tag", aml_res_tag(d), 8);
        eq("WordSpace width", aml_res_space_width(d), 2);
        eq("WordSpace min", aml_res_space_min(d), 0x0000);
        eq("WordSpace max", aml_res_space_max(d), 0x00FF);
        eq("WordSpace length", aml_res_space_len(d), 0x0100);

        d = nth_child(rs, 5);
        eq("DWordSpace width", aml_res_space_width(d), 4);
        eq("DWordSpace min", aml_res_space_min(d), 0x80000000u);
        eq("DWordSpace max", aml_res_space_max(d), 0x8FFFFFFFu);
        eq("DWordSpace length", aml_res_space_len(d), 0x10000000u);

        d = nth_child(rs, 6);
        eq("QWordSpace width", aml_res_space_width(d), 8);
        eq("QWordSpace min", aml_res_space_min(d), 0x100000000ull);
        eq("QWordSpace max", aml_res_space_max(d), 0x1FFFFFFFFull);
        eq("QWordSpace length", aml_res_space_len(d), 0x100000000ull);

        d = nth_child(rs, 7);
        eq("Gpio tag", aml_res_tag(d), 12);
        eq("Gpio is an interrupt", aml_res_gpio_type(d), 0);
        eq("Gpio pin count", aml_res_gpio_pin_count(d), 1);
        eq("Gpio pin 0", aml_res_gpio_pin(d, 0), 0x004B);

        d = nth_child(rs, 8);
        eq("SerialBus tag", aml_res_tag(d), 14);
        eq("bus type is I2C", aml_res_serial_type(d), 1);
        eq("I2C speed", aml_res_i2c_speed(d), 400000);
        eq("I2C slave address", aml_res_i2c_addr(d), 0x2C);

        d = nth_child(rs, 9);
        eq("EndTag tag", aml_res_tag(d), 15);
        eq("EndTag carries the checksum byte", aml_res_data_len(d), 1);

        /* a field beyond the descriptor reads 0 rather than the
         * neighbouring descriptor's bytes */
        eq("read past the descriptor", aml_res_u32(nth_child(rs, 0), 4), 0);
        /* and the accessors leave the cursor where they found it */
        eq("cursor undisturbed", aml_lex_pos(), n);
    });
}

/* Not every Buffer is a resource template, and misreading an ordinary
 * one as a template would be a correctness bug. The discriminator is
 * whole-buffer validation, so it says no — and says it without latching
 * an error, because "not a template" is not a fault. */
static void test_resource_discriminator(void)
{
    static uint8_t aml[128];
    uint8_t data[] = { 0x22, 0xDE, 0xAD, 0xBE, 0xEF };   /* starts like an IRQ */
    size_t n = emit_name_buffer(aml, "DATA", data, sizeof data);
    WITH_PARSE("ordinary Buffer is not a resource template", aml, n, {
        eq("err", aml_lex_err(), AML_OK);
        uint64_t bf = aml_node_first_child(aml_node_first_child(root));
        eq("kind", aml_node_kind(bf), N_BUFFER);
        eq("discriminator refuses", aml_res_is_template(bf), 0);
        eq("nothing was latched", aml_lex_err(), AML_OK);
        eq("nothing was allocated", (uint64_t)count_children(bf), 1);
        /* the same buffer through the asserting entry point DOES latch,
         * and names the reason */
        eq("parse refuses", aml_res_parse(bf), 0);
        /* 0x22 does begin like an IRQ, so the walk gets three bytes in
         * before 0xBE turns out to be a reserved large item name — which
         * is exactly why a first-byte sniff would have accepted this. */
        eq("reason", aml_lex_err(), E_RES_BAD_TAG);
    });
}

/* The malformed resource corpus runs against aml_res_validate directly:
 * it returns the code instead of latching it, so every case can be
 * asserted from one fixture without a fresh parse each time. */
static void test_resource_malformed(void)
{
    struct { const char *name; uint8_t b[32]; size_t n; uint64_t err; } c[] = {
        /* a correct non-zero checksum is accepted */
        { "resource: valid checksum", { 0x22, 0x10, 0x00, 0x79, 0x55 }, 5,
          AML_OK },
        /* checksum byte 0 means "not computed" (§6.4.2.9) */
        { "resource: checksum 0 means not computed",
          { 0x22, 0x10, 0x00, 0x79, 0x00 }, 5, AML_OK },
        /* a non-zero checksum that does not make the sum vanish */
        { "resource: bad EndTag checksum",
          { 0x22, 0x10, 0x00, 0x79, 0x01 }, 5, E_RES_CHECKSUM },
        /* a small descriptor cut off mid-payload */
        { "resource: truncated mid-descriptor", { 0x22, 0x10 }, 2,
          E_RES_TRUNCATED },
        /* a large descriptor whose 16-bit length field claims more bytes
         * than the buffer holds */
        { "resource: large length overruns",
          { 0x86, 0xFF, 0x00, 0x01, 0x02 }, 5, E_RES_LENGTH },
        /* a large descriptor whose 3-byte header is itself cut short */
        { "resource: large header truncated", { 0x86, 0x09 }, 2,
          E_RES_TRUNCATED },
        /* no EndTag at all */
        { "resource: no EndTag", { 0x22, 0x10, 0x00 }, 3, E_RES_NO_ENDTAG },
        /* bytes after the EndTag */
        { "resource: trailing bytes after EndTag",
          { 0x22, 0x10, 0x00, 0x79, 0x00, 0xFF }, 6, E_RES_NO_ENDTAG },
        /* a reserved small item name */
        { "resource: reserved small tag", { 0x00, 0x79, 0x00 }, 3,
          E_RES_BAD_TAG },
        /* a reserved large item name */
        { "resource: reserved large tag",
          { 0x83, 0x00, 0x00, 0x79, 0x00 }, 5, E_RES_BAD_TAG },
        /* an EndTag with the wrong length nibble */
        { "resource: EndTag with no checksum byte",
          { 0x22, 0x10, 0x00, 0x78 }, 4, E_RES_TRUNCATED },
        /* an empty buffer is not a template */
        { "resource: empty", { 0x00 }, 0, E_RES_NO_ENDTAG }
    };
    for (volatile size_t i = 0; i < sizeof c / sizeof c[0]; i++) {
        WITH_FIXTURE(c[i].name, c[i].b, c[i].n, {
            eq("validation code", aml_res_validate(0, c[i].n), c[i].err);
            /* a question must never poison the parse that asked it */
            eq("nothing latched", aml_lex_err(), AML_OK);
        });
    }
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

    test_parse_control_flow();
    test_parse_forward_call();
    test_parse_osi_builtin();
    test_parse_external_call();
    test_parse_nameref_not_call();
    test_parse_package();
    test_parse_varpackage_and_buffer();
    test_parse_reference_ops();
    test_parse_package_underfilled();
    test_resource_template();
    test_resource_discriminator();

    test_parse_malformed();
    test_parse_term_malformed();
    test_if_containment_is_early();
    test_resource_malformed();
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
