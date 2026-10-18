#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$base"
export TF_CORE_BINARY="${TF_CORE_BINARY:-$base/dist/Terminal Finder Drawn.app/Contents/Resources/terminal-finder-core}"
export MYGO_GHOSTTY_VT="${MYGO_GHOSTTY_VT:-$base/dist/Terminal Finder Drawn.app/Contents/Resources/libghostty-vt.dylib}"
export TF_DRAWN_PREVIEW="$base/.cache/drawn-preview"
mkdir -p "$TF_DRAWN_PREVIEW"
export TF_PREVIEW="$TF_DRAWN_PREVIEW/finder-terminal.png"
test -x "$TF_CORE_BINARY"
test -f "$MYGO_GHOSTTY_VT"
./go-local vet ./...
CGO_ENABLED=1 ./go-local test -race -p 1 -count=1 ./...
test -z "$(.tools/go/bin/gofmt -l cmd internal)"
