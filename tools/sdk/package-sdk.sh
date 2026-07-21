#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-or-later
# Assemble the SDK release asset set for one board from the current build
# artifacts.  Run from tools/sdk/.  Output: releases/sdk-<board>-<version>/
# (+ a zip beside it) — upload the directory contents as GitHub release
# assets on the matching tag (e.g. tag "r6-v5").
#
#   VERSION=v5 [BOARD=r6] [MENU_BUILD=...] ./package-sdk.sh
#
# The asset set is what docs/RM-CONVERSION-GUIDE.md §3 requires a core
# developer to have, plus the install images (see docs/SDK-RELEASE.md):
#   static_locked.dcp        THE ABI - every child link opens this
#   config_a_routed.dcp      pr_verify reference (contains the democore)
#   config_menu.bit          install image (shell + menu, firmware baked)
#   config_democore.bit      JTAG fallback install image (shell + democore)
#   config_*_partial.bin     known-good partials to sanity-check a load path
#   sha256sums.txt           asset checksums; static_locked.dcp's hash is
#                            the ABI identity together with RELEASE-INFO
#   RELEASE-INFO.txt         boundary version, part, Vivado version pin
#
# .cor packaging (MEGA65 flasher, no JTAG needed) is still a manual step:
# mega65-tools' bit2core on config_menu.bit — see docs/SDK-RELEASE.md.
set -eu

VERSION=${VERSION:?set VERSION=<boundary version, e.g. v5>}
BOARD=${BOARD:-r6}
SHELL_BUILD=${SHELL_BUILD:-../../build/$BOARD}
MENU_BUILD=${MENU_BUILD:-../../../picorv32-menu/build}
VIVADO_VER=${VIVADO_VER:-2023.2}

case $BOARD in
   r6)     PART=xc7a200tfbg484-2  MENU_CFG=config_picorv32_r6 ;;
   wukong) PART=xc7a100tfgg676-2  MENU_CFG=config_picorv32 ;;
   *)      echo "unknown BOARD=$BOARD" >&2; exit 1 ;;
esac

NAME=sdk-$BOARD-$VERSION
OUT=../../releases/$NAME

test -f "$SHELL_BUILD/static_locked.dcp"   || { echo "no locked static in $SHELL_BUILD" >&2; exit 1; }
test -f "$SHELL_BUILD/config_a_routed.dcp" || { echo "no config_a_routed.dcp in $SHELL_BUILD" >&2; exit 1; }
test -f "$MENU_BUILD/$MENU_CFG.bit"        || { echo "no menu artifacts in $MENU_BUILD" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# the ABI + the pr_verify reference
cp "$SHELL_BUILD/static_locked.dcp"   "$OUT/static_locked.dcp"
cp "$SHELL_BUILD/config_a_routed.dcp" "$OUT/config_a_routed.dcp"

# install images: menu (entry, firmware baked) + democore (JTAG fallback)
cp "$MENU_BUILD/$MENU_CFG.bit"        "$OUT/config_menu.bit"
cp "$SHELL_BUILD/config_a.bit"        "$OUT/config_democore.bit"

# known-good partials for load-path sanity checks
cp "$SHELL_BUILD/config_a_pblock_RM_partial.bin" \
   "$OUT/config_democore_pblock_RM_partial.bin"
cp "$MENU_BUILD/${MENU_CFG}_pblock_RM_partial.bin" \
   "$OUT/config_menu_pblock_RM_partial.bin"

cat > "$OUT/RELEASE-INFO.txt" <<EOF
mega65-shell SDK release
board:            $BOARD
part:             $PART
boundary version: $VERSION
Vivado version:   $VIVADO_VER  (exact-version requirement - see docs/SDK-RELEASE.md)
packaged:         $(date +%Y-%m-%d)

The ABI identity is the pair (sha256 of static_locked.dcp, Vivado version).
Every RM in a catalog must be built with this Vivado version and linked
against this exact static_locked.dcp; partials are only interchangeable
within one release.
EOF

(cd "$OUT" && sha256sum -- * > sha256sums.txt)
(cd ../../releases && zip -qr "$NAME.zip" "$NAME")

echo "packaged: releases/$NAME/ (+ releases/$NAME.zip)"
echo "ABI hash: $(sha256sum "$OUT/static_locked.dcp" | cut -d' ' -f1)"
