#!/usr/bin/env bash
# check-deps.sh — report which prerequisites are present, before a long download.
set -uo pipefail

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

echo
if wine reg query 'HKCU\Software\Wine\DllOverrides' 2>/dev/null | grep -qi msxml6; then
	printf '  \033[32m✓\033[0m %-12s overridden in this prefix\n' msxml6
else
	# Counted as missing like everything else: makepri fails without it, and a
	# report that exits 0 while naming a prerequisite it lacks is not a report.
	printf '  \033[31m✗\033[0m %-12s run: winetricks -q msxml6\n' msxml6
	missing+=(msxml6)
fi

if [[ ${#missing[@]} -gt 0 ]]; then
	echo
	echo "Missing: ${missing[*]}"
	exit 1
fi
