> **Historical (pre-v5 names).** This spec predates the mega65-shell repo;
> signal names follow the old M2M-flavoured scheme. v5 rename map:
> `qnice_clk/qnice_rst` -> `loader_clk/loader_rst`, `hr_clk/hr_rst` ->
> `mem_clk/mem_rst`, `reset_m2m_n` -> `reset_shell_n`. Semantics are
> unchanged; see ../BOUNDARY.md for the current contract.

# Boundary v3 — memory-ready stalling, QSPI pass-through, third core clock

Delta against BOUNDARY-V2.md. Built as one deliberate shell revision
2026-07-13 (MiSTer2MEGA65 branch `dfx-v3`, boundary commit af7fae7 plus
cd8ba54/60eb804): static locked at WNS +0.106 / 0 violations, full
catalog (democore + VIC20 + C64) rebuilt against it, pr_verify
all-interchangeable, v2 partials retired. Hardware acid tests pending
(see Validation). This doc also captures the interim generic-rename
revision (2026-07-10, `dfx-vic20` ea2a50c) that shipped between v2 and
v3 without its own document.

## Generic core-clock names (interim revision, 2026-07-10)

The v2 pins `main_clk_i`/`video_clk_i` were renamed to
`core_clk1_i`/`core_clk0_i` (+ matching `_rst_i`). Semantic names were
the wrong abstraction: it is the RM's job to map its functions (video /
cpu / main / ...) onto the shell's outputs given its needs and the
MMCM's physical constraints. What is shell-side fact — and therefore
part of the boundary contract — is each output's *capability*:

| pin | MMCM output | mux (clkctl) | capability |
|---|---|---|---|
| core_clk0_i | CLKOUT0 of CORE_A/B | bit 0 | fractional divide (CLKOUT0 is the only `_F`-capable output) |
| core_clk1_i | CLKOUT1 of CORE_A/B | bit 1 | integer divide only |
| core_clk2_i | CLKOUT2 of CORE_A/B | bit 5 | integer divide only; on CORE_A, CLKOUT2 is shared with the cascade reference (new in v3, see below) |

