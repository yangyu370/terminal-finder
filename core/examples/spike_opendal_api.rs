//! # OpenDAL 0.53 API ground-truth spike
//!
//! Run with: `cargo run --example spike_opendal_api`
//!
//! This file does NOT make network requests. Its job is to compile against the
//! real OpenDAL 0.53 surface and lock down four facts that the design document
//! left ambiguous. The conclusions below are what the rest of `vfs/s3.rs`
//! relies on.
//!
//! ## Conclusion 1 — Builder chain
//!
//! `S3::default()` returns a builder. Configuration is chained:
//!   - `.endpoint(&str)`     — server URL including scheme
//!   - `.region(&str)`       — region string (R2 wants "auto", MinIO accepts "us-east-1")
//!   - `.bucket(&str)`       — bucket name
//!   - `.access_key_id(&str)`
//!   - `.secret_access_key(&str)`
//!
//! ## Conclusion 2 — path-style addressing
//!
//! OpenDAL 0.53 method: `.enable_virtual_host_style()` switches to virtual-hosted style.
//! Default is path-style (which MinIO requires). For R2 (virtual-hosted), CALL
//! `.enable_virtual_host_style()`. For MinIO (path-style), DO NOT call it.
//!
//! ## Conclusion 3 — Operator finish
//!
//! `Operator::new(builder)?.finish()` returns `Operator`. The intermediate
//! `OperatorBuilder` is from `Operator::new(builder)?`. Both stages must succeed
//! before list/stat/read.
//!
//! ## Conclusion 4 — Error kinds mapping (opendal::ErrorKind → ApiError)
//!
//! | opendal::ErrorKind     | ApiError variant                  |
//! |------------------------|-----------------------------------|
//! | NotFound               | ObjectNotFound { path }           |
//! | PermissionDenied       | AuthenticationFailed { conn, msg }|
//! | ConfigInvalid          | AuthenticationFailed { conn, msg }|
//! | Unexpected (network)   | NetworkError { op, msg }          |
//! | (other)                | ProviderError { op, msg }         |
//!
//! Note: `opendal::Error` exposes `.kind() -> ErrorKind` and `.to_string()` for
//! diagnostic message. `is_temporary()` indicates retryability.
//!
//! ## Fallback
//!
//! If a future opendal version breaks these assumptions, see
//! `CLOUD_RESOURCE_MANAGER_DESIGN.md §2.1` for the aws-sdk-s3 fallback decision.

use opendal::{Operator, services::S3};

fn main() {
    // Conclusion 1 + 2 + 3: build an operator for MinIO (path-style).
    let builder = S3::default()
        .endpoint("http://localhost:9000")
        .region("us-east-1")
        .bucket("test-bucket")
        .access_key_id("minioadmin")
        .secret_access_key("minioadmin");
    // path-style is default; we do NOT call .enable_virtual_host_style()

    let op = Operator::new(builder).expect("builder is valid").finish();

    println!(
        "MinIO Operator constructed: scheme={:?}",
        op.info().scheme()
    );

    // Conclusion 1 + 2 + 3: build an operator for R2 (virtual-hosted).
    let r2_builder = S3::default()
        .endpoint("https://example.r2.cloudflarestorage.com")
        .region("auto")
        .bucket("prod-bucket")
        .access_key_id("R2_KEY")
        .secret_access_key("R2_SECRET")
        .enable_virtual_host_style();

    let r2_op = Operator::new(r2_builder)
        .expect("R2 builder is valid")
        .finish();

    println!(
        "R2 Operator constructed: scheme={:?}",
        r2_op.info().scheme()
    );

    println!("Spike compiled and operators constructed without network calls. ✓");
}
