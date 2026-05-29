# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Minimal M-mode loader for the Stage 3.2b observable PVM gate.
# The JAM image is preloaded into pvm_front.img_mem by the TB ($readmemh via
# +PVM_IMG). This loader programs the PVM control CSRs to enter PVM mode and
# run that image; when the PVM program executes `trap`, the HW delivers an
# M-mode exception to mtvec, where we signal success via HTIF tohost.
#
# JAM program under test: load_imm r5,0xAB ; trap   (code at img offset 0,
# code_len=4, entry_pc=0). PVMCFG0=0 (entry_pc=0, code_base=0);
# PVMCFG1 = (1<<32)|4 (pvm_active | code_len). Build: rv64emac_zbb / lp64e.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#ifndef CODE_LEN
#define CODE_LEN 4
#endif
#ifndef JT_BASE
#define JT_BASE 0          /* dynamic jump-table base (bytes); 0 = none */
#endif
#ifndef JT_Z
#define JT_Z 1             /* jump-table entry size in bytes */
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    # install M-mode trap vector
    la   t0, pvm_trap_handler
    csrw mtvec, t0

    # PVMCFG0 = (code_base<<32) | entry_pc = 0
    csrw CSR_PVM_CFG0, x0

    # PVMCFG2 = (jumptable_z<<32) | jumptable_base  (for dynamic jumps via the jump
    # table). Only written when a jump table is present (JT_BASE != 0): the extra
    # startup CSR write perturbs pipeline timing enough to expose a race between the
    # M-mode handler's in-flight control flow and PVM re-entry on back-to-back ecalli
    # resumes (see logs/04-pvm-in-hw "djump CFG2 timing race"). Programs that do djump
    # set JT_BASE; the ecalli/branch/loop tests don't need it.
#if (JT_BASE)
    li   t0, ((JT_Z) << 32) | (JT_BASE)
    csrw CSR_PVM_CFG2, t0
#endif

    # PVMCFG1 = (pvm_active<<32) | code_len ; active=bit32, code_len=4
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0     # rising edge of active -> PVM mode enters & runs

wait_pvm:
    # busy-loop (NOT wfi: keep the pipeline live so PVM uops flow through issue)
    j    wait_pvm

    .align 2
pvm_trap_handler:
    # Two PVM exit causes vector here:
    #   ecalli (host-call, opcode 10) -> mcause = ENV_CALL_MMODE (11): service it
    #     and RESUME the guest. The HW put the resume point (next_pc) in mepc.
    #   trap   (opcode 0)             -> mcause = ILLEGAL_INSTR (2): program done.
    # Only x14/x15 are touched on the ecalli path: PVM uses r0..r12 == x1..x13,
    # so x14/x15 are the only GPRs free to scratch without corrupting guest state.
    csrr x14, mcause
    li   x15, 11                 # ENV_CALL_MMODE
    bne  x14, x15, pvm_done      # not a host-call -> final trap -> SUCCESS

    # --- host-call #0 = putchar(PVM r7) --------------------------------------
    # PVM r7 maps to x8; the guest left the character there before `ecalli #0`.
    li   x15, 0x10000000         # UART base (THR)
    sb   x8, 0(x15)              # THR <- char
    lbu  x14, 0x14(x15)          # read LSR: an uncached load drains the store
                                 # buffer, ordering this MMIO write one-at-a-time
                                 # (else the WT-dcache coalesces same-addr writes)
    # --- resume the guest after the ecalli -----------------------------------
    # pvm_fetch already suspended at the post-ecalli pc; re-activate with the
    # resume bit so it continues there (no entry_pc/next_pc bookkeeping needed).
    csrw CSR_PVM_CFG1, x0                       # clear -> next write is a rising edge
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN  # resume | active | code_len
    csrw CSR_PVM_CFG1, x15                      # rising edge -> resume PVM
    j    wait_pvm

pvm_done:
    # Final trap: drain any UART tail, then signal SUCCESS via HTIF tohost.
    li   t2, 4000
1:  addi t2, t2, -1
    bnez t2, 1b
    li   t0, 1                   # tohost = (0<<1)|1 -> exit code 0 -> SUCCESS
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
