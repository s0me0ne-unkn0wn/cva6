#!/usr/bin/env bash
# Phase 4.5 sub-phase 0 — runner for pvm_frontend_tb
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVA6_ROOT="$(realpath "$SCRIPT_DIR/../..")"
INC_DIR="$CVA6_ROOT/core/include"
BUILD_DIR="$SCRIPT_DIR/build/frontend"

mkdir -p "$BUILD_DIR"

VERILATOR_FLAGS="--binary --timing -sv +incdir+$INC_DIR -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-TIMESCALEMOD"

verilator $VERILATOR_FLAGS \
  --Mdir "$BUILD_DIR" \
  --top-module pvm_frontend_tb \
  "$INC_DIR/polkavm_pkg.sv" \
  "$CVA6_ROOT/core/frontend/pvm_frontend.sv" \
  "$SCRIPT_DIR/pvm_frontend_tb.sv"

LOG="$BUILD_DIR/run.log"
"$BUILD_DIR/Vpvm_frontend_tb" 2>&1 | tee "$LOG"

if grep -qE "ALL TESTS PASSED|PASS: 17" "$LOG"; then
  echo "[run_pvm_frontend_tb] PASS"
  exit 0
else
  echo "[run_pvm_frontend_tb] FAIL — see $LOG" >&2
  exit 1
fi
