-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-------------------------------------------------------------------------------------------------------------
-- mega65-shell — QMTECH Wukong board layer
--
-- Avalon Memory-Map (burst capable) to pipelined Wishbone bridge, written for
-- the UberDDR3 controller: one Wishbone request per 128-bit word, requests are
-- accepted while o_wb_stall is low and acknowledged strictly in order.
--
-- Simplifications that hold for this use (single Avalon master, UberDDR3 slave):
-- * Only one Avalon transaction is in flight at a time (waitrequest is held
--   during a read burst), so read data routing needs no reorder logic.
-- * Write acknowledges are counted but not waited for, except that a read is
--   not started before all outstanding write acks have drained, so an ack can
--   always be attributed unambiguously.
--
-- Wukong port done by 0xa000 in 2026
-------------------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity avm_to_wb is
   generic (
      G_AVM_ADDRESS_SIZE : integer;      -- Avalon word address width (words of G_DATA_SIZE bits)
      G_WB_ADDRESS_SIZE  : integer;      -- Wishbone word address width (low bits of the Avalon address)
      G_DATA_SIZE        : integer
   );
   port (
      clk_i                 : in  std_logic;
      rst_i                 : in  std_logic;

      -- Avalon Memory Map (slave)
      s_avm_write_i         : in  std_logic;
      s_avm_read_i          : in  std_logic;
      s_avm_address_i       : in  std_logic_vector(G_AVM_ADDRESS_SIZE - 1 downto 0);
      s_avm_writedata_i     : in  std_logic_vector(G_DATA_SIZE - 1 downto 0);
      s_avm_byteenable_i    : in  std_logic_vector(G_DATA_SIZE / 8 - 1 downto 0);
      s_avm_burstcount_i    : in  std_logic_vector(7 downto 0);
      s_avm_readdata_o      : out std_logic_vector(G_DATA_SIZE - 1 downto 0);
      s_avm_readdatavalid_o : out std_logic;
      s_avm_waitrequest_o   : out std_logic;

      -- Pipelined Wishbone (master)
      wb_cyc_o              : out std_logic;
      wb_stb_o              : out std_logic;
      wb_we_o               : out std_logic;
      wb_addr_o             : out std_logic_vector(G_WB_ADDRESS_SIZE - 1 downto 0);
      wb_data_o             : out std_logic_vector(G_DATA_SIZE - 1 downto 0);
      wb_sel_o              : out std_logic_vector(G_DATA_SIZE / 8 - 1 downto 0);
      wb_stall_i            : in  std_logic;
      wb_ack_i              : in  std_logic;
      wb_data_i             : in  std_logic_vector(G_DATA_SIZE - 1 downto 0)
   );
end entity avm_to_wb;

architecture synthesis of avm_to_wb is

   type t_state is (IDLE_ST, WRITE_ST, READ_ST);
   signal state : t_state := IDLE_ST;

   signal addr        : unsigned(G_AVM_ADDRESS_SIZE - 1 downto 0);
   signal beats_left  : unsigned(7 downto 0);  -- write beats still to accept / read stbs still to issue
   signal acks_left   : unsigned(7 downto 0);  -- read acks still to receive
   signal pending_wr  : unsigned(7 downto 0);  -- write acks not yet drained

   signal wr_beat_now : std_logic;             -- a write beat is presented and will be accepted
   signal rd_stb_now  : std_logic;             -- a read stb is presented and will be accepted

begin

   -- Holding CYC permanently asserted is valid for UberDDR3 and avoids having
   -- to track the exact drain time of posted writes.
   wb_cyc_o <= not rst_i;

   wr_beat_now <= '1' when (state = IDLE_ST or state = WRITE_ST) and s_avm_write_i = '1' and wb_stall_i = '0'
                  else '0';
   rd_stb_now  <= '1' when state = READ_ST and beats_left /= 0 and wb_stall_i = '0'
                  else '0';

   -- Write beats pass straight through; read stbs are generated locally.
   wb_stb_o  <= s_avm_write_i when state = IDLE_ST or state = WRITE_ST else
                '1'           when state = READ_ST and beats_left /= 0 else
                '0';
   wb_we_o   <= '1' when state = IDLE_ST or state = WRITE_ST else '0';
   wb_data_o <= s_avm_writedata_i;
   wb_sel_o  <= s_avm_byteenable_i when state = IDLE_ST or state = WRITE_ST else (others => '1');

   wb_addr_o <= s_avm_address_i(G_WB_ADDRESS_SIZE - 1 downto 0) when state = IDLE_ST else
                std_logic_vector(addr(G_WB_ADDRESS_SIZE - 1 downto 0));

   s_avm_waitrequest_o <= wb_stall_i when (state = IDLE_ST and s_avm_write_i = '1') or state = WRITE_ST else
                          '1'        when state = READ_ST else
                          '1'        when state = IDLE_ST and s_avm_read_i = '1' and pending_wr /= 0 else
                          '0';

   p_fsm : process (clk_i)
   begin
      if rising_edge(clk_i) then
         -- registered read response
         s_avm_readdatavalid_o <= '0';
         if state = READ_ST and wb_ack_i = '1' then
            s_avm_readdata_o      <= wb_data_i;
            s_avm_readdatavalid_o <= '1';
         end if;

         -- outstanding write ack bookkeeping
         if wr_beat_now = '1' and not (wb_ack_i = '1' and state /= READ_ST) then
            pending_wr <= pending_wr + 1;
         elsif wr_beat_now = '0' and wb_ack_i = '1' and state /= READ_ST and pending_wr /= 0 then
            pending_wr <= pending_wr - 1;
         end if;

         case state is
            when IDLE_ST =>
               if s_avm_write_i = '1' and wb_stall_i = '0' then
                  addr       <= unsigned(s_avm_address_i) + 1;
                  beats_left <= unsigned(s_avm_burstcount_i) - 1;
                  if unsigned(s_avm_burstcount_i) /= 1 then
                     state <= WRITE_ST;
                  end if;
               elsif s_avm_read_i = '1' and pending_wr = 0 then
                  addr       <= unsigned(s_avm_address_i);
                  beats_left <= unsigned(s_avm_burstcount_i);
                  acks_left  <= unsigned(s_avm_burstcount_i);
                  state      <= READ_ST;
               end if;

            when WRITE_ST =>
               if s_avm_write_i = '1' and wb_stall_i = '0' then
                  addr       <= addr + 1;
                  beats_left <= beats_left - 1;
                  if beats_left = 1 then
                     state <= IDLE_ST;
                  end if;
               end if;

            when READ_ST =>
               if rd_stb_now = '1' then
                  addr       <= addr + 1;
                  beats_left <= beats_left - 1;
               end if;
               if wb_ack_i = '1' then
                  acks_left <= acks_left - 1;
                  if acks_left = 1 then
                     state <= IDLE_ST;
                  end if;
               end if;
         end case;

         if rst_i = '1' then
            state                 <= IDLE_ST;
            pending_wr            <= (others => '0');
            s_avm_readdatavalid_o <= '0';
         end if;
      end if;
   end process p_fsm;

end architecture synthesis;
