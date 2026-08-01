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

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/../scripts"
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
# No namespace declaration: nothing to derive an alias from.
echo "// just a comment" >"$tmp/base.h"

"$scripts/fix-header-case.sh" "$tmp" --canonical >/dev/null
assert "compound segments keep their casing" "no Windows.ApplicationModel.DataTransfer.h" \
	test -L "$tmp/Windows.ApplicationModel.DataTransfer.h"
assert "acronyms stay upper-case" "no Windows.AI.MachineLearning.h" \
	test -L "$tmp/Windows.AI.MachineLearning.h"
assert "the alias points at the real file" "wrong link target" \
	is_link_to "$tmp/Windows.AI.MachineLearning.h" windows.ai.machinelearning.h
assert "a header with no namespace gets no alias" "Base.h was created" \
	test ! -e "$tmp/Base.h"

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

echo "build.sh guards"
fails_with "--out is required" "--out is required" "$scripts/build.sh" a.cpp
fails_with "sources are required" "no source files" "$scripts/build.sh" --out a.exe
UWP_XWIN_ROOT=/nonexistent fails_with "a missing CRT names fetch-sdk.sh" "run fetch-sdk.sh" \
	env UWP_XWIN_ROOT=/nonexistent "$scripts/build.sh" --out a.exe a.cpp

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
rm -rf "$tmp"

echo "gen-projection.sh and gen-resources.sh guards"
fails_with "gen-projection needs its arguments" "are required" "$scripts/gen-projection.sh"
tmp="$(mktemp -d)"
fails_with "gen-resources needs a layout with a manifest" "no AppxManifest.xml" \
	"$scripts/gen-resources.sh" --layout "$tmp"
rm -rf "$tmp"

echo "wine-tool.sh"
fails_with "an unknown tool is refused" "usage:" \
	env UWP_SDK_ROOT=/nonexistent "$scripts/wine-tool.sh" notatool

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
