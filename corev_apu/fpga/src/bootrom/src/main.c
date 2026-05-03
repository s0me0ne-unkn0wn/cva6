// Copyright OpenHW Group contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "uart.h"
#include "spi.h"
#include "sd.h"
#include "gpt.h"

#define SECOND_CYCLES   CLOCK_FREQUENCY
#define WAIT_SECONDS    (10)

/*
 * PVM port (sub-phase 10): the PVM ISA has no `cycle` CSR.
 * The pcycle counter is exposed as a MMIO load at PCYCLE_MMIO_ADDR.
 *
 * Hardware note: HW MMIO-mapping of pcycle via the LSU decode path is a
 * follow-up task (sub-phase 11 / pvm_csr_regfile.sv).  For now this
 * returns 0 so that get_cycle_count() - start always < SECOND_CYCLES,
 * meaning the timeout loop exits immediately (0 wait-seconds effectively).
 * The bootrom still reaches the SD-card read path.
 *
 * PCYCLE_MMIO_ADDR = 0x40000000 (unused MMIO slot, reserved for pcycle).
 */
#ifndef PCYCLE_MMIO_ADDR
#define PCYCLE_MMIO_ADDR 0x40000000UL
#endif

static inline uintptr_t get_cycle_count() {
#ifdef PVM_PCYCLE_STUB
    /* Stub: HW MMIO not yet mapped.  Returns 0 so timeout loop exits fast. */
    return 0;
#else
    return *((volatile uintptr_t *)PCYCLE_MMIO_ADDR);
#endif
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

int main()
{
    int i, ret = 0;
    uint8_t uart_res = 0;
    uintptr_t start;


    #ifndef PLAT_AGILEX
    init_uart(CLOCK_FREQUENCY, UART_BITRATE); //not needed in intel setup as UART IP is already configured via HW
    #endif 
    print_uart("Hello World!\r\n");

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
        /*
         * PVM port (sub-phase 10): replaced RISC-V inline asm jump with a
         * typed function-pointer call.  The PVM compiler (polkatool JAM v1)
         * will emit the equivalent of:
         *   load_imm   A0, 0          ; hart ID = 0 (single-hart)
         *   load_imm   A1, &_dtb      ; device-tree pointer
         *   load_imm64 A2, 0x80000000 ; DRAM base
         *   jump_indirect A2, 0
         *
         * Convention: entry(hartid, dtb_ptr) matching Linux/OpenSBI ABI.
         */
        extern char _dtb[];
        typedef void __attribute__((noreturn)) (*entry_fn_t)(uintptr_t, void *);
        entry_fn_t entry = (entry_fn_t)0x80000000UL;
        entry(0, (void *)_dtb);
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
