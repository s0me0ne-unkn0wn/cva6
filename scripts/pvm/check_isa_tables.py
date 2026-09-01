#!/usr/bin/env python3
"""B4 guard: the RTL opcode table (polkavm_pkg.sv) must match the ISA that polkatool
emits for this hardware (ISA_JamV1Privileged; userspace links with --instruction-set
jam_v1, a strict subset). The silent Latest64-vs-JamV1 skew in the unary group
(sign_extend_8 = 108 vs 107) cost a day of hush-math debugging (b4v5..b4v8):
polkatool's default is latest64, so EVERY polkatool link in this project must pass
--instruction-set jam_v1 (user) or jam_v1_privileged (kernel/SBI/U-Boot).
Usage: check_isa_tables.py [cva6_root] [polkavm_root]; exit 1 on any mismatch."""
import re, sys

cva6 = sys.argv[1] if len(sys.argv) > 1 else '/home/claude/pvm/cva6'
pvm  = sys.argv[2] if len(sys.argv) > 2 else '/home/claude/pvm/polkavm'
pkg = open(f'{cva6}/core/include/polkavm_pkg.sv').read()
rs  = open(f'{pvm}/crates/polkavm-common/src/program.rs').read()

rtl = {int(m.group(2)): m.group(1).lower()
       for m in re.finditer(r"PVM_OP_(\w+)\s*=\s*8'd(\d+)", pkg)}
sec = rs[rs.rindex('build_static_dispatch_table_jam_v1_privileged'):]
jam = {}
for m in re.finditer(r"^\s+(\w+)\s+=\s+(\d+),", sec, re.M):
    jam.setdefault(int(m.group(2)), m.group(1))

# pkg uses shortened names; compare squashed with the known abbreviations expanded
ALIAS = [('shlo_l','shift_logical_left'),('shlo_r','shift_logical_right'),
         ('shar_r','shift_arithmetic_right'),('div_u','div_unsigned'),('div_s','div_signed'),
         ('rem_u','rem_unsigned'),('rem_s','rem_signed'),('set_lt_u','set_less_than_unsigned'),
         ('set_lt_s','set_less_than_signed'),('set_gt_u','set_greater_than_unsigned'),
         ('set_gt_s','set_greater_than_signed'),('branch_ge_u','branch_greater_or_equal_unsigned'),
         ('branch_ge_s','branch_greater_or_equal_signed'),('branch_lt_u','branch_less_unsigned'),
         ('branch_lt_s','branch_less_signed'),('branch_le_u','branch_less_or_equal_unsigned'),
         ('branch_le_s','branch_less_or_equal_signed'),('branch_gt_u','branch_greater_unsigned'),
         ('branch_gt_s','branch_greater_signed'),('branch_ne','branch_not_eq'),
         ('store_imm_ind','store_imm_indirect'),('store_ind','store_indirect'),
         ('load_ind','load_indirect'),('load_imm_jump_ind','load_imm_and_jump_indirect'),
         ('load_imm_jump','load_imm_and_jump'),('jump_ind','jump_indirect'),
         ('neg_add_imm','negate_and_add_imm'),('cmov_iz','cmov_if_zero'),('cmov_nz','cmov_if_not_zero'),
         ('rot_l','rotate_left'),('rot_r_64_imm_alt','rotate_right_imm_alt_64'),
         ('rot_r_32_imm_alt','rotate_right_imm_alt_32'),('rot_r_64_imm','rotate_right_imm_64'),
         ('rot_r_32_imm','rotate_right_imm_32'),('rot_r','rotate_right'),
         ('and_inv','and_inverted'),('or_inv','or_inverted'),('max_u','maximum_unsigned'),
         ('min_u','minimum_unsigned'),('mul_upper_s_s','mul_upper_signed_signed'),
         ('mul_upper_u_u','mul_upper_unsigned_unsigned'),('mul_upper_s_u','mul_upper_signed_unsigned'),
         ('leading_zero_bits','count_leading_zero_bits'),('trailing_zero_bits','count_trailing_zero_bits'),
         ('reverse_bytes','reverse_byte'),('max','maximum'),('min','minimum')]
def canon(n):
    for a, b in ALIAS:
        if n == a or n.startswith(a + '_'):
            n = b + n[len(a):]
            break
    return n.replace('_', '')

bad = 0
for num in sorted(rtl):
    r, j = rtl[num], jam.get(num)
    if j is None:
        print(f"MISMATCH {num}: RTL has {r}, JamV1Privileged has nothing"); bad += 1
    elif canon(r) != j.lower().replace('_', ''):
        print(f"MISMATCH {num}: RTL {r} vs JamV1Privileged {j}"); bad += 1
missing = [n for n in ('sign_extend_8','sign_extend_16','zero_extend_16') if n not in jam.values()]
sys.exit(1 if bad or missing else print(f"OK: {len(rtl)} RTL opcodes match ISA_JamV1Privileged") or 0)
