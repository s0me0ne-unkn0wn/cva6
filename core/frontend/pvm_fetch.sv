// Copyright 2026 CVA6-PolkaVM contributors
// SPDX-License-Identifier: Apache-2.0
//
// PolkaVM JAM v1 fetch unit — skip/bitmask instruction-boundary walker.
//
// TEMPORARY LOCATION: this file's final home is core/frontend/pvm_fetch.sv.
// It lives in core/ during Stage 1 because core/frontend/ is not yet writable
// (uid-1000 permissions); it will be `git mv`d and wired into Flist.cva6 once
// `chown -R claude:claude` is applied. No functional dependency on the location.
//
// Reads PVM code bytes `c` and the opcode bitmask `k` (both resident in BRAM,
// supplied here as combinational windows) and walks the instruction-counter
// `i` per graypaper text/pvm.tex:
//   skip(i) = min(24, j : (k ++ [1,1,...])_{i+1+j} = 1)
//   next_i  = i + 1 + skip(i)
// Bitmask bit-order is LSB-FIRST: bit k of byte j == code byte 8*j+i, i.e. the
// window bit `bm_window_i[k]` is the bitmask for code position i+1+k. (The
// polkatool emit-image doc-comment says "MSB-first" — that is WRONG; verified
// against `polkatool disassemble`.) Positions at/after code_len are treated as
// set bits (the spec's bitmask "append-1s"), guaranteeing termination.
//
// This is a single-instruction-per-handshake walker; it does not itself decode
// operands (that is pvm_decoder, Stage 2). It exposes the 16-byte instruction
// window so the decoder can slice operands.

module pvm_fetch
  import polkavm_pkg::*;
