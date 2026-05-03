XLEN ?= 64
# Legacy RISC-V target toolchain (used by the legacy 'all' target).
# For the new PolkaVM target (see below) we override to riscv64-linux-gnu-
# because riscv-none-elf- does not support -mabi=lp64e on all distros.
CROSSCOMPILE ?= riscv-none-elf-

ifeq ($(BOARD), nexys_video)
DRAM_SIZE_64 ?= 0x20000000 #512MB
DRAM_SIZE_32 ?= 0x08000000 #128MB
CLOCK_FREQUENCY ?= 25000000 #25MHz
HALF_CLOCK_FREQUENCY ?= 12500000 #12.5MHz
UART_BITRATE ?= 57600
HAS_ETHERNET ?= 0
else ifeq ($(PLATFORM), PLAT_AGILEX)
DRAM_SIZE_64 ?= 0x40000000 #1GB
DRAM_SIZE_32 ?= 0x08000000 #128MB
CLOCK_FREQUENCY ?= 100000000 #100MHz
HALF_CLOCK_FREQUENCY ?= 50000000 #50MHz
UART_BITRATE ?= 115200
HAS_ETHERNET ?= 1
else
DRAM_SIZE_64 ?= 0x40000000 #1GB
DRAM_SIZE_32 ?= 0x08000000 #128MB
CLOCK_FREQUENCY ?= 50000000 #50MHz
HALF_CLOCK_FREQUENCY ?= 25000000 #25MHz
UART_BITRATE ?= 115200
HAS_ETHERNET ?= 1
endif

ifeq ($(CC),cc)
  CC = $(RISCV)/bin/${CROSSCOMPILE}gcc
  OBJCOPY = $(RISCV)/bin/$(CROSSCOMPILE)objcopy
endif
SED = sed
PLATFORM_DEFINES = -DCLOCK_FREQUENCY=$(CLOCK_FREQUENCY) -DUART_BITRATE=$(UART_BITRATE) -D$(PLATFORM)  -DXLEN=$(XLEN)

ifeq ($(XLEN), 64)
CFLAGS = $(PLATFORM_DEFINES) -Os -ggdb -march=rv64emac_zicsr -mabi=lp64e -Wall -mcmodel=medany -mexplicit-relocs -ffreestanding
else
CFLAGS = $(PLATFORM_DEFINES) -O2 -ggdb  -march=rv32im_zicsr -mabi=ilp32 -W -Wall -mcmodel=medany -mexplicit-relocs -fno-builtin -ffreestanding
endif

CCASFLAGS = -mcmodel=medany -mexplicit-relocs
LDFLAGS = -nostdlib -nodefaultlibs -nostartfiles

INCLUDES = -I./ -I./src

SRCS_C = src/main.c src/uart.c src/spi.c src/sd.c src/gpt.c src/dw_mmc.c src/bouncebuf.c
SRCS_ASM = startup.S
OBJS_C = $(SRCS_C:.c=.o)
OBJS_S = $(SRCS_ASM:.S=.o)

MAIN = bootrom_$(XLEN).elf
MAIN_BIN = $(MAIN:.elf=.bin)
MAIN_IMG = $(MAIN:.elf=.img)
MAIN_SV = $(MAIN:.elf=.sv)

ifeq ($(PLATFORM), PLAT_AGILEX)
DTB = cv$(XLEN)a6_agilex.dtb
else
DTB = cv$(XLEN)a6.dtb
endif

ifeq ($(HAS_ETHERNET), 1)
SED_DELETE_OPT = -e "/DELETE_ETH/d"
else
SED_DELETE_OPT =
endif

#.PHONY: clean

$(MAIN): $(DTB) $(OBJS_C) $(OBJS_S) linker.lds
	$(CC) $(CFLAGS) $(LDFLAGS) $(INCLUDES) -Tlinker.lds $(OBJS_S) $(OBJS_C) -o $(MAIN)
	@echo "LD    >= $(MAIN)"
	@echo "BOOTROM PLATFORM IS : $(PLATFORM)"

%.img: %.bin
	dd if=$< of=$@ bs=128

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

%.o: %.c
	@echo "CC    <= $<"
	@$(CC) $(CFLAGS) $(INCLUDES) -c $<  -o $@

%.o: %.S
	@echo "CC    <= $<"
	@$(CC) $(CFLAGS) $(CCASFLAGS) $(INCLUDES) -c $<  -o $@

%.dts: %.dts.in
	$(SED) -e "s/DRAM_SIZE_64/$(DRAM_SIZE_64)/g" \
	       -e "s/DRAM_SIZE_32/$(DRAM_SIZE_32)/g" \
	       -e "s/HALF_CLOCK_FREQUENCY/$(HALF_CLOCK_FREQUENCY)/g" \
	       -e "s/CLOCK_FREQUENCY/$(CLOCK_FREQUENCY)/g" \
	       -e "s/UART_BITRATE/$(UART_BITRATE)/g" \
	       $(SED_DELETE_OPT) $< > $@
	cat $@

