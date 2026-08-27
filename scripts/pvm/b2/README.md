# Userspace-as-PVM (B2.x): standalone `.pvm` programs under the NOMMU Linux guest

The guest kernel (cva6-sdk patches 0003..0007) runs as PolkaVM bytecode on cva6-pvm; this
directory holds the userspace side: programs loaded at runtime by `fs/binfmt_pvm.c` from the
initramfs, the toolchain recipe and the silicon-proven probes.

| stage | what works | probe | UART |
|-------|-----------|-------|------|
| B2.1  | execve() of a code-only program: code appended behind the live kernel bitmask, bitmask rebuilt behind it, host grows `CFG1.code_len` (ecalli #2 `pvm_grow`, a0 = HW x8), `start_thread` | `user_hello.S` | `B2!` |
| B2.2  | + `.rodata/.data/.bss`: linked at the reserved user-data window `0x700000` (`polkatool --memory-base`, DTS `reserved-memory`), PVMI v2 header carries ro/rw bases | `user_data.S` | `B2.2 ro+rw: 37` |
| B2.3  | + function calls: the program's jump-table entries are appended after the kernel's K entries (`polkatool --jt-index-base K`, K passed by the host in `CFG2[63:40]`), PVMI v3 | `user_calls.c` | `B2.3 calls: fib(10)=55 cnt=8` |

## Build

```
./build_b23.sh user_calls            # kernel -> K -> program(K) -> kernel(initramfs) -> verify K
../fpga_run.sh ~/pvm/artifacts/b2/vmlinux_b2.polkavm <tag>   # Genesys2: program bit, JTAG load, UART capture
```
`build_user.sh <name> [memory_base] [K]` builds one program (`<name>.S`, or `<name>.c` + `start_user.S`);
`build_b2.sh <initramfs_spec>` builds + links the kernel (`polkatool link -i jam_v1_privileged -O1`).

Toolchain rules (all learned the hard way):
* `-mno-relax -Wl,--no-relax` -- linker relaxation leaves relocations polkatool cannot apply
  ("failed to add addend to the symbol's offset due to overflow"); same for `lla`.
* `-Wl,--emit-relocs -Wl,--build-id=none` -- polkatool needs the export/metadata relocations, rejects build-id.
* `polkatool link --opt-level 0` -- O>=1 deletes `t0 = <syscall nr>` before the `ecalli` (t0 is not
  an ecalli input register in the metadata). Syscall ABI = RV64E: nr in t0, args a0..a5, ecalli 0.
* `la` (GOT) for data addresses is fine: polkatool resolves the GOT to the `--memory-base` addresses.
* K depends on the kernel CODE only (not on the initramfs), but any kernel code change moves it ->
  rebuild the programs (`build_b23.sh` does the loop and checks).

## Limits (as of B2.3)
* one data/JT-carrying program at a time (window `[0x700000,0x800000)`, JT range `[K, K+n)`);
* the code region is append-only (Harvard; each exec re-copies the kernel bitmask: ~230 KB, ~1 s);
* no heap/sbrk, no argv/envp/auxv (sp = top of an anonymous stack), no `polkatool` interpreter run
  of these images (hardware-only memory map).

Host side: `verif/tests/custom/pvm_run/loader_kernel.S` (`host_trap`: GROW, K side-band; the resume
path is CSR/ALU/store only -- see the deadlock note in its comments and in `core/frontend/pvm_front.sv`).
