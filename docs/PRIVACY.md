# 隐私与本地数据

Small Screen Status 在当前用户的 Mac 上运行。监测器只读 `~/.codex/state_5.sqlite` 和对应的本地任务事件文件，用于取得任务标题、状态、公开进展及明确发出的提问。应用不会修改 Codex 的任务记录，也不会读取浏览器中的 ChatGPT 对话。脚本任务由使用者主动运行 `screenctl.py` 才会出现。

应用在 `~/Library/Application Support/SmallScreenStatus/` 保存工具配置、笔记、清单、计时状态、提问或追加指令草稿、脚本状态、小屏提问记录、界面状态以及 `monitor.log`、`launcher.log`。这些文件可能包含任务标题、问题文字、个人笔记或本机路径。小屏直接提问的答案文件在等待工具接收后删除，请求文件会留下状态记录；草稿和其他状态按功能需要保留。macOS 偏好设置另存字号与显示屏选择。

应用代码没有遥测或自动网络请求。配置的链接只在使用者点击时由 macOS 打开；若配置了本地 `readout`，应用只读取明确指定的 JSON 文件。安装程序不上传本机状态。

要清除个人内容，请先退出应用，再自行删除上述应用支持目录；这会同时删除笔记、草稿、计时和脚本状态。已安装的 LaunchAgent 可通过分享包内 `python3 install.py --remove-autostart` 取消。提交问题报告时，请检查截图、日志、`state.json`、`ui-state.json` 和发行包，避免带入本机信息。

仓库只存源码、示例配置、文档和测试。构建产物与日志被 `.gitignore` 排除；发行 ZIP 作为 GitHub Release 附件发布。示例不使用真实设备型号、显示规格、用户名或个人文件路径。
