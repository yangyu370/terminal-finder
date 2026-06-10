//! UniFFI 绑定生成器入口（仅 `bindgen` feature）。
//!
//! 用法见 `scripts/gen-bindings.sh`，本质是 library 模式：
//! `uniffi-bindgen generate --library <dylib> --language swift --out-dir <dir>`。

fn main() {
    uniffi::uniffi_bindgen_main()
}
