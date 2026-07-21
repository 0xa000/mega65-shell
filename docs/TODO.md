# Open items (migrated from m65-shell-poc docs/TODO.md, 2026-07-19)

The pre-repo history (v2/v3/v4 rebuild bundles, all executed) stays in the
m65-shell-poc copy; this list carries only what is still open.

## v5 bring-up (this repo)

- [x] Wukong v5 static built (WNS +0.392) + catalog relinked
      (democore seed + menu + Moon Patrol), pr_verify-interchangeable
      (2026-07-19).
- [x] R6 v5 static built (WNS +0.173) WITH the v4 SD/FAT32 loader wired
      (external micro-SD slot — user decision 2026-07-19); catalog
      (democore seed + menu + Moon Patrol R6 ports) relinked + verified.
- [x] Hardware shakedown, Wukong: v5 catalog works end to end
      (user-verified 2026-07-20).
- [ ] Hardware shakedown, R6 (tester): swap regression + first SD/menu
      test on the external slot; keyboard via mega65kbd path in the menu.

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

## Boundary v6 wishlist (next static rebuild — bundle, don't trickle)

From the R6 tidy-up review (2026-07-21). None of these justifies an ABI
break on its own; execute as one bundle when the next rebuild is forced.
Review conclusions that need NO action: the shell-side audio DAC driver
stays (park-at-silence keeps the AK4432 clocked across swaps; boundary
carries clean PCM; ~40 FFs), and nothing else currently in the shell
should move RM-side.

- [ ] SDRAM service: controller in the shell behind a second Avalon
      slave (`mem2_*`), per the standing decision in
      boards/BOUNDARY-R6.md (raw pins rejected — IOB-timing risk on
      every RM rebuild). Controller candidates listed there.
- [ ] Rename the `rsv` boundary pins to their actual function —
      descriptor hand-over to the desc_proxy register file (e.g.
      `rsv_i/rsv_o` -> `desc_i/desc_o`) — and add a fresh
      over-provisioned spare bus (`rsv2`) in both directions: the
      current 16+16 bits are fully consumed, so today any new service,
      however small, forces an ABI break.
- [ ] Raw pass-throughs for the remaining parked peripherals: Ethernet
      PHY (RMII), internal FDC, PMOD (+ enables/flags). Park gates
      only, negligible static cost; sweep them in wholesale.
- [ ] Consider an L-shaped RP: add clock region X1Y4 to the RM
      (~9-10k LUTs, ~20 RAMB36, ~40 DSPs — exact numbers to be queried
      in Vivado; both rectangles clock-region aligned, so
      RESET_AFTER_RECONFIG holds). Weigh against the SDRAM
      controller's own placement needs in row Y4 before committing.
- [ ] Ethernet park polish: hold the PHY in reset while unsupported
      (today `eth_reset_o <= '1'` with no RMII clock, verbatim from
      upstream).
- [ ] Optional: expose joystick_5v_disable/powergood as boundary bits.
- [ ] Optional (pairs with loader phase 4): minimal shell-side keyboard
      LED driver so load progress/verdict is visible on a closed case
      (mainboard LEDs are inside the case; keyboard LEDs are RM-driven
      and unreachable while the RP is dark).

## RM-side (framework/core repos, no static rebuild)

- [x] M2M fork rm_top/rm_top_r6 v5 renames (branches dfx-v5 / dfx-v5-r6)
      + R6 qnice-rm.xdc; picorv32-menu + Moon Patrol renamed and ported
      to R6 (2026-07-19).
- [ ] VIC20 + C64 rm_tops: v5 rename + relink (deferred; also still
      missing the drp_done gate that democore/R6/Moon Patrol have).
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
