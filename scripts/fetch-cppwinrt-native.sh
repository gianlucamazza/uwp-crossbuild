#!/usr/bin/env bash
# fetch-cppwinrt-native.sh — build the C++/WinRT compiler natively for Linux.
#
#   fetch-cppwinrt-native.sh [--version 2.0.240405.15]
#
# Microsoft ships cppwinrt.exe as a 32-bit PE only (still true of CppWinRT 3.0,
# 2026-07), and Wine 11.15 dropped the PE32 loader — on current Wine the NuGet
# binary cannot run at all. Upstream microsoft/cppwinrt builds natively on
# Linux by design (its CMakeLists says so), and the tool is deterministic per
# tag, so a native build at the same version produces the same projection as
# CI's cppwinrt.exe.
#
# Installs to $UWP_SDK_ROOT/cppwinrt/bin/cppwinrt (next to the .exe, which is
# kept for older Wines) and records the tag in cppwinrt.version beside it.
# wine-tool.sh prefers the native binary automatically when it is present.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=scripts/common.sh
. "$here/common.sh"

SDK_ROOT="${UWP_SDK_ROOT:-$HOME/.cache/uwp-crossbuild/sdk}"
version="${UWP_CPPWINRT_VERSION:-2.0.240405.15}"

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--version) value "$1" $# "${2:-}" && version="$2" && shift 2 ;;
	*) die "unknown argument $1" ;;
	esac
done

command -v cmake >/dev/null || die "cmake is required to build cppwinrt natively"
command -v git >/dev/null || die "git is required to build cppwinrt natively"

dest="$SDK_ROOT/cppwinrt/bin"
if [[ -x "$dest/cppwinrt" ]] &&
	[[ "$(cat "$dest/cppwinrt.version" 2>/dev/null)" == "$version" ]]; then
	echo "native cppwinrt $version already at $dest/cppwinrt"
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

step "Cloning microsoft/cppwinrt @ $version"
git clone --quiet --depth 1 --branch "$version" \
	https://github.com/microsoft/cppwinrt.git "$work/src" ||
	die "no upstream tag '$version' — check https://github.com/microsoft/cppwinrt/tags"

step "Building the compiler natively"
cmake -S "$work/src" -B "$work/build" -DCMAKE_BUILD_TYPE=Release \
	-DCPPWINRT_BUILD_VERSION="$version" >/dev/null
cmake --build "$work/build" -j "$(nproc)" >/dev/null
[[ -x "$work/build/cppwinrt" ]] || die "build produced no cppwinrt binary"

# The tool must agree it is the requested version: the projection headers it
# writes carry CPPWINRT_VERSION, and a mismatch there fails builds much later.
got="$("$work/build/cppwinrt" 2>&1 | sed -n 's/^C++\/WinRT v//p' | head -1)"
[[ "$got" == "$version" ]] || die "built cppwinrt says '$got', wanted '$version'"

mkdir -p "$dest"
install -m 0755 "$work/build/cppwinrt" "$dest/cppwinrt"
printf '%s\n' "$version" >"$dest/cppwinrt.version"
echo "native cppwinrt $version installed at $dest/cppwinrt"
