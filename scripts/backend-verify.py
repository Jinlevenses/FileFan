#!/usr/bin/env python3
"""Actual bundled-engine fixtures through the Swift adapter, with semantic readback."""
import hashlib
import json
import math
import pathlib
import shutil
import struct
import subprocess
import sys
import time
import traceback
import wave
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "dist/FileFan.app"
BACKEND = APP / "Contents/Resources/Backend/filee-cli"
QA = ROOT / ".build/release/FileFanBackendQA"
BED = ROOT / "artifacts/evidence/backend-fixtures"
INPUT = BED / "inputs"
OUTPUT = BED / "outputs"
REPORT = ROOT / "artifacts/evidence/backend-17-family-report.json"
FFMPEG = BACKEND.parent / "engines/ffmpeg/ffmpeg"
FFPROBE = BACKEND.parent / "engines/ffmpeg/ffprobe"
report = dict(backend=str(BACKEND), startedUTC=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), cases=[], conversions=[])
hashes = {}


def run(arguments, timeout=180):
    result = subprocess.run(list(map(str, arguments)), capture_output=True, timeout=timeout)
    assert result.returncode == 0, f"Exit {result.returncode}: {arguments}\n{result.stdout.decode(errors='replace')}\n{result.stderr.decode(errors='replace')}"
    return result.stdout


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save():
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


def convert(name, target, *sources, pages=None):
    directory = OUTPUT / name
    directory.mkdir(parents=True, exist_ok=True)
    for source in sources:
        hashes[source] = digest(source)
    arguments = [QA, BACKEND, directory, target, *sources]
    if pages:
        arguments += ["--pages", pages]
    result = json.loads(run(arguments))
    assert result["failureCount"] == 0 and result["successCount"] == len(sources), result
    for source in sources:
        assert digest(source) == hashes[source], f"Source changed: {source}"
    outputs = [pathlib.Path(path) for path in result["outputs"]]
    assert outputs and all(path.exists() for path in outputs), result
    report["conversions"].append(dict(name=name, target=target, sources=[str(path) for path in sources],
                                      outputs=[str(path) for path in outputs], notices=[item["notice"] for item in result["files"] if item["notice"]],
                                      sourceSHA256={str(path): hashes[path] for path in sources}))
    save()
    return outputs


def only(outputs):
    assert len(outputs) == 1, outputs
    return outputs[0]


def pages(path):
    return json.loads(run([QA, "--pdf-info", path]))["pages"]


def zip_text(path, pattern):
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if pattern(name)]
        assert names, (path, archive.namelist())
        return "\n".join(archive.read(name).decode("utf-8", errors="replace") for name in names)


def media(path):
    return json.loads(run([FFPROBE, "-v", "error", "-show_streams", "-show_format", "-of", "json", path]))


def case(name, family, operation):
    started = time.monotonic()
    try:
        details = operation() or {}
        report["cases"].append(dict(name=name, family=family, status="PASS", seconds=round(time.monotonic() - started, 3), details=details))
        print("PASS", name, flush=True)
    except Exception as error:
        report["cases"].append(dict(name=name, family=family, status="FAIL", seconds=round(time.monotonic() - started, 3), error=str(error), traceback=traceback.format_exc()))
        print("FAIL", name, str(error)[:500], flush=True)
    save()


def build_archives():
    payload = "FileFan 알집/에그 테스트".encode()
    name = "문서.txt"
    encoded = name.encode("cp949")
    alz = b"ALZ\x01\x0a\x00\x00\x00BLZ\x01" + struct.pack("<HBI", len(encoded), 0x20, 0x52A63805) + bytes([0x40, 0, 0, 0])
    alz += struct.pack("<III", zlib.crc32(payload), len(payload), len(payload)) + encoded + payload
    alz += b"CLZ\x01" + bytes(12) + b"CLZ\x02" + bytes(12)
    (INPUT / "sample.alz").write_bytes(alz)
    encoded = name.encode()
    end = struct.pack("<I", 0x08E28222)
    egg = struct.pack("<IHII", 0x41474745, 0x100, 0x12345678, 0) + end
    egg += struct.pack("<IIq", 0x0A8590E3, 0, len(payload))
    egg += struct.pack("<IBH", 0x0A8591AC, 0, len(encoded)) + encoded + end
    egg += struct.pack("<IBBIII", 0x02B50C13, 0, 0, len(payload), len(payload), zlib.crc32(payload)) + end + payload + end
    (INPUT / "sample.egg").write_bytes(egg)
    return payload


