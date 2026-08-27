/* Common startup for C userspace .pvm programs (B2.3): the PVM ecalli metadata for the
 * Linux syscall (RV64E: nr in t0, args a0..a5), the `_start` export, and _start itself:
 * call main (a REAL call -> the return goes through the jump table), then exit(main()).
 * Linked by polkatool with --memory-base 0x700000 --jt-index-base K (K = the guest kernel's
 * jump-table entry count, see binfmt_pvm). */
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

	.section .text
	.balign	8
	.globl	_start
_start:
	andi	sp, sp, -16
	call	main					/* -> ret = dynamic jump via the (shared) jump table */
	li	t0, 93					/* __NR_exit(a0 = main's return value) */
	.insn	r 0xb, 0, 0, zero, zero, zero
	.quad	u_sc_md
1:	j	1b
