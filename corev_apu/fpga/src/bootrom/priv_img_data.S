# Auto-generated from gen_pvm_img.py `priv` mode (verif/tests/custom/pvm_run).
# A multi-privilege PVM round-trip image (the OpenSBI-on-PVM core):
#   @0  (M): csr_rw mtvec,Lh ; csr_rw mepc,Ls ; mret -> S@Ls
#   @15      trap (decoy: mret-redirect-fail)
#   @16 (M-handler Lh, 4-aligned): load_imm r7,'#' ; ecalli@M (host '#') ; trap
#   @22 (S-entry Ls, 2-aligned): load_imm r7,'S' ; ecalli@S -> guest-trap to mtvec=Lh
# CODE_LEN=28 BM_OFF=32 ENTRY_PC=0 IMG_BYTES=36 (28 code + 4 pad + 4 bitmask).
# Targets are aligned: mtvec (Lh) 4-byte, mepc (Ls) 2-byte (RISC-V WARL on tvec[1:0]/epc[0]).
    .globl priv_blob
priv_blob:
    .byte 0x33, 0x01, 0x10, 0xe7, 0x21, 0x05, 0x03, 0x33, 0x01, 0x16, 0xe7, 0x21
    .byte 0x41, 0x03, 0xed, 0x00, 0x33, 0x07, 0x23, 0x0a, 0x00, 0x00, 0x33, 0x07
    .byte 0x53, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x89, 0xc4, 0x69, 0x0a
