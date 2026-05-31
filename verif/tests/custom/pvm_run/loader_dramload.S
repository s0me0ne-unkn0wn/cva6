# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# M1: prove a PolkaVM image runs from a RUNTIME-LOADED img_mem -- written by the
# M-mode loader through the CSR_PVM_IMG load port -- with NO baked ROM and NO
# +PVM_IMG/$readmemh preload. This is the precursor to fetching JAM code from DRAM:
# here the image is embedded in the loader's .rodata and streamed into img_mem byte
# by byte; the DRAM variant only changes the *source* of those bytes.
#
# Embedded image: load_imm r7,'#' ; ecalli #0 (putchar) ; trap  -> prints '#'.
# code_len=6, bitmask byte 0x29 at align16(6)=offset 16. RV64E: only x1..x15.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_IMG  0xbc3        /* write {addr<<8 | data} -> img_mem[addr] */
#define CODE_LEN     6

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la   t0, pvm_trap_handler
    csrw mtvec, t0

    # --- load img_mem via CSR_PVM_IMG: for i in 0..len-1: csrw IMG, (i<<8)|img[i] ---
    la   t0, pvm_img_data        # source bytes (in .rodata)
    li   t1, 0                   # index / dest addr
    li   t2, 17                  # byte count (= pvm_img_len: 6 code + 10 pad + 1 bitmask)
1:  bge  t1, t2, 2f
    add  a2, t0, t1
    lbu  a0, 0(a2)               # data byte
    slli a1, t1, 8               # addr << 8
    or   a1, a1, a0              # {addr, data}
    csrw CSR_PVM_IMG, a1         # img_mem[addr] = data
    addi t1, t1, 1
    j    1b
2:
    # --- enter PVM (the image is now resident in img_mem) ---
    csrw CSR_PVM_CFG0, x0        # entry_pc=0, code_base=0
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0        # rising edge of active -> run
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:
    csrr x14, mcause
    li   x15, 11                 # ENV_CALL_MMODE
    bne  x14, x15, pvm_done
    csrr x14, mtval              # host-call number
    beqz x14, hc_putchar         # #0 = putchar(a0)
    j    hc_resume
hc_putchar:
    li   x15, 0x10000000         # UART THR
    sb   x8, 0(x15)              # THR <- a0 (PVM r7)
    lbu  x14, 0x14(x15)          # serialize (drain store buffer)
hc_resume:
    csrw CSR_PVM_CFG1, x0
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15       # resume PVM
    j    wait_pvm

pvm_done:
    li   t2, 4000                # drain the UART tail
3:  addi t2, t2, -1
    bnez t2, 3b
    li   t0, 1
    la   t1, tohost
    sd   t0, 0(t1)              # SUCCESS
4:  j    4b

    # NB: keep the image bytes in .text.init -- link.ld only loads .text.init/.tohost,
    # so an orphan .rodata would not be loaded by the testharness (lbu would read junk).
    .section .text.init,"ax",@progbits
    .align 3
pvm_img_data:
    .byte 0x33, 0x07, 0x23      # load_imm r7, '#'           @0
    .byte 0x0a, 0x00            # ecalli #0 (putchar)        @3
    .byte 0x00                  # trap                       @5
    .byte 0,0,0,0,0,0,0,0,0,0   # pad code_len(6)..bitmask(16)
    .byte 0x29                  # opcode bitmask: starts {0,3,5} @16
pvm_img_len = . - pvm_img_data

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
