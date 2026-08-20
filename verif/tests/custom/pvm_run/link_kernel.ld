/* NOMMU-Linux-kernel-on-PVM standalone-run loader link map (CVA6 testharness: DRAM @ 0x80000000).
 *
 * Like link_uboot.ld, EVERYTHING lives in ONE PT_LOAD based at 0x80000000 because the Verilator
 * driver (corev_apu/tb/ariane_tb.cpp) preloads only the segment whose paddr == 0x80000000 (copies
 * up to 0xFFFFFF=16MB contiguously into the sram); inter-region gaps become zero padding (so the
 * kernel's bss gap [0x801a72cc,0x801df0d0) is preloaded zero, and head.S re-zeros it too).
 *
 * Kernel PVM DATA layout (computed from polkavm-common/abi.rs MemoryMapBuilder, page=0x10000):
 *   ro_data  guest 0x10000 (838656 B)  -> phys 0x80010000   (LSU aperture +0x80000000)
 *   guard    guest 0xE0000..0xF0000
 *   rw_data  guest 0xF0000  (750092 init + bss to 0x1df0d0) -> phys 0x800f0000 (aperture)
 *   stack    polkavm high 0xFFFE0000 -- NOT used (head.S sets its own sp from init_thread_union,
 *            a data symbol in rw -> guest 0xF0000+, inside the aperture).
 * The Harvard code/jump-table are physical DRAM regions read by the M3 demand-fetch / CFG2.jt_base
 * (NOT through the data aperture), placed ABOVE the 2MB aperture region [0x80010000,0x80200000) so
 * the kernel's ~2MB ro+rw+bss never collides with the code blob (U-Boot's code@0x80100000 would):
 *   code+bm  -> 0x80200000 (CFG0 code_base, 4.6MB)   jt -> 0x80700000 (CFG2 jt_base, 864KB)
 *   dtb      -> 0x80800000 (a1, pass-through)
 * Whole image spans [0x80000000, ~0x80803000) = ~8.4MB < 16MB sim preload.
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

  /* relocated guest RW init: guest rw_base -> phys 0x80000000+rw_base (bss zeroed by loader+head.S).
     rw_base = 0x10000 + align_up(RO,0x10000) + 0x10000-guard (abi.rs) -- image-dependent! Pass it as
     -Wl,--defsym,RW_VMA=<0x80000000+RW_BASE> (RW_BASE printed by opensbi_to_dram.py); the constant
     fallback matches the full-config kernel only and went stale twice (0xF0000/0x100000/0xC0000). */
  . = DEFINED(RW_VMA) ? RW_VMA : 0x80100000;
  .pvm_rw : { *(.pvm_rw) } :ph

  /* M3 demand-fetch code region (code + pad + bitmask): code_base = 0x80820000.
     Placed ABOVE the 8 MiB kernel-RAM aperture target [0x80010000,0x80810000) so the buddy/SLUB
     allocator (which now hands out LOW guest pages mapped here) never collides with the code blob.
     The gap [0x80010000+data, 0x80820000) is zero-padding in the single PT_LOAD (the buddy's free
     RAM, preloaded zero by the 16 MiB sim preload). */
  . = 0x80820000;
  .pvm_code : { *(.pvm_code) } :ph

  /* jump table: CFG2 jt_base = 0x80C00000 (above code, code is ~3.6 MiB) */
  . = 0x80C00000;
  .pvm_jt : { *(.pvm_jt) } :ph

  /* staged devicetree blob: a1 = guest 0x80D00000 (OUTSIDE the aperture -> pass-through -> phys
     0x80D00000). Whole image spans [0x80000000, ~0x80D01000) = ~13.4 MiB < 16 MiB sim preload. */
  . = 0x80D00000;
  .pvm_dtb : { *(.pvm_dtb) } :ph

  _end = .;

  /DISCARD/ : { *(.note.gnu.build-id) *(.riscv.attributes) *(.comment) }
}
