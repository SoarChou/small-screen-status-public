#!/usr/bin/env python3
"""Local, read-only Codex rollout monitor. No hooks or network requests."""
import argparse
import datetime
import json
import os
import re
from pathlib import Path
import sqlite3
import time

ROOT = Path(os.environ.get('SMALL_SCREEN_STATUS_ROOT', str(Path.home() / 'Library/Application Support/SmallScreenStatus')))
ACTIVE = {'running', 'waiting'}


def preceding_boundary(path, before):
    """Find the latest actual task boundary before a bounded bootstrap tail."""
    with Path(path).open('rb') as f:
        position, remainder = before, b''
        while position > 0:
            length = min(position, 256 * 1024)
            position -= length
            f.seek(position)
            lines = (f.read(length) + remainder).split(b'\n')
            remainder = lines.pop(0)
            line_position = position + len(remainder) + 1
            if position == 0:
                lines.insert(0, remainder)
                line_position = 0
            located = []
            for line in lines:
                located.append((line_position, line))
                line_position += len(line) + 1
            for offset, line in reversed(located):
                if not any(token in line for token in (b'"task_started"', b'"task_complete"', b'"turn_aborted"')):
                    continue
                try:
                    event = json.loads(line)
                    if event.get('type') == 'event_msg' and (event.get('payload') or {}).get('type') in ('task_started', 'task_complete', 'turn_aborted'):
                        event['_file_offset'] = offset
                        return event
                except (ValueError, TypeError):
                    pass
    return None


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + f'.{os.getpid()}.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    temp.replace(path)


def timestamp(value, fallback=0):
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError):
        return fallback


def stage(name):
    name = name.lower()
    if any(x in name for x in ('request_user', 'permission', 'approval')):
        return '等待你的操作', 'waiting'
    for keys, label in [(('search', 'web', 'browse'), '查找资料'),
                        (('patch', 'edit', 'write'), '修改文件'),
                        (('test',), '验证结果'), (('exec', 'command', 'stdin'), '执行工具'),
                        (('imagegen',), '生成图像'), (('read', 'list', 'get'), '读取信息')]:
        if any(k in name for k in keys):
            return label, 'running'
    return '执行工具', 'running'


