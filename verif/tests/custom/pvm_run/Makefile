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

# CSR-immediate operand-source regression (silicon post-PTP byte-reversal derail). csrrsi
# mscratch,zimm must use the 4-bit zimm as operand, NOT a poisoned GPR. '#'(0x23)=zimm path
# correct; '`'(0x60)=GPR mis-read (the old bug that set mstatus.MBE -> ld/sd byte-reversal).
run-csri: loader.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' csri.hex csri | grep CODE_LEN | grep -oE '[0-9]+'); \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_csri.elf loader.S; \
	 echo ">> CSR-immediate zimm-operand (expect '#', bug='\`'):"; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath csri.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_csri.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 echo "$$OUT" | grep -qa '#' && echo "   CSR-immediate OK ('#' returned)" || { echo "   *** CSR-immediate FAILED (no '#') ***"; exit 1; }

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
            run-pvmvec run-mret run-handoff run-handoff-dram run-djump-dram run-handoff-smode \
            run-handoff-smode-dram run-handoff-sdyn-dram run-priv run-priv-dyn run-priv-return run-strap-skip run-handoff-skip run-trap-jt run-trap-jt-dram run-handoff-trap-jt-dram run-smode-loop run-smode-loop-jt run-smode-sbi run-storeimm
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

# Stage 1 (M->S handoff via JT-mapped eret): the guest sets mepc to a JT-ENCODED code address
# (2 = (idx0+1)*2, NOT a PVM-pc) and mret with CSR_PVM_CFG2[36]=1; the HW maps mepc through the
# jump table (like a djump) -> jumptable[0] = success block ('#'). Without the map the eret would
# use mepc[31:0]=2 directly -> a mid-instruction pc -> no '#'. Expect '#', never 'X'.
run-handoff: loader_handoff.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '' handoff.hex handoff); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JB=$$(echo "$$G" | grep JT_BASE | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z | grep -oE '[0-9]+'); \
	 echo ">> Stage 1: M->S handoff via JT-mapped eret, CODE_LEN=$$CL JT_BASE=$$JB JT_Z=$$JZ (expect '#', not 'X'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_BASE=$$JB -DJT_Z=$$JZ -T link.ld -o loader_handoff.elf loader_handoff.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath handoff.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_handoff.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 { echo "$$OUT" | grep -qa '#' && ! echo "$$OUT" | grep -qa 'X'; } && echo "   handoff OK: eret JT-mapped mepc -> success block" || { echo "   *** handoff FAILED ($$(echo "$$OUT" | grep -qa X && echo 'fell through -> X' || echo 'no #')) ***"; exit 1; }

# Stage 1 DRAM-path reproducer (the FPGA/OpenSBI fetch path): the SAME M->S handoff via JT-mapped
# eret as run-handoff, but the image is demand-fetched from DRAM (CFG1[34]) via the dcache, NOT
# preloaded into img_bram (+PVM_IMG). The BRAM run-handoff passes; this exercises the eret-via-jt
# x DRAM-demand-fetch FSM interaction (the FPGA-only wrong-target bug). IDX>0 places the live JT
# entry far from the code/bitmask lines so the JT read is a COLD cache MISS (the D_WAIT path) --
# the FPGA condition (idx=0 hot-line reads do NOT reproduce it). Expect '#', never 'X'.
IDX ?= 62
run-handoff-dram: loader_handoff_dram.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '$(IDX)' handoff_dram.hex handoff handoff_blob); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JO=$$(echo "$$G" | grep JT_OFF  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z    | grep -oE '[0-9]+'); \
	 echo ">> Stage 1 DRAM: M->S handoff via JT-mapped eret, demand-fetch (CODE_LEN=$$CL JT_OFF=$$JO JT_Z=$$JZ; expect '#', not 'X'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_OFF=$$JO -DJT_Z=$$JZ -T link.ld -o loader_handoff_dram.elf loader_handoff_dram.S; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_handoff_dram.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 { echo "$$OUT" | grep -qa '#' && ! echo "$$OUT" | grep -qa 'X'; } && echo "   handoff-dram OK: eret JT-mapped mepc -> success block (DRAM)" || { echo "   *** handoff-dram FAILED ($$(echo "$$OUT" | grep -qa X && echo 'fell through -> X' || echo 'no #')) ***"; exit 1; }

# Stage 1 DRAM-path CONTROL: a plain djump (jump_ind) through the jump table on the SAME DRAM
# demand-fetch path. The A/B partner of run-handoff-dram: same DRAM JT read, triggered by a DJUMP
# (br_resolved) not an ERET (eret_via_jt). On the FPGA DJUMP+DRAM works; this proves the DRAM JT
# read itself is sound in sim, isolating any run-handoff-dram failure to the eret sequencing.
run-djump-dram: loader_djump_dram.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '$(IDX)' djtab_dram.hex djump_table djtab_blob); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JO=$$(echo "$$G" | grep JT_OFF  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z    | grep -oE '[0-9]+'); \
	 echo ">> Stage 1 DRAM CONTROL: jump_ind through the jump table, demand-fetch (CODE_LEN=$$CL JT_OFF=$$JO JT_Z=$$JZ; expect 'J'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_OFF=$$JO -DJT_Z=$$JZ -T link.ld -o loader_djump_dram.elf loader_djump_dram.S; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_djump_dram.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 echo "$$OUT" | grep -qa 'J' && echo "   djump-dram OK: DRAM JT read sound (djump path)" || { echo "   *** djump-dram FAILED (no 'J') ***"; exit 1; }

