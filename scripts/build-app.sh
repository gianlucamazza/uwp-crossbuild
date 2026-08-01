#!/usr/bin/env bash
# build-app.sh — an example directory in, a package layout out.
#
#   build-app.sh --project examples/hello-uwp --out /tmp/hello-layout \
#                [--name NAME] [--copy DIR] [--no-pri]
#
#     --copy DIR   copy the contents of DIR into the layout (repeatable). This
#                  is how precompiled third-party DLLs get into the package: a
#                  native NuGet package's runtimes/win-x64/native, say. They are
#                  already built for Windows, which is the reason for using them.
#     --no-pri     skip resources.pri, which is not needed to install
#     --name NAME  override the executable and namespace name
#     --help       this text
#
# Drives the whole chain: midlrt and cppwinrt under Wine for the metadata and the
# projection, clang-cl for the executable, makepri for the resources. The result
# is a directory `openappx pack` accepts.
#
# The project directory must hold app.idl, AppxManifest.xml, Assets/ and the
# sources. --name defaults to the manifest's Application/@Executable minus .exe,
# which is also the namespace the .idl declares.
set -euo pipefail

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

project=""
out=""
name=""
no_pri=0
copy_dirs=()
die() {
	echo "error: $*" >&2
	exit 1
}
step() { printf '\n==> %s\n' "$*"; }
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
	--project) value "$1" $# && project="$2" && shift 2 ;;
	--out) value "$1" $# && out="$2" && shift 2 ;;
	--name) value "$1" $# && name="$2" && shift 2 ;;
	--copy) value "$1" $# && copy_dirs+=("$2") && shift 2 ;;
	--no-pri) no_pri=1 && shift ;;
	*) die "unknown argument $1" ;;
	esac
done

[[ -n "$project" && -n "$out" ]] || die "--project and --out are required"
[[ -f "$project/app.idl" ]] || die "no app.idl in $project"
[[ -f "$project/AppxManifest.xml" ]] || die "no AppxManifest.xml in $project"
project="$(cd "$project" && pwd)"
# Checked now rather than after a ten-minute compile.
for dir in ${copy_dirs[@]+"${copy_dirs[@]}"}; do
	[[ -d "$dir" ]] || die "--copy: no such directory: $dir"
done

if [[ -z "$name" ]]; then
	name=$(sed -n 's/.*Executable="\([^"]*\)\.exe".*/\1/p' "$project/AppxManifest.xml" | head -1)
	[[ -n "$name" ]] || die "cannot read Executable from the manifest; pass --name"
fi

mkdir -p "$out"
out="$(cd "$out" && pwd)"
[[ "$out" != "$project" && "$out" != "$project"/* ]] ||
	die "--out must be outside --project: the layout is a build product, not a source"

# A layout is the complete contents of a package, so anything left over from an
# earlier build ships with it — a renamed executable, a winmd from a project
# that used to be called something else. Clear it, but only once it is
# recognisably a layout of ours: --out pointed somewhere unexpected should not
# delete that directory's contents.
# $name.exe counts as well as the manifest: a build that died between the link
# and the copy leaves a layout holding only the executable, and the next run
# should not need a manual rm.
if [[ -n "$(ls -A "$out")" ]]; then
	[[ -f "$out/AppxManifest.xml" || -f "$out/$name.exe" ]] ||
		die "$out is not empty and holds no AppxManifest.xml — refusing to clear it"
	find "$out" -mindepth 1 -delete
fi

# Everything generated — the projection, the objects, the ~190 MB precompiled
# header — goes in a build directory *beside* the layout, never inside it.
# Whatever is in the layout ends up in the package, and makepri indexes it: with
# the projection under $out, resources.pri came out describing App.g.h and a
# winmd that were deleted a moment later.
build="${UWP_OBJ_DIR:-$out.build}"
gen="$build/gen"
rm -rf "$gen"

step "Metadata and projection ($name.winmd)"
"$here/gen-projection.sh" --idl "$project/app.idl" --name "$name" --out "$gen" >/dev/null

step "Compiling"
# .c as well as .cpp: build.sh compiles each with the standard for its language,
# and a UWP application wrapping a C library is an ordinary shape.
sources=()
for f in "$project"/*.cpp "$project"/*.c; do [[ -f "$f" ]] && sources+=("$f"); done
[[ ${#sources[@]} -gt 0 ]] || die "no .cpp or .c files in $project"
# A project with a pch.h gets it precompiled — the difference between ~30 s and
# ~1 s per translation unit.
build_args=(--uwp --out "$out/$name.exe")
[[ -f "$project/pch.h" ]] && build_args+=(--pch "$project/pch.h")
UWP_OBJ_DIR="$build/obj" \
	"$here/build.sh" "${build_args[@]}" "${sources[@]}" -- /I"$gen" /I"$project"

step "Assembling the layout"
cp "$project/AppxManifest.xml" "$out/"
[[ -d "$project/Assets" ]] && cp -r "$project/Assets" "$out/"
# The manifest's EntryPoint is resolved against this file at activation time.
cp "$gen/$name.winmd" "$out/"
# Precompiled dependencies — a native NuGet package's DLLs — are copied, not
# built. Before makepri, because it indexes the layout as it finds it, and the
# loader looks for them beside the executable.
for dir in ${copy_dirs[@]+"${copy_dirs[@]}"}; do
	echo "  copying $(basename "$dir")/"
	cp -r "$dir/." "$out/"
done

if [[ $no_pri -eq 0 ]]; then
	step "Resources"
	"$here/gen-resources.sh" --layout "$out"
fi

step "Layout ready: $out"
ls -la "$out"
echo
echo "generated files (projection, objects, PCH) are in $build"
