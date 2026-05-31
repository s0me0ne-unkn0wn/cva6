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

    # PVMCFG2 = (jumptable_z<<32) | jumptable_base, for dynamic jumps via the jump
    # table. Written UNCONDITIONALLY. This used to be #if (JT_BASE)-gated to dodge the
    # "djump CFG2 timing race": the extra startup CSR write shifted pipeline timing and
    # made the rising-edge PVM re-entry miss on back-to-back ecalli resumes (banner hung
    # at ~char 6). That race is now fixed at the source -- a PVMCFG1 write flushes the
    # pipeline (csr_regfile.sv, the same idiom as mstatus/satp), fencing every PVM mode
    # transition -- so the dodge is removed and every program exercises CFG2.
    li   t0, ((JT_Z) << 32) | (JT_BASE)
    csrw CSR_PVM_CFG2, t0

    # PVMCFG1 = (pvm_active<<32) | code_len ; active=bit32, code_len=4
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0     # rising edge of active -> PVM mode enters & runs

wait_pvm:
    # busy-loop (NOT wfi: keep the pipeline live so PVM uops flow through issue)
    j    wait_pvm

    .align 2
pvm_trap_handler:
    # PVM exit causes: mcause = ENV_CALL_MMODE (11) = an ecalli host-call -> service it
    # and RESUME the guest; anything else = the program's final `trap` (ILLEGAL_INSTR).
    # Host-call ABI (B3): the host-call number (the ecalli immediate) arrives in mtval
    # (HW, cva6.sv adapter). Args/return follow the PolkaVM ABI: a0..a5 = PVM r7..r12 =
    # x8..x13, with a0 (x8) the first arg AND the return value. The handler scratches
    # only x14/x15; it reads/writes a0/a1 (x8/x9) solely as the host-call ABI.
    csrr x14, mcause
    li   x15, 11
    bne  x14, x15, pvm_done       # not a host-call -> final trap -> SUCCESS
    csrr x14, mtval               # x14 = host-call number
    beqz x14, hc_putchar          # #0 = putchar(a0)
    li   x15, 1
    beq  x14, x15, hc_sum         # #1 = sum: a0 = a0 + a1
    j    hc_resume                # unknown host-call -> no-op, resume
hc_sum:
    add  x8, x8, x9               # a0 = a0 + a1   (return value in a0)
    j    hc_resume
hc_putchar:
    li   x15, 0x10000000          # UART THR
    sb   x8, 0(x15)               # THR <- a0 (low byte)
    lbu  x14, 0x14(x15)           # uncached LSR read drains the store buffer (1-at-a-time)
hc_resume:
    # pvm_fetch is suspended at the post-ecalli pc; re-activate with the resume bit so
    # it continues there. The clear write (CFG1=0) before the set spaces the re-entry;
    # the CFG1-write pipeline flush (B1) fences every PVM mode transition.
    csrw CSR_PVM_CFG1, x0                        # clear pulse (spacing)
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN   # resume | active | code_len
    csrw CSR_PVM_CFG1, x15                       # resume PVM
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
