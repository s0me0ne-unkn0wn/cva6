# PolkaVM JAM v1 Toolchain Spike — Sub-Phase 0

## Purpose

Software-only toolchain spike: confirm the build host can compile a minimal C
program to a PolkaVM JAM v1 blob and that the blob disassembly contains the
three required opcode classes (arithmetic add-immediate, 32-bit memory store,
trap/halt).

## Outcome

**PASS** — all three opcode classes confirmed in blob disassembly.

## Files

| File | Purpose |
|------|---------|
| `hello.c` | Minimal C source: volatile load, add_imm, store_u32, trap |
| `link.ld` | Bare-metal linker script (PIE origin 0x10000) |
| `Makefile` | Drives gcc → ELF → polkavm blob → disassembly |

## Build Invocation

```sh
# Compile C to ELF
riscv64-linux-gnu-gcc \
  -march=rv64ema_zbb -mabi=lp64e \
  -nostdlib -nostartfiles -static \
  -fPIE -fvisibility=hidden \
  -Wl,--emit-relocs -mno-relax \
  -O2 -ffreestanding \
  -T link.ld -o hello.elf hello.c

# Link ELF to PolkaVM JAM v1 blob (-i selects ISA — requires polkatool patch, see below)
polkatool link -i jam_v1 hello.elf -o hello.polkavm

# Disassemble
polkatool disassemble hello.polkavm
```

Or simply:

```sh
make POLKAVM_DIR=/home/claude/pvm/polkavm
```

## Disassembly Output

```
// RO data = 0/0 bytes
// RW data = 8/8 bytes
// Stack size = 8192 bytes

// Instructions = 4
// Code size = 14 bytes

<_start>:
      : @0 [export #0: 'main']
     0: a5 = i32 [0x20000]
     5: i32 a5 = a5 + 0x2a
     8: u32 [0x20004] = a5
    13: trap
```

## Blob Size

83–95 bytes (varies by polkavm version; measured 95 bytes on polkavm 0.33.0).

## Opcode Class Verification

| Required class | PVM ISA name | Disassembler display | Found |
|---------------|-------------|---------------------|-------|
| add_imm | `add_imm_32` | `i32 a5 = a5 + 0x2a` | YES |
| store_u32 | `store_indirect_u32` | `u32 [0x20004] = a5` | YES |
| trap | `trap` | `trap` | YES |

Note: the polkavm disassembler's human-readable display format differs from
the PVM ISA table opcode names. The grep checks in the spec use ISA names
(`add_imm`, `store_u32`); adjusted patterns that match the actual output are:

```sh
grep -qE '\+ 0x'   hello.disasm   # add_imm-class
grep -qE 'u32 \['  hello.disasm   # store_u32-class
grep -q  'trap'    hello.disasm   # trap
```

## Toolchain Anomalies

### 1. GCC 15.1.0 LP64E deprecation warning

```
cc1: warning: LP64E ABI is marked for deprecation in GCC [-Wdeprecated]
cc1: note: if you need LP64E please notify the GCC project via PR116152
```

**Informational only — not blocking.** GCC 15.1.0 marks the `lp64e` ABI as
deprecated per GCC PR116152. The compilation succeeds and the output ELF is
correct. Downstream sub-phases should expect this warning.

### 2. C extension (RVC) incompatible with polkavm-linker

The polkavm-linker rejects `c.ebreak` (opcode `0x9002`), which GCC emits for
`__builtin_trap()` when the C (compressed) extension is enabled. The fix is to
drop the `c` from the `-march` string: use `rv64ema_zbb` instead of
`rv64emac_zbb`.

**Impact on phase 1+**: any code compiled with `rv64emac_zbb` that contains
`__builtin_trap()` or assembly `ebreak`/`c.ebreak` will fail the polkavm
link step. Either omit `c` from the march, or avoid `ebreak` in any code
targeted at polkavm.

### 3. ebreak instruction not supported

The polkavm-linker also rejects 4-byte `ebreak` (`0x00100073`). The PVM `trap`
opcode is produced by the `unimp` pseudo-instruction (`0xc0001073` = `csrrw
x0,cycle,x0`), which the linker explicitly maps to `Inst::Unimplemented` →
PVM `trap`. Use `.word 0xc0001073` in inline assembly as the trap idiom.

### 4. R_RISCV_RELAX with non-zero addend panics the linker

When two adjacent `volatile` variables are placed in `.data`, GCC with
`-mrelax` (the default) emits `R_RISCV_RELAX *ABS*+0x4` — a RELAX relaxation
hint referencing the second variable with addend=4. The polkavm-linker hits an
`assert_eq!(relocation.addend(), 0)` panic on this.

**Fix**: compile with `-mno-relax`. This is a polkavm-linker upstream limitation
(the assert in `program_from_elf.rs:1702` should be a soft skip, not a panic).

### 5. `polkatool link -i jam_v1` requires a local patch (applied)

Upstream polkatool 0.33.0 hardcodes `TargetInstructionSet::Latest` in
`tools/polkatool/src/main.rs:278`. The `-i` / `--instruction-set` flag exists
only on `assemble`, not `link`. We added it to `link` via a 4-edit local patch
saved at `polkatool-isa-link.patch` in this directory.

**Apply the patch on a fresh polkavm checkout:**

```sh
cd /path/to/polkavm
git apply /path/to/cva6/verif/tests/custom/polkavm_jam_smoke/polkatool-isa-link.patch
cargo build -p polkatool
```

Without the patch, `polkatool link` only emits Latest64 blobs (version byte
`0x02`). With the patch, `-i jam_v1` emits JAM v1 blobs (version byte `0x03`).
Verify via:

```sh
od -An -c -tx1 -N5 hello.polkavm   # byte 4 = 03 if JAM v1, 02 if Latest64
```

The plan's earlier draft specified `--isa jam_v1`; clap-derive auto-names long
flags after the field name (`instruction_set`), so the long form is
`--instruction-set jam_v1` and the short form is `-i jam_v1`. Use the short
form for brevity.

### 6. Linker script .note.gnu.build-id discarded

The linker emits a warning about discarding `.note.gnu.build-id`. This is
harmless — the polkavm-linker does not use the build-id note section.

## Platform

- Host: Linux 6.12 (Manjaro)
- GCC: `riscv64-linux-gnu-gcc (GCC) 15.1.0`
- Cargo: `1.86.0`
- polkavm: `0.33.0` (workspace at `/home/claude/pvm/polkavm`)
- `riscv-none-elf-gcc`: NOT installed; `riscv64-linux-gnu-gcc` used throughout