class Rollout:
    def __init__(self, thread_id, path, title):
        self.id, self.path, self.title = thread_id, Path(path), title
        self.offset = 0
        self.initial = True
        self.task = None
        self.pending = {}

    def interactions(self, payload, now):
        """Only extract explicit user-facing question fields, never arbitrary tool arguments."""
        typ = payload.get('type')
        call = payload.get('call_id')
        name = payload.get('name', '').split('.')[-1].split('__')[-1]
        if typ == 'function_call' and call and name in {'request_user_input', 'request_user_input_async', 'request_permissions'}:
            try:
                args = json.loads(payload.get('arguments', '{}'))
            except (ValueError, TypeError):
                return
            if not isinstance(args, dict):
                return
            questions = []
            if name == 'request_permissions':
                questions = [dict(id='permission', title='权限确认', text=str(args.get('reason') or '请在原对话查看并确认所请求的权限')[:4000], options=[])]
            else:
                for index, q in enumerate(args.get('questions', [])[:3]):
                    if not isinstance(q, dict):
                        continue
                    text = q.get('question') or q.get('title')
                    if not isinstance(text, str):
                        continue
                    options = []
                    for option in q.get('options', [])[:20]:
                        if isinstance(option, str):
                            options.append(dict(label=option[:512], description=''))
                        elif isinstance(option, dict) and isinstance(option.get('label'), str):
                            options.append(dict(label=option['label'][:512], description=str(option.get('description') or '')[:2000]))
                    questions.append(dict(id=str(index), title=str(q.get('header') or '待回答')[:100], text=text[:4000], options=options))
            if questions:
                self.pending[call] = dict(id=call, kind='approval' if name == 'request_permissions' else 'question',
                                          async_request=name == 'request_user_input_async', created=now, questions=questions)
        elif typ in ('function_call_output', 'custom_tool_call_output') and call in self.pending:
            # Async acknowledgement is not a human answer. Failed delivery is resolved.
            try:
                output = json.loads(payload.get('output', ''))
            except (ValueError, TypeError):
                output = None
            if not (self.pending[call]['async_request'] and isinstance(output, dict) and output.get('accepted') is True):
                self.pending.pop(call, None)
        elif typ == 'message' and payload.get('role') == 'user':
            for content in payload.get('content', []):
                text = content.get('text', '') if isinstance(content, dict) else ''
                match = re.fullmatch(r'\s*<send_user_message_question_reply>\s*(.*?)\s*</send_user_message_question_reply>\s*', text, re.S)
                if not match:
                    continue
                try:
                    for answer in json.loads(match.group(1)):
                        tool, answered_call, index = json.loads(answer['questionItemId'])
                        if tool != 'request_user_input_async' or answered_call not in self.pending:
                            continue
                        request = self.pending[answered_call]
                        request['questions'] = [q for q in request['questions'] if q['id'] != str(index)]
                        if not request['questions']:
                            self.pending.pop(answered_call)
                except (ValueError, TypeError, KeyError):
                    pass

    def publish_interactions(self):
        if self.task is None:
            return
        previously_pending = bool(self.task.get('interactions'))
        self.task['interactions'] = list(self.pending.values())
        if self.pending and self.task['status'] in ACTIVE:
            self.task.update(status='waiting', stage='等待你的操作')
        elif previously_pending and self.task['status'] == 'waiting':
            self.task.update(status='running', stage='思考中')

    def consume(self, event):
        p = event.get('payload') or {}
        kind, typ = event.get('type'), p.get('type')
        now = timestamp(event.get('timestamp'), time.time())
        if kind == 'event_msg' and typ == 'task_started':
            self.pending.clear()
            self.task = dict(id=self.id, title=self.title, source='Codex', status='running',
                             stage='思考中', started=timestamp(p.get('started_at'), now), updated=now,
                             detail='', progress=None, turn_id=p.get('turn_id'))
            return
        if self.task is None:
            if kind == 'event_msg' and typ == 'task_complete':
                end = timestamp(p.get('completed_at'), now)
                self.task = dict(id=self.id, title=self.title, source='Codex', status='done',
                                 stage='本轮完成', started=timestamp(p.get('started_at'), end - p.get('duration_ms', 0) / 1000),
                                 updated=end, finished=end, detail='', progress=None, turn_id=p.get('turn_id'))
            return
        if kind == 'response_item':
            self.interactions(p, now)
        if kind == 'event_msg' and typ in ('task_complete', 'turn_aborted'):
            # An older turn completion must not finish a newer turn.
            if p.get('turn_id') and self.task.get('turn_id') and p['turn_id'] != self.task['turn_id']:
                return
            self.task.update(status='done' if typ == 'task_complete' else 'interrupted',
                             stage='本轮完成' if typ == 'task_complete' else '已中断',
                             updated=timestamp(p.get('completed_at'), now), finished=now, detail='')
            self.pending.clear()
        elif self.task['status'] in ACTIVE:
            if kind == 'response_item' and typ in ('function_call', 'custom_tool_call'):
                label, status = stage(p.get('name', ''))
                self.task.update(stage=label, status=status, updated=now)
            elif kind == 'response_item' and typ in ('function_call_output', 'custom_tool_call_output', 'reasoning'):
                self.task.update(stage='思考中', status='running', updated=now)
            elif kind == 'event_msg' and typ == 'item_completed':
                item = p.get('item') or {}
                it = item.get('type', '')
                if it == 'AgentMessage':
                    content = item.get('content', '')
                    if isinstance(content, list):
                        content = ' '.join(x.get('text', '') for x in content if isinstance(x, dict) and str(x.get('type', '')).lower() in ('text', 'output_text'))
                    if isinstance(content, str) and item.get('phase') == 'commentary':
                        self.task['detail'] = content.strip()[:4000]
                    self.task.update(stage='整理结果' if item.get('phase') in ('final', 'final_answer') else '处理中', updated=now)
                elif it == 'Reasoning':
                    self.task.update(stage='思考中', status='running', updated=now)
        self.publish_interactions()

    def poll(self):
        try:
            size = self.path.stat().st_size
            if size < self.offset:
                self.offset, self.task, self.initial = 0, None, True
                self.pending.clear()
            with self.path.open('rb') as f:
                # Recover the actual boundary of a long turn, then read its bounded tail.
                if self.initial and size > 2 * 1024 * 1024:
                    f.seek(size - 2 * 1024 * 1024)
                    f.readline()
                    self.offset = f.tell()
                    boundary = preceding_boundary(self.path, self.offset)
                    if boundary:
                        self.consume(boundary)
                        # Recover unanswered prompts before the tail without publishing other tool data.
                        if boundary.get('payload', {}).get('type') == 'task_started':
                            tail_offset = self.offset
                            f.seek(boundary['_file_offset'])
                            f.readline()
                            while f.tell() < tail_offset:
                                line = f.readline()
                                if not line:
                                    break
                                relevant = any(token in line for token in (b'request_user_input', b'request_permissions'))
                                relevant = relevant or (self.pending and any(token in line for token in (b'function_call_output', b'custom_tool_call_output', b'send_user_message_question_reply')))
                                if relevant:
                                    try:
                                        e = json.loads(line)
                                        if e.get('type') == 'response_item':
                                            self.interactions(e.get('payload') or {}, timestamp(e.get('timestamp'), time.time()))
                                    except (ValueError, TypeError):
                                        pass
                            self.publish_interactions()
                self.initial = False
                f.seek(self.offset)
                while True:
                    start = f.tell()
                    line = f.readline()
                    if not line or not line.endswith(b'\n'):
                        self.offset = start
                        break
                    try:
                        self.consume(json.loads(line))
                    except (ValueError, TypeError):
                        pass
                    self.offset = f.tell()
        except OSError:
            pass


