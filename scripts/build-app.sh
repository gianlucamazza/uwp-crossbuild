#!/usr/bin/env bash
# build-app.sh — an example directory in, a package layout out.
#
#   build-app.sh --project examples/hello-uwp --out /tmp/hello-layout \
#                [--platform x64|ARM64] [--name NAME] [--copy DIR] [--jobs N] \
#                [--language TAG] [--no-pri]
#
#     --platform   what to compile for (default x64). Sets UWP_TARGET and
#                  UWP_ARCH_DIR. Left at its default it yields to those
#                  variables from the environment; typed out, it refuses an
#                  environment that contradicts it.
#     --copy DIR   copy the contents of DIR into the layout (repeatable). This
#                  is how precompiled third-party DLLs get into the package: a
#                  native NuGet package's runtimes/win-x64/native — or its
#                  win-arm64 sibling — say. They are already built for Windows,
#                  which is the reason for using them.
#     --no-pri     skip resources.pri, which is not needed to install
#     --name NAME  override the executable and namespace name
#     --jobs N     passed through to build.sh, which owns the default (nproc)
#     --language   passed through to gen-resources.sh (default there: en-US); a
#                  manifest declaring another resource language otherwise gets
#                  an en-US pri without a word
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

# shellcheck source=scripts/common.sh
. "$here/common.sh"

project=""
out=""
name=""
no_pri=0
copy_dirs=()
language=""
jobs=""
platform="x64"
platform_explicit=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--project) value "$1" $# "${2:-}" && project="$2" && shift 2 ;;
	--platform) value "$1" $# "${2:-}" && platform="$2" && platform_explicit=explicit && shift 2 ;;
	--out) value "$1" $# "${2:-}" && out="$2" && shift 2 ;;
	--name) value "$1" $# "${2:-}" && name="$2" && shift 2 ;;
	--copy) value "$1" $# "${2:-}" && copy_dirs+=("$2") && shift 2 ;;
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
# Checked now rather than after a ten-minute compile.
for dir in ${copy_dirs[@]+"${copy_dirs[@]}"}; do
	[[ -d "$dir" ]] || die "--copy: no such directory: $dir"
done

platform_env "$platform" $platform_explicit

# The manifest is copied into the layout verbatim, so its architecture has to
# agree with what is actually compiled — same refusal read-vcxproj.py makes for
# a .vcxproj, mirrored here for a project directory. Compared against the
# effective UWP_TARGET, not --platform: a defaulted --platform yields to the
# environment, and it is the target that names the executable's architecture.
# A third architecture has no row to compare against, so nothing is checked.
# neutral and absent stay legal. Parsed as XML, not grepped: a single-quoted
# attribute or a multi-line <Identity> would slip past a pattern and ship a
# mismatched package.
case "$UWP_TARGET" in
x86_64-*) expected="x64" ;;
aarch64-*) expected="arm64" ;;
*) expected="" ;;
esac
declared=$(
	python3 - "$project/AppxManifest.xml" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except ET.ParseError as error:
    sys.exit(f"AppxManifest.xml is not well-formed XML: {error}")
identity = root.find("{*}Identity")
print(identity.get("ProcessorArchitecture", "") if identity is not None else "")
PYEOF
) || die "cannot read $project/AppxManifest.xml"
if [[ -n "$expected" && -n "$declared" && "${declared,,}" != neutral && "${declared,,}" != "$expected" ]]; then
	die "AppxManifest.xml declares ProcessorArchitecture=\"$declared\", and this
  is an $expected build. Set the manifest's Identity/@ProcessorArchitecture to
  \"$expected\", or build with the platform the manifest names."
fi

if [[ -z "$name" ]]; then
	name=$(sed -n 's/.*Executable="\([^"]*\)\.exe".*/\1/p' "$project/AppxManifest.xml" | head -1)
	[[ -n "$name" ]] || die "cannot read Executable from the manifest; pass --name"
fi

# Physical paths (pwd -P above, readlink -m here): the guards are string
# comparisons, and a symlinked parent in either argument would slip a project
# past them and under prepare_layout's recursive clearing. Checked before the
# mkdir, so a refused --out leaves no directory behind either.
out="$(readlink -m "$out")"
[[ "$out" != "$project" && "$out" != "$project"/* ]] ||
	die "--out must be outside --project: the layout is a build product, not a source"
# The reverse as well: clearing a stale layout is recursive, so a project
# living under --out would be deleted with it, sources and all.
[[ "$project" != "$out"/* ]] ||
	die "--project must not live under --out: clearing a stale layout would delete it"
mkdir -p "$out"

prepare_layout "$out" "$name.exe"

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
[[ -n "$jobs" ]] && build_args+=(--jobs "$jobs")
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
	pri_args=(--layout "$out")
	[[ -n "$language" ]] && pri_args+=(--language "$language")
	"$here/gen-resources.sh" "${pri_args[@]}"
fi

step "Layout ready: $out"
ls -la "$out"
echo
echo "generated files (projection, objects, PCH) are in $build"
