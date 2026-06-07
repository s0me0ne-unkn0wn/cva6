// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 05.05.2017
// Description: CSR Register File as specified by RISC-V


module csr_regfile
  import ariane_pkg::*;
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
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Timer threw an interrupt - SUBSYSTEM
    input logic time_irq_i,
    // send a flush request out when a CSR with a side effect changes - CONTROLLER
    output logic flush_o,
    // halt requested - CONTROLLER
    output logic halt_csr_o,
    // Instruction to be committed - ID_STAGE
    input scoreboard_entry_t commit_instr_i,
    // Commit acknowledged an instruction -> increase instret CSR - COMMIT_STAGE
    input logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack_i,
    // Address from which to start booting, mtvec is set to the same address - SUBSYSTEM
    input logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Hart id in a multicore environment (reflected in a CSR) - SUBSYSTEM
    input logic [CVA6Cfg.XLEN-1:0] hart_id_i,
    // We've got an exception from the commit stage, take it - COMMIT_STAGE
    input exception_t ex_i,
    // Operation to perform on the CSR file - COMMIT_STAGE
    input fu_op csr_op_i,
    // Address of the register to read/write - EX_STAGE
    input logic [11:0] csr_addr_i,
    // Write data in - COMMIT_STAGE
    input logic [CVA6Cfg.XLEN-1:0] csr_wdata_i,
    // Read data out - COMMIT_STAGE
    output logic [CVA6Cfg.XLEN-1:0] csr_rdata_o,
    // Mark the FP state as dirty - COMMIT_STAGE
    input logic dirty_fp_state_i,
    // Write fflags register e.g.: we are retiring a floating point instruction - COMMIT_STAGE
    input logic csr_write_fflags_i,
    // Mark the V state as dirty - ACC_DISPATCHER
    input logic dirty_v_state_i,
    // PC of instruction accessing the CSR - COMMIT_STAGE
    input logic [CVA6Cfg.VLEN-1:0] pc_i,
    // attempts to access a CSR without appropriate privilege - COMMIT_STAGE
    output exception_t csr_exception_o,
    // Output the exception PC to PC Gen, the correct CSR (mepc, sepc) is set accordingly - FRONTEND
    output logic [CVA6Cfg.VLEN-1:0] epc_o,
    // Return from exception, set the PC of epc_o - FRONTEND
    output logic eret_o,
    // Output base of exception vector, correct CSR is output (mtvec, stvec) - FRONTEND
    output logic [CVA6Cfg.VLEN-1:0] trap_vector_base_o,
    // Current privilege level the CPU is in - EX_STAGE
    output riscv::priv_lvl_t priv_lvl_o,
    // Data Endian mode
    output logic mbe_o,
    // Current virtualization mode state the CPU is in - EX_STAGE
    output logic v_o,
    // Imprecise FP exception from the accelerator (fcsr.fflags format) - ACC_DISPATCHER
    input logic [4:0] acc_fflags_ex_i,
    // An FP exception from the accelerator occurred - ACC_DISPATCHER
    input logic acc_fflags_ex_valid_i,
    // Floating point extension status - ID_STAGE
    output riscv::xs_t fs_o,
    // Floating point extension virtual status - ID_STAGE
    output riscv::xs_t vfs_o,
    // Floating-Point Occurred Exceptions - COMMIT_STAGE
    output logic [4:0] fflags_o,
    // Floating-Point Dynamic Rounding Mode - EX_STAGE
    output logic [2:0] frm_o,
    // Floating-Point Precision Control - EX_STAGE
    output logic [6:0] fprec_o,
    // Vector extension status - ID_STAGE
    output riscv::xs_t vs_o,
    // interrupt management to id stage - ID_STAGE
    output irq_ctrl_t irq_ctrl_o,
    // Enable virtual address translation - EX_STAGE
    output logic en_translation_o,
    // Enable G-Stage address translation - EX_STAGE
    output logic en_g_translation_o,
    // Enable virtual address translation for load and stores - EX_STAGE
    output logic en_ld_st_translation_o,
    // Enable G-Stage address translation for load and stores - EX_STAGE
    output logic en_ld_st_g_translation_o,
    // Privilege level at which load and stores should happen - EX_STAGE
    output riscv::priv_lvl_t ld_st_priv_lvl_o,
    // Virtualization mode at which load and stores should happen - EX_STAGE
    output logic ld_st_v_o,
    // Current instruction is a Hypervisor Load/Store Instruction - EX_STAGE
    input logic csr_hs_ld_st_inst_i,
    // Supervisor User Memory - EX_STAGE
    output logic sum_o,
    // Virtual Supervisor User Memory - EX_STAGE
    output logic vs_sum_o,
    // Make Executable Readable - EX_STAGE
    output logic mxr_o,
    // Make Executable Readable for VS-mode - EX_STAGE
    output logic vmxr_o,
    // TO_BE_COMPLETED - EX_STAGE
    output logic [CVA6Cfg.PPNW-1:0] satp_ppn_o,
    // TO_BE_COMPLETED - EX_STAGE
    output logic [CVA6Cfg.ASID_WIDTH-1:0] asid_o,
    // TO_BE_COMPLETED - EX_STAGE
    output logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_o,
    // TO_BE_COMPLETED - EX_STAGE
    output logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_o,
    // TO_BE_COMPLETED - EX_STAGE
    output logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_o,
    // TO_BE_COMPLETED - EX_STAGE
    output logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_o,
    // machine-mode cache block invalidate enable - ID_STAGE
    output riscv::cbie_t mcbie_o,
    // supervisor-mode cache block invalidate enable - ID_STAGE
    output riscv::cbie_t scbie_o,
    // hypervisor-mode cache block invalidate enable - ID_STAGE
    output riscv::cbie_t hcbie_o,
    // machine-mode clean/flush cache block invalidate enable - ID_STAGE
    output logic mcbcfe_o,
    // supervisor-mode clean/flush cache block invalidate enable - ID_STAGE
    output logic scbcfe_o,
    // hypervisor-mode clean/flush cache block invalidate enable - ID_STAGE
    output logic hcbcfe_o,
    // external interrupt in - SUBSYSTEM
    input logic [1:0] irq_i,
    // inter processor interrupt -> connected to machine mode sw - SUBSYSTEM
    input logic ipi_i,
    // debug request in - ID_STAGE
    input logic debug_req_i,
    // TO_BE_COMPLETED - FRONTEND
    output logic set_debug_pc_o,
    // trap virtual memory - ID_STAGE
    output logic tvm_o,
    // timeout wait - ID_STAGE
    output logic tw_o,
    // virtual timeout wait - ID_STAGE
    output logic vtw_o,
    // trap sret - ID_STAGE
    output logic tsr_o,
    // hypervisor user mode - ID_STAGE
    output logic hu_o,
    // we are in debug mode -> that will change some decoding - EX_STAGE
    output logic debug_mode_o,
    // we are in single-step mode - COMMIT_STAGE
    output logic single_step_o,
    // L1 ICache Enable - CACHE
    output logic icache_en_o,
    // L1 DCache Enable - CACHE
    output logic dcache_en_o,
    // Accelerator memory consistent mode - ACC_DISPATCHER
    output logic acc_cons_en_o,
    // read/write address to performance counter module - PERF_COUNTERS
    output logic [11:0] perf_addr_o,
    // write data to performance counter module - PERF_COUNTERS
    output logic [CVA6Cfg.XLEN-1:0] perf_data_o,
    // read data from performance counter module - PERF_COUNTERS
    input logic [CVA6Cfg.XLEN-1:0] perf_data_i,
    // TO_BE_COMPLETED - PERF_COUNTERS
    output logic perf_we_o,
    // PMP configuration containing pmpcfg for max 64 PMPs - ACC_DISPATCHER
    output riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0] pmpcfg_o,
    // PMP addresses - ACC_DISPATCHER
    output logic [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_o,
    // TO_BE_COMPLETED - PERF_COUNTERS
    output logic [31:0] mcountinhibit_o,
    // RVFI
    output rvfi_probes_csr_t rvfi_csr_o,
    //jvt output
    output jvt_t jvt_o,
    // B4: route a PVM host-boundary exit (ecalli/panic) to CSR_PVM_VEC instead of mtvec
    input  logic                    pvm_use_vec_i,
    // PVM Stage 2 (skip-class trap-return): on a committed guest-internal ecalli stay-trap, capture
    // the POST-ecalli pc (next_pc-4) into mepc/sepc instead of the trapping ecalli pc, so the guest
    // M-handler's standard RISC-V `mepc += 4; mret` (sbi_ecall.c:165) lands on the instruction AFTER
    // the 2-byte PVM ecalli (the -4 absorbs the 4-vs-2 length gap). cva6 supplies value + valid,
    // gated PvmPresent & pvm_active & pvm_stay (= pvm_trap_redirect). Non-stay/non-PVM = unchanged.
    input  logic [CVA6Cfg.XLEN-1:0] pvm_epc_override_i,
    input  logic                    pvm_epc_override_valid_i,
    // PVM eret-via-JT one-shot: pulse when a JT-mapped eret (the Stage-1 M->S handoff) commits.
    // CFG2[36] (eret-via-JT) self-clears on this pulse so it maps ONLY the one-shot handoff; every
    // subsequent eret (a trap-return -- skip-class or re-execute -- whose mepc is a RAW PVM-pc, not a
    // JT token) takes the DIRECT path, even though the OpenSBI launcher leaves CFG2[36]=1 sticky. SW
    // re-arms by writing CFG2[36]=1 again (a same-cycle SW write wins). Matches the Stage-1 spec
    // intent ("self-clears after use"); without it the SBI-call return would be JT-mangled.
    input  logic                    pvm_eret_jt_consume_i,
    output logic [CVA6Cfg.XLEN-1:0] pvm_cfg0_o,
    output logic [CVA6Cfg.XLEN-1:0] pvm_cfg1_o,
    output logic [CVA6Cfg.XLEN-1:0] pvm_cfg2_o,
    output logic                    pvm_img_we_o,   // pulse: write img_mem (M1 load port)
    output logic [CVA6Cfg.XLEN-1:0] pvm_img_w_o,    // {addr, data} payload for the img write
    output logic [CVA6Cfg.XLEN-1:0] pvm_ram_o,      // B7: guest-RAM->DRAM aperture (base + page bounds)
    // trigger module signals
    output logic debug_from_trigger_o,
    input logic [CVA6Cfg.VLEN-1:0] vaddr_from_lsu_i,
    input logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    input logic [CVA6Cfg.XLEN-1:0] store_result_i,
    output logic break_from_trigger_o
);

  localparam logic [63:0] SMODE_STATUS_READ_MASK = ariane_pkg::smode_status_read_mask(CVA6Cfg);
  localparam int SELECT_COUNTER_WIDTH = CVA6Cfg.IS_XLEN64 ? 6 : 5;

  typedef struct packed {
    logic [CVA6Cfg.ModeW-1:0] mode;
    logic [CVA6Cfg.ASIDW-1:0] asid;
    logic [CVA6Cfg.PPNW-1:0]  ppn;
  } satp_t;

  // internal signal to keep track of access exceptions
  logic read_access_exception, update_access_exception, privilege_violation;
  logic csr_we, csr_read;
  logic [CVA6Cfg.XLEN-1:0] csr_wdata, csr_rdata;
  riscv::priv_lvl_t trap_to_priv_lvl;
  // register for enabling load store address translation, this is critical, hence the register
  logic en_ld_st_translation_d, en_ld_st_translation_q;
  logic mprv;
  logic mret;  // return from M-mode exception
  logic sret;  // return from S-mode exception
  logic dret;  // return from debug mode
  riscv::mstatus_rv_t mstatus_q, mstatus_d;
  logic [CVA6Cfg.XLEN-1:0] mstatus_extended;
  logic [31:0] mstatush;
  satp_t satp_q, satp_d;
  riscv::dcsr_t dcsr_q, dcsr_d;
  riscv::csr_t csr_addr;
  riscv::csr_t conv_csr_addr;
  // privilege level register
  riscv::priv_lvl_t priv_lvl_d, priv_lvl_q;
  // we are in debug
  logic debug_mode_q, debug_mode_d;
  logic mtvec_rst_load_q;  // used to determine whether we came out of reset

  logic [CVA6Cfg.XLEN-1:0] dpc_q, dpc_d;
  logic [CVA6Cfg.XLEN-1:0] dscratch0_q, dscratch0_d;
  logic [CVA6Cfg.XLEN-1:0] dscratch1_q, dscratch1_d;
  logic [CVA6Cfg.XLEN-1:0] mtvec_q, mtvec_d;
  logic [CVA6Cfg.XLEN-1:0] medeleg_q, medeleg_d;
  logic [CVA6Cfg.XLEN-1:0] mideleg_q, mideleg_d;
  logic [CVA6Cfg.XLEN-1:0] mip_q, mip_d;
  logic [CVA6Cfg.XLEN-1:0] mie_q, mie_d;
  logic [CVA6Cfg.XLEN-1:0] mcounteren_q, mcounteren_d;
  logic [CVA6Cfg.XLEN-1:0] mscratch_q, mscratch_d;
  logic [CVA6Cfg.XLEN-1:0] pvm_cfg0_q, pvm_cfg0_d;  // PolkaVM control CSR 0
  logic [CVA6Cfg.XLEN-1:0] pvm_cfg1_q, pvm_cfg1_d;  // PolkaVM control CSR 1
  logic [CVA6Cfg.XLEN-1:0] pvm_cfg2_q, pvm_cfg2_d;  // PolkaVM control CSR 2 (jump table)
  logic [CVA6Cfg.XLEN-1:0] pvm_vec_q, pvm_vec_d;    // B4: PVM host-boundary exit vector
  logic [CVA6Cfg.XLEN-1:0] pvm_ram_q, pvm_ram_d;    // B7: guest-RAM->DRAM aperture
  logic [CVA6Cfg.XLEN-1:0] mepc_q, mepc_d;
  logic [CVA6Cfg.XLEN-1:0] mcause_q, mcause_d;
  logic [CVA6Cfg.XLEN-1:0] mtval_q, mtval_d;
  logic fiom_d, fiom_q;

  logic [CVA6Cfg.XLEN-1:0] stvec_q, stvec_d;
  logic [CVA6Cfg.XLEN-1:0] scounteren_q, scounteren_d;
  logic [CVA6Cfg.XLEN-1:0] sscratch_q, sscratch_d;
  logic [CVA6Cfg.XLEN-1:0] sepc_q, sepc_d;
  logic [CVA6Cfg.XLEN-1:0] scause_q, scause_d;
  logic [CVA6Cfg.XLEN-1:0] stval_q, stval_d;

  logic [CVA6Cfg.XLEN-1:0] dcache_q, dcache_d;
  logic [CVA6Cfg.XLEN-1:0] icache_q, icache_d;
  logic [CVA6Cfg.XLEN-1:0] acc_cons_q, acc_cons_d;

  logic wfi_d, wfi_q;

  logic [63:0] cycle_q, cycle_d;
  logic [63:0] instret_q, instret_d;

  riscv::pmpcfg_t [63:0] pmpcfg_q, pmpcfg_d, pmpcfg_next;
  logic [63:0][CVA6Cfg.PLEN-3:0] pmpaddr_q, pmpaddr_d, pmpaddr_next;
  logic [MHPMCounterNum+3-1:0] mcountinhibit_d, mcountinhibit_q;

  // Trigger Module Registers
  logic [CVA6Cfg.XLEN-1:0] scontext_d, scontext_q;
  logic [CVA6Cfg.XLEN-1:0] tdata1_from_tm;
  logic [CVA6Cfg.XLEN-1:0] tdata1_to_tm;
  logic [CVA6Cfg.XLEN-1:0] tdata2_from_tm;
  logic [CVA6Cfg.XLEN-1:0] tdata2_to_tm;
  logic [CVA6Cfg.XLEN-1:0] tdata3_from_tm;
  logic [CVA6Cfg.XLEN-1:0] tdata3_to_tm;
  logic [CVA6Cfg.XLEN-1:0] tselect_to_tm;
  logic [CVA6Cfg.XLEN-1:0] tselect_from_tm;
  logic tselect_we, tdata1_we, tdata2_we, tdata3_we;
  logic flush_from_tm;
  logic break_from_trigger;
  logic debug_from_trigger;
  logic debug_from_mcontrol;

  // CBO enable flags from menvcfg/senvcfg
  riscv::cbie_t mcbie_q, mcbie_d, scbie_q, scbie_d;
  logic mcbcfe_q, mcbcfe_d, scbcfe_q, scbcfe_d;

  localparam logic [CVA6Cfg.XLEN-1:0] IsaCode = (CVA6Cfg.XLEN'(CVA6Cfg.RVA) <<  0)                // A - Atomic Instructions extension
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVB) << 1)  // B - Bitmanip extension
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVC) << 2)  // C - Compressed extension
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVD) << 3)  // D - Double precision floating-point extension
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVE) << 4)  // E - RV32E/RV64E base ISA (reduced register file)
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVF) << 5)  // F - Single precision floating-point extension
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVH) << 7)  // H - Hypervisor extension
  | (CVA6Cfg.XLEN'(!CVA6Cfg.RVE) << 8)  // I - RV32I/64I base ISA (mutually exclusive with E)
  | (CVA6Cfg.XLEN'(1) << 12)  // M - Integer Multiply/Divide extension
  | (CVA6Cfg.XLEN'(0) << 13)  // N - User level interrupts supported
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVS) << 18)  // S - Supervisor mode implemented
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVU) << 20)  // U - User mode implemented
  | (CVA6Cfg.XLEN'(CVA6Cfg.RVV) << 21)  // V - Vector extension
  | (CVA6Cfg.XLEN'(CVA6Cfg.NSX) << 23)  // X - Non-standard extensions present
  | ((CVA6Cfg.XLEN == 64 ? 2 : 1) << CVA6Cfg.XLEN - 2);  // MXL

  assign pmpcfg_o  = pmpcfg_q[(CVA6Cfg.NrPMPEntries>0?CVA6Cfg.NrPMPEntries-1 : 0):0];
  assign pmpaddr_o = pmpaddr_q[(CVA6Cfg.NrPMPEntries>0?CVA6Cfg.NrPMPEntries-1 : 0):0];

  riscv::fcsr_t fcsr_q, fcsr_d;
  // ----------------
  // Assignments
  // ----------------
  assign csr_addr = riscv::csr_t'(csr_addr_i);
  assign conv_csr_addr = csr_addr;
  assign fs_o = riscv::Off;
  assign vfs_o = riscv::Off;
  assign vs_o = mstatus_q.vs;
  // ----------------
  // CSR Read logic
  // ----------------
  assign mstatus_extended = CVA6Cfg.IS_XLEN64 ? mstatus_q[CVA6Cfg.XLEN-1:0] :
                              {mstatus_q.sd, mstatus_q.wpri3[7:0], mstatus_q[22:0]};
  assign mstatush = {24'h0, 1'b0, 1'b0, mstatus_q.mbe, mstatus_q.sbe, 4'h0};

  always_comb begin : csr_read_process
    // a read access exception can only occur if we attempt to read a CSR which does not exist
    read_access_exception = 1'b0;
    csr_rdata = '0;
    perf_addr_o = csr_addr.address[11:0];

    if (csr_read) begin
      unique case (conv_csr_addr.address)
        riscv::CSR_FFLAGS: read_access_exception = 1'b1;
        riscv::CSR_FRM:    read_access_exception = 1'b1;
        riscv::CSR_FCSR:   read_access_exception = 1'b1;
        riscv::CSR_JVT:    read_access_exception = 1'b1;
        riscv::CSR_FTRAN:  read_access_exception = 1'b1;
        // debug registers
        riscv::CSR_DCSR:
        if (CVA6Cfg.DebugEn) csr_rdata = {{CVA6Cfg.XLEN - 32{1'b0}}, dcsr_q};
        else read_access_exception = 1'b1;
        riscv::CSR_DPC:
        if (CVA6Cfg.DebugEn) csr_rdata = dpc_q;
        else read_access_exception = 1'b1;
        riscv::CSR_DSCRATCH0:
        if (CVA6Cfg.DebugEn) csr_rdata = dscratch0_q;
        else read_access_exception = 1'b1;
        riscv::CSR_DSCRATCH1:
        if (CVA6Cfg.DebugEn) csr_rdata = dscratch1_q;
        else read_access_exception = 1'b1;
        // Trigger module registers
        riscv::CSR_TSELECT:
        if (CVA6Cfg.SDTRIG) csr_rdata = tselect_from_tm;
        else read_access_exception = 1'b1;
        riscv::CSR_TDATA1:
        if (CVA6Cfg.SDTRIG) csr_rdata = tdata1_from_tm;
        else read_access_exception = 1'b1;
        riscv::CSR_TDATA2:
        if (CVA6Cfg.SDTRIG) csr_rdata = tdata2_from_tm;
        else read_access_exception = 1'b1;
        riscv::CSR_TDATA3:
        if (CVA6Cfg.SDTRIG) csr_rdata = tdata3_from_tm;
        else read_access_exception = 1'b1;
        riscv::CSR_TINFO: begin
          if (CVA6Cfg.SDTRIG) begin
            csr_rdata = {
              {CVA6Cfg.XLEN - 32{1'b0}}, 8'h1, 8'h0, 16'b1000_0000_0111_1000
            };  // trigger info:icount = 3, itrigger = 4, etrigger = 5, mcontrol6 = 6, disable = 15
          end else begin
            read_access_exception = 1'b1;
          end
        end
        riscv::CSR_SCONTEXT:
        if (CVA6Cfg.SDTRIG) csr_rdata = scontext_q;
        else read_access_exception = 1'b1;
        // supervisor registers
        riscv::CSR_SSTATUS: begin
          if (CVA6Cfg.RVS) csr_rdata = mstatus_extended & SMODE_STATUS_READ_MASK[CVA6Cfg.XLEN-1:0];
          else read_access_exception = 1'b1;
        end
        riscv::CSR_SIE:
        if (CVA6Cfg.RVS) csr_rdata = mie_q & mideleg_q;
        else read_access_exception = 1'b1;
        riscv::CSR_SIP:
        if (CVA6Cfg.RVS) csr_rdata = mip_q & mideleg_q;
        else read_access_exception = 1'b1;
        riscv::CSR_STVEC:
        if (CVA6Cfg.RVS) csr_rdata = stvec_q;
        else read_access_exception = 1'b1;
        riscv::CSR_SCOUNTEREN:
        if (CVA6Cfg.RVS) csr_rdata = scounteren_q;
        else read_access_exception = 1'b1;
        riscv::CSR_SSCRATCH:
        if (CVA6Cfg.RVS) csr_rdata = sscratch_q;
        else read_access_exception = 1'b1;
        riscv::CSR_SEPC:
        if (CVA6Cfg.RVS) csr_rdata = sepc_q;
        else read_access_exception = 1'b1;
        riscv::CSR_SCAUSE:
        if (CVA6Cfg.RVS) csr_rdata = scause_q;
        else read_access_exception = 1'b1;
        riscv::CSR_STVAL:
        if (CVA6Cfg.RVS) csr_rdata = stval_q;
        else read_access_exception = 1'b1;
        riscv::CSR_SATP: begin
          if (CVA6Cfg.RVS) begin
            // intercept reads to SATP if in S-Mode and TVM is enabled
            if (priv_lvl_o == riscv::PRIV_LVL_S && mstatus_q.tvm) begin
              read_access_exception = 1'b1;
            end else begin
              csr_rdata = satp_q;
            end
          end else begin
            read_access_exception = 1'b1;
          end
        end
        riscv::CSR_SENVCFG: begin
          if (CVA6Cfg.RVS) begin
            csr_rdata = '0 | fiom_q;
          end else begin
            read_access_exception = 1'b1;
          end
        end

        // machine mode registers
        riscv::CSR_MSTATUS: csr_rdata = mstatus_extended;
        riscv::CSR_MSTATUSH:
        if (CVA6Cfg.XLEN == 32) csr_rdata = mstatush;
        else read_access_exception = 1'b1;
        riscv::CSR_MISA: csr_rdata = IsaCode;
        riscv::CSR_MEDELEG:
        if (CVA6Cfg.RVS) csr_rdata = medeleg_q;
        else read_access_exception = 1'b1;
        riscv::CSR_MIDELEG:
        if (CVA6Cfg.RVS) csr_rdata = mideleg_q;
        else read_access_exception = 1'b1;
        riscv::CSR_MIE: csr_rdata = mie_q;
        riscv::CSR_MTVEC: csr_rdata = mtvec_q;
        riscv::CSR_MCOUNTEREN:
        if (CVA6Cfg.RVU) csr_rdata = mcounteren_q;
        else read_access_exception = 1'b1;
        riscv::CSR_MSCRATCH: csr_rdata = mscratch_q;
        riscv::CSR_PVM_CFG0: csr_rdata = pvm_cfg0_q;
        riscv::CSR_PVM_CFG1: csr_rdata = pvm_cfg1_q;
        riscv::CSR_PVM_CFG2: csr_rdata = pvm_cfg2_q;
        riscv::CSR_PVM_VEC:  csr_rdata = pvm_vec_q;
        riscv::CSR_PVM_RAM:  csr_rdata = pvm_ram_q;
        riscv::CSR_PVM_IMG:  csr_rdata = '0;  // write-only image load port
        riscv::CSR_MEPC: csr_rdata = mepc_q;
        riscv::CSR_MCAUSE: csr_rdata = mcause_q;
        riscv::CSR_MTVAL:
        if (CVA6Cfg.TvalEn) csr_rdata = mtval_q;
        else csr_rdata = '0;
        riscv::CSR_MIP: csr_rdata = mip_q;
        riscv::CSR_MENVCFG: begin
          if (CVA6Cfg.RVU) begin
            csr_rdata = '0 | fiom_q;
          end else begin
            read_access_exception = 1'b1;
          end
        end
        riscv::CSR_MENVCFGH: begin
          if (CVA6Cfg.RVU && CVA6Cfg.XLEN == 32) csr_rdata = '0;
          else read_access_exception = 1'b1;
        end
        riscv::CSR_MVENDORID: csr_rdata = {{CVA6Cfg.XLEN - 32{1'b0}}, OPENHWGROUP_MVENDORID};
        riscv::CSR_MARCHID: csr_rdata = {{CVA6Cfg.XLEN - 32{1'b0}}, ARIANE_MARCHID};
        riscv::CSR_MIMPID: csr_rdata = {{CVA6Cfg.XLEN - 32{1'b0}}, ARIANE_MIMPID};
        riscv::CSR_MHARTID: csr_rdata = hart_id_i;
        riscv::CSR_MCONFIGPTR: csr_rdata = '0;  // not implemented
        riscv::CSR_MCOUNTINHIBIT:
        csr_rdata = {{(CVA6Cfg.XLEN - (MHPMCounterNum + 3)) {1'b0}}, mcountinhibit_q};
        // Counters and Timers
        riscv::CSR_MCYCLE: csr_rdata = cycle_q[CVA6Cfg.XLEN-1:0];
        riscv::CSR_MCYCLEH:
        if (CVA6Cfg.XLEN == 32) csr_rdata = cycle_q[63:32];
        else read_access_exception = 1'b1;
        riscv::CSR_MINSTRET: csr_rdata = instret_q[CVA6Cfg.XLEN-1:0];
        riscv::CSR_MINSTRETH:
        if (CVA6Cfg.XLEN == 32) csr_rdata = instret_q[63:32];
        else read_access_exception = 1'b1;
        riscv::CSR_CYCLE:
        if (CVA6Cfg.RVZicntr) csr_rdata = cycle_q[CVA6Cfg.XLEN-1:0];
        else read_access_exception = 1'b1;
        riscv::CSR_CYCLEH:
        if (CVA6Cfg.RVZicntr)
          if (CVA6Cfg.XLEN == 32) csr_rdata = cycle_q[63:32];
          else read_access_exception = 1'b1;
        else read_access_exception = 1'b1;
        riscv::CSR_INSTRET:
        if (CVA6Cfg.RVZicntr) csr_rdata = instret_q[CVA6Cfg.XLEN-1:0];
        else read_access_exception = 1'b1;
        riscv::CSR_INSTRETH:
        if (CVA6Cfg.RVZicntr)
          if (CVA6Cfg.XLEN == 32) csr_rdata = instret_q[63:32];
          else read_access_exception = 1'b1;
        else read_access_exception = 1'b1;
        //Event Selector
        riscv::CSR_MHPM_EVENT_3,
                riscv::CSR_MHPM_EVENT_4,
                riscv::CSR_MHPM_EVENT_5,
                riscv::CSR_MHPM_EVENT_6,
                riscv::CSR_MHPM_EVENT_7,
                riscv::CSR_MHPM_EVENT_8,
                riscv::CSR_MHPM_EVENT_9,
                riscv::CSR_MHPM_EVENT_10,
                riscv::CSR_MHPM_EVENT_11,
                riscv::CSR_MHPM_EVENT_12,
                riscv::CSR_MHPM_EVENT_13,
                riscv::CSR_MHPM_EVENT_14,
                riscv::CSR_MHPM_EVENT_15,
                riscv::CSR_MHPM_EVENT_16,
                riscv::CSR_MHPM_EVENT_17,
                riscv::CSR_MHPM_EVENT_18,
                riscv::CSR_MHPM_EVENT_19,
                riscv::CSR_MHPM_EVENT_20,
                riscv::CSR_MHPM_EVENT_21,
                riscv::CSR_MHPM_EVENT_22,
                riscv::CSR_MHPM_EVENT_23,
                riscv::CSR_MHPM_EVENT_24,
                riscv::CSR_MHPM_EVENT_25,
                riscv::CSR_MHPM_EVENT_26,
                riscv::CSR_MHPM_EVENT_27,
                riscv::CSR_MHPM_EVENT_28,
                riscv::CSR_MHPM_EVENT_29,
                riscv::CSR_MHPM_EVENT_30,
                riscv::CSR_MHPM_EVENT_31 :
        csr_rdata = perf_data_i;

        riscv::CSR_MHPM_COUNTER_3,
                riscv::CSR_MHPM_COUNTER_4,
                riscv::CSR_MHPM_COUNTER_5,
                riscv::CSR_MHPM_COUNTER_6,
                riscv::CSR_MHPM_COUNTER_7,
                riscv::CSR_MHPM_COUNTER_8,
                riscv::CSR_MHPM_COUNTER_9,
                riscv::CSR_MHPM_COUNTER_10,
                riscv::CSR_MHPM_COUNTER_11,
                riscv::CSR_MHPM_COUNTER_12,
                riscv::CSR_MHPM_COUNTER_13,
                riscv::CSR_MHPM_COUNTER_14,
                riscv::CSR_MHPM_COUNTER_15,
                riscv::CSR_MHPM_COUNTER_16,
                riscv::CSR_MHPM_COUNTER_17,
                riscv::CSR_MHPM_COUNTER_18,
                riscv::CSR_MHPM_COUNTER_19,
                riscv::CSR_MHPM_COUNTER_20,
                riscv::CSR_MHPM_COUNTER_21,
                riscv::CSR_MHPM_COUNTER_22,
                riscv::CSR_MHPM_COUNTER_23,
                riscv::CSR_MHPM_COUNTER_24,
                riscv::CSR_MHPM_COUNTER_25,
                riscv::CSR_MHPM_COUNTER_26,
                riscv::CSR_MHPM_COUNTER_27,
                riscv::CSR_MHPM_COUNTER_28,
                riscv::CSR_MHPM_COUNTER_29,
                riscv::CSR_MHPM_COUNTER_30,
                riscv::CSR_MHPM_COUNTER_31 :
        csr_rdata = perf_data_i;

        riscv::CSR_MHPM_COUNTER_3H,
                riscv::CSR_MHPM_COUNTER_4H,
                riscv::CSR_MHPM_COUNTER_5H,
                riscv::CSR_MHPM_COUNTER_6H,
                riscv::CSR_MHPM_COUNTER_7H,
                riscv::CSR_MHPM_COUNTER_8H,
                riscv::CSR_MHPM_COUNTER_9H,
                riscv::CSR_MHPM_COUNTER_10H,
                riscv::CSR_MHPM_COUNTER_11H,
                riscv::CSR_MHPM_COUNTER_12H,
                riscv::CSR_MHPM_COUNTER_13H,
                riscv::CSR_MHPM_COUNTER_14H,
                riscv::CSR_MHPM_COUNTER_15H,
                riscv::CSR_MHPM_COUNTER_16H,
                riscv::CSR_MHPM_COUNTER_17H,
                riscv::CSR_MHPM_COUNTER_18H,
                riscv::CSR_MHPM_COUNTER_19H,
                riscv::CSR_MHPM_COUNTER_20H,
                riscv::CSR_MHPM_COUNTER_21H,
                riscv::CSR_MHPM_COUNTER_22H,
                riscv::CSR_MHPM_COUNTER_23H,
                riscv::CSR_MHPM_COUNTER_24H,
                riscv::CSR_MHPM_COUNTER_25H,
                riscv::CSR_MHPM_COUNTER_26H,
                riscv::CSR_MHPM_COUNTER_27H,
                riscv::CSR_MHPM_COUNTER_28H,
                riscv::CSR_MHPM_COUNTER_29H,
                riscv::CSR_MHPM_COUNTER_30H,
                riscv::CSR_MHPM_COUNTER_31H :
        if (CVA6Cfg.XLEN == 32) csr_rdata = perf_data_i;
        else read_access_exception = 1'b1;

        // Performance counters (User Mode - R/O Shadows)
        riscv::CSR_HPM_COUNTER_3,
                riscv::CSR_HPM_COUNTER_4,
                riscv::CSR_HPM_COUNTER_5,
                riscv::CSR_HPM_COUNTER_6,
                riscv::CSR_HPM_COUNTER_7,
                riscv::CSR_HPM_COUNTER_8,
                riscv::CSR_HPM_COUNTER_9,
                riscv::CSR_HPM_COUNTER_10,
                riscv::CSR_HPM_COUNTER_11,
                riscv::CSR_HPM_COUNTER_12,
                riscv::CSR_HPM_COUNTER_13,
                riscv::CSR_HPM_COUNTER_14,
                riscv::CSR_HPM_COUNTER_15,
                riscv::CSR_HPM_COUNTER_16,
                riscv::CSR_HPM_COUNTER_17,
                riscv::CSR_HPM_COUNTER_18,
                riscv::CSR_HPM_COUNTER_19,
                riscv::CSR_HPM_COUNTER_20,
                riscv::CSR_HPM_COUNTER_21,
                riscv::CSR_HPM_COUNTER_22,
                riscv::CSR_HPM_COUNTER_23,
                riscv::CSR_HPM_COUNTER_24,
                riscv::CSR_HPM_COUNTER_25,
                riscv::CSR_HPM_COUNTER_26,
                riscv::CSR_HPM_COUNTER_27,
                riscv::CSR_HPM_COUNTER_28,
                riscv::CSR_HPM_COUNTER_29,
                riscv::CSR_HPM_COUNTER_30,
                riscv::CSR_HPM_COUNTER_31 :
        if (CVA6Cfg.RVZihpm) begin
          csr_rdata = perf_data_i;
        end else begin
          read_access_exception = 1'b1;
        end

        riscv::CSR_HPM_COUNTER_3H,
                riscv::CSR_HPM_COUNTER_4H,
                riscv::CSR_HPM_COUNTER_5H,
                riscv::CSR_HPM_COUNTER_6H,
                riscv::CSR_HPM_COUNTER_7H,
                riscv::CSR_HPM_COUNTER_8H,
                riscv::CSR_HPM_COUNTER_9H,
                riscv::CSR_HPM_COUNTER_10H,
                riscv::CSR_HPM_COUNTER_11H,
                riscv::CSR_HPM_COUNTER_12H,
                riscv::CSR_HPM_COUNTER_13H,
                riscv::CSR_HPM_COUNTER_14H,
                riscv::CSR_HPM_COUNTER_15H,
                riscv::CSR_HPM_COUNTER_16H,
                riscv::CSR_HPM_COUNTER_17H,
                riscv::CSR_HPM_COUNTER_18H,
                riscv::CSR_HPM_COUNTER_19H,
                riscv::CSR_HPM_COUNTER_20H,
                riscv::CSR_HPM_COUNTER_21H,
                riscv::CSR_HPM_COUNTER_22H,
                riscv::CSR_HPM_COUNTER_23H,
                riscv::CSR_HPM_COUNTER_24H,
                riscv::CSR_HPM_COUNTER_25H,
                riscv::CSR_HPM_COUNTER_26H,
                riscv::CSR_HPM_COUNTER_27H,
                riscv::CSR_HPM_COUNTER_28H,
                riscv::CSR_HPM_COUNTER_29H,
                riscv::CSR_HPM_COUNTER_30H,
                riscv::CSR_HPM_COUNTER_31H :
        if (CVA6Cfg.RVZihpm) begin
          if (CVA6Cfg.XLEN == 32) csr_rdata = perf_data_i;
          else read_access_exception = 1'b1;
        end else begin
          read_access_exception = 1'b1;
        end

        // custom (non RISC-V) cache control
        riscv::CSR_DCACHE: csr_rdata = dcache_q;
        riscv::CSR_ICACHE: csr_rdata = icache_q;
        // custom (non RISC-V) accelerator memory consistency mode
        riscv::CSR_ACC_CONS: read_access_exception = 1'b1;
        // PMPs
        riscv::CSR_PMPCFG0,
                riscv::CSR_PMPCFG1,
                riscv::CSR_PMPCFG2,
                riscv::CSR_PMPCFG3,
                riscv::CSR_PMPCFG4,
                riscv::CSR_PMPCFG5,
                riscv::CSR_PMPCFG6,
                riscv::CSR_PMPCFG7,
                riscv::CSR_PMPCFG8,
                riscv::CSR_PMPCFG9,
                riscv::CSR_PMPCFG10,
                riscv::CSR_PMPCFG11,
                riscv::CSR_PMPCFG12,
                riscv::CSR_PMPCFG13,
                riscv::CSR_PMPCFG14,
                riscv::CSR_PMPCFG15: begin
          // index is calculated using PMPCFG0 as the offset
          automatic logic [3:0] index = csr_addr.address[11:0] - riscv::CSR_PMPCFG0;

          // if index is not even and XLEN==64, raise exception
          if (CVA6Cfg.XLEN == 64 && index[0] == 1'b1) read_access_exception = 1'b1;
          else begin
            // The following line has no effect. It's here just to prevent the synthesizer from crashing
            if (CVA6Cfg.XLEN == 64) index = (index >> 1) << 1;
            csr_rdata = pmpcfg_q[index*4+:CVA6Cfg.XLEN/8];
          end
        end
        // PMPADDR
        riscv::CSR_PMPADDR0,
                riscv::CSR_PMPADDR1,
                riscv::CSR_PMPADDR2,
                riscv::CSR_PMPADDR3,
                riscv::CSR_PMPADDR4,
                riscv::CSR_PMPADDR5,
                riscv::CSR_PMPADDR6,
                riscv::CSR_PMPADDR7,
                riscv::CSR_PMPADDR8,
                riscv::CSR_PMPADDR9,
                riscv::CSR_PMPADDR10,
                riscv::CSR_PMPADDR11,
                riscv::CSR_PMPADDR12,
                riscv::CSR_PMPADDR13,
                riscv::CSR_PMPADDR14,
                riscv::CSR_PMPADDR15,
                riscv::CSR_PMPADDR16,
                riscv::CSR_PMPADDR17,
                riscv::CSR_PMPADDR18,
                riscv::CSR_PMPADDR19,
                riscv::CSR_PMPADDR20,
                riscv::CSR_PMPADDR21,
                riscv::CSR_PMPADDR22,
                riscv::CSR_PMPADDR23,
                riscv::CSR_PMPADDR24,
                riscv::CSR_PMPADDR25,
                riscv::CSR_PMPADDR26,
                riscv::CSR_PMPADDR27,
                riscv::CSR_PMPADDR28,
                riscv::CSR_PMPADDR29,
                riscv::CSR_PMPADDR30,
                riscv::CSR_PMPADDR31,
                riscv::CSR_PMPADDR32,
                riscv::CSR_PMPADDR33,
                riscv::CSR_PMPADDR34,
                riscv::CSR_PMPADDR35,
                riscv::CSR_PMPADDR36,
                riscv::CSR_PMPADDR37,
                riscv::CSR_PMPADDR38,
                riscv::CSR_PMPADDR39,
                riscv::CSR_PMPADDR40,
                riscv::CSR_PMPADDR41,
                riscv::CSR_PMPADDR42,
                riscv::CSR_PMPADDR43,
                riscv::CSR_PMPADDR44,
                riscv::CSR_PMPADDR45,
                riscv::CSR_PMPADDR46,
                riscv::CSR_PMPADDR47,
                riscv::CSR_PMPADDR48,
                riscv::CSR_PMPADDR49,
                riscv::CSR_PMPADDR50,
                riscv::CSR_PMPADDR51,
                riscv::CSR_PMPADDR52,
                riscv::CSR_PMPADDR53,
                riscv::CSR_PMPADDR54,
                riscv::CSR_PMPADDR55,
                riscv::CSR_PMPADDR56,
                riscv::CSR_PMPADDR57,
                riscv::CSR_PMPADDR58,
                riscv::CSR_PMPADDR59,
                riscv::CSR_PMPADDR60,
                riscv::CSR_PMPADDR61,
                riscv::CSR_PMPADDR62,
                riscv::CSR_PMPADDR63: begin
          // index is calculated using PMPADDR0 as the offset
          automatic logic [11:0] index = csr_addr.address[11:0] - riscv::CSR_PMPADDR0;
          // Important: we only support granularity 8 bytes (G=1)
          // -> last bit of pmpaddr must be set 0/1 based on the mode:
          // NA4, NAPOT: 1
          // TOR, OFF:   0
          if (pmpcfg_q[index].addr_mode[1] == 1'b1)
            csr_rdata = {pmpaddr_q[index][CVA6Cfg.PLEN-3:1], 1'b1};
          else csr_rdata = {pmpaddr_q[index][CVA6Cfg.PLEN-3:1], 1'b0};
        end
        default: read_access_exception = 1'b1;
      endcase
    end
  end
  // ---------------------------
  // CSR Write and update logic
  // ---------------------------
  logic [CVA6Cfg.XLEN-1:0] mask;
  always_comb begin : csr_update
    automatic satp_t satp;
    automatic logic [63:0] instret;

    if (CVA6Cfg.RVS) begin
      satp = satp_q;
    end
    instret         = instret_q;

    mcountinhibit_d = mcountinhibit_q;

    // --------------------
    // Counters
    // --------------------
    cycle_d         = cycle_q;
    instret_d       = instret_q;
    if (!(CVA6Cfg.DebugEn && debug_mode_q)) begin
      // increase instruction retired counter
      for (int i = 0; i < CVA6Cfg.NrCommitPorts; i++) begin
        if (commit_ack_i[i] && !ex_i.valid && (!CVA6Cfg.PerfCounterEn || (CVA6Cfg.PerfCounterEn && !mcountinhibit_q[2])))
          instret++;
      end
      instret_d = instret;
      // increment the cycle count
      if (!CVA6Cfg.PerfCounterEn || (CVA6Cfg.PerfCounterEn && !mcountinhibit_q[0]))
        cycle_d = cycle_q + 1'b1;
      else cycle_d = cycle_q;
    end

    eret_o                          = 1'b0;
    flush_o                         = 1'b0;
    pvm_img_we_o                    = 1'b0;
    update_access_exception         = 1'b0;

    set_debug_pc_o                  = 1'b0;

    perf_we_o                       = 1'b0;
    perf_data_o                     = 'b0;
    fcsr_d       = fcsr_q;

    priv_lvl_d   = priv_lvl_q;
    debug_mode_d = debug_mode_q;

    if (CVA6Cfg.DebugEn) begin
      dcsr_d      = dcsr_q;
      dpc_d       = dpc_q;
      dscratch0_d = dscratch0_q;
      dscratch1_d = dscratch1_q;
    end
    mstatus_d = mstatus_q;

    // check whether we come out of reset
    // this is a workaround. some tools have issues
    // having boot_addr_i in the asynchronous
    // reset assignment to mtvec_d, even though
    // boot_addr_i will be assigned a constant
    // on the top-level.
    if (mtvec_rst_load_q) begin
      mtvec_d = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, boot_addr_i} + 'h40;
    end else begin
      mtvec_d = mtvec_q;
    end

    if (CVA6Cfg.RVS) begin
      medeleg_d = medeleg_q;
      mideleg_d = mideleg_q;
    end
    mip_d        = mip_q;
    mie_d        = mie_q;
    mepc_d       = mepc_q;
    mcause_d     = mcause_q;
    mcounteren_d = mcounteren_q;
    mscratch_d   = mscratch_q;
    pvm_cfg0_d   = pvm_cfg0_q;
    pvm_cfg1_d   = pvm_cfg1_q;
    pvm_cfg2_d   = pvm_cfg2_q;
    // eret-via-JT one-shot: once the JT-mapped handoff eret consumes it, clear CFG2[36] so later
    // trap-return erets are DIRECT (raw PVM-pc), not JT-mapped. A same-cycle SW write to CFG2
    // (the write case below, later in this block) overwrites pvm_cfg2_d -> SW write takes precedence (re-arm).
    if (CVA6Cfg.PvmPresent && pvm_eret_jt_consume_i) pvm_cfg2_d[36] = 1'b0;
    pvm_vec_d    = pvm_vec_q;
    pvm_ram_d    = pvm_ram_q;
    if (CVA6Cfg.TvalEn) mtval_d = mtval_q;

    fiom_d     = fiom_q;
    dcache_d   = dcache_q;
    icache_d   = icache_q;
    acc_cons_d = acc_cons_q;

    if (CVA6Cfg.RVS) begin
      sepc_d       = sepc_q;
      scause_d     = scause_q;
      stvec_d      = stvec_q;
      scounteren_d = scounteren_q;
      sscratch_d   = sscratch_q;
      stval_d      = stval_q;
      satp_d       = satp_q;
    end

    en_ld_st_translation_d = en_ld_st_translation_q;

    pmpcfg_d               = pmpcfg_q;
    pmpaddr_d              = pmpaddr_q;

    mcbie_d                = mcbie_q;
    scbie_d                = scbie_q;

    mcbcfe_d               = mcbcfe_q;
    scbcfe_d               = scbcfe_q;

    // trigger module defaults
    tdata1_to_tm           = '0;
    tdata2_to_tm           = '0;
    tdata3_to_tm           = '0;
    tselect_to_tm          = '0;
    tselect_we             = 1'b0;
    tdata1_we              = 1'b0;
    tdata2_we              = 1'b0;
    tdata3_we              = 1'b0;

    // check for correct access rights and that we are writing
    if (csr_we) begin
      unique case (conv_csr_addr.address)
        // Floating-Point (disabled)
        riscv::CSR_FFLAGS: update_access_exception = 1'b1;
        riscv::CSR_FRM:    update_access_exception = 1'b1;
        riscv::CSR_FCSR:   update_access_exception = 1'b1;
        riscv::CSR_FTRAN:  update_access_exception = 1'b1;
        // debug CSR
        riscv::CSR_DCSR: begin
          if (CVA6Cfg.DebugEn) begin
            dcsr_d           = csr_wdata[31:0];
            // debug is implemented
            dcsr_d.xdebugver = 4'h4;
            // currently not supported
            dcsr_d.nmip      = 1'b0;
            dcsr_d.stopcount = 1'b0;
            dcsr_d.stoptime  = 1'b0;
          end else begin
            update_access_exception = 1'b1;
          end
        end
        riscv::CSR_DPC:
        if (CVA6Cfg.DebugEn) dpc_d = csr_wdata;
        else update_access_exception = 1'b1;
        riscv::CSR_DSCRATCH0:
        if (CVA6Cfg.DebugEn) dscratch0_d = csr_wdata;
        else update_access_exception = 1'b1;
        riscv::CSR_DSCRATCH1:
        if (CVA6Cfg.DebugEn) dscratch1_d = csr_wdata;
        else update_access_exception = 1'b1;
        riscv::CSR_JVT: update_access_exception = 1'b1;
        // Trigger module CSRs
        riscv::CSR_TSELECT: begin
          if (CVA6Cfg.SDTRIG) begin
            tselect_to_tm = csr_wdata;
            tselect_we    = csr_we;
          end else begin
            update_access_exception = 1'b1;
          end
        end
        riscv::CSR_TDATA1: begin
          if (CVA6Cfg.SDTRIG) begin
            tdata1_to_tm = csr_wdata;
            tdata1_we    = csr_we;
            flush_o = flush_from_tm;
          end else begin
            update_access_exception = 1'b1;
          end
        end
        riscv::CSR_TDATA2: begin
          if (CVA6Cfg.SDTRIG) begin
            tdata2_to_tm = csr_wdata;
            tdata2_we    = csr_we;
          end else begin
            update_access_exception = 1'b1;
          end
        end
        riscv::CSR_TDATA3: begin
          if (CVA6Cfg.SDTRIG) begin
            tdata3_to_tm = csr_wdata;
            tdata3_we    = csr_we;
          end else begin
            update_access_exception = 1'b1;
          end
        end
        riscv::CSR_SCONTEXT: begin
          if (CVA6Cfg.SDTRIG) begin
            scontext_d = {{CVA6Cfg.XLEN - 32{1'b0}}, csr_wdata[31:0]};
          end else begin
            update_access_exception = 1'b1;
          end
        end
        // sstatus is a subset of mstatus - mask it accordingly
        riscv::CSR_SSTATUS: begin
          if (CVA6Cfg.RVS) begin
            mask = ariane_pkg::SMODE_STATUS_WRITE_MASK[CVA6Cfg.XLEN-1:0];
            mstatus_d = (mstatus_q & ~{{64-CVA6Cfg.XLEN{1'b0}}, mask}) | {{64-CVA6Cfg.XLEN{1'b0}}, (csr_wdata & mask)};
            // hardwire to zero: no FP, no vector
            mstatus_d.fs = riscv::Off;
            mstatus_d.vs = riscv::Off;
            // H-extension not enabled, priv level HS is reserved
            if (mstatus_d.mpp == riscv::PRIV_LVL_HS) begin
              mstatus_d.mpp = mstatus_q.mpp;
            end
            // this instruction has side-effects
            flush_o = 1'b1;
          end else begin
            update_access_exception = 1'b1;
          end
        end
        // even machine mode interrupts can be visible and set-able to supervisor
        // if the corresponding bit in mideleg is set
        riscv::CSR_SIE: begin
          if (CVA6Cfg.RVS) begin
            mask  = mideleg_q;
            // the mideleg makes sure only delegate-able register (and therefore also only implemented registers) are written
            mie_d = (mie_q & ~mask) | (csr_wdata & mask);
          end else begin
            update_access_exception = 1'b1;
          end
        end

        riscv::CSR_SIP: begin
          if (CVA6Cfg.RVS) begin
            // only the supervisor software interrupt is write-able, iff delegated
            mask  = CVA6Cfg.XLEN'(riscv::MIP_SSIP) & mideleg_q;
            mip_d = (mip_q & ~mask) | (csr_wdata & mask);
          end else begin
            update_access_exception = 1'b1;
          end
        end

        riscv::CSR_STVEC:
        if (CVA6Cfg.RVS) stvec_d = {csr_wdata[CVA6Cfg.XLEN-1:2], 1'b0, csr_wdata[0]};
        else update_access_exception = 1'b1;
        riscv::CSR_SCOUNTEREN:
        if (CVA6Cfg.RVS) scounteren_d = {{CVA6Cfg.XLEN - 32{1'b0}}, csr_wdata[31:0]};
        else update_access_exception = 1'b1;
        riscv::CSR_SSCRATCH:
        if (CVA6Cfg.RVS) sscratch_d = csr_wdata;
        else update_access_exception = 1'b1;
        riscv::CSR_SEPC:
        if (CVA6Cfg.RVS) sepc_d = {csr_wdata[CVA6Cfg.XLEN-1:1], 1'b0};
        else update_access_exception = 1'b1;
        riscv::CSR_SCAUSE:
        if (CVA6Cfg.RVS) scause_d = csr_wdata;
        else update_access_exception = 1'b1;
        riscv::CSR_STVAL:
        if (CVA6Cfg.RVS && CVA6Cfg.TvalEn) stval_d = csr_wdata;
        else update_access_exception = 1'b1;
        // supervisor address translation and protection
        riscv::CSR_SATP: begin
          if (CVA6Cfg.RVS) begin
            // intercept SATP writes if in S-Mode and TVM is enabled
            if (priv_lvl_o == riscv::PRIV_LVL_S && mstatus_q.tvm) update_access_exception = 1'b1;
            else begin
              satp = satp_t'(csr_wdata);
              // only make ASID_LEN - 1 bit stick, that way software can figure out how many ASID bits are supported
              satp.asid = satp.asid & {{(CVA6Cfg.ASIDW - CVA6Cfg.ASID_WIDTH) {1'b0}}, {CVA6Cfg.ASID_WIDTH{1'b1}}};
              // only update if we actually support this mode
              if (config_pkg::vm_mode_t'(satp.mode) == config_pkg::ModeOff ||
                                config_pkg::vm_mode_t'(satp.mode) == CVA6Cfg.MODE_SV)
                satp_d = satp;
            end
            // changing the mode can have side-effects on address translation (e.g.: other instructions), re-fetch
            // the next instruction by executing a flush
            flush_o = 1'b1;
          end else begin
            update_access_exception = 1'b1;
          end
        end
        riscv::CSR_SENVCFG: begin
          if (CVA6Cfg.RVS) begin
            fiom_d = csr_wdata[0];
          end else begin
            update_access_exception = 1'b1;
          end
        end
        riscv::CSR_MSTATUS: begin
          mstatus_d    = {{64 - CVA6Cfg.XLEN{1'b0}}, csr_wdata};
          mstatus_d.xs = riscv::Off;
          // hardwire: no FP, no vector
          mstatus_d.fs = riscv::Off;
          mstatus_d.vs = riscv::Off;
          if (!CVA6Cfg.RVS) begin
            mstatus_d.sie  = riscv::Off;
            mstatus_d.spie = riscv::Off;
            mstatus_d.spp  = riscv::Off;
            mstatus_d.sum  = riscv::Off;
            mstatus_d.mxr  = riscv::Off;
            mstatus_d.tvm  = riscv::Off;
            mstatus_d.tsr  = riscv::Off;
          end
          if (!CVA6Cfg.RVU) begin
            mstatus_d.tw   = riscv::Off;
            mstatus_d.mprv = riscv::Off;
          end
          // No H: HS is reserved; check S and U as before
          if ((mstatus_d.mpp == riscv::PRIV_LVL_HS) |
              (!CVA6Cfg.RVS & mstatus_d.mpp == riscv::PRIV_LVL_S) |
              (!CVA6Cfg.RVU & mstatus_d.mpp == riscv::PRIV_LVL_U)) begin
            mstatus_d.mpp = mstatus_q.mpp;
          end
          mstatus_d.wpri3 = 9'b0;
          mstatus_d.wpri1 = 1'b0;
          mstatus_d.wpri2 = 1'b0;
          mstatus_d.wpri0 = 1'b0;
          // Mirror MBE
          mstatus_d.sbe   = mstatus_d.mbe;
          mstatus_d.ube   = mstatus_d.mbe;
          // this register has side-effects on other registers, flush the pipeline
          flush_o         = 1'b1;
        end
        riscv::CSR_MSTATUSH: begin
          if (CVA6Cfg.XLEN == 32) begin
            mstatus_d.mbe = ((csr_wdata & riscv::MSTATUSH_MBE) != 0);
            // Mirror MBE
            mstatus_d.sbe = mstatus_d.mbe;
            mstatus_d.ube = mstatus_d.mbe;
            // this register has side-effects on other registers, flush the pipeline
            flush_o       = 1'b1;
          end else begin
            update_access_exception = 1'b1;
          end
        end
        // MISA is WARL (Write Any Value, Reads Legal Value)
        riscv::CSR_MISA: ;
        // machine exception delegation register
        // 0 - 15 exceptions supported
        riscv::CSR_MEDELEG: begin
          if (CVA6Cfg.RVS) begin
            mask = (1 << riscv::INSTR_ADDR_MISALIGNED) |
                             (1 << riscv::INSTR_ACCESS_FAULT) |
                             (1 << riscv::ILLEGAL_INSTR) |
                             (1 << riscv::BREAKPOINT) |
                             (1 << riscv::LD_ADDR_MISALIGNED) |
                             (1 << riscv::LD_ACCESS_FAULT) |
                             (1 << riscv::ST_ADDR_MISALIGNED) |
                             (1 << riscv::ST_ACCESS_FAULT) |
                             (1 << riscv::ENV_CALL_UMODE) |
                             (1 << riscv::INSTR_PAGE_FAULT) |
                             (1 << riscv::LOAD_PAGE_FAULT) |
                             (1 << riscv::STORE_PAGE_FAULT);
            medeleg_d = (medeleg_q & ~mask) | (csr_wdata & mask);
          end else begin
            update_access_exception = 1'b1;
          end
        end
        // machine interrupt delegation register
        // we do not support user interrupt delegation
        riscv::CSR_MIDELEG: begin
          if (CVA6Cfg.RVS) begin
            mask = CVA6Cfg.XLEN'(riscv::MIP_SSIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_STIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_SEIP);
            mideleg_d = (mideleg_q & ~mask) | (csr_wdata & mask);
          end else begin
            update_access_exception = 1'b1;
          end
        end
        // mask the register so that unsupported interrupts can never be set
        riscv::CSR_MIE: begin
          if (CVA6Cfg.RVS) begin
            mask = CVA6Cfg.XLEN'(riscv::MIP_SSIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_STIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_SEIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_MSIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_MTIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_MEIP);
          end else begin
            if (CVA6Cfg.SoftwareInterruptEn) begin
              mask = CVA6Cfg.XLEN'(riscv::MIP_MSIP)
              | CVA6Cfg.XLEN'(riscv::MIP_MTIP)
              | CVA6Cfg.XLEN'(riscv::MIP_MEIP);
            end else begin
              mask = CVA6Cfg.XLEN'(riscv::MIP_MTIP)
              | CVA6Cfg.XLEN'(riscv::MIP_MEIP);
            end
          end
          mie_d = (mie_q & ~mask) | (csr_wdata & mask); // we only support supervisor and M-mode interrupts
        end

        riscv::CSR_MTVEC: begin
          logic DirVecOnly;
          DirVecOnly = CVA6Cfg.DirectVecOnly ? 1'b0 : csr_wdata[0];
          // PVM code-addresses are 2-byte-aligned (bit 1 is significant), so for a PVM
          // guest preserve mtvec bit 1 -- a guest trap handler can sit at an odd dyn-index
          // (e.g. OpenSBI's _trap_handler @ PVM code-addr 0x16); the RISC-V WARL (bit1=0)
          // would mangle 0x16 -> 0x14 and send every guest trap into the wrong block.
          mtvec_d = {csr_wdata[CVA6Cfg.XLEN-1:2], (CVA6Cfg.PvmPresent ? csr_wdata[1] : 1'b0), DirVecOnly};
          // we are in vector mode, this implementation requires the additional
          // alignment constraint of 64 * 4 bytes
          if (DirVecOnly) mtvec_d = {csr_wdata[CVA6Cfg.XLEN-1:8], 7'b0, DirVecOnly};
        end
        riscv::CSR_MCOUNTEREN: begin
          if (CVA6Cfg.RVU) mcounteren_d = {{CVA6Cfg.XLEN - 32{1'b0}}, csr_wdata[31:0]};
          else update_access_exception = 1'b1;
        end

        riscv::CSR_MSCRATCH: mscratch_d = csr_wdata;
        riscv::CSR_PVM_CFG0: pvm_cfg0_d = csr_wdata;
        riscv::CSR_PVM_CFG1: begin
          pvm_cfg1_d = csr_wdata;
          // PVMCFG1 flips the entire front-end mode (RISC-V <-> PVM). Treat it like
          // the other mode-changing CSRs (mstatus/satp above, which set flush_o) and
          // flush the pipeline: the mode switch then lands on a drained pipe, so no
          // in-flight RISC-V handler control flow (the `j wait_pvm` busy loop, the
          // host-call handler's branches) races the PVM enter/re-entry. This fences
          // the transition that the "djump CFG2 timing race" exposed -- adding the
          // startup `csrw CFG2` shifted pipeline timing enough to make the rising-edge
          // re-entry miss on rapid back-to-back ecalli resumes (M1). See the phase log
          // (robust-fix-proposal.md, B1: flush-only).
          flush_o = 1'b1;
        end
        riscv::CSR_PVM_CFG2: pvm_cfg2_d = csr_wdata;
        riscv::CSR_PVM_VEC:  pvm_vec_d = csr_wdata;
        riscv::CSR_PVM_RAM:  pvm_ram_d = csr_wdata;
        riscv::CSR_PVM_IMG:  pvm_img_we_o = 1'b1;  // 1-cycle img_mem write pulse (data in pvm_img_w_o)
        riscv::CSR_MEPC: mepc_d = {csr_wdata[CVA6Cfg.XLEN-1:1], 1'b0};
        riscv::CSR_MCAUSE: mcause_d = csr_wdata;
        riscv::CSR_MTVAL: begin
          if (CVA6Cfg.TvalEn) mtval_d = csr_wdata;
        end
        riscv::CSR_MIP: begin
          if (CVA6Cfg.RVS) begin
            mask = CVA6Cfg.XLEN'(riscv::MIP_SSIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_STIP)
                    | CVA6Cfg.XLEN'(riscv::MIP_SEIP);
          end else begin
            mask = '0;
          end
          mip_d = (mip_q & ~mask) | (csr_wdata & mask);
        end
        riscv::CSR_MENVCFG: begin
          if (CVA6Cfg.RVU) begin
            fiom_d = csr_wdata[0];
          end
        end
        riscv::CSR_MENVCFGH: begin
          if (!CVA6Cfg.RVU || CVA6Cfg.XLEN != 32) update_access_exception = 1'b1;
        end
        riscv::CSR_MCOUNTINHIBIT:
        if (CVA6Cfg.PerfCounterEn)
          mcountinhibit_d = {csr_wdata[MHPMCounterNum+2:2], 1'b0, csr_wdata[0]};
        else mcountinhibit_d = '0;
        // performance counters
        riscv::CSR_MCYCLE: cycle_d[CVA6Cfg.XLEN-1:0] = csr_wdata;
        riscv::CSR_MCYCLEH:
        if (CVA6Cfg.XLEN == 32) cycle_d[63:32] = csr_wdata;
        else update_access_exception = 1'b1;
        riscv::CSR_MINSTRET: instret_d[CVA6Cfg.XLEN-1:0] = csr_wdata;
        riscv::CSR_MINSTRETH:
        if (CVA6Cfg.XLEN == 32) instret_d[63:32] = csr_wdata;
        else update_access_exception = 1'b1;
        //Event Selector
        riscv::CSR_MHPM_EVENT_3,
                riscv::CSR_MHPM_EVENT_4,
                riscv::CSR_MHPM_EVENT_5,
                riscv::CSR_MHPM_EVENT_6,
                riscv::CSR_MHPM_EVENT_7,
                riscv::CSR_MHPM_EVENT_8,
                riscv::CSR_MHPM_EVENT_9,
                riscv::CSR_MHPM_EVENT_10,
                riscv::CSR_MHPM_EVENT_11,
                riscv::CSR_MHPM_EVENT_12,
                riscv::CSR_MHPM_EVENT_13,
                riscv::CSR_MHPM_EVENT_14,
                riscv::CSR_MHPM_EVENT_15,
                riscv::CSR_MHPM_EVENT_16,
                riscv::CSR_MHPM_EVENT_17,
                riscv::CSR_MHPM_EVENT_18,
                riscv::CSR_MHPM_EVENT_19,
                riscv::CSR_MHPM_EVENT_20,
                riscv::CSR_MHPM_EVENT_21,
                riscv::CSR_MHPM_EVENT_22,
                riscv::CSR_MHPM_EVENT_23,
                riscv::CSR_MHPM_EVENT_24,
                riscv::CSR_MHPM_EVENT_25,
                riscv::CSR_MHPM_EVENT_26,
                riscv::CSR_MHPM_EVENT_27,
                riscv::CSR_MHPM_EVENT_28,
                riscv::CSR_MHPM_EVENT_29,
                riscv::CSR_MHPM_EVENT_30,
                riscv::CSR_MHPM_EVENT_31 :     begin
          perf_we_o   = 1'b1;
          perf_data_o = csr_wdata;
        end

        riscv::CSR_MHPM_COUNTER_3,
                riscv::CSR_MHPM_COUNTER_4,
                riscv::CSR_MHPM_COUNTER_5,
                riscv::CSR_MHPM_COUNTER_6,
                riscv::CSR_MHPM_COUNTER_7,
                riscv::CSR_MHPM_COUNTER_8,
                riscv::CSR_MHPM_COUNTER_9,
                riscv::CSR_MHPM_COUNTER_10,
                riscv::CSR_MHPM_COUNTER_11,
                riscv::CSR_MHPM_COUNTER_12,
                riscv::CSR_MHPM_COUNTER_13,
                riscv::CSR_MHPM_COUNTER_14,
                riscv::CSR_MHPM_COUNTER_15,
                riscv::CSR_MHPM_COUNTER_16,
                riscv::CSR_MHPM_COUNTER_17,
                riscv::CSR_MHPM_COUNTER_18,
                riscv::CSR_MHPM_COUNTER_19,
                riscv::CSR_MHPM_COUNTER_20,
                riscv::CSR_MHPM_COUNTER_21,
                riscv::CSR_MHPM_COUNTER_22,
                riscv::CSR_MHPM_COUNTER_23,
                riscv::CSR_MHPM_COUNTER_24,
                riscv::CSR_MHPM_COUNTER_25,
                riscv::CSR_MHPM_COUNTER_26,
                riscv::CSR_MHPM_COUNTER_27,
                riscv::CSR_MHPM_COUNTER_28,
                riscv::CSR_MHPM_COUNTER_29,
                riscv::CSR_MHPM_COUNTER_30,
                riscv::CSR_MHPM_COUNTER_31 :  begin
          perf_we_o   = 1'b1;
          perf_data_o = csr_wdata;
        end

        riscv::CSR_MHPM_COUNTER_3H,
                riscv::CSR_MHPM_COUNTER_4H,
                riscv::CSR_MHPM_COUNTER_5H,
                riscv::CSR_MHPM_COUNTER_6H,
                riscv::CSR_MHPM_COUNTER_7H,
                riscv::CSR_MHPM_COUNTER_8H,
                riscv::CSR_MHPM_COUNTER_9H,
                riscv::CSR_MHPM_COUNTER_10H,
                riscv::CSR_MHPM_COUNTER_11H,
                riscv::CSR_MHPM_COUNTER_12H,
                riscv::CSR_MHPM_COUNTER_13H,
                riscv::CSR_MHPM_COUNTER_14H,
                riscv::CSR_MHPM_COUNTER_15H,
                riscv::CSR_MHPM_COUNTER_16H,
                riscv::CSR_MHPM_COUNTER_17H,
                riscv::CSR_MHPM_COUNTER_18H,
                riscv::CSR_MHPM_COUNTER_19H,
                riscv::CSR_MHPM_COUNTER_20H,
                riscv::CSR_MHPM_COUNTER_21H,
                riscv::CSR_MHPM_COUNTER_22H,
                riscv::CSR_MHPM_COUNTER_23H,
                riscv::CSR_MHPM_COUNTER_24H,
                riscv::CSR_MHPM_COUNTER_25H,
                riscv::CSR_MHPM_COUNTER_26H,
                riscv::CSR_MHPM_COUNTER_27H,
                riscv::CSR_MHPM_COUNTER_28H,
                riscv::CSR_MHPM_COUNTER_29H,
                riscv::CSR_MHPM_COUNTER_30H,
                riscv::CSR_MHPM_COUNTER_31H :  begin
          perf_we_o = 1'b1;
          if (CVA6Cfg.XLEN == 32) perf_data_o = csr_wdata;
          else update_access_exception = 1'b1;
        end

        riscv::CSR_DCACHE: dcache_d = {{CVA6Cfg.XLEN - 1{1'b0}}, csr_wdata[0]};  // enable bit
        riscv::CSR_ICACHE: icache_d = {{CVA6Cfg.XLEN - 1{1'b0}}, csr_wdata[0]};  // enable bit
        riscv::CSR_ACC_CONS: update_access_exception = 1'b1;
        // PMP locked logic
        // 1. refuse to update any locked entry
        // 2. also refuse to update the entry below a locked TOR entry
        // Note that writes to pmpcfg below a locked TOR entry are valid
        riscv::CSR_PMPCFG0,
                riscv::CSR_PMPCFG1,
                riscv::CSR_PMPCFG2,
                riscv::CSR_PMPCFG3,
                riscv::CSR_PMPCFG4,
                riscv::CSR_PMPCFG5,
                riscv::CSR_PMPCFG6,
                riscv::CSR_PMPCFG7,
                riscv::CSR_PMPCFG8,
                riscv::CSR_PMPCFG9,
                riscv::CSR_PMPCFG10,
                riscv::CSR_PMPCFG11,
                riscv::CSR_PMPCFG12,
                riscv::CSR_PMPCFG13,
                riscv::CSR_PMPCFG14,
                riscv::CSR_PMPCFG15: begin
          // index is calculated using PMPCFG0 as the offset
          automatic logic [11:0] index = csr_addr.address[11:0] - riscv::CSR_PMPCFG0;

          // if index is not even and XLEN==64, raise exception
          if (CVA6Cfg.XLEN == 64 && index[0] == 1'b1) update_access_exception = 1'b1;
          else begin
            for (int i = 0; i < CVA6Cfg.XLEN / 8; i++) begin
              if (!pmpcfg_q[index*4+i].locked) pmpcfg_d[index*4+i] = csr_wdata[i*8+:8];
            end
          end
        end
        riscv::CSR_PMPADDR0,
                riscv::CSR_PMPADDR1,
                riscv::CSR_PMPADDR2,
                riscv::CSR_PMPADDR3,
                riscv::CSR_PMPADDR4,
                riscv::CSR_PMPADDR5,
                riscv::CSR_PMPADDR6,
                riscv::CSR_PMPADDR7,
                riscv::CSR_PMPADDR8,
                riscv::CSR_PMPADDR9,
                riscv::CSR_PMPADDR10,
                riscv::CSR_PMPADDR11,
                riscv::CSR_PMPADDR12,
                riscv::CSR_PMPADDR13,
                riscv::CSR_PMPADDR14,
                riscv::CSR_PMPADDR15,
                riscv::CSR_PMPADDR16,
                riscv::CSR_PMPADDR17,
                riscv::CSR_PMPADDR18,
                riscv::CSR_PMPADDR19,
                riscv::CSR_PMPADDR20,
                riscv::CSR_PMPADDR21,
                riscv::CSR_PMPADDR22,
                riscv::CSR_PMPADDR23,
                riscv::CSR_PMPADDR24,
                riscv::CSR_PMPADDR25,
                riscv::CSR_PMPADDR26,
                riscv::CSR_PMPADDR27,
                riscv::CSR_PMPADDR28,
                riscv::CSR_PMPADDR29,
                riscv::CSR_PMPADDR30,
                riscv::CSR_PMPADDR31,
                riscv::CSR_PMPADDR32,
                riscv::CSR_PMPADDR33,
                riscv::CSR_PMPADDR34,
                riscv::CSR_PMPADDR35,
                riscv::CSR_PMPADDR36,
                riscv::CSR_PMPADDR37,
                riscv::CSR_PMPADDR38,
                riscv::CSR_PMPADDR39,
                riscv::CSR_PMPADDR40,
                riscv::CSR_PMPADDR41,
                riscv::CSR_PMPADDR42,
                riscv::CSR_PMPADDR43,
                riscv::CSR_PMPADDR44,
                riscv::CSR_PMPADDR45,
                riscv::CSR_PMPADDR46,
                riscv::CSR_PMPADDR47,
                riscv::CSR_PMPADDR48,
                riscv::CSR_PMPADDR49,
                riscv::CSR_PMPADDR50,
                riscv::CSR_PMPADDR51,
                riscv::CSR_PMPADDR52,
                riscv::CSR_PMPADDR53,
                riscv::CSR_PMPADDR54,
                riscv::CSR_PMPADDR55,
                riscv::CSR_PMPADDR56,
                riscv::CSR_PMPADDR57,
                riscv::CSR_PMPADDR58,
                riscv::CSR_PMPADDR59,
                riscv::CSR_PMPADDR60,
                riscv::CSR_PMPADDR61,
                riscv::CSR_PMPADDR62,
                riscv::CSR_PMPADDR63: begin
          // index is calculated using PMPADDR0 as the offset
          automatic logic [11:0] index = csr_addr.address[11:0] - riscv::CSR_PMPADDR0;
          // check if the entry or the entry above is locked
          if (!pmpcfg_q[index].locked && !(pmpcfg_q[index+1].locked && pmpcfg_q[index+1].addr_mode == riscv::TOR)) begin
            pmpaddr_d[index] = csr_wdata[CVA6Cfg.PLEN-3:0];
          end
        end
        default: update_access_exception = 1'b1;
      endcase
    end
    if (CVA6Cfg.IS_XLEN64) begin
      if (CVA6Cfg.RVS) mstatus_d.sxl = riscv::XLEN_64;
      else mstatus_d.sxl = riscv::XLEN_NA;
      if (CVA6Cfg.RVU) mstatus_d.uxl = riscv::XLEN_64;
      else mstatus_d.uxl = riscv::XLEN_NA;
    end
    if (!CVA6Cfg.RVU) begin
      mstatus_d.mpp = riscv::PRIV_LVL_M;
    end

    // No FP, no vector: SD always off
    if (CVA6Cfg.RVS) begin
      mstatus_d.sd = (mstatus_q.xs == riscv::Dirty);
    end else begin
      mstatus_d.sd = riscv::Off;
    end

    // reserve PMPCFG bits 5 and 6 (hardwire to 0)
    for (int i = 0; i < CVA6Cfg.NrPMPEntries; i++) pmpcfg_d[i].reserved = 2'b0;

    // ---------------------
    // External Interrupts
    // ---------------------
    // Machine Mode External Interrupt Pending
    mip_d[riscv::IRQ_M_EXT] = irq_i[0];
    // Machine software interrupt
    mip_d[riscv::IRQ_M_SOFT] = CVA6Cfg.SoftwareInterruptEn && ipi_i;
    // Timer interrupt pending, coming from platform timer
    mip_d[riscv::IRQ_M_TIMER] = time_irq_i;

    // -----------------------
    // Manage Exception Stack
    // -----------------------
    // update exception CSRs
    // we got an exception update cause, pc and stval register
    trap_to_priv_lvl = riscv::PRIV_LVL_M;
    // Exception is taken and we are not in debug mode
    // exceptions in debug mode don't update any fields
    if ((CVA6Cfg.DebugEn && !debug_mode_q && ex_i.cause != riscv::DEBUG_REQUEST && ex_i.valid) || (!CVA6Cfg.DebugEn && ex_i.valid) || (!CVA6Cfg.DebugEn && CVA6Cfg.SDTRIG && break_from_trigger)) begin
      // do not flush, flush is reserved for CSR writes with side effects
      flush_o = 1'b0;
      // figure out where to trap to
      // a m-mode trap might be delegated if we are taking it in S mode
      // first figure out if this was an exception or an interrupt e.g.: look at bit (XLEN-1)
      // the cause register can only be $clog2(CVA6Cfg.XLEN) bits long (as we only support XLEN exceptions)
      if (CVA6Cfg.RVS) begin
        if ((ex_i.cause[CVA6Cfg.XLEN-1] && mideleg_q[ex_i.cause[$clog2(
                CVA6Cfg.XLEN
            )-1:0]]) || (~ex_i.cause[CVA6Cfg.XLEN-1] && medeleg_q[ex_i.cause[$clog2(
                CVA6Cfg.XLEN
            )-1:0]])) begin
          // traps never transition from a more-privileged mode to a less privileged mode
          // so if we are already in M mode, stay there
          trap_to_priv_lvl = (priv_lvl_o == riscv::PRIV_LVL_M) ? riscv::PRIV_LVL_M : riscv::PRIV_LVL_S;
        end
      end

      // trap to supervisor mode
      if (CVA6Cfg.RVS && trap_to_priv_lvl == riscv::PRIV_LVL_S) begin
          // update sstatus
          mstatus_d.sie = 1'b0;
          mstatus_d.spie = mstatus_q.sie;
          // this can either be user or supervisor mode
          mstatus_d.spp = priv_lvl_q[0];
          // set cause
          scause_d = ex_i.cause;
          // set epc (PVM Stage 2: override with the post-ecalli pc on a guest-ecalli stay-trap)
          sepc_d = (CVA6Cfg.PvmPresent && pvm_epc_override_valid_i)
                       ? pvm_epc_override_i
                       : {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{pc_i[CVA6Cfg.VLEN-1]}}, pc_i};
          // set stval
          stval_d        = (ariane_pkg::ZERO_TVAL
                                  && (ex_i.cause inside {
                                    riscv::ILLEGAL_INSTR,
                                    riscv::BREAKPOINT,
                                    riscv::ENV_CALL_UMODE,
                                    riscv::ENV_CALL_SMODE,
                                    riscv::ENV_CALL_MMODE
                                  } || ex_i.cause[CVA6Cfg.XLEN-1])) ? '0 : ex_i.tval;
        // trap to machine mode
      end else begin
        // update mstatus
        mstatus_d.mie = 1'b0;
        mstatus_d.mpie = mstatus_q.mie;
        // save the previous privilege mode
        mstatus_d.mpp = priv_lvl_q;
        mcause_d = (break_from_trigger) ? 32'h00000003 : ex_i.cause;
        // set epc (PVM Stage 2: override with the post-ecalli pc on a guest-ecalli stay-trap)
        mepc_d = (CVA6Cfg.PvmPresent && pvm_epc_override_valid_i)
                     ? pvm_epc_override_i
                     : {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{pc_i[CVA6Cfg.VLEN-1]}}, pc_i};
        // set mtval or stval
        if (CVA6Cfg.TvalEn) begin
          mtval_d        = (ariane_pkg::ZERO_TVAL
                                    && (ex_i.cause inside {
                                      riscv::ILLEGAL_INSTR,
                                      riscv::BREAKPOINT,
                                      riscv::ENV_CALL_UMODE,
                                      riscv::ENV_CALL_SMODE,
                                      riscv::ENV_CALL_MMODE
                                    } || ex_i.cause[CVA6Cfg.GPLEN-1])) ? '0 : ex_i.tval;
        end else begin
          mtval_d = '0;
        end

      end

      priv_lvl_d = trap_to_priv_lvl;
    end

    // ------------------------------
    // Debug
    // ------------------------------
    // Explains why Debug Mode was entered.
    // When there are multiple reasons to enter Debug Mode in a single cycle, hardware should set cause to the cause with the highest priority.
    // 1: An ebreak instruction was executed. (priority 3)
    // 2: The Trigger Module caused a breakpoint exception. (priority 4)
    // 3: The debugger requested entry to Debug Mode. (priority 2)
    // 4: The hart single stepped because step was set. (priority 1)
    // we are currently not in debug mode and could potentially enter
    if (CVA6Cfg.DebugEn && !debug_mode_q) begin
      dcsr_d.prv = priv_lvl_o;
      dcsr_d.v   = 1'b0;

      // trigger module fired
      if (CVA6Cfg.SDTRIG && debug_from_trigger) begin
        dcsr_d.prv = priv_lvl_o;
        dcsr_d.v = 1'b0;
        dpc_d = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{pc_i[CVA6Cfg.VLEN-1]}}, pc_i};
        debug_mode_d = 1'b1;
        set_debug_pc_o = 1'b1;
        dcsr_d.cause = ariane_pkg::CauseTrigger;
      end

      // caused by a breakpoint
      if (ex_i.valid && ex_i.cause == riscv::BREAKPOINT) begin
        dcsr_d.prv = priv_lvl_o;
        dcsr_d.v   = 1'b0;
        // check that we actually want to enter debug depending on the privilege level we are currently in
        unique case (priv_lvl_o)
          riscv::PRIV_LVL_M: begin
            debug_mode_d   = dcsr_q.ebreakm;
            set_debug_pc_o = dcsr_q.ebreakm;
          end
          riscv::PRIV_LVL_S: begin
            if (CVA6Cfg.RVS) begin
              debug_mode_d   = dcsr_q.ebreaks;
              set_debug_pc_o = dcsr_q.ebreaks;
            end
          end
          riscv::PRIV_LVL_U: begin
            if (CVA6Cfg.RVU) begin
              debug_mode_d   = dcsr_q.ebreaku;
              set_debug_pc_o = dcsr_q.ebreaku;
            end
          end
          default: ;
        endcase
        // save PC of next this instruction e.g.: the next one to be executed
        dpc_d = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{pc_i[CVA6Cfg.VLEN-1]}}, pc_i};
        dcsr_d.cause = ariane_pkg::CauseBreakpoint;
      end

      // we've got a debug request
      if (ex_i.valid && ex_i.cause == riscv::DEBUG_REQUEST) begin
        dcsr_d.prv = priv_lvl_o;
        dcsr_d.v = 1'b0;
        // save the PC
        dpc_d = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{pc_i[CVA6Cfg.VLEN-1]}}, pc_i};
        // enter debug mode
        debug_mode_d = 1'b1;
        // jump to the base address
        set_debug_pc_o = 1'b1;
        // save the cause as external debug request
        dcsr_d.cause = ariane_pkg::CauseRequest;
      end

      // single step enable and we just retired an instruction
      if (dcsr_q.step && commit_ack_i[0]) begin
        dcsr_d.prv = priv_lvl_o;
        dcsr_d.v   = 1'b0;
        // valid CTRL flow change
        if (commit_instr_i.fu == CTRL_FLOW) begin
          // we saved the correct target address during execute
          dpc_d = {
            {CVA6Cfg.XLEN - CVA6Cfg.VLEN{commit_instr_i.bp.predict_address[CVA6Cfg.VLEN-1]}},
            commit_instr_i.bp.predict_address
          };
          // exception valid
        end else if (ex_i.valid) begin
          dpc_d = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, trap_vector_base_o};
          // return from environment
        end else if (eret_o) begin
          dpc_d = {{CVA6Cfg.XLEN - CVA6Cfg.VLEN{1'b0}}, epc_o};
          // consecutive PC
        end else begin
          dpc_d = {
            {CVA6Cfg.XLEN - CVA6Cfg.VLEN{commit_instr_i.pc[CVA6Cfg.VLEN-1]}},
            commit_instr_i.pc + (commit_instr_i.is_compressed ? 'h2 : 'h4)
          };
        end
        debug_mode_d   = 1'b1;
        set_debug_pc_o = 1'b1;
        dcsr_d.cause   = ariane_pkg::CauseSingleStep;
      end
    end
    // go in halt-state again when we encounter an exception
    if (CVA6Cfg.DebugEn && debug_mode_q && ex_i.valid && ex_i.cause == riscv::BREAKPOINT) begin
      set_debug_pc_o = 1'b1;
    end

    // ------------------------------
    // MPRV - Modify Privilege Level
    // ------------------------------
    // Set the address translation at which the load and stores should occur
    // we can use the previous values since changing the address translation will always involve a pipeline flush
    if (CVA6Cfg.MmuPresent && mprv && CVA6Cfg.RVS && config_pkg::vm_mode_t'(satp_q.mode) == CVA6Cfg.MODE_SV && (mstatus_q.mpp != riscv::PRIV_LVL_M))
      en_ld_st_translation_d = 1'b1;
    else  // otherwise we go with the regular settings
      en_ld_st_translation_d = en_translation_o;

    if (CVA6Cfg.RVU) begin
      ld_st_priv_lvl_o = (mprv) ? mstatus_q.mpp : priv_lvl_o;
    end else begin
      ld_st_priv_lvl_o = priv_lvl_o;
    end
    en_ld_st_translation_o = en_ld_st_translation_q;
    ld_st_v_o = 1'b0;
    en_ld_st_g_translation_o = 1'b0;
    // ------------------------------
    // Return from Environment
    // ------------------------------
    // When executing an xRET instruction, supposing xPP holds the value y, xIE is set to xPIE; the privilege
    // mode is changed to y; xPIE is set to 1; and xPP is set to U
    if (mret) begin
      // return from exception, IF doesn't care from where we are returning
      eret_o        = 1'b1;
      // return to the previous privilege level and restore all enable flags
      // get the previous machine interrupt enable flag
      mstatus_d.mie = mstatus_q.mpie;
      // restore the previous privilege level
      priv_lvl_d    = mstatus_q.mpp;
      mstatus_d.mpp = riscv::PRIV_LVL_M;
      if (CVA6Cfg.RVU) begin
        // set mpp to user mode
        mstatus_d.mpp = riscv::PRIV_LVL_U;
      end
      // set mpie to 1
      mstatus_d.mpie = 1'b1;
    end

    if (CVA6Cfg.RVS && sret) begin
      // return from exception, IF doesn't care from where we are returning
      eret_o         = 1'b1;
      // return the previous supervisor interrupt enable flag
      mstatus_d.sie  = mstatus_q.spie;
      // restore the previous privilege level
      priv_lvl_d     = riscv::priv_lvl_t'({1'b0, mstatus_q.spp});
      // set spp to user mode
      mstatus_d.spp  = 1'b0;
      // set spie to 1
      mstatus_d.spie = 1'b1;
    end

    // return from debug mode
    if (CVA6Cfg.DebugEn) begin
      if (dret) begin
        // return from exception, IF doesn't care from where we are returning
        eret_o     = 1'b1;
        // restore the previous privilege level
        priv_lvl_d = riscv::priv_lvl_t'(dcsr_q.prv);
        // actually return from debug mode
        debug_mode_d = 1'b0;
      end
    end
  end

  // ---------------------------
  // CSR OP Select Logic
  // ---------------------------
  always_comb begin : csr_op_logic
    csr_wdata = csr_wdata_i;
    csr_we    = 1'b1;
    csr_read  = 1'b1;
    mret      = 1'b0;
    sret      = 1'b0;
    dret      = 1'b0;

    unique case (csr_op_i)
      CSR_WRITE: csr_wdata = csr_wdata_i;
      CSR_SET:   csr_wdata = csr_wdata_i | csr_rdata;
      CSR_CLEAR: csr_wdata = (~csr_wdata_i) & csr_rdata;
      CSR_READ:  csr_we = 1'b0;
      MRET: begin
        // the return should not have any write or read side-effects
        csr_we   = 1'b0;
        csr_read = 1'b0;
        mret     = 1'b1;  // signal a return from machine mode
      end
      default: begin
        if (CVA6Cfg.RVS && csr_op_i == SRET) begin
          // the return should not have any write or read side-effects
          csr_we   = 1'b0;
          csr_read = 1'b0;
          sret     = 1'b1;  // signal a return from supervisor mode
        end else if (CVA6Cfg.DebugEn && csr_op_i == DRET) begin
          // the return should not have any write or read side-effects
          csr_we   = 1'b0;
          csr_read = 1'b0;
          dret     = 1'b1;  // signal a return from debug mode
        end else begin
          csr_we   = 1'b0;
          csr_read = 1'b0;
        end
      end
    endcase
    // if we are violating our privilges do not update the architectural state
    if (privilege_violation) begin
      csr_we   = 1'b0;
      csr_read = 1'b0;
    end
  end

  assign irq_ctrl_o.mie = mie_q;
  assign irq_ctrl_o.mip = mip_q;
  assign irq_ctrl_o.sie = mstatus_q.sie;
  assign irq_ctrl_o.mideleg = (CVA6Cfg.RVS) ? mideleg_q : '0;
  assign irq_ctrl_o.hideleg = '0;
  assign irq_ctrl_o.global_enable = ~(CVA6Cfg.DebugEn & debug_mode_q)
      // interrupts are enabled during single step or we are not stepping
      // No need to check interrupts during single step if we don't support DEBUG mode
      & (~CVA6Cfg.DebugEn | (~dcsr_q.step | dcsr_q.stepie))
                                    & ((mstatus_q.mie & (priv_lvl_o == riscv::PRIV_LVL_M))
                                    | (CVA6Cfg.RVU & priv_lvl_o != riscv::PRIV_LVL_M));

  always_comb begin : privilege_check
      // -----------------
      // Privilege Check
      // -----------------
      privilege_violation = 1'b0;
      // if we are reading or writing, check for the correct privilege level this has
      // precedence over interrupts
      if (csr_op_i inside {CSR_WRITE, CSR_SET, CSR_CLEAR, CSR_READ}) begin
        if (CVA6Cfg.RVU && (riscv::priv_lvl_t'(priv_lvl_o & csr_addr.csr_decode.priv_lvl) != csr_addr.csr_decode.priv_lvl)) begin
          privilege_violation = 1'b1;
        end
        // check access to debug mode only CSRs
        if ((!CVA6Cfg.DebugEn && csr_addr_i[11:4] == 8'h7b) || (CVA6Cfg.DebugEn && csr_addr_i[11:4] == 8'h7b && !debug_mode_q)) begin
          privilege_violation = 1'b1;
        end
        // check counter-enabled counter CSR accesses
        // counter address range is C00 to C1F
        if (CVA6Cfg.RVZihpm) begin
          if (csr_addr_i inside {[riscv::CSR_HPM_COUNTER_3 : riscv::CSR_HPM_COUNTER_31]} |
              csr_addr_i inside {[riscv::CSR_HPM_COUNTER_3H : riscv::CSR_HPM_COUNTER_31H]}) begin
            if (priv_lvl_o == riscv::PRIV_LVL_S && CVA6Cfg.RVS) begin
              privilege_violation = ~mcounteren_q[csr_addr_i[4:0]];
            end else if (priv_lvl_o == riscv::PRIV_LVL_U && CVA6Cfg.RVU) begin
              privilege_violation = ~mcounteren_q[csr_addr_i[4:0]] | ~scounteren_q[csr_addr_i[4:0]];
            end else if (priv_lvl_o == riscv::PRIV_LVL_M) begin
              privilege_violation = 1'b0;
            end
          end
        end
        if (CVA6Cfg.RVZicntr) begin
          if (csr_addr_i inside {[riscv::CSR_CYCLE : riscv::CSR_INSTRET]} |
              csr_addr_i inside {[riscv::CSR_CYCLEH : riscv::CSR_INSTRETH]}) begin
            if (priv_lvl_o == riscv::PRIV_LVL_S && CVA6Cfg.RVS) begin
              privilege_violation = ~mcounteren_q[csr_addr_i[4:0]];
            end else if (priv_lvl_o == riscv::PRIV_LVL_U && CVA6Cfg.RVU) begin
              privilege_violation = ~mcounteren_q[csr_addr_i[4:0]] | ~scounteren_q[csr_addr_i[4:0]];
            end else if (priv_lvl_o == riscv::PRIV_LVL_M) begin
              privilege_violation = 1'b0;
            end
          end
        end
      end
  end
  // ----------------------
  // CSR Exception Control
  // ----------------------
  always_comb begin : exception_ctrl
    csr_exception_o = {
      {CVA6Cfg.XLEN{1'b0}}, {CVA6Cfg.XLEN{1'b0}}, {CVA6Cfg.GPLEN{1'b0}}, {32{1'b0}}, 1'b0, 1'b0
    };
    // ----------------------------------
    // Illegal Access (decode exception)
    // ----------------------------------
    // we got an exception in one of the processes above
    // throw an illegal instruction exception
    if (update_access_exception || read_access_exception) begin
      csr_exception_o.cause = riscv::ILLEGAL_INSTR;
      // we don't set the tval field as this will be set by the commit stage
      // this spares the extra wiring from commit to CSR and back to commit
      csr_exception_o.valid = 1'b1;
    end

    if (privilege_violation) begin
      csr_exception_o.cause = riscv::ILLEGAL_INSTR;
      csr_exception_o.valid = 1'b1;
    end

  end

  // -------------------
  // Wait for Interrupt
  // -------------------
  always_comb begin : wfi_ctrl
    // wait for interrupt register
    wfi_d = wfi_q;
    // if there is any (enabled) interrupt pending un-stall the core
    // also un-stall if we want to enter debug mode
    if (|(mip_q & mie_q) || (CVA6Cfg.DebugEn && debug_req_i) || irq_i[1]) begin
      wfi_d = 1'b0;
      // or alternatively if there is no exception pending and we are not in debug mode wait here
      // for the interrupt
    end else if (((CVA6Cfg.DebugEn && !debug_mode_q) && csr_op_i == WFI && !ex_i.valid) || (!CVA6Cfg.DebugEn && csr_op_i == WFI && !ex_i.valid)) begin
      wfi_d = 1'b1;
    end
  end

  // output assignments dependent on privilege mode
  always_comb begin : priv_output
    // PVM: preserve mtvec bit 1 (2B-aligned PVM code-address) on the trap-vector redirect.
    trap_vector_base_o = {mtvec_q[CVA6Cfg.VLEN-1:2], (CVA6Cfg.PvmPresent ? mtvec_q[1] : 1'b0), 1'b0};
    // output user mode stvec
    if (CVA6Cfg.RVS && trap_to_priv_lvl == riscv::PRIV_LVL_S) begin
      trap_vector_base_o = {stvec_q[CVA6Cfg.VLEN-1:2], 2'b0};
    end

    // if we are in debug mode jump to a specific address
    if (CVA6Cfg.DebugEn && debug_mode_q) begin
      trap_vector_base_o = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0] + CVA6Cfg.ExceptionAddress[CVA6Cfg.VLEN-1:0];
    end

    // check if we are in vectored mode, if yes then do BASE + 4 * cause we
    // are imposing an additional alignment-constraint of 64 * 4 bytes since
    // we want to spare the costly addition. Furthermore check to which
    // privilege level we are jumping and whether the vectored mode is
    // activated for _that_ privilege level.
    if (ex_i.cause[CVA6Cfg.XLEN-1] &&
                ((((CVA6Cfg.RVS || CVA6Cfg.RVU) && trap_to_priv_lvl == riscv::PRIV_LVL_M && (!CVA6Cfg.DirectVecOnly && mtvec_q[0])) || (!CVA6Cfg.RVS && !CVA6Cfg.RVU && (!CVA6Cfg.DirectVecOnly && mtvec_q[0])))
               || (CVA6Cfg.RVS && trap_to_priv_lvl == riscv::PRIV_LVL_S && stvec_q[0]))) begin
      trap_vector_base_o[7:2] = ex_i.cause[5:0];
    end

    // B4: a PVM host-boundary exit (ecalli / panic / illegal / clean-halt, flagged by the
    // cva6 adapter) is delivered to CSR_PVM_VEC instead of mtvec -- so a guest (e.g. OpenSBI)
    // doing `csrw mtvec` cannot steal the host hypervisor's hook. Authoritative (overrides
    // mtvec/stvec/vectored). Guest-internal RISC-V faults (FU writeback) are NOT flagged and
    // keep using mtvec/stvec. PvmPresent-gated + pvm_use_vec_i=0 for every non-PVM exception,
    // so the standard RISC-V trap path is byte-identical when this is off.
    // CSR_PVM_VEC==0 means "unset" -> fall back to mtvec (backward-compatible: gates/hosts
    // that never set CSR_PVM_VEC keep the original ecalli/trap->mtvec delivery).
    if (CVA6Cfg.PvmPresent && pvm_use_vec_i && (|pvm_vec_q))
      trap_vector_base_o = {pvm_vec_q[CVA6Cfg.VLEN-1:2], 2'b0};

    epc_o = mepc_q[CVA6Cfg.VLEN-1:0];
    // we are returning from supervisor mode, so take the sepc register
    if (CVA6Cfg.RVS) begin
      if (sret) begin
        epc_o = sepc_q[CVA6Cfg.VLEN-1:0];
      end
    end
    // we are returning from debug mode, to take the dpc register
    if (CVA6Cfg.DebugEn) begin
      if (dret) begin
        epc_o = dpc_q[CVA6Cfg.VLEN-1:0];
      end
    end
  end

  // -------------------
  // Output Assignments
  // -------------------
  always_comb begin
    // When the SEIP bit is read with a CSRRW, CSRRS, or CSRRC instruction, the value
    // returned in the rd destination register contains the logical-OR of the software-writable
    // bit and the interrupt signal from the interrupt controller.
    csr_rdata_o = csr_rdata;

    unique case (conv_csr_addr.address)
      riscv::CSR_MIP:
      csr_rdata_o = csr_rdata | ({{CVA6Cfg.XLEN - 1{1'b0}}, CVA6Cfg.RVS && irq_i[1]} << riscv::IRQ_S_EXT);
      // in supervisor mode we also need to check whether we delegated this bit
      riscv::CSR_SIP: begin
        if (CVA6Cfg.RVS) begin
          csr_rdata_o = csr_rdata
                              | ({{CVA6Cfg.XLEN-1{1'b0}}, (irq_i[1] & mideleg_q[riscv::IRQ_S_EXT])} << riscv::IRQ_S_EXT);
        end
      end
      default: ;
    endcase
  end

  // in debug mode we execute with privilege level M
  assign priv_lvl_o = (CVA6Cfg.DebugEn && debug_mode_q) ? riscv::PRIV_LVL_M : priv_lvl_q;
  assign v_o = 1'b0;
  // FPU outputs (disabled)
  assign fflags_o = '0;
  assign frm_o = '0;
  assign fprec_o = '0;
  //JVT outputs (disabled)
  assign jvt_o.base = '0;
  assign jvt_o.mode = '0;
  // MMU outputs
  assign satp_ppn_o  = CVA6Cfg.RVS ? satp_q.ppn : '0;
  assign vsatp_ppn_o = '0;
  assign hgatp_ppn_o = '0;
  if (CVA6Cfg.RVS) begin
    assign asid_o = satp_q.asid[CVA6Cfg.ASID_WIDTH-1:0];
  end else begin
    assign asid_o = '0;
  end
  assign vs_asid_o = '0;
  assign vmid_o = '0;
  assign sum_o = mstatus_q.sum;
  assign vs_sum_o = '0;
  assign hu_o = '0;

  assign mcbie_o = riscv::CBIE_ILLEGAL;
  assign scbie_o = riscv::CBIE_ILLEGAL;
  assign hcbie_o = riscv::CBIE_ILLEGAL;

  assign mcbcfe_o = 1'b0;
  assign scbcfe_o = 1'b0;
  assign hcbcfe_o = 1'b0;
  // we support bare memory addressing and SV39
  assign en_translation_o = (CVA6Cfg.RVS && config_pkg::vm_mode_t'(satp_q.mode) == CVA6Cfg.MODE_SV &&
                            priv_lvl_o != riscv::PRIV_LVL_M)
                           ? 1'b1
                           : 1'b0;
  assign en_g_translation_o = 1'b0;
  assign mxr_o  = mstatus_q.mxr;
  assign vmxr_o = '0;
  assign tvm_o = mstatus_q.tvm;
  assign tw_o  = mstatus_q.tw;
  assign vtw_o = '0;
  assign tsr_o = mstatus_q.tsr;
  assign halt_csr_o = wfi_q;
`ifdef PITON_ARIANE
  assign icache_en_o = icache_q[0];
`else
  assign icache_en_o = icache_q[0] & ~(CVA6Cfg.DebugEn && debug_mode_q);
`endif
  assign dcache_en_o = dcache_q[0];
  assign acc_cons_en_o = 1'b0;

  // determine if mprv needs to be considered if in debug mode
  assign mprv = (CVA6Cfg.DebugEn && debug_mode_q && !dcsr_q.mprven) ? 1'b0 : mstatus_q.mprv;
  assign debug_mode_o = debug_mode_q;
  assign single_step_o = CVA6Cfg.DebugEn ? dcsr_q.step : 1'b0;
  assign mcountinhibit_o = {{29 - MHPMCounterNum{1'b0}}, mcountinhibit_q};

  assign mbe_o = mstatus_q.mbe;

  // sequential process
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      priv_lvl_q <= riscv::PRIV_LVL_M;
      // floating-point registers
      fcsr_q     <= '0;
      // debug signals
      if (CVA6Cfg.DebugEn) begin
        debug_mode_q <= 1'b0;
        dcsr_q       <= '{xdebugver: 4'h4, prv: riscv::PRIV_LVL_M, default: '0};
        dpc_q        <= '0;
        dscratch0_q  <= {CVA6Cfg.XLEN{1'b0}};
        dscratch1_q  <= {CVA6Cfg.XLEN{1'b0}};
      end
      // machine mode registers
      mstatus_q        <= 64'b0;
      // set to boot address + direct mode + 4 byte offset which is the initial trap
      mtvec_rst_load_q <= 1'b1;
      mtvec_q          <= '0;
      mip_q            <= {CVA6Cfg.XLEN{1'b0}};
      mie_q            <= {CVA6Cfg.XLEN{1'b0}};
      mepc_q           <= {CVA6Cfg.XLEN{1'b0}};
      mcause_q         <= {CVA6Cfg.XLEN{1'b0}};
      mcounteren_q     <= {CVA6Cfg.XLEN{1'b0}};
      mscratch_q       <= {CVA6Cfg.XLEN{1'b0}};
      pvm_cfg0_q       <= {CVA6Cfg.XLEN{1'b0}};
      pvm_cfg1_q       <= {CVA6Cfg.XLEN{1'b0}};
      pvm_cfg2_q       <= {CVA6Cfg.XLEN{1'b0}};
      pvm_vec_q        <= {CVA6Cfg.XLEN{1'b0}};
      pvm_ram_q        <= {CVA6Cfg.XLEN{1'b0}};
      if (CVA6Cfg.TvalEn) mtval_q <= {CVA6Cfg.XLEN{1'b0}};
      fiom_q          <= '0;
      dcache_q        <= {{CVA6Cfg.XLEN - 1{1'b0}}, 1'b1};
      icache_q        <= {{CVA6Cfg.XLEN - 1{1'b0}}, 1'b1};
      mcountinhibit_q <= '0;
      acc_cons_q      <= '0;
      // supervisor mode registers
      if (CVA6Cfg.RVS) begin
        medeleg_q    <= {CVA6Cfg.XLEN{1'b0}};
        mideleg_q    <= {CVA6Cfg.XLEN{1'b0}};
        sepc_q       <= {CVA6Cfg.XLEN{1'b0}};
        scause_q     <= {CVA6Cfg.XLEN{1'b0}};
        stvec_q      <= {CVA6Cfg.XLEN{1'b0}};
        scounteren_q <= {CVA6Cfg.XLEN{1'b0}};
        sscratch_q   <= {CVA6Cfg.XLEN{1'b0}};
        stval_q      <= {CVA6Cfg.XLEN{1'b0}};
        satp_q       <= {CVA6Cfg.XLEN{1'b0}};
      end
      if (CVA6Cfg.SDTRIG) begin
        scontext_q <= '0;
      end
      // timer and counters
      cycle_q                <= 64'b0;
      instret_q              <= 64'b0;
      // aux registers
      en_ld_st_translation_q <= 1'b0;
      // wait for interrupt
      wfi_q                  <= 1'b0;
      // pmp
      for (int i = 0; i < 64; i++) begin
        if (i < CVA6Cfg.NrPMPEntries) begin
          pmpcfg_q[i]  <= riscv::pmpcfg_t'(CVA6Cfg.PMPCfgRstVal[i]);
          pmpaddr_q[i] <= CVA6Cfg.PMPAddrRstVal[i][CVA6Cfg.PLEN-3:0];
        end else begin
          pmpcfg_q[i]  <= '0;
          pmpaddr_q[i] <= '0;
        end
      end
    end else begin
      priv_lvl_q <= priv_lvl_d;
      // floating-point registers
      fcsr_q     <= fcsr_d;
      // debug signals
      if (CVA6Cfg.DebugEn) begin
        debug_mode_q <= debug_mode_d;
        dcsr_q       <= dcsr_d;
        dpc_q        <= dpc_d;
        dscratch0_q  <= dscratch0_d;
        dscratch1_q  <= dscratch1_d;
      end
      // machine mode registers
      mstatus_q        <= mstatus_d;
      mtvec_rst_load_q <= 1'b0;
      mtvec_q          <= mtvec_d;
      mip_q            <= mip_d;
      mie_q            <= mie_d;
      mepc_q           <= mepc_d;
      mcause_q         <= mcause_d;
      mcounteren_q     <= mcounteren_d;
      mscratch_q       <= mscratch_d;
      pvm_cfg0_q       <= pvm_cfg0_d;
      pvm_cfg1_q       <= pvm_cfg1_d;
      pvm_cfg2_q       <= pvm_cfg2_d;
      pvm_vec_q        <= pvm_vec_d;
      pvm_ram_q        <= pvm_ram_d;
      if (CVA6Cfg.TvalEn) mtval_q <= mtval_d;
      fiom_q          <= fiom_d;
      dcache_q        <= dcache_d;
      icache_q        <= icache_d;
      mcountinhibit_q <= mcountinhibit_d;
      acc_cons_q      <= acc_cons_d;
      // supervisor mode registers
      if (CVA6Cfg.RVS) begin
        medeleg_q    <= medeleg_d;
        mideleg_q    <= mideleg_d;
        sepc_q       <= sepc_d;
        scause_q     <= scause_d;
        stvec_q      <= stvec_d;
        scounteren_q <= scounteren_d;
        sscratch_q   <= sscratch_d;
        if (CVA6Cfg.TvalEn) stval_q <= stval_d;
        satp_q <= satp_d;
      end
      if (CVA6Cfg.SDTRIG) begin
        scontext_q <= scontext_d;
      end
      // timer and counters
      cycle_q                <= cycle_d;
      instret_q              <= instret_d;
      // aux registers
      en_ld_st_translation_q <= en_ld_st_translation_d;
      // wait for interrupt
      wfi_q                  <= wfi_d;
      // pmp
      pmpcfg_q               <= pmpcfg_next;
      pmpaddr_q              <= pmpaddr_next;
    end
  end

  assign debug_from_trigger_o = debug_from_mcontrol;  // from trigger module to id stage
  assign break_from_trigger_o = break_from_trigger;  // from trigger module to commit stage

  // write logic pmp
  always_comb begin : write
    for (int i = 0; i < 64; i++) begin
      if (i < CVA6Cfg.NrPMPEntries) begin
        if (!CVA6Cfg.PMPEntryReadOnly[i]) begin
          // PMP locked logic is handled in the CSR write process above
          pmpcfg_next[i] = pmpcfg_d[i];
          // We only support >=8-byte granularity, NA4 is not supported
          if ((!CVA6Cfg.PMPNapotEn && pmpcfg_d[i].addr_mode == riscv::NAPOT) ||pmpcfg_d[i].addr_mode == riscv::NA4) begin
            pmpcfg_next[i].addr_mode = pmpcfg_q[i].addr_mode;
          end
          // Follow collective WARL spec for RWX fields
          if (pmpcfg_d[i].access_type.r == '0 && pmpcfg_d[i].access_type.w == '1) begin
            pmpcfg_next[i].access_type = pmpcfg_q[i].access_type;
          end
        end else begin
          pmpcfg_next[i] = pmpcfg_q[i];
        end
        if (!CVA6Cfg.PMPEntryReadOnly[i]) begin
          pmpaddr_next[i] = pmpaddr_d[i];
        end else begin
          pmpaddr_next[i] = pmpaddr_q[i];
        end
      end else begin
        pmpcfg_next[i]  = '0;
        pmpaddr_next[i] = '0;
      end
    end
  end

  //-------------
  // Trigger Module
  //-------------
  generate
    if (CVA6Cfg.SDTRIG) begin : tm_gen
      trigger_module #(
          .CVA6Cfg           (CVA6Cfg),
          .exception_t       (exception_t),
          .scoreboard_entry_t(scoreboard_entry_t),
          .N_Triggers        (N_Triggers)
      ) trigger_module_i (
          .clk_i,
          .rst_ni,
          .commit_instr_i       (commit_instr_i),
          .commit_ack_i         (commit_ack_i),
          .ex_i                 (ex_i),
          .vaddr_from_lsu_i     (vaddr_from_lsu_i),
          .orig_instr_i         (orig_instr_i),
          .store_result_i       (store_result_i),
          .priv_lvl_i           (priv_lvl_o),
          .debug_mode_i         (debug_mode_q),
          .mret_i               (mret),
          .sret_i               (sret),
          .scontext_i           (scontext_q),
          .tselect_i            (tselect_to_tm),
          .tdata1_i             (tdata1_to_tm),
          .tdata2_i             (tdata2_to_tm),
          .tdata3_i             (tdata3_to_tm),
          .tselect_we           (tselect_we),
          .tdata1_we            (tdata1_we),
          .tdata2_we            (tdata2_we),
          .tdata3_we            (tdata3_we),
          .tselect_o            (tselect_from_tm),
          .tdata1_o             (tdata1_from_tm),
          .tdata2_o             (tdata2_from_tm),
          .tdata3_o             (tdata3_from_tm),
          .flush_o              (flush_from_tm),
          // debug/break request from TM
          .debug_from_trigger_o (debug_from_trigger),
          .break_from_trigger_o (break_from_trigger),
          .debug_from_mcontrol_o(debug_from_mcontrol)
      );
    end else begin
      assign tdata1_from_tm = '0;
      assign tdata2_from_tm = '0;
      assign tdata3_from_tm = '0;
      assign tselect_from_tm = '0;
      assign flush_from_tm = 0;
      assign debug_from_trigger = 0;
      assign break_from_trigger = 0;
      assign debug_from_mcontrol = 0;
    end
  endgenerate

  //-------------
  // Assertions
  //-------------
  //pragma translate_off
  // check that eret and ex are never valid together
  assert property (@(posedge clk_i) disable iff (!rst_ni !== '0) !(eret_o && ex_i.valid))
  else begin
    $error("eret and exception should never be valid at the same time");
    $stop();
  end
  //pragma translate_on


  //RVFI CSR

  //-------------
  // RVFI
  //-------------
  assign rvfi_csr_o.fcsr_q = '0;
  assign rvfi_csr_o.jvt_q = '0;
  assign rvfi_csr_o.dcsr_q = CVA6Cfg.DebugEn ? dcsr_q : '0;
  assign rvfi_csr_o.dpc_q = CVA6Cfg.DebugEn ? dpc_q : '0;
  assign rvfi_csr_o.dscratch0_q = CVA6Cfg.DebugEn ? dscratch0_q : '0;
  assign rvfi_csr_o.dscratch1_q = CVA6Cfg.DebugEn ? dscratch1_q : '0;
  assign rvfi_csr_o.mie_q = mie_q;
  assign rvfi_csr_o.mip_q = mip_q;
  assign rvfi_csr_o.stvec_q = CVA6Cfg.RVS ? stvec_q : '0;
  assign rvfi_csr_o.scounteren_q = CVA6Cfg.RVS ? scounteren_q : '0;
  assign rvfi_csr_o.sscratch_q = CVA6Cfg.RVS ? sscratch_q : '0;
  assign rvfi_csr_o.sepc_q = CVA6Cfg.RVS ? sepc_q : '0;
  assign rvfi_csr_o.scause_q = CVA6Cfg.RVS ? scause_q : '0;
  assign rvfi_csr_o.stval_q = CVA6Cfg.RVS ? stval_q : '0;
  assign rvfi_csr_o.satp_q = CVA6Cfg.RVS ? satp_q : '0;
  assign rvfi_csr_o.mstatus_extended = mstatus_extended;
  assign rvfi_csr_o.medeleg_q = CVA6Cfg.RVS ? medeleg_q : '0;
  assign rvfi_csr_o.mideleg_q = CVA6Cfg.RVS ? mideleg_q : '0;
  assign rvfi_csr_o.mtvec_q = mtvec_q;
  assign rvfi_csr_o.mcounteren_q = mcounteren_q;
  assign rvfi_csr_o.mscratch_q = mscratch_q;
  assign pvm_img_w_o = csr_wdata;  // {addr, data}; latched into img_mem by pvm_front on pvm_img_we_o
  assign pvm_cfg0_o = pvm_cfg0_q;
  assign pvm_cfg1_o = pvm_cfg1_q;
  assign pvm_cfg2_o = pvm_cfg2_q;
  assign pvm_ram_o = pvm_ram_q;
  assign rvfi_csr_o.mepc_q = mepc_q;
  assign rvfi_csr_o.mcause_q = mcause_q;
  assign rvfi_csr_o.mtval_q = CVA6Cfg.TvalEn ? mtval_q : '0;
  assign rvfi_csr_o.fiom_q = fiom_q;
  assign rvfi_csr_o.mcountinhibit_q = mcountinhibit_q;
  assign rvfi_csr_o.cycle_q = cycle_q;
  assign rvfi_csr_o.instret_q = instret_q;
  assign rvfi_csr_o.dcache_q = dcache_q;
  assign rvfi_csr_o.icache_q = icache_q;
  assign rvfi_csr_o.acc_cons_q = '0;
  assign rvfi_csr_o.pmpcfg_q = pmpcfg_q;
  assign rvfi_csr_o.pmpaddr_q = pmpaddr_q;


endmodule
