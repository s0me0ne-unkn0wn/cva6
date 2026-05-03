// PolkaVM JAM v1 frontend testbench — sub-phase 4 / 4.5.
//
// 8-instruction test program with mixed instruction lengths:
//
//   Offset  Instruction                               Bytes  skip
//   0       trap                                      1      0
//   1       load_imm RA(0), 0x42                     3      2
//   4       add_64 A0(7), A1(8), A2(9)               3      2
//   7       jump 0x10                                 5      4
//   12      load_imm64 A3(10), 0xFFFFFFFFDEADBEEF    10     9
//   22      branch_eq_imm A0(7), 0, 0x10             6      5
//   28      ecalli 0xFFFFFFFF                         5      4
//   33      trap                                      1      0
//
// Encoding per polkavm-common/src/program.rs and graypaper §pvm:79:
//   trap:          op=0x00 (no_args)
//   load_imm:      op=0x33 (51, reg_imm): b1[3:0]=reg, b2..bN=imm
//   add_64:        op=0xC8 (200, reg_reg_reg): b1[3:0]=rs2, b1[7:4]=rs3, b2[3:0]=rd
//   jump:          op=0x28 (40, offset): b1..b4=imm32 LE
//   load_imm64:    op=0x14 (20, reg_imm64): b1[3:0]=reg, b2..b9=imm64 LE
//   branch_eq_imm: op=0x51 (81, reg_imm_offset): b1[3:0]=rs1, b1[7:4]=imm1_nbytes
//   ecalli:        op=0x0A (10, imm): b1..b4=imm32 LE
//
// Bitmask layout (1 bit per code byte; set at opcode positions + sentinel):
//   Opcode positions: 0, 1, 4, 7, 12, 22, 28, 33
//   Sentinel at byte 34 ensures skip(33) = 0 (trap is 1 byte).
//   bitmask_rom[0] = 0x93  (bits 0,1,4,7)
//   bitmask_rom[1] = 0x10  (bit 4 → global byte 12)
//   bitmask_rom[2] = 0x40  (bit 6 → global byte 22)
//   bitmask_rom[3] = 0x10  (bit 4 → global byte 28)
//   bitmask_rom[4] = 0x06  (bits 1,2 → global bytes 33, 34 sentinel)
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

