#!/usr/bin/env bash
# build.sh — compile C++/WinRT sources into a Windows PE, from Linux.
#
#   build.sh --out app.exe src/*.cpp [-- extra clang-cl args]
#
# Wraps clang-cl and lld-link with the include and library paths xwin produces,
# plus the three settings a C++/WinRT build cannot do without. See README.md.
set -euo pipefail

XWIN_ROOT="${UWP_XWIN_ROOT:-$HOME/.cache/uwp-crossbuild/xwin}"
TARGET="${UWP_TARGET:-x86_64-pc-windows-msvc}"
ARCH_DIR="${UWP_ARCH_DIR:-x86_64}"
STD="${UWP_CXX_STD:-c++20}"

out=""
sources=()
extra=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--out)
		out="$2"
		shift 2
		;;
	--)
		shift
		extra=("$@")
		break
		;;
	*)
		sources+=("$1")
		shift
		;;
	esac
done

die() {
	echo "error: $*" >&2
	exit 1
}
[[ -n "$out" ]] || die "--out is required"
[[ ${#sources[@]} -gt 0 ]] || die "no source files given"
[[ -d "$XWIN_ROOT/crt/include" ]] || die "no CRT at $XWIN_ROOT — run fetch-sdk.sh"
command -v clang-cl >/dev/null || die "clang-cl not found"

includes=(
	/imsvc "$XWIN_ROOT/crt/include"
	/imsvc "$XWIN_ROOT/sdk/include/ucrt"
	/imsvc "$XWIN_ROOT/sdk/include/um"
	/imsvc "$XWIN_ROOT/sdk/include/shared"
	/imsvc "$XWIN_ROOT/sdk/include/winrt"
	/imsvc "$XWIN_ROOT/sdk/include/cppwinrt"
)
libs=(
	/libpath:"$XWIN_ROOT/crt/lib/$ARCH_DIR"
	/libpath:"$XWIN_ROOT/sdk/lib/um/$ARCH_DIR"
	/libpath:"$XWIN_ROOT/sdk/lib/ucrt/$ARCH_DIR"
	# WINRT_IMPL_* (CoInitializeEx, RoOriginateLanguageException, …) live here.
	WindowsApp.lib
)

# C++/WinRT reaches for <experimental/coroutine> below C++20, and that header
# refuses to compile with clang by design. C++20's <coroutine> works.
exec clang-cl -target "$TARGET" "/std:$STD" /EHsc /W3 \
	"${includes[@]}" "${sources[@]}" -o "$out" \
	"${extra[@]}" \
	-fuse-ld=lld-link -link "${libs[@]}"
