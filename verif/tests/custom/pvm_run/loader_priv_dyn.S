# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# B5 gate (flush-safe guest CSR write): identical to loader_priv.S EXCEPT the HOST does NOT
# set mstatus.MPP -- the GUEST sets mstatus.MPP=S itself (a flush-class CSR write that B5's
# csr-fence makes safe). This is the path a REAL OpenSBI takes (it picks its own mret target
# privilege). A guest write to mstatus raises flush_o in csr_regfile; without B5 that flush
# discards the YOUNGER in-flight PVM uop (the mret right after) -> the eret never commits and
# pvm_fetch hangs (no '['). With B5, pvm_fetch fences at the mstatus write, lets it commit
# ALONE, then resumes -- so the round-trip still prints '[#]'.
#
# The guest writes mstatus/mtvec/mepc itself; medeleg is left 0, so the guest ecalli@S
# delivers to M (mtvec), the guest's M-mode handler. Prints '[#]' iff the whole round-trip
# works (B5 fence + mret redirect + priv->S + ecalli@S stays in PVM + redirect to guest tvec).

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#ifndef CODE_LEN
#define CODE_LEN 36
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0            # host hypervisor hook (B4): services ecalli@M + the final trap

    # NOTE: unlike loader_priv.S, the host does NOT set mstatus.MPP here. The GUEST sets
    # mstatus.MPP=S itself (flush-class CSR write, fenced by B5) before its first mret.

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
