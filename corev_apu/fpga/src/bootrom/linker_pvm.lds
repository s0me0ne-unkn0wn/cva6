/* linker_pvm.lds — PolkaVM JAM v1 compatible linker script for bootrom.
 *
 * Differences from linker.lds:
 *   - polkavm-linker re-layouts sections; origin is a placeholder.
 *   - /DISCARD/ removes sections polkatool doesn't understand.
 *   - .polkavm_exports note section preserved (polkatool entry detection).
 *   - .dtb input section merged into .rodata so _dtb is a valid RO symbol.
 *
 * Sub-phase 10.
 */

OUTPUT_FORMAT("elf64-littleriscv")
OUTPUT_ARCH(riscv)
ENTRY(_prog_start)

MEMORY
{
    ram (rwxai) : ORIGIN = 0x00010000, LENGTH = 0x2000000
}

SECTIONS
{
    .text.init : {
        *(.text.init)
    } > ram

    .text : ALIGN(0x100) {
        _TEXT_START_ = .;
        *(.text .text.*)
        _TEXT_END_ = .;
    } > ram

    /* Merge the device tree blob into .rodata so polkatool classifies
     * references to _dtb as valid RO data accesses. */
    .rodata : ALIGN(0x100) {
        _RODATA_START_ = .;
        *(.rodata .rodata.*)
        /* DTB goes here — _dtb symbol is defined by startup.S .section .dtb */
        *(.dtb .dtb.*)
        _RODATA_END_ = .;
    } > ram

    .data : ALIGN(0x100) {
        _DATA_START_ = .;
        *(.data .data.*)
        _DATA_END_ = .;
    } > ram

    PROVIDE(_data     = ADDR(.data));
    PROVIDE(_data_lma = LOADADDR(.data));
    PROVIDE(_edata    = .);

    .bss : ALIGN(0x100) {
        _BSS_START_ = .;
        *(.bss .bss.*)
        *(COMMON)
        _BSS_END_ = .;
    } > ram

    /* PolkaVM metadata and exports — required by polkatool for entry detection */
    .metadata : {
        *(.metadata)
    } > ram

    .polkavm_exports : {
        *(.polkavm_exports)
    } > ram

    /DISCARD/ : {
        *(.comment)
        *(.note.gnu.build-id)
        *(.note.ABI-tag)
        *(.eh_frame .eh_frame_hdr)
    }
}
