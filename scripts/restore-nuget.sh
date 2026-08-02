#!/usr/bin/env bash
# restore-nuget.sh — put a project's NuGet packages where its .vcxproj expects.
#
#   restore-nuget.sh --project uwp/app.vcxproj [--packages DIR]
#   restore-nuget.sh --config packages.config  [--packages DIR]
#
#     --project    read the package list from the project: its packages.config
#                  if there is one, and any PackageReference items
#     --config     read it from a packages.config directly
#     --packages   where they go (default: packages/ beside the project, which
#                  is where Visual Studio puts them and where the .vcxproj's
#                  <Import> lines look)
#     --help       this text
#
# A native NuGet package is an ordinary zip. What a project needs from it is the
# .props file it imports, the headers under build/native/include and the DLLs
# under runtimes/win-x64/native — none of which exist on a machine that has
# never run Visual Studio, which is why read-vcxproj.py sees a project's include
# paths pointing at nothing until this has run.
#
# Nothing is redistributed: the packages come from nuget.org at run time under
# their own licences, into a directory this repository never touches.
set -euo pipefail

FEED="${UWP_NUGET_FEED:-https://www.nuget.org/api/v2/package}"

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=scripts/common.sh
. "$here/common.sh"

project=""
config=""
packages=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--project) value "$1" $# && project="$2" && shift 2 ;;
	--config) value "$1" $# && config="$2" && shift 2 ;;
	--packages) value "$1" $# && packages="$2" && shift 2 ;;
	*) die "unknown argument $1" ;;
	esac
done

[[ -n "$project" || -n "$config" ]] || die "--project or --config is required"
[[ -z "$project" || -z "$config" ]] || die "--project and --config are exclusive"
command -v curl >/dev/null || die "curl is required"
command -v 7z >/dev/null || die "7z (p7zip) is required"

# The package list. From the project it comes through read-vcxproj.py, which
# already knows both places a project can declare one; from a packages.config it
# is read here, because that file is the whole input.
#
# Read through a command substitution rather than `mapfile < <(…)`: a process
# substitution's exit status is not the pipeline's, so a reader that failed
# would look like a project with no packages.
declared=""
if [[ -n "$project" ]]; then
	[[ -f "$project" ]] || die "no such project: $project"
	project="$(cd "$(dirname "$project")" && pwd)/$(basename "$project")"
	packages="${packages:-$(dirname "$project")/packages}"
	declared="$("$here/read-vcxproj.py" "$project" --field packages)" ||
		die "cannot read the package list from $project"
else
	[[ -f "$config" ]] || die "no such packages.config: $config"
	config="$(cd "$(dirname "$config")" && pwd)/$(basename "$config")"
	packages="${packages:-$(dirname "$config")/packages}"
	declared="$(
		python3 - "$config" <<'PY'
import sys, xml.etree.ElementTree as ET

try:
    root = ET.parse(sys.argv[1]).getroot()
except ET.ParseError as error:
    sys.exit(f"error: {sys.argv[1]}: not readable as XML: {error}")
for package in root:
    identifier, version = package.get("id"), package.get("version")
    if not identifier or not version:
        sys.exit(f"error: {sys.argv[1]}: a <package> without an id and a version")
    print(f"{identifier}\t{version}")
PY
	)" || die "cannot read $config"
fi

list=()
[[ -z "$declared" ]] || mapfile -t list <<<"$declared"
[[ ${#list[@]} -gt 0 ]] || {
	echo "no packages declared — nothing to restore"
	exit 0
}

mkdir -p "$packages"
packages="$(cd "$packages" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

step "Restoring ${#list[@]} package(s) into $packages"
for entry in "${list[@]}"; do
	identifier="${entry%%$'\t'*}"
	version="${entry##*$'\t'}"
	[[ -n "$identifier" && -n "$version" && "$identifier" != "$version" ]] ||
		die "a package without both an id and a version: $entry"
	# The directory Visual Studio would create, which is the one the project's
	# <Import> lines name.
	target="$packages/$identifier.$version"
	if [[ -d "$target" ]]; then
		echo "  $identifier $version (already there)"
		continue
	fi
	echo "  $identifier $version"
	fetch "$FEED/$identifier/$version" "$work/$identifier.nupkg"
	# Into a temporary directory first: an interrupted extraction otherwise
	# leaves a package directory that looks restored and is not.
	rm -rf "$work/out"
	7z x -y -o"$work/out" "$work/$identifier.nupkg" >/dev/null ||
		die "$identifier $version does not unpack as a zip — is that a real version?"
	mv "$work/out" "$target"
done

step "Done"
echo "packages restored in $packages"