# Stage 1 OpenSBI-handoff repro (BRAM): a JT-mapped eret that ALSO drops M->S (vs run-handoff's
# M->M). Isolates [JT-mapped eret] x [M->S priv drop] WITHOUT the DRAM path -- if this passes but
# run-handoff-smode-dram fails, the bug needs the DRAM demand-fetch; if both fail, it is the priv
# drop x JT-map itself. Guest: JT-mapped mret -> JT[0]=Ls (S-entry); ecalli@S -> guest mtvec (M)
# -> host '[#]'. Expect '[#]'; '[S]' = priv stayed M; '' = wrong JT target.
run-handoff-smode: loader_handoff_smode.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '0' hsmode.hex handoff_smode); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JB=$$(echo "$$G" | grep JT_BASE  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z     | grep -oE '[0-9]+'); \
	 echo ">> Stage 1 BRAM: M->S handoff via JT-mapped eret (CODE_LEN=$$CL JT_BASE=$$JB JT_Z=$$JZ; expect '[#]'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_BASE=$$JB -DJT_Z=$$JZ -T link.ld -o loader_handoff_smode.elf loader_handoff_smode.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath hsmode.hex) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_handoff_smode.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   handoff-smode OK: JT-mapped M->S mret round-trip (BRAM)" || { echo "   *** handoff-smode FAILED (got '$$EMIT'; [S]=priv stayed M, ''=wrong JT target/fault) ***"; exit 1; }

# Stage 1 OpenSBI-handoff repro (DRAM demand-fetch) -- the FULL FPGA condition: JT-mapped eret +
# M->S priv drop + cold-miss DRAM JT read. The exact handoff that prints '!F' on the board.
# Expect '[#]'. This is the prime reproduction target for the eret-via-jt x DRAM bug.
run-handoff-smode-dram: loader_handoff_smode_dram.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '$(IDX)' handoff_smode_dram.hex handoff_smode handoff_smode_blob); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JO=$$(echo "$$G" | grep JT_OFF  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z    | grep -oE '[0-9]+'); \
	 echo ">> Stage 1 DRAM: M->S handoff via JT-mapped eret, demand-fetch (CODE_LEN=$$CL JT_OFF=$$JO JT_Z=$$JZ; expect '[#]'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_OFF=$$JO -DJT_Z=$$JZ -T link.ld -o loader_handoff_smode_dram.elf loader_handoff_smode_dram.S; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_handoff_smode_dram.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   handoff-smode-dram OK: JT-mapped M->S mret round-trip (DRAM)" || { echo "   *** handoff-smode-dram FAILED (got '$$EMIT'; [S]=priv stayed M, ''=wrong JT target/fault) ***"; exit 1; }

# Stage 1 OpenSBI-handoff repro (DRAM, GUEST flush-write) -- the MOST faithful: the guest sets
# mstatus.MPP=S ITSELF (flush-class, B5-fenced) THEN a JT-mapped M->S mret, exactly like
# sbi_hart_switch_mode (csr_write MSTATUS; mret). Adds the one factor the other handoff repros
# omit: a guest flush-class CSR write immediately upstream of the JT-mapped eret. Expect '[#]'.
run-handoff-sdyn-dram: loader_handoff_smode_dyn_dram.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '$(IDX)' handoff_sdyn_dram.hex handoff_smode_dyn handoff_sdyn_blob); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JO=$$(echo "$$G" | grep JT_OFF  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z    | grep -oE '[0-9]+'); \
	 echo ">> Stage 1 DRAM: guest flush-write mstatus + JT-mapped M->S mret, demand-fetch (CODE_LEN=$$CL JT_OFF=$$JO JT_Z=$$JZ; expect '[#]'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_OFF=$$JO -DJT_Z=$$JZ -T link.ld -o loader_handoff_smode_dyn_dram.elf loader_handoff_smode_dyn_dram.S; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_handoff_smode_dyn_dram.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   handoff-sdyn-dram OK: guest-flush + JT-mapped M->S round-trip (DRAM)" || { echo "   *** handoff-sdyn-dram FAILED (got '$$EMIT'; [S]=priv stayed M, ''=wrong JT target/fault) ***"; exit 1; }

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

# B5 flush-safe guest CSR write: like run-priv but the GUEST sets mstatus.MPP=S ITSELF (a
# flush-class CSR write) before its mret, instead of the host pre-setting it. The guest mstatus
# write raises flush_o; B5's csr-fence stalls pvm_fetch so the write commits ALONE (the younger
# mret is not discarded) -> the round-trip still prints '[#]'. A HANG (no '[#]') means the flush
# discarded the mret -> B5 broken. This is the path a real OpenSBI takes (picks its own priv).
run-priv-dyn: loader_priv_dyn.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' priv_dyn.hex priv_dyn | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> B5: guest-driven mstatus.MPP=S (flush-class, fenced) + M->S mret round-trip (expect '#'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_priv_dyn.elf loader_priv_dyn.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath priv_dyn.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_priv_dyn.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   B5 OK: guest mstatus write fenced; mret round-trip survived the flush" || { echo "   *** B5 FAILED (got '$$EMIT'; ''=flush discarded the mret -> pvm_fetch hung) ***"; exit 1; }

# B6 handler-return: prove a guest M-handler can `mret` BACK to the trapped S-guest (the
# enter->serve->return trap cycle a real SBI handler needs), not just host-exit. Two-vector
# scheme: the 1st M-handler RE-POINTS mtvec then mret-returns to S (mstatus.MPP still S, NO
# host-exit before the mret); a 2nd guest-trap@S then reaches the (re-pointed) exit handler
# that host-exits '#'. '[#]' is reachable ONLY if the handler-return mret returned to S at the
# right PVM-pc. Expect '[#]'; '' (no frame) = the return mret fell through / wrong priv/pc.
run-priv-return: loader_priv.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' priv_return.hex priv_return | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> B6: guest M-handler mret-RETURNS to S, 2nd trap -> re-pointed handler host-exits (expect '#'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_priv_return.elf loader_priv.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath priv_return.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_priv_return.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   B6 OK: M-handler mret returned to S; full enter->serve->return cycle" || { echo "   *** B6 FAILED (got '$$EMIT'; ''=handler-return mret fell through / wrong priv/pc) ***"; exit 1; }

# Stage 2 skip-class trap-return: an ecalli@S (SBI call) must return to the instruction AFTER the
# 2-byte ecalli when the guest M-handler does the STANDARD RISC-V `mepc += 4; mret` (sbi_ecall.c:165).
# HW biases the guest-ecalli trap-capture by -4 (mepc <- next_pc(ecalli)-4) so the unmodified +4 lands
# right. The handler does a faithful csrr/add4/csrw mepc (NOT a const write), and the success path's
# 2nd ecalli sits EXACTLY at the skip-target -- a 2-byte mis-land hits a DECOY trap and emits no '#'.
# Expect '[#]'; '' = the +4 overshot (bias missing/wrong) -> landed on the decoy.
run-strap-skip: loader_priv.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' strap_skip.hex strap_skip | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> Stage 2: ecalli@S skip-return via guest mepc+=4;mret lands after the 2B ecalli (expect '#'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_strap_skip.elf loader_priv.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath strap_skip.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_strap_skip.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   stage2 OK: guest mepc+=4 landed on the instruction after the ecalli (-4 bias)" || { echo "   *** stage2 FAILED (got '$$EMIT'; ''=mepc+=4 overshot the 2B ecalli -> hit the decoy) ***"; exit 1; }

