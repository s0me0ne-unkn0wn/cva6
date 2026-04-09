/* Copyright 2018 ETH Zurich and University of Bologna.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the “License”); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File:   ariane_pkg.sv
 * Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
 * Date:   8.4.2017
 *
 * Description: Contains all the necessary defines for Ariane
 *              in one package.
 */

/// This package contains `functions` and global defines for CVA6.
/// *Note*: There are some parameters here as well which will eventually be
/// moved out to favour a fully parameterizable core.
package ariane_pkg;

  // TODO: Slowly move those parameters to the new system.
  localparam BITS_SATURATION_COUNTER = 2;

  // depth of store-buffers, this needs to be a power of two
  localparam logic [2:0] DEPTH_SPEC = 'd4;

  // if CVA6Cfg.DCacheType = cva6_config_pkg::WT
  // we can use a small commit queue since we have a write buffer in the dcache
  // we could in principle do without the commit queue in this case, but the timing degrades if we do that due
  // to longer paths into the commit stage
  // if CVA6Cfg.DCacheType = cva6_config_pkg::WB
  // allocate more space for the commit buffer to be on the safe side, this needs to be a power of two
  localparam logic [2:0] DEPTH_COMMIT = 'd4;

  localparam logic [31:0] OPENHWGROUP_MVENDORID = 32'h0602;
  localparam logic [31:0] ARIANE_MARCHID = 32'd3;
  localparam logic [31:0] ARIANE_MIMPID = 32'd0;

  // 16 registers (RV64E)
  localparam REG_ADDR_SIZE = 4;

  // Read ports for general purpose register files
  localparam NR_RGPR_PORTS = 2;

  // static debug hartinfo
  // debug causes
  localparam logic [2:0] CauseBreakpoint = 3'h1;
  localparam logic [2:0] CauseTrigger = 3'h2;
  localparam logic [2:0] CauseRequest = 3'h3;
  localparam logic [2:0] CauseSingleStep = 3'h4;
  // amount of data count registers implemented
  localparam logic [3:0] DataCount = 4'h2;

  // address where data0-15 is shadowed or if shadowed in a CSR
  // address of the first CSR used for shadowing the data
  localparam logic [11:0] DataAddr = 12'h380;  // we are aligned with Rocket here
  typedef struct packed {
    logic [31:24] zero1;
    logic [23:20] nscratch;
    logic [19:17] zero0;
    logic         dataaccess;
    logic [15:12] datasize;
    logic [11:0]  dataaddr;
  } hartinfo_t;

  localparam hartinfo_t DebugHartInfo = '{
      zero1: '0,
      nscratch: 2,  // Debug module needs at least two scratch regs
      zero0: '0,
      dataaccess: 1'b1,  // data registers are memory mapped in the debugger
      datasize: DataCount,
      dataaddr: DataAddr
  };

  // enables a commit log which matches spikes commit log format for easier trace comparison
  localparam bit ENABLE_SPIKE_COMMIT_LOG = 1'b1;

  // ------------- Dangerous -------------
  // if set to zero a flush will not invalidate the cache-lines, in a single core environment
  // where coherence is not necessary this can improve performance. This needs to be switched on
  // when more than one core is in a system
  localparam logic INVALIDATE_ON_FLUSH = 1'b1;

`ifdef SPIKE_TANDEM
  // Spike still places 0 in TVAL for ENV_CALL_* exceptions.
  // This may eventually go away when Spike starts to handle TVAL for *all* exceptions.
  localparam bit ZERO_TVAL = 1'b1;
`else
  localparam bit ZERO_TVAL = 1'b0;
