# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Stage 1 DRAM-path CONTROL: a plain dynamic jump (jump_ind) through the jump table, with the
# image demand-fetched from DRAM (CFG1[34]), NOT preloaded into img_bram. This is the A/B partner
# of loader_handoff_dram.S: same DRAM JT-read mechanism, but triggered by a DJUMP (br_resolved)
# instead of an ERET (eret_via_jt). On the FPGA, DJUMP+DRAM WORKS while ERET+DRAM fails -- so if
# this gate PASSES in sim and run-handoff-dram FAILS, the bug is isolated to the eret-specific
# JT-read sequencing (matching the FPGA triple-isolation), pointing the fix at pvm_front/pvm_fetch.
#
# Guest image = emit_djump_table: load_imm r2,2 ; jump_ind r2 -> jumptable[0] = TARGET (prints 'J')
# then trap. Expect 'J'.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define FETCH_DRAM   (1 << 34)
#ifndef CODE_LEN
#define CODE_LEN 12
#endif
#ifndef JT_OFF
#define JT_OFF 18
#endif
#ifndef JT_Z
#define JT_Z 1
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0
    csrw mtvec, t0

    lla  t0, djtab_blob
    slli a2, t0, 32
    csrw CSR_PVM_CFG0, a2           # entry_pc=0, code_base=&djtab_blob

    lla  t1, djtab_blob
    addi t1, t1, JT_OFF
    li   t2, ((JT_Z) << 32)         # jump table base/z; NO bit36 (this is a djump, not eret-via-jt)
    or   t1, t1, t2
    csrw CSR_PVM_CFG2, t1

    fence
    li   t0, FETCH_DRAM | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0           # enter PVM in DRAM demand-fetch mode
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done
    li   x15, 0x10000000            # ecalli #0 = putchar(r7 == x8)
    sb   x8, 0(x15)
    lbu  x14, 0x14(x15)
    csrw CSR_PVM_CFG1, x0
    li   x15, FETCH_DRAM | (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

    .align 2
pvm_done:
    li   t2, 4000
1:  addi t2, t2, -1
    bnez t2, 1b
    li   t0, 1
    lla  t1, tohost
    sd   t0, 0(t1)
done:
    j    done

    .include "djtab_dram_blob.S"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
