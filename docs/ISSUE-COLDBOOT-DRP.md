# Issue: full-boot / alternating wakes show no core video (overlay OK)

Status: **FIXED — root cause found and hardware-confirmed 2026-07-12.**
Upstream ascal bug: the avl reset clause has `avl_write_i<='0'`
commented out, so a reset landing mid-write freezes a stale phantom
write request through the whole reset hold; at release, a race against
the avalon chain's own reset release turns it into a truncated burst
that permanently desyncs downstream burst counters and starves the
o-side line fetches. One-line fix (restore the clear) verified on
Wukong hardware with the debug taps: repeated short presses always
recover, eat counter stays 0. See "v5 capture" section for the full
mechanism; ported to dfx-vic20/wukong/dfx-r6 + vendored VIC20/C64
copies. Upstream report to sy2002/MJoergen pending. The dated sections
below record the investigation trail.

## Symptom

Booting a **full** DFX config of a real core (VIC20 / C64) brings up the
OSM overlay, keyboard and menu, but no core video behind it. Arriving at
the *same* RM via a partial swap (config_a full, then stream the partial)
works. Democore full boots are unaffected.

## What the symptom localizes to

Overlay alive proves: QNICE (qnice_clk), the OSM/HDMI path (hdmi_clk from
the static video_out_clock), the hr domain, and the framework are all
running — so for the *ungated* RMs (see below) the failure is confined to
the core clock domains or the framebuffer write path:

1. **Core clocks dead**: a stuck `clkctl` reset bit or an MMCM that never
   relocks keeps `core_clk0/1_rst` asserted forever
   (`xpm_cdc_async_rst` in `shell_core_clk` only deasserts on lock).
2. **Core running at the 54 MHz parking preset** (the DRP wake never took
   effect): VIC20 at 54 instead of 35.46/70.93 MHz produces video timings
   ~1.5× off — ascal can't capture the input, black core window, overlay
   untouched. *Democore is immune by construction* (its programmed preset
   equals the parking preset), which matches "real cores fail, democore
   doesn't".
3. **Framebuffer write chain wedged** (orphaned Avalon burst — the same
   class as the hardware-confirmed swap-back fence bug of 2026-07-07).

## Ruled out by analysis

- **Cold-vs-warm MMCM register state (RMW hazard)**: rows write all
  functional bits (mask=0) and preserve only reserved bits (mask=1) —
  but preserved bits are never DRP-written, so after any earlier
  programming they still hold their configuration-attribute values. The
  DI actually written is therefore **bit-identical** at first-ever boot
  and after prior swaps. Not the cause.
- **Handshake asymmetry**: `clk_drp_master` (RM) and `drp_proxy` (shell)
  are both reset by the same `reset_m2m_n`, in the same clk_100 domain,
  in both scenarios. The toggle protocol starts from zeroed state either
  way (GSR at full boot; decouple-hold + GSR-on-partial at swap).
- **reset_manager timing**: power-on hold is ~70 ms (20 ms debounce +
  50 ms RST_DURATION) — orders of magnitude beyond MMCM lock time, so
  the parking MMCMs are locked before the DRP wake starts in both
  scenarios.
- **Mechanism 3 at wake is improbable**: ascal's framebuffer *writer*
  sits in the core video domain and only bursts after it has captured
  input video (≥ 1 frame ≈ 20 ms), while the DRP wake window closes
  ≈ 0.4 ms after reset release; the *reader* and OSM run in static
  domains that never stop. It also cannot explain the full-vs-partial
  asymmetry — the wake timeline is identical.

## Structural finding (worth fixing regardless)

The `drp_done` reset gate — hold the framework in reset until the DRP
wake has completed and the MMCM locked (`fw_reset_* <= reset_*_n and
drp_done`) — is present in the **Wukong democore rm_top** and in **R6
rm_top_r6**, but:

- **VIC20 rm_top: `done_o => open`** — no gate at all;
- **C64 rm_top: `drp_done` used only for the flicker-mux glue** — the
  framework reset is ungated.

