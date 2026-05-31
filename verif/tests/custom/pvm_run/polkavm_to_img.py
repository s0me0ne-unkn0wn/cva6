#!/usr/bin/env python3
# Copyright 2026 CVA6-PolkaVM contributors
# SPDX-License-Identifier: Apache-2.0
#
# Convert a `polkatool emit-image` blob (the flat "PVMI" hardware image) into the
# img_mem layout the CVA6-PVM fetch expects (code at 0, the opcode bitmask at
# align16(code_len), then the jump table), emitting BOTH a $readmemh hex (for the
# +PVM_IMG fast-sim path) and a byte .S array (for the DRAM CSR-load path). This
# is the bridge from the REAL PolkaVM toolchain (link -> emit-image) to our
# loader -- genuine compiled programs instead of the hand-emitted gen_pvm_img.py.
#
# emit-image header is 128 bytes (the `--help` "16-byte/MSB-first" text is stale);
# the authoritative layout is polkatool main.rs main_emit_image:
#   0x00 magic "PVMI"  0x04 version=1  0x08 code_size  0x0C bitmask_size
#   0x10 ro_image  0x14 ro_total  0x18 rw_image  0x1C rw_total
#   0x20 jt_size   0x24 jt_entry_size  0x28 stack_size  0x2C entry_pc
#   0x80 code ; then ALIGN-16 padded: bitmask, ro_init, rw_init, jump_table.
# The bitmask is ALREADY LSB-first (verified against known boundaries) == our HW
# skip-encoder order (pvm_fetch.sv), so NO bit reversal. ro/rw data are guest
# DRAM contents (loaded separately by the loader), NOT part of img_mem.
#
#   usage: polkavm_to_img.py <in.img> <out_basename>
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

    # OUR img_mem layout: code, pad->align16, bitmask (LSB-first as-is), then jt
    bm_off = align16(code_size)
    img = bytearray(code) + b"\x00" * (bm_off - code_size) + bitmask
    jt_base = len(img)
    img += jt

    with open(base + ".hex", "w") as f:
        f.write("@00000000\n")
        for b in img:
            f.write(f"{b:02x}\n")

    with open(base + "_blob.S", "w") as f:
        f.write("# Auto-generated from a polkatool emit-image blob. Do not edit.\n")
        f.write(f"# CODE_LEN={code_size} BM_OFF={bm_off} ENTRY_PC={entry_pc} "
                f"JT_BASE={jt_base if jt_size else 0} JT_Z={jt_entry} IMG_BYTES={len(img)}\n")
        f.write("    .globl user_blob\nuser_blob:\n")
        for i in range(0, len(img), 12):
            row = ", ".join(f"0x{b:02x}" for b in img[i : i + 12])
            f.write(f"    .byte {row}\n")

    print(f"CODE_LEN  : {code_size}")
    print(f"ENTRY_PC  : {entry_pc}")
    print(f"BM_OFF    : {bm_off}")
    print(f"JT_BASE   : {jt_base if jt_size else 0}")
    print(f"JT_Z      : {jt_entry}")
    print(f"RO/RW     : {ro_tot}/{rw_tot} bytes (guest DRAM; loader must place)")
    print(f"STACK     : {stack_size}")
    print(f"IMG_BYTES : {len(img)}")
    print(f"wrote     : {base}.hex, {base}_blob.S")


if __name__ == "__main__":
    main()
