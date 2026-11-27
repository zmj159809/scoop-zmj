# 我的 Scoop Bucket

这是一个个人维护的 Windows 软件源。Scoop 从 Git 仓库读取软件清单，推送清单后即可订阅，无需部署网站。

- [仓库目录](#仓库目录)
- [脚本清单与用法](#脚本清单与用法)
- [Scoop Bucket](#scoop-bucket)

## 仓库目录

| 路径 | 用途 |
| --- | --- |
| [`bucket/`](bucket/) | 正式软件清单。文件名去掉 `.json` 后缀就是 Scoop 包名。 |
| [`templates/portable.json`](templates/portable.json) | 便携版 ZIP 清单模板。 |
| [`scripts/`](scripts/) | 生成、校验和更新清单的 PowerShell 脚本。 |
| [`.github/workflows/validate.yml`](.github/workflows/validate.yml) | 在清单、脚本或校验工作流变更时执行基础校验。 |
| [`.github/workflows/excavator.yml`](.github/workflows/excavator.yml) | 定期检查上游版本并更新清单。 |
| [`AGENTS.md`](AGENTS.md) | 仓库维护指引，包含新增软件的文档和卸载提醒要求。 |
| `update-log.txt` | 本地更新脚本生成的日志，已被 [`.gitignore`](.gitignore) 忽略。 |

新增清单时优先用小写字母、数字和短横线命名。

## 脚本清单与用法

以下命令在仓库根目录运行，需要 PowerShell 7。生成清单和检查更新需要访问 GitHub 及相应的发布资产。

| 脚本 | 用途 | 文件改动 |
| --- | --- | --- |
| [`validate.ps1`](scripts/validate.ps1) | 检查清单格式、必要字段、下载地址和哈希格式 | 无 |
| [`new-manifest.ps1`](scripts/new-manifest.ps1) | 根据 GitHub Release 生成软件清单 | 默认写入 `bucket/` |
| [`check-updates.ps1`](scripts/check-updates.ps1) | 检查已收录软件的上游版本 | 确认更新后修改清单并追加本地日志 |

### 校验清单

```powershell
pwsh -NoProfile -File ./scripts/validate.ps1
```

`-BucketPath` 可指定其他清单目录，默认使用仓库的 `bucket/`。脚本检查文件名、JSON 格式、模板占位符、必要字段、支持的架构、HTTP(S) 地址和 SHA256 格式。下载包的实际哈希和软件能否安装运行需要另行验证。GitHub Actions 的 Validate bucket 工作流也运行此脚本。

### 从 GitHub Release 生成清单

```powershell
pwsh -NoProfile -File ./scripts/new-manifest.ps1 https://github.com/unixwin/niubash -DryRun
pwsh -NoProfile -File ./scripts/new-manifest.ps1 unixwin/niubash -Version 1.4.2 -DryRun
```

脚本默认选择最新正式版，按文件名筛选 Windows 发布资产和架构，下载计算 SHA256，并尝试推断 `extract_dir`、`bin` 以及 `checkver` / `autoupdate`（便携单文件 `.exe` 会自动追加 `#/<包名>.exe` 固定本地文件名）。GitHub 仓库可用完整地址或 `owner/repo` 指定。预览无误后去掉 `-DryRun`，脚本会生成清单并运行基础校验。

| 参数 | 用途 |
| --- | --- |
| `-RepoUrl` | GitHub 仓库地址，可作为第一个位置参数传入。省略时脚本会询问。 |
| `-Version` | 指定发布版本，例如 `1.4.2` 或 `v1.4.2`，也会尝试匹配上游带前缀的 tag。 |
| `-Name` / `-BucketPath` | 指定包名或输出目录，默认取仓库名并写到 `bucket/`。 |
| `-Bin` / `-ExtractDir` | 手动指定命令入口或包内解压目录。 |
| `-DryRun` / `-Force` | 分别为只预览和允许覆盖已有清单。 |
| `-NoHash` | 跳过下载，生成带 `REPLACE_ME` 哈希的草稿，发布前须补齐。 |
| `-Prerelease` | 允许使用预发布版本。 |
| `-Token` | 指定 GitHub 令牌，默认读取 `GITHUB_TOKEN`。 |

有多个命令入口候选时可用 `-Bin` 指定。检查 `.7z` 内容需要本机的 7-Zip。MSI 或 EXE 安装器生成的清单需要按实际安装、升级和卸载行为补齐。

### 检查并更新清单

```powershell
pwsh -NoProfile -File ./scripts/check-updates.ps1 -CheckOnly
pwsh -NoProfile -File ./scripts/check-updates.ps1
```

脚本从 `checkver.github` 或 GitHub `homepage` 查找最新正式版，默认逐项询问是否更新。确认后会更新版本、下载链接、哈希及带版本号的解压目录，写入前重新解析 JSON，并在 `update-log.txt` 记录改动。哈希优先使用 GitHub Release 的 asset digest，缺少时下载计算。单个仓库查询失败时会继续检查其余清单。

| 参数 | 用途 |
| --- | --- |
| `-CheckOnly` | 只检查新版本。 |
| `-Yes` | 跳过询问，更新所有发现新版本的清单。 |
| `-BucketPath` / `-LogPath` | 指定清单目录或日志路径。 |
| `-Token` | 指定 GitHub 令牌，默认读取 `GITHUB_TOKEN`。 |

GitHub API 限流时，生成和更新脚本会尝试通过 Release 网页或 Atom Feed 查询。需要提高 API 配额时可以设置 `GITHUB_TOKEN`。SSH 密钥用于 Git 操作，API 调用使用令牌。

## Scoop Bucket

### 订阅、安装与更新

准备好 [Scoop](https://scoop.sh/) 和 Git 后，在 PowerShell 中运行以下命令。订阅地址根据当前仓库的 Git `origin` 填写。

```powershell
scoop bucket add my https://github.com/zmj159809/scoop-zmj.git
scoop bucket list
scoop install my/niubash
```

`my` 是本机别名。换用其他别名时，同时替换安装命令中的 `my/`。私有仓库需先配置可访问仓库的 Git 凭据。

```powershell
scoop update          # 同步 Scoop 和各 Bucket
scoop update niubash  # 更新已安装的 niubash
```

### 已收录软件

版本以各清单中的 `version` 字段为准。

| 软件包 | 架构 | 用途 | 清单 |
| --- | --- | --- | --- |
| [`argus`](#argus) | x64 | Windows 任务管理器，便携版 | [清单](bucket/argus.json) |
| [`argus-setup`](#argus-setup) | x64 | Windows 任务管理器，官方全用户安装版 | [清单](bucket/argus-setup.json) |
| [`cloudy`](#cloudy) | x64 / ARM64 | 第三方网易云音乐桌面客户端 | [清单](bucket/cloudy.json) |
| [`codex-proxy-rs`](#codex-proxy-rs) | x64 / ARM64 | 面向 Codex 的自托管多账号 AI 透明代理网关 | [清单](bucket/codex-proxy-rs.json) |
| [`niubash`](#niubash) | x64 / ARM64 | Windows 原生 Bash 兼容 Shell | [清单](bucket/niubash.json) |
| [`tools3000`](#tools3000) | x64 | 轻量原生 Windows 桌面效率工具集，便携版 | [清单](bucket/tools3000.json) |

以下文件残留说明来自现有清单及其卸载脚本。`%APPDATA%`、`%LOCALAPPDATA%` 和 `%USERPROFILE%` 通常在 C 盘，实际位置以当前账户和软件配置为准。`scoop uninstall --purge <包名>` 清理 Scoop 管理的持久化数据。应用自行保存的数据按下列条目检查。当前清单带有卸载提醒，使用旧清单安装的版本可能要在升级或重装后才会显示提醒。

#### argus

[Argus](https://github.com/Ray-lea/Argus) 可查看进程、性能、历史记录、文件锁、网络连接、服务和启动项，也可在托盘、桌面或任务栏显示监控信息。

```powershell
scoop install my/argus
scoop update argus
```

从开始菜单打开「Argus」或运行 `argus`。默认用 `Ctrl+Alt+Esc` 显示或隐藏窗口。

**备注**

- 当前清单使用 x64 便携版，要求 Windows 10 22H2（build 19045）或 Windows 11，以及支持 DirectX 11 的显卡。Windows ARM64 上的运行依赖 x64 模拟支持。
- 两个 Argus 版本共用账户下的配置和历史记录。若曾手动启用特权服务、PawnIO 或任务管理器替换，请在卸载前通过 Argus 设置关闭并移除。升级后特权服务副本未同步时，在「设置 → 权限 → 特权服务」中更新。
- 下载地址末尾的 `#/argus.exe` 用于让 Scoop 固定本地文件名。

**卸载与残留**

```powershell
scoop uninstall argus
```

- **C 盘文件 · 已确认有残留（使用中产生的数据）**。清单提示检查 `%APPDATA%\dev.argus.taskmanager` 的设置、界面偏好，以及 `%LOCALAPPDATA%\dev.argus.taskmanager` 的日志和历史记录。如修改过历史记录路径，也检查自定义位置。
- **注册表 · 尚未验证**。便携清单不执行安装器，也不自动启用任务管理器替换。手动开启系统集成的情况请优先通过应用设置还原。
- 两个版本都不再使用且确认数据不再需要后，记得先备份，再手动清理上述文件。

#### argus-setup

`argus-setup` 使用 [Argus 官方 x64 安装程序](https://github.com/Ray-lea/Argus) 安装 Windows 任务管理器。主程序位于 `<Scoop 根目录>\apps\argus-setup\<版本>`，例如 `D:\scoop\apps\argus-setup\0.6.0`。从开始菜单打开「Argus (Setup)」。

```powershell
scoop install my/argus-setup
scoop update argus-setup
```

**备注**

- 请在管理员 PowerShell 中执行安装、升级和卸载。要求 Windows 10 22H2（build 19045）或 Windows 11，以及支持 DirectX 11 的显卡。
- 如果旧 Scoop 清单已把程序装到 `Program Files\Argus`，请先备份配置和历史记录，并关闭下文所列已启用的系统集成。接着执行 `scoop uninstall argus-setup`，再执行 `scoop install my/argus-setup`。单独用官方安装器安装的版本，可在 Windows「已安装的应用」中卸载，保留用户数据后再安装 Scoop 版。
- 升级或卸载前先从托盘退出 Argus。建议关闭应用内自动更新，统一由 Scoop 更新。安装程序仍可刷新已有的特权服务及任务管理器替换组件，这些组件使用系统路径。

**卸载与残留**

卸载前，在 Argus 设置中关闭并移除已启用的开机启动、特权服务、PawnIO 和任务管理器替换。Scoop 调用官方卸载程序时使用 `/UPDATE` 和 `_?=`，以保留共享系统集成和用户数据。

```powershell
scoop uninstall argus-setup
```

- **C 盘文件 · 已确认有残留（使用中产生的数据）**。根据官方静默卸载脚本，程序保留 `%APPDATA%\dev.argus.taskmanager` 的设置和界面偏好，以及 `%LOCALAPPDATA%\dev.argus.taskmanager` 的日志和 `history` 目录。若应用数据目录或历史记录目录位于其他盘，也请检查相应位置。
- **注册表 · 已确认有残留（根据官方脚本）**。`HKLM\SOFTWARE\Argus contributors\Argus` 的默认值记录上次安装路径。Scoop 会检查官方卸载使用的 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Argus` 是否已移除。若启用过开机启动，`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下的 `Argus` 值也会保留，可在应用设置中关闭。
- 两个版本都不再使用且确认数据不再需要后，先备份再手动清理上述用户数据和上次安装路径。若卸载后还留有特权组件，优先通过 Argus 设置移除。卸载行为依据 [官方安装模板](https://github.com/Ray-lea/Argus/blob/v0.6.0/packaging/windows/installer-template.nsi) 和 [安装钩子](https://github.com/Ray-lea/Argus/blob/v0.6.0/packaging/windows/installer-hooks.nsh)。

#### cloudy

[Cloudy](https://github.com/nya-owo/cloudy)（原名 Cloud-nya）是使用 Go 和 MyGo 原生界面的第三方网易云音乐客户端。

```powershell
scoop install my/cloudy
scoop update cloudy
```

从开始菜单打开「Cloudy」或运行 `cloudy`。打开客户端后可扫码登录。在「设置 → 下载与缓存 → 本地音乐」中添加音乐目录，也可以直接拖入文件或文件夹。

**备注**

- 上游未签名，首次运行可能显示 SmartScreen 提示。请先核对软件来源。
- 建议在「设置 → 关于」关闭应用内自动更新，统一由 Scoop 更新，以保持文件版本和 `scoop list` 一致。
- 清单使用上游可直接解压运行的 tar.gz 更新包。上游另有 EXE 安装器，其安装目录和注册表行为不适用于此清单。

**卸载与残留**

```powershell
scoop uninstall cloudy
```

- **C 盘文件 · 已确认有残留（使用中产生的数据）**。清单提示检查 `%APPDATA%\Cloudy` 的设置和播放数据、`%LOCALAPPDATA%\Cloudy` 的默认缓存，以及自定义缓存和下载目录。
- **注册表 · 尚未验证**。此清单使用便携更新包。登录凭据由系统保存，需要清除时请在卸载前从 Cloudy 退出账号。
- 确认文件不再需要后，记得先备份设置和需要保留的下载歌曲，再手动清理。

#### codex-proxy-rs

[Codex Proxy RS](https://github.com/zyycn/codex-proxy-rs) 是基于 Rust 的自托管多账号 AI 透明代理网关，支持 OpenAI Responses、Chat Completions 和 Anthropic Messages 协议，内置多账号调度、限额与用量统计管理端。

```powershell
scoop install my/codex-proxy-rs
notepad "$(scoop prefix codex-proxy-rs)\..\..\persist\codex-proxy-rs\deploy\config.yaml"
Set-Location (scoop prefix codex-proxy-rs)
codex-proxy-rs serve
scoop update codex-proxy-rs
```

启动前编辑 `deploy\config.yaml`，填写 `store.database`、`store.redis` 的连接地址与独立密码，以及 `admin.default_password`。在安装目录执行 `codex-proxy-rs serve` 启动后，默认可通过 `http://127.0.0.1:8080` 打开管理端（默认账号 `admin@cpr.local`），按 `Ctrl+C` 停止服务。

**备注**

- 运行前需准备可访问的 PostgreSQL（最低版本 16）和 Redis；若使用管理端的数据库备份功能，还需将匹配服务端版本的 `pg_dump` 加入 `PATH`。常规安装无需管理员权限，上游二进制未做代码签名，首次运行可能显示 SmartScreen 提示，请先核对软件来源。
- 后端从当前工作目录向上查找 `deploy/config.yaml`，并依赖包内的 `web/dist` 与 `plugins/official` 目录结构，因此请切换到 `$(scoop prefix codex-proxy-rs)` 后再启动。清单在首次安装时自动从 `deploy\config.example.yaml` 生成初始 `deploy\config.yaml`（已将 `api.asset_directory` 设为 `'../web/dist'`），并通过 `persist` 持久化 `deploy/config.yaml` 与 `.runtime`。若编辑器保存时采用替换文件方式导致单文件硬链接断开，可直接编辑 `<Scoop 根目录>\persist\codex-proxy-rs\deploy\config.yaml` 并运行 `scoop reset codex-proxy-rs` 恢复链接。
- 建议不要使用管理端的在线更新功能，以免直接改写版本目录文件而绕过 Scoop 版本管理；升级前先按 `Ctrl+C` 停止服务，再运行 `scoop update codex-proxy-rs`，并对照新版本的 `deploy\config.example.yaml` 合并新增字段。

**卸载与残留**

```powershell
scoop uninstall codex-proxy-rs
```

- **C 盘文件 · 经核对未发现**。核对上游 [部署与运维文档](https://github.com/zyycn/codex-proxy-rs/blob/v3.55.2/deploy/README.md) 及本地启动行为，程序不在 `%APPDATA%` 或 `%LOCALAPPDATA%` 创建目录，仅读写工作目录下的 `deploy\config.yaml` 与 `.runtime`（含 `data` 下的会话锚点密钥、更新状态、备份暂存区，以及 `logs` 下的应用日志、按需开启的 OAuth 恢复记录与请求转储）。常规卸载默认保留 `<Scoop 根目录>\persist\codex-proxy-rs`（Scoop 装在默认路径 `%USERPROFILE%\scoop` 时位于 C 盘，装在其他盘时位于对应盘符；可用 `scoop uninstall --purge codex-proxy-rs` 清理）。若曾在自定义工作目录运行或修改过 `runtime_data_dir` 与日志路径，对应目录也会保留。
- **注册表 · 经核对未发现**。清单使用上游便携 `tar.gz` 归档，不执行安装器也不注册系统服务；核查清单与可执行文件仅见读取系统代理设置（`Internet Settings`），未发现应用专用的注册表写入项。
- 账号、客户端密钥、用量记录与插件状态保存在外部 PostgreSQL，协调状态保存在 Redis；若曾手动修改 `%USERPROFILE%\.codex\config.toml`（或 `CODEX_HOME`）接入本地网关，或将管理端安装为浏览器 PWA，卸载后也不会自动改动。确认无其他安装实例在用且不再需要后，请先备份 `deploy\config.yaml`、`.runtime` 日志与数据库内容，再手动清理对应目录和数据，并按需还原客户端配置。

#### niubash

[niubash](https://github.com/unixwin/niubash) 是 Windows 原生 Bash 兼容 Shell，包含 Unix 命令和 Git。

```powershell
scoop install my/niubash
niu --version
niu                    # 打开交互式 Shell
niu -c "ls -la"        # 执行单条命令
scoop update niubash
```

也可从开始菜单打开「Niubash」。`ls`、`grep` 和 `git` 等命令可在 `niu` 环境中直接使用。

**备注**

- 当前清单只将 `niu.exe` 暴露为命令行入口，避免与 Git Bash 或 MSYS2 的命令冲突。要单独调用包内的 `winuxcmd`，可在安装目录中找到 `winuxcmd\usr\bin\winuxcmd.exe`。
- 常规安装无需管理员权限。上游包未签名，首次运行可能显示 SmartScreen 提示。请先核对软件来源。
- 清单使用上游 tar.gz 包，解压时可还原 Git 和 awk 载荷使用的硬链接，并通过 `extract_dir` 定位带版本号的顶层目录。

**卸载与残留**

```powershell
scoop uninstall niubash
```

- **C 盘文件 · 已确认有残留（使用中产生的数据）**。清单提示检查 niubash 主目录（默认通常是 `%USERPROFILE%`）下的 `.niubashrc`、`.niubash_history` 和 `.niubash` 目录。设置了 `HISTFILE` 时也检查自定义历史文件。
- **注册表 · 尚未验证**。清单未定义应用专用的注册表清理操作。
- 确认配置和命令历史不再需要后，记得先备份，再手动删除。

#### tools3000

[Tools3000](https://github.com/yuan278501381/Tools3000) 是基于 C++20 与 Rust 的轻量原生 Windows 桌面效率工具集，集成文件/应用/书签即时搜索、空格预览、剪贴板历史、文本扩展、文件锁定解锁、滚动截图与离线 OCR、自动缩放录屏、全局鼠标手势和 Picasa 风格看图等功能。

```powershell
scoop install my/tools3000
scoop update tools3000
```

从开始菜单打开「Tools3000」或运行 `tools3000`，也可在终端使用 `tools3000-cli`。

**备注**

- 要求 Windows 10 / 11 / Server（x64），界面依赖系统 Microsoft Edge WebView2 Runtime。
- 由于 Tools3000 的原子写盘逻辑与伴生模块（`Tools3000_WindowKit.exe`、`Tools3000_Picasa_Viewer.exe`）校验均会拒绝包含目录联接（Junction）的路径，清单通过 `pre_install` 生成指向真实版本号目录的启动器（绕过 `current` 目录联接），并通过 `persist` 与 `env_set` 将 `TOOLS3000_DATA_ROOT` 设为 `<Scoop 根目录>\persist\tools3000\.tools3000` 这一真实物理路径，使 `config.json`、日志、统计数据、剪贴板历史、离线 OCR 模型与 WebView2 运行数据直接写入持久化目录，既避免目录联接拦截，也不写入系统用户目录。若在安装前已打开终端，请新开终端后再启动以使环境变量生效。
- 建议关闭应用内自动更新，统一通过 `scoop update tools3000` 升级。首次运行若出现 SmartScreen 提示，请先核对软件来源。

**卸载与残留**

```powershell
scoop uninstall tools3000
```

- **C 盘文件 · 经核对未发现（便携模式下）**。核对上游文档与便携包结构，便携模式仅读写程序目录下的持久化数据目录，不写入 `%LOCALAPPDATA%\Tools3000`。常规卸载默认保留 `<Scoop 根目录>\persist\tools3000`（Scoop 装在默认路径 `%USERPROFILE%\scoop` 时位于 C 盘，装在其他盘时位于对应盘符；可用 `scoop uninstall --purge tools3000` 清理）。若曾在非便携模式下运行过独立版本，也请检查 `%LOCALAPPDATA%\Tools3000`。
- **注册表 · 尚未验证**。便携清单不执行官方安装程序，也不主动写入安装器注册表项；但若在软件设置中手动开启了开机自启或 File Locksmith 右键菜单等系统集成，卸载前请先在应用设置中关闭。
- 确认无其他安装实例在用且数据不再需要后，请先备份配置、剪贴板与统计数据，再手动清理上述目录。

### 添加软件与发布

可用 [生成脚本](#从-github-release-生成清单)，也可复制模板后编辑。

```powershell
Copy-Item ./templates/portable.json ./bucket/my-app.json
notepad ./bucket/my-app.json
```

将 `version`、`description`、`homepage`、`license`、`url`、`hash` 等字段填为实际值并替换所有占位符。下载地址使用固定版本的资产直链。按程序实际路径设置 `bin` 和 `shortcuts`。压缩包若有统一的顶层目录，填写 `extract_dir`，此时程序路径相对该目录填写。只有需要 Scoop 跨版本保留的应用目录才加入 `persist`。安装器类清单需按实际安装行为编写。

可手动下载对应资产计算哈希，下面的地址需替换为真实直链。

```powershell
$downloadUrl = 'https://example.com/app-1.2.3-win64.zip'
$packagePath = Join-Path $env:TEMP 'my-app-1.2.3.zip'
Invoke-WebRequest -Uri $downloadUrl -OutFile $packagePath
(Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
```

新增软件时按 [维护指引](AGENTS.md) 补齐 README 条目、安装备注和卸载提示。提交前先运行基础校验，在测试环境验证安装、启动和卸载，再将清单和文档一起提交。

```powershell
pwsh -NoProfile -File ./scripts/validate.ps1
scoop install ./bucket/my-app.json
```

如果要建立自己的 Bucket，可在 GitHub 创建空仓库，将本仓库内容连同 `.github/` 推送到默认分支，再用新仓库地址订阅。使用 SSH 或 HTTPS 均可，已有 Git 仓库可沿用现有设置。

### GitHub Actions 自动维护

[Excavator](.github/workflows/excavator.yml) 使用 [ScoopInstaller/GithubActions](https://github.com/ScoopInstaller/GithubActions)，每 4 小时在默认分支检查同时配置 `checkver` 和 `autoupdate` 的清单。北京时间约为 00:20、04:20、08:20、12:20、16:20 和 20:20，执行时间可能延迟。也可在仓库的 Actions → Excavator → Run workflow 中手动运行。

- 发现新版后，工作流更新下载地址、SHA256 以及适用的解压目录，并使用 GitHub 提供的 `GITHUB_TOKEN` 提交和推送。仓库策略和分支保护规则需允许该操作。
- 工作流在更新前后执行基础校验。更新后的校验会报告结果，此时官方 Action 已完成推送。用 `GITHUB_TOKEN` 推送的自动提交不会再次触发普通 push 校验。
- 运行失败时在对应任务查看日志。公开仓库长期不活跃时，GitHub 可能暂停定时任务，可在 Actions 页面重新启用。

生成脚本会填 `checkver`，并尽量按下载链接和 `extract_dir` 中的版本号自动生成 `autoupdate`；若上游发布规则特殊，请按实际情况手动调整。单架构示例：

```json
{
  "checkver": {
    "github": "https://github.com/owner/repo"
  },
  "autoupdate": {
    "url": "https://github.com/owner/repo/releases/download/v$version/app-$version-win64.zip"
  }
}
```

多架构的下载地址放到 `autoupdate.architecture.64bit`、`arm64` 等对应条目下，带版本号的 `extract_dir` 也要使用 `$version` 模板。已有清单可作为示例。上游更改 tag、资源名称或目录规则时需要同步修正。自动维护更新的是仓库清单，已安装软件仍通过 `scoop update <包名>` 升级。

### 官方参考

- [Scoop 官网](https://scoop.sh/)
- [软件清单说明](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests)
- [自建 Bucket](https://github.com/ScoopInstaller/Scoop/wiki/Buckets)
- [自动更新配置](https://github.com/ScoopInstaller/Scoop/wiki/Autoupdate)