This asymmetry doesn't by itself explain full-boot-vs-swap, but it
explains the *visibility* of the symptom: on ungated RMs a silent DRP
wake failure leaves the overlay alive (exactly what's observed), whereas
on gated RMs the same failure would show a completely dark system.
Carrying the gate into VIC20/C64 is an RM-only change — partials remain
valid against the released static.

## Discriminating experiments (Wukong, ~minutes each)

0. ~~Define the failing path precisely~~ **ANSWERED (user, 2026-07-11):
   it was a JTAG push** of the full config, not QSPI power-on. So
   "cold boot" ≡ any full-configuration load; QSPI/power-supply-specific
   causes are out. Note this keeps the DDR3 angle alive in a different
   form: a full config (JTAG or QSPI) asserts `ddr3_arst` through the
   POR and forces recalibration, whereas the partial-swap path never
   touches the DDR3 — that is a genuine full-vs-partial asymmetry.
1. ~~Full-boot `config_democore.bin`~~ **ANSWERED (user, 2026-07-11):
   overlay was present** ⇒ `drp_done` fired ⇒ the DRP wake (handshake,
   all rows, relock) **completes from a full boot**. Handshake-failure
   variants of mechanism 1 are dead. Retest should additionally note
   whether democore **core video** was present (see matrix below).
2. **After a failed full boot: short press vs hold ≥ 1.5 s.** Wukong
   wiring makes this a three-way split: a short press pulses
   `reset_core_n` — which resets the DDR3 controller and forces
   recalibration (`ddr3_arst`, shell_top:764) but does *not* touch
   `clk_drp_master`; a long press asserts `reset_m2m_n` and re-runs the
   entire DRP wake.
   - short press fixes video ⇒ memory chain was wedged (mechanism 3);
   - only long press fixes it ⇒ the wake/clock state was wrong
     (mechanisms 1/2);
   - neither ⇒ instrument (step 4).
3. **Audio pitch during the failure** (VIC20 tone / C64 SID): ~1.5× high
   ⇒ core is running at the 54 MHz parking preset (mechanism 2).
   Correct pitch ⇒ clocks are right; look at mechanism 3.
4. If needed: debug RM build with `drp_done`, `clkstat` lock bits and
   `clkctl(3)` on LEDs/UART.

### Retest matrix (per full image: democore / VIC20 / C64)

| observe | discriminates |
|---|---|
| overlay present? | framework/QNICE alive (gated RM: also proves wake done) |
| core video present? | the failure itself; democore-video-dead ⇒ mechanism 3 common to all wakes |
| audio pitch (real cores) | 54 parking vs programmed frequency |
| short-press recovery? | DDR3/memory-chain wedge |
| long-press recovery? | wake/clock state |

The most valuable single outcome: **self-clocking democore full boot
with core video OK** would clear mechanism 3's common path and pin the
failure to the frequency-*changing* wake (or something core-specific);
**democore core video dead with overlay alive** would instead point
firmly at the memory chain around full-boot recalibration.

## R6 impact (HyperRAM vs DDR3)

Mechanisms 1/2 are board-agnostic (identical shell RTL), **but**
`rm_top_r6` already gates both framework resets on `drp_done`, and the
current R6 catalog is democore-only — its programmed preset equals the
parking preset, so even a failed wake is invisible. The one plausibly
**Wukong-only** amplifier is mechanism 3's trigger: UberDDR3 recalibrates
on every full configuration (~100 ms+ with early Avalon traffic stalled
open), while the R6 HyperRAM needs no calibration and is ready almost
immediately (and the shell deliberately never resets it on swaps).

Bottom line: quite possibly Wukong-only in practice, not yet proven.
Run the retest matrix (experiments 2–3) on the Wukong before the first
R6 core with a non-54 MHz preset ships to testers. The confirmed
democore result (JTAG full push → overlay present ⇒ wake completes) is
directly the R6 tester Test-1 path, which is reassuring for the current
democore-only R6 package.

---

## 2026-07-11 evening: hardware evidence supersedes the theories above

### Wukong (user, democore full via JTAG)

- Full JTAG push of the gated self-clocking democore: **audio + overlay
  work, no checkerboard**. Audio proves the core clocks and the core are
  fine → the DRP wake is fully exonerated (it also completes *before*
  the gated framework runs).
- **Short reset press fixes it.** Long press wedges it again — but the
  decisive observation: **short presses alone strictly alternate**
  (odd press = works, even press = wedged). So the parity is per
  *reset/wake event*, not per reset type. The short-vs-long distinction
  was an artifact of alternating presses.
- Wedged state appearance: **fixed vertical stripes** — one captured
  line repeated down the screen (hearts/paddle absent, no motion).
  Interpretation: the scaler output repeats a single framebuffer line;
  the line-address/frame advance is stuck somewhere in the
  capture→framebuffer→output loop.
- Both press types visibly recalibrate the DDR3 (LED) — consistent with
  `ddr3_arst <= not reset_m2m_n or not reset_core_n` (also in flat,
  framework_wukong.vhd:442).

### R6 (community tester, first hardware contact 2026-07-11)

- **The swap path works**: partial loads 26 s (exactly 2 Mbps wire
  speed), picture back ~5 s after load, LED indication live, keyboard,
  menu, audio, and OSM video-mode switching all fine. The tester
  deliverable package is functionally validated.
- `m65 -q config_a.bit` (full JTAG push): **black screen, sound and
  overlay OK** — the full-boot failure **reproduces on R6**, which has
  no DDR3, no UberDDR3, no calibration. **The UberDDR3-calibration
  theory is dead.** (The Wukong recalibration correlation was
  coincidental — recalibration merely accompanies every wake event
  there.)
- Then: swap to B → *perfect* demo (hearts, paddle, scrolling
  checkerboard); swap to A → **striped, frozen, no sprites** — the same
  wedged signature as the Wukong, arriving via swaps.
- **Confounder warning**: the R6 sequence so far (full-A bad → B good →
  A bad) is consistent BOTH with wake-parity alternation AND with
  "config A bad, config B good". The Wukong data (alternation on one
  unchanging image) argues for parity, but R6 needs an A→A→A test.
- Also suspicious: tester "wouldn't call the screens inverted" — config
  B's G_INVERT_VIDEO marker should be visually obvious against A.
  Needs a direct A-vs-B color comparison when both are in the good
  state.

### What the carrier must satisfy

One bit of good/bad state that (a) exists on both boards, (b) toggles
once per wake/hr-reset event, (c) comes out of full-bitstream GSR in the
BAD phase (full boots consistently fail), and (d) survives the events
that toggle it: on the Wukong a short press (hr domain + core reset +
DDR3 recalib, framework/QNICE alive, no decouple, no DRP activity), on
the R6 a partial swap (whole RM reset via GSR+rm_reset, decouple cycled,
HyperRAM controller/fence *not* reset). The intersection is small:
shell-side hr-path state (fence counter — but it is hr_rst-reset on
Wukong presses), memory-controller internal state, the RAM device
itself, or some subtle clock/CDC phase relationship re-established per
wake.

### Next discriminating tests

R6 (remote tester, all safe):

1. **A→A→A**: swap the *same* partial repeatedly. Alternates good/bad ⇒
   wake parity confirmed, config-A-specific ruled out.
2. **VGA output during a wedged state.** The R6 analog pipeline shows
   the core's video *directly, not through the ascal framebuffer*. VGA
   moving normally while HDMI is striped ⇒ core + capture input fine,
   freeze is in the framebuffer/scaler loop. VGA also frozen ⇒ the core
   itself (or its clocks) is stuck — very different hunt.
3. Short reset press in a wedged state (does R6 recover like Wukong?).
4. A-vs-B color check in the good state (validate the G_INVERT_VIDEO
   marker at all).

Wukong (local):

5. **Flat democore, repeated short presses.** The flat build has the
   identical `ddr3_arst` wiring, ascal, and reset topology minus all DFX
   machinery. Flat alternating ⇒ every line of DFX code is exonerated
   and this is a latent M2M-framework/ascal-level issue (present
   upstream?); flat clean ⇒ the carrier is in the DFX delta (fence,
   boundary registers, shell clocking).

---

## 2026-07-11 late: flat Wukong democore REPRODUCES — DFX exonerated

Test 5 result (user): **the flat democore has the same issue.** Two
refinements from more presses:

- **Not strictly alternating** — just *most* of the time. The earlier
  "odd/even" run was a streak. This kills the clean 1-bit toggle-carrier
  model; the behavior fits a **per-reset-event race with a strongly
  biased outcome**, re-rolled at every wake.
- **VIC20 is markedly less affected** (flat AND partial): usually its
  video survives a short press, but it *can* still be wedged. Severity
  depends on the core — democore video clock is 54 MHz, VIC20
  35.47 MHz. A frequency-dependent failure probability is a race-window
  signature, not a config-content one.

### Consequences

- **Every line of DFX code is out of the suspect set**: fence, decouple,
  DRP proxy/master, drp_done gates, boundary registers, shell clocking,
  the pblock — none of it exists in the flat build. (The fence was
  already doubly exonerated: flat Wukong has no fence, and the failing
  setups use two entirely different memory backends.)
- The intersection of all failing setups (flat Wukong DDR3, DFX Wukong,
  DFX R6 HyperRAM) is the **stock M2M framework av-pipeline + democore +
  reset topology** — i.e. this is very likely a latent upstream V2.0.1
  issue that stock MEGA65 hardware would also show.
- Stock topology check: upstream `framework.vhd:443-450` gives clk_m2m
  `core_rstn_i => reset_core_n` with the comment "reset only the core
  (means the HyperRAM needs to be reset, too)" and derives `hr_rst` from
  it — so **a short press asserts hr_rst upstream as well**, same as
  both ports. Everything in the capture→framebuffer→output loop IS reset
  on every press; the good/bad outcome must therefore be decided at
  **reset release**, not carried in surviving state.

### Prime suspect: ascal reset-release race

`digital_pipeline.vhd:291`: `reset_na <= not (video_rst_i or hr_rst_i)`
— a combinational async reset into all of ascal. Inside
(`ascal.vhd:1109-1111`) the release is re-synced with a **single flop
per clock domain** (i_clk = core video, o_clk = hdmi, avl_clk = hr), so
the three domains leave reset in arbitrary order with per-event skew —
and upstream's own `set_false_path -through reset_na` removes these
paths from timing analysis entirely. A wrong release order (e.g. the
avl/o side starting while the i side still holds its half of the buffer
handshake reset) wedging the frame/line-advance handshake would produce
exactly the observed one-line-repeated output; the race odds shift with
the i_clk frequency (54 vs 35.47 MHz), matching democore-worse /
VIC20-better. Unverified — needs the VGA-during-wedge discriminator and
then targeted ascal-handshake inspection.

### Refinement (user observation, same evening): stripes appear ON the press

As soon as reset is short-pressed the picture freezes into a stripe
pattern; the repeated line is a line of the *live pre-reset frame*
(sometimes contains the paddle/ball colors), sometimes "random" stripes.
On release the picture either stays striped (wedge) or the moving
checkerboard resumes.

This pins the wedge down further rather than changing the analysis:

- The final HDMI sync is **ascal's o-side output** (digital_pipeline:
  ascal → video_overlay → vga_to_hdmi, all in hdmi_clk). So "stripes" =
  the o-side scan-out running while its **line-fetch loop delivers no
  new lines** — the output line buffer (OLBUF) replays one stale line.
  The stripe content is exactly what OLBUF happens to hold: a line of
  the pre-reset frame (paddle/ball), garbage ("random"), or — at a
  full boot, where BRAM initializes to zero — **black**. Full-boot
  black and warm-wedge stripes are the SAME deadlock with different
  buffer content. One bug, one mechanism.
