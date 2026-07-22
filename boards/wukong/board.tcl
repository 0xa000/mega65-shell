# SPDX-License-Identifier: LGPL-3.0-or-later
# mega65-shell — QMTECH Wukong board definition (sourced by flow/dfx.tcl;
# all paths are relative to the repository root)

set part      xc7a100tfgg676-2
set shell_top shell_top

set static_vhdl_2008 {
   rtl/common/types_pkg.vhd
   rtl/common/shell_clk_base.vhd
   rtl/common/debounce.vhd
   rtl/common/reset_manager.vhd
   rtl/common/cdc_stable.vhd
   rtl/common/video_out_clock.vhd
   rtl/common/shell_core_clk.vhd
   rtl/common/drp_proxy.vhd
   rtl/common/avm_increase.vhd
   rtl/common/axi_fifo_small.vhd
   rtl/common/serialiser_10to1_selectio.vhd
   rtl/common/icap_loader.vhdl
   rtl/common/uart_rx.vhdl
   rtl/common/uart_tx.vhdl
   rtl/common/sd_sector.vhdl
   rtl/common/fat32_walker.vhdl
   rtl/common/load_ctrl.vhdl
   rtl/common/desc_proxy.vhd
   rtl/common/iprog_seq.vhdl
   boards/wukong/rtl/clk_wukong.vhd
   boards/wukong/rtl/avm_to_wb.vhd
   boards/wukong/rtl/ddr3_wrapper_wukong.vhd
   boards/wukong/rtl/shell_top.vhd
}

set static_verilog {
   boards/wukong/uberddr3/ddr3_controller.v
   boards/wukong/uberddr3/ddr3_phy.v
   boards/wukong/uberddr3/ddr3_top_wukong.v
}

# Pin + timing constraints for synthesis and the initial link
set xdc_static {
   boards/wukong/constr/static.xdc
}

set xdc_pblock boards/wukong/constr/pblock.xdc
set xdc_child  boards/wukong/constr/child.xdc
