## mega65-shell — MEGA65 R6 DFX: child-configuration constraints
##
## Applied by every child implementation (impl_b, future RMs) after linking
## a fresh RM netlist into the locked static. Contains ONLY the timing
## constraints that target RM-internal cells: these were dropped from
## static_locked.dcp when the RM was black-boxed, and re-reading the full
## static.xdc is not possible (pin constraints on a locked netlist
## make the placer try to modify DONT_TOUCH static logic). Keep in sync
## with the corresponding static.xdc rules.

## Generic CDC (cdc_stable instances inside the RM)
set_max_delay 8 -datapath_only -from [get_generated_clocks] -to [get_pins -hierarchical "*cdc_stable_gen.dst_*_d_reg[*]/D"]
set_max_delay 8 -datapath_only -from [get_clocks clk] -to [get_pins -hierarchical "*cdc_stable_gen.dst_*_d_reg[*]/D"]

## RM-framework constraints (QNICE sdcard_clk, EAE multicycles) live in the
## RM framework's own XDC (read additionally with -unmanaged at link time) —
## constraint-ownership rule, same as the Wukong child XDC.

## ASCAL clock-domain waivers (regs inside the RM)
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/i_.*_reg.*/C"]   -to [get_pins -hierarchical -regexp ".*/i_ascal/avl_.*_reg.*/D"]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/i_.*_reg.*/C"]   -to [get_pins -hierarchical -regexp ".*/i_ascal/o_.*_reg.*/D"]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/avl_.*_reg.*/C"] -to [get_pins -hierarchical -regexp ".*/i_ascal/o_.*_reg.*/D"]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/o_.*_reg.*/C"]   -to [get_pins -hierarchical -regexp ".*/i_ascal/i_.*_reg.*/D"]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/o_.*_reg.*/C"]   -to [get_pins -hierarchical -regexp ".*/i_ascal/avl_.*_reg.*/D"]

## ascal CDC FIFOs when spilled to LUTRAM: the asynchronous read moves the
## path startpoint to the write-clock pin (RAMA|RAMB/CLK), which the
## FF-oriented "..._reg.*/C" rules above do not match (lesson carried from
## the Wukong C64 RM).  Full-match "/CLK" only — inert if the FIFOs map to
## BRAM (clock pins CLKARDCLK/CLKBWRCLK).
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/i_dpram_reg.*/CLK"] -to [get_clocks mem_clk]
set_false_path -quiet -from [get_pins -hierarchical -regexp ".*/i_ascal/o_dpram_reg.*/CLK"] -to [get_clocks hdmi_clk]

## Clock-pair waivers (clocks are static, but re-apply defensively)
set_false_path -from [get_clocks hdmi_clk]  -to [get_clocks audio_clk]
set_false_path -from [get_clocks audio_clk] -to [get_clocks hdmi_clk]
set_false_path -from [get_clocks loader_clk] -to [get_clocks hdmi_clk]

## The loader/service clock is asynchronous to the core clocks — every such
## data crossing goes through the framework's dual-clock RAMs / CDC
## synchronisers.  The flat build gets this for free because loader_clk and the
## core sit on separate, unrelated MMCM trees; but in the shell both derive
## from the same 100 MHz input, so STA would otherwise time them
## synchronously with a near-zero requirement.  Covers both mux sources
## (core_clk0/core_clk0_b, core_clk1/core_clk1_b); -quiet so it is inert for
## an RM that leaves a core clock unused.
set_clock_groups -asynchronous -quiet \
   -group [get_clocks -quiet loader_clk] \
   -group [get_clocks -quiet {core_clk0 core_clk0_b core_clk1 core_clk1_b core_clk2 core_clk2_b}]
