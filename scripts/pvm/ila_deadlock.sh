#!/bin/bash
# ila_deadlock.sh <kernel_dram.bin> [ila_bit]
# Capture the B2 host-resume deadlock with the ILA built by `PVM_ILA=1 make fpga`:
#   1. program the ILA bitstream                    (vivado, prog_bit.tcl)
#   2. load the image with the hart HALTED, no resume   (openocd)
#   3. arm the ILA: trigger = first host-boundary exit (vivado ila_capture.tcl armexit) -- the
#      armed state lives in the fabric, so hw_server can disconnect and free the JTAG cable
#   4. resume the hart                              (openocd)      -> boot ~23 s -> 'G' -> wedge
#   5. dump the captured window                     (vivado ila_capture.tcl dump) -> CSV/TXT
# Artifacts: ~/pvm/artifacts/ila/<ts>/  (uart, oocd, vivado logs, pvm_ila_capture.{csv,txt})
set -u
BIN=${1:?kernel_dram.bin}; BIT=${2:-/home/claude/pvm/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit}; TRIGPC=${3:-0C0738}; PHASE=${4:-armexit}
S=/home/claude/pvm/cva6/scripts/pvm; ROOT=/home/claude/pvm/cva6
OUT=/home/claude/pvm/artifacts/ila/$(date +%Y%m%d_%H%M%S); mkdir -p $OUT
exec > $OUT/run.log 2>&1
ts(){ date +%T; }
export LANG=C LC_ALL=C
source /home/claude/Vivado/2025.2/Vivado/settings64.sh
pkill -9 -x openocd 2>/dev/null; sleep 1
echo "[$(ts)] bin=$BIN bit=$BIT ltx=${BIT%.bit}.ltx"
echo "[$(ts)] 1. program"
vivado -nojournal -nolog -mode batch -source $S/prog_bit.tcl -tclargs "$BIT" > $OUT/prog.vivado.log 2>&1
echo "[$(ts)]    rc=$? PROGRAM_DONE_OK=$(grep -c PROGRAM_DONE_OK $OUT/prog.vivado.log)"; pkill -x hw_server 2>/dev/null; sleep 2   # hw_server would hold the FTDI (openocd: LIBUSB_ERROR_BUSY)
stty -F /dev/ttyUSB0 115200 raw -echo 2>/dev/null
timeout 420 stdbuf -o0 cat /dev/ttyUSB0 > $OUT/uart.log 2>&1 &
CAP=$!
echo "[$(ts)] 2. load (halted)"
openocd -f $S/ariane_jtag.cfg -c init -c halt -c "load_image $BIN 0x80000000 bin" -c "reg pc 0x80000000" -c shutdown > $OUT/oocd_load.log 2>&1
echo "[$(ts)]    rc=$? $(grep -a 'downloaded' $OUT/oocd_load.log | tail -1)"
echo "[$(ts)] 3. arm (exit trigger)"
(cd $ROOT && vivado -nojournal -nolog -mode batch -source corev_apu/fpga/scripts/ila_capture.tcl -tclargs $PHASE $TRIGPC) > $OUT/arm.vivado.log 2>&1
echo "[$(ts)]    rc=$? $(grep -av '^#' $OUT/arm.vivado.log | grep -a '\[ila\] armed\|\[ila\] ARMED\|ERROR' | head -3 | tr '\n' ' ')"
pkill -x hw_server 2>/dev/null; sleep 1
grep -aq '\[ila\] ARMED' $OUT/arm.vivado.log || { echo "[$(ts)] ARM FAILED -- aborting before resume"; kill $CAP 2>/dev/null; exit 3; }
echo "[$(ts)] 4. resume"
openocd -f $S/ariane_jtag.cfg -c init -c resume -c shutdown > $OUT/oocd_resume.log 2>&1
echo "[$(ts)]    rc=$?"
sleep 60
echo "[$(ts)]    UART after 60 s: $(stat -c%s $OUT/uart.log) bytes; tail: $(tail -c 120 $OUT/uart.log | tr -d '\r\n' | tail -c 80)"
echo "[$(ts)] 5. dump"
(cd $ROOT && vivado -nojournal -nolog -mode batch -source corev_apu/fpga/scripts/ila_capture.tcl -tclargs dump) > $OUT/dump.vivado.log 2>&1
echo "[$(ts)]    rc=$? $(grep -av '^#' $OUT/dump.vivado.log | grep -a '\[ila\]\|ERROR' | tail -4 | tr '\n' ' ')"
pkill -x hw_server 2>/dev/null
cp /home/claude/pvm/artifacts/ila/pvm_ila_capture.csv /home/claude/pvm/artifacts/ila/pvm_ila_capture.txt $OUT/ 2>/dev/null
kill $CAP 2>/dev/null
echo "[$(ts)] DONE -> $OUT"
