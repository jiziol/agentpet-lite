#!/usr/bin/env python3
"""Build the same vendored decoder for standalone swiftc regression harnesses.

Content-addressed cache stays in .build; no Homebrew or downloaded dependencies.
The normal application uses the SwiftPM CUsageZstd target instead.
"""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
source = repo / 'Sources/CUsageZstd'
files = sorted(p for p in source.rglob('*') if p.suffix in {'.c', '.h'})
compiler = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
identity = subprocess.check_output([compiler, '--version']) + os.uname().machine.encode()
flags = ['-O2', '-DZSTD_LEGACY_SUPPORT=0', '-DZSTD_DISABLE_ASM', '-mmacosx-version-min=13.0']
key = hashlib.sha256(identity + repr(flags).encode() + b''.join(str(p.relative_to(source)).encode() + p.read_bytes() for p in files)).hexdigest()[:24]
cache = repo / '.build/usage-decoder-check'
cache.mkdir(parents=True, exist_ok=True)
target = cache / key
library = target / 'libUsageZstd.a'
if not library.is_file():
    stage = Path(tempfile.mkdtemp(prefix='compile-', dir=cache))
    try:
        objects = []
        for index, path in enumerate(p for p in files if p.suffix == '.c'):
            obj = stage / (str(index) + '.o')
            subprocess.run([compiler, *flags, '-c', str(path), '-o', str(obj)], check=True)
            objects.append(str(obj))
        subprocess.run(['ar', 'rcs', str(stage / library.name), *objects], check=True)
        if target.exists():
            if not library.is_file(): raise RuntimeError('Incomplete decoder cache')
        else:
            os.rename(stage, target)
    finally:
        if stage.exists(): shutil.rmtree(stage)
print(library)
