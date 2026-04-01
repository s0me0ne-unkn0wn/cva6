# Minimal RV64E bootrom for PolkaVM configuration
# Single-hart, M-mode only. Jumps directly to DRAM_BASE.
# Uses only x0-x15 (RV64E compliant).

#define DRAM_BASE 0x80000000

  .section .text.init
  .option norvc
  .globl _prog_start
_prog_start:
  csrr a0, mhartid        # a0 = hart ID (convention for boot)
  la   a1, _dtb            # a1 = pointer to device tree
  li   a2, 1
  slli a2, a2, 31          # a2 = 0x80000000 (works in both 32/64-bit)
  jr   a2                  # jump to DRAM

  .section .dtb
  .globl _dtb
  .align 4, 0
_dtb:
#if __riscv_xlen == 64
  .incbin "cv64a6.dtb"
#else
  .incbin "cv32a6.dtb"
#endif
