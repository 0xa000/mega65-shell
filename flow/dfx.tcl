# SPDX-License-Identifier: LGPL-3.0-or-later
# mega65-shell — parameterized Vivado non-project DFX flow
#
# Usage (from the repository root):
#   vivado -mode batch -source flow/dfx.tcl -tclargs <board> <stage> [name=value ...]
#
# Boards: any directory under boards/ with a board.tcl (wukong, r6).
# Stages:
#   static_elab                      RTL elaboration sanity check of the shell
#   static_synth                     synthesize the static -> build/<board>/static_synth.dcp
#   link SEED_RM_DCP=<dcp>           link the seed RM, implement, write the
#        [SEED_RM_XDC=<xdc>]         config_a bitstream, then black-box the RM and
#                                    lock the static -> static_locked.dcp.
#                                    THIS FREEZES THE BOUNDARY ABI: every child
#                                    partial must be linked against this exact
#                                    static_locked.dcp.
#   child RM_DCP=<dcp> NAME=<name>   link an RM synthesis checkpoint against the
#        [RM_XDC=<xdc>]              locked static -> config_<name> bitstream
#   verify [routed dcps ...]         pr_verify config_a against all
#                                    config_*_routed.dcp (+ any extra given)
#
# The seed RM is an input artifact: the shell repo contains no core code, but
# DFX needs one RM netlist to implement and lock the static. Any RM that
# matches the boundary (e.g. the M2M fork's democore) works. SEED_RM_XDC /
# RM_XDC are RM-framework constraint files (QNICE sdcard_clk etc.), read with
# -unmanaged so they act on the run but are never serialized into checkpoints
# (a baked RM-cell constraint replays into every later child link and errors
# RMs without those cells — the constraint-ownership rule).

if { $argc < 2 } {
   puts "ERROR: usage: -tclargs <board> <stage> \[name=value ...\]"
   exit 1
}
set board [lindex $argv 0]
set stage [lindex $argv 1]

# name=value arguments
array set opt {}
set extra_args [list]
foreach a [lrange $argv 2 end] {
   if { [regexp {^([A-Za-z_]+)=(.*)$} $a -> k v] } {
      set opt($k) $v
   } else {
      lappend extra_args $a
   }
}

if { ![file exists boards/$board/board.tcl] } {
   puts "ERROR: unknown board '$board' (no boards/$board/board.tcl)"
   exit 1
}
source boards/$board/board.tcl

set outdir build/$board
file mkdir $outdir

proc read_static_sources {} {
   global static_vhdl_2008 static_verilog
   read_vhdl -vhdl2008 $static_vhdl_2008
   if { [llength $static_verilog] > 0 } {
      read_verilog $static_verilog
   }
   # Non-project mode does not scan for Xilinx Parameterized Macros itself;
   # without this all XPM_CDC timing constraints are silently skipped and
   # every clock-domain crossing fails timing.
   auto_detect_xpm
}

# ascal's reset_na resync registers only resolve on a linked RM netlist;
# harmless (with a note) for RMs without ascal.
proc apply_ascal_false_path {} {
   set ascal_rst [get_pins -quiet -hier -filter {
      (NAME =~ "*/i_ascal/*reset_na_reg*/D") ||
      (NAME =~ "*/i_ascal/*reset_na_reg*/CLR") ||
      (NAME =~ "*/i_ascal/*reset_na_reg*/PRE")}]
   if { [llength $ascal_rst] > 0 } {
      set_false_path -to $ascal_rst
      puts "== ascal reset_na false path applied to [llength $ascal_rst] pins =="
   } else {
      puts "== note: no ascal reset_na registers found (RM without ascal?) =="
   }
}

if { $stage == "static_elab" } {
   read_static_sources
   synth_design -rtl -top $shell_top -part $part
   puts "== Static elaboration OK =="
   exit 0
}

