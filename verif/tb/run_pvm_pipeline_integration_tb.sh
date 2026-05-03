#!/usr/bin/env bash
# Phase 4.5 sub-phase 5 — full-pipeline Verilator integration test.
#
# Builds cva6 with pvm_pipeline_integration_tb.sv as top, runs the
# simulation, then checks four hard gates:
#   Gate 1: ≥50 instructions committed
#   Gate 2: uart_trace.log contains "Hello" (case-insensitive)
#   Gate 3: no %Error / Aborted in sim log
#   Gate 4: no DEADLOCK / HANG in sim log
#
# Copyright 2025 Parity Technologies Ltd.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CVA6_ROOT="$(realpath "$SCRIPT_DIR/../..")"
INC_DIR="$CVA6_ROOT/core/include"
BUILD_DIR="$SCRIPT_DIR/build/integration"
UART_LOG="$SCRIPT_DIR/uart_trace.log"

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# HPDCACHE path (bundled under core/cache_subsystem/hpdcache).
# ---------------------------------------------------------------------------
HPDCACHE_DIR="$CVA6_ROOT/core/cache_subsystem/hpdcache"
export HPDCACHE_DIR

# ---------------------------------------------------------------------------
# Assemble RTL file list from core/Flist.cva6.
# Lines starting with + (incdir directives), # (comments), or -F (sub-flists)
# are skipped; $-variable references are expanded; .sv/.svh files are kept.
#
# The HPDCACHE -F sub-flist is handled separately below.
# ---------------------------------------------------------------------------
FILES=()