%.dtb: %.dts
	dtc -I dts $< -O dtb -o cv$(XLEN)a6.dtb

%.sv: %.img
	@echo "PYTHON >= $(MAIN_SV)"
	./gen_rom.py $<

clean:
	$(RM) $(OBJS_C) $(OBJS_S) $(MAIN) $(MAIN_BIN) $(MAIN_IMG) *.dtb *.dts *.sv
	rm -f ./bootrom_32.h ./bootrom_64.h

all: $(MAIN) $(MAIN_BIN) $(MAIN_IMG) $(MAIN_SV)
	@echo "zero stage bootloader has been compiled!"

# ===========================================================================
# PolkaVM JAM v1 bootrom target
# ===========================================================================
#
# Build path (sub-phase 10):
#   Step 1  Build-host check: verify riscv64-linux-gnu-gcc supports lp64e.
#           riscv-none-elf- is used for the legacy 'all' target; the PVM path
#           requires riscv64-linux-gnu-gcc because it ships the lp64e multilib.
#   Step 2  Compile all C sources to ELF with riscv64-linux-gnu-gcc.
#   Step 3  Link ELF → .polkavm blob via patched polkatool (jam_v1 ISA).
#   Step 4  Gen SV ROMs: gen_pvm_rom.py blob → bootrom_code_64.sv +
#           bootrom_bitmask_64.sv.
#
# Toolchain override: CROSSCOMPILE is set to riscv64-linux-gnu- for this path.
# Set PVM_CC explicitly on the command line to override, e.g.:
#   make polkavm PVM_CC=/opt/riscv/bin/riscv64-unknown-elf-gcc
#
# Polkatool path: set POLKATOOL or defaults to 'cargo run -p polkatool --'
# inside the polkavm tree at $(POLKAVM_ROOT).

POLKAVM_ROOT ?= $(realpath ../../../../polkavm)

# Compiler for the PVM path: riscv64-linux-gnu-gcc (lp64e multilib)
PVM_CROSSCOMPILE ?= riscv64-linux-gnu-
PVM_CC    = $(PVM_CROSSCOMPILE)gcc
PVM_OBJCOPY = $(PVM_CROSSCOMPILE)objcopy

# polkatool invocation
ifdef POLKATOOL
  POLKATOOL_CMD = $(POLKATOOL)
else
  POLKATOOL_CMD = cargo run --manifest-path $(POLKAVM_ROOT)/Cargo.toml -p polkatool --
endif

# Compiler flags for the PVM-compatible C build
# -march=rv64emac_zbb : RV64E + MAC + Zbb (polkatool accepts these)
# -mabi=lp64e         : LP64E ABI required for PVM register file
# -mno-relax          : disable linker relaxation (polkatool does not support it)
# -nostdlib -nostartfiles : bare-metal, no libc
# -DPVM_PCYCLE_STUB   : stub out the pcycle MMIO (HW not yet mapped, sub-ph 11)
# zicsr is needed by startup.S (csrr mhartid, csrw mie) even though polkatool
# will translate/remove those CSR ops when generating the JAM v1 blob.
PVM_MARCH   = rv64emac_zbb_zicsr
PVM_ABI     = lp64e
PVM_CFLAGS  = $(PLATFORM_DEFINES) \
              -Os \
              -march=$(PVM_MARCH) -mabi=$(PVM_ABI) \
              -mno-relax \
              -Wall \
              -mcmodel=medany \
              -mexplicit-relocs \
              -ffreestanding \
              -nostdlib \
              -nostartfiles \
              -fno-pic \
              -fno-plt \
              -static \
              -DPVM_PCYCLE_STUB

# --emit-relocs: keep relocation entries in the final ELF so polkatool can
#   rewrite PC-relative auipc sequences into absolute PVM load_imm ops.
# --build-id=none: suppress .note.gnu.build-id section polkatool rejects.
# -static/-fno-pic/-fno-plt: prevent GOT/PLT/dynamic sections that
#   polkatool cannot handle ("basic instruction refers to neither data nor text").
PVM_LDFLAGS = -nostdlib -nodefaultlibs -nostartfiles \
              -static \
              -Wl,--emit-relocs -Wl,--build-id=none

# Sources (same as legacy path; startup.S provides _start for RV64E ELF entry)
PVM_SRCS_C   = src/main.c src/uart.c src/spi.c src/sd.c src/gpt.c \
               src/dw_mmc.c src/bouncebuf.c
PVM_SRCS_ASM = startup.S
PVM_OBJS_C   = $(PVM_SRCS_C:.c=.pvm.o)
PVM_OBJS_S   = $(PVM_SRCS_ASM:.S=.pvm.o)

