// PolkaVM JAM v1 instruction decoder for CVA6.
// Sub-phase 3 of Phase 4.
//
// Decodes a 16-byte instruction chunk (per graypaper §pvm:99, max instr = 16 B)
// into PVM fields: opcode, registers, immediates, length, and exception flags.
//
// Operand parsing mirrors polkavm-common/src/program.rs:483-587 read_args_* functions.
// Immediate sign-extension mirrors graypaper §pvm:204 fnsext{n} and
// polkavm-common/src/varint.rs:read_simple_varint.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

module pvm_decoder
  import polkavm_pkg::*;
(
    // Subsystem clock / reset
    input  logic        clk_i,
    input  logic        rst_ni,

    // ---------------------------------------------------------------------------
    // Instruction chunk inputs
    // ---------------------------------------------------------------------------
    // 16-byte aligned instruction window; chunk_i[7:0] = opcode byte,
    // chunk_i[15:8] = first arg byte, …, chunk_i[127:112] = byte 15.
    input  logic [127:0] chunk_i,

    // skip_i = number of bytes in the instruction beyond the opcode byte
    // (i.e. instruction_length - 1). Range 0..15.
    // Computed by pvm_frontend from the bitmask (sub-phase 4); fed directly here.
    input  logic [4:0]   skip_i,

    // is_valid_opcode_i: asserted when chunk_i[7:0] is at a known opcode position
    // per the bitmask k (graypaper §pvm:79). If de-asserted, treat as illegal.
    input  logic         is_valid_opcode_i,

    // is_s_mode_i: current privilege level is PVM S-mode (supervisor).
    // Used for ecalli sentinel constraints.
    input  logic         is_s_mode_i,

    // ---------------------------------------------------------------------------
    // Decoded outputs
    // ---------------------------------------------------------------------------
    output pvm_op_t      pvm_op_o,

    // Register indices (4 bits; 0..12 valid, 13..15 → illegal_reg)
    output logic [3:0]   rs1_o,
    output logic [3:0]   rs2_o,
    output logic [3:0]   rd_o,

    // Immediates — sign-extended to 64 bits (upper 32 bits = sign extension of 32-bit imm)
    output logic [63:0]  imm_o,
    output logic [63:0]  imm2_o,

    // Exception / control flags
    output logic         is_illegal_op_o,
    output logic         is_illegal_reg_o,
    output logic         is_ecalli_o,
    output logic         is_ecalli_sentinel_mode_return_o,
    output logic         is_ecalli_sentinel_read_csr_o,

    // Instruction byte count consumed by this instruction (= skip_i + 1).
    output logic [4:0]   instruction_length_o,

    // has_rd_o: asserted when the decoded instruction writes a GPR result.
    // When clear, id_stage should set rd=x0 to suppress writeback.
    // (Needed because rd=0 in the decoder means PVM r0, not "no register".)
    output logic         has_rd_o,

    // has_rs1_o / has_rs2_o: asserted when the instruction actually reads
    // rs1 / rs2.  When clear, id_stage must map the register to x0 (NOT x1)
    // so that the CVA6 issue stage reads the zero-register rather than x1.
    // (Symmetric with has_rd_o: PVM r0 maps to x1, so we cannot blindly add
    // +1 to an unused register field whose default is 4'd0.)
    output logic         has_rs1_o,
    output logic         has_rs2_o,

    // Basic-block terminator: trap, fallthrough, jump, jump_indirect,
    // load_imm_and_jump, load_imm_and_jump_indirect, all branches.
    output logic         is_basic_block_term_o
);

  // -------------------------------------------------------------------------
  // Internal wires — raw byte lanes from chunk
  // -------------------------------------------------------------------------
  // chunk_i[7:0]   = opcode byte
  // chunk_i[15:8]  = byte 1 (first arg byte, "b1")
  // chunk_i[23:16] = byte 2 ("b2"), etc.
  logic [7:0] opcode;
  logic [7:0] b1, b2, b3, b4, b5, b6, b7, b8;

  assign opcode = chunk_i[7:0];
  assign b1     = chunk_i[15:8];
  assign b2     = chunk_i[23:16];
  assign b3     = chunk_i[31:24];
  assign b4     = chunk_i[39:32];
  assign b5     = chunk_i[47:40];
  assign b6     = chunk_i[55:48];
  assign b7     = chunk_i[63:56];
  assign b8     = chunk_i[71:64];

  // -------------------------------------------------------------------------
  // Valid-opcode lookup table
  // -------------------------------------------------------------------------
  // 256-entry ROM: valid_opcode[n] = 1 iff opcode n is defined in ISA_JamV1.
  // Derived from polkavm-common/src/program.rs:2274-2445 (ISA_JamV1 macro).
  logic valid_opcode_lut [0:255];

  always_comb begin : gen_valid_opcode_lut
    // Default: all illegal
    for (int i = 0; i < 256; i++) valid_opcode_lut[i] = 1'b0;
    // Group 1: no_args
    valid_opcode_lut[0]   = 1'b1;  // trap
    valid_opcode_lut[1]   = 1'b1;  // fallthrough
    valid_opcode_lut[2]   = 1'b1;  // unlikely
    // Group 9: imm
    valid_opcode_lut[10]  = 1'b1;  // ecalli
    // Group 13: reg_imm64
    valid_opcode_lut[20]  = 1'b1;  // load_imm64
    // Group 10: imm_imm
    valid_opcode_lut[30]  = 1'b1;  // store_imm_u8
    valid_opcode_lut[31]  = 1'b1;  // store_imm_u16
    valid_opcode_lut[32]  = 1'b1;  // store_imm_u32
    valid_opcode_lut[33]  = 1'b1;  // store_imm_u64
    // Group 8: offset
    valid_opcode_lut[40]  = 1'b1;  // jump
    // Group 2: reg_imm
    valid_opcode_lut[50]  = 1'b1;  // jump_indirect
    valid_opcode_lut[51]  = 1'b1;  // load_imm
    valid_opcode_lut[52]  = 1'b1;  // load_u8
    valid_opcode_lut[53]  = 1'b1;  // load_i8
    valid_opcode_lut[54]  = 1'b1;  // load_u16
    valid_opcode_lut[55]  = 1'b1;  // load_i16
    valid_opcode_lut[56]  = 1'b1;  // load_u32
    valid_opcode_lut[57]  = 1'b1;  // load_i32
    valid_opcode_lut[58]  = 1'b1;  // load_u64
    valid_opcode_lut[59]  = 1'b1;  // store_u8
    valid_opcode_lut[60]  = 1'b1;  // store_u16
    valid_opcode_lut[61]  = 1'b1;  // store_u32
    valid_opcode_lut[62]  = 1'b1;  // store_u64
    // Group 4: store_imm_indirect
    valid_opcode_lut[70]  = 1'b1;  // store_imm_indirect_u8
    valid_opcode_lut[71]  = 1'b1;  // store_imm_indirect_u16
    valid_opcode_lut[72]  = 1'b1;  // store_imm_indirect_u32
    valid_opcode_lut[73]  = 1'b1;  // store_imm_indirect_u64
    // Group 3: reg_imm_offset
    valid_opcode_lut[80]  = 1'b1;  // load_imm_and_jump
    valid_opcode_lut[81]  = 1'b1;  // branch_eq_imm
    valid_opcode_lut[82]  = 1'b1;  // branch_not_eq_imm
    valid_opcode_lut[83]  = 1'b1;  // branch_less_unsigned_imm
    valid_opcode_lut[84]  = 1'b1;  // branch_less_or_equal_unsigned_imm
    valid_opcode_lut[85]  = 1'b1;  // branch_greater_or_equal_unsigned_imm
    valid_opcode_lut[86]  = 1'b1;  // branch_greater_unsigned_imm
    valid_opcode_lut[87]  = 1'b1;  // branch_less_signed_imm
    valid_opcode_lut[88]  = 1'b1;  // branch_less_or_equal_signed_imm
    valid_opcode_lut[89]  = 1'b1;  // branch_greater_or_equal_signed_imm
    valid_opcode_lut[90]  = 1'b1;  // branch_greater_signed_imm
    // Group 11: reg_reg
    valid_opcode_lut[100] = 1'b1;  // move_reg
    valid_opcode_lut[101] = 1'b1;  // count_set_bits_64
    valid_opcode_lut[102] = 1'b1;  // count_set_bits_32
    valid_opcode_lut[103] = 1'b1;  // count_leading_zero_bits_64
    valid_opcode_lut[104] = 1'b1;  // count_leading_zero_bits_32
    valid_opcode_lut[105] = 1'b1;  // count_trailing_zero_bits_64
    valid_opcode_lut[106] = 1'b1;  // count_trailing_zero_bits_32
    valid_opcode_lut[107] = 1'b1;  // sign_extend_8
    valid_opcode_lut[108] = 1'b1;  // sign_extend_16
    valid_opcode_lut[109] = 1'b1;  // zero_extend_16
    valid_opcode_lut[110] = 1'b1;  // reverse_byte
    // Group 5: reg_reg_imm
    valid_opcode_lut[120] = 1'b1;  // store_indirect_u8
    valid_opcode_lut[121] = 1'b1;  // store_indirect_u16
    valid_opcode_lut[122] = 1'b1;  // store_indirect_u32
    valid_opcode_lut[123] = 1'b1;  // store_indirect_u64
    valid_opcode_lut[124] = 1'b1;  // load_indirect_u8
    valid_opcode_lut[125] = 1'b1;  // load_indirect_i8
    valid_opcode_lut[126] = 1'b1;  // load_indirect_u16
    valid_opcode_lut[127] = 1'b1;  // load_indirect_i16
    valid_opcode_lut[128] = 1'b1;  // load_indirect_u32
    valid_opcode_lut[129] = 1'b1;  // load_indirect_i32
    valid_opcode_lut[130] = 1'b1;  // load_indirect_u64
    valid_opcode_lut[131] = 1'b1;  // add_imm_32
    valid_opcode_lut[132] = 1'b1;  // and_imm
    valid_opcode_lut[133] = 1'b1;  // xor_imm
    valid_opcode_lut[134] = 1'b1;  // or_imm
    valid_opcode_lut[135] = 1'b1;  // mul_imm_32
    valid_opcode_lut[136] = 1'b1;  // set_less_than_unsigned_imm
    valid_opcode_lut[137] = 1'b1;  // set_less_than_signed_imm
    valid_opcode_lut[138] = 1'b1;  // shift_logical_left_imm_32
    valid_opcode_lut[139] = 1'b1;  // shift_logical_right_imm_32
    valid_opcode_lut[140] = 1'b1;  // shift_arithmetic_right_imm_32
    valid_opcode_lut[141] = 1'b1;  // negate_and_add_imm_32
    valid_opcode_lut[142] = 1'b1;  // set_greater_than_unsigned_imm
    valid_opcode_lut[143] = 1'b1;  // set_greater_than_signed_imm
    valid_opcode_lut[144] = 1'b1;  // shift_logical_left_imm_alt_32
    valid_opcode_lut[145] = 1'b1;  // shift_logical_right_imm_alt_32
    valid_opcode_lut[146] = 1'b1;  // shift_arithmetic_right_imm_alt_32
    valid_opcode_lut[147] = 1'b1;  // cmov_if_zero_imm
    valid_opcode_lut[148] = 1'b1;  // cmov_if_not_zero_imm
    valid_opcode_lut[149] = 1'b1;  // add_imm_64
    valid_opcode_lut[150] = 1'b1;  // mul_imm_64
    valid_opcode_lut[151] = 1'b1;  // shift_logical_left_imm_64
    valid_opcode_lut[152] = 1'b1;  // shift_logical_right_imm_64
    valid_opcode_lut[153] = 1'b1;  // shift_arithmetic_right_imm_64
    valid_opcode_lut[154] = 1'b1;  // negate_and_add_imm_64
    valid_opcode_lut[155] = 1'b1;  // shift_logical_left_imm_alt_64
    valid_opcode_lut[156] = 1'b1;  // shift_logical_right_imm_alt_64
    valid_opcode_lut[157] = 1'b1;  // shift_arithmetic_right_imm_alt_64
    valid_opcode_lut[158] = 1'b1;  // rotate_right_imm_64
    valid_opcode_lut[159] = 1'b1;  // rotate_right_imm_alt_64
    valid_opcode_lut[160] = 1'b1;  // rotate_right_imm_32
    valid_opcode_lut[161] = 1'b1;  // rotate_right_imm_alt_32
    // Group 6: reg_reg_offset
    valid_opcode_lut[170] = 1'b1;  // branch_eq
    valid_opcode_lut[171] = 1'b1;  // branch_not_eq
    valid_opcode_lut[172] = 1'b1;  // branch_less_unsigned
    valid_opcode_lut[173] = 1'b1;  // branch_less_signed
    valid_opcode_lut[174] = 1'b1;  // branch_greater_or_equal_unsigned
    valid_opcode_lut[175] = 1'b1;  // branch_greater_or_equal_signed
    // Group 12: reg_imm_imm
    valid_opcode_lut[180] = 1'b1;  // load_imm_and_jump_indirect
    // Group 7: reg_reg_reg
    valid_opcode_lut[190] = 1'b1;  // add_32
    valid_opcode_lut[191] = 1'b1;  // sub_32
    valid_opcode_lut[192] = 1'b1;  // mul_32
    valid_opcode_lut[193] = 1'b1;  // div_unsigned_32
    valid_opcode_lut[194] = 1'b1;  // div_signed_32
    valid_opcode_lut[195] = 1'b1;  // rem_unsigned_32
    valid_opcode_lut[196] = 1'b1;  // rem_signed_32
    valid_opcode_lut[197] = 1'b1;  // shift_logical_left_32
    valid_opcode_lut[198] = 1'b1;  // shift_logical_right_32
    valid_opcode_lut[199] = 1'b1;  // shift_arithmetic_right_32
    valid_opcode_lut[200] = 1'b1;  // add_64
    valid_opcode_lut[201] = 1'b1;  // sub_64
    valid_opcode_lut[202] = 1'b1;  // mul_64
    valid_opcode_lut[203] = 1'b1;  // div_unsigned_64
    valid_opcode_lut[204] = 1'b1;  // div_signed_64
    valid_opcode_lut[205] = 1'b1;  // rem_unsigned_64
    valid_opcode_lut[206] = 1'b1;  // rem_signed_64
    valid_opcode_lut[207] = 1'b1;  // shift_logical_left_64
    valid_opcode_lut[208] = 1'b1;  // shift_logical_right_64
    valid_opcode_lut[209] = 1'b1;  // shift_arithmetic_right_64
    valid_opcode_lut[210] = 1'b1;  // and
    valid_opcode_lut[211] = 1'b1;  // xor
    valid_opcode_lut[212] = 1'b1;  // or
    valid_opcode_lut[213] = 1'b1;  // mul_upper_signed_signed
    valid_opcode_lut[214] = 1'b1;  // mul_upper_unsigned_unsigned
    valid_opcode_lut[215] = 1'b1;  // mul_upper_signed_unsigned
    valid_opcode_lut[216] = 1'b1;  // set_less_than_unsigned
    valid_opcode_lut[217] = 1'b1;  // set_less_than_signed
    valid_opcode_lut[218] = 1'b1;  // cmov_if_zero
    valid_opcode_lut[219] = 1'b1;  // cmov_if_not_zero
    valid_opcode_lut[220] = 1'b1;  // rotate_left_64
    valid_opcode_lut[221] = 1'b1;  // rotate_left_32
    valid_opcode_lut[222] = 1'b1;  // rotate_right_64
    valid_opcode_lut[223] = 1'b1;  // rotate_right_32
    valid_opcode_lut[224] = 1'b1;  // and_inverted
    valid_opcode_lut[225] = 1'b1;  // or_inverted
    valid_opcode_lut[226] = 1'b1;  // xnor
    valid_opcode_lut[227] = 1'b1;  // maximum
    valid_opcode_lut[228] = 1'b1;  // maximum_unsigned
    valid_opcode_lut[229] = 1'b1;  // minimum
    valid_opcode_lut[230] = 1'b1;  // minimum_unsigned
  end

  // -------------------------------------------------------------------------
  // Sign-extension helper functions
  // -------------------------------------------------------------------------
  // pvm_sext_n: sign-extend a 32-bit value from n bytes (0..4).
  // Mirrors read_simple_varint in polkavm-common/src/varint.rs:97-100 and
  // graypaper §pvm:204 fnsext{n}.
  //   n=0 → result = 0
  //   n=1 → sign-extend from bit 7
  //   n=2 → sign-extend from bit 15
  //   n=3 → sign-extend from bit 23
  //   n=4 → full 32 bits, no sign extension needed (already 32-bit)
  function automatic logic [31:0] pvm_sext_n (
    input logic [31:0] val,
    input logic [2:0]  n    // 0..4
  );
    case (n)
      3'd0: pvm_sext_n = 32'd0;
      3'd1: pvm_sext_n = {{24{val[7]}},  val[7:0]};
      3'd2: pvm_sext_n = {{16{val[15]}}, val[15:0]};
      3'd3: pvm_sext_n = {{ 8{val[23]}}, val[23:0]};
      3'd4: pvm_sext_n = val;
      default: pvm_sext_n = 32'd0;
    endcase
  endfunction

  // -------------------------------------------------------------------------
  // Immediate extraction helpers
  // -------------------------------------------------------------------------
  // imm_length = min(4, skip).  The Rust TABLE_1/TABLE_2 logic reduces to:
  //   For a 1-immediate encoding: imm_length = clamp(0, skip, 4)
  //   For the first imm in 2-immediate: imm1_length = min(4, aux & 0x7)
  //   For the second imm: imm2_length = clamp(0, skip - imm1_length - offset, 4)
  //   where offset=1 for TABLE_1, offset=2 for TABLE_2.

  // Extract up to 4 bytes of immediate from byte positions [p+3:p+0] in chunk,
  // taking exactly 'n' bytes (0..4), sign-extended to 32 bits.
  // The 4 bytes starting at byte-offset 'p' within chunk:
  //   p=1 → b1,b2,b3,b4
  //   p=2 → b2,b3,b4,b5
  function automatic logic [31:0] read_imm_at (
    input logic [127:0] chunk,
    input logic [3:0]   byte_off,  // byte offset within chunk (1..11)
    input logic [2:0]   n          // byte count 0..4
  );
    logic [31:0] raw;
    // Build raw 4-byte word at byte_off
    raw = chunk[byte_off*8 +: 32];
    read_imm_at = pvm_sext_n(raw, n);
  endfunction

  // Clamp: result = clamp(0, value, 4) as 3-bit
  function automatic logic [2:0] clamp04 (input logic signed [5:0] value);
    if (value <= 0) clamp04 = 3'd0;
    else if (value >= 4) clamp04 = 3'd4;
    else clamp04 = value[2:0];
  endfunction

  // min(4, a) as 3-bit
  function automatic logic [2:0] min4 (input logic [4:0] a);
    min4 = (a >= 5'd4) ? 3'd4 : a[2:0];
  endfunction

  // -------------------------------------------------------------------------
  // Main decode logic
  // -------------------------------------------------------------------------
  pvm_op_t     dec_op;
  logic [3:0]  dec_rs1, dec_rs2, dec_rd;
  logic        dec_has_rd, dec_has_rs1, dec_has_rs2;
  logic [63:0] dec_imm, dec_imm2;
  logic        dec_illegal_op;
  logic        dec_is_bb_term;

  // Intermediate imm calc wires
  logic [2:0]  imm_len;    // for single-imm encodings
  logic [2:0]  imm1_len;   // first imm in two-imm encodings
  logic [2:0]  imm2_len;   // second imm in two-imm encodings
  logic [31:0] imm_raw;    // sign-extended 32-bit imm
  logic [31:0] imm1_raw, imm2_raw;
  // signed skip for clamping arithmetic
  logic signed [5:0] skip_s;
  assign skip_s = {1'b0, skip_i};

  always_comb begin : decode_main
    // Default: no-op / zero
    dec_op       = PVM_OP_TRAP;
    dec_rs1      = 4'd0;
    dec_rs2      = 4'd0;
    dec_rd       = 4'd0;
    dec_has_rd   = 1'b0;
    dec_has_rs1  = 1'b0;
    dec_has_rs2  = 1'b0;
    dec_imm      = 64'd0;
    dec_imm2     = 64'd0;
    dec_illegal_op = 1'b0;
    dec_is_bb_term = 1'b0;
    imm_len      = 3'd0;
    imm1_len     = 3'd0;
    imm2_len     = 3'd0;
    imm_raw      = 32'd0;
    imm1_raw     = 32'd0;
    imm2_raw     = 32'd0;

    // Check valid opcode via LUT
    if (!valid_opcode_lut[opcode] || !is_valid_opcode_i) begin
      dec_op         = PVM_OP_TRAP;
      dec_illegal_op = 1'b1;
      dec_is_bb_term = 1'b1;  // illegal → trap path terminates basic block
    end else begin
      // Dispatch by opcode
      unique casez (opcode)

        // -----------------------------------------------------------------
        // Group 1: no_args — opcode only, no operands (length = 1, skip=0)
        // -----------------------------------------------------------------
        8'd0: begin  // trap
          dec_op         = PVM_OP_TRAP;
          dec_is_bb_term = 1'b1;
        end
        8'd1: begin  // fallthrough
          dec_op         = PVM_OP_FALLTHROUGH;
          dec_is_bb_term = 1'b1;
        end
        8'd2: begin  // unlikely
          dec_op         = PVM_OP_UNLIKELY;
          dec_is_bb_term = 1'b0;
        end

        // -----------------------------------------------------------------
        // Group 9: imm — single immediate (ecalli)
        // read_args_imm: imm_length = min(4, skip), bytes from b1..b4
        // -----------------------------------------------------------------
        8'd10: begin  // ecalli
          dec_op  = PVM_OP_ECALLI;
          imm_len = min4(skip_i);
          imm_raw = read_imm_at(chunk_i, 4'd1, imm_len);
          dec_imm = {{32{imm_raw[31]}}, imm_raw};
        end

        // -----------------------------------------------------------------
        // Group 13: reg_imm64 — register + 64-bit literal
        // read_args_reg_imm64: b1[3:0]=reg, imm = b2..b9 (8 bytes, no sext)
        // length = 1 (opcode) + 1 (reg byte) + 8 (imm) = 10
        // -----------------------------------------------------------------
        8'd20: begin  // load_imm64
          dec_op  = PVM_OP_LOAD_IMM64;
          dec_rd     = b1[3:0];  // destination register (was incorrectly dec_rs1)
          dec_has_rd = 1'b1;
          dec_imm = chunk_i[79:16];  // bytes 2..9 = b2..b9 (64 bits)
        end

        // -----------------------------------------------------------------
        // Group 10: imm_imm — two immediates (store_imm_u*)
        // read_args_imm2: b1[2:0]=imm1_len, imm1 from b2, imm2 after
        // TABLE_1 (offset=1): imm1_len=min(4,b1[2:0]), imm2_len=clamp(0,skip-imm1_len-1,4)
        // -----------------------------------------------------------------
        8'd30, 8'd31, 8'd32, 8'd33: begin  // store_imm_u*
          case (opcode)
            8'd30: dec_op = PVM_OP_STORE_IMM_U8;
            8'd31: dec_op = PVM_OP_STORE_IMM_U16;
            8'd32: dec_op = PVM_OP_STORE_IMM_U32;
            default: dec_op = PVM_OP_STORE_IMM_U64;
          endcase
          imm1_len = min4({2'b00, b1[2:0]});   // min(4, b1[2:0])
          imm2_len = clamp04(skip_s - 6'(imm1_len) - 6'd1);
          imm1_raw = read_imm_at(chunk_i, 4'd2, imm1_len);  // starts at b2
          // imm2 starts after imm1 bytes
          imm2_raw = read_imm_at(chunk_i, 4'd2 + {1'b0, imm1_len}, imm2_len);
          dec_imm  = {{32{imm1_raw[31]}}, imm1_raw};
          dec_imm2 = {{32{imm2_raw[31]}}, imm2_raw};
        end

        // -----------------------------------------------------------------
        // Group 8: offset — single PC-relative offset (jump)
        // read_args_imm (same as Group 9): imm_length = min(4, skip)
        // -----------------------------------------------------------------
        8'd40: begin  // jump
          dec_op         = PVM_OP_JUMP;
          imm_len        = min4(skip_i);
          imm_raw        = read_imm_at(chunk_i, 4'd1, imm_len);
          // PVM branch offsets are relative to next_pc (pc + instr_len).
          // CVA6 branch_unit computes target = pc + imm, so adjust:
          // dec_imm = raw_imm + (skip + 1) = raw_imm + instr_len.
          dec_imm        = {{32{imm_raw[31]}}, imm_raw} + 64'(skip_i) + 64'd1;
          dec_is_bb_term = 1'b1;
        end

        // -----------------------------------------------------------------
        // Group 2: reg_imm — one register + one immediate
        // read_args_reg_imm: b1[3:0]=reg, imm_len=clamp(0,skip-1,4), imm from b2
        //
        // Register role depends on opcode:
        //   50 (jump_indirect):  b1[3:0] = rs1 (base reg for jump target)
        //   51 (load_imm):       b1[3:0] = rd  (destination; no register source)
        //   52-58 (load_*):      b1[3:0] = rd  (destination; address from imm)
        //   59-62 (store_*):     b1[3:0] = rs2 (value to store; address from imm)
        // -----------------------------------------------------------------
        8'd50, 8'd51, 8'd52, 8'd53, 8'd54, 8'd55,
        8'd56, 8'd57, 8'd58, 8'd59, 8'd60, 8'd61, 8'd62: begin
          case (opcode)
            8'd50: begin dec_op = PVM_OP_JUMP_INDIRECT;  dec_is_bb_term = 1'b1; end
            8'd51: dec_op = PVM_OP_LOAD_IMM;
            8'd52: dec_op = PVM_OP_LOAD_U8;
            8'd53: dec_op = PVM_OP_LOAD_I8;
            8'd54: dec_op = PVM_OP_LOAD_U16;
            8'd55: dec_op = PVM_OP_LOAD_I16;
            8'd56: dec_op = PVM_OP_LOAD_U32;
            8'd57: dec_op = PVM_OP_LOAD_I32;
            8'd58: dec_op = PVM_OP_LOAD_U64;
            8'd59: dec_op = PVM_OP_STORE_U8;
            8'd60: dec_op = PVM_OP_STORE_U16;
            8'd61: dec_op = PVM_OP_STORE_U32;
            default: dec_op = PVM_OP_STORE_U64;
          endcase
          imm_len = clamp04(skip_s - 6'd1);
          imm_raw = read_imm_at(chunk_i, 4'd2, imm_len);
          dec_imm = {{32{imm_raw[31]}}, imm_raw};
          // Assign register based on opcode role
          if (opcode == 8'd50) begin
            dec_rs1     = b1[3:0];  // jump_indirect: base register
            dec_has_rs1 = 1'b1;
          end else if (opcode >= 8'd59) begin
            dec_rs2     = b1[3:0];  // store_u*: value register
            dec_has_rs2 = 1'b1;
          end else begin
            dec_rd     = b1[3:0];  // load_imm / load_u*: destination register
            dec_has_rd = 1'b1;
          end
        end

        // -----------------------------------------------------------------
        // Group 4: store_imm_indirect — base_reg + imm_offset + imm_value
        // read_args_regs2_imm2: b1[3:0]=reg1, b1[7:4]=reg2 (unused here),
        //   b2[2:0]=imm1_len, imm1 from b3, imm2 after.
        // TABLE_2 (offset=2): imm1_len=min(4,b2[2:0]), imm2_len=clamp(0,skip-imm1_len-2,4)
        // For store_imm_indirect: reg=b1[3:0], offset_imm=imm1, value_imm=imm2
        // -----------------------------------------------------------------
        8'd70, 8'd71, 8'd72, 8'd73: begin  // store_imm_indirect_u*
          case (opcode)
            8'd70: dec_op = PVM_OP_STORE_IMM_INDIRECT_U8;
            8'd71: dec_op = PVM_OP_STORE_IMM_INDIRECT_U16;
            8'd72: dec_op = PVM_OP_STORE_IMM_INDIRECT_U32;
            default: dec_op = PVM_OP_STORE_IMM_INDIRECT_U64;
          endcase
          dec_rs1     = b1[3:0];
          dec_has_rs1 = 1'b1;
          // b1[7:4] is NOT a register in this encoding (unused nibble).
          // dec_rs2 / dec_has_rs2 remain at their defaults (0 / false).
          // Clamp imm1_len to bytes actually available after b1,b2.
          // Available = max(0, skip - 2); min with the declared length.
          imm1_len = min4({2'b00, b2[2:0]});  // min(4, b2[2:0])
          if (6'(imm1_len) > (skip_s - 6'd2))
            imm1_len = clamp04(skip_s - 6'd2);  // clamp to available bytes
          imm2_len = clamp04(skip_s - 6'(imm1_len) - 6'd2);
          imm1_raw = read_imm_at(chunk_i, 4'd3, imm1_len);  // starts at b3
          imm2_raw = read_imm_at(chunk_i, 4'd3 + {1'b0, imm1_len}, imm2_len);
          dec_imm  = {{32{imm1_raw[31]}}, imm1_raw};
          dec_imm2 = {{32{imm2_raw[31]}}, imm2_raw};
        end

        // -----------------------------------------------------------------
        // Group 3: reg_imm_offset — register + immediate + PC-offset
        // read_args_reg_imm2: b1[3:0]=reg, b1[7:4]=imm1_len_aux,
        //   imm1_len=min(4,b1[7:4]), imm2_len=clamp(0,skip-imm1_len-1,4)
        //   imm1 from b2, imm2 from b2+imm1_len
        // -----------------------------------------------------------------
        8'd80, 8'd81, 8'd82, 8'd83, 8'd84, 8'd85,
        8'd86, 8'd87, 8'd88, 8'd89, 8'd90: begin
          case (opcode)
            8'd80: begin dec_op = PVM_OP_LOAD_IMM_AND_JUMP;    dec_is_bb_term = 1'b1; end
            8'd81: begin dec_op = PVM_OP_BRANCH_EQ_IMM;        dec_is_bb_term = 1'b1; end
            8'd82: begin dec_op = PVM_OP_BRANCH_NOT_EQ_IMM;    dec_is_bb_term = 1'b1; end
            8'd83: begin dec_op = PVM_OP_BRANCH_LESS_UNSIGNED_IMM; dec_is_bb_term = 1'b1; end
            8'd84: begin dec_op = PVM_OP_BRANCH_LESS_OR_EQUAL_UNSIGNED_IMM; dec_is_bb_term = 1'b1; end
            8'd85: begin dec_op = PVM_OP_BRANCH_GREATER_OR_EQUAL_UNSIGNED_IMM; dec_is_bb_term = 1'b1; end
            8'd86: begin dec_op = PVM_OP_BRANCH_GREATER_UNSIGNED_IMM; dec_is_bb_term = 1'b1; end
            8'd87: begin dec_op = PVM_OP_BRANCH_LESS_SIGNED_IMM; dec_is_bb_term = 1'b1; end
            8'd88: begin dec_op = PVM_OP_BRANCH_LESS_OR_EQUAL_SIGNED_IMM; dec_is_bb_term = 1'b1; end
            8'd89: begin dec_op = PVM_OP_BRANCH_GREATER_OR_EQUAL_SIGNED_IMM; dec_is_bb_term = 1'b1; end
            default: begin dec_op = PVM_OP_BRANCH_GREATER_SIGNED_IMM; dec_is_bb_term = 1'b1; end
          endcase
          dec_rs1     = b1[3:0];
          dec_has_rs1 = 1'b1;
          imm1_len = min4({2'b00, b1[6:4]});  // min(4, b1[7:4] & 7) — high nibble
          imm2_len = clamp04(skip_s - 6'(imm1_len) - 6'd1);
          imm1_raw = read_imm_at(chunk_i, 4'd2, imm1_len);  // from b2
          imm2_raw = read_imm_at(chunk_i, 4'd2 + {1'b0, imm1_len}, imm2_len);
          dec_imm  = {{32{imm1_raw[31]}}, imm1_raw};
          // dec_imm2 = branch offset, relative to next_pc. Adjust for CVA6 pc+imm:
          dec_imm2 = {{32{imm2_raw[31]}}, imm2_raw} + 64'(skip_i) + 64'd1;
        end

        // -----------------------------------------------------------------
        // Group 11: reg_reg — two registers, no immediate
        // read_args_regs2: b1[3:0]=reg1, b1[7:4]=reg2
        // -----------------------------------------------------------------
        8'd100, 8'd101, 8'd102, 8'd103, 8'd104,
        8'd105, 8'd106, 8'd107, 8'd108, 8'd109, 8'd110: begin
          case (opcode)
            8'd100: dec_op = PVM_OP_MOVE_REG;
            8'd101: dec_op = PVM_OP_COUNT_SET_BITS_64;
            8'd102: dec_op = PVM_OP_COUNT_SET_BITS_32;
            8'd103: dec_op = PVM_OP_COUNT_LEADING_ZERO_BITS_64;
            8'd104: dec_op = PVM_OP_COUNT_LEADING_ZERO_BITS_32;
            8'd105: dec_op = PVM_OP_COUNT_TRAILING_ZERO_BITS_64;
            8'd106: dec_op = PVM_OP_COUNT_TRAILING_ZERO_BITS_32;
            8'd107: dec_op = PVM_OP_SIGN_EXTEND_8;
            8'd108: dec_op = PVM_OP_SIGN_EXTEND_16;
            8'd109: dec_op = PVM_OP_ZERO_EXTEND_16;
            default: dec_op = PVM_OP_REVERSE_BYTE;
          endcase
          dec_rd      = b1[3:0];  // reg1 (dest — polkavm read_args_regs2 reg1=dst)
          dec_has_rd  = 1'b1;
          dec_rs1     = b1[7:4];  // reg2 (source)
          dec_has_rs1 = 1'b1;
        end

        // -----------------------------------------------------------------
        // Group 5: reg_reg_imm — dst_reg + src_reg + immediate
        // read_args_regs2_imm: b1[3:0]=reg1, b1[7:4]=reg2, imm_len=clamp(0,skip-1,4), imm from b2
        //
        // SPECIAL CASE — *_imm_alt_* opcodes (144-146, 155-157, 159, 161):
        //   The "alt" form swaps which operand is the value vs the shift amount.
        //   In the non-alt form: rd = rs1 OP imm  (reg=value, imm=shift-amount).
        //   In the alt  form:   rd = imm OP rs1   (imm=value, reg=shift-amount).
        //   The ENCODING IS IDENTICAL — same byte layout. Only the semantic
        //   interpretation at execute time differs. The decoder just sets rd/rs1/imm
        //   normally; the ALU (sub-phase 5) handles the swap.
        //   See polkavm-common/src/program.rs:2350-2361 and plan Critic-issue note.
        // -----------------------------------------------------------------
        // -----------------------------------------------------------------
        // Group 5a: store_indirect — src_reg + base_reg + imm_offset
        // read_args_regs2_imm: b1[3:0]=src(value), b1[7:4]=base
        // (polkavm-common/src/program.rs read_args_regs2_imm: reg1=b1[3:0]=src, reg2=b1[7:4]=base)
        // CVA6 LSU: rs1 = base (operand_a → vaddr = rs1 + imm),
        //           rs2 = value (operand_b → data written)
        // -----------------------------------------------------------------
        8'd120, 8'd121, 8'd122, 8'd123: begin
          case (opcode)
            8'd120: dec_op = PVM_OP_STORE_INDIRECT_U8;
            8'd121: dec_op = PVM_OP_STORE_INDIRECT_U16;
            8'd122: dec_op = PVM_OP_STORE_INDIRECT_U32;
            default: dec_op = PVM_OP_STORE_INDIRECT_U64;
          endcase
          dec_rs1     = b1[7:4];   // base register → operand_a for vaddr computation
          dec_has_rs1 = 1'b1;
          dec_rs2     = b1[3:0];   // value(src) register → operand_b (data to store)
          dec_has_rs2 = 1'b1;
          imm_len = clamp04(skip_s - 6'd1);
          imm_raw = read_imm_at(chunk_i, 4'd2, imm_len);
          dec_imm = {{32{imm_raw[31]}}, imm_raw};
        end

        // -----------------------------------------------------------------
        // Group 5b: load_indirect — base_reg → dst_reg
        // read_args_regs2_imm: b1[3:0]=dst_reg, b1[7:4]=base_reg
        // CVA6 LSU: rs1 = base (operand_a → vaddr = rs1 + imm),
        //           rd  = destination register for loaded value
        // -----------------------------------------------------------------
        8'd124, 8'd125, 8'd126, 8'd127, 8'd128, 8'd129, 8'd130: begin
          case (opcode)
            8'd124: dec_op = PVM_OP_LOAD_INDIRECT_U8;
            8'd125: dec_op = PVM_OP_LOAD_INDIRECT_I8;
            8'd126: dec_op = PVM_OP_LOAD_INDIRECT_U16;
            8'd127: dec_op = PVM_OP_LOAD_INDIRECT_I16;
            8'd128: dec_op = PVM_OP_LOAD_INDIRECT_U32;
            8'd129: dec_op = PVM_OP_LOAD_INDIRECT_I32;
            default: dec_op = PVM_OP_LOAD_INDIRECT_U64;
          endcase
          dec_rs1     = b1[7:4];   // base register → operand_a for vaddr computation
          dec_has_rs1 = 1'b1;
          dec_rd      = b1[3:0];   // destination register for loaded value
          dec_has_rd  = 1'b1;
          imm_len = clamp04(skip_s - 6'd1);
          imm_raw = read_imm_at(chunk_i, 4'd2, imm_len);
          dec_imm = {{32{imm_raw[31]}}, imm_raw};
        end

        // -----------------------------------------------------------------
        // Group 5c: reg_imm ALU operations (dst + src + imm)
        // read_args_regs2_imm: b1[3:0]=dst_reg, b1[7:4]=src_reg
        // CVA6 ALU: rs1 = src (operand_a), rd = dst (result destination)
        // -----------------------------------------------------------------
        8'd131, 8'd132, 8'd133, 8'd134, 8'd135, 8'd136, 8'd137,
        8'd138, 8'd139, 8'd140, 8'd141, 8'd142, 8'd143,
        8'd144, 8'd145, 8'd146, 8'd147, 8'd148,
        8'd149, 8'd150, 8'd151, 8'd152, 8'd153, 8'd154,
        8'd155, 8'd156, 8'd157, 8'd158, 8'd159, 8'd160, 8'd161: begin
          case (opcode)
            8'd131: dec_op = PVM_OP_ADD_IMM_32;
            8'd132: dec_op = PVM_OP_AND_IMM;
            8'd133: dec_op = PVM_OP_XOR_IMM;
            8'd134: dec_op = PVM_OP_OR_IMM;
            8'd135: dec_op = PVM_OP_MUL_IMM_32;
            8'd136: dec_op = PVM_OP_SET_LESS_THAN_UNSIGNED_IMM;
            8'd137: dec_op = PVM_OP_SET_LESS_THAN_SIGNED_IMM;
            8'd138: dec_op = PVM_OP_SHIFT_LOGICAL_LEFT_IMM_32;
            8'd139: dec_op = PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_32;
            8'd140: dec_op = PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_32;
            8'd141: dec_op = PVM_OP_NEGATE_AND_ADD_IMM_32;
            8'd142: dec_op = PVM_OP_SET_GREATER_THAN_UNSIGNED_IMM;
            8'd143: dec_op = PVM_OP_SET_GREATER_THAN_SIGNED_IMM;
            // Alt shift variants: same byte encoding, swap semantic at execute time (ALU sub-phase 5).
            8'd144: dec_op = PVM_OP_SHIFT_LOGICAL_LEFT_IMM_ALT_32;
            8'd145: dec_op = PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_ALT_32;
            8'd146: dec_op = PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_ALT_32;
            8'd147: dec_op = PVM_OP_CMOV_IF_ZERO_IMM;
            8'd148: dec_op = PVM_OP_CMOV_IF_NOT_ZERO_IMM;
            8'd149: dec_op = PVM_OP_ADD_IMM_64;
            8'd150: dec_op = PVM_OP_MUL_IMM_64;
            8'd151: dec_op = PVM_OP_SHIFT_LOGICAL_LEFT_IMM_64;
            8'd152: dec_op = PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_64;
            8'd153: dec_op = PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_64;
            8'd154: dec_op = PVM_OP_NEGATE_AND_ADD_IMM_64;
            8'd155: dec_op = PVM_OP_SHIFT_LOGICAL_LEFT_IMM_ALT_64;
            8'd156: dec_op = PVM_OP_SHIFT_LOGICAL_RIGHT_IMM_ALT_64;
            8'd157: dec_op = PVM_OP_SHIFT_ARITHMETIC_RIGHT_IMM_ALT_64;
            8'd158: dec_op = PVM_OP_ROTATE_RIGHT_IMM_64;
            8'd159: dec_op = PVM_OP_ROTATE_RIGHT_IMM_ALT_64;
            8'd160: dec_op = PVM_OP_ROTATE_RIGHT_IMM_32;
            default: dec_op = PVM_OP_ROTATE_RIGHT_IMM_ALT_32;
          endcase
          dec_rd      = b1[3:0];  // dst register (result destination)
          dec_has_rd  = 1'b1;
          dec_rs1     = b1[7:4];  // src register (operand_a)
          dec_has_rs1 = 1'b1;
          imm_len = clamp04(skip_s - 6'd1);
          imm_raw = read_imm_at(chunk_i, 4'd2, imm_len);
          dec_imm = {{32{imm_raw[31]}}, imm_raw};
        end

        // -----------------------------------------------------------------
        // Group 6: reg_reg_offset — two registers + PC-relative offset (branches)
        // read_args_regs2_imm: b1[3:0]=reg1, b1[7:4]=reg2, imm_len=clamp(0,skip-1,4), imm from b2
        // -----------------------------------------------------------------
        8'd170, 8'd171, 8'd172, 8'd173, 8'd174, 8'd175: begin
          case (opcode)
            8'd170: dec_op = PVM_OP_BRANCH_EQ;
            8'd171: dec_op = PVM_OP_BRANCH_NOT_EQ;
            8'd172: dec_op = PVM_OP_BRANCH_LESS_UNSIGNED;
            8'd173: dec_op = PVM_OP_BRANCH_LESS_SIGNED;
            8'd174: dec_op = PVM_OP_BRANCH_GREATER_OR_EQUAL_UNSIGNED;
            default: dec_op = PVM_OP_BRANCH_GREATER_OR_EQUAL_SIGNED;
          endcase
          dec_rs1        = b1[3:0];
          dec_has_rs1    = 1'b1;
          dec_rs2        = b1[7:4];
          dec_has_rs2    = 1'b1;
          imm_len        = clamp04(skip_s - 6'd1);
          imm_raw        = read_imm_at(chunk_i, 4'd2, imm_len);
          // Branch offset relative to next_pc; adjust for CVA6 pc+imm convention.
          dec_imm        = {{32{imm_raw[31]}}, imm_raw} + 64'(skip_i) + 64'd1;
          dec_is_bb_term = 1'b1;
        end

        // -----------------------------------------------------------------
        // Group 12: reg_imm_imm — register + base-imm + dest-imm
        // read_args_reg_imm2: b1[3:0]=reg, b1[7:4]=imm1_len_nibble
        //   imm1_len=min(4,b1[7:4]&7), imm2_len=clamp(0,skip-imm1_len-1,4)
        //   imm1 from b2, imm2 from b2+imm1_len
        // -----------------------------------------------------------------
        8'd180: begin  // load_imm_and_jump_indirect
          dec_op      = PVM_OP_LOAD_IMM_AND_JUMP_INDIRECT;
          dec_rs1     = b1[3:0];
          dec_has_rs1 = 1'b1;
          imm1_len = min4({2'b00, b1[6:4]});  // min(4, b1[7:4] & 7)
          imm2_len = clamp04(skip_s - 6'(imm1_len) - 6'd1);
          imm1_raw = read_imm_at(chunk_i, 4'd2, imm1_len);
          imm2_raw = read_imm_at(chunk_i, 4'd2 + {1'b0, imm1_len}, imm2_len);
          dec_imm  = {{32{imm1_raw[31]}}, imm1_raw};
          dec_imm2 = {{32{imm2_raw[31]}}, imm2_raw};
          dec_is_bb_term = 1'b1;
        end

        // -----------------------------------------------------------------
        // Group 7: reg_reg_reg — three registers
        // read_args_regs3: b1[3:0]=reg2, b1[7:4]=reg3, b2[3:0]=reg1
        // (reg1=dst, reg2=src1, reg3=src2 per Rust convention)
        // -----------------------------------------------------------------
        8'd190, 8'd191, 8'd192, 8'd193, 8'd194, 8'd195, 8'd196,
        8'd197, 8'd198, 8'd199, 8'd200, 8'd201, 8'd202, 8'd203,
        8'd204, 8'd205, 8'd206, 8'd207, 8'd208, 8'd209,
        8'd210, 8'd211, 8'd212, 8'd213, 8'd214, 8'd215,
        8'd216, 8'd217, 8'd218, 8'd219,
        8'd220, 8'd221, 8'd222, 8'd223,
        8'd224, 8'd225, 8'd226, 8'd227, 8'd228, 8'd229, 8'd230: begin
          case (opcode)
            8'd190: dec_op = PVM_OP_ADD_32;
            8'd191: dec_op = PVM_OP_SUB_32;
            8'd192: dec_op = PVM_OP_MUL_32;
            8'd193: dec_op = PVM_OP_DIV_UNSIGNED_32;
            8'd194: dec_op = PVM_OP_DIV_SIGNED_32;
            8'd195: dec_op = PVM_OP_REM_UNSIGNED_32;
            8'd196: dec_op = PVM_OP_REM_SIGNED_32;
            8'd197: dec_op = PVM_OP_SHIFT_LOGICAL_LEFT_32;
            8'd198: dec_op = PVM_OP_SHIFT_LOGICAL_RIGHT_32;
            8'd199: dec_op = PVM_OP_SHIFT_ARITHMETIC_RIGHT_32;
            8'd200: dec_op = PVM_OP_ADD_64;
            8'd201: dec_op = PVM_OP_SUB_64;
            8'd202: dec_op = PVM_OP_MUL_64;
            8'd203: dec_op = PVM_OP_DIV_UNSIGNED_64;
            8'd204: dec_op = PVM_OP_DIV_SIGNED_64;
            8'd205: dec_op = PVM_OP_REM_UNSIGNED_64;
            8'd206: dec_op = PVM_OP_REM_SIGNED_64;
            8'd207: dec_op = PVM_OP_SHIFT_LOGICAL_LEFT_64;
            8'd208: dec_op = PVM_OP_SHIFT_LOGICAL_RIGHT_64;
            8'd209: dec_op = PVM_OP_SHIFT_ARITHMETIC_RIGHT_64;
            8'd210: dec_op = PVM_OP_AND;
            8'd211: dec_op = PVM_OP_XOR;
            8'd212: dec_op = PVM_OP_OR;
            8'd213: dec_op = PVM_OP_MUL_UPPER_SIGNED_SIGNED;
            8'd214: dec_op = PVM_OP_MUL_UPPER_UNSIGNED_UNSIGNED;
            8'd215: dec_op = PVM_OP_MUL_UPPER_SIGNED_UNSIGNED;
            8'd216: dec_op = PVM_OP_SET_LESS_THAN_UNSIGNED;
            8'd217: dec_op = PVM_OP_SET_LESS_THAN_SIGNED;
            8'd218: dec_op = PVM_OP_CMOV_IF_ZERO;
            8'd219: dec_op = PVM_OP_CMOV_IF_NOT_ZERO;
            8'd220: dec_op = PVM_OP_ROTATE_LEFT_64;
            8'd221: dec_op = PVM_OP_ROTATE_LEFT_32;
            8'd222: dec_op = PVM_OP_ROTATE_RIGHT_64;
            8'd223: dec_op = PVM_OP_ROTATE_RIGHT_32;
            8'd224: dec_op = PVM_OP_AND_INVERTED;
            8'd225: dec_op = PVM_OP_OR_INVERTED;
            8'd226: dec_op = PVM_OP_XNOR;
            8'd227: dec_op = PVM_OP_MAXIMUM;
            8'd228: dec_op = PVM_OP_MAXIMUM_UNSIGNED;
            8'd229: dec_op = PVM_OP_MINIMUM;
            default: dec_op = PVM_OP_MINIMUM_UNSIGNED;
          endcase
          // read_args_regs3: b1[3:0]=reg2, b1[7:4]=reg3, b2[3:0]=reg1
          dec_rd      = b2[3:0];  // reg1 = dst
          dec_has_rd  = 1'b1;
          dec_rs1     = b1[3:0];  // reg2 = src1
          dec_has_rs1 = 1'b1;
          dec_rs2     = b1[7:4];  // reg3 = src2
          dec_has_rs2 = 1'b1;
        end

        // -----------------------------------------------------------------
        // Default: any remaining unmapped opcode is illegal
        // -----------------------------------------------------------------
        default: begin
          dec_op         = PVM_OP_TRAP;
          dec_illegal_op = 1'b1;
          dec_is_bb_term = 1'b1;
        end

      endcase  // unique casez (opcode)
    end  // valid opcode check
  end  // always_comb decode_main

  // -------------------------------------------------------------------------
  // Illegal-register check (ADR-4)
  // -------------------------------------------------------------------------
  // Any reg index 13..15 triggers the illegal-reg trap.
  logic illegal_reg;
  assign illegal_reg = pvm_reg_is_illegal(dec_rs1) |
                       pvm_reg_is_illegal(dec_rs2) |
                       pvm_reg_is_illegal(dec_rd);

  // -------------------------------------------------------------------------
  // Ecalli sentinel detection
  // -------------------------------------------------------------------------
  logic is_ecalli;
  logic is_ecalli_sentinel_mode_return;
  logic is_ecalli_sentinel_read_csr;

  assign is_ecalli = (dec_op == PVM_OP_ECALLI) & ~dec_illegal_op;

  // Sentinel values are 32-bit comparisons on the raw imm (upper 32 bits = sext).
  // PVM_ECALLI_SENTINEL_MODE_RETURN = 0xFFFF_FFFF → dec_imm = 64'hFFFF_FFFF_FFFF_FFFF
  // PVM_ECALLI_SENTINEL_READ_CSR    = 0xFFFF_FFFE → dec_imm = 64'hFFFF_FFFF_FFFF_FFFE
  assign is_ecalli_sentinel_mode_return = is_ecalli &
      (dec_imm[31:0] == PVM_ECALLI_SENTINEL_MODE_RETURN);
  // read_csr sentinel requires S-mode (ADR-5).
  assign is_ecalli_sentinel_read_csr = is_ecalli & is_s_mode_i &
      (dec_imm[31:0] == PVM_ECALLI_SENTINEL_READ_CSR);

  // -------------------------------------------------------------------------
  // Instruction length
  // -------------------------------------------------------------------------
  assign instruction_length_o = skip_i + 5'd1;

  // -------------------------------------------------------------------------
  // Output assignments
  // -------------------------------------------------------------------------
  assign pvm_op_o                          = dec_op;
  assign rs1_o                             = dec_rs1;
  assign rs2_o                             = dec_rs2;
  assign rd_o                              = dec_rd;
  assign has_rd_o                          = dec_has_rd;
  assign has_rs1_o                         = dec_has_rs1;
  assign has_rs2_o                         = dec_has_rs2;
  assign imm_o                             = dec_imm;
  assign imm2_o                            = dec_imm2;
  assign is_illegal_op_o                   = dec_illegal_op;
  assign is_illegal_reg_o                  = illegal_reg;
  assign is_ecalli_o                       = is_ecalli;
  assign is_ecalli_sentinel_mode_return_o  = is_ecalli_sentinel_mode_return;
  assign is_ecalli_sentinel_read_csr_o     = is_ecalli_sentinel_read_csr;
  assign is_basic_block_term_o             = dec_is_bb_term;

endmodule
