---
name: small-screen-install
description: 在 Mac 上安装、更新或检查可分享的 Small Screen Status 小屏应用，选择目标显示屏，并设置随 ChatGPT/Codex 启动和退出。适用于安装此应用包，不用于其他软件。
---

# 安装小屏任务状态

安装包包含编译后的通用 Mac 应用，不需要 Swift 编译。需要 macOS 13+、Python 3.9+；`/usr/bin/python3` 由 Apple Command Line Tools 提供。应用读取当前用户的 Codex 本地任务记录，不监测浏览器里的 ChatGPT 对话。普通 ChatGPT 可以作为启停宿主，任务监测仍需本地 Codex 数据。

入口是本 skill 的 `scripts/install.py`。它优先使用随分享包一起提供的 `install.py`；独立 skill 则解压 `assets/SmallScreenStatus-macOS.zip`，安装完成后仍从稳定应用路径运行。用户提供了不同发布包时，用 `--package /absolute/path/to/package.zip` 或解压后的目录，不在用户其他目录递归搜索。

先运行入口加 `--dry-run`，检查架构、签名完整性和实际安装位置。默认安装 `~/Applications/Small Screen Status.app`、三个配套 skill（已有同名 skill 保留）及当前用户 LaunchAgent。默认随本机 ChatGPT/Codex 启停，菜单栏 `◉ → 选择显示屏` 可以改目标；自动模式选择最小副屏，只有主屏时保持隐藏。用户指定屏幕时传 `--display '屏幕名称'`；指定宿主时传 `--host-app /absolute/path/ChatGPT.app`。不要默认覆盖主屏。

执行入口（不加 `--dry-run`）安装，再加 `--check` 查看安装版本、监听器参数与运行状态。`--no-autostart` 跳过启停设置，`--no-skills` 跳过配套 skill，`--app-dir` 指定应用目录，`--python` 指定已有 Python 3.9+ 解释器。安装后的工具位于应用的 `Contents/Resources/Scripts/`；辅助监听器位于 `Contents/Resources/Tools/`。

这是临时签名、未 Apple 公证的个人分享版本。若实际被 Gatekeeper 阻止，告知用户应用位置与系统提示，让用户按 [Apple 的首次打开流程](https://support.apple.com/102445) 对这个应用确认。不要删除 quarantine、全局关闭 Gatekeeper 或把临时签名说成 Apple 公证。缺少 Python 时说明 `xcode-select --install` 或使用已有合适 Python；安装额外依赖按当前用户授权处理。

检查时区分“复制安装成功”与“运行成功”：宿主关闭时小屏可以不运行；宿主打开后使用安装入口的 `--check` 确认状态更新、热键注册和启动时不抢键盘焦点。必要时调用已安装辅助程序 `--list-displays` 获取屏幕名称，再让用户在菜单中选择，或按其明确要求写入偏好。验证界面只操作小屏；不要为测试关闭用户正在工作的 ChatGPT。

更新保留个人内容，旧应用会先正常退出并留下带时间戳的应用备份。已安装应用的 `--check` 和 `--remove-autostart` 可以通过同一入口调用；取消联动保留应用和个人内容。不要为普通安装清空 `~/Library/Application Support/SmallScreenStatus/`。
