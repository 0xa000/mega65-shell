-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
----------------------------------------------------------------------------------
-- Shell core-clock service — boundary v2 (board-agnostic)
--
-- Provides the two core-facing MMCMs (CORE_A, CORE_B) with the frozen
-- crossbar topology described in docs/BOUNDARY-V2.md:
--
--                    +----------+  CLKOUT1  +--------------+
--   clk_100 ------+->| MMCM     |--------->|              |
--                 |  | CORE_A   |  CLKOUT0 | BUFGMUX_CTRL |--> core_clk1
--                 |  +----------+----+---->|  sel: mux(1) |
--                 |       | spare    |     +--------------+
--                 |       v CLKOUT2  |
--                 |  +---------+     |     +--------------+
--                 +->| BUFGMUX |     +---->|              |
--   (cascade) ------>| _CTRL   |--+        | BUFGMUX_CTRL |--> core_clk0
--                    +---------+  |  +---->|  sel: mux(0) |
--                                 v  |     +--------------+
--   Generic outputs (no swap): core_clk0 = CLKOUT0, core_clk1 = CLKOUT1.
--   Only CLKOUT0/CLKFBOUT support fractional divide, so core_clk0 is the
--   fractional-capable output; the RM maps its functions (video/cpu/...) onto
--   the two outputs given this documented capability.
--                    +----------+    |
--                    | MMCM     |----+  (CORE_B.clk0/clk1 are the
--                    | CORE_B   |        second mux inputs)
--                    +----------+
--
-- Default preset: CORE_A boots at 54 MHz (democore) on both outputs.
-- An RM that never touches the DRP service gets v1 behavior unchanged.
-- CORE_B is held in reset until the RM explicitly enables it via clkctl.
-- Lock-chaining: CORE_B RST is forced whenever its upstream (CORE_A) is
-- unlocked and cascade is selected.
--
-- DRP DCLK is clk_100 (from the board clock generator, independent of the MMCMs
-- being reprogrammed). ZHOLD compensation with a BUFG in the feedback
-- path — the same idiom as CORE/vhdl/clk.vhd and video_out_clock.vhd,
-- both hardware-verified on this board (video_out_clock incl. DRP).
--
-- DFX carve-out done by 0xa000 in 2026
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity shell_core_clk is
   port (
      clk_100        : in  std_logic;    -- 100 MHz board-level clock

      -- Quasi-static control from RM (stability-filtered in shell_top before here)
      mux_sel        : in  std_logic_vector(2 downto 0);  -- [0]=core_clk0, [1]=core_clk1, [2]=core_clk2 mux sel
      cascade_en     : in  std_logic;    -- 0=CORE_B fed from clk_100, 1=CORE_A.CLKOUT2
      core_a_rst     : in  std_logic;    -- RM-asserted CORE_A reset (clkctl[3] | drp_active_a)
      core_b_rst     : in  std_logic;    -- RM-asserted CORE_B reset (clkctl[4] | drp_active_b)

      -- CORE_A DRP bus (from drp_proxy)
      core_a_daddr   : in  std_logic_vector(6 downto 0);
      core_a_di      : in  std_logic_vector(15 downto 0);
      core_a_do      : out std_logic_vector(15 downto 0);
      core_a_den     : in  std_logic;
      core_a_dwe     : in  std_logic;
      core_a_drdy    : out std_logic;

      -- CORE_B DRP bus (from drp_proxy)
      core_b_daddr   : in  std_logic_vector(6 downto 0);
      core_b_di      : in  std_logic_vector(15 downto 0);
      core_b_do      : out std_logic_vector(15 downto 0);
      core_b_den     : in  std_logic;
      core_b_dwe     : in  std_logic;
      core_b_drdy    : out std_logic;

      -- Status to RM (clkstat bits 0/1)
      core_a_locked  : out std_logic;
      core_b_locked  : out std_logic;

      -- Generic core clocks + synchronised resets (BUFG-driven, cross the RM
      -- boundary).  The RM maps its functions (cpu/video/...) onto these given
      -- each output's MMCM capability:
      --   core_clk0 = CLKOUT0 : fractional-divide (_F) capable
      --   core_clk1 = CLKOUT1 : integer divide only
      --   core_clk2 = CLKOUT2 : integer divide only; on CORE_A this CLKOUT
      --               doubles as the cascade reference — an RM that enables
      --               the cascade sees that reference on core_clk2(A)
      core_clk0      : out std_logic;
      core_clk0_rst  : out std_logic;
      core_clk1      : out std_logic;
      core_clk1_rst  : out std_logic;
      core_clk2      : out std_logic;
      core_clk2_rst  : out std_logic
   );
