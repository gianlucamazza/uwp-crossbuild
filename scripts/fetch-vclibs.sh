#!/usr/bin/env bash
# fetch-vclibs.sh — turn Microsoft's VCLibs framework package into the store
# CRT import libraries that let /MD work inside an app container.
#
#   fetch-vclibs.sh --appx FILE [--platform x64|ARM64]
#   fetch-vclibs.sh --url URL --accept-license [--platform x64|ARM64]
#
#     --appx FILE       import a Microsoft.VCLibs.<arch>.14.00.appx you already
#                       have. Visual Studio's UWP workload installs one under
#                       Microsoft SDKs\Windows Kits\10\ExtensionSDKs\
#                       Microsoft.VCLibs\14.0\Appx\Retail\<arch>\, and a
#                       VS-built package carries one in its Dependencies
#                       folder. This is the proven route.
#     --url URL         download the appx instead (UWP_VCLIBS_URL works too).
#                       There is no default: Microsoft publishes no stable
#                       public link for the store framework, and a guessed one
#                       would fail as a 404 saved to the cache.
#     --accept-license  required with --url, and checked before any network
#                       access: the appx is Microsoft's, under Microsoft's
#                       terms, fetched at run time and never redistributed.
#                       UWP_VCLIBS_ACCEPT_LICENSE=1 says the same thing.
#     --platform        which architecture's libraries (x64, the default, or
#                       ARM64) — the platform table in common.sh.
#     --help            this text
#
# What it does: extracts the *_app.dll set (VCRUNTIME140_APP.dll and friends),
# reads each DLL's export table with llvm-readobj, writes a .def, and generates
# an import library with llvm-dlltool — the libraries modern MSVC no longer
# ships and xwin therefore cannot carry. read-vcxproj.py honours /MD inside an
# app container only when they are here; build.sh --store-crt links them.
#
# The cache, under UWP_VCLIBS_ROOT (default ~/.cache/uwp-crossbuild/vclibs):
#   appx/  the package as obtained     dll/<arch>/  the extracted DLLs
#   lib/<arch>/  the .def and .lib set the toolchain consumes
# Regenerate by deleting lib/<arch>; nothing here is committed or cached in CI.
set -euo pipefail

# Resolve through symlinks: these scripts locate their siblings relative to
# themselves, so a symlink on PATH must point back at the real directory.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=scripts/common.sh
. "$here/common.sh"

appx=""
url="${UWP_VCLIBS_URL:-}"
accept="${UWP_VCLIBS_ACCEPT_LICENSE:-0}"
platform="x64"
platform_explicit=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--appx) value "$1" $# "${2:-}" && appx="$2" && shift 2 ;;
	--url) value "$1" $# "${2:-}" && url="$2" && shift 2 ;;
	--accept-license) accept=1 && shift ;;
	--platform) value "$1" $# "${2:-}" && platform="$2" && platform_explicit=explicit && shift 2 ;;
	*) die "unknown argument $1" ;;
	esac
done

platform_env "$platform" $platform_explicit

[[ -n "$appx" || -n "$url" ]] ||
	die "either --appx FILE or --url URL is required: Microsoft publishes no
  stable public link for the store framework, so this cannot pick one for you.
  Visual Studio's UWP workload installs the appx under Microsoft SDKs\\Windows
  Kits\\10\\ExtensionSDKs\\Microsoft.VCLibs\\14.0\\Appx\\Retail\\<arch>\\, and
  a VS-built package carries one in its Dependencies folder."
[[ -z "$appx" || -z "$url" ]] || die "--appx and --url are exclusive: one source, not two"

# The consent gate comes before the tool checks: what may be downloaded is
# answerable on any machine, and it is the question that matters most.
if [[ -n "$url" && "$accept" != 1 ]]; then
	die "downloading the VCLibs appx needs explicit licence acceptance.
  The package is Microsoft's, under Microsoft's terms — fetched at run time,
  never redistributed. Pass --accept-license (or UWP_VCLIBS_ACCEPT_LICENSE=1)
  to proceed with:
    $url"
fi

command -v 7z >/dev/null || die "7z (p7zip) is required"
command -v llvm-readobj >/dev/null ||
	die "llvm-readobj not found — it ships with LLVM, beside clang-cl"
