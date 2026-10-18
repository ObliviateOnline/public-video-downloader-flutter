# Mobile download service

The Android/iOS Flutter client cannot execute Windows `yt-dlp.exe` or `ffmpeg.exe`. Run this small service on a computer with Python, `yt-dlp`, and FFmpeg installed, then enter the computer's LAN address in the mobile app.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe server.py --host 0.0.0.0
```

Example app address: `http://192.168.1.20:8000`.

The service accepts copied share text, including links without `https://`, for Bilibili, Douyin, and WeChat Channels hostnames. It extracts the real URL, adds the scheme when needed, isolates every download in its own temporary directory, and removes the temporary files after the phone receives the file. `yt-dlp` is installed in the same virtual environment as the service, so the server does not depend on a global Python package.

For Douyin, open the page in a browser on the same computer first, close the browser, then set `DOWNLOADER_BROWSER=chrome` or `DOWNLOADER_BROWSER=edge` before starting the service. This reads the local browser session only; it does not upload cookies to the phone. If the service is exposed outside a private LAN, put it behind HTTPS and authentication.

The default bind address is `127.0.0.1`. Use `--host 0.0.0.0` only when the phone needs to connect over the local network. Only process public content you are authorized to save.
