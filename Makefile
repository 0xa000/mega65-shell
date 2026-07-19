# SPDX-License-Identifier: LGPL-3.0-or-later
# mega65-shell — convenience wrapper around flow/dfx.tcl
#
#   make BOARD=wukong static SEED_RM_DCP=/path/to/rm_democore_synth.dcp \
#        [SEED_RM_XDC=/path/to/qnice-rm.xdc]
#   make BOARD=wukong child RM_DCP=... NAME=menu [RM_XDC=...]
#   make BOARD=wukong verify
#
# The seed RM is an input artifact (the repo contains no core code); any RM
# synthesis checkpoint matching the board's boundary works.

BOARD  ?= wukong
VIVADO ?= /opt/Xilinx/Vivado/2023.2/bin/vivado

BUILD   := build/$(BOARD)
RUN      = $(VIVADO) -mode batch -nojournal -log $(BUILD)/vivado_$@.log \
           -source flow/dfx.tcl -tclargs $(BOARD)

$(shell mkdir -p $(BUILD))

.PHONY: elab synth link child verify static sim clean

elab:
	$(RUN) static_elab

synth:
	$(RUN) static_synth

link:
	$(RUN) link SEED_RM_DCP=$(SEED_RM_DCP) $(if $(SEED_RM_XDC),SEED_RM_XDC=$(SEED_RM_XDC))

# synth + link + verify-ready static in one go
static: synth link

child:
	$(RUN) child RM_DCP=$(RM_DCP) NAME=$(NAME) $(if $(RM_XDC),RM_XDC=$(RM_XDC))

verify:
	$(RUN) verify $(EXTRA_CONFIGS)

# GHDL testbench for the SD/FAT32 load path (card model enforces NCS timing)
sim:
	ghdl -a --std=08 --workdir=sim rtl/common/uart_rx.vhdl rtl/common/uart_tx.vhdl \
	   rtl/common/sd_sector.vhdl rtl/common/fat32_walker.vhdl rtl/common/load_ctrl.vhdl \
	   sim/tb_sd_load.vhd
	ghdl --elab-run --std=08 --workdir=sim tb_sd_load --assert-level=error

clean:
	rm -rf build
