# Converting a core into a DFX reconfigurable module (RM)

A practical, step-by-step manual for turning an existing full core into a
loadable partial for the mega65-shell static shell. Written for someone
comfortable with Vivado and RTL but **not** steeped in timing/placement
constraints or the odder corners of the DFX (partial-reconfiguration) flow.
Every timing or placement rule you meet here is explained where it first
appears, and again in one place in §7.

We build up in two passes:

- **Part I (§4)** — a *non-M2M* core (bare RTL that draws video and maybe
  touches RAM). This is the whole DFX story with nothing else on top. The
  worked example is `picorv32-menu`. §4.2a is a self-contained DRP clock
  example for anyone who needs a core clock the shell isn't already parked at.
- **Part II (§5)** — the *M2M* additions (QNICE, ascal scaler, OSM, the
  `*_rm` framework forks, DRP clock programming). The worked example is
  `MoonPatrolMEGA65_r3_r6`, the most current M2M core in the catalog (it
  exists as both a Wukong and an R6 RM).

Read Part I even if your core is M2M-based: every rule there still applies,
and Part II is purely additive.

**Boundary revision.** This guide targets **boundary v5** — the current
shell ABI (locked 2026-07-19 for both boards; hardware-verified end to end
on the Wukong 2026-07-20, R6 awaiting its tester round). v5 is a delta on
v4/v3: shell-neutral names (`loader_*`, `mem_*`, `reset_shell_n`), the
loader stack on a 50 MHz domain, and the ICAP LED verdict — semantics of
the v3 services are unchanged. **The authoritative port list is the
`rm_top` component declaration in each board's shell top**
(`boards/wukong/rtl/shell_top.vhd`, `boards/r6/rtl/shell_top_r6.vhd`); see
`BOUNDARY.md` for the version lineage and rename map.

Reference material this guide is distilled from: `DESIGN.md` (why the
boundary is where it is), `BOUNDARY.md` + the annexes under `boards/`
(the signal-level ABI, newest first), `FEASIBILITY-C64-RM.md` (a full
worked cost estimate), and the build scripts — `flow/dfx.tcl` in this repo
(the parameterized flow), `picorv32-menu/scripts/build.tcl` (non-M2M), and
`MoonPatrolMEGA65_r3_r6/CORE/wukong-dfx-build.tcl` / `r6-dfx-build.tcl`
(M2M).


## 1. The mental model

There are two halves of the FPGA:

- The **static shell** owns every device pin (IOBs), every clock primitive
  (MMCM/PLL/BUFG), and the config primitives (ICAPE2, BSCAN, STARTUPE2). It
  holds the memory controller (DDR3 on the Wukong, HyperRAM on the R6), the
  HDMI OSERDES serialisers, the SD/FAT32 reader and the ICAP loader that
  streams new cores in. It is built **once**, routed, locked, and released
  as `static_locked.dcp`. It never changes when you build a core.
- The **reconfigurable partition (RP)** is one region of the die into which
  cores — and the boot menu itself — are streamed at runtime. Your core
  becomes the contents of that region: a **reconfigurable module (RM)**.

The single most important consequence, and the thing that makes DFX feel
strange the first time:

> **Every RM is implemented *against the exact locked static checkpoint*.**
> You do not synthesize a whole design. You synthesize *only your module*,
> then place-and-route it into a frozen shell whose routing and placement
> are already fixed (static routes may even pass straight through your
> region). Change one line of the shell and every core ever built is
> invalidated.

This is the **shell-SDK model**: the shell is released like an ABI. Cores
*vendor* the RM-side framework files but **link against the shared
`static_locked.dcp`; they never rebuild it**. Your deliverable is a
**partial bitstream** (`*.bin`) that the shell loads on top of itself.

### What may NOT go inside an RM (7-series DFX hard rules)

- No `MMCM`/`PLL`/`BUFG`/`BUFGCTRL` — all clock generation and buffering is
  the shell's. Your clocks arrive as **input ports, already on global
  buffers**. (This is the rule that bites core ports hardest: almost every
  core has a `clk.vhd` full of MMCMs. It has to go — see §4.2.)
- No `IOB`/pin primitives — the shell owns the pads. You get **logical**
  signals across the boundary (e.g. `sd_mosi_o`, not a pad).
- No `ICAPE2`/`BSCAN`/`STARTUPE2` — config primitives are static-only. This
  is why even the QSPI flash clock is a *request* the shell proxies (§2).
- No debug hub (ILA/VIO need a static-only debug bridge).


## 2. The boundary ABI — the one contract you must honour

The boundary is a fixed VHDL entity, `rm_top` (`rm_top_r6` on the R6).
**Its port list is the ABI.** It is byte-identical across every core built
for a board (democore, menu, VIC20, C64, Moon Patrol, your core), which is
exactly why any partial links against the same static. You do not get to
change it; you fill it in.

Here is the current (v5) Wukong port list, grouped by purpose. Names are
exact; the authoritative copy is the component declaration in
`boards/wukong/rtl/shell_top.vhd`:

