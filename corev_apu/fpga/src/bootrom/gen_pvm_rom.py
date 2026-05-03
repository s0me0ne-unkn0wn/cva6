#!/usr/bin/env python3
"""gen_pvm_rom.py — PolkaVM blob → SystemVerilog ROM pair

Reads a JAM v1 `.polkavm` blob produced by:
    cargo run -p polkatool -- link -i jam_v1 elf -o out.polkavm

Emits two companion SV ROM modules:
    bootrom_code_64.sv   — 16-byte-aligned 128-bit code chunks
    bootrom_bitmask_64.sv — 4-byte-aligned 32-bit bitmask windows

These are consumed by pvm_frontend.sv (ADR-10 layout):
    code_data_i    [127:0]  — 16 bytes starting at group_base = addr & ~15
    bitmask_data_i  [31:0]  — 4 bytes, one bit per code byte, starting at
                              group_base = addr & ~31 (32-byte window)

Usage:
    gen_pvm_rom.py --in blob.polkavm \
                   --out-code bootrom_code_64.sv \
                   --out-bitmask bootrom_bitmask_64.sv

    # Or single-output (both in one file):
    gen_pvm_rom.py --in blob.polkavm --out-combined bootrom_pvm_64.sv

The script also emits a .h header with the raw code bytes for simulation.
"""

import argparse
import math
import os
import struct
import sys

# ---------------------------------------------------------------------------
# PolkaVM blob constants (from polkavm-common/src/program.rs)
# ---------------------------------------------------------------------------
BLOB_MAGIC = b'PVM\x00'
BLOB_LEN_OFFSET = 5          # after magic(4) + version(1)
BLOB_LEN_SIZE = 8            # u64 LE

# Version bytes
ISA_LATEST32 = 1
ISA_REVIVE_V1 = 2
ISA_JAM_V1 = 3
ISA_LATEST64 = 4

ISA_NAMES = {
    ISA_LATEST32: "latest32",
    ISA_REVIVE_V1: "revive_v1",
    ISA_JAM_V1: "jam_v1",
    ISA_LATEST64: "latest64",
}

# Section IDs
SECTION_MEMORY_CONFIG = 1
SECTION_RO_DATA = 2
SECTION_RW_DATA = 3
SECTION_IMPORTS = 4
SECTION_EXPORTS = 5
SECTION_CODE_AND_JUMP_TABLE = 6
SECTION_OPT_DEBUG_STRINGS = 128
SECTION_OPT_DEBUG_LINE_PROGRAMS = 129
SECTION_OPT_DEBUG_LINE_PROGRAM_RANGES = 130
SECTION_END_OF_FILE = 0

# ---------------------------------------------------------------------------
# Varint decoder (mirrors polkavm-common/src/varint.rs)
# ---------------------------------------------------------------------------

def read_varint(data: bytes, pos: int):
    """Decode one varint at data[pos].  Returns (value, new_pos)."""
    if pos >= len(data):
        raise ValueError(f"read_varint: position {pos} past end of data ({len(data)})")
    first = data[pos]
    # leading ones of the inverted first byte give extension byte count
    length = bin(first ^ 0xFF).lstrip('0b').lstrip('1').find('1') if (first ^ 0xFF) else 8
    # simpler: count leading ones in first byte
    length = 0
    tmp = first
    while tmp & 0x80:
        length += 1
        tmp = (tmp << 1) & 0xFF
    # upper_bits are the payload bits in the first byte
    upper_mask = 0xFF >> length
    upper_bits = (upper_mask & first) << (length * 8)
    # read extension bytes (little-endian)
    ext = data[pos + 1: pos + 1 + length]
    if len(ext) != length:
        raise ValueError(f"read_varint: not enough bytes at pos {pos}")
    value = upper_bits
    for i, b in enumerate(ext):
        value |= b << (i * 8)
    return value, pos + 1 + length


# ---------------------------------------------------------------------------
# Blob parser
# ---------------------------------------------------------------------------

