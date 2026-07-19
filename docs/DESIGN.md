# Design notes: a partial-reconfiguration shell for MEGA65 core switching

Distilled from the feasibility discussion that started this project
(July 2026). These are working conclusions, not sacred law — but each was
reasoned through, so revisit deliberately.

## Problem and approach

MEGA65 stores cores as full bitstreams in QSPI flash; slots are running
out. Instead of flashing cores, use Xilinx DFX (partial reconfiguration):
a small **static shell** stays resident and streams core bitstreams from
SD card into ICAPE2; everything else — including the boot menu — lives in
one large **reconfigurable partition (RP)**.

Key 7-series facts that shape everything:

- Every reconfigurable module (RM) is implemented against the *locked,
  routed* static checkpoint. Static routing may pass through the RP, so
  RMs are welded to one exact static implementation. Any static change
  invalidates all built cores.
- IOBs, BUFGs, MMCMs/PLLs and config primitives (ICAP, BSCAN, STARTUP)
  cannot be inside an RP. The shell owns all pins and clock primitives,
  permanently.
- Static-region BRAM is untouched by partial reconfig — a small FIFO
  suffices for SD→ICAP streaming; no external RAM buffering needed.
- Full self-reconfig via the FPGA's own JTAG is impossible (JPROGRAM
  clears the fabric driving TCK). ICAP+IPROG (full, jumps to flash) and
  ICAP+partials (static survives) are the two working mechanisms.

## Architecture decisions