```vhdl
entity rm_top is port (
   -- CLOCKS + RESETS (all BUFG-driven, from the shell; never generate these)
   sys_clk_i, sys_pps_i            : in  std_logic; -- 100 MHz system + 1pps tick
   reset_shell_n_i, reset_core_n_i : in  std_logic; -- reset whole machine / core only
   loader_clk_i, loader_rst_i      : in  std_logic; -- 50 MHz service clock (M2M RMs clock QNICE from it)
   core_clk0_i,  core_clk0_rst_i   : in  std_logic; -- CLKOUT0: fractional-capable
   core_clk1_i,  core_clk1_rst_i   : in  std_logic; -- CLKOUT1: integer divide only
   core_clk2_i,  core_clk2_rst_i   : in  std_logic; -- CLKOUT2: integer only (v3)
   mem_clk_i,    mem_rst_i         : in  std_logic; -- memory port clock (Avalon)
   audio_clk_i,  audio_rst_i       : in  std_logic; -- audio sample clock
   hdmi_clk_i,   hdmi_rst_i        : in  std_logic; -- HDMI *pixel* clock (follows vclk_sel_o)

   -- TIER-0 RAW I/O (logical; tri-state buffers are shell-side)
   uart_rx_i, uart_tx_o          : ...              -- shares the wire with the ICAP loader
   kb_porta_col_n_o, kb_portb_row_n_i, kb_portb_charge_o, kb_restore_n_i : ...  -- keyboard
   joy_1_*/joy_2_* (up/down/left/right/fire, active low, inputs on Wukong)
   sd_reset_o, sd_clk_o, sd_mosi_o, sd_miso_i        -- SD (RM owns it except while RP is dark)
   qspi_clk_o, qspi_csn_o, qspi_d_i/o/oe             -- QSPI flash pass-through (v3; see below)

   -- MEMORY: one arbitrated Avalon-MM master @ mem_clk_i toward the shell controller
   mem_write_o, mem_read_o, mem_address_o(31:0), mem_writedata_o(15:0),
   mem_byteenable_o(1:0), mem_burstcount_o(7:0),
   mem_readdata_i(15:0), mem_readdatavalid_i, mem_waitrequest_i

   -- VIDEO: 3x10-bit parallel TMDS words @ hdmi_clk_i; shell serialises them
   tmds_o : out std_logic_vector(29 downto 0)       -- channel i = bits 10*i+9 downto 10*i

   -- CLOCK SERVICE (see §4.2a / §5.2)
   vclk_sel_o(2:0)               -- pixel-clock preset request into shell video MMCM
   drp_target_o(2:0), drp_addr_o(6:0), drp_data_o(15:0), drp_mask_o(15:0),
   drp_req_o, drp_ack_i          -- DRP write proxy: reprogram a core MMCM at wake
   clkctl_o(7:0), clkstat_i(3:0) -- core-clock mux selects / lock+status feedback

   -- CONTROL PLANE
   rm_alive_o                    -- set it high once you're up (watchdog proof-of-life)
   rsv_i(15:0), rsv_o(15:0)      -- desc_proxy register file: the FAT32 load-descriptor
                                 --   hand-over rides these (see §4.4; "rsv" is a
                                 --   historical name — a v6 rename to desc_* is queued)
);
```

### Board differences — the R6 port list is a superset

