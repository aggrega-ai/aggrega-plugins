# aggrega-plugins

Aggrega plugins that ship neither inside the compiler binary nor as core
plugins: WebAssembly guests published to a registry and resolved from there.
Every socket belongs here — a `cli` plugin that installs as a top-level
`aggrega <command>`, a `pipeline-step` plugin a feature recipe runs over
rendered documents, and any other socket a guest targets. The compiler is blind
to what a plugin does; the WebAssembly runtime executes its bytes and moves the
socket's payload in and its result out.

Each guest is a directory holding its source, a `build.sh` that compiles it to
a `.wasm` artifact, and the `Plugin` entity that describes it. The one file the
guests share is `lib/build-version.sh`, the recipe every `build.sh` sources for
the version and commit it stamps into the guest. Built artifacts are not
committed — `build.sh` writes one beside its source.

## Plugins in this repository

| Directory                  | Socket          | Language   | What it does                                                       |
| -------------------------- | --------------- | ---------- | ------------------------------------------------------------------ |
| `moo/`                     | `cli`           | Go         | Prints a friendly cow.                                              |
| `smoke-rust/`              | `cli`           | Rust       | Reports the argument vector it received.                            |
| `smoke-ts/`                | `cli`           | TypeScript | Reports the argument vector; returns an exit code.                  |
| `litellm-gateway-config/`  | `pipeline-step` | Rust       | Writes runtime controls into an AI gateway's rendered configuration. |

`moo` is the full `cli` showcase. The two `smoke-*` guests are minimal `cli_run`
proofs, one per plugin-authoring language. Each declares no capability beyond
the CLI baseline (an argument vector in; streamed stdout/stderr; an exit code
out), so installing any of them asks for no additional grants.

## Anatomy of a cli plugin

Every guest is two exports:

- `describe()` returns a static JSON self-report declaring `plugin_type: cli`,
  the `command` name it contributes, a one-line description, and the `cli_run`
  export together with the host functions it imports (here, the stdout
  streaming function).
- `cli_run()` reads its argument vector, streams output through the host, and
  returns an exit code. A zero code is success; a non-zero code reaches the
  shell as the command's status.

Each guest ships a `plugin.yaml` — the `Plugin` entity that names the plugin
and its version and declares its ABI version, exports, the host functions it
may call, and the commands it contributes. The entity's identity is its name
and its version; the `.wasm` artifact and the content digest of its verified
bytes are bound at publish time, not written into the entity by hand.

## Anatomy of a pipeline-step plugin

A `pipeline-step` guest is reached from a `FeatureRecipe`'s `pipeline:` rather
than from the command line: a Feature attached to a component names the step,
and the step transforms documents that component's realization already
rendered. It is also two exports:

- `describe()` returns a static JSON self-report declaring
  `plugin_type: pipeline-step`, the provider capabilities the step is compatible
  with, and the `step` export together with what it operates on — `patch` or
  `emit`, over the `own` documents or the attached `host` component's.
- `step()` receives the keyed document set, the step's rendered `with` block,
  and the render context; it returns RFC 6902 patches addressed by scope and
  key, plus any side effects and diagnostics.

Two properties are worth knowing before writing one. A guest **cannot know the
emitted filenames ahead of time**, so it selects the documents it targets by
their content and echoes back the key it learned at runtime. And the declared
capability list is checked against the provider rendering the documents the step
touches, **before the guest runs** — a step written against one provider's
output shape is refused where another rendered it, so the list is a
tested-compatibility claim rather than an aspiration.

## Author, build, publish, run

A plugin travels from source to a published artifact in two hands: an author
builds and publishes the guest to a registry, and a consumer resolves it from
there — by name for a `cli` plugin a user installs, or through the entity URI a
`FeatureRecipe` step names. `aggrega plugin add` has no local-path install: a
command is always resolved from a registry, or, for the built-ins, from the
binary itself.

### Author and publish

