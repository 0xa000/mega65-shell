> **Historical (pre-v5 names).** This spec predates the mega65-shell repo;
> signal names follow the old M2M-flavoured scheme. v5 rename map:
> `qnice_clk/qnice_rst` -> `loader_clk/loader_rst`, `hr_clk/hr_rst` ->
> `mem_clk/mem_rst`, `reset_m2m_n` -> `reset_shell_n`. Semantics are
> unchanged; see ../BOUNDARY.md for the current contract.
>
> **Erratum (2026-07-21).** QSPI is listed below as parked static / not
> in the ABI — that was the 2026-07-11 decision and was superseded by
> the boundary v3 QSPI pass-through (BOUNDARY-V3.md), which the R6
> shell implements: qspi data/CS go through the boundary, the flash
> clock is proxied via the shell-owned STARTUPE2.

# Boundary R6 — MEGA65 R6 static shell (DRAFT)

Port of the hardware-verified Wukong boundary v2 (BOUNDARY-V2.md) to the
MEGA65 R6 mainboard (xc7a200tfbg484-2). Work lives on branch `dfx-r6` of
the MiSTer2MEGA65 fork (worktree `MiSTer2MEGA65-r6`), based on upstream
V2.0.1 — the same base commit as the Wukong work, but a fresh branch: no
Wukong board code is carried over. Board-agnostic DFX components
(shell_core_clk, drp_proxy, icap_loader, uart_rx, clk_drp_master,
mmcm_drp_table.py) are copied to a board-neutral home `M2M/vhdl/dfx/`.

Decisions taken 2026-07-11 (user):

* Boundary = v2 services + full R6 peripheral set **including IEC and the
  complete cartridge port**. Parked static (not in the ABI): Ethernet,
  internal FDC, PMOD headers, QSPI flash.
* No R6 hardware on the developer's bench — validation is by community
  testers (both `.cor`-only and TE0790 JTAG/UART tiers exist). Build-time
  verification (pr_verify, STA, utilization sanity) carries more weight
  than usual; deliverables must be tester-friendly.

## Inherited from boundary v2 (unchanged semantics)

* **Core-clock service**: CORE_A/CORE_B MMCMs behind BUFGMUX_CTRL,
  write-only DRP proxy (target,addr,data,mask + toggle handshake),
  clkctl[7:0] with 64-cycle stability filter, clkstat lock bits, generic
  fractional-capable core_clk0 (CLKOUT0) + integer core_clk1 (CLKOUT1).
  MMCM state persists across swaps; **every RM programs its clocks at
  wake** (clk_drp_master + generated table); the 54 MHz default is a
  parking state, not a contract.
* **Video seam** = TMDS words (30 wires @ hdmi_clk): TMDS encoder,
  InfoFrames and audio data islands are RM-side; shell owns only the
  OSERDES serialisers and parks the lanes at CTL0 "1101010100" while the
  RP is dark. vclk_sel[2:0] preset request into video_out_clock's DRP
  FSM, same CDC + 64-cycle filter, same invalid-preset rejection.
* **Memory service**: ONE fenced Avalon-MM slave (16-bit data, 32-bit
  address, burstcount 8); the RM brings its own arbiter
  (avm_arbit/qnice2hyperram chains stay RM-side). The fence completes an
  orphaned write burst with byteenable-"00" dummy beats injected by the
  SHELL (never wait for the decoupled side), RM requests hard-gated by
  decouple. RAM content survives swaps.
* **Loader**: sync-word-gated byte→ICAP streamer, UART byte source at
  2 MBd (100 MHz / 2 MBd = 50 clks/bit exact; TE0790 FT2232 handles it),
  absolute-time timeouts, drives decouple + rm_reset (ORed into all
  boundary resets, RESET_AFTER_RECONFIG on the RP).
* rsv_i/rsv_o 16+16 reserved pins; rm_alive watchdog seed; the RM-side
  framework/QNICE/OSM/vdrives are a library each RM links in.

## R6-specific shell differences vs the Wukong shell

* **Input clock is already 100 MHz** (`clk_i`) — no front PLL; a BUFG'd
  copy is the sys/DRP/ICAP clock and the CLKIN of all shell MMCMs.
* **HyperRAM replaces UberDDR3** behind the same Avalon fence: upstream's
  own controller (M2M/vhdl/controllers/hyperram/) moves shell-side
  together with its IOB tri-states, driven by clk_m2m's stock hr clocks
  (hr_clk/hr_clk_del 100 MHz + delay_refclk 200 MHz — CLKOUT1/2/3 of the
  clk_m2m hr MMCM, no wrapper re-gearing). The IS66WVH8M8 self-refreshes:
  content survives swaps as long as the shell never toggles hr_reset_o —
  the controller resets on the board reset button only, exactly like the
  Wukong DDR3 (`ddr3_arst` rule).
