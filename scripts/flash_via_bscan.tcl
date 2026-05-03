# SPI Flash programmer via BSCAN USER1 + Vivado JTAG
# Programs S25FL256S on Genesys 2 through bscan_spi proxy bitstream
#
# NOTE: This is a reference/backup script. The recommended approach is
# scripts/program_spi_flash.tcl (XAPP586 flow) which handles all
# BSCAN details internally via Vivado's program_hw_cfgmem.
#
# This script requires a bscan_spi proxy bitstream (e.g. from quartiq).
# Protocol: DR = [marker=1][32-bit length MSB-first][SPI data MSB-first]
# TDO captures MISO with 1-bit offset (captured 1 cycle late)
#
# Run from cva6/ dir:
#   source ~/Vivado/2025.2/Vivado/settings64.sh
#   vivado -mode batch -source scripts/flash_via_bscan.tcl

# ============ Configuration ============

set bin_file "corev_apu/fpga/work-fpga/ariane_xilinx.bin"
set bscan_proxy "scripts/bscan_spi_xc7k325t.bit"

# ============ BSCAN SPI primitives ============

proc set_bit {dataVar pos val} {
    upvar $dataVar d
    set byte_idx [expr {$pos / 8}]
    set bit_idx [expr {$pos % 8}]
    if {$val} {
        lset d $byte_idx [expr {[lindex $d $byte_idx] | (1 << $bit_idx)}]
    }
}

proc get_bit {data pos} {
    set byte_idx [expr {$pos / 8}]
    set bit_idx [expr {$pos % 8}]
    return [expr {([lindex $data $byte_idx] >> $bit_idx) & 1}]
}

# Convert hex string (MSB-first) to byte list (LSB-first)
proc hex_to_bytes {hex total_bytes} {
    set hex_clean [string trimleft $hex "0x"]
    while {[string length $hex_clean] < [expr {$total_bytes * 2}]} {
        set hex_clean "0${hex_clean}"
    }
    set bytes [list]
    for {set i 0} {$i < $total_bytes} {incr i} {
        set idx [expr {[string length $hex_clean] - 2 - $i * 2}]
        if {$idx < 0} {
            lappend bytes 0
        } else {
            lappend bytes [scan [string range $hex_clean $idx [expr {$idx + 1}]] %x]
        }
    }
    return $bytes
}

# Build DR shift data for a SPI transaction
# Returns: [total_bits, tdi_hex_string]
proc build_spi_dr {cmd_byte addr_bytes write_bytes read_count} {
    set cmd_bits 8
    set addr_bits [expr {[llength $addr_bytes] * 8}]
    set write_bits [expr {[llength $write_bytes] * 8}]
    set read_bits [expr {$read_count * 8}]
    set spi_bits [expr {$cmd_bits + $addr_bits + $write_bits + $read_bits}]

    # +1 for marker, +32 for length, +1 extra for TDO capture offset
    set total_bits [expr {1 + 32 + $spi_bits + 1}]
    set total_bytes [expr {($total_bits + 7) / 8}]

    set data [list]
    for {set i 0} {$i < $total_bytes} {incr i} { lappend data 0 }

    # Bit 0: marker = 1
    set_bit data 0 1

    # Bits 1-32: SPI bit count, MSB first
    for {set i 0} {$i < 32} {incr i} {
        set_bit data [expr {1 + $i}] [expr {($spi_bits >> (31 - $i)) & 1}]
    }

    # Bit 33+: SPI command byte, MSB first
    set pos 33
    for {set i 0} {$i < 8} {incr i} {
        set_bit data $pos [expr {($cmd_byte >> (7 - $i)) & 1}]
        incr pos
    }

    # Address bytes, MSB first per byte
    foreach byte $addr_bytes {
        for {set i 0} {$i < 8} {incr i} {
            set_bit data $pos [expr {($byte >> (7 - $i)) & 1}]
            incr pos
        }
    }

    # Write data bytes, MSB first per byte
    foreach byte $write_bytes {
        for {set i 0} {$i < 8} {incr i} {
            set_bit data $pos [expr {($byte >> (7 - $i)) & 1}]
            incr pos
        }
    }

    # Convert to hex string (MSB byte first)
    set hex ""
    for {set i [expr {$total_bytes - 1}]} {$i >= 0} {incr i -1} {
        append hex [format %02x [lindex $data $i]]
    }

    # Trim to exact number of hex digits Vivado expects (ceil(total_bits/4))
    set hex_len [expr {($total_bits + 3) / 4}]
    if {[string length $hex] > $hex_len} {
        set hex [string range $hex end-[expr {$hex_len - 1}] end]
    }

    return [list $total_bits $hex]
}

