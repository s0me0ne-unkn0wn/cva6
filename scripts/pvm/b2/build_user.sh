#!/bin/bash
# build_user.sh <name> [memory_base]
# Rebuild <name>.{polkavm,pvmi} from <name>.S for the cva6-pvm guest kernel (binfmt_pvm).
#  * --emit-relocs: polkatool needs the relocation for the export's metadata pointer
#  * --build-id=none: polkatool rejects .note.gnu.build-id
#  * --opt-level 0: O>=1 deletes `t0 = <syscall nr>` before the ecalli (t0 is not an ecalli input
#    register in the metadata, so the optimizer thinks it is dead) -> the kernel would see nr=garbage
#  * memory_base (B2.2, default 0x10000 = code-only programs): link the ro/rw data at the guest
#    kernel's reserved user-data window [0x700000,0x800000) and record it in the PVMI v2 header.
set -eu
cd "$(dirname "$0")"
NAME=${1:?name}; MB=${2:-}
P=${POLKATOOL:-/home/claude/pvm/polkavm/target/release/polkatool}
MBARG=(); [ -n "$MB" ] && MBARG=(--memory-base "$MB")
riscv64-linux-gnu-gcc -march=rv64emac_zbb -mabi=lp64e -mcmodel=medany -nostdlib -nostartfiles -static \
  -Wl,--emit-relocs -Wl,--build-id=none -Wno-deprecated -o "$NAME.elf" "$NAME.S"
"$P" link --opt-level 0 --strip "${MBARG[@]}" -o "$NAME.polkavm" "$NAME.elf"
"$P" emit-image "${MBARG[@]}" -o "$NAME.pvmi" "$NAME.polkavm"
rm -f "$NAME.elf"
ls -la "$NAME.pvmi"