PVM_ELF     = bootrom.elf
PVM_BLOB    = bootrom.polkavm
PVM_CODE_SV = bootrom_code_64.sv
PVM_BM_SV   = bootrom_bitmask_64.sv

# ---------------------------------------------------------------------------
# Build-host check (Step 1)
# ---------------------------------------------------------------------------
.PHONY: check-pvm-toolchain
check-pvm-toolchain:
	@echo "Checking PVM toolchain: $(PVM_CC) -march=$(PVM_MARCH) -mabi=$(PVM_ABI) ..."
	@$(PVM_CC) -march=$(PVM_MARCH) -mabi=$(PVM_ABI) -mno-relax -nostdlib \
	    -c -x c /dev/null -o /dev/null 2>&1 \
	  && echo "  OK: $(PVM_CC) supports -march=$(PVM_MARCH) -mabi=$(PVM_ABI)" \
	  || { echo "  FAIL: $(PVM_CC) does not support required flags."; \
	       echo "  Install riscv64-linux-gnu-gcc with lp64e multilib."; \
	       exit 1; }

# ---------------------------------------------------------------------------
# Compile C sources (Step 2) — .pvm.o objects to avoid colliding with legacy
# ---------------------------------------------------------------------------
%.pvm.o: %.c
	@echo "PVM-CC <= $<"
	$(PVM_CC) $(PVM_CFLAGS) $(INCLUDES) -c $< -o $@

%.pvm.o: %.S
	@echo "PVM-AS <= $<"
	$(PVM_CC) $(PVM_CFLAGS) -mcmodel=medany -mexplicit-relocs $(INCLUDES) -c $< -o $@

# ---------------------------------------------------------------------------
# Link ELF (Step 2 cont.)
# ---------------------------------------------------------------------------
$(PVM_ELF): check-pvm-toolchain $(DTB) $(PVM_OBJS_C) $(PVM_OBJS_S) linker_pvm.lds
	$(PVM_CC) $(PVM_CFLAGS) $(PVM_LDFLAGS) $(INCLUDES) \
	    -Tlinker_pvm.lds $(PVM_OBJS_S) $(PVM_OBJS_C) -o $@
	@echo "LD => $(PVM_ELF)"

# ---------------------------------------------------------------------------
# polkatool link → .polkavm blob (Step 3)
# ---------------------------------------------------------------------------
$(PVM_BLOB): $(PVM_ELF)
	@echo "POLKATOOL link => $(PVM_BLOB)"
	# --strip: suppress debug info emission to avoid an assertion in polkatool's
	# debug line-program builder (offsets.len != locations_for_instruction.len).
	# Debug symbols are not needed in the ROM blob.
	$(POLKATOOL_CMD) link -i jam_v1 --strip $(PVM_ELF) -o $(PVM_BLOB)

# ---------------------------------------------------------------------------
# gen_pvm_rom.py → SV ROMs (Step 4)
# ---------------------------------------------------------------------------
$(PVM_CODE_SV) $(PVM_BM_SV): $(PVM_BLOB)
	@echo "GEN_PVM_ROM => $(PVM_CODE_SV) $(PVM_BM_SV)"
	python3 gen_pvm_rom.py \
	    --in $(PVM_BLOB) \
	    --out-code $(PVM_CODE_SV) \
	    --out-bitmask $(PVM_BM_SV) \
	    --verbose

# ---------------------------------------------------------------------------
# Top-level polkavm target (default for PVM builds)
# ---------------------------------------------------------------------------
.PHONY: polkavm
polkavm: $(PVM_CODE_SV) $(PVM_BM_SV)
	@echo "=== PolkaVM JAM v1 bootrom build complete ==="
	@echo "  ELF    : $(PVM_ELF)"
	@echo "  Blob   : $(PVM_BLOB)"
	@echo "  Code SV: $(PVM_CODE_SV)"
	@echo "  Mask SV: $(PVM_BM_SV)"
	@echo "Disassembly:"
	$(POLKATOOL_CMD) disassemble $(PVM_BLOB)

# ---------------------------------------------------------------------------
# Disassemble helper
# ---------------------------------------------------------------------------
.PHONY: disasm
disasm: $(PVM_BLOB)
	$(POLKATOOL_CMD) disassemble $(PVM_BLOB)

# ---------------------------------------------------------------------------
# Clean extension for PVM artifacts
# ---------------------------------------------------------------------------
clean-polkavm:
	$(RM) $(PVM_OBJS_C) $(PVM_OBJS_S) \
	      $(PVM_ELF) $(PVM_BLOB) \
	      $(PVM_CODE_SV) $(PVM_BM_SV)

# DO NOT DELETE THIS LINE -- make depend needs it
