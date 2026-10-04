#!/usr/bin/env python3
"""Ask on the small screen and return the human answer to this waiting task."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import uuid

ROOT = Path.home() / 'Library/Application Support/SmallScreenStatus'


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.ask-')
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, ensure_ascii=False)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def questions_from(value):
    questions = value.get('questions')
    if not isinstance(questions, list) or not 1 <= len(questions) <= 3:
        raise ValueError('需要 1–3 个问题')
    result = []
    for index, question in enumerate(questions):
        if not isinstance(question, dict):
            raise ValueError('每个问题必须是对象')
        text = question.get('text', '')
        if not isinstance(text, str) or not text.strip() or len(text) > 4000:
            raise ValueError('问题文字不能为空，最长 4000 字')
        options = question.get('options', [])
        if not isinstance(options, list) or len(options) > 8:
            raise ValueError('每题最多 8 个选项')
        rows = []
        for option in options:
            if isinstance(option, str):
                option = {'label': option, 'description': ''}
            if not isinstance(option, dict) or not isinstance(option.get('label'), str) or not option['label'].strip():
                raise ValueError('选项必须有文字')
            rows.append({'label': option['label'][:1000], 'description': str(option.get('description', ''))[:2000]})
        result.append({'id': str(index), 'title': str(question.get('title', '请选择或填写'))[:200],
                       'text': text, 'options': rows})
    return result


def thread_title(thread_id):
    path = Path.home() / '.codex/state_5.sqlite'
    try:
        with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as db:
            row = db.execute('SELECT name,title FROM threads WHERE id=?', (thread_id,)).fetchone()
            if row:
                return row[0] or row[1] or '小屏提问'
    except sqlite3.Error:
        pass
    return '小屏提问'


def ask(root, thread_id, questions, timeout=900, title=None):
    thread_id = str(uuid.UUID(thread_id))
    if not 1 <= timeout <= 3600:
        raise ValueError('等待时间需要为 1–3600 秒')
    request_id = str(uuid.uuid4())
    path = root / 'screen-requests' / (request_id + '.json')
    answer_path = path.with_suffix('.answer.json')
    now = time.time()
    request = dict(id=request_id, threadID=thread_id, title=title or thread_title(thread_id),
                   questions=questions, created=now, expires=now + timeout,
                   pid=os.getpid(), status='pending')
    atomic(path, request)
    deadline = time.monotonic() + timeout
    last_task_check = 0
    try:
        while time.monotonic() < deadline:
            try:
                response = json.loads(answer_path.read_text())
                answers = response.get('answers')
                valid = (response.get('id') == request_id and response.get('threadID') == thread_id and
                         isinstance(answers, dict) and set(answers) == {q['id'] for q in questions} and
                         all(isinstance(v, str) and v.strip() and len(v) <= 16000 for v in answers.values()))
                if valid:
                    request['status'] = 'answered'
                    atomic(path, request)
                    return dict(status='answered', thread_id=thread_id, request_id=request_id,
                                answers=[{'question': q['text'], 'answer': answers[q['id']]} for q in questions])
            except (OSError, ValueError, TypeError):
                pass
            if time.monotonic() - last_task_check >= 1:
                last_task_check = time.monotonic()
                try:
                    state = json.loads((root / 'state.json').read_text())
                    task = next((t for t in state.get('display_tasks', []) if t.get('id') == thread_id), {})
                    if task.get('status') in ('done', 'error', 'interrupted') and task.get('finished', 0) >= now:
                        request['status'] = 'cancelled'
                        atomic(path, request)
                        return dict(status='cancelled', thread_id=thread_id, request_id=request_id)
                except (OSError, ValueError, TypeError):
                    pass
            time.sleep(.1)
        request['status'] = 'expired'
        atomic(path, request)
        return dict(status='timeout', thread_id=thread_id, request_id=request_id)
    except BaseException:
        request['status'] = 'cancelled'
        atomic(path, request)
        raise
    finally:
        # Answers belong in the waiting tool result; do not retain a second copy.
        try:
            answer_path.unlink()
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser(description='在小屏提问，直接返回用户答案')
    parser.add_argument('--question')
    parser.add_argument('--option', action='append', default=[])
    parser.add_argument('--file', type=Path, help='JSON 对象，含 questions 数组')
    parser.add_argument('--thread', default=os.environ.get('CODEX_THREAD_ID'))
    parser.add_argument('--timeout', type=int, default=900)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    if not args.thread:
        parser.error('需要当前 CODEX_THREAD_ID 或 --thread，不能猜测目标对话')
    try:
        if args.file:
            value = json.loads(args.file.read_text())
        elif args.question:
            value = {'questions': [{'text': args.question, 'options': args.option}]}
        else:
            parser.error('需要 --question 或 --file')
        result = ask(args.root, args.thread, questions_from(value), args.timeout)
        print(json.dumps(result, ensure_ascii=False), flush=True)
        return 0 if result['status'] == 'answered' else 2
    except (OSError, ValueError, TypeError, AttributeError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
