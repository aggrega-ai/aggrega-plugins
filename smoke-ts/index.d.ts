// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Cognitio s.r.l.

// Interface declaration consumed by extism-js at compile time.
// The `extism:host` user interface declares the streaming stdout host
// function the plugin imports under the runtime CLI profile; the `main`
// module declares the plugin's exported functions for extism-js to bind.

declare module "extism:host" {
  interface user {
    aggrega_cli_write_stdout(ptr: I64, len: I64): void;
  }
}

declare module "main" {
  export function cli_run(): I32;
  export function describe(): I32;
}
