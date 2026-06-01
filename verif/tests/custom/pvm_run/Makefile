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

# Stage 3.3b: imm-branches (81-90), macro-expanded in the front (load scratch=imm ;
# branch_reg). branch_eq_imm r1,X,+10: X==7 (taken -> 'T') or X!=7 (not taken -> 'F').
run-ibranch: loader.S link.ld gen_pvm_img.py
	@python3 gen_pvm_img.py '' ibr_t.hex  ibr_taken    >/dev/null; \
	 python3 gen_pvm_img.py '' ibr_nt.hex ibr_nottaken >/dev/null; \
	 $(CC) $(CFLAGS) -DCODE_LEN=19 -T link.ld -o loader_ibr.elf loader.S; \
	 echo ">> imm-branch TAKEN (expect T):"; \
	 $(HARNESS) +PVM_IMG=$(abspath ibr_t.hex)  +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_ibr.elf) 2>&1 | grep -aE 'SUCCESS|^T'; \
	 echo ">> imm-branch NOT-TAKEN (expect F):"; \
	 $(HARNESS) +PVM_IMG=$(abspath ibr_nt.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_ibr.elf) 2>&1 | grep -aE 'SUCCESS|^F'

# Stage 3.3b: load_imm_jump_ind (180) -- macro-expanded (load reg_A) + dynamic jump
# (reg_B) through the jump table. Prints 'J' then traps.
run-ldij: loader.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '' ldij.hex ldij); \
	 CL=$$(echo "$$G"|grep CODE_LEN|grep -oE '[0-9]+'); JB=$$(echo "$$G"|grep JT_BASE|grep -oE '[0-9]+'); JZ=$$(echo "$$G"|grep JT_Z|grep -oE '[0-9]+'); \
	 echo ">> CODE_LEN=$$CL JT_BASE=$$JB JT_Z=$$JZ"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_BASE=$$JB -DJT_Z=$$JZ -T link.ld -o loader_ldij.elf loader.S; \
	 echo ">> load_imm_jump_ind (expect J):"; \
	 $(HARNESS) +PVM_IMG=$(abspath ldij.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_ldij.elf) 2>&1 | grep -aE 'SUCCESS|^J'

# Stage B2: privileged CSR data ops (csr_rw/csr_rs/csr_rc) through mscratch. Writes
# 0x20, sets 0x07 (->0x27), clears 0x04 (->0x23), reads back, putchars '#'. The char
# is '#' iff all three CSR ops transformed the real CSR correctly. PVM runs at M-mode
# (mscratch is M-mode + loader-unused). mret/sret/wfi/sfence_vma -> B4 (need privilege).
run-csr: loader.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' csr.hex csr | grep CODE_LEN | grep -oE '[0-9]+'); \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_csr.elf loader.S; \
	 echo ">> CSR rw/rs/rc round-trip (expect '#'):"; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath csr.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_csr.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 echo "$$OUT" | grep -qa '#' && echo "   CSR rw/rs/rc OK ('#' returned)" || { echo "   *** CSR FAILED (no '#') ***"; exit 1; }

# Stage B3: host-call ABI. The host-call number (ecalli imm) is delivered in mtval; the
# handler dispatches -- #0 = putchar(a0), #1 = sum (a0 = a0 + a1). ABI a0..a5 = PVM
# r7..r12. Program: a0=0x22, a1=0x01, ecalli #1 (a0->0x23), ecalli #0 -> putchar '#'.
# Exactly one '#' iff dispatch + 2-arg + return + resume all work (a broken dispatch
# would putchar a0 at #1 too -> '"' x2, no '#').
run-hostcall: loader.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' hostcall.hex hostcall | grep CODE_LEN | grep -oE '[0-9]+'); \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_hostcall.elf loader.S; \
	 echo ">> host-call ABI dispatch (sum #1 then putchar #0, expect '#'):"; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath hostcall.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_hostcall.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 echo "$$OUT" | grep -qa '#' && echo "   host-call ABI OK ('#' returned)" || { echo "   *** host-call ABI FAILED (no '#') ***"; exit 1; }

# M1: a PolkaVM image is loaded into img_mem at RUNTIME via the CSR_PVM_IMG load port
# (the bootrom load path; here the bytes are resident in DRAM as the loader's .text.init
# and streamed in by csrw) -- NO baked ROM, NO +PVM_IMG/$readmemh. Proves JAM code runs
# from a runtime-loaded memory: the DRAM-fetch precursor. Image: load_imm r7,'#';ecalli;trap.
run-dram: loader_dramload.S link.ld
	@$(CC) $(CFLAGS) -T link.ld -o loader_dramload.elf loader_dramload.S; \
	 echo ">> image CSR-loaded into img_mem from DRAM (no +PVM_IMG), expect '#':"; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_dramload.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 echo "$$OUT" | grep -qa '#' && echo "   M1 OK: '#' from a runtime-loaded img_mem" || { echo "   *** M1 FAILED (no '#') ***"; exit 1; }

