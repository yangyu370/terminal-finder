# Windows agent 交接：MyGo 自绘 Terminal Finder

交接日期：2026-10-17。分支：`codex/mygo-drawn-windows-handoff`。基线：`master` 的 `11fa3289d6e75bb7509c143622b5d3713120e344`。

## 2026-10-18 实现更新（优先于下文初始交接记录）

本分支现已加入 Windows 原生终端实现：portable-pty/ConPTY、PowerShell7.2+与PSReadLine2.2+引导、独立不可变JSON目录请求、空提示符OnIdle应用、OSC7盘符/UNC转换、失败回报、Windows资源定位与原生构建/测试脚本。Unix/zsh实现保留在平台模块中；外部DTO/协议形状不变。

使用原生Windows PowerShell7运行：

```powershell
Set-Location clients\MyGo
.\build-windows.ps1
.\dist\terminal-finder-drawn.exe --dark --workspace 'C:\work\project'
.\test-windows.ps1
```

`-PreviewOnly` 可只构建不依赖Rust/DLL的组件样板。完整构建自动校验对应MyGo版本的Ghostty DLL并将 `core.exe`、`ghostty-vt.dll` 放到客户端exe旁。PowerShell7必须在PATH；Windows PowerShell5.1不在本首版支持范围内。`test-windows.ps1` 包含真实PTY、MyGo/Ghostty渲染、双向cwd、中文/空格/引号、原生子进程cwd、前台stdin隔离、应用失败、resize及退出检查。

Windows-native CI：`.github/workflows/mygo-windows.yml`。实现验证进行中，不能将下面的历史交叉编译记录当成新实现的实际运行结果；最终状态以CI和提交验证记录为准。物理Windows桌面、输入法、多DPI和UNC真实服务器仍需额外验收。

## 初始交接的目标与状态（2026-10-17）

接手目标是在 Windows 原生桌面上运行 `clients/MyGo/` 的同一套 Finder 风格自绘 UI，连接同仓 Rust core，实现真实终端与文件视图目录双向同步。不要重新写一套 WinForms/WPF UI，也不要把本次工作替换为 WSL-only 方案。

本分支新增实验客户端与参考文档，不修改 Rust 业务代码或 `clients/MacOS/`。保留原仓库历史；不是一个没有 core 的独立 Go 仓库。旧的 Go/AppKit 原生控件试验版未带入本目录。

| 能力 | 已验证 | Windows 待做 |
|---|---|---|
| Go 自绘 UI | macOS 渲染/交互；Windows amd64 交叉编译 | 实机启动、DPI、中文输入法、窗口按钮避让、键盘与文件打开 |
| 目录浏览 | macOS 通过真实 Rust listing | Windows core 编译、盘符/UNC/权限/路径语义 |
| 终端渲染 | macOS MyGo terminal + Ghostty VT | 对应架构 `ghostty-vt.dll` 的打包与加载 |
| PTY 与 shell | macOS Rust PTY + zsh | ConPTY、PowerShell 启动、退出/resize/编码 |
| UI ↔ shell cwd | macOS 真实双向同步、前台程序不被注入 | Windows shell hook、受控切目录、确认屏障和路径 URL |
| Finder 像素一致 | 尚未达到；有严格差分与残差 | 保留外观方向，实测 Windows 字体/DPI 差异 |

当前 Windows exe 只证明能编译；`--demo` 不含真实 backend 或 shell。不要把交叉编译、固定数据演示或跳过集成测试报告成完整 Windows 版已完成。

## Finder 截图与视觉目标

以下 Finder 原图由用户提供，保持原始 PNG 字节，2306×1362px。SHA-256：`d02c1a0bb4f062578f4024c7658c7039601843a00d57e96becefdbbdd36fb1dc`。仅作交接参考，不参与产品 UI 绘制。

![用户提供的原生 Finder 深色截图](clients/MyGo/reference/finder-dark-original.png)

当前 Go 自绘预览使用明确的固定样例数据；文件名和可用功能不与 Finder Recents 一一对应：

