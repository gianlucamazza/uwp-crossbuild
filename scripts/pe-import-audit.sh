#!/usr/bin/env bash
# pe-import-audit.sh — fail a PE that imports symbols known to break Xbox AppContainer launch.
#
# Usage:
#   pe-import-audit.sh path/to/app.exe
#   pe-import-audit.sh --allow-kernel32 path/to/app.exe   # softer: banlist symbols only
#
# Exit 0 = clean enough; exit 1 = forbidden imports present.
# Requires llvm-readobj (ships with LLVM next to clang-cl).
set -euo pipefail

allow_kernel32=0
exe=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--allow-kernel32) allow_kernel32=1; shift ;;
	-h | --help)
		sed -n '2,12p' "$0"
		exit 0
		;;
	*)
		exe="$1"
		shift
		;;
	esac
done

[[ -n "$exe" && -f "$exe" ]] || {
	echo "usage: $0 [--allow-kernel32] path/to/app.exe" >&2
	exit 2
}
command -v llvm-readobj >/dev/null || {
	echo "llvm-readobj not found (install LLVM / clang)" >&2
	exit 2
}

# Symbols repeatedly observed on xllama crossbuild PE that fail Xbox activation
# (0x8027025b / loader), and that CI MSVC APP-CRT images do not import.
# Extend carefully — apiset names vary by SDK.
forbidden_syms=(
	RegOpenKeyExA
	RegOpenKeyExW
	RegOpenKeyA
	RegOpenKeyW
	RegQueryValueExA
	RegQueryValueExW
	RegCloseKey
	SetThreadAffinityMask
)

imports=$(llvm-readobj --coff-imports "$exe" 2>/dev/null || true)
[[ -n "$imports" ]] || {
	echo "error: could not read COFF imports from $exe" >&2
	exit 2
}

bad=0
echo "pe-import-audit: $exe"
for sym in "${forbidden_syms[@]}"; do
	if grep -qE "Symbol: ${sym}( |\$)" <<<"$imports" || grep -q " $sym " <<<"$imports"; then
		echo "  FORBIDDEN symbol: $sym"
		bad=1
	fi
done

# Raw KERNEL32.dll is a smell for desktop CRT / missing apiset routing (gotcha 18).
# Soft-allow for interim builds that still need it for benign symbols.
if [[ $allow_kernel32 -eq 0 ]]; then
	if grep -qE 'Name: KERNEL32\.dll' <<<"$imports"; then
		echo "  FORBIDDEN dll: KERNEL32.dll (prefer apiset / KERNELBASE; use --allow-kernel32 to soft-pass)"
		bad=1
	fi
fi

# Desktop CRT (not APP) — cannot resolve in AppContainer.
for dll in MSVCP140.dll VCRUNTIME140.dll VCRUNTIME140_1.dll; do
	if grep -qE "Name: ${dll}" <<<"$imports"; then
		echo "  FORBIDDEN dll: $dll (use store APP CRT or static /MT app-container path)"
		bad=1
	fi
done

if [[ $bad -ne 0 ]]; then
	echo "pe-import-audit: FAIL — package may install but refuse activation (e.g. 0x8027025b)"
	exit 1
fi
echo "pe-import-audit: OK"
exit 0
