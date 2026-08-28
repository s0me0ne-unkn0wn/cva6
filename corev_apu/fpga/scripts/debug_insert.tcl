# ============================================================================
# debug_insert.tcl  --  Vivado ILA (Integrated Logic Analyzer) auto-insertion
# ============================================================================
# Inserts ONE ILA core wired to every net tagged (* mark_debug = "true" *) in
# the RTL (the PVM DRAM-demand-fetch / decode signals), so the OpenSBI-on-PVM
# FPGA-only hang can be observed at RTL level WITHOUT perturbing the PVM
# instruction stream (the marker-instrumentation approach moved the bug).
#
# SOURCED from run.tcl AFTER `open_run synth_1` (the synthesized netlist is in
# memory) and BEFORE `launch_runs impl_1`. Opt-in: only runs when the env var
# PVM_ILA=1 is set, so the normal `make fpga` flow is byte-identical unless the
# debugger explicitly asks for the ILA build.
#
# Flow (the mark_debug -> create_debug_core path, the cleanest non-GUI method):
#   1. Collect all nets carrying the MARK_DEBUG property in the synth_1 netlist.
#   2. Create one ila_pvm core; clk port -> the CVA6 core clock net.
#   3. One probe per debug net, width-matched; connect_debug_port.
#   4. Set ILA depth + basic capture-control so the parent can free-run + stop.
#   5. save_constraints so impl picks up the debug hub + the .ltx is written.
#
# The result: impl_1 builds the ILA in; write_bitstream emits ariane_xilinx.bit
# AND ariane_xilinx.ltx (the probe map the hw_manager needs).
# ============================================================================

if {![info exists ::env(PVM_ILA)] || $::env(PVM_ILA) ne "1"} {
    puts "\[debug_insert\] PVM_ILA != 1 -> skipping ILA insertion (normal build)."
    return
}

puts "============================================================"
puts "\[debug_insert\] PVM_ILA=1 -> inserting an ILA on the mark_debug nets"
puts "============================================================"

# ---- ILA sizing -----------------------------------------------------------
# Sample depth: 8192 is comfortable on the xc7k325t (the hang is persistent, so
# a free-running capture of the steady-state stall is all we need). Drop to 4096
# if BRAM utilization is tight (the parent can re-run with PVM_ILA_DEPTH=4096).
set ila_depth 8192
if {[info exists ::env(PVM_ILA_DEPTH)]} { set ila_depth $::env(PVM_ILA_DEPTH) }

# ---- 1. find the mark_debug nets ------------------------------------------
# get_nets -hierarchical -filter {MARK_DEBUG} returns every net Vivado kept the
# MARK_DEBUG property on through synthesis. Each net keeps its hierarchical name
# (e.g. .../i_pvm_front/i_fetch/pc_q_reg[*]), so we don't hardcode the hierarchy.
set dbg_nets [get_nets -hierarchical -filter {MARK_DEBUG == 1}]
if {[llength $dbg_nets] == 0} {
    # Fallback: some Vivado versions report the property as TRUE/true.
    set dbg_nets [get_nets -hierarchical -filter {MARK_DEBUG}]
}
set n_nets [llength $dbg_nets]
puts "\[debug_insert\] found $n_nets MARK_DEBUG net(s)."
if {$n_nets == 0} {
    puts "\[debug_insert\] ERROR: no MARK_DEBUG nets found -- did the mark_debug RTL get synthesized? Aborting ILA insertion."
    return
}

# Group nets into buses by their base name (strip a trailing [idx]) so a 32-bit
# pc_q becomes ONE 32-bit probe, not 32 one-bit probes. Preserve bit order.
# We build: bus_bits(base) = list of {index netobj}; scalars get index -1.
array unset bus_members
foreach net $dbg_nets {
    set nm [get_property NAME $net]
    if {[regexp {^(.*)\[(\d+)\]$} $nm -> base idx]} {
        lappend bus_members($base) [list $idx $net]
    } else {
        lappend bus_members($nm) [list -1 $net]
    }
}
set bases [lsort [array names bus_members]]
set n_probes [llength $bases]
puts "\[debug_insert\] grouped into $n_probes probe(s):"
foreach b $bases {
    puts "\[debug_insert\]   $b  (width [llength $bus_members($b)])"
}

