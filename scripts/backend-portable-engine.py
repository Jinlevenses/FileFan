#!/usr/bin/env python3
"""Copy a local macOS engine's Mach-O closure; never modifies installed tools."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True)


def dependencies(path):
    return [line.strip().split(" (compatibility", 1)[0] for line in run("/usr/bin/otool", "-L", str(path)).splitlines()[1:]]


def system(path):
    return path.startswith(("/usr/lib/", "/System/Library/"))


def resolve(name, owner, executable):
    if name.startswith("@loader_path/"):
        return (owner.parent / name[len("@loader_path/"):]).resolve()
    if name.startswith("@executable_path/"):
        return (executable.parent / name[len("@executable_path/"):]).resolve()
    if name.startswith("@rpath/"):
        suffix = name[len("@rpath/"):]
        paths = re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path ([^\n]+) \(offset", run("/usr/bin/otool", "-l", str(owner)))
        for path in paths:
            base = pathlib.Path(path.replace("@loader_path", str(owner.parent)).replace("@executable_path", str(executable.parent)))
            if (base / suffix).is_file():
                return (base / suffix).resolve()
        for base in (owner.parent, pathlib.Path("/opt/homebrew/lib")):
            if (base / suffix).is_file():
                return (base / suffix).resolve()
        raise RuntimeError(f"Unresolved {name} from {owner}")
    return pathlib.Path(name).resolve()


def package(identifier, programs, destination):
    destination.mkdir(parents=True, exist_ok=True)
    library_dir = destination / "lib"
    library_dir.mkdir(exist_ok=True)
    mapped = {}
    owners = {}
    originals = {}
    pending = []
    for program in programs:
        source = pathlib.Path(program).resolve()
        mapped[source] = destination / pathlib.Path(program).name
        originals[source] = source
        pending.append((source, source))
    edges = {}
    while pending:
        owner, executable = pending.pop()
        if owner in edges:
            continue
        edges[owner] = []
        for name in dependencies(owner):
            if system(name):
                continue
            source = resolve(name, owner, executable)
            # Dylib LC_ID_DYLIB appears in otool -L too.
            if source == owner:
                continue
            assert source.is_file(), source
            if source not in mapped:
                basename = source.name
                if basename in owners and owners[basename] != source:
                    basename = hashlib.sha256(str(source).encode()).hexdigest()[:8] + "-" + basename
                owners[basename] = source
                mapped[source] = library_dir / basename
                originals[source] = executable
                pending.append((source, executable))
            edges[owner].append((name, source))
    prefixes = set()
    for source, target in mapped.items():
        shutil.copy2(source, target)
        target.chmod(target.stat().st_mode | 0o200)
        subprocess.run(["/usr/bin/codesign", "--remove-signature", str(target)], capture_output=True)
        for old, dependency in edges[source]:
            relative = os.path.relpath(mapped[dependency], target.parent)
            subprocess.run(["/usr/bin/install_name_tool", "-change", old, "@loader_path/" + relative, str(target)], check=True, capture_output=True)
        if target.parent == library_dir:
            subprocess.run(["/usr/bin/install_name_tool", "-id", "@loader_path/" + target.name, str(target)], check=True, capture_output=True)
        for dependency in dependencies(target):
            assert system(dependency) or dependency.startswith("@loader_path/"), (target, dependency)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(target)], check=True, capture_output=True)
        if source.parts[:4] == ("/", "opt", "homebrew", "Cellar"):
            prefixes.add(pathlib.Path(*source.parts[:6]))
    licenses = destination / "licenses"
    licenses.mkdir(exist_ok=True)
    receipts = {}
    for prefix in sorted(prefixes):
        package_dir = licenses / prefix.parent.name
        package_dir.mkdir(exist_ok=True)
        receipt = prefix / "INSTALL_RECEIPT.json"
        if receipt.is_file():
            installed = json.loads(receipt.read_text())
            source = installed.get("source", {})
            receipts[prefix.parent.name] = {
                "version": source.get("versions", {}).get("stable"), "tap": source.get("tap"),
                "bottle": installed.get("poured_from_bottle"), "compiler": installed.get("compiler"),
                "builtAsBottle": installed.get("built_as_bottle"),
            }
        candidates = list(prefix.glob("*"))
        docs = prefix / "share/doc"
        if docs.is_dir():
            candidates += list(docs.rglob("*"))
        for path in candidates:
            if path.is_file() and re.match(r"(?i)^(license|copying|copyright|notice|authors)", path.name):
                relative = str(path.relative_to(prefix)).replace("/", "_")
                shutil.copy2(path, package_dir / relative)
    if identifier == "ghostscript":
        prefix = pathlib.Path(programs[0]).resolve().parent.parent
        shutil.copytree(prefix / "share/ghostscript", destination / "share/ghostscript", dirs_exist_ok=True)
    metadata = dict(engine=identifier, programs=[pathlib.Path(program).name for program in programs], sourceReceipts=receipts,
                    relocation="Non-system dependencies use @loader_path; source tools unchanged",
                    files={str(target.relative_to(destination)): hashlib.sha256(target.read_bytes()).hexdigest() for target in mapped.values()})
    (destination / "portable-engine.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(f"{identifier}: {len(mapped)} relocated Mach-O files at {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("engine")
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("programs", nargs="+")
    args = parser.parse_args()
    package(args.engine, args.programs, args.destination.resolve())
