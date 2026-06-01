# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# B4 (goal C) gate: prove the PVM host-boundary exit is DECOUPLED from mtvec. A guest
# (mtvec-test) clobbers mtvec (csr_rw mtvec, 0x40) -- simulating OpenSBI installing its
# own trap vector -- then ecalli #0 (putchar '#'). The host hook lives in CSR_PVM_VEC
# (not mtvec). If B4 works, the ecalli reaches pvm_trap_handler via CSR_PVM_VEC and '#'
# prints. mtvec is set to a DECOY ('X') so a non-decoupled exit would print 'X' (or, with
# the guest clobber to 0x40, crash) -- '#' can ONLY appear via CSR_PVM_VEC. Expect '#'.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#ifndef CODE_LEN
#define CODE_LEN 13
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la   t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0            # B4: the host hypervisor hook -- NOT mtvec
    la   t1, mtvec_decoy
    csrw mtvec, t1                  # mtvec = decoy ('X'); the guest will clobber it anyway
    csrw CSR_PVM_CFG0, x0
    csrw CSR_PVM_CFG2, x0
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0           # enter PVM
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:                  # reached via CSR_PVM_VEC for ecalli + the final trap
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done         # not a host-call -> final trap -> SUCCESS
    csrr x14, mtval
    bnez x14, hc_resume             # only #0 used
    li   x15, 0x10000000            # #0 = putchar(r7 == x8)
    sb   x8, 0(x15)
    lbu  x14, 0x14(x15)
hc_resume:
    csrw CSR_PVM_CFG1, x0
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

    .align 2
mtvec_decoy:                       # if a host-boundary exit WRONGLY used mtvec -> 'X' (FAIL)
    li   x15, 0x10000000
    li   x14, 'X'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    li   t0, 1
    la   t1, tohost
    sd   t0, 0(t1)
8:  j    8b

pvm_done:                          # final trap (via CSR_PVM_VEC) -> drain + SUCCESS
    li   t2, 4000
1:  addi t2, t2, -1
    bnez t2, 1b
    li   t0, 1
    la   t1, tohost
    sd   t0, 0(t1)
done:
    j    done

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
