#!/usr/bin/env bash
# build.sh — compile C++/WinRT sources into a Windows PE, from Linux.
#
#   build.sh --out app.exe [--uwp] [--pch pch.h] [--jobs N] [-I DIR] \
#            [--link-arg X] src/*.cpp [-- extra clang-cl args]
#
#     --uwp        build for the app container. Sets WINAPI_FAMILY=APP at
#                  compile time (VS parity). For an executable also links
#                  /appcontainer and the windows subsystem. Required for any
#                  UWP image, and for StaticLibrary projects that ship inside
#                  one (they must compile under the same family).
#     --store-crt  link the DLL runtime against the store CRT
#                  (VCRUNTIME140_APP.dll and friends) instead of the desktop
#                  one, using fetch-vclibs.sh import libs plus
#                  msvcprt_app_static.lib (MD static STL helpers: __std_fs_*,
#                  __std_find_*, _Facet_Register). Only with --uwp. The package
#                  must declare the Microsoft.VCLibs framework dependency —
#                  build-project.sh checks it does.
#     -I / --include  an extra include directory (repeatable). Use it for
#                  third-party headers — a NuGet native package, say — so a
#                  source tree written for Visual Studio compiles unmodified.
#     --pch        precompile this header and reuse it for every source. Worth
#                  it: including the XAML projection costs ~32 s per translation
#                  unit, ~1 s through a PCH (measured, see README).
#     --jobs       parallel compiles (default: nproc)
#     --link-arg   pass one argument straight to lld-link (repeatable)
#     --static-lib archive the objects into a .lib instead of linking an
#                  executable. What a Visual Studio project marked
#                  ConfigurationType=StaticLibrary produces, and what a project
#                  that references it expects to link against.
#     --help       this text
#
# C and C++ sources can be given together: a .c file is compiled as C, with
# UWP_C_STD, and everything else as C++ with UWP_CXX_STD.
#
# Wraps clang-cl and lld-link with the include and library paths xwin produces,
# plus the settings a C++/WinRT build cannot do without. See README.md.
set -euo pipefail

XWIN_ROOT="${UWP_XWIN_ROOT:-$HOME/.cache/uwp-crossbuild/xwin}"
TARGET="${UWP_TARGET:-x86_64-pc-windows-msvc}"
ARCH_DIR="${UWP_ARCH_DIR:-x86_64}"
STD="${UWP_CXX_STD:-c++20}"
C_STD="${UWP_C_STD:-c17}"

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=scripts/common.sh
. "$here/common.sh"

out=""
pch=""
jobs="$(nproc 2>/dev/null || echo 4)"
uwp=0
store_crt=0
static_lib=0
sources=()
extra=()
link_args=()
include_dirs=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--out) value "$1" $# "${2:-}" && out="$2" && shift 2 ;;
	--pch) value "$1" $# "${2:-}" && pch="$2" && shift 2 ;;
	--jobs) value "$1" $# "${2:-}" && jobs="$2" && shift 2 ;;
	--uwp) uwp=1 && shift ;;
	--store-crt) store_crt=1 && shift ;;
	--static-lib) static_lib=1 && shift ;;
	-I | --include) value "$1" $# "${2:-}" && include_dirs+=("/I$2") && shift 2 ;;
	--link-arg) value "$1" $# "${2:-}" && link_args+=("$2") && shift 2 ;;
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
# A contradiction in the arguments is answerable on any machine; it comes
# before the checks for what is installed.
# --static-lib + --uwp is legal: the archive is not an image, so /appcontainer
# is skipped, but WINAPI_FAMILY=APP still applies at compile time. Without it
# a UWP StaticLibrary (ggml-uwp) compiles desktop Win32 into the .lib and the
# linking application inherits forbidden imports (gotcha 22).
[[ $store_crt -eq 0 || $uwp -eq 1 ]] ||
	die "--store-crt without --uwp is a contradiction: the store CRT exists for
  the app container, and outside it the desktop /MD works as it is."
[[ $store_crt -eq 0 || $static_lib -eq 0 ]] ||
	die "--store-crt with --static-lib is a contradiction: the store CRT is a
  link-time property of the application image, not of an archive."
