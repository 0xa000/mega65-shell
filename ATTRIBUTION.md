# Licensing, attribution and provenance

## Licensing scheme

- **Original code in this repository** (the ICAP loader, UART RX/TX, the
  SD/FAT32 load path `sd_sector` / `fat32_walker` / `load_ctrl` /
  `desc_proxy`, the core-clock service `shell_core_clk` / `drp_proxy`, the
  board shell tops' original portions, the DFX build flow, tools, testbenches
  and documentation) is licensed **LGPL-3.0-or-later** (`LICENSE.LGPL-3.0`,
  which supplements `LICENSE`). This is deliberate: the MEGA65 project's
  `mega65-core` is LGPLv3, and the parts we control should be liftable into
  it without a license change.
- **Imported components keep their upstream licenses** (see table below).
  Because some of them are GPLv3, a *combined work* (a bitstream, or a source
  release including those directories) that contains them is effectively
  distributed under **GPL-3.0**. This mirrors the scheme already used by the
  mega65-core Wukong fork (LGPL core + GPLv3 UberDDR3 ⇒ GPLv3 combined).
- Per-file SPDX headers state each file's license; this document records
  origin and modifications.

Practical consequence per board today: **Wukong** builds always include
UberDDR3 (GPLv3) ⇒ combined GPLv3. **R6** builds include M2M framework
helpers (GPLv3) ⇒ combined GPLv3. The LGPL/MIT parts remain individually
reusable under their own terms.

## Imported components

| Component (paths) | Origin | License | Notes |
|---|---|---|---|
| `rtl/common/` framework helpers: `cdc_stable.vhd`, `debounce.vhd`, `reset_manager.vhd`, `types_pkg.vhd`, `axi_fifo_small.vhd`, `avm_increase.vhd`, `shell_clk_base.vhd` (from `clk_m2m.vhd`) | [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) framework, by sy2002 and MJoergen | GPL-3.0 | `avm_increase.vhd` carries two local fixes (RESPONSE_ST stale-word, abort-drain fencing). `shell_clk_base.vhd` is `clk_m2m.vhd` with shell-neutral clock names. |
| `rtl/common/video_out_clock.vhd`, `rtl/common/serialiser_10to1_selectio.vhd` | The Tyto Project, (C) Adam Barnes, as distributed (with modifications by MJoergen) in MiSTer2MEGA65 | LGPL-3.0-or-later | Dynamically reconfigured pixel-clock MMCM and 10:1 OSERDES serialiser. |
| `boards/r6/hyperram/` | [HyperRAM controller](https://github.com/MJoergen/HyperRAM) by Michael Jørgensen | MIT (upstream); imported from the MiSTer2MEGA65 distribution — M2M-specific modifications, if any, are GPL-3.0 | Unmodified relative to the M2M tree. |
| `boards/r6/rtl/audio.vhd` | MiSTer2MEGA65 (`controllers/M65/audio.vhd`) | GPL-3.0 | AK4432 DAC driver, shell-side on MEGA65 R6. |
| `boards/wukong/uberddr3/` | [UberDDR3](https://github.com/AngeloJacobo/UberDDR3) by Angelo C. Jacobo | GPL-3.0-or-later | `ddr3_top_wukong.v` is a board-specific top derived from the UberDDR3 example top. |
| `boards/*/rtl/shell_top*.vhd` (pin handling, peripheral-driver portions) | Portions derived from MiSTer2MEGA65 `framework.vhd` / board tops | GPL-3.0 (those portions) | The shell tops re-implement the board I/O layer outside the reconfigurable partition; files marked GPL-3.0 accordingly. |

The SD-card init sequence in `sd_sector.vhdl` encodes lessons from this
project's PicoRV32 menu firmware bring-up (NCS lead-in clocking,
skew-tolerant R1 parsing); the code itself is original.

## Relationship to MiSTer2MEGA65 and mega65-core

The shell is deliberately framework-neutral: it owns board I/O, clocks,
memory controllers and the ICAP loader, and treats any core — M2M-based,
mega65-core-based or bare-metal — as a reconfigurable module behind the
documented boundary (see `docs/`). M2M-based cores keep using the M2M
framework *inside* their reconfigurable module; the RM-side DFX framework
lives in the respective core/framework repositories, not here.
