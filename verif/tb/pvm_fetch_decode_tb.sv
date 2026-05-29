// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// Composition testbench: pvm_fetch -> pvm_decoder (Stage 1+2 integration-lite).
// Walks the real example-hello-world image through the fetch unit and feeds each
// fetched instruction straight into the decoder, checking the produced micro-op
// stream (fu/op + hostcall/jump flags) against the golden decode. This proves the
// fetch->decode interface contract that the Stage 3 pipeline integration relies on.

module pvm_fetch_decode_tb;
  import ariane_pkg::*;
  import polkavm_pkg::*;

  localparam int VLEN = 32;
  localparam int CLEN = 25;

  logic            clk = 1'b0;
  logic            rst_n, start, next_ready;
  logic [VLEN-1:0] entry_pc, code_len;
  logic [127:0]    code_window;
  logic [31:0]     bm_window;

  // fetch outputs
  logic            f_valid, f_term;
  logic [VLEN-1:0] f_pc, f_code_addr, f_next_pc;
  logic [7:0]      f_opcode;
  logic [127:0]    f_window;
  logic [4:0]      f_skip;

  // decoder outputs
  fu_t             d_fu;
  fu_op            d_op;
  logic [4:0]      d_rd, d_rs1, d_rs2;
  logic [63:0]     d_imm;
  logic            d_use_imm, d_is_branch, d_is_jump;
  logic [VLEN-1:0] d_btgt;
  logic            d_hostcall;
  logic [63:0]     d_hcid;
  logic            d_trap, d_illegal, d_unsupported;

  logic [7:0] code_mem [0:31];
  logic       bm_bits  [0:47];
  logic [7:0] bm_bytes [0:3];

  pvm_fetch #(.VLEN(VLEN)) i_fetch (
      .clk_i(clk), .rst_ni(rst_n), .start_i(start), .resume_i(1'b0), .entry_pc_i(entry_pc),
      .code_len_i(code_len), .next_ready_i(next_ready), .halt_i(1'b0),
      .redirect_valid_i(1'b0), .redirect_pc_i('0),
      .code_window_i(code_window), .bm_window_i(bm_window),
      .valid_o(f_valid), .pc_o(f_pc), .code_addr_o(f_code_addr), .opcode_o(f_opcode),
      .instr_window_o(f_window), .skip_o(f_skip), .next_pc_o(f_next_pc), .terminator_o(f_term)
  );

  pvm_decoder #(.VLEN(VLEN)) i_dec (
      .opcode_i(f_opcode), .instr_window_i(f_window), .pc_i(f_pc), .skip_i(f_skip),
      .fu_o(d_fu), .op_o(d_op), .rd_o(d_rd), .rs1_o(d_rs1), .rs2_o(d_rs2),
      .imm_o(d_imm), .use_imm_o(d_use_imm), .is_branch_o(d_is_branch), .is_jump_o(d_is_jump),
      .branch_target_o(d_btgt), .is_hostcall_o(d_hostcall), .hostcall_id_o(d_hcid),
      .is_trap_o(d_trap), .illegal_o(d_illegal), .unsupported_o(d_unsupported)
  );

  always_comb begin : p_windows
    int unsigned idx, posn;
    for (int b = 0; b < 16; b++) begin
      idx = f_code_addr + b;
      code_window[b*8+:8] = (idx < 32) ? code_mem[idx] : 8'h00;
    end
    for (int k = 0; k < 32; k++) begin
      posn = f_code_addr + 1 + k;
      bm_window[k] = (posn < 48) ? bm_bits[posn] : 1'b1;
    end
  end

  always #5 clk = ~clk;

  // golden decode of hello-world (per instruction-start)
  localparam int N = 10;
  fu_t   g_fu  [0:N-1];
  fu_op  g_op  [0:N-1];
  int    n_obs = 0;
  int    errors = 0;
  logic  sample_en = 1'b0;

  // observed
  fu_t  o_fu  [0:N-1];
  fu_op o_op  [0:N-1];
  logic o_host[0:N-1];
  logic o_jump[0:N-1];

  always @(posedge clk) begin
    if (sample_en && f_valid && n_obs < N) begin
      o_fu[n_obs]   = d_fu;
      o_op[n_obs]   = d_op;
      o_host[n_obs] = d_hostcall;
      o_jump[n_obs] = d_is_jump;
      n_obs         = n_obs + 1;
    end
  end

  initial begin
    for (int i = 0; i < 32; i++) code_mem[i] = 8'h00;
    code_mem[0]=8'h83; code_mem[1]=8'h11; code_mem[2]=8'hf8; code_mem[3]=8'h7a;
    code_mem[4]=8'h10; code_mem[5]=8'h04; code_mem[6]=8'h7a; code_mem[7]=8'h15;
    code_mem[8]=8'hbe; code_mem[9]=8'h78; code_mem[10]=8'h05; code_mem[11]=8'h0a;
    code_mem[12]=8'hbe; code_mem[13]=8'h57; code_mem[14]=8'h07; code_mem[15]=8'h81;
    code_mem[16]=8'h10; code_mem[17]=8'h04; code_mem[18]=8'h81; code_mem[19]=8'h15;
    code_mem[20]=8'h83; code_mem[21]=8'h11; code_mem[22]=8'h08; code_mem[23]=8'h32;
    code_mem[24]=8'h00;
    bm_bytes[0]=8'h49; bm_bytes[1]=8'h99; bm_bytes[2]=8'h94; bm_bytes[3]=8'h00;
    for (int n = 0; n < 48; n++) bm_bits[n] = 1'b1;
    for (int n = 0; n < CLEN; n++) bm_bits[n] = bm_bytes[n>>3][n[2:0]];

    g_fu = '{ALU, STORE, STORE, ALU, NONE, ALU, LOAD, LOAD, ALU, CTRL_FLOW};
    g_op = '{ADDW, SW, SW, ADDW, ADD, ADDW, LW, LW, ADDW, JALR};
    //         ^ecalli leaves op at default ADD; we check fu=NONE + hostcall instead

    rst_n=1'b0; start=1'b0; next_ready=1'b0; entry_pc='0; code_len=VLEN'(CLEN);
    repeat (3) @(posedge clk);
    rst_n=1'b1; @(posedge clk);
    sample_en=1'b1;
    start=1'b1; @(posedge clk); start=1'b0;
    next_ready=1'b1;
    repeat (40) @(posedge clk);
    sample_en=1'b0;

    if (n_obs != N) begin errors++; $display("FAIL: observed %0d, expected %0d", n_obs, N); end
    for (int i = 0; i < N && i < n_obs; i++) begin
      if (o_fu[i] !== g_fu[i]) begin
        errors++; $display("FAIL instr %0d: fu got=%0d exp=%0d", i, int'(o_fu[i]), int'(g_fu[i]));
      end
      // op only meaningful for non-ecalli (i!=4)
      if (i != 4 && o_op[i] !== g_op[i]) begin
        errors++; $display("FAIL instr %0d: op got=%0d exp=%0d", i, int'(o_op[i]), int'(g_op[i]));
      end
    end
    // ecalli at index 4
    if (n_obs > 4 && o_host[4] !== 1'b1) begin errors++; $display("FAIL instr4: ecalli hostcall not set"); end
    // jump_ind at index 9
    if (n_obs > 9 && o_jump[9] !== 1'b1) begin errors++; $display("FAIL instr9: jump_ind is_jump not set"); end

    if (errors != 0) begin
      $display("PVM_FETCH_DECODE_TB: %0d CHECK(S) FAILED", errors);
      $fatal(1, "pvm_fetch_decode_tb failed");
    end else begin
      $display("PVM_FETCH_DECODE_TB: ALL CHECKS PASSED (%0d instructions fetched+decoded)", n_obs);
    end
    $finish;
  end

  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "timeout");
  end

endmodule
