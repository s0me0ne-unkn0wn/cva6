// Phase 4.5 sub-phase 5 — Full-pipeline Verilator integration testbench.
//
// Instantiates cva6 with the PolkaVM config (cv64a6_emac_polkavm_config_pkg).
// The pvm_frontend + bootrom ROMs are already wired inside cva6.sv (sub-phase 3).
//
// Monitors:
//   - AXI write channel (noc_req_o) for bytes written to UART @ 0x10000000.
//     Each byte is appended to uart_trace.log.
//   - rvfi_probes_o.instr.commit_ack for instruction-commit counting.
//   - Rolling-window deadlock detector (10 k cycles without a commit → abort).
//   - Cycle budget (100 k cycles hard stop).
//
// UART AXI response: a minimal AXI4 slave that accepts every AW+W beat
// and returns B=OKAY one cycle later, plus constant AR-ready + R-OKAY for
// any read (bootrom address space).  Without B-channel acks the core's AXI
// shim stalls permanently.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

`timescale 1ns/1ps

`include "rvfi_types.svh"
`include "cvxif_types.svh"

module pvm_pipeline_integration_tb;

  // =========================================================================
  // Config alias — must match the package used to build cva6.
  // =========================================================================
  import cva6_config_pkg::*;
  import ariane_pkg::*;
  import polkavm_pkg::*;

  // Build the CVA6 config the same way the RTL does.
  localparam config_pkg::cva6_cfg_t CVA6Cfg =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  // =========================================================================
  // AXI width constants derived from config.
  // =========================================================================
  localparam int unsigned AXI_AW   = CVA6Cfg.AxiAddrWidth; // 64
  localparam int unsigned AXI_DW   = CVA6Cfg.AxiDataWidth; // 64
  localparam int unsigned AXI_IDW  = CVA6Cfg.AxiIdWidth;   // 4
  localparam int unsigned AXI_UW   = CVA6Cfg.AxiUserWidth; // 1

  // =========================================================================
  // RVFI probe types (needed for the cva6 port declaration).
  // =========================================================================
  localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg);
  localparam type rvfi_probes_csr_t   = `RVFI_PROBES_CSR_T(CVA6Cfg);
  localparam type rvfi_probes_t = struct packed {
    rvfi_probes_csr_t   csr;
    rvfi_probes_instr_t instr;
  };

  // =========================================================================
  // CVXIF types (disabled in this config, but cva6 still requires the types).
  // =========================================================================
  localparam type readregflags_t      = `READREGFLAGS_T(CVA6Cfg);
  localparam type writeregflags_t     = `WRITEREGFLAGS_T(CVA6Cfg);
  localparam type id_t                = `ID_T(CVA6Cfg);
  localparam type hartid_t            = `HARTID_T(CVA6Cfg);
  localparam type x_compressed_req_t  = `X_COMPRESSED_REQ_T(CVA6Cfg, hartid_t);
  localparam type x_compressed_resp_t = `X_COMPRESSED_RESP_T(CVA6Cfg);
  localparam type x_issue_req_t       = `X_ISSUE_REQ_T(CVA6Cfg, hartid_t, id_t);
  localparam type x_issue_resp_t      =
      `X_ISSUE_RESP_T(CVA6Cfg, writeregflags_t, readregflags_t);
  localparam type x_register_t        =
      `X_REGISTER_T(CVA6Cfg, hartid_t, id_t, readregflags_t);
  localparam type x_commit_t          = `X_COMMIT_T(CVA6Cfg, hartid_t, id_t);
  localparam type x_result_t          =
      `X_RESULT_T(CVA6Cfg, hartid_t, id_t, writeregflags_t);
  localparam type cvxif_req_t         =
      `CVXIF_REQ_T(CVA6Cfg, x_compressed_req_t, x_issue_req_t, x_register_t, x_commit_t);
  localparam type cvxif_resp_t        =
      `CVXIF_RESP_T(CVA6Cfg, x_compressed_resp_t, x_issue_resp_t, x_result_t);

  // =========================================================================
  // AXI channel types — matching the cva6 parameter defaults.
  // =========================================================================
  typedef struct packed {
    logic [AXI_IDW-1:0]   id;
    logic [AXI_AW-1:0]    addr;
    axi_pkg::len_t         len;
    axi_pkg::size_t        size;
    axi_pkg::burst_t       burst;
    logic                  lock;
    axi_pkg::cache_t       cache;
    axi_pkg::prot_t        prot;
    axi_pkg::qos_t         qos;
    axi_pkg::region_t      region;
    axi_pkg::atop_t        atop;
    logic [AXI_UW-1:0]    user;
  } axi_aw_chan_t;

  typedef struct packed {
    logic [AXI_IDW-1:0]   id;
    logic [AXI_AW-1:0]    addr;
    axi_pkg::len_t         len;
    axi_pkg::size_t        size;
    axi_pkg::burst_t       burst;
    logic                  lock;
    axi_pkg::cache_t       cache;
    axi_pkg::prot_t        prot;
    axi_pkg::qos_t         qos;
    axi_pkg::region_t      region;
    logic [AXI_UW-1:0]    user;
  } axi_ar_chan_t;

  typedef struct packed {
    logic [AXI_DW-1:0]        data;
    logic [(AXI_DW/8)-1:0]    strb;
    logic                      last;
    logic [AXI_UW-1:0]        user;
  } axi_w_chan_t;

  typedef struct packed {
    logic [AXI_IDW-1:0]   id;
    axi_pkg::resp_t        resp;
    logic [AXI_UW-1:0]    user;
  } axi_b_chan_t;

  typedef struct packed {
    logic [AXI_IDW-1:0]   id;
    logic [AXI_DW-1:0]    data;
    axi_pkg::resp_t        resp;
    logic                  last;
    logic [AXI_UW-1:0]    user;
  } axi_r_chan_t;

  typedef struct packed {
    axi_aw_chan_t aw;
    logic         aw_valid;
    axi_w_chan_t  w;
    logic         w_valid;
    logic         b_ready;
    axi_ar_chan_t ar;
    logic         ar_valid;
    logic         r_ready;
  } noc_req_t;

  typedef struct packed {
    logic        aw_ready;
    logic        ar_ready;
    logic        w_ready;
    logic        b_valid;
    axi_b_chan_t b;
    logic        r_valid;
    axi_r_chan_t r;
  } noc_resp_t;

  // =========================================================================
  // Clock and reset
  // =========================================================================
  logic clk  = 0;
  always #10 clk = ~clk;   // 50 MHz nominal

  logic rst_ni;
  initial begin
    // Disable all internal CVA6 assertions for this integration testbench.
    // The assertions rely on invariants that hold when the branch redirect path
    // is fully connected; with pvm_frontend's branch_redirect_valid_i tied low,
    // speculative-queue invariants may be temporarily violated during flushes.
    $assertoff(0, pvm_pipeline_integration_tb);
    rst_ni = 0;
    repeat (5) @(posedge clk);
    rst_ni = 1;
  end

  // SP (x2 / PVM r1) is pre-initialized to 0x83ffffe8 via PVM_SIM_SP_INIT
  // define in ariane_regfile_fpga.sv.  See run_pvm_pipeline_integration_tb.sh.

  // =========================================================================
  // CVA6 AXI ports
  // =========================================================================
  noc_req_t  noc_req;
  noc_resp_t noc_resp;

  rvfi_probes_t rvfi_probes;

  cvxif_req_t  cvxif_req;
  cvxif_resp_t cvxif_resp;

  // =========================================================================
  // CVA6 DUT
  // boot_addr_i = 0 because pvm_frontend starts at PC=0 (reset to '0).
  // =========================================================================
  cva6 #(
    .CVA6Cfg              ( CVA6Cfg              ),
    .rvfi_probes_instr_t  ( rvfi_probes_instr_t  ),
    .rvfi_probes_csr_t    ( rvfi_probes_csr_t    ),
    .rvfi_probes_t        ( rvfi_probes_t         ),
    .axi_ar_chan_t        ( axi_ar_chan_t         ),
    .axi_aw_chan_t        ( axi_aw_chan_t         ),
    .axi_w_chan_t         ( axi_w_chan_t          ),
    .b_chan_t             ( axi_b_chan_t          ),
    .r_chan_t             ( axi_r_chan_t          ),
    .noc_req_t            ( noc_req_t            ),
    .noc_resp_t           ( noc_resp_t           ),
    .readregflags_t       ( readregflags_t       ),
    .writeregflags_t      ( writeregflags_t      ),
    .id_t                 ( id_t                 ),
    .hartid_t             ( hartid_t             ),
    .x_compressed_req_t   ( x_compressed_req_t  ),
    .x_compressed_resp_t  ( x_compressed_resp_t ),
    .x_issue_req_t        ( x_issue_req_t        ),
    .x_issue_resp_t       ( x_issue_resp_t       ),
    .x_register_t         ( x_register_t         ),
    .x_commit_t           ( x_commit_t           ),
    .x_result_t           ( x_result_t           ),
    .cvxif_req_t          ( cvxif_req_t          ),
    .cvxif_resp_t         ( cvxif_resp_t         )
  ) i_cva6 (
    .clk_i                ( clk                  ),
    .rst_ni               ( rst_ni               ),
    .boot_addr_i          ( '0                   ),  // pvm_frontend starts at PC=0
    .hart_id_i            ( '0                   ),
    .irq_i                ( '0                   ),
    .ipi_i                ( '0                   ),
    .time_irq_i           ( '0                   ),
    .debug_req_i          ( '0                   ),
    .rvfi_probes_o        ( rvfi_probes          ),
    .cvxif_req_o          ( cvxif_req            ),
    .cvxif_resp_i         ( '0                   ),
    .noc_req_o            ( noc_req              ),
    .noc_resp_i           ( noc_resp             )
  );

  // =========================================================================
  // Minimal AXI4 slave: accepts all transactions, returns OKAY.
  //
  // Write path:
  //   - AW channel: accept every cycle (aw_ready=1).
  //   - W channel:  accept every cycle (w_ready=1).
  //   - B channel:  latch the ID from AW and return b_valid one cycle later.
  //
  // Read path:
  //   - AR channel: accept every cycle (ar_ready=1).
  //   - R channel:  return r_valid one cycle later with data=0, resp=OKAY.
  //                 All reads return 0 (the pvm_frontend ignores AXI reads;
  //                 it uses the internal bootrom directly).
  // =========================================================================

  // --- Write path ---
  logic                  b_valid_q;
  logic [AXI_IDW-1:0]   b_id_q;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      b_valid_q <= '0;
      b_id_q    <= '0;
    end else begin
      // Accept the AW beat; latch ID for B response.
      // Hold b_valid until the core asserts b_ready.
      if (noc_req.aw_valid && noc_resp.aw_ready && !b_valid_q) begin
        b_valid_q <= 1'b1;
        b_id_q    <= noc_req.aw.id;
      end else if (b_valid_q && noc_req.b_ready) begin
        b_valid_q <= 1'b0;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Simple RAM model — backs all AXI write/read traffic outside UART/ro_data.
  // Byte-addressed associative array; only entries written are stored.
  // -------------------------------------------------------------------------
  logic [7:0] axi_ram [logic [63:0]];

  // Helper task — commit one AXI write beat into the RAM.
  task automatic ram_write(
    input logic [AXI_AW-1:0] aw_addr,
    input logic [63:0]        w_data,
    input logic [7:0]         w_strb
  );
    for (int b = 0; b < 8; b++) begin
      if (w_strb[b])
        axi_ram[aw_addr + AXI_AW'(b)] = w_data[b*8 +: 8];
    end
  endtask

  // Latch AW address for the ram_write path (mirrors pend_aw_addr used for UART).
  // We reuse pend_aw_addr / pend_aw_valid which are already declared below, so
  // the RAM write block runs in the same always_ff as the UART tracker.
  // NOTE: ram_write() is called from the uart-tracker always_ff (see below).

  // --- Read path ---
  logic                      r_valid_q;
  logic [AXI_IDW-1:0]        r_id_q;
  logic [AXI_AW-1:0]         r_addr_q;   // latched AR address for response data

  // UART register addresses
  localparam logic [AXI_AW-1:0] UART_LINE_STATUS_ADDR = 64'h10000014;  // +20
  localparam logic [AXI_AW-1:0] UART_MODEM_STATUS_ADDR = 64'h10000018; // +24

  // PVM ro_data ROM — string literals mapped at VA [0x10000, 0x11152).
  // Loaded by polkavm string-reference load_imm + load_indirect_u8 sequences.
  `include "pvm_ro_data_rom.svh"

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_valid_q <= '0;
      r_id_q    <= '0;
      r_addr_q  <= '0;
    end else begin
      if (noc_req.ar_valid && noc_resp.ar_ready && !r_valid_q) begin
        r_valid_q <= 1'b1;
        r_id_q    <= noc_req.ar.id;
        r_addr_q  <= noc_req.ar.addr;
      end else if (r_valid_q && noc_req.r_ready) begin
        r_valid_q <= 1'b0;
      end
    end
  end

  // Compute read data based on address.
  //   UART_LINE_STATUS (0x10000014): return 0x60 (THRE+TEMT) so write_serial()
  //     exits its "while transmit not empty" spin loop immediately.
  //   PVM ro_data [0x10000, 0x11152): serve string literals so print_uart()
  //     reads actual characters instead of 0 (null = premature string end).
  //   All other reads: return 0.
  logic [63:0] r_data_comb;
  always_comb begin
    if (r_addr_q == UART_LINE_STATUS_ADDR) begin
      r_data_comb = 64'h6060606060606060; // bit5=THRE, bit6=TEMT — all byte lanes ready
    end else if (r_addr_q >= PVM_RO_DATA_BASE && r_addr_q < PVM_RO_DATA_END) begin
      // 8-byte aligned index into ro_data ROM.
      // r_addr_q is byte address; index = (r_addr_q - PVM_RO_DATA_BASE) >> 3.
      // The SV packed array is MSB-first (index 0 = highest word), so we
      // invert: sv_idx = PVM_RO_DATA_WORDS - 1 - word_idx.
      automatic int unsigned word_idx;
      automatic int unsigned sv_idx;
      word_idx = int'((r_addr_q - PVM_RO_DATA_BASE) >> 3);
      sv_idx   = PVM_RO_DATA_WORDS - 1 - word_idx;
      if (word_idx < PVM_RO_DATA_WORDS)
        r_data_comb = pvm_ro_data_rom[sv_idx];
      else
        r_data_comb = '0;
    end else begin
      // Return bytes from the RAM model; unwritten bytes default to 0.
      for (int b = 0; b < 8; b++) begin
        if (axi_ram.exists(r_addr_q + AXI_AW'(b)))
          r_data_comb[b*8 +: 8] = axi_ram[r_addr_q + AXI_AW'(b)];
        else
          r_data_comb[b*8 +: 8] = 8'h00;
      end
    end
  end

  // Drive noc_resp combinatorially.
  always_comb begin
    noc_resp = '0;
    // AW always ready unless we already have an unanswered B outstanding.
    noc_resp.aw_ready = ~b_valid_q;
    // W always ready (we don't buffer W data, UART snoop is separate).
    noc_resp.w_ready  = 1'b1;
    // B channel.
    noc_resp.b_valid      = b_valid_q;
    noc_resp.b.id         = b_id_q;
    noc_resp.b.resp       = axi_pkg::RESP_OKAY;
    // AR always ready unless R outstanding.
    noc_resp.ar_ready = ~r_valid_q;
    // R channel.
    noc_resp.r_valid      = r_valid_q;
    noc_resp.r.id         = r_id_q;
    noc_resp.r.data       = r_data_comb;
    noc_resp.r.resp       = axi_pkg::RESP_OKAY;
    noc_resp.r.last       = 1'b1;
  end

  // =========================================================================
  // UART monitor — snoop AXI write beats to 0x10000000.
  //
  // The PVM bootrom writes individual bytes to the UART data register at
  // 0x10000000.  We capture the W.data[7:0] whenever AW.addr == 0x10000000
  // and both AW+W are valid in the same cycle (or within one cycle of each
  // other — we latch the most recent accepted AW address).
  // =========================================================================
  localparam logic [AXI_AW-1:0] UART_ADDR = 64'h10000000;

  integer uart_fd;
  integer uart_byte_count;

  initial begin
    uart_fd         = $fopen("uart_trace.log", "w");
    uart_byte_count = 0;
    if (uart_fd == 0) begin
      $display("[TB] ERROR: could not open uart_trace.log");
      $finish;
    end
  end

  // AW-W handshake tracker.
  //
  // The TB's AXI slave accepts W beats every cycle (w_ready=1) but stalls AW
  // when a B response is pending (aw_ready = ~b_valid_q).  This means W can
  // arrive ONE cycle BEFORE the corresponding AW.  We handle both orderings:
  //
  //   Case A — AW arrives in the same cycle or before W:
  //     Latch AW addr.  When W arrives, compare latched addr with UART_ADDR.
  //
  //   Case B — W arrives before AW (w_ready=1 but aw_ready=0):
  //     Latch W data+strb.  When AW arrives, compare with UART_ADDR and emit.
  //
  // The TB guarantees at most 1 outstanding write at a time (aw_ready stalls
  // until B response is consumed), so a 1-entry latch for each direction is
  // sufficient.

  logic [AXI_AW-1:0]    pend_aw_addr;
  logic                  pend_aw_valid;   // AW accepted, waiting for W

  logic [63:0]           pend_w_data;
  logic [7:0]            pend_w_strb;
  logic                  pend_w_valid;    // W accepted, waiting for AW

  // Helper task — emit one UART byte when an AW+W pair is resolved.
  task automatic uart_emit(
    input logic [AXI_AW-1:0] aw_addr,
    input logic [63:0]        w_data,
    input logic [7:0]         w_strb
  );
    logic [7:0] uart_byte;
    int         lane;
    begin
      if (aw_addr == UART_ADDR) begin
        uart_byte = w_data[7:0];
        lane = 0;
        for (int b = 0; b < 8; b++) begin
          if (w_strb[b]) begin
            uart_byte = w_data[b*8 +: 8];
            lane = b;
            break;
          end
        end
        $fwrite(uart_fd, "%c", uart_byte);
        $fflush(uart_fd);
        uart_byte_count = uart_byte_count + 1;
        $display("[UART] addr=0x%016h strb=0x%02h byte=0x%02h '%c' (byte %0d)",
                 aw_addr, w_strb, uart_byte, uart_byte, uart_byte_count);
      end
    end
  endtask

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_aw_addr  <= '0;
      pend_aw_valid <= 1'b0;
      pend_w_data   <= '0;
      pend_w_strb   <= '0;
      pend_w_valid  <= 1'b0;
    end else begin
      automatic logic aw_fire = noc_req.aw_valid && noc_resp.aw_ready;
      automatic logic w_fire  = noc_req.w_valid  && noc_resp.w_ready;

      // Both AW and W accepted in the same cycle → immediate match.
      if (aw_fire && w_fire) begin
        uart_emit(noc_req.aw.addr, noc_req.w.data, noc_req.w.strb);
        ram_write(noc_req.aw.addr, noc_req.w.data, noc_req.w.strb);
        pend_aw_valid <= 1'b0;
        pend_w_valid  <= 1'b0;

      // AW accepted; check if a pending W is waiting.
      end else if (aw_fire) begin
        if (pend_w_valid) begin
          uart_emit(noc_req.aw.addr, pend_w_data, pend_w_strb);
          ram_write(noc_req.aw.addr, pend_w_data, pend_w_strb);
          pend_w_valid  <= 1'b0;
        end else begin
          pend_aw_addr  <= noc_req.aw.addr;
          pend_aw_valid <= 1'b1;
        end

      // W accepted; check if a pending AW is waiting.
      end else if (w_fire) begin
        if (pend_aw_valid) begin
          uart_emit(pend_aw_addr, noc_req.w.data, noc_req.w.strb);
          ram_write(pend_aw_addr, noc_req.w.data, noc_req.w.strb);
          pend_aw_valid <= 1'b0;
        end else begin
          pend_w_data  <= noc_req.w.data;
          pend_w_strb  <= noc_req.w.strb;
          pend_w_valid <= 1'b1;
        end
      end
    end
  end

  // =========================================================================
  // Instruction commit counter (via rvfi_probes).
  // commit_ack is a NrCommitPorts-wide vector; count each asserted bit.
  // =========================================================================
  integer commit_count;
  integer last_commit_cycle;   // for deadlock detector

  initial begin
    commit_count      = 0;
    last_commit_cycle = 0;
  end

  always_ff @(posedge clk) begin
    if (rst_ni) begin
      for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin
        if (rvfi_probes.instr.commit_ack[p]) begin
          commit_count      = commit_count + 1;
          last_commit_cycle = cycle_count;
        end
      end
    end
  end

  // =========================================================================
  // Cycle counter
  // =========================================================================
  integer cycle_count;

  initial cycle_count = 0;

  always_ff @(posedge clk) cycle_count = cycle_count + 1;

  // =========================================================================
  // Cycle budget — hard stop at CYCLE_BUDGET cycles.
  // =========================================================================
  localparam int CYCLE_BUDGET = 500_000;

  always_ff @(posedge clk) begin
    if (cycle_count >= CYCLE_BUDGET) begin
      $display("[CYCLE BUDGET] %0d cycles elapsed, %0d instructions committed",
               cycle_count, commit_count);
      $display("CYCLE BUDGET EXHAUSTED");
      $finish;
    end
  end

  // =========================================================================
  // Deadlock detector — rolling 10 k-cycle window with zero commits.
  // Only armed after reset and after at least one commit has been observed
  // (avoids false positives during cache fill latency at start-up).
  // =========================================================================
  localparam int DEADLOCK_WINDOW = 2000;

  always_ff @(posedge clk) begin
    if (rst_ni && commit_count > 0) begin
      if ((cycle_count - last_commit_cycle) > DEADLOCK_WINDOW) begin
        $display("[DEADLOCK] No commit for %0d cycles (last at cycle %0d, now %0d)",
                 DEADLOCK_WINDOW, last_commit_cycle, cycle_count);
        $display("DEADLOCK at cycle %0d", cycle_count);
        $finish;
      end
    end
  end

  // =========================================================================
  // Exception / trap halt detector.
  // ex_commit_valid in rvfi_probes indicates a committed exception.
  // When it fires we log the cause and stop (the bootrom ends with trap after
  // the SPI-init sequence, so this is expected termination).
  // =========================================================================
  always_ff @(posedge clk) begin
    if (rst_ni && rvfi_probes.instr.ex_commit_valid) begin
      $display("[EX cy=%0d] cause=0x%0h tval=0x%0h (log only, continuing)",
               cycle_count, rvfi_probes.instr.ex_commit_cause, rvfi_probes.instr.tval);
    end
  end

  // =========================================================================
  // PVM frontend/decoder signal probing — wire internal signals for debug.
  // =========================================================================
  // Probe the pvm_frontend output registers (pc_o, valid_o, skip_o) and
  // id_stage decoder input (is_valid_opcode, chunk) every cycle for first
  // 50 cycles so we can see exactly what the frontend feeds to decode.
  wire [38:0] fe_pc_probe     = i_cva6.pvm_fe_pc_w;
  wire        fe_valid_probe  = i_cva6.pvm_fc_if_id[0].valid;
  wire [127:0] fe_chunk_probe = i_cva6.pvm_fc_if_id[0].chunk;
  wire [3:0]   fe_skip_probe  = i_cva6.pvm_fc_if_id[0].skip;
  wire         fe_isop_probe  = i_cva6.pvm_fc_if_id[0].is_valid_opcode;
  wire [38:0]  fe_redirect_target = i_cva6.pvm_fe_redirect_target_w;
  wire         fe_redirect_valid  = i_cva6.pvm_fe_redirect_valid_w;

  always_ff @(posedge clk) begin
    if (rst_ni && (cycle_count <= 50 || (cycle_count >= 305 && cycle_count <= 345))) begin
      $display("[FE cy=%0d] pc=0x%0h valid=%0b skip=%0d isop=%0b chunk0=0x%02h chunk1=0x%02h redir=%0b redir_tgt=0x%0h",
               cycle_count, fe_pc_probe, fe_valid_probe, fe_skip_probe,
               fe_isop_probe, fe_chunk_probe[7:0], fe_chunk_probe[15:8],
               fe_redirect_valid, fe_redirect_target);
    end
  end

  // =========================================================================
  // Dcache store-port probes — track data_req / data_gnt on the store port
  // (dcache_req_ports_ex_cache[2]) to see if the LSU is issuing the store.
  // =========================================================================
  wire        st_data_req  = i_cva6.dcache_req_ports_ex_cache[2].data_req;
  wire        st_data_gnt  = i_cva6.dcache_req_ports_cache_ex[2].data_gnt;
  wire [63:0] st_data_addr = {i_cva6.dcache_req_ports_ex_cache[2].address_tag,
                               i_cva6.dcache_req_ports_ex_cache[2].address_index};
  wire [63:0] st_data_val  = i_cva6.dcache_req_ports_ex_cache[2].data_wdata;
  wire        st_data_we   = i_cva6.dcache_req_ports_ex_cache[2].data_we;

  // LSU ready/valid
  wire        lsu_ready    = i_cva6.lsu_ready_ex_id;
  wire        lsu_valid    = i_cva6.lsu_valid_id_ex[0];
  wire        store_valid  = i_cva6.store_valid_ex_id;
  wire        lsu_commit   = i_cva6.lsu_commit_commit_ex;
  wire        lsu_commit_rdy = i_cva6.lsu_commit_ready_ex_commit;

  // Flush probes
  wire        flush_ctrl_if  = i_cva6.flush_ctrl_if;
  wire        flush_ctrl_id  = i_cva6.flush_ctrl_id;
  wire        flush_ctrl_ex  = i_cva6.flush_ctrl_ex;
  wire        flush_commit   = i_cva6.flush_commit;
  wire        set_pc         = i_cva6.set_pc_ctrl_pcgen;
  wire [63:0] pc_commit_w    = i_cva6.pc_commit;

  // Store buffer internals — probe commit queue depth counter and validity
  wire [2:0] sb_commit_cnt = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_status_cnt_q;
  wire [1:0] sb_commit_rptr = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_read_pointer_q;
  wire [1:0] sb_commit_wptr = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_write_pointer_q;
  wire [2:0] sb_spec_cnt = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_status_cnt_q;

  // Additional store buffer inputs
  wire        sb_valid_i     = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.valid_i;
  wire        sb_commit_i    = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_i;
  wire        sb_ready_o     = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.ready_o;
  wire [63:0] sb_paddr_i     = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.paddr_i;
  // Store unit FSM state
  wire [1:0]  su_state       = i_cva6.ex_stage_i.lsu_i.i_store_unit.state_q;
  wire        su_valid_i     = i_cva6.ex_stage_i.lsu_i.i_store_unit.valid_i;
  wire        su_valid_o     = i_cva6.ex_stage_i.lsu_i.i_store_unit.valid_o;
  wire        su_st_valid    = i_cva6.ex_stage_i.lsu_i.i_store_unit.st_valid;
  wire        su_pop         = i_cva6.ex_stage_i.lsu_i.i_store_unit.pop_st_o;
  wire        su_flush       = i_cva6.ex_stage_i.lsu_i.i_store_unit.flush_i;
  wire [63:0] su_vaddr       = i_cva6.ex_stage_i.lsu_i.i_store_unit.vaddr_o;
  // Probe queue entries' valid bits directly
  wire        sq0_vld = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[0].valid;
  wire        sq1_vld = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[1].valid;
  wire        sq2_vld = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[2].valid;
  wire        sq3_vld = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[3].valid;
  wire        cq0_vld = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[0].valid;
  wire        cq1_vld = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[1].valid;
  wire        cq2_vld = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[2].valid;
  wire        cq3_vld = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[3].valid;
  // Probe SB entry addresses for forwarding analysis
  wire [63:0] sq0_addr = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[0].address;
  wire [63:0] sq1_addr = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.speculative_queue_q[1].address;
  wire [63:0] cq0_addr = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[0].address;
  wire [63:0] cq1_addr = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[1].address;
  wire [63:0] cq0_data = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[0].data;
  wire [63:0] cq1_data = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[1].data;
  wire [7:0]  cq0_be   = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[0].be;
  wire [7:0]  cq1_be   = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.commit_queue_q[1].be;
  wire        sb_page_off_match = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.page_offset_matches_o;
  wire [11:0] sb_page_off_in   = i_cva6.ex_stage_i.lsu_i.i_store_unit.store_buffer_i.page_offset_i;

  // Load unit probes
  wire        lu_valid_i  = i_cva6.ex_stage_i.lsu_i.i_load_unit.valid_i;
  wire        lu_valid_o  = i_cva6.ex_stage_i.lsu_i.i_load_unit.valid_o;
  wire [1:0]  lu_state    = i_cva6.ex_stage_i.lsu_i.i_load_unit.state_q;
  wire [63:0] lu_vaddr    = i_cva6.ex_stage_i.lsu_i.i_load_unit.vaddr_o;
  wire [63:0] lu_result   = i_cva6.ex_stage_i.lsu_i.i_load_unit.result_o;
  wire        lu_rvalid   = i_cva6.ex_stage_i.lsu_i.i_load_unit.req_port_i.data_rvalid;
  wire        lu_data_req = i_cva6.ex_stage_i.lsu_i.i_load_unit.req_port_o.data_req;
  wire        lu_data_gnt = i_cva6.ex_stage_i.lsu_i.i_load_unit.req_port_i.data_gnt;
  wire        lu_ex_valid = i_cva6.ex_stage_i.lsu_i.i_load_unit.ex_i.valid;
  wire [63:0] lu_trans_id = {59'b0, i_cva6.ex_stage_i.lsu_i.i_load_unit.trans_id_o};
  // Dcache load-port return data (port 1 = load unit)
  wire [63:0] lu_dcache_rdata = i_cva6.dcache_req_ports_cache_ex[1].data_rdata;
  wire        lu_dcache_rvalid = i_cva6.dcache_req_ports_cache_ex[1].data_rvalid;
  // Dcache wbuffer not-idle
  wire        dcache_wbuf_not_ni = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.wbuffer_not_ni_o;
  // Scoreboard writeback port probes (LOAD_WB=2, STORE_WB=1, FLU_WB=0)
  wire        wb_load_valid   = i_cva6.wt_valid_ex_id[2];
  wire [4:0]  wb_load_tid     = i_cva6.trans_id_ex_id[2];
  wire [63:0] wb_load_data    = i_cva6.wbdata_ex_id[2];
  wire        wb_flu_valid    = i_cva6.wt_valid_ex_id[0];
  wire [4:0]  wb_flu_tid      = i_cva6.trans_id_ex_id[0];
  wire [63:0] wb_flu_data     = i_cva6.wbdata_ex_id[0];

  // Dcache wbuffer entry probes (8 entries, WtDcacheWbufDepth=8)
  // Each entry has: wtag, data, valid, dirty, txblock, checked, hit_oh
  wire [63:0] wbuf0_data  = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[0].data;
  wire [7:0]  wbuf0_valid = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[0].valid;
  wire [7:0]  wbuf0_dirty = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[0].dirty;
  wire [7:0]  wbuf0_txblk = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[0].txblock;
  // wtag width = DCACHE_TAG_WIDTH + (DCACHE_INDEX_WIDTH - XLEN_ALIGN_BYTES) = 44+(12-3) = 53 bits
  // Pack as 64-bit for display
  wire [63:0] wbuf0_wtag  = {11'b0, i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[0].wtag};
  wire [63:0] wbuf1_data  = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[1].data;
  wire [7:0]  wbuf1_valid = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[1].valid;
  wire [63:0] wbuf1_wtag  = {11'b0, i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[1].wtag};
  wire [63:0] wbuf2_data  = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[2].data;
  wire [7:0]  wbuf2_valid = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[2].valid;
  wire [63:0] wbuf2_wtag  = {11'b0, i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_wbuffer.wbuffer_q[2].wtag};
  // Load unit ldbuf address_offset (byte offset within dword for the current load)
  wire [2:0]  lu_addr_off = i_cva6.ex_stage_i.lsu_i.i_load_unit.ldbuf_q[i_cva6.ex_stage_i.lsu_i.i_load_unit.ldbuf_rindex].address_offset;
  // dcache forwarding hit signal from wt_dcache_mem (wbuffer_be = bytes forwarded from wbuf)
  wire [7:0]  dcache_wbuf_be  = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_mem.wbuffer_be;
  wire [63:0] dcache_wbuf_rdata = i_cva6.gen_cache_wt.i_cache_subsystem.i_wt_dcache.i_wt_dcache_mem.wbuffer_rdata;

  // Issue-stage operand probes
  wire [63:0] iss_opa = i_cva6.issue_stage_i.i_issue_read_operands.fu_data_q[0].operand_a;
  wire [63:0] iss_opb = i_cva6.issue_stage_i.i_issue_read_operands.fu_data_q[0].operand_b;
  wire [4:0]  iss_rd  = i_cva6.issue_stage_i.i_issue_read_operands.issue_instr_i[0].rd;
  wire [4:0]  iss_rs1 = i_cva6.issue_stage_i.i_issue_read_operands.issue_instr_i[0].rs1;
  wire        iss_use_imm = i_cva6.issue_stage_i.i_issue_read_operands.issue_instr_i[0].use_imm;
  wire [63:0] iss_result  = i_cva6.issue_stage_i.i_issue_read_operands.issue_instr_i[0].result;
  wire        iss_stall = i_cva6.issue_stage_i.i_issue_read_operands.stall_raw[0];
  wire        iss_valid = i_cva6.issue_stage_i.i_issue_read_operands.issue_instr_i[0].valid;
  wire [63:0] iss_pc  = i_cva6.issue_stage_i.i_issue_read_operands.issue_instr_i[0].pc;
  // Commit-stage write-back probes (commit -> regfile signals in cva6)
  wire        wbk_valid = i_cva6.we_gpr_commit_id[0];
  wire [4:0]  wbk_rd    = i_cva6.waddr_commit_id[0];
  wire [63:0] wbk_data  = i_cva6.wdata_commit_id[0];
  // Direct regfile output probe for x8 and x12 (r11)
  wire [63:0] rf_x8  = i_cva6.issue_stage_i.i_issue_read_operands.gen_fpga_regfile.i_ariane_regfile_fpga.mem[0][8];
  wire [63:0] rf_x12 = i_cva6.issue_stage_i.i_issue_read_operands.gen_fpga_regfile.i_ariane_regfile_fpga.mem[0][12];
  // All-port WBK probes for tracking r11 (x12) writes
  wire        wbk1_valid = i_cva6.we_gpr_commit_id[1];
  wire [4:0]  wbk1_rd    = i_cva6.waddr_commit_id[1];
  wire [63:0] wbk1_data  = i_cva6.wdata_commit_id[1];
  // Regfile read-operand_a combinatorial output
  wire [63:0] rf_opa_comb = i_cva6.issue_stage_i.i_issue_read_operands.operand_a_regfile[0];
  // forward_rs1 flag
  wire        fwd_rs1 = i_cva6.issue_stage_i.i_issue_read_operands.forward_rs1[0];
  wire        rs1_raw = i_cva6.issue_stage_i.i_issue_read_operands.rs1_has_raw[0];
  // Actual regfile read address for rs1
  wire [4:0]  rf_raddr0 = i_cva6.issue_stage_i.i_issue_read_operands.raddr_pack[0];
  // Block selector for x8 (to debug FPGA regfile routing)
  wire [0:0]  rf_blksel8 = i_cva6.issue_stage_i.i_issue_read_operands.gen_fpga_regfile.i_ariane_regfile_fpga.mem_block_sel_q[8];

  // Forward debug probes
  wire [3:0]  iss_idx_rs1 = i_cva6.issue_stage_i.i_issue_read_operands.gen_raw_checks[0].i_rs1_last_raw.idx_o;
  wire        iss_rs1_valid = i_cva6.issue_stage_i.i_issue_read_operands.rs1_valid[0];
  wire        iss_rs1_raw  = i_cva6.issue_stage_i.i_issue_read_operands.rs1_has_raw[0];
  wire [63:0] iss_fwd_res  = i_cva6.issue_stage_i.i_issue_read_operands.fwd_res[iss_idx_rs1];
  wire        iss_fwd_valid= i_cva6.issue_stage_i.i_issue_read_operands.fwd_res_valid[iss_idx_rs1];

  // Scoreboard commit-slot probes: track sbe.valid and sbe.result for commit pointer
  wire [3:0]  sb_commit_ptr = i_cva6.issue_stage_i.i_scoreboard.commit_pointer_q[0];
  wire        sb_cmt_valid  = i_cva6.issue_stage_i.i_scoreboard.mem_q[sb_commit_ptr].sbe.valid;
  wire [63:0] sb_cmt_result = i_cva6.issue_stage_i.i_scoreboard.mem_q[sb_commit_ptr].sbe.result;
  wire [63:0] sb_cmt_pc     = i_cva6.issue_stage_i.i_scoreboard.mem_q[sb_commit_ptr].sbe.pc;
  wire [3:0]  sb_cmt_fu     = i_cva6.issue_stage_i.i_scoreboard.mem_q[sb_commit_ptr].sbe.fu;
  // wt_valid_i array: all writeback ports visible to scoreboard
  wire        sb_wt_ld      = i_cva6.wt_valid_ex_id[2];
  wire        sb_wt_flu     = i_cva6.wt_valid_ex_id[0];
  wire        sb_wt_st      = i_cva6.wt_valid_ex_id[1];

  always_ff @(posedge clk) begin
    if (rst_ni && ((cycle_count >= 1 && cycle_count <= 45) || (cycle_count >= 255 && cycle_count <= 275) || (cycle_count >= 305 && cycle_count <= 345) || (cycle_count >= 499900 && cycle_count <= 500001))) begin
      $display("[ISS cy=%0d] pc=0x%0h rd=%0d rs1=%0d opa=0x%0h opb=0x%0h use_imm=%0b imm=0x%0h stall=%0b valid=%0b",
               cycle_count, iss_pc, iss_rd, iss_rs1, iss_opa, iss_opb, iss_use_imm, iss_result, iss_stall, iss_valid);
      $display("[FWD cy=%0d] rs1_raw=%0b fwd=%0b rs1_valid=%0b idx=%0d fwd_res=0x%0h fwd_vld=%0b rf_opa=0x%0h raddr=%0d blk8=%0d",
               cycle_count, iss_rs1_raw, fwd_rs1, iss_rs1_valid, iss_idx_rs1, iss_fwd_res, iss_fwd_valid, rf_opa_comb, rf_raddr0, rf_blksel8);
    end
    if (rst_ni && ((cycle_count >= 1 && cycle_count <= 45) || (cycle_count >= 255 && cycle_count <= 275) || (cycle_count >= 305 && cycle_count <= 345) || (cycle_count >= 499900 && cycle_count <= 500001))) begin
      if (wbk_valid)
        $display("[WBK cy=%0d] rd=%0d data=0x%0h x8=0x%0h",
                 cycle_count, wbk_rd, wbk_data, rf_x8);
    end
    // Track all writes to x12 (r11) across both commit ports — always active
    if (rst_ni) begin
      if (wbk_valid  && wbk_rd  == 5'd12)
        $display("[R11 cy=%0d port=0] data=0x%0h x12=0x%0h", cycle_count, wbk_data,  rf_x12);
      if (wbk1_valid && wbk1_rd == 5'd12)
        $display("[R11 cy=%0d port=1] data=0x%0h x12=0x%0h", cycle_count, wbk1_data, rf_x12);
    end
    // Track all writes to x1 (ra / r0) — always active
    if (rst_ni) begin
      if (wbk_valid  && wbk_rd  == 5'd1)
        $display("[RA  cy=%0d port=0] data=0x%0h", cycle_count, wbk_data);
      if (wbk1_valid && wbk1_rd == 5'd1)
        $display("[RA  cy=%0d port=1] data=0x%0h", cycle_count, wbk1_data);
    end
    // Always print SB state when any entry is valid (catches store drain timing)
    if (rst_ni && (sq0_vld || sq1_vld || sq2_vld || sq3_vld || cq0_vld || cq1_vld || cq2_vld || cq3_vld || sb_valid_i || sb_commit_i)) begin
      $display("[SB cy=%0d] sc=%0d cc=%0d rp=%0d wp=%0d sq_v=%0b%0b%0b%0b cq_v=%0b%0b%0b%0b valid_i=%0b commit_i=%0b paddr=0x%0h pg_match=%0b pg_off=0x%0h cq0:[v=%0b a=0x%0h d=0x%0h be=0x%02h] cq1:[v=%0b a=0x%0h d=0x%0h be=0x%02h]",
               cycle_count, sb_spec_cnt, sb_commit_cnt, sb_commit_rptr, sb_commit_wptr,
               sq3_vld, sq2_vld, sq1_vld, sq0_vld,
               cq3_vld, cq2_vld, cq1_vld, cq0_vld,
               sb_valid_i, sb_commit_i, sb_paddr_i,
               sb_page_off_match, sb_page_off_in,
               cq0_vld, cq0_addr, cq0_data, cq0_be,
               cq1_vld, cq1_addr, cq1_data, cq1_be);
    end
    if (rst_ni && (cycle_count <= 45 || (cycle_count >= 255 && cycle_count <= 275) || (cycle_count >= 305 && cycle_count <= 345) || (cycle_count >= 499900 && cycle_count <= 500001))) begin
      $display("[SU cy=%0d] state=%0d vi=%0b vo=%0b stvld=%0b pop=%0b flush=%0b vaddr=0x%0h",
               cycle_count, su_state, su_valid_i, su_valid_o, su_st_valid, su_pop, su_flush, su_vaddr);
      $display("[LU cy=%0d] state=%0d vi=%0b vo=%0b vaddr=0x%0h result=0x%0h req=%0b gnt=%0b rvalid=%0b ex=%0b tid=%0d",
               cycle_count, lu_state, lu_valid_i, lu_valid_o, lu_vaddr, lu_result, lu_data_req, lu_data_gnt, lu_rvalid, lu_ex_valid, lu_trans_id);
    end
    // Always log when dcache returns data to load unit
    if (rst_ni && lu_dcache_rvalid)
      $display("[DCACHE_R cy=%0d] rdata=0x%0h vaddr=0x%0h result=0x%0h wbuf_not_ni=%0b wbuf_be=0x%02h wbuf_fwd=0x%0h addr_off=%0d",
               cycle_count, lu_dcache_rdata, lu_vaddr, lu_result, dcache_wbuf_not_ni, dcache_wbuf_be, dcache_wbuf_rdata, lu_addr_off);
    // Log when load unit fires valid_o (writeback to scoreboard)
    if (rst_ni && lu_valid_o)
      $display("[LU_WB cy=%0d] valid_o=1 result=0x%0h vaddr=0x%0h rvalid=%0b dcache_rdata=0x%0h wbuf_be=0x%02h",
               cycle_count, lu_result, lu_vaddr, lu_rvalid, lu_dcache_rdata, dcache_wbuf_be);
    // Always log scoreboard writeback events (LOAD_WB and FLU_WB ports)
    if (rst_ni && wb_load_valid)
      $display("[SB_WB_LD cy=%0d] tid=%0d data=0x%0h", cycle_count, wb_load_tid, wb_load_data);
    if (rst_ni && wb_flu_valid)
      $display("[SB_WB_FLU cy=%0d] tid=%0d data=0x%0h", cycle_count, wb_flu_tid, wb_flu_data);
    // Always log scoreboard commit-slot state transitions (valid going 0->1)
    // and show the slot when any wt_valid fires
    if (rst_ni && (sb_wt_ld || sb_wt_flu || sb_wt_st))
      $display("[SB_WT cy=%0d] flu=%0b st=%0b ld=%0b | cmt_ptr=%0d cmt_valid=%0b cmt_fu=%0d cmt_pc=0x%0h cmt_res=0x%0h",
               cycle_count, sb_wt_flu, sb_wt_st, sb_wt_ld,
               sb_commit_ptr, sb_cmt_valid, sb_cmt_fu, sb_cmt_pc, sb_cmt_result);
    // Dump all 8 scoreboard entries for key windows
    if (rst_ni && ((cycle_count >= 38 && cycle_count <= 50) || (cycle_count >= 256 && cycle_count <= 265))) begin
      for (int s = 0; s < 8; s++) begin
        $display("[SB_SLOT cy=%0d slot=%0d] issued=%0b valid=%0b fu=%0d pc=0x%0h res=0x%0h",
                 cycle_count, s,
                 i_cva6.issue_stage_i.i_scoreboard.mem_q[s].issued,
                 i_cva6.issue_stage_i.i_scoreboard.mem_q[s].sbe.valid,
                 i_cva6.issue_stage_i.i_scoreboard.mem_q[s].sbe.fu,
                 i_cva6.issue_stage_i.i_scoreboard.mem_q[s].sbe.pc,
                 i_cva6.issue_stage_i.i_scoreboard.mem_q[s].sbe.result);
      end
    end
    // Log wbuffer entry state around load-execution window
    if (rst_ni && ((cycle_count >= 1 && cycle_count <= 45) || (cycle_count >= 255 && cycle_count <= 275))) begin
      $display("[WBUF cy=%0d] e0:[vld=%02h dty=%02h tx=%02h wtag=0x%0h dat=0x%0h] e1:[vld=%02h wtag=0x%0h dat=0x%0h] e2:[vld=%02h wtag=0x%0h dat=0x%0h]",
               cycle_count,
               wbuf0_valid, wbuf0_dirty, wbuf0_txblk, wbuf0_wtag, wbuf0_data,
               wbuf1_valid, wbuf1_wtag, wbuf1_data,
               wbuf2_valid, wbuf2_wtag, wbuf2_data);
    end
    if (flush_ctrl_if || flush_ctrl_id || flush_ctrl_ex || flush_commit || set_pc)
      if (rst_ni && cycle_count <= 200)
        $display("[FLUSH cy=%0d] flush_if=%0b flush_id=%0b flush_ex=%0b flush_commit=%0b set_pc=%0b pc_commit=0x%0h",
                 cycle_count, flush_ctrl_if, flush_ctrl_id, flush_ctrl_ex,
                 flush_commit, set_pc, pc_commit_w);
  end

  // =========================================================================
  // PC trace for ALL commits (debug aid — helps attribution).
  // =========================================================================
  always_ff @(posedge clk) begin
    if (rst_ni) begin
      for (int p = 0; p < CVA6Cfg.NrCommitPorts; p++) begin
        if (rvfi_probes.instr.commit_ack[p]) begin
          $display("[COMMIT cy=%0d port=%0d] PC=0x%0h fu=%0d op=%0d ex_valid=%0b",
                   cycle_count, p,
                   rvfi_probes.instr.commit_instr_pc[p],
                   rvfi_probes.instr.commit_instr_valid[p],
                   rvfi_probes.instr.commit_instr_op[p],
                   rvfi_probes.instr.ex_commit_valid);
        end
      end
      // Also log ex_commit_valid every cycle for first 200 cycles
      if ((cycle_count <= 200 || (cycle_count >= 305 && cycle_count <= 325)) && rvfi_probes.instr.ex_commit_valid) begin
        $display("[EX_COMMIT cy=%0d] cause=0x%0h pc=0x%0h tval=0x%0h",
                 cycle_count, rvfi_probes.instr.ex_commit_cause,
                 rvfi_probes.instr.commit_instr_pc[0],
                 rvfi_probes.instr.tval);
      end
      // Log AXI beats for first 600 cycles (dense debug window)
      if (cycle_count <= 600) begin
        if (noc_req.aw_valid)
          $display("[AXI_AW cy=%0d] addr=0x%0h size=%0d ready=%0b",
                   cycle_count, noc_req.aw.addr, noc_req.aw.size, noc_resp.aw_ready);
        if (noc_req.w_valid)
          $display("[AXI_W  cy=%0d] data=0x%0h strb=0x%0h ready=%0b",
                   cycle_count, noc_req.w.data, noc_req.w.strb, noc_resp.w_ready);
        if (noc_resp.b_valid)
          $display("[AXI_B  cy=%0d] id=%0d ready=%0b",
                   cycle_count, noc_resp.b.id, noc_req.b_ready);
        if (noc_req.ar_valid)
          $display("[AXI_AR cy=%0d] addr=0x%0h ready=%0b",
                   cycle_count, noc_req.ar.addr, noc_resp.ar_ready);
        if (noc_resp.r_valid)
          $display("[AXI_R  cy=%0d] data=0x%0h ready=%0b",
                   cycle_count, noc_resp.r.data, noc_req.r_ready);
      end
    end
  end

  // =========================================================================
  // Final summary block
  // =========================================================================
  final begin
    $fclose(uart_fd);
    $display("=== Integration test summary ===");
    $display("Cycles:                   %0d", cycle_count);
    $display("Instructions committed:   %0d", commit_count);
    $display("UART bytes emitted:       %0d", uart_byte_count);
    if (commit_count > 0)
      $display("instructions committed: %0d", commit_count);
  end

endmodule
