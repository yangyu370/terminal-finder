# Core Backend 审查结论与实施计划

> 审查范围：`core/` Rust backend 全部源码（`api/`、`terminal/`、`workspace/`、`error.rs`、`state.rs`、`main.rs`）
> 审查日期：2026-06-07
> 状态：终端 WebSocket 安全为最高优先级，需在对外分发前阻断

## 总体评价

backend 分层清晰（routes → RPC dispatch → controllers → service → fs / terminal），阻塞 IO 用
`spawn_blocking` 或独立线程隔离，状态集中在 `AppState`，错误和响应结构统一。

新增的 `/terminal` WebSocket 引入了一个完整的交互式 shell 端点，把后端的攻击面从"只读文件
浏览"扩大到"任意命令执行"。本轮审查的核心结论：**终端端点当前无任何鉴权与来源校验，构成可被
任意网页触发的本地 RCE，必须优先修复。** 其余为 workspace 历史遗留项与终端健壮性项。

## 🔴 终端 WebSocket 安全（最高优先级，对外分发前必须阻断）

### T1 无鉴权 + 无 Origin 校验 → CSWSH / 本地 RCE

位置：`api/terminal.rs:70-82`、`main.rs:32`

`/terminal` 直接 `upgrade.on_upgrade(...)` 开启完整 shell，握手阶段不校验 `Origin`、不校验任何
token 或子协议。绑定 `127.0.0.1` **挡不住浏览器攻击**：WebSocket 不受同源策略 / CORS 限制，
任意恶意网页的 JS 都能 `new WebSocket("ws://127.0.0.1:3587/terminal")` 连入、发 `terminal.create`
拿到 shell 并执行任意命令（Cross-Site WebSocket Hijacking）。

这是把本地工具变成"任意网站可在受害者机器执行任意代码"的洞，是当前最严重问题。

实施规则：

- 握手时校验 `Origin` 头，仅允许已知客户端来源（白名单）；缺失或不匹配直接拒绝升级。
- 进程启动时生成随机 session token，由本地客户端持有，握手时通过子协议或 query 校验。
- `/rpc`、`/events` 同样缺乏鉴权（见 #7），应统一在一层中间件解决，避免逐端点重复。

### T2 input / resize / close 不校验会话归属（跨连接越权）

位置：`api/terminal.rs:303,355,389`

`owned_sessions` 仅用于断开时清理（`terminal.rs:177`），但 `terminal.input` / `terminal.resize`
/ `terminal.close` 全程只按 `session_id` 在**全局** registry 查找，不校验该会话是否由当前连接创建。
任意连接只要持有 UUID 即可向他人会话注入输入、改尺寸或关闭它。UUID v4 不可猜可缓解，但叠加 T1
后构成真实越权面。

实施规则：input / resize / close 执行前先校验 `owned_sessions.contains(&session_id)`，否则返回
`unknown_session`，不得触达全局 registry。

## 🟠 终端健壮性（资源与可用性）

### T3 单连接可无限创建会话 → 进程/线程耗尽

位置：`api/terminal.rs:216`、`terminal/session.rs:95-96`

`terminal.create` 无任何数量上限。每次 create 会 spawn 一个子进程加两个 OS 线程（reader +
control）。失控或恶意客户端循环 create 即可打满机器线程/进程数。

实施规则：对每连接与全局活跃会话数设上限（如每连接 16、全局可配置），超限返回明确错误 code，
不静默丢弃。

### T4 cols / rows 无下限校验，可传 0

位置：`api/terminal.rs:36-53`

`CreateData` / `ResizeData` 直接接收 `u16`，客户端可传 `cols:0, rows:0`，以 0 尺寸开 PTY，
导致 TUI 程序行为异常甚至卡死。

实施规则：create 与 resize 均将 cols/rows 钳制到合理区间（如 1..=1000），越界归一化或拒绝。

### T5 退出信号永远丢失

位置：`terminal/session.rs:242-248`

