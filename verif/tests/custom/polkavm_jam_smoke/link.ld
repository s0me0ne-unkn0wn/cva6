/* Linker script for PolkaVM JAM smoke test.
 * polkavm-linker re-layouts sections into its own address space,
 * so the origin here is a placeholder; -fPIE + --emit-relocs
 * lets the linker patch all pointers at link time. */

OUTPUT_FORMAT("elf64-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ram (rwxai) : ORIGIN = 0x00010000, LENGTH = 0x100000
}

SECTIONS
{
    .text : {
        *(.text .text.*)
    } > ram

    .rodata : { *(.rodata .rodata.*) } > ram

    .data : { *(.data .data.*) } > ram

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } > ram

    /* polkavm metadata sections — kept as NOTE sections so the linker sees them */
    .metadata : { *(.metadata) } > ram

    _end = .;

    /* Discard everything the polkavm-linker doesn't need */
    /DISCARD/ : {
        *(.comment)
        *(.gnu.*)
        *(.note.gnu.*)
        *(.eh_frame*)
    }
}
