#!/usr/bin/env python3
"""XAPP888 MMCM DRP row-table generator (7-series) — the "one table" tool.

Boundary v2 (docs/boards/BOUNDARY-V2.md): each RM build consumes ONE
frequency table per MMCM, from which the flow generates the DRP payload rows
for the RM's clk_drp_master ROM.  Never hand-edit generated rows; rerun this.

Row format matches video_out_clock.vhd's preset ROM: (daddr, data, mask),
where the shell's drp_proxy performs  DRP_write((DRP_read() & mask) | data).

Lock/filter lookup tables and register assembly are taken from Vivado's
clocking-wizard DRP functions (authoritative, currently shipped):
  /opt/Xilinx/Vivado/2023.2/data/ip/xilinx/clk_wiz_v6_0/mmcm_pll_drp_func_7s_mmcm.vh
Validated against the hardware-verified vectors in video_out_clock.vhd (see
selftest): filter and counter rows match exactly; lock register 0x1A differs
from the older XAPP888 .xls in the LockSatHigh field (1001 vs 489) — a lock
monitor window revision, functionally benign, we follow the current tables.

Fractional MULT / CLKOUT0 divide are supported (mmcm_frac_count_calc, ported
bit-exact from the same .vh + the ROM assembly in mmcm_pll_drp_v.ttcl, and
validated against iverilog golden vectors in selftest).  7-series constraint:
only CLKOUT0 and CLKFBOUT can be fractional (CLKOUT1..6 are integer-only), so
a fractional-video core (e.g. VIC20 70.926 MHz = /13.5) must put that clock on
CLKOUT0.  A fractional counter also tucks its FRAC_TIME bits into an unused
sibling register (CLKOUT0 -> 0x07, CLKFBOUT -> 0x13), so those rows appear too.

Phase is 0 for every clock in this project (matches counter_rows); the
fractional port assumes phase 0.

DFX carve-out done by 0xa000 in 2026.
SPDX-License-Identifier: LGPL-3.0-or-later
"""

import argparse
import sys

# --- lock table (divides 1..64): (RefDly==FBDly, LockCnt); SatHigh/Unlock fixed
_LOCK_DLY = [6, 6, 8, 11, 14, 17, 19, 22, 25, 28] + [31] * 54
_LOCK_CNT = ([1000] * 10 +
             [900, 825, 750, 700, 650, 625, 575, 550, 525, 500,
              475, 450, 425, 400, 400, 375, 350, 350, 325, 325,
              300, 300, 300, 275, 275, 275] + [250] * 28)
_LOCK_SAT_HIGH = 0x3E9   # 1001, all divides
_LOCK_UNLOCK_CNT = 1     # all divides

# --- filter table, HIGH/OPTIMIZED bandwidth (divides 1..64): (CP, RES); LFHF=0
_FILT_HIGH = (
    [(0b0010, 0b1111), (0b0100, 0b1111), (0b0101, 0b1011), (0b0111, 0b0111),
     (0b1101, 0b0111), (0b1110, 0b1011), (0b1110, 0b1101), (0b1111, 0b0011),
     (0b1110, 0b0101), (0b1111, 0b0101), (0b1111, 0b1001), (0b1101, 0b0001)] +
    [(0b1111, 0b1001)] * 4 +      # 13-16
    [(0b1111, 0b0101)] * 2 +      # 17-18
    [(0b1100, 0b0001)] * 3 +      # 19-21
    [(0b0101, 0b1100)] * 4 +      # 22-25
    [(0b0011, 0b0100)] * 16 +     # 26-41
    [(0b0010, 0b1000)] * 5 +      # 42-46
    [(0b0111, 0b0001)] * 2 +      # 47-48
    [(0b0100, 0b1100)] * 4 +      # 49-52
    [(0b0110, 0b0001)] * 2 +      # 53-54
    [(0b0101, 0b0110)] * 3 +      # 55-57
    [(0b0010, 0b0100)] * 4 +      # 58-61
    [(0b0100, 0b1010)] +          # 62
    [(0b0011, 0b1100)] * 2)       # 63-64

# DRP addresses of the counter register pairs
_COUNTER_ADDR = {'CLKOUT0': 0x08, 'CLKOUT1': 0x0A, 'CLKOUT2': 0x0C,
                 'CLKOUT3': 0x0E, 'CLKOUT4': 0x10, 'CLKOUT5': 0x06,
                 'CLKOUT6': 0x12, 'CLKFBOUT': 0x14}


