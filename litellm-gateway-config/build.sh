#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the litellm-gateway-config pipeline-step plugin to a .wasm artifact.
#
# The destination directory defaults to this script's own directory; set
# AGGREGA_PLUGIN_WASM_OUT to write the artifact elsewhere (for example a
# sidecar directory or a staging area a walk-through drives).

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${AGGREGA_PLUGIN_WASM_OUT:-${SCRIPT_DIR}}"
mkdir -p "${OUT_DIR}"

(cd "${SCRIPT_DIR}" && cargo build --release --target wasm32-unknown-unknown)
cp "${SCRIPT_DIR}/target/wasm32-unknown-unknown/release/litellm_gateway_config.wasm" \
   "${OUT_DIR}/litellm-gateway-config.wasm"
echo "Wrote ${OUT_DIR}/litellm-gateway-config.wasm"
