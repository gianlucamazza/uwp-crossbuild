#!/usr/bin/env bash
# fetch-sdk.sh — obtain the Windows SDK pieces needed to build UWP from Linux.
#
# Downloads the SDK layout with the official web installer (run under Wine),
# extracts only the MSIs we need via administrative install, and fixes the
# filename casing so a case-sensitive filesystem can resolve the includes.
#
# Nothing here is redistributed: the SDK is fetched from Microsoft's CDN at run
# time, under its own licence. Do not commit the result.
set -euo pipefail

SDK_ROOT="${UWP_SDK_ROOT:-$HOME/.cache/uwp-crossbuild/sdk}"
WORK="${UWP_SDK_WORK:-$HOME/.cache/uwp-crossbuild/work}"
SDK_VERSION="${UWP_SDK_VERSION:-10.0.22621.0}"
SDK_INSTALLER_URL="${UWP_SDK_URL:-https://go.microsoft.com/fwlink/?linkid=2196241}"
CPPWINRT_URL="https://www.nuget.org/api/v2/package/Microsoft.Windows.CppWinRT"

# Only these four MSIs matter. The full layout is ~1.1 GB; these hold the tools,
# the platform metadata and the IDL/headers midlrt includes.
MSIS=(
	"Windows SDK for Windows Store Apps Tools-x86_en-us.msi"     # midlrt, makepri, makeappx
	"Windows SDK for Windows Store Apps Headers-x86_en-us.msi"   # winrtbase.idl and friends
	"Windows SDK for Windows Store Apps Contracts-x86_en-us.msi" # *.Contract.winmd
	"Windows SDK Facade Windows WinMD Versioned-x86_en-us.msi"   # UnionMetadata/Windows.winmd
)

die() {
	echo "error: $*" >&2
	exit 1
}
step() { printf '\n==> %s\n' "$*"; }

command -v wine >/dev/null || die "wine is required"
command -v 7z >/dev/null || die "7z (p7zip) is required"

# MAX_PATH: tools receive Windows paths, and anything past 260 characters is
# silently truncated. Keep the cache shallow and fail early if it is not.
[[ ${#SDK_ROOT} -lt 80 ]] || die "UWP_SDK_ROOT is too long (${#SDK_ROOT} chars): $SDK_ROOT"

mkdir -p "$WORK" "$SDK_ROOT"

step "Downloading the SDK web installer"
[[ -f "$WORK/sdksetup.exe" ]] ||
	curl -sSL -o "$WORK/sdksetup.exe" "$SDK_INSTALLER_URL"

step "Fetching the SDK layout (~1.1 GB, cached in $WORK/layout)"
if [[ ! -d "$WORK/layout/Installers" ]]; then
	mkdir -p "$WORK/layout"
	WINEDEBUG=-all wine "$WORK/sdksetup.exe" /quiet /layout "$(winepath -w "$WORK/layout")"
fi

step "Extracting the MSIs we need"
for msi in "${MSIS[@]}"; do
	[[ -f "$WORK/layout/Installers/$msi" ]] || die "missing from layout: $msi"
	echo "  $msi"
	WINEDEBUG=-all wine msiexec /a "$WORK/layout/Installers/$msi" /qn \
		TARGETDIR="$(winepath -w "$SDK_ROOT")" >/dev/null 2>&1 ||
		die "administrative install failed for $msi"
done

step "Adding lowercase symlinks for the includes"
# midlrt asks for winrtbase.idl; the SDK ships WinRTBase.idl. On NTFS that is the
# same file, here it is not — so alias every mixed-case name.
created=0
for dir in winrt shared um; do
	target="$SDK_ROOT/Windows Kits/10/Include/$SDK_VERSION/$dir"
	[[ -d "$target" ]] || continue
	pushd "$target" >/dev/null
	for f in *; do
		lower="${f,,}"
		if [[ "$f" != "$lower" && ! -e "$lower" ]]; then
			ln -s "$f" "$lower"
			created=$((created + 1))
		fi
	done
	popd >/dev/null
done
echo "  linked $created files"

step "Fetching cppwinrt.exe"
if [[ ! -f "$SDK_ROOT/cppwinrt/bin/cppwinrt.exe" ]]; then
	curl -sSL -o "$WORK/cppwinrt.nupkg" "$CPPWINRT_URL"
	7z x -y -o"$SDK_ROOT/cppwinrt" "$WORK/cppwinrt.nupkg" "bin/cppwinrt.exe" >/dev/null
fi

step "Checking MSXML6, which makepri needs"
if ! wine reg query 'HKCU\Software\Wine\DllOverrides' 2>/dev/null | grep -qi msxml6; then
	cat <<'EOF'
  MSXML6 is not overridden in this Wine prefix. `makepri new` will fail with
  "PRI175: Initializing Indexer / Schema Validation Failed" without it:

      winetricks -q msxml6

  Note that only the *32-bit* makepri works afterwards; the x64 build faults
  inside MSXML. scripts/wine-tool.sh already picks the right one.
EOF
fi

step "Done"
echo "SDK ready at: $SDK_ROOT"
echo "Try:  scripts/wine-tool.sh midlrt /? | head -3"
