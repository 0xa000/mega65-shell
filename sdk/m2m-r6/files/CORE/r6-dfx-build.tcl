# MiSTer2MEGA65 — MEGA65 R6 RM build (mega65-shell SDK overlay)
#
# RM-only flow: elaborate / synthesize the M2M democore as a reconfigurable
# module for the mega65-shell static shell (boundary v5). The static shell,
# child link and pr_verify live in the mega65-shell repo:
#
#   make BOARD=r6 child RM_DCP=.../rm_democore_synth.dcp NAME=democore \
#        RM_XDC=".../r6-dfx-child.xdc .../qnice-rm.xdc"
#
# Usage (run from CORE/):
#   vivado -mode batch -source r6-dfx-build.tcl -tclargs rm_elab   # RM-only elaboration sanity check
#   vivado -mode batch -source r6-dfx-build.tcl -tclargs rm_synth  # RM out-of-context synthesis -> rm_democore_synth.dcp
#
# Trimmed from the full DFX PoC flow (MiSTer2MEGA65 fork, branch dfx-v5-r6);
# boundary reference: mega65-shell docs/BOUNDARY.md.
# DFX carve-out done by 0xa000 in 2026 and licensed under GPL v3

set stage "rm_elab"
if { $argc > 0 } { set stage [lindex $argv 0] }

set part xc7a200tfbg484-2
set outdir ./build-r6-dfx
file mkdir $outdir

if { ![file exists ./m2m-rom/m2m-rom.rom] } {
   puts "ERROR: m2m-rom/m2m-rom.rom missing — run cd m2m-rom && ./make_rom.sh first"
   exit 1
}

# ---------------------------------------------------------------------------
# RM sources: the flat r6-build.tcl list minus everything the shell owns
# (clk_m2m, video_out_clock, reset_manager, HyperRAM controller, the AK4432
# audio driver, OSERDES serialiser, CORE clk.vhd, board top) plus the dfx RM
# variants (av_pipeline_rm/digital_pipeline_rm shadow their originals;
# framework_rm shadows framework.vhd; mega65_rm shadows CORE/vhdl/mega65.vhd
# under the same entity name MEGA65_Core)
# ---------------------------------------------------------------------------

