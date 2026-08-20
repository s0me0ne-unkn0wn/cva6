#!/usr/bin/env python3
# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
"""Generate a PolkaVM JAM image (.hex) for the CVA6 pvm_front BRAM loader.

The image layout matches core/frontend/pvm_front.sv:
  * code at offset 0
  * opcode bitmask at align16(code_len)
The bitmask is LSB-first: bit i of byte j flags code byte (8*j + i) as an
instruction start. Output is Verilog $readmemh format (one hex byte per line,
'@addr' block headers), loaded via +PVM_IMG.

This generator removes the hand-encoding hazard (a mis-placed bitmask offset
silently splits instructions). It prints the resulting CODE_LEN for the loader
build (-DCODE_LEN=N).

JAM opcodes used (see core/include/polkavm_pkg.sv):
  0x14 (20)  load_imm64    reg + 8-byte LE imm
  0x33 (51)  load_imm      reg + variable LE imm (here 1 byte, ASCII < 0x80)
  0x78 (120) store_ind_u8  [rbase] = rsrc(low byte); arg nibble lo=rsrc hi=rbase
  0x00 (0)   trap          halt -> M-mode

The UART console path: mock_uart (testharness, InclUART=0 under Verilator)
prints pwdata[7:0] on every THR write. Storing a byte to UART base 0x10000000
therefore emits one character; ((paddr>>2)&7)==0 selects THR.
"""
import sys

# ---- JAM opcodes ----------------------------------------------------------
TRAP         = 0x00
LOAD_IMM_64  = 0x14
LOAD_IMM     = 0x33
STORE_IND_U8 = 0x78
STORE_IND_U32 = 0x7a   # 122: [rbase+off] = rval (word); byte1=(rbase<<4)|rval, then off
STORE_IND_U64 = 0x7b   # 123: [rbase+off] = rval (dword); byte1=(rbase<<4)|rval, then off
LOAD_IND_U8  = 0x7c   # 124: rd = [rbase + off]; nibble lo=rd, hi=rbase
ECALLI       = 0x0a   # 10: host-call; imm = host-call id (read from offset 1)
MRET         = 0xed   # 237: return-from-handler (PVM-pc redirect to mepc)
SRET         = 0xee   # 238: return-from-handler (PVM-pc redirect to sepc)

UART_THR = 0x10000000  # ariane_soc::UARTBase; mock_uart THR @ ((paddr>>2)&7)==0
UART_LSR_OFF = 0x14    # line status register offset (reg 5, 4-byte stride)

# PVM register file uses r0..r12; r0 is the magic halt reg, keep r7/r8 as
# scratch (PVM rN -> RISC-V GPR(N+1), so r7->x8, r8->x9).
R_CHAR = 7   # holds the character to emit
R_BASE = 8   # holds the UART THR base address
R_SCR  = 6   # scratch for the serializing LSR read


def le(value, nbytes):
    """Little-endian byte list of `value` in `nbytes` bytes."""
    return [(value >> (8 * i)) & 0xFF for i in range(nbytes)]


def emit_banner(text, serialize=True):
    """Return (code_bytes, instr_starts) for a putchar banner of `text`.

    With serialize=True a dummy LSR read (load_ind_u8 [r8+0x14]) follows every
    THR write. An uncached load in CVA6 waits for the store buffer to drain, so
    this orders the MMIO writes one-at-a-time. Without it, rapid back-to-back
    same-address uncached writes get coalesced in the WT-dcache bypass path and
    intermediate characters are lost (only first+last survive). This is also the
    correct UART protocol step (a real putchar polls LSR before writing THR)."""
    instrs = []
    # r8 = UART THR base (load_imm64: opcode, reg byte, 8 LE imm bytes)
    instrs.append([LOAD_IMM_64, R_BASE & 0x0F] + le(UART_THR, 8))
    for ch in text:
        c = ord(ch)
        assert 0 <= c < 0x80, f"char {ch!r}=0x{c:x} needs sext padding; keep ASCII"
        # r7 = c (load_imm: opcode, reg byte, 1 imm byte)
        instrs.append([LOAD_IMM, R_CHAR & 0x0F, c])
        # store_ind_u8 r7 -> [r8] : arg nibble lo=rsrc(r7), hi=rbase(r8), off=0
        instrs.append([STORE_IND_U8, ((R_BASE & 0xF) << 4) | (R_CHAR & 0xF)])
        if serialize:
            # load_ind_u8 r6 <- [r8 + 0x14] : nibble lo=rd(r6), hi=rbase(r8)
            instrs.append([LOAD_IND_U8, ((R_BASE & 0xF) << 4) | (R_SCR & 0xF), UART_LSR_OFF])
    instrs.append([TRAP])

    code = []
    starts = []
    for ins in instrs:
        starts.append(len(code))
        code.extend(ins)
    return code, starts


def emit_ecalli_banner(text):
    """Return (code_bytes, instr_starts) for a putchar banner via host-calls.

    Per character: `load_imm r7, c` then `ecalli #0`. The M-mode handler reads the
    char from PVM r7 (== x8), writes the UART, and resumes the guest at next_pc.
    Each ecalli is its own M-mode round-trip, so the MMIO writes are naturally
    spaced (no WT-dcache coalescing) and the guest never touches MMIO directly --
    the faithful PolkaVM host-call model. `ecalli #0` = [0x0a, 0x00] (id byte 0)."""
    instrs = []
    for ch in text:
        c = ord(ch)
        assert 0 <= c < 0x80, f"char {ch!r}=0x{c:x} needs sext padding; keep ASCII"
        instrs.append([LOAD_IMM, R_CHAR & 0x0F, c])   # r7 = c
        instrs.append([ECALLI, 0x00])                 # ecalli #0 (putchar)
    instrs.append([TRAP])

    code = []
    starts = []
    for ins in instrs:
        starts.append(len(code))
        code.extend(ins)
    return code, starts


def emit_ebreak_probe():
    """MICRO-TEST: where does a guest PVM `trap` (== polkatool's lowering of a RISC-V
    `ebreak`/`c.ebreak`, riscv.rs:1316/909 -> Inst::Unimplemented -> Instruction::trap)
    go -- the host (CSR_PVM_VEC) or the guest's own mtvec?

    Program: `load_imm r7,'E'` ; `ecalli #0` (host prints 'E' + resumes -- proves the
    round-trip works) ; `trap` (the ebreak-equivalent).  With the current RTL pvm_is_trap
    is in pvm_use_vec -> the `trap` is a HOST-boundary exit (mcause=ILLEGAL_INSTR=2 != 11)
    -> loader_ebreak.S host_trap prints '!F'.  Observable: 'E' then '!F' (NOT the guest
    handler's 'G').  Confirms a guest `trap` is NOT delivered to the guest tvec today."""
    instrs = []
    instrs.append([LOAD_IMM, R_CHAR & 0x0F, ord('E')])   # r7 = 'E'
    instrs.append([ECALLI, 0x00])                         # ecalli #0 (host putchar 'E')
    instrs.append([TRAP])                                 # the ebreak-equivalent
    code = []
    starts = []
    for ins in instrs:
        starts.append(len(code))
        code.extend(ins)
    return code, starts


BRANCH_EQ = 0xAA   # 170: branch if rA==rB; arg = (rB<<4)|rA, then signed LE offset
ADD_IMM_32 = 0x83  # 131: rd = rs + imm (arg = (rs<<4)|rd? see decoder); used by loop test


def emit_branch_test(take):
    """Forward conditional-branch test. branch_eq r1,r2,+9 -> TGT; the fall-through
    path prints 'F', the taken path prints 'T' (via ecalli). With take=True r2==r1
    so the branch is taken ('T'); with take=False r2!=r1 so it falls through ('F').
    Proves stall-on-branch resolves both directions and redirects pvm_fetch.
    Layout (1-byte offset, every instr fixed-length): branch@pc6, TGT@pc15, off=9."""
    r2val = 7 if take else 9
    code = (
        [LOAD_IMM, 0x01, 7]            # load_imm r1, 7          @0  (r1->x2)
        + [LOAD_IMM, 0x02, r2val]      # load_imm r2, 7|9        @3  (r2->x3)
        + [BRANCH_EQ, 0x21, 9]         # branch_eq r1,r2,+9->@15 @6  (rA=r1,rB=r2)
        + [LOAD_IMM, 0x07, ord('F')]   # load_imm r7, 'F'        @9
        + [ECALLI, 0x00]               # ecalli  (putchar 'F')   @12
        + [TRAP]                       # trap                    @14
        + [LOAD_IMM, 0x07, ord('T')]   # load_imm r7, 'T'  (TGT) @15
        + [ECALLI, 0x00]               # ecalli  (putchar 'T')   @18
        + [TRAP]                       # trap                    @20
    )
    starts = [0, 3, 6, 9, 12, 14, 15, 18, 20]
    return code, starts


def emit_loop_test(n):
    """Countdown loop: print '*' n times via a backward branch_ne. Proves the
    taken (loop-back, negative offset) and not-taken (exit) paths plus add_imm.
      load_imm r1,n ; load_imm r2,0 ; LOOP: load_imm r7,'*' ; ecalli ;
      add_imm_32 r1,r1,-1 ; branch_ne r1,r2,LOOP ; trap"""
    BRANCH_NE = 0xAB  # 171
    instrs = []
    instrs.append([LOAD_IMM, 0x01, n & 0xFF])    # r1 = n            (r1->x2)
    instrs.append([LOAD_IMM, 0x02, 0])           # r2 = 0            (r2->x3)
    # LOOP:
    instrs.append([LOAD_IMM, 0x07, ord('#')])    # r7 = '#' (absent from all harness stdout)
    instrs.append([ECALLI, 0x00])                # putchar('*')
    instrs.append([ADD_IMM_32, 0x11, 0xFF])      # add_imm r1,r1,-1  (rd=r1,rs=r1; imm=-1 sext)
    # branch_ne r1,r2,LOOP : filled after we know positions
    instrs.append([BRANCH_NE, 0x21, 0])          # placeholder offset
    instrs.append([TRAP])
    # compute starts + the backward offset (target = LOOP pc, branch_pc = branch start)
    code, starts = [], []
    for ins in instrs:
        starts.append(len(code)); code.extend(ins)
    loop_pc   = starts[2]            # LOOP label
    branch_pc = starts[5]            # branch instruction
    off = (loop_pc - branch_pc) & 0xFF   # signed 1-byte LE
    code[branch_pc + 2] = off
    return code, starts


JUMP_IND = 0x32   # 50: djump((reg_A + imm_X) mod 2^32); arg = reg_A in low nibble, then imm_X
DJUMP_HALT_ADDR = 0xFFFF0000  # r0 halt magic = 2^32 - 2^16
BRANCH_EQ_IMM = 0x51  # 81: branch(imm_Y, reg_A == imm_X); byte1=(lX<<4)|rA, then imm_X, imm_Y(offset)


def emit_imm_branch(opcode, rval, x):
    """Generic imm-branch (macro-expanded) test: load r1=rval ; <opcode> r1, X, +10.
    Fall-through prints 'F', taken prints 'T'. Exercises the 2-uop front macro-expansion
    (load scratch=X ; branch_cmp r1,scratch) -- including the LE/GT operand swaps."""
    code = (
        [LOAD_IMM, 0x01, rval & 0xFF]     # load_imm r1, rval           @0  (r1->x2)
        + [opcode, 0x11, x & 0xFF, 10]    # <imm-branch> r1,X,off=10->@13  @3 (lX=1,rA=1)
        + [LOAD_IMM, 0x07, ord('F')]      # load_imm r7,'F'             @7
        + [ECALLI, 0x00]                  # ecalli                      @10
        + [TRAP]                          # trap                        @12
        + [LOAD_IMM, 0x07, ord('T')]      # TGT: load_imm r7,'T'        @13
        + [ECALLI, 0x00]                  # ecalli                      @16
        + [TRAP]                          # trap                        @18
    )
    starts = [0, 3, 7, 10, 12, 13, 16, 18]
    return code, starts


def emit_imm_branch_test(take):
    """branch_eq_imm r1, X: r1=7; take -> X=7 (taken,'T'), else X=9 ('F')."""
    return emit_imm_branch(BRANCH_EQ_IMM, 7, 7 if take else 9)


def emit_djump_halt():
    """jump_ind to the r0 halt magic: load_imm64 r2, 0xFFFF0000 ; jump_ind r2.
    djump(0xFFFF0000) -> halt -> pvm_front emits a synthetic trap -> M-mode SUCCESS.
    No jump table needed. Proves the dynamic-jump stall/resolve + clean-halt exit."""
    code = (
        [LOAD_IMM_64, 0x02] + le(DJUMP_HALT_ADDR, 8)   # r2 = 0xFFFF0000   @0  (10B)
        + [JUMP_IND, 0x02]                             # jump_ind r2       @10 (2B)
    )
    starts = [0, 10]
    return code, starts


STORE_IMM_IND_U32 = 0x48  # 72: [reg_A + imm_X] = imm_Y(u32); byte1=(lX<<4)|rA, imm_X, imm_Y
STORE_IMM_IND_U64 = 0x49  # 73: [reg_A + imm_X] = imm_Y(u64); byte1=(lX<<4)|rA, imm_X, imm_Y
STORE_IMM_U32     = 0x20  # 32: [imm_A] = imm_B(u32); byte1 low3=lA, imm_A, imm_B
STORE_IMM_U64     = 0x21  # 33: [imm_A] = imm_B(u64); byte1 low3=lA, imm_A, imm_B
LOAD_IND_U64      = 0x82  # 130: rd = [rbase + off](u64); nibble lo=rd, hi=rbase
LOAD_IND_U32      = 0x80  # 128: rd = [rbase + off](u32, zero-ext); nibble lo=rd, hi=rbase
SHLO_R_IMM_64     = 0x98  # 152: rd = rs >> imm (logical, 64b); nibble lo=rd, hi=rs
ADD_IMM_64        = 0x95  # 149: rd = rs + imm (64b); nibble lo=rd, hi=rs
AND_REG           = 0xD2  # 210: rd = rs1 & rs2 (3-reg); byte1=(rs2<<4)|rs1, byte2=rd
OR_REG            = 0xD4  # 212: rd = rs1 | rs2 (3-reg); byte1=(rs2<<4)|rs1, byte2=rd
XOR_IMM           = 0x85  # 133: rd = rs ^ imm (reg+imm); byte1=(rs<<4)|rd, then imm
CMOV_NZ           = 0xDB  # 219: rd = (cond!=0)?src:rd (3-reg th.mvnez); byte1=(cond<<4)|src, byte2=rd


