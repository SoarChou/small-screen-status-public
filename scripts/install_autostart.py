#!/usr/bin/env python3
"""Install the current user's local ChatGPT lifecycle watcher."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

LABEL = 'local.soar.small-screen-chatgpt-launcher'
PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description='设置小屏随 ChatGPT 启动和退出')
    parser.add_argument('--remove', action='store_true', help='停止监听并取消随 ChatGPT 启动和退出')
    args = parser.parse_args()
    domain = f'gui/{os.getuid()}'
    service = f'{domain}/{LABEL}'
    plist = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
    if args.remove:
        subprocess.run(['/bin/launchctl', 'bootout', service], capture_output=True)
        if plist.exists():
            plist.unlink()
        print('已取消随 ChatGPT 启动和退出，小屏当前窗口保持运行。')
        return
    executable = PROJECT / 'build/ChatGPTSmallScreenLauncher'
    app = PROJECT / 'build/Small Screen Status.app'
    if not executable.is_file() or not app.is_dir():
        parser.error('请先在项目目录运行 ./scripts/build.sh')
    logs = Path.home() / 'Library/Application Support/SmallScreenStatus'
    logs.mkdir(parents=True, exist_ok=True)
    config = {
        'Label': LABEL,
        'ProgramArguments': [str(executable), str(app)],
        'RunAtLoad': True,
        'KeepAlive': True,
        'ThrottleInterval': 10,
        'ProcessType': 'Background',
        'LimitLoadToSessionType': 'Aqua',
        'StandardOutPath': str(logs / 'launcher.log'),
        'StandardErrorPath': str(logs / 'launcher.log'),
    }
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
    subprocess.run(['/bin/launchctl', 'bootout', service], capture_output=True)
    subprocess.run(['/bin/launchctl', 'enable', service], check=True)
    subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(plist)], check=True)
    print('已启用：小屏随 ChatGPT 启动和退出，不抢占输入焦点。')


if __name__ == '__main__':
    main()
