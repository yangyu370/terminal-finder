# 云端资源管理器开发设计文档（Cloud Resource Manager）

> 状态：设计稿（Phase 1 部分已本地实现：Session 1a / 1b / 1c / 1d 已 merge 到本地 `master`，未 push；下一步从 Session 1e 开始）。本文件是开发计划，不是活契约；当前架构与已实现能力以根目录 `README.md` 为权威，协议以 `protocol/README.md` 为准。
>
> 约定：本文件是 `*.md` 开发文档，**不纳入 git**（遵循根/core/client `agent.md`）。

## 0. 目标

把 Terminal Finder 的 Finder UI 扩展成一个**面向开发者的云端资源管理器**，集成四类能力：

1. **云端对象存储**：生产 Cloudflare R2，开发 MinIO（均 S3 兼容）。
2. **远程 Shell**：生产 sprites.dev，开发本地 docker container。
3. **云端开发环境**：以"接入现有/远程"为形态（远程文件 + 远程 Shell + 端口转发的组合），不自建编排。
4. **文件同步**：单向手动 push/pull（不做双向持续同步与冲突引擎）。

保持现有架构的根本边界不变：**Rust core 是 source of truth，macOS client 只做表现层；core 进程内 FFI 链接，不重新引入子进程/daemon。**

---

## 1. 核心判断：4 个能力 = 2 个抽象的泛化 + 2 个新部件

现在的 core 有两个稳定契约，且都**只认本地**：

- `workspace.*`（`getState` / `openDirectory` / `listDirectory`）→ 已通过 `VfsProvider` trait 抽象（`src/vfs/`），Phase 0 完成后当前只注册 `LocalFsProvider`。
- `terminal.*`（`create` / `input` / `resize` / `close`）→ 只认本地 PTY（`portable-pty`，`src/terminal/`）。

四个需求正好收敛为：

| 需求 | 落到现有抽象上的形态 |
| --- | --- |
| 云端对象存储 | `workspace.*` 背后多一个 **S3 VfsProvider** |
| 远程 Shell | `terminal.*` 背后多一个 **RemoteExec TerminalTransport**（SSH/docker exec/sprites.dev） |
| 云端开发环境 | 一个"连接" = 远程 VFS + 远程 Shell + 端口转发，**复用上面两者**组合 |
| 文件同步 | 一个 **SyncEngine**，在两个 provider 间单向搬数据；依赖一个**本地 FileWatcher**（当前未实现） |

**关键收益**：跨平台 DTO `DirectoryEntry`（`name` / `path` / `kind` / `isDirectory` / `size` / `modifiedAt`）形状不变，客户端 icon/list/column/gallery 四种视图与终端面板**几乎不动**。新增的只是"位置带 scheme"与"连接/同步管理 UI"。

**工程地基**（Phase 0 已完成）：把 `workspace/fs.rs` 里直接调本地 FS 的逻辑，抽象成了 `VfsProvider` trait（`src/vfs/`）。地基已就位，后续三个能力是往上插插件。

---

## 2. 锁定的技术决策（Decision Record）

| 维度 | 选择 | 对设计的影响 |
| --- | --- | --- |
| 对象存储 | 生产 **Cloudflare R2** / 开发 **MinIO** | 都是 S3 兼容 → 一个 `S3Provider` 通吃；MinIO 需 **path-style** endpoint，R2 用 virtual-hosted + 自定义 endpoint |
| 远程 terminal / dev env | 生产 **sprites.dev** / 开发 **docker container** | 后续阶段；docker 可用本地 PTY 包 `docker exec -it` 极速验证，sprites.dev 走其 API transport |
| 文件同步 | **单向手动 push/pull** | 只需**本地** watcher，不做双向冲突引擎 |
| 凭据存储 | **macOS Keychain，core 拿引用** | 见 §4.1 精确语义 |

### 2.1 Crate 选型（Phase 1）

- **推荐** `opendal`**（Apache OpenDAL）做 cloud provider**：其 `Operator`（`list` / `stat` / `read` / `write` / `delete` / `presign`）几乎就是 `VfsProvider`，且**一个 crate 同时覆盖 S3/R2、SFTP、未来 WebDAV**，比分别引 `aws-sdk-s3` + ssh 库总依赖更小。
- **保守替代** `aws-sdk-s3`：R2 兼容性最稳，multipart / presigned 最精细。
- **本地 provider 保留 native** `fs.rs`**，不走 OpenDAL**：现有 symlink / 权限 / 扫描竞争 / 排序语义被 Rust 测试逐条锁死，OpenDAL 的 fs backend 不保证 1:1 匹配，替换会引入回归。
- 远程 Shell（Phase 2）：docker 阶段复用 `portable-pty` 包 `docker exec`，无新传输依赖；sprites.dev / SSH 阶段再评估 `russh` 或其官方 SDK。
- 文件 watcher（Phase 3）：`notify`。

---

## 3. 总体架构

```text
            ┌────────────────── macOS client (presentation only) ──────────────────┐
            │  Views/Finder/*  四种视图 + 终端面板 + 新增"连接/同步"面板             │
            │  ViewModels: 位置=Location{provider,path};连接状态;同步进度          │
            │  Services: Keychain 凭据读写 + ConnectionStore 配置元数据持久化        │
            └──────────────────────────────┬───────────────────────────────────────┘
                                            │ UniFFI 进程内（契约不变，逐步新增方法）
   ┌────────────────────────────────────────▼────────────────────────────────────────┐
   │                         Rust core (source of truth)                               │
   │                                                                                   │
   │  workspace.* ──► VfsProvider (trait)            terminal.* ──► TerminalTransport   │
   │     ├─ LocalFsProvider   (现有 fs.rs 抽出)          ├─ LocalPtySession (现有)      │
   │     ├─ S3Provider        (对象存储 / OpenDAL)       └─ RemoteExec (docker / sprites)│
   │     └─ SftpProvider      (远程 dev env 文件)←后续                                  │
   │                                                                                   │
   │  ConnectionRegistry (AppState)   ──  凭据引用、provider 实例、健康状态             │
   │  FileWatcher (notify) ←后续       ──  本地变更事件 → 事件通道                       │
   │  SyncEngine ←后续                 ──  在两个 provider 间扫描/diff/单向传输          │
   └───────────────────────────────────────────────────────────────────────────────────┘
                 │ 出站网络（core 内发起，不重新引入子进程/daemon）
        ┌────────┴─────────┬──────────────────┬─────────────────┐
     R2 / MinIO         sprites.dev /        （后续）          Keychain（凭据，client 侧）
     (S3 兼容)          docker exec
```