def emit_storeimm_test():
    """store_imm RTL bug gate -- the BACK-TO-BACK store_imm data-stale hazard.

    A single, isolated store_imm of a full-width (>16-bit, up to 64-bit sign-extended)
    immediate to a non-zero offset stores CORRECTLY -- verified exhaustively against
    polkatool's exact byte encodings (indirect/absolute, u32/u64, +/- sign-extended
    offsets, bit-31-set values). The REAL defect is cross-instruction: each store_imm is
    a 2-uop macro (phase 0: scratch GPR x14 = value; phase 1: STORE [base+off] = x14) and
    pvm_fetch does NOT drain between a macro's phase 1 and the next instruction's phase 0.
    Two store_imm whose store-phases overlap make the YOUNGER store read a STALE x14, so it
    stores the OLDER store's data. RVFI-confirmed: three store_imm of 0x41/0x42/0x43 to
    distinct slots wrote addresses 8/16/24 correctly but DATA 0x41/0x41/0x41.

    This gate writes THREE consecutive store_imm_ind_u64 of distinct values to adjacent DRAM
    slots, then reads them back and checks all three match. It prints '[#]' (0x23) iff each
    store kept its OWN data; on the bug it prints '[X]'. (A single store passes -- the bug
    only bites when the next instruction issues before the store's data is consumed.)

    Verify: load each back, fold (loaded_i == expected_i) into a running flag; r7 = '#' if
    all three matched else 'X'. Guest reg<->GPR: r1=x2 base, r7=x8 a0 (loader frames [a0])."""
    BASE = 0x80100000
    vals = [0x410000, 0x420000, 0x430000]   # distinct values, low 16 bits 0, byte2 = 0x41/42/43
    offs = [0x10, 0x18, 0x20]
    instrs = []
    instrs.append([LOAD_IMM_64, 0x01] + le(BASE, 8))                  # r1 = BASE (DRAM)
    # THREE consecutive store_imm_ind_u64 (no instruction between) -- the failing pattern.
    for V, off in zip(vals, offs):
        instrs.append([STORE_IMM_IND_U64, (1 << 4) | 0x1] + le(off, 1) + le(V, 4))
    # read each back, >>16 -> byte2 (0x41/42/43 if OK), compare to expected; accumulate diffs in r9(x10).
    instrs.append([LOAD_IMM, 0x09, 0x00])                            # r9 = 0 (diff accumulator)
    for V, off in zip(vals, offs):
        exp = (V >> 16) & 0xFF                                       # expected byte2
        instrs.append([LOAD_IND_U64, (0x1 << 4) | 0x7, off])         # r7 = [r1+off]
        instrs.append([SHLO_R_IMM_64, (0x7 << 4) | 0x7, 16])         # r7 >>= 16  -> byte2 (+ high)
        instrs.append([XOR_IMM, (0x7 << 4) | 0x7, exp])              # r7 ^= expected -> 0 iff match
        instrs.append([OR_REG, (0x7 << 4) | 0x9, 0x9])               # r9 |= r7 (byte1=(rs2=r7<<4)|rs1=r9, byte2=rd=r9)
    # r7 = (r9 == 0) ? '#' : 'X'. r9!=0 means some store was wrong. Compute via set_lt_u + select:
    #   r10 = (0 < r9) = (r9 != 0)  [SET_LT_U_IMM rd=r10, rs=r9, imm=0 gives (r9<0)=0 -- wrong dir];
    # simpler: r7='#'; cmov_if_not_zero r7 <- 'X' when r9!=0 (reg-reg cmov keeps r7 if r9==0).
    instrs.append([LOAD_IMM, 0x07, 0x23])                            # r7 = '#'
    instrs.append([LOAD_IMM, 0x0b, ord('X')])                        # r11 = 'X' (x12)
    instrs.append([CMOV_NZ, ((0x9 & 0xF) << 4) | 0x0b, 0x07])        # r7 = (r9!=0) ? r11 : r7  (rd=r7,rs1=r11,cond=r9)
    instrs.append([ECALLI, 0x00])                                    # putchar(r7) -> '[' r7 ']'
    instrs.append([TRAP])

    code, starts = [], []
    for ins in instrs:
        starts.append(len(code)); code.extend(ins)
    return code, starts


def emit_djump_table(idx=0, z=1):
    """jump_ind through the jump table: load_imm r2,(idx+1)*2 ; jump_ind r2 -> j[idx] = TARGET.
    djump((idx+1)*2): index = (idx+1) - 1 = idx -> target = jumptable[idx]. Prints 'J' then traps.
    Returns (code, starts, jumptable_bytes, z). The image builder appends the table after the
    bitmask; CFG2 = jumptable_base | (z<<32). idx>0 places the live entry FAR from code -> a
    COLD-miss JT read on the DRAM demand-fetch path; z>1 = wider JT entries (real OpenSBI uses z=3).
    The A/B control for the eret-via-jt handoff (same JE/JT-read, triggered by a djump not an eret)."""
    target = (idx + 1) * 2
    assert 0 <= target <= 127, f"target {target} needs a multi-byte load_imm (use idx<=62)"
    code = (
        [LOAD_IMM, 0x02, target]       # load_imm r2, (idx+1)*2 (djump addr -> index idx) @0 (3B)
        + [JUMP_IND, 0x02]             # jump_ind r2                            @3 (2B)
        + [TRAP]                       # (error catch: djump must skip this)    @5 (1B)
        + [LOAD_IMM, 0x07, ord('J')]   # TARGET: load_imm r7, 'J'               @6 (3B)
        + [ECALLI, 0x00]               # ecalli (putchar 'J')                   @9 (2B)
        + [TRAP]                       # trap                                   @11(1B)
    )
    starts = [0, 3, 5, 6, 9, 11]
    jumptable = [0] * idx + [6]        # j[idx] = TARGET pc (6)
    return code, starts, jumptable, z


LOAD_IMM_JUMP_IND = 0xB4  # 180: reg_A = imm_X ; djump(reg_B + imm_Y); byte1=(rB<<4)|rA, byte2=lX


def emit_ldij_test():
    """load_imm_jump_ind: load r2=0 ; load_imm_jump_ind r3,r2,imm_X=99,imm_Y=2 ->
    djump(r2+2)=djump(2)=j[0]=TARGET. Prints 'J' then traps. Combines the 2-uop
    macro-expansion (load reg_A) with the dynamic-jump (reg_B) path + the jump table."""
    code = (
        [LOAD_IMM, 0x02, 0]                       # load_imm r2, 0 (djump base) @0 (3B)
        + [LOAD_IMM_JUMP_IND, 0x23, 0x01, 99, 2]  # r3=99 ; djump(r2+2)->@9      @3 (5B) rB=2,rA=3,lX=1
        + [TRAP]                                   # error catch (djump skips it) @8 (1B)
        + [LOAD_IMM, 0x07, ord('J')]               # TARGET: load_imm r7,'J'      @9 (3B)
        + [ECALLI, 0x00]                           # ecalli (putchar 'J')         @12 (2B)
        + [TRAP]                                    # trap                         @14 (1B)
    )
    starts = [0, 3, 8, 9, 12, 14]
    return code, starts, [9], 1   # jumptable[0] = TARGET(9), z=1


# Privileged CSR opcodes (231-236): reg_reg_imm. byte1 = (rs1<<4)|rd nibbles -- i.e.
# rd = LOW nibble, csr-source reg = HIGH nibble (the polkavm2 jam_v1_privileged
# encoding; verified against polkatool disasm of real OpenSBI). PVM rN -> RISC-V
# x(N+1), then the csr-number immediate (LE). csr_rw: rd=old csr, csr=rs1. csr_rs:
# rd=old csr, csr|=rs1. csr_rc: rd=old csr, csr&=~rs1.
CSR_RW   = 0xE7   # 231
CSR_RS   = 0xE8   # 232
CSR_RC   = 0xE9   # 233
MSCRATCH = 0x340  # an M-mode CSR unused by the loader -> safe to clobber from PVM
MTVEC    = 0x305  # M-mode trap vector: the guest clobbers it to prove the B4 PVM-exit decouple
MEPC     = 0x341  # M-mode exception PC: mret redirects PVM fetch here (writing it sets no flush)
MSTATUS  = 0x300  # M-mode status (MPP etc.); written by the HOST loader, not the guest (flush)
MCAUSE   = 0x342  # M-mode trap cause; an ecalli@S presents ENV_CALL_SMODE(9) (cva6.sv:772-775)
MIE      = 0x304  # M-mode interrupt-enable (MSIE bit3 / MTIE bit7)


def emit_irq_test():
    """Async-IRQ-to-guest gate (CFG2[38]): a pending machine interrupt must be delivered
    to a PVM guest that spins with interrupts enabled -- WITHOUT the inject the guest loops
    forever (timeout = FAIL); WITH it, control reaches the guest's own mtvec handler.

    The guest (M-mode) raises its OWN machine software interrupt via the CLINT MSIP
    register (phys 0x2000000, a pass-through store), then enables mie.MSIE + mstatus.MIE
    and spins. cva6.sv's pvm_irq_take then replaces the next whole spin uop with an
    M_SW interrupt exception -> redirect to mtvec (raw PVM-pc here; CFG2[37] off in the
    micro-loader). The handler writes '@' straight to the UART THR and traps -- a DIRECT
    MMIO store, not an ecalli, so the gate proves inject+redirect+handler-execution
    without a nested host-call. '@' iff the interrupt was delivered to the guest tvec.

      r1=HANDLER ; csr_rw mtvec,r1                 ; mtvec = handler (raw pc)
      r2=0x2000000 ; r3=1 ; sw [r2]=r3             ; CLINT MSIP=1 -> mip.MSIP
      r4=8 ; csr_rs mie,r4                          ; mie.MSIE
      r5=8 ; csr_rs mstatus,r5                      ; mstatus.MIE -> global_enable => INJECT
      spin: branch_eq r1,r1,0                       ; loop until the interrupt fires
      @HANDLER: r8=UART ; r7='@' ; sb [r8]=r7 ; trap
    """
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    HANDLER = 40                                  # 4B/2B-aligned raw PVM-pc (mtvec zeroes bit0)
    mtv = le(MTVEC, 2)
    mie = le(MIE, 2)
    mst = le(MSTATUS, 2)
    code = (
        [LOAD_IMM, 0x01, HANDLER]                 # r1 = HANDLER                  @0  (3B)
        + [CSR_RW, b1(6, 1)] + mtv                # mtvec = r1                    @3  (4B)
        + [LOAD_IMM_64, 0x02] + le(0x2000000, 8)  # r2 = CLINT MSIP base          @7  (10B)
        + [LOAD_IMM, 0x03, 0x01]                  # r3 = 1                        @17 (3B)
        + [STORE_IND_U32, b1(3, 2), 0x00]         # [r2+0] = r3 -> MSIP=1         @20 (3B)
        + [LOAD_IMM, 0x04, 0x08]                  # r4 = 8 (MSIE bit3)            @23 (3B)
        + [CSR_RS, b1(6, 4)] + mie                # mie |= 8                      @26 (4B)
        + [LOAD_IMM, 0x05, 0x08]                  # r5 = 8 (MIE bit3)             @30 (3B)
        + [CSR_RS, b1(6, 5)] + mst                # mstatus |= 8 -> enable        @33 (4B)
        + [BRANCH_EQ, b1(1, 1), 0x00]             # spin: branch_eq r1,r1,0       @37 (3B)
        + [LOAD_IMM_64, 0x08] + le(UART_THR, 8)   # HANDLER r8 = UART THR         @40 (10B)
        + [LOAD_IMM, 0x07, ord('@')]              # r7 = '@'                      @50 (3B)
        + [STORE_IND_U8, b1(7, 8), 0x00]          # sb [r8+0] = r7 -> putchar '@' @53 (3B)
        + [TRAP]                                  # trap                          @56 (1B)
    )
    starts = [0, 3, 7, 17, 20, 23, 26, 30, 33, 37, 40, 50, 53, 56]
    assert HANDLER == 40 and len(code) == 57
    return code, starts


def emit_csr_test():
    """Privileged CSR data ops (csr_rw / csr_rs / csr_rc) exercised through mscratch,
    verifying each actually transforms the CSR value (not just round-trips a byte):
      load_imm r7,0x20 ; csr_rw r1,r7,mscratch   ->  mscratch = 0x20
      load_imm r2,0x07 ; csr_rs r1,r2,mscratch   ->  mscratch |= 0x07 = 0x27
      load_imm r3,0x04 ; csr_rc r1,r3,mscratch   ->  mscratch &= ~0x04 = 0x23 ('#')
      load_imm r7,0 (CLOBBER) ; load_imm r4,0 ; csr_rs r7,r4,mscratch -> r7 = 0x23
      ecalli #0 (putchar r7) ; trap.
    Prints '#' iff write + set + clear + read ALL work: 0x23 is reached only as
    0x20 -> set 0x07 -> clear 0x04, so a wrong/no-op at any step yields a different
    char (write-fail->0x03, set-fail->0x20 ' ', clear-fail->0x27 '\''). '#' is also
    absent from the harness's own stdout, so it is unambiguous. The r7 clobber before
    the read defeats a false pass. PVM runs at M-mode and mscratch is an M-mode CSR the
    loader never touches, so the accesses are legal and observable. (mret/sret/wfi/
    sfence_vma are control/privilege ops -- their meaningful test needs the guest-
    privilege scenario from B4, so they are exercised there, not here.)"""
    csr = le(MSCRATCH, 2)                    # [0x40, 0x03]
    def b1(rd, rs1):                          # nibbles: lo = rd PVM idx, hi = rs1 PVM idx
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    code = (
        [LOAD_IMM, 0x07, 0x20]               # r7 = 0x20                @0  (3B)
        + [CSR_RW, b1(1, 7)] + csr           # mscratch = r7 = 0x20     @3  (4B)
        + [LOAD_IMM, 0x02, 0x07]             # r2 = 0x07                @7  (3B)
        + [CSR_RS, b1(1, 2)] + csr           # mscratch |= 0x07 -> 0x27 @10 (4B)
        + [LOAD_IMM, 0x03, 0x04]             # r3 = 0x04                @14 (3B)
        + [CSR_RC, b1(1, 3)] + csr           # mscratch &= ~0x04 ->0x23 @17 (4B)
        + [LOAD_IMM, 0x07, 0x00]             # r7 = 0  (clobber)        @21 (3B)
        + [LOAD_IMM, 0x04, 0x00]             # r4 = 0  (read mask)      @24 (3B)
        + [CSR_RS, b1(7, 4)] + csr           # r7 = mscratch = 0x61     @27 (4B)
        + [ECALLI, 0x00]                     # putchar(r7) = 'a'        @31 (2B)
        + [TRAP]                             # trap                     @33 (1B)
    )
    starts = [0, 3, 7, 10, 14, 17, 21, 24, 27, 31, 33]
    return code, starts


