#!/usr/bin/env bash
# publish-aur.sh — update the PKGBUILD for a release and push it to the AUR.
#
#   packaging/publish-aur.sh --version 0.1.0 [--dry-run] [--no-push]
#
# The same script runs by hand and from CI, so what CI does is what you can
# reproduce locally — and a release does not depend on a workflow nobody has
# ever run.
#
# It rewrites pkgver, resets pkgrel, downloads the release tarball to compute
# its checksum, regenerates .SRCINFO, and pushes. Editing those by hand is how
# an AUR package ends up claiming a checksum for the wrong tarball.
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo="$(cd "$here/.." && pwd)"

PKGNAME="${AUR_PKGNAME:-uwp-crossbuild}"
AUR_HOST="${AUR_HOST:-aur@aur.archlinux.org}"

version=""
dry_run=0
push=1
while [[ $# -gt 0 ]]; do
	case "$1" in
	--version) version="$2" && shift 2 ;;
	--dry-run) dry_run=1 && shift ;;
	--no-push) push=0 && shift ;;
	*) echo "error: unknown argument $1" >&2 && exit 2 ;;
	esac
done

die() {
	echo "error: $*" >&2
	exit 1
}
step() { printf '\n==> %s\n' "$*"; }

[[ -n "$version" ]] || die "--version is required (e.g. --version 0.1.0)"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "not a version: $version"
command -v makepkg >/dev/null || die "makepkg not found — this needs Arch or an arch container"

# makepkg refuses to run as root, and CI containers are root by default.
[[ "$(id -u)" -ne 0 ]] || die "run as a normal user: makepkg refuses root"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$here/PKGBUILD" "$work/PKGBUILD"
cd "$work"

step "Setting pkgver=$version"
sed -i "s/^pkgver=.*/pkgver=$version/" PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD

step "Checksumming the release tarball"
# updpkgsums downloads whatever `source` resolves to after the pkgver change,
# so the checksum can never describe a different tarball than the one declared.
if command -v updpkgsums >/dev/null; then
	updpkgsums
else
	die "updpkgsums not found (pacman-contrib)"
fi

step "Regenerating .SRCINFO"
makepkg --printsrcinfo >.SRCINFO
grep -q "pkgver = $version" .SRCINFO || die ".SRCINFO disagrees with pkgver"

step "Checking the package builds and its tests pass"
makepkg --check --noconfirm --nodeps --clean >/dev/null

if [[ $dry_run -eq 1 ]]; then
	step "Dry run — the PKGBUILD that would be published:"
	cat PKGBUILD
	exit 0
fi

step "Recording the result in the repository"
cp PKGBUILD .SRCINFO "$here/"

if [[ $push -eq 0 ]]; then
	step "Not pushing (--no-push). $here is up to date."
	exit 0
fi

step "Pushing to the AUR"
# The AUR repository holds only PKGBUILD and .SRCINFO; it is not a mirror of
# this one, so it is cloned fresh rather than kept as a remote here.
aur="$work/aur"
git clone -q "ssh://$AUR_HOST/$PKGNAME.git" "$aur" ||
	die "cannot clone $PKGNAME from the AUR — is the package registered, and the key loaded?"
cp "$here/PKGBUILD" "$here/.SRCINFO" "$aur/"
cd "$aur"
git add PKGBUILD .SRCINFO
# Staged, not working-tree: on a first publication the AUR repository is empty,
# so `git diff` sees nothing — the files are untracked, not unchanged — and the
# script would report success having pushed no package.
if git diff --cached --quiet; then
	step "Already published at $version — nothing to do"
	exit 0
fi
git -c user.name="${GIT_AUTHOR_NAME:-Gianluca Mazza}" \
	-c user.email="${GIT_AUTHOR_EMAIL:-info@gianlucamazza.it}" \
	commit -q -m "$PKGNAME $version"
# HEAD:master because a fresh clone of an empty repository has no master yet.
git push -q origin HEAD:master
step "Published $PKGNAME $version to the AUR"
echo "  https://aur.archlinux.org/packages/$PKGNAME"

cd "$repo"
