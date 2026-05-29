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
