#!/usr/bin/env bash
# Phase 4.5 sub-phase 0 — runner for pvm_csr_tb
# The CSR testbench imports ariane_pkg, config_pkg, build_config_pkg, and
# polkavm_pkg, so all package files must be included on the command line.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVA6_ROOT="$(realpath "$SCRIPT_DIR/../..")"
INC_DIR="$CVA6_ROOT/core/include"
BUILD_DIR="$SCRIPT_DIR/build/csr"

mkdir -p "$BUILD_DIR"

VERILATOR_FLAGS="--binary --timing -sv +incdir+$INC_DIR -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-PINMISSING"

verilator $VERILATOR_FLAGS \
  --Mdir "$BUILD_DIR" \
  --top-module pvm_csr_tb \
  "$INC_DIR/riscv_pkg.sv" \
  "$INC_DIR/config_pkg.sv" \
  "$INC_DIR/cv64a6_emac_polkavm_config_pkg.sv" \
  "$INC_DIR/build_config_pkg.sv" \
  "$INC_DIR/polkavm_pkg.sv" \
  "$INC_DIR/ariane_pkg.sv" \
  "$CVA6_ROOT/core/pvm_csr_regfile.sv" \
  "$SCRIPT_DIR/pvm_csr_tb.sv"

LOG="$BUILD_DIR/run.log"
"$BUILD_DIR/Vpvm_csr_tb" 2>&1 | tee "$LOG"

if grep -qE "RESULT: ALL PASS|6 PASS" "$LOG"; then
  echo "[run_pvm_csr_tb] PASS"
  exit 0
else
  echo "[run_pvm_csr_tb] FAIL — see $LOG" >&2
  exit 1
fi