def prepare():
    INPUT.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    run([QA, "--fixtures", INPUT])
    (INPUT / "document.txt").write_text("FileFan offline document\n한글 문서 변환 확인\n", encoding="utf-8")
    (INPUT / "sheet.csv").write_text("name,score\nAlice,10\nBob,20\n", encoding="utf-8")
    (INPUT / "markup.md").write_text("# FileFan Offline\n\n- Preserved text\n- No upload\n", encoding="utf-8")
    (INPUT / "drawing.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect x="10" y="10" width="80" height="40" fill="red"/></svg>')
    (INPUT / "subtitle.srt").write_text("1\n00:00:00,000 --> 00:00:00,300\nFileFan subtitle\n", encoding="utf-8")
    (INPUT / "korean.smi").write_bytes('<SAMI><BODY><SYNC Start=0><P Class=KRCC>안녕하세요<SYNC Start=1000><P Class=KRCC>&nbsp;</BODY></SAMI>'.encode("cp949"))
    (INPUT / "contact.vcf").write_text("BEGIN:VCARD\nVERSION:3.0\nFN:FileFan Example\nN:Example;FileFan;;;\nTEL:+1-202-555-0100\nEND:VCARD\n")
    (INPUT / "model.obj").write_text("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n")
    (INPUT / "line.dxf").write_text("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1027\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nLINE\n5\n10\n100\nAcDbEntity\n8\n0\n100\nAcDbLine\n10\n0.0\n20\n0.0\n30\n0.0\n11\n10.0\n21\n5.0\n31\n0.0\n0\nENDSEC\n0\nEOF\n")
    fonts = ROOT / "artifacts/reference/Filee/tests/Filee.Engines.Tests/Fonts"
    shutil.copy2(fonts / "FileeTest-TrueType.ttf", INPUT / "test-font.ttf")
    shutil.copy2(fonts / "OFL.txt", INPUT / "font-OFL.txt")
    with wave.open(str(INPUT / "audio.wav"), "wb") as audio:
        audio.setparams((1, 2, 8000, 1600, "NONE", "not compressed"))
        audio.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(index * 2 * math.pi * 440 / 8000))) for index in range(1600)))
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=96x72:rate=5:duration=0.4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", INPUT / "video.mp4"])
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-i", INPUT / "video.mp4", "-i", INPUT / "subtitle.srt", "-c:v", "copy", "-c:s", "mov_text", "-y", INPUT / "video-subtitles.mp4"])
    return build_archives()