Build a guest to a `.wasm` artifact with its `build.sh`. Each build script
writes the artifact next to its source by default; set `AGGREGA_PLUGIN_WASM_OUT`
to write it elsewhere.

#### Where a guest's version comes from

A guest's version is a git tag in this repository named after the guest's
directory: `<guest>/v<semver>`, for example `moo/v0.2.3` or
`litellm-gateway-config/v1.0.0`. Every `build.sh` sources `lib/build-version.sh`,
which describes the commit being built against that guest's tags only, strips
the `<guest>/v` prefix, and stamps the result into the guest's `describe()`
self-report together with the repository's short commit. Each build prints the
version and commit it stamped. Each kit folds the stamp in its own way: the
Rust guests' builds pass it to `cargo build` for the kit's `describe!` macro,
the TypeScript guest's build defines it in the bundle for the kit's
`encodeDescriptor`, and the Go guest's build sets it through the linker for the
kit's `MarshalDescriptor`.

The tag is the version's source. The `version` in a guest's `Cargo.toml` or
`package.json` is not read by the stamp, and the entity's `metadata.version` is
held to the stamp when the guest is published.

| The tree being built                                  | Stamped version                 |
| ----------------------------------------------------- | ------------------------------- |
| the commit the guest's tag names, with no local edits | `0.2.3`                         |
| three commits past that tag                           | `0.2.3-3-g1a2b3c4`              |
| a commit no tag of the guest precedes                 | the short commit, `1a2b3c4`     |
| any of these, with uncommitted edits                  | the same, ending in `-dirty`    |

A tag names a commit of the whole repository, never a directory. A commit that
changes only another guest still moves this guest off its tag: after a commit
touching only `smoke-rust`, building `moo` stamps a development version such as
`0.2.3-1-g1a2b3c4` until `moo` is tagged again. To rebuild a version that is
already published, build from the commit its tag names.

#### What publishing checks

`aggrega push` reads `describe()` from the `.wasm` it is given and refuses the
entity when its records disagree with that binary: `metadata.pluginType` must be
the type the guest reports, each export the entity claims must be one the guest
declares, with the same `operates` and `scope`, `metadata.version` must equal the
version the guest stamped, and the synced host functions and commands must equal
what the guest imports and declares. A build from an untagged commit, from
a commit past the tag, or from an edited tree stamps a development version, and
publishing refuses it against the release version the entity records. That
refusal is cleared by tagging the commit and rebuilding from it, not by writing
the development version into the entity: a published version names a tagged
build.

#### Publishing a release

The steps run in this order, because the tag has to name the commit that
carries the entity it releases:

```sh
# 1. Set the release version in the entity's metadata.version, build, and align
#    the entity's machine-owned records — the host functions it may call and
#    the commands it contributes — with the freshly built bytes.
./moo/build.sh                                   # writes moo/moo.wasm
aggrega plugin sync moo/plugin.yaml --plugin moo/moo.wasm

# 2. Commit the synced entity and the source, then tag that commit with the
#    version the entity records.
git tag moo/v0.2.3

# 3. Rebuild on the clean, tagged commit, so the guest stamps the release
#    version.
./moo/build.sh                                   # Stamping version 0.2.3, commit <sha>

# 4. Publish the entity and its artifact to the registry. Publishing signs the
#    artifact and records the content digest of its verified bytes; it first
#    checks the entity's version and synced records against the .wasm and
#    refuses a file that has drifted from its binary.
aggrega push moo/plugin.yaml --plugin moo/moo.wasm
```

When you are starting an entity from the binary rather than editing one by hand,
`aggrega plugin gen-catalog` generates a `Plugin` entity from a guest's
`describe()` self-report plus an authored overlay. The generated entity carries
the version that build stamped, so one generated from a development build has
its release version set in the first step above.

### Add and run

A user adds a published cli plugin by name. `aggrega plugin add cli <name>`
searches the configured registry, resolves the query to one plugin, fetches and
verifies its bytes, caches them, and pins the command into the plugin list as a
top-level `aggrega <name>`. The pin records the resolved reference and the
content digest, so later runs execute those exact bytes from the local cache
with no further network access. The plugin's declared capabilities are shown for
confirmation before it is added; `--yes` skips that prompt for a non-interactive
run.

