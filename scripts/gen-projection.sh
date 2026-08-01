#!/usr/bin/env bash
# gen-projection.sh — .idl -> .winmd -> C++/WinRT projection, under Wine.
#
#   gen-projection.sh --idl app.idl --name hello --out gen [--stubs gen/stubs]
#
# Produces, in --out:
#   <name>.winmd    the metadata. It must ship inside the package: a manifest
#                   with EntryPoint="<name>.App" is resolved against it.
#   App.g.h         base class for the implementation (App : AppT<App>)
#   module.g.cpp    the cppwinrt 2.x factory aggregator, compiled once
#   winrt/          projection headers for the types the .idl declares
#
# --stubs writes starter App.h / App.cpp somewhere separate; without it they
# would land next to the generated files and shadow the ones you wrote.
set -euo pipefail

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SDK_ROOT="${UWP_SDK_ROOT:-$HOME/.cache/uwp-crossbuild/sdk}"
SDK_VERSION="${UWP_SDK_VERSION:-10.0.22621.0}"
UNION="$SDK_ROOT/Windows Kits/10/UnionMetadata/$SDK_VERSION"

idl=""
name=""
out=""
stubs=""
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
	--idl) value "$1" $# && idl="$2" && shift 2 ;;
	--name) value "$1" $# && name="$2" && shift 2 ;;
	--out) value "$1" $# && out="$2" && shift 2 ;;
	--stubs) value "$1" $# && stubs="$2" && shift 2 ;;
	*) die "unknown argument $1" ;;
	esac
done

[[ -n "$idl" && -n "$name" && -n "$out" ]] || die "--idl, --name and --out are required"
[[ -f "$idl" ]] || die "no such file: $idl"
[[ -d "$UNION" ]] || die "no platform metadata at $UNION — run fetch-sdk.sh"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
stubs="${stubs:-$out/stubs}"
idl="$(cd "$(dirname "$idl")" && pwd)/$(basename "$idl")"

# Wine truncates a path past MAX_PATH without saying so: midlrt then reports the
# result as "not a winmd", and cppwinrt as a missing input. The tools are given
# paths under $out, so check it here rather than let either failure be diagnosed
# as a broken SDK. 200 leaves room for winrt/Windows.ApplicationModel.…h.
[[ ${#out} -lt 200 ]] || die "--out is too long for Windows MAX_PATH (${#out} chars): $out
  Build from a short directory, e.g. /tmp/build, or symlink one."

# midlrt writes its output next to the current directory and rejects /out with a
# Unix path (MIDL1012), so run it from the destination instead.
cd "$out"
"$here/wine-tool.sh" midlrt /winmd "$name.winmd" "$(winepath -w "$idl")"
[[ -f "$out/$name.winmd" ]] || die "midlrt produced no $name.winmd"

# -component is what emits App.g.h and module.g.cpp; without it cppwinrt only
# writes the projection headers. Its argument is where the starter App.h/App.cpp
# go, and they default out of the way because they would shadow real sources.
mkdir -p "$stubs"
"$here/wine-tool.sh" cppwinrt \
	-input "$name.winmd" -reference "$(winepath -w "$UNION")" \
	-output . -component "$(winepath -w "$stubs")" -prefix
[[ -f "$out/App.g.h" ]] || die "cppwinrt produced no App.g.h"

echo "projection ready in $out"
