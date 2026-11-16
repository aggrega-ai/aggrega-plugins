#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# The build-path remap every Rust guest's build.sh sources. It is sourced, never
# executed, and it is the one place in this repository that decides how a Rust
# guest names the directories of the machine that built it.
#
# A Rust guest keeps the source path of every panic location it can report — in
# its own code, its dependencies and the standard library — as a string in the
# .wasm. Left alone, those strings name the building machine: the directory
# holding the checkout, the cargo home under the builder's home directory, and,
# where the toolchain's rust-src component is installed, the toolchain's own
# directory.
#
# plugin_build_rustflags maps each of those directories to a fixed name:
#
#   the directory holding this repository                 .
#   the cargo home (CARGO_HOME, or ~/.cargo)              cargo-home
#   the toolchain's standard-library sources              /rustc/<commit-hash>
#
# The last name is the one the toolchain's prebuilt standard library already
# carries, so a guest's bytes do not depend on whether rust-src is installed.
#
# The remap removes those paths. It does not make the bytes independent of where
# the build runs when a guest takes a path dependency outside its own workspace:
# cargo derives that dependency's identity from its absolute location, and that
# identity reaches the bytes, the symbol names among them, so the same commit
# built with the dependency in another directory yields different bytes. The Rust
# guests here take the kit crates from crates.io by version, which carries no
# such location.
#
# rustc applies the LAST --remap-path-prefix whose prefix matches a path, so the
# directory holding the checkout is given first: a checkout straight under a home
# directory contains the cargo home and the toolchain, and their names must win.
#
# The flags travel in CARGO_ENCODED_RUSTFLAGS, which cargo reads in preference to
# RUSTFLAGS and splits on a unit separator rather than on spaces, so a directory
# whose name holds a space is remapped whole. A caller's own flags —
# CARGO_ENCODED_RUSTFLAGS when it is set, otherwise RUSTFLAGS — are kept and come
# first, so a caller can still add a flag but cannot bring a path back. While
# either variable is set, cargo reads no rustflags from a configuration file.
#
# The CLI repository's embedded-guest build carries the same remap in its own
# script. The copy is deliberate: each repository builds from its own checkout
# alone, so neither sources a file from the other.
#
# One function:
#
#   plugin_build_rustflags
#       Called by a Rust guest's build.sh. It asks the toolchain cargo will use
#       for its standard-library sources and commit — rustup selects that
#       toolchain from the directory holding the calling script, where the build
#       runs — and sets BUILD_ENCODED_RUSTFLAGS, which the build.sh passes to
#       cargo as CARGO_ENCODED_RUSTFLAGS.

# BUILD_ENCODED_RUSTFLAGS is read by the calling build.sh.
# shellcheck disable=SC2034
plugin_build_rustflags() {
    # BASH_SOURCE[1] is the guest's build.sh, as in plugin_build_stamp.
    local caller="${BASH_SOURCE[1]:-}"
    if [ -z "${caller}" ]; then
        echo "error: plugin_build_rustflags is called from a guest's build.sh, which runs cargo in its own directory" >&2
        return 1
    fi

    # Physical paths throughout: cargo names sources by the resolved working
    # directory, so a prefix spelled through a symbolic link would never match.
    local dir workspace
    dir="$(cd "$(dirname "${caller}")" && pwd -P)"
    workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

    local rustc="${RUSTC:-rustc}" sysroot version line commit=""
    if ! sysroot="$(cd "${dir}" && "${rustc}" --print sysroot)" \
        || ! version="$(cd "${dir}" && "${rustc}" -vV)"; then
        echo "error: ${rustc} did not report its sysroot and version from ${dir}" >&2
        return 1
    fi
    while IFS= read -r line; do
        case "${line}" in "commit-hash: "*) commit="${line#commit-hash: }" ;; esac
    done <<< "${version}"

    local IFS=$'\x1f' flags=()
    if [ -n "${CARGO_ENCODED_RUSTFLAGS+set}" ]; then
        if [ -n "${CARGO_ENCODED_RUSTFLAGS}" ]; then
            read -r -a flags <<< "${CARGO_ENCODED_RUSTFLAGS}"
        fi
    elif [ -n "${RUSTFLAGS:-}" ]; then
        IFS=' ' read -r -a flags <<< "${RUSTFLAGS}"
    fi
    flags+=(
        "--remap-path-prefix=${workspace}=."
        "--remap-path-prefix=${CARGO_HOME:-${HOME}/.cargo}=cargo-home"
        "--remap-path-prefix=${sysroot}/lib/rustlib/src/rust=/rustc/${commit:-unknown}"
    )
    # "${flags[*]}" joins with the first character of IFS, the unit separator.
    BUILD_ENCODED_RUSTFLAGS="${flags[*]}"
}
