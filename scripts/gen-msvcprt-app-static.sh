#!/usr/bin/env bash
# gen-msvcprt-app-static.sh — MD static STL helpers for store-CRT (/MD) links.
#
#   gen-msvcprt-app-static.sh [--force]
#
# xwin's msvcprt.lib is two things mixed together:
#   1. Import stubs for MSVCP140.dll (desktop) — must not enter an AppContainer.
#   2. A small set of .obj members (filesystem, vector_algorithms, locale0, …)
#      compiled as RuntimeLibrary=MD_DynamicRelease that define __std_fs_*,
#      __std_find_*, std::_Facet_Register, and friends. msvcp140_app.dll does
#      not export those; Visual Studio still satisfies them from the MD static
#      surface of the STL. libcpmt.lib holds the same symbols but as MT, and
#      linking it into /MD fails FAILIFMISMATCH (gotcha 21).
#
# This script extracts only the .obj members into
#   $UWP_XWIN_ROOT/crt/lib/<arch>/msvcprt_app_static.lib
# build.sh --store-crt links that archive after the *_app import libs.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=scripts/common.sh
. "$here/common.sh"

force=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--force) force=1 && shift ;;
	*) die "unknown argument $1" ;;
	esac
done

XWIN_ROOT="${UWP_XWIN_ROOT:-$HOME/.cache/uwp-crossbuild/xwin}"
ARCH_DIR="${UWP_ARCH_DIR:-x86_64}"
src="$XWIN_ROOT/crt/lib/$ARCH_DIR/msvcprt.lib"
out="$XWIN_ROOT/crt/lib/$ARCH_DIR/msvcprt_app_static.lib"

[[ -f "$src" ]] || die "no msvcprt.lib at $src — run xwin splat / fetch-sdk.sh"
command -v llvm-ar >/dev/null || die "llvm-ar not found — ships with LLVM"
command -v llvm-lib >/dev/null || die "llvm-lib not found — ships with LLVM"

if [[ -f "$out" && $force -eq 0 ]]; then
	# Rebuild if the source archive is newer than our extract.
	if [[ ! "$src" -nt "$out" ]]; then
		echo "msvcprt_app_static.lib already current: $out"
		exit 0
	fi
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Member names are Windows paths (D:\a\_work\...\filesystem.obj). Extract only
# .obj — the MSVCP140.dll import stubs stay out.
mapfile -t members < <(llvm-ar t "$src" 2>/dev/null | grep -i '\.obj$')
[[ ${#members[@]} -gt 0 ]] || die "no .obj members in $src"

stage="$tmp/stage"
mkdir -p "$stage" "$tmp/extract"
objs=()
for m in "${members[@]}"; do
	# Member names are full Windows paths; llvm-ar writes them as a single
	# filename containing backslashes under --output.
	rm -rf "$tmp/extract"
	mkdir -p "$tmp/extract"
	llvm-ar --output "$tmp/extract" x "$src" "$m"
	base="${m##*[\\/]}"
	found=""
	for f in "$tmp/extract"/*; do
		[[ -f "$f" ]] || continue
		found="$f"
		break
	done
	[[ -n "$found" && -f "$found" ]] || die "failed to extract member: $m"
	dest="$stage/$base"
	if [[ -e "$dest" ]]; then
		dest="$stage/${#objs}_$base"
	fi
	cp "$found" "$dest"
	objs+=("$dest")
done

[[ ${#objs[@]} -gt 0 ]] || die "extracted zero objects from $src"

llvm-lib "/out:$out" "${objs[@]}"
echo "wrote $out (${#objs[@]} MD static objects from msvcprt.lib)"
# Sanity: the filesystem helpers that store /MD apps need must be present.
if ! llvm-nm "$out" 2>/dev/null | grep -q ' T __std_fs_create_directory$'; then
	die "$out is missing __std_fs_create_directory — extract incomplete"
fi
