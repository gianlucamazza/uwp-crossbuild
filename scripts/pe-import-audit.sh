#!/usr/bin/env bash
# pe-import-audit.sh — fail a PE that would install and then refuse activation.
#
#   pe-import-audit.sh [--allow-kernel32] path/to/app.exe
#
#     --allow-kernel32  do not fail on a raw KERNEL32.dll import. That import is
#                       the smell of desktop CRT / missing apiset routing
#                       (gotcha 18), not one of the proven killers, and
#                       crossbuilt images that launch have carried it.
#                       build-app.sh and build-project.sh audit this way;
#                       run without it for the strict pre-deploy check.
#     --help            this text
#
# The activation contract, all read from the same PE. Each item below has been
# observed — on a Series S dev kit, or against CI MSVC images of the same app —
# to decide between a launch and 0x8027025b:
#
#   - no symbol from the banlist (registry, thread affinity): desktop Win32
#     that compiled into the image or an archive it linked (gotcha 22).
#     UWP_AUDIT_FORBID adds names, whitespace-separated — apiset names vary
#     by SDK, so the list is extendable without editing this file.
#   - no desktop CRT DLL (MSVCP140.dll, VCRUNTIME140*.dll): the app container
#     resolves only the *_app store set (gotcha 19).
#   - subsystem version at least 6.02, the Store baseline build.sh links with;
#     bare /subsystem:windows defaults to 6.00 and has refused activation.
#   - IMAGE_DLL_CHARACTERISTICS_APPCONTAINER (0x1000), or the package is
#     refused outright.
#
# Exit 0 = clean; 1 = forbidden — the package may install but refuse
# activation; 2 = cannot audit (arguments, missing llvm-readobj, unreadable
# PE). llvm-readobj ships with LLVM, beside clang-cl.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=scripts/common.sh
. "$here/common.sh"

# Not die(): its exit 1 is this script's verdict for "forbidden imports", and
# "cannot audit" must stay distinguishable from it.
unable() {
	echo "error: $*" >&2
	exit 2
}

allow_kernel32=0
exe=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--allow-kernel32) allow_kernel32=1 && shift ;;
	-h | --help) usage ;;
	-*) unable "unknown argument: $1" ;;
	*)
		[[ -z "$exe" ]] || unable "one PE at a time: $exe and $1"
		exe="$1"
		shift
		;;
	esac
done

[[ -n "$exe" ]] || unable "usage: $0 [--allow-kernel32] path/to/app.exe"
[[ -f "$exe" ]] || unable "no such file: $exe"
command -v llvm-readobj >/dev/null ||
	unable "llvm-readobj not found — it ships with LLVM, beside clang-cl"

# Symbols repeatedly observed on xllama crossbuild PE that fail Xbox activation
# (0x8027025b / loader), and that CI MSVC APP-CRT images do not import.
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
if [[ -n "${UWP_AUDIT_FORBID:-}" ]]; then
	read -ra extra_syms <<<"$UWP_AUDIT_FORBID"
	forbidden_syms+=("${extra_syms[@]}")
fi

headers=$(llvm-readobj --file-headers "$exe" 2>/dev/null || true)
[[ -n "$headers" ]] || unable "could not read PE headers from $exe"
imports=$(llvm-readobj --coff-imports "$exe" 2>/dev/null || true)
[[ -n "$imports" ]] || unable "could not read COFF imports from $exe"

bad=0
echo "pe-import-audit: $exe"

# llvm-readobj prints each import as "Symbol: Name (hint)".
for sym in "${forbidden_syms[@]}"; do
	if grep -qE "Symbol: ${sym}( |\$)" <<<"$imports"; then
		echo "  FORBIDDEN symbol: $sym"
		bad=1
	fi
done

# Raw KERNEL32.dll is a smell for desktop CRT / missing apiset routing
# (gotcha 18). Case-insensitive: the name in the PE is whatever the import
# library carried.
if [[ $allow_kernel32 -eq 0 ]]; then
	if grep -qiE 'Name: KERNEL32\.dll$' <<<"$imports"; then
		echo "  FORBIDDEN dll: KERNEL32.dll (prefer apiset / KERNELBASE; use --allow-kernel32 to soft-pass)"
		bad=1
	fi
fi

# Desktop CRT (not APP) — cannot resolve in AppContainer.
for dll in MSVCP140.dll VCRUNTIME140.dll VCRUNTIME140_1.dll; do
	if grep -qiE "Name: ${dll//./\\.}\$" <<<"$imports"; then
		echo "  FORBIDDEN dll: $dll (use store APP CRT or static /MT app-container path)"
		bad=1
	fi
done

# Subsystem 6.02 is the Store baseline build.sh links with; a 6.00 image of the
# same app has installed and refused activation while a CI MSVC 6.02 PE
# launched.
major=$(sed -n 's/.*MajorSubsystemVersion: \([0-9]\{1,\}\).*/\1/p' <<<"$headers" | head -1)
minor=$(sed -n 's/.*MinorSubsystemVersion: \([0-9]\{1,\}\).*/\1/p' <<<"$headers" | head -1)
[[ -n "$major" && -n "$minor" ]] || unable "no subsystem version in the PE headers of $exe"
if ((major < 6 || (major == 6 && minor < 2))); then
	echo "  FORBIDDEN subsystem version: $major.$(printf '%02d' "$minor") (link /subsystem:windows,6.02)"
	bad=1
fi

# Without the bit the package is refused at install rather than activation —
# still this contract's to check, being one llvm-readobj call away.
if ! grep -q 'IMAGE_DLL_CHARACTERISTICS_APPCONTAINER' <<<"$headers"; then
	echo "  FORBIDDEN image: no IMAGE_DLL_CHARACTERISTICS_APPCONTAINER (link /appcontainer)"
	bad=1
fi

if [[ $bad -ne 0 ]]; then
	echo "pe-import-audit: FAIL — package may install but refuse activation (e.g. 0x8027025b)"
	exit 1
fi
echo "pe-import-audit: OK"
exit 0
