-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-- Streams a partial bitstream (raw .bin format, as produced by
-- write_bitstream -bin_file) into ICAPE2.
--
-- The loader hunts for the bitstream sync word AA995566 in a byte-sliding
-- window, so nothing happens on line noise or USB enumeration glitches:
-- no sync, no decouple. On sync it isolates the RM, replays a dummy word
-- plus the sync word into ICAP, and streams every following byte as
-- 32-bit words (word alignment is inherited from the sync position, which
-- also makes it self-recovering after junk). ICAPE2 expects each byte
-- bit-reversed relative to the file (UG470 "Parallel Bus Bit Order").
--
-- Load ends when the DESYNC command is seen (drain, recouple, release
-- reset). A stall mid-load parks in error with the RM isolated; a fresh
-- stream (next sync word) restarts.
--
-- status: 00 idle (RM running), 01 loading, 10 error, 11 draining.
--
-- The ICAP write-mode status byte on O (UG470: O[7]=CFGERR_B, O[6]=DALIGN,
-- O[4]=IN_ABORT_B) is latched sticky per load attempt: stat_dalign proves
-- the config engine saw our sync word, stat_cfgerr/stat_abort flag a
-- rejected stream. A new attempt (next sync word) clears them.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity icap_loader is
  generic (
    CLK_HZ : positive := 50_000_000
    );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    byte_in    : in  std_logic_vector(7 downto 0);
    byte_valid : in  std_logic;
    decouple   : out std_logic;
    rm_reset   : out std_logic;
    status     : out std_logic_vector(1 downto 0);
    -- Config-engine evidence, sticky per load attempt (see header).
    stat_attempt : out std_logic;
    stat_dalign  : out std_logic;
    stat_cfgerr  : out std_logic;
    stat_abort   : out std_logic
    );
end icap_loader;

architecture rtl of icap_loader is

  -- Bit-reverse each byte of a 32-bit word for the ICAP data pins.
  function bitswap(w : std_logic_vector(31 downto 0))
    return std_logic_vector is
    variable r : std_logic_vector(31 downto 0);
  begin
    for b in 0 to 3 loop
      for i in 0 to 7 loop
        r(8 * b + i) := w(8 * b + 7 - i);
      end loop;
    end loop;
    return r;
  end function;

  constant WORD_SYNC     : std_logic_vector(31 downto 0) := x"AA995566";
  constant WORD_DUMMY    : std_logic_vector(31 downto 0) := x"FFFFFFFF";
  constant CMD_WRITE_CMD : std_logic_vector(31 downto 0) := x"30008001";
  constant CMD_DESYNC    : std_logic_vector(31 downto 0) := x"0000000D";

  -- Stall detection: no bytes for ~500 ms mid-load means the host gave up.
  constant STALL_LIMIT : natural := CLK_HZ / 2;
  -- After DESYNC, wait ~10 ms of line silence before declaring the load done.
  constant DRAIN_LIMIT : natural := CLK_HZ / 100;
  -- Hold the RM in reset for ~2 ms after recoupling.
  constant RESET_HOLD  : natural := CLK_HZ / 500;

  type state_t is (st_hunt, st_sync, st_loading, st_drain, st_reset_hold,
                   st_error);
  signal state : state_t := st_hunt;

  -- Byte-sliding window for sync detection (active in hunt and error).
  signal sync_sr : std_logic_vector(31 downto 0) := (others => '0');

  signal word      : std_logic_vector(31 downto 0) := (others => '0');
  signal byte_cnt  : unsigned(1 downto 0)          := (others => '0');
  signal prev_word : std_logic_vector(31 downto 0) := (others => '0');
  signal desync    : std_logic                     := '0';

  signal idle_cnt : unsigned(25 downto 0) := (others => '0');

  signal icap_data : std_logic_vector(31 downto 0) := (others => '1');
  signal icap_csib : std_logic                     := '1';
  signal icap_o    : std_logic_vector(31 downto 0);

