#!/usr/bin/env python3
"""Check tracked files and release ZIP contents for common accidental disclosures."""
from io import BytesIO
from pathlib import Path
import re
import subprocess
import sys
from zipfile import BadZipFile, ZipFile

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    'absolute user home path': re.compile(rb'/Users/[A-Za-z0-9._-]+/'),
    'email address': re.compile(rb'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    'credential-like value': re.compile(rb'(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]{16,}'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----'),
    'fixed display resolution': re.compile(rb'\b[1-9][0-9]{2,3}\s*(?:[xX]|\xc3\x97)\s*[1-9][0-9]{2,3}\b'),
}
PRIVATE_SUFFIXES = {'.log', '.sqlite', '.jsonl', '.zip', '.dmg'}
issues = []
checked = 0


def inspect(name, data):
    global checked
    if data.startswith(b'PK'):
        try:
            with ZipFile(BytesIO(data)) as archive:
                for item in archive.infolist():
                    if not item.is_dir():
                        inspect(name + '!/' + item.filename, archive.read(item))
            return
        except BadZipFile:
            pass
    checked += 1
    for label, pattern in PATTERNS.items():
        if pattern.search(name.encode()) or pattern.search(data):
            issues.append((name, label))


def main():
    metadata = subprocess.check_output(['git', 'log', '-1', '--format=%ae%n%ce'], cwd=ROOT, text=True).splitlines()
    if any(not address.endswith('@users.noreply.github.com') for address in metadata):
        issues.append(('HEAD commit', 'author or committer email is not a GitHub noreply address'))
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).split(b'\0')
    for raw in tracked:
        if not raw:
            continue
        relative = raw.decode('utf-8')
        path = ROOT / relative
        if not path.is_file():
            continue
        if path.suffix.lower() in PRIVATE_SUFFIXES:
            issues.append((relative, 'generated or private file tracked by Git'))
        inspect(relative, path.read_bytes())
    for package in sorted((ROOT / 'dist').glob('*.zip')):
        inspect(str(package.relative_to(ROOT)), package.read_bytes())
    for name, reason in issues:
        print(f'{name}: {reason}', file=sys.stderr)
    if issues:
        print(f'Privacy check failed: {len(issues)} potential issues in {checked} files.', file=sys.stderr)
        return 1
    print(f'Privacy check passed: {checked} tracked and packaged files scanned.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
