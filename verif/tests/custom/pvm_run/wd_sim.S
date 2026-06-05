# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Sim validation of the bring-up WATCHDOG mechanism (cont.14): arm a CLINT timer
# interrupt, spin, and in the handler read CSR_PVM_DBG and print "DBG=<16 hex>".
# No PVM is entered, so the snapshot must read 0xDB00000000000000 (magic + zeros).
# This exercises exactly the FPGA-critical chain: mtimecmp -> timer IRQ -> handler
# -> interrupt branch -> CSR_PVM_DBG read -> hex print. Expect: DBG=db00000000000000
# then *** SUCCESS ***.

#define CLINT_MTIME    0x0200bff8
#define CLINT_MTIMECMP 0x02004000
#define CSR_PVM_DBG  0xbc3

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la   t0, handler
    csrw mtvec, t0
    li   t0, CLINT_MTIME
    ld   t1, 0(t0)
    li   t2, 200
    add  t1, t1, t2
    li   t0, CLINT_MTIMECMP
    sd   t1, 0(t0)
    li   t0, (1 << 7)            # mie.MTIE
    csrs mie, t0
    li   t0, (1 << 3)            # mstatus.MIE
    csrs mstatus, t0
spin:
    j    spin

    .align 2
handler:
    csrr x14, mcause
    bgez x14, fail               # not an interrupt -> unexpected
    li   a0, 'D'; call putc
    li   a0, 'B'; call putc
    li   a0, 'G'; call putc
    li   a0, '='; call putc
    csrr t1, CSR_PVM_DBG
    li   t0, 60
hl: srl  a0, t1, t0
    andi a0, a0, 0xf
    li   x15, 10
    blt  a0, x15, hd
    addi a0, a0, 0x57
    j    hp
hd: addi a0, a0, 0x30
hp: call putc
    addi t0, t0, -4
    bgez t0, hl
    li   a0, 0x0a; call putc
    li   t0, 1                   # tohost = 1 -> SUCCESS
    la   t1, tohost
    sd   t0, 0(t1)
done:
    j    done
fail:
    li   t0, 3                   # exit code 1 -> FAIL
    la   t1, tohost
    sd   t0, 0(t1)
fdone:
    j    fdone

putc:
    li   x15, 0x10000000
pl: lbu  x14, 0x14(x15)
    andi x14, x14, 0x20
    beqz x14, pl
    sb   a0, 0(x15)
    lbu  x14, 0x14(x15)
    ret

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
