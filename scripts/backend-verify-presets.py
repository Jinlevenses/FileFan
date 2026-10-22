#!/usr/bin/env python3
"""Read actual grayscale/resize pixels and a real 1080p → 720p transcode."""
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
QA = ROOT / ".build/release/FileFanBackendQA"
BACKEND = ROOT / "dist/FileFan.app/Contents/Resources/Backend/filee-cli"
BED = ROOT / "artifacts/evidence/backend-preset-fixtures"
BED.mkdir(parents=True, exist_ok=True)
IMAGE = ROOT / "artifacts/evidence/backend-fixtures/inputs/image.png"
FFMPEG = BACKEND.parent / "engines/ffmpeg/ffmpeg"
FFPROBE = BACKEND.parent / "engines/ffmpeg/ffprobe"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(arguments):
    result = subprocess.run(list(map(str, arguments)), capture_output=True, timeout=180)
    assert result.returncode == 0, result.stderr.decode(errors="replace") + result.stdout.decode(errors="replace")
    return result.stdout


def convert(name, target, source, *options):
    folder = BED / name
    folder.mkdir(exist_ok=True)
    before = digest(source)
    result = json.loads(run([QA, BACKEND, folder, target, source, *options]))
    assert result["successCount"] == 1 and result["failureCount"] == 0 and digest(source) == before
    return pathlib.Path(result["outputs"][0]), before


gray, image_hash = convert("grayscale", "preset:grayscale", IMAGE)
gray_info = json.loads(run([QA, "--image-info", gray]))
original_info = json.loads(run([QA, "--image-info", IMAGE]))
assert original_info["grayPixels"] == 0 and gray_info["grayPixels"] == 32 * 24
resized, _ = convert("resize", "preset:resize", IMAGE, "--max-pixels", "16")
size_info = json.loads(run([QA, "--image-info", resized]))
assert (size_info["width"], size_info["height"]) == (16, 12)
video = BED / "video-1080p.mp4"
run([FFMPEG, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=royalblue:s=1920x1080:r=5:d=0.4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", video])
output, video_hash = convert("mp4-720", "preset:mp4-720", video)
stream = json.loads(run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,codec_name,sample_aspect_ratio", "-of", "json", output]))["streams"][0]
assert stream["width"] == 1280 and stream["height"] == 720 and stream["codec_name"] == "h264" and stream["sample_aspect_ratio"] == "1:1"
report = dict(status="PASS", grayscale=dict(source=str(IMAGE), output=str(gray), sourcePixels=original_info, outputPixels=gray_info),
              resize=dict(source=str(IMAGE), output=str(resized), maxPixels=16, outputPixels=size_info),
              mp4_720=dict(source=str(video), sourceWidth=1920, sourceHeight=1080, output=str(output), outputStream=stream),
              sourceHashesUnchanged=True, imageSourceSHA256=image_hash, videoSourceSHA256=video_hash)
(ROOT / "artifacts/evidence/backend-preset-report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
