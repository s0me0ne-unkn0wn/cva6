# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# PolkaVM bootrom entry (FPGA). Called from main() after the UART is up and
# "Hello World!" / "Entering PolkaVM..." have printed. Enters PVM mode running the
# image baked into pvm_front.img_mem (the `ecalli` banner 'PolkaVM on CVA6!\r\n',
# CODE_LEN=91), services each `ecalli #0` as putchar via the real apb_uart, resumes
# the guest (host-call model, graypaper D4), and spins on the program's final trap.
#
# RV64E: only x1..x15. PVM r0..r12 map to x1..x13 (incl. sp/gp/tp), so while PVM
# runs the guest owns the stack -- the trap handler is therefore pure assembly,
# touching only x14/x15, and the final trap spins rather than returning to C.
#
# IMPORTANT: use `lla` (NOT `la`) for the handler address. This bootrom is built
# PIE, so `la` would load it from the GOT -- whose R_RISCV_RELATIVE reloc a bare-
# metal boot never applies, leaving 0 -> mtvec=0 -> every PVM trap redirects to
# address 0 and hangs. `lla` is PC-relative (auipc+addi), no GOT. (See phase log
# cont.14: this single bug caused a 9-build FPGA bring-up saga.)

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define PVM_CODE_LEN 91             /* baked ecalli banner 'PolkaVM on CVA6!\r\n' */
#define UART_BASE    0x10000000     /* ariane_soc::UARTBase (apb_uart THR @ +0) */
#define UART_LSR_OFF 0x14           /* line status register (reg 5, 4-byte stride) */
#define LSR_THRE     0x20           /* LSR bit 5: transmit holding register empty */

    .section .text,"ax",@progbits
    .globl pvm_boot
pvm_boot:
    lla  t0, pvm_trap_handler       # PC-relative (see header: NOT `la`)
    csrw mtvec, t0
    csrw CSR_PVM_CFG0, x0           # entry_pc=0, code_base=0
    csrw CSR_PVM_CFG1, x0           # clear -> clean 0->1 edge on the next write
    li   t0, (1 << 32) | PVM_CODE_LEN
    csrw CSR_PVM_CFG1, t0           # rising edge of active -> enter PVM
wait_pvm:
    # busy-loop (NOT wfi): keep the pipeline live so PVM uops flow through issue.
    j    wait_pvm

    .align 2
pvm_trap_handler:
    # ecalli (opcode 10) -> mcause = ENV_CALL_MMODE (11): service + resume.
    # trap   (opcode 0)  -> mcause = ILLEGAL_INSTR (2): program done -> spin.
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done
    # --- host-call #0 = putchar(PVM r7 == x8), flow-controlled for the real UART -
    li   x15, UART_BASE
1:  lbu  x14, UART_LSR_OFF(x15)      # wait for THR empty (FIFO space)
    andi x14, x14, LSR_THRE
    beqz x14, 1b
    sb   x8, 0(x15)                  # THR <- char
    lbu  x14, UART_LSR_OFF(x15)      # uncached LSR read drains the store buffer
    # --- resume the guest after the ecalli ----------------------------------
    csrw CSR_PVM_CFG1, x0            # clear-pulse (spaces the re-entry)
    li   x15, (1 << 33) | (1 << 32) | PVM_CODE_LEN   # resume | active | code_len
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

pvm_done:
    j    pvm_done                    # banner (incl. trailing CRLF) printed; halt
