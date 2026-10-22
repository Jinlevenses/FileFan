#!/usr/bin/env python3
"""Verify actual PDF size reduction on a 300 dpi lossless image, retaining page geometry."""
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
QA = ROOT / ".build/release/FileFanBackendQA"
BACKEND = ROOT / "dist/FileFan.app/Contents/Resources/Backend/filee-cli"
DIRECTORY = ROOT / "artifacts/evidence/backend-compression-fixture"
DIRECTORY.mkdir(parents=True, exist_ok=True)
source = DIRECTORY / "image-300dpi.pdf"
subprocess.run([str(QA), "--compression-fixture", str(source)], check=True)
before = hashlib.sha256(source.read_bytes()).hexdigest()
output = DIRECTORY / "converted"
output.mkdir(exist_ok=True)
conversion = subprocess.run([str(QA), str(BACKEND), str(output), "preset:compress-pdf", str(source)], check=True, capture_output=True)
result = json.loads(conversion.stdout)
assert result["failureCount"] == 0 and result["successCount"] == 1
compressed = pathlib.Path(result["outputs"][0])
info = lambda path: json.loads(subprocess.check_output([str(QA), "--pdf-info", str(path)]))
original_info, compressed_info = info(source), info(compressed)
assert original_info == compressed_info == {"pages": 1, "pageSizes": [{"width": 288, "height": 216}]}
assert compressed.stat().st_size < source.stat().st_size
assert hashlib.sha256(source.read_bytes()).hexdigest() == before
readbacks = []
for label, path in [("original", source), ("compressed", compressed)]:
    png = DIRECTORY / (label + "-readback.png")
    raster = json.loads(subprocess.check_output([str(QA), "--pdf-render-check", str(path), str(png)]))
    assert raster["width"] == 288 and raster["height"] == 216 and raster["visiblePixels"] > 288 * 216 * 0.95
    readbacks.append(dict(kind=label, image=str(png), **raster))
report = dict(status="PASS", fixture="1200x900 RGB deterministic noise, lossless PDF placement at 300 dpi; no padding",
              source=str(source), output=str(compressed), sourceSHA256=before, sourceUnchanged=True,
              originalBytes=source.stat().st_size, compressedBytes=compressed.stat().st_size,
              reductionPercent=round(100 * (1 - compressed.stat().st_size / source.stat().st_size), 2),
              originalPDF=original_info, compressedPDF=compressed_info, coreGraphicsRasterReadbacks=readbacks,
              notices=[file["notice"] for file in result["files"] if file["notice"]])
(ROOT / "artifacts/evidence/backend-pdf-compression-report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
