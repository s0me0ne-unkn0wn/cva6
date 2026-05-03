#!/usr/bin/env python3
# alu_golden_extract.py — PVM ALU golden-value extractor (sub-phase 5)
#
# Invokes the Rust alu-golden-dump binary (tools/alu-golden-dump in the
# polkavm workspace) which assembles, runs in interpreter mode, and reads
# final register state for each PVM ALU test vector.
#
# Usage:
#   cd /home/claude/pvm/cva6
#   python3 verif/tb/alu_golden_extract.py [--polkavm-root PATH] [--out PATH]
#
# Outputs:
#   verif/tb/alu_golden.tsv  — TSV with columns:
#     op_name  rs1_hex  rs2_hex  imm_hex  expected_rd_hex
#   (all hex fields are 16 hex digits, no 0x prefix)
#
# The SV testbench (pvm_alu_tb.sv) reads this file via $readmemh (adapted).
#
# Requirements:
#   - Rust toolchain (cargo) available in PATH
#   - polkavm workspace already compiles (see tools/alu-golden-dump/)
#
# Copyright 2025 Parity Technologies Ltd.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0

import argparse
import os
import subprocess
import sys

DEFAULT_POLKAVM_ROOT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "..", "polkavm"
)
DEFAULT_OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "alu_golden.tsv"
)


def build_golden_dump(polkavm_root: str) -> str:
    """Build the alu-golden-dump binary.  Returns path to the built binary."""
    print(f"[golden_extract] Building alu-golden-dump in {polkavm_root} ...", flush=True)
    result = subprocess.run(
        ["cargo", "build", "-p", "alu-golden-dump", "--release"],
        cwd=polkavm_root,
        capture_output=False,
        text=True,
    )
    if result.returncode != 0:
        print("[golden_extract] ERROR: cargo build failed", file=sys.stderr)
        sys.exit(1)

    binary = os.path.join(polkavm_root, "target", "release", "alu-golden-dump")
    if not os.path.isfile(binary):
        # Try debug build path
        binary = os.path.join(polkavm_root, "target", "debug", "alu-golden-dump")
    if not os.path.isfile(binary):
        print(f"[golden_extract] ERROR: binary not found at {binary}", file=sys.stderr)
        sys.exit(1)
    return binary


def run_golden_dump(binary: str) -> list[str]:
    """Run the binary and return stdout lines (TSV rows)."""
    print(f"[golden_extract] Running {binary} ...", flush=True)
    result = subprocess.run(
        [binary],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"[golden_extract] ERROR: binary exited {result.returncode}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    return result.stdout.splitlines()


def validate_tsv(lines: list[str]) -> list[dict]:
    """Parse and validate TSV rows.  Returns list of row dicts."""
    if not lines:
        print("[golden_extract] ERROR: empty output from golden dump", file=sys.stderr)
        sys.exit(1)

    header = lines[0].split('\t')
    expected_header = ["op_name", "rs1_hex", "rs2_hex", "imm_hex", "expected_rd_hex"]
    if header != expected_header:
        print(f"[golden_extract] ERROR: unexpected TSV header: {header}", file=sys.stderr)
        sys.exit(1)

    rows = []
    for i, line in enumerate(lines[1:], start=2):
        if not line.strip():
            continue
        fields = line.split('\t')
        if len(fields) != 5:
            print(f"[golden_extract] ERROR: line {i} has {len(fields)} fields: {line!r}",
                  file=sys.stderr)
            sys.exit(1)
        op_name, rs1_hex, rs2_hex, imm_hex, rd_hex = fields
        # Validate all hex fields are 16-digit hex
        for fname, fval in [("rs1", rs1_hex), ("rs2", rs2_hex),
                             ("imm", imm_hex), ("rd", rd_hex)]:
            if len(fval) != 16 or not all(c in '0123456789abcdefABCDEF' for c in fval):
                print(f"[golden_extract] ERROR: line {i} {fname}={fval!r} not 16-hex",
                      file=sys.stderr)
                sys.exit(1)
        rows.append({
            "op_name":    op_name,
            "rs1_hex":    rs1_hex.lower(),
            "rs2_hex":    rs2_hex.lower(),
            "imm_hex":    imm_hex.lower(),
            "rd_hex":     rd_hex.lower(),
        })
    return rows


def write_tsv(rows: list[dict], out_path: str) -> None:
    """Write validated TSV to out_path."""
    with open(out_path, "w") as f:
        f.write("op_name\trs1_hex\trs2_hex\timm_hex\texpected_rd_hex\n")
        for row in rows:
            f.write(
                f"{row['op_name']}\t{row['rs1_hex']}\t{row['rs2_hex']}\t"
                f"{row['imm_hex']}\t{row['rd_hex']}\n"
            )
    print(f"[golden_extract] Wrote {len(rows)} rows to {out_path}", flush=True)


def print_sample(rows: list[dict], n: int = 5) -> None:
    """Print a few sample rows for sanity-checking."""
    print(f"\n[golden_extract] Sample rows (first {min(n, len(rows))}):")
    print(f"  {'op_name':<40} {'rs1':>16}  {'rs2':>16}  {'expected_rd':>16}")
    for row in rows[:n]:
        print(f"  {row['op_name']:<40} {row['rs1_hex']:>16}  {row['rs2_hex']:>16}  {row['rd_hex']:>16}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate PVM ALU golden values via polkavm interpreter"
    )
    parser.add_argument(
        "--polkavm-root",
        default=DEFAULT_POLKAVM_ROOT,
        help=f"Path to polkavm workspace root (default: {DEFAULT_POLKAVM_ROOT})"
    )
    parser.add_argument(
        "--out",
        default=DEFAULT_OUT,
        help=f"Output TSV path (default: {DEFAULT_OUT})"
    )
    parser.add_argument(
        "--binary",
        default=None,
        help="Path to pre-built alu-golden-dump binary (skip build step)"
    )
    args = parser.parse_args()

    polkavm_root = os.path.realpath(args.polkavm_root)
    if not os.path.isdir(polkavm_root):
        print(f"[golden_extract] ERROR: polkavm root not found: {polkavm_root}", file=sys.stderr)
        sys.exit(1)

    if args.binary:
        binary = args.binary
        print(f"[golden_extract] Using pre-built binary: {binary}", flush=True)
    else:
        binary = build_golden_dump(polkavm_root)

    lines = run_golden_dump(binary)
    rows = validate_tsv(lines)

    print(f"[golden_extract] Total golden rows: {len(rows)}")
    if len(rows) < 30:
        print(f"[golden_extract] WARNING: only {len(rows)} rows; expected >= 30",
              file=sys.stderr)

    print_sample(rows)

    # Also write a hex file that pvm_alu_tb.sv reads via $readmemh.
    # Format: each row is 5 * 64 bits = 320 bits = 80 hex nibbles, separated
    # by newlines.  The SV testbench reads 5 64-bit words per row.
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    write_tsv(rows, args.out)

    # Write companion hex file for $readmemh (op_index rs1 rs2 imm rd per row)
    # We use a simple integer op_index for the hex file (col 0 is op name in
    # TSV but can't go in $readmemh directly); SV TB reads the TSV natively
    # via file I/O instead.
    print("\n[golden_extract] Done.  Run pvm_alu_tb.sv to verify against hardware.")


if __name__ == "__main__":
    main()
