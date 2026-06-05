# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Sim copy of corev_apu/fpga/src/bootrom/pvm_boot.S (watchdog version), linked at
# DRAM for the harness, against the baked load_imm;trap image (PVM_BAKE harness,
# CODE_LEN=4). In sim the program's `trap` fires before the (long) watchdog, so
# pvm_done runs -> it prints 'D'+cause then "/DBG=<16 hex>" (the latched snapshot)
# and signals tohost. This validates the CSR_PVM_DBG latch captured the PVM run
# (active_cyc>0, valid_seen=1, issue_seen=1, issue_cnt>=1, commit_cnt>=1). The
# watchdog path (timer) is validated separately by wd_sim.S.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_DBG  0xbc3
#define PVM_CODE_LEN 4
#define UART_BASE    0x10000000
#define UART_LSR_OFF 0x14
#define LSR_THRE     0x20
#define CLINT_MTIME    0x0200bff8
#define CLINT_MTIMECMP 0x02004000
#define WD_TICKS     0x4000

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la   t0, pvm_trap_handler
    csrw mtvec, t0
    csrw CSR_PVM_CFG0, x0
    li   a0, 'E'
    call putc
    li   t0, CLINT_MTIME
    ld   t1, 0(t0)
    li   t2, WD_TICKS
    add  t1, t1, t2
    li   t0, CLINT_MTIMECMP
    sd   t1, 0(t0)
    li   t0, (1 << 7)
    csrs mie, t0
    li   t0, (1 << 3)
    csrs mstatus, t0
    csrw CSR_PVM_CFG1, x0
    li   t0, (1 << 32) | PVM_CODE_LEN
    csrw CSR_PVM_CFG1, t0
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:
    csrr x14, mcause
    bltz x14, pvm_watchdog
    li   x15, 11
    bne  x14, x15, pvm_done
    li   x15, UART_BASE
1:  lbu  x14, UART_LSR_OFF(x15)
    andi x14, x14, LSR_THRE
    beqz x14, 1b
    sb   x8, 0(x15)
    lbu  x14, UART_LSR_OFF(x15)
    csrw CSR_PVM_CFG1, x0
    li   x15, (1 << 33) | (1 << 32) | PVM_CODE_LEN
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

pvm_watchdog:
    li   x15, CLINT_MTIMECMP
    li   x14, -1
    sd   x14, 0(x15)
    li   a0, 'W'; call putc
    call print_dbg
    j    succeed

pvm_done:
    li   a0, 'D'; call putc
    andi a0, x14, 0xf
    li   t0, 10
    blt  a0, t0, 6f
    addi a0, a0, 0x57
    j    7f
6:  addi a0, a0, 0x30
7:  call putc
    call print_dbg
succeed:
    li   t0, 1
    la   t1, tohost
    sd   t0, 0(t1)
done:
    j    done

# print "/DBG=<16 hex>" of CSR_PVM_DBG. clobbers a0,t0,t1,x14,x15,ra. uses s0 for ra save.
print_dbg:
    mv   s0, ra
    li   a0, '/'; call putc
    li   a0, 'D'; call putc
    li   a0, 'B'; call putc
    li   a0, 'G'; call putc
    li   a0, '='; call putc
    csrr t1, CSR_PVM_DBG
    li   t0, 60
pl: srl  a0, t1, t0
    andi a0, a0, 0xf
    li   x15, 10
    blt  a0, x15, pd
    addi a0, a0, 0x57
    j    pp
pd: addi a0, a0, 0x30
pp: call putc
    addi t0, t0, -4
    bgez t0, pl
    li   a0, 0x0a; call putc
    mv   ra, s0
    ret

putc:
    li   x15, UART_BASE
9:  lbu  x14, UART_LSR_OFF(x15)
    andi x14, x14, LSR_THRE
    beqz x14, 9b
    sb   a0, 0(x15)
    lbu  x14, UART_LSR_OFF(x15)
    ret

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
