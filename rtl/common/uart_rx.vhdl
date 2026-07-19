-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-- Minimal 8N1 UART receiver. Start-edge aligned, samples each bit at its
-- midpoint. At 50 MHz / 921600 baud the divisor is ~54.25; the cumulative
-- sampling error over 10 bits stays well inside half a bit period.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
  generic (
    CLK_HZ : positive := 50_000_000;
    BAUD   : positive := 921_600
    );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;
    rxd        : in  std_logic;
    data       : out std_logic_vector(7 downto 0);
    data_valid : out std_logic
    );
end uart_rx;

architecture rtl of uart_rx is

  constant BIT_CLKS  : positive := CLK_HZ / BAUD;
  constant HALF_CLKS : positive := BIT_CLKS / 2;

  type state_t is (idle, start, bits, stop);
  signal state : state_t := idle;

  signal rxd_sync  : std_logic_vector(2 downto 0) := (others => '1');
  signal phase     : integer range 0 to BIT_CLKS - 1 := 0;
  signal bit_index : integer range 0 to 7 := 0;
  signal shreg     : std_logic_vector(7 downto 0) := (others => '0');

begin

  process(clk)
  begin
    if rising_edge(clk) then
      data_valid <= '0';
      rxd_sync   <= rxd & rxd_sync(2 downto 1);

      if rst = '1' then
        state <= idle;
      else
        case state is
          when idle =>
            if rxd_sync(0) = '0' then   -- start edge
              state <= start;
              phase <= 0;
            end if;

          when start =>
            -- Confirm the start bit at its midpoint, then align to data bits.
            if phase = HALF_CLKS - 1 then
              if rxd_sync(0) = '0' then
                state     <= bits;
                phase     <= 0;
                bit_index <= 0;
              else
                state <= idle;          -- glitch
              end if;
            else
              phase <= phase + 1;
            end if;

          when bits =>
            if phase = BIT_CLKS - 1 then
              phase <= 0;
              shreg <= rxd_sync(0) & shreg(7 downto 1);  -- LSB first
              if bit_index = 7 then
                state <= stop;
              else
                bit_index <= bit_index + 1;
              end if;
            else
              phase <= phase + 1;
            end if;

          when stop =>
            if phase = BIT_CLKS - 1 then
              if rxd_sync(0) = '1' then
                data       <= shreg;
                data_valid <= '1';
              end if;                   -- framing error: drop the byte
              state <= idle;
            else
              phase <= phase + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

end rtl;
