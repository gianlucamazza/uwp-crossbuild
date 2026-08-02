#!/usr/bin/env bash
# common.sh — what every script here would otherwise write for itself.
#
# Sourced, never run:
#
#     . "$here/common.sh"
#
# Four kinds of thing live here, and nothing else does. Anything specific to
# one script belongs in that script, where its reasons are.
#
#   the shape of an error      die, and the argument checks that produce one
#   a download that can fail   fetch: the same failure in two scripts is one
#                              routine, not two that drift apart
#   the layout doctrine        prepare_layout: what may be cleared and what may
#                              not, which both front doors have to agree on
#   the default SDK version    fetch-sdk.sh writes the layout at this version;
#                              gen-projection.sh and wine-tool.sh read it back.
#                              Three copies of the default could disagree, and
#                              the symptom would be "tool not found" naming
#                              neither copy
#
# That last one is why this file exists at all. build-app.sh and
# build-project.sh had a copy each of "clear a stale layout, but only when it is
# recognisably one", and within a day they disagreed about what counts as
# recognisable — same message, different behaviour, and only one of them let a
# half-built layout be rebuilt without a manual rm.

# The one default every SDK consumer must agree on. UWP_SDK_VERSION still
# overrides it everywhere; the installer URL stays in fetch-sdk.sh beside the
# cross-check that both describe the same SDK.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
UWP_SDK_VERSION_DEFAULT="10.0.22621.0"

die() {
	echo "error: $*" >&2
	exit 1
}

step() { printf '\n==> %s\n' "$*"; }

# A flag whose value is missing would otherwise fail on an unbound $2 under
# `set -u`, naming the shell rather than the argument. A value that is itself
# a flag — `--out --uwp` — would be taken literally, and the real failure
# deferred to whatever is downstream of the misread pair: an executable named
# `--uwp`, without the app container.
value() { # value <flag> <argc> [value]
	[[ $2 -ge 2 ]] || die "$1 needs a value"
	[[ "${3:-}" != --* ]] || die "$1 needs a value, not another flag: $3"
}

# The comment block at the top of the *calling* script is its usage text.
# Printing it back means there is one description of the flags, not two that
# drift apart. BASH_SOURCE[-1] is that script — resolved through the symlink it
# was reached by, since the installed commands are symlinks.
usage() {
	awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' \
		"$(readlink -f "${BASH_SOURCE[-1]}")"
	exit 0
}

# Downloads to a temporary name and renames on success. Two failures otherwise
# land in a cache and stay there: curl without --fail writes the server's error
# page into the output file and exits 0, so an HTTP 404 leaves a 200-byte
# "package"; and an interrupted download leaves a truncated one that every later
# run happily reuses.
fetch() { # fetch <url> <destination>
	curl -sSL --fail -o "$2.part" "$1" || die "download failed: $1"
	mv "$2.part" "$2"
}

# A layout is the complete contents of a package: everything in it ships, and
# `makepri new` indexes what it finds. So it has to be emptied before it is
# filled — an executable under a name the project no longer uses would ship
# otherwise — and it has to be emptied only when it is recognisably a layout
# this produced, because --out can be pointed anywhere.
#
# The executable counts as that evidence alongside the manifest: a build that
# died between the link and the manifest copy leaves a layout holding nothing
# else, and the next run should not need a manual rm.
prepare_layout() { # prepare_layout <layout> <executable name>
	local layout="$1" executable="$2"
	[[ -n "$(ls -A "$layout")" ]] || return 0
	[[ -f "$layout/AppxManifest.xml" || -f "$layout/$executable" ]] ||
		die "$layout is not empty and holds no AppxManifest.xml — refusing to clear it"
	find "$layout" -mindepth 1 -delete
}
