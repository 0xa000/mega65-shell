-- SPDX-License-Identifier: GPL-3.0-only
-- Shell top by 0xa000; pin-handling/peripheral-driver portions derived from
-- the MiSTer2MEGA65 R6 board top (GPLv3, sy2002 & MJoergen) -- see ATTRIBUTION.md.
----------------------------------------------------------------------------------
-- Thin shell — static design top for the MEGA65 R6 (DFX carve-out)
--
-- Owns everything a reconfigurable module cannot or should not:
--   * all pins/IOBUFs and all clock generation (shell_clk_base loader/audio/mem,
--     video_out_clock following the RM's vclk_sel preset request,
--     shell_core_clk dual-MMCM service + DRP proxy — boundary v2)
--   * the reset manager
--   * the HyperRAM controller behind ONE Avalon-MM slave (the RM brings its
--     own arbiter) — RAM content survives RM swaps (the IS66WVH8M8 keeps
--     self-refreshing; hr_reset_o only asserts on the reset button)
--   * ONLY the OSERDES serialisers of the HDMI back end: the TMDS encoder,
--     InfoFrames and audio data islands are RM-side; the shell generates no
--     video and parks the TMDS lanes at a control symbol while the RP is
--     dark (sync loss on swap is accepted — LEDs indicate loading)
--   * the audio DAC driver (i_audio, AK4432); the boundary carries
--     processed PCM, parked at silence while the RP is dark
--   * the sync-word-gated UART -> ICAP loader (verified in m65-shell-poc
--     stage A1), which drives decouple/rm_reset; it runs on loader_clk
--     (50 MHz) and latches the ICAP O-port status per attempt (round 5)
--   * decoupling: every RM output is gated/muxed to a safe value while the
--     RP is dark; the Avalon fence completes an in-flight write burst with
--     shell-injected dummy beats (never wait for the decoupled side)
--
-- The RM (rm_top_r6) is a black box here; the DFX flow links its
-- synthesized checkpoint into the reconfigurable partition. Boundary:
-- docs/ (R6 board annex).
--
-- Note on the MEGA65's LEDs: the power/drive LEDs sit on the keyboard and
-- are driven RM-side through the kb_io serial protocol, so there is no
-- user-visible load indicator on a closed case while the RP is dark; the
-- shell mirrors the RM's power/drive LEDs onto the mainboard green/red
-- LEDs and blinks the red one with loader progress during a swap; after
-- a swap attempt the red LED shows the ICAP verdict (solid = engine
-- never synced, slow blink = synced but error, fast blink = accepted).
--
-- DFX carve-out done by 0xa000 in 2026, based on top_mega65-r6.vhd.
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.types_pkg.all;

library xpm;
use xpm.vcomponents.all;

library unisim;
use unisim.vcomponents.all;

entity shell_top_r6 is
port (
   -- Onboard crystal oscillator = 100 MHz
   clk_i                   : in    std_logic;

   -- Reset button on the side of the machine
   reset_button_i          : in    std_logic;      -- Active high

   -- USB-RS232 Interface
   uart_rxd_i              : in    std_logic;
   uart_txd_o              : out   std_logic;

   -- VGA via VDAC. U3 = ADV7125BCPZ170
   vga_red_o               : out   std_logic_vector(7 downto 0);
   vga_green_o             : out   std_logic_vector(7 downto 0);
   vga_blue_o              : out   std_logic_vector(7 downto 0);
   vga_hs_o                : out   std_logic;
   vga_vs_o                : out   std_logic;
   vga_scl_io              : inout std_logic;
   vga_sda_io              : inout std_logic;
   vdac_clk_o              : out   std_logic;
   vdac_sync_n_o           : out   std_logic;
   vdac_blank_n_o          : out   std_logic;
   vdac_psave_n_o          : out   std_logic;

   -- HDMI. U10 = PTN3363BSMP
   tmds_data_p_o           : out   std_logic_vector(2 downto 0);
   tmds_data_n_o           : out   std_logic_vector(2 downto 0);
   tmds_clk_p_o            : out   std_logic;
   tmds_clk_n_o            : out   std_logic;
   hdmi_hiz_en_o           : out   std_logic;   -- Connect to U10.HIZ_EN
   hdmi_ls_oe_n_o          : out   std_logic;   -- Connect to U10.OE#
   hdmi_hpd_i              : in    std_logic;   -- Connect to U10.HPD_SOURCE
   hdmi_scl_io             : inout std_logic;   -- Connect to U10.SCL_SOURCE
   hdmi_sda_io             : inout std_logic;   -- Connect to U10.SDA_SOURCE

   -- MEGA65 smart keyboard controller
   kb_io0_o                : out   std_logic;                 -- clock to keyboard
   kb_io1_o                : out   std_logic;                 -- data output to keyboard
   kb_io2_i                : in    std_logic;                 -- data input from keyboard
   kb_tck_o                : out   std_logic;
   kb_tdo_i                : in    std_logic;
   kb_tms_o                : out   std_logic;
   kb_tdi_o                : out   std_logic;
   kb_jtagen_o             : out   std_logic;

   -- Micro SD Connector (external slot at back of the cover)
   sd_reset_o              : out   std_logic;
   sd_clk_o                : out   std_logic;
   sd_mosi_o               : out   std_logic;
   sd_miso_i               : in    std_logic;
   sd_cd_i                 : in    std_logic;
   sd_d1_i                 : in    std_logic;
   sd_d2_i                 : in    std_logic;

   -- SD Connector (this is the slot at the bottom side of the case under the cover)
   sd2_reset_o             : out   std_logic;
   sd2_clk_o               : out   std_logic;
   sd2_mosi_o              : out   std_logic;
   sd2_miso_i              : in    std_logic;
   sd2_cd_i                : in    std_logic;
   sd2_wp_i                : in    std_logic;
   sd2_d1_i                : in    std_logic;
   sd2_d2_i                : in    std_logic;

   -- Audio DAC. U37 = AK4432VT
   audio_mclk_o            : out   std_logic;   -- Master Clock Input Pin,       12.288 MHz
   audio_bick_o            : out   std_logic;   -- Audio Serial Data Clock Pin,   3.072 MHz
   audio_sdti_o            : out   std_logic;   -- Audio Serial Data Input Pin,  16-bit LSB justified
   audio_lrclk_o           : out   std_logic;   -- Input Channel Clock Pin,      48.0 kHz
   audio_pdn_n_o           : out   std_logic;   -- Power-Down & Reset Pin
   audio_i2cfil_o          : out   std_logic;   -- I2C Interface Mode Select Pin
   audio_scl_io            : inout std_logic;   -- Control Data Clock Input Pin
   audio_sda_io            : inout std_logic;   -- Control Data Input/Output Pin

   -- Joysticks and Paddles
   fa_up_n_i               : in    std_logic;
   fa_down_n_i             : in    std_logic;
   fa_left_n_i             : in    std_logic;
   fa_right_n_i            : in    std_logic;
   fa_fire_n_i             : in    std_logic;
   fa_fire_n_o             : out   std_logic;   -- 0: Drive pin low (output). 1: Leave pin floating (input)
   fa_up_n_o               : out   std_logic;
   fa_left_n_o             : out   std_logic;
   fa_down_n_o             : out   std_logic;
   fa_right_n_o            : out   std_logic;
   fb_up_n_i               : in    std_logic;
   fb_down_n_i             : in    std_logic;
   fb_left_n_i             : in    std_logic;
   fb_right_n_i            : in    std_logic;
   fb_fire_n_i             : in    std_logic;
   fb_up_n_o               : out   std_logic;
   fb_down_n_o             : out   std_logic;
   fb_fire_n_o             : out   std_logic;
   fb_right_n_o            : out   std_logic;
   fb_left_n_o             : out   std_logic;

   -- Joystick power supply
   joystick_5v_disable_o   : out   std_logic;  -- 1: Disable 5V power supply to joysticks
   joystick_5v_powergood_i : in    std_logic;

   paddle_i                : in    std_logic_vector(3 downto 0);
   paddle_drain_o          : out   std_logic;

   -- HyperRAM. U29 = IS66WVH8M8DBLL-100B1LI
   hr_d_io                 : inout std_logic_vector(7 downto 0);
   hr_rwds_io              : inout std_logic;
   hr_reset_o              : out   std_logic;
   hr_clk_p_o              : out   std_logic;
   hr_cs0_o                : out   std_logic;

   -- CBM-488/IEC serial port
   iec_reset_n_o           : out   std_logic;
   iec_atn_n_o             : out   std_logic;
   iec_clk_en_n_o          : out   std_logic;
   iec_clk_n_i             : in    std_logic;
   iec_clk_n_o             : out   std_logic;
   iec_data_en_n_o         : out   std_logic;
   iec_data_n_i            : in    std_logic;
   iec_data_n_o            : out   std_logic;
   iec_srq_en_n_o          : out   std_logic;
   iec_srq_n_i             : in    std_logic;
   iec_srq_n_o             : out   std_logic;

   -- C64 Expansion Port (aka Cartridge Port)
   cart_phi2_o             : out   std_logic;
   cart_dotclock_o         : out   std_logic;
   cart_dma_i              : in    std_logic;
   cart_reset_oe_n_o       : out   std_logic;
   cart_reset_io           : inout std_logic;
   cart_game_oe_n_o        : out   std_logic;
   cart_game_io            : inout std_logic;
   cart_exrom_oe_n_o       : out   std_logic;
   cart_exrom_io           : inout std_logic;
   cart_nmi_oe_n_o         : out   std_logic;
   cart_nmi_io             : inout std_logic;
   cart_irq_oe_n_o         : out   std_logic;
   cart_irq_io             : inout std_logic;
   cart_ctrl_en_o          : out   std_logic;
   cart_ctrl_dir_o         : out   std_logic;                  -- =1 means FPGA->Port, =0 means Port->FPGA
   cart_ba_io              : inout std_logic;
   cart_rw_io              : inout std_logic;
   cart_io1_io             : inout std_logic;
   cart_io2_io             : inout std_logic;
   cart_romh_oe_n_o        : out   std_logic;
   cart_romh_io            : inout std_logic;
   cart_roml_oe_n_o        : out   std_logic;
   cart_roml_io            : inout std_logic;
   cart_en_o               : out   std_logic;
   cart_addr_en_o          : out   std_logic;
   cart_haddr_dir_o        : out   std_logic;                  -- =1 means FPGA->Port, =0 means Port->FPGA
   cart_laddr_dir_o        : out   std_logic;                  -- =1 means FPGA->Port, =0 means Port->FPGA
   cart_a_io               : inout unsigned(15 downto 0);
   cart_data_en_o          : out   std_logic;
   cart_data_dir_o         : out   std_logic;                  -- =1 means FPGA->Port, =0 means Port->FPGA
   cart_d_io               : inout unsigned(7 downto 0);

   -- The remaining ports are not supported (parked static)

   -- SMSC Ethernet PHY. U4 = KSZ8081RNDCA
   eth_clock_o             : out   std_logic;
   eth_led2_o              : out   std_logic;
   eth_mdc_o               : out   std_logic;
   eth_mdio_io             : inout std_logic;
   eth_reset_o             : out   std_logic;
   eth_rxd_i               : in    std_logic_vector(1 downto 0);
   eth_rxdv_i              : in    std_logic;
   eth_rxer_i              : in    std_logic;
   eth_txd_o               : out   std_logic_vector(1 downto 0);
   eth_txen_o              : out   std_logic;

   -- FDC interface
   f_density_o             : out   std_logic;
   f_diskchanged_i         : in    std_logic;
   f_index_i               : in    std_logic;
   f_motora_o              : out   std_logic;
   f_motorb_o              : out   std_logic;
   f_rdata_i               : in    std_logic;
   f_selecta_o             : out   std_logic;
   f_selectb_o             : out   std_logic;
   f_side1_o               : out   std_logic;
   f_stepdir_o             : out   std_logic;
   f_step_o                : out   std_logic;
   f_track0_i              : in    std_logic;
   f_wdata_o               : out   std_logic;
   f_wgate_o               : out   std_logic;
   f_writeprotect_i        : in    std_logic;

   -- I2C bus for on-board peripherals
   -- U36. 24AA025E48T. Address 0x50. 2K Serial EEPROM.
   -- U38. RV-3032-C7.  Address 0x51. Real-Time Clock Module.
   -- U39. 24LC128.     Address 0x56. 128K CMOS Serial EEPROM.
   fpga_sda_io             : inout std_logic;
   fpga_scl_io             : inout std_logic;

   -- Connected to J18
   grove_sda_io            : inout std_logic;
   grove_scl_io            : inout std_logic;

   -- On board LEDs
   led_g_n_o               : out   std_logic;
   led_r_n_o               : out   std_logic;
   led_o                   : out   std_logic;

   -- Pmod Header
   p1lo_io                 : inout std_logic_vector(3 downto 0);
   p1hi_io                 : inout std_logic_vector(3 downto 0);
   p2lo_io                 : inout std_logic_vector(3 downto 0);
   p2hi_io                 : inout std_logic_vector(3 downto 0);
   pmod1_en_o              : out   std_logic;
   pmod1_flag_i            : in    std_logic;
   pmod2_en_o              : out   std_logic;
   pmod2_flag_i            : in    std_logic;

   -- Quad SPI Flash. U5 = S25FL512SAGBHIS10
   qspidb_io               : inout std_logic_vector(3 downto 0);
   qspicsn_o               : out   std_logic;

   -- I2C bus
   -- U32 = PCA9655EMTTXG. Address 0x40. I/O expander.
   -- U12 = MP8869SGL-Z.   Address 0x61. DC/DC Converter.
   -- U14 = MP8869SGL-Z.   Address 0x67. DC/DC Converter.
   i2c_scl_io              : inout std_logic;
   i2c_sda_io              : inout std_logic;

   -- Debug.
   dbg_io_11               : inout std_logic;

   -- SDRAM - 32M x 16 bit, 3.3V VCC. U44 = IS42S16320F-6BL
   sdram_clk_o             : out   std_logic;
   sdram_cke_o             : out   std_logic;
   sdram_ras_n_o           : out   std_logic;
   sdram_cas_n_o           : out   std_logic;
   sdram_we_n_o            : out   std_logic;
   sdram_cs_n_o            : out   std_logic;
   sdram_ba_o              : out   std_logic_vector(1 downto 0);
   sdram_a_o               : out   std_logic_vector(12 downto 0);
   sdram_dqml_o            : out   std_logic;
   sdram_dqmh_o            : out   std_logic;
   sdram_dq_io             : inout std_logic_vector(15 downto 0)
);
end entity shell_top_r6;

