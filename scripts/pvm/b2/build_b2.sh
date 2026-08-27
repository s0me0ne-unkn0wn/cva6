#!/bin/bash
# B2.1: build the NOMMU PVM kernel with binfmt_pvm + an initramfs whose /init is the
# standalone user_hello.pvmi, then polkatool-link at O1. Artifacts -> ~/pvm/artifacts/b2
# (NOT /tmp -- tmp-cleaner wiped a week of artifacts once).
set -u
exec > /home/claude/pvm/artifacts/b2/build_b2.log 2>&1
ts(){ date +%T; }
export PATH=/home/claude/pvm/cva6-sdk/buildroot/output/host/bin:$PATH
export ARCH=riscv CROSS_COMPILE=riscv64-buildroot-linux-gnu- LANG=C LC_ALL=C
P=/home/claude/pvm/polkavm/target/release/polkatool
K=/home/claude/pvm/cva6-sdk/buildroot/output/build/linux-6.19.6
OUT=/home/claude/pvm/artifacts/b2
OC=riscv64-buildroot-linux-gnu-objcopy
cd "$K" || exit 9
echo "[$(ts)] pin the B2 initramfs (/init = user_hello.pvmi) + olddefconfig + make vmlinux"
SPEC=${1:-/home/claude/pvm/cva6/scripts/pvm/b2/initramfs_spec.txt}   # arg 1: initramfs spec (B2.1 default; B2.2 = initramfs_spec_b22.txt)
echo "[$(ts)] initramfs spec = $SPEC"
./scripts/config --set-str CONFIG_INITRAMFS_SOURCE "$SPEC"
make olddefconfig >/dev/null
make -j"$(nproc)" vmlinux 2>&1 | grep -E "error|Error|warning: .*binfmt_pvm|LD .*vmlinux|CC .*binfmt_pvm" | head -20
RC=${PIPESTATUS[0]}; echo "[$(ts)] BUILD_RC=$RC"; [ "$RC" = 0 ] || exit 10
ls -la usr/initramfs_data.cpio 2>/dev/null
$OC --strip-debug vmlinux $OUT/vmlinux_b2.nodbg
echo "[$(ts)] polkatool link --opt-level 1"
timeout 900 "$P" link -i jam_v1_privileged --opt-level 1 --strip $OUT/vmlinux_b2.nodbg -o $OUT/vmlinux_b2.polkavm 2>&1 | head -8
echo "LINK_RC=${PIPESTATUS[0]}"
ls -la $OUT/vmlinux_b2.polkavm 2>/dev/null && echo ">>> LINKED"
echo "[$(ts)] DONE"
