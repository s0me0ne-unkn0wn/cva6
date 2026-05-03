/* startup_polkavm.S — JAM v1 hand-emitted startup blob
 *
 * Sub-phase 10: rewritten from RV64E assembly to JAM v1 bytecode.
 *
 * The startup sequence is four instructions:
 *
 *   load_imm   A0, 0            ; hart ID = 0 (single-hart PVM)
 *   load_imm   A1, <dtb_offset> ; A1 = device-tree pointer (patched by linker)
 *   load_imm64 A2, 0x80000000   ; A2 = DRAM base address
 *   jump_indirect A2, 0         ; jump to DRAM
 *
 * JAM v1 encoding reference (polkavm-common/src/program.rs ISA_JamV1):
 *
 *   load_imm  dst, imm32    opcode=0x04  format: [0x04][reg][imm32 LE 4B]
 *     - 1 byte opcode + 1 byte reg + 4 bytes imm = 6 bytes total
 *     - for imm=0: 1 byte opcode + 1 byte reg + 1 byte (varint 0) = 3 bytes
 *       (polkavm uses simple_varint so 0..=0x7F encodes in 1 byte)
 *
 *   load_imm64 dst, imm64  opcode=0x05  format: [0x05][reg][imm64 LE 8B]
 *     - 1 byte opcode + 1 byte reg + 8 bytes imm = 10 bytes total
 *
 *   jump_indirect base, off imm32
 *                            opcode=0x21 format: [0x21][reg][imm32 LE 4B]
 *     - for offset=0: [0x21][reg][0x00] = 3 bytes
 *
 * Register encoding (JAM v1 = same as polkavm-common Reg enum):
 *   A0 = 7,  A1 = 8,  A2 = 9
 *
 * NOTE: For the real bootrom build, this file is NOT assembled as RISC-V asm.
 *       It is a documentation artifact.  The actual JAM v1 blob is produced by:
 *         cargo run -p polkatool -- link -i jam_v1 elf -o bootrom.polkavm
 *       where the C sources (main.c etc.) have been ported to PVM-compatible C.
 *
 *       The hand-emitted byte sequence below documents the expected minimal
 *       startup blob for inspection and for the gen_pvm_rom.py self-test.
 *
 * ---------------------------------------------------------------------------
 * Hand-emitted JAM v1 minimal startup (20 bytes code + 3 bytes bitmask):
 *
 * Offset  Bytes         Instruction
 * ------  -----------   -----------------------------------------
 *  0x00   04 07 00      load_imm A0(7), 0         [opcode reg imm8=0]
 *  0x03   04 08 XX XX XX XX   load_imm A1(8), _dtb  [imm32 placeholder]
 *  0x09   05 09 00 00 00 80 00 00 00 00  load_imm64 A2(9), 0x80000000
 *  0x13   21 09 00      jump_indirect A2(9), 0
 *
 * Total code: 0x16 = 22 bytes
 *
 * Bitmask (one bit per code byte, LSB = byte 0):
 *   Opcode positions: 0, 3, 9, 19  (decimal)
 *   Bits set: 0,3,9,19
 *   byte 0: bit0=1(off0) bit1=0 bit2=0 bit3=1(off3) bit4=0 bit5=0 bit6=0 bit7=0 = 0x09
 *   byte 1: bit8=0 bit9=1(off9) bit10..15=0                                      = 0x02
 *   byte 2: bit16..18=0 bit19=1(off19) bit20..21=0 (padding)                     = 0x08
 *
 * So bitmask = [0x09, 0x02, 0x08]
 * ---------------------------------------------------------------------------
 *
 * For sub-phase 10 the actual compilation path is:
 *   riscv64-linux-gnu-gcc -march=rv64emac_zbb -mabi=lp64e -nostdlib \
 *       -nostartfiles -mno-relax -c src/main.c src/uart.c ... -o *.o
 *   riscv64-linux-gnu-gcc ... -Tlinker.lds *.o -o bootrom.elf
 *   cargo run -p polkatool -- link -i jam_v1 elf -o bootrom.polkavm bootrom.elf
 *   python3 gen_pvm_rom.py --in bootrom.polkavm \
 *       --out-code bootrom_code_64.sv --out-bitmask bootrom_bitmask_64.sv
 *
 * Phase 5 TODO: replace this documentation file with a proper polkavm
 * assembler source that polkatool can assemble directly.
 */

/* ---------------------------------------------------------------------------
 * Below is a minimal PVM asm source stub kept for reference.
 * It uses the polkavm assembler syntax for documentation purposes.
 * ---------------------------------------------------------------------------
 *
 * .global _start
 * _start:
 *     load_imm a0, 0
 *     load_imm a1, _dtb
 *     load_imm64 a2, 0x80000000
 *     jump_indirect a2, 0
 *
 * .section .dtb
 * .global _dtb
 * .align 4, 0
 * _dtb:
 * #if __riscv_xlen == 64
 *     .incbin "cv64a6.dtb"
 * #else
 *     .incbin "cv32a6.dtb"
 * #endif
 */
