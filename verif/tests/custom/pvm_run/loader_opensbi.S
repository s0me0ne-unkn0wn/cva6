# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# B7 step-1: boot a REAL OpenSBI build as a PVM/JAM guest in Verilator. The image is the
# genuine fw_payload.bin (PVMI emit-image, 125 KB) split by opensbi_to_dram.py into:
#   .pvm_code (code+pad+bitmask) @ 0x80100000  (M3 demand-fetch code_base)
#   .pvm_jt   (jump table z=3)   @ 0x80200000  (CFG2 jt_base)
#   .pvm_ro   (ro_data)          @ 0x80010000  (= ram_base + guest 0x10000)
#   .pvm_rw   (rw_init)          @ 0x80030000  (= ram_base + guest 0x30000)
# placed there by link_opensbi.ld + .incbin below. The loader (M-mode RISC-V) zeroes the
# guest bss [0x80030b00,0x80031738), installs a host trap vector in CSR_PVM_VEC, programs the
# guest-RAM->DRAM aperture (CSR_PVM_RAM = base 0x80000000, window [0x10000,0x40000)), points
# CFG0 at the DRAM code, CFG2 at the jump table, seeds a0/a1/a2, and enters PVM in
# DRAM-demand-fetch mode (CFG1[34]). OpenSBI's `_start` then: s0=a0, s1=a1, store a2->[0x30058]
# (the FIRST guest store -- relocated into DRAM by the aperture), boot-lottery, bss-zero,
# csrw mtvec=0x16, clear an mstatus bit, sp=0x32b00, then call into C (console/DTB).
#
# SUCCESS = the first OpenSBI UART byte ($write from mock_uart). A precise first-fault
# localization (via the commit trace) is the fallback observable -- see run-opensbi.

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define CSR_PVM_RAM  0xbc5

#ifndef CODE_LEN
#define CODE_LEN 85668
#endif
#ifndef JT_Z
#define JT_Z 3
#endif

#ifndef CODE_BASE
#define CODE_BASE  0x80100000
#endif
#ifndef JT_BASE
#define JT_BASE    0x80200000
#endif
#define RAM_BASE   0x80000000
#define BSS_LO     0x80030b00          /* guest 0x30b00 relocated */
#define BSS_HI     0x80031738          /* guest 0x31738 relocated */
/* a1 / FDT location = guest 0x90000 == FW_PAYLOAD_FDT_OFFSET in the rebuilt OpenSBI.
 * BOTH consumers must agree: fw_platform_init() parses the DTB at boot-a1, and
 * generic_early_init()->fdt_serial_init() (the console path, just before the banner)
 * parses fdt_get_address()==scratch->next_arg1==fw_next_arg1()==_fw_start+0x90000.
 * Staging the DTB at 0x90000 and passing a1=0x90000 makes both reads hit the same
 * valid blob (phys 0x80090000, inside the widened aperture). */
#define DTB_GUEST  0x90000             /* a1 = FW_PAYLOAD_FDT_OFFSET; phys 0x80090000 */

#ifndef DTB_PATH
#define DTB_PATH "/home/claude/pvm/cva6-sdk/configs/genesys2/cv64a6_emac_sv39.dtb"
#endif

/* CFG1 flag bits are >32-bit; DO NOT use (1<<34) in #define — C preprocessor integer
 * arithmetic is 32-bit and overflows silently.  Build the 64-bit value with explicit
 * li+slli+or sequences in assembly (see enter_pvm / host_trap below). */
#define CFG1_CODE_LEN_MASK 0xFFFFFFFF   /* low 32 bits of CFG1 = code_len */
/* Bit positions (for documentation; use assembly not macros for >31-bit shifts): */
#define CFG1_BIT_ACTIVE 32
#define CFG1_BIT_RESUME 33
#define CFG1_BIT_FETCH  34

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    # ---- host trap vector (PVM host-boundary exit) ----
    lla  t0, host_trap                  # lla = PC-relative, bare-metal safe (la uses GOT -> 0)
    csrw mtvec, t0                      # safety net
    csrw CSR_PVM_VEC, t0                # B4: ecalli/panic host-exit vector

    # ---- zero the guest bss [BSS_LO, BSS_HI) (OpenSBI _start expects it pre-zeroed too,
    #      but its loop re-zeroes; do it here so a partial bss can't poison early reads) ----
    li   t0, BSS_LO
    li   t1, BSS_HI
