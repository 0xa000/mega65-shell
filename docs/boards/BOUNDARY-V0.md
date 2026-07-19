> **Historical (pre-v5 names).** This spec predates the mega65-shell repo;
> signal names follow the old M2M-flavoured scheme. v5 rename map:
> `qnice_clk/qnice_rst` -> `loader_clk/loader_rst`, `hr_clk/hr_rst` ->
> `mem_clk/mem_rst`, `reset_m2m_n` -> `reset_shell_n`. Semantics are
> unchanged; see ../BOUNDARY.md for the current contract.

# Boundary v0 — thin shell / M2M-RM seam (Wukong, democore)

Concrete signal-level boundary for the first thin-shell carve-out of the
flat MiSTer2MEGA65-wukong design (see DESIGN.md "Boundary confirmed: thin
shell"). Scope: stage-2 PoC — democore RM, one fixed video mode, all
clocks fixed, loader stays the verified UART/ICAP path. Everything here
was read off the working flat design (framework_wukong.vhd and
av_pipeline/digital_pipeline.vhd), not designed on paper.

## What moves where

Static shell (from the flat design):
- `ddr3_wrapper_wukong` complete (UberDDR3 + avm_increase + avm_to_wb +
  its MMCM; exports hr_clk/hr_rst) — its 16-bit Avalon slave is the
  boundary memory port.
- `vga_to_hdmi` + both `serialiser_10to1_selectio` + the PCM strobe
  generation (`pcm_clken`/`acr`/`n`/`cts` counters from
  digital_pipeline) + HDMI mode metadata (v0: constants for 720p60,
  CEA VIC 4).
- Video fallback: RGB pattern generator (loading stripes, fed by the
  ICAP byte counter) muxed in front of vga_to_hdmi while the RP is dark.
- All clock generation: `clk_wukong` (50→100), `clk_m2m` (qnice 50,
  audio 12.288), a fixed 74.25/371.25 MHz MMCM replacing the
  QNICE-DRP `video_out_clock` (v0 has no mode switching), and the
  democore main clock 54.000 MHz (MMCM: DIVCLK=1, MULT_F=6.750,
  DIVIDE_F=12.500 — fractional, i.e. already a nontrivial preset).
- ICAP loader + UART byte source (unchanged from stage A1), IOBUFs for
  all pins, decoupling registers on all RM outputs.

RM (everything else — the M2M framework becomes RM-side library code):
- qnice_wrapper (QNICE, SD, OSM logic), m2m_keyb_wukong +
  c64kbd_to_matrix scanner logic, reset_manager, joystick debouncer,
  avm_arbit_general (the RM-internal arbiter: core + ascal + QNICE),
  avm_fifo_qnice, all cdc_stable/cdc_pulse instances, rtc_wrapper
  (idle I2C on Wukong), av_pipeline *minus* vga_to_hdmi/serialisers,
  and the CORE (democore) with its `clk.vhd` MMCM **deleted** — the RM
  receives main_clk from the shell (7-series: no MMCM/PLL/BUFG in an RP).

## Partition pins (RM port list)

Clocks + resets, static → RM (each already BUFG-driven in static):

| signal | freq / domain |
|---|---|
| qnice_clk / qnice_rst | 50 MHz |
| main_clk / main_rst | 54.000 MHz (democore; per-RM preset later) |
| hr_clk / hr_rst | 100 MHz (= UberDDR3 controller clock) |
| hdmi_clk / hdmi_rst | 74.25 MHz (fixed 720p60 in v0) |
| audio_clk / audio_rst | 12.288 MHz |

(tmds_clk 371.25 MHz never crosses: serialisers are shell-side.)

Memory, RM master → shell Avalon-MM slave, all @ hr_clk (62 wires):
`avm_write, avm_read, avm_address[31:0], avm_writedata[15:0],
avm_byteenable[1:0], avm_burstcount[7:0]` →, ← `avm_readdata[15:0],
avm_readdatavalid, avm_waitrequest`. This is the output of the RM's own
arbiter — the shell sees exactly one latency-insensitive master
(hardware-proven port: HyperRAM on MEGA65 / UberDDR3 on Wukong).

Video, RM → shell, all @ hdmi_clk (27 wires):
`vid_red[7:0], vid_green[7:0], vid_blue[7:0], vid_hs, vid_vs, vid_de` —
tapped at the video_overlay (OSM) output, i.e. the exact signal set
vga_to_hdmi consumes today. Shell muxes to the stripes generator when
the RM is absent/decoupled.

Audio, RM → shell @ audio_clk (32 wires): `pcm_l[15:0], pcm_r[15:0]`,
sampled by the shell's 48 kHz clken strobe; shell owns ACR/N/CTS
(depends only on video mode + sample rate, both shell-known in v0).

I/O passthrough, tier 0 (raw, slow, registered both sides):
- C64 keyboard matrix: the charge-trick pins as in/out/oe triples
  (scanner logic stays in the RM; shell owns only the IOBUFs).
- Joysticks: 2×6 inputs. UART: rx →RM, tx ←RM. SD (6): RM-owned in v0
  (loader is UART-fed; the SD ownership mux is a later stage).
- LEDs (2) ←RM (shell overrides while RP dark), buttons (2) →RM.

Control plane, v0 minimum:
- `rm_alive` ←RM (watchdog seed, DESIGN.md §4), `rm_reset` →RM
  (asserted through reconfiguration; the decouple signal itself stays
  shell-internal). Reserved bus: 16 in / 16 out spare wires, registered,
  tied off — partition-pin count is frozen with the shell, over-provision
  day one (DESIGN.md §6).

## Decoupling (shell-side, while RP is dark)

`avm_write/read` → 0 (arbiter sees idle master; wait for outstanding
readdatavalid beats to drain before decoupling), video mux → stripes,
`pcm_l/r` → 0, `uart_tx` → 1, keyboard oe → inactive, LEDs → shell
pattern, `rm_alive` → 0.

## Known v0 simplifications (deliberate, lifted in later stages)

1. Fixed video mode: the RM's QNICE still *writes* video_out_clock DRP
   registers and expects ascal to follow mode changes — v0 ignores the
   DRP traffic (democore's default mode is 720p60; OSM "HDMI mode" menu
   entries won't act). Stage 3 replaces this with the DRP preset service.
2. Fixed main_clk: 54 MHz hardwired; per-RM presets come with stage 3.
3. SD stays RM-owned; shell loads partials over UART (stage A1 path).
   The SD mux + menu-RM exec-descriptor flow is stage A2/B territory.
4. RTC/I2C: Wukong has none; pins tied as in the flat port.

## RM-side source changes (the "board layer becomes the adapter")

- framework_wukong.vhd forks into `rm_m2m_wukong.vhd`: clk_m2m,
  video_out_clock, ddr3_wrapper, vga_to_hdmi/serialisers deleted;
  clocks/avm/video/pcm become ports.
- democore mega65.vhd variant: clk.vhd instance replaced by the
  main_clk port (mechanical; this is the per-core migration DESIGN.md
  predicts for every M2M port).
- digital_pipeline gets a generate/variant cut after i_video_overlay.

Everything else — QNICE firmware, ascal, OSM, vdrives, keyboard — is
untouched M2M code compiled into the RM.
