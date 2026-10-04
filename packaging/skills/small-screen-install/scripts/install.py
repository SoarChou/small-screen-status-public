#!/usr/bin/env python3
"""Locate the adjacent release or extract this skill's bundled release."""
from pathlib import Path
import argparse
import subprocess
import sys
import tempfile
import zipfile


def entry(root):
    direct = root / 'install.py'
    if direct.is_file() and (root / 'Small Screen Status.app').is_dir():
        return direct
    found = [child / 'install.py' for child in root.iterdir() if child.is_dir()
             and (child / 'install.py').is_file() and (child / 'Small Screen Status.app').is_dir()]
    if len(found) != 1:
        raise ValueError('发布包中没有唯一的应用安装入口')
    return found[0]


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--package', type=Path)
    args, remaining = parser.parse_known_args()
    skill = Path(__file__).resolve().parents[1]
    adjacent = skill.parents[1]
    package = args.package.expanduser().resolve() if args.package else skill / 'assets/SmallScreenStatus-macOS.zip'
    if args.package is None and (adjacent / 'Small Screen Status.app').is_dir():
        return subprocess.call([sys.executable, str(entry(adjacent)), *remaining])
    if package.is_dir():
        return subprocess.call([sys.executable, str(entry(package)), *remaining])
    if not package.is_file():
        raise ValueError('缺少发布包；用 --package 指定分享 ZIP 或解压目录')
    with tempfile.TemporaryDirectory(prefix='small-screen-install-') as temporary:
        root = Path(temporary).resolve()
        # Validate names before using ditto to preserve macOS permissions/signatures.
        with zipfile.ZipFile(package) as archive:
            for name in archive.namelist():
                target = (root / name).resolve()
                if not target.is_relative_to(root):
                    raise ValueError('ZIP 包含目录越界路径')
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(package), str(root)], check=True)
        return subprocess.call([sys.executable, str(entry(root)), *remaining])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
