# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Boot a REAL U-Boot 2026.01 (RV64E) build as a PVM/JAM guest in Verilator (standalone:
# NO OpenSBI underneath -- the goal is to empirically surface the FIRST runtime wall of
# uboot.polkavm, not the full M->S stack). The image is the genuine uboot.polkavm
# (polkatool link -i jam_v1_privileged) -> emit-image -> 128B-PVMI split by
# opensbi_to_dram.py into:
#   .pvm_code (code+pad+bitmask) @ 0x80100000  (M3 demand-fetch code_base)
#   .pvm_jt   (jump table z=3)   @ 0x80160000  (CFG2 jt_base)
#   .pvm_ro   (ro_data 78616B)   @ 0x80010000  (= ram_base + guest 0x10000)
#   .pvm_rw   (rw_init 14816B)    @ 0x80040000  (= ram_base + guest 0x40000)
# placed there by link_uboot.ld + .incbin below.
#
# U-Boot's PVM data layout (decoded from the disasm): ro@guest 0x10000, rw@guest 0x40000
# (bss to 0x4d338) -- these are LOW addrs covered by the guest-RAM->DRAM aperture
# (CSR_PVM_RAM base 0x80000000, window [0x10000,0x100000)). BUT U-Boot's _start hard-sets
# sp=0x80200000 and gd=0x801f7ed0 (its link/RAM-top config) -- HIGH addrs that fall OUTSIDE
# the aperture and hit the LSU pass-through (identity on the low 32 bits), which lands them
# right back in physical DRAM (0x80200000 is 2MB into the 16MB sram). So the hybrid
# aperture+pass-through backs BOTH the low data sections and the high stack with no remap
# collision. We run the guest at M-mode (strictly more permissive than its intended S-mode;
# _start only touches stvec/sie, legal from M) so a missing S-handoff can't be the blocker.
#
# SUCCESS observable = the first guest UART byte (U-Boot's console) OR, more likely for a
# first run, the commit trace localizing the FIRST fault (its PVM-pc, priv, data address).

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define CSR_PVM_RAM  0xbc5

#ifndef CODE_LEN
#define CODE_LEN 291517
#endif
#ifndef JT_Z
#define JT_Z 3
#endif
#ifndef RW_IMG
#define RW_IMG 14816
#endif
#ifndef RW_TOTAL
#define RW_TOTAL 54072
#endif

#define CODE_BASE  0x80100000
#define JT_BASE    0x80160000
#define RAM_BASE   0x80000000

/* guest data bases (decoded): ro@0x10000, rw@0x40000.  bss = [rw_base+RW_IMG, rw_base+RW_TOTAL) */
#define RW_GUEST   0x40000
#define BSS_LO     (RAM_BASE + RW_GUEST + RW_IMG)     /* phys 0x800439e0 */
#define BSS_HI     (RAM_BASE + RW_GUEST + RW_TOTAL)   /* phys 0x8004d338 */

#define DTB_GUEST  0x80170000          /* a1: pass-through -> phys 0x80170000 */

#ifndef DTB_PATH
#define DTB_PATH "/home/claude/pvm/cva6-sdk/configs/genesys2/cv64a6_emac_sv39.dtb"
#endif

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    # ---- FPGA-diag marker 'L': the launcher started (RISC-V M-mode, pre-PVM) ----
    li   x15, 0x10000000
    li   x14, 'L'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    # ---- host trap vector (PVM host-boundary exit: ecalli/panic/fault land here) ----
    lla  t0, host_trap                  # lla = PC-relative, bare-metal safe (la uses GOT -> 0)
    csrw mtvec, t0                      # safety net (RISC-V trap vector)
    csrw CSR_PVM_VEC, t0                # B4: PVM host-exit vector

    # ---- zero the guest bss [BSS_LO, BSS_HI) (phys, via the aperture target) ----
    li   t0, BSS_LO
    li   t1, BSS_HI
