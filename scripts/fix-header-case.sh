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
set -euo pipefail

target="${1:?usage: $0 <directory> [--lower|--canonical]}"
mode="${2:---lower}"
[[ -d "$target" ]] || {
	echo "error: no such directory: $target" >&2
	exit 1
}

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
    if canonical != path.name and not (directory / canonical).exists():
        os.symlink(path.name, directory / canonical)
        created += 1
print(f"{created} canonical-case aliases in {directory} ({removed} stale removed)")
PY
	;;
*)
	echo "error: unknown mode $mode" >&2
	exit 1
	;;
esac
