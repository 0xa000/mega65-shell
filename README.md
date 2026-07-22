# mega65-shell

A minimal **static shell** for MEGA65-style FPGA computers using Xilinx
7-series partial reconfiguration (DFX). The shell owns board I/O, clocks,
memory controllers and an ICAP loader; **cores are reconfigurable modules**
(RMs) streamed in over UART or loaded directly from a FAT32 SD card — the
shell is `exec()` for FPGA cores. No soft CPU is required in the shell: a
menu/chooser is itself just another core.

Supported boards:

| Board | Device | Core RAM service | Status |
|---|---|---|---|
| QMTECH Wukong | XC7A100T-2 | DDR3 (UberDDR3) behind Avalon-MM | hardware-verified (boundary v4 lineage) |
| MEGA65 R6 | XC7A200T-2 | HyperRAM behind Avalon-MM | hardware-verified swap path (community testers) |

This repository collects what previously lived across `m65-shell-poc` and
DFX branches of a MiSTer2MEGA65 fork: board-agnostic shell RTL
(`rtl/common/`), per-board shell tops and constraints (`boards/`), the
parameterized Vivado DFX build flow (`flow/`), host tools (`tools/`),
simulation testbenches (`sim/`) and the boundary documentation (`docs/`).

## Layout

```
rtl/common/       board-agnostic shell blocks (loader stack, clock service, fences)
boards/<board>/   shell_top, constraints, pblock, memory controller
flow/             Vivado non-project DFX flow (parameterized per board)
tools/            partial senders, FAT32 helpers, tester + SDK release packaging
sim/              GHDL testbenches
docs/             design rationale, boundary service contract, per-board annexes
releases/         released static ABIs (static_locked.dcp + boundary spec), not in git
```

## The SDK model

Each board has, at any time, **one released locked static implementation**
(`static_locked.dcp`) — that checkpoint *is* the ABI. Core projects take
the RM-side framework as a drop-in overlay (`sdk/`, `install-overlay.sh`)
but **link against the released static**, never
rebuild it. Rebuilding the static (any change to `rtl/common`, a board's
shell or constraints) starts a new boundary version and invalidates all
existing partials — that is inherent to DFX.

Building the static requires a *seed RM* netlist for the first
configuration; the flow takes it as an input artifact (`SEED_RM_DCP`), so
no core code lives in this repository.

## Getting the SDK / building a core

Core developers consume the shell as a **tagged GitHub release** (the
locked static, the `pr_verify` reference and install images) and never
rebuild it. Start here:

- `docs/SDK-RELEASE.md` — what to download, the **exact-Vivado-version
  requirement** (currently 2023.2; the free ML Standard edition suffices),
  and the hardware tiers (TE0790 vs SD-card-only development).
- `docs/RM-CONVERSION-GUIDE.md` — the step-by-step manual for turning an
  existing core into a loadable partial.
- `docs/BOUNDARY.md` — the boundary service contract (ABI) and its
  version lineage.

## Licensing

Original code here is **LGPL-3.0-or-later** (chosen for compatibility with
mega65-core). Imported components keep their upstream licenses (GPLv3 for
UberDDR3 and MiSTer2MEGA65-derived parts, MIT for the HyperRAM controller,
LGPL for Tyto Project files) — so combined works (bitstreams) are
effectively **GPL-3.0**. See `ATTRIBUTION.md` for the full provenance
table.
