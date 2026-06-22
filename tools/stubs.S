/* tools/stubs.S — Phase-7-in-progress link stubs.
 *
 * paideia-as 0.6.0 doesn't yet emit named ELF symbols for top-level let-fn
 * bindings (the encoder uses a synthetic `add_one` placeholder for all of
 * them), so cross-file calls in the kernel surface as undefined PLT32
 * relocations. R_X86_64_PLT32 can't target absolute symbols, so we provide
 * real (empty) function bodies for the placeholders. Each is `ret` only.
 *
 * The kernel will return through these stubs on call — no UART output, no
 * real init — but the boot image links and QEMU loads it. Real symbol-export
 * lands in a later paideia-as phase.
 *
 * Add new lines here as more undefined symbols surface during integration.
 */
    .text
    .globl uart_init
    .type  uart_init, @function
    .globl uart_puts
    .type  uart_puts, @function
uart_init:
uart_puts:
    ret
    .size uart_init, .-uart_init
    .size uart_puts, .-uart_puts
