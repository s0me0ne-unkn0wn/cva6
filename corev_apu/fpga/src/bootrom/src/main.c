// Copyright OpenHW Group contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "uart.h"
#include "spi.h"
#include "sd.h"
#include "gpt.h"

#define SECOND_CYCLES   CLOCK_FREQUENCY
#define WAIT_SECONDS    (10)

static inline uintptr_t get_cycle_count() {
    uintptr_t cycle;
    __asm__ volatile ("csrr %0, cycle" : "=r" (cycle));
    return cycle;
}

int update(uint8_t *dest)
{
    int i;
    uint32_t size = 0;

    print_uart("receiving boot image\r\nsize: ");
    for(i = 0; i < sizeof(uint32_t); i++) {
        while(!read_serial(&((uint8_t *) &size)[i]));
    }

    print_uart_int(size);
    print_uart("\r\nreceiving ");

    for(i = 0; i < size; i++) {
        while(!read_serial(&dest[i]));

        if(i % (size >> 4) == 0) {
            print_uart(".");
        }
    }

    print_uart(" done!\r\n");
    return 0;
}

#ifdef OPENSBI_UART_LOAD
// UART-download bootloader for OpenSBI-on-PVM (no JTAG path available on this board).
// The 2.1 MB OpenSBI DRAM image (flat objcopy of loader_opensbi.elf: code/jt/ro/rw/dtb at
// their offsets, mapped 1:1 from 0x80000000) is streamed in over the ns16550 UART and written
// byte-for-byte into DRAM at physical 0x80000000. opensbi_pvm_boot() then programs the PVM CSRs.
//
// No flow control is needed: at 50 MHz the CPU's uart_getc() poll loop is far faster than the
// 115200-baud byte arrival rate, so the RX FIFO never overruns. A '.' is emitted every 0x40000
// bytes so download progress is visible on the host terminal.
#ifndef LOAD_BYTES
#define LOAD_BYTES 2102750
#endif
void uart_load_dram(void)
{
    volatile unsigned char *p = (volatile unsigned char *)0x80000000UL;
    unsigned long i;

    print_uart("\r\nUART-load: send 2102750 bytes now\r\n");
    for (i = 0; i < LOAD_BYTES; i++) {
        p[i] = uart_getc();
        if ((i & 0x3FFFF) == 0) {
            print_uart(".");
        }
    }
    print_uart("\r\nload done, launching OpenSBI\r\n");
}
#endif

int main()
{
    int i, ret = 0;
    uint8_t uart_res = 0;
    uintptr_t start;


    #ifndef PLAT_AGILEX
    init_uart(CLOCK_FREQUENCY, UART_BITRATE); //not needed in intel setup as UART IP is already configured via HW
    #endif 
    print_uart("Hello World!\r\n");

    // PolkaVM bring-up (Stage 5): enter PVM mode and run the banner baked into
    // pvm_front.img_mem. pvm_boot() services ecalli host-calls and never returns.
    //
    // OpenSBI-on-PVM (B9): build with -DOPENSBI_PVM to instead launch a REAL OpenSBI build
    // as a PVM/JAM guest demand-fetched from DRAM (see opensbi_boot.S + OPENSBI_FPGA_BRINGUP.md).
    // The 2 MB OpenSBI DRAM image is staged out-of-band (JTAG/gdb or SD) BEFORE this call; by
    // default opensbi_pvm_boot() spins on a "ready" magic in DRAM until the host signals it.
    // The plain banner path (pvm_boot) is kept intact as the default fallback.
#ifdef OPENSBI_PVM
    print_uart("Entering PolkaVM (OpenSBI)...\r\n");
#ifdef OPENSBI_UART_LOAD
    // Receive the OpenSBI DRAM image over the UART (no JTAG preload here), then launch.
    // opensbi_pvm_boot() must NOT spin on the JTAG ready-magic in this mode -> build with
    // OPENSBI_NO_WAIT too (the C download replaces the out-of-band staging handshake).
    uart_load_dram();
#endif
    extern void opensbi_pvm_boot(void);
    opensbi_pvm_boot();
#else
    print_uart("Entering PolkaVM...\r\n");
    extern void pvm_boot(void);
    pvm_boot();
#endif

    // See if we should enter update mode
    print_uart("Hit any key to enter update mode ");
    for(i = 0; i < WAIT_SECONDS && !ret; i++) {
        print_uart(".");
        start = get_cycle_count();
        while(get_cycle_count() - start < SECOND_CYCLES) {
            ret = read_serial(&uart_res);
            if(ret) {
                break;
            }
        }
    }

    int res;
    if(ret) {
        print_uart(" updating!\r\n");
        res = update((uint8_t *)0x80000000UL);
    } else {
        print_uart(" booting!\r\n");
        #ifndef PLAT_AGILEX
        res = gpt_find_boot_partition((uint8_t *)0x80000000UL, 2 * 16384); 
        #else 
            int start_block_fw_payload  = 0x32800; //payload at 100MB
            print_uart("I am Agilex 7! \r\n");

            print_uart("Loading fw_payload into memory address 0x80000000 \n");
            for (uint64_t i = 0; i < 15000; i++){
                res = sd_copy_mmc((uint8_t *)0x80000000UL + (i * 0x200), start_block_fw_payload + i, 1); // for now hardcoded, need to develop the code to find the file in the SD card

                if (res)
                {
                    print_uart("TRANSFER ERROR\n");
                    return res;
                }
		    }
        #endif 
    }

    if (res == 0)
    {
        // jump to the address
        __asm__ volatile(
            "li s0, 0x80000000;"
            "la a1, _dtb;"
            "jr s0");
    }

    while (1)
    {
        // do nothing
    }
}

void handle_trap(void)
{
    // print_uart("trap\r\n");
}