def main():
    archive_payload = prepare()
    def image():
        heic = only(convert("image-heic", "format:heic", INPUT / "image.png"))
        png = only(convert("image-readback", "format:png", heic))
        width, height = struct.unpack(">II", png.read_bytes()[16:24]); assert (width, height) == (32, 24)
        return dict(width=width, height=height, heicBytes=heic.stat().st_size)
    case("PNG → HEIC → PNG dimensions", "Image", image)
    def vector():
        output = only(convert("vector-pdf", "format:pdf", INPUT / "drawing.svg")); assert pages(output) == 1
        return dict(pdfPages=1)
    case("SVG → vector PDF", "Vector", vector)
    def pdf_actions():
        source = INPUT / "three-pages.pdf"
        merged = only(convert("pdf-merge", "preset:merge-pdf", source, only(convert("pdf-merge-copy", "preset:pdf-pages", source, pages="1-3"))))
        assert pages(merged) == 6
        split = convert("pdf-split", "preset:pdf-split", source); assert len(split) == 3 and all(pages(path) == 1 for path in split)
        ranged = only(convert("pdf-range", "preset:pdf-pages", source, pages="2-3")); assert pages(ranged) == 2
        compressed = only(convert("pdf-compress", "preset:compress-pdf", source)); assert pages(compressed) == 3 and compressed.stat().st_size <= source.stat().st_size
        slides = only(convert("pdf-slides", "preset:pdf-slides", source))
        with zipfile.ZipFile(slides) as archive:
            slide_names = [name for name in archive.namelist() if name.startswith("ppt/slides/slide") and name.endswith(".xml")]
            count = len(slide_names); assert count == 3
            assert all(any(node.tag.endswith("}pic") for node in ET.fromstring(archive.read(name)).iter()) for name in slide_names)
            pictures = [archive.read(name) for name in archive.namelist() if name.startswith("ppt/media/")]
            assert len(pictures) == 3 and len({hashlib.sha256(picture).hexdigest() for picture in pictures}) == 3
        return dict(mergePages=6, splitFiles=3, rangePages=2, compressedPages=3, pictureSlides=3, slides=str(slides))
    case("PDF merge/split/compress/ranges/picture PPTX", "Pdf", pdf_actions)
    def documents():
        docx = only(convert("document-docx", "format:docx", INPUT / "document.txt"))
        assert "FileFan" in zip_text(docx, lambda name: name == "word/document.xml")
        legacy = only(convert("document-legacy", "format:doc", docx)); assert legacy.read_bytes().startswith(bytes.fromhex("d0cf11e0a1b11ae1"))
        back = only(convert("document-readback", "format:docx", legacy)); assert "FileFan" in zip_text(back, lambda name: name == "word/document.xml")
        return dict(legacyCompoundDocument=True, textRoundTrip=True)
    case("DOCX ↔ legacy DOC content", "Document", documents)
    def spreadsheet():
        xlsx = only(convert("spreadsheet-xlsx", "format:xlsx", INPUT / "sheet.csv"))
        text = zip_text(xlsx, lambda name: name.startswith("xl/") and name.endswith(".xml")); assert "Alice" in text and "20" in text
        ods = only(convert("spreadsheet-ods", "format:ods", xlsx)); assert "Alice" in zip_text(ods, lambda name: name == "content.xml")
        return dict(namesAndScoresPreserved=True)
    case("CSV → XLSX → ODS cells", "Spreadsheet", spreadsheet)
    def presentation():
        slides = only(convert("presentation-seed", "preset:pdf-slides", INPUT / "three-pages.pdf"))
        pdf = only(convert("presentation-pdf", "format:pdf", slides)); assert pages(pdf) == 3
        return dict(pages=3)
    case("PPTX → PDF slide count", "Presentation", presentation)
    def hwp():
        hwpx = only(convert("hwp-hwpx", "format:hwpx", INPUT / "document.txt"))
        assert "한글" in zip_text(hwpx, lambda name: name.startswith("Contents/") and name.endswith(".xml"))
        legacy = only(convert("hwp-legacy", "format:hwp", hwpx)); assert legacy.read_bytes().startswith(bytes.fromhex("d0cf11e0a1b11ae1"))
        back = only(convert("hwp-readback", "format:hwpx", legacy)); assert "한글" in zip_text(back, lambda name: name.startswith("Contents/") and name.endswith(".xml"))
        return dict(koreanTextRoundTrip=True, hwpCompoundDocument=True)
    case("HWPX ↔ HWP Korean text", "Hwp", hwp)
    def markup():
        rst = only(convert("text-rst", "format:rst", INPUT / "markup.md")); assert "FileFan Offline" in rst.read_text()
        pptx = only(convert("text-pptx", "format:pptx", INPUT / "markup.md")); assert "FileFan" in zip_text(pptx, lambda name: name.startswith("ppt/slides/") and name.endswith(".xml"))
        return dict(pandocRst=True, markdownPptx=True)
    case("Markdown → RST and PPTX", "Text", markup)
    def video():
        webm = only(convert("video-webm", "format:webm", INPUT / "video.mp4")); info = media(webm); stream = next(s for s in info["streams"] if s["codec_type"] == "video")
        assert (stream["width"], stream["height"]) == (96, 72)
        mp4 = only(convert("video-720", "preset:mp4-720", INPUT / "video.mp4")); assert next(s for s in media(mp4)["streams"] if s["codec_type"] == "video")["height"] == 72
        for preset, codec in [("mp4-hevc", "hevc"), ("mp4-av1", "av1")]:
            converted = only(convert("video-" + codec, "preset:" + preset, INPUT / "video.mp4")); assert next(s for s in media(converted)["streams"] if s["codec_type"] == "video")["codec_name"] == codec
        return dict(width=96, height=72, codecs=["webm", "h264", "hevc", "av1"])
    case("Video dimensions and H264/HEVC/AV1 presets", "Video", video)
    def audio():
        flac = only(convert("audio-flac", "format:flac", INPUT / "audio.wav")); stream = media(flac)["streams"][0]
        assert int(stream["sample_rate"]) == 8000 and stream["channels"] == 1
        back = only(convert("audio-readback", "format:wav", flac))
        with wave.open(str(back), "rb") as result, wave.open(str(INPUT / "audio.wav"), "rb") as original:
            assert result.readframes(result.getnframes()) == original.readframes(original.getnframes())
        return dict(sampleRate=8000, channels=1, pcmRoundTrip=True)
    case("WAV ↔ FLAC lossless PCM", "Audio", audio)
    def ebook():
        epub = only(convert("ebook-epub", "format:epub", INPUT / "document.txt")); assert "FileFan" in zip_text(epub, lambda name: name.endswith((".html", ".xhtml")))
        mobi = only(convert("ebook-mobi", "format:mobi", epub)); assert b"BOOKMOBI" in mobi.read_bytes()[:100]
        back = only(convert("ebook-readback", "format:epub", mobi)); assert "FileFan" in zip_text(back, lambda name: name.endswith((".html", ".xhtml")))
        return dict(mobiHeader=True, textRoundTrip=True)
    case("EPUB ↔ MOBI text", "Ebook", ebook)
    def archives():
        packed = only(convert("archive-combine", "preset:zip-all", INPUT / "document.txt", INPUT / "image.png"))
        seven = only(convert("archive-7z", "format:7z", packed)); assert seven.read_bytes().startswith(b"7z\xbc\xaf\x27\x1c")
        extracted = only(convert("archive-extract", "preset:extract", seven)); assert (extracted / "document.txt").read_bytes() == (INPUT / "document.txt").read_bytes()
        for extension in ("alz", "egg"):
            folder = only(convert("archive-" + extension, "preset:extract", INPUT / ("sample." + extension)))
            assert (folder / "문서.txt").read_bytes() == archive_payload
        return dict(zipSevenZipContents=True, alzCp949Name=True, eggUtf8Name=True)
    case("ZIP/7Z plus ALZ/EGG extraction bytes", "Archive", archives)
    def cad():
        dwg = only(convert("cad-dwg", "format:dwg", INPUT / "line.dxf")); assert dwg.read_bytes().startswith(b"AC1032")
        dxf = only(convert("cad-readback", "format:dxf", dwg)); assert b"LINE" in dxf.read_bytes()
        svg = only(convert("cad-svg", "format:svg", dwg)); root = ET.parse(svg).getroot(); assert any(node.tag.endswith(("path", "line")) for node in root.iter())
        return dict(dwg2018Header=True, lineEntityRoundTrip=True, svgGeometry=True)
    case("DXF ↔ DWG and SVG geometry", "Cad", cad)
    def fonts():
        woff = only(convert("font-woff2", "format:woff2", INPUT / "test-font.ttf")); assert woff.read_bytes().startswith(b"wOF2")
        back = only(convert("font-readback", "format:ttf", woff))
        def glyph_count(path):
            data = path.read_bytes(); count = struct.unpack_from(">H", data, 4)[0]
            for i in range(count):
                tag, _, offset, _ = struct.unpack_from(">4sIII", data, 12 + i * 16)
                if tag == b"maxp": return struct.unpack_from(">H", data, offset + 4)[0]
            raise AssertionError("Missing maxp table")
        count = glyph_count(back); assert count == glyph_count(INPUT / "test-font.ttf") and count > 0
        return dict(glyphCount=count)
    case("TTF ↔ WOFF2 glyph count", "Font", fonts)
    def subtitles():
        srt = only(convert("subtitle-cp949", "format:srt", INPUT / "korean.smi")); assert "안녕하세요" in srt.read_text(encoding="utf-8")
        extracted = only(convert("subtitle-extract", "preset:extract-subtitles", INPUT / "video-subtitles.mp4")); assert "FileFan subtitle" in extracted.read_text()
        return dict(cp949KoreanDecoded=True, embeddedTextSubtitleExtracted=True)
    case("CP949 SAMI and embedded subtitle extraction", "Subtitle", subtitles)
    def data():
        output = only(convert("data-json", "format:json", INPUT / "contact.vcf")); parsed = json.loads(output.read_text()); assert "FileFan Example" in json.dumps(parsed)
        return dict(vcardNamePreserved=True)
    case("vCard → JSON contact fields", "Data", data)
    def model():
        glb = only(convert("model-glb", "format:glb", INPUT / "model.obj")); assert glb.read_bytes().startswith(b"glTF")
        stl = only(convert("model-stl", "format:stl", glb)); data = stl.read_bytes(); assert struct.unpack_from("<I", data, 80)[0] == 1
        return dict(glbHeader=True, triangleCount=1)
    case("OBJ → GLB → STL triangle", "Model3D", model)
    report["sourceHashesUnchanged"] = all(digest(path) == expected for path, expected in hashes.items())
    report["sourceCount"] = len(hashes)
    report["passed"] = sum(item["status"] == "PASS" for item in report["cases"])
    report["failed"] = len(report["cases"]) - report["passed"]
    report["families"] = sorted({item["family"] for item in report["cases"] if item["status"] == "PASS"})
    save()
    print(json.dumps({key: report[key] for key in ("passed", "failed", "sourceHashesUnchanged", "sourceCount", "families")}, ensure_ascii=False), flush=True)
    return 0 if report["failed"] == 0 and report["sourceHashesUnchanged"] else 1


if __name__ == "__main__":
    sys.exit(main())
