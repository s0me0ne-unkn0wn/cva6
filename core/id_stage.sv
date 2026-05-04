// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 15.04.2017
// Description: Instruction decode, contains the logic for decode,
//              issue and read operands.

module id_stage #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type branchpredict_sbe_t = logic,
    parameter type dcache_req_i_t = logic,
    parameter type dcache_req_o_t = logic,
    parameter type exception_t = logic,
    parameter type fetch_entry_t = logic,
    parameter type jvt_t = logic,
    parameter type irq_ctrl_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type interrupts_t = logic,
    parameter interrupts_t INTERRUPTS = '0,
    parameter type x_compressed_req_t = logic,
    parameter type x_compressed_resp_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Fetch flush request - CONTROLLER
    input logic flush_i,
    // Debug (async) request - SUBSYSTEM
    input logic debug_req_i,
    // Handshake's data between fetch and decode - FRONTEND
    input fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_i,
    // Handshake's valid between fetch and decode - FRONTEND
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_i,
    // Handshake's ready between fetch and decode - FRONTEND
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_o,
    // Handshake's data between decode and issue - ISSUE
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_entry_o,
    output scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_entry_o_prev,
    // Instruction value - ISSUE
    output logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_o,
    // Handshake's valid between decode and issue - ISSUE
    output logic [CVA6Cfg.NrIssuePorts-1:0] issue_entry_valid_o,
    // Report if instruction is a control flow instruction - ISSUE
    output logic [CVA6Cfg.NrIssuePorts-1:0] is_ctrl_flow_o,
    // Handshake's acknowledge between decode and issue - ISSUE
    input logic [CVA6Cfg.NrIssuePorts-1:0] issue_instr_ack_i,
    // Information dedicated to RVFI - RVFI
    output logic [CVA6Cfg.NrIssuePorts-1:0] rvfi_is_compressed_o,
    // Current privilege level - CSR_REGFILE
    input riscv::priv_lvl_t priv_lvl_i,
    // Current virtualization mode - CSR_REGFILE
    input logic v_i,
    // Floating point extension status - CSR_REGFILE
    input riscv::xs_t fs_i,
    // Floating point extension virtual status - CSR_REGFILE
    input riscv::xs_t vfs_i,
    // Floating point dynamic rounding mode - CSR_REGFILE
    input logic [2:0] frm_i,
    // Vector extension status - CSR_REGFILE
    input riscv::xs_t vs_i,
    // Level sensitive (async) interrupts - SUBSYSTEM
    input logic [1:0] irq_i,
    // Interrupt control status - CSR_REGFILE
    input irq_ctrl_t irq_ctrl_i,
    // Is current mode debug ? - CSR_REGFILE
    input logic debug_mode_i,
    // Trap virtual memory - CSR_REGFILE
    input logic tvm_i,
    // Timeout wait - CSR_REGFILE
    input logic tw_i,
    // Virtual timeout wait - CSR_REGFILE
    input logic vtw_i,
    // Trap sret - CSR_REGFILE
    input logic tsr_i,
    // Hypervisor user mode - CSR_REGFILE
    input logic hu_i,
    // machine-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t mcbie_i,
    // supervisor-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t scbie_i,
    // hypervisor-mode cache block invalidate enable - CSR_REGFILE
    input riscv::cbie_t hcbie_i,
    // machine-mode clean/flush cache block invalidate enable - CSR_REGFILE
    input logic mcbcfe_i,
    // supervisor-mode clean/flush cache block invalidate enable - CSR_REGFILE
    input logic scbcfe_i,
    // hypervisor-mode clean/flush cache block invalidate enable - CSR_REGFILE
    input logic hcbcfe_i,
    // CVXIF Compressed interface
    input logic [CVA6Cfg.XLEN-1:0] hart_id_i,
    input logic compressed_ready_i,
    //JVT
    input jvt_t jvt_i,
    input x_compressed_resp_t compressed_resp_i,
    output logic compressed_valid_o,
    output x_compressed_req_t compressed_req_o,
    // breakpoint request from trigger module
    input debug_from_trigger_i,
    // Data cache request ouput - CACHE
    input dcache_req_o_t dcache_req_ports_i,
    // Data cache request input - CACHE
    output dcache_req_i_t dcache_req_ports_o,
    // PVM fetch chunks from top-level pvm_frontend (sub-phase 3) - FRONTEND
    input polkavm_pkg::pvm_fetch_chunk_t [CVA6Cfg.NrIssuePorts-1:0] pvm_fc_if_id_i,
    // PVM PC from top-level pvm_frontend (sub-phase 3) - FRONTEND
    input logic [CVA6Cfg.VLEN-1:0] pvm_fe_pc_i
);
  // ID/ISSUE register stage
  typedef struct packed {
    logic              valid;
    scoreboard_entry_t sbe;
    logic [31:0]       orig_instr;
    logic              is_ctrl_flow;
  } issue_struct_t;
  issue_struct_t [CVA6Cfg.NrIssuePorts-1:0] issue_n, issue_q;
  // stall required for ZCMP ZCMT CVXIF
  logic              [CVA6Cfg.NrIssuePorts-1:0]       stall_instr_fetch;

  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_control_flow_instr;
  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]       decoded_instruction;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       decoded_instruction_valid;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr;

  // Compressed decoder signals
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_illegal_rvc;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] instruction_rvc;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_compressed_rvc;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_zcmt_instr;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_macro_instr;

  // CVXIF compressed interface driver signals
  // Inputs
  logic                                               is_illegal_cvxif_i;
  logic              [                    31:0]       instruction_cvxif_i;
  logic                                               is_compressed_cvxif_i;
  logic                                               stall_macro_deco;
  // Outputs
  logic                                               is_illegal_cvxif_o;
  logic              [                    31:0]       instruction_cvxif_o;
  logic                                               is_compressed_cvxif_o;

  // ZCMP decoder signals
  logic                                               is_illegal_zcmp;
  logic              [                    31:0]       instruction_zcmp;
  logic                                               is_compressed_zcmp;
  logic                                               stall_macro_deco_zcmp;
  logic                                               is_last_macro_instr;
  logic                                               is_double_rd_macro_instr;

  // ZCMT decoder signals
  logic                                               is_illegal_zcmt;
  logic              [                    31:0]       instruction_zcmt;
  logic                                               is_compressed_zcmt;
  logic                                               stall_macro_deco_zcmt;
  logic              [        CVA6Cfg.XLEN-1:0]       jump_address;

  // Decoder signals
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_illegal_deco;
  logic              [CVA6Cfg.NrIssuePorts-1:0][31:0] instruction_deco;
  logic              [CVA6Cfg.NrIssuePorts-1:0]       is_compressed_deco;


  // RVC permanently disabled in PVM-native build (sub-phase 9 deleted compressed_decoder.sv).
  // Drive RVC-related signals to inert defaults so downstream consumers see no compressed input.
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : g_no_rvc
    assign is_illegal_rvc[i]    = 1'b0;
    assign instruction_rvc[i]   = fetch_entry_i[i].instruction;
    assign is_compressed_rvc[i] = 1'b0;
    assign stall_instr_fetch[i] = 1'b0;
  end

  // ---------------------------------------------------------
  // 2. Decode and emit instruction to issue stage
  // ---------------------------------------------------------

  always_comb begin
    // Connect directly compressed decoder to decoder
    is_illegal_deco    = is_illegal_rvc;
    instruction_deco   = instruction_rvc;
    is_compressed_deco = is_compressed_rvc;
  end

  assign rvfi_is_compressed_o = is_compressed_rvc;

  // PVM JAM v1 decoder active (CVA6ConfigUsePvmIsa=1).
  // Legacy decoder.sv and compressed_decoder.sv deleted.
  // Sub-phase 4: pvm_frontend provides the 128-bit instruction chunk,
  // skip value (instruction_length - 1), and is_valid_opcode per ADR-10.
  // ROM ports are tied to 0 here; real bootrom wiring is sub-phase 10.
  // Branch redirect from execute is sub-phase 6+.

  // Sub-phase 3: pvm_frontend, bootrom_code_64, bootrom_bitmask_64 moved to
  // cva6.sv top level (ADR-O4 sub-option A.a). Chunk/pc arrive via ports.

  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : g_pvm_dec_port
    import polkavm_pkg::*;
    import ariane_pkg::fu_t;
    import ariane_pkg::fu_op;

    pvm_op_t      pvm_op_w;
    logic [3:0]   pvm_rs1_w, pvm_rs2_w, pvm_rd_w;
    logic         pvm_has_rd_w, pvm_has_rs1_w, pvm_has_rs2_w;
    logic [63:0]  pvm_imm_w, pvm_imm2_w;
    logic         pvm_illegal_op_w, pvm_illegal_reg_w;
    logic         pvm_is_ecalli_w;
    logic         pvm_is_ecalli_mode_ret_w, pvm_is_ecalli_read_csr_w;
    logic [4:0]   pvm_instr_len_w;
    logic         pvm_is_bb_term_w;

    pvm_decoder i_pvm_decoder (
      .clk_i                            (clk_i),
      .rst_ni                           (rst_ni),
      // Sub-phase 3: chunk/skip/is_valid_opcode arrive via top-level ports.
      // (Port i=0 gets the live frontend output; superscalar port i=1
      //  is unused in PVM mode — NrIssuePorts=1 for RVE PVM config.)
      .chunk_i                          (pvm_fc_if_id_i[i].chunk),
      .skip_i                           ({1'b0, pvm_fc_if_id_i[i].skip}),
      .is_valid_opcode_i                (pvm_fc_if_id_i[i].is_valid_opcode),
      .is_s_mode_i                      (1'b0),
      .pvm_op_o                         (pvm_op_w),
      .rs1_o                            (pvm_rs1_w),
      .rs2_o                            (pvm_rs2_w),
      .rd_o                             (pvm_rd_w),
      .imm_o                            (pvm_imm_w),
      .imm2_o                           (pvm_imm2_w),
      .is_illegal_op_o                  (pvm_illegal_op_w),
      .is_illegal_reg_o                 (pvm_illegal_reg_w),
      .is_ecalli_o                      (pvm_is_ecalli_w),
      .is_ecalli_sentinel_mode_return_o (pvm_is_ecalli_mode_ret_w),
      .is_ecalli_sentinel_read_csr_o    (pvm_is_ecalli_read_csr_w),
      .instruction_length_o             (pvm_instr_len_w),
      .has_rd_o                         (pvm_has_rd_w),
      .has_rs1_o                        (pvm_has_rs1_w),
      .has_rs2_o                        (pvm_has_rs2_w),
      .is_basic_block_term_o            (pvm_is_bb_term_w)
    );

    // Sub-phase 2: bridge pvm_decoder outputs → scoreboard_entry_t.
    // Function pvm_op_to_fu_t_op() maps pvm_op_t to FU/op/pvm_alu_op.
    pvm_decode_result_t pvm_dec_r;
    always_comb begin : g_pvm_bridge
      pvm_dec_r = pvm_op_to_fu_t_op(pvm_op_w);

      decoded_instruction[i]          = '0;
      decoded_instruction[i].fu       = fu_t'(pvm_dec_r.fu);
      decoded_instruction[i].op       = fu_op'(pvm_dec_r.op);
      decoded_instruction[i].pvm_alu_op = pvm_dec_r.pvm_alu_op;
      decoded_instruction[i].is_pvm_op  = pvm_dec_r.is_pvm_op;
      // PVM r0-r12 map to CVA6 x1-x13 (+1 offset) because CVA6 x0 is
      // hardwired zero and PVM r0 is a general-purpose register.
      // rs1/rs2/rd each get +1 only when the corresponding has_* flag is set;
      // otherwise they map to x0 so the issue stage reads 0 / suppresses writeback.
      // (Without this guard, default dec_rs1=0 → x1 instead of x0, causing
      //  instructions like LOAD_IMM64 to read x1 as their source register.)
      decoded_instruction[i].rs1      = pvm_has_rs1_w ? ({1'b0, pvm_rs1_w} + 5'd1) : 5'd0;
      decoded_instruction[i].rs2      = pvm_has_rs2_w ? ({1'b0, pvm_rs2_w} + 5'd1) : 5'd0;
      decoded_instruction[i].rd       = pvm_has_rd_w  ? ({1'b0, pvm_rd_w}  + 5'd1) : 5'd0;
      // Immediate stored in result field (dual-purpose per cva6.sv:106).
      // For store_imm_indirect_*: pack {imm2[31:0], imm1[31:0]} into result so
      // issue_read_operands can extract address-offset (lower 32b) and store-data
      // (upper 32b) separately.  rs2 is forced to x0 to avoid RAW stalls on the
      // garbage b1[7:4] nibble that the decoder produces for this instruction group.
      if (pvm_op_w == PVM_OP_STORE_IMM_INDIRECT_U8  ||
          pvm_op_w == PVM_OP_STORE_IMM_INDIRECT_U16 ||
          pvm_op_w == PVM_OP_STORE_IMM_INDIRECT_U32 ||
          pvm_op_w == PVM_OP_STORE_IMM_INDIRECT_U64) begin
        decoded_instruction[i].result  = {pvm_imm2_w[31:0], pvm_imm_w[31:0]};
        decoded_instruction[i].rs2     = 5'd0;
        decoded_instruction[i].use_imm = 1'b1;
        decoded_instruction[i].is_pvm_op = 1'b1;
      end else if (pvm_op_w == PVM_OP_BRANCH_EQ_IMM                    ||
                   pvm_op_w == PVM_OP_BRANCH_NOT_EQ_IMM                 ||
                   pvm_op_w == PVM_OP_BRANCH_LESS_UNSIGNED_IMM          ||
                   pvm_op_w == PVM_OP_BRANCH_LESS_OR_EQUAL_UNSIGNED_IMM ||
                   pvm_op_w == PVM_OP_BRANCH_GREATER_OR_EQUAL_UNSIGNED_IMM ||
                   pvm_op_w == PVM_OP_BRANCH_GREATER_UNSIGNED_IMM       ||
                   pvm_op_w == PVM_OP_BRANCH_LESS_SIGNED_IMM            ||
                   pvm_op_w == PVM_OP_BRANCH_LESS_OR_EQUAL_SIGNED_IMM   ||
                   pvm_op_w == PVM_OP_BRANCH_GREATER_OR_EQUAL_SIGNED_IMM ||
                   pvm_op_w == PVM_OP_BRANCH_GREATER_SIGNED_IMM) begin
        // Pack: result[31:0]  = imm2 (branch offset to add to PC),
        //       result[63:32] = imm1 (comparand, sign-extended in issue stage).
        // issue_read_operands will unpack for CTRL_FLOW pvm ops.
        decoded_instruction[i].result        = {pvm_imm_w[31:0], pvm_imm2_w[31:0]};
        decoded_instruction[i].use_imm       = 1'b1;
        decoded_instruction[i].is_pvm_op     = 1'b1;
        decoded_instruction[i].swap_operands = pvm_dec_r.swap_operands;
      end else begin
        decoded_instruction[i].result  = pvm_imm_w;
        decoded_instruction[i].use_imm = pvm_dec_r.use_imm;
      end
      // sbe.valid means "execution complete, ready to commit" — must be 0 at decode
      // time so the scoreboard waits for the FU writeback (wt_valid_i) before
      // committing.  Set to 1 only for illegal instructions so they can retire
      // and raise their exception immediately.  This matches the standard CVA6
      // decoder: `assign instruction_o.valid = instruction_o.ex.valid;`
      decoded_instruction[i].valid    = pvm_dec_r.is_illegal | pvm_illegal_op_w | pvm_illegal_reg_w;
      decoded_instruction[i].pc       = pvm_fe_pc_i;
      // Exception: illegal op, illegal reg, or function says illegal.
      decoded_instruction[i].ex.valid = pvm_illegal_op_w
                                      | pvm_illegal_reg_w
                                      | pvm_dec_r.is_illegal;
      decoded_instruction[i].ex.cause = riscv::ILLEGAL_INSTR;
      // tval: lower 32 bits of the raw fetch chunk, zero-extended.
      decoded_instruction[i].ex.tval  = {{(CVA6Cfg.XLEN-32){1'b0}},
                                          pvm_fc_if_id_i[i].chunk[31:0]};
      decoded_instruction[i].bp       = '0;
    end

    assign orig_instr[i]            = pvm_fc_if_id_i[i].chunk[31:0];
    assign is_control_flow_instr[i] = pvm_is_bb_term_w;
  end

  // ------------------
  // 3. Pipeline Register
  // ------------------
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin
    assign issue_entry_o[i] = issue_q[i].sbe;
    assign issue_entry_o_prev[i] = CVA6Cfg.FpgaAlteraEn ? issue_n[i].sbe : '0;
    assign issue_entry_valid_o[i] = issue_q[i].valid;
    assign is_ctrl_flow_o[i] = issue_q[i].is_ctrl_flow;
    assign orig_instr_o[i] = issue_q[i].orig_instr;
  end

  if (CVA6Cfg.SuperscalarEn) begin
    always_comb begin
      issue_n = issue_q;
      fetch_entry_ready_o = '0;
      decoded_instruction_valid[0] = 1'b1;
      // Instruction on port 1 are always valid. It is either 32bits or legal 16bits.
      decoded_instruction_valid[1] = ~stall_instr_fetch[1];

      // Clear the valid flag if issue has acknowledged the instruction
      if (issue_instr_ack_i[0]) begin
        issue_n[0].valid = 1'b0;
      end
      if (issue_instr_ack_i[1]) begin
        issue_n[1].valid = 1'b0;
      end

      if (!issue_n[0].valid) begin
        if (issue_n[1].valid) begin
          issue_n[0] = issue_n[1];
          issue_n[1].valid = 1'b0;
        end else if (fetch_entry_valid_i[0]) begin
          fetch_entry_ready_o[0] = ~stall_instr_fetch[0];
          issue_n[0] = '{
              decoded_instruction_valid[0],
              decoded_instruction[0],
              orig_instr[0],
              is_control_flow_instr[0]
          };
        end
      end

      if (!issue_n[1].valid) begin
        if (fetch_entry_ready_o[0]) begin
          if (fetch_entry_valid_i[1]) begin
            fetch_entry_ready_o[1] = ~stall_instr_fetch[1];
            issue_n[1] = '{
                decoded_instruction_valid[1],
                decoded_instruction[1],
                orig_instr[1],
                is_control_flow_instr[1]
            };
          end
        end else if (fetch_entry_valid_i[0]) begin
          fetch_entry_ready_o[0] = ~stall_instr_fetch[0];
          issue_n[1] = '{
              decoded_instruction_valid[0],
              decoded_instruction[0],
              orig_instr[0],
              is_control_flow_instr[0]
          };
        end
      end

      if (flush_i) begin
        issue_n[0].valid = 1'b0;
        issue_n[1].valid = 1'b0;
      end
    end
  end else begin
    always_comb begin
      issue_n = issue_q;
      fetch_entry_ready_o = '0;
      decoded_instruction_valid[0] = 1'b1;
      // Clear the valid flag if issue has acknowledged the instruction
      if (issue_instr_ack_i[0]) issue_n[0].valid = 1'b0;

      // TODO: redo
      // if we have a space in the register and the fetch is valid, go get it
      // or the issue stage is currently acknowledging an instruction, which means that we will have space
      // for a new instruction
      if (!issue_n[0].valid && fetch_entry_valid_i[0]) begin
        fetch_entry_ready_o[0] = ~stall_instr_fetch[0];
        issue_n[0] = '{
            decoded_instruction_valid[0],
            decoded_instruction[0],
            orig_instr[0],
            is_control_flow_instr[0]
        };
      end

      // invalidate the pipeline register on a flush
      if (flush_i) issue_n[0].valid = 1'b0;
    end
  end
  // -------------------------
  // Registers (ID <-> Issue)
  // -------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      issue_q <= '0;
    end else begin
      issue_q <= issue_n;
    end
  end

endmodule