- The stripes appearing immediately at every press means this is the
  *normal* transient state during/after any reset; the bug is binary:
  does the capture→framebuffer→scan-out loop **re-engage** at release
  or not.
- The re-engagement path is ascal's o_clk↔avl_clk **toggle-handshake
  read pipeline** (`o_read` → avl_read_sync/XOR pulse → avalon read →
  `avl_readack`/`avl_readdataack` toggles back; ascal.vhd:1670-1779,
  1995-2000) with level counters (`o_readlev`/`o_copylev`) and **no
  timeout**: one lost or double-counted event deadlocks it permanently,
  producing exactly the observed picture.

Checked while here:

- UberDDR3 **stalls** during calibration (`o_wb_stall <= ... ||
  state_calibrate != DONE_CALIBRATE`, ddr3_controller.v:863) — requests
  issued during recalibration pend on waitrequest, they are not dropped.
  So the corruption is in the handshake/counters at release, not a
  simple swallowed-during-calibration read.
- Candidate corruption modes still open: (a) stale in-flight
  readdatavalid beats when the memory controller is NOT reset together
  with ascal (R6 swap: HyperRAM stays alive while the RM — ascal
  included — is GSR'd mid-burst; beats of a pre-reset burst land on the
  fresh FSM and misalign the counters); (b) domain start-order at full
  boot — o_clk (hdmi) comes from the QNICE-*programmed* video_out_clock,
  so at a cold boot the o domain starts long after i/avl; (c) DFX
  decouple gating currently **drops** RM reads
  (`avm_read <= rm_mem_read and not decouple_hr`) without forcing
  waitrequest — any read escaping in a decouple window vanishes
  (DFX-only; cannot explain flat, but must be closed anyway).

