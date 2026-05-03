# Makefile for sub-phase 9 PVM JAM v1 smoke tests
#
# Runs two standalone Verilator testbenches:
#   Program A: arith + load_imm + branch loop + store_u8 + trap  (no ecalli)
#   Program B: ecalli round-trip (write_csr sentinel → load regs → ecalli dispatch
#              → handler → mode_return → resume → trap)
#
# No polkatool required: programs are pre-encoded as hex literals in the SV.
# No full CVA6 pipeline: testbenches instantiate only pvm_frontend, pvm_decoder,
# pvm_alu (standalone modules with no ariane_pkg dependency).
#
# Usage:
#   make sim_a        — build and run Program A
#   make sim_b        — build and run Program B
#   make sim          — run both (default)
#   make clean        — remove build artifacts
#
# Requirements:
#   verilator >= 5.x in PATH

VERILATOR  ?= verilator
CVA6_ROOT  ?= $(realpath ../../../..)
CORE_DIR   := $(CVA6_ROOT)/core
INC_DIR    := $(CORE_DIR)/include
BUILD_DIR  := build

# Source files needed (no ariane_pkg, no full cva6 hierarchy)
PVM_PKG    := $(INC_DIR)/polkavm_pkg.sv
FRONTEND   := $(CORE_DIR)/frontend/pvm_frontend.sv
DECODER    := $(CORE_DIR)/pvm_decoder.sv
ALU        := $(CORE_DIR)/pvm_alu.sv

VERILATOR_FLAGS := \
  --binary --build \
  +incdir+$(INC_DIR) \
  -sv \
  --timing \
  -Wno-WIDTHEXPAND \
  -Wno-WIDTHTRUNC \
  -Wno-CASEINCOMPLETE \
  -Wno-UNOPTFLAT \
  -Wno-TIMESCALEMOD

.PHONY: all sim sim_a sim_b clean

all: sim

sim: sim_a sim_b

# ============================================================
# Program A  (Verilator names binary V<top-module>)
# ============================================================
$(BUILD_DIR)/Vtestbench_a/Vtestbench_a: testbench_a.sv $(PVM_PKG) $(FRONTEND) $(DECODER) $(ALU)
	@mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
	  --Mdir $(BUILD_DIR)/Vtestbench_a \
	  --top-module testbench_a \
	  $(PVM_PKG) $(FRONTEND) $(DECODER) $(ALU) \
	  testbench_a.sv

sim_a: $(BUILD_DIR)/Vtestbench_a/Vtestbench_a
	@echo "--- Running Program A smoke test ---"
	$(BUILD_DIR)/Vtestbench_a/Vtestbench_a

# ============================================================
# Program B
# ============================================================
$(BUILD_DIR)/Vtestbench_b/Vtestbench_b: testbench_b.sv $(PVM_PKG) $(FRONTEND) $(DECODER) $(ALU)
	@mkdir -p $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
	  --Mdir $(BUILD_DIR)/Vtestbench_b \
	  --top-module testbench_b \
	  $(PVM_PKG) $(FRONTEND) $(DECODER) $(ALU) \
	  testbench_b.sv

sim_b: $(BUILD_DIR)/Vtestbench_b/Vtestbench_b
	@echo "--- Running Program B smoke test ---"
	$(BUILD_DIR)/Vtestbench_b/Vtestbench_b

clean:
	rm -rf $(BUILD_DIR)