1. **The menu is just the first RM.** Static = SD reader + ICAP FSM +
   control registers + IOBs/clocks (+ optionally bare video sync so the
   display doesn't drop during the 1–3 s load). Everything smart is an RM.
2. **The shell is `exec()`.** Any core can request a core switch via a
   descriptor: source (SD0/SD1/QSPI), mode (raw LBA / FAT32 chain),
   start (LBA or cluster), byte length. "Start cluster + size" is exactly
   what a FAT directory entry holds, so the requesting core (e.g. QNICE
   menu in M2M) does one dirent lookup and passes it through.
3. **Hardware FAT32 chain follower with self-mount.** Costs a few hundred
   LUTs + a 512 B FAT-sector cache; removes the contiguous-file
   requirement. The shell re-parses MBR+VBR itself at every load (two
   sector reads — never stale), with a CSR mount-record **override** as
   the software escape hatch for weird cards. Guards: cluster bounds
   check, stop after ceil(size/512) sectors (loop-proof), FAT32 only,
   read-only, FAT copy #0.
4. **Robustness: golden descriptor + watchdog.** Descriptor 0 = menu RM
   from a fixed QSPI address, triggered by long reset-press and by a
   watchdog when a fresh RM fails to set its alive bit. Core files carry
   a header (magic, ABI version, board/device ID, length, checksum);
   software validates fully, shell re-checks magic.
5. **Multiple shells coexist in QSPI slots** (e.g. native vs. M2M),
   switched by today's WBSTAR+IPROG full-reconfig path; PR switches cores
   *within* a shell. Cross-reconfig state ("after reboot, load core X")
   goes through the MAX10 system controller as mailbox (survives FPGA
   reconfig; RTC NVRAM as fallback). This federates the ABI problem:
   shell v2 ships in another slot, old partials keep working; legacy
   monolithic cores remain valid slot citizens indefinitely.
6. **Boundary ABI in tiers** (sketched against mega65r6.vhdl's `container`,
   which is already a proto-shell):
   - Tier 0 raw in/out/oe triples: keyboard, joysticks, IEC, cartridge
     port, floppy, PMODs, I2C buses, RMII ethernet.
   - Tier 1 thin PHY seams: HDMI = 3×10-bit TMDS words at pixel clock;
     the shell keeps only the pixel-clock MMCM (DRP presets) and the
     OSERDES — encoder, InfoFrames and audio data islands are RM-side
     (re-revised 2026-07-07: the earlier RGB seam served only the
     keep-sync fallback, since dropped; see "Boundary revised" below).
     Audio rides in the TMDS stream on HDMI targets; VGA = RGB+syncs.
   - Tier 2 shell-owned controllers: SDRAM/HyperRAM behind a registered
     burst port (boundary timing forces this); clocking = shell-private
     MMCM + 2 core-facing MMCMs, DRP-programmable, with a pre-wired
     optional cascade mux (topology is frozen; provision the superset).
   - Tier 3 time-shared: SD and QSPI pins muxed — shell seizes them only
     while the RP is dark, cores keep their own controllers otherwise.
   - Control plane: small CSR bus — ABI version, board ID, exec
     descriptor + GO, MAX10 link, DRP windows, watchdog kick, plus
     ~256 reserved wires each way and spare clock lines (partition pin
     count is frozen with the shell — over-provision day one).
7. **Timing rule: nothing fast crosses the boundary.** Register both
   sides of every partition pin; boundary buses ≤ ~160 MHz single-clock
   synchronous; DDR/serializer/PHY logic entirely on one side.

## Boundary confirmed: thin shell (2026-07-06)

The M2M-on-Wukong flat port (framework + UberDDR3 verified on hardware;
C64MEGA65 building) was the "M2M internals recon" this document asked
for, and it settled the one boundary question that had drifted: whether
the M2M framework (QNICE, ascal, OSM, vdrives, av-pipeline) belongs in
the shell or in the RM. **It is RM-side code** — a library each RM links
in at build time, not a shell service. The tier model above stands;
what follows is why, and what it sharpened.

- **Churn lives in the RM.** Any static change invalidates every built
  core. The framework and QNICE firmware are the churniest code in the
  stack; the RAM controller, SERDES and clock primitives are the most
  stable. With the framework RM-side, a framework or firmware update
  rebuilds only the RMs that want it — the shell stays locked, the core
  catalog stays valid, and different RMs may carry different framework
  versions concurrently.
- **The RAM seam collapses to one port.** M2M's internal arbiter
  (core + ascal + QNICE) stays in the RM, so the shell exposes a single
  Avalon-MM slave in front of the memory controller. Backend
  interchangeability is now hardware-proven: the same latency-insensitive
  port runs HyperRAM on MEGA65 and UberDDR3 on Wukong with the RM none
  the wiser. Shell-side RAM also survives the swap (the controller keeps
  refreshing while the RP is dark), so an outgoing RM can leave data for
  its successor.
- **No M2M policy crosses the boundary.** Menus, config blocks, vdrives
  protocols — all RM-internal. Non-M2M cores get raw pins, one Avalon
  port and an RGB video output, with no framework tax.
- **Keep-sync fallback — dropped (2026-07-07, see "Boundary revised"
  below).** The v0 stripes fallback was built and hardware-verified,
  then killed for a policy reason: saved per-core video modes make the
  incoming RM's mode unknowable at swap time, and SD-speed loads
  complete inside the monitor's own resync window anyway. Sync loss is
  accepted, the shell generates no video, and LEDs are the load /
  proof-of-life indicator on all targets (which was already the
  analog/VGA plan). Menu-RM analog output still needs nothing special:
  RMs carry the full framework incl. analog_pipeline, so VGA is just a
  second tier-1 RGB seam (~30 wires; size the reserved partition pins
  with it in mind).
- **Shell services this implies** (all within the existing tiers): the
  pixel-clock MMCM presets must be RM-requestable, since mode policy
  (QNICE) now sits in the RM — M2M's `video_out_clock` is the
  in-framework template (revised 2026-07-07: a 3-bit preset request is
  the whole interface; InfoFrame/mode metadata no longer crosses — it
  moved into the RM with the encoder, see BOUNDARY-V1.md); SD ownership
  is the Tier 3 mux, stated plainly: the RM owns SD except while the RP
  is dark.
- **Accepted costs.** Each RM re-implements the ~20k-LUT framework
  (per-RM build ≈ today's flat build, including re-closing ascal/QNICE
  timing against the locked shell); partials span most of the device
  (bigger files — seconds at SD speed). The A100T squeeze is real:
  C64MEGA65 only fits Wukong with its CRT cache shrunk and kernal
  variants pruned, and the shell's own footprint comes out of the same
  budget. 200T remains comfortable.

## Boundary revised: TMDS seam, sync loss accepted (2026-07-07)

The democore swap hardware test closed the loop on keep-sync and
killed it for a policy reason, not a technical one: M2M cores save
user settings including HDMI mode, restored by QNICE *after* boot, so
the incoming RM's mode is unknowable at swap time and even a kept-sync
swap re-syncs seconds later when the saved mode lands. Meanwhile
SD-speed loads (~3 MB partial, stage A2) complete inside the monitor's
own 1–2 s resync window — a swap reads as a mode change. Decisions
(BOUNDARY-V1.md has the signal-level spec):

- Sync loss on swap and on mode change is accepted. The shell
  generates no video; the stripes/progress-bar/mux machinery is
  deleted, not improved. LEDs indicate loading.
- The video seam drops to the DFX floor: 3×10-bit TMDS words at pixel
  clock (OSERDES/IOB/MMCM must be static; nothing else video stays).
  Encoder, InfoFrames and audio data islands move into the RM; the
  PCM audio boundary disappears (embedded in TMDS). Video+audio
  boundary width: 59 → 33 wires.
- Mode switching becomes RM-internal except the pixel clock: a 3-bit
  quasi-static preset request (`vclk_sel`) into video_out_clock's
  existing DRP FSM — shell side is a CDC + stability filter +
  decouple freeze; the existing hdmi_rst is the "relocking" feedback.
  No mode metadata ever crosses.
- The core-clock service (stage 3) stays separate and will be a DRP
  write proxy, not presets — per-core frequencies are arbitrary.
- Cost for non-M2M cores: every RM carries a TMDS encoder.
  vga_to_hdmi ships in the RM-support library next to the framework;
  any core needs video generation anyway.

Timing impact: neutral-to-easier. The 371.25 MHz x5 domain stays
entirely shell-internal; the 30 seam nets have a 13.5 ns budget over
a distance the RGB seam already covered; vga_to_hdmi gains pblock
placement freedom; one shell CDC (audio ACR) disappears; fewer
partition pins means less closure variance between RMs.

## M2M implications

M2M's board layer becomes the RM-side adapter; core authors mostly
untouched *except* each port's hand-instantiated clock file (core-specific
MMCMs, sometimes cascaded) must become DRP presets — mechanical, and
automatable from the MMCM generics. Cores that mux clocks at runtime
(turbo via BUFG switching) need shell BUFGMUX service or clock-enable
rework. Debug needs a shell-provided bridge (debug hub is static-only).

## Rough effort (PoC for M2M)

Stage A: DFX walking skeleton, ~2–3 wk. Stage B: real boundary v0 +
clocking/DRP + SD/FAT loader + control plane, ~3–6 wk. Stage C: M2M
board-layer adaptation + one core, ~4–8 wk (biggest unknown; do a
half-day recon of M2M internals before freezing the boundary). 100T
capacity is a real constraint for big cores + shell; 200T is comfortable.

## Alternatives considered

- **Flash staging** (copy core from SD into a QSPI staging slot, IPROG to
  it): ~1 % of the disruption, solves the capacity problem, tens of
  seconds per switch. The pragmatic near-term answer; PR is the long-term
  architecture. They don't conflict.
- **External JTAG configurator** (MCU cartridge): sound and
  ecosystem-neutral, but MEGA65 JTAG is on an internal header.
- **Self-JTAG**: dies at JPROGRAM, always. Fun to contemplate once.