![MyGo 自绘深色组件预览](clients/MyGo/reference/mygo-dark.png)

逐组件对照：左为 Finder 原始裁剪，中间为 Go 实际组件状态，右为放大的原始像素误差。分栏/画廊在 MVP 中禁用，主报告保留其与 Finder 参考的状态差异。

![Finder、MyGo 和误差热图](clients/MyGo/reference/component-diff.png)

已校准的基准在 `clients/MyGo/internal/finderui/metrics.go`：工具栏52pt、侧栏总跨度176pt（含MyGo分隔条）、表头区28pt、列表行20pt、左右内收10pt、行顶部5pt、正文/侧栏13pt、表头11pt、标题15pt。圆角和 SVG 光学尺寸部分仍为拟合值。完整说明见 [像素审计](clients/MyGo/FINDER_PIXEL_AUDIT.md)。

目前只有交替行**内部取样**完全相同，不代表整行/整窗一致。材质、文字抗锯齿、文件类型图标和部分矢量边缘仍有差异；不要用原生截图作整窗纹理，也不要放宽像素门禁来宣称通过。浅色/hover/pressed/inactive 尚无同状态原生基准。

## Windows 第一轮：只启动共享 UI

用 Windows 原生 Git、Go，Go版本至少满足 `go.mod` 的1.27.1；本次macOS实测为1.27.2，MyGo锁定0.5.5。以下是 PowerShell 命令，**不要在 Windows 直接执行本目录的 macOS `.sh` 脚本**。

```powershell
git clone --branch codex/mygo-drawn-windows-handoff https://github.com/yangyu370/terminal-finder.git
Set-Location terminal-finder\clients\MyGo
go version
go env GOOS GOARCH
$env:CGO_ENABLED = '0'
go mod download
New-Item -ItemType Directory -Force .\dist | Out-Null
go build -trimpath -ldflags '-H=windowsgui' -o .\dist\terminal-finder-drawn.exe ./cmd/terminal-finder-drawn
if ($LASTEXITCODE -ne 0) { throw 'Go build failed' }
& .\dist\terminal-finder-drawn.exe --demo --dark
```

故障诊断时可去掉 `-ldflags '-H=windowsgui'` 重新构建，以便查看控制台启动错误。

该模式不需要 Rust 或 Ghostty DLL。确认列表/图标切换、搜索展开与Esc、路径对话框、终端面板开关、侧栏与布局拖动、窗口最小化/最大化/关闭。演示模型中仍有macOS风格固定路径，Windows 上需检查路径拆分和演示导航，不要把这些路径当作 Windows 磁盘数据。

先运行不依赖真实shell的测试：

```powershell
go test -count=1 ./internal/backend ./internal/workspace ./internal/osc ./internal/visualdiff ./internal/finderui
```

这组测试尚未在 Windows 实机执行；记录实际失败，不要直接标成通过。其中 `internal/workspace/controller_test.go` 仍使用 `/new`、`/slow`、`/missing` 等Unix绝对路径字面量，Windows `filepath.IsAbs/Join` 会产生不同结果，需先把这些fixture改成 `t.TempDir()` / 本机绝对路径并保持断言语义；这属于已知测试适配项，不等于后端已适配。`internal/launch/server_test.go` 当前使用 `#!/bin/sh` 测试进程；完整 `go test ./...` 的该用例需要改成跨平台测试子进程。`internal/integration/` 也仍使用 zsh/Unix 命令，不能直接当作 PowerShell 验收。

## 架构与代码入口

```text
clients/MyGo/cmd/terminal-finder-drawn/main.go
  → MyGo window + finderui.Browser + terminal.View
  → workspace.Controller
  → backend.Client / backend.Terminal（HTTP / WebSocket）
  → core/ 可选 axum server → workspace / filesystem / Rust PTY
```

