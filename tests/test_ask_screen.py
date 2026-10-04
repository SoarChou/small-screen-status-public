import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

CLI = Path(__file__).resolve().parents[1] / 'src/cli'
sys.path.insert(0, str(CLI))
from ask_screen import questions_from

THREAD = '11111111-1111-4111-8111-111111111111'


class AskTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=3)
        self.tmp.cleanup()

    def start(self, timeout=5, questions=None):
        args = [sys.executable, str(CLI / 'ask_screen.py'),
                '--root', str(self.root), '--thread', THREAD, '--timeout', str(timeout)]
        if questions:
            path = self.root / 'questions.json'
            path.write_text(json.dumps({'questions': questions}))
            args += ['--file', str(path)]
        else:
            args += ['--question', '请选择测试方案', '--option', '方案甲', '--option', '方案乙']
        child = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(child)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            paths = list((self.root / 'screen-requests').glob('*.json'))
            if paths:
                path = paths[0]
                return child, path, json.loads(path.read_text())
            time.sleep(.02)
        self.fail('Question was not published')

    def respond(self, path, request, answers, thread=THREAD):
        path.with_suffix('.answer.json').write_text(json.dumps({'id': request['id'], 'threadID': thread, 'answers': answers}))

    def test_real_waiter_receives_answer_and_acknowledges(self):
        child, path, request = self.start()
        self.respond(path, request, {'0': '自定义中文答案'})
        stdout, stderr = child.communicate(timeout=3)
        self.assertEqual(child.returncode, 0, stderr)
        self.assertEqual(json.loads(stdout)['answers'][0]['answer'], '自定义中文答案')
        self.assertEqual(json.loads(path.read_text())['status'], 'answered')
        self.assertFalse(path.with_suffix('.answer.json').exists())

    def test_wrong_target_does_not_deliver(self):
        child, path, request = self.start()
        self.respond(path, request, {'0': '错误目标'}, thread='22222222-2222-4222-8222-222222222222')
        time.sleep(.2)
        self.assertIsNone(child.poll())
        self.respond(path, request, {'0': '正确目标'})
        stdout, _ = child.communicate(timeout=3)
        self.assertEqual(json.loads(stdout)['answers'][0]['answer'], '正确目标')

    def test_multi_question_requires_all_answers(self):
        child, path, request = self.start(questions=[{'text': '第一题'}, {'text': '第二题'}])
        self.respond(path, request, {'0': '第一题答案'})
        time.sleep(.2)
        self.assertIsNone(child.poll())
        self.respond(path, request, {'0': '第一题答案', '1': '第二题答案'})
        stdout, _ = child.communicate(timeout=3)
        self.assertEqual(len(json.loads(stdout)['answers']), 2)

    def test_timeout_is_not_an_answer(self):
        child, path, request = self.start(timeout=1)
        stdout, _ = child.communicate(timeout=3)
        self.assertEqual(child.returncode, 2)
        self.assertEqual(json.loads(stdout)['status'], 'timeout')
        self.assertEqual(json.loads(path.read_text())['status'], 'expired')

    def test_task_end_cancels_waiter(self):
        child, path, request = self.start()
        (self.root / 'state.json').write_text(json.dumps({'display_tasks': [
            {'id': THREAD, 'status': 'interrupted', 'finished': time.time()}]}))
        stdout, _ = child.communicate(timeout=3)
        self.assertEqual(json.loads(stdout)['status'], 'cancelled')

    def test_interruption_closes_request(self):
        child, path, request = self.start()
        child.send_signal(signal.SIGINT)
        child.communicate(timeout=3)
        self.assertEqual(child.returncode, 130)
        self.assertEqual(json.loads(path.read_text())['status'], 'cancelled')

    def test_invalid_input_and_path_target_rejected(self):
        with self.assertRaises(ValueError): questions_from({'questions': []})
        with self.assertRaises(ValueError): questions_from({'questions': [{'text': ''}]})
        with self.assertRaises(ValueError): questions_from({'questions': [{'text': '问题', 'options': ['']}]})
        command = [sys.executable, str(CLI / 'ask_screen.py'), '--thread', '../other', '--question', '问题', '--root', str(self.root)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / 'screen-requests').exists())


if __name__ == '__main__':
    unittest.main()