### 3.1 VfsProvider trait（Phase 0 已实现 → Phase 1 分步扩展）

```rust
// src/vfs/mod.rs — 当前实现（Phase 0）
#[async_trait]
pub trait VfsProvider: Send + Sync {
    async fn list(&self, path: &str) -> Result<ListDirectoryResponse, ApiError>;
    async fn open_directory(&self, path: &str) -> Result<(String, ListDirectoryResponse), ApiError>;
    fn capabilities(&self) -> ProviderCaps;

    // Phase 1c 加入：
    // async fn stat(&self, path: &str) -> Result<DirectoryEntry, ApiError>;

    // Phase 1g 加入：
    // async fn read(&self, path: &str) -> Result<Vec<u8>, ApiError>;

    // Phase 1h 加入：
    // async fn write(&self, path: &str, data: Vec<u8>) -> Result<(), ApiError>;
    // async fn delete(&self, path: &str) -> Result<(), ApiError>;
    // async fn create_directory(&self, path: &str) -> Result<(), ApiError>;
    // async fn rename(&self, from: &str, to: &str) -> Result<(), ApiError>;
}
```

- `Location { scheme, connection_id, path }`：`Scheme::Local` / `Scheme::S3`。
- `LocalFsProvider` 的 async 方法内部仍走 `tokio::task::spawn_blocking`；`S3Provider` 原生 async。
- `ProviderCaps` 暴露给客户端，决定哪些右键菜单/工具栏动作可用（如对象存储禁用"原子重命名"）。

---

## 4. 横切设计（决定难度的真正变量）

### 4.1 凭据管理（高风险点）

- S3 SigV4 签名**需要 access_key + secret 本体**，所以"core 拿引用"的实务落点：
  - **Keychain 是凭据持久化所有者（client 侧）**：通过 macOS Security framework 存取 `access_key_id` / `secret_access_key`。
  - **ConnectionStore 是非敏感连接配置持久化所有者（client 侧）**：JSON file at `~/Library/Application Support/TerminalFinder/connections.json`，只存 `connectionId` / `kind` / `displayName` / `endpoint` / `region` / `bucket` / `basePrefix` / `pathStyle`。
  - client 在**建连接时**把密钥经**进程内 FFI**（同地址空间，不过网络）交给 core。
  - app 启动时 core 的 `ConnectionRegistry` 永远为空；Swift 读取 `ConnectionStore` + Keychain 后逐条 `core.connectionCreate(...)` 重建活跃内存注册表。
  - core 只在 `ConnectionRegistry` 的**内存**里持有配置和凭据，用于签名；**绝不落盘、绝不进 tracing 日志、绝不进崩溃 dump 摘要**（对齐 `core/agent.md` 日志脱敏规则）。
- 已落地状态（2026-06-20）：`KeychainService.swift` / `ConnectionStore.swift` 已在 Session 1b 本地 merge；真实连接 UI 仍属于 Session 1f。
- sprites.dev 等支持短期 token 的场景，才是真正意义上的"引用/临时凭据"。
- R2 建议使用 **scoped API token**，不要用账户主密钥；attack surface 已在 README 限制章节警示。

### 4.2 对象存储 ≠ 文件系统

- 扁平 namespace：用 `/` delimiter 模拟目录；list 返回 common prefixes（伪目录）+ objects。
- 无真正 rename（= copy + delete，**非原子**，客户端须提示）；无 in-place 部分写；有网络延迟与**最终一致性**（list 后立刻 read 可能 404，需可重试）。
- 错误 taxonomy 要从纯 FS 错误扩展为 `network / auth / timeout / quota / notFound / ...`，不可塞进现有 FS 错误码；映射须经 FFI `CoreError` 同步到 client，并更新 `protocol/README.md` + Swift 绑定 + 测试。
- DTO 映射：common prefix → `isDirectory=true`（无 `modifiedAt`）；object → file（`size` / `modifiedAt` 来自 object metadata）。

### 4.3 文件同步前置：本地 watcher

- `core/agent.md` 将 file watcher 列为未实现，是 Phase 3 的前置。
- 单向 push/pull 只需**本地一侧** watcher（`notify`），远程侧靠 list diff（etag/size/mtime）。这是把同步砍成 MVP 的关键。

---

## 5. 分阶段开发计划（MVP = 对象存储）

每个阶段都遵循 `agent.md` 的"五层同步 + 测试与提交门禁"： **backend →** `core/src/ffi/` **转接与 DTO → 重新生成 Swift 绑定（**`scripts/refresh-core-ffi.sh`**）→ client DTO/调用 →** `protocol/README.md`，并配套 Rust + macOS 测试。

### Phase 0 — VFS provider 地基 ✅ 已完成

纯重构，零新功能，零行为变化。已交付：

- `src/vfs/mod.rs`：`VfsProvider` trait（`list` / `open_directory` / `capabilities`）、`Location`、`Scheme`、`ProviderCaps`
- `src/vfs/local.rs`：`LocalFsProvider`（从 `workspace/fs.rs` 搬入，逻辑不变）
- `src/vfs/registry.rs`：`ProviderRegistry`（按 `Scheme` 查找 provider 实例，Phase 0 只注册 `Local`）
- `workspace/service.rs`：改为通过 `state.providers().get(&scheme)` dispatch，不再直接调 `fs::*`
- `workspace/fs.rs`：已删除（逻辑全在 `vfs/local.rs`）
- FFI 形状零变化（Swift 绑定 MD5 刷新后一致），39 测试全绿

---

### Phase 1 — 对象存储（MinIO 开发 / R2 生产），分 8 个 Session

> **总目标**：让用户在 Finder UI 中浏览、下载、上传、删除 S3 兼容存储桶中的对象，开发用 MinIO，生产用 Cloudflare R2。
>
> **Phase 0 已有的地基**：`VfsProvider` trait（`list` / `open_directory` / `capabilities`），`ProviderRegistry`，`Location { scheme, connection_id, path }`，`Scheme::Local`。Phase 1 在此基础上扩展 `Scheme::S3`，新增 `S3Provider`、`ConnectionRegistry`，并分步扩展 `VfsProvider` trait。
>
> **破坏性 FFI 变更集中在 Session 1e**——在此之前 core 可独立开发和测试，不影响 client。

#### Phase 1 总体文件结构