class ProgramBlob:
    """Parsed PolkaVM program blob."""

    def __init__(self):
        self.isa: int = 0
        self.ro_data_size: int = 0
        self.rw_data_size: int = 0
        self.stack_size: int = 0
        self.ro_data: bytes = b''
        self.rw_data: bytes = b''
        self.import_offsets: bytes = b''
        self.import_symbols: bytes = b''
        self.exports: bytes = b''
        self.jump_table: bytes = b''
        self.jump_table_entry_size: int = 0
        self.code: bytes = b''
        self.bitmask: bytes = b''
        self.raw: bytes = b''

    @classmethod
    def from_file(cls, path: str) -> 'ProgramBlob':
        with open(path, 'rb') as f:
            data = f.read()
        return cls.from_bytes(data)

    @classmethod
    def from_bytes(cls, data: bytes) -> 'ProgramBlob':
        blob = cls()
        blob.raw = data

        # Magic check
        if not data.startswith(BLOB_MAGIC):
            raise ValueError(f"Bad magic: expected {BLOB_MAGIC.hex()}, got {data[:4].hex()}")

        pos = len(BLOB_MAGIC)

        # Version byte
        blob.isa = data[pos]
        pos += 1
        if blob.isa not in ISA_NAMES:
            raise ValueError(f"Unsupported ISA version byte: 0x{blob.isa:02x}")

        # Blob length (u64 LE)
        blob_len = struct.unpack_from('<Q', data, pos)[0]
        pos += 8
        if blob_len != len(data):
            raise ValueError(
                f"Blob length mismatch: header says {blob_len}, actual {len(data)}")

        # Parse sections in order
        def read_section_bytes(expected_id: int) -> bytes:
            nonlocal pos
            if pos >= len(data):
                return b''
            sid = data[pos]
            if sid != expected_id:
                return b''
            pos += 1
            sec_len, pos = read_varint(data, pos)
            payload = data[pos: pos + sec_len]
            pos += sec_len
            return payload

        def peek_section() -> int:
            if pos < len(data):
                return data[pos]
            return SECTION_END_OF_FILE

        # Section 1: memory config (optional)
        if peek_section() == SECTION_MEMORY_CONFIG:
            pos += 1  # consume section id
            sec_len, pos = read_varint(data, pos)
            sec_start = pos
            blob.ro_data_size, pos = read_varint(data, pos)
            blob.rw_data_size, pos = read_varint(data, pos)
            blob.stack_size, pos = read_varint(data, pos)
            # skip any remaining bytes in section
            pos = sec_start + sec_len

        # Section 2: RO data
        blob.ro_data = read_section_bytes(SECTION_RO_DATA)

        # Section 3: RW data
        blob.rw_data = read_section_bytes(SECTION_RW_DATA)

        # Section 4: imports (optional, variable layout)
        if peek_section() == SECTION_IMPORTS:
            pos += 1  # consume section id
            sec_len, pos = read_varint(data, pos)
            sec_start = pos
            import_count, pos = read_varint(data, pos)
            import_offsets_size = import_count * 4
            blob.import_offsets = data[pos: pos + import_offsets_size]
            pos += import_offsets_size
            remaining = sec_len - (pos - sec_start)
            blob.import_symbols = data[pos: pos + remaining]
            pos += remaining

        # Section 5: exports
        blob.exports = read_section_bytes(SECTION_EXPORTS)

        # Section 6: code and jump table (required)
        code_jt_raw = read_section_bytes(SECTION_CODE_AND_JUMP_TABLE)
        if not code_jt_raw:
            raise ValueError("No code section found in blob")
        blob._parse_code_section(code_jt_raw)

        # Skip optional debug sections (section IDs >= 128)
        while peek_section() >= 128:
            pos += 1  # consume section id
            sec_len, pos = read_varint(data, pos)
            pos += sec_len

        # End of file
        if peek_section() != SECTION_END_OF_FILE:
            sid = data[pos] if pos < len(data) else -1
            raise ValueError(
                f"Expected SECTION_END_OF_FILE (0), got 0x{sid:02x} at pos {pos}")

        return blob

    def _parse_code_section(self, raw: bytes):
        """Parse the CODE_AND_JUMP_TABLE section payload."""
        pos = 0
        initial_pos = pos

        # jump_table_entry_count (varint)
        jt_count, pos = read_varint(raw, pos)
        # jump_table_entry_size (1 byte)
        jt_entry_size = raw[pos]
        pos += 1
        # code_length (varint)
        code_length, pos = read_varint(raw, pos)

        if jt_entry_size not in range(5):
            raise ValueError(f"Invalid jump table entry size: {jt_entry_size}")

        jt_bytes = jt_count * jt_entry_size
        self.jump_table_entry_size = jt_entry_size
        self.jump_table = raw[pos: pos + jt_bytes]
        pos += jt_bytes

        self.code = raw[pos: pos + code_length]
        pos += code_length

        # Remainder is the bitmask
        bitmask_length = len(raw) - pos
        self.bitmask = raw[pos: pos + bitmask_length]

        # Validate bitmask length
        expected = (len(self.code) + 7) // 8
        if len(self.bitmask) != expected:
            raise ValueError(
                f"Bitmask length {len(self.bitmask)} != expected {expected} "
                f"for code length {len(self.code)}")

    def isa_name(self) -> str:
        return ISA_NAMES.get(self.isa, f"unknown(0x{self.isa:02x})")

    def get_bit(self, byte_offset: int) -> bool:
        """Return True if code byte at byte_offset is an opcode position."""
        if byte_offset >= len(self.code):
            return False
        byte_idx = byte_offset >> 3
        bit_idx = byte_offset & 7
        if byte_idx >= len(self.bitmask):
            return False
        return bool(self.bitmask[byte_idx] & (1 << bit_idx))

    def summary(self) -> str:
        lines = [
            f"ISA         : {self.isa_name()} (version byte 0x{self.isa:02x})",
            f"Total size  : {len(self.raw)} bytes",
            f"RO data     : {len(self.ro_data)}/{self.ro_data_size} bytes",
            f"RW data     : {len(self.rw_data)}/{self.rw_data_size} bytes",
            f"Stack size  : {self.stack_size} bytes",
            f"Code        : {len(self.code)} bytes",
            f"Bitmask     : {len(self.bitmask)} bytes",
            f"Jump table  : {len(self.jump_table)} bytes "
            f"(entry_size={self.jump_table_entry_size})",
            f"Exports raw : {len(self.exports)} bytes",
        ]
        return '\n'.join(lines)


