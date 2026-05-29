// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// Standalone self-checking testbench for pvm_decoder.sv (Stage 2 gate).
// Primary golden source: the real example-hello-world.polkavm program — every
// one of its 10 instructions is decoded and checked field-by-field against the
// disassembly (with the r->GPR(+1) mapping). Plus hand cases for a 3-reg ALU op,
// a reg-reg branch, a conditional-move, a privileged CSR, an invalid opcode, and
// a deferred/unsupported opcode.
//
// Build & run (example):
//   $ verilator --binary -sv core/include/config_pkg.sv \
//       core/include/cv64a6_emac_polkavm_config_pkg.sv core/include/riscv_pkg.sv \
//       core/include/ariane_pkg.sv core/include/polkavm_pkg.sv core/pvm_decoder.sv \
//       verif/tb/pvm_decoder_tb.sv --top-module pvm_decoder_tb -o pvm_decoder_tb \
//       && ./obj_dir/pvm_decoder_tb

module pvm_decoder_tb;
  import ariane_pkg::*;
  import polkavm_pkg::*;

  localparam int VLEN = 32;

  logic [7:0]      opcode;
  logic [127:0]    instr_window;
  logic [VLEN-1:0] pc;
  logic [4:0]      skip;

  fu_t             fu_o;
  fu_op            op_o;
  logic [4:0]      rd_o, rs1_o, rs2_o;
  logic [63:0]     imm_o;
  logic            use_imm_o, is_branch_o, is_jump_o, is_djump_o;
  logic [VLEN-1:0] branch_target_o;
  logic            is_hostcall_o;
  logic [63:0]     hostcall_id_o;
  logic            is_trap_o, illegal_o, unsupported_o;

  int errors = 0;

  pvm_decoder #(.VLEN(VLEN)) dut (
      .opcode_i       (opcode),
      .instr_window_i (instr_window),
      .pc_i           (pc),
      .skip_i         (skip),
      .fu_o, .op_o, .rd_o, .rs1_o, .rs2_o, .imm_o, .use_imm_o,
      .is_branch_o, .is_jump_o, .is_djump_o, .branch_target_o,
      .is_hostcall_o, .hostcall_id_o, .is_trap_o, .illegal_o, .unsupported_o
  );

  // hello-world code image (25 bytes)
  logic [7:0] code_mem [0:31];

  function automatic logic [127:0] win_at(input int unsigned p);
    logic [127:0] w;
    w = '0;
    for (int b = 0; b < 16; b++)
      if ((p + b) < 32) w[b*8+:8] = code_mem[p+b];
    return w;
  endfunction

  task automatic chk(input string nm, input logic cond);
    if (!cond) begin errors++; $display("FAIL %s", nm); end
  endtask

  // check a data-path instruction (fu/op/regs/imm/use_imm)
  task automatic check_instr(input string nm, input int unsigned pcv, input int unsigned skp,
                             input fu_t efu, input fu_op eop,
                             input int erd, input int ers1, input int ers2,
                             input logic [63:0] eimm, input logic euse);
    opcode = code_mem[pcv]; instr_window = win_at(pcv); pc = pcv; skip = skp[4:0]; #1;
    if (fu_o   !== efu)        begin errors++; $display("FAIL %s: fu got=%0d exp=%0d",  nm, int'(fu_o),  int'(efu)); end
    if (op_o   !== eop)        begin errors++; $display("FAIL %s: op got=%0d exp=%0d",  nm, int'(op_o),  int'(eop)); end
    if (rd_o   !== erd[4:0])   begin errors++; $display("FAIL %s: rd got=%0d exp=%0d",  nm, rd_o,  erd);  end
    if (rs1_o  !== ers1[4:0])  begin errors++; $display("FAIL %s: rs1 got=%0d exp=%0d", nm, rs1_o, ers1); end
    if (rs2_o  !== ers2[4:0])  begin errors++; $display("FAIL %s: rs2 got=%0d exp=%0d", nm, rs2_o, ers2); end
    if (imm_o  !== eimm)       begin errors++; $display("FAIL %s: imm got=%h exp=%h",   nm, imm_o, eimm); end
    if (use_imm_o !== euse)    begin errors++; $display("FAIL %s: use_imm got=%b exp=%b", nm, use_imm_o, euse); end
  endtask

  // drive a raw (hand-built) instruction
  task automatic drive_raw(input logic [7:0] op, input logic [7:0] b1,
                           input logic [7:0] b2, input int unsigned skp);
    opcode = op; instr_window = '0;
    instr_window[7:0]   = op;
    instr_window[15:8]  = b1;
    instr_window[23:16] = b2;
    pc = 32'd0; skip = skp[4:0]; #1;
  endtask

  initial begin
    for (int i = 0; i < 32; i++) code_mem[i] = 8'h00;
    code_mem[0]=8'h83; code_mem[1]=8'h11; code_mem[2]=8'hf8; code_mem[3]=8'h7a;
    code_mem[4]=8'h10; code_mem[5]=8'h04; code_mem[6]=8'h7a; code_mem[7]=8'h15;
    code_mem[8]=8'hbe; code_mem[9]=8'h78; code_mem[10]=8'h05; code_mem[11]=8'h0a;
    code_mem[12]=8'hbe; code_mem[13]=8'h57; code_mem[14]=8'h07; code_mem[15]=8'h81;
    code_mem[16]=8'h10; code_mem[17]=8'h04; code_mem[18]=8'h81; code_mem[19]=8'h15;
    code_mem[20]=8'h83; code_mem[21]=8'h11; code_mem[22]=8'h08; code_mem[23]=8'h32;
    code_mem[24]=8'h00;

    // ---- hello-world program, instruction by instruction ----
    // pc=0 : add_imm_32 sp,sp,-8   rd=2 rs1=2 imm=0xFFFFFFFFFFFFFFF8
    check_instr("hw0 add_imm32", 0, 2, ALU, ADDW, 2, 2, 0, 64'hFFFF_FFFF_FFFF_FFF8, 1'b1);
    // pc=3 : store_ind_u32 [sp+4]=ra  base rB=sp(2) data rA=ra(1) imm=4
    check_instr("hw3 store_u32", 3, 2, STORE, SW, 0, 2, 1, 64'd4, 1'b1);
    // pc=6 : store_ind_u32 [sp]=s0    base rB=sp(2) data rA=s0(6) imm=0
    check_instr("hw6 store_u32", 6, 1, STORE, SW, 0, 2, 6, 64'd0, 1'b1);
    // pc=8 : add_32 s0=a1+a0   rD=s0(6) rA=a1(9) rB=a0(8)
    check_instr("hw8 add_32",   8, 2, ALU, ADDW, 6, 9, 8, 64'd0, 1'b0);
    // pc=11: ecalli 0  (checked separately below)
    opcode=code_mem[11]; instr_window=win_at(11); pc=11; skip=5'd0; #1;
    chk("hw11 ecalli is_hostcall", is_hostcall_o === 1'b1);
    chk("hw11 ecalli id=0",        hostcall_id_o === 64'd0);
    chk("hw11 ecalli fu=NONE",     fu_o === NONE);
    // pc=12: add_32 a0=a0+s0   rD=a0(8) rA=a0(8) rB=s0(6)
    check_instr("hw12 add_32",  12, 2, ALU, ADDW, 8, 8, 6, 64'd0, 1'b0);
    // pc=15: load_ind_i32 ra=[sp+4]  rd=ra(1) base rB=sp(2) imm=4
    check_instr("hw15 load_i32",15, 2, LOAD, LW, 1, 2, 0, 64'd4, 1'b1);
    // pc=18: load_ind_i32 s0=[sp]    rd=s0(6) base rB=sp(2) imm=0
    check_instr("hw18 load_i32",18, 1, LOAD, LW, 6, 2, 0, 64'd0, 1'b1);
    // pc=20: add_imm_32 sp,sp,8  rd=2 rs1=2 imm=8
    check_instr("hw20 add_imm32",20, 2, ALU, ADDW, 2, 2, 0, 64'd8, 1'b1);
    // pc=23: jump_ind ra  rs1=ra(1) imm=0 (a dynamic jump -> is_djump, NOT is_jump)
    check_instr("hw23 jump_ind",23, 1, CTRL_FLOW, JALR, 0, 1, 0, 64'd0, 1'b1);
    chk("hw23 is_djump", is_djump_o === 1'b1);
    chk("hw23 not is_jump", is_jump_o === 1'b0);

    // ---- hand cases ----
    // trap
    drive_raw(PVM_OP_TRAP, 8'h00, 8'h00, 0);
    chk("trap is_trap", is_trap_o === 1'b1);
    // add_64 3reg: rD from b2=3 ->4, rA=lo(b1=0x21)=1 ->2, rB=hi=2 ->3
    drive_raw(PVM_OP_ADD_64, 8'h21, 8'h03, 0);
    chk("add64 fu",  fu_o === ALU);
    chk("add64 op",  op_o === ADD);
    chk("add64 rd",  rd_o === 5'd4);
    chk("add64 rs1", rs1_o === 5'd2);
    chk("add64 rs2", rs2_o === 5'd3);
    // mul_64 3reg -> MULT/MUL
    drive_raw(PVM_OP_MUL_64, 8'h21, 8'h03, 0);
    chk("mul64 fu", fu_o === MULT);
    chk("mul64 op", op_o === MUL);
    // cmov_if_zero -> XHEAD_MVEQZ
    drive_raw(PVM_OP_CMOV_IZ, 8'h21, 8'h03, 0);
    chk("cmoviz op", op_o === XHEAD_MVEQZ);
    // branch_eq (2reg+off): rA=lo(0x21)=1->2, rB=hi=2->3, skip=2 imm offset
    instr_window = '0; instr_window[7:0]=PVM_OP_BRANCH_EQ; instr_window[15:8]=8'h21;
    instr_window[23:16]=8'h04;  // offset byte = +4
    opcode=PVM_OP_BRANCH_EQ; pc=32'd10; skip=5'd2; #1;
    chk("breq fu",     fu_o === CTRL_FLOW);
    chk("breq op",     op_o === EQ);
    chk("breq is_br",  is_branch_o === 1'b1);
    chk("breq rs1",    rs1_o === 5'd2);
    chk("breq rs2",    rs2_o === 5'd3);
    chk("breq target", branch_target_o === 32'd14);  // pc(10)+4
    // csr_rw (231): rd=b1[7:4]+1, rs1=b1[3:0]+1, csr in imm
    instr_window='0; instr_window[7:0]=PVM_OP_CSR_RW; instr_window[15:8]=8'h21; // rd=2->3, rs1=1->2
    instr_window[23:16]=8'h00; instr_window[31:24]=8'h03; // imm bytes (csr) len from skip
    opcode=PVM_OP_CSR_RW; pc=32'd0; skip=5'd3; #1;  // skip=3 -> len_ri=min(4,2)=2
    chk("csrrw fu", fu_o === CSR);
    chk("csrrw op", op_o === CSR_WRITE);
    chk("csrrw rd", rd_o === 5'd3);
    chk("csrrw rs1",rs1_o === 5'd2);
    // invalid opcode 11 -> illegal
    drive_raw(8'd11, 8'h00, 8'h00, 0);
    chk("op11 illegal",    illegal_o === 1'b1);
    chk("op11 !unsupported",unsupported_o === 1'b0);
    // store_imm (30) valid but deferred -> unsupported
    drive_raw(PVM_OP_STORE_IMM_U8, 8'h00, 8'h00, 1);
    chk("op30 unsupported", unsupported_o === 1'b1);
    chk("op30 !illegal",    illegal_o === 1'b0);

    if (errors != 0) begin
      $display("PVM_DECODER_TB: %0d CHECK(S) FAILED", errors);
      $fatal(1, "pvm_decoder_tb failed");
    end else begin
      $display("PVM_DECODER_TB: ALL CHECKS PASSED");
    end
    $finish;
  end

endmodule
