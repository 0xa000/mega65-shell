----------------------------------------------------------------------------------
-- MiSTer2MEGA65 — DFX reconfigurable module top for the MEGA65 R6
--
-- This entity IS the reconfigurable partition: its ports are the partition
-- pins of the shell/RM boundary defined in m65-shell-poc/docs/BOUNDARY-R6.md
-- (the Wukong boundary v2 services plus the R6 peripheral set including IEC
-- and the full cartridge port). Inside: framework_rm (the M2M framework as
-- RM-side library code, incl. m2m_keyb and the vga_to_hdmi TMDS encoder)
-- plus the CORE (democore variant without its clk MMCM). Everything the
-- shell owns — pins, IOBUFs, clock generation, reset manager, HyperRAM
-- controller, OSERDES serialisers, audio DAC driver, ICAP loader — is on
-- the other side of these ports.
--
-- Port rules (DESIGN.md tier model): everything here is either a shell-
-- generated clock, a latency-insensitive bus, or a slow raw signal; the
-- shell registers/decouples its side of every RM output.
--
-- Wiring of framework<->CORE is identical to top_mega65-r6.vhd — diff
-- against it to review.
--
-- DFX carve-out done by 0xa000 in 2026, based on top_mega65-r6.vhd,
-- licensed under GPL v3
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.types_pkg.all;
use work.video_modes_pkg.all;
use work.democore_clk_pkg.all;

