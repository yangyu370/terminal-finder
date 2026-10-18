#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$base/../.." && pwd)
core_repo=${TF_CORE_REPO:-$repo}
cargo_bin=${CARGO:-cargo}
if [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    export CC=/Library/Developer/CommandLineTools/usr/bin/clang
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk
    export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$CC"
fi
"$cargo_bin" build --locked --manifest-path "$core_repo/core/Cargo.toml" --target-dir "$base/.cache/rust-target" --features server --bin core
