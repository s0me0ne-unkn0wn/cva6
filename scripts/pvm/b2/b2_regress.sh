#!/bin/bash
# b2_regress.sh [bit] -- the userspace-as-PVM silicon regression: build every B2 stage's kernel
# image (K loop) and run it on Genesys2, asserting the expected UART line. ~7 min per stage.
# Usage after any RTL / loader / kernel / polkatool change. Log: ~/pvm/artifacts/b2/b2_regress.log
set -u
cd "$(dirname "$0")"
BIT=${1:-}
OUT=/home/claude/pvm/artifacts/b2; LOG=$OUT/b2_regress.log; : > $LOG
ts(){ date +%T; }
pass=0; fail=0
stage() {   # stage <tag> <expected-regex> <init program> [more programs...]
  local tag=$1 expect=$2; shift 2
  echo "[$(ts)] === $tag: build ($*) ===" | tee -a $LOG
  if ! ./build_b23.sh "$@" >> $LOG 2>&1; then echo "[$(ts)] $tag BUILD FAILED" | tee -a $LOG; fail=$((fail+1)); return; fi
  echo "[$(ts)] === $tag: run ===" | tee -a $LOG
  bash ../fpga_run.sh $OUT/vmlinux_b2.polkavm "reg_$tag" $BIT >/dev/null 2>&1
  if grep -aqE "$expect" /home/claude/pvm/artifacts/fpga/reg_$tag.uart.log && grep -aq "exitcode=0x00000000" /home/claude/pvm/artifacts/fpga/reg_$tag.uart.log; then
    echo "[$(ts)] $tag PASS: $(grep -aoE "$expect" /home/claude/pvm/artifacts/fpga/reg_$tag.uart.log | head -1)" | tee -a $LOG; pass=$((pass+1))
  else
    echo "[$(ts)] $tag FAIL (see ~/pvm/artifacts/fpga/reg_$tag.uart.log)" | tee -a $LOG; tail -c 400 /home/claude/pvm/artifacts/fpga/reg_$tag.uart.log | tr -d '\r' | tail -4 | tee -a $LOG; fail=$((fail+1))
  fi
}
stage b21 'B2!'                             user_hello
stage b22 'B2\.2 ro\+rw: 37'                user_data
stage b23 'B2\.3 calls: fib\(10\)=55 cnt=8' user_calls
stage b24 'B2\.3 calls: fib\(10\)=55 cnt=8' user_chain user_calls
echo "[$(ts)] === B2 REGRESSION: $pass pass, $fail fail ===" | tee -a $LOG
[ $fail = 0 ]