# CSR-IMMEDIATE opcodes (234-236): reg_reg_imm shape, byte1 = (zimm<<4)|rd. The HIGH
# nibble is the 5-bit zimm VALUE (0..15), NOT a register index (polkatool packs
# `(imm)&0xF` into the source nibble). Regression for the silicon post-PTP `!F` derail:
# the decoder read a GPR there instead of the zimm, so Linux's `csrrsi mstatus,zimm`
# set mstatus.MBE (the read GPR had bit 37) -> big-endian -> every ld/sd byte-reversed.
CSR_RWI = 0xEA   # 234
CSR_RSI = 0xEB   # 235
CSR_RCI = 0xEC   # 236

def emit_csri_test():
    """CSR-immediate (csrrsi/csrrwi) operand-source gate. csrrsi mscratch,zimm must use
    the 4-bit zimm as the set-mask, NOT a GPR.  Poison the GPR the BUGGY decoder would
    read (csrrsi mscratch,3 -> byte1 hi-nibble 3 -> old decode g_hi = x(3+1) = PVM r3) with
    0x40, then:
      r3 = 0x40                       (poison: the mis-read source)
      csrrwi mscratch, 0              -> mscratch = 0     (csrrwi always writes the zimm)
      csrrsi mscratch, 3              -> mscratch |= 3     correct=3 ; buggy=|=r3(0x40)=0x40
      r7 = csrrs mscratch, x0         -> read mscratch back (register form, side-effect free)
      add_imm32 r7, r7, 0x20          -> correct: 0x23 '#' ; buggy: 0x60 '`'
      ecalli #0 (putchar r7) ; trap.
    '#' iff the zimm (=3) reached csr_buffer as operand_a; '`' (0x60) iff the GPR did.
    (Also implicitly proves no MBE flip, since a flip would corrupt the ecalli path too.)"""
    csr = le(MSCRATCH, 2)                        # [0x40, 0x03]
    def b1_reg(rd, rs1):                          # register form nibbles: lo=rd, hi=rs1
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    def b1_imm(rd, zimm):                          # immediate form nibbles: lo=rd, hi=zimm
        return ((zimm & 0xF) << 4) | (rd & 0xF)
    code = (
        [LOAD_IMM, 0x03, 0x40]                   # r3 = 0x40 (poison)        @0  (3B)
        + [CSR_RWI, b1_imm(1, 0)] + csr          # mscratch = zimm 0         @3  (4B)
        + [CSR_RSI, b1_imm(1, 3)] + csr          # mscratch |= zimm 3        @7  (4B)
        + [CSR_RS,  b1_reg(7, 0)] + csr          # r7 = mscratch (read)      @11 (4B)
        + [ADD_IMM_32, (7 << 4) | 7, 0x20]       # r7 = r7 + 0x20            @15 (3B)
        + [ECALLI, 0x00]                         # putchar(r7)               @18 (2B)
        + [TRAP]                                 # trap                      @20 (1B)
    )
    starts = [0, 3, 7, 11, 15, 18, 20]
    return code, starts


def emit_hostcall_test():
    """Host-call ABI (B3): dispatch on the host-call number + multi-arg + return value.
      load_imm r7,0x22 (a0) ; load_imm r8,0x01 (a1) ;
      ecalli #1 (sum: handler sets a0 = a0 + a1 = 0x23) ; ecalli #0 (putchar a0) ; trap.
    Prints exactly one '#' (0x23) iff the handler dispatched on the host-call number
    (delivered in mtval), read both args (a0=r7, a1=r8), wrote the return into a0 and
    resumed. A broken dispatch (always putchar) would print a0=0x22 ('"') at BOTH ecallis
    and never '#'. ABI: a0..a5 = PVM r7..r12 (== x8..x13), a0 = arg0 + return."""
    code = (
        [LOAD_IMM, 0x07, 0x22]      # a0 (r7) = 0x22              @0  (3B)
        + [LOAD_IMM, 0x08, 0x01]    # a1 (r8) = 0x01              @3  (3B)
        + [ECALLI, 0x01]            # ecalli #1 (sum -> a0=0x23)  @6  (2B)
        + [ECALLI, 0x00]            # ecalli #0 (putchar a0='#')  @8  (2B)
        + [TRAP]                    # trap                        @10 (1B)
    )
    starts = [0, 3, 6, 8, 10]
    return code, starts


def emit_mtvec_test():
    """B4 mtvec-decouple proof: the guest CLOBBERS mtvec (simulating OpenSBI installing its
    own trap vector), then ecalli #0 (putchar). The ecalli MUST still reach the host handler
    -- because a PVM host-boundary exit is delivered to CSR_PVM_VEC, not mtvec. The loader
    sets CSR_PVM_VEC = the real handler; mtvec is clobbered to a bogus 0x40. If the decouple
    works, '#' prints; if the exit wrongly used the (clobbered) mtvec, control jumps to 0x40
    -> no '#'. Prints '#' iff B4 routes the host-boundary exit independently of mtvec.
      load_imm r2,0x40 ; csr_rw r1,r2,mtvec  -> mtvec = 0x40 (CLOBBER)
      load_imm r7,0x23 ; ecalli #0 (putchar '#') ; trap."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mtv = le(MTVEC, 2)                        # [0x05, 0x03]
    code = (
        [LOAD_IMM, 0x02, 0x40]               # r2 = 0x40 (bogus handler)   @0  (3B)
        + [CSR_RW, b1(1, 2)] + mtv           # mtvec = r2 = 0x40 (clobber) @3  (4B)
        + [LOAD_IMM, 0x07, 0x23]             # r7 = 0x23 = '#'             @7  (3B)
        + [ECALLI, 0x00]                     # putchar(r7) via CSR_PVM_VEC @10 (2B)
        + [TRAP]                             # trap                        @12 (1B)
    )
    starts = [0, 3, 7, 10, 12]
    return code, starts


def emit_mret_test():
    """Phase-A mret PVM-pc-redirect proof (isolates the redirect). The guest sets
    mepc = <success-block PVM-pc L> and executes `mret`; the HW must REDIRECT pvm_fetch
    to L, not fall through to the sequential next pc (a DECOY that prints 'X'). The
    success block at L prints '#'. Privilege is set to M by the HOST loader (not the
    guest) so the success block's ecalli is a host-exit in BOTH Phase A and Phase B;
    writing mepc raises NO pipeline flush (unlike mstatus), so no younger PVM uop is lost.
      load_imm r1,L ; csr_rw r2,r1,mepc ; mret          -> must resume at L
      @decoy (seq. after mret): load_imm r7,'X' ; ecalli #0 ; trap     (FAIL marker)
      @L:                       load_imm r7,'#' ; ecalli #0 ; trap     (SUCCESS marker)
    Prints '#' iff pvm_fetch redirected to mepc; 'X' iff the redirect fell through."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mepc = le(MEPC, 2)                            # [0x41, 0x03]
    L = 14                                        # PVM-pc of the success block (see layout)
    code = (
        [LOAD_IMM, 0x01, L]                       # r1 = L                       @0  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = r1 = L                @3  (4B)
        + [MRET]                                  # mret -> redirect to L        @7  (1B)
        + [LOAD_IMM, 0x07, ord('X')]              # DECOY  r7 = 'X'              @8  (3B)
        + [ECALLI, 0x00]                          # putchar('X')  (FAIL)         @11 (2B)
        + [TRAP]                                  # trap                         @13 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # SUCCESS r7 = '#'  (== L)     @14 (3B)
        + [ECALLI, 0x00]                          # putchar('#')                 @17 (2B)
        + [TRAP]                                  # trap                         @19 (1B)
    )
    starts = [0, 3, 7, 8, 11, 13, 14, 17, 19]
    assert L == 14 and len(code) == 20
    return code, starts


