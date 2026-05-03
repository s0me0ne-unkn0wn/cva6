# start sequence of the bootloader
#
# PVM port (sub-phase 10):
#   - csrr a0, mhartid replaced with li a0, 0 (single-hart)
#   - smp_pause/smp_resume are no-ops (MULTI_HART not defined)
#   - .polkavm_exports metadata added for polkatool entry detection
#
#include <smp.h>
#define DRAM_BASE 0x80000000

/* PolkaVM export metadata — required by polkatool link to find the entry point */
  .pushsection .metadata,"",@progbits
_entry_point_name:
    .asciz "main"
_entry_point_name_end:
_pvm_metadata:
    .byte  1                                                  /* version */
    .word  0                                                  /* flags */
    .word  _entry_point_name_end - _entry_point_name - 1     /* name length */
    .quad  _entry_point_name                                  /* name ptr */
    .byte  0                                                  /* input regs */
    .byte  0                                                  /* output regs */
  .popsection

  .pushsection .polkavm_exports,"R",@note
    .byte  1              /* entry count */
    .quad  _pvm_metadata  /* pointer to metadata */
    .quad  _prog_start    /* pointer to code */
  .popsection

  .section .text.init
  .option norvc
  .globl _prog_start
_prog_start:
  smp_pause(s1, a2)
  li sp, 0x84000000
  call main
  smp_resume(s1, a2)
  # PVM port (sub-phase 10): csrr a0, mhartid replaced with constant 0
  # (single-hart; CSR instructions rejected by polkatool JAM v1 linker)
  li a0, 0
  la a1, _dtb
  li s1, DRAM_BASE
  jr s1

  .section .dtb
  .globl _dtb
  .align 4, 0
_dtb:
#if __riscv_xlen == 64
  .incbin "cv64a6.dtb"
#else
  .incbin "cv32a6.dtb"
#endif
