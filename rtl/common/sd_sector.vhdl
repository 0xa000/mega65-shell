-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-- SPI-mode SD single-sector engine (Stage A2/B byte source, bottom layer).
--
-- Dumb by design: init_req runs a complete card bring-up (power-up delay,
-- 96 dummy clocks, CMD0/CMD8/CMD55+ACMD41/CMD58); rd_req reads ONE sector
-- via CMD17 and emits all 512 payload bytes on byte_out/byte_valid. Which
-- sectors to read, what the bytes mean and how many of them to forward is
-- the fat32_walker's business (raw runs and FAT32 chains alike).
--
-- The SPI byte engine and the init sequence are lifted from the
-- hardware-proven picorv32-menu sd_spi_ctrl.vhd, including its hard-won
-- lessons: NCS lead-in clocks after every CS assert (cards mis-anchor
-- the command start bit without them), 64-byte R1 poll budget, and the
-- diagnostic capture of the last raw poll byte.
--
-- done pulses on completion of EITHER request kind (the caller knows
-- which it issued); err pulses on failure with diagnostics latched in
-- diag_state/diag_r1, and the engine falls back to idle — a fresh
-- init_req starts over. ready is level: card initialised, engine idle.
--
-- Targets SD 2.0+ (SDHC/SDXC block-addressed; SDSC byte-addressed
-- fallback via the CMD58 CCS bit). SD 1.x is rejected.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sd_sector is
  generic (
    CLK_HZ : positive := 50_000_000
    );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;

    -- Request interface: pulses, sampled only when the engine is idle.
    init_req   : in  std_logic;
    rd_req     : in  std_logic;
    lba        : in  std_logic_vector(31 downto 0);

    -- Sector byte stream (all 512 bytes of every read).
    byte_out   : out std_logic_vector(7 downto 0);
    byte_valid : out std_logic;

    -- Status. done/err are single-cycle pulses; diag_* stay latched
    -- until the next error for post-mortem readout.
    ready      : out std_logic;
    done       : out std_logic;
    err        : out std_logic;
    diag_state : out std_logic_vector(7 downto 0);
    diag_r1    : out std_logic_vector(7 downto 0);

    -- SPI pins.
    sd_cs_n    : out std_logic;
    sd_clk     : out std_logic;
    sd_mosi    : out std_logic;
    sd_miso    : in  std_logic
    );
end sd_sector;

architecture rtl of sd_sector is

  -- SPI half-period counts. The +1 keeps the init clock under the
  -- 400 kHz spec limit (plain division lands at 403 kHz from 50 MHz).
  constant SLOW_HALF : natural := CLK_HZ / 800_000 + 1;
  constant FAST_HALF : natural := CLK_HZ / 50_000_000;  -- 25 MHz data clock
  -- Data-token poll budget in bytes: ~160 ms at 25 MHz, past the SD
  -- spec's 100 ms worst case.
  constant TOKEN_MAX : natural := 500_000;

  -- ---------------------------------------------------------------------
  -- SPI byte engine (CPOL=0 CPHA=0), verbatim from sd_spi_ctrl.vhd.
  -- ---------------------------------------------------------------------
  type spi_st_t is (SPI_IDLE, SPI_LOW, SPI_HIGH);
  signal spi_st       : spi_st_t := SPI_IDLE;
  signal spi_half_r   : natural range 0 to SLOW_HALF := SLOW_HALF;
  signal spi_cnt      : natural range 0 to SLOW_HALF := 0;
  signal spi_bit_cnt  : natural range 0 to 7 := 0;
  signal spi_tx_reg   : std_logic_vector(7 downto 0) := (others => '1');
  signal spi_rx_shift : std_logic_vector(7 downto 0) := (others => '0');
  signal spi_tx_byte  : std_logic_vector(7 downto 0) := (others => '1');
  signal spi_start    : std_logic := '0';
  signal spi_rx_byte  : std_logic_vector(7 downto 0) := (others => '0');
  signal spi_done     : std_logic := '0';
  signal spi_fast     : std_logic := '0';

  -- ---------------------------------------------------------------------
  -- Card FSM.
  -- ---------------------------------------------------------------------
  type sd_st_t is (
    S_IDLE,          -- uninitialised, waiting for init_req
    S_POWER_UP,      -- ~2 ms settle
    S_SEND_CLOCKS,   -- 96 dummy clocks, CS=1
    S_CMD_LEAD,      -- CS=0: drain 0xFF until MISO idle-high, then command
    S_CMD_SEND,      -- shift out the 6-byte cmd_buf
    S_CMD_RESP,      -- poll for R1 (<=64 tries)
    S_INIT_CHK0,     -- CMD0 R1 check, dispatch CMD8
    S_INIT_TRAIL8,   -- discard 4 R7 bytes, dispatch CMD55
    S_INIT_ACMD41,   -- dispatch ACMD41
    S_INIT_ACMD_CHK, -- ready / retry / error
    S_INIT_TRAIL58,  -- 4 OCR bytes, CCS -> sdhc
    S_READY,         -- initialised, waiting for rd_req
    S_RD_TOKEN,      -- poll for the 0xFE data token
    S_RD_DATA,       -- 512 payload bytes, all emitted
    S_RD_CRC,        -- discard 2 CRC bytes
    S_RD_DESEL,      -- CS=1 + 8 cleanup clocks, then done -> S_READY
    S_FAIL           -- latch diagnostics, pulse err, back to S_IDLE
    );
  signal sd_st   : sd_st_t := S_IDLE;
  signal next_st : sd_st_t := S_IDLE;   -- S_CMD_RESP dispatch target

  signal cmd_buf   : std_logic_vector(47 downto 0) := (others => '0');
  signal cmd_step  : natural range 0 to 5 := 0;
  signal rx_try    : natural range 0 to 64 := 0;
  signal trail_cnt : natural range 0 to 3 := 0;
  signal acmd41_n  : natural range 0 to 4095 := 0;
  signal r1_byte   : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_raw    : std_logic_vector(7 downto 0) := (others => '0');
  signal ocr_msb   : std_logic_vector(7 downto 0) := (others => '0');
  signal sdhc      : std_logic := '0';

  constant PU_TOP : natural := CLK_HZ / 500;  -- ~2 ms
  signal pu_cnt   : natural range 0 to PU_TOP := PU_TOP;
  signal clk_cnt  : natural range 0 to 12 := 0;
  signal tok_cnt  : natural range 0 to TOKEN_MAX := 0;

  signal sec_byte : natural range 0 to 511 := 0;
  signal crc_cnt  : natural range 0 to 1 := 0;

