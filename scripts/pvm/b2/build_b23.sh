#!/bin/bash
# build_b23.sh <init_program> [more programs...] [0xFIRST_SLOT]   (progN -> /progN, slot N-1, sequential --jt-index-base)
# B2.3 build loop: a user program that makes calls needs its jump-table tokens numbered from
# K = the kernel's jump-table entry count, and it is embedded in the kernel's initramfs. K
# depends only on the kernel CODE (not on the initramfs data), so:
#   1. build the kernel with a placeholder initramfs -> K
#   2. build <user_program> with --memory-base <mb> --jt-index-base K
#   3. rebuild the kernel with /init = <user_program>.pvmi
#   4. verify K did not move (paranoia: the initramfs is data only)
set -eu
cd "$(dirname "$0")"
PROG=${1:?init program name (e.g. user_calls)}; shift; MB=0x700000
EXTRA=()                     # further programs land at /prog2, /prog3 ... (B2.4 chaining / B2.7 slots)
for a in "$@"; do case "$a" in 0x*) MB=$a;; *) EXTRA+=("$a");; esac; done
SLOT_SIZE=$((0x40000))       # B2.7: each data program is linked at its own 256 KiB window slot
P=${POLKATOOL:-/home/claude/pvm/polkavm/target/release/polkatool}
OUT=/home/claude/pvm/artifacts/b2
kval() { "$P" emit-image -o "$OUT/k.pvmi" "$OUT/vmlinux_b2.polkavm" >/dev/null 2>&1 && \
         python3 -c "import struct;b=open('$OUT/k.pvmi','rb').read();w=struct.unpack_from('<16I',b,0);print(w[8]//w[9])"; }
SPEC=$OUT/initramfs_spec_$PROG.txt
{ printf 'dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\nfile /init %s/%s.pvmi 0755 0 0\n' "$PWD" "$PROG"
  printf 'dir /etc 0755 0 0\nfile /etc/motd %s/motd.txt 0644 0 0\ndir /tmp 1777 0 0\n' "$PWD"   # B4.1: real files for ls/cat
  i=2; for e in "${EXTRA[@]}"; do printf 'file /prog%d %s/%s.pvmi 0755 0 0\n' "$i" "$PWD" "$e"; i=$((i+1)); done; } > "$SPEC"
SB=$((MB)); for e in "$PROG" "${EXTRA[@]}"; do case "$e" in *_musl) B=./build_musl_user.sh;; *) B=./build_user.sh;; esac; [ -f "$e.pvmi" ] || $B "$e" $(printf 0x%x $SB) 0 >/dev/null; SB=$((SB+SLOT_SIZE)); done   # placeholders for pass 1
bash ./build_b2.sh "$SPEC" >/dev/null; grep -q "LINK_RC=0" $OUT/build_b2.log || { echo "kernel build 1 failed (see $OUT/build_b2.log)"; exit 1; }
K=$(kval); echo "K = $K"
# B2.7: program i gets slot i (base MB + i*256K) and the next free jump-table index range.
SB=$((MB)); JB=$K
for e in "$PROG" "${EXTRA[@]}"; do
  case "$e" in *_musl) B=./build_musl_user.sh;; *) B=./build_user.sh;; esac   # B3: *_musl -> the musl toolchain
  $B "$e" $(printf 0x%x $SB) "$JB" | tail -1
  n=$(python3 -c "import struct;b=open('$e.pvmi','rb').read();w=struct.unpack_from('<16I',b,0);print(w[8]//w[9] if w[9] else 0)")
  echo "   $e: slot $(printf 0x%x $SB), jt [$JB, $((JB+n)))"
  JB=$((JB+n)); SB=$((SB+SLOT_SIZE))
done
bash ./build_b2.sh "$SPEC" >/dev/null; grep -q "LINK_RC=0" $OUT/build_b2.log || { echo "kernel build 2 failed"; exit 1; }
K2=$(kval); [ "$K2" = "$K" ] || { echo "K moved: $K -> $K2 (initramfs is not data-only?!)"; exit 2; }
echo "OK: $OUT/vmlinux_b2.polkavm (/init = $PROG.pvmi, K = $K, data @ $MB)"
