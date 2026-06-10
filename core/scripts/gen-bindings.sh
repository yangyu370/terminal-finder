#!/usr/bin/env bash
#
# 生成 Swift 的 UniFFI 绑定（library 模式：从编译好的 cdylib 读元数据）。
#
# 用法：
#   core/scripts/gen-bindings.sh [OUT_DIR]
#
# OUT_DIR 默认 core/target/bindings/swift。产物：
#   terminal_finder_core.swift        Swift API
#   terminal_finder_coreFFI.h         C 头文件
#   terminal_finder_coreFFI.modulemap module map

set -euo pipefail

# 定位 core/ 目录（脚本在 core/scripts/ 下）。
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CORE_DIR"

OUT_DIR="${1:-target/bindings/swift}"
LIB_NAME="libterminal_finder_core.dylib"
LIB_PATH="target/debug/${LIB_NAME}"

echo "==> building cdylib ($LIB_NAME)"
cargo build

echo "==> generating Swift bindings -> $OUT_DIR"
cargo run --features bindgen --bin uniffi-bindgen -- \
  generate \
  --library "$LIB_PATH" \
  --language swift \
  --out-dir "$OUT_DIR"

echo "==> done:"
ls -1 "$OUT_DIR"
