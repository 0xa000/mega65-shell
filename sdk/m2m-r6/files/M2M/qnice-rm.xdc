## MiSTer2MEGA65 — MEGA65 R6 DFX: QNICE-framework RM constraints
##
## Owned by the RM, not the shell (constraint-ownership rule, see
## mega65-shell docs/BOUNDARY.md): these target cells inside the RM of
## QNICE-framework cores (democore, Moon Patrol, ...). Read this
## file AFTER the RM netlist is linked, and read it with
##
##    read_xdc -unmanaged ../M2M/qnice-rm.xdc
##
## at any stage that later writes static_locked.dcp: unmanaged constraints
## are not serialized into checkpoints, so nothing RM-internal replays into
## the link of a non-QNICE RM (the picorv32 menu hit exactly that on
## sdcard_clk). Non-QNICE RMs simply do not read this file.

## Clock divider sdcard_clk that creates the 25 MHz used by sd_spi.vhd.
## Guarded so the file is inert if a QNICE variant lacks the register.
set sd_slow_clk_pin [get_pins -quiet RM/i_framework/i_qnice_wrapper/QNICE_SOC/sd_card/Slow_Clock_25MHz_reg/Q]
if {[llength $sd_slow_clk_pin]} {
   create_generated_clock -name sdcard_clk -source [get_pins i_shell_clk_base/i_pll_base/CLKOUT0] -divide_by 2 $sd_slow_clk_pin
}

## QNICE's EAE combinatorial division networks take longer than the regular
## clock period.
set_multicycle_path -from [get_cells -include_replicated {RM/i_framework/i_qnice_wrapper/QNICE_SOC/eae_inst/op*_reg[*]}] \
   -to [get_cells -include_replicated {RM/i_framework/i_qnice_wrapper/QNICE_SOC/eae_inst/res_reg[*]}] -setup 3
set_multicycle_path -from [get_cells -include_replicated {RM/i_framework/i_qnice_wrapper/QNICE_SOC/eae_inst/op*_reg[*]}] \
   -to [get_cells -include_replicated {RM/i_framework/i_qnice_wrapper/QNICE_SOC/eae_inst/res_reg[*]}] -hold 2
