#!/usr/bin/env bash
# run-tests.sh — everything that can be checked without 1.1 GB of Windows SDK.
#
# The scripts here are mostly workarounds, each tied to a version of LLVM, Wine,
# xwin or the SDK. What can be tested cheaply is the logic around them: argument
# handling, the guards that produce a useful error instead of a confusing one,
# and the header-alias generator, which is pure parsing.
#
# Anything needing the real toolchain belongs in the manual workflow, not here.
set -uo pipefail

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
scripts="$here/../scripts"
packaging="$here/../packaging"
passed=0
failed=0

# The developer's real store-CRT cache must not decide a test: the evaluator
# turns /MD-vs-/MT on the presence of UWP_VCLIBS_ROOT/lib/<arch>, and presence
# in a test is a fixture, never whatever this machine happens to have fetched.
export UWP_VCLIBS_ROOT=/nonexistent

ok() {
	printf '  ok   %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf '  FAIL %s\n  	%s\n' "$1" "${2:-}" >&2
	failed=$((failed + 1))
}

assert() { # assert <name> <detail-on-failure> <test-expression...>
	local name="$1" detail="$2"
	shift 2
	if "$@"; then
		ok "$name"
	else
		no "$name" "$detail"
	fi
}

is_link_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }

skipped=0
skip() { # skip <name> <why>
	printf '  skip %s (%s)\n' "$1" "$2"
	skipped=$((skipped + 1))
}

fails_with() { # fails_with <name> <expected-substring> <command...>
	local name="$1" expect="$2"
	shift 2
	local out status
	out="$("$@" 2>&1)"
	status=$?
	if [[ $status -eq 0 ]]; then
		no "$name" "expected a non-zero exit, got 0"
	elif [[ "$out" != *"$expect"* ]]; then
		no "$name" "expected '$expect', got: ${out:-<empty>}"
	else
		ok "$name"
	fi
}

succeeds_with() { # succeeds_with <name> <expected-substring> <command...>
	local name="$1" expect="$2"
	shift 2
	local out status
	out="$("$@" 2>&1)"
	status=$?
	if [[ $status -ne 0 ]]; then
		no "$name" "expected exit 0, got $status: ${out:-<empty>}"
	elif [[ "$out" != *"$expect"* ]]; then
		no "$name" "expected '$expect', got: ${out:-<empty>}"
	else
		ok "$name"
	fi
}

lacks() { # lacks <name> <substring that must not appear> <command...>
	local name="$1" unwanted="$2"
	shift 2
	local out
	out="$("$@" 2>&1)"
	if [[ "$out" == *"$unwanted"* ]]; then
		no "$name" "'$unwanted' is in the output: $out"
	else
		ok "$name"
	fi
}

echo "fix-header-case.sh --canonical"
tmp="$(mktemp -d)"
# Capitalising each segment would give "Applicationmodel" and
# "Datatransfer" — which is why the script reads the namespace out of the file.
cat >"$tmp/windows.applicationmodel.datatransfer.h" <<'EOF'
namespace winrt::impl {}
WINRT_EXPORT namespace winrt::Windows::ApplicationModel::DataTransfer
{
}
EOF
cat >"$tmp/windows.ai.machinelearning.h" <<'EOF'
WINRT_EXPORT namespace winrt::Windows::AI::MachineLearning
{
}
EOF
# base.h forward-declares other namespaces near the top and sorts first, so a
# script that trusts the first namespace it finds gives it the alias for
# Windows.Foundation.h — and the real windows.foundation.h, the one holding
# box_value, gets none. That reads as a missing function, not a bad symlink.
cat >"$tmp/base.h" <<'EOF'
WINRT_EXPORT namespace winrt::Windows::Foundation
{
}
EOF
cat >"$tmp/windows.foundation.h" <<'EOF'
WINRT_EXPORT namespace winrt::Windows::Foundation
{
}
EOF

"$scripts/fix-header-case.sh" "$tmp" --canonical >/dev/null
assert "a namespace only fixes its own file's casing" "base.h claimed the alias" \
	is_link_to "$tmp/Windows.Foundation.h" windows.foundation.h
assert "a header whose namespace is not its name gets no alias" "Base.h exists" \
	test ! -e "$tmp/Base.h"
assert "compound segments keep their casing" "no Windows.ApplicationModel.DataTransfer.h" \
	test -L "$tmp/Windows.ApplicationModel.DataTransfer.h"
assert "acronyms stay upper-case" "no Windows.AI.MachineLearning.h" \
	test -L "$tmp/Windows.AI.MachineLearning.h"
assert "the alias points at the real file" "wrong link target" \
	is_link_to "$tmp/Windows.AI.MachineLearning.h" windows.ai.machinelearning.h

# A wrong alias from an earlier version of this script must not survive — but
# only aliases of this mode's own shape are its to delete: --lower's
# all-lowercase ones and a user's symlink to elsewhere both stay.
ln -s windows.ai.machinelearning.h "$tmp/Windows.Ai.Machinelearning.h"
ln -s windows.foundation.h "$tmp/lowercase.alias.h"
ln -s /etc/hostname "$tmp/My.Own.Header.h"
"$scripts/fix-header-case.sh" "$tmp" --canonical >/dev/null
assert "a stale alias is removed" "Windows.Ai.Machinelearning.h survived" \
	test ! -e "$tmp/Windows.Ai.Machinelearning.h"
assert "rerunning is idempotent" "the correct alias did not come back" \
	test -L "$tmp/Windows.AI.MachineLearning.h"
assert "an all-lowercase alias survives --canonical" "lowercase.alias.h was deleted" \
	test -L "$tmp/lowercase.alias.h"
assert "a symlink to elsewhere survives --canonical" "My.Own.Header.h was deleted" \
	test -L "$tmp/My.Own.Header.h"
rm -rf "$tmp"

echo "fix-header-case.sh --lower"
tmp="$(mktemp -d)"
touch "$tmp/WinRTBase.idl" "$tmp/already-lower.idl"
"$scripts/fix-header-case.sh" "$tmp" --lower >/dev/null
assert "mixed case gets a lowercase alias" "no winrtbase.idl symlink" \
	is_link_to "$tmp/winrtbase.idl" WinRTBase.idl
rm -rf "$tmp"
fails_with "a missing directory is refused" "no such directory" \
	"$scripts/fix-header-case.sh" /nonexistent-directory --lower
fails_with "no directory at all is an error, not a shell diagnostic" \
	"a directory is required" "$scripts/fix-header-case.sh"
fails_with "an unknown mode names the two that exist" "expected --lower" \
	"$scripts/fix-header-case.sh" /tmp --sideways

echo "build.sh guards"
tmp="$(mktemp -d)"
touch "$tmp/a.cpp"
fails_with "--out is required" "--out is required" "$scripts/build.sh" "$tmp/a.cpp"
fails_with "sources are required" "no source files" "$scripts/build.sh" --out a.exe
fails_with "a missing CRT names fetch-sdk.sh" "run fetch-sdk.sh" \
	env UWP_XWIN_ROOT=/nonexistent "$scripts/build.sh" --out a.exe "$tmp/a.cpp"
