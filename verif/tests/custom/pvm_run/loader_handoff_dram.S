# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Stage 1 DRAM-path reproducer: the M->S handoff via a JT-MAPPED eret, but with the image
# fetched from DRAM ON-DEMAND (CFG1[34]=fetch_from_dram, via the dcache) instead of preloaded
# into img_bram via +PVM_IMG. This is the FPGA/OpenSBI path -- the one where the handoff reaches
# the WRONG JT target ('!F' on board). The BRAM gate (run-handoff) PASSES, so this gate isolates
# the eret-via-jt x DRAM-demand-fetch interaction (the prime suspect, pvm_front D-FSM sequencing).
#
# Same guest image as run-handoff (emit_handoff_test): the guest sets mepc = a JT-ENCODED code
# address (2 = (idx0+1)*2, NOT a PVM-pc) and mret with CSR_PVM_CFG2[36]=1; the HW must map mepc
# through the jump table -> jumptable[0] = success block (prints '#'). Without the JT-map the eret
# uses mepc[31:0]=2 directly -> a mid-instruction pc -> 'X'/garbage/fault. Expect '#'.
#
# Differs from loader_handoff.S ONLY in the fetch source: code_base = &handoff_blob (a DRAM addr),
# jumptable_base = &handoff_blob + JT_OFF, and CFG1[34] set. mstatus.MPP=M is host-set (as before).

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define FETCH_DRAM   (1 << 34)        /* CFG1[34]: fetch code/bitmask/jt from DRAM via dcache */
#ifndef CODE_LEN
#define CODE_LEN 20
#endif
#ifndef JT_OFF
#define JT_OFF 35
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

    # code_base = &handoff_blob (the image lives in DRAM as .text.init data; demand-fetched).
    lla  t0, handoff_blob
    slli a2, t0, 32                # a2 = code_base << 32 (entry_pc = 0 in [31:0])
    csrw CSR_PVM_CFG0, a2          # entry_pc=0, code_base=&handoff_blob

    # CFG2: jumptable_base = &handoff_blob + JT_OFF (a DRAM byte addr), z<<32, bit36 = eret-via-jt.
    lla  t1, handoff_blob
    addi t1, t1, JT_OFF
    li   t2, ((1 << 36) | ((JT_Z) << 32))
    or   t1, t1, t2
    csrw CSR_PVM_CFG2, t1

    fence                          # ensure the blob is visible to the fetch dcache reads
    li   t0, FETCH_DRAM | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0          # enter PVM in DRAM demand-fetch mode
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
    li   x15, FETCH_DRAM | (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15          # resume PVM at the post-ecalli pc (keep DRAM-fetch mode)
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

    .include "handoff_dram_blob.S"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