`rm_top_r6` carries every service above with identical semantics, plus the
R6's larger peripheral set as tier-0 raw I/O: the smart-keyboard serial
protocol (`kb_io0/1/2` instead of the Wukong's matrix scanner pins), joystick
*output* legs and paddles, a **second SD slot** (`sd2_*`, the internal one;
the shell's own loader uses the *external* slot during loads), **five I2C
buses** as in/out pairs (fpga/grove/i2c/hdmi/vga/audio), the **IEC serial
port**, the **full C64 cartridge port** (oe/in/out triples), **VGA/VDAC
output** (24-bit RGB + syncs + VDAC control), and a **PCM audio pair**
(`audio_left_o`/`audio_right_o`, signed 16-bit @ `audio_clk_i`) into the
shell's AK4432 DAC driver. `mem_*` talks to the HyperRAM (whose content
survives swaps) instead of DDR3. Start from an existing R6 RM
(`rm_top_r6.vhd` in the M2M fork branch `dfx-v5-r6` or picorv32-menu) —
the democore ties the whole C64-specific block off, so even a minimal RM
satisfies the ABI without new code.

### The three core clocks and their capabilities (v3, unchanged in v5)

The shell has two identical core MMCMs (CORE_A, CORE_B) behind a glitch-free
mux crossbar. Each exposes three outputs across the boundary. What is fixed
shell-side — and therefore part of the contract — is each output's
*capability*; it's the RM's job to map its functions onto them:

| port | MMCM output | mux via `clkctl` bit | capability |
|---|---|---|---|
| `core_clk0_i` | CLKOUT0 | bit 0 | **fractional** divide (the only `_F`-capable output) |
| `core_clk1_i` | CLKOUT1 | bit 1 | integer divide only |
| `core_clk2_i` | CLKOUT2 | bit 5 | integer only; on CORE_A this pin *doubles* as the CORE_B cascade reference (see V3 doc) |

`clkctl_o` bit map: bit0 = core_clk0 A/B select, bit1 = core_clk1 A/B,
bit2 = CORE_B input cascade, bit3 = CORE_A reset, bit4 = CORE_B reset,
bit5 = core_clk2 A/B, bits 6-7 reserved.

`clkstat_i`: bit0 = CORE_A locked, bit1 = CORE_B locked, **bit2 = memory
subsystem ready (informational only)**, bit3 reserved.

Put a fractional frequency (e.g. a 70.926 MHz video clock) on `core_clk0`;
put integer frequencies on `core_clk1`/`core_clk2`.

### Shell clock topology (how CORE_A and CORE_B relate)

Count carefully: the shell has several MMCMs, but only **two are the
core-clock service** — the ones an RM programs. The others exist but aren't
part of the DRP story:

| MMCM | who sets it | produces |
|---|---|---|
| **CORE_A** | the RM, via DRP proxy | its 3 outputs → `core_clk0/1/2` |
| **CORE_B** | the RM, via DRP proxy | its 3 outputs → `core_clk0/1/2` (alternate source) |
| base MMCM (`shell_clk_base`) | shell-fixed, untouchable | `sys_clk_i` (100), `loader_clk_i` (50), `mem_clk_i`, `audio_clk_i` |
| pixel MMCM (`video_out_clock`) | preset-only, via `vclk_sel_o` | `hdmi_clk_i` |

So "the core clocks" = **2 identical MMCMs, CORE_A and CORE_B**, each with 3
outputs (CLKOUT0 fractional, CLKOUT1/2 integer). The "3" you might expect
refers to the three *outputs per MMCM*, not three MMCMs.

The two MMCMs relate in two independent ways — easy to conflate because both
involve CORE_A and CORE_B, but they are different mechanisms:

```
   100 MHz sys_clk
        │
        ├──────────────► CORE_A ──CLKOUT0/1/2──┐
        │                  │                    │
        │   (cascade,      │ CLKOUT2            ├─► out MUX ─► core_clk0_i  (clkctl bit0)
        │    clkctl bit2)  ▼                    │
        └───(or raw 100)─► CORE_B ──CLKOUT0/1/2─┤
                                                ├─► out MUX ─► core_clk1_i  (clkctl bit1)
                                                └─► out MUX ─► core_clk2_i  (clkctl bit5)
```

1. **Live output mux — "switch between them".** Each `core_clk*` output pin
   can be sourced from *either* CORE_A or CORE_B, chosen at runtime by a
   `clkctl` bit (bit0/1/5) through a glitch-free `BUFGMUX_CTRL`. Run both
   MMCMs at slightly different frequencies and flip the mux bit live, no core
   reset. **This is the C64 flicker-fix** (`FEASIBILITY-C64-RM.md §3`): CORE_A
   at 31.5278 MHz ("orig"), CORE_B at 31.4490 MHz ("slow"), both on CLKOUT0 →
   `core_clk0`; the core toggles `clkctl` bit0 from ascal buffer-fill feedback
   to lock the frame rate to the display. Both MMCMs must be locked
   (`clkstat` bits 0 **and** 1) before the core is released.

2. **Cascade — "chain them".** CORE_A's CLKOUT2 can drive CORE_B's *input*
   (selected by `clkctl` bit2) so CORE_B synthesizes from CORE_A's output
   instead of raw 100 MHz. This is for reaching a frequency a single MMCM
   can't hit from 100 MHz in one stage (VCO-range / divide limits). Pre-wired
   but optional; most cores don't need it. Overlap to watch: on CORE_A,
   CLKOUT2 *is* the cascade reference, so using both `core_clk2`-from-A and
   the cascade at once forces them to the same frequency (one physical output
   feeds both).

A single-MMCM core (VIC20, Moon Patrol, democore) just programs CORE_A and
leaves the mux bits at 0 (CORE_A selected). You only touch CORE_B for the
live-switch or cascade patterns above.

### Rules of engagement

- **Every output must be driven — to a *safe idle*, not just driven.** The
  `rm_top` entity is frozen and identical across all cores, so your RM has
  every port whether it uses the function or not; unused ones must be tied to
  a defined idle value, not left open. Each RM output fans out to something
  real on the shell side, of two kinds: (a) **device pads** through shell
  IOBs (`uart_tx_o`, `sd_*_o`, `qspi_*`, LEDs, and the `oe` legs of raw
  triples) — a floating output here can leave a pin undefined or make a
  tri-state `oe` actively drive and contend on a shared pad; and (b) **shell
  service logic** (`mem_*`, `drp_*`, `clkctl_o`, `vclk_sel_o`, `rm_alive_o`,
  `tmds_o`, `rsv_o`) — a floating `clkctl_o`/`drp_req_o` can spuriously reset
  an MMCM or trigger a DRP write, a floating `rsv_o` can fire a bogus load
  descriptor, and a wrong `rm_alive_o` makes the watchdog reload the golden
  menu under you. So a minimal video-only core on `sys_clk_i`/`hdmi_clk_i`
  drives `tmds_o`, `rm_alive_o`, the LEDs, sets `vclk_sel_o` to its pixel
  preset, and idles the rest (`drp_req_o<='0'`, `clkctl_o<=(others=>'0')`,
  `rsv_o<=(others=>'0')`, the QSPI group off).
- **If you use any `core_clk*`, you MUST reprogram it at wake** (§4.2a). Do
  not assume the parked 54 MHz — that value is only guaranteed at cold boot;
  the core MMCMs are static, so whatever frequency the *previous* core set
  persists across the swap until you overwrite it.
- **QSPI clock is a request, not a clock.** On 7-series the flash clock is the
  dedicated CCLK config pin, drivable post-config only through
  `STARTUPE2.USRCCLKO`, which is a one-per-device primitive that must stay
  static. So `qspi_clk_o` is proxied by the shell. Silicon quirk: the first
  ~3 edges after config are swallowed — flash drivers must send dummy clocks
  first. Unused? Tie `qspi_clk_o<='0'`, `qspi_csn_o<='1'`, `qspi_d_o`/`_oe`
  all `'0'` (democore does).
- **Nothing *fast* crosses the boundary — but "register both sides" is only
  for the synchronous buses.** Two different kinds of signal cross the RM↔shell
  partition, and they're handled oppositely:
  - **Synchronous service buses** — the Avalon memory port (`mem_*` @
    `mem_clk`), the DRP proxy, `clkctl`/`clkstat`, `tmds_o`, `rsv_*`. These
    are wide, single-clock, and **registered on both sides**. The reason is
    DFX timing closure: a partition pin routes worse than an ordinary net
    (the router can't optimise across the locked boundary), so each crossing
    gets a full clock period. "Nothing fast crosses" means keep
    DDR/SERDES/PHY/high-rate logic entirely on the shell side — never
    straddling the boundary.
  - **Tier-0 raw I/O** — keyboard, joysticks, IEC, and on the R6 the
    cartridge port and I2C buses. These are `in`/`out`/`oe` triples passed
    **combinationally**: the shell owns only the IOB (buffer, driver,
    tri-state), and the *logical* pad signal is wired straight across with no
    register. That is deliberate — cycle-exact protocols need it. The
    timing-critical bus logic lives in the RM on the (slow, ~1–8 MHz) core
    clock and drives/samples the pad directly; the combinational crossing adds
    propagation delay but **not clock cycles**, so cycle-exactness is
    preserved (there is ample slack for a full RM→pad→device→pad→RM round trip
    within one core cycle). Do **not** register these, and don't treat them
    as "buses" — they get I/O-delay / false-path treatment, not the
    both-sides-registered rule.


## 3. Inputs you need before you start

From the **shell release** (this repo's `build/<board>/` after a
`make BOARD=<board> static` run, or a published release):

1. `static_locked.dcp` — the frozen shell. **This is the ABI.** Every core in
   a catalog must link the *same* file, byte-for-byte, or partials won't be
   interchangeable (`pr_verify` is how you prove it).
2. The board's common child constraints, `boards/<board>/constr/child.xdc` —
   you don't handle this file yourself; the `child` flow stage applies it
   automatically (§5.3).
3. A reference routed checkpoint of an already-built core to `pr_verify`
   against — the seed config `build/<board>/config_a_routed.dcp` (democore).

Facts baked into that shell you must match:

- Part: `xc7a100tfgg676-2` (QMTECH Wukong, Artix-7 100T) or
  `xc7a200tfbg484-2` (MEGA65 R6, Artix-7 200T).
- The RP instance name inside the static is **`RM`** on both boards;
  `read_checkpoint -cell RM` (the flow does this for you).
- The RP floorplan (pblock) and its **BRAM cap**: **125 RAMB36** on the
  Wukong (the static DDR3 region owns the only other BRAM column), **320
  RAMB36** on the R6. On the Wukong this is usually your binding constraint
  (§4.6, §5.4); the R6 is much roomier. The pblock itself,
  `RESET_AFTER_RECONFIG`, and `SNAPPING_MODE` are already inside
  `static_locked.dcp` — as an RM author you do **not** set them.
- **Memory readiness is handled shell-side.** The Wukong DDR3 recalibrates
  for ~2 s after a reset (the R6 HyperRAM's init is ~1.3 ms); the shell
  forces `mem_waitrequest_i = '1'` toward you while memory is not ready (or
  while the RP is decoupled), so your Avalon accesses simply stall and
  complete when the window ends. You do **not** need a calibration gate in
  the RM. `clkstat_i(2)` exposes readiness for display only ("memory
  initializing…"); correctness comes from the waitrequest, never from
  polling that bit.


## 4. PART I — converting a non-M2M core

Worked example: `picorv32-menu` — a PicoRV32 SoC that draws 720p video, reads
SD/QSPI, and requests core switches. It uses none of the M2M framework, so it
is the cleanest illustration of the pure DFX transform.

### 4.1 Start from the `rm_top` skeleton

Copy an existing `rm_top.vhd` for your board (e.g.
`picorv32-menu/src/rm_top.vhd`) so you inherit the exact ABI port list, and
replace its architecture body with your core. Your top-level design entity is
now `rm_top`; your core is instantiated inside it. Drive every output; tie
off the ports you don't use (`loader_clk_i` is just an available clock —
ignore it if your core doesn't want a 50 MHz domain).

### 4.2 Clocks — delete your MMCMs, consume ports instead

This is the biggest conceptual change and where a newcomer loses the most
time. Your flat core has a clock-generation module (an MMCM or a stack of
them). **It cannot exist in an RM.** Instead:

1. Delete the clock module from the RM source list entirely.
2. Pick which shell clock ports feed your logic. Always-available and
   *fixed*: `sys_clk_i` (100 MHz), `loader_clk_i` (50 MHz),
   `hdmi_clk_i` (the pixel clock), `audio_clk_i`, `mem_clk_i` (memory
   port). Programmable: the three `core_clk0/1/2_i`. Each clock has a
   matching synchronous `*_rst_i` — use the resets the shell hands you; do
   not invent your own power-on reset.
3. Choose a clocking strategy:
   - **Fixed-clock (picorv32 does this):** run your logic on `sys_clk_i`
     (100 MHz) and `hdmi_clk_i` (74.25 MHz for 720p). Tie `drp_req_o<='0'`
     and `clkctl_o<=(others=>'0')`. You never touch DRP, and you don't need
     a generated-clock XDC either — these clocks are real in the locked
     static and STA already knows their frequency. Zero clock code.
   - **Custom core frequency:** you need a specific rate the shell isn't
     already generating (a CPU dot clock, a fractional video clock). Use a
     `core_clk*` and **reprogram it at wake** via the DRP proxy — §4.2a walks
     the whole thing.

Why you can't just "use the parked clock": the shell's core MMCMs live in the
*static*, and their DRP-set frequency is volatile MMCM state that **survives
a partial swap**. At cold boot they're at the 54 MHz park, but after any
other core has run they hold *that* core's frequency. So an RM that relies on
a `core_clk*` must set it to a known value itself — even democore, which
wants 54 MHz, reprograms explicitly. (An RM on `sys_clk`/`hdmi_clk` only is
immune, because those are fixed shell clocks, never DRP-touched.)

### 4.2a Worked example — getting a core clock via the DRP proxy

Say your core needs a 25 MHz main clock. 25 MHz is an integer divide of the
100 MHz reference, so it goes on `core_clk1` (CLKOUT1). Four small pieces:

**1) Generate the preset ROM + the matching timing override.** The tool does
the MMCM register math for you and validates the VCO range. The canonical
copy lives in this repo (`tools/mmcm_drp_table.py`, self-tested against
hardware-verified vectors by `make drp-selftest`); never hand-edit the rows:

```sh
# VHDL package with the DRP register rows:
python3 tools/mmcm_drp_table.py \
    --table target=0,divclk=5,mult=40,CLKOUT1=32 \
    --name mycore_clk -o src/dfx/mycore_clk_pkg.vhd
# same thing, --xdc emits the STA override instead of the package:
python3 tools/mmcm_drp_table.py \
    --table target=0,divclk=5,mult=40,CLKOUT1=32 \
    --name mycore_clk --xdc -o src/dfx/mycore-dfx-child-clocks.xdc
```

`target=0` = CORE_A; `divclk=5, mult=40` → VCO = 100·40/5 = 800 MHz (must be
in the MMCM's legal 600–1200 MHz band); `CLKOUT1=32` → 800/32 = 25 MHz. The
package is a 42-bit-per-row table — `[41:39]` target, `[38:32]` DRP address,
`[31:16]` data, `[15:0]` read-mask — and a lookup function
`mycore_clk_row(idx)`. (See `mpatrol_clk_pkg.vhd` for a real generated file.)

**2) Instantiate the DRP master and point it at the ROM.** `clk_drp_master`
is the RM-side helper, vendored with the RM framework in the core repos
(M2M fork `M2M/vhdl/dfx/clk_drp_master.vhd`, branches `dfx-v5`/`dfx-v5-r6`).
It runs on `sys_clk_i` (fixed, so it can't be pulled out from under itself),
asserts the target MMCM's reset via `clkctl`, streams the rows through the
toggle handshake, then waits for the lock bit — the XAPP888 sequence:

```vhdl
signal rom_idx  : natural range 0 to C_MYCORE_CLK_ROWS - 1;
signal drp_done : std_logic;
...
i_clk_drp_master : entity work.clk_drp_master
   generic map (
      G_NUM_ROWS => C_MYCORE_CLK_ROWS       -- from mycore_clk_pkg
      -- defaults target CORE_A: G_CLKCTL_RST="00001000" (bit3),
      --   G_CLKCTL_RUN="00000000", G_LOCK_MASK="0001" (bit0 = CORE_A locked)
   )
   port map (
      clk_i => sys_clk_i, rst_i => not reset_shell_n_i,
      rom_idx_o => rom_idx,
      rom_row_i => mycore_clk_row(rom_idx),  -- combinational ROM lookup
      drp_target_o => drp_target_o, drp_addr_o => drp_addr_o,
      drp_data_o   => drp_data_o,   drp_mask_o => drp_mask_o,
      drp_req_o    => drp_req_o,    drp_ack_i  => drp_ack_i,
      clkctl_o     => clkctl_o,     clkstat_i  => clkstat_i,
      done_o       => drp_done
   );
```

Because you program CORE_A and the default `G_CLKCTL_RUN` is all-zero, the
core_clk1 mux already selects CORE_A — no override needed. If you'd used
CORE_B (`target=1`) you'd set the run value's bit1 and the lock mask's bit1.

**3) Gate your core out of reset on `drp_done`** so it never runs a cycle at
the wrong (pre-programming) frequency. The shell's lock-based `core_clk1_rst_i`
already holds the domain during the relock, but gating your framework/core
reset on `drp_done` too is the robust "democore pattern" — a failed wake
leaves the RM visibly dark instead of running core-dead:

```vhdl
my_core_reset_n <= reset_core_n_i and drp_done;
```

**4) Pass the generated override XDC at impl time** (§4.5), *after*
`read_checkpoint`. This is the step people forget, and it fails silently on
hardware: the shell MMCM is placed at its 54 MHz park, so without the
override STA times your 25 MHz logic *as if it were 54 MHz*, "passes", and the
board then misses timing. The generated file re-declares the real rate on
**both** MMCMs' output pins (both feed the mux; the un-programmed one must not
be left timing your logic at the park default):

```tcl
create_generated_clock -name core_a_clk1 -source [get_pins i_shell_core_clk/i_core_a/CLKIN1] \
   -multiply_by 1 -divide_by 4 [get_pins i_shell_core_clk/i_core_a/CLKOUT1]  ;# 25.0000 MHz
create_generated_clock -name core_b_clk1 -source [get_pins i_shell_core_clk/i_core_b/CLKIN1] \
   -multiply_by 1 -divide_by 4 [get_pins i_shell_core_clk/i_core_b/CLKOUT1]  ;# 25.0000 MHz
```

That's the entire DRP story; the M2M version (§5.2) is the same helper with a
longer ROM (three frequencies) and the same `drp_done` gate.

### 4.3 Video — generate TMDS words, hand them to the shell

The video seam is at the *parallel TMDS word* stage, not the pins. You:

1. Generate video (pixel timing + RGB) on `hdmi_clk_i`.
2. Run it through a TMDS encoder (picorv32 ships its own `tmds_encoder.vhd`;
   M2M cores use `vga_to_hdmi` inside `digital_pipeline_rm`). The encoder
   produces three 10-bit symbol streams.
3. Concatenate to `tmds_o(29 downto 0)`, channel *i* on bits
   `10*i+9 downto 10*i`, and drive it (Moon Patrol:
   `tmds_o <= fw_tmds(2) & fw_tmds(1) & fw_tmds(0)`). The shell owns the
   OSERDES serialisers and the pixel-clock MMCM; it turns your words into
   differential HDMI.
4. Request the pixel-clock frequency you designed for via `vclk_sel_o`
   (a 3-bit preset index into the shell's `video_out_clock` DRP FSM, e.g.
   `"010"` = 74.25 MHz). The shell CDCs and stability-filters it.

On the **Wukong** there is no analog/VGA and no separate PCM audio boundary:
audio rides inside the TMDS stream as data islands (the encoder handles it).
On the **R6** the boundary additionally carries VGA/VDAC (drive RGB + syncs
+ VDAC control on your pixel domain) and a PCM pair
(`audio_left_o`/`audio_right_o` @ `audio_clk_i`) into the shell's DAC
driver. Either way, sync loss during a swap is accepted by design — the
shell generates no video of its own; LEDs are the load indicator.

### 4.4 The other seams (only what your core needs)

- **Memory:** if your core needs external RAM, drive the single Avalon-MM
  master (`mem_*`) at `mem_clk_i`. It's latency-insensitive
  (`waitrequest`/`readdatavalid` handshake, burst-capable). The shell keeps
  refreshing while the RP is dark, so an outgoing core can even leave data for
  its successor, and it stalls you cleanly during memory init (§3). If you
  don't need RAM, tie the master idle (`mem_write_o<='0'`,
  `mem_read_o<='0'`).
