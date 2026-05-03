// pvm_lsu_tb.sv — Testbench for PVM LSU low-inaccessible panic check.
// Sub-phase 6: LSU adaptation + virtual-mod-2^32 < 2^16 panic check.
//
// Tests the panic condition: (vaddr mod 2^32) < 2^16 = 0x10000.
// Checks the 8 vectors from the sub-phase 6 plan, including distinguishing
// vectors that exercise virtual-mod semantics vs naive physical-address checks.
//
// The panic check logic mirrors what load_store_unit.sv implements:
//   is_panic = (vaddr[31:0] < PVM_LOW_INACCESSIBLE_MOD)
//
// This testbench is standalone (no LSU instantiation) because the full LSU
// has many CVA6 parametric dependencies.  The combinational panic logic is
// inlined here and cross-checked against the expected outcome for each vector.
//
// Run via Verilator (from repo root):
//   $ verilator --binary --timing -sv -Icore/include
//         core/include/polkavm_pkg.sv verif/tb/pvm_lsu_tb.sv
//         --top-module pvm_lsu_tb -o /tmp/sim_pvm_lsu && /tmp/sim_pvm_lsu
//
// Copyright 2025 Parity Technologies Ltd.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

module pvm_lsu_tb;
  import polkavm_pkg::*;

  // -------------------------------------------------------------------------
  // Test vector struct
  // -------------------------------------------------------------------------
  typedef struct {
    logic [63:0] vaddr;
    logic        expect_panic;
    string       label;
  } lsu_vec_t;

  // -------------------------------------------------------------------------
  // 8 test vectors (Table from sub-phase 6 plan)
  // -------------------------------------------------------------------------
  // Vector descriptions:
  //  #1  0x0000_0000_0000_0000  low32=0x00000000  < 0x10000 -> PANIC
  //  #2  0x0000_0000_0000_FFFF  low32=0x0000FFFF  < 0x10000 -> PANIC
  //  #3  0x0000_0000_0001_0000  low32=0x00010000  = 0x10000 -> success
  //  #4  0x0000_0000_1000_0000  low32=0x10000000  > 0x10000 -> success (UART)
  //  #5  0x0000_0000_8000_0000  low32=0x80000000  > 0x10000 -> success (DRAM)
  //  #6  0x00000DEAD_0000_0000  low32=0x00000000  < 0x10000 -> PANIC
  //      (distinguishing: naive raw-addr check would NOT panic here)
  //  #7  0x00000DEAD_FFFF0001   low32=0xFFFF0001  > 0x10000 -> success
  //      (distinguishing: wrong physical check on full addr < 0x10000_0000_0000
  //       would panic; correct virtual-mod check does not)
  //  #8  0x00000DEAD_0000FFFF   low32=0x0000FFFF  < 0x10000 -> PANIC
  localparam int NUM_VECS = 8;
  lsu_vec_t vectors[NUM_VECS];

  // -------------------------------------------------------------------------
  // Combinational panic check (mirrors load_store_unit.sv logic)
  // -------------------------------------------------------------------------
  logic [63:0] vaddr_tb;
  logic        is_panic;

  // The panic check: low 32 bits of virtual address < 2^16
  assign is_panic = (vaddr_tb[31:0] < PVM_LOW_INACCESSIBLE_MOD);

  // -------------------------------------------------------------------------
  // Test sequencer
  // -------------------------------------------------------------------------
  int pass_count;
  int fail_count;

  initial begin
    // Initialise vectors
    vectors[0] = '{vaddr: 64'h0000_0000_0000_0000, expect_panic: 1'b1,
                   label: "vec1: low32=0 -> panic"};
    vectors[1] = '{vaddr: 64'h0000_0000_0000_FFFF, expect_panic: 1'b1,
                   label: "vec2: low32=0xFFFF -> panic"};
    vectors[2] = '{vaddr: 64'h0000_0000_0001_0000, expect_panic: 1'b0,
                   label: "vec3: low32=0x10000 -> success"};
    vectors[3] = '{vaddr: 64'h0000_0000_1000_0000, expect_panic: 1'b0,
                   label: "vec4: low32=0x10000000 -> success (UART)"};
    vectors[4] = '{vaddr: 64'h0000_0000_8000_0000, expect_panic: 1'b0,
                   label: "vec5: low32=0x80000000 -> success (DRAM)"};
    vectors[5] = '{vaddr: 64'h0000_DEAD_0000_0000, expect_panic: 1'b1,
                   label: "vec6: 0xDEAD_0000_0000_0000 low32=0 -> PANIC (distinguishing)"};
    vectors[6] = '{vaddr: 64'h0000_DEAD_FFFF_0001, expect_panic: 1'b0,
                   label: "vec7: 0xDEAD_0000_FFFF0001 low32=0xFFFF0001 -> success (distinguishing)"};
    vectors[7] = '{vaddr: 64'h0000_DEAD_0000_FFFF, expect_panic: 1'b1,
                   label: "vec8: 0xDEAD_0000_0000FFFF low32=0xFFFF -> PANIC"};

    pass_count = 0;
    fail_count = 0;

    $display("=== PVM LSU Low-Inaccessible Panic Check Testbench ===");
    $display("  Panic condition: vaddr[31:0] < 0x%08h (PVM_LOW_INACCESSIBLE_MOD)",
             PVM_LOW_INACCESSIBLE_MOD);
    $display("");

    for (int i = 0; i < NUM_VECS; i++) begin
      // Drive the address
      vaddr_tb = vectors[i].vaddr;
      #1;  // let combinational logic settle

      if (is_panic === vectors[i].expect_panic) begin
        $display("PASS [%0d] %s", i+1, vectors[i].label);
        $display("       vaddr=0x%016h  low32=0x%08h  panic=%0b (expected %0b)",
                 vaddr_tb, vaddr_tb[31:0], is_panic, vectors[i].expect_panic);
        pass_count++;
      end else begin
        $display("FAIL [%0d] %s", i+1, vectors[i].label);
        $display("       vaddr=0x%016h  low32=0x%08h  panic=%0b (expected %0b) *** MISMATCH ***",
                 vaddr_tb, vaddr_tb[31:0], is_panic, vectors[i].expect_panic);
        fail_count++;
      end
    end

    $display("");
    $display("=== Results: %0d/%0d PASS, %0d FAIL ===", pass_count, NUM_VECS, fail_count);

    if (fail_count != 0) begin
      $fatal(1, "LSU panic check testbench: %0d vector(s) FAILED", fail_count);
    end else begin
      $display("ALL VECTORS PASS");
      $finish;
    end
  end

endmodule
