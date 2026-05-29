// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// PolkaVM JAM v1 decoder — maps a fetched JAM instruction (opcode + 16-byte
// instruction window + skip length + instruction-counter) onto the CVA6 micro-op
// vocabulary (ariane_pkg::fu_t / fu_op + register addresses + immediate). The
// integration adapter (Stage 3) copies these into a scoreboard_entry_t and the
// existing issue/EX/commit backend executes them unchanged.
//
// FINAL LOCATION: core/pvm_decoder.sv is already its intended home (core/ is
// writable); only the Flist.cva6 entry + the scoreboard_entry_t adapter in
// cva6.sv are deferred until `chown` unblocks those uid-1000 files.
//
// Register mapping: PVM has 13 registers r0..r12 where r0 (RA) is a *real*
// register, so it cannot alias RISC-V x0 (hardwired zero). We map PVM rN ->
// RISC-V GPR (N+1); x0 stays the zero source used by move/load_imm, x14/x15 are
// free scratch (reserved for future macro-expansion of store_imm / branch_imm).
//
// Increment 1 scope: all 1:1-mappable ops (3-reg ALU/MUL, 2-reg unary, 2-reg+imm
// arithmetic, reg+imm loads/stores, jump_ind, reg-reg branches, load_imm,
// load_imm_64, ecalli, trap, privileged CSR/mret/sret/wfi/sfence). Ops needing
// multi-uop macro-expansion or reverse-operand routing (store_imm*, branch_*_imm,
// load_imm_jump[_ind], neg_add_imm, *_alt shifts, rot_*_imm) are flagged
// `unsupported_o` for a later increment.

module pvm_decoder
  import ariane_pkg::*;
  import polkavm_pkg::*;
