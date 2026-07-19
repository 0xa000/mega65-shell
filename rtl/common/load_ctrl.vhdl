-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-- Stage A2/B load controller: UART descriptor parser, byte-source mux and
-- status echo.
--
-- Sits between uart_rx and icap_loader. Normally every UART byte passes
-- straight through (Stage A1 behavior, bit for bit). When the loader is
-- idle and no SD load runs, the parser additionally watches the stream
-- for a 14-byte descriptor frame:
--
--   "M65D"  mode/part  start[31:24..0]  len[31:24..0]  checksum
--
-- (big-endian, checksum = XOR of the 9 payload bytes). mode/part packs
-- mode in [7:4] (0 = raw LBA, 1 = FAT32 chain; start is an LBA or a
-- cluster number accordingly) and partition select in [3:0] (0 = first
-- FAT32-type MBR slot, 1..4 = explicit slot; chain mode only). A valid
-- frame fires the fat32_walker and the SD byte stream replaces the UART
-- as the loader's source until the load ends. The 10 payload bytes are
-- withheld from the loader (they could contain anything, including a
-- false sync word); the 4 magic bytes have already passed through by the
-- time the match completes, which is harmless — the loader ignores
-- everything before a sync word. The parser is disabled mid-load, so a
-- UART-streamed bitstream that happens to contain "M65D" is not eaten.
--
-- Status echo on the TX pin (single bytes, host-readable):
--   'A' descriptor accepted     'N' bad checksum / mode / partition
--   'D' SD load done            'E' + code + r1: failure diagnostics
--                                     (walker codes >= 0x80, SD-engine
--                                      FSM states below — see
--                                      fat32_walker.vhdl / sd_sector.vhdl)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity load_ctrl is
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;

    -- UART byte stream in.
    uart_byte    : in  std_logic_vector(7 downto 0);
    uart_valid   : in  std_logic;

    -- Loader state (icap_loader status = "00").
    loader_idle  : in  std_logic;

    -- Byte stream out, towards icap_loader.
    ld_byte      : out std_logic_vector(7 downto 0);
    ld_valid     : out std_logic;

    -- fat32_walker command and status side.
    wk_req       : out std_logic;
    wk_mode      : out std_logic;                      -- 0 raw, 1 chain
    wk_part      : out std_logic_vector(3 downto 0);
    wk_start     : out std_logic_vector(31 downto 0);
    wk_len       : out std_logic_vector(31 downto 0);
    wk_busy      : in  std_logic;
    wk_done      : in  std_logic;
    wk_err       : in  std_logic;
    wk_diag      : in  std_logic_vector(7 downto 0);
    wk_diag_r1   : in  std_logic_vector(7 downto 0);

    -- fat32_walker byte stream in.
    wk_byte      : in  std_logic_vector(7 downto 0);
    wk_valid     : in  std_logic;

    -- Status echo towards uart_tx.
    tx_data      : out std_logic_vector(7 downto 0);
    tx_send      : out std_logic;
    tx_busy      : in  std_logic
    );
end load_ctrl;

architecture rtl of load_ctrl is

  constant MAGIC : std_logic_vector(31 downto 0) := x"4D363544";  -- "M65D"

  type parse_t is (p_hunt, p_collect);
  signal parse : parse_t := p_hunt;

  signal magic_sr  : std_logic_vector(31 downto 0) := (others => '0');
  signal frame     : std_logic_vector(71 downto 0) := (others => '0');
  signal frame_cnt : natural range 0 to 9 := 0;
  signal csum      : std_logic_vector(7 downto 0) := (others => '0');

  -- Echo queue: up to 3 bytes, sent back-to-back as tx frees up.
  signal echo_buf : std_logic_vector(23 downto 0) := (others => '0');
  signal echo_cnt : natural range 0 to 3 := 0;
  signal tx_send_i : std_logic := '0';

begin

  tx_send <= tx_send_i;

  process(clk)
    variable parser_on : boolean;
    variable frame_ok  : boolean;
  begin
    if rising_edge(clk) then
      ld_valid  <= '0';
      wk_req    <= '0';
      tx_send_i <= '0';

      if rst = '1' then
        parse    <= p_hunt;
        magic_sr <= (others => '0');
        echo_cnt <= 0;
      else
        parser_on := loader_idle = '1' and wk_busy = '0';

        -- Byte-source mux: walker stream while a load runs, else UART
        -- pass-through (suppressed while a frame body is being collected).
        if wk_busy = '1' then
          if wk_valid = '1' then
            ld_byte  <= wk_byte;
            ld_valid <= '1';
          end if;
        elsif uart_valid = '1' and parse = p_hunt then
          ld_byte  <= uart_byte;
          ld_valid <= '1';
        end if;

        -- Descriptor parser.
        case parse is
          when p_hunt =>
            if uart_valid = '1' and parser_on then
              magic_sr <= magic_sr(23 downto 0) & uart_byte;
              if magic_sr(23 downto 0) & uart_byte = MAGIC then
                parse     <= p_collect;
                frame_cnt <= 0;
                csum      <= (others => '0');
              end if;
            end if;

          when p_collect =>
            if uart_valid = '1' then
              if frame_cnt = 9 then
                -- 10th byte: the checksum.
                parse    <= p_hunt;
                magic_sr <= (others => '0');
                frame_ok := uart_byte = csum
                  and frame(71 downto 69) = "000"            -- mode 0 or 1
                  and unsigned(frame(67 downto 64)) <= 4;    -- partition 0..4
                if frame_ok then
                  wk_mode  <= frame(68);
                  wk_part  <= frame(67 downto 64);
                  wk_start <= frame(63 downto 32);
                  wk_len   <= frame(31 downto 0);
                  wk_req   <= '1';
                  echo_buf(7 downto 0) <= x"41";             -- 'A'
                  echo_cnt <= 1;
                else
                  echo_buf(7 downto 0) <= x"4E";             -- 'N'
                  echo_cnt <= 1;
                end if;
              else
                frame     <= frame(63 downto 0) & uart_byte;
                csum      <= csum xor uart_byte;
                frame_cnt <= frame_cnt + 1;
              end if;
            end if;
        end case;

        -- Load completion events.
        if wk_done = '1' then
          echo_buf(7 downto 0) <= x"44";                     -- 'D'
          echo_cnt <= 1;
        elsif wk_err = '1' then
          -- 'E' first on the wire, then diag code, then r1.
          echo_buf <= wk_diag_r1 & wk_diag & x"45";
          echo_cnt <= 3;
        end if;

        -- Echo queue drain.
        if echo_cnt /= 0 and tx_busy = '0' and tx_send_i = '0' then
          tx_data   <= echo_buf(7 downto 0);
          tx_send_i <= '1';
          echo_buf  <= x"00" & echo_buf(23 downto 8);
          echo_cnt  <= echo_cnt - 1;
        end if;
      end if;
    end if;
  end process;

end rtl;
