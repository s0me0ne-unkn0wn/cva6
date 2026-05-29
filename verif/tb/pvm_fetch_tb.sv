// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// Standalone self-checking testbench for pvm_fetch.sv (Stage 1 gate).
// Stimulus = the real example-hello-world.polkavm image: 25 code bytes plus
// the raw emit-image bitmask `49 99 94 00` (fed as raw bytes so the DUT must
// itself decode LSB-first). Golden instruction-counter sequence + skip values
// were derived by cross-checking `polkatool disassemble` (see
// logs/04-pvm-in-hw/CLAUDE.md "Stage 1 golden fetch vector").
//
// Build & run (example):
//   $ verilator --binary -sv core/include/polkavm_pkg.sv core/pvm_fetch.sv \
//       verif/tb/pvm_fetch_tb.sv --top-module pvm_fetch_tb -o pvm_fetch_tb \
//       && ./obj_dir/pvm_fetch_tb
// Exits non-zero (via $fatal) on any mismatch.

module pvm_fetch_tb;
  localparam int VLEN = 32;
  localparam int CLEN = 25;  // |c| for hello-world

  logic            clk = 1'b0;
  logic            rst_n;
  logic            start;
  logic [VLEN-1:0] entry_pc;
  logic [VLEN-1:0] code_len;
  logic            next_ready;
  logic [127:0]    code_window;
  logic [31:0]     bm_window;

  logic            valid;
  logic [VLEN-1:0] pc;
  logic [VLEN-1:0] code_addr;
  logic [7:0]      opcode;
  logic [127:0]    instr_window;
  logic [4:0]      skip;
  logic [VLEN-1:0] next_pc;
  logic            terminator;

  // ---- code + bitmask memory (golden hello-world image) --------------------
  logic [7:0] code_mem [0:31];
  logic       bm_bits  [0:47];
  logic [7:0] bm_bytes [0:3];

  // ---- DUT -----------------------------------------------------------------
  pvm_fetch #(.VLEN(VLEN)) dut (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .start_i       (start),
      .resume_i      (1'b0),
      .entry_pc_i    (entry_pc),
      .code_len_i    (code_len),
      .next_ready_i  (next_ready),
      .halt_i        (1'b0),
      .redirect_valid_i(1'b0),
      .redirect_pc_i ('0),
      .code_window_i (code_window),
      .bm_window_i   (bm_window),
      .valid_o       (valid),
      .pc_o          (pc),
      .code_addr_o   (code_addr),
      .opcode_o      (opcode),
      .instr_window_o(instr_window),
      .skip_o        (skip),
      .next_pc_o     (next_pc),
      .terminator_o  (terminator)
  );

  // ---- combinational BRAM windows addressed by code_addr -------------------
  always_comb begin : p_windows
    int unsigned idx;
    int unsigned posn;
    for (int b = 0; b < 16; b++) begin
      idx = code_addr + b;
      code_window[b*8+:8] = (idx < 32) ? code_mem[idx] : 8'h00;
    end
    for (int k = 0; k < 32; k++) begin
      posn = code_addr + 1 + k;
      bm_window[k] = (posn < 48) ? bm_bits[posn] : 1'b1;
    end
  end

  always #5 clk = ~clk;

  // ---- golden reference ----------------------------------------------------
  localparam int NSTART = 10;
  int golden_pc   [0:NSTART-1];
  int golden_skip [0:NSTART-1];

  int    obs_pc   [0:63];
  int    obs_skip [0:63];
  logic  obs_term [0:63];
  int    n_obs = 0;
  int    errors = 0;
  logic  sample_en = 1'b0;

  // synchronous sampler: capture each presented instruction while valid.
  // (Sampling in always @(posedge) avoids the initial-block #1 phase race that
  // dropped the first instruction; the DUT itself is correct.)
  always @(posedge clk) begin
    if (sample_en && valid) begin
      obs_pc[n_obs]   = pc;
      obs_skip[n_obs] = 32'(skip);
      obs_term[n_obs] = terminator;
      n_obs           = n_obs + 1;
    end
  end

  initial begin
    // code bytes
    for (int i = 0; i < 32; i++) code_mem[i] = 8'h00;
    code_mem[0]=8'h83; code_mem[1]=8'h11; code_mem[2]=8'hf8; code_mem[3]=8'h7a;
    code_mem[4]=8'h10; code_mem[5]=8'h04; code_mem[6]=8'h7a; code_mem[7]=8'h15;
    code_mem[8]=8'hbe; code_mem[9]=8'h78; code_mem[10]=8'h05; code_mem[11]=8'h0a;
    code_mem[12]=8'hbe; code_mem[13]=8'h57; code_mem[14]=8'h07; code_mem[15]=8'h81;
    code_mem[16]=8'h10; code_mem[17]=8'h04; code_mem[18]=8'h81; code_mem[19]=8'h15;
    code_mem[20]=8'h83; code_mem[21]=8'h11; code_mem[22]=8'h08; code_mem[23]=8'h32;
    code_mem[24]=8'h00;

    // raw bitmask bytes from emit-image; decode LSB-first into per-position bits
    bm_bytes[0]=8'h49; bm_bytes[1]=8'h99; bm_bytes[2]=8'h94; bm_bytes[3]=8'h00;
    for (int n = 0; n < 48; n++) bm_bits[n] = 1'b1;            // append-1s past code
    for (int n = 0; n < CLEN; n++)
      bm_bits[n] = bm_bytes[n>>3][n[2:0]];                     // LSB-first

    // golden vector (from polkatool disassemble cross-check)
    golden_pc   = '{0,3,6,8,11,12,15,18,20,23};
    golden_skip = '{2,2,1,2,0, 2,2,1,2,1};

    // ---- drive ----
    rst_n = 1'b0; start = 1'b0; next_ready = 1'b0;
    entry_pc = '0; code_len = VLEN'(CLEN);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    // start pulse
    sample_en  = 1'b1;                                // enable sampler (valid still 0)
    start      = 1'b1; @(posedge clk); start = 1'b0;  // edge: pc<=entry_pc, running<=1
    next_ready = 1'b1;                                // free-run, 1 instruction/cycle

    // let the walker run to completion; the synchronous sampler records each step
    repeat (40) @(posedge clk);
    sample_en  = 1'b0;

    // ---- check ----
    if (n_obs != NSTART) begin
      errors++;
      $display("FAIL: observed %0d instructions, expected %0d", n_obs, NSTART);
    end
    for (int i = 0; i < NSTART && i < n_obs; i++) begin
      if (obs_pc[i] !== golden_pc[i]) begin
        errors++; $display("FAIL: step %0d pc got=%0d exp=%0d", i, obs_pc[i], golden_pc[i]);
      end
      if (obs_skip[i] !== golden_skip[i]) begin
        errors++; $display("FAIL: step %0d skip got=%0d exp=%0d", i, obs_skip[i], golden_skip[i]);
      end
    end
    // terminator must be set ONLY on the last instruction (jump_ind @ pc=23)
    for (int i = 0; i < n_obs; i++) begin
      logic exp_t;
      exp_t = (i == NSTART-1);
      if (obs_term[i] !== exp_t) begin
        errors++;
        $display("FAIL: step %0d (pc=%0d) terminator got=%0b exp=%0b", i, obs_pc[i], obs_term[i], exp_t);
      end
    end

    if (errors != 0) begin
      $display("PVM_FETCH_TB: %0d CHECK(S) FAILED", errors);
      $fatal(1, "pvm_fetch_tb failed");
    end else begin
      $display("PVM_FETCH_TB: ALL CHECKS PASSED (%0d instructions walked)", n_obs);
    end
    $finish;
  end

  // global timeout guard
  initial begin
    repeat (2000) @(posedge clk);
    $display("PVM_FETCH_TB: TIMEOUT");
    $fatal(1, "timeout");
  end

endmodule