#(
    parameter int unsigned VLEN = 32
) (
    input  logic [7:0]      opcode_i,
    input  logic [127:0]    instr_window_i,  // c[i..i+15], byte 0 = opcode
    input  logic [VLEN-1:0] pc_i,            // instruction-counter i
    input  logic [4:0]      skip_i,          // skip(i) = instruction length - 1
    // decoded micro-op (toward scoreboard_entry_t)
    output fu_t             fu_o,
    output fu_op            op_o,
    output logic [4:0]      rd_o,
    output logic [4:0]      rs1_o,
    output logic [4:0]      rs2_o,
    output logic [63:0]     imm_o,           // immediate / store data / target imm
    output logic            use_imm_o,       // operand B is the immediate
    output logic            is_branch_o,     // conditional branch (cond in op_o)
    output logic            is_jump_o,       // unconditional / indirect jump
    output logic [VLEN-1:0] branch_target_o, // PVM instruction-counter target
    output logic            is_hostcall_o,   // ecalli
    output logic [63:0]     hostcall_id_o,
    output logic            is_trap_o,       // trap opcode (panic)
    output logic            illegal_o,       // opcode not in valid set U
    output logic            unsupported_o    // valid but not handled in this increment
);

  // ---- field extraction ----------------------------------------------------
  logic [7:0] b1, b2;
  assign b1 = instr_window_i[15:8];   // c[i+1]
  assign b2 = instr_window_i[23:16];  // c[i+2]

  // PVM reg (clamped nibble/byte) -> RISC-V GPR (+1); x0 reserved as zero.
  logic [4:0] g_lo, g_hi, g_d3;
  assign g_lo = {1'b0, pvm_reg_lo(b1)} + 5'd1;                       // rA = low nibble
  assign g_hi = {1'b0, pvm_reg_hi(b1)} + 5'd1;                       // rB = high nibble
  assign g_d3 = (b2 > 8'd12) ? 5'd13 : ({1'b0, b2[3:0]} + 5'd1);     // rD = min(12,c[i+2])

  // immediate lengths (graypaper): reg+imm / 2reg+imm / 2reg+off use
  // lX = min(4, max(0, skip-1)), immediate at byte offset 2. ecalli uses
  // lX = min(4, skip) at offset 1. load_imm_64 uses 8 bytes at offset 2.
  int unsigned len_ri, len_ec;
  logic [63:0] imm_ri, imm_ec, imm64;
  always_comb begin
    int unsigned skip_int;
    skip_int = int'(skip_i);
    len_ri = (skip_int == 0) ? 0 : ((skip_int - 1 > 4) ? 4 : (skip_int - 1));
    len_ec = (skip_int > 4) ? 4 : skip_int;
    imm_ri = pvm_sext(pvm_le_bytes(instr_window_i, 2, len_ri), len_ri);
    imm_ec = pvm_sext(pvm_le_bytes(instr_window_i, 1, len_ec), len_ec);
    imm64  = pvm_le_bytes(instr_window_i, 2, 8);
  end

  // ---- decode ---------------------------------------------------------------
  always_comb begin
    // defaults
    fu_o            = NONE;
    op_o            = ADD;
    rd_o            = 5'd0;
    rs1_o           = 5'd0;
    rs2_o           = 5'd0;
    imm_o           = 64'd0;
    use_imm_o       = 1'b0;
    is_branch_o     = 1'b0;
    is_jump_o       = 1'b0;
    branch_target_o = '0;
    is_hostcall_o   = 1'b0;
    hostcall_id_o   = 64'd0;
    is_trap_o       = 1'b0;
    illegal_o       = 1'b0;
    unsupported_o   = 1'b0;

    unique case (opcode_i)
      // ---- no-arg ----
      PVM_OP_TRAP:        is_trap_o = 1'b1;
      PVM_OP_FALLTHROUGH: fu_o = NONE;                       // sequential fallthrough
      PVM_OP_UNLIKELY:    fu_o = NONE;                       // hint, no-op
      PVM_OP_MRET:      begin fu_o = CSR; op_o = MRET; end
      PVM_OP_SRET:      begin fu_o = CSR; op_o = SRET; end
      PVM_OP_WFI:       begin fu_o = CSR; op_o = WFI;  end

      // ---- host call ----
      PVM_OP_ECALLI: begin is_hostcall_o = 1'b1; hostcall_id_o = imm_ec; end

      // ---- load_imm_64 (reg + 8-byte imm) ----
      PVM_OP_LOAD_IMM_64: begin
        fu_o = ALU; op_o = ADD; rd_o = g_lo; rs1_o = 5'd0; imm_o = imm64; use_imm_o = 1'b1;
      end

      // ---- reg + imm: load_imm + absolute loads/stores + jump_ind ----
      PVM_OP_LOAD_IMM: begin
        fu_o = ALU; op_o = ADD; rd_o = g_lo; rs1_o = 5'd0; imm_o = imm_ri; use_imm_o = 1'b1;
      end
      PVM_OP_LOAD_U8, PVM_OP_LOAD_I8, PVM_OP_LOAD_U16, PVM_OP_LOAD_I16,
      PVM_OP_LOAD_U32, PVM_OP_LOAD_I32, PVM_OP_LOAD_U64: begin
        fu_o = LOAD; rd_o = g_lo; rs1_o = 5'd0; imm_o = imm_ri; use_imm_o = 1'b1;
        unique case (opcode_i)
          PVM_OP_LOAD_U8:  op_o = LBU;
          PVM_OP_LOAD_I8:  op_o = LB;
          PVM_OP_LOAD_U16: op_o = LHU;
          PVM_OP_LOAD_I16: op_o = LH;
          PVM_OP_LOAD_U32: op_o = LWU;
          PVM_OP_LOAD_I32: op_o = LW;
          default:         op_o = LD;   // LOAD_U64
        endcase
      end
      PVM_OP_STORE_U8, PVM_OP_STORE_U16, PVM_OP_STORE_U32, PVM_OP_STORE_U64: begin
        fu_o = STORE; rs1_o = 5'd0; rs2_o = g_lo; imm_o = imm_ri; use_imm_o = 1'b1;
        unique case (opcode_i)
          PVM_OP_STORE_U8:  op_o = SB;
          PVM_OP_STORE_U16: op_o = SH;
          PVM_OP_STORE_U32: op_o = SW;
          default:          op_o = SD;  // STORE_U64
        endcase
      end
      PVM_OP_JUMP_IND: begin
        fu_o = CTRL_FLOW; op_o = JALR; rs1_o = g_lo; imm_o = imm_ri;
        use_imm_o = 1'b1; is_jump_o = 1'b1;
      end

      // ---- 2reg + imm: indirect loads/stores + reg-imm arithmetic ----
      PVM_OP_STORE_IND_U8, PVM_OP_STORE_IND_U16,
      PVM_OP_STORE_IND_U32, PVM_OP_STORE_IND_U64: begin
        fu_o = STORE; rs1_o = g_hi; rs2_o = g_lo; imm_o = imm_ri; use_imm_o = 1'b1;
        unique case (opcode_i)
          PVM_OP_STORE_IND_U8:  op_o = SB;
          PVM_OP_STORE_IND_U16: op_o = SH;
          PVM_OP_STORE_IND_U32: op_o = SW;
          default:              op_o = SD;
        endcase
      end
      PVM_OP_LOAD_IND_U8, PVM_OP_LOAD_IND_I8, PVM_OP_LOAD_IND_U16, PVM_OP_LOAD_IND_I16,
      PVM_OP_LOAD_IND_U32, PVM_OP_LOAD_IND_I32, PVM_OP_LOAD_IND_U64: begin
        fu_o = LOAD; rd_o = g_lo; rs1_o = g_hi; imm_o = imm_ri; use_imm_o = 1'b1;
        unique case (opcode_i)
          PVM_OP_LOAD_IND_U8:  op_o = LBU;
          PVM_OP_LOAD_IND_I8:  op_o = LB;
          PVM_OP_LOAD_IND_U16: op_o = LHU;
          PVM_OP_LOAD_IND_I16: op_o = LH;
          PVM_OP_LOAD_IND_U32: op_o = LWU;
          PVM_OP_LOAD_IND_I32: op_o = LW;
          default:             op_o = LD;
        endcase
      end
      PVM_OP_ADD_IMM_32, PVM_OP_ADD_IMM_64, PVM_OP_AND_IMM, PVM_OP_OR_IMM,
      PVM_OP_XOR_IMM, PVM_OP_MUL_IMM_32, PVM_OP_MUL_IMM_64,
      PVM_OP_SET_LT_U_IMM, PVM_OP_SET_LT_S_IMM,
      PVM_OP_SHLO_L_IMM_32, PVM_OP_SHLO_R_IMM_32, PVM_OP_SHAR_R_IMM_32,
      PVM_OP_SHLO_L_IMM_64, PVM_OP_SHLO_R_IMM_64, PVM_OP_SHAR_R_IMM_64: begin
        rd_o = g_lo; rs1_o = g_hi; imm_o = imm_ri; use_imm_o = 1'b1; fu_o = ALU;
        unique case (opcode_i)
          PVM_OP_ADD_IMM_32:   op_o = ADDW;
          PVM_OP_ADD_IMM_64:   op_o = ADD;
          PVM_OP_AND_IMM:      op_o = ANDL;
          PVM_OP_OR_IMM:       op_o = ORL;
          PVM_OP_XOR_IMM:      op_o = XORL;
          PVM_OP_MUL_IMM_32:   begin op_o = MULW; fu_o = MULT; end
          PVM_OP_MUL_IMM_64:   begin op_o = MUL;  fu_o = MULT; end
          PVM_OP_SET_LT_U_IMM: op_o = SLTU;
          PVM_OP_SET_LT_S_IMM: op_o = SLTS;
          PVM_OP_SHLO_L_IMM_32:op_o = SLLW;
          PVM_OP_SHLO_R_IMM_32:op_o = SRLW;
          PVM_OP_SHAR_R_IMM_32:op_o = SRAW;
          PVM_OP_SHLO_L_IMM_64:op_o = SLL;
          PVM_OP_SHLO_R_IMM_64:op_o = SRL;
          default:             op_o = SRA;  // SHAR_R_IMM_64
        endcase
      end

      // ---- 2reg unary ----
      PVM_OP_MOVE_REG: begin fu_o = ALU; op_o = ADD; rd_o = g_lo; rs1_o = g_hi; rs2_o = 5'd0; end
      PVM_OP_COUNT_SET_BITS_64:    begin fu_o = ALU; op_o = CPOP;  rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_COUNT_SET_BITS_32:    begin fu_o = ALU; op_o = CPOPW; rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_LEADING_ZERO_BITS_64: begin fu_o = ALU; op_o = CLZ;   rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_LEADING_ZERO_BITS_32: begin fu_o = ALU; op_o = CLZW;  rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_TRAILING_ZERO_BITS_64:begin fu_o = ALU; op_o = CTZ;   rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_TRAILING_ZERO_BITS_32:begin fu_o = ALU; op_o = CTZW;  rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_SIGN_EXTEND_8:        begin fu_o = ALU; op_o = SEXTB; rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_SIGN_EXTEND_16:       begin fu_o = ALU; op_o = SEXTH; rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_ZERO_EXTEND_16:       begin fu_o = ALU; op_o = ZEXTH; rd_o = g_lo; rs1_o = g_hi; end
      PVM_OP_REVERSE_BYTES:        begin fu_o = ALU; op_o = REV8;  rd_o = g_lo; rs1_o = g_hi; end

      // ---- unconditional jump (front-resolved redirect; NOP to the backend) ----
      PVM_OP_JUMP: begin
        fu_o = ALU; op_o = ADD; rd_o = 5'd0; rs1_o = 5'd0; rs2_o = 5'd0;  // NOP -> x0
        is_jump_o = 1'b1;
        branch_target_o = pc_i + imm_ec[VLEN-1:0];
      end

      // ---- 2reg + offset: register-register branches ----
      PVM_OP_BRANCH_EQ, PVM_OP_BRANCH_NE, PVM_OP_BRANCH_LT_U, PVM_OP_BRANCH_LT_S,
      PVM_OP_BRANCH_GE_U, PVM_OP_BRANCH_GE_S: begin
        fu_o = CTRL_FLOW; rs1_o = g_lo; rs2_o = g_hi; is_branch_o = 1'b1;
        branch_target_o = pc_i + imm_ri[VLEN-1:0];
        imm_o = imm_ri;  // offset -> fu_data.imm; branch_unit target = pc + offset
        unique case (opcode_i)
          PVM_OP_BRANCH_EQ:   op_o = EQ;
          PVM_OP_BRANCH_NE:   op_o = NE;
          PVM_OP_BRANCH_LT_U: op_o = LTU;
          PVM_OP_BRANCH_LT_S: op_o = LTS;
          PVM_OP_BRANCH_GE_U: op_o = GEU;
          default:            op_o = GES;  // BRANCH_GE_S
        endcase
      end

      // ---- 3reg ALU / MUL ----
      PVM_OP_ADD_32, PVM_OP_SUB_32, PVM_OP_MUL_32, PVM_OP_DIV_U_32, PVM_OP_DIV_S_32,
      PVM_OP_REM_U_32, PVM_OP_REM_S_32, PVM_OP_SHLO_L_32, PVM_OP_SHLO_R_32, PVM_OP_SHAR_R_32,
      PVM_OP_ADD_64, PVM_OP_SUB_64, PVM_OP_MUL_64, PVM_OP_DIV_U_64, PVM_OP_DIV_S_64,
      PVM_OP_REM_U_64, PVM_OP_REM_S_64, PVM_OP_SHLO_L_64, PVM_OP_SHLO_R_64, PVM_OP_SHAR_R_64,
      PVM_OP_AND, PVM_OP_XOR, PVM_OP_OR, PVM_OP_MUL_UPPER_S_S, PVM_OP_MUL_UPPER_U_U,
      PVM_OP_MUL_UPPER_S_U, PVM_OP_SET_LT_U, PVM_OP_SET_LT_S, PVM_OP_ROT_L_64, PVM_OP_ROT_L_32,
      PVM_OP_ROT_R_64, PVM_OP_ROT_R_32, PVM_OP_AND_INV, PVM_OP_OR_INV, PVM_OP_XNOR,
      PVM_OP_MAX, PVM_OP_MAX_U, PVM_OP_MIN, PVM_OP_MIN_U,
      PVM_OP_CMOV_IZ, PVM_OP_CMOV_NZ: begin
        rd_o = g_d3; rs1_o = g_lo; rs2_o = g_hi; fu_o = ALU;
        unique case (opcode_i)
          PVM_OP_ADD_32:        op_o = ADDW;
          PVM_OP_SUB_32:        op_o = SUBW;
          PVM_OP_ADD_64:        op_o = ADD;
          PVM_OP_SUB_64:        op_o = SUB;
          PVM_OP_SHLO_L_32:     op_o = SLLW;
          PVM_OP_SHLO_R_32:     op_o = SRLW;
          PVM_OP_SHAR_R_32:     op_o = SRAW;
          PVM_OP_SHLO_L_64:     op_o = SLL;
          PVM_OP_SHLO_R_64:     op_o = SRL;
          PVM_OP_SHAR_R_64:     op_o = SRA;
          PVM_OP_AND:           op_o = ANDL;
          PVM_OP_XOR:           op_o = XORL;
          PVM_OP_OR:            op_o = ORL;
          PVM_OP_SET_LT_U:      op_o = SLTU;
          PVM_OP_SET_LT_S:      op_o = SLTS;
          PVM_OP_ROT_L_64:      op_o = ROL;
          PVM_OP_ROT_L_32:      op_o = ROLW;
          PVM_OP_ROT_R_64:      op_o = ROR;
          PVM_OP_ROT_R_32:      op_o = RORW;
          PVM_OP_AND_INV:       op_o = ANDN;
          PVM_OP_OR_INV:        op_o = ORN;
          PVM_OP_XNOR:          op_o = XNOR;
          PVM_OP_MAX:           op_o = MAX;
          PVM_OP_MAX_U:         op_o = MAXU;
          PVM_OP_MIN:           op_o = MIN;
          PVM_OP_MIN_U:         op_o = MINU;
          PVM_OP_CMOV_IZ:       op_o = XHEAD_MVEQZ;  // rd = (rs2==0)?rs1:rd
          PVM_OP_CMOV_NZ:       op_o = XHEAD_MVNEZ;
          PVM_OP_MUL_32:        begin op_o = MULW;   fu_o = MULT; end
          PVM_OP_MUL_64:        begin op_o = MUL;    fu_o = MULT; end
          PVM_OP_MUL_UPPER_S_S: begin op_o = MULH;   fu_o = MULT; end
          PVM_OP_MUL_UPPER_U_U: begin op_o = MULHU;  fu_o = MULT; end
          PVM_OP_MUL_UPPER_S_U: begin op_o = MULHSU; fu_o = MULT; end
          PVM_OP_DIV_U_32:      begin op_o = DIVUW;  fu_o = MULT; end
          PVM_OP_DIV_S_32:      begin op_o = DIVW;   fu_o = MULT; end
          PVM_OP_REM_U_32:      begin op_o = REMUW;  fu_o = MULT; end
          PVM_OP_REM_S_32:      begin op_o = REMW;   fu_o = MULT; end
          PVM_OP_DIV_U_64:      begin op_o = DIVU;   fu_o = MULT; end
          PVM_OP_DIV_S_64:      begin op_o = DIV;    fu_o = MULT; end
          PVM_OP_REM_U_64:      begin op_o = REMU;   fu_o = MULT; end
          default:              begin op_o = REM;    fu_o = MULT; end  // REM_S_64
        endcase
      end

      // ---- privileged CSR (reg_reg_imm: rd=b1[7:4], rs1=b1[3:0], imm=csr) ----
      PVM_OP_CSR_RW, PVM_OP_CSR_RS, PVM_OP_CSR_RC,
      PVM_OP_CSR_RWI, PVM_OP_CSR_RSI, PVM_OP_CSR_RCI: begin
        fu_o = CSR; rd_o = g_hi; rs1_o = g_lo; imm_o = imm_ri; use_imm_o = 1'b1;
        unique case (opcode_i)
          PVM_OP_CSR_RW, PVM_OP_CSR_RWI: op_o = CSR_WRITE;
          PVM_OP_CSR_RS, PVM_OP_CSR_RSI: op_o = CSR_SET;
          default:                       op_o = CSR_CLEAR;  // RC / RCI
        endcase
      end
      PVM_OP_SFENCE_VMA: begin fu_o = CSR; op_o = SFENCE_VMA; rs1_o = g_hi; rs2_o = g_lo; end

      default: begin
        // valid-but-deferred (need macro-expansion/operand-reverse) vs truly illegal
        if (pvm_is_valid_opcode(opcode_i)) unsupported_o = 1'b1;
        else                               illegal_o     = 1'b1;
      end
    endcase
  end

endmodule