# ---------------------------------------------------------------------------
# SV generation helpers — mirrors gen_rom.py style
# ---------------------------------------------------------------------------

LICENSE_HEADER = """\
/* Copyright 2018 ETH Zurich and University of Bologna.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the "License"); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File: {filename}
 *
 * Description: Auto-generated PVM bootrom (gen_pvm_rom.py)
 */

// Auto-generated code — do not edit by hand.
// Source: {source}
// ISA: {isa}
// Code bytes: {code_bytes}
// Bitmask bytes: {bitmask_bytes}
"""

CODE_ROM_TEMPLATE = """\
module bootrom_code_64 (
   input  logic         clk_i,
   input  logic         req_i,
   input  logic [63:0]  addr_i,
   output logic [127:0] rdata_o
);
    // Number of 16-byte (128-bit) entries.
    localparam int RomSize = {rom_size};

    // MSB-first array so index 0 = first 16 bytes of code.
    const logic [RomSize-1:0][127:0] mem = {{
{content}
    }};

    // Combinatorial read so pvm_frontend.sv (which assumes same-cycle data)
    // can fetch correctly. Distributed RAM is inferred for the small ROM.
    // clk_i / req_i kept in ports for interface compatibility.
    logic unused_clk;  assign unused_clk = clk_i;
    logic unused_req;  assign unused_req = req_i;
    (* rom_style = "distributed" *)
    logic [$clog2(RomSize)-1:0] idx;
    assign idx = addr_i[$clog2(RomSize)-1+4:4];
    assign rdata_o = (idx < RomSize) ? mem[idx] : '0;
endmodule
"""

BITMASK_ROM_TEMPLATE = """\
module bootrom_bitmask_64 (
   input  logic         clk_i,
   input  logic         req_i,
   input  logic [63:0]  addr_i,
   output logic [31:0]  rdata_o
);
    // Number of 4-byte (32-bit) bitmask entries.
    // Each entry covers 32 consecutive code bytes (one bit per byte).
    localparam int RomSize = {rom_size};

    const logic [RomSize-1:0][31:0] mem = {{
{content}
    }};

    // Combinatorial read so pvm_frontend.sv (which assumes same-cycle data)
    // can fetch correctly. Distributed RAM is inferred for the small ROM.
    // clk_i / req_i kept in ports for interface compatibility.
    logic unused_clk;  assign unused_clk = clk_i;
    logic unused_req;  assign unused_req = req_i;
    (* rom_style = "distributed" *)
    logic [$clog2(RomSize)-1:0] idx;
    assign idx = addr_i[$clog2(RomSize)-1+5:5];
    assign rdata_o = (idx < RomSize) ? mem[idx] : '0;
endmodule
"""

COMBINED_TEMPLATE = """\
{code_module}

{bitmask_module}
"""


def pad_to_multiple(data: bytes, multiple: int, pad_byte: int = 0) -> bytes:
    """Pad data up to the next multiple of `multiple` bytes."""
    rem = len(data) % multiple
    if rem:
        data = data + bytes([pad_byte] * (multiple - rem))
    return data


