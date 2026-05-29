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
# resumes the guest (pvm_fetch suspended at the post-ecalli pc; re-entry sets the
# resume bit PVM_CFG1[33]), proving PVM-mode resume-after-trap.
run-ecalli: loader.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '$(BANNER)' ecalli.hex ecalli | tee /dev/stderr | grep CODE_LEN | grep -oE '[0-9]+'); \
	echo ">> building loader with CODE_LEN=$$CL"; \
	$(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_ecalli.elf loader.S; \
	$(HARNESS) +PVM_IMG=$(abspath ecalli.hex) +tohost_addr=$(TOHOST) +time_out=400000 $(abspath loader_ecalli.elf)

# Stage 3.3b: conditional branches (backend-resolved, stall-on-branch). branch_eq
# r1,r2,+9 with r1==r2 (taken -> prints 'T') or r1!=r2 (not taken -> prints 'F').
run-branch: loader.S link.ld gen_pvm_img.py
	@python3 gen_pvm_img.py '' br_taken.hex    br_taken    >/dev/null; \
	 python3 gen_pvm_img.py '' br_nottaken.hex br_nottaken >/dev/null; \
	 $(CC) $(CFLAGS) -DCODE_LEN=21 -T link.ld -o loader_br.elf loader.S; \
	 echo ">> branch TAKEN (expect T):"; \
	 $(HARNESS) +PVM_IMG=$(abspath br_taken.hex)    +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_br.elf) | grep -aE 'SUCCESS|^T'; \
	 echo ">> branch NOT-TAKEN (expect F):"; \
	 $(HARNESS) +PVM_IMG=$(abspath br_nottaken.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_br.elf) | grep -aE 'SUCCESS|^F'

# Stage 3.3b: backward conditional branch (loop). Prints '#' N times (N=$(LOOP_N)).
LOOP_N ?= 5
run-loop: loader.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '$(LOOP_N)' loop.hex loop | grep CODE_LEN | grep -oE '[0-9]+'); \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_loop.elf loader.S; \
	 echo ">> loop N=$(LOOP_N): printing '#' x$(LOOP_N)"; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath loop.hex) +tohost_addr=$(TOHOST) +time_out=400000 $(abspath loader_loop.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; echo "   '#' count = $$(echo "$$OUT" | grep -ao '#' | wc -l)"

# Stage 3.3b: dynamic jump (jump_ind) -> djump. Halt variant: jump_ind to the r0
# halt magic (0xFFFF0000) -> clean halt -> synthetic trap -> M-mode SUCCESS.
run-djump-halt: loader.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' djhalt.hex djump_halt | grep CODE_LEN | grep -oE '[0-9]+'); \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_djhalt.elf loader.S; \
	 echo ">> jump_ind -> r0 halt magic:"; \
	 $(HARNESS) +PVM_IMG=$(abspath djhalt.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_djhalt.elf) 2>&1 | grep -aE 'SUCCESS'

# Stage 3.3b: dynamic jump through the jump table. jump_ind r2 (a=2) -> j[0]=TARGET;
# prints 'J' then traps. CFG2 (JT_BASE/JT_Z) comes from the generator's report.
run-djump-table: loader.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '' djtab.hex djump_table); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JB=$$(echo "$$G" | grep JT_BASE | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z | grep -oE '[0-9]+'); \
	 echo ">> CODE_LEN=$$CL JT_BASE=$$JB JT_Z=$$JZ"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_BASE=$$JB -DJT_Z=$$JZ -T link.ld -o loader_djtab.elf loader.S; \
	 echo ">> jump_ind through jump table (expect J):"; \
	 $(HARNESS) +PVM_IMG=$(abspath djtab.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_djtab.elf) | grep -aE 'SUCCESS|^J'

clean:
	rm -f loader.elf loader_jump.elf loader_banner.elf loader_ecalli.elf loader_br.elf loader_loop.elf loader_djhalt.elf loader_djtab.elf loader_hi.elf baseline.elf banner.hex ecalli.hex hi_banner.hex br_taken.hex br_nottaken.hex loop.hex djhalt.hex djtab.hex

.PHONY: all run run-jump run-banner run-ecalli run-branch run-loop run-djump-halt run-djump-table clean
