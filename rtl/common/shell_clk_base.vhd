-- SPDX-License-Identifier: GPL-3.0-only
-- Imported from the MiSTer2MEGA65 framework by sy2002 & MJoergen (GPLv3),
-- where this file is clk_m2m.vhd; renamed with shell-neutral clock names.
-- Local modifications are listed in ATTRIBUTION.md.
-------------------------------------------------------------------------------------------------------------
-- Shell base clock generator (from MiSTer2MEGA65 clk_m2m.vhd):
--
--   loader domain expects 50 MHz (shell loader block, and a general-purpose
--                                 50 MHz service clock for the RM)
--   memory controller expects 100 MHz (+ delayed / 200 MHz reference taps)
--   audio processing expects 12.288 MHz
--
-- MiSTer2MEGA65 done by sy2002 and MJoergen in 2022 and licensed under GPL v3
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity shell_clk_base is
   port (
      sys_clk_i          : in  std_logic;   -- expects 100 MHz
      sys_rstn_i         : in  std_logic;   -- Asynchronous, asserted low
      core_rstn_i        : in  std_logic;   -- Reset only the core, asserted low

      loader_clk_o       : out std_logic;   -- 50 MHz loader/service clock
      loader_rst_o       : out std_logic;   -- loader domain reset, synchronized

      mem_clk_o          : out std_logic;   -- memory controller @ 100 MHz
      mem_clk_del_o      : out std_logic;   -- memory controller @ 100 MHz phase delayed
      mem_delay_refclk_o : out std_logic;   -- memory controller @ 200 MHz
      mem_rst_o          : out std_logic;   -- memory domain reset, synchronized

      audio_clk_o        : out std_logic;   -- Audio's 12.288 MHz clock
      audio_rst_o        : out std_logic;   -- Audio's reset, synchronized

      sys_pps_o          : out std_logic    -- One pulse per second (in sys_clk domain)
   );
end entity shell_clk_base;

architecture rtl of shell_clk_base is

signal audio_fb_mmcm       : std_logic;
signal base_fb_pll         : std_logic;
signal loader_clk_pll      : std_logic;
signal mem_clk_pll         : std_logic;
signal mem_clk_del_pll     : std_logic;
signal mem_delay_refclk_pll: std_logic;
signal audio_clk_mmcm      : std_logic;

signal base_locked         : std_logic;
signal audio_locked        : std_logic;

signal sys_counter         : natural range 0 to 99_999_999;