def counter_rows(name, divide):
    """reg1/reg2 for one counter, integer divide, 0 phase, 50% duty."""
    addr = _COUNTER_ADDR[name]
    if divide == 1:
        ht, lt, edge, nc = 1, 1, 0, 1
    else:
        ht = divide // 2
        lt = divide - ht
        edge = divide & 1
        nc = 0
    # reg1: [15:13] phase_mux=0, [12] reserved (masked), [11:6] HT, [5:0] LT
    reg1 = 0x1000 | (ht << 6) | lt
    # reg2: FRAC fields 0 (integer), [9:8] MX=0, [7] EDGE, [6] NO_COUNT, [5:0] DT=0
    reg2 = (edge << 7) | (nc << 6)
    return [(addr, reg1, 0x1000, f"{name} Register 1 (divide {divide})"),
            (addr + 1, reg2, 0x8000, f"{name} Register 2")]


def divclk_row(divide):
    if divide == 1:
        ht, lt, nc = 1, 1, 1
    else:
        ht = divide // 2
        lt = divide - ht
        nc = 0
    # [13] EDGE=0 (internal divider, duty irrelevant), [12] NO_COUNT
    val = (nc << 12) | (ht << 6) | lt
    return [(0x16, val, 0xC000, f"DIVCLK Register (divide {divide})")]


# --- Fractional counter support (7-series MMCM) -----------------------------
# Bit-exact port of mmcm_frac_count_calc + mmcm_pll_divider + round_frac from
# mmcm_pll_drp_func_7s_mmcm.vh (FRAC_PRECISION=10, FIXED_WIDTH=32).  Verilog
# uses [32:1] one-indexed vectors: x[k] has weight 2^(k-1).  Only phase 0 is
# used here.  Validated against iverilog (see the golden vectors in selftest).

def _round_frac(decimal, precision):
    # Verilog: if decimal[10-precision]==1 add (1 << (10-precision)); [32:1]
    # indexing means bit (10-precision) has weight 2^(10-precision-1).
    if (decimal >> (10 - precision - 1)) & 1:
        decimal += (1 << (10 - precision))
    return decimal


def _pll_divider(divide, duty=50000):
    """mmcm_pll_divider -> 14 bits {w_edge, no_count, high[5:0], low[5:0]}."""
    duty_fix = (duty << 10) // 100000
    if divide == 1:
        w_edge, no_count, high, low = 0, 1, 1, 1
    else:
        temp = _round_frac(duty_fix * divide, 1)
        high = (temp >> 10) & 0x7F          # temp[17:11]
        w_edge = (temp >> 9) & 1            # temp[10]
        if high == 0:
            high, w_edge = 1, 0
        if high == divide:
            high, w_edge = divide - 1, 1
        low = divide - high
        no_count = 0
    return (w_edge << 13) | (no_count << 12) | ((high & 0x3F) << 6) | (low & 0x3F)


def mmcm_frac_count_calc(divide, frac):
    """38-bit fractional counter result (phase 0, 50% duty).  frac in
    thousandths and a multiple of 125 (the MMCM's 0.125 fractional step)."""
    assert 0 <= frac <= 875 and frac % 125 == 0, "frac must be 0..875 step 125"
    dfrac = frac // 125                       # clkout0_divide_frac, 0..7
    even_high = divide >> 1
    odd = divide - 2 * even_high
    odd_and_frac = 8 * odd + dfrac
    lt_frac = (even_high - (1 if odd_and_frac <= 9 else 0)) & 0xFF
    ht_frac = (even_high - (1 if odd_and_frac <= 8 else 0)) & 0xFF
    pm_fall = (((odd & 0x7F) << 2) + ((dfrac >> 1) & 0x3)) & 0xFF
    wf_fall = 1 if ((2 <= odd_and_frac <= 9) or (dfrac == 1 and divide == 2)) else 0
    wf_rise = 1 if (1 <= odd_and_frac <= 8) else 0
    # phase 0 -> pm_rise_frac, dt and their derivatives all vanish
    pm_fall_frac = pm_fall & 0xFF
    pm_fall_frac_filtered = (pm_fall - (pm_fall_frac & 0xF8)) & 0xFF
    edge_nocount = (_pll_divider(divide) >> 12) & 0x3   # div_calc[13:12]
    v = 0
    v |= (pm_fall_frac_filtered & 0x7) << 33
    v |= (wf_fall & 0x1) << 32
    v |= (dfrac & 0x7) << 28
    v |= 1 << 27                              # FRAC_EN
    v |= (wf_rise & 0x1) << 26
    # phase_calc[10:9] (MX) is always 00 (coarse mux); dt/pm_rise = 0 @ phase 0
    v |= (edge_nocount & 0x3) << 22
    v |= (ht_frac & 0x3F) << 6
    v |= (lt_frac & 0x3F)
    return v


