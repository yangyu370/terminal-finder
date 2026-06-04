# Core Backend 审查结论与实施计划

> 审查范围：`core/` Rust backend 全部源码（`api/`、`workspace/`、`error.rs`、`state.rs`、`main.rs`）
> 审查日期：2026-06-04
> 状态：已完成结论校准，可直接按本文实施

## 总体评价

当前 backend 分层清晰（routes → RPC dispatch → controllers → service → fs），阻塞文件系统
操作使用 `spawn_blocking` 隔离，状态集中在 `WorkspaceStore`，错误和响应结构也保持统一。

本轮不调整整体架构，重点修正目录扫描竞争、明确 `workspaceRoot` 语义、增强状态锁恢复能力，
并降低 info 日志中的路径暴露。RPC 请求和响应结构保持不变。

## 已确认决策

| 编号 | 结论 | 本轮动作 |
| --- | --- | --- |
| #1 | 目录扫描应容忍条目在扫描期间消失，但不能静默忽略其他错误 | 仅跳过 `NotFound`，其他错误继续失败 |
| #2 | `workspaceRoot` 是 workspace 上下文根，不是文件系统访问沙箱 | root 内导航保留 root，root 外导航切换 root |
| #3 | `RwLock` 中毒恢复属于防御性改进 | warning 后使用锁内状态继续服务 |
| #6 | info 日志不应记录完整请求参数或路径 | 完整路径和 params 降到 debug |
| #4 / #5 / #7 | 当前不是本轮必要修改 | 明确延期 |

## #1 目录扫描竞争处理

位置：`workspace/fs.rs`

当前 `read_dir` 结果通过 `collect::<Result<Vec<_>, _>>()` 收集，任何条目处理错误都会使整个
listing 失败。目录扫描与条目 metadata 读取之间存在正常竞争：条目可能恰好被删除，此时返回
`NotFound` 不应拖垮整个 listing。

实施规则：

- 使用显式扫描循环替代当前 `collect::<Result<...>>()`。
- `directory_entry` 返回的 `ApiError::FileSystemRead` 若来源为 `io::ErrorKind::NotFound`，
  视为扫描竞争，使用 debug 日志记录后跳过。
- `PermissionDenied` 及其他错误继续使整个 listing 失败，避免把不完整结果伪装为完整成功。
- 不新增 `partial`、`warnings` 或其他协议字段。
- 悬空 symlink 应继续作为 symlink 条目返回；`symlink_metadata` 可以读取链接本身，
  不能将悬空 symlink 视为应跳过的错误。

## #2 workspaceRoot 语义与切换规则

位置：`workspace/state.rs`、`workspace/fs.rs`、`workspace/service.rs`

`workspaceRoot` 表示当前 workspace 的稳定上下文根，但不是安全边界。Phase 1 继续允许客户端
通过 `openDirectory` 和 `listDirectory` 访问进程权限范围内的任意可访问目录。

`workspace.openDirectory` 的确定行为：

- 先在 blocking 文件系统区域规范化目标目录和当前 `workspaceRoot`。
- 目标目录位于当前 root 内时，仅更新 `currentDirectory`，保留规范化后的 root。
- 目标目录位于当前 root 外时，将规范化后的目标目录同时设为新的 `workspaceRoot` 和
  `currentDirectory`。
- 当前 root 已无法规范化时，将成功打开的目标目录设为新的 root/current。
- 通过 symlink 打开目录时，以规范化后的真实目标判断是否位于 root 内。
- 目录验证和 listing 全部成功后，才在同一次写锁中更新 root/current；失败不得部分更新状态。

`workspace.listDirectory` 保持无状态：

- 可列举任意可访问目录，包括当前 root 外目录。
- 不修改 `workspaceRoot` 或 `currentDirectory`。

该语义需要同步写入 `core/agent.md` 和 `protocol/README.md`。`workspaceRoot` 不提供访问控制；
正式分发前的安全边界应通过独立的 Host/Origin 校验、认证或授权设计解决。