# Stage 1 + Stage 2 COMBINED (the real OpenSBI config): CFG2[36] is set sticky (like loader_opensbi.S),
# so the eret-via-JT one-shot MUST JT-map the M->S handoff then SELF-CLEAR, so the subsequent ecalli@S
# skip-return (raw-pc mepc, +4) takes the DIRECT path instead of being JT-mangled. Reuses
# loader_handoff_smode.S (MPP=S + CFG2[36]=1 + JT). Expect '[#]'; '' = the skip-return was JT-mapped
# (one-shot self-clear broken) or the -4 bias is wrong. This is the gate the run-strap-skip gate
# (CFG2=0) could NOT cover -- it exercises the Stage-1/Stage-2 interaction the architect flagged.
run-handoff-skip: loader_handoff_smode.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '0' hskip.hex handoff_skip); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JB=$$(echo "$$G" | grep JT_BASE  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z     | grep -oE '[0-9]+'); \
	 echo ">> Stage 1+2: one-shot CFG2[36] JT-maps the handoff then self-clears -> ecalli@S skip-return is DIRECT (expect '#'):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_BASE=$$JB -DJT_Z=$$JZ -T link.ld -o loader_handoff_skip.elf loader_handoff_smode.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath hskip.hex) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_handoff_skip.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   handoff-skip OK: CFG2[36] one-shot (JT handoff -> self-clear -> DIRECT skip-return)" || { echo "   *** handoff-skip FAILED (got '$$EMIT'; ''=skip-return JT-mangled -> one-shot broken, or -4 bias wrong) ***"; exit 1; }

# trap-via-JT (CSR_PVM_CFG2[37]): the EXACT mirror of run-handoff (eret-via-JT/CFG2[36]) for the TRAP
# vector. Real OpenSBI sets mtvec via `lla _trap_handler; csrw mtvec`; in PVM `lla` yields a jump-table
# TOKEN, so a guest-internal ecalli@S would trap to the raw token (garbage). With CFG2[37]=1 the
# guest-trap redirect maps mtvec (a JT token) THROUGH the jump table -> JT[idx]=the M-handler PVM-pc.
# Guest (emit_trap_jt): host pre-sets MPP=S; a NORMAL raw-pc entry mret (CFG2[36]=0) drops M->S at Ls;
# at Ls an ecalli@S traps to mtvec=token, JT-mapped -> JT[0]=Lh -> host putchars '[#]'. The POSITIVE
# build sets CFG2[37]=1 (-DCFG2_TRAP_JT) -> expect '[#]'. The NEGATIVE control clears it (-UCFG2_TRAP_JT)
# -> the token is used RAW -> a mid-instruction pc -> NO '[#]' (proves the gate discriminates: '[#]' can
# come ONLY via the JT map). Reuses loader_trap_jt.S (CFG2[37] gated by the define).
run-trap-jt: loader_trap_jt.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '0' trapjt.hex trap_jt); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JB=$$(echo "$$G" | grep JT_BASE  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z     | grep -oE '[0-9]+'); \
	 echo ">> trap-via-JT (CFG2[37]): ecalli@S traps to a JT-token mtvec, JT-mapped to the handler (CODE_LEN=$$CL JT_BASE=$$JB JT_Z=$$JZ; expect '[#]'):"; \
	 $(CC) $(CFLAGS) -DCFG2_TRAP_JT -DCODE_LEN=$$CL -DJT_BASE=$$JB -DJT_Z=$$JZ -T link.ld -o loader_trap_jt.elf loader_trap_jt.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath trapjt.hex) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_trap_jt.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted (CFG2[37]=1) = $$EMIT (expect [#])"; \
	 echo "   -- negative control (CFG2[37]=0): the JT-token mtvec is used RAW -> expect NO [#] --"; \
	 $(CC) $(CFLAGS) -UCFG2_TRAP_JT -DCODE_LEN=$$CL -DJT_BASE=$$JB -DJT_Z=$$JZ -T link.ld -o loader_trap_jt_neg.elf loader_trap_jt.S; \
	 OUTN=$$($(HARNESS) +PVM_IMG=$(abspath trapjt.hex) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_trap_jt_neg.elf) 2>&1); \
	 EMITN=$$(echo "$$OUTN" | grep -aoE '\[.\]' | head -1); echo "   negative-control emitted (CFG2[37]=0) = '$$EMITN' (expect NOT [#])"; \
	 { [ "$$EMIT" = "[#]" ] && [ "$$EMITN" != "[#]" ]; } && echo "   trap-jt OK: CFG2[37] JT-maps the trap vector (pos=[#]); raw-mtvec control did NOT reach the handler" || { echo "   *** trap-jt FAILED (pos='$$EMIT' expect [#]; neg='$$EMITN' must NOT be [#]) ***"; exit 1; }

# trap-via-JT DRAM-path reproducer (the FPGA/OpenSBI fetch path) -- the EXACT mirror of
# run-handoff-smode-dram (which tests eret-via-JT/CFG2[36] on the DRAM demand-fetch path) but for
# the TRAP vector (CFG2[37]). The SAME trap-via-JT scenario as run-trap-jt, but the image is
# demand-fetched from DRAM (CFG1[34]) via the dcache, NOT preloaded into img_bram (+PVM_IMG). The
# BRAM run-trap-jt passes; this exercises the trap-via-jt x DRAM-demand-fetch M3 FSM interaction
# (the FPGA-only failure where the ecalli@S trap never reaches the JT-mapped handler). IDX>0 places
# the live JT entry far from the code/bitmask lines so the trap's JT read is a COLD cache MISS (the
# D_WAIT path) -- the FPGA condition (idx=0 hot-line reads do NOT reproduce it). The POSITIVE build
# sets CFG2[37]=1 (-DCFG2_TRAP_JT) -> expect '[#]'. The NEGATIVE control clears it -> the token is
# used RAW -> a mid-instruction pc -> NO '[#]'. Reuses loader_trap_jt_dram.S (CFG2[37] gated).
run-trap-jt-dram: loader_trap_jt_dram.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '$(IDX)' trapjt_dram.hex trap_jt trap_jt_blob); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JO=$$(echo "$$G" | grep JT_OFF  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z    | grep -oE '[0-9]+'); \
	 echo ">> trap-via-JT DRAM: ecalli@S traps to a JT-token mtvec, JT-mapped (cold-miss) to the handler (CODE_LEN=$$CL JT_OFF=$$JO JT_Z=$$JZ; expect '[#]'):"; \
	 $(CC) $(CFLAGS) -DCFG2_TRAP_JT -DCODE_LEN=$$CL -DJT_OFF=$$JO -DJT_Z=$$JZ -T link.ld -o loader_trap_jt_dram.elf loader_trap_jt_dram.S; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_trap_jt_dram.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted (CFG2[37]=1) = $$EMIT (expect [#])"; \
	 echo "   -- negative control (CFG2[37]=0): the JT-token mtvec is used RAW -> expect NO [#] --"; \
	 $(CC) $(CFLAGS) -UCFG2_TRAP_JT -DCODE_LEN=$$CL -DJT_OFF=$$JO -DJT_Z=$$JZ -T link.ld -o loader_trap_jt_dram_neg.elf loader_trap_jt_dram.S; \
	 OUTN=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_trap_jt_dram_neg.elf) 2>&1); \
	 EMITN=$$(echo "$$OUTN" | grep -aoE '\[.\]' | head -1); echo "   negative-control emitted (CFG2[37]=0) = '$$EMITN' (expect NOT [#])"; \
	 { [ "$$EMIT" = "[#]" ] && [ "$$EMITN" != "[#]" ]; } && echo "   trap-jt-dram OK: CFG2[37] JT-maps the trap vector on the DRAM cold-miss path (pos=[#]); raw-mtvec control did NOT reach the handler" || { echo "   *** trap-jt-dram FAILED (pos='$$EMIT' expect [#]; neg='$$EMITN' must NOT be [#]) ***"; exit 1; }