### Fix plan (assuming the read-pipeline-deadlock localization holds)

0. **Confirm first (one debug rebuild):** LEDs/UART on ascal internals
   in the wedged state — `avl_read_i` stuck high? `o_readlev` vs
   `o_copylev`? outstanding-readdatavalid counter? One build tells us
   the exact deadlock point. (VGA-during-wedge on R6 remains the
   parallel core-alive check.)
1. **Sequenced reset release (framework-level, minimal, both boards +
   upstream-portable):** generate ascal's `reset_na` from a small
   sequencer instead of `not (video_rst or hr_rst)`: assert on any
   reset OR memory-not-ready; release once, after (a) memory controller
   ready (UberDDR3 calib done / HyperRAM init done), (b) all three
   ascal clocks verified toggling (covers the QNICE-programmed hdmi
   clock at cold boot), (c) a few ms of quiet. Kills the whole
   release-order/mid-flight hazard class in one place; inherently fixes
   full boot.
2. **Drain/quiesce on assertion where the controller outlives ascal:**
   extend the fence idea to reads — track outstanding read beats and
   absorb stale readdatavalid before releasing ascal; and in the DFX
   shells force `waitrequest` to the RM during decouple instead of
   dropping (`stall-don't-drop`). Shell-side = static change → bundle
   with the next static rebuild.
