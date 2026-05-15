# Klipt

Save videos and images from Twitter/X, TikTok, Instagram, and YouTube Shorts directly to your iPhone's Photos library — organised into per-platform albums, no watermarks, no ads.

## What it does

Paste a link. Tap save. Done.

| Platform | What you get |
|---|---|
| Twitter / X | Video download (no native download exists) |
| TikTok | Watermark-free video |
| Instagram | Feed posts, Reels, Stories |
| YouTube Shorts | Clean MP4, up to 1080p+ |

Media saves automatically to a named album (`Twitter`, `TikTok`, `Instagram`, `YouTube`) in your Photos library.

## Architecture

```
iOS App (Swift / SwiftUI)
  └── detects clipboard URL on open
  └── calls backend to resolve + download
  └── saves to Photos with album targeting

Backend (Python / FastAPI + yt-dlp)
  ├── POST /resolve  → returns metadata and quality options
  ├── POST /download → downloads and returns MP4 directly
  └── GET  /health
```

## Running locally

**Backend**
```bash
cd backend
python3.12 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

**iOS app**

Open `Klipt/Klipt.xcodeproj` in Xcode, select an iPhone simulator, and hit Run.

> The app points to `http://localhost:8000` by default. Make sure the backend is running before launching the simulator.
