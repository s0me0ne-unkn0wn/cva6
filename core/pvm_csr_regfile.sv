// PVM CSR regfile + ecalli FSM (sub-phase 8).
// Phase 4 sub-phase 2: parallel-to-legacy module gated by USE_PVM_ISA.
//   - When USE_PVM_ISA = 0 (default): legacy csr_regfile is instantiated.
//   - When USE_PVM_ISA = 1: this module is instantiated.
//   - Sub-phase 9 deletes csr_regfile.sv after verification.
//
// CSR set: {pcause, pepc, pstatus, pevent_table_base, pgas, pcycle}.
//   pgas reads-as-zero per ADR-2.
//   pcycle is a free-running 64-bit cycle counter (substitutes csrr cycle
//     in bootrom/src/main.c:15; per Critic adversarial finding).
//
// ecalli FSM (sub-phase 8): all 4 states now reachable.
//   IDLE       → on ecalli retire with non-sentinel imm  → DRAINED
//   DRAINED    → 1-cycle snapshot; issue table-read addr → TABLE_READ
//   TABLE_READ → 3-cycle timer (mock dcache hit; see NOTE below) → JUMPED
//   JUMPED     → 1-cycle redirect pulse                  → IDLE
//
// NOTE (LSU integration gap): reading `pevent_table_base + 8*imm` from
// memory requires an out-of-band dcache request that cannot be issued from
// the CSR regfile without a new dcache port in cva6.sv (all 3 existing
// ex-stage ports are used by LSU/PTW).  For MVP the TABLE_READ state uses a
// 3-cycle timer and returns `pevent_table_base + 8*imm` as the redirect
// target *directly* (treating the table as an offset map rather than an
// indirection, which is correct only when the handler is always at a fixed
// address known at load time).  A follow-up (sub-phase 8.5 or sub-phase 9)
// must wire an actual dcache load here before real JAM-v1 programs can use
// non-trivial handler tables.
//
// Port shape is intentionally kept close to csr_regfile so the generate
// if-else in cva6.sv compiles with the same signal names.  Unused RISC-V
// outputs are driven to safe constants; unused inputs are ignored.
// Sub-phase 7 will trim the port surface once downstream modules no longer
// depend on the RISC-V-specific signals.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

