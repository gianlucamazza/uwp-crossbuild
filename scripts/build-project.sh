#!/usr/bin/env bash
# build-project.sh — a Visual Studio project in, a package layout out.
#
#   build-project.sh --project uwp/app.vcxproj --out /tmp/layout \
#                    [--config Release] [--platform x64] \
#                    [--property NAME=VALUE] [--no-pri] [--no-restore]
#
#     --config     which configuration's settings to take (default: Release)
#     --platform   which platform's (x64, the default, or ARM64). This also
#                  selects the compiler target and library directories: the
#                  platform decides both which MSBuild conditions hold and what
#                  the objects are, and answering only the first would build
#                  x64 code under ARM64 settings without a word. Left at its
#                  default it yields to UWP_TARGET/UWP_ARCH_DIR from the
#                  environment; typed out, it refuses an environment that
#                  contradicts it.
#     --property   MSBuild's /p:, repeatable. A project's own switches live
#                  here — a backend selector, a SKU flag — and one of them can
#                  decide whether a ProjectReference exists at all.
#     --no-restore skip the NuGet restore, for a tree that already has one
#     --no-pri     skip resources.pri, which is not needed to install
#     --help       this text
#
# Does by itself what docs/porting-a-vcxproj.md does by hand: reads the project
# with read-vcxproj.py, restores its NuGet packages, builds every
# ProjectReference it depends on, generates the projection from its .idl,
# compiles and links, and assembles a layout `openappx pack` accepts.
#
# It refuses whatever read-vcxproj.py refuses. A build that silently differs
# from the one MSBuild produces is worse than no build.
#
# For a project in the shape of examples/hello-uwp — one directory, no .vcxproj
# — build-app.sh is the shorter road.
set -euo pipefail

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=scripts/common.sh
. "$here/common.sh"

project=""
out=""
config="Release"
platform="x64"
platform_explicit=""
properties=()
no_pri=0
no_restore=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--project) value "$1" $# "${2:-}" && project="$2" && shift 2 ;;
	--out) value "$1" $# "${2:-}" && out="$2" && shift 2 ;;
	--config) value "$1" $# "${2:-}" && config="$2" && shift 2 ;;
	--platform) value "$1" $# "${2:-}" && platform="$2" && platform_explicit=explicit && shift 2 ;;
	--property) value "$1" $# "${2:-}" && properties+=(--property "$2") && shift 2 ;;
	--no-pri) no_pri=1 && shift ;;
	--no-restore) no_restore=1 && shift ;;
	*) die "unknown argument $1" ;;
	esac
done

[[ -n "$project" && -n "$out" ]] || die "--project and --out are required"
# A directory is the likely mistake, and it has its own answer.
[[ ! -d "$project" ]] ||
	die "$project is a directory, and this takes a .vcxproj.
  For a project directory in the shape of examples/hello-uwp, use build-app.sh."
[[ -f "$project" ]] || die "no such project: $project"
[[ "$project" == *.vcxproj ]] ||
	die "not a .vcxproj: $project
  For a project directory in the shape of examples/hello-uwp, use build-app.sh."
# Physical (-P): the guards below are string comparisons, and a symlinked
# parent would slip a project past them and under prepare_layout's clearing.
project="$(cd "$(dirname "$project")" && pwd -P)/$(basename "$project")"

platform_env "$platform" $platform_explicit

read_vcxproj=("$here/read-vcxproj.py" --config "$config" --platform "$platform"
	${properties[@]+"${properties[@]}"})

# One field at a time, one value per line, so nothing here needs a JSON parser.
# Always through a command substitution, never `< <(…)`: a process
# substitution's exit status is not the pipeline's, so a refusal would arrive as
# a project with no sources rather than as a stopped build.
field() { # field <project> <dotted path>
	"${read_vcxproj[@]}" "$1" --field "$2"
}