3. **Only if needed — ascal self-healing (upstream-worthy):** o-side
   watchdog: outstanding reads unanswered for ~1 ms ⇒ resync level
   counters and re-request at next vsync. Real ascal surgery; last
   resort.

### Debug build (2026-07-11, MiSTer2MEGA65 branch dbg-ascal-wedge, 5a61986)

Flat Wukong democore with ascal internals streamed on the UART TX pin
(115200 8N1 — **QNICE stdout is hijacked in this build**) as one ASCII
line per 250 ms: `SSSSSSSS CCCCCCCC` (status, counters, hex). led0 =
wedge flag (lit when the o-side FSM stays away from sDISP for >167 ms
or a level counter reads the out-of-range value 3); led1 keeps its
DDR3-calibration meaning. Bitstream: `CORE/build-wukong/wukong-m2m.bit`.

Status word S (read the 8 hex chars MSB-first, char N = S[31-4N : 28-4N]):

| bits | meaning | healthy |
|---|---|---|
| S[1:0] | ascal o_state: 0=DISP 1=HSYNC 2=READ 3=WAITREAD | mostly 0, flickers |
| S[3:2] | o_readlev — **3 = corrupted counter** | 0..2 |
| S[5:4] | o_copylev — **3 = corrupted counter** | 0..2 |
| S[7:6] | o_fload | 0 |
| S[9:8] | avl_state: 0=IDLE 1=WRITE 2=READ | mostly 0 |
| S[10] | avl_read_i (avalon read pending) | flickers |
| S[11] | avl_read_sr (latched request) | flickers |
| S[12] | avl_write_sr | flickers |
| S[13] | o_read request toggle | random |
| S[14] | avl_readack toggle | random |
| S[15] | avl_readdataack toggle | random |
| S[16] | i_write capture toggle | random |
| S[17] | output vsync | random |
| S[18] | i_vss input scan | random |
| S[19] | o_run | 1 |
| S[23:20] | o_vacpt(3:0) fb line pointer | random |
| S[24] | avalon waitrequest at ascal | flickers |
| S[25] | avalon readdatavalid | flickers |
| S[26] | avalon read | flickers |
| S[27] | avalon write | flickers |
| S[28] | ascal reset_na | 1 |

Counters C (free-running, wrap; "changing between lines" = event still
occurring, "frozen" = stopped): C[31:28] read requests (o_read),
C[27:24] read accepts (avl_readack), C[23:20] read data bursts
(avl_readdataack), C[19:16] capture writes (i_write), C[15:12] output
vsyncs, C[11:4] readdatavalid beats.

What to capture: a few lines in the good state, a few in the wedged
state, and the transition across a reset press. Signatures:

| wedged-state reading | conclusion |
|---|---|
| o_state=3 (WAITREAD), rq/ak counters frozen, avl_state=0, S[11]=0 | request toggle lost in the o→avl CDC |
| o_readlev=3 or o_copylev=3 | level-counter underflow (stale-beat mechanism) |
| S[10]=1 and S[24]=1 steady, ak frozen | backend wedged — memory chain never serves the read |
| avl_state=2 steady, ak counting, dk frozen | readdatavalid burst miscount |
| everything counting but wr frozen | capture side dead (would contradict the read-path theory) |

### DEBUG RESULTS (user capture, 2026-07-11 late evening): MECHANISM FOUND

Good state: o_state=DISP, levels 0, rq/ak/dk counters incrementing in
lockstep, everything flickering. (led0 glowed dimly — benign sampling
artifact: async capture of the o_readlev 1<->2 transition reads 3 for a
cycle; filtered in the next build.)

Wedged state (`101C008A AA4xx960`), fully decoded:

- **o_state stuck in sREAD, o_readlev=2, o_copylev=0, o_fload=2** — the
  post-reset 2-line preload never completed and `o_readlev<2` blocks
  further requests forever.
- avl side idle, no pending request, waitrequest=0 — memory chain up
  and willing NOW.
- **rq==ak frozen equal** (every request ascal made was accepted on the
  Avalon bus), **dk and the readdatavalid beat counter frozen** — the
  accepted bursts never returned a single beat.
- Capture writes still churning (core + i-side alive — as predicted),
  vsync counting at ~50 Hz (output scan alive).

**Conclusion: after reset release, ascal's 2-line preload issues two
read bursts; the Wukong memory chain (arbiter → avm_decrease →
avm_increase → avm_to_wb → UberDDR3) ACCEPTS them during the DDR3
recalibration window and never returns data. ascal has no timeout →
permanent sREAD deadlock → one stale line repeats (stripes), or black
after a cold boot (zeroed line buffer).** Not a CDC toggle loss, not
counter corruption, not a stuck backend.

