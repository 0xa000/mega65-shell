> **Historical (pre-v5 names).** This spec predates the mega65-shell repo;
> signal names follow the old M2M-flavoured scheme. v5 rename map:
> `qnice_clk/qnice_rst` -> `loader_clk/loader_rst`, `hr_clk/hr_rst` ->
> `mem_clk/mem_rst`, `reset_m2m_n` -> `reset_shell_n`. Semantics are
> unchanged; see ../BOUNDARY.md for the current contract.

# Boundary v1 — TMDS seam, no shell video, clock preset request

Revision of BOUNDARY-V0.md following the hardware-verified democore
swap (2026-07-07). Two linked decisions:

1. **Sync loss on swap is accepted; the shell generates no video.**
   M2M cores save user settings (incl. HDMI mode) and QNICE restores
   them *after* boot, so the incoming RM's mode is unknowable at swap
   time — even a kept-sync swap re-syncs moments later when the saved
   mode lands. Keep-sync could only ever hold when outgoing mode,
   shell mode and the incoming RM's saved mode were all 720p60.
   Meanwhile the load path that matters (SD, stage A2) moves the ~3 MB
   partial in ~1–3 s — inside the monitor's own resync window. A swap
   reads as a mode change: blink, new core. LEDs indicate load
   activity (the dev-path UART load, minutes long, gets LED feedback
   only).

2. **With the fallback gone, the video seam drops to TMDS words** —
   the RGB seam existed only so the shell could encode its own
   fallback picture. The new seam is the DFX floor: OSERDES/IOB/MMCM
   must be static, so the shell keeps video_out_clock + the 3+1
   serialisers + OBUFDS and nothing else video.

## Deltas vs v0

Moves RM-side: `vga_to_hdmi` (TMDS encoding, AVI/ACR InfoFrames,
audio sample packets / data islands), `clk_synthetic_enable` + the
ACR/N/CTS strobe generation, and all mode metadata
(VIC/aspect/pix_rep/polarities — RM-internal now, never crosses).

Deleted outright: `shell_stripes`, the shell video mux, the PCM audio
boundary + silence gating, and the planned ~14-bit mode-metadata
fields over the reserved bus.

Port list changes (RM boundary):

