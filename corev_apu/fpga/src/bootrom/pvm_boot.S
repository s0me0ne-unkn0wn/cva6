# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# PolkaVM bootrom entry (FPGA) -- STAGE-2 skip-class trap-return, COMBINED with Stage-1 eret-via-JT
# (cont.23, the real OpenSBI config). Called from main() after the UART is up + prologue banner.
# One JAM image drives the REAL RISC-V privilege CSRs; the host sets MPP=S + CFG2={bit36|z<<32|jt_base}:
#   @M : mtvec=Lh1 ; mepc=(idx+1)*2 (a JT TOKEN) ; mret  -> JT-mapped to JT[0]=Ls, priv->S
#        (this one-shot CONSUMES CFG2[36] -> eret-via-JT self-clears in HW)
#   @S (Ls): ecalli@S -> GUEST-INTERNAL trap to mtvec=Lh1 (stays in PVM), priv->M; HW captures
#        mepc = next_pc(ecalli)-4 (the Stage-2 -4 bias)
#   @M (Lh1): re-point mtvec=Lh2 ; csrr mepc ; +4 ; csrw mepc ; mret -> S@(ecalli+2) MUST be DIRECT
#        (CFG2[36] already self-cleared -> a raw PVM-pc, NOT JT-mapped); a still-sticky bit would
#        JT-mangle it -> miss the 2nd ecalli -> hit the decoy trap -> NO '#'
#   @S: 2nd ecalli@S -> Lh2 ; @M (Lh2): ecalli@M -> the one door out -> framed putchar '[#]'
# UART shows "[#]" iff the CFG2[36] one-shot self-clear AND the -4 skip-bias BOTH hold on silicon
# (sim gates: run-handoff-skip + run-strap-skip). Original cont.20 priv bootrom: /tmp/pvm_boot_priv.S.bak.
#
# The HOST sets mstatus.MPP = S so the guest's mret drops to S WITHOUT the guest writing
# mstatus (a guest mstatus write raises a pipeline flush that discards in-flight PVM uops --
# deferred). The guest writes only mtvec/mepc (flush-free). The image is staged into
# img_bram via the CSR_PVM_IMG byte-load port (M1/M2), code_base=0 (no DRAM fetch).
#
# IMPORTANT: use `lla` (NOT `la`) for label addresses -- this bootrom is PIE, so `la` loads
# from the GOT whose R_RISCV_RELATIVE reloc a bare-metal boot never applies (-> 0 -> mtvec=0
# -> every trap hangs). `lla` is PC-relative. (See phase log cont.14: a 9-build saga.)

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_IMG  0xbc3          /* write {addr<<8 | byte} -> img_bram[addr] (M1 load port) */
#define CSR_PVM_VEC  0xbc4          /* host-boundary exit vector (B4): survives a guest mtvec write */
#define PVM_IMG_LEN  72             /* handoff_skip image: 54 code + 10 pad + 7 bitmask + 1 JT */
#define PVM_CODE_LEN 54             /* |c| of the handoff_skip image */
#define PVM_JT_BASE  71             /* jump-table byte offset within img_bram (= JT_BASE) */
#define PVM_JT_Z     1              /* jump-table entry size z */
#define MSTATUS_MPP_S 0x800         /* mstatus.MPP = S (bits 12:11 = 0b01) */
#define UART_BASE    0x10000000     /* ariane_soc::UARTBase (apb_uart THR @ +0) */
#define UART_LSR_OFF 0x14           /* line status register (reg 5, 4-byte stride) */
#define LSR_THRE     0x20           /* LSR bit 5: transmit holding register empty */

    .section .text,"ax",@progbits
    .globl pvm_boot
