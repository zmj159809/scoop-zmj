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

脚本默认选择最新正式版，按文件名筛选 Windows 发布资产和架构，下载计算 SHA256，并尝试推断 `extract_dir` 和 `bin`。GitHub 仓库可用完整地址或 `owner/repo` 指定。预览无误后去掉 `-DryRun`，脚本会生成清单并运行基础校验。

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
| [`niubash`](#niubash) | x64 / ARM64 | Windows 原生 Bash 兼容 Shell | [清单](bucket/niubash.json) |

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

[Argus 官方安装版](https://github.com/Ray-lea/Argus) 为所有用户安装到 `Program Files\Argus`，由安装器创建开始菜单入口。

```powershell
scoop install my/argus-setup
scoop update argus-setup
```

**备注**

- 安装、升级和卸载均需管理员 PowerShell。已装过官方安装版时，先通过 Windows「已安装的应用」卸载旧版并保留用户数据。
- 升级或卸载前先从托盘退出 Argus。建议关闭应用内自动更新。Scoop 升级会先调用官方卸载程序，特权服务或任务管理器替换等系统集成可能需要重新启用。

**卸载与残留**

```powershell
scoop uninstall argus-setup
```

- **C 盘文件 · 已确认有残留（使用中产生的数据）**。官方静默卸载保留用户数据。检查 `%APPDATA%\dev.argus.taskmanager` 中的 `settings.json`、`preferences.json`，以及 `%LOCALAPPDATA%\dev.argus.taskmanager` 中的日志和 `history` 目录。如改过历史记录路径，也检查自定义位置。
- **注册表 · 尚未验证**。清单通过 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Argus` 或 `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Argus` 检查安装位置。安装时使用这些项与卸载后是否残留是两回事。若卸载后仍看到 Argus 条目，先确认官方卸载是否成功以及是否还有其他安装实例。
- 两个版本都不再使用且确认数据不再需要后，记得先备份，再手动清理上述文件。

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

生成脚本会填 `checkver`，如需自动更新，应按上游发布规则补齐 `autoupdate`。单架构示例：

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
