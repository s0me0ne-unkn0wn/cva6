# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# CSR-load the FULL ecalli banner (108 bytes, 7 BRAM words) into img_mem via
# CSR_PVM_IMG, then enter PVM -- the sim mirror of the FPGA bootrom's DRAM-load path
# (which CSR-loads the same 108 bytes). run-dram only loads 17 bytes; this exercises
# the byte-enable BRAM write + the read-FSM across multiple words at the banner's scale.
# Expect the full banner 'PolkaVM on CVA6!' on the UART.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_IMG  0xbc3
#define CODE_LEN     91
#define IMG_LEN      108

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la   t0, pvm_trap_handler
    csrw mtvec, t0
    # CSR-load img_mem[i] = banner_blob[i]   (i in 0..107)
    la   t0, banner_blob
    li   t1, 0
    li   t2, IMG_LEN
1:  bge  t1, t2, 2f
    add  a2, t0, t1
    lbu  a0, 0(a2)
    slli a1, t1, 8
    or   a1, a1, a0
    csrw CSR_PVM_IMG, a1
    addi t1, t1, 1
    j    1b
2:
    csrw CSR_PVM_CFG0, x0
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done
    csrr x14, mtval
    beqz x14, hc_putchar
    j    hc_resume
hc_putchar:
    li   x15, 0x10000000
    sb   x8, 0(x15)
    lbu  x14, 0x14(x15)
hc_resume:
    csrw CSR_PVM_CFG1, x0
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

pvm_done:
    li   t2, 4000
3:  addi t2, t2, -1
    bnez t2, 3b
    li   t0, 1
    la   t1, tohost
    sd   t0, 0(t1)
4:  j    4b

    .include "banner_blob.S"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
