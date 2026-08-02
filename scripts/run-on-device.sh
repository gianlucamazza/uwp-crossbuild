#!/usr/bin/env bash
# run-on-device.sh — a package layout onto the console, installed and launched.
#
#   run-on-device.sh --layout /tmp/hello-layout [--pfx FILE] [--no-launch]
#   run-on-device.sh --package app.msix [--no-launch]
#
#     --layout     a layout produced by build-app.sh or build-project.sh;
#                  packed, signed and deployed. Mutually exclusive with:
#     --package    an .msix already packed and signed, deployed as it is
#     --pfx        the signing certificate (default:
#                  ~/.config/uwp-crossbuild/dev.pfx). Its subject must equal
#                  the manifest's Publisher, or the device refuses the package.
#     --no-launch  install only
#     --help       this text
#
# The device half of the configuration is machine-local and never committed:
# ~/.config/uwp-crossbuild/device-env exports UWP_DEVICE_URL, UWP_DEVICE_USER
# and OPENAPPX_DEVICE_PASSWORD, and this script sources it when they are not
# already set. Packing, signing and every Device Portal call go through
# openappx — this script only decides the order and reads the manifest.
set -euo pipefail

# Resolve through symlinks: these scripts locate their siblings and
# include/msvc-compat.h relative to themselves, so a symlink on PATH must point
# back at the real directory rather than at ~/.local/bin.
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=scripts/common.sh
. "$here/common.sh"

CONFIG="${UWP_DEVICE_ENV:-$HOME/.config/uwp-crossbuild/device-env}"

layout=""
package=""
pfx="${UWP_DEVICE_PFX:-$HOME/.config/uwp-crossbuild/dev.pfx}"
launch=1

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage ;;
	--layout) value "$1" $# "${2:-}" && layout="$2" && shift 2 ;;
	--package) value "$1" $# "${2:-}" && package="$2" && shift 2 ;;
	--pfx) value "$1" $# "${2:-}" && pfx="$2" && shift 2 ;;
	--no-launch) launch=0 && shift ;;
	*) die "unknown argument $1" ;;
	esac
done

[[ -n "$layout" || -n "$package" ]] || die "--layout or --package is required"
[[ -z "$layout" || -z "$package" ]] || die "--layout and --package are exclusive"
if [[ -n "$layout" ]]; then
	[[ -d "$layout" ]] || die "no such layout: $layout"
	[[ -f "$layout/AppxManifest.xml" ]] || die "no AppxManifest.xml in $layout —
  this takes what build-app.sh or build-project.sh produced"
else
	[[ -f "$package" ]] || die "no such package: $package"
fi

# The device configuration, from the environment or from the local file. The
# error names all three variables: a partial configuration is the case that
# otherwise surfaces as an authentication failure blamed on the console.
if [[ -z "${UWP_DEVICE_URL:-}" || -z "${UWP_DEVICE_USER:-}" || -z "${OPENAPPX_DEVICE_PASSWORD:-}" ]]; then
	# shellcheck disable=SC1090  # machine-local, deliberately not in the repo
	[[ ! -f "$CONFIG" ]] || . "$CONFIG"
fi
[[ -n "${UWP_DEVICE_URL:-}" && -n "${UWP_DEVICE_USER:-}" && -n "${OPENAPPX_DEVICE_PASSWORD:-}" ]] ||
	die "device not configured: export UWP_DEVICE_URL, UWP_DEVICE_USER and
  OPENAPPX_DEVICE_PASSWORD, or write them in $CONFIG
  (values are in Dev Home -> Remote Access on the console)"

command -v openappx >/dev/null || die "openappx not found — pipx install openappx"

# --insecure is not optional: the Device Portal's certificate is issued by the
# console to itself, so verification against a CA store can never succeed.
portal=(openappx deploy --device "$UWP_DEVICE_URL" --user "$UWP_DEVICE_USER" --insecure)

# One attribute out of an XML file, without pretending this is a parser: the
# values it reads are written by Visual Studio templates and by this
# toolchain, one attribute per line or not — hence python3, not sed.
manifest_attr() { # manifest_attr <file> <element localname> <attribute>
	python3 - "$1" "$2" "$3" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for element in root.iter():
    if element.tag.rsplit("}", 1)[-1] == sys.argv[2] and element.get(sys.argv[3]):
        print(element.get(sys.argv[3]))
        sys.exit(0)
sys.exit(f"error: {sys.argv[1]}: no <{sys.argv[2]} {sys.argv[3]}=...>")
PY
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -n "$layout" ]]; then
	manifest="$layout/AppxManifest.xml"
	[[ -f "$pfx" ]] || die "no signing certificate at $pfx
  Generate one whose subject equals the manifest's Publisher
  ($(manifest_attr "$manifest" Identity Publisher)):
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 365 \\
      -nodes -subj '/CN=...' -addext extendedKeyUsage=codeSigning
    openssl pkcs12 -export -out dev.pfx -inkey key.pem -in cert.pem
  and trust its DER form once: openappx deploy ... --install-cert dev.cer"
	package="$work/$(basename "$layout").msix"
	step "Packing and signing $(basename "$package")"
	openappx validate --root "$layout"
	openappx pack --root "$layout" --out "$package"
	openappx sign --package "$package" --pfx "$pfx"
else
	# The manifest travels inside the package; inspect writes it out.
	openappx unpack --package "$package" --out "$work/unpacked" >/dev/null
	manifest="$work/unpacked/AppxManifest.xml"
fi

identity="$(manifest_attr "$manifest" Identity Name)"
app_id="$(manifest_attr "$manifest" Application Id)"

# A record of the same package already on the device makes Add fail with
# 0x80070057, "the parameter is incorrect" — same full name, other content —
# which names neither the package nor the cause. This is a development loop:
# what is being sent replaces what is there.
while read -r stale; do
	[[ -n "$stale" ]] || continue
	step "Removing the installed $stale first"
	"${portal[@]}" --uninstall "$stale"
done < <("${portal[@]}" --list | awk -F'\t' -v n="$identity" '$0 ~ "^"n"_" {print $1}')

step "Installing $identity on $UWP_DEVICE_URL"
"${portal[@]}" --package "$package"

# The full name carries the version and the publisher hash, which only the
# device knows; asked rather than reconstructed.
full_name="$("${portal[@]}" --list | awk -F'\t' -v n="$identity" '$0 ~ "^"n"_" {print $1; exit}')"
[[ -n "$full_name" ]] ||
	die "$identity installed but not listed by the device — openappx deploy --list disagrees"

if [[ $launch -eq 1 ]]; then
	step "Launching $full_name !$app_id"
	"${portal[@]}" --start "$full_name" --app-id "$app_id"
	step "Launched. Verify on the screen; stop with:
  openappx deploy --device $UWP_DEVICE_URL --user $UWP_DEVICE_USER --insecure --stop $full_name"
else
	step "Installed: $full_name (not launched: --no-launch)"
fi
