#!/usr/bin/env bash
# build-app.sh — an example directory in, a package layout out.
#
#   build-app.sh --project examples/hello-uwp --out /tmp/hello-layout
#
# Drives the whole chain: midlrt and cppwinrt under Wine for the metadata and the
# projection, clang-cl for the executable, makepri for the resources. The result
# is a directory `openappx pack` accepts.
#
# The project directory must hold app.idl, AppxManifest.xml, Assets/ and the
# sources. --name defaults to the manifest's Application/@Executable minus .exe,
# which is also the namespace the .idl declares.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

project=""
out=""
name=""
no_pri=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	--project) project="$2" && shift 2 ;;
	--out) out="$2" && shift 2 ;;
	--name) name="$2" && shift 2 ;;
	--no-pri) no_pri=1 && shift ;;
	*) echo "error: unknown argument $1" >&2 && exit 1 ;;
	esac
done

die() {
	echo "error: $*" >&2
	exit 1
}
step() { printf '\n==> %s\n' "$*"; }

[[ -n "$project" && -n "$out" ]] || die "--project and --out are required"
[[ -f "$project/app.idl" ]] || die "no app.idl in $project"
[[ -f "$project/AppxManifest.xml" ]] || die "no AppxManifest.xml in $project"
project="$(cd "$project" && pwd)"

if [[ -z "$name" ]]; then
	name=$(sed -n 's/.*Executable="\([^"]*\)\.exe".*/\1/p' "$project/AppxManifest.xml" | head -1)
	[[ -n "$name" ]] || die "cannot read Executable from the manifest; pass --name"
fi

mkdir -p "$out"
out="$(cd "$out" && pwd)"
gen="$out/.gen"
rm -rf "$gen"

step "Metadata and projection ($name.winmd)"
"$here/gen-projection.sh" --idl "$project/app.idl" --name "$name" --out "$gen" >/dev/null

step "Compiling"
sources=()
for f in "$project"/*.cpp; do [[ -f "$f" ]] && sources+=("$f"); done
[[ ${#sources[@]} -gt 0 ]] || die "no .cpp files in $project"
# A project with a pch.h gets it precompiled — the difference between ~30 s and
# ~1 s per translation unit.
build_args=(--uwp --out "$out/$name.exe")
[[ -f "$project/pch.h" ]] && build_args+=(--pch "$project/pch.h")
# Objects and the ~190 MB precompiled header must stay outside the layout:
# whatever is in there ends up in the package, and makepri indexes it too.
UWP_OBJ_DIR="${UWP_OBJ_DIR:-$out.build}" \
	"$here/build.sh" "${build_args[@]}" "${sources[@]}" -- /I"$gen" /I"$project"

step "Assembling the layout"
cp "$project/AppxManifest.xml" "$out/"
[[ -d "$project/Assets" ]] && cp -r "$project/Assets" "$out/"
# The manifest's EntryPoint is resolved against this file at activation time.
cp "$gen/$name.winmd" "$out/"

if [[ $no_pri -eq 0 ]]; then
	step "Resources"
	"$here/gen-resources.sh" --layout "$out"
fi

rm -rf "$gen"
step "Layout ready: $out"
ls -la "$out"
