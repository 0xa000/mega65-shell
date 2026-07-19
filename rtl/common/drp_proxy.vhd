-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
----------------------------------------------------------------------------------
-- DRP write proxy — boundary v2 (static shell)
--
-- Single multi-target DRP window shared by CORE_A (target=0) and CORE_B
-- (target=1); target 2 (video MMCM) is reserved and not wired in v2.
--
-- Protocol (docs/BOUNDARY-V2.md):
--   1. RM drives target/addr/data/mask and flips drp_req_o (toggle).
--   2. Shell (clk_100): sees req ≠ ack through a two-FF synchroniser;
--      payload is stable by construction.  Performs DRP read (DRDY), masks
--      the read data, writes back (DRDY), then flips drp_ack_i.
--   3. RM sees ack = req: may present the next row.
--
-- The RM is expected to assert the target MMCM's reset (via clkctl) before
-- the first row and release it after the last, then wait for the lock status
-- bit.  The proxy additionally reports drp_active_a/b so shell_top can OR
-- these into the MMCM RST inputs as a belt-and-suspenders guard.
--
-- While decouple='1' (RP dark) the whole handshake state is held at zero:
-- partition outputs toggle randomly during reconfiguration, and the next
-- RM starts with req='0' out of GSR — re-zeroing ack here keeps the toggle
-- protocol consistent across swaps (otherwise an odd transaction count from
-- the previous RM would leave ack='1' and fire a spurious write).
--
-- DFX carve-out done by 0xa000 in 2026
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity drp_proxy is
   port (
      clk          : in  std_logic;    -- clk_100

      -- System reset (not reset_shell_n, so the proxy stays alive during RM swap)
      rst          : in  std_logic;

      -- Freeze while the RP is dark (loader active)
      decouple     : in  std_logic;

      -- RM-facing partition pins (RM's arbitrary clock domain → synchronised here)
      drp_target   : in  std_logic_vector(2 downto 0);  -- 0=CORE_A, 1=CORE_B
      drp_addr     : in  std_logic_vector(6 downto 0);
      drp_data     : in  std_logic_vector(15 downto 0);
      drp_mask     : in  std_logic_vector(15 downto 0);  -- 1=preserve-from-read, 0=overwrite
      drp_req      : in  std_logic;    -- toggle: RM toggles to issue a request
      drp_ack      : out std_logic;    -- toggle: shell toggles when complete

      -- In-progress flags for shell_top to OR into MMCM RST pins
      drp_active_a : out std_logic;   -- transaction targeting CORE_A in progress
      drp_active_b : out std_logic;   -- transaction targeting CORE_B in progress

      -- CORE_A DRP bus (@ clk_100; connects to shell_core_clk)
      a_daddr      : out std_logic_vector(6 downto 0);
      a_di         : out std_logic_vector(15 downto 0);
      a_do         : in  std_logic_vector(15 downto 0);
      a_den        : out std_logic;
      a_dwe        : out std_logic;
      a_drdy       : in  std_logic;

      -- CORE_B DRP bus
      b_daddr      : out std_logic_vector(6 downto 0);
      b_di         : out std_logic_vector(15 downto 0);
      b_do         : in  std_logic_vector(15 downto 0);
      b_den        : out std_logic;
      b_dwe        : out std_logic;
      b_drdy       : in  std_logic
      -- target 2 (video MMCM): reserved, not wired in v2
   );
end entity drp_proxy;

architecture rtl of drp_proxy is

   type state_t is (IDLE, DO_READ, WAIT_RD, DO_WRITE, WAIT_WR);
   signal state       : state_t := IDLE;

   -- Toggle-handshake state
   signal ack_reg     : std_logic                     := '0';
   signal req_meta    : std_logic                     := '0';
   signal req_sync    : std_logic                     := '0';

   -- Latched payload (captured when the mismatch is first seen)
   signal lat_target  : std_logic_vector(2 downto 0);
   signal lat_addr    : std_logic_vector(6 downto 0);
   signal lat_data    : std_logic_vector(15 downto 0);
   signal lat_mask    : std_logic_vector(15 downto 0);

   -- Read-data captured from DRDY cycle
   signal read_data   : std_logic_vector(15 downto 0);

   -- Internal active flags driven in the process
   signal active_a    : std_logic := '0';
   signal active_b    : std_logic := '0';

begin

   drp_ack      <= ack_reg;
   drp_active_a <= active_a;
   drp_active_b <= active_b;

   process (clk)
   begin
      if rising_edge(clk) then

         -- Two-FF synchroniser for req (toggle from RM's arbitrary domain)
         req_meta <= drp_req;
         req_sync <= req_meta;

         -- Default: DRP enables are deasserted every cycle;
         -- each state that needs them asserts for exactly one cycle.
         a_den <= '0';  a_dwe <= '0';
         b_den <= '0';  b_dwe <= '0';
         active_a <= '0';
         active_b <= '0';

         if rst = '1' or decouple = '1' then
            state    <= IDLE;
            ack_reg  <= '0';
            req_meta <= '0';
            req_sync <= '0';

         else
            case state is

               -- ---------------------------------------------------------------
               when IDLE =>
                  if req_sync /= ack_reg then
                     -- Latch the stable payload before the FSM touches DRP
                     lat_target <= drp_target;
                     lat_addr   <= drp_addr;
                     lat_data   <= drp_data;
                     lat_mask   <= drp_mask;
                     state <= DO_READ;
                  end if;

               -- ---------------------------------------------------------------
               when DO_READ =>
                  -- Issue a single-cycle DRP read to the latched target.
                  -- Both active flags are asserted from here through WAIT_WR so
                  -- that shell_top can guard the MMCM RST.
                  case lat_target is
                     when "000" =>
                        a_daddr  <= lat_addr;
                        a_den    <= '1';
                        active_a <= '1';
                     when "001" =>
                        b_daddr  <= lat_addr;
                        b_den    <= '1';
                        active_b <= '1';
                     when others =>
                        -- Reserved target: skip read/write, just acknowledge
                        ack_reg <= req_sync;
                        state   <= IDLE;
                  end case;
                  if lat_target = "000" or lat_target = "001" then
                     state <= WAIT_RD;
                  end if;

               -- ---------------------------------------------------------------
               when WAIT_RD =>
                  -- Hold active flag while waiting for DRDY
                  case lat_target is
                     when "000" =>
                        active_a <= '1';
                        if a_drdy = '1' then
                           read_data <= a_do;
                           state <= DO_WRITE;
                        end if;
                     when "001" =>
                        active_b <= '1';
                        if b_drdy = '1' then
                           read_data <= b_do;
                           state <= DO_WRITE;
                        end if;
                     when others =>
                        ack_reg <= req_sync;
                        state   <= IDLE;
                  end case;

               -- ---------------------------------------------------------------
               when DO_WRITE =>
                  -- DI = (read_data & mask) | data
                  --   mask=1 bit: preserve bit from read; mask=0 bit: use data bit
                  case lat_target is
                     when "000" =>
                        a_daddr  <= lat_addr;
                        a_di     <= (read_data and lat_mask) or lat_data;
                        a_den    <= '1';
                        a_dwe    <= '1';
                        active_a <= '1';
                     when "001" =>
                        b_daddr  <= lat_addr;
                        b_di     <= (read_data and lat_mask) or lat_data;
                        b_den    <= '1';
                        b_dwe    <= '1';
                        active_b <= '1';
                     when others =>
                        ack_reg <= req_sync;
                        state   <= IDLE;
                  end case;
                  if lat_target = "000" or lat_target = "001" then
                     state <= WAIT_WR;
                  end if;

               -- ---------------------------------------------------------------
               when WAIT_WR =>
                  case lat_target is
                     when "000" =>
                        active_a <= '1';
                        if a_drdy = '1' then
                           ack_reg <= req_sync;
                           state   <= IDLE;
                        end if;
                     when "001" =>
                        active_b <= '1';
                        if b_drdy = '1' then
                           ack_reg <= req_sync;
                           state   <= IDLE;
                        end if;
                     when others =>
                        ack_reg <= req_sync;
                        state   <= IDLE;
                  end case;

            end case;
         end if;
      end if;
   end process;

end architecture rtl;
