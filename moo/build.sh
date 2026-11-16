#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the moo cli plugin to a .wasm artifact.
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
# built from, read by ../lib/build-version.sh from this guest's moo/v<semver>
# tag. The linker sets the kit's Version and Commit, which the kit's
# MarshalDescriptor folds into the self-report.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${AGGREGA_PLUGIN_WASM_OUT:-${SCRIPT_DIR}}"
mkdir -p "${OUT_DIR}"

# shellcheck source=SCRIPTDIR/../lib/build-artifact.sh
source "${SCRIPT_DIR}/../lib/build-artifact.sh"
plugin_build_artifact

# shellcheck source=SCRIPTDIR/../lib/build-version.sh
source "${SCRIPT_DIR}/../lib/build-version.sh"
plugin_build_stamp
echo "Stamping version ${BUILD_VERSION}, commit ${BUILD_COMMIT}"

KIT=github.com/aggrega-ai/aggrega-pdk/go/pkg/aggrega

# GOWORK=off builds this plugin module standalone, independent of any Go
# workspace the surrounding checkout may define. -trimpath records each source
# file by its module path rather than its directory on disk, so the .wasm names
# no directory of the machine that built it. -buildvcs=false keeps the
# version-control stamp out of the build info, so the bytes depend on the
# source alone and not on the state of whichever repository holds the checkout.
# The version and commit a guest reports come from the -X stamps below instead.
(cd "${SCRIPT_DIR}" && GOWORK=off GOOS=wasip1 GOARCH=wasm go build -trimpath -buildvcs=false -buildmode=c-shared \
    -ldflags "-X ${KIT}.Version=${BUILD_VERSION} -X ${KIT}.Commit=${BUILD_COMMIT}" \
    -o "${OUT_DIR}/${BUILD_ARTIFACT}" ./)
echo "Wrote ${OUT_DIR}/${BUILD_ARTIFACT}"
