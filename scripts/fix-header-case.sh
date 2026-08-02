#!/usr/bin/env bash
# fix-header-case.sh — alias SDK headers so case-sensitive filesystems resolve them.
#
# Windows filesystems are case-insensitive, so the SDK ships `WinRTBase.idl` and
# code includes `winrtbase.idl` without anyone noticing. Here those are different
# files. xwin fixes this for most of the SDK but not for the C++/WinRT projection
# headers, where `#include <winrt/Windows.Foundation.Collections.h>` meets a file
# named `windows.foundation.collections.h`.
#
#   fix-header-case.sh <directory> [--lower|--canonical]
#
#     --lower      add lowercase aliases   (WinRTBase.idl -> winrtbase.idl)
#     --canonical  add namespace-cased ones (windows.foundation.h -> Windows.Foundation.h)
#     --help       this text
set -euo pipefail

# Resolve through symlinks: an installed command is a symlink in bin/, and the
# scripts find their siblings, common.sh and include/msvc-compat.h relative to
# themselves — which has to be the real directory, not ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=scripts/common.sh
. "$here/common.sh"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

# ${1:?…} would report this as a shell error naming a line number. Everything
# else here says "error: …" and names the fix.
[[ $# -ge 1 ]] || die "a directory is required — see --help"
target="$1"
mode="${2:---lower}"
[[ -d "$target" ]] || die "no such directory: $target"

case "$mode" in
--lower)
	created=0
	cd "$target"
	for f in *; do
		[[ -f "$f" ]] || continue
		lower="${f,,}"
		if [[ "$f" != "$lower" && ! -e "$lower" ]]; then
			ln -s "$f" "$lower"
			created=$((created + 1))
		fi
	done
	echo "$created lowercase aliases in $target"
	;;
--canonical)
	python3 - "$target" <<'PY'
import os, pathlib, re, sys

# Projection header names mirror WinRT namespaces, and cppwinrt writes them
# lower-cased: windows.foundation.collections.h. Guessing the capitalisation back
# does not work — ApplicationModel, DataTransfer and every other compound segment
# would come out as Applicationmodel. Read it from the file instead: every
# projection header declares its own namespace, spelled correctly.
NAMESPACE = re.compile(rb"^WINRT_EXPORT namespace winrt::([A-Za-z0-9_:]+)", re.M)

directory = pathlib.Path(sys.argv[1])

# Idempotent: the symlinks in here are ours (xwin ships plain files), so drop
# them before rebuilding, or a wrong alias from an earlier run would survive.
removed = 0
for path in sorted(directory.iterdir()):
    if path.is_symlink():
        path.unlink()
        removed += 1

created = 0
for path in sorted(directory.iterdir()):
    if not path.is_file() or path.suffix != ".h":
        continue
    match = NAMESPACE.search(path.read_bytes())
    if not match:
        continue
    canonical = match.group(1).decode().replace("::", ".") + ".h"
    # The namespace is only allowed to fix the *casing* of this file's own name.
    # Without that check base.h wins Windows.Foundation.h, because it forward-
    # declares winrt::Windows::Foundation near the top and sorts first — and the
    # real windows.foundation.h, the one holding box_value, then has no alias at
    # all. That failure looks like a missing function, not a bad symlink.
    if canonical.lower() != path.name.lower():
        continue
    if canonical != path.name and not (directory / canonical).exists():
        os.symlink(path.name, directory / canonical)
        created += 1
print(f"{created} canonical-case aliases in {directory} ({removed} stale removed)")
PY
	;;
*) die "unknown mode $mode — expected --lower or --canonical" ;;
esac
