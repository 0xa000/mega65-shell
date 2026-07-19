# Feasibility study: C64 core as a DFX RM on the Wukong (A100T)

Date: 2026-07-10.  Baseline: boundary-v2 static with generic core_clk0/1
ABI (MiSTer2MEGA65 dfx-vic20 ea2a50c), RP hard-capped at 125 BRAM tiles;
C64MEGA65-wukong flat build (commit c4f7c7e era, `CORE/build-wukong/`).

## Verdict

**Feasible, and cheaper than VIC20 was.** The C64 RM fits the existing
RP after porting the VIC20 mount-buffer depth cap (no feature trims
needed — the "drop another kernal" reserve stays unused), and its
flicker-fix clocking maps 1:1 onto the shell's existing dual-MMCM +
BUFGMUX_CTRL crossbar. **No static rebuild, no ABI change**: this is
pure RM-side work in the C64MEGA65 repo against the released
static_locked.dcp. Boundary v2's crossbar was specced from this exact
core's requirement, and it pays off.

## 1. BRAM (the binding constraint)

Flat route utilization: 130 RAMB36 + 5 RAMB18 = **132.5 tiles** (98% of
device). Conversion to RM terms:

| step | tiles |
|---|---|
| flat, routed | 132.5 |
| − static-side DDR3 FIFOs (only shell BRAM) | −2 → 130.5 |
| − mount-buffer cap 2^18 → 197376 (64 → ~50 RAMB36) | −14..15 → **~116** |

~116 of 125 tiles ≈ **93% fill** — comfortable; the VIC20 RM routes
clean at 124/125 (99%). The mount buffer is the same dead-generic bug
found in VIC20: `dualport_2clk_ram` never passed `MAXIMUM_SIZE` down,
so the 18-bit D64 buffer allocated the full 256 KB. C64's instance
already declares `MAXIMUM_SIZE => 197376` (max 40-track+error D64;
mega65.vhd:881, and it is D64-only by design — CRT goes through the
DDR3 cache, PRG into C64 RAM). Porting VIC20 commit 6d943f9 (tdp_ram
`MAX_DEPTH`, 2 small files in the vendored M2M) makes it real. Zero
feature loss.

**Kernal-drop reserve (not needed, kept as contingency):** the
QNICE-uploadable `custom_kernal` RAM (20 KB, BLOCK-pinned) ≈ 5 tiles
if the fill turns out too hot to route. GS/JAP were already pruned in
the flat trims; std stays.

## 2. LUT / DSP / clock-network

- **LUT:** flat = 39.5k. Shell-side removal is ~2.5k (VIC20 delta:
  27.3k flat → 24.8k RM OOC), so RM ≈ **37k vs ~53k RP capacity
  (~70%)**. Moderate density; combined with 93% BRAM it's the main
  routing risk, but VIC20 routed at 99% BRAM with WNS +0.22, and the
  mount-buffer cap *reduces* the BRAM pressure that caused the flat
  build's LUTRAM spills.
- **DSP:** 72 of ~200 in the RP — trivial.
- **BUFGCTRL / MMCM in RP:** zero, as required (7-series DFX forbids
  them). Both flicker-fix MMCMs and their glitch-free mux live in the
  shell already.

## 3. Flicker-fix clocking — exact match to boundary v2

C64 clk.vhd (flat) is: two single-output MMCMs behind one
BUFGMUX_CTRL, select switched live (no core reset), reset =
NOT(locked_orig AND locked_slow).

| flat element | shell/boundary-v2 element |
|---|---|
| i_clk_c64_orig: DIVCLK=6, MULT_F=56.75, CLKOUT0=30 → 31.5278 MHz | CORE_A via DRP table (frac on CLKFBOUT only) |
| i_clk_c64_slow: DIVCLK=9, MULT_F=60.5, CLKOUT0_F=21.375 → 31.4490 MHz | CORE_B via DRP table (frac on CLKFBOUT + CLKOUT0 ✓ = the one frac-capable output) |
| bufgmux_ctrl on core_speed(0) | shell core_clk0 output mux, clkctl **bit0** |
| both LOCKED → reset release | clkstat bits 0+1 |
| video clock | none needed — `video_clk_o <= main_clk_o` (mega65.vhd:419); RM uses core_clk0_i for both |

The switch driver is **automatic RTL, not QNICE**: a bang-bang
controller in mega65.vhd flips core_speed on `hr_low_i`/`hr_high_i`
(ascal buffer-fill feedback, hr domain, all RM-internal). Only the
select bit crosses the boundary, through the existing clkctl CDC +
64-cycle stability filter. Events are frame-scale (≥ ms apart) vs a
640 ns filter window — fine, but confirm cadence on hardware (§6).

