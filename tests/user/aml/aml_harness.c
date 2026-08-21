/* tests/user/aml/aml_harness.c — R30.M1-001 (#1049) / R30.M1-002 (#1050)
 *                                 R30.M1-003 (#1051) / R30.M1-004 (#1052)
 *                                 R30.M1-005 (#1053)
 *                                 R30.M2-001 (#1054) / R30.M2-002 (#1055)
 *                                 R30.M3-002 (#1062)
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

/* #1054 — evaluator core: context, budgets, frames, namespace walker */
extern void     aml_eval_reset(uint64_t revision);
extern uint64_t aml_eval_err(void);
extern uint64_t aml_eval_set_err(uint64_t code);
extern uint64_t aml_eval_set_fuel(uint64_t budget);
extern uint64_t aml_eval_fuel(void);
extern uint64_t aml_eval_budget(void);
extern uint64_t aml_eval_depth(void);
extern uint64_t aml_eval_frames(void);
extern uint64_t aml_eval_scope(void);
extern void     aml_eval_set_scope(uint64_t node);
extern uint64_t aml_eval_revision(void);
extern uint64_t aml_eval_retval(void);
extern uint64_t aml_eval_width(void);
extern uint64_t aml_eval_ones(void);
extern uint64_t aml_eval_trunc(uint64_t v);
extern uint64_t aml_eval_spend(void);
extern uint64_t aml_eval_enter(void);
extern void     aml_eval_leave(void);
extern uint64_t aml_frame_push(uint64_t method_node);
extern void     aml_frame_pop(void);
extern uint64_t aml_frame_method(void);
extern uint64_t aml_frame_arg(uint64_t i);
extern uint64_t aml_frame_set_arg(uint64_t i, uint64_t v);
extern uint64_t aml_frame_local(uint64_t i);
extern uint64_t aml_frame_set_local(uint64_t i, uint64_t v);
extern uint64_t aml_eval_names(uint64_t kind);
extern uint64_t aml_eval_abspath(uint64_t node, uint64_t which);
extern uint64_t aml_eval_path_len(uint64_t which);
extern uint64_t aml_eval_find(uint64_t len);
extern uint64_t aml_eval_resolve(uint64_t scope, uint64_t name_ref);
extern uint64_t aml_eval_read_named(uint64_t node);
extern uint64_t aml_eval_store(uint64_t target, uint64_t value);
extern uint64_t aml_eval_node(uint64_t node);
extern uint64_t aml_eval_stmt(uint64_t node);
extern uint64_t aml_eval_body(uint64_t parent, uint64_t skip);
extern uint64_t aml_eval_call(uint64_t call_node);
extern uint64_t aml_eval_method(uint64_t method_node);

/* #1055 — arithmetic and logical operators */
extern uint64_t aml_arith_child(uint64_t node, uint64_t n);
extern uint64_t aml_arith_handles(uint64_t op16);
extern uint64_t aml_arith_eval(uint64_t expr_node);

/* Also needed by the evaluator corpus (#1054 added the setter). */
extern uint64_t aml_u64_set(uint64_t ref, uint64_t value);

/* #1056 / #1057 — the object model */
extern void     aml_obj_reset(void);
extern uint64_t aml_obj_count(void);
extern uint64_t aml_obj_heap_used(void);
extern uint64_t aml_obj_elem_used(void);
extern uint64_t aml_obj_alloc(uint64_t ty);
extern uint64_t aml_obj_word(uint64_t o, uint64_t w);
extern uint64_t aml_obj_set_word(uint64_t o, uint64_t w, uint64_t v);
extern uint64_t aml_obj_type(uint64_t o);
extern uint64_t aml_obj_refkind(uint64_t o);
extern uint64_t aml_obj_base(uint64_t o);
extern uint64_t aml_obj_len(uint64_t o);
extern uint64_t aml_obj_aux(uint64_t o);
extern uint64_t aml_obj_int(uint64_t v);
extern uint64_t aml_obj_int_value(uint64_t o);
extern uint64_t aml_obj_heap_alloc(uint64_t n);
extern uint64_t aml_obj_heap_get(uint64_t off);
extern uint64_t aml_obj_heap_set(uint64_t off, uint64_t b);
extern uint64_t aml_obj_str_alloc(uint64_t n);
extern uint64_t aml_obj_buf_alloc(uint64_t n);
extern uint64_t aml_obj_byte(uint64_t o, uint64_t i);
extern uint64_t aml_obj_set_byte(uint64_t o, uint64_t i, uint64_t b);
extern uint64_t aml_obj_copy(uint64_t d, uint64_t doff, uint64_t sO,
                             uint64_t soff, uint64_t n);
extern uint64_t aml_obj_pkg_alloc(uint64_t n);
extern uint64_t aml_obj_elem_get(uint64_t o, uint64_t i);
extern uint64_t aml_obj_elem_set(uint64_t o, uint64_t i, uint64_t v);
extern uint64_t aml_obj_ref(uint64_t k, uint64_t b, uint64_t i, uint64_t ser);
extern uint64_t aml_obj_bind_get(uint64_t n);
extern uint64_t aml_obj_bind_set(uint64_t n, uint64_t o);
extern uint64_t aml_obj_src_u8(uint64_t off);

/* #1056 — conversion and the String/Buffer operators */
extern uint64_t aml_conv_len;
extern uint64_t aml_conv_tab[];
extern uint64_t aml_conv_want(uint64_t op16, uint64_t pos);
extern uint64_t aml_conv_dec_digits(uint64_t v);
extern uint64_t aml_conv_int_to_str(uint64_t v, uint64_t base);
extern uint64_t aml_conv_buf_to_str(uint64_t o, uint64_t base);
extern uint64_t aml_conv_str_to_int(uint64_t o);
extern uint64_t aml_conv_buf_to_int(uint64_t o);
extern uint64_t aml_conv_int_to_buf(uint64_t v);
extern uint64_t aml_conv_str_to_buf(uint64_t o);
extern uint64_t aml_conv_cast(uint64_t o, uint64_t want);
extern uint64_t aml_conv_operand(uint64_t n, uint64_t pos);
extern uint64_t aml_str_cmp(uint64_t a, uint64_t b);
extern uint64_t aml_str_concat(uint64_t a, uint64_t b);
extern uint64_t aml_str_res_end(uint64_t o);
extern uint64_t aml_str_concat_res(uint64_t a, uint64_t b);
extern uint64_t aml_str_mid(uint64_t o, uint64_t i, uint64_t l);
extern uint64_t aml_str_tostring(uint64_t o, uint64_t l);
extern uint64_t aml_str_sizeof(uint64_t o);
extern uint64_t aml_str_match_one(uint64_t e, uint64_t op, uint64_t a);
extern uint64_t aml_str_match(uint64_t n);
extern uint64_t aml_str_handles(uint64_t op16);
extern uint64_t aml_str_eval(uint64_t n);

/* #1057 — packages, references, Index */
extern uint64_t aml_ref_node_objtype(uint64_t n);
extern uint64_t aml_ref_objtype(uint64_t o);
extern uint64_t aml_ref_deref(uint64_t o);
extern uint64_t aml_ref_index(uint64_t sO, uint64_t i);
extern uint64_t aml_ref_of_node(uint64_t n, uint64_t q);
extern uint64_t aml_ref_store_through(uint64_t r, uint64_t sO);
extern uint64_t aml_ref_handles(uint64_t op16);

/* #1058 — invocation: the return-value tag and the arity cross-check. */
extern uint64_t aml_conv_argop;
extern uint64_t aml_eval_retval_is_obj(void);
extern uint64_t aml_eval_arity_ok(uint64_t call_node, uint64_t method_node);

/* #1059 — the notification ring. */
extern uint64_t aml_ctl_handles(uint64_t op16);
extern uint64_t aml_ctl_notify_kind_ok(uint64_t kind);
extern uint64_t aml_ctl_notify_objtype(uint64_t kind);
extern uint64_t aml_ctl_notify(uint64_t expr_node);
extern void     aml_notify_reset(void);
extern uint64_t aml_notify_depth(void);
extern uint64_t aml_notify_drops(void);
extern uint64_t aml_notify_drained(void);
extern uint64_t aml_notify_offered(void);
extern uint64_t aml_notify_peek(uint64_t field);
extern uint64_t aml_notify_pop(void);
extern uint64_t aml_notify_enqueue(uint64_t node, uint64_t val, uint64_t objtype);

/* #1060 — serialized methods. */
extern void     aml_ctl_reset(void);
extern uint64_t aml_ctl_ctx(void);
/* #1581 — mint a fresh AML context id and latch it as current, WITHOUT
 * touching the mutex pool. aml_ctl_reset calls this under the hood so
 * every evaluation session enters with a distinct identity; the test
 * corpus below also calls it directly to reach the "held by another
 * context" arm of aml_ctl_acquire without wiping the pool. */
extern uint64_t aml_ctl_ctx_alloc(void);
extern uint64_t aml_ctl_level(void);
extern uint64_t aml_ctl_held(void);
extern uint64_t aml_ctl_acquires(void);
extern uint64_t aml_ctl_leaked(void);
extern uint64_t aml_ctl_count_of(uint64_t method_node);
extern uint64_t aml_ctl_acquire(uint64_t method_node);
extern uint64_t aml_ctl_release(uint64_t method_node);
extern uint64_t aml_method_argcount(uint64_t idx);
extern uint64_t aml_method_serialized(uint64_t idx);
extern uint64_t aml_method_synclevel(uint64_t idx);
extern uint64_t aml_ref_eval(uint64_t n);

/* #1062 — the SystemMemory address-space handler */
extern void     aml_region_reset(void);
extern uint64_t aml_region_count(void);
extern uint64_t aml_region_accesses(void);
extern uint64_t aml_region_refusals(void);
extern uint64_t aml_region_space_supported(uint64_t space);
extern uint64_t aml_region_mask(uint64_t n);
extern uint64_t aml_region_contains(uint64_t wb, uint64_t wl,
                                    uint64_t db, uint64_t dl);
extern uint64_t aml_region_row_live(uint64_t b);
extern uint64_t aml_region_node(uint64_t b);
extern uint64_t aml_region_space(uint64_t b);
extern uint64_t aml_region_base(uint64_t b);
extern uint64_t aml_region_len(uint64_t b);
extern uint64_t aml_region_cap(uint64_t b);
extern uint64_t aml_region_find(uint64_t node);
extern uint64_t aml_region_bind(uint64_t node, uint64_t cap, uint64_t wb,
                                uint64_t wl, uint64_t host);
extern uint64_t aml_region_bounds_ok(uint64_t b, uint64_t off, uint64_t n);
extern uint64_t aml_region_read_unit(uint64_t b, uint64_t off, uint64_t n);
extern uint64_t aml_region_write_unit(uint64_t b, uint64_t off, uint64_t n,
                                      uint64_t v);
extern uint64_t aml_region_acc_bits(uint64_t node, uint64_t space);
/* #1063 / #1064 / #1065 */
extern uint64_t aml_region_pci_ctx(uint64_t b);
extern uint64_t aml_region_row_word(uint64_t b, uint64_t w);
extern uint64_t aml_region_port_in(uint64_t port, uint64_t n);
extern uint64_t aml_region_port_out(uint64_t port, uint64_t n, uint64_t v);
extern uint64_t aml_region_pci_ecam_offset(uint64_t ctx);
extern uint64_t aml_region_pci_context(uint64_t node);
extern uint64_t aml_region_enclosing_device(uint64_t node);
extern uint64_t aml_region_host_bridge(uint64_t dev);
extern uint64_t aml_region_named_int(uint64_t scope, uint64_t seg);
extern uint64_t aml_region_named_int_val(uint64_t name_node);
extern uint64_t aml_region_ec_backing(void);
extern uint64_t aml_region_ec_hw_committed(void);
extern uint64_t aml_region_ec_gated(void);

/* R30.M7-001/002/003 (#1079 / #1080 / #1081) — the EC driver. */
extern uint64_t aml_ec_attach(uint64_t node, uint64_t data_port, uint64_t cmd_port);
extern uint64_t aml_ec_bound(void);
extern void     aml_ec_reset(void);
extern uint64_t aml_ec_stat(uint64_t which);
extern void     aml_ec_mode_set(uint64_t mode);
extern void     aml_ec_synth_reset(uint64_t wedge);
extern void     aml_ec_ram_poke(uint64_t addr, uint64_t value);
extern uint64_t aml_ec_ram_peek(uint64_t addr);
extern void     aml_ec_synth_query_set(uint64_t q);
extern uint64_t aml_ec_synth_writes(void);
extern uint64_t aml_ec_xact(uint64_t op, uint64_t addr, uint64_t value);
extern uint64_t aml_ec_query_pump(void);
extern uint64_t aml_ec_query_seg(uint64_t q);
extern void     aml_ec_probe_arm(uint64_t n);

/* R30.M8-001 (#1082) — the ACPI Global Lock. */
extern void     aml_glk_reset(void);
extern uint64_t aml_glk_attach(uint64_t facs_va, uint64_t pm1_cnt, uint64_t pm1_sts);
extern uint64_t aml_glk_bound(void);
extern void     aml_glk_mode_set(uint64_t mode);
extern uint64_t aml_glk_stat(uint64_t which);
extern void     aml_glk_synth_reset(uint64_t initial);
extern uint64_t aml_glk_facs_word(void);
extern uint64_t aml_glk_facs_guard(void);
extern uint64_t aml_glk_facs_addr(void);
extern void     aml_glk_smm_arm(uint64_t injections, uint64_t value);
extern void     aml_glk_smm_signal_after(uint64_t steps);
extern uint64_t aml_glk_smm_stat(uint64_t which);
extern uint64_t aml_glk_try(void);
extern uint64_t aml_glk_enter(void);
extern uint64_t aml_glk_leave(void);
extern uint64_t aml_glk_depth(void);
/* R30.M9-002 (#1086) — the death/teardown path. */
extern uint64_t aml_glk_abandon(void);
extern uint64_t aml_glk_abandon_stat(uint64_t which);
extern void     aml_glk_smm_step(void);
extern uint64_t aml_eval_find_in_scope(uint64_t scope, uint64_t seg);
extern uint64_t aml_region_acc_log(uint64_t aw);
extern uint64_t aml_region_of_field(uint64_t node);
extern uint64_t aml_region_field_binding(uint64_t node);
extern uint64_t aml_region_field_read(uint64_t node);
extern uint64_t aml_region_field_store(uint64_t node, uint64_t v);
extern uint64_t aml_region_field_load_obj(uint64_t node);
extern uint64_t aml_region_handles(uint64_t op16);

/* #1057 — evaluator additions */
extern uint64_t aml_eval_quiet(void);
extern uint64_t aml_eval_set_quiet(uint64_t v);
extern uint64_t aml_frame_bit(uint64_t k, uint64_t sl);
extern uint64_t aml_frame_serial_of(uint64_t f);
extern uint64_t aml_frame_slot_is_obj(uint64_t f, uint64_t k, uint64_t sl);
extern uint64_t aml_frame_ref_get(uint64_t f, uint64_t k, uint64_t sl);
extern uint64_t aml_frame_ref_set(uint64_t f, uint64_t k, uint64_t sl,
                                  uint64_t o);
extern uint64_t aml_frame_arg_is_obj(uint64_t i);
extern uint64_t aml_frame_local_is_obj(uint64_t i);
extern uint64_t aml_frame_set_arg_obj(uint64_t i, uint64_t o);
extern uint64_t aml_frame_set_local_obj(uint64_t i, uint64_t o);
extern uint64_t aml_eval_mk_string(uint64_t st, uint64_t en);
extern uint64_t aml_eval_mk_buffer(uint64_t n);
extern uint64_t aml_eval_mk_package(uint64_t n);
extern uint64_t aml_eval_decl_obj(uint64_t n);
extern uint64_t aml_eval_obj(uint64_t n);
extern uint64_t aml_eval_store_named(uint64_t d, uint64_t o);
extern uint64_t aml_eval_store_obj(uint64_t t, uint64_t o);
extern uint64_t aml_eval_copy_obj(uint64_t t, uint64_t o);
extern uint64_t aml_eval_int_shaped(uint64_t n);
extern uint64_t aml_eval_dest_is_int(uint64_t n);
extern uint64_t aml_eval_expr_int_ok(uint64_t n);

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
    E_BAD_TERMARG = 30,
    /* #1054 / #1055 — evaluator. Latched in aml_eval_state, not in the
     * lexer: parsing is per-table and evaluation is per-invocation, so
     * one shared first-writer-wins slot would let the first failed
     * evaluation block every later one. The CODE space is shared, so a
     * code still identifies its origin unambiguously. */
    E_FUEL_EXHAUSTED = 31, E_EVAL_DEPTH = 32, E_FRAME_OVERFLOW = 33,
    E_DIVIDE_BY_ZERO = 34, E_NOT_EVALUABLE = 35, E_NAME_NOT_FOUND = 36,
    E_BAD_SLOT = 37, E_NAME_TOO_DEEP = 38, E_BAD_PARENT_PREFIX = 39,
    E_NO_FRAME = 40, E_BAD_TARGET = 41,
    /* #1056 / #1057 — the object model. Same shared code space, so a code
     * still identifies its origin unambiguously. */
    E_OBJ_ARENA_FULL = 42, E_OBJ_HEAP_FULL = 43, E_OBJ_ELEM_FULL = 44,
    E_BAD_REF = 45, E_OBJ_RANGE = 46, E_NO_CONVERSION = 47,
    E_BAD_OBJTYPE = 48, E_STALE_REF = 49, E_UNINIT_ELEMENT = 50,
    /* #1058 / #1059 / #1060 — invocation, Notify, serialized methods. */
    E_ARG_COUNT = 51, E_BAD_NOTIFY_TARGET = 52, E_SYNC_LEVEL = 53,
    E_MUTEX_CONTENTION = 54, E_MUTEX_POOL_FULL = 55,
    /* #1062 — the address-space handler. These are the codes that mean
     * "a firmware table asked to touch something", and each names a
     * different reason it was refused. */
    E_REGION_NO_CAP = 56, E_REGION_NOT_COVERED = 57, E_REGION_UNBOUND = 58,
    E_REGION_OOB = 59, E_REGION_ACCESS_WIDTH = 60, E_REGION_FIELD_WIDTH = 61,
    E_REGION_SPACE = 62, E_REGION_TABLE_FULL = 63,
    E_REGION_INDIRECT_FIELD = 64,
    /* #1063 / #1064 / #1065 */
    E_REGION_PORT_RANGE = 65, E_REGION_PCI_CONTEXT = 66,
    E_REGION_EC_GATED = 67,
    /* R30.M7 — the EC driver's own refusals. */
    E_EC_UNBOUND      = 68,
    E_EC_TIMEOUT_IBF  = 69,
    E_EC_TIMEOUT_OBF  = 70,
    E_EC_STATUS       = 71,
    E_EC_RANGE        = 72,
    E_EC_REENTRANT    = 73,
    E_EC_QUERY_DEPTH  = 74,
    E_EC_BAD_OP       = 75
};

/* Address spaces, and the sentinel that selects real port transactions. */
enum {
    SP_MEM = 0, SP_IO = 1, SP_PCI = 2, SP_EC = 3,
    IO_REAL = 1,
    PCI_CTX_VALID_HI = 0x100  /* bit 40, as the top byte of a >>32 shift */
};

/* ACPI ObjectType codes — §19.6.101, and the object model's internal tag. */
enum {
    T_UNINIT = 0, T_INT = 1, T_STR = 2, T_BUF = 3, T_PKG = 4,
    T_FIELDUNIT = 5, T_DEVICE = 6, T_EVENT = 7, T_METHOD = 8, T_MUTEX = 9,
    T_REGION = 10, T_POWER = 11, T_PROC = 12, T_THERMAL = 13,
    T_BUFFIELD = 14, T_REF = 20,
    /* want-codes that are not types */
    T_ANY = 0, T_STRDEC = 12, T_SAME0 = 100, T_TARGET = 101
};

/* reference sub-kinds */
enum {
    R_NAME = 1, R_LOCAL = 2, R_ARG = 3, R_PKG_ELEM = 4,
    R_BUF_FIELD = 5, R_STR_FIELD = 6
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
    /* Outside a GUARDED region there is nothing to long-jump to, so the
     * only useful thing left is to say so on the way out — a bare exit
     * code 97 from a pre-push hook is a mystery, and this path is reached
     * by exactly the class of bug (an index escaping a fixed-size pool)
     * that is worth naming. write() rather than fprintf: async-signal
     * safety. */
    static const char msg[] =
        "[aml-corpus] FATAL — SIGSEGV outside a guarded region; a bounds "
        "check on a fixed-size array is missing or wrong\n";
    ssize_t w = write(2, msg, sizeof msg - 1);
    (void)w;
    _exit(97);
}

/* WHY A WATCHDOG.
 *
 * The evaluator's headline guarantee is that a `While(One)` over
 * firmware-supplied bytes TERMINATES. The failure mode of losing that
 * guarantee is not an assertion that reports false — it is a corpus that
 * never returns, which in the pre-push matrix is a wedged hook and no
 * diagnosis at all. Mutation testing confirmed it: neutralising
 * aml_eval_spend produces a hang, and a hang is the one outcome this
 * harness could not previously report.
 *
 * So the whole corpus runs under an alarm. Sixty seconds is roughly two
 * orders of magnitude more than it needs (the full run, including the
 * million-step default-budget fixture, is well under a second), so this
 * can only fire on a real non-termination. */
static void on_alarm(int sig)
{
    (void)sig;
    static const char msg[] =
        "[aml-corpus] FATAL — the corpus did not finish within 60s. An "
        "evaluation guard (fuel, depth or frames) is not terminating.\n";
    ssize_t w = write(2, msg, sizeof msg - 1);
    (void)w;
    _exit(96);
}

/* Variadic since #1056: an object-model test body contains array
 * initialisers, whose commas a single-parameter macro would split on. */
#define GUARDED(...)                                                         \
    do {                                                                     \
        g_armed = 1;                                                         \
        if (sigsetjmp(g_jb, 1) == 0) { __VA_ARGS__; }                        \
        else { fail("SIGSEGV — read past the end of the AML buffer"); }      \
        g_armed = 0;                                                         \
    } while (0)

/* Bind the lexer to a guarded copy of `data` and run `body`. */
#define WITH_FIXTURE(name, data, n, ...)                                     \
    do {                                                                     \
        g_case = (name);                                                     \
        const uint8_t *_b = guard_load((data), (n));                         \
        aml_arena_reset();                                                   \
        aml_lex_init((uint64_t)(uintptr_t)_b, (uint64_t)(n));                \
        GUARDED(__VA_ARGS__);                                                \
        guard_free();                                                        \
    } while (0)