def snapshot(tasks, now, error=None):
    tasks = [dict(t) for t in tasks if t]
    for task in tasks:
        # Don't silently call a stalled or abandoned session complete.
        if task['status'] in ACTIVE and not task.get('interactions') and now - task['updated'] > 1800:
            task.update(status='unknown', stage='状态待确认', detail='较长时间没有新活动，请查看原任务。')
    active = sorted([t for t in tasks if t['status'] in ACTIVE], key=lambda t: t['updated'], reverse=True)
    recent = sorted(tasks, key=lambda t: t['updated'], reverse=True)
    primary = active[0] if active else (recent[0] if recent and now - recent[0]['updated'] < 86400 else None)
    # Stable ordering prevents rows from jumping whenever another tool finishes.
    displayed = sorted(active, key=lambda t: (t['started'], t['id']))
    displayed += [t for t in recent if t['status'] not in ACTIVE and
                  ((t['status'] in {'done', 'error', 'interrupted'} and now - t['updated'] < 300)
                   or (t['status'] == 'unknown' and now - t['updated'] < 3600))]
    return dict(heartbeat=now, primary=primary, active=active, active_count=len(active),
                display_tasks=displayed, error=error)


def run(root=ROOT, codex_home=None, parent_pid=None):
    home = Path(codex_home or os.environ.get('CODEX_HOME', Path.home() / '.codex'))
    watchers = {}
    next_discovery = 0
    error = None
    while True:
        if parent_pid is not None and os.getppid() != parent_pid:
            return
        now = time.time()
        if now >= next_discovery:
            next_discovery = now + 3
            try:
                with sqlite3.connect(f'file:{home / "state_5.sqlite"}?mode=ro', uri=True, timeout=.3) as conn:
                    # Codex stores the sidebar title in name; title is the first prompt.
                    rows = conn.execute("SELECT id, rollout_path, COALESCE(NULLIF(TRIM(name), ''), title) "
                                        'FROM threads WHERE archived=0 AND updated_at >= ? '
                                        'ORDER BY updated_at DESC', (now - 86400,)).fetchall()
                for tid, path, title in rows:
                    if tid not in watchers:
                        watchers[tid] = Rollout(tid, path, ' '.join((title or 'Codex 任务').split())[:512])
                    else:
                        watchers[tid].title = ' '.join((title or 'Codex 任务').split())[:512]
                        if watchers[tid].task:
                            watchers[tid].task['title'] = watchers[tid].title
                keep = {r[0] for r in rows}
                watchers = {k: w for k, w in watchers.items() if k in keep or (w.task and w.task['status'] in ACTIVE)}
                error = None
            except (sqlite3.Error, OSError):
                error = 'Codex 状态源不可用'
        for watcher in watchers.values():
            watcher.poll()
        tasks = [w.task for w in watchers.values() if w.task]
        for path in (root / 'tasks').glob('*.json'):
            try:
                task = json.loads(path.read_text())
                if task.get('source') == '脚本' and task['status'] in ACTIVE:
                    try:
                        os.kill(int(task['pid']), 0)
                    except (ProcessLookupError, ValueError, KeyError):
                        task.update(status='unknown', stage='进程已退出', updated=now, finished=now,
                                    detail='没有收到退出结果，请检查脚本。')
                        atomic_json(path, task)
                if now - task.get('updated', 0) < 86400 or task.get('status') in ACTIVE:
                    tasks.append(task)
            except (ValueError, KeyError, OSError):
                pass
        atomic_json(root / 'state.json', snapshot(tasks, now, error))
        time.sleep(.5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--codex-home', type=Path)
    parser.add_argument('--parent-pid', type=int)
    args = parser.parse_args()
    run(args.root, args.codex_home, args.parent_pid)