Both frequencies are legal for the generator (0.125-step, phase 0,
duty 0.5, VCO 945.8 / 672.2 in range) and both are < 54 MHz, so the
default child-XDC over-constraint would even suffice; emit real
overrides anyway.

**Infrastructure gaps — all small, all RM-side or tooling:**

1. `clk_drp_master` needs **no RTL change**: rows carry a 3-bit target,
   so one concatenated ROM (orig rows @target 0 + slow rows @target 1,
   ~30 rows) programs both MMCMs; G_CLKCTL_RST = both reset bits,
   G_LOCK_MASK = both lock bits (it holds all masked resets during the
   whole write and releases together — matches XAPP888).
2. rm_top glue (~5 lines): after `done_o`, clkctl bit0 must follow the
   live core_speed value (2-FF CDC from hr domain) instead of the
   constant G_CLKCTL_RUN. Gate the pass-through on `done` so the mux
   never switches while the MMCMs are still in reset.
3. mmcm_drp_table.py: emit/merge two tables into one pkg (or generate
   twice and hand-concat the constant array), and `--xdc` must emit the
   two cores at their *own* frequencies (VIC20's single-MMCM emit put
   one table's freqs on both). Constraining both at the faster 31.5278
   is also acceptable.

## 4. Everything else transfers from VIC20

- RM transform is the same recipe: mega65_rm.vhd = mega65.vhd minus
  clk_gen, clocks/resets from the boundary; vendored framework_rm /
  pipeline_rm / rm_top / build tcl copied from VIC20MEGA65 and adapted
  (per the shell-SDK model: link against the shared static_locked.dcp,
  never rebuild it).
- REU + CRT cache already ride the single Avalon slave (avm_arbit is
  RM-side) — the boundary pattern proven by democore + VIC20.
- Child XDC: carry over the C64 flat build's hard-won constraints
  (RAM_STYLE BLOCK for custom_kernal + crt_lo/hi, DISTRIBUTED+waiver
  for romstd, ascal LUTRAM /CLK false paths) plus the two VIC20 RM
  lessons (constrain BOTH cores on each mux output; qnice↔core
  set_clock_groups -asynchronous, since the override re-derives core
  clocks from sys_clk_100).

## 5. What this does NOT require

- No static rebuild, no pblock change, no ABI bump. The postponed
  refinements (extra over-provisioned outputs, reset-gate) stay
  postponed — C64 needs exactly 2 MMCMs × 1 output + 1 mux bit.
- No feature trims beyond what the flat build already has (GS/JAP
  kernals, cache size, iec DUALROM).
- NTSC is upstream @TODO in the flat core too — out of scope.

## 6. Risks / open items

| risk | assessment |
|---|---|
| Routing at 93% BRAM + 70% LUT | Moderate; VIC20 precedent good (99% BRAM routed, WNS +0.22). Contingency: kernal drop (−5 tiles) and/or LUT-side trims. |
| First hardware exercise of CORE_B DRP + output-mux bit0 | Variant C only ever reprogrammed CORE_A and never touched the mux select. RTL paths are symmetric; verify on hw. |
| Flicker-switch cadence vs 64-cycle clkctl filter | Expected frame-scale; if ascal feedback ever oscillates faster than 640 ns (implausible), the filter would suppress switches — confirm flicker-free actually locks (OSM shows it; a counter/LED on accepted toggles would settle it). |
| Cold-boot-DRP video bug / reset-gate (deferred) | Applies to C64 same as VIC20; unchanged status. |
| C64 upstream age | Our base predates possible upstream C64MEGA65 fixes (VIC20 turned out 32 commits behind). Optional: rebase like VIC20 before the RM transform. Doesn't gate feasibility. |

## 7. Suggested implementation order

1. Port tdp_ram MAX_DEPTH (VIC20 6d943f9) into C64MEGA65's vendored
   M2M; optionally rebuild flat as a sanity check (BRAM 98% → ~87%).
2. Generate + golden-validate (iverilog oracle) the two DRP tables;
   merge into c64_clk_pkg; emit child-XDC clock overrides.
3. RM transform (mega65_rm.vhd, rm_top with dual-target ROM + live
   core_speed→clkctl bit0 glue), vendored dfx files from VIC20MEGA65.
4. OOC synth → check ≤ 125 tiles → impl against existing
   static_locked.dcp → pr_verify against democore + VIC20 partials.
5. Hardware: swap in, boot, then the flicker-free OSM toggle in a
   50 Hz HDMI mode; verify live switching (no glitch/reset) and that
   the frame rate actually locks to the display.
