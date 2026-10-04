#!/usr/bin/env python3
"""Run a command and report its real status to the small display."""
import argparse
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from monitor import ROOT, atomic_json


def main():
    p = argparse.ArgumentParser(description='小屏脚本进度')
    sub = p.add_subparsers(dest='action', required=True)
    r = sub.add_parser('run')
    r.add_argument('--title', required=True)
    r.add_argument('command', nargs=argparse.REMAINDER)
    u = sub.add_parser('progress')
    u.add_argument('percent', type=float)
    u.add_argument('--message', default='执行中')
    u.add_argument('--id', default=os.environ.get('SMALL_SCREEN_TASK_ID'))
    args = p.parse_args()
    if args.action == 'progress':
        if not args.id or not all(c in '0123456789abcdef-' for c in args.id):
            p.error('请在 screenctl run 启动的脚本中使用，或提供有效的 --id')
        path = ROOT / 'tasks' / (args.id + '.json')
        import json
        task = json.loads(path.read_text())
        task.update(progress=max(0, min(100, args.percent)), stage=args.message[:50], updated=time.time())
        atomic_json(path, task)
        return 0
    command = args.command
    if command and command[0] == '--':
        command = command[1:]
    if not command:
        p.error('缺少 -- 后的命令')
    tid = str(uuid.uuid4())
    path = ROOT / 'tasks' / (tid + '.json')
    now = time.time()
    task = dict(id=tid, title=args.title, source='脚本', status='running', stage='执行中',
                started=now, updated=now, detail='', progress=None, pid=os.getpid())
    atomic_json(path, task)
    env = dict(os.environ, SMALL_SCREEN_TASK_ID=tid)
    try:
        child = subprocess.Popen(command, env=env)
        code = child.wait()
    except KeyboardInterrupt:
        if 'child' in locals():
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        code = 130
    except OSError as exc:
        task['detail'] = str(exc)
        code = 127
    # Preserve the last reported stage/progress until recording the final result.
    import json
    try:
        task = json.loads(path.read_text())
    except (OSError, ValueError):
        pass
    task.update(status='done' if code == 0 else ('interrupted' if code == 130 else 'error'),
                stage='执行完成' if code == 0 else ('已中断' if code == 130 else '执行失败'),
                finished=time.time(), updated=time.time(), exit_code=code,
                progress=100 if code == 0 else task.get('progress'))
    atomic_json(path, task)
    return code if code >= 0 else 128 - code


if __name__ == '__main__':
    sys.exit(main())
