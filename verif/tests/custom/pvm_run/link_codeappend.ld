/* B2 code-append micro-test link map (CVA6 testharness: DRAM @ 0x80000000).
 *
 * Like link_opensbi.ld, the Verilator driver preloads ONLY the one PT_LOAD segment based at
 * 0x80000000, so everything lives in a SINGLE segment; the gap to the code region becomes zero
 * padding inside it (contiguous copy). The guest code-region (the appender + reserved append
 * space) is pinned at 0x80100000 so the appender can hard-encode absolute NC/bitmask store
 * addresses (a PVM guest has no `lla`); the loader sets CFG0.code_base to the same 0x80100000.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

PHDRS
{
  ph PT_LOAD FLAGS(7);   /* one RWX load segment for the whole image */
}

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) } :ph

  . = 0x80001000;
  .tohost : { *(.tohost) } :ph

  /* M3 demand-fetch code region: appender + pad + initial bitmask + reserved append space.
   * code_base = 0x80100000 (must equal CODE_APPEND_BASE in gen_pvm_img.py:emit_codeappend). */
  . = 0x80100000;
  .pvm_code : { *(.pvm_code) } :ph

  _end = .;

  /DISCARD/ : { *(.note.gnu.build-id) *(.riscv.attributes) *(.comment) }
}