- **SD / QSPI / keyboard / joysticks:** logical signals, wire straight to
  your controllers. SD is yours except during a load (on the R6, the *external*
  slot is walker-owned for the whole of a load — keep off it after firing a
  descriptor; the internal `sd2_*` slot is always yours). QSPI is the
  pass-through of §2 — remember the dummy-clock quirk.
- **Control plane:** raise `rm_alive_o` once you're running (a watchdog
  reloads the golden menu if a fresh RM never asserts it — loader phase 4).
  To trigger a core switch, write a load descriptor {source, raw-LBA or
  FAT32 chain, start, length} through the `rsv_*` register file — the
  shell's `desc_proxy` latches it and the FAT32 walker self-mounts the card
  and streams the partial into ICAP (`shell_desc.h` in picorv32-menu is the
  firmware-side view; `DESIGN.md` decisions 2–4 the rationale).

### 4.5 Build flow (non-M2M)

The canonical child build is this repo's flow:

```sh
make BOARD=wukong child RM_DCP=/path/to/rm_mycore_synth.dcp NAME=mycore \
     RM_XDC="/path/to/mycore-dfx-child-clocks.xdc"
make BOARD=wukong verify   # auto-globs every config_*_routed.dcp in build/;
                           # EXTRA_CONFIGS=<dcp...> adds routed configs from core repos
```