def build_code_sv_entries(code: bytes) -> tuple[int, str]:
    """
    Build SV const-array entries for 128-bit (16-byte) code chunks.

    The SV array is declared [RomSize-1:0][127:0] so index 0 is the
    *first* entry.  SystemVerilog array literals are written highest-index
    first (left = highest), so we reverse the chunk list before emitting.
    """
    # Pad code to 16-byte boundary
    padded = pad_to_multiple(code, 16)
    n_chunks = len(padded) // 16

    chunks = []
    for i in range(n_chunks):
        chunk = padded[i * 16: i * 16 + 16]
        # little-endian 128-bit word: chunk[0] is bit 7..0 of rdata_o
        word = int.from_bytes(chunk, 'little')
        hi64 = (word >> 64) & 0xFFFFFFFFFFFFFFFF
        lo64 = word & 0xFFFFFFFFFFFFFFFF
        chunks.append(f"        128'h{hi64:016x}_{lo64:016x}")

    # Reverse so that entry 0 is written last (SV highest-index-first)
    chunks_rev = list(reversed(chunks))
    content = ',\n'.join(chunks_rev)
    return n_chunks, content


def build_bitmask_sv_entries(code: bytes, bitmask: bytes) -> tuple[int, str]:
    """
    Build SV const-array entries for 32-bit bitmask windows.

    Each entry covers 32 consecutive code bytes (one bit per byte, packed
    LSB-first: bit j of the 32-bit word = opcode marker for code byte
    group_base + j).

    The bitmask in the blob is already packed with 8 bits per byte and
    LSB = lowest offset, matching what pvm_frontend.sv expects.
    """
    # Pad code to 32-byte boundary for complete bitmask words
    padded_code_len = ((len(code) + 31) // 32) * 32
    n_words = padded_code_len // 32

    entries = []
    for i in range(n_words):
        # Extract 4 bytes of bitmask covering code bytes [i*32 .. i*32+31]
        bm_byte_start = i * 4
        bm_slice = bitmask[bm_byte_start: bm_byte_start + 4]
        # Pad with zeros if we ran off the end
        bm_slice = bm_slice + b'\x00' * (4 - len(bm_slice))
        word = struct.unpack_from('<I', bm_slice)[0]
        entries.append(f"        32'h{word:08x}")

    # Reverse for SV highest-index-first layout
    entries_rev = list(reversed(entries))
    content = ',\n'.join(entries_rev)
    return n_words, content


# ---------------------------------------------------------------------------
# .h header emission (for simulation — mirrors gen_rom.py style)
# ---------------------------------------------------------------------------

def generate_h(filename_base: str, blob: 'ProgramBlob'):
    """Emit a C header with the code bytes for simulation."""
    code = blob.code
    # Pad to 4-byte boundary
    padded = pad_to_multiple(code, 4)
    with open(filename_base + '.h', 'w') as f:
        f.write("// Auto-generated PVM bootrom code header\n")
        f.write(f"// Source ISA: {blob.isa_name()}\n")
        f.write(f"// Code bytes: {len(code)}\n\n")
        f.write(f"const int pvm_bootrom_code_size = {len(padded) // 4};\n\n")
        f.write("uint32_t pvm_bootrom_code[] = {\n")
        for i in range(0, len(padded), 4):
            word = struct.unpack_from('<I', padded, i)[0]
            f.write(f"    0x{word:08x},\n")
        f.write("};\n")


# ---------------------------------------------------------------------------
# Main generator
# ---------------------------------------------------------------------------

def generate_code_sv(blob: 'ProgramBlob', out_path: str, source_path: str):
    n_chunks, content = build_code_sv_entries(blob.code)
    filename = os.path.basename(out_path)
    header = LICENSE_HEADER.format(
        filename=filename,
        source=os.path.basename(source_path),
        isa=blob.isa_name(),
        code_bytes=len(blob.code),
        bitmask_bytes=len(blob.bitmask),
    )
    body = CODE_ROM_TEMPLATE.format(
        rom_size=n_chunks,
        content=content,
    )
    with open(out_path, 'w') as f:
        f.write(header)
        f.write(body)
    print(f"  Wrote {out_path}  ({n_chunks} x 128-bit chunks, "
          f"{n_chunks * 16} bytes code space)")


def generate_bitmask_sv(blob: 'ProgramBlob', out_path: str, source_path: str):
    n_words, content = build_bitmask_sv_entries(blob.code, blob.bitmask)
    filename = os.path.basename(out_path)
    header = LICENSE_HEADER.format(
        filename=filename,
        source=os.path.basename(source_path),
        isa=blob.isa_name(),
        code_bytes=len(blob.code),
        bitmask_bytes=len(blob.bitmask),
    )
    body = BITMASK_ROM_TEMPLATE.format(
        rom_size=n_words,
        content=content,
    )
    with open(out_path, 'w') as f:
        f.write(header)
        f.write(body)
    print(f"  Wrote {out_path}  ({n_words} x 32-bit bitmask words, "
          f"covers {n_words * 32} code bytes)")


def generate_combined_sv(blob: 'ProgramBlob', out_path: str, source_path: str):
    n_chunks, code_content = build_code_sv_entries(blob.code)
    n_words, bm_content = build_bitmask_sv_entries(blob.code, blob.bitmask)
    filename = os.path.basename(out_path)
    header = LICENSE_HEADER.format(
        filename=filename,
        source=os.path.basename(source_path),
        isa=blob.isa_name(),
        code_bytes=len(blob.code),
        bitmask_bytes=len(blob.bitmask),
    )
    code_body = CODE_ROM_TEMPLATE.format(
        rom_size=n_chunks,
        content=code_content,
    )
    bm_body = BITMASK_ROM_TEMPLATE.format(
        rom_size=n_words,
        content=bm_content,
    )
    with open(out_path, 'w') as f:
        f.write(header)
        f.write(code_body)
        f.write('\n')
        f.write(bm_body)
    print(f"  Wrote {out_path}  (combined: {n_chunks} code chunks, "
          f"{n_words} bitmask words)")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(
        description='Convert a .polkavm blob to SV ROM files for the PVM frontend.')
    p.add_argument('--in', dest='blob_path', required=True,
                   metavar='BLOB',
                   help='Input .polkavm blob file')
    p.add_argument('--out-code', dest='out_code', default=None,
                   metavar='FILE',
                   help='Output path for bootrom_code_64.sv')
    p.add_argument('--out-bitmask', dest='out_bitmask', default=None,
                   metavar='FILE',
                   help='Output path for bootrom_bitmask_64.sv')
    p.add_argument('--out-combined', dest='out_combined', default=None,
                   metavar='FILE',
                   help='Output path for combined SV file (overrides --out-code/--out-bitmask)')
    p.add_argument('--out-header', dest='out_header', default=None,
                   metavar='BASE',
                   help='Output base path for .h simulation header (no extension)')
    p.add_argument('--verbose', '-v', action='store_true',
                   help='Print blob summary')
    # Legacy positional: gen_pvm_rom.py blob.polkavm [code.sv] [bitmask.sv]
    p.add_argument('positional', nargs='*', metavar='ARG',
                   help='Positional: blob [code_out] [bitmask_out]')
    return p.parse_args()


def main():
    args = parse_args()

    # Support legacy positional invocation:
    #   gen_pvm_rom.py blob.polkavm bootrom_code_64.sv bootrom_bitmask_64.sv
    blob_path = args.blob_path
    out_code = args.out_code
    out_bitmask = args.out_bitmask

    if args.positional:
        if len(args.positional) >= 1 and blob_path is None:
            blob_path = args.positional[0]
        if len(args.positional) >= 2 and out_code is None:
            out_code = args.positional[1]
        if len(args.positional) >= 3 and out_bitmask is None:
            out_bitmask = args.positional[2]

    if blob_path is None:
        print("error: --in <blob.polkavm> is required", file=sys.stderr)
        sys.exit(1)

    print(f"Reading {blob_path} ...")
    try:
        blob = ProgramBlob.from_file(blob_path)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    if args.verbose:
        print(blob.summary())

    # Derive default output paths from blob path if not specified
    base = os.path.splitext(blob_path)[0]

    if args.out_combined:
        generate_combined_sv(blob, args.out_combined, blob_path)
    else:
        code_out = out_code if out_code else base + '_code_64.sv'
        bm_out = out_bitmask if out_bitmask else base + '_bitmask_64.sv'
        generate_code_sv(blob, code_out, blob_path)
        generate_bitmask_sv(blob, bm_out, blob_path)

    if args.out_header:
        generate_h(args.out_header, blob)
        print(f"  Wrote {args.out_header}.h")

    print(f"Done.  Code: {len(blob.code)} bytes, "
          f"Bitmask: {len(blob.bitmask)} bytes, "
          f"ISA: {blob.isa_name()}")


if __name__ == '__main__':
    main()
