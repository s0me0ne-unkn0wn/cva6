#!/bin/bash
# Rebuild user_hello.{elf,polkavm,pvmi} from user_hello.S (byte-identical to the committed .pvmi).
#  * --emit-relocs: polkatool needs the relocation for the export's metadata pointer
#  * --build-id=none: polkatool rejects .note.gnu.build-id
#  * --opt-level 0: O>=1 deletes `t0 = <syscall nr>` before the ecalli (t0 is not an ecalli input
#    register in the metadata, so the optimizer thinks it is dead) -> the kernel would see nr=garbage.
set -eu
cd "$(dirname "$0")"
P=${POLKATOOL:-/home/claude/pvm/polkavm/target/release/polkatool}
riscv64-linux-gnu-gcc -march=rv64emac_zbb -mabi=lp64e -nostdlib -nostartfiles -static \
  -Wl,--emit-relocs -Wl,--build-id=none -Wno-deprecated -o user_hello.elf user_hello.S
"$P" link --opt-level 0 --strip -o user_hello.polkavm user_hello.elf
"$P" emit-image -o user_hello.pvmi user_hello.polkavm
ls -la user_hello.pvmi
