# Volatile JTAG programming for Genesys 2
# Programs FPGA with .bit file (lost on power cycle)
# Run from cva6/ directory:
#   source ~/Vivado/2025.2/Vivado/settings64.sh
#   vivado -mode tcl -nojournal -nolog -source scripts/program_bit.tcl

puts "=== Programming Genesys 2 with ariane_xilinx.bit ==="
open_hw_manager
connect_hw_server

# Use the JTAG target directly (the one ending with B is the JTAG channel)
set target [lindex [get_hw_targets -quiet "*200300BD82D8B*"] 0]
if {$target eq ""} {
    # Try to find any target with a device
    set target [lindex [get_hw_targets -quiet] end]
}
puts "Using target: $target"

open_hw_target $target
set devices [get_hw_devices -quiet]
puts "Devices: $devices"

set dev [lindex $devices 0]
puts "Programming device: $dev"

current_hw_device $dev
set_property PROGRAM.FILE {corev_apu/fpga/work-fpga/ariane_xilinx.bit} $dev
program_hw_devices $dev

puts "=== Programming complete! ==="

close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
