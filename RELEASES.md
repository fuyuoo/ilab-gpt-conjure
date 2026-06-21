# 下载 / Releases

当前正式版本：[v0.5.2](https://github.com/kadevin/ilab-gpt-conjure/releases/tag/v0.5.2)

## 版本说明

当前版本：`v0.5.2`。这个版本提供 Windows x64、macOS Apple Silicon、macOS Intel 三种免安装一键包；下载对应平台的 zip 后解压即可启动本地 WebUI，并可手动运行包内更新脚本升级到后续版本。

本版重点：这一版在系统设置、API 供应商管理、语言设置和输入图片编辑器升级的基础上，补齐输入图编辑画布范围、任务状态同步和公用图库窄卡片操作区溢出修复；同时继续保持免安装一键包启动路径本地化，更新路径由用户手动触发并校验 SHA256，降低脚本被安全软件误报的概率。

本版详情：

- 系统设置整合：右上角 API 设置入口和输出设置里的系统设置入口统一打开同一个居中系统设置窗口；`API 设置` 默认第一位，`Codex 通道` 独立第二位，`语言 / Language` 独立第三位，`存储与通知` 第四位，左下角独立存储设置入口已移除。
- API 供应商管理：供应商以卡片快速选择，并显示已保存供应商数量；进入设置时默认只展示当前供应商只读详情，不会自动进入编辑状态，降低误改 Base URL、Key 或模型名的风险。
- 显式编辑工作流：编辑、新建和复制都会进入独立草稿编辑区；“保存供应商”只保存当前草稿，“保存当前选择”只同步当前选中的供应商和系统设置，避免把全局保存按钮误当作编辑保存。
- 复制、删除和排序：复制供应商会沿用已保存 API Key 的本地后端引用，但界面仍只显示掩码，适合同一个供应商维护多个模型映射；删除供应商需要二次确认；供应商多于 1 个时可进入排序模式并用上移/下移调整顺序。
- Codex 通道独立：Codex `Image` / `Responses` 切换从 API 设置里拆出，保留默认 `Image` 通道和 Responses 兼容通道；联网搜索仍只在 Responses 通道生效。
- 存储与通知：输入目录、输出目录、公用图库目录、源数据目录、站内通知和系统通知收在 `存储与通知` Tab；保存后需要重启 WebUI 的目录设置继续保持明确提示。
- 多图层输入编辑器：编辑输入图片时可插入输入框里的其他图片，进行多图组合、选择移动、缩放旋转和局部擦除；图片变换默认锁定长宽比例，按住 Shift 可自由变换；图层列表显示真实缩略图而不是数字占位。
- 编辑画布范围：输入图片编辑器新增画布范围选择，可继续按首张参考图尺寸编辑，也可切换为自动适应全部图层范围，方便把多张插入图片组合保存成一张更大的输入图。
- 公用图库溢出修复：合入 PR #3 的窄宽度卡片修复，图库卡片、标题、说明和操作按钮都允许收缩并使用省略显示，极窄容器下操作按钮自动变为单列，避免抽屉变窄时按钮挤出卡片。
- 任务状态同步：修复已生成结果但左侧任务列表仍显示“生成中”的状态不同步问题，任务状态、输出槽位和历史详情以真实可显示结果为准更新。
- 前端依赖与源码复构：图层编辑器使用 Konva，`package-lock.json` 锁定对应 npm 依赖；一键包启动时不安装 Node，也不重建前端资源，但 portable 包会包含 `package.json`、`package-lock.json`、`tsconfig.webui.json` 和 CSS 构建脚本，便于需要时从源码复构静态资源。
- 一键包启动器降误报：portable 启动脚本只启动本地 WebUI，不再在启动路径访问 GitHub、检查 Release 或写自动更新提示；Windows 启动健康检查改用包内 Python，减少对 PowerShell 的依赖。
- 手动更新器透明化：portable 更新器仍需用户手动运行；运行时显示匹配的 Release 资产、下载地址和 SHA256 文件，校验 SHA256，保留本地 `data/`，只替换一键包目录内由程序管理的文件，并把被替换文件备份到 `.backup/`。Windows 更新入口不再使用 `ExecutionPolicy Bypass`。
- 文档与安全说明：公开 README、英文 README、RELEASES、SECURITY 和三平台 portable README 同步更新多图层编辑器、前端依赖边界、启动脚本本地化、手动更新、SHA256 校验、未签名 macOS 包和本地数据边界。
- 静态资源与前端合同：前端资源版本提升到 `runtime-368`；静态测试锁定系统设置 Tab、语言下拉菜单、API 供应商卡片、复制/删除/排序、Codex 通道隔离、编辑画布范围、图层缩略图、图库卡片窄宽度按钮溢出修复、portable 打包文档和公开导出说明，降低后续回归风险。

## 免安装一键包

| 平台 | 适用设备 | 下载 | SHA256 |
| --- | --- | --- | --- |
| Windows x64 | Windows 10/11 x64 | [ilab-gpt-conjure_windows_portable_x64_0.5.2.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.2/ilab-gpt-conjure_windows_portable_x64_0.5.2.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.2/ilab-gpt-conjure_windows_portable_x64_0.5.2.zip.sha256.txt) |
| macOS Apple Silicon | M1/M2/M3/M4 | [ilab-gpt-conjure_macos_portable_arm64_0.5.2.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.2/ilab-gpt-conjure_macos_portable_arm64_0.5.2.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.2/ilab-gpt-conjure_macos_portable_arm64_0.5.2.zip.sha256.txt) |
| macOS Intel | Intel x64 | [ilab-gpt-conjure_macos_portable_x64_0.5.2.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.2/ilab-gpt-conjure_macos_portable_x64_0.5.2.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.2/ilab-gpt-conjure_macos_portable_x64_0.5.2.zip.sha256.txt) |

使用方式：

1. 下载对应平台的 zip。
2. 解压到普通用户目录，不要放在系统保护目录。
3. Windows 双击 `Start WebUI Portable.bat`；macOS 双击
   `Start WebUI Portable.command`。
4. 如果浏览器没有自动打开，访问 `http://127.0.0.1:8787/`。

更新已经解压的一键包时，先关闭 WebUI 服务窗口，然后运行 Windows 的
`Update WebUI Portable.bat` 或 macOS 的 `Update WebUI Portable.command`。
启动脚本不会访问 GitHub，也不会自动更新文件。更新脚本会下载当前平台对应的最新
GitHub Release 资产，执行前显示所选资产和 SHA256 文件，校验 SHA256，只替换一键包目录内由程序管理的文件，保留本地 `data/`，并把被替换文件备份到 `.backup/`。

macOS 包是未签名的 portable zip，不是已签名 `.app` 或 notarized DMG。
启动脚本会尝试在启动前移除当前解压目录内的 quarantine 标记。如果 macOS
仍然拦截启动脚本，可以右键或 Control-click `Start WebUI Portable.command`，
选择 Open，并在系统安全提示中再次确认。也可以对解压目录执行：

```bash
xattr -dr com.apple.quarantine /path/to/ilab-gpt-conjure_macos_portable_arm64
# 或：
xattr -dr com.apple.quarantine /path/to/ilab-gpt-conjure_macos_portable_x64
```

一键包内的 `data/` 目录会保存本地设置、公用图库、输入图、输出图、任务数据库和日志。
不要把这些本地数据、API key 或 OAuth 文件提交到 Git。
