# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# trap-via-JT gate, DRAM demand-fetch path -- the FULL FPGA/OpenSBI condition for CFG2[37].
# This is loader_trap_jt.S (BRAM) ported to the DRAM demand-fetch path, EXACTLY mirroring how
# loader_handoff_smode_dram.S ports loader_handoff_smode.S: the image is fetched from DRAM
# on-demand (CFG1[34]) via the dcache, NOT preloaded into img_bram (+PVM_IMG); code_base and
# jumptable_base point into the blob in DRAM. IDX>0 places the live JT entry far from the
# code/bitmask lines so the trap's JT read is a COLD cache MISS (the D_WAIT path) -- the FPGA
# condition the BRAM gate cannot exercise (no M3 demand-fetch FSM).
#
# Real OpenSBI sets its trap vector via `lla _trap_handler; csrw mtvec`; in PVM `lla` yields a
# polkatool JUMP-TABLE TOKEN, NOT a raw PVM-pc. So a guest-internal ecalli@S would trap to the raw
# token (garbage). CFG2[37]=1 makes the guest-trap redirect map mtvec (a JT token) THROUGH the
# jump table (like a djump/eret), so the ecalli@S reaches JT[token]=the real M-handler PVM-pc.
#
# Guest (emit_trap_jt): host pre-sets MPP=S; the entry mret is a NORMAL raw-pc eret (CFG2[36]=0)
# that drops M->S at Ls. At Ls an ecalli@S stays in PVM and traps to the guest mtvec=token; with
# CFG2[37]=1 the HW JT-maps token -> JT[idx]=Lh -> host putchars '[#]'. With CFG2[37]=0 (the
# -UCFG2_TRAP_JT negative control) the token is used raw -> a mid-instruction pc -> no '#'.
# Handler is verbatim from loader_handoff_smode_dram.S (ecalli@M -> framed putchar via CSR_PVM_VEC).

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define FETCH_DRAM   (1 << 34)
#ifndef CODE_LEN
#define CODE_LEN 25
#endif
#ifndef JT_OFF
#define JT_OFF 36
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
    csrw CSR_PVM_VEC, t0            # host hypervisor hook: ecalli@M (putchar) + final trap
    csrw mtvec, t0                  # legacy fallback

    li   t0, 0x1800                # clear MPP
    csrc mstatus, t0
    li   t0, 0x800                 # mstatus.MPP = S (bits 12:11 = 0b01)
    csrs mstatus, t0               # so the guest's entry mret drops to S-mode

    lla  t0, trap_jt_blob
    slli a2, t0, 32                # code_base << 32 (entry_pc = 0)
    csrw CSR_PVM_CFG0, a2          # entry_pc=0, code_base=&trap_jt_blob

    lla  t1, trap_jt_blob
    addi t1, t1, JT_OFF            # jumptable_base = &blob + JT_OFF (a DRAM byte addr)
    li   t2, (CFG2_TRAP_BIT | ((JT_Z) << 32))
    or   t1, t1, t2
    csrw CSR_PVM_CFG2, t1          # jt base/z + bit37 = trap-via-jt. NOTE: bit 36 (eret-via-jt)
                                   # left 0 -> the entry mret is a raw-pc eret (lands at Ls directly)

    fence                          # ensure the blob is visible to the fetch dcache reads
    li   t0, FETCH_DRAM | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, t0          # enter PVM in DRAM demand-fetch mode (guest starts at M)
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
    li   x15, FETCH_DRAM | (1 << 33) | (1 << 32) | CODE_LEN
    csrw CSR_PVM_CFG1, x15          # resume PVM at the post-ecalli pc (keep DRAM-fetch mode)
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

    .include "trapjt_dram_blob.S"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