```text
core/src/
├── connection/                     ← 1a 新增
│   ├── mod.rs                      ← ConnectionConfig + ConnectionId + re-exports
│   └── registry.rs                 ← ConnectionRegistry（Arc<RwLock>，AppState 持有）
├── vfs/
│   ├── mod.rs                      ← 扩展 VfsProvider trait（1c 加 stat，1g 加 read/write/delete）
│   ├── local.rs                    ← 不动
│   ├── registry.rs                 ← 扩展：按 connection_id 查找 S3Provider 实例
│   └── s3.rs                       ← 1c 新增：S3Provider 实现
├── workspace/
│   ├── dto.rs                      ← 1e 扩展：Location 相关字段
│   ├── service.rs                  ← 1e 扩展：按 location.scheme dispatch
│   └── state.rs                    ← 不动
├── state.rs                        ← 1a 新增 ConnectionRegistry 字段
├── ffi/
│   ├── mod.rs                      ← 1b 新增 connection_* 方法；1e 改 workspace 方法签名
│   ├── dto.rs                      ← 1b 新增 ConnectionDto；1e 改 workspace DTO
│   └── error.rs                    ← 1c 扩展错误码
├── error.rs                        ← 1c 扩展 ApiError 变体
└── lib.rs                          ← 1a 加 pub mod connection;
```

```text
clients/MacOS/
├── MacOS/
│   ├── Core/Generated/             ← 1e 跑 refresh-core-ffi.sh 后自动更新
│   ├── Services/
│   │   ├── KeychainService.swift   ← 1b 新增：凭据持久化
│   │   └── ConnectionStore.swift   ← 1b 新增：非敏感连接配置 JSON 持久化
│   ├── ViewModels/
│   │   └── ConnectionViewModel.swift ← 1f 新增
│   └── Views/
│       └── Finder/
│           └── Sidebar/
│               └── ConnectionSidebarSection.swift ← 1f 新增
└── Vendor/CoreFFI/                 ← 1e 跑 refresh-core-ffi.sh 后自动更新
```

---

#### Session 1a — ConnectionConfig + ConnectionRegistry（core only，无 FFI，无网络）

**目标**：定义连接模型和内存注册表。这一步只是数据结构，不发网络请求，不碰 FFI。

##### 1a.1 新增 `src/connection/mod.rs`

```rust
use std::fmt;

pub mod registry;
pub use registry::ConnectionRegistry;

/// 连接唯一标识。生成规则：UUID v4 字符串。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ConnectionId(pub String);

impl fmt::Display for ConnectionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// 连接类型。Phase 1 只有 S3。
#[derive(Debug, Clone)]
pub enum ConnectionKind {
    S3,
}

/// S3 连接配置。不含凭据——凭据由 `Credential` 单独存储。
#[derive(Debug, Clone)]
pub struct S3ConnectionConfig {
    pub display_name: String,
    pub endpoint: String,         // e.g. "https://xxx.r2.cloudflarestorage.com"
    pub region: String,           // e.g. "auto" for R2, "us-east-1" for MinIO
    pub bucket: String,
    pub base_prefix: String,      // 可选，浏览起始目录（空 = bucket 根）
    pub path_style: bool,         // MinIO = true, R2 = false
}

/// 连接配置（enum dispatch，未来可加 Sftp / Docker 等）。
#[derive(Debug, Clone)]
pub enum ConnectionConfig {
    S3(S3ConnectionConfig),
}

impl ConnectionConfig {
    pub fn display_name(&self) -> &str {
        match self {
            ConnectionConfig::S3(config) => &config.display_name,
        }
    }

    pub fn kind(&self) -> ConnectionKind {
        match self {
            ConnectionConfig::S3(_) => ConnectionKind::S3,
        }
    }
}

/// S3 凭据。仅内存持有，绝不落盘、绝不进日志。
/// client 经 FFI 传入，core 在 ConnectionRegistry 内存中存储，
/// session 结束或连接移除时销毁。
#[derive(Clone)]
pub struct S3Credential {
    pub access_key_id: String,
    pub secret_access_key: String,
}

// 安全：Debug impl 不打印凭据本体。
impl fmt::Debug for S3Credential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("S3Credential")
            .field("access_key_id", &"***")
            .field("secret_access_key", &"***")
            .finish()
    }
}

/// 凭据（enum dispatch）。
#[derive(Debug, Clone)]
pub enum Credential {
    S3(S3Credential),
}
```

##### 1a.2 新增 `src/connection/registry.rs`

```rust
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use super::{ConnectionConfig, ConnectionId, Credential};

/// 一条活跃连接的完整记录。
#[derive(Debug, Clone)]
pub struct ConnectionEntry {
    pub id: ConnectionId,
    pub config: ConnectionConfig,
    pub credential: Credential,
}

/// 连接注册表。Arc<RwLock> 包裹使得 AppState clone 后共享同一份。
#[derive(Clone)]
pub struct ConnectionRegistry {
    entries: Arc<RwLock<HashMap<ConnectionId, ConnectionEntry>>>,
}

impl ConnectionRegistry {
    pub fn new() -> Self { /* ... */ }
    pub fn create(&self, config: ConnectionConfig, credential: Credential) -> ConnectionId { /* uuid::Uuid::new_v4 */ }
    pub fn get(&self, id: &ConnectionId) -> Option<ConnectionEntry> { /* ... */ }
    pub fn list(&self) -> Vec<ConnectionEntry> { /* ... */ }
    pub fn remove(&self, id: &ConnectionId) -> bool { /* ... */ }
    pub fn is_shared_with(&self, other: &Self) -> bool { Arc::ptr_eq(&self.entries, &other.entries) }
}
```

##### 1a.3 AppState 改动

```rust
// state.rs 新增：
use crate::connection::ConnectionRegistry;

pub struct AppState {
    // ... 现有字段 ...
    connections: ConnectionRegistry,   // ← 新增
}

impl AppState {
    pub fn connections(&self) -> &ConnectionRegistry { &self.connections }
}
```

##### 1a.4 lib.rs

```rust
pub mod connection;  // ← 新增（在 pub mod error 之前，按字母序）
```

##### 1a.5 测试

| 测试 | 验证内容 |
| --- | --- |
| `connection_create_returns_unique_id` | 两次 create 返回不同 id |
| `connection_get_returns_entry_by_id` | create 后 get 回来的 config 字段一致 |
| `connection_list_returns_all_entries` | 创建多个后 list 数量正确 |
| `connection_remove_deletes_entry` | remove 后 get 返回 None |
| `connection_registry_shared_across_clones` | `is_shared_with` 通过（对齐 `TerminalRegistry` 测试模式） |
| `s3_credential_debug_does_not_leak_secret` | `format!("{:?}", cred)` 不含实际密钥 |