The ~alternation falls out naturally: whether the preload (launched at
the first vsync after reset release, ~20 ms granularity) lands inside
the ~100 ms calibration window is a timing race with roughly even,
history-correlated odds; VIC20's different video timing shifts the odds
(less affected). On R6 the same accepted-but-unanswered class exists
via different eaters (decouple gating drops reads without forcing
waitrequest; HyperRAM init window at cold boot) — needs its own capture
to confirm the specific eater.

### Fix experiment (dbg-ascal-wedge 9861444, building)

`hr_rst_av <= hr_rst or not ddr3_calib_complete` gating **only the
av_pipeline's hr-side reset** (which feeds ascal's reset_na): the
preload cannot launch until the DDR3 actually serves. If repeated
presses never wedge → mechanism confirmed, this is the Wukong fix.
Follow-ups regardless of outcome:

- Find the exact eater (avm_to_wb / UberDDR3 acceptance during
  calibration) and make it stall-not-drop — the gate above removes the
  trigger, the eater is still a landmine for any master that talks
  during calibration.
- R6/DFX: same gate class (hold RM av-pipeline until memory ready is a
  no-op for HyperRAM steady-state, but decouple must stall-not-drop:
  force waitrequest to the RM while decoupled) — static rebuild item.
- Upstream: ascal read timeout/resync would make the whole class
  self-healing; report findings to sy2002/MJoergen (stock topology has
  the same reset wiring; on HyperRAM boards the window is much smaller,
  which may be why it is not a known issue upstream).

### Fix experiment result (user, same night): STILL WEDGES — calib window exonerated

With ascal held until `ddr3_calib_complete`, the identical wedge
signature reappears (o_state=sREAD, readlev=2, copylev=0, fload=2, avl
idle, rq==ak frozen, zero beats). So the recalibration window is NOT
the eater. New decisive detail from the capture: **the write path works
during the wedge** (i_write churns with avl_state always idle — write
bursts complete) — the arbiter and DDR3 serve writes while dig's reads
vanish. The eater is read-specific, between avm_decrease's master side
and the wrapper. (The calib gate is kept — correct defense, wrong
culprit. led0 glitch filter confirmed working: dark in good state,
solid on true wedge.)

**Code suspicion (avm_arbit.vhd, upstream MJoergen arbiter):** slave
acceptance is gated by `active_grant` (`s*_waitrequest_o <=
m_waitrequest or not s*_active_grant`, line 139) but the request
forward-mux AND the readdatavalid routing are gated by a *different*
register, `last_grant` (lines 310-329). If they desync, a master's read
is accepted at the slave port yet never forwarded to memory (and/or its
beats are routed to the other master) — exactly "accepted, zero beats".
Not yet proven; v3 tap decides empirically.

### Debug tap v3 (dbg-ascal-wedge c615563): narrow + post-arbiter levels

Status word changes vs the table above:

| bits | v3 meaning |
|---|---|
| S[26] | post-arbiter readdatavalid (wrapper → arbiter) |
| S[27] | narrow dig readdatavalid (arbiter → avm_decrease) |
| S[29] | narrow dig read pending (avm_decrease → arbiter) |
| S[30] | narrow dig waitrequest |
| S[31] | post-arbiter read pending (arbiter → wrapper) |

Counters v3: C[31:28] rq, C[27:24] ak, C[23:20] dk (as before);
C[19:16] narrow dig read episodes; C[15:12] post-arbiter read episodes;
C[11:8] wide rdv beats; C[7:4] narrow dig rdv beats; C[3:0] post-arb
rdv beats.

Wedged-state decode:

| reading | eater |
|---|---|
| C[19:16] frozen | avm_decrease never issues narrow reads → decrease bug |
| C[19:16] counts, C[15:12] frozen | **arbiter accepts but never forwards** (active_grant/last_grant desync) |
| C[15:12] counts, C[3:0] frozen | wrapper (avm_increase/avm_to_wb/UberDDR3) eats the read |
| C[3:0] counts, C[7:4] frozen | arbiter misroutes the response beats |
| C[7:4] counts, C[11:8] frozen | avm_decrease wide-beat assembly stuck |
| S[29]=1 & S[30]=1 steady | narrow read stalled forever at the arbiter (grant never given) |

### v3 capture (user, 2026-07-11 night): EATER IS INSIDE THE DDR3 WRAPPER

The capture included the transition: ~2 s of `reset_na=0` during a
short press — that is the calib gate holding through UberDDR3's
calibration **plus its internal self-test** (built with
SKIP_INTERNAL_TEST=0), then the wedge. Counter deltas across the
transition: rq +2, ak +2 (preload issued), **ndr +2 (avm_decrease
issued both narrow reads), mar +2 (arbiter forwarded both to the
wrapper)**, prv/nrv/wrv +0 (**the wrapper returned zero beats**),
S31=0 (both accepted, none pending). Arbiter and avm_decrease
exonerated; the eater is inside `ddr3_wrapper_wukong`
(avm_increase → avm_to_wb → UberDDR3).

