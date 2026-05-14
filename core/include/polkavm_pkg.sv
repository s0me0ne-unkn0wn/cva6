// PolkaVM JAM v1 native-ISA package for CVA6.
// Mirrors `polkavm-common/src/program.rs` (fetched 2026-04-29).
// Source-of-truth: ISA_JamV1 macro at lines 2274-2445.
//
// Phase 4 sub-phase 1: foundation package, no module dependencies.
// Used by: pvm_decoder.sv (sub-phase 3+), pvm_csr_regfile.sv (sub-phase 2+),
//          pvm_alu.sv (sub-phase 5+), pvm_frontend.sv (sub-phase 4+).
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

package polkavm_pkg;

  // ---------------------------------------------------------------------------
  // Common parameters
  // ---------------------------------------------------------------------------

  // Register address width: 4 bits for 13 PVM regs (indices 0..12) plus 3
  // illegal slots (13..15) that trigger the illegal-register trap (ADR-4).
  localparam PVM_REG_ADDR_WIDTH = 4;

  // Canonical PVM register count (RA, SP, T0-T2, S0-S1, A0-A5).
  localparam PVM_REG_COUNT = 13;

  // Opcode width: 1 byte per graypaper §pvm:81.
  localparam PVM_OP_WIDTH = 8;

  // Maximum instruction length in bytes per graypaper §pvm:99.
  localparam PVM_INSTR_MAX_BYTES = 16;

  // Page size per graypaper §pvm:177 (Cpvmpagesize = 4096).
  // Relevant for Phase 5 page-fault model; declared here for completeness.
  localparam PVM_PAGE_SIZE = 4096;

  // Low-inaccessible region per ADR-3:
  //   panic if (addr mod 2^32) < 2^16
  localparam logic [15:0] PVM_LOW_INACCESSIBLE_LIMIT = 16'h0000;
  localparam logic [31:0] PVM_LOW_INACCESSIBLE_MOD   = 32'h0001_0000;

  // Sentinel immediate values for ecalli (ADR-5).
  // ecalli imm=0xFFFFFFFF → mode_return (S→U).
  // ecalli imm=0xFFFFFFFE → read_csr (S-mode only).
  // ecalli imm=0xFFFFFFFD → write_csr (reserved, Phase 5).
  // All imm >= 0xFFFFFFFD are reserved for HW use.
  localparam logic [31:0] PVM_ECALLI_SENTINEL_MODE_RETURN = 32'hFFFF_FFFF;
  localparam logic [31:0] PVM_ECALLI_SENTINEL_READ_CSR    = 32'hFFFF_FFFE;
  localparam logic [31:0] PVM_ECALLI_SENTINEL_WRITE_CSR   = 32'hFFFF_FFFD;

  // PolkaVM blob magic: byte 4 of a .polkavm JAM v1 blob = 0x03.
  // Confirmed by sub-phase 0 toolchain smoke test.
  localparam logic [7:0] PVM_BLOB_VERSION_JAMV1 = 8'h03;

  // ---------------------------------------------------------------------------
  // pvm_op_t — JAM v1 opcode enum
  // ---------------------------------------------------------------------------
  // Values EXACTLY match `ISA_JamV1` in polkavm-common/src/program.rs:2274-2445.
  // Opcodes not listed here are undefined in JamV1 and are treated as illegal
  // by the decoder (trap path), matching the Rust interpreter behaviour.
  //
  // NOTE on `sbrk`: opcode 101 in JamV1 is `count_set_bits_64`, NOT `sbrk`.
  // `sbrk=101` appears only in ISA_Latest64 (line 2254). Do NOT add sbrk here.
  //
  // NOTE on `_alt` shift variants: the "imm_alt" opcodes (e.g.
  // shift_logical_left_imm_alt_32 = 144) swap the operand position relative
  // to the non-alt form (shift_logical_left_imm_32 = 138): in the alt form,
  // the immediate provides the *value* and the register provides the *shift
  // amount*, instead of the usual (register=value, immediate=shift-amount).
  // The decoder must account for this operand swap.
  //
  // Instruction-format group membership (from ISA_JamV1 macro bracket order):
  //   Group 1  no_args              [0]    : trap, fallthrough, unlikely
  //   Group 2  reg_imm              [50]   : jump_indirect, load_imm,
  //                                          load_{u8,i8,u16,i16,i32,u32,u64},
  //                                          store_{u8,u16,u32,u64}
  //   Group 3  reg_imm_offset       [80]   : load_imm_and_jump,
  //                                          branch_{eq,not_eq,less_unsigned,
  //                                          less_signed,greater_or_equal_unsigned,
  //                                          greater_or_equal_signed,
  //                                          less_or_equal_signed,
  //                                          less_or_equal_unsigned,
  //                                          greater_signed,greater_unsigned}_imm
  //   Group 4  store_imm_indirect   [70]   : store_imm_indirect_{u8,u16,u32,u64}
  //   Group 5  reg_reg_imm          [120]  : store_indirect_{u8,u16,u32,u64},
  //                                          load_indirect_{u8,i8,u16,i16,i32,u32,u64},
  //                                          add_imm_{32,64}, and_imm, xor_imm,
  //                                          or_imm, mul_imm_{32,64},
  //                                          set_less_than_{unsigned,signed}_imm,
  //                                          shift_logical_{left,right}_imm_{32,64},
  //                                          shift_arithmetic_right_imm_{32,64},
  //                                          negate_and_add_imm_{32,64},
  //                                          set_greater_than_{unsigned,signed}_imm,
  //                                          shift_logical_{right,left}_imm_alt_{32,64},
  //                                          shift_arithmetic_right_imm_alt_{32,64},
  //                                          cmov_if_{zero,not_zero}_imm,
  //                                          rotate_right_imm_{32,64},
  //                                          rotate_right_imm_alt_{32,64}
  //   Group 6  reg_reg_offset       [170]  : branch_{eq,not_eq,less_unsigned,
  //                                          less_signed,greater_or_equal_unsigned,
  //                                          greater_or_equal_signed}
  //   Group 7  reg_reg_reg          [190]  : add_{32,64}, sub_{32,64}, and, xor,
  //                                          or, mul_{32,64},
  //                                          mul_upper_{signed_signed,
  //                                          unsigned_unsigned,signed_unsigned},
  //                                          set_less_than_{unsigned,signed},
  //                                          shift_logical_{left,right}_{32,64},
  //                                          shift_arithmetic_right_{32,64},
  //                                          div_{unsigned,signed}_{32,64},
  //                                          rem_{unsigned,signed}_{32,64},
  //                                          cmov_if_{zero,not_zero},
  //                                          and_inverted, or_inverted, xnor,
  //                                          maximum, maximum_unsigned,
  //                                          minimum, minimum_unsigned,
  //                                          rotate_{left,right}_{32,64}
  //   Group 8  offset               [40]   : jump
  //   Group 9  imm                  [10]   : ecalli
  //   Group 10 imm_imm              [30]   : store_imm_{u8,u16,u32,u64}
  //   Group 11 reg_reg              [100]  : move_reg,
  //                                          count_leading_zero_bits_{32,64},
  //                                          count_trailing_zero_bits_{32,64},
  //                                          count_set_bits_{32,64},
  //                                          sign_extend_{8,16}, zero_extend_16,
  //                                          reverse_byte
  //   Group 12 reg_imm_imm          [180]  : load_imm_and_jump_indirect
  //   Group 13 reg_imm64            [20]   : load_imm64
  //
  typedef enum logic [7:0] {
    // -------------------------------------------------------------------------
    // Group 1: no_args — opcodes with no operands
    // -------------------------------------------------------------------------
    PVM_OP_TRAP                                   = 8'd0,
    PVM_OP_FALLTHROUGH                            = 8'd1,
    PVM_OP_UNLIKELY                               = 8'd2,

    // -------------------------------------------------------------------------
    // Group 9: imm — single immediate operand
    // -------------------------------------------------------------------------
    PVM_OP_ECALLI                                 = 8'd10,

    // -------------------------------------------------------------------------
    // Group 13: reg_imm64 — register + 64-bit immediate
    // -------------------------------------------------------------------------
    PVM_OP_LOAD_IMM64                             = 8'd20,

    // -------------------------------------------------------------------------
    // Group 10: imm_imm — two immediates (address + value)
    // -------------------------------------------------------------------------
    PVM_OP_STORE_IMM_U8                           = 8'd30,
    PVM_OP_STORE_IMM_U16                          = 8'd31,
    PVM_OP_STORE_IMM_U32                          = 8'd32,
    PVM_OP_STORE_IMM_U64                          = 8'd33,

    // -------------------------------------------------------------------------
    // Group 8: offset — single PC-relative offset
    // -------------------------------------------------------------------------
    PVM_OP_JUMP                                   = 8'd40,

    // -------------------------------------------------------------------------
    // Group 2: reg_imm — register + immediate
    //   (includes loads and stores to absolute address)
    // -------------------------------------------------------------------------
    PVM_OP_JUMP_INDIRECT                          = 8'd50,
    PVM_OP_LOAD_IMM                               = 8'd51,
    PVM_OP_LOAD_U8                                = 8'd52,
    PVM_OP_LOAD_I8                                = 8'd53,
    PVM_OP_LOAD_U16                               = 8'd54,
    PVM_OP_LOAD_I16                               = 8'd55,
    PVM_OP_LOAD_U32                               = 8'd56,  // NOTE: 56 not 57
    PVM_OP_LOAD_I32                               = 8'd57,
    PVM_OP_LOAD_U64                               = 8'd58,
    PVM_OP_STORE_U8                               = 8'd59,
    PVM_OP_STORE_U16                              = 8'd60,
    PVM_OP_STORE_U32                              = 8'd61,
    PVM_OP_STORE_U64                              = 8'd62,

    // -------------------------------------------------------------------------
    // Group 4: store_imm_indirect — base register + imm offset + imm value
    // -------------------------------------------------------------------------
    PVM_OP_STORE_IMM_INDIRECT_U8                  = 8'd70,
    PVM_OP_STORE_IMM_INDIRECT_U16                 = 8'd71,
    PVM_OP_STORE_IMM_INDIRECT_U32                 = 8'd72,
    PVM_OP_STORE_IMM_INDIRECT_U64                 = 8'd73,

    // -------------------------------------------------------------------------
    // Group 3: reg_imm_offset — register + immediate + PC-relative offset
    //   (load_imm_and_jump + all conditional branches with immediate comparand)
    // -------------------------------------------------------------------------
    PVM_OP_LOAD_IMM_AND_JUMP                      = 8'd80,
    PVM_OP_BRANCH_EQ_IMM                          = 8'd81,
    PVM_OP_BRANCH_NOT_EQ_IMM                      = 8'd82,
    PVM_OP_BRANCH_LESS_UNSIGNED_IMM               = 8'd83,
    PVM_OP_BRANCH_LESS_OR_EQUAL_UNSIGNED_IMM      = 8'd84,
    PVM_OP_BRANCH_GREATER_OR_EQUAL_UNSIGNED_IMM   = 8'd85,
    PVM_OP_BRANCH_GREATER_UNSIGNED_IMM            = 8'd86,
    PVM_OP_BRANCH_LESS_SIGNED_IMM                 = 8'd87,
    PVM_OP_BRANCH_LESS_OR_EQUAL_SIGNED_IMM        = 8'd88,
    PVM_OP_BRANCH_GREATER_OR_EQUAL_SIGNED_IMM     = 8'd89,
    PVM_OP_BRANCH_GREATER_SIGNED_IMM              = 8'd90,

    // -------------------------------------------------------------------------
    // Group 11: reg_reg — two registers (unary ops on one reg, dst = separate)
    // -------------------------------------------------------------------------
    PVM_OP_MOVE_REG                               = 8'd100,
    PVM_OP_COUNT_SET_BITS_32                      = 8'd102,
    PVM_OP_COUNT_SET_BITS_64                      = 8'd101,  // popcount64; NOT sbrk
    PVM_OP_COUNT_LEADING_ZERO_BITS_64             = 8'd103,
    PVM_OP_COUNT_LEADING_ZERO_BITS_32             = 8'd104,
    PVM_OP_COUNT_TRAILING_ZERO_BITS_64            = 8'd105,
    PVM_OP_COUNT_TRAILING_ZERO_BITS_32            = 8'd106,
    PVM_OP_SIGN_EXTEND_8                          = 8'd107,
    PVM_OP_SIGN_EXTEND_16                         = 8'd108,
    PVM_OP_ZERO_EXTEND_16                         = 8'd109,
    PVM_OP_REVERSE_BYTE                           = 8'd110,

    // -------------------------------------------------------------------------
    // Group 5: reg_reg_imm — dst + src + immediate
    //   (reg-reg stores, reg-reg loads with offset, ALU-with-immediate)
    // -------------------------------------------------------------------------
    PVM_OP_STORE_INDIRECT_U8                      = 8'd120,
    PVM_OP_STORE_INDIRECT_U16                     = 8'd121,
    PVM_OP_STORE_INDIRECT_U32                     = 8'd122,
    PVM_OP_STORE_INDIRECT_U64                     = 8'd123,
    PVM_OP_LOAD_INDIRECT_U8                       = 8'd124,
    PVM_OP_LOAD_INDIRECT_I8                       = 8'd125,
    PVM_OP_LOAD_INDIRECT_U16                      = 8'd126,
    PVM_OP_LOAD_INDIRECT_I16                      = 8'd127,
    PVM_OP_LOAD_INDIRECT_U32                      = 8'd128,  // NOTE: 128 not 129
    PVM_OP_LOAD_INDIRECT_I32                      = 8'd129,
    PVM_OP_LOAD_INDIRECT_U64                      = 8'd130,
    PVM_OP_ADD_IMM_32                             = 8'd131,
    PVM_OP_AND_IMM                                = 8'd132,
    PVM_OP_XOR_IMM                                = 8'd133,
    PVM_OP_OR_IMM                                 = 8'd134,
    PVM_OP_MUL_IMM_32                             = 8'd135,
    PVM_OP_SET_LESS_THAN_UNSIGNED_IMM             = 8'd136,
    PVM_OP_SET_LESS_THAN_SIGNED_IMM               = 8'd137,
    PVM_OP_SHIFT_LOGICAL_LEFT_IMM_32              = 8'd138,
    PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_32             = 8'd139,
    PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_32          = 8'd140,
    PVM_OP_NEGATE_AND_ADD_IMM_32                  = 8'd141,
    PVM_OP_SET_GREATER_THAN_UNSIGNED_IMM          = 8'd142,
    PVM_OP_SET_GREATER_THAN_SIGNED_IMM            = 8'd143,
    // Alt shift variants: operands swapped vs non-alt form.
    // Non-alt: rd = rs op imm  (register=value, immediate=shift-amount).
    // Alt:     rd = imm op rs  (immediate=value, register=shift-amount).
    PVM_OP_SHIFT_LOGICAL_LEFT_IMM_ALT_32          = 8'd144,
    PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_ALT_32         = 8'd145,
    PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_ALT_32      = 8'd146,
    PVM_OP_CMOV_IF_ZERO_IMM                       = 8'd147,
    PVM_OP_CMOV_IF_NOT_ZERO_IMM                   = 8'd148,
    PVM_OP_ADD_IMM_64                             = 8'd149,
    PVM_OP_MUL_IMM_64                             = 8'd150,
    PVM_OP_SHIFT_LOGICAL_LEFT_IMM_64              = 8'd151,
    PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_64             = 8'd152,
    PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_64          = 8'd153,
    PVM_OP_NEGATE_AND_ADD_IMM_64                  = 8'd154,
    PVM_OP_SHIFT_LOGICAL_LEFT_IMM_ALT_64          = 8'd155,
    PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_ALT_64         = 8'd156,
    PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_ALT_64      = 8'd157,
    PVM_OP_ROTATE_RIGHT_IMM_64                    = 8'd158,
    PVM_OP_ROTATE_RIGHT_IMM_ALT_64               = 8'd159,
    PVM_OP_ROTATE_RIGHT_IMM_32                    = 8'd160,
    PVM_OP_ROTATE_RIGHT_IMM_ALT_32               = 8'd161,

    // -------------------------------------------------------------------------
    // Group 6: reg_reg_offset — two registers + PC-relative offset
    //   (conditional branches comparing two registers)
    // -------------------------------------------------------------------------
    PVM_OP_BRANCH_EQ                              = 8'd170,
    PVM_OP_BRANCH_NOT_EQ                          = 8'd171,
    PVM_OP_BRANCH_LESS_UNSIGNED                   = 8'd172,
    PVM_OP_BRANCH_LESS_SIGNED                     = 8'd173,
    PVM_OP_BRANCH_GREATER_OR_EQUAL_UNSIGNED       = 8'd174,
    PVM_OP_BRANCH_GREATER_OR_EQUAL_SIGNED         = 8'd175,

    // -------------------------------------------------------------------------
    // Group 12: reg_imm_imm — register + base-imm + destination-imm
    // -------------------------------------------------------------------------
    PVM_OP_LOAD_IMM_AND_JUMP_INDIRECT             = 8'd180,

    // -------------------------------------------------------------------------
    // Group 7: reg_reg_reg — three registers (standard ALU)
    // -------------------------------------------------------------------------
    PVM_OP_ADD_32                                 = 8'd190,
    PVM_OP_SUB_32                                 = 8'd191,
    PVM_OP_MUL_32                                 = 8'd192,
    PVM_OP_DIV_UNSIGNED_32                        = 8'd193,
    PVM_OP_DIV_SIGNED_32                          = 8'd194,
    PVM_OP_REM_UNSIGNED_32                        = 8'd195,
    PVM_OP_REM_SIGNED_32                          = 8'd196,
    PVM_OP_SHIFT_LOGICAL_LEFT_32                  = 8'd197,
    PVM_OP_SHIFT_LOGICAL_RIGHT_32                 = 8'd198,
    PVM_OP_SHIFT_ARITHMETIC_RIGHT_32              = 8'd199,
    PVM_OP_ADD_64                                 = 8'd200,
    PVM_OP_SUB_64                                 = 8'd201,
    PVM_OP_MUL_64                                 = 8'd202,
    PVM_OP_DIV_UNSIGNED_64                        = 8'd203,
    PVM_OP_DIV_SIGNED_64                          = 8'd204,
    PVM_OP_REM_UNSIGNED_64                        = 8'd205,
    PVM_OP_REM_SIGNED_64                          = 8'd206,
    PVM_OP_SHIFT_LOGICAL_LEFT_64                  = 8'd207,
    PVM_OP_SHIFT_LOGICAL_RIGHT_64                 = 8'd208,
    PVM_OP_SHIFT_ARITHMETIC_RIGHT_64              = 8'd209,
    PVM_OP_AND                                    = 8'd210,
    PVM_OP_XOR                                    = 8'd211,
    PVM_OP_OR                                     = 8'd212,
    PVM_OP_MUL_UPPER_SIGNED_SIGNED               = 8'd213,
    PVM_OP_MUL_UPPER_UNSIGNED_UNSIGNED            = 8'd214,
    PVM_OP_MUL_UPPER_SIGNED_UNSIGNED              = 8'd215,
    PVM_OP_SET_LESS_THAN_UNSIGNED                 = 8'd216,
    PVM_OP_SET_LESS_THAN_SIGNED                   = 8'd217,
    PVM_OP_CMOV_IF_ZERO                           = 8'd218,
    PVM_OP_CMOV_IF_NOT_ZERO                       = 8'd219,
    PVM_OP_ROTATE_LEFT_64                         = 8'd220,
    PVM_OP_ROTATE_LEFT_32                         = 8'd221,
    PVM_OP_ROTATE_RIGHT_64                        = 8'd222,
    PVM_OP_ROTATE_RIGHT_32                        = 8'd223,
    PVM_OP_AND_INVERTED                           = 8'd224,
    PVM_OP_OR_INVERTED                            = 8'd225,
    PVM_OP_XNOR                                   = 8'd226,
    PVM_OP_MAXIMUM                                = 8'd227,
    PVM_OP_MAXIMUM_UNSIGNED                       = 8'd228,
    PVM_OP_MINIMUM                                = 8'd229,
    PVM_OP_MINIMUM_UNSIGNED                       = 8'd230
  } pvm_op_t;

  // ---------------------------------------------------------------------------
  // pvm_reg_t — canonical PVM register indices
  // ---------------------------------------------------------------------------
  // Values are taken from `Reg::from_raw()` in polkavm-common/src/program.rs:107.
  // The mapping is:
  //   RA=0, SP=1, T0=2, T1=3, T2=4, S0=5, S1=6,
  //   A0=7, A1=8, A2=9, A3=10, A4=11, A5=12
  //
  // Indices 13..15 are NOT valid PVM registers. Any instruction that encodes
  // a register index of 13, 14, or 15 triggers an illegal-register trap
  // (ADR-4). Those values are represented by pvm_reg_invalid_t below.
  //
  // The enum is 4 bits wide (PVM_REG_ADDR_WIDTH) matching the existing
  // REG_ADDR_SIZE=4 in ariane_pkg.sv (Phase 3). Values 0..12 are valid;
  // values 13..15 are architecturally illegal.
  //
  typedef enum logic [3:0] {
    PVM_REG_RA = 4'd0,   // return address
    PVM_REG_SP = 4'd1,   // stack pointer
    PVM_REG_T0 = 4'd2,   // temporary 0
    PVM_REG_T1 = 4'd3,   // temporary 1
    PVM_REG_T2 = 4'd4,   // temporary 2
    PVM_REG_S0 = 4'd5,   // saved 0
    PVM_REG_S1 = 4'd6,   // saved 1
    PVM_REG_A0 = 4'd7,   // argument/return 0
    PVM_REG_A1 = 4'd8,   // argument/return 1
    PVM_REG_A2 = 4'd9,   // argument 2
    PVM_REG_A3 = 4'd10,  // argument 3
    PVM_REG_A4 = 4'd11,  // argument 4
    PVM_REG_A5 = 4'd12   // argument 5
  } pvm_reg_t;

  // Illegal register sentinel values (indices 13..15).
  // Any decoded register index in this range triggers an IllegalReg trap.
  // Not an enum to allow direct comparison with logic [3:0] decoded fields.
  localparam logic [3:0] PVM_REG_ILLEGAL_LO = 4'd13;
  localparam logic [3:0] PVM_REG_ILLEGAL_HI = 4'd15;

  // Helper function: returns 1 if the given 4-bit register index is illegal.
  function automatic logic pvm_reg_is_illegal(input logic [3:0] r);
    return (r >= PVM_REG_ILLEGAL_LO);
  endfunction

  // ---------------------------------------------------------------------------
  // pvm_csr_addr_t — PVM CSR address space (Phase 5 ADR-12 iter 3 relocation)
  // ---------------------------------------------------------------------------
  // CSR address assignment rationale (ADR-12, supersedes Phase 4 ADR-5):
  //   The Phase 4 mirror-RISC-V layout (0x300/0x304/0x305/0x341/0x342/0x343)
  //   is FORBIDDEN starting with Phase 5 because those addresses are reserved
  //   for restored RISC-V M-mode CSRs:
  //     mstatus=0x300, mie=0x304, mtvec=0x305, mepc=0x341, mcause=0x342,
  //     mtval=0x343 (all 6 collide; see riscv_pkg.sv:448-489). The Phase 4
  //     "repurpose the 0x300 range" rationale was correct under minimization
  //     but breaks once M-mode is added back for OpenSBI in Phase 5.
  //
  //   The 0x7C0-0x7FF "user/M-RW custom" range was REJECTED in iter 3 because
  //   CVA6 already declares CSR_ICACHE=12'h7C0, CSR_DCACHE=12'h7C1, and
  //   CSR_ACC_CONS=12'h7C2 (see riscv_pkg.sv:644-647) — the same silent-shadow
  //   failure mode that ADR-12 is meant to eliminate.
  //
  //   The 0xBC0-0xBFF "M-mode custom RW" range (RISC-V Privileged ISA Vol II
  //   Table 2.1) was CHOSEN — verified empty in CVA6 via
  //   `grep -E "12'h[Bb][Cc]" core/include/riscv_pkg.sv` returning 0 hits.
  //   Reserves 58 slots (0xBC6..0xBFF) for Phase 6 S-mode/MMU and future
  //   extensions, eliminating further relocation churn.
  //
  //   New mapping (ADR-12 iter 3):
  //     0xBC0 → pstatus            (was 0x300, collided with mstatus)
  //     0xBC1 → pepc               (was 0x341, collided with mepc)
  //     0xBC2 → pcause             (was 0x342, collided with mcause)
  //     0xBC3 → pgas               (was 0x343, collided with mtval; MVP=0)
  //     0xBC4 → pevent_table_base  (was 0x304, collided with mie)
  //     0xBC5 → pcycle             (was 0x305, collided with mtvec;
  //                                 bootrom/src/main.c:15 csrr-cycle subst.)
  //
  typedef enum logic [11:0] {
    PVM_CSR_PSTATUS           = 12'hBC0,  // PVM supervisor status register
    PVM_CSR_PEPC              = 12'hBC1,  // PVM exception program counter
    PVM_CSR_PCAUSE            = 12'hBC2,  // PVM exception cause code
    PVM_CSR_PGAS              = 12'hBC3,  // PVM gas remaining (MVP = 0)
    PVM_CSR_PEVENT_TABLE_BASE = 12'hBC4,  // ecalli handler table base pointer
    PVM_CSR_PCYCLE            = 12'hBC5   // cycle counter (bootrom compat.)
  } pvm_csr_addr_t;

  // ---------------------------------------------------------------------------
  // Phase 5 privileged-opcode csr_addr field encoding contract (ADR-1.1)
  // ---------------------------------------------------------------------------
  //   PVM_OP_CSR_RW / RS / RC and immediate variants (opcodes 231..236 — to be
  //   added in sub-phase 2.1) carry the 12-bit csr_addr in imm[11:0]:
  //     • Standard form (csrrw/csrrs/csrrc):
  //         rA = dst (4-bit reg id), rB = src1 (4-bit reg id),
  //         imm[11:0] = csr_addr
  //     • Immediate form (csrrwi/csrrsi/csrrci):
  //         rA = dst (4-bit reg id), rB = zimm[4:0] (only low 5 bits used —
  //         RV64E reg-field is 4 bits, so zimm > 15 is not encodable in this
  //         scheme; OpenSBI v1.7 emits NO immediate-form CSR ops with zimm>15
  //         per grep audit — confirmed by sub-phase 4.0 step 0),
  //         imm[11:0] = csr_addr
  //     • PVM_OP_MRET (237), PVM_OP_SRET (238), PVM_OP_WFI (239): no operands,
  //         no immediate
  //     • PVM_OP_SFENCE_VMA (240): rA = rs1, rB = rs2, no immediate
  //
  //   REJECTED alternative (iter 2): split csr_addr across imm[11:5] +
  //   imm[4:0] with zimm in imm[4:0] — encoding splits across fields,
  //   harder to decode; iter 3 keeps csr_addr in imm[11:0] contiguous.
  //
  function automatic logic [11:0] pvm_priv_csr_addr(input logic [63:0] imm);
    // Extracts the 12-bit csr_addr field from the immediate operand of a
    // PVM privileged CSR opcode (231..236). Defined here so both the decoder
    // and Verilator testbenches share one extraction point — preventing the
    // polkatool-emission / decoder-decode contract from diverging silently.
    return imm[11:0];
  endfunction

  // ---------------------------------------------------------------------------
  // pvm_exit_reason_t — PVM execution termination codes
  // ---------------------------------------------------------------------------
  // Mirrors the PVM halt/panic/oog/fault/host outcomes from graypaper §pvm:38.
  // Flattened to a single enum; the Host variant captures any ecalli-triggered
  // transfer (sub-phase 8 wires the precise semantics).
  //
  // `Continue`  — normal pipeline operation; no termination.
  // `Halt`      — graceful halt (trap opcode at end-of-program or explicit).
  // `Panic`     — unrecoverable error (illegal instruction, illegal register,
  //               memory fault, alignment violation, etc.).
  // `OutOfGas`  — gas exhausted; reserved for Phase 5 (ADR-2); unused in MVP.
  // `Fault`     — memory access violation outside permitted segments.
  // `Host`      — ecalli transferred control to host handler (S-mode).
  //
  typedef enum logic [2:0] {
    PVM_EXIT_CONTINUE   = 3'd0,
    PVM_EXIT_HALT       = 3'd1,
    PVM_EXIT_PANIC      = 3'd2,
    PVM_EXIT_OUT_OF_GAS = 3'd3,  // reserved; Phase 5
    PVM_EXIT_FAULT      = 3'd4,
    PVM_EXIT_HOST       = 3'd5
  } pvm_exit_reason_t;

  // ---------------------------------------------------------------------------
  // pvm_alu_op_e — PVM ALU operation selector (sub-phase 5)
  // ---------------------------------------------------------------------------
  // Used by pvm_alu_tb.sv and the ALU result mux to distinguish PVM-specific
  // ALU ops from the legacy ariane_pkg::fu_op set.  The ALU receives a
  // separate `is_pvm_op_i` flag alongside `fu_data_i.operation` (which carries
  // the fu_op enum).  When `is_pvm_op_i` is asserted the ALU result mux
  // instead selects on this enum, forwarded through a new `pvm_alu_op_i` port.
  //
  // Only pure-ALU PVM ops are listed here.  Load/store ops are handled by the
  // LSU (sub-phase 6).  Div/rem ops go through mult.sv.  CMOV variants use the
  // forwarding-network rs3 path per ADR-4.
  //
  typedef enum logic [5:0] {
    // -- 64-bit arithmetic ---------------------------------------------------
    PVM_ALU_ADD_64             = 6'd0,   // rd = rs1 + rs2                (64b)
    PVM_ALU_SUB_64             = 6'd1,   // rd = rs1 - rs2                (64b)
    PVM_ALU_MUL_64             = 6'd2,   // rd = (rs1 * rs2)[63:0]        (64b)
    PVM_ALU_ADD_IMM_64         = 6'd3,   // rd = rs1 + imm                (64b)
    PVM_ALU_MUL_IMM_64         = 6'd4,   // rd = (rs1 * imm)[63:0]        (64b)
    PVM_ALU_NEGATE_ADD_IMM_64  = 6'd5,   // rd = (-rs1) + imm             (64b)
    // -- 32-bit arithmetic (sign-extended to 64b) ----------------------------
    PVM_ALU_ADD_32             = 6'd6,   // rd = sext(rs1[31:0]+rs2[31:0])(32b)
    PVM_ALU_SUB_32             = 6'd7,   // rd = sext(rs1[31:0]-rs2[31:0])(32b)
    PVM_ALU_MUL_32             = 6'd8,   // rd = sext((rs1*rs2)[31:0])    (32b)
    PVM_ALU_ADD_IMM_32         = 6'd9,   // rd = sext((rs1+imm)[31:0])    (32b)
    PVM_ALU_MUL_IMM_32         = 6'd10,  // rd = sext((rs1*imm)[31:0])    (32b)
    PVM_ALU_NEGATE_ADD_IMM_32  = 6'd11,  // rd = sext((-rs1+imm)[31:0])   (32b)
    // -- Bitwise logic -------------------------------------------------------
    PVM_ALU_AND                = 6'd12,  // rd = rs1 & rs2
    PVM_ALU_OR                 = 6'd13,  // rd = rs1 | rs2
    PVM_ALU_XOR                = 6'd14,  // rd = rs1 ^ rs2
    PVM_ALU_AND_IMM            = 6'd15,  // rd = rs1 & imm
    PVM_ALU_OR_IMM             = 6'd16,  // rd = rs1 | imm
    PVM_ALU_XOR_IMM            = 6'd17,  // rd = rs1 ^ imm
    PVM_ALU_AND_INVERTED       = 6'd18,  // rd = rs1 & ~rs2  (ANDN)
    PVM_ALU_OR_INVERTED        = 6'd19,  // rd = rs1 | ~rs2  (ORN)
    PVM_ALU_XNOR               = 6'd20,  // rd = ~(rs1 ^ rs2)
    // -- Shifts (64b) --------------------------------------------------------
    PVM_ALU_SLL_64             = 6'd21,  // rd = rs1 << rs2[5:0]
    PVM_ALU_SRL_64             = 6'd22,  // rd = rs1 >> rs2[5:0]   (logical)
    PVM_ALU_SRA_64             = 6'd23,  // rd = rs1 >>> rs2[5:0]  (arith)
    PVM_ALU_SLL_IMM_64         = 6'd24,  // rd = rs1 << imm[5:0]
    PVM_ALU_SRL_IMM_64         = 6'd25,  // rd = rs1 >> imm[5:0]
    PVM_ALU_SRA_IMM_64         = 6'd26,  // rd = rs1 >>> imm[5:0]
    // -- Shifts (32b, sign-extended) -----------------------------------------
    PVM_ALU_SLL_32             = 6'd27,  // rd = sext(rs1[31:0] << rs2[4:0])
    PVM_ALU_SRL_32             = 6'd28,
    PVM_ALU_SRA_32             = 6'd29,
    PVM_ALU_SLL_IMM_32         = 6'd30,
    PVM_ALU_SRL_IMM_32         = 6'd31,
    PVM_ALU_SRA_IMM_32         = 6'd32,
    // -- Multiply-high (upper 64 bits of 128-bit product) --------------------
    PVM_ALU_MUL_UPPER_SS       = 6'd33,  // mulh:   signed×signed   upper 64b
    PVM_ALU_MUL_UPPER_UU       = 6'd34,  // mulhu:  unsigned×unsign upper 64b
    PVM_ALU_MUL_UPPER_SU       = 6'd35,  // mulhsu: signed×unsigned upper 64b
    // -- Comparisons ---------------------------------------------------------
    PVM_ALU_SLT_U              = 6'd36,  // set_less_than_unsigned     (rs2)
    PVM_ALU_SLT_S              = 6'd37,  // set_less_than_signed       (rs2)
    PVM_ALU_SLT_U_IMM          = 6'd38,  // set_less_than_unsigned_imm
    PVM_ALU_SLT_S_IMM          = 6'd39,  // set_less_than_signed_imm
    PVM_ALU_SGT_U_IMM          = 6'd40,  // set_greater_than_unsigned_imm
    PVM_ALU_SGT_S_IMM          = 6'd41,  // set_greater_than_signed_imm
    // -- Min/Max -------------------------------------------------------------
    PVM_ALU_MAX_S              = 6'd42,  // signed maximum
    PVM_ALU_MAX_U              = 6'd43,  // unsigned maximum
    PVM_ALU_MIN_S              = 6'd44,  // signed minimum
    PVM_ALU_MIN_U              = 6'd45,  // unsigned minimum
    // -- Rotates -------------------------------------------------------------
    PVM_ALU_ROL_64             = 6'd46,
    PVM_ALU_ROR_64             = 6'd47,
    PVM_ALU_ROL_32             = 6'd48,
    PVM_ALU_ROR_32             = 6'd49,
    PVM_ALU_ROR_IMM_64         = 6'd50,
    PVM_ALU_ROR_IMM_32         = 6'd51,
    // -- Bit operations (reg_reg group 11) ------------------------------------
    PVM_ALU_MOVE_REG           = 6'd52,  // rd = rs1
    PVM_ALU_ZERO_EXT_16        = 6'd53,  // rd = rs1[15:0] zero-extended to 64b
    PVM_ALU_REV_BYTE_64        = 6'd54,  // byte-reverse 64b (= REV8)
    PVM_ALU_REV_BYTE_32        = 6'd55,  // byte-reverse lower 32b, sign-extend
    PVM_ALU_CLZ_64             = 6'd56,
    PVM_ALU_CLZ_32             = 6'd57,
    PVM_ALU_CTZ_64             = 6'd58,
    PVM_ALU_CTZ_32             = 6'd59,
    PVM_ALU_CPOP_64            = 6'd60,
    PVM_ALU_CPOP_32            = 6'd61,
    PVM_ALU_SEXT_8             = 6'd62,  // sign_extend_8
    PVM_ALU_SEXT_16            = 6'd63   // sign_extend_16
    // CMOV ops use the forwarding-network rs3 path (ADR-4); they route through
    // XHEAD_MVEQZ/XHEAD_MVNEZ in fu_op, not through this enum.
    // imm_alt shift variants share the same pvm_alu_op_e entry as their
    // non-alt counterparts; operand swap is done at the decoder (sub-phase 3).
  } pvm_alu_op_e;

  // ---------------------------------------------------------------------------
  // pvm_fetch_chunk_t — 128-bit fetch window passed from PVM frontend (ADR-O6)
  // ---------------------------------------------------------------------------
  // Sub-phase 3 drives this from pvm_frontend; sub-phase 1 stubs with '0.
  // `chunk`            — raw 16-byte window aligned to instruction start
  // `skip`             — leading bytes already consumed (0..15)
  // `is_valid_opcode`  — chunk[0+skip] decodes to a known JAMv1 opcode
  // `valid`            — chunk itself is architecturally valid (not a gap)
  //
  typedef struct packed {
    logic [127:0] chunk;
    logic [3:0]   skip;
    logic         is_valid_opcode;
    logic         valid;
  } pvm_fetch_chunk_t;

  // ---------------------------------------------------------------------------
  // pvm_decode_result_t — output of pvm_op_to_fu_t_op() (sub-phase 2)
  // ---------------------------------------------------------------------------
  // Uses raw logic types for fu/op to avoid importing ariane_pkg (which
  // follows polkavm_pkg in Flist.cva6).  Callers cast to fu_t/fu_op.
  //
  // fu          [3:0]  — ariane_pkg::fu_t encoded value
  // op          [7:0]  — ariane_pkg::fu_op encoded value
  // pvm_alu_op         — PVM ALU op selector (pvm_alu_op_e)
  // is_pvm_op          — set for all native PVM ops routed through pvm_alu
  // is_illegal         — set when opcode has no defined mapping (trap path)
  // use_imm            — operand B is the immediate (not rs2)
  //
  typedef struct packed {
    logic [3:0]   fu;
    logic [7:0]   op;
    pvm_alu_op_e  pvm_alu_op;
    logic         is_pvm_op;
    logic         is_illegal;
    logic         use_imm;
    logic         swap_operands;  // swap rs1/imm comparand for reversed comparisons (e.g. LEU→GEU)
  } pvm_decode_result_t;

  // Functional-unit encoding constants (must match ariane_pkg::fu_t values).
  localparam logic [3:0] PVM_FU_NONE      = 4'd0;
  localparam logic [3:0] PVM_FU_LOAD      = 4'd1;
  localparam logic [3:0] PVM_FU_STORE     = 4'd2;
  localparam logic [3:0] PVM_FU_ALU       = 4'd3;
  localparam logic [3:0] PVM_FU_CTRL_FLOW = 4'd4;
  localparam logic [3:0] PVM_FU_MULT      = 4'd5;
  localparam logic [3:0] PVM_FU_CSR       = 4'd6;

  // fu_op encoding constants (must match ariane_pkg::fu_op enum ordinal values).
  // Verified by counting enum members in ariane_pkg.sv (ADD=0, then sequential).
  localparam logic [7:0] PVM_OP_ADD_FU    = 8'd0;   // ariane_pkg::ADD
  localparam logic [7:0] PVM_OP_LTS_FU    = 8'd13;  // ariane_pkg::LTS
  localparam logic [7:0] PVM_OP_LTU_FU    = 8'd14;  // ariane_pkg::LTU
  localparam logic [7:0] PVM_OP_GES_FU    = 8'd15;  // ariane_pkg::GES
  localparam logic [7:0] PVM_OP_GEU_FU    = 8'd16;  // ariane_pkg::GEU
  localparam logic [7:0] PVM_OP_EQ_FU     = 8'd17;  // ariane_pkg::EQ
  localparam logic [7:0] PVM_OP_NE_FU     = 8'd18;  // ariane_pkg::NE
  localparam logic [7:0] PVM_OP_JALR_FU   = 8'd19;  // ariane_pkg::JALR
  localparam logic [7:0] PVM_OP_BRANCH_FU = 8'd20;  // ariane_pkg::BRANCH
  localparam logic [7:0] PVM_OP_ECALL_FU  = 8'd26;  // ariane_pkg::ECALL
  localparam logic [7:0] PVM_OP_LD_FU     = 8'd37;  // ariane_pkg::LD
  localparam logic [7:0] PVM_OP_SD_FU     = 8'd38;  // ariane_pkg::SD
  localparam logic [7:0] PVM_OP_LW_FU     = 8'd39;  // ariane_pkg::LW
  localparam logic [7:0] PVM_OP_LWU_FU    = 8'd40;  // ariane_pkg::LWU
  localparam logic [7:0] PVM_OP_SW_FU     = 8'd41;  // ariane_pkg::SW
  localparam logic [7:0] PVM_OP_LH_FU     = 8'd42;  // ariane_pkg::LH
  localparam logic [7:0] PVM_OP_LHU_FU    = 8'd43;  // ariane_pkg::LHU
  localparam logic [7:0] PVM_OP_SH_FU     = 8'd44;  // ariane_pkg::SH
  localparam logic [7:0] PVM_OP_LB_FU     = 8'd45;  // ariane_pkg::LB
  localparam logic [7:0] PVM_OP_SB_FU     = 8'd46;  // ariane_pkg::SB
  localparam logic [7:0] PVM_OP_LBU_FU    = 8'd47;  // ariane_pkg::LBU
  localparam logic [7:0] PVM_OP_MULH_FU   = 8'd88;  // ariane_pkg::MULH
  localparam logic [7:0] PVM_OP_MULHU_FU  = 8'd89;  // ariane_pkg::MULHU
  localparam logic [7:0] PVM_OP_MULHSU_FU = 8'd90;  // ariane_pkg::MULHSU
  localparam logic [7:0] PVM_OP_MULW_FU   = 8'd91;  // ariane_pkg::MULW
  localparam logic [7:0] PVM_OP_DIV_FU    = 8'd92;  // ariane_pkg::DIV
  localparam logic [7:0] PVM_OP_DIVU_FU   = 8'd93;  // ariane_pkg::DIVU
  localparam logic [7:0] PVM_OP_DIVW_FU   = 8'd94;  // ariane_pkg::DIVW
  localparam logic [7:0] PVM_OP_DIVUW_FU  = 8'd95;  // ariane_pkg::DIVUW
  localparam logic [7:0] PVM_OP_REM_FU    = 8'd96;  // ariane_pkg::REM
  localparam logic [7:0] PVM_OP_REMU_FU   = 8'd97;  // ariane_pkg::REMU
  localparam logic [7:0] PVM_OP_REMW_FU   = 8'd98;  // ariane_pkg::REMW
  localparam logic [7:0] PVM_OP_REMUW_FU  = 8'd99;  // ariane_pkg::REMUW
  localparam logic [7:0] PVM_OP_MVEQZ_FU  = 8'd192; // ariane_pkg::XHEAD_MVEQZ
  localparam logic [7:0] PVM_OP_MVNEZ_FU  = 8'd193; // ariane_pkg::XHEAD_MVNEZ

  // ---------------------------------------------------------------------------
  // pvm_op_to_fu_t_op — map pvm_op_t to ariane_pkg FU/op/pvm_alu_op (sub-phase 2)
  // ---------------------------------------------------------------------------
  // All 93 defined JAM v1 opcodes (from pvm_op_t enum above) are covered.
  // The default arm sets is_illegal=1; any opcode not in pvm_op_t falls here.
  //
  // Mapping authority: plan ralplan-phase4.5-integration.md sub-phase 2 §Edit1.
  //
  function automatic pvm_decode_result_t pvm_op_to_fu_t_op(input pvm_op_t op);
    pvm_decode_result_t r;
    // Safe defaults
    r.fu            = PVM_FU_NONE;
    r.op            = 8'd0;
    r.pvm_alu_op    = PVM_ALU_ADD_64;
    r.is_pvm_op     = 1'b0;
    r.is_illegal    = 1'b0;
    r.use_imm       = 1'b0;
    r.swap_operands = 1'b0;

    unique case (op)
      // -----------------------------------------------------------------------
      // Group 1: no_args
      // -----------------------------------------------------------------------
      PVM_OP_TRAP: begin
        // Halt — route to existing trap/ECALL path (commits as exception).
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_ECALL_FU;
      end
      PVM_OP_FALLTHROUGH,
      PVM_OP_UNLIKELY: begin
        // No-op / hint — NOP through NONE FU.
        r.fu = PVM_FU_NONE; r.op = 8'd0;
      end

      // -----------------------------------------------------------------------
      // Group 9: imm — ecalli
      // -----------------------------------------------------------------------
      PVM_OP_ECALLI: begin
        r.fu = PVM_FU_CSR; r.op = PVM_OP_ECALL_FU;
      end

      // -----------------------------------------------------------------------
      // Group 13: reg_imm64 — load_imm64 (64-bit immediate load)
      // -----------------------------------------------------------------------
      PVM_OP_LOAD_IMM64: begin
        // rd = imm64 — use ALU ADD with rs1=x0, imm=imm64.
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ADD_IMM_64;
        r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end

      // -----------------------------------------------------------------------
      // Group 10: imm_imm — store_imm (absolute address + immediate value)
      // -----------------------------------------------------------------------
      // imm1 = absolute address (used as offset, base reg = x0 from decoder),
      // imm2 = data byte. id_stage packs {imm2[31:0], imm1[31:0]} into
      // result; issue_read_operands extracts result[63:32] as operand_b.
      PVM_OP_STORE_IMM_U8:  begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SB_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_STORE_IMM_U16: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SH_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_STORE_IMM_U32: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SW_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_STORE_IMM_U64: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SD_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end

      // -----------------------------------------------------------------------
      // Group 8: offset — jump (PC-relative unconditional)
      // -----------------------------------------------------------------------
      PVM_OP_JUMP: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_BRANCH_FU;
      end

      // -----------------------------------------------------------------------
      // Group 2: reg_imm
      // -----------------------------------------------------------------------
      PVM_OP_JUMP_INDIRECT: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_JALR_FU;
      end
      PVM_OP_LOAD_IMM: begin
        // rd = sext(imm32) — ALU ADD rs1=x0, operand_b=imm.
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ADD_IMM_64;
        r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_LOAD_U8:  begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LBU_FU; end
      PVM_OP_LOAD_I8:  begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LB_FU;  end
      PVM_OP_LOAD_U16: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LHU_FU; end
      PVM_OP_LOAD_I16: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LH_FU;  end
      PVM_OP_LOAD_U32: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LWU_FU; end
      PVM_OP_LOAD_I32: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LW_FU;  end
      PVM_OP_LOAD_U64: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LD_FU;  end
      PVM_OP_STORE_U8:  begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SB_FU; end
      PVM_OP_STORE_U16: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SH_FU; end
      PVM_OP_STORE_U32: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SW_FU; end
      PVM_OP_STORE_U64: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SD_FU; end

      // -----------------------------------------------------------------------
      // Group 4: store_imm_indirect (base reg + imm offset + imm value)
      // -----------------------------------------------------------------------
      // rs1 = base reg, imm1 = offset, imm2 = data byte. id_stage packs
      // {imm2[31:0], imm1[31:0]} into result; LSU computes addr = rs1 + result[31:0],
      // issue_read_operands extracts sext(result[63:32]) as operand_b (write data).
      PVM_OP_STORE_IMM_INDIRECT_U8:  begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SB_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_STORE_IMM_INDIRECT_U16: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SH_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_STORE_IMM_INDIRECT_U32: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SW_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_STORE_IMM_INDIRECT_U64: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SD_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end

      // -----------------------------------------------------------------------
      // Group 3: reg_imm_offset (conditional branches with immediate comparand,
      //                          and load_imm_and_jump)
      // -----------------------------------------------------------------------
      PVM_OP_LOAD_IMM_AND_JUMP: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_BRANCH_FU;
      end
      // Conditional branches: use specific CVA6 comparison ops so op_is_branch()
      // fires correctly and is_mispredict is only set when branch is mispredicted.
      // For reversed comparisons (LEU, GTU, LES, GTS) we set swap_operands so
      // issue_read_operands swaps rs1 and the comparand immediate.
      PVM_OP_BRANCH_EQ_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_EQ_FU;
      end
      PVM_OP_BRANCH_NOT_EQ_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_NE_FU;
      end
      PVM_OP_BRANCH_LESS_UNSIGNED_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_LTU_FU;
      end
      PVM_OP_BRANCH_GREATER_OR_EQUAL_UNSIGNED_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_GEU_FU;
      end
      PVM_OP_BRANCH_LESS_SIGNED_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_LTS_FU;
      end
      PVM_OP_BRANCH_GREATER_OR_EQUAL_SIGNED_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_GES_FU;
      end
      // Reversed: a <=_u b  ≡  b >=_u a  →  GEU with operands swapped
      PVM_OP_BRANCH_LESS_OR_EQUAL_UNSIGNED_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_GEU_FU; r.swap_operands = 1'b1;
      end
      // Reversed: a >_u b   ≡  b <_u a  →  LTU with operands swapped
      PVM_OP_BRANCH_GREATER_UNSIGNED_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_LTU_FU; r.swap_operands = 1'b1;
      end
      // Reversed: a <=_s b  ≡  b >=_s a  →  GES with operands swapped
      PVM_OP_BRANCH_LESS_OR_EQUAL_SIGNED_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_GES_FU; r.swap_operands = 1'b1;
      end
      // Reversed: a >_s b   ≡  b <_s a  →  LTS with operands swapped
      PVM_OP_BRANCH_GREATER_SIGNED_IMM: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_LTS_FU; r.swap_operands = 1'b1;
      end

      // -----------------------------------------------------------------------
      // Group 11: reg_reg — bit/count ops + move_reg
      // -----------------------------------------------------------------------
      PVM_OP_MOVE_REG: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MOVE_REG; r.is_pvm_op = 1'b1;
      end
      PVM_OP_COUNT_SET_BITS_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_CPOP_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_COUNT_SET_BITS_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_CPOP_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_COUNT_LEADING_ZERO_BITS_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_CLZ_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_COUNT_LEADING_ZERO_BITS_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_CLZ_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_COUNT_TRAILING_ZERO_BITS_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_CTZ_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_COUNT_TRAILING_ZERO_BITS_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_CTZ_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SIGN_EXTEND_8: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SEXT_8; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SIGN_EXTEND_16: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SEXT_16; r.is_pvm_op = 1'b1;
      end
      PVM_OP_ZERO_EXTEND_16: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ZERO_EXT_16; r.is_pvm_op = 1'b1;
      end
      PVM_OP_REVERSE_BYTE: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_REV_BYTE_64; r.is_pvm_op = 1'b1;
      end

      // -----------------------------------------------------------------------
      // Group 5: reg_reg_imm — ALU-with-immediate, loads/stores with offset
      // -----------------------------------------------------------------------
      PVM_OP_STORE_INDIRECT_U8:  begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SB_FU; end
      PVM_OP_STORE_INDIRECT_U16: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SH_FU; end
      PVM_OP_STORE_INDIRECT_U32: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SW_FU; end
      PVM_OP_STORE_INDIRECT_U64: begin r.fu = PVM_FU_STORE; r.op = PVM_OP_SD_FU; end
      PVM_OP_LOAD_INDIRECT_U8:  begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LBU_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_LOAD_INDIRECT_I8:  begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LB_FU;  r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_LOAD_INDIRECT_U16: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LHU_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_LOAD_INDIRECT_I16: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LH_FU;  r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_LOAD_INDIRECT_U32: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LWU_FU; r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_LOAD_INDIRECT_I32: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LW_FU;  r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_LOAD_INDIRECT_U64: begin r.fu = PVM_FU_LOAD; r.op = PVM_OP_LD_FU;  r.use_imm = 1'b1; r.is_pvm_op = 1'b1; end
      PVM_OP_ADD_IMM_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ADD_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_AND_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_AND_IMM; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_XOR_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_XOR_IMM; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_OR_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_OR_IMM; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_MUL_IMM_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MUL_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SET_LESS_THAN_UNSIGNED_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLT_U_IMM; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SET_LESS_THAN_SIGNED_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLT_S_IMM; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_LEFT_IMM_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLL_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRL_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRA_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_NEGATE_AND_ADD_IMM_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_NEGATE_ADD_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SET_GREATER_THAN_UNSIGNED_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SGT_U_IMM; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SET_GREATER_THAN_SIGNED_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SGT_S_IMM; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      // Alt shift variants: operand swap done at decoder; ALU op is same.
      PVM_OP_SHIFT_LOGICAL_LEFT_IMM_ALT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLL_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_ALT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRL_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_ALT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRA_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_CMOV_IF_ZERO_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_MVEQZ_FU; r.use_imm = 1'b1;
      end
      PVM_OP_CMOV_IF_NOT_ZERO_IMM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_MVNEZ_FU; r.use_imm = 1'b1;
      end
      PVM_OP_ADD_IMM_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ADD_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_MUL_IMM_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MUL_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_LEFT_IMM_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLL_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRL_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRA_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_NEGATE_AND_ADD_IMM_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_NEGATE_ADD_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_LEFT_IMM_ALT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLL_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_ALT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRL_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_ALT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRA_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_ROTATE_RIGHT_IMM_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ROR_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_ROTATE_RIGHT_IMM_ALT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ROR_IMM_64; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_ROTATE_RIGHT_IMM_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ROR_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end
      PVM_OP_ROTATE_RIGHT_IMM_ALT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ROR_IMM_32; r.is_pvm_op = 1'b1; r.use_imm = 1'b1;
      end

      // -----------------------------------------------------------------------
      // Group 6: reg_reg_offset — conditional branches (register vs register)
      // -----------------------------------------------------------------------
      PVM_OP_BRANCH_EQ,
      PVM_OP_BRANCH_NOT_EQ,
      PVM_OP_BRANCH_LESS_UNSIGNED,
      PVM_OP_BRANCH_LESS_SIGNED,
      PVM_OP_BRANCH_GREATER_OR_EQUAL_UNSIGNED,
      PVM_OP_BRANCH_GREATER_OR_EQUAL_SIGNED: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_BRANCH_FU;
      end

      // -----------------------------------------------------------------------
      // Group 12: reg_imm_imm — load_imm_and_jump_indirect
      // -----------------------------------------------------------------------
      PVM_OP_LOAD_IMM_AND_JUMP_INDIRECT: begin
        r.fu = PVM_FU_CTRL_FLOW; r.op = PVM_OP_JALR_FU;
      end

      // -----------------------------------------------------------------------
      // Group 7: reg_reg_reg — standard ALU ops
      // -----------------------------------------------------------------------
      PVM_OP_ADD_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ADD_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SUB_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SUB_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MUL_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MUL_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_DIV_UNSIGNED_32: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_DIVUW_FU;
      end
      PVM_OP_DIV_SIGNED_32: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_DIVW_FU;
      end
      PVM_OP_REM_UNSIGNED_32: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_REMUW_FU;
      end
      PVM_OP_REM_SIGNED_32: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_REMW_FU;
      end
      PVM_OP_SHIFT_LOGICAL_LEFT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLL_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_RIGHT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRL_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SHIFT_ARITHMETIC_RIGHT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRA_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_ADD_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ADD_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SUB_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SUB_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MUL_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MUL_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_DIV_UNSIGNED_64: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_DIVU_FU;
      end
      PVM_OP_DIV_SIGNED_64: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_DIV_FU;
      end
      PVM_OP_REM_UNSIGNED_64: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_REMU_FU;
      end
      PVM_OP_REM_SIGNED_64: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_REM_FU;
      end
      PVM_OP_SHIFT_LOGICAL_LEFT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLL_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SHIFT_LOGICAL_RIGHT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRL_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SHIFT_ARITHMETIC_RIGHT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SRA_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_AND: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_AND; r.is_pvm_op = 1'b1;
      end
      PVM_OP_XOR: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_XOR; r.is_pvm_op = 1'b1;
      end
      PVM_OP_OR: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_OR; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MUL_UPPER_SIGNED_SIGNED: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_MULH_FU;
        r.pvm_alu_op = PVM_ALU_MUL_UPPER_SS; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MUL_UPPER_UNSIGNED_UNSIGNED: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_MULHU_FU;
        r.pvm_alu_op = PVM_ALU_MUL_UPPER_UU; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MUL_UPPER_SIGNED_UNSIGNED: begin
        r.fu = PVM_FU_MULT; r.op = PVM_OP_MULHSU_FU;
        r.pvm_alu_op = PVM_ALU_MUL_UPPER_SU; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SET_LESS_THAN_UNSIGNED: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLT_U; r.is_pvm_op = 1'b1;
      end
      PVM_OP_SET_LESS_THAN_SIGNED: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_SLT_S; r.is_pvm_op = 1'b1;
      end
      PVM_OP_CMOV_IF_ZERO: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_MVEQZ_FU;
      end
      PVM_OP_CMOV_IF_NOT_ZERO: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_MVNEZ_FU;
      end
      PVM_OP_ROTATE_LEFT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ROL_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_ROTATE_LEFT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ROL_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_ROTATE_RIGHT_64: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ROR_64; r.is_pvm_op = 1'b1;
      end
      PVM_OP_ROTATE_RIGHT_32: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_ROR_32; r.is_pvm_op = 1'b1;
      end
      PVM_OP_AND_INVERTED: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_AND_INVERTED; r.is_pvm_op = 1'b1;
      end
      PVM_OP_OR_INVERTED: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_OR_INVERTED; r.is_pvm_op = 1'b1;
      end
      PVM_OP_XNOR: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_XNOR; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MAXIMUM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MAX_S; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MAXIMUM_UNSIGNED: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MAX_U; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MINIMUM: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MIN_S; r.is_pvm_op = 1'b1;
      end
      PVM_OP_MINIMUM_UNSIGNED: begin
        r.fu = PVM_FU_ALU; r.op = PVM_OP_ADD_FU;
        r.pvm_alu_op = PVM_ALU_MIN_U; r.is_pvm_op = 1'b1;
      end

      // -----------------------------------------------------------------------
      // Default: undefined opcode → illegal (trap path)
      // -----------------------------------------------------------------------
      default: begin
        r.is_illegal = 1'b1;
      end
    endcase
    return r;
  endfunction

endpackage