architecture synthesis of shell_top_r6 is

   -- The reconfigurable module: black box in the static synthesis, linked
   -- from its own synthesis checkpoint by the DFX flow. Port list must
   -- match the RM framework's rm_top_r6 exactly (the G_INVERT_VIDEO
   -- generic is an RM-synthesis concern and does not appear here).
   component rm_top_r6 is
   port (
      sys_clk_i               : in    std_logic;
      sys_pps_i               : in    std_logic;
      reset_shell_n_i           : in    std_logic;
      reset_core_n_i          : in    std_logic;
      loader_clk_i             : in    std_logic;
      loader_rst_i             : in    std_logic;
      core_clk0_i             : in    std_logic;
      core_clk0_rst_i         : in    std_logic;
      core_clk1_i             : in    std_logic;
      core_clk1_rst_i         : in    std_logic;
      core_clk2_i             : in    std_logic;
      core_clk2_rst_i         : in    std_logic;
      qspi_clk_o              : out   std_logic;
      qspi_csn_o              : out   std_logic;
      qspi_d_i                : in    std_logic_vector(3 downto 0);
      qspi_d_o                : out   std_logic_vector(3 downto 0);
      qspi_d_oe_o             : out   std_logic_vector(3 downto 0);
      mem_clk_i                : in    std_logic;
      mem_rst_i                : in    std_logic;
      audio_clk_i             : in    std_logic;
      audio_rst_i             : in    std_logic;
      hdmi_clk_i              : in    std_logic;
      hdmi_rst_i              : in    std_logic;
      uart_rx_i               : in    std_logic;
      uart_tx_o               : out   std_logic;
      kb_io0_o                : out   std_logic;
      kb_io1_o                : out   std_logic;
      kb_io2_i                : in    std_logic;
      sd_reset_o              : out   std_logic;
      sd_clk_o                : out   std_logic;
      sd_mosi_o               : out   std_logic;
      sd_miso_i               : in    std_logic;
      sd_cd_i                 : in    std_logic;
      sd_d1_i                 : in    std_logic;
      sd_d2_i                 : in    std_logic;
      sd2_reset_o             : out   std_logic;
      sd2_clk_o               : out   std_logic;
      sd2_mosi_o              : out   std_logic;
      sd2_miso_i              : in    std_logic;
      sd2_cd_i                : in    std_logic;
      sd2_wp_i                : in    std_logic;
      sd2_d1_i                : in    std_logic;
      sd2_d2_i                : in    std_logic;
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
      vga_red_o               : out   std_logic_vector(7 downto 0);
      vga_green_o             : out   std_logic_vector(7 downto 0);
      vga_blue_o              : out   std_logic_vector(7 downto 0);
      vga_hs_o                : out   std_logic;
      vga_vs_o                : out   std_logic;
      vdac_clk_o              : out   std_logic;
      vdac_sync_n_o           : out   std_logic;
      vdac_blank_n_o          : out   std_logic;
      audio_left_o            : out   signed(15 downto 0);
      audio_right_o           : out   signed(15 downto 0);
      hdmi_hpd_i              : in    std_logic;
      mem_write_o             : out   std_logic;
      mem_read_o              : out   std_logic;
      mem_address_o           : out   std_logic_vector(31 downto 0);
      mem_writedata_o         : out   std_logic_vector(15 downto 0);
      mem_byteenable_o        : out   std_logic_vector(1 downto 0);
      mem_burstcount_o        : out   std_logic_vector(7 downto 0);
      mem_readdata_i          : in    std_logic_vector(15 downto 0);
      mem_readdatavalid_i     : in    std_logic;
      mem_waitrequest_i       : in    std_logic;
      tmds_o                  : out   std_logic_vector(29 downto 0);
      vclk_sel_o              : out   std_logic_vector(2 downto 0);
      drp_target_o            : out   std_logic_vector(2 downto 0);
      drp_addr_o              : out   std_logic_vector(6 downto 0);
      drp_data_o              : out   std_logic_vector(15 downto 0);
      drp_mask_o              : out   std_logic_vector(15 downto 0);
      drp_req_o               : out   std_logic;
      drp_ack_i               : in    std_logic;
      clkctl_o                : out   std_logic_vector(7 downto 0);
      clkstat_i               : in    std_logic_vector(3 downto 0);
      fpga_scl_in_i           : in    std_logic;
      fpga_scl_out_o          : out   std_logic;
      fpga_sda_in_i           : in    std_logic;
      fpga_sda_out_o          : out   std_logic;
      grove_scl_in_i          : in    std_logic;
      grove_scl_out_o         : out   std_logic;
      grove_sda_in_i          : in    std_logic;
      grove_sda_out_o         : out   std_logic;
      i2c_scl_in_i            : in    std_logic;
      i2c_scl_out_o           : out   std_logic;
      i2c_sda_in_i            : in    std_logic;
      i2c_sda_out_o           : out   std_logic;
      hdmi_scl_in_i           : in    std_logic;
      hdmi_scl_out_o          : out   std_logic;
      hdmi_sda_in_i           : in    std_logic;
      hdmi_sda_out_o          : out   std_logic;
      vga_scl_in_i            : in    std_logic;
      vga_scl_out_o           : out   std_logic;
      vga_sda_in_i            : in    std_logic;
      vga_sda_out_o           : out   std_logic;
      audio_scl_in_i          : in    std_logic;
      audio_scl_out_o         : out   std_logic;
      audio_sda_in_i          : in    std_logic;
      audio_sda_out_o         : out   std_logic;
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
      cart_en_o               : out   std_logic;
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
      cart_ctrl_oe_o          : out   std_logic;
      cart_ba_i               : in    std_logic;
      cart_rw_i               : in    std_logic;
      cart_io1_i              : in    std_logic;
      cart_io2_i              : in    std_logic;
      cart_ba_o               : out   std_logic;
      cart_rw_o               : out   std_logic;
      cart_io1_o              : out   std_logic;
      cart_io2_o              : out   std_logic;
      cart_data_oe_o          : out   std_logic;
      cart_d_i                : in    unsigned(7 downto 0);
      cart_d_o                : out   unsigned(7 downto 0);
      cart_addr_oe_o          : out   std_logic;
      cart_a_i                : in    unsigned(15 downto 0);
      cart_a_o                : out   unsigned(15 downto 0);
      power_led_o             : out   std_logic;
      drive_led_o             : out   std_logic;
      rm_alive_o              : out   std_logic;
      rsv_i                   : in    std_logic_vector(15 downto 0);
      rsv_o                   : out   std_logic_vector(15 downto 0)
   );
   end component rm_top_r6;

   -- Video clock preset service: default preset the shell boots with and
   -- holds while the RP is dark ("010" = 74.25 MHz, 720p)
   constant C_VCLK_SEL_DEFAULT : std_logic_vector(2 downto 0) := "010";

   -- TMDS control-period symbol for {C1,C0} = 00: what the serialisers
   -- emit while the RP is dark (electrically clean, DC-balanced; the
   -- monitor sees sync loss and mutes — that is accepted)
   constant C_TMDS_CTL0 : std_logic_vector(9 downto 0) := "1101010100";

   ---------------------------------------------------------------------------
   -- Clocks and resets
   ---------------------------------------------------------------------------

   signal clk_100         : std_logic;
   signal reset_shell_n     : std_logic;
   signal reset_core_n    : std_logic;
   signal sys_pps         : std_logic;

   signal loader_clk       : std_logic;
   signal loader_rst       : std_logic;
   signal audio_clk       : std_logic;
   signal audio_rst       : std_logic;
   signal hdmi_clk        : std_logic;
   signal hdmi_rst        : std_logic;
   signal tmds_clk        : std_logic;
   signal core_clk0       : std_logic;    -- CLKOUT0 core clock (fractional-capable)
   signal core_clk0_rst   : std_logic;
   signal core_clk1       : std_logic;    -- CLKOUT1 core clock (integer; 54 MHz parking default)
   signal core_clk1_rst   : std_logic;
   signal core_clk2       : std_logic;    -- CLKOUT2 core clock (integer; over-provisioned, v3)
   signal core_clk2_rst   : std_logic;
   signal mem_clk          : std_logic;
   signal mem_clk_del      : std_logic;
   signal mem_delay_refclk : std_logic;
   signal mem_rst          : std_logic;

   ---------------------------------------------------------------------------
   -- Loader / decoupling
   ---------------------------------------------------------------------------

   signal loader_byte        : std_logic_vector(7 downto 0);
   signal loader_byte_valid  : std_logic;
   signal decouple           : std_logic;   -- loader domain (loader_clk)
   signal rm_reset           : std_logic;   -- loader domain (loader_clk)
   signal loader_status      : std_logic_vector(1 downto 0);
   signal loader_progress    : unsigned(19 downto 0);

   -- ICAP config-engine evidence latches (loader domain) and the verdict
   -- blink they drive on the red LED after a load attempt
   signal icap_attempt       : std_logic;
   signal icap_dalign        : std_logic;
   signal icap_cfgerr        : std_logic;
   signal icap_abort         : std_logic;
   signal verdict_cnt        : unsigned(25 downto 0) := (others => '0');
   signal led_verdict        : std_logic;

   signal decouple_sys       : std_logic;
   signal rm_reset_sys       : std_logic;
   signal decouple_mem        : std_logic;
   signal decouple_hdmi      : std_logic;
   signal decouple_audio     : std_logic;
   signal rm_rst_loader       : std_logic;
   signal rm_rst_core0       : std_logic;
   signal rm_rst_core1       : std_logic;
   signal rm_rst_core2       : std_logic;
   signal rm_rst_mem          : std_logic;
   signal rm_rst_audio       : std_logic;
   signal rm_rst_hdmi        : std_logic;

   -- QSPI flash pass-through (boundary v3): raw RM outputs
   signal rm_qspi_clk        : std_logic;
   signal rm_qspi_csn        : std_logic;
   signal rm_qspi_d          : std_logic_vector(3 downto 0);
   signal rm_qspi_d_oe       : std_logic_vector(3 downto 0);

   -- Memory-ready (boundary v3): the HyperRAM controller exposes no init-
   -- done signal, so the shell holds mem_ready low for 2^17 mem_clk cycles
   -- (~1.3 ms) after hr reset release — comfortably past the controller's
   -- config-register writes and IDELAY calibration.
   signal mem_ready_cnt      : unsigned(16 downto 0) := (others => '0');
   signal mem_ready          : std_logic := '0';
   signal mem_ready_sys      : std_logic;
   signal mem_stall          : std_logic;

   ---------------------------------------------------------------------------
   -- RM boundary signals (raw = as driven by the RM; use gated versions!)
   ---------------------------------------------------------------------------

   signal rm_uart_tx         : std_logic;
   signal rm_kb_io0          : std_logic;
   signal rm_kb_io1          : std_logic;
   signal rm_sd_reset        : std_logic;
   signal rm_sd_clk          : std_logic;
   signal rm_sd_mosi         : std_logic;
   signal rm_sd2_reset       : std_logic;
   signal rm_sd2_clk         : std_logic;
   signal rm_sd2_mosi        : std_logic;

   signal rm_joy1_up_n       : std_logic;
   signal rm_joy1_down_n     : std_logic;
   signal rm_joy1_left_n     : std_logic;
   signal rm_joy1_right_n    : std_logic;
   signal rm_joy1_fire_n     : std_logic;
   signal rm_joy2_up_n       : std_logic;
   signal rm_joy2_down_n     : std_logic;
   signal rm_joy2_left_n     : std_logic;
   signal rm_joy2_right_n    : std_logic;
   signal rm_joy2_fire_n     : std_logic;
   signal rm_paddle_drain    : std_logic;

   signal rm_vga_red         : std_logic_vector(7 downto 0);
   signal rm_vga_green       : std_logic_vector(7 downto 0);
   signal rm_vga_blue        : std_logic_vector(7 downto 0);
   signal rm_vga_hs          : std_logic;
   signal rm_vga_vs          : std_logic;
   signal rm_vdac_clk        : std_logic;
   signal rm_vdac_sync_n     : std_logic;
   signal rm_vdac_blank_n    : std_logic;

   signal rm_audio_left      : signed(15 downto 0);
   signal rm_audio_right     : signed(15 downto 0);
   signal audio_left         : signed(15 downto 0);   -- parked at silence while dark
   signal audio_right        : signed(15 downto 0);

   signal rm_mem_write       : std_logic;
   signal rm_mem_read        : std_logic;
   signal rm_mem_address     : std_logic_vector(31 downto 0);
   signal rm_mem_writedata   : std_logic_vector(15 downto 0);
   signal rm_mem_byteenable  : std_logic_vector(1 downto 0);
   signal rm_mem_burstcount  : std_logic_vector(7 downto 0);

   signal rm_tmds            : std_logic_vector(29 downto 0);
   signal rm_vclk_sel        : std_logic_vector(2 downto 0);

   -- Core-clock service (boundary v2): raw RM outputs
   signal rm_drp_target      : std_logic_vector(2 downto 0);
   signal rm_drp_addr        : std_logic_vector(6 downto 0);
   signal rm_drp_data        : std_logic_vector(15 downto 0);
   signal rm_drp_mask        : std_logic_vector(15 downto 0);
   signal rm_drp_req         : std_logic;
   signal rm_clkctl          : std_logic_vector(7 downto 0);

   -- I2C logical levels from the RM (the pin tri-states are below)
   signal rm_fpga_scl        : std_logic;
   signal rm_fpga_sda        : std_logic;
   signal rm_grove_scl       : std_logic;
   signal rm_grove_sda       : std_logic;
   signal rm_i2c_scl         : std_logic;
   signal rm_i2c_sda         : std_logic;
   signal rm_hdmi_scl        : std_logic;
   signal rm_hdmi_sda        : std_logic;
   signal rm_vga_scl         : std_logic;
   signal rm_vga_sda         : std_logic;
   signal rm_audio_scl       : std_logic;
   signal rm_audio_sda       : std_logic;

   -- IEC logical signals from the RM
   signal rm_iec_reset_n     : std_logic;
   signal rm_iec_atn_n       : std_logic;
   signal rm_iec_clk_en      : std_logic;
   signal rm_iec_clk_n       : std_logic;
   signal rm_iec_data_en     : std_logic;
   signal rm_iec_data_n      : std_logic;
   signal rm_iec_srq_en      : std_logic;
   signal rm_iec_srq_n       : std_logic;

   -- Cartridge port: raw RM outputs and gated versions (pin logic verbatim
   -- from top_mega65-r6.vhd, driven by the gated signals)
   signal rm_cart_en         : std_logic;
   signal rm_cart_phi2       : std_logic;
   signal rm_cart_dotclock   : std_logic;
   signal rm_cart_reset_oe   : std_logic;
   signal rm_cart_reset_out  : std_logic;
   signal rm_cart_game_oe    : std_logic;
   signal rm_cart_game_out   : std_logic;
   signal rm_cart_exrom_oe   : std_logic;
   signal rm_cart_exrom_out  : std_logic;
   signal rm_cart_nmi_oe     : std_logic;
   signal rm_cart_nmi_out    : std_logic;
   signal rm_cart_irq_oe     : std_logic;
   signal rm_cart_irq_out    : std_logic;
   signal rm_cart_roml_oe    : std_logic;
   signal rm_cart_roml_out   : std_logic;
   signal rm_cart_romh_oe    : std_logic;
   signal rm_cart_romh_out   : std_logic;
   signal rm_cart_ctrl_oe    : std_logic;
   signal rm_cart_ba_out     : std_logic;
   signal rm_cart_rw_out     : std_logic;
   signal rm_cart_io1_out    : std_logic;
   signal rm_cart_io2_out    : std_logic;
   signal rm_cart_data_oe    : std_logic;
   signal rm_cart_d_out      : unsigned(7 downto 0);
   signal rm_cart_addr_oe    : std_logic;
   signal rm_cart_a_out      : unsigned(15 downto 0);

   signal cart_en            : std_logic;   -- gated
   signal cart_reset_oe      : std_logic;   -- gated
   signal cart_game_oe       : std_logic;
   signal cart_exrom_oe      : std_logic;
   signal cart_nmi_oe        : std_logic;
   signal cart_irq_oe        : std_logic;
   signal cart_roml_oe       : std_logic;
   signal cart_romh_oe       : std_logic;
   signal cart_ctrl_oe       : std_logic;
   signal cart_data_oe       : std_logic;
   signal cart_addr_oe       : std_logic;

   signal cart_reset_in      : std_logic;
   signal cart_game_in       : std_logic;
   signal cart_exrom_in      : std_logic;
   signal cart_nmi_in        : std_logic;
   signal cart_irq_in        : std_logic;
   signal cart_roml_in       : std_logic;
   signal cart_romh_in       : std_logic;
   signal cart_ba_in         : std_logic;
   signal cart_rw_in         : std_logic;
   signal cart_io1_in        : std_logic;
   signal cart_io2_in        : std_logic;
   signal cart_a_in          : unsigned(15 downto 0);
   signal cart_d_in          : unsigned(7 downto 0);

   signal rm_power_led       : std_logic;
   signal rm_drive_led       : std_logic;
   signal rm_alive           : std_logic;

   ---------------------------------------------------------------------------
   -- Core-clock service (boundary v2): clkctl CDC + stability filter
   --
   -- clkctl_o from the RM is quasi-static (stability-filtered before use).
   -- Same 64-cycle filter as vclk_sel; freeze while RP is dark.
   -- Bit mapping: [5]=core_clk2 mux (v3),
   --              [0]=core_clk0 mux, [1]=core_clk1 mux, [2]=cascade_en,
   --              [3]=CORE_A rst, [4]=CORE_B rst, [5:7]=reserved
   ---------------------------------------------------------------------------

   constant C_CLKCTL_DEFAULT : std_logic_vector(7 downto 0) := (others => '0');

   signal clkctl_meta        : std_logic_vector(7 downto 0) := C_CLKCTL_DEFAULT;
   signal clkctl_candidate   : std_logic_vector(7 downto 0) := C_CLKCTL_DEFAULT;
   signal clkctl_stable_cnt  : unsigned(5 downto 0)         := (others => '0');
   signal clkctl_accepted    : std_logic_vector(7 downto 0) := C_CLKCTL_DEFAULT;

   -- DRP proxy ↔ shell_core_clk wires
   signal drp_ack            : std_logic;
   signal drp_active_a       : std_logic;
   signal drp_active_b       : std_logic;
   signal core_a_daddr       : std_logic_vector(6 downto 0);
   signal core_a_di          : std_logic_vector(15 downto 0);
   signal core_a_do          : std_logic_vector(15 downto 0);
   signal core_a_den         : std_logic;
   signal core_a_dwe         : std_logic;
   signal core_a_drdy        : std_logic;
   signal core_b_daddr       : std_logic_vector(6 downto 0);
   signal core_b_di          : std_logic_vector(15 downto 0);
   signal core_b_do          : std_logic_vector(15 downto 0);
   signal core_b_den         : std_logic;
   signal core_b_dwe         : std_logic;
   signal core_b_drdy        : std_logic;
   signal core_a_locked      : std_logic;
   signal core_b_locked      : std_logic;
   signal clkstat            : std_logic_vector(3 downto 0);

   ---------------------------------------------------------------------------
   -- Avalon fence (mem domain): pass RM requests, but on decouple complete
   -- the in-flight write burst before blocking
   ---------------------------------------------------------------------------

   signal avm_write          : std_logic;
   signal avm_read           : std_logic;
   signal avm_readdata       : std_logic_vector(15 downto 0);
   signal avm_readdatavalid  : std_logic;
   signal avm_waitrequest    : std_logic;
   signal wr_beats_left      : unsigned(7 downto 0) := (others => '0');
   signal fence_flush        : std_logic;
   signal avm_byteenable     : std_logic_vector(1 downto 0);

   -- HyperRAM physical layer
   signal hr_rwds_in         : std_logic;
   signal hr_rwds_out        : std_logic;
   signal hr_rwds_oe_n       : std_logic;
   signal hr_dq_in           : std_logic_vector(7 downto 0);
   signal hr_dq_out          : std_logic_vector(7 downto 0);
   signal hr_dq_oe_n         : std_logic_vector(7 downto 0);

   ---------------------------------------------------------------------------
   -- TMDS park mux (hdmi domain) + video clock preset filter (sys domain)
   ---------------------------------------------------------------------------

   signal hdmi_tmds          : slv_9_0_t(0 to 2);

   -- vclk_sel pipeline: CDC'd RM request -> stability filter -> accepted.
   -- The RM's request is quasi-static from an arbitrary clock domain; a
   -- 3-bit bus may tear during a change, so a candidate must be sampled
   -- identical for 64 consecutive clk_100 cycles before it is accepted.
   signal vclk_meta          : std_logic_vector(2 downto 0);
   signal vclk_candidate     : std_logic_vector(2 downto 0) := C_VCLK_SEL_DEFAULT;
   signal vclk_stable_cnt    : unsigned(5 downto 0) := (others => '0');
   signal vclk_sel_accepted  : std_logic_vector(2 downto 0) := C_VCLK_SEL_DEFAULT;

