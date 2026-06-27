# 下载 / Releases

当前正式版本：[v0.5.3](https://github.com/kadevin/ilab-gpt-conjure/releases/tag/v0.5.3)

## 版本说明

当前版本：`v0.5.3`。这个版本提供 Windows x64、macOS Apple Silicon、macOS Intel 三种免安装一键包；下载对应平台的 zip 后解压即可启动本地 WebUI，并可手动运行包内更新脚本升级到后续版本。

本版重点：这是一个偏修复的小版本，重点解决图片输入格式兼容和任务列表尺寸显示不准确的问题。WebUI 现在会在发送参考图前规范化不被生成接口直接支持的图片格式，减少 MPO、HEIC 等输入图导致的请求失败；同时修复 OpenAI-compatible Images 返回结果把字节数误当作 `size` 时，任务槽显示 `952614`、`388070` 这类数字而不是图片尺寸的问题。

本版详情：

- 输入图格式兼容：参考图发送前会检测真实图片格式；PNG、JPEG、WebP、非动画 GIF 继续按原格式发送，不支持的可解码图片会自动取首帧并转为 PNG。
- 错误处理更明确：无法解码的图片会返回 `Unsupported image type: could not decode image`，避免坏文件进入生成请求后才失败。
- 任务槽尺寸显示修复：生成结果会优先从输出图片本身读取真实像素尺寸，例如 `1024x1536`；不再把 API 返回的字节数当成尺寸展示。
- 旧任务兼容：历史 metadata 中已有的纯数字 `output_size` / `outputs[].size` 会被过滤；读不到真实输出尺寸时回退到请求参数里的合法尺寸。
- 测试覆盖：新增和补充输入图、客户端解析、任务 API 单测，覆盖 MPO 转 PNG、声明类型错误但内容为 JPEG、坏图拒绝、数字 size 过滤和尺寸回退等场景。
- 社区贡献：合入 RobinZhiBin 的 PR #5：`fix(webui): normalize unsupported image input formats`。

## 免安装一键包

| 平台 | 适用设备 | 下载 | SHA256 |
| --- | --- | --- | --- |
| Windows x64 | Windows 10/11 x64 | [ilab-gpt-conjure_windows_portable_x64_0.5.3.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.3/ilab-gpt-conjure_windows_portable_x64_0.5.3.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.3/ilab-gpt-conjure_windows_portable_x64_0.5.3.zip.sha256.txt) |
| macOS Apple Silicon | M1/M2/M3/M4 | [ilab-gpt-conjure_macos_portable_arm64_0.5.3.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.3/ilab-gpt-conjure_macos_portable_arm64_0.5.3.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.3/ilab-gpt-conjure_macos_portable_arm64_0.5.3.zip.sha256.txt) |
| macOS Intel | Intel x64 | [ilab-gpt-conjure_macos_portable_x64_0.5.3.zip](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.3/ilab-gpt-conjure_macos_portable_x64_0.5.3.zip) | [sha256](https://github.com/kadevin/ilab-gpt-conjure/releases/download/v0.5.3/ilab-gpt-conjure_macos_portable_x64_0.5.3.zip.sha256.txt) |

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
