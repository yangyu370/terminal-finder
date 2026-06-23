#!/usr/bin/env bash
set -euo pipefail

IMAGE="terminal-finder-workspace:dev"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

docker build -t "$IMAGE" "$ROOT/container"
echo "built $IMAGE"