begin

   ---------------------------------------------------------------------------
   -- Clock generation (all MMCMs/PLLs live here, in the static)
   ---------------------------------------------------------------------------

   -- The R6 crystal is already 100 MHz: clk_i is the sys/DRP clock and
   -- the CLKIN of all shell MMCMs. The BUFG is load-bearing: without it
   -- the whole sys domain hangs off the IBUF net through general routing
   -- (fo>600 local clock, several ns of skew). The ICAP loader no longer
   -- lives here: since round 5 it runs on loader_clk (50 MHz) — see the
   -- loader section.
   i_bufg_clk100 : BUFG
      port map (
         I => clk_i,
         O => clk_100
      ); -- i_bufg_clk100

   i_reset_manager : entity work.reset_manager
      generic map (
         BOARD_CLK_SPEED => 100_000_000
      )
      port map (
         CLK            => clk_100,
         RESET_N        => not reset_button_i,
         reset_shell_n_o  => reset_shell_n,
         reset_core_n_o => reset_core_n
      ); -- i_reset_manager

   i_shell_clk_base : entity work.shell_clk_base
      port map (
         sys_clk_i         => clk_100,
         sys_rstn_i        => reset_shell_n,        -- reset everything
         core_rstn_i       => reset_core_n,       -- reset only the core (resets the HyperRAM, too — stock semantics)
         loader_clk_o       => loader_clk,
         loader_rst_o       => loader_rst,
         mem_clk_o          => mem_clk,
         mem_clk_del_o      => mem_clk_del,
         mem_delay_refclk_o => mem_delay_refclk,
         mem_rst_o          => mem_rst,
         audio_clk_o       => audio_clk,
         audio_rst_o       => audio_rst,
         sys_pps_o         => sys_pps
      ); -- i_shell_clk_base

   -- The pixel clock follows the RM's preset request. The DRP rewrite FSM,
   -- XAPP888 preset ROM and reset/lock sequencing all live inside
   -- video_out_clock; rsto is held through relock and reaches the RM as
   -- hdmi_rst — that IS the feedback, there is no ack.
   i_video_out_clock : entity work.video_out_clock
      generic map (
         fref    => 100.0
      )
      port map (
         rsti    => not reset_shell_n,
         clki    => clk_100,
         sel     => vclk_sel_accepted,
         rsto    => hdmi_rst,
         clko    => hdmi_clk,
         clko_x5 => tmds_clk
      ); -- i_video_out_clock

   -- vclk_sel filter: CDC (source register is RM-side), then require 64
   -- identical consecutive samples (absorbs CDC tear and transitional
   -- garbage), reject invalid presets ("111" undefined, "011" = 148.5 MHz
   -- exceeds -2 OSERDES limits), freeze while the RP is dark.
   i_cdc_vclk : xpm_cdc_array_single
      generic map (
         WIDTH         => 3,
         SRC_INPUT_REG => 0
      )
      port map (
         src_clk  => '0',
         src_in   => rm_vclk_sel,
         dest_clk => clk_100,
         dest_out => vclk_meta
      ); -- i_cdc_vclk

   p_vclk_filter : process (clk_100)
   begin
      if rising_edge(clk_100) then
         if vclk_meta /= vclk_candidate then
            vclk_candidate  <= vclk_meta;
            vclk_stable_cnt <= (others => '0');
         elsif vclk_stable_cnt /= 63 then
            vclk_stable_cnt <= vclk_stable_cnt + 1;
         elsif decouple_sys = '0' and vclk_candidate /= "111" and vclk_candidate /= "011" then
            vclk_sel_accepted <= vclk_candidate;
         end if;
      end if;
   end process p_vclk_filter;

   -- Core-clock service (boundary v2): dual-MMCM topology with DRP proxy.
   -- Replaces the fixed CORE/vhdl/clk.vhd (54 MHz single MMCM).
   -- CORE_A boots at the democore preset (54 MHz) so RMs that never use
   -- the DRP service get sensible default behaviour.

   -- clkstat[2] = generic memory-subsystem-ready (v3, informational; the
   -- fence's waitrequest force is what guarantees correctness)
   i_cdc_mem_ready : xpm_cdc_single
      port map ( src_clk => mem_clk, src_in => mem_ready,
                 dest_clk => clk_100, dest_out => mem_ready_sys );

   clkstat <= '0' & mem_ready_sys & core_b_locked & core_a_locked;

   -- clkctl stability filter: same 64-cycle pattern as vclk_sel, no validity
   -- gate.  Freeze while RP is dark so an in-flight swap cannot flip the MMCM.
   i_cdc_clkctl : xpm_cdc_array_single
      generic map (WIDTH => 8, SRC_INPUT_REG => 0)
      port map (src_clk => '0', src_in => rm_clkctl,
                dest_clk => clk_100, dest_out => clkctl_meta);

   p_clkctl_filter : process (clk_100)
   begin
      if rising_edge(clk_100) then
         if clkctl_meta /= clkctl_candidate then
            clkctl_candidate  <= clkctl_meta;
            clkctl_stable_cnt <= (others => '0');
         elsif clkctl_stable_cnt /= 63 then
            clkctl_stable_cnt <= clkctl_stable_cnt + 1;
         elsif decouple_sys = '0' then
            clkctl_accepted <= clkctl_candidate;
         end if;
      end if;
   end process p_clkctl_filter;

   i_shell_core_clk : entity work.shell_core_clk
      port map (
         clk_100       => clk_100,
         -- Stability-filtered control from RM (clkctl bit mapping per BOUNDARY-R6.md)
         mux_sel       => clkctl_accepted(5) & clkctl_accepted(1 downto 0),
         cascade_en    => clkctl_accepted(2),
         -- MMCM resets: RM-controlled bits OR'd with DRP-in-progress guard
         core_a_rst    => clkctl_accepted(3) or drp_active_a,
         core_b_rst    => clkctl_accepted(4) or drp_active_b,
         -- CORE_A DRP bus
         core_a_daddr  => core_a_daddr,
         core_a_di     => core_a_di,
         core_a_do     => core_a_do,
         core_a_den    => core_a_den,
         core_a_dwe    => core_a_dwe,
         core_a_drdy   => core_a_drdy,
         -- CORE_B DRP bus
         core_b_daddr  => core_b_daddr,
         core_b_di     => core_b_di,
         core_b_do     => core_b_do,
         core_b_den    => core_b_den,
         core_b_dwe    => core_b_dwe,
         core_b_drdy   => core_b_drdy,
         -- Status
         core_a_locked => core_a_locked,
         core_b_locked => core_b_locked,
         -- Generic core-clock outputs towards the RM boundary
         core_clk0     => core_clk0,
         core_clk0_rst => core_clk0_rst,
         core_clk1     => core_clk1,
         core_clk1_rst => core_clk1_rst,
         core_clk2     => core_clk2,
         core_clk2_rst => core_clk2_rst
      ); -- i_shell_core_clk

   i_drp_proxy : entity work.drp_proxy
      port map (
         clk          => clk_100,
         rst          => not reset_shell_n,
         decouple     => decouple_sys,
         -- RM-facing partition pins (raw; proxy syncs req internally)
         drp_target   => rm_drp_target,
         drp_addr     => rm_drp_addr,
         drp_data     => rm_drp_data,
         drp_mask     => rm_drp_mask,
         drp_req      => rm_drp_req,
         drp_ack      => drp_ack,
         drp_active_a => drp_active_a,
         drp_active_b => drp_active_b,
         -- CORE_A DRP
         a_daddr      => core_a_daddr,
         a_di         => core_a_di,
         a_do         => core_a_do,
         a_den        => core_a_den,
         a_dwe        => core_a_dwe,
         a_drdy       => core_a_drdy,
         -- CORE_B DRP
         b_daddr      => core_b_daddr,
         b_di         => core_b_di,
         b_do         => core_b_do,
         b_den        => core_b_den,
         b_dwe        => core_b_dwe,
         b_drdy       => core_b_drdy
      ); -- i_drp_proxy

   ---------------------------------------------------------------------------
   -- Loader: UART byte source -> sync-word-gated ICAP streamer
   -- (stage A1 of m65-shell-poc, hardware-verified)
   ---------------------------------------------------------------------------

   -- 2 MBd on the TE0790's FT2232 (verified at 2 Mbps in mega65-core use);
   -- 50 MHz / 2 MBd = 25 clks/bit exactly (zero sampling error).
   -- Sender baud must match.
   --
   -- The whole loader block runs on loader_clk (50 MHz, MMCM-conditioned):
   -- round 4 showed the BUFG fix alone did not make ICAP accept partials,
   -- and ICAPE2 on the BUFG'd raw oscillator sat exactly at its 100 MHz
   -- spec limit (min-period slack 0.000). At 50 MHz that whole failure
   -- class is off the table. loader_rst matches the previous
   -- "not reset_shell_n" semantics (whole-shell reset only).
   i_uart_rx : entity work.uart_rx
      generic map (
         CLK_HZ => 50_000_000,
         BAUD   => 2_000_000
      )
      port map (
         clk        => loader_clk,
         rst        => loader_rst,
         rxd        => uart_rxd_i,
         data       => loader_byte,
         data_valid => loader_byte_valid
      ); -- i_uart_rx

   i_icap_loader : entity work.icap_loader
      generic map (
         CLK_HZ => 50_000_000
      )
      port map (
         clk          => loader_clk,
         rst          => loader_rst,
         byte_in      => loader_byte,
         byte_valid   => loader_byte_valid,
         decouple     => decouple,
         rm_reset     => rm_reset,
         status       => loader_status,
         stat_attempt => icap_attempt,
         stat_dalign  => icap_dalign,
         stat_cfgerr  => icap_cfgerr,
         stat_abort   => icap_abort
      ); -- i_icap_loader

   -- Loader progress (blinks the red LED during a swap): count received bytes
   p_progress : process (loader_clk)
   begin
      if rising_edge(loader_clk) then
         if decouple = '0' then
            loader_progress <= (others => '0');
         elsif loader_byte_valid = '1' then
            loader_progress <= loader_progress + 1;
         end if;
      end if;
   end process p_progress;

   -- Verdict blink source: at 50 MHz bit 25 gives a ~0.75 Hz blink and
   -- bit 22 a ~6 Hz blink.
   p_verdict_cnt : process (loader_clk)
   begin
      if rising_edge(loader_clk) then
         verdict_cnt <= verdict_cnt + 1;
      end if;
   end process p_verdict_cnt;

   -- Post-attempt verdict for the red LED (held until the next load or a
   -- long-press shell reset): solid = config engine never synced (the
   -- rounds-1..4 no-op signature), slow blink = engine synced but flagged
   -- CFGERR/abort, fast blink = stream accepted cleanly.
   led_verdict <= '1'             when icap_dalign = '0' else
                  verdict_cnt(25) when icap_cfgerr = '1' or icap_abort = '1' else
                  verdict_cnt(22);

   -- Loader-domain outputs crossed back into the sys domain for the
   -- consumers that live there (vclk/clkctl freeze, drp_proxy, RM resets).
   i_cdc_dec_sys : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => decouple,
                 dest_clk => clk_100, dest_out => decouple_sys );

   i_cdc_rst_sys : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => clk_100, dest_out => rm_reset_sys );

   ---------------------------------------------------------------------------
   -- Decouple/reset distribution into the boundary clock domains
   ---------------------------------------------------------------------------

   i_cdc_dec_hr : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => decouple,
                 dest_clk => mem_clk, dest_out => decouple_mem );

   i_cdc_dec_hdmi : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => decouple,
                 dest_clk => hdmi_clk, dest_out => decouple_hdmi );

   i_cdc_dec_audio : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => decouple,
                 dest_clk => audio_clk, dest_out => decouple_audio );

   -- The loader itself runs in the loader domain, so no CDC here.
   rm_rst_loader <= rm_reset;

   i_cdc_rst_core0 : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => core_clk0, dest_out => rm_rst_core0 );

   i_cdc_rst_core2 : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => core_clk2, dest_out => rm_rst_core2 );

   i_cdc_rst_core1 : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => core_clk1, dest_out => rm_rst_core1 );

   i_cdc_rst_hr : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => mem_clk, dest_out => rm_rst_mem );

   i_cdc_rst_audio : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => audio_clk, dest_out => rm_rst_audio );

   i_cdc_rst_hdmi : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => hdmi_clk, dest_out => rm_rst_hdmi );

   ---------------------------------------------------------------------------
   -- The reconfigurable module
   ---------------------------------------------------------------------------

   RM : rm_top_r6
      port map (
         sys_clk_i           => clk_100,
         sys_pps_i           => sys_pps,
         -- rm_reset (loader) resets the whole RM after a swap; the RM-internal reset
         -- chain then propagates it into every RM-internal domain
         reset_shell_n_i       => reset_shell_n and not rm_reset_sys,
         reset_core_n_i      => reset_core_n and not rm_reset_sys,
         loader_clk_i         => loader_clk,
         loader_rst_i         => loader_rst or rm_rst_loader,
         core_clk0_i         => core_clk0,
         core_clk0_rst_i     => core_clk0_rst or rm_rst_core0,
         core_clk2_i         => core_clk2,
         core_clk2_rst_i     => core_clk2_rst or rm_rst_core2,
         qspi_clk_o          => rm_qspi_clk,
         qspi_csn_o          => rm_qspi_csn,
         qspi_d_i            => qspidb_io,
         qspi_d_o            => rm_qspi_d,
         qspi_d_oe_o         => rm_qspi_d_oe,
         core_clk1_i         => core_clk1,
         core_clk1_rst_i     => core_clk1_rst or rm_rst_core1,
         mem_clk_i            => mem_clk,
         mem_rst_i            => mem_rst or rm_rst_mem,
         audio_clk_i         => audio_clk,
         audio_rst_i         => audio_rst or rm_rst_audio,
         hdmi_clk_i          => hdmi_clk,
         hdmi_rst_i          => hdmi_rst or rm_rst_hdmi,
         uart_rx_i           => uart_rxd_i,
         uart_tx_o           => rm_uart_tx,
         kb_io0_o            => rm_kb_io0,
         kb_io1_o            => rm_kb_io1,
         kb_io2_i            => kb_io2_i,
         sd_reset_o          => rm_sd_reset,
         sd_clk_o            => rm_sd_clk,
         sd_mosi_o           => rm_sd_mosi,
         sd_miso_i           => sd_miso_i,
         sd_cd_i             => sd_cd_i,
         sd_d1_i             => sd_d1_i,
         sd_d2_i             => sd_d2_i,
         sd2_reset_o         => rm_sd2_reset,
         sd2_clk_o           => rm_sd2_clk,
         sd2_mosi_o          => rm_sd2_mosi,
         sd2_miso_i          => sd2_miso_i,
         sd2_cd_i            => sd2_cd_i,
         sd2_wp_i            => sd2_wp_i,
         sd2_d1_i            => sd2_d1_i,
         sd2_d2_i            => sd2_d2_i,
         joy_1_up_n_i        => fa_up_n_i,
         joy_1_down_n_i      => fa_down_n_i,
         joy_1_left_n_i      => fa_left_n_i,
         joy_1_right_n_i     => fa_right_n_i,
         joy_1_fire_n_i      => fa_fire_n_i,
         joy_1_up_n_o        => rm_joy1_up_n,
         joy_1_down_n_o      => rm_joy1_down_n,
         joy_1_left_n_o      => rm_joy1_left_n,
         joy_1_right_n_o     => rm_joy1_right_n,
         joy_1_fire_n_o      => rm_joy1_fire_n,
         joy_2_up_n_i        => fb_up_n_i,
         joy_2_down_n_i      => fb_down_n_i,
         joy_2_left_n_i      => fb_left_n_i,
         joy_2_right_n_i     => fb_right_n_i,
         joy_2_fire_n_i      => fb_fire_n_i,
         joy_2_up_n_o        => rm_joy2_up_n,
         joy_2_down_n_o      => rm_joy2_down_n,
         joy_2_left_n_o      => rm_joy2_left_n,
         joy_2_right_n_o     => rm_joy2_right_n,
         joy_2_fire_n_o      => rm_joy2_fire_n,
         paddle_i            => paddle_i,
         paddle_drain_o      => rm_paddle_drain,
         vga_red_o           => rm_vga_red,
         vga_green_o         => rm_vga_green,
         vga_blue_o          => rm_vga_blue,
         vga_hs_o            => rm_vga_hs,
         vga_vs_o            => rm_vga_vs,
         vdac_clk_o          => rm_vdac_clk,
         vdac_sync_n_o       => rm_vdac_sync_n,
         vdac_blank_n_o      => rm_vdac_blank_n,
         audio_left_o        => rm_audio_left,
         audio_right_o       => rm_audio_right,
         hdmi_hpd_i          => hdmi_hpd_i,
         mem_write_o         => rm_mem_write,
         mem_read_o          => rm_mem_read,
         mem_address_o       => rm_mem_address,
         mem_writedata_o     => rm_mem_writedata,
         mem_byteenable_o    => rm_mem_byteenable,
         mem_burstcount_o    => rm_mem_burstcount,
         mem_readdata_i      => avm_readdata,
         mem_readdatavalid_i => avm_readdatavalid,
         mem_waitrequest_i   => avm_waitrequest or mem_stall,
         tmds_o              => rm_tmds,
         vclk_sel_o          => rm_vclk_sel,
         -- Core-clock service (boundary v2)
         drp_target_o        => rm_drp_target,
         drp_addr_o          => rm_drp_addr,
         drp_data_o          => rm_drp_data,
         drp_mask_o          => rm_drp_mask,
         drp_req_o           => rm_drp_req,
         drp_ack_i           => drp_ack,
         clkctl_o            => rm_clkctl,
         clkstat_i           => clkstat,
         fpga_scl_in_i       => fpga_scl_io,
         fpga_scl_out_o      => rm_fpga_scl,
         fpga_sda_in_i       => fpga_sda_io,
         fpga_sda_out_o      => rm_fpga_sda,
         grove_scl_in_i      => grove_scl_io,
         grove_scl_out_o     => rm_grove_scl,
         grove_sda_in_i      => grove_sda_io,
         grove_sda_out_o     => rm_grove_sda,
         i2c_scl_in_i        => i2c_scl_io,
         i2c_scl_out_o       => rm_i2c_scl,
         i2c_sda_in_i        => i2c_sda_io,
         i2c_sda_out_o       => rm_i2c_sda,
         hdmi_scl_in_i       => hdmi_scl_io,
         hdmi_scl_out_o      => rm_hdmi_scl,
         hdmi_sda_in_i       => hdmi_sda_io,
         hdmi_sda_out_o      => rm_hdmi_sda,
         vga_scl_in_i        => vga_scl_io,
         vga_scl_out_o       => rm_vga_scl,
         vga_sda_in_i        => vga_sda_io,
         vga_sda_out_o       => rm_vga_sda,
         audio_scl_in_i      => audio_scl_io,
         audio_scl_out_o     => rm_audio_scl,
         audio_sda_in_i      => audio_sda_io,
         audio_sda_out_o     => rm_audio_sda,
         iec_reset_n_o       => rm_iec_reset_n,
         iec_atn_n_o         => rm_iec_atn_n,
         iec_clk_en_o        => rm_iec_clk_en,
         iec_clk_n_i         => iec_clk_n_i,
         iec_clk_n_o         => rm_iec_clk_n,
         iec_data_en_o       => rm_iec_data_en,
         iec_data_n_i        => iec_data_n_i,
         iec_data_n_o        => rm_iec_data_n,
         iec_srq_en_o        => rm_iec_srq_en,
         iec_srq_n_i         => iec_srq_n_i,
         iec_srq_n_o         => rm_iec_srq_n,
         cart_en_o           => rm_cart_en,
         cart_phi2_o         => rm_cart_phi2,
         cart_dotclock_o     => rm_cart_dotclock,
         cart_dma_i          => cart_dma_i,
         cart_reset_oe_o     => rm_cart_reset_oe,
         cart_reset_i        => cart_reset_in,
         cart_reset_o        => rm_cart_reset_out,
         cart_game_oe_o      => rm_cart_game_oe,
         cart_game_i         => cart_game_in,
         cart_game_o         => rm_cart_game_out,
         cart_exrom_oe_o     => rm_cart_exrom_oe,
         cart_exrom_i        => cart_exrom_in,
         cart_exrom_o        => rm_cart_exrom_out,
         cart_nmi_oe_o       => rm_cart_nmi_oe,
         cart_nmi_i          => cart_nmi_in,
         cart_nmi_o          => rm_cart_nmi_out,
         cart_irq_oe_o       => rm_cart_irq_oe,
         cart_irq_i          => cart_irq_in,
         cart_irq_o          => rm_cart_irq_out,
         cart_roml_oe_o      => rm_cart_roml_oe,
         cart_roml_i         => cart_roml_in,
         cart_roml_o         => rm_cart_roml_out,
         cart_romh_oe_o      => rm_cart_romh_oe,
         cart_romh_i         => cart_romh_in,
         cart_romh_o         => rm_cart_romh_out,
         cart_ctrl_oe_o      => rm_cart_ctrl_oe,
         cart_ba_i           => cart_ba_in,
         cart_rw_i           => cart_rw_in,
         cart_io1_i          => cart_io1_in,
         cart_io2_i          => cart_io2_in,
         cart_ba_o           => rm_cart_ba_out,
         cart_rw_o           => rm_cart_rw_out,
         cart_io1_o          => rm_cart_io1_out,
         cart_io2_o          => rm_cart_io2_out,
         cart_data_oe_o      => rm_cart_data_oe,
         cart_d_i            => cart_d_in,
         cart_d_o            => rm_cart_d_out,
         cart_addr_oe_o      => rm_cart_addr_oe,
         cart_a_i            => cart_a_in,
         cart_a_o            => rm_cart_a_out,
         power_led_o         => rm_power_led,
         drive_led_o         => rm_drive_led,
         rm_alive_o          => rm_alive,
         rsv_i               => (others => '0'),
         rsv_o               => open
      ); -- RM

   ---------------------------------------------------------------------------
   -- Tier-0 outputs with decoupling
   ---------------------------------------------------------------------------

   uart_txd_o <= rm_uart_tx when decouple = '0' else '1';

   -- Smart keyboard: park the serial protocol lines low while the RP is dark
   kb_io0_o <= rm_kb_io0 when decouple = '0' else '0';
   kb_io1_o <= rm_kb_io1 when decouple = '0' else '0';

   -- Keyboard JTAG chain: parked static (never part of the ABI)
   kb_tck_o    <= '0';
   kb_tms_o    <= '0';
   kb_tdi_o    <= '0';
   kb_jtagen_o <= '0';

   -- SD slots: deselect while dark (reset asserted, clock low, mosi idle)
   sd_reset_o  <= rm_sd_reset  when decouple = '0' else '1';
   sd_clk_o    <= rm_sd_clk    when decouple = '0' else '0';
   sd_mosi_o   <= rm_sd_mosi   when decouple = '0' else '1';
   sd2_reset_o <= rm_sd2_reset when decouple = '0' else '1';
   sd2_clk_o   <= rm_sd2_clk   when decouple = '0' else '0';
   sd2_mosi_o  <= rm_sd2_mosi  when decouple = '0' else '1';

   -- Joystick outputs: '1' = leave pin floating (board drives low only)
   fa_up_n_o    <= rm_joy1_up_n    when decouple = '0' else '1';
   fa_down_n_o  <= rm_joy1_down_n  when decouple = '0' else '1';
   fa_left_n_o  <= rm_joy1_left_n  when decouple = '0' else '1';
   fa_right_n_o <= rm_joy1_right_n when decouple = '0' else '1';
   fa_fire_n_o  <= rm_joy1_fire_n  when decouple = '0' else '1';
   fb_up_n_o    <= rm_joy2_up_n    when decouple = '0' else '1';
   fb_down_n_o  <= rm_joy2_down_n  when decouple = '0' else '1';
   fb_left_n_o  <= rm_joy2_left_n  when decouple = '0' else '1';
   fb_right_n_o <= rm_joy2_right_n when decouple = '0' else '1';
   fb_fire_n_o  <= rm_joy2_fire_n  when decouple = '0' else '1';

   paddle_drain_o <= rm_paddle_drain when decouple = '0' else '0';

   -- VGA/VDAC: black picture, syncs released, DAC blanked while dark.
   -- These pins carry no output-delay constraints upstream; the
   -- unregistered park mux keeps that (non-)guarantee.
   vga_red_o      <= rm_vga_red      when decouple = '0' else (others => '0');
   vga_green_o    <= rm_vga_green    when decouple = '0' else (others => '0');
   vga_blue_o     <= rm_vga_blue     when decouple = '0' else (others => '0');
   vga_hs_o       <= rm_vga_hs       when decouple = '0' else '1';
   vga_vs_o       <= rm_vga_vs       when decouple = '0' else '1';
   vdac_clk_o     <= rm_vdac_clk     when decouple = '0' else '0';
   vdac_sync_n_o  <= rm_vdac_sync_n  when decouple = '0' else '0';
   vdac_blank_n_o <= rm_vdac_blank_n when decouple = '0' else '0';

   -- Mainboard LEDs (green/red active low): mirror the RM's power/drive
   -- LEDs; while the RP is dark the red LED blinks with loader progress
   -- and led_o signals "loading" (the keyboard LEDs are RM-side and
   -- unreachable while dark — see the header note)
   led_g_n_o <= not (rm_power_led and not decouple);
   -- Red LED priority: progress flicker while loading, then the ICAP
   -- verdict (see led_verdict above) once any load has been attempted,
   -- else the RM's drive LED.
   led_r_n_o <= not loader_progress(14) when decouple = '1'     else
                not led_verdict         when icap_attempt = '1' else
                not rm_drive_led;
   led_o     <= decouple;

   ---------------------------------------------------------------------------
   -- Audio DAC (AK4432) driver: shell-side; PCM parked at silence while
   -- the RP is dark (DAC stays powered and clocked). Mux registered in the
   -- audio domain (boundary timing rule).
   ---------------------------------------------------------------------------

   p_audio_park : process (audio_clk)
   begin
      if rising_edge(audio_clk) then
         if decouple_audio = '1' then
            audio_left  <= (others => '0');
            audio_right <= (others => '0');
         else
            audio_left  <= rm_audio_left;
            audio_right <= rm_audio_right;
         end if;
      end if;
   end process p_audio_park;

   i_audio : entity work.audio
      port map (
         audio_clk_i    => audio_clk,
         audio_reset_i  => audio_rst,
         audio_left_i   => audio_left,
         audio_right_i  => audio_right,
         audio_mclk_o   => audio_mclk_o,
         audio_bick_o   => audio_bick_o,
         audio_sdti_o   => audio_sdti_o,
         audio_lrclk_o  => audio_lrclk_o,
         audio_pdn_n_o  => audio_pdn_n_o
      ); -- i_audio

   audio_i2cfil_o <= '0';  -- I2C speed 400 kHz

   ---------------------------------------------------------------------------
   -- I2C buses: open collector, i.e. either drive pin low, or let it float;
   -- all buses released while the RP is dark
   ---------------------------------------------------------------------------

   fpga_sda_io  <= '0' when rm_fpga_sda  = '0' and decouple = '0' else 'Z';
   fpga_scl_io  <= '0' when rm_fpga_scl  = '0' and decouple = '0' else 'Z';
   grove_sda_io <= '0' when rm_grove_sda = '0' and decouple = '0' else 'Z';
   grove_scl_io <= '0' when rm_grove_scl = '0' and decouple = '0' else 'Z';
   i2c_sda_io   <= '0' when rm_i2c_sda   = '0' and decouple = '0' else 'Z';
   i2c_scl_io   <= '0' when rm_i2c_scl   = '0' and decouple = '0' else 'Z';
   hdmi_sda_io  <= '0' when rm_hdmi_sda  = '0' and decouple = '0' else 'Z';
   hdmi_scl_io  <= '0' when rm_hdmi_scl  = '0' and decouple = '0' else 'Z';
   vga_sda_io   <= '0' when rm_vga_sda   = '0' and decouple = '0' else 'Z';
   vga_scl_io   <= '0' when rm_vga_scl   = '0' and decouple = '0' else 'Z';
   audio_sda_io <= '0' when rm_audio_sda = '0' and decouple = '0' else 'Z';
   audio_scl_io <= '0' when rm_audio_scl = '0' and decouple = '0' else 'Z';

   ---------------------------------------------------------------------------
   -- IEC serial port: enables inverted to the active-low pins (per
   -- top_mega65-r6.vhd); everything disabled/released while the RP is dark
   ---------------------------------------------------------------------------

   iec_reset_n_o   <= rm_iec_reset_n when decouple = '0' else '1';
   iec_atn_n_o     <= rm_iec_atn_n   when decouple = '0' else '1';
   iec_clk_n_o     <= rm_iec_clk_n   when decouple = '0' else '1';
   iec_data_n_o    <= rm_iec_data_n  when decouple = '0' else '1';
   iec_srq_n_o     <= rm_iec_srq_n   when decouple = '0' else '1';
   iec_clk_en_n_o  <= not (rm_iec_clk_en  and not decouple);
   iec_data_en_n_o <= not (rm_iec_data_en and not decouple);
   iec_srq_en_n_o  <= not (rm_iec_srq_en  and not decouple);

   ---------------------------------------------------------------------------
   -- C64 Cartridge port: pin logic verbatim from top_mega65-r6.vhd, driven
   -- by decouple-gated signals. Dark parking = the flat democore's state
   -- (cart_en '1' with every driver tri-stated: due to a bug in the R5/R6
   -- boards the port must stay enabled for joystick port 2 to work)
   ---------------------------------------------------------------------------

   cart_en       <= rm_cart_en       when decouple = '0' else '1';
   cart_reset_oe <= rm_cart_reset_oe and not decouple;
   cart_game_oe  <= rm_cart_game_oe  and not decouple;
   cart_exrom_oe <= rm_cart_exrom_oe and not decouple;
   cart_nmi_oe   <= rm_cart_nmi_oe   and not decouple;
   cart_irq_oe   <= rm_cart_irq_oe   and not decouple;
   cart_roml_oe  <= rm_cart_roml_oe  and not decouple;
   cart_romh_oe  <= rm_cart_romh_oe  and not decouple;
   cart_ctrl_oe  <= rm_cart_ctrl_oe  and not decouple;
   cart_data_oe  <= rm_cart_data_oe  and not decouple;
   cart_addr_oe  <= rm_cart_addr_oe  and not decouple;

   cart_phi2_o     <= rm_cart_phi2     when decouple = '0' else '0';
   cart_dotclock_o <= rm_cart_dotclock when decouple = '0' else '0';

   cart_en_o         <= cart_en;
   cart_reset_io     <= rm_cart_reset_out when cart_reset_oe = '1' else 'Z';
   cart_game_io      <= rm_cart_game_out  when cart_game_oe  = '1' else 'Z';
   cart_exrom_io     <= rm_cart_exrom_out when cart_exrom_oe = '1' else 'Z';
   cart_nmi_io       <= rm_cart_nmi_out   when cart_nmi_oe   = '1' else 'Z';
   cart_irq_io       <= rm_cart_irq_out   when cart_irq_oe   = '1' else 'Z';
   cart_roml_io      <= rm_cart_roml_out  when cart_roml_oe  = '1' else 'Z';
   cart_romh_io      <= rm_cart_romh_out  when cart_romh_oe  = '1' else 'Z';
   cart_reset_in     <= cart_reset_io;
   cart_game_in      <= cart_game_io;
   cart_exrom_in     <= cart_exrom_io;
   cart_nmi_in       <= cart_nmi_io;
   cart_irq_in       <= cart_irq_io;
   cart_roml_in      <= cart_roml_io;
   cart_romh_in      <= cart_romh_io;
   cart_reset_oe_n_o <= not cart_reset_oe;
   cart_game_oe_n_o  <= not cart_game_oe;
   cart_exrom_oe_n_o <= not cart_exrom_oe;
   cart_nmi_oe_n_o   <= not cart_nmi_oe;
   cart_irq_oe_n_o   <= not cart_irq_oe;
   cart_roml_oe_n_o  <= not cart_roml_oe;
   cart_romh_oe_n_o  <= not cart_romh_oe;

   cart_ba_io        <= rm_cart_ba_out   when cart_ctrl_oe = '1' else 'Z';
   cart_rw_io        <= rm_cart_rw_out   when cart_ctrl_oe = '1' else 'Z';
   cart_io1_io       <= rm_cart_io1_out  when cart_ctrl_oe = '1' else 'Z';
   cart_io2_io       <= rm_cart_io2_out  when cart_ctrl_oe = '1' else 'Z';
   cart_ba_in        <= cart_ba_io;
   cart_rw_in        <= cart_rw_io;
   cart_io1_in       <= cart_io1_io;
   cart_io2_in       <= cart_io2_io;
   cart_ctrl_en_o    <= not cart_en;
   cart_ctrl_dir_o   <= cart_ctrl_oe;

   cart_d_io         <= rm_cart_d_out    when cart_data_oe = '1' else (others => 'Z');
   cart_d_in         <= cart_d_io;
   cart_data_en_o    <= not cart_en;
   cart_data_dir_o   <= cart_data_oe;

   cart_a_io         <= rm_cart_a_out    when cart_addr_oe = '1' else (others => 'Z');
   cart_a_in         <= cart_a_io;
   cart_addr_en_o    <= not cart_en;
   cart_haddr_dir_o  <= cart_addr_oe;
   cart_laddr_dir_o  <= cart_addr_oe;

   ---------------------------------------------------------------------------
   -- Avalon fence + HyperRAM controller (mem domain)
   ---------------------------------------------------------------------------

   -- Pass requests while coupled; when decouple asserts, the SHELL completes
   -- any write burst in flight with byteenable-"00" dummy beats (Avalon
   -- no-ops — the surviving RAM content must not be stomped), then blocks
   -- everything until re-couple.
   --
   -- The shell must inject those beats itself: the loader asserts rm_reset
   -- together with decouple, so the RM's master stops instantly and will
   -- never deliver the remaining beats (hardware-verified fix on the
   -- Wukong — see that shell's p_fence history).
   p_fence : process (mem_clk)
   begin
      if rising_edge(mem_clk) then
         if avm_write = '1' and avm_waitrequest = '0' then
            if wr_beats_left = 0 then
               -- first beat of a burst: remaining = burstcount - 1
               wr_beats_left <= unsigned(rm_mem_burstcount) - 1;
            else
               wr_beats_left <= wr_beats_left - 1;
            end if;
         end if;
         if mem_rst = '1' then
            wr_beats_left <= (others => '0');
         end if;
      end if;
   end process p_fence;

   -- Memory-ready timer (boundary v3): see the signal declaration.  Restarts
   -- on every hr reset (button presses), like the Wukong's recalibration.
   p_mem_ready : process (mem_clk)
   begin
      if rising_edge(mem_clk) then
         if mem_rst = '1' then
            mem_ready_cnt <= (others => '0');
            mem_ready     <= '0';
         elsif mem_ready_cnt = (mem_ready_cnt'range => '1') then
            mem_ready     <= '1';
         else
            mem_ready_cnt <= mem_ready_cnt + 1;
         end if;
      end if;
   end process p_mem_ready;

   -- Drains the orphaned burst (flush beats decrement wr_beats_left in
   -- p_fence like any accepted write); a fresh header cannot start while
   -- decoupled, so no garbage burstcount can be loaded.
   fence_flush <= '1' when decouple_mem = '1' and wr_beats_left /= 0 else '0';

   -- Memory-ready stalling (boundary v3): while decoupled OR the memory
   -- subsystem is initializing, force waitrequest toward the RM and pass no
   -- commands — in-band Avalon back-pressure, so RM commands stall and
   -- complete instead of being accepted-and-dropped (the ascal preload
   -- deadlock class; the R6 tester's full-push black + swap-5 wedge).
   mem_stall <= decouple_mem or not mem_ready;

   avm_write      <= (rm_mem_write and not mem_stall) or fence_flush;
   avm_read       <= rm_mem_read and not mem_stall;
   avm_byteenable <= rm_mem_byteenable when decouple_mem = '0' else "00";

   -- HyperRAM resets on the reset button only (mem_rst, via shell_clk_base) — NOT
   -- during an RM swap, so the IS66WVH8M8 keeps self-refreshing and RAM
   -- content survives partial reconfiguration
   i_hyperram : entity work.hyperram
      generic map (
         G_ERRATA_ISSI_D_FIX => true
      )
      port map (
         clk_i               => mem_clk,
         clk_del_i           => mem_clk_del,
         delay_refclk_i      => mem_delay_refclk,
         rst_i               => mem_rst,
         avm_write_i         => avm_write,
         avm_read_i          => avm_read,
         avm_address_i       => rm_mem_address,
         avm_writedata_i     => rm_mem_writedata,
         avm_byteenable_i    => avm_byteenable,
         avm_burstcount_i    => rm_mem_burstcount,
         avm_readdata_o      => avm_readdata,
         avm_readdatavalid_o => avm_readdatavalid,
         avm_waitrequest_o   => avm_waitrequest,
         count_long_o        => open,
         count_short_o       => open,
         hr_resetn_o         => hr_reset_o,
         hr_csn_o            => hr_cs0_o,
         hr_ck_o             => hr_clk_p_o,
         hr_rwds_in_i        => hr_rwds_in,
         hr_rwds_out_o       => hr_rwds_out,
         hr_rwds_oe_n_o      => hr_rwds_oe_n,
         hr_dq_in_i          => hr_dq_in,
         hr_dq_out_o         => hr_dq_out,
         hr_dq_oe_n_o        => hr_dq_oe_n
      ); -- i_hyperram

   -- Tri-state buffers for HyperRAM
   hr_rwds_io <= hr_rwds_out when hr_rwds_oe_n = '0' else 'Z';
   hr_d_gen : for i in 0 to 7 generate
      hr_d_io(i) <= hr_dq_out(i) when hr_dq_oe_n(i) = '0' else 'Z';
   end generate hr_d_gen;
   hr_rwds_in <= hr_rwds_io;
   hr_dq_in   <= hr_d_io;

   ---------------------------------------------------------------------------
   -- HDMI back end: park mux + serialisers only. The TMDS encoder lives in
   -- the RM; while the RP is dark the lanes emit a control-period symbol
   -- (monitor mutes — accepted, LEDs show loading).
   ---------------------------------------------------------------------------

   -- Register the mux once in the hdmi domain (boundary timing rule)
   p_tmds_park : process (hdmi_clk)
   begin
      if rising_edge(hdmi_clk) then
         if decouple_hdmi = '1' then
            hdmi_tmds(0) <= C_TMDS_CTL0;
            hdmi_tmds(1) <= C_TMDS_CTL0;
            hdmi_tmds(2) <= C_TMDS_CTL0;
         else
            hdmi_tmds(0) <= rm_tmds( 9 downto  0);
            hdmi_tmds(1) <= rm_tmds(19 downto 10);
            hdmi_tmds(2) <= rm_tmds(29 downto 20);
         end if;
      end if;
   end process p_tmds_park;

   gen_hdmi_data : for i in 0 to 2 generate
      i_serialiser_data : entity work.serialiser_10to1_selectio
         port map (
            rst     => hdmi_rst,
            clk     => hdmi_clk,
            clk_x5  => tmds_clk,
            d       => hdmi_tmds(i),
            out_p   => tmds_data_p_o(i),
            out_n   => tmds_data_n_o(i)
         );
   end generate gen_hdmi_data;

   i_serialiser_clk : entity work.serialiser_10to1_selectio
      port map (
         rst     => hdmi_rst,
         clk     => hdmi_clk,
         clk_x5  => tmds_clk,
         d       => "0000011111",
         out_p   => tmds_clk_p_o,
         out_n   => tmds_clk_n_o
      ); -- i_serialiser_clk

   ---------------------------------------------------------------------------
   -- Safe default values for ports not in the boundary (parked static,
   -- verbatim from top_mega65-r6.vhd)
   ---------------------------------------------------------------------------

   vdac_psave_n_o        <= '1';
   hdmi_hiz_en_o         <= '0'; -- HDMI is 50 ohm terminated.
   hdmi_ls_oe_n_o        <= '0'; -- Enable HDMI output
   dbg_io_11             <= 'Z';

   eth_clock_o           <= '0';
   eth_led2_o            <= '0';
   eth_mdc_o             <= '0';
   eth_mdio_io           <= 'Z';
   eth_reset_o           <= '1';
   eth_txd_o             <= (others => '0');
   eth_txen_o            <= '0';
   f_density_o           <= '1';
   f_motora_o            <= '1';
   f_motorb_o            <= '1';
   f_selecta_o           <= '1';
   f_selectb_o           <= '1';
   f_side1_o             <= '1';
   f_stepdir_o           <= '1';
   f_step_o              <= '1';
   f_wdata_o             <= '1';
   f_wgate_o             <= '1';
   joystick_5v_disable_o <= '0'; -- Enable 5V power supply to joysticks
   p1lo_io               <= (others => 'Z');
   p1hi_io               <= (others => 'Z');
   p2lo_io               <= (others => 'Z');
   p2hi_io               <= (others => 'Z');
   pmod1_en_o            <= '0';
   pmod2_en_o            <= '0';
   -- QSPI flash pass-through (boundary v3): CS/data park inactive while the
   -- RP is dark (the ICAP loader must never race an RM flash transaction).
   qspicsn_o <= rm_qspi_csn when decouple = '0' else '1';
   qspi_gen : for i in 0 to 3 generate
      qspidb_io(i) <= rm_qspi_d(i) when rm_qspi_d_oe(i) = '1' and decouple = '0' else 'Z';
   end generate qspi_gen;

   -- The flash clock is the dedicated CCLK config pin — only drivable
   -- post-configuration through STARTUPE2.USRCCLKO. STARTUPE2 is a
   -- one-per-device config primitive (like the loader's ICAPE2) and must
   -- live in the static. Note: the first ~3 USRCCLKO edges after
   -- configuration are swallowed while the internal CCLK mux hands over —
   -- flash controllers idle SCK before CS assertion, so this is harmless.
   i_startupe2 : STARTUPE2
      generic map (
         PROG_USR      => "FALSE",
         SIM_CCLK_FREQ => 10.0
      )
      port map (
         CFGCLK    => open,
         CFGMCLK   => open,
         EOS       => open,
         PREQ      => open,
         CLK       => '0',
         GSR       => '0',
         GTS       => '0',
         KEYCLEARB => '0',
         PACK      => '0',
         USRCCLKO  => rm_qspi_clk and not decouple,
         USRCCLKTS => '0',
         USRDONEO  => '1',
         USRDONETS => '1'
      ); -- i_startupe2
   sdram_clk_o           <= '0';
   sdram_cke_o           <= '0';
   sdram_ras_n_o         <= '1';
   sdram_cas_n_o         <= '1';
   sdram_we_n_o          <= '1';
   sdram_cs_n_o          <= '1';
   sdram_ba_o            <= (others => '0');
   sdram_a_o             <= (others => '0');
   sdram_dqml_o          <= '0';
   sdram_dqmh_o          <= '0';
   sdram_dq_io           <= (others => 'Z');

end architecture synthesis;
