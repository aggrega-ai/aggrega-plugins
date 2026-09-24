#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# The build-provenance recipe every guest's build.sh sources. It is sourced,
# never executed, and it is the one place in this repository that asks git
# which version a guest is.
#
# A guest's version is a git tag named after the guest's directory,
# <guest>/v<semver> — for example litellm-gateway-config/v1.0.0. The recipe
# describes HEAD against that guest's tags only and strips the "<guest>/v"
# prefix from the answer:
#
#   the commit the tag names, clean tree       1.0.0
#   three commits past that tag                1.0.0-3-g1a2b3c4
#   either of those, with uncommitted edits    1.0.0-dirty, 1.0.0-3-g1a2b3c4-dirty
#   no tag for this guest yet                  the short commit, such as 1a2b3c4
#
# A tag names a commit of the whole repository, never a directory, so a commit
# that touches only another guest still moves this guest's build off its tag.
# The "/v" that ends the prefix keeps one guest's tags from matching another
# guest whose name starts with the same letters.
#
# Outside a git checkout the version is "dev" and the commit "unknown". Neither
# is a semantic version, so neither can equal a release version.
#
# Two functions:
#
#   plugin_version_from_describe <guest> <described>
#       Prints <described> with a leading "<guest>/v" removed. It reads only its
#       arguments, so the tag form can be checked on any string.
#
#   plugin_build_stamp
#       Called by a guest's build.sh. It takes the guest's name from the
#       directory holding the calling script, so a guest is always stamped under
#       its own directory's name, and sets BUILD_VERSION and BUILD_COMMIT.

plugin_version_from_describe() {
    local guest="$1" described="$2"
    printf '%s\n' "${described#"${guest}/v"}"
}

# BUILD_VERSION and BUILD_COMMIT are read by the calling build.sh.
# shellcheck disable=SC2034
plugin_build_stamp() {
    # BASH_SOURCE[1] is the file this function was called from: the guest's
    # build.sh. Nothing else names the guest, so no caller can pass a name
    # that differs from its directory.
    local caller="${BASH_SOURCE[1]:-}"
    if [ -z "${caller}" ]; then
        echo "error: plugin_build_stamp is called from a guest's build.sh, which names the guest by its directory" >&2
        return 1
    fi

    local dir guest described
    dir="$(cd "$(dirname "${caller}")" && pwd)"
    guest="$(basename "${dir}")"

    if described="$(git -C "${dir}" describe --tags --always --dirty --match "${guest}/v*" 2>/dev/null)"; then
        BUILD_VERSION="$(plugin_version_from_describe "${guest}" "${described}")"
        BUILD_COMMIT="$(git -C "${dir}" rev-parse --short HEAD)"
    else
        BUILD_VERSION="dev"
        BUILD_COMMIT="unknown"
    fi
}
