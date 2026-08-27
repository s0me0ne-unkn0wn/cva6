# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Boot a REAL NOMMU RV64E Linux kernel (vmlinux.polkavm, polkatool link -i jam_v1_privileged
# --opt-level 0) as a PVM/JAM guest in Verilator (standalone: NO OpenSBI/U-Boot underneath --
# the kernel is NOMMU + CONFIG_RISCV_M_MODE=y, so it runs in M-mode and does its own timer/
# console MMIO; the goal of this first run is to empirically surface the FIRST runtime wall of
# vmlinux.polkavm via the commit trace, exactly like the U-Boot bring-up). The image is the
# genuine vmlinux.polkavm -> emit-image -> 128B-PVMI split by opensbi_to_dram.py into:
#   .pvm_code (code+pad+bitmask 4.6MB) @ 0x80200000  (M3 demand-fetch code_base)
#   .pvm_jt   (jump table z=3, 864KB)  @ 0x80700000  (CFG2 jt_base)
#   .pvm_ro   (ro_data 838656B)        @ 0x80010000  (= ram_base + guest 0x10000)
#   .pvm_rw   (rw_init bytes)           @ 0x80100000  (= ram_base + guest 0x100000; -Os RO grew the base)
# placed there by link_kernel.ld + .incbin below.
#
# Kernel PVM data layout (from polkavm-common/abi.rs MemoryMapBuilder, VM_MAX_PAGE_SIZE=0x10000):
#   ro @ guest 0x10000, region [0x10000, 0xE0000) (align_up(838656,0x10000)=0xD0000); guard 0x10000;
#   rw @ guest 0xF0000  (= 0x10000 + 0xD0000 + 0x10000-guard); init 750092 -> [0xF0000,0x1A72CC);
#   bss to heap_base 0x1DF0D0. These LOW addrs are covered by the guest-RAM->DRAM aperture
#   (CSR_PVM_RAM base 0x80000000, window [0x10000,0x200000) = 2MB, big enough for the kernel's
#   ~2MB ro+rw+bss -- vs U-Boot's [0x10000,0x100000)). The kernel's head.S sets its OWN sp from
#   init_thread_union (a data symbol in rw -> guest 0xF0000+, in the aperture), like U-Boot's _start
#   hard-set its sp -- so the polkavm entry sp (stack_address_high 0xFFFE0000) is transient and
#   never actually used (watch the trace for any 0xFFFE0000 access just in case). MMIO (UART
#   0x10000000) + the DTB (guest 0x80800000) fall OUTSIDE the aperture -> LSU pass-through (identity
#   low-32) -> right back into physical DRAM/MMIO. We run M-mode (the kernel is M-mode NOMMU).
#
# CFG2: NO bit36(eret-via-jt)/bit37(trap-via-jt) for this FIRST run (minimal, matches the proven
# loader_uboot.S standalone pattern) -- the kernel takes no traps during early boot (irqs off, no
# faults if the memory model holds), so the first wall is far more likely a memory-model/opcode
# fault (cf. U-Boot's reset_cpu) surfaced via host_trap + the trace than a trap-handling issue.
# If the first wall turns out to be an early trap, add trap-via-jt (bit37) then.
#
# SUCCESS observable = the first guest UART byte (the kernel's earlycon) OR, more likely for a
# first run, the commit trace localizing the FIRST fault (its PVM-pc, priv, data address).

#define CSR_PVM_CFG0 0xbc0
#define CSR_PVM_CFG1 0xbc1
#define CSR_PVM_CFG2 0xbc2
#define CSR_PVM_VEC  0xbc4
#define CSR_PVM_RAM  0xbc5
#define PVM_HC_GROW  2     /* ecalli id: guest kernel asks the host to grow CFG1.code_len (B2) */

