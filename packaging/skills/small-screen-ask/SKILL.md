---
name: small-screen-ask
description: 把当前任务需要用户回答的问题发到 Small Screen Status 小屏，点选或输入后直接返回等待中的任务；不接管已有 Codex 内置提问或正式审批。
---

# 小屏直接回答

先定位已安装的 `Small Screen Status.app`：默认在 `~/Applications/`，也可能在 `/Applications/`，用户指定位置时用其位置。调用应用内部 `Contents/Resources/Scripts/ask_screen.py`，使用 Python 3.9+。不要依赖分享者的开发目录。

```sh
/usr/bin/python3 "$HOME/Applications/Small Screen Status.app/Contents/Resources/Scripts/ask_screen.py" --question '采用哪套配置？' --option '当前配置' --option '低内存配置'
```

默认从当前环境 `CODEX_THREAD_ID` 绑定原对话。没有该变量时先确定当前真实对话 ID，再传 `--thread`；无法确定则使用正常提问方式，不猜测其他任务。复杂内容／1–3 个问题用 `--file /absolute/path.json`，结构为 `{"questions":[{"text":"问题","options":[{"label":"选项","description":"说明"}]}]}`。

通过任务执行工具启动并等待该进程结果；单次等待不超过 60 秒，期间可处理不依赖答案的工作。默认等待 900 秒，`--timeout` 可设 1–3600 秒。只有 `status: answered` 代表用户实际提交；超时、取消、中断不是用户同意，不代为选择。单题点选自动提交，多题填齐后统一提交。

小屏应运行且目标屏幕已连接；不可用则回到正常提问。已有内置提问仍在原对话提交。正式权限授权／受控操作审批使用正式流程，不能借这里的普通选项绕过。不要代替用户点击答案。
