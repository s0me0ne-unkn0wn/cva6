# Makefile for PolkaVM RV64EMAC smoke tests
RISCV_PREFIX ?= riscv64-linux-gnu-
CC      = $(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_PREFIX)objdump

MARCH  = rv64emac_zbb
MABI   = lp64e
CFLAGS = -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles -static
LDFLAGS = -T link.ld

TESTS = xtheadcondmov_test rv64emac_zbb_test

all: $(addsuffix .elf, $(TESTS)) $(addsuffix .bin, $(TESTS))

%.elf: %.S link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

%.dump: %.elf
	$(OBJDUMP) -d $< > $@

disasm: $(addsuffix .dump, $(TESTS))

clean:
	rm -f *.elf *.bin *.dump *.o

.PHONY: all clean disasm
