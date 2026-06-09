# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# COMBINED eret-via-JT + trap-via-JT gate, DRAM demand-fetch path -- the EXACT real-OpenSBI
# SEQUENCE that run-handoff-smode-dram (CFG2[36] only) and run-trap-jt-dram (CFG2[37] only, RAW
# M->S entry) each covered HALF of, but which NEITHER ran together:
#
#   1. M->S handoff = a JT-MAPPED eret (CFG2[36]=1): mepc = a JT token, mret -> jumptable[idx_e]=Ls,
#      priv->S, and the eret-via-JT one-shot CONSUMES CFG2[36] (-> 0).  [like loader_handoff_smode_dram.S]
#   2. THEN, in S-mode, an ecalli@S whose guest mtvec is a DIFFERENT JT token must trap-via-JT
#      (CFG2[37]=1, still set): the guest-trap redirect JT-maps mtvec -> jumptable[idx_t]=Lh ->
#      host putchars '[#]'.                                            [like loader_trap_jt_dram.S]
#
# This is the SEQUENCE the FPGA real-OpenSBI hits: the launcher sets BOTH bits (`li t1,(3<<36)`,
# loader_opensbi.S); the handoff eret consumes [36] while [37] stays 1, so the SUBSEQUENT
# trap-via-JT runs with the SAME shared JT-FSM state (djump_a_q/jt_req_q/jt_valid_q/djump_pending/
# d_state_q) the consumed eret left behind. run-trap-jt-dram used a RAW M->S entry (CFG2[36]=0
# from the start) -> it NEVER exercised "eret-via-JT-consume THEN trap-via-JT".
#
# Image is demand-fetched from DRAM on-demand (CFG1[34]) via the dcache, NOT preloaded into
# img_bram (+PVM_IMG); code_base and jumptable_base point into the blob in DRAM. IDX>0 places
# BOTH live JT entries far from the code/bitmask lines so each JT read is a COLD cache MISS (the
# D_WAIT path), and idx_t != idx_e so the trap's JT read is a DIFFERENT line than the eret's.
#
# The POSITIVE build sets CFG2[37]=1 (-DCFG2_TRAP_JT) -> expect '[#]' (both JT-maps fired in
# sequence). The NEGATIVE control clears it (-UCFG2_TRAP_JT): the eret-via-JT handoff still JT-maps
# (CFG2[36]=1) and drops to S, but the ecalli@S's JT-token mtvec is then used RAW -> a
# mid-instruction pc -> NO '#'. (So the negative control also proves the bit-37 gate, exactly like
# run-trap-jt-dram, on top of the full handoff sequence.)
# Handler is verbatim from loader_handoff_smode_dram.S / loader_trap_jt_dram.S.

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
# CFG2[36] (eret-via-JT) is ALWAYS set here (the handoff IS a JT-mapped eret). CFG2[37]
# (trap-via-JT) is set for the real gate; -UCFG2_TRAP_JT for the negative control.
#ifdef CFG2_TRAP_JT
#define CFG2_BITS ((1 << 37) | (1 << 36))
#else
#define CFG2_BITS (1 << 36)
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
    csrs mstatus, t0               # so the guest's JT-mapped entry mret drops to S-mode

    lla  t0, handoff_trap_jt_blob
    slli a2, t0, 32                # code_base << 32 (entry_pc = 0)
    csrw CSR_PVM_CFG0, a2          # entry_pc=0, code_base=&handoff_trap_jt_blob

    lla  t1, handoff_trap_jt_blob
    addi t1, t1, JT_OFF            # jumptable_base = &blob + JT_OFF (a DRAM byte addr)
    li   t2, (CFG2_BITS | ((JT_Z) << 32))
    or   t1, t1, t2
    csrw CSR_PVM_CFG2, t1          # jt base/z + bit36 (eret-via-jt) [+ bit37 (trap-via-jt)]

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

    .include "handoff_trap_jt_dram_blob.S"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