entity rm_top_r6 is
generic (
   -- Catalog variant marker: invert the CORE video between core and
   -- framework, so config A and config B are visually distinguishable
   -- during swap testing
   G_INVERT_VIDEO : boolean := false
);
port (
   -- Clocks and resets from the static shell (all BUFG-driven shell-side;
   -- 7-series DFX: no MMCM/PLL/BUFG inside a reconfigurable partition)
   sys_clk_i               : in    std_logic;   -- 100 MHz system clock
   sys_pps_i               : in    std_logic;   -- one pulse per second
   reset_shell_n_i         : in    std_logic;   -- from the shell's reset manager
   reset_core_n_i          : in    std_logic;
   loader_clk_i            : in    std_logic;   -- 50 MHz
   loader_rst_i            : in    std_logic;
   core_clk0_i             : in    std_logic;   -- CLKOUT0 core clock (fractional-capable; democore ignores)
   core_clk0_rst_i         : in    std_logic;
   core_clk1_i             : in    std_logic;   -- CLKOUT1 core clock (integer; 54 MHz for democore)
   core_clk1_rst_i         : in    std_logic;
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

   mem_clk_i               : in    std_logic;   -- 100 MHz = shell's HyperRAM/Avalon domain
   mem_rst_i               : in    std_logic;
   audio_clk_i             : in    std_logic;   -- 12.288 MHz
   audio_rst_i             : in    std_logic;
   hdmi_clk_i              : in    std_logic;   -- HDMI pixel clock (shell MMCM; follows vclk_sel_o)
   hdmi_rst_i              : in    std_logic;

   -- Serial communication (tier 0 passthrough)
   uart_rx_i               : in    std_logic;
   uart_tx_o               : out   std_logic;

   -- MEGA65 smart keyboard (kio serial protocol; m2m_keyb is RM-side, the
   -- shell parks the lines while the RP is dark)
   kb_io0_o                : out   std_logic;   -- clock to keyboard
   kb_io1_o                : out   std_logic;   -- data output to keyboard
   kb_io2_i                : in    std_logic;   -- data input from keyboard

   -- Micro SD Connector (external slot at back of the cover)
   sd_reset_o              : out   std_logic;
   sd_clk_o                : out   std_logic;
   sd_mosi_o               : out   std_logic;
   sd_miso_i               : in    std_logic;
   sd_cd_i                 : in    std_logic;
   sd_d1_i                 : in    std_logic;   -- unused by the framework; in the ABI for future RMs
   sd_d2_i                 : in    std_logic;

   -- SD Connector (this is the slot at the bottom side of the case under the cover)
   sd2_reset_o             : out   std_logic;
   sd2_clk_o               : out   std_logic;
   sd2_mosi_o              : out   std_logic;
   sd2_miso_i              : in    std_logic;
   sd2_cd_i                : in    std_logic;
   sd2_wp_i                : in    std_logic;   -- unused by the framework; in the ABI for future RMs
   sd2_d1_i                : in    std_logic;
   sd2_d2_i                : in    std_logic;

   -- Joysticks and Paddles (outputs are open-collector requests: '0' =
   -- drive pin low, '1' = leave floating; the shell owns the pin logic)
   joy_1_up_n_i            : in    std_logic;
   joy_1_down_n_i          : in    std_logic;
   joy_1_left_n_i          : in    std_logic;
   joy_1_right_n_i         : in    std_logic;
   joy_1_fire_n_i          : in    std_logic;
   joy_1_up_n_o            : out   std_logic;
   joy_1_down_n_o          : out   std_logic;
   joy_1_left_n_o          : out   std_logic;
   joy_1_right_n_o         : out   std_logic;
   joy_1_fire_n_o          : out   std_logic;

   joy_2_up_n_i            : in    std_logic;
   joy_2_down_n_i          : in    std_logic;
   joy_2_left_n_i          : in    std_logic;
   joy_2_right_n_i         : in    std_logic;
   joy_2_fire_n_i          : in    std_logic;
   joy_2_up_n_o            : out   std_logic;
   joy_2_down_n_o          : out   std_logic;
   joy_2_left_n_o          : out   std_logic;
   joy_2_right_n_o         : out   std_logic;
   joy_2_fire_n_o          : out   std_logic;

   paddle_i                : in    std_logic_vector(3 downto 0);
   paddle_drain_o          : out   std_logic;

   -- VGA via the shell's VDAC pins (video clock domain is RM-internal;
   -- vdac_clk_o is plain fabric forwarding of it, no ODDR upstream either)
   vga_red_o               : out   std_logic_vector(7 downto 0);
   vga_green_o             : out   std_logic_vector(7 downto 0);
   vga_blue_o              : out   std_logic_vector(7 downto 0);
   vga_hs_o                : out   std_logic;
   vga_vs_o                : out   std_logic;
   vdac_clk_o              : out   std_logic;
   vdac_sync_n_o           : out   std_logic;
   vdac_blank_n_o          : out   std_logic;

   -- Processed PCM towards the shell's audio DAC driver (@ audio_clk_i;
   -- filtered/muted by the RM's av pipeline, shell parks at silence)
   audio_left_o            : out   signed(15 downto 0);
   audio_right_o           : out   signed(15 downto 0);

   -- HDMI hot-plug detect (unused by the framework; in the ABI for future RMs)
   hdmi_hpd_i              : in    std_logic;

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
   -- inside the stream as data islands)
   tmds_o                  : out   std_logic_vector(29 downto 0);

   -- Video clock preset request into the shell's video_out_clock DRP FSM
   -- (quasi-static; encoding per video_out_clock.vhd, e.g. "010" = 74.25 MHz)
   vclk_sel_o              : out   std_logic_vector(2 downto 0);

   -- Core-clock service (boundary v2): DRP write proxy
   drp_target_o            : out   std_logic_vector(2 downto 0);  -- 0=CORE_A, 1=CORE_B
   drp_addr_o              : out   std_logic_vector(6 downto 0);
   drp_data_o              : out   std_logic_vector(15 downto 0);
   drp_mask_o              : out   std_logic_vector(15 downto 0);  -- 1=preserve-from-read
   drp_req_o               : out   std_logic;   -- toggle handshake
   drp_ack_i               : in    std_logic;   -- toggle handshake return
   clkctl_o                : out   std_logic_vector(7 downto 0);  -- bit0:core_clk0 mux, bit1:core_clk1 mux, bit2:cascade, bit3:CORE_A rst, bit4:CORE_B rst
   clkstat_i               : in    std_logic_vector(3 downto 0);  -- bit0:CORE_A locked, bit1:CORE_B locked

   -- I2C buses as logical in/out pairs; the open-collector tri-states are
   -- shell-side IOBs, released while the RP is dark
   fpga_scl_in_i           : in    std_logic;   -- on-board EEPROMs + RTC
   fpga_scl_out_o          : out   std_logic;
   fpga_sda_in_i           : in    std_logic;
   fpga_sda_out_o          : out   std_logic;
   grove_scl_in_i          : in    std_logic;   -- J18
   grove_scl_out_o         : out   std_logic;
   grove_sda_in_i          : in    std_logic;
   grove_sda_out_o         : out   std_logic;
   i2c_scl_in_i            : in    std_logic;   -- I/O expander + DC/DC converters
   i2c_scl_out_o           : out   std_logic;
   i2c_sda_in_i            : in    std_logic;
   i2c_sda_out_o           : out   std_logic;
   hdmi_scl_in_i           : in    std_logic;   -- U10 PTN3363
   hdmi_scl_out_o          : out   std_logic;
   hdmi_sda_in_i           : in    std_logic;
   hdmi_sda_out_o          : out   std_logic;
   vga_scl_in_i            : in    std_logic;   -- VGA DDC
   vga_scl_out_o           : out   std_logic;
   vga_sda_in_i            : in    std_logic;
   vga_sda_out_o           : out   std_logic;
   audio_scl_in_i          : in    std_logic;   -- U37 AK4432
   audio_scl_out_o         : out   std_logic;
   audio_sda_in_i          : in    std_logic;
   audio_sda_out_o         : out   std_logic;

   -- CBM-488/IEC serial port, logical signals per the MEGA65_Core ABI
   -- (enables active HIGH here; the shell inverts to the pins' _en_n_o and
   -- parks everything disabled)
   iec_reset_n_o           : out   std_logic;
   iec_atn_n_o             : out   std_logic;
   iec_clk_en_o            : out   std_logic;
   iec_clk_n_i             : in    std_logic;
   iec_clk_n_o             : out   std_logic;
   iec_data_en_o           : out   std_logic;
   iec_data_n_i            : in    std_logic;
   iec_data_n_o            : out   std_logic;
   iec_srq_en_o            : out   std_logic;
   iec_srq_n_i             : in    std_logic;
   iec_srq_n_o             : out   std_logic;

   -- C64 Expansion Port (aka Cartridge Port), logical oe/in/out triples per
   -- the MEGA65_Core ABI; the shell owns the IOBUFs, the level-shifter
   -- enable/direction pin logic and the dark-parking
   cart_en_o               : out   std_logic;   -- enable port, active high
   cart_phi2_o             : out   std_logic;
   cart_dotclock_o         : out   std_logic;
   cart_dma_i              : in    std_logic;
   cart_reset_oe_o         : out   std_logic;
   cart_reset_i            : in    std_logic;
   cart_reset_o            : out   std_logic;
   cart_game_oe_o          : out   std_logic;
   cart_game_i             : in    std_logic;
   cart_game_o             : out   std_logic;
   cart_exrom_oe_o         : out   std_logic;
   cart_exrom_i            : in    std_logic;
   cart_exrom_o            : out   std_logic;
   cart_nmi_oe_o           : out   std_logic;
   cart_nmi_i              : in    std_logic;
   cart_nmi_o              : out   std_logic;
   cart_irq_oe_o           : out   std_logic;
   cart_irq_i              : in    std_logic;
   cart_irq_o              : out   std_logic;
   cart_roml_oe_o          : out   std_logic;
   cart_roml_i             : in    std_logic;
   cart_roml_o             : out   std_logic;
   cart_romh_oe_o          : out   std_logic;
   cart_romh_i             : in    std_logic;
   cart_romh_o             : out   std_logic;
   cart_ctrl_oe_o          : out   std_logic;   -- 0: tristate (input), 1: output
   cart_ba_i               : in    std_logic;
   cart_rw_i               : in    std_logic;
   cart_io1_i              : in    std_logic;
   cart_io2_i              : in    std_logic;
   cart_ba_o               : out   std_logic;
   cart_rw_o               : out   std_logic;
   cart_io1_o              : out   std_logic;
   cart_io2_o              : out   std_logic;
   cart_data_oe_o          : out   std_logic;   -- 0: tristate (input), 1: output
   cart_d_i                : in    unsigned(7 downto 0);
   cart_d_o                : out   unsigned(7 downto 0);
   cart_addr_oe_o          : out   std_logic;   -- 0: tristate (input), 1: output
   cart_a_i                : in    unsigned(15 downto 0);
   cart_a_o                : out   unsigned(15 downto 0);

   -- Status towards the shell (mainboard LEDs, watchdog); the keyboard's
   -- own power/drive LEDs are driven RM-side through kb_io by m2m_keyb
   power_led_o             : out   std_logic;   -- active high; shell maps to the green mainboard LED
   drive_led_o             : out   std_logic;   -- active high; shell maps to the red mainboard LED
   rm_alive_o              : out   std_logic;   -- watchdog seed (DESIGN.md §4)

   -- Reserved, registered, tied off — partition pin count is frozen with
   -- the shell, so over-provision on day one (DESIGN.md §6)
   rsv_i                   : in    std_logic_vector(15 downto 0);
   rsv_o                   : out   std_logic_vector(15 downto 0)
);
end entity rm_top_r6;

