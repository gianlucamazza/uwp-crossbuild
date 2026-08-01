#!/usr/bin/env bash
# build.sh — compile C++/WinRT sources into a Windows PE, from Linux.
#
#   build.sh --out app.exe [--uwp] [--pch pch.h] [--jobs N] [-I DIR] \
#            [--link-arg X] src/*.cpp [-- extra clang-cl args]
#
#     --uwp        build for the app container: /appcontainer and the windows
#                  subsystem. Required for anything that installs as a UWP app.
#     -I / --include  an extra include directory (repeatable). Use it for
#                  third-party headers — a NuGet native package, say — so a
#                  source tree written for Visual Studio compiles unmodified.
#     --pch        precompile this header and reuse it for every source. Worth
#                  it: including the XAML projection costs ~32 s per translation
#                  unit, ~1 s through a PCH (measured, see README).
#     --jobs       parallel compiles (default: nproc)
#     --link-arg   pass one argument straight to lld-link (repeatable)
#
# Wraps clang-cl and lld-link with the include and library paths xwin produces,
# plus the settings a C++/WinRT build cannot do without. See README.md.
set -euo pipefail

XWIN_ROOT="${UWP_XWIN_ROOT:-$HOME/.cache/uwp-crossbuild/xwin}"
TARGET="${UWP_TARGET:-x86_64-pc-windows-msvc}"
ARCH_DIR="${UWP_ARCH_DIR:-x86_64}"
STD="${UWP_CXX_STD:-c++20}"

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

out=""
pch=""
jobs="$(nproc 2>/dev/null || echo 4)"
uwp=0
sources=()
extra=()
link_args=()
include_dirs=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--out) out="$2" && shift 2 ;;
	--pch) pch="$2" && shift 2 ;;
	--jobs) jobs="$2" && shift 2 ;;
	--uwp) uwp=1 && shift ;;
	-I | --include) include_dirs+=("/I$2") && shift 2 ;;
	--link-arg) link_args+=("$2") && shift 2 ;;
	--)
		shift
		extra=("$@")
		break
		;;
	*) sources+=("$1") && shift ;;
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

# Force-included before everything: the two adjustments a source tree written
# for MSVC needs in order to compile with clang unchanged. See the header.
compat="$here/../include/msvc-compat.h"
[[ -f "$compat" ]] || die "missing $compat"

common=(
	-target "$TARGET" "/std:$STD" /EHsc /W3
	"/FI$compat"
	/imsvc "$XWIN_ROOT/crt/include"
	/imsvc "$XWIN_ROOT/sdk/include/ucrt"
	/imsvc "$XWIN_ROOT/sdk/include/um"
	/imsvc "$XWIN_ROOT/sdk/include/shared"
	/imsvc "$XWIN_ROOT/sdk/include/winrt"
	/imsvc "$XWIN_ROOT/sdk/include/cppwinrt"
	${include_dirs[@]+"${include_dirs[@]}"}
)
libs=(
	/libpath:"$XWIN_ROOT/crt/lib/$ARCH_DIR"
	/libpath:"$XWIN_ROOT/sdk/lib/um/$ARCH_DIR"
	/libpath:"$XWIN_ROOT/sdk/lib/ucrt/$ARCH_DIR"
	# WINRT_IMPL_* (CoInitializeEx, RoOriginateLanguageException, …) live here.
	WindowsApp.lib
)

if [[ $uwp -eq 1 ]]; then
	extra+=(/D__WRL_NO_DEFAULT_LIB__)
	# Without /appcontainer the image lacks IMAGE_DLLCHARACTERISTICS_APPCONTAINER
	# (0x1000) and the package is refused. Verify with:
	#   objdump -p app.exe | grep DllCharacteristics
	#
	# Deliberately NOT set here: /DWINAPI_FAMILY=WINAPI_FAMILY_APP. It would
	# restrict the headers to the app partition, but it makes <cstdlib>
	# uncompilable — the ucrt hides `system`/`getenv` outside the desktop
	# partition while the MSVC STL still does `using _CSTD system;`
	# unconditionally. Pass it via `--` if you want to audit a translation unit.
	link_args+=(/appcontainer /subsystem:windows)
fi

# -mcx16 enables cmpxchg16b, which MSVC assumes on x64 and clang does not.
# Without it, C++/WinRT's factory cache leaves __atomic_compare_exchange_16
# undefined at link time — an error that names no header and no source line.
[[ "$ARCH_DIR" == "x86_64" ]] && common+=(-mcx16)

# C++/WinRT reaches for <experimental/coroutine> below C++20, and that header
# refuses to compile with clang by design. C++20's <coroutine> works.
objdir="${UWP_OBJ_DIR:-$out.objs}"
mkdir -p "$objdir"

pch_args=()
if [[ -n "$pch" ]]; then
	[[ -f "$pch" ]] || die "no such header: $pch"
	pchfile="$objdir/$(basename "$pch").pch"
	# ~190 MB and ~40 s to build, so reuse it until the header itself changes.
	# Anything the header includes is SDK-stable; regenerate by deleting it.
	if [[ ! -f "$pchfile" || "$pch" -nt "$pchfile" ]]; then
		echo "  precompiling $(basename "$pch")"
		printf '#include "%s"\n' "$(basename "$pch")" >"$objdir/pch.cpp"
		clang-cl "${common[@]}" "${extra[@]}" /c "$objdir/pch.cpp" \
			"/Yc$(basename "$pch")" "/Fp$pchfile" "/Fo$objdir/pch.obj" \
			"/I$(cd "$(dirname "$pch")" && pwd)"
	fi
	pch_args=("/Yu$(basename "$pch")" "/Fp$pchfile")
fi

objects=()
pids=()
for src in "${sources[@]}"; do
	obj="$objdir/$(basename "${src%.*}").obj"
	objects+=("$obj")
	clang-cl "${common[@]}" "${extra[@]}" "${pch_args[@]}" /c "$src" -o "$obj" &
	pids+=($!)
	# A plain `wait -n` loop would be neater but needs bash 4.3+ semantics that
	# differ across the versions in the wild; batching is enough here.
	if [[ ${#pids[@]} -ge $jobs ]]; then
		for p in "${pids[@]}"; do wait "$p"; done
		pids=()
	fi
done
for p in "${pids[@]}"; do wait "$p"; done

[[ -n "$pch" ]] && objects+=("$objdir/pch.obj")

exec clang-cl -target "$TARGET" "${objects[@]}" -o "$out" \
	-fuse-ld=lld-link -link "${libs[@]}" "${link_args[@]}"
