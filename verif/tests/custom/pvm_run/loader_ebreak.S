# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# MICRO-TEST: is a guest PVM `trap` opcode (what polkatool lowers a RISC-V `ebreak`
# to -- riscv.rs:1316/909 ebreak/c.ebreak -> Inst::Unimplemented -> Instruction::trap)
# delivered to the GUEST's own mtvec, or does it exit to the HOST (CSR_PVM_VEC)?
#
# This mirrors the Linux kernel-as-PVM host_trap contract (loader_kernel.S): the host
# resumes only on ENV_CALL_M (ecalli); ANY other PVM host-boundary exit prints '!F'.
# A guest mtvec handler is also installed (via CFG2[37] JT-mapping, like the kernel
# loader) and would print 'G' if a `trap` were delivered there instead of to the host.
#
# Guest program (emitted by gen_pvm_img.py 'ebreak_probe'):
#   ecalli #0    -- host call: the handler prints 'E' and resumes (proves round-trip)
#   trap         -- the ebreak-equivalent; WHERE does it go?
#
# Expected with the current RTL (pvm_is_trap is in pvm_use_vec): the `trap` is a
# HOST-boundary exit -> host_trap, mcause=ILLEGAL_INSTR(2) != 11 -> '!F'.  So the
# observable is 'E' then '!F' (the guest handler 'G' is NOT printed).  THIS proves the
# kernel's WARN/BUG ebreak cannot be made non-fatal by routing alone -- the kernel-side
# warnfix (bug.h: WARN via the pure-C warn_slowpath_fmt path, no ebreak) is required,
# because the kernel's generic-bug machinery (find_bug-by-address, instruction readback)
# is incompatible with PVM's Harvard PVM-pc model regardless of where the trap lands.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#ifndef CODE_LEN
#define CODE_LEN 4
#endif
#ifndef JT_BASE
#define JT_BASE 16
#endif
#ifndef JT_Z
#define JT_Z 1
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    # ---- host trap vector (PVM host-boundary exit: ecalli/trap/fault land here) ----
    lla  t0, host_trap
    csrw mtvec, t0                 # RISC-V safety net
    csrw CSR_PVM_VEC, t0           # B4: PVM host-exit vector

    # ---- guest mtvec = a JT token that, with CFG2[37]=1, maps to guest_handler ----
    # (Mirror the kernel loader: the guest would set mtvec via lla->JT token; here we
    #  pre-seed the guest's mtvec by leaving it at the JT base so a guest-delivered trap
    #  would reach guest_handler. We do NOT enter the guest at M with its own mtvec set,
    #  so this is only reachable if the HW routes a `trap` to the guest tvec.)

    csrw CSR_PVM_CFG0, x0          # entry_pc = 0, code_base = 0 (BRAM image)
    li   t0, (1 << 37) | ((JT_Z) << 32) | (JT_BASE)   # CFG2: trap-via-JT + jt base/z
    csrw CSR_PVM_CFG2, t0
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x0          # clean 0->1 ACTIVE edge
    csrw CSR_PVM_CFG1, t0          # enter PVM at M-mode
wait_pvm:
    j    wait_pvm

    # ---------------------------------------------------------------------------
    # Host trap handler (the PVM host-boundary exit vector, like loader_kernel.S).
    #   ENV_CALL_M (11) = ecalli  -> print 'E', resume the guest.
    #   anything else (e.g. a `trap` -> ILLEGAL_INSTR=2) -> '!F' (fatal).
    # ---------------------------------------------------------------------------
    .align 2
host_trap:
    csrr x14, mcause
    li   x15, 11                   # ENV_CALL_M
    bne  x14, x15, trap_fault
    # ecalli: print 'E' then resume
    li   x15, 0x10000000
    li   x14, 'E'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    csrw CSR_PVM_CFG1, x0
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN   # resume (no DRAM fetch: BRAM image)
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

trap_fault:
    li   x15, 0x10000000
    li   x14, '!'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    li   x14, 'F'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    li   t2, 4000
2:  addi t2, t2, -1
    bnez t2, 2b
    li   t0, 1
    lla  t1, tohost
    sd   t0, 0(t1)
fault_park:
    j    fault_park

    # The guest mtvec handler: only reached if the HW delivers a guest `trap` to the
    # guest tvec (it does NOT, with the current RTL).  Prints 'G' and clean-halts.
    .align 2
guest_handler:
    li   x15, 0x10000000
    li   x14, 'G'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    li   t0, 1
    lla  t1, tohost
    sd   t0, 0(t1)
3:  j    3b

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