# COMBINED eret-via-JT + trap-via-JT, DRAM demand-fetch -- the UNTESTED real-OpenSBI SEQUENCE.
# run-handoff-smode-dram tests eret-via-JT (CFG2[36]) alone; run-trap-jt-dram tests trap-via-JT
# (CFG2[37]) alone but from a RAW M->S entry (CFG2[36]=0 from the start). NEITHER ran the actual
# OpenSBI order: a JT-mapped M->S handoff eret that CONSUMES CFG2[36] (the one-shot), THEN an
# ecalli@S that must still trap-via-JT (CFG2[37] stays 1). The loader sets BOTH bits ((3<<36),
# exactly loader_opensbi.S `li t1,(3<<36)`); the handoff consumes [36], [37] persists, so the
# SECOND JT-map (the trap) runs with the shared JT-FSM state (djump_a_q/jt_req_q/jt_valid_q/
# djump_pending/d_state_q) the FIRST (the consumed eret) left behind -- the precise interaction
# run-trap-jt-dram skipped. HTJ_IDX places BOTH live JT entries deep in DRAM (cold-miss); the trap
# entry is HTJ_IDX+2 (a DIFFERENT cold-miss line than the eret entry). Both tokens must be <=127
# (1-byte load_imm), so HTJ_IDX<=60. POSITIVE (-DCFG2_TRAP_JT): expect '[#]' (both maps fired in
# sequence). NEGATIVE control (-UCFG2_TRAP_JT): the handoff eret-via-JT still drops to S, but the
# ecalli@S's JT-token mtvec is used RAW -> mid-instruction pc -> NO '#' (proves the [37] gate atop
# the full handoff). '' / non-[#] in the POSITIVE build = the trap-via-JT did NOT engage / mis-mapped
# after the eret-via-JT consume (the FPGA failure). Reuses loader_handoff_trap_jt_dram.S.
# HTJ_IDX=eret JT index (trap entry is +2); HTJ_Z=JT entry size. Default Z=3 == the real OpenSBI
# emit-image (loader_opensbi.S JT_Z=3); idx=60 -> both entries deep in DRAM (cold-miss), distinct lines.
HTJ_IDX ?= 60
HTJ_Z   ?= 3
run-handoff-trap-jt-dram: loader_handoff_trap_jt_dram.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '$(HTJ_IDX),$(HTJ_Z)' handoff_trap_jt_dram.hex handoff_trap_jt handoff_trap_jt_blob); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JO=$$(echo "$$G" | grep JT_OFF  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z    | grep -oE '[0-9]+'); \
	 echo ">> COMBINED eret-via-JT(CFG2[36],consumed) THEN trap-via-JT(CFG2[37]) on DRAM cold-miss (CODE_LEN=$$CL JT_OFF=$$JO JT_Z=$$JZ HTJ_IDX=$(HTJ_IDX); expect '[#]'):"; \
	 $(CC) $(CFLAGS) -DCFG2_TRAP_JT -DCODE_LEN=$$CL -DJT_OFF=$$JO -DJT_Z=$$JZ -T link.ld -o loader_handoff_trap_jt_dram.elf loader_handoff_trap_jt_dram.S; \
	 OUT=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_handoff_trap_jt_dram.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted (CFG2[36+37]=1) = $$EMIT (expect [#])"; \
	 echo "   -- negative control (CFG2[37]=0, CFG2[36]=1): handoff still JT-maps to S, but the ecalli@S JT-token mtvec is RAW -> expect NO [#] --"; \
	 $(CC) $(CFLAGS) -UCFG2_TRAP_JT -DCODE_LEN=$$CL -DJT_OFF=$$JO -DJT_Z=$$JZ -T link.ld -o loader_handoff_trap_jt_dram_neg.elf loader_handoff_trap_jt_dram.S; \
	 OUTN=$$($(HARNESS) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_handoff_trap_jt_dram_neg.elf) 2>&1); \
	 EMITN=$$(echo "$$OUTN" | grep -aoE '\[.\]' | head -1); echo "   negative-control emitted (CFG2[37]=0) = '$$EMITN' (expect NOT [#])"; \
	 { [ "$$EMIT" = "[#]" ] && [ "$$EMITN" != "[#]" ]; } && echo "   handoff-trap-jt-dram OK: eret-via-JT consume THEN trap-via-JT both fired in sequence (pos=[#]); raw-mtvec control did NOT reach the handler" || { echo "   *** handoff-trap-jt-dram FAILED (pos='$$EMIT' expect [#] -> trap-via-JT did NOT engage after the eret-via-JT consume; neg='$$EMITN' must NOT be [#]) ***"; exit 1; }

# Stage 3 (re-scoped): a REAL S-mode payload -- an S-mode LOOP making N SBI-putchar ecalli@S calls,
# each round-tripping through ONE reusable guest M-handler (putchar via direct UART MMIO, like
# OpenSBI's M-mode console, THEN the standard skip-return mepc+=4; mret). Unlike run-strap-skip /
# run-handoff-skip (a SINGLE synthetic round-trip), it keeps LIVE S-state -- the loop counter (r1)
# and the char (r7) -- across EVERY trap (the handler WRITES only r3/r4/r5/r6, READS r7/r8), so it proves
# register preservation across S->M->S + repeated skip-returns + guest-M-handler MMIO via the S-trap
# path. Expect the sequential string 'ABCDE' (n=5); a clobbered counter/char -> truncated/garbled
# output, a mis-landed skip-return -> hang. HOST pre-sets MPP=S (loader_priv.S, CFG2=0).
SMODE_LOOP_N ?= 5
run-smode-loop: loader_priv.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '$(SMODE_LOOP_N)' smloop.hex smode_loop | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> Stage 3: real S-mode payload, $(SMODE_LOOP_N) SBI-putchar round-trips in a loop (expect exactly the first $(SMODE_LOOP_N) letters):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_smode_loop.elf loader_priv.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath smloop.hex) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_smode_loop.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EXP=$$(python3 -c "import sys;n=int(sys.argv[1]);print(''.join(chr(65+i) for i in range(n)))" $(SMODE_LOOP_N)); \
	 NX=$$(python3 -c "import sys;n=int(sys.argv[1]);print(''.join(chr(65+i) for i in range(n+1)))" $(SMODE_LOOP_N)); \
	 FLAT=$$(echo "$$OUT" | tr -d '\r\n'); \
	 EMIT=$$(echo "$$FLAT" | grep -aoF "$$EXP" | head -1); OVER=$$(echo "$$FLAT" | grep -aoF "$$NX" | head -1); \
	 echo "   guest emitted = '$$EMIT' (expect exactly $$EXP, and NOT the over-run $$NX)"; \
	 { [ "$$EMIT" = "$$EXP" ] && [ -z "$$OVER" ]; } && echo "   smode-loop OK: $(SMODE_LOOP_N) S->M->S round-trips, counter (r1) + char (r7) survived every trap" || { echo "   *** smode-loop FAILED (EMIT='$$EMIT' OVER='$$OVER'; ''/short=counter|char clobbered or skip-return mis-land; over-run=counter clobbered LONGER) ***"; exit 1; }

