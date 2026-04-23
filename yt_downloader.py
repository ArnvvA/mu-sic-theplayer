from pytubefix import YouTube, Playlist
from pytubefix.cli import on_progress
import os
import ffmpeg

OUTPUT_PATH = "D:\\Games\\cards\\assets\\music"


def convert_to_ogg(input_path):
    base     = os.path.splitext(input_path)[0]
    ogg_path = base + ".ogg"

    try:
        (
            ffmpeg
            .input(input_path)
            .output(
                ogg_path,
                acodec='libvorbis',
                audio_bitrate='192k',
            )
            .overwrite_output()
            .run(quiet=True)
        )
        os.remove(input_path)
        print(f"\nConverted: {os.path.basename(ogg_path)}")
        return ogg_path
    except ffmpeg.Error as e:
        print(f"Conversion failed: {e}")
        return input_path


def download_singular(url, path=OUTPUT_PATH):
    yt = YouTube(url, on_progress_callback=on_progress)
    print(f"Downloading: {yt.title}")

    ys       = yt.streams.filter(only_audio=True).first()
    out_file = ys.download(output_path=path)
    convert_to_ogg(out_file)


def download_playlist(url):
    playlist    = Playlist(url)
    folder_name = sanitize_filename(playlist.title)
    pl_folder   = os.path.join(OUTPUT_PATH, folder_name)
    os.makedirs(pl_folder, exist_ok=True)
    print(f"Downloading playlist: {playlist.title}")

    for video in playlist.videos:
        download_singular(video.watch_url, pl_folder)


def decide(url):
    if "playlist" in url.lower():
        download_playlist(url)
    else:
        folder = input("Album / folder name (blank = Singles): ").strip()
        if not folder:
            folder = "Singles"
        track_path = os.path.join(OUTPUT_PATH, sanitize_filename(folder))
        os.makedirs(track_path, exist_ok=True)
        download_singular(url, track_path)


def sanitize_filename(name):
    return "".join(c for c in name if c.isalnum() or c in " _-").strip()


if __name__ == "__main__":
    url = input("url: ")
    decide(url)