if { $stage == "static_synth" } {
   read_static_sources
   foreach x $xdc_static { read_xdc $x }
   synth_design -top $shell_top -part $part
   write_checkpoint -force $outdir/static_synth.dcp
   report_utilization -file $outdir/static_utilization_synth.rpt
   puts "== Static synthesis OK — $outdir/static_synth.dcp =="
   exit 0
}

# First configuration: link the seed RM into the static, implement, write the
# config_a bitstream, then lock the static for all child configurations.
if { $stage == "link" } {
   if { ![info exists opt(SEED_RM_DCP)] } {
      puts "ERROR: link needs SEED_RM_DCP=<rm synth checkpoint>"
      exit 1
   }
   open_checkpoint $outdir/static_synth.dcp
   read_checkpoint -cell RM $opt(SEED_RM_DCP)
   set_property HD.RECONFIGURABLE true [get_cells RM]
   foreach x $xdc_static { read_xdc $x }
   read_xdc $xdc_pblock
   if { [info exists opt(SEED_RM_XDC)] } {
      read_xdc -unmanaged $opt(SEED_RM_XDC)
   }
   apply_ascal_false_path

   opt_design
   place_design
   phys_opt_design
   route_design

   write_checkpoint -force $outdir/config_a_routed.dcp
   report_utilization -file $outdir/config_a_utilization.rpt
   report_timing_summary -file $outdir/config_a_timing.rpt
   # TIMING-27 (local clock) in here caught the R6 round-3 ICAP clock bug;
   # check this report after every static change.
   report_methodology -file $outdir/config_a_methodology.rpt
   write_bitstream -force -bin_file $outdir/config_a

   # Freeze the static half for all child configurations
   update_design -cell RM -black_box
   lock_design -level routing
   write_checkpoint -force $outdir/static_locked.dcp
   puts "== Config A implemented, static locked — $outdir/static_locked.dcp =="
   exit 0
}

# Link an RM against the locked static -> config_<NAME>. The common child XDC
# re-applies the RM-internal timing constraints that were dropped when the
# static was black-boxed.
if { $stage == "child" } {
   if { ![info exists opt(RM_DCP)] || ![info exists opt(NAME)] } {
      puts "ERROR: child needs RM_DCP=<rm synth checkpoint> NAME=<config name>"
      exit 1
   }
   open_checkpoint $outdir/static_locked.dcp
   read_checkpoint -cell RM $opt(RM_DCP)
   read_xdc $xdc_child
   # RM_XDC accepts a space-separated list: the RM framework XDC plus the
   # per-RM clock override emitted by tools/mmcm_drp_table.py --xdc
   # (read after the common child XDC, per the one-table rule).
   if { [info exists opt(RM_XDC)] } {
      foreach x $opt(RM_XDC) { read_xdc -unmanaged $x }
   }
   apply_ascal_false_path

   opt_design
   place_design
   route_design

   write_checkpoint -force $outdir/config_$opt(NAME)_routed.dcp
   report_timing_summary -file $outdir/config_$opt(NAME)_timing.rpt
   write_bitstream -force -bin_file $outdir/config_$opt(NAME)
   puts "== Config $opt(NAME) implemented =="
   exit 0
}

# Formal check: every partial shares the locked static (pass extra routed
# configs, e.g. from a core repo, as plain arguments for cross-repo checks).
if { $stage == "verify" } {
   set additional [list]
   foreach cfg [glob -nocomplain $outdir/config_*_routed.dcp] {
      if { [file tail $cfg] ne "config_a_routed.dcp" } { lappend additional $cfg }
   }
   foreach cfg $extra_args {
      if { [file exists $cfg] } { lappend additional $cfg }
   }
   if { [llength $additional] == 0 } {
      puts "ERROR: nothing to verify against config_a"
      exit 1
   }
   pr_verify -initial $outdir/config_a_routed.dcp -additional $additional
   puts "== pr_verify OK: partials are interchangeable =="
   exit 0
}

puts "ERROR: unknown stage '$stage'"
exit 1