# Run the whole PVM gate suite and tally PASS/FAIL (prereq: the testharness is built,
# `make verilate target=cv64a6_emac_polkavm RISCV=/usr` from the repo root). Each gate
# returns non-zero on failure (the SUCCESS grep / the hardened '#' asserts), so the exit
# code is the per-gate verdict.
PVM_GATES = run run-ecalli run-banner run-branch run-loop run-djump-halt run-djump-table \
            run-ibranch run-ldij run-csr run-hostcall run-dram run-dram-banner run-user run-user-dram \
            run-pvmvec run-mret run-priv
run-all:
	@pass=0; fail=0; failed=""; \
	 for t in $(PVM_GATES); do \
	   if $(MAKE) -s $$t >/dev/null 2>&1; then echo "  OK   $$t"; pass=$$((pass+1)); \
	   else echo "  FAIL $$t"; fail=$$((fail+1)); failed="$$failed $$t"; fi; \
	 done; \
	 echo "=== PVM gates: PASS=$$pass FAIL=$$fail$${failed:+ (failed:$$failed)} ==="; \
	 test $$fail -eq 0

# CSR-load the FULL banner (108B, 7 BRAM words) via CSR_PVM_IMG, no +PVM_IMG -- the sim
# mirror of the FPGA bootrom's DRAM-load path (run-dram only loads 17B). Stresses the
# byte-enable BRAM write + read-FSM at the banner's scale. Expect 'PolkaVM on CVA6!'.
run-dram-banner: loader_drambanner.S banner_blob.S link.ld
	@$(CC) $(CFLAGS) -T link.ld -o loader_drambanner.elf loader_drambanner.S; \
	 echo ">> CSR-loaded full banner (108B):"; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=400000 $(abspath loader_drambanner.elf) 2>&1); \
	 echo "$$OUT" | grep -aoE 'PolkaVM on CVA6!' | head -1; \
	 echo "$$OUT" | grep -qa 'PolkaVM on CVA6!' && echo "   CSR-load-at-scale OK" || { echo "   *** FAILED ***"; exit 1; }

# A6: run a REAL compiled PolkaVM program from DRAM (not a hand-emitted banner). Take a
# .polkavm blob, emit-image it, convert to our img_mem layout (polkavm_to_img.py), size
# the loader to its code_len, run. The example export 'add_numbers' uses the GUEST STACK
# (spills ra/s0 to [sp]/[sp+4] with sp in DRAM), arithmetic, a host-call, and ret-halt;
# it computes a0 = a0+a1+third = 10+20+12 = 42 = '*'. Exactly one '*' + SUCCESS proves
# the whole path -- the LSU 32-bit guest-address mask makes the stack land in DRAM.
POLKATOOL ?= /home/claude/pvm/polkavm/target/release/polkatool
USER_BLOB  ?= /home/claude/pvm/polkavm/guest-programs/output/example-hello-world.polkavm
run-user: loader_user.S link.ld polkavm_to_img.py
	@$(POLKATOOL) emit-image $(USER_BLOB) -o hello.img >/dev/null 2>&1; \
	 CL=$$(python3 polkavm_to_img.py hello.img hello | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> real PolkaVM program from DRAM, CODE_LEN=$$CL (expect one '*'=42):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_user.elf loader_user.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath hello.hex) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_user.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 R=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest result = $$R (expect [*])"; \
	 { [ "$$R" = "[*]" ] && echo "$$OUT" | grep -qa 'SUCCESS'; } && echo "   A6 OK: real program ran from DRAM" || { echo "   *** A6 FAILED (got '$$R') ***"; exit 1; }

