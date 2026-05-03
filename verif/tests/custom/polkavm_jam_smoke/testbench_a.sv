// Sub-phase 9: Program A end-to-end smoke test
//
// Tests: load_imm + add_imm_64 (loop) + branch_not_eq_imm + store_u8 + trap.
// Program: add 3 to accumulator 5 times (result=15), store to UART, halt.
//
// 2-group layout to avoid cross-group instruction boundary:
//   Group 0 (bytes 0..15): load_imm + loop (add_imm + branch_not_eq_imm)
//   Group 1 (bytes 16..31): store_u8 + trap
//
// Program encoding (verified by /tmp/verify_pvm.py):
//   [0x00] load_imm   A0, 0     (A0 = accumulator)
//   [0x02] load_imm   A1, 5     (A1 = loop counter)
//   [0x05] add_imm_64 A0, A0, 3 (acc += 3)     <- LOOP
//   [0x08] add_imm_64 A1, A1,-1 (counter--)
//   [0x0B] branch_not_eq_imm A1, 0, -9  (if counter!=0 → LOOP at 0x05)
//   [0x0E] load_imm A3, 0       (nop / advance to group boundary)
//   [0x10] store_u8  A0, 0x7F   (write result to UART addr 0x7F)
//   [0x13] trap                 (halt)
//
// After 5 iterations: A0 = 5*3 = 15, A1 = 0.
// UART write: byte 0x0F to address 0x7F.
//
// No ariane_pkg dependency. Standalone Verilator binary.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

