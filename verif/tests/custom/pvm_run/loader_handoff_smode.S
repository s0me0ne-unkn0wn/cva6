# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# OpenSBI-handoff reproduction (BRAM path): a JT-mapped eret that ALSO drops M->S. Unlike
# loader_handoff.S (mret M->M), the host sets mstatus.MPP=S so the guest's JT-mapped mret drops
# to S-mode -- the EXACT OpenSBI handoff (M-mode OpenSBI -> S-mode payload via JT-mapped mret).
# The guest (emit_handoff_smode): mtvec=Lh, mepc=JT-encoded target, mret w/ CFG2[36]=1 -> the HW
# maps mepc through the jump table -> jumptable[idx]=Ls (S-entry) AND priv->S; at Ls an ecalli@S
# stays in PVM and traps to the guest mtvec=Lh (M handler) -> host '#'. Expect framed '[#]'.
# This isolates [JT-mapped eret] x [M->S priv drop]; the BRAM partner of loader_handoff_smode_dram.S.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#ifndef CODE_LEN
#define CODE_LEN 28
#endif
#ifndef JT_BASE
#define JT_BASE 36
#endif
#ifndef JT_Z
#define JT_Z 1
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0            # host hypervisor hook: services ecalli@M (putchar) + final trap
    csrw mtvec, t0                  # legacy fallback

    li   t0, 0x1800                # clear MPP
    csrc mstatus, t0
    li   t0, 0x800                 # mstatus.MPP = S (bits 12:11 = 0b01)
    csrs mstatus, t0               # so the guest's JT-mapped mret drops to S-mode

    csrw CSR_PVM_CFG0, x0          # entry_pc = 0, code_base = 0 (BRAM image)
    li   t0, ((1 << 36) | ((JT_Z) << 32) | (JT_BASE))  # CFG2: jt base/z + bit36 = eret-via-jt
    csrw CSR_PVM_CFG2, t0
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0          # enter PVM (guest starts at M-mode)
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:                  # reached via CSR_PVM_VEC for ecalli@M (putchar) + final trap.
    csrr x14, mcause               # the guest-internal ecalli@S does NOT arrive here (stays in PVM).
    li   x15, 11
    bne  x14, x15, pvm_done        # not ENV_CALL_M -> final trap -> SUCCESS
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
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15          # resume PVM at the post-ecalli pc
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

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
