#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the moo cli plugin to a .wasm artifact.
#
# The destination directory defaults to this script's own directory; set
# AGGREGA_PLUGIN_WASM_OUT to write the artifact elsewhere (for example a
# sidecar directory or a staging area a walk-through drives).

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${AGGREGA_PLUGIN_WASM_OUT:-${SCRIPT_DIR}}"
mkdir -p "${OUT_DIR}"

# GOWORK=off builds this plugin module standalone, independent of any Go
# workspace the surrounding checkout may define.
(cd "${SCRIPT_DIR}" && GOWORK=off GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o "${OUT_DIR}/moo.wasm" ./)
echo "Wrote ${OUT_DIR}/moo.wasm"
