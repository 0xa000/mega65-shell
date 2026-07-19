-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-------------------------------------------------------------------------------------------------------------
-- mega65-shell — QMTECH Wukong board layer
--
-- Presents the shell's standard memory service: the same
-- 16-bit burst-capable Avalon-MM slave, backed by the Wukong's 256 MB DDR3
-- through the UberDDR3 open source controller.
--
-- The UberDDR3 controller clock IS the shell's mem_clk: this wrapper
-- generates the 100 MHz controller clock (exported as ctrl_clk_o, adopted
-- by the shell as mem_clk) so the whole Avalon chain is a single clock
-- domain with no CDC:
--   16-bit Avalon @ 100 MHz
--     -> avm_increase  (16 -> 128 bit, matching UberDDR3's data width)
--     -> avm_to_wb     (Avalon -> pipelined Wishbone)
--     -> ddr3_top_wukong (UberDDR3, 4:1, DDR3-800)
--
-- Clocking is UberDDR3's reference configuration: DDR3 at 400 MHz,
-- controller at 100 MHz, 200 MHz IDELAYCTRL reference — all derived here
-- from the 100 MHz board clock (VCO 800 MHz).
--
-- Wukong port done by 0xa000 in 2026
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity ddr3_wrapper_wukong is
   port (
      -- 100 MHz board clock for the internal clock generation
      sys_clk_i           : in    std_logic;

      -- Asynchronous reset request (framework/core reset, any domain)
      rst_i               : in    std_logic;

      -- Controller clock domain, exported: the framework adopts these as
      -- mem_clk/mem_rst so the Avalon fabric and UberDDR3 share one domain
      ctrl_clk_o          : out   std_logic;
      ctrl_rst_o          : out   std_logic;

      -- Avalon-MM slave in the ctrl_clk_o domain (same interface the HyperRAM controller had)
      avm_write_i         : in    std_logic;
      avm_read_i          : in    std_logic;
      avm_address_i       : in    std_logic_vector(31 downto 0);
      avm_writedata_i     : in    std_logic_vector(15 downto 0);
      avm_byteenable_i    : in    std_logic_vector(1 downto 0);
      avm_burstcount_i    : in    std_logic_vector(7 downto 0);
      avm_readdata_o      : out   std_logic_vector(15 downto 0);
      avm_readdatavalid_o : out   std_logic;
      avm_waitrequest_o   : out   std_logic;

      calib_complete_o    : out   std_logic;

      -- DDR3 device interface
      ddr3_clk_p_o        : out   std_logic;
      ddr3_clk_n_o        : out   std_logic;
      ddr3_reset_n_o      : out   std_logic;
      ddr3_cke_o          : out   std_logic;
      ddr3_ras_n_o        : out   std_logic;
      ddr3_cas_n_o        : out   std_logic;
      ddr3_we_n_o         : out   std_logic;
      ddr3_addr_o         : out   std_logic_vector(13 downto 0);
      ddr3_ba_o           : out   std_logic_vector(2 downto 0);
      ddr3_dq_io          : inout std_logic_vector(15 downto 0);
      ddr3_dqs_p_io       : inout std_logic_vector(1 downto 0);
      ddr3_dqs_n_io       : inout std_logic_vector(1 downto 0);
      ddr3_dm_o           : out   std_logic_vector(1 downto 0);
      ddr3_odt_o          : out   std_logic
   );
end entity ddr3_wrapper_wukong;

architecture synthesis of ddr3_wrapper_wukong is

   component ddr3_top_wukong is
      generic (
         CONTROLLER_CLK_PERIOD : integer := 12_000;   -- ps
         DDR3_CLK_PERIOD       : integer := 3_000     -- ps, must be 1/4 of the above
      );
      port (
         i_controller_clk : in    std_logic;
         i_ddr3_clk       : in    std_logic;
         i_ref_clk        : in    std_logic;
         i_ddr3_clk_90    : in    std_logic;
         i_rst_n          : in    std_logic;
         i_wb_cyc         : in    std_logic;
         i_wb_stb         : in    std_logic;
         i_wb_we          : in    std_logic;
         i_wb_addr        : in    std_logic_vector(23 downto 0);
         i_wb_data        : in    std_logic_vector(127 downto 0);
         i_wb_sel         : in    std_logic_vector(15 downto 0);
         o_wb_stall       : out   std_logic;
         o_wb_ack         : out   std_logic;
         o_wb_err         : out   std_logic;
         o_wb_data        : out   std_logic_vector(127 downto 0);
         o_ddr3_clk_p     : out   std_logic;
         o_ddr3_clk_n     : out   std_logic;
         o_ddr3_reset_n   : out   std_logic;
         o_ddr3_cke       : out   std_logic;
         o_ddr3_cs_n      : out   std_logic;
         o_ddr3_ras_n     : out   std_logic;
         o_ddr3_cas_n     : out   std_logic;
         o_ddr3_we_n      : out   std_logic;
         o_ddr3_addr      : out   std_logic_vector(13 downto 0);
         o_ddr3_ba_addr   : out   std_logic_vector(2 downto 0);
         io_ddr3_dq       : inout std_logic_vector(15 downto 0);
         io_ddr3_dqs      : inout std_logic_vector(1 downto 0);
         io_ddr3_dqs_n    : inout std_logic_vector(1 downto 0);
         o_ddr3_dm        : out   std_logic_vector(1 downto 0);
         o_ddr3_odt       : out   std_logic;
         o_calib_complete : out   std_logic;
         o_debug1         : out   std_logic_vector(31 downto 0)
      );
   end component ddr3_top_wukong;

   -- Clock generation
   signal clk_fb          : std_logic;
   signal ddr3_clk_mmcm   : std_logic;
   signal ddr3_clk90_mmcm : std_logic;
   signal ctrl_clk_mmcm   : std_logic;
   signal ref_clk_mmcm    : std_logic;
   signal ddr3_clk        : std_logic;
   signal ddr3_clk90      : std_logic;
   signal ctrl_clk        : std_logic;
   signal ref_clk         : std_logic;
   signal mmcm_locked     : std_logic;

   signal ctrl_rst        : std_logic;

   -- Avalon in the controller clock domain, 128-bit
   signal wide_avm_write         : std_logic;
   signal wide_avm_read          : std_logic;
   signal wide_avm_address       : std_logic_vector(28 downto 0);
   signal wide_avm_writedata     : std_logic_vector(127 downto 0);
   signal wide_avm_byteenable    : std_logic_vector(15 downto 0);
   signal wide_avm_burstcount    : std_logic_vector(7 downto 0);
   signal wide_avm_readdata      : std_logic_vector(127 downto 0);
   signal wide_avm_readdatavalid : std_logic;
   signal wide_avm_waitrequest   : std_logic;

   -- Wishbone to UberDDR3
   signal wb_cyc   : std_logic;
   signal wb_stb   : std_logic;
   signal wb_we    : std_logic;
   signal wb_addr  : std_logic_vector(23 downto 0);
   signal wb_data  : std_logic_vector(127 downto 0);
   signal wb_sel   : std_logic_vector(15 downto 0);
   signal wb_stall : std_logic;
   signal wb_ack   : std_logic;
   signal wb_rdata : std_logic_vector(127 downto 0);

begin

   ---------------------------------------------------------------------------
   -- Clock generation: VCO = 100 MHz * 8 = 800 MHz
   ---------------------------------------------------------------------------

   i_mmcm_ddr3 : MMCME2_BASE
      generic map (
         BANDWIDTH          => "OPTIMIZED",
         CLKFBOUT_MULT_F    => 8.000,      -- VCO 800 MHz
         CLKFBOUT_PHASE     => 0.000,
         CLKIN1_PERIOD      => 10.0,       -- INPUT @ 100 MHz
         CLKOUT0_DIVIDE_F   => 2.000,      -- DDR3 @ 400 MHz
         CLKOUT0_PHASE      => 0.000,
         CLKOUT1_DIVIDE     => 2,          -- DDR3 @ 400 MHz, 90 degrees
         CLKOUT1_PHASE      => 90.000,
         CLKOUT2_DIVIDE     => 8,          -- Controller @ 100 MHz (= mem_clk)
         CLKOUT2_PHASE      => 0.000,
         CLKOUT3_DIVIDE     => 4,          -- IDELAYCTRL reference @ 200 MHz
         CLKOUT3_PHASE      => 0.000,
         DIVCLK_DIVIDE      => 1,
         REF_JITTER1        => 0.010,
         STARTUP_WAIT       => FALSE
      )
      port map (
         CLKFBIN  => clk_fb,
         CLKFBOUT => clk_fb,
         CLKIN1   => sys_clk_i,
         CLKOUT0  => ddr3_clk_mmcm,
         CLKOUT1  => ddr3_clk90_mmcm,
         CLKOUT2  => ctrl_clk_mmcm,
         CLKOUT3  => ref_clk_mmcm,
         LOCKED   => mmcm_locked,
         PWRDWN   => '0',
         RST      => '0'
      ); -- i_mmcm_ddr3

   i_bufg_ddr3   : BUFG port map (I => ddr3_clk_mmcm,   O => ddr3_clk);
   i_bufg_ddr390 : BUFG port map (I => ddr3_clk90_mmcm, O => ddr3_clk90);
   i_bufg_ctrl   : BUFG port map (I => ctrl_clk_mmcm,   O => ctrl_clk);
   i_bufg_ref    : BUFG port map (I => ref_clk_mmcm,    O => ref_clk);

   i_rst_ctrl : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => rst_i or not mmcm_locked,
         dest_clk  => ctrl_clk,
         dest_arst => ctrl_rst
      ); -- i_rst_ctrl

   ctrl_clk_o <= ctrl_clk;
   ctrl_rst_o <= ctrl_rst;

   ---------------------------------------------------------------------------
   -- Avalon chain (entirely in the ctrl_clk domain — no CDC)
   ---------------------------------------------------------------------------

   i_avm_increase : entity work.avm_increase
      generic map (
         G_SLAVE_ADDRESS_SIZE  => 32,
         G_SLAVE_DATA_SIZE     => 16,
         G_MASTER_ADDRESS_SIZE => 29,
         G_MASTER_DATA_SIZE    => 128
      )
      port map (
         clk_i                 => ctrl_clk,
         rst_i                 => ctrl_rst,
         s_avm_write_i         => avm_write_i,
         s_avm_read_i          => avm_read_i,
         s_avm_address_i       => avm_address_i,
         s_avm_writedata_i     => avm_writedata_i,
         s_avm_byteenable_i    => avm_byteenable_i,
         s_avm_burstcount_i    => avm_burstcount_i,
         s_avm_readdata_o      => avm_readdata_o,
         s_avm_readdatavalid_o => avm_readdatavalid_o,
         s_avm_waitrequest_o   => avm_waitrequest_o,
         m_avm_write_o         => wide_avm_write,
         m_avm_read_o          => wide_avm_read,
         m_avm_address_o       => wide_avm_address,
         m_avm_writedata_o     => wide_avm_writedata,
         m_avm_byteenable_o    => wide_avm_byteenable,
         m_avm_burstcount_o    => wide_avm_burstcount,
         m_avm_readdata_i      => wide_avm_readdata,
         m_avm_readdatavalid_i => wide_avm_readdatavalid,
         m_avm_waitrequest_i   => wide_avm_waitrequest
      ); -- i_avm_increase

   i_avm_to_wb : entity work.avm_to_wb
      generic map (
         G_AVM_ADDRESS_SIZE => 29,
         G_WB_ADDRESS_SIZE  => 24,
         G_DATA_SIZE        => 128
      )
      port map (
         clk_i                 => ctrl_clk,
         rst_i                 => ctrl_rst,
         s_avm_write_i         => wide_avm_write,
         s_avm_read_i          => wide_avm_read,
         s_avm_address_i       => wide_avm_address,
         s_avm_writedata_i     => wide_avm_writedata,
         s_avm_byteenable_i    => wide_avm_byteenable,
         s_avm_burstcount_i    => wide_avm_burstcount,
         s_avm_readdata_o      => wide_avm_readdata,
         s_avm_readdatavalid_o => wide_avm_readdatavalid,
         s_avm_waitrequest_o   => wide_avm_waitrequest,
         wb_cyc_o              => wb_cyc,
         wb_stb_o              => wb_stb,
         wb_we_o               => wb_we,
         wb_addr_o             => wb_addr,
         wb_data_o             => wb_data,
         wb_sel_o              => wb_sel,
         wb_stall_i            => wb_stall,
         wb_ack_i              => wb_ack,
         wb_data_i             => wb_rdata
      ); -- i_avm_to_wb

   ---------------------------------------------------------------------------
   -- UberDDR3
   ---------------------------------------------------------------------------

   i_ddr3_top : ddr3_top_wukong
      generic map (
         CONTROLLER_CLK_PERIOD => 10_000,
         DDR3_CLK_PERIOD       => 2_500
      )
      port map (
         i_controller_clk => ctrl_clk,
         i_ddr3_clk       => ddr3_clk,
         i_ref_clk        => ref_clk,
         i_ddr3_clk_90    => ddr3_clk90,
         i_rst_n          => not ctrl_rst,
         i_wb_cyc         => wb_cyc,
         i_wb_stb         => wb_stb,
         i_wb_we          => wb_we,
         i_wb_addr        => wb_addr,
         i_wb_data        => wb_data,
         i_wb_sel         => wb_sel,
         o_wb_stall       => wb_stall,
         o_wb_ack         => wb_ack,
         o_wb_err         => open,
         o_wb_data        => wb_rdata,
         o_ddr3_clk_p     => ddr3_clk_p_o,
         o_ddr3_clk_n     => ddr3_clk_n_o,
         o_ddr3_reset_n   => ddr3_reset_n_o,
         o_ddr3_cke       => ddr3_cke_o,
         o_ddr3_cs_n      => open,
         o_ddr3_ras_n     => ddr3_ras_n_o,
         o_ddr3_cas_n     => ddr3_cas_n_o,
         o_ddr3_we_n      => ddr3_we_n_o,
         o_ddr3_addr      => ddr3_addr_o,
         o_ddr3_ba_addr   => ddr3_ba_o,
         io_ddr3_dq       => ddr3_dq_io,
         io_ddr3_dqs      => ddr3_dqs_p_io,
         io_ddr3_dqs_n    => ddr3_dqs_n_io,
         o_ddr3_dm        => ddr3_dm_o,
         o_ddr3_odt       => ddr3_odt_o,
         o_calib_complete => calib_complete_o,
         o_debug1         => open
      ); -- i_ddr3_top

end architecture synthesis;
