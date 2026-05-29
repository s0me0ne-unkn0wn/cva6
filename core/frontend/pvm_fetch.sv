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
      pc_q      <= '0;
      running_q <= 1'b0;
    end else if (start_i) begin
      // Fresh start loads entry_pc; a host-call resume keeps the suspended pc_q
      // (which already points at the instruction after the ecalli).
      if (!resume_i) pc_q <= entry_pc_i;
      running_q <= 1'b1;
    end else if (running_q && next_ready_i) begin
      // Unconditional jump: redirect to the decode-time target (overrides the
      // terminator-halt, since `jump` is itself a basic-block terminator).
      if (redirect_valid_i) pc_q <= redirect_pc_i;
      // Host-call (ecalli): advance to the next pc, then suspend so the M-mode
      // handler runs; on resume pvm_fetch continues from this saved next pc.
      else if (halt_i) begin pc_q <= next_pc_c; running_q <= 1'b0; end
      else if (terminator_c || (next_pc_c >= code_len_i)) running_q <= 1'b0;
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

endmodule
