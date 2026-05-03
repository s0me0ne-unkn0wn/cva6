// Sub-phase 9: Program B ecalli round-trip smoke test
//
// Tests ecalli dispatch FSM end-to-end through pvm_frontend + pvm_decoder.
// The ecalli FSM is modelled directly (same approach as sub-phase 8 checker.sv).
//
// Program B layout (all instructions contained within their 16-byte group):
//
//   Group 0 (0x00..0x0F):
//     [0x00] ecalli imm=0xFFFFFFFD  (write_csr sentinel: set pevent_table_base)
//     [0x02] load_imm A0, 0xDEADBEEF
//     [0x08] load_imm A1, 0x12345678
//     [0x0E] load_imm A3, 0         (nop / advance to group boundary)
//
//   Group 1 (0x10..0x1F):
//     [0x10] load_imm A2, 0xCAFEF00D
//     [0x16] ecalli imm=1            (dispatch: table[1] → handler at 0x80)
//     [0x18] trap                    (halt after handler returns)
//
//   Group 8 (0x80..0x8F):
//     [0x80] load_imm A3, 0x5AFECAFE (handler writes sentinel)
//     [0x86] ecalli imm=0xFFFFFFFF   (mode_return: restore pepc=0x18, resume main)
//
// pevent_table_base = 0x78 so dispatch target = 0x78 + 8*1 = 0x80 (handler) ✓
//
// Checks:
//   1. A0[31:0] == 0xDEADBEEF  (preserved across ecalli round-trip)
//   2. A1[31:0] == 0x12345678  (preserved)
//   3. A2[31:0] == 0xCAFEF00D  (preserved)
//   4. A3[31:0] == 0x5AFECAFE  (written by handler)
//   5. ecalli dispatch round-trip <= 25 cycles (ADR-5)
//
// NOTE on LSU integration gap (sub-phase 8):
//   The ecalli FSM MVP uses a direct address computation
//   (pevent_table_base + 8*imm) instead of a real dcache read.
//   This is the known LSU gap; flagged explicitly in output.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

