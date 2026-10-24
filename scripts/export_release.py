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
import os
from select_sdk import select_sdk

PROJECT = Path(__file__).resolve().parents[1]


def run(args):
    subprocess.run([str(x) for x in args], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repack', action='store_true', help='更新说明和安装入口，复用已验证的通用应用')
    parser.add_argument('--repack-from', type=Path, help='明确指定已验证的通用应用，用于仅修改安装包的版本')
    parser.add_argument('--version', help='与 --repack-from 一起指定新安装包版本')
    args = parser.parse_args()
    if bool(args.repack_from) != bool(args.version):
        parser.error('--repack-from 和 --version 必须同时提供')
    repack = args.repack or bool(args.repack_from)
    if not repack:
        run([PROJECT / 'scripts/build.sh'])
    native_app = PROJECT / 'build/Small Screen Status.app'
    version_app = args.repack_from.expanduser().resolve() if args.repack_from else native_app
    with (version_app / 'Contents/Info.plist').open('rb') as source:
        version = args.version or plistlib.load(source)['CFBundleShortVersionString']
    output = PROJECT / 'dist'
    output.mkdir(exist_ok=True)
    name = f'SmallScreenStatus-{version}-macOS'
    release = output / name
    preserved = None
    if repack:
        existing = args.repack_from.expanduser().resolve() if args.repack_from else release / 'Small Screen Status.app'
        architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(existing / 'Contents/MacOS/SmallScreenStatus')], text=True)
        if set(architectures.split()) != {'arm64', 'x86_64'}:
            raise ValueError('复用的应用必须同时包含 arm64 和 x86_64')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', existing])
        preserved = tempfile.TemporaryDirectory(prefix='small-screen-repack-')
        shutil.copytree(existing, Path(preserved.name) / 'Small Screen Status.app')
    if release.exists():
        shutil.rmtree(release)
    shutil.copytree(PROJECT / 'packaging', release, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    app = release / 'Small Screen Status.app'
    shutil.copytree(Path(preserved.name) / 'Small Screen Status.app' if preserved else native_app, app)
    if args.repack_from:
        plist_path = app / 'Contents/Info.plist'
        with plist_path.open('rb') as source:
            info = plistlib.load(source)
        info['CFBundleShortVersionString'] = version
        info['CFBundleVersion'] = version
        with plist_path.open('wb') as destination:
            plistlib.dump(info, destination)
    current = platform.machine()
    other = 'x86_64' if current == 'arm64' else 'arm64'
    if not repack:
        sdk = select_sdk()
        sdk_args = ['-sdk', str(sdk)] if sdk else []
        if sdk:
            os.environ['SDKROOT'] = str(sdk)
        with tempfile.TemporaryDirectory(prefix='small-screen-universal-') as temporary:
            temp = Path(temporary)
            run(['/usr/bin/swiftc', '-O', '-target', f'{other}-apple-macos13.0', *sdk_args, *sorted((PROJECT / 'src/app').glob('*.swift')),
                 '-o', temp / 'SmallScreenStatus', '-framework', 'Cocoa', '-framework', 'SwiftUI', '-framework', 'Carbon'])
            run(['/usr/bin/swiftc', '-O', '-target', f'{other}-apple-macos13.0', *sdk_args, PROJECT / 'src/launcher/ChatGPTLauncher.swift',
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
