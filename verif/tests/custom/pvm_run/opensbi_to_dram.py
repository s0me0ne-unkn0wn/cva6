#!/usr/bin/env python3
# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# B7: split a `polkatool emit-image` blob (the flat "PVMI" hardware image) of a REAL
# OpenSBI build into the separate DRAM regions the CVA6-PVM M3 demand-fetch path expects,
# emitting binary blobs for `.incbin` (NOT giant .byte arrays -- the OpenSBI code is 85 KB).
#
# Output blobs (placed at fixed DRAM addrs by link_opensbi.ld):
#   <base>.code.bin : code + pad-to-align16 + bitmask          -> code_base (M3 fetch)
#   <base>.jt.bin   : the jump table (z-byte LE entries)        -> CFG2 jt_base
#   <base>.ro.bin   : ro_data  (guest [0x10000,0x10000+ro_tot)) -> ram_base+0x10000
#   <base>.rw.bin   : rw_init  (guest [0x30000,0x30000+rw_img)) -> ram_base+0x30000
# (bss = rw_tot - rw_img is zeroed by the loader, not emitted.)
#
# emit-image header is 128 bytes; authoritative layout (polkatool main_emit_image):
#   0x00 magic "PVMI"  0x04 version=1  0x08 code_size  0x0C bitmask_size
#   0x10 ro_image  0x14 ro_total  0x18 rw_image  0x1C rw_total
#   0x20 jt_size   0x24 jt_entry_size  0x28 stack_size  0x2C entry_pc
#   0x80 code ; then ALIGN-16 padded: bitmask, ro_init, rw_init, jump_table.
# The bitmask is ALREADY LSB-first == our HW skip-encoder order (pvm_fetch.sv): no reversal.
# M3 fetch wants code at off 0 of the code region and the bitmask at align16(code_len)
# (pvm_front: bitmask_base = code_base + align16(code_len)); the jump table is a SEPARATE
# DRAM region addressed by CFG2.jt_base (cva6.sv: jumptable_base_i = CFG2[31:0]).
#
#   usage: opensbi_to_dram.py <in.img> <out_basename>
import sys, struct

PVMI_MAGIC = 0x504D5649  # "PVMI"
HEADER = 128


def align16(n):
    return (n + 15) & ~15


def main():
    inp, base = sys.argv[1], sys.argv[2]
    data = open(inp, "rb").read()
    (magic, version, code_size, bm_size, ro_img, ro_tot, rw_img, rw_tot,
     jt_size, jt_entry, stack_size, entry_pc) = struct.unpack("<12I", data[:48])
    if magic != PVMI_MAGIC:
        sys.exit(f"bad magic 0x{magic:08x} (expected PVMI 0x{PVMI_MAGIC:08x})")

    # sections in the emit-image file, each ALIGN-16 padded after the 128B header
    off = HEADER
    code = data[off : off + code_size];            off = align16(off + code_size)
    bitmask = data[off : off + bm_size];           off = align16(off + bm_size)
    ro = data[off : off + ro_img];                 off = align16(off + ro_img)
    rw = data[off : off + rw_img];                 off = align16(off + rw_img)
    jt = data[off : off + jt_size]

    # code region for the M3 fetch: code, pad->align16(code_len), bitmask (LSB-first as-is)
    bm_off = align16(code_size)
    code_region = bytearray(code) + b"\x00" * (bm_off - code_size) + bitmask

    open(base + ".code.bin", "wb").write(code_region)
    open(base + ".jt.bin", "wb").write(jt)
    open(base + ".ro.bin", "wb").write(ro)
    open(base + ".rw.bin", "wb").write(rw)

    bss = rw_tot - rw_img

    # Guest RW base, exactly as polkavm-common abi.rs MemoryMapBuilder lays it out:
    # ro@0x10000, then align the RO span up to VM_MAX_PAGE_SIZE (64K) plus one guard
    # page. HARD-CODING this in a loader goes stale the moment RO crosses a 64K
    # boundary (bit us twice: -Os growth 0xF0000->0x100000, minimal-config shrink
    # 0x100000->0xC0000 -> every static kernel pointer read zeros) -- consumers must
    # take RW_BASE/RW_VMA from here instead.
    VM_PAGE = 0x10000
    rw_base = VM_PAGE + ((ro_tot + VM_PAGE - 1) & ~(VM_PAGE - 1)) + VM_PAGE

    print(f"CODE_LEN  : {code_size}")
    print(f"RW_BASE   : {rw_base}")
    print(f"RW_VMA    : 0x{0x80000000 + rw_base:x}")
    print(f"BM_OFF    : {bm_off}")
    print(f"CODE_REGION_BYTES : {len(code_region)}")
    print(f"JT_SIZE   : {jt_size}")
    print(f"JT_Z      : {jt_entry}")
    print(f"JT_ENTRIES: {jt_size // jt_entry if jt_entry else 0}")
    print(f"ENTRY_PC  : {entry_pc}")
    print(f"RO_IMG    : {ro_img}")
    print(f"RW_IMG    : {rw_img}")
    print(f"RW_TOTAL  : {rw_tot}")
    print(f"BSS       : {bss}")
    print(f"STACK     : {stack_size}")
    print(f"wrote     : {base}.code.bin {base}.jt.bin {base}.ro.bin {base}.rw.bin")


if __name__ == "__main__":
    main()