# Stage 3 (real-OpenSBI config): the SAME real S-mode loop as run-smode-loop, but the M->S handoff
# is JT-mapped under a STICKY CFG2[36]=1 (loader_handoff_smode.S, exactly like loader_opensbi.S). The
# eret-via-JT one-shot must consume CFG2[36] on the handoff mret so all N subsequent skip-return mrets
# are DIRECT. run-handoff-skip proved ONE skip-return after the handoff; this proves the one-shot
# stays consumed across N (=5) erets in a loop. Expect 'ABCDE'; ''/truncated = a later skip-return
# got JT-mangled (one-shot re-armed) or S-state was clobbered.
run-smode-loop-jt: loader_handoff_smode.S link.ld gen_pvm_img.py
	@G=$$(python3 gen_pvm_img.py '0' smloopjt.hex smode_loop_jt); \
	 CL=$$(echo "$$G" | grep CODE_LEN | grep -oE '[0-9]+'); \
	 JB=$$(echo "$$G" | grep JT_BASE  | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep JT_Z     | grep -oE '[0-9]+'); \
	 echo ">> Stage 3 (real-OpenSBI CFG2[36]): JT-mapped handoff -> one-shot self-clear -> 5 DIRECT skip-returns in a loop (expect exactly ABCDE); n is pinned at 5 in the generator:"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_BASE=$$JB -DJT_Z=$$JZ -T link.ld -o loader_smode_loop_jt.elf loader_handoff_smode.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath smloopjt.hex) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_smode_loop_jt.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 FLAT=$$(echo "$$OUT" | tr -d '\r\n'); \
	 EMIT=$$(echo "$$FLAT" | grep -aoF 'ABCDE' | head -1); OVER=$$(echo "$$FLAT" | grep -aoF 'ABCDEF' | head -1); \
	 echo "   guest emitted = '$$EMIT' (expect exactly ABCDE, and NOT the over-run ABCDEF)"; \
	 { [ "$$EMIT" = "ABCDE" ] && [ -z "$$OVER" ]; } && echo "   smode-loop-jt OK: CFG2[36] one-shot held across 5 erets; counter+char survived" || { echo "   *** smode-loop-jt FAILED (EMIT='$$EMIT' OVER='$$OVER'; a post-handoff skip-return JT-mangled, or S-state clobbered) ***"; exit 1; }

