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

// M1: the PolkaVM image is RUNTIME-LOADED -- the M-mode bootrom writes img_mem via the
// CSR_PVM_IMG load port (so JAM code can be copied in from DRAM), and simulation can also
// preload via `+PVM_IMG`. The old `ifdef SYNTHESIS -> baked constant ROM is left below
// as dead code under a never-defined macro (PVM_USE_BAKED_IMG) for reference only.

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
  // M2: image storage is a true BRAM (128-bit words) so a RUNTIME-loaded JAM image
  // ROUTES on FPGA. The old writable byte-array read by a 16-byte combinational window
  // was unroutable (congestion lvl 6); the baked constant ROM only worked because
  // constant reads fold into a LUT-ROM. Byte-enable write port = the M1 load
  // (CSR_PVM_IMG streams one byte at a time); one registered read port feeds the fetch
  // read-FSM (p_fetch_read) below, which reconstructs the code/bitmask windows.
  localparam int unsigned NW  = (IMG_BYTES + 15) / 16;        // number of 128-bit words
  localparam int unsigned WAW = (NW <= 1) ? 1 : $clog2(NW);   // word-address width
  // Flat 128-bit words + ram_style="block": a [15:0][7:0] packed array is read as a
  // "RAM from Record/Structs" by Vivado and falls back to 32768 registers (-> congestion);
  // a flat vector with a byte part-select write infers a byte-write-enabled block RAM.
  (* ram_style = "block" *) logic [127:0] img_bram [0:NW-1];  // 16 bytes/word
  always_ff @(posedge clk_i) begin : p_img_write
    if (img_we_i && img_addr_i < VLEN'(IMG_BYTES))
      img_bram[img_addr_i[IMG_AW-1:4]][img_addr_i[3:0]*8 +: 8] <= img_wdata_i;  // byte write
  end
  logic [WAW-1:0] bram_raddr;
  logic [127:0]   bram_rdata_q;
  always_ff @(posedge clk_i) bram_rdata_q <= img_bram[bram_raddr];
`ifndef SYNTHESIS
  // Simulation preload: +PVM_IMG hex (one byte/line), packed into the BRAM words.
  initial begin : p_img_preload
    string pvm_img_file;
    logic [7:0] img_bytes [0:IMG_BYTES-1];
    if ($value$plusargs("PVM_IMG=%s", pvm_img_file)) begin
      for (int b = 0; b < IMG_BYTES; b++) img_bytes[b] = 8'h00;
      $readmemh(pvm_img_file, img_bytes);
      for (int w = 0; w < NW; w++)
        for (int b = 0; b < 16; b++) img_bram[w][b*8 +: 8] = img_bytes[w*16 + b];
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

  // ---- fetch windows: driven by the BRAM read-FSM (p_fetch_read, below) ----------
  logic [VLEN-1:0] f_code_addr;     // current PVM pc (from pvm_fetch)
  logic [127:0]    code_window;     // c[i..i+15], registered (assembled from BRAM)
  logic [31:0]     bm_window;       // bitmask bits [i+1..i+32], registered
  logic            window_valid;    // the window for f_code_addr is loaded

  // ---- fetch ----------------------------------------------------------------
  logic            f_valid, f_term, f_done, f_is_djump, f_djump_pending, f_phase, f_two_uop;
  logic [VLEN-1:0] f_pc, f_next_pc;
  logic [7:0]      f_opcode;
  logic [127:0]    f_window;
  logic [4:0]      f_skip;

  // ==== BRAM fetch read-FSM ===================================================
  // Reconstructs the code window (c[i..i+15]) and bitmask window (bits [i+1..i+32])
  // from registered 128-bit BRAM reads, plus the djump jump-table entry. Replaces the
  // old combinational p_windows/p_djump (a multi-port img_mem read that was unroutable
  // on FPGA -- congestion lvl 6). One read port, multi-cycle; the latency is absorbed
  // (the backend accepts PVM uops slower than the refill). djump (rare) reuses the FSM
  // while suspended. window_valid / jt_valid gate the consumer (pvm_fetch).
  localparam logic [31:0] DJUMP_HALT = 32'hFFFF0000;

  logic [127:0]    word0_q, word1_q, bm0_q, bm1_q, jt0_q, jt1_q;  // read holding regs
  logic [VLEN-1:0] rd_addr_q, loaded_addr_q;
  logic [3:0]      fsm_step_q;
  logic            window_valid_q;
  logic [127:0]    window_code_q;
  logic [31:0]     window_bm_q;
  logic [VLEN-1:0] djump_a_q, djump_target_q;
  logic            djump_halt_q, jt_valid_q, jt_req_q;

  // word addresses for the refill target (rd_addr_q) and the djump entry
  logic [VLEN-1:0] CA, p1v, BB, JE;
  always_comb begin
    CA   = code_base_i + rd_addr_q;
    p1v  = rd_addr_q + VLEN'(1);
    BB   = bitmask_base_i + (p1v >> 3);
    JE   = jumptable_base_i + (((djump_a_q >> 1) - VLEN'(1)) * VLEN'(jumptable_z_i));
  end

  always_comb begin                                     // BRAM read addr by FSM step
    case (fsm_step_q)
      4'd1:    bram_raddr = CA[WAW-1+4:4];
      4'd2:    bram_raddr = CA[WAW-1+4:4] + 1'b1;
      4'd3:    bram_raddr = BB[WAW-1+4:4];
      4'd4:    bram_raddr = BB[WAW-1+4:4] + 1'b1;
      4'd9:    bram_raddr = JE[WAW-1+4:4];
      4'd10:   bram_raddr = JE[WAW-1+4:4] + 1'b1;
      default: bram_raddr = CA[WAW-1+4:4];
    endcase
  end

  logic [255:0]    code256, bm256, jt256, code_sh256, bm_sh256, jt_sh256;
  logic [7:0]      code_sh, bm_sh, jt_sh;
  logic [127:0]    code_asm;
  logic [31:0]     bm_asm;
  logic [VLEN-1:0] djtgt_asm;
  always_comb begin                                     // window/target assembly
    code256    = {word1_q, word0_q};
    bm256      = {bm1_q, bm0_q};
    jt256      = {jt1_q, jt0_q};
    code_sh    = {CA[3:0], 3'b0};                        // (CA & 15) * 8
    bm_sh      = {BB[3:0], 3'b0} + {5'b0, p1v[2:0]};     // (BB&15)*8 + (i+1)&7
    jt_sh      = {JE[3:0], 3'b0};                        // (JE & 15) * 8
    code_sh256 = code256 >> code_sh;
    bm_sh256   = bm256   >> bm_sh;
    jt_sh256   = jt256   >> jt_sh;
    code_asm   = code_sh256[127:0];
    for (int b = 0; b < 16; b++)
      if (rd_addr_q + VLEN'(b) >= code_len_i) code_asm[b*8 +: 8] = 8'h00;
    bm_asm     = bm_sh256[31:0];
    for (int k = 0; k < 32; k++)
      if (rd_addr_q + VLEN'(1) + VLEN'(k) >= code_len_i) bm_asm[k] = 1'b1;
    djtgt_asm  = jt_sh256[VLEN-1:0];
    for (int e = 0; e < 8; e++)                          // keep only z bytes (rest = 0)
      if (e >= int'(jumptable_z_i)) djtgt_asm[e*8 +: 8] = 8'h00;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fetch_read
    if (!rst_ni) begin
      fsm_step_q <= 4'd0; loaded_addr_q <= {VLEN{1'b1}}; window_valid_q <= 1'b0;
      jt_valid_q <= 1'b0; jt_req_q <= 1'b0; djump_halt_q <= 1'b0;
    end else if (start_pulse) begin
      loaded_addr_q <= {VLEN{1'b1}}; window_valid_q <= 1'b0; fsm_step_q <= 4'd0;
      jt_valid_q <= 1'b0; jt_req_q <= 1'b0;
    end else begin
      // capture a djump resolution (a = br_target_i) while suspended at the djump
      if (f_djump_pending && br_resolved_i && !jt_req_q && !jt_valid_q) begin
        djump_a_q    <= br_target_i;
        djump_halt_q <= (br_target_i[31:0] == DJUMP_HALT);
        jt_req_q     <= 1'b1;
      end
      if (!f_djump_pending) begin jt_valid_q <= 1'b0; jt_req_q <= 1'b0; end

      case (fsm_step_q)
        4'd0: begin                                      // idle: pick the next job
          if (f_code_addr != loaded_addr_q) begin        // code/bitmask window refill
            rd_addr_q <= f_code_addr; window_valid_q <= 1'b0; fsm_step_q <= 4'd1;
          end else if (jt_req_q && !jt_valid_q && djump_halt_q) begin
            jt_valid_q <= 1'b1;                           // r0 halt magic: no read needed
          end else if (jt_req_q && !jt_valid_q) begin
            fsm_step_q <= 4'd9;                           // jump-table read
          end
        end
        4'd1: fsm_step_q <= 4'd2;                         // raddr=W0 issued
        4'd2: begin word0_q <= bram_rdata_q; fsm_step_q <= 4'd3; end
        4'd3: begin word1_q <= bram_rdata_q; fsm_step_q <= 4'd4; end
        4'd4: begin bm0_q   <= bram_rdata_q; fsm_step_q <= 4'd5; end
        4'd5: begin bm1_q   <= bram_rdata_q; fsm_step_q <= 4'd6; end
        4'd6: begin                                       // assemble + present
          window_code_q  <= code_asm; window_bm_q <= bm_asm;
          window_valid_q <= 1'b1; loaded_addr_q <= rd_addr_q; fsm_step_q <= 4'd0;
        end
        4'd9:  fsm_step_q <= 4'd10;                        // raddr=JT0 issued
        4'd10: begin jt0_q <= bram_rdata_q; fsm_step_q <= 4'd11; end
        4'd11: begin                                      // zero the hi jump-table word if
          jt1_q <= (((JE >> 4) + VLEN'(1)) >= VLEN'(NW))   // it would wrap past the image
                   ? 128'd0 : bram_rdata_q;                // (unmasked path; code/bm are masked)
          fsm_step_q <= 4'd12;
        end
        4'd12: begin djump_target_q <= djtgt_asm; jt_valid_q <= 1'b1; fsm_step_q <= 4'd0; end
        default: fsm_step_q <= 4'd0;
      endcase
    end
  end

  assign code_window  = window_code_q;
  assign bm_window    = window_bm_q;
  assign window_valid = window_valid_q && (loaded_addr_q == f_code_addr);

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
      .djump_target_i(djump_target_q),
      .djump_halt_i  (djump_halt_q),
      .jt_valid_i    (jt_valid_q),        // jump-table read done (BRAM read-FSM)
      .djump_pending_o(f_djump_pending),
      .two_uop_i     (f_two_uop),
      .phase_o       (f_phase),
      .done_o        (f_done),
      .redirect_valid_i(is_jump_o),       // unconditional jump -> front redirect
      .redirect_pc_i   (branch_target_o),
      .code_window_i (code_window),
      .bm_window_i   (bm_window),
      .window_valid_i(window_valid),      // window for pc_o is loaded (BRAM read-FSM)
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
      .phase_i        (f_phase),
      .two_uop_o      (f_two_uop),
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
