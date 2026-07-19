> **Historical (pre-v5 names).** This spec predates the mega65-shell repo;
> signal names follow the old M2M-flavoured scheme. v5 rename map:
> `qnice_clk/qnice_rst` -> `loader_clk/loader_rst`, `hr_clk/hr_rst` ->
> `mem_clk/mem_rst`, `reset_m2m_n` -> `reset_shell_n`. Semantics are
> unchanged; see ../BOUNDARY.md for the current contract.

# Boundary v2 — core clock service (DRAFT, stage B)

Delta against BOUNDARY-V1.md (hardware-verified 2026-07-07: swap,
RM-side TMDS/audio, live vclk_sel mode switching). Scope: everything
the RM needs to own its core clocking without owning clock primitives
(7-series DFX: MMCM/PLL/BUFG must be static). Requirements below are
read off real cores, not designed on paper:

- **VIC20MEGA65** (`CORE/vhdl/clk.vhd`): ONE MMCM, TWO outputs from
  one VCO — CLKOUT0 = 70.926 MHz (core video), CLKOUT1 = 35.463 MHz
  (main). DIVCLK=5, MULT_F=47.875, DIVIDE_F=13.5/27 — fractional.
  ⇒ a shell core-MMCM must expose two outputs, and the boundary needs
  a second core clock pin.
- **C64MEGA65** (`CORE/vhdl/clk.vhd`): HDMI flicker-fix = TWO parallel
  MMCMs running simultaneously (orig 31.5278 MHz: 6/56.750/30.000;
  slow 31.4490 MHz: 9/60.500/21.375) behind a **BUFGMUX_CTRL**,
  switched live by QNICE **without resetting the core**.
  ⇒ the restricted crossbar is a hard requirement, and the mux select
  crosses the boundary.

## Shell clock resources (frozen topology, provision the superset)

Two core-facing MMCMs, CORE_A and CORE_B, each with two exposed
outputs; three glitch-free BUFGCTRL-class muxes:

```
                       +----------+   clk0   +--------------+
   clk_100 --------+-->| MMCM     |--------->|              |
                   |   | CORE_A   |   clk1   | BUFGMUX_CTRL |--> main_clk    (RM pin)
                   |   +----------+----+---->|  sel: mux(0) |
                   |        | spare    |     +--------------+
                   |        v CLKOUT2  |
                   |   +---------+     |     +--------------+
                   +-->| BUFGCTRL|     +---->|              |
   (cascade) --------->| in-mux  |--+       | BUFGMUX_CTRL |--> video_clk   (RM pin, new)
                       +---------+  |  +--->|  sel: mux(1) |
                                    v  |    +--------------+
                       +----------+    |
                       | MMCM     |----+  (CORE_B.clk0/clk1 are the
                       | CORE_B   |        second mux inputs)
                       +----------+
```

- CORE_A boots with the democore preset (54 MHz on clk1) baked into
  the static bitstream — an RM that never touches the service gets
  v1 behavior unchanged.
- CORE_B's input is a BUFGCTRL choosing {clk_100, CORE_A.CLKOUT2}:
  one pre-wired cascade hop for frequencies out of single-MMCM reach.
  Lock-chaining is shell-owned: CORE_B is held in reset while its
  selected upstream is unlocked or mid-DRP-write.
- Use cases mapped: VIC20 = CORE_A alone, both outputs, muxes at 0.
  C64 flicker-fix = program CORE_A (orig) + CORE_B (slow), toggle
  mux(0) live. Democore = touch nothing.

## New partition pins

RM → shell, DRP proxy (write-only; the shell does read-modify-write,
so the RM never needs DRP read data):

| signal | width | notes |
|---|---|---|
| drp_target_o | 3 | 0=CORE_A, 1=CORE_B, 2=video MMCM (reserved, not wired in v2), 3–7 reserved |
| drp_addr_o | 7 | DRP register address |
| drp_data_o | 16 | write data |
| drp_mask_o | 16 | read-mask: shell writes (read & mask) \| data |
| drp_req_o | 1 | toggle handshake (see protocol) |
| clkctl_o | 8 | bit0: mux(0) main_clk A/B; bit1: mux(1) video_clk A/B; bit2: CORE_B input cascade off/on; bit3: CORE_A reset; bit4: CORE_B reset; bits 5–7 reserved. Quasi-static, vclk_sel-style CDC + stability filter |

Shell → RM:

| signal | width | notes |
|---|---|---|
| drp_ack_i | 1 | toggle handshake return |
| clkstat_i | 4 | bit0: CORE_A locked; bit1: CORE_B locked; bits 2–3 reserved |
| video_clk_i / video_rst_i | 2 | second core clock domain (VIC20; democore RMs ignore it) |

