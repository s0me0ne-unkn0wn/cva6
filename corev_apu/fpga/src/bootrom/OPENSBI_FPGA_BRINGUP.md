# OpenSBI-on-PolkaVM — Genesys2 FPGA bring-up recipe (B9)

Run a **real OpenSBI build** as a PolkaVM/JAM guest on the CVA6-PVM core on a Digilent Genesys2,
and see its banner on the UART. This is the hardware port of the Verilator gate
`verif/tests/custom/pvm_run/run-opensbi` (loader `loader_opensbi.S`).

The bootrom does NOT bake the 2 MB OpenSBI DRAM image (the ROM is only ~12 KB). Instead the image
is **staged into DRAM out-of-band** (JTAG/gdb, recommended; or SD card), and the bootrom routine
`opensbi_pvm_boot` (in `opensbi_boot.S`) programs the PVM CSRs to demand-fetch + run it, servicing
the guest's `ecalli` console putchar so the banner reaches the ns16550 UART.

> Status: **UNTESTED on hardware** (prepared without board access). The bootrom side assembles,
> links, and fits (see "Build" below). Everything from `make fpga` onward needs board validation;
> the items most likely to need a tweak are flagged **[VERIFY ON BOARD]**.

---

## 0. Prerequisites

- Vivado installed; source its settings once per shell: `source ~/tools/Xilinx/Vivado/*/settings64.sh`
  (or wherever your install lives). `make fpga` and `make program` need `vivado` on `PATH`.
- A RISC-V toolchain with `rv64emac`/`lp64e` support. The repo uses `riscv64-linux-gnu-` (GCC 15.1
  validated here). The bootrom Makefile defaults to `riscv-none-elf-`; override with
  `CROSSCOMPILE=riscv64-linux-gnu- RISCV=/usr` if that is what you have.
- OpenOCD for the JTAG/gdb staging path (config `corev_apu/fpga/ariane-multi-hart.cfg` or
  `ariane_pmod.cfg`; see `tutorials/fpga.md` §Debugging).
- The staged OpenSBI image: `cva6-sdk/install64e_genesys2/fw_payload.bin` (the emit-image "PVMI"
  blob) — already split + linked by the `run-opensbi` flow into `loader_opensbi.elf`.

---

## 1. Build the FPGA bitstream with the OpenSBI-PVM bootrom

`make fpga` regenerates `bootrom_64.sv` from this directory's Makefile, then runs Vivado (~1–2 h).
To select the OpenSBI launch path (instead of the default "PolkaVM on CVA6!" banner), build the
bootrom with `OPENSBI_PVM=1` and the current image's `CODE_LEN`/`JT_Z`.

Derive `CODE_LEN`/`JT_Z` from the **exact** staged image (do this every time OpenSBI is rebuilt):

```bash
cd verif/tests/custom/pvm_run
python3 opensbi_to_dram.py /home/claude/pvm/cva6-sdk/install64e_genesys2/fw_payload.bin /tmp/osbi
# -> prints:  CODE_LEN : 85658     JT_Z : 3      (track these)
```

Then, from the repo root, build the bitstream. The top `fpga` target forwards `BOARD`/`PLATFORM`
to the bootrom sub-make; pass the OpenSBI knobs through `MAKEFLAGS`-style overrides on the bootrom
make (simplest: regenerate the bootrom first with the knobs, then run `make fpga`, which will see
the freshly generated `bootrom_64.sv` and not rebuild it):

```bash
# (a) generate the OpenSBI-PVM bootrom ROM explicitly:
make -C corev_apu/fpga/src/bootrom \
     BOARD=genesys2 XLEN=64 PLATFORM=PLAT_XILINX \
     CROSSCOMPILE=riscv64-linux-gnu- RISCV=/usr \
     OPENSBI_PVM=1 CODE_LEN=85658 JT_Z=3 \
     bootrom_64.sv

# (b) build the bitstream (genesys2 is the default BOARD):
source ~/tools/Xilinx/Vivado/*/settings64.sh
make fpga BOARD=genesys2            # ~1–2 h -> corev_apu/fpga/work-fpga/ariane_xilinx.bit
```

> NOTE: `make fpga`'s bootrom rule has no `OPENSBI_PVM` dependency, so step (a) must run first and
> leave `bootrom_64.sv` in place; `make fpga` will reuse it (it only rebuilds if missing). If you
> run `make fpga` first it bakes the *default banner* ROM — re-run (a) then `touch` the `.sv` and
> re-run `make fpga`. **[VERIFY ON BOARD]** that the bitstream picked up the OpenSBI ROM (UART will
> print `Entering PolkaVM (OpenSBI)...` not `Entering PolkaVM...`).

