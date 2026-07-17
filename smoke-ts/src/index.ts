// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Cognitio S.r.l.

/**
 * A minimal cli smoke plugin for the Aggrega Wasm runtime, in TypeScript.
 *
 * It contributes one runtime subcommand — `smoke-ts` — that reports the
 * argument vector it received and returns an exit code. It exists to prove the
 * TypeScript PDK's cli_run path end to end: a describe() self-report declaring
 * plugin_type `cli`, a one-element commands list carrying the command's name
 * and short description, and the cli_run export; a cli_run body that reads its
 * arguments through cliArgs() and streams a line through writeStdout().
 *
 * The exit code demonstrates that a guest's status reaches the shell verbatim:
 * a first argument of `fail` returns a non-zero code, any other invocation
 * returns zero.
 */

import {
  API_VERSION,
  cliArgs,
  encodeDescriptor,
  type PluginDescriptor,
  writeStdout,
} from "@aggrega-ai/aggrega-pdk-typescript";

// The static describe() self-report: a v1alpha1 cli plugin contributing a
// single command, "smoke-ts". Each entry in the commands list carries a name —
// the token the host installs the subcommand under — and a description, its
// short help. The cli_run export declares the stdout streaming host function it
// imports, which the host grants under the runtime CLI profile. The descriptor
// is built with typed PDK values and encoded through encodeDescriptor rather
// than hand-written JSON.
function descriptor(): PluginDescriptor {
  return {
    abi_version: API_VERSION,
    plugin_type: "cli",
    exports: [
      { name: "cli_run", host_functions: ["aggrega_cli_write_stdout"] },
    ],
    commands: [
      {
        name: "smoke-ts",
        description: "Report the argument vector from a TypeScript cli plugin.",
      },
    ],
    metadata: { author: "aggrega", license: "Apache-2.0" },
  };
}

// The host calls describe() once at load to read the plugin's static
// self-report before dispatching cli_run.
function describe(): void {
  Host.outputString(encodeDescriptor(descriptor()));
}

function cli_run(): number {
  const args = cliArgs();
  const failing = args.length > 0 && args[0] === "fail";
  const code = failing ? 7 : 0;
  writeStdout(
    Memory.fromString(
      `smoke-ts: ${args.length} arg(s): [${args.join(" ")}] exit ${code}\n`,
    ).readBytes(),
  );
  return code;
}

module.exports = { describe, cli_run };
