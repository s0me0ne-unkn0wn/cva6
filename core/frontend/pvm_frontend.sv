// PolkaVM JAM v1 instruction fetch frontend — sub-phase 4 / 4.5.
//
// Maintains a byte-granular PC; fetches 16 B aligned groups from a ROM/ICache
// model; reads bitmask k (1 bit per code byte) to compute skip(i) per
// graypaper §pvm:90.
//
// ROM model: COMBINATORIAL (address → data in same cycle).
// Matches the testbench's simple array ROM.
//
// Bitmask coverage: 32 bits (= 4 bitmask bytes) are read per cycle, covering
// code bytes [group_base .. group_base+31]. This spans the current 16-B group
// plus the following 16-B group, ensuring that any instruction starting within
// the current 16-B group can find its successor opcode even if that successor
// starts in the next group. PVM max instruction = 16 B (graypaper §pvm:99),
// so searching 16 bits beyond the opcode byte always finds the next opcode.
//
// Pipeline (1-cycle throughput, per ADR-1 "registered skip"):
//   Each cycle, pc_q drives the combinatorial ROM and skip encoder.
//   Results are registered into output registers on every rising edge when
//   the downstream is ready (ready_i) or the output register is empty.
//
// Latency: 1 cycle from reset / redirect to first valid_o.
// Throughput: 1 instruction per cycle when ready_i asserted.
//
// Branch redirect: 1-cycle bubble (pc_q updated; invalid output suppressed).
//
// No BTB / RAS / BHT (ADR-9). Static-not-taken.
// ADR-10: FETCH_WIDTH = 128 bits = 16 B aligned groups.
// ADR-1: priority-encoder output is registered.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