You produce `rm_mycore_synth.dcp` yourself (out-of-context synthesis in your
core repo — `picorv32-menu/scripts/build.tcl` stages a/b below); the `child`
stage links it, applies the board child XDC + your `RM_XDC` list, routes and
writes the bitstream. Under the hood the shape is the canonical RM flow;
learn it once:

```tcl
set part xc7a100tfgg676-2   ;# Wukong (R6: xc7a200tfbg484-2)

# (a) ELABORATE — fast syntax/hierarchy check, no XDC
synth_design -rtl -top rm_top -part $part

# (b) SYNTHESIZE OUT-OF-CONTEXT — the key DFX flag.
#     -mode out_of_context suppresses I/O buffer insertion, because your
#     "ports" are partition pins into the shell, NOT device pads. You want
#     NO IOBs. This yields a self-contained module checkpoint.
synth_design -top rm_top -part $part -mode out_of_context
write_checkpoint -force build/rm_<core>_synth.dcp
report_utilization -file build/rm_<core>_util.rpt   ;# CHECK BRAM cap here (§3)

# (c) IMPLEMENT against the locked shell (= the flow's `child` stage)
open_checkpoint build/<board>/static_locked.dcp     ;# open the frozen shell
read_checkpoint -cell RM build/rm_<core>_synth.dcp  ;# drop your module into cell RM
read_xdc boards/<board>/constr/child.xdc            ;# common child constraints (§5.3)
read_xdc -unmanaged src/dfx/mycore-dfx-child-clocks.xdc  ;# ONLY if you reprogrammed a core clock
#   ... plus RM-internal timing exceptions (see §4.6 / §7) ...
opt_design
place_design
route_design                                 ;# routes ONLY inside the RP; static is locked
write_bitstream -force -bin_file build/config_<core>
#   -> produces build/config_<core>_pblock_RM_partial.bin  <-- THIS is your deliverable

# (d) VERIFY interchangeability
pr_verify -initial build/<board>/config_a_routed.dcp \
          -additional build/config_<core>_routed.dcp
```