`timescale 1ns/1ps

module pvm_frontend_tb;

  // =========================================================================
  // DUT parameters
  // =========================================================================
  localparam int unsigned VADDR = 8;  // 8-bit = 256-byte address space

  // =========================================================================
  // Clock and reset
  // =========================================================================
  logic clk = 0;
  always #5 clk = ~clk;   // 100 MHz (10 ns period)

  logic rst_n;
  initial rst_n = 0;

  // =========================================================================
  // ROM models
  // =========================================================================
  bit [7:0] code_rom    [0:255];  // 256-byte code ROM
  bit [7:0] bitmask_rom [0:31];   // 32-byte bitmask ROM (256 bits / 8)

  // =========================================================================
  // DUT signals
  // =========================================================================
  logic [VADDR-1:0] code_addr;
  logic [127:0]     code_data;
  logic [127:0]     code_data_next;
  logic [VADDR-1:0] bitmask_addr;
  logic [31:0]      bitmask_data;
  logic             branch_redirect_valid;
  logic [VADDR-1:0] branch_redirect_target;
  logic             valid;
  logic [127:0]     chunk;
  logic [4:0]       skip;
  logic             is_valid_opcode;
  logic [VADDR-1:0] pc_out;
  logic             ready;

  // =========================================================================
  // DUT instantiation
  // =========================================================================
  pvm_frontend #(
    .VirtualAddrSize(VADDR)
  ) dut (
    .clk_i                    (clk),
    .rst_ni                   (rst_n),
    .code_addr_o              (code_addr),
    .code_data_i              (code_data),
    .code_data_next_i         (code_data_next),
    .bitmask_addr_o           (bitmask_addr),
    .bitmask_data_i           (bitmask_data),
    .branch_redirect_valid_i  (branch_redirect_valid),
    .branch_redirect_target_i (branch_redirect_target),
    .valid_o                  (valid),
    .chunk_o                  (chunk),
    .skip_o                   (skip),
    .is_valid_opcode_o        (is_valid_opcode),
    .pc_o                     (pc_out),
    .ready_i                  (ready)
  );

  // =========================================================================
  // Combinatorial ROM model
  // =========================================================================
  always_comb begin : p_code_rom
    code_data = '0;
    for (int b = 0; b < 16; b++) begin
      if ((int'(code_addr) + b) < 256)
        code_data[b*8 +: 8] = code_rom[code_addr + VADDR'(b)];
    end
  end

  // Next 16-byte group for cross-boundary instruction fetch.
  always_comb begin : p_code_rom_next
    code_data_next = '0;
    for (int b = 0; b < 16; b++) begin
      if ((int'(code_addr) + 16 + b) < 256)
        code_data_next[b*8 +: 8] = code_rom[code_addr + VADDR'(16) + VADDR'(b)];
    end
  end

  always_comb begin : p_bitmask_rom
    bitmask_data = '0;
    for (int b = 0; b < 4; b++) begin
      if ((int'(bitmask_addr) + b) < 32)
        bitmask_data[b*8 +: 8] = bitmask_rom[5'(bitmask_addr) + 5'(b)];
    end
  end

  // =========================================================================
  // Test counters
  // =========================================================================
  int pass_cnt;
  int fail_cnt;

  initial begin
    pass_cnt = 0;
    fail_cnt = 0;
  end

  // =========================================================================
  // Check task — called at stable point (after #1 from posedge)
  // =========================================================================
  task automatic check_instr(
    input logic [VADDR-1:0] exp_pc,
    input logic [7:0]       exp_op,
    input logic [4:0]       exp_skip,
    input logic             exp_valid_op,
    input string            name
  );
    automatic logic ok = 1'b1;
    if (!valid) begin
      $display("FAIL [%s] valid=0", name);
      ok = 1'b0;
    end
    if (pc_out !== exp_pc) begin
      $display("FAIL [%s] pc: got 0x%02h, exp 0x%02h", name, pc_out, exp_pc);
      ok = 1'b0;
    end
    if (chunk[7:0] !== exp_op) begin
      $display("FAIL [%s] opcode: got 0x%02h, exp 0x%02h", name, chunk[7:0], exp_op);
      ok = 1'b0;
    end
    if (skip !== exp_skip) begin
      $display("FAIL [%s] skip: got %0d, exp %0d", name, skip, exp_skip);
      ok = 1'b0;
    end
    if (is_valid_opcode !== exp_valid_op) begin
      $display("FAIL [%s] is_valid_opcode: got %0b, exp %0b",
               name, is_valid_opcode, exp_valid_op);
      ok = 1'b0;
    end
    if (ok) begin
      $display("PASS [%s] pc=0x%02h op=0x%02h skip=%0d", name, pc_out, chunk[7:0], skip);
      pass_cnt++;
    end else begin
      fail_cnt++;
    end
  endtask

  // =========================================================================
  // ROM initialisation — shared across all tests
  // =========================================================================
  task automatic init_rom();
    for (int i = 0; i < 256; i++) code_rom[i]    = 8'h00;
    for (int i = 0; i < 32;  i++) bitmask_rom[i] = 8'h00;

    // Instruction 0: trap @ byte 0 (1 byte, skip=0)
    code_rom[0]  = 8'h00;

    // Instruction 1: load_imm RA(0), 0x42 @ byte 1 (3 bytes, skip=2)
    code_rom[1]  = 8'h33;   // op
    code_rom[2]  = 8'h00;   // b1: rd=RA=0
    code_rom[3]  = 8'h42;   // b2: imm=0x42

    // Instruction 2: add_64 A0(7), A1(8), A2(9) @ byte 4 (3 bytes, skip=2)
    code_rom[4]  = 8'hC8;   // op
    code_rom[5]  = 8'h98;   // b1: rs2=A1=8 (lo), rs3=A2=9 (hi)
    code_rom[6]  = 8'h07;   // b2: rd=A0=7 (lo nibble)

    // Instruction 3: jump 0x10 @ byte 7 (5 bytes, skip=4)
    code_rom[7]  = 8'h28;   // op
    code_rom[8]  = 8'h10;   // b1: imm[7:0]
    code_rom[9]  = 8'h00;
    code_rom[10] = 8'h00;
    code_rom[11] = 8'h00;   // b4: imm[31:24]

    // Instruction 4: load_imm64 A3(10), 0xFFFFFFFFDEADBEEF @ byte 12 (10 bytes, skip=9)
    code_rom[12] = 8'h14;   // op
    code_rom[13] = 8'h0A;   // b1: reg=A3=10
    code_rom[14] = 8'hEF;   // b2: imm64[7:0]
    code_rom[15] = 8'hBE;
    code_rom[16] = 8'hAD;
    code_rom[17] = 8'hDE;
    code_rom[18] = 8'hFF;
    code_rom[19] = 8'hFF;
    code_rom[20] = 8'hFF;
    code_rom[21] = 8'hFF;   // b9: imm64[63:56]

    // Instruction 5: branch_eq_imm A0(7), 0, 0x10 @ byte 22 (6 bytes, skip=5)
    code_rom[22] = 8'h51;   // op
    code_rom[23] = 8'h07;   // b1: rs1=A0=7, imm1_nbytes=0
    code_rom[24] = 8'h10;   // b2: offset[7:0]
    code_rom[25] = 8'h00;
    code_rom[26] = 8'h00;
    code_rom[27] = 8'h00;   // b5: offset[31:24]

    // Instruction 6: ecalli 0xFFFFFFFF @ byte 28 (5 bytes, skip=4)
    code_rom[28] = 8'h0A;   // op
    code_rom[29] = 8'hFF;
    code_rom[30] = 8'hFF;
    code_rom[31] = 8'hFF;
    code_rom[32] = 8'hFF;   // b4: imm[31:24]

    // Instruction 7: trap @ byte 33 (1 byte, skip=0)
    code_rom[33] = 8'h00;

    // Bitmask (opcode positions: 0,1,4,7,12,22,28,33)
    // A sentinel bit at byte 34 ensures skip(33) = 34-33-1 = 0.
    // Without it the encoder finds no next opcode and returns skip=15 (wrong).
    // In a real program the next instruction's opcode bit serves this role.
    // The PVM blob terminator guarantees at least one valid byte after the last
    // instruction; this sentinel matches that guarantee.
    bitmask_rom[0] = 8'b1001_0011;   // bits 0,1,4,7
    bitmask_rom[1] = 8'b0001_0000;   // bit 4  (→ global byte 12)
    bitmask_rom[2] = 8'b0100_0000;   // bit 6  (→ global byte 22)
    bitmask_rom[3] = 8'b0001_0000;   // bit 4  (→ global byte 28)
    bitmask_rom[4] = 8'b0000_0110;   // bits 1,2 (→ global bytes 33,34 sentinel)
  endtask

  // =========================================================================
  // Helper: do a synchronous reset, wait 2 posedges, return at stable point.
  // After this task the first valid output is present at the output ports.
  // =========================================================================
  task automatic do_reset();
    rst_n = 0;
    @(posedge clk); #1;  // hold reset through one posedge
    rst_n = 1;
    @(posedge clk); #1;  // first posedge after reset: DUT registers instruction 0
  endtask

  // =========================================================================
  // Main test
  // =========================================================================
  initial begin : tb_main

    // Defaults
    branch_redirect_valid  = 1'b0;
    branch_redirect_target = '0;
    ready                  = 1'b1;

    init_rom();

    // -----------------------------------------------------------------------
    // Test 1: Sequential fetch — all 8 instructions in order
    // -----------------------------------------------------------------------
    $display("=== Test 1: Sequential fetch ===");
    do_reset();

    // After do_reset, the DUT has registered instruction 0 into the output regs.
    // Each @(posedge clk); #1 advances to the next instruction.
    check_instr(VADDR'(0),  8'h00, 5'd0,  1'b1, "instr0_trap@0");
    @(posedge clk); #1;

    check_instr(VADDR'(1),  8'h33, 5'd2,  1'b1, "instr1_load_imm@1");
    @(posedge clk); #1;

    check_instr(VADDR'(4),  8'hC8, 5'd2,  1'b1, "instr2_add_64@4");
    @(posedge clk); #1;

    check_instr(VADDR'(7),  8'h28, 5'd4,  1'b1, "instr3_jump@7");
    @(posedge clk); #1;

    check_instr(VADDR'(12), 8'h14, 5'd9,  1'b1, "instr4_load_imm64@12");
    @(posedge clk); #1;

    check_instr(VADDR'(22), 8'h51, 5'd5,  1'b1, "instr5_branch_eq_imm@22");
    @(posedge clk); #1;

    check_instr(VADDR'(28), 8'h0A, 5'd4,  1'b1, "instr6_ecalli@28");
    @(posedge clk); #1;

    check_instr(VADDR'(33), 8'h00, 5'd0,  1'b1, "instr7_trap@33");

    // -----------------------------------------------------------------------
    // Test 2: Back-pressure — ready=0 stalls output
    // -----------------------------------------------------------------------
    $display("=== Test 2: Back-pressure ===");
    ready = 1'b0;
    do_reset();

    // After reset with ready=0: DUT registered instruction 0 (advance=1 since valid_q=0).
    // Now valid=1. Hold for 3 cycles and confirm output doesn't change.
    check_instr(VADDR'(0), 8'h00, 5'd0, 1'b1, "stall_cycle1");
    @(posedge clk); #1;
    check_instr(VADDR'(0), 8'h00, 5'd0, 1'b1, "stall_cycle2");
    @(posedge clk); #1;
    check_instr(VADDR'(0), 8'h00, 5'd0, 1'b1, "stall_cycle3");

    // Release back-pressure; next clock advances PC
    ready = 1'b1;
    @(posedge clk); #1;

    // From here: back to instruction 0 consumed, instruction 1 appears
    check_instr(VADDR'(1),  8'h33, 5'd2, 1'b1, "after_stall_load_imm@1");
    @(posedge clk); #1;

    check_instr(VADDR'(4),  8'hC8, 5'd2, 1'b1, "after_stall_add_64@4");
    @(posedge clk); #1;

    check_instr(VADDR'(7),  8'h28, 5'd4, 1'b1, "after_stall_jump@7");
    @(posedge clk); #1;

    check_instr(VADDR'(12), 8'h14, 5'd9, 1'b1, "after_stall_load_imm64@12");

    // -----------------------------------------------------------------------
    // Test 3: Branch redirect
    // -----------------------------------------------------------------------
    $display("=== Test 3: Branch redirect ===");
    ready = 1'b1;
    do_reset();

    // Fetch instructions 0 and 1
    @(posedge clk); #1;  // instr 0 consumed, instr 1 in output
    // Issue redirect to byte 7 (jump instruction) during cycle showing instr 1
    branch_redirect_valid  = 1'b1;
    branch_redirect_target = VADDR'(7);
    @(posedge clk); #1;  // redirect accepted; output invalidated
    branch_redirect_valid  = 1'b0;

    // valid_q=0 for one cycle; advance will re-load from redirect target
    @(posedge clk); #1;  // instruction at PC=7 now in output
    check_instr(VADDR'(7),  8'h28, 5'd4, 1'b1, "redirect_jump@7");
    @(posedge clk); #1;

    check_instr(VADDR'(12), 8'h14, 5'd9, 1'b1, "after_redirect_load_imm64@12");

    // -----------------------------------------------------------------------
    // Final report
    // -----------------------------------------------------------------------
    $display("");
    $display("=== pvm_frontend_tb RESULTS ===");
    $display("PASS: %0d", pass_cnt);
    $display("FAIL: %0d", fail_cnt);
    if (fail_cnt == 0)
      $display("ALL TESTS PASSED");
    else
      $display("SOME TESTS FAILED");
    $display("================================");

    $finish;
  end

  // =========================================================================
  // Timeout watchdog
  // =========================================================================
  initial begin
    #5000;
    $display("TIMEOUT: simulation exceeded 5000 ns");
    $finish;
  end

endmodule
