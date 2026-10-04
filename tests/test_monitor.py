import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import sqlite3
import datetime
CLI = Path(__file__).resolve().parents[1] / 'src/cli'
sys.path.insert(0, str(CLI))
from monitor import Rollout, snapshot


def event(typ, **fields):
    return dict(type='event_msg', timestamp='2026-10-03T08:00:00Z', payload=dict(type=typ, **fields))


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'rollout.jsonl'
        self.path.write_text('')
        self.w = Rollout('thread', self.path, '任务')

    def tearDown(self):
        self.tmp.cleanup()

    def test_actual_boundaries_and_turn_race(self):
        self.w.consume(event('task_started', turn_id='new', started_at=100))
        self.w.consume(event('task_complete', turn_id='old'))
        self.assertEqual(self.w.task['status'], 'running')
        self.w.consume(event('task_complete', turn_id='new'))
        self.assertEqual(self.w.task['status'], 'done')
        self.assertIsNone(self.w.task['progress'])

    def test_interruption_and_missing_start(self):
        self.w.consume(event('task_complete'))
        self.assertEqual(self.w.task['status'], 'done')
        self.w.consume(event('task_started'))
        self.w.consume(event('turn_aborted'))
        self.assertEqual(self.w.task['status'], 'interrupted')

    def test_partial_write_is_read_once_when_complete(self):
        line = json.dumps(event('task_started', turn_id='t')).encode()
        self.path.write_bytes(line[:30])
        self.w.poll()
        self.assertIsNone(self.w.task)
        with self.path.open('ab') as f:
            f.write(line[30:] + b'\n')
        self.w.poll()
        self.assertEqual(self.w.task['turn_id'], 't')
        offset = self.w.offset
        self.w.poll()
        self.assertEqual(self.w.offset, offset)

    def test_parallel_priority_and_stale_state(self):
        self.w.consume(event('task_started', started_at=100))
        running = self.w.task
        now = running['updated'] + 10
        done = dict(running, id='done', status='done', updated=now)
        state = snapshot([done, running], now)
        self.assertEqual(state['primary']['id'], 'thread')
        self.assertEqual(state['active_count'], 1)
        state = snapshot([running], now + 1801)
        self.assertEqual(state['primary']['status'], 'unknown')

    def test_all_parallel_tasks_are_exposed_without_activity_reordering(self):
        now = time.time()
        tasks = [dict(id=str(i), title=f'任务{i}', source='Codex', status='running',
                      stage='思考中', started=now-100+i, updated=now-i) for i in range(8)]
        state = snapshot(tasks, now)
        self.assertEqual(state['active_count'], 8)
        self.assertEqual(len(state['active']), 8)
        self.assertEqual([t['id'] for t in state['display_tasks']], [str(i) for i in range(8)])
        tasks[-1]['updated'] = now + 1
        self.assertEqual([t['id'] for t in snapshot(tasks, now+1)['display_tasks']], [str(i) for i in range(8)])

    def test_completion_stays_visible_beside_other_running_task(self):
        now = time.time()
        first = dict(id='a', title='A', source='Codex', status='running', stage='思考中', started=now-60, updated=now)
        second = dict(first, id='b', status='done', finished=now, stage='本轮完成')
        state = snapshot([first, second], now)
        self.assertEqual(state['active_count'], 1)
        self.assertEqual([t['id'] for t in state['display_tasks']], ['a', 'b'])
        first['updated'] = now + 301
        self.assertEqual([t['id'] for t in snapshot([first, second], now+301)['display_tasks']], ['a'])

    def test_long_running_turn_is_recovered_outside_bootstrap_tail(self):
        with self.path.open('w') as f:
            f.write(json.dumps(event('task_started', turn_id='long', started_at=100)) + '\n')
            for _ in range(2500):
                f.write(json.dumps(dict(type='irrelevant', payload={'text': 'x' * 1000})) + '\n')
            f.write(json.dumps(dict(type='response_item', payload={'type': 'reasoning'})) + '\n')
        self.w.poll()
        self.assertEqual(self.w.task['status'], 'running')
        self.assertEqual(self.w.task['turn_id'], 'long')

    def test_long_completed_turn_is_not_revived_by_its_tail(self):
        with self.path.open('w') as f:
            f.write(json.dumps(event('task_started', turn_id='long', started_at=100)) + '\n')
            f.write(json.dumps(event('task_complete', turn_id='long', completed_at=200, duration_ms=100000)) + '\n')
            for _ in range(2500):
                f.write(json.dumps(dict(type='irrelevant', payload={'text': 'x' * 1000})) + '\n')
        self.w.poll()
        self.assertEqual(self.w.task['status'], 'done')
        self.assertEqual(self.w.task['started'], 100)

    def test_prompt_before_bootstrap_tail_is_recovered(self):
        with self.path.open('w') as f:
            f.write(json.dumps(event('task_started', turn_id='long')) + '\n')
            prompt = dict(type='response_item', payload={'type':'function_call','call_id':'early',
                'name':'request_user_input_async','arguments':json.dumps({'questions':[{'title':'早先未回答的问题'}]})})
            f.write(json.dumps(prompt) + '\n')
            for _ in range(2500):
                f.write(json.dumps(dict(type='irrelevant', payload={'text':'x'*1000}))+'\n')
            f.write(json.dumps(dict(type='response_item', payload={'type':'reasoning'}))+'\n')
        self.w.poll()
        self.assertEqual(self.w.task['status'], 'waiting')
        self.assertEqual(self.w.task['interactions'][0]['questions'][0]['text'], '早先未回答的问题')

    def test_monitor_discovers_more_than_twelve_running_threads(self):
        home = Path(self.tmp.name) / 'codex'
        output = Path(self.tmp.name) / 'state'
        home.mkdir()
        now = time.time()
        with sqlite3.connect(home / 'state_5.sqlite') as conn:
            conn.execute('CREATE TABLE threads (id TEXT, rollout_path TEXT, title TEXT, archived INT, updated_at REAL, name TEXT)')
            for i in range(16):
                path = home / f'{i}.jsonl'
                record = event('task_started', turn_id=str(i), started_at=now)
                record['timestamp'] = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat()
                path.write_text(json.dumps(record) + '\n')
                conn.execute('INSERT INTO threads VALUES (?,?,?,?,?,?)', (str(i), str(path), f'首条问题{i}', 0, now, f'任务标题{i}'))
        process = subprocess.Popen([sys.executable, str(CLI / 'monitor.py'),
                                    '--root', str(output), '--codex-home', str(home), '--parent-pid', str(os.getpid())])
        try:
            deadline = time.monotonic() + 5
            while not (output / 'state.json').exists() and time.monotonic() < deadline:
                time.sleep(.03)
            state = json.loads((output / 'state.json').read_text())
            self.assertEqual(state['active_count'], 16)
            self.assertEqual(len(state['display_tasks']), 16)
            self.assertEqual({t['title'] for t in state['display_tasks']}, {f'任务标题{i}' for i in range(16)})
            # Rename one task while it runs; the next discovery must update its row.
            with sqlite3.connect(home / 'state_5.sqlite') as conn:
                conn.execute("UPDATE threads SET name='新任务标题' WHERE id='0'")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                state = json.loads((output / 'state.json').read_text())
                renamed = next(t for t in state['display_tasks'] if t['id'] == '0')
                if renamed['title'] == '新任务标题':
                    break
                time.sleep(.05)
            self.assertEqual(renamed['title'], '新任务标题')
        finally:
            process.terminate()
            process.wait(timeout=3)

    def test_reasoning_content_is_never_displayed(self):
        self.w.consume(event('task_started'))
        self.w.consume(event('item_completed', item={'type': 'Reasoning', 'raw_content': 'secret'}))
        self.assertNotIn('secret', json.dumps(self.w.task))

    def test_commentary_content_blocks_are_visible(self):
        self.w.consume(event('task_started'))
        self.w.consume(event('item_completed', item={'type': 'AgentMessage', 'phase': 'commentary',
                        'content': [{'type': 'Text', 'text': '正在 检查结果'}]}))
        self.assertEqual(self.w.task['detail'], '正在 检查结果')

    def ask(self, name='request_user_input_async', call='ask', questions=None):
        self.w.consume(dict(type='response_item', payload=dict(type='function_call', call_id=call, name=name,
            arguments=json.dumps({'questions': questions or [{'title': '选择下一步', 'options': ['继续', '稍后']}]}))))

    def output(self, call, value):
        self.w.consume(dict(type='response_item', payload=dict(type='function_call_output', call_id=call, output=json.dumps(value))))

    def test_async_ack_and_other_work_do_not_resolve_question(self):
        self.w.consume(event('task_started'))
        self.ask()
        self.output('ask', {'accepted': True})
        self.output('unrelated', {'result': 'secret'})
        self.w.consume(dict(type='response_item', payload={'type': 'reasoning'}))
        self.assertEqual(self.w.task['status'], 'waiting')
        self.assertEqual(self.w.task['interactions'][0]['questions'][0]['text'], '选择下一步')
        state = snapshot([self.w.task], self.w.task['updated'] + 2000)
        self.assertEqual(state['primary']['status'], 'waiting')

    def test_partial_human_reply_only_resolves_matching_question(self):
        self.w.consume(event('task_started'))
        self.ask(questions=[{'title': '问题 A'}, {'title': '问题 B'}])
        answer = [{'questionItemId': json.dumps(['request_user_input_async', 'ask', 0]), 'answer': 'A'}]
        self.w.consume(dict(type='response_item', payload={'type': 'message', 'role': 'user', 'content':[
            {'type':'input_text', 'text':'<send_user_message_question_reply>\n'+json.dumps(answer)+'\n</send_user_message_question_reply>'}]}))
        self.assertEqual([q['text'] for q in self.w.task['interactions'][0]['questions']], ['问题 B'])
        answer[0]['questionItemId'] = json.dumps(['request_user_input_async', 'ask', 1])
        self.w.consume(dict(type='response_item', payload={'type': 'message', 'role': 'user', 'content':[
            {'type':'input_text', 'text':'<send_user_message_question_reply>'+json.dumps(answer)+'</send_user_message_question_reply>'}]}))
        self.assertEqual(self.w.task['interactions'], [])
        self.assertEqual(self.w.task['status'], 'running')

    def test_sync_answer_resolves_and_preserves_option_descriptions(self):
        self.w.consume(event('task_started'))
        self.ask(name='request_user_input', questions=[{'question': '处理方式', 'header':'方式',
            'options':[{'label':'A', 'description':'方案解释'}]}])
        self.assertEqual(self.w.task['interactions'][0]['questions'][0]['options'][0]['description'], '方案解释')
        self.output('ask', {'answers': {'方式': 'A'}})
        self.assertEqual(self.w.task['interactions'], [])
        self.assertEqual(self.w.task['status'], 'running')

    def test_failed_question_delivery_and_turn_finish_clear_pending(self):
        self.w.consume(event('task_started'))
        self.ask()
        self.output('ask', {'accepted': False})
        self.assertEqual(self.w.task['interactions'], [])
        self.ask()
        self.w.consume(event('task_complete'))
        self.assertEqual(self.w.task['interactions'], [])
        self.assertEqual(self.w.task['status'], 'done')

    def test_only_explicit_question_fields_are_exposed(self):
        self.w.consume(event('task_started'))
        self.w.consume(dict(type='response_item', payload={'type':'function_call', 'name':'exec_command',
            'arguments':json.dumps({'cmd':'secret token value', 'questions':[{'title':'not a question tool'}]})}))
        self.assertEqual(self.w.task['interactions'], [])
        self.assertNotIn('secret token', json.dumps(self.w.task))

    def test_explicit_permissions_prompt_omits_permission_paths(self):
        self.w.consume(event('task_started'))
        self.w.consume(dict(type='response_item', payload={'type':'function_call', 'name':'request_permissions',
            'call_id':'permission', 'arguments':json.dumps({'reason':'需要访问项目', 'paths':['secret path']})}))
        self.assertEqual(self.w.task['interactions'][0]['kind'], 'approval')
        self.assertNotIn('secret path', json.dumps(self.w.task))

    def run_script(self, code):
        env = dict(os.environ, SMALL_SCREEN_STATUS_ROOT=self.tmp.name)
        return subprocess.run([sys.executable, str(CLI / 'screenctl.py'),
                               'run', '--title', '验证', '--', sys.executable, '-c', code], env=env)

    def task_file(self):
        files = list((Path(self.tmp.name) / 'tasks').glob('*.json'))
        self.assertEqual(len(files), 1)
        return json.loads(files[0].read_text())

    def test_script_success(self):
        result = self.run_script('pass')
        self.assertEqual(result.returncode, 0)
        task = self.task_file()
        self.assertEqual(task['status'], 'done')
        self.assertEqual(task['progress'], 100)

    def test_script_failure_retains_exit_code(self):
        result = self.run_script('raise SystemExit(7)')
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.task_file()['status'], 'error')

    def test_reported_progress_is_preserved_on_failure(self):
        ctl = str(CLI / 'screenctl.py')
        result = self.run_script(f'import subprocess,sys; subprocess.check_call([sys.executable,{ctl!r},"progress","42","--message","处理数据"]); raise SystemExit(3)')
        self.assertEqual(result.returncode, 3)
        self.assertEqual(self.task_file()['progress'], 42)


if __name__ == '__main__':
    unittest.main()
