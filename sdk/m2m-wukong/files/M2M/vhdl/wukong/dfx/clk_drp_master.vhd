----------------------------------------------------------------------------------
-- Core-clock DRP master — boundary v2 RM-side helper
--
-- Drives the shell's DRP write proxy at RM boot to reprogram the shell's
-- core MMCMs, the way a flat core drove its own MMCM generics
-- (BOUNDARY-V2.md: "clk_drp_master").  Runs entirely in the sys_clk_i
-- domain (shell-fixed 100 MHz, same domain as the shell proxy — never
-- reprogrammed), so the sequence is immune to the core clock changing
-- underneath it:
--
--   1. boot delay (let the shell's clkctl stability filter settle)
--   2. assert the target MMCM reset via clkctl (XAPP888: RST during DRP)
--   3. stream the preset ROM rows through the toggle handshake
--   4. release the MMCM reset, wait for the lock bit in clkstat
--
-- While the MMCM relocks, the shell's lock-based main_rst/video_rst hold
-- the RM's core domains in reset — release order is shell-enforced, the
-- core never runs a cycle at a half-programmed frequency.
--
-- The ROM lives at the instantiation site (rom_idx_o/rom_row_i pair), so
-- this FSM stays core-agnostic; tables are generated from the core's one
-- frequency table by M2M/tools/mmcm_drp_table.py.
--
-- Wukong DFX carve-out done by 0xa000 in 2026, licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity clk_drp_master is
   generic (
      G_NUM_ROWS     : natural;                  -- rows in the preset ROM
      G_BOOT_DELAY   : natural := 1024;          -- sys_clk cycles before starting
      G_RST_SETTLE   : natural := 256;           -- cycles for clkctl filter (64) + CDC margin
      -- clkctl bits to assert while reprogramming (bit3 = CORE_A, bit4 = CORE_B)
      G_CLKCTL_RST   : std_logic_vector(7 downto 0) := "00001000";
      -- clkctl steady-state value after reprogram (mux/cascade selects)
      G_CLKCTL_RUN   : std_logic_vector(7 downto 0) := "00000000";
      -- clkstat bits that must be set before done (bit0 = CORE_A locked)
      G_LOCK_MASK    : std_logic_vector(3 downto 0) := "0001"
   );
   port (
      clk_i          : in  std_logic;            -- sys_clk_i (shell-fixed 100 MHz)
      rst_i          : in  std_logic;

      -- Preset ROM at the instantiation site (combinational lookup)
      rom_idx_o      : out natural range 0 to G_NUM_ROWS - 1;
      rom_row_i      : in  std_logic_vector(41 downto 0);  -- target & addr & data & mask

      -- Boundary v2 partition pins
      drp_target_o   : out std_logic_vector(2 downto 0);
      drp_addr_o     : out std_logic_vector(6 downto 0);
      drp_data_o     : out std_logic_vector(15 downto 0);
      drp_mask_o     : out std_logic_vector(15 downto 0);
      drp_req_o      : out std_logic;
      drp_ack_i      : in  std_logic;
      clkctl_o       : out std_logic_vector(7 downto 0);
      clkstat_i      : in  std_logic_vector(3 downto 0);

      done_o         : out std_logic
   );
end entity clk_drp_master;

architecture rtl of clk_drp_master is

   type state_t is (ST_BOOT, ST_RST_SETTLE, ST_PRESENT, ST_WAIT_ACK,
                    ST_RELEASE, ST_WAIT_LOCK, ST_DONE);
   signal state    : state_t := ST_BOOT;

   signal delay    : natural range 0 to G_BOOT_DELAY := 0;
   signal row_idx  : natural range 0 to G_NUM_ROWS - 1 := 0;

   signal req      : std_logic := '0';
   signal ack_meta : std_logic := '0';
   signal ack_sync : std_logic := '0';

   -- clkstat comes from the shell's clk_100 domain (same as clk_i, but the
   -- lock sources are async MMCM outputs) — synchronise before use
   signal stat_meta : std_logic_vector(3 downto 0) := (others => '0');
   signal stat_sync : std_logic_vector(3 downto 0) := (others => '0');

begin

   rom_idx_o <= row_idx;
   drp_req_o <= req;

   process (clk_i)
   begin
      if rising_edge(clk_i) then

         ack_meta  <= drp_ack_i;
         ack_sync  <= ack_meta;
         stat_meta <= clkstat_i;
         stat_sync <= stat_meta;

         if rst_i = '1' then
            state    <= ST_BOOT;
            delay    <= 0;
            row_idx  <= 0;
            req      <= '0';
            clkctl_o <= G_CLKCTL_RUN;
            done_o   <= '0';

         else
            case state is

               when ST_BOOT =>
                  -- Let the shell settle after swap before touching clkctl.
                  -- Handshake state is zeroed on both sides here: the shell
                  -- reset the proxy during decouple, GSR reset us.
                  done_o <= '0';
                  if delay = G_BOOT_DELAY then
                     delay    <= 0;
                     clkctl_o <= G_CLKCTL_RUN or G_CLKCTL_RST;
                     state    <= ST_RST_SETTLE;
                  else
                     delay <= delay + 1;
                  end if;

               when ST_RST_SETTLE =>
                  -- The clkctl stability filter needs 64 stable clk_100
                  -- cycles before the MMCM reset actually asserts.
                  if delay = G_RST_SETTLE then
                     delay <= 0;
                     state <= ST_PRESENT;
                  else
                     delay <= delay + 1;
                  end if;

               when ST_PRESENT =>
                  -- Payload first, then the req toggle: the proxy's 2-FF
                  -- synchroniser guarantees the payload is stable by the
                  -- time the toggle is seen.
                  drp_target_o <= rom_row_i(41 downto 39);
                  drp_addr_o   <= rom_row_i(38 downto 32);
                  drp_data_o   <= rom_row_i(31 downto 16);
                  drp_mask_o   <= rom_row_i(15 downto 0);
                  req          <= not req;
                  state        <= ST_WAIT_ACK;

               when ST_WAIT_ACK =>
                  if ack_sync = req then
                     if row_idx = G_NUM_ROWS - 1 then
                        state <= ST_RELEASE;
                     else
                        row_idx <= row_idx + 1;
                        state   <= ST_PRESENT;
                     end if;
                  end if;

               when ST_RELEASE =>
                  -- All rows written: release the MMCM reset (stability
                  -- filter adds its 64-cycle latency shell-side).
                  clkctl_o <= G_CLKCTL_RUN;
                  state    <= ST_WAIT_LOCK;

               when ST_WAIT_LOCK =>
                  if (stat_sync and G_LOCK_MASK) = G_LOCK_MASK then
                     state <= ST_DONE;
                  end if;

               when ST_DONE =>
                  done_o <= '1';

            end case;
         end if;
      end if;
   end process;

end architecture rtl;