# M3 (goal B): demand-fetch. Same add_numbers program, but its image is fetched from DRAM
# ON-DEMAND via the dcache (CFG1[34]=fetch_from_dram), NOT preloaded into img_bram. The
# blob lives in DRAM as the loader's .text.init data; NO +PVM_IMG. Expect "[*]" -- proving
# the JAM code is fetched live from DRAM (toward kernel-scale images beyond the 4KB BRAM).
run-user-dram: loader_userdram.S link.ld polkavm_to_img.py
	@$(POLKATOOL) emit-image $(USER_BLOB) -o hello.img >/dev/null 2>&1; \
	 CL=$$(python3 polkavm_to_img.py hello.img hello | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> M3: add_numbers fetched from DRAM via dcache (CFG1[34]), CODE_LEN=$$CL (expect [*]):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_userdram.elf loader_userdram.S; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=600000 $(abspath loader_userdram.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 R=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest result = $$R (expect [*])"; \
	 { [ "$$R" = "[*]" ] && echo "$$OUT" | grep -qa 'SUCCESS'; } && echo "   M3 OK: code fetched from DRAM on-demand" || { echo "   *** M3 FAILED (got '$$R') ***"; exit 1; }

# B4 (goal C): PVM host-boundary exit decoupled from mtvec. The guest clobbers mtvec
# (simulating OpenSBI's `csrw mtvec`), then ecalli #0 (putchar '#'). The host hook is in
# CSR_PVM_VEC, so the ecalli still reaches it -> '#'. mtvec is a decoy ('X'): '#' can only
# come via CSR_PVM_VEC. Proves OpenSBI can install its own trap vector without stealing the
# host hypervisor's ecalli/panic hook.
run-pvmvec: loader_pvmvec.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' pvmvec.hex mtvec | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> B4: guest clobbers mtvec; ecalli must reach host via CSR_PVM_VEC (expect '#', not 'X'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_pvmvec.elf loader_pvmvec.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath pvmvec.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_pvmvec.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 echo "$$OUT" | grep -qa '#' && echo "   B4 OK: ecalli host-exit decoupled from mtvec (CSR_PVM_VEC)" || { echo "   *** B4 FAILED ($$(echo "$$OUT" | grep -qa X && echo 'used mtvec -> X' || echo 'no #/X')) ***"; exit 1; }

# Phase A (mret/sret PVM-pc redirect): the guest sets mepc=<success pc L> and executes
# `mret`; the HW must REDIRECT pvm_fetch to L (not fall through to the sequential next pc,
# a DECOY that prints 'X'). The success block at L prints '#'. Privilege is M (host-set),
# so the success ecalli is a host-exit. Expect '#', never 'X'.
run-mret: loader_mret.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' mret.hex mret | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> Phase A: guest mret must redirect PVM fetch to mepc (expect '#', not 'X'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_mret.elf loader_mret.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath mret.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_mret.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 { echo "$$OUT" | grep -qa '#' && ! echo "$$OUT" | grep -qa 'X'; } && echo "   mret OK: PVM-pc redirected to mepc" || { echo "   *** mret FAILED ($$(echo "$$OUT" | grep -qa X && echo 'fell through -> X' || echo 'no #')) ***"; exit 1; }

# Phase B/C (multi-privilege round-trip = OpenSBI-on-PVM core): the guest drops M->S via
# mret, then a guest-internal ecalli@S traps to the guest's OWN mtvec while STAYING in PVM
# (not a host-boundary exit), reaching an M-mode handler that host-exits '#'. '#' proves the
# whole round-trip (mret redirect + priv->S + ecalli@S stays in PVM + redirect to guest tvec
# + priv->M). 'S' (no '#') would mean priv stayed M after mret. Expect '#', never 'S'.
run-priv: loader_priv.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' priv.hex priv | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> Phase B/C: guest M->S mret + ecalli@S guest-trap (expect '#', not 'S'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_priv.elf loader_priv.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath priv.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_priv.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   priv OK: M->S mret + ecalli@S stayed in PVM (guest trap)" || { echo "   *** priv FAILED (got '$$EMIT'; [S]=priv stayed M, ''=redirect/trap hung) ***"; exit 1; }

clean:
	rm -f loader.elf loader_jump.elf loader_banner.elf loader_ecalli.elf loader_br.elf loader_loop.elf loader_djhalt.elf loader_djtab.elf loader_ibr.elf loader_ldij.elf loader_csr.elf loader_hostcall.elf loader_dramload.elf loader_drambanner.elf loader_hi.elf baseline.elf banner.hex ecalli.hex hi_banner.hex br_taken.hex br_nottaken.hex loop.hex djhalt.hex djtab.hex ibr_t.hex ibr_nt.hex ldij.hex csr.hex hostcall.hex

.PHONY: all run run-jump run-banner run-ecalli run-branch run-loop run-djump-halt run-djump-table run-ibranch run-ldij run-csr run-hostcall run-dram run-dram-banner run-user run-user-dram run-pvmvec run-all clean
