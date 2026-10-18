# Flutter 公开视频下载器

这是 Flutter 跨平台工程。Windows 版在本机运行随应用提供的 `yt-dlp.exe` 和 FFmpeg；Android/iOS 版通过 `mobile_server/` 下载服务完成解析、下载和手机保存。Windows 运行库只进入 Windows 发布包，不会进入移动端 APK/IPA。

## 功能

- 粘贴 B 站、抖音等公开页面链接
- 支持直接粘贴整段分享文案，即使链接前面有文字或缺少 `https://`
- 解析标题、作者、时长和可用画质
- 选择保存目录
- 高画质视频和音频自动合并
- 下载进度、速度、日志和取消
- 可选读取本机 Chrome、Edge 或 Firefox 的浏览器会话，用于抖音需要新鲜 Cookie 的链接
- Android/iOS 共用 Flutter 界面，下载完成后调起系统分享/保存面板
- Windows 同时提供高画质合并模式和单文件兼容模式
- 微信视频号标记为实验性：当前 yt-dlp 没有稳定的视频号专用解析器，公开分享链接可能无法解析

只处理公开且用户有权保存的内容。视频号、需要登录、付费、DRM、验证码或平台安全限制的链接，取决于平台当前允许的公开访问能力。

抖音目前经常要求新鲜浏览器会话。使用时先在浏览器中打开目标视频，确认页面可以正常播放，然后完全关闭浏览器（包括后台进程），在应用中选择对应浏览器后再解析。应用只在用户主动选择时读取本机浏览器会话，不上传 Cookie。

Windows 下载画质中，带“音视频合并”的选项会使用应用内置 FFmpeg；“兼容模式：最佳单文件”直接选择平台提供的单文件视频，不需要 FFmpeg，适合遇到合并失败或只需要普通 MP4 的情况。

## Android 和 iOS

移动系统不能直接执行 Windows 的 `yt-dlp.exe` 和 FFmpeg。请先在电脑或服务器运行 `mobile_server/server.py`，再在手机应用中填写服务地址。手机与电脑在同一 Wi-Fi 时，可填写电脑局域网地址，例如 `http://192.168.1.20:8000`；正式部署应使用 HTTPS 和身份验证。服务端和 Windows 一样依赖 yt-dlp 当前的站点解析能力，不能保证微信视频号分享链接可用。

服务端会自动从带说明文字的分享内容中提取 URL，只接受 B 站、抖音和微信视频号域名，并为每个下载任务使用独立临时目录，避免多个手机任务拿到错误文件。抖音可以在服务端电脑上通过 `DOWNLOADER_BROWSER=chrome` 或 `DOWNLOADER_BROWSER=edge` 复用本机浏览器会话。

```powershell
cd mobile_server
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe server.py
```

Android 构建：

```powershell
flutter pub get
flutter build apk --release
```

iOS 构建需要 macOS、Xcode、Apple 开发者签名和 CocoaPods。Windows 电脑可以维护 Flutter 源码，但不能在本机生成最终 iOS IPA。

GitHub Actions 提供 Android 构建工作流；iOS 工作流可在 macOS runner 上生成未签名的 iOS Release，正式安装到 iPhone 仍需要 Apple 签名和开发者账号。

## 资源文件

将以下文件放进 `resources/`：

- `yt-dlp.exe`
- `ffmpeg.exe`
- `ffprobe.exe`（可选）

构建时会把它们复制到 Windows 发布目录。Flutter Windows 应用默认是一个发布文件夹，用户双击其中的 `public_video_downloader.exe` 即可运行。

## 构建

```powershell
flutter pub get
flutter build windows --release
```

发布目录：`build\windows\x64\runner\Release\`

## GitHub Actions

仓库中的 `.github/workflows/windows.yml` 会在推送到 `main` 分支后自动检查代码、构建 Windows Release，并上传 ZIP 构建产物。FFmpeg 和 yt-dlp 通过 Git LFS 管理，克隆仓库时需要安装 Git LFS。

## 许可

应用代码使用 MIT 许可。`resources\ffmpeg.exe` 遵循 FFmpeg 自身许可，许可文本见 `resources\FFMPEG-LICENSE.txt`；`resources\yt-dlp.exe` 遵循 yt-dlp 项目许可。
