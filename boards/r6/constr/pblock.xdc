# Reconfigurable partition floorplan for the thin shell (MEGA65 R6,
# XC7A200T-FBG484).
#
# Geometry (queried from the flat democore's post_route.dcp, 2026-07-11):
#   * clock regions X0Y0..X1Y4 (2 columns x 5 rows)
#   * HyperRAM (bank 16 + IDELAYCTRL + all its I/O logic) sits ENTIRELY in
#     region X0Y4; the HDMI TMDS pins (bank 34) are in X1Y2's IO column
#     (OLOGIC — not a SLICE/RAMB/DSP site, so not in these ranges)
#   * the shell needs 0 BRAM and 0 DSP; row Y4 has 5050 slices (~20k LUTs)
#     for the shell's ~4k
#
# RP = clock-region rows Y0..Y3, FULL width:
#   SLICEs   28600 (~114k LUTs)   RAMB36  320 of 365   DSP48  640 of 740
# Static keeps row Y4 (both X0Y4 + X1Y4): HyperRAM I/O + fabric, PCIE_X0Y0,
# the upper GTP quad — and the CMT columns everywhere (MMCMs/PLLs are
# dedicated sites, not fabric).  The GTP quad in row Y0 and the XADC (X0Y3)
# fall inside the RP rectangle and are ranged so the RP owns every grid type
# in its rectangle (DRC HDPR-45); no RM instantiates them.
# Ranges are per-grid-type bounding boxes; SNAPPING_MODE reconciles exact
# column boundaries.  RESET_AFTER_RECONFIG needs clock-region-aligned
# height, which full rows Y0..Y3 satisfy.

create_pblock pblock_RM
add_cells_to_pblock [get_pblocks pblock_RM] [get_cells RM]

resize_pblock [get_pblocks pblock_RM] -add {SLICE_X0Y0:SLICE_X163Y199}
resize_pblock [get_pblocks pblock_RM] -add {RAMB36_X0Y0:RAMB36_X8Y39}
resize_pblock [get_pblocks pblock_RM] -add {RAMB18_X0Y0:RAMB18_X8Y79}
resize_pblock [get_pblocks pblock_RM] -add {DSP48_X0Y0:DSP48_X8Y79}

# Hard blocks inside the RP rectangle (unused by any RM; ranged for HDPR-45)
resize_pblock [get_pblocks pblock_RM] -add {GTPE2_CHANNEL_X0Y0:GTPE2_CHANNEL_X1Y3}
resize_pblock [get_pblocks pblock_RM] -add {GTPE2_COMMON_X0Y0:GTPE2_COMMON_X1Y0}
resize_pblock [get_pblocks pblock_RM] -add {XADC_X0Y0:XADC_X0Y0}

set_property RESET_AFTER_RECONFIG true [get_pblocks pblock_RM]
set_property SNAPPING_MODE ON [get_pblocks pblock_RM]
