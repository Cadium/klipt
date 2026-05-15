import os
import re
import shutil
import tempfile
from typing import Optional
from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel
import yt_dlp

app = FastAPI(title="Klipt API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

PLATFORM_PATTERNS = {
    "twitter": re.compile(r"(https?://)?(www\.)?(twitter\.com|x\.com)/\S+/status/\d+"),
    "tiktok": re.compile(r"(https?://)?(www\.|vm\.)?tiktok\.com/\S+"),
    "instagram": re.compile(r"(https?://)?(www\.)?instagram\.com/(p|reel|stories|tv)/\S+"),
    "youtube": re.compile(r"(https?://)?(www\.)?(youtube\.com/(shorts/|watch\?v=)|youtu\.be/)\S+"),
}


class ResolveRequest(BaseModel):
    url: str


class MediaItem(BaseModel):
    url: str
    quality: Optional[str] = None
    ext: str


class ResolveResponse(BaseModel):
    platform: str
    type: str
    thumbnail: Optional[str]
    title: Optional[str]
    media: list[MediaItem]


def detect_platform(url: str) -> str:
    for platform, pattern in PLATFORM_PATTERNS.items():
        if pattern.search(url):
            return platform
    raise HTTPException(status_code=400, detail="Unsupported platform or invalid URL")


def base_ydl_opts(platform: str) -> dict:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
    }
    if platform == "tiktok":
        opts["format"] = "best[format_id!=download][ext=mp4]/best[format_id!=download]"
    if platform in ("twitter", "instagram"):
        opts["cookiesfrombrowser"] = ("chrome",)
    return opts


def extract_media_items(info: dict, platform: str) -> tuple[list[MediaItem], str]:
    media_items: list[MediaItem] = []
    media_type = "video"

    if "entries" in info:
        entries = list(info["entries"])
        for entry in entries:
            if entry.get("url"):
                media_items.append(MediaItem(url=entry["url"], ext=entry.get("ext", "jpg")))
        is_all_images = all(e.get("ext", "") in ("jpg", "jpeg", "png", "webp") for e in entries)
        media_type = "image" if is_all_images else "video"
        return media_items, media_type

    if info.get("formats"):
        formats = info["formats"]
        if platform == "tiktok":
            formats = [f for f in formats if f.get("format_id") != "download"]

        video_formats = [
            f for f in formats
            if f.get("url") and f.get("vcodec") not in (None, "none") and f.get("ext") == "mp4"
        ]
        if not video_formats:
            video_formats = [f for f in formats if f.get("url") and f.get("vcodec") not in (None, "none")]

        h264 = [f for f in video_formats if "h264" in (f.get("vcodec") or "")]
        chosen = h264 if h264 else video_formats
        chosen.sort(key=lambda f: (f.get("height") or 0), reverse=True)

        seen: set = set()
        for f in chosen:
            h = f.get("height")
            if h in seen:
                continue
            seen.add(h)
            label = f"{h}p" if h else f.get("format_note", "best")
            media_items.append(MediaItem(url=f["url"], quality=label, ext=f.get("ext", "mp4")))
            if len(media_items) == 3:
                break

    if not media_items and info.get("url"):
        media_items.append(MediaItem(url=info["url"], ext=info.get("ext", "mp4")))

    return media_items, media_type


@app.post("/resolve", response_model=ResolveResponse)
def resolve(req: ResolveRequest):
    platform = detect_platform(req.url)
    opts = base_ydl_opts(platform)
    opts["skip_download"] = True

    with yt_dlp.YoutubeDL(opts) as ydl:
        try:
            info = ydl.extract_info(req.url, download=False)
        except yt_dlp.utils.DownloadError as e:
            raise HTTPException(status_code=422, detail=str(e))

    media_items, media_type = extract_media_items(info, platform)
    if not media_items:
        raise HTTPException(status_code=422, detail="No downloadable media found")

    return ResolveResponse(
        platform=platform,
        type=media_type,
        thumbnail=info.get("thumbnail"),
        title=info.get("title"),
        media=media_items,
    )


@app.post("/download")
def download(req: ResolveRequest, background_tasks: BackgroundTasks):
    """Download media and return the file directly. Handles HLS and all formats."""
    platform = detect_platform(req.url)
    opts = base_ydl_opts(platform)

    tmpdir = tempfile.mkdtemp()
    opts["outtmpl"] = os.path.join(tmpdir, "media.%(ext)s")
    # Merge best video+audio into a single MP4
    opts["format"] = "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
    opts["merge_output_format"] = "mp4"
    opts["postprocessors"] = [{"key": "FFmpegVideoConvertor", "preferedformat": "mp4"}]

    if platform == "tiktok":
        opts["format"] = "best[format_id!=download][ext=mp4]/best[format_id!=download]"

    with yt_dlp.YoutubeDL(opts) as ydl:
        try:
            ydl.extract_info(req.url, download=True)
        except yt_dlp.utils.DownloadError as e:
            shutil.rmtree(tmpdir, ignore_errors=True)
            raise HTTPException(status_code=422, detail=str(e))

    files = [f for f in os.listdir(tmpdir) if not f.startswith(".")]
    if not files:
        shutil.rmtree(tmpdir, ignore_errors=True)
        raise HTTPException(status_code=422, detail="Download produced no output")

    filepath = os.path.join(tmpdir, files[0])
    ext = os.path.splitext(filepath)[1].lower()
    media_type = "video/mp4" if ext in (".mp4", ".mov", ".m4v") else "image/jpeg"

    background_tasks.add_task(shutil.rmtree, tmpdir, True)
    return FileResponse(filepath, media_type=media_type, filename=f"klipt{ext}")


@app.get("/health")
def health():
    return {"status": "ok"}
