#!/usr/bin/env bash
# check-deps.sh — report which prerequisites are present, before a long download.
set -uo pipefail

ok=0
missing=()

check() { # name, command, why
	if command -v "$2" >/dev/null 2>&1; then
		printf '  \033[32m✓\033[0m %-12s %s\n' "$1" "$($2 --version 2>/dev/null | head -1 | cut -c1-46)"
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
check 7z 7z "unpacks the NuGet and SDK payloads"
check curl curl "downloads them"
check xwin xwin "CRT and SDK headers/libraries"
check winetricks winetricks "installs msxml6, which makepri needs"

echo
if wine reg query 'HKCU\Software\Wine\DllOverrides' 2>/dev/null | grep -qi msxml6; then
	printf '  \033[32m✓\033[0m %-12s overridden in this prefix\n' msxml6
else
	printf '  \033[31m✗\033[0m %-12s run: winetricks -q msxml6\n' msxml6
fi

if [[ ${#missing[@]} -gt 0 ]]; then
	echo
	echo "Missing: ${missing[*]}"
	exit 1
fi
