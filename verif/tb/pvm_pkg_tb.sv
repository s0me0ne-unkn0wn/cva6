// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// Standalone self-checking testbench for polkavm_pkg.sv (Stage 0 gate).
// Verifies the JAM v1 opcode argument-family classifier, the block-terminator
// set T, the valid-opcode set U, and the register-clamp helpers against the
// graypaper spec. Runs with:
//   $ verilator --binary -sv core/include/polkavm_pkg.sv verif/tb/pvm_pkg_tb.sv \
//             --top-module pvm_pkg_tb -o pvm_pkg_tb && ./obj_dir/pvm_pkg_tb
// Exits non-zero (via $fatal) on any mismatch.

module pvm_pkg_tb;
  import polkavm_pkg::*;

  int errors = 0;

  // ---- check helpers -------------------------------------------------------
  task automatic chk_fam(input logic [7:0] op, input pvm_arg_family_e exp);
    pvm_arg_family_e got;
    got = pvm_arg_family(op);
    if (got !== exp) begin
      errors++;
      $display("FAIL arg_family(op=%0d): got=%0d exp=%0d", op, int'(got), int'(exp));
    end
  endtask

  task automatic chk_term(input logic [7:0] op, input logic exp);
    if (pvm_is_terminator(op) !== exp) begin
      errors++;
      $display("FAIL is_terminator(op=%0d): got=%0b exp=%0b", op, pvm_is_terminator(op), exp);
    end
  endtask

  task automatic chk_valid(input logic [7:0] op, input logic exp);
    if (pvm_is_valid_opcode(op) !== exp) begin
      errors++;
      $display("FAIL is_valid(op=%0d): got=%0b exp=%0b", op, pvm_is_valid_opcode(op), exp);
    end
  endtask

  task automatic chk_reg(input logic [3:0] got, input logic [3:0] exp, input string what);
    if (got !== exp) begin
      errors++;
      $display("FAIL %s: got=%0d exp=%0d", what, got, exp);
    end
  endtask

  task automatic chk_u64(input logic [63:0] got, input logic [63:0] exp, input string what);
    if (got !== exp) begin
      errors++;
      $display("FAIL %s: got=%h exp=%h", what, got, exp);
    end
  endtask

  initial begin
    // ---- argument families: one+ representative per family ----------------
    chk_fam(8'd0,   PVM_ARG_NONE);        // trap
    chk_fam(8'd1,   PVM_ARG_NONE);        // fallthrough
    chk_fam(8'd2,   PVM_ARG_NONE);        // unlikely
    chk_fam(8'd237, PVM_ARG_NONE);        // mret
    chk_fam(8'd239, PVM_ARG_NONE);        // wfi
    chk_fam(8'd10,  PVM_ARG_IMM);         // ecalli
    chk_fam(8'd20,  PVM_ARG_REG_IMMEXT);  // load_imm_64
    chk_fam(8'd30,  PVM_ARG_2IMM);        // store_imm_u8
    chk_fam(8'd33,  PVM_ARG_2IMM);        // store_imm_u64
    chk_fam(8'd40,  PVM_ARG_OFFSET);      // jump
    chk_fam(8'd50,  PVM_ARG_REG_IMM);     // jump_ind
    chk_fam(8'd51,  PVM_ARG_REG_IMM);     // load_imm
    chk_fam(8'd62,  PVM_ARG_REG_IMM);     // store_u64
    chk_fam(8'd70,  PVM_ARG_REG_2IMM);    // store_imm_ind_u8
    chk_fam(8'd73,  PVM_ARG_REG_2IMM);    // store_imm_ind_u64
    chk_fam(8'd80,  PVM_ARG_REG_IMM_OFF); // load_imm_jump
    chk_fam(8'd81,  PVM_ARG_REG_IMM_OFF); // branch_eq_imm
    chk_fam(8'd90,  PVM_ARG_REG_IMM_OFF); // branch_gt_s_imm
    chk_fam(8'd100, PVM_ARG_2REG);        // move_reg
    chk_fam(8'd110, PVM_ARG_2REG);        // reverse_bytes
    chk_fam(8'd240, PVM_ARG_2REG);        // sfence_vma
    chk_fam(8'd120, PVM_ARG_2REG_IMM);    // store_ind_u8
    chk_fam(8'd131, PVM_ARG_2REG_IMM);    // add_imm_32
    chk_fam(8'd161, PVM_ARG_2REG_IMM);    // rot_r_32_imm_alt
    chk_fam(8'd231, PVM_ARG_2REG_IMM);    // csr_rw
    chk_fam(8'd236, PVM_ARG_2REG_IMM);    // csr_rci
    chk_fam(8'd170, PVM_ARG_2REG_OFF);    // branch_eq
    chk_fam(8'd175, PVM_ARG_2REG_OFF);    // branch_ge_s
    chk_fam(8'd180, PVM_ARG_2REG_2IMM);   // load_imm_jump_ind
    chk_fam(8'd190, PVM_ARG_3REG);        // add_32
    chk_fam(8'd200, PVM_ARG_3REG);        // add_64
    chk_fam(8'd210, PVM_ARG_3REG);        // and
    chk_fam(8'd230, PVM_ARG_3REG);        // minimum_unsigned

    // ---- invalid opcodes (gaps in set U) ----------------------------------
    chk_fam(8'd3,   PVM_ARG_INVALID);
    chk_fam(8'd11,  PVM_ARG_INVALID);
    chk_fam(8'd41,  PVM_ARG_INVALID);
    chk_fam(8'd63,  PVM_ARG_INVALID);
    chk_fam(8'd111, PVM_ARG_INVALID);
    chk_fam(8'd162, PVM_ARG_INVALID);
    chk_fam(8'd176, PVM_ARG_INVALID);
    chk_fam(8'd181, PVM_ARG_INVALID);
    chk_fam(8'd241, PVM_ARG_INVALID);
    chk_fam(8'd255, PVM_ARG_INVALID);

    // ---- block-terminator set T -------------------------------------------
    chk_term(8'd0,   1'b1);  // trap
    chk_term(8'd1,   1'b1);  // fallthrough
    chk_term(8'd40,  1'b1);  // jump
    chk_term(8'd50,  1'b1);  // jump_ind
    chk_term(8'd80,  1'b1);  // load_imm_jump
    chk_term(8'd180, 1'b1);  // load_imm_jump_ind
    chk_term(8'd81,  1'b1);  // branch_eq_imm
    chk_term(8'd90,  1'b1);  // branch_gt_s_imm
    chk_term(8'd170, 1'b1);  // branch_eq
    chk_term(8'd175, 1'b1);  // branch_ge_s
    chk_term(8'd2,   1'b0);  // unlikely is NOT a terminator
    chk_term(8'd10,  1'b0);  // ecalli
    chk_term(8'd51,  1'b0);  // load_imm
    chk_term(8'd100, 1'b0);  // move_reg
    chk_term(8'd120, 1'b0);  // store_ind_u8
    chk_term(8'd190, 1'b0);  // add_32

    // ---- valid-opcode set U ------------------------------------------------
    chk_valid(8'd0,   1'b1);
    chk_valid(8'd190, 1'b1);
    chk_valid(8'd240, 1'b1);
    chk_valid(8'd11,  1'b0);
    chk_valid(8'd241, 1'b0);

    // ---- register-clamp helpers (min(12, nibble)) -------------------------
    chk_reg(pvm_clamp_reg(4'd15), 4'd12, "clamp(15)");
    chk_reg(pvm_clamp_reg(4'd13), 4'd12, "clamp(13)");
    chk_reg(pvm_clamp_reg(4'd12), 4'd12, "clamp(12)");
    chk_reg(pvm_clamp_reg(4'd11), 4'd11, "clamp(11)");
    chk_reg(pvm_clamp_reg(4'd0),  4'd0,  "clamp(0)");
    chk_reg(pvm_reg_lo(8'hA5), 4'd5,  "reg_lo(A5)");
    chk_reg(pvm_reg_hi(8'hA5), 4'd10, "reg_hi(A5)");
    chk_reg(pvm_reg_lo(8'hFF), 4'd12, "reg_lo(FF)");
    chk_reg(pvm_reg_hi(8'hFF), 4'd12, "reg_hi(FF)");

    // ---- immediate helpers (little-endian assembly + sign-extend) ---------
    begin
      logic [127:0] win;
      win = '0;
      win[7:0]   = 8'hAA;  // byte 0
      win[15:8]  = 8'hBB;  // byte 1
      win[23:16] = 8'hF8;  // byte 2
      chk_u64(pvm_le_bytes(win, 0, 2), 64'h0000_0000_0000_BBAA, "le_bytes(0,2)");
      chk_u64(pvm_le_bytes(win, 1, 1), 64'h0000_0000_0000_00BB, "le_bytes(1,1)");
      chk_u64(pvm_le_bytes(win, 0, 0), 64'd0,                    "le_bytes(0,0)");
      chk_u64(pvm_sext(64'h0000_0000_0000_00F8, 1), 64'hFFFF_FFFF_FFFF_FFF8, "sext(F8,1)");
      chk_u64(pvm_sext(64'h0000_0000_0000_0078, 1), 64'h0000_0000_0000_0078, "sext(78,1)");
      chk_u64(pvm_sext(64'h0000_0000_FFFF_FFF8, 4), 64'hFFFF_FFFF_FFFF_FFF8, "sext(neg32,4)");
      chk_u64(pvm_sext(64'hDEAD_BEEF_CAFE_0001, 8), 64'hDEAD_BEEF_CAFE_0001, "sext(full,8)");
      chk_u64(pvm_sext(64'h0000_0000_0000_1234, 0), 64'd0,                    "sext(x,0)");
    end

    if (errors != 0) begin
      $display("PVM_PKG_TB: %0d CHECK(S) FAILED", errors);
      $fatal(1, "pvm_pkg_tb failed");
    end else begin
      $display("PVM_PKG_TB: ALL CHECKS PASSED");
    end
    $finish;
  end

endmodule
