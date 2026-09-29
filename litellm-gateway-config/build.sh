#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the litellm-gateway-config pipeline-step plugin to a .wasm artifact.
#
# The destination directory defaults to this script's own directory; set
# AGGREGA_PLUGIN_WASM_OUT to write the artifact elsewhere (for example a
# sidecar directory or a staging area a walk-through drives).
#
# The guest's describe() reports the version and commit of the tree it was
# built from, read by ../lib/build-version.sh from this guest's
# litellm-gateway-config/v<semver> tag. The kit's describe! macro reads them at
# compile time from AGGREGA_VERSION and AGGREGA_COMMIT, and cargo rebuilds the
# crate when either value changes.
#
# The .wasm names no directory of the machine that built it:
# ../lib/build-paths.sh remaps the checkout's directory, the cargo home and the
# toolchain's sources to fixed names.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${AGGREGA_PLUGIN_WASM_OUT:-${SCRIPT_DIR}}"
mkdir -p "${OUT_DIR}"

# shellcheck source=SCRIPTDIR/../lib/build-version.sh
source "${SCRIPT_DIR}/../lib/build-version.sh"
plugin_build_stamp
echo "Stamping version ${BUILD_VERSION}, commit ${BUILD_COMMIT}"

# shellcheck source=SCRIPTDIR/../lib/build-paths.sh
source "${SCRIPT_DIR}/../lib/build-paths.sh"
plugin_build_rustflags

(cd "${SCRIPT_DIR}" && AGGREGA_VERSION="${BUILD_VERSION}" AGGREGA_COMMIT="${BUILD_COMMIT}" \
    CARGO_ENCODED_RUSTFLAGS="${BUILD_ENCODED_RUSTFLAGS}" \
    cargo build --release --target wasm32-unknown-unknown)
cp "${SCRIPT_DIR}/target/wasm32-unknown-unknown/release/litellm_gateway_config.wasm" \
   "${OUT_DIR}/litellm-gateway-config.wasm"
echo "Wrote ${OUT_DIR}/litellm-gateway-config.wasm"