The default (no `OPENSBI_PVM`) bootrom is byte-identical to the proven banner ROM (RomSize 1469);
the OpenSBI ROM is RomSize 1502 (12016 B), well within the 64 KB ROM region (`ROMLength=0x10000`).

---

## 2. Flash the bitstream to the board

Connect the board (USB-JTAG, the J17/micro-USB), power on, then:

```bash
source ~/tools/Xilinx/Vivado/*/settings64.sh
export HW_SERVER_URL=localhost:3121          # start `hw_server` first, or let Vivado spawn one
make -C corev_apu/fpga program                # runs scripts/program.tcl -> program_genesys2.tcl
```

`program_genesys2.tcl` programs `xc7k325t_0` with `work-fpga/ariane_xilinx.bit`. (For a permanent
flash to SPI, generate the `.mcs` and use the Vivado flow in `tutorials/fpga.md` §1.)

---

## 3. Stage the 2 MB OpenSBI DRAM image into DRAM

### 3a. Extract the flat DRAM image (one contiguous blob @ 0x80000000)

`loader_opensbi.elf` is a single PT_LOAD spanning `0x80000000 → ~0x802015e1` with the five guest
regions at their final addresses and the inter-region gaps zero-padded. `objcopy -O binary` gives a
flat ~2.01 MB blob that maps 1:1 onto DRAM at `0x80000000`:

```bash
cd verif/tests/custom/pvm_run
# ensure loader_opensbi.elf is fresh for the current image (the run-opensbi gate builds it; or):
make run-opensbi   # (re-links loader_opensbi.elf with the derived -DCODE_LEN/-DJT_Z); Ctrl-C the sim
riscv64-linux-gnu-objcopy -O binary loader_opensbi.elf /tmp/opensbi_dram.bin   # ~2102753 bytes
```

Region check (the blob places each region at the right offset — verified):
| region | flat offset | phys addr   | first bytes |
|--------|-------------|-------------|-------------|
| ro     | 0x00010000  | 0x80010000  | `2d2d2d00`  |
| rw     | 0x00030000  | 0x80030000  | (rw_init)   |
| dtb    | 0x00090000  | 0x80090000  | `d00dfeed`  |
| code   | 0x00100000  | 0x80100000  | `64756486`  |
| jt     | 0x00200000  | 0x80200000  | `10000049`  |

The sim loader's own M-mode `.text.init` (@0x80000000) is harmless filler on HW — the bootrom, not
that code, drives the launch, and PVM fetches from `code_base=0x80100000`.

### 3b. Load it over JTAG/gdb (recommended for a first bring-up)

Start OpenOCD against the board, then gdb-`restore` the flat blob into DRAM and release the
bootrom's "ready" spin:

```bash
# terminal 1: OpenOCD (gdb server on :3333) — see tutorials/fpga.md for the exact cfg for your cable
openocd -f corev_apu/fpga/ariane-multi-hart.cfg     # or ariane_pmod.cfg

# terminal 2: gdb
riscv64-linux-gnu-gdb -q
(gdb) target remote localhost:3333
(gdb) monitor reset halt                       # optional; the bootrom is already spinning on READY
# load the flat OpenSBI image into DRAM at 0x80000000 (binary restore):
(gdb) restore /tmp/opensbi_dram.bin binary 0x80000000
# release the bootrom: write the ready magic ABOVE the image (clobber-proof, order-independent):
(gdb) set {int}0x80300000 = 0x5042564d        # "MVBP" -> opensbi_pvm_boot stops spinning
(gdb) continue
```

The bootrom's `opensbi_pvm_boot` polls `0x80300000` for `0x5042564d`; on match it programs the PVM
CSRs (aperture, CFG0/CFG2/VEC, a0/a1/a2, CFG1=FETCH|ACTIVE|CODE_LEN), enters PVM, and the guest
runs. **[VERIFY ON BOARD]** the `restore` rate (2 MB over JTAG can take a few seconds) and that
`monitor reset halt` is not required (the spin makes the bootrom wait regardless of reset timing).

> Alternative (no spin): build the bootrom with `OPENSBI_NO_WAIT` defined (add it to `CFLAGS` in
> the `OPENSBI_PVM` block) and instead `set $pc = &opensbi_pvm_boot` after the restore. The spin is
> simpler — you never need the entry address.

### 3c. SD-card staging (alternative — no debugger needed at boot)

The bootrom already has an SD/GPT path (`src/{dw_mmc,sd,gpt}.c`, `sd_copy_mmc`). To use it:
1. Write `/tmp/opensbi_dram.bin` to a raw SD region (a dedicated partition or fixed LBA), e.g.
   `sudo dd if=/tmp/opensbi_dram.bin of=/dev/sdX bs=512 seek=<lba>`.
