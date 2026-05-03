// See LICENSE for license details.
#pragma once

/*
 * PVM port (sub-phase 10): stripped down for single-hart PolkaVM bootrom.
 *
 * The original smp.h used RISC-V CSR instructions (csrw mie, csrr mhartid,
 * csrr mip) that are not valid in the PVM ISA.  The PVM bootrom is
 * single-hart only, so:
 *
 *   - smp_pause / smp_resume macros are removed entirely.
 *     Multi-hart synchronisation is not needed (MULTI_HART path only).
 *
 *   - mhartid is replaced with the constant 0.
 *
 * The original macros are preserved in comments below for reference and
 * to document each inline-asm site (sub-phase 10 audit table).
 *
 * Inline-asm sites removed / replaced:
 *   smp.h:25  csrw mie, reg2        — removed (single-hart, no IPI)
 *   smp.h:27  csrr reg2, mhartid    — replaced with constant 0
 *   smp.h:40  csrr reg2, mip        — removed (single-hart, no IPI)
 *   smp.h:44  csrr reg2, mhartid    — replaced with constant 0
 */

// The hart that non-SMP tests should run on
#ifndef NONSMP_HART
#define NONSMP_HART 0
#endif

// The maximum number of HARTs this code supports
#define CLINT_CTRL_ADDR 0x2000000
#ifndef MAX_HARTS
#define MAX_HARTS 256
#endif
#define CLINT_END_HART_IPI (CLINT_CTRL_ADDR + (MAX_HARTS * 4))

/* ---------------------------------------------------------------------------
 * Single-hart PVM stubs: smp_pause and smp_resume are no-ops.
 *
 * Under MULTI_HART, restore the original CSR-based macros and rebuild with
 * a RISC-V (non-PVM) toolchain.
 * ---------------------------------------------------------------------------
 */
#ifdef MULTI_HART

/* Original RISC-V multi-hart macros — NOT valid for PVM ISA. */
#define smp_pause(reg1, reg2) \
    li reg2, 0x8;             \
    csrw mie, reg2;           \
    li reg1, NONSMP_HART;     \
    csrr reg2, mhartid;       \
    bne reg1, reg2, 42f

#define smp_resume(reg1, reg2)   \
    li reg1, CLINT_CTRL_ADDR;    \
    41:;                         \
    li reg2, 1;                  \
    sw reg2, 0(reg1);            \
    addi reg1, reg1, 4;          \
    li reg2, CLINT_END_HART_IPI; \
    blt reg1, reg2, 41b;         \
    42:;                         \
    wfi;                         \
    csrr reg2, mip;              \
    andi reg2, reg2, 0x8;        \
    beqz reg2, 42b;              \
    li reg1, CLINT_CTRL_ADDR;    \
    csrr reg2, mhartid;          \
    slli reg2, reg2, 2;          \
    add reg2, reg2, reg1;        \
    sw zero, 0(reg2);            \
    41:;                         \
    lw reg2, 0(reg1);            \
    bnez reg2, 41b;              \
    addi reg1, reg1, 4;          \
    li reg2, CLINT_END_HART_IPI; \
    blt reg1, reg2, 41b

#else /* !MULTI_HART — single-hart PVM path */

/* smp_pause/smp_resume are no-ops in single-hart mode. */
#define smp_pause(reg1, reg2)   /* nothing */
#define smp_resume(reg1, reg2)  /* nothing */

#endif /* MULTI_HART */

/*
 * PVM-compatible hartid accessor.
 * Single-hart: always returns 0.
 * Multi-hart RISC-V: reads mhartid CSR (not PVM-compatible).
 *
 * Guard with __ASSEMBLER__ because this header is also included by startup.S.
 */
#ifndef __ASSEMBLER__
static inline unsigned int pvm_hartid(void) {
#ifdef MULTI_HART
    /* RISC-V only — not valid in PVM ISA. */
    unsigned int id;
    __asm__ volatile ("csrr %0, mhartid" : "=r" (id));
    return id;
#else
    return 0;  /* single-hart constant */
#endif
}
#endif /* !__ASSEMBLER__ */
