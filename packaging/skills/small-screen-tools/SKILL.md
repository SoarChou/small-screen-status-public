---
name: small-screen-tools
description: 为已安装的 Small Screen Status 小屏应用添加或调整计时、笔记、清单、时钟、快捷入口和本地读数；不用于其他应用的小组件。
---

# 小屏工具扩展

定位已安装的 `Small Screen Status.app`，默认 `~/Applications/`，也可在 `/Applications/` 或用户指定位置。工具管理器在应用内部 `Contents/Resources/Scripts/widgetctl.py`，扩展协议在 `Contents/Resources/EXTENSIONS.md`。读协议后优先注册已有类型，无需 Swift 或重新编译。

```sh
/usr/bin/python3 "$HOME/Applications/Small Screen Status.app/Contents/Resources/Scripts/widgetctl.py" list
/usr/bin/python3 "$HOME/Applications/Small Screen Status.app/Contents/Resources/Scripts/widgetctl.py" add --id work-notes --kind note --title '任务随手记'
```

复杂配置先保存 JSON，再传 `add --file` 或 `update --file`。注册表默认 `~/Library/Application Support/SmallScreenStatus/widgets.json`，每 3 秒热更新；`--registry` 指定隔离配置。保留已有 ID、个人内容及未请求改动的工具，不用默认配置覆盖用户配置。运行 `validate`，确认实际界面与用户所需行为。

只针对用户明确要求的来源添加监测读数，不扫描其他项目／凭据。新交互类型需要源码工程，编译应用内部没有 Swift 源码；告知需要源项目，不直接篡改签名后的应用。新增任务提问使用配套 `$small-screen-ask`，不能把内置提问的复制／跳转说成直接提交。
