-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-- IPROG warm-boot sequencer: full reconfiguration from QSPI flash.
--
-- On req it plays the canned warm-boot command sequence (UG470 ch. 7,
-- "IPROG Reconfiguration": dummy, sync, NOOP, write WBSTAR = flash byte
-- address, write CMD = IPROG, NOOP) as a BYTE STREAM, big-endian word
-- order — the same wire format as a .bin partial. The stream is meant to
-- be muxed into icap_loader's byte input: the loader's own sync hunt then
-- isolates the RM and forwards the words into ICAPE2 (with its byte
-- bit-swap), and the config engine restarts from the flash address in
-- master SPI mode. On success the fabric — including this sequencer —
-- ceases to exist mid-stream; there is deliberately no completion event.
--
-- One byte every other cycle, so a word lands at ICAP every 8 cycles —
-- far below ICAPE2's write-rate limit at any plausible loader clock.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity iprog_seq is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;

    req        : in  std_logic;                      -- 1-cycle pulse
    addr       : in  std_logic_vector(31 downto 0);  -- flash byte address
    busy       : out std_logic;

    byte_out   : out std_logic_vector(7 downto 0);
    byte_valid : out std_logic
    );
end iprog_seq;

architecture rtl of iprog_seq is

  type seq_t is array (0 to 7) of std_logic_vector(31 downto 0);
  constant SEQ : seq_t := (
    x"FFFFFFFF",   -- dummy
    x"AA995566",   -- sync
    x"20000000",   -- NOOP
    x"30020001",   -- write WBSTAR
    x"00000000",   -- (replaced by addr)
    x"30008001",   -- write CMD
    x"0000000F",   -- IPROG
    x"20000000");  -- NOOP

  signal addr_r    : std_logic_vector(31 downto 0) := (others => '0');
  signal shreg     : std_logic_vector(31 downto 0) := (others => '0');
  signal word_idx  : natural range 0 to 7 := 0;
  signal byte_idx  : natural range 0 to 3 := 0;
  signal phase     : std_logic := '0';   -- pace: one byte every other cycle
  signal running   : std_logic := '0';

begin

  busy <= running;

  process(clk)
    variable w : std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      byte_valid <= '0';

      if rst = '1' then
        running <= '0';
      elsif running = '0' then
        if req = '1' then
          addr_r   <= addr;
          word_idx <= 0;
          byte_idx <= 0;
          phase    <= '0';
          running  <= '1';
        end if;
      else
        phase <= not phase;
        if phase = '0' then
          -- Big-endian byte order within the word, like a .bin stream:
          -- load the word at each byte_idx=0, then shift a byte per emit.
          if byte_idx = 0 then
            if word_idx = 4 then
              w := addr_r;
            else
              w := SEQ(word_idx);
            end if;
          else
            w := shreg;
          end if;
          byte_out   <= w(31 downto 24);
          byte_valid <= '1';
          shreg      <= w(23 downto 0) & x"00";

          if byte_idx = 3 then
            byte_idx <= 0;
            if word_idx = 7 then
              running <= '0';   -- only reached if the config engine balked
            else
              word_idx <= word_idx + 1;
            end if;
          else
            byte_idx <= byte_idx + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

end rtl;
