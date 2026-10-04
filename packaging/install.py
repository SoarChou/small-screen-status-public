#!/usr/bin/env python3
"""Install a relocated Small Screen Status release for the current user."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

APP_NAME = 'Small Screen Status.app'
APP_ID = 'local.soar.small-screen-status'
LABEL = 'local.soar.small-screen-chatgpt-launcher'
ROOT = Path(__file__).resolve().parent


def run(args, check=True):
    return subprocess.run([str(x) for x in args], check=check, text=True, capture_output=True)


def metadata(app):
    with (app / 'Contents/Info.plist').open('rb') as source:
        return plistlib.load(source)


def verify_release():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    for relative, expected in manifest['files'].items():
        path = (ROOT / relative).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file():
            raise ValueError('安装包缺少文件：' + relative)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('安装包校验失败：' + relative)
    app = ROOT / APP_NAME
    info = metadata(app)
    if info.get('CFBundleIdentifier') != APP_ID or 'SmallScreenPreviewRoot' in info:
        raise ValueError('这不是正式小屏应用包')
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    return info


def choose_host(explicit):
    if explicit:
        app = Path(explicit).expanduser().resolve()
        return app, metadata(app)['CFBundleIdentifier']
    candidates = [base / name for base in [Path('/Applications'), Path.home() / 'Applications']
                  for name in ['ChatGPT.app', 'Codex.app']]
    found = []
    for app in candidates:
        if not (app / 'Contents/Info.plist').is_file():
            continue
        identifier = metadata(app).get('CFBundleIdentifier')
        if identifier in {'com.openai.codex', 'com.openai.chat'}:
            found.append((app, identifier))
    found.sort(key=lambda item: item[1] != 'com.openai.codex')
    return found[0] if found else (None, 'com.openai.codex')


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.small-screen-')
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install_skills(destination):
    copied, kept = [], []
    for source in (ROOT / 'skills').iterdir():
        if not source.is_dir() or not (source / 'SKILL.md').is_file():
            continue
        target = destination / source.name
        if target.exists():
            kept.append(source.name)
            continue
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, target)
        if source.name == 'small-screen-install':
            if target.resolve().is_relative_to(ROOT):
                raise ValueError('安装 skill 的位置不能位于发布包内')
            assets = target / 'assets'
            assets.mkdir(exist_ok=True)
            run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', ROOT, assets / 'SmallScreenStatus-macOS.zip'])
        copied.append(source.name)
    return {'installed': copied, 'existing_preserved': kept}


def main(argv=None):
    parser = argparse.ArgumentParser(description='安装小屏任务状态（当前用户，无需 sudo）')
    parser.add_argument('--app-dir', type=Path, default=Path.home() / 'Applications')
    parser.add_argument('--host-app', help='随此 ChatGPT/Codex 应用启动和退出')
    parser.add_argument('--display', help='目标屏幕名称；未设置时自动选择最小副屏')
    parser.add_argument('--python', type=Path, help='监测使用的 Python 3.9+ 解释器路径，默认 /usr/bin/python3')
    parser.add_argument('--no-autostart', action='store_true')
    parser.add_argument('--no-launch', action='store_true')
    parser.add_argument('--no-skills', action='store_true')
    parser.add_argument('--skill-dir', type=Path, default=Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'skills')
    parser.add_argument('--dry-run', action='store_true', help='校验并显示安装计划，不修改系统')
    parser.add_argument('--check', action='store_true', help='检查已安装应用及监听器，不修改系统')
    parser.add_argument('--remove-autostart', action='store_true', help='仅取消联动，保留应用和内容')
    args = parser.parse_args(argv)
    if platform.system() != 'Darwin' or tuple(map(int, platform.mac_ver()[0].split('.')[:2])) < (13, 0):
        parser.error('需要 macOS 13 或更高版本')
    if sys.version_info < (3, 9):
        parser.error('需要 Python 3.9 或更高版本')
    app = args.app_dir.expanduser().resolve() / APP_NAME
    helper = app / 'Contents/Resources/Tools/ChatGPTSmallScreenLauncher'
    domain = f'gui/{os.getuid()}'
    service = f'{domain}/{LABEL}'
    agent = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
    state = Path.home() / 'Library/Application Support/SmallScreenStatus'
    if args.check:
        info = metadata(app)
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        status = run(['/bin/launchctl', 'print', service], check=False)
        result = {'app': str(app), 'version': info.get('CFBundleShortVersionString'),
                  'listener_running': status.returncode == 0 and 'state = running' in status.stdout,
                  'listener_config': str(agent), 'log': str(state / 'launcher.log')}
        if agent.exists():
            result['listener_arguments'] = plistlib.loads(agent.read_bytes()).get('ProgramArguments')
            result['listener_targets_app'] = str(app) in result['listener_arguments']
        if (state / 'ui-state.json').exists():
            result['ui'] = json.loads((state / 'ui-state.json').read_text())
            result['ui_fresh'] = time.time() - (state / 'ui-state.json').stat().st_mtime < 10
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return
    if args.remove_autostart:
        run(['/bin/launchctl', 'bootout', service], check=False)
        if agent.exists():
            agent.unlink()
        print('已取消联动，应用及个人内容保留。')
        return
    info = verify_release()
    python = args.python.expanduser().resolve() if args.python else Path('/usr/bin/python3')
    if args.python is None and run(['/usr/bin/xcode-select', '-p'], check=False).returncode != 0:
        python = Path(sys.executable).resolve()
    run([python, '-c', 'import sys,sqlite3,zoneinfo; assert sys.version_info >= (3,9)'])
    host, host_id = choose_host(args.host_app)
    plan = {'version': info['CFBundleShortVersionString'], 'app': str(app), 'host': str(host) if host else None,
            'host_id': host_id, 'autostart': not args.no_autostart, 'launch': not args.no_launch,
            'display': args.display or '自动选择最小副屏', 'python': str(python),
            'skills': None if args.no_skills else str(args.skill_dir)}
    if args.dry_run:
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        return
    if app.exists() and metadata(app).get('CFBundleIdentifier') != APP_ID:
        raise ValueError('目标位置存在另一个应用，不能覆盖：' + str(app))
    if app == ROOT / APP_NAME:
        raise ValueError('安装位置不能与安装包来源相同')
    if app.exists():
        run([helper, '--quit-screen', app])
    # Copy before replacing the existing installation; keep an upgrade backup.
    app.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=app.parent, prefix='.small-screen-stage-') as temporary:
        staged = Path(temporary) / APP_NAME
        run(['/usr/bin/ditto', ROOT / APP_NAME, staged])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', staged])
        if app.exists():
            backup = app.with_name(f'Small Screen Status.backup-{time.time_ns()}.app')
            app.rename(backup)
            plan['previous_app_backup'] = str(backup)
        staged.rename(app)
    if args.display:
        run(['/usr/bin/defaults', 'write', APP_ID, 'preferredDisplay', '-string', args.display])
    if python != Path('/usr/bin/python3'):
        run(['/usr/bin/defaults', 'write', APP_ID, 'pythonExecutable', '-string', python])
    if not args.no_skills:
        plan['skill_result'] = install_skills(args.skill_dir.expanduser().resolve())
    if not args.no_autostart:
        state.mkdir(parents=True, exist_ok=True)
        config = {'Label': LABEL, 'ProgramArguments': [str(helper), str(app), '--host-id', host_id],
                  'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
                  'ProcessType': 'Background', 'LimitLoadToSessionType': 'Aqua',
                  'StandardOutPath': str(state / 'launcher.log'), 'StandardErrorPath': str(state / 'launcher.log')}
        write_atomic(agent, plistlib.dumps(config))
        run(['/bin/launchctl', 'bootout', service], check=False)
        run(['/bin/launchctl', 'enable', service])
        run(['/bin/launchctl', 'bootstrap', domain, agent])
    if not args.no_launch:
        run(['/usr/bin/open', '-g', app])
    print(json.dumps({'status': 'installed', **plan}, ensure_ascii=False, indent=2))
    print('菜单栏 ◉ → 选择显示屏。个人内容保存在 ~/Library/Application Support/SmallScreenStatus/。')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        print('安装未完成：' + (detail or str(error)), file=sys.stderr)
        sys.exit(1)
