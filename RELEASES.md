# 下载 / Releases

当前正式版本：[v0.5.5](https://github.com/kadevin/ilab-gpt-conjure/releases/tag/v0.5.5)

## 版本说明

当前版本：`v0.5.5`。这个版本是启动器、标准应用包、自动更新和迁移过渡版本。新用户建议下载标准包：macOS 使用 DMG，Windows 使用独立 App ZIP；老用户和调试用户仍可下载 portable zip 继续沿用同目录 `data/` 工作流。

本版重点：0.5.5 新增小兔子 Rust 托盘 / 菜单栏启动器、macOS 标准 `.app` + DMG、Windows 标准 App ZIP、标准包数据目录、旧 portable 数据确认复制迁移，以及 portable-only signed `latest.json` 自动更新。同时补齐系统设置实时保存、任务卡信息重排、Codex Image / Codex Responses 命名、生成页历史搜索和批量管理滚动稳定性。标准包在本版只提供检查更新并打开 Release 页面，不做未签名 `.app` / Windows ZIP 的自替换。

本版详情：

### 升级必读

- `v0.5.4` 及更早 portable 用户首次升级到 `0.5.5` 时，建议手动下载完整标准包或完整 portable 包；旧 updater 只保证升级 WebUI/依赖，不保证安装新的小兔子启动器、标准 `.app` / `.exe` 入口和迁移助手。
- 新用户建议优先下载标准包。标准包把用户数据写入系统应用数据目录；portable 包继续把数据写在同级 `data/`，用于老用户过渡、调试和临时工作流。
- 标准包检查更新在 0.5.5 只打开 GitHub Release 页面；未签名 `.app` 和 Windows ZIP 的自替换更新器延后，避免扩大文件替换风险。
- 0.5.5 的 macOS 标准 DMG 和 portable zip 都暂未签名、未 notarize，首次启动可能需要右键或 Control-click 选择 Open。

### 标准应用包

- 新增标准 macOS 应用包：`iLab GPT CONJURE.app` 把程序资源封装进 `.app/Contents/Resources/`，用户数据默认写入 `~/Library/Application Support/iLab GPT CONJURE/`。
- 新增 macOS DMG：Apple Silicon 和 Intel 分别提供独立 DMG，DMG 内包含 `.app` 和 Applications 快捷方式。
- 新增 Windows 标准 App ZIP：根目录只保留用户入口 `iLab GPT CONJURE.exe`、README、许可证和内置 `resources/`，用户数据默认写入 `%APPDATA%\iLab GPT CONJURE\`。
- 标准包首次启动会检测相邻旧 portable `data/`，也可以选择旧版本目录；迁移必须用户确认，默认复制不移动；目标标准数据目录已有 WebUI 数据时不自动覆盖；成功后写 marker 避免重复提示。

### 小兔子启动器

- 新增 Rust 托盘 / 菜单栏启动器：启动后不再需要独立终端窗口，会自动启动本地 WebUI、打开系统默认浏览器，并在 Windows 右下角或 macOS 右上角保留小兔子图标。
- 托盘 / 菜单栏菜单支持打开 WebUI、打开系统设置、打开历史库、检查更新、关于版本、重启服务和退出。
- 菜单文案会跟随 WebUI 语言设置或系统语言；“关于版本”使用系统原生窗口，显示版本、开源地址和检查更新按钮。
- 程序图标、托盘 / 菜单栏图标和 WebUI 左上角品牌统一为可识别的小兔子视觉。

### portable 过渡包与自动更新

- 继续保留三种 portable zip：Windows x64、macOS Apple Silicon、macOS Intel；portable 数据仍保存在包内同级 `data/`。
- portable 包包含 `Start iLab GPT CONJURE.exe` / `Start iLab GPT CONJURE.app` 启动器，旧的 `Start WebUI Portable` 脚本继续保留作为终端调试入口。
- portable 自动更新使用 signed `latest.json` manifest、Ed25519 签名校验、SHA256 校验、`.backup/` 备份和更新后重启；`latest.json` 只声明 portable 三平台 zip，不作为标准包自替换更新 manifest。
- 更新器只替换一键包目录内由程序管理的文件，保留本地 `data/`，并在执行前显示所选资产和 manifest SHA256。

### WebUI 与交互改进

- 系统设置调整为实时保存：API 供应商选择、Codex 通道和语言切换会即时生效，界面不再保留容易误解的“保存当前选择 / 保存 Codex 通道”按钮；只有供应商编辑草稿和存储路径仍需要明确保存。
- 任务卡信息重排：状态、耗时、尺寸、供应商 / 通道和完成时间分层显示，失败任务不再用长错误文本挤占摘要，运行中和已完成任务更容易快速扫描。
- Codex 通道命名改为 `Codex Image` 与 `Codex Responses`，任务卡片也区分 `Codex Image`、`Codex Responses`、`API Image` 和 `API Responses`，避免把 Responses 误认为只有 Codex 通道。
- 复用历史任务只恢复提示词、尺寸、质量、数量等生成参数，不再把旧任务的 API 供应商、API 调用方式或 Codex 通道覆盖到当前全局设置；下一次新生成始终使用右上角当前选择的供应商 / 通道。
- 生成页搜索会使用历史库全文索引补充历史任务命中结果，不再因为卡片摘要被截断而漏掉完整历史里能搜到的任务。
- 批量管理点击选择任务改为局部更新选中态和工具条，不再重绘整条任务列表，避免长列表滚动位置跳到顶部。
- `0.5.4` 用户通过 portable 更新到 `0.5.5` 后，会弹出标准包过渡说明，提示标准 App、portable 数据目录和迁移助手的区别。

### 发布工作流

- Release workflow 同时构建并上传 macOS Apple Silicon DMG、macOS Intel DMG、Windows 标准 App ZIP、Windows x64 portable、macOS Apple Silicon portable、macOS Intel portable、所有 `.sha256.txt` 和 portable 用 `latest.json`。
- `latest.json` 仅服务 portable 自动更新；标准包下载信息放在 Release 正文和 README 中。

## 推荐下载

| 平台 | 推荐给 | 下载 | SHA256 |
| --- | --- | --- | --- |
| macOS Apple Silicon | 新用户，M1/M2/M3/M4 | [iLab-GPT-CONJURE-macos-arm64-0.5.5.dmg](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/iLab-GPT-CONJURE-macos-arm64-0.5.5.dmg) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/iLab-GPT-CONJURE-macos-arm64-0.5.5.dmg.sha256.txt) |
| macOS Intel | 新用户，Intel x64 | [iLab-GPT-CONJURE-macos-x64-0.5.5.dmg](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/iLab-GPT-CONJURE-macos-x64-0.5.5.dmg) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/iLab-GPT-CONJURE-macos-x64-0.5.5.dmg.sha256.txt) |
| Windows x64 | 新用户，Windows 10/11 x64 | [iLab-GPT-CONJURE-windows-x64_0.5.5.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/iLab-GPT-CONJURE-windows-x64_0.5.5.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/iLab-GPT-CONJURE-windows-x64_0.5.5.zip.sha256.txt) |

标准包数据目录：

- macOS：`~/Library/Application Support/iLab GPT CONJURE/`
- Windows：`%APPDATA%\iLab GPT CONJURE\`

标准包的“检查更新”会打开 Release 页面。0.5.5 不对标准 `.app` 或 Windows 标准 ZIP 执行自动自替换。

## 免安装一键包

| 平台 | 适用设备 | 下载 | SHA256 |
| --- | --- | --- | --- |
| Windows x64 | Windows 10/11 x64 | [ilab-gpt-conjure_windows_portable_x64_0.5.5.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/ilab-gpt-conjure_windows_portable_x64_0.5.5.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/ilab-gpt-conjure_windows_portable_x64_0.5.5.zip.sha256.txt) |
| macOS Apple Silicon | M1/M2/M3/M4 | [ilab-gpt-conjure_macos_portable_arm64_0.5.5.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/ilab-gpt-conjure_macos_portable_arm64_0.5.5.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/ilab-gpt-conjure_macos_portable_arm64_0.5.5.zip.sha256.txt) |
| macOS Intel | Intel x64 | [ilab-gpt-conjure_macos_portable_x64_0.5.5.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/ilab-gpt-conjure_macos_portable_x64_0.5.5.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/ilab-gpt-conjure_macos_portable_x64_0.5.5.zip.sha256.txt) |

portable 自动更新 manifest：

- [latest.json](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.5/latest.json)

使用方式：

1. 下载对应平台的 zip。
2. 解压到普通用户目录，不要放在系统保护目录。
3. Windows 双击 `Start iLab GPT CONJURE.exe`；macOS 双击
   `Start iLab GPT CONJURE.app`。旧的 `Start WebUI Portable.bat` /
   `Start WebUI Portable.command` 仍保留，用于终端调试。
4. 如果浏览器没有自动打开，访问 `http://127.0.0.1:8787/`。

一键包启动器不会后台自动访问 GitHub。更新已经解压的一键包时，可在托盘 / 菜单栏
菜单选择检查更新，并在发现新版本后确认 `安装更新`；也可以退出启动器后手动运行
Windows 的 `Update WebUI Portable.bat` 或 macOS 的 `Update WebUI Portable.command`。
更新脚本会读取带签名的 `latest.json`
manifest，先用启动器内置公钥校验 Ed25519 签名，再下载当前平台对应的最新
GitHub Release 资产，执行前显示所选资产和 manifest SHA256，校验下载 zip 的
SHA256，只替换一键包目录内由程序管理的文件，保留本地 `data/`，并把被替换文件备份到 `.backup/`。

0.5.5 的 macOS 标准 DMG 和 portable zip 都暂未签名、未 notarize。如果 macOS
拦截启动，可以右键或 Control-click App，选择 Open，并在系统安全提示中再次确认。
portable zip 也可以对解压目录执行：

```bash
xattr -dr com.apple.quarantine /path/to/ilab-gpt-conjure_macos_portable_arm64
# 或：
xattr -dr com.apple.quarantine /path/to/ilab-gpt-conjure_macos_portable_x64
```

一键包内的 `data/` 目录会保存本地设置、公用图库、输入图、输出图、任务数据库和日志。
不要把这些本地数据、API key 或 OAuth 文件提交到 Git。
