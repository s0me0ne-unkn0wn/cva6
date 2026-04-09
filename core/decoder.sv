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
// File:   issue_read_operands.sv
// Author: Florian Zaruba <zarubaf@ethz.ch>
// Date:   8.4.2017
//
// Copyright (C) 2017 ETH Zurich, University of Bologna
// All rights reserved.
//
// Description: Issues instruction from the scoreboard and fetches the operands
//              This also includes all the forwarding logic
//

module decoder
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type branchpredict_sbe_t = logic,
    parameter type exception_t = logic,
    parameter type irq_ctrl_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type interrupts_t = logic,
    parameter interrupts_t INTERRUPTS = '0
) (
    // Debug (async) request - SUBSYSTEM
    input logic debug_req_i,
    // PC from fetch stage - FRONTEND
    input logic [CVA6Cfg.VLEN-1:0] pc_i,
    // Is a compressed instruction - compressed_decoder
    input logic is_compressed_i,
    // Compressed form of instruction - FRONTEND
    input logic [15:0] compressed_instr_i,
    // Illegal compressed instruction - compressed_decoder
    input logic is_illegal_i,
    // Instruction from fetch stage - FRONTEND
    input logic [31:0] instruction_i,
    // Is a macro instruction - macro_decoder
    input logic is_macro_instr_i,
    // Is a last macro instruction - macro_decoder
    input logic is_last_macro_instr_i,
    // Is mvsa01/mva01s macro instruction - macro_decoder
    input logic is_double_rd_macro_instr_i,
    // Zcmt instruction - FRONTEND
    input logic is_zcmt_i,
    // Jump address - zcmt_decoder
    input logic [CVA6Cfg.XLEN-1:0] jump_address_i,
    // Is a branch predict instruction - FRONTEND
    input branchpredict_sbe_t branch_predict_i,
    // If an exception occurred in fetch stage - FRONTEND
    input exception_t ex_i,
    // Level sensitive (async) interrupts - SUBSYSTEM
    input logic [1:0] irq_i,
    // Interrupt control status - CSR_REGFILE
    input irq_ctrl_t irq_ctrl_i,
    // Current privilege level - CSR_REGFILE
    input riscv::priv_lvl_t priv_lvl_i,
    // Current virtualization mode - CSR_REGFILE
    input logic v_i,
    // Is debug mode - CSR_REGFILE
    input logic debug_mode_i,
    // Floating point extension status - CSR_REGFILE
    input riscv::xs_t fs_i,
    // Virtual floating point extension status - CSR_REGFILE
    input riscv::xs_t vfs_i,
    // Floating-point dynamic rounding mode - CSR_REGFILE
    input logic [2:0] frm_i,
    // Vector extension status - CSR_REGFILE
    input riscv::xs_t vs_i,
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
    // Instruction to be added to scoreboard entry - ISSUE_STAGE
    output scoreboard_entry_t instruction_o,
    // Instruction - ISSUE_STAGE
    output logic [31:0] orig_instr_o,
    // Is a control flow instruction - ISSUE_STAGE
    output logic is_control_flow_instr_o,
    input debug_from_trigger_i
);
  logic illegal_instr;
  logic illegal_instr_bm;
  logic illegal_instr_zic;
  logic illegal_instr_non_bm;
  logic virtual_illegal_instr;
  // this instruction is an environment call (ecall), it is handled like an exception
  logic ecall;
  // this instruction is a software break-point
  logic ebreak;
  // this instruction needs floating-point rounding-mode verification
  logic check_fprm;
  riscv::instruction_t instr;
  assign instr = riscv::instruction_t'(instruction_i);
  // transformed instruction
  logic [31:0] tinst;
  // --------------------
  // Immediate select
  // --------------------
  enum logic [3:0] {
    NOIMM,
    IIMM,
    SIMM,
    SBIMM,
    UIMM,
    JIMM,
    RS3,
    MUX_RD_RS3
  } imm_select;

  logic [CVA6Cfg.XLEN-1:0] imm_i_type;
  logic [CVA6Cfg.XLEN-1:0] imm_s_type;
  logic [CVA6Cfg.XLEN-1:0] imm_sb_type;
  logic [CVA6Cfg.XLEN-1:0] imm_u_type;
  logic [CVA6Cfg.XLEN-1:0] imm_uj_type;

  // ---------------------------------------
  // Accelerator instructions' first-pass decoder
  // ---------------------------------------
  logic is_accel;
  scoreboard_entry_t acc_instruction;
  logic acc_illegal_instr;
  logic acc_is_control_flow_instr;

  assign is_accel                  = 1'b0;
  assign acc_instruction           = '0;
  assign acc_illegal_instr         = 1'b1;  // this should never propagate
  assign acc_is_control_flow_instr = 1'b0;

  always_comb begin : decoder

    imm_select                             = NOIMM;
    is_control_flow_instr_o                = 1'b0;
    illegal_instr                          = 1'b0;
    illegal_instr_non_bm                   = 1'b0;
    illegal_instr_bm                       = 1'b0;
    illegal_instr_zic                      = 1'b0;
    virtual_illegal_instr                  = 1'b0;
    instruction_o.pc                       = pc_i;
    instruction_o.trans_id                 = '0;
    instruction_o.fu                       = NONE;
    instruction_o.op                       = ariane_pkg::ADD;
    instruction_o.rs1                      = '0;
    instruction_o.rs2                      = '0;
    instruction_o.rd                       = '0;
    instruction_o.use_pc                   = 1'b0;
    instruction_o.is_compressed            = is_compressed_i;
    instruction_o.is_macro_instr           = is_macro_instr_i;
    instruction_o.is_last_macro_instr      = is_last_macro_instr_i;
    instruction_o.is_double_rd_macro_instr = is_double_rd_macro_instr_i;
    instruction_o.use_zimm                 = 1'b0;
    instruction_o.bp                       = branch_predict_i;
    instruction_o.vfp                      = 1'b0;
    instruction_o.is_zcmt                  = is_zcmt_i;
    ecall                                  = 1'b0;
    ebreak                                 = 1'b0;
    check_fprm                             = 1'b0;
    tinst                                  = 32'h0;

    if (~ex_i.valid) begin
      case (instr.rtype.opcode)
        riscv::OpcodeSystem: begin
          instruction_o.fu = CSR;
          instruction_o.rs1 = instr.itype.rs1;
          instruction_o.rs2 = instr.rtype.rs2;   //TODO: needs to be checked if better way is available
          instruction_o.rd = instr.itype.rd;

          unique case (instr.itype.funct3)
            3'b000: begin
              // check if the RD and and RS1 fields are zero, this may be reset for the SFENCE.VMA instruction
              if (instr.itype.rs1 != '0 || instr.itype.rd != '0) begin
                illegal_instr = 1'b1;
              end
              // decode the immediate field
              case (instr.itype.imm)
                // ECALL -> inject exception
                12'b0: ecall = 1'b1;
                // EBREAK -> inject exception
                12'b1: ebreak = 1'b1;
                // SRET
                12'b1_0000_0010: begin
                  if (CVA6Cfg.RVS) begin
                    instruction_o.op = ariane_pkg::SRET;
                    // check privilege level, SRET can only be executed in S and M mode
                    // we'll just decode an illegal instruction if we are in the wrong privilege level
                    if (CVA6Cfg.RVU && priv_lvl_i == riscv::PRIV_LVL_U) begin
                      illegal_instr = 1'b1;
                      //  do not change privilege level if this is an illegal instruction
                      instruction_o.op = ariane_pkg::ADD;
                    end
                    // if we are in S-Mode and Trap SRET (tsr) is set -> trap on illegal instruction
                    if (priv_lvl_i == riscv::PRIV_LVL_S && tsr_i) begin
                      illegal_instr = 1'b1;
                      //  do not change privilege level if this is an illegal instruction
                      instruction_o.op = ariane_pkg::ADD;
                    end
                  end else begin
                    illegal_instr = 1'b1;
                    instruction_o.op = ariane_pkg::ADD;
                  end
                end
                // MRET
                12'b11_0000_0010: begin
                  instruction_o.op = ariane_pkg::MRET;
                  // check privilege level, MRET can only be executed in M mode
                  // otherwise we decode an illegal instruction
                  if ((CVA6Cfg.RVS && priv_lvl_i == riscv::PRIV_LVL_S) || (CVA6Cfg.RVU && priv_lvl_i == riscv::PRIV_LVL_U))
                    illegal_instr = 1'b1;
                end
                // DRET
                12'b111_1011_0010: begin
                  instruction_o.op = ariane_pkg::DRET;
                  if (CVA6Cfg.DebugEn) begin
                    // check that we are in debug mode when executing this instruction
                    illegal_instr = (!debug_mode_i) ? 1'b1 : illegal_instr;
                  end else begin
                    illegal_instr = 1'b1;
                  end
                end
                // WFI
                12'b1_0000_0101: begin
                  instruction_o.op = ariane_pkg::WFI;
                  // if timeout wait is set, trap on an illegal instruction in S Mode
                  // (after 0 cycles timeout)
                  if (CVA6Cfg.RVS && priv_lvl_i == riscv::PRIV_LVL_S && tw_i) begin
                    illegal_instr = 1'b1;
                    instruction_o.op = ariane_pkg::ADD;
                  end
                  // we don't support U mode interrupts so WFI is illegal in this context
                  if (CVA6Cfg.RVU && priv_lvl_i == riscv::PRIV_LVL_U) begin
                    illegal_instr = 1'b1;
                    instruction_o.op = ariane_pkg::ADD;
                  end
                end
                // SFENCE.VMA
                default: begin
                  if (instr.instr[31:25] == 7'b1001) begin
                    // check privilege level, SFENCE.VMA can only be executed in M/S mode
                    // only if S mode is supported
                    // otherwise decode an illegal instruction
                    illegal_instr    = (CVA6Cfg.RVS && (priv_lvl_i inside {riscv::PRIV_LVL_M, riscv::PRIV_LVL_S}) && instr.itype.rd == '0) ? 1'b0 : 1'b1;
                    instruction_o.op = ariane_pkg::SFENCE_VMA;
                    // check TVM flag and intercept SFENCE.VMA call if necessary
                    if (CVA6Cfg.RVS && priv_lvl_i == riscv::PRIV_LVL_S && tvm_i) begin
                      illegal_instr = 1'b1;
                    end
                  end else begin
                    illegal_instr = 1'b1;
                  end
                end
              endcase
            end
            3'b100: begin
              illegal_instr = 1'b1;
            end
            // atomically swaps values in the CSR and integer register
            3'b001: begin  // CSRRW
              imm_select = IIMM;
              instruction_o.op = ariane_pkg::CSR_WRITE;
            end
            // atomically set values in the CSR and write back to rd
            3'b010: begin  // CSRRS
              imm_select = IIMM;
              // this is just a read
              if (instr.itype.rs1 == '0) instruction_o.op = ariane_pkg::CSR_READ;
              else instruction_o.op = ariane_pkg::CSR_SET;
            end
            // atomically clear values in the CSR and write back to rd
            3'b011: begin  // CSRRC
              imm_select = IIMM;
              // this is just a read
              if (instr.itype.rs1 == '0) instruction_o.op = ariane_pkg::CSR_READ;
              else instruction_o.op = ariane_pkg::CSR_CLEAR;
            end
            // use zimm and iimm
            3'b101: begin  // CSRRWI
              instruction_o.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              instruction_o.use_zimm = 1'b1;
              instruction_o.op = ariane_pkg::CSR_WRITE;
            end
            3'b110: begin  // CSRRSI
              instruction_o.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              instruction_o.use_zimm = 1'b1;
              // this is just a read
              if (instr.itype.rs1 == 5'b0) instruction_o.op = ariane_pkg::CSR_READ;
              else instruction_o.op = ariane_pkg::CSR_SET;
            end
            3'b111: begin  // CSRRCI
              instruction_o.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              instruction_o.use_zimm = 1'b1;
              // this is just a read
              if (instr.itype.rs1 == '0) instruction_o.op = ariane_pkg::CSR_READ;
              else instruction_o.op = ariane_pkg::CSR_CLEAR;
            end
            default: illegal_instr = 1'b1;
          endcase
        end
        // Memory ordering instructions
        riscv::OpcodeMiscMem: begin
          instruction_o.fu  = CSR;
          instruction_o.rs1 = '0;
          instruction_o.rs2 = '0;
          instruction_o.rd  = '0;

          case (instr.stype.funct3)
            // FENCE
            // Currently implemented as a whole DCache flush boldly ignoring other things
            3'b000: instruction_o.op = ariane_pkg::FENCE;
            // FENCE.I
            3'b001: instruction_o.op = ariane_pkg::FENCE_I;
            // CBO - optional
            3'b010: begin
              illegal_instr = 1'b1;
            end


            default: illegal_instr = 1'b1;
          endcase
        end

        // --------------------------
        // Reg-Reg Operations
        // --------------------------
        riscv::OpcodeOp: begin
          // --------------------------------------------
          // Vectorial Floating-Point Reg-Reg Operations
          // --------------------------------------------
          if (instr.rvftype.funct2 == 2'b10) begin  // Prefix 10 for all Xfvec ops
            illegal_instr = 1'b1;
            // ---------------------------
            // Integer Reg-Reg Operations
            // ---------------------------
          end else begin
            instruction_o.fu = (instr.rtype.funct7 == 7'b000_0001) ? MULT : ALU;
            instruction_o.rs1 = instr.rtype.rs1;
            instruction_o.rs2 = instr.rtype.rs2;
            instruction_o.rd  = instr.rtype.rd;

            unique case ({
              instr.rtype.funct7, instr.rtype.funct3
            })
              {7'b000_0000, 3'b000} : instruction_o.op = ariane_pkg::ADD;  // Add
              {7'b010_0000, 3'b000} : instruction_o.op = ariane_pkg::SUB;  // Sub
              {7'b000_0000, 3'b010} : instruction_o.op = ariane_pkg::SLTS;  // Set Lower Than
              {
                7'b000_0000, 3'b011
              } :
              instruction_o.op = ariane_pkg::SLTU;  // Set Lower Than Unsigned
              {7'b000_0000, 3'b100} : instruction_o.op = ariane_pkg::XORL;  // Xor
              {7'b000_0000, 3'b110} : instruction_o.op = ariane_pkg::ORL;  // Or
              {7'b000_0000, 3'b111} : instruction_o.op = ariane_pkg::ANDL;  // And
              {7'b000_0000, 3'b001} : instruction_o.op = ariane_pkg::SLL;  // Shift Left Logical
              {7'b000_0000, 3'b101} : instruction_o.op = ariane_pkg::SRL;  // Shift Right Logical
              {7'b010_0000, 3'b101} : instruction_o.op = ariane_pkg::SRA;  // Shift Right Arithmetic
              // Multiplications
              {7'b000_0001, 3'b000} : instruction_o.op = ariane_pkg::MUL;
              {7'b000_0001, 3'b001} : instruction_o.op = ariane_pkg::MULH;
              {7'b000_0001, 3'b010} : instruction_o.op = ariane_pkg::MULHSU;
              {7'b000_0001, 3'b011} : instruction_o.op = ariane_pkg::MULHU;
              {7'b000_0001, 3'b100} : instruction_o.op = ariane_pkg::DIV;
              {7'b000_0001, 3'b101} : instruction_o.op = ariane_pkg::DIVU;
              {7'b000_0001, 3'b110} : instruction_o.op = ariane_pkg::REM;
              {7'b000_0001, 3'b111} : instruction_o.op = ariane_pkg::REMU;
              default: begin
                illegal_instr_non_bm = 1'b1;
              end
            endcase
            if (CVA6Cfg.RVB) begin
              unique case ({
                instr.rtype.funct7, instr.rtype.funct3
              })
                //Logical with Negate (Zbb)
                {7'b010_0000, 3'b111} : instruction_o.op = ariane_pkg::ANDN;  // Andn
                {7'b010_0000, 3'b110} : instruction_o.op = ariane_pkg::ORN;  // Orn
                {7'b010_0000, 3'b100} : instruction_o.op = ariane_pkg::XNOR;  // Xnor
                // Integer maximum/minimum (Zbb)
                {7'b000_0101, 3'b110} : instruction_o.op = ariane_pkg::MAX;  // max
                {7'b000_0101, 3'b111} : instruction_o.op = ariane_pkg::MAXU;  // maxu
                {7'b000_0101, 3'b100} : instruction_o.op = ariane_pkg::MIN;  // min
                {7'b000_0101, 3'b101} : instruction_o.op = ariane_pkg::MINU;  // minu
                // Bitwise Rotation (Zbb)
                {7'b011_0000, 3'b001} : instruction_o.op = ariane_pkg::ROL;  // rol
                {7'b011_0000, 3'b101} : instruction_o.op = ariane_pkg::ROR;  // ror
                // Zero Extend Op RV32 encoding (Zbb)
                {
                  7'b000_0100, 3'b100
                } : begin
                  if (!CVA6Cfg.IS_XLEN64 && instr.instr[24:20] == 5'b00000)
                    instruction_o.op = ariane_pkg::ZEXTH;  // Zero Extend Op RV32 encoding
                  else illegal_instr_bm = 1'b1;
                end
                default: begin
                  illegal_instr_bm = 1'b1;
                end
              endcase
            end
            //VCS coverage on
            if (CVA6Cfg.RVB) begin
              illegal_instr = illegal_instr_non_bm & illegal_instr_bm;
            end else begin
              illegal_instr = illegal_instr_non_bm;
            end
          end
        end

        // --------------------------
        // Xtheadcondmov (CUSTOM-0)
        // --------------------------
        riscv::OpcodeCustom0: begin
          if (CVA6Cfg.XtheadCondMov) begin
            instruction_o.fu  = ALU;
            instruction_o.rs1 = instr.rtype.rs1;
            instruction_o.rs2 = instr.rtype.rs2;
            instruction_o.rd  = instr.rtype.rd;
            imm_select        = MUX_RD_RS3;  // old rd value as 3rd operand
            unique case ({instr.rtype.funct7, instr.rtype.funct3})
              {7'b010_0000, 3'b001}: instruction_o.op = ariane_pkg::XHEAD_MVEQZ;  // th.mveqz
              {7'b010_0001, 3'b001}: instruction_o.op = ariane_pkg::XHEAD_MVNEZ;  // th.mvnez
              default: illegal_instr = 1'b1;
            endcase
          end else begin
            illegal_instr = 1'b1;
          end
        end

        // --------------------------
        // 32bit Reg-Reg Operations
        // --------------------------
        riscv::OpcodeOp32: begin
          instruction_o.fu  = (instr.rtype.funct7 == 7'b000_0001) ? MULT : ALU;
          instruction_o.rs1 = instr.rtype.rs1;
          instruction_o.rs2 = instr.rtype.rs2;
          instruction_o.rd  = instr.rtype.rd;
          if (CVA6Cfg.IS_XLEN64) begin
            unique case ({
              instr.rtype.funct7, instr.rtype.funct3
            })
              {7'b000_0000, 3'b000} : instruction_o.op = ariane_pkg::ADDW;  // addw
              {7'b010_0000, 3'b000} : instruction_o.op = ariane_pkg::SUBW;  // subw
              {7'b000_0000, 3'b001} : instruction_o.op = ariane_pkg::SLLW;  // sllw
              {7'b000_0000, 3'b101} : instruction_o.op = ariane_pkg::SRLW;  // srlw
              {7'b010_0000, 3'b101} : instruction_o.op = ariane_pkg::SRAW;  // sraw
              // Multiplications
              {7'b000_0001, 3'b000} : instruction_o.op = ariane_pkg::MULW;
              {7'b000_0001, 3'b100} : instruction_o.op = ariane_pkg::DIVW;
              {7'b000_0001, 3'b101} : instruction_o.op = ariane_pkg::DIVUW;
              {7'b000_0001, 3'b110} : instruction_o.op = ariane_pkg::REMW;
              {7'b000_0001, 3'b111} : instruction_o.op = ariane_pkg::REMUW;
              default: illegal_instr_non_bm = 1'b1;
            endcase
            if (CVA6Cfg.RVB) begin
              unique case ({
                instr.rtype.funct7, instr.rtype.funct3
              })
                // Bitwise Rotation (Zbb)
                {7'b011_0000, 3'b001} : instruction_o.op = ariane_pkg::ROLW;  // rolw
                {7'b011_0000, 3'b101} : instruction_o.op = ariane_pkg::RORW;  // rorw
                // Zero Extend Op RV64 encoding (Zbb)
                {
                  7'b000_0100, 3'b100
                } : begin
                  if (instr.instr[24:20] == 5'b00000)
                    instruction_o.op = ariane_pkg::ZEXTH;  // Zero Extend Op RV64 encoding
                  else illegal_instr_bm = 1'b1;
                end
                default: illegal_instr_bm = 1'b1;
              endcase
              illegal_instr = illegal_instr_non_bm & illegal_instr_bm;
            end else begin
              illegal_instr = illegal_instr_non_bm;
            end
          end else illegal_instr = 1'b1;
        end
        // --------------------------------
        // Reg-Immediate Operations
        // --------------------------------
        riscv::OpcodeOpImm: begin
          instruction_o.fu = ALU;
          imm_select = IIMM;
          instruction_o.rs1 = instr.itype.rs1;
          instruction_o.rd = instr.itype.rd;
          unique case (instr.itype.funct3)
            3'b000: instruction_o.op = ariane_pkg::ADD;  // Add Immediate
            3'b010: instruction_o.op = ariane_pkg::SLTS;  // Set to one if Lower Than Immediate
            3'b011:
            instruction_o.op = ariane_pkg::SLTU;  // Set to one if Lower Than Immediate Unsigned
            3'b100: instruction_o.op = ariane_pkg::XORL;  // Exclusive Or with Immediate
            3'b110: instruction_o.op = ariane_pkg::ORL;  // Or with Immediate
            3'b111: instruction_o.op = ariane_pkg::ANDL;  // And with Immediate

            3'b001: begin
              instruction_o.op = ariane_pkg::SLL;  // Shift Left Logical by Immediate
              if (instr.instr[31:26] != 6'b0) illegal_instr_non_bm = 1'b1;
              if (instr.instr[25] != 1'b0 && CVA6Cfg.XLEN == 32) illegal_instr_non_bm = 1'b1;
            end

            3'b101: begin
              if (instr.instr[31:26] == 6'b0)
                instruction_o.op = ariane_pkg::SRL;  // Shift Right Logical by Immediate
              else if (instr.instr[31:26] == 6'b010_000)
                instruction_o.op = ariane_pkg::SRA;  // Shift Right Arithmetically by Immediate
              else illegal_instr_non_bm = 1'b1;
              if (instr.instr[25] != 1'b0 && CVA6Cfg.XLEN == 32) illegal_instr_non_bm = 1'b1;
            end
          endcase
          if (CVA6Cfg.RVB) begin
            unique case (instr.itype.funct3)
              3'b001: begin
                if (instr.instr[31:25] == 7'b0110000) begin
                  // Zbb unary operations
                  if (instr.instr[24:20] == 5'b00100) instruction_o.op = ariane_pkg::SEXTB;
                  else if (instr.instr[24:20] == 5'b00101) instruction_o.op = ariane_pkg::SEXTH;
                  else if (instr.instr[24:20] == 5'b00010) instruction_o.op = ariane_pkg::CPOP;
                  else if (instr.instr[24:20] == 5'b00000) instruction_o.op = ariane_pkg::CLZ;
                  else if (instr.instr[24:20] == 5'b00001) instruction_o.op = ariane_pkg::CTZ;
                  else illegal_instr_bm = 1'b1;
                end else illegal_instr_bm = 1'b1;
              end
              3'b101: begin
                // Zbb byte-reverse and or-combine
                if (instr.instr[31:20] == 12'b001010000111) instruction_o.op = ariane_pkg::ORCB;
                else if (CVA6Cfg.IS_XLEN64 && instr.instr[31:20] == 12'b011010111000)
                  instruction_o.op = ariane_pkg::REV8;
                else if (instr.instr[31:20] == 12'b011010011000)
                  instruction_o.op = ariane_pkg::REV8;
                // Zbb rotate right immediate
                else if (CVA6Cfg.IS_XLEN64 && instr.instr[31:26] == 6'b011_000)
                  instruction_o.op = ariane_pkg::RORI;
                else if (CVA6Cfg.IS_XLEN32 && instr.instr[31:25] == 7'b011_0000)
                  instruction_o.op = ariane_pkg::RORI;
                else illegal_instr_bm = 1'b1;
              end
              default: illegal_instr_bm = 1'b1;
            endcase
            illegal_instr = illegal_instr_non_bm & illegal_instr_bm;
          end else begin
            illegal_instr = illegal_instr_non_bm;
          end
        end

        // --------------------------------
        // 32 bit Reg-Immediate Operations
        // --------------------------------
        riscv::OpcodeOpImm32: begin
          instruction_o.fu = ALU;
          imm_select = IIMM;
          instruction_o.rs1 = instr.itype.rs1;
          instruction_o.rd = instr.itype.rd;
          if (CVA6Cfg.IS_XLEN64) begin
            unique case (instr.itype.funct3)
              3'b000:  instruction_o.op = ariane_pkg::ADDW;  // Add Immediate
              3'b001: begin
                instruction_o.op = ariane_pkg::SLLW;  // Shift Left Logical by Immediate
                if (instr.instr[31:25] != 7'b0) illegal_instr_non_bm = 1'b1;
              end
              3'b101: begin
                if (instr.instr[31:25] == 7'b0)
                  instruction_o.op = ariane_pkg::SRLW;  // Shift Right Logical by Immediate
                else if (instr.instr[31:25] == 7'b010_0000)
                  instruction_o.op = ariane_pkg::SRAW;  // Shift Right Arithmetically by Immediate
                else illegal_instr_non_bm = 1'b1;
              end
              default: illegal_instr_non_bm = 1'b1;
            endcase
            if (CVA6Cfg.RVB) begin
              unique case (instr.itype.funct3)
                3'b001: begin
                  if (instr.instr[31:25] == 7'b0110000) begin
                    // Zbb word-width unary operations
                    if (instr.instr[24:20] == 5'b00010) instruction_o.op = ariane_pkg::CPOPW;
                    else if (instr.instr[24:20] == 5'b00000) instruction_o.op = ariane_pkg::CLZW;
                    else if (instr.instr[24:20] == 5'b00001) instruction_o.op = ariane_pkg::CTZW;
                    else illegal_instr_bm = 1'b1;
                  end else illegal_instr_bm = 1'b1;
                end
                3'b101: begin
                  // Zbb rotate right word immediate
                  if (instr.instr[31:25] == 7'b011_0000) instruction_o.op = ariane_pkg::RORIW;
                  else illegal_instr_bm = 1'b1;
                end
                default: illegal_instr_bm = 1'b1;
              endcase
              illegal_instr = illegal_instr_non_bm & illegal_instr_bm;
            end else begin
              illegal_instr = illegal_instr_non_bm;
            end

          end else illegal_instr = 1'b1;
        end
        // --------------------------------
        // LSU
        // --------------------------------
        riscv::OpcodeStore: begin
          instruction_o.fu = STORE;
          imm_select = SIMM;
          instruction_o.rs1 = instr.stype.rs1;
          instruction_o.rs2 = instr.stype.rs2;
          // determine store size
          unique case (instr.stype.funct3)
            3'b000: instruction_o.op = ariane_pkg::SB;
            3'b001: instruction_o.op = ariane_pkg::SH;
            3'b010: instruction_o.op = ariane_pkg::SW;
            3'b011:
            if (CVA6Cfg.XLEN == 64) instruction_o.op = ariane_pkg::SD;
            else illegal_instr = 1'b1;
            default: illegal_instr = 1'b1;
          endcase
        end

        riscv::OpcodeLoad: begin
          instruction_o.fu = LOAD;
          imm_select = IIMM;
          instruction_o.rs1 = instr.itype.rs1;
          instruction_o.rd = instr.itype.rd;
          // determine load size and signed type
          unique case (instr.itype.funct3)
            3'b000: instruction_o.op = ariane_pkg::LB;
            3'b001: instruction_o.op = ariane_pkg::LH;
            3'b010: instruction_o.op = ariane_pkg::LW;
            3'b100: instruction_o.op = ariane_pkg::LBU;
            3'b101: instruction_o.op = ariane_pkg::LHU;
            3'b110:
            if (CVA6Cfg.XLEN == 64) instruction_o.op = ariane_pkg::LWU;
            else illegal_instr = 1'b1;
            3'b011:
            if (CVA6Cfg.XLEN == 64) instruction_o.op = ariane_pkg::LD;
            else illegal_instr = 1'b1;
            default: illegal_instr = 1'b1;
          endcase
        end

        // --------------------------------
        // Floating-Point Load/store
        // --------------------------------
        riscv::OpcodeStoreFp: begin
          illegal_instr = 1'b1;
        end

        riscv::OpcodeLoadFp: begin
          illegal_instr = 1'b1;
        end

        // ----------------------------------
        // Floating-Point Reg-Reg Operations
        // ----------------------------------
        riscv::OpcodeMadd, riscv::OpcodeMsub, riscv::OpcodeNmsub, riscv::OpcodeNmadd: begin
          illegal_instr = 1'b1;
        end

        riscv::OpcodeOpFp: begin
          illegal_instr = 1'b1;
        end

        // ----------------------------------
        // Atomic Operations
        // ----------------------------------
        riscv::OpcodeAmo: begin
          // we are going to use the load unit for AMOs
          instruction_o.fu  = STORE;
          instruction_o.rs1 = instr.atype.rs1;
          instruction_o.rs2 = instr.atype.rs2;
          instruction_o.rd  = instr.atype.rd;
          // TODO(zarubaf): Ordering
          // words
          if (CVA6Cfg.RVA && instr.stype.funct3 == 3'h2) begin
            unique case (instr.instr[31:27])
              5'h0: instruction_o.op = ariane_pkg::AMO_ADDW;
              5'h1: instruction_o.op = ariane_pkg::AMO_SWAPW;
              5'h2: begin
                instruction_o.op = ariane_pkg::AMO_LRW;
                if (instr.atype.rs2 != 0) illegal_instr = 1'b1;
              end
              5'h3: instruction_o.op = ariane_pkg::AMO_SCW;
              5'h4: instruction_o.op = ariane_pkg::AMO_XORW;
              5'h8: instruction_o.op = ariane_pkg::AMO_ORW;
              5'hC: instruction_o.op = ariane_pkg::AMO_ANDW;
              5'h10: instruction_o.op = ariane_pkg::AMO_MINW;
              5'h14: instruction_o.op = ariane_pkg::AMO_MAXW;
              5'h18: instruction_o.op = ariane_pkg::AMO_MINWU;
              5'h1C: instruction_o.op = ariane_pkg::AMO_MAXWU;
              default: illegal_instr = 1'b1;
            endcase
            // double words
          end else if (CVA6Cfg.IS_XLEN64 && CVA6Cfg.RVA && instr.stype.funct3 == 3'h3) begin
            unique case (instr.instr[31:27])
              5'h0: instruction_o.op = ariane_pkg::AMO_ADDD;
              5'h1: instruction_o.op = ariane_pkg::AMO_SWAPD;
              5'h2: begin
                instruction_o.op = ariane_pkg::AMO_LRD;
                if (instr.atype.rs2 != 0) illegal_instr = 1'b1;
              end
              5'h3: instruction_o.op = ariane_pkg::AMO_SCD;
              5'h4: instruction_o.op = ariane_pkg::AMO_XORD;
              5'h8: instruction_o.op = ariane_pkg::AMO_ORD;
              5'hC: instruction_o.op = ariane_pkg::AMO_ANDD;
              5'h10: instruction_o.op = ariane_pkg::AMO_MIND;
              5'h14: instruction_o.op = ariane_pkg::AMO_MAXD;
              5'h18: instruction_o.op = ariane_pkg::AMO_MINDU;
              5'h1C: instruction_o.op = ariane_pkg::AMO_MAXDU;
              default: illegal_instr = 1'b1;
            endcase
          end else begin
            illegal_instr = 1'b1;
          end
        end

        // --------------------------------
        // Control Flow Instructions
        // --------------------------------
        riscv::OpcodeBranch: begin
          imm_select              = SBIMM;
          instruction_o.fu        = CTRL_FLOW;
          instruction_o.rs1       = instr.stype.rs1;
          instruction_o.rs2       = instr.stype.rs2;

          is_control_flow_instr_o = 1'b1;

          case (instr.stype.funct3)
            3'b000: instruction_o.op = ariane_pkg::EQ;
            3'b001: instruction_o.op = ariane_pkg::NE;
            3'b100: instruction_o.op = ariane_pkg::LTS;
            3'b101: instruction_o.op = ariane_pkg::GES;
            3'b110: instruction_o.op = ariane_pkg::LTU;
            3'b111: instruction_o.op = ariane_pkg::GEU;
            default: begin
              is_control_flow_instr_o = 1'b0;
              illegal_instr           = 1'b1;
            end
          endcase
        end
        // Jump and link register
        riscv::OpcodeJalr: begin
          instruction_o.fu        = CTRL_FLOW;
          instruction_o.op        = ariane_pkg::JALR;
          instruction_o.rs1       = instr.itype.rs1;
          imm_select              = IIMM;
          instruction_o.rd        = instr.itype.rd;
          is_control_flow_instr_o = 1'b1;
          // invalid jump and link register -> reserved for vector encoding
          if (instr.itype.funct3 != 3'b0) illegal_instr = 1'b1;
        end
        // Jump and link
        riscv::OpcodeJal: begin
          instruction_o.fu        = CTRL_FLOW;
          imm_select              = JIMM;
          instruction_o.rd        = instr.utype.rd;
          is_control_flow_instr_o = 1'b1;
        end

        riscv::OpcodeAuipc: begin
          instruction_o.fu     = ALU;
          imm_select           = UIMM;
          instruction_o.use_pc = 1'b1;
          instruction_o.rd     = instr.utype.rd;
        end

        riscv::OpcodeLui: begin
          imm_select       = UIMM;
          instruction_o.fu = ALU;
          instruction_o.rd = instr.utype.rd;
        end

        default: illegal_instr = 1'b1;
      endcase
    end
    if (CVA6Cfg.CvxifEn) begin
      if (~ex_i.valid && (is_illegal_i || illegal_instr)) begin
        instruction_o.fu = CVXIF;
        instruction_o.rs1 = instr.r4type.rs1;
        instruction_o.rs2 = instr.r4type.rs2;
        instruction_o.rd = instr.r4type.rd;
        instruction_o.op = ariane_pkg::OFFLOAD;
        imm_select             = instr.rtype.opcode == riscv::OpcodeMadd ||
                                 instr.rtype.opcode == riscv::OpcodeMsub ||
                                 instr.rtype.opcode == riscv::OpcodeNmadd ||
                                 instr.rtype.opcode == riscv::OpcodeNmsub ? RS3 : MUX_RD_RS3;
      end
    end

    // Accelerator removed - is_accel is always 0
  end

  // --------------------------------
  // Sign extend immediate
  // --------------------------------
  always_comb begin : sign_extend
    imm_i_type = {{CVA6Cfg.XLEN - 12{instruction_i[31]}}, instruction_i[31:20]};
    imm_s_type = {
      {CVA6Cfg.XLEN - 12{instruction_i[31]}}, instruction_i[31:25], instruction_i[11:7]
    };
    imm_sb_type = {
      {CVA6Cfg.XLEN - 13{instruction_i[31]}},
      instruction_i[31],
      instruction_i[7],
      instruction_i[30:25],
      instruction_i[11:8],
      1'b0
    };
    imm_u_type = {
      {CVA6Cfg.XLEN - 32{instruction_i[31]}}, instruction_i[31:12], 12'b0
    };  // JAL, AUIPC, sign extended to 64 bit
    //  if zcmt then xlen jump address assign to immediate
    if (CVA6Cfg.RVZCMT && is_zcmt_i) begin
      imm_uj_type = {{CVA6Cfg.XLEN - 32{jump_address_i[31]}}, jump_address_i[31:0]};
    end else begin
      imm_uj_type = {
        {CVA6Cfg.XLEN - 20{instruction_i[31]}},
        instruction_i[19:12],
        instruction_i[20],
        instruction_i[30:21],
        1'b0
      };
    end

    // NOIMM, IIMM, SIMM, SBIMM, UIMM, JIMM, RS3
    // select immediate
    case (imm_select)
      IIMM: begin
        instruction_o.result  = imm_i_type;
        instruction_o.use_imm = 1'b1;
      end
      SIMM: begin
        instruction_o.result  = imm_s_type;
        instruction_o.use_imm = 1'b1;
      end
      SBIMM: begin
        instruction_o.result  = imm_sb_type;
        instruction_o.use_imm = 1'b1;
      end
      UIMM: begin
        instruction_o.result  = imm_u_type;
        instruction_o.use_imm = 1'b1;
      end
      JIMM: begin
        instruction_o.result  = imm_uj_type;
        instruction_o.use_imm = 1'b1;
      end
      RS3: begin
        // result holds address of fp operand rs3
        instruction_o.result  = {{CVA6Cfg.XLEN - 5{1'b0}}, instr.r4type.rs3};
        instruction_o.use_imm = 1'b0;
      end
      MUX_RD_RS3: begin
        // result holds address of operand rs3 which is in rd field
        instruction_o.result  = {{CVA6Cfg.XLEN - 5{1'b0}}, instr.rtype.rd};
        instruction_o.use_imm = 1'b0;
      end
      default: begin
        instruction_o.result  = {CVA6Cfg.XLEN{1'b0}};
        instruction_o.use_imm = 1'b0;
      end
    endcase

    // Accelerator removed - is_accel is always 0
  end

  // ---------------------
  // Exception handling
  // ---------------------
  logic [CVA6Cfg.XLEN-1:0] interrupt_cause;

  // this instruction has already executed if the exception is valid
  assign instruction_o.valid = instruction_o.ex.valid;

  always_comb begin : exception_handling
    interrupt_cause = '0;
    instruction_o.ex = ex_i;
    orig_instr_o = '0;
    // look if we didn't already get an exception in any previous
    // stage - we should not overwrite it as we retain order regarding the exception
    if (~ex_i.valid) begin
      // if we didn't already get an exception save the instruction here as we may need it
      // in the commit stage if we got a access exception to one of the CSR registers
      if (CVA6Cfg.CvxifEn || CVA6Cfg.RVF)
        orig_instr_o = (is_compressed_i) ? {{CVA6Cfg.XLEN-16{1'b0}}, compressed_instr_i} : {{CVA6Cfg.XLEN-32{1'b0}}, instruction_i};
      if (CVA6Cfg.TvalEn)
        instruction_o.ex.tval  = (is_compressed_i) ? {{CVA6Cfg.XLEN-16{1'b0}}, compressed_instr_i} : {{CVA6Cfg.XLEN-32{1'b0}}, instruction_i};
      else instruction_o.ex.tval = '0;
      instruction_o.ex.tinst = '0;
      // instructions which will throw an exception are marked as valid
      // e.g.: they can be committed anytime and do not need to wait for any functional unit
      // check here if we decoded an invalid instruction or if the compressed decoder already decoded
      // a invalid instruction
      if (illegal_instr || is_illegal_i) begin
        if (!CVA6Cfg.CvxifEn) instruction_o.ex.valid = 1'b1;
        // we decoded an illegal exception here
        instruction_o.ex.cause = riscv::ILLEGAL_INSTR;
      // we got an ecall, set the correct cause depending on the current privilege level
      end else if (ecall) begin
        // this exception is valid
        instruction_o.ex.valid = 1'b1;
        // depending on the privilege mode, set the appropriate cause
        if (priv_lvl_i == riscv::PRIV_LVL_S && CVA6Cfg.RVS) begin
          instruction_o.ex.cause = riscv::ENV_CALL_SMODE;
        end else if (priv_lvl_i == riscv::PRIV_LVL_U && CVA6Cfg.RVU) begin
          instruction_o.ex.cause = riscv::ENV_CALL_UMODE;
        end else if (priv_lvl_i == riscv::PRIV_LVL_M) begin
          instruction_o.ex.cause = riscv::ENV_CALL_MMODE;
        end
        if (CVA6Cfg.TvalEn) instruction_o.ex.tval = '0;
      end else if (ebreak) begin
        // this exception is valid
        instruction_o.ex.valid = 1'b1;
        // set breakpoint cause
        instruction_o.ex.cause = riscv::BREAKPOINT;
        // set gva bit
        instruction_o.ex.gva = 1'b0;
        if (CVA6Cfg.TvalEn) instruction_o.ex.tval = pc_i;
      end
      // -----------------
      // Interrupt Control
      // -----------------
      // we decode an interrupt the same as an exception, hence it will be taken if the instruction did not
      // throw any previous exception.
      // we have three interrupt sources: external interrupts, software interrupts, timer interrupts (order of precedence)
      // for two privilege levels: Supervisor and Machine Mode
      if (CVA6Cfg.RVS) begin
        // Supervisor Timer Interrupt
        if (irq_ctrl_i.mie[riscv::IRQ_S_TIMER] && irq_ctrl_i.mip[riscv::IRQ_S_TIMER]) begin
          interrupt_cause = INTERRUPTS.S_TIMER;
        end
        // Supervisor Software Interrupt
        if (irq_ctrl_i.mie[riscv::IRQ_S_SOFT] && irq_ctrl_i.mip[riscv::IRQ_S_SOFT]) begin
          interrupt_cause = INTERRUPTS.S_SW;
        end
        // Supervisor External Interrupt
        // The logical-OR of the software-writable bit and the signal from the external interrupt controller is
        // used to generate external interrupts to the supervisor
        if (irq_ctrl_i.mie[riscv::IRQ_S_EXT] && (irq_ctrl_i.mip[riscv::IRQ_S_EXT] | irq_i[ariane_pkg::SupervisorIrq])) begin
          interrupt_cause = INTERRUPTS.S_EXT;
        end
      end
      // Machine Timer Interrupt
      if (irq_ctrl_i.mip[riscv::IRQ_M_TIMER] && irq_ctrl_i.mie[riscv::IRQ_M_TIMER]) begin
        interrupt_cause = INTERRUPTS.M_TIMER;
      end
      if (CVA6Cfg.SoftwareInterruptEn) begin
        // Machine Mode Software Interrupt
        if (irq_ctrl_i.mip[riscv::IRQ_M_SOFT] && irq_ctrl_i.mie[riscv::IRQ_M_SOFT]) begin
          interrupt_cause = INTERRUPTS.M_SW;
        end
      end
      // Machine Mode External Interrupt
      if (irq_ctrl_i.mip[riscv::IRQ_M_EXT] && irq_ctrl_i.mie[riscv::IRQ_M_EXT]) begin
        interrupt_cause = INTERRUPTS.M_EXT;
      end

      if (interrupt_cause[CVA6Cfg.XLEN-1] && irq_ctrl_i.global_enable) begin
        // However, if bit i in mideleg is set, interrupts are considered to be globally enabled if the hart’s current privilege
        // mode equals the delegated privilege mode (S or U) and that mode’s interrupt enable bit
        // (SIE or UIE in mstatus) is set, or if the current privilege mode is less than the delegated privilege mode.
        if (irq_ctrl_i.mideleg[interrupt_cause[$clog2(CVA6Cfg.XLEN)-1:0]]) begin
            if ((CVA6Cfg.RVS && irq_ctrl_i.sie && priv_lvl_i == riscv::PRIV_LVL_S) || (CVA6Cfg.RVU && priv_lvl_i == riscv::PRIV_LVL_U)) begin
              instruction_o.ex.valid = 1'b1;
              instruction_o.ex.cause = interrupt_cause;
            end
        end else begin
          instruction_o.ex.valid = 1'b1;
          instruction_o.ex.cause = interrupt_cause;
        end
      end
    end

    // a debug request has precendece over everything else
    if ((CVA6Cfg.DebugEn && debug_req_i && !debug_mode_i) || (CVA6Cfg.SDTRIG && CVA6Cfg.Mcontrol6 && CVA6Cfg.DebugEn && !debug_mode_i && debug_from_trigger_i)) begin
      instruction_o.ex.valid = 1'b1;
      instruction_o.ex.cause = riscv::DEBUG_REQUEST;
    end
  end
endmodule
