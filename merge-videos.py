#!/usr/bin/env python3
"""Merge videos, preferring stream copy and using NVENC when normalization is needed."""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
from fractions import Fraction
from pathlib import Path


VIDEO_EXTENSIONS = {
    ".mp4", ".mkv", ".mov", ".m4v", ".avi", ".webm",
    ".ts", ".mts", ".m2ts", ".flv",
}


def run(command: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(f'"{part}"' if " " in part else part for part in command))
    return subprocess.run(command, check=check, text=True)


def capture(command: list[str]) -> str:
    result = subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout


def natural_key(path: Path) -> list[object]:
    return [
        int(part) if part.isdigit() else part.lower()
        for part in re.split(r"(\d+)", path.name)
    ]


def integer(value: object, default: int = 0) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def parse_rate(value: object) -> float:
    if not value or value in {"0/0", "N/A"}:
        return 0.0
    try:
        return float(Fraction(str(value)))
    except (ValueError, ZeroDivisionError):
        return 0.0


def canonical_frame_rate(fps: float) -> Fraction:
    """Convert decimal FPS to a safe, compact rational representation."""
    ntsc_rates = (
        Fraction(24000, 1001),
        Fraction(30000, 1001),
        Fraction(48000, 1001),
        Fraction(60000, 1001),
        Fraction(120000, 1001),
    )
    for rate in ntsc_rates:
        if abs(float(rate) - fps) < 0.001:
            return rate
    return Fraction(fps).limit_denominator(1001)


def probe(path: Path) -> dict[str, object]:
    data = json.loads(
        capture([
            "ffprobe", "-v", "error",
            "-show_streams", "-show_format",
            "-of", "json", str(path),
        ])
    )
    streams = data.get("streams", [])
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    if not video:
        raise RuntimeError(f"没有检测到视频流：{path}")
    return {
        "path": path,
        "video": video,
        "audio": audio,
        "format": data.get("format", {}),
    }


def video_signature(item: dict[str, object]) -> tuple[object, ...]:
    video = item["video"]
    assert isinstance(video, dict)
    return (
        video.get("codec_name"),
        video.get("profile"),
        video.get("level"),
        integer(video.get("width")),
        integer(video.get("height")),
        video.get("pix_fmt"),
        video.get("r_frame_rate"),
        video.get("time_base"),
        video.get("sample_aspect_ratio"),
    )


def audio_signature(item: dict[str, object]) -> tuple[object, ...] | None:
    audio = item["audio"]
    if not isinstance(audio, dict):
        return None
    return (
        audio.get("codec_name"),
        audio.get("sample_rate"),
        audio.get("channels"),
        audio.get("channel_layout"),
        audio.get("time_base"),
    )


def can_lossless_concat(items: list[dict[str, object]]) -> bool:
    first_video = items[0]["video"]
    assert isinstance(first_video, dict)
    if first_video.get("codec_name") != "h264":
        return False
    video_sig = video_signature(items[0])
    audio_sig = audio_signature(items[0])
    return all(
        video_signature(item) == video_sig
        and audio_signature(item) == audio_sig
        for item in items[1:]
    )


def concat_quote(path: Path) -> str:
    return "'" + str(path.resolve()).replace("'", "'\\''") + "'"


def write_concat_file(path: Path, videos: list[Path]) -> None:
    path.write_text(
        "".join(f"file {concat_quote(video)}\n" for video in videos),
        encoding="utf-8",
    )


def try_lossless(
    items: list[dict[str, object]],
    output: Path,
    workdir: Path,
) -> bool:
    concat_file = workdir / "lossless.ffconcat"
    write_concat_file(
        concat_file,
        [item["path"] for item in items],  # type: ignore[list-item]
    )
    result = run([
        "ffmpeg", "-hide_banner", "-nostdin", "-y",
        "-f", "concat", "-safe", "0", "-i", str(concat_file),
        "-map", "0:v:0", "-map", "0:a:0?",
        "-c", "copy", "-movflags", "+faststart",
        str(output),
    ], check=False)
    if result.returncode == 0:
        return True
    output.unlink(missing_ok=True)
    print("无损拼接失败，将统一参数后使用 NVENC 编码。", file=sys.stderr)
    return False