# Unrecognised arguments become sources, so a glued -I/path would reach clang-cl
# as a file. The error has to name the argument, not the compiler.
fails_with "a source that does not exist is refused" "no such source file" \
	env UWP_XWIN_ROOT=/nonexistent "$scripts/build.sh" --out a.exe "-I$tmp"
fails_with "a flag with no value says so" "--out needs a value" \
	"$scripts/build.sh" --out
fails_with "--jobs takes a positive integer" "--jobs must be a positive integer" \
	env UWP_XWIN_ROOT=/nonexistent "$scripts/build.sh" --out a.exe --jobs 0 "$tmp/a.cpp"
# An archive has no DllCharacteristics: /appcontainer is link-only. But a UWP
# StaticLibrary still needs WINAPI_FAMILY=APP at compile time, so --static-lib
# + --uwp is legal (compile family yes, image flags no). store-crt is link-only.
mkdir -p "$tmp/crt/include"
fails_with "--store-crt with --static-lib is a contradiction" "static-lib" \
	env UWP_XWIN_ROOT="$tmp" "$scripts/build.sh" --static-lib --uwp --store-crt \
	--out a.lib "$tmp/a.cpp"
fails_with "--store-crt without --uwp is a contradiction" "store CRT" \
	env UWP_XWIN_ROOT="$tmp" "$scripts/build.sh" --store-crt --out a.exe "$tmp/a.cpp"
assert "build.sh accepts --static-lib --uwp (compile family only)" "still exclusive" \
	grep -q 'static-lib + --uwp is legal' "$scripts/build.sh"
# Checked before the xwin CRT: the fix is fetch-vclibs.sh, and a message naming
# fetch-sdk.sh would send someone to re-run a download that cannot help.
fails_with "--store-crt without the libraries names fetch-vclibs.sh" "fetch-vclibs.sh" \
	env UWP_XWIN_ROOT=/nonexistent "$scripts/build.sh" --uwp --store-crt \
	--out a.exe "$tmp/a.cpp"
# store_last expands last: msvcprt_app_static.lib (MD helpers), never libcpmt.
assert "store_last expansion stays last when set" "store_last moved" \
	grep -qP '^\t\$\{store_last\[@\]\+"\$\{store_last\[@\]\}"\}$' "$scripts/build.sh"
assert "store path links msvcprt_app_static (MD helpers)" "no MD static helpers" \
	grep -q 'msvcprt_app_static.lib' "$scripts/build.sh"
if grep -q 'UWP_STORE_CRT_LIBCPMT' "$scripts/build.sh"; then
	no "store path does not fall back to libcpmt" "libcpmt still forced"
else
	ok "store path does not fall back to libcpmt"
fi
assert "gen-msvcprt-app-static.sh exists" "missing helper generator" \
	test -x "$scripts/gen-msvcprt-app-static.sh"
rm -rf "$tmp"

echo "fetch-vclibs.sh guards"
fails_with "a source is required" "either --appx FILE or --url URL" \
	"$scripts/fetch-vclibs.sh"
fails_with "two sources are one too many" "exclusive" \
	"$scripts/fetch-vclibs.sh" --appx x --url y
fails_with "a missing --appx file says so" "no such file" \
	"$scripts/fetch-vclibs.sh" --appx /nonexistent/vclibs.appx
# The consent gate has to come before any network access: the URL here answers
# nothing, so a regression that reaches for it fails loudly on the connection
# rather than passing this test quietly.
fails_with "downloading needs explicit licence acceptance" "licence acceptance" \
	"$scripts/fetch-vclibs.sh" --url http://127.0.0.1:1/vclibs.appx
fails_with "a platform outside the matrix is refused" "x64 or ARM64" \
	"$scripts/fetch-vclibs.sh" --appx x --platform Win32
fails_with "an unknown argument is refused" "unknown argument" \
	"$scripts/fetch-vclibs.sh" --publish-everything

