-- Testbench for the Stage A2/B SD load path: load_ctrl + fat32_walker +
-- sd_sector against a behavioral SD card model serving a synthetic FAT32
-- disk, driven by UART-style descriptor bytes.
--
-- Synthetic disk layout (512 B sectors):
--   lba 0     MBR: entry0 = type 0x83 (non-FAT, must be skipped by auto
--             partition select), entry1 = type 0x0C at lba 2048
--   lba 2048  VBR: 512 B/sector, 2 sectors/cluster, 32 reserved, 2 FATs,
--             16 sectors/FAT, 65536 total sectors
--   lba 2080  FAT#0: chain 5 -> 6 -> 9 -> EOC (deliberately fragmented)
--   lba 2112  data region begin; cluster c at lba 2112 + (c-2)*2
--   data byte = (lba*7 + offset) mod 256 everywhere in the data region
--
-- Tests:
--   1. corrupt frame           -> 'N', no load started
--   2. raw mode, lba 3000/700B -> byte-exact, 'A'+'D'
--   3. chain mode, auto partition (skips the 0x83 entry), cluster 5,
--      2500 B -> follows 5,6,9 byte-exact across the fragmentation,
--      exercises FAT-cache fill (5->6) and hit (6->9), 'A'+'D'
--   4. chain mode, explicit partition 2, cluster 5, 5000 B -> chain is
--      only 3072 B: premature EOC, 'E' + code 0x83
--
-- Card model: as in phase 1 — and it ENFORCES the NCS rule (start bit
-- within 8 clocks of CS assert = error), the lesson the original
-- picorv32-menu TB model missed. CMD17 serves disk_byte() sectors.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_sd_load is
end entity;

architecture sim of tb_sd_load is

  constant CLK_HZ : positive := 50_000_000;

  -- disk geometry (keep in sync with the header comment)
  constant PART_LBA   : natural := 2048;
  constant FAT_LBA    : natural := 2080;
  constant DATA_LBA   : natural := 2112;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal uart_byte  : std_logic_vector(7 downto 0) := (others => '0');
  signal uart_valid : std_logic := '0';

  signal ld_byte  : std_logic_vector(7 downto 0);
  signal ld_valid : std_logic;

  signal wk_req, wk_busy, wk_done, wk_err : std_logic;
  signal wk_mode                          : std_logic;
  signal wk_part                          : std_logic_vector(3 downto 0);
  signal wk_start, wk_len                 : std_logic_vector(31 downto 0);
  signal wk_diag, wk_diag_r1              : std_logic_vector(7 downto 0);
  signal wk_byte_s                        : std_logic_vector(7 downto 0);
  signal wk_valid_s                       : std_logic;

  signal sdc_init, sdc_rd, sdc_done, sdc_err : std_logic;
  signal sdc_lba                             : std_logic_vector(31 downto 0);
  signal sdc_diag, sdc_diag_r1               : std_logic_vector(7 downto 0);
  signal sdc_byte_s                          : std_logic_vector(7 downto 0);
  signal sdc_valid_s                         : std_logic;

  signal tx_data : std_logic_vector(7 downto 0);
  signal tx_send : std_logic;

  signal sd_cs_n, sd_clk_w, sd_mosi : std_logic;
  signal sd_miso : std_logic := '1';

  signal done : boolean := false;

  -- checker interface
  signal rx_count : natural := 0;
  signal rx_bad   : natural := 0;
  signal rx_clear : std_logic := '0';
  signal test_id  : natural := 0;

  -- echo log
  type echo_arr_t is array (0 to 7) of std_logic_vector(7 downto 0);
  signal echo_log : echo_arr_t := (others => (others => '0'));
  signal echo_n   : natural := 0;

  -- ---------------------------------------------------------------------
  -- Synthetic disk content.
  -- ---------------------------------------------------------------------
  function fat_entry_val(idx : natural) return natural is
  begin
    case idx is
      when 0      => return 16#0FFFFFF8#;
      when 1      => return 16#0FFFFFFF#;
      when 5      => return 6;
      when 6      => return 9;
      when 9      => return 16#0FFFFFFF#;
      when others => return 0;
    end case;
  end function;

  function disk_byte(lba : natural; off : natural) return natural is
    variable e : natural;
  begin
    if lba = 0 then                                    -- MBR
      case off is
        when 446 + 4  => return 16#83#;                -- entry0: non-FAT
        when 446 + 8  => return 16#E7#;                -- entry0 lba 999 (junk)
        when 446 + 9  => return 16#03#;
        when 462 + 4  => return 16#0C#;                -- entry1: FAT32 LBA
        when 462 + 8  => return PART_LBA mod 256;      -- 2048 LE
        when 462 + 9  => return (PART_LBA / 256) mod 256;
        when 462 + 10 => return (PART_LBA / 65536) mod 256;
        when 510      => return 16#55#;
        when 511      => return 16#AA#;
        when others   => return 0;
      end case;
    elsif lba = PART_LBA then                          -- VBR
      case off is
        when 11     => return 0;                       -- 512 B/sector LE
        when 12     => return 2;
        when 13     => return 2;                       -- sectors/cluster
        when 14     => return 32;                      -- reserved LE
        when 15     => return 0;
        when 16     => return 2;                       -- num FATs
        when 32     => return 0;                       -- totsec 65536 LE
        when 33     => return 0;
        when 34     => return 1;
        when 35     => return 0;
        when 36     => return 16;                      -- sectors/FAT LE
        when 37 | 38 | 39 => return 0;
        when 510    => return 16#55#;
        when 511    => return 16#AA#;
        when others => return 0;
      end case;
    elsif lba >= FAT_LBA and lba < FAT_LBA + 16 then   -- FAT#0
      if lba = FAT_LBA then
        e := fat_entry_val(off / 4);
        return (e / (256 ** (off mod 4))) mod 256;     -- LE
      else
        return 0;
      end if;
    elsif lba >= DATA_LBA then                         -- data region
      return (lba * 7 + off) mod 256;
    else
      return 0;                                        -- FAT#1 / reserved
    end if;
  end function;

  -- file byte n of the chain-mode test file (clusters 5, 6, 9; spc = 2)
  function file_byte(n : natural) return natural is
    variable c   : natural;
    variable lba : natural;
  begin
    case n / 1024 is
      when 0      => c := 5;
      when 1      => c := 6;
      when others => c := 9;
    end case;
    lba := DATA_LBA + (c - 2) * 2 + (n mod 1024) / 512;
    return disk_byte(lba, n mod 512);
  end function;