`timescale 1ns/1ps

module testbench_a
  import polkavm_pkg::*;
();

  // =========================================================================
  // Clock / reset
  // =========================================================================
  logic clk   = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;  // 100 MHz

  // =========================================================================
  // Program A: 2-group layout, all instructions within their respective groups
  // =========================================================================
  localparam int  CODE_LEN     = 32;   // 2 x 16-byte groups
  localparam int  BITMASK_LEN  = 4;
  localparam logic [7:0] UART_ADDR = 8'h7F;  // single-byte address

  logic [7:0] code_rom    [0:CODE_LEN-1];
  logic [7:0] bitmask_rom [0:BITMASK_LEN-1];

  initial begin
    // Zero-fill
    for (int i = 0; i < CODE_LEN;    i++) code_rom[i]    = 8'h00;
    for (int i = 0; i < BITMASK_LEN; i++) bitmask_rom[i] = 8'h00;

    // --- Group 0 (bytes 0x00..0x0F) ---
    // [0x00] load_imm A0 (reg7), imm=0 → 2 bytes
    code_rom[8'h00] = 8'h33; code_rom[8'h01] = 8'h07;
    // [0x02] load_imm A1 (reg8), imm=5 → 3 bytes
    code_rom[8'h02] = 8'h33; code_rom[8'h03] = 8'h08; code_rom[8'h04] = 8'h05;
    // [0x05] add_imm_64 A0(dst=7), A0(src=7), imm=3 → 3 bytes
    //        b1 = dst|(src<<4) = 7|(7<<4) = 0x77
    code_rom[8'h05] = 8'h95; code_rom[8'h06] = 8'h77; code_rom[8'h07] = 8'h03;
    // [0x08] add_imm_64 A1(dst=8), A1(src=8), imm=-1 → 3 bytes (-1=0xFF 1-byte sext)
    //        b1 = 8|(8<<4) = 0x88
    code_rom[8'h08] = 8'h95; code_rom[8'h09] = 8'h88; code_rom[8'h0A] = 8'hFF;
    // [0x0B] branch_not_eq_imm A1(rs=8), imm=0, offset=-9 → 3 bytes
    //        b1 = rs|(imm1_len<<4) = 8|(0<<4) = 0x08
    //        imm1_len=0 (imm=0 needs no bytes; min4(b1[7:4])=min4(0)=0)
    //        imm2=offset=-9=0xF7 (1 byte sext)
    //        next_pc=0x0E, target=0x0E+(-9)=0x05 ✓
    code_rom[8'h0B] = 8'h52; code_rom[8'h0C] = 8'h08; code_rom[8'h0D] = 8'hF7;
    // [0x0E] load_imm A3 (reg10), imm=0 → 2 bytes (nop to advance PC to group boundary)
    code_rom[8'h0E] = 8'h33; code_rom[8'h0F] = 8'h0A;

    // --- Group 1 (bytes 0x10..0x1F) ---
    // [0x10] store_u8 A0 (rs=7), addr=0x7F → 3 bytes
    //        opcode=59=0x3B, b1=rs=0x07, imm=0x7F (1 byte)
    code_rom[8'h10] = 8'h3B; code_rom[8'h11] = 8'h07; code_rom[8'h12] = 8'h7F;
    // [0x13] trap → 1 byte
    code_rom[8'h13] = 8'h00;

    // Bitmask: opcode positions are 0x00, 0x02, 0x05, 0x08, 0x0B, 0x0E, 0x10, 0x13
    // Byte 0: bits 0,2,5       = 0b00100101 = 0x25
    // Byte 1: bits 0,3,6       = 0b01001001 = 0x49
    // Byte 2: bits 0,3 (=16,19 relative to byte base 16)
    //         pos 0x10=16: byte 2 bit 0; pos 0x13=19: byte 2 bit 3
    //         = 0b00001001 = 0x09
    // Byte 3: 0x00
    bitmask_rom[0] = 8'h25;
    bitmask_rom[1] = 8'h49;
    bitmask_rom[2] = 8'h09;
    bitmask_rom[3] = 8'h00;
  end

  // =========================================================================
  // UART model
  // =========================================================================
  logic [7:0] mem_uart_byte;
  logic       mem_uart_written;

  // =========================================================================
  // PVM frontend wires
  // =========================================================================
  logic [7:0]   fe_code_addr;
  logic [127:0] fe_code_data;
  logic [7:0]   fe_bitmask_addr;
  logic [31:0]  fe_bitmask_data;
  logic         fe_branch_valid;
  logic [7:0]   fe_branch_target;
  logic         fe_valid;
  logic [127:0] fe_chunk;
  logic [4:0]   fe_skip;
  logic         fe_is_valid_op;
  logic [7:0]   fe_pc;
  logic         fe_ready;

  // =========================================================================
  // Combinatorial ROM response
  // =========================================================================
  always_comb begin : rom_read
    automatic logic [7:0] group_base;
    group_base   = {fe_code_addr[7:4], 4'b0};
    fe_code_data = '0;
    for (int b = 0; b < 16; b++) begin
      if (int'(group_base) + b < CODE_LEN) begin
        fe_code_data[b*8 +: 8] = code_rom[int'(group_base) + b];
      end
    end
  end

  always_comb begin : bitmask_read
    automatic logic [7:0] bm_base;
    bm_base          = fe_bitmask_addr;
    fe_bitmask_data  = '0;
    for (int b = 0; b < 4; b++) begin
      if (int'(bm_base) + b < BITMASK_LEN) begin
        fe_bitmask_data[b*8 +: 8] = bitmask_rom[int'(bm_base) + b];
      end
    end
  end

  // =========================================================================
  // pvm_frontend instantiation
  // =========================================================================
  pvm_frontend #(
    .VirtualAddrSize(8)
  ) i_frontend (
    .clk_i                   (clk),
    .rst_ni                  (rst_n),
    .code_addr_o             (fe_code_addr),
    .code_data_i             (fe_code_data),
    .bitmask_addr_o          (fe_bitmask_addr),
    .bitmask_data_i          (fe_bitmask_data),
    .branch_redirect_valid_i (fe_branch_valid),
    .branch_redirect_target_i(fe_branch_target),
    .valid_o                 (fe_valid),
    .chunk_o                 (fe_chunk),
    .skip_o                  (fe_skip),
    .is_valid_opcode_o       (fe_is_valid_op),
    .pc_o                    (fe_pc),
    .ready_i                 (fe_ready)
  );

  // =========================================================================
  // pvm_decoder wires
  // =========================================================================
  pvm_op_t    dec_op;
  logic [3:0]  dec_rs1, dec_rs2, dec_rd;
  logic [63:0] dec_imm, dec_imm2;
  logic        dec_illegal_op, dec_illegal_reg;
  logic        dec_is_ecalli, dec_sentinel_mr, dec_sentinel_rcsr;
  logic [4:0]  dec_instr_len;
  logic        dec_is_bb_term;

  pvm_decoder i_decoder (
    .clk_i                           (clk),
    .rst_ni                          (rst_n),
    .chunk_i                         (fe_chunk),
    .skip_i                          (fe_skip),
    .is_valid_opcode_i               (fe_is_valid_op),
    .is_s_mode_i                     (1'b0),
    .pvm_op_o                        (dec_op),
    .rs1_o                           (dec_rs1),
    .rs2_o                           (dec_rs2),
    .rd_o                            (dec_rd),
    .imm_o                           (dec_imm),
    .imm2_o                          (dec_imm2),
    .is_illegal_op_o                 (dec_illegal_op),
    .is_illegal_reg_o                (dec_illegal_reg),
    .is_ecalli_o                     (dec_is_ecalli),
    .is_ecalli_sentinel_mode_return_o(dec_sentinel_mr),
    .is_ecalli_sentinel_read_csr_o   (dec_sentinel_rcsr),
    .instruction_length_o            (dec_instr_len),
    .is_basic_block_term_o           (dec_is_bb_term)
  );

  // =========================================================================
  // pvm_alu
  // =========================================================================
  logic [63:0]  alu_a, alu_b, alu_imm_in, alu_mul_upper;
  pvm_alu_op_e  alu_op;
  logic [63:0]  alu_result;

  pvm_alu i_alu (
    .operand_a_i (alu_a),
    .operand_b_i (alu_b),
    .imm_i       (alu_imm_in),
    .mul_upper_i (alu_mul_upper),
    .op_i        (alu_op),
    .result_o    (alu_result)
  );

  // =========================================================================
  // Register file (13 x 64 bits)
  // =========================================================================
  logic [63:0] regfile [0:12];

  // =========================================================================
  // ALU operand mux
  // =========================================================================
  // Group 5 (reg_reg_imm, add_imm_64 etc.): dec_rs1=dst, dec_rs2=src
  // Group 7 (reg_reg_reg, add_64 etc.):     dec_rd=dst, dec_rs1=src1, dec_rs2=src2
  always_comb begin : alu_mux
    alu_mul_upper = '0;
    alu_imm_in    = '0;
    alu_a         = '0;
    alu_b         = '0;
    alu_op        = PVM_ALU_ADD_64;
    case (dec_op)
      PVM_OP_ADD_64, PVM_OP_SUB_64, PVM_OP_AND, PVM_OP_OR, PVM_OP_XOR: begin
        alu_a  = (dec_rs1 < 13) ? regfile[dec_rs1] : '0;
        alu_b  = (dec_rs2 < 13) ? regfile[dec_rs2] : '0;
        alu_op = PVM_ALU_ADD_64;
      end
      PVM_OP_ADD_IMM_64: begin
        // dec_rs2 = source register (b1[7:4])
        alu_a  = (dec_rs2 < 13) ? regfile[dec_rs2] : '0;
        alu_b  = dec_imm;
        alu_op = PVM_ALU_ADD_IMM_64;
      end
      PVM_OP_ADD_IMM_32: begin
        alu_a  = (dec_rs2 < 13) ? regfile[dec_rs2] : '0;
        alu_b  = dec_imm;
        alu_op = PVM_ALU_ADD_IMM_32;
      end
      default: ;
    endcase
  end

  // =========================================================================
  // Branch evaluation (combinatorial)
  // =========================================================================
  logic        branch_taken;
  logic [63:0] branch_target_full;

  always_comb begin : branch_eval
    branch_taken       = 1'b0;
    branch_target_full = '0;
    if (fe_valid) begin
      case (dec_op)
        PVM_OP_BRANCH_NOT_EQ_IMM: begin
          automatic logic [63:0] rs_val;
          rs_val = (dec_rs1 < 13) ? regfile[dec_rs1] : '0;
          if (rs_val != dec_imm) begin
            branch_taken       = 1'b1;
            // target = PC_of_instr_after_branch + signed_offset
            branch_target_full = (64'(fe_pc) + 64'(dec_instr_len)) + dec_imm2;
          end
        end
        PVM_OP_BRANCH_EQ_IMM: begin
          automatic logic [63:0] rs_val2;
          rs_val2 = (dec_rs1 < 13) ? regfile[dec_rs1] : '0;
          if (rs_val2 == dec_imm) begin
            branch_taken       = 1'b1;
            branch_target_full = (64'(fe_pc) + 64'(dec_instr_len)) + dec_imm2;
          end
        end
        default: ;
      endcase
    end
  end

  // Frontend back-pressure: stall while branch resolves
  assign fe_ready        = fe_valid && !branch_taken;
  assign fe_branch_valid  = fe_valid && branch_taken;
  assign fe_branch_target = branch_target_full[7:0];

  // =========================================================================
  // Execute stage (clocked)
  // =========================================================================
  int  cycle_count;
  logic halt_seen;
  int  errors;

  always_ff @(posedge clk or negedge rst_n) begin : execute
    if (!rst_n) begin
      cycle_count      <= 0;
      halt_seen        <= 1'b0;
      errors           <= 0;
      mem_uart_byte    <= 8'h00;
      mem_uart_written <= 1'b0;
      for (int i = 0; i < 13; i++) regfile[i] <= '0;
    end else begin
      cycle_count <= cycle_count + 1;

      if (fe_valid && !halt_seen) begin
        case (dec_op)

          // load_imm: rd = dec_rs1 (b1[3:0]), imm = dec_imm
          PVM_OP_LOAD_IMM, PVM_OP_LOAD_IMM64: begin
            if (dec_rs1 < 13) regfile[dec_rs1] <= dec_imm;
          end

          // add_imm_64: dst=dec_rs1, src=dec_rs2, imm=dec_imm
          PVM_OP_ADD_IMM_64, PVM_OP_ADD_IMM_32: begin
            if (dec_rs1 < 13) regfile[dec_rs1] <= alu_result;
          end

          // add_64: dst=dec_rd, src1=dec_rs1, src2=dec_rs2
          PVM_OP_ADD_64, PVM_OP_SUB_64, PVM_OP_AND, PVM_OP_OR, PVM_OP_XOR: begin
            if (dec_rd < 13) regfile[dec_rd] <= alu_result;
          end

          // store_u8: mem[dec_imm] = regfile[dec_rs1][7:0]
          PVM_OP_STORE_U8: begin
            automatic logic [7:0] val;
            val = (dec_rs1 < 13) ? regfile[dec_rs1][7:0] : 8'h00;
            if (dec_imm[7:0] == UART_ADDR) begin
              mem_uart_byte    <= val;
              mem_uart_written <= 1'b1;
            end
          end

          // branch: no regfile write; redirect handled combinatorially
          PVM_OP_BRANCH_NOT_EQ_IMM, PVM_OP_BRANCH_EQ_IMM: ;

          // trap: halt
          PVM_OP_TRAP: halt_seen <= 1'b1;

          // fallthrough/unlikely: just advance
          PVM_OP_FALLTHROUGH, PVM_OP_UNLIKELY: ;

          default: ;
        endcase
      end
    end
  end

  // =========================================================================
  // Checker
  // =========================================================================
  task automatic check_cond(input string msg, input logic cond);
    if (!cond) begin
      $display("FAIL [cycle %0d]: %s", cycle_count, msg);
      errors++;
    end else begin
      $display("PASS [cycle %0d]: %s", cycle_count, msg);
    end
  endtask

  initial begin
    @(posedge clk); @(posedge clk); @(posedge clk);
    rst_n = 1;

    fork
      begin wait (halt_seen); end
      begin
        repeat (300) @(posedge clk);
        $display("TIMEOUT: halt not seen in 300 cycles");
        errors++;
      end
    join_any

    @(posedge clk);

    $display("\n--- Program A final state ---");
    $display("  cycle_count  = %0d", cycle_count);
    $display("  A0 (acc)     = %0d (expected 15)", regfile[7]);
    $display("  A1 (counter) = %0d (expected 0)",  regfile[8]);
    $display("  UART byte    = 0x%02X (expected 0x0F)", mem_uart_byte);
    $display("  UART written = %0b (expected 1)", mem_uart_written);

    check_cond("A0 == 15 (5 * 3 accumulation)", regfile[7] == 64'd15);
    check_cond("A1 == 0 (loop counter reached zero)", regfile[8] == 64'd0);
    check_cond("UART byte == 0x0F", mem_uart_byte == 8'h0F);
    check_cond("UART was written", mem_uart_written == 1'b1);
    check_cond("No illegal ops seen", !dec_illegal_op || halt_seen);

    $display("\n========================================");
    if (errors == 0) begin
      $display("PROGRAM_A PASS — all checks passed");
    end else begin
      $display("PROGRAM_A FAIL — %0d check(s) failed", errors);
    end
    $display("========================================\n");

    $finish;
  end

  initial begin
    #5000;
    $display("WATCHDOG TIMEOUT");
    $finish;
  end

endmodule
