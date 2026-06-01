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


def emit_djump_table():
    """jump_ind through the jump table: load_imm r2,2 ; jump_ind r2 -> j[0] = TARGET.
    djump(2): index = 2/2-1 = 0 -> target = jumptable[0]. Prints 'J' then traps.
    Returns (code, starts, jumptable_bytes, z). The image builder appends the table
    after the bitmask; CFG2 = jumptable_base | (z<<32)."""
    code = (
        [LOAD_IMM, 0x02, 2]            # load_imm r2, 2 (djump addr -> index 0) @0 (3B)
        + [JUMP_IND, 0x02]             # jump_ind r2                            @3 (2B)
        + [TRAP]                       # (error catch: djump must skip this)    @5 (1B)
        + [LOAD_IMM, 0x07, ord('J')]   # TARGET: load_imm r7, 'J'               @6 (3B)
        + [ECALLI, 0x00]               # ecalli (putchar 'J')                   @9 (2B)
        + [TRAP]                       # trap                                   @11(1B)
    )
    starts = [0, 3, 5, 6, 9, 11]
    z = 1
    jumptable = [6]                    # j[0] = TARGET pc (6)
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


# Privileged CSR opcodes (231-236): reg_reg_imm. byte1 = (rd<<4)|rs1 nibbles (PVM
# rN -> RISC-V x(N+1)), then the csr-number immediate (LE). csr_rw: rd=old csr,
# csr=rs1. csr_rs: rd=old csr, csr|=rs1. csr_rc: rd=old csr, csr&=~rs1.
CSR_RW   = 0xE7   # 231
CSR_RS   = 0xE8   # 232
CSR_RC   = 0xE9   # 233
MSCRATCH = 0x340  # an M-mode CSR unused by the loader -> safe to clobber from PVM
MTVEC    = 0x305  # M-mode trap vector: the guest clobbers it to prove the B4 PVM-exit decouple
MEPC     = 0x341  # M-mode exception PC: mret redirects PVM fetch here (writing it sets no flush)
MSTATUS  = 0x300  # M-mode status (MPP etc.); written by the HOST loader, not the guest (flush)


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
    def b1(rd, rs1):                          # nibbles: hi = rd PVM idx, lo = rs1 PVM idx
        return ((rd & 0xF) << 4) | (rs1 & 0xF)
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
        return ((rd & 0xF) << 4) | (rs1 & 0xF)
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
        return ((rd & 0xF) << 4) | (rs1 & 0xF)
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
        return ((rd & 0xF) << 4) | (rs1 & 0xF)
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
        code, starts, jumptable, z = emit_djump_table()
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
    elif mode == "mtvec":
        code, starts = emit_mtvec_test()
    elif mode == "mret":
        code, starts = emit_mret_test()
    elif mode == "priv":
        code, starts = emit_priv_test()
    elif mode == "hostcall":
        code, starts = emit_hostcall_test()
    else:
        code, starts = emit_banner(text)
    img, code_len, bm_off, jt_off = build_image(code, starts, jumptable, z)
    write_hex(out, img)

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
