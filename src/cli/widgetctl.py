#!/usr/bin/env python3
"""Manage data-defined small-screen tools without rebuilding the app."""
import argparse
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlparse
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from monitor import ROOT, atomic_json

KINDS = {'timer', 'note', 'checklist', 'clock', 'links', 'readout'}


def validate_widget(widget):
    if not isinstance(widget, dict):
        raise ValueError('工具必须是 JSON 对象')
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', widget.get('id', '')):
        raise ValueError('id 使用小写字母、数字和连字符，以字母开头')
    if widget.get('kind') not in KINDS:
        raise ValueError('未知 kind: ' + str(widget.get('kind')))
    if not isinstance(widget.get('title'), str) or not widget['title'].strip():
        raise ValueError('缺少 title')
    if 'monitor' in widget and not isinstance(widget['monitor'], bool):
        raise ValueError('monitor 必须为 true 或 false')
    if widget['kind'] == 'timer':
        presets = widget.get('presets', [5, 25, 50])
        if not presets or any(not isinstance(n, int) or not 1 <= n <= 1440 for n in presets):
            raise ValueError('presets 是 1–1440 的分钟数列表')
    if widget['kind'] == 'checklist':
        ids = []
        for item in widget.get('items', []):
            if not isinstance(item.get('id'), str) or not item.get('id') or not item.get('text'):
                raise ValueError('清单项需要 id 和 text')
            ids.append(item['id'])
        if len(set(ids)) != len(ids):
            raise ValueError('清单项 id 重复')
    if widget['kind'] == 'clock':
        for zone in widget.get('zones', []):
            if zone.get('timezone') == 'local':
                continue
            try:
                ZoneInfo(zone['timezone'])
            except (KeyError, ZoneInfoNotFoundError):
                raise ValueError('无效的 timezone')
    if widget['kind'] == 'links':
        for link in widget.get('links', []):
            if not link.get('title') or urlparse(link.get('url', '')).scheme not in {'https', 'http', 'codex', 'file'}:
                raise ValueError('入口需要标题和 https/http/codex/file URL')
    if widget['kind'] == 'readout' and not Path(widget.get('file', '')).is_absolute():
        raise ValueError('readout 的 file 必须是本地绝对路径')
    return widget


def validate_registry(registry):
    if registry.get('version') != 1 or not isinstance(registry.get('widgets'), list):
        raise ValueError('注册表需要 version: 1 和 widgets 列表')
    widgets = [validate_widget(w) for w in registry['widgets']]
    if len({w['id'] for w in widgets}) != len(widgets):
        raise ValueError('工具 id 重复')
    return registry


def main():
    p = argparse.ArgumentParser(description='添加或更新小屏工具')
    p.add_argument('--registry', type=Path, default=ROOT / 'widgets.json')
    sub = p.add_subparsers(dest='action', required=True)
    sub.add_parser('list')
    sub.add_parser('validate')
    for action in ['add', 'update']:
        a = sub.add_parser(action)
        a.add_argument('--file', type=Path)
        a.add_argument('--id')
        a.add_argument('--kind', choices=sorted(KINDS))
        a.add_argument('--title')
        a.add_argument('--subtitle', default='')
    args = p.parse_args()
    try:
        bundled = Path(__file__).with_name('widgets.json')
        source_default = Path(__file__).resolve().parents[1] / 'config/widgets.json'
        source = args.registry if args.registry.exists() else bundled if bundled.exists() else source_default
        registry = validate_registry(json.loads(source.read_text()))
        if args.action == 'list':
            print(json.dumps(registry, ensure_ascii=False, indent=2))
        elif args.action == 'validate':
            print('注册表有效，工具数：', len(registry['widgets']))
        else:
            widget = json.loads(args.file.read_text()) if args.file else dict(id=args.id, kind=args.kind, title=args.title, subtitle=args.subtitle)
            validate_widget(widget)
            index = next((i for i, w in enumerate(registry['widgets']) if w['id'] == widget['id']), None)
            if args.action == 'add':
                if index is not None:
                    raise ValueError('id 已存在；要修改请使用 update')
                registry['widgets'].append(widget)
            else:
                if index is None:
                    raise ValueError('要更新的 id 不存在')
                registry['widgets'][index] = widget
            validate_registry(registry)
            atomic_json(args.registry, registry)
            print('已保存：', args.registry)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        p.error(str(error))


if __name__ == '__main__':
    sys.exit(main())
