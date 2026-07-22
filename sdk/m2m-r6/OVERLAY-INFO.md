# m2m-r6 overlay — boundary v5

RM-side DFX framework for M2M-based cores on the **MEGA65 R6**. Applies to
**stock upstream MiSTer2MEGA65** — no fork needed.

## Pinned base

| | |
|---|---|
| Applies on top of | [sy2002/MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) `master` @ `c697e96` (2026-07) |
| Extracted from | `0xa000/MiSTer2MEGA65-wukong`, branch `dfx-v5-r6` @ `5211cd8` |
| Boundary | v5 (`docs/BOUNDARY.md`); static: SDK release `r6-v5` |
| Patches | `ascal-avl-reset-clear.patch` (below) |

## The one patch

`patches/ascal-avl-reset-clear.patch` re-enables a commented-out reset
clear in `M2M/vhdl/av_pipeline/ascal.vhd` (`avl_write_i <= '0'`). Without
it, a reset landing mid-burst leaves a phantom write presented to the
memory chain for the whole reset hold — the cold-boot black screen /
striped freeze wedge. This is a general upstream bug (report:
`docs/UPSTREAM-ISSUE-ascal-reset.md`); the patch disappears from this
overlay once upstream takes the fix.

## Files

| Path (in the core checkout) | Role |
|---|---|
| `M2M/vhdl/dfx/rm/framework_rm.vhd` | fork of `framework.vhd` with everything the shell owns removed |
| `M2M/vhdl/dfx/rm/av_pipeline_rm.vhd`, `digital_pipeline_rm.vhd` | forks of their originals (shell owns HDMI encode + clocks) |
| `M2M/vhdl/dfx/rm/rm_top_r6.vhd` | the RM top — implements the boundary-v5 port list |
| `M2M/vhdl/dfx/clk_drp_master.vhd` | RM-side DRP clock programming helper |
| `CORE/vhdl/dfx/mega65_rm.vhd` | shadows `CORE/vhdl/mega65.vhd` (same entity `MEGA65_Core`) |
| `CORE/vhdl/dfx/democore_clk_pkg.vhd` | democore's clock preset table — **template: replace with your core's** |
| `CORE/r6-dfx-build.tcl` | RM-only build: `rm_elab` / `rm_synth` (democore) |
| `M2M/r6-dfx-child.xdc` | pass as `RM_XDC` at child link (re-applies RM-internal timing dropped when the static was black-boxed) |
| `M2M/qnice-rm.xdc` | pass as `RM_XDC` for QNICE-bearing RMs (sdcard_clk, EAE multicycle) |

## Flow

```
./install-overlay.sh r6 /path/to/checkout
cd /path/to/checkout/CORE && (cd m2m-rom && ./make_rom.sh)
vivado -mode batch -source r6-dfx-build.tcl -tclargs rm_elab
vivado -mode batch -source r6-dfx-build.tcl -tclargs rm_synth
# in mega65-shell, against the r6-v5 release assets:
make BOARD=r6 child RM_DCP=.../rm_democore_synth.dcp NAME=democore \
     RM_XDC=".../M2M/r6-dfx-child.xdc .../M2M/qnice-rm.xdc"
```

Load the resulting `*_partial.bin` (never `.bit`) via the shell's menu/SD
(external micro-SD slot) or UART loader (`tools/send_partial.py`).
