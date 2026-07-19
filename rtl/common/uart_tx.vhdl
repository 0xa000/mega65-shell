-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-- Minimal 8N1 UART transmitter, counterpart of uart_rx. One byte per
-- send pulse; busy covers start bit through stop bit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
  generic (
    CLK_HZ : positive := 50_000_000;
    BAUD   : positive := 921_600
    );
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;
    data : in  std_logic_vector(7 downto 0);
    send : in  std_logic;
    txd  : out std_logic;
    busy : out std_logic
    );
end uart_tx;

architecture rtl of uart_tx is

  constant BIT_CLKS : positive := CLK_HZ / BAUD;

  type state_t is (idle, shift);
  signal state : state_t := idle;

  signal phase     : integer range 0 to BIT_CLKS - 1 := 0;
  -- start + 8 data + stop, shifted out LSB of shreg first
  signal shreg     : std_logic_vector(9 downto 0) := (others => '1');
  signal bit_index : integer range 0 to 9 := 0;

begin

  txd  <= shreg(0);
  busy <= '1' when state /= idle else '0';

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state <= idle;
        shreg <= (others => '1');
      else
        case state is
          when idle =>
            if send = '1' then
              shreg     <= '1' & data & '0';   -- stop, data LSB-first, start
              phase     <= 0;
              bit_index <= 0;
              state     <= shift;
            end if;

          when shift =>
            if phase = BIT_CLKS - 1 then
              phase <= 0;
              shreg <= '1' & shreg(9 downto 1);
              if bit_index = 9 then
                state <= idle;
              else
                bit_index <= bit_index + 1;
              end if;
            else
              phase <= phase + 1;
            end if;
        end case;
      end if;
    end if;
  end process;

end rtl;
