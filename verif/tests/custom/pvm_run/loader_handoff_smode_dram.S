# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# OpenSBI-handoff reproduction (DRAM demand-fetch path) -- the FULL FPGA condition: a JT-mapped
# eret that drops M->S, with the image fetched from DRAM on-demand (CFG1[34]) via the dcache, NOT
# preloaded into img_bram. This is exactly the OpenSBI M->S payload handoff that prints '!F' on
# the board. Guest = emit_handoff_smode: mtvec=Lh, mepc=JT-encoded target, mret w/ CFG2[36]=1 +
# MPP=S (host) -> JT-map mepc -> jumptable[idx]=Ls (S-entry) AND priv->S; ecalli@S -> guest mtvec
# Lh (M) -> host '#'. Expect framed '[#]'. IDX>0 makes the JT read a COLD cache MISS (FPGA cond).

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define FETCH_DRAM   (1 << 34)
#ifndef CODE_LEN
#define CODE_LEN 28
#endif
#ifndef JT_OFF
#define JT_OFF 36
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

    li   t0, 0x1800                # clear MPP
    csrc mstatus, t0
    li   t0, 0x800                 # mstatus.MPP = S (bits 12:11 = 0b01)
    csrs mstatus, t0               # so the guest's JT-mapped mret drops to S-mode

    lla  t0, handoff_smode_blob
    slli a2, t0, 32                # code_base << 32 (entry_pc = 0)
    csrw CSR_PVM_CFG0, a2          # entry_pc=0, code_base=&handoff_smode_blob

    lla  t1, handoff_smode_blob
    addi t1, t1, JT_OFF            # jumptable_base = &blob + JT_OFF (a DRAM byte addr)
    li   t2, ((1 << 36) | ((JT_Z) << 32))
    or   t1, t1, t2
    csrw CSR_PVM_CFG2, t1          # jt base/z + bit36 = eret-via-jt

    fence                          # ensure the blob is visible to the fetch dcache reads
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

    .include "handoff_smode_dram_blob.S"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
