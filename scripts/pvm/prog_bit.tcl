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
  if {[catch {open_hw_target $t} err]} { puts "skip $t: $err"; continue }
  set devs [get_hw_devices -quiet xc7k325t_0]
  if {[llength $devs] > 0} { set found 1; puts "USING_TARGET: $t"; break }
  close_hw_target
}
if {!$found} { puts "NO_K325T_TARGET"; exit 1 }
current_hw_device [get_hw_devices xc7k325t_0]
set_property PROGRAM.FILE $bitfile [get_hw_devices xc7k325t_0]
program_hw_devices [get_hw_devices xc7k325t_0]
refresh_hw_device [lindex [get_hw_devices xc7k325t_0] 0]
puts "PROGRAM_DONE_OK"
