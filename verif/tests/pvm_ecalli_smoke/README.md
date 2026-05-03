# pvm_ecalli_smoke — Sub-phase 8 ecalli FSM checker

Unit-level smoke test for the `pvm_csr_regfile` ecalli FSM introduced in
sub-phase 8.  Tests all four FSM states, both sentinel paths, and the ADR-5
round-trip latency budget.

## What it tests

| Test | Covers |
|------|--------|
| 1    | `mode_return` sentinel (0xFFFFFFFF): IDLE→done in 1 combinatorial cycle |
| 2    | `read_csr` sentinel (0xFFFFFFFE): IDLE→done in 1 cycle; PC+2 redirect |
| 3    | Non-sentinel ecalli (imm=1): all 4 FSM states reachable; TABLE_READ 3-cycle wait; JUMPED emits correct handler address and U-mode priv |
| 4    | `mode_return` after dispatch: `pepc` (ecalli_pc+2) and `pstatus.MPP` correctly restored |

## FSM state reachability (sub-phase 8 result)

All four states reachable:

```
IDLE (0) -> DRAINED (1) -> TABLE_READ (2) -> JUMPED (3) -> IDLE (0)
```

DRAINED and JUMPED are 1-cycle transient states.  The TABLE_READ state holds
for 3 cycles (mock latency; see LSU integration gap note below).

## ADR-5 round-trip budget

Measured round-trip (ecalli_valid assertion to ecalli_done): **6 cycles**.

Budget: **≤ 25 cycles** (ADR-5).  Well within budget.

## LSU integration gap

The TABLE_READ state is supposed to perform a memory load of
`pevent_table_base + 8 * imm` to fetch the handler address from the event
table.  This requires an out-of-band dcache request that the CSR regfile
cannot issue directly — all three ex-stage dcache ports are used by the
LSU/PTW.

For MVP (sub-phase 8), the TABLE_READ state uses a 3-cycle mock timer and
returns `pevent_table_base + 8 * imm` directly as the redirect target
(treating the table as an offset map).  This is correct only when the handler
address equals exactly `pevent_table_base + 8 * imm`, which is trivially true
in the smoke test.

A follow-up (sub-phase 8.5 or sub-phase 9) must wire an actual dcache load
for the TABLE_READ path before real JAM v1 programs with non-trivial handler
tables can execute correctly.

## Running

```
cd verif/tests/pvm_ecalli_smoke
make sim
```

Requires: `verilator >= 5.x` in `PATH`.

## File list

| File | Description |
|------|-------------|
| `checker.sv` | Verilator testbench (FSM model + stimulus + assertions) |
| `hello.s` | JAM v1 assembly description of the smoke program intent |
| `Makefile` | Build and run via Verilator |
| `README.md` | This file |
