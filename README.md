# aggrega-plugins

A showcase of Aggrega CLI plugins: WebAssembly guests that install as
top-level `aggrega <command>` subcommands. Each plugin is a self-contained
`cli` plugin — it declares the command it contributes, takes an argument
vector in, streams its output, and returns an exit code. The compiler is
blind to what a plugin does; the WebAssembly runtime executes its bytes and
routes the argument vector in and the streamed output plus exit code out.

## Plugins in this repository

| Directory     | Command      | Language   | What it does                                        |
| ------------- | ------------ | ---------- | --------------------------------------------------- |
| `moo/`        | `moo`        | Go         | Prints a friendly cow.                               |
| `smoke-rust/` | `smoke-rust` | Rust       | Reports the argument vector it received.            |
| `smoke-ts/`   | `smoke-ts`   | TypeScript | Reports the argument vector; returns an exit code.  |

`moo` is the full showcase. The two `smoke-*` guests are minimal `cli_run`
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

## Author, build, publish, run

A plugin travels from source to a working `aggrega <command>` in two hands: an
author builds and publishes the guest to a registry, and a user adds it from
that registry by name. There is no local-path install — a plugin is always
resolved from a registry, or, for the built-ins, from the binary itself.

### Author and publish

Build a guest to a `.wasm` artifact with its `build.sh`. Each build script
writes the artifact next to its source by default; set `AGGREGA_PLUGIN_WASM_OUT`
to write it elsewhere.

```sh
# 1. Build the guest to a .wasm artifact.
./moo/build.sh                                   # writes moo/moo.wasm

# 2. Align the entity's machine-owned records — the host functions it may call
#    and the commands it contributes — with the freshly built bytes.
aggrega plugin sync moo/plugin.yaml --plugin moo/moo.wasm

# 3. Publish the entity and its artifact to the registry. Publishing signs the
#    artifact and records the content digest of its verified bytes; it first
#    checks the entity's synced records against the .wasm and refuses a file
#    whose records have drifted from its binary.
aggrega push moo/plugin.yaml --plugin moo/moo.wasm
```

When you are starting an entity from the binary rather than editing one by hand,
`aggrega plugin gen-catalog` generates a `Plugin` entity from a guest's
`describe()` self-report plus an authored overlay.

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

The smoke guests follow the same shape — build, sync, publish, then add and run:

```sh
./smoke-rust/build.sh                            # cargo build --release --target wasm32-wasip1
aggrega plugin sync smoke-rust/plugin.yaml --plugin smoke-rust/smoke-rust.wasm
aggrega push smoke-rust/plugin.yaml --plugin smoke-rust/smoke-rust.wasm
aggrega plugin add cli smoke-rust
aggrega smoke-rust alpha beta                    # -> smoke-rust: 2 arg(s): [alpha beta]

./smoke-ts/build.sh                              # extism-js compile of the bundled TypeScript
aggrega plugin sync smoke-ts/plugin.yaml --plugin smoke-ts/smoke-ts.wasm
aggrega push smoke-ts/plugin.yaml --plugin smoke-ts/smoke-ts.wasm
aggrega plugin add cli smoke-ts
aggrega smoke-ts hello world                     # exit 0
aggrega smoke-ts fail now                        # exit 7 — a non-zero status reaches the shell
```

## Build prerequisites

- `moo` (Go): a Go toolchain with the `wasip1`/`wasm` target.
- `smoke-rust` (Rust): a Rust toolchain with the `wasm32-wasip1` target
  (`rustup target add wasm32-wasip1`).
- `smoke-ts` (TypeScript): Node with `npm`, the `extism-js` compiler, and the
  binaryen tools (`wasm-merge`, `wasm-opt`) on `PATH`.

Each guest depends on the matching Aggrega plugin development kit. The build
files reference the kit from a sibling checkout, so this repository builds
alongside the plugin development kits.