def frac_counter_rows(name, divide, frac):
    """Fractional CLKOUT0 or CLKFBOUT: reg1 (mask 0x1000), reg2 (mask 0x8000)."""
    addr = _COUNTER_ADDR[name]
    fc = mmcm_frac_count_calc(divide, frac)
    return [(addr, fc & 0xFFFF, 0x1000, f"{name} Register 1 (divide {divide}.{frac:03d})"),
            (addr + 1, (fc >> 16) & 0xFFFF, 0x8000, f"{name} Register 2 (fractional)")]


def shared_frac_row(addr, frac_calc, host):
    """FRAC_TIME[35:32] of a fractional counter is stored in an UNUSED sibling
    output's reg2 (CLKOUT0 -> CLKOUT5 @ 0x07, CLKFBOUT -> CLKOUT6 @ 0x13).
    The sibling is unused (divide 1) so its reg2 = 0x0040 (NO_COUNT), leaving
    bits [15:14]=0 preserved and [9:0]=0x040; FRAC_TIME lands in [13:10]."""
    frac_time = (frac_calc >> 32) & 0xF
    host_reg2 = 0x0040                        # count_calc(1) reg2 for unused host
    data = (host_reg2 & 0x3FF) | (frac_time << 10)   # [15:14] preserved by mask
    return [(addr, data, 0xC000, f"{host} Reg2 + FRAC_TIME (daddr 0x{addr:02X})")]


def lock_rows(mult):
    dly = _LOCK_DLY[mult - 1]
    cnt = _LOCK_CNT[mult - 1]
    return [(0x18, cnt, 0xFC00, "Lock Register 1"),
            (0x19, (dly << 10) | _LOCK_UNLOCK_CNT, 0x8000, "Lock Register 2"),
            (0x1A, (dly << 10) | _LOCK_SAT_HIGH, 0x8000, "Lock Register 3")]


def filter_rows(mult):
    cp, res = _FILT_HIGH[mult - 1]
    f = (cp << 6) | (res << 2) | 0b00       # filt[9:0] = CP & RES & LFHF
    r4e = (((f >> 9) & 1) << 15) | (((f >> 7) & 3) << 11) | (((f >> 6) & 1) << 8)
    r4f = (((f >> 5) & 1) << 15) | (((f >> 3) & 3) << 11) | \
          (((f >> 1) & 3) << 7) | ((f & 1) << 4)
    return [(0x4E, r4e, 0x66FF, "Filter Register 1"),
            (0x4F, r4f, 0x666F, "Filter Register 2")]


def power_row():
    return [(0x28, 0xFFFF, 0x0000, "Power Register")]


def make_table(mult, mult_frac, divclk, clkouts):
    """clkouts: dict name -> (divide, frac).  mult_frac / per-clkout frac in
    thousandths (0 = integer).  Only CLKOUT0 and CLKFBOUT may be fractional
    (7-series).  Lock/filter are looked up by the INTEGER mult, as clk_wiz does.
    """
    rows = []
    for name in ('CLKOUT0', 'CLKOUT1', 'CLKOUT2', 'CLKOUT3',
                 'CLKOUT4', 'CLKOUT5', 'CLKOUT6'):
        if name in clkouts:
            div, frac = clkouts[name]
            if frac:
                if name != 'CLKOUT0':
                    raise ValueError('only CLKOUT0 supports fractional divide')
                rows += frac_counter_rows(name, div, frac)
            else:
                rows += counter_rows(name, div)
    if mult_frac:
        rows += frac_counter_rows('CLKFBOUT', mult, mult_frac)
    else:
        rows += counter_rows('CLKFBOUT', mult)
    # Shared FRAC_TIME rows — only when the respective counter is fractional
    clk0 = clkouts.get('CLKOUT0')
    if clk0 and clk0[1]:
        rows += shared_frac_row(0x07, mmcm_frac_count_calc(clk0[0], clk0[1]), 'CLKOUT5')
    if mult_frac:
        rows += shared_frac_row(0x13, mmcm_frac_count_calc(mult, mult_frac), 'CLKOUT6')
    rows += divclk_row(divclk)
    rows += lock_rows(mult)
    rows += power_row()
    rows += filter_rows(mult)
    return rows