# Extract read bytes from TDO response
# Response starts at bit (33 + cmd_bits + addr_bits + write_bits + 1_offset)
proc extract_response {tdo_hex total_bits skip_bytes read_count} {
    set total_bytes [expr {($total_bits + 7) / 8}]
    set bytes [hex_to_bytes $tdo_hex $total_bytes]

    # Response starts after: 1 marker + 32 length + skip_bytes*8 + 1 TDO offset
    set start_bit [expr {33 + $skip_bytes * 8 + 1}]

    set result [list]
    for {set n 0} {$n < $read_count} {incr n} {
        set val 0
        for {set b 0} {$b < 8} {incr b} {
            set bit_pos [expr {$start_bit + $n * 8 + $b}]
            set bit_val [get_bit $bytes $bit_pos]
            set val [expr {$val | ($bit_val << (7 - $b))}]
        }
        lappend result $val
    }
    return $result
}

# Execute a SPI command and return read data
proc spi_xfer {cmd addr_bytes write_bytes read_count} {
    set dr [build_spi_dr $cmd $addr_bytes $write_bytes $read_count]
    set total_bits [lindex $dr 0]
    set tdi_hex [lindex $dr 1]

    set tdo [scan_dr_hw_jtag $total_bits -tdi $tdi_hex]

    if {$read_count > 0} {
        set skip [expr {1 + [llength $addr_bytes] + [llength $write_bytes]}]
        return [extract_response $tdo $total_bits $skip $read_count]
    }
    return {}
}

# SPI flash commands
proc flash_read_jedec {} {
    return [spi_xfer 0x9F {} {} 3]
}

proc flash_read_status {} {
    set resp [spi_xfer 0x05 {} {} 1]
    return [lindex $resp 0]
}

proc flash_write_enable {} {
    spi_xfer 0x06 {} {} 0
}

proc flash_sector_erase {addr} {
    set a2 [expr {($addr >> 16) & 0xFF}]
    set a1 [expr {($addr >> 8) & 0xFF}]
    set a0 [expr {$addr & 0xFF}]
    spi_xfer 0xD8 [list $a2 $a1 $a0] {} 0
}

proc flash_wait_ready {{timeout_ms 30000}} {
    set start [clock milliseconds]
    while {1} {
        set sr [flash_read_status]
        if {($sr & 0x01) == 0} { return 1 }
        if {[clock milliseconds] - $start > $timeout_ms} {
            puts "ERROR: Flash timeout waiting for ready"
            return 0
        }
        after 50
    }
}

proc flash_page_program {addr data_bytes} {
    set a2 [expr {($addr >> 16) & 0xFF}]
    set a1 [expr {($addr >> 8) & 0xFF}]
    set a0 [expr {$addr & 0xFF}]
    spi_xfer 0x02 [list $a2 $a1 $a0] $data_bytes 0
}

# ============ Main flash programming logic ============

puts "=== Genesys 2 SPI Flash Programmer via BSCAN ==="

open_hw_manager
connect_hw_server

set target [lindex [get_hw_targets -quiet "*200300BD82D8B*"] 0]
puts "Target: $target"
open_hw_target $target

set dev [lindex [get_hw_devices -quiet] 0]
current_hw_device $dev

# Program FPGA with bscan_spi proxy
puts "Loading bscan_spi proxy..."
set_property PROGRAM.FILE $bscan_proxy $dev
program_hw_devices $dev
puts "Proxy loaded"
close_hw_target

