# m2m-wukong overlay — boundary v5

RM-side DFX framework for M2M-based cores on the **QMTECH Wukong** board.

## Pinned base

| | |
|---|---|
| Applies on top of | `0xa000/MiSTer2MEGA65-wukong`, branch **`wukong`** @ `c3b0b41` |
| Extracted from | branch `dfx-v5` @ `60e6ed1` |
| Boundary | v5 (`docs/BOUNDARY.md`); static: SDK release `wukong-v5` |
| Patches | none — the `wukong` branch already carries the ascal reset fix and both `avm_increase` fixes |

The Wukong board support itself (pins, UberDDR3, keyboard, flat build) is
the `wukong` branch's job; this overlay only adds the RM framework on top.

## Files

| Path (in the core checkout) | Role |
|---|---|
| `M2M/vhdl/wukong/dfx/framework_rm.vhd` | fork of `framework_wukong.vhd` with everything the shell owns removed |
| `M2M/vhdl/wukong/dfx/av_pipeline_rm.vhd`, `digital_pipeline_rm.vhd` | forks of their originals (shell owns HDMI encode + clocks) |
| `M2M/vhdl/wukong/dfx/rm_top.vhd` | the RM top — implements the boundary-v5 port list |
| `M2M/vhdl/wukong/dfx/clk_drp_master.vhd` | RM-side DRP clock programming helper |
| `CORE/vhdl/dfx/mega65_rm.vhd` | shadows `CORE/vhdl/mega65.vhd` (same entity `MEGA65_Core`) |
| `CORE/vhdl/dfx/democore_clk_pkg.vhd` | democore's clock preset table — **template: replace with your core's** |
| `CORE/wukong-dfx-build.tcl` | RM-only build: `rm_elab` / `rm_synth` (democore) |
| `M2M/wukong-dfx-child.xdc` | pass as `RM_XDC` at child link (re-applies RM-internal timing dropped when the static was black-boxed) |
| `M2M/qnice-rm.xdc` | pass as `RM_XDC` for QNICE-bearing RMs (sdcard_clk, EAE multicycle) |

## Flow

```
./install-overlay.sh wukong /path/to/checkout
cd /path/to/checkout/CORE && (cd m2m-rom && ./make_rom.sh)
vivado -mode batch -source wukong-dfx-build.tcl -tclargs rm_elab
vivado -mode batch -source wukong-dfx-build.tcl -tclargs rm_synth
# in mega65-shell, against the wukong-v5 release assets:
make BOARD=wukong child RM_DCP=.../rm_democore_synth.dcp NAME=democore \
     RM_XDC=".../M2M/wukong-dfx-child.xdc .../M2M/qnice-rm.xdc"
```

Load the resulting `*_partial.bin` (never `.bit`) via the shell's menu/SD
or UART loader.
