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

Each guest ships a `plugin.yaml` — the `Plugin` entity that names the plugin,
its version, and the artifact reference the CLI resolves. The entity's
identity is its reference plus its version; the resolved content digest lives
in the lockfile, not in the entity.

## Author, build, install, run

Build a guest to a `.wasm` artifact with its `build.sh`, then install and run
it. Each build script writes the artifact next to its source by default; set
`AGGREGA_PLUGIN_WASM_OUT` to write it elsewhere (for example a sidecar
directory).

```sh
# 1. Build the guest to a .wasm artifact.
./moo/build.sh                      # writes moo/moo.wasm

# 2. Install it as a top-level command. The install prints the plugin's
#    declared capabilities and asks for confirmation; pass --yes for a
#    non-interactive run.
aggrega plugin install ./moo/moo.wasm --yes

# 3. Run it.
aggrega moo
```

`aggrega plugin install` resolves the reference, loads the guest to read its
`describe()` self-report, confirms the plugin's capabilities, and registers
the command it contributes. A reference is resolved through the plugin
cascade: an embedded built-in, a sidecar directory, an explicit local path,
the content cache, or a registry. A local path (`./moo/moo.wasm`) resolves
with no network and no registry — the shortest path from a freshly built
guest to a working command.

The smoke guests follow the same shape:

```sh
./smoke-rust/build.sh               # cargo build --release --target wasm32-wasip1
aggrega plugin install ./smoke-rust/smoke-rust.wasm --yes
aggrega smoke-rust alpha beta       # -> smoke-rust: 2 arg(s): [alpha beta]

./smoke-ts/build.sh                 # extism-js compile of the bundled TypeScript
aggrega plugin install ./smoke-ts/smoke-ts.wasm --yes
aggrega smoke-ts hello world        # exit 0
aggrega smoke-ts fail now           # exit 7 — a non-zero status reaches the shell
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
