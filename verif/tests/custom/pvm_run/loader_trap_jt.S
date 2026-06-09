# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# trap-via-JT gate (mirror of loader_handoff_smode.S, which exercises eret-via-JT/CFG2[36]).
# Real OpenSBI sets its trap vector via `lla _trap_handler; csrw mtvec` (fw_base.S:798); in PVM,
# `lla _trap_handler` yields a polkatool JUMP-TABLE TOKEN, NOT a raw PVM-pc. So a guest-internal
# ecalli@S would trap to the raw token (garbage) instead of the real handler. CFG2[37]=1 makes the
# guest-trap redirect map mtvec (a JT token) THROUGH the jump table (like a djump/eret), so the
# ecalli@S reaches JT[token]=the real M-handler PVM-pc.
#
# The guest (emit_trap_jt): host pre-sets MPP=S; entry mret (NORMAL, raw mepc) drops M->S at Ls.
# At Ls an ecalli@S stays in PVM and traps to the guest mtvec=token; with CFG2[37]=1 the HW JT-maps
# token -> JT[idx]=Lh (the in-image M-handler) -> host putchars '[#]'. With CFG2[37]=0 (the
# -UCFG2_TRAP_JT negative control) the token is used raw -> a mid-instruction pc -> no '#'.
# Reuses loader_handoff_smode.S's handler verbatim (ecalli@M -> framed putchar via CSR_PVM_VEC).

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#ifndef CODE_LEN
#define CODE_LEN 28
#endif
#ifndef JT_BASE
#define JT_BASE 36
#endif
#ifndef JT_Z
#define JT_Z 1
#endif
# CFG2[37] = trap-via-JT. Defined for the real gate; -UCFG2_TRAP_JT for the negative control.
#ifdef CFG2_TRAP_JT
#define CFG2_TRAP_BIT (1 << 37)
#else
#define CFG2_TRAP_BIT 0
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    lla  t0, pvm_trap_handler
    csrw CSR_PVM_VEC, t0            # host hypervisor hook: services ecalli@M (putchar) + final trap
    csrw mtvec, t0                  # legacy fallback

    li   t0, 0x1800                # clear MPP
    csrc mstatus, t0
    li   t0, 0x800                 # mstatus.MPP = S (bits 12:11 = 0b01)
    csrs mstatus, t0               # so the guest's entry mret drops to S-mode

    csrw CSR_PVM_CFG0, x0          # entry_pc = 0, code_base = 0 (BRAM image)
    li   t0, (CFG2_TRAP_BIT | ((JT_Z) << 32) | (JT_BASE))  # CFG2: jt base/z + bit37 = trap-via-jt
    csrw CSR_PVM_CFG2, t0          # NOTE: bit 36 (eret-via-jt) left 0 -> the entry mret is raw-pc
    li   t0, (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0          # enter PVM (guest starts at M-mode)
wait_pvm:
    j    wait_pvm

    .align 2
pvm_trap_handler:                  # reached via CSR_PVM_VEC for ecalli@M (putchar) + final trap.
    csrr x14, mcause               # the guest-internal ecalli@S does NOT arrive here (stays in PVM).
    li   x15, 11
    bne  x14, x15, pvm_done        # not ENV_CALL_M -> final trap -> SUCCESS
    li   x15, 0x10000000           # ecalli #0 = framed putchar '[' r7 ']' (r7 == x8)
    li   x14, '['
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    sb   x8,  0(x15)
    lbu  x14, 0x14(x15)
    li   x14, ']'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    csrw CSR_PVM_CFG1, x0
    li   x15, (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15          # resume PVM at the post-ecalli pc
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

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
