; JAM v1 assembly — ecalli smoke test (sub-phase 8)
;
; Program layout:
;   1. Set pevent_table_base CSR to point at handler_table (3 entries).
;   2. Load known register values into A0-A2.
;   3. Fire "ecalli imm=1" from caller context (U-mode equivalent).
;   4. The CSR regfile FSM redirects to handler_entry (table[1]).
;   5. Handler verifies A0-A2 are unchanged, writes sentinel to A3.
;   6. Handler fires "ecalli imm=0xFFFFFFFF" (mode_return).
;   7. Execution resumes at the instruction after the original ecalli.
;   8. Verify A3 == sentinel value and A0-A2 still match.
;   9. Trap (halt).
;
; Register use:
;   A0 = 0xDEAD_BEEF  (preserved across ecalli round-trip)
;   A1 = 0x1234_5678  (preserved across ecalli round-trip)
;   A2 = 0xCAFE_F00D  (preserved across ecalli round-trip)
;   A3 = written by handler to 0x5AFE_CAFE (verify on return)
;
; NOTE: This is a pseudo-assembly description of the test intent.
; The actual encoding must be produced by polkatool with JAM v1 input.
; For the checker.sv testbench the program blob is pre-encoded below
; as raw hex bytes matching the JAM v1 binary format.
;
; Assembled encoding (2-byte ecalli, 6-byte load_imm, etc.):
;   See checker.sv for the raw blob used in simulation.

; ---------------------------------------------------------------------------
; Handler table (3 x 8-byte entries at a known address)
; ---------------------------------------------------------------------------
; handler_table:
;   entry[0]:  <address of handler_entry_0>   ; not used in this test
;   entry[1]:  <address of handler_entry_1>   ; used by ecalli imm=1
;   entry[2]:  <address of handler_entry_2>   ; not used in this test

; ---------------------------------------------------------------------------
; _start: main program
; ---------------------------------------------------------------------------
; _start:
;   ; Write pevent_table_base = &handler_table
;   ecalli imm=0xFFFFFFFD  ; write_csr sentinel (sub-phase 7 path)
;                           ; rd=PVM_CSR_PEVENT_TABLE_BASE, rs1=handler_table_addr
;
;   ; Load test values
;   load_imm A0, 0xDEADBEEF
;   load_imm A1, 0x12345678
;   load_imm A2, 0xCAFEF00D
;
;   ; Fire ecalli with imm=1 -> dispatch to handler_table[1]
;   ecalli imm=1
;
;   ; --- RETURN POINT ---
;   ; Verify A3 was written by handler
;   ; (checker.sv reads register file directly after trap)
;   trap

; ---------------------------------------------------------------------------
; handler_entry_1: S-mode handler
; ---------------------------------------------------------------------------
; handler_entry_1:
;   ; A0-A2 should be unchanged (register file preserved by hardware)
;   ; Write sentinel to A3
;   load_imm A3, 0x5AFECAFE
;
;   ; Return to caller via mode_return sentinel
;   ecalli imm=0xFFFFFFFF

; ---------------------------------------------------------------------------
; JAM v1 binary encoding reference (for checker.sv)
; ---------------------------------------------------------------------------
; The checker.sv testbench uses a pre-encoded blob rather than calling
; polkatool at build time (polkatool may not be available in all CI envs).
; The blob was hand-encoded per JAM v1 spec (graypaper §pvm:81-99):
;
;   Byte offset | Encoding | Instruction
;   ------------|----------|-----------------------------
;   0x00        | 0x0A 0x01 0x00 0x00 0x00 | ecalli imm=0 (trap, placeholder)
;   ... (full blob in checker.sv)