pvm_boot:
    lla  t0, pvm_trap_handler       # PC-relative (see header: NOT `la`)
    csrw CSR_PVM_VEC, t0            # host hypervisor hook (B4): the one door out of the sandbox
    csrw mtvec, t0                  # legacy fallback (pvm_vec!=0 here, so PVM_VEC wins)
    li   t0, MSTATUS_MPP_S
    csrs mstatus, t0                # MPP = S so the guest's mret drops to S-mode
    # --- stage the JAM image into img_bram via CSR_PVM_IMG (M1/M2 byte-load) ---------
    lla  t0, skip_blob              # ROM source (PC-relative, NOT GOT)
    li   t2, PVM_IMG_LEN
    li   a3, 0                      # byte index
1:  add  a2, t0, a3
    lbu  a0, 0(a2)                  # ROM byte
    slli a1, a3, 8
    or   a1, a1, a0                 # (addr << 8) | byte
    csrw CSR_PVM_IMG, a1            # img_bram[addr] = byte
    addi a3, a3, 1
    blt  a3, t2, 1b
    # --- enter PVM (img_bram fetch, code_base = 0, guest starts at M-mode) ------------
    csrw CSR_PVM_CFG0, x0           # entry_pc = 0, code_base = 0
    # CFG2 = {1<<36 (eret-via-jt, one-shot) | PVM_JT_Z<<32 | PVM_JT_BASE}. Built in ASM with explicit
    # shifts -- the C preprocessor would 32-bit-overflow a (1<<36) macro (see cont.22 / opensbi_boot.S).
    li   t0, PVM_JT_BASE            # CFG2[31:0] = jump-table base (img_bram byte offset)
    li   t1, PVM_JT_Z
    slli t1, t1, 32                 # CFG2[35:32] = z
    or   t0, t0, t1
    li   t1, 1
    slli t1, t1, 36                 # CFG2[36] = eret-via-jt (HW self-clears after the handoff eret)
    or   t0, t0, t1
    csrw CSR_PVM_CFG2, t0           # JT handoff armed (one-shot)
    fence                           # drain the staging writes before fetch
    csrw CSR_PVM_CFG1, x0           # clear -> clean 0->1 edge on the next write
    li   t0, (1 << 32) | PVM_CODE_LEN
    csrw CSR_PVM_CFG1, t0           # rising edge of active -> enter PVM
wait_pvm:
    j    wait_pvm                   # busy-loop (NOT wfi): keep the pipeline live for PVM uops

    .align 2
pvm_trap_handler:                   # reached via CSR_PVM_VEC for ecalli@M + the final trap.
    csrr x14, mcause                # the GUEST-INTERNAL ecalli@S does NOT arrive here -- it
    li   x15, 11                    # stays in PVM and traps to the guest mtvec (Phase B).
    bne  x14, x15, pvm_done         # not ENV_CALL_M -> final trap -> done
    # ecalli@M (the handler Lh host-exit): framed putchar '[' r7(x8) ']'
    li   x15, UART_BASE
    li   x14, '['
    jal  x13, putc
    mv   x14, x8                    # r7 = the guest's char ('#')
    jal  x13, putc
    li   x14, ']'
    jal  x13, putc
    csrw CSR_PVM_CFG1, x0           # clear-pulse (spaces the re-entry)
    li   x15, (1 << 33) | (1 << 32) | PVM_CODE_LEN  # resume | active | len
    csrw CSR_PVM_CFG1, x15          # resume PVM at the post-ecalli pc
    j    wait_pvm

pvm_done:                           # final trap: terminate the line and halt
    li   x15, UART_BASE
    li   x14, '\r'
    jal  x13, putc
    li   x14, '\n'
    jal  x13, putc
done:
    j    done

putc:                               # putchar(x14) with THRE flow control; link in x13
1:  lbu  x12, UART_LSR_OFF(x15)     # wait for THR empty
    andi x12, x12, LSR_THRE
    beqz x12, 1b
    sb   x14, 0(x15)                # THR <- char
    lbu  x12, UART_LSR_OFF(x15)     # uncached LSR read drains the store buffer
    jr   x13

    .include "handoff_skip_data.S"
