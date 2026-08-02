#!/usr/bin/env bash
# gen-resources.sh — build resources.pri for a package layout, under Wine.
#
#   gen-resources.sh --layout /tmp/hello-layout [--language en-US]
#
# The layout must already hold AppxManifest.xml and the assets: makepri indexes
# what is on disk, so run this after everything else is in place. resources.pri
# lands in the layout, which is where the loader expects it.
set -euo pipefail

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=scripts/common.sh
. "$here/common.sh"

layout=""
language="en-US"

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--layout) value "$1" $# "${2:-}" && layout="$2" && shift 2 ;;
	--language) value "$1" $# "${2:-}" && language="$2" && shift 2 ;;
	*) die "unknown argument $1" ;;
	esac
done

[[ -n "$layout" ]] || die "--layout is required"
[[ -f "$layout/AppxManifest.xml" ]] || die "no AppxManifest.xml in $layout"

layout="$(cd "$layout" && pwd)"
# makepri writes its config somewhere it can also read back through Wine; the
# layout is not that place — anything left in there ships inside the package.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
config="$work/priconfig.xml"

# makepri refuses to index a directory that already holds its own output.
rm -f "$layout/resources.pri"

"$here/wine-tool.sh" makepri createconfig \
	/ConfigXml "$(winepath -w "$config")" /Default "$language" /Overwrite >/dev/null

"$here/wine-tool.sh" makepri new \
	/ProjectRoot "$(winepath -w "$layout")" \
	/ConfigXml "$(winepath -w "$config")" \
	/OutputFile "$(winepath -w "$layout/resources.pri")" \
	/Overwrite >/dev/null

[[ -f "$layout/resources.pri" ]] || die "makepri produced no resources.pri"
# makepri can exit 0 having written a file the loader will not load. Whether the
# *contents* are right needs the loader on a device, but the PRI container
# frames itself, so a truncated or empty file is detectable here: "mrm_pri2" in
# the first 8 bytes, the total file size as a little-endian uint32 at offset
# 0xc, and the magic again in the last 8 (observed on SDK 10.0.22621 output).
pri="$layout/resources.pri"
size="$(stat -c%s "$pri")"
# Compared as hex, not as strings: the surrounding bytes are binary, and bash
# command substitution drops NUL bytes with a warning.
magic="6d726d5f70726932" # "mrm_pri2"
[[ $size -ge 16 &&
	"$(head -c 8 "$pri" | od -A n -t x1 | tr -d ' \n')" == "$magic" &&
	"$(tail -c 8 "$pri" | od -A n -t x1 | tr -d ' \n')" == "$magic" ]] ||
	die "resources.pri is not a PRI container (no mrm_pri2 magic) — makepri wrote $size bytes from $layout"
declared="$(od -A n -t u4 -j 12 -N 4 "$pri" | tr -d ' ')"
[[ "$declared" == "$size" ]] ||
	die "resources.pri is truncated: header declares $declared bytes, file has $size"
printf 'resources.pri: %s bytes, container intact\n' "$size"
