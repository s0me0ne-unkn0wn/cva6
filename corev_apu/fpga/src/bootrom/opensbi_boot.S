# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# OpenSBI-on-PolkaVM bootrom launch (FPGA / Genesys2). This is the HARDWARE port of the
# Verilator loader verif/tests/custom/pvm_run/loader_opensbi.S: it programs the PVM CSRs so
# the CVA6-PVM front-end demand-fetches a REAL OpenSBI build (the genuine fw_payload.bin,
# emit-image, ~125 KB) from DRAM and runs it as a JAM/PVM guest, then services the guest's
# ecalli host-calls (the OpenSBI console putchar) so its banner appears on the ns16550 UART.
#
# WHY a separate routine (vs baking the image like pvm_boot.S): the bootrom ROM is ~11.7 KB
# (bootrom_64.sv RomSize), far too small for the 2 MB OpenSBI DRAM image. So the image is NOT
# baked here -- it is STAGED into DRAM out-of-band (JTAG/gdb `restore`, or SD copy) BEFORE this
# routine programs the CSRs. This file is staging-AGNOSTIC: it only does the CSR launch + the
# host-trap handler. See OPENSBI_FPGA_BRINGUP.md for the staging recipe.
#
# DRAM layout this routine assumes is already present (mirror loader_opensbi.S + link_opensbi.ld):
#   .pvm_ro   @ 0x80010000  (guest 0x10000)   ro_data
#   .pvm_rw   @ 0x80030000  (guest 0x30000)   rw_init ; BSS [0x80030b00,0x80031738) zeroed here
#   .pvm_dtb  @ 0x80090000  (guest 0x90000)   devicetree blob (a1 points here)
#   .pvm_code @ 0x80100000  (CFG0 code_base)  code + pad + bitmask (M3 demand-fetch)
#   .pvm_jt   @ 0x80200000  (CFG2 jt_base)    jump table (z = JT_Z)
# i.e. exactly the flat image `objcopy -O binary loader_opensbi.elf` produces, loaded at
# 0x80000000 (a single contiguous PT_LOAD). Nothing in [0x40000,0x100000) is MMIO, so the whole
# widened aperture passes through to DRAM.
#
# IMPORTANT: use `lla` (NOT `la`) for label addresses -- this bootrom is PIE, so `la` loads from
# the GOT whose R_RISCV_RELATIVE reloc a bare-metal boot never applies (-> 0 -> mtvec=0 -> every
# trap hangs). `lla` is PC-relative. (Project memory: a 9-build FPGA hang saga was exactly this.)
#
# CFG1 flag bits are >32-bit; the C preprocessor does 32-bit arithmetic and would silently
# overflow `(1<<34)`. Build the 64-bit CFG1 value with explicit li+slli+or in assembly.

#define CSR_PVM_CFG0 0xbc0          /* {code_base [63:32], entry_pc [31:0]} */
#define CSR_PVM_CFG1 0xbc1          /* {.., FETCH[34], RESUME[33], ACTIVE[32], code_len [31:0]} */
#define CSR_PVM_CFG2 0xbc2          /* {jt_z [35:32], jt_base [31:0]} */
#define CSR_PVM_VEC  0xbc4          /* host-boundary exit vector (B4); survives a guest mtvec write */
#define CSR_PVM_RAM  0xbc5          /* {ram_hi_page [63:48], ram_lo_page [47:32], ram_base [31:0]} */

# --- OpenSBI DRAM image geometry (TRACK loader_opensbi.S / opensbi_to_dram.py at port time) ----
# CODE_LEN = emit-image header code_size (NOT the padded code-region size). For the current
# cva6-sdk/install64e_genesys2/fw_payload.bin: code_size=85658, jt_entry=3, entry_pc=0,
# rw_img=2816 (-> BSS_LO guest 0x30b00), rw_tot=5944 (-> BSS_HI guest 0x31738).
# Overridable from the Makefile (-DCODE_LEN=.. -DJT_Z=..) so a rebuilt image needs no edit here.
#ifndef CODE_LEN
#define CODE_LEN 85658
#endif
#ifndef JT_Z
#define JT_Z 3
#endif

#define RAM_BASE   0x80000000
#define CODE_BASE  0x80100000          /* CFG0 code_base (M3 demand-fetch) */
#define JT_BASE    0x80200000          /* CFG2 jt_base */
#define BSS_LO     0x80030b00          /* guest 0x30b00 (= 0x30000 + rw_img) */
#define BSS_HI     0x80031738          /* guest 0x31738 (= 0x30000 + rw_tot) */
#define DTB_GUEST  0x90000             /* a1 = FW_PAYLOAD_FDT_OFFSET; phys 0x80090000 */