#ifndef CODE_LEN
#define CODE_LEN 4095920
#endif
#ifndef JT_Z
#define JT_Z 3
#endif
#ifndef RW_IMG
#define RW_IMG 750092
#endif
#ifndef RW_TOTAL
#define RW_TOTAL 979088
#endif

#define CODE_BASE  0x80820000
#define JT_BASE    0x80C00000
#define RAM_BASE   0x80000000

/* guest data bases (computed from abi.rs): ro@0x10000, rw@RW_GUEST.  bss = [rw_base+RW_IMG, rw_base+RW_TOTAL)
   abi.rs: rw_base = 0x10000 + align_up(RO,0x10000) + 0x10000(guard). RW_GUEST MUST equal polkatool's
   actual rw_data_address for THIS image -- pass -DRW_GUEST=$(RW_BASE from opensbi_to_dram.py). The
   hard-coded fallback went stale twice (-Os growth 0xF0000->0x100000; minimal-config shrink ->0xC0000,
   which loaded every static kernel pointer as zeros -> NULL sched_clock fptr -> _start restart loop). */
#ifndef RW_GUEST
#define RW_GUEST   0x100000
#endif
/* 8B-aligned (round UP) so the `sd x0` bss-zero loop never hits a misaligned store -- CVA6 traps
   misaligned accesses; RW_IMG=750092 leaves the raw rw-end (0x801a72cc) only 4B-aligned. The <8B
   skipped at the bottom is already preload-zeroed (the PT_LOAD spans the gap to .pvm_code). */
#define BSS_LO     ((RAM_BASE + RW_GUEST + RW_IMG + 7) & ~7)     /* phys 0x801a72d0 */
#define BSS_HI     ((RAM_BASE + RW_GUEST + RW_TOTAL + 7) & ~7)   /* phys 0x801df0d0 */