end entity shell_core_clk;

architecture rtl of shell_core_clk is

   -- CORE_A MMCM raw (pre-BUFG) outputs
   signal core_a_clkfb        : std_logic;
   signal core_a_clkfb_buf    : std_logic;
   signal core_a_clk0_raw     : std_logic;
   signal core_a_clk1_raw     : std_logic;
   signal core_a_clk2_raw     : std_logic;    -- spare / cascade source
   signal core_a_locked_i     : std_logic;

   -- CORE_B MMCM raw outputs
   signal core_b_clkfb        : std_logic;
   signal core_b_clkfb_buf    : std_logic;
   signal core_b_clk0_raw     : std_logic;
   signal core_b_clk1_raw     : std_logic;
   signal core_b_clk2_raw     : std_logic;
   signal core_b_locked_i     : std_logic;

   -- NOTE: the MMCM outputs feed the BUFGMUX_CTRLs DIRECTLY (dedicated
   -- CMT->BUFG routing).  An earlier revision put a BUFG on each output
   -- first; that creates BUFG->BUFG cascades, which the placer requires
   -- to be adjacent-and-cyclic (rule_cascaded_bufg) — satisfiable by luck
   -- on the Wukong A100T, but the A200T clock placer failed on it.  The
   -- buffered copies drove nothing but the muxes, so the BUFGs were
   -- redundant; removing them also frees 5 BUFGs.

   -- Cascade mux output → CORE_B CLKIN1
   signal core_b_clkin        : std_logic;

   -- Mux output clocks (internal; also drive the output ports)
   signal core_clk0_int        : std_logic;
   signal core_clk1_int        : std_logic;
   signal core_clk2_int        : std_logic;

   -- Reset source: unlock signal of whichever MMCM is currently selected
   signal core_clk0_src_unlocked : std_logic;
   signal core_clk1_src_unlocked : std_logic;
   signal core_clk2_src_unlocked : std_logic;

