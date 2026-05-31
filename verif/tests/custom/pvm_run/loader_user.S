# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# A6: run a REAL compiled PolkaVM userspace program from DRAM. The image is the
# genuine `example-hello-world.polkavm` (built by the PolkaVM toolchain), run
# through `polkatool emit-image` + polkavm_to_img.py. Unlike the hand-emitted
# banner, this program USES THE STACK: it spills ra/s0 to [sp]/[sp+4], computes
# a1+a0, host-calls for a third number, adds it, reloads the frame, and `ret`s.
#
# The export 'add_numbers' computes  a0 = a0 + a1 + get_third_number().
# We seed a0=10, a1=20; host-call #0 returns 12  ->  a0 = 42 = '*'. The guest's
# `ret` is a djump to ra; we seed ra = the r0 halt magic (0xFFFF0000) so it halts
# cleanly into M-mode, where we putchar the result. Observing '*' proves the full
# stack store/load path (sp pointed into DRAM) + call/ret frame + host-call resume.
#
# Guest reg<->GPR: PVM r_n = x(n+1).  ra=r0=x1, sp=r1=x2, s0=r5=x6, a0=r7=x8,
# a1=r8=x9. Entering PVM keeps the GPRs (shared regfile), so the loader seeds them.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#ifndef CODE_LEN
#define CODE_LEN 25
#endif
#define HALT_MAGIC 0xFFFF0000
#define GUEST_SP   0x80100000        /* guest stack top: 1 MiB into DRAM, clear of the loader */
#define THIRD      12                /* get_third_number() result */

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la   t0, pvm_trap_handler
    csrw mtvec, t0

    # seed guest registers (persist through the PVM-mode switch)
    li   x1, HALT_MAGIC              # ra  (r0) = halt magic -> guest `ret` halts
    li   x2, GUEST_SP                # sp  (r1) = DRAM stack top
    li   x8, 10                      # a0  (r7) = 10
    li   x9, 20                      # a1  (r8) = 20

    csrw CSR_PVM_CFG0, x0            # entry_pc=0, code_base=0
    csrw CSR_PVM_CFG2, x0            # no jump table (ret targets are absolute)
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0            # enter PVM

wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done          # not a host-call -> final halt -> print result
    csrr x14, mtval                  # host-call number
    bnez x14, hc_resume              # only #0 ('get_third_number') is used
    li   x8, THIRD                   # a0 = get_third_number()
hc_resume:
    csrw CSR_PVM_CFG1, x0
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15           # resume guest
    j    wait_pvm

pvm_done:
    # guest halted via `ret` -> halt magic. Result is in a0 (x8) = 10+20+12 = 42 = '*'.
    # Frame it as "[<result>]" so the gate can tell the guest's byte apart from the
    # harness's own "*** SUCCESS ***" decoration. RVE: only x0..x15, use x14/x15.
    li   x15, 0x10000000             # UART THR
    li   x14, '['
    sb   x14, 0(x15)                 # putchar('[')
    lbu  x14, 0x14(x15)              # drain (uncached LSR read, 1-at-a-time)
    sb   x8,  0(x15)                 # putchar(a0) = result
    lbu  x14, 0x14(x15)              # drain
    li   x14, ']'
    sb   x14, 0(x15)                 # putchar(']')
    lbu  x14, 0x14(x15)              # drain
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
