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

# A wrong alias from an earlier version of this script must not survive.
ln -s windows.ai.machinelearning.h "$tmp/Windows.Ai.Machinelearning.h"
"$scripts/fix-header-case.sh" "$tmp" --canonical >/dev/null
assert "a stale alias is removed" "Windows.Ai.Machinelearning.h survived" \
	test ! -e "$tmp/Windows.Ai.Machinelearning.h"
assert "rerunning is idempotent" "the correct alias did not come back" \
	test -L "$tmp/Windows.AI.MachineLearning.h"
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
# An archive has no DllCharacteristics to set: /appcontainer belongs to the
# application that links the library, not to the library.
mkdir -p "$tmp/crt/include"
fails_with "--static-lib and --uwp are exclusive" "exclusive" \
	env UWP_XWIN_ROOT="$tmp" "$scripts/build.sh" --static-lib --uwp \
	--out a.lib "$tmp/a.cpp"
rm -rf "$tmp"

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
rm -rf "$tmp" "$elsewhere"

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
# README, "Fourteen things", 1: C++/WinRT below C++20 reaches for
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
succeeds_with "ObjectFileName and MultiProcessorCompilation are dropped" "/EHa" \
	"$read_vcxproj" "$vcxproj" --field options
succeeds_with "the manifest whose condition holds is the one chosen" "AppxManifest.xml" \
	"$read_vcxproj" "$vcxproj" --field manifest
succeeds_with "a DeploymentContent file keeps its package-relative target" "thirdparty.dll" \
	"$read_vcxproj" "$vcxproj" --field deploy
succeeds_with "an Image ships without asking to" "Assets/StoreLogo.png" \
	"$read_vcxproj" "$vcxproj" --field deploy
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
fails_with "a project that is not there" "no such project" \
	"$read_vcxproj" "$refused/absent.vcxproj"
# The OS activates what the manifest names. A package whose executable is called
# something else installs, then fails to launch, and reads as an application bug.
fails_with "a manifest that starts another executable" "would install and fail to launch" \
	"$read_vcxproj" "$refused/mismatched-executable.vcxproj"

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

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[[ $failed -eq 0 ]]
