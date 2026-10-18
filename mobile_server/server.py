"""Minimal mobile backend for the Flutter Android/iOS client.

Run this on a computer that has Python, yt-dlp and FFmpeg installed. Put the
server URL into the mobile app, for example http://192.168.1.20:8000.
Only use it for public content you are authorized to save.
"""

from __future__ import annotations

import argparse
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any
from urllib.parse import urlparse

from flask import Flask, Response, jsonify, request, send_file

app = Flask(__name__)
ALLOWED_HOSTS = (
    "bilibili.com",
    "b23.tv",
    "douyin.com",
    "iesdouyin.com",
    "weixin.qq.com",
)
FORMAT_PATTERN = re.compile(r"^[A-Za-z0-9*+./=<>:\[\]-]{1,240}$")
URL_PATTERN = re.compile(
    r"(?:https?://|(?:www\.)?(?:v\.douyin\.com|douyin\.com|iesdouyin\.com|"
    r"bilibili\.com|b23\.tv|weixin\.qq\.com)/)[^\s<>\"']+",
    re.IGNORECASE,
)


def normalize_url(value: str) -> str:
    match = URL_PATTERN.search(html.unescape(value).strip())
    if not match:
        return ""
    url = match.group(0).rstrip("，。；、）】》>.,;:!?)]}")
    return url if re.match(r"https?://", url, re.IGNORECASE) else f"https://{url}"


def validate_url(value: str) -> str:
    url = normalize_url(value)
    parsed = urlparse(url)
    host = parsed.hostname.lower().rstrip(".") if parsed.hostname else ""
    if parsed.scheme not in {"http", "https"} or not host:
        raise ValueError("链接必须以 http:// 或 https:// 开头")
    if not any(host == suffix or host.endswith(f".{suffix}") for suffix in ALLOWED_HOSTS):
        raise ValueError("暂不支持这个站点，仅支持 B 站、抖音和微信视频号链接")
    return url


def is_wechat_url(url: str) -> bool:
    host = urlparse(url).hostname or ""
    return host.lower().endswith("weixin.qq.com")


def run_ytdlp(args: list[str], *, cwd: str | None = None, timeout: int = 1800) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, "-m", "yt_dlp", "--no-warnings", "--no-playlist", "--windows-filenames"]
    browser = os.environ.get("DOWNLOADER_BROWSER", "").strip()
    if browser:
        command.extend(["--cookies-from-browser", browser])
    ffmpeg = os.environ.get("FFMPEG_BIN", "").strip()
    if ffmpeg:
        command.extend(["--ffmpeg-location", ffmpeg])
    return subprocess.run(
        [*command, *args],
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        cwd=cwd,
        timeout=timeout,
    )


def error_response(result: subprocess.CompletedProcess[str]) -> tuple[Response, int]:
    message = (result.stderr or result.stdout or "yt-dlp 执行失败").strip()
    return jsonify({"error": message[-4000:]}), 400


@app.get("/api/health")
def health() -> Response:
    return jsonify({"ok": True, "service": "public-video-downloader"})


@app.post("/api/info")
def info() -> tuple[Response, int] | Response:
    payload: dict[str, Any] = request.get_json(silent=True) or {}
    try:
        url = validate_url(str(payload.get("url", "")))
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    if is_wechat_url(url):
        return jsonify({"error": "微信视频号目前没有稳定的 yt-dlp 专用解析器"}), 400
    result = run_ytdlp(["--dump-single-json", url], timeout=120)
    if result.returncode:
        return error_response(result)
    return Response(result.stdout, content_type="application/json; charset=utf-8")


@app.post("/api/download")
def download() -> tuple[Response, int] | Response:
    payload: dict[str, Any] = request.get_json(silent=True) or {}
    try:
        url = validate_url(str(payload.get("url", "")))
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    if is_wechat_url(url):
        return jsonify({"error": "微信视频号目前没有稳定的 yt-dlp 专用解析器"}), 400
    selector = str(payload.get("format", "bestvideo*+bestaudio/best"))
    if not FORMAT_PATTERN.fullmatch(selector) or selector.startswith("-"):
        return jsonify({"error": "无效的画质格式"}), 400
    work_dir = tempfile.mkdtemp(prefix="public-video-downloader-")
    output = "%(title).100s [%(id)s].%(ext)s"
    result = run_ytdlp([
        "--format", selector,
        "--merge-output-format", "mp4",
        "--output", output,
        url,
    ], cwd=work_dir)
    if result.returncode:
        shutil.rmtree(work_dir, ignore_errors=True)
        return error_response(result)
    files = sorted(
        (entry for entry in os.scandir(work_dir) if entry.is_file() and not entry.name.endswith(".part")),
        key=lambda entry: entry.stat().st_mtime,
        reverse=True,
    )
    if not files:
        shutil.rmtree(work_dir, ignore_errors=True)
        return jsonify({"error": "下载完成但没有找到输出文件"}), 500
    response = send_file(files[0].path, as_attachment=True, download_name=files[0].name)
    response.call_on_close(lambda: shutil.rmtree(work_dir, ignore_errors=True))
    return response


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    app.run(host=args.host, port=args.port)