module pvm_csr_regfile
  import ariane_pkg::*;
  import polkavm_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg            = config_pkg::cva6_cfg_empty,
    parameter type                   exception_t        = logic,
    parameter type                   jvt_t              = logic,
    parameter type                   irq_ctrl_t         = logic,
    parameter type                   scoreboard_entry_t = logic,
    parameter type                   rvfi_probes_csr_t  = logic,
    parameter int                    VmidWidth          = 1,
    parameter int unsigned           MHPMCounterNum     = 6,
    parameter int unsigned           N_Triggers         = 4
) (
    // Subsystem Clock - SUBSYSTEM
    input  logic                                   clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                                   rst_ni,
    // Timer threw an interrupt - SUBSYSTEM
    input  logic                                   time_irq_i,
    // send a flush request out when a CSR with a side effect changes - CONTROLLER
    output logic                                   flush_o,
    // halt requested - CONTROLLER
    output logic                                   halt_csr_o,
    // Instruction to be committed - ID_STAGE
    input  scoreboard_entry_t                      commit_instr_i,
    // Commit acknowledged an instruction - COMMIT_STAGE
    input  logic [CVA6Cfg.NrCommitPorts-1:0]      commit_ack_i,
    // Address from which to start booting - SUBSYSTEM
    input  logic [CVA6Cfg.VLEN-1:0]               boot_addr_i,
    // Hart id (not used in PVM; driven to zero) - SUBSYSTEM
    input  logic [CVA6Cfg.XLEN-1:0]               hart_id_i,
    // Exception from commit stage - COMMIT_STAGE
    input  exception_t                             ex_i,
    // CSR operation (read/write/set/clear/mret) - COMMIT_STAGE
    input  fu_op                                   csr_op_i,
    // CSR address - EX_STAGE
    input  logic [11:0]                            csr_addr_i,
    // Write data in - COMMIT_STAGE
    input  logic [CVA6Cfg.XLEN-1:0]               csr_wdata_i,
    // Read data out - COMMIT_STAGE
    output logic [CVA6Cfg.XLEN-1:0]               csr_rdata_o,
    // Mark the FP state as dirty (unused in PVM) - COMMIT_STAGE
    input  logic                                   dirty_fp_state_i,
    // Write fflags register (unused in PVM) - COMMIT_STAGE
    input  logic                                   csr_write_fflags_i,
    // Mark the V state as dirty (unused in PVM) - ACC_DISPATCHER
    input  logic                                   dirty_v_state_i,
    // PC of instruction accessing the CSR - COMMIT_STAGE
    input  logic [CVA6Cfg.VLEN-1:0]               pc_i,
    // CSR access exception - COMMIT_STAGE
    output exception_t                             csr_exception_o,
    // Exception PC out (pepc → epc_o) - FRONTEND
    output logic [CVA6Cfg.VLEN-1:0]               epc_o,
    // Return from exception - FRONTEND
    output logic                                   eret_o,
    // Trap vector base (pevent_table_base → trap_vector_base_o) - FRONTEND
    output logic [CVA6Cfg.VLEN-1:0]               trap_vector_base_o,
    // Current privilege level - EX_STAGE
    output riscv::priv_lvl_t                       priv_lvl_o,
    // Data Endian mode (always little-endian) - EX_STAGE
    output logic                                   mbe_o,
    // Virtualization mode (not used in PVM) - EX_STAGE
    output logic                                   v_o,
    // FP accelerator fflags (unused in PVM) - ACC_DISPATCHER
    input  logic [4:0]                             acc_fflags_ex_i,
    // FP accelerator valid (unused in PVM) - ACC_DISPATCHER
    input  logic                                   acc_fflags_ex_valid_i,
    // FP extension status (always Off) - ID_STAGE
    output riscv::xs_t                             fs_o,
    // FP virtual extension status (always Off) - ID_STAGE
    output riscv::xs_t                             vfs_o,
    // FP occurred exceptions (always zero) - COMMIT_STAGE
    output logic [4:0]                             fflags_o,
    // FP dynamic rounding mode (always zero) - EX_STAGE
    output logic [2:0]                             frm_o,
    // FP precision control (always zero) - EX_STAGE
    output logic [6:0]                             fprec_o,
    // Vector extension status (always Off) - ID_STAGE
    output riscv::xs_t                             vs_o,
    // Interrupt management (partially wired; sub-phase 9 finalises) - ID_STAGE
    output irq_ctrl_t                              irq_ctrl_o,
    // Enable virtual address translation (always 0 in PVM MVP) - EX_STAGE
    output logic                                   en_translation_o,
    // Enable G-Stage address translation (always 0) - EX_STAGE
    output logic                                   en_g_translation_o,
    // Enable LD/ST address translation (always 0) - EX_STAGE
    output logic                                   en_ld_st_translation_o,
    // Enable G-Stage LD/ST address translation (always 0) - EX_STAGE
    output logic                                   en_ld_st_g_translation_o,
    // Privilege level for LD/ST - EX_STAGE
    output riscv::priv_lvl_t                       ld_st_priv_lvl_o,
    // Virtualization mode for LD/ST (always 0) - EX_STAGE
    output logic                                   ld_st_v_o,
    // Hypervisor LD/ST inst (unused in PVM) - EX_STAGE
    input  logic                                   csr_hs_ld_st_inst_i,
    // SUM bit (always 0 in PVM) - EX_STAGE
    output logic                                   sum_o,
    // VS-SUM bit (always 0) - EX_STAGE
    output logic                                   vs_sum_o,
    // MXR bit (always 0 in PVM) - EX_STAGE
    output logic                                   mxr_o,
    // VS-MXR bit (always 0) - EX_STAGE
    output logic                                   vmxr_o,
    // SATP PPN (always 0; no MMU in PVM MVP) - EX_STAGE
    output logic [CVA6Cfg.PPNW-1:0]               satp_ppn_o,
    // ASID (always 0) - EX_STAGE
    output logic [CVA6Cfg.ASID_WIDTH-1:0]         asid_o,
    // VS-SATP PPN (always 0) - EX_STAGE
    output logic [CVA6Cfg.PPNW-1:0]               vsatp_ppn_o,
    // VS-ASID (always 0) - EX_STAGE
    output logic [CVA6Cfg.ASID_WIDTH-1:0]         vs_asid_o,
    // HGATP PPN (always 0) - EX_STAGE
    output logic [CVA6Cfg.PPNW-1:0]               hgatp_ppn_o,
    // VMID (always 0) - EX_STAGE
    output logic [CVA6Cfg.VMID_WIDTH-1:0]         vmid_o,
    // CBO enable flags (always Off) - ID_STAGE
    output riscv::cbie_t                           mcbie_o,
    output riscv::cbie_t                           scbie_o,
    output riscv::cbie_t                           hcbie_o,
    output logic                                   mcbcfe_o,
    output logic                                   scbcfe_o,
    output logic                                   hcbcfe_o,
    // External interrupt in - SUBSYSTEM
    input  logic [1:0]                             irq_i,
    // IPI (unused in PVM MVP) - SUBSYSTEM
    input  logic                                   ipi_i,
    // Debug request in (unused in PVM MVP) - ID_STAGE
    input  logic                                   debug_req_i,
    // Set debug PC (always 0 in PVM MVP) - FRONTEND
    output logic                                   set_debug_pc_o,
    // TVM / TW / VTW / TSR / HU bits (always 0 in PVM) - ID_STAGE
    output logic                                   tvm_o,
    output logic                                   tw_o,
    output logic                                   vtw_o,
    output logic                                   tsr_o,
    output logic                                   hu_o,
    // Debug mode (always 0 in PVM MVP) - EX_STAGE
    output logic                                   debug_mode_o,
    // Single step (always 0 in PVM MVP) - COMMIT_STAGE
    output logic                                   single_step_o,
    // ICache / DCache enable (always 1) - CACHE
    output logic                                   icache_en_o,
    output logic                                   dcache_en_o,
    // Accelerator memory-consistent mode (always 0) - ACC_DISPATCHER
    output logic                                   acc_cons_en_o,
    // Perf counter interface (stub; pcycle handled internally) - PERF_COUNTERS
    output logic [11:0]                            perf_addr_o,
    output logic [CVA6Cfg.XLEN-1:0]               perf_data_o,
    input  logic [CVA6Cfg.XLEN-1:0]               perf_data_i,
    output logic                                   perf_we_o,
    // PMP (all zeros; no PMP in PVM MVP) - ACC_DISPATCHER
    output riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0] pmpcfg_o,
    output logic [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_o,
    // mcountinhibit (always 0 in PVM) - PERF_COUNTERS
    output logic [31:0]                            mcountinhibit_o,
    // RVFI (wired to zero for PVM; tracer will be re-targeted in sub-phase 6)
    output rvfi_probes_csr_t                       rvfi_csr_o,
    // JVT (unused in PVM) - COMMIT_STAGE
    output jvt_t                                   jvt_o,
    // Trigger module (no triggers in PVM MVP) - COMMIT_STAGE
    output logic                                   debug_from_trigger_o,
    input  logic [CVA6Cfg.VLEN-1:0]               vaddr_from_lsu_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    input  logic [CVA6Cfg.XLEN-1:0]               store_result_i,
    output logic                                   break_from_trigger_o,
    // -------------------------------------------------------------------------
    // ecalli FSM handshake (sub-phase 8) — connects to commit_stage
    // -------------------------------------------------------------------------
    // Pulse from commit_stage when an ecalli retires (non-sentinel imm).
    // Committed PC and imm are valid in the same cycle as this pulse.
    input  logic                                   ecalli_valid_i,
    // 32-bit ecalli immediate (lower 32 bits of the committed result).
    input  logic [31:0]                            ecalli_imm_i,
    // PC of the ecalli instruction (commit_instr_i[0].pc).
    input  logic [CVA6Cfg.VLEN-1:0]               ecalli_pc_i,
    // Pulse back to commit_stage: FSM has completed; redirect is ready.
    output logic                                   ecalli_done_o,
    // Redirect target PC (handler address or restored pepc).
    output logic [CVA6Cfg.VLEN-1:0]               ecalli_redirect_pc_o,
    // Privilege level after the ecalli redirect (U-mode for handler entry).
    output riscv::priv_lvl_t                       ecalli_redirect_priv_o
);

  // ---------------------------------------------------------------------------
  // ecalli FSM type definition (sub-phase 8: all 4 states reachable)
  // ---------------------------------------------------------------------------
  // States per ADR-5:
  //   IDLE       — normal execution; no ecalli in-flight.
  //   DRAINED    — pipeline drained after ecalli retire; snapshot saved.
  //   TABLE_READ — waiting for handler-address resolution (mock: 3-cycle timer).
  //   JUMPED     — 1-cycle redirect pulse; then return to IDLE.
  //
  // Sub-phase 8 wires all transitions.  The TABLE_READ state uses a 3-cycle
  // timer instead of a real dcache load (see LSU integration gap note above).
  typedef enum logic [1:0] {
    ECALLI_IDLE       = 2'd0,
    ECALLI_DRAINED    = 2'd1,
    ECALLI_TABLE_READ = 2'd2,
    ECALLI_JUMPED     = 2'd3
  } ecalli_state_t;

  ecalli_state_t ecalli_state_q, ecalli_state_d;

  // TABLE_READ mock-latency counter (3 cycles simulates dcache hit latency).
  logic [1:0] table_read_cnt_q, table_read_cnt_d;

  // Latched ecalli imm and PC captured at IDLE→DRAINED transition.
  logic [31:0]              ecalli_imm_lat_q,  ecalli_imm_lat_d;
  logic [CVA6Cfg.VLEN-1:0] ecalli_pc_lat_q,   ecalli_pc_lat_d;

  // handler_addr is declared after the CSR storage registers (below) since it
  // references pevent_table_base_q which must be declared first.

  // ---------------------------------------------------------------------------
  // PVM CSR storage registers
  // ---------------------------------------------------------------------------
  // pcause  (analogous to mcause):  exception cause code written on trap.
  logic [CVA6Cfg.XLEN-1:0] pcause_q,            pcause_d;
  // pepc    (analogous to mepc):    PC of the instruction that caused the trap.
  logic [CVA6Cfg.VLEN-1:0] pepc_q,              pepc_d;
  // pstatus (analogous to mstatus): minimal status — privilege bit + IE + PIE.
  //   Bit layout (matches RISC-V mstatus subset we keep):
  //     [3]  MIE  — machine interrupt enable
  //     [7]  MPIE — previous MIE (saved on trap)
  //     [12:11] MPP — previous privilege level (2 bits)
  //   All other bits are WPRI (writes ignored, reads zero).
  logic [CVA6Cfg.XLEN-1:0] pstatus_q,           pstatus_d;
  // pevent_table_base: pointer to the ecalli handler dispatch table (ADR-5).
  logic [CVA6Cfg.XLEN-1:0] pevent_table_base_q, pevent_table_base_d;
  // pcycle: free-running 64-bit cycle counter.  Always increments; wraps.
  //   pgas  reads-as-zero per ADR-2 (no register storage needed).
  logic [63:0]              pcycle_q;

  // Computed handler target: pevent_table_base + 8 * imm.
  // MVP: used directly as redirect target (no memory indirection; see note).
  logic [CVA6Cfg.VLEN-1:0] handler_addr;
  assign handler_addr = CVA6Cfg.VLEN'(pevent_table_base_q +
                        {{CVA6Cfg.XLEN-35{1'b0}}, ecalli_imm_lat_q, 3'b000});

  // ---------------------------------------------------------------------------
  // Internal control signals
  // ---------------------------------------------------------------------------
  logic csr_we, csr_read;
  logic [CVA6Cfg.XLEN-1:0] csr_wdata, csr_rdata;
  logic read_access_exception, update_access_exception;
  logic mret;   // ecalli mode_return sentinel (maps to eret/epc restore)
  logic priv_update;
  riscv::priv_lvl_t priv_lvl_q, priv_lvl_d;

  // Detect ecalli sentinel immediates from the commit instruction.
  // commit_instr_i.result carries the ecalli immediate in the CVA6 pipeline
  // (the commit stage places the CSR write-data = ecalli imm in csr_wdata_i
  //  when op == ECALLI; that path is sub-phase 8).  For sub-phase 2 we just
  // wire the sentinel detectors so they elaborate; they drive FSM inputs that
  // are not yet connected to real state transitions.
  logic ecalli_mode_return_detected;
  logic ecalli_read_csr_detected;

  assign ecalli_mode_return_detected = (csr_wdata_i == PVM_ECALLI_SENTINEL_MODE_RETURN);
  assign ecalli_read_csr_detected    = (csr_wdata_i == PVM_ECALLI_SENTINEL_READ_CSR);

  // ---------------------------------------------------------------------------
  // pcycle: free-running counter, always increments (no inhibit in MVP)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pcycle_q <= '0;
    end else begin
      pcycle_q <= pcycle_q + 64'd1;
    end
  end

  // ---------------------------------------------------------------------------
  // ecalli FSM registers (sub-phase 8)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ecalli_state_q    <= ECALLI_IDLE;
      table_read_cnt_q  <= 2'd0;
      ecalli_imm_lat_q  <= '0;
      ecalli_pc_lat_q   <= '0;
    end else begin
      ecalli_state_q    <= ecalli_state_d;
      table_read_cnt_q  <= table_read_cnt_d;
      ecalli_imm_lat_q  <= ecalli_imm_lat_d;
      ecalli_pc_lat_q   <= ecalli_pc_lat_d;
    end
  end

  // ---------------------------------------------------------------------------
  // ecalli FSM next-state + output logic (sub-phase 8)
  // ---------------------------------------------------------------------------
  // ecalli_done_o is a 1-cycle pulse when the FSM completes, either:
  //   - immediately (sentinel path: mode_return / read_csr), or
  //   - after JUMPED (non-sentinel path: handler dispatch).
  // ecalli_redirect_pc_o / ecalli_redirect_priv_o carry the new PC/priv
  // and are valid in the same cycle as ecalli_done_o.
  always_comb begin : ecalli_fsm_next
    // Defaults — hold current values, no outputs
    ecalli_state_d     = ecalli_state_q;
    table_read_cnt_d   = table_read_cnt_q;
    ecalli_imm_lat_d   = ecalli_imm_lat_q;
    ecalli_pc_lat_d    = ecalli_pc_lat_q;
    ecalli_done_o          = 1'b0;
    ecalli_redirect_pc_o   = pepc_q;
    ecalli_redirect_priv_o = priv_lvl_q;

    unique case (ecalli_state_q)

      // ----------------------------------------------------------------------
      // IDLE: wait for commit_stage to signal an ecalli retire.
      // Sentinel imms (mode_return, read_csr) are handled immediately here
      // (single-cycle) and never leave IDLE.  Non-sentinel imms start the
      // handler-dispatch sequence (IDLE→DRAINED→TABLE_READ→JUMPED).
      // ----------------------------------------------------------------------
      ECALLI_IDLE: begin
        if (ecalli_valid_i) begin
          if (ecalli_imm_i == PVM_ECALLI_SENTINEL_MODE_RETURN) begin
            // mode_return (0xFFFFFFFF): restore PC and priv from saved state.
            // The mret path in csr_write_process already updates pstatus/priv;
            // here we just emit the redirect pulse immediately (1-cycle).
            ecalli_done_o          = 1'b1;
            ecalli_redirect_pc_o   = pepc_q;
            ecalli_redirect_priv_o = riscv::priv_lvl_t'(pstatus_q[12:11]);
            // Stay in IDLE.
          end else if (ecalli_imm_i == PVM_ECALLI_SENTINEL_READ_CSR) begin
            // read_csr (0xFFFFFFFE): the CSR value is already returned via
            // csr_rdata_o by the standard CSR-read path in csr_op_decode.
            // No mode change; emit done immediately.
            ecalli_done_o          = 1'b1;
            ecalli_redirect_pc_o   = CVA6Cfg.VLEN'(ecalli_pc_i + CVA6Cfg.VLEN'(2));
            ecalli_redirect_priv_o = priv_lvl_q;
            // Stay in IDLE.
          end else begin
            // Non-sentinel: start handler-dispatch sequence.
            ecalli_imm_lat_d = ecalli_imm_i;
            ecalli_pc_lat_d  = ecalli_pc_i;
            ecalli_state_d   = ECALLI_DRAINED;
          end
        end
      end

      // ----------------------------------------------------------------------
      // DRAINED: the pipeline has been stalled by commit_stage (commit_ack=0).
      // In this cycle:
      //   • Snapshot pepc = ecalli_pc + 1 (ecalli is 2-byte; point past it).
      //   • Snapshot pstatus.MPP = current priv.
      //   • Switch priv to U-mode (handler runs at U-mode in PVM model).
      //   • Start 3-cycle TABLE_READ timer.
      // Note: pepc/pstatus writes happen in csr_write_process via the
      //   snapshot signals below; here we just drive them combinatorially
      //   through pepc_d/pstatus_d in the write process block.
      // ----------------------------------------------------------------------
      ECALLI_DRAINED: begin
        table_read_cnt_d = 2'd0;
        ecalli_state_d   = ECALLI_TABLE_READ;
      end

      // ----------------------------------------------------------------------
      // TABLE_READ: count 3 cycles, then produce the redirect.
      // In MVP, handler_addr = pevent_table_base + 8 * imm (direct, no load).
      // ----------------------------------------------------------------------
      ECALLI_TABLE_READ: begin
        if (table_read_cnt_q == 2'd2) begin
          // Timer expired → move to JUMPED.
          ecalli_state_d = ECALLI_JUMPED;
        end else begin
          table_read_cnt_d = table_read_cnt_q + 2'd1;
        end
      end

      // ----------------------------------------------------------------------
      // JUMPED: emit 1-cycle redirect pulse, then return to IDLE.
      // Redirect to handler_addr at U-mode.
      // ----------------------------------------------------------------------
      ECALLI_JUMPED: begin
        ecalli_done_o          = 1'b1;
        ecalli_redirect_pc_o   = handler_addr;
        ecalli_redirect_priv_o = riscv::PRIV_LVL_U;
        ecalli_state_d         = ECALLI_IDLE;
      end

      default: ecalli_state_d = ECALLI_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // CSR read/write control decode (mirrors legacy csr_regfile shape)
  // ---------------------------------------------------------------------------
  always_comb begin : csr_op_decode
    csr_wdata = csr_wdata_i;
    csr_we    = 1'b1;
    csr_read  = 1'b1;
    mret      = 1'b0;

    unique case (csr_op_i)
      CSR_WRITE: csr_wdata = csr_wdata_i;
      CSR_SET:   csr_wdata = csr_wdata_i | csr_rdata;
      CSR_CLEAR: csr_wdata = (~csr_wdata_i) & csr_rdata;
      CSR_READ:  csr_we    = 1'b0;
      MRET: begin
        csr_we   = 1'b0;
        csr_read = 1'b0;
        mret     = 1'b1;
      end
      default: begin
        csr_we   = 1'b0;
        csr_read = 1'b0;
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // CSR read multiplexer
  // ---------------------------------------------------------------------------
  always_comb begin : csr_read_process
    read_access_exception = 1'b0;
    csr_rdata             = '0;
    perf_addr_o           = csr_addr_i;

    if (csr_read) begin
      unique case (pvm_csr_addr_t'(csr_addr_i))
        PVM_CSR_PSTATUS:           csr_rdata = pstatus_q;
        PVM_CSR_PEVENT_TABLE_BASE: csr_rdata = pevent_table_base_q;
        PVM_CSR_PCYCLE: begin
          // 64-bit counter; return full 64-bit value on RV64.
          csr_rdata = CVA6Cfg.XLEN'(pcycle_q);
        end
        PVM_CSR_PEPC:              csr_rdata = CVA6Cfg.XLEN'(pepc_q);
        PVM_CSR_PCAUSE:            csr_rdata = pcause_q;
        PVM_CSR_PGAS:              csr_rdata = '0;  // reads-as-zero per ADR-2
        default:                   read_access_exception = 1'b1;
      endcase
    end
  end

  assign csr_rdata_o = csr_rdata;

  // ---------------------------------------------------------------------------
  // CSR write logic + trap handling
  // ---------------------------------------------------------------------------
  always_comb begin : csr_write_process
    update_access_exception  = 1'b0;
    pcause_d                 = pcause_q;
    pepc_d                   = pepc_q;
    pstatus_d                = pstatus_q;
    pevent_table_base_d      = pevent_table_base_q;
    priv_lvl_d               = priv_lvl_q;
    flush_o                  = 1'b0;
    eret_o                   = 1'b0;

    // ------------------------------------------------------------------
    // ecalli DRAINED: snapshot pepc and pstatus when entering S-mode handler
    // ------------------------------------------------------------------
    // When FSM transitions IDLE→DRAINED we capture the return PC and mode.
    // pepc = ecalli_pc + 2 (ecalli is a 2-byte instruction in JAM v1 encoding;
    //   the next instruction byte offset is +2).  priv switches to U-mode
    //   (handler runs unprivileged in PVM model per ADR-5).
    if (ecalli_state_q == ECALLI_DRAINED) begin
      // Save return address: PC past the ecalli instruction (+2 bytes).
      pepc_d            = CVA6Cfg.VLEN'(ecalli_pc_lat_q + CVA6Cfg.VLEN'(2));
      // Save current privilege level in MPP so mode_return can restore it.
      pstatus_d[12:11]  = priv_lvl_q;   // MPP ← caller's priv
      pstatus_d[7]      = pstatus_q[3]; // MPIE ← MIE
      pstatus_d[3]      = 1'b0;         // MIE ← 0
      // Switch to U-mode for handler execution.
      priv_lvl_d        = riscv::PRIV_LVL_U;
    end

    // ------------------------------------------------------------------
    // ecalli mode_return sentinel (0xFFFFFFFF):
    // Detected by commit_stage via ecalli_mode_return_detected; it drives
    // mret=1 so the standard mret path below handles register restore.
    // Additionally we immediately emit ecalli_done_o (see FSM IDLE arm).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Trap: take exception from commit stage
    // ------------------------------------------------------------------
    if (ex_i.valid) begin
      // Save PC of faulting instruction into pepc.
      pepc_d   = ex_i.tval[CVA6Cfg.VLEN-1:0];  // tval holds faulting VA/PC
      // Save cause.
      pcause_d = ex_i.cause;
      // Save current privilege into pstatus.mpp, clear IE, save PIE.
      //   pstatus bit layout:  [3]=MIE  [7]=MPIE  [12:11]=MPP
      pstatus_d[7]     = pstatus_q[3];   // MPIE ← MIE
      pstatus_d[3]     = 1'b0;           // MIE  ← 0 (disable interrupts)
      pstatus_d[12:11] = priv_lvl_q;     // MPP  ← current priv
      // Switch to M-mode on trap (PVM S-mode is represented as M-mode
      // in the underlying CVA6 pipeline; sub-phase 9 refines this).
      priv_lvl_d = riscv::PRIV_LVL_M;
    end

    // ------------------------------------------------------------------
    // mret / mode_return: restore saved state
    // ------------------------------------------------------------------
    if (mret) begin
      eret_o         = 1'b1;
      // Restore MIE from MPIE; set MPIE=1; restore priv from MPP.
      pstatus_d[3]   = pstatus_q[7];     // MIE  ← MPIE
      pstatus_d[7]   = 1'b1;             // MPIE ← 1
      priv_lvl_d     = riscv::priv_lvl_t'(pstatus_q[12:11]);
    end

    // ------------------------------------------------------------------
    // Explicit CSR writes
    // ------------------------------------------------------------------
    if (csr_we) begin
      unique case (pvm_csr_addr_t'(csr_addr_i))
        PVM_CSR_PSTATUS: begin
          // Only writable fields: MIE[3], MPIE[7], MPP[12:11].
          // WPRI bits are silently ignored.
          pstatus_d[3]     = csr_wdata[3];
          pstatus_d[7]     = csr_wdata[7];
          pstatus_d[12:11] = csr_wdata[12:11];
          flush_o          = 1'b1;
        end
        PVM_CSR_PEVENT_TABLE_BASE: begin
          pevent_table_base_d = csr_wdata;
          flush_o             = 1'b1;
        end
        PVM_CSR_PCYCLE: begin
          // pcycle is read-only in the MVP (free-running).
          update_access_exception = 1'b1;
        end
        PVM_CSR_PEPC: begin
          pepc_d = csr_wdata[CVA6Cfg.VLEN-1:0];
        end
        PVM_CSR_PCAUSE: begin
          pcause_d = csr_wdata;
        end
        PVM_CSR_PGAS: begin
          // pgas is read-only (reads-as-zero per ADR-2).
          update_access_exception = 1'b1;
        end
        default: begin
          update_access_exception = 1'b1;
        end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // CSR exception output
  // ---------------------------------------------------------------------------
  always_comb begin : exception_ctrl
    csr_exception_o = {
      {CVA6Cfg.XLEN{1'b0}}, {CVA6Cfg.XLEN{1'b0}},
      {CVA6Cfg.GPLEN{1'b0}}, {32{1'b0}}, 1'b0, 1'b0
    };
    if (update_access_exception || read_access_exception) begin
      csr_exception_o.cause = riscv::ILLEGAL_INSTR;
      csr_exception_o.valid = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Privilege level register
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      priv_lvl_q <= riscv::PRIV_LVL_M;
    end else begin
      priv_lvl_q <= priv_lvl_d;
    end
  end

  // ---------------------------------------------------------------------------
  // PVM CSR sequential update
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pcause_q            <= '0;
      pepc_q              <= '0;
      pstatus_q           <= '0;
      pevent_table_base_q <= CVA6Cfg.XLEN'(boot_addr_i);
    end else begin
      pcause_q            <= pcause_d;
      pepc_q              <= pepc_d;
      pstatus_q           <= pstatus_d;
      pevent_table_base_q <= pevent_table_base_d;
    end
  end

  // ---------------------------------------------------------------------------
  // Output assignments
  // ---------------------------------------------------------------------------

  // Core outputs used by the pipeline
  assign priv_lvl_o         = priv_lvl_q;
  assign epc_o              = pepc_q;
  assign trap_vector_base_o = pevent_table_base_q;
  assign halt_csr_o         = 1'b0;

  // Privilege / translation outputs — no MMU in PVM MVP
  assign en_translation_o        = 1'b0;
  assign en_g_translation_o      = 1'b0;
  assign en_ld_st_translation_o  = 1'b0;
  assign en_ld_st_g_translation_o= 1'b0;
  assign ld_st_priv_lvl_o        = priv_lvl_q;
  assign ld_st_v_o               = 1'b0;
  assign sum_o                   = 1'b0;
  assign vs_sum_o                = 1'b0;
  assign mxr_o                   = 1'b0;
  assign vmxr_o                  = 1'b0;
  assign satp_ppn_o              = '0;
  assign asid_o                  = '0;
  assign vsatp_ppn_o             = '0;
  assign vs_asid_o               = '0;
  assign hgatp_ppn_o             = '0;
  assign vmid_o                  = '0;
  assign v_o                     = 1'b0;
  assign mbe_o                   = 1'b0;

  // FP / Vector — Off in PVM (no FP extension)
  assign fs_o    = riscv::Off;
  assign vfs_o   = riscv::Off;
  assign vs_o    = riscv::Off;
  assign fflags_o= '0;
  assign frm_o   = '0;
  assign fprec_o = '0;

  // IRQ control: wire MIE and MIP from pstatus; no delegation in MVP.
  // Sub-phase 8 completes the interrupt path.
  assign irq_ctrl_o.mie          = {CVA6Cfg.XLEN{1'b0}};
  assign irq_ctrl_o.mip          = {CVA6Cfg.XLEN{1'b0}};
  assign irq_ctrl_o.sie          = 1'b0;
  assign irq_ctrl_o.mideleg      = '0;
  assign irq_ctrl_o.hideleg      = '0;
  assign irq_ctrl_o.global_enable= pstatus_q[3];  // MIE bit

  // Cache: always enabled
  assign icache_en_o  = 1'b1;
  assign dcache_en_o  = 1'b1;
  assign acc_cons_en_o= 1'b0;

  // PMP: all zeroed (no PMP in PVM MVP)
  assign pmpcfg_o  = '0;
  assign pmpaddr_o = '0;

  // Performance counter interface: stub
  assign perf_data_o       = '0;
  assign perf_we_o         = 1'b0;
  assign mcountinhibit_o   = '0;

  // Debug / trigger: unused in PVM MVP
  assign set_debug_pc_o    = 1'b0;
  assign debug_mode_o      = 1'b0;
  assign single_step_o     = 1'b0;
  assign tvm_o             = 1'b0;
  assign tw_o              = 1'b0;
  assign vtw_o             = 1'b0;
  assign tsr_o             = 1'b0;
  assign hu_o              = 1'b0;
  assign debug_from_trigger_o = 1'b0;
  assign break_from_trigger_o = 1'b0;

  // CBO: unused in PVM (ILLEGAL = 2'b00 means lower-mode CBO.INVAL is illegal)
  assign mcbie_o  = riscv::CBIE_ILLEGAL;
  assign scbie_o  = riscv::CBIE_ILLEGAL;
  assign hcbie_o  = riscv::CBIE_ILLEGAL;
  assign mcbcfe_o = 1'b0;
  assign scbcfe_o = 1'b0;
  assign hcbcfe_o = 1'b0;

  // JVT: unused in PVM
  assign jvt_o = '0;

  // RVFI: driven to zero; sub-phase 6 re-targets the tracer for PVM.
  assign rvfi_csr_o = '0;

endmodule
