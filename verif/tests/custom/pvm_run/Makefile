# Observable PVM gate: a JAM program runs through the integrated CVA6 pipeline
# (pvm_front -> issue -> EX -> commit), drives the simulated UART (mock_uart),
# traps into M-mode, and the handler signals SUCCESS via HTIF tohost.
#
#   make            # build loader.elf
#   make run        # load_imm r5,0xAB ; trap          (expects *** SUCCESS ***)
#   make run-jump   # unconditional-jump redirect test
#   make run-banner # PVM bootloader prints a UART banner, then traps (MVP gate)
#
# Prereq: the testharness is built (from repo root:
#   make verilate target=cv64a6_emac_polkavm RISCV=/usr).
RISCV_PREFIX ?= riscv64-linux-gnu-
CC      = $(RISCV_PREFIX)gcc
# -Wno-deprecated silences the LP64E ABI deprecation note (harmless here).
CFLAGS  = -march=rv64emac_zbb_zicsr -mabi=lp64e -mcmodel=medany \
          -fno-pic -fno-pie -nostdlib -nostartfiles -static -no-pie -Wno-deprecated
HARNESS ?= ../../../../work-ver/Variane_testharness
TOHOST  ?= 80001000
IMG     ?= loadimm_trap.hex      # JAM image: load_imm r5,0xAB ; trap (code@0,len=4)
# banner text for run-banner (no trailing spaces: make keeps them in the value)
BANNER  ?= PolkaVM on CVA6!\n

all: loader.elf

loader.elf: loader.S link.ld
	$(CC) $(CFLAGS) -T link.ld -o $@ $<

run: loader.elf $(IMG)
	$(HARNESS) +PVM_IMG=$(abspath $(IMG)) +tohost_addr=$(TOHOST) +time_out=80000 $(abspath loader.elf)

# Stage 3.3a: unconditional-jump redirect test (jump@0 skips trap@2 -> load_imm@3 -> trap@6)
loader_jump.elf: loader.S link.ld
	$(CC) $(CFLAGS) -DCODE_LEN=7 -T link.ld -o $@ $<

run-jump: loader_jump.elf jump_test.hex
	$(HARNESS) +PVM_IMG=$(abspath jump_test.hex) +tohost_addr=$(TOHOST) +time_out=80000 $(abspath loader_jump.elf)

# Stage 4 MVP: generate a putchar banner image, size the loader to its code_len,
# run it. gen_pvm_img.py emits the JAM image (code + LSB-first bitmask) and prints
# CODE_LEN; each character is serialized with an LSR read so the WT-dcache does not
# coalesce the back-to-back same-address UART writes.
run-banner: loader.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '$(BANNER)' banner.hex | tee /dev/stderr | grep CODE_LEN | grep -oE '[0-9]+'); \
	echo ">> building loader with CODE_LEN=$$CL"; \
	$(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_banner.elf loader.S; \
	$(HARNESS) +PVM_IMG=$(abspath banner.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_banner.elf)

# Stage 4 host-call model: the banner is printed via `ecalli #0` (putchar) host
# calls instead of direct MMIO. Each char: load_imm r7,c ; ecalli #0. The PVM trap
# vectors to M-mode (mcause=ENV_CALL_MMODE), the handler does putchar(PVM r7) and
# resumes the guest at next_pc (carried in mepc), proving PVM-mode resume-after-trap.
run-ecalli: loader.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '$(BANNER)' ecalli.hex ecalli | tee /dev/stderr | grep CODE_LEN | grep -oE '[0-9]+'); \
	echo ">> building loader with CODE_LEN=$$CL"; \
	$(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_ecalli.elf loader.S; \
	$(HARNESS) +PVM_IMG=$(abspath ecalli.hex) +tohost_addr=$(TOHOST) +time_out=400000 $(abspath loader_ecalli.elf)

clean:
	rm -f loader.elf loader_jump.elf loader_banner.elf loader_ecalli.elf loader_hi.elf baseline.elf banner.hex ecalli.hex hi_banner.hex

.PHONY: all run run-jump run-banner run-ecalli clean