#define DTB_GUEST  0x80D00000          /* a1: pass-through (OUTSIDE aperture) -> phys 0x80D00000 */

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

    # ---- guest-RAM -> DRAM aperture: ram_base=0x80000000, window [0x10000,0x810000) = 8 MiB ----
    # The ENTIRE kernel RAM (static data ro@0x10000/rw@0x100000/bss-to-~0x1ec090 AND all dynamic
    # pages the buddy/SLUB allocator hands out) lives in this ONE low guest window, backed by DRAM
    # [0x80010000,0x80810000). Unified-low-base memory model: the DTB memory node is memory@10000
    # (size 0x800000) so memblock_start_of_DRAM()=0x10000 -> phys_ram_base = 0x10000 & PMD_MASK = 0
    # -> ARCH_PFN_OFFSET=0 -> the FLATMEM mem_map covers the LOW pfns where the kernel's static
    # symbols actually reside (NOMMU virt==phys), so __pa_symbol()/virt_to_page() of static data
    # index INSIDE mem_map (vs the old high 0x80000000 node: ARCH_PFN_OFFSET=0x80000 -> static pfn
    # 0x10 -> mem_map[-0x7fff0] -> bogus page struct). This is the CORRECT NOMMU memory model and
    # eliminates the bogus rodata/page-struct addresses. (NOTE: this alone does NOT clear the SLAB
    # kmem_cache size=192 panic -- that is a separate polkatool page-allocator codegen defect,
    # proven layout/size-independent: 8 MiB and 48 MiB RAM both panic identically. See findings.)
    # MMIO (0x10000000), the code/jt blobs (0x80820000/0x80C00000) and the DTB (0x80D00000) are OUTSIDE
    # this window -> LSU pass-through (identity low-32) -> their own DRAM/MMIO (NOT remapped).
    # CSR_PVM_RAM = [31:0]=ram_base, [47:32]=ram_lo_page(1->0x10000), [63:48]=ram_hi_page(0x81->0x810000)
    li   t0, RAM_BASE
    li   t1, 1
    slli t1, t1, 32
    or   t0, t0, t1
    li   t1, 0x81
    slli t1, t1, 48
    or   t0, t0, t1
    csrw CSR_PVM_RAM, t0

    # ---- CFG0 = {code_base=0x80200000 [63:32], entry_pc=0 [31:0]} ----
    li   t0, CODE_BASE
    slli t0, t0, 32
    csrw CSR_PVM_CFG0, t0

    # ---- CFG2 = {trap_via_jt [37], jt_z [35:32], jt_base=0x80700000 [31:0]} ----
    # bit37 (trap-via-JT) ON: the kernel sets mtvec via `lla handle_exception; csrw mtvec`, which in
    # PVM yields a JT TOKEN (not a raw PVM-pc). When the guest takes a synchronous trap it services
    # itself (e.g. a misaligned-load fault -> CONFIG_RISCV_MISALIGNED do_trap_load_misaligned, which
    # software-emulates the access), the HW must map that mtvec token through the jump table to reach
    # handle_exception's real PVM-pc -- exactly the S-mode SBI trap-via-jt path (CFG2[37], cont.29).
    # Without it the trap to the raw token 0x74086 fetch-faults forever (the kernel boot wall right
    # after calibrate_delay, at mnt_init's first misaligned access). bit36 (eret-via-jt) stays OFF:
    # the kernel's trap-return mepc is the RAW faulting PVM-pc (the misalign emulator advances mepc),
    # so its mret is a normal direct-pc eret, not a JT-mapped handoff.
    li   t0, JT_BASE
    li   t1, JT_Z
    slli t1, t1, 32
    or   t0, t0, t1
    li   t1, 1
    slli t1, t1, 37                     # trap-via-JT: guest sync traps -> mtvec token mapped via JT
    or   t0, t0, t1
    # bit38 (async-IRQ-to-guest): deliver pending machine interrupts (CLINT MTIP first of
    # all) to the guest at uop boundaries -- the guest kernel owns the machine, so its
    # timer ticks/jiffies must fire (and the no-IRQ 8250 tty TX ring must drain). The
    # injected interrupt rides the same stay-trap/mtvec-via-JT path as bit37 sync faults.
    li   t1, 1
    slli t1, t1, 38
    or   t0, t0, t1
    csrw CSR_PVM_CFG2, t0

    # ---- seed guest entry registers: RISC-V Linux boot protocol a0=hartid, a1=dtb ----
    # (mirror loader_uboot.S, which correctly delivered a0/a1 to U-Boot: x8=a0, x9=a1, x10=a2.)
    li   x8, 0                          # a0 = hartid 0
    li   x9, DTB_GUEST                  # a1 = dtb ptr (phys 0x80800000 via pass-through)
    li   x10, 0                         # a2

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
    csrw CSR_PVM_CFG1, x0               # FPGA: clear first -> clean 0->1 ACTIVE edge
    csrw CSR_PVM_CFG1, t0               # rising edge of ACTIVE -> enter PVM

wait_pvm:
    j    wait_pvm

    # ---------------------------------------------------------------------------
    # Host trap handler. ENV_CALL_M (ecalli) = the kernel's SBI/host-call ABI base -> just
    # resume (early boot makes no real host call; reaching here early is informational).
    # Any other cause = a real fault: mark '!F' on the UART, dump via the trace, park.
    # ---------------------------------------------------------------------------
    .align 2
