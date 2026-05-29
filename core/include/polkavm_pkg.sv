// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// PolkaVM JAM v1 instruction-set package for the CVA6 hardware PVM front half.
//
// This package is the single source of truth for JAM v1 opcode numbers, their
// argument families (operand encoding shape), and the block-terminator /
// valid-opcode sets used by the PVM fetch unit (pvm_fetch.sv) and PVM decoder
// (pvm_decoder.sv).
//
// References:
//   - graypaper text/pvm.tex sec. "Instruction Tables" (arg families) and
//     "Basic Blocks and Termination Instructions" (set T).
//   - polkavm/crates/polkavm-common/src/program.rs (ISA_JamV1 + ISA_JamV1Privileged).
//
// It is intentionally self-contained (no ariane_pkg/config dependency) so it
// can be lint-checked standalone. Opcode -> ariane_pkg::fu_op mapping lives in
// the decoder (Stage 2), not here.

package polkavm_pkg;

  // ---------------------------------------------------------------------------
  // Opcode numbers (ISA_JamV1)
  // ---------------------------------------------------------------------------
  // No-argument
  localparam logic [7:0] PVM_OP_TRAP                 = 8'd0;
  localparam logic [7:0] PVM_OP_FALLTHROUGH          = 8'd1;
  localparam logic [7:0] PVM_OP_UNLIKELY             = 8'd2;

  // One immediate
  localparam logic [7:0] PVM_OP_ECALLI               = 8'd10;

  // One register + one extended-width (8-byte) immediate
  localparam logic [7:0] PVM_OP_LOAD_IMM_64          = 8'd20;

  // Two immediates (store immediate, absolute address)
  localparam logic [7:0] PVM_OP_STORE_IMM_U8         = 8'd30;
  localparam logic [7:0] PVM_OP_STORE_IMM_U16        = 8'd31;
  localparam logic [7:0] PVM_OP_STORE_IMM_U32        = 8'd32;
  localparam logic [7:0] PVM_OP_STORE_IMM_U64        = 8'd33;

  // One offset
  localparam logic [7:0] PVM_OP_JUMP                 = 8'd40;

  // One register + one immediate
  localparam logic [7:0] PVM_OP_JUMP_IND             = 8'd50;
  localparam logic [7:0] PVM_OP_LOAD_IMM             = 8'd51;
  localparam logic [7:0] PVM_OP_LOAD_U8              = 8'd52;
  localparam logic [7:0] PVM_OP_LOAD_I8              = 8'd53;
  localparam logic [7:0] PVM_OP_LOAD_U16             = 8'd54;
  localparam logic [7:0] PVM_OP_LOAD_I16             = 8'd55;
  localparam logic [7:0] PVM_OP_LOAD_U32             = 8'd56;
  localparam logic [7:0] PVM_OP_LOAD_I32             = 8'd57;
  localparam logic [7:0] PVM_OP_LOAD_U64             = 8'd58;
  localparam logic [7:0] PVM_OP_STORE_U8             = 8'd59;
  localparam logic [7:0] PVM_OP_STORE_U16            = 8'd60;
  localparam logic [7:0] PVM_OP_STORE_U32            = 8'd61;
  localparam logic [7:0] PVM_OP_STORE_U64            = 8'd62;

  // One register + two immediates (store immediate, indirect)
  localparam logic [7:0] PVM_OP_STORE_IMM_IND_U8     = 8'd70;
  localparam logic [7:0] PVM_OP_STORE_IMM_IND_U16    = 8'd71;
  localparam logic [7:0] PVM_OP_STORE_IMM_IND_U32    = 8'd72;
  localparam logic [7:0] PVM_OP_STORE_IMM_IND_U64    = 8'd73;

  // One register + one immediate + one offset
  localparam logic [7:0] PVM_OP_LOAD_IMM_JUMP        = 8'd80;
  localparam logic [7:0] PVM_OP_BRANCH_EQ_IMM        = 8'd81;
  localparam logic [7:0] PVM_OP_BRANCH_NE_IMM        = 8'd82;
  localparam logic [7:0] PVM_OP_BRANCH_LT_U_IMM      = 8'd83;
  localparam logic [7:0] PVM_OP_BRANCH_LE_U_IMM      = 8'd84;
  localparam logic [7:0] PVM_OP_BRANCH_GE_U_IMM      = 8'd85;
  localparam logic [7:0] PVM_OP_BRANCH_GT_U_IMM      = 8'd86;
  localparam logic [7:0] PVM_OP_BRANCH_LT_S_IMM      = 8'd87;
  localparam logic [7:0] PVM_OP_BRANCH_LE_S_IMM      = 8'd88;
  localparam logic [7:0] PVM_OP_BRANCH_GE_S_IMM      = 8'd89;
  localparam logic [7:0] PVM_OP_BRANCH_GT_S_IMM      = 8'd90;

  // Two registers
  localparam logic [7:0] PVM_OP_MOVE_REG             = 8'd100;
  localparam logic [7:0] PVM_OP_COUNT_SET_BITS_64    = 8'd101;
  localparam logic [7:0] PVM_OP_COUNT_SET_BITS_32    = 8'd102;
  localparam logic [7:0] PVM_OP_LEADING_ZERO_BITS_64 = 8'd103;
  localparam logic [7:0] PVM_OP_LEADING_ZERO_BITS_32 = 8'd104;
  localparam logic [7:0] PVM_OP_TRAILING_ZERO_BITS_64= 8'd105;
  localparam logic [7:0] PVM_OP_TRAILING_ZERO_BITS_32= 8'd106;
  localparam logic [7:0] PVM_OP_SIGN_EXTEND_8        = 8'd107;
  localparam logic [7:0] PVM_OP_SIGN_EXTEND_16       = 8'd108;
  localparam logic [7:0] PVM_OP_ZERO_EXTEND_16       = 8'd109;
  localparam logic [7:0] PVM_OP_REVERSE_BYTES        = 8'd110;

  // Two registers + one immediate (indirect load/store + reg-imm ALU)
  localparam logic [7:0] PVM_OP_STORE_IND_U8         = 8'd120;
  localparam logic [7:0] PVM_OP_STORE_IND_U16        = 8'd121;
  localparam logic [7:0] PVM_OP_STORE_IND_U32        = 8'd122;
  localparam logic [7:0] PVM_OP_STORE_IND_U64        = 8'd123;
  localparam logic [7:0] PVM_OP_LOAD_IND_U8          = 8'd124;
  localparam logic [7:0] PVM_OP_LOAD_IND_I8          = 8'd125;
  localparam logic [7:0] PVM_OP_LOAD_IND_U16         = 8'd126;
  localparam logic [7:0] PVM_OP_LOAD_IND_I16         = 8'd127;
  localparam logic [7:0] PVM_OP_LOAD_IND_U32         = 8'd128;
  localparam logic [7:0] PVM_OP_LOAD_IND_I32         = 8'd129;
  localparam logic [7:0] PVM_OP_LOAD_IND_U64         = 8'd130;
  localparam logic [7:0] PVM_OP_ADD_IMM_32           = 8'd131;
  localparam logic [7:0] PVM_OP_AND_IMM              = 8'd132;
  localparam logic [7:0] PVM_OP_XOR_IMM              = 8'd133;
  localparam logic [7:0] PVM_OP_OR_IMM               = 8'd134;
  localparam logic [7:0] PVM_OP_MUL_IMM_32           = 8'd135;
  localparam logic [7:0] PVM_OP_SET_LT_U_IMM         = 8'd136;
  localparam logic [7:0] PVM_OP_SET_LT_S_IMM         = 8'd137;
  localparam logic [7:0] PVM_OP_SHLO_L_IMM_32        = 8'd138;
  localparam logic [7:0] PVM_OP_SHLO_R_IMM_32        = 8'd139;
  localparam logic [7:0] PVM_OP_SHAR_R_IMM_32        = 8'd140;
  localparam logic [7:0] PVM_OP_NEG_ADD_IMM_32       = 8'd141;
  localparam logic [7:0] PVM_OP_SET_GT_U_IMM         = 8'd142;
  localparam logic [7:0] PVM_OP_SET_GT_S_IMM         = 8'd143;
  localparam logic [7:0] PVM_OP_SHLO_L_IMM_ALT_32    = 8'd144;
  localparam logic [7:0] PVM_OP_SHLO_R_IMM_ALT_32    = 8'd145;
  localparam logic [7:0] PVM_OP_SHAR_R_IMM_ALT_32    = 8'd146;
  localparam logic [7:0] PVM_OP_CMOV_IZ_IMM          = 8'd147;
  localparam logic [7:0] PVM_OP_CMOV_NZ_IMM          = 8'd148;
  localparam logic [7:0] PVM_OP_ADD_IMM_64           = 8'd149;
  localparam logic [7:0] PVM_OP_MUL_IMM_64           = 8'd150;
  localparam logic [7:0] PVM_OP_SHLO_L_IMM_64        = 8'd151;
  localparam logic [7:0] PVM_OP_SHLO_R_IMM_64        = 8'd152;
  localparam logic [7:0] PVM_OP_SHAR_R_IMM_64        = 8'd153;
  localparam logic [7:0] PVM_OP_NEG_ADD_IMM_64       = 8'd154;
  localparam logic [7:0] PVM_OP_SHLO_L_IMM_ALT_64    = 8'd155;
  localparam logic [7:0] PVM_OP_SHLO_R_IMM_ALT_64    = 8'd156;
  localparam logic [7:0] PVM_OP_SHAR_R_IMM_ALT_64    = 8'd157;
  localparam logic [7:0] PVM_OP_ROT_R_64_IMM         = 8'd158;
  localparam logic [7:0] PVM_OP_ROT_R_64_IMM_ALT     = 8'd159;
  localparam logic [7:0] PVM_OP_ROT_R_32_IMM         = 8'd160;
  localparam logic [7:0] PVM_OP_ROT_R_32_IMM_ALT     = 8'd161;

  // Two registers + one offset (register-register branches)
  localparam logic [7:0] PVM_OP_BRANCH_EQ            = 8'd170;
  localparam logic [7:0] PVM_OP_BRANCH_NE            = 8'd171;
  localparam logic [7:0] PVM_OP_BRANCH_LT_U          = 8'd172;
  localparam logic [7:0] PVM_OP_BRANCH_LT_S          = 8'd173;
  localparam logic [7:0] PVM_OP_BRANCH_GE_U          = 8'd174;
  localparam logic [7:0] PVM_OP_BRANCH_GE_S          = 8'd175;

  // Two registers + two immediates
  localparam logic [7:0] PVM_OP_LOAD_IMM_JUMP_IND    = 8'd180;

  // Three registers
  localparam logic [7:0] PVM_OP_ADD_32               = 8'd190;
  localparam logic [7:0] PVM_OP_SUB_32               = 8'd191;
  localparam logic [7:0] PVM_OP_MUL_32               = 8'd192;
  localparam logic [7:0] PVM_OP_DIV_U_32             = 8'd193;
  localparam logic [7:0] PVM_OP_DIV_S_32             = 8'd194;
  localparam logic [7:0] PVM_OP_REM_U_32             = 8'd195;
  localparam logic [7:0] PVM_OP_REM_S_32             = 8'd196;
  localparam logic [7:0] PVM_OP_SHLO_L_32            = 8'd197;
  localparam logic [7:0] PVM_OP_SHLO_R_32            = 8'd198;
  localparam logic [7:0] PVM_OP_SHAR_R_32            = 8'd199;
  localparam logic [7:0] PVM_OP_ADD_64               = 8'd200;
  localparam logic [7:0] PVM_OP_SUB_64               = 8'd201;
  localparam logic [7:0] PVM_OP_MUL_64               = 8'd202;
  localparam logic [7:0] PVM_OP_DIV_U_64             = 8'd203;
  localparam logic [7:0] PVM_OP_DIV_S_64             = 8'd204;
  localparam logic [7:0] PVM_OP_REM_U_64             = 8'd205;
  localparam logic [7:0] PVM_OP_REM_S_64             = 8'd206;
  localparam logic [7:0] PVM_OP_SHLO_L_64            = 8'd207;
  localparam logic [7:0] PVM_OP_SHLO_R_64            = 8'd208;
  localparam logic [7:0] PVM_OP_SHAR_R_64            = 8'd209;
  localparam logic [7:0] PVM_OP_AND                  = 8'd210;
  localparam logic [7:0] PVM_OP_XOR                  = 8'd211;
  localparam logic [7:0] PVM_OP_OR                   = 8'd212;
  localparam logic [7:0] PVM_OP_MUL_UPPER_S_S        = 8'd213;
  localparam logic [7:0] PVM_OP_MUL_UPPER_U_U        = 8'd214;
  localparam logic [7:0] PVM_OP_MUL_UPPER_S_U        = 8'd215;
  localparam logic [7:0] PVM_OP_SET_LT_U             = 8'd216;
  localparam logic [7:0] PVM_OP_SET_LT_S             = 8'd217;
  localparam logic [7:0] PVM_OP_CMOV_IZ             = 8'd218;
  localparam logic [7:0] PVM_OP_CMOV_NZ             = 8'd219;
  localparam logic [7:0] PVM_OP_ROT_L_64             = 8'd220;
  localparam logic [7:0] PVM_OP_ROT_L_32             = 8'd221;
  localparam logic [7:0] PVM_OP_ROT_R_64             = 8'd222;
  localparam logic [7:0] PVM_OP_ROT_R_32             = 8'd223;
  localparam logic [7:0] PVM_OP_AND_INV              = 8'd224;
  localparam logic [7:0] PVM_OP_OR_INV               = 8'd225;
  localparam logic [7:0] PVM_OP_XNOR                 = 8'd226;
  localparam logic [7:0] PVM_OP_MAX                  = 8'd227;
  localparam logic [7:0] PVM_OP_MAX_U                = 8'd228;
  localparam logic [7:0] PVM_OP_MIN                  = 8'd229;
  localparam logic [7:0] PVM_OP_MIN_U                = 8'd230;

  // ---------------------------------------------------------------------------
  // Privileged extension (ISA_JamV1Privileged, opcodes 231-240, ADR-1.1).
  // Emitted only by `polkatool link --privileged` (blob version byte 5).
  // U/S-mode legality is gated in the decoder by privilege mode, not here.
  // ---------------------------------------------------------------------------
  // CSR std (231-233): reg_reg_imm -> b1[7:4]=rd, b1[3:0]=rs1, imm[11:0]=csr.
  localparam logic [7:0] PVM_OP_CSR_RW               = 8'd231;
  localparam logic [7:0] PVM_OP_CSR_RS               = 8'd232;
  localparam logic [7:0] PVM_OP_CSR_RC               = 8'd233;
  // CSR imm (234-236): reg_reg_imm -> b1[7:4]=rd, b1[3:0]=zimm, imm[11:0]=csr.
  localparam logic [7:0] PVM_OP_CSR_RWI              = 8'd234;
  localparam logic [7:0] PVM_OP_CSR_RSI              = 8'd235;
  localparam logic [7:0] PVM_OP_CSR_RCI              = 8'd236;
  // mret/sret/wfi (237-239): argless.
  localparam logic [7:0] PVM_OP_MRET                 = 8'd237;
  localparam logic [7:0] PVM_OP_SRET                 = 8'd238;
  localparam logic [7:0] PVM_OP_WFI                  = 8'd239;
  // sfence_vma (240): reg_reg -> b1[7:4]=rs1, b1[3:0]=rs2.
  localparam logic [7:0] PVM_OP_SFENCE_VMA           = 8'd240;

  // ---------------------------------------------------------------------------
  // Argument families (operand encoding shape). Determines how pvm_fetch slices
  // operand bytes and how pvm_decoder reads registers/immediates.
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    PVM_ARG_INVALID = 4'd0,  // not a defined opcode (set U complement)
    PVM_ARG_NONE,            // no arguments
    PVM_ARG_IMM,             // 1 immediate
    PVM_ARG_REG_IMMEXT,      // 1 reg + 8-byte immediate (load_imm_64)
    PVM_ARG_2IMM,            // 2 immediates
    PVM_ARG_OFFSET,          // 1 offset
    PVM_ARG_REG_IMM,         // 1 reg + 1 immediate
    PVM_ARG_REG_2IMM,        // 1 reg + 2 immediates
    PVM_ARG_REG_IMM_OFF,     // 1 reg + 1 immediate + 1 offset
    PVM_ARG_2REG,            // 2 registers
    PVM_ARG_2REG_IMM,        // 2 registers + 1 immediate
    PVM_ARG_2REG_OFF,        // 2 registers + 1 offset
    PVM_ARG_2REG_2IMM,       // 2 registers + 2 immediates
    PVM_ARG_3REG             // 3 registers
  } pvm_arg_family_e;

  // Classify an opcode byte into its argument family. PVM_ARG_INVALID marks an
  // opcode not in the valid set U (decoder must panic on these).
  function automatic pvm_arg_family_e pvm_arg_family(input logic [7:0] op);
    unique case (op)
      PVM_OP_TRAP, PVM_OP_FALLTHROUGH, PVM_OP_UNLIKELY,
      PVM_OP_MRET, PVM_OP_SRET, PVM_OP_WFI:
        return PVM_ARG_NONE;

      PVM_OP_ECALLI:
        return PVM_ARG_IMM;

      PVM_OP_LOAD_IMM_64:
        return PVM_ARG_REG_IMMEXT;

      PVM_OP_STORE_IMM_U8, PVM_OP_STORE_IMM_U16,
      PVM_OP_STORE_IMM_U32, PVM_OP_STORE_IMM_U64:
        return PVM_ARG_2IMM;

      PVM_OP_JUMP:
        return PVM_ARG_OFFSET;

      PVM_OP_JUMP_IND, PVM_OP_LOAD_IMM,
      PVM_OP_LOAD_U8, PVM_OP_LOAD_I8, PVM_OP_LOAD_U16, PVM_OP_LOAD_I16,
      PVM_OP_LOAD_U32, PVM_OP_LOAD_I32, PVM_OP_LOAD_U64,
      PVM_OP_STORE_U8, PVM_OP_STORE_U16, PVM_OP_STORE_U32, PVM_OP_STORE_U64:
        return PVM_ARG_REG_IMM;

      PVM_OP_STORE_IMM_IND_U8, PVM_OP_STORE_IMM_IND_U16,
      PVM_OP_STORE_IMM_IND_U32, PVM_OP_STORE_IMM_IND_U64:
        return PVM_ARG_REG_2IMM;

      PVM_OP_LOAD_IMM_JUMP,
      PVM_OP_BRANCH_EQ_IMM, PVM_OP_BRANCH_NE_IMM,
      PVM_OP_BRANCH_LT_U_IMM, PVM_OP_BRANCH_LE_U_IMM,
      PVM_OP_BRANCH_GE_U_IMM, PVM_OP_BRANCH_GT_U_IMM,
      PVM_OP_BRANCH_LT_S_IMM, PVM_OP_BRANCH_LE_S_IMM,
      PVM_OP_BRANCH_GE_S_IMM, PVM_OP_BRANCH_GT_S_IMM:
        return PVM_ARG_REG_IMM_OFF;

      PVM_OP_MOVE_REG, PVM_OP_COUNT_SET_BITS_64, PVM_OP_COUNT_SET_BITS_32,
      PVM_OP_LEADING_ZERO_BITS_64, PVM_OP_LEADING_ZERO_BITS_32,
      PVM_OP_TRAILING_ZERO_BITS_64, PVM_OP_TRAILING_ZERO_BITS_32,
      PVM_OP_SIGN_EXTEND_8, PVM_OP_SIGN_EXTEND_16,
      PVM_OP_ZERO_EXTEND_16, PVM_OP_REVERSE_BYTES,
      PVM_OP_SFENCE_VMA:
        return PVM_ARG_2REG;

      PVM_OP_BRANCH_EQ, PVM_OP_BRANCH_NE,
      PVM_OP_BRANCH_LT_U, PVM_OP_BRANCH_LT_S,
      PVM_OP_BRANCH_GE_U, PVM_OP_BRANCH_GE_S:
        return PVM_ARG_2REG_OFF;

      PVM_OP_LOAD_IMM_JUMP_IND:
        return PVM_ARG_2REG_2IMM;

      // 190..230 three-register ALU
      PVM_OP_ADD_32, PVM_OP_SUB_32, PVM_OP_MUL_32, PVM_OP_DIV_U_32,
      PVM_OP_DIV_S_32, PVM_OP_REM_U_32, PVM_OP_REM_S_32, PVM_OP_SHLO_L_32,
      PVM_OP_SHLO_R_32, PVM_OP_SHAR_R_32, PVM_OP_ADD_64, PVM_OP_SUB_64,
      PVM_OP_MUL_64, PVM_OP_DIV_U_64, PVM_OP_DIV_S_64, PVM_OP_REM_U_64,
      PVM_OP_REM_S_64, PVM_OP_SHLO_L_64, PVM_OP_SHLO_R_64, PVM_OP_SHAR_R_64,
      PVM_OP_AND, PVM_OP_XOR, PVM_OP_OR, PVM_OP_MUL_UPPER_S_S,
      PVM_OP_MUL_UPPER_U_U, PVM_OP_MUL_UPPER_S_U, PVM_OP_SET_LT_U,
      PVM_OP_SET_LT_S, PVM_OP_CMOV_IZ, PVM_OP_CMOV_NZ, PVM_OP_ROT_L_64,
      PVM_OP_ROT_L_32, PVM_OP_ROT_R_64, PVM_OP_ROT_R_32, PVM_OP_AND_INV,
      PVM_OP_OR_INV, PVM_OP_XNOR, PVM_OP_MAX, PVM_OP_MAX_U, PVM_OP_MIN,
      PVM_OP_MIN_U:
        return PVM_ARG_3REG;

      default: begin
        // 120..161 (two-reg + imm) covers a contiguous range incl. priv CSR;
        // checked via range below to keep the case readable.
        if ((op >= PVM_OP_STORE_IND_U8 && op <= PVM_OP_ROT_R_32_IMM_ALT) ||
            (op >= PVM_OP_CSR_RW && op <= PVM_OP_CSR_RCI))
          return PVM_ARG_2REG_IMM;
        else
          return PVM_ARG_INVALID;
      end
    endcase
  endfunction

  // Is `op` a defined (valid) opcode, i.e. in set U?
  function automatic logic pvm_is_valid_opcode(input logic [7:0] op);
    return pvm_arg_family(op) != PVM_ARG_INVALID;
  endfunction

  // Basic-block termination set T (graypaper pvm.tex "Basic Blocks"):
  // trap, fallthrough, all jumps/load-and-jumps, and all branches.
  function automatic logic pvm_is_terminator(input logic [7:0] op);
    unique case (op)
      PVM_OP_TRAP, PVM_OP_FALLTHROUGH,
      PVM_OP_JUMP, PVM_OP_JUMP_IND,
      PVM_OP_LOAD_IMM_JUMP, PVM_OP_LOAD_IMM_JUMP_IND,
      PVM_OP_BRANCH_EQ, PVM_OP_BRANCH_NE,
      PVM_OP_BRANCH_LT_U, PVM_OP_BRANCH_LT_S,
      PVM_OP_BRANCH_GE_U, PVM_OP_BRANCH_GE_S,
      PVM_OP_BRANCH_EQ_IMM, PVM_OP_BRANCH_NE_IMM,
      PVM_OP_BRANCH_LT_U_IMM, PVM_OP_BRANCH_LE_U_IMM,
      PVM_OP_BRANCH_GE_U_IMM, PVM_OP_BRANCH_GT_U_IMM,
      PVM_OP_BRANCH_LT_S_IMM, PVM_OP_BRANCH_LE_S_IMM,
      PVM_OP_BRANCH_GE_S_IMM, PVM_OP_BRANCH_GT_S_IMM:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Register-field helpers. PVM register indices are nibbles clamped to <=12
  // (13 registers, r0..r12). See graypaper arg-family equations.
  // ---------------------------------------------------------------------------
  // Clamp a 4-bit register nibble to the valid range [0,12].
  function automatic logic [3:0] pvm_clamp_reg(input logic [3:0] nibble);
    return (nibble > 4'd12) ? 4'd12 : nibble;
  endfunction

  // rA / rD low nibble: c[i+1][3:0].
  function automatic logic [3:0] pvm_reg_lo(input logic [7:0] byte1);
    return pvm_clamp_reg(byte1[3:0]);
  endfunction

  // rB high nibble: c[i+1][7:4].
  function automatic logic [3:0] pvm_reg_hi(input logic [7:0] byte1);
    return pvm_clamp_reg(byte1[7:4]);
  endfunction

  // ---------------------------------------------------------------------------
  // Immediate helpers. Operand immediates are little-endian, variable length
  // (0..8 octets), sign-extended from their byte length (graypaper eq:sext).
  // The instruction window `win` is the 16 code bytes c[i..i+15], byte 0 = opcode.
  // ---------------------------------------------------------------------------
  // Assemble `n` (0..8) little-endian bytes from `win` at byte offset `start`
  // into a 64-bit value (high bytes zero-filled).
  function automatic logic [63:0] pvm_le_bytes(input logic [127:0] win,
                                               input int unsigned   start,
                                               input int unsigned   n);
    logic [63:0] r;
    r = '0;
    for (int b = 0; b < 8; b++)
      if ((b < n) && ((start + b) < 16))
        r[b*8+:8] = win[(start + b)*8+:8];
    return r;
  endfunction

  // Sign-extend a value whose `nbytes` (0..8) low bytes are significant to 64b.
  function automatic logic [63:0] pvm_sext(input logic [63:0] raw,
                                           input int unsigned   nbytes);
    logic [63:0] mask;
    int unsigned bits;
    if (nbytes == 0) return 64'd0;
    if (nbytes >= 8) return raw;
    bits = nbytes * 8;
    mask = (64'd1 << bits) - 64'd1;
    if (raw[bits-1]) return raw | ~mask;  // negative -> fill high with ones
    else             return raw & mask;   // positive -> clear high bytes
  endfunction

endpackage
