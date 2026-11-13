module github.com/aggrega-ai/aggrega-plugins/moo

go 1.26.0

require (
	github.com/aggrega-ai/aggrega-pdk/go v0.0.0
	github.com/extism/go-pdk v1.1.3
)

require github.com/aggrega-ai/aggrega-abi/go v0.0.0 // indirect

replace github.com/aggrega-ai/aggrega-pdk/go => ../../aggrega-pdk/go

replace github.com/aggrega-ai/aggrega-abi/go => ../../aggrega-abi/go
