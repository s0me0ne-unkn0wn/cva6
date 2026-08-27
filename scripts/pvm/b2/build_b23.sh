#!/bin/bash
# build_b23.sh <user_program> [memory_base]
# B2.3 build loop: a user program that makes calls needs its jump-table tokens numbered from
# K = the kernel's jump-table entry count, and it is embedded in the kernel's initramfs. K
# depends only on the kernel CODE (not on the initramfs data), so:
#   1. build the kernel with a placeholder initramfs -> K
#   2. build <user_program> with --memory-base <mb> --jt-index-base K
#   3. rebuild the kernel with /init = <user_program>.pvmi
#   4. verify K did not move (paranoia: the initramfs is data only)
set -eu
cd "$(dirname "$0")"
PROG=${1:?user program name (e.g. user_calls)}; MB=${2:-0x700000}
P=${POLKATOOL:-/home/claude/pvm/polkavm/target/release/polkatool}
OUT=/home/claude/pvm/artifacts/b2
kval() { "$P" emit-image -o "$OUT/k.pvmi" "$OUT/vmlinux_b2.polkavm" >/dev/null 2>&1 && \
         python3 -c "import struct;b=open('$OUT/k.pvmi','rb').read();w=struct.unpack_from('<16I',b,0);print(w[8]//w[9])"; }
SPEC=$OUT/initramfs_spec_$PROG.txt
printf 'dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\nfile /init %s/%s.pvmi 0755 0 0\n' "$PWD" "$PROG" > "$SPEC"
[ -f "$PROG.pvmi" ] || ./build_user.sh "$PROG" "$MB" 0 >/dev/null     # placeholder image (any) for pass 1
bash ./build_b2.sh "$SPEC" >/dev/null; grep -q "LINK_RC=0" $OUT/build_b2.log || { echo "kernel build 1 failed (see $OUT/build_b2.log)"; exit 1; }
K=$(kval); echo "K = $K"
./build_user.sh "$PROG" "$MB" "$K" | tail -1
bash ./build_b2.sh "$SPEC" >/dev/null; grep -q "LINK_RC=0" $OUT/build_b2.log || { echo "kernel build 2 failed"; exit 1; }
K2=$(kval); [ "$K2" = "$K" ] || { echo "K moved: $K -> $K2 (initramfs is not data-only?!)"; exit 2; }
echo "OK: $OUT/vmlinux_b2.polkavm (/init = $PROG.pvmi, K = $K, data @ $MB)"
