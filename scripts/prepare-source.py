#!/usr/bin/env python3
"""Export an allowlisted local review snapshot, never a Git repository or release.

The snapshot and checksums are review aids. They do not grant media rights,
approve Git history, choose a public version or publish anything.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import zipfile


ROOT_FILES = {
    ".gitignore", "Package.swift", "Package.resolved", "README.md",
    "CONTRIBUTING.md", "LICENSE", "THIRD_PARTY_NOTICES.md",
}
README_TRANSLATIONS = {"README.en.md"}
PUBLIC_DOCS = {
    "architecture.md", "maintenance-policy.md", "agent-integrations.md",
    "pet-animation-packs.md", "public-scope.md", "feature-comparison.md", "dsh-bridge-protocol.md",
}
README_ASSETS = {
    "README.md", "hero.png", "project-overview.png", "quota.png",
    "animations.gif", "animation-settings.png",
    "hero-en.png", "project-overview-en.png", "quota-en.png",
    "daily-usage.png", "daily-usage-en.png",
    "animations-en.gif", "animation-settings-en.png",
}
SOURCE_ROOTS = {"Sources", "Tests", "Localizations", "third-party-licenses"}
SCRIPT_FILES = {
    "AppInfo.plist", "AppIcon.icns", "build-local.sh", "verify-local.sh",
    "migrate-local-to-lite.py",
    "package-dmg.py",
    "prepare-source.py", "prepare-pet-animation.swift", "sync-deepseek-animations.py",
    "import-reviewed-animations.py", "install-codex-local.py", "install-antigravity-local.py",
    "test-integration-setup.sh", "test-human-intervention.sh", "test-codex-core.sh",
    "test-hook-ownership.sh", "test-archive-core.sh", "test-refactor-baseline.sh",
    "test-socket-core.sh", "test-read-receipts.sh", "test-antigravity-input.sh",
    "test-opencode-core.sh", "test-antigravity-core.sh",
}
SECRET_PATTERNS = {
    "private_key": rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "github_token": rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b",
    "github_fine_grained_token": rb"\bgithub_pat_[A-Za-z0-9_]{30,}\b",
    "api_key": rb"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,}\b",
    "aws_access_key": rb"\bAKIA[A-Z0-9]{16}\b",
}


def allowed(name):
    p = Path(name)
    if p.is_absolute() or ".." in p.parts:
        return False
    if any(part in {".git", ".DS_Store", "__pycache__", "node_modules", ".build"} for part in p.parts):
        return False
    if (p.name in {"auth.json", "credentials.json", "secrets.json"}
            or p.name.startswith(".env") or p.suffix.lower() in {".key", ".pem", ".p12", ".pfx", ".log", ".tsbuildinfo"}):
        return False
    if len(p.parts) == 1:
        return name in ROOT_FILES or name in README_TRANSLATIONS
    if p.parts[0] in SOURCE_ROOTS:
        return True
    if p.parts[0] == "docs":
        return len(p.parts) == 2 and p.name in PUBLIC_DOCS
    if p.parts[0] == ".github":
        return (name == ".github/workflows/ci.yml"
                or (len(p.parts) == 3 and p.parts[1] == "readme" and p.name in README_ASSETS))
    if p.parts[0] == "scripts":
        return ((len(p.parts) == 2 and p.name in SCRIPT_FILES)
                or (len(p.parts) >= 3 and p.parts[1] == "checks"))
    return False


def check_index(repo):
    """Check the staged file set, including force-added and unchanged files."""
    entries = subprocess.check_output(
        ["git", "ls-files", "--stage", "-z"], cwd=repo,
    ).split(b"\0")
    names, rejected = set(), []
    for entry in filter(None, entries):
        metadata, encoded_name = entry.split(b"\t", 1)
        mode, _object_id, stage = metadata.split()
        name = encoded_name.decode("utf-8", errors="surrogateescape")
        if stage != b"0" or mode not in {b"100644", b"100755"} or not allowed(name):
            rejected.append(name)
        names.add(name)
    if rejected:
        raise ValueError("Index contains unapproved paths or file types: "
                         + ", ".join(repr(name) for name in sorted(set(rejected))))
    required = ROOT_FILES | {"docs/" + name for name in PUBLIC_DOCS}
    if missing := required - names:
        raise ValueError("Required public files missing from index: "
                         + ", ".join(sorted(missing)))
    print(f"Index file scope passed ({len(names)} files; content and history not audited)")


def check_tree(repo):
    """Check an extracted source snapshot without requiring Git metadata."""
    names = set()
    for path in repo.rglob("*"):
        relative = path.relative_to(repo)
        # Generated local build outputs are never part of source scope.
        if relative.parts[0] in {".build", "build", ".swiftpm"}:
            continue
        if path.is_symlink():
            raise ValueError("Source tree contains symlink: " + str(relative))
        if path.is_dir():
            continue
        name = relative.as_posix()
        if not path.is_file() or not allowed(name):
            raise ValueError("Source tree contains unapproved path: " + name)
        names.add(name)
    required = ROOT_FILES | {"docs/" + name for name in PUBLIC_DOCS}
    if missing := required - names:
        raise ValueError("Required public files missing from tree: " + ", ".join(sorted(missing)))
    print(f"Tree file scope passed ({len(names)} files; content and history not audited)")


def export(repo, output, tracked_only=False):
    repo, output = repo.resolve(), output.resolve()
    if output.exists() or output.is_relative_to(repo):
        raise ValueError("Output must be a new directory outside the repository")
    tracked = set(subprocess.check_output(
        ["git", "ls-files", "--cached", "-z"], cwd=repo,
    ).decode().split("\0")) - {""}
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=repo,
    ).decode().split("\0")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repo))
    files, excluded = {}, {}
    for name in sorted(set(names) - {""}):
        if tracked_only and name not in tracked:
            excluded[name] = "untracked; excluded by --tracked-only"
            continue
        if not allowed(name):
            excluded[name] = "outside public source allowlist"
            continue
        path = repo / name
        if any((repo / parent).is_symlink() for parent in (Path(name), *Path(name).parents)):
            raise ValueError("Refusing source symlink: " + name)
        if not path.exists():
            continue  # A tracked deletion is not part of the working snapshot.
        if path.is_symlink() or not path.resolve().is_relative_to(repo) or not path.is_file():
            raise ValueError("Refusing non-regular or escaping source: " + name)
        data = path.read_bytes()
        for label, pattern in SECRET_PATTERNS.items():
            if re.search(pattern, data):
                raise ValueError("Review required: " + label + " pattern in " + name)
        files[name] = data
    required = ROOT_FILES | {"docs/" + name for name in PUBLIC_DOCS}
    if missing := required - files.keys():
        raise ValueError("Required public files missing: " + ", ".join(sorted(missing)))
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".agentpet-source-", dir=output.parent))
    try:
        archive = stage / "agentpet-lite-source-review.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for name, data in files.items():
                info = zipfile.ZipInfo("agentpet-lite/" + name, date_time=(2026, 1, 1, 0, 0, 0))
                mode = 0o755 if (repo / name).stat().st_mode & stat.S_IXUSR else 0o644
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, data)
        report = {
            "kind": "local-review-snapshot", "created_utc": datetime.now(timezone.utc).isoformat(),
            "source_commit": revision, "working_tree_dirty": dirty,
            "tracked_only": tracked_only,
            "scope": "No Git metadata/history, runtime data, builds or private process documents",
            "limitations": "Pattern scan is not a proof of privacy or licensing clearance; review before publication",
            "files": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()},
            "excluded": excluded,
        }
        manifest = stage / "source-manifest.json"
        manifest.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        (stage / "SHA256SUMS").write_text("".join(
            hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n"
            for p in (archive, manifest)
        ))
        stage.rename(output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print(f"Local review snapshot: {output} ({len(files)} files; not published)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--output", type=Path)
    action.add_argument("--check-tree", action="store_true",
                        help="Check extracted source paths without Git; generated build directories excluded")
    action.add_argument("--check-index", action="store_true",
                        help="Reject staged files outside the public source allowlist; does not audit content or history")
    parser.add_argument("--tracked-only", action="store_true",
                        help="Export tracked working-tree files only; preserve but exclude untracked diagnostics")
    args = parser.parse_args()
    if args.tracked_only and not args.output:
        parser.error("--tracked-only requires --output")
    try:
        repo = Path(__file__).resolve().parents[1]
        if args.check_index:
            check_index(repo)
        elif args.check_tree:
            check_tree(repo)
        else:
            export(repo, args.output, args.tracked_only)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        operation = "Index check" if args.check_index else "Source export"
        raise SystemExit(operation + " refused: " + str(error))