architecture synthesis of rm_top_r6 is

   -- clk_drp_master ROM index (democore reprograms CORE_A to 54 MHz at wake)
   signal rom_idx           : natural range 0 to C_DEMOCORE_CLK_ROWS - 1;

   -- DRP-done gate on the framework reset: the reprogram stops main_clk while
   -- CORE_A relocks; the framework (ascal + its HyperRAM video buffer) must
   -- not be running a burst when that happens or the orphaned burst wedges
   -- the video path.  On a partial swap the shell's decouple fence covers
   -- this, but on a JTAG/cold boot there is no fence, so hold the framework
   -- in reset until the DRP has finished and the MMCM is locked.
   signal drp_done          : std_logic;
   signal fw_reset_m2m_n    : std_logic;
   signal fw_reset_core_n   : std_logic;

   -- encoded TMDS words from the framework (flattened onto tmds_o)
   signal fw_tmds           : slv_9_0_t(0 to 2);

   -- core video towards the framework (variant marker XOR)
   signal video_red_fw      : std_logic_vector(7 downto 0);
   signal video_green_fw    : std_logic_vector(7 downto 0);
   signal video_blue_fw     : std_logic_vector(7 downto 0);

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
   -- 54 MHz parking default — the previous RM may have left the MMCM at a
   -- different frequency, since DRP state persists across swaps.  democore's
   -- preset happens to be 54 MHz on every output (its native clock), so this
   -- restores the parking state; the point is that it does so explicitly.
   -- The FSM runs on sys_clk_i (shell-fixed); the shell's lock-based
   -- main_rst holds the core in reset until the MMCM relocks.
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

   -- Flatten the TMDS channels onto the partition pins
   tmds_o <= fw_tmds(2) & fw_tmds(1) & fw_tmds(0);

   -- Catalog variant marker (config B): invert the CORE video
   gen_invert : if G_INVERT_VIDEO generate
      video_red_fw   <= not video_red;
      video_green_fw <= not video_green;
      video_blue_fw  <= not video_blue;
   else generate
      video_red_fw   <= video_red;
      video_green_fw <= video_green;
      video_blue_fw  <= video_blue;
   end generate gen_invert;

   -----------------------------------------------------------------------------------------
   -- MiSTer2MEGA framework (RM-side library code)
   -----------------------------------------------------------------------------------------

   i_framework : entity work.framework_rm
   generic map (
      G_BOARD => "MEGA65_R6"
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
      vga_red_o               => vga_red_o,
      vga_green_o             => vga_green_o,
      vga_blue_o              => vga_blue_o,
      vga_hs_o                => vga_hs_o,
      vga_vs_o                => vga_vs_o,
      vdac_clk_o              => vdac_clk_o,
      vdac_sync_n_o           => vdac_sync_n_o,
      vdac_blank_n_o          => vdac_blank_n_o,
      tmds_o                  => fw_tmds,
      vclk_sel_o              => vclk_sel_o,
      kb_io0_o                => kb_io0_o,
      kb_io1_o                => kb_io1_o,
      kb_io2_i                => kb_io2_i,
      sd_reset_o              => sd_reset_o,
      sd_clk_o                => sd_clk_o,
      sd_mosi_o               => sd_mosi_o,
      sd_miso_i               => sd_miso_i,
      sd_cd_i                 => sd_cd_i,
      sd2_reset_o             => sd2_reset_o,
      sd2_clk_o               => sd2_clk_o,
      sd2_mosi_o              => sd2_mosi_o,
      sd2_miso_i              => sd2_miso_i,
      sd2_cd_i                => sd2_cd_i,
      joy_1_up_n_i            => joy_1_up_n_i,
      joy_1_down_n_i          => joy_1_down_n_i,
      joy_1_left_n_i          => joy_1_left_n_i,
      joy_1_right_n_i         => joy_1_right_n_i,
      joy_1_fire_n_i          => joy_1_fire_n_i,
      joy_1_up_n_o            => joy_1_up_n_o,
      joy_1_down_n_o          => joy_1_down_n_o,
      joy_1_left_n_o          => joy_1_left_n_o,
      joy_1_right_n_o         => joy_1_right_n_o,
      joy_1_fire_n_o          => joy_1_fire_n_o,
      joy_2_up_n_i            => joy_2_up_n_i,
      joy_2_down_n_i          => joy_2_down_n_i,
      joy_2_left_n_i          => joy_2_left_n_i,
      joy_2_right_n_i         => joy_2_right_n_i,
      joy_2_fire_n_i          => joy_2_fire_n_i,
      joy_2_up_n_o            => joy_2_up_n_o,
      joy_2_down_n_o          => joy_2_down_n_o,
      joy_2_left_n_o          => joy_2_left_n_o,
      joy_2_right_n_o         => joy_2_right_n_o,
      joy_2_fire_n_o          => joy_2_fire_n_o,
      paddle_i                => paddle_i,
      paddle_drain_o          => paddle_drain_o,

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

      -- Audio: processed PCM towards the shell's DAC driver (audio_clk_i
      -- domain is shared with the shell, so the clock outputs stay unused)
      audio_clk_o             => open,
      audio_reset_o           => open,
      audio_left_o            => audio_left_o,
      audio_right_o           => audio_right_o,

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
      qnice_ramrom_wait_i     => qnice_ramrom_wait,

      hdmi_scl_in_i           => hdmi_scl_in_i,
      hdmi_scl_out_o          => hdmi_scl_out_o,
      hdmi_sda_in_i           => hdmi_sda_in_i,
      hdmi_sda_out_o          => hdmi_sda_out_o,
      vga_scl_in_i            => vga_scl_in_i,
      vga_scl_out_o           => vga_scl_out_o,
      vga_sda_in_i            => vga_sda_in_i,
      vga_sda_out_o           => vga_sda_out_o,
      audio_scl_in_i          => audio_scl_in_i,
      audio_scl_out_o         => audio_scl_out_o,
      audio_sda_in_i          => audio_sda_in_i,
      audio_sda_out_o         => audio_sda_out_o,
      i2c_scl_in_i            => i2c_scl_in_i,
      i2c_scl_out_o           => i2c_scl_out_o,
      i2c_sda_in_i            => i2c_sda_in_i,
      i2c_sda_out_o           => i2c_sda_out_o,
      fpga_scl_in_i           => fpga_scl_in_i,
      fpga_scl_out_o          => fpga_scl_out_o,
      fpga_sda_in_i           => fpga_sda_in_i,
      fpga_sda_out_o          => fpga_sda_out_o,
      grove_scl_in_i          => grove_scl_in_i,
      grove_scl_out_o         => grove_scl_out_o,
      grove_sda_in_i          => grove_sda_in_i,
      grove_sda_out_o         => grove_sda_out_o
   ); -- i_framework


   ---------------------------------------------------------------------------------------------------------------
   -- MEGA65 Core including the MiSTer core: Multiple clock domains
   -- (mega65_rm.vhd variant: no clk MMCM, main_clk/main_rst come from the shell)
   ---------------------------------------------------------------------------------------------------------------

   CORE : entity work.MEGA65_Core
      generic map (
         G_BOARD => "MEGA65_R6"
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
         -- C64 specific ports: IEC and the Expansion Port cross the DFX
         -- boundary as logical signals; the shell owns the pins
         --------------------------------------------------------------------

         iec_reset_n_o           => iec_reset_n_o,
         iec_atn_n_o             => iec_atn_n_o,
         iec_clk_en_o            => iec_clk_en_o,
         iec_clk_n_i             => iec_clk_n_i,
         iec_clk_n_o             => iec_clk_n_o,
         iec_data_en_o           => iec_data_en_o,
         iec_data_n_i            => iec_data_n_i,
         iec_data_n_o            => iec_data_n_o,
         iec_srq_en_o            => iec_srq_en_o,
         iec_srq_n_i             => iec_srq_n_i,
         iec_srq_n_o             => iec_srq_n_o,

         cart_en_o               => cart_en_o,
         cart_phi2_o             => cart_phi2_o,
         cart_dotclock_o         => cart_dotclock_o,
         cart_dma_i              => cart_dma_i,
         cart_reset_oe_o         => cart_reset_oe_o,
         cart_reset_i            => cart_reset_i,
         cart_reset_o            => cart_reset_o,
         cart_game_oe_o          => cart_game_oe_o,
         cart_game_i             => cart_game_i,
         cart_game_o             => cart_game_o,
         cart_exrom_oe_o         => cart_exrom_oe_o,
         cart_exrom_i            => cart_exrom_i,
         cart_exrom_o            => cart_exrom_o,
         cart_nmi_oe_o           => cart_nmi_oe_o,
         cart_nmi_i              => cart_nmi_i,
         cart_nmi_o              => cart_nmi_o,
         cart_irq_oe_o           => cart_irq_oe_o,
         cart_irq_i              => cart_irq_i,
         cart_irq_o              => cart_irq_o,
         cart_roml_oe_o          => cart_roml_oe_o,
         cart_roml_i             => cart_roml_i,
         cart_roml_o             => cart_roml_o,
         cart_romh_oe_o          => cart_romh_oe_o,
         cart_romh_i             => cart_romh_i,
         cart_romh_o             => cart_romh_o,
         cart_ctrl_oe_o          => cart_ctrl_oe_o,
         cart_ba_i               => cart_ba_i,
         cart_rw_i               => cart_rw_i,
         cart_io1_i              => cart_io1_i,
         cart_io2_i              => cart_io2_i,
         cart_ba_o               => cart_ba_o,
         cart_rw_o               => cart_rw_o,
         cart_io1_o              => cart_io1_o,
         cart_io2_o              => cart_io2_o,
         cart_data_oe_o          => cart_data_oe_o,
         cart_d_i                => cart_d_i,
         cart_d_o                => cart_d_o,
         cart_addr_oe_o          => cart_addr_oe_o,
         cart_a_i                => cart_a_i,
         cart_a_o                => cart_a_o
      ); -- CORE

end architecture synthesis;
