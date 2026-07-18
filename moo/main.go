// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Cognitio S.r.l.

// The moo cli plugin for the Aggrega Wasm runtime.
//
// It contributes one runtime subcommand — "moo" — that prints a friendly
// cowsay-style cow to standard output and exits with code zero. It is the
// showcase shape of a CLI plugin: a describe() self-report declaring
// plugin_type "cli", a one-element commands list carrying the command name
// "moo", a short description, and the --alien flag, and the cli_run export,
// plus a cli_run body that streams the cow through the stdout streaming host
// function in a single write. The descriptor is built with typed PDK values
// and marshaled through aggrega.MarshalDescriptor rather than hand-written JSON.
//
// The plugin declares no capability beyond the CLI baseline — it takes no
// input, streams output, and returns an exit code — so installing it asks for
// no additional grants.
//
// Build: GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o moo.wasm ./
package main

import (
	pdk "github.com/extism/go-pdk"

	"github.com/aggrega-ai/aggrega-pdk-go/pkg/aggrega"
)

// alienFlag is the long name of the --alien flag moo declares. When it appears
// in the argument vector, cli_run streams the UFO abduction scene instead of
// the cow.
const alienFlag = "--alien"

// descriptor is the static describe() self-report: a v1alpha1 cli plugin
// contributing a single command, "moo", carrying one flag. The command's name
// is the token the host installs the subcommand under; its flags are registered
// on the command so aggrega help moo lists them like a core command's flags. The
// cli_run export declares the stdout streaming host function it imports, which
// the host grants under the runtime CLI profile.
func descriptor() aggrega.PluginDescriptor {
	return aggrega.PluginDescriptor{
		AbiVersion: aggrega.APIVersion,
		PluginType: "cli",
		Exports: []aggrega.PluginExport{
			{Name: "cli_run", HostFunctions: []string{"aggrega_cli_write_stdout"}},
		},
		Commands: []aggrega.PluginCLICommand{{
			Name:        "moo",
			Description: "This Aggrega has Super Cow Powers.",
			Flags: []aggrega.PluginCommandFlag{{
				Name:        "alien",
				Description: "Print a UFO abduction scene instead of the cow.",
				Type:        "bool",
				Default:     "false",
			}},
		}},
		Metadata: &aggrega.PluginDescriptorMeta{Author: "aggrega", License: "Apache-2.0"},
	}
}

// cow is the full frame streamed in one write: a speech bubble carrying the
// message above the classic cow art.
const cow = ` _______________________
< Have you mooed today? >
 -----------------------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||
`

// alien is the full frame streamed in one write when the caller passes
// --alien: a UFO tractor-beaming the classic cow, closed by an overline
// ground bar.
const alien = `            .-------.
         _-' O O O O '-_
        /_______________\
        \_______________/
        / | | | | | | | \
       /  | | | | | | |  \
      /   | | | | | | |   \
     /                     \
    /    Moooo!             \
   /     ^__^                \
  /      (@@)\_______         \
 /       (__)\       )\/\/*    \
/            ||----w |          \
             ||     ||           
‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
`

//go:wasmexport describe
func describe() int32 {
	out, err := aggrega.MarshalDescriptor(descriptor())
	if err != nil {
		pdk.SetError(err)
		return 1
	}
	pdk.Output(out)
	return 0
}

//go:wasmexport cli_run
func cli_run() int32 {
	args, err := aggrega.CLIArgs()
	if err != nil {
		pdk.SetError(err)
		return 1
	}
	for _, a := range args {
		if a == alienFlag {
			aggrega.WriteStdout([]byte(alien))
			return 0
		}
	}
	aggrega.WriteStdout([]byte(cow))
	return 0
}

func main() {}
