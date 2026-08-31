#!/bin/bash
# build_musl_user.sh <name> [memory_base] [jt_index_base]
# Compile <name>.c against the PVM-ported musl (lp64e, syscalls = ecalli marker, no gp/tp)
# and produce <name>.pvmi for binfmt_pvm. Same polkatool rules as build_user.sh.
set -eu
cd "$(dirname "$0")"
NAME=${1:?name}; MB=${2:-0x700000}; K=${3:-0}
export PATH=/home/claude/pvm/cva6-sdk/buildroot/output/host/bin:$PATH
M=/home/claude/pvm/musl-pvm
P=${POLKATOOL:-/home/claude/pvm/polkavm/target/release/polkatool}
LIBGCC=$(riscv64-buildroot-linux-gnu-gcc -march=rv64emac_zbb -mabi=lp64e -print-libgcc-file-name)
if [ -f "$NAME.elfsrc" ]; then
  # pre-built ELF (e.g. busybox linked via pvm-musl-gcc): just polkatool it
  cp "$NAME.elfsrc" "$NAME.elf"
else
riscv64-buildroot-linux-gnu-gcc -march=rv64emac_zbb -mabi=lp64e -mcmodel=medany -mno-relax \
  -fno-jump-tables -Os -nostdinc -isystem $M/include \
  -nostdlib -nostartfiles -static -Wl,--no-relax -Wl,--emit-relocs -Wl,--build-id=none \
  -o "$NAME.elf" $M/lib/crt1.o "$NAME.c" $M/lib/libc.a "$LIBGCC"
fi
"$P" link --opt-level 0 --strip --memory-base "$MB" --jt-index-base "$K" -o "$NAME.polkavm" "$NAME.elf"
"$P" emit-image --memory-base "$MB" --jt-index-base "$K" -o "$NAME.pvmi" "$NAME.polkavm"
rm -f "$NAME.elf"
ls -la "$NAME.pvmi"
