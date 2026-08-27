#!/bin/bash
# Boot a polkatool-linked NOMMU Linux (+ initramfs) as a PVM guest on Genesys2.
# Usage: fpga_run.sh <vmlinux.polkavm> <tag> [bitstream.bit] [capture_secs]
#   builds kernel_dram_<tag>.bin (launcher @0x80000000 + blobs), programs the bitstream
#   (default = the current work-fpga one), JTAG-loads, resumes, captures ttyUSB0.
# Artifacts -> ~/pvm/artifacts/fpga/<tag>.*  (never /tmp).
set -u
KPOLKAVM=${1:?vmlinux.polkavm}; TAG=${2:?tag}
BIT=${3:-/home/claude/pvm/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit}
CAP=${4:-300}   # NB: the capture window starts BEFORE the ~210s JTAG download (13.6MB @64KiB/s) -> real UART capture = CAP-210s
S=/home/claude/pvm/cva6/scripts/pvm
PVMRUN=/home/claude/pvm/cva6/verif/tests/custom/pvm_run
OUT=/home/claude/pvm/artifacts/fpga; mkdir -p $OUT
P=/home/claude/pvm/polkavm/target/release/polkatool
DTB=$S/kernel_unaligned.dtb
dtc -q -I dts -O dtb -o $DTB $S/kernel_unaligned.dts 2>/dev/null   # *.dtb is gitignored: always rebuild from the dts
exec > $OUT/$TAG.log 2>&1
ts(){ date +%T; }
export LANG=C LC_ALL=C
pkill -9 -x openocd 2>/dev/null; sleep 1
W=$OUT/work_$TAG; rm -rf $W; mkdir -p $W; cd $W
cp $PVMRUN/opensbi_to_dram.py $PVMRUN/loader_kernel.S $PVMRUN/link_kernel.ld .
echo "[$(ts)] image=$KPOLKAVM bit=$BIT dtb=$DTB"
"$P" emit-image -o kernel.bin "$KPOLKAVM" >/dev/null 2>&1 || { echo FATAL emit-image; exit 10; }
G=$(python3 opensbi_to_dram.py kernel.bin kernel)
CL=$(echo "$G"|grep '^CODE_LEN'|grep -oE '[0-9]+'); JZ=$(echo "$G"|grep '^JT_Z'|grep -oE '[0-9]+')
RWI=$(echo "$G"|grep '^RW_IMG'|grep -oE '[0-9]+'); RWT=$(echo "$G"|grep '^RW_TOTAL'|grep -oE '[0-9]+')
RWB=$(echo "$G"|grep '^RW_BASE'|grep -oE '[0-9]+'); RWV=$(echo "$G"|grep '^RW_VMA'|grep -oE '0x[0-9a-f]+')
JE=$(echo "$G"|grep '^JT_ENTRIES'|grep -oE '[0-9]+')
echo "[$(ts)] CODE_LEN=$CL JT_Z=$JZ JT_ENTRIES=$JE RW_IMG=$RWI RW_TOTAL=$RWT RW_BASE=$RWB RW_VMA=$RWV"
[ -z "$CL" ] && { echo FATAL split; exit 11; }
riscv64-linux-gnu-gcc -march=rv64emac_zbb_zicsr -mabi=lp64e -mcmodel=medany -fno-pic -fno-pie \
  -nostdlib -nostartfiles -static -no-pie -Wno-deprecated \
  -DCODE_LEN=$CL -DJT_Z=$JZ -DJT_ENTRIES=${JE:-0} -DRW_IMG=$RWI -DRW_TOTAL=$RWT -DRW_GUEST=$RWB -Wl,--defsym,RW_VMA=$RWV \
  -DDTB_PATH="\"$DTB\"" -T link_kernel.ld -o loader_kernel.elf loader_kernel.S 2>gcc.log \
  || { echo FATAL gcc; cat gcc.log; exit 12; }
riscv64-linux-gnu-objcopy -O binary loader_kernel.elf $OUT/kernel_dram_$TAG.bin
echo "[$(ts)] kernel_dram_$TAG.bin = $(stat -c%s $OUT/kernel_dram_$TAG.bin) bytes"
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
openocd -f $S/ariane_jtag.cfg -c init -c halt \
  -c "load_image $OUT/kernel_dram_$TAG.bin 0x80000000 bin" \
  -c "reg pc 0x80000000" -c "resume" -c shutdown > $OUT/$TAG.oocd.log 2>&1
echo "[$(ts)] OPENOCD rc=$?"; tail -3 $OUT/$TAG.oocd.log
wait $CAPPID
echo "[$(ts)] === UART ($(wc -c < $OUT/$TAG.uart.log) bytes) tail ==="
tail -25 $OUT/$TAG.uart.log
echo "[$(ts)] === DONE ==="
