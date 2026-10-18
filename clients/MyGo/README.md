# Terminal Finder — MyGo 自绘客户端（实验分支）

这是 Go/MyGo 自绘 Finder 风格 UI，复用仓库 `core/` 的现有 Rust backend。工具栏、侧栏、列表、图标、路径栏和终端面板外壳使用共享 Go 组件和自有 SVG；本目录不包含旧的 Go/AppKit 原生控件试验版。

**Windows agent 从 [WINDOWS_MYGO_HANDOFF.md](../../WINDOWS_MYGO_HANDOFF.md) 开始。** 文档包含 Windows 启动命令、已知阻塞、适配顺序、验收用例和 Finder 原始截图。

![Finder 深色参考](reference/finder-dark-original.png)

![当前 MyGo 深色组件预览，固定样例数据](reference/mygo-dark.png)

## 当前能力与边界

- 本地目录导航、历史、路径输入、隐藏 dotfiles、名称过滤、列表/图标模式、名称/日期排序、终端面板显隐与拖动布局。
- Rust 持有 workspace、目录验证与 listing、PTY 会话和目录同步；客户端不绕过 core 读取真实文件系统构造业务状态。
- 真实终端通过 MyGo terminal/Ghostty VT 展示 Rust PTY；UI 导航与 shell `cd` 双向同步，前台程序运行时排队，不能向其 stdin 注入 `cd`。
- 分栏/画廊按钮禁用；没有 S3 客户端、文件写操作、递归搜索、索引、git awareness 等新增功能。
- macOS 与 Windows x64 的真实本地终端闭环已通过自动化验证。Windows使用 ConPTY / PowerShell7.2+；CI、下载包与实际渲染截图见交接文档。物理桌面、输入法/DPI仍需验收。
- 深浅两套配色；当前 Finder 参考只有深色静止画面。字体、动态材质、图标边缘尚未像素一致，见 [像素审计](FINDER_PIXEL_AUDIT.md)。

本实验明确使用 Rust 的**可选 HTTP/WebSocket server 模式**，开发端口 `127.0.0.1:3587`，接口与 `protocol/README.md` 对齐。仓库原 `clients/MacOS/` 的默认进程内 UniFFI 路径保持原状；不要把本实验的端口和进程模型套用到原客户端。

## Windows（PowerShell7.2+）

```powershell
.\build-windows.ps1
.\dist\terminal-finder-drawn.exe --dark --workspace 'C:\work\project'
.\test-windows.ps1
```

完整构建需要Go、Rust MSVC工具链与PATH中的 `pwsh.exe`；启动后要求PSReadLine2.2+。`-PreviewOnly` 只编译UI。Windows资源放在exe旁；目录同步独立于stdin，前台程序运行时排队。原生自动化状态见交接文档，不能用交叉编译替代运行验证。

## macOS Apple Silicon

```sh
cd clients/MyGo
./bootstrap.sh
./build-drawn.sh
./run-drawn.sh --dark --workspace /some/local/project
```

需要 PATH 中的 Rust/Cargo；`CARGO` 可指定 cargo 路径，`TF_CORE_REPO` 可覆盖 core 所在仓库。构建缓存、Go 工具链、Rust target 与 dist 都留在本目录并忽略；不提交二进制、dylib 或依赖缓存。

`./build-drawn.sh` 默认编译本分支 `../../core/` 的 server，再打包 `dist/Terminal Finder Drawn.app`。`TF_CORE_BINARY` 仅用于显式复用已构建的同版本 core。当前 `bootstrap.sh` / `go-local` 是 macOS shell 脚本，Windows 请使用交接文档的原生 Go/PowerShell 命令。

组件预览不需要 Rust、Ghostty DLL/dylib 或 shell：

```sh
./run-drawn.sh --demo --dark
./run-drawn.sh --demo --dark --capture .cache/components.png
```

`--demo` 的固定数据明确标记为样例；打开终端面板会显示没有 shell session，不伪装成真实文件系统或终端。

## 验证

macOS 完整验证（先退出占用3587端口的客户端）：

```sh
./test.sh
./verify-pixels.sh
```

`test.sh` 包含 vet、race、格式检查和真实 Rust PTY/Ghostty 双向同步集成。直接 `go test ./...` 未提供环境变量时会跳过真实集成，不能当作完整终端验证。`verify-pixels.sh` 是单独的严格视觉门禁，当前因实际残差返回2；不得用放宽阈值掩盖。

不需要真实 backend 的测试可直接执行：

```sh
go test ./internal/backend ./internal/workspace ./internal/osc ./internal/visualdiff ./internal/finderui
```

Finder 原图仅是文档与测试参考，不作为界面的纹理。原图、当前 Go 预览与组件热图位于 `reference/`；小块自动化基准及坐标/哈希位于 `internal/finderui/testdata/finder26-dark/`。
