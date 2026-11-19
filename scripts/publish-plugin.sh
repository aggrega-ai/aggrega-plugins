#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# publish-plugin.sh — release a guest of this repository from its release tag.
#
# A guest's release tag is <guest>/v<MAJOR>.<MINOR>.<PATCH>, named after the
# guest's directory (see "Where a guest's version comes from" in README.md). This
# script resolves such a tag to the guest and version it names, builds the guest
# from the commit the tag names with the guest's own build.sh, checks that the
# entity and the build both carry the tag's version, and prints the publication
# plan or publishes. It is what the CI publisher runs, step by step, and it runs
# the same way by hand. Nothing is pushed unless the publish command is given
# without --dry-run.
#
# Each publication carries the guest's third-party notices and an SBOM of what
# the guest links in. The build writes both beside the .wasm, with the generator
# of an aggrega-cli checkout beside this repository, and the publication hands
# them to aggrega push. Every guest therefore needs its lockfile (go.sum,
# Cargo.lock or package-lock.json) committed; a guest without it is refused.
# Publishing needs a tooling image or an aggrega binary whose push takes
# --plugin-notices and --plugin-sbom.
#
# Run with --help for the commands.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG_PATTERN='^([a-z0-9][a-z0-9._-]*)/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# The tools the TypeScript guest's build calls besides Node: the extism-js
# compiler and binaryen's wasm-merge and wasm-opt. Pinned by version and by the
# SHA-256 of the release asset, so every run installs the same bytes.
EXTISM_JS_VERSION=v1.5.1
EXTISM_JS_SHA256=f6a4a3a8f16651a527a4643f95d229c854a04d66d4628cdc724a58c699b93c95
BINARYEN_VERSION=version_129
BINARYEN_SHA256=50b9fa62b9abea752da92ec57e0c555fee578760cd237c40107957715d2976ba

usage() {
  cat <<'EOF'
usage: scripts/publish-plugin.sh <command> [options]

Release a guest of this repository from its release tag. A release tag is
<guest>/v<MAJOR>.<MINOR>.<PATCH>, named after the guest's directory, such as
litellm-gateway-config/v1.0.0.

Commands:

  resolve [--tag <tag>] [--publish] [--repo <dir>] [--output <file>]
      Resolve what a run builds, and refuse a tag that is malformed, that the
      repository does not carry, or whose commit holds no such guest.
      With --tag: the one guest the tag names, at that tag.
      Without --tag: every guest in the repository's checked-out commit that has
      a release tag, each at its newest one, so every guest is built exactly as
      publishing its current release would build it. A guest with no release
      tag yet is listed as skipped. --publish refuses to run without a tag,
      because a publication names one version.
      Prints key=value lines, and appends them to --output when given:
        tags     the release tags to build, space-separated
        skipped  the guests with no release tag
        rust     true when a guest to build is a Rust crate
        go       the highest Go version a Go guest's go.mod names, or empty
        node     true when a guest to build is a TypeScript package

  install-tools --dir <dir>
      Download the x86_64 Linux builds of the extism-js compiler and of
      binaryen's wasm-merge and wasm-opt, which the TypeScript guest's build
      calls, verify each against its pinned SHA-256, and install them into
      <dir>. Add <dir> to PATH afterwards.

  build --tags "<tag>..." --work <dir> --out <dir> [--repo <dir>]
      Build each tag's guest from a clone of the repository at the commit the
      tag names. Before building it checks that the entity's metadata.version
      equals the tag's version; after, that the build stamped exactly that
      version. The clone is made in <work>, which must be absent or empty. Each
      guest takes the plugin development kits from its language's package
      registry at the version its own manifest names. Each guest's entity, its
      .wasm, its third-party notices (notices.md), its SBOM (sbom.spdx.json) and
      a build.txt naming the tag, the commit and the stamp land in
      <out>/<guest>/. The notices and the SBOM are generated from the guest's
      lockfile by scripts/gen-third-party-licenses.sh of an aggrega-cli checkout
      beside this repository (../aggrega-cli); the build refuses a guest
      without its lockfile, and refuses to run without that checkout.

  publish --dir <dir> --registry <host> (--dry-run | --sign [--key <file>])
      Publish each guest a build left in <dir>: its entity, its .wasm, its
      notices and its SBOM, with aggrega push --plugin, --plugin-notices and
      --plugin-sbom; a guest missing either file is refused, naming it, before
      anything is pushed. --dry-run prints each publication plan and
      contacts no registry; aggrega push still reads describe() from the .wasm
      and refuses an entity that disagrees with it. --sign signs each
      publication, keyless unless --key names an ECDSA P-256 private key.
      The binary is AGGREGA_BIN when set, otherwise aggrega from PATH.

Common options:
  --repo <dir>  the repository to read tags from and clone; defaults to the one
                this script is in
  -h, --help    print this help

Exit status: 0 on success, 1 when a check refuses or a step fails, 2 for a usage
error.
EOF
}