def selftest():
    """Reproduce hardware-verified video_out_clock.vhd vectors."""
    ok = True

    def chk(what, got, want):
        nonlocal ok
        if got != want:
            print(f"FAIL {what}: got {got:#06x} want {want:#06x}")
            ok = False

    # counter encodings (integer divides from the verified presets)
    for div, r1, r2 in ((25, 0x130D, 0x0080), (35, 0x1452, 0x0080),
                        (10, 0x1145, 0x0000), (2, 0x1041, 0x0000),
                        (5, 0x1083, 0x0080), (7, 0x10C4, 0x0080)):
        rows = counter_rows('CLKOUT1', div)
        chk(f"counter{div}.reg1", rows[0][1], r1)
        chk(f"counter{div}.reg2", rows[1][1], r2)
    # DIVCLK=5 -> 0x0083 (verified in all video_out_clock presets)
    chk("divclk5", divclk_row(5)[0][1], 0x0083)
    # lock regs, divide 37/47 (presets 3/2): 0x18/0x19 match verified vectors;
    # 0x1A LockSatHigh differs from the old .xls by design (see header)
    for mult in (37, 47):
        rows = lock_rows(mult)
        chk(f"lock{mult}.r18", rows[0][1], 0x00FA)
        chk(f"lock{mult}.r19", rows[1][1], 0x7C01)
    # filter regs, divide 37 (preset 3) and 47 (preset 2), verified exactly
    rows = filter_rows(37)
    chk("filt37.r4e", rows[0][1], 0x0900)
    chk("filt37.r4f", rows[1][1], 0x1000)
    rows = filter_rows(47)
    chk("filt47.r4e", rows[0][1], 0x1900)
    chk("filt47.r4f", rows[1][1], 0x0100)

    # --- Fractional vectors, golden from iverilog running the real Xilinx
    # .vh (mmcm_frac_count_calc) on VIC20's counters.  Regenerate with
    # tools/mmcm_frac_golden.v (see its header) if the port/presets change.
    chk("frac.clkout0(13.500)", mmcm_frac_count_calc(13, 500), 0x0C48800186)
    chk("frac.clkfbout(47.875)", mmcm_frac_count_calc(47, 875), 0x0E788005D7)
    # Assembled frac-specific rows must equal the clk_wiz golden exactly
    # (addr, data, mask); the integer rows follow the video_out_clock
    # convention above and are covered by the checks already made.
    golden = {0x08: (0x0186, 0x1000), 0x09: (0x4880, 0x8000),
              0x07: (0x3040, 0xC000), 0x14: (0x05D7, 0x1000),
              0x15: (0x7880, 0x8000), 0x13: (0x3840, 0xC000)}
    vic20 = {a: (d, m) for a, d, m, _ in
             make_table(47, 875, 5, {'CLKOUT0': (13, 500), 'CLKOUT1': (27, 0)})}
    for addr, (data, mask) in golden.items():
        chk(f"vic20.row[0x{addr:02X}].data", vic20[addr][0], data)
        chk(f"vic20.row[0x{addr:02X}].mask", vic20[addr][1], mask)

    print("selftest OK" if ok else "selftest FAILED")
    return ok


