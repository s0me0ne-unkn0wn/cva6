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
    input  logic            phase_i,         // micro-op phase for macro-expanded ops (imm-branch)
    output logic            two_uop_o,       // this op expands to 2 uops (phase 0 then phase 1)
    // decoded micro-op (toward scoreboard_entry_t)
    output fu_t             fu_o,
    output fu_op            op_o,
    output logic [4:0]      rd_o,
    output logic [4:0]      rs1_o,
    output logic [4:0]      rs2_o,
    output logic [63:0]     imm_o,           // immediate / store data / target imm
    output logic            use_imm_o,       // operand B is the immediate
    output logic            is_branch_o,     // conditional branch (cond in op_o)
    output logic            is_jump_o,       // unconditional jump (target known at decode)
    output logic            is_djump_o,      // dynamic indirect jump (jump_ind): djump(reg+imm)
    output logic [VLEN-1:0] branch_target_o, // PVM instruction-counter target
    output logic            is_hostcall_o,   // ecalli
    output logic [63:0]     hostcall_id_o,
    output logic            is_trap_o,       // trap opcode (panic)
    output logic            is_eret_o,       // mret/sret: return-from-handler (PVM-pc redirect to mepc/sepc)
    output logic            is_csr_fence_o,  // B5: a CSR write to a flush-class CSR (mstatus/sstatus/satp/mstatush)
    output logic            is_store_imm_o,  // a store_imm 2-uop macro (serialize: drain the store before the next instr)
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
  // CSR source register: the linker lowers a RISC-V `csrr*` whose rs1=x0 (e.g. `csrr
  // mhartid` == `csrrs rd,mhartid,x0`, a pure read) to a PVM csr_rs/rc/rw with source =
  // RawReg(0) (PolkaVM has no zero reg; Reg::RA==0 doubles as the x0 stand-in, see
  // polkavm-linker program_from_elf.rs:661/8826-8834). So in the CSR *source* slot a high
  // nibble of 0 means x0/zero, NOT x1(ra): map it to x0 so set/clear add no bits (legal on
  // read-only CSRs like mhartid) and a write supplies 0. Data-reg slots keep g_hi (+1).
  logic [4:0] g_hi_csr;
  assign g_hi_csr = (pvm_reg_hi(b1) == 4'd0) ? 5'd0 : g_hi;

  // immediate lengths (graypaper): reg+imm / 2reg+imm / 2reg+off use
  // lX = min(4, max(0, skip-1)), immediate at byte offset 2. ecalli uses
  // lX = min(4, skip) at offset 1. load_imm_64 uses 8 bytes at offset 2.
  int unsigned len_ri, len_ec;
  logic [63:0] imm_ri, imm_ec, imm64;
  // reg + 2 immediates (imm-branch 81-90): lX = min(4, b1[6:4]), imm_X @offset 2;
  // lY = min(4, max(0, skip - lX - 1)), imm_Y(offset) @offset 2+lX, target = pc + imm_Y.
  int unsigned len_x, len_y, len_x2, len_y2;
  logic [63:0] imm_x, imm_y, imm_x2, imm_y2;
  // 2 immediates, no register (store_imm absolute 30-33): read_args_imm2 strips the
  // opcode so chunk[0]=b1 is BOTH the imm1-length selector (low 3 bits) AND unused as a
  // reg. lA = min(4, b1[2:0]), imm_A(addr) @offset 2; lB = min(4, max(0, skip - lA - 1)),
  // imm_B(value) @offset 2+lA. Same shape as the imm-branch slices but selector = b1[2:0].
  int unsigned len_a, len_b;
  logic [63:0] imm_a, imm_b;
  always_comb begin
    int unsigned skip_int;
    skip_int = int'(skip_i);
    len_ri = (skip_int == 0) ? 0 : ((skip_int - 1 > 4) ? 4 : (skip_int - 1));
    len_ec = (skip_int > 4) ? 4 : skip_int;
    imm_ri = pvm_sext(pvm_le_bytes(instr_window_i, 2, len_ri), len_ri);
    imm_ec = pvm_sext(pvm_le_bytes(instr_window_i, 1, len_ec), len_ec);
    imm64  = pvm_le_bytes(instr_window_i, 2, 8);
    len_x  = int'({1'b0, b1[6:4]});                  // (b1/16) mod 8
    if (len_x > 4) len_x = 4;
    len_y  = (skip_int > (len_x + 1)) ? (skip_int - len_x - 1) : 0;
    if (len_y > 4) len_y = 4;
    imm_x  = pvm_sext(pvm_le_bytes(instr_window_i, 2, len_x), len_x);
    imm_y  = pvm_sext(pvm_le_bytes(instr_window_i, 2 + len_x, len_y), len_y);
    // 2reg + 2imm family (load_imm_jump_ind 180): lX2 = min(4, c[i+2] mod 8),
    // imm_X @offset 3; lY2 = min(4, max(0, skip - lX2 - 2)), imm_Y @offset 3+lX2.
    len_x2 = int'({1'b0, b2[2:0]});
    if (len_x2 > 4) len_x2 = 4;
    len_y2 = (skip_int > (len_x2 + 2)) ? (skip_int - len_x2 - 2) : 0;
    if (len_y2 > 4) len_y2 = 4;
    imm_x2 = pvm_sext(pvm_le_bytes(instr_window_i, 3, len_x2), len_x2);
    imm_y2 = pvm_sext(pvm_le_bytes(instr_window_i, 3 + len_x2, len_y2), len_y2);
    // store_imm absolute (30-33): lA from b1[2:0], imm_A @offset 2, imm_B @offset 2+lA.
    len_a  = int'({1'b0, b1[2:0]});
    if (len_a > 4) len_a = 4;
    len_b  = (skip_int > (len_a + 1)) ? (skip_int - len_a - 1) : 0;
    if (len_b > 4) len_b = 4;
    imm_a  = pvm_sext(pvm_le_bytes(instr_window_i, 2, len_a), len_a);
    imm_b  = pvm_sext(pvm_le_bytes(instr_window_i, 2 + len_a, len_b), len_b);
  end

  localparam logic [4:0] PVM_SCRATCH = 5'd14;  // x14: outside PVM r0..r12 (==x1..x13)

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
    is_djump_o      = 1'b0;
    branch_target_o = '0;
    is_hostcall_o   = 1'b0;
    hostcall_id_o   = 64'd0;
    is_trap_o       = 1'b0;
    is_eret_o       = 1'b0;
    is_csr_fence_o  = 1'b0;
    is_store_imm_o  = 1'b0;
    illegal_o       = 1'b0;
    unsupported_o   = 1'b0;
    two_uop_o       = 1'b0;

    unique case (opcode_i)
      // ---- no-arg ----
      PVM_OP_TRAP:        is_trap_o = 1'b1;
      PVM_OP_FALLTHROUGH: fu_o = NONE;                       // sequential fallthrough
      PVM_OP_UNLIKELY:    fu_o = NONE;                       // hint, no-op
      PVM_OP_MRET:      begin fu_o = CSR; op_o = MRET; is_eret_o = 1'b1; end
      PVM_OP_SRET:      begin fu_o = CSR; op_o = SRET; is_eret_o = 1'b1; end
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
        // Dynamic jump: the backend branch_unit (JALR) computes a = reg_A + imm_X;
        // pvm_fetch suspends (is_djump) and resolves it through djump (jump table
        // or the r0 halt magic). NOT a decode-time (is_jump) target.
        fu_o = CTRL_FLOW; op_o = JALR; rs1_o = g_lo; imm_o = imm_ri;
        use_imm_o = 1'b1; is_djump_o = 1'b1;
      end

      // ---- reg + imm + offset: load_imm_jump = (reg_A = imm_X ; jump pc+imm_Y) ----
      // A STATIC jump (decode-time target, like PVM_OP_JUMP) that also loads reg_A. One uop:
      // the ALU does reg_A = 0 + imm_X (the load_imm) while is_jump redirects the front to
      // pc+imm_Y. REG_IMM_OFF args (same family as the imm-branches): imm_X = value @off2,
      // imm_Y = offset @off2+len_x. Used pervasively by OpenSBI for `ra = <ret> ; jump callee`.
      PVM_OP_LOAD_IMM_JUMP: begin
        fu_o = ALU; op_o = ADD; rd_o = g_lo; rs1_o = 5'd0; imm_o = imm_x; use_imm_o = 1'b1;
        is_jump_o = 1'b1;
        branch_target_o = pc_i + imm_y[VLEN-1:0];
      end

      // ---- 2reg + 2imm: load_imm_jump_ind = (reg_A = imm_X ; djump(reg_B + imm_Y)) ----
      // Macro-expanded: phase 0 loads reg_A, phase 1 is the dynamic jump on reg_B.
      PVM_OP_LOAD_IMM_JUMP_IND: begin
        two_uop_o = 1'b1;
        if (!phase_i) begin
          fu_o = ALU; op_o = ADD; rd_o = g_lo; rs1_o = 5'd0; imm_o = imm_x2; use_imm_o = 1'b1;
        end else begin
          fu_o = CTRL_FLOW; op_o = JALR; rs1_o = g_hi; imm_o = imm_y2;
          use_imm_o = 1'b1; is_djump_o = 1'b1;
        end
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

      // ---- reg + 2imm: branch reg-vs-immediate (macro-expanded into 2 uops) ----
      // CVA6's branch_unit compares two registers, so we synthesise:
      //   phase 0: load PVM_SCRATCH = imm_X   (ALU ADD scratch = x0 + imm_X)
      //   phase 1: branch <cmp> (rA, scratch), target = pc + imm_Y
      // LE/GT have no direct RISC-V branch op, so we swap operands (a<=b == b>=a,
      // a>b == b<a) using GE/LT instead.
      PVM_OP_BRANCH_EQ_IMM, PVM_OP_BRANCH_NE_IMM,
      PVM_OP_BRANCH_LT_U_IMM, PVM_OP_BRANCH_LE_U_IMM,
      PVM_OP_BRANCH_GE_U_IMM, PVM_OP_BRANCH_GT_U_IMM,
      PVM_OP_BRANCH_LT_S_IMM, PVM_OP_BRANCH_LE_S_IMM,
      PVM_OP_BRANCH_GE_S_IMM, PVM_OP_BRANCH_GT_S_IMM: begin
        two_uop_o = 1'b1;
        if (!phase_i) begin
          // phase 0: scratch = imm_X
          fu_o = ALU; op_o = ADD; rd_o = PVM_SCRATCH; rs1_o = 5'd0;
          imm_o = imm_x; use_imm_o = 1'b1;
        end else begin
          // phase 1: conditional branch rA vs scratch
          fu_o = CTRL_FLOW; is_branch_o = 1'b1;
          branch_target_o = pc_i + imm_y[VLEN-1:0];
          imm_o = imm_y;
          unique case (opcode_i)
            PVM_OP_BRANCH_EQ_IMM:   begin op_o = EQ;  rs1_o = g_lo;        rs2_o = PVM_SCRATCH; end
            PVM_OP_BRANCH_NE_IMM:   begin op_o = NE;  rs1_o = g_lo;        rs2_o = PVM_SCRATCH; end
            PVM_OP_BRANCH_LT_U_IMM: begin op_o = LTU; rs1_o = g_lo;        rs2_o = PVM_SCRATCH; end
            PVM_OP_BRANCH_GE_U_IMM: begin op_o = GEU; rs1_o = g_lo;        rs2_o = PVM_SCRATCH; end
            PVM_OP_BRANCH_LT_S_IMM: begin op_o = LTS; rs1_o = g_lo;        rs2_o = PVM_SCRATCH; end
            PVM_OP_BRANCH_GE_S_IMM: begin op_o = GES; rs1_o = g_lo;        rs2_o = PVM_SCRATCH; end
            PVM_OP_BRANCH_LE_U_IMM: begin op_o = GEU; rs1_o = PVM_SCRATCH; rs2_o = g_lo; end // rA<=X == X>=rA
            PVM_OP_BRANCH_GT_U_IMM: begin op_o = LTU; rs1_o = PVM_SCRATCH; rs2_o = g_lo; end // rA>X  == X<rA
            PVM_OP_BRANCH_LE_S_IMM: begin op_o = GES; rs1_o = PVM_SCRATCH; rs2_o = g_lo; end
            default:                begin op_o = LTS; rs1_o = PVM_SCRATCH; rs2_o = g_lo; end // GT_S
          endcase
        end
      end

      // ---- reg + 2imm: store-immediate, indirect (uN [reg_A + imm_X] = imm_Y) ----
      // 2-uop macro (mirrors the imm-branch): the STORE backend takes the store data from
      // rs2, so phase 0 loads PVM_SCRATCH = imm_Y (the value); phase 1 is a normal STORE
      // [reg_A + imm_X] = scratch. reg_imm2 family: reg_A = g_lo, imm_X(offset) = imm_x,
      // imm_Y(value) = imm_y (selector b1[6:4], same as the imm-branches).
      PVM_OP_STORE_IMM_IND_U8, PVM_OP_STORE_IMM_IND_U16,
      PVM_OP_STORE_IMM_IND_U32, PVM_OP_STORE_IMM_IND_U64: begin
        two_uop_o = 1'b1;
        is_store_imm_o = 1'b1;  // serialize: drain this store before the next instr (scratch-reuse hazard)
        if (!phase_i) begin
          fu_o = ALU; op_o = ADD; rd_o = PVM_SCRATCH; rs1_o = 5'd0;
          imm_o = imm_y; use_imm_o = 1'b1;
        end else begin
          fu_o = STORE; rs1_o = g_lo; rs2_o = PVM_SCRATCH; imm_o = imm_x; use_imm_o = 1'b1;
          unique case (opcode_i)
            PVM_OP_STORE_IMM_IND_U8:  op_o = SB;
            PVM_OP_STORE_IMM_IND_U16: op_o = SH;
            PVM_OP_STORE_IMM_IND_U32: op_o = SW;
            default:                  op_o = SD;  // STORE_IMM_IND_U64
          endcase
        end
      end

      // ---- 2imm: store-immediate, absolute (uN [imm_A] = imm_B) ----
      // Same 2-uop macro with no base register: phase 0 scratch = imm_B (value); phase 1
      // STORE [x0 + imm_A] = scratch. imm_imm family: imm_A(addr) = imm_a, imm_B(value) = imm_b.
      PVM_OP_STORE_IMM_U8, PVM_OP_STORE_IMM_U16,
      PVM_OP_STORE_IMM_U32, PVM_OP_STORE_IMM_U64: begin
        two_uop_o = 1'b1;
        is_store_imm_o = 1'b1;  // serialize: drain this store before the next instr (scratch-reuse hazard)
        if (!phase_i) begin
          fu_o = ALU; op_o = ADD; rd_o = PVM_SCRATCH; rs1_o = 5'd0;
          imm_o = imm_b; use_imm_o = 1'b1;
        end else begin
          fu_o = STORE; rs1_o = 5'd0; rs2_o = PVM_SCRATCH; imm_o = imm_a; use_imm_o = 1'b1;
          unique case (opcode_i)
            PVM_OP_STORE_IMM_U8:  op_o = SB;
            PVM_OP_STORE_IMM_U16: op_o = SH;
            PVM_OP_STORE_IMM_U32: op_o = SW;
            default:              op_o = SD;  // STORE_IMM_U64
          endcase
        end
      end

      // ---- reg + imm reverse-operand ALU ("imm OP reg") + cmov-imm (2-uop macros) ----
      // CVA6's reg-imm datapath puts the register in operand_a and the immediate in
      // operand_b (use_imm), i.e. it can only compute "reg OP imm". These ops need
      // "imm OP reg" (or a cmov whose moved value is an immediate), so we synthesise:
      //   phase 0: PVM_SCRATCH = imm   (ALU ADD scratch = x0 + imm_ri)
      //   phase 1: a reg-reg op with rs1 = scratch (the imm) and rs2 = reg_B (g_hi).
      // reg_reg_imm family: rd = g_lo (low nibble), reg = g_hi (high nibble), imm = imm_ri.
      //   NEG_ADD_IMM_{32,64} (141/154): d = imm - reg   -> SUB(W) scratch - reg     (program.rs s2.wrapping_sub(s1))
      //   SET_GT_U_IMM        (142):     d = (reg > imm) -> SLTU (imm < reg)         (program.rs u64::from(s1 > s2))
      //   SHLO_L_IMM_ALT_{32,64} (144/155), SHLO_R_IMM_ALT_64 (156): d = imm <</>> reg
      //     -- the polkavm2 "alt" visitor signature is (d, s2:reg, s1:imm) with s1 <</>> s2,
      //        i.e. the IMMEDIATE is shifted by the REGISTER -> SLL/SRL scratch by reg.
      PVM_OP_NEG_ADD_IMM_32, PVM_OP_NEG_ADD_IMM_64, PVM_OP_SET_GT_U_IMM,
      PVM_OP_SHLO_L_IMM_ALT_32, PVM_OP_SHLO_L_IMM_ALT_64, PVM_OP_SHLO_R_IMM_ALT_64: begin
        two_uop_o = 1'b1;
        if (!phase_i) begin
          fu_o = ALU; op_o = ADD; rd_o = PVM_SCRATCH; rs1_o = 5'd0;
          imm_o = imm_ri; use_imm_o = 1'b1;
        end else begin
          fu_o = ALU; rd_o = g_lo; rs1_o = PVM_SCRATCH; rs2_o = g_hi;
          unique case (opcode_i)
            PVM_OP_NEG_ADD_IMM_32:    op_o = SUBW;
            PVM_OP_NEG_ADD_IMM_64:    op_o = SUB;
            PVM_OP_SET_GT_U_IMM:      op_o = SLTU;
            PVM_OP_SHLO_L_IMM_ALT_32: op_o = SLLW;
            PVM_OP_SHLO_L_IMM_ALT_64: op_o = SLL;
            default:                  op_o = SRL;  // SHLO_R_IMM_ALT_64
          endcase
        end
      end

      // CMOV with an immediate moved-value (147/148). reg_reg_imm: rd = g_lo, condition
      // reg = g_hi, moved value = imm. CVA6's Xtheadcondmov needs the moved value in a
      // register (operand_a) and uses operand_c (read at result[4:0]) as the unchanged-rd
      // fallback. So phase 0 loads scratch = imm; phase 1 is th.mveqz/mvnez with
      // rs1 = scratch (moved value), rs2 = g_hi (condition), and imm_o = g_lo so the third
      // read port fetches the OLD rd value as the keep-rd fallback (use_imm stays 0).
      //   CMOV_IZ_IMM (147): rd = (reg == 0) ? imm : rd  -> th.mveqz (result = |opB ? imm : opA)
      //   CMOV_NZ_IMM (148): rd = (reg != 0) ? imm : rd  -> th.mvnez
      PVM_OP_CMOV_IZ_IMM, PVM_OP_CMOV_NZ_IMM: begin
        two_uop_o = 1'b1;
        if (!phase_i) begin
          fu_o = ALU; op_o = ADD; rd_o = PVM_SCRATCH; rs1_o = 5'd0;
          imm_o = imm_ri; use_imm_o = 1'b1;
        end else begin
          fu_o = ALU; rd_o = g_lo; rs1_o = PVM_SCRATCH; rs2_o = g_hi;
          imm_o = {59'd0, g_lo};  // result[4:0] = rd -> operand_c reads old rd (fallback)
          op_o  = (opcode_i == PVM_OP_CMOV_IZ_IMM) ? XHEAD_MVEQZ : XHEAD_MVNEZ;
        end
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
        // reg-reg cmov (218/219): d = (c {==,!=} 0) ? s : d. th.mveqz/mvnez supply the
        // keep-d fallback from operand_c, read at result[4:0]=imm_o[4:0]. Point it at the
        // DEST reg (g_d3) so an untaken cmov preserves d (default imm_o=0 wrongly reads x0=0).
        if (opcode_i inside {PVM_OP_CMOV_IZ, PVM_OP_CMOV_NZ}) imm_o = {59'd0, g_d3};
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
        // polkavm2 (jam_v1_privileged) CSR encoding: rd = LOW nibble, the CSR-source reg =
        // HIGH nibble (verified against polkatool disasm of real OpenSBI: `a5 = csrrw csr, t1`
        // has byte1 lo=a5/hi=t1). The earlier rd=hi/rs1=lo was backwards -- it self-agreed
        // with the hand-rolled gen_pvm_img generator (so the run-csr gate passed trivially) but
        // mis-decoded real compiled code: e.g. OpenSBI's `_reset_regs` `csrrw mscratch, ra`
        // (preserve ra) was decoded as writing ra, corrupting the return address -> `ret` to 0
        // -> _start re-ran -> boot-lottery spin. gen_pvm_img's b1() is flipped to match. B7.
        fu_o = CSR; rd_o = g_lo; rs1_o = g_hi_csr; imm_o = imm_ri; use_imm_o = 1'b1;
        // A csrrs/csrrc whose source is x0 (high nibble 0 -- the linker's x0/zimm=0 stand-in for
        // `csrr csr` reads, e.g. `csrr mhartid`) must NOT request a CSR write: CVA6's csr_regfile
        // sets csr_we=1 for any CSR_SET/CSR_CLEAR (it does not re-derive rs1==x0), so a SET/CLEAR
        // to a READ-ONLY CSR (mhartid 0xf14, mhpmcounter 0xb0x, mvendorid 0xf1x ...) traps ILLEGAL.
        // The stock RISC-V decoder.sv (290-321) maps rs1==x0 csrrs/csrrc -> CSR_READ; mirror that
        // here so the read is side-effect-free. csrrw/csrrwi always write (RISC-V: write 0 when
        // the source is x0), so they are unaffected.
        unique case (opcode_i)
          PVM_OP_CSR_RW, PVM_OP_CSR_RWI: op_o = CSR_WRITE;
          PVM_OP_CSR_RS, PVM_OP_CSR_RSI: op_o = (pvm_reg_hi(b1) == 4'd0) ? CSR_READ : CSR_SET;
          default:                       op_o = (pvm_reg_hi(b1) == 4'd0) ? CSR_READ : CSR_CLEAR; // RC/RCI
        endcase
        // B5: a WRITE to a flush-class CSR (mstatus/sstatus/satp/mstatush) raises flush_o in
        // csr_regfile (side-effects on translation/MPP etc.). In PVM mode that flush would
        // discard the YOUNGER in-flight uop (e.g. a following mret) -> the eret never commits
        // and pvm_fetch hangs. Flag it so pvm_fetch fences: it advances pc, suspends, and
        // resumes on the commit flush (the CSR write commits ALONE, like the eret). The CSR
        // address is the decoded immediate imm_ri; only its low 12 bits select the CSR.
        // CRITICAL -- fence WRITES ONLY: a pure CSR_READ (csrr, or csrrs/csrrc with rs1=x0)
        // does NOT write the CSR and raises NO flush, so csr_fence_resolved_i never pulses and
        // pvm_fetch would stay suspended FOREVER. (Fencing reads hung OpenSBI's
        // sbi_hart_switch_mode `csr_read(mstatus)` and every trap handler that reads mstatus ->
        // it blocked the S-mode handoff and the SBI console.) op_o (decoded just above) tells
        // write vs read.
        if (op_o != CSR_READ) begin
          unique case (imm_ri[11:0])
            12'h300, 12'h100, 12'h180, 12'h310: is_csr_fence_o = 1'b1;  // mstatus/sstatus/satp/mstatush
            default: ;
          endcase
        end
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
