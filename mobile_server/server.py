"""Minimal mobile backend for the Flutter Android/iOS client.

Run this on a computer that has Python, yt-dlp and FFmpeg installed. Put the
server URL into the mobile app, for example http://192.168.1.20:8000.
Only use it for public content you are authorized to save.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from flask import Flask, Response, jsonify, request, send_file

app = Flask(__name__)
DOWNLOAD_DIR = Path(tempfile.gettempdir()) / "public_video_downloader_mobile"
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)


def run_ytdlp(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["yt-dlp", "--no-warnings", "--no-playlist", *args],
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=300,
    )


def error_response(result: subprocess.CompletedProcess[str]) -> tuple[Response, int]:
    message = (result.stderr or result.stdout or "yt-dlp 执行失败").strip()
    return jsonify({"error": message[-4000:]}), 400


@app.post("/api/info")
def info() -> tuple[Response, int] | Response:
    payload: dict[str, Any] = request.get_json(silent=True) or {}
    url = str(payload.get("url", "")).strip()
    if not re.match(r"^https?://", url):
        return jsonify({"error": "链接必须以 http:// 或 https:// 开头"}), 400
    result = run_ytdlp(["--dump-single-json", url])
    if result.returncode:
        return error_response(result)
    return Response(result.stdout, content_type="application/json; charset=utf-8")


@app.post("/api/download")
def download() -> tuple[Response, int] | Response:
    payload: dict[str, Any] = request.get_json(silent=True) or {}
    url = str(payload.get("url", "")).strip()
    selector = str(payload.get("format", "bestvideo*+bestaudio/best"))
    if not re.match(r"^https?://", url):
        return jsonify({"error": "链接必须以 http:// 或 https:// 开头"}), 400
    output = str(DOWNLOAD_DIR / "%(title).100s [%(id)s].%(ext)s")
    result = run_ytdlp([
        "--format", selector,
        "--merge-output-format", "mp4",
        "--output", output,
        url,
    ])
    if result.returncode:
        return error_response(result)
    files = sorted(DOWNLOAD_DIR.glob("*"), key=os.path.getmtime, reverse=True)
    if not files:
        return jsonify({"error": "下载完成但没有找到输出文件"}), 500
    return send_file(files[0], as_attachment=True, download_name=files[0].name)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
