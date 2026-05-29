/* Minimal linker script for the PVM Stage 3.2b loader (CVA6 testharness: DRAM @ 0x80000000). */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }

  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }

  . = ALIGN(0x1000);
  .text : { *(.text .text.*) }
  .data : { *(.data .data.*) }
  .bss  : { *(.bss .bss.*) *(COMMON) }

  _end = .;
}