##### 1a.6 验收

```bash
cargo fmt --check && cargo test && cargo clippy --all-targets -- -D warnings
cargo build --no-default-features --lib
```

全绿。FFI 不动，client 不动。

---

#### Session 1b — Connection FFI 方法 + Swift Keychain / ConnectionStore 服务

**目标**：通过 FFI 暴露连接 CRUD，Swift 侧实现 Keychain 凭据读写服务，并持久化非敏感连接配置元数据。

**已落地（2026-06-20，本地 master `0097bab`）**：本 session 已完成并额外包含 `ConnectionStore`。后续 Session 1f 不再创建 `ConnectionStore`，只在 `ConnectionViewModel` 和启动 hook 中消费它。

##### 1b.1 FFI 新增方法（`ffi/mod.rs`）

```rust
#[uniffi::export]
impl CoreHandle {
    // --- 连接管理（同步方法，无网络 I/O）---

    /// 创建连接并在内存中存储凭据。返回 connection_id。
    pub fn connection_create(
        &self,
        display_name: String,
        endpoint: String,
        region: String,
        bucket: String,
        base_prefix: String,
        path_style: bool,
        access_key_id: String,
        secret_access_key: String,
    ) -> String { /* ... */ }

    /// 列出所有已注册连接（不含凭据明文）。
    pub fn connection_list(&self) -> Vec<ConnectionInfoDto> { /* ... */ }

    /// 移除连接及其内存凭据。
    pub fn connection_remove(&self, connection_id: String) -> Result<(), CoreError> { /* ... */ }
}
```

##### 1b.2 FFI 新增 DTO（`ffi/dto.rs`）

```rust
/// 连接摘要信息（不含凭据）。
#[derive(Debug, uniffi::Record)]
pub struct ConnectionInfoDto {
    pub connection_id: String,
    pub display_name: String,
    pub endpoint: String,
    pub bucket: String,
    pub base_prefix: String,
}
```

##### 1b.3 Swift 侧 — KeychainService

```swift
// MacOS/Services/KeychainService.swift
// Security framework 封装，存取 S3 access_key_id + secret_access_key
// 以 "<connection_id>::<label>" 为 Keychain item 的 account 字段
// 读取后经 FFI 传给 core（进程内，不过网络）
```

##### 1b.4 Swift 侧 — ConnectionStore

```swift
// MacOS/Services/ConnectionStore.swift
// JSON file persistence for non-sensitive connection config metadata only.
// File: ~/Library/Application Support/TerminalFinder/connections.json
// Schema:
// {
//   "version": 1,
//   "connections": [
//     {
//       "connectionId": "uuid",
//       "kind": "s3",
//       "displayName": "MinIO local",
//       "endpoint": "http://localhost:9000",
//       "region": "us-east-1",
//       "bucket": "test-bucket",
//       "basePrefix": "",
//       "pathStyle": true
//     }
//   ]
// }
```

规则：凭据字段永远不进 JSON；配置元数据也不塞进 Keychain；core 不读取该文件。

##### 1b.5 五层同步

此步新增了 FFI 方法和 DTO，必须：
1. `scripts/refresh-core-ffi.sh` 重新生成 Swift 绑定
2. 更新 `protocol/README.md` 加入 `connection.*` 方法

##### 1b.6 测试

| 层 | 测试 |
| --- | --- |
| core（`ffi/mod.rs`） | `connection_create_and_list_returns_entry` / `connection_remove_makes_get_fail` |
| Swift（`KeychainServiceTests`） | 存 → 取 → 删的 roundtrip（需 mock 或 test Keychain） |
| Swift（`ConnectionStoreTests`） | missing file / corrupt JSON / upsert replace / remove / JSON 不含凭据 / store + keychain 可重组 `connectionCreate` 参数 |

---

#### Session 1c — S3Provider core 实现 + 错误扩展（core only，mock-tested）

**目标**：实现 `S3Provider`，让它能 list 对象存储中的内容并映射为 `DirectoryEntry`。先只在 core 层用 mock 测试，不碰 FFI / client。

**已落地（2026-06-20，本地 `master` HEAD `8945efb`）**：OpenDAL 0.53 spike、`ApiError` cloud variants、`Scheme::S3`、`VfsProvider::stat`、`LocalFsProvider::stat`、`ProviderRegistry` connection-id lookup、`S3Provider` 的 `list` / `open_directory` / `stat` 与 OpenDAL error mapping 已完成。真实 MinIO 网络往返仍按计划留给 Session 1d。

##### 1c.1 依赖选择

```toml
# core/Cargo.toml — 新增
opendal = { version = "0.53", features = ["services-s3"] }
```

OpenDAL 一个 crate 同时覆盖 S3/R2/MinIO/SFTP/WebDAV，比分别引 `aws-sdk-s3` 总依赖更小。`services-s3` feature 只拉 S3 后端。

##### 1c.2 Scheme 扩展（`vfs/mod.rs`）

```rust
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Scheme {
    Local,
    S3,    // ← 新增
}
```

##### 1c.3 VfsProvider trait 扩展

```rust
#[async_trait::async_trait]
pub trait VfsProvider: Send + Sync {
    // Phase 0 已有
    async fn list(&self, path: &str) -> Result<ListDirectoryResponse, ApiError>;
    async fn open_directory(&self, path: &str)
        -> Result<(String, ListDirectoryResponse), ApiError>;
    fn capabilities(&self) -> ProviderCaps;

    // Phase 1c 新增
    async fn stat(&self, path: &str) -> Result<DirectoryEntry, ApiError>;
}
```

`stat` 是只读浏览的最小补充——用于判断路径是目录还是文件。`LocalFsProvider` 需要补充实现。

##### 1c.4 新增 `src/vfs/s3.rs`

