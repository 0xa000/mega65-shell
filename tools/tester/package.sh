#!/bin/sh
# Assemble the tester zip from the current CORE/build-r6-dfx artifacts.
# Run from CORE/dfx-tester/.  Output: dist/m65r6-dfx-<date>.zip
set -eu

BUILD=../build-r6-dfx
DATE=$(date +%Y%m%d)
NAME=m65r6-dfx-$DATE
OUT=dist/$NAME

test -f $BUILD/config_a.bit || { echo "no artifacts in $BUILD" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

cp $BUILD/config_a.bit $BUILD/config_b.bit \
   $BUILD/config_a_pblock_RM_partial.bin \
   $BUILD/config_b_pblock_RM_partial.bin \
   send_partial.py TESTER-GUIDE.md "$OUT/"

(cd "$OUT" && sha256sum -- * > sha256sums.txt)
(cd dist && zip -r "$NAME.zip" "$NAME")

echo "packaged: dist/$NAME.zip"