#(
    parameter int unsigned VLEN = 32  // PVM instruction-counter width
) (
    input  logic            clk_i,
    input  logic            rst_ni,
    // control
    input  logic            start_i,      // pulse: (re)start at entry_pc_i
    input  logic            resume_i,     // at start: keep pc_q (resume after host-call) vs load entry_pc_i
    input  logic [VLEN-1:0] entry_pc_i,   // initial / redirect instruction-counter
    input  logic [VLEN-1:0] code_len_i,   // number of code bytes |c|
    input  logic            next_ready_i, // consumer accepts current instruction -> advance
    input  logic            halt_i,       // current instr is a host-call: advance to next pc, then suspend
    // conditional-branch resolution (stall-on-branch: suspend at the branch until
    // the backend branch_unit resolves it, then redirect taken/not-taken).
    input  logic            branch_i,     // current instr is a conditional branch
    input  logic            br_resolved_i,// backend resolved the pending branch (pulse)
    input  logic            br_taken_i,   // resolved outcome (1 = taken)
    // dynamic indirect jump (jump_ind): suspend, resolve a = reg+imm in the backend,
    // then djump (jump-table target / r0 halt magic).
    input  logic            djump_i,      // current instr is a dynamic jump
    input  logic [VLEN-1:0] br_target_i,  // backend-resolved address a (= reg_A + imm_X)
    input  logic [VLEN-1:0] djump_target_i,// jump-table target for a (computed by pvm_front)
    input  logic            djump_halt_i, // a is the r0 halt magic (2^32 - 2^16)
    output logic            djump_pending_o,// suspended at a dynamic jump (gates the jump-table read)
    // macro-expansion of imm-branches: a 2-uop instruction is held at the same pc
    // across phase 0 (decoder emits uop0) and phase 1 (uop1) before advancing.
    input  logic            two_uop_i,    // current instr expands to 2 uops (decoder)
    output logic            phase_o,      // current micro-op phase (0 or 1) for the decoder
    output logic            done_o,       // PVM run finished cleanly (djump-halt / off-the-end)
    // same-cycle front redirect for unconditional jumps (target known at decode)
    input  logic            redirect_valid_i,
    input  logic [VLEN-1:0] redirect_pc_i,
    // BRAM windows (combinational, addressed by pc_o):
    //   code_window_i : 16 code bytes starting at pc_o (byte 0 = opcode at pc_o)
    //   bm_window_i   : 32 bitmask bits starting at pc_o+1 (LSB = position pc_o+1)
    input  logic [127:0]    code_window_i,
    input  logic [31:0]     bm_window_i,
    // outputs
    output logic            valid_o,       // a valid instruction is presented
    output logic [VLEN-1:0] pc_o,          // current instruction-counter i
    output logic [VLEN-1:0] code_addr_o,   // = pc_o (drives the code/bitmask window read)
    output logic [7:0]      opcode_o,      // c[i]
    output logic [127:0]    instr_window_o,// 16 bytes c[i..i+15] for the decoder
    output logic [4:0]      skip_o,        // skip(i), 0..24
    output logic [VLEN-1:0] next_pc_o,     // i + 1 + skip(i)
    output logic            terminator_o   // c[i] in basic-block terminator set T
);

  logic [VLEN-1:0] pc_q;
  logic            running_q;
  logic            branch_pending_q;  // suspended at a conditional branch, awaiting resolution
  logic            djump_pending_q;   // suspended at a dynamic jump, awaiting resolution
  logic            done_q;            // PVM run terminated cleanly (djump-halt / off-the-end)
  logic            phase_q;           // micro-op phase for 2-uop (imm-branch) macro-expansion

  // ---- combinational skip encoder (LSB-first, append-1s past code_len) ------
  logic [4:0] skip_c;
  always_comb begin : p_skip_encoder
    logic [VLEN-1:0] pos;
    logic            bit_set;
    skip_c = 5'd24;  // spec cap min(24, .)
    // scan high->low so the lowest set position wins the final assignment
    for (int k = 24; k >= 0; k--) begin
      pos     = pc_q + VLEN'(1) + VLEN'(k);
      bit_set = (pos >= code_len_i) ? 1'b1 : bm_window_i[k];
      if (bit_set) skip_c = k[4:0];
    end
  end

  logic [7:0]      opcode_c;
  logic [VLEN-1:0] next_pc_c;
  logic            terminator_c;

  assign opcode_c     = code_window_i[7:0];
  assign next_pc_c    = pc_q + VLEN'(1) + VLEN'(skip_c);
  assign terminator_c = pvm_is_terminator(opcode_c);

  // ---- instruction-counter FSM ---------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_seq
    if (!rst_ni) begin
      pc_q             <= '0;
      running_q        <= 1'b0;
      branch_pending_q <= 1'b0;
      djump_pending_q  <= 1'b0;
      done_q           <= 1'b0;
      phase_q          <= 1'b0;
    end else if (start_i) begin
      // Fresh start loads entry_pc; a host-call resume keeps the suspended pc_q
      // (which already points at the instruction after the ecalli).
      if (!resume_i) pc_q <= entry_pc_i;
      running_q        <= 1'b1;
      branch_pending_q <= 1'b0;
      djump_pending_q  <= 1'b0;
      done_q           <= 1'b0;
      phase_q          <= 1'b0;
    end else if (branch_pending_q) begin
      // Suspended after a conditional branch: wait for the backend branch_unit to
      // resolve it, then redirect to the taken target (decode-time redirect_pc_i,
      // = pc+offset) or fall through to the sequential next pc. Reset the macro phase
      // (an imm-branch's phase-1 branch resolving here ends its 2-uop sequence).
      if (br_resolved_i) begin
        pc_q             <= br_taken_i ? redirect_pc_i : next_pc_c;
        running_q        <= 1'b1;
        branch_pending_q <= 1'b0;
        phase_q          <= 1'b0;
      end
    end else if (djump_pending_q) begin
      // Suspended at a dynamic jump: the backend gave a = reg_A + imm_X; pvm_front
      // turned it into either the r0 halt magic (clean termination) or a jump-table
      // target (continue there).
      if (br_resolved_i) begin
        djump_pending_q <= 1'b0;
        phase_q         <= 1'b0;  // end any 2-uop (load_imm_jump_ind) sequence
        if (djump_halt_i) done_q <= 1'b1;
        else begin pc_q <= djump_target_i; running_q <= 1'b1; end
      end
    end else if (running_q && next_ready_i) begin
      // Macro-expansion phase 0 (imm-branch): the load-scratch uop just issued; stay
      // at this pc and present phase 1 (the branch) next cycle.
      if (two_uop_i && !phase_q) phase_q <= 1'b1;
      // Unconditional jump: redirect to the decode-time target (overrides the
      // terminator-halt, since `jump` is itself a basic-block terminator).
      else if (redirect_valid_i) pc_q <= redirect_pc_i;
      // Conditional branch: suspend (no speculation) until the backend resolves it.
      else if (branch_i) begin running_q <= 1'b0; branch_pending_q <= 1'b1; end
      // Dynamic jump (jump_ind): suspend until the backend resolves a = reg+imm.
      else if (djump_i) begin running_q <= 1'b0; djump_pending_q <= 1'b1; end
      // Host-call (ecalli): advance to the next pc, then suspend so the M-mode
      // handler runs; on resume pvm_fetch continues from this saved next pc.
      else if (halt_i) begin pc_q <= next_pc_c; running_q <= 1'b0; end
      // trap (opcode 0) exits via its own exception uop; just stop fetching.
      else if (terminator_c) running_q <= 1'b0;
      // Off the end of the code with no explicit trap: clean halt -> synthetic trap.
      else if (next_pc_c >= code_len_i) begin running_q <= 1'b0; done_q <= 1'b1; end
      else pc_q <= next_pc_c;
    end
  end

  // ---- outputs --------------------------------------------------------------
  assign valid_o        = running_q;
  assign pc_o           = pc_q;
  assign code_addr_o    = pc_q;
  assign opcode_o       = opcode_c;
  assign instr_window_o = code_window_i;
  assign skip_o         = skip_c;
  assign next_pc_o      = next_pc_c;
  assign terminator_o   = terminator_c;
  assign done_o         = done_q;
  assign djump_pending_o = djump_pending_q;
  assign phase_o        = phase_q;

endmodule