1:  sd   x0, 0(t0)
    addi t0, t0, 8
    bltu t0, t1, 1b

    # ---- guest-RAM -> DRAM aperture: ram_base=0x80000000, window [0x10000,0x100000) ----
    # Widened from [0x10000,0x40000) to cover the rebuilt OpenSBI's in-aperture FDT-reloc
    # dest (guest 0x90000, FW_PAYLOAD_FDT_OFFSET) + next-stage payload (guest 0xC0000,
    # FW_PAYLOAD_OFFSET); both now map to DRAM 0x800{90,C0}000. Nothing between guest
    # 0x40000 and 0x100000 is MMIO, so all of it passes through to DRAM.
    # CSR_PVM_RAM = [31:0]=ram_base, [47:32]=ram_lo_page(1<<16=0x10000), [63:48]=ram_hi_page(0x10<<16=0x100000)
    li   t0, RAM_BASE                   # [31:0]
    li   t1, 1
    slli t1, t1, 32                     # ram_lo_page = 1  -> 0x10000
    or   t0, t0, t1
    li   t1, 0x10
    slli t1, t1, 48                     # ram_hi_page = 0x10 -> 0x100000
    or   t0, t0, t1
    csrw CSR_PVM_RAM, t0

    # ---- CFG0 = {code_base=0x80100000 [63:32], entry_pc=0 [31:0]} ----
    li   t0, CODE_BASE
    slli t0, t0, 32
    csrw CSR_PVM_CFG0, t0

    # ---- CFG2 = {jt_z [35:32], jt_base=0x80200000 [31:0]} ----
    li   t0, JT_BASE
    li   t1, JT_Z
    slli t1, t1, 32
    or   t0, t0, t1
    li   t1, (1 << 36)                  # Stage 1: CFG2[36] = eret-via-jt. The M->S handoff mret maps
    or   t0, t0, t1                     # mepc through the jump table (a JT-encoded code address, not a
                                        # PVM-pc). Sticky: the cold-boot path has NO eret before the
                                        # handoff (hardcoded features skip the CSR trap-probe), so only
                                        # the handoff eret is affected.
    csrw CSR_PVM_CFG2, t0

    # ---- seed guest entry registers (shared regfile persists through the PVM switch) ----
    # OpenSBI _start: a0=hartid, a1=opaque(dtb ptr), a2=FW_NEXT_ARG (-> stored at [0x30058]).
    li   x8, 0                          # a0 (r7) = hartid 0
    li   x9, DTB_GUEST                  # a1 (r8) = guest DTB ptr 0x90000 (staged at phys 0x80090000)
    li   x10, 0                         # a2 (r9) = next-stage arg (stored to guest 0x30058)

    fence                               # publish ro/rw/code/jt DRAM writes to the fetch dcache

#ifdef SELFCHECK
    # DIAG: read code[0] from CODE_BASE and bitmask[0] from CODE_BASE+align16(CODE_LEN);
    # putchar each as 2 hex nibbles framed '<cc bb>' so we can confirm the ELF DRAM load.
    li   x15, 0x10000000                 # UART THR
    li   x14, '<'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    li   x11, CODE_BASE
    lbu  x12, 0(x11)                     # code[0] (expect 0x64)
    li   x11, CODE_BASE + ((CODE_LEN + 15) & ~15)
    lbu  x13, 0(x11)                     # bitmask[0] (expect 0x15)
    # print x12 as 2 hex digits
    srli x14, x12, 4
    call hexnib
    mv   x14, x12
    call hexnib
    li   x14, ' '
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    srli x14, x13, 4
    call hexnib
    mv   x14, x13
    call hexnib
    li   x14, '>'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
#endif

    # ---- enter PVM in DRAM demand-fetch mode ----
    # CFG1 = (1<<34)|(1<<32)|CODE_LEN  -- built with explicit shifts (li+slli safe for >31 bits)
    li   t0, CODE_LEN
    li   t1, 1
    slli t1, t1, 34                     # FETCH_DRAM bit
    or   t0, t0, t1
    li   t1, 1
    slli t1, t1, 32                     # PVM_ACTIVE bit
    or   t0, t0, t1
    csrw CSR_PVM_CFG1, t0

wait_pvm:
    j    wait_pvm

    # ---------------------------------------------------------------------------
    # Host trap handler: any PVM host-boundary exit (ecalli/panic/fault) lands here.
    # OpenSBI uses ecalli=0 only as its host-call ABI base; early boot makes NO host
    # calls (console is direct MMIO), so reaching here early == a fault. We emit a
    # one-char marker ('!'+the mcause low nibble is overkill; just print 'X' and the
    # raw mcause/mepc are visible in the trace) then resume so the trace keeps going.
    # ---------------------------------------------------------------------------
    .align 2
host_trap:
    csrr x14, mcause
    li   x15, 11                        # ENV_CALL_M (ecalli host-boundary)
    bne  x14, x15, trap_fault
    # ecalli host-call: OpenSBI early boot shouldn't hit this; just resume.
    # CFG1 = (1<<34)|(1<<33)|(1<<32)|CODE_LEN -- explicit shifts, >31 bits unsafe in #define
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

#ifdef SELFCHECK
    # print low nibble of x14 as a hex char to UART (x15 = THR). Clobbers x14.
    .align 2
hexnib:
    andi x14, x14, 0xf
    li   x6, 10
    blt  x14, x6, 1f
    addi x14, x14, 'a' - 10 - '0'
1:  addi x14, x14, '0'
    sb   x14, 0(x15)
    lbu  x14, 0x14(x15)
    ret
#endif

    # ---- embedded guest image regions (placed by link_opensbi.ld) ----
    .section .pvm_code,"a",@progbits
    .globl pvm_code
pvm_code:
    .incbin "opensbi.code.bin"

    .section .pvm_jt,"a",@progbits
    .globl pvm_jt
pvm_jt:
    .incbin "opensbi.jt.bin"

    .section .pvm_ro,"a",@progbits
    .globl pvm_ro
pvm_ro:
    .incbin "opensbi.ro.bin"

    .section .pvm_dtb,"a",@progbits
    .globl pvm_dtb
pvm_dtb:
    .incbin DTB_PATH

    .section .pvm_rw,"a",@progbits
    .globl pvm_rw
pvm_rw:
    .incbin "opensbi.rw.bin"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