Code review of the wrapper components found one REAL hole:
**avm_increase in WRITING_ST asserts waitrequest=0 yet ignores a
presented READ completely** (avm_increase.vhd:59 vs the FSM's IDLE-only
read acceptance at :120) — any read that reaches it mid-write-burst is
silently dropped. What sequence puts a read there (all wrapper
components ARE ctrl_rst-reset on a press) is not yet derived —
candidates: a burst-boundary phase slip between the arbiter's and
increase's beat accounting created around reset, or an avm_to_wb /
UberDDR3 ack loss instead. avm_to_wb reviewed: read acceptance is
stall-independent by design, ack bookkeeping underflow-guarded — no
obvious zero-beat mode.

### Debug tap v4 (dbg-ascal-wedge 19aa7fe): inside the wrapper

S bits 16-23 repurposed: S16=wb_stb, S17=wb_ack, S18=wb_stall,
**S19=read-eaten-in-WRITING_ST (the smoking gun bit)**, S20=wide read
(increase→to_wb), S21=wide rdv (to_wb→increase), S23:22=increase FSM
(0=IDLE 1=WRITING 2=READING 3=RESPONSE). Bits 0-15 and 24-31 unchanged
from v3.

Counters v4: C[31:28] rq; C[27:24] post-arb read episodes; C[23:20]
wide read episodes; C[19:16] accepted wb stbs; C[15:12] wb acks;
C[11:8] wide rdv beats; C[7:4] wrapper rdv beats; **C[3:0] EATEN
reads**.

Wedged-state decode:

| reading | conclusion |
|---|---|
| C[3:0] +2 across the wedge | avm_increase WRITING_ST hole CONFIRMED — fix: stall reads during WRITING_ST + find the phase-slip origin |
| S23:22=1 (WRITING) steady while bus idle | increase stuck mid-burst = burst phase slip visible directly |
| C[23:20] +0 (no wide reads) with C[3:0]=0 | increase dropped them some other way |
| C[23:20] +2, C[19:16] +0 | avm_to_wb never issued stbs |
| stbs +, acks +0 | UberDDR3 swallowed accepted stbs |
| acks +, C[11:8] +0 | avm_to_wb dropped the response |

### v4 capture (user, 2026-07-11 night): CONVICTION — the WRITING_ST hole eats the preload reads

Counter deltas across the wedge transition: **eat +2** (C[3:0], the
smoking-gun counter), wide-read episodes +0 (the reads never became
wide reads), and post-transition S23:22=01 steady — **avm_increase is
camped in WRITING_ST with the bus completely idle**. Both ascal preload
reads were silently dropped by the WRITING_ST hole. So the wedge
mechanism is fully: a **phantom write burst** parks avm_increase in
WRITING_ST (it waits forever for write beats that never come), then the
two preload reads arrive, see waitrequest=0, and are eaten.

Timing of phantom creation: the v4 capture showed increase IDLE during
the ~2 s reset hold (UberDDR3 calibration + internal self-test,
SKIP_INTERNAL_TEST=0), so the phantom forms **in-band within the first
write bursts after reset release**, before the preload reads. Ruled out
for creation: avm_decrease's reset clause (outputs cleared), the core
port (tied to constants in democore), reset asymmetry (arbiter,
increase, decrease all sit on the same hr_rst/ctrl_rst net). The
creation mechanism — how increase's beat accounting slips against the
arbiter's — is still unknown; that is what v5 measures.

Secondary hole noted in review: the arbiter's read-load path
(avm_arbit.vhd:151-156) has no burstcount=0 guard, so an eaten read that
reloads its counter can park the grant on the dig master forever.

### Debug tap v5 (dbg-ascal-wedge 076caf8): phantom burst anatomy

Status word changes vs v4: **S[15:8] = avm_increase live s_burstcount**
(remaining narrow beats of the burst it thinks it's in — the phantom's
remaining count, quasi-static in the wedge so the 250 ms raw sample is
trustworthy). S[21] repurposed: narrow write beat accepted at the
wrapper (was wide rdv). Ascal wedge signature now only S[7:0]. S[16-20],
S[23:22], S[24-31] unchanged from v4/v3.

Counters v5: C[31:28] WRITING_ST entries (ent); C[27:24] WRITING_ST
exits (ext); C[23:20] post-arbiter read episodes (mar); C[19:16] narrow
write beats accepted (wrb); C[15:12] accepted wb stbs; C[11:8] wb acks;
C[7:4] wrapper rdv beats (prv); **C[3:0] eaten reads (eat)**.

Wedged-state decode:

