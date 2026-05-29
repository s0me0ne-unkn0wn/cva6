    .section .text.init,"ax",@progbits
    .globl _start
_start:
    li   t0, 0xAB
    li   t1, 0x80010000
    sb   t0, 0(t1)         # plain RISC-V store to the same address PVM uses
    lb   t2, 0(t1)         # read back
    li   t0, 1
    la   t1, tohost
    sd   t0, 0(t1)         # success
1:  j 1b
    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
