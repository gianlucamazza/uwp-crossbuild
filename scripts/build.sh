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
die() {
	echo "error: $*" >&2
	exit 1
}
# A flag whose value is missing would otherwise fail on an unbound $2 under
# `set -u`, naming the shell rather than the argument.
value() { # value <flag> <argc>
	[[ $2 -ge 2 ]] || die "$1 needs a value"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--out) value "$1" $# && out="$2" && shift 2 ;;
	--pch) value "$1" $# && pch="$2" && shift 2 ;;
	--jobs) value "$1" $# && jobs="$2" && shift 2 ;;
	--uwp) uwp=1 && shift ;;
	-I | --include) value "$1" $# && include_dirs+=("/I$2") && shift 2 ;;
	--link-arg) value "$1" $# && link_args+=("$2") && shift 2 ;;
	--)
		shift
		extra=("$@")
		break
		;;
	*) sources+=("$1") && shift ;;
	esac
done

[[ -n "$out" ]] || die "--out is required"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer, got: $jobs"
[[ ${#sources[@]} -gt 0 ]] || die "no source files given"
# Anything unrecognised is taken as a source, so a glued `-I/path` — the form
# clang-cl itself accepts — would be handed to the compiler as a file. Check
# here, where the error can say which argument was wrong.
for src in "${sources[@]}"; do
	[[ -f "$src" ]] || die "no such source file: $src
  (include directories go through -I DIR or --include DIR, with a space)"
done
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
		# ${arr[@]+…}: an array that can be empty, expanded the way bash before
		# 4.4 accepts under set -u — same as include_dirs and pids above.
		clang-cl "${common[@]}" ${extra[@]+"${extra[@]}"} /c "$objdir/pch.cpp" \
			"/Yc$(basename "$pch")" "/Fp$pchfile" "/Fo$objdir/pch.obj" \
			"/I$(cd "$(dirname "$pch")" && pwd)"
	fi
	pch_args=("/Yu$(basename "$pch")" "/Fp$pchfile")
fi

# Waits for every compile before reporting, so one broken source does not hide
# the errors from the others — and so no compile is left running detached.
wait_all() { # wait_all <pid...>
	local p rc=0
	for p in "$@"; do wait "$p" || rc=1; done
	return "$rc"
}

objects=()
pids=()
for src in "${sources[@]}"; do
	# Named after the whole path plus a checksum of it. The path alone, with
	# every / replaced by _, is not injective: src/util.cpp and src_util.cpp
	# would meet in the same object, in parallel, and the link would take
	# whichever finished last without a word — and a source named pch.cpp
	# would collide with the PCH's own object the same way. The checksum
	# settles every such pair.
	flat="${src%.*}"
	flat="${flat#./}"
	crc=$(printf %s "$src" | cksum)
	obj="$objdir/${flat//\//_}.${crc%% *}.obj"
	objects+=("$obj")
	clang-cl "${common[@]}" ${extra[@]+"${extra[@]}"} \
		${pch_args[@]+"${pch_args[@]}"} /c "$src" -o "$obj" &
	pids+=($!)
	# A plain `wait -n` loop would be neater but needs bash 4.3+ semantics that
	# differ across the versions in the wild; batching is enough here.
	if [[ ${#pids[@]} -ge "$jobs" ]]; then
		wait_all ${pids[@]+"${pids[@]}"} || die "compilation failed"
		pids=()
	fi
done
wait_all ${pids[@]+"${pids[@]}"} || die "compilation failed"

[[ -n "$pch" ]] && objects+=("$objdir/pch.obj")

exec clang-cl -target "$TARGET" "${objects[@]}" -o "$out" \
	-fuse-ld=lld-link -link "${libs[@]}" ${link_args[@]+"${link_args[@]}"}