module pvm_frontend #(
    // Virtual address width — matches CVA6 VLEN (39 for Sv39).
    // Testbench uses VirtualAddrSize=8 for a 256-byte address space.
    parameter int unsigned VirtualAddrSize = 39
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,

    // -----------------------------------------------------------------------
    // ROM / ICache interface — COMBINATORIAL ROM assumed.
    // -----------------------------------------------------------------------
    // 16-byte aligned fetch address (= pc_q with low 4 bits zeroed).
    output logic [VirtualAddrSize-1:0]    code_addr_o,
    // 128-bit instruction group valid combinatorially from code_addr_o.
    input  logic [127:0]                  code_data_i,
    // Next 16-byte group (code_addr_o + 16), for cross-boundary instructions.
    input  logic [127:0]                  code_data_next_i,

    // Bitmask: 1 bit per code byte.
    // Address = 16-byte-aligned group address.  The ROM selects the 32-byte
    // entry via addr[9:5] and returns 64 bits ({entry[idx+1], entry[idx]}).
    output logic [VirtualAddrSize-1:0]    bitmask_addr_o,
    // 64 bitmask bits, valid combinatorially from bitmask_addr_o.
    // Lower 32 bits = entry[idx], upper 32 bits = entry[idx+1].
    // Together they cover code bytes [32*idx .. 32*idx+63].
    // bitmask_data_i[j] = k bit for code byte (32*idx + j), j = 0..63.
    input  logic [63:0]                   bitmask_data_i,

    // -----------------------------------------------------------------------
    // Branch redirect from execute stage
    // -----------------------------------------------------------------------
    input  logic                          branch_redirect_valid_i,
    input  logic [VirtualAddrSize-1:0]    branch_redirect_target_i,

    // -----------------------------------------------------------------------
    // Phase 5 ADR-10 + sub-phase 1.1: privilege mode + DRAM section bounds.
    // -----------------------------------------------------------------------
    // Current privilege level (RISC-V encoding): 2'b11 = M, 2'b01 = S, 2'b00 = U.
    // In Phase 4.5 mode (USE_PVM_PRIV=0) the wrapper ties this to 2'b11 — and
    // since code_base_m/s default to 0 from pvm_config_regs reset, all bounds
    // checks fail and fetch_source_o stays at BOOTROM (preserved behaviour).
    input  logic [1:0]                    priv_lvl_i,
    // M-mode DRAM section bounds (programmed by bootrom via PVMConfig MMIO).
    input  logic [31:0]                   code_base_m_i,
    input  logic [31:0]                   code_len_m_i,
    // S/U-mode DRAM section bounds (Phase 6 — reset 0 in Phase 5).
    input  logic [31:0]                   code_base_s_i,
    input  logic [31:0]                   code_len_s_i,
    // Fetch-source selector for the wrapper's bootrom/DRAM-AXI mux (sub-phase 1.2):
    //   2'b00 FETCH_BOOTROM — pc falls outside both DRAM ranges (default)
    //   2'b01 FETCH_DRAM_M  — M-mode, pc ∈ [code_base_m, code_base_m+code_len_m)
    //   2'b10 FETCH_DRAM_S  — S/U-mode, pc ∈ [code_base_s, code_base_s+code_len_s)
    // Combinational alongside code_addr_o; the wrapper muxes the data source
    // in the same cycle so code_data_i (existing input) reflects the chosen
    // source on the next read.
    // Sub-phase 1.1 (this file) only computes the flag; sub-phase 1.2 wires
    // the AXI master interface in cva6.sv / ariane_xilinx.sv that consumes it.
    output logic [1:0]                    fetch_source_o,

    // -----------------------------------------------------------------------
    // Output to id_stage / pvm_decoder — registered (ADR-1).
    // -----------------------------------------------------------------------
    output logic                          valid_o,
    // 16-byte instruction window; chunk_o[7:0] = opcode at pc_o.
    output logic [127:0]                  chunk_o,
    // skip = instruction_length - 1. Range 0..15. Registered per ADR-1.
    output logic [4:0]                    skip_o,
    // Asserted when pc_o is a valid opcode position per bitmask k.
    output logic                          is_valid_opcode_o,
    // Byte-granular PC of the instruction in chunk_o.
    output logic [VirtualAddrSize-1:0]    pc_o,

    // Back-pressure: 0 = stall (hold output, do not advance PC).
    input  logic                          ready_i
);

  // =========================================================================
  // PC register
  // =========================================================================
  logic [VirtualAddrSize-1:0] pc_q;

  // =========================================================================
  // Combinatorial: ROM addressing
  // =========================================================================
  // 16-B aligned group address.
  logic [VirtualAddrSize-1:0] group_addr;
  assign group_addr     = {pc_q[VirtualAddrSize-1:4], 4'b0000};
  assign code_addr_o    = group_addr;
  // Bitmask address: pass the 16-byte-aligned group address directly.
  // The bitmask ROM uses idx = addr_i[9:5] (32-byte-aligned entries, 32 bits each).
  // When group_addr[4]=1 (group is at offset 16 within a 32-byte entry),
  // the bitmask window must be shifted right by 16 so that bitmask_shifted[j]
  // corresponds to code byte (group_base + j).  See bitmask_shifted below.
  assign bitmask_addr_o = group_addr;

  // =========================================================================
  // Combinatorial: skip encoder
  // =========================================================================
  // Byte offset of current PC within the 16-B group (0..15).
  logic [3:0] byte_off;
  assign byte_off = pc_q[3:0];

  // Concatenate current and next 16-byte groups into a 256-bit window so that
  // instructions crossing a 16-byte boundary are fully captured.
  // chunk[7:0] = opcode at pc_q after right-shifting by byte_off*8.
  logic [255:0] fetch_window;
  assign fetch_window = {code_data_next_i, code_data_i};
  logic [127:0] chunk_comb;
  assign chunk_comb = fetch_window[{1'b0, byte_off, 3'b000} +: 128];

  // Bitmask window alignment.
  // The bitmask ROM returns 64 bits: {entry[idx+1], entry[idx]}, where
  // entry[idx] covers code bytes [32*idx .. 32*idx+31].
  // group_addr is 16-byte aligned; bitmask_addr_o = group_addr so
  // idx = group_addr[9:5] (the 32-byte block containing group_base).
  //
  // We extract a 32-bit window starting at group_base:
  //   - group_addr[4]=0: group_base is 32-byte aligned → use bits [31:0]
  //   - group_addr[4]=1: group_base is at offset +16 → use bits [47:16]
  // This gives bitmask_shifted[j] = "code byte (group_base+j) is opcode start"
  // for j=0..31, spanning up to 16 bytes beyond the end of the 16-byte group
  // (the full PVM max-instruction lookahead per graypaper §pvm:99).
  logic [31:0] bitmask_shifted;
  assign bitmask_shifted = group_addr[4] ? bitmask_data_i[47:16] : bitmask_data_i[31:0];

  // is_valid_opcode: bitmask bit at current byte offset.
  logic is_valid_op_comb;
  assign is_valid_op_comb = bitmask_shifted[{1'b0, byte_off}];

  // Priority encoder over 32-bit bitmask.
  // Search bits [byte_off+1 .. byte_off+16] (up to 16 positions ahead,
  // matching the max instruction length of 16 B per graypaper §pvm:99).
  // skip = (position_of_next_opcode) - byte_off - 1
  //      = (next set bit index in bitmask_shifted above byte_off) - byte_off - 1.
  // bitmask_shifted[j] corresponds to code byte (group_base + j).
  // byte_off is in 0..15, so we search bits byte_off+1 .. byte_off+16 (⊆ 1..31).
  //
  // Default when no next opcode found in 16 positions: skip = 15
  // (16-byte instruction, 15 arg bytes — max per §pvm:99).
  logic [4:0] skip_comb;

  always_comb begin : p_skip_encoder
    skip_comb = 5'd15;  // default: 16-byte instruction
    // Scan downward from byte_off+16 so the first (lowest-index) set bit wins.
    for (int j = 31; j >= 1; j--) begin
      // Only consider positions in [byte_off+1 .. byte_off+16].
      if ((j > int'(byte_off)) && (j <= int'(byte_off) + 16)) begin
        if (bitmask_shifted[j]) begin
          skip_comb = 5'(unsigned'(j)) - 5'({1'b0, byte_off}) - 5'd1;
        end
      end
    end
  end

  // Next instruction PC = current PC + 1 (opcode) + skip (arg bytes).
  logic [VirtualAddrSize-1:0] next_pc;
  assign next_pc = pc_q + VirtualAddrSize'(1) + VirtualAddrSize'(skip_comb);

  // =========================================================================
  // Output registers (ADR-1: skip registered)
  // =========================================================================
  logic          valid_q;
  logic [127:0]  chunk_q;
  logic [4:0]    skip_q;
  logic          is_valid_op_q;
  logic [VirtualAddrSize-1:0] pc_out_q;

  // Pipeline can advance when: downstream is ready, or output register empty.
  logic advance;
  assign advance = ready_i || !valid_q;

  // =========================================================================
  // Sequential logic
  // =========================================================================
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_seq
    if (!rst_ni) begin
      pc_q          <= '0;
      valid_q       <= 1'b0;
      chunk_q       <= '0;
      skip_q        <= '0;
      is_valid_op_q <= 1'b0;
      pc_out_q      <= '0;
    end else begin

      // -------------------------------------------------------------------
      // Branch redirect: highest priority — flush output and load new PC.
      // The new combinatorial values will be registered on the next edge
      // (via the advance path, since valid_q = 0 → advance = 1).
      // -------------------------------------------------------------------
      if (branch_redirect_valid_i) begin
        pc_q    <= branch_redirect_target_i;
        valid_q <= 1'b0;

      // -------------------------------------------------------------------
      // Normal: register combinatorial outputs when pipeline can advance.
      // -------------------------------------------------------------------
      end else if (advance) begin
        chunk_q       <= chunk_comb;
        skip_q        <= skip_comb;
        is_valid_op_q <= is_valid_op_comb;
        pc_out_q      <= pc_q;
        valid_q       <= 1'b1;
        pc_q          <= next_pc;
      end
      // Stall (ready_i=0 and valid_q=1): hold all registers unchanged.

    end
  end

  // =========================================================================
  // Phase 5 ADR-10 / sub-phase 1.1: mode-aware fetch source selection
  // (B3 fix iter 3: absolute-PC bounds-check, NO `pc_q - reset_vector`).
  // =========================================================================
  // The fetch-source decision is combinational on pc_q (matches the cycle
  // when code_addr_o is driven). The wrapper consumes fetch_source_o in the
  // same cycle to route either bootrom-direct or DRAM-AXI data into
  // code_data_i / code_data_next_i / bitmask_data_i.
  localparam logic [1:0] FETCH_BOOTROM = 2'b00;
  localparam logic [1:0] FETCH_DRAM_M  = 2'b01;
  localparam logic [1:0] FETCH_DRAM_S  = 2'b10;

  // Zero-extend 32-bit bases to VirtualAddrSize. DRAM at 0x80000000-0xBFFFFFFF
  // on Genesys2 fits within 32 bits, so 32-bit MMIO base regs are sufficient.
  logic in_m_range, in_s_range;
  assign in_m_range = (code_len_m_i != 32'h0)
                   && (pc_q >= VirtualAddrSize'({{(VirtualAddrSize-32){1'b0}}, code_base_m_i}))
                   && (pc_q <  VirtualAddrSize'({{(VirtualAddrSize-32){1'b0}}, code_base_m_i + code_len_m_i}));
  assign in_s_range = (code_len_s_i != 32'h0)
                   && (pc_q >= VirtualAddrSize'({{(VirtualAddrSize-32){1'b0}}, code_base_s_i}))
                   && (pc_q <  VirtualAddrSize'({{(VirtualAddrSize-32){1'b0}}, code_base_s_i + code_len_s_i}));

  logic [1:0] fetch_source_comb;
  always_comb begin : p_fetch_source_mux
    unique case (priv_lvl_i)
      2'b11:   fetch_source_comb = in_m_range ? FETCH_DRAM_M : FETCH_BOOTROM;
      2'b00,
      2'b01:   fetch_source_comb = in_s_range ? FETCH_DRAM_S : FETCH_BOOTROM;
      default: fetch_source_comb = FETCH_BOOTROM;  // 2'b10 reserved
    endcase
  end

  // =========================================================================
  // Output assignments
  // =========================================================================
  assign valid_o           = valid_q;
  assign chunk_o           = chunk_q;
  assign skip_o            = skip_q;
  assign is_valid_opcode_o = is_valid_op_q;
  assign pc_o              = pc_out_q;
  assign fetch_source_o    = fetch_source_comb;

endmodule
