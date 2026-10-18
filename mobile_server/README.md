# Mobile download service

The Android/iOS Flutter client cannot execute Windows `yt-dlp.exe` or `ffmpeg.exe`. Run this small service on a computer with Python, `yt-dlp`, and FFmpeg installed, then enter the computer's LAN address in the mobile app.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe server.py
```

Example app address: `http://192.168.1.20:8000`.

For use outside a private LAN, put the service behind HTTPS and authentication. Only process public content you are authorized to save.
