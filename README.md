# Flutter 公开视频下载器

这是 Flutter 跨平台工程。Windows 版在本机运行随应用提供的 `yt-dlp.exe` 和 FFmpeg；Android/iOS 版通过 `mobile_server/` 下载服务完成解析、下载和手机保存。Windows 运行库只进入 Windows 发布包，不会进入移动端 APK/IPA。

## 功能

- 粘贴 B 站、抖音等公开页面链接
- 解析标题、作者、时长和可用画质
- 选择保存目录
- 高画质视频和音频自动合并
- 下载进度、速度、日志和取消
- 可选读取本机 Chrome、Edge 或 Firefox 的浏览器会话，用于抖音需要新鲜 Cookie 的链接
- Android/iOS 共用 Flutter 界面，下载完成后调起系统分享/保存面板

只处理公开且用户有权保存的内容。视频号、需要登录、付费、DRM、验证码或平台安全限制的链接，取决于平台当前允许的公开访问能力。

抖音目前经常要求新鲜浏览器会话。使用时先在浏览器中打开目标视频，确认页面可以正常播放，然后完全关闭浏览器（包括后台进程），在应用中选择对应浏览器后再解析。应用只在用户主动选择时读取本机浏览器会话，不上传 Cookie。

## Android 和 iOS

移动系统不能直接执行 Windows 的 `yt-dlp.exe` 和 FFmpeg。请先在电脑或服务器运行 `mobile_server/server.py`，再在手机应用中填写服务地址。手机与电脑在同一 Wi-Fi 时，可填写电脑局域网地址，例如 `http://192.168.1.20:8000`；正式部署应使用 HTTPS 和身份验证。

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