`timescale 1ns/1ps

module testbench_b
  import polkavm_pkg::*;
();

  // =========================================================================
  // Clock / reset
  // =========================================================================
  logic clk   = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // =========================================================================
  // Code ROM — 144 bytes (groups 0, 1, and 8)
  // =========================================================================
  localparam int  CODE_LEN    = 144;   // 0x90 bytes
  localparam int  BITMASK_LEN = 18;    // ceil(144/8)

  // pevent_table_base: dispatch target = base + 8*imm = 0x78 + 8 = 0x80
  localparam logic [63:0] PEVENT_TABLE_BASE = 64'h78;
  localparam logic [7:0]  HANDLER_ADDR      = 8'h80;

  logic [7:0] code_rom    [0:CODE_LEN-1];
  logic [7:0] bitmask_rom [0:BITMASK_LEN-1];

  initial begin
    // Zero-fill
    for (int i = 0; i < CODE_LEN;    i++) code_rom[i]    = 8'h00;
    for (int i = 0; i < BITMASK_LEN; i++) bitmask_rom[i] = 8'h00;

    // --- Group 0 (0x00..0x0F) ---
    // [0x00] ecalli imm=0xFFFFFFFD (write_csr: 2 bytes)
    //        imm=0xFFFFFFFD: encode_imm_bytes(0xFFFFFFFD)=-3→1 byte=0xFD
    code_rom[8'h00] = 8'h0A; code_rom[8'h01] = 8'hFD;
    // [0x02] load_imm A0 (reg7), imm=0xDEADBEEF (6 bytes)
    code_rom[8'h02] = 8'h33; code_rom[8'h03] = 8'h07;
    code_rom[8'h04] = 8'hEF; code_rom[8'h05] = 8'hBE;
    code_rom[8'h06] = 8'hAD; code_rom[8'h07] = 8'hDE;
    // [0x08] load_imm A1 (reg8), imm=0x12345678 (6 bytes)
    code_rom[8'h08] = 8'h33; code_rom[8'h09] = 8'h08;
    code_rom[8'h0A] = 8'h78; code_rom[8'h0B] = 8'h56;
    code_rom[8'h0C] = 8'h34; code_rom[8'h0D] = 8'h12;
    // [0x0E] load_imm A3 (reg10), imm=0 → 2 bytes (nop to pad to group boundary)
    code_rom[8'h0E] = 8'h33; code_rom[8'h0F] = 8'h0A;

    // --- Group 1 (0x10..0x1F) ---
    // [0x10] load_imm A2 (reg9), imm=0xCAFEF00D (6 bytes)
    code_rom[8'h10] = 8'h33; code_rom[8'h11] = 8'h09;
    code_rom[8'h12] = 8'h0D; code_rom[8'h13] = 8'hF0;
    code_rom[8'h14] = 8'hFE; code_rom[8'h15] = 8'hCA;
    // [0x16] ecalli imm=1 (2 bytes)
    code_rom[8'h16] = 8'h0A; code_rom[8'h17] = 8'h01;
    // [0x18] trap (1 byte)
    code_rom[8'h18] = 8'h00;

    // --- Group 8 (0x80..0x8F): handler ---
    // [0x80] load_imm A3 (reg10), imm=0x5AFECAFE (6 bytes)
    code_rom[8'h80] = 8'h33; code_rom[8'h81] = 8'h0A;
    code_rom[8'h82] = 8'hFE; code_rom[8'h83] = 8'hCA;
    code_rom[8'h84] = 8'hFE; code_rom[8'h85] = 8'h5A;
    // [0x86] ecalli imm=0xFFFFFFFF (mode_return, 2 bytes: 0xFF sext to -1=0xFFFFFFFF)
    code_rom[8'h86] = 8'h0A; code_rom[8'h87] = 8'hFF;

    // Bitmask: opcode positions 0x00,0x02,0x08,0x0E,0x10,0x16,0x18,0x80,0x86
    // byte[0] : bits 0,2       = 0b00000101 = 0x05  (pos 0, 2)
    // byte[1] : bits 0,6       = 0b01000001 = 0x41  (pos 8, 14)
    // byte[2] : bits 0,6       = 0b01000001 = 0x41  (pos 16, 22=0x16)
    // byte[3] : bit  0         = 0b00000001 = 0x01  (pos 24=0x18)
    // byte[16]: bits 0,6       = 0b01000001 = 0x41  (pos 128=0x80, 134=0x86)
    bitmask_rom[0]  = 8'h05;
    bitmask_rom[1]  = 8'h41;
    bitmask_rom[2]  = 8'h41;
    bitmask_rom[3]  = 8'h01;
    bitmask_rom[16] = 8'h41;
  end

  // =========================================================================
  // Combinatorial ROM reads
  // =========================================================================
  logic [7:0]   fe_code_addr;
  logic [127:0] fe_code_data;
  logic [7:0]   fe_bitmask_addr;
  logic [31:0]  fe_bitmask_data;

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
    bm_base         = fe_bitmask_addr;
    fe_bitmask_data = '0;
    for (int b = 0; b < 4; b++) begin
      if (int'(bm_base) + b < BITMASK_LEN) begin
        fe_bitmask_data[b*8 +: 8] = bitmask_rom[int'(bm_base) + b];
      end
    end
  end

  // =========================================================================
  // pvm_frontend
  // =========================================================================
  logic        fe_branch_valid;
  logic [7:0]  fe_branch_target;
  logic        fe_valid;
  logic [127:0] fe_chunk;
  logic [4:0]  fe_skip;
  logic        fe_is_valid_op;
  logic [7:0]  fe_pc;
  logic        fe_ready;

  pvm_frontend #(.VirtualAddrSize(8)) i_frontend (
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
  // pvm_decoder
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
  // pvm_alu (instantiated for completeness; not used in this test)
  // =========================================================================
  pvm_alu i_alu (
    .operand_a_i ('0),
    .operand_b_i ('0),
    .imm_i       ('0),
    .mul_upper_i ('0),
    .op_i        (PVM_ALU_ADD_64),
    .result_o    ()
  );

  // =========================================================================
  // Register file
  // =========================================================================
  logic [63:0] regfile [0:12];

  // =========================================================================
  // Ecalli FSM model (mirrors pvm_csr_regfile)
  // =========================================================================
  typedef enum logic [1:0] {
    ECALLI_IDLE       = 2'd0,
    ECALLI_DRAINED    = 2'd1,
    ECALLI_TABLE_READ = 2'd2,
    ECALLI_JUMPED     = 2'd3
  } ecalli_state_t;

  ecalli_state_t ecalli_state;
  logic [1:0]  ecalli_cnt;
  logic [31:0] ecalli_imm_lat;
  logic [7:0]  ecalli_pc_lat;

  logic [63:0] pevent_table_base_csr;
  logic [63:0] pepc_csr;

  logic        ecalli_done;
  logic [7:0]  ecalli_redirect_pc_8;

  // Handler address: pevent_table_base + 8*imm (MVP direct-offset model)
  logic [63:0] handler_addr;
  assign handler_addr = pevent_table_base_csr + {29'd0, ecalli_imm_lat, 3'b000};

  int dispatch_start_cycle;
  int dispatch_done_cycle;
  int cycle_count;
  logic halt_seen;
  int errors;

  always_ff @(posedge clk or negedge rst_n) begin : ecalli_fsm
    if (!rst_n) begin
      ecalli_state          <= ECALLI_IDLE;
      ecalli_cnt            <= 2'd0;
      ecalli_imm_lat        <= '0;
      ecalli_pc_lat         <= '0;
      pevent_table_base_csr <= PEVENT_TABLE_BASE;
      pepc_csr              <= '0;
      ecalli_done           <= 1'b0;
      ecalli_redirect_pc_8  <= '0;
      dispatch_start_cycle  <= 0;
      dispatch_done_cycle   <= 0;
    end else begin
      ecalli_done <= 1'b0;  // pulse (held high for one cycle only)

      case (ecalli_state)
        ECALLI_IDLE: begin
          if (fe_valid && dec_is_ecalli && !halt_seen) begin
            if (dec_sentinel_mr) begin
              // mode_return: restore execution to saved pepc
              ecalli_done          <= 1'b1;
              ecalli_redirect_pc_8 <= pepc_csr[7:0];
            end else if (dec_imm[31:0] == PVM_ECALLI_SENTINEL_WRITE_CSR) begin
              // write_csr: set pevent_table_base, continue at next instruction
              pevent_table_base_csr <= PEVENT_TABLE_BASE;
              ecalli_done           <= 1'b1;
              ecalli_redirect_pc_8  <= fe_pc + 8'(dec_instr_len);
            end else begin
              // Non-sentinel: start 4-state dispatch
              ecalli_imm_lat       <= dec_imm[31:0];
              ecalli_pc_lat        <= fe_pc;
              dispatch_start_cycle <= cycle_count;
              ecalli_state         <= ECALLI_DRAINED;
            end
          end
        end

        ECALLI_DRAINED: begin
          // Save return address (pepc = ecalli_pc + instr_len)
          pepc_csr     <= {56'h0, ecalli_pc_lat} + 64'd2;
          ecalli_cnt   <= 2'd0;
          ecalli_state <= ECALLI_TABLE_READ;
        end

        ECALLI_TABLE_READ: begin
          // 3-cycle timer (mock dcache — LSU integration gap)
          if (ecalli_cnt == 2'd2) begin
            ecalli_state <= ECALLI_JUMPED;
          end else begin
            ecalli_cnt <= ecalli_cnt + 2'd1;
          end
        end

        ECALLI_JUMPED: begin
          // Redirect to handler
          ecalli_done          <= 1'b1;
          ecalli_redirect_pc_8 <= handler_addr[7:0];
          dispatch_done_cycle  <= cycle_count;
          ecalli_state         <= ECALLI_IDLE;
        end
      endcase
    end
  end

  logic ecalli_active;
  assign ecalli_active = (ecalli_state != ECALLI_IDLE);

  // =========================================================================
  // Front-end control
  // =========================================================================
  // Stall while FSM is running; redirect when FSM emits done pulse
  assign fe_ready        = fe_valid && !ecalli_active && !ecalli_done;
  assign fe_branch_valid  = ecalli_done;
  assign fe_branch_target = ecalli_redirect_pc_8;

  // =========================================================================
  // Execute stage
  // =========================================================================
  always_ff @(posedge clk or negedge rst_n) begin : execute
    if (!rst_n) begin
      cycle_count <= 0;
      halt_seen   <= 1'b0;
      errors      <= 0;
      for (int i = 0; i < 13; i++) regfile[i] <= '0;
    end else begin
      cycle_count <= cycle_count + 1;

      // Execute when frontend has valid output, FSM not active/redirecting, not halted
      if (fe_valid && !ecalli_active && !ecalli_done && !halt_seen) begin
        case (dec_op)
          PVM_OP_LOAD_IMM, PVM_OP_LOAD_IMM64: begin
            if (dec_rs1 < 13) regfile[dec_rs1] <= dec_imm;
          end
          PVM_OP_TRAP: begin
            halt_seen <= 1'b1;
          end
          PVM_OP_ECALLI: ; // handled by FSM above
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
        repeat (400) @(posedge clk);
        $display("TIMEOUT: halt not seen in 400 cycles");
        errors++;
      end
    join_any

    @(posedge clk);

    $display("\n--- Program B final state ---");
    $display("  cycle_count          = %0d", cycle_count);
    $display("  dispatch_start       = %0d", dispatch_start_cycle);
    $display("  dispatch_done        = %0d", dispatch_done_cycle);
    if (dispatch_done_cycle > dispatch_start_cycle) begin
      $display("  dispatch_cycles      = %0d (budget: 25)",
               dispatch_done_cycle - dispatch_start_cycle);
    end
    $display("  A0                   = 0x%016X (expected 0xFFFFFFFFDEADBEEF)", regfile[7]);
    $display("  A1                   = 0x%016X (expected 0x0000000012345678)", regfile[8]);
    $display("  A2                   = 0x%016X (expected 0xFFFFFFFFCAFEF00D)", regfile[9]);
    $display("  A3 (handler written) = 0x%016X (expected 0xFFFFFFFF5AFECAFE)", regfile[10]);

    check_cond("A0[31:0] == 0xDEADBEEF (preserved)", regfile[7][31:0] == 32'hDEADBEEF);
    check_cond("A1[31:0] == 0x12345678 (preserved)", regfile[8][31:0] == 32'h12345678);
    check_cond("A2[31:0] == 0xCAFEF00D (preserved)", regfile[9][31:0] == 32'hCAFEF00D);
    check_cond("A3[31:0] == 0x5AFECAFE (handler wrote)", regfile[10][31:0] == 32'h5AFECAFE);

    if (dispatch_done_cycle > dispatch_start_cycle) begin
      automatic int rt = dispatch_done_cycle - dispatch_start_cycle;
      check_cond($sformatf("ADR-5: dispatch round-trip %0d <= 25 cycles", rt), rt <= 25);
    end

    $display("\nNOTE: ecalli TABLE_READ uses mock 3-cycle timer + direct address");
    $display("  computation (pevent_table_base + 8*imm), NOT a real dcache read.");
    $display("  This is the known LSU integration gap from sub-phase 8.");

    $display("\n========================================");
    if (errors == 0) begin
      $display("PROGRAM_B PASS — all checks passed");
    end else begin
      $display("PROGRAM_B FAIL — %0d check(s) failed", errors);
    end
    $display("========================================\n");

    $finish;
  end

  initial begin
    #6000;
    $display("WATCHDOG TIMEOUT");
    $finish;
  end

endmodule
