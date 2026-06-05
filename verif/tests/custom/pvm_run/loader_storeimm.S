# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# store_imm RTL bug gate loader. Runs a PVM guest (at M-mode) that exercises the
# store_imm 2-uop macro with a >16-bit immediate (low 16 bits zero) to a non-zero
# offset, loads it back, and host-calls (ecalli #0) to putchar the verification
# byte. The handler frames it as "[<a0>]" so the gate reads the guest byte apart
# from the harness's own decoration; '[#]' (0x23) iff every full-width store kept
# its high bits. The guest's final `trap` exits SUCCESS via tohost.
#
# Guest reg<->GPR: PVM r_n = x(n+1). r1=x2 (base ptr into DRAM), r7=x8 (a0/result).
# The guest stays at M-mode (the entry privilege), so its DRAM stores (0x8xxxxxxx,
# masked into DRAM by the LSU) are legal -- the same path run-user proves.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#ifndef CODE_LEN
#define CODE_LEN 43
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0            # host hypervisor hook: services ecalli@M (putchar) + final trap

    csrw CSR_PVM_CFG0, x0           # entry_pc = 0, code_base = 0
    csrw CSR_PVM_CFG2, x0           # no jump table
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0           # enter PVM (guest at M-mode)
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:                  # ecalli@M (putchar) + final trap
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done         # not ENV_CALL_M -> final trap -> SUCCESS
    li   x15, 0x10000000            # ecalli #0 = framed putchar '[' a0 ']' (a0 == x8)
    li   x14, '['
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)             # serialize each MMIO store (mock_uart LSR read)
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
pvm_done:                          # final trap -> drain + SUCCESS
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