```sh
# Add the published plugin as a top-level command, then run it.
aggrega plugin add cli moo
aggrega moo                                      # prints the cow
aggrega moo --alien                              # prints the UFO abduction scene
```

`aggrega plugin list` shows every plugin the CLI can resolve — the embedded
built-ins and the configured commands — each with its `describe()` metadata and
readiness. `aggrega plugin remove cli moo` removes the command again, symmetric
with `add`.

The smoke guests follow the same shape — build, sync, commit and tag, rebuild
on the tagged commit, publish, then add and run:

```sh
./smoke-rust/build.sh                            # cargo build --release --target wasm32-wasip1
aggrega plugin sync smoke-rust/plugin.yaml --plugin smoke-rust/smoke-rust.wasm
git tag smoke-rust/v0.1.0                        # on the commit carrying the synced entity
./smoke-rust/build.sh                            # Stamping version 0.1.0, commit <sha>
aggrega push smoke-rust/plugin.yaml --plugin smoke-rust/smoke-rust.wasm
aggrega plugin add cli smoke-rust
aggrega smoke-rust alpha beta                    # -> smoke-rust: 2 arg(s): [alpha beta]

./smoke-ts/build.sh                              # extism-js compile of the bundled TypeScript
aggrega plugin sync smoke-ts/plugin.yaml --plugin smoke-ts/smoke-ts.wasm
git tag smoke-ts/v0.1.0                          # on the commit carrying the synced entity
./smoke-ts/build.sh                              # Stamping version 0.1.0, commit <sha>
aggrega push smoke-ts/plugin.yaml --plugin smoke-ts/smoke-ts.wasm
aggrega plugin add cli smoke-ts
aggrega smoke-ts hello world                     # exit 0
aggrega smoke-ts fail now                        # exit 7 — a non-zero status reaches the shell
```

### A pipeline-step guest: build, sync, tag, publish

A `pipeline-step` guest is built and published the same way, and there is no
`add` step: nothing installs it as a command. A `FeatureRecipe` names it by its
entity URI — `<pluginType>/<name>:<version>` — and the build resolves that entity
to its artifact when an attachment reaches the step.

```sh
./litellm-gateway-config/build.sh
aggrega plugin sync litellm-gateway-config/plugin.yaml \
  --plugin litellm-gateway-config/litellm-gateway-config.wasm
git tag litellm-gateway-config/v1.0.0            # on the commit carrying the synced entity
./litellm-gateway-config/build.sh                # Stamping version 1.0.0, commit <sha>
aggrega push litellm-gateway-config/plugin.yaml \
  --plugin litellm-gateway-config/litellm-gateway-config.wasm
```

**Publish the bytes before the entity.** Between an entity being published and
its artifact following, a build that reaches the step halts and names the plugin
it could not resolve. Publishing in this order keeps a deployment from meeting a
refusal it has no way to clear from its own side.

## Build prerequisites

- Every guest: `git`, and a clone of this repository that carries its tags,
  since the version is read from them. Outside a git checkout a build stamps
  the version `dev` and the commit `unknown`, which no release carries.
- `moo` (Go): a Go toolchain with the `wasip1`/`wasm` target.
- `smoke-rust` (Rust): a Rust toolchain with the `wasm32-wasip1` target
  (`rustup target add wasm32-wasip1`).
- `smoke-ts` (TypeScript): Node with `npm`, the `extism-js` compiler, and the
  binaryen tools (`wasm-merge`, `wasm-opt`) on `PATH`.
- `litellm-gateway-config` (Rust): a Rust toolchain with the
  `wasm32-unknown-unknown` target (`rustup target add wasm32-unknown-unknown`).

Each guest depends on the matching Aggrega plugin development kit. The build
files reference the kit from a sibling checkout, so this repository builds
alongside the plugin development kits.
