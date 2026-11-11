#!/usr/bin/env python3
"""Build a new external pet pack from manually reviewed, previously verified MOVs.

The review and source pack are read-only. --pack must not exist. Retains the
original sprites/license; only selected movies/posters enter the new catalog.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

GROUPS = ["idle", "working", "waiting", "success", "failure", "quota", "levelup", "tap", "drag"]


def local(root, name):
    path = Path(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name:
        raise ValueError("Invalid catalog path")
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root.resolve()) or not resolved.is_file():
        raise ValueError("Missing/escaping catalog file")
    return resolved


def build(review, source, output):
    review, source, output = review.resolve(), source.resolve(), output.resolve()
    if output.exists() or output.is_relative_to(review) or output.is_relative_to(source):
        raise ValueError("Output must be a new directory outside review/source")
    catalog = json.loads((source / "animations.json").read_text())
    if catalog.get("version") != 1 or len(catalog["clips"]) > 512:
        raise ValueError("Unsupported source catalog")
    if len({e["id"] for e in catalog["clips"]}) != len(catalog["clips"]) or len({e["name"] for e in catalog["clips"]}) != len(catalog["clips"]):
        raise ValueError("Duplicate source IDs/names")
    for entry in catalog["clips"]:
        for field in ["file", "poster"]:
            local(source, entry[field])
    entries = {entry["name"]: entry for entry in catalog["clips"]}
    selected = {}
    group_counts = {}
    for number, key in enumerate(GROUPS, 1):
        folders = [p for p in review.iterdir() if p.is_dir() and p.name.startswith(f"{number:02d}-")]
        if len(folders) != 1:
            raise ValueError(f"Expected exactly one group {number:02d}")
        movies = sorted(folders[0].glob("*.mov"))
        if not movies:
            raise ValueError(f"Group {number:02d} has no selected movie")
        group_counts[key] = len(movies)
        for movie in movies:
            if not movie.resolve().is_relative_to(review):
                raise ValueError("Review symlink escapes review directory")
            entry = entries.get(movie.stem)
            if entry is None:
                raise ValueError(f"Unverified movie: {movie.name}; validate new media before import")
            digest = hashlib.sha256(movie.read_bytes()).hexdigest()
            original = local(source, entry["file"])
            local(source, entry["poster"])
            if digest != entry["sha256"] or digest != hashlib.sha256(original.read_bytes()).hexdigest():
                raise ValueError(f"Movie differs from verified source: {movie.name}")
            item = selected.setdefault(entry["id"], dict(entry, purposes=[], displayName=movie.stem))
            if key not in item["purposes"]:
                item["purposes"].append(key)
    # Validate all input before creating the candidate. Never mutate live media.
    shutil.copytree(source, output)
    retained = {item[field] for item in selected.values() for field in ["file", "poster"]}
    for entry in catalog["clips"]:
        for field in ["file", "poster"]:
            if entry[field] not in retained:
                local(output, entry[field]).unlink()
    (output / "animations.json").write_text(json.dumps({"version": 1, "clips": list(selected.values())}, ensure_ascii=False, indent=2) + "\n")
    result = {"clips": len(selected), "groups": group_counts,
              "sha256": {item["id"]: item["sha256"] for item in selected.values()},
              "source": "Previously verified source catalog; original upstream attribution retained"}
    (output / "reviewed-import.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--review", required=True, type=Path)
    parser.add_argument("--source-pack", required=True, type=Path)
    parser.add_argument("--pack", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.review, args.source_pack, args.pack), ensure_ascii=True))
