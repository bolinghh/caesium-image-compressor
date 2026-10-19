#!/usr/bin/env python3
"""Build pinned codec dependencies locally; never install into system directories."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument('--work', default='build/dependencies')
parser.add_argument('--prefix', default='build/dependencies/install')
args = parser.parse_args()
work = Path(args.work).resolve()
prefix = Path(args.prefix).resolve()
work.mkdir(parents=True, exist_ok=True)
lock = json.loads((Path(__file__).parent / 'macos-deps.lock.json').read_text())

def run(*arguments):
    subprocess.run([str(x) for x in arguments], check=True)

def source(name, spec):
    directory = work / name
    if 'git' in spec:
        if not directory.exists():
            run('git', 'clone', '--depth', '1', '--branch', spec['tag'], spec['git'], directory)
        actual = subprocess.check_output(['git', '-C', str(directory), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != spec['revision']:
            raise RuntimeError(f'{name}: source revision mismatch: {actual}')
    else:
        archive = work / (name + '.tar.gz')
        if not archive.exists():
            run('curl', '--fail', '--location', '--retry', '3', '--retry-all-errors', spec['url'], '-o', archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != spec['sha256']:
            raise RuntimeError(f'{name}: archive checksum mismatch')
        if not directory.exists():
            directory.mkdir()
            with tarfile.open(archive) as bundle:
                # All pinned archives have a single enclosing directory.
                for member in bundle.getmembers():
                    parts = Path(member.name).parts[1:]
                    if not parts:
                        continue
                    member.name = str(Path(*parts))
                    if '..' in parts or Path(member.name).is_absolute():
                        raise RuntimeError('Unsafe archive path')
                    bundle.extract(member, directory)
    return directory

for name, spec in lock.items():
    src = source(name, spec)
    build = work / (name + '-build')
    run('cmake', '-S', src / spec.get('subdirectory', ''), '-B', build,
        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_DEPLOYMENT_TARGET=12',
        '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_INSTALL_PREFIX=' + str(prefix),
        '-DCMAKE_PREFIX_PATH=' + str(prefix), '-DBUILD_SHARED_LIBS=ON', *spec['cmake'])
    run('cmake', '--build', build, '-j', min(os.cpu_count() or 4, 8))
    run('cmake', '--install', build)
print(prefix)