host_trap:
    csrr x14, mcause
    li   x15, 11                        # ENV_CALL_M
    bne  x14, x15, trap_fault
    # ecalli host-call from the GUEST KERNEL (M-mode). The host-call id is in mtval (B3 ABI).
    # B2 GROW (id PVM_HC_GROW): the kernel's binfmt_pvm appended a userspace program to the
    # code region + rebuilt the bitmask, and asks the host to grow CFG1.code_len to a0 (PVM r7
    # = HW x8, the sole ecalli-surviving register). The guest CANNOT csrw CFG1 itself (0xBC1 is not in
    # the pvm_decoder csr_fence set, so its commit-flush derails fetch -> ILLEGAL). The host
    # keeps the live code_len in CFG1[31:0] itself (re-read via csrr on a plain resume).
    # Any other id: plain resume with the current code_len.
    # NO LOADS ON THIS PATH (B2 deadlock lesson, 2026-08-27): a host-boundary exit can leave the
    # PVM M3 demand-fetch port (dcache port 0, top priority) waiting for a tag it never gets
    # (pre-fix RTL), which starves every load in the core until the resume start_pulse kills it.
    # So the current code_len is re-read from CFG1[31:0] (a CSR, not memory) and the GROW value
    # arrives in a register -- the path below is CSR/ALU/store only, and the resume itself is
    # what releases the port. (Stores still drain, so the 'G' marker is safe.)
    csrr x14, mtval
    li   x15, PVM_HC_GROW
    bne  x14, x15, 1f
    # REGISTER MAP GOTCHA: pvm_decoder maps PVM rN -> RISC-V x(N+1) (r0=ra must not alias
    # x0). So the guest's PVM a0 (r7) lives in HW x8, NOT x10 (x10 = PVM a2). Same rule as the
    # boot seeding above (x8=a0, x9=a1) and loader_codeappend.S (putchar(r7==x8)).
    mv   x15, x8                        # x15 = new code_len = PVM a0 (HW x8)
    li   x14, 0x10000000                # DIAG 'G' = GROW arrived (plain sb: touches only x14/x15,
    li   x8, 0x47                       # which are not PVM registers -> nothing of the guest is
    sb   x8, 0(x14)                     # clobbered; x8 = PVM a0 is a declared ecalli clobber)
    j    2f
1:  csrr x15, CSR_PVM_CFG1              # plain resume: keep the live code_len = CFG1[31:0]
    slli x15, x15, 32
    srli x15, x15, 32
2:  csrw CSR_PVM_CFG1, x0               # falling edge, then the rising edge below = start_pulse
    li   x14, 1
    slli x14, x14, 34                   # FETCH_DRAM
    or   x15, x15, x14
    li   x14, 1
    slli x14, x14, 33                   # RESUME
    or   x15, x15, x14
    li   x14, 1
    slli x14, x14, 32                   # ACTIVE
    or   x15, x15, x14
    csrw CSR_PVM_CFG1, x15
    j    wait_pvm

trap_fault:
    # A real fault (load/store access, illegal, etc.). DIAGNOSTIC: print the PVM-exit
    # cause + pc so we can root-cause the wall (decoder gap vs memory vs config).
    #   mcause = WHY the guest exited PVM (2=illegal-instr/decoder-gap, 5/7=load/store-access,
    #            4/6=misaligned, ...);  mepc = the faulting guest PVM-pc (== byte offset into
    #            the .pvm_code blob == polkatool-disassemble offset of the faulting op).
    # GOTCHA (reference_pvm_fpga_diag_gotchas): capture BOTH into callee-saved regs (s0/s1 =
    # x8/x9; RV64E lp64e has only x0..x15 -- s2/s3 do NOT exist) FIRST -- the UART path here is
    # a plain RISC-V `sb` (NOT a PVM ecalli), but be safe and re-read every hex digit from the
    # captured copy. The hex helper uses only a0/t0/t1/t2/ra, never s0/s1, so the captured
    # values survive the whole emit. We never return to the guest (we park), so clobbering
    # s0/s1 is harmless.
    csrr s0, mcause                     # s0 = captured mcause (survives the UART stores)
    csrr s1, mepc                       # s1 = captured mepc (the faulting PVM-pc)
    li   x15, 0x10000000                # UART THR base (kept in x15 across the prints)

    li   a0, '!'
    jal  ra, putc_fault
    li   a0, 'F'
    jal  ra, putc_fault
    li   a0, ' '
    jal  ra, putc_fault
    li   a0, 'C'
    jal  ra, putc_fault
    li   a0, '='
    jal  ra, putc_fault
    mv   a0, s0                         # re-read captured mcause
    jal  ra, puthex64
    li   a0, ' '
    jal  ra, putc_fault
    li   a0, 'P'
    jal  ra, putc_fault
    li   a0, '='
    jal  ra, putc_fault
    mv   a0, s1                         # re-read captured mepc (PVM-pc)
    jal  ra, puthex64
    li   a0, '\n'
    jal  ra, putc_fault

    li   t2, 4000
