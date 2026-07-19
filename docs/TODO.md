# Open items (migrated from m65-shell-poc docs/TODO.md, 2026-07-19)

The pre-repo history (v2/v3/v4 rebuild bundles, all executed) stays in the
m65-shell-poc copy; this list carries only what is still open.

## v5 bring-up (this repo)

- [ ] Wukong v5 static: `make BOARD=wukong synth link` with the M2M fork's
      democore as seed RM (needs the fork's rm_top renamed to the v5 port
      names first — see "RM-side" below), then relink the catalog
      (democore + menu + Moon Patrol) and `make verify`.
- [ ] Hardware shakedown of the two v5 backports on Wukong: LED verdict
      readings on good/bad streams, loader at 50 MHz (UART M65D raw+chain
      regression, menu-driven SD swap).
- [ ] R6 static from this repo (round-5 parity first, then the v4 loader
      port below).

## R6 feature parity (v4 loader port)

- [ ] Wire the SD/FAT32 load path (uart_tx, sd_sector, fat32_walker,
      load_ctrl, desc_proxy) into shell_top_r6 — blocks already in
      rtl/common and listed as unwired in boards/r6/board.tcl.
- [ ] DECIDE: which SD slot the walker owns on the R6 (external micro-SD
      at the back vs internal full-size under the cover), and the park/mux
      policy for the other slot.
- [ ] Menu RM port to the R6 (picorv32-menu; needs the descriptor block +
      rsv serializer against the R6 boundary).

## R6 open issues (from tester rounds)

- [ ] Cold-boot race: initial full push comes up black, recovered by a
      short press (Wukong's equivalent was fixed by memory-ready stalling;
      R6 still shows it — separate cause, likely keyboard/DRP related).
- [ ] A-vs-B G_INVERT_VIDEO marker confirmation (round-3 ask).
- [ ] Wedged-after-swap: does a short press recover? VGA alive during
      wedge? (Localizes RM-side ascal deadlock vs shell-side burst debt.)

## Robustness (loader phase 4)

- [ ] Core-file header (instead of raw .bin partials on the card).
- [ ] Golden descriptor 0 from QSPI + rm_alive watchdog: shell falls back
      to the menu core if the loaded RM never comes alive.

## RM-side (framework/core repos, no static rebuild)

- [ ] M2M fork: rename rm_top/rm_top_r6 ports to the v5 names
      (docs/BOUNDARY.md rename map) and create the R6 framework XDC
      (sdcard_clk + EAE multicycles, read -unmanaged at link — the
      constraints were dropped from this repo's r6 static/child XDCs per
      the ownership rule).
- [ ] drp_done gate into VIC20 + C64 rm_tops (democore + R6 have it).
- [ ] VIC20 rebased-RM fit: `synth_design -max_bram` reclaim of 1 tile.
- [ ] Cosmetic: RM blanks video while clkstat[2]=0 (short-press stall
      window visibly frozen otherwise).

## Upstream reporting

- [ ] ascal `avl_write_i` reset bug to sy2002/MJoergen (+ temlib
      heritage); stock-severity check first (unmodified core on real
      MEGA65, repeated resets). Evidence in ISSUE-COLDBOOT-DRP.md +
      UPSTREAM-ISSUE-ascal-reset.md.
- [ ] avm_increase RESPONSE_ST stale-word fix PR (pending since
      2026-07-05; the fixed copy is rtl/common/avm_increase.vhd).
- [ ] mega65-tools `fpgajtag-fixes` branch (HS2 ACBUS cable fix + the
      raw-STAT-readout ICAP fix): user pushes/PRs.
