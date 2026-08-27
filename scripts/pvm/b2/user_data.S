/* B2.2 standalone userspace .pvm WITH DATA: a .rodata string, a .data byte that is
 * read-modified-written, a .bss byte that must read as 0. Expected output:
 *   "B2.2 ro+rw: 37\n"   ('3' = .data 0x30+3, '7' = .bss 0+'7')
 * Linked with `polkatool link --memory-base 0x700000` (+ emit-image --memory-base
 * 0x700000): the data lands in the guest kernel's reserved window [0x700000,0x800000)
 * (DTS reserved-memory), where binfmt_pvm copies the ro/rw images before start_thread.
 * Syscall ABI as user_hello.S (RV64E: nr in t0, PVM ecalli marker + ExternMetadataV2).
 * NB: `la` (GOT-indirect under the default-PIE toolchain) is deliberate -- polkatool
 * resolves the GOT entries to the --memory-base addresses; `lla` (auipc+addi) makes
 * polkatool fail with "failed to add addend to the symbol's offset due to overflow". */
	.section .polkavm_metadata, "a", %progbits
u_sc_sym:
	.asciz	"linux_syscall"
u_sc_sym_end:
	.globl	u_sc_md
u_sc_md:
	.byte	2					/* version */
	.word	0					/* flags */
	.word	u_sc_sym_end - u_sc_sym - 1		/* symbol_length */
	.quad	u_sc_sym				/* symbol ptr (R_RISCV_64) */
	.byte	6					/* input_regs  = a0-a5 */
	.byte	2					/* output_regs = a0-a1 */
	.byte	1					/* has_index */
	.word	0					/* index 0 -> ecalli 0 */

u_name:
	.asciz	"_start"
u_name_end:
	.globl	u_entry_md
u_entry_md:
	.byte	1					/* version */
	.word	0					/* flags */
	.word	u_name_end - u_name - 1			/* name length */
	.quad	u_name					/* name ptr (R_RISCV_64) */
	.byte	0					/* input regs */
	.byte	0					/* output regs */

	.pushsection .polkavm_exports, "R", %note
	.byte	1					/* record version */
	.quad	u_entry_md
	.quad	_start
	.popsection

	.macro	pvm_syscall
	.insn	r 0xb, 0, 0, zero, zero, zero
	.quad	u_sc_md
	.endm

	.section .rodata
	.balign	8
msg:	.ascii	"B2.2 ro+rw: "			/* 12 bytes (MSG_LEN below) */
msg_end:
nl:	.ascii	"\n"

	.section .data
	.balign	8
	.globl	counter
counter:
	.byte	0x30					/* '0' -> +3 -> '3' */
	.byte	0					/* out[1] slot */
	.balign 8

	.section .bss
	.balign	8
	.globl	zero_byte
zero_byte:
	.zero	8					/* must read as 0 -> +'7' -> '7' */

	.section .text
	.balign	8
	.globl	_start
_start:
	/* rw: counter += 3 ('0' -> '3'), keep it in .data as out[0] */
	la	t1, counter
	lbu	t2, 0(t1)
	addi	t2, t2, 3
	sb	t2, 0(t1)
	/* bss: zero_byte + '7' -> out[1] (in .data, right after counter) */
	la	t2, zero_byte
	lbu	t2, 0(t2)
	addi	t2, t2, 0x37
	sb	t2, 1(t1)
	/* write(1, msg, 12) -- ro */
	li	t0, 64
	li	a0, 1
	la	a1, msg
	li	a2, 12				/* MSG_LEN: `li` needs an absolute constant */
	pvm_syscall
	/* write(1, counter, 2) -- rw result "37" */
	li	t0, 64
	li	a0, 1
	la	a1, counter
	li	a2, 2
	pvm_syscall
	/* write(1, nl, 1) */
	li	t0, 64
	li	a0, 1
	la	a1, nl
	li	a2, 1
	pvm_syscall
	li	t0, 93					/* exit(0) */
	li	a0, 0
	pvm_syscall
1:	j	1b