begin

  ready <= '1' when sd_st = S_READY else '0';

  -- =======================================================================
  -- SPI byte engine (CPOL=0 CPHA=0). MISO sampled at the end of the high
  -- phase; MOSI changes on the falling edge.
  -- =======================================================================
  p_spi : process(clk)
  begin
    if rising_edge(clk) then
      spi_done <= '0';

      case spi_st is

        when SPI_IDLE =>
          sd_clk <= '0';
          if spi_start = '1' then
            spi_tx_reg  <= spi_tx_byte;
            spi_bit_cnt <= 7;
            sd_mosi     <= spi_tx_byte(7);
            if spi_fast = '1' then
              spi_half_r <= FAST_HALF;
              spi_cnt    <= FAST_HALF - 1;
            else
              spi_half_r <= SLOW_HALF;
              spi_cnt    <= SLOW_HALF - 1;
            end if;
            spi_st <= SPI_LOW;
          end if;

        when SPI_LOW =>
          if spi_cnt = 0 then
            sd_clk  <= '1';
            spi_cnt <= spi_half_r - 1;
            spi_st  <= SPI_HIGH;
          else
            spi_cnt <= spi_cnt - 1;
          end if;

        when SPI_HIGH =>
          if spi_cnt = 0 then
            spi_rx_shift <= spi_rx_shift(6 downto 0) & sd_miso;
            sd_clk       <= '0';
            if spi_bit_cnt = 0 then
              spi_rx_byte <= spi_rx_shift(6 downto 0) & sd_miso;
              spi_done    <= '1';
              spi_st      <= SPI_IDLE;
            else
              spi_bit_cnt <= spi_bit_cnt - 1;
              spi_tx_reg  <= spi_tx_reg(6 downto 0) & '0';
              sd_mosi     <= spi_tx_reg(6);
              spi_cnt     <= spi_half_r - 1;
              spi_st      <= SPI_LOW;
            end if;
          else
            spi_cnt <= spi_cnt - 1;
          end if;

      end case;

      if rst = '1' then
        spi_st   <= SPI_IDLE;
        sd_clk   <= '0';
        sd_mosi  <= '1';
        spi_done <= '0';
      end if;
    end if;
  end process p_spi;

  -- =======================================================================
  -- Card FSM. Command pattern and SPI kick idiom as in sd_spi_ctrl.vhd:
  --   spi_done='1'                          -> consume result, kick next
  --   elsif spi_start='0' and spi_st=IDLE   -> first-entry kick (fires once)
  -- =======================================================================
  p_sd : process(clk)
  begin
    if rising_edge(clk) then
      spi_start  <= '0';
      byte_valid <= '0';
      done       <= '0';
      err        <= '0';

      if rst = '1' then
        sd_st    <= S_IDLE;
        sd_cs_n  <= '1';
        spi_fast <= '0';
        sdhc     <= '0';
      else

        case sd_st is

          -- -----------------------------------------------------------------
          when S_IDLE =>
            sd_cs_n <= '1';
            if init_req = '1' then
              spi_fast <= '0';
              sdhc     <= '0';
              pu_cnt   <= PU_TOP;
              sd_st    <= S_POWER_UP;
            end if;

          -- -----------------------------------------------------------------
          when S_POWER_UP =>
            sd_cs_n <= '1';
            if pu_cnt = 0 then
              clk_cnt <= 12;             -- 96 dummy clocks (>=74 required)
              sd_st   <= S_SEND_CLOCKS;
            else
              pu_cnt <= pu_cnt - 1;
            end if;

          -- -----------------------------------------------------------------
          when S_SEND_CLOCKS =>
            if spi_done = '1' then
              if clk_cnt = 0 then
                sd_cs_n  <= '0';
                cmd_buf  <= x"40_00_00_00_00_95";  -- CMD0, CRC required
                cmd_step <= 0;
                next_st  <= S_INIT_CHK0;
                sd_st    <= S_CMD_LEAD;
              else
                clk_cnt     <= clk_cnt - 1;
                spi_tx_byte <= x"FF";
                spi_start   <= '1';
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          -- NCS lead-in: clock 0xFF after CS assert until MISO reads
          -- idle-high (or the budget runs out), only then the command.
          -- -----------------------------------------------------------------
          when S_CMD_LEAD =>
            if spi_done = '1' then
              if spi_rx_byte = x"FF" or rx_try = 64 then
                sd_st <= S_CMD_SEND;
              else
                rx_try      <= rx_try + 1;
                spi_tx_byte <= x"FF";
                spi_start   <= '1';
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              rx_try      <= 0;
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          when S_CMD_SEND =>
            if spi_done = '1' then
              if cmd_step = 5 then
                rx_try <= 0;
                sd_st  <= S_CMD_RESP;
              else
                cmd_step    <= cmd_step + 1;
                spi_tx_byte <= cmd_buf(39 downto 32);
                spi_start   <= '1';
                cmd_buf     <= cmd_buf(39 downto 0) & x"FF";
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= cmd_buf(47 downto 40);
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          when S_CMD_RESP =>
            if spi_done = '1' then
              rx_raw <= spi_rx_byte;
              if spi_rx_byte(7) = '0' then
                r1_byte <= spi_rx_byte;
                sd_st   <= next_st;
              elsif rx_try = 64 then
                diag_state <= std_logic_vector(
                  to_unsigned(sd_st_t'pos(next_st), 8));
                sd_st <= S_FAIL;
              else
                rx_try      <= rx_try + 1;
                spi_tx_byte <= x"FF";
                spi_start   <= '1';
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          when S_INIT_CHK0 =>
            if r1_byte = x"01" then
              trail_cnt <= 3;
              cmd_buf   <= x"48_00_00_01_AA_87";  -- CMD8, VHS=1, check 0xAA
              cmd_step  <= 0;
              next_st   <= S_INIT_TRAIL8;
              sd_st     <= S_CMD_LEAD;
            else
              diag_state <= std_logic_vector(
                to_unsigned(sd_st_t'pos(sd_st), 8));
              sd_st <= S_FAIL;
            end if;

          -- -----------------------------------------------------------------
          when S_INIT_TRAIL8 =>
            if r1_byte = x"05" then                -- SD 1.x: not supported
              diag_state <= std_logic_vector(
                to_unsigned(sd_st_t'pos(sd_st), 8));
              sd_st <= S_FAIL;
            elsif spi_done = '1' then
              if trail_cnt = 0 then
                acmd41_n <= 0;
                cmd_buf  <= x"77_00_00_00_00_FF";  -- CMD55
                cmd_step <= 0;
                next_st  <= S_INIT_ACMD41;
                sd_st    <= S_CMD_LEAD;
              else
                trail_cnt   <= trail_cnt - 1;
                spi_tx_byte <= x"FF";
                spi_start   <= '1';
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          when S_INIT_ACMD41 =>
            cmd_buf  <= x"69_40_00_00_00_FF";      -- ACMD41, HCS=1
            cmd_step <= 0;
            next_st  <= S_INIT_ACMD_CHK;
            sd_st    <= S_CMD_LEAD;

          -- -----------------------------------------------------------------
          when S_INIT_ACMD_CHK =>
            if r1_byte = x"00" then
              trail_cnt <= 3;
              cmd_buf   <= x"7A_00_00_00_00_FF";   -- CMD58: OCR / CCS
              cmd_step  <= 0;
              next_st   <= S_INIT_TRAIL58;
              sd_st     <= S_CMD_LEAD;
            elsif r1_byte = x"01" then
              if acmd41_n = 4000 then              -- ~1 s at 400 kHz
                diag_state <= std_logic_vector(
                  to_unsigned(sd_st_t'pos(sd_st), 8));
                sd_st <= S_FAIL;
              else
                acmd41_n <= acmd41_n + 1;
                cmd_buf  <= x"77_00_00_00_00_FF";
                cmd_step <= 0;
                next_st  <= S_INIT_ACMD41;
                sd_st    <= S_CMD_LEAD;
              end if;
            else
              diag_state <= std_logic_vector(
                to_unsigned(sd_st_t'pos(sd_st), 8));
              sd_st <= S_FAIL;
            end if;

          -- -----------------------------------------------------------------
          when S_INIT_TRAIL58 =>
            if spi_done = '1' then
              if trail_cnt = 3 then
                ocr_msb <= spi_rx_byte;            -- OCR[31:24]; CCS = bit 6
              end if;
              if trail_cnt = 0 then
                sdhc     <= ocr_msb(6);
                spi_fast <= '1';
                sd_cs_n  <= '1';
                done     <= '1';                   -- init complete
                sd_st    <= S_READY;
              else
                trail_cnt   <= trail_cnt - 1;
                spi_tx_byte <= x"FF";
                spi_start   <= '1';
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          -- Initialised and idle. CS is cycled around each sector read
          -- (proven pattern, ~2% overhead — CMD18 multi-block is a later
          -- tweak in the walker/engine pair).
          -- -----------------------------------------------------------------
          when S_READY =>
            sd_cs_n <= '1';
            if init_req = '1' then
              -- re-init for the next load (per-load policy: never stale)
              spi_fast <= '0';
              sdhc     <= '0';
              pu_cnt   <= PU_TOP;
              sd_st    <= S_POWER_UP;
            elsif rd_req = '1' then
              sd_cs_n  <= '0';
              tok_cnt  <= 0;
              cmd_step <= 0;
              -- SDHC argument = block address; SDSC = byte address.
              if sdhc = '1' then
                cmd_buf <= x"51" & lba & x"FF";
              else
                cmd_buf <= x"51" &
                           std_logic_vector(
                             shift_left(unsigned(lba), 9)) & x"FF";
              end if;
              next_st <= S_RD_TOKEN;
              sd_st   <= S_CMD_LEAD;
            end if;

          -- -----------------------------------------------------------------
          when S_RD_TOKEN =>
            if spi_done = '1' then
              if spi_rx_byte = x"FE" then
                sec_byte <= 0;
                sd_st    <= S_RD_DATA;
              elsif spi_rx_byte(7) = '0' and spi_rx_byte(4) = '0' then
                diag_state <= std_logic_vector(
                  to_unsigned(sd_st_t'pos(sd_st), 8));
                sd_st <= S_FAIL;                   -- data error token
              elsif tok_cnt = TOKEN_MAX then
                diag_state <= std_logic_vector(
                  to_unsigned(sd_st_t'pos(sd_st), 8));
                sd_st <= S_FAIL;                   -- read timeout
              else
                tok_cnt     <= tok_cnt + 1;
                spi_tx_byte <= x"FF";
                spi_start   <= '1';
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          when S_RD_DATA =>
            if spi_done = '1' then
              byte_out   <= spi_rx_byte;
              byte_valid <= '1';
              if sec_byte = 511 then
                crc_cnt <= 1;
                sd_st   <= S_RD_CRC;
              else
                sec_byte    <= sec_byte + 1;
                spi_tx_byte <= x"FF";
                spi_start   <= '1';
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          when S_RD_CRC =>
            if spi_done = '1' then
              if crc_cnt = 0 then
                sd_st <= S_RD_DESEL;
              else
                crc_cnt     <= crc_cnt - 1;
                spi_tx_byte <= x"FF";
                spi_start   <= '1';
              end if;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          when S_RD_DESEL =>
            sd_cs_n <= '1';
            if spi_done = '1' then
              done  <= '1';                        -- sector complete
              sd_st <= S_READY;
            elsif spi_start = '0' and spi_st = SPI_IDLE then
              spi_tx_byte <= x"FF";
              spi_start   <= '1';
            end if;

          -- -----------------------------------------------------------------
          when S_FAIL =>
            sd_cs_n <= '1';
            err     <= '1';
            diag_r1 <= rx_raw;
            sd_st   <= S_IDLE;

        end case;
      end if;
    end if;
  end process p_sd;

end rtl;