2:  addi t2, t2, -1
    bnez t2, 2b
    li   t0, 1
    lla  t1, tohost                     # lla = PC-relative, bare-metal safe
    sd   t0, 0(t1)
fault_park:
    j    fault_park

    # ---- emit one char a0[7:0] to the UART with THRE flow control (x15 = THR base) ----
    # CRITICAL (FPGA char-drop gotcha, reference_pvm_fpga_diag_gotchas / opensbi_boot.S:233): the
    # ns16550 TX FIFO drops chars written back-to-back -> a multi-char string (our hex dump) loses
    # all but the first 1-2 bytes unless we WAIT for LSR bit5 (THRE = TX-holding-empty) before each
    # write. The bare `sb;lbu` form only serialized the dcache; it did NOT throttle to the UART, so
    # the first run printed only "!F" and dropped the whole " C=.. P=.." tail. Uses only a0 + t0.
    .align 2
putc_fault:
6:  lbu  t0, 0x14(x15)                  # poll LSR
    andi t0, t0, 0x20                   # THRE (bit 5): TX holding register empty?
    beqz t0, 6b                         # spin until ready (FIFO has room)
    sb   a0, 0(x15)                     # THR <- char
    lbu  t0, 0x14(x15)                  # uncached LSR read drains the store buffer (MMIO serialize)
    ret

    # ---- emit a0 as 16 hex digits, MSB first (re-reads only a0; t1=value, t2=saved-ra, t0=shift,
    # ra=putc scratch). Each digit goes through putc_fault so THRE flow-control applies uniformly. ----
    .align 2
puthex64:
    mv   t1, a0                         # t1 = the 64-bit value to print (a0 is clobbered below)
    mv   t2, ra                         # save return (the inline putc below clobbers ra)
    li   t0, 60                         # shift amount, 60 down to 0 in steps of 4
3:  srl  a0, t1, t0
    andi a0, a0, 0xf
    li   ra, 10
    blt  a0, ra, 4f
    addi a0, a0, 'a' - 10 - '0'         # nudge a..f so the common +'0' below lands on 'a'..'f'
4:  addi a0, a0, '0'                    # 0..9 (digits >=10 already nudged above -> a..f)
    # inline THRE-polled putc (can't `jal` -- t0/t1/t2 are loop-live; ra is the only free scratch)
7:  lbu  ra, 0x14(x15)
    andi ra, ra, 0x20                   # THRE: wait for TX holding empty
    beqz ra, 7b
    sb   a0, 0(x15)                     # THR <- digit
    lbu  ra, 0x14(x15)                  # serialize
    beqz t0, 5f
    addi t0, t0, -4
    j    3b
5:  mv   ra, t2
    ret

    # ---- embedded guest image regions (placed by link_kernel.ld) ----
    .section .pvm_code,"a",@progbits
    .globl pvm_code
pvm_code:
    .incbin "kernel.code.bin"

    .section .pvm_jt,"a",@progbits
    .globl pvm_jt
pvm_jt:
    .incbin "kernel.jt.bin"

    .section .pvm_ro,"a",@progbits
    .globl pvm_ro
pvm_ro:
    .incbin "kernel.ro.bin"

    .section .pvm_dtb,"a",@progbits
    .globl pvm_dtb
pvm_dtb:
    .incbin DTB_PATH

    .section .pvm_rw,"a",@progbits
    .globl pvm_rw
pvm_rw:
    .incbin "kernel.rw.bin"

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
