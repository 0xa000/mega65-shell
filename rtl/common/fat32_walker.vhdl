-- SPDX-License-Identifier: LGPL-3.0-or-later
-- Copyright (C) 2026 0xa000 -- part of mega65-shell; provenance in ATTRIBUTION.md
-- FAT32 chain walker / load sequencer (Stage B, DESIGN.md decision 3).
--
-- Sits between load_ctrl and sd_sector; owns the whole load in both
-- descriptor modes:
--
--   raw:   stream ceil(len/512) consecutive sectors from start = LBA.
--   chain: self-mount, then follow the FAT chain from start = cluster.
--
-- Self-mount happens on EVERY chain load (MBR + VBR = two sector reads —
-- never stale, card swaps between loads are safe). Partition select from
-- the descriptor: 0 = first MBR slot with a FAT32 type byte (0x0B/0x0C),
-- 1..4 = explicit MBR primary slot; either way the VBR validation is the
-- real FAT32-only guard (type bytes are unreliable in the wild).
--
-- Guards (DESIGN.md): FAT32 only (bytes/sector 512, FAT16 sector count
-- zero, sectors/cluster a power of two), cluster bounds check against
-- the computed cluster count, read-only, FAT copy #0 only. Loads are
-- length-bounded (bytes_left countdown), so even a cyclic FAT chain
-- terminates. A 512 B FAT-sector cache (LUTRAM + tag) makes chain
-- lookups ~free for contiguous files: 128 entries per FAT sector = one
-- extra sector read per 128 clusters.
--
-- Exactly len bytes are forwarded to the ICAP seam; everything else the
-- engine emits (metadata sectors, final-sector tail) is consumed here.
--
-- Errors: walker-level codes >= 0x80 in diag_code, SD-level errors pass
-- sd_sector's diagnostic state through unchanged (< 0x80):
--   0x80 MBR signature bad        0x83 chain ended before len (EOC)
--   0x81 no matching partition    0x84 bad / out-of-bounds cluster
--   0x82 VBR invalid (not FAT32)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fat32_walker is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;

    -- Request from load_ctrl (pulse; sampled while idle).
    req         : in  std_logic;
    mode_chain  : in  std_logic;                      -- 0 raw, 1 FAT32 chain
    part_sel    : in  std_logic_vector(3 downto 0);   -- 0 auto, 1..4 slot
    start       : in  std_logic_vector(31 downto 0);  -- LBA or cluster
    byte_len    : in  std_logic_vector(31 downto 0);

    -- Byte stream towards icap_loader (exactly byte_len bytes).
    byte_out    : out std_logic_vector(7 downto 0);
    byte_valid  : out std_logic;

    -- Status towards load_ctrl.
    busy        : out std_logic;
    done        : out std_logic;
    err         : out std_logic;
    diag_code   : out std_logic_vector(7 downto 0);
    diag_r1     : out std_logic_vector(7 downto 0);

    -- sd_sector command/status/stream.
    sdc_init    : out std_logic;
    sdc_rd      : out std_logic;
    sdc_lba     : out std_logic_vector(31 downto 0);
    sdc_done    : in  std_logic;
    sdc_err     : in  std_logic;
    sdc_diag    : in  std_logic_vector(7 downto 0);
    sdc_diag_r1 : in  std_logic_vector(7 downto 0);
    sdc_byte    : in  std_logic_vector(7 downto 0);
    sdc_valid   : in  std_logic
    );
end fat32_walker;

