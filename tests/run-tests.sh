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
ln -s windows.applicationmodel.datatransfer.h "$tmp/lowercase.alias.h"
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
rm -rf "$tmp"

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
assert "a refused --out leaves nothing behind" "$tmp/inside was created" \
	test ! -e "$tmp/inside"
# The reverse direction: clearing a stale layout is recursive, so a project
# under --out would be deleted with it — sources and all.
nested="$(mktemp -d)"
cp "$tmp/AppxManifest.xml" "$nested/"
mkdir "$nested/src"
cp "$tmp/app.idl" "$tmp/AppxManifest.xml" "$nested/src/"
fails_with "--project inside --out is refused" "must not live under --out" \
	"$scripts/build-app.sh" --project "$nested/src" --out "$nested"
assert "the nested project kept its sources" "app.idl was deleted" \
	test -f "$nested/src/app.idl"
rm -rf "$nested"
# Symlinks must not defeat the guards: the comparisons are on resolved paths,
# or a layout reached through a link deletes the project inside the real one.
sym="$(mktemp -d)"
mkdir -p "$sym/data/layout/proj"
cp "$tmp/AppxManifest.xml" "$sym/data/layout/"
cp "$tmp/app.idl" "$tmp/AppxManifest.xml" "$sym/data/layout/proj/"
ln -s data "$sym/slink"
fails_with "a symlinked --out cannot hide the project inside it" "must not live under --out" \
	"$scripts/build-app.sh" --project "$sym/data/layout/proj" --out "$sym/slink/layout"
assert "the project behind the symlink kept its sources" "app.idl was deleted" \
	test -f "$sym/data/layout/proj/app.idl"
rm -rf "$sym"
# A directory that is not recognisably a layout is never cleared, whatever
# --out was pointed at.
elsewhere="$(mktemp -d)"
touch "$elsewhere/precious"
fails_with "a non-empty --out with no manifest is not cleared" "refusing to clear it" \
	"$scripts/build-app.sh" --project "$tmp" --out "$elsewhere"
assert "the untouched directory kept its contents" "the file was deleted" \
	test -f "$elsewhere/precious"
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

printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[[ $failed -eq 0 ]]
