/* B2.1 standalone userspace .pvm: write "B2!\n" + exit(0), code-only (no .data,
 * no djump/JT). The string is built on the stack (start_thread gives sp), so the
 * image has no ro/rw data to relocate. Linked by polkatool into a standalone
 * user.polkavm, loaded from initramfs by binfmt_pvm (NOT pre-linked into the kernel).
 * RV64E Linux syscall ABI: number in t0, args a0..a2. Syscalls are PVM ecalli via
 * the .insn marker + ExternMetadataV2 pair (the U-Boot/uexec convention). */
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

	.section .text
	.balign	8
	.globl	_start
_start:
	/* build "B2!\n" on the stack: 0x0a='\n' 0x21='!' 0x32='2' 0x42='B' -> LE word 0x0a213242 */
	li	t1, 0x0a213242
	addi	sp, sp, -16
	sw	t1, 0(sp)			/* [sp..sp+4) = "B2!\n" */
	li	t0, 64				/* __NR_write (RV64E: nr in t0) */
	li	a0, 1				/* fd = stdout */
	mv	a1, sp				/* buf = stack */
	li	a2, 4				/* len = 4 */
	pvm_syscall
	li	t0, 93				/* __NR_exit */
	li	a0, 0
	pvm_syscall
1:	j	1b