* **Analog audio exists**: the AK4432 DAC driver (`i_audio`, upstream
  top-level component, audio_clk 12.288 MHz domain) stays shell-side; the
  boundary carries filtered PCM (audio_left/right, signed 16-bit,
  audio_clk domain — the seam upstream already has between framework and
  top). Parked = zeros (silence, DAC stays powered and clocked).
* **Analog video exists**: VGA RGB + syncs + VDAC controls cross the
  boundary raw; `vdac_clk` is plain fabric forwarding of the RM's video
  clock (upstream: `vdac_clk_o <= video_clk_i`, no ODDR), so it passes
  through a partition pin like any net. Parked = RGB black, syncs
  inactive, vdac_blank_n low. These pins carry no output-delay
  constraints upstream; the shell's unregistered park mux adds one LUT
  and keeps that (non-)guarantee.
* **LED caveat**: the MEGA65 power/drive LEDs sit on the *keyboard* and
  are driven through the smart-keyboard serial protocol — RM-side. While
  the RP is dark the shell parks kb_io*, so there is **no user-visible
  load indicator on a closed case**; the shell blinks the three
  mainboard LEDs (led_g_n/led_r_n/led) with loader progress instead.
  A shell-side minimal kbd-LED speaker is possible later without an ABI
  change (shell owns the pins and the park mux).

## RM boundary port groups (rm_top_r6)

Clock/reset/service pins identical to v2: sys_clk/sys_pps,
reset_m2m_n/reset_core_n, qnice_clk/rst, audio_clk/rst, hdmi_clk/rst,
hr_clk/rst, core_clk0/core_clk0_rst, core_clk1/core_clk1_rst, DRP proxy
bus, clkctl/clkstat, vclk_sel, mem_* Avalon master, tmds[29:0],
uart_rx/uart_tx, rm_alive, rsv_i/rsv_o. power_led/drive_led map to the
mainboard green/red LEDs (the keyboard LEDs are RM-side via kb_io).

New/changed peripheral groups (RM side; direction as seen from the RM;
park value = what the shell drives on the pin while the RP is dark):

| Group | Pins (RM view) | Domain | Park |
|---|---|---|---|
| Smart keyboard | kb_io0_o, kb_io1_o; kb_io2_i | qnice (framework samples) | io0/io1 = '0' |
| SD ext (back) | sd_reset/clk/mosi_o; sd_miso/cd/d1/d2_i | qnice | reset '1', clk '0', mosi '1' |
| SD int (bottom) | sd2_reset/clk/mosi_o; sd2_miso/cd/wp/d1/d2_i | qnice | idem |
| Joystick 1/2 in | joy_{1,2}_{up,down,left,right,fire}_n_i | async (debounced RM-side) | — |
| Joystick 1/2 out | joy_{1,2}_{up,down,left,right,fire}_n_o | main (RM) | '1' (float — board drives low only) |
| Paddles | paddle_i[3:0]; paddle_drain_o | qnice | drain '0' |
| VGA/VDAC | vga_red/green/blue_o[7:0], vga_hs/vs_o, vdac_clk_o, vdac_sync_n_o, vdac_blank_n_o | video (RM-internal) | black, syncs '1', blank_n '0', clk '0' |
| Audio PCM | audio_left_o[15:0], audio_right_o[15:0] (signed) | audio | 0 (silence) |
| HDMI aux | hdmi_hpd_i | async | — |
| I2C ×6 | named in/out pairs per bus (no packed vectors): {fpga, grove, i2c, hdmi, vga, audio}_{scl,sda}_{in_i,out_o} | qnice | out '1' (released) |
| IEC | iec_reset_n_o, iec_atn_n_o, iec_clk_en_o, iec_clk_n_o, iec_data_en_o, iec_data_n_o, iec_srq_en_o, iec_srq_n_o; iec_clk_n_i, iec_data_n_i, iec_srq_n_i | main (RM) | en '0' (shell inverts to _en_n_o '1' = disabled), levels '1' |
| Cartridge | per MEGA65_Core V2.0.1 ABI: cart_en_o, cart_phi2_o, cart_dotclock_o, cart_dma_i; oe/in/out triples for reset, game, exrom, nmi, irq, roml, romh; cart_ctrl_oe_o + ba/rw/io1/io2 in/out; cart_addr_oe_o + cart_a in/out[15:0]; cart_data_oe_o + cart_d in/out[7:0] | main (RM) | flat-democore state: cart_en_o '1' (the R5/R6 board bug needs the port enabled for joystick 2 to work), ALL oe '0' → every driver tri-stated, dirs Port→FPGA, phi2/dotclock '0' |

