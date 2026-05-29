// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// Standalone self-checking testbench for pvm_front.sv (Stage 3 wrapper gate).
// Loads the real example-hello-world image into the wrapper's behavioral image
// memory via the loader write port, programs the control regs, enters PVM mode,
// and (with issue_ack held high) checks the emitted micro-op stream against the
// golden decode + that the run halts after the terminator (jump_ind).

module pvm_front_tb;
  import ariane_pkg::*;
  import polkavm_pkg::*;

  localparam int VLEN = 32;
  localparam int CLEN = 25;
  localparam int BM_BASE = 32;  // bitmask placed at byte 32 in the image

  logic            clk = 1'b0;
  logic            rst_n;
  logic            pvm_active, resume, issue_ack, img_we;
  logic [VLEN-1:0] entry_pc, code_len, code_base, bitmask_base, img_addr;
  logic [7:0]      img_wdata;

  logic            valid, is_branch, is_jump, is_hostcall, is_trap, illegal, unsupported, halted;
  logic [VLEN-1:0] pc, btgt;
  fu_t             fu;
  fu_op            op;
  logic [4:0]      rd, rs1, rs2;
  logic [63:0]     imm, hcid;

  pvm_front #(.VLEN(VLEN), .IMG_BYTES(4096)) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .pvm_active_i(pvm_active), .resume_i(resume), .entry_pc_i(entry_pc), .code_len_i(code_len),
      .code_base_i(code_base), .bitmask_base_i(bitmask_base),
      .img_we_i(img_we), .img_addr_i(img_addr), .img_wdata_i(img_wdata),
      .issue_ack_i(issue_ack),
      .valid_o(valid), .pc_o(pc), .fu_o(fu), .op_o(op),
      .rd_o(rd), .rs1_o(rs1), .rs2_o(rs2), .imm_o(imm), .use_imm_o(),
      .is_branch_o(is_branch), .is_jump_o(is_jump), .branch_target_o(btgt),
      .is_hostcall_o(is_hostcall), .hostcall_id_o(hcid), .is_trap_o(is_trap),
      .illegal_o(illegal), .unsupported_o(unsupported), .halted_o(halted)
  );

  always #5 clk = ~clk;

  logic [7:0] code_b [0:CLEN-1];
  logic [7:0] bm_b   [0:3];

  localparam int N = 10;
  fu_t  g_fu [0:N-1];
  fu_op g_op [0:N-1];
  fu_t  o_fu [0:N-1];
  fu_op o_op [0:N-1];
  logic o_host [0:N-1];
  logic o_jump [0:N-1];
  int   n_obs = 0, errors = 0;
  logic sample_en = 1'b0;

  always @(posedge clk) begin
    if (sample_en && valid && n_obs < N) begin
      o_fu[n_obs] = fu; o_op[n_obs] = op; o_host[n_obs] = is_hostcall; o_jump[n_obs] = is_jump;
      n_obs = n_obs + 1;
    end
  end

  task automatic wr(input logic [VLEN-1:0] a, input logic [7:0] d);
    img_we = 1'b1; img_addr = a; img_wdata = d; @(posedge clk);
    img_we = 1'b0;
  endtask

  initial begin
    code_b = '{8'h83,8'h11,8'hf8,8'h7a,8'h10,8'h04,8'h7a,8'h15,8'hbe,8'h78,
               8'h05,8'h0a,8'hbe,8'h57,8'h07,8'h81,8'h10,8'h04,8'h81,8'h15,
               8'h83,8'h11,8'h08,8'h32,8'h00};
    bm_b = '{8'h49,8'h99,8'h94,8'h00};
    g_fu = '{ALU, STORE, STORE, ALU, NONE, ALU, LOAD, LOAD, ALU, CTRL_FLOW};
    g_op = '{ADDW, SW, SW, ADDW, ADD, ADDW, LW, LW, ADDW, JALR};

    rst_n=1'b0; pvm_active=1'b0; resume=1'b0; issue_ack=1'b0; img_we=1'b0;
    entry_pc='0; code_len=VLEN'(CLEN); code_base='0; bitmask_base=VLEN'(BM_BASE);
    img_addr='0; img_wdata='0;
    repeat (3) @(posedge clk);
    rst_n=1'b1; @(posedge clk);

    // load image: code at 0, bitmask at BM_BASE
    for (int i = 0; i < CLEN; i++) wr(VLEN'(i), code_b[i]);
    for (int i = 0; i < 4; i++)    wr(VLEN'(BM_BASE + i), bm_b[i]);
    @(posedge clk);

    // enter PVM mode; the fetch runs indices 0..4 and suspends at the ecalli
    // (index 4) host-call (halt_i = is_hostcall), modelling the M-mode trap.
    sample_en = 1'b1;
    issue_ack = 1'b1;
    pvm_active = 1'b1;
    wait (n_obs == 5);                // indices 0..4 sampled; fetch suspends at ecalli@4
    @(posedge clk);
    // M-mode "handler" resumes the guest: re-activate with the resume bit so the
    // fetch continues at the post-ecalli pc it saved (indices 5..9).
    pvm_active = 1'b0; @(posedge clk);
    resume = 1'b1; pvm_active = 1'b1;
    repeat (30) @(posedge clk);
    sample_en = 1'b0;

    if (n_obs != N) begin errors++; $display("FAIL: observed %0d, expected %0d", n_obs, N); end
    for (int i = 0; i < N && i < n_obs; i++) begin
      if (o_fu[i] !== g_fu[i]) begin errors++; $display("FAIL i%0d fu got=%0d exp=%0d", i, int'(o_fu[i]), int'(g_fu[i])); end
      if (i != 4 && o_op[i] !== g_op[i]) begin errors++; $display("FAIL i%0d op got=%0d exp=%0d", i, int'(o_op[i]), int'(g_op[i])); end
    end
    if (n_obs > 4 && o_host[4] !== 1'b1) begin errors++; $display("FAIL i4 hostcall not set"); end
    if (n_obs > 9 && o_jump[9] !== 1'b1) begin errors++; $display("FAIL i9 jump not set"); end
    // after the run, must report halted
    if (halted !== 1'b1) begin errors++; $display("FAIL: not halted after run (halted=%0b)", halted); end

    if (errors != 0) begin
      $display("PVM_FRONT_TB: %0d CHECK(S) FAILED", errors);
      $fatal(1, "pvm_front_tb failed");
    end else begin
      $display("PVM_FRONT_TB: ALL CHECKS PASSED (%0d uops; halted)", n_obs);
    end
    $finish;
  end

  initial begin
    repeat (4000) @(posedge clk);
    $fatal(1, "timeout");
  end

endmodule
