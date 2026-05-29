// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// PolkaVM front-half wrapper (Stage 3): composes the JAM-image memory, control,
// pvm_fetch (skip/bitmask walker) and pvm_decoder into a single unit that emits
// a stream of decoded micro-ops (raw ariane_pkg fields) with an ack handshake.
// cva6.sv assembles a scoreboard_entry_t from these raw fields (where that type
// is in scope) and muxes the stream into the issue stage when PVM mode is active.
//
// Increment 1: straight-line execution + trap/host-call exit (no taken-branch
// redirect yet — that is increment 2, wiring resolved_branch back to pvm_fetch).
//
// Image memory: a behavioral byte array holding the emit-image payload (code at
// `code_base_i`, LSB-first bitmask at `bitmask_base_i`). Written by the M-mode
// loader via the img_we/img_addr/img_wdata port; read combinationally by fetch.
// (FPGA synthesis will replace this with a real dual-port BRAM — a later step.)

module pvm_front
  import ariane_pkg::*;
  import polkavm_pkg::*;
#(
    parameter int unsigned VLEN      = 32,
    parameter int unsigned IMG_BYTES = 4096
) (
    input  logic            clk_i,
    input  logic            rst_ni,
    // control (from the M-mode loader / control CSR)
    input  logic            pvm_active_i,    // level: 1 = run PVM mode
    input  logic            resume_i,        // on (re)activation: continue at the post-host-call
                                             // pc (suspended in pvm_fetch) instead of entry_pc_i
    input  logic [VLEN-1:0] entry_pc_i,      // instruction-counter to start at
    input  logic [VLEN-1:0] code_len_i,      // |c| in bytes
    input  logic [VLEN-1:0] code_base_i,     // byte offset of code in image mem
    input  logic [VLEN-1:0] bitmask_base_i,  // byte offset of bitmask in image mem
    input  logic [VLEN-1:0] jumptable_base_i,// byte offset of the dynamic jump table
    input  logic [3:0]      jumptable_z_i,   // jump-table entry size in bytes (E1(z), 1..8)
    // image memory write port (loader)
    input  logic            img_we_i,
    input  logic [VLEN-1:0] img_addr_i,
    input  logic [7:0]      img_wdata_i,
    // downstream issue handshake
    input  logic            issue_ack_i,     // consumer accepted current uop -> advance
    // control-flow resolution feedback from the backend branch_unit
    input  logic            br_resolved_i,   // a PVM branch/jump resolved this cycle (pulse)
    input  logic            br_taken_i,      // resolved conditional-branch outcome (1 = taken)
    input  logic [VLEN-1:0] br_target_i,     // resolved address (cond: unused; djump: a=reg+imm)
    // decoded micro-op (raw; scoreboard_entry_t assembled by cva6.sv)
    output logic            valid_o,
    output logic [VLEN-1:0] pc_o,
    output fu_t             fu_o,
    output fu_op            op_o,
    output logic [4:0]      rd_o,
    output logic [4:0]      rs1_o,
    output logic [4:0]      rs2_o,
    output logic [63:0]     imm_o,
    output logic            use_imm_o,
    output logic            is_branch_o,
    output logic            is_jump_o,
    output logic [VLEN-1:0] branch_target_o,
    output logic            is_hostcall_o,
    output logic [63:0]     hostcall_id_o,
    output logic            is_trap_o,
    output logic            illegal_o,
    output logic            unsupported_o,
    output logic            halted_o,        // PVM run finished (terminator/!valid)
    output logic            done_o           // PVM terminated cleanly (djump-halt / off-the-end)
);

  // ---- image memory --------------------------------------------------------
  localparam int unsigned IMG_AW = $clog2(IMG_BYTES);
  logic [7:0] img_mem [0:IMG_BYTES-1];
  always_ff @(posedge clk_i) begin
    if (img_we_i && img_addr_i < VLEN'(IMG_BYTES)) img_mem[img_addr_i[IMG_AW-1:0]] <= img_wdata_i;
  end
`ifndef SYNTHESIS
  // Simulation-only image preload: `+PVM_IMG=<hexfile>` loads the emit-image
  // bytes (one hex byte per line) into img_mem. FPGA uses the img write port /
  // a real loader path instead (guarded out of synthesis).
  initial begin : p_img_preload
    string pvm_img_file;
    if ($value$plusargs("PVM_IMG=%s", pvm_img_file)) begin
      $display("[pvm_front] preloading PVM image from '%s'", pvm_img_file);
      $readmemh(pvm_img_file, img_mem);
    end
  end
`endif

  // ---- start-pulse on entering PVM mode ------------------------------------
  logic pvm_active_q;
  logic start_pulse;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pvm_active_q <= 1'b0;
    else         pvm_active_q <= pvm_active_i;
  end
  assign start_pulse = pvm_active_i & ~pvm_active_q;

  // ---- fetch <-> image windows (combinational reads addressed by pc) -------
  logic [VLEN-1:0] f_code_addr;
  logic [127:0]    code_window;
  logic [31:0]     bm_window;
  always_comb begin : p_windows
    logic [VLEN-1:0] caddr, pos, bytei;
    code_window = '0;
    bm_window   = '0;
    caddr = '0;
    pos   = '0;
    bytei = '0;
    for (int b = 0; b < 16; b++) begin
      caddr = code_base_i + f_code_addr + VLEN'(b);
      if ((f_code_addr + VLEN'(b) < code_len_i) && (caddr < VLEN'(IMG_BYTES)))
        code_window[b*8+:8] = img_mem[caddr[IMG_AW-1:0]];
    end
    for (int k = 0; k < 32; k++) begin
      pos = f_code_addr + VLEN'(1) + VLEN'(k);
      if (pos >= code_len_i) begin
        bm_window[k] = 1'b1;                       // append-1s past code
      end else begin
        bytei = bitmask_base_i + (pos >> 3);
        bm_window[k] = (bytei < VLEN'(IMG_BYTES)) ? img_mem[bytei[IMG_AW-1:0]][pos[2:0]] : 1'b1;
      end
    end
  end

  // ---- fetch ----------------------------------------------------------------
  logic            f_valid, f_term, f_done, f_is_djump;
  logic [VLEN-1:0] f_pc, f_next_pc;
  logic [7:0]      f_opcode;
  logic [127:0]    f_window;
  logic [4:0]      f_skip;

  // ---- dynamic-jump (djump) decode: a = br_target_i (= reg_A + imm_X) ---------
  // r0 halt magic = 2^32 - 2^16; otherwise target = j[a/Z - 1], Z = 2 (eq.
  // jumptablealignment). Panic checks (a even, in range, target is a BB start) are
  // omitted for the trusted-bootloader MVP, like gas metering (decision D3).
  localparam logic [31:0] DJUMP_HALT = 32'hFFFF0000;
  logic            djump_halt_c;
  logic [VLEN-1:0] djump_index, djump_entry, djump_target_c;
  always_comb begin : p_djump
    logic [VLEN-1:0] ea;
    djump_halt_c   = (br_target_i[31:0] == DJUMP_HALT);
    djump_index    = (br_target_i >> 1) - VLEN'(1);                 // a/Z - 1
    djump_entry    = jumptable_base_i + djump_index * VLEN'(jumptable_z_i);
    djump_target_c = '0;
    ea             = '0;
    for (int e = 0; e < 8; e++) begin
      ea = djump_entry + VLEN'(e);
      if ((e < int'(jumptable_z_i)) && (ea < VLEN'(IMG_BYTES)))
        djump_target_c[e*8+:8] = img_mem[ea[IMG_AW-1:0]];
    end
  end

  pvm_fetch #(.VLEN(VLEN)) i_fetch (
      .clk_i, .rst_ni,
      .start_i       (start_pulse),
      .resume_i      (resume_i),          // keep suspended pc (post host-call) on restart
      .entry_pc_i    (entry_pc_i),
      .code_len_i    (code_len_i),
      .next_ready_i  (issue_ack_i),
      .halt_i        (is_hostcall_o),     // ecalli: advance to next pc, then suspend for M-mode
      .branch_i      (is_branch_o),       // conditional branch: suspend until backend resolves
      .br_resolved_i (br_resolved_i),
      .br_taken_i    (br_taken_i),
      .djump_i       (f_is_djump),        // jump_ind: suspend, resolve a, then djump
      .br_target_i   (br_target_i),
      .djump_target_i(djump_target_c),
      .djump_halt_i  (djump_halt_c),
      .done_o        (f_done),
      .redirect_valid_i(is_jump_o),       // unconditional jump -> front redirect
      .redirect_pc_i   (branch_target_o),
      .code_window_i (code_window),
      .bm_window_i   (bm_window),
      .valid_o       (f_valid),
      .pc_o          (f_pc),
      .code_addr_o   (f_code_addr),
      .opcode_o      (f_opcode),
      .instr_window_o(f_window),
      .skip_o        (f_skip),
      .next_pc_o     (f_next_pc),
      .terminator_o  (f_term)
  );

  // ---- decode ---------------------------------------------------------------
  pvm_decoder #(.VLEN(VLEN)) i_dec (
      .opcode_i       (f_opcode),
      .instr_window_i (f_window),
      .pc_i           (f_pc),
      .skip_i         (f_skip),
      .fu_o           (fu_o),
      .op_o           (op_o),
      .rd_o           (rd_o),
      .rs1_o          (rs1_o),
      .rs2_o          (rs2_o),
      .imm_o          (imm_o),
      .use_imm_o      (use_imm_o),
      .is_branch_o    (is_branch_o),
      .is_jump_o      (is_jump_o),
      .is_djump_o     (f_is_djump),
      .branch_target_o(branch_target_o),
      .is_hostcall_o  (is_hostcall_o),
      .hostcall_id_o  (hostcall_id_o),
      .is_trap_o      (is_trap_o),
      .illegal_o      (illegal_o),
      .unsupported_o  (unsupported_o)
  );

  assign pc_o     = f_pc;
  // On a clean termination (f_done) present one synthetic uop; cva6 turns it into a
  // trap exception so the M-mode loader regains control (the guest had no `trap`).
  assign valid_o  = pvm_active_i & (f_valid | f_done);
  assign done_o   = pvm_active_i & f_done;
  assign halted_o = pvm_active_i & ~f_valid & ~f_done;

endmodule
