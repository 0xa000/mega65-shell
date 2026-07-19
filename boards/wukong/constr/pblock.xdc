# Reconfigurable partition floorplan for the thin shell (XC7A100T).
#
# Grown for the VIC20 RM (2026-07-09): VIC20 needs 111 RAMB36 + 22 RAMB18 (OOC
# synth), so the RP must reach into the BRAM-dense right-hand clock regions.
# Device has 135 RAMB36; the static uses only 2 (a DDR3 FIFO at X0Y30/31) plus
# IO-anchored blocks (DDR3 PHY in X0Y3, HDMI OSERDES in X1Y2's IO column),
# and only ~4k LUTs total — so the static fits comfortably in region X0Y3.
#
# RP = clock-region rows 0,1,2 (FULL width) + the right half of row 3 (X1Y3):
#   rows 0-1  : 70 RAMB36
#   row 2     : 40 RAMB36  (X0Y2 10 + X1Y2 30 — reclaims X1Y2 fabric; the HDMI
#               OSERDES stay static in that region's IO column, OLOGIC_X1Y101..
#               106, which is not a SLICE/RAMB/DSP site so it is not in these
#               ranges)
#   X1Y3      : 15 RAMB36
#   -------------------------------------------------------------------
#   total     : 125 RAMB36 tiles -> VIC20's 111 fits at ~89% fill (tight).
# Static keeps X0Y3 (DDR3 region: PHY IO + the 2 FIFO BRAMs) + the CMT columns
# (MMCMs/PLLs are dedicated, not fabric).  Ranges below are per-grid-type
# bounding boxes; SNAPPING_MODE reconciles exact column boundaries (DRC HDPR-45
# wants every grid type ranged).  RESET_AFTER_RECONFIG needs clock-region-
# aligned height, which full-region rows satisfy.

create_pblock pblock_RM
add_cells_to_pblock [get_pblocks pblock_RM] [get_cells RM]

# clock-region rows 0-1, full width
resize_pblock [get_pblocks pblock_RM] -add {SLICE_X0Y0:SLICE_X89Y99}
resize_pblock [get_pblocks pblock_RM] -add {RAMB36_X0Y0:RAMB36_X3Y19}
resize_pblock [get_pblocks pblock_RM] -add {RAMB18_X0Y0:RAMB18_X3Y39}
resize_pblock [get_pblocks pblock_RM] -add {DSP48_X0Y0:DSP48_X2Y39}

# clock-region row 2, FULL width (X0Y2 + X1Y2 fabric; OSERDES IO stays static)
resize_pblock [get_pblocks pblock_RM] -add {SLICE_X0Y100:SLICE_X89Y149}
resize_pblock [get_pblocks pblock_RM] -add {RAMB36_X0Y20:RAMB36_X3Y29}
resize_pblock [get_pblocks pblock_RM] -add {RAMB18_X0Y40:RAMB18_X3Y59}
resize_pblock [get_pblocks pblock_RM] -add {DSP48_X0Y40:DSP48_X2Y59}

# clock-region row 3, RIGHT half only (X1Y3); X0Y3 stays static for DDR3
resize_pblock [get_pblocks pblock_RM] -add {SLICE_X52Y150:SLICE_X81Y199}
resize_pblock [get_pblocks pblock_RM] -add {RAMB36_X1Y30:RAMB36_X2Y39}
resize_pblock [get_pblocks pblock_RM] -add {RAMB18_X1Y60:RAMB18_X2Y79}
resize_pblock [get_pblocks pblock_RM] -add {DSP48_X1Y60:DSP48_X2Y79}
# The lone PCIE hard block sits in X1Y3; range it so the RP owns every grid
# type in its rectangle (DRC HDPR-45).  The RM never instantiates PCIE — this
# just reserves the site for routability at high fill.
resize_pblock [get_pblocks pblock_RM] -add {PCIE_X0Y0:PCIE_X0Y0}

set_property RESET_AFTER_RECONFIG true [get_pblocks pblock_RM]
set_property SNAPPING_MODE ON [get_pblocks pblock_RM]