| reading | conclusion |
|---|---|
| S[15:8] ≈ small (a few…~60) | normal-length burst with slipped beat accounting — increase under-counted accepted beats or arbiter over-delivered |
| S[15:8] ≈ 250+ | burstcount≈0 load — increase latched a burst-length it should never have seen (decrease/arbiter presented garbage burstcount around release) |
| ent − ext = 1 across the wedge | confirms camped-in-WRITING_ST (entered, never exited) |
| wrb delta since release vs expected burst total | how many beats the phantom actually received before starving |
| eat +2, S23:22=01 | v4 conviction reproduces (sanity) |

### v5 capture (user, 2026-07-12): ROOT CAUSE FOUND — stale `avl_write_i` through ascal reset

Capture (flat democore, good → press → wedge):

- Good: S alternates `50000000`/`50000100` — increase IDLE, s_burstcount
  resting at 0 (post-write) / 1 (post-read), eat=0.
- Reset hold (~2 s, 8 identical lines `40040900 BB476500`): increase
  IDLE, wb_stall=1 (calib+self-test), s_burstcount=9 = harmless leftover
  (not cleared by rst, reloads at next header). All counters frozen —
  whole chain in reset.
- Wedge: S=`5040388A` stable — increase WRITING_ST, **s_burstcount =
  0x38 = 56**, eat=2 frozen, mar frozen, prv=0, ent−ext ≡ 1.

**56 = 64 − 8: a 64-narrow-beat burst truncated after exactly ONE wide
word.** Not the burstcount-0 mode (~250).

**Mechanism (complete):** ascal's avl-side async reset clause
(ascal.vhd ~1645) forces `avl_state<=sIDLE` but the `avl_write_i<='0'`
line is **commented out** (upstream/temlib heritage). The synchronous
`avl_write_i<='0'` default cannot run while reset is asserted, so a
reset landing while the avl writer is active freezes `avl_write_i='1'`
(with stale address; burstcount port is constant 8) for the entire
reset hold. At release the race is decided: if the avm chain
(decrease/arbit/increase) wakes ≥1 cycle before ascal's avl-domain
reset sync releases, avm_decrease accepts the stale phantom header
(announces 8 wide = 64 narrow downstream; increase latches 64),
delivers the single held wide beat as one 8-narrow chunk, then ascal's
release clears the write → truncated at 56. If ascal wins the race →
clean wake. Biased coin per reset event ⇒ the ~alternation, VIC20's
different odds (clock-ratio-dependent race), and the R6 reproduction
(same stale write enters the HyperRAM avm chain).

**The 56 self-regenerates:** each later real avl burst (64 beats)
first drains the 56-beat debt (increase exits mid-burst at 0), and its
last 8 beats are re-latched as a fresh 64-beat header (decrease
re-announces 64 per chunk) → camped at 56 again. The 8-beat debt rolls
forward forever; the sampler catches WRITING/56 with high probability.
The o-side preload reads arrive during a camped window and are eaten
by the WRITING_ST hole (eat=2) → permanent deadlock.

**FIX (root cause, one line):** restore `avl_write_i<='0'` in the
reset clause. dbg-ascal-wedge commit e96f8a7 (fix build, taps kept for
verification). Upstream-report to sy2002/MJoergen (and temlib): applies
to every M2M board/core.

**Defense-in-depth (deferred, NOT built):** the previously planned
avm_increase "stall reads in WRITING_ST" would NOT self-heal — a
stalled read head-of-line blocks the arbiter→increase command channel,
so the drain writes queue behind it and the debt never clears
(polite wedge instead of silent wedge; still worth it as hygiene).
A full self-heal is abort-drain: on read-while-WRITING, increase
completes the announced wide burst itself with byteenable-0 dummy
beats (shell-fence pattern), then serves the read — clears the debt
permanently. Related same-class item stays open: R6/DFX decouple must
force waitrequest to the RM (stall-not-drop) instead of gating reads.

### Updated test ranking

1. **VGA during a wedged state (R6)** — unchanged, still the decisive
   split: VGA moving + HDMI striped ⇒ freeze in the ascal
   capture/framebuffer loop (fits the race theory); VGA also frozen ⇒
   core-side, theory wrong.
2. **NEW: unmodified upstream V2.0.1 democore on real MEGA65 hardware,
   repeated reset presses.** Reproduces ⇒ confirmed upstream bug, report
   to sy2002/MJoergen with the flat-Wukong + R6 evidence. (Cheap proxy:
   ask the tester whether official M2M-based release cores — e.g.
   C64MEGA65 — ever show the striped freeze after reset presses.)
3. A→A→A on R6 (now expected to show *mostly*-alternating, matching
   Wukong).
4. Short-press recovery on R6 + A-vs-B color check (G_INVERT_VIDEO
   marker) — unchanged.
