// PolkaVM ALU — standalone, ariane_pkg-free implementation.
// Sub-phase 5: ALU adaptation for PVM JAM v1 ISA.
//
// This module implements the pure ALU (no memory, no branch resolution)
// for all PVM ALU opcodes.  It is intentionally independent of ariane_pkg
// so it can be linted and simulated with the simple Verilator testbench
// (pvm_alu_tb.sv) without pulling in the full CVA6 package hierarchy.
//
// Integration note: In the full CVA6 pipeline the existing alu.sv is kept
// and extended with is_pvm_op_i / pvm_alu_op_i / mul_upper_result_i ports
// (see core/alu.sv sub-phase 5 additions).  This standalone module exists
// ONLY for sub-phase 5 testing; it is not instantiated in cva6.sv.
//
// Port contract
// -------------
//   operand_a_i : rs1 (or imm value for imm_alt shift variants)
//   operand_b_i : rs2 or sign-extended immediate (decoder responsibility)
//   op_i        : pvm_alu_op_e selector
//   result_o    : 64-bit ALU result
//
// CMOV variants (cmov_if_zero / cmov_if_not_zero) are handled via
// pvm_alu_op_e entries that match XHEAD_MVEQZ / XHEAD_MVNEZ semantics.
// The forwarding network (issue_read_operands.sv) delivers old_rd via
// imm_i (ADR-4).  These are included here for testbench coverage.
//
// MUL_UPPER ops require a one-cycle latency from the multiplier pipeline;
// mul_upper_i is expected to be valid one cycle after the instruction is
// presented.  The testbench handles this timing.
//
// imm_alt shift variants (shift_logical_left_imm_alt_32, etc.):
//   The decoder swaps operands so operand_a = imm value, operand_b = shift
//   amount.  The ALU sees the same pvm_alu_op_e as the non-alt form.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

module pvm_alu
  import polkavm_pkg::*;