begin

  clk <= not clk after 10 ns when not done else '0';
  rst <= '0' after 200 ns;

  ctrl0 : entity work.load_ctrl
    port map (
      clk => clk, rst => rst,
      uart_byte => uart_byte, uart_valid => uart_valid,
      loader_idle => '1',
      ld_byte => ld_byte, ld_valid => ld_valid,
      wk_req => wk_req, wk_mode => wk_mode, wk_part => wk_part,
      wk_start => wk_start, wk_len => wk_len,
      wk_busy => wk_busy, wk_done => wk_done, wk_err => wk_err,
      wk_diag => wk_diag, wk_diag_r1 => wk_diag_r1,
      wk_byte => wk_byte_s, wk_valid => wk_valid_s,
      tx_data => tx_data, tx_send => tx_send, tx_busy => '0');

  walker0 : entity work.fat32_walker
    port map (
      clk => clk, rst => rst,
      req => wk_req, mode_chain => wk_mode, part_sel => wk_part,
      start => wk_start, byte_len => wk_len,
      byte_out => wk_byte_s, byte_valid => wk_valid_s,
      busy => wk_busy, done => wk_done, err => wk_err,
      diag_code => wk_diag, diag_r1 => wk_diag_r1,
      sdc_init => sdc_init, sdc_rd => sdc_rd, sdc_lba => sdc_lba,
      sdc_done => sdc_done, sdc_err => sdc_err,
      sdc_diag => sdc_diag, sdc_diag_r1 => sdc_diag_r1,
      sdc_byte => sdc_byte_s, sdc_valid => sdc_valid_s);

  sd0 : entity work.sd_sector
    generic map ( CLK_HZ => CLK_HZ )
    port map (
      clk => clk, rst => rst,
      init_req => sdc_init, rd_req => sdc_rd, lba => sdc_lba,
      byte_out => sdc_byte_s, byte_valid => sdc_valid_s,
      ready => open, done => sdc_done, err => sdc_err,
      diag_state => sdc_diag, diag_r1 => sdc_diag_r1,
      sd_cs_n => sd_cs_n, sd_clk => sd_clk_w, sd_mosi => sd_mosi,
      sd_miso => sd_miso);

  -- =====================================================================
  -- Emitted-stream checker (walker output only; descriptor magic bytes
  -- pass through to the loader by design and are excluded via wk_busy).
  -- =====================================================================
  check : process(clk)
    variable expect : natural;
  begin
    if rising_edge(clk) then
      if rx_clear = '1' then
        rx_count <= 0;
        rx_bad   <= 0;
      elsif ld_valid = '1' and wk_busy = '1' then
        case test_id is
          when 2      => expect := disk_byte(3000 + rx_count / 512,
                                             rx_count mod 512);
          when others => expect := file_byte(rx_count);
        end case;
        if to_integer(unsigned(ld_byte)) /= expect then
          rx_bad <= rx_bad + 1;
          if rx_bad < 5 then
            report "STREAM(test " & integer'image(test_id) & "): byte " &
                   integer'image(rx_count) & " = " &
                   integer'image(to_integer(unsigned(ld_byte))) &
                   ", expected " & integer'image(expect)
              severity error;
          end if;
        end if;
        rx_count <= rx_count + 1;
      end if;
    end if;
  end process;

  -- echo log
  echo_mon : process(clk)
  begin
    if rising_edge(clk) then
      if rx_clear = '1' then
        echo_n <= 0;
      elsif tx_send = '1' then
        echo_log(echo_n) <= tx_data;
        echo_n <= echo_n + 1;
        report "ECHO: " & integer'image(to_integer(unsigned(tx_data)));
      end if;
    end if;
  end process;

  -- =====================================================================
  -- SD card model.
  -- =====================================================================
  card : process
    variable frame      : std_logic_vector(47 downto 0);
    variable resp       : std_logic_vector(0 to 55) := (others => '1');
    variable resp_len   : natural := 0;
    variable resp_wait  : integer := -1;
    variable bitcnt     : natural := 0;
    variable in_frame   : boolean := false;
    variable acmd41_cnt : natural := 0;
    variable cmd        : natural;
    variable arg        : natural;
    variable cs_low_cnt : natural := 0;
    variable data_lba   : natural := 0;
    variable data_bits  : integer := -1;
    variable data_byte  : natural := 0;
  begin
    while not done loop
      wait until (sd_clk_w'event or sd_cs_n'event) and not done;

      if sd_cs_n = '1' then
        in_frame   := false;
        resp_len   := 0;
        resp_wait  := -1;
        data_bits  := -1;
        cs_low_cnt := 0;
        sd_miso <= '1';
        next;
      end if;

      if rising_edge(sd_clk_w) then
        cs_low_cnt := cs_low_cnt + 1;

        if not in_frame then
          if sd_mosi = '0' and resp_len = 0 and resp_wait < 0
             and data_bits < 0 then
            assert cs_low_cnt > 8
              report "CARD: start bit only " & integer'image(cs_low_cnt) &
                     " clocks after CS assert (NCS violated)"
              severity error;
            in_frame  := true;
            frame     := (others => '0');
            frame(47) := sd_mosi;
            bitcnt    := 1;
          end if;
        else
          frame(47 - bitcnt) := sd_mosi;
          bitcnt := bitcnt + 1;
          if bitcnt = 48 then
            in_frame := false;
            cmd := to_integer(unsigned(frame(45 downto 40)));
            arg := to_integer(unsigned(frame(39 downto 8)));
            resp := (others => '1');
            case cmd is
              when 0 =>
                assert frame = x"400000000095"
                  report "CARD: CMD0 frame corrupt" severity error;
                acmd41_cnt := 0;
                resp(0 to 7) := x"01"; resp_len := 8;
              when 8 =>
                resp(0 to 7) := x"01";
                resp(8 to 39) := x"000001AA"; resp_len := 40;
              when 55 =>
                resp(0 to 7) := x"01"; resp_len := 8;
              when 41 =>
                if acmd41_cnt < 2 then
                  acmd41_cnt := acmd41_cnt + 1;
                  resp(0 to 7) := x"01";
                else
                  resp(0 to 7) := x"00";
                end if;
                resp_len := 8;
              when 58 =>
                resp(0 to 7) := x"00";
                resp(8 to 39) := x"C0FF8000"; resp_len := 40;  -- CCS=1
              when 17 =>
                data_lba := arg;
                resp(0 to 7) := x"00"; resp_len := 8;
                data_bits := (515 * 8) + 16;   -- gap + token + 512 + 2 CRC
              when others =>
                resp(0 to 7) := x"04"; resp_len := 8;
            end case;
            resp_wait := 9;
            bitcnt := 0;
          end if;
        end if;
      end if;

      if falling_edge(sd_clk_w) then
        if resp_wait > 0 then
          resp_wait := resp_wait - 1;
          sd_miso <= '1';
          if resp_wait = 0 then
            resp_wait := -1;
            sd_miso <= resp(0);
            resp(0 to 54) := resp(1 to 55);
            resp_len := resp_len - 1;
          end if;
        elsif resp_len > 0 then
          sd_miso <= resp(0);
          resp(0 to 54) := resp(1 to 55);
          resp_len := resp_len - 1;
        elsif data_bits > 0 then
          data_bits := data_bits - 1;
          if data_bits >= 515 * 8 then
            sd_miso <= '1';                          -- N_ac gap
          else
            if (data_bits mod 8) = 7 then
              case (515 * 8 - 1 - data_bits) / 8 is
                when 0          => data_byte := 16#FE#;   -- data token
                when 513 | 514  => data_byte := 0;        -- CRC (unchecked)
                when others     =>
                  data_byte := disk_byte(data_lba,
                                         (515 * 8 - 1 - data_bits) / 8 - 1);
              end case;
            end if;
            if (data_byte / (2 ** (data_bits mod 8))) mod 2 = 1 then
              sd_miso <= '1';
            else
              sd_miso <= '0';
            end if;
            if data_bits = 0 then
              data_bits := -1;
            end if;
          end if;
        else
          sd_miso <= '1';
        end if;
      end if;
    end loop;
    wait;
  end process card;

  -- =====================================================================
  -- Stimulus.
  -- =====================================================================
  stim : process
    procedure send_byte(b : in std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk);
      uart_byte  <= b;
      uart_valid <= '1';
      wait until rising_edge(clk);
      uart_valid <= '0';
      for i in 1 to 20 loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure send_frame(mode, part, start, len : in natural;
                         corrupt : in boolean) is
      variable payload : std_logic_vector(71 downto 0);
      variable csum    : std_logic_vector(7 downto 0) := (others => '0');
    begin
      payload := std_logic_vector(to_unsigned(mode, 4)) &
                 std_logic_vector(to_unsigned(part, 4)) &
                 std_logic_vector(to_unsigned(start, 32)) &
                 std_logic_vector(to_unsigned(len, 32));
      send_byte(x"4D"); send_byte(x"36"); send_byte(x"35"); send_byte(x"44");
      csum := (others => '0');
      for i in 8 downto 0 loop
        csum := csum xor payload(8 * i + 7 downto 8 * i);
      end loop;
      if corrupt then
        csum := csum xor x"FF";
      end if;
      for i in 8 downto 0 loop
        send_byte(payload(8 * i + 7 downto 8 * i));
      end loop;
      send_byte(csum);
    end procedure;

    procedure wait_load(timeout_val : in time) is
      variable t0 : time;
    begin
      t0 := now;
      while wk_done /= '1' and wk_err /= '1' loop
        wait until rising_edge(clk);
        if now - t0 > timeout_val then
          report "TB: TIMEOUT waiting for load completion" severity failure;
        end if;
      end loop;
      wait for 10 us;    -- let echoes drain
    end procedure;

    procedure new_test(id : in natural) is
    begin
      wait until rising_edge(clk);
      test_id  <= id;
      rx_clear <= '1';
      wait until rising_edge(clk);
      rx_clear <= '0';
      wait until rising_edge(clk);
    end procedure;

    variable pass : boolean := true;
  begin
    wait until rst = '0';
    wait for 1 us;

    -- test 1: corrupt frame ------------------------------------------------
    new_test(1);
    send_frame(1, 0, 5, 2500, corrupt => true);
    wait for 20 us;
    if wk_busy /= '0' or echo_n /= 1 or echo_log(0) /= x"4E" then
      report "TB: test 1 FAIL (corrupt frame not NAKed)" severity error;
      pass := false;
    end if;

    -- test 2: raw mode -----------------------------------------------------
    new_test(2);
    send_frame(0, 0, 3000, 700, corrupt => false);
    wait_load(100 ms);
    if rx_count /= 700 or rx_bad /= 0 or echo_n /= 2
       or echo_log(0) /= x"41" or echo_log(1) /= x"44" then
      report "TB: test 2 FAIL (raw: " & integer'image(rx_count) & " bytes, "
             & integer'image(rx_bad) & " bad)" severity error;
      pass := false;
    end if;

    -- test 3: chain mode, auto partition ------------------------------------
    new_test(3);
    send_frame(1, 0, 5, 2500, corrupt => false);
    wait_load(100 ms);
    if rx_count /= 2500 or rx_bad /= 0 or echo_n /= 2
       or echo_log(0) /= x"41" or echo_log(1) /= x"44" then
      report "TB: test 3 FAIL (chain: " & integer'image(rx_count) &
             " bytes, " & integer'image(rx_bad) & " bad)" severity error;
      pass := false;
    end if;

    -- test 4: chain mode, explicit partition, premature EOC ------------------
    new_test(4);
    send_frame(1, 2, 5, 5000, corrupt => false);
    wait_load(100 ms);
    if echo_n /= 4 or echo_log(0) /= x"41" or echo_log(1) /= x"45"
       or echo_log(2) /= x"83" then
      report "TB: test 4 FAIL (expected 'A','E',0x83; got " &
             integer'image(echo_n) & " echoes, code " &
             integer'image(to_integer(unsigned(echo_log(2))))
        severity error;
      pass := false;
    end if;
    if rx_count /= 3072 or rx_bad /= 0 then
      report "TB: test 4 FAIL (stream before EOC: " &
             integer'image(rx_count) & " bytes, " &
             integer'image(rx_bad) & " bad)" severity error;
      pass := false;
    end if;

    if pass then
      report "TB: PASS (all 4 tests)";
    else
      report "TB: FAIL" severity error;
    end if;

    done <= true;
    wait;
  end process stim;

end architecture sim;
