#!/usr/bin/env bash
# Install a mega65-shell RM overlay into a MiSTer2MEGA65-based core checkout.
#
#   ./install-overlay.sh wukong /path/to/core-checkout   # base: M2M fork master
#   ./install-overlay.sh r6     /path/to/core-checkout   # base: upstream MiSTer2MEGA65
#
# Copies the overlay's files/ tree into the checkout (pure additions) and
# applies any patches/ (only the r6 overlay has one: the ascal reset fix).
# See the per-board OVERLAY-INFO.md for the pinned base revision.
set -euo pipefail

usage() { echo "usage: $0 <wukong|r6> <path-to-core-checkout>" >&2; exit 1; }
[ $# -eq 2 ] || usage
board=$1
target=$2
here="$(cd "$(dirname "$0")" && pwd)"

case "$board" in
   wukong) src="$here/m2m-wukong" ;;
   r6)     src="$here/m2m-r6" ;;
   *)      usage ;;
esac

if [ ! -f "$target/CORE/vhdl/mega65.vhd" ] || [ ! -d "$target/M2M/vhdl" ]; then
   echo "ERROR: '$target' does not look like a MiSTer2MEGA65-based checkout" >&2
   echo "       (expected CORE/vhdl/mega65.vhd and M2M/vhdl/)" >&2
   exit 1
fi

echo "== Copying overlay files into $target"
(cd "$src/files" && find . -type f | sed 's|^\./||') | while read -r f; do
   mkdir -p "$target/$(dirname "$f")"
   cp -v "$src/files/$f" "$target/$f"
done

for p in "$src"/patches/*.patch; do
   [ -e "$p" ] || continue
   echo "== Applying $(basename "$p")"
   if patch -d "$target" -p1 -N --dry-run < "$p" >/dev/null 2>&1; then
      patch -d "$target" -p1 -N < "$p"
   elif patch -d "$target" -p1 -R --dry-run < "$p" >/dev/null 2>&1; then
      echo "   already applied — skipping"
   else
      echo "ERROR: $(basename "$p") does not apply — the checkout does not match" >&2
      echo "       the overlay's pinned base (see OVERLAY-INFO.md)" >&2
      exit 1
   fi
done

echo "== Overlay '$board' installed. Next: see $src/OVERLAY-INFO.md"
