# verif/tests/pvm_ecalli_smoke/Makefile
# Sub-phase 8: ecalli FSM smoke test — unit-level checker only.
#
# Runs checker.sv in Verilator (standalone FSM model, no full pipeline).
# The checker models the ecalli FSM from pvm_csr_regfile.sv directly and
# verifies all 4 states reachable + round-trip ≤ 25 cycles (ADR-5 budget).
#
# Usage:
#   make sim      — compile and run (default)
#   make clean    — remove build artifacts
#
# Requirements:
#   verilator >= 5.x  in PATH

VERILATOR ?= verilator
SIM_TOP   := tb_ecalli_smoke
SIM_SRC   := checker.sv
BUILD_DIR := build

.PHONY: all sim clean

all: sim

$(BUILD_DIR)/V$(SIM_TOP)/V$(SIM_TOP): $(SIM_SRC)
	@mkdir -p $(BUILD_DIR)
	$(VERILATOR) --binary --build \
	  --Mdir $(BUILD_DIR)/V$(SIM_TOP) \
	  --top-module $(SIM_TOP) \
	  +define+SIMULATION \
	  -sv \
	  $(SIM_SRC)

sim: $(BUILD_DIR)/V$(SIM_TOP)/V$(SIM_TOP)
	@echo "--- Running ecalli FSM smoke test ---"
	$(BUILD_DIR)/V$(SIM_TOP)/V$(SIM_TOP)

clean:
	rm -rf $(BUILD_DIR)
