-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-- Load-descriptor proxy over the reserved boundary pins (phase 3 of the
-- FAT32 core loader; DESIGN.md decision 2 — "the shell is exec()").
--
-- The RM writes a descriptor {mode, partition, start, length} into a small
-- shell-side register file and fires GO; the shell's fat32_walker then
-- pulls the named partial off the SD card into the ICAP loader. Transport
-- is a toggle-handshake register write over rsv_o/rsv_i, so the boundary
-- port list is UNCHANGED from v3 — RMs that tie rsv_o to zero (democore,
-- VIC20, C64, Moon Patrol) never interact with it.
--
--   rsv from RM: [15] req toggle   [14:11] register index   [7:0] data
--   rsv to RM:   [15] ack toggle   [9] walker busy  [8] error latched
--                [7:0] last diagnostic code (walker codes >= 0x80,
--                      SD-engine states below, 0x8F = bad descriptor)
--
-- Registers: 0 MODE_PART (data[7:4] mode: 0 raw / 1 FAT32 chain /
-- 2 flash boot, data[3:0] partition: 0 auto / 1..4 MBR slot; ignored in
-- mode 2), 1..4 START (MSB first; mode 2: QSPI flash byte address),
-- 5..8 LENGTH (MSB first; ignored in mode 2), 9 GO.
--
-- Mode 2 fires the iprog_seq instead of the walker: the shell plays an
-- IPROG warm-boot sequence into the ICAP and the config engine reloads
-- the FULL bitstream from flash at START — on success the whole fabric
-- (RM included) is replaced, so GO never "completes" from the RM's view.
--
-- GO with the walker or sequencer busy is ignored (RM can poll bit 9).
-- GO with an invalid mode/partition sets the error latch to 0x8F without
-- firing. The error latch clears on the next GO and on decouple.
--
-- Sequencing contract with the RM: after GO the RM must leave the SD
-- pins alone (the shell muxes them to the walker). Card init and
-- self-mount run BEFORE any byte reaches the ICAP, so early failures
-- (no card, not FAT32, bad cluster) return err + code while the RM is
-- still alive and running; only when bitstream data actually streams
-- does decouple engage and the RM get replaced.
--
-- Handshake state is zeroed while decoupled (same lesson as drp_proxy:
-- an odd toggle count must not leak across a swap — the incoming RM's
-- side is GSR-zeroed).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity desc_proxy is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    decouple   : in  std_logic;

    -- RM-facing partition pins.
    rsv_from_rm : in  std_logic_vector(15 downto 0);
    rsv_to_rm   : out std_logic_vector(15 downto 0);

    -- Walker command side (arbitrated with load_ctrl in shell_top).
    wk_req     : out std_logic;
    wk_mode    : out std_logic;
    wk_part    : out std_logic_vector(3 downto 0);
    wk_start   : out std_logic_vector(31 downto 0);
    wk_len     : out std_logic_vector(31 downto 0);
    wk_busy    : in  std_logic;
    wk_err     : in  std_logic;
    wk_diag    : in  std_logic_vector(7 downto 0);

    -- IPROG warm-boot side (mode 2; address rides on wk_start).
    ip_req     : out std_logic;
    ip_busy    : in  std_logic
    );
end desc_proxy;

architecture rtl of desc_proxy is

  signal req_sync : std_logic_vector(1 downto 0) := (others => '0');
  signal req_seen : std_logic := '0';   -- last handled req toggle state
  signal ack      : std_logic := '0';

  signal mode_part : std_logic_vector(7 downto 0) := (others => '0');
  signal start_r   : std_logic_vector(31 downto 0) := (others => '0');
  signal len_r     : std_logic_vector(31 downto 0) := (others => '0');

  signal err_latch : std_logic := '0';
  signal diag_r    : std_logic_vector(7 downto 0) := (others => '0');

begin

  wk_mode  <= mode_part(4);
  wk_part  <= mode_part(3 downto 0);
  wk_start <= start_r;
  wk_len   <= len_r;

  rsv_to_rm <= ack & "00000" & (wk_busy or ip_busy) & err_latch & diag_r;

  process(clk)
    variable idx : natural range 0 to 15;
  begin
    if rising_edge(clk) then
      wk_req <= '0';
      ip_req <= '0';

      if rst = '1' or decouple = '1' then
        -- Zero the WHOLE handshake so toggle parity re-pairs with the
        -- next RM's GSR-zeroed side; also drop stale errors.
        req_sync  <= (others => '0');
        req_seen  <= '0';
        ack       <= '0';
        err_latch <= '0';
        diag_r    <= (others => '0');
      else
        req_sync <= rsv_from_rm(15) & req_sync(1);

        if req_sync(0) /= req_seen then
          -- Payload has been stable for the synchronizer latency by
          -- construction (RM sets idx/data before flipping the toggle).
          req_seen <= req_sync(0);
          ack      <= req_sync(0);
          idx := to_integer(unsigned(rsv_from_rm(14 downto 11)));
          case idx is
            when 0 => mode_part <= rsv_from_rm(7 downto 0);
            when 1 => start_r(31 downto 24) <= rsv_from_rm(7 downto 0);
            when 2 => start_r(23 downto 16) <= rsv_from_rm(7 downto 0);
            when 3 => start_r(15 downto 8)  <= rsv_from_rm(7 downto 0);
            when 4 => start_r(7 downto 0)   <= rsv_from_rm(7 downto 0);
            when 5 => len_r(31 downto 24)   <= rsv_from_rm(7 downto 0);
            when 6 => len_r(23 downto 16)   <= rsv_from_rm(7 downto 0);
            when 7 => len_r(15 downto 8)    <= rsv_from_rm(7 downto 0);
            when 8 => len_r(7 downto 0)     <= rsv_from_rm(7 downto 0);
            when 9 =>
              err_latch <= '0';
              if wk_busy = '0' and ip_busy = '0' then
                if mode_part(7 downto 4) = x"2" then
                  ip_req <= '1';               -- flash boot: IPROG warm-boot
                elsif mode_part(7 downto 5) = "000"
                   and unsigned(mode_part(3 downto 0)) <= 4 then
                  wk_req <= '1';
                else
                  err_latch <= '1';
                  diag_r    <= x"8F";          -- bad descriptor
                end if;
              end if;
              -- GO while busy: ignored, RM polls the busy bit
            when others => null;               -- reserved indices
          end case;
        end if;

        if wk_err = '1' then
          err_latch <= '1';
          diag_r    <= wk_diag;
        end if;
      end if;
    end if;
  end process;

end rtl;