```rust
use opendal::{Operator, services::S3};
use crate::connection::{ConnectionId, S3ConnectionConfig, S3Credential};

pub struct S3Provider {
    operator: Operator,
    connection_id: ConnectionId,
    base_prefix: String,
}

impl S3Provider {
    pub fn new(
        id: ConnectionId,
        config: &S3ConnectionConfig,
        credential: &S3Credential,
    ) -> Result<Self, ApiError> {
        let mut builder = S3::default()
            .endpoint(&config.endpoint)
            .region(&config.region)
            .bucket(&config.bucket)
            .access_key_id(&credential.access_key_id)
            .secret_access_key(&credential.secret_access_key);

        if !config.path_style {
            builder = builder.enable_virtual_host_style();
            // 注：OpenDAL 0.53 默认是 path-style
            // MinIO 需 path-style；R2 需 virtual-hosted
        }

        let operator = Operator::new(builder)?.finish();
        Ok(Self {
            operator,
            connection_id: id,
            base_prefix: config.base_prefix.clone(),
        })
    }
}

#[async_trait::async_trait]
impl VfsProvider for S3Provider {
    async fn list(&self, path: &str) -> Result<ListDirectoryResponse, ApiError> {
        // 1. 拼接 base_prefix + path → 得到完整 S3 prefix
        // 2. operator.list_with(prefix).delimiter("/") → 获取 objects + common_prefixes
        // 3. common_prefix → DirectoryEntry { is_directory: true, kind: Directory, modified_at: None }
        //    object → DirectoryEntry { is_directory: false, kind: File, size, modified_at }
        // 4. 排序规则与 local 一致：目录在前，名称 case-insensitive 升序
    }

    async fn open_directory(&self, path: &str)
        -> Result<(String, ListDirectoryResponse), ApiError>
    {
        // S3 无 canonicalize 概念——path 即为 canonical
        let listing = self.list(path).await?;
        let canonical = format!("{}{}", self.base_prefix, path);
        Ok((canonical, listing))
    }

    async fn stat(&self, path: &str) -> Result<DirectoryEntry, ApiError> {
        // operator.stat(key) → EntryMeta → DirectoryEntry
    }

    fn capabilities(&self) -> ProviderCaps {
        ProviderCaps {
            can_rename: false,          // copy + delete，非原子
            can_symlink: false,
            can_write: true,
            has_native_directories: false,  // 用 delimiter 模拟
        }
    }
}
```

##### 1c.5 错误扩展（`error.rs`）

```rust
pub enum ApiError {
    // ... 现有变体 ...

    // Phase 1c 新增：云端操作错误
    #[error("network error during {operation}: {message}")]
    NetworkError { operation: &'static str, message: String },

    #[error("authentication failed for connection {connection_id}: {message}")]
    AuthenticationFailed { connection_id: String, message: String },

    #[error("object not found: {path}")]
    ObjectNotFound { path: String },

    #[error("connection not found: {connection_id}")]
    ConnectionNotFound { connection_id: String },

    #[error("provider error during {operation}: {message}")]
    ProviderError { operation: &'static str, message: String },
}
```

每个新变体需配套 `code()` 和 `message()` 实现，并在 `ffi/error.rs` 的 `From<ApiError> for CoreError` 中覆盖。

##### 1c.6 ProviderRegistry 扩展

```rust
impl ProviderRegistry {
    // Phase 0 已有
    pub fn get(&self, scheme: &Scheme) -> Option<Arc<dyn VfsProvider>> { /* ... */ }

    // Phase 1c 新增：按 connection_id 注册/获取/移除 S3Provider
    pub fn register_connection(&mut self, connection_id: &ConnectionId, provider: Arc<dyn VfsProvider>) { /* ... */ }
    pub fn get_by_connection(&self, connection_id: &ConnectionId) -> Option<Arc<dyn VfsProvider>> { /* ... */ }
    pub fn remove_connection(&self, connection_id: &ConnectionId) { /* ... */ }
}
```

**设计决策**：`ProviderRegistry` 的查找方式从纯 `Scheme` 查找扩展为 `Scheme` + `connection_id` 双键查找。Local provider 仍走 `get(&Scheme::Local)` 原有路径；S3 provider 走 `get_by_connection(id)` 因为同一 Scheme 下可以有多个连接。

##### 1c.7 DTO 映射规则（对象存储 → DirectoryEntry）

| S3 概念 | DirectoryEntry 字段 |
| --- | --- |
| common prefix（`/` 分隔的伪目录） | `name` = 最后一段, `kind` = Directory, `is_directory` = true, `size` = None, `modified_at` = None |
| object | `name` = key 最后一段, `kind` = File, `is_directory` = false, `size` = content_length, `modified_at` = last_modified ISO |
| bucket 根 | list path = "" 或 "/"，显示为 base_prefix 下的内容 |

##### 1c.8 测试

| 测试 | 验证内容 |
| --- | --- |
| `s3_list_maps_prefixes_to_directories` | 给定 mock list 结果（含 common_prefix + object），输出的 DirectoryEntry 正确 |
| `s3_list_sorts_directories_first` | 排序与 local 一致 |
| `s3_open_directory_returns_canonical_path` | canonical_path = base_prefix + path |
| `s3_capabilities_declare_no_rename_no_symlink` | capabilities 正确 |
| `error_codes_cover_new_variants` | 新 ApiError 变体全部有 code() 和 message() |
| `ffi_core_error_maps_all_api_errors` | 所有 ApiError 变体可 Into<CoreError> |

##### 1c.9 验收

```bash
cargo fmt --check && cargo test && cargo clippy --all-targets -- -D warnings
cargo build --no-default-features --lib
```

全绿。此步不碰 FFI 外部形状、不碰 client。

---

#### Session 1d — MinIO 开发环境 + Integration Test

**目标**：用 docker-compose 起 MinIO，跑 S3Provider 真实网络测试。

**已落地（2026-06-20，本地 `master`）**：新增 `dev/docker-compose.minio.yml`、`dev/init-minio.sh`、`dev/fixtures/`，并在 `core` 增加 `integration-test` feature gate 与 5 个真实 MinIO 网络集成测试。验证结果：`cargo test` 63 passed；`cargo test --features integration-test` 68 passed（含 5 个 MinIO 测试）；`cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`、`cargo build --no-default-features --lib` 均通过。

##### 1d.1 docker-compose 文件

```yaml
# dev/docker-compose.minio.yml
services:
  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"    # S3 API
      - "9001:9001"    # Console
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes:
      - minio-data:/data

volumes:
  minio-data:
```

##### 1d.2 初始化脚本

```bash
# dev/init-minio.sh
# 用官方 minio/mc 镜像创建 bucket 并复制 fixtures。
# macOS Docker Desktop 下通过 host.docker.internal 回连宿主机 localhost:9000。
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -e MC_HOST_local=http://minioadmin:minioadmin@host.docker.internal:9000 \
  minio/mc:latest mb --ignore-existing local/test-bucket

docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -v "$(pwd)/dev/fixtures:/fixtures:ro" \
  -e MC_HOST_local=http://minioadmin:minioadmin@host.docker.internal:9000 \
  minio/mc:latest cp --recursive /fixtures/ local/test-bucket/
```

##### 1d.3 Feature-gated integration test

