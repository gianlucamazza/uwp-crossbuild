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

layout=""
language="en-US"
die() {
	echo "error: $*" >&2
	exit 1
}
# A flag whose value is missing would otherwise fail on an unbound $2 under
# `set -u`, naming the shell rather than the argument.
value() { # value <flag> <argc>
	[[ $2 -ge 2 ]] || die "$1 needs a value"
}
# The comment block at the top of this file is the usage text. Printing it back
# means there is one description of the flags, not two that drift apart.
usage() {
	awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' \
		"$(readlink -f "${BASH_SOURCE[0]}")"
	exit 0
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--layout) value "$1" $# && layout="$2" && shift 2 ;;
	--language) value "$1" $# && language="$2" && shift 2 ;;
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
# makepri can exit 0 having written an empty file when the indexer finds nothing
# it recognises. Nothing here can validate the contents — that needs the loader
# on a device — but an empty .pri is certainly wrong, and it installs.
size="$(stat -c%s "$layout/resources.pri")"
[[ $size -gt 0 ]] || die "makepri wrote an empty resources.pri from $layout"
printf 'resources.pri: %s bytes\n' "$size"