## #3 RwLock 中毒恢复

位置：`workspace/state.rs`

当前通过 `.expect("workspace state lock is not poisoned")` 获取读写锁。虽然持锁代码很短，
现实中毒风险较低，但一旦发生会令后续 workspace 请求持续 panic。

实施规则：

- 继续使用标准库 `RwLock`，不引入 `parking_lot`。
- 读锁或写锁中毒时记录 warning，并通过 `poisoned.into_inner()` 获取锁内状态继续服务。
- root/current 更新必须由单个状态更新方法在同一次写锁中完成，防止状态部分更新。
- 中毒恢复属于可用性策略，不代表忽略触发中毒的原始 panic；日志需保留诊断信号。

## #6 日志路径与参数

位置：`api/rpc.rs`、`workspace/service.rs`

info/warn 日志用于请求级诊断，不记录完整请求参数、完整路径或详细错误 message：

- info 保留 method、status、elapsed time、成功/失败结果和非敏感数量摘要。
- warn 保留 method、status、elapsed time 和错误 code。
- 完整 `params`、目标路径和详细错误 message 仅在 debug 级别记录。
- API 返回给客户端的路径和错误 message 不受本日志策略影响。

## 本轮延期项

以下项目已审查，但本轮不修改：

- **#4 RPC 序列化 `.expect()`**：当前响应 DTO 由普通可序列化字段组成，`.expect()` 用作
  不变量断言；暂不新增内部序列化错误类型。
- **#5 `ApiError::message()` 与 Display 重复**：属于低风险清理，后续可在确定对外 message
  与内部 Display 的绑定策略后处理。
- **#7 Host/Origin 校验与认证**：Phase 1 内部开发阶段延期；正式分发前必须单独评估并实现。
- **超大目录分页或上限**：当前不增加分页、不静默截断结果，后续根据真实性能数据设计协议。
- **`open_directory_blocking` 的 TOCTOU 窗口**：当前影响有限，暂不处理。

## 实施顺序

1. 调整 `WorkspaceStore`，支持原子更新 root/current 和锁中毒恢复。
2. 调整 `openDirectory` 的规范化、root 判断和成功后状态更新流程。
3. 调整目录扫描，仅忽略条目竞争产生的 `NotFound`。
4. 调整 RPC 与 workspace 日志级别和摘要。
5. 同步 `core/agent.md` 与 `protocol/README.md` 中的 workspaceRoot 语义。
6. 补充测试并执行完整验证。

## 测试场景

workspace 状态与导航：

- 打开当前 root 内的子目录时保留 root，只更新 current。
- 打开当前 root 外目录或 root 的祖先目录时，将目标设为新的 root/current。
- 当前 root 已失效时，成功打开的目标成为新的 root/current。
- Unix 下打开指向 root 外的目录 symlink 时，按规范化目标切换 root。
- 目标验证或 listing 失败时，root/current 均保持不变。
- `listDirectory` 列举 root 外目录时不修改 workspace 状态。

目录扫描：

- 条目在扫描期间消失并产生 `NotFound` 时，返回其余条目。
- 条目产生 `PermissionDenied` 或其他错误时，listing 明确失败。
- 悬空 symlink 仍作为 symlink 条目返回。
- 目录优先和名称排序行为保持不变。

状态恢复与日志：

- 锁中毒后 `state()` 和 workspace 状态更新仍可继续工作。
- info/warn 日志不包含完整请求 params、路径或详细错误 message。
- debug 日志保留定位扫描竞争和请求失败所需的信息。

## 验收标准

- RPC 请求和响应结构不变，不新增错误 code。
- `workspaceRoot`、`currentDirectory` 和 `listDirectory` 行为符合本文确定语义。
- 扫描竞争不会因单个 `NotFound` 拖垮 listing，其他错误不会被静默忽略。
- backend info/warn 日志不暴露完整路径或 params。
- 执行以下命令均通过：

```sh
cd core
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```
