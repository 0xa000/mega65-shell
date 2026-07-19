# SPDX-License-Identifier: LGPL-3.0-or-later
# mega65-shell — MEGA65 R6 board definition (sourced by flow/dfx.tcl;
# all paths are relative to the repository root)

set part      xc7a200tfbg484-2
set shell_top shell_top_r6

set static_vhdl_2008 {
   rtl/common/types_pkg.vhd
   rtl/common/shell_clk_base.vhd
   rtl/common/debounce.vhd
   rtl/common/reset_manager.vhd
   rtl/common/cdc_stable.vhd
   rtl/common/video_out_clock.vhd
   rtl/common/shell_core_clk.vhd
   rtl/common/drp_proxy.vhd
   rtl/common/serialiser_10to1_selectio.vhd
   rtl/common/icap_loader.vhdl
   rtl/common/uart_rx.vhdl
   rtl/common/uart_tx.vhdl
   rtl/common/sd_sector.vhdl
   rtl/common/fat32_walker.vhdl
   rtl/common/load_ctrl.vhdl
   rtl/common/desc_proxy.vhd
   boards/r6/rtl/audio.vhd
   boards/r6/hyperram/hyperram_errata.vhd
   boards/r6/hyperram/hyperram_config.vhd
   boards/r6/hyperram/hyperram_ctrl.vhd
   boards/r6/hyperram/hyperram_fifo.vhd
   boards/r6/hyperram/hyperram_rx.vhd
   boards/r6/hyperram/hyperram_tx.vhd
   boards/r6/hyperram/hyperram.vhd
   boards/r6/rtl/shell_top_r6.vhd
}

set static_verilog {}

# Pin + timing constraints for synthesis and the initial link
set xdc_static {
   boards/r6/constr/pins.xdc
   boards/r6/constr/static.xdc
}

set xdc_pblock boards/r6/constr/pblock.xdc
set xdc_child  boards/r6/constr/child.xdc
