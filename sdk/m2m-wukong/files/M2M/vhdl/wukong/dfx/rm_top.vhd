----------------------------------------------------------------------------------
-- MiSTer2MEGA65 — DFX reconfigurable module top (thin-shell carve-out)
--
-- This entity IS the reconfigurable partition: its ports are the partition
-- pins of the shell/RM boundary defined in m65-shell-poc/docs/BOUNDARY-V2.md.
-- Inside: framework_rm (the M2M framework as RM-side library code, incl.
-- the vga_to_hdmi TMDS encoder) plus the CORE (democore variant without its
-- clk MMCM). Everything the shell owns — pins, clock generation, reset
-- manager, DDR3 controller, OSERDES serialisers, ICAP loader — is on the
-- other side of these ports.
--
-- Port rules (DESIGN.md tier model): everything here is either a shell-
-- generated clock, a latency-insensitive bus, or a slow raw signal; the
-- shell registers/decouples its side of every RM output.
--
-- Wiring of framework<->CORE is identical to top_wukong.vhd — diff against
-- it to review.
--
-- Wukong DFX carve-out done by 0xa000 in 2026, based on top_wukong.vhd,
-- licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.types_pkg.all;
use work.video_modes_pkg.all;
use work.democore_clk_pkg.all;

entity rm_top is
port (
   -- Clocks and resets from the static shell (all BUFG-driven shell-side;
   -- 7-series DFX: no MMCM/PLL/BUFG inside a reconfigurable partition)
   sys_clk_i               : in    std_logic;   -- 100 MHz system clock
   sys_pps_i               : in    std_logic;   -- one pulse per second
   reset_shell_n_i         : in    std_logic;   -- from the shell's reset manager
   reset_core_n_i          : in    std_logic;
   loader_clk_i            : in    std_logic;   -- 50 MHz
   loader_rst_i            : in    std_logic;
   core_clk1_i             : in    std_logic;   -- CLKOUT1 core clock (integer; 54 MHz for democore)
   core_clk1_rst_i         : in    std_logic;
   mem_clk_i               : in    std_logic;   -- 100 MHz = UberDDR3 controller clock
   mem_rst_i               : in    std_logic;
   audio_clk_i             : in    std_logic;   -- 12.288 MHz
   audio_rst_i             : in    std_logic;
   hdmi_clk_i              : in    std_logic;   -- HDMI pixel clock (shell MMCM; follows vclk_sel_o)
   hdmi_rst_i              : in    std_logic;

   -- Serial communication (tier 0 passthrough)
   uart_rx_i               : in    std_logic;
   uart_tx_o               : out   std_logic;

   -- C64 keyboard, logical signals (the open-drain/charge IOBUFs are in the shell)
   kb_porta_col_n_o        : out   std_logic_vector(7 downto 0);
   kb_portb_row_n_i        : in    std_logic_vector(7 downto 0);
   kb_portb_charge_o       : out   std_logic;
   kb_restore_n_i          : in    std_logic;

   -- SD card (RM-owned in v0; the shell loads partials over UART)
   sd_reset_o              : out   std_logic;
   sd_clk_o                : out   std_logic;
   sd_mosi_o               : out   std_logic;
   sd_miso_i               : in    std_logic;

   -- Joysticks (inputs only on the Wukong)
   joy_1_up_n_i            : in    std_logic;
   joy_1_down_n_i          : in    std_logic;
   joy_1_left_n_i          : in    std_logic;
   joy_1_right_n_i         : in    std_logic;
   joy_1_fire_n_i          : in    std_logic;
   joy_2_up_n_i            : in    std_logic;
   joy_2_down_n_i          : in    std_logic;
   joy_2_left_n_i          : in    std_logic;
   joy_2_right_n_i         : in    std_logic;
   joy_2_fire_n_i          : in    std_logic;

   -- Arbitrated Avalon-MM master towards the shell's memory port (@ mem_clk_i)
   mem_write_o             : out   std_logic;
   mem_read_o              : out   std_logic;
   mem_address_o           : out   std_logic_vector(31 downto 0);
   mem_writedata_o         : out   std_logic_vector(15 downto 0);
   mem_byteenable_o        : out   std_logic_vector(1 downto 0);
   mem_burstcount_o        : out   std_logic_vector(7 downto 0);
   mem_readdata_i          : in    std_logic_vector(15 downto 0);
   mem_readdatavalid_i     : in    std_logic;
   mem_waitrequest_i       : in    std_logic;

   -- Encoded TMDS words towards the shell's OSERDES serialisers
   -- (@ hdmi_clk_i; channel i on bits 10*i+9 downto 10*i; audio rides
   -- inside the stream as data islands — no separate PCM boundary in v1)
   tmds_o                  : out   std_logic_vector(29 downto 0);

   -- Video clock preset request into the shell's video_out_clock DRP FSM
   -- (quasi-static; encoding per video_out_clock.vhd, e.g. "010" = 74.25 MHz)
   vclk_sel_o              : out   std_logic_vector(2 downto 0);

   -- Core-clock service (boundary v2): DRP write proxy.
   -- Democore RMs tie drp_req_o='0' and clkctl_o="00000000"
   -- so the shell boots with the hardcoded 54 MHz preset (v1-identical).
   drp_target_o            : out   std_logic_vector(2 downto 0);  -- 0=CORE_A, 1=CORE_B
   drp_addr_o              : out   std_logic_vector(6 downto 0);
   drp_data_o              : out   std_logic_vector(15 downto 0);
   drp_mask_o              : out   std_logic_vector(15 downto 0);  -- 1=preserve-from-read
   drp_req_o               : out   std_logic;   -- toggle handshake
   drp_ack_i               : in    std_logic;   -- toggle handshake return (unused by democore)
   clkctl_o                : out   std_logic_vector(7 downto 0);  -- bit0:core_clk0 mux, bit1:core_clk1 mux, bit2:cascade, bit3:CORE_A rst, bit4:CORE_B rst, bit5:core_clk2 mux (v3)
   clkstat_i               : in    std_logic_vector(3 downto 0);  -- bit0:CORE_A locked, bit1:CORE_B locked, bit2:memory subsystem ready (v3, informational)
   core_clk0_i             : in    std_logic;   -- CLKOUT0 core clock (fractional-capable; democore ignores)
   core_clk0_rst_i         : in    std_logic;
   core_clk2_i             : in    std_logic;   -- CLKOUT2 core clock (integer; over-provisioned in v3, democore ignores)
   core_clk2_rst_i         : in    std_logic;

   -- QSPI flash pass-through (boundary v3): clock reaches the CCLK pad via
   -- the shell's STARTUPE2; data/CS are gated IOBUFs shell-side.
   -- Democore ties the port off (no flash access).
   qspi_clk_o              : out   std_logic;
   qspi_csn_o              : out   std_logic;
   qspi_d_i                : in    std_logic_vector(3 downto 0);
   qspi_d_o                : out   std_logic_vector(3 downto 0);
   qspi_d_oe_o             : out   std_logic_vector(3 downto 0);

   -- Status towards the shell (LEDs, watchdog)
   power_led_o             : out   std_logic;   -- active high; shell inverts for the board
   drive_led_o             : out   std_logic;
   rm_alive_o              : out   std_logic;   -- watchdog seed (DESIGN.md §4)

   -- Reserved, registered, tied off — partition pin count is frozen with
   -- the shell, so over-provision on day one (DESIGN.md §6)
   rsv_i                   : in    std_logic_vector(15 downto 0);
   rsv_o                   : out   std_logic_vector(15 downto 0)
);
end entity rm_top;