begin

  icap0 : ICAPE2
    generic map (
      ICAP_WIDTH => "X32")
    port map (
      O     => icap_o,
      CLK   => clk,
      CSIB  => icap_csib,
      I     => icap_data,
      RDWRB => '0');

  process(clk)
    variable w : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      icap_csib <= '1';

      if rst = '1' then
        state    <= st_hunt;
        sync_sr  <= (others => '0');
        desync   <= '0';
        decouple <= '0';
        rm_reset <= '0';
        status   <= "00";
        stat_attempt <= '0';
        stat_dalign  <= '0';
        stat_cfgerr  <= '0';
        stat_abort   <= '0';
      else

        -- Latch the config-engine status while a load is in flight.
        if state = st_sync or state = st_loading or state = st_drain then
          if icap_o(6) = '1' then
            stat_dalign <= '1';
          end if;
          if icap_o(7) = '0' then
            stat_cfgerr <= '1';
          end if;
          if icap_o(4) = '0' then
            stat_abort <= '1';
          end if;
        end if;

        -- Word assembly and ICAP feed while a load is in progress.
        if byte_valid = '1' and (state = st_loading or state = st_drain) then
          w := word(23 downto 0) & byte_in;
          word <= w;
          if byte_cnt = 3 then
            byte_cnt  <= (others => '0');
            icap_data <= bitswap(w);
            icap_csib <= '0';
            prev_word <= w;
            if prev_word = CMD_WRITE_CMD and w = CMD_DESYNC then
              desync <= '1';
            end if;
          else
            byte_cnt <= byte_cnt + 1;
          end if;
        end if;

        -- Sync hunt: byte-sliding window, active whenever no load runs.
        if byte_valid = '1' and (state = st_hunt or state = st_error) then
          sync_sr <= sync_sr(23 downto 0) & byte_in;
        end if;

        -- Idle time since the last received byte.
        if byte_valid = '1' then
          idle_cnt <= (others => '0');
        elsif idle_cnt /= x"3FFFFFF" then
          idle_cnt <= idle_cnt + 1;
        end if;

        case state is
          when st_hunt =>
            decouple <= '0';
            rm_reset <= '0';
            status   <= "00";
            if byte_valid = '1'
              and sync_sr(23 downto 0) & byte_in = WORD_SYNC then
              -- Sync word complete: isolate the RM and open the load.
              state     <= st_sync;
              decouple  <= '1';
              rm_reset  <= '1';
              status    <= "01";
              icap_data <= bitswap(WORD_DUMMY);
              icap_csib <= '0';
              stat_attempt <= '1';
              stat_dalign  <= '0';
              stat_cfgerr  <= '0';
              stat_abort   <= '0';
            end if;

          when st_sync =>
            -- Second beat of the preamble: the sync word itself.
            state     <= st_loading;
            icap_data <= bitswap(WORD_SYNC);
            icap_csib <= '0';
            desync    <= '0';
            prev_word <= WORD_SYNC;
            -- Don't lose a byte that lands exactly in this cycle.
            if byte_valid = '1' then
              word     <= x"000000" & byte_in;
              byte_cnt <= "01";
            else
              byte_cnt <= (others => '0');
            end if;

          when st_loading =>
            if desync = '1' then
              state  <= st_drain;
              status <= "11";
            elsif idle_cnt = to_unsigned(STALL_LIMIT, idle_cnt'length) then
              state   <= st_error;
              status  <= "10";
              sync_sr <= (others => '0');
            end if;

          when st_drain =>
            -- Trailing pad words still trickle in; ICAP is desynced and
            -- ignores them. Declare completion once the line goes quiet.
            if idle_cnt = to_unsigned(DRAIN_LIMIT, idle_cnt'length) then
              state    <= st_reset_hold;
              decouple <= '0';
              idle_cnt <= (others => '0');
            end if;

          when st_reset_hold =>
            if idle_cnt = to_unsigned(RESET_HOLD, idle_cnt'length) then
              state    <= st_hunt;
              rm_reset <= '0';
              status   <= "00";
              sync_sr  <= (others => '0');
            end if;

          when st_error =>
            -- RM is half-written: keep it decoupled and in reset until a
            -- fresh stream's sync word arrives.
            if byte_valid = '1'
              and sync_sr(23 downto 0) & byte_in = WORD_SYNC then
              state     <= st_sync;
              status    <= "01";
              icap_data <= bitswap(WORD_DUMMY);
              icap_csib <= '0';
              stat_attempt <= '1';
              stat_dalign  <= '0';
              stat_cfgerr  <= '0';
              stat_abort   <= '0';
            end if;
        end case;
      end if;
    end if;
  end process;

end rtl;
