# RM overlays — the RM-side framework as a drop-in

An **overlay** is the RM-side DFX framework packaged so that a developer
with an existing MiSTer2MEGA65-based core does not need to fork or rebase
anything: run `install-overlay.sh`, and the checkout can build the core as
a reconfigurable module against the released shell (see `SDK-RELEASE.md`
in `docs/` for the release assets, and `RM-CONVERSION-GUIDE.md` for the
full conversion manual).

Each overlay is **pure additions** plus, where the base does not already
carry them, small bug-fix patches. Nothing in an overlay modifies how the
flat (non-DFX) build of the core works.

| Overlay | Applies on top of | Patches |
|---|---|---|
| `m2m-wukong/` | the M2M fork's `wukong` branch (board port; already carries the ascal + `avm_increase` fixes) | none |
| `m2m-r6/` | **stock upstream** [MiSTer2MEGA65](https://github.com/sy2002/MiSTer2MEGA65) | `ascal-avl-reset-clear.patch` |

Exact pinned base revisions: each overlay's `OVERLAY-INFO.md`.

## Install and build

```
./install-overlay.sh r6 /path/to/your-core        # or: wukong
cd /path/to/your-core/CORE
vivado -mode batch -source r6-dfx-build.tcl -tclargs rm_elab    # sanity check
vivado -mode batch -source r6-dfx-build.tcl -tclargs rm_synth   # -> build-r6-dfx/rm_democore_synth.dcp
```

Then link the RM against the released locked static in this repo:

```
make BOARD=r6 child RM_DCP=.../rm_democore_synth.dcp NAME=democore \
     RM_XDC=".../M2M/r6-dfx-child.xdc .../M2M/qnice-rm.xdc"
make BOARD=r6 verify ...
```

The shipped build tcl targets the **M2M democore** — it is the smoke test
that the overlay and your toolchain work end to end, and the template to
adapt for your own core (swap the `CORE/vhdl` sources, set your core clock
in `democore_clk_pkg.vhd`'s successor — see RM-CONVERSION-GUIDE.md §5).
If your core needs a clock the shell isn't parked at, generate the DRP
table and child-timing XDC with `tools/mmcm_drp_table.py` (in this repo).

## Version pinning — read this before updating the base

The `*_rm` files are reviewable forks of their M2M framework counterparts
and instantiate M2M entities by name (`qnice_wrapper`, `avm_arbit_general`,
`avm_fifo`, …). An overlay is therefore **pinned to the base revision named
in its OVERLAY-INFO.md**; a newer framework may work, but any change to
those entities' ports or file layout will surface at `rm_elab`. Run
`rm_elab` after any base update before debugging anything else.

The overlays are distribution copies; they are developed on the M2M fork
branches (`dfx-v5` Wukong / `dfx-v5-r6` R6) and re-extracted here per
boundary version. The two `avm_increase` fixes referenced above are
static-side (`rtl/common/avm_increase.vhd`) and pending as an upstream PR;
they are listed only because the Wukong *flat* build also compiles that
file from its own tree.
