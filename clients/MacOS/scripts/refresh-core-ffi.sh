#!/usr/bin/env bash
#
# 刷新 macOS 客户端使用的 Rust core FFI 产物：
#   1. cargo build --release 产出 libterminal_finder_core.a
#   2. uniffi-bindgen 生成 Swift 绑定
#   3. 拷贝到客户端目录：
#        Vendor/CoreFFI/        libterminal_finder_core.a + 头文件 + module.modulemap
#        MacOS/Core/Generated/  terminal_finder_core.swift（同步组，自动入 target）
#
# Rust 侧接口变更后运行本脚本，再用 Xcode 构建。

set -euo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$CLIENT_DIR/../.." && pwd)"
CORE_DIR="$REPO_ROOT/core"

VENDOR_DIR="$CLIENT_DIR/Vendor/CoreFFI"
GENERATED_DIR="$CLIENT_DIR/MacOS/Core/Generated"
BINDINGS_DIR="$CORE_DIR/target/bindings/swift"

echo "==> building Rust core (release)"
cargo build --release --manifest-path "$CORE_DIR/Cargo.toml"

echo "==> generating Swift bindings"
# uniffi-bindgen 内部调用 cargo metadata，必须在 core 目录下执行。
(
  cd "$CORE_DIR"
  cargo run --release --features bindgen --bin uniffi-bindgen -- \
    generate \
    --library target/release/libterminal_finder_core.dylib \
    --language swift \
    --out-dir "$BINDINGS_DIR"
)

echo "==> vendoring artifacts into client"
mkdir -p "$VENDOR_DIR" "$GENERATED_DIR"
cp "$CORE_DIR/target/release/libterminal_finder_core.a" "$VENDOR_DIR/"
cp "$BINDINGS_DIR/terminal_finder_coreFFI.h" "$VENDOR_DIR/"
# Swift 经 SWIFT_INCLUDE_PATHS 查找的 clang module 必须叫 module.modulemap。
cp "$BINDINGS_DIR/terminal_finder_coreFFI.modulemap" "$VENDOR_DIR/module.modulemap"
cp "$BINDINGS_DIR/terminal_finder_core.swift" "$GENERATED_DIR/"

echo "==> done:"
ls -lh "$VENDOR_DIR" "$GENERATED_DIR"
