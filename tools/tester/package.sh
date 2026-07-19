#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-or-later
# Assemble the MEGA65 R6 tester zip from the current build artifacts of the
# mega65-shell repo and its sibling core repos.  Run from tools/tester/.
# Output: dist/m65r6-dfx-<date>.zip
#
# Package naming: config_menu / config_democore / config_mpatrol (build
# names config_picorv32_r6 / config_a / config_mpatrol_r6).  The menu is
# the entry .bit and must be built with baked-in firmware
# (rm_synth_r6 UART_BOOT=false) so it comes alive without a host.
set -eu

SHELL_BUILD=${SHELL_BUILD:-../../build/r6}
MENU_BUILD=${MENU_BUILD:-../../../picorv32-menu/build}
MPATROL_BUILD=${MPATROL_BUILD:-../../../MoonPatrolMEGA65_r3_r6/CORE/build-r6-dfx}

DATE=$(date +%Y%m%d)
NAME=m65r6-dfx-$DATE
OUT=dist/$NAME

test -f "$SHELL_BUILD/config_a.bit" || { echo "no shell artifacts in $SHELL_BUILD" >&2; exit 1; }
test -f "$MENU_BUILD/config_picorv32_r6.bit" || { echo "no menu artifacts in $MENU_BUILD" >&2; exit 1; }
test -f "$MPATROL_BUILD/config_mpatrol_r6.bit" || { echo "no mpatrol artifacts in $MPATROL_BUILD" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# entry image (menu, firmware baked) + JTAG fallback (democore)
cp "$MENU_BUILD/config_picorv32_r6.bit"                 "$OUT/config_menu.bit"
cp "$SHELL_BUILD/config_a.bit"                          "$OUT/config_democore.bit"

# partials for the SD card / serial loader
cp "$SHELL_BUILD/config_a_pblock_RM_partial.bin"        "$OUT/config_democore_pblock_RM_partial.bin"
cp "$MENU_BUILD/config_picorv32_r6_pblock_RM_partial.bin" "$OUT/config_menu_pblock_RM_partial.bin"
cp "$MPATROL_BUILD/config_mpatrol_r6_pblock_RM_partial.bin" "$OUT/config_mpatrol_pblock_RM_partial.bin"

cp ../send_partial.py TESTER-GUIDE.md "$OUT/"

(cd "$OUT" && sha256sum -- * > sha256sums.txt)
mkdir -p dist
(cd dist && zip -qr "$NAME.zip" "$NAME")

echo "packaged: dist/$NAME.zip"
