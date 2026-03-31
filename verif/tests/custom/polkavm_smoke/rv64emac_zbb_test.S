# RV64EMAC + Zbb smoke test for CVA6 PolkaVM configuration
# Tests: M (mul/div), A (lr/sc, amo), C (compressed), Zbb (bit manipulation)
# All registers limited to x0-x15 (RV64E compliant)
#
# Each test section writes a test number to a3 before checks,
# so on failure we know which test failed.

.section .text.start
.globl _start
_start:

    # ===== M extension: multiply/divide =====

    # Test 1: MUL
    li   a3, 1
    li   a0, 7
    li   a1, 13
    mul  a2, a0, a1     # 7 * 13 = 91
    li   a4, 91
    bne  a2, a4, fail

    # Test 2: MULH (signed high multiply)
    li   a3, 2
    li   a0, -1         # 0xFFFFFFFFFFFFFFFF
    li   a1, 2
    mulh a2, a0, a1     # high 64 bits of (-1 * 2) = -1
    li   a4, -1
    bne  a2, a4, fail

    # Test 3: DIV
    li   a3, 3
    li   a0, 100
    li   a1, 7
    div  a2, a0, a1     # 100 / 7 = 14
    li   a4, 14
    bne  a2, a4, fail

    # Test 4: REM
    li   a3, 4
    li   a0, 100
    li   a1, 7
    rem  a2, a0, a1     # 100 % 7 = 2
    li   a4, 2
    bne  a2, a4, fail

    # Test 5: DIVW (32-bit divide)
    li   a3, 5
    li   a0, 200
    li   a1, 10
    divw a2, a0, a1     # 200 / 10 = 20
    li   a4, 20
    bne  a2, a4, fail

    # ===== A extension: atomics =====

    # Test 6: LR/SC pair (single-hart, should always succeed)
    li   a3, 6
    la   a0, scratch
    li   a1, 0x42
    sd   a1, 0(a0)      # scratch = 0x42
    lr.d a2, (a0)        # a2 = load-reserved from scratch
    li   a4, 0x42
    bne  a2, a4, fail    # should have read 0x42

    li   a3, 7
    li   a1, 0x99
    sc.d a5, a1, (a0)    # store-conditional 0x99 to scratch
    bnez a5, fail         # a5 should be 0 (success) on single-hart

    li   a3, 8
    ld   a2, 0(a0)       # verify scratch == 0x99
    li   a4, 0x99
    bne  a2, a4, fail

    # Test 9: AMOADD
    li   a3, 9
    la   a0, scratch
    li   a1, 10
    sd   a1, 0(a0)       # scratch = 10
    li   a1, 5
    amoadd.d a2, a1, (a0)  # a2 = old(10), scratch = 10+5=15
    li   a4, 10
    bne  a2, a4, fail

    li   a3, 10
    ld   a2, 0(a0)
    li   a4, 15
    bne  a2, a4, fail

    # ===== Zbb extension: basic bit manipulation =====

    # Test 11: CLZ (count leading zeros)
    li   a3, 11
    li   a0, 1           # 0x0000000000000001 -> 63 leading zeros
    # CLZ is in Zbb: .insn encoding or use the mnemonic if toolchain supports
    clz  a2, a0
    li   a4, 63
    bne  a2, a4, fail

    # Test 12: CTZ (count trailing zeros)
    li   a3, 12
    li   a0, 1
    slli a0, a0, 4       # a0 = 0x10 -> 4 trailing zeros
    ctz  a2, a0
    li   a4, 4
    bne  a2, a4, fail

    # Test 13: CPOP (population count)
    li   a3, 13
    li   a0, 0xFF        # 8 bits set
    cpop a2, a0
    li   a4, 8
    bne  a2, a4, fail

    # Test 14: MIN (signed minimum)
    li   a3, 14
    li   a0, 5
    li   a1, -3
    min  a2, a0, a1
    li   a4, -3
    bne  a2, a4, fail

    # Test 15: MAX (signed maximum)
    li   a3, 15
    li   a0, 5
    li   a1, -3
    max  a2, a0, a1
    li   a4, 5
    bne  a2, a4, fail

    # Test 16: ANDN (and-not)
    li   a3, 16           # a3 = test number (careful, reusing a3)
    li   a0, 0xFF
    li   a1, 0x0F
    andn a2, a0, a1       # a2 = a0 & ~a1 = 0xFF & 0xF0 = 0xF0
    li   a4, 0xF0
    bne  a2, a4, fail

    # Test 17: ORN (or-not)
    li   a3, 17
    li   a0, 0x00
    li   a1, 0x0F
    orn  a2, a0, a1       # a2 = a0 | ~a1 = 0x00 | 0xFFF...F0 = 0xFFF...F0
    li   a4, -16           # 0xFFFFFFFFFFFFFFF0
    bne  a2, a4, fail

    # Test 18: REV8 (byte-reverse)
    li   a3, 18
    li   a0, 0x0102       # just low bytes for simplicity
    slli a0, a0, 48       # a0 = 0x0102_0000_0000_0000
    rev8 a2, a0           # a2 = 0x0000_0000_0000_0201
    li   a4, 0x0201
    bne  a2, a4, fail

    # Test 19: ROL (rotate left)
    li   a3, 19
    li   a0, 1
    li   a1, 3
    rol  a2, a0, a1       # rotate 1 left by 3 = 8
    li   a4, 8
    bne  a2, a4, fail

    # Test 20: SEXT.B (sign-extend byte)
    li   a3, 20
    li   a0, 0x80         # negative byte
    sext.b a2, a0          # sign-extend to -128
    li   a4, -128
    bne  a2, a4, fail

    # Test 21: SEXT.H (sign-extend halfword)
    li   a3, 21
    li   a0, 0x8000       # negative halfword
    sext.h a2, a0          # sign-extend to -32768
    li   a4, -32768
    bne  a2, a4, fail

    # ===== C extension: compressed instructions =====
    # (Used implicitly throughout -- the assembler emits C-format
    #  instructions automatically for RV64C-eligible patterns.
    #  The fact that this test runs at all proves C extension works.)

    # Test 22: Explicit compressed-eligible sequence
    li   a3, 22
    c.li a0, 10           # compressed load immediate
    c.li a1, 20
    c.add a0, a1          # compressed add: a0 = 30
    li   a4, 30
    bne  a0, a4, fail

pass:
    li   a0, 1
    la   a1, tohost
    sd   a0, 0(a1)
1:  wfi
    j    1b

fail:
    # a3 contains the failing test number
    # Write (test_num << 1) | 1 to tohost to signal which test failed
    slli a3, a3, 1
    ori  a3, a3, 1
    la   a1, tohost
    sd   a3, 0(a1)
1:  wfi
    j    1b

.section .data
.align 3
scratch:  .dword 0
.globl tohost
tohost:   .dword 0
.globl fromhost
fromhost: .dword 0
