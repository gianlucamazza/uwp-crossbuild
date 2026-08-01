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

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="${UWP_SDK_ROOT:-$HOME/.cache/uwp-crossbuild/sdk}"
SDK_VERSION="${UWP_SDK_VERSION:-10.0.22621.0}"
UNION="$SDK_ROOT/Windows Kits/10/UnionMetadata/$SDK_VERSION"

idl=""
name=""
out=""
stubs=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--idl) idl="$2" && shift 2 ;;
	--name) name="$2" && shift 2 ;;
	--out) out="$2" && shift 2 ;;
	--stubs) stubs="$2" && shift 2 ;;
	*) echo "error: unknown argument $1" >&2 && exit 1 ;;
	esac
done

die() {
	echo "error: $*" >&2
	exit 1
}
[[ -n "$idl" && -n "$name" && -n "$out" ]] || die "--idl, --name and --out are required"
[[ -f "$idl" ]] || die "no such file: $idl"
[[ -d "$UNION" ]] || die "no platform metadata at $UNION — run fetch-sdk.sh"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
stubs="${stubs:-$out/stubs}"
idl="$(cd "$(dirname "$idl")" && pwd)/$(basename "$idl")"

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
