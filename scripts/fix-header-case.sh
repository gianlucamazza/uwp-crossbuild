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
import os, pathlib, sys

# Projection header names mirror WinRT namespaces, so the canonical spelling is
# the namespace: windows.foundation.collections.h -> Windows.Foundation.Collections.h.
# Segments that are acronyms stay upper-case (Windows.AI.MachineLearning.h).
ACRONYMS = {
    "ai", "ui", "xaml", "api", "ip", "url", "http", "json", "xml", "rss", "sms",
    "nfc", "usb", "gpio", "spi", "i2c", "pwm", "hid", "dns", "ftp", "ssl", "tls",
    "uri", "gui", "cpu", "gpu", "ml", "ar", "vr", "3d", "2d", "hd", "sd", "tv",
    "pc", "os", "io", "db", "id",
}

directory = pathlib.Path(sys.argv[1])
created = 0
for path in sorted(directory.iterdir()):
    if not path.is_file() or path.suffix != ".h":
        continue
    segments = path.name[:-2].split(".")
    canonical = ".".join(
        s.upper() if s.lower() in ACRONYMS else s.capitalize() for s in segments
    ) + ".h"
    if canonical != path.name and not (directory / canonical).exists():
        os.symlink(path.name, directory / canonical)
        created += 1
print(f"{created} canonical-case aliases in {directory}")
PY
	;;
*)
	echo "error: unknown mode $mode" >&2
	exit 1
	;;
esac