An RM that needs a fractional frequency (VIC20's 70.926 MHz video) puts
it on core_clk0 itself; the v2-era shell-side CLKOUT0↔CLKOUT1 swap
(which existed only because the pin was literally named "video") is
reverted — core_clk0 = CLKOUT0 straight through. The democore parks on
core_clk1 = 54 MHz, and per the v2 RM clocking rule still reprograms it
explicitly at wake.

## Memory-ready stalling: the unified fence term

The hw-root-caused deadlock class (2026-07-13): commands
accepted-and-dropped while the memory subsystem is unavailable. The
Wukong DDR3 recalibrates for ~2 s after a button reset; if the
QNICE/framework boot sequence overlaps that window (cold boot, long
press), ascal's framebuffer preload reads are accepted, never served,
and there is no timeout — deterministic black screen or stripe wedge.

v3 fix: express "memory not ready" in-band as Avalon back-pressure. The
shell's fence forces `mem_waitrequest_i = '1'` toward the RM while
**(decoupled OR NOT mem_ready)**:

```vhdl
mem_stall         <= decouple_hr or not ddr3_calib_complete;
mem_waitrequest_i <= avm_waitrequest or mem_stall;
```

Avalon-MM permits indefinite waitrequest, so commands stall and
complete when the window ends instead of vanishing. This *unifies* the
decouple fence with memory readiness (the v2 fence gated read/write to
zero during decouple — same accepted-and-dropped failure shape) and
replaces the RM-side calibration reset gate proven in the flat debug
build: **no RM change, no ABI change**. The dummy-beat fence for write
bursts orphaned by a swap is kept, and `avm_increase` gained abort-drain
hardening (cd8ba54): a read presented mid-write-burst self-completes the
announced wide burst with byteenable-0 dummies before the read is
served — a plain read-stall would head-of-line-block the drain writes
and never self-heal.

`mem_ready` derivation is deliberately shell-internal so nothing
memory-technology-specific crosses the boundary: Wukong = UberDDR3
`calib_complete` (self-test skipped, see below); R6 = ~1.3 ms post-reset
timer, since the HyperRAM controller has no init-done output.

## clkstat becomes general shell status

| bit | meaning |
|---|---|
| 0 | CORE_A locked (v2) |
| 1 | CORE_B locked (v2) |
| 2 | memory subsystem ready (v3, informational) |
| 3 | reserved |

Bit 2 is informational only — an RM may display "memory initializing";
correctness comes from the waitrequest force, never from polling this
bit.

## QSPI flash pass-through

New partition pins (RM side):

| signal | dir | width | notes |
|---|---|---|---|
| qspi_clk_o | out | 1 | flash clock *request* — proxied, see below |
| qspi_csn_o | out | 1 | chip select, active low |
| qspi_d_i | in | 4 | data read-back from the pads |
| qspi_d_o | out | 4 | data drive value |
| qspi_d_oe_o | out | 4 | per-bit output enable (in/out/oe triple per pad) |

The clock is the one non-obvious part: on 7-series the flash clock is
the dedicated CCLK *configuration* pin, drivable post-config only
through `STARTUPE2.USRCCLKO`. STARTUPE2 is a one-per-device config
primitive and must live in the static — the same rule as the shell's
ICAPE2 — so the boundary carries a clock *request* and the shell proxies
it:

```vhdl
USRCCLKO => rm_qspi_clk and not decouple,
```

Documented silicon quirk: the first ~3 USRCCLKO edges after
configuration are swallowed while the internal CCLK mux hands over —
flash drivers must send dummy clocks first (standard practice anyway).

Decouple parking: CS and data park inactive and the clock is gated
while the RP is dark (`qspi_db(i) <= rm_qspi_d(i) when oe='1' and
decouple='0' else 'Z'`), which also enforces the safety rule that the
ICAP loader must never race an RM flash transaction. An RM that does
not use the flash ties the group off: clk '0', csn '1', d_o/oe all '0'
(democore does).

## Third core clock: core_clk2

One extra generic output — the cheap-insurance end of the v2
over-provisioning discussion (BUFGCTRL budget: ~1-2 per single-source
output, and the BUFG fix below freed 5). core_clk2 = CLKOUT2 of both
MMCMs behind a mux selected by clkctl bit 5. Constraint to document in
RM frequency tables: on CORE_A, CLKOUT2 doubles as the CORE_B cascade
reference, so an RM using the cascade (clkctl bit 2) and core_clk2 from
CORE_A simultaneously gets the same frequency on both — that
combination fixes core_clk2-from-A to the cascade reference. The common
child XDC's clock groups gained core_clk2.

clkctl v3 summary: bit0 core_clk0 A/B, bit1 core_clk1 A/B, bit2 CORE_B
input cascade, bit3 CORE_A reset, bit4 CORE_B reset, bit5 core_clk2
A/B, bits 6-7 reserved.

## Non-boundary shell changes in the same rebuild

- **shell_core_clk BUFG fix** (backported from dfx-r6): the MMCMs feed
  the BUFGMUX_CTRLs directly; the per-output BUFGs were redundant
  (BUFG→BUFGMUX cascades are A200T-fatal and the A100T passed by luck).
  Frees 5 BUFGCTRL sites.
- **SKIP_INTERNAL_TEST=1** in the UberDDR3 wrapper: ~2 s faster resets,
  no self-test-pattern residue frames at wake, and a shorter not-ready
  window for the stalling term to cover.
- **hr_clk +0.100 ns setup uncertainty**: the v2 static froze WNS
  +0.010 on a controller-internal path that every child re-reported;
  the overconstraint buys rebuild-seed margin (v3 locks at +0.106
  *with* the uncertainty applied).

## Constraint ownership rule (lesson, 2026-07-14)

Everything read into the static build — including `WUKONG-DFX.xdc` —
is **baked into `static_locked.dcp` and replays into every child
link**, even children that read no XDC of their own. The picorv32 menu
RM hit this: a `create_generated_clock` on a QNICE-internal register
(the sdcard 25 MHz divider) errored out a child whose RM has no such
register. Interim fix: the constraint is guarded with `get_pins -quiet`
+ `llength` (takes effect at the next static rebuild, since the live
static has the unguarded form baked in).

The rule going forward: the static XDC may constrain only the static
region and the boundary; **RM-internal constraints (QNICE sdcard_clk,
EAE multicycles) are per-RM property and belong in per-RM child XDCs**
— a `qnice-rm.xdc` read by the initial config link and every
QNICE-framework child, next to the common `wukong-dfx-child.xdc`.
Staged for the next static rebuild (see TODO.md).

## Validation

Build-time: static + all three catalog RMs timing-clean, pr_verify
all-interchangeable (2026-07-13). **Hardware-verified the same day**:
cold JTAG push comes up *without* a reset press (the old deterministic
black screen), long presses recover clean every time, swap stress
democore↔VIC20↔C64 solid, no lockups obtainable, short presses remain
fixed. Known cosmetic: on a short press the monitor stays synced, so
the recalibration stall window is briefly *visible* as transient
garbage (long press hides it behind the mode-resync mute). Polish hook
if wanted, RM-side only: blank video while clkstat[2] = 0.

R6 mirror: executed the same day on `dfx-r6` (81848eb) — same fence
term (timer-based mem_ready), QSPI pass-through, core_clk2, shared
BUFG-fixed shell_core_clk; both configs WNS +0.173, pr_verify
interchangeable. R6 deltas live in BOUNDARY-R6.md.

Everything not named here is BOUNDARY-V2.md (and transitively V1)
unchanged.
