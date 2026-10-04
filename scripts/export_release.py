#!/usr/bin/env python3
"""Build a portable universal app ZIP and a self-contained installation skill ZIP."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]


def run(args):
    subprocess.run([str(x) for x in args], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repack', action='store_true', help='更新说明和安装入口，复用已验证的通用应用')
    args = parser.parse_args()
    if not args.repack:
        run([PROJECT / 'scripts/build.sh'])
    native_app = PROJECT / 'build/Small Screen Status.app'
    with (native_app / 'Contents/Info.plist').open('rb') as source:
        version = plistlib.load(source)['CFBundleShortVersionString']
    output = PROJECT / 'dist'
    output.mkdir(exist_ok=True)
    name = f'SmallScreenStatus-{version}-macOS'
    release = output / name
    preserved = None
    if args.repack:
        existing = release / 'Small Screen Status.app'
        run(['/usr/bin/lipo', existing / 'Contents/MacOS/SmallScreenStatus', '-verify_arch', 'arm64', 'x86_64'])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', existing])
        preserved = tempfile.TemporaryDirectory(prefix='small-screen-repack-')
        shutil.copytree(existing, Path(preserved.name) / 'Small Screen Status.app')
    if release.exists():
        shutil.rmtree(release)
    shutil.copytree(PROJECT / 'packaging', release, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    app = release / 'Small Screen Status.app'
    shutil.copytree(Path(preserved.name) / 'Small Screen Status.app' if preserved else native_app, app)
    current = platform.machine()
    other = 'x86_64' if current == 'arm64' else 'arm64'
    if not args.repack:
        with tempfile.TemporaryDirectory(prefix='small-screen-universal-') as temporary:
            temp = Path(temporary)
            run(['/usr/bin/swiftc', '-O', '-target', f'{other}-apple-macos13.0', *sorted((PROJECT / 'src/app').glob('*.swift')),
                 '-o', temp / 'SmallScreenStatus', '-framework', 'Cocoa', '-framework', 'SwiftUI', '-framework', 'Carbon'])
            run(['/usr/bin/swiftc', '-O', '-target', f'{other}-apple-macos13.0', PROJECT / 'src/launcher/ChatGPTLauncher.swift',
                 '-o', temp / 'ChatGPTSmallScreenLauncher', '-framework', 'Cocoa'])
            executable = app / 'Contents/MacOS/SmallScreenStatus'
            helper = app / 'Contents/Resources/Tools/ChatGPTSmallScreenLauncher'
            run(['/usr/bin/lipo', '-create', native_app / 'Contents/MacOS/SmallScreenStatus', temp / 'SmallScreenStatus', '-output', executable])
            run(['/usr/bin/lipo', '-create', native_app / 'Contents/Resources/Tools/ChatGPTSmallScreenLauncher', temp / 'ChatGPTSmallScreenLauncher', '-output', helper])
    executable = app / 'Contents/MacOS/SmallScreenStatus'
    helper = app / 'Contents/Resources/Tools/ChatGPTSmallScreenLauncher'
    if preserved:
        preserved.cleanup()
    helper.chmod(0o755)
    executable.chmod(0o755)
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', helper])
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', app])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    run([executable, '--self-test'])
    run([helper, '--self-test'])
    (release / 'install.command').chmod(0o755)
    files = {str(path.relative_to(release)): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in sorted(release.rglob('*')) if path.is_file() and path.name != 'manifest.json'}
    (release / 'manifest.json').write_text(json.dumps({'version': version, 'architectures': ['arm64', 'x86_64'], 'files': files}, ensure_ascii=False, indent=2) + '\n')
    package_zip = output / f'{name}.zip'
    if package_zip.exists():
        package_zip.unlink()
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', release, package_zip])
    # The separate skill contains the exact release, independent of project paths.
    skill = output / 'small-screen-install'
    if skill.exists():
        shutil.rmtree(skill)
    shutil.copytree(release / 'skills/small-screen-install', skill)
    (skill / 'assets').mkdir()
    shutil.copy2(package_zip, skill / 'assets/SmallScreenStatus-macOS.zip')
    skill_zip = output / f'small-screen-install-{version}.zip'
    if skill_zip.exists():
        skill_zip.unlink()
    run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', skill, skill_zip])
    (output / 'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in [package_zip, skill_zip]))
    print(json.dumps({'app_package': str(package_zip), 'installation_skill': str(skill_zip), 'checksums': str(output / 'SHA256SUMS.txt')}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
