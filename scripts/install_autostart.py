#!/usr/bin/env python3
"""Install a login LaunchAgent for a local source build."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

LOGIN_LABEL = 'local.soar.small-screen-dev-login'
HOST_LABEL = 'local.soar.small-screen-dev-host'
PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description='设置小屏登录 Mac 后独立启动')
    parser.add_argument('--remove', action='store_true', help='取消自动启动')
    parser.add_argument('--follow-host', action='store_true', help='改为随本机 ChatGPT/Codex 启停')
    args = parser.parse_args()
    domain = f'gui/{os.getuid()}'
    label = HOST_LABEL if args.follow_host else LOGIN_LABEL
    plist = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
    for old_label in (LOGIN_LABEL, HOST_LABEL):
        subprocess.run(['/bin/launchctl', 'bootout', f'{domain}/{old_label}'], capture_output=True)
        old = Path.home() / 'Library/LaunchAgents' / (old_label + '.plist')
        if old.exists():
            old.unlink()
    if args.remove:
        print('已取消自动启动，小屏当前窗口保持运行。')
        return
    executable = PROJECT / 'build/ChatGPTSmallScreenLauncher'
    app = PROJECT / 'build/Small Screen Status.app'
    if not executable.is_file() or not app.is_dir():
        parser.error('请先在项目目录运行 ./scripts/build.sh')
    logs = Path.home() / 'Library/Application Support/SmallScreenStatus'
    logs.mkdir(parents=True, exist_ok=True)
    config = {
        'Label': label,
        'ProgramArguments': [str(executable), str(app)] if args.follow_host else ['/usr/bin/open', '-g', str(app)],
        'RunAtLoad': True,
        'LimitLoadToSessionType': 'Aqua',
        'StandardOutPath': str(logs / 'launcher.log'),
        'StandardErrorPath': str(logs / 'launcher.log'),
    }
    if args.follow_host:
        config.update({'KeepAlive': True, 'ThrottleInterval': 10, 'ProcessType': 'Background'})
    plist.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=plist.parent, prefix='.small-screen-launcher-')
    try:
        with os.fdopen(fd, 'wb') as output:
            plistlib.dump(config, output)
        os.chmod(temporary, 0o644)
        os.replace(temporary, plist)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    subprocess.run(['/bin/launchctl', 'enable', f'{domain}/{label}'], check=True)
    subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(plist)], check=True)
    print('已启用：小屏随 ChatGPT/Codex 启停。' if args.follow_host else '已启用：小屏登录 Mac 后独立启动。')


if __name__ == '__main__':
    main()
