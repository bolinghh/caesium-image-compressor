#!/usr/bin/env python3
"""Create a local self-contained app; does not publish or Developer ID sign."""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--qt', type=Path, required=True)
parser.add_argument('--library-path', action='append', type=Path, default=[])
parser.add_argument('--framework-path', action='append', type=Path, default=[])
parser.add_argument('--output', type=Path, default=Path('build/package'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
app = args.output.resolve() / args.app.name
if app.exists():
    raise SystemExit('Output app already exists; choose a fresh --output directory')
shutil.copytree(args.app, app, symlinks=True)
subprocess.run([str(args.qt / 'bin/macdeployqt'), str(app), '-always-overwrite', '-no-strip'], check=True)
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir(exist_ok=True)
search = [p.resolve() for p in args.library_path] + [frameworks]
executable = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']

def machos():
    return [p for p in app.rglob('*') if p.is_file() and not p.is_symlink()
            and 'Mach-O' in subprocess.run(['file', '-b', str(p)], capture_output=True, text=True).stdout]

pending = machos()
seen = set()
for binary in pending:
    if binary in seen:
        continue
    seen.add(binary)
    dependencies = subprocess.check_output(['otool', '-arch', 'arm64', '-L', str(binary)], text=True).splitlines()[1:]
    for line in dependencies:
        if not line.startswith('\t'):
            continue
        dependency = line.strip().split(' (compatibility')[0]
        if dependency.startswith(('/usr/lib/', '/System/Library/')):
            continue
        if '.framework/' in dependency:
            framework_name = dependency.split('.framework/', 1)[0].split('/')[-1] + '.framework'
            target = frameworks / framework_name
            if not target.exists():
                candidates = ([Path(dependency[:dependency.index('.framework/') + len('.framework')])] if dependency.startswith('/') else [])
                candidates += [p / framework_name for p in args.framework_path]
                candidates += [Path('build/dependencies/sparkle') / framework_name, Path('build/sparkle') / framework_name]
                source = next((p for p in candidates if p.exists()), None)
                if source is None:
                    raise SystemExit(f'Unresolved framework: {dependency}')
                shutil.copytree(source, target, symlinks=True)
                pending.extend(machos())
            replacement = '@rpath/' + framework_name + '/' + dependency.split('.framework/', 1)[1]
        else:
            name = Path(dependency).name
            target = frameworks / name
            if not target.exists():
                candidates = ([Path(dependency)] if dependency.startswith('/') else []) + [p / name for p in search]
                source = next((p for p in candidates if p.exists()), None)
                if source is None:
                    raise SystemExit(f'Unresolved dependency: {dependency} in {binary}')
                shutil.copy2(source.resolve(), target)
                subprocess.run(['install_name_tool', '-id', '@rpath/' + name, str(target)], check=True)
                pending.append(target)
            replacement = '@rpath/' + name
        if dependency != replacement:
            subprocess.run(['install_name_tool', '-change', dependency, replacement, str(binary)], check=True)

# Remove build-machine paths from every bundled binary.
for binary in machos():
    load_commands = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    for path in re.findall(r'cmd LC_RPATH\n.*?path (.*?) \(offset', load_commands, re.S):
        if path.startswith('/'):
            subprocess.run(['install_name_tool', '-delete_rpath', path, str(binary)], check=True)
subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(executable)], check=True)
for binary in machos():
    links = '\n'.join(line for line in subprocess.check_output(['otool', '-arch', 'arm64', '-L', str(binary)], text=True).splitlines() if line.startswith('\t'))
    if '/opt/homebrew' in links or '/private/tmp' in links or str(Path.cwd()) in links:
        raise SystemExit(f'Build-machine dependency remains: {binary}')
licenses = app / 'Contents/Resources/ThirdPartyLicenses'
licenses.mkdir(parents=True, exist_ok=True)
shutil.copy2(Path(__file__).resolve().parent.parent / 'LICENSE', licenses / 'Caesium-GPL-3.0.txt')
shutil.copy2(Path(__file__).resolve().parent.parent / 'docs/third-party.md', licenses / 'third-party.md')
for directory in (Path.cwd() / 'build/dependencies').iterdir():
    if directory.is_dir():
        for name in ('COPYING', 'COPYING.LESSER', 'LICENSE', 'LICENSE.txt', 'PATENTS'):
            source = directory / name
            if source.is_file():
                shutil.copy2(source, licenses / (directory.name + '-' + name))

# Apple Silicon requires valid local code signatures after rewriting Mach-O load commands.
# This is ad-hoc signing for local execution, not release signing or notarization.
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
print(app)
