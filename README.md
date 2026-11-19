# 我的 Scoop Bucket

自己维护的 Windows 软件源（Scoop bucket）。仓库推送到 GitHub 后，用 `scoop bucket add` 订阅即可在任意电脑上安装这里收录的软件。

不需要搭建网站，也不需要 GitHub Pages：Scoop 直接读取仓库里 `bucket/*.json` 这些清单文件。

```powershell
scoop bucket add my https://github.com/YOUR_GITHUB_NAME/scoop-bucket.git
scoop install my/niubash
```

> 每收录一个新软件，都在下面的 [已收录软件](#已收录软件) 里补一节使用说明，格式照抄已有条目。

---

## 目录说明

```text
bucket/                         正式软件清单，每个软件一个 JSON
  cloudy.json                   Cloudy（网易云音乐第三方客户端）1.3.2
  niubash.json                  niubash（Bash for Windows）1.5.0
templates/portable.json         便携版 ZIP 模板（不会被 Scoop 当成软件）
scripts/validate.ps1            清单基础校验，本地和 GitHub Actions 都用它
scripts/new-manifest.ps1        给一个 GitHub 地址，自动生成清单
scripts/check-updates.ps1       检查上游新版本，按需改写清单并写日志
update-log.txt                  更新日志（已在 .gitignore 中忽略，不上传）
.github/workflows/validate.yml  GitHub Actions：推送时自动跑校验
README.md                       本文档
```

| 路径 | 说明 |
| --- | --- |
| `bucket/` | **必须**叫这个名字，Scoop 只扫描这一层。文件名即软件名：`bucket/foo.json` → `scoop install my/foo` |
| `templates/` | 手工写清单时的起点。Scoop 不读这里，放着不会变成可安装软件 |
| `scripts/` | 辅助脚本，不参与安装流程 |
| `.github/workflows/` | 只做校验，不会自动改版本或推送提交 |

命名约定：清单文件名只用小写字母、数字和短横线。

---

## 这个 Bucket 是什么

| 项目 | 说明 |
| --- | --- |
| 类型 | 个人自建 bucket（不是官方 main / extras / versions） |
| 仓库名 | 示例用 `scoop-bucket`，可任意取 |
| 本地别名 | 示例用 `my`，`scoop bucket add` 时的第一个参数，可任意取 |
| 分支 | `main` |
| 可见性 | 推荐公开；私有仓库需要本机 Git 已配置 GitHub 凭据，`scoop update` 时才不会卡住 |
| 收录策略 | 只放自己确实在用的软件；便携版优先，安装器类按实际安装行为单独写 |
| 自动更新 | 靠 `scripts/check-updates.ps1` 手动触发；没有配置 GitHub Actions 自动改版本 |

订阅端的工作方式：

1. `scoop bucket add my <仓库地址>` 把仓库克隆到 `~/scoop/buckets/my`；
2. `scoop update` 会 `git pull` 同步所有 bucket；
3. `scoop install my/<清单名>` 读取 `bucket/<清单名>.json` 安装。

所以**只要清单文件被推送上去，订阅端 `scoop update` 后就能装到新版本**，无需额外发布步骤。

---

## 脚本清单

三个脚本都只依赖 PowerShell 7（`pwsh`），在本项目根目录运行。

| 脚本 | 作用 | 会不会改文件 | 常用命令 |
| --- | --- | --- | --- |
| [`scripts/validate.ps1`](scripts/validate.ps1) | 校验清单字段、格式、占位符 | 否 | `pwsh -NoProfile -File .\scripts\validate.ps1` |
| [`scripts/new-manifest.ps1`](scripts/new-manifest.ps1) | 从 GitHub 仓库生成清单 | 是（写 `bucket/`） | `pwsh -NoProfile -File .\scripts\new-manifest.ps1 <仓库地址>` |
| [`scripts/check-updates.ps1`](scripts/check-updates.ps1) | 查上游新版本，询问后改写清单 | 是（改清单 + 写日志） | `pwsh -NoProfile -File .\scripts\check-updates.ps1` |

### validate.ps1 —— 校验清单

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
```

检查内容：文件名是否为小写、是否残留 `REPLACE_ME`、`version` / `description` / `homepage` / `license` 是否齐全、`architecture` 下每个架构（`32bit` / `64bit` / `arm64`）是否都有 `url` 和 `hash`、`url` 是否为 http(s) 绝对地址、`hash` 是否为 64 位十六进制。

**它不下载文件、不核对远端哈希、不验证所有 Scoop 字段**，也不能代替实际安装测试。提交前请用 `scoop install .\bucket\<名字>.json` 实测一次。

GitHub Actions 在 push 和 pull_request 时自动跑同一个脚本（只监听 `bucket/**` 和 `scripts/**` 的改动）。

### new-manifest.ps1 —— 自动生成清单

不想手工查版本、算哈希时，直接给它一个 GitHub 地址：

```powershell
pwsh -NoProfile -File .\scripts\new-manifest.ps1 https://github.com/unixwin/niubash
```

**它做了什么**

1. 解析仓库地址（`https://github.com/owner/repo`、`owner/repo`、带 `.git` 或 `releases` 路径都可以）；
2. 查询最新正式 Release，拿到版本号、仓库简介和许可证（API 限流时自动改用网页查询）；
3. 从发布资产里挑出 Windows 平台的安装包，按文件名识别 `64bit` / `arm64` / `32bit`，跳过 macOS、Linux、校验文件和源码包；
4. 下载选中的包，计算 SHA256，列出压缩包内容，推断 `extract_dir`（唯一的顶层目录）和 `bin`（顶层的可执行文件）；
5. 生成 `bucket/<名称>.json`，然后自动跑一遍 `validate.ps1`。

**输出示例**

```text
仓库：unixwin/niubash
最新版本：1.5.0（https://github.com/unixwin/niubash/releases/tag/v1.5.0）
[64bit] niubash-v1.5.0-win-x64.tar.gz
  下载中……
  extract_dir：niubash-v1.5.0-win-x64
  可执行文件：niu.exe
[arm64] niubash-v1.5.0-win-arm64.tar.gz
  ……
bin：niu.exe
```

**参数**

| 参数 | 作用 |
| --- | --- |
| `-Version` | 指定版本，例如 `1.5.0`、`v1.5.0`；默认取最新正式版 |
| `-Name` | 清单文件名（不含 `.json`），默认取仓库名 |
| `-Bin` | 手工指定加入 PATH 的程序，覆盖自动推断 |
| `-ExtractDir` | 手工指定压缩包内的子目录 |
| `-DryRun` | 只打印生成的清单，不写文件 |
| `-Force` | 清单已存在时覆盖 |
| `-NoHash` | 不下载资产，只按命名规则生成骨架（`hash` 留成 `REPLACE_ME`） |
| `-Prerelease` | 允许使用预发布版本 |
| `-Token` | GitHub 令牌，默认读环境变量 `GITHUB_TOKEN` |

**指定版本**

```powershell
pwsh -NoProfile -File .\scripts\new-manifest.ps1 https://github.com/unixwin/niubash -Version 1.4.2
```

上游 tag 是 `niubash-v1.4.2` 也能匹配：脚本依次尝试 `1.4.2`、`v1.4.2`，再按「以该版本号结尾」在最近 15 个 tag 里模糊匹配。命中后清单里的 `version` 会规范化成 `1.4.2`（去掉 `v` 和前缀）。确实没有这个版本时，会列出仓库最近可用的版本。

**猜不出来时会明说**，不会硬写错的东西：

- 顶层有多个可执行文件 → 不填 `bin`，列出候选，让你用 `-Bin` 选；
- 压缩包里没有统一顶层目录 → 不写 `extract_dir`；
- `.7z` 且本机没装 7-Zip → 看不到内容，提示 `extract_dir` / `bin` 需手工确认；
- `.msi` → 提示要补 `installer` 脚本；`.exe` 安装器按「可执行文件」处理，需要按实际安装行为改写。

建议先 `-DryRun` 看一眼，再真正写入。

### check-updates.ps1 —— 检查并升级版本

```powershell
pwsh -NoProfile -File .\scripts\check-updates.ps1
```

遍历 `bucket/` 里的每个清单，查询对应 GitHub 仓库的最新正式 Release。发现更高版本时打印版本号和 Release 链接，并询问 yes/no：

```text
niubash：发现新版本 1.6.0（当前 1.5.0）
  最新版本：1.6.0
  Release ：https://github.com/unixwin/niubash/releases/tag/v1.6.0
是否更新 niubash 到 1.6.0？ [yes/no]
```

回答 `yes` 后，脚本在原文件上**精确替换** `version`、各架构的 `url`、`hash`、`extract_dir`，不重排、不重新格式化。写入前会重新解析 JSON 自检，自检不通过就放弃该文件、保持原样。哈希优先取 Release API 的 asset digest，上游没有 digest 时才下载资产本地计算。

| 参数 | 作用 |
| --- | --- |
| `-CheckOnly` | 只提示是否有新版本，不改动任何文件 |
| `-Yes` | 不询问，直接更新所有有新版本的软件 |
| `-BucketPath` | 清单目录，默认 `bucket` |
| `-LogPath` | 日志路径，默认仓库根目录的 `update-log.txt` |
| `-Token` | GitHub 令牌，默认读环境变量 `GITHUB_TOKEN`，一般不需要 |

每次实际更新都会把改动追加写入 `update-log.txt`：时间、版本变化、Release 链接，以及每个架构 `url` / `hash` / `extract_dir` 的旧值和新值。该文件已在 `.gitignore` 中忽略，不会上传。

脚本只处理带 `checkver.github` 或 GitHub `homepage` 的清单，其他清单标记为「跳过」。查询失败（断网、超时、限流）只影响对应清单，不中断其余检查。

**API 限流**：GitHub 对未登录请求限制为每小时 60 次，超出返回 `403 rate limit exceeded`。脚本会自动改用网页查询（`releases/latest` 的跳转地址，再退回 `releases.atom`），此时哈希靠下载资产本地计算，慢一些但不需要凭据。想固定走 API 可以设置令牌：

```powershell
$env:GITHUB_TOKEN = 'ghp_xxxxxxxx'   # 细粒度令牌，不需要任何权限即可读公开仓库
```

> 本机 SSH key 只用于 `git clone` / `git push`，对 `api.github.com` 和网页查询无效，脚本也不需要它。

---

## 使用说明

### 1. 上传到自己的 GitHub

推荐创建一个空的公开仓库，例如 `scoop-bucket`。创建时**不要**勾选自动生成 README、.gitignore 或 License，避免首次推送冲突。在本项目目录执行：

```powershell
git init
git add .
git commit -m "Initialize personal Scoop bucket"
git branch -M main
git remote add origin git@github.com:YOUR_GITHUB_NAME/scoop-bucket.git
git push -u origin main
```

`YOUR_GITHUB_NAME` 换成自己的用户名。用 SSH 地址可以免去每次输入密码；没有配置 SSH 就改用 `https://github.com/...`，首次推送按提示登录。已有 Git 仓库或 origin 时沿用现有设置，跳过对应步骤。

也可以直接通过 GitHub 网页上传全部文件，注意要包含 `.github` 等隐藏目录。

### 2. 订阅自己的源

需要电脑已装 Scoop 和 Git，未安装见 https://scoop.sh/ 。

```powershell
scoop bucket add my https://github.com/YOUR_GITHUB_NAME/scoop-bucket.git
scoop bucket list
```

`my` 是这台电脑上的别名，可改成自己喜欢的名字，之后安装用 `scoop install my/<清单名>`。其他电脑运行同样的命令即可订阅同一个源。

### 3. 添加软件

**推荐：用脚本生成**

```powershell
pwsh -NoProfile -File .\scripts\new-manifest.ps1 https://github.com/owner/repo
```

**手工：从模板改**

```powershell
Copy-Item .\templates\portable.json .\bucket\my-app.json
notepad .\bucket\my-app.json
```

模板字段含义：

| 字段 | 填写内容 |
| --- | --- |
| `version` | 实际版本，例如 `1.2.3` |
| `description` | 软件介绍 |
| `homepage` | 软件官网 |
| `license` | 真实许可证，例如 `MIT`；专有软件核实后填 `Proprietary` |
| `url` | 对应版本的安装包直链，不能是下载介绍页面 |
| `hash` | 下载文件的真实 SHA256 |
| `bin` | 解压后要加入命令行的程序路径；不需要命令行入口时可删除 |
| `shortcuts` | 开始菜单快捷方式，程序路径与显示名称都要改；不需要可删除 |

把所有 `REPLACE_ME` 和示例路径替换掉。JSON 不支持注释，最后一个字段后面不要加逗号。

自己算 SHA256（把网址换成真实直链）：

```powershell
$downloadUrl = 'https://example.com/app-1.2.3-win64.zip'
$packagePath = Join-Path $env:TEMP 'my-app-1.2.3.zip'
Invoke-WebRequest -Uri $downloadUrl -OutFile $packagePath
(Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
```

优先使用固定版本下载地址，避免上游替换文件后校验失败。

ZIP 解压后还有一层目录（例如 `MyApp-1.2.3/app.exe`）时，加：

```json
"extract_dir": "MyApp-1.2.3"
```

此时 `bin` 和 `shortcuts` 的路径相对于该目录，写 `app.exe`。数据要跨升级保留时，按软件实际目录加 `"persist": ["data"]`，不要填不存在的数据目录。

模板只适合便携版 ZIP。安装器 EXE、MSI、需要注册表或服务的软件要按其安装行为单独编写，不能只替换下载地址。

### 4. 本地测试并提交

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
scoop install .\bucket\my-app.json
```

确认软件能启动、命令或快捷方式正常后再提交；已装过的先看 `scoop list`。

```powershell
git add bucket README.md
git commit -m "Add my-app"
git push
```

推送后 GitHub Actions 会跑校验。**别忘了在 [已收录软件](#已收录软件) 里补一节使用说明。**

### 5. 升级软件

```powershell
pwsh -NoProfile -File .\scripts\check-updates.ps1   # 改清单
git add bucket && git commit -m "update manifests" && git push
```

订阅端：

```powershell
scoop update          # 同步 bucket
scoop update niubash  # 升级已安装的软件
```

想接入 Scoop 原生的 `autoupdate`（无需手动跑脚本），需要软件发布方提供稳定的资产命名和独立的 `.sha256` 校验文件。

---
## 已收录软件

| 清单 | 软件 | 版本 | 架构 | 说明 |
| --- | --- | --- | --- | --- |
| [`bucket/cloudy.json`](bucket/cloudy.json) | [cloudy](https://github.com/nya-owo/cloudy) | 1.3.2 | 64bit / arm64 | 网易云音乐第三方客户端，Go 原生界面，自带应用内更新 |
| [`bucket/niubash.json`](bucket/niubash.json) | [niubash](https://github.com/unixwin/niubash) | 1.5.0 | 64bit / arm64 | 原生 Windows Bash 兼容 shell，命令名 `niu` |

### niubash

[niubash](https://github.com/unixwin/niubash) 是原生实现的 Windows Bash 兼容 shell（Git Bash 替代品），单文件 `niu.exe`，内置 Unix 命令和 git。

**安装**

```powershell
scoop update
scoop install my/niubash
niu --version
```

**使用**

装好后直接在终端里运行 `niu`，或从开始菜单打开「Niubash」：

```powershell
niu                      # 进入 niubash 的交互 shell
niu -c "ls -la"          # 执行单条命令
```

`niu` 启动时会带上自己的 `winuxcmd` 运行环境，`ls`、`grep`、`git` 等命令在里面都能用，不需要额外装 Git Bash。

**注意事项**

- 清单只把包内的 `niu.exe` 加入 PATH，命令名为 `niu`；`winuxcmd` 里的 176 个 Unix 命令**没有**加入 PATH，避免和 Git Bash、MSYS2 的命令互相覆盖。需要单独调用时用安装目录下的 `winuxcmd\usr\bin\winuxcmd.exe`。
- 上游未做代码签名，首次运行 SmartScreen 可能报警（上游 issue #511），选择「仍要运行」即可。
- 安装不需要管理员权限，也不会改动系统 PATH 之外的设置。

**升级**

```powershell
scoop update
scoop update niubash
```

上游只为安装器 `setup.exe` 提供 `.sha256` 文件，tar.gz 没有独立校验文件，因此清单没有配置 `autoupdate`，需手动或跑 `scripts/check-updates.ps1` 升级。手工改的话要保持一致的有四处：`version`、两个架构的 `url`、两个 `extract_dir`（`niubash-v<版本>-win-x64` / `-win-arm64`）、两个 `hash`。

**为什么用 tar.gz**

清单选用上游的 `win-x64.tar.gz` / `win-arm64.tar.gz`：这两种包在解压时会还原 git、awk 载荷的硬链接，体积最小（x64 约 31 MB，zip 版 57 MB）。压缩包内有一层带版本号的目录，所以用 `extract_dir` 指定它，`bin` 才能找到根目录下的 `niu.exe`。

### cloudy

[Cloudy](https://github.com/nya-owo/cloudy)（旧名 Cloud-nya）是第三方网易云音乐桌面客户端，用 Go 和 MyGo 写原生界面，不套 WebView，启动快、占用小。

**安装**

```powershell
scoop update
scoop install my/cloudy
```

装完从开始菜单打开「Cloudy」，或在终端运行 `cloudy`。

**使用**

- 登录：打开客户端扫码登录网易云账号，登录状态保存在系统凭据里。
- 命令行：清单把 `Cloudy.exe` 加入 PATH，命令名 `cloudy`。它是 GUI 程序，在终端运行不会输出内容，只是把窗口叫起来。
- 本地音乐：设置 → 下载与缓存 → 本地音乐，添加存放 MP3 / FLAC 的文件夹；也可以把文件或文件夹直接拖进窗口。

**注意事项**

- 上游未做代码签名，首次运行 SmartScreen 会提示，选「更多信息 → 仍要运行」。
- **自带应用内更新**：Cloudy 会自己检查 GitHub（连不上时切镜像）并静默替换文件，绕过 Scoop 的版本记录。装了 Scoop 版建议在设置里关掉自动更新，统一用 `scoop update cloudy` 升级，否则 `scoop list` 显示的版本会和实际文件对不上。
- 只有 Windows 版本，分 x64 和 ARM64 两种；ARM64 设备会装 `arm64` 那个包。
- 登录状态、缓存和听歌数据在 `%APPDATA%` 下，`scoop uninstall` 不会删除。

**升级**

```powershell
scoop update
scoop update cloudy
```

清单没有配 `autoupdate`，和 niubash 一样靠 `scripts/check-updates.ps1`。上游资产名稳定（`cloudy-<版本>-windows-amd64.tar.gz`），但发布里没有独立的校验文件，脚本遇到这种清单会下载资产自己算哈希。

**为什么用 tar.gz**

发布里的 `cloudy-<版本>-windows-<架构>.tar.gz` 是 MyGo 的更新包，内容是「装好之后的文件」，平铺在压缩包根目录（`Cloudy.exe` 加资源目录），解压即可运行，所以清单不需要 `extract_dir`，`bin` 直接写 `Cloudy.exe`。安装器 `cloudy-setup-*.exe` 会装到 `%LOCALAPPDATA%\Programs` 并写注册表，不适合交给 Scoop 管理。

新增软件时照这个结构补一节（复制后改内容即可）：

````markdown
### 软件名

一句话介绍。

**安装**

```powershell
scoop install my/软件名
```

**使用**

```powershell
命令或入口说明
```

**注意事项**

- PATH、签名、依赖、已知问题
````

---

## 官方参考

- Scoop：https://scoop.sh/
- 软件清单说明：https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests
- 自建 Bucket：https://github.com/ScoopInstaller/Scoop/wiki/Buckets
- 自动更新配置：https://github.com/ScoopInstaller/Scoop/wiki/Autoupdate
