/* Linker script for RV64EMAC bare-metal smoke tests
   Memory map matches CVA6 testharness: DRAM at 0x80000000 */

OUTPUT_FORMAT("elf64-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    dram (rwxai) : ORIGIN = 0x80000000, LENGTH = 0x100000
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text .text.*)
    } > dram

    .rodata : { *(.rodata .rodata.*) } > dram
    .data   : { *(.data .data.*)     } > dram

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } > dram

    _end = .;
}
