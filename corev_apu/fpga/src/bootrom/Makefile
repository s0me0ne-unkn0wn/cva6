XLEN ?= 64
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
SRCS_ASM = startup.S pvm_boot.S

# OpenSBI-on-PVM (B9): opt-in with `make ... OPENSBI_PVM=1` (also threaded by the top Makefile
# when building the FPGA bootrom for the OpenSBI demo). Adds the DRAM-launch routine + selects
# the opensbi_pvm_boot() branch in main.c. CODE_LEN/JT_Z track the staged fw_payload.bin
# (opensbi_to_dram.py header code_size / jt_entry); override on the make line if the image is
# rebuilt, e.g. `make OPENSBI_PVM=1 CODE_LEN=85658 JT_Z=3 bootrom_64.sv`.
ifeq ($(OPENSBI_PVM), 1)
SRCS_ASM += opensbi_boot.S
CFLAGS += -DOPENSBI_PVM
ifdef CODE_LEN
CFLAGS += -DCODE_LEN=$(CODE_LEN)
endif
ifdef JT_Z
CFLAGS += -DJT_Z=$(JT_Z)
endif
# UART-download variant: receive the 2.1 MB OpenSBI DRAM image over the serial UART in C
# (main.c uart_load_dram) instead of an out-of-band JTAG/gdb preload. Pair with OPENSBI_NO_WAIT=1
# so opensbi_boot.S skips the JTAG ready-magic spin (the C download is the staging handshake).
# Override LOAD_BYTES if the image size changes (default 2102750).
ifeq ($(OPENSBI_UART_LOAD), 1)
CFLAGS += -DOPENSBI_UART_LOAD
ifdef LOAD_BYTES
CFLAGS += -DLOAD_BYTES=$(LOAD_BYTES)
endif
endif
ifeq ($(OPENSBI_NO_WAIT), 1)
CFLAGS += -DOPENSBI_NO_WAIT
endif
endif

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

# PolkaVM minimal bootrom (RV64E, asm-only, no SD/UART)
POLKAVM_ELF = bootrom_polkavm.elf
POLKAVM_BIN = bootrom_polkavm.bin
POLKAVM_IMG = bootrom_polkavm.img
POLKAVM_SV  = bootrom_polkavm.sv
POLKAVM_CFLAGS = -march=rv64emac -mabi=lp64e -DXLEN=64 -mcmodel=medany -mexplicit-relocs -nostdlib -static

$(POLKAVM_ELF): $(DTB) startup_polkavm.S linker.lds
	$(CC) $(POLKAVM_CFLAGS) $(INCLUDES) -Tlinker.lds startup_polkavm.S -o $@

polkavm: $(POLKAVM_ELF) $(POLKAVM_BIN) $(POLKAVM_IMG) $(POLKAVM_SV)
	@echo "PolkaVM RV64E bootrom compiled!"

# DO NOT DELETE THIS LINE -- make depend needs it
