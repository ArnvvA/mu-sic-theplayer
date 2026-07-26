import os
import json
import shutil
import yt_dlp

OUTPUT_PATH = r"D:\Games\cards\assets\music"

# Path to a cookies.txt exported from your browser (via "Get cookies.txt
# LOCALLY" extension on youtube.com). yt-dlp uses these cookies so requests
# look like a normal logged-in user, which prevents rate limiting.
COOKIES_FILE = r"D:\Games\cards\cookies.txt"

AUDIO_EXTS = (".ogg", ".mp3", ".wav")


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


def extract_chapters(info: dict) -> list:
    # yt-dlp puts YouTube's chapter splits in info["chapters"] as a list of
    # {start_time, end_time, title}. Normalize to {start, end, title} with
    # numeric seconds; drop anything without a start time. end may be null on a
    # trailing chapter — the player can fall back to the song's duration there.
    raw = info.get("chapters") or []
    out = []
    for ch in raw:
        start = ch.get("start_time")
        if start is None:
            continue
        end = ch.get("end_time")
        out.append({
            "start": float(start),
            "end": float(end) if end is not None else None,
            "title": (ch.get("title") or "").strip(),
        })
    return out


def find_audio_for(folder: str, base: str) -> str:
    # An info.json named "<base>.info.json" pairs with an audio file "<base>.ogg"
    # (or .mp3/.wav) — same output-template base, different extension. Return the
    # audio filename that actually exists on disk, or "" if none does.
    for ext in AUDIO_EXTS:
        cand = base + ext
        if os.path.exists(os.path.join(folder, cand)):
            return cand
    return ""


def write_meta(folder: str, album_name: str, info: dict,
               chapters_map: dict, source_url: str = "") -> None:
    meta_path = os.path.join(folder, "meta.json")
    if os.path.exists(meta_path):
        with open(meta_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
    else:
        meta = {}
    meta.setdefault("album", album_name)
    meta.setdefault("artist", parse_artist(info))
    if source_url:
        meta["source_url"] = source_url
    if chapters_map:
        # Merge so re-runs / backfills add to (not clobber) known chapters.
        existing = meta.get("chapters", {})
        existing.update(chapters_map)
        meta["chapters"] = existing
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)


def consolidate_artifacts(folder: str, album_name: str,
                          source_url: str = "") -> None:
    cover = os.path.join(folder, "cover.jpg")
    album_info = None
    chapters_map = {}

    for fn in sorted(os.listdir(folder)):
        path = os.path.join(folder, fn)
        lower = fn.lower()

        if lower.endswith(".info.json"):
            with open(path, "r", encoding="utf-8") as f:
                info = json.load(f)
            if album_info is None:
                album_info = info      # first one drives album/artist meta
            base = fn[: -len(".info.json")]
            audio = find_audio_for(folder, base)
            if audio:
                chs = extract_chapters(info)
                if chs:
                    chapters_map[audio] = chs
            os.remove(path)
            continue

        if lower.endswith((".jpg", ".jpeg", ".png", ".webp")) and fn != "cover.jpg":
            if not os.path.exists(cover):
                shutil.move(path, cover)
            else:
                os.remove(path)

    if album_info is not None:
        write_meta(folder, album_name, album_info, chapters_map, source_url)


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
    consolidate_artifacts(folder, album_name, source_url=url)


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


# ── Chapter backfill ──────────────────────────────────────────────────────────
# Existing albums were downloaded before chapters were captured. This re-fetches
# just the metadata (no audio) for one already-downloaded album and writes the
# chapter splits into its meta.json, matching each video's chapters to the audio
# files already on disk. Use it for the single-video "Full Album" uploads whose
# chapters mark the track boundaries.

def _match_chapters_to_disk(folder: str, entries: list) -> dict:
    # Pair each fetched video's chapters with a real audio file in the folder.
    # Prefer an exact "<title>.<ext>" match; if there's exactly one video and one
    # audio file (the common Full-Album case), pair them directly.
    audio_files = [f for f in sorted(os.listdir(folder))
                   if f.lower().endswith(AUDIO_EXTS)]
    chapters_map = {}

    if len(entries) == 1 and len(audio_files) == 1:
        chs = extract_chapters(entries[0])
        if chs:
            chapters_map[audio_files[0]] = chs
        return chapters_map

    for entry in entries:
        chs = extract_chapters(entry)
        if not chs:
            continue
        title = entry.get("title") or ""
        base = sanitize_filename(title)
        matched = ""
        for af in audio_files:
            if os.path.splitext(af)[0] == title or os.path.splitext(af)[0] == base:
                matched = af
                break
        if matched:
            chapters_map[matched] = chs
    return chapters_map


def backfill(url: str, folder: str) -> None:
    opts = {
        "quiet": True,
        "cookiefile": COOKIES_FILE,
        # Full extraction (not extract_flat) so chapters come through.
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)

    entries = info.get("entries")
    entries = list(entries) if entries else [info]
    entries = [e for e in entries if e]  # ignoreerrors can leave None gaps

    chapters_map = _match_chapters_to_disk(folder, entries)
    if not chapters_map:
        print("No chapters found (or none matched the audio files on disk).")
        return

    write_meta(folder, os.path.basename(folder), entries[0], chapters_map,
               source_url=url)
    total = sum(len(v) for v in chapters_map.values())
    print(f"Wrote {total} chapters across {len(chapters_map)} file(s) to {folder}")


if __name__ == "__main__":
    mode = input("mode — [d]ownload or [b]ackfill chapters (default d): ").strip().lower()
    if mode.startswith("b"):
        album = input("Existing album folder name: ").strip()
        folder = os.path.join(OUTPUT_PATH, sanitize_filename(album))
        if not os.path.isdir(folder):
            print(f"No such album folder: {folder}")
        else:
            url = input("Source URL: ").strip()
            backfill(url, folder)
    else:
        url = input("url: ").strip()
        decide(url)
