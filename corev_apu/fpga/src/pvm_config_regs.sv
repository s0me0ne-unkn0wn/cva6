// Copyright 2026 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
//
// pvm_config_regs — Phase 5 ADR-2 MMIO config register slave.
//
// 20 × 32-bit register file at PVMConfigBase (0x1800_2000), 4 KB region.
// Five sections × two privilege modes × {base, length}:
//
//   offset  reg              consumed by
//   ------  ---------------  --------------------------------------------
//   0x00    code_base_m      pvm_frontend (sub-phase 1.1) — DRAM PC bounds
//   0x04    code_len_m       pvm_frontend (sub-phase 1.1) — DRAM PC bounds
//   0x08    bitmask_base_m   pvm_frontend (sub-phase 1.1) — bitmask fetch
//   0x0C    bitmask_len_m    pvm_frontend (sub-phase 1.1)
//   0x10    ro_base_m        LSU (Stage 2) — ro_data section in DRAM
//   0x14    ro_len_m         LSU (Stage 2)
//   0x18    rw_base_m        LSU (Stage 2) — rw_data section in DRAM
//   0x1C    rw_len_m         LSU (Stage 2)
//   0x20    jt_base_m        LSU (Stage 2) — jump-table for jump_indirect
//   0x24    jt_len_m         LSU (Stage 2)
//   0x28    code_base_s      Phase 6 S-mode — unused in Phase 5 (reset=0)
//   0x2C    code_len_s       Phase 6 — unused in Phase 5
//   0x30    bitmask_base_s   Phase 6 — unused in Phase 5
//   0x34    bitmask_len_s    Phase 6 — unused in Phase 5
//   0x38    ro_base_s        Phase 6 — unused in Phase 5
//   0x3C    ro_len_s         Phase 6 — unused in Phase 5
//   0x40    rw_base_s        Phase 6 — unused in Phase 5
//   0x44    rw_len_s         Phase 6 — unused in Phase 5
//   0x48    jt_base_s        Phase 6 — unused in Phase 5
//   0x4C    jt_len_s         Phase 6 — unused in Phase 5
//
// Higher offsets (0x50..0xFFC) are reserved; read 0, write ignored.
//
// All registers reset to 0. Bootrom (sub-phase 5.2) programs the M-mode set
// after parsing the 128-byte SD-image header. The S-mode set stays 0 in
// Phase 5 — when OpenSBI does mret, the frontend reads the unprogrammed
// S-mode base (0), the bounds-check fails, fetch_source falls back to BOOTROM
// and reads zero bytes (since reset_vector is 0x10000 and bootrom ROM is
// addressed by mod 16 lookup); the zero-byte PVM `trap` opcode then delivers
// the exception via mtvec per ADR-4. This is the Phase 5 milestone-C smoke.
//
// AXI4 slave (full AXI, single-beat — no burst). aw_size and ar_size are
// honoured for byte-lane selection within the 64-bit data bus.