def emit_handoff_test(idx=0, z=1):
    """Stage 1 M->S handoff via JT-mapped eret. The guest sets mepc = a JT-ENCODED code
    address ((idx+1)*2, a PolkaVM jump target), NOT a PVM-pc, and executes mret while
    CSR_PVM_CFG2[36]=1 (set by the HOST loader). The HW must map mepc through the jump table
    (JE = base + (((idx+1)*2 >> 1) - 1)*z = base + idx*z -> jumptable[idx]) and redirect there;
    jumptable[idx] = the success block's PVM-pc (L=14). Falls through / lands wrong (DECOY 'X' or
    garbage) if the JT-map did NOT happen (e.g. the eret used mepc[31:0] directly -> a mid-instr pc).
      load_imm r1,(idx+1)*2 ; csr_rw mepc,r1 ; mret    -> JT[idx] -> success
      @8  decoy: load_imm r7,'X' ; ecalli ; trap   (FAIL)
      @14 L:     load_imm r7,'#' ; ecalli ; trap   (SUCCESS) -- jumptable[idx] = 14
    idx>0 places the live JT entry FAR from the code+bitmask lines, so the DRAM demand-fetch JT
    read is a COLD cache MISS (the D_WAIT path) -- the FPGA/OpenSBI handoff condition that the
    idx=0 hot-line read does not exercise. Prints '#' iff the eret JT-mapped mepc."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    target = (idx + 1) * 2                        # JT-encoded address for index `idx`
    assert 0 <= target <= 127, f"target {target} needs a multi-byte load_imm (use idx<=62)"
    mepc = le(MEPC, 2)
    L = 14
    code = (
        [LOAD_IMM, 0x01, target]                  # r1 = (idx+1)*2 (JT-encoded target)  @0  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = r1                           @3  (4B)
        + [MRET]                                  # mret -> JT-map mepc -> jumptable[idx]@7  (1B)
        + [LOAD_IMM, 0x07, ord('X')]              # DECOY  r7 = 'X'                     @8  (3B)
        + [ECALLI, 0x00]                          # putchar('X')  (FAIL)                @11 (2B)
        + [TRAP]                                  #                                     @13 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # SUCCESS r7 = '#'  (== L)            @14 (3B)
        + [ECALLI, 0x00]                          # putchar('#')                        @17 (2B)
        + [TRAP]                                  #                                     @19 (1B)
    )
    starts = [0, 3, 7, 8, 11, 13, 14, 17, 19]
    jumptable = [0] * idx + [L]                   # jumptable[idx] = success PVM-pc (14)
    assert L == 14 and len(code) == 20
    return code, starts, jumptable, z


def emit_handoff_smode(idx=0):
    """OpenSBI-handoff reproduction: a JT-mapped eret that ALSO drops M->S (the real handoff,
    vs emit_handoff_test which mret's M->M). The guest sets mtvec=Lh, mepc=a JT-ENCODED target
    ((idx+1)*2), and mret with CSR_PVM_CFG2[36]=1 + MPP=S (host-set): the HW maps mepc through the
    jump table -> jumptable[idx]=Ls (the S-entry PVM-pc) AND drops priv to S. At Ls (S-mode) a
    guest-internal ecalli@S stays in PVM and traps to the guest mtvec=Lh (M handler) -> host '#'.
    This is emit_priv_test x eret-via-jt: it isolates the [JT-mapped eret] x [M->S priv drop]
    combination -- the exact FPGA/OpenSBI handoff. Prints '#' iff the JT-mapped M->S mret reached
    Ls at S-mode and the round-trip closed; 'S' iff JT-mapped to Ls but priv stayed M; nothing iff
    the JT-map reached the WRONG target (garbage -> fault). Lh=16 (4-aligned, mtvec), Ls=22 (2-aligned)."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    mtvec  = le(MTVEC, 2)
    mepc   = le(MEPC, 2)
    target = (idx + 1) * 2                        # JT-encoded address for index `idx`
    assert 0 <= target <= 127, f"target {target} needs a multi-byte load_imm (use idx<=62)"
    Lh = 16                                       # M-mode guest trap handler PVM-pc (4-aligned)
    Ls = 22                                       # S-mode entry PVM-pc (2-aligned)
    code = (
        [LOAD_IMM, 0x01, Lh]                      # r1 = Lh                      @0  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh (guest M tvec)    @3  (4B)
        + [LOAD_IMM, 0x01, target]                # r1 = (idx+1)*2 (JT-encoded)  @7  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = JT-encoded target     @10 (4B)
        + [MRET]                                  # mret JT-map -> JT[idx]=Ls, priv->S @14 (1B)
        + [TRAP]                                  # DECOY (redirect fail -> exit)@15 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # Lh: r7 = '#' (4-aligned=16)  @16 (3B)
        + [ECALLI, 0x00]                          # ecalli@M -> host putchar '#' @19 (2B)
        + [TRAP]                                  # trap -> exit SUCCESS         @21 (1B)
        + [LOAD_IMM, 0x07, ord('S')]              # Ls: r7 = 'S' (priv-fail char)@22 (3B)
        + [ECALLI, 0x00]                          # ecalli@S -> guest-trap to Lh @25 (2B)
        + [TRAP]                                  # safety exit                  @27 (1B)
    )
    starts = [0, 3, 7, 10, 14, 15, 16, 19, 21, 22, 25, 27]
    z = 1
    jumptable = [0] * idx + [Ls]                  # jumptable[idx] = S-entry PVM-pc (22)
    assert Lh == 16 and Ls == 22 and len(code) == 28
    return code, starts, jumptable, z


def emit_handoff_smode_dyn(idx=0):
    """The MOST faithful OpenSBI-handoff repro: the GUEST sets mstatus.MPP=S ITSELF (a flush-class
    CSR write, B5-fenced) and THEN does a JT-mapped M->S mret -- exactly sbi_hart_switch_mode (which
    csr_write's MSTATUS then mret's). This is emit_priv_dyn_test x eret-via-jt: it adds the ONE
    factor the other handoff repros omit -- a guest flush-class CSR write immediately upstream of the
    JT-mapped mret (the host pre-set MPP in emit_handoff_smode). Layout = emit_priv_dyn_test, but
    mepc is the JT-ENCODED target ((idx+1)*2) and jumptable[idx]=Ls. Prints '#' iff B5 fences the
    flush AND the JT-mapped M->S round-trip closes. Lh=24 (4-aligned), Ls=30 (2-aligned)."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    mstatus = le(MSTATUS, 2)
    mtvec   = le(MTVEC, 2)
    mepc    = le(MEPC, 2)
    target  = (idx + 1) * 2
    assert 0 <= target <= 127, f"target {target} needs a multi-byte load_imm (use idx<=62)"
    Lh = 24                                       # M-mode guest trap handler PVM-pc (4-aligned)
    Ls = 30                                       # S-mode entry PVM-pc (2-aligned)
    code = (
        [LOAD_IMM, 0x02, 0x00, 0x08]              # r2 = 0x800 (MPP=S bit, 2-byte imm) @0  (4B)
        + [CSR_RS, b1(1, 2)] + mstatus            # mstatus |= r2 -> MPP=S (FENCED)     @4  (4B)
        + [LOAD_IMM, 0x01, Lh]                     # r1 = Lh                             @8  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh (guest M tvec)           @11 (4B)
        + [LOAD_IMM, 0x01, target]                # r1 = (idx+1)*2 (JT-encoded)         @15 (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = JT-encoded target            @18 (4B)
        + [MRET]                                   # mret JT-map -> JT[idx]=Ls, priv->S  @22 (1B)
        + [TRAP]                                   # DECOY (redirect fail -> exit)       @23 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # Lh: r7 = '#' (4-aligned=24)         @24 (3B)
        + [ECALLI, 0x00]                          # ecalli@M -> host putchar '#'        @27 (2B)
        + [TRAP]                                   # trap -> exit SUCCESS                @29 (1B)
        + [LOAD_IMM, 0x07, ord('S')]              # Ls: r7 = 'S' (priv-fail char)       @30 (3B)
        + [ECALLI, 0x00]                          # ecalli@S -> guest-trap to Lh        @33 (2B)
        + [TRAP]                                   # safety exit                         @35 (1B)
    )
    starts = [0, 4, 8, 11, 15, 18, 22, 23, 24, 27, 29, 30, 33, 35]
    z = 1
    jumptable = [0] * idx + [Ls]                  # jumptable[idx] = S-entry PVM-pc (30)
    assert Lh == 24 and Ls == 30 and len(code) == 36
    return code, starts, jumptable, z


def emit_handoff_clobber(idx=0):
    """HYPOTHESIS TEST: does a host-call (ecalli) BETWEEN the mepc write and the mret CLOBBER mepc?
    The HW trap-entry on an ecalli writes mepc <- (ecalli pc); if the guest's mepc=JT-target is not
    preserved across the host-call, the following JT-mapped mret maps the WRONG value -> no '#'.
    This mirrors OpenSBI sbi_hart_switch_mode, where pvm_putc('U') (an ecalli) sits between
    csr_write(MEPC, 0x8a0) and the mret -- the one factor every passing handoff repro omits.
      load_imm r1,(idx+1)*2 ; csr_rw mepc,r1 ; load_imm r7,'U' ; ecalli ; mret -> JT[idx]
    Prints 'U' then '#' iff mepc survived the host-call; 'U' then garbage/decoy iff it was clobbered."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    target = (idx + 1) * 2
    assert 0 <= target <= 127, f"target {target} needs a multi-byte load_imm (use idx<=62)"
    mepc = le(MEPC, 2)
    L = 19
    code = (
        [LOAD_IMM, 0x01, target]                  # r1 = (idx+1)*2 (JT-encoded)  @0  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = r1                    @3  (4B)
        + [LOAD_IMM, 0x07, ord('U')]              # r7 = 'U'                     @7  (3B)
        + [ECALLI, 0x00]                          # ecalli (host 'U') -- clobbers mepc? @10 (2B)
        + [MRET]                                  # mret -> JT-map mepc -> JT[idx]@12 (1B)
        + [LOAD_IMM, 0x07, ord('X')]              # DECOY  r7 = 'X'              @13 (3B)
        + [ECALLI, 0x00]                          #                              @16 (2B)
        + [TRAP]                                  #                              @18 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # SUCCESS r7 = '#' (== L)      @19 (3B)
        + [ECALLI, 0x00]                          #                              @22 (2B)
        + [TRAP]                                  #                              @24 (1B)
    )
    starts = [0, 3, 7, 10, 12, 13, 16, 18, 19, 22, 24]
    z = 1
    jumptable = [0] * idx + [L]                   # jumptable[idx] = success PVM-pc (19)
    assert L == 19 and len(code) == 25
    return code, starts, jumptable, z


def emit_handoff_rearm(idx=0):
    """FIX VALIDATION for emit_handoff_clobber: re-arm mepc AFTER the host-call, immediately before
    the mret -- so no ecalli sits between the (final) mepc write and the mret. Mirrors the OpenSBI
    fix (write CSR_MEPC last, after the pvm_putc diagnostics). If the clobber theory + fix are right,
    this prints 'U' then '#' (mepc survives because it is re-armed past the host-call).
      load_imm r1,t ; csr_rw mepc,r1 ; load_imm r7,'U' ; ecalli ; load_imm r1,t ; csr_rw mepc,r1 ; mret"""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    target = (idx + 1) * 2
    assert 0 <= target <= 127, f"target {target} needs a multi-byte load_imm (use idx<=62)"
    mepc = le(MEPC, 2)
    L = 26
    code = (
        [LOAD_IMM, 0x01, target]                  # r1 = target                  @0  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = r1                    @3  (4B)
        + [LOAD_IMM, 0x07, ord('U')]              # r7 = 'U'                     @7  (3B)
        + [ECALLI, 0x00]                          # ecalli (host 'U') clobbers mepc @10 (2B)
        + [LOAD_IMM, 0x01, target]                # r1 = target (again)          @12 (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = r1 (RE-ARM, last)     @15 (4B)
        + [MRET]                                  # mret -> JT-map mepc -> JT[idx]@19 (1B)
        + [LOAD_IMM, 0x07, ord('X')]              # DECOY                        @20 (3B)
        + [ECALLI, 0x00]                          #                              @23 (2B)
        + [TRAP]                                  #                              @25 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # SUCCESS (== L)               @26 (3B)
        + [ECALLI, 0x00]                          #                              @29 (2B)
        + [TRAP]                                  #                              @31 (1B)
    )
    starts = [0, 3, 7, 10, 12, 15, 19, 20, 23, 25, 26, 29, 31]
    z = 1
    jumptable = [0] * idx + [L]                   # jumptable[idx] = success PVM-pc (26)
    assert L == 26 and len(code) == 32
    return code, starts, jumptable, z


def emit_handoff_djump_eret(idx=0, z=1):
    """Untested interaction: a DJUMP (jump_ind via JT) immediately UPSTREAM of the JT-mapped eret.
    OpenSBI's sbi_hart_switch_mode calls misa_extension('H') right before the mret; in PVM a function
    RETURN (ret = jalr ra) is a jump_ind -> a djump through the JT. So a djump's JT read precedes the
    eret-via-jt's JT read, and both reuse the SAME regs (djump_a_q/djump_target_q/jt_req_q/jt_valid_q).
    If the eret picks up STALE djump state, it maps to the wrong target. Every passing handoff repro was
    straight-line (no djump before the mret) -- this adds that one factor.
      load_imm r2,2 ; jump_ind r2 -> JT[0]=B ;  B: load_imm r1,4 ; csr_rw mepc,r1 ; mret -> JT[1]=L
    Prints '#' iff the eret-via-jt JT read is independent of the preceding djump; else 'X'/garbage."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    mepc = le(MEPC, 2)
    B = 6                                         # djump target (the eret-setup block)
    L = 15                                        # eret target (success block)
    code = (
        [LOAD_IMM, 0x02, 2]                       # r2 = 2 -> djump index 0       @0  (3B)
        + [JUMP_IND, 0x02]                        # jump_ind r2 -> JT[0] = B      @3  (2B)
        + [TRAP]                                  # catch (djump skips)           @5  (1B)
        + [LOAD_IMM, 0x01, 4]                     # B: r1 = 4 -> eret index 1     @6  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = r1 = 4                 @9  (4B)
        + [MRET]                                  # mret -> JT-map -> JT[1] = L   @13 (1B)
        + [TRAP]                                  # catch                         @14 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # L: r7 = '#' (success)         @15 (3B)
        + [ECALLI, 0x00]                          #                              @18 (2B)
        + [TRAP]                                  #                              @20 (1B)
    )
    starts = [0, 3, 5, 6, 9, 13, 14, 15, 18, 20]
    jumptable = [B, L]                            # JT[0]=djump target B, JT[1]=eret target L
    assert B == 6 and L == 15 and len(code) == 21
    return code, starts, jumptable, z


def emit_handoff_satp(idx=0, z=1):
    """Untested OpenSBI factor: a FLUSH-class CSR write (satp) BETWEEN the mepc write and the
    JT-mapped mret. sbi_hart_switch_mode writes stvec/sscratch/sie/SATP after MEPC, then mret;
    SATP is flush-class (B5 fences it: pvm_fetch suspends after the write, commits it alone, then
    resumes -> the mret). Every passing handoff repro put the mret IMMEDIATELY after the mepc write,
    so the B5-fence-then-eret-via-jt sequence is untested. M->M (the JT-map is priv-independent).
      load_imm r3,0 ; load_imm r1,t ; csr_rw mepc,r1 ; csr_rw satp,r3 (FLUSH) ; mret -> JT[idx]
    Prints '#' iff the eret-via-jt survives a flush-class write right before it; else 'X'/garbage."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    satp = le(0x180, 2)
    mepc = le(MEPC, 2)
    target = (idx + 1) * 2
    assert 0 <= target <= 127, f"target {target} needs a multi-byte load_imm (use idx<=62)"
    L = 21
    code = (
        [LOAD_IMM, 0x03, 0]                       # r3 = 0 (satp value)          @0  (3B)
        + [LOAD_IMM, 0x01, target]                # r1 = (idx+1)*2 (JT-encoded)  @3  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = r1                    @6  (4B)
        + [CSR_RW, b1(4, 3)] + satp               # satp = r3 = 0 (FLUSH, last)  @10 (4B)
        + [MRET]                                  # mret -> JT-map mepc -> JT[idx]@14 (1B)
        + [LOAD_IMM, 0x07, ord('X')]              # DECOY                        @15 (3B)
        + [ECALLI, 0x00]                          #                              @18 (2B)
        + [TRAP]                                  #                              @20 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # SUCCESS (== L)               @21 (3B)
        + [ECALLI, 0x00]                          #                              @24 (2B)
        + [TRAP]                                  #                              @26 (1B)
    )
    starts = [0, 3, 6, 10, 14, 15, 18, 20, 21, 24, 26]
    jumptable = [0] * idx + [L]                   # jumptable[idx] = success PVM-pc (21)
    assert L == 21 and len(code) == 27
    return code, starts, jumptable, z


def emit_priv_test():
    """Phase-B/C multi-privilege round-trip (the OpenSBI-on-PVM core): the guest drops
    M->S via mret, then a guest-internal ecalli@S traps to the guest's OWN mtvec while
    STAYING in PVM (it is NOT a host-boundary exit), reaching an M-mode handler that
    host-exits '#'. Privilege MPP=S is set by the HOST loader (a guest mstatus write would
    raise a flush); the guest only writes mtvec/mepc (flush-free).
      @M  csr_rw mtvec,Lh ; csr_rw mepc,Ls ; mret        -> redirect to Ls, priv->S
      @15 trap                                            (DECOY: mret-redirect-fail exit)
      @Ls(S) load_imm r7,'S' ; ecalli #0                  -> guest-trap to mtvec=Lh, priv->M
      @21 trap                                            (safety exit)
      @Lh(M) load_imm r7,'#' ; ecalli #0 (host '#') ; trap
    Prints '#' iff: mret redirected to Ls AND priv became S AND ecalli@S stayed in PVM and
    redirected to the guest mtvec=Lh AND priv became M there. Prints 'S' (no '#') iff the
    mret redirected but priv stayed M (ecalli@Ls would host-exit directly). Expect '#'."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mtvec = le(MTVEC, 2)                          # [0x05, 0x03]
    mepc  = le(MEPC, 2)                           # [0x41, 0x03]
    # ALIGNMENT (a real RISC-V constraint on the PVM-pc targets): mtvec is 4-byte aligned
    # in direct mode (bits[1:0] forced 0), so the guest M-handler PVM-pc Lh MUST be 4-byte
    # aligned -- else trap_vector_base = Lh & ~3 lands mid-instruction (a hang/illegal).
    # mepc clears only bit 0, so the S-entry PVM-pc Ls must be 2-byte aligned. Here Lh=16
    # (4-aligned, right after the decoy) and Ls=22 (2-aligned).
    Lh = 16                                       # M-mode guest trap handler PVM-pc (4-aligned)
    Ls = 22                                       # S-mode entry PVM-pc (2-aligned)
    code = (
        [LOAD_IMM, 0x01, Lh]                      # r1 = Lh                      @0  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh (guest M tvec)    @3  (4B)
        + [LOAD_IMM, 0x01, Ls]                    # r1 = Ls                      @7  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = Ls                    @10 (4B)
        + [MRET]                                  # mret -> Ls, priv->S          @14 (1B)
        + [TRAP]                                  # DECOY (redirect fail -> exit)@15 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # Lh: r7 = '#' (4-aligned=16)  @16 (3B)
        + [ECALLI, 0x00]                          # ecalli@M -> host putchar '#' @19 (2B)
        + [TRAP]                                  # trap -> exit SUCCESS         @21 (1B)
        + [LOAD_IMM, 0x07, ord('S')]              # Ls: r7 = 'S' (priv-fail char)@22 (3B)
        + [ECALLI, 0x00]                          # ecalli@S -> guest-trap to Lh @25 (2B)
        + [TRAP]                                  # safety exit                  @27 (1B)
    )
    starts = [0, 3, 7, 10, 14, 15, 16, 19, 21, 22, 25, 27]
    assert Lh == 16 and Ls == 22 and len(code) == 28
    return code, starts


def emit_priv_dyn_test():
    """B5 flush-safe guest CSR write: identical to emit_priv_test() EXCEPT the GUEST sets
    mstatus.MPP=S ITSELF (instead of the host loader), via a flush-class CSR write that B5's
    csr-fence makes safe. A write to mstatus raises flush_o in csr_regfile; without B5 that
    flush discards the YOUNGER in-flight PVM uop (here the mret issued right after) -> the eret
    never commits and pvm_fetch hangs (no output). With B5, pvm_fetch fences at the mstatus
    write, lets it commit ALONE, then resumes -- so the round-trip prints '#'.
      @M  load_imm r2,0x800 ; csr_rs r1,r2,mstatus  -> mstatus.MPP=S (FLUSH-CLASS, fenced)
          csr_rw mtvec,Lh ; csr_rw mepc,Ls ; mret    -> redirect to Ls, priv->S
      @23 trap                                         (DECOY: mret-redirect-fail exit)
      @Lh(M) ... (host '#') ... ; @Ls(S) ecalli@S -> guest-trap to Lh
    Prints '#' iff B5 fences the guest mstatus write (no hang) AND the priv round-trip works.
    A hang (no output / timeout) means the flush discarded the mret -> B5 is broken."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mstatus = le(MSTATUS, 2)                      # [0x00, 0x03]
    mtvec   = le(MTVEC, 2)                         # [0x05, 0x03]
    mepc    = le(MEPC, 2)                          # [0x41, 0x03]
    # Layout shifts +8 vs emit_priv_test() for the guest MPP-set prefix (load_imm 4B + csr_rs
    # 4B). ALIGNMENT (RISC-V WARL on the PVM-pc targets): mtvec is 4-byte aligned (direct mode,
    # bits[1:0]=0) so Lh MUST be 4-aligned; mepc clears bit 0 so Ls MUST be 2-aligned. With the
    # +8 prefix and the same body, Lh=24 (4-aligned, right after the decoy) and Ls=30 (2-aligned).
    Lh = 24                                       # M-mode guest trap handler PVM-pc (4-aligned)
    Ls = 30                                       # S-mode entry PVM-pc (2-aligned)
    code = (
        [LOAD_IMM, 0x02, 0x00, 0x08]              # r2 = 0x800 (MPP=S bit, 2-byte imm) @0  (4B)
        + [CSR_RS, b1(1, 2)] + mstatus            # mstatus |= r2 -> MPP=S (FENCED)     @4  (4B)
        + [LOAD_IMM, 0x01, Lh]                     # r1 = Lh                             @8  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh (guest M tvec)           @11 (4B)
        + [LOAD_IMM, 0x01, Ls]                     # r1 = Ls                             @15 (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = Ls                           @18 (4B)
        + [MRET]                                   # mret -> Ls, priv->S                 @22 (1B)
        + [TRAP]                                   # DECOY (redirect fail -> exit)       @23 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # Lh: r7 = '#' (4-aligned=24)         @24 (3B)
        + [ECALLI, 0x00]                          # ecalli@M -> host putchar '#'        @27 (2B)
        + [TRAP]                                   # trap -> exit SUCCESS                @29 (1B)
        + [LOAD_IMM, 0x07, ord('S')]              # Ls: r7 = 'S' (priv-fail char)       @30 (3B)
        + [ECALLI, 0x00]                          # ecalli@S -> guest-trap to Lh        @33 (2B)
        + [TRAP]                                   # safety exit                         @35 (1B)
    )
    starts = [0, 4, 8, 11, 15, 18, 22, 23, 24, 27, 29, 30, 33, 35]
    assert Lh == 24 and Ls == 30 and len(code) == 36
    assert Lh % 4 == 0 and Ls % 2 == 0            # RISC-V WARL: mtvec 4-aligned, mepc 2-aligned
    return code, starts


def emit_priv_return_test():
    """B6 handler-return: prove a guest M-handler can `mret` BACK to the trapped
    S-guest (the enter->serve->return trap cycle a real SBI handler needs), NOT just
    host-exit. cont.20's round-trip M-handler EXITED; here the FIRST handler RETURNS to
    S, then a SECOND guest-trap (via a re-pointed vector) reaches the exit handler.

    Two-vector scheme (avoids the mpp-clobber + any branch). The HOST loader pre-sets
    mstatus.MPP=S (loader_priv.S); the guest writes only mtvec/mepc (flush-free, no B5).
      @0  (M): csr_rw mtvec=Lh1 ; csr_rw mepc=Ls ; mret             -> S@Ls (priv->S)
      @15      trap                                       (DECOY: mret-redirect-fail exit)
      @Ls (S): ecalli #0  -> guest-trap -> Lh1 (priv->M, mepc<-Ls's PVM-pc, mpp<-S)
      @18      trap                                       (DECOY: trap-redirect-fail exit)
      @Lh1(M, 4-aligned): csr_rw mtvec=Lh2 (RE-POINT the vector) ; csr_rw mepc=Sr ; mret
               -> S@Sr.  NB: NO host-exit before this mret, so mstatus.mpp stays S and the
               mret returns to S (a host-exit ecalli@M would clobber mpp=M -> wrongly to M).
      @35      trap                                       (DECOY: handler-return-fail exit)
      @Sr (S, 2-aligned): ecalli #0  -> guest-trap -> Lh2 (the NEW vector)
      @38      trap                                       (DECOY)
      @Lh2(M, 4-aligned): load_imm r7,'#' ; ecalli #0 (host-exit '#') ; trap -> exit
    '#' (framed '[#]' by the host loader) is reachable ONLY if Lh1's mret RETURNED to
    S@Sr (priv=S there so ecalli@Sr is a guest-trap, pc=Sr so it hits the re-pointed
    vector Lh2). A failed handler-return would either fall through Lh1's mret to the
    DECOY trap@35 (exit, no '#') or land at the wrong priv/pc. ALIGNMENT (RISC-V WARL):
    mtvec targets Lh1/Lh2 are 4-aligned (direct mode bits[1:0]=0); mepc/sepc targets
    Ls/Sr are 2-aligned. TRAP(0x00) pad bytes realign each section (@19, @39)."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mtvec = le(MTVEC, 2)                          # [0x05, 0x03]
    mepc  = le(MEPC, 2)                           # [0x41, 0x03]
    Lh1 = 20                                      # 1st M-handler PVM-pc (4-aligned)
    Ls  = 16                                      # S-entry PVM-pc (2-aligned)
    Lh2 = 40                                      # 2nd (re-pointed) M-handler PVM-pc (4-aligned)
    Sr  = 36                                      # S-resume PVM-pc (2-aligned)
    code = (
        [LOAD_IMM, 0x01, Lh1]                     # r1 = Lh1                     @0  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh1 (guest M tvec)   @3  (4B)
        + [LOAD_IMM, 0x01, Ls]                    # r1 = Ls                      @7  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = Ls                    @10 (4B)
        + [MRET]                                  # mret -> Ls, priv->S          @14 (1B)
        + [TRAP]                                  # DECOY (mret-redirect fail)   @15 (1B)
        + [ECALLI, 0x00]                          # Ls(2al=16): ecalli@S -> Lh1  @16 (2B)
        + [TRAP]                                  # DECOY (trap-redirect fail)   @18 (1B)
        + [TRAP]                                  # pad -> Lh1 4-align            @19 (1B)
        + [LOAD_IMM, 0x01, Lh2]                   # Lh1(4al=20): r1 = Lh2        @20 (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh2 (RE-POINT)       @23 (4B)
        + [LOAD_IMM, 0x01, Sr]                    # r1 = Sr                      @27 (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = Sr                    @30 (4B)
        + [MRET]                                  # mret -> Sr (mpp stays S)     @34 (1B)
        + [TRAP]                                  # DECOY (handler-return fail)  @35 (1B)
        + [ECALLI, 0x00]                          # Sr(2al=36): ecalli@S -> Lh2  @36 (2B)
        + [TRAP]                                  # DECOY                        @38 (1B)
        + [TRAP]                                  # pad -> Lh2 4-align            @39 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # Lh2(4al=40): r7 = '#'        @40 (3B)
        + [ECALLI, 0x00]                          # ecalli@M -> host putchar '#' @43 (2B)
        + [TRAP]                                  # trap -> exit SUCCESS         @45 (1B)
    )
    starts = [0, 3, 7, 10, 14, 15, 16, 18, 19, 20, 23, 27, 30, 34, 35, 36, 38, 39, 40, 43, 45]
    assert Lh1 == 20 and Ls == 16 and Lh2 == 40 and Sr == 36 and len(code) == 46
    assert Lh1 % 4 == 0 and Lh2 % 4 == 0          # RISC-V WARL: mtvec 4-aligned
    assert Ls % 2 == 0 and Sr % 2 == 0            # RISC-V WARL: mepc/sepc 2-aligned
    return code, starts


def emit_strap_skip_test():
    """Stage 2 skip-class trap-return: prove an ecalli@S (an SBI call) returns to the instruction
    AFTER the 2-byte ecalli when the guest M-handler does the STANDARD RISC-V `mepc += 4; mret`
    (exactly OpenSBI sbi_ecall.c:165). Without the HW -4 bias on the guest-ecalli trap-capture, the
    captured mepc = the ecalli's OWN pc, so `mepc += 4` OVERSHOOTS the 2-byte ecalli by 2 and skips
    the next instruction; with the bias the capture = next_pc(ecalli)-4, so `mepc += 4` lands exactly
    on next_pc(ecalli).

    The handler does a FAITHFUL READ-MODIFY-WRITE (csrr mepc; add 4; csrw mepc; mret) -- NOT a
    `csr_rw mepc,<const>` -- so the result genuinely depends on the CAPTURED value (a const write
    would pass even WITH the bug, hiding it). Two-vector scheme (no branch needed, mirrors
    emit_priv_return_test): the 1st ecalli@S -> Lh1 (skip-return; re-points mtvec to Lh2); the
    success path's 2nd ecalli@S -> Lh2 (host-exit '#'). The 2nd ecalli sits EXACTLY at
    next_pc(1st ecalli)=Ls+2; a wrong landing (the bug: mepc+4 = Ls+4 = 2 bytes too far) hits the
    DECOY trap@Ls+4 and exits with NO '#'. So '[#]' appears IFF the -4 bias is correct.
      @M  csr_rw mtvec=Lh1 ; csr_rw mepc=Ls ; mret        -> S@Ls (priv->S)
      @15 trap                                            (DECOY: mret-redirect fail)
      @Ls(S,16): ecalli #0   -> guest-trap to Lh1 ; SKIP-target = @18
      @18  (S):  ecalli #0   -> guest-trap to Lh2 -> host '#'  (reached IFF skip landed here)
      @20 trap (+pads)                                    (DECOY: bug lands @Ls+4=20 -> no '#')
      @Lh1(M,24): csr_rw mtvec=Lh2 ; r5=0 ; r3=mepc ; r3+=4 ; mepc=r3 ; mret  -> S@18
      @46 trap (+pad)                                     (DECOY: skip-return fail)
      @Lh2(M,48): load_imm r7,'#' ; ecalli #0 (host '#') ; trap
    Prints '[#]' iff the -4 bias made the standard `mepc += 4` land on the instruction after the
    ecalli. HOST pre-sets mstatus.MPP=S (loader_priv.S); the guest writes only mtvec/mepc (flush-free)."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mtvec = le(MTVEC, 2)                          # [0x05, 0x03]
    mepc  = le(MEPC, 2)                           # [0x41, 0x03]
    Lh1 = 24                                      # skip-return M-handler PVM-pc (4-aligned)
    Ls  = 16                                      # S-entry / 1st-ecalli PVM-pc (2-aligned)
    Lh2 = 48                                      # exit M-handler PVM-pc (4-aligned)
    code = (
        [LOAD_IMM, 0x01, Lh1]                     # r1 = Lh1                        @0  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh1 (guest M tvec)      @3  (4B)
        + [LOAD_IMM, 0x01, Ls]                    # r1 = Ls                         @7  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = Ls                       @10 (4B)
        + [MRET]                                  # mret -> Ls, priv->S             @14 (1B)
        + [TRAP]                                  # DECOY (mret-redirect fail)      @15 (1B)
        + [ECALLI, 0x00]                          # Ls(16): 1st ecalli@S -> Lh1     @16 (2B)
        + [ECALLI, 0x00]                          # @18: 2nd ecalli@S -> Lh2 -> '#' @18 (2B)
        + [TRAP]                                  # DECOY: bug lands @Ls+4=20       @20 (1B)
        + [TRAP] + [TRAP] + [TRAP]                # pad -> Lh1 4-align              @21,22,23
        + [LOAD_IMM, 0x01, Lh2]                   # Lh1(24): r1 = Lh2               @24 (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh2 (RE-POINT vector)   @27 (4B)
        + [LOAD_IMM, 0x05, 0x00]                  # r5 = 0 (zero reg for csrr)      @31 (3B)
        + [CSR_RS, b1(3, 5)] + mepc               # r3 = mepc (= next_pc-4); |=0    @34 (4B)
        + [ADD_IMM_32, (3 << 4) | 3, 0x04]        # r3 += 4  (== RISC-V `mepc += 4`)@38 (3B)
        + [CSR_RW, b1(4, 3)] + mepc               # mepc = r3 (= next_pc)           @41 (4B)
        + [MRET]                                  # mret -> S@18 (mpp stays S)      @45 (1B)
        + [TRAP]                                  # DECOY (skip-return fail)        @46 (1B)
        + [TRAP]                                  # pad -> Lh2 4-align              @47 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # Lh2(48): r7 = '#'               @48 (3B)
        + [ECALLI, 0x00]                          # ecalli@M -> host putchar '#'    @51 (2B)
        + [TRAP]                                  # trap -> exit SUCCESS            @53 (1B)
    )
    starts = [0, 3, 7, 10, 14, 15, 16, 18, 20, 21, 22, 23,
              24, 27, 31, 34, 38, 41, 45, 46, 47, 48, 51, 53]
    assert Lh1 == 24 and Ls == 16 and Lh2 == 48 and len(code) == 54
    assert Lh1 % 4 == 0 and Lh2 % 4 == 0          # RISC-V WARL: mtvec 4-aligned
    assert Ls % 2 == 0 and (Ls + 2) % 2 == 0      # RISC-V WARL: mepc 2-aligned (entry + skip-target)
    return code, starts


def emit_handoff_skip(idx=0, z=1):
    """COMBINED Stage-1 + Stage-2 gate (the real OpenSBI config): the eret-via-JT bit CFG2[36] must
    JT-map ONLY the one-shot M->S handoff, then SELF-CLEAR so the subsequent ecalli@S skip-return is
    DIRECT. The host loader (loader_handoff_smode.S) sets CFG2[36]=1 + a JT (sticky, exactly like
    loader_opensbi.S), so without the one-shot self-clear the skip-return's RAW mepc would be fed to
    the JT mapper and mangled -> wrong target -> no '#'. Body is emit_strap_skip_test's, EXCEPT the
    M->S ENTRY mret uses a JT-ENCODED mepc (token (idx+1)*2) so it is JT-mapped (and consumes CFG2[36]).
      @M  mtvec=Lh1 ; mepc=(idx+1)*2 (JT token) ; mret  -> JT[idx]=Ls (JT-mapped; CONSUMES CFG2[36])
      @Ls(S,16): ecalli@S -> Lh1 ; SKIP-target=@18  (this skip-return mret MUST now be DIRECT)
      @18 (S):   ecalli@S -> Lh2 -> host '#'
      @20 trap (+pads)                                  (DECOY: skip-return JT-mangled/overshot -> no '#')
      @Lh1(M,24): mtvec=Lh2 ; r5=0 ; r3=mepc ; r3+=4 ; mepc=r3 ; mret  -> S@18 (DIRECT, bit36 consumed)
      @46 trap (+pad)
      @Lh2(M,48): load_imm r7,'#' ; ecalli@M (host '#') ; trap
    Prints '[#]' iff BOTH hold: CFG2[36] one-shot (handoff JT-maps then self-clears) AND the -4 skip
    bias. A still-sticky CFG2[36] -> the skip-return mret JT-maps a raw PVM-pc -> wrong -> no '#'."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mtvec = le(MTVEC, 2)                          # [0x05, 0x03]
    mepc  = le(MEPC, 2)                           # [0x41, 0x03]
    Lh1 = 24                                      # skip-return M-handler PVM-pc (4-aligned)
    Ls  = 16                                      # S-entry / 1st-ecalli PVM-pc (2-aligned) = JT[idx]
    Lh2 = 48                                      # exit M-handler PVM-pc (4-aligned)
    token = (idx + 1) * 2                         # JT-encoded handoff target (PolkaVM jump token)
    code = (
        [LOAD_IMM, 0x01, Lh1]                     # r1 = Lh1                        @0  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh1                     @3  (4B)
        + [LOAD_IMM, 0x01, token]                 # r1 = JT token (NOT Ls)          @7  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = token                    @10 (4B)
        + [MRET]                                  # JT-map -> JT[idx]=Ls; CONSUME   @14 (1B)
        + [TRAP]                                  # DECOY (handoff fail)            @15 (1B)
        + [ECALLI, 0x00]                          # Ls(16): 1st ecalli@S -> Lh1     @16 (2B)
        + [ECALLI, 0x00]                          # @18: 2nd ecalli@S -> Lh2 -> '#' @18 (2B)
        + [TRAP]                                  # DECOY: skip-return mis-land     @20 (1B)
        + [TRAP] + [TRAP] + [TRAP]                # pad -> Lh1 4-align              @21,22,23
        + [LOAD_IMM, 0x01, Lh2]                   # Lh1(24): r1 = Lh2               @24 (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = Lh2 (RE-POINT)          @27 (4B)
        + [LOAD_IMM, 0x05, 0x00]                  # r5 = 0 (zero reg for csrr)      @31 (3B)
        + [CSR_RS, b1(3, 5)] + mepc               # r3 = mepc (= next_pc-4); |=0    @34 (4B)
        + [ADD_IMM_32, (3 << 4) | 3, 0x04]        # r3 += 4  (== RISC-V mepc += 4)  @38 (3B)
        + [CSR_RW, b1(4, 3)] + mepc               # mepc = r3 (= next_pc)           @41 (4B)
        + [MRET]                                  # DIRECT eret (bit36 consumed)    @45 (1B)
        + [TRAP]                                  # DECOY (skip-return fail)        @46 (1B)
        + [TRAP]                                  # pad -> Lh2 4-align              @47 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # Lh2(48): r7 = '#'               @48 (3B)
        + [ECALLI, 0x00]                          # ecalli@M -> host putchar '#'    @51 (2B)
        + [TRAP]                                  # trap -> exit SUCCESS            @53 (1B)
    )
    starts = [0, 3, 7, 10, 14, 15, 16, 18, 20, 21, 22, 23,
              24, 27, 31, 34, 38, 41, 45, 46, 47, 48, 51, 53]
    jumptable = [0] * idx + [Ls]                  # JT[idx] = Ls (handoff target)
    assert Lh1 == 24 and Ls == 16 and Lh2 == 48 and len(code) == 54
    assert Lh1 % 4 == 0 and Lh2 % 4 == 0 and Ls % 2 == 0
    return code, starts, jumptable, z


def emit_trap_jt(idx=0, z=1):
    """trap-via-JT gate (the EXACT mirror of emit_handoff_smode, which exercises eret-via-JT/CFG2[36]).
    Real OpenSBI sets mtvec via `lla _trap_handler; csrw mtvec`; in PVM `lla` yields a jump-table
    TOKEN, NOT a raw PVM-pc, so a guest-internal ecalli@S would trap to the raw token (garbage). With
    CSR_PVM_CFG2[37]=1 the guest-trap redirect maps mtvec (a JT token) THROUGH the jump table -> the
    ecalli@S reaches JT[idx]=the real M-handler PVM-pc.

    Here the guest sets mtvec = a JT-ENCODED token ((idx+1)*2, NOT Lh) and mepc = Ls (a RAW S-entry
    PVM-pc), then mret. The entry mret is a NORMAL raw-pc eret (the loader leaves CFG2[36]=0), so it
    lands at Ls directly and drops to S (host pre-set MPP=S). At Ls a guest-internal ecalli@S stays in
    PVM and traps to the guest mtvec=token; the trap-via-JT maps token -> JT[idx]=Lh (the in-image M
    handler), which putchars '#'. Prints framed '[#]' iff the trap target was JT-mapped to Lh.
    With CFG2[37]=0 (the negative control) the token is used RAW -> PVM-pc 2 (mid-instruction) -> no '#'.
    Lh=16 (4-aligned, mtvec target after the JT map), Ls=22 (2-aligned, mepc). Body mirrors
    emit_handoff_smode with the mtvec/mepc roles swapped (token in mtvec, raw Ls in mepc)."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mtvec  = le(MTVEC, 2)
    mepc   = le(MEPC, 2)
    token  = (idx + 1) * 2                        # JT-encoded mtvec (PolkaVM jump token), NOT Lh
    assert 0 <= token <= 127, f"token {token} needs a multi-byte load_imm (use idx<=62)"
    Lh = 16                                       # M-mode guest trap handler PVM-pc (4-aligned) = JT[idx]
    Ls = 22                                       # S-mode entry PVM-pc (2-aligned, raw mepc)
    code = (
        [LOAD_IMM, 0x01, token]                   # r1 = (idx+1)*2 (JT token for mtvec) @0  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec              # mtvec = token (JT-encoded tvec)     @3  (4B)
        + [LOAD_IMM, 0x01, Ls]                    # r1 = Ls (raw S-entry PVM-pc)        @7  (3B)
        + [CSR_RW, b1(2, 1)] + mepc               # mepc = Ls                           @10 (4B)
        + [MRET]                                  # mret -> Ls (raw eret), priv->S      @14 (1B)
        + [TRAP]                                  # DECOY (mret-redirect fail -> exit)  @15 (1B)
        + [LOAD_IMM, 0x07, ord('#')]              # Lh: r7 = '#' (4-aligned=16)         @16 (3B)
        + [ECALLI, 0x00]                          # ecalli@M -> host putchar '#'        @19 (2B)
        + [TRAP]                                  # trap -> exit SUCCESS                @21 (1B)
        + [ECALLI, 0x00]                          # Ls(22): ecalli@S -> guest-trap (JT-map mtvec->Lh) @22 (2B)
        + [TRAP]                                  # safety exit                         @24 (1B)
    )
    starts = [0, 3, 7, 10, 14, 15, 16, 19, 21, 22, 24]
    jumptable = [0] * idx + [Lh]                  # JT[idx] = the M-handler PVM-pc (16)
    assert Lh == 16 and Ls == 22 and len(code) == 25
    assert Lh % 4 == 0 and Ls % 2 == 0            # RISC-V WARL: mtvec(->Lh) 4-aligned, mepc 2-aligned
    return code, starts, jumptable, z


def emit_handoff_trap_jt(idx_e=0, idx_t=2, z=1):
    """COMBINED eret-via-JT (CFG2[36]) + trap-via-JT (CFG2[37]) -- the UNTESTED real-OpenSBI SEQUENCE.

    This is the exact composition run-handoff-smode-dram (CFG2[36] only) and run-trap-jt-dram
    (CFG2[37] only, RAW M->S entry) each covered HALF of, but which neither exercised together:
      1. The M->S handoff is a JT-MAPPED eret (CFG2[36]=1): mepc = a JT token, mret -> JT[idx_e]=Ls,
         priv->S, and the eret-via-JT one-shot CONSUMES CFG2[36] (-> 0). [exactly emit_handoff_smode]
      2. THEN, in S-mode, an ecalli@S whose guest mtvec is a DIFFERENT JT token must trap-via-JT
         (CFG2[37]=1, still set): the guest-trap redirect JT-maps mtvec -> JT[idx_t]=Lh -> host '[#]'.
         [exactly emit_trap_jt's S-side]
    The real OpenSBI launcher sets BOTH bits (`li t1,(3<<36)`, loader_opensbi.S); the handoff
    consumes [36] while [37] stays 1. So the SECOND JT-map (the trap) runs with the SAME JT-FSM
    state (djump_a_q/jt_req_q/jt_valid_q/djump_pending/d_state_q) left behind by the FIRST (the
    consumed eret) -- the precise interaction run-trap-jt-dram (raw entry, CFG2[36]=0) skipped.

    The guest mtvec is a JT TOKEN (token_t), NOT a raw Lh, so reaching Lh proves the trap-via-JT
    JT-mapped (not a raw-mtvec accident). idx_t != idx_e (and idx_t > idx_e) so the trap's JT read
    is a SEPARATE jump-table entry from the eret's -> a distinct cold-miss line on the DRAM path.
      @M  mtvec=token_t (JT) ; mepc=token_e (JT) ; mret  -> JT[idx_e]=Ls, priv->S, CONSUME CFG2[36]
      @15 trap                                            (DECOY: handoff redirect fail -> exit)
      @Lh(16,M): r7='#' ; ecalli@M (host '#') ; trap      (reached only via the trap-via-JT JT-map)
      @Ls(22,S): ecalli@S -> guest-trap, mtvec=token_t JT-mapped (CFG2[37]) -> JT[idx_t]=Lh
    Prints framed '[#]' iff BOTH JT-maps fired in sequence; 'S'... no -- there is no 'S' decoy here:
    a failed trap-via-JT (token used raw -> mid-instruction pc) yields garbage/no '#'. Layout is
    byte-identical to emit_handoff_smode (Lh=16,Ls=22,len=25); only mtvec's value (token_t vs Lh)
    and the jump table (two live entries) differ -- so CFG2[37]=0 reuses this same image as a
    negative control (token_t raw -> no '#'), exactly like run-trap-jt[-dram]."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    mtvec   = le(MTVEC, 2)
    mepc    = le(MEPC, 2)
    token_e = (idx_e + 1) * 2                      # eret-via-JT token (mepc) -> JT[idx_e]=Ls
    token_t = (idx_t + 1) * 2                      # trap-via-JT token (mtvec) -> JT[idx_t]=Lh
    assert 0 <= token_e <= 127 and 0 <= token_t <= 127, "tokens need a 1-byte load_imm (idx<=62)"
    assert idx_t != idx_e, "the trap and eret JT entries must differ (separate cold-miss lines)"
    Lh = 16                                        # M-mode guest trap handler PVM-pc (4-aligned) = JT[idx_t]
    Ls = 22                                        # S-mode entry PVM-pc (2-aligned) = JT[idx_e]
    code = (
        [LOAD_IMM, 0x01, token_t]                  # r1 = token_t (JT token for mtvec)   @0  (3B)
        + [CSR_RW, b1(2, 1)] + mtvec               # mtvec = token_t (JT-encoded tvec)   @3  (4B)
        + [LOAD_IMM, 0x01, token_e]                # r1 = token_e (JT token for mepc)    @7  (3B)
        + [CSR_RW, b1(2, 1)] + mepc                # mepc = token_e                      @10 (4B)
        + [MRET]                                   # mret JT-map -> JT[idx_e]=Ls, priv->S, CONSUME @14 (1B)
        + [TRAP]                                   # DECOY (handoff redirect fail -> exit)@15 (1B)
        + [LOAD_IMM, 0x07, ord('#')]               # Lh: r7 = '#' (4-aligned=16)         @16 (3B)
        + [ECALLI, 0x00]                           # ecalli@M -> host putchar '#'        @19 (2B)
        + [TRAP]                                   # trap -> exit SUCCESS                @21 (1B)
        + [ECALLI, 0x00]                           # Ls(22): ecalli@S -> guest-trap (JT-map mtvec->Lh) @22 (2B)
        + [TRAP]                                   # safety exit                         @24 (1B)
    )
    starts = [0, 3, 7, 10, 14, 15, 16, 19, 21, 22, 24]
    nj = max(idx_e, idx_t) + 1
    jumptable = [0] * nj
    jumptable[idx_e] = Ls                          # JT[idx_e] = S-entry  (eret-via-JT target)
    jumptable[idx_t] = Lh                          # JT[idx_t] = M-handler (trap-via-JT target)
    assert Lh == 16 and Ls == 22 and len(code) == 25
    assert Lh % 4 == 0 and Ls % 2 == 0             # RISC-V WARL: mtvec(->Lh) 4-aligned, mepc 2-aligned
    return code, starts, jumptable, z


def emit_smode_loop(n=5, jt_handoff=False, idx=0, z=1):
    """Stage 3 (re-scoped): a REAL S-mode payload -- an S-mode LOOP making N SBI-putchar
    ecalli@S calls, each round-tripping through ONE reusable guest M-handler that does the
    putchar (direct UART MMIO, exactly like OpenSBI's M-mode console driver) THEN the standard
    RISC-V skip-return (csrr mepc; +4; csrw mepc; mret). Unlike run-strap-skip / run-handoff-skip
    (a SINGLE synthetic 2-ecalli round-trip), this exercises the pattern a real S payload actually
    runs -- repeated SBI calls in a loop with LIVE S-mode state that must survive every trap:
      * r1 (loop counter), r2 (branch-zero) and r7 (the char) are the live S-state, written in S and
        used/advanced ACROSS the round-trip. The M-handler WRITES only r3/r4/r5/r6 (r4 = the discarded
        old-mepc from the csr_rw) and READS r7/r8 -- it never writes r1/r2/r7 -> proves S-register
        preservation across S->M->S (an exact 'ABCDE' requires both r1 and r7 to survive every trap).
      * the one handler is reached N times -> repeated skip-returns (and, in the CFG2[36] -jt
        variant, that the eret-via-JT one-shot stays consumed across many erets).
      * the handler does REAL work (UART MMIO putchar) when entered via the S-trap path.
    The handler does NO ecalli@M, so nothing clobbers mepc/mstatus.MPP (gotcha #3): MPP stays S and
    the mret returns to S directly. Output = the N sequential chars 'A','B',... ('ABCDE' for n=5);
    a clobbered counter/char -> truncated/garbled string, a mis-landed skip-return -> hang/decoy.
    HOST pre-sets mstatus.MPP=S (loader_priv.S, CFG2=0); the guest writes only mtvec/mepc (flush-free).

    Layout is computed from instruction lengths (Lh/Ls < 128 -> 1-byte load_imm), then the forward
    refs (Lh, Ls) and the backward branch offset are back-patched; alignment is asserted."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)   # polkavm2: rd=LOW nibble, csr-src=HIGH
    BRANCH_NE = 0xAB                              # 171: branch if rA!=rB; arg=(rB<<4)|rA, then LE off
    mtvec = le(MTVEC, 2)
    mepc  = le(MEPC, 2)
    assert 1 <= n <= 26, "n in 1..26 (1-byte counter imm; 'A'+n-1 stays printable ASCII)"
    instrs = [
        # ---- M-prologue (priv M): arm the guest mtvec=Lh, mepc=Ls, hand off to S ----
        [LOAD_IMM_64, R_BASE & 0x0F] + le(UART_THR, 8),  # r8 = UART base (the handler's putchar dst)
        [LOAD_IMM, 0x01, 0x00],                          # r1 = Lh           (imm back-patched)
        [CSR_RW, b1(2, 1)] + mtvec,                      # mtvec = Lh (guest M trap vector)
        [LOAD_IMM, 0x01, 0x00],                          # r1 = Ls           (imm back-patched)
        [CSR_RW, b1(2, 1)] + mepc,                       # mepc = Ls (S-entry, raw pc)
        [MRET],                                          # mret -> S@Ls, priv->S
        [TRAP],                                          # DECOY (handoff redirect fail -> exit)
        # ---- S-mode payload (priv S) at Ls: the SBI-putchar loop ----
        [LOAD_IMM, 0x02, 0x00],                          # r2 = 0 (branch zero reg)
        [LOAD_IMM, 0x01, n & 0xFF, 0x00],                # r1 = n (4-byte load -> ecalli lands even)
        [LOAD_IMM, R_CHAR & 0x0F, ord('A')],             # r7 = 'A' (first char)
        [ECALLI, 0x00],                                  # Lloop: ecalli@S -> Lh; skip-return -> here+2
        [ADD_IMM_32, (R_CHAR << 4) | R_CHAR, 0x01],      # r7 += 1 (next char) -- MUST survive the trap
        [ADD_IMM_32, (1 << 4) | 1, 0xFF],                # r1 -= 1 (counter)   -- MUST survive the trap
        [BRANCH_NE, b1(1, 2), 0x00],                     # branch_ne r1,r2,Lloop (off back-patched)
        [TRAP],                                          # loop done -> host exit SUCCESS
        # ---- guest M-handler (priv M) at Lh: putchar(r7) THEN skip-return ----
        [STORE_IND_U8, ((R_BASE & 0xF) << 4) | (R_CHAR & 0xF)],              # [r8] = r7 (UART THR)
        [LOAD_IND_U8, ((R_BASE & 0xF) << 4) | (R_SCR & 0xF), UART_LSR_OFF],  # serialize (LSR read)
        [LOAD_IMM, 0x05, 0x00],                          # r5 = 0 (zero reg for csrr)
        [CSR_RS, b1(3, 5)] + mepc,                       # r3 = mepc (= next_pc-4 via the -4 bias)
        [ADD_IMM_32, (3 << 4) | 3, 0x04],                # r3 += 4 (== RISC-V `mepc += 4`)
        [CSR_RW, b1(4, 3)] + mepc,                       # mepc = r3 (= next_pc)
        [MRET],                                          # mret -> S@next_pc (MPP stays S; no clobber)
    ]
    starts, code = [], []
    for ins in instrs:
        starts.append(len(code)); code.extend(ins)
    Ls    = starts[7]     # first S-payload instr (load_imm r2,0)
    Lloop = starts[10]    # the ecalli@S
    Lh    = starts[15]    # store_ind_u8 (handler entry)
    code[starts[1] + 2] = Lh                  # M-prologue: r1 = Lh
    # The M->S handoff mepc: a JT-encoded token (real-OpenSBI / CFG2[36]=1 config -> the entry mret
    # is JT-mapped and CONSUMES the one-shot) or the raw S-entry pc (CFG2=0). The N skip-returns in
    # the loop are ALWAYS direct (bit36 consumed) -- the -jt variant stress-tests that the one-shot
    # stays consumed across MANY erets (run-handoff-skip only ever did ONE skip-return after handoff).
    code[starts[3] + 2] = (idx + 1) * 2 if jt_handoff else Ls   # M-prologue: r1 = handoff target
    code[starts[13] + 2] = (Lloop - starts[13]) & 0xFF   # backward branch offset (target-branch_start)
    assert Lh % 4 == 0, f"Lh={Lh} must be 4-aligned (mtvec direct mode WARL)"
    assert Ls % 2 == 0, f"Ls={Ls} must be 2-aligned (mepc WARL)"
    assert (Lloop + 2) % 2 == 0, "skip-target (post-ecalli pc) must be 2-aligned (mepc WARL)"
    if jt_handoff:
        jumptable = [0] * idx + [Ls]          # JT[idx] = Ls (the JT-mapped M->S handoff target)
        return code, starts, jumptable, z
    return code, starts


def emit_smode_sbi(n=5):
    """B7 Phase-A: prove the REAL OpenSBI SBI-dispatch HW path with a fast synthetic proxy. Same
    S-mode loop as emit_smode_loop, but the guest M-handler does OpenSBI-style CAUSE DISPATCH before
    servicing: it reads mcause and services (putchar + skip-return) ONLY if mcause==ENV_CALL_SMODE(9),
    else it falls to a DECOY trap (host-exit, no output). This empirically confirms that an ecalli@S
    presents mcause=ENV_CALL_SMODE to the guest mtvec handler (cva6.sv:772-775) -- exactly what
    OpenSBI's real sbi_trap_handler keys on to route a supervisor ecall to sbi_ecall. A pass ('ABCDE')
    means the HW cause is correct AND the dispatch-on-cause pattern works on real silicon, so the real
    OpenSBI SBI round-trip is HW-validated WITHOUT the ~30-min full-OpenSBI rebuild/run. If the cause
    were wrong, every iteration would hit the decoy -> NO output. Live S-state r1/r2/r7 survives; the
    handler writes r3/r4/r5/r6, reads r7/r8. HOST pre-sets MPP=S (loader_priv.S, CFG2=0)."""
    def b1(rd, rs1):
        return ((rs1 & 0xF) << 4) | (rd & 0xF)
    BRANCH_NE = 0xAB
    mtvec  = le(MTVEC, 2)
    mepc   = le(MEPC, 2)
    mcause = le(MCAUSE, 2)
    assert 1 <= n <= 26, "n in 1..26 (1-byte counter imm; 'A'+n-1 stays printable ASCII)"
    instrs = [
        # ---- M-prologue (priv M): arm guest mtvec=Lh, mepc=Ls, hand off to S ----
        [LOAD_IMM_64, R_BASE & 0x0F] + le(UART_THR, 8),  # r8 = UART base
        [LOAD_IMM, 0x01, 0x00],                          # r1 = Lh        (back-patched)
        [CSR_RW, b1(2, 1)] + mtvec,                      # mtvec = Lh
        [LOAD_IMM, 0x01, 0x00],                          # r1 = Ls        (back-patched)
        [CSR_RW, b1(2, 1)] + mepc,                       # mepc = Ls
        [MRET],                                          # mret -> S@Ls, priv->S
        [TRAP],                                          # DECOY (handoff fail)
        # ---- S-mode payload (priv S): the SBI-putchar loop ----
        [LOAD_IMM, 0x02, 0x00],                          # r2 = 0 (branch zero)
        [LOAD_IMM, 0x01, n & 0xFF, 0x00],                # r1 = n (4B -> ecalli even)
        [LOAD_IMM, R_CHAR & 0x0F, ord('A')],             # r7 = 'A'
        [ECALLI, 0x00],                                  # Lloop: ecalli@S -> Lh (SBI call)
        [ADD_IMM_32, (R_CHAR << 4) | R_CHAR, 0x01],      # r7 += 1
        [ADD_IMM_32, (1 << 4) | 1, 0xFF],                # r1 -= 1
        [BRANCH_NE, b1(1, 2), 0x00],                     # branch_ne r1,r2,Lloop (off patched)
        [TRAP],                                          # loop done -> host exit SUCCESS
        # ---- guest M-handler (priv M) at Lh: OpenSBI-style cause dispatch, then service ----
        [LOAD_IMM, 0x05, 0x00],                          # r5 = 0 (zero source for csrr)
        [CSR_RS, b1(4, 5)] + mcause,                     # r4 = mcause (expect ENV_CALL_SMODE=9)
        [LOAD_IMM, 0x03, 0x09],                          # r3 = 9 (ENV_CALL_SMODE)
        [BRANCH_NE, b1(4, 3), 0x00],                     # if mcause != 9 -> Ldecoy (off patched)
        [STORE_IND_U8, ((R_BASE & 0xF) << 4) | (R_CHAR & 0xF)],              # [r8]=r7 (serviced putchar)
        [LOAD_IND_U8, ((R_BASE & 0xF) << 4) | (R_SCR & 0xF), UART_LSR_OFF],  # serialize
        [CSR_RS, b1(3, 5)] + mepc,                       # r3 = mepc (= next_pc-4)
        [ADD_IMM_32, (3 << 4) | 3, 0x04],                # r3 += 4 (RISC-V mepc += 4)
        [CSR_RW, b1(4, 3)] + mepc,                        # mepc = r3 (= next_pc)
        [MRET],                                          # mret -> S@next_pc (MPP stays S)
        [TRAP],                                          # Ldecoy: mcause wasn't 9 -> host exit, no output
    ]
    starts, code = [], []
    for ins in instrs:
        starts.append(len(code)); code.extend(ins)
    Ls    = starts[7]
    Lloop = starts[10]
    Lh    = starts[15]
    Ldecoy = starts[25]                       # the trailing trap (cause-mismatch landing)
    code[starts[1] + 2] = Lh                  # M-prologue: r1 = Lh
    code[starts[3] + 2] = Ls                  # M-prologue: r1 = Ls
    code[starts[13] + 2] = (Lloop - starts[13]) & 0xFF      # loop backward branch
    code[starts[18] + 2] = (Ldecoy - starts[18]) & 0xFF     # handler forward decoy branch (mcause!=9)
    assert Lh % 4 == 0 and Ls % 2 == 0 and (Lloop + 2) % 2 == 0
    assert Ldecoy > starts[18], "decoy must be forward of its branch"
    return code, starts


CODE_APPEND_BASE = 0x80100000   # fixed DRAM code_base for run-codeappend (link_codeappend.ld)


def emit_codeappend(code_base=CODE_APPEND_BASE):
    """B2 foundation micro-test: prove a PVM guest can, at RUNTIME, write new bytecode + a rebuilt
    opcode bitmask into its own DRAM code-region, have code_len grown so the new code becomes
    fetchable, and execute it.

    ONE code-region at `code_base` (M3 DRAM demand-fetch, CFG1[34]=1 -> code stays in DRAM, so a
    guest LSU store to it is a physical-address pass-through == writable):
      APPENDER [pc 0..L0)      : the initial code (initial code_len = L0).
      (gap + initial bitmask)  : align16(L0) holds the LSB-first bitmask that decodes the appender.
      NC       [pc NC..NC+6)   : new code, WRITTEN by the appender at runtime into FRESH space past
                                 the initial bitmask; ABSENT until the grow, and it never overlaps
                                 the live initial bitmask (so the appender's own decode is safe).
      new bitmask [align16(L1))]: the FULL rebuilt bitmask (appender + NC starts), written by the
                                 appender; a DIFFERENT base from the initial one (bitmask_base moves
                                 with code_len: cva6.sv code_base+align16(code_len)) -- so this
                                 exercises the bitmask-base MOVE, the core B2 hardware fact.

    APPENDER (in order):
      1. r2 = code_base + NC                  base for BOTH stores (NC@+0, bitmask@+BM_OFF)
      2. r3 = NC bytes packed as one u64
      3. store_ind_u64 [r2+0]      = r3       write NC (u64 store => NC 8-aligned by construction)
      4. r5 = full rebuilt bitmask u64
      5. store_ind_u64 [r2+BM_OFF] = r5       write the rebuilt bitmask at code_base+align16(L1)
      6. ecalli #2                            ask the HOST to grow code_len to L1 and enter at pc NC

    Why the host grows code_len (not the guest): a guest `csr_rw CFG1` is NOT flagged is_csr_fence
    in pvm_decoder (only mstatus/sstatus/satp/mstatush are), yet a CFG1 write raises flush_o in
    csr_regfile. Un-fenced, that commit-flush redirect is NOT absorbed by a pvm_fetch suspend, so
    the front-end momentarily fetches the PVM-pc as a RISC-V address -> ILLEGAL_INSTR (RVFI-confirmed:
    the guest's csrw CFG1 at pc 0x34 raised ILLEGAL_INSTR after both stores committed correctly).
    So the guest asks the host (RISC-V, where csrw CFG1 flushes cleanly) to grow + re-enter. The
    CFG registers are the host<->guest control interface, so a guest requesting a code-region grow
    via a host-call is the faithful model. The re-entry is a fresh start (rising edge -> start_pulse
    kills+reloads the demand-fetch window) at CFG0.entry_pc = NC, so NC is fetched with the grown
    code_len and the rebuilt bitmask.

    NC = putchar('B') via a host-call, then trap: load_imm r7,'B' ; ecalli #0 ; trap.
    SUCCESS == the host prints 'B' (the dynamically-written code executed).

    Returns (appender_code, appender_starts) -> build_image builds the initial blob at code_len L0;
    prints INIT_CODE_LEN / GROWN_CODE_LEN / NC_START for the loader defines. `code_base` is fixed by
    link_codeappend.ld so the appender can hard-encode absolute store addresses (no guest `lla`)."""
    def align16(n):
        return (n + 15) & ~15
    def align8(n):
        return (n + 7) & ~7

    # ---- NC: the code the appender writes at runtime; ecalli #0 = host putchar('B') ----
    nc = [LOAD_IMM, R_CHAR & 0xF, ord('B')] + [ECALLI, 0x00] + [TRAP]   # 3 + 2 + 1 = 6 bytes
    nc_rel_starts = [0, 3, 5]
    nc_len = len(nc)

    # ---- APPENDER: placeholder immediates, patched once its length L0 is known. load_imm64 is a
    #      fixed 10 bytes regardless of value, so L0 is independent of the addresses we patch in.
    #      Ends with ecalli #2 (grow request) -- no guest CFG1 write (see docstring). ----
    P8 = [0] * 8
    instrs = [
        [LOAD_IMM_64, 0x02] + P8,                    # r2 = code_base + NC   (base for both stores)
        [LOAD_IMM_64, 0x03] + P8,                    # r3 = NC packed u64
        [STORE_IND_U64, (0x2 << 4) | 0x3, 0x00],     # [r2+0]      = r3  (write NC)
        [LOAD_IMM_64, 0x05] + P8,                    # r5 = rebuilt bitmask u64
        [STORE_IND_U64, (0x2 << 4) | 0x5, 0x00],     # [r2+BM_OFF] = r5  (off patched below)
        [ECALLI, 0x02],                              # ecalli #2 -> host: grow code_len + enter @ NC
    ]
    code, starts = [], []
    for ins in instrs:
        starts.append(len(code)); code.extend(ins)
    L0 = len(code)                                    # appender length == initial code_len

    # NC lives in FRESH 8-aligned space just past the initial bitmask (align16(L0)+ceil(L0/8)), so a
    # runtime store never touches the live initial bitmask, and NC_BASE is 8-aligned for the u64 store.
    init_bm_end = align16(L0) + (L0 + 7) // 8
    nc_start = align8(init_bm_end)
    nc_base  = code_base + nc_start
    assert nc_base % 8 == 0, f"NC_BASE 0x{nc_base:x} not 8-aligned"
    L1 = nc_start + nc_len

    bm_dest = code_base + align16(L1)                 # rebuilt-bitmask base (moves with code_len)
    bm_off  = align16(L1) - nc_start                  # store offset from nc_base to the bitmask
    assert 0 <= bm_off < 128, f"bm_off {bm_off} needs a multi-byte store offset"
    assert align16(L1) >= nc_start + 8, f"rebuilt bitmask 0x{bm_dest:x} overlaps the NC store"

    nc_u64 = 0
    for i, b in enumerate(nc):                        # 6 NC bytes + 2 zero -> one u64 store
        nc_u64 |= b << (8 * i)

    all_starts = list(starts) + [nc_start + s for s in nc_rel_starts]
    assert (L1 + 7) // 8 <= 8, "rebuilt bitmask exceeds one u64 store"
    bm_bytes = [0] * 8
    for s in all_starts:
        bm_bytes[s // 8] |= 1 << (s % 8)
    bm_u64 = 0
    for i, b in enumerate(bm_bytes):
        bm_u64 |= b << (8 * i)

    reserve_end = align16(L1) + 8                     # last byte the bitmask u64 store touches

    def put_u64(instr_idx, value):
        base = starts[instr_idx] + 2                  # opcode + reg byte, then 8 LE imm bytes
        for i in range(8):
            code[base + i] = (value >> (8 * i)) & 0xFF
    put_u64(0, nc_base)                               # instr 1: r2 = NC/bitmask base
    put_u64(1, nc_u64)                               # instr 2: r3 = NC u64
    put_u64(3, bm_u64)                               # instr 4: r5 = bitmask u64
    code[starts[4] + 2] = bm_off & 0xFF              # instr 5 (BM store): patch the BM_OFF byte

    print(f"CODE_BASE     : 0x{code_base:x}")
    print(f"INIT_CODE_LEN : {L0}")
    print(f"GROWN_CODE_LEN: {L1}")
    print(f"NC_START      : {nc_start}")
    print(f"NC_BASE       : 0x{nc_base:x}")
    print(f"BM_DEST       : 0x{bm_dest:x}  (off {bm_off} from NC_BASE)")
    print(f"RESERVE_END   : {reserve_end}")
    print(f"NC_U64        : 0x{nc_u64:016x}")
    print(f"BM_U64        : 0x{bm_u64:016x}  bytes={[f'0x{b:02x}' for b in bm_bytes]}")
    print(f"appender starts : {starts}")
    print(f"all starts (L1) : {all_starts}")
    return code, starts


def build_image(code, starts, jumptable=None, z=1):
    """Pad code to align16, append the LSB-first opcode bitmask, then (optionally)
    the dynamic jump table (z bytes/entry, LE). Returns (img, code_len, bm_off, jt_off)."""
    code_len = len(code)
    bm_off = (code_len + 15) & ~15            # align16(code_len)
    bm_len = (code_len + 7) // 8              # ceil(code_len/8)
    bitmask = [0] * bm_len
    for s in starts:
        bitmask[s // 8] |= 1 << (s % 8)

    img = list(code)
    img += [0] * (bm_off - code_len)          # pad gap between code and bitmask
    img += bitmask
    jt_off = len(img)
    if jumptable:
        for entry in jumptable:
            img += [(entry >> (8 * i)) & 0xFF for i in range(z)]   # z-byte LE entry
    return img, code_len, bm_off, jt_off


def write_hex(path, img):
    with open(path, "w") as f:
        f.write("@00000000\n")
        for b in img:
            f.write(f"{b:02x}\n")


def write_blob(path, sym, img):
    """Emit the PVM image as a .byte array for the DRAM demand-fetch path: the image lives in
    DRAM as the loader's .text.init data (code_base/jumptable_base point into it), NOT in img_bram
    via +PVM_IMG. 16-aligned, and padded to 64B so the demand-fetch code/bitmask/jump-table window
    reads (which fetch 16-aligned 32-byte spans) stay within defined data."""
    with open(path, "w") as f:
        f.write("# Auto-generated by gen_pvm_img.py for the DRAM demand-fetch path. Do not edit.\n")
        f.write(f"    .balign 16\n    .globl {sym}\n{sym}:\n")
        for i in range(0, len(img), 12):
            row = ", ".join(f"0x{b:02x}" for b in img[i : i + 12])
            f.write(f"    .byte {row}\n")
        pad = (64 - (len(img) % 64)) % 64
        if pad:
            f.write(f"    .zero {pad}\n")


def _parse_idx_z(text):
    """Parse the generator's text arg as the JT index and (optional) entry size: "idx" or "idx,z".
    z>1 widens jump-table entries (real OpenSBI emit-image uses z=3); default idx=0, z=1."""
    t = text.strip()
    if "," in t:
        a, b = t.split(",", 1)
        return (int(a) if a.strip().lstrip("-").isdigit() else 0,
                int(b) if b.strip().isdigit() else 1)
    return (int(t) if t.lstrip("-").isdigit() else 0, 1)


def main():
    text = sys.argv[1] if len(sys.argv) > 1 else "PolkaVM on CVA6!\n"
    out  = sys.argv[2] if len(sys.argv) > 2 else "banner.hex"
    mode = sys.argv[3] if len(sys.argv) > 3 else "mmio"  # mmio|ecalli|br_taken|br_nottaken|loop
    # allow \n etc. from the shell-literal default / argv
    text = text.encode().decode("unicode_escape")

    jumptable, z = None, 1
    if mode == "ecalli":
        code, starts = emit_ecalli_banner(text)
    elif mode == "br_taken":
        code, starts = emit_branch_test(True)
    elif mode == "br_nottaken":
        code, starts = emit_branch_test(False)
    elif mode == "loop":
        code, starts = emit_loop_test(int(text) if text.strip().isdigit() else 3)
    elif mode == "djump_halt":
        code, starts = emit_djump_halt()
    elif mode == "djump_table":
        _idx, _z = _parse_idx_z(text)
        code, starts, jumptable, z = emit_djump_table(_idx, _z)
    elif mode == "ibr_taken":
        code, starts = emit_imm_branch_test(True)
    elif mode == "ibr_nottaken":
        code, starts = emit_imm_branch_test(False)
    elif mode == "ibrx":
        op, rv, xv = (int(t, 0) for t in text.split(","))   # "opcode,rval,X"
        code, starts = emit_imm_branch(op, rv, xv)
    elif mode == "ldij":
        code, starts, jumptable, z = emit_ldij_test()
    elif mode == "csr":
        code, starts = emit_csr_test()
    elif mode == "csri":
        code, starts = emit_csri_test()
    elif mode == "irq":
        code, starts = emit_irq_test()
    elif mode == "mtvec":
        code, starts = emit_mtvec_test()
    elif mode == "mret":
        code, starts = emit_mret_test()
    elif mode == "handoff":
        _idx, _z = _parse_idx_z(text)
        code, starts, jumptable, z = emit_handoff_test(_idx, _z)
    elif mode == "handoff_clobber":
        code, starts, jumptable, z = emit_handoff_clobber(int(text) if text.strip().isdigit() else 0)
    elif mode == "handoff_satp":
        _idx, _z = _parse_idx_z(text)
        code, starts, jumptable, z = emit_handoff_satp(_idx, _z)
    elif mode == "handoff_djump_eret":
        _idx, _z = _parse_idx_z(text)
        code, starts, jumptable, z = emit_handoff_djump_eret(_idx, _z)
    elif mode == "handoff_rearm":
        code, starts, jumptable, z = emit_handoff_rearm(int(text) if text.strip().isdigit() else 0)
    elif mode == "handoff_smode":
        code, starts, jumptable, z = emit_handoff_smode(int(text) if text.strip().isdigit() else 0)
    elif mode == "handoff_smode_dyn":
        code, starts, jumptable, z = emit_handoff_smode_dyn(int(text) if text.strip().isdigit() else 0)
    elif mode == "handoff_skip":
        code, starts, jumptable, z = emit_handoff_skip(int(text) if text.strip().isdigit() else 0)
    elif mode == "trap_jt":
        code, starts, jumptable, z = emit_trap_jt(int(text) if text.strip().isdigit() else 0)
    elif mode == "handoff_trap_jt":
        # text = "idx_e" or "idx_e,z": the eret JT index (idx_e), optional entry size z (real
        # OpenSBI emit-image uses z=3). The trap JT index is idx_e+2 (a distinct cold-miss line).
        _ie, _z = _parse_idx_z(text)
        code, starts, jumptable, z = emit_handoff_trap_jt(_ie, _ie + 2, _z)
    elif mode == "smode_loop":
        code, starts = emit_smode_loop(int(text) if text.strip().isdigit() else 5)
    elif mode == "smode_loop_jt":
        _idx, _z = _parse_idx_z(text)
        code, starts, jumptable, z = emit_smode_loop(5, jt_handoff=True, idx=_idx, z=_z)
    elif mode == "smode_sbi":
        code, starts = emit_smode_sbi(int(text) if text.strip().isdigit() else 5)
    elif mode == "priv":
        code, starts = emit_priv_test()
    elif mode == "priv_dyn":
        code, starts = emit_priv_dyn_test()
    elif mode == "priv_return":
        code, starts = emit_priv_return_test()
    elif mode == "strap_skip":
        code, starts = emit_strap_skip_test()
    elif mode == "hostcall":
        code, starts = emit_hostcall_test()
    elif mode == "storeimm":
        code, starts = emit_storeimm_test()
    elif mode == "ebreak_probe":
        code, starts = emit_ebreak_probe()
    elif mode == "codeappend":
        code, starts = emit_codeappend()
    else:
        code, starts = emit_banner(text)
    img, code_len, bm_off, jt_off = build_image(code, starts, jumptable, z)
    write_hex(out, img)

    # Optional 4th arg = a symbol name -> ALSO emit <out>_blob.S (the same image bytes as a
    # .byte array) for the DRAM demand-fetch path (run-*-dram gates). JT_OFF is the jump-table
    # byte offset within the blob; the loader sets jumptable_base = &blob + JT_OFF.
    if len(sys.argv) > 4:
        blob_sym  = sys.argv[4]
        blob_path = (out[:-4] if out.endswith(".hex") else out) + "_blob.S"
        write_blob(blob_path, blob_sym, img)
        print(f"JT_OFF    : {jt_off}")
        print(f"BLOB      : {blob_path} ({blob_sym})")

    print(f"mode      : {mode}")
    print(f"banner    : {text!r}")
    print(f"CODE_LEN  : {code_len}")
    print(f"bitmask@  : 0x{bm_off:x} ({bm_off})")
    if jumptable:
        print(f"JT_BASE   : {jt_off}")
        print(f"JT_Z      : {z}")
    print(f"img bytes : {len(img)}")
    print(f"starts    : {starts}")
    print(f"wrote     : {out}")


if __name__ == "__main__":
    main()