#define UART_BASE    0x10000000        /* ariane_soc::UARTBase (ns16550 THR @ +0) */
#define UART_LSR_OFF 0x14              /* line status register (reg 5, 4-byte stride) */
#define LSR_THRE     0x20              /* LSR bit 5: transmit holding register empty */

# --- JTAG/gdb staging handshake (default ON) -------------------------------------------------
# When the host preloads DRAM over JTAG it is simplest NOT to have to know this routine's entry
# address: instead the bootrom spins on a "ready" magic word in DRAM, and the host writes the
# magic (via gdb `set {int}<addr>=<magic>`) once the image is staged. Define OPENSBI_NO_WAIT
# (e.g. for the SD path, where main.c has already finished the copy) to skip the spin and launch
# immediately. The magic word lives ABOVE the OpenSBI image (which ends ~0x802015e1) and above
# the guest aperture, so neither the `restore` of the flat image nor the guest can ever clobber
# it -- the restore/write order is then irrelevant. It is free DRAM, not MMIO.
#ifndef OPENSBI_NO_WAIT
#define OPENSBI_WAIT_MAGIC 1
#endif
#define READY_ADDR  0x80300000         /* free DRAM above the image + aperture; clobber-proof */
#define READY_MAGIC 0x5042564d         /* "MVBP" -> the host writes this when DRAM is staged */
/* Host-trap register save area: the putchar host-trap handler must PRESERVE the guest's
 * x12-x15 (a2-a5) across the ecalli, otherwise a pvm_putc() placed where those regs are live
 * (e.g. inside a loop) silently corrupts the guest. Free host DRAM above the image/aperture;
 * the guest (aperture [0x10000,0x100000)) can never touch it. +32 holds the precomputed CFG1
 * resume value so the resume path needs only ONE scratch reg (a0, which pvm_putc clobbers). */
#define SAVE_AREA   0x80300040

    .section .text,"ax",@progbits
    .globl opensbi_pvm_boot
opensbi_pvm_boot:
#ifdef OPENSBI_WAIT_MAGIC
    # ---- wait for the host (JTAG/gdb) to finish staging the OpenSBI DRAM image ----
    # The host: (1) loads the flat image at 0x80000000, (2) `set {int}0x80000800 = 0x5042564d`.
    li   t1, READY_ADDR
    li   t2, READY_MAGIC
1:  lw   t0, 0(t1)                  # poll the ready word (uncached DRAM read)
    bne  t0, t2, 1b                 # spin until the host signals "image staged"
#endif

    # ---- host trap vector (PVM host-boundary exit: ecalli / panic / fault) ----
    lla  t0, opensbi_trap_handler   # lla = PC-relative, bare-metal safe (la uses GOT -> 0)
    csrw CSR_PVM_VEC, t0            # B4: the one door out of the PVM sandbox
    csrw mtvec, t0                  # legacy fallback (pvm_vec != 0 here, so PVM_VEC wins)

    # ---- zero the guest BSS [BSS_LO, BSS_HI) (OpenSBI _start re-zeroes, but do it here so a
    #      partial bss from a prior run / staging can't poison early reads) ----
    li   t0, BSS_LO
    li   t1, BSS_HI
1:  sd   x0, 0(t0)
    addi t0, t0, 8
    bltu t0, t1, 1b

    # ---- guest-RAM -> DRAM aperture: ram_base=0x80000000, window [0x10000,0x100000) ----
    # CSR_PVM_RAM = [31:0]=ram_base, [47:32]=ram_lo_page(1 -> 0x10000), [63:48]=ram_hi_page(0x10 -> 0x100000)
    li   t0, RAM_BASE               # [31:0]
    li   t1, 1
    slli t1, t1, 32                 # ram_lo_page = 1  -> guest window low  0x10000
    or   t0, t0, t1
    li   t1, 0x10
    slli t1, t1, 48                 # ram_hi_page = 0x10 -> guest window high 0x100000
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
    csrw CSR_PVM_CFG2, t0

    # ---- seed guest entry registers (shared regfile persists through the PVM switch) ----
    # OpenSBI _start: a0=hartid, a1=opaque(dtb ptr), a2=FW_NEXT_ARG. PVM guest regs r7/r8/r9
    # map to x8/x9/x10 (NOT the RISC-V ABI names -- this is the PVM shared-regfile convention,
    # same as pvm_boot.S / loader_opensbi.S).
    li   x8,  0                     # a0 (r7) = hartid 0
    li   x9,  DTB_GUEST             # a1 (r8) = guest DTB ptr 0x90000 (staged at phys 0x80090000)
    li   x10, 0                     # a2 (r9) = next-stage arg (stored to guest 0x30058)

    fence                           # publish ro/rw/code/jt DRAM writes to the fetch dcache path

    # ---- precompute the CFG1 RESUME value for the host-trap handler ----
    # CFG1_RESUME = (1<<34)|(1<<33)|(1<<32)|CODE_LEN ; stash at SAVE_AREA+32 so the handler's
    # resume path needs only one scratch register (so it can preserve the guest's x12-x15).
    li   t0, CODE_LEN
    li   t1, 1
    slli t1, t1, 34
    or   t0, t0, t1
    li   t1, 1
    slli t1, t1, 33
    or   t0, t0, t1
    li   t1, 1
    slli t1, t1, 32
    or   t0, t0, t1
    li   t1, SAVE_AREA
    sd   t0, 32(t1)

    # ---- enter PVM in DRAM demand-fetch mode ----
    # CFG1 = (1<<34)|(1<<32)|CODE_LEN  -- explicit shifts (li+slli safe for >31-bit fields)
    csrw CSR_PVM_CFG1, x0           # clear -> clean 0->1 edge on the next write
    li   t0, CODE_LEN
    li   t1, 1
    slli t1, t1, 34                 # FETCH_DRAM bit
    or   t0, t0, t1
    li   t1, 1
    slli t1, t1, 32                 # PVM_ACTIVE bit
    or   t0, t0, t1
    csrw CSR_PVM_CFG1, t0           # rising edge of active -> enter PVM