# Checked before the xwin CRT: the fix is a different script, and a message
# naming fetch-sdk.sh for a missing store CRT would send someone to re-run a
# download that cannot help.
vclibs_lib="$UWP_VCLIBS_ROOT/lib/$ARCH_DIR"
if [[ $store_crt -eq 1 ]]; then
	for lib in vcruntime140_app.lib msvcp140_app.lib; do
		[[ -f "$vclibs_lib/$lib" ]] ||
			die "no store CRT import libraries at $vclibs_lib — run
  scripts/fetch-vclibs.sh (with the platform this build is for)"
	done
fi
[[ -d "$XWIN_ROOT/crt/include" ]] || die "no CRT at $XWIN_ROOT — run fetch-sdk.sh"
command -v clang-cl >/dev/null || die "clang-cl not found"
[[ $static_lib -eq 0 ]] || command -v llvm-lib >/dev/null ||
	die "llvm-lib not found — it ships with LLVM, beside clang-cl"

# Force-included before everything: the two adjustments a source tree written
# for MSVC needs in order to compile with clang unchanged. See the header.
compat="$here/../include/msvc-compat.h"
[[ -f "$compat" ]] || die "missing $compat"

# /std and /EHsc are per-language and added at compile time. A .c file given
# /std:c++20 does not fail — clang-cl calls it an unused argument and compiles
# the file with whatever C standard it defaults to, which is not the same as
# choosing one — so what this buys is a stated standard per language and no
# warning per translation unit. The part that really did fail is in
# include/msvc-compat.h, which is force-included into C sources too.
common=(
	-target "$TARGET" /W3
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
	# Compile-time UWP surface — applies to StaticLibrary and Application.
	# Match Visual Studio: app family so WINAPI_FAMILY_PARTITION(DESKTOP) is
	# false. wingdi GDI names and desktop-only Win32 (RegOpenKeyEx,
	# SetThreadAffinityMask, …) stay out of the compile. include/msvc-compat.h
	# bridges the MSVC STL cstdlib getenv/system using under this family
	# (gotcha n°7).
	extra+=(/D__WRL_NO_DEFAULT_LIB__)
	extra+=(/DWINAPI_FAMILY=WINAPI_FAMILY_APP)
	# Link-time image flags — only an executable has DllCharacteristics.
	if [[ $static_lib -eq 0 ]]; then
		command -v llvm-dlltool >/dev/null ||
			die "llvm-dlltool not found — it ships with LLVM, beside clang-cl"
		# Without /appcontainer the image lacks
		# IMAGE_DLLCHARACTERISTICS_APPCONTAINER (0x1000) and the package is
		# refused. Verify with: objdump -p app.exe | grep DllCharacteristics
		# Subsystem 6.02 matches Visual Studio UWP (Windows 8 / Store baseline);
		# bare /subsystem:windows defaults to 6.00 and has been observed on
		# crossbuilt images that install but refuse activation as 0x8027025b
		# while a CI MSVC PE of the same app (6.02) launches.
		link_args+=(/appcontainer /subsystem:windows,6.02)
	fi
fi

store_last=()
if [[ $store_crt -eq 1 ]]; then
	# Shut out msvcprt.lib and vcruntime.lib (desktop MSVCP140 / VCRUNTIME140
	# imports) and link:
	#   1. VCLibs-generated *_app import set (DLL runtime in the container)
	#   2. msvcprt_app_static.lib — MD .obj members of msvcprt.lib that define
	#      __std_fs_*, __std_find_*, std::_Facet_Register (not exports of
	#      msvcp140_app.dll; VS pulls them from this MD static surface).
	# libcpmt.lib is MT and must never mix into /MD (FAILIFMISMATCH — gotcha 21).
	store_libs=()
	for lib in "$vclibs_lib"/*_app.lib; do
		store_libs+=("$(basename "$lib")")
	done
	md_static="$XWIN_ROOT/crt/lib/$ARCH_DIR/msvcprt_app_static.lib"
	if [[ ! -f "$md_static" ]]; then
		"$here/gen-msvcprt-app-static.sh"
	fi
	[[ -f "$md_static" ]] ||
		die "no MD static STL helpers at $md_static — run
  scripts/gen-msvcprt-app-static.sh"
	link_args+=(/nodefaultlib:msvcprt.lib /nodefaultlib:vcruntime.lib
		/libpath:"$vclibs_lib" "${store_libs[@]}")
	# Last so only unresolved helpers come from it.
	store_last=("$md_static")
fi

# -mcx16 enables cmpxchg16b, which MSVC assumes on x64 and clang does not.
# Without it, C++/WinRT's factory cache leaves __atomic_compare_exchange_16
# undefined at link time — an error that names no header and no source line.
[[ "$ARCH_DIR" == "x86_64" ]] && common+=(-mcx16)

# C++/WinRT reaches for <experimental/coroutine> below C++20, and that header
# refuses to compile with clang by design. C++20's <coroutine> works.
objdir="${UWP_OBJ_DIR:-$out.objs}"
mkdir -p "$objdir"

if [[ $uwp -eq 1 && $static_lib -eq 0 ]]; then
	# EncodePointer and DecodePointer: xwin's kernel32.lib imports them from
	# api-ms-win-core-util-l1-1-0.dll, an apiset the Xbox app container does
	# not provide — the package installs, and the loader then fails the launch
	# with 0x80070002, naming nothing. The static CRT reaches for the pair in
	# its optimised initialisation paths, so any /O2 build can pick the import
	# up with no application code involved. include/appcontainer-pointers.def
	# reroutes exactly these two names to KERNELBASE.dll, which exports them
	# and is present in every app-container process; first in the list, so
	# they resolve here before kernel32.lib is consulted. Link-time only.
	case "$ARCH_DIR" in
	aarch64) machine=arm64 ;;
	*) machine=i386:x86-64 ;;
	esac
	pointers="$objdir/appcontainer-pointers.lib"
	[[ -f "$pointers" ]] || llvm-dlltool -m "$machine" \
		-d "$here/../include/appcontainer-pointers.def" -l "$pointers"
	libs=("$pointers" "${libs[@]}")
fi

# The C++ flags. The precompiled header is C++ by definition, and so is every
# source that is not a .c.
cxx=("/std:$STD" /EHsc)

pch_args=()
if [[ -n "$pch" ]]; then
	[[ -f "$pch" ]] || die "no such header: $pch"
	pchfile="$objdir/$(basename "$pch").pch"
	# ~190 MB and ~40 s to build, so reuse it until the header itself changes.
	# Anything the header includes is SDK-stable; regenerate by deleting it.
	if [[ ! -f "$pchfile" || "$pch" -nt "$pchfile" ]]; then
		echo "  precompiling $(basename "$pch")"
		printf '#include "%s"\n' "$(basename "$pch")" >"$objdir/pch.cpp"
		clang-cl "${common[@]}" "${cxx[@]}" ${extra[@]+"${extra[@]}"} /c "$objdir/pch.cpp" \
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
	# `/` flattened to `_`, is not injective: src/util.cpp and src_util.cpp
	# would meet in one object, in parallel, and the link would take whichever
	# finished last without a word; a source named pch.cpp would collide with
	# the PCH's own object the same way. The checksum keeps the readable name
	# and settles the ties.
	flat="${src%.*}"
	flat="${flat#./}"
	crc=$(printf %s "$src" | cksum)
	obj="$objdir/${flat//\//_}.${crc%% *}.obj"
	objects+=("$obj")
	# A C source takes neither the C++ standard nor the C++ precompiled header.
	lang=("${cxx[@]}" ${pch_args[@]+"${pch_args[@]}"})
	[[ "$src" == *.c ]] && lang=("/std:$C_STD")
	clang-cl "${common[@]}" "${lang[@]}" ${extra[@]+"${extra[@]}"} /c "$src" -o "$obj" &
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

if [[ $static_lib -eq 1 ]]; then
	# An archive, not an image: no libraries, no entry point, no subsystem.
	# Whatever links it resolves the symbols.
	exec llvm-lib "/out:$out" "${objects[@]}"
fi

# ${store_last[@]} stays the final token: no --link-arg a caller adds may land
# after libcpmt.lib, or it could satisfy a symbol the import libraries export.
exec clang-cl -target "$TARGET" "${objects[@]}" -o "$out" \
	-fuse-ld=lld-link -link "${libs[@]}" ${link_args[@]+"${link_args[@]}"} \
	${store_last[@]+"${store_last[@]}"}