begin

   -------------------------------------------------------------------------------------
   -- Generate loader and memory-controller clocks
   -------------------------------------------------------------------------------------

   -- VCO frequency range for Artix 7 speed grade -1 : 600 MHz - 1200 MHz
   -- f_VCO = f_CLKIN * CLKFBOUT_MULT_F / DIVCLK_DIVIDE

   i_pll_base : PLLE2_BASE
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKFBOUT_MULT        => 12,         -- 1200 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         CLKOUT0_DIVIDE       => 24,         -- loader @ 50 MHz
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_PHASE        => 0.000,
         CLKOUT1_DIVIDE       => 12,         -- memory @ 100 MHz
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT1_PHASE        => 0.000,
         CLKOUT2_DIVIDE       => 6,          -- memory @ 200 MHz
         CLKOUT2_DUTY_CYCLE   => 0.500,
         CLKOUT2_PHASE        => 0.000,
         CLKOUT3_DIVIDE       => 12,         -- memory @ 100 MHz phase delayed
         CLKOUT3_DUTY_CYCLE   => 0.500,
         CLKOUT3_PHASE        => 90.000,
         DIVCLK_DIVIDE        => 1,
         REF_JITTER1          => 0.010,
         STARTUP_WAIT         => "FALSE"
      )
      port map (
         CLKFBIN             => base_fb_pll,
         CLKFBOUT            => base_fb_pll,
         CLKIN1              => sys_clk_i,
         CLKOUT0             => loader_clk_pll,
         CLKOUT1             => mem_clk_pll,
         CLKOUT2             => mem_delay_refclk_pll,
         CLKOUT3             => mem_clk_del_pll,
         LOCKED              => base_locked,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_pll_base

   i_clk_audio : MMCME2_BASE
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKFBOUT_MULT_F      => 48.000,     -- 960 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKIN1_PERIOD        => 10.0,       -- INPUT @ 100 MHz
         CLKOUT0_DIVIDE_F     => 78.125,     -- AUDIO @ 12.288 MHz
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_PHASE        => 0.000,
         DIVCLK_DIVIDE        => 5,
         REF_JITTER1          => 0.010,
         STARTUP_WAIT         => FALSE
      )
      port map (
         CLKFBIN             => audio_fb_mmcm,
         CLKFBOUT            => audio_fb_mmcm,
         CLKIN1              => sys_clk_i,
         CLKOUT0             => audio_clk_mmcm,
         LOCKED              => audio_locked,
         PWRDWN              => '0',
         RST                 => '0'
      ); -- i_clk_audio

   ---------------------------------------------------------------------------------------
   -- Output buffering
   ---------------------------------------------------------------------------------------

   loader_clk_bufg : BUFG
      port map (
         I => loader_clk_pll,
         O => loader_clk_o
      );

   mem_clk_bufg : BUFG
      port map (
         I => mem_clk_pll,
         O => mem_clk_o
      );

   mem_clk_del_bufg : BUFG
      port map (
         I => mem_clk_del_pll,
         O => mem_clk_del_o
      );

   mem_delay_refclk_bufg : BUFG
      port map (
         I => mem_delay_refclk_pll,
         O => mem_delay_refclk_o
      );

   audio_clk_bufg : BUFG
      port map (
         I => audio_clk_mmcm,
         O => audio_clk_o
      );

   -------------------------------------
   -- Reset generation
   -------------------------------------

   i_xpm_cdc_async_rst_loader : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1
      )
      port map (
         src_arst  => not (base_locked and sys_rstn_i),    -- 1-bit input: Source reset signal.
         dest_clk  => loader_clk_o,     -- 1-bit input: Destination clock.
         dest_arst => loader_rst_o      -- 1-bit output: src_rst synchronized to the destination clock domain.
                                        -- This output is registered.
      );

   i_xpm_cdc_async_rst_mem : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         -- 1-bit input: Source reset signal
         -- Important: The memory controller needs to be reset when ascal is being reset! The Avalon memory
         -- interface assumes that both ends maintain state information and agree on this state information.
         -- Therefore, one side can not be reset in the middle of e.g. a burst transaction, without the other
         -- end becoming confused.
         src_arst  => not (base_locked and sys_rstn_i and core_rstn_i),
         dest_clk  => mem_clk_o,        -- 1-bit input: Destination clock.
         dest_arst => mem_rst_o         -- 1-bit output: src_rst synchronized to the destination clock domain.
                                        -- This output is registered.
      );

   i_xpm_cdc_async_rst_audio : xpm_cdc_async_rst
      generic map (
         RST_ACTIVE_HIGH => 1,
         DEST_SYNC_FF    => 6
      )
      port map (
         src_arst  => not (audio_locked and sys_rstn_i),   -- 1-bit input: Source reset signal.
         dest_clk  => audio_clk_o,      -- 1-bit input: Destination clock.
         dest_arst => audio_rst_o       -- 1-bit output: src_rst synchronized to the destination clock domain.
                                        -- This output is registered.
      );

   p_sys_pps : process (sys_clk_i)
   begin
      if rising_edge(sys_clk_i) then
         if sys_counter < 99_999_999 then
            sys_counter <= sys_counter + 1;
            sys_pps_o   <= '0';
         else
            sys_counter <= 0;
            sys_pps_o   <= '1';
         end if;
      end if;
   end process p_sys_pps;

end architecture rtl;