say() {
  echo "publish-plugin: $*" >&2
}

fail() {
  say "$*"
  exit 1
}

usage_error() {
  say "$*"
  say "run with --help for the commands"
  exit 2
}

# plugin_entity_metadata <plugin.yaml> <key> reads a key of an entity's metadata
# block, the same way a guest's build reads it.
# shellcheck source=SCRIPTDIR/../lib/entity-metadata.sh
source "$SCRIPT_DIR/../lib/entity-metadata.sh"

repo_root() {
  local dir="$1"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null \
    || fail "$dir is not a git checkout of this repository"
}

# check_tag <repo> <tag> refuses a malformed tag, one the repository does not
# carry, and one whose commit holds no such guest.
check_tag() {
  local repo="$1" tag="$2" guest
  if ! [[ "$tag" =~ $TAG_PATTERN ]]; then
    fail "'$tag' is not a release tag: a release tag is <guest>/v<MAJOR>.<MINOR>.<PATCH>, named after the guest's directory, such as litellm-gateway-config/v1.0.0"
  fi
  guest="${BASH_REMATCH[1]}"
  if ! git -C "$repo" rev-parse --quiet --verify "refs/tags/$tag^{commit}" >/dev/null; then
    fail "the repository carries no tag $tag; fetch its tags, or name a tag it carries"
  fi
  local f
  for f in plugin.yaml build.sh; do
    if ! git -C "$repo" cat-file -e "refs/tags/$tag:$guest/$f" 2>/dev/null; then
      fail "the commit $tag names holds no $guest/$f, so it holds no guest named $guest"
    fi
  done
}

cmd_resolve() {
  local tag="" tag_set=false publish=false repo="$SCRIPT_DIR/.." output=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag) [ "$#" -ge 2 ] || usage_error "--tag needs a value"; tag="$2"; tag_set=true; shift 2 ;;
      --publish) publish=true; shift ;;
      --repo) [ "$#" -ge 2 ] || usage_error "--repo needs a value"; repo="$2"; shift 2 ;;
      --output) [ "$#" -ge 2 ] || usage_error "--output needs a value"; output="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "resolve: unknown argument '$1'" ;;
    esac
  done
  repo="$(repo_root "$repo")"

  local tags=() skipped=()
  if "$tag_set" && [ -n "$tag" ]; then
    check_tag "$repo" "$tag"
    tags=("$tag")
  elif "$publish"; then
    fail "a publish needs a release tag (<guest>/v<MAJOR>.<MINOR>.<PATCH>): push one, or pass one; only a dry run runs without a tag"
  else
    local entry guest newest candidate
    while IFS= read -r entry; do
      guest="$entry"
      git -C "$repo" cat-file -e "HEAD:$guest/plugin.yaml" 2>/dev/null || continue
      git -C "$repo" cat-file -e "HEAD:$guest/build.sh" 2>/dev/null || continue
      newest=""
      while IFS= read -r candidate; do
        if [[ "$candidate" =~ $TAG_PATTERN ]] && [ "${BASH_REMATCH[1]}" = "$guest" ]; then
          newest="$candidate"
          break
        fi
      done < <(git -C "$repo" tag --list "$guest/v*" --sort=-version:refname)
      if [ -n "$newest" ]; then
        check_tag "$repo" "$newest"
        tags+=("$newest")
      else
        skipped+=("$guest")
      fi
    done < <(git -C "$repo" ls-tree -d --name-only HEAD)
    [ "${#tags[@]}" -gt 0 ] || fail "no guest in this repository has a release tag, so there is nothing to build"
  fi

  local rust=false node=false go_versions=() t g gomod v
  for t in "${tags[@]}"; do
    g="${t%%/v*}"
    if git -C "$repo" cat-file -e "refs/tags/$t:$g/Cargo.toml" 2>/dev/null; then rust=true; fi
    if git -C "$repo" cat-file -e "refs/tags/$t:$g/package.json" 2>/dev/null; then node=true; fi
    if gomod="$(git -C "$repo" show "refs/tags/$t:$g/go.mod" 2>/dev/null)"; then
      v="$(printf '%s\n' "$gomod" | awk '$1 == "go" { print $2; exit }')"
      [ -n "$v" ] || fail "$t: $g/go.mod names no go version"
      go_versions+=("$v")
    fi
  done
  local go=""
  if [ "${#go_versions[@]}" -gt 0 ]; then
    go="$(printf '%s\n' "${go_versions[@]}" | sort -V | tail -n 1)"
  fi

  local lines
  lines="$(printf 'tags=%s\nskipped=%s\nrust=%s\ngo=%s\nnode=%s\n' \
    "${tags[*]}" "${skipped[*]:-}" "$rust" "$go" "$node")"
  printf '%s\n' "$lines"
  if [ -n "$output" ]; then
    printf '%s\n' "$lines" >> "$output"
  fi
  for g in "${skipped[@]:-}"; do
    [ -n "$g" ] && say "skipped $g: it has no release tag yet"
  done
  return 0
}

