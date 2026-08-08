#!/usr/bin/env bash
# check-deps.sh — report which prerequisites are present, before a long download.
#
#   check-deps.sh
#
# Takes no arguments. Exits non-zero if anything the toolchain needs is missing,
# so it can gate a build script as well as inform a person.
set -uo pipefail

# Resolve through symlinks: an installed command is a symlink in bin/, and the
# scripts find their siblings, common.sh and include/msvc-compat.h relative to
# themselves — which has to be the real directory, not ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=scripts/common.sh
. "$here/common.sh"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage
[[ $# -eq 0 ]] || {
	echo "error: check-deps.sh takes no arguments" >&2
	exit 1
}

ok=0
missing=()

check() { # name, command, why, [flag that prints a version, default --version]
	if command -v "$2" >/dev/null 2>&1; then
		# 7z has no --version: it prints its banner for any help flag instead,
		# and the check reported an empty version rather than saying so.
		local version
		version="$("$2" "${4:---version}" 2>/dev/null | grep -m1 . | cut -c1-46)"
		printf '  \033[32m✓\033[0m %-12s %s\n' "$1" "${version:-installed}"
		ok=$((ok + 1))
	else
		printf '  \033[31m✗\033[0m %-12s %s\n' "$1" "$3"
		missing+=("$1")
	fi
}

echo "Toolchain:"
check clang-cl clang-cl "compiles for the MSVC ABI"
check lld-link lld-link "links Windows binaries"
check wine wine "runs midlrt / makepri / cppwinrt"
check 7z 7z "unpacks the NuGet and SDK payloads" -h
check curl curl "downloads them"
check xwin xwin "CRT and SDK headers/libraries"
check winetricks winetricks "installs msxml6, which makepri needs"
check python3 python3 "fix-header-case.sh --canonical reads each header's namespace"
# The llvm package proper, beyond clang and lld: every UWP link is followed by
# a fail-closed llvm-readobj audit, so these are prerequisites of an ordinary
# build, not of a corner.
check llvm-readobj llvm-readobj "pe-import-audit.sh reads every UWP PE after its link"
check llvm-dlltool llvm-dlltool "import libraries: --uwp pointer rewrite, fetch-vclibs.sh"
check llvm-lib llvm-lib "archives: --static-lib, store-CRT MD helpers"
check llvm-ar llvm-ar "gen-msvcprt-app-static.sh extracts msvcprt.lib members"
check llvm-nm llvm-nm "and verifies what it extracted"

echo
if wine reg query 'HKCU\Software\Wine\DllOverrides' 2>/dev/null | grep -qi msxml6; then
	printf '  \033[32m✓\033[0m %-12s overridden in this prefix\n' msxml6
else
	# Counted as missing like everything else: makepri fails without it, and a
	# report that exits 0 while naming a prerequisite it lacks is not a report.
	printf '  \033[31m✗\033[0m %-12s run: winetricks -q msxml6\n' msxml6
	missing+=(msxml6)
fi

# Informational, never counted as missing: building needs none of it. It is
# what carries the layout to a console — pack, sign, install, launch — and a
# machine that only compiles is complete without it.
echo
echo "Deploy (optional):"
if command -v openappx >/dev/null 2>&1; then
	version="$(openappx --version 2>/dev/null | grep -m1 . | cut -c1-46)"
	printf '  \033[32m✓\033[0m %-12s %s\n' openappx "${version:-installed}"
else
	printf '  \033[33m-\033[0m %-12s run-on-device.sh packs, signs and deploys with it\n' openappx
fi

if [[ ${#missing[@]} -gt 0 ]]; then
	echo
	echo "Missing: ${missing[*]}"
	exit 1
fi