while IFS= read -r line; do
  # Skip blank lines
  [[ -z "$line" ]] && continue
  # Skip incdir directives
  [[ "$line" == +* ]] && continue
  # Skip comments
  [[ "$line" == //* ]] && continue
  [[ "$line" == "#"* ]] && continue

  # Inline -F sub-flist at this position (preserves ordering relative to
  # the direct-path entries in Flist.cva6 that follow the -F line).
  if [[ "$line" == -F* ]]; then
    subflist=$(echo "${line#-F }" \
      | sed "s|\\\${HPDCACHE_DIR}|$HPDCACHE_DIR|g" \
      | sed "s|\\\${CVA6_REPO_DIR}|$CVA6_ROOT|g")
    subflist="${subflist## }"   # strip leading space
    if [[ -f "$subflist" ]]; then
      while IFS= read -r subline; do
        [[ -z "$subline" ]] && continue
        [[ "$subline" == +* ]] && continue
        [[ "$subline" == //* ]] && continue
        [[ "$subline" == "#"* ]] && continue
        [[ "$subline" == -F* ]] && continue
        subexpanded=$(echo "$subline" \
          | sed "s|\\\${HPDCACHE_DIR}|$HPDCACHE_DIR|g" \
          | sed "s|\\\${CVA6_REPO_DIR}|$CVA6_ROOT|g")
        if [[ "$subexpanded" == *.sv ]] || [[ "$subexpanded" == *.svh ]]; then
          FILES+=("$subexpanded")
        fi
      done < "$subflist"
    fi
    continue
  fi

  # Expand shell variables in path (use sed to avoid bash pattern issues with ${...})
  expanded=$(echo "$line" \
    | sed "s|\\\${CVA6_REPO_DIR}|$CVA6_ROOT|g" \
    | sed "s|\\\${HPDCACHE_DIR}|$HPDCACHE_DIR|g" \
    | sed "s|\\\${TARGET_CFG}|cv64a6_emac_polkavm|g")

  # Only keep .sv / .svh files
  if [[ "$expanded" == *.sv ]] || [[ "$expanded" == *.svh ]]; then
    FILES+=("$expanded")
  fi
done < "$CVA6_ROOT/core/Flist.cva6"

# ---------------------------------------------------------------------------
# Additional include directories found in Flist.cva6 +incdir lines.
# ---------------------------------------------------------------------------
INC_DIRS=(
  "+incdir+$SCRIPT_DIR"
  "+incdir+$INC_DIR"
  "+incdir+$CVA6_ROOT/vendor/pulp-platform/common_cells/include/"
  "+incdir+$CVA6_ROOT/vendor/pulp-platform/common_cells/src/"
  "+incdir+$CVA6_ROOT/vendor/pulp-platform/axi/include/"
  "+incdir+$CVA6_ROOT/common/local/util/"
  "+incdir+$HPDCACHE_DIR/rtl/include/"
)

# ---------------------------------------------------------------------------
# Verilator build.
# ---------------------------------------------------------------------------
VERILATOR_FLAGS=(
  --binary --timing -sv
  --x-initial 0
  +define+PVM_SIM_SP_INIT
  "${INC_DIRS[@]}"
  --unroll-count 256
  -Wno-WIDTHEXPAND
  -Wno-WIDTHTRUNC
  -Wno-CASEINCOMPLETE
  -Wno-UNOPTFLAT
  -Wno-TIMESCALEMOD
  -Wno-PINMISSING
  -Wno-PINCONNECTEMPTY
  -Wno-ASSIGNDLY
  -Wno-DECLFILENAME
  -Wno-UNUSED
  -Wno-BLKANDNBLK
  -Wno-style
  -Wno-fatal
)

echo "[BUILD] Verilating cva6 + pvm_pipeline_integration_tb..."
verilator "${VERILATOR_FLAGS[@]}" \
  --Mdir "$BUILD_DIR" \
  --top-module pvm_pipeline_integration_tb \
  "${FILES[@]}" \
  "$SCRIPT_DIR/pvm_pipeline_integration_tb.sv" \
  2>&1 | tee "$BUILD_DIR/verilate.log"

BUILD_EXIT=${PIPESTATUS[0]}
if [[ $BUILD_EXIT -ne 0 ]]; then
  echo "[BUILD] FAIL — first 10 errors:"
  grep -E "%Error" "$BUILD_DIR/verilate.log" | head -10 || true
  exit 1
fi
echo "[BUILD] PASS"

# ---------------------------------------------------------------------------
# Run simulation (cd to script dir so uart_trace.log lands there).
# ---------------------------------------------------------------------------
LOG="$BUILD_DIR/run.log"
cd "$SCRIPT_DIR"
echo "[SIM] Running..."
"$BUILD_DIR/Vpvm_pipeline_integration_tb" 2>&1 | tee "$LOG"
SIM_EXIT=${PIPESTATUS[0]}

# ---------------------------------------------------------------------------
# Gate checks.
# ---------------------------------------------------------------------------
COMMITS=$(grep -oE "instructions committed:[[:space:]]*[0-9]+" "$LOG" \
  | grep -oE '[0-9]+' | tail -1 || echo 0)
HELLO=$(grep -ci "hello" "$UART_LOG" 2>/dev/null | head -1 || echo 0)
ERRS=$(grep -cE "%Error|Aborted" "$LOG" || echo 0)
DEAD=$(grep -cE "DEADLOCK|HANG" "$LOG" || echo 0)

echo ""
echo "=== GATE SUMMARY ==="
echo "Commits:        $COMMITS  (gate: >=50)"
echo "Hello matches:  $HELLO    (gate: >=1)"
echo "Errors:         $ERRS     (gate: 0)"
echo "Deadlock:       $DEAD     (gate: 0)"
if [[ -f "$UART_LOG" ]]; then
  echo ""
  echo "=== uart_trace.log (first 200 chars) ==="
  head -c 200 "$UART_LOG" || true
  echo ""
fi

if [[ $COMMITS -ge 50 ]] && [[ $HELLO -ge 1 ]] && \
   [[ $ERRS -eq 0 ]] && [[ $DEAD -eq 0 ]]; then
  echo "[INTEGRATION] PASS"
  exit 0
else
  echo "[INTEGRATION] FAIL"
  exit 1
fi
