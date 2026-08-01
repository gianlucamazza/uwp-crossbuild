#!/usr/bin/env bash
# build-app.sh — an example directory in, a package layout out.
#
#   build-app.sh --project examples/hello-uwp --out /tmp/hello-layout
#                [--name NAME] [--jobs N] [--language TAG] [--no-pri]
#
# Drives the whole chain: midlrt and cppwinrt under Wine for the metadata and the
# projection, clang-cl for the executable, makepri for the resources. The result
# is a directory `openappx pack` accepts.
#
# The project directory must hold app.idl, AppxManifest.xml, Assets/ and the
# sources. --name defaults to the manifest's Application/@Executable minus .exe,
# which is also the namespace the .idl declares. --jobs and --language pass
# through to build.sh and gen-resources.sh, which own their defaults (nproc and
# en-US); --no-pri skips makepri entirely.
set -euo pipefail

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

project=""
out=""
name=""
no_pri=0
language=""
jobs=""
die() {
	echo "error: $*" >&2
	exit 1
}
step() { printf '\n==> %s\n' "$*"; }
# A flag whose value is missing would otherwise fail on an unbound $2 under
# `set -u`, naming the shell rather than the argument. A value that is itself
# a flag — `--out --uwp` — would be taken literally, and the real failure
# deferred to whatever is downstream of the misread pair.
value() { # value <flag> <argc> [value]
	[[ $2 -ge 2 ]] || die "$1 needs a value"
	[[ "${3:-}" != --* ]] || die "$1 needs a value, not another flag: $3"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--project) value "$1" $# "${2:-}" && project="$2" && shift 2 ;;
	--out) value "$1" $# "${2:-}" && out="$2" && shift 2 ;;
	--name) value "$1" $# "${2:-}" && name="$2" && shift 2 ;;
	--jobs) value "$1" $# "${2:-}" && jobs="$2" && shift 2 ;;
	--language) value "$1" $# "${2:-}" && language="$2" && shift 2 ;;
	--no-pri) no_pri=1 && shift ;;
	*) die "unknown argument $1" ;;
	esac
done

[[ -n "$project" && -n "$out" ]] || die "--project and --out are required"
[[ -f "$project/app.idl" ]] || die "no app.idl in $project"
[[ -f "$project/AppxManifest.xml" ]] || die "no AppxManifest.xml in $project"
project="$(cd "$project" && pwd -P)"

if [[ -z "$name" ]]; then
	name=$(sed -n 's/.*Executable="\([^"]*\)\.exe".*/\1/p' "$project/AppxManifest.xml" | head -1)
	[[ -n "$name" ]] || die "cannot read Executable from the manifest; pass --name"
fi

# Physical paths (pwd -P above, readlink -m here): the guards below are string
# comparisons, and a symlinked parent in either argument would slip a project
# past them and under the recursive clearing further down. Checked before the
# mkdir, so a refused --out leaves no directory behind either.
out="$(readlink -m "$out")"
[[ "$out" != "$project" && "$out" != "$project"/* ]] ||
	die "--out must be outside --project: the layout is a build product, not a source"
# The reverse as well: clearing a stale layout below is recursive, so a project
# living under --out would be deleted with it, sources and all.
[[ "$project" != "$out"/* ]] ||
	die "--project must not live under --out: clearing a stale layout would delete it"
mkdir -p "$out"

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
sources=()
for f in "$project"/*.cpp; do [[ -f "$f" ]] && sources+=("$f"); done
[[ ${#sources[@]} -gt 0 ]] || die "no .cpp files in $project"
# A project with a pch.h gets it precompiled — the difference between ~30 s and
# ~1 s per translation unit.
build_args=(--uwp --out "$out/$name.exe")
[[ -f "$project/pch.h" ]] && build_args+=(--pch "$project/pch.h")
[[ -n "$jobs" ]] && build_args+=(--jobs "$jobs")
UWP_OBJ_DIR="$build/obj" \
	"$here/build.sh" "${build_args[@]}" "${sources[@]}" -- /I"$gen" /I"$project"

step "Assembling the layout"
cp "$project/AppxManifest.xml" "$out/"
[[ -d "$project/Assets" ]] && cp -r "$project/Assets" "$out/"
# The manifest's EntryPoint is resolved against this file at activation time.
cp "$gen/$name.winmd" "$out/"

if [[ $no_pri -eq 0 ]]; then
	step "Resources"
	pri_args=(--layout "$out")
	[[ -n "$language" ]] && pri_args+=(--language "$language")
	"$here/gen-resources.sh" "${pri_args[@]}"
fi

step "Layout ready: $out"
ls -la "$out"
echo
echo "generated files (projection, objects, PCH) are in $build"