```toml
# core/Cargo.toml
[features]
integration-test = []  # 不带新依赖，只开门
```

```rust
// src/vfs/s3.rs 底部
#[cfg(all(test, feature = "integration-test"))]
mod integration_tests {
    // 需要本地 MinIO 在 localhost:9000 运行
    // 测试覆盖：
    // - list bucket 根目录
    // - list 嵌套 prefix
    // - stat 已知 object
    // - stat 不存在的 key → ObjectNotFound
    // - 错误凭据 → AuthenticationFailed
}
```

##### 1d.4 运行方式

```bash
# 启动 MinIO
docker compose -f dev/docker-compose.minio.yml up -d
bash dev/init-minio.sh

# 跑 integration test
cd core && cargo test --features integration-test
```

##### 1d.5 验收

integration test 全绿（CI 中设为 optional / allow-fail，不阻塞主线）。

---

#### Session 1e — FFI 破坏性升级：Location-aware workspace 方法

**目标**：让 `open_directory` 和 `list_directory` 支持按 connection_id 浏览 S3。**这是整个 Phase 1 唯一的破坏性 FFI 变更，集中在此 session 一次性完成五层同步。**

##### 1e.1 workspace DTO 变更（`workspace/dto.rs`）

```rust
// 新增请求参数
#[derive(Debug, Deserialize)]
pub struct OpenDirectoryParams {
    pub path: PathBuf,                   // 保留（local 继续用）
    pub connection_id: Option<String>,   // ← 新增：None = local
}

#[derive(Debug, Deserialize)]
pub struct ListDirectoryParams {
    pub path: PathBuf,                   // 对 S3 来说是 prefix
    pub connection_id: Option<String>,   // ← 新增
}

// WorkspaceStateResponse 扩展
#[derive(Debug, Serialize)]
pub struct WorkspaceStateResponse {
    pub workspace_root: String,
    pub current_directory: String,
    pub connection_id: Option<String>,   // ← 新增：当前浏览的连接
    pub scheme: String,                  // ← 新增："local" 或 "s3"
}
```

##### 1e.2 FFI DTO 变更（`ffi/dto.rs`）

```rust
#[derive(Debug, uniffi::Record)]
pub struct WorkspaceStateDto {
    pub workspace_root: String,
    pub current_directory: String,
    pub connection_id: Option<String>,   // ← 新增
    pub scheme: String,                  // ← 新增
}
```

FFI 方法签名变更：

```rust
#[uniffi::export(async_runtime = "tokio")]
impl CoreHandle {
    pub async fn open_directory(
        &self,
        path: String,
        connection_id: Option<String>,  // ← 新增参数
    ) -> Result<OpenDirectoryDto, CoreError> { /* ... */ }

    pub async fn list_directory(
        &self,
        path: String,
        connection_id: Option<String>,  // ← 新增参数
    ) -> Result<DirectoryListingDto, CoreError> { /* ... */ }
}
```

##### 1e.3 workspace/service.rs dispatch 改造

```rust
pub async fn open_directory(
    state: &AppState,
    params: OpenDirectoryParams,
) -> Result<OpenDirectoryResponse, ApiError> {
    let (location, provider) = resolve_provider(state, params.connection_id.as_deref(), &params.path)?;

    let (canonical_path, listing) = provider.open_directory(&location.path).await?;

    match location.scheme {
        Scheme::Local => {
            // 现有逻辑：workspace_root_for_directory + set_directory_state
        }
        Scheme::S3 => {
            // S3 的 "root" 是 connection 的 base_prefix
            // current_directory 是当前浏览的 prefix
        }
    }

    // ... 构造 response（含 scheme + connection_id）
}

/// 根据 connection_id 解析 Location 和 Provider。
/// connection_id = None → local；Some(id) → 从 ConnectionRegistry 查找。
fn resolve_provider(
    state: &AppState,
    connection_id: Option<&str>,
    path: &Path,
) -> Result<(Location, Arc<dyn VfsProvider>), ApiError> {
    match connection_id {
        None => {
            let location = Location::local(path.to_string_lossy());
            let provider = state.providers().get(&Scheme::Local)
                .expect("local provider always registered");
            Ok((location, provider))
        }
        Some(id) => {
            let conn_id = ConnectionId(id.to_string());
            let provider = state.providers().get_by_connection(&conn_id)
                .ok_or_else(|| ApiError::ConnectionNotFound { connection_id: id.to_string() })?;
            let location = Location {
                scheme: Scheme::S3,
                connection_id: Some(id.to_string()),
                path: path.to_string_lossy().into_owned(),
            };
            Ok((location, provider))
        }
    }
}
```

##### 1e.4 五层同步检查清单

| 层 | 改动 |
| --- | --- |
| 1. core 业务逻辑 | `workspace/service.rs` dispatch + `workspace/dto.rs` 字段 |
| 2. `ffi/` 转接与 DTO | `ffi/mod.rs` 方法签名 + `ffi/dto.rs` Record 字段 + `From` 实现 |
| 3. Swift 绑定重生成 | `scripts/refresh-core-ffi.sh` |
| 4. client DTO/调用 | Swift ViewModel 调用处加 `connectionId: nil`（保持本地行为不变） |
| 5. `protocol/README.md` | `workspace.openDirectory` / `workspace.listDirectory` 参数更新 |

##### 1e.5 向后兼容策略

Swift 侧现有的 `openDirectory(path:)` 调用全部改为 `openDirectory(path:, connectionId: nil)`。`nil` = 本地浏览，行为完全不变。**这是 client 唯一需要改的地方**——一次性机械替换，不影响逻辑。

##### 1e.6 测试

| 测试 | 验证内容 |
| --- | --- |
| `open_directory_nil_connection_behaves_as_local` | connection_id = nil 时行为与 Phase 0 逐字节一致 |
| `open_directory_with_connection_id_dispatches_to_s3` | connection_id = 有效 id 时走 S3Provider |
| `open_directory_with_invalid_connection_id_returns_error` | 无效 id → ConnectionNotFound |
| `workspace_state_includes_scheme_and_connection_id` | response 含正确 scheme + connection_id |
| Swift: `WorkspaceBrowserViewModelTests` | 全部改用 `connectionId: nil`，全绿 |

##### 1e.7 验收

```bash
# Rust
cargo fmt --check && cargo test && cargo clippy --all-targets -- -D warnings

# FFI 重生成
bash clients/MacOS/scripts/refresh-core-ffi.sh

# Swift
xcodebuild test ...
```

全绿。**这是 Phase 1 中测试成本最高的 session**，但之后的 session 1f–1h 都是增量扩展，不再有破坏性 FFI 变更。