# Reopen in JTAG mode
open_hw_target $target -jtag_mode true

# Select USER1 IR (0x02 for 7-series)
scan_ir_hw_jtag 6 -tdi 02

# Read and verify JEDEC ID
puts "\nReading JEDEC ID..."
set jedec [flash_read_jedec]
set mfr [lindex $jedec 0]
set mtype [lindex $jedec 1]
set cap [lindex $jedec 2]
puts "  Manufacturer: [format 0x%02X $mfr]"
puts "  Memory Type:  [format 0x%02X $mtype]"
puts "  Capacity:     [format 0x%02X $cap]"

if {$mfr != 0x01 || $cap < 0x18} {
    puts "ERROR: Expected Spansion S25FL256S (0x01, 0x02, 0x19)"
    puts "       Got: [format 0x%02X $mfr], [format 0x%02X $mtype], [format 0x%02X $cap]"
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    exit 1
}
puts "S25FL256S detected!"

# Read the binary file
puts "\nReading $bin_file..."
set fp [open $bin_file rb]
set bin_data [read $fp]
close $fp
set file_size [string length $bin_data]
puts "  File size: $file_size bytes ([expr {$file_size / 1024}] KB)"

# Calculate sectors (64KB each)
set sector_size 65536
set page_size 256
set num_sectors [expr {($file_size + $sector_size - 1) / $sector_size}]
set num_pages [expr {($file_size + $page_size - 1) / $page_size}]
puts "  Sectors to erase: $num_sectors"
puts "  Pages to program: $num_pages"

# Phase 1: Erase sectors
puts "\n=== Phase 1: Erasing $num_sectors sectors ==="
set erase_start [clock seconds]

for {set s 0} {$s < $num_sectors} {incr s} {
    set addr [expr {$s * $sector_size}]
    if {$s % 10 == 0 || $s == $num_sectors - 1} {
        puts "  Erasing sector $s/$num_sectors (addr [format 0x%06X $addr])..."
    }

    # Re-select USER1 before each operation
    scan_ir_hw_jtag 6 -tdi 02

    flash_write_enable
    scan_ir_hw_jtag 6 -tdi 02
    flash_sector_erase $addr
    scan_ir_hw_jtag 6 -tdi 02
    if {![flash_wait_ready 60000]} {
        puts "ERROR: Erase timeout at sector $s"
        exit 1
    }
}

set erase_time [expr {[clock seconds] - $erase_start}]
puts "  Erase complete in ${erase_time}s"

# Phase 2: Program pages
puts "\n=== Phase 2: Programming $num_pages pages ==="
set prog_start [clock seconds]

for {set p 0} {$p < $num_pages} {incr p} {
    set addr [expr {$p * $page_size}]
    set offset [expr {$p * $page_size}]
    set remaining [expr {$file_size - $offset}]
    set chunk_size [expr {min($page_size, $remaining)}]

    # Extract page data
    set page_data [list]
    for {set i 0} {$i < $chunk_size} {incr i} {
        lappend page_data [scan [string index $bin_data [expr {$offset + $i}]] %c]
    }
    # Pad to page size with 0xFF
    while {[llength $page_data] < $page_size} {
        lappend page_data 0xFF
    }

    if {$p % 100 == 0 || $p == $num_pages - 1} {
        set pct [expr {$p * 100 / $num_pages}]
        puts "  Programming page $p/$num_pages (${pct}%, addr [format 0x%06X $addr])..."
    }

    scan_ir_hw_jtag 6 -tdi 02
    flash_write_enable
    scan_ir_hw_jtag 6 -tdi 02
    flash_page_program $addr $page_data
    scan_ir_hw_jtag 6 -tdi 02
    if {![flash_wait_ready 5000]} {
        puts "ERROR: Program timeout at page $p"
        exit 1
    }
}

set prog_time [expr {[clock seconds] - $prog_start}]
puts "  Programming complete in ${prog_time}s"
puts "\n=== Flash programming SUCCESS ==="
puts "Total time: [expr {$erase_time + $prog_time}]s"

close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
