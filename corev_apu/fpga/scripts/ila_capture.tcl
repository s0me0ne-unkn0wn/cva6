# ============================================================================
# ila_capture.tcl  --  hw_manager (no-GUI) ILA arm + capture for the PVM hang
# ============================================================================
# RUN FROM the cva6/ repo root (paths below are relative to it), e.g.:
#   source ~/Vivado/2025.2/Vivado/settings64.sh
#   vivado -mode tcl -nojournal -nolog \
#          -source corev_apu/fpga/scripts/ila_capture.tcl -tclargs arm
#
# Drives the ILA built into ariane_xilinx.bit by debug_insert.tcl, over the same
# hw_server/JTAG path program_bit.tcl uses. TWO phases (pick with -tclargs):
#
#   PHASE 1 (arm, free-running):  BEFORE the parent UART-loads OpenSBI
#     ... -source corev_apu/fpga/scripts/ila_capture.tcl -tclargs arm
#   ...then the parent paced-sends the blob; OpenSBI runs + hangs ("BSH" / "B")...
#
#   PHASE 2 (dump, AFTER the hang is confirmed on UART):
#     ... -source corev_apu/fpga/scripts/ila_capture.tcl -tclargs dump
#   -> stops the ILA, uploads the captured window, writes:
#        /tmp/pvm_ila_capture.csv   (one row per sample, all probes -- machine readable)
#        /tmp/pvm_ila_capture.txt   (human dump of the same)
#
# Because the hang is PERSISTENT, a free-running always-trigger captures the
# steady-state stall: at dump time the ILA's circular buffer holds the last
# <depth> core-clock cycles, which (since the PVM-pc has stopped) ARE the
# wedged state -- exactly the stuck FSM / handshake we want to see.
#
# OPTIONAL smarter trigger (PHASE 1b): trigger when the PVM is RUNNING but a
# DRAM fetch beat is waiting on rvalid (a fetch-stall). Pass `armstall`.
# ============================================================================

set phase "arm"
if {$::argc >= 1} { set phase [lindex $::argv 0] }

# The probe map (.ltx) lives next to the .bit (relative to the cva6/ root).
set ltx_file  "corev_apu/fpga/work-fpga/ariane_xilinx.ltx"
file mkdir /home/claude/pvm/artifacts/ila
set out_csv   "/home/claude/pvm/artifacts/ila/pvm_ila_capture.csv"     ;# NOT /tmp (tmp-cleaner)
set out_txt   "/home/claude/pvm/artifacts/ila/pvm_ila_capture.txt"

# ---- connect (same target-finding path as program_bit.tcl) -----------------
open_hw_manager
connect_hw_server
set target [lindex [get_hw_targets -quiet "*200300BD82D8B*"] 0]
if {$target eq ""} { set target [lindex [get_hw_targets -quiet] end] }
puts "\[ila\] target: $target"
open_hw_target $target
set dev [lindex [get_hw_devices -quiet] 0]
current_hw_device $dev
puts "\[ila\] device: $dev"

# Associate the probe map so get_hw_ilas/get_hw_probes resolve names. We do NOT
# re-program the device here -- the parent already flashed + UART-loaded; a
# re-program would wipe the running OpenSBI. We only refresh to attach the ILA.
if {[file exists $ltx_file]} {
    set_property PROBES.FILE        $ltx_file $dev
    set_property FULL_PROBES.FILE   $ltx_file $dev
    puts "\[ila\] attached probe map $ltx_file"
} else {
    puts "\[ila\] WARNING: $ltx_file not found; probe names may show as probeN."
}
refresh_hw_device -quiet -update_hw_probes true $dev

set ila [lindex [get_hw_ilas -quiet] 0]
if {$ila eq ""} {
    puts "\[ila\] ERROR: no hw_ila found on the device. Was the .bit built with PVM_ILA=1? Aborting."
    catch {disconnect_hw_server}
    exit 1
}
puts "\[ila\] using ILA: $ila"

proc list_probe_names {ila} {
    set names {}
    foreach p [get_hw_probes -quiet -of_objects [get_hw_ilas $ila]] {
        lappend names [get_property NAME $p]
    }
    return $names
}

