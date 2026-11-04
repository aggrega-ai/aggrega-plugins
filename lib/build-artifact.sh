#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# The artifact filename every guest's build.sh sources. It is sourced, never
# executed, and it is the one place in this repository that decides the name a
# guest's .wasm is written under.
#
# The compiler reads a plugin's .wasm from beside its Plugin entity under a name
# derived from the entity's plugin type and name: the two parts, each encoded,
# joined by two hyphens, with .wasm appended. A guest's build.sh writes its .wasm
# beside the guest's own plugin.yaml, so the build writes that same name, and the
# file it leaves is the one the compiler looks for there:
#
#   pluginType: pipeline-step, name: litellm-gateway-config
#       pipeline-step--litellm-gateway-config.wasm
#
# The encoding carries a lowercase letter or a digit as itself, and a hyphen as
# itself where a lowercase letter other than "z", or a digit, follows it.
# Everything else it writes as an escape: an uppercase letter, any other
# character, a hyphen that ends the part, a hyphen before another hyphen or
# before "z" (a hyphen followed by "z" opens an escape), and an empty part. This
# script spells the name flat, without encoding, so the flat spelling is the
# compiler's name only where every character of both parts is carried as itself.
#
# 🔴 The rule has one home, and this file is not it: it lives beside the
# compiler's resolver, which reads the name. This copy is deliberate. A guest
# builds from this repository's checkout alone, and no aggrega binary is there
# at build time to ask for the name, so the name is spelled here a second time —
# and a second statement that agrees today is what hides tomorrow's divergence.
# No test holds this copy to the compiler's derivation; the refusal
# below holds it shut: a plugin type or name the flat spelling is not exact for
# stops the build rather than writing a file the compiler never reads. The
# condition is narrower than the encoding's own, deliberately: it also refuses a
# part that begins with a hyphen, which the encoding would carry as itself.
# Refusing a part that was encodable costs a message; admitting one that was not
# would cost a file nothing reads. The CLI repository's co-located catalog
# generator spells the same name with the same refusal, for the same reason.
#
# Two functions:
#
#   plugin_artifact_leaf <plugin-type> <name>
#       Prints the filename a guest of that plugin type and name is written
#       under, or prints why it cannot and returns 1. It reads only its
#       arguments, so the rule can be checked on any pair.
#
#   plugin_build_artifact
#       Called by a guest's build.sh. It reads metadata.pluginType and
#       metadata.name from the plugin.yaml beside the calling script, through
#       ./entity-metadata.sh, so the
#       name is taken from the entity the compiler resolves rather than written
#       into each build.sh, and sets BUILD_ARTIFACT.

# plugin_artifact_part_flat reports whether the flat spelling is exact for one
# part: lowercase letters and digits, hyphens only between two of them, and no
# hyphen before "z".
plugin_artifact_part_flat() {
    case "$1" in *-z*) return 1 ;; esac
    [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

plugin_artifact_leaf() {
    local plugin_type="$1" name="$2" part label
    for label in "plugin type" "name"; do
        part="${plugin_type}"
        [ "${label}" != "name" ] || part="${name}"
        if [ -z "${part}" ]; then
            echo "error: the plugin's ${label} is empty, so this build cannot name the file the compiler reads its .wasm from" >&2
            return 1
        fi
        if ! plugin_artifact_part_flat "${part}"; then
            echo "error: the plugin's ${label} \"${part}\" cannot be spelled into the filename the compiler reads its .wasm from." >&2
            echo "  This build writes a plugin type or name into that filename only where it is lowercase letters and digits," >&2
            echo "  with single hyphens between them and no hyphen before a \"z\" — a form the compiler writes as itself. It" >&2
            echo "  does not escape anything else, as the compiler does, so it would risk writing a file the compiler never" >&2
            echo "  reads. Rename the plugin, or copy the built .wasm beside its Plugin entity under the name" >&2
            echo "  'aggrega lint <plugin.yaml>' reports it looked for." >&2
            return 1
        fi
    done
    printf '%s--%s.wasm\n' "${plugin_type}" "${name}"
}

# The entity's keys are read by the repository's one reader of a plugin.yaml's
# metadata block, which the release script reads a guest's version through too.
# shellcheck source=SCRIPTDIR/entity-metadata.sh
source "$(dirname "${BASH_SOURCE[0]}")/entity-metadata.sh"

# BUILD_ARTIFACT is read by the calling build.sh.
# shellcheck disable=SC2034
plugin_build_artifact() {
    # BASH_SOURCE[1] is the guest's build.sh, as in plugin_build_stamp.
    local caller="${BASH_SOURCE[1]:-}"
    if [ -z "${caller}" ]; then
        echo "error: plugin_build_artifact is called from a guest's build.sh, which sits beside the guest's plugin.yaml" >&2
        return 1
    fi

    local dir entity plugin_type name leaf
    dir="$(cd "$(dirname "${caller}")" && pwd)"
    entity="${dir}/plugin.yaml"
    if [ ! -f "${entity}" ]; then
        echo "error: ${entity} does not exist; a guest's build names its .wasm from the Plugin entity beside it" >&2
        return 1
    fi
    plugin_type="$(plugin_entity_metadata "${entity}" pluginType)"
    name="$(plugin_entity_metadata "${entity}" name)"
    if ! leaf="$(plugin_artifact_leaf "${plugin_type}" "${name}")"; then
        echo "  (read from ${entity})" >&2
        return 1
    fi
    BUILD_ARTIFACT="${leaf}"
}