def choose_targets(items: list[dict[str, object]]) -> dict[str, int | float]:
    best = max(
        items,
        key=lambda item:
            integer(item["video"].get("width"))  # type: ignore[union-attr]
            * integer(item["video"].get("height")),  # type: ignore[union-attr]
    )
    best_video = best["video"]
    assert isinstance(best_video, dict)
    width = integer(best_video.get("width"), 1920)
    height = integer(best_video.get("height"), 1080)
    width += width % 2
    height += height % 2

    fps = max(
        parse_rate(item["video"].get("avg_frame_rate"))  # type: ignore[union-attr]
        or parse_rate(item["video"].get("r_frame_rate"))  # type: ignore[union-attr]
        for item in items
    )
    fps = min(fps or 30.0, 120.0)
    fps_rate = canonical_frame_rate(fps)

    video_bitrates: list[int] = []
    audio_bitrates: list[int] = []
    sample_rates: list[int] = []
    channels: list[int] = []
    for item in items:
        video = item["video"]
        audio = item["audio"]
        file_format = item["format"]
        assert isinstance(video, dict) and isinstance(file_format, dict)
        video_bitrates.append(
            integer(video.get("bit_rate"))
            or integer(file_format.get("bit_rate"))
        )
        if isinstance(audio, dict):
            audio_bitrates.append(integer(audio.get("bit_rate")))
            sample_rates.append(integer(audio.get("sample_rate"), 48000))
            channels.append(integer(audio.get("channels"), 2))

    fallback_bitrate = int(width * height * float(fps_rate) * 0.10)
    video_bitrate = max(max(video_bitrates, default=0), fallback_bitrate, 2_000_000)
    audio_bitrate = min(max(max(audio_bitrates, default=0), 192_000), 320_000)

    return {
        "width": width,
        "height": height,
        "fps": float(fps_rate),
        "fps_num": fps_rate.numerator,
        "fps_den": fps_rate.denominator,
        "video_bitrate": video_bitrate,
        "audio_bitrate": audio_bitrate,
        "sample_rate": min(max(sample_rates, default=48000), 48000),
        "channels": min(max(channels, default=2), 8),
    }


def require_nvenc() -> None:
    if "h264_nvenc" not in capture(["ffmpeg", "-hide_banner", "-encoders"]):
        raise RuntimeError(
            "当前 ffmpeg 不包含 h264_nvenc。请安装启用了 NVENC 的 ffmpeg。"
        )


def transcode_one(
    item: dict[str, object],
    destination: Path,
    target: dict[str, int | float],
) -> None:
    source = item["path"]
    has_audio = isinstance(item["audio"], dict)
    width = int(target["width"])
    height = int(target["height"])
    fps_num = int(target["fps_num"])
    fps_den = int(target["fps_den"])
    fps_expression = f"{fps_num}/{fps_den}"

    # Keep an exact per-frame timestamp while avoiding the huge time base produced
    # by decimal expressions such as 59.940060 (which overflows after ~6 minutes).
    video_track_timescale = max(1000, fps_num)
    video_bitrate = int(target["video_bitrate"])
    maxrate = math.ceil(video_bitrate * 1.5)
    bufsize = video_bitrate * 2

    command = [
        "ffmpeg", "-hide_banner", "-nostdin", "-y",
        "-fflags", "+genpts",
        "-i", str(source),
    ]
    if not has_audio:
        command += [
            "-f", "lavfi", "-i",
            f"anullsrc=r={target['sample_rate']}:cl=stereo",
        ]

    video_filter = (
        f"scale={width}:{height}:force_original_aspect_ratio=decrease:"
        "flags=lanczos,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:black,"
        f"fps={fps_expression},setsar=1"
    )
    command += [
        "-map", "0:v:0",
        "-map", "0:a:0" if has_audio else "1:a:0",
        "-vf", video_filter,
        "-c:v", "h264_nvenc",
        "-preset", "p7",
        "-tune", "hq",
        "-rc", "vbr",
        "-cq", "18",
        "-b:v", str(video_bitrate),
        "-maxrate", str(maxrate),
        "-bufsize", str(bufsize),
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", str(target["audio_bitrate"]),
        "-ar", str(target["sample_rate"]),
        "-ac", str(target["channels"]),
        "-video_track_timescale", str(video_track_timescale),
        "-movflags", "+faststart",
    ]
    if not has_audio:
        command.append("-shortest")
    command.append(str(destination))
    run(command)