cmd_install_tools() {
  local dir=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) [ "$#" -ge 2 ] || usage_error "--dir needs a value"; dir="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "install-tools: unknown argument '$1'" ;;
    esac
  done
  [ -n "$dir" ] || usage_error "install-tools needs --dir"
  mkdir -p "$dir"
  local tmp
  tmp="$(mktemp -d)"
  local extism="extism-js-x86_64-linux-$EXTISM_JS_VERSION.gz"
  local binaryen="binaryen-$BINARYEN_VERSION-x86_64-linux.tar.gz"
  curl --silent --show-error --fail --location --retry 3 -o "$tmp/$extism" \
    "https://github.com/extism/js-pdk/releases/download/$EXTISM_JS_VERSION/$extism"
  curl --silent --show-error --fail --location --retry 3 -o "$tmp/$binaryen" \
    "https://github.com/WebAssembly/binaryen/releases/download/$BINARYEN_VERSION/$binaryen"
  printf '%s  %s\n%s  %s\n' "$EXTISM_JS_SHA256" "$tmp/$extism" "$BINARYEN_SHA256" "$tmp/$binaryen" \
    | sha256sum --check --quiet \
    || fail "a downloaded tool does not match its pinned SHA-256; nothing was installed"
  gunzip -c "$tmp/$extism" > "$dir/extism-js"
  chmod 0755 "$dir/extism-js"
  tar -xzf "$tmp/$binaryen" -C "$tmp"
  local tool
  for tool in wasm-merge wasm-opt; do
    install -m 0755 "$tmp/binaryen-$BINARYEN_VERSION/bin/$tool" "$dir/$tool"
  done
  rm -rf "$tmp"
  say "installed extism-js $EXTISM_JS_VERSION and binaryen $BINARYEN_VERSION (wasm-merge, wasm-opt) into $dir"
}

# notices_generator prints the generator of the aggrega-cli checkout beside this
# repository, and refuses when that checkout is absent.
notices_generator() {
  local gen="$SCRIPT_DIR/../../aggrega-cli/scripts/gen-third-party-licenses.sh"
  [ -f "$gen" ] || fail "the notices generator is missing: expected $gen. Check out aggrega-cli beside this repository (a sibling directory named aggrega-cli), at the release the tooling image is."
  printf '%s\n' "$gen"
}

