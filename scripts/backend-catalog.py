#!/usr/bin/env python3
"""Regenerate the pinned upstream format inventory (inventory is not availability)."""
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
upstream = root / "artifacts/reference/Filee"
source = (upstream / "src/Filee.Core/Formats/FormatRegistry.cs").read_text()
pattern = r'new\("([^"]+)",\s*"([^"]+)",\s*FormatCategory\.(\w+),\s*\[([^]]+)\](?:,\s*Writable:\s*(false|true))?\)'
formats = [dict(id=identifier, name=name, category=category,
                extensions=re.findall(r'"([^"]+)"', extensions), writable=writable != "false")
           for identifier, name, category, extensions, writable in re.findall(pattern, source, re.S)]
assert len(formats) >= 200, len(formats)
assert len({f["category"] for f in formats}) == 17
assert len({f["id"] for f in formats}) == len(formats)
destination = root / "Sources/FileFanCore/Resources/formats.json"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(formats, ensure_ascii=False, indent=2) + "\n")
print(f"{len(formats)} known formats, 17 categories; live engine probing determines routes")
