// Golden oracle for mmcm_drp_table.py's fractional selftest (VIC20 preset).
//
// Includes the authoritative Xilinx clk_wiz 7-series functions and reproduces
// the exact state-1 ROM assembly from mmcm_pll_drp_v.ttcl (7-series `else`
// branch, FRAC_EN=1 for CLKOUT0 and CLKFBOUT).  The CLKOUT0_FRAC_CALC /
// CLKFBOUT_FRAC_CALC values and the frac-specific rows it prints are the
// golden vectors hard-coded in mmcm_drp_table.py selftest(); regenerate them
// if the fractional port or a preset changes:
//
//   D=/opt/Xilinx/Vivado/2023.2/data/ip/xilinx/clk_wiz_v6_0
//   iverilog -g2012 -I $D -o g.vvp M2M/tools/mmcm_frac_golden.v && vvp g.vvp
//
// Prints each row as  IDX ADDR MASK DATA  ({addr, mask, data} row order the
// clk_wiz SM uses; mmcm_drp_table.py stores it as (addr, data, mask)).

`timescale 1ns/1ps

module golden;
`include "mmcm_pll_drp_func_7s_mmcm.vh"

   // ---- VIC20 clk.vhd: DIVCLK=5, MULT_F=47.875, CLKOUT0_DIVIDE_F=13.5,
   //      CLKOUT1_DIVIDE=27 (integer).  Phase 0, 50% duty.
   localparam S1_CLKFBOUT_MULT   = 47;
   localparam S1_CLKFBOUT_FRAC   = 875;
   localparam S1_CLKFBOUT_PHASE  = 0;
   localparam S1_CLKOUT0_DIVIDE  = 13;
   localparam S1_CLKOUT0_FRAC    = 500;
   localparam S1_CLKOUT0_PHASE   = 0;
   localparam S1_CLKOUT0_DUTY    = 50000;
   localparam S1_CLKOUT1_DIVIDE  = 27;
   localparam S1_CLKOUT1_PHASE   = 0;
   localparam S1_CLKOUT1_DUTY    = 50000;
   localparam S1_DIVCLK_DIVIDE   = 5;

   localparam [37:0] S1_CLKFBOUT           = mmcm_pll_count_calc(S1_CLKFBOUT_MULT, S1_CLKFBOUT_PHASE, 50000);
   localparam [37:0] S1_CLKFBOUT_FRAC_CALC = mmcm_frac_count_calc(S1_CLKFBOUT_MULT, S1_CLKFBOUT_PHASE, 50000, S1_CLKFBOUT_FRAC);
   localparam [9:0]  S1_DIGITAL_FILT       = mmcm_pll_filter_lookup(S1_CLKFBOUT_MULT, "OPTIMIZED");
   localparam [39:0] S1_LOCK               = mmcm_pll_lock_lookup(S1_CLKFBOUT_MULT);
   localparam [37:0] S1_DIVCLK             = mmcm_pll_count_calc(S1_DIVCLK_DIVIDE, 0, 50000);
   localparam [37:0] S1_CLKOUT0            = mmcm_pll_count_calc(S1_CLKOUT0_DIVIDE, S1_CLKOUT0_PHASE, S1_CLKOUT0_DUTY);
   localparam [37:0] S1_CLKOUT0_FRAC_CALC  = mmcm_frac_count_calc(S1_CLKOUT0_DIVIDE, S1_CLKOUT0_PHASE, 50000, S1_CLKOUT0_FRAC);
   localparam [37:0] S1_CLKOUT1            = mmcm_pll_count_calc(S1_CLKOUT1_DIVIDE, S1_CLKOUT1_PHASE, S1_CLKOUT1_DUTY);
   // Unused outputs: clk_wiz defaults them to divide 1
   localparam [37:0] S1_CLKOUT2            = mmcm_pll_count_calc(1, 0, 50000);
   localparam [37:0] S1_CLKOUT3            = mmcm_pll_count_calc(1, 0, 50000);
   localparam [37:0] S1_CLKOUT4            = mmcm_pll_count_calc(1, 0, 50000);
   localparam [37:0] S1_CLKOUT5            = mmcm_pll_count_calc(1, 0, 50000);
   localparam [37:0] S1_CLKOUT6            = mmcm_pll_count_calc(1, 0, 50000);

   reg [38:0] ram [0:22];
   integer i;

   initial begin
      // ttcl state-1 ROM, 7-series `else` branch, FRAC_EN=1 (CLKOUT0 & CLKFBOUT)
      ram[0]  = {7'h28, 16'h0000, 16'hFFFF};
      ram[1]  = {7'h09, 16'h8000, S1_CLKOUT0_FRAC_CALC[31:16]};
      ram[2]  = {7'h08, 16'h1000, S1_CLKOUT0_FRAC_CALC[15:0]};
      ram[3]  = {7'h0A, 16'h1000, S1_CLKOUT1[15:0]};
      ram[4]  = {7'h0B, 16'hFC00, S1_CLKOUT1[31:16]};
      ram[5]  = {7'h0C, 16'h1000, S1_CLKOUT2[15:0]};
      ram[6]  = {7'h0D, 16'hFC00, S1_CLKOUT2[31:16]};
      ram[7]  = {7'h0E, 16'h1000, S1_CLKOUT3[15:0]};
      ram[8]  = {7'h0F, 16'hFC00, S1_CLKOUT3[31:16]};
      ram[9]  = {7'h10, 16'h1000, S1_CLKOUT4[15:0]};
      ram[10] = {7'h11, 16'hFC00, S1_CLKOUT4[31:16]};
      ram[11] = {7'h06, 16'h1000, S1_CLKOUT5[15:0]};
      ram[12] = {7'h07, 16'hC000, S1_CLKOUT5[31:30], S1_CLKOUT0_FRAC_CALC[35:32], S1_CLKOUT5[25:16]};
      ram[13] = {7'h12, 16'h1000, S1_CLKOUT6[15:0]};
      ram[14] = {7'h13, 16'hC000, S1_CLKOUT6[31:30], S1_CLKFBOUT_FRAC_CALC[35:32], S1_CLKOUT6[25:16]};
      ram[15] = {7'h16, 16'hC000, 2'h0, S1_DIVCLK[23:22], S1_DIVCLK[11:0]};
      ram[16] = {7'h14, 16'h1000, S1_CLKFBOUT_FRAC_CALC[15:0]};
      ram[17] = {7'h15, 16'h8000, S1_CLKFBOUT_FRAC_CALC[31:16]};
      ram[18] = {7'h18, 16'hFC00, 6'h00, S1_LOCK[29:20]};
      ram[19] = {7'h19, 16'h8000, 1'b0, S1_LOCK[34:30], S1_LOCK[9:0]};
      ram[20] = {7'h1A, 16'h8000, 1'b0, S1_LOCK[39:35], S1_LOCK[19:10]};
      ram[21] = {7'h4E, 16'h66FF, S1_DIGITAL_FILT[9], 2'h0, S1_DIGITAL_FILT[8:7], 2'h0, S1_DIGITAL_FILT[6], 8'h00};
      ram[22] = {7'h4F, 16'h666F, S1_DIGITAL_FILT[5], 2'h0, S1_DIGITAL_FILT[4:3], 2'h0, S1_DIGITAL_FILT[2:1], 2'h0, S1_DIGITAL_FILT[0], 4'h0};

      $display("# raw frac results:");
      $display("# CLKOUT0_FRAC_CALC = %010h", S1_CLKOUT0_FRAC_CALC);
      $display("# CLKFBOUT_FRAC_CALC = %010h", S1_CLKFBOUT_FRAC_CALC);
      $display("# CLKOUT1 = %010h", S1_CLKOUT1);
      $display("# DIVCLK = %010h", S1_DIVCLK);
      $display("# LOCK = %010h  FILT = %03h", S1_LOCK, S1_DIGITAL_FILT);
      for (i = 0; i < 23; i = i + 1)
         $display("%0d %02h %04h %04h", i, ram[i][38:32], ram[i][31:16], ram[i][15:0]);
      $finish;
   end
endmodule
