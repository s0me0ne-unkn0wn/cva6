# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Stage 1 gate: prove the M->S handoff via a JT-MAPPED eret. The guest sets mepc to a
# JT-ENCODED code address (2 = (idx0+1)*2, a PolkaVM jump target, NOT a PVM-pc) and executes
# `mret` with CSR_PVM_CFG2[36]=1; the HW must map mepc through the jump table (like a djump,
# JE = base + ((2>>1)-1)*z -> jumptable[0]) and redirect to the success block (prints '#').
# Without the JT-map the eret would use mepc[31:0]=2 directly -> a mid-instruction pc -> no '#'.
# Expect '#'. The JT (base/z) comes from the generator (-DJT_BASE/-DJT_Z); bit 36 = eret-via-jt.
#
# Privilege: the HOST sets mstatus.MPP = M (a guest mstatus write would flush younger uops).

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#ifndef CODE_LEN
#define CODE_LEN 20
#endif
#ifndef JT_BASE
#define JT_BASE 0
#endif
#ifndef JT_Z
#define JT_Z 1
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0            # host hypervisor hook (B4) -- survives a guest mtvec write
    csrw mtvec, t0                  # legacy fallback

    li   t0, 0x1800                # mstatus.MPP = M (bits 12:11 = 0b11)
    csrs mstatus, t0               # so the guest's mret returns to M-mode

    csrw CSR_PVM_CFG0, x0          # entry_pc = 0, code_base = 0
    li   t0, ((1 << 36) | ((JT_Z) << 32) | (JT_BASE))  # CFG2: jump table base/z + bit36 = eret-via-jt
    csrw CSR_PVM_CFG2, t0
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0          # enter PVM
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:                  # reached via CSR_PVM_VEC for ecalli (putchar) + final trap
    csrr x14, mcause
    li   x15, 11                   # ENV_CALL_MMODE -> host-call
    bne  x14, x15, pvm_done        # not a host-call -> final trap -> SUCCESS
    li   x15, 0x10000000           # ecalli #0 = putchar(r7 == x8)
    sb   x8, 0(x15)
    lbu  x14, 0x14(x15)            # serialize the MMIO store (mock_uart LSR read)
    csrw CSR_PVM_CFG1, x0
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15          # resume PVM at the post-ecalli pc
    j    wait_pvm

    .align 2
pvm_done:                          # final trap (via CSR_PVM_VEC) -> drain + SUCCESS
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
