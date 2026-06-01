# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# M3 demand-fetch gate: run the REAL add_numbers PolkaVM program with its image fetched
# from DRAM ON-DEMAND (via the dcache, port 0), NOT preloaded into img_bram. The image
# (hello_blob = code+pad+bitmask) is resident in DRAM as .text.init data; we point
# code_base at it and set CFG1[34]=fetch_from_dram. Same program/result as run-user: it
# uses the guest stack, host-calls #0, ret-halts; result a0 = 10+20+12 = 42 = '*',
# framed "[*]". Proves the JAM code is fetched live from DRAM (M3), not from BRAM.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#ifndef CODE_LEN
#define CODE_LEN 25
#endif
#define HALT_MAGIC 0xFFFF0000
#define GUEST_SP   0x80100000
#define THIRD      12
#define FETCH_DRAM (1 << 34)        /* CFG1[34]: fetch code/bitmask/jt from DRAM via dcache */

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la   t0, pvm_trap_handler
    csrw mtvec, t0
    # code_base = &user_blob (the image lives in DRAM as .text.init data; no CSR-load).
    la   t0, user_blob              # t0 = &user_blob (RV64E: only x0..x15, no t3/t4)
    slli a2, t0, 32                  # a2 = code_base << 32 (a2=x12, not a guest reg)
    csrw CSR_PVM_CFG0, a2            # entry_pc=0, code_base=&user_blob (DRAM addr)
    csrw CSR_PVM_CFG2, x0            # no jump table
    # seed guest registers (persist through the PVM-mode switch)
    li   x1, HALT_MAGIC              # ra (r0) = halt magic -> guest `ret` halts
    li   x2, GUEST_SP               # sp (r1) = DRAM stack top
    li   x8, 10                     # a0 (r7)
    li   x9, 20                     # a1 (r8)
    fence                           # ensure the image is visible to the fetch dcache reads
    li   t0, FETCH_DRAM | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0           # enter PVM in DRAM demand-fetch mode
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done
    csrr x14, mtval
    bnez x14, hc_resume
    li   x8, THIRD                  # host-call #0 -> a0 = get_third_number()
hc_resume:
    csrw CSR_PVM_CFG1, x0
    li   x15, FETCH_DRAM | (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15          # resume (keep DRAM-fetch mode)
    j    wait_pvm

pvm_done:
    li   x15, 0x10000000            # UART THR
    li   x14, '['
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    sb   x8,  0(x15)                # result
    lbu  x14, 0x14(x15)
    li   x14, ']'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    li   t2, 4000
1:  addi t2, t2, -1
    bnez t2, 1b
    li   t0, 1
    la   t1, tohost
    sd   t0, 0(t1)
done:
    j    done

    .include "hello_blob.S"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