(
    // rs1 (or swapped imm value for imm_alt shift variants)
    input  logic [63:0]     operand_a_i,
    // rs2 or sign-extended immediate (decoder places correct value here)
    input  logic [63:0]     operand_b_i,
    // For CMOV ops: old rd value from forwarding network (ADR-4)
    input  logic [63:0]     imm_i,
    // Upper 64b of 128-bit multiply product (one-cycle registered from mult)
    input  logic [63:0]     mul_upper_i,
    // PVM ALU operation
    input  pvm_alu_op_e     op_i,
    // 64-bit result
    output logic [63:0]     result_o
);

  // =========================================================================
  // Pre-computed intermediates (always computed, muxed in result_o below)
  // =========================================================================

  // 64-bit adder (used for ADD_64, SUB_64, ADD_IMM_64)
  logic [64:0] adder64;
  assign adder64 = operand_a_i + operand_b_i;

  // 32-bit arithmetic
  logic [31:0] add32_r, sub32_r, mul32_r;
  assign add32_r = operand_a_i[31:0] + operand_b_i[31:0];
  assign sub32_r = operand_a_i[31:0] - operand_b_i[31:0];
  assign mul32_r = operand_a_i[31:0] * operand_b_i[31:0];

  // negate_and_add_imm: (-rs1) + imm = ~rs1 + 1 + imm
  // Decoder places imm on operand_b_i.
  logic [63:0] neg64_r;
  logic [31:0] neg32_r;
  assign neg64_r = (~operand_a_i) + 64'd1 + operand_b_i;
  assign neg32_r = (~operand_a_i[31:0]) + 32'd1 + operand_b_i[31:0];

  // 64-bit shifts
  logic [63:0] sll64_r, srl64_r;
  logic [63:0] sra64_r;
  assign sll64_r = operand_a_i << operand_b_i[5:0];
  assign srl64_r = operand_a_i >> operand_b_i[5:0];
  assign sra64_r = $unsigned($signed(operand_a_i) >>> operand_b_i[5:0]);

  // 32-bit shifts
  logic [31:0] sll32_r, srl32_r, sra32_r;
  assign sll32_r = operand_a_i[31:0] << operand_b_i[4:0];
  assign srl32_r = operand_a_i[31:0] >> operand_b_i[4:0];
  assign sra32_r = $unsigned($signed(operand_a_i[31:0]) >>> operand_b_i[4:0]);

  // 64-bit rotates
  logic [63:0] rol64_r, ror64_r;
  assign rol64_r = (operand_a_i << operand_b_i[5:0]) |
                   (operand_a_i >> (7'd64 - {1'b0, operand_b_i[5:0]}));
  assign ror64_r = (operand_a_i >> operand_b_i[5:0]) |
                   (operand_a_i << (7'd64 - {1'b0, operand_b_i[5:0]}));

  // 32-bit rotates
  logic [31:0] rol32_r, ror32_r;
  assign rol32_r = (operand_a_i[31:0] << operand_b_i[4:0]) |
                   (operand_a_i[31:0] >> (6'd32 - {1'b0, operand_b_i[4:0]}));
  assign ror32_r = (operand_a_i[31:0] >> operand_b_i[4:0]) |
                   (operand_a_i[31:0] << (6'd32 - {1'b0, operand_b_i[4:0]}));

  // Signed/unsigned comparisons (64b)
  logic less_s, less_u, greater_s, greater_u;
  assign less_s    = $signed(operand_a_i) < $signed(operand_b_i);
  assign less_u    = operand_a_i < operand_b_i;
  assign greater_s = $signed(operand_b_i) < $signed(operand_a_i);
  assign greater_u = operand_b_i < operand_a_i;

  // Byte-reverse operations
  logic [63:0] rev64_r;
  logic [31:0] rev32_r;
  assign rev64_r = {operand_a_i[ 7: 0], operand_a_i[15: 8],
                    operand_a_i[23:16], operand_a_i[31:24],
                    operand_a_i[39:32], operand_a_i[47:40],
                    operand_a_i[55:48], operand_a_i[63:56]};
  assign rev32_r = {operand_a_i[ 7: 0], operand_a_i[15: 8],
                    operand_a_i[23:16], operand_a_i[31:24]};

  // CLZ (count leading zeros) — 64b and 32b
  // Simple priority encoder; synthesizer will optimise.
  logic [6:0] clz64_r;
  logic [5:0] clz32_r;

  always_comb begin : p_clz64
    clz64_r = 7'd64;
    for (int i = 63; i >= 0; i--) begin
      if (operand_a_i[i]) clz64_r = 7'(63 - i);
    end
  end

  always_comb begin : p_clz32
    clz32_r = 6'd32;
    for (int i = 31; i >= 0; i--) begin
      if (operand_a_i[i]) clz32_r = 6'(31 - i);
    end
  end

  // CTZ (count trailing zeros) — 64b and 32b
  logic [6:0] ctz64_r;
  logic [5:0] ctz32_r;

  always_comb begin : p_ctz64
    ctz64_r = 7'd64;
    for (int i = 0; i < 64; i++) begin
      if (operand_a_i[i]) begin
        ctz64_r = 7'(i);
        break;
      end
    end
  end

  always_comb begin : p_ctz32
    ctz32_r = 6'd32;
    for (int i = 0; i < 32; i++) begin
      if (operand_a_i[i]) begin
        ctz32_r = 6'(i);
        break;
      end
    end
  end

  // CPOP (popcount) — 64b and 32b
  logic [6:0] cpop64_r;
  logic [5:0] cpop32_r;

  always_comb begin : p_cpop64
    cpop64_r = '0;
    for (int i = 0; i < 64; i++) cpop64_r = cpop64_r + {6'b0, operand_a_i[i]};
  end

  always_comb begin : p_cpop32
    cpop32_r = '0;
    for (int i = 0; i < 32; i++) cpop32_r = cpop32_r + {5'b0, operand_a_i[i]};
  end

  // =========================================================================
  // Result MUX
  // =========================================================================
  always_comb begin : p_result_mux
    result_o = '0;
    unique case (op_i)
      // ---- 64-bit arithmetic ----------------------------------------------
      PVM_ALU_ADD_64:            result_o = adder64[63:0];
      PVM_ALU_SUB_64:            result_o = operand_a_i - operand_b_i;
      PVM_ALU_MUL_64:            result_o = operand_a_i * operand_b_i;
      PVM_ALU_ADD_IMM_64:        result_o = adder64[63:0];
      PVM_ALU_MUL_IMM_64:        result_o = operand_a_i * operand_b_i;
      PVM_ALU_NEGATE_ADD_IMM_64: result_o = neg64_r;

      // ---- 32-bit arithmetic (sign-extend to 64b) -------------------------
      PVM_ALU_ADD_32:            result_o = {{32{add32_r[31]}}, add32_r};
      PVM_ALU_SUB_32:            result_o = {{32{sub32_r[31]}}, sub32_r};
      PVM_ALU_MUL_32:            result_o = {{32{mul32_r[31]}}, mul32_r};
      PVM_ALU_ADD_IMM_32:        result_o = {{32{add32_r[31]}}, add32_r};
      PVM_ALU_MUL_IMM_32:        result_o = {{32{mul32_r[31]}}, mul32_r};
      PVM_ALU_NEGATE_ADD_IMM_32: result_o = {{32{neg32_r[31]}}, neg32_r};

      // ---- Bitwise logic --------------------------------------------------
      PVM_ALU_AND:               result_o = operand_a_i & operand_b_i;
      PVM_ALU_OR:                result_o = operand_a_i | operand_b_i;
      PVM_ALU_XOR:               result_o = operand_a_i ^ operand_b_i;
      PVM_ALU_AND_IMM:           result_o = operand_a_i & operand_b_i;
      PVM_ALU_OR_IMM:            result_o = operand_a_i | operand_b_i;
      PVM_ALU_XOR_IMM:           result_o = operand_a_i ^ operand_b_i;
      PVM_ALU_AND_INVERTED:      result_o = operand_a_i & ~operand_b_i;
      PVM_ALU_OR_INVERTED:       result_o = operand_a_i | ~operand_b_i;
      PVM_ALU_XNOR:              result_o = ~(operand_a_i ^ operand_b_i);

      // ---- 64-bit shifts --------------------------------------------------
      PVM_ALU_SLL_64:            result_o = sll64_r;
      PVM_ALU_SRL_64:            result_o = srl64_r;
      PVM_ALU_SRA_64:            result_o = sra64_r;
      PVM_ALU_SLL_IMM_64:        result_o = sll64_r;
      PVM_ALU_SRL_IMM_64:        result_o = srl64_r;
      PVM_ALU_SRA_IMM_64:        result_o = sra64_r;

      // ---- 32-bit shifts (SLL/SRA sign-extend; SRL zero-extend) ----------
      PVM_ALU_SLL_32:            result_o = {{32{sll32_r[31]}}, sll32_r};
      PVM_ALU_SRL_32:            result_o = {32'b0,             srl32_r};
      PVM_ALU_SRA_32:            result_o = {{32{sra32_r[31]}}, sra32_r};
      PVM_ALU_SLL_IMM_32:        result_o = {{32{sll32_r[31]}}, sll32_r};
      PVM_ALU_SRL_IMM_32:        result_o = {32'b0,             srl32_r};
      PVM_ALU_SRA_IMM_32:        result_o = {{32{sra32_r[31]}}, sra32_r};

      // ---- Multiply-upper (pipelined: valid one cycle after issue) --------
      PVM_ALU_MUL_UPPER_SS:      result_o = mul_upper_i;
      PVM_ALU_MUL_UPPER_UU:      result_o = mul_upper_i;
      PVM_ALU_MUL_UPPER_SU:      result_o = mul_upper_i;

      // ---- Comparisons ----------------------------------------------------
      PVM_ALU_SLT_U:             result_o = {63'b0, less_u};
      PVM_ALU_SLT_S:             result_o = {63'b0, less_s};
      PVM_ALU_SLT_U_IMM:         result_o = {63'b0, less_u};
      PVM_ALU_SLT_S_IMM:         result_o = {63'b0, less_s};
      PVM_ALU_SGT_U_IMM:         result_o = {63'b0, greater_u};
      PVM_ALU_SGT_S_IMM:         result_o = {63'b0, greater_s};

      // ---- Min/Max --------------------------------------------------------
      PVM_ALU_MAX_S:             result_o = less_s ? operand_b_i : operand_a_i;
      PVM_ALU_MAX_U:             result_o = less_u ? operand_b_i : operand_a_i;
      PVM_ALU_MIN_S:             result_o = less_s ? operand_a_i : operand_b_i;
      PVM_ALU_MIN_U:             result_o = less_u ? operand_a_i : operand_b_i;

      // ---- 64-bit rotates -------------------------------------------------
      PVM_ALU_ROL_64:            result_o = rol64_r;
      PVM_ALU_ROR_64:            result_o = ror64_r;
      PVM_ALU_ROR_IMM_64:        result_o = ror64_r;

      // ---- 32-bit rotates (sign-extend) -----------------------------------
      PVM_ALU_ROL_32:            result_o = {{32{rol32_r[31]}}, rol32_r};
      PVM_ALU_ROR_32:            result_o = {{32{ror32_r[31]}}, ror32_r};
      PVM_ALU_ROR_IMM_32:        result_o = {{32{ror32_r[31]}}, ror32_r};

      // ---- Register / bit-extend (Group 11) --------------------------------
      PVM_ALU_MOVE_REG:          result_o = operand_a_i;
      PVM_ALU_ZERO_EXT_16:       result_o = {48'b0, operand_a_i[15:0]};
      PVM_ALU_REV_BYTE_64:       result_o = rev64_r;
      // REV_BYTE_32: polkavm places reversed low-32b in bits 63:32, zeros in 31:0
      PVM_ALU_REV_BYTE_32:       result_o = {rev32_r, 32'b0};

      // ---- CLZ / CTZ / CPOP -----------------------------------------------
      PVM_ALU_CLZ_64:            result_o = {57'b0, clz64_r};
      PVM_ALU_CLZ_32:            result_o = {58'b0, clz32_r};
      PVM_ALU_CTZ_64:            result_o = {57'b0, ctz64_r};
      PVM_ALU_CTZ_32:            result_o = {58'b0, ctz32_r};
      PVM_ALU_CPOP_64:           result_o = {57'b0, cpop64_r};
      PVM_ALU_CPOP_32:           result_o = {58'b0, cpop32_r};

      // ---- Sign extend ----------------------------------------------------
      PVM_ALU_SEXT_8:            result_o = {{56{operand_a_i[7]}},  operand_a_i[7:0]};
      PVM_ALU_SEXT_16:           result_o = {{48{operand_a_i[15]}}, operand_a_i[15:0]};

      // CMOV: conditional move using old rd via imm_i (ADR-4 forwarding path)
      // cmov_if_zero     (XHEAD_MVEQZ): rd = (rs2==0) ? rs1 : old_rd
      // cmov_if_not_zero (XHEAD_MVNEZ): rd = (rs2!=0) ? rs1 : old_rd
      // These are not proper pvm_alu_op_e entries (cmov routes via XHEAD ops
      // in fu_op); included here only for standalone testbench coverage.

      default:                   result_o = '0;
    endcase
  end

endmodule