# The winmd is named after the namespace the .idl declares, never after the
# .idl file: the manifest's EntryPoint is "<namespace>.App" and the loader
# resolves it against <namespace>.winmd. An app.idl declaring `namespace hello`
# must ship hello.winmd — named after the file, the package installs and then
# fails to launch.
idl_namespace() { # idl_namespace <idl path>
	local name
	name="$(sed -n 's/^[[:space:]]*namespace[[:space:]]\{1,\}\([A-Za-z0-9_.]\{1,\}\).*/\1/p' "$1" | head -1)"
	[[ -n "$name" ]] || die "$1 declares no namespace, so the winmd has no name"
	echo "$name"
}

# The same, into an array named by the caller, with an empty result meaning an
# empty array rather than one empty string.
read_field() { # read_field <array name> <project> <dotted path>
	local -n destination="$1"
	local text
	text="$(field "$2" "$3")" || die "cannot read $3 from $2"
	destination=()
	# shellcheck disable=SC2034  # destination is a nameref: this writes the
	# caller's array, which shellcheck cannot follow.
	[[ -z "$text" ]] || mapfile -t destination <<<"$text"
}

# readlink -m before the mkdir: a refused --out leaves no directory behind,
# and the comparisons below see physical paths. Anchored with the trailing
# slash — a plain prefix test would also refuse /tmp/app-layout beside
# /tmp/app, which contains nothing of the project's.
directory="$(dirname "$project")"
out="$(readlink -m "$out")"
[[ "$out" != "$directory" && "$out" != "$directory"/* ]] ||
	die "--out must be outside the project directory: the layout is a build
  product, and everything in it ships inside the package."
[[ "$directory" != "$out"/* ]] ||
	die "--project must not live under --out: clearing a stale layout would delete it"
mkdir -p "$out"

type="$(field "$project" type)"
[[ "$type" == "Application" ]] ||
	die "$project is a $type. Only an Application produces a package layout;
  a StaticLibrary is built as a reference of one."
# The name the manifest starts, which read-vcxproj.py has already checked
# against the one the project builds — a package whose executable is named
# something else installs and then fails to launch.
executable="$(field "$project" executable)"

# /MD through the store CRT means the loader will want the Microsoft.VCLibs
# framework at launch. Checked now rather than after a ten-minute compile, and
# refused rather than repaired: the manifest is the project's, and nothing here
# rewrites it. The check matters because nothing later gives it: the Device
# Portal registers a package with unmet dependencies without complaint, and the
# loader then fails the launch as 0x80070002, naming nothing.
store_crt="$(field "$project" store_crt)" || die "cannot read store_crt from $project"
if [[ "$store_crt" == "true" ]]; then
	manifest="$(field "$project" manifest)" || die "cannot read manifest from $project"
	[[ -n "$manifest" ]] || die "$project declares no AppxManifest"
	python3 - "$(dirname "$project")/$manifest" <<'PYEOF' ||
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except (ET.ParseError, OSError) as error:
    sys.exit(f"{sys.argv[1]}: not readable as XML: {error}")
sys.exit(
    0
    if any(
        element.tag.split("}")[-1] == "PackageDependency"
        and element.get("Name") == "Microsoft.VCLibs.140.00"
        for element in root.iter()
    )
    else 1
)
PYEOF
		die "the executable will import VCRUNTIME140_APP.dll, which the
  Microsoft.VCLibs.140.00 framework provides, and $manifest does not declare
  it. Add, inside <Dependencies>:
    <PackageDependency Name=\"Microsoft.VCLibs.140.00\" MinVersion=\"14.0.0.0\"
        Publisher=\"CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US\" />
  The framework must also be installed on the device: the Device Portal
  registers a package with unmet dependencies without complaint, and the
  loader then fails the launch as 0x80070002."
fi

prepare_layout "$out" "$executable"

build="${UWP_OBJ_DIR:-$out.build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"

# --------------------------------------------------------------------------
# Every project, references first. A .lib is built once however many projects
# name it, and the recursion is depth-first because a reference has to exist
# before whatever links it.
# --------------------------------------------------------------------------
declare -A built=()

build_project() { # build_project <project> <output path> <static|application>
	local vcxproj="$1" output="$2" kind="$3"
	local directory
	directory="$(dirname "$vcxproj")"

	local type
	type="$(field "$vcxproj" type)"
	if [[ "$kind" == "static" && "$type" != "StaticLibrary" ]]; then
		die "$vcxproj is a $type, referenced where a StaticLibrary is expected"
	fi

	# NuGet first: until the packages are there the project's <Import> lines
	# resolve to nothing and its include directories point at absent
	# directories. Every field below is read after this, and read afresh, so
	# what the restore makes resolvable is what gets used.
	#
	# Unconditionally when the project declares packages, not only when
	# packages/ is absent: a directory holding three of four packages is the
	# case a "does it exist" test gets wrong, and restore-nuget.sh skips the
	# ones already there.
	if [[ $no_restore -eq 0 ]]; then
		local packages
		packages="$(field "$vcxproj" packages)"
		if [[ -n "$packages" ]]; then
			step "NuGet packages for $(basename "$vcxproj")"
			"$here/restore-nuget.sh" --project "$vcxproj"
		fi
	fi

	local -a references libs=()
	read_field references "$vcxproj" references
	local reference resolved lib
	for reference in ${references[@]+"${references[@]}"}; do
		[[ -f "$directory/$reference" ]] ||
			die "$(basename "$vcxproj") references $reference, which is not there"
		resolved="$(cd "$directory" && cd "$(dirname "$reference")" && pwd)/$(basename "$reference")"
		lib="$build/$(basename "${resolved%.vcxproj}").lib"
		# A cycle would otherwise recurse until the stack gives out. Marked
		# before descending, so the second visit is the one that notices.
		if [[ "${built[$resolved]:-}" == "building" ]]; then
			die "circular ProjectReference: $(basename "$vcxproj") and
  $(basename "$resolved") each need the other built first"
		fi
		if [[ -z "${built[$resolved]:-}" ]]; then
			built[$resolved]=building
			step "Reference: $(basename "$resolved")"
			build_project "$resolved" "$lib" static
			built[$resolved]=built
		fi
		libs+=("$lib")
	done

	local -a sources=() listed
	local source
	read_field listed "$vcxproj" sources.cpp
	for source in ${listed[@]+"${listed[@]}"}; do sources+=("$directory/$source"); done
	read_field listed "$vcxproj" sources.c
	for source in ${listed[@]+"${listed[@]}"}; do sources+=("$directory/$source"); done
	[[ ${#sources[@]} -gt 0 ]] || die "$vcxproj lists no sources"

	# build.sh takes its own flags before the sources and the compiler's after a
	# `--`, which consumes everything left. Two arrays, so nothing can end up on
	# the wrong side of it.
	local -a arguments=(--out "$output") passthrough=()
	local entry
	read_field listed "$vcxproj" includes
	for entry in ${listed[@]+"${listed[@]}"}; do arguments+=(-I "$directory/$entry"); done
	read_field listed "$vcxproj" defines
	for entry in ${listed[@]+"${listed[@]}"}; do passthrough+=("/D$entry"); done
	read_field listed "$vcxproj" options
	for entry in ${listed[@]+"${listed[@]}"}; do passthrough+=("$entry"); done

	local pch
	pch="$(field "$vcxproj" pch)" || die "cannot read pch from $vcxproj"
	[[ -z "$pch" ]] || arguments+=(--pch "$directory/$pch")

	if [[ "$kind" == "static" ]]; then
		arguments+=(--static-lib)
		# VS UWP StaticLibrary projects set AppContainerApplication=true and
		# compile under WINAPI_FAMILY=APP. Without --uwp here the archive is
		# built as desktop and the linking app inherits forbidden imports
		# (RegOpenKeyEx / SetThreadAffinityMask → 0x8027025b). Gotcha 22.
		local is_container
		is_container="$(field "$vcxproj" app_container)" ||
			die "cannot read app_container from $vcxproj"
		[[ "$is_container" != "true" ]] || arguments+=(--uwp)
	else
		arguments+=(--uwp)
		# read afresh for this project, like every field: only an application
		# links a CRT, so a static reference never carries the flag.
		local wants_store_crt
		wants_store_crt="$(field "$vcxproj" store_crt)" ||
			die "cannot read store_crt from $vcxproj"
		[[ "$wants_store_crt" != "true" ]] || arguments+=(--store-crt)
		# The projection comes from the project's own .idl: the sources that
		# implement the application class do not compile without the generated
		# headers, and the winmd has to ship inside the package.
		local idl namespace
		idl="$(field "$vcxproj" idl)" || die "cannot read idl from $vcxproj"
		if [[ -n "$idl" ]]; then
			namespace="$(idl_namespace "$directory/$idl")"
			step "Metadata and projection ($namespace.winmd)"
			"$here/gen-projection.sh" --idl "$directory/$idl" \
				--name "$namespace" --out "$build/gen" >/dev/null
			arguments+=(-I "$build/gen")
		fi
		read_field listed "$vcxproj" link.libpath
		for entry in ${listed[@]+"${listed[@]}"}; do
			arguments+=(--link-arg "/libpath:$directory/$entry")
		done
		read_field listed "$vcxproj" link.libs
		for entry in ${listed[@]+"${listed[@]}"}; do
			arguments+=(--link-arg "$entry")
		done
		for lib in ${libs[@]+"${libs[@]}"}; do
			arguments+=(--link-arg "$lib")
		done
	fi

	step "Compiling $(basename "$vcxproj") (${#sources[@]} sources)"
	local cxx_std c_std
	cxx_std="$(field "$vcxproj" std.cxx)" || die "cannot read std.cxx from $vcxproj"
	c_std="$(field "$vcxproj" std.c)" || die "cannot read std.c from $vcxproj"
	UWP_OBJ_DIR="$build/obj/$(basename "${vcxproj%.vcxproj}")" \
	UWP_CXX_STD="${cxx_std:-c++20}" \
	UWP_C_STD="${c_std:-c17}" \
		"$here/build.sh" "${arguments[@]}" "${sources[@]}" \
		-- ${passthrough[@]+"${passthrough[@]}"}
}

# --------------------------------------------------------------------------

build_project "$project" "$out/$executable" application

step "Assembling the layout"
directory="$(dirname "$project")"
manifest="$(field "$project" manifest)"
[[ -n "$manifest" ]] || die "$project declares no AppxManifest"
cp "$directory/$manifest" "$out/AppxManifest.xml"

# The manifest's EntryPoint is resolved against the winmd at activation time, so
# it ships inside the package.
idl="$(field "$project" idl)"
if [[ -n "$idl" ]]; then
	cp "$build/gen/$(idl_namespace "$directory/$idl").winmd" "$out/"
fi

# Everything the project marks for deployment, at the name it has to have inside
# the package — TargetPath is how a DLL from a NuGet package's
# runtimes/win-x64/native ends up beside the executable. Before makepri, which
# indexes the layout as it finds it.
deployed=()
read_field deployed "$project" deploy
for entry in ${deployed[@]+"${deployed[@]}"}; do
	source="${entry%%$'\t'*}"
	target="${entry##*$'\t'}"
	[[ -f "$directory/$source" ]] ||
		die "declared for deployment but not there: $source
  A payload from a NuGet package needs a restore; run without --no-restore."
	mkdir -p "$out/$(dirname "$target")"
	cp "$directory/$source" "$out/$target"
done

if [[ $no_pri -eq 0 ]]; then
	step "Resources"
	"$here/gen-resources.sh" --layout "$out"
fi

step "Layout ready: $out"
ls -la "$out"
echo
echo "generated files (projection, objects, PCH) are in $build"
