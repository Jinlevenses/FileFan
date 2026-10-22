#!/usr/bin/env python3
"""Verify pinned official macOS downloads and stage isolated engine copies."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOWNLOADS = ROOT / "artifacts/downloads"
DESTINATION = ROOT / "artifacts/runtime/optional-engines"
MANIFEST = ROOT / "artifacts/reference/Filee/src/Filee.Engines/Infrastructure/engines.json"
COMPONENTS = json.loads(MANIFEST.read_text())["platforms"]["osx-arm64"]["components"]


def verified(identifier):
    component = COMPONENTS[identifier]
    archive = DOWNLOADS / component["url"].split("/")[-1]
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    assert digest.lower() == component["sha256"].lower(), f"Checksum mismatch: {identifier}"
    return archive, dict(engine=identifier, version=component["version"], url=component["url"], archiveSHA256=digest)


def stage_zip():
    archive, provenance = verified("pandoc")
    target = DESTINATION / "pandoc"
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as source:
        item = next(item for item in source.infolist() if item.filename.endswith("/bin/pandoc"))
        with source.open(item) as stream, target.joinpath("pandoc").open("wb") as output:
            shutil.copyfileobj(stream, output)
    target.joinpath("pandoc").chmod(0o755)
    target.joinpath("download-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")


def stage_dmg(identifier, application):
    archive, provenance = verified(identifier)
    target = DESTINATION / identifier
    target.mkdir(parents=True, exist_ok=True)
    mount = ROOT / "artifacts/runtime/mounts" / identifier
    mount.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(archive)], check=True)
    try:
        source = mount / application
        assert source.is_dir(), f"Missing {application} in verified image"
        for link in source.rglob("*"):
            if link.is_symlink():
                assert link.resolve().is_relative_to(source.resolve()), f"External app symlink: {link}"
        shutil.copytree(source, target / application, symlinks=True, dirs_exist_ok=True, ignore=shutil.ignore_patterns("._*", ".DS_Store"))
    finally:
        subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True)
    target.joinpath("download-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")


if __name__ == "__main__":
    stage_zip()
    stage_dmg("libreoffice", "LibreOffice.app")
    stage_dmg("calibre", "calibre.app")
    for identifier in ("ffmpeg", "ghostscript"):
        shutil.copytree(ROOT / ".build/portable-engines" / identifier, DESTINATION / identifier, symlinks=True, dirs_exist_ok=True)
    print(f"Five verified/relocated engine packages staged at {DESTINATION}")
