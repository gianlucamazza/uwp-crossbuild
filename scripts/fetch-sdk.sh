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
# cppwinrt.exe writes a static_assert pinning the version of the winrt/ headers
# it expects, so its version must match the projection headers xwin installs —
# take the newest from NuGet and every build fails with "Mismatched C++/WinRT
# headers". Read the version out of the headers when they are there.
CPPWINRT_VERSION="${UWP_CPPWINRT_VERSION:-}"
CPPWINRT_FALLBACK="2.0.250303.1"
XWIN_ROOT="${UWP_XWIN_ROOT:-$HOME/.cache/uwp-crossbuild/xwin}"

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
	# msiexec under Wine is noisy when it works and the only witness when it does
	# not, so keep the output in a log rather than discarding it: without this a
	# failure here has no diagnosis at all.
	log="$WORK/msiexec-${msi// /_}.log"
	WINEDEBUG=-all wine msiexec /a "$WORK/layout/Installers/$msi" /qn \
		TARGETDIR="$(winepath -w "$SDK_ROOT")" >"$log" 2>&1 ||
		die "administrative install failed for $msi
$(tail -20 "$log")
  full log: $log"
done

# An SDK version that does not match what the installer laid down produces no
# error here — the symlink loop below just finds nothing and midlrt fails much
# later, complaining about metadata. Say it now, and say which two settings
# disagree.
[[ -d "$SDK_ROOT/Windows Kits/10/bin/$SDK_VERSION" ]] ||
	die "no SDK $SDK_VERSION under $SDK_ROOT after extraction.
  Found: $(cd "$SDK_ROOT/Windows Kits/10/bin" 2>/dev/null && echo *)
  UWP_SDK_VERSION and UWP_SDK_URL have to describe the same SDK."

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
if [[ -z "$CPPWINRT_VERSION" ]]; then
	base="$XWIN_ROOT/sdk/include/cppwinrt/winrt/base.h"
	if [[ -f "$base" ]]; then
		CPPWINRT_VERSION=$(sed -n 's/^#define CPPWINRT_VERSION "\(.*\)"/\1/p' "$base" | head -1)
	else
		# Reading the version out of the headers is the whole point, so say so
		# rather than pin a guess silently: run xwin *before* this script, or the
		# fallback below decides the version and every build can fail on the
		# static_assert instead.
		echo "  no xwin headers at $base — falling back to $CPPWINRT_FALLBACK" >&2
		echo "  run xwin splat first, or set UWP_CPPWINRT_VERSION, if that is wrong" >&2
	fi
	CPPWINRT_VERSION="${CPPWINRT_VERSION:-$CPPWINRT_FALLBACK}"
fi
echo "  version $CPPWINRT_VERSION (must match the winrt/ headers)"
if [[ ! -f "$SDK_ROOT/cppwinrt/bin/cppwinrt.exe" ]]; then
	curl -sSL -o "$WORK/cppwinrt.nupkg" \
		"https://www.nuget.org/api/v2/package/Microsoft.Windows.CppWinRT/$CPPWINRT_VERSION"
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