| 位置 | 责任/接手重点 |
|---|---|
| `clients/MyGo/cmd/terminal-finder-drawn/main.go` | demo/真实模式、资源路径、窗口与终端装配；默认资源路径仍为macOS `.app/Contents/Resources`，Windows需调整 |
| `clients/MyGo/internal/finderui/` | 自绘布局、SVG、选择态、名称过滤、样例模型；保持共享UI，业务事实从core获取 |
| `clients/MyGo/internal/workspace/controller.go` / `state.go` | 旧报告忽略、最新导航优先、确认屏障、失败保留listing、等待前台程序退出；不要移除这些保护 |
| `clients/MyGo/internal/backend/` | 现有RPC DTO、WS请求关联、原始PTY字节、生命周期；不启动第二个客户端shell |
| `clients/MyGo/internal/launch/server.go` | 托管core进程、HOST/TERM、健康检查、stdin EOF关闭与kill兜底；只关闭自己创建的进程，不杀端口占用者 |
| `clients/MyGo/internal/osc/parser.go` | OSC7流式解析（分包/BEL/ST/异常输入）；Windows URL语义交给core验证 |
| `core/src/terminal/session.rs` | 当前默认 `/bin/zsh`，使用 `portable-pty`；接入/验证Windows ConPTY与shell选择 |
| `core/src/terminal/shell_integration.rs` | **当前编译阻塞**：无条件 `std::os::unix`、`libc::mkfifo`、Unix文件标志、zsh启动脚本与FIFO唤醒；需平台实现分离 |
| `core/src/terminal/websocket.rs` | workspace-bound终端及cwd URL校验；Windows盘符、UNC和URL规范化 |
| `core/src/ffi/`、`protocol/README.md` | 与公共语义/DTO相关改动必须保持一致；默认Swift客户端仍用进程内FFI |
| `clients/MyGo/internal/integration/` | 真实Rust PTY与实际MyGo/Ghostty渲染闭环测试；补Windows版本，不用mock替代全部验收 |

本Go实验明确走 **core 的可选 server 模式**，固定开发地址 `http://127.0.0.1:3587`。`core/src/bin/server.rs` 目前硬编码该端口，stdin EOF会触发退出；手工启动时必须让stdin保持打开。Go托管启动会持有stdin管道，退出时关闭。若端口占用，报错或显式 `--connect`，禁止自动杀已有进程。

Go使用的现有方法包括 `workspace.openDirectory`、`terminal.createWorkspace`、`terminal.changeDirectory`、`terminal.updateWorkingDirectory`。PTY输出里的OSC7先经core验证再影响浏览状态；changeDirectory确认queued不等于shell已经切换成功。

## 建议按这个顺序适配

1. **确认UI独立运行。** 用上述demo命令；检查100%/125%/150%/200% DPI、中文输入法、字体fallback、焦点、窗口控件避让、Ctrl快捷键。macOS底层仍通过MyGo依赖AppKit/NSFont/CoreText；Windows使用其Win32/DirectWrite适配层，不需要AppKit。不能据此承诺两平台文字像素相同。
2. **拿到Windows core的真实编译错误。** 在本机Rust MSVC工具链下执行下面的cargo命令；先拆Unix-only模块，再补Windows实现，保持macOS原有行为。不要先修改协议来绕开后端。
3. **打通PTY和shell。** 初始支持PowerShell（明确选择pwsh或Windows PowerShell及fallback策略），验证ConPTY、初始cwd、UTF-8/中文、resize、Ctrl+C、正常/异常退出。core继续持有会话生命周期；不让Go terminal插件另起本地shell。
4. **实现Windows目录同步。** PowerShell hook上报真实cwd；UI→shell走受控请求与安全时机应用。使用named pipe或等价的独立控制通道，不能把 `cd ...` 塞进前台程序stdin。覆盖空格、中文、单引号、盘符切换、UNC、路径大小写/规范化、旧报告和快速连续导航。
5. **资源定位与打包。** 用exe相邻资源目录等Windows布局，打包 `core.exe`、对应架构 `ghostty-vt.dll`；新增PowerShell构建/测试脚本。保留当前macOS脚本可用；不要提交 `.tools/`、`.cache/`、`dist/` 或原生库二进制。
6. **跑完整验收与记录。** 验收用临时目录与临时shell配置，不修改用户PowerShell profile。提交Windows命令、测试结果、实际截图和未解决项；保留macOS回归。

