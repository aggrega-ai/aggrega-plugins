// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Cognitio S.r.l.

//! A minimal cli smoke plugin for the Aggrega Wasm runtime, in Rust.
//!
//! It contributes one runtime subcommand — `smoke-rust` — that reports the
//! argument vector it received and exits with code zero. It exists to prove the
//! Rust PDK's `cli_run` path end to end: a `describe()` self-report declaring
//! plugin_type `cli`, a one-element commands list carrying the command's name
//! and short description, and the `cli_run` export; a `cli_run` body that reads
//! its arguments through `cli_args` and streams a line through `write_stdout`.
//! The descriptor is built with typed PDK values and encoded through the kit's
//! `aggrega_pdk_rust::describe!` macro rather than hand-written JSON, which
//! also folds in the version and commit the build stamps.
//!
//! Build: `./build.sh`, which stamps the version and commit and runs
//! `cargo build --release --target wasm32-wasip1`.

use aggrega_pdk_rust::{
    cli_args, write_stdout, PluginCLICommand, PluginDescriptor, PluginDescriptorMeta,
    PluginExport, API_VERSION,
};
use extism_pdk::{plugin_fn, FnResult};

/// The static `describe()` self-report: a v1alpha1 `cli` plugin contributing a
/// single command, `smoke-rust`. Each entry in the commands list carries a name
/// — the token the host installs the subcommand under — and a description, its
/// short help. The `cli_run` export declares the stdout streaming host function
/// it imports, which the host grants under the runtime CLI profile.
fn descriptor() -> PluginDescriptor {
    PluginDescriptor {
        abi_version: API_VERSION.to_string(),
        plugin_type: "cli".to_string(),
        exports: vec![PluginExport {
            name: "cli_run".to_string(),
            host_functions: vec!["aggrega_cli_write_stdout".to_string()],
            ..Default::default()
        }],
        commands: vec![PluginCLICommand {
            name: "smoke-rust".to_string(),
            description: "Report the argument vector from a Rust cli plugin.".to_string(),
            ..Default::default()
        }],
        metadata: Some(Box::new(PluginDescriptorMeta {
            author: "aggrega".to_string(),
            license: "Apache-2.0".to_string(),
            ..Default::default()
        })),
        ..Default::default()
    }
}

/// The host calls `describe()` once at load to read the plugin's static
/// self-report before dispatching `cli_run`. The kit's `describe!` macro
/// expands here, in this crate, so the version and commit the build script
/// stamps at compile time reach the self-report.
#[plugin_fn]
pub fn describe() -> FnResult<String> {
    Ok(aggrega_pdk_rust::describe!(descriptor()))
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