1:  sd   x0, 0(t0)
    addi t0, t0, 8
    bltu t0, t1, 1b

    # ---- guest-RAM -> DRAM aperture: ram_base=0x80000000, window [0x10000,0x100000) ----
    # Covers ro(0x10000)+rw/bss(0x40000..0x4d338). U-Boot's sp/gd (0x80200000/0x801f7ed0)
    # are OUTSIDE this window -> LSU pass-through (identity) -> already-valid DRAM.
    # CSR_PVM_RAM = [31:0]=ram_base, [47:32]=ram_lo_page(1->0x10000), [63:48]=ram_hi_page(0x10->0x100000)
    li   t0, RAM_BASE
    li   t1, 1
    slli t1, t1, 32
    or   t0, t0, t1
    li   t1, 0x10
    slli t1, t1, 48
    or   t0, t0, t1
    csrw CSR_PVM_RAM, t0

    # ---- CFG0 = {code_base=0x80100000 [63:32], entry_pc=0 [31:0]} ----
    li   t0, CODE_BASE
    slli t0, t0, 32
    csrw CSR_PVM_CFG0, t0

    # ---- CFG2 = {jt_z [35:32], jt_base=0x80160000 [31:0]} ----
    # NO bit36/37 (standalone M-mode: no OpenSBI->U-Boot eret-via-jt, no guest trap-via-jt).
    li   t0, JT_BASE
    li   t1, JT_Z
    slli t1, t1, 32
    or   t0, t0, t1
    csrw CSR_PVM_CFG2, t0

    # ---- seed guest entry registers (PVM a0..a5 = r7..r12 = RISC-V x8..x13) ----
    # U-Boot _start: a0=hartid, a1=dtb (saved to s0).  a2 unused at entry.
    li   x8, 0                          # a0 (r7) = hartid 0
    li   x9, DTB_GUEST                  # a1 (r8) = dtb ptr (phys 0x80170000 via pass-through)
    li   x10, 0                         # a2 (r9)

    fence                               # publish ro/rw/code/jt DRAM writes to the fetch dcache

    # ---- FPGA-diag marker 'P': CSRs programmed, about to enter PVM (CFG1) ----
    li   x15, 0x10000000
    li   x14, 'P'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)

    # ---- enter PVM in DRAM demand-fetch mode: CFG1 = (1<<34)|(1<<32)|CODE_LEN ----
    li   t0, CODE_LEN
    li   t1, 1
    slli t1, t1, 34                     # FETCH_DRAM bit
    or   t0, t0, t1
    li   t1, 1
    slli t1, t1, 32                     # PVM_ACTIVE bit
    or   t0, t0, t1
    csrw CSR_PVM_CFG1, x0               # FPGA: clear first -> clean 0->1 ACTIVE edge (PVM entry is
                                        # rising-edge triggered; the bootrom's prior PVM test may
                                        # leave CFG1[32]=1, so a bare 1->1 write enters NOTHING).
    csrw CSR_PVM_CFG1, t0               # rising edge of ACTIVE -> enter PVM

wait_pvm:
    j    wait_pvm

    # ---------------------------------------------------------------------------
    # Host trap handler. ENV_CALL_M (ecalli) = U-Boot's SBI host-call ABI base -> just
    # resume (early boot makes no real SBI call; reaching here early is informational).
    # Any other cause = a real fault: mark '!F' on the UART, dump via the trace, park.
    # ---------------------------------------------------------------------------
    .align 2
host_trap:
    csrr x14, mcause
    li   x15, 11                        # ENV_CALL_M
    bne  x14, x15, trap_fault
    # ecalli host-call: resume the guest (CFG1 = (1<<34)|(1<<33)|(1<<32)|CODE_LEN)
    csrw CSR_PVM_CFG1, x0
    li   x15, CODE_LEN
    li   x14, 1
    slli x14, x14, 34                   # FETCH_DRAM
    or   x15, x15, x14
    li   x14, 1
    slli x14, x14, 33                   # PVM_RESUME
    or   x15, x15, x14
    li   x14, 1
    slli x14, x14, 32                   # PVM_ACTIVE
    or   x15, x15, x14
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

trap_fault:
    # A real fault (load/store access, illegal, etc.). Mark it on the UART, then park.
    # The trace_rvfi dump carries the precise pc/cause/tval for the post-mortem.
    li   x15, 0x10000000                # UART THR
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
    lla  t1, tohost                     # lla = PC-relative, bare-metal safe
    sd   t0, 0(t1)
fault_park:
    j    fault_park

    # ---- embedded guest image regions (placed by link_uboot.ld) ----
    .section .pvm_code,"a",@progbits
    .globl pvm_code
pvm_code:
    .incbin "uboot.code.bin"

    .section .pvm_jt,"a",@progbits
    .globl pvm_jt
pvm_jt:
    .incbin "uboot.jt.bin"

    .section .pvm_ro,"a",@progbits
    .globl pvm_ro
pvm_ro:
    .incbin "uboot.ro.bin"

    .section .pvm_dtb,"a",@progbits
    .globl pvm_dtb
pvm_dtb:
    .incbin DTB_PATH

    .section .pvm_rw,"a",@progbits
    .globl pvm_rw
pvm_rw:
    .incbin "uboot.rw.bin"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