def emit_vhdl(tables, name, fref, out):
    """tables: list of (target, mult, mult_frac, divclk, clkouts, rows).  One
    table = the classic single-MMCM ROM; several = one concatenated ROM whose
    rows carry per-table drp_targets (e.g. the C64 flicker-fix pair, CORE_A
    orig + CORE_B slow, programmed by one clk_drp_master pass)."""
    n = sum(len(t[5]) for t in tables)
    print(f"""\
----------------------------------------------------------------------------------
-- GENERATED FILE — do not hand-edit (BOUNDARY-V2.md one-table rule).
-- Regenerate:  python3 tools/mmcm_drp_table.py {' '.join(sys.argv[1:])}
--""", file=out)
    for target, mult, mult_frac, divclk, clkouts, _rows in tables:
        vco = fref * (mult + mult_frac / 1000) / divclk
        tgt = f" (target {target} = CORE_{'AB'[target]})" if len(tables) > 1 else ""
        print(f"-- MMCM preset{tgt}: fref={fref} MHz, DIVCLK={divclk}, "
              f"MULT={mult + mult_frac / 1000:g} (VCO={vco:g} MHz)", file=out)
        for cname, (div, frac) in clkouts.items():
            dv = div + frac / 1000
            print(f"--   {cname}_DIVIDE = {dv:g}  ->  {vco / dv:g} MHz", file=out)
    print(f"""\
--
-- Row format (42 bit): [41:39] drp_target, [38:32] daddr, [31:16] data,
-- [15:0] read mask (shell writes (read & mask) | data).
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package {name}_pkg is
   constant C_{name.upper()}_ROWS : natural := {n};
   function {name}_row(idx : natural) return std_logic_vector;
end package {name}_pkg;

package body {name}_pkg is

   function {name}_row(idx : natural) return std_logic_vector is
      variable v : std_logic_vector(41 downto 0);
   begin
      v := (others => '0');
      case idx is""", file=out)
    i = 0
    for target, _mult, _mf, _dc, _co, rows in tables:
        for addr, data, mask, comment in rows:
            print(f'         when {i:2} => v := "{target:03b}" & "{addr:07b}"'
                  f' & x"{data:04X}" & x"{mask:04X}";  -- {comment} (daddr 0x{addr:02X})',
                  file=out)
            i += 1
    print(f"""\
         when others => null;
      end case;
      return v;
   end function {name}_row;

end package body {name}_pkg;""", file=out)


