# Program the PVM bitstream on Genesys2 (xc7k325t). Robust target pick: a stale
# hw_server can list a phantom sibling target with no devices (lindex 0 then fails).
# Usage: vivado -nojournal -mode batch -source prog_bit.tcl -tclargs /path/to.bit
set bitfile [lindex $argv 0]
if {$bitfile eq ""} { set bitfile /home/claude/pvm/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit }
open_hw_manager
connect_hw_server -url localhost:3121
set tgts [get_hw_targets]
puts "HW_TARGETS: $tgts"
set found 0
foreach t $tgts {
  if {[catch {open_hw_target $t} err]} {
    # A failed open of the phantom sibling can leave the REAL target auto-opened: Vivado then
    # reports "Target is already opened" for it -- that is a success, not a reason to skip.
    if {![string match -nocase "*already opened*" $err]} { puts "skip $t: $err"; continue }
    # The failed open of the phantom sibling auto-opens the real target WITHOUT scanning its
    # chain (empty device list, refresh does not help). Close and re-open it cleanly.
    puts "already-open: $t -> close + clean re-open"
    catch {current_hw_target $t}
    catch {close_hw_target}
    if {[catch {open_hw_target $t} err2]} { puts "skip $t after re-open: $err2"; continue }
  }
  set devs [get_hw_devices -quiet xc7k325t_0]
  if {[llength $devs] > 0} { set found 1; puts "USING_TARGET: $t"; break }
  catch {close_hw_target}
}
if {!$found} { puts "NO_K325T_TARGET"; exit 1 }
current_hw_device [get_hw_devices xc7k325t_0]
set_property PROGRAM.FILE $bitfile [get_hw_devices xc7k325t_0]
program_hw_devices [get_hw_devices xc7k325t_0]
refresh_hw_device [lindex [get_hw_devices xc7k325t_0] 0]
puts "PROGRAM_DONE_OK"
