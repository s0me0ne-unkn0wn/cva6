// pvm_csr_tb.sv — Standalone testbench for pvm_csr_regfile.
// Phase 4 sub-phase 7.
//
// Provides explicit struct definitions matching cva6.sv parameter types so
// the DUT elaborates with proper field access.  Only the CSR-facing ports
// (csr_op_i, csr_addr_i, csr_wdata_i, csr_rdata_o) are actively driven;
// all other ports receive safe-constant tie-offs.
//
// Tests:
//   T1: Write pcause  = 0xDEAD_BEEF_0000_0001, read back, expect match.
//   T2: Write pepc    = 0xDEAD_BEEF_0000_0002, read back, expect match.
//   T3: Write pstatus MIE/MPIE/MPP fields, read back, expect mask match.
//   T4: Write pevent_table_base = 0x0000_0000_DEAD_0000, read back.
//   T5: Read pgas, expect 0 (ADR-2: reads-as-zero).
//   T6: Read pcycle twice (4 cycles apart), expect strictly increasing.
//
// PASS = all 6 vectors match.
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

module pvm_csr_tb;
  import ariane_pkg::*;
  import polkavm_pkg::*;

  // -----------------------------------------------------------------------
  // Config (resolved at elaboration time from the package)
  // -----------------------------------------------------------------------
  localparam config_pkg::cva6_cfg_t DUT_CFG = build_config_pkg::build_config(
      cva6_config_pkg::cva6_cfg
  );

  // Derived widths
  localparam int XLEN          = DUT_CFG.XLEN;
  localparam int VLEN          = DUT_CFG.VLEN;
  localparam int TRANS_ID_BITS = DUT_CFG.TRANS_ID_BITS;
  localparam int PPNW          = DUT_CFG.PPNW;
  localparam int ASID_WIDTH    = DUT_CFG.ASID_WIDTH;
  localparam int VMID_WIDTH    = DUT_CFG.VMID_WIDTH;
  localparam int GPLEN         = DUT_CFG.GPLEN;
  localparam int PLEN          = DUT_CFG.PLEN;
  localparam int NrPMPEntries  = DUT_CFG.NrPMPEntries;
  localparam int NrCommitPorts = DUT_CFG.NrCommitPorts;
  localparam int NrIssuePorts  = DUT_CFG.NrIssuePorts;

  // -----------------------------------------------------------------------
  // Type definitions mirroring cva6.sv parameter defaults
  // -----------------------------------------------------------------------

  // exception_t
  typedef struct packed {
    logic [XLEN-1:0]  cause;
    logic [XLEN-1:0]  tval;
    logic [GPLEN-1:0] tval2;
    logic [31:0]      tinst;
    logic             gva;
    logic             valid;
  } tb_exception_t;

  // branchpredict_sbe_t (needed inside scoreboard_entry_t)
  typedef struct packed {
    cf_t              cf;
    logic [VLEN-1:0]  predict_address;
  } tb_branchpredict_sbe_t;

  // scoreboard_entry_t  (matches cva6.sv localparam layout exactly)
  typedef struct packed {
    logic [VLEN-1:0]          pc;
    logic [TRANS_ID_BITS-1:0] trans_id;
    fu_t                      fu;
    fu_op                     op;
    logic [REG_ADDR_SIZE-1:0] rs1;
    logic [REG_ADDR_SIZE-1:0] rs2;
    logic [REG_ADDR_SIZE-1:0] rd;
    logic [XLEN-1:0]          result;
    logic                     valid;
    logic                     use_imm;
    logic                     use_zimm;
    logic                     use_pc;
    tb_exception_t            ex;
    tb_branchpredict_sbe_t    bp;
    logic                     is_compressed;
    logic                     is_macro_instr;
    logic                     is_last_macro_instr;
    logic                     is_double_rd_macro_instr;
    logic                     vfp;
    logic                     is_zcmt;
  } tb_sbe_t;

  // jvt_t
  typedef struct packed {
    logic [XLEN-7:0] base;
    logic [5:0]      mode;
  } tb_jvt_t;

  // irq_ctrl_t  (matches cva6.sv localparam)
  typedef struct packed {
    logic [XLEN-1:0] mie;
    logic [XLEN-1:0] mip;
    logic            sie;
    logic [XLEN-1:0] mideleg;
    logic [XLEN-1:0] hideleg;
    logic            global_enable;
  } tb_irq_ctrl_t;

  // rvfi_probes_csr_t — use 1-bit logic stub; DUT assigns '0 to this output.
  typedef logic tb_rvfi_probes_csr_t;

  // -----------------------------------------------------------------------
  // Clock / reset
  // -----------------------------------------------------------------------
  logic clk;
  logic rst_n;

  initial clk = 1'b0;
  always #5 clk = ~clk;  // 100 MHz

  // -----------------------------------------------------------------------
  // DUT port signals
  // -----------------------------------------------------------------------
  // Active ports
  logic                        time_irq           = '0;
  tb_sbe_t                     commit_instr        = '0;
  logic [NrCommitPorts-1:0]    commit_ack          = '0;
  logic [VLEN-1:0]             boot_addr           = 64'h8000_0000;
  logic [XLEN-1:0]             hart_id             = '0;
  tb_exception_t               ex_in               = '0;
  fu_op                        csr_op              = ADD;
  logic [11:0]                 csr_addr            = '0;
  logic [XLEN-1:0]             csr_wdata           = '0;
  logic                        dirty_fp_state      = '0;
  logic                        csr_write_fflags    = '0;
  logic                        dirty_v_state       = '0;
  logic [VLEN-1:0]             pc_in               = '0;
  logic [4:0]                  acc_fflags_ex       = '0;
  logic                        acc_fflags_ex_valid = '0;
  logic [1:0]                  irq_in              = '0;
  logic                        ipi_in              = '0;
  logic                        debug_req_in        = '0;
  logic                        csr_hs_ld_st_inst   = '0;
  logic [XLEN-1:0]             perf_data_in        = '0;
  logic [VLEN-1:0]             vaddr_from_lsu      = '0;
  logic [NrIssuePorts-1:0][31:0] orig_instr        = '0;
  logic [XLEN-1:0]             store_result        = '0;

  // Monitored output
  logic [XLEN-1:0]             csr_rdata_out;

  // Ignored outputs
  logic                        flush_out, halt_csr_out, eret_out;
  tb_exception_t               csr_exception_out;
  logic [VLEN-1:0]             epc_out, trap_vector_base_out;
  riscv::priv_lvl_t            priv_lvl_out, ld_st_priv_lvl_out;
  logic                        mbe_out, v_out;
  riscv::xs_t                  fs_out, vfs_out, vs_out;
  logic [4:0]                  fflags_out;
  logic [2:0]                  frm_out;
  logic [6:0]                  fprec_out;
  tb_irq_ctrl_t                irq_ctrl_out;
  logic                        en_translation_out, en_g_translation_out;
  logic                        en_ld_st_translation_out, en_ld_st_g_translation_out;
  logic                        ld_st_v_out, sum_out, vs_sum_out, mxr_out, vmxr_out;
  logic [PPNW-1:0]             satp_ppn_out, vsatp_ppn_out, hgatp_ppn_out;
  logic [ASID_WIDTH-1:0]       asid_out, vs_asid_out;
  logic [VMID_WIDTH-1:0]       vmid_out;
  riscv::cbie_t                mcbie_out, scbie_out, hcbie_out;
  logic                        mcbcfe_out, scbcfe_out, hcbcfe_out;
  logic                        set_debug_pc_out, tvm_out, tw_out, vtw_out;
  logic                        tsr_out, hu_out, debug_mode_out, single_step_out;
  logic                        icache_en_out, dcache_en_out, acc_cons_en_out;
  logic [11:0]                 perf_addr_out;
  logic [XLEN-1:0]             perf_data_out;
  logic                        perf_we_out;
  riscv::pmpcfg_t [avoid_neg(NrPMPEntries-1):0] pmpcfg_out;
  logic [avoid_neg(NrPMPEntries-1):0][PLEN-3:0] pmpaddr_out;
  logic [31:0]                 mcountinhibit_out;
  tb_rvfi_probes_csr_t         rvfi_csr_out;
  tb_jvt_t                     jvt_out;
  logic                        debug_from_trigger_out, break_from_trigger_out;

  // -----------------------------------------------------------------------
  // DUT instantiation
  // -----------------------------------------------------------------------
  pvm_csr_regfile #(
      .CVA6Cfg           (DUT_CFG),
      .exception_t       (tb_exception_t),
      .jvt_t             (tb_jvt_t),
      .irq_ctrl_t        (tb_irq_ctrl_t),
      .scoreboard_entry_t(tb_sbe_t),
      .rvfi_probes_csr_t (tb_rvfi_probes_csr_t),
      .MHPMCounterNum    (6)
  ) dut (
      .clk_i                   (clk),
      .rst_ni                  (rst_n),
      .time_irq_i              (time_irq),
      .flush_o                 (flush_out),
      .halt_csr_o              (halt_csr_out),
      .commit_instr_i          (commit_instr),
      .commit_ack_i            (commit_ack),
      .boot_addr_i             (boot_addr),
      .hart_id_i               (hart_id),
      .ex_i                    (ex_in),
      .csr_op_i                (csr_op),
      .csr_addr_i              (csr_addr),
      .csr_wdata_i             (csr_wdata),
      .csr_rdata_o             (csr_rdata_out),
      .dirty_fp_state_i        (dirty_fp_state),
      .csr_write_fflags_i      (csr_write_fflags),
      .dirty_v_state_i         (dirty_v_state),
      .pc_i                    (pc_in),
      .csr_exception_o         (csr_exception_out),
      .epc_o                   (epc_out),
      .eret_o                  (eret_out),
      .trap_vector_base_o      (trap_vector_base_out),
      .priv_lvl_o              (priv_lvl_out),
      .mbe_o                   (mbe_out),
      .v_o                     (v_out),
      .acc_fflags_ex_i         (acc_fflags_ex),
      .acc_fflags_ex_valid_i   (acc_fflags_ex_valid),
      .fs_o                    (fs_out),
      .vfs_o                   (vfs_out),
      .fflags_o                (fflags_out),
      .frm_o                   (frm_out),
      .fprec_o                 (fprec_out),
      .vs_o                    (vs_out),
      .irq_ctrl_o              (irq_ctrl_out),
      .en_translation_o        (en_translation_out),
      .en_g_translation_o      (en_g_translation_out),
      .en_ld_st_translation_o  (en_ld_st_translation_out),
      .en_ld_st_g_translation_o(en_ld_st_g_translation_out),
      .ld_st_priv_lvl_o        (ld_st_priv_lvl_out),
      .ld_st_v_o               (ld_st_v_out),
      .csr_hs_ld_st_inst_i     (csr_hs_ld_st_inst),
      .sum_o                   (sum_out),
      .vs_sum_o                (vs_sum_out),
      .mxr_o                   (mxr_out),
      .vmxr_o                  (vmxr_out),
      .satp_ppn_o              (satp_ppn_out),
      .asid_o                  (asid_out),
      .vsatp_ppn_o             (vsatp_ppn_out),
      .vs_asid_o               (vs_asid_out),
      .hgatp_ppn_o             (hgatp_ppn_out),
      .vmid_o                  (vmid_out),
      .irq_i                   (irq_in),
      .ipi_i                   (ipi_in),
      .debug_req_i             (debug_req_in),
      .set_debug_pc_o          (set_debug_pc_out),
      .tvm_o                   (tvm_out),
      .tw_o                    (tw_out),
      .vtw_o                   (vtw_out),
      .tsr_o                   (tsr_out),
      .hu_o                    (hu_out),
      .debug_mode_o            (debug_mode_out),
      .single_step_o           (single_step_out),
      .icache_en_o             (icache_en_out),
      .dcache_en_o             (dcache_en_out),
      .acc_cons_en_o           (acc_cons_en_out),
      .perf_addr_o             (perf_addr_out),
      .perf_data_o             (perf_data_out),
      .perf_data_i             (perf_data_in),
      .perf_we_o               (perf_we_out),
      .pmpcfg_o                (pmpcfg_out),
      .pmpaddr_o               (pmpaddr_out),
      .mcountinhibit_o         (mcountinhibit_out),
      .rvfi_csr_o              (rvfi_csr_out),
      .jvt_o                   (jvt_out),
      .debug_from_trigger_o    (debug_from_trigger_out),
      .vaddr_from_lsu_i        (vaddr_from_lsu),
      .orig_instr_i            (orig_instr),
      .store_result_i          (store_result),
      .break_from_trigger_o    (break_from_trigger_out),
      .mcbie_o                 (mcbie_out),
      .scbie_o                 (scbie_out),
      .hcbie_o                 (hcbie_out),
      .mcbcfe_o                (mcbcfe_out),
      .scbcfe_o                (scbcfe_out),
      .hcbcfe_o                (hcbcfe_out)
  );

  // -----------------------------------------------------------------------
  // Helper tasks
  // -----------------------------------------------------------------------
  // Issue a CSR write, clock one posedge, return to NOP
  task automatic do_csr_write(
    input logic [11:0] addr,
    input logic [63:0] data
  );
    @(negedge clk);
    csr_addr  = addr;
    csr_wdata = XLEN'(data);
    csr_op    = CSR_WRITE;
    @(posedge clk); #1;
    csr_op    = ADD;
  endtask

  // Issue a CSR read (combinational), capture rdata
  task automatic do_csr_read(
    input  logic [11:0]  addr,
    output logic [63:0]  rdata
  );
    @(negedge clk);
    csr_addr = addr;
    csr_op   = CSR_READ;
    #1;
    rdata    = 64'(csr_rdata_out);
    @(negedge clk);
    csr_op   = ADD;
  endtask

  // -----------------------------------------------------------------------
  // Stimulus + checker
  // -----------------------------------------------------------------------
  int  pass_count;
  int  fail_count;
  logic [63:0] rd_val;
  logic [63:0] cycle_a, cycle_b;

  initial begin
    rst_n      = 1'b0;
    pass_count = 0;
    fail_count = 0;

    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ------------------------------------------------------------------
    // T1: pcause write / read
    // ------------------------------------------------------------------
    do_csr_write(PVM_CSR_PCAUSE, 64'hDEAD_BEEF_0000_0001);
    do_csr_read(PVM_CSR_PCAUSE, rd_val);
    if (rd_val === 64'hDEAD_BEEF_0000_0001) begin
      $display("PASS T1: pcause = 0x%016h", rd_val);
      pass_count++;
    end else begin
      $display("FAIL T1: pcause = 0x%016h  expected 0xDEADBEEF00000001", rd_val);
      fail_count++;
    end

    // ------------------------------------------------------------------
    // T2: pepc write / read
    // ------------------------------------------------------------------
    do_csr_write(PVM_CSR_PEPC, 64'hDEAD_BEEF_0000_0002);
    do_csr_read(PVM_CSR_PEPC, rd_val);
    if (rd_val === 64'hDEAD_BEEF_0000_0002) begin
      $display("PASS T2: pepc = 0x%016h", rd_val);
      pass_count++;
    end else begin
      $display("FAIL T2: pepc = 0x%016h  expected 0xDEADBEEF00000002", rd_val);
      fail_count++;
    end

    // ------------------------------------------------------------------
    // T3: pstatus write (MIE[3]=1, MPIE[7]=1, MPP[12:11]=2'b11) / read
    //     Only bits [3],[7],[12:11] are architecturally writable.
    // ------------------------------------------------------------------
    do_csr_write(PVM_CSR_PSTATUS, 64'h0000_0000_0000_1888);
    do_csr_read(PVM_CSR_PSTATUS, rd_val);
    if ((rd_val & 64'h1888) === 64'h1888) begin
      $display("PASS T3: pstatus = 0x%016h  (MIE/MPIE/MPP bits set)", rd_val);
      pass_count++;
    end else begin
      $display("FAIL T3: pstatus = 0x%016h  expected bits [3,7,12:11] set", rd_val);
      fail_count++;
    end

    // ------------------------------------------------------------------
    // T4: pevent_table_base write / read
    // ------------------------------------------------------------------
    do_csr_write(PVM_CSR_PEVENT_TABLE_BASE, 64'h0000_0000_DEAD_0000);
    do_csr_read(PVM_CSR_PEVENT_TABLE_BASE, rd_val);
    if (rd_val === 64'h0000_0000_DEAD_0000) begin
      $display("PASS T4: pevent_table_base = 0x%016h", rd_val);
      pass_count++;
    end else begin
      $display("FAIL T4: pevent_table_base = 0x%016h  expected 0x00000000DEAD0000", rd_val);
      fail_count++;
    end

    // ------------------------------------------------------------------
    // T5: pgas reads-as-zero (ADR-2)
    // ------------------------------------------------------------------
    do_csr_read(PVM_CSR_PGAS, rd_val);
    if (rd_val === 64'h0) begin
      $display("PASS T5: pgas = 0x%016h  (reads-as-zero per ADR-2)", rd_val);
      pass_count++;
    end else begin
      $display("FAIL T5: pgas = 0x%016h  expected 0", rd_val);
      fail_count++;
    end

    // ------------------------------------------------------------------
    // T6: pcycle monotonically increasing
    // ------------------------------------------------------------------
    do_csr_read(PVM_CSR_PCYCLE, cycle_a);
    repeat (4) @(posedge clk);
    do_csr_read(PVM_CSR_PCYCLE, cycle_b);
    if (cycle_b > cycle_a && cycle_a > 0) begin
      $display("PASS T6: pcycle monotone  %0d -> %0d", cycle_a, cycle_b);
      pass_count++;
    end else begin
      $display("FAIL T6: pcycle  first=%0d  second=%0d  (expected second > first > 0)",
               cycle_a, cycle_b);
      fail_count++;
    end

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    $display("----------------------------------------------");
    $display("pvm_csr_tb: %0d PASS / %0d FAIL", pass_count, fail_count);
    if (fail_count == 0) $display("RESULT: ALL PASS");
    else $display("RESULT: FAIL");
    $display("----------------------------------------------");
    $finish;
  end

  // Timeout guard
  initial begin
    #500000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