The (addr, data, mask) triple is exactly one row of the XAPP888
spreadsheet output — the same format video_out_clock's preset ROM
uses — so the one-table flow (below) emits proxy payloads and shell
ROM entries from identical source data.

## DRP write protocol

The payload is multi-bit and changes per write, so the quasi-static
stability-filter trick does not apply; a classic toggle handshake
carries it instead:

1. RM drives target/addr/data/mask, then flips `drp_req_o`.
2. Shell (clk_100): sees req ≠ ack through a synchronizer — payload
   has been stable for the synchronizer latency by construction —
   performs DRP read, applies mask, writes, waits DRDY, then flips
   `drp_ack_i`.
3. RM sees ack = req: may present the next row.

Rules: the RM asserts the target's reset (clkctl bit 3/4) before the
first row of a reprogram and releases it after the last, then waits
for the lock bit in `clkstat_i` (XAPP888 sequence). The shell
additionally forces reset on any MMCM whose DRP is mid-write and
ignores requests while the RP is decoupled (freeze, like vclk_sel;
implementation note: the shell zeroes the whole toggle-handshake
state during decouple, so req/ack parity re-pairs with the next RM's
GSR-zeroed side — an odd transaction count must not leak across a
swap). Full reprogram ≈ 15-23 rows; at a few µs per handshake this
is well under a millisecond — boot-time noise.

**RM clocking rule (agreed 2026-07-07): MMCM DRP state persists
across swaps** — partial reconfiguration does not touch static
frames, so whatever the previous RM programmed is still there.
Every RM (including the menu, which returns after every core) must
program the clocks it needs during its wake sequence, before its
core-domain logic leaves reset; the shell's lock-based main_rst/
video_rst enforce the release order. The static default preset is a
parking state and the first-boot frequency — not a contract. An RM
that skips the service entirely (democore A/B) is only a valid
regression vehicle against a freshly configured static.

The M2M framework library gains a small `clk_drp_master` helper (FSM +
preset ROM generated from the table) so a core port drives the service
the way it drove its own MMCM generics; non-M2M cores can bit-bang the
handshake.

## Build-time STA (the one-table rule)

Runtime freedom must agree with static timing analysis. Each RM's
build consumes ONE frequency table (per MMCM: DIVCLK/MULT_F/CLKOUTn
divides), from which the flow generates:

1. the DRP payload rows for the RM's `clk_drp_master` ROM,
2. the child-XDC `create_clock`/`create_generated_clock` overrides on
   the shell MMCM output pins at the RM's actual frequencies,
3. `set_clock_groups -physically_exclusive` for the A/B pairs feeding
   each BUFGMUX (both clocks exist in STA; only one drives the domain
   at a time — same setup flat C64 needs for its two MMCMs).

Never hand-edit one of the three; regenerate all from the table.

## Bundled static changes (same rebuild, since RMs invalidate anyway)

- **Pblock growth for VIC20**: VIC20 flat ≈ 124 RAMB36; the current RP
  holds 100. Extend row-2-right (+20 → 120) and into row 3 as the
  VIC20 flat placement dictates, keeping the DDR3 (X0Y3) and HDMI
  OSERDES (X1Y2) strips static.
- Optional: 40 MHz preset in video_out_clock's ROM (SVGA), or leave
  SVGA to the RM-side menu trim.

## Validation plan

1. Democore RM against the v2 static: regression (ignores the new
   pins — proves default-preset behavior). **DONE, hardware-verified
   2026-07-07** (A→B→A swaps incl. swap-back after the Avalon fence
   fix; see repo history — the fence must complete an orphaned write
   burst itself with byteenable-0 beats, never wait for the RM).
2. Democore variant C: `clk_drp_master` reprograms CORE_A to a
   different main clock (e.g. 40 MHz) at boot — first live proxy test
   (roadmap step 3 folded in). **DONE, hardware-verified 2026-07-07**:
   15-row table generated by `M2M/tools/mmcm_drp_table.py` (one-table
   tool; lock/filter tables from Vivado's clk_wiz DRP functions,
   selftest reproduces video_out_clock's verified vectors), CORE_A
   live-reprogrammed 54→40 MHz through the proxy at RM boot.
3. VIC20 RM: CORE_A dual-output (70.926/35.463) — the real-core test,
   plus the grown pblock.
4. VIC20 OSM mode menu: already served by vclk_sel (v1, verified).

Build note: the static's XDC times the default table (CORE_A 54 MHz,
cascade off via case analysis); presets SLOWER than the default are
conservative-safe without overrides (variant C's 40 MHz), presets
FASTER need the one-table child-XDC overrides.

Status: implemented and hardware-verified through validation step 2,
2026-07-07 (shell_core_clk.vhd, drp_proxy.vhd, clk_drp_master.vhd,
mmcm_drp_table.py in the M2M repo). Everything not named here is
BOUNDARY-V1.md unchanged.
