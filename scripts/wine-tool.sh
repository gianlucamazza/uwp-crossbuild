#!/usr/bin/env bash
# wine-tool.sh — run a Windows SDK tool from Linux, with the workarounds it needs.
#
#   wine-tool.sh midlrt  <args...>     generate a .winmd from an .idl
#   wine-tool.sh makepri <args...>     generate resources.pri
#   wine-tool.sh cppwinrt <args...>    generate C++/WinRT projection headers
#
# Every non-obvious flag below was established empirically; see README.md for the
# failure each one avoids.
set -euo pipefail

SDK_ROOT="${UWP_SDK_ROOT:-$HOME/.cache/uwp-crossbuild/sdk}"
SDK_VERSION="${UWP_SDK_VERSION:-10.0.22621.0}"

KITS="$SDK_ROOT/Windows Kits/10"
BIN_X64="$KITS/bin/$SDK_VERSION/x64"
BIN_X86="$KITS/bin/$SDK_VERSION/x86"
INCLUDE="$KITS/Include/$SDK_VERSION"
REFERENCES="$KITS/References/$SDK_VERSION"
UNION="$KITS/UnionMetadata/$SDK_VERSION"

die() {
	echo "error: $*" >&2
	exit 1
}

# The comment block at the top of this file is the usage text. Printing it back
# means there is one description of the tools, not two that drift apart.
usage() {
	awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' \
		"$(readlink -f "${BASH_SOURCE[0]}")"
	exit 0
}

tool="${1:-}"
shift || true
# Check the tool name before the SDK: a typo should not send anyone off to
# download 1.1 GB before finding out.
case "$tool" in
midlrt | makepri | cppwinrt) ;;
-h | --help) usage ;;
*) die "usage: $0 <midlrt|makepri|cppwinrt> [args...]" ;;
esac

[[ -d "$KITS" ]] || die "SDK not found at $SDK_ROOT — run scripts/fetch-sdk.sh first"
command -v wine >/dev/null || die "wine is not installed"

# Wine reports MAX_PATH truncation as a silently mangled argument: a .winmd path
# over 260 characters arrives as "....w?" and midlrt rejects it as "not a winmd".
check_path_length() {
	local p="$1"
	[[ ${#p} -lt 240 ]] || die "path too long for Windows MAX_PATH (${#p} chars): $p
  Work from a short directory, e.g. /tmp/build, or symlink one."
}

win() { winepath -w "$1"; }

# A missing tool otherwise surfaces as whatever Wine says about an executable it
# cannot find, which names neither the SDK version nor the script that installs
# it. $KITS existing is not enough: the tools live under a version directory, and
# UWP_SDK_VERSION can disagree with what was actually extracted.
need_tool() { # need_tool <path>
	[[ -f "$1" ]] || die "not found: $1
  Run scripts/fetch-sdk.sh, or set UWP_SDK_VERSION to the SDK you have
  (present: $(cd "$KITS/bin" 2>/dev/null && echo *))."
}

run_midlrt() {
	need_tool "$BIN_X64/midlrt.exe"
	check_path_length "$UNION"
	local args=(
		/winrt /nomidl
		# midlrt shells out to cl.exe unless preprocessing is off; the IDL of a
		# typical UWP app has no preprocessor directives, so this is safe.
		/no_cpp
		/metadata_dir "$(win "$UNION")"
		/I "$(win "$INCLUDE/winrt")"
		/I "$(win "$INCLUDE/shared")"
		/I "$(win "$INCLUDE/um")"
	)
	local f
	for f in "$REFERENCES"/Windows.Foundation.FoundationContract/*/*.winmd \
		"$REFERENCES"/Windows.Foundation.UniversalApiContract/*/*.winmd; do
		[[ -f "$f" ]] && args+=(/reference "$(win "$f")")
	done
	WINEDEBUG="${WINEDEBUG:--all}" exec wine "$BIN_X64/midlrt.exe" "${args[@]}" "$@"
}

run_makepri() {
	# The x64 build faults inside MSXML6 under Wine; the x86 build works with the
	# 32-bit msxml6 winetricks installs. Same output either way.
	need_tool "$BIN_X86/makepri.exe"
	WINEDEBUG="${WINEDEBUG:--all}" exec wine "$BIN_X86/makepri.exe" "$@"
}

run_cppwinrt() {
	local exe="${CPPWINRT_EXE:-$SDK_ROOT/cppwinrt/bin/cppwinrt.exe}"
	[[ -f "$exe" ]] || die "cppwinrt.exe not found at $exe — run fetch-sdk.sh"
	WINEDEBUG="${WINEDEBUG:--all}" exec wine "$exe" "$@"
}

case "$tool" in
midlrt) run_midlrt "$@" ;;
makepri) run_makepri "$@" ;;
cppwinrt) run_cppwinrt "$@" ;;
esac