wait_pvm:
    j    wait_pvm                   # busy-loop (NOT wfi): keep the pipeline live for PVM uops

    # ---------------------------------------------------------------------------
    # Host trap handler: any PVM host-boundary exit (ecalli / panic / fault) lands here via
    # CSR_PVM_VEC. OpenSBI's console putchar is host-call #0 (ecalli 0): mcause == 11
    # (ENV_CALL_M) and mtval == the host-call number. #0 = putchar(a0) -> ns16550 THR; resume.
    # A non-ecalli trap (real fault) prints a one-char marker and parks.
    # ---------------------------------------------------------------------------
    .align 2
opensbi_trap_handler:
    # ---- PRESERVE the guest's x12-x15 (a2-a5): save them to SAVE_AREA before we clobber them.
    #      Bootstrap the base in x10 (a0) -- pvm_putc already clobbers a0, so the guest never
    #      relies on it across the ecalli; this avoids touching mscratch (the guest's scratch base). ----
    li   x10, SAVE_AREA
    sd   x12, 0(x10)
    sd   x13, 8(x10)
    sd   x14, 16(x10)
    sd   x15, 24(x10)
    # x10=SAVE_AREA; x12-x15 saved -> now free to clobber
    csrr x14, mcause
    li   x15, 11                    # ENV_CALL_M (ecalli host-boundary)
    bne  x14, x15, trap_fault
    # ---- ecalli host-call: dispatch on the host-call number in mtval ----
    csrr x14, mtval                 # host-call # (the ecalli immediate)
    bnez x14, hostcall_resume       # only #0 (putchar) is implemented; others -> just resume
    # host-call #0 = putchar(x8). inline (x15=UART, x14=char, x13=LSR temp; x12 free too).
    li   x15, UART_BASE
    mv   x14, x8                    # char to emit (PVM guest arg r7 == x8)
1:  lbu  x13, UART_LSR_OFF(x15)     # wait for THR empty
    andi x13, x13, LSR_THRE
    beqz x13, 1b
    sb   x14, 0(x15)                # THR <- char
    lbu  x13, UART_LSR_OFF(x15)     # uncached LSR read drains the store buffer (MMIO serialize)
hostcall_resume:
    # ---- restore the guest's x12-x15, then resume PVM ----
    li   x10, SAVE_AREA
    ld   x12, 0(x10)
    ld   x13, 8(x10)
    ld   x14, 16(x10)
    ld   x15, 24(x10)
    # CFG1 resume edge via x10 (a0, clobberable): clear-pulse then write the precomputed CFG1_RESUME.
    csrw CSR_PVM_CFG1, x0           # clear-pulse (spaces the re-entry edge)
    li   x10, SAVE_AREA
    ld   x10, 32(x10)              # precomputed (1<<34)|(1<<33)|(1<<32)|CODE_LEN
    csrw CSR_PVM_CFG1, x10
    j    wait_pvm

trap_fault:
    # A real fault (load/store access, illegal, etc.). Mark it on the UART, then park. The raw
    # mcause/mepc/mtval are visible to an attached debugger for the post-mortem.
    li   x15, UART_BASE
    li   x14, '!'
    jal  x13, putc
    li   x14, 'F'
    jal  x13, putc
fault_park:
    j    fault_park

putc:                               # putchar(x14) with THRE flow control; link register in x13
1:  lbu  x12, UART_LSR_OFF(x15)     # wait for THR empty
    andi x12, x12, LSR_THRE
    beqz x12, 1b
    sb   x14, 0(x15)                # THR <- char
    lbu  x12, UART_LSR_OFF(x15)     # uncached LSR read drains the store buffer (MMIO serialize)
    jr   x13
