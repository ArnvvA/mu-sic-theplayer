import os
import json
import shutil
import yt_dlp

OUTPUT_PATH = r"D:\Games\cards\assets\music"

# Path to a cookies.txt exported from your browser (via "Get cookies.txt
# LOCALLY" extension on youtube.com). yt-dlp uses these cookies so requests
# look like a normal logged-in user, which prevents rate limiting.
COOKIES_FILE = r"D:\Games\cards\cookies.txt"


def sanitize_filename(name: str) -> str:
    return "".join(c for c in name if c.isalnum() or c in " _-").strip()


def parse_artist(info: dict) -> str:
    author = (info.get("uploader") or info.get("channel") or "").strip()
    if author.endswith(" - Topic"):
        author = author[: -len(" - Topic")]
    if not author:
        title = info.get("title") or ""
        if " - " in title:
            author = title.split(" - ", 1)[0].strip()
    return author or "Unknown"


def write_meta(folder: str, album_name: str, info: dict) -> None:
    meta_path = os.path.join(folder, "meta.json")
    if os.path.exists(meta_path):
        with open(meta_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
    else:
        meta = {}
    meta.setdefault("album", album_name)
    meta.setdefault("artist", parse_artist(info))
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)


def consolidate_artifacts(folder: str, album_name: str) -> None:
    cover = os.path.join(folder, "cover.jpg")
    info_payload = None

    for fn in sorted(os.listdir(folder)):
        path = os.path.join(folder, fn)
        lower = fn.lower()

        if lower.endswith(".info.json"):
            if info_payload is None:
                with open(path, "r", encoding="utf-8") as f:
                    info_payload = json.load(f)
            os.remove(path)
            continue

        if lower.endswith((".jpg", ".jpeg", ".png", ".webp")) and fn != "cover.jpg":
            if not os.path.exists(cover):
                shutil.move(path, cover)
            else:
                os.remove(path)

    if info_payload is not None:
        write_meta(folder, album_name, info_payload)


def make_opts(folder: str, is_playlist: bool) -> dict:
    name_tmpl = (
        "%(playlist_index)s - %(title)s.%(ext)s"
        if is_playlist
        else "%(title)s.%(ext)s"
    )
    return {
        "format": "bestaudio/best",
        "outtmpl": os.path.join(folder, name_tmpl),
        "writethumbnail": True,
        "writeinfojson": True,
        "cookiefile": COOKIES_FILE,
        "sleep_interval": 3,
        "max_sleep_interval": 7,
        "ignoreerrors": True,
        "retries": 5,
        "fragment_retries": 5,
        "js_runtimes": {"node": {}},
        "postprocessors": [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": "vorbis",
                "preferredquality": "192",
            },
            {"key": "FFmpegThumbnailsConvertor", "format": "jpg"},
        ],
    }


def download(url: str, folder: str, album_name: str, is_playlist: bool) -> None:
    os.makedirs(folder, exist_ok=True)
    with yt_dlp.YoutubeDL(make_opts(folder, is_playlist)) as ydl:
        ydl.download([url])
    consolidate_artifacts(folder, album_name)


def resolve_playlist_title(url: str) -> str:
    probe_opts = {
        "extract_flat": True,
        "quiet": True,
        "cookiefile": COOKIES_FILE,
    }
    with yt_dlp.YoutubeDL(probe_opts) as ydl:
        info = ydl.extract_info(url, download=False)
    return info.get("title") or "Playlist"


def decide(url: str) -> None:
    is_playlist = ("playlist" in url.lower()) or ("list=" in url)
    if is_playlist:
        album_name = resolve_playlist_title(url)
        folder = os.path.join(OUTPUT_PATH, sanitize_filename(album_name))
        download(url, folder, album_name, is_playlist=True)
    else:
        album = input("Album / folder name (blank = Singles): ").strip() or "Singles"
        folder = os.path.join(OUTPUT_PATH, sanitize_filename(album))
        download(url, folder, album, is_playlist=False)


if __name__ == "__main__":
    url = input("url: ").strip()
    decide(url)
