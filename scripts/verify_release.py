#!/usr/bin/env python3
"""Verify relocated releases without changing the live app or its LaunchAgent."""
import json
import contextlib
import importlib.util
import io
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

PROJECT = Path(__file__).resolve().parents[1]


def run(args):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr + result.stdout)
    return result.stdout


def main():
    with (PROJECT / 'build/Small Screen Status.app/Contents/Info.plist').open('rb') as source:
        version = plistlib.load(source)['CFBundleShortVersionString']
    package = PROJECT / f'dist/SmallScreenStatus-{version}-macOS.zip'
    skill_zip = PROJECT / f'dist/small-screen-install-{version}.zip'
    if not package.is_file() or not skill_zip.is_file():
        raise RuntimeError('请先运行 python3 scripts/export_release.py 生成当前版本的分享包')
    release_name = package.stem
    with tempfile.TemporaryDirectory(prefix='small-screen-share-') as temporary:
        root = Path(temporary).resolve()
        relocated = root / 'Download with spaces'
        relocated.mkdir()
        run(['/usr/bin/ditto', '-x', '-k', package, relocated])
        release = relocated / release_name
        installer = release / 'install.py'
        app_dir, skills = root / 'User Applications', root / 'User Skills'
        skills.mkdir()
        (skills / 'small-screen-tools').mkdir()
        (skills / 'small-screen-tools/SKILL.md').write_text('Existing personal skill')
        plan = json.loads(run(['/usr/bin/python3', installer, '--dry-run', '--app-dir', app_dir, '--skill-dir', skills]))
        assert plan['app'] == str(app_dir / 'Small Screen Status.app')
        assert plan['host_id'] in {'com.openai.codex', 'com.openai.chat'}
        install_args = ['/usr/bin/python3', installer, '--app-dir', app_dir, '--skill-dir', skills, '--no-autostart', '--no-launch']
        run(install_args)
        app = app_dir / 'Small Screen Status.app'
        assert app.is_dir()
        assert (skills / 'small-screen-tools/SKILL.md').read_text() == 'Existing personal skill'
        assert (skills / 'small-screen-install/assets/SmallScreenStatus-macOS.zip').is_file()
        for relative in ['Contents/MacOS/SmallScreenStatus', 'Contents/Resources/Tools/ChatGPTSmallScreenLauncher']:
            architectures = run(['/usr/bin/lipo', '-archs', app / relative]).strip()
            assert set(architectures.split()) == {'arm64', 'x86_64'}
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        run(install_args)
        assert len(list(app_dir.glob('Small Screen Status.backup-*.app'))) == 1
        # Exercise real launchctl registration with a separate job name and an
        # absent fixture host, so it cannot touch the user's app or watcher.
        spec = importlib.util.spec_from_file_location('release_installer', installer)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.LABEL = 'local.soar.small-screen-release-test-' + uuid.uuid4().hex
        service = f'gui/{os.getuid()}/{module.LABEL}'
        fake_home = root / 'Fixture Home'
        host = root / 'Absent Fixture Host.app'
        (host / 'Contents').mkdir(parents=True)
        (host / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.soar.absent-release-host'}))
        previous_home = os.environ.get('HOME')
        try:
            os.environ['HOME'] = str(fake_home)
            with contextlib.redirect_stdout(io.StringIO()):
                module.main(['--app-dir', str(root / 'Listener Applications'), '--host-app', str(host), '--no-launch', '--no-skills'])
            agent = fake_home / 'Library/LaunchAgents' / (module.LABEL + '.plist')
            config = plistlib.loads(agent.read_bytes())
            installed = root / 'Listener Applications/Small Screen Status.app'
            assert config['ProgramArguments'] == [str(installed / 'Contents/Resources/Tools/ChatGPTSmallScreenLauncher'), str(installed), '--host-id', 'local.soar.absent-release-host']
            for _ in range(30):
                status = run(['/bin/launchctl', 'print', service])
                if 'state = running' in status:
                    break
                time.sleep(0.1)
            assert 'state = running' in status, status
            with contextlib.redirect_stdout(io.StringIO()):
                module.main(['--remove-autostart'])
            assert not agent.exists() and installed.is_dir()
        finally:
            subprocess.run(['/bin/launchctl', 'bootout', service], capture_output=True)
            if previous_home is None:
                os.environ.pop('HOME', None)
            else:
                os.environ['HOME'] = previous_home
        # Installed skill remains useful after deleting the original download.
        shutil.rmtree(relocated)
        run(['/usr/bin/python3', skills / 'small-screen-install/scripts/install.py', '--dry-run', '--app-dir', root / 'Other Applications'])
        standalone = root / 'Standalone Skill'
        standalone.mkdir()
        run(['/usr/bin/ditto', '-x', '-k', skill_zip, standalone])
        wrapper = standalone / 'small-screen-install/scripts/install.py'
        run(['/usr/bin/python3', wrapper, '--app-dir', root / 'Agent Applications', '--no-skills', '--no-autostart', '--no-launch'])
        assert (root / 'Agent Applications/Small Screen Status.app').is_dir()
        # Corruption is rejected before copying an installation.
        tamper = root / 'Tampered'
        run(['/usr/bin/ditto', '-x', '-k', package, tamper])
        corrupted = tamper / release_name
        (corrupted / 'Small Screen Status.app/Contents/Resources/widgets.json').write_text('{}')
        result = subprocess.run(['/usr/bin/python3', str(corrupted / 'install.py'), '--dry-run'], capture_output=True, text=True)
        assert result.returncode and '校验失败' in result.stderr
        print('Share checks passed: relocated install; universal binaries; signature; existing skills preserved; upgrade backup; isolated LaunchAgent registration/removal; installed skill after download removal; independent skill installation; corruption rejection.')
    print('All verification installations were isolated; production app and LaunchAgent were unchanged.')


if __name__ == '__main__':
    main()
