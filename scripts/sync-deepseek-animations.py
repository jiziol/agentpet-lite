#!/usr/bin/env python3
"""Import the pinned upstream transparent MOV pack, keeping existing sprite files.

Requires macOS/Xcode. --pack should point to a staging copy first. Source/asset
versions and checksums are fixed; reruns never silently follow upstream main.
"""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

COMMIT = "e4c8c2af8b8b982d199d39fdec9de3ed5f84ecc5"
ASSET_SHA256 = "b3fe34fa42f28d297da8525cd08d0ac2706c96c14d3cf1eb386137a59b79a3c0"
ARCHIVE_URL = "https://github.com/PC2005-cloud/dsh-pet/releases/download/assets-mov/dsh-pet-mov-assets-mov.zip"
RAW_ROOT = f"https://raw.githubusercontent.com/PC2005-cloud/dsh-pet/{COMMIT}/"


def classifications(readme):
    section = readme.split("## 效果预览", 1)[1].split("## 从零生成", 1)[0]
    category = None
    result = {}
    for line in section.splitlines():
        heading = re.match(r"^\*\*(.+?)\*\*", line)
        if heading:
            category = heading.group(1)
        for name in re.findall(r'alt="([^"]+)"', line):
            if not category:
                raise ValueError("Preview missing upstream category")
            result[html.unescape(name)] = category
    if len(result) != 106:
        raise ValueError(f"Pinned README expected 106 actions, found {len(result)}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--archive", type=Path, help="Use an already downloaded, checksum-verified release archive")
    parser.add_argument("--readme", type=Path, help="Use pinned README content from an earlier download")
    args = parser.parse_args()
    pack = args.pack.resolve()
    if not (pack / "pet.json").is_file() or not (pack / "spritesheet.webp").is_file():
        raise ValueError("Copy the existing deepseek pack to the staging directory first")
    with tempfile.TemporaryDirectory(prefix="agentpet-animation-") as temp:
        scratch = Path(temp)
        archive = args.archive
        if archive is None:
            archive = scratch / "assets-mov.zip"
            urllib.request.urlretrieve(ARCHIVE_URL, archive)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != ASSET_SHA256:
            raise ValueError("Upstream release checksum mismatch")
        readme = args.readme.read_text() if args.readme else urllib.request.urlopen(RAW_ROOT + "README.md").read().decode()
        categories = classifications(readme)
        with zipfile.ZipFile(archive) as z:
            for entry in z.infolist():
                p = Path(entry.filename)
                if p.is_absolute() or ".." in p.parts or ((entry.external_attr >> 16) & 0o170000) == 0o120000:
                    raise ValueError("Unsafe release archive entry")
            z.extractall(scratch / "extracted")
        movies = [p for p in (scratch / "extracted").rglob("*.mov") if not p.name.startswith("._")]
        if len(movies) != 106 or {p.stem for p in movies} != set(categories):
            raise ValueError("MOV release and pinned README action names differ")
        movie_dir = pack / "videos"
        movie_dir.mkdir(exist_ok=True)
        for movie in movies:
            shutil.copy2(movie, movie_dir / movie.name)
        metadata_path = scratch / "native-decode.json"
        tool = Path(__file__).with_name("prepare-pet-animation.swift")
        subprocess.run(["swift", str(tool), str(movie_dir), str(metadata_path)], check=True)
        decoded = json.loads(metadata_path.read_text())
        if len(decoded) != 106:
            raise ValueError("Incomplete native validation")
        entries = []
        for item in decoded:
            file = movie_dir / item["file"]
            entries.append({"id": "dsh:" + item["name"], "name": item["name"],
                            "category": categories[item["name"]], "file": "videos/" + file.name,
                            "poster": "posters/" + item["poster"], "duration": item["duration"],
                            "width": item["width"], "height": item["height"],
                            "sha256": hashlib.sha256(file.read_bytes()).hexdigest()})
        catalog = {"version": 1, "clips": entries}
        provenance = {"repository": "https://github.com/PC2005-cloud/dsh-pet", "readmeCommit": COMMIT,
                      "mediaRelease": "assets-mov", "archiveURL": ARCHIVE_URL, "archiveSHA256": digest,
                      "animationCount": 106, "nativeDecode": decoded,
                      "scope": "Animation media only; no DSH plugin, models, balance or physics services imported"}
        (pack / "LICENSE.dsh-pet").write_bytes(urllib.request.urlopen(RAW_ROOT + "LICENSE").read())
        (pack / "animation-source.json").write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n")
        target = pack / "animations.json"
        temporary = target.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(target)
        print(f"PASS: 106 actions in {len(set(categories.values()))} upstream categories; original sprite files preserved")


if __name__ == "__main__":
    main()
