#!/usr/bin/env python3
"""Package the built Lite app as a verified local DMG; never install or publish.

The verified DMG replaces the intermediate build/AgentPet Lite.app so the same
version is not retained in two complete formats. The installed app is untouched.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
APP = BUILD / "AgentPet Lite.app"
BUNDLE = "io.github.jiziol.agentpet-lite"
IMAGE_ID = BUNDLE + ".dmg"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree(root):
    return {str(p.relative_to(root)): ("link", os.readlink(p)) if p.is_symlink()
            else ("file", sha(p)) for p in root.rglob("*") if p.is_symlink() or p.is_file()}


def package():
    if not APP.is_dir() or APP.is_symlink():
        raise ValueError('Build Lite first: AGENTPET_APP_NAME="AgentPet Lite" bash scripts/build-local.sh')
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    version = info.get("CFBundleShortVersionString", "")
    if info.get("CFBundleIdentifier") != BUNDLE or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected the formal Lite bundle and a stable version")
    run("codesign", "--verify", "--deep", "--strict", str(APP))
    binary = APP / "Contents/MacOS" / info["CFBundleExecutable"]
    if run("lipo", "-archs", str(binary)).decode().strip() != "arm64":
        raise ValueError("This packaging target requires an arm64 app")
    source = tree(APP)
    image = BUILD / f"AgentPet-Lite-{version}-arm64.dmg"
    if image.exists() or image.is_symlink():
        if not image.is_file() or image.is_symlink():
            raise ValueError("Refusing an unexpected DMG output path")
        run("codesign", "--verify", "--strict", str(image))
        details = subprocess.run(["codesign", "-d", "--verbose=2", str(image)],
                                 check=True, capture_output=True).stderr.decode()
        if f"Identifier={IMAGE_ID}\n" not in details:
            raise ValueError("Refusing to replace a different disk image")
    with tempfile.TemporaryDirectory(prefix=".agentpet-dmg-", dir=BUILD) as directory:
        temp = Path(directory)
        stage, mount = temp / "contents", temp / "mount"
        stage.mkdir(); mount.mkdir()
        run("ditto", "--norsrc", "--noextattr", str(APP), str(stage / APP.name))
        (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
        (stage / "README.txt").write_text(
            f"AgentPet Lite {version} / Apple Silicon / macOS 13+\n\n"
            "安装：将 AgentPet Lite.app 拖到 Applications，弹出磁盘映像，\n"
            "再从应用程序文件夹启动。首次打开若提示无法验证，核对来源后到\n"
            "系统设置 > 隐私与安全性 > 安全性，选择仍要打开。\n"
            "已有 Local 数据的用户请先按源码 README 的迁移指南操作。\n\n"
            "Install: drag AgentPet Lite.app to Applications, eject this image,\n"
            "then open the app from Applications. If macOS cannot verify it,\n"
            "check its source and use System Settings > Privacy & Security >\n"
            "Security > Open Anyway. Existing Local users should first follow\n"
            "the migration guide linked from the source README.\n\n"
            "Ad-hoc signed; not Developer ID signed or Apple notarized.\n"
            "Licenses and asset credits are included in the app.\n", encoding="utf-8")
        candidate = temp / image.name
        run("hdiutil", "create", "-srcfolder", str(stage), "-volname", f"AgentPet Lite {version}",
            "-fs", "HFS+", "-format", "UDZO", str(candidate))
        run("codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", IMAGE_ID, str(candidate))
        run("codesign", "--verify", "--strict", str(candidate))
        run("hdiutil", "verify", str(candidate))
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(candidate))
        try:
            run("codesign", "--verify", "--deep", "--strict", str(mount / APP.name))
            if tree(mount / APP.name) != source or os.readlink(mount / "Applications") != "/Applications":
                raise ValueError("Mounted payload does not match the built app")
            if not (mount / "README.txt").is_file():
                raise ValueError("Installation instructions are missing")
        finally:
            run("hdiutil", "detach", str(mount))
        if tree(APP) != source:
            raise ValueError("Build app changed while packaging; candidate not promoted")
        occupancy = subprocess.run(["lsof", "-t", "+D", str(APP)], capture_output=True)
        if occupancy.returncode != 1 or occupancy.stdout or occupancy.stderr:
            raise ValueError("Build app is in use; do not retire it while a process holds it")
        os.replace(candidate, image)
        digest = sha(image)
        image.with_suffix(".dmg.sha256").write_text(f"{digest}  {image.name}\n", encoding="ascii")
        shutil.rmtree(APP)
    print(json.dumps({"version": version, "architecture": "arm64", "dmg": str(image),
                      "sha256": digest, "bytes": image.stat().st_size,
                      "image_signature": "ad-hoc", "mounted_app_matches_build": True,
                      "strict_app_signature_verified": True, "applications_shortcut_verified": True,
                      "intermediate_build_app_retired": True, "installed_app_untouched": True,
                      "notarized": False, "published": False}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        package()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"DMG packaging refused: {error}")