if {$phase eq "arm" || $phase eq "armstall" || $phase eq "armexit"} {
    # -------- PHASE 1: arm a free-running (or stall-triggered) capture -------
    # Keep the most recent <depth> cycles ending at the trigger (position 0 =
    # trigger at the start; for a persistent stall the whole window is the stall).
    set_property CONTROL.TRIGGER_POSITION 0 [get_hw_ilas $ila]
    set_property CONTROL.WINDOW_COUNT     1 [get_hw_ilas $ila]

    if {$phase eq "armexit"} {
        # armexit (B2 host-resume deadlock, 2026-08-28): trigger on the FIRST host-boundary
        # exit -- dbg_pvm_active is 1 for the whole kernel boot until the GROW ecalli, so a
        # plain ==0 compare fires exactly there. Trigger at 1/4 of the window: 2048 cycles of
        # guest before the exit + 6144 cycles of host code (a dozen instructions) and the wedge.
        set_property CONTROL.CAPTURE_MODE  ALWAYS     [get_hw_ilas $ila]
        set_property CONTROL.TRIGGER_MODE  BASIC_ONLY [get_hw_ilas $ila]
        set_property CONTROL.TRIGGER_POSITION 2048    [get_hw_ilas $ila]
        set aprobe [get_hw_probes -quiet "*dbg_pvm_active*" -of_objects [get_hw_ilas $ila]]
        if {[llength $aprobe] == 0} { puts "\[ila\] ERROR: dbg_pvm_active probe not found"; catch {disconnect_hw_server}; exit 1 }
        foreach p [get_hw_probes -quiet -of_objects [get_hw_ilas $ila]] {
            set w [get_property WIDTH $p]
            set_property TRIGGER_COMPARE_VALUE "eq${w}'hX" $p
        }
        set_property TRIGGER_COMPARE_VALUE "eq1'b0" [lindex $aprobe 0]
        puts "\[ila\] armed EXIT trigger (dbg_pvm_active==0, position 2048)."
    } elseif {$phase eq "arm"} {
        # Trigger = ALWAYS (free-running): every probe compares to "don't care".
        set_property CONTROL.CAPTURE_MODE  ALWAYS     [get_hw_ilas $ila]
        set_property CONTROL.TRIGGER_MODE  BASIC_ONLY [get_hw_ilas $ila]
        foreach p [get_hw_probes -quiet -of_objects [get_hw_ilas $ila]] {
            set w [get_property WIDTH $p]
            set_property TRIGGER_COMPARE_VALUE "eq${w}'hX" $p
        }
        puts "\[ila\] armed FREE-RUNNING (trigger=always, capture=always)."
    } else {
        # armstall: trigger on a fetch-stall. running_q==1 AND d_state_q==D_WAIT(3)
        # = a DRAM beat awaiting rvalid that never returns. Names come from the
        # .ltx (the submodule reg names). If absent, falls back to free-running.
        set_property CONTROL.CAPTURE_MODE  ALWAYS     [get_hw_ilas $ila]
        set_property CONTROL.TRIGGER_MODE  BASIC_ONLY [get_hw_ilas $ila]
        set rprobe [get_hw_probes -quiet "*running_q*" -of_objects [get_hw_ilas $ila]]
        set dprobe [get_hw_probes -quiet "*d_state_q*" -of_objects [get_hw_ilas $ila]]
        if {[llength $rprobe] > 0 && [llength $dprobe] > 0} {
            set_property TRIGGER_COMPARE_VALUE "eq1'b1"   [lindex $rprobe 0]
            set_property TRIGGER_COMPARE_VALUE "eq3'b011" [lindex $dprobe 0]
            puts "\[ila\] armed STALL trigger (running_q==1 && d_state_q==D_WAIT)."
        } else {
            puts "\[ila\] stall-probe names not found; falling back to free-running always."
        }
    }
    run_hw_ila -quiet [get_hw_ilas $ila]
    puts "\[ila\] ARMED. Probes: [list_probe_names $ila]"
    puts "\[ila\] Now paced-send the OpenSBI blob, let it hang, then re-run with -tclargs dump."
    # Closing the hw_manager does NOT stop the armed ILA in the fabric (it keeps
    # sampling). Disconnect cleanly so the parent's UART send is unaffected.
    catch {disconnect_hw_server}
    catch {close_hw_manager}
    exit 0
}

if {$phase eq "dump"} {
    # -------- PHASE 2: stop, upload, and dump --------------------------------
    puts "\[ila\] uploading the captured window..."
    upload_hw_ila_data -quiet [get_hw_ilas $ila]
    set data [current_hw_ila_data]

    # Machine-readable CSV (all probes, all samples).
    write_hw_ila_data -force -csv_file $out_csv $data
    puts "\[ila\] wrote CSV: $out_csv"

    # Human-readable text table (sample x probe, hex).
    set probes [get_hw_probes -quiet -of_objects [get_hw_ilas $ila]]
    set nsamp  [get_property CORE.DATA_DEPTH [get_hw_ilas $ila]]
    set fh [open $out_txt w]
    puts $fh "# PVM ILA capture -- probe values per sample (hex). $nsamp samples."
    puts $fh "sample\t[join [list_probe_names $ila] \t]"
    for {set s 0} {$s < $nsamp} {incr s} {
        set row $s
        foreach p $probes {
            set v [get_hw_probe_value -quiet $p -radix hex -sample_index $s $data]
            append row "\t$v"
        }
        puts $fh $row
    }
    close $fh
    puts "\[ila\] wrote text dump: $out_txt ($nsamp samples)."

    catch {disconnect_hw_server}
    catch {close_hw_manager}
    exit 0
}

puts "\[ila\] unknown phase '$phase' (use: arm | armstall | dump)."
catch {disconnect_hw_server}
exit 1
