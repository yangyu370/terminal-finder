#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$base"
if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
    printf '%s\n' 'This MVP bootstrap is verified for Apple Silicon macOS only.' >&2
    exit 1
fi
mkdir -p .tools .cache/natives
if [ ! -x .tools/go/bin/go ]; then
    curl --noproxy '*' -fL --max-time 180 https://go.dev/dl/go1.27.2.darwin-arm64.tar.gz -o .cache/go.tar.gz
    printf '%s\n' '76812b213b1b2302c978d28fa52fa92d541704b9e7d9d5db8002c50e4018c4c5  .cache/go.tar.gz' | shasum -a 256 -c -
    tar -xzf .cache/go.tar.gz -C .tools
fi
if [ ! -f .cache/natives/libghostty-vt.dylib ]; then
    curl --noproxy '*' -fL --max-time 120 https://github.com/egoist/mygo/releases/download/libghostty-vt-befcdfd2c3a1/libghostty-vt-darwin-arm64.dylib -o .cache/natives/libghostty-vt.dylib
fi
printf '%s\n' '6f385d3221f8c776ba40530db9baf8c71478907897959849896eeb0ddbf16b41  .cache/natives/libghostty-vt.dylib' | shasum -a 256 -c -
./go-local mod download
