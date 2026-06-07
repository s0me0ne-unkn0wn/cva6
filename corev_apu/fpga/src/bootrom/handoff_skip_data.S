# Auto-generated from gen_pvm_img.py `handoff_skip` mode (verif/tests/custom/pvm_run).
# Stage-1 + Stage-2 COMBINED FPGA image (the real OpenSBI config): the M->S ENTRY mret is
# JT-mapped (mepc = JT token (idx+1)*2, CFG2[36]=1) and CONSUMES the one-shot; then an ecalli@S
# skip-return -- whose mepc is a RAW PVM-pc (the guest M-handler does the standard RISC-V
# `mepc += 4; mret`) -- MUST take the DIRECT path (CFG2[36] self-cleared) to land on the
# instruction after the 2-byte ecalli. Prints framed '[#]' iff the one-shot self-clear AND the
# -4 skip-bias both hold on silicon; a still-sticky CFG2[36] JT-mangles the skip-return -> no '#'.
#   @0  (M): mtvec=Lh1 ; mepc=(idx+1)*2 (JT token) ; mret -> JT[0]=Ls(16) [JT-mapped; consumes bit36]
#   @16 (S, Ls): ecalli@S -> Lh1 ; skip-target = @18
#   @18 (S): ecalli@S -> Lh2 -> host '#'
#   @20 trap (+pads): DECOY (skip-return mis-land -> no '#')
#   @24 (M, Lh1): mtvec=Lh2 ; r5=0 ; r3=mepc ; r3+=4 ; mepc=r3 ; mret -> S@18 [DIRECT, bit36 gone]
#   @48 (M, Lh2): load_imm r7,'#' ; ecalli@M (host '#') ; trap
# CODE_LEN=54 BM_OFF=64 JT_BASE=71 JT_Z=1 IMG_BYTES=72. mtvec targets (Lh1/Lh2) 4-aligned;
# mepc/skip targets (Ls/Ls+2) 2-aligned (RISC-V WARL). Loader sets MPP=S + CFG2={bit36|z<<32|71}.
    .globl skip_blob
skip_blob:
    .byte 0x33, 0x01, 0x18, 0xe7, 0x12, 0x05, 0x03, 0x33, 0x01, 0x02, 0xe7, 0x12
    .byte 0x41, 0x03, 0xed, 0x00, 0x0a, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x33, 0x01, 0x30, 0xe7, 0x12, 0x05, 0x03, 0x33, 0x05, 0x00, 0xe8, 0x53
    .byte 0x41, 0x03, 0x83, 0x33, 0x04, 0xe7, 0x34, 0x41, 0x03, 0xed, 0x00, 0x00
    .byte 0x33, 0x07, 0x23, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x89, 0xc4, 0xf5, 0x89, 0x44, 0xe2, 0x29, 0x10