architecture synthesis of rm_top is

   -- clk_drp_master ROM index (democore reprograms CORE_A to 54 MHz at wake)
   signal rom_idx           : natural range 0 to C_DEMOCORE_CLK_ROWS - 1;

   -- DRP-done gate on the framework reset: the reprogram stops main_clk while
   -- CORE_A relocks; the framework (ascal + its DDR3 video buffer) must not be
   -- running a burst when that happens or the orphaned burst wedges the video
   -- path.  On a partial swap the shell's decouple fence covers this, but on a
   -- JTAG/cold boot there is no fence, so hold the framework in reset until the
   -- DRP has finished and the MMCM is locked.
   signal drp_done          : std_logic;
   signal fw_reset_m2m_n    : std_logic;
   signal fw_reset_core_n   : std_logic;

   -- encoded TMDS words from the framework (flattened onto tmds_o)
   signal fw_tmds           : slv_9_0_t(0 to 2);

   -- core video towards the framework
   signal video_red_fw      : std_logic_vector(7 downto 0);
   signal video_green_fw    : std_logic_vector(7 downto 0);
   signal video_blue_fw     : std_logic_vector(7 downto 0);

   -- keyboard
   signal kb_porta_col_n    : std_logic_vector(7 downto 0);
   signal kb_portb_charge   : std_logic;

   --------------------------------------------------------------------------------------------
   -- main_clk (MiSTer core's clock)
   ---------------------------------------------------------------------------------------------

   -- QNICE control and status register
   signal main_qnice_reset       : std_logic;
   signal main_qnice_pause       : std_logic;

   signal main_reset_m2m         : std_logic;
   signal main_reset_core        : std_logic;

   -- keyboard handling (incl. drive led)
   signal main_key_num           : integer range 0 to 79;
   signal main_key_pressed_n     : std_logic;
   signal main_power_led         : std_logic;
   signal main_power_led_col     : std_logic_vector(23 downto 0);
   signal main_drive_led         : std_logic;
   signal main_drive_led_col     : std_logic_vector(23 downto 0);

   -- QNICE On Screen Menu selections
   signal main_osm_control_m     : std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   signal main_qnice_gp_reg      : std_logic_vector(255 downto 0);

   -- signed audio from the core
   signal main_audio_l           : signed(15 downto 0);
   signal main_audio_r           : signed(15 downto 0);

   -- Video output from Core
   signal video_clk              : std_logic;
   signal video_rst              : std_logic;
   signal video_ce               : std_logic;
   signal video_ce_ovl           : std_logic;
   signal video_red              : std_logic_vector(7 downto 0);
   signal video_green            : std_logic_vector(7 downto 0);
   signal video_blue             : std_logic_vector(7 downto 0);
   signal video_vs               : std_logic;
   signal video_hs               : std_logic;
   signal video_hblank           : std_logic;
   signal video_vblank           : std_logic;

   -- Joysticks
   signal main_joy1_up_n_in      : std_logic;
   signal main_joy1_down_n_in    : std_logic;
   signal main_joy1_left_n_in    : std_logic;
   signal main_joy1_right_n_in   : std_logic;
   signal main_joy1_fire_n_in    : std_logic;

   signal main_joy1_up_n_out     : std_logic;
   signal main_joy1_down_n_out   : std_logic;
   signal main_joy1_left_n_out   : std_logic;
   signal main_joy1_right_n_out  : std_logic;
   signal main_joy1_fire_n_out   : std_logic;

   signal main_joy2_up_n_in      : std_logic;
   signal main_joy2_down_n_in    : std_logic;
   signal main_joy2_left_n_in    : std_logic;
   signal main_joy2_right_n_in   : std_logic;
   signal main_joy2_fire_n_in    : std_logic;

   signal main_joy2_up_n_out     : std_logic;
   signal main_joy2_down_n_out   : std_logic;
   signal main_joy2_left_n_out   : std_logic;
   signal main_joy2_right_n_out  : std_logic;
   signal main_joy2_fire_n_out   : std_logic;

   signal main_pot1_x            : std_logic_vector(7 downto 0);
   signal main_pot1_y            : std_logic_vector(7 downto 0);
   signal main_pot2_x            : std_logic_vector(7 downto 0);
   signal main_pot2_y            : std_logic_vector(7 downto 0);
   signal main_rtc               : std_logic_vector(64 downto 0);

   ---------------------------------------------------------------------------------------------
   -- hr_clk domain (external RAM behind the shell's Avalon port)
   ---------------------------------------------------------------------------------------------

   signal hr_core_write          : std_logic;
   signal hr_core_read           : std_logic;
   signal hr_core_address        : std_logic_vector(31 downto 0);
   signal hr_core_writedata      : std_logic_vector(15 downto 0);
   signal hr_core_byteenable     : std_logic_vector(1 downto 0);
   signal hr_core_burstcount     : std_logic_vector(7 downto 0);
   signal hr_core_readdata       : std_logic_vector(15 downto 0);
   signal hr_core_readdatavalid  : std_logic;
   signal hr_core_waitrequest    : std_logic;
   signal hr_low                 : std_logic;
   signal hr_high                : std_logic;

   ---------------------------------------------------------------------------------------------
   -- qnice_clk
   ---------------------------------------------------------------------------------------------

   -- Video and audio mode control
   signal qnice_dvi              : std_logic;
   signal qnice_video_mode       : video_mode_type;
   signal qnice_scandoubler      : std_logic;
   signal qnice_csync            : std_logic;
   signal qnice_audio_mute       : std_logic;
   signal qnice_audio_filter     : std_logic;
   signal qnice_zoom_crop        : std_logic;
   signal qnice_ascal_mode       : std_logic_vector(1 downto 0);
   signal qnice_ascal_polyphase  : std_logic;
   signal qnice_ascal_triplebuf  : std_logic;
   signal qnice_retro15kHz       : std_logic;
   signal qnice_osm_cfg_scaling  : std_logic_vector(8 downto 0);

   -- flip joystick ports
   signal qnice_flip_joyports    : std_logic;

   -- QNICE On Screen Menu selections
   signal qnice_osm_control_m    : std_logic_vector(255 downto 0);

   -- QNICE general purpose register
   signal qnice_gp_reg           : std_logic_vector(255 downto 0);

   -- QNICE MMIO 4k-segmented access to RAMs, ROMs and similarily behaving devices
   signal qnice_ramrom_dev       : std_logic_vector(15 downto 0);
   signal qnice_ramrom_addr      : std_logic_vector(27 downto 0);
   signal qnice_ramrom_data_out  : std_logic_vector(15 downto 0);
   signal qnice_ramrom_data_in   : std_logic_vector(15 downto 0);
   signal qnice_ramrom_ce        : std_logic;
   signal qnice_ramrom_we        : std_logic;
   signal qnice_ramrom_wait      : std_logic;

begin

   kb_porta_col_n_o  <= kb_porta_col_n;
   kb_portb_charge_o <= kb_portb_charge;

   power_led_o <= main_power_led;
   drive_led_o <= main_drive_led;

   -- Watchdog seed: a live RM drives 1; the shell's decoupler forces 0
   -- while the RP is dark (real liveness logic can come later)
   rm_alive_o <= '1';
   rsv_o      <= (others => '0');

   -- QSPI flash unused by the democore: clock low, CS deasserted, bus released
   qspi_clk_o  <= '0';
   qspi_csn_o  <= '1';
   qspi_d_o    <= (others => '0');
   qspi_d_oe_o <= (others => '0');

   -- Boundary v2 core-clock service: like every well-behaved RM, democore
   -- reprograms CORE_A to its own frequency at wake rather than trusting the
   -- 54 MHz parking default — the previous RM (e.g. VIC20) may have left the
   -- MMCM at a different frequency, since DRP state persists across swaps.
   -- democore's preset happens to be 54 MHz on every output (its native
   -- clock), so this restores the parking state; the point is that it does so
   -- explicitly.  The FSM runs on sys_clk_i (shell-fixed); the shell's
   -- lock-based main_rst holds the core in reset until the MMCM relocks.
   i_clk_drp_master : entity work.clk_drp_master
      generic map (
         G_NUM_ROWS => C_DEMOCORE_CLK_ROWS
         -- defaults: reset/lock masks target CORE_A, clkctl run value 0
      )
      port map (
         clk_i        => sys_clk_i,
         rst_i        => not reset_shell_n_i,
         rom_idx_o    => rom_idx,
         rom_row_i    => democore_clk_row(rom_idx),
         drp_target_o => drp_target_o,
         drp_addr_o   => drp_addr_o,
         drp_data_o   => drp_data_o,
         drp_mask_o   => drp_mask_o,
         drp_req_o    => drp_req_o,
         drp_ack_i    => drp_ack_i,
         clkctl_o     => clkctl_o,
         clkstat_i    => clkstat_i,
         done_o       => drp_done
      ); -- i_clk_drp_master

   -- Hold the framework in reset until CORE_A has been reprogrammed + relocked
   fw_reset_m2m_n  <= reset_shell_n_i and drp_done;
   fw_reset_core_n <= reset_core_n_i and drp_done;

   -- DFX boundary v1: flatten the TMDS channels onto the partition pins
   tmds_o <= fw_tmds(2) & fw_tmds(1) & fw_tmds(0);

   -- No variant marker anymore: pass the CORE video straight through
   video_red_fw   <= video_red;
   video_green_fw <= video_green;
   video_blue_fw  <= video_blue;

   -----------------------------------------------------------------------------------------
   -- MiSTer2MEGA framework (RM-side library code)
   -----------------------------------------------------------------------------------------

   i_framework : entity work.framework_rm
   generic map (
      G_BOARD => "WUKONG"
   )
   port map (
      -- Clocks/resets from the shell
      clk_i                   => sys_clk_i,
      sys_pps_i               => sys_pps_i,
      reset_m2m_n_i           => fw_reset_m2m_n,
      reset_core_n_i          => fw_reset_core_n,
      qnice_clk_i             => loader_clk_i,
      qnice_rst_i             => loader_rst_i,
      hr_clk_i                => mem_clk_i,
      hr_rst_i                => mem_rst_i,
      audio_clk_i             => audio_clk_i,
      audio_rst_i             => audio_rst_i,
      hdmi_clk_i              => hdmi_clk_i,
      hdmi_rst_i              => hdmi_rst_i,

      uart_rxd_i              => uart_rx_i,
      uart_txd_o              => uart_tx_o,
      vga_red_o               => open,
      vga_green_o             => open,
      vga_blue_o              => open,
      vga_hs_o                => open,
      vga_vs_o                => open,
      vdac_clk_o              => open,
      vdac_sync_n_o           => open,
      vdac_blank_n_o          => open,
      tmds_o                  => fw_tmds,
      vclk_sel_o              => vclk_sel_o,
      kb_porta_col_n_o        => kb_porta_col_n,
      kb_portb_row_n_i        => kb_portb_row_n_i,
      kb_portb_charge_o       => kb_portb_charge,
      kb_restore_n_i          => kb_restore_n_i,
      -- The single Wukong SD slot maps to M2M's "external" slot, which has
      -- precedence in the firmware's auto mode; the internal slot reads "no card"
      sd_reset_o              => sd_reset_o,
      sd_clk_o                => sd_clk_o,
      sd_mosi_o               => sd_mosi_o,
      sd_miso_i               => sd_miso_i,
      sd_cd_i                 => '0',                -- low active: card present
      sd2_reset_o             => open,
      sd2_clk_o               => open,
      sd2_mosi_o              => open,
      sd2_miso_i              => '1',
      sd2_cd_i                => '1',                -- low active: no card
      joy_1_up_n_i            => joy_1_up_n_i,
      joy_1_down_n_i          => joy_1_down_n_i,
      joy_1_left_n_i          => joy_1_left_n_i,
      joy_1_right_n_i         => joy_1_right_n_i,
      joy_1_fire_n_i          => joy_1_fire_n_i,
      joy_1_up_n_o            => open,               -- joystick pins are input-only on the Wukong
      joy_1_down_n_o          => open,
      joy_1_left_n_o          => open,
      joy_1_right_n_o         => open,
      joy_1_fire_n_o          => open,
      joy_2_up_n_i            => joy_2_up_n_i,
      joy_2_down_n_i          => joy_2_down_n_i,
      joy_2_left_n_i          => joy_2_left_n_i,
      joy_2_right_n_i         => joy_2_right_n_i,
      joy_2_fire_n_i          => joy_2_fire_n_i,
      joy_2_up_n_o            => open,
      joy_2_down_n_o          => open,
      joy_2_left_n_o          => open,
      joy_2_right_n_o         => open,
      joy_2_fire_n_o          => open,
      paddle_i                => (others => '0'),    -- no paddles on the Wukong
      paddle_drain_o          => open,

      -- Arbitrated Avalon-MM master towards the shell's memory port
      mem_write_o             => mem_write_o,
      mem_read_o              => mem_read_o,
      mem_address_o           => mem_address_o,
      mem_writedata_o         => mem_writedata_o,
      mem_byteenable_o        => mem_byteenable_o,
      mem_burstcount_o        => mem_burstcount_o,
      mem_readdata_i          => mem_readdata_i,
      mem_readdatavalid_i     => mem_readdatavalid_i,
      mem_waitrequest_i       => mem_waitrequest_i,

      -- Connect to CORE
      main_clk_i              => core_clk1_i,
      main_rst_i              => core_clk1_rst_i,
      main_qnice_reset_o      => main_qnice_reset,
      main_qnice_pause_o      => main_qnice_pause,
      main_reset_m2m_o        => main_reset_m2m,
      main_reset_core_o       => main_reset_core,
      main_key_num_o          => main_key_num,
      main_key_pressed_n_o    => main_key_pressed_n,
      main_power_led_i        => main_power_led,
      main_power_led_col_i    => main_power_led_col,
      main_drive_led_i        => main_drive_led,
      main_drive_led_col_i    => main_drive_led_col,
      main_osm_control_m_o    => main_osm_control_m,
      main_qnice_gp_reg_o     => main_qnice_gp_reg,
      -- Audio is live in the RM build: hearing the democore test tone
      -- proves the PCM boundary path (mute is available in the OSM menu)
      main_audio_l_i          => main_audio_l,
      main_audio_r_i          => main_audio_r,
      video_clk_i             => video_clk,
      video_rst_i             => video_rst,
      video_ce_i              => video_ce,
      video_ce_ovl_i          => video_ce_ovl,
      video_red_i             => video_red_fw,
      video_green_i           => video_green_fw,
      video_blue_i            => video_blue_fw,
      video_vs_i              => video_vs,
      video_hs_i              => video_hs,
      video_hblank_i          => video_hblank,
      video_vblank_i          => video_vblank,
      main_joy1_up_n_o        => main_joy1_up_n_in,
      main_joy1_down_n_o      => main_joy1_down_n_in,
      main_joy1_left_n_o      => main_joy1_left_n_in,
      main_joy1_right_n_o     => main_joy1_right_n_in,
      main_joy1_fire_n_o      => main_joy1_fire_n_in,
      main_joy1_up_n_i        => main_joy1_up_n_out,
      main_joy1_down_n_i      => main_joy1_down_n_out,
      main_joy1_left_n_i      => main_joy1_left_n_out,
      main_joy1_right_n_i     => main_joy1_right_n_out,
      main_joy1_fire_n_i      => main_joy1_fire_n_out,
      main_joy2_up_n_o        => main_joy2_up_n_in,
      main_joy2_down_n_o      => main_joy2_down_n_in,
      main_joy2_left_n_o      => main_joy2_left_n_in,
      main_joy2_right_n_o     => main_joy2_right_n_in,
      main_joy2_fire_n_o      => main_joy2_fire_n_in,
      main_joy2_up_n_i        => main_joy2_up_n_out,
      main_joy2_down_n_i      => main_joy2_down_n_out,
      main_joy2_left_n_i      => main_joy2_left_n_out,
      main_joy2_right_n_i     => main_joy2_right_n_out,
      main_joy2_fire_n_i      => main_joy2_fire_n_out,
      main_pot1_x_o           => main_pot1_x,
      main_pot1_y_o           => main_pot1_y,
      main_pot2_x_o           => main_pot2_x,
      main_pot2_y_o           => main_pot2_y,
      main_rtc_o              => main_rtc,

      -- Provide external memory to core (in hr_clk domain)
      hr_core_write_i         => hr_core_write,
      hr_core_read_i          => hr_core_read,
      hr_core_address_i       => hr_core_address,
      hr_core_writedata_i     => hr_core_writedata,
      hr_core_byteenable_i    => hr_core_byteenable,
      hr_core_burstcount_i    => hr_core_burstcount,
      hr_core_readdata_o      => hr_core_readdata,
      hr_core_readdatavalid_o => hr_core_readdatavalid,
      hr_core_waitrequest_o   => hr_core_waitrequest,
      hr_high_o               => hr_high,
      hr_low_o                => hr_low,

      -- Boundary v1: audio rides in the TMDS data islands (vga_to_hdmi is
      -- RM-side now) — no separate PCM boundary
      audio_clk_o             => open,
      audio_reset_o           => open,
      audio_left_o            => open,
      audio_right_o           => open,

      -- Connect to QNICE
      qnice_dvi_i             => qnice_dvi,
      qnice_video_mode_i      => qnice_video_mode,
      qnice_scandoubler_i     => qnice_scandoubler,
      qnice_csync_i           => qnice_csync,
      qnice_audio_mute_i      => qnice_audio_mute,
      qnice_audio_filter_i    => qnice_audio_filter,
      qnice_zoom_crop_i       => qnice_zoom_crop,
      qnice_osm_cfg_scaling_i => qnice_osm_cfg_scaling,
      qnice_retro15kHz_i      => qnice_retro15kHz,
      qnice_ascal_mode_i      => qnice_ascal_mode,
      qnice_ascal_polyphase_i => qnice_ascal_polyphase,
      qnice_ascal_triplebuf_i => qnice_ascal_triplebuf,
      qnice_flip_joyports_i   => qnice_flip_joyports,
      qnice_osm_control_m_o   => qnice_osm_control_m,
      qnice_gp_reg_o          => qnice_gp_reg,
      qnice_ramrom_dev_o      => qnice_ramrom_dev,
      qnice_ramrom_addr_o     => qnice_ramrom_addr,
      qnice_ramrom_data_out_o => qnice_ramrom_data_out,
      qnice_ramrom_data_in_i  => qnice_ramrom_data_in,
      qnice_ramrom_ce_o       => qnice_ramrom_ce,
      qnice_ramrom_we_o       => qnice_ramrom_we,
      qnice_ramrom_wait_i     => qnice_ramrom_wait
   ); -- i_framework


   ---------------------------------------------------------------------------------------------------------------
   -- MEGA65 Core including the MiSTer core: Multiple clock domains
   -- (mega65_rm.vhd variant: no clk MMCM, main_clk/main_rst come from the shell)
   ---------------------------------------------------------------------------------------------------------------

   CORE : entity work.MEGA65_Core
      generic map (
         G_BOARD => "WUKONG"
      )
      port map (
         main_clk_i              => core_clk1_i,
         main_rst_i              => core_clk1_rst_i,

         --------------------------------------------------------------------------------------------------------
         -- QNICE Clock Domain
         --------------------------------------------------------------------------------------------------------

         qnice_clk_i             => loader_clk_i,
         qnice_rst_i             => loader_rst_i,

         -- Video and audio mode control
         qnice_dvi_o             => qnice_dvi,
         qnice_video_mode_o      => qnice_video_mode,
         qnice_scandoubler_o     => qnice_scandoubler,
         qnice_csync_o           => qnice_csync,
         qnice_audio_mute_o      => qnice_audio_mute,
         qnice_audio_filter_o    => qnice_audio_filter,
         qnice_zoom_crop_o       => qnice_zoom_crop,
         qnice_ascal_mode_o      => qnice_ascal_mode,
         qnice_ascal_polyphase_o => qnice_ascal_polyphase,
         qnice_ascal_triplebuf_o => qnice_ascal_triplebuf,
         qnice_retro15kHz_o      => qnice_retro15kHz,
         qnice_osm_cfg_scaling_o => qnice_osm_cfg_scaling,

         -- Flip joystick ports
         qnice_flip_joyports_o   => qnice_flip_joyports,

         -- On-Screen-Menu selections (in QNICE clock domain)
         qnice_osm_control_i     => qnice_osm_control_m,

         -- QNICE general purpose register
         qnice_gp_reg_i          => qnice_gp_reg,

         -- Core-specific devices
         qnice_dev_id_i          => qnice_ramrom_dev,
         qnice_dev_addr_i        => qnice_ramrom_addr,
         qnice_dev_data_i        => qnice_ramrom_data_out,
         qnice_dev_data_o        => qnice_ramrom_data_in,
         qnice_dev_ce_i          => qnice_ramrom_ce,
         qnice_dev_we_i          => qnice_ramrom_we,
         qnice_dev_wait_o        => qnice_ramrom_wait,

         --------------------------------------------------------------------------------------------------------
         -- Core Clock Domain
         --------------------------------------------------------------------------------------------------------

         main_reset_m2m_i        => main_reset_m2m  or main_qnice_reset or core_clk1_rst_i,
         main_reset_core_i       => main_reset_core or main_qnice_reset,
         main_pause_core_i       => main_qnice_pause,

         main_osm_control_i      => main_osm_control_m,
         main_qnice_gp_reg_i     => main_qnice_gp_reg,

         -- Video output
         video_clk_o             => video_clk,
         video_rst_o             => video_rst,
         video_ce_o              => video_ce,
         video_ce_ovl_o          => video_ce_ovl,
         video_red_o             => video_red,
         video_green_o           => video_green,
         video_blue_o            => video_blue,
         video_vs_o              => video_vs,
         video_hs_o              => video_hs,
         video_hblank_o          => video_hblank,
         video_vblank_o          => video_vblank,

         -- Audio output (Signed PCM)
         main_audio_left_o       => main_audio_l,
         main_audio_right_o      => main_audio_r,

         -- M2M Keyboard interface
         main_kb_key_num_i       => main_key_num,
         main_kb_key_pressed_n_i => main_key_pressed_n,
         main_power_led_o        => main_power_led,
         main_power_led_col_o    => main_power_led_col,
         main_drive_led_o        => main_drive_led,
         main_drive_led_col_o    => main_drive_led_col,

         -- Joysticks input
         main_joy_1_up_n_i       => main_joy1_up_n_in,
         main_joy_1_down_n_i     => main_joy1_down_n_in,
         main_joy_1_left_n_i     => main_joy1_left_n_in,
         main_joy_1_right_n_i    => main_joy1_right_n_in,
         main_joy_1_fire_n_i     => main_joy1_fire_n_in,
         main_joy_1_up_n_o       => main_joy1_up_n_out,
         main_joy_1_down_n_o     => main_joy1_down_n_out,
         main_joy_1_left_n_o     => main_joy1_left_n_out,
         main_joy_1_right_n_o    => main_joy1_right_n_out,
         main_joy_1_fire_n_o     => main_joy1_fire_n_out,

         main_joy_2_up_n_i       => main_joy2_up_n_in,
         main_joy_2_down_n_i     => main_joy2_down_n_in,
         main_joy_2_left_n_i     => main_joy2_left_n_in,
         main_joy_2_right_n_i    => main_joy2_right_n_in,
         main_joy_2_fire_n_i     => main_joy2_fire_n_in,
         main_joy_2_up_n_o       => main_joy2_up_n_out,
         main_joy_2_down_n_o     => main_joy2_down_n_out,
         main_joy_2_left_n_o     => main_joy2_left_n_out,
         main_joy_2_right_n_o    => main_joy2_right_n_out,
         main_joy_2_fire_n_o     => main_joy2_fire_n_out,

         main_pot1_x_i           => main_pot1_x,
         main_pot1_y_i           => main_pot1_y,
         main_pot2_x_i           => main_pot2_x,
         main_pot2_y_i           => main_pot2_y,
         main_rtc_i              => main_rtc,

         --------------------------------------------------------------------------------------------------------
         -- Provide support for external memory (Avalon Memory Map)
         --------------------------------------------------------------------------------------------------------

         hr_clk_i                => mem_clk_i,
         hr_rst_i                => mem_rst_i,
         hr_core_write_o         => hr_core_write,
         hr_core_read_o          => hr_core_read,
         hr_core_address_o       => hr_core_address,
         hr_core_writedata_o     => hr_core_writedata,
         hr_core_byteenable_o    => hr_core_byteenable,
         hr_core_burstcount_o    => hr_core_burstcount,
         hr_core_readdata_i      => hr_core_readdata,
         hr_core_readdatavalid_i => hr_core_readdatavalid,
         hr_core_waitrequest_i   => hr_core_waitrequest,
         hr_high_i               => hr_high,
         hr_low_i                => hr_low,

         --------------------------------------------------------------------
         -- Ports that have no counterpart on the Wukong: IEC, Expansion Port
         --------------------------------------------------------------------

         iec_reset_n_o           => open,
         iec_atn_n_o             => open,
         iec_clk_en_o            => open,
         iec_clk_n_i             => '1',
         iec_clk_n_o             => open,
         iec_data_en_o           => open,
         iec_data_n_i            => '1',
         iec_data_n_o            => open,
         iec_srq_en_o            => open,
         iec_srq_n_i             => '1',
         iec_srq_n_o             => open,

         cart_en_o               => open,
         cart_phi2_o             => open,
         cart_dotclock_o         => open,
         cart_dma_i              => '1',
         cart_reset_oe_o         => open,
         cart_reset_i            => '1',
         cart_reset_o            => open,
         cart_game_oe_o          => open,
         cart_game_i             => '1',
         cart_game_o             => open,
         cart_exrom_oe_o         => open,
         cart_exrom_i            => '1',
         cart_exrom_o            => open,
         cart_nmi_oe_o           => open,
         cart_nmi_i              => '1',
         cart_nmi_o              => open,
         cart_irq_oe_o           => open,
         cart_irq_i              => '1',
         cart_irq_o              => open,
         cart_roml_oe_o          => open,
         cart_roml_i             => '1',
         cart_roml_o             => open,
         cart_romh_oe_o          => open,
         cart_romh_i             => '1',
         cart_romh_o             => open,
         cart_ctrl_oe_o          => open,
         cart_ba_i               => '1',
         cart_rw_i               => '1',
         cart_io1_i              => '1',
         cart_io2_i              => '1',
         cart_ba_o               => open,
         cart_rw_o               => open,
         cart_io1_o              => open,
         cart_io2_o              => open,
         cart_data_oe_o          => open,
         cart_d_i                => (others => '1'),
         cart_d_o                => open,
         cart_addr_oe_o          => open,
         cart_a_i                => (others => '1'),
         cart_a_o                => open
      ); -- CORE

end architecture synthesis;
