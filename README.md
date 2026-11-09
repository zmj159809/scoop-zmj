# 我的 Scoop Bucket

这是一个用于自己维护 Windows 软件的 Scoop 软件源。把这个仓库上传到 GitHub 后，就可以通过 `scoop bucket add` 订阅，再逐步添加自己的软件。

仓库初始为空，模板不属于可安装软件。无需部署网站，也无需启用 GitHub Pages。

## 1. 上传到自己的 GitHub

推荐创建一个公开仓库，例如 `scoop-bucket`。公开仓库订阅最方便；私有仓库需要先配置本机 Git 的 GitHub 身份验证。

创建仓库时不要勾选自动生成 README、.gitignore 或 License，避免首次推送产生冲突。在本项目目录打开 PowerShell，依次执行：

```powershell
cd D:\project\tools\scoopRepo
git init
git add .
git commit -m "Initialize personal Scoop bucket"
git branch -M main
git remote add origin https://github.com/YOUR_GITHUB_NAME/scoop-bucket.git
git push -u origin main
```

请将 `YOUR_GITHUB_NAME` 和 `scoop-bucket` 换成自己的 GitHub 用户名与仓库名。如果 Git 要求用户名或邮箱，按提示配置后重新提交。如果本来就有 Git 仓库或 origin，请沿用现有设置，跳过对应的初始化或添加远程步骤。

也可以通过 GitHub 网页上传本项目全部文件，记得包含 `.github` 等隐藏目录。网页上传时若空文件未被保留，添加第一个软件清单后 `bucket` 目录就会存在。

## 2. 订阅自己的源

以下命令需要电脑已安装 Scoop 和 Git。如果尚未安装 Scoop，请参考官方安装说明：https://scoop.sh/ 。

```powershell
scoop bucket add my https://github.com/YOUR_GITHUB_NAME/scoop-bucket.git
scoop bucket list
```

`my` 是这台电脑上软件源的别名，可改成自己喜欢的名字。以后安装软件时使用这个别名：

```powershell
# 添加并推送 my-app.json 后才可以执行
scoop install my/my-app
```

在其他电脑上运行相同的 `scoop bucket add` 命令，即可订阅同一个源。仓库应保留 `bucket` 目录在根目录下。

## 3. 添加第一个软件

先选择提供 Windows 便携版 ZIP 的软件，这类软件最容易制作清单。

在本项目目录执行：

```powershell
Copy-Item .\templates\portable.json .\bucket\my-app.json
notepad .\bucket\my-app.json
```

文件名就是安装时使用的软件名，例如 `my-app.json` 对应 `scoop install my/my-app`。建议只用小写字母、数字、短横线。

模板字段含义：

| 字段 | 填写内容 |
| --- | --- |
| `version` | 实际版本，例如 `1.2.3` |
| `description` | 软件介绍 |
| `homepage` | 软件官网 |
| `license` | 真实许可证，例如 `MIT`；专有软件核实后填写 `Proprietary` |
| `url` | 对应版本的安装包直链，不能是下载介绍页面 |
| `hash` | 下载文件的真实 SHA256 值 |
| `bin` | 解压后要加入命令行的软件路径；不需要命令行入口时可删除此字段 |
| `shortcuts` | 开始菜单快捷方式，内部的程序路径与显示名称均需按软件修改；不需要可删除 |

将所有 `REPLACE_ME` 和示例路径替换掉。JSON 不支持注释，最后一个字段后面不要加逗号。

下载并计算 SHA256 的例子（将网址替换成真实直链）：

```powershell
$downloadUrl = 'https://example.com/app-1.2.3-win64.zip'
$packagePath = Join-Path $env:TEMP 'my-app-1.2.3.zip'
Invoke-WebRequest -Uri $downloadUrl -OutFile $packagePath
(Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
```

复制输出的 64 位哈希值到 `hash`。优先使用固定版本下载地址，避免上游替换文件后校验失败。

如果 ZIP 解压后还有一层目录，例如 `MyApp-1.2.3/app.exe`，在清单中增加：

```json
"extract_dir": "MyApp-1.2.3"
```

此时 `bin` 和 `shortcuts` 中的路径相对于该目录填写，例如 `app.exe`。数据需要跨升级保留时，可按软件实际目录添加 `"persist": ["data"]`，不要随意填写不存在的数据目录。

此模板适合便携版 ZIP。安装器 EXE、MSI、需要注册表或服务的软件需要按其安装行为单独编写清单；不能只替换下载地址。

## 4. 校验并测试安装

基础校验使用 PowerShell 7，在本项目目录运行：

```powershell
pwsh -NoProfile -File .\scripts\validate.ps1
```

它检查必要字段、JSON 格式、模板占位符、下载 URL 与 SHA256 格式，也支持 `architecture` 下的 `32bit`、`64bit` 和 `arm64` 下载项。它不下载软件、不核对远程文件哈希、不验证所有 Scoop 字段，也不能代替实际安装测试。

在提交之前，用本地清单测试：

```powershell
scoop install .\bucket\my-app.json
```

确认软件可以启动、命令或快捷方式正常后，再提交。软件已经安装时，请先查看 `scoop list`，按需要选择自己的测试方式。

```powershell
git add bucket
git commit -m "Add my-app"
git push
```

GitHub 仓库的 Actions 页面会显示基础校验结果。当前只配置校验，不会自动修改版本或推送提交。

## 5. 后续更新

有新版本时，修改清单的 `version`、`url` 和 `hash`，安装测试后提交并推送；其他版本相关字段（如 `extract_dir`）也要一起修改。订阅端执行：

```powershell
scoop update
scoop update my-app
```

第一条命令同步 Scoop 和已订阅 bucket，第二条升级已安装的软件。若需要以后再接入自动检查与更新，可参考 Scoop 的 `checkver` 和 `autoupdate` 文档，按每个软件真实的发布方式配置。

## 目录说明

```text
bucket/                         正式软件清单，每个软件一个 JSON
  .gitkeep                      保留初始空目录
 templates/portable.json        便携版 ZIP 模板（不会被 Scoop 当成软件）
scripts/validate.ps1            本地及 CI 基础校验
.github/workflows/validate.yml  GitHub Actions 校验流程
```

## 官方参考

- Scoop：https://scoop.sh/
- 软件清单说明：https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests
- 自建 Bucket：https://github.com/ScoopInstaller/Scoop/wiki/Buckets
- 自动更新配置：https://github.com/ScoopInstaller/Scoop/wiki/Autoupdate
