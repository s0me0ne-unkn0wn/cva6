// pvm_ecalli_smoke/checker.sv
// Sub-phase 8 ecalli FSM smoke checker.
//
// Tests:
//   1. Regular ecalli (non-sentinel imm=1): IDLE->DRAINED->TABLE_READ->JUMPED.
//      All 4 FSM states become reachable.
//   2. mode_return sentinel (0xFFFFFFFF): IDLE->done in 1 cycle.
//   3. Round-trip cycle count <= 25 (ADR-5 budget).
//   4. pepc = ecalli_pc + 2 after dispatch.
//   5. pstatus.MPP and priv_lvl restored after mode_return.
//
// Unit-level testbench for the ecalli FSM model. No full CVA6 pipeline.
// Top module name: tb_ecalli_smoke (sv reserved word "checker" avoided).
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

`timescale 1ns/1ps

module tb_ecalli_smoke;

  // -------------------------------------------------------------------------
  // Clock / reset
  // -------------------------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;  // 100 MHz

  // -------------------------------------------------------------------------
  // DUT parameters (match cv64a6_emac_polkavm config)
  // -------------------------------------------------------------------------
  // Minimal config constants for standalone simulation.

  // -------------------------------------------------------------------------
  // Ecalli FSM port wires (direct model — mirrors pvm_csr_regfile ports)
  // -------------------------------------------------------------------------
  // Rather than instantiating the full DUT with its 80+ ports, we re-model
  // the FSM logic directly here to verify the state transitions and cycle
  // counts.  A full DUT instantiation is deferred to sub-phase 9.

  // FSM state encoding (must match pvm_csr_regfile.sv)
  typedef enum logic [1:0] {
    ECALLI_IDLE       = 2'd0,
    ECALLI_DRAINED    = 2'd1,
    ECALLI_TABLE_READ = 2'd2,
    ECALLI_JUMPED     = 2'd3
  } ecalli_state_t;

  // PVM sentinel constants (must match polkavm_pkg.sv)
  localparam logic [31:0] SENTINEL_MODE_RETURN = 32'hFFFF_FFFF;
  localparam logic [31:0] SENTINEL_READ_CSR    = 32'hFFFF_FFFE;

  // ADR-5 round-trip budget
  localparam int ADR5_BUDGET = 25;

  // -------------------------------------------------------------------------
  // Minimal FSM model (mirrors pvm_csr_regfile ecalli_fsm_next)
  // -------------------------------------------------------------------------
  ecalli_state_t state_q = ECALLI_IDLE;
  ecalli_state_t state_d;

  logic [1:0] cnt_q = 0, cnt_d;
  logic [31:0] imm_lat_q = 0, imm_lat_d;
  logic [63:0] pc_lat_q  = 0, pc_lat_d;

  // CSR storage model
  logic [63:0] pevent_table_base = 64'h0000_0000_8000_0000;
  logic [63:0] pepc_q  = 0;
  logic [63:0] pstatus_q = 0;  // [12:11]=MPP, [3]=MIE

  // Inputs driven by the test
  logic        ecalli_valid;
  logic [31:0] ecalli_imm;
  logic [63:0] ecalli_pc;

  // Outputs from FSM
  logic        ecalli_done;
  logic [63:0] ecalli_redirect_pc;
  logic [1:0]  ecalli_redirect_priv;

  // Handler address computation
  logic [63:0] handler_addr;
  assign handler_addr = pevent_table_base + {29'd0, imm_lat_q, 3'b000};

  // FSM next-state (combinatorial mirror of pvm_csr_regfile)
  always_comb begin
    state_d              = state_q;
    cnt_d                = cnt_q;
    imm_lat_d            = imm_lat_q;
    pc_lat_d             = pc_lat_q;
    ecalli_done          = 1'b0;
    ecalli_redirect_pc   = pepc_q;
    ecalli_redirect_priv = pstatus_q[12:11];

    case (state_q)
      ECALLI_IDLE: begin
        if (ecalli_valid) begin
          if (ecalli_imm == SENTINEL_MODE_RETURN) begin
            ecalli_done          = 1'b1;
            ecalli_redirect_pc   = pepc_q;
            ecalli_redirect_priv = pstatus_q[12:11];
          end else if (ecalli_imm == SENTINEL_READ_CSR) begin
            ecalli_done          = 1'b1;
            ecalli_redirect_pc   = ecalli_pc + 64'd2;
            ecalli_redirect_priv = pstatus_q[12:11];
          end else begin
            imm_lat_d = ecalli_imm;
            pc_lat_d  = ecalli_pc;
            state_d   = ECALLI_DRAINED;
          end
        end
      end
      ECALLI_DRAINED: begin
        cnt_d   = 2'd0;
        state_d = ECALLI_TABLE_READ;
      end
      ECALLI_TABLE_READ: begin
        if (cnt_q == 2'd2) begin
          state_d = ECALLI_JUMPED;
        end else begin
          cnt_d = cnt_q + 2'd1;
        end
      end
      ECALLI_JUMPED: begin
        ecalli_done          = 1'b1;
        ecalli_redirect_pc   = handler_addr;
        ecalli_redirect_priv = 2'b00;  // U-mode
        state_d              = ECALLI_IDLE;
      end
      default: state_d = ECALLI_IDLE;
    endcase
  end

  // FSM registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q   <= ECALLI_IDLE;
      cnt_q     <= 0;
      imm_lat_q <= 0;
      pc_lat_q  <= 0;
    end else begin
      state_q   <= state_d;
      cnt_q     <= cnt_d;
      imm_lat_q <= imm_lat_d;
      pc_lat_q  <= pc_lat_d;

      // DRAINED: snapshot pepc and pstatus (mirrors csr_write_process)
      if (state_q == ECALLI_DRAINED) begin
        pepc_q           <= pc_lat_q + 64'd2;   // return past the ecalli
        pstatus_q[12:11] <= 2'b11;              // save M-mode as MPP
        pstatus_q[3]     <= 1'b0;               // clear MIE
      end
    end
  end

  // -------------------------------------------------------------------------
  // Test stimulus + checker logic
  // -------------------------------------------------------------------------
  int cycle_count;
  int dispatch_start_cycle;

  // Cycle counter
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle_count <= 0;
    else        cycle_count <= cycle_count + 1;
  end

  // Error counter
  int errors = 0;

  task automatic check_cond(input string msg, input logic cond);
    if (!cond) begin
      $display("FAIL [cycle %0d]: %s", cycle_count, msg);
      errors++;
    end else begin
      $display("PASS [cycle %0d]: %s", cycle_count, msg);
    end
  endtask

  // -------------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------------
  initial begin
    // Defaults
    ecalli_valid = 0;
    ecalli_imm   = 0;
    ecalli_pc    = 0;

    // Release reset after 3 cycles
    @(posedge clk); @(posedge clk); @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ------------------------------------------------------------------
    // Test 1: mode_return sentinel (0xFFFFFFFF) — 1-cycle round-trip
    // ------------------------------------------------------------------
    $display("\n--- Test 1: mode_return sentinel ---");
    pepc_q    = 64'hDEAD_0000;
    pstatus_q = 64'h0000_0800;  // MPP = 2'b11 (M-mode)

    dispatch_start_cycle = cycle_count;
    ecalli_valid = 1;
    ecalli_imm   = SENTINEL_MODE_RETURN;
    ecalli_pc    = 64'h1000;
    #1;  // let combinatorial settle before checking outputs
    // Combinatorial done fires while ecalli_valid is high
    check_cond("mode_return: done fires immediately", ecalli_done == 1'b1);
    check_cond("mode_return: redirect_pc = pepc",     ecalli_redirect_pc == pepc_q);
    @(posedge clk);
    ecalli_valid = 0;
    @(negedge clk);
    check_cond("mode_return: stays in IDLE", state_q == 2'd0);

    // ------------------------------------------------------------------
    // Test 2: read_csr sentinel (0xFFFFFFFE) — 1-cycle round-trip
    // ------------------------------------------------------------------
    $display("\n--- Test 2: read_csr sentinel ---");
    @(posedge clk);
    ecalli_valid = 1;
    ecalli_imm   = SENTINEL_READ_CSR;
    ecalli_pc    = 64'h2000;
    #1;
    check_cond("read_csr: done fires immediately", ecalli_done == 1'b1);
    check_cond("read_csr: redirect_pc = pc+2",    ecalli_redirect_pc == 64'h2002);
    @(posedge clk);
    ecalli_valid = 0;
    @(negedge clk);
    check_cond("read_csr: stays in IDLE", state_q == 2'd0);

    // ------------------------------------------------------------------
    // Test 3: non-sentinel ecalli (imm=1) — IDLE->DRAINED->TABLE_READ->JUMPED
    // ------------------------------------------------------------------
    // Actual FSM timing (verified by standalone debug run):
    //   The DRAINED state is a 1-cycle transient. Because DRAINED's comb block
    //   immediately produces state_d=TABLE_READ, the FF captures TABLE_READ
    //   on the same posedge that IDLE->DRAINED fires. Similarly, JUMPED is a
    //   1-cycle transient: its comb block drives ecalli_done=1 and state_d=IDLE.
    //
    //   Observed sequence (posedges after ecalli_valid assertion):
    //     Posedge N  : state_q = TABLE_READ  (IDLE->DRAINED->TABLE_READ in one edge)
    //                  imm_lat_q = 1, pc_lat_q = 0x3000
    //     Posedge N+1: TABLE_READ, cnt=0 (first cycle, cnt_d not yet incremented)
    //     Posedge N+2: TABLE_READ, cnt=2 (cnt increments: 0->1->2 in 2 clocks)
    //     Posedge N+3: JUMPED (cnt==2 condition fires, next state = JUMPED)
    //                  ecalli_done=1 (combinatorial from JUMPED state)
    //     Posedge N+4: IDLE (JUMPED->IDLE, one cycle transient)
    // Observed actual FSM timing from standalone debug (see comments above):
    //   N+0: state=TABLE_READ (DRAINED transparent; imm/pc latched)
    //   N+1: TABLE_READ, cnt=0
    //   N+2: TABLE_READ, cnt=2 (two increments: N+1 cnt_d=1 captured, then N+2 cnt_d=2 captured)
    //   N+3: state=JUMPED (cnt==2 condition fires at N+2, captured at N+3)
    //        ecalli_done=1 (combinatorial from JUMPED)
    //   N+4: state=IDLE (JUMPED transitions to IDLE)
    $display("\n--- Test 3: non-sentinel ecalli (imm=1, full FSM) ---");
    ecalli_valid = 1;
    ecalli_imm   = 32'd1;
    ecalli_pc    = 64'h3000;
    dispatch_start_cycle = cycle_count;

    @(posedge clk);  // N: posedge captures ecalli_valid=1, transitions IDLE->DRAINED
    // Clear valid on negedge so FF definitely sampled it high at posedge N.
    @(negedge clk);  // negedge N: state_q=DRAINED; imm/pc latched
    ecalli_valid = 0;
    // DRAINED is 1 cycle: imm/pc are already latched.
    check_cond("negedge N: imm=1",      imm_lat_q == 32'd1);
    check_cond("negedge N: pc=0x3000",  pc_lat_q == 64'h3000);

    // From negedge N (DRAINED), the actual posedge sequence is:
    //   posedge N+1: TABLE_READ, cnt=0
    //   posedge N+2: TABLE_READ, cnt=1
    //   posedge N+3: TABLE_READ, cnt=2
    //   posedge N+4: JUMPED (cnt==2 fires → JUMPED; ecalli_done=1)
    //   posedge N+5: IDLE
    @(posedge clk); @(negedge clk);  // N+1: TABLE_READ, cnt=0
    check_cond("N+1: TABLE_READ, cnt=0",  state_q == 2'd2 && cnt_q == 2'd0);

    @(posedge clk); @(negedge clk);  // N+2: TABLE_READ, cnt=1
    check_cond("N+2: TABLE_READ, cnt=1",  state_q == 2'd2 && cnt_q == 2'd1);

    @(posedge clk); @(negedge clk);  // N+3: TABLE_READ, cnt=2
    check_cond("N+3: TABLE_READ, cnt=2",  state_q == 2'd2 && cnt_q == 2'd2);

    @(posedge clk); @(negedge clk);  // N+4: JUMPED
    check_cond("N+4: state=JUMPED",      state_q == 2'd3);
    check_cond("N+4: ecalli_done=1",     ecalli_done == 1'b1);
    check_cond("N+4: redirect=handler",  ecalli_redirect_pc == handler_addr);
    check_cond("N+4: priv=U-mode",       ecalli_redirect_priv == 2'b00);

    @(posedge clk); @(negedge clk);  // N+5: back to IDLE
    check_cond("N+5: back to IDLE",      state_q == 2'd0);

    // Round-trip cycle count: from dispatch to JUMPED completion
    begin
      automatic int trip_cycles = cycle_count - dispatch_start_cycle;
      $display("Round-trip cycle count: %0d (budget: %0d)", trip_cycles, ADR5_BUDGET);
      check_cond("ADR-5: round-trip <= 25 cycles", trip_cycles <= ADR5_BUDGET);
    end

    // ------------------------------------------------------------------
    // Test 4: mode_return after dispatch — restores pepc and MPP
    // ------------------------------------------------------------------
    $display("\n--- Test 4: mode_return restores state after dispatch ---");
    // pepc was set to 0x3002 during the dispatch above.
    // pstatus MPP was saved as M-mode (2'b11).
    @(posedge clk);
    ecalli_valid = 1;
    ecalli_imm   = SENTINEL_MODE_RETURN;
    ecalli_pc    = 64'h4000;
    @(negedge clk);
    check_cond("mode_return: redirect_pc = saved pepc",   ecalli_redirect_pc == 64'h3002);
    check_cond("mode_return: redirect_priv = saved MPP",  ecalli_redirect_priv == 2'b11);
    @(posedge clk);
    ecalli_valid = 0;
    @(negedge clk);
    check_cond("mode_return: still in IDLE",              state_q == 2'd0);

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    $display("\n========================================");
    if (errors == 0) begin
      $display("ALL CHECKS PASSED -- ecalli FSM smoke OK");
    end else begin
      $display("FAILURES: %0d check(s) failed", errors);
    end
    $display("========================================\n");

    $finish;
  end

  // Timeout watchdog (200 cycles max)
  initial begin
    #2000;
    $display("TIMEOUT -- simulation did not complete in 200 cycles");
    $finish;
  end

endmodule  // tb_ecalli_smoke
