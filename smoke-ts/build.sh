#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the smoke-ts cli plugin to a .wasm artifact via the Extism JS PDK
# (extism-js compiler + QuickJS runtime).
#
# The destination directory defaults to this script's own directory; set
# AGGREGA_PLUGIN_WASM_OUT to write the artifact elsewhere (for example a
# sidecar directory or a staging area a walk-through drives).

set -eo pipefail

# Bring node + extism-js + binaryen onto PATH for non-interactive
# subprocess invocations.
if [ -d "${HOME}/n/bin" ]; then
    export PATH="${HOME}/n/bin:${PATH}"
fi
if [ -d "${HOME}/.local/bin" ]; then
    export PATH="${HOME}/.local/bin:${PATH}"
fi

for tool in node npm extism-js wasm-merge wasm-opt; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' not on PATH for the TypeScript plugin build."
        echo "  extism-js: install from github.com/extism/js-pdk/releases (v1.6.0 line)"
        echo "  wasm-merge + wasm-opt: install via the binaryen release tarball"
        echo "  node + npm: ensure your node install is on PATH"
        exit 1
    fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${AGGREGA_PLUGIN_WASM_OUT:-${SCRIPT_DIR}}"
mkdir -p "${OUT_DIR}" "${SCRIPT_DIR}/dist"

# Install plugin-local dependencies (the PDK, esbuild, and types).
(cd "${SCRIPT_DIR}" && npm install --no-save --silent --no-audit --no-fund)

# Bundle TypeScript to a single CommonJS JS file.
(cd "${SCRIPT_DIR}" && npx esbuild src/index.ts --bundle --format=cjs --target=es2022 --platform=neutral --main-fields=main --outfile=dist/plugin.js)

# Compile the bundled JS into a Wasm artifact embedding QuickJS.
extism-js -i "${SCRIPT_DIR}/index.d.ts" "${SCRIPT_DIR}/dist/plugin.js" -o "${OUT_DIR}/smoke-ts.wasm"
echo "Wrote ${OUT_DIR}/smoke-ts.wasm"
