# Flutter 公开视频下载器

这是 Windows 桌面版 Flutter 工程。界面由 Flutter 绘制，下载由随应用提供的 `yt-dlp.exe` 和 FFmpeg 完成。

## 功能

- 粘贴 B 站、抖音等公开页面链接
- 解析标题、作者、时长和可用画质
- 选择保存目录
- 高画质视频和音频自动合并
- 下载进度、速度、日志和取消

只处理公开且用户有权保存的内容。视频号、需要登录、付费、DRM、验证码或平台安全限制的链接，取决于平台当前允许的公开访问能力。

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