# B7 Phase-A: prove the REAL OpenSBI SBI-dispatch HW path cheaply (no ~30-min full-OpenSBI run). Same
# S-mode SBI-putchar loop as run-smode-loop, but the guest M-handler does OpenSBI-style CAUSE DISPATCH --
# it services (putchar + skip-return) ONLY if mcause==ENV_CALL_SMODE(9), else a DECOY trap (no output).
# A pass ('ABCDE') empirically confirms an ecalli@S presents mcause=ENV_CALL_SMODE to the guest mtvec
# (cva6.sv:772-775) -- exactly what OpenSBI's sbi_trap_handler keys on to route an SBI call to sbi_ecall.
# '' = the cause was wrong (every iteration hit the decoy).
SMODE_SBI_N ?= 5
run-smode-sbi: loader_priv.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '$(SMODE_SBI_N)' smsbi.hex smode_sbi | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> B7 Phase-A: ecalli@S dispatched as ENV_CALL_SMODE by an OpenSBI-style handler (expect first $(SMODE_SBI_N) letters):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_smode_sbi.elf loader_priv.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath smsbi.hex) +tohost_addr=$(TOHOST) +time_out=300000 $(abspath loader_smode_sbi.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EXP=$$(python3 -c "import sys;n=int(sys.argv[1]);print(''.join(chr(65+i) for i in range(n)))" $(SMODE_SBI_N)); \
	 NX=$$(python3 -c "import sys;n=int(sys.argv[1]);print(''.join(chr(65+i) for i in range(n+1)))" $(SMODE_SBI_N)); \
	 FLAT=$$(echo "$$OUT" | tr -d '\r\n'); \
	 EMIT=$$(echo "$$FLAT" | grep -aoF "$$EXP" | head -1); OVER=$$(echo "$$FLAT" | grep -aoF "$$NX" | head -1); \
	 echo "   guest emitted = '$$EMIT' (expect exactly $$EXP, and NOT $$NX)"; \
	 { [ "$$EMIT" = "$$EXP" ] && [ -z "$$OVER" ]; } && echo "   smode-sbi OK: ecalli@S -> mcause=ENV_CALL_SMODE dispatched, serviced, skip-returned x$(SMODE_SBI_N)" || { echo "   *** smode-sbi FAILED (EMIT='$$EMIT' OVER='$$OVER'; ''=mcause!=9 -> decoy every iter => HW cause wrong for the OpenSBI SBI dispatch) ***"; exit 1; }

# store_imm RTL bug gate: a PVM store_imm of a >16-bit immediate (low 16 bits ZERO, e.g.
# 0x230000) to a NON-ZERO offset must store the FULL value, not just the low 16 bits.
# Mirrors polkatool folding `li a5,0x10000; sd a5,off(base)` into store_imm_u64. The guest
# does store_imm_ind_u64 [r1+8] and store_imm_u32 [imm], loads each back, shifts right 16,
# ANDs the two 0x23 results, and host-call putchars it framed as "[a0]". '[#]' iff BOTH
# full-width stores kept their high bits; '[ ]'/no-# iff the macro dropped bits above 16.
run-storeimm: loader_storeimm.S link.ld gen_pvm_img.py
	@CL=$$(python3 gen_pvm_img.py '' storeimm.hex storeimm | grep CODE_LEN | grep -oE '[0-9]+'); \
	 echo ">> store_imm >16-bit immediate to a non-zero offset (expect '#', not NUL):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -T link.ld -o loader_storeimm.elf loader_storeimm.S; \
	 OUT=$$($(HARNESS) +PVM_IMG=$(abspath storeimm.hex) +tohost_addr=$(TOHOST) +time_out=200000 $(abspath loader_storeimm.elf) 2>&1); \
	 echo "$$OUT" | grep -aE 'SUCCESS'; \
	 EMIT=$$(echo "$$OUT" | grep -aoE '\[.\]' | head -1); echo "   guest emitted = $$EMIT (expect [#])"; \
	 { [ "$$EMIT" = "[#]" ]; } && echo "   store_imm OK: full-width immediate stored at a non-zero offset" || { echo "   *** store_imm FAILED (got '$$EMIT'; high bits of the store value were dropped -> stored 0) ***"; exit 1; }

# B7 step-1: boot a REAL OpenSBI build as a PVM/JAM guest from DRAM (M3 demand-fetch).
# opensbi_to_dram.py splits the 125 KB emit-image (fw_payload.bin) into code+bitmask / jt /
# ro / rw binary blobs; link_opensbi.ld pins them at the DRAM addresses the aperture
# (CSR_PVM_RAM ram_base=0x80000000, window [0x10000,0x40000)) + CFG0/CFG2 expect. The
# loader enters PVM; OpenSBI's _start runs its first store (relocated into DRAM), boot
# lottery, bss-zero, mtvec/mstatus CSRs, sp setup, then C console init. SUCCESS = the first
# mock_uart byte. If none, the commit trace (trace_rvfi_hart_00.dasm) localizes the first
# fault: its PVM-pc, priv level, and (for a load/store) the faulting data address.
OPENSBI_IMG ?= /home/claude/pvm/cva6-sdk/install64e_genesys2/fw_payload.bin
# libfdt init is correct-but-slow (O(nodes x drivers), re-decodes the BE header each call);
# raise the cycle budget so OpenSBI clears FDT-parse + CPU-enumeration and reaches the console.
OPENSBI_TIMEOUT ?= 400000000
# wall-clock cap (s) for the run-opensbi harness invocation; raise for big cycle budgets
# (the banner is ~600M+ cycles ≈ tens of minutes of Verilator wall-clock).
OPENSBI_WALLCLOCK ?= 1800
# In-aperture DTB (memory@10000 + reserve in [0x10000,0xd0000)); staged at guest 0x90000 ==
# the rebuilt OpenSBI's FW_PAYLOAD_FDT_OFFSET (what fdt_get_address()==next_arg1 parses).
OPENSBI_DTS ?= cv64a6_pvm_inaperture.dts
OPENSBI_DTB ?= cv64a6_pvm_inaperture.dtb
run-opensbi: loader_opensbi.S link_opensbi.ld opensbi_to_dram.py $(OPENSBI_DTS)
	@dtc -I dts -O dtb -o $(OPENSBI_DTB) $(OPENSBI_DTS) 2>/dev/null; \
	 G=$$(python3 opensbi_to_dram.py $(OPENSBI_IMG) opensbi); \
	 CL=$$(echo "$$G" | grep '^CODE_LEN' | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep '^JT_Z' | grep -oE '[0-9]+'); \
	 echo ">> B7: real OpenSBI as a PVM guest from DRAM (CODE_LEN=$$CL JT_Z=$$JZ):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_Z=$$JZ -DDTB_PATH='"$(OPENSBI_DTB)"' -T link_opensbi.ld -o loader_opensbi.elf loader_opensbi.S; \
	 OUT=$$(timeout $(OPENSBI_WALLCLOCK) $(HARNESS) +tohost_addr=$(TOHOST) +time_out=$(OPENSBI_TIMEOUT) $(abspath loader_opensbi.elf) 2>&1); \
	 PVMPC=$$(grep -E '^core   0: 0x0000000000[0-9a-f]+ ' trace_rvfi_hart_00.dasm | grep -oE '0x0000000000[0-9a-f]+' | sort -u | tail -1); \
	 NC=$$(grep -cE '^core   0: 0x0000000000[0-9a-f]+ ' trace_rvfi_hart_00.dasm); \
	 echo "=== PVM guest committed $$NC instructions; max PVM-pc = $$PVMPC ==="; \
	 echo "=== first PVM fault (non-breakpoint exception): ==="; \
	 C1=$$(grep -n 'bc129073' trace_rvfi_hart_00.dasm | head -1 | cut -d: -f1); \
	 awk -v s="$$C1" 'NR>s && /exception/ && !/BREAKPOINT/ {print; exit}' trace_rvfi_hart_00.dasm; \
	 echo "=== guest UART output (mock_uart \$$write -- the OpenSBI banner if it printed; '!F' = the loader trap-fault marker): ==="; \
	 echo "$$OUT" | grep -avE 'FAILED|JTAG|Listening|CPU time|Wall clock|emulator' | grep -aiE 'OpenSBI|Copyright|Platform Name|Boot HART|Firmware Base|cva6-bare|!F' | head -20 || true; \
	 echo "=== UART MMIO accesses (phys 0x10000000; >0 => console driver reached the UART): ==="; \
	 grep -cE 'mem 0x0000000010000[0-9a-f]+' trace_rvfi_hart_00.dasm || true

# U-Boot-on-PVM standalone run: boot the real uboot.polkavm as a PVM/JAM guest from DRAM
# (M3 demand-fetch) at M-mode, to empirically surface its FIRST runtime wall. Unlike
# run-opensbi (fw_payload.bin is already emit-image'd), uboot.polkavm is a linked .polkavm
# blob -> emit-image here first, then split (opensbi_to_dram.py is the generic PVMI splitter).
# U-Boot data: ro@guest 0x10000, rw@guest 0x40000 (aperture); sp/gd @ 0x80200000/0x801f7ed0
# (LSU pass-through -> already-in-DRAM). RW_IMG/RW_TOTAL drive the loader's bss-zero range.
POLKATOOL       ?= /home/claude/pvm/polkavm/target/release/polkatool
UBOOT_POLKAVM   ?= /home/claude/pvm/cva6-sdk/install64e_genesys2/uboot.polkavm
# bounded: an early memory-model/opcode fault halts via tohost long before this; raise to
# chase a deeper frontier once the first walls clear.
UBOOT_TIMEOUT   ?= 20000000
UBOOT_WALLCLOCK ?= 900
UBOOT_DTB       ?= /home/claude/pvm/cva6-sdk/configs/genesys2/cv64a6_emac_sv39.dtb
run-uboot: loader_uboot.S link_uboot.ld opensbi_to_dram.py
	@$(POLKATOOL) emit-image -o uboot.bin $(UBOOT_POLKAVM) >/dev/null 2>&1; \
	 G=$$(python3 opensbi_to_dram.py uboot.bin uboot); \
	 CL=$$(echo "$$G" | grep '^CODE_LEN' | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep '^JT_Z' | grep -oE '[0-9]+'); \
	 RWI=$$(echo "$$G" | grep '^RW_IMG' | grep -oE '[0-9]+'); \
	 RWT=$$(echo "$$G" | grep '^RW_TOTAL' | grep -oE '[0-9]+'); \
	 EP=$$(echo "$$G" | grep '^ENTRY_PC' | grep -oE '[0-9]+'); \
	 echo ">> U-Boot as a PVM guest from DRAM (CODE_LEN=$$CL JT_Z=$$JZ RW_IMG=$$RWI RW_TOTAL=$$RWT ENTRY_PC=$$EP):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_Z=$$JZ -DRW_IMG=$$RWI -DRW_TOTAL=$$RWT -DDTB_PATH='"$(UBOOT_DTB)"' -T link_uboot.ld -o loader_uboot.elf loader_uboot.S; \
	 OUT=$$(timeout $(UBOOT_WALLCLOCK) $(HARNESS) +tohost_addr=$(TOHOST) +time_out=$(UBOOT_TIMEOUT) $(abspath loader_uboot.elf) 2>&1); \
	 PVMPC=$$(grep -E '^core   0: 0x0000000000[0-9a-f]+ ' trace_rvfi_hart_00.dasm | grep -oE '0x0000000000[0-9a-f]+' | sort -u | tail -1); \
	 NC=$$(grep -cE '^core   0: 0x0000000000[0-9a-f]+ ' trace_rvfi_hart_00.dasm); \
	 echo "=== PVM guest committed $$NC instructions; max PVM-pc = $$PVMPC ==="; \
	 echo "=== first PVM fault (non-breakpoint exception) after PVM entry: ==="; \
	 C1=$$(grep -n 'bc129073' trace_rvfi_hart_00.dasm | head -1 | cut -d: -f1); \
	 awk -v s="$$C1" 'NR>s && /exception/ && !/BREAKPOINT/ {print; exit}' trace_rvfi_hart_00.dasm; \
	 echo "=== guest UART output ('!F' = loader trap-fault marker; any U-Boot text = console reached): ==="; \
	 echo "$$OUT" | grep -avE 'FAILED|JTAG|Listening|CPU time|Wall clock|emulator' | grep -aiE 'U-Boot|uboot|!F|reset|DRAM|Hit any' | head -20 || true; \
	 echo "=== UART MMIO accesses (phys 0x10000000; >0 => console driver reached): ==="; \
	 grep -cE 'mem 0x0000000010000[0-9a-f]+' trace_rvfi_hart_00.dasm || true

# NOMMU-Linux-kernel-on-PVM standalone run: boot the real vmlinux.polkavm (polkatool link
# --opt-level 0) as a PVM/JAM guest from DRAM (M3 demand-fetch) at M-mode (the kernel is NOMMU
# CONFIG_RISCV_M_MODE), to surface its FIRST runtime wall via the commit trace. Mirror of run-uboot.
# Kernel data: ro@guest 0x10000, rw@guest 0xF0000 (aperture [0x10000,0x200000)=2MB); code@0x80200000
# jt@0x80700000 (ABOVE the aperture so the kernel's ~2MB data never collides with the 4.6MB code).
# First probe: 2M-instr cap finds an early wall fast with a compact trace; raise KERNEL_TIMEOUT to
# chase a deeper frontier once the first walls clear.
KERNEL_POLKAVM   ?= /tmp/vmlinux_k.polkavm
KERNEL_TIMEOUT   ?= 2000000
KERNEL_WALLCLOCK ?= 900
# Unified-low-base DTB (memory@10000, size 8 MiB): makes phys_ram_base/ARCH_PFN_OFFSET match the
# LOW guest addresses where polkatool actually places the kernel's static data (NOMMU virt==phys),
# which the FLATMEM mem_map then covers -> fixes the kmem_cache size=192 -EINVAL SLAB panic. Must be
# paired with loader_kernel.S's 8 MiB aperture [0x10000,0x810000) + blobs relocated to 0x80820000+.
KERNEL_DTB       ?= kernel_lowbase.dtb
run-kernel: loader_kernel.S link_kernel.ld opensbi_to_dram.py
	@$(POLKATOOL) emit-image -o kernel.bin $(KERNEL_POLKAVM) >/dev/null 2>&1; \
	 G=$$(python3 opensbi_to_dram.py kernel.bin kernel); \
	 CL=$$(echo "$$G" | grep '^CODE_LEN' | grep -oE '[0-9]+'); \
	 JZ=$$(echo "$$G" | grep '^JT_Z' | grep -oE '[0-9]+'); \
	 RWI=$$(echo "$$G" | grep '^RW_IMG' | grep -oE '[0-9]+'); \
	 RWT=$$(echo "$$G" | grep '^RW_TOTAL' | grep -oE '[0-9]+'); \
	 RWB=$$(echo "$$G" | grep '^RW_BASE' | grep -oE '[0-9]+'); \
	 RWV=$$(echo "$$G" | grep '^RW_VMA' | grep -oE '0x[0-9a-f]+'); \
	 EP=$$(echo "$$G" | grep '^ENTRY_PC' | grep -oE '[0-9]+'); \
	 echo ">> NOMMU Linux kernel as a PVM guest from DRAM (CODE_LEN=$$CL JT_Z=$$JZ RW_IMG=$$RWI RW_TOTAL=$$RWT RW_BASE=$$RWB ENTRY_PC=$$EP):"; \
	 $(CC) $(CFLAGS) -DCODE_LEN=$$CL -DJT_Z=$$JZ -DRW_IMG=$$RWI -DRW_TOTAL=$$RWT -DRW_GUEST=$$RWB -Wl,--defsym,RW_VMA=$$RWV -DDTB_PATH='"$(KERNEL_DTB)"' -T link_kernel.ld -o loader_kernel.elf loader_kernel.S; \
	 OUT=$$(timeout $(KERNEL_WALLCLOCK) $(HARNESS) +tohost_addr=$(TOHOST) +time_out=$(KERNEL_TIMEOUT) $(abspath loader_kernel.elf) 2>&1); \
	 PVMPC=$$(grep -E '^core   0: 0x0000000000[0-9a-f]+ ' trace_rvfi_hart_00.dasm | grep -oE '0x0000000000[0-9a-f]+' | sort -u | tail -1); \
	 NC=$$(grep -cE '^core   0: 0x0000000000[0-9a-f]+ ' trace_rvfi_hart_00.dasm); \
	 echo "=== PVM guest committed $$NC instructions; max PVM-pc = $$PVMPC ==="; \
	 echo "=== first PVM fault (non-breakpoint exception) after PVM entry: ==="; \
	 C1=$$(grep -n 'bc129073' trace_rvfi_hart_00.dasm | head -1 | cut -d: -f1); \
	 awk -v s="$$C1" 'NR>s && /exception/ && !/BREAKPOINT/ {print; exit}' trace_rvfi_hart_00.dasm; \
	 echo "=== guest UART output ('!F' = loader trap-fault marker; any kernel text = console reached): ==="; \
	 echo "$$OUT" | grep -avE 'FAILED|JTAG|Listening|CPU time|Wall clock|emulator' | grep -aiE 'Linux|Kernel|console|earlycon|!F|panic|Oops|Booting' | head -20 || true; \
	 echo "=== UART MMIO accesses (phys 0x10000000; >0 => console driver reached): ==="; \
	 grep -cE 'mem 0x0000000010000[0-9a-f]+' trace_rvfi_hart_00.dasm || true

clean:
	rm -f loader.elf loader_jump.elf loader_banner.elf loader_ecalli.elf loader_br.elf loader_loop.elf loader_djhalt.elf loader_djtab.elf loader_ibr.elf loader_ldij.elf loader_csr.elf loader_hostcall.elf loader_dramload.elf loader_drambanner.elf loader_hi.elf baseline.elf banner.hex ecalli.hex hi_banner.hex br_taken.hex br_nottaken.hex loop.hex djhalt.hex djtab.hex ibr_t.hex ibr_nt.hex ldij.hex csr.hex hostcall.hex loader_opensbi.elf opensbi.code.bin opensbi.jt.bin opensbi.ro.bin opensbi.rw.bin

.PHONY: all run run-jump run-banner run-ecalli run-branch run-loop run-djump-halt run-djump-table run-ibranch run-ldij run-csr run-hostcall run-dram run-dram-banner run-user run-user-dram run-pvmvec run-mret run-handoff run-handoff-dram run-djump-dram run-handoff-smode run-handoff-smode-dram run-priv run-priv-dyn run-priv-return run-strap-skip run-handoff-skip run-trap-jt run-trap-jt-dram run-handoff-trap-jt-dram run-smode-loop run-smode-loop-jt run-smode-sbi run-storeimm run-opensbi run-uboot run-kernel run-all clean
