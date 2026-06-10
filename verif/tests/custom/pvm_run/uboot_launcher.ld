OUTPUT_ARCH("riscv")
ENTRY(_start)
PHDRS { ph PT_LOAD FLAGS(7); }
SECTIONS {
  . = 0x80400000;
  .text.init : { *(.text.init) } :ph
  . = 0x80401000;
  .tohost : { *(.tohost) } :ph
  /DISCARD/ : { *(.pvm_ro) *(.pvm_rw) *(.pvm_code) *(.pvm_jt) *(.pvm_dtb) *(.note*) *(.riscv.attributes) *(.comment) }
}