architecture rtl of fat32_walker is

  type wk_st_t is (
    W_IDLE,
    W_INIT,          -- card bring-up running in sd_sector
    W_MBR,           -- sector 0: partition table + signature
    W_VBR,           -- volume boot record: geometry + FAT32 guards
    W_CLUS,          -- validate cluster, issue first sector of it
    W_DATA,          -- data sectors of the current cluster (chain mode)
    W_RAW,           -- consecutive data sectors (raw mode)
    W_FAT_REQ,       -- FAT lookup: cache hit or issue FAT sector read
    W_FAT_FILL,      -- FAT sector streaming into the cache
    W_FAT_CACHE_RD,  -- registered cache read
    W_FAT_DECIDE,    -- next cluster / EOC / bad
    W_DONE,
    W_FAIL
    );
  signal wk_st : wk_st_t := W_IDLE;

  -- Latched request.
  signal chain_r  : std_logic := '0';
  signal auto_r   : std_logic := '0';
  signal start_r  : unsigned(31 downto 0) := (others => '0');
  signal bytes_left : unsigned(31 downto 0) := (others => '0');

  -- Sector byte index (position within the sector being streamed).
  signal bidx : natural range 0 to 511 := 0;

  -- MBR parse.
  signal found    : std_logic := '0';
  signal sel_ent  : unsigned(1 downto 0) := (others => '0');
  signal part_lba : unsigned(31 downto 0) := (others => '0');
  signal sig0, sig1 : std_logic := '0';

  -- VBR parse (raw captured fields, little-endian assembly).
  signal bps_lo, bps_hi   : std_logic_vector(7 downto 0) := (others => '0');
  signal spc_r            : unsigned(7 downto 0) := (others => '0');
  signal reserved_r       : unsigned(15 downto 0) := (others => '0');
  signal nfats_r          : unsigned(7 downto 0) := (others => '0');
  signal fatsz16_nz       : std_logic := '0';
  signal totsec_r         : unsigned(31 downto 0) := (others => '0');
  signal fatsz_r          : unsigned(31 downto 0) := (others => '0');

  -- Mount results.
  signal fat_begin   : unsigned(31 downto 0) := (others => '0');
  signal data_begin  : unsigned(31 downto 0) := (others => '0');
  signal spc_shift   : natural range 0 to 7 := 0;
  signal spc_m1      : unsigned(7 downto 0) := (others => '0');
  signal max_cluster : unsigned(31 downto 0) := (others => '0');

  -- Chain state.
  signal cluster     : unsigned(31 downto 0) := (others => '0');
  signal sec_in_clus : unsigned(7 downto 0) := (others => '0');
  signal lba_cur     : unsigned(31 downto 0) := (others => '0');

  -- FAT sector cache: 128 x 32 LUTRAM + tag.
  type fat_cache_t is array (0 to 127) of std_logic_vector(31 downto 0);
  signal fat_cache : fat_cache_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of fat_cache : signal is "distributed";
  signal cache_tag   : unsigned(31 downto 0) := (others => '0');
  signal cache_valid : std_logic := '0';
  signal fat_lba_r   : unsigned(31 downto 0) := (others => '0');
  signal fat_entry   : std_logic_vector(31 downto 0) := (others => '0');
  signal word_asm    : std_logic_vector(23 downto 0) := (others => '0');

  constant EOC_MIN : unsigned(27 downto 0) := x"FFFFFF8";
  constant BAD_CLU : unsigned(27 downto 0) := x"FFFFFF7";

