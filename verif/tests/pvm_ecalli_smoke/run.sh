#!/usr/bin/env bash
# Phase 4.5 sub-phase 0 — runner for pvm_ecalli_smoke
# Delegates to the existing Makefile (checker.sv / tb_ecalli_smoke top).
# Expected output: "ALL CHECKS PASSED" (20 internal checks via pass_check task).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG="$SCRIPT_DIR/build/run.log"
mkdir -p "$SCRIPT_DIR/build"

make -C "$SCRIPT_DIR" sim 2>&1 | tee "$LOG"

if grep -qE "ALL CHECKS PASSED" "$LOG"; then
  echo "[pvm_ecalli_smoke] PASS"
  exit 0
else
  echo "[pvm_ecalli_smoke] FAIL — see $LOG" >&2
  exit 1
fi
