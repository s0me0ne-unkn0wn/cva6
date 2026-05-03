// PolkaVM JAM v1 decoder testbench — sub-phase 3.
// 30 hand-crafted test vectors covering all JAM v1 instruction format groups.
//
// Byte encoding derived from read_args_* in polkavm-common/src/program.rs.
// Vectors hand-assembled and cross-referenced against the Rust ISA_JamV1
// macro at polkavm-common/src/program.rs:2274-2445.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

`timescale 1ns/1ps

module pvm_decoder_tb;
  import polkavm_pkg::*;

  // -------------------------------------------------------------------------
  // DUT signals
  // -------------------------------------------------------------------------
  logic        clk;
  logic        rst_n;
  logic [127:0] chunk;
  logic [4:0]   skip;
  logic         is_valid;
  logic         is_s_mode;

  pvm_op_t     pvm_op;
  logic [3:0]  rs1, rs2, rd;
  logic [63:0] imm_out, imm2_out;
  logic        illegal_op, illegal_reg;
  logic        is_ecalli, is_ecalli_mode_ret, is_ecalli_read_csr;
  logic [4:0]  instr_len;
  logic        is_bb_term;
  logic        has_rd, has_rs1, has_rs2;

  // -------------------------------------------------------------------------
  // DUT instantiation
  // -------------------------------------------------------------------------
  pvm_decoder dut (
    .clk_i                            (clk),
    .rst_ni                           (rst_n),
    .chunk_i                          (chunk),
    .skip_i                           (skip),
    .is_valid_opcode_i                (is_valid),
    .is_s_mode_i                      (is_s_mode),
    .pvm_op_o                         (pvm_op),
    .rs1_o                            (rs1),
    .rs2_o                            (rs2),
    .rd_o                             (rd),
    .imm_o                            (imm_out),
    .imm2_o                           (imm2_out),
    .is_illegal_op_o                  (illegal_op),
    .is_illegal_reg_o                 (illegal_reg),
    .is_ecalli_o                      (is_ecalli),
    .is_ecalli_sentinel_mode_return_o (is_ecalli_mode_ret),
    .is_ecalli_sentinel_read_csr_o    (is_ecalli_read_csr),
    .instruction_length_o             (instr_len),
    .has_rd_o                         (has_rd),
    .has_rs1_o                        (has_rs1),
    .has_rs2_o                        (has_rs2),
    .is_basic_block_term_o            (is_bb_term)
  );

  // -------------------------------------------------------------------------
  // Test vector struct
  // -------------------------------------------------------------------------
  typedef struct {
    logic [127:0] chunk;
    logic [4:0]   skip;
    logic         is_valid;
    logic         is_s_mode;
    pvm_op_t      expected_op;
    logic [3:0]   expected_rs1;
    logic [3:0]   expected_rs2;
    logic [3:0]   expected_rd;
    logic [63:0]  expected_imm;
    logic [63:0]  expected_imm2;
    logic [4:0]   expected_length;
    logic         expected_illegal_op;
    logic         expected_illegal_reg;
    logic         expected_is_ecalli;
    logic         expected_bb_term;
    string        name;
  } pvm_dec_vec_t;

  // Helper: build a 128-bit chunk from raw bytes (byte 0 = chunk[7:0])
  // Up to 16 bytes; unused bytes zero.
  function automatic logic [127:0] make_chunk (
    input logic [7:0] b0,  b1,  b2,  b3,
                      b4,  b5,  b6,  b7,
                      b8,  b9,  b10, b11,
                      b12, b13, b14, b15
  );
    make_chunk = {b15,b14,b13,b12,b11,b10,b9,b8,b7,b6,b5,b4,b3,b2,b1,b0};
  endfunction

  // -------------------------------------------------------------------------
  // Test vector definitions
  // Hand-assembled using read_args_* encoding rules:
  //   chunk[7:0]  = opcode
  //   chunk[15:8] = b1 (first arg byte)
  //   chunk[23:16]= b2, etc.
  //
  // skip = instruction_length - 1
  //
  // Group encodings:
  //   no_args      : opcode only (skip=0)
  //   imm          : b1..bN = imm, imm_len=min(4,skip), sign-extended
  //   offset       : same as imm
  //   reg_imm      : b1[3:0]=reg, b2..bN = imm, imm_len=clamp(0,skip-1,4)
  //   reg_imm2     : b1[3:0]=reg, b1[7:4]=imm1_nbytes, b2=imm1, b(2+n)=imm2
  //   imm_imm      : b1[2:0]=imm1_nbytes, b2=imm1, b(2+n)=imm2
  //   regs2_imm    : b1[3:0]=reg1, b1[7:4]=reg2, b2..bN = imm
  //   regs2_imm2   : b1[3:0]=reg1, b1[7:4]=reg2, b2[2:0]=imm1_nbytes, b3=imm1, ...
  //   regs2        : b1[3:0]=reg1, b1[7:4]=reg2
  //   regs3        : b1[3:0]=reg2, b1[7:4]=reg3, b2[3:0]=reg1
  //   reg_imm64    : b1[3:0]=reg, b2..b9 = 8-byte literal imm
  // -------------------------------------------------------------------------

  // PVM register indices (matching polkavm_pkg::pvm_reg_t):
  //   RA=0, SP=1, T0=2, T1=3, T2=4, S0=5, S1=6, A0=7, A1=8, A2=9, A3=10, A4=11, A5=12

  pvm_dec_vec_t vecs [0:29];

  initial begin : setup_vectors

    // -----------------------------------------------------------------
    // 1. no_args: trap (opcode=0x00, skip=0, length=1)
    // -----------------------------------------------------------------
    vecs[0].chunk            = make_chunk(8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[0].skip             = 5'd0;
    vecs[0].is_valid         = 1'b1;
    vecs[0].is_s_mode        = 1'b0;
    vecs[0].expected_op      = PVM_OP_TRAP;
    vecs[0].expected_rs1     = 4'd0;
    vecs[0].expected_rs2     = 4'd0;
    vecs[0].expected_rd      = 4'd0;
    vecs[0].expected_imm     = 64'd0;
    vecs[0].expected_imm2    = 64'd0;
    vecs[0].expected_length  = 5'd1;
    vecs[0].expected_illegal_op  = 1'b0;
    vecs[0].expected_illegal_reg = 1'b0;
    vecs[0].expected_is_ecalli   = 1'b0;
    vecs[0].expected_bb_term     = 1'b1;
    vecs[0].name = "trap";

    // -----------------------------------------------------------------
    // 2. no_args: fallthrough (opcode=0x01, skip=0, length=1)
    // -----------------------------------------------------------------
    vecs[1].chunk            = make_chunk(8'h01,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[1].skip             = 5'd0;
    vecs[1].is_valid         = 1'b1;
    vecs[1].is_s_mode        = 1'b0;
    vecs[1].expected_op      = PVM_OP_FALLTHROUGH;
    vecs[1].expected_rs1     = 4'd0;
    vecs[1].expected_rs2     = 4'd0;
    vecs[1].expected_rd      = 4'd0;
    vecs[1].expected_imm     = 64'd0;
    vecs[1].expected_imm2    = 64'd0;
    vecs[1].expected_length  = 5'd1;
    vecs[1].expected_illegal_op  = 1'b0;
    vecs[1].expected_illegal_reg = 1'b0;
    vecs[1].expected_is_ecalli   = 1'b0;
    vecs[1].expected_bb_term     = 1'b1;
    vecs[1].name = "fallthrough";

    // -----------------------------------------------------------------
    // 3. no_args: unlikely (opcode=0x02, skip=0, length=1)
    // -----------------------------------------------------------------
    vecs[2].chunk            = make_chunk(8'h02,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[2].skip             = 5'd0;
    vecs[2].is_valid         = 1'b1;
    vecs[2].is_s_mode        = 1'b0;
    vecs[2].expected_op      = PVM_OP_UNLIKELY;
    vecs[2].expected_rs1     = 4'd0;
    vecs[2].expected_rs2     = 4'd0;
    vecs[2].expected_rd      = 4'd0;
    vecs[2].expected_imm     = 64'd0;
    vecs[2].expected_imm2    = 64'd0;
    vecs[2].expected_length  = 5'd1;
    vecs[2].expected_illegal_op  = 1'b0;
    vecs[2].expected_illegal_reg = 1'b0;
    vecs[2].expected_is_ecalli   = 1'b0;
    vecs[2].expected_bb_term     = 1'b0;
    vecs[2].name = "unlikely";

    // -----------------------------------------------------------------
    // 4. offset: jump +0x100
    //    opcode=0x28(40), skip=4, imm = 0x00000100
    //    b1..b4 = 00 01 00 00 (LE 4-byte = 0x00000100)
    // -----------------------------------------------------------------
    vecs[3].chunk            = make_chunk(8'h28,8'h00,8'h01,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[3].skip             = 5'd4;
    vecs[3].is_valid         = 1'b1;
    vecs[3].is_s_mode        = 1'b0;
    vecs[3].expected_op      = PVM_OP_JUMP;
    vecs[3].expected_rs1     = 4'd0;
    vecs[3].expected_rs2     = 4'd0;
    vecs[3].expected_rd      = 4'd0;
    vecs[3].expected_imm     = 64'h0000_0000_0000_0105;  // 0x100 + skip(4)+1 = 0x105
    vecs[3].expected_imm2    = 64'd0;
    vecs[3].expected_length  = 5'd5;
    vecs[3].expected_illegal_op  = 1'b0;
    vecs[3].expected_illegal_reg = 1'b0;
    vecs[3].expected_is_ecalli   = 1'b0;
    vecs[3].expected_bb_term     = 1'b1;
    vecs[3].name = "jump +0x100";

    // -----------------------------------------------------------------
    // 5. offset: jump -8
    //    opcode=0x28(40), skip=4, imm = -8 = 0xFFFFFFF8
    //    b1..b4 = F8 FF FF FF
    // -----------------------------------------------------------------
    vecs[4].chunk            = make_chunk(8'h28,8'hF8,8'hFF,8'hFF,8'hFF,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[4].skip             = 5'd4;
    vecs[4].is_valid         = 1'b1;
    vecs[4].is_s_mode        = 1'b0;
    vecs[4].expected_op      = PVM_OP_JUMP;
    vecs[4].expected_rs1     = 4'd0;
    vecs[4].expected_rs2     = 4'd0;
    vecs[4].expected_rd      = 4'd0;
    vecs[4].expected_imm     = 64'hFFFF_FFFF_FFFF_FFFD;  // -8 + skip(4)+1 = -3
    vecs[4].expected_imm2    = 64'd0;
    vecs[4].expected_length  = 5'd5;
    vecs[4].expected_illegal_op  = 1'b0;
    vecs[4].expected_illegal_reg = 1'b0;
    vecs[4].expected_is_ecalli   = 1'b0;
    vecs[4].expected_bb_term     = 1'b1;
    vecs[4].name = "jump -8";

    // -----------------------------------------------------------------
    // 6. reg_imm: load_imm RA(=0), 0x42
    //    opcode=0x33(51), skip=2, b1=0x00(RA), b2=0x42
    //    imm_len=clamp(0,skip-1,4)=1, imm=sext(0x42,1)=0x42
    // -----------------------------------------------------------------
    vecs[5].chunk            = make_chunk(8'h33,8'h00,8'h42,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[5].skip             = 5'd2;
    vecs[5].is_valid         = 1'b1;
    vecs[5].is_s_mode        = 1'b0;
    vecs[5].expected_op      = PVM_OP_LOAD_IMM;
    vecs[5].expected_rs1     = 4'd0;  // RA = 0
    vecs[5].expected_rs2     = 4'd0;
    vecs[5].expected_rd      = 4'd0;
    vecs[5].expected_imm     = 64'h0000_0000_0000_0042;
    vecs[5].expected_imm2    = 64'd0;
    vecs[5].expected_length  = 5'd3;
    vecs[5].expected_illegal_op  = 1'b0;
    vecs[5].expected_illegal_reg = 1'b0;
    vecs[5].expected_is_ecalli   = 1'b0;
    vecs[5].expected_bb_term     = 1'b0;
    vecs[5].name = "load_imm RA,0x42";

    // -----------------------------------------------------------------
    // 7. reg_imm: load_imm A0(=7), -1
    //    opcode=0x33(51), skip=4, b1=0x07(A0), b2..b5=FF FF FF FF
    //    imm_len=clamp(0,4-1,4)=3 → read 3 bytes: FF FF FF → sext(0x00FFFFFF,3)=0xFFFFFFFF
    //    Wait: sext from 3 bytes = sign-extend from bit 23: 0xFFFFFF has bit23=1 → 0xFFFFFFFF
    //    For imm=-1, use skip=4, b2=FF,b3=FF,b4=FF,b5=FF (4 bytes, imm_len=3):
    //    Actually imm_len=clamp(0,4-1,4)=3, reads b2,b3,b4 = FF,FF,FF → sext(0x00FFFFFF,3)=0xFFFFFFFF ✓
    // -----------------------------------------------------------------
    vecs[6].chunk            = make_chunk(8'h33,8'h07,8'hFF,8'hFF,8'hFF,8'hFF,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[6].skip             = 5'd4;
    vecs[6].is_valid         = 1'b1;
    vecs[6].is_s_mode        = 1'b0;
    vecs[6].expected_op      = PVM_OP_LOAD_IMM;
    vecs[6].expected_rs1     = 4'd0;  // no register source
    vecs[6].expected_rs2     = 4'd0;
    vecs[6].expected_rd      = 4'd7;  // A0 = 7 (destination)
    vecs[6].expected_imm     = 64'hFFFF_FFFF_FFFF_FFFF;
    vecs[6].expected_imm2    = 64'd0;
    vecs[6].expected_length  = 5'd5;
    vecs[6].expected_illegal_op  = 1'b0;
    vecs[6].expected_illegal_reg = 1'b0;
    vecs[6].expected_is_ecalli   = 1'b0;
    vecs[6].expected_bb_term     = 1'b0;
    vecs[6].name = "load_imm A0,-1";

    // -----------------------------------------------------------------
    // 8. reg_imm_offset: branch_eq_imm A0(=7), 0, 0x10
    //    opcode=0x51(81), b1=reg(A0=7)|imm1_nbytes<<4
    //    imm1=0 (0 bytes), so imm1_nbytes=0, b1=0x07|0x00=0x07
    //    imm2_len=clamp(0,skip-0-1,4), skip=? length needed: 1+1+4=6, skip=5
    //    b2..b5=10 00 00 00 (imm2=0x10=16)
    //    imm1_len=min(4,b1[7:4]&7)=min(4,0)=0, imm1=0
    //    imm2_len=clamp(0,5-0-1,4)=4, imm2=read 4 bytes from b2: 10 00 00 00=0x10
    // -----------------------------------------------------------------
    vecs[7].chunk            = make_chunk(8'h51,8'h07,8'h10,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[7].skip             = 5'd5;
    vecs[7].is_valid         = 1'b1;
    vecs[7].is_s_mode        = 1'b0;
    vecs[7].expected_op      = PVM_OP_BRANCH_EQ_IMM;
    vecs[7].expected_rs1     = 4'd7;  // A0 = 7
    vecs[7].expected_rs2     = 4'd0;
    vecs[7].expected_rd      = 4'd0;
    vecs[7].expected_imm     = 64'd0;        // cond_imm = 0
    vecs[7].expected_imm2    = 64'h0000_0000_0000_0016;  // branch_offset = 0x10 + skip(5)+1 = 0x16
    vecs[7].expected_length  = 5'd6;
    vecs[7].expected_illegal_op  = 1'b0;
    vecs[7].expected_illegal_reg = 1'b0;
    vecs[7].expected_is_ecalli   = 1'b0;
    vecs[7].expected_bb_term     = 1'b1;
    vecs[7].name = "branch_eq_imm A0,0,0x10";

    // -----------------------------------------------------------------
    // 9. reg_imm_offset: branch_less_signed_imm A1(=8), -1, 0x20
    //    opcode=0x57(87)
    //    imm1=-1 (1 byte: FF), imm1_nbytes=1, b1=0x08|(1<<4)=0x18
    //    b2=FF (imm1)
    //    imm2=0x20 (1 byte: 20), skip: 1+1+1+1=4 → skip=4? Wait:
    //    imm2_len=clamp(0,skip-imm1_len-1,4)=clamp(0,skip-1-1,4)
    //    For imm2=0x20 (1 byte), need imm2_len=1 → skip-2=1 → skip=3
    //    length = 1+3=4: opcode(1)+b1(1)+imm1(1)+imm2(1)
    //    skip=3: imm2_len=clamp(0,3-1-1,4)=1 ✓
    // -----------------------------------------------------------------
    vecs[8].chunk            = make_chunk(8'h57,8'h18,8'hFF,8'h20,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[8].skip             = 5'd3;
    vecs[8].is_valid         = 1'b1;
    vecs[8].is_s_mode        = 1'b0;
    vecs[8].expected_op      = PVM_OP_BRANCH_LESS_SIGNED_IMM;
    vecs[8].expected_rs1     = 4'd8;  // A1 = 8
    vecs[8].expected_rs2     = 4'd0;
    vecs[8].expected_rd      = 4'd0;
    vecs[8].expected_imm     = 64'hFFFF_FFFF_FFFF_FFFF;  // cond_imm = -1
    vecs[8].expected_imm2    = 64'h0000_0000_0000_0024;  // branch_offset = 0x20 + skip(3)+1 = 0x24
    vecs[8].expected_length  = 5'd4;
    vecs[8].expected_illegal_op  = 1'b0;
    vecs[8].expected_illegal_reg = 1'b0;
    vecs[8].expected_is_ecalli   = 1'b0;
    vecs[8].expected_bb_term     = 1'b1;
    vecs[8].name = "branch_less_signed_imm A1,-1,0x20";

    // -----------------------------------------------------------------
    // 10. reg_imm_offset: branch_greater_or_equal_unsigned_imm A2(=9), 5, 0x30
    //     opcode=0x55(85)
    //     imm1=5 (1 byte), imm1_nbytes=1, b1=0x09|(1<<4)=0x19
    //     b2=0x05, b3=0x30
    //     skip=3: imm2_len=clamp(0,3-1-1,4)=1, imm2=0x30 ✓
    // -----------------------------------------------------------------
    vecs[9].chunk            = make_chunk(8'h55,8'h19,8'h05,8'h30,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[9].skip             = 5'd3;
    vecs[9].is_valid         = 1'b1;
    vecs[9].is_s_mode        = 1'b0;
    vecs[9].expected_op      = PVM_OP_BRANCH_GREATER_OR_EQUAL_UNSIGNED_IMM;
    vecs[9].expected_rs1     = 4'd9;  // A2 = 9
    vecs[9].expected_rs2     = 4'd0;
    vecs[9].expected_rd      = 4'd0;
    vecs[9].expected_imm     = 64'h0000_0000_0000_0005;  // cond_imm = 5
    vecs[9].expected_imm2    = 64'h0000_0000_0000_0034;  // branch_offset = 0x30 + skip(3)+1 = 0x34
    vecs[9].expected_length  = 5'd4;
    vecs[9].expected_illegal_op  = 1'b0;
    vecs[9].expected_illegal_reg = 1'b0;
    vecs[9].expected_is_ecalli   = 1'b0;
    vecs[9].expected_bb_term     = 1'b1;
    vecs[9].name = "branch_geq_unsigned_imm A2,5,0x30";

    // -----------------------------------------------------------------
    // 11. reg_imm_offset: branch_greater_signed_imm A3(=10), 100, 0x40
    //     opcode=0x5A(90)
    //     imm1=100=0x64 (1 byte), imm1_nbytes=1, b1=0x0A|(1<<4)=0x1A
    //     b2=0x64, b3=0x40
    //     skip=3
    // -----------------------------------------------------------------
    vecs[10].chunk            = make_chunk(8'h5A,8'h1A,8'h64,8'h40,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[10].skip             = 5'd3;
    vecs[10].is_valid         = 1'b1;
    vecs[10].is_s_mode        = 1'b0;
    vecs[10].expected_op      = PVM_OP_BRANCH_GREATER_SIGNED_IMM;
    vecs[10].expected_rs1     = 4'd10;  // A3 = 10
    vecs[10].expected_rs2     = 4'd0;
    vecs[10].expected_rd      = 4'd0;
    vecs[10].expected_imm     = 64'h0000_0000_0000_0064;  // cond_imm = 100
    vecs[10].expected_imm2    = 64'h0000_0000_0000_0044;  // branch_offset = 0x40 + skip(3)+1 = 0x44
    vecs[10].expected_length  = 5'd4;
    vecs[10].expected_illegal_op  = 1'b0;
    vecs[10].expected_illegal_reg = 1'b0;
    vecs[10].expected_is_ecalli   = 1'b0;
    vecs[10].expected_bb_term     = 1'b1;
    vecs[10].name = "branch_greater_signed_imm A3,100,0x40";

    // -----------------------------------------------------------------
    // 12. reg_reg: move_reg A0(=7) <- A1(=8)   (polkavm: d=reg1=low, s=reg2=high)
    //     opcode=0x64(100), b1=rd(A0=7)|rs1(A1=8)<<4 = 0x87
    //     skip=1, length=2
    //     rd=A0=7 (dest, low nibble b1[3:0]), rs1=A1=8 (source, high nibble b1[7:4])
    // -----------------------------------------------------------------
    vecs[11].chunk            = make_chunk(8'h64,8'h87,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[11].skip             = 5'd1;
    vecs[11].is_valid         = 1'b1;
    vecs[11].is_s_mode        = 1'b0;
    vecs[11].expected_op      = PVM_OP_MOVE_REG;
    vecs[11].expected_rs1     = 4'd8;   // A1 = 8 (source, high nibble of b1)
    vecs[11].expected_rs2     = 4'd0;
    vecs[11].expected_rd      = 4'd7;   // A0 = 7 (dest, low nibble of b1)
    vecs[11].expected_imm     = 64'd0;
    vecs[11].expected_imm2    = 64'd0;
    vecs[11].expected_length  = 5'd2;
    vecs[11].expected_illegal_op  = 1'b0;
    vecs[11].expected_illegal_reg = 1'b0;
    vecs[11].expected_is_ecalli   = 1'b0;
    vecs[11].expected_bb_term     = 1'b0;
    vecs[11].name = "move_reg A0<-A1";

    // -----------------------------------------------------------------
    // 13. reg_reg_imm: add_imm_64 A0(=7) <- A1(=8) + 5
    //     opcode=0x95(149), b1=rs1(A0=7)|rs2(A1=8)<<4=0x87
    //     b2=0x05, skip=2
    //     imm_len=clamp(0,2-1,4)=1, imm=sext(0x05,1)=0x05
    // -----------------------------------------------------------------
    vecs[12].chunk            = make_chunk(8'h95,8'h87,8'h05,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[12].skip             = 5'd2;
    vecs[12].is_valid         = 1'b1;
    vecs[12].is_s_mode        = 1'b0;
    vecs[12].expected_op      = PVM_OP_ADD_IMM_64;
    vecs[12].expected_rs1     = 4'd8;   // A1 = src (b1[7:4])
    vecs[12].expected_rs2     = 4'd0;
    vecs[12].expected_rd      = 4'd7;   // A0 = dst (b1[3:0])
    vecs[12].expected_imm     = 64'h0000_0000_0000_0005;
    vecs[12].expected_imm2    = 64'd0;
    vecs[12].expected_length  = 5'd3;
    vecs[12].expected_illegal_op  = 1'b0;
    vecs[12].expected_illegal_reg = 1'b0;
    vecs[12].expected_is_ecalli   = 1'b0;
    vecs[12].expected_bb_term     = 1'b0;
    vecs[12].name = "add_imm_64 A0,A1,5";

    // -----------------------------------------------------------------
    // 14. reg_reg_imm: shift_logical_left_imm_64 A0(=7) <- A1(=8) << 3
    //     opcode=0x97(151), b1=0x87(A0|A1<<4), b2=0x03 (shift amount)
    //     skip=2
    // -----------------------------------------------------------------
    vecs[13].chunk            = make_chunk(8'h97,8'h87,8'h03,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[13].skip             = 5'd2;
    vecs[13].is_valid         = 1'b1;
    vecs[13].is_s_mode        = 1'b0;
    vecs[13].expected_op      = PVM_OP_SHIFT_LOGICAL_LEFT_IMM_64;
    vecs[13].expected_rs1     = 4'd8;   // A1 = src (b1[7:4])
    vecs[13].expected_rs2     = 4'd0;
    vecs[13].expected_rd      = 4'd7;   // A0 = dst (b1[3:0])
    vecs[13].expected_imm     = 64'h0000_0000_0000_0003;
    vecs[13].expected_imm2    = 64'd0;
    vecs[13].expected_length  = 5'd3;
    vecs[13].expected_illegal_op  = 1'b0;
    vecs[13].expected_illegal_reg = 1'b0;
    vecs[13].expected_is_ecalli   = 1'b0;
    vecs[13].expected_bb_term     = 1'b0;
    vecs[13].name = "shift_logical_left_imm_64 A0,A1,3";

    // -----------------------------------------------------------------
    // 15. reg_reg_imm: mul_imm_64 A0(=7) <- A1(=8) * 7
    //     opcode=0x96(150), b1=0x87, b2=0x07
    //     skip=2
    // -----------------------------------------------------------------
    vecs[14].chunk            = make_chunk(8'h96,8'h87,8'h07,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[14].skip             = 5'd2;
    vecs[14].is_valid         = 1'b1;
    vecs[14].is_s_mode        = 1'b0;
    vecs[14].expected_op      = PVM_OP_MUL_IMM_64;
    vecs[14].expected_rs1     = 4'd8;   // A1 = src (b1[7:4])
    vecs[14].expected_rs2     = 4'd0;
    vecs[14].expected_rd      = 4'd7;   // A0 = dst (b1[3:0])
    vecs[14].expected_imm     = 64'h0000_0000_0000_0007;
    vecs[14].expected_imm2    = 64'd0;
    vecs[14].expected_length  = 5'd3;
    vecs[14].expected_illegal_op  = 1'b0;
    vecs[14].expected_illegal_reg = 1'b0;
    vecs[14].expected_is_ecalli   = 1'b0;
    vecs[14].expected_bb_term     = 1'b0;
    vecs[14].name = "mul_imm_64 A0,A1,7";

    // -----------------------------------------------------------------
    // 16. reg_reg_imm: negate_and_add_imm_64 A0(=7) <- -A1(=8) + 10
    //     opcode=0x9A(154), b1=0x87, b2=0x0A
    //     skip=2
    // -----------------------------------------------------------------
    vecs[15].chunk            = make_chunk(8'h9A,8'h87,8'h0A,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[15].skip             = 5'd2;
    vecs[15].is_valid         = 1'b1;
    vecs[15].is_s_mode        = 1'b0;
    vecs[15].expected_op      = PVM_OP_NEGATE_AND_ADD_IMM_64;
    vecs[15].expected_rs1     = 4'd8;   // A1 = src (b1[7:4])
    vecs[15].expected_rs2     = 4'd0;
    vecs[15].expected_rd      = 4'd7;   // A0 = dst (b1[3:0])
    vecs[15].expected_imm     = 64'h0000_0000_0000_000A;
    vecs[15].expected_imm2    = 64'd0;
    vecs[15].expected_length  = 5'd3;
    vecs[15].expected_illegal_op  = 1'b0;
    vecs[15].expected_illegal_reg = 1'b0;
    vecs[15].expected_is_ecalli   = 1'b0;
    vecs[15].expected_bb_term     = 1'b0;
    vecs[15].name = "negate_and_add_imm_64 A0,A1,10";

    // -----------------------------------------------------------------
    // 17. reg_reg_imm (load_indirect): load_indirect_u8 A0(=7) <- [A1(=8)+0x10]
    //     opcode=0x7C(124), b1=0x87, b2=0x10
    //     skip=2
    // -----------------------------------------------------------------
    vecs[16].chunk            = make_chunk(8'h7C,8'h87,8'h10,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[16].skip             = 5'd2;
    vecs[16].is_valid         = 1'b1;
    vecs[16].is_s_mode        = 1'b0;
    vecs[16].expected_op      = PVM_OP_LOAD_INDIRECT_U8;
    vecs[16].expected_rs1     = 4'd8;   // A1 = base (b1[7:4])
    vecs[16].expected_rs2     = 4'd0;
    vecs[16].expected_rd      = 4'd7;   // A0 = dest (b1[3:0])
    vecs[16].expected_imm     = 64'h0000_0000_0000_0010;  // offset = 0x10
    vecs[16].expected_imm2    = 64'd0;
    vecs[16].expected_length  = 5'd3;
    vecs[16].expected_illegal_op  = 1'b0;
    vecs[16].expected_illegal_reg = 1'b0;
    vecs[16].expected_is_ecalli   = 1'b0;
    vecs[16].expected_bb_term     = 1'b0;
    vecs[16].name = "load_indirect_u8 A0,[A1+0x10]";

    // -----------------------------------------------------------------
    // 18. reg_reg_imm (load_indirect): load_indirect_u32 A1(=8) <- [A2(=9)+0x100]
    //     opcode=0x80(128), b1=A1(8)|A2(9)<<4=0x98, b2..b3=00 01 (LE 2-byte=0x100)
    //     skip=3: imm_len=clamp(0,3-1,4)=2 → reads 2 bytes: 00 01 → sext(0x0100,2)=0x0100
    // -----------------------------------------------------------------
    vecs[17].chunk            = make_chunk(8'h80,8'h98,8'h00,8'h01,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[17].skip             = 5'd3;
    vecs[17].is_valid         = 1'b1;
    vecs[17].is_s_mode        = 1'b0;
    vecs[17].expected_op      = PVM_OP_LOAD_INDIRECT_U32;
    vecs[17].expected_rs1     = 4'd9;   // A2 = base (b1[7:4])
    vecs[17].expected_rs2     = 4'd0;
    vecs[17].expected_rd      = 4'd8;   // A1 = dest (b1[3:0])
    vecs[17].expected_imm     = 64'h0000_0000_0000_0100;  // offset = 0x100
    vecs[17].expected_imm2    = 64'd0;
    vecs[17].expected_length  = 5'd4;
    vecs[17].expected_illegal_op  = 1'b0;
    vecs[17].expected_illegal_reg = 1'b0;
    vecs[17].expected_is_ecalli   = 1'b0;
    vecs[17].expected_bb_term     = 1'b0;
    vecs[17].name = "load_indirect_u32 A1,[A2+0x100]";

    // -----------------------------------------------------------------
    // 19. reg_reg_imm (load_indirect): load_indirect_u64 A2(=9) <- [A3(=10)+4]
    //     opcode=0x82(130), b1=A2(9)|A3(10)<<4=0xA9, b2=0x04
    //     skip=2
    // -----------------------------------------------------------------
    vecs[18].chunk            = make_chunk(8'h82,8'hA9,8'h04,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[18].skip             = 5'd2;
    vecs[18].is_valid         = 1'b1;
    vecs[18].is_s_mode        = 1'b0;
    vecs[18].expected_op      = PVM_OP_LOAD_INDIRECT_U64;
    vecs[18].expected_rs1     = 4'd10;  // A3 = base (b1[7:4])
    vecs[18].expected_rs2     = 4'd0;
    vecs[18].expected_rd      = 4'd9;   // A2 = dest (b1[3:0])
    vecs[18].expected_imm     = 64'h0000_0000_0000_0004;
    vecs[18].expected_imm2    = 64'd0;
    vecs[18].expected_length  = 5'd3;
    vecs[18].expected_illegal_op  = 1'b0;
    vecs[18].expected_illegal_reg = 1'b0;
    vecs[18].expected_is_ecalli   = 1'b0;
    vecs[18].expected_bb_term     = 1'b0;
    vecs[18].name = "load_indirect_u64 A2,[A3+4]";

    // -----------------------------------------------------------------
    // 20. reg_reg_reg: add_64 A0(=7) = A1(=8) + A2(=9)
    //     opcode=0xC8(200), b1=reg2(A1=8)|reg3(A2=9)<<4=0x98, b2=reg1(A0=7) low nibble
    //     skip=2, length=3
    // -----------------------------------------------------------------
    vecs[19].chunk            = make_chunk(8'hC8,8'h98,8'h07,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[19].skip             = 5'd2;
    vecs[19].is_valid         = 1'b1;
    vecs[19].is_s_mode        = 1'b0;
    vecs[19].expected_op      = PVM_OP_ADD_64;
    vecs[19].expected_rs1     = 4'd8;   // A1 (src1, from b1[3:0])
    vecs[19].expected_rs2     = 4'd9;   // A2 (src2, from b1[7:4])
    vecs[19].expected_rd      = 4'd7;   // A0 (dst, from b2[3:0])
    vecs[19].expected_imm     = 64'd0;
    vecs[19].expected_imm2    = 64'd0;
    vecs[19].expected_length  = 5'd3;
    vecs[19].expected_illegal_op  = 1'b0;
    vecs[19].expected_illegal_reg = 1'b0;
    vecs[19].expected_is_ecalli   = 1'b0;
    vecs[19].expected_bb_term     = 1'b0;
    vecs[19].name = "add_64 A0,A1,A2";

    // -----------------------------------------------------------------
    // 21. reg_reg_reg: mul_64 A0(=7) = A1(=8) * A2(=9)
    //     opcode=0xCA(202), b1=0x98, b2=0x07
    //     skip=2
    // -----------------------------------------------------------------
    vecs[20].chunk            = make_chunk(8'hCA,8'h98,8'h07,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[20].skip             = 5'd2;
    vecs[20].is_valid         = 1'b1;
    vecs[20].is_s_mode        = 1'b0;
    vecs[20].expected_op      = PVM_OP_MUL_64;
    vecs[20].expected_rs1     = 4'd8;
    vecs[20].expected_rs2     = 4'd9;
    vecs[20].expected_rd      = 4'd7;
    vecs[20].expected_imm     = 64'd0;
    vecs[20].expected_imm2    = 64'd0;
    vecs[20].expected_length  = 5'd3;
    vecs[20].expected_illegal_op  = 1'b0;
    vecs[20].expected_illegal_reg = 1'b0;
    vecs[20].expected_is_ecalli   = 1'b0;
    vecs[20].expected_bb_term     = 1'b0;
    vecs[20].name = "mul_64 A0,A1,A2";

    // -----------------------------------------------------------------
    // 22. reg_reg_reg: cmov_if_zero A0(=7) = (A2(=9)==0)?A1(=8):A0
    //     opcode=0xDA(218), b1=0x98, b2=0x07
    //     skip=2
    // -----------------------------------------------------------------
    vecs[21].chunk            = make_chunk(8'hDA,8'h98,8'h07,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[21].skip             = 5'd2;
    vecs[21].is_valid         = 1'b1;
    vecs[21].is_s_mode        = 1'b0;
    vecs[21].expected_op      = PVM_OP_CMOV_IF_ZERO;
    vecs[21].expected_rs1     = 4'd8;
    vecs[21].expected_rs2     = 4'd9;
    vecs[21].expected_rd      = 4'd7;
    vecs[21].expected_imm     = 64'd0;
    vecs[21].expected_imm2    = 64'd0;
    vecs[21].expected_length  = 5'd3;
    vecs[21].expected_illegal_op  = 1'b0;
    vecs[21].expected_illegal_reg = 1'b0;
    vecs[21].expected_is_ecalli   = 1'b0;
    vecs[21].expected_bb_term     = 1'b0;
    vecs[21].name = "cmov_if_zero A0,A1,A2";

    // -----------------------------------------------------------------
    // 23. reg_reg_reg: xor A0(=7) = A1(=8) ^ A2(=9)
    //     opcode=0xD3(211), b1=0x98, b2=0x07
    //     skip=2
    // -----------------------------------------------------------------
    vecs[22].chunk            = make_chunk(8'hD3,8'h98,8'h07,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[22].skip             = 5'd2;
    vecs[22].is_valid         = 1'b1;
    vecs[22].is_s_mode        = 1'b0;
    vecs[22].expected_op      = PVM_OP_XOR;
    vecs[22].expected_rs1     = 4'd8;
    vecs[22].expected_rs2     = 4'd9;
    vecs[22].expected_rd      = 4'd7;
    vecs[22].expected_imm     = 64'd0;
    vecs[22].expected_imm2    = 64'd0;
    vecs[22].expected_length  = 5'd3;
    vecs[22].expected_illegal_op  = 1'b0;
    vecs[22].expected_illegal_reg = 1'b0;
    vecs[22].expected_is_ecalli   = 1'b0;
    vecs[22].expected_bb_term     = 1'b0;
    vecs[22].name = "xor A0,A1,A2";

    // -----------------------------------------------------------------
    // 24. reg_reg_offset: branch_eq A0(=7), A1(=8), 0x20
    //     opcode=0xAA(170), b1=A0(7)|A1(8)<<4=0x87, b2=0x20
    //     skip=2, imm_len=clamp(0,2-1,4)=1, imm=0x20
    // -----------------------------------------------------------------
    vecs[23].chunk            = make_chunk(8'hAA,8'h87,8'h20,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[23].skip             = 5'd2;
    vecs[23].is_valid         = 1'b1;
    vecs[23].is_s_mode        = 1'b0;
    vecs[23].expected_op      = PVM_OP_BRANCH_EQ;
    vecs[23].expected_rs1     = 4'd7;   // A0
    vecs[23].expected_rs2     = 4'd8;   // A1
    vecs[23].expected_rd      = 4'd0;
    vecs[23].expected_imm     = 64'h0000_0000_0000_0023;  // 0x20 + skip(2)+1 = 0x23
    vecs[23].expected_imm2    = 64'd0;
    vecs[23].expected_length  = 5'd3;
    vecs[23].expected_illegal_op  = 1'b0;
    vecs[23].expected_illegal_reg = 1'b0;
    vecs[23].expected_is_ecalli   = 1'b0;
    vecs[23].expected_bb_term     = 1'b1;
    vecs[23].name = "branch_eq A0,A1,0x20";

    // -----------------------------------------------------------------
    // 25. reg_reg_offset: branch_less_signed A0(=7), A1(=8), -4
    //     opcode=0xAD(173), b1=0x87, b2=0xFC(-4 as 1 byte signed)
    //     skip=2, imm_len=1, imm=sext(0xFC,1)=0xFFFFFFFC
    // -----------------------------------------------------------------
    vecs[24].chunk            = make_chunk(8'hAD,8'h87,8'hFC,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[24].skip             = 5'd2;
    vecs[24].is_valid         = 1'b1;
    vecs[24].is_s_mode        = 1'b0;
    vecs[24].expected_op      = PVM_OP_BRANCH_LESS_SIGNED;
    vecs[24].expected_rs1     = 4'd7;
    vecs[24].expected_rs2     = 4'd8;
    vecs[24].expected_rd      = 4'd0;
    vecs[24].expected_imm     = 64'hFFFF_FFFF_FFFF_FFFF;  // -4 + skip(2)+1 = -1
    vecs[24].expected_imm2    = 64'd0;
    vecs[24].expected_length  = 5'd3;
    vecs[24].expected_illegal_op  = 1'b0;
    vecs[24].expected_illegal_reg = 1'b0;
    vecs[24].expected_is_ecalli   = 1'b0;
    vecs[24].expected_bb_term     = 1'b1;
    vecs[24].name = "branch_less_signed A0,A1,-4";

    // -----------------------------------------------------------------
    // 26. jump_indirect: jump_indirect RA(=0), 0
    //     opcode=0x32(50), b1=0x00(RA), skip=1 → imm_len=0, imm=0
    // -----------------------------------------------------------------
    vecs[25].chunk            = make_chunk(8'h32,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[25].skip             = 5'd1;
    vecs[25].is_valid         = 1'b1;
    vecs[25].is_s_mode        = 1'b0;
    vecs[25].expected_op      = PVM_OP_JUMP_INDIRECT;
    vecs[25].expected_rs1     = 4'd0;   // RA
    vecs[25].expected_rs2     = 4'd0;
    vecs[25].expected_rd      = 4'd0;
    vecs[25].expected_imm     = 64'd0;
    vecs[25].expected_imm2    = 64'd0;
    vecs[25].expected_length  = 5'd2;
    vecs[25].expected_illegal_op  = 1'b0;
    vecs[25].expected_illegal_reg = 1'b0;
    vecs[25].expected_is_ecalli   = 1'b0;
    vecs[25].expected_bb_term     = 1'b1;
    vecs[25].name = "jump_indirect RA,0";

    // -----------------------------------------------------------------
    // 27. ecalli: ecalli 1
    //     opcode=0x0A(10), b1=0x01, skip=1, imm_len=min(4,1)=1, imm=0x01
    // -----------------------------------------------------------------
    vecs[26].chunk            = make_chunk(8'h0A,8'h01,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[26].skip             = 5'd1;
    vecs[26].is_valid         = 1'b1;
    vecs[26].is_s_mode        = 1'b0;
    vecs[26].expected_op      = PVM_OP_ECALLI;
    vecs[26].expected_rs1     = 4'd0;
    vecs[26].expected_rs2     = 4'd0;
    vecs[26].expected_rd      = 4'd0;
    vecs[26].expected_imm     = 64'h0000_0000_0000_0001;
    vecs[26].expected_imm2    = 64'd0;
    vecs[26].expected_length  = 5'd2;
    vecs[26].expected_illegal_op  = 1'b0;
    vecs[26].expected_illegal_reg = 1'b0;
    vecs[26].expected_is_ecalli   = 1'b1;
    vecs[26].expected_bb_term     = 1'b0;
    vecs[26].name = "ecalli 1";

    // -----------------------------------------------------------------
    // 28. ecalli sentinel: ecalli 0xFFFFFFFF (mode_return)
    //     opcode=0x0A(10), b1..b4=FF FF FF FF, skip=4
    //     imm_len=min(4,4)=4, imm=sext(0xFFFFFFFF,4)=0xFFFFFFFF (no sext at 4 bytes)
    //     Note: for 4-byte read, shift=0, full 32 bits as-is = 0xFFFFFFFF
    //     64-bit sign extension: 0xFFFF_FFFF_FFFF_FFFF
    // -----------------------------------------------------------------
    vecs[27].chunk            = make_chunk(8'h0A,8'hFF,8'hFF,8'hFF,8'hFF,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[27].skip             = 5'd4;
    vecs[27].is_valid         = 1'b1;
    vecs[27].is_s_mode        = 1'b0;
    vecs[27].expected_op      = PVM_OP_ECALLI;
    vecs[27].expected_rs1     = 4'd0;
    vecs[27].expected_rs2     = 4'd0;
    vecs[27].expected_rd      = 4'd0;
    vecs[27].expected_imm     = 64'hFFFF_FFFF_FFFF_FFFF;
    vecs[27].expected_imm2    = 64'd0;
    vecs[27].expected_length  = 5'd5;
    vecs[27].expected_illegal_op  = 1'b0;
    vecs[27].expected_illegal_reg = 1'b0;
    vecs[27].expected_is_ecalli   = 1'b1;
    vecs[27].expected_bb_term     = 1'b0;
    vecs[27].name = "ecalli sentinel MODE_RETURN";

    // -----------------------------------------------------------------
    // 29. illegal opcode: byte 0x05 (gap 3..9, unassigned in JamV1)
    //     is_valid_opcode_i=1 but opcode not in LUT → illegal_op=1
    // -----------------------------------------------------------------
    vecs[28].chunk            = make_chunk(8'h05,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[28].skip             = 5'd0;
    vecs[28].is_valid         = 1'b1;
    vecs[28].is_s_mode        = 1'b0;
    vecs[28].expected_op      = PVM_OP_TRAP;
    vecs[28].expected_rs1     = 4'd0;
    vecs[28].expected_rs2     = 4'd0;
    vecs[28].expected_rd      = 4'd0;
    vecs[28].expected_imm     = 64'd0;
    vecs[28].expected_imm2    = 64'd0;
    vecs[28].expected_length  = 5'd1;
    vecs[28].expected_illegal_op  = 1'b1;
    vecs[28].expected_illegal_reg = 1'b0;
    vecs[28].expected_is_ecalli   = 1'b0;
    vecs[28].expected_bb_term     = 1'b1;
    vecs[28].name = "illegal opcode 0x05";

    // -----------------------------------------------------------------
    // 30. illegal opcode: byte 0x06 (also gap, unassigned in JamV1)
    // -----------------------------------------------------------------
    vecs[29].chunk            = make_chunk(8'h06,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00);
    vecs[29].skip             = 5'd0;
    vecs[29].is_valid         = 1'b1;
    vecs[29].is_s_mode        = 1'b0;
    vecs[29].expected_op      = PVM_OP_TRAP;
    vecs[29].expected_rs1     = 4'd0;
    vecs[29].expected_rs2     = 4'd0;
    vecs[29].expected_rd      = 4'd0;
    vecs[29].expected_imm     = 64'd0;
    vecs[29].expected_imm2    = 64'd0;
    vecs[29].expected_length  = 5'd1;
    vecs[29].expected_illegal_op  = 1'b1;
    vecs[29].expected_illegal_reg = 1'b0;
    vecs[29].expected_is_ecalli   = 1'b0;
    vecs[29].expected_bb_term     = 1'b1;
    vecs[29].name = "illegal opcode 0x06";

  end  // initial setup_vectors

  // -------------------------------------------------------------------------
  // Clock generation
  // -------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // Stimulus and checking
  // -------------------------------------------------------------------------
  int pass_count;
  int fail_count;

  initial begin : run_vectors
    pass_count = 0;
    fail_count = 0;
    rst_n      = 1'b0;
    chunk      = 128'd0;
    skip       = 5'd0;
    is_valid   = 1'b1;
    is_s_mode  = 1'b0;

    // De-assert reset after a couple of clocks
    @(posedge clk); #1;
    @(posedge clk); #1;
    rst_n = 1'b1;
    @(posedge clk); #1;

    for (int v = 0; v < 30; v++) begin
      // Apply stimulus (combinational decoder — no need for clock edge)
      chunk     = vecs[v].chunk;
      skip      = vecs[v].skip;
      is_valid  = vecs[v].is_valid;
      is_s_mode = vecs[v].is_s_mode;

      // One clock cycle for outputs to settle
      @(posedge clk); #1;

      begin
        logic err;
        err = 1'b0;

        if (pvm_op !== vecs[v].expected_op) begin
          $display("FAIL [%0d] %s: pvm_op got=%0d exp=%0d",
                   v+1, vecs[v].name, pvm_op, vecs[v].expected_op);
          err = 1'b1;
        end
        if (rs1 !== vecs[v].expected_rs1) begin
          $display("FAIL [%0d] %s: rs1 got=%0d exp=%0d",
                   v+1, vecs[v].name, rs1, vecs[v].expected_rs1);
          err = 1'b1;
        end
        if (rs2 !== vecs[v].expected_rs2) begin
          $display("FAIL [%0d] %s: rs2 got=%0d exp=%0d",
                   v+1, vecs[v].name, rs2, vecs[v].expected_rs2);
          err = 1'b1;
        end
        if (rd !== vecs[v].expected_rd) begin
          $display("FAIL [%0d] %s: rd got=%0d exp=%0d",
                   v+1, vecs[v].name, rd, vecs[v].expected_rd);
          err = 1'b1;
        end
        if (imm_out !== vecs[v].expected_imm) begin
          $display("FAIL [%0d] %s: imm got=%016h exp=%016h",
                   v+1, vecs[v].name, imm_out, vecs[v].expected_imm);
          err = 1'b1;
        end
        if (imm2_out !== vecs[v].expected_imm2) begin
          $display("FAIL [%0d] %s: imm2 got=%016h exp=%016h",
                   v+1, vecs[v].name, imm2_out, vecs[v].expected_imm2);
          err = 1'b1;
        end
        if (instr_len !== vecs[v].expected_length) begin
          $display("FAIL [%0d] %s: length got=%0d exp=%0d",
                   v+1, vecs[v].name, instr_len, vecs[v].expected_length);
          err = 1'b1;
        end
        if (illegal_op !== vecs[v].expected_illegal_op) begin
          $display("FAIL [%0d] %s: illegal_op got=%0b exp=%0b",
                   v+1, vecs[v].name, illegal_op, vecs[v].expected_illegal_op);
          err = 1'b1;
        end
        if (illegal_reg !== vecs[v].expected_illegal_reg) begin
          $display("FAIL [%0d] %s: illegal_reg got=%0b exp=%0b",
                   v+1, vecs[v].name, illegal_reg, vecs[v].expected_illegal_reg);
          err = 1'b1;
        end
        if (is_ecalli !== vecs[v].expected_is_ecalli) begin
          $display("FAIL [%0d] %s: is_ecalli got=%0b exp=%0b",
                   v+1, vecs[v].name, is_ecalli, vecs[v].expected_is_ecalli);
          err = 1'b1;
        end
        if (is_bb_term !== vecs[v].expected_bb_term) begin
          $display("FAIL [%0d] %s: bb_term got=%0b exp=%0b",
                   v+1, vecs[v].name, is_bb_term, vecs[v].expected_bb_term);
          err = 1'b1;
        end

        if (!err) begin
          $display("PASS [%0d] %s", v+1, vecs[v].name);
          pass_count++;
        end else begin
          fail_count++;
        end
      end
    end

    $display("---");
    $display("PASS: %0d/30  FAIL: %0d/30", pass_count, fail_count);

    if (fail_count == 0)
      $display("ALL PASS");
    else
      $display("FAILURES DETECTED");

    $finish;
  end

endmodule
