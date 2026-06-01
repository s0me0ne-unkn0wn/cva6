# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Phase-B/C gate: a multi-privilege PVM guest -- the OpenSBI-on-PVM core. The guest drops
# M->S via `mret` (Phase A redirect + privilege change), then a guest-internal `ecalli`@S
# traps to the guest's OWN mtvec (NOT the host) while STAYING in PVM (Phase B), reaching an
# M-mode handler that host-exits '#'. Prints '#' iff the whole privilege round-trip works;
# 'S' (no '#') iff the mret redirected but the privilege did not change to S.
#
# The HOST sets mstatus.MPP = S so the guest's mret drops to S WITHOUT the guest writing
# mstatus (a guest mstatus write would raise a pipeline flush that discards in-flight PVM
# uops -- deferred until a guest dynamically chooses its target privilege). The guest writes
# only mtvec/mepc (both flush-free). medeleg is left 0, so the guest ecalli@S delivers to M
# (mtvec), which is the guest's M-mode handler.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#ifndef CODE_LEN
#define CODE_LEN 28
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0            # host hypervisor hook (B4): services ecalli@M + the final trap

    li   t0, 0x800                 # mstatus.MPP = S (bits 12:11 = 0b01)
    csrs mstatus, t0               # so the guest's first mret drops to S-mode

    csrw CSR_PVM_CFG0, x0          # entry_pc = 0, code_base = 0
    csrw CSR_PVM_CFG2, x0          # no jump table
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0          # enter PVM (guest starts at M-mode)
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:                  # reached via CSR_PVM_VEC for ecalli@M (putchar) + final trap.
    csrr x14, mcause               # NOTE: the guest-internal ecalli@S does NOT arrive here --
    li   x15, 11                   # it stays in PVM and traps to the guest mtvec (Phase B).
    bne  x14, x15, pvm_done        # not ENV_CALL_M -> final trap -> SUCCESS
    li   x15, 0x10000000           # ecalli #0 = framed putchar '[' r7 ']' (r7 == x8)
    li   x14, '['
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)            # serialize each MMIO store (mock_uart LSR read)
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
