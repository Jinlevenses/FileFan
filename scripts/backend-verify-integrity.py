#!/usr/bin/env python3
"""Verify the final signed bundle and every file in its pinned backend manifest."""
import hashlib
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "dist/FileFan.app"
backend = APP / "Contents/Resources/Backend"
manifest = backend / "backend-manifest.json"
metadata = json.loads(manifest.read_text())
mismatches = []
for relative, expected in metadata["files"].items():
    path = backend / relative
    if not path.is_file() or hashlib.file_digest(path.open("rb"), "sha256").hexdigest() != expected:
        mismatches.append(relative)
main = APP / "Contents/MacOS/FileFan"
report = dict(mainSHA256=hashlib.file_digest(main.open("rb"), "sha256").hexdigest(),
              backendManifestSHA256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
              checkedBackendFiles=len(metadata["files"]), mismatches=mismatches,
              engines=metadata["availableEngineCount"], currentRoutes=metadata["currentRouteCount"], optionalRoutes=metadata["optionalRouteCount"],
              bundleCodesignVerified=subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(APP)], capture_output=True).returncode == 0,
              generatedUTC=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
(ROOT / "artifacts/evidence/final-backend-release-integrity.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
assert not mismatches and report["bundleCodesignVerified"]
