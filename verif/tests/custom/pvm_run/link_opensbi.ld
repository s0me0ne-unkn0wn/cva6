/* B7 OpenSBI-on-PVM loader link map (CVA6 testharness: DRAM @ 0x80000000).
 *
 * IMPORTANT — the Verilator driver (corev_apu/tb/ariane_tb.cpp) preloads ONLY the ELF
 * segment whose paddr == 0x80000000 (it copies up to 0xFFFFFF bytes from that one section
 * into the main sram; any segment at a different paddr is silently dropped). So EVERYTHING
 * must live in a SINGLE PT_LOAD segment based at 0x80000000. We force that with one program
 * header (`ph`) and assign every section to it; the inter-region gaps become zero padding
 * inside that segment (the copy is contiguous from 0x80000000, so each region lands at its
 * intended DRAM address). Layout (offsets from ram_base=0x80000000):
 *   ro_data  -> 0x80010000  (guest 0x10000)   rw_init -> 0x80030000 (guest 0x30000)
 *   dtb      -> 0x80020000  (guest 0x20000, the free ro/rw gap; OpenSBI a1)
 *   code+bm  -> 0x80100000  (CFG0 code_base)  jt      -> 0x80200000 (CFG2 jt_base)
 * The loader's own M-mode .text.init sits at 0x80000000 (below the guest 0x10000 window).
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

  /* relocated guest RO data: guest 0x10000 -> phys 0x80010000 */
  . = 0x80010000;
  .pvm_ro : { *(.pvm_ro) } :ph

  /* staged devicetree blob: guest 0x20000 (the free ro/rw gap) -> phys 0x80020000.
   * OpenSBI's fw_platform_init reads the DTB through the aperture from a1=0x20000. */
  . = 0x80020000;
  .pvm_dtb : { *(.pvm_dtb) } :ph

  /* relocated guest RW init: guest 0x30000 -> phys 0x80030000 */
  . = 0x80030000;
  .pvm_rw : { *(.pvm_rw) } :ph

  /* M3 demand-fetch code region (code + pad + bitmask): code_base = 0x80100000 */
  . = 0x80100000;
  .pvm_code : { *(.pvm_code) } :ph

  /* jump table: CFG2 jt_base = 0x80200000 */
  . = 0x80200000;
  .pvm_jt : { *(.pvm_jt) } :ph

  _end = .;

  /DISCARD/ : { *(.note.gnu.build-id) *(.riscv.attributes) *(.comment) }
}
