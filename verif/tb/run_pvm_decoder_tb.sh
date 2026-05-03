#!/usr/bin/env bash
# Phase 4.5 sub-phase 0 — runner for pvm_decoder_tb
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVA6_ROOT="$(realpath "$SCRIPT_DIR/../..")"
INC_DIR="$CVA6_ROOT/core/include"
BUILD_DIR="$SCRIPT_DIR/build/decoder"

mkdir -p "$BUILD_DIR"

VERILATOR_FLAGS="--binary --timing -sv +incdir+$INC_DIR -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-TIMESCALEMOD"

verilator $VERILATOR_FLAGS \
  --Mdir "$BUILD_DIR" \
  --top-module pvm_decoder_tb \
  "$INC_DIR/polkavm_pkg.sv" \
  "$CVA6_ROOT/core/pvm_decoder.sv" \
  "$SCRIPT_DIR/pvm_decoder_tb.sv"

LOG="$BUILD_DIR/run.log"
"$BUILD_DIR/Vpvm_decoder_tb" 2>&1 | tee "$LOG"

if grep -qE "PASS: 30/30|ALL PASS|RESULT: ALL PASS" "$LOG"; then
  echo "[run_pvm_decoder_tb] PASS"
  exit 0
else
  echo "[run_pvm_decoder_tb] FAIL — see $LOG" >&2
  exit 1
fi
