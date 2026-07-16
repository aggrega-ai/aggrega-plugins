// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Cognitio S.r.l.

// The moo cli plugin for the Aggrega Wasm runtime.
//
// It contributes one runtime subcommand — "moo" — that prints a friendly
// cowsay-style cow to standard output and exits with code zero. It is the
// showcase shape of a CLI plugin: a describe() self-report declaring
// plugin_type "cli", a one-element commands list carrying the command name
// "moo" and a short description, and the cli_run export, plus a cli_run body
// that streams the cow through the stdout streaming host function in a single
// write.
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

// pluginDescriptor is the static describe() self-report: a v1alpha1 cli plugin
// contributing a single command, "moo". Each entry in the commands list carries
// a name — the token the host installs the subcommand under — and a
// description, its short help. The cli_run export declares the stdout streaming
// host function it imports, which the host grants under the runtime CLI profile.
const pluginDescriptor = `{"abi_version":"v1alpha1","plugin_type":"cli","commands":[{"name":"moo","description":"This Aggrega has Super Cow Powers. Pass --alien for a UFO abduction scene."}],"exports":[{"name":"cli_run","host_functions":["aggrega_cli_write_stdout"]}],"metadata":{"author":"aggrega","license":"Apache-2.0"}}`

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
     /   Moooo!            \
    /     ^__^              \
   /     (@@)\_______        \
  /      (__)\  )\/\/*        \
 /           ||----w |         \
/            ||     ||          \
‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
`

//go:wasmexport describe
func describe() int32 {
	pdk.Output([]byte(pluginDescriptor))
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
		if a == "--alien" {
			aggrega.WriteStdout([]byte(alien))
			return 0
		}
	}
	aggrega.WriteStdout([]byte(cow))
	return 0
}

func main() {}