module pvm_config_regs #(
  parameter int unsigned AxiAddrWidth = 64,
  parameter int unsigned AxiDataWidth = 64,
  parameter int unsigned AxiIdWidth   = 4,
  parameter int unsigned AxiUserWidth = 1
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // AXI4 slave port from xbar (master[ariane_soc::PVMConfig])
  AXI_BUS.Slave                   axi,

  // M-mode section bases and lengths (consumed by pvm_frontend + LSU).
  output logic [31:0]             code_base_m_o,
  output logic [31:0]             code_len_m_o,
  output logic [31:0]             bitmask_base_m_o,
  output logic [31:0]             bitmask_len_m_o,
  output logic [31:0]             ro_base_m_o,
  output logic [31:0]             ro_len_m_o,
  output logic [31:0]             rw_base_m_o,
  output logic [31:0]             rw_len_m_o,
  output logic [31:0]             jt_base_m_o,
  output logic [31:0]             jt_len_m_o,

  // S-mode section bases and lengths (Phase 6 use; reset=0 in Phase 5).
  output logic [31:0]             code_base_s_o,
  output logic [31:0]             code_len_s_o,
  output logic [31:0]             bitmask_base_s_o,
  output logic [31:0]             bitmask_len_s_o,
  output logic [31:0]             ro_base_s_o,
  output logic [31:0]             ro_len_s_o,
  output logic [31:0]             rw_base_s_o,
  output logic [31:0]             rw_len_s_o,
  output logic [31:0]             jt_base_s_o,
  output logic [31:0]             jt_len_s_o
);

  localparam int unsigned NUM_REGS = 20;

  // Register file (reset to 0).
  logic [31:0] regs_q [NUM_REGS];

  // ===========================================================================
  // Write channel (AW + W → B)
  // ===========================================================================
  // Latch AW and W independently; commit when both received and not already
  // sending a B response. Single-beat only (aw_len assumed 0).
  logic                          aw_received_q;
  logic                          w_received_q;
  logic [AxiAddrWidth-1:0]       wr_addr_q;
  logic [AxiIdWidth-1:0]         wr_id_q;
  logic [AxiUserWidth-1:0]       wr_user_q;
  logic [AxiDataWidth-1:0]       wr_data_q;
  logic [AxiDataWidth/8-1:0]     wr_strb_q;
  logic                          b_valid_q;

  // ===========================================================================
  // Read channel (AR → R)
  // ===========================================================================
  logic [AxiIdWidth-1:0]         rd_id_q;
  logic [31:0]                   rd_word_q;
  logic                          rd_addr_high_q;  // r_data lane select
  logic                          r_valid_q;

  // Decoded register index (4-byte stride, low 7 address bits cover 0x00..0x7C
  // which is the 32-word window; offsets >= 0x50 read 0, writes ignored).
  function automatic logic [4:0] reg_idx_from_addr(input logic [AxiAddrWidth-1:0] a);
    return a[6:2];
  endfunction

  // ===========================================================================
  // Sequential logic
  // ===========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_received_q   <= 1'b0;
      w_received_q    <= 1'b0;
      wr_addr_q       <= '0;
      wr_id_q         <= '0;
      wr_user_q       <= '0;
      wr_data_q       <= '0;
      wr_strb_q       <= '0;
      b_valid_q       <= 1'b0;
      rd_id_q         <= '0;
      rd_word_q       <= '0;
      rd_addr_high_q  <= 1'b0;
      r_valid_q       <= 1'b0;
      for (int i = 0; i < NUM_REGS; i++) regs_q[i] <= '0;
    end else begin
      // ----- AW latch -----
      if (axi.aw_valid && axi.aw_ready) begin
        aw_received_q <= 1'b1;
        wr_addr_q     <= axi.aw_addr;
        wr_id_q       <= axi.aw_id;
        wr_user_q     <= axi.aw_user;
      end
      // ----- W latch -----
      if (axi.w_valid && axi.w_ready) begin
        w_received_q <= 1'b1;
        wr_data_q    <= axi.w_data;
        wr_strb_q    <= axi.w_strb;
      end
      // ----- Commit write -----
      if (aw_received_q && w_received_q && !b_valid_q) begin
        logic [4:0]  widx;
        logic [31:0] wword;
        widx  = reg_idx_from_addr(wr_addr_q);
        // Byte lane: if address[2]=1, the 32-bit word is in the upper half
        // of w_data; otherwise it is in the lower half.
        wword = wr_addr_q[2] ? wr_data_q[63:32] : wr_data_q[31:0];
        if (widx < 5'(NUM_REGS)) begin
          regs_q[widx] <= wword;
        end
        // Reserved offsets (>= 0x50, i.e. widx >= NUM_REGS): write ignored,
        // OK response.
        aw_received_q <= 1'b0;
        w_received_q  <= 1'b0;
        b_valid_q     <= 1'b1;
      end
      // ----- B handshake -----
      if (b_valid_q && axi.b_ready) begin
        b_valid_q <= 1'b0;
      end

      // ----- AR latch + read -----
      if (axi.ar_valid && axi.ar_ready) begin
        logic [4:0] ridx;
        ridx           = reg_idx_from_addr(axi.ar_addr);
        rd_id_q        <= axi.ar_id;
        rd_addr_high_q <= axi.ar_addr[2];
        rd_word_q      <= (ridx < 5'(NUM_REGS)) ? regs_q[ridx] : 32'h0;
        r_valid_q      <= 1'b1;
      end
      if (r_valid_q && axi.r_ready) begin
        r_valid_q <= 1'b0;
      end
    end
  end

  // ===========================================================================
  // Combinational ready/valid drivers
  // ===========================================================================
  // Accept AW/W only when not already latched AND not currently emitting B.
  // (Backpressure when B is in flight prevents head-of-line stall.)
  assign axi.aw_ready = !aw_received_q && !b_valid_q;
  assign axi.w_ready  = !w_received_q  && !b_valid_q;
  assign axi.b_id     = wr_id_q;
  assign axi.b_resp   = 2'b00;             // OKAY
  assign axi.b_user   = '0;
  assign axi.b_valid  = b_valid_q;

  // Read: accept AR only when not already serving an R.
  assign axi.ar_ready = !r_valid_q;
  assign axi.r_id     = rd_id_q;
  // Lane selection: place the 32-bit register value in the correct half of
  // the 64-bit data bus based on the captured address's bit [2].
  assign axi.r_data   = rd_addr_high_q ? {rd_word_q, 32'h0000_0000}
                                       : {32'h0000_0000, rd_word_q};
  assign axi.r_resp   = 2'b00;             // OKAY
  assign axi.r_last   = 1'b1;              // single-beat
  assign axi.r_user   = '0;
  assign axi.r_valid  = r_valid_q;

  // ===========================================================================
  // Output assignments
  // ===========================================================================
  assign code_base_m_o    = regs_q[0];
  assign code_len_m_o     = regs_q[1];
  assign bitmask_base_m_o = regs_q[2];
  assign bitmask_len_m_o  = regs_q[3];
  assign ro_base_m_o      = regs_q[4];
  assign ro_len_m_o       = regs_q[5];
  assign rw_base_m_o      = regs_q[6];
  assign rw_len_m_o       = regs_q[7];
  assign jt_base_m_o      = regs_q[8];
  assign jt_len_m_o       = regs_q[9];
  assign code_base_s_o    = regs_q[10];
  assign code_len_s_o     = regs_q[11];
  assign bitmask_base_s_o = regs_q[12];
  assign bitmask_len_s_o  = regs_q[13];
  assign ro_base_s_o      = regs_q[14];
  assign ro_len_s_o       = regs_q[15];
  assign rw_base_s_o      = regs_q[16];
  assign rw_len_s_o       = regs_q[17];
  assign jt_base_s_o      = regs_q[18];
  assign jt_len_s_o       = regs_q[19];

endmodule
