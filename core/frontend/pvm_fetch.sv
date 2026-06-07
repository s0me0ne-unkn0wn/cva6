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
    input  logic            jt_valid_i,   // jump-table read complete (djump_target_i ready)
    output logic            djump_pending_o,// suspended at a dynamic jump (gates the jump-table read)
    // macro-expansion of imm-branches: a 2-uop instruction is held at the same pc
    // across phase 0 (decoder emits uop0) and phase 1 (uop1) before advancing.
    input  logic            two_uop_i,    // current instr expands to 2 uops (decoder)
    output logic            phase_o,      // current micro-op phase (0 or 1) for the decoder
    output logic            done_o,       // PVM run finished cleanly (djump-halt / off-the-end)
    // same-cycle front redirect for unconditional jumps (target known at decode)
    input  logic            redirect_valid_i,
    input  logic [VLEN-1:0] redirect_pc_i,
    // return-from-handler (mret/sret): suspend at the eret like a conditional branch,
    // then on the backend's commit redirect the PVM-pc to mepc/sepc (the privilege
    // change is applied by the backend; pvm_active stays 1 -- mret is not an exception).
    input  logic            eret_i,           // current instr is mret/sret
    input  logic            eret_resolved_i,  // backend committed the eret (1-cycle pulse)
    input  logic [VLEN-1:0] eret_pc_i,        // committed mepc/sepc as a PVM instruction-counter
    input  logic            eret_via_jt_i,    // Stage 1: this committed eret's mepc is a JT-encoded code
                                              // address (M->S handoff), NOT a PVM-pc -> map it via the JT
    // guest-internal trap (ecalli@priv<M): the backend delivered a trap to the guest's
    // mtvec/stvec while STAYING in PVM. pvm_fetch is halt-suspended at the ecalli; on this
    // commit pulse it redirects to the guest trap vector (no host involvement).
    input  logic            trap_redirect_i,  // backend committed a stay-in-PVM trap (1-cycle pulse)
    input  logic [VLEN-1:0] trap_pc_i,        // committed guest mtvec/stvec as a PVM instruction-counter
    // CSR fence (B5): a guest write to a flush-class CSR (mstatus/sstatus/satp/mstatush) raises
    // flush_o in csr_regfile, which would discard the YOUNGER in-flight PVM uop (e.g. a following
    // mret). The CSR write DOES execute, so -- like halt_i -- we advance pc to next_pc and suspend;
    // unlike halt_i we resume on the commit flush (csr_fence_resolved_i), not a host resume. The CSR
    // write then commits ALONE and its flush is harmless (identical safety argument to the eret).
    input  logic            csr_fence_i,          // current instr is a flush-class CSR write
    input  logic            csr_fence_resolved_i, // the CSR write committed/flushed (1-cycle pulse)
    // store_imm serialization: a store_imm is a 2-uop macro (phase0: scratch GPR = value; phase1:
    // STORE [base+off] = scratch). pvm_fetch does not drain between macros, so two store_imm whose
    // store-phases overlap make the younger store read a STALE scratch GPR and store the older
    // store's data (RVFI-confirmed). Suspend after phase1 like csr_fence; resume when the store has
    // drained (storeimm_resolved_i = no store pending), so the scratch read can never cross macros.
    input  logic            store_imm_i,          // current instr is a store_imm 2-uop macro
    input  logic            storeimm_resolved_i,  // the store_imm's store has committed/drained (level)
    // BRAM windows (combinational, addressed by pc_o):
    //   code_window_i : 16 code bytes starting at pc_o (byte 0 = opcode at pc_o)
    //   bm_window_i   : 32 bitmask bits starting at pc_o+1 (LSB = position pc_o+1)
    input  logic [127:0]    code_window_i,
    input  logic [31:0]     bm_window_i,
    input  logic            window_valid_i,// code/bitmask window for pc_o is loaded (BRAM read-FSM)
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

  // ILA debug (non-perturbing observability for the FPGA-only OpenSBI demand-fetch hang):
  // mark_debug the instruction-counter + the full suspend/resume FSM state so a Vivado ILA can
  // see WHETHER the PVM-pc is advancing and, if not, WHICH pending flag is stuck (a fetch-stall
  // vs a never-resolved branch/djump/eret/csr-fence/store-imm). Pure attribute -- does NOT change
  // the synthesized PVM instruction stream/layout (unlike code markers), so it does not move the bug.
  (* mark_debug = "true" *) logic [VLEN-1:0] pc_q;
  (* mark_debug = "true" *) logic            running_q;
  (* mark_debug = "true" *) logic            branch_pending_q;  // suspended at a conditional branch, awaiting resolution
  (* mark_debug = "true" *) logic            djump_pending_q;   // suspended at a dynamic jump, awaiting resolution
  (* mark_debug = "true" *) logic            eret_pending_q;    // suspended at an mret/sret, awaiting the backend commit
  (* mark_debug = "true" *) logic            csr_fence_pending_q;// B5: suspended at a flush-class CSR write, awaiting the commit flush
  (* mark_debug = "true" *) logic            storeimm_pending_q; // suspended after a store_imm macro, awaiting the store to drain
  (* mark_debug = "true" *) logic            done_q;            // PVM run terminated cleanly (djump-halt / off-the-end)
  (* mark_debug = "true" *) logic            phase_q;           // micro-op phase for 2-uop (imm-branch) macro-expansion

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
      eret_pending_q   <= 1'b0;
      csr_fence_pending_q <= 1'b0;
      storeimm_pending_q  <= 1'b0;
      done_q           <= 1'b0;
      phase_q          <= 1'b0;
    end else if (start_i) begin
      // Fresh start loads entry_pc; a host-call resume keeps the suspended pc_q
      // (which already points at the instruction after the ecalli).
      if (!resume_i) pc_q <= entry_pc_i;
      running_q        <= 1'b1;
      branch_pending_q <= 1'b0;
      djump_pending_q  <= 1'b0;
      eret_pending_q   <= 1'b0;
      csr_fence_pending_q <= 1'b0;
      storeimm_pending_q  <= 1'b0;
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
      // target (continue there). Wait for the BRAM jump-table read (jt_valid_i): with
      // a real BRAM, djump_target_i is produced a few cycles after the backend resolves
      // a, not combinationally -- so resolve on jt_valid_i, not br_resolved_i.
      if (jt_valid_i) begin
        djump_pending_q <= 1'b0;
        phase_q         <= 1'b0;  // end any 2-uop (load_imm_jump_ind) sequence
        if (djump_halt_i) done_q <= 1'b1;
        else begin pc_q <= djump_target_i; running_q <= 1'b1; end
      end
    end else if (eret_pending_q) begin
      // Suspended at an mret/sret: wait for the backend to COMMIT it (eret_resolved_i),
      // then resume PVM fetch at the committed mepc/sepc (the privilege change is applied
      // by the backend at the same commit). We stall until commit -- not redirect at
      // issue -- so the post-handler code never runs at the pre-mret privilege.
      if (eret_resolved_i) begin
        eret_pending_q <= 1'b0;
        phase_q        <= 1'b0;
        if (eret_via_jt_i) begin
          // Stage 1: mepc holds a JT-encoded code address (the M->S handoff target), not a
          // PVM-pc. Route it through the jump table like a djump: enter djump_pending and wait
          // for the JT read (pvm_front captures djump_a = eret_pc_i on eret_via_jt_i), then the
          // djump_pending arm sets pc_q <= djump_target_i. Stay suspended (running_q=0) meanwhile.
          djump_pending_q <= 1'b1;
        end else begin
          pc_q           <= eret_pc_i;   // normal eret: mepc is already a PVM-pc (trap round-trip)
          running_q      <= 1'b1;
        end
      end
    end else if (csr_fence_pending_q) begin
      // B5: suspended at a flush-class CSR write (pc_q already advanced to next_pc when we
      // suspended -- the CSR op executes). Wait for it to commit; its flush fires on commit
      // (csr_fence_resolved_i = pvm_active & csr_regfile flush, gated in cva6.sv). The write
      // commits ALONE (nothing younger was issued -- we suspended issue), so the flush is
      // harmless. Just un-suspend; pc_q is already at the next instruction.
      if (csr_fence_resolved_i) begin
        running_q           <= 1'b1;
        csr_fence_pending_q <= 1'b0;
        phase_q             <= 1'b0;
      end
    end else if (storeimm_pending_q) begin
      // Suspended after a store_imm 2-uop macro (pc_q already advanced to next_pc; the macro's
      // store executes). Wait for the store to commit/drain (storeimm_resolved_i = no store
      // pending while pvm_active, gated in cva6.sv). Resuming only after the store drains means
      // the NEXT 2-uop macro's phase-0 scratch write cannot overlap this store's scratch read --
      // so the operand forwarding never crosses macros (the back-to-back store_imm data-stale
      // bug). The store committed ALONE (issue was suspended), so this is otherwise transparent.
      if (storeimm_resolved_i) begin
        running_q          <= 1'b1;
        storeimm_pending_q <= 1'b0;
        phase_q            <= 1'b0;
      end
    end else if (trap_redirect_i) begin
      // Guest-internal trap (ecalli@priv<M): pvm_fetch was halt-suspended at the ecalli
      // (running_q=0, post-ecalli pc held). The backend delivered the trap to the guest
      // mtvec/stvec and STAYED in PVM; redirect fetch there and resume. Exclusive with
      // start_i (a stay-trap involves no host resume) and the branch/djump/eret arms.
      pc_q             <= trap_pc_i;
      running_q        <= 1'b1;
      branch_pending_q <= 1'b0;
      djump_pending_q  <= 1'b0;
      eret_pending_q   <= 1'b0;
      phase_q          <= 1'b0;
    end else if (running_q && next_ready_i && window_valid_i) begin
      // Macro-expansion phase 0 (imm-branch): the load-scratch uop just issued; stay
      // at this pc and present phase 1 (the branch) next cycle.
      if (two_uop_i && !phase_q) phase_q <= 1'b1;
      // store_imm phase 1 (the STORE) just issued: advance pc to next_pc, then SUSPEND until the
      // store drains (storeimm_pending). This serializes back-to-back store_imm so the next
      // macro's phase-0 scratch write cannot overlap this store's scratch read -> no cross-macro
      // forwarding (the data-stale bug). Placed before the generic pc-advance; mutually exclusive
      // with branch/djump/eret/csr-fence (a store is fu=STORE) and only fires on phase 1 (phase 0
      // took the arm above), so the store is in flight when we suspend. next_pc like halt_i/B5.
      else if (store_imm_i && phase_q) begin pc_q <= next_pc_c; running_q <= 1'b0; storeimm_pending_q <= 1'b1; phase_q <= 1'b0; end
      // Unconditional jump: redirect to the decode-time target (overrides the
      // terminator-halt, since `jump` is itself a basic-block terminator).
      else if (redirect_valid_i) pc_q <= redirect_pc_i;
      // Conditional branch: suspend (no speculation) until the backend resolves it.
      else if (branch_i) begin running_q <= 1'b0; branch_pending_q <= 1'b1; end
      // Dynamic jump (jump_ind): suspend until the backend resolves a = reg+imm.
      else if (djump_i) begin running_q <= 1'b0; djump_pending_q <= 1'b1; end
      // Return-from-handler (mret/sret): suspend until the backend commits it, then
      // redirect to mepc/sepc. Not a terminator, so without this it would fall through
      // to the sequential next pc -- wrong (must resume at the handler return target).
      else if (eret_i) begin running_q <= 1'b0; eret_pending_q <= 1'b1; end
      // CSR fence (B5): a flush-class CSR write (mstatus/sstatus/satp/mstatush). The write
      // EXECUTES (so advance to next_pc like halt_i), then suspend; resume on the commit
      // flush (csr_fence_resolved_i). Mutually exclusive with branch/djump/eret/halt above
      // (a CSR write is fu=CSR, never a branch/djump/eret/hostcall) and with terminator (CSR
      // opcodes are not in T), so its order in this chain is safe.
      else if (csr_fence_i) begin pc_q <= next_pc_c; running_q <= 1'b0; csr_fence_pending_q <= 1'b1; end
      // Host-call (ecalli): advance to the next pc, then suspend so the M-mode
      // handler runs; on resume pvm_fetch continues from this saved next pc.
      else if (halt_i) begin pc_q <= next_pc_c; running_q <= 1'b0; end
      // trap (opcode 0) exits via its own exception uop; just stop fetching. NOTE: of the
      // terminator set T only TRAP halts fetch here -- jumps/branches/djumps are handled by
      // the redirect/branch_i/djump_i arms above, and FALLTHROUGH (the bare basic-block
      // separator, opcode 1) is NOT a control-flow stop: execution continues sequentially to
      // next_pc. (Treating fallthrough as a hard stop hung any continuous block-to-block run,
      // e.g. OpenSBI _start crossing its first basic-block boundary -- B7.)
      else if (opcode_c == PVM_OP_TRAP) running_q <= 1'b0;
      // Off the end of the code with no explicit trap: clean halt -> synthetic trap.
      else if (next_pc_c >= code_len_i) begin running_q <= 1'b0; done_q <= 1'b1; end
      else pc_q <= next_pc_c;
    end
  end

  // ---- outputs --------------------------------------------------------------
  assign valid_o        = running_q & window_valid_i;
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
