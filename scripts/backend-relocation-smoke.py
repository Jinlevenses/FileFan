#!/usr/bin/env python3
"""Run the resource/capability loader from an APFS clone while denying workspace reads."""
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="FileFanRelocated-", dir="/private/tmp") as temporary:
    moved = pathlib.Path(temporary) / "FileFan.app"
    subprocess.run(["/bin/cp", "-cR", str(ROOT / "dist/FileFan.app"), str(moved)], check=True)
    main = moved / "Contents/MacOS/FileFan"
    shutil.copy2(ROOT / ".build/release/FileFanBackendQA", main)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(moved)], check=True, capture_output=True)
    escaped = str(ROOT).replace("\\", "\\\\").replace('"', '\\"')
    profile = '(version 1) (allow default) (deny file-read* (subpath "' + escaped + '"))'
    result = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, str(main), "--bundle-probe"], capture_output=True, timeout=180)
    report = dict(workspaceReadDenied=True, workspace=str(ROOT), relocatedApp=str(moved), exitCode=result.returncode,
                  stdout=result.stdout.decode(errors="replace"), stderr=result.stderr.decode(errors="replace"))
    if result.returncode == 0:
        report["probe"] = json.loads(result.stdout)
        assert report["probe"]["formats"] == 244 and report["probe"]["categories"] == 17
        assert report["probe"]["availablePNGTargets"] > 0
    destination = ROOT / "artifacts/evidence/backend-relocation-smoke.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    assert result.returncode == 0