set rm_vhdl_2008 {
   ../M2M/vhdl/tdp_ram.vhd
   ../M2M/vhdl/2port2clk_ram.vhd
   ../M2M/vhdl/2port2clk_ram_byteenable.vhd
   ../M2M/QNICE/vhdl/EAE.vhd
   ../M2M/QNICE/vhdl/cpu_constants.vhd
   ../M2M/QNICE/vhdl/alu.vhd
   ../M2M/QNICE/vhdl/alu_shifter.vhd
   ../M2M/vhdl/av_pipeline/vga_recover_counters.vhd
   ../M2M/vhdl/ram_init.vhd
   ../M2M/vhdl/av_pipeline/vga_osm.vhd
   ../M2M/vhdl/av_pipeline/video_overlay.vhd
   ../M2M/vhdl/av_pipeline/analog_pipeline.vhd
   ../M2M/vhdl/av_pipeline/ascal.vhd
   ../M2M/QNICE/vhdl/tools.vhd
   ../M2M/vhdl/av_pipeline/video_modes_pkg.vhd
   vhdl/globals.vhd
   ../M2M/vhdl/controllers/HDMI/types_pkg.vhd
   ../M2M/vhdl/cdc_stable.vhd
   ../M2M/vhdl/cdc_pulse.vhd
   ../M2M/vhdl/av_pipeline/video_counters.vhd
   ../M2M/vhdl/av_pipeline/crop.vhd
   ../M2M/vhdl/av_pipeline/clk_synthetic_enable.vhd
   ../M2M/vhdl/memory/avm_decrease.vhd
   ../M2M/vhdl/controllers/HDMI/sync_reg.vhd
   ../M2M/vhdl/controllers/HDMI/hdmi_tx_encoder.vhd
   ../M2M/vhdl/controllers/HDMI/vga_to_hdmi.vhd
   ../M2M/vhdl/hdmi_flicker_free.vhd
   ../M2M/vhdl/memory/avm_arbit.vhd
   ../M2M/vhdl/memory/avm_arbit_general.vhd
   ../M2M/vhdl/memory/axi_fifo.vhd
   ../M2M/vhdl/memory/avm_fifo.vhd
   ../M2M/QNICE/vhdl/basic_uart.vhd
   ../M2M/vhdl/QNICE/qnice_globals.vhd
   ../M2M/QNICE/vhdl/block_ram.vhd
   ../M2M/QNICE/vhdl/block_rom.vhd
   ../M2M/QNICE/vhdl/bus_uart.vhd
   ../M2M/QNICE/vhdl/byte_bram.vhd
   ../M2M/vhdl/clock_counter.vhd
   vhdl/config.vhd
   ../M2M/vhdl/i2c/cpu_to_i2c_master.vhd
   ../M2M/QNICE/vhdl/cycle_counter.vhd
   ../M2M/vhdl/debounce.vhd
   ../M2M/vhdl/debouncer.vhd
   ../M2M/vhdl/democore/democore_game.vhd
   ../M2M/vhdl/democore/vga_controller.vhd
   ../M2M/vhdl/democore/democore_video.vhd
   ../M2M/vhdl/democore/democore_audio.vhd
   ../M2M/vhdl/democore/democore.vhd
   ../M2M/QNICE/vhdl/fifo.vhd
   ../M2M/vhdl/controllers/M65/kb_matrix_ram.vhdl
   ../M2M/vhdl/controllers/M65/mega65kbd_to_matrix.vhdl
   ../M2M/vhdl/controllers/M65/matrix_to_keynum.vhdl
   ../M2M/vhdl/m2m_keyb.vhd
   ../M2M/QNICE/vhdl/qnice_cpu.vhd
   ../M2M/vhdl/QNICE/sdmux.vhd
   ../M2M/QNICE/vhdl/sdcard.vhd
   ../M2M/vhdl/QNICE/qnice_mmio.vhd
   ../M2M/vhdl/QNICE/qnice.vhd
   ../M2M/vhdl/qnice2hyperram.vhd
   ../M2M/vhdl/controllers/M65/mouse_input.vhdl
   ../M2M/vhdl/qnice_wrapper.vhd
   ../M2M/vhdl/i2c/rtc_master.vhd
   ../M2M/vhdl/i2c/rtc_controller.vhd
   ../M2M/vhdl/qnice_arbit.vhd
   ../M2M/vhdl/i2c/i2c_master.vhd
   ../M2M/vhdl/i2c/i2c_controller.vhd
   ../M2M/vhdl/i2c/rtc_wrapper.vhd
   vhdl/keyboard.vhd
   vhdl/main.vhd
   ../M2M/vhdl/vdrives.vhd
   ../M2M/QNICE/vhdl/register_file.vhd
   ../M2M/QNICE/vhdl/sd_spi.vhd
   vhdl/dfx/mega65_rm.vhd
   vhdl/dfx/democore_clk_pkg.vhd
   ../M2M/vhdl/dfx/rm/digital_pipeline_rm.vhd
   ../M2M/vhdl/dfx/rm/av_pipeline_rm.vhd
   ../M2M/vhdl/dfx/rm/framework_rm.vhd
   ../M2M/vhdl/dfx/clk_drp_master.vhd
   ../M2M/vhdl/dfx/rm/rm_top_r6.vhd
}

set rm_sverilog {
   ../M2M/vhdl/av_pipeline/audio_out.v
   ../M2M/vhdl/controllers/MiSTer/iir_filter.v
   ../M2M/vhdl/controllers/MiSTer/scandoubler.v
   ../M2M/vhdl/controllers/MiSTer/csync.sv
   ../M2M/vhdl/controllers/MiSTer/hq2x.sv
   ../M2M/vhdl/controllers/MiSTer/video_freezer.sv
   ../M2M/vhdl/controllers/MiSTer/video_mixer.sv
}

proc read_rm_sources {} {
   global rm_vhdl_2008 rm_sverilog
   read_vhdl -vhdl2008 $rm_vhdl_2008
   read_verilog -sv $rm_sverilog
   # Non-project mode does not scan for Xilinx Parameterized Macros itself;
   # without this all XPM_CDC/XPM_FIFO timing constraints are silently
   # skipped and every framework clock-domain crossing fails timing.
   auto_detect_xpm
}

if { $stage == "rm_elab" } {
   read_rm_sources
   synth_design -rtl -top rm_top_r6 -part $part
   puts "== RM elaboration OK =="
   exit 0
}

# democore RM, out-of-context.  It reprograms CORE_A to 54 MHz at wake via
# the DRP proxy (democore's native clock), so swapping back to it from any
# other RM restores the right frequency instead of inheriting the previous
# RM's — the "RM clocking rule".
if { $stage == "rm_synth" } {
   read_rm_sources
   synth_design -top rm_top_r6 -part $part -mode out_of_context
   write_checkpoint -force $outdir/rm_democore_synth.dcp
   report_utilization -file $outdir/rm_democore_utilization_synth.rpt
   puts "== democore RM synthesis OK — $outdir/rm_democore_synth.dcp =="
   exit 0
}

puts "ERROR: unknown stage '$stage' (this overlay copy has rm_elab and rm_synth;"
puts "       child link and pr_verify are done in the mega65-shell repo)"
exit 1
