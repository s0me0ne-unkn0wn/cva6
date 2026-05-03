#!/usr/bin/env bash
# Phase 4.5 sub-phase 0 — runner for pvm_lsu_tb
# The LSU testbench is standalone (inlines the panic check logic) and only
# needs polkavm_pkg for PVM_LOW_INACCESSIBLE_MOD.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVA6_ROOT="$(realpath "$SCRIPT_DIR/../..")"
INC_DIR="$CVA6_ROOT/core/include"
BUILD_DIR="$SCRIPT_DIR/build/lsu"

mkdir -p "$BUILD_DIR"

VERILATOR_FLAGS="--binary --timing -sv +incdir+$INC_DIR -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-TIMESCALEMOD"

verilator $VERILATOR_FLAGS \
  --Mdir "$BUILD_DIR" \
  --top-module pvm_lsu_tb \
  "$INC_DIR/polkavm_pkg.sv" \
  "$SCRIPT_DIR/pvm_lsu_tb.sv"

LOG="$BUILD_DIR/run.log"
"$BUILD_DIR/Vpvm_lsu_tb" 2>&1 | tee "$LOG"

if grep -qE "ALL VECTORS PASS|8/8 PASS" "$LOG"; then
  echo "[run_pvm_lsu_tb] PASS"
  exit 0
else
  echo "[run_pvm_lsu_tb] FAIL — see $LOG" >&2
  exit 1
fi
