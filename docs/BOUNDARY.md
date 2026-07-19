# The shell boundary — service contract (v5)

This is the umbrella spec for the static-shell / reconfigurable-module (RM)
boundary as shipped from this repository. **The authoritative port list is
the `rm_top` component declaration in each board's shell top**
(`boards/wukong/rtl/shell_top.vhd`, `boards/r6/rtl/shell_top_r6.vhd`); the
RM framework's `rm_top` entity must match it exactly. Full protocol detail
for each service lives in the versioned annexes under `boards/`
(V0..V3 + R6, kept verbatim from their hardware-verified state); this file
records what v5 changes and where to look.

## Version lineage

| Version | Board | Delta | Spec |
|---|---|---|---|
| v1 | Wukong | HDMI park/serialisers, UART→ICAP loader, decouple/fence | `boards/BOUNDARY-V1.md` |
| v2 | Wukong | dual-MMCM core-clock service (clkctl/clkstat, DRP proxy) | `boards/BOUNDARY-V2.md` |
| v3 | Wukong+R6 | memory-ready stalling, QSPI pass-through, core_clk2 | `boards/BOUNDARY-V3.md` |
| v4 | Wukong | FAT32 SD loader in the shell, descriptor service over `rsv` | `boards/BOUNDARY-V3.md` §v4 addendum + `docs/DESIGN.md` |
| R6 | MEGA65 R6 | v3-equivalent port of the shell to the R6 board | `boards/BOUNDARY-R6.md` |
| **v5** | both | rename to shell-neutral names; loader block on 50 MHz domain; ICAP LED verdict | this file |

Any static rebuild starts a new boundary version and invalidates every
existing partial — that is inherent to DFX, not a policy choice. One
released `static_locked.dcp` per board *is* the ABI ("SDK model", see
README.md).

## v5 changes

**1. Shell-neutral names (ABI-visible).** The shell is not tied to the
MiSTer2MEGA65 framework; M2M-flavoured names are gone from the boundary:

| pre-v5 | v5 | meaning |
|---|---|---|
| `qnice_clk_i` / `qnice_rst_i` | `loader_clk_i` / `loader_rst_i` | 50 MHz MMCM-conditioned service clock (the shell's loader domain; M2M RMs clock QNICE from it) |
| `hr_clk_i` / `hr_rst_i` | `mem_clk_i` / `mem_rst_i` | memory-service clock (Wukong: DDR3 UI clock; R6: HyperRAM clock) |
| `reset_m2m_n_i` | `reset_shell_n_i` | long-press whole-system reset |

XDC clock names follow (`loader_clk`, `mem_clk`, `mem_clk_del`,
`mem_delay_refclk`). Semantics are unchanged from v4; an RM ports to v5 by
renaming its `rm_top` ports and any `get_clocks` references.

**2. Loader block on the 50 MHz domain (static-side only).** The whole
loader stack (UART RX/TX, SD sector engine, FAT32 walker, load_ctrl,
desc_proxy, ICAP streamer) runs on `loader_clk`. Backported from the R6
shell (round 5): ICAPE2 clocked at 100 MHz sat exactly at its spec limit
and rejected every partial there. 50 MHz / 2 MBd = 25 clks/bit, zero UART
sampling error. `decouple`/`rm_reset` originate in the loader domain and
are CDC'd into the other boundary domains.

**3. ICAP LED verdict (static-side only).** The ICAPE2 O-port status
(DALIGN / CFGERR_B / IN_ABORT_B, UG470) is latched sticky per load
attempt. After any attempt the progress LED shows, until the next load or
a long-press reset: **solid** = config engine never saw the sync word,
**slow blink (~0.75 Hz)** = synced but CFGERR/abort, **fast blink
(~6 Hz)** = stream accepted. Wukong: led1; R6: the red mainboard LED.

## Services (pointers)

- **exec() / load descriptors** — the RM writes {source, raw-LBA or FAT32
  chain, start, length} through the `rsv` register file (desc_proxy) and
  the shell self-mounts the card and streams the partial into ICAP;
  rationale and descriptor format in `DESIGN.md` (decisions 2–4). Host
  test path: 14-byte `"M65D"` UART frames (`tools/send_descriptor.py`).
- **Core clocks** — two DRP-programmable MMCMs behind `clkctl`/`clkstat`
  and the toggle-handshake DRP proxy; generic outputs `core_clk0`
  (fractional-capable) / `core_clk1` / `core_clk2`: `boards/BOUNDARY-V2.md`
  + v3 annex. RM clocking rule: an RM must program its own presets at wake.
- **Video preset** — `vclk_sel_o` request, 64-cycle stability filter,
  `hdmi_rst` as the only feedback: `boards/BOUNDARY-V1.md`.
- **Memory** — one burst-capable 16-bit Avalon-MM slave; waitrequest is
  forced while decoupled or the memory subsystem is not ready
  (`clkstat[2]` mirrors readiness informationally); RAM content survives
  swaps: `boards/BOUNDARY-V3.md`.
- **QSPI flash** — data/CS through the boundary, clock proxied via the
  shell-owned STARTUPE2: `boards/BOUNDARY-V3.md`.
- **RM conversion** — how to turn a core into an RM against this boundary:
  `RM-CONVERSION-GUIDE.md`.
