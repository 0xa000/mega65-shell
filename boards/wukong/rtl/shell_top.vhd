-- SPDX-License-Identifier: GPL-3.0-only
-- Shell top by 0xa000; pin-handling/peripheral-driver portions derived from
-- the MiSTer2MEGA65 board top (GPLv3, sy2002 & MJoergen) — see ATTRIBUTION.md.
----------------------------------------------------------------------------------
-- Thin shell — static design top for the QMTECH Wukong (boundary v5)
--
-- Owns everything a reconfigurable module cannot or should not:
--   * all pins/IOBUFs and all clock generation (clk_wukong 50->100,
--     shell_clk_base loader/audio, video_out_clock following the RM's
--     vclk_sel preset request, shell_core_clk dual-MMCM service + DRP proxy
--     (boundary v2), the DDR3 wrapper's own MMCM)
--   * the reset manager
--   * the DDR3 controller behind ONE Avalon-MM slave (the RM brings its own
--     arbiter) — RAM content survives RM swaps (controller keeps refreshing)
--   * ONLY the OSERDES serialisers of the HDMI back end (boundary v1): the
--     TMDS encoder, InfoFrames and audio data islands are RM-side; the
--     shell generates no video and parks the TMDS lanes at a control
--     symbol while the RP is dark (sync loss on swap is accepted — LEDs
--     indicate loading)
--   * the sync-word-gated UART/SD -> ICAP loader, which drives
--     decouple/rm_reset. Since v5 the whole loader block runs on
--     loader_clk (50 MHz, MMCM-conditioned) and the ICAP status readback
--     drives a post-load LED verdict — both backported from the R6 shell
--   * decoupling: every RM output is gated/muxed to a safe value while the
--     RP is dark; the Avalon fence completes an in-flight write burst
--     before blocking (the RM still runs for a while after decouple
--     asserts, so its last burst data is valid)
--   * memory-ready stalling (boundary v3): while the RP is decoupled OR the
--     memory subsystem is not ready (DDR3 recalibration after a button
--     reset), the fence forces waitrequest toward the RM instead of letting
--     commands through — in-band Avalon back-pressure, so RM commands stall
--     and complete instead of being accepted-and-dropped (the ascal preload
--     deadlock class; cold-boot black / long-press stripe wedge)
--   * QSPI flash pass-through (boundary v3): data/CS pins as gated IOBUFs;
--     the flash clock is the dedicated CCLK config pin, driven via the
--     shell-owned STARTUPE2 (config primitive — must live in the static)
--   * the FAT32 SD load path (boundary v4): descriptor register file over
--     the reserved boundary pins, walker-owned SD pad mux
--
-- The RM (rm_top) is a black box here; the DFX flow links its synthesized
-- checkpoint into the reconfigurable partition. The rm_top component
-- declaration below is the authoritative boundary port list; the boundary
-- service contract lives in docs/.
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

entity shell_top is
port (
   -- Onboard crystal oscillator = 50 MHz
   clk_in                  : in    std_logic;

   -- Buttons (active low)
   reset_button            : in    std_logic;

   -- USB-RS232 Interface
   rsrx                    : in    std_logic;
   uart_txd                : out   std_logic;

   -- HDMI
   tmds_data_p             : out   std_logic_vector(2 downto 0);
   tmds_data_n             : out   std_logic_vector(2 downto 0);
   tmds_clk_p              : out   std_logic;
   tmds_clk_n              : out   std_logic;

   -- C64 keyboard on J12; RESTORE is a separate line
   restore_key             : in    std_logic;
   porta_pins              : inout std_logic_vector(7 downto 0);
   portb_pins              : inout std_logic_vector(7 downto 0);

   -- SD card (single slot)
   int_sd_reset            : out   std_logic;
   int_sd_clock            : out   std_logic;
   int_sd_mosi             : out   std_logic;
   int_sd_miso             : in    std_logic;

   -- Joysticks on J10 (port 1) and J11 (port 2), active low, board pullups
   fa_up                   : in    std_logic;
   fa_down                 : in    std_logic;
   fa_left                 : in    std_logic;
   fa_right                : in    std_logic;
   fa_fire                 : in    std_logic;
   fb_up                   : in    std_logic;
   fb_down                 : in    std_logic;
   fb_left                 : in    std_logic;
   fb_right                : in    std_logic;
   fb_fire                 : in    std_logic;

   -- DDR3 256MB (Micron MT41K128M16JT-125:K)
   ddr3_clk_p              : out   std_logic;
   ddr3_clk_n              : out   std_logic;
   ddr3_reset_n            : out   std_logic;
   ddr3_cke                : out   std_logic;
   ddr3_ras_n              : out   std_logic;
   ddr3_cas_n              : out   std_logic;
   ddr3_we_n               : out   std_logic;
   ddr3_addr               : out   std_logic_vector(13 downto 0);
   ddr3_ba                 : out   std_logic_vector(2 downto 0);
   ddr3_dq                 : inout std_logic_vector(15 downto 0);
   ddr3_dqs_p              : inout std_logic_vector(1 downto 0);
   ddr3_dqs_n              : inout std_logic_vector(1 downto 0);
   ddr3_dm                 : out   std_logic_vector(1 downto 0);
   ddr3_odt                : out   std_logic;

   -- QSPI config flash (clock goes through STARTUPE2, not a user pin)
   qspi_csn                : out   std_logic;
   qspi_db                 : inout std_logic_vector(3 downto 0);

   -- On board LEDs (active low)
   led0                    : out   std_logic;
   led1                    : out   std_logic
);
end entity shell_top;

architecture synthesis of shell_top is

   -- The reconfigurable module: black box in the static synthesis, linked
   -- from its own synthesis checkpoint by the DFX flow. This declaration is
   -- the frozen boundary ABI — the RM framework's rm_top must match it
   -- exactly (v5: de-M2M port names — loader_* was qnice_*, mem_* was hr_*,
   -- reset_shell_n_i was reset_m2m_n_i).
   component rm_top is
   port (
      sys_clk_i               : in    std_logic;
      sys_pps_i               : in    std_logic;
      reset_shell_n_i         : in    std_logic;
      reset_core_n_i          : in    std_logic;
      loader_clk_i            : in    std_logic;
      loader_rst_i            : in    std_logic;
      core_clk1_i             : in    std_logic;
      core_clk1_rst_i         : in    std_logic;
      mem_clk_i               : in    std_logic;
      mem_rst_i               : in    std_logic;
      audio_clk_i             : in    std_logic;
      audio_rst_i             : in    std_logic;
      hdmi_clk_i              : in    std_logic;
      hdmi_rst_i              : in    std_logic;
      uart_rx_i               : in    std_logic;
      uart_tx_o               : out   std_logic;
      kb_porta_col_n_o        : out   std_logic_vector(7 downto 0);
      kb_portb_row_n_i        : in    std_logic_vector(7 downto 0);
      kb_portb_charge_o       : out   std_logic;
      kb_restore_n_i          : in    std_logic;
      sd_reset_o              : out   std_logic;
      sd_clk_o                : out   std_logic;
      sd_mosi_o               : out   std_logic;
      sd_miso_i               : in    std_logic;
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
      -- Core-clock service (boundary v2)
      drp_target_o            : out   std_logic_vector(2 downto 0);
      drp_addr_o              : out   std_logic_vector(6 downto 0);
      drp_data_o              : out   std_logic_vector(15 downto 0);
      drp_mask_o              : out   std_logic_vector(15 downto 0);
      drp_req_o               : out   std_logic;
      drp_ack_i               : in    std_logic;
      clkctl_o                : out   std_logic_vector(7 downto 0);
      clkstat_i               : in    std_logic_vector(3 downto 0);
      core_clk0_i             : in    std_logic;
      core_clk0_rst_i         : in    std_logic;
      core_clk2_i             : in    std_logic;
      core_clk2_rst_i         : in    std_logic;
      qspi_clk_o              : out   std_logic;
      qspi_csn_o              : out   std_logic;
      qspi_d_i                : in    std_logic_vector(3 downto 0);
      qspi_d_o                : out   std_logic_vector(3 downto 0);
      qspi_d_oe_o             : out   std_logic_vector(3 downto 0);
      power_led_o             : out   std_logic;
      drive_led_o             : out   std_logic;
      rm_alive_o              : out   std_logic;
      rsv_i                   : in    std_logic_vector(15 downto 0);
      rsv_o                   : out   std_logic_vector(15 downto 0)
   );
   end component rm_top;

   -- Video clock preset service (boundary v1): default preset the shell
   -- boots with and holds while the RP is dark ("010" = 74.25 MHz, 720p)
   constant C_VCLK_SEL_DEFAULT : std_logic_vector(2 downto 0) := "010";

   -- TMDS control-period symbol for {C1,C0} = 00: what the serialisers
   -- emit while the RP is dark (electrically clean, DC-balanced; the
   -- monitor sees sync loss and mutes — that is accepted in v1)
   constant C_TMDS_CTL0 : std_logic_vector(9 downto 0) := "1101010100";

   ---------------------------------------------------------------------------
   -- Clocks and resets
   ---------------------------------------------------------------------------

   signal clk_100       : std_logic;
   signal reset_shell_n : std_logic;
   signal reset_core_n  : std_logic;
   signal ddr3_arst     : std_logic;
   signal sys_pps       : std_logic;

   signal loader_clk    : std_logic;
   signal loader_rst    : std_logic;
   signal audio_clk     : std_logic;
   signal audio_rst     : std_logic;
   signal hdmi_clk      : std_logic;
   signal hdmi_rst      : std_logic;
   signal tmds_clk      : std_logic;
   signal core_clk0     : std_logic;    -- CLKOUT0 core clock (fractional-capable)
   signal core_clk0_rst : std_logic;
   signal core_clk1     : std_logic;    -- CLKOUT1 core clock (integer only)
   signal core_clk1_rst : std_logic;
   signal core_clk2     : std_logic;    -- CLKOUT2 core clock (integer only; over-provisioned, v3)
   signal core_clk2_rst : std_logic;
   signal mem_clk       : std_logic;
   signal mem_rst       : std_logic;

   ---------------------------------------------------------------------------
   -- Loader / decoupling (whole block on loader_clk since v5)
   ---------------------------------------------------------------------------

   signal loader_byte        : std_logic_vector(7 downto 0);
   signal loader_byte_valid  : std_logic;

   -- Loader byte source after the load_ctrl mux (UART or SD walker).
   signal ld_byte            : std_logic_vector(7 downto 0);
   signal ld_valid           : std_logic;

   -- FAT32 walker: two descriptor sources (UART frame via load_ctrl,
   -- RM via desc_proxy), one command interface.
   signal wk_req             : std_logic;
   signal wk_mode            : std_logic;
   signal wk_part            : std_logic_vector(3 downto 0);
   signal wk_start           : std_logic_vector(31 downto 0);
   signal wk_len             : std_logic_vector(31 downto 0);
   signal wk_busy            : std_logic;
   signal wk_done            : std_logic;
   signal wk_err             : std_logic;
   signal wk_diag            : std_logic_vector(7 downto 0);
   signal wk_diag_r1         : std_logic_vector(7 downto 0);
   signal wk_byte            : std_logic_vector(7 downto 0);
   signal wk_valid           : std_logic;

   signal lc_req             : std_logic;   -- from load_ctrl (UART)
   signal lc_mode            : std_logic;
   signal lc_part            : std_logic_vector(3 downto 0);
   signal lc_start           : std_logic_vector(31 downto 0);
   signal lc_len             : std_logic_vector(31 downto 0);

   signal dp_req             : std_logic;   -- from desc_proxy (RM)
   signal dp_mode            : std_logic;
   signal dp_part            : std_logic_vector(3 downto 0);
   signal dp_start           : std_logic_vector(31 downto 0);
   signal dp_len             : std_logic_vector(31 downto 0);

   -- SD sector engine (walker side).
   signal sdc_init           : std_logic;
   signal sdc_rd             : std_logic;
   signal sdc_lba            : std_logic_vector(31 downto 0);
   signal sdc_done           : std_logic;
   signal sdc_err            : std_logic;
   signal sdc_diag           : std_logic_vector(7 downto 0);
   signal sdc_diag_r1        : std_logic_vector(7 downto 0);
   signal sdc_byte           : std_logic_vector(7 downto 0);
   signal sdc_valid          : std_logic;

   -- Walker-owned SD pins (muxed onto the pads while a load runs).
   signal wk_sd_cs_n         : std_logic;
   signal wk_sd_clk          : std_logic;
   signal wk_sd_mosi         : std_logic;

   -- Status echo (load_ctrl -> uart_tx, muxed onto the TX pad).
   signal echo_data          : std_logic_vector(7 downto 0);
   signal echo_send          : std_logic;
   signal echo_busy          : std_logic;
   signal echo_txd           : std_logic;

   signal loader_idle        : std_logic;

   -- Descriptor proxy <-> RM reserved pins.
   signal rm_rsv_o           : std_logic_vector(15 downto 0);
   signal rsv_to_rm          : std_logic_vector(15 downto 0);
   signal decouple           : std_logic;   -- loader domain (loader_clk)
   signal rm_reset           : std_logic;   -- loader domain
   signal loader_status      : std_logic_vector(1 downto 0);
   signal loader_progress    : unsigned(19 downto 0);

   -- ICAP config-engine evidence (sticky per load attempt) + LED verdict
   signal icap_attempt       : std_logic;
   signal icap_dalign        : std_logic;
   signal icap_cfgerr        : std_logic;
   signal icap_abort         : std_logic;
   signal verdict_cnt        : unsigned(25 downto 0) := (others => '0');
   signal led_verdict        : std_logic;

   signal decouple_sys       : std_logic;
   signal rm_reset_sys       : std_logic;
   signal decouple_mem       : std_logic;
   signal decouple_hdmi      : std_logic;
   signal rm_rst_loader      : std_logic;
   signal rm_rst_core1       : std_logic;   -- rm_reset CDC'd to core_clk1 domain
   signal rm_rst_mem         : std_logic;
   signal rm_rst_audio       : std_logic;
   signal rm_rst_hdmi        : std_logic;
   signal rm_rst_core0       : std_logic;   -- rm_reset CDC'd to core_clk0 domain
   signal rm_rst_core2       : std_logic;   -- rm_reset CDC'd to core_clk2 domain

   ---------------------------------------------------------------------------
   -- RM boundary signals (raw = as driven by the RM; use gated versions!)
   ---------------------------------------------------------------------------

   signal rm_uart_tx         : std_logic;
   signal rm_kb_porta_col_n  : std_logic_vector(7 downto 0);
   signal rm_kb_portb_charge : std_logic;
   signal rm_sd_reset        : std_logic;
   signal rm_sd_clk          : std_logic;
   signal rm_sd_mosi         : std_logic;

   signal rm_mem_write         : std_logic;
   signal rm_mem_read          : std_logic;
   signal rm_mem_address       : std_logic_vector(31 downto 0);
   signal rm_mem_writedata     : std_logic_vector(15 downto 0);
   signal rm_mem_byteenable    : std_logic_vector(1 downto 0);
   signal rm_mem_burstcount    : std_logic_vector(7 downto 0);

   signal rm_tmds            : std_logic_vector(29 downto 0);
   signal rm_vclk_sel        : std_logic_vector(2 downto 0);

   -- Core-clock service (boundary v2): raw RM outputs
   signal rm_drp_target      : std_logic_vector(2 downto 0);
   signal rm_drp_addr        : std_logic_vector(6 downto 0);
   signal rm_drp_data        : std_logic_vector(15 downto 0);
   signal rm_drp_mask        : std_logic_vector(15 downto 0);
   signal rm_drp_req         : std_logic;
   signal rm_clkctl          : std_logic_vector(7 downto 0);

   signal rm_power_led       : std_logic;
   signal rm_drive_led       : std_logic;
   signal rm_alive           : std_logic;

   -- QSPI flash pass-through (boundary v3): raw RM outputs
   signal rm_qspi_clk        : std_logic;
   signal rm_qspi_csn        : std_logic;
   signal rm_qspi_d          : std_logic_vector(3 downto 0);
   signal rm_qspi_d_oe       : std_logic_vector(3 downto 0);

   ---------------------------------------------------------------------------
   -- Core-clock service (boundary v2): clkctl CDC + stability filter
   --
   -- clkctl_o from the RM is quasi-static (stability-filtered before use).
   -- Same 64-cycle filter as vclk_sel; freeze while RP is dark.
   -- Bit mapping: [0]=core_clk0 mux, [1]=core_clk1 mux, [2]=cascade_en,
   --              [3]=CORE_A rst, [4]=CORE_B rst, [5]=core_clk2 mux (v3),
   --              [6:7]=reserved
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
   signal mem_stall          : std_logic;   -- mem domain: decoupled OR memory not ready
   signal mem_ready_sys      : std_logic;   -- calib_complete CDC'd to clk_100 (clkstat[2])

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

   signal ddr3_calib_complete : std_logic;

begin

   ---------------------------------------------------------------------------
   -- Clock generation (all MMCMs/PLLs live here, in the static)
   ---------------------------------------------------------------------------

   i_clk_wukong : entity work.clk_wukong
      port map (
         sys_clk_50_i  => clk_in,
         sys_clk_100_o => clk_100,
         sys_locked_o  => open
      ); -- i_clk_wukong

   i_reset_manager : entity work.reset_manager
      generic map (
         BOARD_CLK_SPEED => 100_000_000
      )
      port map (
         CLK             => clk_100,
         RESET_N         => reset_button,
         reset_shell_n_o => reset_shell_n,
         reset_core_n_o  => reset_core_n
      ); -- i_reset_manager

   i_shell_clk_base : entity work.shell_clk_base
      port map (
         sys_clk_i          => clk_100,
         sys_rstn_i         => reset_shell_n,
         core_rstn_i        => reset_core_n,
         loader_clk_o       => loader_clk,
         loader_rst_o       => loader_rst,
         mem_clk_o          => open,              -- mem_clk comes from i_ddr3_wrapper
         mem_clk_del_o      => open,
         mem_delay_refclk_o => open,
         mem_rst_o          => open,
         audio_clk_o        => audio_clk,
         audio_rst_o        => audio_rst,
         sys_pps_o          => sys_pps
      ); -- i_shell_clk_base

   -- Boundary v1: the pixel clock follows the RM's preset request. The DRP
   -- rewrite FSM, XAPP888 preset ROM and reset/lock sequencing all live
   -- inside video_out_clock; rsto is held through relock and reaches the
   -- RM as hdmi_rst — that IS the feedback, there is no ack.
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
   -- CORE_A boots at the democore preset (54 MHz) so RMs that never use
   -- the DRP service get v1-identical behaviour.

   -- clkstat[2] = generic memory-subsystem-ready (v3, informational: the
   -- fence's waitrequest force is what guarantees correctness; this bit lets
   -- an RM display "memory initializing" or defer optional work)
   i_cdc_mem_ready : xpm_cdc_single
      port map ( src_clk => mem_clk, src_in => ddr3_calib_complete,
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
         -- Stability-filtered control from RM (clkctl bit mapping per the
         -- boundary spec; v3: bit 5 = core_clk2 mux select)
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
   -- Loader: UART/SD byte source -> sync-word-gated ICAP streamer
   --
   -- The whole loader block runs on loader_clk (50 MHz, MMCM-conditioned) —
   -- backported from the R6 shell (round 5): on the R6, ICAPE2 clocked at
   -- 100 MHz sat exactly at its spec limit and rejected every partial; at
   -- 50 MHz that failure class is off the table. The byte sources (UART,
   -- SD walker) share the domain so no stream CDC is needed.
   ---------------------------------------------------------------------------

   -- 2 MBd: board's USB-serial verified at 2 Mbps (mega65-core use);
   -- 50 MHz / 2 MBd = 25 clks/bit exactly (zero sampling error).
   -- Sender baud must match.
   i_uart_rx : entity work.uart_rx
      generic map (
         CLK_HZ => 50_000_000,
         BAUD   => 2_000_000
      )
      port map (
         clk        => loader_clk,
         rst        => loader_rst,
         rxd        => rsrx,
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
         byte_in      => ld_byte,
         byte_valid   => ld_valid,
         decouple     => decouple,
         rm_reset     => rm_reset,
         status       => loader_status,
         stat_attempt => icap_attempt,
         stat_dalign  => icap_dalign,
         stat_cfgerr  => icap_cfgerr,
         stat_abort   => icap_abort
      ); -- i_icap_loader

   -- Loader progress (blinks led1 during a swap): count streamed bytes
   p_progress : process (loader_clk)
   begin
      if rising_edge(loader_clk) then
         if decouple = '0' then
            loader_progress <= (others => '0');
         elsif ld_valid = '1' then
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

   -- Post-attempt verdict for led1 (held until the next load or a
   -- long-press shell reset): solid = config engine never synced,
   -- slow blink = engine synced but flagged CFGERR/abort, fast blink =
   -- stream accepted cleanly.
   led_verdict <= '1'             when icap_dalign = '0' else
                  verdict_cnt(25) when icap_cfgerr = '1' or icap_abort = '1' else
                  verdict_cnt(22);

   ---------------------------------------------------------------------------
   -- SD -> ICAP load path (FAT32 core loader, boundary v4; whole path in
   -- the loader domain)
   ---------------------------------------------------------------------------

   loader_idle <= '1' when loader_status = "00" else '0';

   -- load_ctrl: UART pass-through + 14-byte "M65D" descriptor frames +
   -- byte-source mux into the ICAP loader + status echo (host test path;
   -- the menu RM uses the desc_proxy instead).
   i_load_ctrl : entity work.load_ctrl
      port map (
         clk         => loader_clk,
         rst         => loader_rst,
         uart_byte   => loader_byte,
         uart_valid  => loader_byte_valid,
         loader_idle => loader_idle,
         ld_byte     => ld_byte,
         ld_valid    => ld_valid,
         wk_req      => lc_req,
         wk_mode     => lc_mode,
         wk_part     => lc_part,
         wk_start    => lc_start,
         wk_len      => lc_len,
         wk_busy     => wk_busy,
         wk_done     => wk_done,
         wk_err      => wk_err,
         wk_diag     => wk_diag,
         wk_diag_r1  => wk_diag_r1,
         wk_byte     => wk_byte,
         wk_valid    => wk_valid,
         tx_data     => echo_data,
         tx_send     => echo_send,
         tx_busy     => echo_busy
      ); -- i_load_ctrl

   -- desc_proxy: the RM-facing descriptor register file over the reserved
   -- boundary pins (menu firmware writes partition/cluster/length + GO).
   i_desc_proxy : entity work.desc_proxy
      port map (
         clk         => loader_clk,
         rst         => loader_rst,
         decouple    => decouple,
         rsv_from_rm => rm_rsv_o,
         rsv_to_rm   => rsv_to_rm,
         wk_req      => dp_req,
         wk_mode     => dp_mode,
         wk_part     => dp_part,
         wk_start    => dp_start,
         wk_len      => dp_len,
         wk_busy     => wk_busy,
         wk_err      => wk_err,
         wk_diag     => wk_diag
      ); -- i_desc_proxy

   -- Two descriptor sources, one walker: the proxy wins a same-cycle tie
   -- (never happens in practice); the walker ignores requests while busy.
   wk_req   <= lc_req or dp_req;
   wk_mode  <= dp_mode  when dp_req = '1' else lc_mode;
   wk_part  <= dp_part  when dp_req = '1' else lc_part;
   wk_start <= dp_start when dp_req = '1' else lc_start;
   wk_len   <= dp_len   when dp_req = '1' else lc_len;

   i_fat32_walker : entity work.fat32_walker
      port map (
         clk         => loader_clk,
         rst         => loader_rst,
         req         => wk_req,
         mode_chain  => wk_mode,
         part_sel    => wk_part,
         start       => wk_start,
         byte_len    => wk_len,
         byte_out    => wk_byte,
         byte_valid  => wk_valid,
         busy        => wk_busy,
         done        => wk_done,
         err         => wk_err,
         diag_code   => wk_diag,
         diag_r1     => wk_diag_r1,
         sdc_init    => sdc_init,
         sdc_rd      => sdc_rd,
         sdc_lba     => sdc_lba,
         sdc_done    => sdc_done,
         sdc_err     => sdc_err,
         sdc_diag    => sdc_diag,
         sdc_diag_r1 => sdc_diag_r1,
         sdc_byte    => sdc_byte,
         sdc_valid   => sdc_valid
      ); -- i_fat32_walker

   i_sd_sector : entity work.sd_sector
      generic map (
         CLK_HZ => 50_000_000
      )
      port map (
         clk        => loader_clk,
         rst        => loader_rst,
         init_req   => sdc_init,
         rd_req     => sdc_rd,
         lba        => sdc_lba,
         byte_out   => sdc_byte,
         byte_valid => sdc_valid,
         ready      => open,
         done       => sdc_done,
         err        => sdc_err,
         diag_state => sdc_diag,
         diag_r1    => sdc_diag_r1,
         sd_cs_n    => wk_sd_cs_n,
         sd_clk     => wk_sd_clk,
         sd_mosi    => wk_sd_mosi,
         sd_miso    => int_sd_miso
      ); -- i_sd_sector

   -- Status echo transmitter (2 MBd like the loader RX). Echo bytes take
   -- priority over the RM's TX for their ~5 us — at worst a corrupted
   -- console character, in exchange for host-visible load diagnostics.
   i_uart_tx : entity work.uart_tx
      generic map (
         CLK_HZ => 50_000_000,
         BAUD   => 2_000_000
      )
      port map (
         clk  => loader_clk,
         rst  => loader_rst,
         data => echo_data,
         send => echo_send,
         txd  => echo_txd,
         busy => echo_busy
      ); -- i_uart_tx

   ---------------------------------------------------------------------------
   -- Decouple/reset distribution into the boundary clock domains
   ---------------------------------------------------------------------------

   -- Loader-domain outputs crossed back into the sys domain for the
   -- consumers that live there (vclk/clkctl freeze, drp_proxy, RM resets).
   i_cdc_dec_sys : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => decouple,
                 dest_clk => clk_100, dest_out => decouple_sys );

   i_cdc_rst_sys : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => clk_100, dest_out => rm_reset_sys );

   i_cdc_dec_mem : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => decouple,
                 dest_clk => mem_clk, dest_out => decouple_mem );

   i_cdc_dec_hdmi : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => decouple,
                 dest_clk => hdmi_clk, dest_out => decouple_hdmi );

   -- The loader itself runs in the loader domain, so no CDC here.
   rm_rst_loader <= rm_reset;

   i_cdc_rst_core1 : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => core_clk1, dest_out => rm_rst_core1 );

   i_cdc_rst_mem : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => mem_clk, dest_out => rm_rst_mem );

   i_cdc_rst_audio : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => audio_clk, dest_out => rm_rst_audio );

   i_cdc_rst_hdmi : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => hdmi_clk, dest_out => rm_rst_hdmi );

   i_cdc_rst_core0 : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => core_clk0, dest_out => rm_rst_core0 );

   i_cdc_rst_core2 : xpm_cdc_single
      port map ( src_clk => loader_clk, src_in => rm_reset,
                 dest_clk => core_clk2, dest_out => rm_rst_core2 );

   ---------------------------------------------------------------------------
   -- The reconfigurable module
   ---------------------------------------------------------------------------

   RM : rm_top
      port map (
         sys_clk_i           => clk_100,
         sys_pps_i           => sys_pps,
         -- rm_reset (loader) resets the whole RM after a swap; the RM-internal
         -- reset chain then propagates it into every RM-internal domain
         reset_shell_n_i     => reset_shell_n and not rm_reset_sys,
         reset_core_n_i      => reset_core_n and not rm_reset_sys,
         loader_clk_i        => loader_clk,
         loader_rst_i        => loader_rst or rm_rst_loader,
         core_clk1_i         => core_clk1,
         core_clk1_rst_i     => core_clk1_rst or rm_rst_core1,
         mem_clk_i           => mem_clk,
         mem_rst_i           => mem_rst or rm_rst_mem,
         audio_clk_i         => audio_clk,
         audio_rst_i         => audio_rst or rm_rst_audio,
         hdmi_clk_i          => hdmi_clk,
         hdmi_rst_i          => hdmi_rst or rm_rst_hdmi,
         uart_rx_i           => rsrx,
         uart_tx_o           => rm_uart_tx,
         kb_porta_col_n_o    => rm_kb_porta_col_n,
         kb_portb_row_n_i    => portb_pins,
         kb_portb_charge_o   => rm_kb_portb_charge,
         kb_restore_n_i      => restore_key,
         sd_reset_o          => rm_sd_reset,
         sd_clk_o            => rm_sd_clk,
         sd_mosi_o           => rm_sd_mosi,
         sd_miso_i           => int_sd_miso,
         joy_1_up_n_i        => fa_up,
         joy_1_down_n_i      => fa_down,
         joy_1_left_n_i      => fa_left,
         joy_1_right_n_i     => fa_right,
         joy_1_fire_n_i      => fa_fire,
         joy_2_up_n_i        => fb_up,
         joy_2_down_n_i      => fb_down,
         joy_2_left_n_i      => fb_left,
         joy_2_right_n_i     => fb_right,
         joy_2_fire_n_i      => fb_fire,
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
         core_clk0_i         => core_clk0,
         core_clk0_rst_i     => core_clk0_rst or rm_rst_core0,
         core_clk2_i         => core_clk2,
         core_clk2_rst_i     => core_clk2_rst or rm_rst_core2,
         qspi_clk_o          => rm_qspi_clk,
         qspi_csn_o          => rm_qspi_csn,
         qspi_d_i            => qspi_db,
         qspi_d_o            => rm_qspi_d,
         qspi_d_oe_o         => rm_qspi_d_oe,
         power_led_o         => rm_power_led,
         drive_led_o         => rm_drive_led,
         rm_alive_o          => rm_alive,
         rsv_i               => rsv_to_rm,
         rsv_o               => rm_rsv_o
      ); -- RM

   ---------------------------------------------------------------------------
   -- Tier-0 outputs with decoupling
   ---------------------------------------------------------------------------

   -- TX pad: status-echo bytes win over the RM console for their duration
   -- (~5 us each); idle high while the RP is dark and no echo runs.
   uart_txd <= echo_txd   when echo_busy = '1' else
               rm_uart_tx when decouple = '0'  else
               '1';

   -- C64 keyboard: open-drain column drivers, row inputs with charge pump;
   -- release everything while the RP is dark
   porta_gen : for i in 0 to 7 generate
      porta_pins(i) <= '0' when rm_kb_porta_col_n(i) = '0' and decouple = '0' else 'Z';
   end generate porta_gen;

   portb_pins <= (others => '1') when rm_kb_portb_charge = '1' and decouple = '0' else (others => 'Z');

   -- SD pads, three-way: the walker owns them for the whole of a load
   -- (from GO, i.e. before decouple — the requesting RM must keep off the
   -- SD after firing a descriptor); otherwise the RM when coupled; parked
   -- when the RP is dark.
   int_sd_reset <= wk_sd_cs_n  when wk_busy = '1'  else
                   rm_sd_reset when decouple = '0' else '1';
   int_sd_clock <= wk_sd_clk   when wk_busy = '1'  else
                   rm_sd_clk   when decouple = '0' else '0';
   int_sd_mosi  <= wk_sd_mosi  when wk_busy = '1'  else
                   rm_sd_mosi  when decouple = '0' else '1';

   -- QSPI flash pass-through (boundary v3): CS/data park inactive while the
   -- RP is dark (the ICAP loader must never race an RM flash transaction).
   qspi_csn <= rm_qspi_csn when decouple = '0' else '1';
   qspi_gen : for i in 0 to 3 generate
      qspi_db(i) <= rm_qspi_d(i) when rm_qspi_d_oe(i) = '1' and decouple = '0' else 'Z';
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

   -- LEDs (active low): led0 = power led from the RM (masked while the RP
   -- is dark). led1, in priority order: loader-progress toggle during a
   -- swap (every 16K bytes); post-attempt ICAP verdict (v5, see
   -- led_verdict above) once any load has been attempted; otherwise
   -- drive led / solid while DDR3 calibrates.
   led0 <= not (rm_power_led and not decouple);
   led1 <= not loader_progress(14) when decouple = '1'     else
           not led_verdict         when icap_attempt = '1' else
           not (rm_drive_led or not ddr3_calib_complete);

   ---------------------------------------------------------------------------
   -- Avalon fence + DDR3 (mem domain)
   ---------------------------------------------------------------------------

   -- Pass requests while coupled; when decouple asserts, the SHELL completes
   -- any write burst in flight with byteenable-"00" dummy beats (Avalon
   -- no-ops — the surviving framebuffer content must not be stomped), then
   -- blocks everything until re-couple.
   --
   -- The shell must inject those beats itself: the loader asserts rm_reset
   -- together with decouple, so the RM's master stops instantly and will
   -- never deliver the remaining beats.  The original fence waited for the
   -- RM to finish ("fence_pass while wr_beats_left /= 0") — that left the
   -- counter stranded nonzero after the first swap, which held the fence
   -- OPEN throughout the *next* load; the RP's glitching partition outputs
   -- then fed garbage bursts into the DDR3 chain and wedged it (black core
   -- video, overlay/audio alive, only a full reconfig recovers).
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

   -- Drains the orphaned burst (flush beats decrement wr_beats_left in
   -- p_fence like any accepted write); a fresh header cannot start while
   -- decoupled, so no garbage burstcount can be loaded.
   fence_flush <= '1' when decouple_mem = '1' and wr_beats_left /= 0 else '0';

   -- Memory-ready stalling (boundary v3): while decoupled OR the DDR3 is
   -- (re)calibrating, force waitrequest toward the RM and pass no commands.
   -- Avalon allows indefinite waitrequest, so RM commands stall and complete
   -- once the memory serves instead of being accepted-and-dropped — a read
   -- accepted during the ~2 s recalibration window after a button reset
   -- never returns data, and ascal's 2-line preload has no timeout (the
   -- cold-boot black / long-press stripe wedge; hw-confirmed 2026-07-13,
   -- countermeasure proven as an av-pipeline reset gate in the flat debug
   -- build).  calib_complete is in the controller clock domain = mem_clk.
   mem_stall <= decouple_mem or not ddr3_calib_complete;

   avm_write      <= (rm_mem_write and not mem_stall) or fence_flush;
   avm_read       <= rm_mem_read and not mem_stall;
   avm_byteenable <= rm_mem_byteenable when decouple_mem = '0' else "00";

   i_ddr3_wrapper : entity work.ddr3_wrapper_wukong
      port map (
         sys_clk_i           => clk_100,
         rst_i               => ddr3_arst,
         ctrl_clk_o          => mem_clk,
         ctrl_rst_o          => mem_rst,
         avm_write_i         => avm_write,
         avm_read_i          => avm_read,
         avm_address_i       => rm_mem_address,
         avm_writedata_i     => rm_mem_writedata,
         avm_byteenable_i    => avm_byteenable,
         avm_burstcount_i    => rm_mem_burstcount,
         avm_readdata_o      => avm_readdata,
         avm_readdatavalid_o => avm_readdatavalid,
         avm_waitrequest_o   => avm_waitrequest,
         calib_complete_o    => ddr3_calib_complete,
         ddr3_clk_p_o        => ddr3_clk_p,
         ddr3_clk_n_o        => ddr3_clk_n,
         ddr3_reset_n_o      => ddr3_reset_n,
         ddr3_cke_o          => ddr3_cke,
         ddr3_ras_n_o        => ddr3_ras_n,
         ddr3_cas_n_o        => ddr3_cas_n,
         ddr3_we_n_o         => ddr3_we_n,
         ddr3_addr_o         => ddr3_addr,
         ddr3_ba_o           => ddr3_ba,
         ddr3_dq_io          => ddr3_dq,
         ddr3_dqs_p_io       => ddr3_dqs_p,
         ddr3_dqs_n_io       => ddr3_dqs_n,
         ddr3_dm_o           => ddr3_dm,
         ddr3_odt_o          => ddr3_odt
      ); -- i_ddr3_wrapper

   -- DDR3 resets on the buttons only — NOT during an RM swap, so RAM
   -- content survives partial reconfiguration (framebuffer hand-over)
   ddr3_arst <= (not reset_shell_n) or (not reset_core_n);

   ---------------------------------------------------------------------------
   -- HDMI back end (boundary v1): park mux + serialisers only. The TMDS
   -- encoder lives in the RM; while the RP is dark the lanes emit a
   -- control-period symbol (monitor mutes — accepted, LEDs show loading).
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
            out_p   => tmds_data_p(i),
            out_n   => tmds_data_n(i)
         );
   end generate gen_hdmi_data;

   i_serialiser_clk : entity work.serialiser_10to1_selectio
      port map (
         rst     => hdmi_rst,
         clk     => hdmi_clk,
         clk_x5  => tmds_clk,
         d       => "0000011111",
         out_p   => tmds_clk_p,
         out_n   => tmds_clk_n
      ); -- i_serialiser_clk

end architecture synthesis;
