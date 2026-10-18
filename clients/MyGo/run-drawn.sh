#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$base/dist/Terminal Finder Drawn.app"
if [ ! -x "$app/Contents/MacOS/terminal-finder-drawn" ]; then "$base/build-drawn.sh"; fi
exec "$app/Contents/MacOS/terminal-finder-drawn" "$@"
