#!/usr/bin/env python3
"""Assemble only the verified Filee CLI dependency closure and bundled engines."""
import hashlib
import json
import pathlib
import shutil
import os
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ARCHIVE = ROOT / "artifacts/downloads/Filee-1.12.0-osx-arm64.tar.gz"
EXPECTED = "7ab779a73a81d36f6867eee10d81b8bd2375d14800673ce31c17aa8c7326e096"
SOURCE = ROOT / "artifacts/runtime/Filee/Filee-1.12.0-osx-arm64/Filee.app/Contents/MacOS"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def refresh_hashes(destination):
    manifest = destination / "backend-manifest.json"
    metadata = json.loads(manifest.read_text())
    metadata["files"] = {str(path.relative_to(destination)): sha256(path)
                         for path in sorted(destination.rglob("*")) if path.is_file() and path != manifest}
    manifest.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")


def package(destination):
    assert ARCHIVE.is_file(), "Fetch the pinned official self-contained release first"
    assert sha256(ARCHIVE) == EXPECTED, "Pinned backend archive checksum mismatch"
    assert SOURCE.joinpath("filee-cli").is_file(), "Extract the pinned official release first"
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    deps = json.loads(SOURCE.joinpath("filee-cli.deps.json").read_text())
    paths = {"filee-cli", "filee-cli.dll", "filee-cli.deps.json", "filee-cli.runtimeconfig.json"}
    for library in deps["targets"][deps["runtimeTarget"]["name"]].values():
        for kind in ("runtime", "native", "resources"):
            paths.update(library.get(kind, {}))
    for name in sorted(paths):
        relative = pathlib.Path(name)
        assert not relative.is_absolute() and ".." not in relative.parts
        source = SOURCE / relative
        target = destination / relative
        if not source.is_file():
            localized = pathlib.Path(*relative.parts[-2:])
            relative = localized if SOURCE.joinpath(localized).is_file() else pathlib.Path(relative.name)
            source = SOURCE / relative
            target = destination / relative
        assert source.is_file(), f"Missing CLI dependency: {name}"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    if SOURCE.joinpath("engines").is_dir():
        shutil.copytree(SOURCE / "engines", destination / "engines", ignore=shutil.ignore_patterns("._*", ".DS_Store"))
    extras = ROOT / "artifacts/runtime/optional-engines"
    if extras.is_dir():
        for engine in extras.iterdir():
            if engine.is_dir():
                shutil.copytree(engine, destination / "engines" / engine.name, dirs_exist_ok=True, symlinks=True, ignore=shutil.ignore_patterns("._*", ".DS_Store"))
    capabilities = ROOT / ".build/backend-capabilities"
    assert capabilities.joinpath("filefan-caps").is_file(), "Build the product-owned capability bridge with scripts/backend-capabilities-build.sh"
    for name in ("filefan-caps", "filefan-caps.dll", "filefan-caps.runtimeconfig.json", "filefan-caps.deps.json"):
        shutil.copy2(capabilities / name, destination / name)
    for item in ROOT.joinpath("Resources/BackendLicenses").iterdir():
        shutil.copy2(item, destination / item.name)
    with tempfile.TemporaryDirectory(prefix="filefan-capabilities-") as data:
        variables = os.environ.copy()
        variables["FILEE_DATA_DIR"] = data
        variables["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        probe = subprocess.run([str(destination / "filefan-caps")], env=variables, capture_output=True, timeout=180, check=True)
        graph = json.loads(probe.stdout)
    assert graph["schemaVersion"] == 1 and len(graph["formats"]) == 245
    graph["archiveSHA256"] = EXPECTED
    graph["sourceCommit"] = "49911afab6eef81f144543710f1aa8021c617ff1"
    destination.joinpath("capability-manifest.json").write_text(json.dumps(graph, ensure_ascii=False, indent=2) + "\n")
    metadata = {
        "backend": "Filee.Cli", "version": "1.12.0",
        "upstream": "https://github.com/KnifeLemon/Filee",
        "sourceCommit": "49911afab6eef81f144543710f1aa8021c617ff1",
        "archiveSHA256": EXPECTED,
        "protocol": "convert --preset <isolated JSON recipe> -o <private staging> --json",
        "formatInventoryCount": 244, "formatCategoryCount": 17,
        "availability": "Probed from executable at runtime; inventory is not support",
        "availableEngineCount": sum(engine["available"] for engine in graph["engines"]),
        "currentRouteCount": sum(len(item["current"]) for item in graph["formats"]),
        "optionalRouteCount": sum(len(item["optional"]) for item in graph["formats"]),
        "files": {str(path.relative_to(destination)): sha256(path) for path in sorted(destination.rglob("*")) if path.is_file()},
    }
    destination.joinpath("backend-manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    assert not any(destination.glob("Avalonia*")), "GUI assemblies unexpectedly included"
    print(f"Backend assembled: {destination} ({len(metadata['files'])} files)")


if __name__ == "__main__":
    if sys.argv[1] == "--rehash":
        refresh_hashes(pathlib.Path(sys.argv[2]).resolve())
    else:
        package(pathlib.Path(sys.argv[1]).resolve())
