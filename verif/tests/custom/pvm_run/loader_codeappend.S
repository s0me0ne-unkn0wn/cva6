# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# B2 FOUNDATION micro-test: dynamic code-append. A PVM guest (the "appender") writes new
# bytecode AND a rebuilt opcode bitmask into its OWN DRAM code-region, then host-calls
# `ecalli #2` to ask the host to grow code_len and re-enter at the new code. The new code
# host-calls putchar('B') and traps. SUCCESS = 'B' on the UART == the dynamically-written
# code was fetched and executed. See gen_pvm_img.py:emit_codeappend for the guest image.
#
# M3 DRAM demand-fetch (CFG1[34]=1): the code stays in DRAM, so a guest LSU store to the
# code-region is a physical-address pass-through (writable) -- the mechanism this test needs.
# code_base is pinned at 0x80100000 by link_codeappend.ld so the appender can hard-encode
# the absolute NC/bitmask store addresses (a PVM guest has no `lla`).
#
# WHY THE HOST GROWS code_len: a guest `csr_rw CFG1` is not is_csr_fence-flagged in
# pvm_decoder, yet a CFG1 write raises flush_o in csr_regfile; un-fenced, that commit-flush
# redirect is not absorbed by a pvm_fetch suspend and the front-end fetches the PVM-pc as a
# RISC-V address -> ILLEGAL_INSTR (RVFI-confirmed). The CFG registers are the host<->guest
# control interface, so the guest requests the grow via a host-call and the host (RISC-V,
# where csrw CFG1 flushes cleanly) performs it and re-enters PVM at the new code.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define FETCH_DRAM   (1 << 34)

#ifndef CODE_BASE
#define CODE_BASE 0x80100000
#endif
#ifndef INIT_CODE_LEN
#define INIT_CODE_LEN 38            /* L0: the appender only */
#endif
#ifndef GROWN_CODE_LEN
#define GROWN_CODE_LEN 62           /* L1: appender + appended new code (NC) */
#endif
#ifndef NC_START
#define NC_START 56                 /* PVM-pc of the appended code (host re-enters here) */
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, host_trap
    csrw CSR_PVM_VEC, t0           # B4: ecalli/trap host-boundary exit vector
    csrw mtvec, t0                 # safety net

    li   t0, CODE_BASE
    slli a2, t0, 32
    csrw CSR_PVM_CFG0, a2          # entry_pc=0 [31:0], code_base=0x80100000 [63:32]

    csrw CSR_PVM_CFG2, x0          # no jump table

    fence                          # publish the blob DRAM image to the fetch dcache
    li   t0, FETCH_DRAM | (1 << 32) | INIT_CODE_LEN
    csrw CSR_PVM_CFG1, t0          # enter PVM: DRAM demand-fetch, active, code_len=L0
wait_pvm:
    j    wait_pvm

    # -------------------------------------------------------------------------
    # Host trap handler. host-call number arrives in mtval (cva6.sv adapter).
    #   ecalli #2 (appender): GROW code_len to L1 and re-enter PVM at pc NC_START (fresh).
    #   ecalli #0 (NC)      : putchar(r7==x8) = 'B', then resume the guest.
    #   any other cause     : the NC final trap -> done (SUCCESS via tohost).
    # -------------------------------------------------------------------------
    .align 2
host_trap:
    csrr x14, mcause
    li   x15, 11                   # ENV_CALL_M = ecalli host-boundary
    bne  x14, x15, pvm_done
    csrr x14, mtval                # host-call number
    li   x15, 2
    beq  x14, x15, hc_grow         # #2 = grow + enter at NC
    # #0 = putchar(a0 == x8)
    li   x15, 0x10000000           # UART THR
    sb   x8, 0(x15)                # putchar(r7) -- expect 'B'
    lbu  x14, 0x14(x15)            # LSR read: serialize / drain the store buffer
    csrr x13, CSR_PVM_CFG1         # current CFG1 (dram|active|GROWN)
    csrw CSR_PVM_CFG1, x0          # active->0
    li   x14, 1
    slli x14, x14, 33             # PVM resume bit
    or   x13, x13, x14
    csrw CSR_PVM_CFG1, x13         # rising edge + resume: keep the suspended (post-ecalli) pc
    j    wait_pvm

    .align 2
hc_grow:
    # CFG0 = (code_base << 32) | entry_pc = NC_START  -> re-enter at the appended code
    li   t0, CODE_BASE
    slli t0, t0, 32
    ori  t0, t0, NC_START
    csrw CSR_PVM_CFG0, t0
    # fresh re-enter with the grown code_len (rising edge, NO resume -> loads entry_pc)
    csrw CSR_PVM_CFG1, x0
    li   t0, FETCH_DRAM | (1 << 32) | GROWN_CODE_LEN
    csrw CSR_PVM_CFG1, t0
    j    wait_pvm

    .align 2
pvm_done:
    li   t2, 4000
1:  addi t2, t2, -1
    bnez t2, 1b
    li   t0, 1
    lla  t1, tohost
    sd   t0, 0(t1)
done:
    j    done

    # ---- guest code-region (placed at 0x80100000 by link_codeappend.ld) ----
    # The blob is the initial appender + its bitmask; the trailing .zero reserves the DRAM the
    # appender writes at runtime (NC + rebuilt bitmask, up to code_base + RESERVE_END).
    .section .pvm_code,"a",@progbits
    .globl pvm_code
pvm_code:
    .include "codeappend_blob.S"
    .balign 16
    .zero 128                      # runtime append space (NC @ +56, rebuilt bitmask @ +64)

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
