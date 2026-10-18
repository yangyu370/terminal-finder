#!/bin/sh
# A deliberately strict gate: nonzero while ANY native component pixel differs.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$base"
out="${TF_PIXEL_AUDIT:-$base/dist/pixel-audit}"
mkdir -p "$out/candidate"
TF_PIXEL_OUTPUT="$out/candidate" ./go-local test -count=1 -run TestCaptureFinderPixelProbes ./internal/finderui
./go-local build -o "$out/finder-pixel-diff" ./cmd/finder-pixel-diff
"$out/finder-pixel-diff" --reference internal/finderui/testdata/finder26-dark --candidate "$out/candidate" --out "$out/diff" --require-exact
