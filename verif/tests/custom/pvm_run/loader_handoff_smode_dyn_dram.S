# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# MOST faithful OpenSBI-handoff repro (DRAM demand-fetch): the GUEST sets mstatus.MPP=S itself
# (flush-class CSR write, B5-fenced) and THEN does a JT-mapped M->S mret -- exactly what
# sbi_hart_switch_mode does (csr_write MSTATUS; ... ; mret). Adds the one factor the other repros
# omit: a guest flush-class CSR write immediately upstream of the JT-mapped eret, on the DRAM path.
# Host does NOT pre-set MPP (unlike loader_handoff_smode_dram.S). Expect framed '[#]'.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define FETCH_DRAM   (1 << 34)
#ifndef CODE_LEN
#define CODE_LEN 36
#endif
#ifndef JT_OFF
#define JT_OFF 53
#endif
#ifndef JT_Z
#define JT_Z 1
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0            # host hypervisor hook: ecalli@M (putchar) + final trap
    csrw mtvec, t0

    # NOTE: host does NOT set mstatus.MPP -- the GUEST sets MPP=S itself (flush-class, fenced).

    lla  t0, handoff_sdyn_blob
    slli a2, t0, 32                # code_base << 32 (entry_pc = 0)
    csrw CSR_PVM_CFG0, a2          # entry_pc=0, code_base=&handoff_sdyn_blob

    lla  t1, handoff_sdyn_blob
    addi t1, t1, JT_OFF            # jumptable_base = &blob + JT_OFF (a DRAM byte addr)
    li   t2, ((1 << 36) | ((JT_Z) << 32))
    or   t1, t1, t2
    csrw CSR_PVM_CFG2, t1          # jt base/z + bit36 = eret-via-jt

    fence
    li   t0, FETCH_DRAM | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0          # enter PVM in DRAM demand-fetch mode (guest starts at M)
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done
    li   x15, 0x10000000           # ecalli #0 = framed putchar '[' r7 ']' (r7 == x8)
    li   x14, '['
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    sb   x8,  0(x15)
    lbu  x14, 0x14(x15)
    li   x14, ']'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    csrw CSR_PVM_CFG1, x0
    li   x15, FETCH_DRAM | (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15          # resume PVM at the post-ecalli pc (keep DRAM-fetch mode)
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

    .include "handoff_sdyn_dram_blob.S"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