# ---- 2. find the core clock net -------------------------------------------
# The ILA samples on the CVA6 core clock. The cleanest, hierarchy-independent
# way is to take the clock pin of one of the debug FLOP nets and trace to its
# clock net; but simplest robust choice on this design = the clock driving the
# pvm_fetch registers. We locate it via the synth'd clock of pc_q_reg.
# Strategy: find the clock net feeding the first debug net's driver flop. If
# that fails, fall back to the named core clock 'clk' (ariane_xilinx -> i_ariane
# .clk_i(clk)); after synth it is typically the buffered net on that pin.
set clk_net ""
# Try: the clock net of a debug register's C pin.
set dbg_cells [get_cells -hierarchical -filter {PRIMITIVE_GROUP == FLOP_LATCH} -quiet]
# Prefer the registers backing pc_q (always clocked by the core clock).
set pc_cells [get_cells -hierarchical -quiet -filter {NAME =~ *i_pvm_front*i_fetch*pc_q_reg*}]
if {[llength $pc_cells] > 0} {
    set cpin [get_pins -quiet -of_objects [lindex $pc_cells 0] -filter {REF_PIN_NAME == C || REF_PIN_NAME == CLK}]
    if {[llength $cpin] > 0} {
        set clk_net [get_nets -quiet -of_objects [lindex $cpin 0]]
    }
}
if {$clk_net eq ""} {
    # Fallbacks by common synthesized core-clock net names on this board flow.
    foreach cand {clk clk_i i_ariane/clk_i i_dram/clk_o} {
        set c [get_nets -hierarchical -quiet $cand]
        if {[llength $c] > 0} { set clk_net [lindex $c 0]; break }
    }
}
if {$clk_net eq ""} {
    # Last resort: the net on the highest-fanout BUFG output (the core clock dominates fanout).
    set bufg [get_cells -hierarchical -quiet -filter {REF_NAME =~ BUFG*}]
    if {[llength $bufg] > 0} {
        set clk_net [get_nets -quiet -of_objects [get_pins -quiet -of_objects [lindex $bufg 0] -filter {DIRECTION == OUT}]]
    }
}
if {$clk_net eq ""} {
    puts "\[debug_insert\] ERROR: could not resolve the core clock net for the ILA. Aborting."
    return
}
# A net can come back as a list; take the first element and report it.
set clk_net [lindex $clk_net 0]
puts "\[debug_insert\] ILA sample clock net: [get_property NAME $clk_net]"

# ---- 3. create the ILA core + connect probes ------------------------------
set dbg_core [create_debug_core ila_pvm ila]
set_property C_DATA_DEPTH    $ila_depth         [get_debug_cores $dbg_core]
set_property C_TRIGIN_EN     false              [get_debug_cores $dbg_core]
set_property C_TRIGOUT_EN    false              [get_debug_cores $dbg_core]
set_property C_INPUT_PIPE_STAGES 2              [get_debug_cores $dbg_core]
set_property C_EN_STRG_QUAL  true               [get_debug_cores $dbg_core]
set_property ALL_PROBE_SAME_MU       true       [get_debug_cores $dbg_core]
set_property ALL_PROBE_SAME_MU_CNT   4          [get_debug_cores $dbg_core]
# Connect the sample clock.
set_property port_width 1 [get_debug_ports $dbg_core/clk]
connect_debug_port $dbg_core/clk $clk_net

# probe0 is auto-created with the core; create the rest as we go.
set pidx 0
foreach b $bases {
    # Build the net list for this probe in ascending bit order (idx 0 = LSB).
    set members [lsort -integer -index 0 $bus_members($b)]
    set width [llength $members]
    set netlist {}
    foreach m $members { lappend netlist [lindex $m 1] }

    if {$pidx == 0} {
        set port $dbg_core/probe0
    } else {
        set port [create_debug_port $dbg_core probe]
    }
    set_property port_width $width [get_debug_ports $port]
    # Make probes available as both DATA and TRIGGER so the parent can optionally
    # trigger on e.g. running_q without rebuilding.
    set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports $port]
    connect_debug_port $port $netlist
    puts "\[debug_insert\]   probe$pidx <- $b (\[$width\] bit)"
    incr pidx
}

puts "\[debug_insert\] connected $pidx probe(s) to ILA core 'ila_pvm' (depth $ila_depth)."

# ---- 4. persist so impl_1 builds the debug hub + writes the .ltx ----------
# Implementation reads the debug constraints from the in-memory netlist; saving
# them (apply_hw_ila / save) makes the BUFG/dbg_hub insertion + .ltx generation
# happen during impl + write_bitstream.
# NB (2026-08-28): a bare `save_constraints -force` rewrote the TRACKED constraints/*.xdc
# (reformatted them and appended the create_debug_core/connect_debug_port lines), so every later
# normal build silently pulled the ILA in. Route the new debug constraints into a scratch file
# under work-fpga instead: it becomes the target constraints file, so save_constraints writes
# the debug core there and leaves the source .xdc alone. (If Vivado still touches the sources,
# `git checkout corev_apu/fpga/constraints/` after an ILA build.)
set dbg_xdc [file normalize "work-fpga/ila_debug.xdc"]
set fh [open $dbg_xdc w]; puts $fh "# generated by debug_insert.tcl (PVM_ILA=1): ILA core + probe connections"; close $fh
add_files -fileset constrs_1 -norecurse $dbg_xdc
set_property target_constrs_file $dbg_xdc [current_fileset -constrset]
save_constraints -force
puts "\[debug_insert\] ILA insertion complete; debug constraints -> $dbg_xdc; impl_1 will build it in and emit the .ltx."
