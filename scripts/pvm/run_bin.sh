#!/bin/bash
# run_bin.sh <kernel_dram_*.bin> <tag> [bit] [capture_secs]
# Program the bitstream, JTAG-load a READY-MADE DRAM image (no rebuild), resume at 0x80000000,
# capture the UART. Used for A/B tests of an old image against a new bitstream (e.g. prove an RTL
# fix on the exact image that hung). Artifacts -> ~/pvm/artifacts/fpga/<tag>.*
set -u
BIN=$1; TAG=$2
BIT=${3:-/home/claude/pvm/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit}
CAP=${4:-300}   # NB: starts BEFORE the ~210s JTAG download -> real UART capture = CAP-210s
S=/home/claude/pvm/cva6/scripts/pvm
OUT=/home/claude/pvm/artifacts/fpga; mkdir -p $OUT
exec > $OUT/$TAG.log 2>&1
ts(){ date +%T; }
export LANG=C LC_ALL=C
pkill -9 -x openocd 2>/dev/null; sleep 1
echo "[$(ts)] bin=$BIN ($(stat -c%s "$BIN") bytes) bit=$BIT"
echo "[$(ts)] === program bitstream ==="
source /home/claude/Vivado/2025.2/Vivado/settings64.sh
vivado -nojournal -mode batch -source $S/prog_bit.tcl -tclargs "$BIT" > $OUT/$TAG.vivado.log 2>&1
echo "[$(ts)] REPROG rc=$? PROGRAM_DONE_OK=$(grep -c PROGRAM_DONE_OK $OUT/$TAG.vivado.log)"
sleep 2
echo "[$(ts)] === capture + JTAG load + resume ==="
stty -F /dev/ttyUSB0 115200 raw -echo 2>/dev/null
timeout $CAP stdbuf -o0 cat /dev/ttyUSB0 > $OUT/$TAG.uart.log 2>&1 &
CAPPID=$!
sleep 1
openocd -f $S/ariane_jtag.cfg -c "init; halt; load_image $BIN 0x80000000 bin; reg pc 0x80000000; resume; shutdown" > $OUT/$TAG.oocd.log 2>&1
echo "[$(ts)] OPENOCD rc=$?"; tail -3 $OUT/$TAG.oocd.log
wait $CAPPID
echo "[$(ts)] === UART ($(stat -c%s $OUT/$TAG.uart.log) bytes) tail ==="
tail -c 1500 $OUT/$TAG.uart.log | tr -d '\r'
echo; echo "[$(ts)] === DONE ==="
