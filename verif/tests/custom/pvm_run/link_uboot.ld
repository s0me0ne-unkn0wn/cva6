/* U-Boot-on-PVM standalone-run loader link map (CVA6 testharness: DRAM @ 0x80000000).
 *
 * Like link_opensbi.ld, EVERYTHING lives in ONE PT_LOAD based at 0x80000000 because the
 * Verilator driver (corev_apu/tb/ariane_tb.cpp:332-348) preloads only the segment whose
 * paddr == 0x80000000 (copies up to 0xFFFFFF=16MB contiguously into the sram); inter-region
 * gaps become zero padding in that segment.
 *
 * U-Boot's PVM DATA layout (empirically decoded from `polkatool disassemble uboot.polkavm`):
 *   ro_data  guest 0x10000 (78616 B)  -> phys 0x80010000   (LSU aperture +0x80000000)
 *   guard    guest 0x30000..0x40000
 *   rw_data  guest 0x40000 (14816 init + bss to 0x4d338) -> phys 0x80040000 (aperture)
 *   stack    guest 0x80200000 (sp), gd 0x801f7ed0  -> phys identical (LSU pass-through:
 *            0x80200000 is already in DRAM, so the out-of-aperture identity map backs it).
 * The Harvard code/jump-table are physical DRAM regions read by the M3 demand-fetch /
 * CFG2.jt_base (NOT through the data aperture):
 *   code+bm  -> 0x80100000 (CFG0 code_base)   jt -> 0x80160000 (CFG2 jt_base)
 *   dtb      -> 0x80170000 (a1, pass-through)
 * A QUAD(0) at 0x801ffff8 forces the PT_LOAD filesz up to the stack top so the gd+stack
 * region [.., 0x80200000) is preloaded with zeros (no X-propagation on first stack reads).
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

  /* relocated guest RW init: guest 0x40000 -> phys 0x80040000 (bss zeroed by the loader) */
  . = 0x80040000;
  .pvm_rw : { *(.pvm_rw) } :ph

  /* M3 demand-fetch code region (code + pad + bitmask): code_base = 0x80100000 */
  . = 0x80100000;
  .pvm_code : { *(.pvm_code) } :ph

  /* jump table: CFG2 jt_base = 0x80160000 */
  . = 0x80160000;
  .pvm_jt : { *(.pvm_jt) } :ph

  /* staged devicetree blob: a1 = guest 0x80170000 (pass-through -> phys 0x80170000) */
  . = 0x80170000;
  .pvm_dtb : { *(.pvm_dtb) } :ph

  /* force the PT_LOAD filesz up to the stack top so gd (0x801f7ed0) + the early stack are
   * preloaded with zeros (deterministic; no uninitialized-sram reads in sim). */
  . = 0x801ffff8;
  .pvm_stacktop : { QUAD(0); } :ph

  _end = .;

  /DISCARD/ : { *(.note.gnu.build-id) *(.riscv.attributes) *(.comment) }
}
