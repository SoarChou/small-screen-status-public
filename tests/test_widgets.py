import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
CLI = Path(__file__).resolve().parents[1] / 'src/cli'
sys.path.insert(0, str(CLI))
from widgetctl import validate_registry, validate_widget


class WidgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.registry = Path(self.tmp.name) / 'widgets.json'
        self.default = json.loads((Path(__file__).resolve().parents[1] / 'src/config/widgets.json').read_text())
        self.registry.write_text(json.dumps(self.default))

    def tearDown(self):
        self.tmp.cleanup()

    def test_defaults_and_duplicate_detection(self):
        validate_registry(self.default)
        duplicate = copy.deepcopy(self.default)
        duplicate['widgets'].append(duplicate['widgets'][0])
        with self.assertRaises(ValueError):
            validate_registry(duplicate)

    def test_extension_addition_preserves_existing_tools(self):
        command = [sys.executable, str(CLI / 'widgetctl.py'), '--registry', str(self.registry),
                   'add', '--id', 'work-notes', '--kind', 'note', '--title', '任务随手记']
        first = subprocess.run(command, capture_output=True)
        self.assertEqual(first.returncode, 0)
        updated = json.loads(self.registry.read_text())
        self.assertEqual(updated['widgets'][:-1], self.default['widgets'])
        self.assertEqual(updated['widgets'][-1]['id'], 'work-notes')
        second = subprocess.run(command, capture_output=True)
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(json.loads(self.registry.read_text()), updated)

    def test_links_never_allow_command_schemes(self):
        with self.assertRaises(ValueError):
            validate_widget(dict(id='link', kind='links', title='入口', links=[dict(title='命令', url='javascript:doSomething()')]))

    def test_invalid_time_zone_and_duration(self):
        with self.assertRaises(ValueError):
            validate_widget(dict(id='clock', kind='clock', title='时间', zones=[dict(title='错误', timezone='Unknown/Zone')]))
        validate_widget(dict(id='clock', kind='clock', title='时间', zones=[dict(title='本地', timezone='local')]))
        with self.assertRaises(ValueError):
            validate_widget(dict(id='timer', kind='timer', title='计时', presets=[0]))

    def test_readout_is_an_explicit_local_file(self):
        with self.assertRaises(ValueError):
            validate_widget(dict(id='metric', kind='readout', title='指标', file='metrics.json'))
        validate_widget(dict(id='metric', kind='readout', title='指标', file='/tmp/metrics.json'))


if __name__ == '__main__':
    unittest.main()