def emit_xdc(tables, fref, out):
    """Child-configuration timing override, generated from the SAME table as the
    DRP ROM (BOUNDARY-V2.md one-table rule — STA and the runtime preset can't
    drift).  Redefines the shell's auto-derived MMCM output clocks so the RM's
    logic is timed at the frequency it actually programs, not the shell's 54 MHz
    parking default.

    Subtlety: each shell output clock is a glitch-free mux of CORE_A and CORE_B
    (the flicker-fix live-switch), and BOTH sources are declared as clocks on the
    mux OUTPUT net (main_clk/main_clk_b, video_clk/video_clk_b) — physically
    exclusive, but both time the RM logic.  A single-MMCM RM only programs its
    target core, leaving the OTHER core parked at 54 MHz; the RM logic then gets
    timed against that parked core's period too (e.g. main_clk_b at 54 -> bogus
    near-zero requirements).  So constrain BOTH cores' outputs to the RM's
    frequencies: the parked core never actually drives (mux stays on the target),
    so this only fixes STA — it does not describe the parked hardware.  Both cores
    derive from clk_100, so cross paths stay related and time correctly.

    Multi-table (e.g. C64 flicker-fix): each core takes the frequencies of ITS
    OWN table — both really run, alternately driving the muxes — so nothing is
    parked and nothing falls back."""
    from math import gcd
    if len(tables) == 1:
        target = tables[0][0]
        tcore = 'CORE_A' if target == 0 else 'CORE_B'
        what = (f"## Child timing override: the RM programs {tcore} to the frequencies below.\n"
                "## Both shell core MMCMs are constrained (both feed the output muxes / their\n"
                "## _b clocks); the un-programmed one never drives but must not be left timing\n"
                "## the RM logic at the 54 MHz park default.")
    else:
        what = ("## Child timing override: the RM programs BOTH core MMCMs (per-core tables\n"
                "## below) and live-switches the output muxes between them, so each core is\n"
                "## constrained at its own programmed frequencies.")
    print(f"""\
## GENERATED — do not hand-edit (BOUNDARY-V2.md one-table rule).
## Regenerate:  python3 tools/mmcm_drp_table.py {' '.join(sys.argv[1:])}
##
{what}  Read AFTER the common child XDC.""", file=out)
    by_target = {t[0]: t for t in tables}
    for tgt, core in ((0, 'i_core_a'), (1, 'i_core_b')):
        _t, mult, mult_frac, divclk, clkouts, _r = by_target.get(tgt, tables[0])
        num = mult * 1000 + mult_frac                 # MULT_total x 1000
        for name in ('CLKOUT0', 'CLKOUT1', 'CLKOUT2', 'CLKOUT3',
                     'CLKOUT4', 'CLKOUT5', 'CLKOUT6'):
            if name not in clkouts:
                continue
            div, frac = clkouts[name]
            den = divclk * (div * 1000 + frac)
            g = gcd(num, den)
            m, d = num // g, den // g
            freq = fref * num / den
            n = name[-1]
            print(f"create_generated_clock -name {core[2:]}_clk{n} "
                  f"-source [get_pins i_shell_core_clk/{core}/CLKIN1] "
                  f"-multiply_by {m} -divide_by {d} "
                  f"[get_pins i_shell_core_clk/{core}/CLKOUT{n}]  ;# {freq:.4f} MHz",
                  file=out)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--selftest', action='store_true')
    p.add_argument('--fref', type=float, default=100.0, help='input clock MHz')
    p.add_argument('--mult', help='CLKFBOUT_MULT_F, e.g. 47.875 or 10')
    p.add_argument('--divclk', type=int, default=1)
    p.add_argument('--clkout', action='append', default=[],
                   metavar='NAME=DIV', help='e.g. CLKOUT0=13.5 (repeatable); '
                   'only CLKOUT0 may be fractional')
    p.add_argument('--target', type=int, default=0,
                   help='drp_target: 0=CORE_A, 1=CORE_B')
    p.add_argument('--table', action='append', default=[], metavar='SPEC',
                   help='multi-MMCM form (repeatable), replaces --target/'
                   '--divclk/--mult/--clkout: e.g. '
                   '"target=0,divclk=6,mult=56.75,CLKOUT0=30".  All tables '
                   'land in ONE ROM whose rows carry per-table drp_targets '
                   '(one clk_drp_master pass programs every MMCM), and --xdc '
                   'constrains each core at its own table\'s frequencies')
    p.add_argument('--name', default='clk_preset', help='VHDL package base name')
    p.add_argument('--xdc', action='store_true',
                   help='emit the child-configuration timing override (XDC) '
                   'instead of the DRP ROM (VHDL)')
    p.add_argument('-o', '--output', default='-')
    args = p.parse_args()

    if args.selftest:
        sys.exit(0 if selftest() else 1)

    if args.table:
        if args.mult is not None or args.clkout:
            p.error('--table replaces --mult/--clkout (and --target/--divclk)')
    elif args.mult is None or not args.clkout:
        p.error('--mult and at least one --clkout required')

    def split_frac(text, what):
        """'47.875' -> (47, 875); '27' -> (27, 0).  Frac must be a 0.125 step."""
        try:
            val = float(text)
        except ValueError:
            p.error(f'{what}: not a number: {text!r}')
        whole = int(val)
        frac = round((val - whole) * 1000)
        if frac % 125 != 0:
            p.error(f'{what} {text}: fraction must be a multiple of 0.125')
        return whole, frac

    def parse_clkout(spec, clkouts):
        cname, div = spec.split('=')
        if cname not in _COUNTER_ADDR or cname == 'CLKFBOUT':
            p.error(f'bad clkout name {cname}')
        clkouts[cname] = split_frac(div, cname)

    def check_table(target, mult, mult_frac, divclk, clkouts):
        if not 2 <= mult <= 64:
            p.error('MULT out of range 2..64')
        vco = args.fref * (mult + mult_frac / 1000) / divclk
        if not 600.0 <= vco <= 1440.0:
            p.error(f'VCO {vco:g} MHz outside 600..1440 (A7 -2 speed grade)')
        rows = make_table(mult, mult_frac, divclk, clkouts)
        return (target, mult, mult_frac, divclk, clkouts, rows)

    tables = []
    if args.table:
        for tspec in args.table:
            target, divclk, mult, mult_frac, clkouts = 0, 1, None, 0, {}
            for item in tspec.split(','):
                key, val = item.split('=', 1)
                if key == 'target':
                    target = int(val)
                elif key == 'divclk':
                    divclk = int(val)
                elif key == 'mult':
                    mult, mult_frac = split_frac(val, 'mult')
                else:
                    parse_clkout(item, clkouts)
            if mult is None or not clkouts:
                p.error(f'--table {tspec!r}: mult= and a CLKOUTn= required')
            tables.append(check_table(target, mult, mult_frac, divclk, clkouts))
        if len({t[0] for t in tables}) != len(tables):
            p.error('duplicate target across --table specs')
    else:
        mult, mult_frac = split_frac(args.mult, 'MULT')
        clkouts = {}
        for spec in args.clkout:
            parse_clkout(spec, clkouts)
        tables.append(check_table(args.target, mult, mult_frac,
                                  args.divclk, clkouts))

    out = sys.stdout if args.output == '-' else open(args.output, 'w')
    if args.xdc:
        emit_xdc(tables, args.fref, out)
    else:
        emit_vhdl(tables, args.name, args.fref, out)
    if out is not sys.stdout:
        out.close()


if __name__ == '__main__':
    main()
