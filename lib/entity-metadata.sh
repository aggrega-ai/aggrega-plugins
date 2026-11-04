#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# The reader of a guest's Plugin entity that every script in this repository
# sources. It is sourced, never executed, and it is the one place in this
# repository that reads a key out of a plugin.yaml's metadata block, so the build
# that names a guest's .wasm and the release script that checks a guest's version
# read the entity the same way.
#
# One function:
#
#   plugin_entity_metadata <plugin.yaml> <key>
#       Prints the value of <key> at the first indentation level under the
#       top-level metadata key, whatever that indentation is. A comment after
#       the value is dropped, and one pair of matching quotes around it is
#       removed. A key of the same name deeper in the document, or inside a
#       folded description, is never taken for it. Prints nothing when the
#       block does not carry the key.
plugin_entity_metadata() {
    awk -v key="$2" -v q="'" '
        /^[[:space:]]*(#.*)?$/ { next }
        /^[^[:space:]]/ { inmeta = ($0 ~ /^metadata:[[:space:]]*(#.*)?$/); indent = ""; next }
        inmeta {
            match($0, /^[[:space:]]+/)
            ind = substr($0, 1, RLENGTH)
            if (indent == "") indent = ind
            if (ind != indent) next
            line = substr($0, RLENGTH + 1)
            if (index(line, key ":") == 1) {
                line = substr(line, length(key) + 2)
                sub(/^[[:space:]]*/, "", line)
                sub(/[[:space:]]+#.*$/, "", line)
                sub(/[[:space:]]+$/, "", line)
                first = substr(line, 1, 1)
                if ((first == "\"" || first == q) && substr(line, length(line), 1) == first) {
                    line = substr(line, 2, length(line) - 2)
                }
                print line
                exit
            }
        }' "$1"
}