/* Parse a guarded copy of `data` and run `body` with `root` in scope. */
#define WITH_PARSE(name, data, n, ...)                                       \
    do {                                                                     \
        g_case = (name);                                                     \
        const uint8_t *_b = guard_load((data), (n));                         \
        volatile uint64_t root = 0;                                          \
        GUARDED(root = aml_parse((uint64_t)(uintptr_t)_b, (uint64_t)(n)));    \
        { __VA_ARGS__; }                                                     \
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

/* ==================================================================== */
/* R30.M2-001 (#1054) / R30.M2-002 (#1055) — the evaluator.             */
/*                                                                      */
/* Parsing untrusted input can over-read, and the corpus above answers   */
/* that with a guard page. EVALUATING untrusted input can additionally   */
/* loop forever, recurse without bound and exhaust memory, so the first  */
/* thing asserted here is that each of those three terminates with its   */
/* own distinct code rather than hanging the harness. See                */
/* design/acpi/aml-evaluator.md.                                         */
/* ==================================================================== */

/* Build `Method(TEST, 0) { Return(<expr>) }` around a hand-written
 * expression, evaluate it at the given table revision, and assert the
 * value or the error code. Wrapping in a method rather than evaluating a
 * bare node is deliberate: it means every one of these cases also
 * exercises the frame push/pop and the scope switch, so a regression
 * there cannot hide behind a corpus that only ever evaluates expressions. */
static void eval_expr_case(const char *name, const uint8_t *expr, size_t en,
                           uint64_t revision, uint64_t expect, uint64_t experr)
{
    uint8_t b[160];
    uint8_t lenb[4];
    size_t ln = emit_pkglen(lenb, 4 + 1 + 1 + en);
    size_t n = 0;
    b[n++] = 0x14;                       /* MethodOp */
    memcpy(b + n, lenb, ln); n += ln;
    memcpy(b + n, "TEST", 4); n += 4;
    b[n++] = 0x00;                       /* MethodFlags: 0 args */
    b[n++] = 0xA4;                       /* ReturnOp */
    memcpy(b + n, expr, en); n += en;

    WITH_PARSE(name, b, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        eq("method kind", aml_node_kind(m), N_METHOD);
        aml_eval_reset(revision);
        eq("session starts clean", aml_eval_err(), AML_OK);
        uint64_t v = aml_eval_method(m);
        eq("eval err", aml_eval_err(), experr);
        if (experr == AML_OK)
            eq("value", v, expect);
        eq("eval depth unwound", aml_eval_depth(), 0);
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

#define EXPR_CASE(nm, rev, want, err, ...)                                   \
    do {                                                                     \
        static const uint8_t _e[] = { __VA_ARGS__ };                         \
        eval_expr_case((nm), _e, sizeof _e, (rev), (want), (err));           \
    } while (0)

/* ---------------------------------------------------------------------
 * THE HEADLINE TEST. `While(One)` with a firmware-controlled predicate
 * that is never false. Real ACPICA learned this the hard way. If the fuel
 * budget is not threaded through every evaluated node, this fixture does
 * not fail — it HANGS, and a hang in acpi_supervisor is a machine that
 * does not boot.
 * --------------------------------------------------------------------- */
static void test_eval_fuel_terminates_while_one(void)
{
    uint8_t b[] = {
        0x14, 0x09, 'W','H','I','L', 0x00,   /* Method(WHIL, 0) */
            0xA2, 0x02, 0x01                  /*   While(One) { } */
    };
    WITH_PARSE("eval: While(One) terminates on fuel", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        eq("method kind", aml_node_kind(m), N_METHOD);
        eq("while kind", aml_node_kind(aml_node_first_child(m)), N_WHILE);

        /* A small budget first, so the mechanism is asserted cheaply. */
        aml_eval_reset(2);
        eq("narrowed budget", aml_eval_set_fuel(1000), 1000);
        eq("returns nothing", aml_eval_method(m), 0);
        eq("fuel exhausted", aml_eval_err(), E_FUEL_EXHAUSTED);
        eq("budget fully spent", aml_eval_fuel(), 0);
        eq("depth unwound", aml_eval_depth(), 0);
        eq("frames unwound", aml_eval_frames(), 0);

        /* And now at the REAL default budget — this is the assertion that
         * the shipping configuration terminates, not just a test-sized one. */
        aml_eval_reset(2);
        eq("default budget", aml_eval_budget(), 1000000);
        eq("returns nothing", aml_eval_method(m), 0);
        eq("fuel exhausted at the default budget",
           aml_eval_err(), E_FUEL_EXHAUSTED);
        eq("budget fully spent", aml_eval_fuel(), 0);
        eq("depth unwound", aml_eval_depth(), 0);
        eq("frames unwound", aml_eval_frames(), 0);

        /* The setter narrows and CLAMPS; it cannot raise the ceiling, so
         * the termination guarantee does not depend on any caller. */
        aml_eval_reset(2);
        eq("clamped up from zero", aml_eval_set_fuel(0), 1);
        eq("clamped down from above the max",
           aml_eval_set_fuel(5000000), 1000000);
    });
}

/* A fuel-exhausted evaluation must not poison the NEXT one. With a single
 * shared first-writer-wins error slot it would: acpi_supervisor could
 * evaluate exactly one method per boot. */
static void test_eval_session_isolation(void)
{
    uint8_t b[] = {
        0x14, 0x09, 'F','A','I','L', 0x00,
            0xA2, 0x02, 0x01,                 /* While(One) { } */
        0x14, 0x09, 'G','O','O','D', 0x00,
            0xA4, 0x0A, 0x2A                  /* Return(42) */
    };
    WITH_PARSE("eval: a spent session does not poison the next", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t bad  = nth_child(root, 0);
        uint64_t good = nth_child(root, 1);

        aml_eval_reset(2);
        aml_eval_set_fuel(500);
        aml_eval_method(bad);
        eq("first session failed", aml_eval_err(), E_FUEL_EXHAUSTED);

        aml_eval_reset(2);
        eq("second session starts clean", aml_eval_err(), AML_OK);
        eq("second session evaluates", aml_eval_method(good), 42);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* A table that failed to PARSE must not be evaluable at all — the session
 * is seeded from the parse latch, so a caller who forgets to check cannot
 * walk an arena that was never finished. */
static void test_eval_refuses_a_failed_parse(void)
{
    uint8_t b[] = { 0x14, 0x40, 'B','A','D','_', 0x00 };  /* pkglen past end */
    WITH_PARSE("eval: a failed parse blocks evaluation", b, sizeof b, {
        (void)root;
        g_checks++;
        if (aml_lex_err() == AML_OK)
            fail("fixture should not have parsed");
        uint64_t latched = aml_lex_err();
        aml_eval_reset(2);
        eq("session seeded from the parse latch", aml_eval_err(), latched);
        eq("no fuel is spent", aml_eval_fuel(), 1000000);
    });
}

/* Depth, reached WITHOUT touching the frame pool: 52 nested Adds. This is
 * the fixture that keeps the two budgets genuinely distinct — a
 * self-recursive method exhausts frames long before depth, so if depth
 * were only ever reachable through recursion the cap would be untested. */
static void test_eval_depth_cap(void)
{
    enum { N = 52 };
    uint8_t body[1 + 3 * N];
    size_t bn = 0;
    for (int i = 0; i < N; i++) body[bn++] = 0x72;      /* AddOp x N */
    body[bn++] = 0x01;                                  /* innermost One */
    for (int i = 0; i < N; i++) { body[bn++] = 0x01; body[bn++] = 0x00; }

    uint8_t b[16 + sizeof body];
    uint8_t lenb[4];
    size_t ln = emit_pkglen(lenb, 4 + 1 + bn);
    size_t n = 0;
    b[n++] = 0x14;
    memcpy(b + n, lenb, ln); n += ln;
    memcpy(b + n, "DEEP", 4); n += 4;
    b[n++] = 0x00;
    memcpy(b + n, body, bn); n += bn;

    WITH_PARSE("eval: nested expressions hit the depth cap", b, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        aml_eval_reset(2);
        eq("returns nothing", aml_eval_method(m), 0);
        eq("depth, not fuel", aml_eval_err(), E_EVAL_DEPTH);
        g_checks++;
        if (aml_eval_fuel() == 0)
            fail("fuel was exhausted too — the depth cap is not what fired");
        eq("depth unwound", aml_eval_depth(), 0);
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

/* Unbounded recursion. A method that calls itself takes one frame and
 * about two depth levels per level, so the FRAME pool is what stops it —
 * asserted by the code, so a change that made depth fire first would be
 * visible rather than silently equivalent. */
static void test_eval_frame_pool_exhaustion(void)
{
    uint8_t b[] = {
        0x14, 0x0A, 'R','E','C','U', 0x00,
            'R','E','C','U'                   /* RECU() — self-recursive */
    };
    WITH_PARSE("eval: unbounded recursion exhausts the frame pool", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        eq("call node", aml_node_kind(aml_node_first_child(m)), N_CALL);
        aml_eval_reset(2);
        eq("returns nothing", aml_eval_method(m), 0);
        eq("frames, not fuel or depth", aml_eval_err(), E_FRAME_OVERFLOW);
        g_checks++;
        if (aml_eval_fuel() == 0)
            fail("fuel was exhausted too — the frame cap is not what fired");
        eq("every frame was popped on the way out", aml_eval_frames(), 0);
        eq("depth unwound", aml_eval_depth(), 0);

        /* The CALL node inside RECU is name-transparent, so its absolute
         * path is its parent's — [RECU] — which is also the METHOD's.
         * Two nodes, one path. Resolution still lands on the declaration
         * because a parent is always allocated before its children and
         * aml_eval_find takes the FIRST match. Pinned here so the
         * coincidence is on the record rather than assumed by whoever
         * replaces the linear scan with a sorted name index. */
        uint64_t call = aml_node_first_child(m);
        eq("the call site is name-transparent",
           aml_eval_names(aml_node_kind(call)), 0);
        eq("path computed", aml_eval_abspath(call, 0), 1);
        eq("it inherits the method's path", aml_eval_path_len(0), 1);
        eq("and the declaration is what that path resolves to",
           aml_eval_find(1), m);
    });
}

/* The frame pool as a unit: eight frames, isolation between them, and a
 * ninth refused. Driven through the API rather than through AML because
 * the AML path cannot reach slot indices the opcode space does not
 * encode, and BAD_SLOT still has to be reachable and tested. */
static void test_eval_frame_pool_api(void)
{
    uint8_t b[] = { 0x10, 0x06, '\\', '_','S','B','_' };  /* Scope(\_SB_){} */
    WITH_PARSE("eval: frame pool isolation and bounds", b, sizeof b, {
        (void)root;
        eq("parse ok", aml_lex_err(), AML_OK);
        aml_eval_reset(2);

        /* No frame: ArgX and LocalX are refused, not silently zero. */
        eq("local with no frame", aml_frame_local(0), 0);
        eq("NO_FRAME latched", aml_eval_err(), E_NO_FRAME);

        aml_eval_reset(2);
        eq("arg with no frame", aml_frame_arg(0), 0);
        eq("NO_FRAME latched", aml_eval_err(), E_NO_FRAME);

        /* Seven args and EIGHT locals — ACPI 6.5 §20.2.6.2. The counts are
         * asymmetric in the spec and in the opcode space (0x68..0x6E vs
         * 0x60..0x67); evening them up would refuse Local7. */
        aml_eval_reset(2);
        eq("first frame", aml_frame_push(0), 1);
        eq("Arg6 is in range", aml_frame_set_arg(6, 1), 1);
        eq("no error", aml_eval_err(), AML_OK);
        eq("Arg7 does not exist", aml_frame_set_arg(7, 1), 0);
        eq("BAD_SLOT latched", aml_eval_err(), E_BAD_SLOT);

        aml_eval_reset(2);
        aml_frame_push(0);
        eq("Local7 is in range", aml_frame_set_local(7, 1), 1);
        eq("no error", aml_eval_err(), AML_OK);
        eq("Local8 does not exist", aml_frame_set_local(8, 1), 0);
        eq("BAD_SLOT latched", aml_eval_err(), E_BAD_SLOT);

        /* Isolation, part one: a REUSED frame comes back clean. This has
         * to be asserted against a DIRTY pool — the pool is .bss, so a
         * frame that has never been written is zero whether or not
         * aml_frame_push zeroes it, and an isolation test that only ever
         * touches virgin frames proves nothing. So dirty frame 2 first,
         * unwind, and then re-enter it. */
        aml_eval_reset(2);
        aml_frame_push(0);
        aml_frame_push(0);                        /* frame 2 */
        aml_frame_set_local(0, 0x9999);
        aml_frame_set_local(7, 0x8888);
        aml_frame_set_arg(3, 0x7777);
        aml_frame_pop();
        aml_frame_pop();
        eq("pool empty", aml_eval_frames(), 0);

        aml_eval_reset(2);
        aml_frame_push(0);
        aml_frame_push(0);                        /* frame 2, reused */
        eq("reused frame Local0 is zeroed", aml_frame_local(0), 0);
        eq("reused frame Local7 is zeroed", aml_frame_local(7), 0);
        eq("reused frame Arg3 is zeroed", aml_frame_arg(3), 0);
        eq("no error", aml_eval_err(), AML_OK);
        aml_frame_pop();
        aml_frame_pop();

        /* Isolation, part two: a write to a callee's slot leaves the
         * caller's untouched. */
        aml_eval_reset(2);
        eq("frame 1", aml_frame_push(0), 1);
        eq("fresh frame is zeroed", aml_frame_local(0), 0);
        aml_frame_set_local(0, 111);
        aml_frame_set_arg(0, 211);
        eq("caller local", aml_frame_local(0), 111);
        eq("frame 2", aml_frame_push(0), 2);
        eq("callee local starts at Zero", aml_frame_local(0), 0);
        eq("callee arg starts at Zero", aml_frame_arg(0), 0);
        aml_frame_set_local(0, 222);
        eq("callee local", aml_frame_local(0), 222);
        aml_frame_pop();
        eq("caller local is undisturbed", aml_frame_local(0), 111);
        eq("caller arg is undisturbed", aml_frame_arg(0), 211);
        eq("no error throughout", aml_eval_err(), AML_OK);
        aml_frame_pop();
        eq("pool empty", aml_eval_frames(), 0);

        /* Eight frames fit; the ninth is an error, never a grow. */
        aml_eval_reset(2);
        for (int i = 1; i <= 8; i++)
            eq("frame allocated", aml_frame_push(0), (uint64_t)i);
        eq("no error at eight", aml_eval_err(), AML_OK);
        eq("ninth refused", aml_frame_push(0), 0);
        eq("FRAME_OVERFLOW latched", aml_eval_err(), E_FRAME_OVERFLOW);
        eq("top unchanged by the refusal", aml_eval_frames(), 8);
    });
}

/* Frame isolation through real AML: the callee writes its own Local0 and
 * the caller's survives. */
static void test_eval_frame_isolation_in_aml(void)
{
    uint8_t b[] = {
        0x14, 0x11, 'O','U','T','R', 0x00,
            0x72, 0x0A, 0x0B, 0x00, 0x60,     /* Add(11, Zero, Local0) */
            'I','N','N','R',                   /* INNR() */
            0xA4, 0x60,                        /* Return(Local0) */
        0x14, 0x0D, 'I','N','N','R', 0x00,
            0x72, 0x0A, 0x16, 0x00, 0x60,     /* Add(22, Zero, Local0) */
            0xA4, 0x60                         /* Return(Local0) */
    };
    WITH_PARSE("eval: callee Local0 does not disturb the caller's", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t outr = nth_child(root, 0);
        uint64_t innr = nth_child(root, 1);

        aml_eval_reset(2);
        eq("callee sets its own Local0", aml_eval_method(innr), 22);
        eq("no error", aml_eval_err(), AML_OK);

        aml_eval_reset(2);
        eq("caller's Local0 survives the call", aml_eval_method(outr), 11);
        eq("no error", aml_eval_err(), AML_OK);
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

/* Arguments are evaluated in the CALLER's frame. Push-then-evaluate would
 * read the callee's freshly-zeroed Local0 and pass Zero — a wrong value,
 * silently. */
static void test_eval_args_evaluated_in_caller_frame(void)
{
    uint8_t b[] = {
        0x14, 0x08, 'I','D','N','T', 0x01,
            0xA4, 0x68,                        /* Return(Arg0) */
        0x14, 0x11, 'C','A','L','R', 0x00,
            0x72, 0x0A, 0x09, 0x00, 0x60,     /* Add(9, Zero, Local0) */
            0xA4, 'I','D','N','T', 0x60        /* Return(IDNT(Local0)) */
    };
    WITH_PARSE("eval: arguments evaluate in the caller's frame", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t calr = nth_child(root, 1);
        aml_eval_reset(2);
        eq("argument carried the caller's Local0", aml_eval_method(calr), 9);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* Two arguments, bound in order, read back as Arg0 and Arg1. */
static void test_eval_method_arguments(void)
{
    uint8_t b[] = {
        0x14, 0x0B, 'A','D','D','R', 0x02,
            0xA4, 0x72, 0x68, 0x69, 0x00,     /* Return(Add(Arg0, Arg1, Zero)) */
        0x14, 0x0F, 'M','A','I','N', 0x00,
            0xA4, 'A','D','D','R', 0x0A, 0x07, 0x0A, 0x0B
    };
    WITH_PARSE("eval: two arguments bind in order", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t main_m = nth_child(root, 1);
        aml_eval_reset(2);
        eq("7 + 11", aml_eval_method(main_m), 18);
        eq("no error", aml_eval_err(), AML_OK);
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

/* ---------------------------------------------------------------------
 * ACPI 6.5 §5.3 name resolution. The same NameSeg, written four ways,
 * must resolve to two DIFFERENT objects. That is the property that makes
 * this fixture able to fail: an implementation that ignores the root
 * anchor, or that searches upward when it must not, still finds A
 * declaration — just the wrong one.
 * --------------------------------------------------------------------- */
static void test_eval_name_resolution(void)
{
    /*  Name(VALU, 1)                     -> \VALU      = 1
     *  Scope(SCPA) {
     *      Name(VALU, 2)                 -> \SCPA.VALU = 2
     *      Method(INNR) { Return(VALU)   }   search rule: inner wins  -> 2
     *      Method(RTMD) { Return(\VALU)  }   root anchor              -> 1
     *      Method(PPMD) { Return(^VALU)  }   parent of the method     -> 2
     *      Method(PP2M) { Return(^^VALU) }   grandparent = root       -> 1
     *  }
     */
    uint8_t inner[128];
    size_t in = 0;
    const uint8_t nm[] = { 0x08, 'V','A','L','U', 0x0A, 0x02 };
    memcpy(inner + in, nm, sizeof nm); in += sizeof nm;

    struct { const char *seg; uint8_t body[8]; size_t bn; } ms[] = {
        { "INNR", { 0xA4, 'V','A','L','U' }, 5 },
        { "RTMD", { 0xA4, 0x5C, 'V','A','L','U' }, 6 },
        { "PPMD", { 0xA4, 0x5E, 'V','A','L','U' }, 6 },
        { "PP2M", { 0xA4, 0x5E, 0x5E, 'V','A','L','U' }, 7 },
    };
    for (size_t i = 0; i < 4; i++) {
        uint8_t lenb[4];
        size_t ln = emit_pkglen(lenb, 4 + 1 + ms[i].bn);
        inner[in++] = 0x14;
        memcpy(inner + in, lenb, ln); in += ln;
        memcpy(inner + in, ms[i].seg, 4); in += 4;
        inner[in++] = 0x00;
        memcpy(inner + in, ms[i].body, ms[i].bn); in += ms[i].bn;
    }

    uint8_t b[192];
    size_t n = 0;
    const uint8_t root_name[] = { 0x08, 'V','A','L','U', 0x0A, 0x01 };
    memcpy(b + n, root_name, sizeof root_name); n += sizeof root_name;
    uint8_t lenb[4];
    size_t ln = emit_pkglen(lenb, 4 + in);
    b[n++] = 0x10;                                    /* ScopeOp */
    memcpy(b + n, lenb, ln); n += ln;
    memcpy(b + n, "SCPA", 4); n += 4;
    memcpy(b + n, inner, in); n += in;

    WITH_PARSE("eval: §5.3 scoping — inner, root anchor, ^ and ^^", b, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        eq("consumed all", aml_lex_pos(), n);
        uint64_t scope = nth_child(root, 1);
        eq("scope kind", aml_node_kind(scope), N_SCOPE);

        uint64_t innr = nth_child(scope, 1);
        uint64_t rtmd = nth_child(scope, 2);
        uint64_t ppmd = nth_child(scope, 3);
        uint64_t pp2m = nth_child(scope, 4);

        aml_eval_reset(2);
        eq("bare NameSeg finds the INNER declaration",
           aml_eval_method(innr), 2);
        eq("no error", aml_eval_err(), AML_OK);

        aml_eval_reset(2);
        eq("\\-anchored name reaches the root past an inner match",
           aml_eval_method(rtmd), 1);
        eq("no error", aml_eval_err(), AML_OK);

        aml_eval_reset(2);
        eq("^ resolves to the method's parent scope",
           aml_eval_method(ppmd), 2);
        eq("no error", aml_eval_err(), AML_OK);

        aml_eval_reset(2);
        eq("^^ resolves two levels up, to the root",
           aml_eval_method(pp2m), 1);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* The two ways §5.3 resolution is allowed to FAIL, and the rule that a
 * multi-segment relative path does NOT get the search. `SCPA.VALU`
 * written inside \SCPA.MSMD names \SCPA.MSMD.SCPA.VALU, which does not
 * exist; an implementation that searched upward anyway would find
 * \SCPA.VALU and return 2. */
static void test_eval_name_resolution_refusals(void)
{
    uint8_t inner[128];
    size_t in = 0;
    const uint8_t nm[] = { 0x08, 'V','A','L','U', 0x0A, 0x02 };
    memcpy(inner + in, nm, sizeof nm); in += sizeof nm;

    struct { const char *seg; uint8_t body[12]; size_t bn; } ms[] = {
        /* Return(SCPA.VALU) — DualNamePath, multi-segment relative */
        { "MSMD", { 0xA4, 0x2E, 'S','C','P','A', 'V','A','L','U' }, 10 },
        /* Return(^^^VALU) — one level more than the scope has */
        { "OVER", { 0xA4, 0x5E, 0x5E, 0x5E, 'V','A','L','U' }, 8 },
    };
    for (size_t i = 0; i < 2; i++) {
        uint8_t lenb[4];
        size_t ln = emit_pkglen(lenb, 4 + 1 + ms[i].bn);
        inner[in++] = 0x14;
        memcpy(inner + in, lenb, ln); in += ln;
        memcpy(inner + in, ms[i].seg, 4); in += 4;
        inner[in++] = 0x00;
        memcpy(inner + in, ms[i].body, ms[i].bn); in += ms[i].bn;
    }

    uint8_t b[192];
    size_t n = 0;
    uint8_t lenb[4];
    size_t ln = emit_pkglen(lenb, 4 + in);
    b[n++] = 0x10;
    memcpy(b + n, lenb, ln); n += ln;
    memcpy(b + n, "SCPA", 4); n += 4;
    memcpy(b + n, inner, in); n += in;

    WITH_PARSE("eval: §5.3 refusals", b, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t scope = nth_child(root, 0);
        uint64_t msmd = nth_child(scope, 1);
        uint64_t over = nth_child(scope, 2);

        aml_eval_reset(2);
        eq("multi-segment relative name is not searched upward",
           aml_eval_method(msmd), 0);
        eq("NAME_NOT_FOUND", aml_eval_err(), E_NAME_NOT_FOUND);

        aml_eval_reset(2);
        eq("too many ^ is refused", aml_eval_method(over), 0);
        eq("BAD_PARENT_PREFIX, not NOT_FOUND",
           aml_eval_err(), E_BAD_PARENT_PREFIX);
    });
}

/* A Field's NameString is the REGION's, not its own, so the three Field
 * kinds must be name-transparent: a field element lives in the scope that
 * contains the Field declaration. If they contributed a path component,
 * FLD0 would sit at \REGN.FLD0 and this resolution would MISS (36) rather
 * than resolve and then refuse to READ a field element (35). */
static void test_eval_field_element_is_not_under_the_region(void)
{
    uint8_t b[] = {
        0x5B, 0x80, 'R','E','G','N', 0x00, 0x0A, 0x10, 0x0A, 0x04,
        0x5B, 0x81, 0x0B, 'R','E','G','N', 0x01, 'F','L','D','0', 0x08,
        0x14, 0x0B, 'F','L','D','M', 0x00, 0xA4, 'F','L','D','0'
    };
    WITH_PARSE("eval: a field element is not under its region", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = nth_child(root, 2);
        eq("method kind", aml_node_kind(m), N_METHOD);
        aml_eval_reset(2);
        aml_region_reset();
        eq("returns nothing", aml_eval_method(m), 0);
        /* Found — and then refused, which is what this fixture is about:
         * NAME_NOT_FOUND (36) here would mean the path was built wrong.
         *
         * The REFUSAL CODE MOVED at R30.M3-002 (#1062). #1057 refused a
         * field element as NOT_EVALUABLE because reading one was a bus
         * transaction nobody had implemented. It is implemented now, and
         * the reason this read fails is different and more specific: the
         * region was never bound to a capability window, so there is no
         * grant covering it. UNBOUND (58) says that; NOT_EVALUABLE said
         * only "I do not know how", which is no longer true and would
         * hide a missing grant behind an implementation gap. */
        eq("resolved, then refused for want of a capability",
           aml_eval_err(), E_REGION_UNBOUND);

        /* The Field node itself carries a name_ref — the REGION's — while
         * contributing nothing to the path, so at top level its absolute
         * path is EMPTY. The empty path names nothing, and the only thing
         * that keeps such a node from being handed back as the declaration
         * of the empty path is the declaration filter in aml_eval_find.
         * This is the one place that filter is observable: everywhere else
         * a transparent node shares its path with the naming ancestor it
         * inherited from, and that ancestor is always allocated first, so
         * first-match-wins already lands on the declaration. */
        uint64_t fld = nth_child(root, 1);
        eq("field node kind", aml_node_kind(fld), N_FIELD);
        g_checks++;
        if (aml_node_name(fld) == 0)
            fail("the Field should carry its region's name_ref");
        eq("path computed", aml_eval_abspath(fld, 0), 1);
        eq("a Field contributes no path component", aml_eval_path_len(0), 0);
        eq("the empty path is the declaration of nothing",
           aml_eval_find(0), 0);
    });
}

/* ---------------------------------------------------------------------
 * Statements: If/Else, While that terminates, Break, Continue, Return.
 * --------------------------------------------------------------------- */
static void test_eval_if_else(void)
{
    uint8_t f[] = {
        0x14, 0x11, 'I','F','E','L', 0x00,
            0xA0, 0x05, 0x00, 0xA4, 0x0A, 0x01,   /* If(Zero){Return(1)} */
            0xA1, 0x04, 0xA4, 0x0A, 0x02          /* Else  {Return(2)} */
    };
    WITH_PARSE("eval: If false takes the Else", f, sizeof f, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        aml_eval_reset(2);
        eq("Else arm ran", aml_eval_method(m), 2);
        eq("no error", aml_eval_err(), AML_OK);
    });

    uint8_t t[] = {
        0x14, 0x11, 'I','F','E','L', 0x00,
            0xA0, 0x05, 0x01, 0xA4, 0x0A, 0x01,   /* If(One){Return(1)} */
            0xA1, 0x04, 0xA4, 0x0A, 0x02          /* Else   {Return(2)} */
    };
    WITH_PARSE("eval: If true skips the Else", t, sizeof t, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        aml_eval_reset(2);
        eq("If arm ran", aml_eval_method(m), 1);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

static void test_eval_while_terminates_naturally(void)
{
    uint8_t b[] = {
        0x14, 0x1E, 'L','O','O','P', 0x00,
            0x72, 0x0A, 0x00, 0x00, 0x60,          /* Local0 = 0 */
            0x72, 0x0A, 0x00, 0x00, 0x61,          /* Local1 = 0 */
            0xA2, 0x0B, 0x95, 0x60, 0x0A, 0x05,    /* While(LLess(Local0,5)) */
                0x75, 0x60,                        /*   Increment(Local0) */
                0x72, 0x61, 0x60, 0x61,            /*   Local1 += Local0 */
            0xA4, 0x61                             /* Return(Local1) */
    };
    WITH_PARSE("eval: a While with a real predicate terminates", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        aml_eval_reset(2);
        eq("1+2+3+4+5", aml_eval_method(m), 15);
        eq("no error", aml_eval_err(), AML_OK);
        g_checks++;
        if (aml_eval_fuel() == 0)
            fail("a terminating loop should not have spent the whole budget");
    });
}

/* Break must leave the loop. Without it this fixture is `While(One)` and
 * would end in FUEL_EXHAUSTED — so the assertion is not merely that the
 * value is 3 but that no error was latched at all. */
static void test_eval_break_leaves_the_loop(void)
{
    uint8_t b[] = {
        0x14, 0x19, 'B','R','K','L', 0x00,
            0x72, 0x0A, 0x00, 0x00, 0x60,          /* Local0 = 0 */
            0xA2, 0x0B, 0x01,                      /* While(One) */
                0x75, 0x60,                        /*   Increment(Local0) */
                0xA0, 0x06, 0x93, 0x60, 0x0A, 0x03,/*   If(LEqual(Local0,3)) */
                    0xA5,                          /*     Break */
            0xA4, 0x60                             /* Return(Local0) */
    };
    WITH_PARSE("eval: Break leaves an otherwise infinite While", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        aml_eval_reset(2);
        eq("loop left after three iterations", aml_eval_method(m), 3);
        eq("no fuel exhaustion", aml_eval_err(), AML_OK);
    });
}

/* ---------------------------------------------------------------------
 * Stores. LocalX, ArgX and a named integer object; Zero as the null
 * target; anything else refused.
 * --------------------------------------------------------------------- */
static void test_eval_named_store(void)
{
    uint8_t b[] = {
        0x08, 'A','C','C','U', 0x0A, 0x00,         /* Name(ACCU, 0) */
        0x14, 0x14, 'S','T','O','R', 0x00,
            0x72, 0x0A, 0x07, 0x0A, 0x05, 'A','C','C','U',  /* ACCU = 7+5 */
            0xA4, 'A','C','C','U'                  /* Return(ACCU) */
    };
    WITH_PARSE("eval: store into a named integer object", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t nm = nth_child(root, 0);
        uint64_t m  = nth_child(root, 1);
        eq("name kind", aml_node_kind(nm), N_NAME);
        eq("initial value", aml_u64_get(aml_node_arg0(nm)), 0);
        aml_eval_reset(2);
        eq("reads back what was stored", aml_eval_method(m), 12);
        eq("the object itself was updated",
           aml_u64_get(aml_node_arg0(nm)), 12);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

static void test_eval_increment_decrement(void)
{
    uint8_t b[] = {
        0x14, 0x13, 'I','N','C','D', 0x00,
            0x72, 0x0A, 0x05, 0x00, 0x60,          /* Local0 = 5 */
            0x75, 0x60,                            /* Increment -> 6 */
            0x75, 0x60,                            /* Increment -> 7 */
            0x76, 0x60,                            /* Decrement -> 6 */
            0xA4, 0x60
    };
    WITH_PARSE("eval: Increment and Decrement read-modify-write", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        aml_eval_reset(2);
        eq("5 +1 +1 -1", aml_eval_method(m), 6);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* Divide has TWO destinations and they are Remainder THEN Quotient
 * (§19.6.34). Swapping them yields 23 instead of 32, so the arithmetic
 * that reads them back is what pins the order. */
static void test_eval_divide_two_destinations(void)
{
    uint8_t b[] = {
        0x14, 0x16, 'D','I','V','T', 0x00,
            0x78, 0x0A, 0x11, 0x0A, 0x05, 0x60, 0x61,  /* 17/5 -> r=2,q=3 */
            0xA4, 0x72, 0x77, 0x61, 0x0A, 0x0A, 0x00, 0x60, 0x00
    };
    WITH_PARSE("eval: Divide fills Remainder then Quotient", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        aml_eval_reset(2);
        eq("quotient*10 + remainder", aml_eval_method(m), 32);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* ---------------------------------------------------------------------
 * The operator table (#1055). One method per expression, so each case
 * also exercises a frame push, a scope switch and a Return.
 * --------------------------------------------------------------------- */
static void test_eval_arithmetic(void)
{
    const uint64_t ONES64 = 0xFFFFFFFFFFFFFFFFull;

    EXPR_CASE("eval: Add",        2, 8,  AML_OK, 0x72,0x0A,0x05,0x0A,0x03,0x00);
    EXPR_CASE("eval: Subtract",   2, 2,  AML_OK, 0x74,0x0A,0x05,0x0A,0x03,0x00);
    EXPR_CASE("eval: Multiply",   2, 15, AML_OK, 0x77,0x0A,0x05,0x0A,0x03,0x00);
    EXPR_CASE("eval: Divide",     2, 3,  AML_OK, 0x78,0x0A,0x11,0x0A,0x05,0x00,0x00);
    EXPR_CASE("eval: Mod",        2, 2,  AML_OK, 0x85,0x0A,0x11,0x0A,0x05,0x00);
    EXPR_CASE("eval: ShiftLeft",  2, 16, AML_OK, 0x79,0x0A,0x01,0x0A,0x04,0x00);
    EXPR_CASE("eval: ShiftRight", 2, 4,  AML_OK, 0x7A,0x0A,0x10,0x0A,0x02,0x00);

    /* x86 masks a shift count to 6 bits, so a bare `shl` would compute
     * these as the operand unchanged. ACPI says every bit is shifted out. */
    EXPR_CASE("eval: ShiftLeft by the full width is Zero",
              2, 0, AML_OK, 0x79,0x0A,0x01,0x0A,0x40,0x00);
    EXPR_CASE("eval: ShiftRight by the full width is Zero",
              2, 0, AML_OK, 0x7A,0xFF,0x0A,0x40,0x00);
    EXPR_CASE("eval: ShiftLeft beyond the width is Zero",
              2, 0, AML_OK, 0x79,0x0A,0x01,0x0A,0x7F,0x00);

    EXPR_CASE("eval: And",  2, 0x30, AML_OK, 0x7B,0x0A,0xF0,0x0A,0x3C,0x00);
    EXPR_CASE("eval: Or",   2, 0xFC, AML_OK, 0x7D,0x0A,0xF0,0x0A,0x0C,0x00);
    EXPR_CASE("eval: Xor",  2, 0xF0, AML_OK, 0x7F,0x0A,0xFF,0x0A,0x0F,0x00);
    EXPR_CASE("eval: Nand", 2, ~(uint64_t)0x30, AML_OK,
              0x7C,0x0A,0xF0,0x0A,0x3C,0x00);
    EXPR_CASE("eval: Nor",  2, ~(uint64_t)0xFC, AML_OK,
              0x7E,0x0A,0xF0,0x0A,0x0C,0x00);
    EXPR_CASE("eval: Not",  2, ~(uint64_t)0x0F, AML_OK, 0x80,0x0A,0x0F,0x00);

    EXPR_CASE("eval: FindSetLeftBit",       2, 8, AML_OK, 0x81,0x0A,0x80,0x00);
    EXPR_CASE("eval: FindSetLeftBit(Zero)", 2, 0, AML_OK, 0x81,0x00,0x00);
    EXPR_CASE("eval: FindSetRightBit",      2, 3, AML_OK, 0x82,0x0A,0x0C,0x00);
    EXPR_CASE("eval: FindSetRightBit(Zero)",2, 0, AML_OK, 0x82,0x00,0x00);
    EXPR_CASE("eval: FindSetLeftBit(One)",  2, 1, AML_OK, 0x81,0x01,0x00);

    EXPR_CASE("eval: LAnd true",  2, ONES64, AML_OK, 0x90,0x01,0x01);
    EXPR_CASE("eval: LAnd false", 2, 0,      AML_OK, 0x90,0x01,0x00);
    EXPR_CASE("eval: LOr true",   2, ONES64, AML_OK, 0x91,0x00,0x01);
    EXPR_CASE("eval: LOr false",  2, 0,      AML_OK, 0x91,0x00,0x00);
    EXPR_CASE("eval: LNot(Zero)", 2, ONES64, AML_OK, 0x92,0x00);
    EXPR_CASE("eval: LNot(One)",  2, 0,      AML_OK, 0x92,0x01);
    EXPR_CASE("eval: LEqual",     2, ONES64, AML_OK, 0x93,0x0A,0x05,0x0A,0x05);
    EXPR_CASE("eval: LGreater",   2, ONES64, AML_OK, 0x94,0x0A,0x05,0x0A,0x03);
    EXPR_CASE("eval: LLess",      2, ONES64, AML_OK, 0x95,0x0A,0x03,0x0A,0x05);

    /* AML integers are UNSIGNED. With jg/jl instead of ja/jb, Ones is -1
     * and both of these invert. */
    EXPR_CASE("eval: LGreater is unsigned", 2, ONES64, AML_OK, 0x94,0xFF,0x01);
    EXPR_CASE("eval: LLess is unsigned",    2, 0,      AML_OK, 0x95,0xFF,0x01);

    /* LGreaterEqual / LLessEqual / LNotEqual have no opcodes: iasl emits
     * LNot of the dual, and that is what is asserted. */
    EXPR_CASE("eval: LGreaterEqual is LNot(LLess)", 2, ONES64, AML_OK,
              0x92,0x95,0x0A,0x05,0x0A,0x05);
    EXPR_CASE("eval: LLessEqual is LNot(LGreater)", 2, ONES64, AML_OK,
              0x92,0x94,0x0A,0x05,0x0A,0x05);
    EXPR_CASE("eval: LNotEqual is LNot(LEqual)", 2, ONES64, AML_OK,
              0x92,0x93,0x0A,0x05,0x0A,0x03);

    EXPR_CASE("eval: RevisionOp", 2, 2, AML_OK, 0x5B,0x30);

    /* Divide by zero is an error, not a #DE — which in a userspace process
     * would be SIGFPE and would let firmware bytecode kill the supervisor. */
    EXPR_CASE("eval: Divide by zero", 2, 0, E_DIVIDE_BY_ZERO,
              0x78,0x0A,0x05,0x00,0x00,0x00);
    EXPR_CASE("eval: Mod by zero", 2, 0, E_DIVIDE_BY_ZERO,
              0x85,0x0A,0x05,0x00,0x00);

    EXPR_CASE("eval: Increment of a literal is not a target",
              2, 0, E_BAD_TARGET, 0x75,0x0A,0x05);

    /* #1056 / #1057 moved these from refusals to implementations. They stay
     * here, next to the twenty-four operators they used to bound, so the
     * boundary is visible as a boundary that MOVED rather than as a comment
     * claiming it once existed.
     *
     * Store returns the value it stored (§19.6.126), which is what makes
     * Store(Store(x,A),B) assign to both -- and it takes the integer fast
     * path here, so it allocates nothing. */
    EXPR_CASE("eval: Store returns the stored value", 2, 1, AML_OK,
              0x70,0x01,0x60);
    /* Concatenate of two Integers is a BUFFER of two width-sized integers
     * (§19.6.13) -- not an Integer, which is the case an implementation that
     * keys conversion off the OPERAND rather than the OPERATOR gets wrong. */
    EXPR_CASE("eval: Concatenate(Int,Int) is a 2*width Buffer", 2, 16, AML_OK,
              0x87,0x73,0x01,0x01,0x00);
    EXPR_CASE("eval: SizeOf a String excludes its NUL", 2, 2, AML_OK,
              0x87,0x0D,'h','i',0x00);
    EXPR_CASE("eval: SizeOf a Buffer is its byte count", 2, 1, AML_OK,
              0x87,0x11,0x03,0x01,0x00);
    /* SizeOf of an INTEGER is an error, not the integer width (§19.6.125). */
    EXPR_CASE("eval: SizeOf of an Integer is refused", 2, 0, E_BAD_OBJTYPE,
              0x87,0x0A,0x05);
    /* The new boundary: a FieldUnit read is a bus transaction, R30.M3's. */
    EXPR_CASE("eval: DerefOf of a non-reference is refused", 2, 0, E_BAD_REF,
              0x83,0x0A,0x05);

    /* ---------------------------------------------------------------
     * §19.3.5.5 — OPERAND CONVERSION IS KEYED BY THE OPERATOR. These two
     * are the pair: the SAME operand type, converted in OPPOSITE
     * directions, chosen by the operator and not by the operand.
     * --------------------------------------------------------------- */
    EXPR_CASE("eval: Add converts a STRING operand to Integer", 2, 8, AML_OK,
              0x72,0x0D,'5',0x00,0x0A,0x03,0x00);
    EXPR_CASE("eval: Add takes a hex string too", 2, 0x13, AML_OK,
              0x72,0x0D,'0','x','1','0',0x00,0x0A,0x03,0x00);
    EXPR_CASE("eval: Concatenate converts an INTEGER operand to Buffer",
              2, T_BUF, AML_OK, 0x8E,0x73,0x0A,0x05,0x0A,0x03,0x00);
    /* and the two integers really are laid end to end at the table width:
     * byte 8 is the low byte of the SECOND operand */
    EXPR_CASE("eval: Concatenate lays two integers end to end", 2, 3, AML_OK,
              0x83,0x88,0x73,0x0A,0x05,0x0A,0x03,0x00,0x0A,0x08,0x00);
    EXPR_CASE("eval: Concatenate of two Strings is a String", 2, 4, AML_OK,
              0x87,0x73,0x0D,'a','b',0x00,0x0D,'c','d',0x00,0x00);
    /* a String first operand converts the Integer to a String -- and the
     * implicit Integer->String rule is FIXED-WIDTH HEX, so 2 + 16 */
    EXPR_CASE("eval: Concatenate String+Integer converts to hex String",
              2, 18, AML_OK, 0x87,0x73,0x0D,'a','b',0x00,0x0A,0x05,0x00);

    /* ---------------------------------------------------------------
     * The four operators that ARE a conversion-table row plus a store.
     * --------------------------------------------------------------- */
    EXPR_CASE("eval: ToInteger of a decimal String", 2, 42, AML_OK,
              0x99,0x0D,'4','2',0x00,0x00);
    EXPR_CASE("eval: ToInteger of a 0x-prefixed hex String", 2, 42, AML_OK,
              0x99,0x0D,'0','x','2','A',0x00,0x00);
    EXPR_CASE("eval: ToInteger of a Buffer is little-endian", 2, 0x1234, AML_OK,
              0x99,0x11,0x05,0x0A,0x02,0x34,0x12,0x00);
    EXPR_CASE("eval: ToHexString of an Integer is fixed width", 2, 16, AML_OK,
              0x87,0x98,0x0A,0x05,0x00);
    EXPR_CASE("eval: ToDecimalString of an Integer is not padded", 2, 2, AML_OK,
              0x87,0x97,0x0A,0x2A,0x00);
    EXPR_CASE("eval: ToBuffer of a String includes its NUL", 2, 3, AML_OK,
              0x87,0x96,0x0D,'A','B',0x00,0x00);
    EXPR_CASE("eval: ToBuffer of an Integer is width/8 bytes", 2, 8, AML_OK,
              0x87,0x96,0x0A,0x05,0x00);

    /* ---------------------------------------------------------------
     * ToString stops at the FIRST NUL **or** at the length, whichever
     * comes first. Both terminators, not one: a Buffer of a,b,NUL,c,d,NUL
     * gives 2 with no limit and 1 with a limit of One.
     * --------------------------------------------------------------- */
    EXPR_CASE("eval: ToString stops at the first NUL", 2, 2, AML_OK,
              0x87,0x9C,0x11,0x09,0x0A,0x06,'a','b',0x00,'c','d',0x00,
              0xFF,0x00);
    EXPR_CASE("eval: ToString stops at the LENGTH when that comes first",
              2, 1, AML_OK,
              0x87,0x9C,0x11,0x09,0x0A,0x06,'a','b',0x00,'c','d',0x00,
              0x01,0x00);
    EXPR_CASE("eval: ToString of a buffer with no NUL takes it all",
              2, 3, AML_OK,
              0x87,0x9C,0x11,0x06,0x0A,0x03,'x','y','z',0xFF,0x00);

    /* Mid keeps the source's TYPE and clamps rather than failing. */
    EXPR_CASE("eval: Mid of a String is a String", 2, 2, AML_OK,
              0x87,0x9E,0x0D,'a','b','c','d',0x00,0x01,0x0A,0x02,0x00);
    EXPR_CASE("eval: Mid past the end yields an empty result", 2, 0, AML_OK,
              0x87,0x9E,0x0D,'a','b',0x00,0x0A,0x09,0x0A,0x02,0x00);
    EXPR_CASE("eval: Mid clamps its length to what remains", 2, 1, AML_OK,
              0x87,0x9E,0x0D,'a','b',0x00,0x01,0x0A,0x09,0x00);
}


/* ---------------------------------------------------------------------
 * R30.M2-003 (#1056) / R30.M2-004 (#1057) — the object model.
 *
 * WHY SO MANY OF THESE TESTS ARE C-LEVEL RATHER THAN AML-LEVEL
 * ------------------------------------------------------------
 * Three properties this milestone has to prove are INVISIBLE from AML at
 * this milestone and would be untestable if the corpus only ever ran
 * methods:
 *
 *   * the three Index() forms produce three DISTINCT reference kinds.
 *     From AML, DerefOf of a buffer index and DerefOf of a package index
 *     of the same value are indistinguishable; the difference only shows
 *     up on a STORE, and only in what gets truncated.
 *   * a store to an ArgX holding a Reference goes THROUGH it while a
 *     store to a LocalX does not (§19.3.5.8). Getting a reference into an
 *     ArgX from AML needs argument promotion, which is #1058's.
 *   * a frame reference is invalidated by its frame being popped.
 *
 * So those are driven through the module API directly, against the same
 * machine code, and the AML-level fixtures cover everything that CAN be
 * reached from bytecode. Both halves run under the guard page.
 * --------------------------------------------------------------------- */

#define OBJ_SESSION(name, ...)                                               \
    do {                                                                     \
        static const uint8_t _z[1] = { 0 };                                  \
        g_case = (name);                                                     \
        const uint8_t *_ob = guard_load(_z, 1);                              \
        aml_arena_reset();                                                   \
        aml_lex_init((uint64_t)(uintptr_t)_ob, 1);                           \
        aml_eval_reset(2);                                                   \
        GUARDED(__VA_ARGS__);                                                \
        guard_free();                                                        \
    } while (0)

static uint64_t mkstr(const char *t)
{
    size_t n = strlen(t);
    uint64_t o = aml_obj_str_alloc(n);
    for (size_t k = 0; k < n; k++) aml_obj_set_byte(o, k, (uint8_t)t[k]);
    return o;
}

static uint64_t mkbuf(const uint8_t *d, size_t n)
{
    uint64_t o = aml_obj_buf_alloc(n);
    for (size_t k = 0; k < n; k++) aml_obj_set_byte(o, k, d[k]);
    return o;
}

static void streq(const char *what, uint64_t o, const char *want)
{
    size_t n = strlen(want);
    eq(what, aml_obj_len(o), (uint64_t)n);
    for (size_t k = 0; k < n; k++)
        eq(what, aml_obj_byte(o, k), (uint64_t)(uint8_t)want[k]);
}

static void test_obj_model(void)
{
    OBJ_SESSION("obj: arena discipline and record shape", {
        eq("session starts empty", aml_obj_count(), 1);
        eq("heap starts at 1", aml_obj_heap_used(), 1);
        eq("elements start at 1", aml_obj_elem_used(), 1);
        eq("no error", aml_eval_err(), AML_OK);

        uint64_t i = aml_obj_int(0x1234);
        eq("integer type", aml_obj_type(i), T_INT);
        eq("integer value", aml_obj_int_value(i), 0x1234);
        eq("object 0 is the null sentinel", aml_obj_type(0), 0);
        eq("and reads as zero on every word", aml_obj_word(0, 1), 0);
        /* nothing above the high-water mark is reachable */
        eq("above the mark reads as zero", aml_obj_word(aml_obj_count(), 0), 0);

        uint64_t so = aml_obj_str_alloc(3);
        eq("string type", aml_obj_type(so), T_STR);
        eq("length EXCLUDES the NUL", aml_obj_len(so), 3);
        eq("set byte", aml_obj_set_byte(so, 0, 'A'), 1);
        eq("byte round-trips", aml_obj_byte(so, 0), 'A');
        eq("the NUL is allocated behind it",
           aml_obj_heap_get(aml_obj_base(so) + 3), 0);

        uint64_t bo = aml_obj_buf_alloc(2);
        eq("buffer type", aml_obj_type(bo), T_BUF);
        eq("a fresh buffer is zero filled", aml_obj_byte(bo, 0), 0);

        uint64_t po = aml_obj_pkg_alloc(3);
        eq("package type", aml_obj_type(po), T_PKG);
        eq("NumElements", aml_obj_len(po), 3);
        eq("an uninitialised element is null", aml_obj_elem_get(po, 2), 0);
        eq("and that is not an error", aml_eval_err(), AML_OK);
        eq("elements bind", aml_obj_elem_set(po, 1, i), 1);
        eq("and read back", aml_obj_elem_get(po, 1), i);

        uint64_t r = aml_obj_ref(R_BUF_FIELD, bo, 1, 0);
        eq("reference type is ACPICA's local 20", aml_obj_type(r), T_REF);
        eq("sub-kind", aml_obj_refkind(r), R_BUF_FIELD);
        eq("base", aml_obj_base(r), bo);
        eq("index", aml_obj_len(r), 1);
        eq("still clean", aml_eval_err(), AML_OK);
    });

    /* Each refusal gets its own session: a latched error is execution-
     * blocking by design (#1054 invariant I3), so two in one session would
     * make the second assertion vacuous. */
    OBJ_SESSION("obj: a byte index past the object is refused", {
        eq("refused", aml_obj_byte(aml_obj_buf_alloc(2), 2), 0);
        eq("OBJ_RANGE", aml_eval_err(), E_OBJ_RANGE);
    });
    OBJ_SESSION("obj: an element index past NumElements is refused", {
        eq("refused", aml_obj_elem_get(aml_obj_pkg_alloc(2), 2), 0);
        eq("OBJ_RANGE", aml_eval_err(), E_OBJ_RANGE);
    });
    OBJ_SESSION("obj: an Integer has no bytes", {
        eq("refused", aml_obj_byte(aml_obj_int(7), 0), 0);
        eq("BAD_OBJTYPE", aml_eval_err(), E_BAD_OBJTYPE);
    });
    OBJ_SESSION("obj: a Buffer is not silently an Integer", {
        eq("refused", aml_obj_int_value(aml_obj_buf_alloc(1)), 0);
        eq("BAD_OBJTYPE", aml_eval_err(), E_BAD_OBJTYPE);
    });
    OBJ_SESSION("obj: an unknown reference sub-kind is refused", {
        eq("refused", aml_obj_ref(9, 1, 0, 0), 0);
        eq("BAD_REF", aml_eval_err(), E_BAD_REF);
    });
    OBJ_SESSION("obj: the payload heap refuses rather than growing", {
        int guard = 0;
        while (aml_eval_err() == AML_OK && guard++ < 400)
            (void)aml_obj_buf_alloc(64);
        eq("exhaustion is a LATCH", aml_eval_err(), E_OBJ_HEAP_FULL);
        eq("bounded, never wrapped", aml_obj_heap_used() <= 8192, 1);
    });
    OBJ_SESSION("obj: the object table refuses rather than growing", {
        int guard = 0;
        while (aml_eval_err() == AML_OK && guard++ < 600)
            (void)aml_obj_int(1);
        eq("exhaustion is a LATCH", aml_eval_err(), E_OBJ_ARENA_FULL);
        eq("bounded at 512 records", aml_obj_count(), 512);
    });
    OBJ_SESSION("obj: the element table refuses rather than growing", {
        int guard = 0;
        while (aml_eval_err() == AML_OK && guard++ < 400)
            (void)aml_obj_pkg_alloc(64);
        eq("exhaustion is a LATCH", aml_eval_err(), E_OBJ_ELEM_FULL);
    });
}

/* ---------------------------------------------------------------------
 * THE CONVERSION MODEL. Two rules that look like one (§19.3.5), and this
 * is the half that says WHICH TYPE EACH OPERATOR WANTS WHERE.
 * --------------------------------------------------------------------- */
static void test_conv_table(void)
{
    OBJ_SESSION("conv: the operand table is keyed by OPERATOR, not operand", {
        /* THE headline pair. Add wants Integers; Concatenate's second
         * operand takes the type of its FIRST. Same operand type, opposite
         * conversions, chosen by the operator. */
        eq("Add operand 0 wants Integer",     aml_conv_want(0x72, 0), T_INT);
        eq("Add operand 1 wants Integer",     aml_conv_want(0x72, 1), T_INT);
        eq("Add operand 2 is a Target",       aml_conv_want(0x72, 2), T_TARGET);
        eq("Concatenate operand 0 is ANY",    aml_conv_want(0x73, 0), 0);
        eq("Concatenate operand 1 follows 0", aml_conv_want(0x73, 1), T_SAME0);
        eq("Concatenate operand 2 is a Target",
                                              aml_conv_want(0x73, 2), T_TARGET);
        /* four operators that ARE a table row plus a store */
        eq("ToBuffer wants Buffer",           aml_conv_want(0x96, 0), T_BUF);
        eq("ToDecimalString wants decimal",   aml_conv_want(0x97, 0), T_STRDEC);
        eq("ToHexString wants hex",           aml_conv_want(0x98, 0), T_STR);
        eq("ToInteger wants Integer",         aml_conv_want(0x99, 0), T_INT);
        eq("ToString wants a Buffer",         aml_conv_want(0x9C, 0), T_BUF);
        eq("then an Integer length",          aml_conv_want(0x9C, 1), T_INT);
        eq("Store operand 1 is a Target",     aml_conv_want(0x70, 1), T_TARGET);
        eq("RefOf operand 0 is a Target",     aml_conv_want(0x71, 0), T_TARGET);
        eq("Index operand 0 is ANY",          aml_conv_want(0x88, 0), 0);
        eq("Index operand 1 wants Integer",   aml_conv_want(0x88, 1), T_INT);
        eq("Mid operand 3 is a Target",       aml_conv_want(0x9E, 3), T_TARGET);
        eq("an unlisted opcode gets the arithmetic default",
                                              aml_conv_want(0x7B, 0), T_INT);
        eq("and its position 2 is a Target",  aml_conv_want(0x7B, 2), T_TARGET);
        eq("there is no operand position 4",  aml_conv_want(0x72, 4), 0);
        /* every row must belong to something somebody actually implements,
         * or the table is describing a promise nothing keeps. Three owners
         * now: aml_str, aml_ref and — since #1059 — aml_ctl, which owns
         * Notify. The METHOD-ARGUMENT row is the one row that is not an
         * opcode at all; it is checked separately below. */
        for (uint64_t k = 0; k < aml_conv_len; k++) {
            uint64_t op = aml_conv_tab[k] & 0xFFFF;
            if (op == aml_conv_argop)
                continue;
            eq("every table row is an implemented operator",
               aml_str_handles(op) || aml_ref_handles(op)
                                   || aml_ctl_handles(op), 1);
        }
    });

    /* #1059 — Notify's operand types come from the table, and the want of
     * REFERENCE in position 0 is what refuses `Notify(5, 0x80)` without
     * Notify's body containing a type test. */
    OBJ_SESSION("conv: Notify's operands are table rows, not a special case", {
        eq("operand 0 wants a Reference", aml_conv_want(0x86, 0), T_REF);
        eq("operand 1 wants an Integer",  aml_conv_want(0x86, 1), T_INT);
        eq("there is no operand 2",       aml_conv_want(0x86, 2), T_ANY);
        eq("aml_ctl owns it",             aml_ctl_handles(0x86), 1);
        eq("and owns nothing else",       aml_ctl_handles(0x87), 0);
        eq("nor an arithmetic opcode",    aml_ctl_handles(0x72), 0);
        eq("nor CondRefOf",               aml_ctl_handles(0x5B12), 0);
        eq("no error", aml_eval_err(), AML_OK);
    });

    /* #1058 — the METHOD ARGUMENT row. ACPI 6.5 §19.6.83 gives arguments no
     * implicit conversion, and this row is how that is SAID rather than
     * merely not-done: without it the default shape applies, and the
     * default wants Integer at position 0 and a TARGET at position 2 —
     * both wrong for an argument, and the first would coerce every Buffer
     * ever passed to a method. The pseudo-opcode is 0xFF01 because op16 is
     * either a single byte (0x00..0xFF) or 0x5Bxx, so it can never
     * collide. */
    OBJ_SESSION("conv: method arguments are a table row that says ANY", {
        eq("the pseudo-opcode is outside the encoding", aml_conv_argop, 0xFF01);
        for (uint64_t p = 0; p < 7; p++)
            eq("no implicit conversion at any argument position",
               aml_conv_want(aml_conv_argop, p), T_ANY);
        /* and the row is load-bearing: this is what the DEFAULT would say */
        eq("without a row, position 0 would want Integer",
           aml_conv_want(0x0072, 0), T_INT);
        eq("without a row, position 2 would be a TARGET",
           aml_conv_want(0x0072, 2), T_TARGET);
        eq("no operator owns the pseudo-opcode",
           aml_str_handles(aml_conv_argop) || aml_ref_handles(aml_conv_argop)
                                           || aml_ctl_handles(aml_conv_argop), 0);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

static void test_conversions(void)
{
    OBJ_SESSION("conv: Integer -> String, hex is padded and decimal is not", {
        uint64_t h = aml_conv_int_to_str(0x2A, 16);
        streq("hex is fixed width/4", h, "000000000000002A");
        streq("decimal suppresses leading zeros",
              aml_conv_int_to_str(42, 10), "42");
        streq("zero is one digit", aml_conv_int_to_str(0, 10), "0");
        eq("no error", aml_eval_err(), AML_OK);
    });

    OBJ_SESSION("conv: Buffer -> String is an ELEMENT LIST, not a number", {
        static const uint8_t d[] = { 0x0F, 0xA0, 0x01 };
        uint64_t b = mkbuf(d, sizeof d);
        streq("hex elements, comma separated",
              aml_conv_buf_to_str(b, 16), "0F,A0,01");
        streq("decimal elements, comma separated",
              aml_conv_buf_to_str(b, 10), "15,160,1");
        streq("an empty Buffer is an empty String",
              aml_conv_buf_to_str(aml_obj_buf_alloc(0), 16), "");
        eq("no error", aml_eval_err(), AML_OK);
    });

    OBJ_SESSION("conv: String -> Integer takes decimal AND 0x hex", {
        eq("decimal",           aml_conv_str_to_int(mkstr("42")), 42);
        eq("0x hex",            aml_conv_str_to_int(mkstr("0x2A")), 42);
        eq("0X hex, lowercase", aml_conv_str_to_int(mkstr("0X2a")), 42);
        eq("leading blanks skipped", aml_conv_str_to_int(mkstr("   7")), 7);
        eq("stops at the first non-digit",
           aml_conv_str_to_int(mkstr("12ab")), 12);
        eq("no digits is ZERO and not an error",
           aml_conv_str_to_int(mkstr("hi")), 0);
        eq("still clean", aml_eval_err(), AML_OK);
    });

    OBJ_SESSION("conv: Buffer -> Integer is little-endian, min(len, width)", {
        static const uint8_t d[] = { 0x34, 0x12 };
        eq("little endian, zero extended",
           aml_conv_buf_to_int(mkbuf(d, 2)), 0x1234);
        static const uint8_t big[] = { 1,2,3,4,5,6,7,8,9 };
        eq("a longer buffer keeps the LOW bytes",
           aml_conv_buf_to_int(mkbuf(big, 9)), 0x0807060504030201ULL);
    });

    OBJ_SESSION("conv: Integer / String -> Buffer", {
        uint64_t b = aml_conv_int_to_buf(0x1234);
        eq("length follows the REVISION, not the value", aml_obj_len(b), 8);
        eq("low byte first", aml_obj_byte(b, 0), 0x34);
        eq("then the next",  aml_obj_byte(b, 1), 0x12);
        uint64_t sb = aml_conv_str_to_buf(mkstr("AB"));
        eq("a String Buffer INCLUDES the NUL", aml_obj_len(sb), 3);
        eq("b0", aml_obj_byte(sb, 0), 'A');
        eq("its last byte is the NUL", aml_obj_byte(sb, 2), 0);
    });

    OBJ_SESSION("conv: a cast to the same type does not copy", {
        uint64_t so = mkstr("x");
        eq("identity", aml_conv_cast(so, T_STR), so);
        eq("ANY is identity too", aml_conv_cast(so, 0), so);
        eq("SAME-AS-0 is resolved by the caller", aml_conv_cast(so, T_SAME0), so);
    });
    OBJ_SESSION("conv: a Package converts to nothing", {
        eq("refused", aml_conv_cast(aml_obj_pkg_alloc(1), T_INT), 0);
        eq("NO_CONVERSION", aml_eval_err(), E_NO_CONVERSION);
    });
    OBJ_SESSION("conv: a Reference converts to nothing either", {
        eq("refused", aml_conv_cast(aml_obj_ref(R_NAME, 1, 0, 0), T_STR), 0);
        eq("NO_CONVERSION", aml_eval_err(), E_NO_CONVERSION);
    });
}

/* ---------------------------------------------------------------------
 * ConcatenateResTemplate — §19.6.14. The EndTag of each source is dropped
 * and ONE new one appended, which is the whole reason the operator exists.
 * --------------------------------------------------------------------- */
static void test_concat_res_template(void)
{
    OBJ_SESSION("str: ConcatenateResTemplate joins descriptor lists", {
        /* Memory32Fixed: large item 6, 9 payload bytes, then an EndTag. */
        static const uint8_t t1[] = { 0x86, 0x09, 0x00,
                                      0x00, 1,0,0,0, 4,0,0,0, 0x79, 0x00 };
        /* IO: small item 8, 7 payload bytes, then an EndTag. */
        static const uint8_t t2[] = { 0x47, 0x01, 0x10,0x00, 0x10,0x00,
                                      0x01, 0x08, 0x79, 0x00 };
        uint64_t a = mkbuf(t1, sizeof t1), b = mkbuf(t2, sizeof t2);
        eq("the chain is WALKED to its EndTag", aml_str_res_end(a), 12);
        eq("and for the small form too", aml_str_res_end(b), 8);
        uint64_t c = aml_str_concat_res(a, b);
        eq("no error", aml_eval_err(), AML_OK);
        eq("descriptors + one EndTag", aml_obj_len(c), 12 + 8 + 2);
        eq("exactly one EndTag, at the end", aml_str_res_end(c), 20);
        eq("generated EndTags carry checksum 0", aml_obj_byte(c, 21), 0);
        eq("the second template survived intact", aml_obj_byte(c, 12), 0x47);
    });
    OBJ_SESSION("str: a buffer with no EndTag is not a template", {
        static const uint8_t bad[] = { 0x86, 0x09, 0x00, 0,0,0,0,0,0,0,0,0 };
        uint64_t a = mkbuf(bad, sizeof bad);
        eq("no EndTag found", aml_str_res_end(a), 0);
        eq("and concatenation refuses", aml_str_concat_res(a, a), 0);
        eq("BAD_OBJTYPE", aml_eval_err(), E_BAD_OBJTYPE);
    });
}

/* ---------------------------------------------------------------------
 * §19.3.5.7 — THE DIRECTION TEST. Storing an Integer into a Name holding
 * a Buffer produces a BUFFER. Implemented the other way round this passes
 * every fixture whose Names only ever hold integers, and then destroys a
 * _CRS on real hardware. CopyObject is run on the SAME fixture, because
 * the only way to prove Store's conversion is doing something is to put
 * it next to the operator that deliberately does not convert (§19.6.20).
 * --------------------------------------------------------------------- */
static void test_store_converts_to_the_destination_type(void)
{
    uint8_t b[] = {
        /* Name(BUFX, Buffer(4){0x11,0x22,0x33,0x44}) */
        0x08, 'B','U','F','X', 0x11, 0x07, 0x0A, 0x04, 0x11,0x22,0x33,0x44,
        /* Method(STOR,0) { Store(0x99, BUFX) ; Return(SizeOf(BUFX)) } */
        0x14, 0x13, 'S','T','O','R', 0x00,
            0x70, 0x0A, 0x99, 'B','U','F','X',
            0xA4, 0x87, 'B','U','F','X',
        /* Method(COPY,0) { CopyObject(0x99, BUFX) ; Return(ObjectType(BUFX)) } */
        0x14, 0x13, 'C','O','P','Y', 0x00,
            0x9D, 0x0A, 0x99, 'B','U','F','X',
            0xA4, 0x8E, 'B','U','F','X',
        /* Method(TYPE,0) { Return(ObjectType(BUFX)) } */
        0x14, 0x0C, 'T','Y','P','E', 0x00,
            0xA4, 0x8E, 'B','U','F','X'
    };
    WITH_PARSE("eval: Store converts to the DESTINATION's existing type",
               b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t nm  = nth_child(root, 0);
        uint64_t stor = nth_child(root, 1);
        uint64_t copy = nth_child(root, 2);
        uint64_t type = nth_child(root, 3);
        eq("name kind", aml_node_kind(nm), N_NAME);
        eq("declared as a buffer", aml_node_flags(nm), 3);

        aml_eval_reset(2);
        eq("the declared type before any store", aml_eval_method(type), T_BUF);

        aml_eval_reset(2);
        eq("SizeOf is still 4 after storing an Integer",
           aml_eval_method(stor), 4);
        eq("no error", aml_eval_err(), AML_OK);
        uint64_t o = aml_obj_bind_get(nm);
        eq("the object bound to the name is a BUFFER", aml_obj_type(o), T_BUF);
        eq("of the DESTINATION's length", aml_obj_len(o), 4);
        eq("byte 0 took the low byte of the Integer", aml_obj_byte(o, 0), 0x99);
        eq("byte 1 was zero filled", aml_obj_byte(o, 1), 0);
        eq("byte 2 was zero filled", aml_obj_byte(o, 2), 0);
        eq("byte 3 was zero filled", aml_obj_byte(o, 3), 0);
        eq("THE PARSE TREE WAS NOT MUTATED", aml_node_flags(nm), 3);

        /* CopyObject does NOT convert: the same store retypes the Name. */
        aml_eval_reset(2);
        eq("CopyObject retypes the destination",
           aml_eval_method(copy), T_INT);
        eq("no error", aml_eval_err(), AML_OK);
        eq("and the bound object really is an Integer",
           aml_obj_type(aml_obj_bind_get(nm)), T_INT);

        /* A fresh session re-materialises from the declaration, so neither
         * store is visible to the next evaluation of the same table. */
        aml_eval_reset(2);
        eq("a new session starts from the declaration again",
           aml_eval_method(type), T_BUF);
        eq("and its bindings are empty", aml_obj_bind_get(nm) != 0, 1);
    });
}

/* ---------------------------------------------------------------------
 * Index() is three operators wearing one opcode, and the three produce
 * three DIFFERENT reference kinds. Conflating them does not fail — it
 * corrupts: a store through a buffer index truncates to one byte, a store
 * through a package index replaces the whole element.
 * --------------------------------------------------------------------- */
static void test_index_three_reference_kinds(void)
{
    uint8_t b[] = {
        /* Name(BUFI, Buffer(3){0xAA,0xBB,0xCC}) */
        0x08, 'B','U','F','I', 0x11, 0x06, 0x0A, 0x03, 0xAA, 0xBB, 0xCC,
        /* Name(STRI, "hey") */
        0x08, 'S','T','R','I', 0x0D, 'h','e','y', 0x00,
        /* Name(PKGI, Package(2){0x10, 0x20}) */
        0x08, 'P','K','G','I', 0x12, 0x06, 0x02, 0x0A, 0x10, 0x0A, 0x20,
        /* Method(DRB_,0){ Return(DerefOf(Index(BUFI,1,Zero))) } */
        0x14, 0x0F, 'D','R','B','_', 0x00,
            0xA4, 0x83, 0x88, 'B','U','F','I', 0x01, 0x00,
        /* Method(DRS_,0){ Return(DerefOf(Index(STRI,1,Zero))) } */
        0x14, 0x0F, 'D','R','S','_', 0x00,
            0xA4, 0x83, 0x88, 'S','T','R','I', 0x01, 0x00,
        /* Method(DRP_,0){ Return(DerefOf(Index(PKGI,1,Zero))) } */
        0x14, 0x0F, 'D','R','P','_', 0x00,
            0xA4, 0x83, 0x88, 'P','K','G','I', 0x01, 0x00,
        /* Method(OTB_,0){ Return(ObjectType(Index(BUFI,1,Zero))) } */
        0x14, 0x0F, 'O','T','B','_', 0x00,
            0xA4, 0x8E, 0x88, 'B','U','F','I', 0x01, 0x00,
        /* Method(OTP_,0){ Return(ObjectType(Index(PKGI,1,Zero))) } */
        0x14, 0x0F, 'O','T','P','_', 0x00,
            0xA4, 0x8E, 0x88, 'P','K','G','I', 0x01, 0x00,
        /* Method(SIZ_,0){ Return(SizeOf(PKGI)) } */
        0x14, 0x0C, 'S','I','Z','_', 0x00,
            0xA4, 0x87, 'P','K','G','I'
    };
    WITH_PARSE("eval: the three Index forms and their references",
               b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t bn = nth_child(root, 0);
        uint64_t sn = nth_child(root, 1);
        uint64_t pn = nth_child(root, 2);

        /* THE distinctness assertion. */
        aml_eval_reset(2);
        uint64_t bo = aml_eval_obj(bn);
        uint64_t so = aml_eval_obj(sn);
        uint64_t po = aml_eval_obj(pn);
        eq("a Buffer declaration materialises as a Buffer",
           aml_obj_type(bo), T_BUF);
        eq("a String declaration as a String",  aml_obj_type(so), T_STR);
        eq("a Package declaration as a Package", aml_obj_type(po), T_PKG);
        eq("buffer contents", aml_obj_byte(bo, 1), 0xBB);
        eq("string contents", aml_obj_byte(so, 1), 'e');
        eq("string length excludes the NUL", aml_obj_len(so), 3);
        eq("package elements", aml_obj_int_value(aml_obj_elem_get(po, 1)), 0x20);
        eq("Index(Buffer,n)  is a BufferField reference",
           aml_obj_refkind(aml_ref_index(bo, 1)), R_BUF_FIELD);
        eq("Index(String,n)  is a StringField reference",
           aml_obj_refkind(aml_ref_index(so, 1)), R_STR_FIELD);
        eq("Index(Package,n) is a package-ELEMENT reference",
           aml_obj_refkind(aml_ref_index(po, 1)), R_PKG_ELEM);
        eq("no error", aml_eval_err(), AML_OK);

        /* DerefOf round-trips each kind, through AML this time. */
        aml_eval_reset(2);
        eq("DerefOf a buffer index", aml_eval_method(nth_child(root, 3)), 0xBB);
        aml_eval_reset(2);
        eq("DerefOf a string index", aml_eval_method(nth_child(root, 4)), 'e');
        aml_eval_reset(2);
        eq("DerefOf a package index", aml_eval_method(nth_child(root, 5)), 0x20);
        aml_eval_reset(2);
        eq("ObjectType of a buffer index is BufferField",
           aml_eval_method(nth_child(root, 6)), T_BUFFIELD);
        aml_eval_reset(2);
        eq("ObjectType of a package index is the ELEMENT's type",
           aml_eval_method(nth_child(root, 7)), T_INT);
        aml_eval_reset(2);
        eq("SizeOf a Package is its element count",
           aml_eval_method(nth_child(root, 8)), 2);

        /* THE CORRUPTION TEST. The same Integer stored through a buffer
         * index and through a package index must land differently. */
        aml_eval_reset(2);
        bo = aml_eval_obj(bn);
        po = aml_eval_obj(pn);
        eq("stored through the buffer field",
           aml_ref_store_through(aml_ref_index(bo, 0), aml_obj_int(0x1234)), 1);
        eq("stored through the package element",
           aml_ref_store_through(aml_ref_index(po, 0), aml_obj_int(0x1234)), 1);
        eq("a buffer field takes ONLY the low byte", aml_obj_byte(bo, 0), 0x34);
        eq("and does not disturb its neighbour", aml_obj_byte(bo, 1), 0xBB);
        eq("a package element takes the WHOLE object",
           aml_obj_int_value(aml_obj_elem_get(po, 0)), 0x1234);
        eq("no error", aml_eval_err(), AML_OK);

        /* Out of range, each in a session of its own. */
        aml_eval_reset(2);
        eq("Index past a Buffer is refused",
           aml_ref_index(aml_eval_obj(bn), 3), 0);
        eq("OBJ_RANGE", aml_eval_err(), E_OBJ_RANGE);
        aml_eval_reset(2);
        eq("Index at a String's NUL is refused",
           aml_ref_index(aml_eval_obj(sn), 3), 0);
        eq("OBJ_RANGE", aml_eval_err(), E_OBJ_RANGE);
        aml_eval_reset(2);
        eq("Index past a Package is refused",
           aml_ref_index(aml_eval_obj(pn), 2), 0);
        eq("OBJ_RANGE", aml_eval_err(), E_OBJ_RANGE);
        aml_eval_reset(2);
        eq("Index of an Integer is refused",
           aml_ref_index(aml_obj_int(1), 0), 0);
        eq("BAD_OBJTYPE", aml_eval_err(), E_BAD_OBJTYPE);
        aml_eval_reset(2);
        eq("DerefOf of a non-reference passes through unchanged",
           aml_obj_int_value(aml_ref_deref(aml_obj_int(7))), 7);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* An element WITHIN NumElements that was never initialised is a different
 * fault from an index past NumElements, and gets a different code. */
static void test_uninitialised_package_element(void)
{
    uint8_t b[] = {
        /* Name(SPAR, Package(3){0x01}) — legal per §20.2.5.4 */
        0x08, 'S','P','A','R', 0x12, 0x03, 0x03, 0x01,
        /* Method(UNI_,0){ Return(DerefOf(Index(SPAR,2,Zero))) } */
        0x14, 0x10, 'U','N','I','_', 0x00,
            0xA4, 0x83, 0x88, 'S','P','A','R', 0x0A, 0x02, 0x00
    };
    WITH_PARSE("eval: an uninitialised package element is its own error",
               b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t pn = nth_child(root, 0);
        aml_eval_reset(2);
        uint64_t po = aml_eval_obj(pn);
        eq("three declared elements", aml_obj_len(po), 3);
        eq("one was initialised",
           aml_obj_int_value(aml_obj_elem_get(po, 0)), 1);
        eq("the others are null", aml_obj_elem_get(po, 2), 0);
        eq("and reading them is not an error yet", aml_eval_err(), AML_OK);
        aml_eval_reset(2);
        eq("but DEREFERENCING one is",
           aml_eval_method(nth_child(root, 1)), 0);
        eq("UNINIT_ELEMENT, not OBJ_RANGE", aml_eval_err(), E_UNINIT_ELEMENT);
    });
}

/* ---------------------------------------------------------------------
 * CondRefOf — the ONE construct where a namespace miss is a VALUE.
 * --------------------------------------------------------------------- */
static void test_cond_ref_of(void)
{
    uint8_t b[] = {
        /* Device(DEV0) { Name(HIDE, 7) } — HIDE is not visible from root */
        0x5B, 0x82, 0x0C, 'D','E','V','0',
            0x08, 'H','I','D','E', 0x0A, 0x07,
        /* Name(SEEN, 9) */
        0x08, 'S','E','E','N', 0x0A, 0x09,
        /* Method(CRM_,0){ Return(CondRefOf(HIDE, Local0)) } */
        0x14, 0x0E, 'C','R','M','_', 0x00,
            0xA4, 0x5B, 0x12, 'H','I','D','E', 0x60,
        /* Method(CRS_,0){ Return(CondRefOf(SEEN, Local0)) } */
        0x14, 0x0E, 'C','R','S','_', 0x00,
            0xA4, 0x5B, 0x12, 'S','E','E','N', 0x60,
        /* Method(CRV_,0){ CondRefOf(SEEN, Local0) ; Return(DerefOf(Local0)) } */
        0x14, 0x10, 'C','R','V','_', 0x00,
            0x5B, 0x12, 'S','E','E','N', 0x60,
            0xA4, 0x83, 0x60
    };
    WITH_PARSE("eval: CondRefOf turns a miss into False, not an error",
               b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t miss = nth_child(root, 2);
        uint64_t hit  = nth_child(root, 3);
        uint64_t val  = nth_child(root, 4);

        aml_eval_reset(2);
        eq("a miss returns Zero", aml_eval_method(miss), 0);
        eq("AND DOES NOT LATCH", aml_eval_err(), AML_OK);
        eq("the quiet flag was restored", aml_eval_quiet(), 0);

        aml_eval_reset(2);
        eq("a hit returns Ones", aml_eval_method(hit), 0xFFFFFFFFFFFFFFFFull);
        eq("no error", aml_eval_err(), AML_OK);
        eq("the quiet flag was restored", aml_eval_quiet(), 0);

        aml_eval_reset(2);
        eq("and the reference it stored dereferences",
           aml_eval_method(val), 9);
        eq("no error", aml_eval_err(), AML_OK);

        /* A plain RefOf of the same invisible name IS an error: only
         * CondRefOf treats a miss as data. */
        aml_eval_reset(2);
        uint64_t crm_src = aml_node_first_child(
                               aml_node_first_child(
                                   aml_node_first_child(miss)));
        eq("the CondRefOf source node", aml_node_kind(crm_src), N_NAMEREF);
        eq("RefOf of the same name is refused",
           aml_ref_of_node(crm_src, 0), 0);
        eq("NAME_NOT_FOUND", aml_eval_err(), E_NAME_NOT_FOUND);
    });
}

/* ---------------------------------------------------------------------
 * §19.3.5.8 — a store to an ArgX holding a Reference goes THROUGH it; a
 * store to a LocalX does not. The asymmetry is the specification's, and
 * an implementation that made the two agree would be wrong either way.
 * Driven through the module API because getting a reference INTO an ArgX
 * from bytecode needs argument promotion, which is #1058's.
 * --------------------------------------------------------------------- */
static void test_arg_stores_through_a_reference(void)
{
    uint8_t b[] = {
        /* Name(TGTV, 0) */
        0x08, 'T','G','T','V', 0x0A, 0x00,
        /* Method(STHR,1){ Store(0x77, Arg0) } */
        0x14, 0x0A, 'S','T','H','R', 0x01, 0x70, 0x0A, 0x77, 0x68,
        /* Method(LOCX,0){ Store(0x55, Local0) } */
        0x14, 0x0A, 'L','O','C','X', 0x00, 0x70, 0x0A, 0x55, 0x60
    };
    WITH_PARSE("eval: ArgX stores through a reference, LocalX overwrites",
               b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t nm   = nth_child(root, 0);
        uint64_t m1   = nth_child(root, 1);
        uint64_t m2   = nth_child(root, 2);
        uint64_t argx = nth_child(aml_node_first_child(m1), 1);
        uint64_t locx = nth_child(aml_node_first_child(m2), 1);
        eq("ArgX target node", aml_node_kind(argx), N_ARGX);
        eq("LocalX target node", aml_node_kind(locx), N_LOCALX);

        aml_eval_reset(2);
        eq("a frame is pushed", aml_frame_push(m1), 1);
        eq("and stamped with a serial", aml_frame_serial_of(1) != 0, 1);
        uint64_t r = aml_obj_ref(R_NAME, nm, 0, 0);
        eq("Arg0 takes the reference", aml_frame_set_arg_obj(0, r), 1);
        eq("and is tagged as an object", aml_frame_arg_is_obj(0), 1);
        eq("stored", aml_eval_store_obj(argx, aml_obj_int(0x77)), 1);
        eq("THE REFERENCED NAME WAS WRITTEN",
           aml_u64_get(aml_node_arg0(nm)), 0x77);
        eq("and the slot still holds the reference",
           aml_frame_ref_get(1, R_ARG, 0), r);

        eq("Local0 takes the same reference", aml_frame_set_local_obj(0, r), 1);
        eq("stored", aml_eval_store_obj(locx, aml_obj_int(0x55)), 1);
        eq("THE NAME IS UNCHANGED", aml_u64_get(aml_node_arg0(nm)), 0x77);
        eq("the Local was retyped to the Integer",
           aml_obj_int_value(aml_frame_ref_get(1, R_LOCAL, 0)), 0x55);

        /* AN INTEGER WRITE RETYPES THE SLOT. The tag bit is what tells an
         * object index from a small integer -- they are both small numbers
         * and no heuristic can separate them -- so the #1054 integer
         * writers must CLEAR it. If they did not, Local0 = 3 would read
         * back as a reference to object 3 on the very next evaluation. */
        eq("the slot is currently an object", aml_frame_local_is_obj(0), 1);
        eq("an integer write succeeds", aml_frame_set_local(0, 3), 1);
        eq("AND CLEARS THE TAG", aml_frame_local_is_obj(0), 0);
        eq("so it reads back as the Integer", aml_frame_local(0), 3);
        eq("and as an Integer object too",
           aml_obj_int_value(aml_frame_ref_get(1, R_LOCAL, 0)), 3);
        eq("the same holds for arguments", aml_frame_arg_is_obj(0), 1);
        eq("an integer write succeeds", aml_frame_set_arg(0, 4), 1);
        eq("AND CLEARS THE TAG", aml_frame_arg_is_obj(0), 0);

        /* the bitmap layout itself: seven args on bits 0..6, eight locals
         * on bits 8..15, and the asymmetry is §20.2.6.2's */
        eq("Arg0 is bit 0",   aml_frame_bit(R_ARG, 0), 1);
        eq("Arg6 is bit 6",   aml_frame_bit(R_ARG, 6), 7);
        eq("there is no Arg7", aml_frame_bit(R_ARG, 7), 0);
        eq("Local0 is bit 8", aml_frame_bit(R_LOCAL, 0), 9);
        eq("Local7 is bit 15", aml_frame_bit(R_LOCAL, 7), 16);
        eq("there is no Local8", aml_frame_bit(R_LOCAL, 8), 0);

        eq("no error", aml_eval_err(), AML_OK);
        aml_frame_pop();
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

/* Eight frames are a REUSED POOL, so a reference that recorded only
 * "frame 3, slot 0" would silently re-aim at whoever holds that slot
 * next. The serial is what turns that into an error. */
static void test_stale_frame_reference(void)
{
    uint8_t b[] = { 0x14, 0x07, 'N','U','L','L', 0x00, 0x60 };
    WITH_PARSE("eval: a reference into a popped frame is stale, not wrong",
               b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t m = aml_node_first_child(root);
        aml_eval_reset(2);
        uint64_t f1 = aml_frame_push(m);
        uint64_t s1 = aml_frame_serial_of(f1);
        uint64_t lref = aml_obj_ref(R_LOCAL, f1, 0, s1);
        eq("Local0 holds an Integer", aml_frame_set_local_obj(0, aml_obj_int(11)), 1);
        eq("the reference reads it", aml_obj_int_value(aml_ref_deref(lref)), 11);
        aml_frame_pop();
        uint64_t f2 = aml_frame_push(m);
        eq("the pool reused the same slot", f2, f1);
        eq("but not the same serial", aml_frame_serial_of(f2) != s1, 1);
        eq("the old reference is REFUSED", aml_ref_deref(lref), 0);
        eq("STALE_REF, not a read of someone else's local",
           aml_eval_err(), E_STALE_REF);
        aml_frame_pop();
    });
}

/* ---------------------------------------------------------------------
 * Match — §19.6.65. Fuel is spent PER ELEMENT, so a firmware package
 * declaring 0xFFFF elements costs the budget rather than the wall clock.
 * --------------------------------------------------------------------- */
static void test_eval_match(void)
{
    uint8_t b[] = {
        /* Name(MPKG, Package(4){0x10,0x20,0x30,0x40}) */
        0x08, 'M','P','K','G', 0x12, 0x0A, 0x04,
            0x0A,0x10, 0x0A,0x20, 0x0A,0x30, 0x0A,0x40,
        /* Method(MAT_,0){ Return(Match(MPKG, MEQ, 0x30, MTR, Zero, Zero)) } */
        0x14, 0x12, 'M','A','T','_', 0x00,
            0xA4, 0x89, 'M','P','K','G', 0x01, 0x0A,0x30, 0x00, 0x00, 0x00,
        /* Method(MNO_,0){ Return(Match(MPKG, MEQ, 0x99, MTR, Zero, Zero)) } */
        0x14, 0x12, 'M','N','O','_', 0x00,
            0xA4, 0x89, 'M','P','K','G', 0x01, 0x0A,0x99, 0x00, 0x00, 0x00,
        /* Method(MGT_,0){ Return(Match(MPKG, MGT, 0x20, MTR, Zero, Zero)) } */
        0x14, 0x12, 'M','G','T','_', 0x00,
            0xA4, 0x89, 'M','P','K','G', 0x05, 0x0A,0x20, 0x00, 0x00, 0x00,
        /* Name(BIGP, Package(200){}) — declared big, no initialisers, which
         * §20.2.5.4 permits and which is how a firmware table makes a scan
         * expensive without making the TABLE big */
        0x08, 'B','I','G','P', 0x12, 0x02, 0xC8,
        /* Method(BIGM,0){ Return(Match(BIGP, MEQ, 0x99, MTR, Zero, Zero)) } */
        0x14, 0x12, 'B','I','G','M', 0x00,
            0xA4, 0x89, 'B','I','G','P', 0x01, 0x0A,0x99, 0x00, 0x00, 0x00
    };
    WITH_PARSE("eval: Match scans a Package and spends fuel per element",
               b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        aml_eval_reset(2);
        eq("MEQ finds index 2", aml_eval_method(nth_child(root, 1)), 2);
        aml_eval_reset(2);
        eq("no match is Ones", aml_eval_method(nth_child(root, 2)),
           0xFFFFFFFFFFFFFFFFull);
        aml_eval_reset(2);
        eq("MGT finds the first element above 0x20",
           aml_eval_method(nth_child(root, 3)), 2);
        eq("no error", aml_eval_err(), AML_OK);
        /* the match opcodes came from the node's arg0/arg1, not from the
         * child list — reading them as TermArgs would consume the package */
        uint64_t mexpr = aml_node_first_child(
                             aml_node_first_child(nth_child(root, 1)));
        eq("MatchOpcode 1 is raw ByteData", aml_node_arg0(mexpr), 1);
        eq("MatchOpcode 2 is raw ByteData", aml_node_arg1(mexpr), 0);
        eq("four TermArg children", (uint64_t)count_children(mexpr), 4);

        /* THE SCAN IS FUEL-BOUNDED. Two hundred declared elements and a
         * sixty-step budget: the loop must stop on the BUDGET, not on the
         * package's own claim about how long it is. Without a spend per
         * element the scan is free and the only bound on Match's cost is a
         * byte in the table. */
        aml_eval_reset(2);
        eq("budget clamped down", aml_eval_set_fuel(60), 60);
        (void)aml_eval_method(nth_child(root, 5));
        eq("FUEL_EXHAUSTED", aml_eval_err(), E_FUEL_EXHAUSTED);
        eq("depth unwound", aml_eval_depth(), 0);
        /* and with a real budget the same scan completes */
        aml_eval_reset(2);
        eq("no match over 200 elements", aml_eval_method(nth_child(root, 5)),
           0xFFFFFFFFFFFFFFFFull);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* ---------------------------------------------------------------------
 * ALLOCATION DISCIPLINE. The object arena is 512 records with no free, so
 * the fast path is not an optimisation — it is what stops an idiom every
 * DSDT contains from exhausting it.
 * --------------------------------------------------------------------- */
static void test_object_budgets(void)
{
    {
        uint8_t b[] = {
            /* Method(ARIT,0){ Return(Add(5,3,Zero)) } */
            0x14, 0x0D, 'A','R','I','T', 0x00,
                0xA4, 0x72, 0x0A, 0x05, 0x0A, 0x03, 0x00
        };
        WITH_PARSE("eval: arithmetic allocates NO objects", b, sizeof b, {
            eq("parse ok", aml_lex_err(), AML_OK);
            aml_eval_reset(2);
            eq("value", aml_eval_method(aml_node_first_child(root)), 8);
            eq("the integer fast path allocated nothing", aml_obj_count(), 1);
            eq("and touched no heap", aml_obj_heap_used(), 1);

            /* The object dispatcher takes its OWN step of fuel and its own
             * level of depth. Without that, an object-valued construct
             * would be free and only its enclosing statement would be
             * counted -- which is exactly how a deeply nested Package or a
             * Concatenate chain gets an unbounded budget. */
            aml_eval_reset(2);
            uint64_t expr = aml_node_first_child(
                                aml_node_first_child(
                                    aml_node_first_child(root)));
            eq("the Return operand", aml_node_kind(expr), N_EXPR);
            /* A LEAF node, so the only fuel that can be spent is this
             * dispatcher's own step -- an operand that itself evaluated
             * would spend through aml_eval_node and hide the omission. */
            uint64_t leaf = nth_child(expr, 0);
            eq("a literal operand", aml_node_kind(leaf), N_INT);
            uint64_t before = aml_eval_fuel();
            uint64_t o = aml_eval_obj(leaf);
            eq("it produced an object", aml_obj_type(o), T_INT);
            eq("of the literal's value", aml_obj_int_value(o), 5);
            eq("AND IT SPENT EXACTLY ONE STEP", before - aml_eval_fuel(), 1);
            eq("depth unwound", aml_eval_depth(), 0);
            /* and a latched error blocks it, like every other spender */
            (void)aml_eval_set_err(E_NOT_EVALUABLE);
            uint64_t stuck = aml_eval_fuel();
            eq("a blocked session produces nothing", aml_eval_obj(leaf), 0);
            eq("and spends nothing", aml_eval_fuel(), stuck);
        });
    }
    {
        uint8_t b[] = {
            /* Method(SLOP,0){ Store(Zero,Local0)
             *                 While(LLess(Local0,100)) {
             *                     Increment(Local0) ; Store(Local0,Local1) }
             *                 Return(Local1) } */
            0x14, 0x16, 'S','L','O','P', 0x00,
                0x70, 0x00, 0x60,
                0xA2, 0x0A, 0x95, 0x60, 0x0A, 0x64,
                    0x75, 0x60,
                    0x70, 0x60, 0x61,
                0xA4, 0x61
        };
        WITH_PARSE("eval: a hundred Stores allocate NO objects", b, sizeof b, {
            eq("parse ok", aml_lex_err(), AML_OK);
            aml_eval_reset(2);
            eq("value", aml_eval_method(aml_node_first_child(root)), 100);
            eq("no error", aml_eval_err(), AML_OK);
            eq("the Store fast path allocated nothing", aml_obj_count(), 1);
        });
    }
    {
        /* Method(CATL,0){ Store("x",Local0)
         *                 While(One){ Store(Concatenate(Local0,"y",Zero),
         *                                   Local0) }
         *                 Return(Zero) } */
        uint8_t b[] = {
            0x14, 0x18, 'C','A','T','L', 0x00,
                0x70, 0x0D, 'x', 0x00, 0x60,
                0xA2, 0x0A, 0x01,
                    0x70, 0x73, 0x60, 0x0D, 'y', 0x00, 0x00, 0x60,
                0xA4, 0x00
        };
        WITH_PARSE("eval: a Concatenate loop terminates on FUEL",
                   b, sizeof b, {
            eq("parse ok", aml_lex_err(), AML_OK);
            aml_eval_reset(2);
            eq("budget clamped down", aml_eval_set_fuel(80), 80);
            (void)aml_eval_method(aml_node_first_child(root));
            eq("FUEL_EXHAUSTED", aml_eval_err(), E_FUEL_EXHAUSTED);
            eq("fuel reached exactly zero", aml_eval_fuel(), 0);
            eq("depth unwound", aml_eval_depth(), 0);
            eq("frames unwound", aml_eval_frames(), 0);
        });
        WITH_PARSE("eval: and on the payload heap when fuel is plentiful",
                   b, sizeof b, {
            eq("parse ok", aml_lex_err(), AML_OK);
            aml_eval_reset(2);
            (void)aml_eval_method(aml_node_first_child(root));
            /* Either bound is a DETERMINISTIC stop; what must never happen
             * is that it runs. The 60-second watchdog covers the third
             * possibility. */
            uint64_t e = aml_eval_err();
            eq("bounded by the object model, not by the clock",
               e == E_OBJ_HEAP_FULL || e == E_OBJ_ARENA_FULL, 1);
            eq("heap never exceeded its ceiling", aml_obj_heap_used() <= 8192, 1);
            eq("depth unwound", aml_eval_depth(), 0);
        });
    }
}

/* The object dispatcher takes its own level of DEPTH as well as its own
 * step of fuel, and the two bound different things: fuel bounds total work,
 * depth bounds native stack. Nested Packages consume depth without looping,
 * so they are the construct that reaches the depth guard through the object
 * path -- an evaluator that spent fuel but took no depth would recurse
 * 100 000 levels into the native stack before the fuel ran out. */
static void test_object_depth_cap(void)
{
    static uint8_t tmp[8192], scratch[8192], meth[8192];
    size_t len = 0;
    /* innermost: Package(1){Zero} */
    tmp[len++] = 0x12; tmp[len++] = 0x03; tmp[len++] = 0x01; tmp[len++] = 0x00;
    for (int i = 0; i < 50; i++) {
        uint8_t hdr[8], pk[4];
        size_t hl = 0, pn = emit_pkglen(pk, 1 + len);
        hdr[hl++] = 0x12;
        memcpy(hdr + hl, pk, pn); hl += pn;
        hdr[hl++] = 0x01;                       /* NumElements */
        memcpy(scratch, tmp, len);
        memcpy(tmp, hdr, hl);
        memcpy(tmp + hl, scratch, len);
        len += hl;
    }
    size_t n = 0;
    uint8_t mk[4];
    size_t mn = emit_pkglen(mk, 4 + 1 + 2 + len);
    meth[n++] = 0x14;
    memcpy(meth + n, mk, mn); n += mn;
    memcpy(meth + n, "DEEP", 4); n += 4;
    meth[n++] = 0x00;                           /* MethodFlags */
    meth[n++] = 0xA4;                           /* Return */
    meth[n++] = 0x87;                           /* SizeOf */
    memcpy(meth + n, tmp, len); n += len;

    WITH_PARSE("eval: nested Packages reach the DEPTH guard", meth, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        eq("parse depth unwound", aml_lex_depth(), 0);
        aml_eval_reset(2);
        (void)aml_eval_method(aml_node_first_child(root));
        eq("EVAL_DEPTH, not a native stack overflow",
           aml_eval_err(), E_EVAL_DEPTH);
        eq("and the counter unwound exactly", aml_eval_depth(), 0);
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

/* Every opcode belongs to exactly one module, asserted in both
 * directions so the claim cannot rot into a stale header comment. */
static void test_object_operator_coverage(void)
{
    static const uint64_t str_ops[] = { 0x73, 0x84, 0x87, 0x89, 0x96,
                                        0x97, 0x98, 0x99, 0x9C, 0x9E };
    static const uint64_t ref_ops[] = { 0x70, 0x71, 0x83, 0x88, 0x8E,
                                        0x9D, 0x5B12 };
    OBJ_SESSION("eval: each opcode is owned by exactly one module", {
        for (size_t k = 0; k < sizeof str_ops / sizeof str_ops[0]; k++) {
            eq("claimed by aml_str",     aml_str_handles(str_ops[k]), 1);
            eq("and not by aml_ref",     aml_ref_handles(str_ops[k]), 0);
            eq("and not by aml_arith",   aml_arith_handles(str_ops[k]), 0);
        }
        for (size_t k = 0; k < sizeof ref_ops / sizeof ref_ops[0]; k++) {
            eq("claimed by aml_ref",     aml_ref_handles(ref_ops[k]), 1);
            eq("and not by aml_str",     aml_str_handles(ref_ops[k]), 0);
            eq("and not by aml_arith",   aml_arith_handles(ref_ops[k]), 0);
        }
        /* Acquire is a real opcode nobody evaluates yet, and it must stay
         * refused rather than be quietly absorbed by a range test. */
        eq("Acquire is claimed by nobody",
           aml_str_handles(0x5B23) + aml_ref_handles(0x5B23)
                                   + aml_arith_handles(0x5B23), 0);
    });
}

/* ---------------------------------------------------------------------
 * Integer width follows the TABLE REVISION, not the machine. ACPI 6.5
 * §19.6: 32-bit when the DSDT/SSDT revision is 1, 64-bit from 2 on. iasl
 * still emits revision 1 unless told otherwise, so this is not a legacy
 * concern.
 * --------------------------------------------------------------------- */
static void test_eval_integer_width_follows_revision(void)
{
    const uint64_t ONES64 = 0xFFFFFFFFFFFFFFFFull;

    /* Ones truncates. design/acpi/aml-parser.md §9 deferred exactly this
     * to R30.M2: the parser stores the full 64-bit value so one parse
     * tree serves both revisions, and the evaluator narrows on read. */
    EXPR_CASE("eval rev1: Ones is 32-bit", 1, 0xFFFFFFFFull, AML_OK, 0xFF);
    EXPR_CASE("eval rev2: Ones is 64-bit", 2, ONES64,        AML_OK, 0xFF);

    EXPR_CASE("eval rev1: Not(Zero) is 32-bit", 1, 0xFFFFFFFFull, AML_OK,
              0x80,0x00,0x00);
    EXPR_CASE("eval rev2: Not(Zero) is 64-bit", 2, ONES64, AML_OK,
              0x80,0x00,0x00);

    /* Addition wraps at the table's width. */
    EXPR_CASE("eval rev1: Add wraps at 2^32", 1, 0, AML_OK,
              0x72,0x0C,0xFF,0xFF,0xFF,0xFF,0x0A,0x01,0x00);
    EXPR_CASE("eval rev2: Add does not wrap at 2^32", 2, 0x100000000ull, AML_OK,
              0x72,0x0C,0xFF,0xFF,0xFF,0xFF,0x0A,0x01,0x00);

    /* A shift by 32 empties a 32-bit integer and does not empty a 64-bit
     * one, so the width is doing real work in both directions. */
    EXPR_CASE("eval rev1: ShiftLeft by 32 is Zero", 1, 0, AML_OK,
              0x79,0x01,0x0A,0x20,0x00);
    EXPR_CASE("eval rev2: ShiftLeft by 32 is 2^32", 2, 0x100000000ull, AML_OK,
              0x79,0x01,0x0A,0x20,0x00);

    /* The discriminator: on a revision-1 table Ones EQUALS 0xFFFFFFFF. A
     * hardcoded 64-bit interpreter answers Zero here. */
    EXPR_CASE("eval rev1: Ones == 0xFFFFFFFF", 1, 0xFFFFFFFFull, AML_OK,
              0x93,0xFF,0x0C,0xFF,0xFF,0xFF,0xFF);
    EXPR_CASE("eval rev2: Ones != 0xFFFFFFFF", 2, 0, AML_OK,
              0x93,0xFF,0x0C,0xFF,0xFF,0xFF,0xFF);

    /* Revision 0 predates the 64-bit definition and is read narrowly. */
    EXPR_CASE("eval rev0: narrowed to 32-bit", 0, 0xFFFFFFFFull, AML_OK, 0xFF);

    /* And a store into a named object narrows too, so a revision-1 object
     * can never come to hold a 64-bit value. */
    EXPR_CASE("eval rev1: RevisionOp reports 1", 1, 1, AML_OK, 0x5B,0x30);
}

/* aml_arith_handles is the executable form of "which opcodes #1055 owns".
 * Asserting it in both directions is what stops the header list and the
 * dispatch chain drifting apart. */
static void test_eval_operator_coverage(void)
{
    g_case = "eval: operator coverage is exact";
    static const uint64_t owned[] = {
        0x72, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C,
        0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0x85,
        0x90, 0x91, 0x92, 0x93, 0x94, 0x95
    };
    static const uint64_t not_owned[] = {
        0x70,        /* Store        — #1057 */
        0x71,        /* RefOf        — #1057 */
        0x73,        /* Concat       — #1056 */
        0x83,        /* DerefOf      — #1057 */
        0x84,        /* ConcatRes    — #1056 */
        0x86,        /* Notify       — #1059 */
        0x87,        /* SizeOf       — #1056 */
        0x88,        /* Index        — #1057 */
        0x8E,        /* ObjectType   — #1057 */
        0x96,        /* ToBuffer     — #1056 */
        0x99,        /* ToInteger    — #1056 */
        0x9E,        /* Mid          — #1056 */
        0x5B12       /* CondRefOf    — #1057 */
    };
    for (size_t i = 0; i < sizeof owned / sizeof owned[0]; i++)
        eq("owned", aml_arith_handles(owned[i]), 1);
    for (size_t i = 0; i < sizeof not_owned / sizeof not_owned[0]; i++)
        eq("not owned", aml_arith_handles(not_owned[i]), 0);
    /* 0x83..0x84 sit inside no range; 0x85 Mod sits outside the 0x72..0x82
     * block and is reached by its own arm, which is why both ends of the
     * arithmetic range are probed here rather than assumed contiguous. */
    eq("below the range", aml_arith_handles(0x71), 0);
    eq("above the logical range", aml_arith_handles(0x96), 0);
}

/* aml_eval_names decides which nodes contribute a component to an absolute
 * namespace path, and getting it wrong corrupts every path underneath
 * rather than failing visibly. It is a table with a reason per row in
 * aml_eval.pdx, so it is asserted here as a table too — every kind the
 * arena defines, in both directions. The three Field kinds and the four
 * reference kinds are the rows that matter: they all CARRY a name_ref, so
 * a "has a name" implementation would include them and would place every
 * field element under its region. */
static void test_eval_name_contributing_kinds(void)
{
    g_case = "eval: which node kinds contribute a namespace component";
    static const uint64_t names_it[] = {
        N_SCOPE, N_DEVICE, N_METHOD, N_NAME, N_ALIAS, N_PROCESSOR,
        N_POWERRES, N_THERMALZONE, N_OPREGION, N_FIELD_ELEM, N_EXTERNAL,
        N_MUTEX, N_EVENT
    };
    static const uint64_t transparent[] = {
        N_ROOT,                             /* the empty path, not a segment */
        N_FIELD, N_INDEXFIELD, N_BANKFIELD, /* carry the REGION's name */
        N_FIELD_LINK, N_FIELD_CONNECT,      /* references */
        N_OPAQUE, N_FIELD_ACCESS, N_FIELD_RESERVED,
        N_CALL,                             /* carries the CALLEE's name */
        N_NAMEREF,                          /* a use, not a declaration */
        N_EXPR, N_IF, N_ELSE, N_WHILE, N_RETURN, N_BREAK, N_CONTINUE,
        N_NOOP, N_BREAKPOINT, N_INT, N_STRING, N_BUFFER, N_PACKAGE,
        N_VARPACKAGE, N_ARGX, N_LOCALX, N_MISC, N_RESOURCE, N_RESDESC
    };
    for (size_t i = 0; i < sizeof names_it / sizeof names_it[0]; i++)
        eq("contributes", aml_eval_names(names_it[i]), 1);
    for (size_t i = 0; i < sizeof transparent / sizeof transparent[0]; i++)
        eq("transparent", aml_eval_names(transparent[i]), 0);
    /* and nothing beyond the kind space */
    eq("kind 0 is not a kind", aml_eval_names(0), 0);
    eq("past the table", aml_eval_names(64), 0);
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

/* =====================================================================
 * R30.M2-005 (#1058) — invocation: arity, argument promotion, return type.
 * ===================================================================== */

/* THE PROMOTION FIXTURE. Two methods with IDENTICAL bodies — Store(0x2A,
 * Arg0) — called two different ways, and the two must disagree about
 * whether the caller sees the write.
 *
 * That disagreement is the whole of §19.3.5.8's ArgX rule: an ArgX holding
 * a REFERENCE stores through it, an ArgX holding a VALUE does not. Before
 * #1058 the question could not arise, because aml_eval_call evaluated
 * every argument through the INTEGER dispatcher and bound it with
 * aml_frame_set_arg, which clears the object tag — so RefOf(TGTR) was
 * either refused or flattened, and either way both methods would agree.
 *
 * Two Names rather than one, because a single shared target could be
 * written by the by-reference call and then read by the by-value one, and
 * the fixture would pass while proving nothing. */
static void test_eval_argument_promotion(void)
{
    uint8_t b[] = {
        0x08, 'T','G','T','R', 0x0A, 0x00,     /* Name(TGTR, 0) */
        0x08, 'T','G','T','V', 0x0A, 0x00,     /* Name(TGTV, 0) */
        0x14, 0x0A, 'S','E','T','A', 0x01,
            0x70, 0x0A, 0x2A, 0x68,            /* Store(0x2A, Arg0) */
        0x14, 0x14, 'B','Y','R','F', 0x00,
            'S','E','T','A', 0x71,'T','G','T','R',   /* SETA(RefOf(TGTR)) */
            0xA4, 'T','G','T','R',                   /* Return(TGTR) */
        0x14, 0x13, 'B','Y','V','L', 0x00,
            'S','E','T','A', 'T','G','T','V',        /* SETA(TGTV) */
            0xA4, 'T','G','T','V'                    /* Return(TGTV) */
    };
    WITH_PARSE("eval: an argument passed by reference writes through", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t byrf = nth_child(root, 3);
        uint64_t byvl = nth_child(root, 4);

        aml_eval_reset(2);
        eq("SETA(RefOf(TGTR)) reached the caller's Name",
           aml_eval_method(byrf), 0x2A);
        eq("no error", aml_eval_err(), AML_OK);
        eq("frames unwound", aml_eval_frames(), 0);

        /* The control. Same callee, same body, an argument that is a VALUE
         * rather than a reference — and the caller's Name is untouched. */
        aml_eval_reset(2);
        eq("SETA(TGTV) wrote only the callee's slot",
           aml_eval_method(byvl), 0);
        eq("no error", aml_eval_err(), AML_OK);
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

/* An argument that is not an integer at all. Before #1058 aml_eval_call
 * evaluated arguments with aml_eval_node, so a Buffer argument was
 * NOT_EVALUABLE — which refuses a shape real tables use constantly, since
 * a helper taking a resource template is how _CRS is usually factored. */
static void test_eval_object_argument_and_return(void)
{
    uint8_t b[] = {
        0x14, 0x09, 'B','L','E','N', 0x01,
            0xA4, 0x87, 0x68,                  /* Return(SizeOf(Arg0)) */
        0x14, 0x12, 'B','M','A','I', 0x00,
            0xA4, 'B','L','E','N',
                0x11, 0x06, 0x0A, 0x03, 0x01, 0x02, 0x03,  /* Buffer(3){1,2,3} */
        0x14, 0x0F, 'R','B','U','F', 0x00,
            0xA4, 0x11, 0x07, 0x0A, 0x04, 0x09, 0x08, 0x07, 0x06
    };
    WITH_PARSE("eval: a Buffer survives being passed and being returned", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t bmai = nth_child(root, 1);
        uint64_t rbuf = nth_child(root, 2);

        aml_eval_reset(2);
        eq("the callee saw a Buffer of three", aml_eval_method(bmai), 3);
        eq("no error", aml_eval_err(), AML_OK);

        /* The return type. `Return(Buffer(...))` is how every _CRS ends,
         * and #1054 refused it because the retval slot had no way to say
         * the word was an object index rather than an Integer. */
        aml_eval_reset(2);
        uint64_t r = aml_eval_method(rbuf);
        eq("the return value is tagged as an object",
           aml_eval_retval_is_obj(), 1);
        eq("and it is a Buffer", aml_obj_type(r), T_BUF);
        eq("of the declared length", aml_obj_len(r), 4);
        eq("with its bytes intact", aml_obj_byte(r, 0), 0x09);
        eq("and its last byte too", aml_obj_byte(r, 3), 0x06);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* An integer-returning method must NOT set the tag, or every caller that
 * checks it would read a small integer as an arena index. The pairing is
 * one store, so this is the assertion that keeps it one store. */
static void test_eval_return_tag_is_exact(void)
{
    uint8_t b[] = {
        0x14, 0x09, 'I','N','T','M', 0x00,
            0xA4, 0x0A, 0x2A,                  /* Return(42) */
        0x14, 0x0A, 'V','O','I','D', 0x00,
            0x70, 0x0A, 0x01, 0x60             /* Store(1, Local0) — no Return */
    };
    WITH_PARSE("eval: the return tag says Integer for an Integer", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t intm = nth_child(root, 0);
        uint64_t voidm = nth_child(root, 1);

        aml_eval_reset(2);
        eq("value", aml_eval_method(intm), 42);
        eq("not tagged as an object", aml_eval_retval_is_obj(), 0);

        /* §19.6.100: falling off the end yields Zero. The tag must be
         * cleared too — otherwise the PREVIOUS invocation's object index
         * is still sitting in the slot with its tag set, and a caller
         * reads a stale Buffer as this method's answer. */
        eq("falling off the end yields Zero", aml_eval_method(voidm), 0);
        eq("and clears the tag", aml_eval_retval_is_obj(), 0);
        eq("and the retval slot itself", aml_eval_retval(), 0);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* The arity cross-check. Driven through aml_eval_arity_ok directly, and
 * that is the honest way to test it: the R30.M1 parser refuses with
 * AMBIGUOUS_CALL (21) the only tables that could make the two counts
 * disagree, so NO AML INPUT REACHES THE MISMATCH. Asserting an unreachable
 * branch through AML would mean writing a fixture that cannot fail; calling
 * the real function the real path calls, with a mismatched pair, tests the
 * check itself. */
static void test_eval_arity_cross_check(void)
{
    uint8_t b[] = {
        0x14, 0x08, 'O','N','E','A', 0x01,
            0xA4, 0x68,                        /* Return(Arg0) */
        0x14, 0x08, 'T','W','O','A', 0x02,
            0xA4, 0x68,                        /* Return(Arg0) */
        0x14, 0x0D, 'C','A','L','1', 0x00,
            0xA4, 'O','N','E','A', 0x0A, 0x05  /* Return(ONEA(5)) */
    };
    WITH_PARSE("eval: a call's arity is checked against the declaration", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t onea = nth_child(root, 0);
        uint64_t twoa = nth_child(root, 1);
        uint64_t cal1 = nth_child(root, 2);
        uint64_t ret  = aml_node_first_child(cal1);
        uint64_t call = aml_node_first_child(ret);
        eq("the call node", aml_node_kind(call), N_CALL);
        eq("declared arities differ", aml_method_argcount(onea), 1);
        eq("as they must for this to test anything",
           aml_method_argcount(twoa), 2);

        aml_eval_reset(2);
        eq("agreement passes", aml_eval_arity_ok(call, onea), 1);
        eq("and latches nothing", aml_eval_err(), AML_OK);

        aml_eval_reset(2);
        eq("disagreement is refused", aml_eval_arity_ok(call, twoa), 0);
        eq("ARG_COUNT latched", aml_eval_err(), E_ARG_COUNT);

        /* and the happy path still runs end to end */
        aml_eval_reset(2);
        eq("the call itself evaluates", aml_eval_method(cal1), 5);
        eq("no error", aml_eval_err(), AML_OK);
    });
}

/* =====================================================================
 * R30.M2-006 (#1059) — Notify.
 * ===================================================================== */

static void test_notify_target_table(void)
{
    g_case = "notify: the notifiable kinds are exactly three";
    /* §19.6.85 names Device, Processor and ThermalZone and the list is
     * closed. Asserted as a table in BOTH directions, because the failure
     * mode of a too-permissive list is an event the supervisor enqueues
     * and can only drop later, at a point with no context left to say
     * which table produced it. */
    static const uint64_t ok[]  = { 3, 7, 9 };
    static const uint64_t objt[] = { 6, 12, 13 };
    for (size_t i = 0; i < 3; i++) {
        eq("notifiable", aml_ctl_notify_kind_ok(ok[i]), 1);
        eq("and reports the spec's ObjectType",
           aml_ctl_notify_objtype(ok[i]), objt[i]);
    }
    static const uint64_t no[] = { 0, 1, 2, 4, 5, 6, 8, 10, 11, 14, 17, 18, 23, 24, 38 };
    for (size_t i = 0; i < sizeof no / sizeof no[0]; i++) {
        eq("not notifiable", aml_ctl_notify_kind_ok(no[i]), 0);
        eq("and has no ObjectType to report",
           aml_ctl_notify_objtype(no[i]), 0);
    }
}

/* The happy path, and the accounting identity that makes the ring's
 * bounded loss reasonable about. */
static void test_notify_delivery(void)
{
    uint8_t b[] = {
        0x5B, 0x82, 0x05, 'D','E','V','0',     /* Device(DEV0) {} */
        0x14, 0x0D, 'N','T','F','Y', 0x00,
            0x86, 'D','E','V','0', 0x0A, 0x80  /* Notify(DEV0, 0x80) */
    };
    WITH_PARSE("notify: a delivered notification carries node, value and type", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t dev0 = nth_child(root, 0);
        uint64_t ntfy = nth_child(root, 1);
        eq("the device", aml_node_kind(dev0), 3);

        aml_notify_reset();
        aml_eval_reset(2);
        uint64_t fuel_before = aml_eval_fuel();
        eq("the method completes", aml_eval_method(ntfy), 0);
        eq("no error", aml_eval_err(), AML_OK);
        eq("one notification pending", aml_notify_depth(), 1);
        eq("none dropped", aml_notify_drops(), 0);
        eq("one offered", aml_notify_offered(), 1);
        eq("none drained yet", aml_notify_drained(), 0);

        /* Delivery spends fuel. If it did not, a Notify storm would be the
         * one construct a firmware table could run for free. */
        g_checks++;
        if (aml_eval_fuel() >= fuel_before)
            fail("Notify delivery spent no fuel");

        /* AND IT SPENT EXACTLY ONE STEP OF ITS OWN. Measured on
         * aml_notify_enqueue directly, because Notify's two operands
         * evaluate through aml_eval_obj and spend their own — a
         * before-and-after across the whole statement cannot tell an
         * enqueue that charges from one riding for free, and a mutant
         * that deleted the spend survived the coarse check above. Same
         * lesson as #1057's object dispatcher: measure the leaf. */
        aml_notify_reset();
        aml_eval_reset(2);
        uint64_t f0 = aml_eval_fuel();
        eq("accepted", aml_notify_enqueue(dev0, 0x81, 6), 1);
        eq("and it cost exactly one step", f0 - aml_eval_fuel(), 1);

        /* The DROPPED path costs the same. If it were cheaper, filling the
         * ring would be the way to make a Notify storm free. */
        for (int i = 0; i < 31; i++)
            eq("accepted", aml_notify_enqueue(dev0, 0x01, 6), 1);
        eq("the ring is full", aml_notify_depth(), 32);
        uint64_t f1 = aml_eval_fuel();
        eq("refused", aml_notify_enqueue(dev0, 0x01, 6), 0);
        eq("and a drop costs exactly one step too", f1 - aml_eval_fuel(), 1);
        eq("counted", aml_notify_drops(), 1);
        eq("and it did NOT latch — a drop is an event, not a fault",
           aml_eval_err(), AML_OK);

        aml_notify_reset();
        aml_eval_reset(2);
        eq("the method completes again", aml_eval_method(ntfy), 0);

        eq("sequence 0 — the first offer", aml_notify_peek(0), 0);
        eq("the target node", aml_notify_peek(1), dev0);
        eq("the notification value", aml_notify_peek(2), 0x80);
        eq("the ObjectType, not the arena kind", aml_notify_peek(3), 6);
        eq("field 4 does not exist", aml_notify_peek(4), 0);

        eq("popped", aml_notify_pop(), 1);
        eq("ring empty", aml_notify_depth(), 0);
        eq("one drained", aml_notify_drained(), 1);
        eq("popping an empty ring is a poll, not an error",
           aml_notify_pop(), 0);
        eq("and latches nothing", aml_eval_err(), AML_OK);

        /* THE ACCOUNTING IDENTITY. Everything offered went exactly one of
         * three places, and this is what makes "no event went anywhere
         * unaccounted" checkable rather than claimed. */
        eq("offered == drained + depth + drops",
           aml_notify_offered(),
           aml_notify_drained() + aml_notify_depth() + aml_notify_drops());

        /* The ring is NOT cleared by a new evaluation session — it belongs
         * to the supervisor, not to the invocation. */
        aml_eval_reset(2);
        eq("a new session does not discard the counters",
           aml_notify_offered(), 1);
    });
}

/* Two failure edges, and they are DIFFERENT failures. The first is caught
 * by the conversion table (want REFERENCE, cast refuses an Integer); the
 * second by Notify itself, because the table can say "a reference" but not
 * "a reference to a Device". */
static void test_notify_refusals(void)
{
    uint8_t b[] = {
        0x5B, 0x82, 0x05, 'D','E','V','0',
        0x5B, 0x01, 'M','U','T','X', 0x00,     /* Mutex(MUTX, 0) */
        0x14, 0x0B, 'N','I','N','T', 0x00,
            0x86, 0x0A, 0x05, 0x0A, 0x80,      /* Notify(5, 0x80) */
        0x14, 0x0D, 'N','M','U','X', 0x00,
            0x86, 'M','U','T','X', 0x0A, 0x80, /* Notify(MUTX, 0x80) */
        0x14, 0x0D, 'N','O','K','_', 0x00,
            0x86, 'D','E','V','0', 0x0A, 0x81
    };
    WITH_PARSE("notify: a non-reference and a wrong-kind target fail differently", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t nint = nth_child(root, 2);
        uint64_t nmux = nth_child(root, 3);
        uint64_t nok  = nth_child(root, 4);

        /* (1) Not a reference at all. Refused by aml_conv_cast, driven by
         * the table row for 0x86 — Notify's body has no type test. */
        aml_notify_reset();
        aml_eval_reset(2);
        eq("refused", aml_eval_method(nint), 0);
        eq("BAD_REF, from the conversion table", aml_eval_err(), E_BAD_REF);
        eq("nothing was enqueued", aml_notify_offered(), 0);

        /* (2) A perfectly good reference to something that cannot be
         * notified. The table cannot express this; Notify can. */
        aml_notify_reset();
        aml_eval_reset(2);
        eq("refused", aml_eval_method(nmux), 0);
        eq("BAD_NOTIFY_TARGET", aml_eval_err(), E_BAD_NOTIFY_TARGET);
        eq("nothing was enqueued", aml_notify_offered(), 0);

        /* (3) Notify is a Type1Opcode — a STATEMENT. In value position it
         * is a refusal and not a plausible zero, which is what stops
         * `Store(Notify(D,1), X)` from looking like it worked. */
        aml_notify_reset();
        aml_eval_reset(2);
        uint64_t expr = aml_node_first_child(nok);
        eq("the Notify node", aml_node_kind(expr), N_EXPR);
        eq("it has no value", aml_eval_obj(expr), 0);
        eq("NOT_EVALUABLE", aml_eval_err(), E_NOT_EVALUABLE);
        eq("and it was not delivered as a side effect",
           aml_notify_offered(), 0);

        /* and the same node in statement position works */
        aml_notify_reset();
        aml_eval_reset(2);
        eq("delivered", aml_eval_method(nok), 0);
        eq("no error", aml_eval_err(), AML_OK);
        eq("one offered", aml_notify_offered(), 1);
        eq("value 0x81", aml_notify_peek(2), 0x81);
    });
}

/* THE RING UNDER LOAD. Forty notifications into a thirty-two-deep ring:
 * the evaluator must not block, must not fail, must deliver the first
 * thirty-two, and must COUNT the eight it refused.
 *
 * The 60-second watchdog is what makes a regression here visible rather
 * than a hang — an implementation that waited for a drainer would stop
 * dead at the thirty-third and this fixture would time out instead of
 * failing an assertion. */
static void test_notify_ring_drops(void)
{
    uint8_t b[] = {
        0x5B, 0x82, 0x05, 'D','E','V','0',
        0x14, 0x1A, 'N','S','T','M', 0x00,
            0x70, 0x00, 0x60,                  /* Store(Zero, Local0) */
            0xA2, 0x0E,                        /* While ( */
                0x95, 0x60, 0x0A, 0x28,        /*   LLess(Local0, 40) ) { */
                0x86, 'D','E','V','0', 0x0A, 0x80,
                0x75, 0x60,                    /*   Increment(Local0) } */
            0xA4, 0x60                         /* Return(Local0) */
    };
    WITH_PARSE("notify: a full ring drops, counts, and does not block", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t nstm = nth_child(root, 1);

        aml_notify_reset();
        aml_eval_reset(2);
        eq("the loop ran to completion", aml_eval_method(nstm), 40);
        eq("a dropped notification is NOT an error", aml_eval_err(), AML_OK);
        eq("the ring is full", aml_notify_depth(), 32);
        eq("eight were refused", aml_notify_drops(), 8);
        eq("forty were offered", aml_notify_offered(), 40);
        eq("offered == drained + depth + drops",
           aml_notify_offered(),
           aml_notify_drained() + aml_notify_depth() + aml_notify_drops());

        /* TAIL-DROP, not overwrite-oldest: what survived is the OLDEST
         * thirty-two, with contiguous sequence numbers 0..31. Under
         * overwrite-oldest the survivors would be 8..39, and the eject
         * request the user pressed at sequence 0 would be the one lost. */
        for (uint64_t i = 0; i < 32; i++) {
            eq("the oldest survived, in order", aml_notify_peek(0), i);
            eq("with its value", aml_notify_peek(2), 0x80);
            eq("and its target type", aml_notify_peek(3), 6);
            eq("popped", aml_notify_pop(), 1);
        }
        eq("drained", aml_notify_drained(), 32);
        eq("empty", aml_notify_depth(), 0);
        eq("the drop count survives the drain", aml_notify_drops(), 8);
        eq("identity still holds",
           aml_notify_offered(),
           aml_notify_drained() + aml_notify_depth() + aml_notify_drops());
    });
}

/* The unbounded case. `While(One) { Notify(...) }` is legal AML and the
 * ring cannot save it — only the fuel budget can, and it must, WITHOUT
 * the ring having blocked on the way. */
static void test_notify_unbounded_loop_terminates(void)
{
    uint8_t b[] = {
        0x5B, 0x82, 0x05, 'D','E','V','0',
        0x14, 0x12, 'N','I','N','F', 0x00,
            0xA2, 0x09,                        /* While ( */
                0x01,                          /*   One ) { */
                0x86, 'D','E','V','0', 0x0A, 0x80,   /*   Notify(DEV0, 0x80) } */
            0xA4, 0x00
    };
    WITH_PARSE("notify: an unbounded Notify loop ends on fuel, not on a block", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t ninf = nth_child(root, 1);

        aml_notify_reset();
        aml_eval_reset(2);
        eq("a tighter budget", aml_eval_set_fuel(300), 300);
        eq("no value", aml_eval_method(ninf), 0);
        eq("fuel, not a hang and not the object arena",
           aml_eval_err(), E_FUEL_EXHAUSTED);
        eq("fuel really is gone", aml_eval_fuel(), 0);
        eq("the ring filled", aml_notify_depth(), 32);
        g_checks++;
        if (aml_notify_drops() == 0)
            fail("the loop never overran the ring — the bound proves nothing");
        eq("identity holds even on the error path",
           aml_notify_offered(),
           aml_notify_drained() + aml_notify_depth() + aml_notify_drops());
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

/* =====================================================================
 * R30.M2-007 (#1060) — serialized methods.
 * ===================================================================== */

/* The acquire count, driven directly. This is where the RECURSIVE part of
 * the recursive mutex is pinned: three acquires of one method give a count
 * of three and ONE held entry, and the two numbers are asserted separately
 * because an implementation that leaked an entry per acquire would still
 * balance the count. */
static void test_serialized_acquire_balance(void)
{
    uint8_t b[] = {
        0x14, 0x08, 'S','R','L','0', 0x08,     /* Method(SRL0, 0, Serialized, 0) */
            0xA4, 0x00,
        0x14, 0x08, 'S','R','L','5', 0x58,     /* Method(SRL5, 0, Serialized, 5) */
            0xA4, 0x00
    };
    WITH_PARSE("serialized: the acquisition count balances across nesting", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t s0 = nth_child(root, 0);
        uint64_t s5 = nth_child(root, 1);
        eq("SRL0 is serialized", aml_method_serialized(s0), 1);
        eq("at level 0", aml_method_synclevel(s0), 0);
        eq("SRL5 is serialized", aml_method_serialized(s5), 1);
        eq("at level 5", aml_method_synclevel(s5), 5);
        eq("and neither takes arguments", aml_method_argcount(s5), 0);

        aml_eval_reset(2);
        eq("nothing held to start", aml_ctl_held(), 0);
        eq("level 0", aml_ctl_level(), 0);

        eq("first acquire", aml_ctl_acquire(s0), 1);
        eq("count 1", aml_ctl_count_of(s0), 1);
        eq("one entry", aml_ctl_held(), 1);
        eq("re-entry by the owner SUCCEEDS", aml_ctl_acquire(s0), 1);
        eq("count 2", aml_ctl_count_of(s0), 2);
        eq("still ONE entry", aml_ctl_held(), 1);
        eq("and again", aml_ctl_acquire(s0), 1);
        eq("count 3", aml_ctl_count_of(s0), 3);
        eq("three acquisitions recorded", aml_ctl_acquires(), 3);
        eq("no error anywhere", aml_eval_err(), AML_OK);

        eq("release", aml_ctl_release(s0), 1);
        eq("count 2", aml_ctl_count_of(s0), 2);
        eq("still held", aml_ctl_held(), 1);
        eq("release", aml_ctl_release(s0), 1);
        eq("release", aml_ctl_release(s0), 1);
        eq("count 0", aml_ctl_count_of(s0), 0);
        eq("entry freed", aml_ctl_held(), 0);
        eq("level restored", aml_ctl_level(), 0);
        eq("releasing what is not held is a silent 0",
           aml_ctl_release(s0), 0);
        eq("and does NOT latch — it is called on error paths",
           aml_eval_err(), AML_OK);

        /* Two distinct methods, acquired upward: two entries, and the
         * level tracks the highest held and is RESTORED, not recomputed. */
        aml_eval_reset(2);
        eq("low first", aml_ctl_acquire(s0), 1);
        eq("level 0", aml_ctl_level(), 0);
        eq("then high", aml_ctl_acquire(s5), 1);
        eq("level 5", aml_ctl_level(), 5);
        eq("two entries", aml_ctl_held(), 2);
        eq("release the high one", aml_ctl_release(s5), 1);
        eq("the level it displaced comes back", aml_ctl_level(), 0);
        eq("release the low one", aml_ctl_release(s0), 1);
        eq("nothing held", aml_ctl_held(), 0);
        eq("no error", aml_eval_err(), AML_OK);

        /* #1581 — the context id is now a real per-evaluation identity
         * (monotonic counter, 0 reserved for "no session yet minted").
         * aml_eval_reset above minted a fresh id, so the value here is
         * nonzero. Its numeric value depends on how many prior tests
         * have called reset, so we assert the property that matters
         * (a valid id was minted) rather than the numeric value. The
         * contention arm itself is reached by
         * test_serialized_contention_across_contexts below. */
        eq("a valid execution context is minted", aml_ctl_ctx() != 0, 1);
    });
}

/* #1581 — REACH THE CONTENTION ARM.
 *
 * Before #1581 aml_ctl_ctx returned the constant 1, so aml_ctl_acquire's
 * `owner != ctx` branch was unreachable from any input and the
 * AML_ERR_MUTEX_CONTENTION (54) code was documented as "refused rather
 * than faked". This fixture reaches it: it acquires a serialized method's
 * implicit mutex under context A, rotates the identity to context B via
 * aml_ctl_ctx_alloc (which does NOT touch the pool, deliberately), and
 * attempts the acquire again. The pool now holds a slot whose owner is A;
 * the running context is B; the comparison at aml_ma_again falls to
 * aml_ma_contend and latches E_MUTEX_CONTENTION. Then it rotates BACK
 * to A and asserts the re-entry succeeds again -- so the failure mode
 * is a genuine owner comparison and not, e.g., a stray always-refuse. */
static void test_serialized_contention_across_contexts(void)
{
    uint8_t b[] = {
        0x14, 0x08, 'S','R','L','C', 0x18,     /* Method(SRLC, 0, Serialized, 1) */
            0xA4, 0x00
    };
    WITH_PARSE("serialized: two contexts contend on one mutex", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t srlc = nth_child(root, 0);
        eq("SRLC is serialized", aml_method_serialized(srlc), 1);

        aml_eval_reset(2);
        uint64_t ctx_a = aml_ctl_ctx();
        eq("session has a valid context id", ctx_a != 0, 1);

        eq("A acquires the mutex", aml_ctl_acquire(srlc), 1);
        eq("count 1 under A", aml_ctl_count_of(srlc), 1);
        eq("one entry held", aml_ctl_held(), 1);
        eq("no error", aml_eval_err(), AML_OK);

        /* Rotate to a fresh context WITHOUT wiping the pool. */
        uint64_t ctx_b = aml_ctl_ctx_alloc();
        eq("ctx_b is a valid id", ctx_b != 0, 1);
        eq("ctx_b differs from ctx_a", ctx_b != ctx_a, 1);

        /* Now B tries to acquire the mutex A holds. The owner field on
         * the pool slot names A; the running context is B; the acquire
         * MUST refuse with MUTEX_CONTENTION rather than either grant a
         * silent parallel acquire or hang. */
        eq("B is refused the acquire", aml_ctl_acquire(srlc), 0);
        eq("with MUTEX_CONTENTION latched", aml_eval_err(),
           E_MUTEX_CONTENTION);
        eq("the entry is still held by A, count unchanged",
           aml_ctl_count_of(srlc), 1);
        eq("still one entry", aml_ctl_held(), 1);

        /* Prove the refusal was really the owner comparison and not an
         * always-refuse latched by the error slot: rotate to yet another
         * fresh context and confirm it is ALSO refused. aml_ctl_ctx_alloc
         * is the only public writer of the counter, so we cannot re-mint
         * A's id to prove positive re-acquisition; the two-refusals shape
         * (B refused, C refused, same slot still held) rules out the
         * "always refuse after first miss" and "MUTEX_CONTENTION was a
         * one-shot bit" failure modes. */
        uint64_t ctx_c = aml_ctl_ctx_alloc();
        eq("ctx_c differs from ctx_b", ctx_c != ctx_b, 1);
        eq("ctx_c differs from ctx_a", ctx_c != ctx_a, 1);
        eq("C is also refused (owner comparison, not a one-shot fluke)",
           aml_ctl_acquire(srlc), 0);
        eq("still MUTEX_CONTENTION", aml_eval_err(), E_MUTEX_CONTENTION);
        eq("pool unchanged", aml_ctl_held(), 1);
        eq("count still 1", aml_ctl_count_of(srlc), 1);

        /* Malformed-input taxonomy: node = 0 is the same shape as every
         * other pool operation, refused as a distinct outcome that does
         * NOT touch the pool. It must also NOT overwrite the latched
         * contention error -- first-writer-wins is what makes the
         * contention diagnosis survive an incidental follow-up. */
        eq("node 0 is refused", aml_ctl_acquire(0), 0);
        eq("MUTEX_CONTENTION still the latched code (first-writer-wins)",
           aml_eval_err(), E_MUTEX_CONTENTION);
        eq("pool truly unchanged", aml_ctl_held(), 1);
    });
}

/* THE ANTI-DEADLOCK FIXTURE. A serialized method that calls itself must
 * RUN. Under a test-and-set mutex this hangs, and the 60-second watchdog
 * — not an assertion — is what makes that visible. */
static void test_serialized_recursion_does_not_deadlock(void)
{
    uint8_t b[] = {
        0x14, 0x19, 'S','R','E','C', 0x09,     /* Method(SREC, 1, Serialized, 0) */
            0xA0, 0x06, 0x93, 0x68, 0x00, 0xA4, 0x00,  /* If(Arg0==0){Return(0)} */
            0xA4, 0x72, 0x68,                  /* Return(Add(Arg0, */
                'S','R','E','C', 0x74, 0x68, 0x01, 0x00,  /*  SREC(Arg0-1), */
                0x00,                          /*                  Zero)) */
        0x14, 0x0D, 'S','M','A','I', 0x00,
            0xA4, 'S','R','E','C', 0x0A, 0x03  /* Return(SREC(3)) */
    };
    WITH_PARSE("serialized: a serialized method may call itself", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t srec = nth_child(root, 0);
        uint64_t smai = nth_child(root, 1);
        eq("SREC is serialized", aml_method_serialized(srec), 1);
        eq("with one argument", aml_method_argcount(srec), 1);

        aml_eval_reset(2);
        eq("3 + 2 + 1 + 0", aml_eval_method(smai), 6);
        eq("no error — and, above all, no hang", aml_eval_err(), AML_OK);
        eq("four entries into SREC, four acquisitions",
           aml_ctl_acquires(), 4);
        eq("all released", aml_ctl_held(), 0);
        eq("count back to zero", aml_ctl_count_of(srec), 0);
        eq("level back to zero", aml_ctl_level(), 0);
        eq("frames unwound", aml_eval_frames(), 0);
    });
}

/* Unbounded serialized recursion. It must end the same way unbounded
 * NON-serialized recursion does — on the frame pool — and it must not
 * leak the mutex on the way out. The leak is the interesting half: a
 * release wired only to the success path would leave SINF permanently
 * held, and every later acquire in the session would then be refused on
 * SyncLevel grounds for reasons nothing in the error would explain. */
static void test_serialized_recursion_is_still_bounded(void)
{
    uint8_t b[] = {
        0x14, 0x0A, 'S','I','N','F', 0x08,
            'S','I','N','F'
    };
    WITH_PARSE("serialized: unbounded recursion trips the frame pool, not a leak", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t sinf = nth_child(root, 0);
        uint64_t leaked_before = aml_ctl_leaked();

        aml_eval_reset(2);
        eq("no value", aml_eval_method(sinf), 0);
        eq("frames, not fuel and not a hang",
           aml_eval_err(), E_FRAME_OVERFLOW);
        g_checks++;
        if (aml_eval_fuel() == 0)
            fail("fuel was exhausted too — the frame cap is not what fired");
        eq("frames unwound", aml_eval_frames(), 0);
        /* eight frames, plus the ninth call that acquired and then could
         * not get a frame — and released again on its way out */
        eq("nine acquisitions", aml_ctl_acquires(), 9);
        eq("nothing still held", aml_ctl_held(), 0);
        eq("level back to zero", aml_ctl_level(), 0);

        /* the leak detector agrees, which is what makes it worth having */
        aml_eval_reset(2);
        eq("no leak was recorded", aml_ctl_leaked(), leaked_before);
    });
}

/* SyncLevel ordering — §19.6.2. Acquiring DOWNWARD is the error; acquiring
 * upward is fine. Both directions are asserted, because a check that
 * refused everything would pass a one-sided test. */
static void test_serialized_sync_level_ordering(void)
{
    uint8_t b[] = {
        0x14, 0x08, 'S','L','L','O', 0x28,     /* Method(SLLO,0,Serialized,2){Return(1)} */
            0xA4, 0x01,
        0x14, 0x0B, 'S','L','H','I', 0x78,     /* Method(SLHI,0,Serialized,7){Return(SLLO())} */
            0xA4, 'S','L','L','O',
        0x14, 0x09, 'S','L','T','P', 0x78,     /* Method(SLTP,0,Serialized,7){Return(42)} */
            0xA4, 0x0A, 0x2A,
        0x14, 0x0B, 'S','L','U','P', 0x28,     /* Method(SLUP,0,Serialized,2){Return(SLTP())} */
            0xA4, 'S','L','T','P'
    };
    WITH_PARSE("serialized: SyncLevel orders acquisition, downward is an error", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t sllo = nth_child(root, 0);
        uint64_t slhi = nth_child(root, 1);
        uint64_t sltp = nth_child(root, 2);
        uint64_t slup = nth_child(root, 3);
        eq("SLLO at 2", aml_method_synclevel(sllo), 2);
        eq("SLHI at 7", aml_method_synclevel(slhi), 7);
        eq("SLTP at 7", aml_method_synclevel(sltp), 7);
        eq("SLUP at 2", aml_method_synclevel(slup), 2);

        /* 7 then 2 — downward. A table that does this has not established
         * its own deadlock-freedom, and running it anyway is choosing to
         * find that out on hardware. */
        aml_eval_reset(2);
        eq("refused", aml_eval_method(slhi), 0);
        eq("SYNC_LEVEL", aml_eval_err(), E_SYNC_LEVEL);
        eq("the outer method's mutex was still released",
           aml_ctl_held(), 0);
        eq("level back to zero", aml_ctl_level(), 0);
        eq("frames unwound", aml_eval_frames(), 0);

        /* 2 then 7 — upward, and legal. Without this half, a check that
         * simply refused every nested acquire would pass. */
        aml_eval_reset(2);
        eq("permitted", aml_eval_method(slup), 42);
        eq("no error", aml_eval_err(), AML_OK);
        eq("both released", aml_ctl_held(), 0);
        eq("level back to zero", aml_ctl_level(), 0);
        eq("two acquisitions", aml_ctl_acquires(), 2);
    });
}

/* The pool bound, and the leak detector. Both are driven through the API:
 * the pool cannot overflow through AML, because a mutex is held only while
 * its method is on the stack and aml_frame_push refuses a ninth frame
 * first. The bound is still checked, because "unreachable" is a property
 * of today's frame count and a pool that indexed past its end when that
 * changed would corrupt the notification ring next door. */
static void test_serialized_pool_bound_and_leak_detection(void)
{
    uint8_t b[64];
    size_t n = 0;
    for (int i = 0; i < 9; i++) {
        b[n++] = 0x08;                          /* Name(Xnnn, 0) */
        b[n++] = 'X';
        b[n++] = (uint8_t)('0' + i);
        b[n++] = '_';
        b[n++] = '_';
        b[n++] = 0x0A;
        b[n++] = 0x00;
    }
    WITH_PARSE("serialized: the mutex pool is bounded and a leak is detected", b, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t nodes[9];
        for (int i = 0; i < 9; i++) {
            nodes[i] = nth_child(root, i);
            eq("a Name node", aml_node_kind(nodes[i]), N_NAME);
        }

        aml_eval_reset(2);
        for (int i = 0; i < 8; i++)
            eq("acquired", aml_ctl_acquire(nodes[i]), 1);
        eq("eight held", aml_ctl_held(), 8);
        eq("no error at eight", aml_eval_err(), AML_OK);
        eq("the ninth is refused", aml_ctl_acquire(nodes[8]), 0);
        eq("MUTEX_POOL_FULL", aml_eval_err(), E_MUTEX_POOL_FULL);
        eq("and the refusal changed nothing", aml_ctl_held(), 8);

        /* Now walk away without releasing. The next session must recover
         * — a wedged pool would refuse correct acquires forever — and must
         * COUNT what it recovered, because silent recovery is how a broken
         * acquire/release pairing survives review. */
        uint64_t leaked_before = aml_ctl_leaked();
        aml_eval_reset(2);
        eq("the pool was forced clean", aml_ctl_held(), 0);
        eq("the level with it", aml_ctl_level(), 0);
        eq("and all eight leaks were counted",
           aml_ctl_leaked(), leaked_before + 8);
        eq("a fresh acquire works again", aml_ctl_acquire(nodes[0]), 1);
        eq("no error", aml_eval_err(), AML_OK);
        aml_ctl_release(nodes[0]);
        eq("balanced", aml_ctl_held(), 0);
    });
}

/* =====================================================================
 * R30.M3-002 (#1062) — the SystemMemory address-space handler.
 *
 * This is the first section of this corpus whose subject can touch
 * memory outside its own arenas, so it is also the first that needs a
 * SECOND guarded mapping: one for the AML fixture (guard_load, as
 * everywhere above) and one for the region's synthetic BACKING STORE.
 *
 * The backing store is placed so its LAST BYTE is the last byte of a
 * mapped page, with the following page PROT_NONE. Every claim about
 * clipping in this section therefore has teeth: an access one byte past
 * the end of a region whose declared length equals the buffer is a hard
 * SIGSEGV rather than a read of whatever follows. A missing bounds check
 * cannot pass by returning a plausible number.
 *
 * NO FIXTURE HERE NAMES A REAL PHYSICAL ADDRESS. That is not a
 * limitation of the corpus, it is the mapping/access split working: the
 * handler's bounds arithmetic, access-width selection and
 * read-modify-write all operate on a binding, and the binding's host
 * address is supplied by the mapping step. Pointing that step at a
 * malloc'd page instead of at mapped device memory changes no line of
 * the code under test.
 * ===================================================================== */

static uint8_t *g_bmap;
static size_t   g_bmaplen;

static uint8_t *backing_load(const uint8_t *data, size_t n)
{
    long ps = sysconf(_SC_PAGESIZE);
    size_t need = ((n + (size_t)ps - 1) / (size_t)ps) * (size_t)ps;
    if (need == 0) need = (size_t)ps;
    g_bmaplen = need + (size_t)ps;
    g_bmap = mmap(NULL, g_bmaplen, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g_bmap == MAP_FAILED) { perror("mmap"); exit(2); }
    if (mprotect(g_bmap + need, (size_t)ps, PROT_NONE) != 0) {
        perror("mprotect"); exit(2);
    }
    uint8_t *p = g_bmap + need - n;
    if (n && data) memcpy(p, data, n);
    else if (n) memset(p, 0, n);
    return p;
}

static void backing_free(void)
{
    if (g_bmap) munmap(g_bmap, g_bmaplen);
    g_bmap = NULL;
}

/* OperationRegion(RGN0, SystemMemory, 0x1000, 0x40)
 * Field(RGN0, ByteAcc, NoLock, Preserve) { FLDA, 8, FLDB, 8 } */
static const uint8_t k_rgn0[] = {
    0x5B, 0x80, 'R','G','N','0', 0x00, 0x0B, 0x00, 0x10, 0x0A, 0x40,
    0x5B, 0x81, 0x10, 'R','G','N','0', 0x01,
        'F','L','D','A', 0x08,
        'F','L','D','B', 0x08
};

/* THE HEADLINE SECURITY FIXTURE.
 *
 * A DSDT is vendor-supplied and unsigned. It can declare an
 * OperationRegion at any 64-bit address it likes, including one the
 * supervisor holds no capability over at all. That must be refused, and
 * it must be refused BEFORE any address is formed. */
static void test_region_refused_without_a_capability(void)
{
    WITH_PARSE("region: no covering capability at all is REFUSED", k_rgn0, sizeof k_rgn0, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn = nth_child(root, 0);
        uint64_t fld = nth_child(root, 1);
        eq("a region", aml_node_kind(rgn), N_OPREGION);
        eq("SystemMemory", aml_node_flags(rgn), 0);
        eq("declared at 0x1000", aml_u64_get(aml_node_arg0(rgn)), 0x1000);
        eq("for 0x40 bytes", aml_u64_get(aml_node_arg1(rgn)), 0x40);
        uint64_t flda = nth_child(fld, 0);
        eq("a field element", aml_node_kind(flda), N_FIELD_ELEM);

        uint8_t *back = backing_load(NULL, 0x40);

        /* A capability handle of zero is "I hold nothing". */
        aml_eval_reset(2);
        aml_region_reset();
        eq("nothing bound", aml_region_count(), 0);
        eq("no cap -> refused", aml_region_bind(rgn, 0, 0x1000, 0x40,
                                                (uint64_t)(uintptr_t)back), 0);
        eq("NO_CAP", aml_eval_err(), E_REGION_NO_CAP);
        eq("still nothing bound", aml_region_count(), 0);
        eq("and the refusal was counted", aml_region_refusals(), 1);

        /* A zero-length window is the same thing said differently: a
         * capability that covers nothing covers this region no better
         * than no capability at all. */
        aml_eval_reset(2);
        eq("empty window -> refused", aml_region_bind(rgn, 7, 0x1000, 0,
                                                      (uint64_t)(uintptr_t)back), 0);
        eq("NO_CAP", aml_eval_err(), E_REGION_NO_CAP);

        /* And a window that was never mapped. */
        aml_eval_reset(2);
        eq("unmapped window -> refused", aml_region_bind(rgn, 7, 0x1000, 0x40, 0), 0);
        eq("NO_CAP", aml_eval_err(), E_REGION_NO_CAP);
        eq("three refusals", aml_region_refusals(), 3);
        eq("and after all three, nothing is bound", aml_region_count(), 0);

        /* THE CONSEQUENCE, which is the part that actually matters: with
         * no binding, a field access is refused and NO READ HAPPENS. An
         * implementation that fell back to the declared address would
         * dereference 0x1000. */
        aml_eval_reset(2);
        eq("no binding", aml_region_field_binding(flda), 0);
        eq("UNBOUND", aml_eval_err(), E_REGION_UNBOUND);
        aml_eval_reset(2);
        eq("field read refused", aml_region_field_read(flda), 0);
        eq("UNBOUND", aml_eval_err(), E_REGION_UNBOUND);
        eq("and NOTHING was read", aml_region_accesses(), 0);
        aml_eval_reset(2);
        eq("field store refused", aml_region_field_store(flda, 0xFF), 0);
        eq("UNBOUND", aml_eval_err(), E_REGION_UNBOUND);
        eq("and NOTHING was written", aml_region_accesses(), 0);

        backing_free();
    });
}

/* Refusal, never truncation. A region larger than its backing capability
 * is refused whole; it is NOT clipped to the covered part. */
static void test_region_refused_beyond_its_capability(void)
{
    WITH_PARSE("region: a range beyond the capability is REFUSED, not clipped",
               k_rgn0, sizeof k_rgn0, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn = nth_child(root, 0);
        uint8_t *back = backing_load(NULL, 0x140);

        /* The window is half the region. */
        aml_eval_reset(2);
        aml_region_reset();
        eq("short window -> refused", aml_region_bind(rgn, 7, 0x1000, 0x20,
                                                      (uint64_t)(uintptr_t)back), 0);
        eq("NOT_COVERED", aml_eval_err(), E_REGION_NOT_COVERED);
        eq("NOTHING was bound -- not even the covered half",
           aml_region_count(), 0);

        /* The window starts above the region. */
        aml_eval_reset(2);
        eq("window above -> refused", aml_region_bind(rgn, 7, 0x1010, 0x40,
                                                      (uint64_t)(uintptr_t)back), 0);
        eq("NOT_COVERED", aml_eval_err(), E_REGION_NOT_COVERED);
        eq("nothing bound", aml_region_count(), 0);

        /* A COVERING window, offset from the region: the binding must
         * record the region's own extent, unclipped and unextended, and
         * the host address must be the window's host address plus the
         * region's offset INTO the window. Getting that offset wrong is
         * the quiet way to read the right number of bytes from the wrong
         * place. */
        aml_eval_reset(2);
        uint64_t b = aml_region_bind(rgn, 7, 0x0F00, 0x140,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("a covering window was refused");
        eq("no error", aml_eval_err(), AML_OK);
        eq("one binding", aml_region_count(), 1);
        eq("the region's own base", aml_region_base(b), 0x1000);
        eq("the region's own length, unclipped", aml_region_len(b), 0x40);
        eq("the capability is recorded", aml_region_cap(b), 7);
        eq("and it is live", aml_region_row_live(b), 1);
        eq("found by node", aml_region_find(rgn), b);

        /* Prove the offset arithmetic by writing through the handler and
         * reading the raw buffer. The region starts 0x100 into the
         * window. */
        aml_eval_reset(2);
        eq("write byte 0", aml_region_write_unit(b, 0, 1, 0xC3), 1);
        g_checks++;
        if (back[0x100] != 0xC3)
            fail("region offset 0 landed at window offset %d, not 0x100",
                 (int)(back[0] == 0xC3 ? 0 : -1));
        eq("read it back", aml_region_read_unit(b, 0, 1), 0xC3);

        /* Re-binding the same region returns the SAME row rather than a
         * second one with a different window. */
        eq("re-bind is idempotent", aml_region_bind(rgn, 7, 0x0F00, 0x140,
                                                    (uint64_t)(uintptr_t)back), b);
        eq("still one binding", aml_region_count(), 1);

        backing_free();
    });
}

/* Bounds. Every access clipped to the region; a straddling access is an
 * error, not a wrap and not a partial transfer. The backing buffer abuts
 * a guard page, so a missing clip is a SIGSEGV, not a wrong answer. */
static void test_region_access_bounds(void)
{
    WITH_PARSE("region: accesses are clipped; straddling is an error",
               k_rgn0, sizeof k_rgn0, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn = nth_child(root, 0);
        uint8_t *back = backing_load(NULL, 0x40);

        aml_eval_reset(2);
        aml_region_reset();
        uint64_t b = aml_region_bind(rgn, 7, 0x1000, 0x40,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("bind failed");

        aml_eval_reset(2);
        eq("last byte is in", aml_region_bounds_ok(b, 0x3F, 1), 1);
        eq("no error", aml_eval_err(), AML_OK);

        aml_eval_reset(2);
        eq("one past the end is out", aml_region_bounds_ok(b, 0x40, 1), 0);
        eq("OOB", aml_eval_err(), E_REGION_OOB);

        /* STRADDLING. Bytes 0x3E and 0x3F are inside the region; 0x40
         * and 0x41 are not. A dword access at 0x3E is refused whole. It
         * is not narrowed to the two bytes that fit, and it does not
         * wrap. */
        aml_eval_reset(2);
        eq("a dword straddling the end is out",
           aml_region_bounds_ok(b, 0x3E, 4), 0);
        eq("OOB", aml_eval_err(), E_REGION_OOB);

        /* And the arithmetic does not wrap: an offset near 2^64 must not
         * come back into range. */
        aml_eval_reset(2);
        eq("2^64-1 does not wrap into range",
           aml_region_bounds_ok(b, 0xFFFFFFFFFFFFFFFFull, 1), 0);
        eq("OOB", aml_eval_err(), E_REGION_OOB);
        aml_eval_reset(2);
        eq("nor does 2^64-2 with a word access",
           aml_region_bounds_ok(b, 0xFFFFFFFFFFFFFFFEull, 2), 0);
        eq("OOB", aml_eval_err(), E_REGION_OOB);

        /* THE READ IS NOT PERFORMED. This is the assertion the guard
         * page backs: if the clip were missing, the read below would
         * touch the PROT_NONE page and the harness would report a
         * SIGSEGV rather than a failed comparison. */
        aml_eval_reset(2);
        uint64_t before = aml_region_accesses();
        GUARDED(eq("out-of-range read returns 0",
                   aml_region_read_unit(b, 0x40, 1), 0));
        eq("OOB", aml_eval_err(), E_REGION_OOB);
        eq("and no access was performed", aml_region_accesses(), before);
        aml_eval_reset(2);
        GUARDED(eq("out-of-range write refused",
                   aml_region_write_unit(b, 0x40, 1, 0xFF), 0));
        eq("OOB", aml_eval_err(), E_REGION_OOB);
        eq("and no access was performed", aml_region_accesses(), before);

        /* An unbound index cannot reach the arithmetic at all. */
        aml_eval_reset(2);
        eq("binding 0 is the null sentinel", aml_region_row_live(0), 0);
        eq("and is refused", aml_region_bounds_ok(0, 0, 1), 0);
        eq("UNBOUND", aml_eval_err(), E_REGION_UNBOUND);
        aml_eval_reset(2);
        eq("so is an index past the table", aml_region_bounds_ok(99, 0, 1), 0);
        eq("UNBOUND", aml_eval_err(), E_REGION_UNBOUND);

        backing_free();
    });
}

/* The containment predicate and the mask helper, driven directly. Both
 * are pure, both have an overflow edge, and both are the kind of thing a
 * refactor breaks silently. */
static void test_region_arithmetic_edges(void)
{
    g_case = "region: containment and mask arithmetic";

    eq("contained", aml_region_contains(0x1000, 0x1000, 0x1400, 0x400), 1);
    eq("exactly the window", aml_region_contains(0x1000, 0x1000, 0x1000, 0x1000), 1);
    eq("one byte past", aml_region_contains(0x1000, 0x1000, 0x1000, 0x1001), 0);
    eq("starts below", aml_region_contains(0x1000, 0x1000, 0x0FFF, 0x10), 0);
    eq("ends above", aml_region_contains(0x1000, 0x1000, 0x1FF0, 0x20), 0);
    eq("empty inner", aml_region_contains(0x1000, 0x1000, 0x1400, 0), 0);
    eq("empty outer", aml_region_contains(0x1000, 0, 0x1000, 1), 0);

    /* THE WRAP. `d_base + d_len` overflows here; the naive form reports
     * CONTAINED for a region that starts at the top of the address space
     * and runs off the end of it. */
    eq("2^64-1 + 2 does not wrap into the window",
       aml_region_contains(0, 0x2000, 0xFFFFFFFFFFFFFFFFull, 2), 0);
    eq("nor into a window at the top",
       aml_region_contains(0xFFFFFFFFFFFF0000ull, 0x10000,
                           0xFFFFFFFFFFFFFFFFull, 2), 0);
    eq("but a window at the top does contain its own last byte",
       aml_region_contains(0xFFFFFFFFFFFF0000ull, 0x10000,
                           0xFFFFFFFFFFFFFFFFull, 1), 1);

    eq("mask 0", aml_region_mask(0), 0);
    eq("mask 1", aml_region_mask(1), 1);
    eq("mask 3", aml_region_mask(3), 7);
    eq("mask 32", aml_region_mask(32), 0xFFFFFFFFull);
    eq("mask 63", aml_region_mask(63), 0x7FFFFFFFFFFFFFFFull);
    /* x86 masks the shift count to 6 bits, so the naive (1<<64)-1 is 0. */
    eq("mask 64 is all ones, not zero", aml_region_mask(64),
       0xFFFFFFFFFFFFFFFFull);

    /* #1063 / #1064 / #1065 moved this boundary. The four serviced
     * spaces and the enumerated refusal now live in
     * test_region_space_boundary; this keeps only the anchor. */
    eq("SystemMemory is serviced", aml_region_space_supported(0), 1);
    eq("SMBus is still a bus protocol, not a window",
       aml_region_space_supported(4), 0);
    eq("this module handles no opcode", aml_region_handles(0x5B80), 0);

    eq("log2 8", aml_region_acc_log(8), 3);
    eq("log2 16", aml_region_acc_log(16), 4);
    eq("log2 32", aml_region_acc_log(32), 5);
    eq("log2 64", aml_region_acc_log(64), 6);
    eq("an inadmissible width has no log", aml_region_acc_log(24), 0);
}

/* THE BIT-GRANULAR, UNALIGNED, MULTI-UNIT FIELD — read and write.
 *
 * FSP is 40 bits starting at bit 3 of a DWordAcc region: it spans two
 * dwords, is aligned to nothing, and covers neither whole unit. Its
 * neighbours (F0 below it, and the top 21 bits of the second dword above
 * it) must survive a write to it. */
static void test_region_unaligned_field_spanning_two_units(void)
{
    /* OperationRegion(RGN1, SystemMemory, 0x2000, 0x10)
     * Field(RGN1, DWordAcc, NoLock, Preserve) { F0__, 3, FSP_, 40 } */
    uint8_t b[] = {
        0x5B, 0x80, 'R','G','N','1', 0x00, 0x0B, 0x00, 0x20, 0x0A, 0x10,
        0x5B, 0x81, 0x10, 'R','G','N','1', 0x03,
            'F','0','_','_', 0x03,
            'F','S','P','_', 0x28
    };
    WITH_PARSE("region: a bit-granular unaligned field spanning two units",
               b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn = nth_child(root, 0);
        uint64_t fld = nth_child(root, 1);
        uint64_t f0  = nth_child(fld, 0);
        uint64_t fsp = nth_child(fld, 1);
        eq("DWordAcc", aml_field_access_type(fld), 3);
        eq("Preserve", aml_field_update_rule(fld), 0);
        eq("F0 at bit 0", aml_node_arg0(f0), 0);
        eq("F0 is 3 bits", aml_node_arg1(f0), 3);
        eq("FSP at bit 3", aml_node_arg0(fsp), 3);
        eq("FSP is 40 bits", aml_node_arg1(fsp), 40);
        eq("its declared width is 32", aml_region_acc_bits(fsp, SP_MEM), 32);

        static const uint8_t seed[16] = {
            0x21, 0x43, 0x65, 0x87,   /* dword0 = 0x87654321 */
            0xA9, 0xCB, 0xED, 0x0F,   /* dword1 = 0x0FEDCBA9 */
            0, 0, 0, 0, 0, 0, 0, 0
        };
        uint8_t *back = backing_load(seed, sizeof seed);

        aml_eval_reset(2);
        aml_region_reset();
        uint64_t bd = aml_region_bind(rgn, 9, 0x2000, 0x10,
                                      (uint64_t)(uintptr_t)back);
        g_checks++;
        if (bd == 0) fail("bind failed");
        eq("the region resolves from the field element",
           aml_region_of_field(fsp), rgn);
        eq("and so does its binding", aml_region_field_binding(fsp), bd);

        const uint64_t d0 = 0x87654321ull, d1 = 0x0FEDCBA9ull;

        /* READ. The expected value is computed here by an expression
         * written independently of the handler's loop -- if both were the
         * same algorithm this assertion would only prove it is
         * deterministic. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t fuel0 = aml_eval_fuel();
        uint64_t acc0  = aml_region_accesses();
        uint64_t want  = ((d0 >> 3) & ((1ull << 29) - 1))
                       | ((d1 & ((1ull << 11) - 1)) << 29);
        eq("the field reads across both units",
           aml_region_field_read(fsp), want);
        eq("no error", aml_eval_err(), AML_OK);
        eq("TWO unit accesses, one per dword",
           aml_region_accesses(), acc0 + 2);
        eq("and fuel was spent once per access",
           fuel0 - aml_eval_fuel(), 2);

        /* The narrow neighbour below it costs ONE access. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        fuel0 = aml_eval_fuel();
        acc0  = aml_region_accesses();
        eq("F0 reads the low three bits", aml_region_field_read(f0), d0 & 7);
        eq("one unit access", aml_region_accesses(), acc0 + 1);
        eq("one unit of fuel", fuel0 - aml_eval_fuel(), 1);

        /* WRITE, under Preserve. The stored value is deliberately not
         * all-ones and not all-zeros, so a lost-neighbour bug shows up as
         * a wrong bit rather than as a value that happens to match. */
        const uint64_t put = 0x5A5A5A5A5Aull & ((1ull << 40) - 1);
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        acc0 = aml_region_accesses();
        eq("store", aml_region_field_store(fsp, put), 1);
        eq("no error", aml_eval_err(), AML_OK);
        /* Preserve reads each partial unit before writing it: two units,
         * each read then written, is four accesses. */
        eq("read-modify-write costs two accesses per partial unit",
           aml_region_accesses(), acc0 + 4);

        uint64_t n0 = (uint64_t)back[0] | ((uint64_t)back[1] << 8)
                    | ((uint64_t)back[2] << 16) | ((uint64_t)back[3] << 24);
        uint64_t n1 = (uint64_t)back[4] | ((uint64_t)back[5] << 8)
                    | ((uint64_t)back[6] << 16) | ((uint64_t)back[7] << 24);

        /* THE NEIGHBOURS SURVIVED. Bits 0..2 of dword0 are F0's; bits
         * 11..31 of dword1 belong to nobody this field may touch. On real
         * hardware those are other control bits, and losing them is the
         * failure this whole read-modify-write exists to prevent. */
        eq("F0's bits are untouched", n0 & 7, d0 & 7);
        eq("dword1's upper 21 bits are untouched",
           n1 & ~((1ull << 11) - 1), d1 & ~((1ull << 11) - 1));
        /* ... and the field itself took the value. */
        eq("the low 29 bits landed in dword0",
           (n0 >> 3) & ((1ull << 29) - 1), put & ((1ull << 29) - 1));
        eq("the high 11 bits landed in dword1",
           n1 & ((1ull << 11) - 1), (put >> 29) & ((1ull << 11) - 1));

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("and it reads back", aml_region_field_read(fsp), put);
        eq("with F0 still intact", aml_region_field_read(f0), d0 & 7);

        backing_free();
    });
}

/* The UpdateRule decides the fate of the bits a partial write does not
 * cover, and the two non-default rules must NOT read first -- they name
 * registers where reading has a side effect. */
static void test_region_update_rules(void)
{
    /* Three one-bit fields at bit 1 of a ByteAcc region, one per
     * UpdateRule. FieldFlags: ByteAcc(1) | UpdateRule << 5. */
    uint8_t b[] = {
        0x5B, 0x80, 'R','G','N','2', 0x00, 0x0B, 0x00, 0x30, 0x0A, 0x04,
        /* Preserve */
        0x5B, 0x81, 0x0D, 'R','G','N','2', 0x01,
            0x00, 0x01, 'P','R','S','V', 0x01,
        /* WriteAsOnes */
        0x5B, 0x81, 0x0D, 'R','G','N','2', 0x21,
            0x00, 0x01, 'O','N','E','S', 0x01,
        /* WriteAsZeros */
        0x5B, 0x81, 0x0D, 'R','G','N','2', 0x41,
            0x00, 0x01, 'Z','R','O','S', 0x01
    };
    WITH_PARSE("region: the UpdateRule decides the uncovered bits", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn  = nth_child(root, 0);
        uint64_t fpre = nth_child(nth_child(root, 1), 1);
        uint64_t fone = nth_child(nth_child(root, 2), 1);
        uint64_t fzer = nth_child(nth_child(root, 3), 1);
        eq("Preserve", aml_field_update_rule(nth_child(root, 1)), 0);
        eq("WriteAsOnes", aml_field_update_rule(nth_child(root, 2)), 1);
        eq("WriteAsZeros", aml_field_update_rule(nth_child(root, 3)), 2);
        eq("all three at bit 1", aml_node_arg0(fpre), 1);
        eq("all three one bit wide", aml_node_arg1(fzer), 1);

        static const uint8_t seed[4] = { 0xA5, 0, 0, 0 };
        uint8_t *back = backing_load(seed, sizeof seed);

        aml_eval_reset(2);
        aml_region_reset();
        uint64_t bd = aml_region_bind(rgn, 9, 0x3000, 4,
                                      (uint64_t)(uintptr_t)back);
        g_checks++;
        if (bd == 0) fail("bind failed");

        /* Preserve: only bit 1 changes. 0xA5 = 1010_0101; bit 1 is 0. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t acc0 = aml_region_accesses();
        eq("store 1", aml_region_field_store(fpre, 1), 1);
        eq("one read + one write", aml_region_accesses(), acc0 + 2);
        eq("only bit 1 moved", (uint64_t)back[0], 0xA7);

        /* WriteAsOnes: every other bit of the byte becomes 1, and the
         * unit is NOT read first. */
        back[0] = 0xA5;
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        acc0 = aml_region_accesses();
        eq("store 0", aml_region_field_store(fone, 0), 1);
        eq("ONE access -- the unit was not read", aml_region_accesses(), acc0 + 1);
        eq("uncovered bits became ones", (uint64_t)back[0], 0xFD);

        /* WriteAsZeros: every other bit becomes 0, also without a read. */
        back[0] = 0xA5;
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        acc0 = aml_region_accesses();
        eq("store 1", aml_region_field_store(fzer, 1), 1);
        eq("ONE access -- the unit was not read", aml_region_accesses(), acc0 + 1);
        eq("uncovered bits became zeros", (uint64_t)back[0], 0x02);

        backing_free();
    });
}

/* THE ACCESS WIDTH IS DECLARED, NOT CHOSEN.
 *
 * The discriminator is a field whose bits are inside the region but
 * whose ALIGNED UNIT at the declared width is not. A handler that
 * quietly serviced a DWordAcc field with byte accesses would succeed
 * here; the declared width makes it an error. */
static void test_region_access_width_is_honoured(void)
{
    /* A 6-byte region. Two fields at bit 32 (byte 4), width 8: one
     * DWordAcc, one ByteAcc. Byte 4 is inside the region; the dword
     * containing it (bytes 4..7) is not. */
    uint8_t b[] = {
        0x5B, 0x80, 'R','G','N','3', 0x00, 0x0B, 0x00, 0x40, 0x0A, 0x06,
        0x5B, 0x81, 0x0D, 'R','G','N','3', 0x03,          /* DWordAcc */
            0x00, 0x20, 'D','W','I','D', 0x08,
        0x5B, 0x81, 0x0D, 'R','G','N','3', 0x01,          /* ByteAcc  */
            0x00, 0x20, 'B','W','I','D', 0x08,
        0x5B, 0x81, 0x0D, 'R','G','N','3', 0x05,          /* BufferAcc */
            0x00, 0x20, 'X','B','U','F', 0x08,
        0x5B, 0x81, 0x0D, 'R','G','N','3', 0x00,          /* AnyAcc   */
            0x00, 0x20, 'A','W','I','D', 0x08,
        0x5B, 0x81, 0x0D, 'R','G','N','3', 0x02,          /* WordAcc  */
            0x00, 0x20, 'W','W','I','D', 0x08,
        0x5B, 0x81, 0x0D, 'R','G','N','3', 0x04,          /* QWordAcc */
            0x00, 0x20, 'Q','W','I','D', 0x08
    };
    WITH_PARSE("region: the declared access width is honoured", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn = nth_child(root, 0);
        uint64_t dw  = nth_child(nth_child(root, 1), 1);
        uint64_t bw  = nth_child(nth_child(root, 2), 1);
        uint64_t xb  = nth_child(nth_child(root, 3), 1);
        uint64_t aw  = nth_child(nth_child(root, 4), 1);
        uint64_t ww  = nth_child(nth_child(root, 5), 1);
        uint64_t qw  = nth_child(nth_child(root, 6), 1);

        /* The resolution table, in both directions. */
        eq("AnyAcc resolves to 8 for a memory window", aml_region_acc_bits(aw, SP_MEM), 8);
        eq("ByteAcc  -> 8",  aml_region_acc_bits(bw, SP_MEM), 8);
        eq("WordAcc  -> 16", aml_region_acc_bits(ww, SP_MEM), 16);
        eq("DWordAcc -> 32", aml_region_acc_bits(dw, SP_MEM), 32);
        eq("QWordAcc -> 64", aml_region_acc_bits(qw, SP_MEM), 64);
        eq("BufferAcc is not a memory width", aml_region_acc_bits(xb, SP_MEM), 0);

        static const uint8_t seed[6] = { 0, 0, 0, 0, 0x7E, 0 };
        uint8_t *back = backing_load(seed, sizeof seed);

        aml_eval_reset(2);
        aml_region_reset();
        uint64_t bd = aml_region_bind(rgn, 9, 0x4000, 6,
                                      (uint64_t)(uintptr_t)back);
        g_checks++;
        if (bd == 0) fail("bind failed");

        /* The ByteAcc field reads: its unit is byte 4, which is in. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("the byte-wide field reads", aml_region_field_read(bw), 0x7E);
        eq("no error", aml_eval_err(), AML_OK);

        /* The DWordAcc field over the SAME BITS is refused, because its
         * unit runs to byte 7 and the region ends at byte 5. This is the
         * assertion that a byte-serviced implementation fails. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t acc0 = aml_region_accesses();
        GUARDED(eq("the dword-wide field over the same bits is refused",
                   aml_region_field_read(dw), 0));
        eq("OOB", aml_eval_err(), E_REGION_OOB);
        eq("and nothing was read", aml_region_accesses(), acc0);

        /* QWordAcc likewise, and WordAcc succeeds (bytes 4..5 fit). */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        GUARDED(eq("the qword-wide field is refused",
                   aml_region_field_read(qw), 0));
        eq("OOB", aml_eval_err(), E_REGION_OOB);
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("the word-wide field fits", aml_region_field_read(ww), 0x7E);
        eq("no error", aml_eval_err(), AML_OK);

        /* BufferAcc is refused as a WIDTH, not as a bounds problem --
         * the two must not be conflated, or a future SMBus handler would
         * inherit an error that says the wrong thing. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("BufferAcc is refused", aml_region_field_read(xb), 0);
        eq("ACCESS_WIDTH, not OOB", aml_eval_err(), E_REGION_ACCESS_WIDTH);

        backing_free();
    });
}

/* Everything this milestone does NOT service, stated as refusals rather
 * than left to be discovered. This is the boundary #1063/#1064/#1065
 * inherit. */
static void test_region_boundary_refusals(void)
{
    /* A SystemIO region, an IndexField, and a field wider than 64 bits. */
    uint8_t b[] = {
        0x5B, 0x80, 'S','M','B','0', 0x04, 0x0A, 0x62, 0x0A, 0x02,
        0x5B, 0x80, 'R','G','N','4', 0x00, 0x0B, 0x00, 0x50, 0x0A, 0x20,
        0x5B, 0x81, 0x0C, 'R','G','N','4', 0x01,
            'W','I','D','E', 0x40, 0x08,         /* 128 bits (PkgLength) */
        0x5B, 0x86, 0x0F, 'R','G','N','4', 'S','I','O','0', 0x01,
            'I','X','F','L', 0x08
    };
    WITH_PARSE("region: the boundary this milestone stops at", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t sio  = nth_child(root, 0);
        uint64_t rgn  = nth_child(root, 1);
        uint64_t wide = nth_child(nth_child(root, 2), 0);
        uint64_t ixf  = nth_child(nth_child(root, 3), 1);
        eq("SMBus", aml_node_flags(sio), 4);
        eq("128 bits wide", aml_node_arg1(wide), 128);
        eq("an IndexField element", aml_node_kind(ixf), N_FIELD_ELEM);

        uint8_t *back = backing_load(NULL, 0x20);

        /* A space this milestone does not service is refused at BIND, so
         * the failure is reported once, where the table is being set up,
         * rather than at every later access. */
        aml_eval_reset(2);
        aml_region_reset();
        eq("an SMBus region is refused",
           aml_region_bind(sio, 9, 0x62, 2, (uint64_t)(uintptr_t)back), 0);
        eq("SPACE — a bus protocol is not a window",
           aml_eval_err(), E_REGION_SPACE);
        eq("nothing bound", aml_region_count(), 0);

        aml_eval_reset(2);
        uint64_t bd = aml_region_bind(rgn, 9, 0x5000, 0x20,
                                      (uint64_t)(uintptr_t)back);
        g_checks++;
        if (bd == 0) fail("bind failed");

        /* A field wider than 64 bits reads as a Buffer per ACPI. It is
         * refused rather than truncated: a truncated read returns a
         * plausible wrong answer. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t acc0 = aml_region_accesses();
        eq("a 128-bit field is refused", aml_region_field_read(wide), 0);
        eq("FIELD_WIDTH (Buffer-valued, R30.M4)",
           aml_eval_err(), E_REGION_FIELD_WIDTH);
        eq("and nothing was read", aml_region_accesses(), acc0);

        /* An IndexField element is a two-step protocol, not an offset. */
        aml_eval_reset(2);
        eq("an IndexField element has no direct region",
           aml_region_of_field(ixf), 0);
        eq("INDIRECT_FIELD (R30.M4)", aml_eval_err(), E_REGION_INDIRECT_FIELD);
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        acc0 = aml_region_accesses();
        eq("and reading it is refused", aml_region_field_read(ixf), 0);
        eq("INDIRECT_FIELD", aml_eval_err(), E_REGION_INDIRECT_FIELD);
        eq("with nothing read", aml_region_accesses(), acc0);

        backing_free();
    });
}

/* The binding table is bounded, and exhaustion is a clean refusal rather
 * than an overwrite -- an overwritten row would silently re-point one
 * region's accesses at another region's window. */
static void test_region_table_is_bounded(void)
{
    uint8_t b[17 * 11];
    size_t n = 0;
    for (int i = 0; i < 17; i++) {
        b[n++] = 0x5B; b[n++] = 0x80;
        b[n++] = 'R';  b[n++] = 'G';
        b[n++] = (uint8_t)('A' + i / 10);
        b[n++] = (uint8_t)('0' + i % 10);
        b[n++] = 0x00;                          /* SystemMemory */
        /* Bases must stay inside a ByteConst, so 8 apart rather than 16:
         * the seventeenth region at 0x10 * 17 would truncate to 0x10 and
         * silently alias the first, which would make the exhaustion
         * assertion below measure the wrong thing. */
        b[n++] = 0x0A; b[n++] = (uint8_t)(0x08 * (i + 1));
        b[n++] = 0x0A; b[n++] = 0x04;
    }
    WITH_PARSE("region: the binding table is bounded", b, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        eq("seventeen regions", (uint64_t)count_children(root), 17);

        uint8_t *back = backing_load(NULL, 0x200);
        aml_eval_reset(2);
        aml_region_reset();

        for (int i = 0; i < 15; i++) {
            uint64_t r = nth_child(root, i);
            uint64_t base = 0x08 * (uint64_t)(i + 1);
            uint64_t bd = aml_region_bind(r, 9, base, 4,
                                          (uint64_t)(uintptr_t)back);
            g_checks++;
            if (bd == 0) fail("bind %d failed", i);
        }
        eq("fifteen bound", aml_region_count(), 15);
        eq("no error", aml_eval_err(), AML_OK);

        aml_eval_reset(2);
        eq("the sixteenth is refused",
           aml_region_bind(nth_child(root, 15), 9, 0x08 * 16, 4,
                           (uint64_t)(uintptr_t)back), 0);
        eq("TABLE_FULL", aml_eval_err(), E_REGION_TABLE_FULL);
        eq("and the refusal changed nothing", aml_region_count(), 15);

        /* A reset recovers the table. */
        aml_region_reset();
        eq("reset clears every binding", aml_region_count(), 0);
        eq("and the counters with it", aml_region_accesses(), 0);

        backing_free();
    });
}

/* THE FIELDUNIT BOUNDARY, END TO END THROUGH THE EVALUATOR.
 *
 * #1057 left a FieldUnit store as AML_ERR_BAD_TARGET with the note that
 * writing one is a bus transaction belonging to R30.M3. This is that
 * milestone: the same AML that was refused then must now run. */
static void test_region_fieldunit_store_is_real_now(void)
{
    /* OperationRegion(RGN5, SystemMemory, 0x6000, 0x08)
     * Field(RGN5, ByteAcc, NoLock, Preserve) { FB0_, 8 }
     * Method(RMAI, 0) { Store(0x5A, FB0_); Return(FB0_) } */
    uint8_t b[] = {
        0x5B, 0x80, 'R','G','N','5', 0x00, 0x0B, 0x00, 0x60, 0x0A, 0x08,
        0x5B, 0x81, 0x0B, 'R','G','N','5', 0x01,
            'F','B','0','_', 0x08,
        0x14, 0x12, 'R','M','A','I', 0x00,
            0x70, 0x0A, 0x5A, 'F','B','0','_',
            0xA4, 'F','B','0','_'
    };
    WITH_PARSE("region: a FieldUnit store is a real access now", b, sizeof b, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn  = nth_child(root, 0);
        uint64_t fb0  = nth_child(nth_child(root, 1), 0);
        uint64_t rmai = nth_child(root, 2);
        eq("a method", aml_node_kind(rmai), N_METHOD);

        static const uint8_t seed[8] = { 0x11, 0x22, 0, 0, 0, 0, 0, 0 };
        uint8_t *back = backing_load(seed, sizeof seed);

        /* UNBOUND FIRST. The method must fail cleanly, and it must fail
         * with the code that says "no capability", not with a generic
         * one -- an operator reading the log has to be able to tell a
         * missing grant from a malformed table. */
        aml_eval_reset(2);
        aml_region_reset();
        aml_eval_set_fuel(10000);
        eq("unbound: no value", aml_eval_method(rmai), 0);
        eq("UNBOUND", aml_eval_err(), E_REGION_UNBOUND);
        eq("nothing was read or written", aml_region_accesses(), 0);
        eq("the buffer is untouched", (uint64_t)back[0], 0x11);
        eq("frames unwound", aml_eval_frames(), 0);

        /* Now bind it and run the same bytes. */
        aml_eval_reset(2);
        uint64_t bd = aml_region_bind(rgn, 9, 0x6000, 8,
                                      (uint64_t)(uintptr_t)back);
        g_checks++;
        if (bd == 0) fail("bind failed");

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("the method returns what it stored", aml_eval_method(rmai), 0x5A);
        eq("no error", aml_eval_err(), AML_OK);
        eq("and the store reached the backing store", (uint64_t)back[0], 0x5A);
        eq("without disturbing the next byte", (uint64_t)back[1], 0x22);
        eq("frames unwound", aml_eval_frames(), 0);

        /* A direct read through the evaluator's object path, which is
         * the other half of the boundary move. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t o = aml_region_field_load_obj(fb0);
        g_checks++;
        if (o == 0) fail("field load produced no object");
        eq("an Integer", aml_obj_type(o), T_INT);
        eq("holding the stored byte", aml_obj_int_value(o), 0x5A);

        /* A field that genuinely reads ZERO must produce an object, not
         * a failure. This is why the object wrapper consults the error
         * latch rather than the returned value. */
        back[0] = 0x00;
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        o = aml_region_field_load_obj(fb0);
        g_checks++;
        if (o == 0) fail("a field reading 0 was reported as a failure");
        eq("still an Integer", aml_obj_type(o), T_INT);
        eq("holding zero", aml_obj_int_value(o), 0);
        eq("no error", aml_eval_err(), AML_OK);

        backing_free();
    });
}

/* =====================================================================
 * R30.M3-003/004/005 (#1063 / #1064 / #1065) — the other three spaces.
 *
 * THE TRANSACTION/LOGIC SPLIT, PER SPACE. #1062 established that the
 * mapping step decides WHETHER and WHERE, and the access step does the
 * arithmetic against whatever the mapping step recorded. That split is
 * what lets the corpus run the real code. It falls differently for each
 * of the three spaces added here, so each is stated:
 *
 *   PCI_Config — the transaction is a MEMORY access, because ECAM is
 *   memory-mapped. So there is nothing new to stub at all: the corpus
 *   points host_va at a 4096-byte synthetic function and the entire
 *   handler runs for real. Everything #1064 adds — resolving
 *   {seg, bus, dev, func} from the namespace, bounding by config-space
 *   size, resolving AnyAcc to dword — is pure logic over the parse tree
 *   and is tested directly. NO CONFIG SPACE IS READ.
 *
 *   SystemIO — the logic is identical to the memory path and is tested
 *   against a synthetic backing, which is reached by handing bind a
 *   host_va that is a buffer. The transaction is `in`/`out`, confined to
 *   aml_region_port_in / aml_region_port_out.
 *
 *   NO REAL PORT I/O IS PERFORMED BY THIS CORPUS, and that is a
 *   deliberate refusal rather than a gap. Executing `in` against, say,
 *   port 0x60 would be a real transaction against the real PS/2
 *   controller of whatever machine runs the pre-push hook. It happens to
 *   fault in ring 3 on Linux — which is tempting to lean on as proof —
 *   but "it faulted" is only true while the harness lacks I/O privilege,
 *   and a corpus whose evidence evaporates if it is ever run with more
 *   privilege is not evidence. So the port path is pinned two other
 *   ways, both airtight and neither touching a port:
 *
 *     1. STRUCTURALLY. tools/verify-aml-parser.sh disassembles
 *        aml_region.o and asserts that every `in` and `out` instruction
 *        lies inside those two functions and nowhere else.
 *     2. BEHAVIOURALLY, via a discriminator that needs no transaction: a
 *        qword access through a real-port binding is refused with
 *        ACCESS_WIDTH, because no 8-byte port instruction exists. A
 *        mutant that routed the real-port sentinel to the memory path
 *        would instead dereference address 1 and die of a SIGSEGV the
 *        harness reports.
 *
 *   EmbeddedControl — there is no transaction to test, because R31 does
 *   not exist. The corpus tests the logic and PINS the transaction at
 *   zero. That pin is the assertion that flips when R31 lands.
 * ===================================================================== */

/* Emit a PkgLength for `n` bytes of body, then the body. */
static size_t emit_pkg(uint8_t *out, const uint8_t *body, size_t n)
{
    size_t k = emit_pkglen(out, n);
    memcpy(out + k, body, n);
    return k + n;
}

/* OperationRegion (IOR0, SystemIO, base, len), then six Fields over it —
 * one per UpdateRule, one covering a whole unit, one QWordAcc and one
 * AnyAcc. Base and length are DWord-encoded whatever their value so the
 * byte layout does not shift between cases. */
static size_t build_io(uint8_t *out, uint32_t base, uint32_t len)
{
    static const struct { uint8_t flags; const char *n0; const char *n1; }
    F[] = {
        { 0x01, "FLDL", "FLDH" },   /* ByteAcc  Preserve      */
        { 0x21, "ONEL", "ONEH" },   /* ByteAcc  WriteAsOnes   */
        { 0x41, "ZERL", "ZERH" },   /* ByteAcc  WriteAsZeros  */
    };
    size_t o = 0;
    out[o++] = 0x5B; out[o++] = 0x80;
    out[o++]='I'; out[o++]='O'; out[o++]='R'; out[o++]='0';
    out[o++] = 0x01;                                   /* SystemIO */
    out[o++] = 0x0C;
    out[o++]=(uint8_t)base;       out[o++]=(uint8_t)(base>>8);
    out[o++]=(uint8_t)(base>>16); out[o++]=(uint8_t)(base>>24);
    out[o++] = 0x0C;
    out[o++]=(uint8_t)len;        out[o++]=(uint8_t)(len>>8);
    out[o++]=(uint8_t)(len>>16);  out[o++]=(uint8_t)(len>>24);

    for (size_t i = 0; i < sizeof F / sizeof F[0]; i++) {
        uint8_t b[32]; size_t k = 0;
        memcpy(b + k, "IOR0", 4); k += 4;
        b[k++] = F[i].flags;
        memcpy(b + k, F[i].n0, 4); k += 4; b[k++] = 4;
        memcpy(b + k, F[i].n1, 4); k += 4; b[k++] = 4;
        out[o++] = 0x5B; out[o++] = 0x81;
        o += emit_pkg(out + o, b, k);
    }
    /* A field covering a WHOLE access unit — no rule applies. */
    { uint8_t b[32]; size_t k = 0;
      memcpy(b + k, "IOR0", 4); k += 4; b[k++] = 0x01;
      memcpy(b + k, "WHOL", 4); k += 4; b[k++] = 8;
      out[o++] = 0x5B; out[o++] = 0x81; o += emit_pkg(out + o, b, k); }
    /* QWordAcc — refused for a port, which is the point. */
    { uint8_t b[32]; size_t k = 0;
      memcpy(b + k, "IOR0", 4); k += 4; b[k++] = 0x04;
      memcpy(b + k, "QFLD", 4); k += 4; b[k++] = 32;
      out[o++] = 0x5B; out[o++] = 0x81; o += emit_pkg(out + o, b, k); }
    /* AnyAcc — must resolve to the narrowest width for a port. */
    { uint8_t b[32]; size_t k = 0;
      memcpy(b + k, "IOR0", 4); k += 4; b[k++] = 0x00;
      memcpy(b + k, "ANYF", 4); k += 4; b[k++] = 8;
      out[o++] = 0x5B; out[o++] = 0x81; o += emit_pkg(out + o, b, k); }
    return o;
}

/* OperationRegion (ECR_, EmbeddedControl, 0, len) + a ByteAcc field and
 * a WordAcc field. The EC transfers one byte per handshake, so the
 * WordAcc one must be refused. */
static size_t build_ec(uint8_t *out, uint32_t len)
{
    size_t o = 0;
    out[o++] = 0x5B; out[o++] = 0x80;
    out[o++]='E'; out[o++]='C'; out[o++]='R'; out[o++]='_';
    out[o++] = 0x03;                                   /* EmbeddedControl */
    out[o++] = 0x0C; out[o++]=0; out[o++]=0; out[o++]=0; out[o++]=0;
    out[o++] = 0x0C;
    out[o++]=(uint8_t)len;        out[o++]=(uint8_t)(len>>8);
    out[o++]=(uint8_t)(len>>16);  out[o++]=(uint8_t)(len>>24);

    { uint8_t b[32]; size_t k = 0;
      memcpy(b + k, "ECR_", 4); k += 4; b[k++] = 0x01;   /* ByteAcc */
      memcpy(b + k, "ECF0", 4); k += 4; b[k++] = 8;
      out[o++] = 0x5B; out[o++] = 0x81; o += emit_pkg(out + o, b, k); }
    { uint8_t b[32]; size_t k = 0;
      memcpy(b + k, "ECR_", 4); k += 4; b[k++] = 0x02;   /* WordAcc */
      memcpy(b + k, "ECW0", 4); k += 4; b[k++] = 16;
      out[o++] = 0x5B; out[o++] = 0x81; o += emit_pkg(out + o, b, k); }
    return o;
}

/* Device (DEV0) { Name(_ADR, adr)?  OperationRegion(PCFG, PCI_Config,
 *                 rbase, rlen)  Field(PCFG, AccType, NoLock, Preserve)
 *                 { PFLD, 32 } }
 * optionally wrapped in a host bridge:
 *   Device (PCI0) { _HID = EisaId(hid), _BBN = 0x20, _SEG = 0x01, DEV0 }
 *
 * _BBN and _SEG are deliberately NON-ZERO. A mutant that defaults the
 * bus or the segment instead of reading them produces 0 and dies on the
 * context comparison — which would be invisible if the fixture had used
 * the values a defaulting implementation would invent. */
static size_t build_pci(uint8_t *out, int with_bridge, int with_adr,
                        uint32_t adr, uint32_t hid, uint32_t rbase,
                        uint32_t rlen, uint8_t accflags)
{
    uint8_t inner[192]; size_t i = 0;
    if (with_adr) {
        inner[i++] = 0x08;
        memcpy(inner + i, "_ADR", 4); i += 4;
        inner[i++] = 0x0C;
        inner[i++]=(uint8_t)adr;       inner[i++]=(uint8_t)(adr>>8);
        inner[i++]=(uint8_t)(adr>>16); inner[i++]=(uint8_t)(adr>>24);
    }
    inner[i++] = 0x5B; inner[i++] = 0x80;
    memcpy(inner + i, "PCFG", 4); i += 4;
    inner[i++] = 0x02;                                 /* PCI_Config */
    inner[i++] = 0x0C;
    inner[i++]=(uint8_t)rbase;       inner[i++]=(uint8_t)(rbase>>8);
    inner[i++]=(uint8_t)(rbase>>16); inner[i++]=(uint8_t)(rbase>>24);
    inner[i++] = 0x0C;
    inner[i++]=(uint8_t)rlen;        inner[i++]=(uint8_t)(rlen>>8);
    inner[i++]=(uint8_t)(rlen>>16);  inner[i++]=(uint8_t)(rlen>>24);
    { uint8_t b[32]; size_t k = 0;
      memcpy(b + k, "PCFG", 4); k += 4; b[k++] = accflags;
      memcpy(b + k, "PFLD", 4); k += 4; b[k++] = 32;
      inner[i++] = 0x5B; inner[i++] = 0x81; i += emit_pkg(inner + i, b, k); }

    uint8_t devbody[224]; size_t d = 0;
    memcpy(devbody + d, "DEV0", 4); d += 4;
    memcpy(devbody + d, inner, i);  d += i;

    uint8_t dev[240]; size_t dn = 0;
    dev[dn++] = 0x5B; dev[dn++] = 0x82;
    dn += emit_pkg(dev + dn, devbody, d);

    if (!with_bridge) { memcpy(out, dev, dn); return dn; }

    uint8_t br[320]; size_t bn = 0;
    memcpy(br + bn, "PCI0", 4); bn += 4;
    br[bn++] = 0x08; memcpy(br + bn, "_HID", 4); bn += 4;
    br[bn++] = 0x0C;
    br[bn++]=(uint8_t)hid;       br[bn++]=(uint8_t)(hid>>8);
    br[bn++]=(uint8_t)(hid>>16); br[bn++]=(uint8_t)(hid>>24);
    br[bn++] = 0x08; memcpy(br + bn, "_BBN", 4); bn += 4;
    br[bn++] = 0x0A; br[bn++] = 0x20;                  /* bus 0x20 */
    br[bn++] = 0x08; memcpy(br + bn, "_SEG", 4); bn += 4;
    br[bn++] = 0x0A; br[bn++] = 0x01;                  /* segment 1 */
    memcpy(br + bn, dev, dn); bn += dn;

    size_t o = 0;
    out[o++] = 0x5B; out[o++] = 0x82;
    o += emit_pkg(out + o, br, bn);
    return o;
}

/* --- the enumerated boundary of AML_ERR_REGION_SPACE ------------------ */

static void test_region_space_boundary(void)
{
    g_case = "region: the serviced spaces, and the enumerated refusal";

    eq("SystemMemory serviced",    aml_region_space_supported(0), 1);
    eq("SystemIO serviced",        aml_region_space_supported(1), 1);
    eq("PCI_Config serviced",      aml_region_space_supported(2), 1);
    eq("EmbeddedControl serviced", aml_region_space_supported(3), 1);

    /* Everything still refused, named one by one. Each is a bus protocol
     * whose access is a transaction, not a load from an offset. */
    eq("SMBus refused",            aml_region_space_supported(4), 0);
    eq("SystemCMOS refused",       aml_region_space_supported(5), 0);
    eq("PciBarTarget refused",     aml_region_space_supported(6), 0);
    eq("IPMI refused",             aml_region_space_supported(7), 0);
    eq("GeneralPurposeIO refused", aml_region_space_supported(8), 0);
    eq("GenericSerialBus refused", aml_region_space_supported(9), 0);
    eq("PCC refused",              aml_region_space_supported(10), 0);
    eq("vendor-defined refused",   aml_region_space_supported(0x80), 0);
    eq("0xFF refused",             aml_region_space_supported(0xFF), 0);
}

/* --- SystemIO: the 16-bit port bound and the width refusal ------------ */

static void test_region_systemio_port_bounds(void)
{
    static const struct { uint32_t base, len; int ok; const char *what; } C[] = {
        { 0x0060,     0x0008, 1, "an ordinary port range binds" },
        { 0x0000,     0x0001, 1, "port 0 is a real port" },
        { 0xFFF8,     0x0008, 1, "a range ending exactly at 0x10000 binds" },
        { 0xFFF8,     0x0009, 0, "one byte past the end of port space" },
        { 0xFFFF,     0x0002, 0, "straddling the top of port space" },
        { 0x10000,    0x0001, 0, "the first port that does not exist" },
        { 0xFFFFFFFF, 0x0002, 0, "a base that would wrap if added to" },
        { 0x0000,  0x10001,   0, "longer than the whole port space" },
    };
    for (size_t i = 0; i < sizeof C / sizeof C[0]; i++) {
        uint8_t f[256];
        size_t n = build_io(f, C[i].base, C[i].len);
        WITH_PARSE(C[i].what, f, n, {
            eq("parse ok", aml_lex_err(), AML_OK);
            uint64_t rgn = nth_child(root, 0);
            eq("an OperationRegion", aml_node_kind(rgn), N_OPREGION);
            eq("in SystemIO", aml_node_flags(rgn), SP_IO);

            uint8_t *back = backing_load(NULL, 0x40);
            aml_eval_reset(2);
            aml_region_reset();
            uint64_t before = aml_region_refusals();
            /* The window is handed in as the capability's own port range,
             * so containment can never be what refuses these: the port
             * bound is a property of the SPACE and is checked first. */
            uint64_t b = aml_region_bind(rgn, 7, C[i].base, C[i].len,
                                         (uint64_t)(uintptr_t)back);
            if (C[i].ok) {
                g_checks++;
                if (b == 0) fail("%s — expected a binding", C[i].what);
                eq("no error", aml_eval_err(), AML_OK);
                eq("space recorded", aml_region_space(b), SP_IO);
                eq("no PCI context on a port binding",
                   aml_region_pci_ctx(b), 0);
            } else {
                eq("refused", b, 0);
                eq("PORT_RANGE", aml_eval_err(), E_REGION_PORT_RANGE);
                eq("and counted", aml_region_refusals(), before + 1);
                eq("nothing bound", aml_region_count(), 0);
            }
            backing_free();
        });
    }
}

static void test_region_systemio_widths(void)
{
    uint8_t f[256];
    size_t n = build_io(f, 0x60, 8);
    WITH_PARSE("region: SystemIO admits byte/word/dword and refuses qword",
               f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn  = nth_child(root, 0);
        uint64_t qfld = nth_child(nth_child(root, 5), 0);   /* QWordAcc */
        uint64_t anyf = nth_child(nth_child(root, 6), 0);   /* AnyAcc   */

        /* THE WIDTH TABLE, read out directly in all four spaces. The
         * three zeroes are the substance of this milestone's refusals. */
        eq("QWordAcc is legal over memory",
           aml_region_acc_bits(qfld, SP_MEM), 64);
        eq("QWordAcc has NO port form",
           aml_region_acc_bits(qfld, SP_IO), 0);
        eq("QWordAcc has no config-space form",
           aml_region_acc_bits(qfld, SP_PCI), 0);
        eq("QWordAcc is not an EC transaction",
           aml_region_acc_bits(qfld, SP_EC), 0);

        eq("AnyAcc is a byte for memory", aml_region_acc_bits(anyf, SP_MEM), 8);
        eq("AnyAcc is a byte for a port", aml_region_acc_bits(anyf, SP_IO), 8);
        eq("AnyAcc is a DWORD for config space",
           aml_region_acc_bits(anyf, SP_PCI), 32);
        eq("AnyAcc is a byte for the EC", aml_region_acc_bits(anyf, SP_EC), 8);

        /* And the refusal is reported through the field path, not merely
         * available from the table. */
        uint8_t *back = backing_load(NULL, 0x40);
        aml_eval_reset(2);
        aml_region_reset();
        uint64_t b = aml_region_bind(rgn, 7, 0x60, 8,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("bind failed");

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t before = aml_region_accesses();
        eq("a QWordAcc field over a port is refused",
           aml_region_field_read(qfld), 0);
        eq("ACCESS_WIDTH", aml_eval_err(), E_REGION_ACCESS_WIDTH);
        eq("and NOT split into two dword transactions",
           aml_region_accesses(), before);

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("nor is it split on the write side",
           aml_region_field_store(qfld, 0x1122334455667788ull), 0);
        eq("ACCESS_WIDTH", aml_eval_err(), E_REGION_ACCESS_WIDTH);
        eq("still no transaction", aml_region_accesses(), before);

        /* The port primitives themselves refuse the width too, without
         * executing anything — the 8-byte case returns before reaching
         * an instruction. This is the second line of the same defence. */
        eq("port_in has no 8-byte form",  aml_region_port_in(0x60, 8), 0);
        eq("port_out has no 8-byte form", aml_region_port_out(0x60, 8, 0), 0);
        eq("nor a 3-byte one",            aml_region_port_in(0x60, 3), 0);

        backing_free();
    });
}

/* THE ACCESS-COUNT ASSERTION. For a port, "did it read?" is the entire
 * question: a read can clear a status bit or pop a FIFO, so a Preserve
 * partial write must perform exactly one read and one write, and a
 * WriteAsOnes / WriteAsZeros partial write must perform exactly one
 * write AND NO READ. Asserting the resulting bytes alone would not
 * distinguish them — all three produce a correct-looking byte. */
static void test_region_systemio_update_rule_access_counts(void)
{
    uint8_t f[256];
    size_t n = build_io(f, 0x60, 8);
    WITH_PARSE("region: SystemIO honours the UpdateRule, counted", f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn  = nth_child(root, 0);
        uint64_t pres = nth_child(nth_child(root, 1), 0);   /* FLDL */
        uint64_t ones = nth_child(nth_child(root, 2), 0);   /* ONEL */
        uint64_t zers = nth_child(nth_child(root, 3), 0);   /* ZERL */
        uint64_t whol = nth_child(nth_child(root, 4), 0);   /* WHOL */

        uint8_t *back = backing_load(NULL, 8);
        aml_eval_reset(2);
        aml_region_reset();
        /* A SYNTHETIC BACKING, not the real-port sentinel: this is the
         * logic half of the split, and every line it runs is the line
         * the real port path runs. */
        uint64_t b = aml_region_bind(rgn, 7, 0x60, 8,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("bind failed");
        eq("bound as SystemIO", aml_region_space(b), SP_IO);

        /* -- Preserve, partial: READ then WRITE. Exactly two. */
        back[0] = 0xA0;
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t before = aml_region_accesses();
        eq("preserve store ok", aml_region_field_store(pres, 0x5), 1);
        eq("the field's nibble changed", (uint64_t)(back[0] & 0x0F), 0x5);
        eq("the neighbouring nibble survived",
           (uint64_t)(back[0] & 0xF0), 0xA0);
        eq("exactly one read and one write",
           aml_region_accesses(), before + 2);

        /* -- WriteAsOnes, partial: WRITE ONLY. Exactly one.
         *    If this ever reads, a clear-on-read status port loses a bit
         *    that nothing downstream can recover. */
        back[0] = 0xA0;
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        before = aml_region_accesses();
        eq("write-as-ones store ok", aml_region_field_store(ones, 0x5), 1);
        eq("uncovered bits became ones", (uint64_t)back[0], 0xF5);
        eq("EXACTLY ONE ACCESS — NO READ",
           aml_region_accesses(), before + 1);

        /* -- WriteAsZeros, partial: WRITE ONLY. Exactly one. */
        back[0] = 0xA0;
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        before = aml_region_accesses();
        eq("write-as-zeros store ok", aml_region_field_store(zers, 0x5), 1);
        eq("uncovered bits became zeros", (uint64_t)back[0], 0x05);
        eq("EXACTLY ONE ACCESS — NO READ",
           aml_region_accesses(), before + 1);

        /* -- Preserve over a WHOLE unit: no rule applies, so no read
         *    either. The fast path must not read "because the rule is
         *    Preserve" when there are no bits to preserve. */
        back[0] = 0xA0;
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        before = aml_region_accesses();
        eq("whole-unit store ok", aml_region_field_store(whol, 0x3C), 1);
        eq("the whole byte was replaced", (uint64_t)back[0], 0x3C);
        eq("one write, no read", aml_region_accesses(), before + 1);

        /* -- And the read path counts one access per unit. */
        back[0] = 0x7E;
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        before = aml_region_accesses();
        eq("the low nibble reads back", aml_region_field_read(pres), 0xE);
        eq("one unit read", aml_region_accesses(), before + 1);

        backing_free();
    });
}

/* The real-port sentinel, proven WITHOUT performing a port transaction.
 * See the section header for why executing one would be worse evidence,
 * not better. */
static void test_region_systemio_real_sentinel(void)
{
    uint8_t f[256];
    size_t n = build_io(f, 0x60, 8);
    WITH_PARSE("region: the real-port sentinel routes away from memory",
               f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn = nth_child(root, 0);

        aml_eval_reset(2);
        aml_region_reset();
        /* THE WINDOW DELIBERATELY STARTS BELOW THE REGION (0x50 vs 0x60),
         * so the window offset is 0x10 and NOT zero. With an offset of
         * zero the sentinel arithmetic is unobservable — 1 + 0 == 1 — and
         * a mutant that applied the offset to the sentinel would survive.
         * Mutation testing found exactly that, which is why the two
         * numbers differ here. */
        uint64_t b = aml_region_bind(rgn, 7, 0x50, 0x20, IO_REAL);
        g_checks++;
        if (b == 0) fail("a real-port binding was refused");
        eq("no error", aml_eval_err(), AML_OK);
        eq("bound as SystemIO", aml_region_space(b), SP_IO);
        eq("the declared port base is recorded", aml_region_base(b), 0x60);

        /* THE SENTINEL IS STORED VERBATIM. If bind had added the window
         * offset to it — the arithmetic every other space needs — it
         * would become 0x11, no longer be recognisable as the sentinel,
         * and the access step would dereference a small integer. */
        eq("host_base is the sentinel, not an address",
           aml_region_row_word(b, 4), IO_REAL);

        /* THE DISCRIMINATOR. A qword access is refused because no 8-byte
         * port instruction exists. A mutant routing the sentinel to the
         * memory path would instead load from address 1 and take a
         * SIGSEGV that GUARDED reports as a failure. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        GUARDED(eq("a qword port read is refused",
                   aml_region_read_unit(b, 0, 8), 0));
        eq("ACCESS_WIDTH", aml_eval_err(), E_REGION_ACCESS_WIDTH);
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        GUARDED(eq("and so is a qword port write",
                   aml_region_write_unit(b, 0, 8, 0), 0));
        eq("ACCESS_WIDTH", aml_eval_err(), E_REGION_ACCESS_WIDTH);
    });

    /* A SystemMemory region handed the sentinel is NOT a mapping. */
    WITH_PARSE("region: the port sentinel is refused for a memory region",
               k_rgn0, sizeof k_rgn0, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn = nth_child(root, 0);
        aml_eval_reset(2);
        aml_region_reset();
        eq("refused", aml_region_bind(rgn, 7, 0x1000, 0x40, IO_REAL), 0);
        eq("NO_CAP", aml_eval_err(), E_REGION_NO_CAP);
        eq("nothing bound", aml_region_count(), 0);
    });
}

/* --- PCI_Config: the device context ----------------------------------- */

/* segment 1, bus 0x20, device 31, function 3 — none of them the value a
 * defaulting implementation would invent. */
#define PCI_EXPECT_CTX ((1ull << 40) | (1ull << 16) | (0x20ull << 8) \
                        | (31ull << 3) | 3ull)

static void test_region_pci_context_resolution(void)
{
    uint8_t f[512];
    size_t n = build_pci(f, 1, 1, 0x001F0003, 0x080AD041, 0x40, 0x10, 0x03);
    WITH_PARSE("region: PCI context comes from _ADR / _BBN / _SEG", f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t pci0 = nth_child(root, 0);
        uint64_t dev0 = nth_child(pci0, 3);
        uint64_t rgn  = nth_child(dev0, 1);
        eq("the bridge is a Device", aml_node_kind(pci0), N_DEVICE);
        eq("so is the function",     aml_node_kind(dev0), N_DEVICE);
        eq("an OperationRegion",     aml_node_kind(rgn),  N_OPREGION);
        eq("in PCI_Config",          aml_node_flags(rgn), SP_PCI);

        /* The walk, in pieces, so a failure names the step that broke. */
        eq("the enclosing Device is found",
           aml_region_enclosing_device(rgn), dev0);
        eq("the host bridge is found above it",
           aml_region_host_bridge(dev0), pci0);

        aml_eval_reset(2);
        uint64_t ctx = aml_region_pci_context(rgn);
        eq("the full context resolves", ctx, PCI_EXPECT_CTX);
        eq("no error", aml_eval_err(), AML_OK);
        /* Spelled out, so a packing change cannot silently pass. */
        eq("segment 1",   (ctx >> 16) & 0xFFFF, 1);
        eq("bus 0x20",    (ctx >> 8)  & 0xFF,   0x20);
        eq("device 31",   (ctx >> 3)  & 0x1F,   31);
        eq("function 3",  ctx & 0x7,            3);
        eq("and it is marked valid", (ctx >> 40) & 1, 1);

        /* The R22 offset arithmetic, mirrored and pinned. If
         * src/kernel/core/pci/config.pdx ever changed its ECAM layout,
         * this is the assertion that would catch the copy drifting. */
        eq("ECAM offset matches R22's (bus<<20)|(dev<<15)|(fn<<12)",
           aml_region_pci_ecam_offset(ctx),
           (0x20ull << 20) | (31ull << 15) | (3ull << 12));

        /* Binding records the context, so which function a region
         * resolved to is OBSERVABLE — the corruption this issue exists
         * to prevent is invisible otherwise. */
        uint8_t *back = backing_load(NULL, 4096);
        aml_eval_reset(2);
        aml_region_reset();
        uint64_t b = aml_region_bind(rgn, 7, 0, 4096,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("bind failed");
        eq("bound as PCI_Config", aml_region_space(b), SP_PCI);
        eq("with the resolved context", aml_region_pci_ctx(b), PCI_EXPECT_CTX);
        eq("and the space still reads back masked",
           aml_region_space(b), SP_PCI);
        backing_free();
    });

    /* PNP0A03 — the other host-bridge _HID — resolves identically. */
    n = build_pci(f, 1, 1, 0x001F0003, 0x030AD041, 0x40, 0x10, 0x03);
    WITH_PARSE("region: PNP0A03 is a host bridge too", f, n, {
        uint64_t rgn = nth_child(nth_child(nth_child(root, 0), 3), 1);
        aml_eval_reset(2);
        eq("resolves", aml_region_pci_context(rgn), PCI_EXPECT_CTX);
    });
}

/* THE REFUSALS. Every one of these would, if defaulted instead, address
 * a real but WRONG function — and every bounds check downstream would
 * still pass. */
static void test_region_pci_context_refusals(void)
{
    static const struct {
        int bridge, adr; uint32_t adrval, hid; const char *what;
    } C[] = {
        { 0, 1, 0x001F0003, 0x080AD041,
          "no host bridge in the ancestry — NOT 'probably bus 0'" },
        { 1, 0, 0,          0x080AD041,
          "a Device with no _ADR — NOT 'probably device 0'" },
        { 1, 1, 0x00200003, 0x080AD041,
          "device 32 does not exist — refused, NOT masked to device 0" },
        { 1, 1, 0x001F0008, 0x080AD041,
          "function 8 does not exist — refused, NOT masked to function 0" },
        { 1, 1, 0x001F0003, 0x0C0CD041,
          "an enclosing Device that is not a host bridge (PNP0C0C)" },
    };
    for (size_t i = 0; i < sizeof C / sizeof C[0]; i++) {
        uint8_t f[512];
        size_t n = build_pci(f, C[i].bridge, C[i].adr, C[i].adrval,
                             C[i].hid, 0x40, 0x10, 0x03);
        WITH_PARSE(C[i].what, f, n, {
            eq("parse ok", aml_lex_err(), AML_OK);
            uint64_t dev0 = C[i].bridge ? nth_child(nth_child(root, 0), 3)
                                        : nth_child(root, 0);
            uint64_t rgn  = nth_child(dev0, C[i].adr ? 1 : 0);
            eq("an OperationRegion", aml_node_kind(rgn), N_OPREGION);

            aml_eval_reset(2);
            eq("no context is produced", aml_region_pci_context(rgn), 0);
            eq("PCI_CONTEXT", aml_eval_err(), E_REGION_PCI_CONTEXT);

            /* And the refusal propagates to the bind, with NOTHING
             * bound — not a row addressed at 0000:00:00.0. */
            uint8_t *back = backing_load(NULL, 4096);
            aml_eval_reset(2);
            aml_region_reset();
            uint64_t before = aml_region_refusals();
            eq("bind refused", aml_region_bind(rgn, 7, 0, 4096,
                                               (uint64_t)(uintptr_t)back), 0);
            eq("PCI_CONTEXT survives to the caller",
               aml_eval_err(), E_REGION_PCI_CONTEXT);
            eq("counted once", aml_region_refusals(), before + 1);
            eq("and nothing was bound", aml_region_count(), 0);
            backing_free();
        });
    }
}

static void test_region_pci_config_space_bounds(void)
{
    static const struct { uint32_t base, len; int ok; const char *what; } C[] = {
        { 0x000, 0x100, 1, "the legacy 256 bytes fit" },
        { 0xFF0, 0x010, 1, "a region ending exactly at 4096 fits" },
        { 0xFF0, 0x011, 0, "one byte past extended config space" },
        { 0x1000, 0x001, 0, "the first offset that does not exist" },
        { 0x000, 0x1001, 0, "longer than config space itself" },
    };
    for (size_t i = 0; i < sizeof C / sizeof C[0]; i++) {
        uint8_t f[512];
        size_t n = build_pci(f, 1, 1, 0x001F0003, 0x080AD041,
                             C[i].base, C[i].len, 0x03);
        WITH_PARSE(C[i].what, f, n, {
            uint64_t rgn = nth_child(nth_child(nth_child(root, 0), 3), 1);
            uint8_t *back = backing_load(NULL, 4096);
            aml_eval_reset(2);
            aml_region_reset();
            uint64_t b = aml_region_bind(rgn, 7, 0, 4096,
                                         (uint64_t)(uintptr_t)back);
            if (C[i].ok) {
                g_checks++;
                if (b == 0) fail("%s — expected a binding", C[i].what);
                eq("no error", aml_eval_err(), AML_OK);
            } else {
                eq("refused", b, 0);
                eq("NOT_COVERED", aml_eval_err(), E_REGION_NOT_COVERED);
                eq("nothing bound", aml_region_count(), 0);
            }
            backing_free();
        });
    }
}

/* The PCI access path IS the memory path — which is the whole reason
 * this space needed no new transaction primitive. Asserting it runs end
 * to end against a synthetic function proves the reuse is real. */
static void test_region_pci_access_is_the_memory_path(void)
{
    uint8_t f[512];
    /* AnyAcc, so the dword resolution is exercised on the way through. */
    size_t n = build_pci(f, 1, 1, 0x001F0003, 0x080AD041, 0x40, 0x10, 0x00);
    WITH_PARSE("region: a PCI_Config field reads and writes through ECAM",
               f, n, {
        uint64_t dev0 = nth_child(nth_child(root, 0), 3);
        uint64_t rgn  = nth_child(dev0, 1);
        uint64_t pfld = nth_child(nth_child(dev0, 2), 0);

        uint8_t *back = backing_load(NULL, 4096);
        aml_eval_reset(2);
        aml_region_reset();
        uint64_t b = aml_region_bind(rgn, 7, 0, 4096,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("bind failed");

        eq("AnyAcc resolved to a dword for config space",
           aml_region_acc_bits(pfld, SP_PCI), 32);

        /* The declared region begins at config offset 0x40, so the
         * access must land there and NOT at offset 0. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("store ok", aml_region_field_store(pfld, 0xDEADBEEF), 1);
        eq("it landed at config offset 0x40",
           (uint64_t)back[0x40] | ((uint64_t)back[0x41] << 8)
           | ((uint64_t)back[0x42] << 16) | ((uint64_t)back[0x43] << 24),
           0xDEADBEEF);
        eq("and not at offset 0", (uint64_t)back[0], 0);

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("and reads back", aml_region_field_read(pfld), 0xDEADBEEF);
        backing_free();
    });
}

/* --- EmbeddedControl: gated, and honestly so ------------------------- */

static void test_region_ec_binds_but_does_not_transact(void)
{
    uint8_t f[256];
    size_t n = build_ec(f, 0x100);
    WITH_PARSE("region: EC binds, validates, and REFUSES to transact",
               f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t rgn  = nth_child(root, 0);
        uint64_t ecf0 = nth_child(nth_child(root, 1), 0);   /* ByteAcc */
        uint64_t ecw0 = nth_child(nth_child(root, 2), 0);   /* WordAcc */
        eq("in EmbeddedControl", aml_node_flags(rgn), SP_EC);

        uint8_t *back = backing_load(NULL, 0x100);
        memset(back, 0xA5, 0x100);           /* would-be "EC data" */

        aml_eval_reset(2);
        aml_region_reset();
        uint64_t b = aml_region_bind(rgn, 7, 0, 0x100,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("an EC region should BIND — only the transaction is gated");
        eq("no error", aml_eval_err(), AML_OK);
        eq("bound as EmbeddedControl", aml_region_space(b), SP_EC);

        /* The EC transfers one byte per handshake. A WordAcc EC field is
         * a table bug and must not become two handshakes. */
        eq("ByteAcc is the EC's only width",
           aml_region_acc_bits(ecf0, SP_EC), 8);
        eq("WordAcc is refused for the EC",
           aml_region_acc_bits(ecw0, SP_EC), 0);

        /* THE GATE. No value is produced, no access is counted, and the
         * backing buffer is NOT consulted — which is the assertion that
         * distinguishes an honest gate from a handler that quietly reads
         * whatever is nearest and calls it EC data. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t acc = aml_region_accesses();
        uint64_t gat = aml_region_ec_gated();
        eq("an EC read produces NOTHING", aml_region_read_unit(b, 0, 1), 0);
        eq("EC_GATED", aml_eval_err(), E_REGION_EC_GATED);
        eq("no access was counted", aml_region_accesses(), acc);
        eq("and the refusal was counted", aml_region_ec_gated(), gat + 1);
        /* 0xA5 is sitting at back[0]. A handler that read it would have
         * returned 0xA5 above. It returned 0 and said why. */

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("an EC write does NOTHING", aml_region_write_unit(b, 0, 1, 0x5A), 0);
        eq("EC_GATED", aml_eval_err(), E_REGION_EC_GATED);
        eq("the buffer is untouched", (uint64_t)back[0], 0xA5);
        eq("no access was counted", aml_region_accesses(), acc);

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("and so does a field read", aml_region_field_read(ecf0), 0);
        eq("EC_GATED", aml_eval_err(), E_REGION_EC_GATED);
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("and a field store", aml_region_field_store(ecf0, 0x5A), 0);
        eq("EC_GATED", aml_eval_err(), E_REGION_EC_GATED);
        eq("the buffer is still untouched", (uint64_t)back[0], 0xA5);

        /* ===============================================================
         * THE FLIP ASSERTION (#1065), RESOLVED BY R30.M7 (#1079).
         *
         * These two pinned the gate SHUT while no driver existed. The
         * driver now exists, so what they pin is the PRE-ATTACH state:
         * a supervisor that has not called aml_ec_attach gets a gate
         * that is still closed, still refuses, and still performs no
         * transaction. That is the posture of every process that parses
         * a table without owning the EC, and it is worth asserting for
         * exactly as long as such a process can exist.
         *
         * THIS TEST MUST RUN BEFORE ANY aml_ec_attach. Registration is a
         * system fact and deliberately survives aml_region_reset, so
         * there is no way back to this state once the driver attaches.
         * main() orders it accordingly; if that ordering is ever broken
         * these two fail and say so rather than passing vacuously.
         * =============================================================== */
        eq("NO EC BACKING IS REGISTERED — nothing has attached yet",
           aml_region_ec_backing(), 0);
        eq("AND NO EC TRANSACTION HAS EVER BEEN PERFORMED",
           aml_region_ec_hw_committed(), 0);

        /* The gated counter is per-session; the committed count is not. */
        aml_region_reset();
        eq("reset clears the session's gated count", aml_region_ec_gated(), 0);
        eq("but never the committed count",
           aml_region_ec_hw_committed(), 0);
        backing_free();
    });

    /* EC space is 256 bytes. */
    n = build_ec(f, 0x101);
    WITH_PARSE("region: an EC region larger than EC space is refused",
               f, n, {
        uint64_t rgn = nth_child(root, 0);
        uint8_t *back = backing_load(NULL, 0x200);
        aml_eval_reset(2);
        aml_region_reset();
        eq("refused", aml_region_bind(rgn, 7, 0, 0x200,
                                      (uint64_t)(uintptr_t)back), 0);
        eq("NOT_COVERED", aml_eval_err(), E_REGION_NOT_COVERED);
        eq("nothing bound", aml_region_count(), 0);
        backing_free();
    });
}

/* ====================================================================
 * R30.M7-001/002/003 (#1079 / #1080 / #1081) — THE EMBEDDED CONTROLLER.
 *
 * EVERY TEST BELOW RUNS AFTER test_region_ec_binds_but_does_not_transact,
 * AND THE ORDER IS LOAD-BEARING. aml_ec_attach registers a transaction
 * backing with aml_region, and that registration deliberately survives
 * aml_region_reset — it is a system fact, not a session one. So the
 * pre-attach assertions ("the gate is shut, nothing transacts") can only
 * be made before the driver attaches, exactly once, and they are made
 * there. Reordering main() would not make them fail silently: that test
 * asserts aml_region_ec_backing() == 0 on entry and says why.
 *
 * The synthetic EC is the same device gpe_io.pdx's GPE_IO_MODE_SYNTH is.
 * aml_ec_xact is byte-identical in both modes, so these are assertions
 * about the shipping transaction rather than about a test double of it.
 * The wedge modes exist because A TEST SUITE IN WHICH THE FAKE EC ALWAYS
 * ANSWERS PROVES NOTHING ABOUT THE PATH THAT MATTERS.
 * ==================================================================== */

enum {
    EC_ST_XACT_BUSY = 4,  EC_ST_EPISODE   = 5,  EC_ST_DEPTH    = 6,
    EC_ST_COMMITTED = 7,  EC_ST_GLK_IN    = 8,  EC_ST_GLK_OUT  = 9,
    EC_ST_ATTEMPTED = 10, EC_ST_Q_SEEN    = 11, EC_ST_Q_DISP   = 12,
    EC_ST_Q_ZERO    = 13, EC_ST_Q_NOMETH  = 14, EC_ST_TO_IBF   = 15,
    EC_ST_TO_OBF    = 16, EC_ST_STATUS    = 17, EC_ST_RANGE    = 18,
    EC_ST_REENT     = 19, EC_ST_DEPTH_REF = 20, EC_ST_UNBOUND  = 21,
    EC_ST_BADOP     = 22, EC_ST_LAST_Q    = 24, EC_ST_PROBE_RES = 26,
    /* R30.M8-001 (#1082). Transactions refused because the Global Lock
     * could not be taken -- the third term of the generalised balance
     * identity glk_enters + glk_denied == attempted. */
    EC_ST_GLK_DENIED = 28
};
enum { EC_OP_READ = 1, EC_OP_WRITE = 2 };
enum { EC_MODE_PORT = 0, EC_MODE_SYNTH = 1 };
enum { EC_WEDGE_NONE = 0, EC_WEDGE_IBF = 1, EC_WEDGE_OBF = 2,
       EC_WEDGE_STUCK_ADDR = 3 };
enum { EC_Q_NONE = 0, EC_Q_DISPATCHED = 1, EC_Q_NO_METHOD = 2 };
#define EC_FAIL 0xFFFFFFFFFFFFFFFFull

/* ── R30.M8-001 (#1082): the ACPI Global Lock ─────────────────────── */
enum {
    GLK_ST_DEPTH     = 5,  GLK_ST_ACQUIRES  = 6,  GLK_ST_RELEASES  = 7,
    GLK_ST_NEST_IN   = 8,  GLK_ST_NEST_OUT  = 9,  GLK_ST_RETRIES   = 10,
    GLK_ST_SIGNALS   = 11, GLK_ST_POLLS     = 12, GLK_ST_TIMEOUTS  = 13,
    GLK_ST_PENDING   = 14, GLK_ST_UNBOUND   = 15, GLK_ST_UNDERFLOW = 16,
    GLK_ST_DEPTH_REF = 17, GLK_ST_STUCK     = 18, GLK_ST_LAST_ERR  = 19,
    GLK_ST_ENTERS    = 20, GLK_ST_LEAVES    = 21, GLK_ST_CASES     = 22,
    GLK_ST_MAXDEPTH  = 23
};
enum { GLK_SMM_DONE = 3, GLK_SMM_STEPS = 4, GLK_SMM_SIGNAL = 5,
       GLK_SMM_BELLS = 7 };
enum { GLK_MODE_HW = 0, GLK_MODE_SYNTH = 1 };
enum { GLK_OWNED = 1, GLK_PENDING = 2 };
#define GLK_GUARD     0xF1A65ED5ull
#define GLK_TRY_STUCK 0xFFFFFFFFFFFFFFFFull

/* Error codes this module latches, continuing aml_ec.pdx's 68..75. */
enum { E_GLK_UNBOUND = 76, E_GLK_TIMEOUT = 77, E_GLK_UNDERFLOW = 78,
       E_GLK_DEPTH = 79, E_GLK_CAS_STUCK = 80 };

/* The EC device fixture, used by every query test.
 *
 *   Name(QCNT, 0)
 *   Device(EC0_) {
 *     OperationRegion(ECR_, EmbeddedControl, 0, 0x100)
 *     Field(ECR_, ByteAcc, NoLock, Preserve) { ECF0, 8 }
 *     Method(_Q00, 0) { Store(0x99, \QCNT) }   <- MUST NEVER RUN
 *     Method(_Q80, 0) { Store(ECF0, \QCNT) }   <- reads the EC from
 *                                                 inside the episode
 *   }
 *
 * _Q80's body is the reentrancy witness in one line: it performs an EC
 * OperationRegion read while the query episode that dispatched it is
 * still open. If the transaction claim were held across the dispatch,
 * this read would be refused and \QCNT would keep its old value.
 *
 * _Q00 exists to be NOT CALLED. Its body is observable for exactly that
 * reason — a fixture whose _Q00 did nothing could not tell "we correctly
 * declined to dispatch it" from "we dispatched it and it happened to be
 * a no-op".
 */
static size_t build_ec_device(uint8_t *out)
{
    size_t o = 0;

    /* Name(QCNT, 0) */
    out[o++] = 0x08; memcpy(out + o, "QCNT", 4); o += 4; out[o++] = 0x00;

    uint8_t body[192]; size_t k = 0;
    memcpy(body + k, "EC0_", 4); k += 4;

    /* OperationRegion(ECR_, EmbeddedControl, 0, 0x100) */
    body[k++] = 0x5B; body[k++] = 0x80;
    memcpy(body + k, "ECR_", 4); k += 4;
    body[k++] = 0x03;                                  /* EmbeddedControl */
    body[k++] = 0x0C; body[k++]=0; body[k++]=0; body[k++]=0; body[k++]=0;
    body[k++] = 0x0C; body[k++]=0x00; body[k++]=0x01; body[k++]=0; body[k++]=0;

    /* Field(ECR_, ByteAcc, NoLock, Preserve) { ECF0, 8 } */
    { uint8_t f[32]; size_t j = 0;
      memcpy(f + j, "ECR_", 4); j += 4; f[j++] = 0x01;  /* ByteAcc */
      memcpy(f + j, "ECF0", 4); j += 4; f[j++] = 8;
      body[k++] = 0x5B; body[k++] = 0x81; k += emit_pkg(body + k, f, j); }

    /* Method(_Q00, 0) { Store(0x99, \QCNT) } */
    { uint8_t m[32]; size_t j = 0;
      memcpy(m + j, "_Q00", 4); j += 4; m[j++] = 0x00;
      m[j++] = 0x70; m[j++] = 0x0A; m[j++] = 0x99;
      m[j++] = 0x5C; memcpy(m + j, "QCNT", 4); j += 4;
      body[k++] = 0x14; k += emit_pkg(body + k, m, j); }

    /* Method(_Q80, 0) { Store(ECF0, \QCNT) } */
    { uint8_t m[32]; size_t j = 0;
      memcpy(m + j, "_Q80", 4); j += 4; m[j++] = 0x00;
      m[j++] = 0x70; memcpy(m + j, "ECF0", 4); j += 4;
      m[j++] = 0x5C; memcpy(m + j, "QCNT", 4); j += 4;
      body[k++] = 0x14; k += emit_pkg(body + k, m, j); }

    out[o++] = 0x5B; out[o++] = 0x82; o += emit_pkg(out + o, body, k);
    return o;
}

/* Put the driver and the synthetic device in a known state. Deliberately
 * NOT a call to aml_ec_attach: the binding survives on purpose, and a
 * helper that re-attached every time would hide a driver that had lost
 * its ports. */
/* R30.M8-001 (#1082): the Global Lock is now REAL, so the EC fixture has
 * to supply one.
 *
 * This is not scaffolding added to keep old tests green — it is what
 * makes every EC test in this file stronger than it was. Before #1082,
 * aml_ec_glk_enter incremented a counter; the balance assertion below
 * was a statement about arithmetic. Now every one of these transactions
 * runs a genuine lock_cmpxchg_d against a FACS word, and the balance
 * assertion is a statement about a lock that is actually taken and
 * actually released.
 *
 * The lock is attached ONCE, alongside the EC's own attach, because a
 * platform has exactly one Global Lock and a supervisor that re-derived
 * its address per transaction would be a supervisor that could get a
 * different answer twice. */
static void glk_fresh(uint64_t initial)
{
    aml_glk_reset();
    aml_glk_mode_set(GLK_MODE_SYNTH);
    aml_glk_synth_reset(initial);
}

/* Same, plus a clean evaluation session.
 *
 * aml_eval_set_err is FIRST-WRITER-WINS by design (see aml_eval.pdx: the
 * code worth keeping is the one describing the original fault, not the
 * last consequence of it). That is right for evaluation and wrong for a
 * fixture: a code latched by an earlier test would mask the one this
 * test is about, and the assertion would silently be checking history.
 *
 * So the tests that assert a REFUSAL CODE start from a clean session.
 * They also cross-check aml_glk_stat(GLK_ST_LAST_ERR), which is this
 * module's own latch and is last-writer-wins — the two together assert
 * both that the right code was raised and that it reached the session. */
static void glk_fresh_clean(uint64_t initial)
{
    aml_eval_reset(2);
    glk_fresh(initial);
}

static void ec_fresh(uint64_t wedge)
{
    aml_ec_reset();
    aml_ec_mode_set(EC_MODE_SYNTH);
    aml_ec_synth_reset(wedge);
    glk_fresh(0);
}

/* The balance assertion the Global Lock seam exists for. Every attempted
 * transaction takes the seam exactly once and leaves it exactly once —
 * including every timeout exit. An implementation that acquires the real
 * lock and leaks it on a timeout fails HERE, in a test written before the
 * lock was.
 *
 * #1082 GENERALISED THIS RATHER THAN WEAKENING IT. A seam that could not
 * fail admitted the triple equality
 *
 *     glk_enters == glk_leaves == attempted
 *
 * A real lock can be refused, so the third term acquires the refusals:
 *
 *     glk_enters == glk_leaves                 (still exact)
 *     glk_enters + glk_denied == attempted
 *
 * On every fixture where the lock is obtainable — which is all of them
 * except the ones that deliberately arrange otherwise — glk_denied is 0
 * and the original triple equality is recovered EXACTLY, which is what
 * the two assertions below check in that order. The test passes because
 * the property still holds, not because it was relaxed to fit.
 *
 * The ownership depth is checked too: a non-zero depth after a completed
 * episode is a leaked hardware lock, which on a real machine is firmware
 * locked out of its own embedded controller until power-cycle. */
static void ec_glk_balanced(const char *where)
{
    g_checks++;
    if (aml_ec_stat(EC_ST_GLK_IN) != aml_ec_stat(EC_ST_GLK_OUT))
        fail(where);
    eq("the seam was entered once per attempted transaction",
       aml_ec_stat(EC_ST_GLK_IN) + aml_ec_stat(EC_ST_GLK_DENIED),
       aml_ec_stat(EC_ST_ATTEMPTED));
    eq("and the transaction claim is free",
       aml_ec_stat(EC_ST_XACT_BUSY), 0);
    eq("and no ownership of the Global Lock was leaked",
       aml_glk_depth(), 0);
    eq("and the FACS Flags word beside the lock is untouched",
       aml_glk_facs_guard(), GLK_GUARD);
}

/* =====================================================================
 * R30.M8-001 (#1082) — THE ACPI GLOBAL LOCK
 *
 * These run AFTER the EC block, because the EC block is where the lock
 * is attached and "nothing works before the attach" is an assertion that
 * can only be made once.
 *
 * WHAT THESE TESTS ARE FOR. The Global Lock arbitrates against System
 * Management Mode, which preempts everything and cannot be made to wait.
 * A fixture in which the lock word never changes underneath us proves
 * nothing whatever about the case the protocol exists for — it exercises
 * the arithmetic and skips the race. So the synthetic firmware here
 * MUTATES THE WORD BETWEEN OUR READ AND OUR WRITE, at the injection
 * point inside both compare-exchange loops, which is exactly where an
 * SMI is a correctness problem and nowhere else.
 * ===================================================================== */

/* The uncontended protocol: acquire sets Owned, release clears it, and
 * the word beside it is not disturbed. */
static void test_glk_acquire_and_release(void)
{
    g_case = "glk: the uncontended acquire/release cycle";
    glk_fresh(0);

    eq("the lock starts free", aml_glk_facs_word(), 0);
    eq("and nothing is owned", aml_glk_depth(), 0);

    eq("acquire succeeds", aml_glk_enter(), 1);
    eq("Owned is set", aml_glk_facs_word() & GLK_OWNED, GLK_OWNED);
    eq("and Pending is NOT — nobody else wanted it",
       aml_glk_facs_word() & GLK_PENDING, 0);
    eq("ownership depth is 1", aml_glk_depth(), 1);
    eq("the hardware lock was taken once", aml_glk_stat(GLK_ST_ACQUIRES), 1);
    eq("with no nesting", aml_glk_stat(GLK_ST_NEST_IN), 0);

    eq("release succeeds", aml_glk_leave(), 1);
    eq("the word is clear", aml_glk_facs_word(), 0);
    eq("depth is back to 0", aml_glk_depth(), 0);
    eq("the hardware lock was dropped once", aml_glk_stat(GLK_ST_RELEASES), 1);

    /* THE DOORBELL DID NOT RING, and that is as load-bearing as the
     * cases where it does. Nothing had marked Pending, so there is
     * nobody waiting to be told; a release that signalled unconditionally
     * would raise GBL_RLS at firmware on every EC transaction. */
    eq("and the doorbell stayed silent — nobody was waiting",
       aml_glk_stat(GLK_ST_SIGNALS), 0);

    /* THE 64-BIT MUTANT DETECTOR. lock_cmpxchg (64-bit) at FACS+0x10
     * read-modify-writes the Flags word at +0x14 as well, carrying it
     * through the acquire arithmetic and storing it back. */
    eq("the FACS Flags word at +0x14 was never touched",
       aml_glk_facs_guard(), GLK_GUARD);
}

/* THE DOORBELL. The single nastiest omission available in this module:
 * skip the GBL_RLS write and nothing here breaks — our counts balance,
 * our transactions complete — while the FIRMWARE waits forever for a
 * signal that never comes, and stops servicing what only it can service.
 * On the T14 G4 that includes thermal response. */
static void test_glk_release_rings_the_doorbell_iff_someone_waits(void)
{
    g_case = "glk: the release doorbell";

    /* Arrange for Pending: firmware already owns the lock, so our
     * acquire registers interest rather than taking it. */
    glk_fresh(GLK_OWNED);
    eq("try does NOT acquire — firmware holds it", aml_glk_try(), 0);
    eq("but our interest is now recorded in Pending",
       aml_glk_facs_word() & GLK_PENDING, GLK_PENDING);
    eq("and that was counted", aml_glk_stat(GLK_ST_PENDING), 1);

    /* Now stand in for firmware's own release of a pended lock: take the
     * lock legitimately from a state that carries Pending, then drop it.
     * The release must ring, because the value it replaces pends. */
    glk_fresh(GLK_OWNED | GLK_PENDING);
    eq("no doorbell yet", aml_glk_stat(GLK_ST_SIGNALS), 0);

    /* Drive the release path directly by asserting ownership: enter
     * observes Pending, cannot take it, and times out — so instead we
     * model the holder by seeding depth through a successful acquire on
     * a free lock whose word we then mark Pending, which is precisely
     * the state a concurrent requester leaves behind. */
    glk_fresh(0);
    eq("acquire a free lock", aml_glk_enter(), 1);
    /* A second party asks for it while we hold it. That is a compare-
     * exchange by someone else, and its whole effect is this bit. */
    aml_glk_smm_arm(1, GLK_PENDING);
    eq("release", aml_glk_leave(), 1);
    eq("THE DOORBELL RANG — firmware was told the lock is free",
       aml_glk_stat(GLK_ST_SIGNALS), 1);
    eq("and the synthetic PM1_CNT heard it",
       aml_glk_smm_stat(GLK_SMM_BELLS), 1);
    eq("the lock is free", aml_glk_facs_word(), 0);
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);
}

/* THE ADVERSARIAL FACS — the test the whole module exists for.
 *
 * Firmware writes the lock word between our read and our write. With
 * lock_cmpxchg_d our write FAILS, we retry, and we re-derive from what
 * firmware actually left. With a load/compute/store in its place, our
 * store lands on top of firmware's decision and it disappears — and
 * every other assertion in this file still passes.
 *
 * The three observables that distinguish them are all asserted below. */
static void test_glk_smm_interleaves_between_the_read_and_the_write(void)
{
    g_case = "glk: SMM mutates the lock word inside our read-modify-write";
    glk_fresh(0);

    /* The word is FREE when we read it. Between that read and our write,
     * firmware takes it. A correct acquire must not conclude it won. */
    aml_glk_smm_arm(1, GLK_OWNED);

    uint64_t r = aml_glk_try();

    eq("the injection point was reached",
       aml_glk_smm_stat(GLK_SMM_STEPS) >= 1, 1);
    eq("and firmware did interfere", aml_glk_smm_stat(GLK_SMM_DONE), 1);

    /* (1) THE COMPARE-EXCHANGE DETECTED IT. A blind store retries zero
     *     times, because a blind store cannot fail. */
    eq("THE COMPARE-EXCHANGE LOST ITS RACE AND RETRIED",
       aml_glk_stat(GLK_ST_RETRIES), 1);

    /* (2) WE DID NOT CLAIM A LOCK FIRMWARE HOLDS. This is the assertion
     *     that separates a correct implementation from one that returns
     *     "acquired" while SMM is mid-transaction on the EC. */
    eq("and we did NOT acquire it", r, 0);

    /* (3) FIRMWARE'S WRITE SURVIVED, and our Pending is on top of it.
     *     A lost update would read back as 1 (ours) rather than 3. */
    eq("firmware still owns it, and our interest is registered",
       aml_glk_facs_word(), GLK_OWNED | GLK_PENDING);

    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);
}

/* The same adversary, sustained: firmware interferes on several
 * consecutive passes. The loop must converge rather than either spin
 * forever or give up on the first collision. */
static void test_glk_sustained_interference_converges(void)
{
    g_case = "glk: sustained interference converges";
    glk_fresh(0);

    /* mask = Owned: firmware takes and drops the lock, over and over.
     * That is a TOGGLE, and a toggle is what makes sustained contention
     * expressible -- a constant store collides at most once, because the
     * second pass reads back the very value firmware keeps writing. */
    aml_glk_smm_arm(4, GLK_OWNED);
    uint64_t r = aml_glk_try();

    eq("four collisions were survived", aml_glk_stat(GLK_ST_RETRIES), 4);
    eq("and the lock was then acquired", r, 1);
    eq("exactly one compare-exchange landed",
       aml_glk_stat(GLK_ST_CASES), 1);
    eq("Owned is set", aml_glk_facs_word(), GLK_OWNED);
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);

    /* And the retry budget is a BOUND, not a hope: an adversary that
     * never relents produces a refusal rather than a livelock. */
    glk_fresh_clean(0);
    aml_glk_smm_arm(100000, GLK_OWNED);
    eq("an unrelenting adversary is refused", aml_glk_try(), GLK_TRY_STUCK);
    eq("with its own code", aml_glk_stat(GLK_ST_LAST_ERR), E_GLK_CAS_STUCK);
    eq("which reached the session", aml_eval_err(), E_GLK_CAS_STUCK);
    eq("and its own counter", aml_glk_stat(GLK_ST_STUCK), 1);
    eq("the retry budget bounded it", aml_glk_stat(GLK_ST_RETRIES), 1024);
    aml_glk_smm_arm(0, 0);
}

/* NESTING. AML acquires \_GL recursively; the hardware lock is taken at
 * 0->1 and dropped at 1->0 and at no other transition.
 *
 * An inner release that dropped the hardware lock would hand the EC to
 * firmware IN THE MIDDLE OF THE OUTER TRANSACTION, and the outer caller
 * would carry on driving registers it no longer owned. */
static void test_glk_nested_acquire_does_not_release_early(void)
{
    g_case = "glk: nested acquisition holds the hardware lock throughout";
    glk_fresh(0);

    eq("outer acquire", aml_glk_enter(), 1);
    eq("the hardware lock was taken", aml_glk_stat(GLK_ST_ACQUIRES), 1);
    eq("Owned", aml_glk_facs_word() & GLK_OWNED, GLK_OWNED);

    eq("inner acquire", aml_glk_enter(), 1);
    eq("depth 2", aml_glk_depth(), 2);
    eq("AND THE HARDWARE LOCK WAS NOT RE-TAKEN",
       aml_glk_stat(GLK_ST_ACQUIRES), 1);
    eq("the nesting path was taken", aml_glk_stat(GLK_ST_NEST_IN), 1);

    eq("innermost acquire", aml_glk_enter(), 1);
    eq("depth 3", aml_glk_depth(), 3);
    eq("still one hardware acquisition", aml_glk_stat(GLK_ST_ACQUIRES), 1);

    eq("innermost release", aml_glk_leave(), 1);
    eq("depth 2", aml_glk_depth(), 2);
    eq("AND THE HARDWARE LOCK WAS NOT DROPPED",
       aml_glk_stat(GLK_ST_RELEASES), 0);
    eq("WHICH MEANS OWNED IS STILL SET ON THE WIRE",
       aml_glk_facs_word() & GLK_OWNED, GLK_OWNED);

    eq("inner release", aml_glk_leave(), 1);
    eq("depth 1", aml_glk_depth(), 1);
    eq("still held", aml_glk_facs_word() & GLK_OWNED, GLK_OWNED);
    eq("the nesting release path was taken twice",
       aml_glk_stat(GLK_ST_NEST_OUT), 2);

    eq("outer release", aml_glk_leave(), 1);
    eq("depth 0", aml_glk_depth(), 0);
    eq("NOW the hardware lock is dropped", aml_glk_stat(GLK_ST_RELEASES), 1);
    eq("and the word is clear", aml_glk_facs_word(), 0);

    eq("acquires and releases balance", aml_glk_stat(GLK_ST_ACQUIRES),
       aml_glk_stat(GLK_ST_RELEASES));
    eq("as do the nesting counts", aml_glk_stat(GLK_ST_NEST_IN),
       aml_glk_stat(GLK_ST_NEST_OUT));
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);
}

/* Refusals, each with its own code, because they are different faults.
 * REFUSE, NEVER CLAMP — and never silently no-op, which for a lock is
 * the same thing as lying about holding it. */
static void test_glk_refusals_are_distinct_and_counted(void)
{
    g_case = "glk: refusals";

    /* UNDERFLOW. A release with nothing outstanding means some caller's
     * bracketing is broken, and the next hardware release would be
     * somebody else's. A no-op here would hide that until the day it
     * unlocked the EC under a live transaction. */
    glk_fresh_clean(0);
    eq("release with nothing held is REFUSED", aml_glk_leave(), 0);
    eq("with its own code", aml_glk_stat(GLK_ST_LAST_ERR), E_GLK_UNDERFLOW);
    eq("which reached the session", aml_eval_err(), E_GLK_UNDERFLOW);
    eq("and its own counter", aml_glk_stat(GLK_ST_UNDERFLOW), 1);
    eq("and the lock word was not touched", aml_glk_facs_word(), 0);
    eq("nor was any hardware release performed",
       aml_glk_stat(GLK_ST_RELEASES), 0);

    /* DEPTH. The bound is checked BEFORE the increment, so an overflow
     * can never be committed and then noticed. */
    glk_fresh_clean(0);
    for (int i = 0; i < 32; i++)
        eq("acquire within the bound", aml_glk_enter(), 1);
    eq("depth is at the bound", aml_glk_depth(), 32);
    eq("the 33rd is REFUSED", aml_glk_enter(), 0);
    eq("with its own code", aml_glk_stat(GLK_ST_LAST_ERR), E_GLK_DEPTH);
    eq("which reached the session", aml_eval_err(), E_GLK_DEPTH);
    eq("and its own counter", aml_glk_stat(GLK_ST_DEPTH_REF), 1);
    eq("AND THE DEPTH DID NOT MOVE", aml_glk_depth(), 32);
    for (int i = 0; i < 32; i++)
        eq("unwind", aml_glk_leave(), 1);
    eq("fully unwound", aml_glk_depth(), 0);
    eq("one hardware acquisition for the whole nest",
       aml_glk_stat(GLK_ST_ACQUIRES), 1);
    eq("and one hardware release", aml_glk_stat(GLK_ST_RELEASES), 1);
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);
}

/* THE BOUNDED WAIT. Firmware that never releases must produce a refusal,
 * not an unbounded wait — the discipline #1081 established for the EC's
 * IBF/OBF waits, with a DISTINCT code, because "firmware will not let
 * go" and "the EC did not answer" send an operator to different parts. */
static void test_glk_firmware_that_never_releases_is_refused(void)
{
    g_case = "glk: firmware that never releases produces a refusal";
    glk_fresh_clean(GLK_OWNED);
    aml_glk_smm_signal_after(0);          /* it never lets go */

    eq("the acquire is REFUSED", aml_glk_enter(), 0);
    eq("with the Global Lock's own timeout code",
       aml_glk_stat(GLK_ST_LAST_ERR), E_GLK_TIMEOUT);
    eq("which reached the session", aml_eval_err(), E_GLK_TIMEOUT);
    eq("and is NOT either EC timeout code",
       (uint64_t)(aml_eval_err() == 69 || aml_eval_err() == 70), 0);
    eq("and its own counter", aml_glk_stat(GLK_ST_TIMEOUTS), 1);
    eq("the wait was bounded", aml_glk_stat(GLK_ST_POLLS) >= 20000, 1);
    eq("NOTHING WAS ACQUIRED", aml_glk_depth(), 0);
    eq("no hardware acquisition was recorded",
       aml_glk_stat(GLK_ST_ACQUIRES), 0);
    /* Our interest IS registered, though — so when firmware eventually
     * does let go, its release will ring our doorbell. A refusal that
     * had also withdrawn Pending would leave us permanently unnotified. */
    eq("but our interest survived the refusal",
       aml_glk_facs_word() & GLK_PENDING, GLK_PENDING);
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);
}

/* The other half of the same path: firmware that DOES let go. A fixture
 * that only ever modelled firmware which never releases would leave the
 * successful wait — the ordinary case — completely unexercised. */
static void test_glk_wait_completes_when_firmware_releases(void)
{
    g_case = "glk: the wait completes when firmware releases";
    glk_fresh(GLK_OWNED);
    aml_glk_smm_signal_after(3);          /* it lets go on the third step */

    eq("the acquire eventually succeeds", aml_glk_enter(), 1);
    eq("it waited", aml_glk_stat(GLK_ST_POLLS) > 0, 1);
    eq("but not to the bound", aml_glk_stat(GLK_ST_POLLS) < 20000, 1);
    eq("no timeout was recorded", aml_glk_stat(GLK_ST_TIMEOUTS), 0);
    eq("we observed firmware's ownership on the way",
       aml_glk_stat(GLK_ST_PENDING) >= 1, 1);
    eq("and now hold it", aml_glk_depth(), 1);
    eq("Owned", aml_glk_facs_word() & GLK_OWNED, GLK_OWNED);

    eq("release", aml_glk_leave(), 1);
    eq("clear", aml_glk_facs_word(), 0);
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);
}

/* ==================================================================== */
/* R30.M9-002 (#1086) — DEATH WHILE HOLDING THE GLOBAL LOCK.            */
/*                                                                      */
/* The acpi_supervisor is a userspace process and a fault inside it is  */
/* ordinary. What is NOT ordinary is a fault taken while it holds the   */
/* ACPI Global Lock: the lock word lives in firmware-owned memory at    */
/* FACS+0x10, so a process that dies holding it leaves firmware waiting */
/* for a release that is never coming. On the T14 G4 the firmware side  */
/* owns thermal response, which makes a stranded lock not a hung        */
/* process but a machine that has stopped managing its own temperature. */
/*                                                                      */
/* aml_glk_abandon is the operation that gives it back. These fixtures  */
/* first make the hazard VISIBLE — a held lock really does leave the    */
/* Owned bit set — and then assert that abandon clears it, at every     */
/* nesting level, while keeping the balance identities true so that     */
/* "not stranded" is an assertion rather than an inspection.            */
/*                                                                      */
/* See design/acpi/crash-isolation.md §4.                               */
/* ==================================================================== */

/* THE HAZARD, DEMONSTRATED BEFORE IT IS ANSWERED.
 *
 * A test that only showed abandon working would leave open whether there
 * was ever anything to fix. So this holds the lock, does NOT release it,
 * and asserts the stranded state exists — Owned set, our depth non-zero,
 * and the hardware acquire/release counts UNBALANCED, which is what a
 * leak looks like from the outside. Only then is abandon called. */
static void test_glk_death_while_holding_strands_the_lock(void)
{
    g_case = "glk: dying while holding leaves the lock stranded";
    glk_fresh_clean(0);

    eq("we take the lock", aml_glk_enter(), 1);
    eq("and hold it", aml_glk_depth(), 1);

    /* This is the moment of death: no leave will ever be issued. */
    eq("FIRMWARE'S LOCK WORD STILL SAYS OWNED",
       aml_glk_facs_word() & GLK_OWNED, GLK_OWNED);
    /* Pin both counters rather than asserting the derived inequality.
     * `acquires == releases` is 1 == 0 here by construction and cannot
     * fail once the enter above is known to have succeeded, so it
     * carries no information; the individual values do — they would
     * catch an enter that double-counted its hardware acquire, which is
     * the accounting error that would later make abandon's balance
     * restoration look correct while being wrong. */
    eq("exactly one hardware acquire", aml_glk_stat(GLK_ST_ACQUIRES), 1);
    eq("and no release yet — this is the leak",
       aml_glk_stat(GLK_ST_RELEASES), 0);

    /* Now the successor surrenders it. */
    eq("abandon surrenders one level", aml_glk_abandon(), 1);
    eq("THE LOCK WORD IS CLEAR", aml_glk_facs_word(), 0);
    eq("we hold nothing", aml_glk_depth(), 0);
    eq("and the hardware counts balance again — not stranded",
       aml_glk_stat(GLK_ST_ACQUIRES), aml_glk_stat(GLK_ST_RELEASES));
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);
    eq("no error was latched", aml_eval_err(), AML_OK);
}

/* ONE HARDWARE RELEASE, HOWEVER DEEPLY WE NESTED.
 *
 * Nesting depth is our own bookkeeping; the hardware lock is held once.
 * An abandon that looped the hardware arm would, from its second pass,
 * be releasing a lock it no longer held — which is precisely what
 * aml_glk_leave's underflow refusal exists to catch. */
static void test_glk_abandon_surrenders_every_nesting_level(void)
{
    g_case = "glk: abandon surrenders every nesting level at once";
    glk_fresh_clean(0);

    eq("outermost", aml_glk_enter(), 1);
    eq("nested",    aml_glk_enter(), 1);
    eq("nested",    aml_glk_enter(), 1);
    eq("depth 3",   aml_glk_depth(), 3);
    eq("but only ONE hardware acquire", aml_glk_stat(GLK_ST_ACQUIRES), 1);

    eq("abandon reports all three levels", aml_glk_abandon(), 3);
    eq("depth 0", aml_glk_depth(), 0);
    eq("word clear", aml_glk_facs_word(), 0);

    /* Exactly one hardware release, matching the one acquire. */
    eq("one hardware release, not three", aml_glk_stat(GLK_ST_RELEASES), 1);
    eq("hardware balance", aml_glk_stat(GLK_ST_ACQUIRES),
                           aml_glk_stat(GLK_ST_RELEASES));

    /* THE NESTING IDENTITY SURVIVES TOO. The two inner levels are
     * credited to nested leaves; an abandon that forgot to account for
     * them would leave this identity broken in exactly the way a real
     * leak does, which would make it useless as a leak detector. */
    eq("nesting balance", aml_glk_stat(GLK_ST_NEST_IN),
                          aml_glk_stat(GLK_ST_NEST_OUT));

    eq("levels surrendered, last", aml_glk_abandon_stat(2), 3);
    eq("levels surrendered, total", aml_glk_abandon_stat(1), 3);
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);
}

/* HOLDING NOTHING IS NOT AN ERROR.
 *
 * aml_glk_leave answers depth 0 with AML_ERR_GLK_UNDERFLOW because a
 * release with nothing outstanding means a caller's bracketing is
 * broken. On a teardown path the same condition is the ORDINARY case:
 * most deaths do not happen inside the critical section. If abandon
 * latched a refusal every clean shutdown, an operator would learn to
 * ignore this code — and then ignore the one that mattered. */
static void test_glk_abandon_holding_nothing_is_not_an_error(void)
{
    g_case = "glk: abandon while holding nothing is silent";
    glk_fresh_clean(0);

    eq("we hold nothing", aml_glk_depth(), 0);
    eq("abandon surrenders nothing", aml_glk_abandon(), 0);
    eq("AND LATCHES NO ERROR", aml_eval_err(), AML_OK);
    eq("no underflow was counted", aml_glk_stat(GLK_ST_UNDERFLOW), 0);
    eq("this module's own latch is clean too",
       aml_glk_stat(GLK_ST_LAST_ERR), 0);
    eq("no hardware release was attempted", aml_glk_stat(GLK_ST_RELEASES), 0);
    eq("the lock word was not touched", aml_glk_facs_word(), 0);
    eq("but the call was counted", aml_glk_abandon_stat(0), 1);

    /* Contrast, in the same fixture, so the difference is on one screen:
     * the ORDINARY release path still refuses at depth 0. */
    eq("leave still refuses", aml_glk_leave(), 0);
    eq("with UNDERFLOW", aml_eval_err(), E_GLK_UNDERFLOW);
    eq("and counts it", aml_glk_stat(GLK_ST_UNDERFLOW), 1);
}

/* A dying process may be torn down more than once — a fault handler and
 * a supervisor sweep can both reach it. The second abandon must be a
 * no-op, not a second release of a lock somebody else may by then hold. */
static void test_glk_abandon_is_idempotent(void)
{
    g_case = "glk: a second abandon releases nothing";
    glk_fresh_clean(0);

    eq("hold it", aml_glk_enter(), 1);
    eq("first abandon", aml_glk_abandon(), 1);
    eq("one hardware release", aml_glk_stat(GLK_ST_RELEASES), 1);

    eq("SECOND ABANDON SURRENDERS NOTHING", aml_glk_abandon(), 0);
    eq("and issues no second hardware release",
       aml_glk_stat(GLK_ST_RELEASES), 1);
    eq("no error", aml_eval_err(), AML_OK);
    eq("word still clear", aml_glk_facs_word(), 0);
    eq("two calls counted", aml_glk_abandon_stat(0), 2);
    eq("but only one level ever surrendered", aml_glk_abandon_stat(1), 1);
}

/* THE DOORBELL IS NOT OPTIONAL ON THE DEATH PATH EITHER.
 *
 * If firmware registered Pending while we held the lock, it is parked
 * waiting for GBL_STS. Abandoning the lock without ringing the doorbell
 * clears the word and still leaves firmware asleep — the failure mode is
 * identical to not releasing at all, and it is quieter. */
static void test_glk_abandon_rings_the_doorbell_iff_someone_waits(void)
{
    g_case = "glk: abandon rings the doorbell when firmware is pending";
    glk_fresh_clean(0);

    eq("hold it", aml_glk_enter(), 1);
    uint64_t bells = aml_glk_smm_stat(GLK_SMM_BELLS);

    /* Firmware registers its interest while we hold the lock. */
    aml_glk_smm_arm(1, GLK_PENDING);
    aml_glk_smm_step();
    eq("firmware is now pending",
       aml_glk_facs_word() & GLK_PENDING, GLK_PENDING);

    eq("abandon", aml_glk_abandon(), 1);
    eq("THE DOORBELL RANG", aml_glk_smm_stat(GLK_SMM_BELLS), bells + 1);
    eq("word clear", aml_glk_facs_word(), 0);
    eq("guard intact", aml_glk_facs_guard(), GLK_GUARD);

    /* And the negative half: with nobody pending, no doorbell. A signal
     * on every release would be indistinguishable from a correct one
     * here, so both directions have to be asserted. */
    glk_fresh_clean(0);
    eq("hold it", aml_glk_enter(), 1);
    bells = aml_glk_smm_stat(GLK_SMM_BELLS);
    eq("abandon", aml_glk_abandon(), 1);
    eq("NO doorbell, because nobody was waiting",
       aml_glk_smm_stat(GLK_SMM_BELLS), bells);
}

/* NOT TESTED HERE, AND THE REASON IS STRUCTURAL, NOT AN OMISSION.
 *
 * aml_glk_abandon's unbound arm — the refusal when no FACS was ever
 * located — cannot be exercised at this point in the file. The binding
 * DELIBERATELY SURVIVES aml_glk_reset (see its justification: where the
 * FACS is is a system fact, not a per-session one), and there is no
 * detach operation, so "nothing is bound" is a ONE-SHOT observation. It
 * is spent by test_ec_refuses_before_it_is_attached, which must run
 * before the first attach and therefore long before this block.
 *
 * A test that re-attached in order to un-attach would be asserting
 * against a state the shipping code cannot enter. The arm itself is
 * byte-for-byte the shape of aml_glk_leave's unbound arm, which IS under
 * test; recorded here so the gap is visible rather than merely absent.
 */

static void test_ec_name_segment_construction(void)
{
    g_case = "ec: _Qxx name construction";
    /* Uppercase is not cosmetic: NameSegs compare as integers, so '_Q8a'
     * and '_Q8A' are different names and only one is declared. */
    eq("_Q00", aml_ec_query_seg(0x00), SEG4('_','Q','0','0'));
    eq("_Q80", aml_ec_query_seg(0x80), SEG4('_','Q','8','0'));
    eq("_Q0F", aml_ec_query_seg(0x0F), SEG4('_','Q','0','F'));
    eq("_QFF", aml_ec_query_seg(0xFF), SEG4('_','Q','F','F'));
    eq("_QA5", aml_ec_query_seg(0xA5), SEG4('_','Q','A','5'));
    eq("_Q10", aml_ec_query_seg(0x10), SEG4('_','Q','1','0'));
    /* The digit/letter boundary, from both sides. */
    eq("_Q09", aml_ec_query_seg(0x09), SEG4('_','Q','0','9'));
    eq("_Q0A", aml_ec_query_seg(0x0A), SEG4('_','Q','0','A'));
}

static void test_ec_refuses_before_it_is_attached(void)
{
    g_case = "ec: nothing transacts before aml_ec_attach";
    /* This runs while the driver is still unbound, which is the only
     * moment it can be observed. */
    ec_fresh(EC_WEDGE_NONE);
    eq("not bound yet", aml_ec_bound(), 0);

    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    uint64_t unb = aml_ec_stat(EC_ST_UNBOUND);
    eq("a read against no EC refuses", aml_ec_xact(EC_OP_READ, 0, 0), EC_FAIL);
    eq("UNBOUND", aml_eval_err(), E_EC_UNBOUND);
    eq("counted", aml_ec_stat(EC_ST_UNBOUND), unb + 1);
    eq("and no transaction was attempted", aml_ec_stat(EC_ST_ATTEMPTED), 0);
    eq("so the Global Lock seam was never taken", aml_ec_stat(EC_ST_GLK_IN), 0);

    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("and neither does a query pump", aml_ec_query_pump(), EC_FAIL);
    eq("UNBOUND", aml_eval_err(), E_EC_UNBOUND);
}

static void test_ec_transaction_round_trip(void)
{
    uint8_t f[256];
    size_t n = build_ec_device(f);
    WITH_PARSE("ec: a real transaction reads and writes the byte it named",
               f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t dev = nth_child(root, 1);
        uint64_t rgn = nth_child(dev, 0);

        /* THE ATTACH. Ports would come from the EC device's _CRS on real
         * hardware; the fixture supplies the conventional pair, and the
         * point of the parameter is that it is a parameter. */
        eq("attach", aml_ec_attach(dev, 0x62, 0x66), 1);
        eq("bound", aml_ec_bound(), 1);
        eq("THE #1065 GATE IS NOW OPEN", aml_region_ec_backing() != 0, 1);

        /* R30.M8-001 (#1082). THE GLOBAL LOCK ATTACH, and it belongs
         * beside the EC attach rather than inside ec_fresh: a platform
         * has ONE Global Lock, its address is a system fact, and a
         * fixture that re-derived it per test would be modelling a
         * supervisor that could get two different answers. aml_glk_reset
         * deliberately preserves this binding for the same reason
         * aml_ec_reset preserves the EC's ports.
         *
         * The synthetic FACS supplies the address; PM1_CNT and PM1_STS
         * take their conventional values. On hardware all three come
         * from the FADT (FIRMWARE_CTRL / PM1a_CNT_BLK / PM1a_EVT_BLK),
         * and the point of them being parameters is that they are
         * parameters -- see design/acpi/global-lock.md §6. */
        eq("the Global Lock refuses before it is attached",
           aml_glk_bound(), 0);
        eq("glk attach", aml_glk_attach(aml_glk_facs_addr(), 0x1804, 0x1800), 1);
        eq("glk bound", aml_glk_bound(), 1);
        glk_fresh(0);

        uint8_t *back = backing_load(NULL, 0x100);
        aml_eval_reset(2);
        aml_region_reset();
        uint64_t b = aml_region_bind(rgn, 7, 0, 0x100,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("EC region did not bind");

        ec_fresh(EC_WEDGE_NONE);
        aml_ec_ram_poke(0x00, 0x5A);
        aml_ec_ram_poke(0x01, 0xC3);
        aml_ec_ram_poke(0x2A, 0x77);

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        /* Both counts are LIFETIME claims — "this process has never
         * performed an EC transaction" — so they survive every reset and
         * every assertion here is a delta. */
        uint64_t hw = aml_region_ec_hw_committed();
        uint64_t dc = aml_ec_stat(EC_ST_COMMITTED);

        /* THE FLIP. #1065 pinned this at "produces nothing". */
        eq("an EC read returns the byte at that offset",
           aml_region_read_unit(b, 0x00, 1), 0x5A);
        eq("no error", aml_eval_err(), AML_OK);
        eq("and a different offset returns a different byte",
           aml_region_read_unit(b, 0x2A, 1), 0x77);
        eq("the neighbour is not what came back",
           aml_region_read_unit(b, 0x01, 1), 0xC3);

        eq("three transactions committed at the region layer",
           aml_region_ec_hw_committed(), hw + 3);
        eq("and at the driver layer", aml_ec_stat(EC_ST_COMMITTED), dc + 3);
        ec_glk_balanced("Global Lock seam unbalanced after three reads");

        /* THE BACKING BUFFER IS NOT THE EC. aml_region_bind wants a
         * non-zero host address and gets one, but an EmbeddedControl
         * access is a port handshake and must never touch it — a handler
         * that fell through to the memory path would have returned
         * whatever memset left there. */
        memset(back, 0xA5, 0x100);
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("the region's host buffer is not consulted",
           aml_region_read_unit(b, 0x00, 1), 0x5A);

        /* Writes. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t w = aml_ec_synth_writes();
        eq("an EC write completes", aml_region_write_unit(b, 0x40, 1, 0x3C), 1);
        eq("no error", aml_eval_err(), AML_OK);
        eq("the byte landed", aml_ec_ram_peek(0x40), 0x3C);
        eq("exactly one byte was written", aml_ec_synth_writes(), w + 1);
        eq("and the neighbour is untouched", aml_ec_ram_peek(0x41), 0);
        eq("the host buffer is still untouched", (uint64_t)back[0x40], 0xA5);

        /* ONE BYTE PER HANDSHAKE. A WordAcc EC field is a table bug, and
         * a direct wide unit access is refused rather than silently
         * turned into two transactions on a device where a read is not
         * free of side effects. */
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        uint64_t com = aml_ec_stat(EC_ST_COMMITTED);
        eq("a two-byte EC access produces nothing",
           aml_region_read_unit(b, 0x00, 2), 0);
        eq("ACCESS_WIDTH", aml_eval_err(), E_REGION_ACCESS_WIDTH);
        eq("and no transaction was performed",
           aml_ec_stat(EC_ST_COMMITTED), com);

        backing_free();
    });
}

static void test_ec_timeouts_refuse_rather_than_hang(void)
{
    g_case = "ec: a wedged EC produces a refusal, not a hang";

    /* ---- the input buffer never drains ---- */
    ec_fresh(EC_WEDGE_IBF);
    uint64_t dc = aml_ec_stat(EC_ST_COMMITTED);   /* lifetime; delta only */
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("a read against an EC that never clears IBF refuses",
       aml_ec_xact(EC_OP_READ, 0x10, 0), EC_FAIL);
    eq("TIMEOUT_IBF — its own code, not a generic failure",
       aml_eval_err(), E_EC_TIMEOUT_IBF);
    eq("counted as an IBF timeout", aml_ec_stat(EC_ST_TO_IBF), 1);
    eq("and NOT as an OBF timeout", aml_ec_stat(EC_ST_TO_OBF), 0);
    eq("nothing was committed", aml_ec_stat(EC_ST_COMMITTED), dc);
    ec_glk_balanced("the IBF timeout path leaked the Global Lock seam");

    /* THE CLAIM IS FREE AFTERWARDS. A timeout that leaked it would turn
     * one wedged transaction into a permanently dead EC path — the same
     * defect as no timeout at all, arriving one transaction later. */
    aml_ec_synth_reset(EC_WEDGE_NONE);
    aml_ec_ram_poke(0x10, 0x81);
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("and the NEXT transaction succeeds normally",
       aml_ec_xact(EC_OP_READ, 0x10, 0), 0x81);
    eq("no error", aml_eval_err(), AML_OK);

    /* ---- the output buffer never fills ---- */
    ec_fresh(EC_WEDGE_OBF);
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("a read against an EC that never sets OBF refuses",
       aml_ec_xact(EC_OP_READ, 0x10, 0), EC_FAIL);
    eq("TIMEOUT_OBF — distinguishable from the IBF case",
       aml_eval_err(), E_EC_TIMEOUT_OBF);
    eq("counted as an OBF timeout", aml_ec_stat(EC_ST_TO_OBF), 1);
    eq("and NOT as an IBF timeout", aml_ec_stat(EC_ST_TO_IBF), 0);
    ec_glk_balanced("the OBF timeout path leaked the Global Lock seam");

    /* A QUERY on a wedged EC must refuse for the same reason: the query
     * path is the one that runs at event time, when a hang is least
     * recoverable. */
    ec_fresh(EC_WEDGE_OBF);
    aml_ec_synth_query_set(0x80);
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("a query against a wedged EC refuses", aml_ec_query_pump(), EC_FAIL);
    eq("TIMEOUT_OBF", aml_eval_err(), E_EC_TIMEOUT_OBF);
    eq("and no query was counted as seen", aml_ec_stat(EC_ST_Q_SEEN), 0);
    eq("nor dispatched", aml_ec_stat(EC_ST_Q_DISP), 0);
    ec_glk_balanced("the query timeout path leaked the Global Lock seam");

    /* ---- the EC answers without consuming the address ---- */
    ec_fresh(EC_WEDGE_STUCK_ADDR);
    aml_ec_ram_poke(0x10, 0x42);
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("an inconsistent status produces NO VALUE",
       aml_ec_xact(EC_OP_READ, 0x10, 0), EC_FAIL);
    eq("STATUS — a third distinct cause", aml_eval_err(), E_EC_STATUS);
    eq("counted", aml_ec_stat(EC_ST_STATUS), 1);
    eq("and neither timeout counter moved",
       aml_ec_stat(EC_ST_TO_IBF) + aml_ec_stat(EC_ST_TO_OBF), 0);
    /* 0x42 was sitting in the output buffer. A handler that trusted OBF
     * alone would have returned it, and thermal code would have believed
     * a number the EC never answered with. */
    ec_glk_balanced("the status-refusal path leaked the Global Lock seam");
}

static void test_ec_out_of_range_is_refused_not_wrapped(void)
{
    g_case = "ec: an address outside EC space is refused";
    ec_fresh(EC_WEDGE_NONE);
    aml_ec_ram_poke(0x00, 0x11);

    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("address 256 is refused", aml_ec_xact(EC_OP_READ, 256, 0), EC_FAIL);
    eq("RANGE", aml_eval_err(), E_EC_RANGE);
    eq("counted", aml_ec_stat(EC_ST_RANGE), 1);

    /* THE ASSERTION THAT MATTERS. 256 & 0xFF is 0, and byte 0 holds
     * 0x11. A handler that masked instead of refusing would have
     * returned 0x11 and looked entirely correct. */
    g_checks++;
    if (aml_ec_xact(EC_OP_READ, 256, 0) == 0x11)
        fail("the address WRAPPED to 0 instead of being refused");

    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("and a far address is refused too",
       aml_ec_xact(EC_OP_READ, 0x10000, 0), EC_FAIL);
    eq("RANGE", aml_eval_err(), E_EC_RANGE);

    /* A REFUSED WRITE MUST NOT REACH THE DEVICE. This is the destructive
     * case: an EC write outside the range firmware declared can do things
     * no specification describes. */
    uint64_t w = aml_ec_synth_writes();
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("an out-of-range write is refused",
       aml_ec_xact(EC_OP_WRITE, 300, 0xFF), EC_FAIL);
    eq("RANGE", aml_eval_err(), E_EC_RANGE);
    eq("and NOTHING was written", aml_ec_synth_writes(), w);
    eq("byte 44 — 300 & 0xFF — is untouched", aml_ec_ram_peek(44), 0);

    /* The range refusals happen BEFORE the transaction claim is taken,
     * which is why the balance identity is over ATTEMPTED transactions
     * and not over calls. */
    eq("no transaction was attempted", aml_ec_stat(EC_ST_ATTEMPTED), 0);
    ec_glk_balanced("a refused address touched the Global Lock seam");

    /* Not a read and not a write. */
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("an unknown operation is refused", aml_ec_xact(7, 0, 0), EC_FAIL);
    eq("BAD_OP", aml_eval_err(), E_EC_BAD_OP);
    eq("counted", aml_ec_stat(EC_ST_BADOP), 1);
}

static void test_ec_reentrant_transaction_is_refused_outer_survives(void)
{
    g_case = "ec: a transaction inside a handshake is refused, and the "
             "outer one still completes";
    ec_fresh(EC_WEDGE_NONE);
    aml_ec_ram_poke(0x20, 0x6E);
    aml_ec_ram_poke(0x00, 0xDD);

    /* The probe fires from inside aml_ec_wait_ibf_clear — there is no
     * other way to be mid-handshake. */
    uint64_t dc = aml_ec_stat(EC_ST_COMMITTED);   /* lifetime; delta only */
    aml_ec_probe_arm(1);
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    uint64_t v = aml_ec_xact(EC_OP_READ, 0x20, 0);

    eq("THE NESTED ATTEMPT WAS REFUSED",
       aml_ec_stat(EC_ST_PROBE_RES), EC_FAIL);
    eq("as REENTRANT", aml_ec_stat(EC_ST_REENT), 1);

    /* AND THE OUTER TRANSACTION STILL COMPLETED, WITH THE RIGHT BYTE.
     * A reentrancy guard that poisoned the transaction it fired inside
     * would be worse than the bug it guards against: every EC access
     * would then depend on nothing else ever touching the EC. */
    eq("the outer read returned its own byte", v, 0x20 == 0x20 ? 0x6E : 0);
    eq("not the nested read's address-0 byte", v != 0xDD, 1);
    eq("one transaction committed, not two",
       aml_ec_stat(EC_ST_COMMITTED), dc + 1);
    ec_glk_balanced("the reentrant refusal disturbed the seam balance");

    /* The refusal left no residue. */
    aml_ec_probe_arm(0);
    aml_eval_reset(2);
    aml_eval_set_fuel(10000);
    eq("the next transaction is unaffected",
       aml_ec_xact(EC_OP_READ, 0x00, 0), 0xDD);
    eq("no error", aml_eval_err(), AML_OK);
}

static void test_ec_query_dispatch_reenters_the_ec(void)
{
    uint8_t f[256];
    size_t n = build_ec_device(f);
    WITH_PARSE("ec: _Qxx dispatch, and the _Qxx reads the EC from inside "
               "the episode", f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t qcnt = nth_child(root, 0);
        uint64_t dev  = nth_child(root, 1);
        uint64_t rgn  = nth_child(dev, 0);
        uint64_t q80  = nth_child(dev, 3);

        eq("attach", aml_ec_attach(dev, 0x62, 0x66), 1);

        /* Exact resolution in the EC's own scope — NOT the §5.3 upward
         * search, which would find an ancestor's _Q80 when this device
         * declares none and run the wrong device's handler. */
        eq("_Q80 resolves under the EC device",
           aml_eval_find_in_scope(dev, aml_ec_query_seg(0x80)), q80);
        eq("a query the table does not define resolves to nothing",
           aml_eval_find_in_scope(dev, aml_ec_query_seg(0x7E)), 0);

        uint8_t *back = backing_load(NULL, 0x100);
        aml_eval_reset(2);
        aml_region_reset();
        uint64_t b = aml_region_bind(rgn, 7, 0, 0x100,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("EC region did not bind");

        ec_fresh(EC_WEDGE_NONE);
        aml_ec_ram_poke(0x00, 0x4B);       /* what _Q80 will read */
        aml_ec_synth_query_set(0x80);

        aml_eval_reset(2);
        aml_eval_set_fuel(100000);
        uint64_t dc = aml_ec_stat(EC_ST_COMMITTED);   /* lifetime; delta */
        eq("QCNT starts at zero", aml_eval_read_named(qcnt), 0);

        /* ============ THE REENTRANT CASE ============
         * The pump issues QR_EC (one transaction), releases the claim,
         * then dispatches _Q80 — whose body performs an EC read (a
         * second transaction) while the episode is still open. If the
         * claim were held across the dispatch this would refuse and
         * QCNT would still be 0. */
        eq("a query was dispatched", aml_ec_query_pump(), EC_Q_DISPATCHED);
        eq("no error", aml_eval_err(), AML_OK);
        eq("_Q80 RAN AND READ THE EC FROM INSIDE THE EPISODE",
           aml_eval_read_named(qcnt), 0x4B);
        eq("two transactions: the query and the _Qxx's own read",
           aml_ec_stat(EC_ST_COMMITTED), dc + 2);
        eq("one query seen", aml_ec_stat(EC_ST_Q_SEEN), 1);
        eq("one dispatched", aml_ec_stat(EC_ST_Q_DISP), 1);
        eq("the query byte was recorded", aml_ec_stat(EC_ST_LAST_Q), 0x80);
        ec_glk_balanced("the query episode unbalanced the seam");

        /* THE EPISODE CLOSED. A dispatch that left the depth raised
         * would refuse every later query with QUERY_DEPTH after four
         * lid events, which is a machine that works for a while. */
        eq("the episode is closed", aml_ec_stat(EC_ST_EPISODE), 0);
        eq("and its depth is back to zero", aml_ec_stat(EC_ST_DEPTH), 0);
        eq("frames unwound", aml_eval_frames(), 0);

        /* ============ QUERY ZERO IS NOT A QUERY ============
         * The synthetic EC has already had its query byte consumed, so
         * the next QR_EC returns 0. _Q00 IS DEFINED in this fixture and
         * its body would set QCNT to 0x99. */
        aml_eval_reset(2);
        aml_eval_set_fuel(100000);
        uint64_t before = aml_eval_read_named(qcnt);
        eq("a second pump finds nothing pending",
           aml_ec_query_pump(), EC_Q_NONE);
        eq("no error", aml_eval_err(), AML_OK);
        eq("counted as a zero query", aml_ec_stat(EC_ST_Q_ZERO), 1);
        eq("NOT counted as a dispatch", aml_ec_stat(EC_ST_Q_DISP), 1);
        eq("_Q00 WAS NOT INVOKED", aml_eval_read_named(qcnt), before);
        g_checks++;
        if (aml_eval_read_named(qcnt) == 0x99)
            fail("_Q00 ran on a query byte of 0 — that event did not happen");

        /* ============ a query with no handler ============ */
        ec_fresh(EC_WEDGE_NONE);
        aml_ec_synth_query_set(0x7E);
        aml_eval_reset(2);
        aml_eval_set_fuel(100000);
        eq("an undeclared _Qxx is reported, not dispatched",
           aml_ec_query_pump(), EC_Q_NO_METHOD);
        eq("and is NOT an error — firmware need not define every query",
           aml_eval_err(), AML_OK);
        eq("counted separately from 'nothing pending'",
           aml_ec_stat(EC_ST_Q_NOMETH), 1);
        eq("no dispatch", aml_ec_stat(EC_ST_Q_DISP), 0);
        eq("the episode never opened", aml_ec_stat(EC_ST_DEPTH), 0);
        ec_glk_balanced("the no-method path unbalanced the seam");

        backing_free();
    });
}

/* R30.M8-DEBUG. aml_ec_query_pump's own QR_EC handshake calls
 * aml_ec_glk_enter exactly as aml_ec_xact does, but the call site was
 * left unchecked when #1082 landed: aml_ec_xact was gated with cmp/je
 * aml_ecx_glk, this one was not, and it fell straight through into the
 * handshake on a refusal -- the same defect class the #1082 commit
 * describes fixing, unfixed one call site over.
 *
 * The symptom is exactly the balance identity ec_glk_balanced checks:
 * a refused aml_ec_glk_enter does not bump GLK_IN, but the unconditional
 * aml_ec_glk_leave on every exit path still bumps GLK_OUT, so
 * GLK_IN == GLK_OUT fails whenever a query lands while firmware holds
 * the lock -- which no existing fixture arranged. */
static void test_ec_query_refused_when_glk_denied(void)
{
    uint8_t f[256];
    size_t n = build_ec_device(f);
    WITH_PARSE("ec: a query pump refuses rather than transacting against "
               "an EC firmware currently owns", f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t dev = nth_child(root, 1);

        eq("attach", aml_ec_attach(dev, 0x62, 0x66), 1);

        ec_fresh(EC_WEDGE_NONE);
        aml_ec_synth_query_set(0x80);

        /* Firmware holds the Global Lock and never lets go -- the same
         * setup test_glk_firmware_that_never_releases_is_refused uses
         * against aml_glk_enter directly, exercised here through the
         * QR_EC handshake instead. */
        glk_fresh(GLK_OWNED);
        aml_glk_smm_signal_after(0);

        aml_eval_reset(2);
        aml_eval_set_fuel(100000);
        uint64_t dc = aml_ec_stat(EC_ST_COMMITTED);
        uint64_t seen = aml_ec_stat(EC_ST_Q_SEEN);

        eq("the query pump refuses rather than issuing QR_EC",
           aml_ec_query_pump(), EC_FAIL);
        eq("with the Global Lock's own timeout code",
           aml_eval_err(), E_GLK_TIMEOUT);
        eq("NOT either EC timeout code",
           (uint64_t)(aml_eval_err() == 69 || aml_eval_err() == 70), 0);
        eq("no QR_EC transaction was ever committed",
           aml_ec_stat(EC_ST_COMMITTED), dc);
        eq("and no query byte was seen",
           aml_ec_stat(EC_ST_Q_SEEN), seen);
        ec_glk_balanced("a GLK-denied query pump unbalanced the seam");
    });
}

static void test_ec_direct_field_access_through_the_evaluator(void)
{
    uint8_t f[256];
    size_t n = build_ec_device(f);
    WITH_PARSE("ec: a FieldUnit over EC space is a real transaction",
               f, n, {
        eq("parse ok", aml_lex_err(), AML_OK);
        uint64_t dev = nth_child(root, 1);
        uint64_t rgn = nth_child(dev, 0);
        uint64_t ecf0 = nth_child(nth_child(dev, 1), 0);

        eq("attach", aml_ec_attach(dev, 0x62, 0x66), 1);

        uint8_t *back = backing_load(NULL, 0x100);
        aml_eval_reset(2);
        aml_region_reset();
        uint64_t b = aml_region_bind(rgn, 7, 0, 0x100,
                                     (uint64_t)(uintptr_t)back);
        g_checks++;
        if (b == 0) fail("EC region did not bind");

        ec_fresh(EC_WEDGE_NONE);
        aml_ec_ram_poke(0x00, 0x37);

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("a field read reaches the EC", aml_region_field_read(ecf0), 0x37);
        eq("no error", aml_eval_err(), AML_OK);

        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("a field store reaches the EC",
           aml_region_field_store(ecf0, 0x91), 1);
        eq("the byte landed", aml_ec_ram_peek(0x00), 0x91);
        eq("the host buffer was never touched", (uint64_t)back[0], 0);

        /* A WEDGED EC SEEN THROUGH THE FIELD LAYER. The refusal has to
         * survive the whole way up, or a thermal method would read a
         * plausible zero and act on it. */
        ec_fresh(EC_WEDGE_OBF);
        aml_eval_reset(2);
        aml_eval_set_fuel(10000);
        eq("a field read over a wedged EC produces nothing",
           aml_region_field_read(ecf0), 0);
        eq("and the reason survives to the top",
           aml_eval_err(), E_EC_TIMEOUT_OBF);

        backing_free();
    });
}

int main(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_segv;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_alarm;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, NULL);
    alarm(60);

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

    /* ---- R30.M2: the evaluator. The three termination guards come
     * first, because if any of them is broken the rest of this list
     * never runs — it hangs. ---- */
    test_eval_fuel_terminates_while_one();
    test_eval_depth_cap();
    test_eval_frame_pool_exhaustion();
    test_eval_frame_pool_api();
    test_eval_session_isolation();
    test_eval_refuses_a_failed_parse();

    test_eval_name_resolution();
    test_eval_name_resolution_refusals();
    test_eval_field_element_is_not_under_the_region();

    test_eval_frame_isolation_in_aml();
    test_eval_args_evaluated_in_caller_frame();
    test_eval_method_arguments();

    test_eval_if_else();
    test_eval_while_terminates_naturally();
    test_eval_break_leaves_the_loop();

    test_eval_named_store();
    test_eval_increment_decrement();
    test_eval_divide_two_destinations();

    test_eval_arithmetic();
    test_eval_integer_width_follows_revision();
    test_eval_operator_coverage();
    test_eval_name_contributing_kinds();

    /* ---- R30.M2-003/004: the object model, conversion, references ---- */
    test_obj_model();
    test_conv_table();
    test_conversions();
    test_concat_res_template();
    test_store_converts_to_the_destination_type();
    test_index_three_reference_kinds();
    test_uninitialised_package_element();
    test_cond_ref_of();
    test_arg_stores_through_a_reference();
    test_stale_frame_reference();
    test_eval_match();
    test_object_budgets();
    test_object_depth_cap();
    test_object_operator_coverage();

    /* ---- R30.M2-005/006/007: invocation, Notify, serialized methods.
     * The two that can HANG rather than fail — the unbounded Notify loop
     * and serialized self-recursion — are here rather than at the end, so
     * a regression in either shows up before the rest of the list has
     * spent its time. ---- */
    test_eval_argument_promotion();
    test_eval_object_argument_and_return();
    test_eval_return_tag_is_exact();
    test_eval_arity_cross_check();

    test_notify_target_table();
    test_notify_delivery();
    test_notify_refusals();
    test_notify_ring_drops();
    test_notify_unbounded_loop_terminates();

    test_serialized_acquire_balance();
    test_serialized_contention_across_contexts();
    test_serialized_recursion_does_not_deadlock();
    test_serialized_recursion_is_still_bounded();
    test_serialized_sync_level_ordering();
    test_serialized_pool_bound_and_leak_detection();

    /* ---- R30.M3-002: the SystemMemory address-space handler. The
     * security fixtures run FIRST, because if the capability check is
     * broken every later assertion in this block is measuring the wrong
     * thing. ---- */
    test_region_refused_without_a_capability();
    test_region_refused_beyond_its_capability();
    test_region_access_bounds();
    test_region_arithmetic_edges();
    test_region_unaligned_field_spanning_two_units();
    test_region_update_rules();
    test_region_access_width_is_honoured();
    test_region_boundary_refusals();
    test_region_table_is_bounded();
    test_region_fieldunit_store_is_real_now();

    /* ---- R30.M3-003/004/005: SystemIO, PCI_Config, EmbeddedControl ---- */
    test_region_space_boundary();
    test_region_systemio_port_bounds();
    test_region_systemio_widths();
    test_region_systemio_update_rule_access_counts();
    test_region_systemio_real_sentinel();
    test_region_pci_context_resolution();
    test_region_pci_context_refusals();
    test_region_pci_config_space_bounds();
    test_region_pci_access_is_the_memory_path();
    test_region_ec_binds_but_does_not_transact();

    /* ---- R30.M7-001/002/003: THE EMBEDDED CONTROLLER.
     *
     * ORDER IS LOAD-BEARING AND IS NOT A STYLE CHOICE. Everything above
     * this line runs with no EC driver attached, which is the only state
     * in which "the #1065 gate is shut" can be observed — aml_ec_attach
     * registers a transaction backing that deliberately survives
     * aml_region_reset. test_ec_refuses_before_it_is_attached is the
     * last observation of the unattached driver and must stay ahead of
     * the first attach for the same reason.
     *
     * Within the block, the wedge fixtures come before the query
     * fixtures: if the timeout path is broken the query tests would hang
     * rather than fail, and the harness's 60-second alarm is a worse
     * diagnostic than an assertion. ---- */
    test_ec_name_segment_construction();
    test_ec_refuses_before_it_is_attached();
    test_ec_transaction_round_trip();
    test_ec_timeouts_refuse_rather_than_hang();
    test_ec_out_of_range_is_refused_not_wrapped();
    test_ec_reentrant_transaction_is_refused_outer_survives();
    test_ec_query_dispatch_reenters_the_ec();
    test_ec_query_refused_when_glk_denied();
    test_ec_direct_field_access_through_the_evaluator();

    /* R30.M8-001 (#1082) — the ACPI Global Lock. AFTER the EC block,
     * which is where the lock is attached: "nothing works before the
     * attach" is an assertion that can only be made once. */
    test_glk_acquire_and_release();
    test_glk_release_rings_the_doorbell_iff_someone_waits();
    test_glk_smm_interleaves_between_the_read_and_the_write();
    test_glk_sustained_interference_converges();
    test_glk_nested_acquire_does_not_release_early();
    test_glk_refusals_are_distinct_and_counted();
    test_glk_firmware_that_never_releases_is_refused();
    test_glk_wait_completes_when_firmware_releases();

    /* R30.M9-002 (#1086) — death while holding the Global Lock.
     *
     * ON ORDERING. These five are self-contained: each opens with
     * glk_fresh_clean(0), which resets the evaluation session and the
     * lock state, so none depends on a predecessor. The hazard fixture
     * does hold the lock mid-body, but it abandons it and asserts
     * depth == 0 and a clear FACS word before returning.
     *
     * The one residue is in test_glk_abandon_holding_nothing_is_not_an_
     * error, which deliberately ends by calling aml_glk_leave() at
     * depth 0 to show the contrasting refusal — latching
     * E_GLK_UNDERFLOW into the first-writer-wins evaluator slot. That is
     * cleared by the next fixture's glk_fresh_clean, and nothing runs
     * after this block but the g_fail check. A fixture inserted AFTER
     * these that asserted on aml_eval_err() without resetting first
     * would read that underflow and be wrong about why. */
    test_glk_death_while_holding_strands_the_lock();
    test_glk_abandon_surrenders_every_nesting_level();
    test_glk_abandon_holding_nothing_is_not_an_error();
    test_glk_abandon_is_idempotent();
    test_glk_abandon_rings_the_doorbell_iff_someone_waits();

    if (g_fail) {
        fprintf(stderr, "[aml-corpus] %d assertion(s) failed out of %d\n",
                g_fail, g_checks);
        return 1;
    }
    alarm(0);
    printf("[aml-corpus] %d assertions PASS\n", g_checks);
    return 0;
}