Notes that trip people up:

- After `read_checkpoint -cell RM`, the pblock, `RESET_AFTER_RECONFIG` and
  all static placement/routing come *from the checkpoint*. You add nothing
  floorplan-wise.
- RM-targeting XDCs are read `-unmanaged` so they act on the run but are
  never serialized into checkpoints — a baked RM-cell constraint would
  replay into every later child link and error on RMs that lack the cells
  (§5.3's ownership note).
- `write_bitstream -bin_file` emits both the full `.bit` and the **partial**
  `*_partial.bin`. The `.bin` (headerless, ICAP bit-swap done in fabric) is
  what the loader eats — **never** feed it a `.bit`.
- `pr_verify` passing is the contract: it proves your partial and the
  reference share an identical static, so either partial is safe to load on
  the other's full bitstream.

### 4.6 The timing constraints you *will* hit (non-M2M)

Even a bare core usually crosses clock domains internally (e.g. a video
raster counter on `hdmi_clk` read by the CPU on `sys_clk`). Those crossings
were fine in your flat build because the tools knew the two clocks were
unrelated. In the RM link they now share the shell's clock tree and STA
tries to time them together — impossibly tight (tens of ps) — which both
fails timing *and* distorts the router. You fix this with **datapath-only
max-delay exceptions** on your synchronizers, applied in-memory in the impl
stage. From `picorv32-menu/scripts/build.tcl`:

```tcl
# raster line, hdmi_clk -> sys_clk (a 2-FF synchronizer that tolerates any skew)
set_max_delay -datapath_only 10.000 \
   -from [get_clocks hdmi_clk] -to [get_cells {RM/i_soc/raster_meta_reg[*]}]
# colour registers, sys_clk -> hdmi_clk
set_max_delay -datapath_only 13.468 \
   -from [get_clocks sys_clk_100] -to [get_cells {RM/i_vdp/*_color_meta_reg[*]}]
```

`-datapath_only` means "ignore clock skew/uncertainty on this path, just cap
the raw combinational delay" — exactly right for a synchronizer that is safe
against any skew by construction. §7 explains the whole family of these.

### 4.7 Package and load

Hand the shell the `.bin` (tools in this repo's `tools/`):

- Over UART: `python3 tools/send_partial.py config_<core>_pblock_RM_partial.bin
  --port /dev/ttyUSB1` — 2 MBd, no flow control; the loader is sync-word
  gated, so an interrupted upload never corrupts the shell (just resend).
- From SD: put the `.bin` on the card and send a descriptor —
  `python3 tools/send_descriptor.py` (raw LBA or FAT32 chain after
  self-mount; `tools/fat32_locate.py` finds a file's start cluster). The
  shell streams the partial through ICAP itself and echoes status bytes on
  TX. This is the same path the menu RM drives through `rsv_*`.

That is the entire non-M2M conversion. If your core is not M2M-based, you are
done — stop here.


## 5. PART II — the M2M framework additions

An M2M core (Moon Patrol, VIC20, C64, the menu-in-M2M) carries the whole M2M
stack — QNICE CPU, ascal scaler, OSM overlay, vdrives, the audio/video
pipeline — *inside* the RM as library code. None of it is a shell service.
Everything from Part I still holds; this section is what's *added*. The
worked example is `MoonPatrolMEGA65_r3_r6`, the newest core in the catalog,
the first 3-clock RM, and the first to exist for both boards.

### 5.1 The `*_rm` file forks

M2M's flat top-level files each have a DFX twin that is the same file with
only the shell-owned pieces carved out. You use the twin in the RM file list
and drop the flat one. They are deliberately kept as reviewable diffs against
their originals, on the M2M fork branches `dfx-v5` (Wukong) / `dfx-v5-r6`
(R6):

| flat file | RM twin | what was carved out |
|---|---|---|
| `top_wukong.vhd` / `top_mega65-r6.vhd` | `rm_top.vhd` / `rm_top_r6.vhd` | IOBs, clocks, memory controller, serialisers → all now ports |
| `framework_wukong.vhd` | `framework_rm.vhd` | `shell_clk_base` (ex `clk_m2m`), `video_out_clock`, reset manager, memory wrapper |
| `av_pipeline.vhd` | `av_pipeline_rm.vhd` | (just re-plumbs to the `_rm` child) |
| `digital_pipeline.vhd` | `digital_pipeline_rm.vhd` | the OSERDES serialisers (→ shell); TMDS words now exit on `tmds_o` |
| `mega65.vhd` (your core) | `mega65_rm.vhd` | the core's `clk.vhd` MMCM; clocks now arrive as ports |

The nesting is `rm_top` → (`clk_drp_master` + `framework_rm` + your
`MEGA65_Core`); `framework_rm` → `qnice_wrapper` + `avm_arbit_general` +
`av_pipeline_rm` → `digital_pipeline_rm` → `vga_to_hdmi`. The framework's
internal arbiter (`avm_arbit_general`) merges core + ascal + QNICE traffic
into the *single* boundary Avalon master for you. QNICE itself runs on
`loader_clk_i` — the 50 MHz service clock is exactly its pre-DFX rate.

**`mega65_rm.vhd` is your real work.** It is `mega65.vhd` with `clk.vhd`
removed and the core/video clocks turned into input ports. Keep the same
entity name (`MEGA65_Core`) so exactly one of the two files is ever in a file
list. Re-derive it by re-applying this transform whenever you rebase the
upstream core.

### 5.2 Clock programming via the DRP proxy

Identical machinery to §4.2a, just a bigger ROM. Moon Patrol wants three
frequencies at once and puts each on the output whose capability fits:

- video **48 MHz** on `core_clk0` (CLKOUT0),
- main **30 MHz** on `core_clk1` (CLKOUT1),
- sound **7.2 MHz** on `core_clk2` (CLKOUT2).

One generated table programs all three (rows carry the 3-bit target, so a
single ROM can even span both MMCMs — the "one-table rule"). From
`mpatrol_clk_pkg.vhd`, regenerated by:

```sh
python3 tools/mmcm_drp_table.py \
    --table target=0,divclk=5,mult=36,CLKOUT0=15,CLKOUT1=24,CLKOUT2=100 \
    --name mpatrol_clk -o CORE/vhdl/dfx/mpatrol_clk_pkg.vhd
```

`clk_drp_master` is instantiated exactly as in §4.2a (Moon Patrol wires
`done_o => drp_done`, then gates the framework reset with
`reset_shell_n_i and drp_done`). Runtime clock *muxing* (turbo, C64
flicker-fix dual-speed) uses `clkctl_o` bits to pick shell output-mux
sources after `done`; you never instantiate a `BUFGMUX` — the crossbar is
static.

For a *fractional* video clock (VIC20's 70.926 MHz, C64's flicker-fix pair)
you must use `core_clk0` — it's the only fractional-capable output. If you
need two live-switchable speeds, they map onto CORE_A/CORE_B behind the mux
bit; see `FEASIBILITY-C64-RM.md §3` for that exact pattern.

### 5.3 The child XDC files (this is the part with no shortcuts)

When the shell was locked, every constraint that targeted RM-internal cells
was **dropped** (the cells were black-boxed). They must be re-supplied at
impl time, *after* `read_checkpoint`. Three layers, in this order — the
flow's `child` stage handles the sequencing when you pass `RM_XDC`:

```sh
make BOARD=wukong child RM_DCP=build/rm_mpatrol_synth.dcp NAME=mpatrol \
     RM_XDC="/path/to/qnice-rm.xdc /path/to/mpatrol-dfx-child-clocks.xdc"
```

1. `boards/<board>/constr/child.xdc` — the **common child XDC**, shipped
   and applied by this repo automatically. Boundary-level rules that apply
   to every RM: generic `cdc_stable` max-delays, the ascal clock-domain
   waivers (all `-quiet`, inert if your RM has no ascal), and the
   loader↔core / fixed-clock-pair async groups.
2. Your **RM-framework XDC** (e.g. the M2M fork's `qnice-rm.xdc`) — the
   framework's *internal* constraints: the QNICE sdcard 25 MHz divider
   clock, EAE multicycles. Passed via `RM_XDC`.
3. Your **generated per-core clock override**
   (`<core>-dfx-child-clocks.xdc`, from `mmcm_drp_table.py --xdc`). Same
   reason as §4.2a step 4, now for three clocks on both MMCMs:

```tcl
create_generated_clock -name core_a_clk0 ... -multiply_by 12 -divide_by 25  ... ;# 48.0000 MHz
create_generated_clock -name core_a_clk1 ... -multiply_by 3  -divide_by 10  ... ;# 30.0000 MHz
create_generated_clock -name core_a_clk2 ... -multiply_by 9  -divide_by 125 ... ;# 7.2000 MHz
# ... and the identical trio on i_core_b ...
```

Two rules a newcomer gets wrong: constrain **both** `i_core_a` and `i_core_b`
even if you program only one, and constrain **all** the outputs you use on
each.

One subtlety the common child XDC handles that deserves understanding —
**the loader↔core async clock group**, the classic DFX gotcha: in the flat
build QNICE and the core sit on *separate, unrelated* MMCM trees, so their
crossings are async "for free". But your child impl re-derives the core
clocks from the shell's 100 MHz reference (that's what the override does),
making them *share* `loader_clk`'s ancestor — so STA would think they're
synchronous with a near-zero requirement and time every QNICE↔core crossing
tightly. `set_clock_groups -asynchronous` between `loader_clk` and the
`core_clk*` group restores CDC treatment.

**Constraint-ownership rule (the V3 lesson, since executed).** Everything
read *managed* into a build is serialized into its checkpoint and replays
into every later link — a QNICE-internal generated clock baked into the
static once errored out the picorv32 menu RM, which has no such register.
Hence the current split: this repo's XDCs constrain only the static and the
boundary; all RM-internal constraints live in the core repos and are read
`-unmanaged` via `RM_XDC` (acting on the run, never serialized). If your
child link errors on a constraint targeting cells your RM doesn't have,
some constraint is on the wrong side of that split — guard it with
`get_pins -quiet` + an existence check, or move it to the right file.

### 5.4 BRAM fit — the usual wall (Wukong)

The Wukong RP caps at 125 RAMB36 (§3); M2M cores routinely synthesize to
~126–132 tiles and must be trimmed. (The R6's 320-tile cap makes this a
non-issue there so far.) Learned levers (from the VIC20 build and the C64
feasibility study):

- **Shrink one big cascaded memory**, don't shave scattered small ones.
  Freeing scattered 2-RAMB36 holes just makes synthesis re-inflate RAMB18 to
  backfill (~½ tile net). VIC20 cut its D64 mount buffer from 197376 (40-track
  +errors) to 174848 (std 35-track), freeing ~6 RAMB36 → ~120 tiles.
- The generic `dualport_2clk_ram`/`tdp_ram` **must** pass `MAXIMUM_SIZE`/
  `MAX_DEPTH` down, or an 18-bit-addressed buffer allocates the full 256 KB
  (the "dead-generic" bug fixed in VIC20 commit 6d943f9). Check yours.
- Small true-dual-port mems can't move to LUT-RAM. Don't count on it.

Check `report_utilization` after OOC synth (stage b), *before* you spend ten
minutes on a place-and-route that will fail to fit. (Moon Patrol, a small
arcade core, fits comfortably; the big home computers are the tight ones.)

### 5.5 One non-project-mode footgun

M2M pulls in XPM (Xilinx Parameterized Macros) CDC/FIFO primitives. In
non-project batch mode Vivado does **not** auto-scan for them, so all their
built-in timing constraints are silently skipped. Call `auto_detect_xpm`
after reading sources (see `read_rm_sources` in the build script). Miss it and
you get a "clean" build that's subtly unconstrained.

### 5.6 M2M build script shape

Same stages as §4.5 (`rm_elab` / `rm_synth` in the core repo, then this
repo's `child` / `verify`), plus: the big curated source list (the flat list
*minus* everything the shell owns, *plus* the `dfx/*_rm` twins,
`clk_drp_master`, and the generated `<core>_clk_pkg`), the `RM_XDC` files
from §5.3, `auto_detect_xpm`, and often a `phys_opt_design` between place
and route for the tighter timing. See
`MoonPatrolMEGA65_r3_r6/CORE/wukong-dfx-build.tcl` / `r6-dfx-build.tcl`
(or the VIC20 one) end to end.


## 6. Conversion checklist

Skeleton:
- [ ] Copy your board's `rm_top.vhd`/`rm_top_r6.vhd`; keep the ABI port
      list byte-identical.
- [ ] Instantiate your core inside it; **drive every output**, tie off unused
      (incl. QSPI group if unused: clk `0`, csn `1`, d_o/oe `0`; `rsv_o` all
      zero unless you fire load descriptors).

Clocks:
- [ ] Delete your core's MMCM/`clk.vhd` from the source list.
- [ ] Consume shell clock ports; use the shell's `*_rst_i`, not your own POR.
- [ ] Fixed clocks (`sys_clk`/`loader_clk`/`hdmi_clk`) only → tie
      `drp_req_o<='0'`, `clkctl_o<=0`, no clock XDC needed.
- [ ] Any `core_clk*` used → generate the DRP table + override XDC (§4.2a),
      instantiate `clk_drp_master`, gate reset on `drp_done`, and constrain
      **both** `i_core_a` and `i_core_b`. Fractional freq → `core_clk0` only.

Video:
- [ ] TMDS-encode on `hdmi_clk_i`; drive `tmds_o` (chan *i* = `10*i+9:10*i`).
- [ ] Request pixel clock via `vclk_sel_o`.
- [ ] R6 only: drive the VGA/VDAC group and the PCM `audio_left/right_o` pair.

Seams:
- [ ] Avalon master idle if no RAM; else handshake at `mem_clk_i` (no RM-side
      calibration gate — the shell stalls you via waitrequest).
- [ ] Raise `rm_alive_o`.
- [ ] QSPI flash: send dummy clocks first (first ~3 USRCCLKO edges swallowed).
- [ ] R6 only: after firing a load descriptor, keep off the external SD slot
      (`sd_*`) — the walker owns it for the whole load.

Build:
- [ ] `synth_design -mode out_of_context`; check `report_utilization` BRAM
      ≤ 125 (Wukong) / ≤ 320 (R6).
- [ ] `make BOARD=<board> child RM_DCP=... NAME=... RM_XDC="..."` — clock
      override + framework XDCs via `RM_XDC`; for M2M sources remember
      `auto_detect_xpm` at synth; add `-datapath_only` exceptions on your
      synchronizers.
- [ ] Take the `config_<name>_pblock_RM_partial.bin`.
- [ ] `make BOARD=<board> verify EXTRA_CONFIGS=...` (`pr_verify` against the
      catalog reference) — must pass.

Load & board sanity (from hard-won notes):
- [ ] Feed the loader the **`.bin`**, never the `.bit` — 2 MBd on both boards.
- [ ] Wukong: board LEDs and buttons are **active-low** — blink patterns read
      inverted.
- [ ] After a load attempt the shell's verdict LED (Wukong led1, R6 red
      mainboard LED) tells you what ICAP thought: solid = never synced,
      slow blink = synced but error, fast blink = accepted (BOUNDARY.md §v5).


## 7. Crash course: the timing/placement constraints in this flow

The constraint idioms above, explained once, plainly.

- **`create_generated_clock`** — "this pin carries a clock derived from that
  source at ratio M/D." Needed because the shell's MMCMs are *inside the
  locked static*, placed at their park frequency; only you know the real
  frequency your DRP write will set. Without the override, STA analyses your
  logic at the wrong (usually slower) rate and passes builds that fail on
  hardware.

- **`set_false_path`** — "never time this path." Correct only when the two
  endpoints are genuinely unrelated (async domains crossed through a proper
  synchronizer, or a static-quasi-static signal). Overuse hides real bugs;
  each one in the child XDC has a specific justification.

- **`set_max_delay -datapath_only N`** — the softer cousin: "cap the raw
  combinational delay at N ns, ignore clock skew/uncertainty." The right tool
  for a 2-FF CDC synchronizer — it bounds the crossing so a captured value is
  stable, without imposing an impossible full-timing requirement. This is
  what both the picorv32 raster/colour CDCs and the framework `cdc_stable`
  rules use.

- **`set_multicycle_path -setup K -hold K-1`** — "this result is allowed K
  cycles, not one." Used for slow iterative logic like QNICE's EAE
  multiply/divide, whose operands hold steady across several cycles.

- **`set_clock_groups -asynchronous`** — "these whole clock groups are
  mutually async; don't time *any* path between them." The blunt,
  group-level version, used for loader↔core precisely because the child impl
  accidentally makes them share an ancestor (§5.3).

Runtime behaviour worth naming: **memory-ready stalling** is not a
constraint but a shell mechanism — `mem_waitrequest_i` is forced high while
memory is initializing or the RP is decoupled, so an RM's Avalon accesses
stall instead of vanishing. It replaces the RM-side calibration reset gate
that earlier boundary revisions needed.

Placement primitives you'll *see* but not set as an RM author (they live in
`static_locked.dcp`; documented so the reports make sense):

- **pblock** — the RP region. It is *ranged over every grid type it spans*
  (SLICE, RAMB36, RAMB18, DSP48 — on the R6 also the unused GTP/XADC hard
  blocks inside its rectangle) because a coarse rectangle that clips a
  column trips DRC HDPR-45. `SNAPPING_MODE ON` lets Vivado align the
  region to legal reconfig-frame boundaries.
- **`RESET_AFTER_RECONFIG`** — the RP is held in reset until a fresh partial
  finishes loading, so a half-streamed core never runs.
- **`HD.RECONFIGURABLE`** — the property (set once, at shell build) that marks
  the cell as a reconfigurable partition in the first place.

If a report or DRC mentions one of these, it's the shell's, not yours — you
inherit them through the checkpoint.