echo "--help"
# Installed as uwp-build and friends, where the header comment nobody can see is
# the only documentation. Each script prints its own, and exits 0 doing it.
for script in "$scripts"/*.sh "$packaging"/publish-aur.sh; do
	# common.sh is sourced by the others and never run: it is a library, and
	# has no usage of its own to print.
	[[ "$(basename "$script")" != common.sh ]] || continue
	succeeds_with "$(basename "$script") --help prints its usage" \
		"$(basename "$script") —" "$script" --help
done
assert "common.sh is a library, not a command" "it is executable, so it looks like one" \
	test ! -x "$scripts/common.sh"
fails_with "check-deps.sh rejects arguments rather than ignoring them" \
	"takes no arguments" "$scripts/check-deps.sh" --canonical

echo "build-app.sh guards"
tmp="$(mktemp -d)"
fails_with "--project is required" "--project and --out are required" \
	"$scripts/build-app.sh" --out "$tmp/out"
fails_with "a project without app.idl is refused" "no app.idl" \
	"$scripts/build-app.sh" --project "$tmp" --out "$tmp/out"
touch "$tmp/app.idl"
fails_with "a project without a manifest is refused" "no AppxManifest.xml" \
	"$scripts/build-app.sh" --project "$tmp" --out "$tmp/out"
# --name defaults to Executable minus .exe, and a manifest without one must say so
# rather than build something called "".
echo '<Package><Applications><Application Id="x"/></Applications></Package>' >"$tmp/AppxManifest.xml"
fails_with "a manifest with no Executable asks for --name" "pass --name" \
	"$scripts/build-app.sh" --project "$tmp" --out "$tmp/out"
# The layout is the package's contents: generated files inside it get shipped and
# indexed into resources.pri, so --out cannot be the project or live under it.
echo '<Package><Applications><Application Id="x" Executable="hello.exe"/></Applications></Package>' \
	>"$tmp/AppxManifest.xml"
fails_with "--out inside --project is refused" "must be outside --project" \
	"$scripts/build-app.sh" --project "$tmp" --out "$tmp/inside"
# A directory that is not recognisably a layout is never cleared, whatever
# --out was pointed at.
elsewhere="$(mktemp -d)"
touch "$elsewhere/precious"
fails_with "a non-empty --out with no manifest is not cleared" "refusing to clear it" \
	"$scripts/build-app.sh" --project "$tmp" --out "$elsewhere"
assert "the untouched directory kept its contents" "the file was deleted" \
	test -f "$elsewhere/precious"
# --copy carries precompiled third-party DLLs into the package. A path that is
# not there is worth saying before a ten-minute compile, not after.
fails_with "--copy checks its directory before building" "no such directory" \
	"$scripts/build-app.sh" --project "$tmp" --out "$elsewhere/layout" \
	--copy /nonexistent-dlls
# `--out --uwp` would otherwise write the layout to a directory literally
# named --uwp, deferring the failure to whatever reads it next.
fails_with "a flag given another flag as its value is refused" "not another flag" \
	"$scripts/build-app.sh" --project "$tmp" --out --uwp
fails_with "a flag with no value is reported by name" "--language needs a value" \
	"$scripts/build-app.sh" --language
# The reverse containment: clearing a stale layout is recursive, so a project
# under --out would be deleted with it — sources and all.
nested="$(mktemp -d)"
cp "$tmp/AppxManifest.xml" "$nested/"
mkdir "$nested/src"
touch "$nested/src/app.idl"
cp "$tmp/AppxManifest.xml" "$nested/src/"
fails_with "--project inside --out is refused" "must not live under --out" \
	"$scripts/build-app.sh" --project "$nested/src" --out "$nested"
assert "the nested project kept its sources" "app.idl was deleted" \
	test -f "$nested/src/app.idl"
rm -rf "$nested"
# Symlinks must not defeat the guards: the comparisons are on physical paths,
# or a layout reached through a link deletes the project inside the real one.
sym="$(mktemp -d)"
mkdir -p "$sym/data/layout/proj"
cp "$tmp/AppxManifest.xml" "$sym/data/layout/"
touch "$sym/data/layout/proj/app.idl"
cp "$tmp/AppxManifest.xml" "$sym/data/layout/proj/"
ln -s data "$sym/slink"
fails_with "a symlinked --out cannot hide the project inside it" "must not live under --out" \
	"$scripts/build-app.sh" --project "$sym/data/layout/proj" --out "$sym/slink/layout"
assert "the project behind the symlink kept its sources" "app.idl was deleted" \
	test -f "$sym/data/layout/proj/app.idl"
# The platform table lives in common.sh; both front doors refuse the same way.
fails_with "a platform outside the matrix is refused" "x64 or ARM64" \
	"$scripts/build-app.sh" --project "$tmp" --out "$elsewhere/layout" --platform Win32
# The manifest ships verbatim, so its architecture has to agree with the
# platform — the same refusal read-vcxproj.py makes, mirrored here.
arch="$(mktemp -d)"
touch "$arch/app.idl"
echo '<Package><Identity ProcessorArchitecture="arm64"/><Applications><Application Id="x" Executable="hello.exe"/></Applications></Package>' \
	>"$arch/AppxManifest.xml"
fails_with "a manifest whose architecture is not the platform's is refused" "ProcessorArchitecture" \
	"$scripts/build-app.sh" --project "$arch" --out "$elsewhere/layout"
# Parsed as XML, not grepped: a single-quoted attribute on a wrapped <Identity>
# slipped past the old pattern, and the mismatch shipped instead of refusing.
printf '%s\n' '<Package>' '  <Identity' "    ProcessorArchitecture='arm64'/>" \
	'  <Applications><Application Id="x" Executable="hello.exe"/></Applications>' \
	'</Package>' >"$arch/AppxManifest.xml"
fails_with "a single-quoted, wrapped Identity is still refused" "ProcessorArchitecture" \
	"$scripts/build-app.sh" --project "$arch" --out "$elsewhere/layout"
# A --platform actually typed refuses an environment that contradicts it: the
# pair would validate one architecture's manifest and compile another's
# executable. Left at its default, the environment keeps winning — the workflow
# that predates the flag — and the manifest check follows the effective target,
# so the arm64 manifest passes it and the run dies later, at the missing SDK.
fails_with "--platform typed out refuses a contradicting environment" "Drop the override" \
	env UWP_TARGET=x86_64-pc-windows-msvc \
	"$scripts/build-app.sh" --project "$arch" --out "$elsewhere/layout" --platform ARM64
lacks "a defaulted --platform yields to the environment" "ProcessorArchitecture" \
	env UWP_TARGET=aarch64-pc-windows-msvc UWP_ARCH_DIR=aarch64 UWP_SDK_ROOT=/nonexistent UWP_XWIN_ROOT=/nonexistent \
	"$scripts/build-app.sh" --project "$arch" --out "$elsewhere/layout"
rm -rf "$arch" "$sym" "$tmp" "$elsewhere"

echo "wine-tool.sh guards"
# The tool is there but the contracts are not: midlrt would otherwise run with
# zero /reference arguments and fail much later on unresolved metadata.
tmp="$(mktemp -d)"
mkdir -p "$tmp/Windows Kits/10/bin/10.0.22621.0/x64"
touch "$tmp/Windows Kits/10/bin/10.0.22621.0/x64/midlrt.exe"
if ! command -v wine >/dev/null; then
	skip "midlrt without contract winmds names the References directory" \
		"wine is not installed"
else
	fails_with "midlrt without contract winmds names the References directory" \
		"no contract .winmd" \
		env UWP_SDK_ROOT="$tmp" "$scripts/wine-tool.sh" midlrt /?
fi
rm -rf "$tmp"

echo "gen-projection.sh and gen-resources.sh guards"
fails_with "gen-projection needs its arguments" "are required" "$scripts/gen-projection.sh"
fails_with "gen-projection reports a flag with no value" "--idl needs a value" \
	"$scripts/gen-projection.sh" --idl
tmp="$(mktemp -d)"
fails_with "gen-resources needs a layout with a manifest" "no AppxManifest.xml" \
	"$scripts/gen-resources.sh" --layout "$tmp"
rm -rf "$tmp"

echo "wine-tool.sh"
fails_with "an unknown tool is refused" "usage:" \
	env UWP_SDK_ROOT=/nonexistent "$scripts/wine-tool.sh" notatool
fails_with "a missing SDK names fetch-sdk.sh" "run scripts/fetch-sdk.sh" \
	env UWP_SDK_ROOT=/nonexistent "$scripts/wine-tool.sh" midlrt /?
# The SDK is there but the tools are not where UWP_SDK_VERSION says: without a
# guard this is whatever Wine prints about a missing executable. Only reachable
# with wine installed — the environment check runs first, and rightly so: a
# suggestion to try another SDK version is no use to someone who cannot run any.
tmp="$(mktemp -d)"
mkdir -p "$tmp/Windows Kits/10/bin/10.0.99999.0"
if ! command -v wine >/dev/null; then
	skip "an SDK without the tool for this version says which versions exist" \
		"wine is not installed"
else
	fails_with "an SDK without the tool for this version says which versions exist" \
		"10.0.99999.0" \
		env UWP_SDK_ROOT="$tmp" "$scripts/wine-tool.sh" midlrt /?
fi
rm -rf "$tmp"

echo "the SDK default is pinned once"
# fetch-sdk.sh writes the layout at the version common.sh pins;
# gen-projection.sh and wine-tool.sh read it back. A second literal copy is
# exactly the disagreement common.sh exists to prevent, and its symptom —
# "tool not found" — names neither copy.
# shellcheck source=scripts/common.sh
sdk_default="$(. "$scripts/common.sh" && echo "$UWP_SDK_VERSION_DEFAULT")"
assert "common.sh declares the default SDK version" "UWP_SDK_VERSION_DEFAULT is empty" \
	test -n "$sdk_default"
# Any four-component 10.0.* literal is a pin, whatever its value: a script
# keeping an older default would pass a search that only knows the current one.
# The web-installer URL is a fwlink, so it carries no version to except.
extra_pins="$(grep -rlE --include='*.sh' '10\.0\.[0-9]+\.[0-9]+' "$scripts" |
	grep -v 'common\.sh$' || true)"
assert "a version literal lives only in common.sh" "also in: $extra_pins" \
	test -z "$extra_pins"
assert "and the one there is the default itself" "UWP_SDK_VERSION_DEFAULT moved" \
	grep -qF "UWP_SDK_VERSION_DEFAULT=\"$sdk_default\"" "$scripts/common.sh"
# The store-CRT root is pinned twice by necessity — common.sh for bash, and
# read-vcxproj.py for python, which cannot source it — so the two copies are
# held to the same directory here.
# shellcheck disable=SC2016  # the $HOME below is the literal being pinned
assert "common.sh defaults the store-CRT root" "the default moved" \
	grep -qF -- '-$HOME/.cache/uwp-crossbuild/vclibs}' "$scripts/common.sh"
assert "and python's fallback names the same directory" "the literals disagree" \
	grep -qF '"~/.cache/uwp-crossbuild/vclibs"' "$scripts/read-vcxproj.py"

echo "publish-aur.sh guards"
fails_with "a version is required" "--version is required" "$packaging/publish-aur.sh"
fails_with "a version that is not one is refused" "not a version" \
	"$packaging/publish-aur.sh" --version 0.1.0-rc1
fails_with "an unknown argument is refused" "unknown argument" \
	"$packaging/publish-aur.sh" --version 0.1.0 --publish-everything

echo "gen-resources.sh leaves nothing behind"
tmp="$(mktemp -d)"
mkdir -p "$tmp/layout" "$tmp/tmpdir"
touch "$tmp/layout/AppxManifest.xml"
# makepri needs its config file somewhere outside the layout, so the script makes
# a temporary directory. It has to go, whichever way the script exits.
fails_with "a missing SDK is reported" "SDK not found" \
	env TMPDIR="$tmp/tmpdir" UWP_SDK_ROOT=/nonexistent \
	"$scripts/gen-resources.sh" --layout "$tmp/layout"
assert "the temporary config directory is removed" "something is left in TMPDIR" \
	test -z "$(ls -A "$tmp/tmpdir")"
rm -rf "$tmp"

echo "check-deps.sh"
# PATH is emptied so nothing is actually probed: what is under test is the list
# of prerequisites, not this machine. bash is called by path for the same reason.
fails_with "python3 is a prerequisite, for fix-header-case --canonical" "python3" \
	env PATH=/nonexistent "$BASH" "$scripts/check-deps.sh"
fails_with "msxml6 counts as missing rather than exiting 0" "Missing:" \
	env PATH=/nonexistent "$BASH" "$scripts/check-deps.sh"

echo "read-vcxproj.py"
# One fixture exercising everything the evaluator has to get right, distilled
# from what real Visual Studio projects do — the repository cannot depend on
# anyone's private source tree, so the shapes are copied and the code is not.
vcxproj="$here/fixtures/evaluation/evaluation.vcxproj"
read_vcxproj="$scripts/read-vcxproj.py"

succeeds_with "a conditional property resolves into the defines" "USE_ORT=1" \
	"$read_vcxproj" "$vcxproj" --field defines
lacks "the branch its condition excluded leaves nothing behind" "USE_LLAMA" \
	"$read_vcxproj" "$vcxproj" --field defines
lacks "%(PreprocessorDefinitions) is not passed to the compiler" "%(" \
	"$read_vcxproj" "$vcxproj" --field defines
# Capitalising a guess at what MSBuild means is the whole failure mode here, so
# each of these says what the wrong answer would look like.
succeeds_with "a ** glob reaches a nested source" "src/deep/two.c" \
	"$read_vcxproj" "$vcxproj" --field sources.c
succeeds_with "C is separated from C++" "src/keep.cpp" \
	"$read_vcxproj" "$vcxproj" --field sources.cpp
lacks "an Exclude is honoured" "generated.cpp" \
	"$read_vcxproj" "$vcxproj" --field sources.cpp
lacks "a .c file is not listed among the C++ ones" "one.c" \
	"$read_vcxproj" "$vcxproj" --field sources.cpp
# README's gotcha list, item 1: C++/WinRT below C++20 reaches for
# <experimental/coroutine>, whose first line is an #error refusing clang.
# 10.0.22621.0 is not a number, and MSBuild compares it as a version. A project
# gates real settings on this, so getting it wrong changes what is compiled.
succeeds_with "a version comparison decides a define" "MODERN_SDK=yes" \
	"$read_vcxproj" "$vcxproj" --field defines
lacks "and the branch it excludes stays out" "ANCIENT" \
	"$read_vcxproj" "$vcxproj" --field defines
# The C++/WinRT package guards a comparison that has no answer with a string
# test. Evaluating both sides refuses a project Microsoft ships and that builds.
succeeds_with "and/or short-circuit, so a guarded comparison is never asked" "GUARDED=yes" \
	"$read_vcxproj" "$vcxproj" --field defines
# $(MSBuildToolsVersion) is the project's own ToolsVersion attribute; left empty
# it would turn that guard into a comparison against nothing.
succeeds_with "a .targets is listed rather than passed over quietly" "package.targets" \
	"$read_vcxproj" "$vcxproj" --field skipped
lacks "and nothing it defines reaches the build" "PackageDir" \
	"$read_vcxproj" "$vcxproj" --json
succeeds_with "stdcpp17 is overridden to c++20, not honoured" "c++20" \
	"$read_vcxproj" "$vcxproj" --field std.cxx
succeeds_with "the C standard comes from LanguageStandard_C" "c11" \
	"$read_vcxproj" "$vcxproj" --field std.c
succeeds_with "the Release ItemDefinitionGroup applies" "/O2" \
	"$read_vcxproj" "$vcxproj" --field options
lacks "and the Debug one does not" "/Od" \
	"$read_vcxproj" "$vcxproj" --field options
succeeds_with "--config Debug picks the other one" "/Od" \
	"$read_vcxproj" "$vcxproj" --config Debug --field options
# The DLL runtimes cannot work in an app container: the store CRT import
# libraries do not exist to link against, so /MD would import the desktop
# VCRUNTIME140.dll and activation dies as 0x80270300 (README's gotcha list,
# item 19). The one place the evaluator changes MSBuild's answer instead of
# mirroring or refusing it — both branches are pinned here.
succeeds_with "the DLL runtime is made static inside an app container" "/MT" \
	"$read_vcxproj" "$vcxproj" --field options
# /MT is a substring of /MTd: without the negative, a Release build handed the
# debug runtime would pass the positive check above.
lacks "and it is the release runtime, not the debug one" "/MTd" \
	"$read_vcxproj" "$vcxproj" --field options
lacks "and /MD does not survive" "/MD" \
	"$read_vcxproj" "$vcxproj" --field options
succeeds_with "the Debug runtime likewise" "/MTd" \
	"$read_vcxproj" "$vcxproj" --config Debug --field options
# A global property wins over the file, so the passthrough branch needs no
# second fixture: outside the container the DLL runtime is honoured.
succeeds_with "outside the container the DLL runtime is honoured" "/MD" \
	"$read_vcxproj" "$vcxproj" --property AppContainerApplication=false --field options
lacks "as the release runtime, not the debug one" "/MDd" \
	"$read_vcxproj" "$vcxproj" --property AppContainerApplication=false --field options
# Store /MD is opt-in (UWP_STORE_CRT=1) even when fetch-vclibs output is on
# disk: default remains /MT so filesystem-heavy apps do not hit the
# libcpmt MT vs /MD FAILIFMISMATCH (gotcha 21). Empty files are enough for
# the presence probe; generation itself runs only in the manual workflow.
vclibs="$(mktemp -d)"
mkdir -p "$vclibs/lib/x86_64"
touch "$vclibs/lib/x86_64/vcruntime140_app.lib" "$vclibs/lib/x86_64/msvcp140_app.lib"
succeeds_with "without UWP_STORE_CRT the container stays on /MT" "/MT" \
	env UWP_VCLIBS_ROOT="$vclibs" "$read_vcxproj" "$vcxproj" --field options
succeeds_with "and store_crt stays false by default" "false" \
	env UWP_VCLIBS_ROOT="$vclibs" "$read_vcxproj" "$vcxproj" --field store_crt
succeeds_with "/MD is honoured when store CRT is there and UWP_STORE_CRT=1" "/MD" \
	env UWP_VCLIBS_ROOT="$vclibs" UWP_STORE_CRT=1 "$read_vcxproj" "$vcxproj" --field options
lacks "and the static override stays out under the opt-in" "/MT" \
	env UWP_VCLIBS_ROOT="$vclibs" UWP_STORE_CRT=1 "$read_vcxproj" "$vcxproj" --field options
succeeds_with "and the project says store_crt under the opt-in" "true" \
	env UWP_VCLIBS_ROOT="$vclibs" UWP_STORE_CRT=1 "$read_vcxproj" "$vcxproj" --field store_crt
succeeds_with "--flags carries --store-crt under the opt-in" "--store-crt" \
	env UWP_VCLIBS_ROOT="$vclibs" UWP_STORE_CRT=1 "$read_vcxproj" "$vcxproj" --flags
# A half-generated cache is exactly what a presence probe gets wrong, so the
# probe wants both libraries: one alone still means the static fallback even
# with UWP_STORE_CRT=1.
rm "$vclibs/lib/x86_64/msvcp140_app.lib"
succeeds_with "half a cache still means the static fallback" "/MT" \
	env UWP_VCLIBS_ROOT="$vclibs" UWP_STORE_CRT=1 "$read_vcxproj" "$vcxproj" --field options
succeeds_with "and the project says that too" "false" \
	env UWP_VCLIBS_ROOT="$vclibs" UWP_STORE_CRT=1 "$read_vcxproj" "$vcxproj" --field store_crt
rm -rf "$vclibs"
# Rows the default Visual Studio template emits: RTTI off, and the Release
# linker's /opt pair — lld-link implements both.
succeeds_with "RuntimeTypeInfo false is /GR-" "/GR-" \
	"$read_vcxproj" "$vcxproj" --field options
succeeds_with "the template's Release link settings become /opt" "/opt:ref" \
	"$read_vcxproj" "$vcxproj" --field link.options
succeeds_with "COMDAT folding likewise" "/opt:icf" \
	"$read_vcxproj" "$vcxproj" --field link.options
lacks "a Debug build asks for neither" "/opt:" \
	"$read_vcxproj" "$vcxproj" --config Debug --field link.options
succeeds_with "ObjectFileName and MultiProcessorCompilation are dropped" "/EHa" \
	"$read_vcxproj" "$vcxproj" --field options
succeeds_with "the manifest whose condition holds is the one chosen" "AppxManifest.xml" \
	"$read_vcxproj" "$vcxproj" --field manifest
succeeds_with "a DeploymentContent file keeps its package-relative target" "thirdparty.dll" \
	"$read_vcxproj" "$vcxproj" --field deploy
succeeds_with "an Image ships without asking to" "Assets/StoreLogo.png" \
	"$read_vcxproj" "$vcxproj" --field deploy
# A native NuGet payload is architecture-specific, and it is the project's own
# $(Platform) condition that selects it — evaluation, not a hardcoded path.
lacks "an arch-specific payload is absent by default" "payload-arm64" \
	"$read_vcxproj" "$vcxproj" --field deploy
succeeds_with "--platform ARM64 lets the project's own condition select it" "payload-arm64" \
	"$read_vcxproj" "$vcxproj" --platform ARM64 --field deploy
# A ProjectReference can be gated on a property, and MSBuild's /p: is the only
# way to reach it — without --property the reference does not exist at all.
lacks "a gated ProjectReference is absent by default" "library.vcxproj" \
	"$read_vcxproj" "$vcxproj" --field references
succeeds_with "--property reaches it, as MSBuild's /p: does" "library.vcxproj" \
	"$read_vcxproj" "$vcxproj" --property Backend=llamacpp --field references
fails_with "--property wants NAME=VALUE" "NAME=VALUE" \
	"$read_vcxproj" "$vcxproj" --property Backend
fails_with "an unknown field is refused" "no such field" \
	"$read_vcxproj" "$vcxproj" --field sources.rust

echo "read-vcxproj.py refuses what it cannot reproduce"
# Each of these is a way a build could silently stop matching the one MSBuild
# produces. The error has to name the thing, not the file in general.
refused="$here/fixtures/refused"
fails_with "a property only Visual Studio supplies" "supplied by Visual Studio" \
	"$read_vcxproj" "$refused/reserved-property.vcxproj"
fails_with "a compiler setting outside the mapping table" "EnableEnhancedInstructionSet" \
	"$read_vcxproj" "$refused/unknown-metadata.vcxproj"
fails_with "a condition calling a function it does not implement" "not a comparison" \
	"$read_vcxproj" "$refused/unknown-condition.vcxproj"
fails_with "an ordering asked of something that has none" "neither a number nor a version" \
	"$read_vcxproj" "$refused/non-numeric-comparison.vcxproj"
fails_with "a target that produces a file" "<Copy>" \
	"$read_vcxproj" "$refused/target-with-task.vcxproj"
fails_with "a project type nothing here has ever built" "DynamicLibrary" \
	"$read_vcxproj" "$refused/dynamic-library.vcxproj"
fails_with "C++/CX, which is a different language" "C++/CX" \
	"$read_vcxproj" "$refused/compile-as-winrt.vcxproj"
fails_with "a linker asked to write the winmd" "gen-projection.sh" \
	"$read_vcxproj" "$refused/generate-winmd.vcxproj"
fails_with "a project that is not there" "no such project" \
	"$read_vcxproj" "$refused/absent.vcxproj"
# The OS activates what the manifest names. A package whose executable is called
# something else installs, then fails to launch, and reads as an application bug.
fails_with "a manifest that starts another executable" "would install and fail to launch" \
	"$read_vcxproj" "$refused/mismatched-executable.vcxproj"
# The manifest is copied into the layout verbatim, so an ARM64 build of an x64
# manifest would ship its executable under an identity claiming the wrong
# architecture. Same manifest, matching platform: no refusal.
fails_with "a manifest whose architecture is not the platform's" "ProcessorArchitecture" \
	"$read_vcxproj" "$refused/mismatched-architecture.vcxproj" --platform ARM64
succeeds_with "the same manifest under the platform it names" "fixture.exe" \
	"$read_vcxproj" "$refused/mismatched-architecture.vcxproj" --field executable

echo "build-project.sh guards"
fails_with "--project and --out are required" "--project and --out are required" \
	"$scripts/build-project.sh" --project "$vcxproj"
fails_with "a project directory is sent to build-app.sh" "build-app.sh" \
	"$scripts/build-project.sh" --project "$here/fixtures" --out /tmp/nowhere
fails_with "and so is a file that is not a .vcxproj" "build-app.sh" \
	"$scripts/build-project.sh" --project "$here/run-tests.sh" --out /tmp/nowhere
fails_with "what read-vcxproj.py refuses, this refuses" "DynamicLibrary" \
	"$scripts/build-project.sh" --project "$refused/dynamic-library.vcxproj" \
	--out /tmp/nowhere
fails_with "--out inside the project directory is refused" "must be outside" \
	"$scripts/build-project.sh" --project "$vcxproj" \
	--out "$here/fixtures/evaluation/layout"
rm -rf "$here/fixtures/evaluation/layout"
# A StaticLibrary is built as somebody's reference, never on its own: it has no
# manifest and produces no package.
fails_with "a library is not a package" "Only an Application" \
	"$scripts/build-project.sh" --project "$here/fixtures/evaluation/library.vcxproj" \
	--out /tmp/nowhere
# The platform picks the compiler target as well as the MSBuild conditions;
# one this cannot compile for has to stop here, not link x64 objects under
# another platform's settings.
fails_with "a platform nothing here can compile for" "x64 or ARM64" \
	"$scripts/build-project.sh" --project "$vcxproj" --platform Win32 \
	--out /tmp/nowhere
# Both front doors share platform_env, and both refuse the same contradiction.
fails_with "--platform typed out refuses a contradicting environment" "Drop the override" \
	env UWP_ARCH_DIR=x86_64 \
	"$scripts/build-project.sh" --project "$vcxproj" --platform ARM64 \
	--out /tmp/nowhere
# A store-CRT build whose manifest does not admit the VCLibs dependency is
# refused before the compile: nothing later objects — the Device Portal
# registers the package, and the loader fails the launch as 0x80070002,
# naming nothing.
vclibs="$(mktemp -d)"
deps_out="$(mktemp -d)"
mkdir -p "$vclibs/lib/x86_64"
touch "$vclibs/lib/x86_64/vcruntime140_app.lib" "$vclibs/lib/x86_64/msvcp140_app.lib"
fails_with "a store-CRT manifest must declare the VCLibs dependency" "PackageDependency" \
	env UWP_VCLIBS_ROOT="$vclibs" UWP_STORE_CRT=1 \
	"$scripts/build-project.sh" --project "$vcxproj" \
	--no-restore --out "$deps_out/layout"
# The store-flavour manifest declares it: the check passes, and the run dies
# later, on the toolchain this environment does not have.
lacks "a manifest that declares it passes the check" "PackageDependency" \
	env UWP_VCLIBS_ROOT="$vclibs" UWP_STORE_CRT=1 \
	UWP_SDK_ROOT=/nonexistent UWP_XWIN_ROOT=/nonexistent \
	"$scripts/build-project.sh" --project "$vcxproj" --property StoreSku=true \
	--no-restore --out "$deps_out/layout"
rm -rf "$vclibs" "$deps_out"
# The winmd is named after the namespace the .idl declares — the manifest's
# EntryPoint is resolved against <namespace>.winmd — so an .idl declaring none
# stops the build here, not on a package that installs and fails to launch.
nameless_out="$(mktemp -d)"
fails_with "an idl with no namespace cannot name the winmd" "declares no namespace" \
	"$scripts/build-project.sh" --project "$here/fixtures/evaluation/nameless.vcxproj" \
	--out "$nameless_out"
rm -rf "$nameless_out"

echo "the example project reads as the directory build-app.sh builds"
# examples/hello-uwp carries the project twice — the directory build-app.sh
# reads, and the .vcxproj build-project.sh reads. These pin the second form to
# the first, so the evaluator is exercised against a project that is actually
# in the repository rather than only against the corpus outside it.
example="$here/../examples/hello-uwp/hello-uwp.vcxproj"
succeeds_with "the manifest and the project agree on hello.exe" "hello.exe" \
	"$read_vcxproj" "$example" --field executable
succeeds_with "the assets arrive through the glob" "Assets/StoreLogo.png" \
	"$read_vcxproj" "$example" --field deploy
succeeds_with "Visual Studio's stdcpp17 is overridden to c++20" "c++20" \
	"$read_vcxproj" "$example" --field std.cxx
succeeds_with "the pch is the one build-app.sh would precompile" "pch.h" \
	"$read_vcxproj" "$example" --field pch
succeeds_with "--flags speaks clang-cl" "/O2" \
	"$read_vcxproj" "$example" --flags
# A source added to the directory and not to the .vcxproj (or the reverse)
# builds two different applications under the same name.
assert "the .vcxproj lists exactly the sources the directory holds" \
	"vcxproj: $("$read_vcxproj" "$example" --field sources.cpp | sort | tr '\n' ' ') dir: $(cd "$here/../examples/hello-uwp" && printf '%s ' *.cpp)" \
	test "$("$read_vcxproj" "$example" --field sources.cpp | sort)" \
	= "$(cd "$here/../examples/hello-uwp" && printf '%s\n' *.cpp)"

echo "run-on-device.sh guards"
# Nothing here reaches a console: what is under test is argument validation and
# the configuration error, which has to name all three variables — a partial
# configuration otherwise surfaces as an authentication failure blamed on the
# device.
fails_with "--layout or --package is required" "--layout or --package is required" \
	"$scripts/run-on-device.sh"
fails_with "and not both" "exclusive" \
	"$scripts/run-on-device.sh" --layout /tmp --package /tmp/x.msix
fails_with "a layout that is not there" "no such layout" \
	"$scripts/run-on-device.sh" --layout /nonexistent
fails_with "a layout without a manifest is not a layout" "AppxManifest.xml" \
	"$scripts/run-on-device.sh" --layout "$here/fixtures"
fails_with "an unconfigured device names every variable it needs" "OPENAPPX_DEVICE_PASSWORD" \
	env -u UWP_DEVICE_URL -u UWP_DEVICE_USER -u OPENAPPX_DEVICE_PASSWORD \
	UWP_DEVICE_ENV=/nonexistent \
	"$scripts/run-on-device.sh" --package "$here/run-tests.sh"
# openappx before 0.6.3 builds the launch request wrong (double-underscore
# AUMID, no package parameter) and every start fails as 0x8D160120; those
# releases also predate --version, so "unknown command" means "too old". The
# stubs stand in for each generation; the device is never reached.
stub="$(mktemp -d)"
device=(UWP_DEVICE_URL=https://device UWP_DEVICE_USER=u OPENAPPX_DEVICE_PASSWORD=p)
cat >"$stub/openappx" <<'EOF'
#!/bin/sh
echo "unknown command: $1" >&2; exit 2
EOF
chmod +x "$stub/openappx"
fails_with "an openappx that predates --version is refused" "predates 0.6.3" \
	env "${device[@]}" PATH="$stub:$PATH" "$scripts/run-on-device.sh" --package "$here/run-tests.sh"
cat >"$stub/openappx" <<'EOF'
#!/bin/sh
echo "openappx 0.6.2"
EOF
fails_with "openappx 0.6.2 is refused, naming the failure it causes" "0x8D160120" \
	env "${device[@]}" PATH="$stub:$PATH" "$scripts/run-on-device.sh" --package "$here/run-tests.sh"
cat >"$stub/openappx" <<'EOF'
#!/bin/sh
case "$1" in
--version) echo "openappx 0.6.3" ;;
*) echo "stub: past the version gate" >&2; exit 3 ;;
esac
EOF
fails_with "0.6.3 itself passes the gate" "past the version gate" \
	env "${device[@]}" PATH="$stub:$PATH" "$scripts/run-on-device.sh" --package "$here/run-tests.sh"
rm -rf "$stub"

echo "restore-nuget.sh"
# Nothing here goes to the network: what is under test is the reading of the
# package list and the refusals, not nuget.org.
fails_with "a project or a config is required" "--project or --config is required" \
	"$scripts/restore-nuget.sh"
fails_with "and not both" "exclusive" \
	"$scripts/restore-nuget.sh" --project a.vcxproj --config packages.config
fails_with "a config that is not there" "no such packages.config" \
	"$scripts/restore-nuget.sh" --config /nonexistent/packages.config
tmp="$(mktemp -d)"
printf 'not xml at all\n' >"$tmp/packages.config"
fails_with "a config that is not XML says so" "not readable as XML" \
	"$scripts/restore-nuget.sh" --config "$tmp/packages.config"
printf '<packages><package id="Only.An.Id" /></packages>\n' >"$tmp/packages.config"
fails_with "a package without a version is refused" "without an id and a version" \
	"$scripts/restore-nuget.sh" --config "$tmp/packages.config"
printf '<packages></packages>\n' >"$tmp/packages.config"
succeeds_with "a project with no packages is not an error" "nothing to restore" \
	"$scripts/restore-nuget.sh" --config "$tmp/packages.config"
rm -rf "$tmp"

echo "msvc-compat.h"
compat="$here/../include/msvc-compat.h"
assert "the compat header exists" "build.sh force-includes it" test -f "$compat"
# Order is the point: <version> defines __cpp_lib_coroutine, which winrt/base.h
# tests before it includes <coroutine>. Undo that and IAsyncAction stops being a
# coroutine, with an error that points at the application.
assert "<version> comes before <windows.h>" "wrong order in msvc-compat.h" \
	test "$(grep -n "include <version>" "$compat" | cut -d: -f1)" -lt \
	"$(grep -n "include <windows.h>" "$compat" | cut -d: -f1)"
assert "GetCurrentTime is undefined after windows.h" "no #undef GetCurrentTime" \
	grep -q "^#undef GetCurrentTime" "$compat"
assert "cstdlib APP bridge declares getenv under non-desktop family" "no getenv bridge" \
	grep -q 'char \*__cdecl getenv' "$compat"
assert "cstdlib APP bridge declares system under non-desktop family" "no system bridge" \
	grep -q 'int __cdecl system' "$compat"
# --uwp must set the app family (VS parity). Without it DESKTOP stays true and
# desktop Win32 compiles into AppContainer images (gotcha 22). The cstdlib
# bridge in msvc-compat.h is what makes the family settable (gotcha 7).
assert "--uwp sets WINAPI_FAMILY=WINAPI_FAMILY_APP" "APP family not set for --uwp" \
	grep -q 'extra+=(/DWINAPI_FAMILY=WINAPI_FAMILY_APP)' "$scripts/build.sh"
if grep -qF 'extra+=(/DNOGDI)' "$scripts/build.sh"; then
	no "--uwp no longer substitutes NOGDI for the app family" "NOGDI workaround still present"
else
	ok "--uwp no longer substitutes NOGDI for the app family"
fi
# The header is force-included into every translation unit, C ones included, and
# <version> is a C++ header: a C source stopped on "'version' file not found",
# blaming a file the project never included. Neither compile can succeed here —
# there is no CRT on a build host — so what is checked is which error arrives.
if ! command -v clang-cl >/dev/null; then
	skip "a C translation unit does not see <version>" "clang-cl is not installed"
else
	tmp="$(mktemp -d)"
	printf 'int f(void) { return 0; }\n' >"$tmp/c.c"
	printf 'int f() { return 0; }\n' >"$tmp/cpp.cpp"
	lacks "a C translation unit does not see <version>" "'version' file not found" \
		clang-cl -target x86_64-pc-windows-msvc /std:c11 "/FI$compat" \
		/c "$tmp/c.c" -o "$tmp/c.obj"
	fails_with "a C++ one does" "'version' file not found" \
		clang-cl -target x86_64-pc-windows-msvc /std:c++20 "/FI$compat" \
		/c "$tmp/cpp.cpp" -o "$tmp/cpp.obj"
	rm -rf "$tmp"
fi
# Full xwin path: APP family + force-included bridge must compile <cstdlib>.
# Without the bridge the STL using of getenv/system fails (gotcha 7).
xwin_root="${UWP_XWIN_ROOT:-$HOME/.cache/uwp-crossbuild/xwin}"
if ! command -v clang-cl >/dev/null; then
	skip "APP family compiles <cstdlib> with the bridge" "clang-cl is not installed"
elif [[ ! -d "$xwin_root/crt/include" || ! -d "$xwin_root/sdk/include/ucrt" ]]; then
	skip "APP family compiles <cstdlib> with the bridge" "xwin CRT not at $xwin_root"
else
	tmp="$(mktemp -d)"
	printf '#include <cstdlib>\nint f() { return 0; }\n' >"$tmp/app_cstdlib.cpp"
	succeeds_with "APP family compiles <cstdlib> with the bridge" "" \
		clang-cl -target x86_64-pc-windows-msvc /std:c++20 \
		/DWINAPI_FAMILY=WINAPI_FAMILY_APP "/FI$compat" \
		/imsvc "$xwin_root/crt/include" \
		/imsvc "$xwin_root/sdk/include/ucrt" \
		/imsvc "$xwin_root/sdk/include/um" \
		/imsvc "$xwin_root/sdk/include/shared" \
		/c "$tmp/app_cstdlib.cpp" -o "$tmp/app_cstdlib.obj"
	# Negative control: same TU without the bridge must still fail.
	fails_with "APP family without the bridge still breaks <cstdlib>" "getenv" \
		clang-cl -target x86_64-pc-windows-msvc /std:c++20 \
		/DWINAPI_FAMILY=WINAPI_FAMILY_APP \
		/imsvc "$xwin_root/crt/include" \
		/imsvc "$xwin_root/sdk/include/ucrt" \
		/imsvc "$xwin_root/sdk/include/um" \
		/imsvc "$xwin_root/sdk/include/shared" \
		/c "$tmp/app_cstdlib.cpp" -o "$tmp/app_cstdlib_nobridge.obj"
	# Partition itself: DESKTOP must be false under APP (GDI / RegOpen gated).
	printf '#include <windows.h>\n#if WINAPI_FAMILY_PARTITION(WINAPI_PARTITION_DESKTOP)\n#error desktop\n#endif\nint x;\n' \
		>"$tmp/partition.cpp"
	succeeds_with "APP family makes DESKTOP partition false" "" \
		clang-cl -target x86_64-pc-windows-msvc /std:c++20 \
		/DWINAPI_FAMILY=WINAPI_FAMILY_APP "/FI$compat" \
		/imsvc "$xwin_root/crt/include" \
		/imsvc "$xwin_root/sdk/include/ucrt" \
		/imsvc "$xwin_root/sdk/include/um" \
		/imsvc "$xwin_root/sdk/include/shared" \
		/c "$tmp/partition.cpp" -o "$tmp/partition.obj"
	rm -rf "$tmp"
fi

echo "pe-import-audit.sh"
audit="$scripts/pe-import-audit.sh"
tmp="$(mktemp -d)"
touch "$tmp/app.exe"
# The audit reads the PE only through llvm-readobj, so a stub on PATH turns
# canned reader output into a fixture — no toolchain, no real PE. The stub
# speaks the reader's actual format ("Name:", "Symbol: name (hint)",
# subsystem fields), which is exactly what the parsing under test has to match.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/llvm-readobj" <<'EOF'
#!/bin/sh
case "$1" in
--file-headers) cat "${AUDIT_HEADERS:?}" ;;
--coff-imports) cat "${AUDIT_IMPORTS:?}" ;;
esac
EOF
chmod +x "$tmp/bin/llvm-readobj"
cat >"$tmp/h_clean" <<'EOF'
  MajorSubsystemVersion: 6
  MinorSubsystemVersion: 2
  DLLCharacteristics [ (0x1100)
    IMAGE_DLL_CHARACTERISTICS_APPCONTAINER (0x1000)
  ]
EOF
cat >"$tmp/h_600" <<'EOF'
  MajorSubsystemVersion: 6
  MinorSubsystemVersion: 0
  DLLCharacteristics [ (0x1100)
    IMAGE_DLL_CHARACTERISTICS_APPCONTAINER (0x1000)
  ]
EOF
cat >"$tmp/h_nobit" <<'EOF'
  MajorSubsystemVersion: 6
  MinorSubsystemVersion: 2
  DLLCharacteristics [ (0x100)
  ]
EOF
cat >"$tmp/i_clean" <<'EOF'
Import {
  Name: api-ms-win-core-com-l1-1-0.dll
  Symbol: CoInitializeEx (12)
}
Import {
  Name: KERNELBASE.dll
  Symbol: EncodePointer (612)
}
EOF
cat >"$tmp/i_reg" <<'EOF'
Import {
  Name: ADVAPI32.dll
  Symbol: RegOpenKeyExW (700)
}
EOF
cat >"$tmp/i_msvcp" <<'EOF'
Import {
  Name: msvcp140.dll
  Symbol: ?_Facet_Register@std@@YAXPEAV_Facet_base@1@@Z (1)
}
EOF
cat >"$tmp/i_k32" <<'EOF'
Import {
  Name: KERNEL32.dll
  Symbol: GetTickCount64 (500)
}
EOF
with_pe() { # with_pe <headers fixture> <imports fixture> <audit args...>
	local headers="$1" imports="$2"
	shift 2
	env PATH="$tmp/bin:$PATH" AUDIT_HEADERS="$tmp/$headers" \
		AUDIT_IMPORTS="$tmp/$imports" "$audit" "$@" "$tmp/app.exe"
}
succeeds_with "a clean PE passes" "pe-import-audit: OK" \
	with_pe h_clean i_clean
fails_with "a banlist symbol is fatal" "FORBIDDEN symbol: RegOpenKeyExW" \
	with_pe h_clean i_reg
# The DLL name in the PE is whatever the import library carried, so case must
# not hide a desktop CRT.
fails_with "a desktop CRT DLL is fatal whatever its case" "MSVCP140.dll" \
	with_pe h_clean i_msvcp
fails_with "raw KERNEL32.dll is fatal by default" "FORBIDDEN dll: KERNEL32.dll" \
	with_pe h_clean i_k32
succeeds_with "--allow-kernel32 keeps it a smell, not a failure" "pe-import-audit: OK" \
	with_pe h_clean i_k32 --allow-kernel32
fails_with "subsystem 6.00 is fatal" "FORBIDDEN subsystem version: 6.00" \
	with_pe h_600 i_clean
fails_with "a missing AppContainer bit is fatal" "APPCONTAINER" \
	with_pe h_nobit i_clean
# Apiset names vary by SDK, so the banlist extends without editing the script.
fails_with "UWP_AUDIT_FORBID extends the banlist" "FORBIDDEN symbol: CoInitializeEx" \
	env UWP_AUDIT_FORBID="CoInitializeEx" PATH="$tmp/bin:$PATH" \
	AUDIT_HEADERS="$tmp/h_clean" AUDIT_IMPORTS="$tmp/i_clean" \
	"$audit" "$tmp/app.exe"
# "Cannot audit" is exit 2, never the verdict's exit 1: a PE the reader cannot
# open must not read as a clean or a forbidden one.
fails_with "an unreadable PE is 'cannot audit', not a verdict" "could not read PE headers" \
	env PATH="$tmp/bin:$PATH" AUDIT_HEADERS=/dev/null AUDIT_IMPORTS="$tmp/i_clean" \
	"$audit" "$tmp/app.exe"
fails_with "a missing file says so" "no such file" "$audit" /nonexistent/app.exe
fails_with "no PE at all is an error, not a verdict" "usage:" "$audit"
rm -rf "$tmp"
# Both front doors run the gate on the PE they just linked, fail-closed with
# the documented opt-out.
for door in build-app.sh build-project.sh; do
	assert "$door runs the audit after the link" "no pe-import-audit call" \
		grep -q 'pe-import-audit.sh" --allow-kernel32' "$scripts/$door"
	assert "and $door has the opt-out" "no UWP_SKIP_IMPORT_AUDIT gate" \
		grep -q 'UWP_SKIP_IMPORT_AUDIT' "$scripts/$door"
done

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[[ $failed -eq 0 ]]
