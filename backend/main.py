import re
from typing import Optional
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import yt_dlp

app = FastAPI(title="Media Saver API")

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
}


class ResolveRequest(BaseModel):
    url: str


class MediaItem(BaseModel):
    url: str
    quality: Optional[str] = None
    ext: str


class ResolveResponse(BaseModel):
    platform: str
    type: str  # "video" or "image"
    thumbnail: Optional[str]
    title: Optional[str]
    media: list[MediaItem]


def detect_platform(url: str) -> str:
    for platform, pattern in PLATFORM_PATTERNS.items():
        if pattern.search(url):
            return platform
    raise HTTPException(status_code=400, detail="Unsupported platform or invalid URL")


def build_ydl_opts(platform: str) -> dict:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
    }

    if platform == "tiktok":
        # Exclude the "download" format which has a watermark burned in.
        # All other format IDs (h264_*, bytevc1_*) are watermark-free.
        opts["format"] = "best[format_id!=download][ext=mp4]/best[format_id!=download]"

    if platform in ("twitter", "instagram"):
        # Twitter and Instagram require a logged-in session.
        # Try Chrome first (Safari needs Full Disk Access in Terminal).
        opts["cookiesfrombrowser"] = ("chrome",)

    return opts


def extract_media_items(info: dict, platform: str) -> tuple[list[MediaItem], str]:
    media_items: list[MediaItem] = []
    media_type = "video"

    # Gallery posts: Instagram carousels, TikTok photo slideshows
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

        # For TikTok, exclude the watermarked format ID
        if platform == "tiktok":
            formats = [f for f in formats if f.get("format_id") != "download"]

        # Keep only proper video formats
        video_formats = [
            f for f in formats
            if f.get("url")
            and f.get("vcodec") not in (None, "none")
            and f.get("ext") == "mp4"
        ]
        if not video_formats:
            video_formats = [f for f in formats if f.get("url") and f.get("vcodec") not in (None, "none")]

        # Prefer h264 for iOS compatibility, then fall back to any codec
        h264 = [f for f in video_formats if "h264" in (f.get("vcodec") or "")]
        chosen = h264 if h264 else video_formats

        # Sort by resolution descending, deduplicate by height
        chosen.sort(key=lambda f: (f.get("height") or 0), reverse=True)
        seen_heights: set = set()
        for f in chosen:
            h = f.get("height")
            if h in seen_heights:
                continue
            seen_heights.add(h)
            label = f"{h}p" if h else f.get("format_note", "best")
            media_items.append(MediaItem(url=f["url"], quality=label, ext=f.get("ext", "mp4")))
            if len(media_items) == 3:
                break

    # Single direct URL (common for Twitter after format selection)
    if not media_items and info.get("url"):
        media_items.append(MediaItem(url=info["url"], ext=info.get("ext", "mp4")))

    return media_items, media_type


def resolve_media(url: str, platform: str) -> ResolveResponse:
    ydl_opts = build_ydl_opts(platform)

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        try:
            info = ydl.extract_info(url, download=False)
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


@app.post("/resolve", response_model=ResolveResponse)
def resolve(req: ResolveRequest):
    platform = detect_platform(req.url)
    return resolve_media(req.url, platform)


@app.get("/health")
def health():
    return {"status": "ok"}
