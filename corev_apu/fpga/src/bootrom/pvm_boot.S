# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# PolkaVM bootrom entry (FPGA). Called from main() after the UART is up and
# "Hello World!" / "Entering PolkaVM..." have printed. Runs a REAL compiled
# PolkaVM userspace program from DRAM (A6): the genuine example-hello-world.polkavm
# export 'add_numbers' (built by the PolkaVM toolchain, NOT a hand-emitted banner).
# It USES THE GUEST STACK -- spills ra/s0 to [sp]/[sp+4] with sp pointing into DRAM
# -- which only works because the LSU masks PVM data addresses to the 32-bit guest
# space (the guest's add_imm_32 sign-extends a DRAM pointer's bit 31). The program
# computes a0 = a0 + a1 + get_third_number() = 10 + 20 + 12 = 42 = '*'; on its
# ret-to-halt-magic the host prints "[*]". This stages the JAM image ROM->DRAM->
# img_mem via CSR_PVM_IMG (M1/M2), seeds the guest regs, enters PVM, services the
# one host-call, and prints the framed result on the program's final trap.
#
# RV64E: only x1..x15. PVM r0..r12 map to x1..x13. While PVM runs the guest owns
# its registers; the handler is pure asm touching only x12..x15. The final trap
# spins (never returns to C), so clobbering sp/ra here is fine.
#
# IMPORTANT: use `lla` (NOT `la`) for the handler address. This bootrom is built
# PIE, so `la` would load it from the GOT -- whose R_RISCV_RELATIVE reloc a bare-
# metal boot never applies, leaving 0 -> mtvec=0 -> every PVM trap hangs. `lla` is
# PC-relative (auipc+addi), no GOT. (See phase log cont.14: a 9-build saga.)

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_IMG  0xbc3          /* write {addr<<8 | byte} -> img_mem[addr] (M1 load port) */
#define PVM_IMG_LEN  36             /* add_numbers image: 25 code + 7 pad + 4 bitmask */
#define PVM_CODE_LEN 25             /* |c| of the add_numbers export */
#define HALT_MAGIC   0xFFFF0000     /* r0 init: guest `ret` djumps here -> clean halt */
#define GUEST_SP     0x80100000     /* guest stack top: 1 MiB into DRAM (blob @0x8000_0000, C sp @0x8400_0000) */
#define THIRD        12             /* get_third_number() result */
#define UART_BASE    0x10000000     /* ariane_soc::UARTBase (apb_uart THR @ +0) */
#define UART_LSR_OFF 0x14           /* line status register (reg 5, 4-byte stride) */
#define LSR_THRE     0x20           /* LSR bit 5: transmit holding register empty */

    .section .text,"ax",@progbits
    .globl pvm_boot
pvm_boot:
    lla  t0, pvm_trap_handler       # PC-relative (see header: NOT `la`)
    csrw mtvec, t0
    # --- stage the JAM image ROM -> DRAM -> img_mem (M1/M2 load path) ----------
    li   t1, 1
    slli t1, t1, 31                 # t1 = DRAM base 0x80000000 (positive, no sext)
    lla  t0, user_blob              # ROM source (PC-relative, NOT GOT)
    li   t2, PVM_IMG_LEN
    li   a3, 0                      # index
3:  add  a2, t0, a3
    lbu  a0, 0(a2)                  # ROM byte
    add  a1, t1, a3
    sb   a0, 0(a1)                  # -> DRAM
    addi a3, a3, 1
    blt  a3, t2, 3b
    li   a3, 0
4:  add  a2, t1, a3
    lbu  a0, 0(a2)                  # DRAM byte (read-back)
    slli a1, a3, 8
    or   a1, a1, a0                 # {addr<<8 | byte}
    csrw CSR_PVM_IMG, a1            # -> img_mem[addr]
    addi a3, a3, 1
    blt  a3, t2, 4b
    # --- seed the guest registers (persist through the PVM-mode switch) --------
    li   x1, HALT_MAGIC             # ra (r0) = halt magic -> guest `ret` halts
    li   x2, GUEST_SP               # sp (r1) = DRAM stack top
    li   x8, 10                     # a0 (r7) = 10
    li   x9, 20                     # a1 (r8) = 20
    # --- enter PVM -------------------------------------------------------------
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
    # ret-to-halt-magic / trap -> mcause != 11: program done -> print result.
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done
    # --- host-call dispatch: #0 ('get_third_number') returns THIRD in a0 (x8) ---
    csrr x14, mtval                 # host-call number (B3: arrives in mtval)
    bnez x14, hc_resume             # only #0 is used by this program
    li   x8, THIRD                  # a0 = get_third_number()
hc_resume:
    csrw CSR_PVM_CFG1, x0           # clear-pulse (spaces the re-entry)
    li   x15, (1 << 33) | (1 << 32) | PVM_CODE_LEN   # resume | active | code_len
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

pvm_done:
    # guest halted (ret -> halt magic). a0 (x8) = 10+20+12 = 42 = '*'. Print "[*]".
    li   x15, UART_BASE
    li   x14, '['
    jal  x13, putc
    mv   x14, x8                    # result byte
    jal  x13, putc
    li   x14, ']'
    jal  x13, putc
    li   x14, '\r'
    jal  x13, putc
    li   x14, '\n'
    jal  x13, putc
done:
    j    done                       # result printed; halt

putc:                               # putchar(x14) with THRE flow control; link in x13
1:  lbu  x12, UART_LSR_OFF(x15)     # wait for THR empty (FIFO space)
    andi x12, x12, LSR_THRE
    beqz x12, 1b
    sb   x14, 0(x15)                # THR <- char
    lbu  x12, UART_LSR_OFF(x15)     # uncached LSR read drains the store buffer
    jr   x13

    # REAL compiled PolkaVM program (add_numbers), staged through DRAM into img_mem.
    .include "pvm_user_data.S"