- Video out: was `vid_r/g/b[7:0] + hs + vs + de` (27 wires) →
  `tmds_data[2:0][9:0]` (30 wires) @ hdmi_clk, registered in the RM
  (vga_to_hdmi's output registers). Shell routes them straight to the
  data serialisers; the clock channel stays a shell-side constant
  `0000011111`.
- Audio out: was `pcm_l/r[15:0]` (32 wires) @ audio_clk → **gone**
  (embedded in the TMDS stream). audio_clk/audio_rst remain boundary
  clock inputs (framework audio processing needs them).
- New: `vclk_sel_o[2:0]` — video clock preset request (next section).
- hdmi_clk/hdmi_rst unchanged as RM inputs; hdmi_clk_x5 still never
  crosses (serialisers are shell-side).

Net: the video+audio boundary shrinks from 59 wires to 33.

## Video clock preset service

The pixel clock is the only piece of "video mode" the RM cannot own
(the MMCM must be static). M2M's `video_out_clock` already contains
the entire mechanism — 3-bit `sel` port, XAPP888 register ROM for 7
presets, change detector, DRP rewrite FSM, MMCM reset + lock-wait
sequencing. Flat M2M drives `sel` from the mode record at runtime;
v0 merely pinned it to "010". v1 unpins it across the boundary.

RM contract:

- `vclk_sel_o[2:0]`, encoding = video_out_clock's existing table:
  `000`=25.200, `001`=27.000, `010`=74.250, `011`=148.500 (rejected by
  the shell — 5× serialiser rate exceeds -2 OSERDES limits), `100`=
  25.175, `101`=27.027, `110`=74.176 MHz, `111`=invalid.
- Drive it from a register **initialized to the RM's default preset**
  — GSR/RESET_AFTER_RECONFIG then guarantees a valid request from the
  first cycle after decouple release. Any clock domain is fine.
- Quasi-static: change it only as a settled write (a QNICE mode
  change). No handshake to implement.

Shell pipeline (clk_100 domain, ~15 lines):

1. `xpm_cdc_array_single`, 3 bits — may tear on a change; tolerated
   by (2).
2. Stability filter: a candidate must be sampled identical for 64
   consecutive cycles (0.64 µs) before acceptance — absorbs CDC tear
   and any transitional garbage.
3. Validity gate: `111` and `011` rejected (hold last accepted).
4. Decouple freeze: while the RP is dark the last accepted preset is
   held — the MMCM keeps running, hdmi_clk keeps ticking, the parked
   TMDS output keeps toggling.
5. Accepted value (register init "010") → `video_out_clock.sel`.

Feedback to the RM: none beyond the existing hdmi_rst.
video_out_clock asserts `rsto` through the DRP rewrite + relock
(~100–200 µs); hdmi_rst already crosses as a boundary reset, so the
RM's hdmi domain — now including its vga_to_hdmi — is held cleanly
and restarts at the new rate. This matches flat M2M semantics
exactly: QNICE writes the mode, the hardware follows, nobody waits
for an ack. (If a future RM wants to poll, a lock status bit can ride
the reserved bus; deliberately not specced.)

Sequence on a mode change: QNICE writes mode → RM registers vclk_sel
and switches its sync counters/VIC → 0.64 µs shell filter → DRP
rewrite + relock with hdmi_rst asserted → RM video restarts in the
new mode → monitor re-syncs (1–2 s; dominates everything else).

Constraint note: the vclk_sel boundary nets are quasi-static and
stability-filtered — false-path them in the child XDC alongside the
other cdc_stable-class crossings.

## Park behavior while the RP is dark

Data channels driven with a constant TMDS control-period symbol
(CTL0 = `1101010100`), clock channel free-running: electrically
clean, DC-balanced, and the monitor sees sync loss and mutes. No
shell timing generator of any kind.

## What this deliberately does NOT change

- Memory (Avalon-MM slave + fence), keyboard, joysticks, UART, SD,
  LEDs/buttons, control plane, reserved bus: exactly as v0.
- Analog/VGA (R6 targets): still a tier-1 RGB+syncs seam — there is
  no encoder to move; the VDAC is the PHY. The shell parks it dark
  during reconfig (CRT keep-sync was dropped by the same decision).
- Core main clock: still fixed per shell in this rev. The stage-3
  service will NOT be preset-select — per-core frequencies are
  arbitrary (VIC20: MULT_F=47.875, DIVIDE_F=13.5) — so the plan is a
  DRP write proxy: the RM streams XAPP888 addr/data pairs into a
  shell-owned MMCM through a small window and the shell adds only
  reset/lock sequencing. The video clock stays preset-based because
  TV pixel rates are a closed set and the ROM already ships inside
  video_out_clock.

## Stage-3 clock service — design conclusions (2026-07-07 discussion)

Recorded here so the proxy spec starts from them; none of these
changes boundary v1.

1. **One shared multi-target DRP window**, not one window per MMCM:
   the RM presents (target, addr, data, strobe) and the shell muxes
   onto the selected MMCM's DRP port, adding reset/lock sequencing.
   Give the target field headroom (3 bits, only core-MMCM targets
   populated at first) so the video MMCM can become a proxy target in
   a later shell **without a boundary change** — the vclk_sel preset
   port then remains as a convenience front-end driving the same
   machinery. Preset-vs-proxy for video is ergonomics, not protection:
   a rogue DRP write to the video MMCM only breaks that RM's own
   picture (loader/DDR3/ICAP don't touch hdmi_clk).
2. **Restricted crossbar for cascading** (the concrete form of
   DESIGN.md tier 2's "pre-wired optional cascade mux; provision the
   superset"): a frozen candidate list per MMCM input via BUFGCTRL
   (glitch-free), e.g. core MMCM B's input selects {clk_100, core
   MMCM A spare CLKOUT}. Selects live in a topology register next to
   the DRP window. The shell owns lock-chain sequencing: a downstream
   MMCM is held in reset while its selected upstream is unlocked or
   mid-DRP-rewrite. Cost per hop: one BUFG + accumulated jitter
   (acceptable for retro cores; flat designs cascade already). Treat
   as cheap insurance, sized minimally — single fractional MMCMs
   reach more than expected (VIC20's 35.468944 MHz is single-stage).
3. **One-table constraint/payload generation**: runtime clock freedom
   must agree with build-time STA. The child XDC must `create_clock`
   each boundary clock at the frequency the RM will actually request.
   Generate the DRP payload table and the child-XDC clock constraints
   from a single frequency table in the build flow so they cannot
   drift apart.

Status: specced 2026-07-07, not yet implemented. This is the planned
next static rebuild (invalidates the v0 RMs); bundle any pblock
resize with it. It supersedes the v0 polish items (stripes
phase-lock, progress bar) — that machinery is deleted, not improved.
