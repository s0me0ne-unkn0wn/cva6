# SPI Flash programming for Genesys 2 — following XAPP586 exactly
# Flash: Spansion S25FL256S, Interface: SPIx4
#
# Prerequisites: generate .bin from .bit first (run from cva6/ dir):
#   source ~/Vivado/2025.2/Vivado/settings64.sh
#   vivado -mode tcl -nojournal -nolog -notrace
#   write_cfgmem -format bin -interface SPIx4 -size 32 \
#       -loadbit "up 0x0 corev_apu/fpga/work-fpga/ariane_xilinx.bit" \
#       -file corev_apu/fpga/work-fpga/ariane_xilinx.bin -force
#   exit
#
# Then program flash (run from cva6/ dir):
#   vivado -mode batch -source scripts/program_spi_flash.tcl

set programming_files {corev_apu/fpga/work-fpga/ariane_xilinx.bin}

open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target [lindex [get_hw_targets -quiet "*200300BD82D8B*"] 0]
open_hw_target

current_hw_device [lindex [get_hw_devices] 0]

# List available S25FL256 parts to find exact name
puts "=== Available S25FL256 cfgmem parts ==="
set all_parts [get_cfgmem_parts {s25fl256*}]
foreach p $all_parts {
    puts "  $p"
}

# Use the SPIx4 variant
set my_mem_device [lindex [get_cfgmem_parts {s25fl256sxxxxxx0-spi-x1_x2_x4}] 0]
if {$my_mem_device eq ""} {
    puts "WARNING: Exact part not found, trying broader match..."
    set my_mem_device [lindex [get_cfgmem_parts {s25fl256*-spi-x1_x2_x4}] 0]
}
if {$my_mem_device eq ""} {
    puts "WARNING: SPIx4 not found, trying x1 only..."
    set my_mem_device [lindex [get_cfgmem_parts {s25fl256*}] 0]
}
puts "Selected flash part: $my_mem_device"

# Create cfgmem object
set my_hw_cfgmem [create_hw_cfgmem -hw_device \
    [lindex [get_hw_devices] 0] -mem_dev $my_mem_device]

# Set properties per XAPP586
set_property PROGRAM.ADDRESS_RANGE {use_file} $my_hw_cfgmem
set_property PROGRAM.FILES $programming_files $my_hw_cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $my_hw_cfgmem

# Program FPGA with internal SPI proxy bitstream
puts "Programming FPGA with SPI proxy..."
program_hw_devices [lindex [get_hw_devices] 0]

# Set programming options
set_property PROGRAM.BLANK_CHECK 0 $my_hw_cfgmem
set_property PROGRAM.ERASE 1 $my_hw_cfgmem
set_property PROGRAM.CFG_PROGRAM 1 $my_hw_cfgmem
set_property PROGRAM.VERIFY 1 $my_hw_cfgmem

# Program flash
puts "Programming SPI flash..."
program_hw_cfgmem -hw_cfgmem $my_hw_cfgmem

puts "=== DONE ==="
close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
