/* PVM smoke: add_imm + store_u32 + trap
 *
 * Exercises three JAM v1 opcode classes:
 *   - add_imm  : x = x + 42
 *   - store_u32: *target = x  (32-bit store to a memory location)
 *   - trap     : __builtin_trap() -> ebreak -> PVM trap opcode
 *
 * The .polkavm_exports section is required by the polkavm-linker.
 * It exports _start as "main" using the same metadata layout as
 * guest-programs/riscv-tests/riscv_test.h.
 */

/* ---- PolkaVM export metadata ------------------------------------------- */
__asm__(
    ".pushsection .metadata,\"\",@progbits\n"
    "_entry_point_name:\n"
    "    .asciz \"main\"\n"
    "_entry_point_name_end:\n"
    "_pvm_metadata:\n"
    "    .byte 1\n"                             /* version */
    "    .word 0\n"                             /* flags */
    "    .word _entry_point_name_end - _entry_point_name - 1\n"
    "    .quad _entry_point_name\n"             /* pointer to name string */
    "    .byte 0\n"                             /* input regs */
    "    .byte 0\n"                             /* output regs */
    ".popsection\n"

    ".pushsection .polkavm_exports,\"R\",@note\n"
    "    .byte 1\n"                             /* entry count */
    "    .quad _pvm_metadata\n"                 /* pointer to metadata */
    "    .quad _start\n"                        /* pointer to code */
    ".popsection\n"
);

/* ---- Data section: source and target words ----------------------------- */
/* volatile prevents the compiler from constant-folding away the add_imm op */
static volatile unsigned int src_word  __attribute__((section(".data"))) = 0;
static volatile unsigned int target_word __attribute__((section(".data"))) = 0;

/* ---- Entry point ------------------------------------------------------- */
void __attribute__((noreturn, used)) _start(void)
{
    unsigned int x = src_word; /* read from volatile: forces a real register load */
    x = x + 42;                /* add_imm-class op: compiler cannot fold this away */
    target_word = x;           /* store_u32-class op (32-bit store) */
    /* PVM trap via the defacto unimp encoding (csrrw x0,cycle,x0 = 0xc0001073).
     * __builtin_trap() emits ebreak which the polkavm-linker rejects.
     * unimp (0xc0001073) is explicitly mapped to Inst::Unimplemented -> PVM trap. */
    __asm__ volatile (".word 0xc0001073" : : : "memory");
    __builtin_unreachable();
}