`endif

  // read mask for SSTATUS over MSTATUS
  function automatic logic [63:0] smode_status_read_mask(config_pkg::cva6_cfg_t Cfg);
    return riscv::SSTATUS_UIE
    | riscv::SSTATUS_SIE
    | riscv::SSTATUS_SPIE
    | riscv::SSTATUS_UBE
    | riscv::SSTATUS_SPP
    | riscv::SSTATUS_FS
    | riscv::SSTATUS_XS
    | riscv::SSTATUS_SUM
    | riscv::SSTATUS_MXR
    | riscv::SSTATUS_UPIE
    | riscv::SSTATUS_SPIE
    | riscv::SSTATUS_UXL
    | riscv::sstatus_sd(Cfg.IS_XLEN64);
  endfunction

  localparam logic [63:0] SMODE_STATUS_WRITE_MASK = riscv::SSTATUS_SIE
                                                    | riscv::SSTATUS_SPIE
                                                    | riscv::SSTATUS_SPP
                                                    | riscv::SSTATUS_FS
                                                    | riscv::SSTATUS_SUM
                                                    | riscv::SSTATUS_MXR;

  // ---------------
  // AXI
  // ---------------

  typedef enum logic {
    SINGLE_REQ,
    CACHE_LINE_REQ
  } ad_req_t;

  // ---------------
  // Fetch Stage
  // ---------------

  // leave as is (fails with >8 entries and wider fetch width)
  localparam int unsigned FETCH_FIFO_DEPTH = 4;
  localparam int unsigned FETCH_ADDR_FIFO_DEPTH = 2;

  typedef enum logic [2:0] {
    NoCF,    // No control flow prediction
    Branch,  // Branch
    Jump,    // Jump to address from immediate
    JumpR,   // Jump to address from registers
    Return   // Return Address Prediction
  } cf_t;

  typedef struct packed {
    logic valid;
    logic taken;
  } bht_prediction_t;

  typedef struct packed {
    logic       valid;
    logic [1:0] saturation_counter;
  } bht_t;

  typedef enum logic [3:0] {
    NONE,       // 0
    LOAD,       // 1
    STORE,      // 2
    ALU,        // 3
    CTRL_FLOW,  // 4
    MULT,       // 5
    CSR,        // 6
    FPU,        // 7
    FPU_VEC,    // 8
    CVXIF,      // 9
    ACCEL,      // 10
    AES         // 11
  } fu_t;

  // Index of writeback ports
  localparam FLU_WB = 0;
  localparam STORE_WB = 1;
  localparam LOAD_WB = 2;
  localparam FPU_WB = 3;
  localparam ACC_WB = 4;
  localparam X_WB = 4;

  localparam EXC_OFF_RST = 8'h80;

  localparam SupervisorIrq = 1;
  localparam MachineIrq = 0;

  // ---------------
  // EX Stage
  // ---------------

  typedef enum logic [7:0] {  // basic ALU op
    ADD,
    SUB,
    ADDW,
    SUBW,
    // logic operations
    XORL,
    ORL,
    ANDL,
    // shifts
    SRA,
    SRL,
    SLL,
    SRLW,
    SLLW,
    SRAW,
    // comparisons
    LTS,
    LTU,
    GES,
    GEU,
    EQ,
    NE,
    // jumps
    JALR,
    BRANCH,
    // set lower than operations
    SLTS,
    SLTU,
    // CSR functions
    MRET,
    SRET,
    DRET,
    ECALL,
    WFI,
    FENCE,
    FENCE_I,
    SFENCE_VMA,
    HFENCE_VVMA,
    HFENCE_GVMA,
    CSR_WRITE,
    CSR_READ,
    CSR_SET,
    CSR_CLEAR,
    // LSU functions
    LD,
    SD,
    LW,
    LWU,
    SW,
    LH,
    LHU,
    SH,
    LB,
    SB,
    LBU,
    // Hypervisor Virtual-Machine Load and Store Instructions
    HLV_B,
    HLV_BU,
    HLV_H,
    HLV_HU,
    HLVX_HU,
    HLV_W,
    HLVX_WU,
    HSV_B,
    HSV_H,
    HSV_W,
    HLV_WU,
    HLV_D,
    HSV_D,
    // Atomic Memory Operations
    AMO_LRW,
    AMO_LRD,
    AMO_SCW,
    AMO_SCD,
    AMO_SWAPW,
    AMO_ADDW,
    AMO_ANDW,
    AMO_ORW,
    AMO_XORW,
    AMO_MAXW,
    AMO_MAXWU,
    AMO_MINW,
    AMO_MINWU,
    AMO_SWAPD,
    AMO_ADDD,
    AMO_ANDD,
    AMO_ORD,
    AMO_XORD,
    AMO_MAXD,
    AMO_MAXDU,
    AMO_MIND,
    AMO_MINDU,
    // cache block operations (CBO)
    CBO_CLEAN,
    CBO_FLUSH,
    CBO_INVAL,
    CBO_NONE,
    // Multiplications
    MUL,
    MULH,
    MULHU,
    MULHSU,
    MULW,
    // Divisions
    DIV,
    DIVU,
    DIVW,
    DIVUW,
    REM,
    REMU,
    REMW,
    REMUW,
    // Floating-Point Load and Store Instructions
    FLD,
    FLW,
    FLH,
    FLB,
    FSD,
    FSW,
    FSH,
    FSB,
    // Floating-Point Computational Instructions
    FADD,
    FSUB,
    FMUL,
    FDIV,
    FMIN_MAX,
    FSQRT,
    FMADD,
    FMSUB,
    FNMSUB,
    FNMADD,
    // Floating-Point Conversion and Move Instructions
    FCVT_F2I,
    FCVT_I2F,
    FCVT_F2F,
    FSGNJ,
    FMV_F2X,
    FMV_X2F,
    // Floating-Point Compare Instructions
    FCMP,
    // Floating-Point Classify Instruction
    FCLASS,
    // Vectorial Floating-Point Instructions that don't directly map onto the scalar ones
    VFMIN,
    VFMAX,
    VFSGNJ,
    VFSGNJN,
    VFSGNJX,
    VFEQ,
    VFNE,
    VFLT,
    VFGE,
    VFLE,
    VFGT,
    VFCPKAB_S,
    VFCPKCD_S,
    VFCPKAB_D,
    VFCPKCD_D,
    // Offload Instructions to be directed into cv_x_if
    OFFLOAD,
    // Or-Combine and REV8
    ORCB,
    REV8,
    // Bitwise Rotation
    ROL,
    ROLW,
    ROR,
    RORI,
    RORIW,
    RORW,
    // Sign and Zero Extend
    SEXTB,
    SEXTH,
    ZEXTH,
    // Count population
    CPOP,
    CPOPW,
    // Count Leading/Training Zeros
    CLZ,
    CLZW,
    CTZ,
    CTZW,
    // Carry less multiplication Op's
    CLMUL,
    CLMULH,
    CLMULR,
    // Single bit instructions Op's
    BCLR,
    BCLRI,
    BEXT,
    BEXTI,
    BINV,
    BINVI,
    BSET,
    BSETI,
    // Integer minimum/maximum
    MAX,
    MAXU,
    MIN,
    MINU,
    // Shift with Add Unsigned Word and Unsigned Word Op's (Bitmanip)
    SH1ADDUW,
    SH2ADDUW,
    SH3ADDUW,
    ADDUW,
    SLLIUW,
    // Shift with Add (Bitmanip)
    SH1ADD,
    SH2ADD,
    SH3ADD,
    // Bitmanip Logical with negate op (Bitmanip)
    ANDN,
    ORN,
    XNOR,
    // Accelerator operations
    ACCEL_OP,
    ACCEL_OP_FS1,
    ACCEL_OP_FD,
    ACCEL_OP_LOAD,
    ACCEL_OP_STORE,
    // Zicond instruction
    CZERO_EQZ,
    CZERO_NEZ,
    // Xtheadcondmov instructions
    XHEAD_MVEQZ,
    XHEAD_MVNEZ,
    // Pack instructions
    PACK,
    PACK_H,
    PACK_W,
    // Brev8 instruction
    BREV8,
    // Zip instructions
    UNZIP,
    ZIP,
    // Xperm instructions
    XPERM8,
    XPERM4,
    // AES Encryption instructions
    AES32ESI,
    AES32ESMI,
    AES64ES,
    AES64ESM,
    // AES Decryption instructions
    AES32DSI,
    AES32DSMI,
    AES64DS,
    AES64DSM,
    AES64IM,
    // AES Key-Schedule instructions
    AES64KS1I,
    AES64KS2,
    // Hashing instructions
    SHA256SIG0,
    SHA256SIG1,
    SHA256SUM0,
    SHA256SUM1,
    SHA512SIG0H,
    SHA512SIG0L,
    SHA512SIG1H,
    SHA512SIG1L,
    SHA512SUM0R,
    SHA512SUM1R,
    SHA512SIG0,
    SHA512SIG1,
    SHA512SUM0,
    SHA512SUM1
  } fu_op;

  typedef struct packed {
    logic rs1_from_rd;
    logic rs2_from_rd;
  } alu_bypass_t;

  function automatic logic op_is_branch(input fu_op op);
    unique case (op) inside
      EQ, NE, LTS, GES, LTU, GEU: return 1'b1;
      default:                    return 1'b0;  // all other ops
    endcase
  endfunction

  // -------------------------------
  // Extract Src/Dst FP Reg from Op
  // -------------------------------
  // function used in instr_trace svh
  // is_rs1_fpr function is kept to allow cva6 compilation with instr_trace feature
  function automatic logic is_rs1_fpr(input fu_op op);
    return 1'b0;
  endfunction

  // function used in instr_trace svh
  // is_rs2_fpr function is kept to allow cva6 compilation with instr_trace feature
  function automatic logic is_rs2_fpr(input fu_op op);
    return 1'b0;
  endfunction

  // function used in instr_trace svh
  // is_imm_fpr function is kept to allow cva6 compilation with instr_trace feature
  function automatic logic is_imm_fpr(input fu_op op);
    return 1'b0;
  endfunction

  // function used in instr_trace svh
  // is_rd_fpr function is kept to allow cva6 compilation with instr_trace feature
  function automatic logic is_rd_fpr(input fu_op op);
    return 1'b0;
  endfunction

  function automatic logic fd_changes_rd_state(input fu_op op);
    return 1'b0;
  endfunction

  function automatic logic is_amo(fu_op op);
    case (op) inside
      [AMO_LRW : AMO_MINDU]: begin
        return 1'b1;
      end
      default: return 1'b0;
    endcase
  endfunction

  // -------------------
  // Performance counter
  // -------------------
  localparam int unsigned MHPMCounterNum = 6;

  // --------------------
  // Atomics
  // --------------------
  typedef enum logic [3:0] {
    AMO_NONE = 4'b0000,
    AMO_LR   = 4'b0001,
    AMO_SC   = 4'b0010,
    AMO_SWAP = 4'b0011,
    AMO_ADD  = 4'b0100,
    AMO_AND  = 4'b0101,
    AMO_OR   = 4'b0110,
    AMO_XOR  = 4'b0111,
    AMO_MAX  = 4'b1000,
    AMO_MAXU = 4'b1001,
    AMO_MIN  = 4'b1010,
    AMO_MINU = 4'b1011
  } amo_t;

  // Bits required for representation of physical address space as 4K pages
  // (e.g. 27*4K == 39bit address space).
  localparam PPN4K_WIDTH = 38;

  typedef struct packed {
    logic             valid;    // valid flag
    logic             is_4M;    //
    logic [20-1:0]    vpn;      //VPN (32bits) = 20bits + 12bits offset
    logic [9-1:0]     asid;     //ASID length = 9 for Sv32 mmu
    riscv::pte_sv32_t content;
  } tlb_update_sv32_t;

  typedef enum logic [1:0] {
    FE_NONE,
    FE_INSTR_ACCESS_FAULT,
    FE_INSTR_PAGE_FAULT
  } frontend_exception_t;

  // AMO request going to cache. this request is unconditionally valid as soon
  // as request goes high.
  // Furthermore, those signals are kept stable until the response indicates
  // completion by asserting ack.
  typedef struct packed {
    logic        req;        // this request is valid
    amo_t        amo_op;     // atomic memory operation to perform
    logic [1:0]  size;       // 2'b10 --> word operation, 2'b11 --> double word operation
    logic [63:0] operand_a;  // address
    logic [63:0] operand_b;  // data as layouted in the register
  } amo_req_t;

  // AMO response coming from cache.
  typedef struct packed {
    logic        ack;     // response is valid
    logic [63:0] result;  // sign-extended, result
  } amo_resp_t;

  localparam RVFI = cva6_config_pkg::CVA6ConfigRvfiTrace;

  // ----------------------
  // Arithmetic Functions
  // ----------------------
  function automatic logic [63:0] sext32to64(logic [31:0] operand);
    return {{32{operand[31]}}, operand[31:0]};
  endfunction

  // ----------------------
  // LSU Functions
  // ----------------------
  // generate byte enable mask
  function automatic logic [7:0] be_gen(logic [2:0] addr, logic [1:0] size);
    case (size)
      2'b11: begin
        return 8'b1111_1111;
      end
      2'b10: begin
        case (addr[2:0])
          3'b000:  return 8'b0000_1111;
          3'b001:  return 8'b0001_1110;
          3'b010:  return 8'b0011_1100;
          3'b011:  return 8'b0111_1000;
          3'b100:  return 8'b1111_0000;
          default: ;  // Do nothing
        endcase
      end
      2'b01: begin
        case (addr[2:0])
          3'b000:  return 8'b0000_0011;
          3'b001:  return 8'b0000_0110;
          3'b010:  return 8'b0000_1100;
          3'b011:  return 8'b0001_1000;
          3'b100:  return 8'b0011_0000;
          3'b101:  return 8'b0110_0000;
          3'b110:  return 8'b1100_0000;
          default: ;  // Do nothing
        endcase
      end
      2'b00: begin
        case (addr[2:0])
          3'b000: return 8'b0000_0001;
          3'b001: return 8'b0000_0010;
          3'b010: return 8'b0000_0100;
          3'b011: return 8'b0000_1000;
          3'b100: return 8'b0001_0000;
          3'b101: return 8'b0010_0000;
          3'b110: return 8'b0100_0000;
          3'b111: return 8'b1000_0000;
        endcase
      end
    endcase
    return 8'b0;
  endfunction

  function automatic logic [3:0] be_gen_32(logic [1:0] addr, logic [1:0] size);
    case (size)
      2'b10: begin
        return 4'b1111;
      end
      2'b01: begin
        case (addr[1:0])
          2'b00:   return 4'b0011;
          2'b01:   return 4'b0110;
          2'b10:   return 4'b1100;
          default: ;  // Do nothing
        endcase
      end
      2'b00: begin
        case (addr[1:0])
          2'b00: return 4'b0001;
          2'b01: return 4'b0010;
          2'b10: return 4'b0100;
          2'b11: return 4'b1000;
        endcase
      end
      default: return 4'b0;
    endcase
    return 4'b0;
  endfunction

  // ----------------------
  // Extract Bytes from Op
  // ----------------------
  function automatic logic [1:0] extract_transfer_size(fu_op op);
    case (op)
      LD, SD,
            AMO_LRD,   AMO_SCD,
            AMO_SWAPD, AMO_ADDD,
            AMO_ANDD,  AMO_ORD,
            AMO_XORD,  AMO_MAXD,
            AMO_MAXDU, AMO_MIND,
            AMO_MINDU: begin
        return 2'b11;
      end
      LW, LWU, SW,
            AMO_LRW,   AMO_SCW,
            AMO_SWAPW, AMO_ADDW,
            AMO_ANDW,  AMO_ORW,
            AMO_XORW,  AMO_MAXW,
            AMO_MAXWU, AMO_MINW,
            AMO_MINWU: begin
        return 2'b10;
      end
      LH, LHU, SH:    return 2'b01;
      LB, LBU, SB:    return 2'b00;
      default:         return 2'b11;
    endcase
  endfunction
  // ----------------------
  // Helper functions
  // ----------------------
  // Avoid negative array slices when defining parametrized sizes
  function automatic int unsigned avoid_neg(int n);
    return (n < 0) ? 0 : n;
  endfunction : avoid_neg

endpackage
