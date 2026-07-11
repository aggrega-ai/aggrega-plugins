// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Cognitio S.r.l.

//! A minimal cli smoke plugin for the Aggrega Wasm runtime, in Rust.
//!
//! It contributes one runtime subcommand — `smoke-rust` — that reports the
//! argument vector it received and exits with code zero. It exists to prove the
//! Rust PDK's `cli_run` path end to end: a `describe()` self-report declaring
//! plugin_type `cli`, the command name, a short description, and the `cli_run`
//! export; a `cli_run` body that reads its arguments through `cli_args` and
//! streams a line through `write_stdout`.
//!
//! Build: `cargo build --release --target wasm32-wasip1`

use aggrega_pdk_rust::{cli_args, write_stdout};
use extism_pdk::{plugin_fn, FnResult};

/// The static `describe()` self-report: a v1alpha1 `cli` plugin contributing
/// the `smoke-rust` command. The `cli_run` export declares the stdout streaming
/// host function it imports, which the host grants under the runtime CLI profile.
const PLUGIN_DESCRIPTOR: &str = r#"{"abi_version":"v1alpha1","plugin_type":"cli","command":"smoke-rust","description":"Report the argument vector from a Rust cli plugin.","exports":[{"name":"cli_run","host_functions":["aggrega_cli_write_stdout"]}],"metadata":{"author":"aggrega","license":"Apache-2.0"}}"#;

/// The host calls `describe()` once at load to read the plugin's static
/// self-report before dispatching `cli_run`.
#[plugin_fn]
pub fn describe() -> FnResult<String> {
    Ok(PLUGIN_DESCRIPTOR.to_string())
}

/// `cli_run` reads the invocation's argument vector, reports how many arguments
/// it received and their joined form on a single line, and returns exit code
/// zero.
#[plugin_fn]
pub fn cli_run() -> FnResult<()> {
    let args = cli_args()?;
    write_stdout(format!("smoke-rust: {} arg(s): [{}]\n", args.len(), args.join(" ")).as_bytes());
    Ok(())
}
