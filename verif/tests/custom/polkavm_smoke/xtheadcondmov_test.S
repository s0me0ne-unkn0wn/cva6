# Xtheadcondmov smoke test for CVA6 PolkaVM configuration
# Tests th.mveqz and th.mvnez instructions
#
# th.mveqz rd, rs1, rs2:  if (rs2 == 0) rd = rs1; else rd unchanged
# th.mvnez rd, rs1, rs2:  if (rs2 != 0) rd = rs1; else rd unchanged
#
# Encoding: R-type on CUSTOM-0 opcode (0x0b)
#   th.mveqz: funct7=0x20, funct3=0x1, opcode=0x0b
#   th.mvnez: funct7=0x21, funct3=0x1, opcode=0x0b
#
# Uses only x0-x15 (RV64E compliant). Writes to tohost on pass/fail.

# GAS macros for Xtheadcondmov (assembler doesn't know these)
.macro th.mveqz rd, rs1, rs2
    .insn r 0x0b, 0x1, 0x20, \rd, \rs1, \rs2
.endm

.macro th.mvnez rd, rs1, rs2
    .insn r 0x0b, 0x1, 0x21, \rd, \rs1, \rs2
.endm

.section .text.start
.globl _start
_start:
    # -------------------------------------------------------
    # Test 1: th.mveqz with rs2 == 0 (condition TRUE -> move)
    # -------------------------------------------------------
    li   a0, 0xDEAD       # a0 = rd (old value)
    li   a1, 0xBEEF       # a1 = rs1 (value to move)
    li   a2, 0             # a2 = rs2 (condition = 0)
    th.mveqz a0, a1, a2   # rs2==0, so a0 should become 0xBEEF
    li   a3, 0xBEEF
    bne  a0, a3, fail

    # -------------------------------------------------------
    # Test 2: th.mveqz with rs2 != 0 (condition FALSE -> no move)
    # -------------------------------------------------------
    li   a0, 0xDEAD       # a0 = rd (old value)
    li   a1, 0xBEEF       # a1 = rs1
    li   a2, 1             # a2 = rs2 (condition != 0)
    th.mveqz a0, a1, a2   # rs2!=0, so a0 should stay 0xDEAD
    li   a3, 0xDEAD
    bne  a0, a3, fail

    # -------------------------------------------------------
    # Test 3: th.mvnez with rs2 != 0 (condition TRUE -> move)
    # -------------------------------------------------------
    li   a0, 0xDEAD       # a0 = rd (old value)
    li   a1, 0xCAFE       # a1 = rs1 (value to move)
    li   a2, 42            # a2 = rs2 (condition != 0)
    th.mvnez a0, a1, a2   # rs2!=0, so a0 should become 0xCAFE
    li   a3, 0xCAFE
    bne  a0, a3, fail

    # -------------------------------------------------------
    # Test 4: th.mvnez with rs2 == 0 (condition FALSE -> no move)
    # -------------------------------------------------------
    li   a0, 0xDEAD       # a0 = rd (old value)
    li   a1, 0xCAFE       # a1 = rs1
    li   a2, 0             # a2 = rs2 (condition == 0)
    th.mvnez a0, a1, a2   # rs2==0, so a0 should stay 0xDEAD
    li   a3, 0xDEAD
    bne  a0, a3, fail

    # -------------------------------------------------------
    # Test 5: th.mveqz with rd == rs1 (self-move when cond true)
    # -------------------------------------------------------
    li   a0, 0x1111
    li   a2, 0
    th.mveqz a0, a0, a2   # a0 = a0 (no change, self-move)
    li   a3, 0x1111
    bne  a0, a3, fail

    # -------------------------------------------------------
    # Test 6: th.mveqz with rd == rs2 (condition reg = dest)
    # -------------------------------------------------------
    li   a0, 0             # a0 = rd = rs2 = 0 (condition true)
    li   a1, 0x2222
    th.mveqz a0, a1, a0   # rs2(a0)==0, so a0 should become 0x2222
    li   a3, 0x2222
    bne  a0, a3, fail

    # -------------------------------------------------------
    # Test 7: th.mvnez with large 64-bit value
    # -------------------------------------------------------
    li   a0, 0
    li   a1, -1            # a1 = 0xFFFFFFFFFFFFFFFF
    li   a2, 1
    th.mvnez a0, a1, a2   # rs2!=0, a0 should become -1
    li   a3, -1
    bne  a0, a3, fail

    # -------------------------------------------------------
    # Test 8: th.mveqz with rs2 having only high bits set
    # -------------------------------------------------------
    li   a0, 0xAAAA        # old value
    li   a1, 0xBBBB        # new value
    li   a2, 1
    slli a2, a2, 63        # a2 = 0x8000000000000000 (high bit only)
    th.mveqz a0, a1, a2   # rs2 != 0, so a0 stays 0xAAAA
    li   a3, 0xAAAA
    bne  a0, a3, fail

pass:
    # Write 1 to tohost (test passed)
    li   a0, 1
    la   a1, tohost
    sd   a0, 0(a1)
1:  wfi
    j    1b

fail:
    # Write 0 to tohost (test failed)
    li   a0, 0
    la   a1, tohost
    sd   a0, 0(a1)
1:  wfi
    j    1b

.section .data
.align 3
.globl tohost
tohost:  .dword 0
.globl fromhost
fromhost: .dword 0