begin

  busy <= '0' when wk_st = W_IDLE else '1';

  process(clk)
    variable rel   : integer;
    variable entv  : unsigned(27 downto 0);
    variable spcok : boolean;
    variable shv   : natural range 0 to 7;
  begin
    if rising_edge(clk) then
      byte_valid <= '0';
      done       <= '0';
      err        <= '0';
      sdc_init   <= '0';
      sdc_rd     <= '0';

      if rst = '1' then
        wk_st       <= W_IDLE;
        cache_valid <= '0';
      else

        -- Data forwarding: in the data states every engine byte goes to
        -- the ICAP seam while the length budget lasts.
        if sdc_valid = '1' and (wk_st = W_DATA or wk_st = W_RAW) then
          if bytes_left /= 0 then
            byte_out   <= sdc_byte;
            byte_valid <= '1';
            bytes_left <= bytes_left - 1;
          end if;
        end if;

        -- Sector byte index (all streaming states).
        if sdc_valid = '1' then
          if bidx /= 511 then
            bidx <= bidx + 1;
          end if;
        end if;

        case wk_st is

          -- -----------------------------------------------------------------
          when W_IDLE =>
            if req = '1' then
              chain_r    <= mode_chain;
              start_r    <= unsigned(start);
              bytes_left <= unsigned(byte_len);
              if unsigned(part_sel) = 0 then
                auto_r  <= '1';
                found   <= '0';
                sel_ent <= "00";
              else
                auto_r  <= '0';
                found   <= '1';
                sel_ent <= resize(unsigned(part_sel) - 1, 2);
              end if;
              cache_valid <= '0';     -- new load, new card state: cold cache
              sdc_init    <= '1';
              wk_st       <= W_INIT;
            end if;

          -- -----------------------------------------------------------------
          when W_INIT =>
            if sdc_done = '1' then
              if chain_r = '1' then
                sdc_lba <= (others => '0');       -- MBR
                sdc_rd  <= '1';
                bidx    <= 0;
                sig0    <= '0';
                sig1    <= '0';
                wk_st   <= W_MBR;
              else
                lba_cur <= start_r;
                sdc_lba <= std_logic_vector(start_r);
                sdc_rd  <= '1';
                bidx    <= 0;
                wk_st   <= W_RAW;
              end if;
            end if;

          -- -----------------------------------------------------------------
          -- MBR: partition entries at 446 + 16*e; type byte at +4, LBA
          -- begin (LE32) at +8. Auto mode decides at the type byte, which
          -- passes BEFORE the entry's LBA bytes — capture works in one pass.
          -- -----------------------------------------------------------------
          when W_MBR =>
            if sdc_valid = '1' then
              rel := bidx - 446;
              if rel >= 0 and rel < 64 then
                if (rel mod 16) = 4 then          -- type byte of entry rel/16
                  if auto_r = '1' and found = '0'
                     and (sdc_byte = x"0B" or sdc_byte = x"0C") then
                    found   <= '1';
                    sel_ent <= to_unsigned(rel / 16, 2);
                  end if;
                elsif (rel mod 16) >= 8 and (rel mod 16) <= 11
                      and found = '1'
                      and to_unsigned(rel / 16, 2) = sel_ent then
                  case rel mod 16 is
                    when 8      => part_lba(7 downto 0)   <= unsigned(sdc_byte);
                    when 9      => part_lba(15 downto 8)  <= unsigned(sdc_byte);
                    when 10     => part_lba(23 downto 16) <= unsigned(sdc_byte);
                    when others => part_lba(31 downto 24) <= unsigned(sdc_byte);
                  end case;
                end if;
              elsif bidx = 510 and sdc_byte = x"55" then
                sig0 <= '1';
              elsif bidx = 511 and sdc_byte = x"AA" then
                sig1 <= '1';
              end if;
            elsif sdc_done = '1' then
              if sig0 = '0' or sig1 = '0' then
                diag_code <= x"80";
                wk_st     <= W_FAIL;
              elsif found = '0' then
                diag_code <= x"81";
                wk_st     <= W_FAIL;
              else
                sdc_lba <= std_logic_vector(part_lba);
                sdc_rd  <= '1';
                bidx    <= 0;
                sig0    <= '0';
                sig1    <= '0';
                wk_st   <= W_VBR;
              end if;
            end if;

          -- -----------------------------------------------------------------
          -- VBR: geometry fields + the FAT32-only guards.
          -- -----------------------------------------------------------------
          when W_VBR =>
            if sdc_valid = '1' then
              case bidx is
                when 11  => bps_lo <= sdc_byte;
                when 12  => bps_hi <= sdc_byte;
                when 13  => spc_r  <= unsigned(sdc_byte);
                when 14  => reserved_r(7 downto 0)  <= unsigned(sdc_byte);
                when 15  => reserved_r(15 downto 8) <= unsigned(sdc_byte);
                when 16  => nfats_r <= unsigned(sdc_byte);
                when 22 | 23 =>
                  if sdc_byte /= x"00" then
                    fatsz16_nz <= '1';            -- FAT12/16, not our volume
                  end if;
                when 32  => totsec_r(7 downto 0)    <= unsigned(sdc_byte);
                when 33  => totsec_r(15 downto 8)   <= unsigned(sdc_byte);
                when 34  => totsec_r(23 downto 16)  <= unsigned(sdc_byte);
                when 35  => totsec_r(31 downto 24)  <= unsigned(sdc_byte);
                when 36  => fatsz_r(7 downto 0)     <= unsigned(sdc_byte);
                when 37  => fatsz_r(15 downto 8)    <= unsigned(sdc_byte);
                when 38  => fatsz_r(23 downto 16)   <= unsigned(sdc_byte);
                when 39  => fatsz_r(31 downto 24)   <= unsigned(sdc_byte);
                when 510 => if sdc_byte = x"55" then sig0 <= '1'; end if;
                when 511 => if sdc_byte = x"AA" then sig1 <= '1'; end if;
                when others => null;
              end case;
            elsif sdc_done = '1' then
              spcok := false;
              shv   := 0;
              case to_integer(spc_r) is
                when 1   => shv := 0; spcok := true;
                when 2   => shv := 1; spcok := true;
                when 4   => shv := 2; spcok := true;
                when 8   => shv := 3; spcok := true;
                when 16  => shv := 4; spcok := true;
                when 32  => shv := 5; spcok := true;
                when 64  => shv := 6; spcok := true;
                when 128 => shv := 7; spcok := true;
                when others => spcok := false;
              end case;
              if sig0 = '0' or sig1 = '0'
                 or bps_lo /= x"00" or bps_hi /= x"02"   -- 512 B sectors only
                 or fatsz16_nz = '1'                     -- FAT32 only
                 or fatsz_r = 0 or nfats_r = 0
                 or not spcok then
                diag_code <= x"82";
                wk_st     <= W_FAIL;
              else
                spc_shift  <= shv;
                spc_m1     <= spc_r - 1;
                fat_begin  <= part_lba + reserved_r;
                data_begin <= part_lba + reserved_r
                              + resize(nfats_r * fatsz_r, 32);
                -- max data cluster = 1 + data_sectors/spc (clusters from 2)
                max_cluster <= 1 + shift_right(
                  totsec_r - reserved_r - resize(nfats_r * fatsz_r, 32), shv);
                cluster <= start_r;
                wk_st   <= W_CLUS;
              end if;
            end if;

          -- -----------------------------------------------------------------
          when W_CLUS =>
            if cluster < 2 or cluster > max_cluster then
              diag_code <= x"84";
              wk_st     <= W_FAIL;
            else
              sec_in_clus <= (others => '0');
              lba_cur <= data_begin
                         + shift_left(cluster - 2, spc_shift);
              sdc_lba <= std_logic_vector(
                data_begin + shift_left(cluster - 2, spc_shift));
              sdc_rd  <= '1';
              bidx    <= 0;
              wk_st   <= W_DATA;
            end if;

          -- -----------------------------------------------------------------
          when W_DATA =>
            if sdc_done = '1' then
              if bytes_left = 0 then
                wk_st <= W_DONE;
              elsif sec_in_clus = spc_m1 then
                wk_st <= W_FAT_REQ;
              else
                sec_in_clus <= sec_in_clus + 1;
                lba_cur     <= lba_cur + 1;
                sdc_lba     <= std_logic_vector(lba_cur + 1);
                sdc_rd      <= '1';
                bidx        <= 0;
              end if;
            end if;

          -- -----------------------------------------------------------------
          when W_RAW =>
            if sdc_done = '1' then
              if bytes_left = 0 then
                wk_st <= W_DONE;
              else
                lba_cur <= lba_cur + 1;
                sdc_lba <= std_logic_vector(lba_cur + 1);
                sdc_rd  <= '1';
                bidx    <= 0;
              end if;
            end if;

          -- -----------------------------------------------------------------
          -- FAT lookup. FAT sector = fat_begin + cluster/128 (FAT copy #0
          -- only); entry index = cluster mod 128.
          -- -----------------------------------------------------------------
          when W_FAT_REQ =>
            fat_lba_r <= fat_begin + resize(cluster(31 downto 7), 32);
            if cache_valid = '1'
               and cache_tag = fat_begin + resize(cluster(31 downto 7), 32) then
              wk_st <= W_FAT_CACHE_RD;
            else
              sdc_lba <= std_logic_vector(
                fat_begin + resize(cluster(31 downto 7), 32));
              sdc_rd      <= '1';
              bidx        <= 0;
              cache_valid <= '0';
              wk_st       <= W_FAT_FILL;
            end if;

          -- -----------------------------------------------------------------
          when W_FAT_FILL =>
            if sdc_valid = '1' then
              -- little-endian word packing, commit on every 4th byte
              case bidx mod 4 is
                when 0 => word_asm(7 downto 0)   <= sdc_byte;
                when 1 => word_asm(15 downto 8)  <= sdc_byte;
                when 2 => word_asm(23 downto 16) <= sdc_byte;
                when others =>
                  fat_cache(bidx / 4) <= sdc_byte & word_asm;
              end case;
            elsif sdc_done = '1' then
              cache_tag   <= fat_lba_r;
              cache_valid <= '1';
              wk_st       <= W_FAT_CACHE_RD;
            end if;

          -- -----------------------------------------------------------------
          when W_FAT_CACHE_RD =>
            fat_entry <= fat_cache(to_integer(cluster(6 downto 0)));
            wk_st     <= W_FAT_DECIDE;

          -- -----------------------------------------------------------------
          when W_FAT_DECIDE =>
            entv := unsigned(fat_entry(27 downto 0));
            if entv >= EOC_MIN then
              diag_code <= x"83";     -- end of chain but bytes_left /= 0
              wk_st     <= W_FAIL;
            elsif entv = BAD_CLU then
              diag_code <= x"84";
              wk_st     <= W_FAIL;
            else
              cluster <= resize(entv, 32);
              wk_st   <= W_CLUS;
            end if;

          -- -----------------------------------------------------------------
          when W_DONE =>
            done  <= '1';
            wk_st <= W_IDLE;

          when W_FAIL =>
            err   <= '1';
            wk_st <= W_IDLE;

        end case;

        -- SD-level errors abort from any active state; the engine's
        -- diagnostic state passes through (< 0x80, walker codes >= 0x80).
        if sdc_err = '1' and wk_st /= W_IDLE then
          diag_code <= sdc_diag;
          wk_st     <= W_FAIL;
        end if;
        diag_r1 <= sdc_diag_r1;
      end if;
    end if;
  end process;

end rtl;
