#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the smoke-ts cli plugin to a .wasm artifact via the Extism JS PDK
# (extism-js compiler + QuickJS runtime).
#
# The destination directory defaults to this script's own directory; set
# AGGREGA_PLUGIN_WASM_OUT to write the artifact elsewhere (for example a
# sidecar directory or a staging area a walk-through drives).
#
# The artifact takes the name ../lib/build-artifact.sh derives from this guest's
# plugin.yaml: the name the compiler reads a plugin's .wasm under beside its
# Plugin entity.
#
# The guest's describe() reports the version and commit of the tree it was
# built from, read by ../lib/build-version.sh from this guest's
# smoke-ts/v<semver> tag. The bundle step defines AGGREGA_PLUGIN_VERSION and
# AGGREGA_PLUGIN_COMMIT, which the kit's encodeDescriptor folds into the
# self-report.

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

# shellcheck source=SCRIPTDIR/../lib/build-artifact.sh
source "${SCRIPT_DIR}/../lib/build-artifact.sh"
plugin_build_artifact

# shellcheck source=SCRIPTDIR/../lib/build-version.sh
source "${SCRIPT_DIR}/../lib/build-version.sh"
plugin_build_stamp
echo "Stamping version ${BUILD_VERSION}, commit ${BUILD_COMMIT}"

# Install plugin-local dependencies (the PDK, esbuild, and types).
(cd "${SCRIPT_DIR}" && npm install --no-save --silent --no-audit --no-fund)

# Bundle TypeScript to a single CommonJS JS file, defining the stamp as two
# string constants.
(cd "${SCRIPT_DIR}" && npx esbuild src/index.ts --bundle --format=cjs --target=es2022 --platform=neutral --main-fields=main --outfile=dist/plugin.js \
    "--define:AGGREGA_PLUGIN_VERSION=\"${BUILD_VERSION}\"" \
    "--define:AGGREGA_PLUGIN_COMMIT=\"${BUILD_COMMIT}\"")

# Compile the bundled JS into a Wasm artifact embedding QuickJS.
extism-js -i "${SCRIPT_DIR}/index.d.ts" "${SCRIPT_DIR}/dist/plugin.js" -o "${OUT_DIR}/${BUILD_ARTIFACT}"
echo "Wrote ${OUT_DIR}/${BUILD_ARTIFACT}"