在 `clients/MyGo/` 下运行core编译检查（当前预期会暴露Unix相关编译问题）：

```powershell
cargo check --locked --manifest-path ..\..\core\Cargo.toml --features server --bin core
# 修复编译问题后再build；不是当前已可运行的承诺。
cargo build --locked --manifest-path ..\..\core\Cargo.toml --features server --bin core
```

Ghostty VT的Windows DLL元数据已随固定版本MyGo提供。`go list -m -f '{{.Dir}}' github.com/egoist/mygo` 找到模块目录后，读取 `plugins/terminal/mygo-plugin.json` 的 `libraries[].files.windows-amd64`（arm64用对应项）。当前amd64文件名 `ghostty-vt.dll`，SHA-256为 `53e8e2dd979702e8f2c48107af19be5a76efc2e88eb7cf1097218e899665da41`；下载必须匹配版本、架构及校验值。

DLL可用 `MYGO_GHOSTTY_VT` 指向完整路径，或按MyGo规则放到exe旁；不要把macOS `.dylib` 改名成 `.dll`。UI demo不加载终端库；完整模式需要它。core编译与同步适配完成后，可先用显式路径绕开尚未修改的默认资源布局：

```powershell
$env:MYGO_GHOSTTY_VT = (Resolve-Path .\dist\ghostty-vt.dll).Path
& .\dist\terminal-finder-drawn.exe --dark --core (Resolve-Path ..\..\core\target\debug\core.exe).Path --workspace 'C:\work\test-project'
```

以上为适配完成后的目标启动方式，当前分支没有可运行的Windows core成品。

## 必须保留的契约与验收

- core拥有目录事实、workspace state与进程生命周期；Go只持有选择、焦点、布局等客户端状态。真实文件列表不能偷偷改成Go `os.ReadDir`。
- `workspaceRoot`是上下文根，不是安全沙箱；root内导航保持root，root外导航重设root；`listDirectory`无状态；目录验证和listing全部成功后才原子更新。
- 本轮不新增删除、重命名等UI写入口，不绕过现有文件变更护栏；不顺带实现S3、索引、插件等无关功能。
- UI进入目录后检查**真实PowerShell cwd**；shell执行 `Set-Location -LiteralPath` 后检查core和UI；无效/不可访问目录保留旧listing并显示错误。
- 快速A→B→C与过期报告不回滚；queued到达不能提前显示Synced；前台程序读stdin期间不收到导航命令，退出后再同步。
- resize合并后的rows/cols有效；隐藏/恢复终端保留同一会话；退出app回收自己创建的core及shell；连接模式不结束共享core。
- core路径比较覆盖 `C:\...`、`D:\...`、UNC、中文、空格、引号、拒绝控制字符；别只在WSL `/mnt/c`上验收。
- backend语义/FFI DTO若变更，同步Rust测试、FFI facade、Swift绑定/客户端与协议。仅内部core改动也需刷新macOS静态库验证；沿用根 README 的构建与FFI刷新流程。

## 交付基线与验证记录

- 本次已通过迁入目录后的 `./build-drawn.sh`、`./test.sh`（vet/race/格式检查、真实Rust PTY与MyGo/Ghostty双向同步）、Python参考提取2项测试、Windows amd64交叉编译，以及文档链接/原图哈希检查。验证主机为macOS arm64，Go1.27.2；Windows实机测试尚未执行。
- `./test.sh` 会启动真实core占用3587端口，必须先关闭托管客户端；它包含 `go vet`、race测试、格式检查、真实Rust PTY与MyGo/Ghostty双向同步测试。
- `./verify-pixels.sh` 当前返回2，表示仍有真实像素差异；与功能测试通过分开记录。固定裁剪、原图哈希和sRGB转换说明在 `internal/finderui/testdata/finder26-dark/provenance.json`。
- Windows原生运行、PowerShell/ConPTY完整闭环、Windows Rust编译和Windows视觉校验仍待接手者完成。仓库根默认macOS客户端的FFI架构没有被本实验替换。