# generate_notices <tag> <guest> <guest-dir> <out-dir> writes the guest's
# notices.md and sbom.spdx.json into <out-dir>, from the lockfile in <guest-dir>
# and the toolchain and caches of the build that just ran there.
generate_notices() {
  local t="$1" guest="$2" gdir="$3" gout="$4" gen
  gen="$(notices_generator)"
  if ! bash "$gen" --guest "$gdir" --out "$gout"; then
    fail "$t: the third-party notices and SBOM of $guest could not be generated; its output is above."
  fi
  local f
  for f in notices.md sbom.spdx.json; do
    [ -s "$gout/$f" ] || fail "$t: generating the notices of $guest left no $f in $gout"
  done
}

cmd_build() {
  local tags_arg="" tags_set=false work="" out="" repo="$SCRIPT_DIR/.."
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tags) [ "$#" -ge 2 ] || usage_error "--tags needs a value"; tags_arg="$2"; tags_set=true; shift 2 ;;
      --work) [ "$#" -ge 2 ] || usage_error "--work needs a value"; work="$2"; shift 2 ;;
      --out) [ "$#" -ge 2 ] || usage_error "--out needs a value"; out="$2"; shift 2 ;;
      --repo) [ "$#" -ge 2 ] || usage_error "--repo needs a value"; repo="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "build: unknown argument '$1'" ;;
    esac
  done
  "$tags_set" || usage_error "build needs --tags"
  [ -n "$work" ] || usage_error "build needs --work"
  [ -n "$out" ] || usage_error "build needs --out"
  local tags=()
  read -r -a tags <<< "$tags_arg"
  [ "${#tags[@]}" -gt 0 ] || usage_error "build needs at least one tag in --tags"

  repo="$(repo_root "$repo")"

  local t
  for t in "${tags[@]}"; do
    check_tag "$repo" "$t"
  done

  if [ -e "$work" ] && [ -n "$(ls -A "$work")" ]; then
    fail "the work directory $work is not empty; give the build an absent or empty one"
  fi
  mkdir -p "$work" "$out"
  work="$(cd "$work" && pwd)"
  out="$(cd "$out" && pwd)"

  local clone="$work/aggrega-plugins"
  git clone --quiet "$repo" "$clone"

  local guest version commit entity entity_version gout log stamp stamped_version stamped_commit
  for t in "${tags[@]}"; do
    guest="${t%%/v*}"
    version="${t#*/v}"
    git -C "$clone" checkout --quiet --detach "refs/tags/$t"
    commit="$(git -C "$clone" rev-parse HEAD)"
    say "$t: building $guest $version from $commit"

    entity="$clone/$guest/plugin.yaml"
    entity_version="$(plugin_entity_metadata "$entity" version)"
    if [ "$entity_version" != "$version" ]; then
      fail "$t: the entity $guest/plugin.yaml at that tag records metadata.version '${entity_version:-<none>}', not the tag's version '$version'. A tag names the commit that carries the entity it releases: set metadata.version, commit, and tag that commit."
    fi

    gout="$out/$guest"
    [ ! -e "$gout" ] || fail "$t: $gout already exists; one build per guest"
    mkdir -p "$gout"
    log="$work/$guest.build.log"
    if ! (cd "$clone/$guest" && AGGREGA_PLUGIN_WASM_OUT="$gout" bash ./build.sh) 2>&1 | tee "$log"; then
      fail "$t: $guest/build.sh failed; its output is above"
    fi

    stamp="$(awk '/^Stamping version / { print; exit }' "$log")"
    [ -n "$stamp" ] || fail "$t: the build printed no 'Stamping version' line, so the version it stamped is unknown"
    stamped_version="$(printf '%s\n' "$stamp" | awk '{ v = $3; sub(/,$/, "", v); print v }')"
    stamped_commit="$(printf '%s\n' "$stamp" | awk '{ print $5 }')"
    if [ "$stamped_version" != "$version" ]; then
      fail "$t: the build stamped version '$stamped_version', not the tag's version '$version'. The stamp is the release tag git describe finds for the built commit, so it is the tag's version only when the tree is the clean commit the tag names and no other release tag of $guest names that commit."
    fi

    shopt -s nullglob
    local wasms=("$gout"/*.wasm)
    shopt -u nullglob
    [ "${#wasms[@]}" -eq 1 ] || fail "$t: the build left ${#wasms[@]} .wasm files in $gout, where one was expected"
    # A build that writes a file the tag does not carry has made something up,
    # most often a lockfile the guest does not commit (cargo writes Cargo.lock
    # when it is absent). Notices drawn from it would describe no committed
    # input, so the build refuses.
    local changed
    changed="$(git -C "$clone" status --porcelain --untracked-files=all -- "$guest")"
    if [ -n "$changed" ]; then
      fail "$t: building $guest changed its tree, which the tag names clean:
$changed
A guest commits its lockfile (go.sum, Cargo.lock or package-lock.json) and the build leaves it as committed."
    fi
    generate_notices "$t" "$guest" "$clone/$guest" "$gout"
    cp "$entity" "$gout/plugin.yaml"
    printf 'tag=%s\nversion=%s\ncommit=%s\nstamped=%s %s\n' \
      "$t" "$version" "$commit" "$stamped_version" "$stamped_commit" > "$gout/build.txt"
    say "$t: built $(basename "${wasms[0]}") stamped $stamped_version, commit $stamped_commit; entity metadata.version $entity_version"
  done
}

cmd_publish() {
  local dir="" registry="" dry=false sign=false key=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) [ "$#" -ge 2 ] || usage_error "--dir needs a value"; dir="$2"; shift 2 ;;
      --registry) [ "$#" -ge 2 ] || usage_error "--registry needs a value"; registry="$2"; shift 2 ;;
      --dry-run) dry=true; shift ;;
      --sign) sign=true; shift ;;
      --key) [ "$#" -ge 2 ] || usage_error "--key needs a value"; key="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "publish: unknown argument '$1'" ;;
    esac
  done
  [ -n "$dir" ] || usage_error "publish needs --dir"
  [ -n "$registry" ] || usage_error "publish needs --registry"
  if "$dry" && "$sign"; then usage_error "publish takes --dry-run or --sign, not both"; fi
  if ! "$dry" && ! "$sign"; then usage_error "publish needs --dry-run, or --sign for a signed publication"; fi
  if [ -n "$key" ] && ! "$sign"; then usage_error "--key goes with --sign"; fi
  [ -d "$dir" ] || fail "no build output at $dir"

  local aggrega="${AGGREGA_BIN:-aggrega}"
  local gdirs=() gdir
  shopt -s nullglob
  for gdir in "$dir"/*/; do
    [ -f "$gdir/plugin.yaml" ] && gdirs+=("${gdir%/}")
  done
  [ "${#gdirs[@]}" -gt 0 ] || fail "no built guest in $dir: each guest's entity is expected at <dir>/<guest>/plugin.yaml"

  local wasms args f
  for gdir in "${gdirs[@]}"; do
    for f in notices.md sbom.spdx.json; do
      [ -s "$gdir/$f" ] || fail "$(basename "$gdir"): $f is missing from $gdir; nothing was pushed. A build writes it beside the .wasm."
    done
  done
  for gdir in "${gdirs[@]}"; do
    wasms=("$gdir"/*.wasm)
    [ "${#wasms[@]}" -eq 1 ] || fail "$gdir holds ${#wasms[@]} .wasm files, where one was expected"
    if [ -f "$gdir/build.txt" ]; then
      say "$(basename "$gdir"): $(awk -F= '$1 == "tag" { printf "tag %s", $2 } $1 == "commit" { printf ", commit %s", $2 }' "$gdir/build.txt")"
    fi
    args=(push "$gdir/plugin.yaml" --plugin "${wasms[0]}" --plugin-notices "$gdir/notices.md" --plugin-sbom "$gdir/sbom.spdx.json" --registry "$registry")
    if "$dry"; then
      args+=(--dry-run)
    else
      args+=(--sign)
      [ -z "$key" ] || args+=(--key "$key")
    fi
    "$aggrega" "${args[@]}"
  done
  shopt -u nullglob
}

if [ "$#" -eq 0 ]; then
  usage_error "name a command: resolve, install-tools, build or publish"
fi
command="$1"
shift
case "$command" in
  resolve) cmd_resolve "$@" ;;
  install-tools) cmd_install_tools "$@" ;;
  build) cmd_build "$@" ;;
  publish) cmd_publish "$@" ;;
  -h|--help) usage ;;
  *) usage_error "unknown command '$command'" ;;
esac