def reencode_and_concat(
    items: list[dict[str, object]],
    output: Path,
    workdir: Path,
) -> None:
    require_nvenc()
    target = choose_targets(items)
    print(
        "统一参数："
        f"{target['width']}x{target['height']}，{target['fps']:.3f} fps，"
        f"视频 {target['video_bitrate'] / 1_000_000:.2f} Mbps，"
        f"音频 {target['audio_bitrate'] / 1000:.0f} kbps"
    )

    normalized: list[Path] = []
    for index, item in enumerate(items, start=1):
        destination = workdir / f"normalized-{index:05d}.mp4"
        print(f"[{index}/{len(items)}] 转换 {item['path']}")
        transcode_one(item, destination, target)
        normalized.append(destination)

    concat_file = workdir / "normalized.ffconcat"
    write_concat_file(concat_file, normalized)
    run([
        "ffmpeg", "-hide_banner", "-nostdin", "-y",
        "-f", "concat", "-safe", "0", "-i", str(concat_file),
        "-c", "copy", "-movflags", "+faststart",
        str(output),
    ])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="按文件名顺序合并视频；兼容时无损拼接，否则使用 NVENC 编码。"
    )
    parser.add_argument("directory", nargs="?", default=".", help="视频目录")
    parser.add_argument("-o", "--output", default="merged.mp4", help="输出 MP4 文件")
    parser.add_argument(
        "--force-reencode",
        action="store_true",
        help="跳过无损拼接，强制统一参数并使用 NVENC 编码",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    for executable in ("ffmpeg", "ffprobe"):
        if not shutil.which(executable):
            print(f"错误：找不到 {executable}", file=sys.stderr)
            return 2

    directory = Path(args.directory).expanduser().resolve()
    output = Path(args.output).expanduser()
    if not output.is_absolute():
        output = directory / output
    output = output.resolve()

    if not directory.is_dir():
        print(f"错误：目录不存在：{directory}", file=sys.stderr)
        return 2
    if output.suffix.lower() != ".mp4":
        print("错误：输出文件必须使用 .mp4 扩展名", file=sys.stderr)
        return 2

    videos = sorted(
        (
            path for path in directory.iterdir()
            if path.is_file()
            and path.suffix.lower() in VIDEO_EXTENSIONS
            and path.resolve() != output
        ),
        key=natural_key,
    )
    if len(videos) < 2:
        print(f"错误：至少需要两个视频，当前找到 {len(videos)} 个", file=sys.stderr)
        return 2

    try:
        items = [probe(path) for path in videos]
        print("合并顺序：")
        for path in videos:
            print(f"  {path.name}")

        with tempfile.TemporaryDirectory(prefix="merge-videos-") as temp:
            workdir = Path(temp)
            if (
                not args.force_reencode
                and can_lossless_concat(items)
                and try_lossless(items, output, workdir)
            ):
                print(f"已完成无损拼接：{output}")
                return 0
            reencode_and_concat(items, output, workdir)

        print(f"已完成 CUDA/NVENC 合并：{output}")
        return 0
    except (subprocess.CalledProcessError, RuntimeError, OSError) as error:
        output.unlink(missing_ok=True)
        print(f"错误：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