The IEC/cart pin set is exactly the "C64 specific ports" block of the
V2.0.1 `MEGA65_Core` entity — the democore already implements (ties off)
these, so even the minimal RM satisfies the ABI without new code, and
C64MEGA65's CORE maps 1:1.

Tri-state IOBs, open-collector emulation (I2C, IEC enables, keyboard) and
the cart direction/enable pin logic stay shell-side, copied verbatim from
`top_mega65-r6.vhd`, each gated by decouple to its park value.

Parked static, not in the ABI: Ethernet PHY, internal floppy (FDC), PMOD
headers + enables, QSPI (qspidb 'Z', csn '1'), dbg_io_11 'Z',
kb JTAG chain (kb_tck/tms/tdi '0', kb_jtagen '0'), joystick_5v_disable
'0', vdac_psave_n '1', hdmi_hiz_en '0', hdmi_ls_oe_n '0',
audio i2cfil '0' + pdn handled by shell i_audio.

**SDRAM (decided 2026-07-11): parked static for now; when a core needs
it, the controller goes INTO THE SHELL** behind a second Avalon slave
(mem2_*), like the HyperRAM — NOT raw pins through the boundary.
Rationale: with raw pins the SDRAM's IOB-adjacent launch/capture
registers would sit RM-side with a partition pin between register and
IOB, preventing IOB packing — so t_co/t_su would re-derive with every
RM's place-and-route, putting per-core board-I/O timing risk on every
rebuild (exactly what the shell-SDK model exists to avoid). A shell
controller proves I/O timing once, in the locked static; the fence is
simpler than the HyperRAM one since SDRAM content carries no
swap-persistence guarantee (plain request gate). No controller to lift
from M2M (checked: upstream/develop = V2.0.1 + README only); candidates
when the ABI bump happens: MJoergen's Avalon SDRAM work, mega65-core's
R6 SDRAM controller, or a MiSTer sdram.sv adaptation.

## Deliverables / test tiers

1. `config_a.bit` (full: shell + democore RM) + `.cor` packaging for a
   QSPI slot — flashable by ANY R6 owner via the MEGA65 flasher;
   validates shell clocks, HyperRAM, HDMI, VGA, audio, keyboard, SD.
2. Partial `.bin`s (democore, democore-inverted) + `send_partial.py` at
   2 MBd — swap testing for TE0790 owners.
3. pr_verify across the whole catalog before anything ships.

## Build staging

1. **DONE** — flat R6 democore (`CORE/r6-build.tcl`, non-project;
   auto_detect_xpm + post-synth ascal reset_na false path carried from
   the Wukong flow) builds clean: WNS +0.282, 0 violations, 11% LUT.
2. **DONE** (dfx-r6 ae103fb) — shell_top_r6 + rm_top_r6 (168 boundary
   ports, G_INVERT_VIDEO variant generic) + framework_rm re-derived from
   stock framework.vhd (cut: clk_m2m + reset_manager out, i_hyperram out
   → Avalon export, av_pipeline cut at TMDS words, VGA/audio PCM
   exported, I2C split into named in/out pairs; m2m_keyb and paddles
   KEPT; mega65_rm additionally ties off the IEC outputs stock
   mega65.vhd leaves undriven — they are partition pins now). Both tops
   elaborate clean; component decl checked port-for-port against the RM
   entity. Flow: `CORE/r6-dfx-build.tcl`.
3. **DONE** (dfx-r6 f736468) — MEGA65-R6-DFX.xdc (common.xdc re-targeted
   to the shell hierarchy + core-clock-service clocks), r6-dfx-child.xdc,
   r6-dfx-pblock.xdc. RP = clock-region rows Y0..Y3 full width (320/365
   RAMB36); static keeps row Y4 (HyperRAM bank 16 lives there), TMDS
   OSERDES static in X1Y2's IO column. Two lessons: the stock
   MEGA65-R6.xdc QoR pblocks overlap the RP even when they resolve empty
   (DRC HDPR-66 — link stage deletes them), and shell_core_clk's
   MMCM→BUFG→BUFGMUX cascades violated rule_cascaded_bufg on the A200T —
   the redundant BUFGs are removed (MMCMs feed the BUFGCTRLs directly;
   backport to Wukong at its next static rebuild).
4. **DONE** — configs A (democore, 54 MHz DRP table at wake) and B
   (G_INVERT_VIDEO): both meet timing (WNS +0.186), pr_verify A↔B OK.
   Partials ~5.1 MB (~26 s over 2 MBd UART). Next: package tester
   deliverables (.cor + partials + send script).
