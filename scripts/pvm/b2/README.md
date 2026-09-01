# Userspace-as-PVM (B2.x): standalone `.pvm` programs under the NOMMU Linux guest

The guest kernel (cva6-sdk patches 0003..0007) runs as PolkaVM bytecode on cva6-pvm; this
directory holds the userspace side: programs loaded at runtime by `fs/binfmt_pvm.c` from the
initramfs, the toolchain recipe and the silicon-proven probes.

| stage | what works | probe | UART |
|-------|-----------|-------|------|
| B2.1  | execve() of a code-only program: code appended behind the live kernel bitmask, bitmask rebuilt behind it, host grows `CFG1.code_len` (ecalli #2 `pvm_grow`, a0 = HW x8), `start_thread` | `user_hello.S` | `B2!` |
| B2.2  | + `.rodata/.data/.bss`: linked at the reserved user-data window `0x700000` (`polkatool --memory-base`, DTS `reserved-memory`), PVMI v2 header carries ro/rw bases | `user_data.S` | `B2.2 ro+rw: 37` |
| B2.3  | + function calls: the program's jump-table entries are appended after the kernel's K entries (`polkatool --jt-index-base K`, K passed by the host in `CFG2[63:40]`), PVMI v3 | `user_calls.c` | `B2.3 calls: fib(10)=55 cnt=8` |
| B2.4  | + exec chaining: the data window / JT range belong to a thread group (re-exec by the owner, reclaim from a dead owner, -EBUSY otherwise) | `user_chain.c` -> `/prog2` | `B2.4 chain -> ` + prog2's line |
| B2.5  | + argc/argv/envp: the Linux initial stack (binfmt_flat layout), `start_user.S` passes argc/argv to `main` | `user_chain.c` -> `user_args.c` | `B2.5 argv: argc=2 argv1=hello-argv env0=B25=yes` |

## Build

```
./build_b23.sh user_calls            # kernel -> K -> program(K) -> kernel(initramfs) -> verify K
./build_b23.sh user_chain user_args  # /init = user_chain, /prog2 = user_args (exec chaining)
./b2_regress.sh [bit]                # all stages on the board, ~7 min each (4/4 PASS 2026-08-28)
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

## Limits (as of B2.5)
* one data/JT-carrying program at a time (window `[0x700000,0x800000)`, JT range `[K, K+n)` -- owned
  by a thread group; sequential exec is fine, concurrent data programs are not);
* the code region is append-only (Harvard; each exec re-copies the kernel bitmask: ~230 KB, ~1 s);
* no heap/sbrk, no auxv, no `polkatool` interpreter run of these images (hardware-only memory map).

Host side: `verif/tests/custom/pvm_run/loader_kernel.S` (`host_trap`: GROW, K side-band; the resume
path is CSR/ALU/store only -- see the deadlock note in its comments and in `core/frontend/pvm_front.sv`).

## B3: musl + busybox (2026-09-01)
Real userspace: musl-1.2.5 ported to rv64e/lp64e/PVM (`../b3/musl-1.2.5-pvm-lp64e.patch`,
13 files: syscall nr in t0 + the ecalli marker, no gp/tp -- the thread pointer is the
`__pvm_tp` global, setjmp s0/s1 only, lp64e stack args in clone/syscall_cp, `_DYNAMIC`
hardwired to NULL, default mallocng -- the earlier get_meta asserts were the latest64-vs-jam_v1
ISA skew in disguise, fixed by --instruction-set jam_v1, see below). Build: `../b3/pvm-musl-gcc` wrapper (partial-link passthrough, crt1 first);
busybox 1.37 allnoconfig + `../b3/busybox_pvm_frag.config` via sed+oldconfig (KCONFIG_ALLCONFIG
does NOT work in busybox; ash needs !NOMMU -> use hush). Probes: `hello_musl.c` (printf),
`init_musl.c` (vfork+execv+waitpid) + `busybox_musl.elfsrc` (regenerate: busybox_unstripped).
Proven on Genesys2: `busybox uname -a` -> "Linux ariane-fpga 6.19.6 riscv64", echo, and a
standalone hush running `echo && uname -m`. Decoder: rot-imm ops (158-161) wired for Zbb libgcc
(`run-rotimm` gate); polkatool: the direct-call macro split at O0/O1.

## B4 addendum (2026-09-02)
Userspace polkatool links MUST pass `--instruction-set jam_v1` (polkatool defaults to
latest64 whose unary opcode group -- clz/ctz/cpop/sext/zext/rev8 -- is renumbered vs the
RTL's jam_v1_privileged table; the kernel links `-i jam_v1_privileged`). Symptoms of the
skew: mallocng get_meta a_crash, hush $((math)) "unexpected )". Guard:
`scripts/pvm/check_isa_tables.py` + the run-sext/run-sextbr sim gates. busybox builds with
CONFIG_BUSYBOX_EXEC_PATH="/prog2" (no procfs for /proc/self/exe); ash needs !NOMMU -> hush.