command -v llvm-dlltool >/dev/null ||
	die "llvm-dlltool not found — it ships with LLVM, beside clang-cl"
[[ -z "$url" ]] || command -v curl >/dev/null || die "curl is required"

mkdir -p "$UWP_VCLIBS_ROOT/appx"

step "Obtaining the appx"
cached="$UWP_VCLIBS_ROOT/appx/Microsoft.VCLibs.$platform.14.00.appx"
if [[ -n "$appx" ]]; then
	[[ -f "$appx" ]] || die "no such file: $appx"
	cp -f "$appx" "$cached"
else
	[[ -f "$cached" ]] || fetch "$url" "$cached"
fi
echo "  $cached"

step "Checking the appx describes a $platform package"
# The appx names its own architecture; a Desktop-variant package, or one for
# the other platform, would generate libraries that link and then fail on the
# device. Parsed as XML — the manifest is Microsoft's, but quoting styles are
# not a contract.
declared=$(7z x -so "$cached" AppxManifest.xml 2>/dev/null | python3 -c '
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.fromstring(sys.stdin.buffer.read())
except ET.ParseError as error:
    sys.exit(f"AppxManifest.xml in the appx is not well-formed XML: {error}")
identity = root.find("{*}Identity")
print(identity.get("ProcessorArchitecture", "") if identity is not None else "")
') || die "cannot read AppxManifest.xml out of $cached"
expected="${platform,,}"
[[ "${declared,,}" == "$expected" ]] ||
	die "the appx declares ProcessorArchitecture=\"$declared\", and this run is
  generating $platform libraries. Pass the $platform package, or --platform
  the one this appx names."

step "Extracting the *_app.dll set"
dlldir="$UWP_VCLIBS_ROOT/dll/$UWP_ARCH_DIR"
mkdir -p "$dlldir"
7z e -y -o"$dlldir" "$cached" "*_app.dll" >/dev/null ||
	die "extracting *_app.dll from $cached failed"
dlls=("$dlldir"/*_app.dll)
[[ -f "${dlls[0]}" ]] ||
	die "no *_app.dll in $cached — is this the store framework package?
  The Desktop variant (Microsoft.VCLibs.*.Desktop.appx) carries the desktop
  DLLs instead, and those do not resolve inside an app container."
printf '  %s\n' "${dlls[@]##*/}"

step "Generating import libraries"
# The same third-architecture procedure as build.sh's dlltool machine case:
# a new platform is one row in platform_env plus this case and that one.
case "$UWP_ARCH_DIR" in
aarch64) machine=arm64 ;;
*) machine=i386:x86-64 ;;
esac
# Built under a temporary name and renamed on success: read-vcxproj.py decides
# /MD by the presence of these files, and an interrupted run must not leave a
# directory that looks complete. Regenerate by deleting lib/<arch>.
libdir="$UWP_VCLIBS_ROOT/lib/$UWP_ARCH_DIR"
if [[ -d "$libdir" ]]; then
	echo "  already generated — delete $libdir to regenerate"
else
	rm -rf "$libdir.part"
	mkdir -p "$libdir.part"
	for dll in "${dlls[@]}"; do
		base="$(basename "$dll" .dll)"
		def="$libdir.part/$base.def"
		lib="$libdir.part/$base.lib"
		# llvm-readobj prints one two-space-indented "Name: symbol" line per
		# Export block (verified with LLVM 22.1.8); the file header lines have
		# no indent, so requiring it keeps only the exports.
		{
			echo "LIBRARY $base.dll"
			echo "EXPORTS"
			llvm-readobj --coff-exports "$dll" |
				sed -n 's/^  Name: \(.*\)/  \1/p'
		} >"$def"
		[[ $(wc -l <"$def") -gt 2 ]] ||
			die "no exports read from $dll — llvm-readobj's output format may
  have changed; the sed above matched LLVM 22.1.8"
		llvm-dlltool -m "$machine" -d "$def" -l "$lib"
		echo "  $base.lib"
	done
	mv "$libdir.part" "$libdir"
fi

step "Done"
echo "Store CRT import libraries at: $libdir"
echo "A /MD project now links against them: see build.sh --store-crt"