---

#### Session 1f — Client 连接管理 UI

**目标**：Swift 侧 sidebar 新增"连接"分组，用户可新增 / 查看 / 删除 S3 连接。

`ConnectionStore` 和 `KeychainService` 已在 Session 1b 落地；1f 只负责 ViewModel、启动恢复 hook 和 UI，不再重复实现持久化服务。

##### 1f.1 ConnectionViewModel

```swift
// 管理连接列表状态
// - loadConnections() → ConnectionStore.load() + core.connectionList()
// - restorePersistedConnections() → ConnectionStore.load() + KeychainService.load() + core.connectionCreate()
// - createConnection(form) → core.connectionCreate() + KeychainService.save() + ConnectionStore.upsert()
// - removeConnection(id) → core.connectionRemove() + KeychainService.delete() + ConnectionStore.remove()
```

##### 1f.2 UI 组件

- **ConnectionSidebarSection**：在 sidebar 已有的文件系统导航下方显示"连接"分组
- **NewConnectionSheet**：表单（名称 / endpoint / region / bucket / base_prefix / path_style / access_key / secret_key）
- **ConnectionRow**：每个连接的 sidebar 行，点击后 `open_directory(path: "", connectionId: id)`

##### 1f.3 测试

- `ConnectionViewModelTests`：mock CoreHandle，验证 create/list/remove 流程
- 手动验证：新建连接 → 连接出现在 sidebar → 删除连接 → 连接消失

---

#### Session 1g — 下载与预览

**目标**：用户点击 S3 对象可下载到本地缓存目录并预览。

##### 1g.1 VfsProvider trait 扩展

```rust
#[async_trait::async_trait]
pub trait VfsProvider: Send + Sync {
    // ... 已有方法 ...

    /// 读取文件内容。返回字节数据。
    /// 大文件后续优化为 streaming；Phase 1g 先全量读取（配合 size 上限保护）。
    async fn read(&self, path: &str) -> Result<Vec<u8>, ApiError>;
}
```

`LocalFsProvider` 补充实现（`spawn_blocking` + `fs::read`），`S3Provider` 实现（`operator.read`）。

##### 1g.2 FFI 新增方法

```rust
#[uniffi::export(async_runtime = "tokio")]
impl CoreHandle {
    /// 下载文件到指定本地路径。
    pub async fn download_file(
        &self,
        connection_id: Option<String>,
        remote_path: String,
        local_destination: String,
    ) -> Result<(), CoreError> { /* ... */ }
}
```

##### 1g.3 Client 侧

- 右键菜单 / 双击 → 下载到 `~/Library/Caches/com.terminal-finder/downloads/`
- 下载完成后调 `NSWorkspace.shared.open(url)` 打开
- 预览面板（QuickLook）：先下载到缓存再触发

##### 1g.4 大文件保护

Phase 1g 的 `read` 先设一个 **50MB 上限**——超过此大小的文件拒绝全量下载，提示用户使用外部工具。Phase 1h 优化为 streaming + range read 后解除限制。

##### 1g.5 测试

| 测试 | 验证内容 |
| --- | --- |
| `local_provider_read_returns_file_bytes` | 本地文件可读 |
| `s3_provider_read_returns_object_bytes`（integration） | MinIO 对象可读 |
| `download_file_writes_to_local_path` | FFI download_file 正确写文件 |
| `read_rejects_oversized_file` | 超过 50MB 返回错误 |

---

#### Session 1h — 写操作 + 进度事件 + 体验收尾

**目标**：上传、删除、创建目录（zero-byte marker）、rename（copy+delete）、进度事件、能力降级 UI。

##### 1h.1 VfsProvider trait 最终形态

```rust
#[async_trait::async_trait]
pub trait VfsProvider: Send + Sync {
    async fn list(&self, path: &str) -> Result<ListDirectoryResponse, ApiError>;
    async fn open_directory(&self, path: &str) -> Result<(String, ListDirectoryResponse), ApiError>;
    async fn stat(&self, path: &str) -> Result<DirectoryEntry, ApiError>;
    async fn read(&self, path: &str) -> Result<Vec<u8>, ApiError>;
    fn capabilities(&self) -> ProviderCaps;

    // Phase 1h 新增
    async fn write(&self, path: &str, data: Vec<u8>) -> Result<(), ApiError>;
    async fn delete(&self, path: &str) -> Result<(), ApiError>;
    async fn create_directory(&self, path: &str) -> Result<(), ApiError>;
    async fn rename(&self, from: &str, to: &str) -> Result<(), ApiError>;
}
```

##### 1h.2 S3Provider 写操作实现

| 方法 | S3 语义 |
| --- | --- |
| `write` | `operator.write(key, data)`；大文件（>5MB）自动走 multipart |
| `delete` | `operator.delete(key)` |
| `create_directory` | `operator.write(prefix + "/", b"")` — zero-byte marker |
| `rename` | `operator.copy(from, to)` + `operator.delete(from)` — **非原子** |

##### 1h.3 FFI 新增方法

```rust
impl CoreHandle {
    pub async fn upload_file(&self, connection_id: Option<String>, remote_path: String, local_source: String) -> Result<(), CoreError> { /* ... */ }
    pub async fn delete_entry(&self, connection_id: Option<String>, path: String) -> Result<(), CoreError> { /* ... */ }
    pub async fn create_remote_directory(&self, connection_id: Option<String>, path: String) -> Result<(), CoreError> { /* ... */ }
    pub async fn rename_entry(&self, connection_id: Option<String>, from: String, to: String) -> Result<(), CoreError> { /* ... */ }
}
```

##### 1h.4 进度事件

通过现有的 `events: broadcast::Sender<String>` 发送 JSON 事件：

```json
{ "type": "transfer_progress", "connection_id": "...", "path": "...", "bytes_transferred": 1024000, "total_bytes": 5242880 }
```

Client 侧监听事件通道，在 UI 上显示进度条。

##### 1h.5 能力降级 UI

Client 根据 `capabilities()` 决定 UI 行为：

| `ProviderCaps` 字段 | false 时的 UI 表现 |
| --- | --- |
| `can_rename` | 右键菜单 "重命名" 灰显，或显示警告 "S3 重命名非原子，可能失败" |
| `can_symlink` | 隐藏 "创建替身" 选项 |
| `has_native_directories` | 新建文件夹时提示 "将创建空标记对象" |

##### 1h.6 FFI ProviderCaps 暴露