2. In `src/main.c`, before `opensbi_pvm_boot()`, copy it to DRAM with `sd_copy_mmc((uint8_t*)
   0x80000000, <lba>, <blkcnt=ceil(2102753/512)=4108>)` (mirror the `gpt_find_boot_partition` /
   Agilex `sd_copy_mmc` loop already in `main.c`), and build the bootrom with
   `OPENSBI_PVM=1 OPENSBI_NO_WAIT` (skip the JTAG spin — the copy is done in C).
**[VERIFY ON BOARD]** the SD LBA/partition mapping and `sd_copy_mmc` block count; the JTAG path
avoids all of this for a one-off, which is why it is recommended first.

---

## 4. Watch the banner on the UART

```bash
screen /dev/ttyUSB0 115200          # or: picocom -b 115200 /dev/ttyUSB0
```

Expected sequence:
```
Hello World!
Entering PolkaVM (OpenSBI)...
OpenSBI v1.7
   ____                    _____ ____ _____
  / __ \                  / ____|  _ \_   _|
 ...
```

- `Hello World!` + `Entering PolkaVM (OpenSBI)...` come from the bootrom C (`main.c`).
- The OpenSBI banner is emitted by the **guest** via `ecalli #0` (console putchar), handled by
  `opensbi_trap_handler` → ns16550 THR. If you see `!F` instead, the guest took a non-ecalli trap
  (a real fault); attach gdb and read `mcause`/`mepc`/`mtval` for the post-mortem.

---

## CSR launch sequence (what `opensbi_pvm_boot` does — mirror of `loader_opensbi.S`)

1. Spin on `0x80300000 == 0x5042564d` (JTAG-ready handshake; skipped under `OPENSBI_NO_WAIT`).
2. `CSR_PVM_VEC (0xBC4) = &opensbi_trap_handler` (+ `mtvec` fallback).  Uses `lla` (PC-relative).
3. Zero guest BSS `[0x80030b00, 0x80031738)`.
4. `CSR_PVM_RAM (0xBC5) = {ram_hi_page=0x10[63:48], ram_lo_page=1[47:32], ram_base=0x80000000[31:0]}`
   → guest `[0x10000,0x100000)` ⇒ DRAM `[0x80010000,0x80100000)`.
5. `CSR_PVM_CFG0 (0xBC0) = 0x80100000 << 32` (code_base; entry_pc=0).
6. `CSR_PVM_CFG2 (0xBC2) = 0x80200000 | (JT_Z=3 << 32)` (jt_base | z).
7. Seed PVM guest regs: `x8=0` (a0/hartid), `x9=0x90000` (a1/DTB ptr), `x10=0` (a2).
8. `fence` (publish the DRAM writes to the fetch dcache path).
9. `CSR_PVM_CFG1 (0xBC1) = 0`, then `= (1<<34)|(1<<32)|CODE_LEN` (FETCH_DRAM | ACTIVE | code_len).
10. Host-trap handler: on `mcause==11` (ENV_CALL_M), `mtval==0` ⇒ putchar(`x8`) to UART; resume via
    `CFG1 = (1<<34)|(1<<33)|(1<<32)|CODE_LEN` (FETCH | RESUME | ACTIVE | len).

CFG1/RAM/CFG0/CFG2 fields wider than 32 bits are built with explicit `li+slli+or` in assembly (the
C preprocessor does 32-bit math and would silently overflow `(1<<34)`).

---

## Open risks / what needs board validation

- **[VERIFY ON BOARD]** `make fpga` actually bakes the OpenSBI ROM (the bootrom rule has no
  `OPENSBI_PVM` dep; regenerate `bootrom_64.sv` first — see §1). UART must say `(OpenSBI)`.
- **[VERIFY ON BOARD]** JTAG `restore` of a 2 MB blob (speed; cable cfg). The `ariane-*.cfg` chosen
  must match your JTAG adapter.
- **[VERIFY ON BOARD]** the ns16550 baud (`115200` here) vs the bootrom `init_uart` clocking.
- **CODE_LEN/JT_Z drift**: every OpenSBI rebuild changes `code_size`. Re-derive (§1) and rebuild the
  bootrom; the flat image (`loader_opensbi.elf`) must be from the SAME rebuild.
- **Sim-only so far**: the underlying PVM RTL fixes (CSR-read, CMOV, store-imm) live in the working
  tree (`core/pvm_decoder.sv` et al.) — the FPGA reads the tree directly, so the bitstream must be
  built from a tree that has them. They are validated in sim (`run-opensbi` reaches past
  domain_init); the banner's final stretch is a sim-speed wall, not a correctness one.
- The bootrom UART putchar reuses the proven `pvm_boot.S` THRE-flow-control + LSR-read MMIO
  serialization, so the console path itself is low-risk.