begin

   core_a_locked <= core_a_locked_i;
   core_b_locked <= core_b_locked_i;

   -- Track which MMCM's lock feeds each output reset.  mux_sel is quasi-static
   -- (64-cycle stability filter upstream) so a combinational mux is safe.
   core_clk0_src_unlocked <= (not core_a_locked_i) when mux_sel(0) = '0' else (not core_b_locked_i);
   core_clk1_src_unlocked <= (not core_a_locked_i) when mux_sel(1) = '0' else (not core_b_locked_i);
   core_clk2_src_unlocked <= (not core_a_locked_i) when mux_sel(2) = '0' else (not core_b_locked_i);

   ---------------------------------------------------------------------------
   -- CORE_A MMCM
   -- Default preset: 54 MHz (democore) on all outputs.  VCO = 100 * 13.5 =
   -- 1350 MHz — the only VCO in the -2 range (600-1440) that is both a legal
   -- fractional multiple of 0.125 from 100 MHz and an integer multiple of
   -- 54 MHz (CLKOUT1/2 have integer dividers only).
   -- Reprogrammed at runtime via drp_proxy using the XAPP888 DRP sequence.
   ---------------------------------------------------------------------------
   i_core_a : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",       -- BUFG'd feedback loop (clk.vhd idiom)
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,          -- 100 MHz input
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 1,
         CLKFBOUT_MULT_F      => 13.500,        -- VCO = 1350 MHz (0.125 granularity, A7-2 range 600-1440)
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 25.000,        -- 54 MHz  (core_clk0 default; fractional-capable)
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => 25,            -- 54 MHz  (core_clk1 default; integer only)
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT2_DIVIDE       => 25,            -- 54 MHz spare for cascade (safe default; DRP retunes)
         CLKOUT2_PHASE        => 0.000,
         CLKOUT2_DUTY_CYCLE   => 0.500
      )
      port map (
         CLKFBOUT             => core_a_clkfb,
         CLKFBIN              => core_a_clkfb_buf,
         CLKOUT0              => core_a_clk0_raw,
         CLKOUT1              => core_a_clk1_raw,
         CLKOUT2              => core_a_clk2_raw,
         CLKOUT3              => open,
         CLKOUT4              => open,
         CLKOUT5              => open,
         CLKOUT6              => open,
         CLKOUT0B             => open,
         CLKOUT1B             => open,
         CLKOUT2B             => open,
         CLKOUT3B             => open,
         CLKFBOUTB            => open,
         CLKIN1               => clk_100,
         CLKIN2               => '0',
         CLKINSEL             => '1',
         DADDR                => core_a_daddr,
         DCLK                 => clk_100,        -- stable reference, unaffected by CORE_A reset
         DEN                  => core_a_den,
         DI                   => core_a_di,
         DO                   => core_a_do,
         DRDY                 => core_a_drdy,
         DWE                  => core_a_dwe,
         PSCLK                => '0',
         PSEN                 => '0',
         PSINCDEC             => '0',
         PSDONE               => open,
         LOCKED               => core_a_locked_i,
         CLKINSTOPPED         => open,
         CLKFBSTOPPED         => open,
         PWRDWN               => '0',
         RST                  => core_a_rst
      ); -- i_core_a

   buf_a_fb : BUFG port map (I => core_a_clkfb, O => core_a_clkfb_buf);
   -- CLKOUT0/1/2 feed the BUFGMUX_CTRLs directly (see note at the signal
   -- declarations); only the feedback path keeps its deskew BUFG

   ---------------------------------------------------------------------------
   -- CORE_B MMCM
   -- Default preset: same 54 MHz as CORE_A (safe out-of-reset state).
   -- Input comes from the cascade BUFGMUX_CTRL; default is clk_100.
   -- Lock-chain: RST is forced while the selected upstream (CORE_A, when
   -- cascade_en=1) is unlocked, in addition to the RM-controlled reset bit.
   ---------------------------------------------------------------------------
   i_core_b : MMCME2_ADV
      generic map (
         BANDWIDTH            => "OPTIMIZED",
         CLKOUT4_CASCADE      => FALSE,
         COMPENSATION         => "ZHOLD",
         STARTUP_WAIT         => FALSE,
         CLKIN1_PERIOD        => 10.0,          -- matches default non-cascade input (clk_100)
         REF_JITTER1          => 0.010,
         DIVCLK_DIVIDE        => 1,
         CLKFBOUT_MULT_F      => 13.500,        -- VCO = 1350 MHz
         CLKFBOUT_PHASE       => 0.000,
         CLKFBOUT_USE_FINE_PS => FALSE,
         CLKOUT0_DIVIDE_F     => 25.000,        -- 54 MHz
         CLKOUT0_PHASE        => 0.000,
         CLKOUT0_DUTY_CYCLE   => 0.500,
         CLKOUT0_USE_FINE_PS  => FALSE,
         CLKOUT1_DIVIDE       => 25,            -- 54 MHz
         CLKOUT1_PHASE        => 0.000,
         CLKOUT1_DUTY_CYCLE   => 0.500,
         CLKOUT2_DIVIDE       => 25,            -- 54 MHz (core_clk2 default)
         CLKOUT2_PHASE        => 0.000,
         CLKOUT2_DUTY_CYCLE   => 0.500
      )
      port map (
         CLKFBOUT             => core_b_clkfb,
         CLKFBIN              => core_b_clkfb_buf,
         CLKOUT0              => core_b_clk0_raw,
         CLKOUT1              => core_b_clk1_raw,
         CLKOUT2              => core_b_clk2_raw,
         CLKOUT3              => open,
         CLKOUT4              => open,
         CLKOUT5              => open,
         CLKOUT6              => open,
         CLKOUT0B             => open,
         CLKOUT1B             => open,
         CLKOUT2B             => open,
         CLKOUT3B             => open,
         CLKFBOUTB            => open,
         CLKIN1               => core_b_clkin,  -- from cascade BUFGMUX_CTRL
         CLKIN2               => '0',
         CLKINSEL             => '1',
         DADDR                => core_b_daddr,
         DCLK                 => clk_100,
         DEN                  => core_b_den,
         DI                   => core_b_di,
         DO                   => core_b_do,
         DRDY                 => core_b_drdy,
         DWE                  => core_b_dwe,
         PSCLK                => '0',
         PSEN                 => '0',
         PSINCDEC             => '0',
         PSDONE               => open,
         LOCKED               => core_b_locked_i,
         CLKINSTOPPED         => open,
         CLKFBSTOPPED         => open,
         PWRDWN               => '0',
         -- Lock-chain: also hold in reset while upstream CORE_A is unlocked (cascade case)
         RST                  => core_b_rst or (cascade_en and not core_a_locked_i)
      ); -- i_core_b

   buf_b_fb : BUFG port map (I => core_b_clkfb, O => core_b_clkfb_buf);

   ---------------------------------------------------------------------------
   -- Cascade mux: selects CORE_B's clock input
   --   I0 = clk_100          (cascade_en=0, default)
   --   I1 = CORE_A.CLKOUT2   (cascade_en=1; retuned via DRP before use)
   -- cascade_en is quasi-static (stability-filtered in shell_top).
   ---------------------------------------------------------------------------
   i_cascade_mux : BUFGMUX_CTRL
      port map (
         I0 => clk_100,
         I1 => core_a_clk2_raw,
         S  => cascade_en,
         O  => core_b_clkin
      ); -- i_cascade_mux

   ---------------------------------------------------------------------------
   -- Output clock muxes (BUFGMUX_CTRL, glitch-free, quasi-static select).
   -- Generic outputs — each core_clkN follows CORE_?.CLKOUTN straight (no
   -- swap): the RM maps its functions (video/cpu/...) onto the outputs.
   --   core_clk0: I0=CORE_A.clk0, I1=CORE_B.clk0, sel=mux_sel[0]  (CLKOUT0)
   --   core_clk1: I0=CORE_A.clk1, I1=CORE_B.clk1, sel=mux_sel[1]  (CLKOUT1)
   -- Only CLKOUT0/CLKFBOUT support fractional divide (_F), so core_clk0 is the
   -- fractional-capable output; an RM whose pixel clock is fractional (e.g.
   -- VIC20's 70.926 MHz = /13.5) must place it on core_clk0.  This capability
   -- is documented in the boundary spec; the shell no longer names outputs
   -- "main"/"video".
   ---------------------------------------------------------------------------
   i_mux_clk0 : BUFGMUX_CTRL
      port map (
         I0 => core_a_clk0_raw,
         I1 => core_b_clk0_raw,
         S  => mux_sel(0),
         O  => core_clk0_int
      ); -- i_mux_clk0

   i_mux_clk1 : BUFGMUX_CTRL
      port map (
         I0 => core_a_clk1_raw,
         I1 => core_b_clk1_raw,
         S  => mux_sel(1),
         O  => core_clk1_int
      ); -- i_mux_clk1

   -- core_clk2 (over-provisioned generic output, boundary v3): CLKOUT2 of
   -- both MMCMs.  On CORE_A that CLKOUT doubles as the cascade reference.
   i_mux_clk2 : BUFGMUX_CTRL
      port map (
         I0 => core_a_clk2_raw,
         I1 => core_b_clk2_raw,
         S  => mux_sel(2),
         O  => core_clk2_int
      ); -- i_mux_clk2

   core_clk0 <= core_clk0_int;
   core_clk1 <= core_clk1_int;
   core_clk2 <= core_clk2_int;

   ---------------------------------------------------------------------------
   -- Output reset synchronisers: async-assert on unlock, sync-deassert.
   -- Tracks the selected MMCM so the reset deasserts only once the active
   -- source is locked.
   ---------------------------------------------------------------------------
   i_rst_clk0 : xpm_cdc_async_rst
      generic map (RST_ACTIVE_HIGH => 1, DEST_SYNC_FF => 6)
      port map (
         src_arst  => core_clk0_src_unlocked,
         dest_clk  => core_clk0_int,
         dest_arst => core_clk0_rst
      ); -- i_rst_clk0

   i_rst_clk1 : xpm_cdc_async_rst
      generic map (RST_ACTIVE_HIGH => 1, DEST_SYNC_FF => 6)
      port map (
         src_arst  => core_clk1_src_unlocked,
         dest_clk  => core_clk1_int,
         dest_arst => core_clk1_rst
      ); -- i_rst_clk1

   i_rst_clk2 : xpm_cdc_async_rst
      generic map (RST_ACTIVE_HIGH => 1, DEST_SYNC_FF => 6)
      port map (
         src_arst  => core_clk2_src_unlocked,
         dest_clk  => core_clk2_int,
         dest_arst => core_clk2_rst
      ); -- i_rst_clk2

end architecture rtl;