```rust
#[derive(Debug, uniffi::Record)]
pub struct ProviderCapsDto {
    pub can_rename: bool,
    pub can_symlink: bool,
    pub can_write: bool,
    pub has_native_directories: bool,
}
```

在 `connection_list` 返回的 `ConnectionInfoDto` 中加 `caps` 字段，或新增 `connection_capabilities(id)` FFI 方法。

##### 1h.7 测试

| 测试 | 验证内容 |
| --- | --- |
| `s3_write_then_read_roundtrip`（integration） | 写入后读回一致 |
| `s3_delete_removes_object`（integration） | 删除后 stat → ObjectNotFound |
| `s3_create_directory_writes_zero_byte_marker`（integration） | list 可见伪目录 |
| `s3_rename_is_copy_plus_delete`（integration） | rename 后 from 不存在、to 存在 |
| `upload_file_ffi_sends_progress_events` | 上传过程中事件通道收到 transfer_progress |
| `capabilities_gate_disables_rename_for_s3` | S3 caps.can_rename == false |

##### 1h.8 Phase 1 终验收

```bash
# Rust 全量
cd core && cargo fmt --check && cargo test && cargo clippy --all-targets -- -D warnings
cargo build --no-default-features --lib
cargo test --features integration-test  # 需 MinIO 运行

# FFI + Swift
bash clients/MacOS/scripts/refresh-core-ffi.sh
xcodebuild test ...

# 手动验证
# 1. 新建 MinIO 连接 → sidebar 出现
# 2. 点击连接 → 看到 bucket 内容（目录 + 文件）
# 3. 点入子目录 → 回退 → 正确
# 4. 双击文件 → 下载并预览
# 5. 上传本地文件 → 在 MinIO console 验证
# 6. 右键删除 → 文件消失
# 7. 切回本地浏览 → 行为不变（回归）
```

---

#### Phase 1 Session 间依赖关系

```text
1a ──► 1b ──► 1c ──► 1d（可并行于 1c 后）
                  │
                  └──► 1e ──► 1f ──► 1g ──► 1h
```

- 1a → 1b：FFI 需要 ConnectionRegistry
- 1b → 1c：S3Provider 需要从 ConnectionRegistry 获取凭据
- 1c → 1d：integration test 需要 S3Provider 实现
- 1c → 1e：FFI 升级需要 S3Provider 就绪
- 1e → 1f：Client UI 需要新 FFI 签名
- 1f → 1g：下载需要连接可选中
- 1g → 1h：写操作建立在读操作基础上

每个 session 独立可提交，回滚只影响该 session 的变更。

### Phase 2 — 远程 Shell（后续，先不实现）

- `TerminalTransport` 抽象（`src/terminal/` 内）。
- **docker 阶段**：本地 PTY 包 `docker exec -it <container> <shell>`，几乎无新依赖，最快验证。
- **sprites.dev 阶段**：走其 API / websocket transport，复用现有终端面板（`FinderTerminalView` / SwiftTerm）与 `terminal.*` 契约。

### Phase 3 — 单向文件同步（后续，先不实现）

- 本地 `notify` watcher → 事件通道（先补齐 `core/agent.md` 列为未实现的 file watcher）。
- SyncEngine：按 path + size + mtime/etag 做 diff，单向（push / pull 二选一）传输；`.gitignore` 风格忽略规则；进度事件。

---

## 6. 开发 / 测试环境

- **MinIO**：`docker-compose` 起本地 MinIO（预置 bucket + scoped key）作为 S3 兼容开发后端。
- **cloud integration 测试 feature-gated**：本地 / CI 可选跑，不让 CI 强依赖网络；单测用 mock provider 覆盖逻辑。
- **docker terminal（Phase 2）**：本地起一个长驻 container 作为 `docker exec` 目标。
- 命令基线（沿用 agent.md）：
  - core：`cd core && cargo fmt --check && cargo test && cargo clippy --all-targets -- -D warnings`
  - 库独立编译：`cargo build --no-default-features --lib`
  - 改 FFI 后：`clients/MacOS/scripts/refresh-core-ffi.sh`
  - client：`xcodebuild test -project clients/MacOS/MacOS.xcodeproj -scheme MacOS -configuration Debug -destination 'platform=macOS' -derivedDataPath .derivedData/codex-tests CODE_SIGNING_ALLOWED=NO`

---

## 7. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| 大文件全量入内存导致 core OOM | `read`/`write` 强制 streaming + range / multipart |
| 对象存储最终一致性（list 后 read 404） | 可重试 + 明确错误码，client 友好提示 |
| 凭据泄漏（日志 / dump） | 内存持有、绝不落盘 / 不进 tracing；R2 用 scoped token |
| attack surface 扩大（README 已警示） | 凭据最小权限、连接级隔离、错误信息脱敏 |
| 本地 FS 回归（Phase 0 重构） | ✅ 已完成：`vfs/local.rs` 保留全部原生 FS 语义，39 测试全绿 |
| FFI 形状破坏 client（Phase 1e） | 连接 CRUD 的新增 FFI 已在 1b 落地；workspace location-aware 破坏性签名集中在 1e，一次性五层同步并配套 client DTO / ViewModel 测试 |

---

## 8. 边界守则（务必遵守，摘自三份 AGENT.md）

- 云端 provider、sync、错误分类等产品事实进 **core**，不进 client；client 只渲染、选择、Keychain 凭据持久化、ConnectionStore 配置元数据持久化，以及平台系统集成。
- 不重新引入子进程 / daemon / `127.0.0.1:3587` 轮询；云端连接是 core 进程内发起的出站网络。
- 阻塞 FS 走 `spawn_blocking`；网络 IO 原生 async。
- 协议方法语义是 FFI 与可选 HTTP **共同契约**；任一处改动五层同步。
- 任何生产代码改动必须配套自动化测试，覆盖失败 / 边界 / 跨层契约，不只 happy path。
- 不提前创建 `core/crates/*` 多 crate；保持单 crate 轻量模块，直到表面积确实变大。
- 本设计文档与其他 `*.md` 开发文档不纳入 git。

---

## 9. 下一步

Phase 0 地基已完成，Phase 1 的 Session 1a / 1b / 1c / 1d 已本地 merge。建议继续按 **Session 1e → 1f → 1g → 1h** 顺序推进。每个 Session 完成后按 §6 跑验证并交付变更清单。

**下一步启动 Session 1e**（FFI location-aware firewall）。在 `workspace.openDirectory` / `workspace.listDirectory` 引入可选 `connection_id`，同步 core service、FFI DTO、Swift bindings、client 调用点、协议文档和测试。