`send_exit` 将 `signal` 硬编码为 `None`，被信号杀死的子进程（Ctrl-C / kill）前端无法与正常退出
区分。portable_pty 的 `ExitStatus` 信息有限，至少应在能区分时填充 signal，或显式注释该限制并在
协议中说明。

## 🔴 全局鉴权（原 #7，终端落地后提级为必须）

位置：`api/routes.rs`、`main.rs`

`/rpc`、`/events`、`/terminal` 均无认证与 Host/Origin 校验。在仅有只读文件浏览时风险有限，但
`/terminal` 落地后任意本地进程或网页都可借此执行命令，已不可继续延期。应在 router 层加统一鉴权
中间件（Host/Origin 校验 + 启动期随机 token），三个端点共用，而非逐端点实现（与 T1 协同）。

## 🟡 Workspace 历史遗留项（保留，未解决）

### #1 目录扫描竞争未容错

位置：`workspace/fs.rs:43-49`

`read_dir` 结果仍通过 `collect::<Result<Vec<_>, _>>()?` 收集，任何条目处理错误都会使整个 listing
失败。扫描与条目 metadata 读取之间存在正常竞争：条目可能恰好被删除并返回 `NotFound`，不应拖垮
整个 listing。

实施规则：

- 用显式扫描循环替代 `collect::<Result<...>>()`。
- 来源为 `io::ErrorKind::NotFound` 的 `FileSystemRead` 视为扫描竞争，debug 记录后跳过。
- `PermissionDenied` 及其他错误继续使整个 listing 失败，不把不完整结果伪装成完整成功。
- 悬空 symlink 继续作为 symlink 条目返回。

### #3 RwLock 中毒恢复未实现

位置：`workspace/state.rs:35,47`

`state()` 与 `set_directory_state()` 仍用 `.expect("...lock is not poisoned")`。root/current 的原子
更新已落地，但中毒恢复未做：一旦锁中毒，后续 workspace 请求会持续 panic。

实施规则：读/写锁中毒时记录 warning，并通过 `poisoned.into_inner()` 获取锁内状态继续服务；保留
触发中毒的诊断信号。

### #6 info 日志暴露完整路径与参数

位置：`api/rpc.rs:47`、`workspace/service.rs:27,52`

`rpc.rs` 仍在 info 级打印 `params=%params`，`service.rs` 仍在 info 级打印完整请求路径。应将完整
`params`、目标路径和详细错误 message 降到 debug；info/warn 仅保留 method、status、elapsed、错误
code 和非敏感数量摘要。

## 延期项（已审查，本轮不改）

- **#4 RPC 序列化 `.expect()`**：响应 DTO 由普通可序列化字段组成，`.expect()` 作为不变量断言。
- **#5 `ApiError::message()` 与 Display 重复**：低风险清理，待对外 message 策略确定后处理。
- **超大目录分页或上限**：暂不分页、不静默截断，后续按真实性能数据设计协议。
- **`open_directory_blocking` 的 TOCTOU 窗口**：当前影响有限。

## 实施顺序

1. **T1 + 全局鉴权**：router 层统一鉴权中间件（Origin/Host 白名单 + 启动期随机 token）。
2. **T2**：input/resize/close 加 `owned_sessions` 归属校验。
3. **T3 / T4**：会话数上限、cols/rows 钳制。
4. **#1 / #3 / #6**：扫描竞争容错、锁中毒恢复、日志降级。
5. **T5**：退出 signal 处理或显式注释。
6. 补充测试并执行完整验证。

## 验收标准

- 未通过 Origin/token 校验的 `/terminal`、`/rpc`、`/events` 升级或请求被拒绝。
- 非本连接创建的 session 无法被 input/resize/close 触达。
- 单连接与全局会话数受上限保护，超限返回明确错误 code。
- cols/rows 被钳制到合理区间。
- 扫描竞争不会因单个 `NotFound` 拖垮 listing，其他错误不被静默忽略。
- 锁中毒后 workspace 仍可服务；info/warn 不暴露完整路径或 params。
- 执行以下命令均通过：

```sh
cd core
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```
